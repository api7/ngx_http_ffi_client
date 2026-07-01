# llhttp response-parser PoC

This is a proof of concept that replaces the hand-written HTTP/1.x **response
parser** with [llhttp](https://github.com/nodejs/llhttp) (the parser used by
Node.js core and undici), behind the exact same FFI contract, while keeping
nginx's event loop and keepalive pool untouched.

## Why

The current response parser (`src/ngx_http_ffi_client_response.c`) is a
hand-written "buffer until CRLFCRLF then split" implementation. It rejects
`Transfer-Encoding: chunked`, hard-requires `Content-Length` (so `204/304/HEAD`
and connection-close bodies fail), and owns security-sensitive framing itself.

llhttp is a sans-io state machine: you feed it bytes, it fires callbacks. It
does full HTTP/1.0+1.1 message framing (chunked, trailers, keep-alive,
Content-Length, EOF) and is fuzzed continuously as Node's parser. It needs no
async runtime, so nginx stays the sole I/O driver — a single Lua coroutine, no
second event loop.

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

## Build

```sh
# from an openresty source tree, pointing --add-module at this repo
NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1 NGX_HTTP_LUA_MODULE_DIR=<ngx_lua> \
  ./configure --add-module=<this repo> ...
make && make install
```

Without the env var the build uses the original hand-written parser, unchanged.

## Benchmark

Self-looping keepalive path (`/bench` handler issues a keepalive FFI request to
a local `/mock` returning a small `Content-Length` body), driven with `wrk`.

```sh
WRK_BIN=/path/to/wrk benchmark/bench-http11.sh <nginx-binary> <label>
# 30s, 2 threads, 64 connections
```

Single saturated worker, same machine, back-to-back runs:

| Backend | Requests/sec | vs C |
| --- | ---: | ---: |
| C (hand-written parser) | 43758.88 | baseline |
| **llhttp** | **43213.74** | **-1.25%** |
| hyper, no nginx keepalive (ref) | 11517.23 | -74% |
| hyper, keepalive bench (ref, PR #9) | 30859.57 | -29% |

llhttp lands within ~1% of the hand-written C parser — parity within run noise —
while borrowing a battle-tested, framing-complete parser. The hyper reference
numbers (its async runtime bridged onto nginx's event loop) are from PR #9's
runs on the same setup, shown for context.

Correctness smoke on both builds: `/bench` returns the expected body and the
keepalive reuse check reports `first:false second:true`.

## Known limitations (PoC scope)

- Response body is still fully buffered before returning to Lua (no streaming);
  SSE / very large bodies need the incremental/streaming FFI contract that is
  out of scope here.
- HEAD-response body suppression is not wired (llhttp cannot infer the request
  method from the response alone); GET/POST are covered.
- This swaps only the parser. TLS/SNI/mTLS (rustls) and HTTP/2 (hyper) remain
  future layers below/above this seam.
