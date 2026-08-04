#!/usr/bin/env bash
#
# Fold raw benchmark rows into the markdown tables the READMEs carry.
#
#   benchmark/fold.sh benchmark/.run/results/<run-id>.csv
#
# Reads the CSV that run.sh emits, one row per wrk2 run, and prints the summary
# tables. Rows that failed the saturation gate or reported non-2xx responses are
# excluded from every median and counted separately, because a run where the
# target worker was not the bottleneck is not measuring the client.

set -euo pipefail

CSV="${1:-}"

if [[ -z "$CSV" ]]; then
    latest="$(ls -1t "$(dirname "${BASH_SOURCE[0]}")/.run/results"/*.csv \
        2>/dev/null | head -n 1 || true)"
    CSV="$latest"
fi

[[ -n "$CSV" && -f "$CSV" ]] || {
    printf 'usage: %s <results.csv>\n' "${BASH_SOURCE[0]}" >&2
    exit 1
}

awk -F, '
function median(arr, n,   i, j, t) {
    if (n == 0) return ""
    for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
            if (arr[j] < arr[i]) { t = arr[i]; arr[i] = arr[j]; arr[j] = t }
    if (n % 2) return arr[(n - 1) / 2]
    return (arr[n / 2 - 1] + arr[n / 2]) / 2
}

function collect(key, value,   n) {
    n = count[key]++
    vals[key SUBSEP n] = value
}

function med_of(key,   i, n, a) {
    n = count[key]
    if (n == 0) return ""
    for (i = 0; i < n; i++) a[i] = vals[key SUBSEP i]
    return median(a, n)
}

function min_of(key,   i, n, m) {
    n = count[key]
    if (n == 0) return ""
    m = vals[key SUBSEP 0]
    for (i = 1; i < n; i++) if (vals[key SUBSEP i] < m) m = vals[key SUBSEP i]
    return m
}

function max_of(key,   i, n, m) {
    n = count[key]
    if (n == 0) return ""
    m = vals[key SUBSEP 0]
    for (i = 1; i < n; i++) if (vals[key SUBSEP i] > m) m = vals[key SUBSEP i]
    return m
}

NR == 1 { next }

{
    phase = $2; name = $4; qps = $5 + 0; non2xx = $7 + 0
    cpu = $12 + 0; sat = $15; rss = $16 + 0; rpc = $19
    p50 = $9; p99 = $10; p999 = $11; rate = $6
    parser = $24; conns = $21; rsize = $20; dur = $23

    meta_parser = parser; meta_conns = conns; meta_rsize = rsize; meta_dur = dur

    if (phase == "throughput") {
        seen_tp[name] = 1
        total[name]++

        if (sat == "yes" && non2xx == 0) {
            collect("qps:" name, qps)
            collect("cpu:" name, cpu)
            collect("rss:" name, rss)
            # "inf" is not a number but it is the best possible reuse result:
            # no new connections at all during the measured window
            if (rpc == "inf") reuse_inf[name]++
            else if (rpc != "") collect("rpc:" name, rpc + 0)
        } else {
            discarded[name]++
        }
    }

    if (phase == "latency") {
        seen_lat[name] = 1
        lat_rate[name] = rate
        if (non2xx == 0) {
            if (p50 != "") collect("p50:" name, p50 + 0)
            if (p99 != "") collect("p99:" name, p99 + 0)
            if (p999 != "") collect("p999:" name, p999 + 0)
        }
    }
}

