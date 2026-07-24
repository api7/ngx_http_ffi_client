#!/usr/bin/env bash
#
# Benchmark the ngx_http_ffi_client HTTP/1.1 keepalive path for a single
# openresty/nginx binary (built with either the custom-C or the llhttp parser
# backend). It spins up a self-contained target on 127.0.0.1, verifies the
# response body and keepalive reuse, then drives /bench with wrk.
#
# Usage:  benchmark/bench-http11.sh <nginx-binary> [label]
#
# Env knobs: BENCH_PORT BENCH_DURATION BENCH_CONNECTIONS BENCH_THREADS WRK_BIN
#            TEST_NGINX_LUA_PACKAGE_PATH
#
set -euo pipefail

nginx_bin="${1:?usage: bench-http11.sh <nginx-binary> [label]}"
label="${2:-$nginx_bin}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lua_path="${TEST_NGINX_LUA_PACKAGE_PATH:-$root/lib/?.lua;$root/lib/?/init.lua}"
port="${BENCH_PORT:-19840}"
duration="${BENCH_DURATION:-30s}"
connections="${BENCH_CONNECTIONS:-64}"
threads="${BENCH_THREADS:-2}"
wrk_bin="${WRK_BIN:-wrk}"

[ -x "$nginx_bin" ] || { echo "not executable: $nginx_bin" >&2; exit 2; }
command -v "$wrk_bin" >/dev/null 2>&1 || { echo "wrk required (set WRK_BIN)" >&2; exit 2; }

workdir="$(mktemp -d "/tmp/ngx_http_ffi_client_bench-XXXXXX")"
cleanup() {
    if [ -s "$workdir/logs/nginx.pid" ]; then
        "$nginx_bin" -p "$workdir" -c conf/nginx.conf -s stop >/dev/null 2>&1 || true
    fi
    rm -rf "$workdir"
}
trap cleanup EXIT
mkdir -p "$workdir/logs" "$workdir/conf"

cat > "$workdir/conf/nginx.conf" <<NGINX
worker_processes  1;
error_log logs/error.log error;
events { worker_connections 8192; }
http {
    lua_package_path "$lua_path;;";
    server {
        listen 127.0.0.1:$port reuseport;

        location /mock {
            content_by_lua_block {
                local body = "hello\n"
                ngx.header["Content-Length"] = #body
                ngx.print(body)
            }
        }

        location /bench {
            content_by_lua_block {
                local client = require "resty.ngx_http_ffi_client"
                local res, err = client.request_uri({
                    scheme = "http", host = "127.0.0.1", port = $port,
                    method = "GET", path = "/mock",
                    keepalive = { pool = "bench", idle_timeout = 60000, pool_size = 128 },
                })
                if not res then ngx.status = 500; ngx.say(err); return end
                ngx.print(res.body)
            }
        }

        location /reuse-check {
            content_by_lua_block {
                local client = require "resty.ngx_http_ffi_client"
                local opts = {
                    scheme = "http", host = "127.0.0.1", port = $port,
                    method = "GET", path = "/mock",
                    keepalive = { pool = "reuse", idle_timeout = 60000, pool_size = 2 },
                }
                local a = client.request_uri(opts)
                local b = client.request_uri(opts)
                ngx.say("first:"  .. tostring(a and a.reused))
                ngx.say("second:" .. tostring(b and b.reused))
            }
        }
    }
}
NGINX

"$nginx_bin" -p "$workdir" -c conf/nginx.conf
sleep 0.3

body="$(curl -fsS "http://127.0.0.1:$port/bench"; printf x)"
if [ "$body" != $'hello\nx' ]; then
    echo "health check FAILED (expected body 'hello'):" >&2
    printf '%s\n' "${body%x}" >&2
    tail -n 40 "$workdir/logs/error.log" >&2 || true
    exit 1
fi

reuse="$(curl -fsS "http://127.0.0.1:$port/reuse-check" | tr '\n' ' ')"
echo "correctness: body=ok  reuse-check=[$reuse]"

echo "== $label =="
"$wrk_bin" -t"$threads" -c"$connections" -d"$duration" "http://127.0.0.1:$port/bench"
