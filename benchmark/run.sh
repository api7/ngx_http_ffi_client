#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/benchmark/.run}"
TARGET_PREFIX="$RUN_DIR/target"
UPSTREAM_PREFIX="$RUN_DIR/upstream"
RESULTS_DIR="${BENCH_RESULTS_DIR:-$RUN_DIR/results}"
CASES_FILE="${BENCH_CASES_FILE:-$ROOT_DIR/benchmark/cases.txt}"

TARGET_PORT="${TARGET_PORT:-19840}"
UPSTREAM_PORT="${UPSTREAM_PORT:-19841}"
UPSTREAM_TLS_PORT="${UPSTREAM_TLS_PORT:-19842}"
UPSTREAM_TRAILER_PORT="${UPSTREAM_TRAILER_PORT:-19843}"
UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
TARGET_CPU="${TARGET_CPU:-0}"
RESPONSE_SIZE="${RESPONSE_SIZE:-1024}"
KEEPALIVE_POOL_SIZE="${KEEPALIVE_POOL_SIZE:-120}"
KEEPALIVE_IDLE_TIMEOUT="${KEEPALIVE_IDLE_TIMEOUT:-60000}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-60000}"
DNS_HOST="${DNS_HOST:-localhost}"
TLS_SERVER_NAME="${TLS_SERVER_NAME:-bench.local}"
CA_FILE="${CA_FILE:-$RUN_DIR/target/conf/ca.crt}"

WRK_THREADS="${WRK_THREADS:-2}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_WARMUP="${WRK_WARMUP:-10s}"
WRK_RATE="${WRK_RATE:-100000}"
CPU_SATURATION_THRESHOLD="${CPU_SATURATION_THRESHOLD:-95}"

BENCH_REPEATS="${BENCH_REPEATS:-5}"
BENCH_LATENCY="${BENCH_LATENCY:-1}"
BENCH_LATENCY_FRACTION="${BENCH_LATENCY_FRACTION:-0.6}"
# Tail percentiles are the noisiest thing here, so one window is not evidence.
BENCH_LATENCY_REPEATS="${BENCH_LATENCY_REPEATS:-3}"
BENCH_GC="${BENCH_GC:-1}"
BENCH_AUDIT="${BENCH_AUDIT:-1}"
BENCH_STRICT="${BENCH_STRICT:-0}"
DROPPED=()
BENCH_DRY_RUN="${BENCH_DRY_RUN:-0}"
BENCH_PARSER="${BENCH_PARSER:-${NGX_HTTP_FFI_CLIENT_USE_LLHTTP:-llhttp}}"

# The default set is the 2x2 that produces the headline ratio. BENCH_CASES=all
# runs every case in benchmark/cases.txt.
BENCH_CASES="${BENCH_CASES:-baseline ffi.oneshot resty.oneshot ffi.stateful resty.stateful}"

TEST_NGINX_BINARY="${TEST_NGINX_BINARY:-}"
BENCH_LUA_DIR="$ROOT_DIR/benchmark/lua"
TEST_NGINX_LUA_PACKAGE_PATH="${TEST_NGINX_LUA_PACKAGE_PATH:-$ROOT_DIR/lib/?.lua;$ROOT_DIR/lib/?/init.lua}"
LUA_PACKAGE_PATH="$TEST_NGINX_LUA_PACKAGE_PATH;$BENCH_LUA_DIR/?.lua"

WRK2_BIN="${WRK2_BIN:-${WRK_BIN:-wrk}}"
CURL_BIN="${CURL_BIN:-curl}"
TASKSET_BIN="${TASKSET_BIN:-taskset}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

online_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '1\n'
}

expand_cpu_list() {
    local spec="${1// /}"
    local part start end i
    local -a parts values

    [[ -n "$spec" ]] || die "CPU list must not be empty"

    IFS=',' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            values+=("$part")
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            (( start <= end )) || die "bad CPU range: $part"
            for ((i = start; i <= end; i++)); do
                values+=("$i")
            done
        else
            die "bad CPU list: $spec"
        fi
    done

    printf '%s\n' "${values[@]}" | sort -n -u
}

cpu_list_count() {
    expand_cpu_list "$1" | wc -l | tr -d ' '
}

cpu_lists_overlap() {
    local first="$1"
    local second="$2"

    comm -12 <(expand_cpu_list "$first") <(expand_cpu_list "$second") |
        grep -q .
}

NCPU="$(online_cpu_count)"
(( NCPU >= 2 )) || die "benchmark requires at least two CPU cores"

if (( NCPU == 2 )); then
    DEFAULT_NON_TARGET_CPUS="1"