END {
    base = med_of("qps:baseline")

    printf "\n### Run parameters\n\n"
    printf "parser `%s`, response size `%s` bytes, wrk2 connections `%s`, ",
        meta_parser, meta_rsize, meta_conns
    printf "duration `%s` per repeat\n", meta_dur

    # --- headline: one row per shape ---
    printf "\n### Headline (median QPS per shape)\n\n"
    printf "| shape | C FFI | `resty.http` | C FFI / `resty.http` |"
    if (base != "") printf " outbound cost ratio |"
    printf "\n| --- | ---: | ---: | ---: |"
    if (base != "") printf " ---: |"
    printf "\n"

    for (name in seen_tp) {
        if (name == "baseline") continue
        # not split(name, parts, ".") -- awk reads the separator as a regex, so
        # "." matches every character and every field comes back empty
        if (substr(name, 1, 4) != "ffi.") continue
        shape = substr(name, 5)

        f = med_of("qps:ffi." shape)
        r = med_of("qps:resty." shape)
        if (f == "" || r == "") continue

        printf "| `%s` | `%.2f` | `%.2f` | `%.2fx` |", shape, f, r, f / r

        if (base != "" && f > 0 && r > 0) {
            bus = 1000000 / base
            fus = 1000000 / f - bus
            rus = 1000000 / r - bus
            if (fus > 0 && rus > 0) printf " `%.2fx` |", rus / fus
            else printf " n/a |"
        } else if (base != "") {
            printf " n/a |"
        }
        printf "\n"
    }

    if (base != "") {
        printf "\nBaseline (no upstream call): `%.2f` QPS, `%.3f` us/request.\n",
            base, 1000000 / base
        printf "The outbound cost ratio subtracts that baseline from both ",
            ""
        printf "client paths and compares what is left.\n"
    }

    # --- detail ---
    printf "\n### Detail (throughput phase)\n\n"
    printf "| case | median QPS | min | max | repeats used | discarded |"
    printf " worker CPU avg | worker RSS | requests/connection |\n"
    printf "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"

    n = 0
    for (name in seen_tp) ordered[n++] = name
    for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
            if (ordered[j] < ordered[i]) { t = ordered[i]; ordered[i] = ordered[j]; ordered[j] = t }

    for (i = 0; i < n; i++) {
        name = ordered[i]
        m = med_of("qps:" name)
        used = count["qps:" name]
        drop = discarded[name] + 0
        rssv = med_of("rss:" name)
        rpcv = med_of("rpc:" name)

        printf "| `%s` |", name
        if (m == "") printf " n/a | n/a | n/a |"
        else printf " `%.2f` | `%.2f` | `%.2f` |", m, min_of("qps:" name), max_of("qps:" name)
        printf " %d | %d |", used, drop
        if (used > 0) printf " `%.1f%%` | `%d` KB |", med_of("cpu:" name), rssv
        else printf " n/a | n/a |"
        if (rpcv != "") printf " `%.1f` |", rpcv
        else if (reuse_inf[name] > 0) printf " no new connections |"
        else printf " n/a |"
        printf "\n"
    }

    # --- latency ---
    haslat = 0
    for (name in seen_lat) haslat = 1

    if (haslat) {
        printf "\n### Latency (fixed rate, corrected for coordinated omission)\n\n"
        printf "| case | rate | p50 | p99 | p99.9 |\n"
        printf "| --- | ---: | ---: | ---: | ---: |\n"

        n = 0
        delete ordered
        for (name in seen_lat) ordered[n++] = name
        for (i = 0; i < n; i++)
            for (j = i + 1; j < n; j++)
                if (ordered[j] < ordered[i]) { t = ordered[i]; ordered[i] = ordered[j]; ordered[j] = t }

        for (i = 0; i < n; i++) {
            name = ordered[i]
            printf "| `%s` | `%s` req/s |", name, lat_rate[name]
            v = med_of("p50:" name);  printf (v == "" ? " n/a |" : " `" sprintf("%.3f", v) "` ms |")
            v = med_of("p99:" name);  printf (v == "" ? " n/a |" : " `" sprintf("%.3f", v) "` ms |")
            v = med_of("p999:" name); printf (v == "" ? " n/a |" : " `" sprintf("%.3f", v) "` ms |")
            printf "\n"
        }
    }

    # --- what got thrown away ---
    anydrop = 0
    for (name in discarded) if (discarded[name] > 0) anydrop = 1

    if (anydrop) {
        printf "\n### Discarded rows\n\n"
        printf "Rows failing the saturation gate or reporting non-2xx responses,"
        printf " excluded from every median above:\n\n"
        for (i = 0; i < n; i++) { }
        for (name in discarded)
            if (discarded[name] > 0)
                printf "- `%s`: %d of %d\n", name, discarded[name], total[name]
    }
    printf "\n"
}
' "$CSV"
