# Benchmark

This directory contains the local benchmark for comparing
`resty.ngx_http_ffi_client` with the Lua cosocket baseline implemented with
`lua-resty-http` / `resty.http`.

The benchmark is scoped to the current HTTP/1.1 client work. It validates the
C/Nginx module path and the llhttp-based HTTP/1 direction; it does not evaluate
HTTP/2, HTTP/3, or alternative protocol APIs.

The benchmark measures maximum QPS when the target OpenResty worker is pinned to
one CPU core and that core is saturated. It is not a fixed-rate latency test.

The runner measures a baseline first. The baseline endpoint does not contact the
upstream; it only returns a response body with the same size as the upstream
response. The C FFI and `resty.http` cases are then compared against this
baseline to estimate the outbound HTTP client cost.

## Current Result Summary

The latest local runs compare three paths:

- no-upstream baseline: target OpenResty returns a fixed response body directly
- C FFI client: target OpenResty sends one upstream HTTP request with
  `resty.ngx_http_ffi_client`
- `resty.http`: target OpenResty sends one upstream HTTP request with
  `lua-resty-http`

Both load points used `WRK_DURATION=15s`, `WRK_RATE=100000`,
`WRK_THREADS=2`, `KEEPALIVE_POOL_SIZE=120`, `KEEPALIVE_IDLE_TIMEOUT=60000`,
and `RESPONSE_SIZE=1024`. The target worker was pinned to CPU `0`, the
upstream workers used CPUs `1-5`, wrk2 used CPUs `6-7`, and the upstream used
`UPSTREAM_WORKERS=5`.

| wrk2 connections | no-upstream baseline | C FFI client | `resty.http` | C FFI / `resty.http` QPS | outbound cost ratio (`resty.http` / C FFI) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `10` | `83998.04` QPS | `32831.68` QPS | `16123.19` QPS | `2.04x` | `2.70x` |
| `100` | `96155.73` QPS | `38582.72` QPS | `14665.62` QPS | `2.63x` | `3.72x` |

The QPS ratio is the direct end-to-end throughput comparison between the C FFI
client and `resty.http`. The outbound cost ratio subtracts the no-upstream
baseline from both client paths and compares the estimated upstream HTTP client
CPU cost as `resty.http / C FFI`. In these runs, the C FFI client is about
`2.04x` to `2.63x` faster end-to-end, and `resty.http` spends about `2.70x` to
`3.72x` as much estimated outbound client CPU time.

## Detailed Local Measurements

All target-worker CPU averages are above the default `95%` saturation threshold,
and no `Non-2xx` responses were reported in these runs.

| wrk2 connections | case | QPS | target worker CPU avg | saturation |
| --- | --- | ---: | ---: | --- |
| `10` | no-upstream baseline | `83998.04` | `108.6%` | valid |
| `10` | C FFI client | `32831.68` | `109.1%` | valid |
| `10` | `resty.http` | `16123.19` | `105.6%` | valid |
| `100` | no-upstream baseline | `96155.73` | `103.9%` | valid |
| `100` | C FFI client | `38582.72` | `110.1%` | valid |
| `100` | `resty.http` | `14665.62` | `106.4%` | valid |

The baseline-derived per-request estimates are:

| wrk2 connections | baseline downstream + handler | C FFI total | C FFI estimated outbound | `resty.http` total | `resty.http` estimated outbound | outbound cost ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `10` | `11.905 us` | `30.458 us` | `18.553 us` | `62.022 us` | `50.117 us` | `2.70x` |
| `100` | `10.400 us` | `25.918 us` | `15.519 us` | `68.187 us` | `57.787 us` | `3.72x` |

The main project advantage shown by this benchmark is that the C FFI client
keeps outbound HTTP request handling in Nginx C module code while preserving
OpenResty worker nonblocking behavior and keepalive reuse. Under a saturated
single target worker, this reduces Lua cosocket overhead on the upstream client
path and leaves more of the worker CPU budget for application logic.

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
