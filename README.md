# ngx_http_ffi_client

`ngx_http_ffi_client` is an OpenResty/APISIX-oriented Nginx C module that will expose a LuaJIT FFI HTTP client API.

The project goal is to let Lua code issue outbound HTTP/1.1 requests through a C implementation that integrates with Nginx/OpenResty event handling, TLS, timers, buffers, and keepalive connection management.

The current implementation target is HTTP/1.x only:

- Lua-facing request/response API for APISIX plugins.
- Nonblocking execution inside OpenResty worker processes.
- HTTP/1.1 over HTTP and HTTPS.
- Keepalive connection pooling.
- Buffered and incremental (streaming) response reads.
- HTTP/1 parsing and framing through the vendored pure-C `llhttp` parser.
- LuaJIT FFI bindings in `lib/resty/ngx_http_ffi_client.lua`.

## Lua API

Two entry points, both on `resty.ngx_http_ffi_client`.

**`request_uri(opts)`** — one shot: connect, send, read the whole response, then
give the connection back to the pool when `keepalive` is set, or close it.

```lua
local client = require "resty.ngx_http_ffi_client"

local res, err = client.request_uri({
    scheme = "http", host = "127.0.0.1", port = 1984,
    method = "GET", path = "/hello",
    headers = { ["X-Trace"] = "1" },
    keepalive = { pool_size = 30, idle_timeout = 60000 },
})
-- res.status / res.headers / res.body / res.trailers
```

**`new()`** — a stateful client object that owns its connection across calls,
shaped like `lua-resty-http`:

```lua
local httpc = client.new()
httpc:set_timeouts(2000, 2000, 2000)

assert(httpc:connect({ scheme = "https", host = "example.com", port = 443 }))

local res = assert(httpc:request({ method = "GET", path = "/events" }))
-- res.status and res.headers are in; the body has not been read yet

local reader = res.body_reader
while true do
    local chunk = reader()          -- one slice, as it arrives off the socket
    if not chunk then break end
    -- ...
end
-- or res:read_body() to get the whole body as a string

httpc:set_keepalive()               -- back to the pool, or httpc:close()
```

`request{ preread_body = true }` selects the buffered fast path instead: C reads
the whole body and resumes the coroutine once, with `res.body` ready. Use it for
bounded bodies; a stream read with `body_reader` is the right call for SSE and
very large responses.

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

2. **`llhttp` is the default parser backend.** The repository now builds the
   `llhttp` response parser by default. The initial hand-written parser remains
   available only as an explicit fallback and comparison baseline with
   `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=0`. Keeping both build paths is a migration
   mechanism, not a long-term plan to maintain two independent HTTP/1 parsers.
   CI runs both the default `llhttp` backend and the explicit hand-written
   fallback so the migration boundary stays covered.

3. **`llhttp` is the HTTP/1 parsing boundary for new work.** New HTTP/1 parsing
   and framing work should be designed around `llhttp`. The default `llhttp`
   response parser benchmarks at near parity with the hand-written C path (see
   [benchmark/llhttp-poc.md](benchmark/llhttp-poc.md)).

4. **The next HTTP/1 work stays in this stack.** Incremental response delivery
   is in: the stateful object resumes at the headers and pulls the body one
   `llhttp` span at a time, so SSE and large bodies stream. Response framing is
   in as well, on both the streaming and the one-shot path:

   - `HEAD` responses, `204` and `304` are bodyless whatever `Content-Length`
     they announce. `HEAD` is matched case-sensitively, as `lua-resty-http`
     does.
   - Chunked trailers are parsed but kept out of `res.headers`; they are
     reported separately as `res.trailers`, filled once the body has been read
     to the end.
   - A response with neither `Content-Length` nor chunked encoding is framed by
     the connection close, and that connection never goes back to the pool. A
     close inside a declared `Content-Length` is still a truncated read.
   - Every `llhttp_set_lenient_*` flag stays off. Strict mode is what rejects
     the request-smuggling shapes: `Content-Length` together with
     `Transfer-Encoding`, a conflicting repeated `Content-Length`, and a chunk
     size that is not a plain hex number. The request side always frames with
     `Content-Length`, so a caller-supplied `Transfer-Encoding` is dropped
     rather than put on the wire next to it. One request gets one response: a
     second message arriving behind the first is refused instead of merged into
     it.
   - Timeouts report `timeout` and a failed connect reports the socket error
     (`connection refused` and the like), matching what the cosocket hands to
     `lua-resty-http` callers.

   The client writes `Host`, `Connection` and `Content-Length` itself, and a
   caller may override them the way `lua-resty-http` allows. Their values feed
   the request prologue, so each is emitted once:

   - `Host` replaces the one derived from the peer, for virtual hosting and for
     talking to an IP with a named `Host`.
   - `Connection` goes on the wire as given. A value asking to close also keeps
     that connection out of the pool, so the wire and the pool agree.
   - `Content-Length` is accepted when it matches the body and refused when it
     disagrees. `lua-resty-http` sends a mismatched length as given; here that
     would leave the connection out of sync with the peer, so it is an error.
   - `Transfer-Encoding` is still dropped, since honoring it needs a streamed
     request body (#29).

   The hand-written fallback accepts content-length and close framing and
   rejects `Transfer-Encoding` outright, so the chunked and trailer cases in
   `t/011-framing.t` run on the `llhttp` backend only.

   What is left — interim `1xx` responses, repeated response headers, and
   request token validation (#25) — is treated as HTTP/1 parsing and framing
   work around `llhttp`. mTLS is future client work in this same C/Nginx
   module, handled at the transport layer rather than by changing the protocol
   scope.

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
