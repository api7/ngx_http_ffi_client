# Response-framing cases: how the client decides where a message body starts,
# ends, and whether there is one at all.
#
# Most cases drive a raw TCP mock so the response bytes are exactly what the
# test says. Cases framed by chunked encoding run on the llhttp backend only;
# the hand-written fallback accepts content-length and close framing.

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

=== TEST 1: HEAD ignores the announced content-length instead of waiting for it
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12811,
                method = "HEAD",
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(#res.body)
            ngx.say(res.headers["Content-Length"])
        }
    }
--- tcp_listen: 12811
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n"
--- request
GET /t
--- response_body
200
0
42
--- no_error_log
[error]



=== TEST 2: HEAD is bodyless on the streaming path too
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12812 }))

            local res, err = httpc:request({ method = "HEAD", path = "/" })
            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(#assert(res:read_body()))

            httpc:close()
        }
    }
--- tcp_listen: 12812
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n"
--- request
GET /t
--- response_body
200
0
--- no_error_log
[error]



=== TEST 3: 204 has no body
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12813,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(#res.body)
        }
    }
--- tcp_listen: 12813
--- tcp_reply eval
"HTTP/1.1 204 No Content\r\n\r\n"
--- request
GET /t
--- response_body
204
0
--- no_error_log
[error]



=== TEST 4: 304 keeps its headers and drops the announced body
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12814,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(#res.body)
            ngx.say(res.headers["ETag"])
        }
    }
--- tcp_listen: 12814
--- tcp_reply eval
"HTTP/1.1 304 Not Modified\r\nContent-Length: 100\r\nETag: \"v1\"\r\n\r\n"
--- request
GET /t
--- response_body
304
0
"v1"
--- no_error_log
[error]



=== TEST 5: chunked trailers are kept out of the response headers
--- skip_eval: 3: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12815 }))

            local res = assert(httpc:request({ path = "/" }))

            ngx.say(assert(res:read_body()))
            ngx.say(res.headers["Trailer"])
            ngx.say(res.headers["X-Checksum"] == nil)
            ngx.say(res.trailers["X-Checksum"])

            httpc:close()
        }
    }
--- tcp_listen: 12815
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc123\r\n\r\n"
--- request
GET /t
--- response_body
hello
X-Checksum
true
abc123
--- no_error_log
[error]



=== TEST 6: the buffered path reports trailers too
--- skip_eval: 3: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12816 }))

            local res = assert(httpc:request({
                path = "/",
                preread_body = true,
            }))

            ngx.say(res.body)
            ngx.say(res.headers["X-Checksum"] == nil)
            ngx.say(res.trailers["X-Checksum"])

            httpc:close()
        }
    }
--- tcp_listen: 12816
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nfoo\r\n3\r\nbar\r\n0\r\nX-Checksum: zz\r\n\r\n"
--- request
GET /t
--- response_body
foobar
true
zz
--- no_error_log
[error]



=== TEST 7: a close-framed response is complete, not truncated
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12817,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(res.body)
        }
    }
--- tcp_listen: 12817
--- tcp_reply eval
"HTTP/1.0 200 OK\r\n\r\nclose-framed body"
--- request
GET /t
--- response_body
200
close-framed body
--- no_error_log
[error]



=== TEST 8: a content-length body cut short by the close is an error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12818,
                path = "/",
                timeout = 1000,
            })

            if res then
                ngx.say("unexpected body: ", res.body)
                return
            end

            ngx.say(err)
        }
    }
--- tcp_listen: 12818
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort"
--- request
GET /t
--- response_body
upstream closed before complete response
--- no_error_log
[error]



=== TEST 9: a response that says Connection: close never goes back to the pool
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({ host = "127.0.0.1", port = 12819 }))

            local res = assert(httpc:request({ path = "/" }))
            ngx.say(assert(res:read_body()))

            local ok, err = httpc:set_keepalive()
            ngx.say(ok or err)
        }
    }
--- tcp_listen: 12819
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
--- request
GET /t
--- response_body
hi
connection not reusable
--- no_error_log
[error]



=== TEST 10: content-length next to transfer-encoding is refused
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12820,
                path = "/",
                timeout = 1000,
            })

            if res then
                ngx.say("unexpected success: ", res.body)
                return
            end

            ngx.say(err)
        }
    }
--- tcp_listen: 12820
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
--- request
GET /t
--- response_body_like: (Transfer-Encoding can't be present with Content-Length|chunked response is not supported)
--- no_error_log
[error]



=== TEST 11: a chunk size that is not a hex number is refused
--- skip_eval: 3: !$::UseLLHTTP
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12821,
                path = "/",
                timeout = 1000,
            })

            if res then
                ngx.say("unexpected success: ", res.body)
                return
            end

            ngx.say(err)
        }
    }
--- tcp_listen: 12821
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n"
--- request
GET /t
--- response_body_like: chunk size
--- no_error_log
[error]



