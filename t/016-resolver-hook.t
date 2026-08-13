# The host application's resolver. None of these blocks configure nginx's
# `resolver`, so a name that reaches the wire at all proves the hook resolved
# it, and the Host header and the SNI prove the name survived the substitution.

use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

our $InitConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    init_by_lua_block {
        local client = require "resty.ngx_http_ffi_client"

        -- installed once at init, as a host application would, and yielding
        -- the way a Lua DNS client does
        client.set_resolver(function (host)
            ngx.sleep(0.001)
            return "127.0.0.1"
        end)
    }
};

our $TlsConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    server {
        listen 127.0.0.1:12899 ssl;
        ssl_certificate \$TEST_NGINX_SERVER_ROOT/html/tls.crt;
        ssl_certificate_key \$TEST_NGINX_SERVER_ROOT/html/tls.key;

        location /sni {
            content_by_lua_block {
                local body = (ngx.var.ssl_server_name or "none") .. "\\n"
                ngx.header["Content-Length"] = #body
                ngx.print(body)
            }
        }
    }
};

our $UserFiles = <<'_EOC_';
>>> tls.crt
-----BEGIN CERTIFICATE-----
MIIDKjCCAhKgAwIBAgIUMpoLE+76X2UdJn+TC1k80Qr6O0MwDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKdGVzdC5sb2NhbDAgFw0yNjA3MTUwODU2MDRaGA8yMTI2
MDYyMTA4NTYwNFowFTETMBEGA1UEAwwKdGVzdC5sb2NhbDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAMWo0WdpxTqswzXDnhsRpqby32slAR4BmzjXECvo
LHK1Oza+/8SCAo9r61HXl5fyy6cCll75MzEmZkLJy8vwmvCh5qTBBDt68eq6RbGH
FRlCNhjup2KvsXoUWfmOQC72PMYKg/faY8RoV40P9x/W57JvT5WSCf6O3/anre8g
ywokpH3QokPRdIEg3OE+OTAMcDV43mISXjWJWAtpJU71T/i0Iyxy5IBU01qXAjEe
WIy8fQLzPoK4WqiHH6jII9bB6ebDrWl5SW2CmrStb5lnMuf8OqXXomXBzTcfC3cu
CAREN2a3uZiAPryG4paTBD/3+dmyLDmjEmeFV2CQCSJ9bQkCAwEAAaNwMG4wHQYD
VR0OBBYEFIZZdTC230/zMtPUjW1CpizXxWGGMB8GA1UdIwQYMBaAFIZZdTC230/z
MtPUjW1CpizXxWGGMA8GA1UdEwEB/wQFMAMBAf8wGwYDVR0RBBQwEoIKdGVzdC5s
b2NhbIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAYv+q+iaGoJG1qStGFk/Ojhpa
aLXti7QV53aCaUpNbiKiCxtIC1ZqpaQAW+G5eM2dWC+7TCrqcMJuJjjp5c9mwolR
WHMqinfNUe/LCa3DsJvqYEkr1Dmy+iPabfP6Ni3UnWMehehTvX86jd4GjR7mTj6/
PC2D6x5gy+SFQSh+OMvtMkmYM91s21UIds5z9PhXDVzolH3kP3zaqtu646F1btIK
g5sdzjzunwEd5Av6hzaqYNu/ysbz6NiVcTOj8cA3RaktwvgBmWE2mRim2BO5bAXf
JE9Vloa+pp9bLzcwlTaU2zIZb2SadrMbNaNdh8lJ/iX5H3pSaNODNTThmw6BWA==
-----END CERTIFICATE-----
>>> tls.key
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDFqNFnacU6rMM1
w54bEaam8t9rJQEeAZs41xAr6CxytTs2vv/EggKPa+tR15eX8sunApZe+TMxJmZC
ycvL8JrwoeakwQQ7evHqukWxhxUZQjYY7qdir7F6FFn5jkAu9jzGCoP32mPEaFeN
D/cf1ueyb0+Vkgn+jt/2p63vIMsKJKR90KJD0XSBINzhPjkwDHA1eN5iEl41iVgL
aSVO9U/4tCMscuSAVNNalwIxHliMvH0C8z6CuFqohx+oyCPWwenmw61peUltgpq0
rW+ZZzLn/Dql16Jlwc03Hwt3LggERDdmt7mYgD68huKWkwQ/9/nZsiw5oxJnhVdg
kAkifW0JAgMBAAECggEAIAgKG1ygKjCKGAHh8tgK7j4op6fhBPhUq8Lqa3seDN7C
wE32i+VXvd9KzMIH3odpqmB4dt6ihaIH62XhYWTV7w4Fnwhqg6saXiQenDTcXfIF
a0ftl0gKllKK/C6pxxJ/acaVeUqKZW9VVNZUAXRlqtxwBLicZwTHVaT5wmlJjhR2
LA0+zqup5J4SxDAk9+p1SgykxhEPP/JkAyAtD39jeQ8uJWx/Rnq3SDLseGUs8qUM
sgHsa5PSHxEmnuM7/LOkO3v6EbkAQsy8hcRdBrXt5DUr1LSk7cmXQlODkQ1klpIU
lAbd+snLarh4+bHzbCfY2PoYy/uqYx7xmBc+FHsE8wKBgQDjj0d3b7KYX2jJWkuT
5o2HD9koRSTrhvuM9/fsYCfJ24QDkUF45OlSd61z7Q9BcfSp8KLuIVbnFOSP4Gim
ZZqOQu0wZffaBWVeXwBpCWNXO/8xuufPXIGaezH4IXZN/uIZWGY5PHHPgACLYSnf
6RXoTTMRCmyWwLip/8l1fCZYQwKBgQDeXOMtHttRaqXCgZY2vkJFd2MqYx+TzREK
1Nzna3vSrsMqvWrwxaONQQK6hphtrfxaB8DPhMWl+0bsrgrjB/7aLDDj7BxUeZPt
/trXRKE+rVMfXKAewvM1NO9to91pDjOOamkG7ih8gWfR4jE6qE0ONvCFwoDS6hQq
XsRUuFTmwwKBgQC4y7Eoz/+D9+8bnQVFLXR/WyJproUF888yMmkWfxuwtGBnmT1H
FPZZbzDftIKwDf+3ReC6az6sV+4o3P9/KYGyx6zgod3+ImWolpO5uNMAk4tw8iyv
25qwPh1dOKdfPX6VQJF7J5fw/yzyA0zDNgEBbjfrPcDjR8xu2Xbbvp9RCwKBgFG+
+jFTP7N9rnSEKVH0ve5FxqoFiM1QPSyrNo7JH9tDLjKfMhpTvh2mwbcK1iy0IqqC
YSqpF/Q+HUPTc+MkxFc2mb6gxYV0sKJ058Tt0Q12sLE93wuQBdMQo9i9vh7p/qAj
lHrcwPuMozswmYKD7tgD8IZsC+n97e3pqumuXl/7AoGAV88zb7UorfzYmilI12dR
dMEmcapTrGz0WTFrAnkMPOMo4haBswySqePfrG5oC/xa77Dw6/LOD8b1pmupeKvx
YrErqu4suZWhAa1m2pblIxAM3CA3l5ZZR8rF4w0Iau1OoUHDEATOTYETiitKuvFp
Ye/gbwb0N+OIZRCBROm7A70=
-----END PRIVATE KEY-----
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: the installed resolver answers for the one shot
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            -- the address was dialled, the name stayed in the Host header
            ngx.print(res.body == "test.local:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 2: an IP literal never reaches the resolver
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local calls = 0

            client.set_resolver(function (host)
                calls = calls + 1
                return "127.0.0.1"
            end)

            local res, err = client.request_uri({
                host = "127.0.0.1",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.say("calls: ", calls)
            ngx.print(res.body == "127.0.0.1:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
calls: 0
true
--- no_error_log
[error]



=== TEST 3: a resolver failure is a connect error
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return nil, "no answer"
            end)

            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            ngx.say(res == nil)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
true
test.local could not be resolved (no answer)
--- no_error_log
[error]



=== TEST 4: a caller Host still wins over the resolved name
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                headers = { ["Host"] = "example.test" },
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
example.test
--- no_error_log
[error]



=== TEST 5: resolver = false on the call leaves the name to nginx
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                resolver = false,
                timeout = 1000,
            })

            ngx.say(res == nil)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
true
no resolver defined to resolve "test.local"
--- no_error_log
[error]



=== TEST 6: the stateful connect resolves and keeps the name
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local httpc = client.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "test.local",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/echo" }))
            local body = assert(res:read_body())
            httpc:close()

            ngx.print(body == "test.local:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 7: the SNI keeps the name, so verification is against the name
--- http_config eval: $::TlsConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local res, err = client.request_uri({
                scheme = "https",
                host = "test.local",
                port = 12899,
                path = "/sni",
                ssl_verify = true,
                ssl_trusted_certificate =
                    "$TEST_NGINX_SERVER_ROOT/html/tls.crt",
                timeout = 2000,
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
test.local
--- no_error_log
[error]



=== TEST 8: two names on two addresses do not share a pooled connection
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = "hello\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local addresses = {
                ["one.test"] = "127.0.0.1",
                ["two.test"] = "127.0.0.2",
                ["also-one.test"] = "127.0.0.1",
            }

            client.set_resolver(function (host)
                return addresses[host]
            end)

            local function call(host)
                local httpc = client.new()
                httpc:set_timeout(1000)

                assert(httpc:connect({
                    host = host,
                    port = ngx.var.server_port,
                    pool_size = 4,
                }))

                local reused = httpc:get_reused_times()
                local res = assert(httpc:request({ path = "/echo" }))
                assert(res:read_body())
                assert(httpc:set_keepalive())

                return reused
            end

            call("one.test")
            -- a different address, so a pool of its own
            ngx.say("two.test: ", call("two.test"))
            -- the same address, so the pooled connection comes back
            ngx.say("also-one.test: ", call("also-one.test"))
        }
    }
--- request
GET /t
--- response_body
two.test: 0
also-one.test: 1
--- no_error_log
[error]



=== TEST 9: set_resolver refuses anything but a function or nil
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local ok, err = pcall(client.set_resolver, "resolver")
            ngx.say(ok)
            ngx.say(err:match("resolver must be a function or nil"))

            -- nil removes it: the name is nginx's to resolve again
            client.set_resolver(function (host) return "127.0.0.1" end)
            client.set_resolver(nil)

            local res, connect_err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            ngx.say(connect_err)
        }
    }
