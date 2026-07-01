use Test::Nginx::Socket -Base;

if (($ENV{NGX_HTTP_FFI_CLIENT_BACKEND} || "") ne "hyper") {
    plan skip_all => "hyper backend only";
}

if (($ENV{NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH} || "") ne "1") {
    plan skip_all => "hyper session benchmark build only";
}

repeat_each(1);
plan tests => repeat_each() * blocks() * 3;

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: hyper benchmark session reuses engine across keepalive requests
--- http_config eval: $::HttpConfig
--- config
    location /mock-one {
        content_by_lua_block {
            local body = "one\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /mock-two {
        content_by_lua_block {
            local body = "two\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /mock-three {
        content_by_lua_block {
            local body = "three\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local function request(path)
                return client.request({
                    scheme = "http",
                    host = "127.0.0.1",
                    port = ngx.var.server_port,
                    method = "GET",
                    path = path,
                    keepalive = {
                        pool = "hyper-session-reuse",
                        idle_timeout = 60000,
                        pool_size = 2,
                    },
                })
            end

            local first, err = request("/mock-one")
            if not first then
                ngx.status = 500
                ngx.say(err)
                return
            end

            local second
            second, err = request("/mock-two")
            if not second then
                ngx.status = 500
                ngx.say(err)
                return
            end

            local third
            third, err = request("/mock-three")
            if not third then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.say("first:" .. tostring(first.reused) .. ":" .. first.body)
            ngx.say("second:" .. tostring(second.reused) .. ":" .. second.body)
            ngx.print("third:" .. tostring(third.reused) .. ":" .. third.body)
        }
    }
--- request
GET /t
--- response_body
first:false:one

second:true:two

third:true:three
--- no_error_log
[error]
