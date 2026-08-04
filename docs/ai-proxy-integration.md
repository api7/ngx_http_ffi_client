# Track B: APISIX ai-proxy integration

API contract findings from checking `resty.ngx_http_ffi_client` against what
APISIX's ai-proxy path actually needs from `lua-resty-http`.

Checked against APISIX at `636100ec` and this library at `f13fcfa`.

## The seam described in the plan does not exist

The plan assumes `apisix/apisix/plugins/ai-transport/http.lua`, "already a seam"
exposing `_M.request(params, timeout)` and `_M.set_keepalive(res, ...)`, behind
which an alternate transport is "roughly 30 lines".

There is no `ai-transport` directory in APISIX at `636100ec`. The outbound call
lives inline in `apisix/plugins/ai-drivers/openai-base.lua`, in `_M.request()`,
interleaved with everything else that function does:

```
_M.request(self, ctx, conf, request_table, extra_opts)
    http.new() / set_timeout
    fetch_gcp_access_token          -- auth, may return early
    url.parse(endpoint)             -- scheme/host/port/path/query derivation
    construct_forward_headers
    self.request_filter(...)        -- per-driver hook that mutates params
    httpc:connect(params)
    core.json.encode(params.body)
    httpc:request(params)
    if status == 429 or 5xx: return  -- retry-relevant, before the body is read
    read_response(...)              -- SSE loop or buffered read
    httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
```

`read_response` is a separate local function that receives `res` and drives
either the SSE `body_reader` loop or a buffered read.

So B3.1 is not "write a 30-line module". It is "extract a transport interface
from `openai-base.lua`, then write the second implementation behind it". The
extraction is the larger and more contentious half, and it is a change to
APISIX, not to this library. That reordering should be agreed before the work
starts, because it changes who reviews it and where the risk sits.

The rest of this document is B3.2 done statically: the contract gaps that the
swap would hit, found by reading both sides rather than by running the swap.

## The surface ai-proxy needs

| call | used for |
| --- | --- |
| `http.new()` | one client per request |
| `httpc:set_timeout(ms)` | single-argument form |
| `httpc:connect(params)` | `scheme`, `host`, `port`, `ssl_verify`, `ssl_server_name`; the whole params table is passed and unknown keys are expected to be ignored |
| `httpc:request(params)` | `method`, `path`, `query` (table), `headers`, `body` (string) |
| `res.status` | retry decision, before the body is read |
| `res.headers["Content-Type"]` | picks the SSE path |
| `res.body_reader` | SSE, chunk by chunk |
| `res:read_body()` | buffered responses |
| `httpc:set_keepalive(timeout, pool_size)` | `conf.keepalive_timeout`, `conf.keepalive_pool` |
| error strings | `handle_error` maps any error containing `timeout` to 504, everything else to 500 |

## Already satisfied

These were checked and need no work:

- **`new`, `set_timeout`, `connect`, `request`, `set_keepalive`, `close`,
  `get_reused_times`** all exist with matching signatures.
- **`connect` ignores unknown keys.** ai-proxy passes the whole `params` table,
  including `method`, `headers`, `body` and `query`, into `connect`. This
  library reads only the keys it knows.
- **`query` as a table** is encoded with `ngx.encode_args`, as `lua-resty-http`
  does.
- **`res.headers["Content-Type"]`** resolves through the case-insensitive
  metatable regardless of the casing the provider used.
- **`res.body_reader` is the default.** `request{}` without `preread_body` sets
  up the streaming reader, which is what the SSE path needs. The buffered fast
  path is opt-in, so a naive swap gets streaming behaviour, not a surprise
  full-body buffer.
- **Timeout error strings.** `handle_error` looks for the substring `timeout`;
  the C path emits exactly `"timeout"` for read, connect and TLS-handshake
  timeouts, deliberately, with a comment saying it matches the cosocket. A 504
  stays a 504.
- **Keepalive pool isolation.** ai-proxy passes no explicit pool name, so the
  key is derived. The derivation is a tagged, length-prefixed encoding of
  `[ssl][verify][host:port][ssl_server_name][ssl_trusted_certificate]`, so
  connections cannot cross between TLS and plaintext, between verify modes,
  between SNI names, or between trusted CAs. With one gateway fronting several
  providers on different TLS settings this is the property that matters most,
  and it holds.

## Gaps

### 1. `request_uri` is a module function, not a method

`lua-resty-http` exposes `httpc:request_uri(uri, params)`. This library exposes
`client.request_uri(opts)` at module level, taking a table rather than a URI
string, and has no method of that name on the client object.

ai-proxy does not call it, so it does not block the swap. Every other APISIX
plugin that reaches for `resty.http` does, though, so it blocks the "drop-in"
claim in general. Either add a `request_uri` method with the `lua-resty-http`
signature, or state plainly in the README that the one-shot entry point is
deliberately different.

### 2. `res.reason` and `res.has_body` are missing

`lua-resty-http` sets both on the response table. This library sets neither.

ai-proxy does not use them, so this is not a blocker for Track B. It is a
drop-in gap for anything that logs `res.reason`, and `has_body` is the idiomatic
way to check for a bodyless response before touching the reader.

### 3. No proxy support

`lua-resty-http` has `set_proxy_options` and honours `proxy_opts` in `connect`
and `request_uri`. This library has none.

ai-proxy's `openai-base.lua` does not use it, but `request_filter` hooks are
free to set it and APISIX deployments behind a corporate proxy will want it.
This is the largest single missing feature relative to `lua-resty-http`.

### 4. Request bodies must be strings

`lua-resty-http` accepts a string, a table of strings, or a function for the
request body, and supports chunked request framing. This library takes a string
only, and refuses `Transfer-Encoding` outright because it always frames with
`Content-Length`.

ai-proxy JSON-encodes to a string first, so it is unaffected. Any caller
streaming a request body is not portable to this client.

### 5. `Connection` and `Content-Length` are sent on every request

Found by the benchmark's fairness audit: this library emits

```
Connection: keep-alive
Content-Length: 0
```

on requests where `lua-resty-http` emits neither. `lua-resty-http` only sets
`Content-Length` for methods that expect a body.

For ai-proxy this is low risk: the requests are POSTs with a body, so
`Content-Length` is correct and present either way, and the only difference on
the wire is the explicit `Connection: keep-alive`. It is worth a deliberate
decision rather than an accident, because a `Content-Length: 0` on a GET is the
kind of thing a strict provider or CDN in front of one can reject, and this
would show up as provider-specific failures rather than as an obvious bug.

## What B3.3 to B3.5 still need

- **B3.3, compatibility.** Running APISIX's ai-proxy suite under both transports
  needs the transport interface from B3.1 to exist first, plus an APISIX test
  environment. Not attempted here.
- **B3.4, end-to-end performance.** Needs a mock openai-compatible SSE upstream
  on localhost. Against a real provider, network and provider latency dominate
  and the client CPU difference disappears into variance, so a real-provider run
  is a sanity check only, as the plan already says.
- **Both** need the same 8-core topology Track A needs, for the same reason.

The Track A harness already covers the three surfaces ai-proxy leans on most
(`body_reader` streaming, TLS, and resolving a peer by hostname) as the
`stream`, `tls` and `dns` cases, so a regression in any of them is visible
without standing up APISIX at all.
