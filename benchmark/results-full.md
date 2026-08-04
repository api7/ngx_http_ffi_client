# Full-matrix benchmark run (`full`)

Run finished 2026-08-04. This file records one complete run of
`benchmark/run.sh` comparing this repo's C/FFI HTTP client
(`resty.ngx_http_ffi_client`) against `lua-resty-http` 0.16.1 across the full
matrix of request shapes. It is a results record only; it does not replace the
methodology write-up in `benchmark/README.md`.

## What was run

- Run parameters: `BENCH_RUN_ID=full`, `BENCH_CASES=all`, `BENCH_REPEATS=5`,
  `BENCH_LATENCY_REPEATS=3`.
- Hardware: 8-core VM. The target OpenResty worker (openresty/1.29.2.4) was
  pinned to CPU 0, the upstream to CPUs 1-5, and `wrk2` to CPUs 6-7, so the
  measured client always runs on a single dedicated core and neither the load
  generator nor the upstream competes with it.
- The run exited 0. The fairness audit passed for all 14 shapes: every shape
  produced the same request line and the same caller-supplied headers from both
  clients (all 14 `echo-<shape>.diff` artifacts are empty). The only reported
  difference is the known, non-failing one — the FFI client emits
  `Connection: keep-alive` and `Content-Length: 0` on a bodyless GET where
  `lua-resty-http` omits them (`Connection: keep-alive` only, for `post`).
- Raw rows: `benchmark/.run/results/full.csv`, 229 data rows — 145 throughput
  rows (29 cases x 5 repeats) and 84 latency rows (28 cases x 3 repeats).
- Exactly 1 row was discarded: `resty.dns` throughput repeat 1, which reported
  4 non-2xx responses and 13 socket errors. It passed the saturation gate but
  the non-2xx count excludes it. No other row in the file has a non-zero
  `non2xx` or `socket_errors` value, and no throughput row failed the saturation
  gate (`saturated` is `yes` on all 145).

## Folded results

The tables below are the verbatim output of
`./benchmark/fold.sh benchmark/.run/results/full.csv`. Every figure is a median
over the kept repeats.

### Run parameters

parser `llhttp`, response size `1024` bytes, wrk2 connections `100`, duration `30s` per repeat

### Headline (median QPS per shape)

| shape | C FFI | `resty.http` | C FFI / `resty.http` | outbound cost ratio |
| --- | ---: | ---: | ---: | ---: |
| `stream` | `27506.05` | `16236.65` | `1.69x` | `2.02x` |
| `stateful` | `26919.60` | `15604.60` | `1.73x` | `2.05x` |
| `hdr40` | `17724.68` | `9218.37` | `1.92x` | `2.16x` |
| `req30` | `23339.15` | `13283.15` | `1.76x` | `2.04x` |
| `cookies` | `25440.85` | `13603.27` | `1.87x` | `2.23x` |
| `trailers` | `28005.24` | `6622.05` | `4.23x` | `5.77x` |
| `readbody` | `26965.62` | `15710.28` | `1.72x` | `2.04x` |
| `oneshot` | `30925.84` | `14510.37` | `2.13x` | `2.76x` |
| `tlsshort` | `932.16` | `1149.50` | `0.81x` | `0.81x` |
| `post` | `24173.16` | `12780.46` | `1.89x` | `2.24x` |
| `chunked` | `26663.11` | `15366.94` | `1.74x` | `2.06x` |
| `short` | `8721.09` | `7152.20` | `1.22x` | `1.24x` |
| `dns` | `26814.07` | `15634.98` | `1.72x` | `2.04x` |
| `tls` | `18655.46` | `11866.50` | `1.57x` | `1.73x` |

Baseline (no upstream call): `86589.91` QPS, `11.549` us/request.
The outbound cost ratio subtracts that baseline from both client paths and compares what is left.

### Detail (throughput phase)

