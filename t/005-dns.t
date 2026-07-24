use Test::Nginx::Socket -Base;

repeat_each(1);
# the aborted block checks the error log only
plan tests => repeat_each() * (blocks() * 3 - 2);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    resolver 127.0.0.1:1953 ipv6=off;
    resolver_timeout 1s;
};

our $NoResolverConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
};

our $TlsConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    resolver 127.0.0.1:1953 ipv6=off;
    resolver_timeout 1s;

    server {
        listen 127.0.0.1:12499 ssl;
        ssl_certificate \$TEST_NGINX_SERVER_ROOT/html/tls.crt;
        ssl_certificate_key \$TEST_NGINX_SERVER_ROOT/html/tls.key;

        location / {
            content_by_lua_block {
                local body = "secure\\n"
                ngx.header["Content-Length"] = #body
                ngx.print(body)
            }
        }
    }
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

# NXDOMAIN: no answer records, rcode 3.
our $DnsNxDomain = sub {
    my $req = shift;
    my $id = substr($req, 0, 2);
    my $question = substr($req, 12);

    return $id . pack("nnnnn", 0x8183, 1, 0, 0, 0) . $question;
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

=== TEST 1: a hostname is resolved and connected to
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
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "http",
                host = "test.local",
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
            -- the Host header carries the name, not the resolved address
            ngx.say(res.headers["X-Host"]
                    == "test.local:" .. ngx.var.server_port)
            ngx.print(res.body)
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



=== TEST 2: an IP literal never goes through the resolver
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "direct\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
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
            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
200
direct
--- no_error_log
[error]



=== TEST 3: a resolve failure returns a clean error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "http",
                host = "missing.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/",
            })

            if res then
                ngx.status = 500
                ngx.say("unexpected success")
                return
            end

            ngx.say(err)
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsNxDomain
--- request
GET /t
--- response_body
missing.local could not be resolved (3: Host not found)
--- no_error_log
[error]



=== TEST 4: a resolver timeout returns a clean error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "http",
                host = "slow.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/",
            })

            if res then
                ngx.status = 500
                ngx.say("unexpected success")
                return
            end

            ngx.say(err)
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- udp_reply_delay: 3s
--- request
GET /t
--- response_body_like: slow\.local could not be resolved
--- no_error_log
[error]



=== TEST 5: a hostname without a resolver is rejected
--- http_config eval: $::NoResolverConfig
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "http",
                host = "test.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/",
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
--- response_body
no resolver defined to resolve "test.local"
--- no_error_log
[error]



=== TEST 6: a pooled connection is reused without a second lookup
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
            local client = require "resty.ngx_http_ffi_client"

            local opts = {
                scheme = "http",
                host = "test.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/mock",
                keepalive = { pool_size = 4, idle_timeout = 60000 },
            }

            local r1, err = client.request_uri(opts)
            if not r1 then
                ngx.status = 500
                ngx.say(err)
                return
            end

            local r2, err2 = client.request_uri(opts)
            if not r2 then
                ngx.status = 500
                ngx.say(err2)
                return
            end

            ngx.say(r1.status)
            ngx.say(r1.reused)
            ngx.say(r2.reused)
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- request
GET /t
--- response_body
200
false
true
--- no_error_log
[error]



=== TEST 7: https to a resolved hostname verifies against its DNS SAN
--- http_config eval: $::TlsConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "https",
                host = "test.local",
                port = 12499,
                method = "GET",
                path = "/",
                ssl_verify = true,
                -- ssl_server_name defaults to host, so SNI reuses the name
                ssl_trusted_certificate =
                    "$TEST_NGINX_SERVER_ROOT/html/tls.crt",
            })

            if not res then
                ngx.status = 500
                ngx.say(err)
                return
            end

            ngx.say(res.status)
            ngx.print(res.body)
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- request
GET /t
--- response_body
200
secure
--- no_error_log
[error]



=== TEST 8: a second request answers from the resolver cache
--- http_config eval: $::HttpConfig
--- config
    location /mock {
        content_by_lua_block {
            local body = "cached\n"
            ngx.header["Content-Length"] = #body
            ngx.print(body)
        }
    }

    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local opts = {
                scheme = "http",
                host = "test.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/mock",
            }

            -- the stub answers one query only, so the second request has to
            -- come out of the resolver cache
            for i = 1, 2 do
                local res, err = client.request_uri(opts)
                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " ", res.reused)
            end
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- request
GET /t
--- response_body
200 false
200 false
--- no_error_log
[error]



=== TEST 9: a client abort while resolving is cleaned up
--- http_config eval: $::HttpConfig
--- config
    location /t {
        lua_check_client_abort on;

        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"
            local res, err = client.request_uri({
                scheme = "http",
                host = "slow.local",
                port = ngx.var.server_port,
                method = "GET",
                path = "/",
            })

            ngx.say(res and res.status or err)
        }
    }
--- udp_listen: 1953
--- udp_reply eval: $::DnsReply
--- udp_reply_delay: 3s
--- request
GET /t
--- timeout: 0.3
--- abort
--- ignore_response
--- no_error_log
[error]
