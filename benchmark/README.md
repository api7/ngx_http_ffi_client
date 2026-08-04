# Benchmark

This directory holds the local benchmark comparing
`resty.ngx_http_ffi_client` with `lua-resty-http` / `resty.http`.

The benchmark is scoped to the current HTTP/1.1 client work. It validates the
C/Nginx module path and the llhttp-based HTTP/1 direction; it does not evaluate
HTTP/2, HTTP/3, or alternative protocol APIs.

Two things are measured, in two separate passes:

- **Throughput**: maximum QPS with the target OpenResty worker pinned to one
  core and that core saturated.
- **Latency**: p50/p99/p99.9 at a fixed rate below saturation. Latency measured
  at saturation is queue depth, not client cost, so it gets its own pass.

A baseline endpoint that returns the same response body without contacting the
upstream runs alongside both, so the downstream leg can be subtracted out.

## Results

Target worker pinned to CPU `0`, upstream on `1-5` with 5 workers, wrk2 on
`6-7`. Median of 5 repeats, 10s discarded warmup and 30s measured per repeat,
`llhttp` parser, `RESPONSE_SIZE=1024`, `WRK_CONNECTIONS=100`. Every row below
was saturated (target worker CPU >= 95%) and reported no non-2xx responses; no
rows were discarded.

### Headline

| shape | C FFI | `resty.http` | C FFI / `resty.http` | outbound cost ratio |
| --- | ---: | ---: | ---: | ---: |
| `oneshot` | `30154.14` | `14785.18` | `2.04x` | `2.64x` |
| `stateful` | `27316.07` | `15381.85` | `1.78x` | `2.16x` |

Baseline (no upstream call): `82184.57` QPS, `12.168` us/request.

### Detail