| case | median QPS | min | max | repeats used | discarded | worker CPU avg | worker RSS | requests/connection |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline` | `86589.91` | `85202.57` | `86833.79` | 5 | 0 | `106.6%` | `2035128` KB | n/a |
| `ffi.chunked` | `26663.11` | `25049.33` | `26744.73` | 5 | 0 | `116.2%` | `3062632` KB | `751598.0` |
| `ffi.cookies` | `25440.85` | `25385.00` | `25508.05` | 5 | 0 | `116.1%` | `3062632` KB | `764350.5` |
| `ffi.dns` | `26814.07` | `25315.59` | `26863.08` | 5 | 0 | `116.2%` | `3062632` KB | `804524.0` |
| `ffi.hdr40` | `17724.68` | `17643.17` | `17737.64` | 5 | 0 | `107.8%` | `3062632` KB | `531768.5` |
| `ffi.oneshot` | `30925.84` | `30751.13` | `31065.85` | 5 | 0 | `117.7%` | `2035128` KB | no new connections |
| `ffi.post` | `24173.16` | `22771.48` | `24269.40` | 5 | 0 | `115.3%` | `2082632` KB | `702825.5` |
| `ffi.readbody` | `26965.62` | `26790.39` | `27007.54` | 5 | 0 | `116.2%` | `2035128` KB | no new connections |
| `ffi.req30` | `23339.15` | `23306.86` | `23466.05` | 5 | 0 | `114.8%` | `3062632` KB | `700270.0` |
| `ffi.short` | `8721.09` | `8389.79` | `8743.68` | 5 | 0 | `105.9%` | `2082104` KB | `1.0` |
| `ffi.stateful` | `26919.60` | `26402.32` | `26949.99` | 5 | 0 | `116.3%` | `2035128` KB | `807690.0` |
| `ffi.stream` | `27506.05` | `27498.37` | `27630.86` | 5 | 0 | `116.7%` | `2035128` KB | `825047.0` |
| `ffi.tls` | `18655.46` | `18438.79` | `18782.34` | 5 | 0 | `114.9%` | `2083824` KB | `563467.5` |
| `ffi.tlsshort` | `932.16` | `861.20` | `933.17` | 5 | 0 | `102.8%` | `3059584` KB | `1.0` |
| `ffi.trailers` | `28005.24` | `27915.10` | `28128.38` | 5 | 0 | `116.2%` | `3062632` KB | n/a |
| `resty.chunked` | `15366.94` | `15164.85` | `15764.74` | 5 | 0 | `114.1%` | `3062632` KB | `53208.0` |
| `resty.cookies` | `13603.27` | `13582.52` | `13898.90` | 5 | 0 | `113.2%` | `3062632` KB | `51824.9` |
| `resty.dns` | `15634.98` | `15489.53` | `15936.46` | 4 | 1 | `114.2%` | `3566436` KB | `46329.1` |
| `resty.hdr40` | `9218.37` | `9200.90` | `9442.03` | 5 | 0 | `111.2%` | `3062632` KB | `30854.3` |
| `resty.oneshot` | `14510.37` | `14299.32` | `14629.47` | 5 | 0 | `113.4%` | `2035128` KB | `89883.6` |
| `resty.post` | `12780.46` | `12371.84` | `13177.75` | 5 | 0 | `113.8%` | `2082632` KB | `94728.2` |
| `resty.readbody` | `15710.28` | `15562.79` | `15942.52` | 5 | 0 | `114.3%` | `2035128` KB | `86699.9` |
| `resty.req30` | `13283.15` | `13208.27` | `13354.04` | 5 | 0 | `112.8%` | `3062632` KB | `22262.1` |
| `resty.short` | `7152.20` | `7099.21` | `7266.89` | 5 | 0 | `105.5%` | `2082228` KB | `1.0` |
| `resty.stateful` | `15604.60` | `15493.86` | `15795.75` | 5 | 0 | `114.4%` | `2035128` KB | `31003.5` |
| `resty.stream` | `16236.65` | `16021.80` | `17296.03` | 5 | 0 | `114.4%` | `2035128` KB | `61189.6` |
| `resty.tls` | `11866.50` | `11503.14` | `12022.41` | 5 | 0 | `113.6%` | `2085452` KB | `36355.9` |
| `resty.tlsshort` | `1149.50` | `1105.48` | `1152.59` | 5 | 0 | `102.9%` | `3063980` KB | `1.0` |
| `resty.trailers` | `6622.05` | `6543.31` | `6782.34` | 5 | 0 | `105.3%` | `3062632` KB | n/a |

### Latency (fixed rate, corrected for coordinated omission)

| case | rate | p50 | p99 | p99.9 |
| --- | ---: | ---: | ---: | ---: |
| `ffi.chunked` | `9220` req/s | `1.060` ms | `2.260` ms | `2.710` ms |
| `ffi.cookies` | `8161` req/s | `1.040` ms | `2.200` ms | `2.670` ms |
| `ffi.dns` | `9380` req/s | `1.070` ms | `2.300` ms | `2.760` ms |
| `ffi.hdr40` | `5531` req/s | `1.030` ms | `2.110` ms | `2.540` ms |
| `ffi.oneshot` | `8706` req/s | `1.020` ms | `2.210` ms | `2.770` ms |
| `ffi.post` | `7668` req/s | `1.050` ms | `2.220` ms | `2.670` ms |
| `ffi.readbody` | `9426` req/s | `1.060` ms | `2.270` ms | `2.770` ms |
| `ffi.req30` | `7969` req/s | `1.150` ms | `2.370` ms | `2.850` ms |
| `ffi.short` | `4291` req/s | `1.180` ms | `2.490` ms | `3.180` ms |
| `ffi.stateful` | `9362` req/s | `1.070` ms | `2.270` ms | `2.730` ms |
| `ffi.stream` | `9741` req/s | `1.090` ms | `2.370` ms | `2.880` ms |
| `ffi.tls` | `7119` req/s | `1.110` ms | `2.340` ms | `2.790` ms |
| `ffi.tlsshort` | `559` req/s | `4.260` ms | `9.010` ms | `11.840` ms |
| `ffi.trailers` | `3973` req/s | `1.000` ms | `2.100` ms | `2.600` ms |
| `resty.chunked` | `9220` req/s | `1.300` ms | `2.800` ms | `3.400` ms |
| `resty.cookies` | `8161` req/s | `1.290` ms | `2.820` ms | `3.480` ms |
| `resty.dns` | `9380` req/s | `1.300` ms | `2.810` ms | `3.380` ms |
| `resty.hdr40` | `5531` req/s | `1.200` ms | `2.540` ms | `3.080` ms |
| `resty.oneshot` | `8706` req/s | `1.290` ms | `2.830` ms | `3.410` ms |
| `resty.post` | `7668` req/s | `1.320` ms | `2.800` ms | `3.350` ms |
| `resty.readbody` | `9426` req/s | `1.270` ms | `2.760` ms | `3.350` ms |
| `resty.req30` | `7969` req/s | `1.500` ms | `3.020` ms | `3.940` ms |
| `resty.short` | `4291` req/s | `1.300` ms | `2.740` ms | `3.310` ms |
| `resty.stateful` | `9362` req/s | `1.270` ms | `2.750` ms | `3.320` ms |
| `resty.stream` | `9741` req/s | `2.040` ms | `4.650` ms | `5.630` ms |
| `resty.tls` | `7119` req/s | `2.330` ms | `5.410` ms | `6.580` ms |
| `resty.tlsshort` | `559` req/s | `3.330` ms | `5.610` ms | `8.030` ms |
| `resty.trailers` | `3973` req/s | `1.890` ms | `43.520` ms | `109.570` ms |

### Discarded rows

Rows failing the saturation gate or reporting non-2xx responses, excluded from every median above:

- `resty.dns`: 1 of 5

## What this shows

- The FFI client wins throughput on 13 of the 14 shapes. Excluding `trailers`,
  the ratios span `1.22x` (`short`, 8721.09 vs 7152.20 QPS) to `2.13x`
  (`oneshot`, 30925.84 vs 14510.37 QPS); the common keepalive shapes
  (`stream`, `stateful`, `readbody`, `chunked`, `dns`) cluster at `1.69x`-`1.74x`.
- `trailers` is the largest win at `4.23x` (28005.24 vs 6622.05 QPS), and
  `5.77x` once the baseline is subtracted from both paths.
- `tlsshort` is the one shape the FFI client LOSES: `0.81x` (932.16 vs 1149.50
  QPS). That shape opens a fresh TLS connection and performs a full handshake
  for every request, so the measurement is dominated by handshake cost rather
  than by client-side request/response handling. Use `lua-resty-http` if your
  workload really does handshake per request.
- Latency: the FFI client wins p50, p99 and p99.9 on every shape except
  `tlsshort`. Typical keepalive p50 is `1.02`-`1.15` ms for FFI against
  `1.27`-`1.50` ms for `resty.http`, and p99.9 is `2.54`-`3.18` ms against
  `3.08`-`3.94` ms.
- On `tlsshort` the FFI client loses the latency picture too: p50 `4.260` vs
  `3.330` ms, p99 `9.010` vs `5.610` ms, p99.9 `11.840` vs `8.030` ms.
- Connection reuse differs sharply. On keepalive shapes the FFI client either
  opened no new upstream connections at all during the measured window
  (`oneshot`, `readbody`) or reached 5.3e5-8.3e5 requests per new connection,
  while `resty.http` sat at 2.2e4-9.5e4. Both clients are at `1.0` on the
  deliberately non-keepalive shapes (`short`, `tlsshort`).
- Repeat-to-repeat spread was small. Across the 5 throughput repeats, 20 of the
  29 cases had a max-min spread under 4% of the maximum; the widest were
  `ffi.tlsshort` at 7.71% (861.20-933.17), `resty.stream` at 7.37%
  (16021.80-17296.03) and `ffi.chunked` at 6.34% (25049.33-26744.73). The
  baseline varied by 1.88% (85202.57-86833.79).
- The `trailers` rows carry no requests-per-connection figure because the
  upstream connection counters read 0/0 for both clients on that shape; the
  QPS and latency numbers for `trailers` are unaffected.

## Correction: the `ffi.stateful` p99.9 tail claim is disproven

An earlier run suggested that `ffi.stateful` had a bad p99.9 tail of 20.94 ms
against `resty.stateful` at 6.80 ms. That was a single-sample artifact. This run
used 3 latency repeats and the result does not reproduce:

| case | p50 | p99 | p99.9 |
| --- | ---: | ---: | ---: |
| `ffi.stateful` | `1.070` ms | `2.270` ms | `2.730` ms |
| `resty.stateful` | `1.270` ms | `2.750` ms | `3.320` ms |

The FFI client wins the tail on `stateful`, it does not lose it. The three
individual `ffi.stateful` p99.9 samples were 2.720, 2.730 and 2.730 ms — tightly
clustered, with nothing near 20 ms — against 3.320, 3.340 and 3.280 ms for
`resty.stateful`. Do not act on the old 20.94 ms claim; it is superseded by
this run.

## Reverse finding: `resty.trailers` tail latency

The one genuinely large tail in the whole run belongs to `lua-resty-http`, not
to the FFI client. On the `trailers` shape at 3973 req/s:

| case | p50 | p99 | p99.9 |
| --- | ---: | ---: | ---: |
| `ffi.trailers` | `1.000` ms | `2.100` ms | `2.600` ms |
| `resty.trailers` | `1.890` ms | `43.520` ms | `109.570` ms |

That is a 42x gap at p99.9. It is also unstable across repeats: the three
`resty.trailers` p99.9 samples were 109.570, 196.610 and 11.970 ms (p99: 43.520,
126.850 and 3.600 ms), while `ffi.trailers` produced 2.690, 2.600 and 2.560 ms.
The median reported above is the middle sample in each case.

---

# TLS re-measurement after the trust-store fix (`fix`)

Run finished 2026-08-04, after the run recorded above. This section records a
targeted re-measurement of the TLS shapes following the fix in
`src/ngx_http_ffi_client_request.c` that stopped the client rescanning the CA
directory on every handshake. It supersedes the `tls` and `tlsshort` numbers in
the `full` run above; every other shape in this file is unaffected and still
stands.

## What was run

- Run parameters: `BENCH_RUN_ID=fix`, `BENCH_REPEATS=5`,
  `BENCH_LATENCY_REPEATS=3`, `BENCH_CASES="ffi.tls resty.tls ffi.tlsshort
  resty.tlsshort ffi.tlsverify resty.tlsverify ffi.tlsverifyshort
  resty.tlsverifyshort"`.