--- request
GET /t
--- response_body
false
resolver must be a function or nil
no resolver defined to resolve "test.local"
--- no_error_log
[error]



=== TEST 10: a resolver installed at init reaches the worker
--- http_config eval: $::InitConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body == "test.local:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 11: the stateful object takes the same resolver, yields and all
--- http_config eval: $::InitConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local httpc = client.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "test.local",
                port = ngx.var.server_port,
            }))

            local res = assert(httpc:request({ path = "/echo" }))
            local body = assert(res:read_body())
            httpc:close()

            ngx.print(body == "test.local:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 12: an address the resolver answers with may be IPv6
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    listen [::1]:$TEST_NGINX_SERVER_PORT;

    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "::1"
            end)

            local res, err = client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                timeout = 1000,
            })

            if not res then
                ngx.say(err)
                return
            end

            ngx.print(res.body == "test.local:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true
--- no_error_log
[error]



=== TEST 13: a name the resolver would answer for is still held to the host rule
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            -- a space is legal in a header value, so a resolved name must be
            -- refused here rather than reaching the peer as a malformed Host
            local res, err = client.request_uri({
                host = "127.0.0.1 evil",
                port = ngx.var.server_port,
                path = "/",
                timeout = 1000,
            })

            ngx.say(res and ("unexpected " .. res.status) or err)

            local httpc = client.new()
            httpc:set_timeout(1000)

            local ok, connect_err = httpc:connect({
                host = "127.0.0.1 evil",
                port = ngx.var.server_port,
            })

            ngx.say(ok == nil)
            ngx.say(connect_err)
        }
    }
