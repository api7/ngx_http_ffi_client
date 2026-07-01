use Test::Nginx::Socket -Base;

if (($ENV{NGX_HTTP_FFI_CLIENT_BACKEND} || "") ne "hyper") {
    plan skip_all => "hyper backend only";
}

if (($ENV{NGX_HTTP_FFI_CLIENT_HYPER_KEEPALIVE_BENCH} || "") ne "1") {
    plan skip_all => "hyper keepalive benchmark build only";
}

repeat_each(1);
plan tests => repeat_each() * blocks() * 3;

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: hyper benchmark keepalive reuses clean connection
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
                    pool = "hyper-bench-reuse",
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
second:true
--- no_error_log
[error]