- Same topology as the `full` run: target worker pinned to CPU 0, upstream on
  CPUs 1-5, `wrk2` on CPUs 6-7.
- The run exited 0. The fairness audit passed for all four shapes. All 40
  throughput windows passed the saturation gate with zero non-2xx and zero
  socket errors; nothing was discarded.
- `requests_per_connection` is `1.0` for both clients on all four short-lived
  cases, so those windows really are measuring a fresh connection and handshake
  per request rather than a partly-pooled result.
- Raw rows: `benchmark/.run-fix/results/fix.csv`, 64 data rows.

## The defect

`ngx_http_ffi_client_ssl_ctx()` called `SSL_CTX_set_default_verify_paths()`
unconditionally. That registers the hashed CA directory as
`X509_FILETYPE_DEFAULT`, and under `DEFAULT` OpenSSL enumerates the entire
directory on *every* handshake instead of opening the single `<hash>.N` file the
lookup needs.

Found with `perf`, sampling the pinned target worker for 40 s during each case
(~40000 samples each). Every top entry in the `perf diff` is kernel
directory-reading code, present only on the FFI side:

```
Baseline  Delta Abs  Symbol
           +2.04%  [k] filldir64
           +2.01%  [k] ext4_htree_store_dirent
           +1.82%  [k] str2hashbuf_signed
           +1.76%  [k] half_md4_transform
           +1.05%  [k] htree_dirblock_to_tree
```

