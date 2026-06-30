#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/benchmark/.run}"
TARGET_PREFIX="$RUN_DIR/target"
UPSTREAM_PREFIX="$RUN_DIR/upstream"

TARGET_PORT="${TARGET_PORT:-19840}"
UPSTREAM_PORT="${UPSTREAM_PORT:-19841}"
TARGET_CPU="${TARGET_CPU:-0}"
RESPONSE_SIZE="${RESPONSE_SIZE:-1024}"
KEEPALIVE_POOL_SIZE="${KEEPALIVE_POOL_SIZE:-256}"
KEEPALIVE_IDLE_TIMEOUT="${KEEPALIVE_IDLE_TIMEOUT:-60000}"
WRK_THREADS="${WRK_THREADS:-2}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-200}"
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_RATE="${WRK_RATE:-100000}"
CPU_SATURATION_THRESHOLD="${CPU_SATURATION_THRESHOLD:-95}"
BENCH_DRY_RUN="${BENCH_DRY_RUN:-0}"

TEST_NGINX_BINARY="${TEST_NGINX_BINARY:-}"
TEST_NGINX_LUA_PACKAGE_PATH="${TEST_NGINX_LUA_PACKAGE_PATH:-$ROOT_DIR/lib/?.lua;$ROOT_DIR/lib/?/init.lua}"

WRK2_BIN="${WRK2_BIN:-${WRK_BIN:-wrk}}"
CURL_BIN="${CURL_BIN:-curl}"
TASKSET_BIN="${TASKSET_BIN:-taskset}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
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

