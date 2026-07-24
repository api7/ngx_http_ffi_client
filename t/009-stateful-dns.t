use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    resolver 127.0.0.1:1953 ipv6=off;
    resolver_timeout 1s;
};

our $NoResolverConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

# The stub answers every question with 127.0.0.1, echoing the query id and the
# question section back so the nginx resolver accepts the response.
our $DnsReply = sub {
    my $req = shift;
    my $id = substr($req, 0, 2);
    my $question = substr($req, 12);

    return $id . pack("nnnnn", 0x8180, 1, 1, 0, 0) . $question
           . pack("nnnNn", 0xc00c, 1, 1, 300, 4) . pack("C4", 127, 0, 0, 1);
};

no_long_string();
run_tests();


__DATA__

=== TEST 1: the stateful connect resolves a hostname
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "hello\n"
            ngx.header["Content-Length"] = #body
            ngx.header["X-Host"] = ngx.var.http_host
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()
            httpc:set_timeout(2000)

            local ok, err = httpc:connect({
                host = "test.local",
                port = ngx.var.server_port,
            })
            if not ok then
                ngx.status = 500
                ngx.say("connect: ", err)
                return
            end

            local res = assert(httpc:request({ path = "/mock" }))

            ngx.say(res.status)
            -- the Host header carries the name, not the resolved address
            ngx.say(res.headers["X-Host"]
                    == "test.local:" .. ngx.var.server_port)
            ngx.print(res:read_body())
            httpc:close()
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- request
GET /t
--- response_body
200
true
hello
--- no_error_log
[error]



=== TEST 2: a pooled connection costs no second lookup
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "pooled\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local port = ngx.var.server_port
            local out = {}

            -- the stub serves exactly one datagram, so a second lookup would
            -- time out instead of coming back
            for i = 1, 2 do
                local httpc = http.new()
                httpc:set_timeout(2000)

                local ok, err = httpc:connect({ host = "test.local", port = port })
                if not ok then
                    ngx.status = 500
                    ngx.say("connect ", i, ": ", err)
                    return
                end

                local res = assert(httpc:request({ path = "/mock" }))
                assert(res:read_body() == "pooled\n")

                out[i] = httpc:get_reused_times()
                assert(httpc:set_keepalive())
            end

            ngx.say(table.concat(out, ","))
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- request
GET /t
--- response_body
0,1
--- no_error_log
[error]



=== TEST 3: connecting without a resolver fails cleanly
--- http_config eval: $::NoResolverConfig
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.ngx_http_ffi_client"
            local httpc = http.new()

            local ok, err = httpc:connect({ host = "test.local", port = 80 })
            ngx.say(ok and "unexpected" or err)
        }
    }
--- request
GET /t
--- response_body
no resolver defined to resolve "test.local"
--- no_error_log
[error]
