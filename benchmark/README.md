# Benchmark

This directory contains the local benchmark for comparing
`resty.ngx_http_ffi_client` with the Lua cosocket baseline implemented with
`lua-resty-http` / `resty.http`.

The benchmark measures maximum QPS when the target OpenResty worker is pinned to
one CPU core and that core is saturated. It is not a fixed-rate latency test.

## Dependencies

- OpenResty or Nginx binary built with `ngx_http_ffi_client_module`
- `lua-resty-http` available in `TEST_NGINX_LUA_PACKAGE_PATH`
- `wrk`
- `curl`
- `taskset` from util-linux
- Linux `/proc` filesystem for CPU sampling

## Command

```bash
export TEST_NGINX_BINARY=/path/to/openresty/nginx/sbin/nginx
export TEST_NGINX_LUA_PACKAGE_PATH="$PWD/lib/?.lua;$PWD/lib/?/init.lua;/path/to/lua-resty-http/lib/?.lua;;"
make bench
```

## Topology

- upstream instance: mock HTTP server, multiple workers, non-target CPU cores
- target instance: one OpenResty worker, pinned to `TARGET_CPU`
- wrk: load generator, pinned to `WRK_CPUS`

`wrk` sends requests to the target instance. The target instance sends one
outbound HTTP/1.1 request to the upstream per inbound request.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `TARGET_CPU` | `0` | CPU core used by the target OpenResty worker |
| `UPSTREAM_CPUS` | non-target cores | CPU cores used by the upstream instance |
| `WRK_CPUS` | `UPSTREAM_CPUS` | CPU cores used by `wrk` |
| `TARGET_PORT` | `19840` | target listen port |
| `UPSTREAM_PORT` | `19841` | upstream listen port |
| `UPSTREAM_WORKERS` | count of `UPSTREAM_CPUS` | upstream worker count |
| `RESPONSE_SIZE` | `1024` | upstream response body size in bytes |
| `KEEPALIVE_POOL_SIZE` | `256` | keepalive pool size for both client paths |
| `KEEPALIVE_IDLE_TIMEOUT` | `60000` | keepalive idle timeout in milliseconds |
| `WRK_THREADS` | `2` | `wrk` thread count |
| `WRK_CONNECTIONS` | `200` | `wrk` connection count |
| `WRK_DURATION` | `30s` | official benchmark duration |
| `CPU_SATURATION_THRESHOLD` | `95` | minimum average target worker CPU for a valid run |

## Valid Runs

A result is valid only when the target worker CPU average is at least
`CPU_SATURATION_THRESHOLD`.

If the result is marked suspicious:

- increase `WRK_THREADS`
- increase `WRK_CONNECTIONS`
- move `wrk` to non-target CPU cores
- increase `UPSTREAM_WORKERS`
- assign more non-target cores to `UPSTREAM_CPUS`

Do not compare C FFI and `resty.http` QPS from runs where the target worker was
not saturated.

## Manual RSS and GC Checks

The benchmark output focuses on QPS, latency, and target worker CPU saturation.
Use these commands for supporting observations:

```bash
cat benchmark/.run/target/logs/nginx.pid
ps -o pid,ppid,pcpu,rss,comm --ppid "$(cat benchmark/.run/target/logs/nginx.pid)"
curl -fsS "http://127.0.0.1:${TARGET_PORT:-19840}/gc"
```

The GC endpoint prints `collectgarbage("count")` in KB for the target worker.
Treat RSS and GC values as diagnostics, not as the primary comparison metric.

## Dry Run

Use dry-run mode to verify template rendering without starting OpenResty or
`wrk`:

```bash
BENCH_DRY_RUN=1 make bench
```
