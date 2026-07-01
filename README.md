# ngx_http_ffi_client

`ngx_http_ffi_client` is an OpenResty/APISIX-oriented Nginx C module that will expose a LuaJIT FFI HTTP client API.

The project goal is to let Lua code issue outbound HTTP/1.1 requests through a C implementation that integrates with Nginx/OpenResty event handling, TLS, timers, buffers, and keepalive connection management.

The first implementation target is:

- Lua-facing request/response API for APISIX plugins.
- Nonblocking execution inside OpenResty worker processes.
- HTTP/1.1 over HTTP and HTTPS.
- Keepalive connection pooling.
- LuaJIT FFI bindings in `lib/resty/ngx_http_ffi_client.lua`.

## Project status

This project is at an **early, exploratory stage**. The code here validates a
direction; it is **not production-ready** yet.

1. **The direction is settled.** The client will not keep maintaining a
   hand-written HTTP protocol implementation. The parsing/protocol layers are to
   be borrowed from battle-tested stacks, while Nginx keeps ownership of the
   event loop, timers, and keepalive pool. Longer term this grows into a
   high-quality outbound client for OpenResty/APISIX (TLS/SNI/mTLS, gzip,
   chunked/trailer, HTTP/2, SSE), leveraging mainstream-language stacks in the
   areas where C/C++ has fallen behind.

2. **The current stage is technical validation (spikes).** The backends in the
   tree are proofs of concept that de-risk the approach and are selectable at
   build time — they are not the final shape:
   - the initial hand-written C HTTP/1.1 parser (baseline);
   - an `llhttp` response-parser backend (`NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1`) —
     borrows Node.js's parser, is sans-io, and benchmarks at ~parity with the
     hand-written C path (see [benchmark/llhttp-poc.md](benchmark/llhttp-poc.md));
   - a `hyper` (Rust) runtime spike exploring an async backend.

   These exist to measure and compare approaches, not to ship as-is.

3. **Production-grade code is still ahead.** Turning these spikes into a
   production implementation still requires, at least:
   - **more exception / edge-case handling** — streaming and very large response
     bodies (SSE), bodyless responses (`204`/`304`/`HEAD`), connection-close
     framing, timeout and error paths, and request-smuggling hardening;
   - **component decoupling** — clean seams between the FFI contract, the
     transport / event-loop integration, the TLS layer, and the HTTP
     parser/framing, so each layer can evolve or be swapped independently.

In short: the direction is decided and technically validated; the
production-grade implementation — with fuller error handling and decoupled
components — is the next phase.

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
