use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 3);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";

    # TLS 1.3 hands its session out after the handshake, in a ticket
    server {
        listen 127.0.0.1:12799 ssl;
        ssl_certificate \$TEST_NGINX_SERVER_ROOT/html/tls.crt;
        ssl_certificate_key \$TEST_NGINX_SERVER_ROOT/html/tls.key;
        ssl_protocols TLSv1.3;
        ssl_session_cache shared:ffi13:1m;
        ssl_session_timeout 10m;

        location / {
            content_by_lua_block {
                local body = "secure\\n"
                ngx.header["Content-Length"] = #body
                ngx.header["X-Reused"] = ngx.var.ssl_session_reused
                ngx.print(body)
            }
        }
    }

    # TLS 1.2 hands it out during the handshake
    server {
        listen 127.0.0.1:12798 ssl;
        ssl_certificate \$TEST_NGINX_SERVER_ROOT/html/tls.crt;
        ssl_certificate_key \$TEST_NGINX_SERVER_ROOT/html/tls.key;
        ssl_protocols TLSv1.2;
        ssl_session_cache shared:ffi12:1m;
        ssl_session_timeout 10m;

        location / {
            content_by_lua_block {
                local body = "secure\\n"
                ngx.header["Content-Length"] = #body
                ngx.header["X-Reused"] = ngx.var.ssl_session_reused
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

=== TEST 1: TLS 1.3 resumes the session of an earlier connection
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _ = 1, 2 do
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " ", res.headers["X-Reused"])
            end
        }
    }
--- request
GET /t
--- response_body
200 .
200 r
--- no_error_log
[error]



=== TEST 2: TLS 1.2 resumes the session of an earlier connection
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _ = 1, 2 do
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12798,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " ", res.headers["X-Reused"])
            end
        }
    }
--- request
GET /t
--- response_body
200 .
200 r
--- no_error_log
[error]



=== TEST 3: ssl_session_reuse = false keeps every handshake full
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _ = 1, 3 do
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                    ssl_session_reuse = false,
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " ", res.headers["X-Reused"])
            end
        }
    }
--- request
GET /t
--- response_body
200 .
200 .
200 .
--- no_error_log
[error]



=== TEST 4: a verify-off session is never offered to a verify-on request
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            -- same peer and same SNI throughout: the verify flag is the only
            -- thing telling the two sessions apart
            local function get(verify)
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    method = "GET",
                    path = "/",
                    ssl_verify = verify,
                    ssl_server_name = "test.local",
                    ssl_trusted_certificate =
                        "$TEST_NGINX_SERVER_ROOT/html/tls.crt",
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return false
                end

                ngx.say(res.status, " ", res.headers["X-Reused"])
                return true
            end

            if not get(false) then return end
            if not get(false) then return end
            if not get(true) then return end
            get(true)
        }
    }
--- request
GET /t
--- response_body
200 .
200 r
200 .
200 r
--- no_error_log
[error]



=== TEST 5: the stateful object resumes across connections
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            for _ = 1, 2 do
                local httpc = client.new()
                httpc:set_timeouts(2000, 2000, 2000)

                local ok, err = httpc:connect({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    ssl_verify = false,
                })

                if not ok then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                local res
                res, err = httpc:request({ method = "GET", path = "/",
                                           preread_body = true })
                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end

                ngx.say(res.status, " ", res.headers["X-Reused"])
                httpc:close()
            end
        }
    }
--- request
GET /t
--- response_body
200 .
200 r
--- no_error_log
[error]


=== TEST 6: sessions do not cross SNI
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            local function get(name)
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                    ssl_server_name = name,
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return false
                end

                ngx.say(name, " ", res.headers["X-Reused"])
                return true
            end

            if not get("one.test") then return end
            if not get("two.test") then return end
            get("one.test")
        }
    }
--- request
GET /t
--- response_body
one.test .
two.test .
one.test r
--- no_error_log
[error]



=== TEST 7: the cache is bounded and drops its least recently used peer
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config
    location /t {
        content_by_lua_block {
            local client = require "resty.ngx_http_ffi_client"

            -- one entry per SNI, so the peer count is the cache pressure
            local function get(name)
                local res, err = client.request_uri({
                    scheme = "https",
                    host = "127.0.0.1",
                    port = 12799,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                    ssl_server_name = name,
                })

                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return nil
                end

                return res.headers["X-Reused"]
            end

            -- fill the cache exactly: h1 is now its least recently used peer
            for i = 1, 256 do
                if not get("h" .. i .. ".test") then return end
            end

            -- h1 still resumes, and using it makes h2 the least recently used
            ngx.say("h1 ", get("h1.test"))

            -- one peer past the cap, so exactly one entry has to go
            ngx.say("h257 ", get("h257.test"))

            -- the one that went is h2, not the h1 an unpromoted cache would
            -- have dropped
            ngx.say("h1 ", get("h1.test"))
            ngx.say("h2 ", get("h2.test"))
        }
    }
--- request
GET /t
--- response_body
h1 r
h257 .
h1 r
h2 .
--- no_error_log
[error]
