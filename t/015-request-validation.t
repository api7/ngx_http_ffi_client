# What a caller may put in a request line and in a request header. Anything the
# client cannot write as one method, one target and one header per line is
# refused before a byte reaches the wire.

use Test::Nginx::Socket -Base;

repeat_each(1);
# the two blocks with a tcp_query check the request bytes on top of the three
plan tests => repeat_each() * (blocks() * 3 + 2);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: a method carrying its own target is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "GET /evil",
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)
        }
    }
--- request
GET /t
--- response_body
invalid method
--- no_error_log
[error]



=== TEST 2: a method with a control byte or a tab is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _, method in ipairs({ "GE\0T", "GE\tT", "GE\1T", "" }) do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    method = method,
                    path = "/",
                    timeout = 1000,
                })

                ngx.say(res and ("unexpected " .. res.status) or err)
            end
        }
    }
--- request
GET /t
--- response_body
invalid method
invalid method
invalid method
method is required
--- no_error_log
[error]



=== TEST 3: a token method that is not a well-known one still goes out
--- http_config eval: $::HttpConfig
--- config
    location = /echo {
        content_by_lua_block {
            local method = ngx.req.get_method()

            -- length framed, so the hand-written backend reads it too
            ngx.header["Content-Length"] = #method
            ngx.print(method)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "M-SEARCH",
                path = "/echo",
                timeout = 1000,
            })

            ngx.say(res and res.body or err)
        }
    }
--- request
GET /t
--- response_body
M-SEARCH
--- no_error_log
[error]



=== TEST 4: a header name carrying its own header is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local names = { "X: injected", "X Y", "X\0Y", "X\1Y", "" }

            for _, name in ipairs(names) do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    path = "/",
                    headers = { [name] = "value" },
                    timeout = 1000,
                })

                ngx.say(res and ("unexpected " .. res.status) or err)
            end
        }
    }
--- request
GET /t
--- response_body
invalid request header
invalid request header
invalid request header
invalid request header
invalid request header
--- no_error_log
[error]



=== TEST 5: a control byte in a header value is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _, value in ipairs({ "a\0b", "a\1b", "a\127b" }) do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    path = "/",
                    headers = { ["X-Test"] = value },
                    timeout = 1000,
                })

                ngx.say(res and ("unexpected " .. res.status) or err)
            end
        }
    }
--- request
GET /t
--- response_body
invalid request header
invalid request header
invalid request header
--- no_error_log
[error]



=== TEST 6: the header name and value characters RFC 9110 allows are sent
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12850,
                path = "/",
                headers = { ["X-Odd!name~1"] = "spaced\tvalue" },
                timeout = 1000,
            })

            ngx.say(res and res.body or err)
        }
    }
--- tcp_listen: 12850
--- tcp_query eval
"GET / HTTP/1.1\r\nHost: 127.0.0.1:12850\r\nConnection: close\r\n"
. "Content-Length: 0\r\nX-Odd!name~1: spaced\tvalue\r\n\r\n"
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]



=== TEST 7: a path with a space or a control byte is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _, path in ipairs({ "/a b", "/a\0b", "/a\tb", "relative" }) do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    path = path,
                    timeout = 1000,
                })

                ngx.say(res and ("unexpected " .. res.status) or err)
            end
        }
    }
--- request
GET /t
--- response_body
invalid path
invalid path
invalid path
invalid path
--- no_error_log
[error]



=== TEST 8: the stateful object validates the same way
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local httpc = client.new()
            httpc:set_timeouts(1000, 1000, 1000)

            local ok, err = httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })

            if not ok then
                ngx.say(err)
                return
            end

            local res, rerr = httpc:request({ method = "GET /evil" })
            ngx.say(res and ("unexpected " .. res.status) or rerr)

            res, rerr = httpc:request({ headers = { ["X: injected"] = "1" } })
            ngx.say(res and ("unexpected " .. res.status) or rerr)

            httpc:close()
        }
    }
--- request
GET /t
--- response_body
invalid method
invalid request header
--- no_error_log
[error]



=== TEST 9: a host with a space is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1 evil",
                port = ngx.var.server_port,
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)
        }
    }
--- request
GET /t
--- response_body
invalid host
--- no_error_log
[error]



=== TEST 10: a body containing CR and LF is sent verbatim
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12851,
                method = "POST",
                path = "/",
                body = "{\n  \"model\": \"m\"\r\n}",
                timeout = 1000,
            })

            ngx.say(res and res.body or err)
        }
    }
--- tcp_listen: 12851
--- tcp_query eval
"POST / HTTP/1.1\r\nHost: 127.0.0.1:12851\r\nConnection: close\r\n"
. "Content-Length: 19\r\n\r\n{\n  \"model\": \"m\"\r\n}"
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
