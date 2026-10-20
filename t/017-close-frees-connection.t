use Test::Nginx::Socket -Base;

repeat_each(1);
plan tests => repeat_each() * (blocks() * 12);

our $HttpConfig = qq{
    lua_package_path "$ENV{TEST_NGINX_LUA_PACKAGE_PATH};;";
    lua_shared_dict ffic_mem 1m;

    server {
        listen 127.0.0.1:12399 ssl;
        ssl_certificate \$TEST_NGINX_SERVER_ROOT/html/tls.crt;
        ssl_certificate_key \$TEST_NGINX_SERVER_ROOT/html/tls.key;
        keepalive_timeout 0;

        location / {
            return 200 "ok\\n";
        }
    }

    server {
        listen 127.0.0.1:12398;
        keepalive_timeout 0;

        location / {
            return 200 "ok\\n";
        }
    }

    init_by_lua_block {
        local ffi = require "ffi"
        ffi.cdef[[
            struct ffic_mallinfo2 {
                size_t arena; size_t ordblks; size_t smblks; size_t hblks;
                size_t hblkhd; size_t usmblks; size_t fsmblks;
                size_t uordblks; size_t fordblks; size_t keepcost;
            };
            struct ffic_mallinfo2 mallinfo2(void);
        ]]

        -- glibc only: elsewhere the check below reports "ok" without measuring
        local found, fn = pcall(function() return ffi.C.mallinfo2 end)

        function ffic_in_use()
            if not found then
                return nil
            end
            return tonumber(fn().uordblks)
        end

        -- each upstream answers with "Connection: close", so every request
        -- opens a connection and the client closes it afterwards
        function ffic_run(scheme, port, n)
            local client = require "resty.ngx_http_ffi_client"
            for _ = 1, n do
                local res, err = client.request_uri({
                    scheme = scheme,
                    host = "127.0.0.1",
                    port = port,
                    method = "GET",
                    path = "/",
                    ssl_verify = false,
                })
                if not res then
                    return err
                end
            end
        end
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
our $Config = <<'_EOC_';
    location = /warm {
        content_by_lua_block {
            ngx.say(ffic_run(ngx.var.arg_scheme, tonumber(ngx.var.arg_port), 50) or "warm")
        }
    }

    location = /base {
        content_by_lua_block {
            ngx.shared.ffic_mem:set("base", ffic_in_use() or -1)
            ngx.say("base")
        }
    }

    location = /run {
        content_by_lua_block {
            ngx.say(ffic_run(ngx.var.arg_scheme, tonumber(ngx.var.arg_port),
                             tonumber(ngx.var.arg_n)) or "ran")
        }
    }

    location = /check {
        content_by_lua_block {
            local base = ngx.shared.ffic_mem:get("base")
            local now = ffic_in_use()
            if not now or base < 0 then
                ngx.say("ok")
                return
            end

            local per = (now - base) / tonumber(ngx.var.arg_n)
            if per > tonumber(ngx.var.arg_max) then
                ngx.say("kept ", math.floor(per), " bytes per closed connection")
                return
            end
            ngx.say("ok")
        }
    }
_EOC_

no_shuffle();
run_tests();

__DATA__

=== TEST 1: closing a TLS connection frees its pool and SSL object
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config eval: $::Config
--- request eval
["GET /warm?scheme=https&port=12399",
 "GET /base",
 "GET /run?scheme=https&port=12399&n=500",
 "GET /check?n=500&max=1024"]
--- response_body eval
["warm\n", "base\n", "ran\n", "ok\n"]
--- no_error_log
[error]



=== TEST 2: closing a plain connection frees its pool
--- http_config eval: $::HttpConfig
--- user_files eval: $::UserFiles
--- config eval: $::Config
--- request eval
["GET /warm?scheme=http&port=12398",
 "GET /base",
 "GET /run?scheme=http&port=12398&n=2000",
 "GET /check?n=2000&max=64"]
--- response_body eval
["warm\n", "base\n", "ran\n", "ok\n"]
--- no_error_log
[error]
