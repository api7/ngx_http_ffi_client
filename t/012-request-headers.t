# Request headers the client writes itself. Host, Connection and Content-Length
# are set by the client but a caller may override them, as in lua-resty-http;
# their values feed the request prologue rather than being emitted twice.

use Test::Nginx::Socket -Base;

repeat_each(1);
# the last block also asserts the request bytes, which counts as one more test
plan tests => repeat_each() * (blocks() * 3 + 1);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: a caller Host replaces the one built from the peer
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/echo",
                headers = { ["Host"] = "example.test" },
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
example.test
--- no_error_log
[error]



=== TEST 2: without an override the Host still comes from the peer
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body == "127.0.0.1:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 3: the Host override reaches the wire from the stateful object
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({
                path = "/echo",
                headers = { ["Host"] = "vhost.test" },
            }))

            ngx.print(assert(res:read_body()))

            httpc:close()
        }
    }
--- request
GET /t
--- response_body
vhost.test
--- no_error_log
[error]



=== TEST 4: a caller Connection value reaches the wire
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = (ngx.var.http_connection or "none") .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/echo",
                headers = { ["Connection"] = "close" },
                keepalive = { pool_size = 4 },
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
close
--- no_error_log
[error]



=== TEST 5: Connection: close keeps the connection out of the pool
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = "ok\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for i = 1, 2 do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    path = "/echo",
                    headers = { ["Connection"] = "close" },
                    keepalive = { pool_size = 4 },
                    timeout = 1000,
                })

                if not res then
                    ngx.say(err)
                    return
                end

                ngx.say(res.reused)
            end
        }
    }
--- request
GET /t
--- response_body
false
false
--- no_error_log
[error]



=== TEST 6: Connection: close on the object refuses set_keepalive afterwards
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12831 }))

            local res = assert(httpc:request({
                path = "/",
                headers = { ["Connection"] = "close" },
            }))

            ngx.say(assert(res:read_body()))

            local ok, err = httpc:set_keepalive()
            ngx.say(ok or err)
        }
    }
--- tcp_listen: 12831
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
--- request
GET /t
--- response_body
hi
connection not reusable
--- no_error_log
[error]



=== TEST 7: a Content-Length that matches the body is accepted
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            ngx.req.read_body()
            local body = ngx.var.http_content_length .. ":"
                         .. (ngx.req.get_body_data() or "") .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "POST",
                path = "/echo",
                body = "payload",
                headers = { ["Content-Length"] = "7" },
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
7:payload
--- no_error_log
[error]



=== TEST 8: a Content-Length that disagrees with the body is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "POST",
                path = "/",
                body = "payload",
                headers = { ["Content-Length"] = "3" },
                timeout = 1000,
            })

            if res then
                ngx.say("unexpected success")
                return
            end

            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
content-length does not match the body
--- no_error_log
[error]



=== TEST 9: a Content-Length that is not a number is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res, err = httpc:request({
                path = "/",
                headers = { ["Content-Length"] = "7, 7" },
            })

            ngx.say(res and "unexpected success" or err)

            httpc:close()
        }
    }
--- request
GET /t
--- response_body
content-length does not match the body
--- no_error_log
[error]



=== TEST 10: the reserved headers are emitted once, with the caller's values
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12832 }))

            local res = assert(httpc:request({
                path = "/",
                headers = {
                    ["Host"] = "once.test",
                    ["Connection"] = "keep-alive",
                    ["X-Trace"] = "1",
                },
            }))

            ngx.say(assert(res:read_body()))

            httpc:close()
        }
    }
--- tcp_listen: 12832
--- tcp_query eval
"GET / HTTP/1.1\r\nHost: once.test\r\nConnection: keep-alive\r\nContent-Length: 0\r\nX-Trace: 1\r\n\r\n"
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