=== TEST 12: a caller-supplied Transfer-Encoding never reaches the wire
--- http_config eval: $::HttpConfig
--- config
    location /echo {
        content_by_lua_block {
            local body = (ngx.var.http_transfer_encoding or "none") .. "\n"
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
                headers = { ["Transfer-Encoding"] = "chunked" },
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
none
--- no_error_log
[error]



=== TEST 13: a read timeout reports the error lua-resty-http callers match on
--- http_config eval: $::HttpConfig
--- config
    location /slow {
        content_by_lua_block {
            ngx.sleep(1)
            ngx.header["Content-Length"] = 2
            ngx.print("ok")
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/slow",
                read_timeout = 200,
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
timeout
--- no_error_log
[error]



=== TEST 14: a second response behind the first is refused, not merged in
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12822,
                path = "/",
                timeout = 1000,
            })

            if res then
                ngx.say("unexpected success: ", res.body)
                return
            end

            ngx.say(err)
        }
    }
--- tcp_listen: 12822
--- tcp_reply eval
"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
. "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nevil!"
--- request
GET /t
--- response_body_like: (unexpected second response|larger than content-length)
--- no_error_log
[error]



=== TEST 15: an interim response is consumed and the final one is the answer
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12823,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status, " ", res.body)
        }
    }
--- tcp_listen: 12823
--- tcp_reply eval
"HTTP/1.1 100 Continue\r\n\r\n"
. "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal"
--- request
GET /t
--- response_body
200 final
--- no_error_log
[error]



=== TEST 16: an interim response arriving in its own read is consumed too
--- http_config eval: $::HttpConfig
--- config
    location = /interim {
        content_by_lua_block {
            ngx.req.read_body()
            local sock = assert(ngx.req.socket(true))

            -- the sleep splits the two messages across separate reads, so the
            -- parser has to carry the interim state from one read to the next
            sock:send("HTTP/1.1 100 Continue\r\n\r\n")
            ngx.sleep(0.1)
            pcall(sock.send, sock,
                  "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal")
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/interim",
                timeout = 1000,
            })

            ngx.say(res and (res.status .. " " .. res.body) or err)
        }
    }
--- request
GET /t
--- response_body
200 final
--- no_error_log
[error]



=== TEST 17: the headers of an interim response stay out of the final one
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12824,
                path = "/",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say("link: ", res.headers["Link"] or "none")
            ngx.say("x-final: ", res.headers["X-Final"] or "none")
            ngx.say(res.body)
        }
    }
--- tcp_listen: 12824
--- tcp_reply eval
"HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n"
. "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Final: yes\r\n\r\nhi"
--- request
GET /t
--- response_body
200
link: none
x-final: yes
hi
--- no_error_log
[error]



=== TEST 18: the streaming path skips interim responses as well
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local httpc = client.new()
            httpc:set_timeouts(1000, 1000, 1000)

            local ok, err = httpc:connect({ host = "127.0.0.1", port = 12825 })
            if not ok then
                ngx.say(err)
                return
            end

            local res, rerr = httpc:request({ path = "/" })
            if not res then
                ngx.say(rerr)
                return
            end

            ngx.say(res.status, " ", assert(res:read_body()))
            httpc:close()
        }
    }
--- tcp_listen: 12825
--- tcp_reply eval
"HTTP/1.1 100 Continue\r\n\r\n"
. "HTTP/1.1 100 Continue\r\n\r\n"
. "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nstream"
--- request
GET /t
--- response_body
200 stream
--- no_error_log
[error]



=== TEST 19: a 101 is refused: the connection stops speaking HTTP after it
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12826,
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)
        }
    }
--- tcp_listen: 12826
--- tcp_reply eval
"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
. "Connection: Upgrade\r\n\r\n"
--- request
GET /t
--- response_body
protocol switch is not supported
--- no_error_log
[error]



=== TEST 20: a connection that carried an interim response is still poolable
--- http_config eval: $::HttpConfig
--- config
    location = /expect {
        content_by_lua_block {
            -- reading the body is what makes nginx answer the Expect header
            -- with its own 100 Continue ahead of this response
            ngx.req.read_body()
            ngx.header["Content-Length"] = 2
            ngx.print("ok")
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            -- a stranded final response would be handed to the second request
            -- as if it were its own
            for i = 1, 2 do
                local res, err = client.request_uri({
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    method = "POST",
                    path = "/expect",
                    headers = { ["Expect"] = "100-continue" },
                    body = "hello",
                    keepalive = { pool_size = 4 },
                    timeout = 1000,
                })

                if not res then
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " reused=", tostring(res.reused), " ",
                        res.body)
            end
        }
    }
--- request
GET /t
--- response_body
200 reused=false ok
200 reused=true ok
--- no_error_log
[error]



=== TEST 21: a stream of interim responses is cut off instead of followed
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12827,
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)
        }
    }
--- tcp_listen: 12827
--- tcp_reply eval
("HTTP/1.1 100 Continue\r\n\r\n" x 9)
. "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal"
--- request
GET /t
--- response_body
too many interim responses
--- no_error_log
[error]



=== TEST 22: a status below 100 is refused rather than read as interim
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 12828,
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)
        }
    }
--- tcp_listen: 12828
--- tcp_reply eval
"HTTP/1.1 042 Bogus\r\n\r\n"
--- request
GET /t
--- response_body
invalid response status
--- no_error_log
[error]



=== TEST 23: a refused connect reports the socket error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = 1,
                path = "/",
                connect_timeout = 1000,
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
--- response_body_like: (?i)connection refused
--- no_error_log
[crit]