else
    DEFAULT_NON_TARGET_CPUS="1-$((NCPU - 1))"
fi

UPSTREAM_CPUS="${UPSTREAM_CPUS:-$DEFAULT_NON_TARGET_CPUS}"
WRK_CPUS="${WRK_CPUS:-$UPSTREAM_CPUS}"
UPSTREAM_WORKERS="${UPSTREAM_WORKERS:-$(cpu_list_count "$UPSTREAM_CPUS")}"

[[ "$(cpu_list_count "$TARGET_CPU")" == "1" ]] ||
    die "TARGET_CPU must contain exactly one CPU core"

cpu_lists_overlap "$TARGET_CPU" "$UPSTREAM_CPUS" &&
    die "TARGET_CPU overlaps UPSTREAM_CPUS"

cpu_lists_overlap "$TARGET_CPU" "$WRK_CPUS" &&
    die "TARGET_CPU overlaps WRK_CPUS"

# The topology this benchmark assumes is a pinned target worker, an upstream
# that cannot be the bottleneck, and a load generator that competes with
# neither. Below eight cores that is not available, and the numbers describe the
# host rather than the client.
if (( NCPU < 8 )); then
    warn "only $NCPU cores online; the plan's topology wants 8+ (target on 1," \
         "upstream on 5, wrk2 on 2). Results here are regression smoke, not" \
         "headline numbers."
fi

default_resolver() {
    awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null ||
        printf '127.0.0.1\n'
}

RESOLVER="${BENCH_RESOLVER:-$(default_resolver)}"
[[ -n "$RESOLVER" ]] || RESOLVER="127.0.0.1"

# ===== case list =====

read_case_file() {
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CASES_FILE" | grep -v '^$'
}

resolve_cases() {
    local requested="$1"

    if [[ "$requested" == "all" ]]; then
        printf 'baseline\n'
        read_case_file
        return
    fi

    printf '%s\n' $requested
}

