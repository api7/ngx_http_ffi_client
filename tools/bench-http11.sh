#!/usr/bin/env bash
set -euo pipefail

backend="${1:-c}"
nginx_bin="${TEST_NGINX_BINARY:?TEST_NGINX_BINARY is required}"
lua_path="${TEST_NGINX_LUA_PACKAGE_PATH:-$PWD/lib/?.lua;$PWD/lib/?/init.lua}"
duration="${BENCH_DURATION:-30s}"
connections="${BENCH_CONNECTIONS:-64}"
threads="${BENCH_THREADS:-2}"
port="${BENCH_PORT:-19840}"
workdir="${BENCH_WORKDIR:-}"
created_workdir=0
nginx_started=0

case "$backend" in
  c|hyper) ;;
  *)
    echo "usage: $0 [c|hyper]" >&2
    exit 2
    ;;
esac

if [ ! -x "$nginx_bin" ]; then
  echo "TEST_NGINX_BINARY must point to an executable nginx binary" >&2
  exit 2
fi

case "$port" in
  ''|*[!0-9]*)
    echo "BENCH_PORT must be a positive integer in 1..65535" >&2
    exit 2
    ;;
esac

require_positive_integer() {
  value_name="$1"
  value="$2"

  case "$value" in
    ''|*[!0-9]*)
      echo "$value_name must be a positive integer" >&2
      exit 2
      ;;
  esac

  if [ "$value" -lt 1 ]; then
    echo "$value_name must be a positive integer" >&2
    exit 2
  fi
}

if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  echo "BENCH_PORT must be a positive integer in 1..65535" >&2
  exit 2
fi

require_positive_integer BENCH_THREADS "$threads"
require_positive_integer BENCH_CONNECTIONS "$connections"

cleanup() {
  if [ "$nginx_started" -eq 1 ]; then
    "$nginx_bin" -p "$workdir" -s stop >/dev/null 2>&1 || true
  fi

  if [ "$created_workdir" -eq 1 ]; then
    rm -rf "$workdir"
  fi
}

tail_error_log() {
  if [ -f "$workdir/logs/error.log" ]; then
    tail -n 80 "$workdir/logs/error.log" >&2
  fi
}

trap cleanup EXIT

if [ -n "$workdir" ]; then
  case "$workdir" in
    /tmp/ngx_http_ffi_client_bench-*) ;;
    *)
      echo "BENCH_WORKDIR must start with /tmp/ngx_http_ffi_client_bench-" >&2
      exit 2
      ;;
  esac

  if [ -s "$workdir/logs/nginx.pid" ]; then
    echo "BENCH_WORKDIR already contains logs/nginx.pid; clean it up or choose another directory" >&2
    exit 2
  fi
else
  workdir="$(mktemp -d "/tmp/ngx_http_ffi_client_bench-${backend}.XXXXXX")"
  created_workdir=1
fi

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required for benchmarks" >&2
  exit 2
fi

mkdir -p "$workdir/logs" "$workdir/conf"

cat > "$workdir/conf/nginx.conf" <<NGINX
worker_processes  1;
error_log logs/error.log error;
events { worker_connections 4096; }
http {
    lua_package_path "$lua_path;;";
    server {
        listen 127.0.0.1:$port;

        location /mock {
            content_by_lua_block {
                local body = "hello\\n"
                ngx.header["Content-Length"] = #body
                ngx.print(body)
            }
        }

        location /chunked {
            content_by_lua_block {
                ngx.say("chunked")
            }
        }

        location /bench {
            content_by_lua_block {
                local client = require "resty.ngx_http_ffi_client"
                local res, err = client.request({
                    scheme = "http",
                    host = "127.0.0.1",
                    port = $port,
                    method = "GET",
                    path = "/mock",
                    keepalive = {
                        pool = "bench",
                        idle_timeout = 60000,
                        pool_size = 64,
                    },
                })
                if not res then
                    ngx.status = 500
                    ngx.say(err)
                    return
                end
                ngx.print(res.body)
            }
        }
    }
}
NGINX

"$nginx_bin" -p "$workdir" -c conf/nginx.conf
nginx_started=1
sleep 0.2

health_body="$(curl -fsS "http://127.0.0.1:$port/bench"; printf x)"
if [ "$health_body" != $'hello\nx' ]; then
  echo "benchmark target health check failed: expected response body 'hello\\n'" >&2
  echo "actual response body:" >&2
  printf '%s' "${health_body%x}" >&2
  tail_error_log
  exit 1
fi

wrk -t"$threads" -c"$connections" -d"$duration" "http://127.0.0.1:$port/bench" | tee "$workdir/result.txt"
