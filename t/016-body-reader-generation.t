use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: a reader from an earlier response never reads a later one
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("AAA")
        }
    }

    location /b {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("BBB")
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

            local res1 = assert(httpc:request({
                path = "/a",
                preread_body = true,
            }))
            ngx.say("first=", res1.body)

            local res2 = assert(httpc:request({ path = "/b" }))

            local chunk, err = res1.body_reader()
            ngx.say("stale=", tostring(chunk), " ", tostring(err))

            -- the refused read left the second response untouched
            ngx.say("second=", assert(res2:read_body()))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
first=AAA
stale=nil stale body reader
second=BBB
--- no_error_log
[error]



=== TEST 2: read_body on a stale response reports the error
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("AAA")
        }
    }

    location /b {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("BBB")
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

            local res1 = assert(httpc:request({
                path = "/a",
                preread_body = true,
            }))
            -- drop the body the fast path handed over, so read_body has to
            -- reach for the reader
            res1.body = nil

            assert(httpc:request({ path = "/b" }))

            local body, err = res1:read_body()
            ngx.say("body=", tostring(body))
            ngx.say("err=", tostring(err))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
body=nil
err=stale body reader
--- no_error_log
[error]



=== TEST 3: a reader kept across set_keepalive is refused
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("AAA")
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                pool = "generation-keepalive",
            }))

            local res = assert(httpc:request({
                path = "/a",
                preread_body = true,
            }))

            assert(httpc:set_keepalive())

            local chunk, err = res.body_reader()
            ngx.say("stale=", tostring(chunk), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
stale=nil stale body reader
--- no_error_log
[error]



=== TEST 4: a reader kept across close is refused
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("AAA")
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
                path = "/a",
                preread_body = true,
            }))

            httpc:close()

            local chunk, err = res.body_reader()
            ngx.say("stale=", tostring(chunk), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
stale=nil stale body reader
--- no_error_log
[error]



=== TEST 5: a reader kept across a reconnect is refused
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("AAA")
        }
    }

    location /b {
        content_by_lua_block {
            ngx.header["Content-Length"] = 3
            ngx.print("BBB")
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            local opts = {
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }

            assert(httpc:connect(opts))

            local res1 = assert(httpc:request({
                path = "/a",
                preread_body = true,
            }))

            httpc:close()
            assert(httpc:connect(opts))

            local res2 = assert(httpc:request({ path = "/b" }))

            local chunk, err = res1.body_reader()
            ngx.say("stale=", tostring(chunk), " ", tostring(err))
            ngx.say("second=", assert(res2:read_body()))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
stale=nil stale body reader
second=BBB
--- no_error_log
[error]



=== TEST 6: the happy path is unchanged, one reader per response
--- http_config eval: $::HttpConfig
--- config
    location /a {
        content_by_lua_block {
            local body = ("a"):rep(20000)
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /b {
        content_by_lua_block {
            local body = ("b"):rep(20000)
            ngx.header["Content-Length"] = #body
            ngx.print(body)
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

            local function drain(res)
                local parts = {}
                while true do
                    local chunk, err = res.body_reader()
                    if err then
                        return nil, err
                    end

                    if not chunk then
                        break
                    end

                    parts[#parts + 1] = chunk
                end

                return table.concat(parts)
            end

            local res1 = assert(httpc:request({ path = "/a" }))
            local first = assert(drain(res1))

            local res2 = assert(httpc:request({ path = "/b" }))
            local second = assert(drain(res2))

            ngx.say("first=", first == ("a"):rep(20000))
            ngx.say("second=", second == ("b"):rep(20000))
            -- a drained reader stays done rather than reaching for more
            ngx.say("again=", tostring(res1.body_reader()))
            httpc:close()
        }
    }
--- request
GET /t
--- response_body
first=true
second=true
again=nil
--- no_error_log
[error]
