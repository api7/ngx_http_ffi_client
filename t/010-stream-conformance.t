# Streaming cases ported from api7/lua-resty-http t/05-stream.t, run against
# this module as a conformance oracle. Only `require` and the module name
# differ.
#
# Cases from that file that are not ported, and why:
#   - TEST 2b / 4 / 5 pass a max size to body_reader. A sized read is the
#     `res:read([size])` API designed in #12, not part of this slice.
#   - TEST 3 / 4 / 4b send `version = 1.0` requests. This client always speaks
#     HTTP/1.1 on the wire; TEST 4b's close-framed *response* is covered here as
#     TEST 3 instead.
#   - TEST 6 / 7 / 8 / 10 exercise the request-side (client body) reader, which
#     this module does not expose.
#   - TEST 9 issues a HEAD request. HEAD-response body suppression is not wired
#     (llhttp cannot infer the request method from the response alone).
#
# Every case here runs on the llhttp backend only: they are framed by chunked
# encoding or by the connection close, and the hand-written fallback parser
# accepts content-length framing only.
#
# The chunk-count assertions in the upstream file (`#chunks`) are dropped on
# purpose: they encode lua-resty-http's blocking `receive(n)`, while this reader
# returns what has arrived (see #12), so the slice count is timing-dependent.

use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 4);

our $UseLLHTTP = !defined($ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP})
    || $ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP} eq ''
    || $ENV{NGX_HTTP_FFI_CLIENT_USE_LLHTTP} eq '1';

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: chunked streaming body reader returns the right content length
--- skip_eval: 4: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })

            local res, err = httpc:request{
                path = "/b",
            }

            local chunks = {}
            repeat
                local chunk = res.body_reader()
                if chunk then
                    table.insert(chunks, chunk)
                end
            until not chunk

            local body = table.concat(chunks)
            ngx.say(#body)
            ngx.say(res.headers["Transfer-Encoding"])

            httpc:close()
        }
    }

    location = /b {
        content_by_lua_block {
            local len = 32768
            local t = {}
            for i = 1, len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        }
    }
--- request
GET /a
--- response_body
32768
chunked
--- no_error_log
[error]
[warn]



=== TEST 2: non-chunked streaming body reader returns the right content length
--- skip_eval: 4: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })

            local res, err = httpc:request{
                path = "/b",
            }

            local chunks = {}
            repeat
                local chunk = res.body_reader()
                if chunk then
                    table.insert(chunks, chunk)
                end
            until not chunk

            local body = table.concat(chunks)
            ngx.say(#body)
            ngx.say(res.headers["Transfer-Encoding"])

            httpc:close()
        }
    }

    location = /b {
        chunked_transfer_encoding off;
        content_by_lua_block {
            local len = 32768
            local t = {}
            for i = 1, len do
                t[i] = 0
            end
            ngx.print(table.concat(t))
        }
    }
--- request
GET /a
--- response_body
32768
nil
--- no_error_log
[error]
[warn]



=== TEST 3: a close-framed response streams to the end of the connection
--- skip_eval: 4: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
            })

            local res, err = httpc:request{
                path = "/b",
            }

            local chunks = {}
            repeat
                local chunk = res.body_reader()
                if chunk then
                    table.insert(chunks, chunk)
                end
            until not chunk

            local body = table.concat(chunks)
            ngx.say(#body)

            httpc:close()
        }
    }

    location = /b {
        content_by_lua_block {
            ngx.req.read_body()
            local sock, err = ngx.req.socket(true)
            if not sock then
                ngx.say(err)
                return
            end

            local res = {}
            table.insert(res, "HTTP/1.0 200 OK")
            table.insert(res, "Date: " .. ngx.http_time(ngx.time()))
            table.insert(res, "")

            local len = 32769
            local t = {}
            for i = 1, len do
                t[i] = 0
            end
            table.insert(res, table.concat(t))

            sock:send(table.concat(res, "\r\n"))
        }
    }
--- request
GET /a
--- response_body
32769
--- no_error_log
[error]
[warn]