mapfile -t CASES < <(resolve_cases "$BENCH_CASES")
(( ${#CASES[@]} > 0 )) || die "BENCH_CASES resolved to nothing"

case_path() {
    local name="$1"

    if [[ "$name" == "baseline" ]]; then
        printf '/bench/baseline'
    else
        printf '/bench/%s' "$name"
    fi
}

# ===== template rendering =====

sed_escape() {
    printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

render_template() {
    local template="$1"
    local output="$2"

    sed \
        -e "s|{{LUA_PACKAGE_PATH}}|$(sed_escape "$LUA_PACKAGE_PATH")|g" \
        -e "s|{{TARGET_PORT}}|$(sed_escape "$TARGET_PORT")|g" \
        -e "s|{{UPSTREAM_HOST}}|$(sed_escape "$UPSTREAM_HOST")|g" \
        -e "s|{{UPSTREAM_PORT}}|$(sed_escape "$UPSTREAM_PORT")|g" \
        -e "s|{{UPSTREAM_TLS_PORT}}|$(sed_escape "$UPSTREAM_TLS_PORT")|g" \
        -e "s|{{UPSTREAM_TRAILER_PORT}}|$(sed_escape "$UPSTREAM_TRAILER_PORT")|g" \
        -e "s|{{UPSTREAM_WORKERS}}|$(sed_escape "$UPSTREAM_WORKERS")|g" \
        -e "s|{{RESPONSE_SIZE}}|$(sed_escape "$RESPONSE_SIZE")|g" \
        -e "s|{{KEEPALIVE_POOL_SIZE}}|$(sed_escape "$KEEPALIVE_POOL_SIZE")|g" \
        -e "s|{{KEEPALIVE_IDLE_TIMEOUT}}|$(sed_escape "$KEEPALIVE_IDLE_TIMEOUT")|g" \
        -e "s|{{CLIENT_TIMEOUT}}|$(sed_escape "$CLIENT_TIMEOUT")|g" \
        -e "s|{{DNS_HOST}}|$(sed_escape "$DNS_HOST")|g" \
        -e "s|{{TLS_SERVER_NAME}}|$(sed_escape "$TLS_SERVER_NAME")|g" \
        -e "s|{{CA_FILE}}|$(sed_escape "$CA_FILE")|g" \
        -e "s|{{RESOLVER}}|$(sed_escape "$RESOLVER")|g" \
        "$template" > "$output"
}

# One exact location per case, generated from cases.txt. Exact rather than one
# regex location on purpose: a regex match would land on the measured worker's
# hot path for every request of every case.
generate_locations() {
    local output="$1"
    local name

    : > "$output"
    while read -r name; do
        cat >> "$output" <<EOF
location = /bench/$name {
    content_by_lua_block { require("bench").run("$name") }
}

location = /echo/$name {
    content_by_lua_block { require("bench").echo("$name") }
}

EOF
    done < <(read_case_file)
}

generate_cert() {
    local dir="$1"

    "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$dir/tls.key" -out "$dir/tls.crt" \
        -subj "/CN=$TLS_SERVER_NAME" \
        -addext "subjectAltName=DNS:$TLS_SERVER_NAME,IP:127.0.0.1" \
        >/dev/null 2>&1 ||
        die "failed to generate a TLS certificate with $OPENSSL_BIN"
}

prepare_prefix() {
    local prefix="$1"

    rm -rf "$prefix"
    mkdir -p \
        "$prefix/conf" \
        "$prefix/logs" \
        "$prefix/client_body_temp" \
        "$prefix/proxy_temp" \
        "$prefix/fastcgi_temp" \
        "$prefix/uwsgi_temp" \
        "$prefix/scgi_temp"
}

prepare_configs() {
    prepare_prefix "$UPSTREAM_PREFIX"
    prepare_prefix "$TARGET_PREFIX"
    mkdir -p "$RESULTS_DIR"

    render_template "$ROOT_DIR/benchmark/conf/upstream.nginx.conf" \
        "$UPSTREAM_PREFIX/conf/nginx.conf"
    render_template "$ROOT_DIR/benchmark/conf/target.nginx.conf" \
        "$TARGET_PREFIX/conf/nginx.conf"

    generate_locations "$TARGET_PREFIX/conf/bench_locations.conf"
    # ssl_certificate resolves relative paths against the conf prefix
    generate_cert "$UPSTREAM_PREFIX/conf"

    # The cert is self-signed with CA:TRUE, so it is its own root: handing the
    # target a copy is all the verify-on cases need to trust the upstream.
    # lua_ssl_trusted_certificate is read at config load, so it must be in place
    # before nginx starts.
    cp "$UPSTREAM_PREFIX/conf/tls.crt" "$CA_FILE" ||
        die "failed to install the trusted CA at $CA_FILE"
}

print_config() {
    cat <<EOF
Benchmark configuration
ROOT_DIR=$ROOT_DIR
NCPU=$NCPU
TARGET_CPU=$TARGET_CPU
CA_FILE=$CA_FILE
UPSTREAM_CPUS=$UPSTREAM_CPUS
WRK_CPUS=$WRK_CPUS
TARGET_PORT=$TARGET_PORT
UPSTREAM_PORT=$UPSTREAM_PORT
UPSTREAM_TLS_PORT=$UPSTREAM_TLS_PORT
UPSTREAM_TRAILER_PORT=$UPSTREAM_TRAILER_PORT
UPSTREAM_WORKERS=$UPSTREAM_WORKERS
RESOLVER=$RESOLVER
DNS_HOST=$DNS_HOST
RESPONSE_SIZE=$RESPONSE_SIZE
KEEPALIVE_POOL_SIZE=$KEEPALIVE_POOL_SIZE
KEEPALIVE_IDLE_TIMEOUT=$KEEPALIVE_IDLE_TIMEOUT
WRK_THREADS=$WRK_THREADS
WRK_CONNECTIONS=$WRK_CONNECTIONS
WRK_WARMUP=$WRK_WARMUP
WRK_DURATION=$WRK_DURATION
WRK_RATE=$WRK_RATE
BENCH_REPEATS=$BENCH_REPEATS
BENCH_PARSER=$BENCH_PARSER
BENCH_CASES=${CASES[*]}
CPU_SATURATION_THRESHOLD=$CPU_SATURATION_THRESHOLD
RESULTS_DIR=$RESULTS_DIR
EOF
}

validate_runtime() {
    [[ -n "$TEST_NGINX_BINARY" ]] || die "TEST_NGINX_BINARY is required"
    [[ -x "$TEST_NGINX_BINARY" ]] ||
        die "TEST_NGINX_BINARY is not executable: $TEST_NGINX_BINARY"
    need_cmd "$WRK2_BIN"
    need_cmd "$CURL_BIN"
    need_cmd "$TASKSET_BIN"
    need_cmd "$OPENSSL_BIN"
}

# ===== process control =====

start_nginx() {
    local name="$1"
    local prefix="$2"
    local cpus="$3"

    printf 'Starting %s on CPUs %s\n' "$name" "$cpus"
    "$TASKSET_BIN" -c "$cpus" "$TEST_NGINX_BINARY" \
        -p "$prefix/" -c conf/nginx.conf
}

stop_nginx() {
    local prefix="$1"
    local pid_file="$prefix/logs/nginx.pid"

    if [[ -s "$pid_file" ]]; then
        "$TEST_NGINX_BINARY" -p "$prefix/" -c conf/nginx.conf -s stop \
            >/dev/null 2>&1 || true
    fi
}

cleanup() {
    stop_nginx "$TARGET_PREFIX"
    stop_nginx "$UPSTREAM_PREFIX"
}

wait_url() {
    local url="$1"
    local i

    for ((i = 0; i < 100; i++)); do
        if "$CURL_BIN" -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done

    die "timed out waiting for $url"
}

target_worker_pid() {
    local master_pid

    master_pid="$(cat "$TARGET_PREFIX/logs/nginx.pid")"
    ps -o pid= --ppid "$master_pid" | awk 'NR == 1 { print $1 }'
}

# ===== CPU sampling =====

read_proc_ticks() {
    awk '{ print $14 + $15 }' "/proc/$1/stat"
}

read_total_ticks() {
    awk '/^cpu / {
        total = 0
        for (i = 2; i <= NF; i++) {
            total += $i
        }
        print total
    }' /proc/stat
}

read_rss_kb() {
    awk '/^VmRSS:/ { print $2 }' "/proc/$1/status" 2>/dev/null || printf '0\n'
}

sample_cpu_once() {
    local pid="$1"
    local proc_before proc_after total_before total_after proc_delta total_delta

    proc_before="$(read_proc_ticks "$pid")"
    total_before="$(read_total_ticks)"
    sleep 1
    proc_after="$(read_proc_ticks "$pid")"
    total_after="$(read_total_ticks)"

    proc_delta=$((proc_after - proc_before))
    total_delta=$((total_after - total_before))

    awk -v proc_delta="$proc_delta" \
        -v total_delta="$total_delta" \
        -v ncpu="$NCPU" \
        'BEGIN {
            if (total_delta <= 0) {
                print "0.0"
            } else {
                printf "%.1f\n", (proc_delta / total_delta) * 100 * ncpu
            }
        }'
}

sample_cpu_loop() {
    local pid="$1"
    local output="$2"

    : > "$output"
    while kill -0 "$pid" >/dev/null 2>&1; do
        sample_cpu_once "$pid" >> "$output" || true
    done
}

cpu_stat() {
    awk -v want="$2" '
        NF {
            sum += $1
            if ($1 > max) { max = $1 }
            n += 1
        }
        END {
            if (n == 0) { print "0"; exit }
            if (want == "avg") { printf "%.1f\n", sum / n }
            else if (want == "max") { printf "%.1f\n", max }
            else { print n }
        }
    ' "$1"
}

# ===== wrk2 output parsing =====

extract_qps() {
    awk '/Requests\/sec:/ { qps = $2 } END { print (qps == "" ? "0" : qps) }' "$1"
}

extract_non2xx() {
    awk '/Non-2xx or 3xx responses:/ { n = $NF } END { print (n == "" ? "0" : n) }' "$1"
}

extract_socket_errors() {
    awk '
        /Socket errors:/ {
            total = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+,?$/) {
                    v = $i
                    sub(",", "", v)
                    total += v
                }
            }
            print total
            found = 1
        }
        END { if (!found) print "0" }
    ' "$1"
}