| case | median QPS | min | max | repeats used | worker CPU avg | worker RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline` | `82184.57` | `81513.32` | `85599.33` | 5 | `109.3%` | `37300` KB |
| `ffi.oneshot` | `30154.14` | `29789.00` | `30489.65` | 5 | `116.7%` | `37300` KB |
| `ffi.stateful` | `27316.07` | `27143.61` | `27724.92` | 5 | `115.9%` | `37300` KB |
| `resty.oneshot` | `14785.18` | `13465.86` | `14855.69` | 5 | `113.5%` | `37300` KB |
| `resty.stateful` | `15381.85` | `15275.92` | `15617.69` | 5 | `114.3%` | `37332` KB |

### Latency, fixed rate at 60% of the slower path

| case | rate | p50 | p99 | p99.9 |
| --- | ---: | ---: | ---: | ---: |
| `ffi.oneshot` | `8871` req/s | `1.060` ms | `2.450` ms | `5.430` ms |
| `resty.oneshot` | `8871` req/s | `1.370` ms | `3.920` ms | `10.550` ms |
| `ffi.stateful` | `9229` req/s | `1.160` ms | `3.360` ms | `20.940` ms |
| `resty.stateful` | `9229` req/s | `1.400` ms | `3.740` ms | `6.800` ms |

At those fixed rates the worker sat at `45.6%` CPU on `ffi.oneshot` against
`72.4%` on `resty.oneshot`, which is the same comparison measured from the
other side.

### Per-request Lua heap delta

| case | KB/request |
| --- | ---: |
| `ffi.oneshot` | `2.494` |
| `ffi.stateful` | `3.331` |
| `resty.stateful` | `6.492` |
| `resty.oneshot` | `7.448` |

### Matrix

The full case matrix, median of 2 repeats (`BENCH_CASES=all`, same host and
topology, `matrix.csv`). Every row was saturated with no non-2xx responses and
nothing was discarded; per-case spread was under 1% on most cases.

| shape | C FFI | `resty.http` | C FFI / `resty.http` | outbound cost ratio |
| --- | ---: | ---: | ---: | ---: |
| `trailers` | `27919.64` | `6325.35` | `4.41x` | `6.10x` |
| `oneshot` | `28052.14` | `14314.11` | `1.96x` | `2.44x` |
| `hdr40` | `17337.44` | `9235.26` | `1.88x` | `2.10x` |
| `post` | `24121.31` | `12826.85` | `1.88x` | `2.23x` |
| `req30` | `23370.36` | `13014.28` | `1.80x` | `2.10x` |
| `cookies` | `24343.96` | `13719.88` | `1.77x` | `2.09x` |
| `chunked` | `26844.53` | `15521.60` | `1.73x` | `2.07x` |
| `dns` | `26937.76` | `15538.12` | `1.73x` | `2.08x` |
| `stateful` | `26365.78` | `15289.51` | `1.72x` | `2.05x` |
| `stream` | `26490.00` | `15686.39` | `1.69x` | `2.00x` |
| `readbody` | `26051.07` | `15462.52` | `1.68x` | `1.99x` |
| `tls` | `17732.35` | `11861.95` | `1.49x` | `1.63x` |
| `short` | `8275.94` | `6973.64` | `1.19x` | `1.21x` |
| `tlsshort` | `872.96` | `1108.38` | `0.79x` | `0.79x` |

Baseline: `84504.18` QPS.

### Where the FFI client does not win

**`tlsshort`, a fresh TLS handshake per request: `0.79x`.** `872.96` QPS against
`resty.http`'s `1108.38`, so this client is about 21% slower. The bottom of the
table reads as one story rather than three: `tls` (`1.49x`), `short` (`1.19x`)
and `tlsshort` (`0.79x`) are exactly the cases where connection setup dominates
the request. The advantage this client has is in per-request work, and it
shrinks as setup takes over, then reverses once setup is nearly all of it.
Anything that cannot hold a keepalive pool, and TLS to many short-lived peers
most of all, is a case where `lua-resty-http` is currently the better choice.

**`ffi.stateful` tail latency.** `p99.9` of `20.940` ms against
`resty.stateful`'s `6.800` ms, a roughly 3x worse tail, even though `p50` and
`p99` are both better. `ffi.oneshot` shows no such tail at `5.430` ms, so
something on the stateful object's path stalls occasionally in a way the
one-shot path does not.

This one is **not yet evidence**: the latency phase ran a single 30s window per
case, and tail percentiles are the noisiest thing measured here. Re-run with
`BENCH_LATENCY_REPEATS=3` before acting on it, and attribute with `perf` (A7) if
it survives.

### Reading the matrix numbers

Two caveats on the matrix table specifically, neither of which applies to the
five-case headline run above:

- **Two repeats, not five.** Enough for the ranking, which is stable, and the
  min/max spread is under 1% on most cases. Not enough to argue about a
  difference of a few percent between adjacent rows.
- **Worker RSS is cumulative in an `all` run and should be ignored there.** It
  climbs from about `527` MB on the early cases to `1.5` GB on the late ones,
  which is 28 separate keepalive pools of up to `120` connections each
  accumulating over the run, not per-case memory. The headline run, with five
  cases and four pools, held steady at about `37` MB. Read RSS from a run that
  measures the cases you care about, not from the sweep.

## What the previous numbers said, and why they were withdrawn

The tables that used to sit here reported the C FFI client as `2.04x`-`2.63x`
faster end-to-end and spending `2.70x`-`3.72x` less outbound CPU. Measured
properly against the current library, the matched one-shot pair is `2.04x` on
throughput and `2.64x` on outbound cost: the same ballpark, but the old `2.63x`
headline was not comparing what it claimed to. Two independent problems:

**The two cases compared different API shapes.** `/bench/ffi` called
`client.request_uri`, the one-shot C fast path that resumes the coroutine once.
`/bench/resty-http` drove a stateful object: `new` → `connect` → `request` →
`read_body` → `set_keepalive`. When that config was written this library only
had `request_uri`; `_M.new()` now exists with the same shape as
`lua-resty-http`. The old ratio therefore contained the API-shape difference and
attributed all of it to C versus Lua.

**They predate most of the current hot path.** Landed since those runs:
per-request token validation of the method and header names with
control-character checks on values, the case-insensitive header metatable with
repeated headers folded into arrays, `llhttp` as the default parser, interim
`1xx` consumption, and trailer parsing. Each adds per-request work.

The harness below fixes both, and the Results section above is what it produces.

## Topology requirement

The measurement assumes three things that a small host cannot provide at once: a
target worker that is the only thing on its core, an upstream that cannot become
the bottleneck, and a load generator competing with neither.

| role | CPUs | why |
| --- | --- | --- |
| target OpenResty worker | 1, exclusive | this is the thing being measured |
| upstream mock | 5 | must never be the bottleneck |
| wrk2 | 2 | must be able to saturate the target |

That means **8 or more dedicated cores**. `run.sh` warns when fewer are online
and still runs, because the saturation gate will mark the rows invalid anyway.
Below eight cores this is a regression smoke test, not a source of headline
numbers. GitHub Actions runners (4 shared vCPUs) fall in that category.

`run.sh` requires `taskset` and `/proc`, so it does not run on macOS.

## The comparison is a 2x2

The headline ratio comes from reading one shape across both columns:

|                | one-shot        | stateful                                                |
| -------------- | --------------- | ------------------------------------------------------- |
| C FFI          | `ffi.oneshot`   | `ffi.stateful`                                          |
| `resty.http`   | `resty.oneshot` | `resty.stateful`                                        |

`ffi.oneshot` and `resty.oneshot` both call `request_uri`. `ffi.stateful` and
`resty.stateful` both drive `new`/`connect`/`request`/read/`set_keepalive`. The
gap between `ffi.oneshot` and `ffi.stateful` separately prices the C fast path
against this library's own Lua object layer, which is a different question from
the C-versus-Lua one and should not be mixed into it.

## Case matrix

Cases are named `<driver>.<shape>` and listed in
[`cases.txt`](cases.txt), which is the single source of truth: `run.sh`
generates one nginx location per name from it, and the smoke check diffs it
against the case table the worker actually loaded, so the two cannot drift.

| shape | axis it prices |
| --- | --- |
| `oneshot`, `stateful` | API shape; the headline pair |
| `readbody` | buffering through the Lua chunk loop instead of the C preread fast path |
| `stream` | `res.body_reader`, chunk by chunk |
| `short` | connection setup, with no keepalive pool |
| `post` | a 4KB request body |
| `tls` | TLS with a pooled connection |
| `tlsshort` | a fresh TLS handshake per request |
| `dns` | resolving the peer by hostname instead of an IP literal |
| `chunked` | chunked response framing |
| `trailers` | chunked framing with a trailer section |
| `hdr40` | 40 response headers |
| `cookies` | ten repeated `Set-Cookie` headers, which fold into an array |
| `req30` | 30 request headers, which prices per-request header validation |

Axes that are not cases because they are swept by environment instead:

- **Body size** via `RESPONSE_SIZE` (the plan sweeps 0, 1KB, 16KB, 256KB, 1MB).
- **Concurrency** via `WRK_CONNECTIONS` (1, 10, 50, 100, 500).
- **Parser backend** by building the module twice, with
  `NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1` and `=0`, and setting `BENCH_PARSER` so the
  rows are labelled.

The full cross-product is too large to run. Sweep body size against concurrency
on the plaintext keepalive GET, then run one point per remaining axis against
that same reference configuration.

Not every case works on every build. The hand-written parser has no chunked
framing, so `ffi.chunked` and `ffi.trailers` fail their smoke check there; they
are excluded from the run, named in the summary, and the rest proceeds.
`BENCH_STRICT=1` aborts instead.

## Fairness audit

An unfair configuration makes every number worthless, so the runner proves
fairness before applying any load rather than asserting it in prose.

Both columns of a pair are generated from one shape table in
[`lua/bench.lua`](lua/bench.lua), so identical pool size, idle timeout,
timeouts, request headers and body consumption are structural rather than
reviewed. On top of that, the upstream exposes `/mock/echo`, which replies with
the raw request header block it received. The runner fetches it through both
clients and diffs:

- **The request line and every caller-supplied header must match.** A difference
  means the pair is not measuring the same request, and the audit fails.
- **Headers a client generates for itself are reported, not failed.** They are
  the client's own contract.

That second category is not empty. The FFI client emits two headers on every
request that `lua-resty-http` does not:

```
Connection: keep-alive
Content-Length: 0
```

`lua-resty-http` omits both on a bodyless GET; it only sets `Content-Length` for
methods that expect a body. The C path always writes `Content-Length` from
`req->body.len`. This costs the FFI client roughly 45 extra bytes per request to
format and send, so it works against the FFI side of the ratio rather than
inflating it, but it is a real difference in the request being measured and a
`Content-Length: 0` on a GET is the kind of thing a strict peer can reject. It
is worth deciding deliberately whether the C path should keep emitting it.

Connection reuse is verified from the upstream side rather than the target's,
which keeps the check off the measured worker entirely. The upstream counts
connections and requests in a shared dict; the counters are reset after the
warmup, so they describe the steady state. **Zero new connections against a
non-zero request count is perfect pool reuse** and is what the keepalive cases
should report. A ratio near one request per connection means the pool is not
reusing anything, and the runner warns.

Any row reporting non-2xx responses is invalid, and so is any throughput row
where the target worker averaged below `CPU_SATURATION_THRESHOLD`. Both are
excluded from every median and counted in the summary.

## Metrics

| metric | how |
| --- | --- |
| throughput | saturated QPS, gated on >=95% target-worker CPU |
| latency | p50/p99/p99.9 from a separate fixed-rate pass at 60% of the slower path's median saturated QPS |
| outbound cost | baseline-subtracted `1/QPS`, compared as `resty.http / C FFI` |
| worker RSS | `VmRSS` of the pinned worker at the end of the measured window |
| Lua heap per request | `collectgarbage("count")` delta over 20 requests, via `/gcdelta/<case>` |

The Lua heap delta is reported rather than left as a diagnostic. The library's
claim is that response handling stays in C, and the header arrays plus the
case-insensitive metatable are exactly where that could regress.

wrk2 is run with `-L -U`, which emits both a coordinated-omission-corrected
distribution and an uncorrected one. The corrected figures are reported by
default, since correcting for delayed starts is the reason to run wrk2 at a
fixed rate at all. `BENCH_LATENCY_MODE=uncorrected` selects the other block.

## Protocol

Per data point: `BENCH_REPEATS` repeats (default 5), each a discarded
`WRK_WARMUP` warmup followed by a measured `WRK_DURATION` window. Cases rotate
within each repeat rather than running back to back, so drift and background
load land on every case equally. Results are reported as the median with the
min/max spread.

## Command

```bash
export TEST_NGINX_BINARY=/path/to/openresty/nginx/sbin/nginx
export TEST_NGINX_LUA_PACKAGE_PATH="$PWD/lib/?.lua;$PWD/lib/?/init.lua;/path/to/lua-resty-http/lib/?.lua"
export WRK2_BIN=/path/to/wrk2/wrk