sed_escape() {
    printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

render_template() {
    local template="$1"
    local output="$2"

    sed \
        -e "s|{{LUA_PACKAGE_PATH}}|$(sed_escape "$TEST_NGINX_LUA_PACKAGE_PATH")|g" \
        -e "s|{{TARGET_PORT}}|$(sed_escape "$TARGET_PORT")|g" \
        -e "s|{{UPSTREAM_PORT}}|$(sed_escape "$UPSTREAM_PORT")|g" \
        -e "s|{{UPSTREAM_WORKERS}}|$(sed_escape "$UPSTREAM_WORKERS")|g" \
        -e "s|{{RESPONSE_SIZE}}|$(sed_escape "$RESPONSE_SIZE")|g" \
        -e "s|{{KEEPALIVE_POOL_SIZE}}|$(sed_escape "$KEEPALIVE_POOL_SIZE")|g" \
        -e "s|{{KEEPALIVE_IDLE_TIMEOUT}}|$(sed_escape "$KEEPALIVE_IDLE_TIMEOUT")|g" \
        "$template" > "$output"
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

    render_template "$ROOT_DIR/benchmark/conf/upstream.nginx.conf" \
        "$UPSTREAM_PREFIX/conf/nginx.conf"
    render_template "$ROOT_DIR/benchmark/conf/target.nginx.conf" \
        "$TARGET_PREFIX/conf/nginx.conf"
}

print_config() {
    cat <<EOF
Benchmark configuration
ROOT_DIR=$ROOT_DIR
TARGET_CPU=$TARGET_CPU
UPSTREAM_CPUS=$UPSTREAM_CPUS
WRK_CPUS=$WRK_CPUS
TARGET_PORT=$TARGET_PORT
UPSTREAM_PORT=$UPSTREAM_PORT
UPSTREAM_WORKERS=$UPSTREAM_WORKERS
RESPONSE_SIZE=$RESPONSE_SIZE
KEEPALIVE_POOL_SIZE=$KEEPALIVE_POOL_SIZE
KEEPALIVE_IDLE_TIMEOUT=$KEEPALIVE_IDLE_TIMEOUT
WRK_THREADS=$WRK_THREADS
WRK_CONNECTIONS=$WRK_CONNECTIONS
WRK_DURATION=$WRK_DURATION
WRK_RATE=$WRK_RATE
CPU_SATURATION_THRESHOLD=$CPU_SATURATION_THRESHOLD
EOF
}

validate_runtime() {
    [[ -n "$TEST_NGINX_BINARY" ]] || die "TEST_NGINX_BINARY is required"
    [[ -x "$TEST_NGINX_BINARY" ]] ||
        die "TEST_NGINX_BINARY is not executable: $TEST_NGINX_BINARY"
    need_cmd "$WRK2_BIN"
    need_cmd "$CURL_BIN"
    need_cmd "$TASKSET_BIN"
}

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

smoke_check() {
    printf 'Running smoke checks\n'
    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/ready" >/dev/null
    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/smoke/ffi-short" >/dev/null
    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/smoke/resty-http-short" >/dev/null
    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/bench/ffi" >/dev/null
    "$CURL_BIN" -fsS "http://127.0.0.1:$TARGET_PORT/bench/resty-http" >/dev/null
    printf 'Smoke checks passed\n'
}

target_worker_pid() {
    local master_pid

    master_pid="$(cat "$TARGET_PREFIX/logs/nginx.pid")"
    ps -o pid= --ppid "$master_pid" | awk 'NR == 1 { print $1 }'
}

read_proc_ticks() {
    local pid="$1"

    awk '{ print $14 + $15 }' "/proc/$pid/stat"
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

summarize_cpu() {
    local samples="$1"

    awk '
        NF {
            sum += $1
            if ($1 > max) {
                max = $1
            }
            n += 1
        }
        END {
            if (n == 0) {
                printf "avg=0.0 max=0.0 samples=0"
            } else {
                printf "avg=%.1f max=%.1f samples=%d", sum / n, max, n
            }
        }
    ' "$samples"
}

cpu_saturated() {
    local samples="$1"

    awk -v threshold="$CPU_SATURATION_THRESHOLD" '
        NF {
            sum += $1
            n += 1
        }
        END {
            if (n == 0) {
                exit 1
            }
            exit !((sum / n) >= threshold)
        }
    ' "$samples"
}

run_wrk_case() {
    local label="$1"
    local path="$2"
    local worker_pid samples sampler_pid

    worker_pid="$(target_worker_pid)"
    [[ -n "$worker_pid" ]] || die "failed to find target worker pid"

    samples="$RUN_DIR/${label// /_}.cpu"

    printf '\n== %s ==\n' "$label"
    sample_cpu_loop "$worker_pid" "$samples" &
    sampler_pid="$!"

    "$TASKSET_BIN" -c "$WRK_CPUS" "$WRK2_BIN" \
        -t "$WRK_THREADS" \
        -c "$WRK_CONNECTIONS" \
        -d "$WRK_DURATION" \
        -R "$WRK_RATE" \
        -L \
        -U \
        -s "$ROOT_DIR/benchmark/wrk/headers.lua" \
        "http://127.0.0.1:$TARGET_PORT$path"

    kill "$sampler_pid" >/dev/null 2>&1 || true
    wait "$sampler_pid" >/dev/null 2>&1 || true

    printf 'target worker CPU: %s\n' "$(summarize_cpu "$samples")"
    if cpu_saturated "$samples"; then
        printf 'saturation: valid (average CPU >= %s%%)\n' \
            "$CPU_SATURATION_THRESHOLD"
    else
        printf 'saturation: suspicious (average CPU < %s%%; increase wrk load or check upstream capacity)\n' \
            "$CPU_SATURATION_THRESHOLD"
    fi
}

prepare_configs
print_config

if [[ "$BENCH_DRY_RUN" == "1" ]]; then
    printf 'BENCH_DRY_RUN=1, not starting OpenResty or wrk2\n'
    exit 0
fi

validate_runtime
trap cleanup EXIT

start_nginx "upstream" "$UPSTREAM_PREFIX" "$UPSTREAM_CPUS"
wait_url "http://127.0.0.1:$UPSTREAM_PORT/ready"

start_nginx "target" "$TARGET_PREFIX" "$TARGET_CPU"
wait_url "http://127.0.0.1:$TARGET_PORT/ready"

smoke_check

run_wrk_case "C FFI keepalive" "/bench/ffi"
run_wrk_case "resty.http keepalive" "/bench/resty-http"
