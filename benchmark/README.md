# Benchmark

This directory contains the local benchmark for comparing
`resty.ngx_http_ffi_client` with the Lua cosocket baseline implemented with
`lua-resty-http` / `resty.http`.

The benchmark measures maximum QPS when the target OpenResty worker is pinned to
one CPU core and that core is saturated. It is not a fixed-rate latency test.

The runner measures a baseline first. The baseline endpoint does not contact the
upstream; it only returns a response body with the same size as the upstream
response. The C FFI and `resty.http` cases are then compared against this
baseline to estimate the outbound HTTP client cost.

## Dependencies

- OpenResty or Nginx binary built with `ngx_http_ffi_client_module`
- `lua-resty-http` available in `TEST_NGINX_LUA_PACKAGE_PATH`
- `wrk2`
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
- wrk2: load generator, pinned to `WRK_CPUS`

`wrk2` sends requests to the target instance. The target instance sends one
outbound HTTP/1.1 request to the upstream per inbound request.

The benchmark cases run in this order:

1. `/bench/baseline`: target worker returns a fixed body without upstream IO.
2. `/bench/ffi`: target worker calls `resty.ngx_http_ffi_client`.
3. `/bench/resty-http`: target worker calls `resty.http`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `TARGET_CPU` | `0` | CPU core used by the target OpenResty worker |
| `UPSTREAM_CPUS` | non-target cores | CPU cores used by the upstream instance |
| `WRK_CPUS` | `UPSTREAM_CPUS` | CPU cores used by wrk2 |
| `TARGET_PORT` | `19840` | target listen port |
| `UPSTREAM_PORT` | `19841` | upstream listen port |
| `UPSTREAM_WORKERS` | count of `UPSTREAM_CPUS` | upstream worker count |
| `RESPONSE_SIZE` | `1024` | upstream response body size in bytes |
| `KEEPALIVE_POOL_SIZE` | `120` | keepalive pool size for both client paths |
| `KEEPALIVE_IDLE_TIMEOUT` | `60000` | keepalive idle timeout in milliseconds |
| `WRK_THREADS` | `2` | wrk2 thread count |
| `WRK_CONNECTIONS` | `100` | wrk2 connection count |
| `WRK_DURATION` | `30s` | official benchmark duration |
| `WRK_RATE` | `100000` | wrk2 target request rate, set high enough to saturate the target worker |
| `WRK2_BIN` | `wrk` | wrk2 executable path |
| `CPU_SATURATION_THRESHOLD` | `95` | minimum average target worker CPU for a valid run |

The runner invokes wrk2 with `-R "$WRK_RATE" -L -U`. The `-L` output reports
wrk2's latency distribution and `-U` reports the uncorrected latency
distribution. For this benchmark, set `WRK_RATE` above the expected maximum QPS
so the single target worker remains CPU-bound.

## Baseline-Derived Estimate

The QPS results include downstream client-to-OpenResty overhead. To estimate the
outbound HTTP client cost, the runner treats single-core CPU time per request as
approximately `1 / QPS`:

```text
baseline_us = 1_000_000 / baseline_qps
ffi_outbound_us = 1_000_000 / ffi_qps - baseline_us
resty_outbound_us = 1_000_000 / resty_http_qps - baseline_us
ratio = resty_outbound_us / ffi_outbound_us
```

This is still an estimate, but it removes the common downstream and simple
response path from the comparison.

## Valid Runs

A result is valid only when the target worker CPU average is at least
`CPU_SATURATION_THRESHOLD`.

If the result is marked suspicious:

- increase `WRK_THREADS`
- increase `WRK_CONNECTIONS`
- increase `WRK_RATE`
- move wrk2 to non-target CPU cores
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
`wrk2`:

```bash
BENCH_DRY_RUN=1 make bench
```
