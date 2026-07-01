use Test::Nginx::Socket -Base;

if (($ENV{NGX_HTTP_FFI_CLIENT_BACKEND} || "") ne "hyper") {
    plan skip_all => "hyper backend only";
}

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3 - 1);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 0: hyper backend marker
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            ngx.say(client.backend())
        }
    }
--- request
GET /t
--- response_body
hyper
--- no_error_log
[error]



=== TEST 1: hyper GET content-length response
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
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "GET",
                path = "/mock",
            })

            if not res then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.say(res.headers["X-Mock"] or res.headers["x-mock"])
            ngx.print(res.body)
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



=== TEST 2: hyper POST raw body and custom header
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
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "POST",
                path = "/echo",
                headers = {
                    ["X-Client-Test"] = "sent",
                },
                body = "payload",
            })

            if not res then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body eval: "POST\nsent\npayload"
--- no_error_log
[error]



=== TEST 3: hyper accepts chunked response
--- http_config eval: $::HttpConfig
--- config
    location /chunked {
        content_by_lua_block {
            ngx.print("chunked")
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "GET",
                path = "/chunked",
            })

            if not res then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body eval: "chunked"
--- no_error_log
[error]



=== TEST 4: hyper keepalive does not reuse current POC connection
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "ok\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local opts = {
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "GET",
                path = "/mock",
                keepalive = {
                    pool = "hyper-no-reuse",
                    idle_timeout = 60000,
                    pool_size = 2,
                },
            }

            local first, err = client.request(opts)
            if not first then
                ngx.status = 500
                ngx.say(err)
                return
            end

            local second
            second, err = client.request(opts)
            if not second then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.say("first:" .. tostring(first.reused))
            ngx.say("second:" .. tostring(second.reused))
        }
    }
--- request
GET /t
--- response_body
first:false
second:false
--- no_error_log
[error]



=== TEST 5: hyper incomplete response returns nil err
--- http_config eval: $::HttpConfig
--- config
    location /incomplete {
        content_by_lua_block {
            ngx.header["Content-Length"] = 16
            ngx.print("short")
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request({
                scheme = "http",
                host = "127.0.0.1",
                port = ngx.var.server_port,
                method = "GET",
                path = "/incomplete",
            })

            if res then
                ngx.status = 500
                ngx.say("unexpected success")
                return
            end

            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body_like: (error reading a body from connection|end of file before message length reached|upstream closed before complete response|body write aborted)
