use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3 - 1);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 0: C backend marker
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
c
--- no_error_log
[error]



=== TEST 1: GET content-length response
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
            ngx.say(res.headers["X-Mock"])
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



=== TEST 2: POST raw body and custom header
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



=== TEST 3: chunked response is rejected
--- http_config eval: $::HttpConfig
--- config
    location /chunked {
        content_by_lua_block {
            ngx.say("chunked")
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
--- response_body_like: chunked response is not supported
--- no_error_log
[error]



=== TEST 4: connection refused is stable nil err
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request({
                scheme = "http",
                host = "127.0.0.1",
                port = 1,
                method = "GET",
                path = "/",
                connect_timeout = 1000,
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
--- response_body_like: (connect failed|connection refused|Connection refused)
