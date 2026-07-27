use Test::Nginx::Socket -Base;

repeat_each(1);
# the connect-failure block checks the response body only
plan tests => repeat_each() * (blocks() * 3 - 1);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: new / connect / request / read_body
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "hello\n"
            ngx.header["Content-Length"] = #body
            ngx.header["X-Mock"] = "yes"
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(2000)

            local ok, err = httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })
            if not ok then
                ngx.status = 500
                ngx.say("connect: ", err)
                return
            end

            local res, rerr = httpc:request({ method = "GET", path = "/mock" })
            if not res then
                ngx.status = 500
                ngx.say("request: ", rerr)
                return
            end

            ngx.say(res.status)
            ngx.say(res.headers["X-Mock"])
            ngx.print(res:read_body())
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
200
yes
hello
--- no_error_log
[error]



=== TEST 2: POST body and custom header
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            ngx.req.read_body()
            local body = ngx.req.get_body_data() or ""
            local out = ngx.req.get_method() .. "\n"
                .. (ngx.req.get_headers()["x-client-test"] or "") .. "\n"
                .. body
            ngx.header["Content-Length"] = #out
            ngx.print(out)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({
                method = "POST",
                path = "/echo",
                headers = { ["X-Client-Test"] = "sent" },
                body = "payload-123",
            }))

            ngx.say(res.status)
            ngx.say(res:read_body())
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
200
POST
sent
payload-123
--- no_error_log
[error]



=== TEST 3: two requests on one connection
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            local b = "AAA"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /b {
        content_by_lua_block {
            local b = "BBBB"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res1 = assert(httpc:request({ path = "/a" }))
            local body1 = res1:read_body()

            local res2 = assert(httpc:request({ path = "/b" }))
            local body2 = res2:read_body()

            ngx.say(body1)
            ngx.say(body2)
            -- the second request never reconnected
            ngx.say("reused=", httpc:get_reused_times())
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
AAA
BBBB
reused=0
--- no_error_log
[error]



=== TEST 4: empty body
--- http_config eval: $::HttpConfig
--- config
    location /empty {
        content_by_lua_block {
            ngx.header["Content-Length"] = 0
            ngx.status = 204
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/empty" }))
            local body = res:read_body()

            ngx.say(res.status)
            ngx.say("len=", #body)
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
204
len=0
--- no_error_log
[error]



=== TEST 5: query params
--- http_config eval: $::HttpConfig
--- config
    location /q {
        content_by_lua_block {
            local v = ngx.var.arg_q or ""
            ngx.header["Content-Length"] = #v
            ngx.print(v)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({
                path = "/q",
                query = { q = "hello" },
            }))

            ngx.say(res.status)
            ngx.say(res:read_body())
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
200
hello
--- no_error_log
[error]



=== TEST 6: set_keepalive saves the connection, the next connect reuses it
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function once()
                local httpc = http.new()
                local ok, err = httpc:connect({ host = "127.0.0.1", port = port })
                if not ok then return nil, "connect: " .. err end

                local res, rerr = httpc:request({ path = "/mock" })
                if not res then return nil, "request: " .. rerr end

                local body = res:read_body()
                local reused = httpc:get_reused_times()

                local kok, kerr = httpc:set_keepalive(10000)
                if not kok then return nil, "keepalive: " .. kerr end

                return { status = res.status, body = body, reused = reused }
            end

            local r1 = assert(once())
            local r2 = assert(once())

            ngx.say(r1.status, " ", r1.reused, " ", r1.body == "ok\n")
            ngx.say(r2.status, " ", r2.reused, " ", r2.body == "ok\n")
        }
    }
--- request
GET /t
--- response_body
200 0 true
200 1 true
--- no_error_log
[error]



=== TEST 7: reuse count climbs across a keepalive loop
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port
            local reused = {}

            for i = 1, 5 do
                local httpc = http.new()
                assert(httpc:connect({ host = "127.0.0.1", port = port }))

                local res = assert(httpc:request({ path = "/mock" }))
                assert(res:read_body() == "ok")

                reused[i] = httpc:get_reused_times()
                assert(httpc:set_keepalive())
            end

            ngx.say(table.concat(reused, ","))
        }
    }
--- request
GET /t
--- response_body
0,1,2,3,4
--- no_error_log
[error]



=== TEST 8: request before connect
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            local res, err = httpc:request({ path = "/x" })
            ngx.say(res and "unexpected" or err)
        }
    }
--- request
GET /t
--- response_body
not connected
--- no_error_log
[error]



=== TEST 9: request after close fails, double close is safe
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/mock" }))
            assert(res:read_body() == "ok")

            httpc:close()
            httpc:close()

            local again, err = httpc:request({ path = "/mock" })
            ngx.say(again and "unexpected" or err)
        }
    }
--- request
GET /t
--- response_body
not connected
--- no_error_log
[error]



=== TEST 10: connect to a closed port fails cleanly
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            local ok, err = httpc:connect({ host = "127.0.0.1", port = 1 })
            ngx.say(ok and "unexpected-connect" or ("failed: " .. err))
        }
    }
--- request
GET /t
--- response_body_like: failed: (connect failed|connection refused|Connection refused)



=== TEST 11: unsupported scheme is rejected before any socket work
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            local ok, err = httpc:connect({
                scheme = "ftp",
                host = "127.0.0.1",
                port = 80,
            })

            ngx.say(ok and "unexpected" or err)
        }
    }
--- request
GET /t
--- response_body
unsupported scheme
--- no_error_log
[error]



=== TEST 12: an unread body keeps the connection out of the pool
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = ("x"):rep(30000)
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/mock" }))
            -- deliberately read only the first slice
            local chunk = res.body_reader()
            ngx.say("first=", chunk ~= nil)

            local ok, err = httpc:set_keepalive()
            ngx.say(ok and "unexpected-pooled" or err)
        }
    }
--- request
GET /t
--- response_body
first=true
connection not reusable
--- no_error_log
[error]



=== TEST 13: a second request over an unread response is refused
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = ("x"):rep(30000)
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/mock" }))
            assert(res.body_reader() ~= nil)

            local again, err = httpc:request({ path = "/mock" })
            ngx.say(again and "unexpected" or err)
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
previous response is not fully read
--- no_error_log
[error]
