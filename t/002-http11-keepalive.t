use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * blocks() * 3;

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: same host and port reuses keepalive connection
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



=== TEST 4: upstream idle close is not reused
--- http_config eval: $::HttpConfig
--- config
    keepalive_timeout 50ms;

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
                    pool = "upstream-idle-close",
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

            ngx.sleep(0.12)

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



=== TEST 3: pool size one evicts older idle connection
--- http_config eval: $::HttpConfig
--- config
    location /slow1 {
        content_by_lua_block {
            ngx.sleep(0.05)
            local body = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /slow2 {
        content_by_lua_block {
            ngx.sleep(0.12)
            local body = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /id {
        content_by_lua_block {
            local body = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /close_id {
        content_by_lua_block {
            local body = ngx.var.connection .. "\n"
            ngx.header["Connection"] = "close"
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
                        pool = "pool-size-one",
                        idle_timeout = 60000,
                        pool_size = 1,
                    },
                })
            end

            local th1 = ngx.thread.spawn(request, "/slow1")
            local th2 = ngx.thread.spawn(request, "/slow2")

            local ok1, res1, err1 = ngx.thread.wait(th1)
            if not ok1 or not res1 then
                ngx.status = 500
                ngx.say(err1 or res1)
                return
            end

            local ok2, res2, err2 = ngx.thread.wait(th2)
            if not ok2 or not res2 then
                ngx.status = 500
                ngx.say(err2 or res2)
                return
            end

            local latest_id = res2.body:gsub("%s+$", "")
            local close_res, err = request("/close_id")
            if not close_res then
                ngx.status = 500
                ngx.say(err)
                return
            end

            local close_id = close_res.body:gsub("%s+$", "")
            local after, after_err = request("/id")
            if not after then
                ngx.status = 500
                ngx.say(after_err)
                return
            end

            ngx.say("latest:" .. tostring(close_res.reused
                and close_id == latest_id))
            ngx.say("after_close:" .. tostring(after.reused))
        }
    }
--- request
GET /t
--- response_body
latest:true
after_close:false
--- no_error_log
[error]



=== TEST 2: idle timeout closes cached connection
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
                    idle_timeout = 50,
                    pool_size = 2,
                },
            }

            local first, err = client.request(opts)
            if not first then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.sleep(0.12)

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
