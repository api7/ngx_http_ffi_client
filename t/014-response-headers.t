# The response header table: what a repeated header looks like, and how a name
# is looked up. The contract is lua-resty-http's, so a plugin written against
# it reads the same values here.

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

=== TEST 1: a repeated header comes back as an array of its values
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12840,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            local cookies = res.headers["Set-Cookie"]
            ngx.say(type(cookies))
            ngx.say(table.concat(cookies, " | "))
        }
    }
--- tcp_listen: 12840
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
. "Set-Cookie: a=1; Path=/\r\nSet-Cookie: b=2; Path=/\r\n\r\nhi"
--- request
GET /t
--- response_body
table
a=1; Path=/ | b=2; Path=/
--- no_error_log
[error]



=== TEST 2: a header sent once is still a plain string
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12841,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(type(res.headers["Set-Cookie"]))
            ngx.say(res.headers["Set-Cookie"])
        }
    }
--- tcp_listen: 12841
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nSet-Cookie: a=1\r\n\r\nhi"
--- request
GET /t
--- response_body
string
a=1
--- no_error_log
[error]



=== TEST 3: a name is looked up without regard to case, and "_" reads as "-"
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12842,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.headers["Content-Type"])
            ngx.say(res.headers["content-type"])
            ngx.say(res.headers["CONTENT-TYPE"])
            ngx.say(res.headers.content_type)
            ngx.say(res.headers["x-missing"] or "none")
        }
    }
--- tcp_listen: 12842
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nhi"
--- request
GET /t
--- response_body
text/plain
text/plain
text/plain
text/plain
none
--- no_error_log
[error]



=== TEST 4: a header repeated in another casing joins the same array
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12843,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            local values = res.headers["set-cookie"]
            ngx.say(#values, " ", table.concat(values, " | "))
        }
    }
--- tcp_listen: 12843
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
. "Set-Cookie: a=1\r\nset-cookie: b=2\r\nSET-COOKIE: c=3\r\n\r\nhi"
--- request
GET /t
--- response_body
3 a=1 | b=2 | c=3
--- no_error_log
[error]



=== TEST 5: the streaming path builds the same header table
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local httpc = client.new()
            httpc:set_timeouts(1000, 1000, 1000)

            local ok, err = httpc:connect({ host = "127.0.0.1", port = 12844 })
            if not ok then
                ngx.say(err)
                return
            end

            local res, rerr = httpc:request({ path = "/" })
            if not res then
                ngx.say(rerr)
                return
            end

            ngx.say(table.concat(res.headers.set_cookie, " | "))
            ngx.say(res.headers["content-length"])
            ngx.say(res:read_body())
            httpc:close()
        }
    }
--- tcp_listen: 12844
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
. "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nhi"
--- request
GET /t
--- response_body
a=1 | b=2
2
hi
--- no_error_log
[error]



=== TEST 6: a request header given as an array is sent once per value
--- http_config eval: $::HttpConfig
--- config
    location = /echo {
        content_by_lua_block {
            local values = ngx.req.get_headers()["X-Multi"]
            local body = type(values) == "table"
                         and table.concat(values, ",") or tostring(values)

            -- length framed, so the hand-written backend reads it too
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
                headers = { ["X-Multi"] = { "one", "two" } },
                timeout = 1000,
            })

            ngx.say(res and res.body or err)
        }
    }
--- request
GET /t
--- response_body
one,two
--- no_error_log
[error]



=== TEST 7: trailers keep the same shape as headers
--- skip_eval: 3: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12845,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.body)
            ngx.say(table.concat(res.trailers["x-checksum"], " | "))
        }
    }
--- tcp_listen: 12845
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
. "2\r\nhi\r\n0\r\nX-Checksum: aaa\r\nX-Checksum: bbb\r\n\r\n"
--- request
GET /t
--- response_body
hi
aaa | bbb
--- no_error_log
[error]
