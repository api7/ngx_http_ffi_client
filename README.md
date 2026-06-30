# ngx_http_ffi_client

`ngx_http_ffi_client` is an OpenResty/APISIX-oriented Nginx C module that will expose a LuaJIT FFI HTTP client API.

The project goal is to let Lua code issue outbound HTTP/1.1 requests through a C implementation that integrates with Nginx/OpenResty event handling, TLS, timers, buffers, and keepalive connection management.

The first implementation target is:

- Lua-facing request/response API for APISIX plugins.
- Nonblocking execution inside OpenResty worker processes.
- HTTP/1.1 over HTTP and HTTPS.
- Keepalive connection pooling.
- LuaJIT FFI bindings in `lib/resty/ngx_http_ffi_client.lua`.

## Benchmark

The local benchmark pins the target OpenResty worker to one CPU core and
compares three request paths: a no-upstream baseline, the C FFI client, and
`resty.http`. The latest 15-second local runs used wrk2 with a saturated target
worker.

| wrk2 connections | no-upstream baseline | C FFI client | `resty.http` | C FFI / `resty.http` QPS | outbound cost ratio (`resty.http` / C FFI) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `10` | `83998.04` QPS | `32831.68` QPS | `16123.19` QPS | `2.04x` | `2.70x` |
| `100` | `96155.73` QPS | `38582.72` QPS | `14665.62` QPS | `2.63x` | `3.72x` |

The C FFI path delivers substantially higher end-to-end throughput than
`resty.http`, and the baseline-derived estimate shows `resty.http` spending
about `2.70x` to `3.72x` as much outbound client CPU time as the C FFI path in
these local runs. See
[benchmark/README.md](benchmark/README.md) for the benchmark topology,
reproduction notes, and detailed measurements.

Design notes and implementation plans used during development live under `docs/superpowers/` and are intentionally ignored by git.
