use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3);

our $UseLLHTTP = !defined($ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP})
    || $ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP} eq ''
    || $ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP} eq '1';

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: a large body is delivered in slices, not in one buffer
--- http_config eval: $::HttpConfig
--- config
    location /big {
        content_by_lua_block {
            local b = ("z"):rep(60000)
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

            local res = assert(httpc:request({ path = "/big" }))

            local reader = res.body_reader
            local total, slices = 0, 0
            local all = {}

            while true do
                local chunk, err = reader()
                if err then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                if not chunk then
                    break
                end

                slices = slices + 1
                total = total + #chunk
                all[slices] = chunk
            end

            ngx.say("bytes=", total)
            ngx.say("intact=", table.concat(all) == ("z"):rep(60000))
            ngx.say("sliced=", slices > 1)
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
bytes=60000
intact=true
sliced=true
--- no_error_log
[error]



=== TEST 2: read_body concatenates the whole streamed body
--- http_config eval: $::HttpConfig
--- config
    location /big {
        content_by_lua_block {
            local b = ("ab"):rep(20000)
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

            local res = assert(httpc:request({ path = "/big" }))
            local body = assert(res:read_body())

            ngx.say(#body)
            ngx.say(body == ("ab"):rep(20000))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
40000
true
--- no_error_log
[error]



=== TEST 3: preread_body reads a multi-recv body in a single resume
--- http_config eval: $::HttpConfig
--- config
    location /big {
        content_by_lua_block {
            local b = ("y"):rep(60000)
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

            local res = assert(httpc:request({
                path = "/big",
                preread_body = true,
            }))

            -- the whole body came back with the headers, in that one resume
            ngx.say("prefilled=", res.body ~= nil and #res.body or "nil")

            local reader = res.body_reader
            local first = reader()
            local second = reader()

            ngx.say("slices=", first and #first or 0, ",", second and #second or 0)
            ngx.say("intact=", first == ("y"):rep(60000))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
prefilled=60000
slices=60000,0
intact=true
--- no_error_log
[error]



=== TEST 4: slices arrive as the peer writes them, not at the end
--- http_config eval: $::HttpConfig
--- config
    location /drip {
        content_by_lua_block {
            local part = ("d"):rep(1000)
            ngx.header["Content-Length"] = 2 * #part
            ngx.print(part)
            ngx.flush(true)
            ngx.sleep(0.2)
            ngx.print(part)
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

            local start = ngx.now()
            local res = assert(httpc:request({ path = "/drip" }))
            local reader = res.body_reader

            local first = reader()
            local after_first = ngx.now() - start

            local second = reader()
            local after_second = ngx.now() - start

            ngx.say("first=", #first, " early=", after_first < 0.15)
            ngx.say("second=", #second, " late=", after_second >= 0.15)
            ngx.say("eof=", reader() == nil)
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
first=1000 early=true
second=1000 late=true
eof=true
--- no_error_log
[error]



=== TEST 5: chunked response streams through llhttp
--- skip_eval: 3: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /chunked {
        content_by_lua_block {
            for i = 1, 3 do
                ngx.print(("c"):rep(10))
                ngx.flush(true)
            end
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

            local res = assert(httpc:request({ path = "/chunked" }))
            ngx.say("te=", res.headers["Transfer-Encoding"])

            local body = assert(res:read_body())
            ngx.say(#body, " ", body == ("c"):rep(30))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
te=chunked
30 true
--- no_error_log
[error]



=== TEST 6: chunked response is rejected by the hand-written parser
--- skip_eval: 3: $::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /chunked {
        content_by_lua_block {
            ngx.say("chunked")
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

            local res, err = httpc:request({ path = "/chunked" })
            ngx.say(res and "unexpected" or err)
        }
    }
--- request
GET /t
--- response_body_like: chunked response is not supported
--- no_error_log
[error]



=== TEST 7: an empty streamed body reports EOF right away
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

            ngx.say(res.status)
            ngx.say("first=", tostring(res.body_reader()))
            ngx.say("body=", string.format("%q", res:read_body()))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
204
first=nil
body=""
--- no_error_log
[error]



=== TEST 8: the connection is reusable after a fully streamed body
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = ("m"):rep(9000)
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port
            local out = {}

            for i = 1, 3 do
                local httpc = http.new()
                assert(httpc:connect({ host = "127.0.0.1", port = port }))

                local res = assert(httpc:request({ path = "/mock" }))
                local body = assert(res:read_body())

                out[i] = httpc:get_reused_times() .. ":" .. #body
                assert(httpc:set_keepalive())
            end

            ngx.say(table.concat(out, " "))
        }
    }
--- request
GET /t
--- response_body
0:9000 1:9000 2:9000
--- no_error_log
[error]



=== TEST 9: two streamed responses on one connection
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            local b = ("1"):rep(5000)
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /b {
        content_by_lua_block {
            local b = ("2"):rep(7000)
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
            local body1 = assert(res1:read_body())

            local res2 = assert(httpc:request({ path = "/b" }))
            local body2 = assert(res2:read_body())

            ngx.say(#body1, " ", body1 == ("1"):rep(5000))
            ngx.say(#body2, " ", body2 == ("2"):rep(7000))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
5000 true
7000 true
--- no_error_log
[error]



=== TEST 10: a truncated body fails instead of returning a short read
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = 12799,
            }))

            local res = assert(httpc:request({ path = "/short" }))
            ngx.say(res.status)

            local body, err = res:read_body()
            ngx.say(body and ("unexpected: " .. #body) or err)
        }
    }
--- tcp_listen: 12799
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly-ten-b"
--- request
GET /t
--- response_body
200
upstream closed before complete response
--- no_error_log
[error]
