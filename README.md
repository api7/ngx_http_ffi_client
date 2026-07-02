# ngx_http_ffi_client

`ngx_http_ffi_client` is an OpenResty/APISIX-oriented Nginx C module that will expose a LuaJIT FFI HTTP client API.

The project goal is to let Lua code issue outbound HTTP/1.1 requests through a C implementation that integrates with Nginx/OpenResty event handling, TLS, timers, buffers, and keepalive connection management.

The current implementation target is HTTP/1.x only:

- Lua-facing request/response API for APISIX plugins.
- Nonblocking execution inside OpenResty worker processes.
- HTTP/1.1 over HTTP and HTTPS.
- Keepalive connection pooling.
- HTTP/1 parsing and framing through the vendored pure-C `llhttp` parser.
- LuaJIT FFI bindings in `lib/resty/ngx_http_ffi_client.lua`.

## Project status

This project is at an **early implementation stage**. The protocol direction is
settled, but the full production behavior is still being built.

1. **The HTTP/1 implementation strategy is settled.** The client should borrow a
   stable, efficient, security-sensitive protocol parser instead of growing a
   larger hand-written HTTP parser in this repository. The selected HTTP/1
   parser is the vendored pure-C `llhttp` code under `src/llhttp/`.

   `llhttp` is the recommended parser because it fits this module's constraints:
   it is C code that can be compiled into the Nginx addon without adding another
   language runtime; it is sans-io, so Nginx remains the only event-loop and
   transport owner; it is already used by Node.js core and undici for HTTP/1
   parsing; it covers HTTP/1 framing rules such as `Content-Length`, chunked
   bodies, trailers, keepalive, and EOF framing; and the local parser benchmark
   shows near parity with the current hand-written C path. This lets the project
   reuse a mature HTTP/1 state machine while keeping timers, buffers, TLS,
   connection lifecycle, and keepalive pooling in Nginx/OpenResty code.

2. **The current default backend is still transitional.** The repository still
   builds the initial hand-written parser by default. The `llhttp` response
   parser is selected explicitly with `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1`.
   Keeping both build paths is a migration mechanism, not a long-term plan to
   maintain two independent HTTP/1 parsers. The hand-written parser remains the
   current baseline while behavior, tests, and remaining edge cases move to the
   `llhttp`-based path.

3. **`llhttp` is the HTTP/1 parsing boundary for new work.** New HTTP/1 parsing
   and framing work should be designed around `llhttp`, even though the default
   build has not flipped yet. The current `llhttp` response parser is selectable
   with `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1` and benchmarks at near parity with
   the hand-written C path (see [benchmark/llhttp-poc.md](benchmark/llhttp-poc.md)).

4. **The next HTTP/1 work stays in this stack.** Streaming and incremental
   response delivery, SSE / large bodies, chunked bodies, trailers, bodyless
   responses (`204`/`304`/`HEAD`), connection-close framing, timeout and error
   paths, and request-smuggling hardening are treated as HTTP/1 parsing and
   framing work around `llhttp`. TLS certificate handling, SNI, and mTLS are
   also future HTTP/1 client work in this same C/Nginx module, handled at the
   transport layer rather than by changing the protocol scope.

5. **HTTP/2 and HTTP/3 are out of scope for the current project stage.** They
   should not shape the current HTTP/1 API. If they are added later, they will
   likely need separate APIs, wrappers, and implementation choices rather than a
   direct reuse of the HTTP/1 client contract.

In short: the current goal is to make the HTTP/1 client stable, efficient, and
safe by building on `llhttp` and Nginx/OpenResty primitives first. Broader
protocol work is intentionally deferred.

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