# the headline 2x2
make bench

# the whole matrix
BENCH_CASES=all make bench

# one axis point
BENCH_CASES="baseline ffi.stream resty.stream" RESPONSE_SIZE=262144 make bench
```

The module has to be compiled into the nginx binary:

```bash
NGX_HTTP_FFI_CLIENT_USE_LLHTTP=1 \
NGX_HTTP_LUA_MODULE_DIR=/path/to/openresty/bundle/ngx_lua-VERSION \
  ./configure --prefix=/tmp/openresty-llhttp --with-http_ssl_module \
              --with-pcre-jit --add-module=/path/to/ngx_http_ffi_client
```

## Results

Every run writes one CSV row per wrk2 invocation to
`benchmark/.run/results/<run-id>.csv`, with the run parameters on each row so
rows from different runs can be concatenated:

```
run_id,phase,repeat,case,qps,rate,non2xx,socket_errors,p50_ms,p99_ms,p999_ms,
cpu_avg,cpu_max,cpu_samples,saturated,rss_kb,upstream_connections,
upstream_requests,requests_per_connection,response_size,connections,threads,
duration,parser
```

[`fold.sh`](fold.sh) folds those rows into the markdown tables this file
carries. `run.sh` calls it at the end of a run; it also runs standalone:

```bash
benchmark/fold.sh benchmark/.run/results/<run-id>.csv
```

The tables it emits are the headline ratio per shape, a per-case detail table
with medians and spread, the latency table, and a list of everything discarded.
Paste them in rather than hand-maintaining them, which is what the previous
tables were.

## Dependencies

- OpenResty or Nginx built with `ngx_http_ffi_client_module`
- `lua-resty-http` on `TEST_NGINX_LUA_PACKAGE_PATH`
- `wrk2`
- `curl`, `openssl`, `taskset` from util-linux
- Linux `/proc` for CPU and RSS sampling

## Topology detail

- upstream instance: mock HTTP server on multiple workers, non-target cores,
  plus a TLS listener and a raw TCP `stream` mock for the trailer case, since
  trailers cannot be emitted from the http subsystem
- target instance: one OpenResty worker, pinned to `TARGET_CPU`
- wrk2: load generator, pinned to `WRK_CPUS`

Both instances raise `keepalive_requests` far above the default. At tens of
thousands of requests per second the stock limit would recycle connections
hundreds of times per run: on the downstream leg that charges accept cost to
whichever case is running, and on the upstream leg it would force the client
pools to reconnect and stop the keepalive cases from measuring keepalive.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `BENCH_CASES` | the 2x2 plus baseline | space-separated case names, or `all` |
| `BENCH_REPEATS` | `5` | repeats per data point |
| `BENCH_LATENCY` | `1` | run the fixed-rate latency phase |
| `BENCH_LATENCY_FRACTION` | `0.6` | fraction of the slower path's QPS for that phase |
| `BENCH_LATENCY_MODE` | `corrected` | `corrected` or `uncorrected` percentiles |
| `BENCH_GC` | `1` | report the per-request Lua heap delta |
| `BENCH_AUDIT` | `1` | run the fairness audit before load |
| `BENCH_STRICT` | `0` | abort instead of excluding a case that fails its smoke check |
| `BENCH_PARSER` | `llhttp` | label recorded in the CSV rows |
| `BENCH_RESULTS_DIR` | `.run/results` | where CSV rows are written |
| `TARGET_CPU` | `0` | CPU core used by the target OpenResty worker |
| `UPSTREAM_CPUS` | non-target cores | CPU cores used by the upstream instance |
| `WRK_CPUS` | `UPSTREAM_CPUS` | CPU cores used by wrk2 |
| `TARGET_PORT` | `19840` | target listen port |
| `UPSTREAM_PORT` | `19841` | upstream listen port |
| `UPSTREAM_TLS_PORT` | `19842` | upstream TLS listen port |
| `UPSTREAM_TRAILER_PORT` | `19843` | raw TCP trailer mock port |
| `UPSTREAM_WORKERS` | count of `UPSTREAM_CPUS` | upstream worker count |
| `DNS_HOST` | `localhost` | hostname used by the `dns` cases |
| `BENCH_RESOLVER` | first `/etc/resolv.conf` nameserver | resolver for those cases |
| `TLS_SERVER_NAME` | `bench.local` | SNI both clients send for the TLS cases |
| `RESPONSE_SIZE` | `1024` | upstream response body size in bytes |
| `KEEPALIVE_POOL_SIZE` | `120` | keepalive pool size for both client paths |
| `KEEPALIVE_IDLE_TIMEOUT` | `60000` | keepalive idle timeout in milliseconds |
| `CLIENT_TIMEOUT` | `60000` | connect/send/read timeout for both clients |
| `WRK_THREADS` | `2` | wrk2 thread count |
| `WRK_CONNECTIONS` | `100` | wrk2 connection count |
| `WRK_WARMUP` | `10s` | discarded warmup before each measured window |
| `WRK_DURATION` | `30s` | measured window |
| `WRK_RATE` | `100000` | wrk2 target rate, set above the expected max QPS |
| `CPU_SATURATION_THRESHOLD` | `95` | minimum average target worker CPU for a valid throughput row |

## Baseline-derived estimate

QPS includes the downstream leg. To estimate outbound client cost, the runner
treats single-core CPU time per request as approximately `1 / QPS`:

```text
baseline_us = 1_000_000 / baseline_qps
ffi_outbound_us = 1_000_000 / ffi_qps - baseline_us
resty_outbound_us = 1_000_000 / resty_http_qps - baseline_us
ratio = resty_outbound_us / ffi_outbound_us
```

Every case, the baseline included, writes the same fixed downstream body, so
that subtraction removes an identical cost from each. It is still an estimate.

## If a run is marked unsaturated

Do not compare QPS across cases from runs where the target worker was not the
bottleneck. Increase `WRK_THREADS`, `WRK_CONNECTIONS` or `WRK_RATE`; move wrk2
to non-target cores; or give the upstream more workers and cores.

## Dry run

Renders the configs and generates the locations without starting anything:

```bash
BENCH_DRY_RUN=1 make bench
```