| | C FFI | `lua-resty-http` |
| --- | ---: | ---: |
| CPU in directory-lookup code | `11.83%` | `0.42%` |
| CPU in the kernel overall | `36.7%` | `17.9%` |

Confirmed at the syscall level under load: 2132 `openat` plus 4264 `getdents64`
for ~2168 requests, one full sweep of a 245-entry directory per handshake. The
same trace during `resty.tlsshort` caught none. After the fix, tracing both
`ffi.tlsshort` and `ffi.tlsverifyshort` caught none either.

The cost is the filetype, not hash-directory lookup and not lookup failure.
Reproduced independently of this module with `openssl s_client` against the
benchmark upstream:

| trust store setup | `getdents64` calls | verify result |
| --- | ---: | --- |
| `set_default_verify_paths()` | `4` | 18 (self-signed) |
| explicit `-CAfile` system bundle | `0` | 18 |
| explicit `-CApath` system dir | `0` | 18 |
| explicit `-CApath`, issuer present | `0` | 0 (ok) |

## Throughput (median of 5 saturated repeats)

| shape | C FFI | `lua-resty-http` | ratio |
| --- | ---: | ---: | ---: |
| `tls` | `18276.36` req/s | `11926.11` req/s | `1.53x` |
| `tlsshort` | `1256.86` req/s | `1142.44` req/s | `1.10x` |
| `tlsverify` | `17542.73` req/s | `11861.35` req/s | `1.48x` |
| `tlsverifyshort` | `1228.67` req/s | `1136.91` req/s | `1.08x` |

