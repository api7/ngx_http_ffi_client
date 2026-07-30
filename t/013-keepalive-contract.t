use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * blocks() * 3;

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

no_long_string();
run_tests();

__DATA__

=== TEST 1: idle timeout closes a pooled connection
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function once()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "idle-expiry",
                }))

                local res = assert(httpc:request({ path = "/mock" }))
                assert(res:read_body() == "ok\n")

                local reused = httpc:get_reused_times()
                assert(httpc:set_keepalive(50))

                return reused
            end

            local first = once()
            ngx.sleep(0.15)
            local second = once()

            ngx.say(first, " ", second)
        }
    }
--- request
GET /t
--- response_body
0 0
--- no_error_log
[error]



=== TEST 2: idle timeout 0 parks the connection with no expiry
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function once()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "never-expires",
                }))

                local res = assert(httpc:request({ path = "/mock" }))
                assert(res:read_body() == "ok\n")

                local reused = httpc:get_reused_times()
                assert(httpc:set_keepalive(0))

                return reused
            end

            local first = once()
            ngx.sleep(0.15)
            local second = once()

            ngx.say(first, " ", second)
        }
    }
--- request
GET /t
--- response_body
0 1
--- no_error_log
[error]



=== TEST 3: set_keepalive pool_size caps the pool
--- http_config eval: $::HttpConfig
--- config
    location /id {
        content_by_lua_block {
            local b = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function open()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "cap-one",
                }))

                local res = assert(httpc:request({ path = "/id" }))
                res:read_body()

                return httpc
            end

            -- two live connections, then one pool slot to park them in
            local c1 = open()
            local c2 = open()

            assert(c1:set_keepalive(10000, 1))
            assert(c2:set_keepalive(10000, 1))

            local reused = {}

            for i = 1, 2 do
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "cap-one",
                }))

                reused[i] = httpc:get_reused_times()
                httpc:close()
            end

            ngx.say(reused[1], " ", reused[2])
        }
    }
--- request
GET /t
--- response_body
1 0
--- no_error_log
[error]



=== TEST 4: a pool sized for two keeps both connections
--- http_config eval: $::HttpConfig
--- config
    location /id {
        content_by_lua_block {
            local b = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function open()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "cap-two",
                }))

                local res = assert(httpc:request({ path = "/id" }))
                res:read_body()

                return httpc
            end

            local c1 = open()
            local c2 = open()

            assert(c1:set_keepalive(10000, 2))
            assert(c2:set_keepalive(10000, 2))

            local reused = {}

            for i = 1, 3 do
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "cap-two",
                }))

                reused[i] = httpc:get_reused_times()
                httpc:close()
            end

            ngx.say(reused[1], " ", reused[2], " ", reused[3])
        }
    }
--- request
GET /t
--- response_body
1 1 0
--- no_error_log
[error]



=== TEST 5: a full pool evicts the least recently used connection
--- http_config eval: $::HttpConfig
--- config
    location /id {
        content_by_lua_block {
            local b = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function open()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "lru",
                }))

                local res = assert(httpc:request({ path = "/id" }))
                local id = res:read_body():gsub("%s+$", "")

                return httpc, id
            end

            -- three distinct connections for a pool that holds two
            local c1, id1 = open()
            local c2, id2 = open()
            local c3, id3 = open()

            assert(c1:set_keepalive(10000, 2))
            assert(c2:set_keepalive(10000, 2))
            -- the pool is full, so this drops the oldest entry: c1
            assert(c3:set_keepalive(10000, 2))

            local ids = {}

            for i = 1, 2 do
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "lru",
                }))

                local res = assert(httpc:request({ path = "/id" }))
                ids[i] = res:read_body():gsub("%s+$", "")
                httpc:close()
            end

            ngx.say("distinct:", id1 ~= id2 and id2 ~= id3 and id1 ~= id3)
            ngx.say("evicted:", ids[1] ~= id1 and ids[2] ~= id1)
            ngx.say("kept:", ids[1] == id3 and ids[2] == id2)
        }
    }
--- request
GET /t
--- response_body
distinct:true
evicted:true
kept:true
--- no_error_log
[error]



=== TEST 6: the pool keeps the size it was created with
--- http_config eval: $::HttpConfig
--- config
    location /id {
        content_by_lua_block {
            local b = ngx.var.connection .. "\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port

            local function open()
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "first-writer",
                    pool_size = 1,
                }))

                local res = assert(httpc:request({ path = "/id" }))
                res:read_body()

                return httpc
            end

            -- connect sized this pool at one, so the ten asked for below is not
            -- what it holds
            local c1 = open()
            local c2 = open()

            assert(c1:set_keepalive(10000, 10))
            assert(c2:set_keepalive(10000, 10))

            local reused = {}

            for i = 1, 2 do
                local httpc = http.new()
                assert(httpc:connect({
                    host = "127.0.0.1",
                    port = port,
                    pool = "first-writer",
                    pool_size = 1,
                }))

                reused[i] = httpc:get_reused_times()
                httpc:close()
            end

            ngx.say(reused[1], " ", reused[2])
        }
    }
--- request
GET /t
--- response_body
1 0
--- no_error_log
[error]



=== TEST 7: set_keepalive rejects a bad timeout and a bad pool size
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local b = "ok\n"
            ngx.header["Content-Length"] = #b
            ngx.print(b)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/mock" }))
            res:read_body()

            local ok, err = httpc:set_keepalive(-1)
            ngx.say(ok and "unexpected" or err)

            ok, err = httpc:set_keepalive(1000, 0)
            ngx.say(ok and "unexpected" or err)

            ok, err = httpc:set_keepalive("soon")
            ngx.say(ok and "unexpected" or err)

            -- the connection survived all three, so it can still be parked
            ngx.say(httpc:set_keepalive())
        }
    }
--- request
GET /t
--- response_body
bad timeout
bad pool_size
bad timeout
1
--- no_error_log
[error]