# wrk2 with -L -U prints two distributions: the recorded one, which corrects for
# coordinated omission by accounting for delayed request starts, and the
# uncorrected one. The corrected figures are the point of running wrk2 at a
# fixed rate at all, so they are the default; BENCH_LATENCY_MODE=uncorrected
# selects the other block. Percentile values come in whatever unit fits, so they
# are normalised to milliseconds before anything compares them.
extract_percentile() {
    local output="$1"
    local pct="$2"
    local mode="${BENCH_LATENCY_MODE:-corrected}"

    awk -v pct="$pct" -v mode="$mode" '
        function to_ms(v) {
            if (v ~ /us$/) { sub(/us$/, "", v); return v / 1000 }
            if (v ~ /ms$/) { sub(/ms$/, "", v); return v + 0 }
            if (v ~ /m$/)  { sub(/m$/, "", v);  return v * 60000 }
            if (v ~ /s$/)  { sub(/s$/, "", v);  return v * 1000 }
            return v + 0
        }
        /Latency Distribution/ {
            in_block = (($0 ~ /Uncorrected/) == (mode == "uncorrected"))
            next
        }
        /Detailed Percentile spectrum/ { in_block = 0 }
        in_block && $1 ~ /%$/ {
            p = $1
            sub(/%$/, "", p)
            if (p + 0 == pct + 0 && !seen) {
                printf "%.3f\n", to_ms($2)
                seen = 1
            }
        }
        END { if (!seen) print "" }
    ' "$output"
}