Against the `full` run above:

| shape | before | after | ratio before | ratio after |
| --- | ---: | ---: | ---: | ---: |
| `ffi.tlsshort` | `932.16` req/s | `1256.86` req/s | `0.81x` | `1.10x` |
| `ffi.tls` | `18655.46` req/s | `18276.36` req/s | `1.57x` | `1.53x` |

`tlsshort` gains 35% and turns the only losing shape in the matrix into a win.
Pooled `tls` is unchanged within run-to-run spread, as expected: it amortises
one handshake over many requests, so the sweep was never a large share of its
cost.

`tlsverify` and `tlsverifyshort` are new. The matrix had never exercised
`ssl_verify = true` — all four call sites in `benchmark/lua/bench.lua` hardcoded
`false` — so the verifying path was previously unmeasured. Verification costs
the FFI client about 4% on pooled TLS (`18276` to `17543`) and roughly 2% on the
short-lived shape, which is real chain-checking work rather than the pathological
sweep.

## Latency (fixed rate, corrected for coordinated omission)

Median of 3 repeats. **These numbers are less trustworthy than the throughput
figures above and should not be quoted for the short-lived shapes** — see the
caveat below.

| case | p50 | p99 | p99.9 |
| --- | ---: | ---: | ---: |
| `ffi.tls` | `1.650` ms | `4.130` ms | `4.880` ms |
| `resty.tls` | `1.260` ms | `2.700` ms | `3.270` ms |
| `ffi.tlsshort` | `3.500` ms | `5.810` ms | `7.710` ms |
| `resty.tlsshort` | `3.620` ms | `6.280` ms | `8.330` ms |
| `ffi.tlsverify` | `1.170` ms | `2.460` ms | `2.930` ms |
| `resty.tlsverify` | `2.330` ms | `5.460` ms | `6.420` ms |
| `ffi.tlsverifyshort` | `23.220` ms | `46.720` ms | `48.380` ms |
| `resty.tlsverifyshort` | `3.430` ms | `5.660` ms | `7.000` ms |

