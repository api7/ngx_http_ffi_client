# llhttp HTTP/1 parser direction

This document records the selected HTTP/1.x parser direction for
`ngx_http_ffi_client`: replace the hand-written HTTP/1.x response parser with
[llhttp](https://github.com/nodejs/llhttp), the pure-C parser used by Node.js
core and undici, behind the current FFI contract while keeping nginx's event
loop and keepalive pool untouched.

## Why

The current response parser (`src/ngx_http_ffi_client_response.c`) is a
hand-written "buffer until CRLFCRLF then split" implementation. It rejects
`Transfer-Encoding: chunked`, hard-requires `Content-Length` (so `204/304/HEAD`
and connection-close bodies fail), and owns security-sensitive framing itself.

llhttp is a sans-io state machine: you feed it bytes, it fires callbacks. It
does full HTTP/1.0+1.1 message framing (chunked, trailers, keep-alive,
Content-Length, EOF) and is fuzzed continuously as Node's parser. It needs no
async runtime, so nginx stays the sole I/O driver: one Lua coroutine, no second
event loop.

The implementation principle is to borrow the stable, efficient, and
security-sensitive parser, then keep transport, timers, TLS, buffers, and
connection reuse in the Nginx/OpenResty module.

The parser choice is based on these constraints:

- **Pure C integration.** `llhttp` can be vendored and compiled into the Nginx
  addon without adding another language runtime, a second event loop, or
  cross-language async ownership to the HTTP/1 path.
- **Sans-io design.** It only consumes bytes and emits parser callbacks, so
  Nginx/OpenResty still owns sockets, timers, buffers, coroutine yield/resume,
  and keepalive reuse.
- **HTTP/1 framing coverage.** It already models status lines, headers,
  `Content-Length`, chunked bodies, trailers, keepalive, and EOF framing. The
  hand-written parser currently owns these security-sensitive rules itself and
  only supports a narrower subset.
- **Operational maturity.** It is used by Node.js core and undici and is
  maintained as a dedicated HTTP parser, which is a better risk profile than
  growing project-local parser logic case by case.
- **Performance fit.** In the local keepalive parser benchmark, the llhttp path
  is within about 1% of the hand-written C parser, so the project can gain a
  more complete parser without giving up the C/Nginx performance goal.

## What changed

- `src/llhttp/` — vendored llhttp release (v9.4.1, see `VENDORED-SHA.txt`).
- `src/ngx_http_ffi_client_response_llhttp.c` — the FFI glue: `parser_init` /
  `parse` / `to_ffi` reimplemented over llhttp callbacks, producing the same
  `ngx_http_ffi_client_ffi_resp_t` (status / headers / body).
- `src/ngx_http_ffi_client.h` — llhttp-variant parser struct (under
  `NGX_HTTP_FFI_CLIENT_USE_LLHTTP`); a backend-neutral `op->received` flag.
- `src/ngx_http_ffi_client_request.c` — drops the only place that peeked at a
  parser-internal field (`parser.raw`) in favour of `op->received`. The
  request lifecycle, network I/O, coroutine yield/resume, and keepalive pool
  are otherwise unchanged.
- `config` — `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1` selects the llhttp backend. The
  vendored llhttp is compiled into a standalone `libllhttp.a` (its generated C
  is thus exempt from nginx's `-Werror`) and linked via `CORE_LIBS`.

The Lua caller and the FFI request/response structs are **unchanged**: the
backend is a compile-time swap invisible to `lib/resty/ngx_http_ffi_client.lua`.

## Build and default status

```sh
# from an openresty source tree, pointing --add-module at this repo
NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1 NGX_HTTP_LUA_MODULE_DIR=<ngx_lua> \
  ./configure --add-module=<this repo> ...
make && make install
```

Without `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1`, the build still uses the original
hand-written parser. That is the current default backend and test baseline.

This does not mean the project intends to keep two HTTP/1 parser designs. The
compile-time switch is a migration boundary: it keeps the existing behavior
available while the llhttp path absorbs the remaining HTTP/1 edge cases and the
tests are updated around that behavior. New HTTP/1 parsing and framing work
should target llhttp rather than extending the hand-written parser.

## Benchmark

Self-looping keepalive path (`/bench` handler issues a keepalive FFI request to
a local `/mock` returning a small `Content-Length` body), driven with `wrk`.

```sh
WRK_BIN=/path/to/wrk benchmark/bench-http11.sh <nginx-binary> <label>
# 30s, 2 threads, 64 connections
```

Single saturated worker, same machine, back-to-back runs:

| Backend | Requests/sec | vs C baseline |
| --- | ---: | ---: |
| C (hand-written parser) | 43758.88 | baseline |
| **llhttp** | **43213.74** | **-1.25%** |

llhttp lands within ~1% of the hand-written C parser — parity within run noise —
while borrowing a battle-tested, framing-complete parser.

Correctness smoke on both builds: `/bench` returns the expected body and the
keepalive reuse check reports `first:false second:true`.

## Current HTTP/1 work

- Response body is still fully buffered before returning to Lua (no streaming);
  SSE / very large bodies need an incremental/streaming FFI contract.
- HEAD-response body suppression is not wired (llhttp cannot infer the request
  method from the response alone); GET/POST are covered.
- More HTTP/1 edge cases still need production handling: chunked bodies,
  trailers, bodyless responses (`204`/`304`/`HEAD`), connection-close framing,
  timeout and error paths, and request-smuggling hardening.
- TLS certificate handling, SNI, and mTLS are future HTTP/1 client work in this
  module's transport layer, while HTTP/1 parsing and framing stay built around
  llhttp.

## Explicit non-goals

HTTP/2 and HTTP/3 are not part of this document's implementation direction.
Those protocols may require different APIs and wrappers later; they should not
drive the current HTTP/1 client contract.