# ===== upstream reuse accounting =====

upstream_stats_reset() {
    "$CURL_BIN" -fsS "http://127.0.0.1:$UPSTREAM_PORT/stats/reset" \
        >/dev/null 2>&1 || true
}

upstream_stat() {
    "$CURL_BIN" -fsS "http://127.0.0.1:$UPSTREAM_PORT/stats" 2>/dev/null |
        awk -v key="$1" '$1 == key { print $2 }'
}

# ===== results =====

RUN_ID="${BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_CSV="$RESULTS_DIR/$RUN_ID.csv"

CSV_HEADER='run_id,phase,repeat,case,qps,rate,non2xx,socket_errors,p50_ms,p99_ms,p999_ms,cpu_avg,cpu_max,cpu_samples,saturated,rss_kb,upstream_connections,upstream_requests,requests_per_connection,response_size,connections,threads,duration,parser'

init_results() {
    mkdir -p "$RESULTS_DIR"
    printf '%s\n' "$CSV_HEADER" > "$RESULTS_CSV"
    printf 'Writing rows to %s\n' "$RESULTS_CSV"
}

# ===== one measured run =====

run_wrk_case() {
    local phase="$1"
    local repeat="$2"
    local name="$3"
    local duration="$4"
    local rate="$5"

    local path stem samples output worker_pid sampler_pid
    local qps non2xx sockerr cpu_avg cpu_max cpu_n saturated rss
    local up_conn up_req rpc p50 p99 p999

    path="$(case_path "$name")"
    stem="$(printf '%s' "${phase}_${repeat}_${name}" | tr -c 'A-Za-z0-9_-' '_')"
    samples="$RUN_DIR/$stem.cpu"
    output="$RUN_DIR/$stem.wrk"

    worker_pid="$(target_worker_pid)"
    [[ -n "$worker_pid" ]] || die "failed to find target worker pid"

    printf '\n== %s repeat %s: %s (%s, rate %s) ==\n' \
        "$phase" "$repeat" "$name" "$duration" "$rate"

    # warmup, discarded: fills the keepalive pools and lets the JIT settle so
    # the measured window is not paying for either
    if [[ "$WRK_WARMUP" != "0" && "$WRK_WARMUP" != "0s" ]]; then
        "$TASKSET_BIN" -c "$WRK_CPUS" "$WRK2_BIN" \
            -t "$WRK_THREADS" -c "$WRK_CONNECTIONS" -d "$WRK_WARMUP" \
            -R "$rate" \
            -s "$ROOT_DIR/benchmark/wrk/headers.lua" \
            "http://127.0.0.1:$TARGET_PORT$path" >/dev/null 2>&1 || true
    fi

    upstream_stats_reset

    sample_cpu_loop "$worker_pid" "$samples" &
    sampler_pid="$!"

    "$TASKSET_BIN" -c "$WRK_CPUS" "$WRK2_BIN" \
        -t "$WRK_THREADS" -c "$WRK_CONNECTIONS" -d "$duration" \
        -R "$rate" -L -U \
        -s "$ROOT_DIR/benchmark/wrk/headers.lua" \
        "http://127.0.0.1:$TARGET_PORT$path" | tee "$output"

    rss="$(read_rss_kb "$worker_pid")"

    kill "$sampler_pid" >/dev/null 2>&1 || true
    wait "$sampler_pid" >/dev/null 2>&1 || true

    qps="$(extract_qps "$output")"
    non2xx="$(extract_non2xx "$output")"
    sockerr="$(extract_socket_errors "$output")"
    cpu_avg="$(cpu_stat "$samples" avg)"
    cpu_max="$(cpu_stat "$samples" max)"
    cpu_n="$(cpu_stat "$samples" n)"
    p50="$(extract_percentile "$output" 50)"
    p99="$(extract_percentile "$output" 99)"
    p999="$(extract_percentile "$output" 99.9)"

    up_conn="$(upstream_stat connections)"
    up_req="$(upstream_stat requests)"
    up_conn="${up_conn:-0}"
    up_req="${up_req:-0}"
    # The counters are reset after the warmup, so they describe the steady
    # state: connections opened during the measured window. Zero new
    # connections against a non-zero request count is perfect pool reuse, which
    # is the result the keepalive cases want; a ratio near 1 means the pool is
    # not reusing anything and the case is measuring connection setup.
    rpc="$(awk -v c="$up_conn" -v r="$up_req" 'BEGIN {
        if (c + 0 > 0) printf "%.1f", r / c
        else if (r + 0 > 0) print "inf"
        else print ""
    }')"

    saturated=no
    if awk -v t="$CPU_SATURATION_THRESHOLD" -v a="$cpu_avg" \
        'BEGIN { exit !(a + 0 >= t + 0) }'; then
        saturated=yes
    fi

    printf 'qps=%s non2xx=%s socket_errors=%s cpu_avg=%s%% rss=%sKB\n' \
        "$qps" "$non2xx" "$sockerr" "$cpu_avg" "$rss"
    printf 'latency p50=%sms p99=%sms p99.9=%sms\n' "$p50" "$p99" "$p999"

    if [[ "$name" != "baseline" ]]; then
        printf 'upstream: %s new connections, %s requests' "$up_conn" "$up_req"
        if [[ -n "$rpc" ]]; then
            printf ', %s requests/connection\n' "$rpc"
        else
            printf '\n'
        fi

        # a keepalive case that opens roughly one connection per request is not
        # exercising the pool, whatever else the row says
        case "$name" in
            *.short|*.tlsshort) ;;
            *)
                if [[ "$rpc" != "inf" && -n "$rpc" ]] &&
                    awk -v v="$rpc" 'BEGIN { exit !(v + 0 < 2) }'
                then
                    warn "$name reused almost nothing (${rpc} requests per" \
                         "connection); this is not a keepalive result"
                fi
                ;;
        esac
    fi

    if [[ "$non2xx" != "0" ]]; then
        warn "$name reported $non2xx non-2xx responses; this row is invalid"
    fi

    if [[ "$phase" == "throughput" && "$saturated" == "no" ]]; then
        warn "$name average target worker CPU ${cpu_avg}% is below" \
             "${CPU_SATURATION_THRESHOLD}%; this row is not a saturated result"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_ID" "$phase" "$repeat" "$name" "$qps" "$rate" "$non2xx" \
        "$sockerr" "$p50" "$p99" "$p999" "$cpu_avg" "$cpu_max" "$cpu_n" \
        "$saturated" "$rss" "$up_conn" "$up_req" "$rpc" "$RESPONSE_SIZE" \
        "$WRK_CONNECTIONS" "$WRK_THREADS" "$duration" "$BENCH_PARSER" \
        >> "$RESULTS_CSV"
}