### Caveat: rate attainment, not latency

The latency phase drives each pair at a fixed rate — 60% of the slower side's
saturated throughput. Several windows failed to reach that rate by roughly 2%,
and wrk2's coordinated-omission correction converts a small rate shortfall into
a large apparent latency, so those rows measure rate attainment rather than
service time:

| case | repeat | achieved / target req/s | p50 | worker CPU |
| --- | ---: | ---: | ---: | ---: |
| `ffi.tlsshort` | 1 | `683.85` / 685 | `3.500` ms | `57.0%` |
| `ffi.tlsshort` | 2 | `672.02` / 685 | `24.400` ms | `55.8%` |
| `ffi.tlsshort` | 3 | `683.89` / 685 | `3.490` ms | `57.5%` |
| `ffi.tlsverifyshort` | 1 | `669.37` / 682 | `23.220` ms | `56.0%` |
| `ffi.tlsverifyshort` | 2 | `669.38` / 682 | `23.500` ms | `56.4%` |
| `ffi.tlsverifyshort` | 3 | `680.99` / 682 | `3.300` ms | `58.0%` |

Every window that hit its target rate produced a ~3.3-3.5 ms p50; every window
that missed produced ~23-24 ms. The worker had roughly 42% CPU headroom
throughout, so this is not a CPU limit.

This is not specific to the FFI client, though it hit it more often here.
`resty.tlsverify` missed the rate on repeats 2 and 3 (`6982` against a `7088`
target) and its p50 went from `1.270` ms to `2.330`/`2.410` ms; `ffi.tls`
repeats 1 and 2 missed (`7020` against `7127`) with the same effect. Where both
sides hit their target — `tlsverify` repeat 1, `tlsverifyshort` repeat 3 — the
FFI client is faster at every percentile.

The underlying cause is not yet understood. Candidates: connection-teardown
asymmetry over which side holds `TIME_WAIT`, ephemeral port pressure at ~683 new
connections per second, or a stall in the connect path. Until it is diagnosed,
no latency claim should be published for the short-lived TLS shapes.