--- request
GET /t
--- response_body
invalid host
true
invalid host
--- no_error_log
[error]



=== TEST 14: a CRLF name never reaches the wire
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            for _, host in ipairs({ "evil\r\nX-Injected: 1",
                                    "evil\r\nX-Injected 1" }) do
                local res, err = client.request_uri({
                    host = host,
                    port = ngx.var.server_port,
                    path = "/",
                    timeout = 1000,
                })

                ngx.say(res and ("unexpected " .. res.status) or err)
            end
        }
    }
--- request
GET /t
--- response_body
invalid host
invalid host
--- no_error_log
[error]



=== TEST 15: a per-call resolver overrides the installed one
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    listen 127.0.0.2:$TEST_NGINX_SERVER_PORT;

    location /echo {
        content_by_lua_block {
            local body = ngx.var.server_addr .. " " .. ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local function per_call(host)
                return "127.0.0.2"
            end

            local res = assert(client.request_uri({
                host = "test.local",
                port = ngx.var.server_port,
                path = "/echo",
                resolver = per_call,
                timeout = 1000,
            }))

            local httpc = client.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "test.local",
                port = ngx.var.server_port,
                resolver = per_call,
            }))

            local stateful = assert(httpc:request({ path = "/echo" }))
            local body = assert(stateful:read_body())
            httpc:close()

            -- the per-call address was dialled on both entry points
            local want = "127.0.0.2 test.local:" .. ngx.var.server_port .. "\n"
            ngx.say(res.body == want)
            ngx.print(body == want)
        }
    }
--- request
GET /t
--- response_body chomp
true
true
--- no_error_log
[error]



=== TEST 16: a refused reconnect leaves the live connection its own Host
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /echo {
        content_by_lua_block {
            local body = ngx.var.http_host .. "\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            client.set_resolver(function (host)
                return "127.0.0.1"
            end)

            local httpc = client.new()
            httpc:set_timeout(1000)

            assert(httpc:connect({
                host = "127.0.0.1",
                port = ngx.var.server_port,
            }))

            -- refused, and the connection above is still the live one
            local ok, err = httpc:connect({
                host = "test.local",
                port = ngx.var.server_port,
            })
            ngx.say(ok == nil, " ", err)

            local res = assert(httpc:request({ path = "/echo" }))
            local body = assert(res:read_body())
            httpc:close()

            ngx.print(body == "127.0.0.1:" .. ngx.var.server_port .. "\n")
        }
    }
--- request
GET /t
--- response_body chomp
true already connected
true
--- no_error_log
[error]
