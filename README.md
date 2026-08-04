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

### Headers

`res.headers` and `res.trailers` follow the `lua-resty-http` contract.

- Names are kept as the peer sent them, and a lookup matches without regard to
  case, with `_` reading as `-`. `res.headers["Content-Type"]`,
  `res.headers["content-type"]` and `res.headers.content_type` all reach the
  same value.
- A name that arrives more than once comes back as an array of its values, in
  the order received, which is how `Set-Cookie` is read. A name that arrives
  once is a plain string.
- A request header may be given as an array too: each value is sent as its own
  header line, so a response table can be passed straight back.

### Request validation

The method and every header name must be an RFC 9110 `token`, a header value
must be free of control characters, and the path and host must be free of
whitespace and control characters. A method of `GET /evil` or a header name of
`X: injected` is refused before anything reaches the wire rather than writing a
request line or a header the caller never asked for.

### Keepalive

`set_keepalive(timeout, pool_size)` follows the cosocket contract that
`lua-resty-http` forwards to.

- `timeout` is how many milliseconds the connection may sit idle in the pool. It
  defaults to `60000`, the cosocket's `lua_socket_keepalive_timeout`, and `0`
  asks for a connection that never expires on its own.
- `pool_size` sizes the pool. A pool is sized once, when it is created, and
  keeps that size for the life of the worker: the first `pool_size` to reach a
  given pool name wins and later ones are ignored, as with the cosocket. The
  pool is created by whichever comes first, a `connect{ pool_size = ... }` or
  the `set_keepalive` that parks the first connection in it. `connect` without a
  `pool_size` leaves the sizing to `set_keepalive`, which falls back to `30`.
- A full pool makes room by closing its least recently used connection.

The one-shot `request_uri{ keepalive = { pool, pool_size, idle_timeout } }`
resolves the same defaults and shares the same pools, so a pool name reaches the
same connections from either entry point.

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

   An interim `1xx` response is consumed and the parser starts over on the
   response behind it, so a `100 Continue` or a `103 Early Hints` never reaches
   the caller as the answer and never strands the final response on a pooled
   connection. The headers of an interim response are dropped with it. A `101`
   is the exception: the connection stops speaking HTTP after it and this client
   has nothing to hand it over to, so it is refused. mTLS is future client work
   in this same C/Nginx module, handled at the transport layer rather than by
   changing the protocol scope.

5. **HTTP/2 and HTTP/3 are out of scope for the current project stage.** They
   should not shape the current HTTP/1 API. If they are added later, they will
   likely need separate APIs, wrappers, and implementation choices rather than a
   direct reuse of the HTTP/1 client contract.

In short: the current goal is to make the HTTP/1 client stable, efficient, and
safe by building on `llhttp` and Nginx/OpenResty primitives first. Broader
protocol work is intentionally deferred.

## Benchmark

The local benchmark pins the target OpenResty worker to one CPU core and
compares a no-upstream baseline against both clients across a matrix of request
shapes: one-shot and stateful, buffered and streaming, plaintext and TLS, IP
literal and hostname, content-length and chunked framing.

Median of 5 repeats, 30s measured each, target worker saturated on every row,
no non-2xx responses, `llhttp` parser, 1KB response body, 100 wrk2 connections:

| shape | C FFI | `resty.http` | C FFI / `resty.http` | outbound cost ratio |
| --- | ---: | ---: | ---: | ---: |
| one-shot (`request_uri`) | `30154` QPS | `14785` QPS | `2.04x` | `2.64x` |
| stateful object | `27316` QPS | `15382` QPS | `1.78x` | `2.16x` |

Baseline without an upstream call: `82185` QPS. The outbound cost ratio
subtracts that baseline from both client paths and compares what is left, which
is the closest this gets to isolating the client itself.

Per-request Lua heap churn, which is the direct test of the claim that response
handling stays in C:

| shape | C FFI | `resty.http` |
| --- | ---: | ---: |
| one-shot | `2.49` KB | `7.45` KB |
| stateful | `3.33` KB | `6.49` KB |

**These supersede the previously published `2.04x`-`2.63x` QPS and
`2.70x`-`3.72x` outbound figures, which were withdrawn.** Those compared the C
one-shot fast path against a stateful `lua-resty-http` object, so the ratio
contained the API-shape difference as well as the C-versus-Lua difference and
credited all of it to the latter. They also predate per-request token
validation, the case-insensitive header table with repeated headers folded into
arrays, `llhttp` as the default parser, interim `1xx` consumption, and trailer
parsing, all of which add hot-path work. Matching the shapes and re-measuring
the current library moves the honest one-shot figure from `2.63x` to `2.04x`.

Across the full case matrix the ratio holds between `1.68x` and `1.96x` for
streaming, chunked framing, hostname resolution, POST bodies, and header-heavy
responses, and reaches `4.41x` on responses with trailers.

**Where this client loses.** The advantage is in per-request work, so it shrinks
as connection setup takes over the request and eventually reverses: `1.49x` on
pooled TLS, `1.19x` on short-lived plaintext connections, and `0.79x` on a fresh
TLS handshake per request, where `lua-resty-http` is about 21% faster. Anything
that cannot hold a keepalive pool, TLS to many short-lived peers most of all, is
a case for the other client today.

See [benchmark/README.md](benchmark/README.md) for the topology, the full case
matrix, the fairness audit, and how to reproduce.

Design notes and implementation plans used during development live under `docs/superpowers/` and are intentionally ignored by git.