# ===== checks before any load =====

smoke_check() {
    printf 'Running smoke checks\n'

    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/ready" >/dev/null ||
        die "target /ready failed"

    # the case table the worker actually has, against the file the runner drives
    local worker_cases file_cases
    worker_cases="$("$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/cases" |
        sort)"
    file_cases="$(read_case_file | sort)"

    if [[ "$worker_cases" != "$file_cases" ]]; then
        printf 'case table drift between benchmark/cases.txt and bench.lua:\n' >&2
        diff <(printf '%s\n' "$file_cases") <(printf '%s\n' "$worker_cases") >&2 ||
            true
        die "case list mismatch"
    fi

    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/bench/baseline" >/dev/null ||
        die "baseline failed"

    # A case that cannot complete once is not going to produce a meaningful
    # number under load. Not every case works on every build, though: the
    # hand-written parser has no chunked framing, so its chunked and trailer
    # cases fail here by design. Those are dropped and named in the summary
    # rather than aborting the whole matrix. BENCH_STRICT=1 aborts instead.
    local name kept=()
    for name in "${CASES[@]}"; do
        if [[ "$name" == "baseline" ]]; then
            kept+=("$name")
            continue
        fi

        if ! "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/audit/$name" \
            > "$RUN_DIR/audit-$name.txt" 2>&1
        then
            if [[ "$BENCH_STRICT" == "1" ]]; then
                printf 'audit output: %s\n' \
                    "$(cat "$RUN_DIR/audit-$name.txt")" >&2
                die "case $name failed its smoke check"
            fi

            warn "case $name failed its smoke check and is excluded from this" \
                 "run; it is not supported by this build or configuration"
            DROPPED+=("$name")
            continue
        fi

        printf '  %s\n' "$(cat "$RUN_DIR/audit-$name.txt")"
        kept+=("$name")
    done

    CASES=("${kept[@]}")

    local remaining=0
    for name in "${CASES[@]}"; do
        [[ "$name" == "baseline" ]] || remaining=$((remaining + 1))
    done

    (( remaining > 0 )) || die "every client case failed its smoke check"

    if (( ${#DROPPED[@]} )); then
        printf 'Smoke checks passed for %d cases, %d excluded\n' \
            "$remaining" "${#DROPPED[@]}"
    else
        printf 'Smoke checks passed\n'
    fi
}

# Headers each client writes for itself rather than on the caller's behalf. A
# difference here is the client's own contract and is reported, not failed: the
# FFI client always emits Connection and Content-Length, lua-resty-http omits
# both on a bodyless GET.
GENERATED_HEADERS='^(host|connection|content-length|user-agent|transfer-encoding|accept|accept-encoding):'

request_line() {
    head -n 1 "$1"
}

caller_headers() {
    tail -n +2 "$1" | grep -Ev -i "$GENERATED_HEADERS" | grep -v '^$' | sort
}

generated_headers() {
    tail -n +2 "$1" | grep -E -i "$GENERATED_HEADERS" | sort
}

# A1: prove the two columns of a pair send the same request. The upstream echoes
# the raw header block it received. The request line and every caller-supplied
# header must match, or the pair is not measuring the same request; headers the
# clients generate themselves are reported separately.
fairness_audit() {
    printf '\n== Fairness audit ==\n'

    local shapes=() name shape seen ffi_out resty_out failures=0

    for name in "${CASES[@]}"; do
        [[ "$name" == "baseline" ]] && continue
        shape="${name#*.}"

        seen=0
        local s
        for s in "${shapes[@]:-}"; do
            [[ "$s" == "$shape" ]] && seen=1
        done
        (( seen )) || shapes+=("$shape")
    done

    for shape in "${shapes[@]:-}"; do
        ffi_out="$RUN_DIR/echo-ffi.$shape.txt"
        resty_out="$RUN_DIR/echo-resty.$shape.txt"

        if ! "$CURL_BIN" -fsS \
            "http://127.0.0.1:$TARGET_PORT/echo/ffi.$shape" > "$ffi_out" 2>&1
        then
            warn "echo for ffi.$shape failed: $(cat "$ffi_out")"
            failures=$((failures + 1))
            continue
        fi

        if ! "$CURL_BIN" -fsS \
            "http://127.0.0.1:$TARGET_PORT/echo/resty.$shape" > "$resty_out" 2>&1
        then
            warn "echo for resty.$shape failed: $(cat "$resty_out")"
            failures=$((failures + 1))
            continue
        fi

        local ok=1

        if [[ "$(request_line "$ffi_out")" != "$(request_line "$resty_out")" ]]
        then
            printf '  %-10s REQUEST LINE DIFFERS:\n' "$shape"
            printf '      ffi:   %s\n' "$(request_line "$ffi_out")"
            printf '      resty: %s\n' "$(request_line "$resty_out")"
            ok=0
        fi

        # header order is not part of the contract, so compare as sets
        if ! diff <(caller_headers "$ffi_out") <(caller_headers "$resty_out") \
            > "$RUN_DIR/echo-$shape.diff"
        then
            printf '  %-10s CALLER HEADERS DIFFER:\n' "$shape"
            sed -e 's/^/      /' "$RUN_DIR/echo-$shape.diff"
            ok=0
        fi

        if (( ok )); then
            printf '  %-10s same request line, same caller headers\n' "$shape"
        else
            failures=$((failures + 1))
        fi

        if ! diff <(generated_headers "$ffi_out") \
            <(generated_headers "$resty_out") > "$RUN_DIR/echo-$shape.gen.diff"
        then
            printf '  %-10s   client-generated headers differ (reported, not a failure):\n' \
                ""
            sed -e 's/^/        /' "$RUN_DIR/echo-$shape.gen.diff"
        fi
    done

    if (( failures )); then
        warn "$failures shape(s) failed the fairness audit; the affected pairs" \
             "are not comparing like for like"
    fi
}

# A5: per-request Lua heap delta. The library's claim is that response handling
# stays in C, and the header arrays and the case-insensitive metatable are where
# that could regress, so this is reported rather than left as a diagnostic.
gc_report() {
    printf '\n== Per-request Lua heap delta (KB/request) ==\n'

    local name delta
    for name in "${CASES[@]}"; do
        [[ "$name" == "baseline" ]] && continue

        delta="$("$CURL_BIN" -fsS \
            "http://127.0.0.1:$TARGET_PORT/gcdelta/$name" 2>/dev/null |
            tail -n 1)"
        printf '  %-18s %s\n' "$name" "${delta:-unavailable}"
    done
}

# ===== phases =====

median_qps() {
    local name="$1"

    awk -F, -v want="$name" '
        NR > 1 && $2 == "throughput" && $4 == want && $15 == "yes" && $7 == 0 {
            v[n++] = $5 + 0
        }
        END {
            if (n == 0) { print ""; exit }
            for (i = 0; i < n; i++) {
                for (j = i + 1; j < n; j++) {
                    if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
                }
            }
            if (n % 2) { printf "%.2f\n", v[(n - 1) / 2] }
            else { printf "%.2f\n", (v[n / 2 - 1] + v[n / 2]) / 2 }
        }
    ' "$RESULTS_CSV"
}

throughput_phase() {
    local repeat name

    for ((repeat = 1; repeat <= BENCH_REPEATS; repeat++)); do
        # cases rotate inside each repeat rather than running back to back, so
        # drift and background load land on every case equally
        for name in "${CASES[@]}"; do
            run_wrk_case throughput "$repeat" "$name" "$WRK_DURATION" "$WRK_RATE"
        done
    done
}

# A5: latency measured at saturation is queue depth. This pass re-runs each pair
# at a fixed fraction of the slower side's saturated throughput, which is the
# only rate at which the two are answering the same question.
latency_phase() {
    printf '\n== Latency phase ==\n'

    local shapes=() name shape seen ffi_med resty_med rate

    for name in "${CASES[@]}"; do
        [[ "$name" == "baseline" ]] && continue
        shape="${name#*.}"

        seen=0
        local s
        for s in "${shapes[@]:-}"; do
            [[ "$s" == "$shape" ]] && seen=1
        done
        (( seen )) || shapes+=("$shape")
    done

    for shape in "${shapes[@]:-}"; do
        ffi_med="$(median_qps "ffi.$shape")"
        resty_med="$(median_qps "resty.$shape")"

        if [[ -z "$ffi_med" || -z "$resty_med" ]]; then
            warn "no valid saturated throughput for both sides of $shape;" \
                 "skipping its latency pass"
            continue
        fi

        rate="$(awk -v a="$ffi_med" -v b="$resty_med" \
            -v f="$BENCH_LATENCY_FRACTION" \
            'BEGIN { m = (a < b ? a : b); printf "%d", m * f }')"

        (( rate > 0 )) || continue

        printf 'shape %s: fixed rate %s req/s (%.0f%% of the slower path)\n' \
            "$shape" "$rate" \
            "$(awk -v f="$BENCH_LATENCY_FRACTION" 'BEGIN { print f * 100 }')"

        local lrepeat
        for ((lrepeat = 1; lrepeat <= BENCH_LATENCY_REPEATS; lrepeat++)); do
            run_wrk_case latency "$lrepeat" "ffi.$shape" "$WRK_DURATION" "$rate"
            run_wrk_case latency "$lrepeat" "resty.$shape" "$WRK_DURATION" "$rate"
        done
    done
}

summarize() {
    printf '\n== Summary (median of %s repeats, saturated rows only) ==\n' \
        "$BENCH_REPEATS"

    "$ROOT_DIR/benchmark/fold.sh" "$RESULTS_CSV" || true

    if (( ${#DROPPED[@]} )); then
        printf '### Cases excluded before the run\n\n'
        printf 'These failed their smoke check on this build and were not'
        printf ' measured:\n\n'
        local name
        for name in "${DROPPED[@]}"; do
            printf -- '- `%s`\n' "$name"
        done
        printf '\n'
    fi

    printf 'Raw rows: %s\n' "$RESULTS_CSV"
}

# ===== main =====

prepare_configs
print_config

if [[ "$BENCH_DRY_RUN" == "1" ]]; then
    printf '\nBENCH_DRY_RUN=1, not starting OpenResty or wrk2\n'
    printf 'rendered: %s\n' "$TARGET_PREFIX/conf/nginx.conf"
    printf 'rendered: %s\n' "$UPSTREAM_PREFIX/conf/nginx.conf"
    printf 'rendered: %s (%s locations)\n' \
        "$TARGET_PREFIX/conf/bench_locations.conf" \
        "$(grep -c '^location' "$TARGET_PREFIX/conf/bench_locations.conf")"
    exit 0
fi

validate_runtime
trap cleanup EXIT

start_nginx "upstream" "$UPSTREAM_PREFIX" "$UPSTREAM_CPUS"
wait_url "http://127.0.0.1:$UPSTREAM_PORT/ready"

start_nginx "target" "$TARGET_PREFIX" "$TARGET_CPU"
wait_url "http://127.0.0.1:$TARGET_PORT/ready"

smoke_check

init_results

if [[ "$BENCH_AUDIT" == "1" ]]; then
    fairness_audit
fi

throughput_phase

if [[ "$BENCH_LATENCY" == "1" ]]; then
    latency_phase
fi

if [[ "$BENCH_GC" == "1" ]]; then
    gc_report
fi

summarize
