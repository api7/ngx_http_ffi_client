#!/usr/bin/env bash
set -euo pipefail

backend="${1:-c}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

openresty_version="${OPENRESTY_VERSION:-1.31.1.1}"
pcre2_version="${PCRE2_VERSION:-10.45}"
workdir="${NGX_HTTP_FFI_CLIENT_BUILD_DIR:-/tmp/ngx_http_ffi_client_build}"
hyper_keepalive_bench="${NGX_HTTP_FFI_CLIENT_HYPER_KEEPALIVE_BENCH:-0}"
hyper_borrow_response_bench="${NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH:-0}"
hyper_session_bench="${NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH:-0}"

case "$backend" in
  c|hyper) ;;
  *)
    echo "usage: $0 [c|hyper]" >&2
    exit 2
    ;;
esac

case "$hyper_keepalive_bench" in
  0|1) ;;
  *)
    echo "NGX_HTTP_FFI_CLIENT_HYPER_KEEPALIVE_BENCH must be 0 or 1" >&2
    exit 2
    ;;
esac

case "$hyper_borrow_response_bench" in
  0|1) ;;
  *)
    echo "NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH must be 0 or 1" >&2
    exit 2
    ;;
esac

case "$hyper_session_bench" in
  0|1) ;;
  *)
    echo "NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH must be 0 or 1" >&2
    exit 2
    ;;
esac

if [ "$backend" != "hyper" ] && [ "$hyper_borrow_response_bench" = "1" ]; then
  echo "NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH requires hyper backend" >&2
  exit 2
fi

if [ "$backend" != "hyper" ] && [ "$hyper_session_bench" = "1" ]; then
  echo "NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH requires hyper backend" >&2
  exit 2
fi

if [ "$hyper_borrow_response_bench" = "1" ] && [ "$hyper_session_bench" = "1" ]; then
  echo "NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH and NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH cannot be combined" >&2
  exit 2
fi

if [ "$hyper_borrow_response_bench" = "1" ]; then
  hyper_keepalive_bench=1
fi

if [ "$hyper_session_bench" = "1" ]; then
  hyper_keepalive_bench=1
fi

build_name="$backend"
if [ "$backend" = "hyper" ] && [ "$hyper_session_bench" = "1" ]; then
  build_name="hyper-session-bench"
elif [ "$backend" = "hyper" ] && [ "$hyper_borrow_response_bench" = "1" ]; then
  build_name="hyper-borrow-response-bench"
elif [ "$backend" = "hyper" ] && [ "$hyper_keepalive_bench" = "1" ]; then
  build_name="hyper-keepalive-bench"
fi

prefix="${OPENRESTY_PREFIX:-$workdir/openresty-$build_name}"
openresty_src="openresty-$openresty_version-$build_name"

if [ "$backend" = "hyper" ] && ! grep -q 'NGX_HTTP_FFI_CLIENT_USE_HYPER' "$root/config"; then
  echo "hyper backend is not supported by config yet; NGX_HTTP_FFI_CLIENT_USE_HYPER is not consumed" >&2
  exit 2
fi

mkdir -p "$workdir"
cd "$workdir"

if [ ! -f "openresty-$openresty_version.tar.gz" ]; then
  curl -fsSLO "https://openresty.org/download/openresty-$openresty_version.tar.gz"
fi

if [ ! -d "$openresty_src" ]; then
  rm -rf "openresty-$openresty_version"
  tar -zxf "openresty-$openresty_version.tar.gz"
  mv "openresty-$openresty_version" "$openresty_src"
fi

if [ ! -d "pcre2-$pcre2_version" ]; then
  curl -fsSLO "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pcre2_version/pcre2-$pcre2_version.tar.gz"
  tar -zxf "pcre2-$pcre2_version.tar.gz"
fi

cd "$workdir/$openresty_src"
ngx_lua_dir="$(find "$PWD/bundle" -maxdepth 1 -type d -name 'ngx_lua-*' -print -quit)"
test -n "$ngx_lua_dir"

extra_env=()
if [ "$backend" = "hyper" ]; then
  extra_env+=(NGX_HTTP_FFI_CLIENT_USE_HYPER=1)
  if [ "$hyper_keepalive_bench" = "1" ]; then
    extra_env+=(NGX_HTTP_FFI_CLIENT_HYPER_KEEPALIVE_BENCH=1)
  fi
  if [ "$hyper_borrow_response_bench" = "1" ]; then
    extra_env+=(NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH=1)
  fi
  if [ "$hyper_session_bench" = "1" ]; then
    extra_env+=(NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH=1)
  fi
fi

env "${extra_env[@]}" NGX_HTTP_LUA_MODULE_DIR="$ngx_lua_dir" ./configure \
  --prefix="$prefix" \
  --with-pcre="$workdir/pcre2-$pcre2_version" \
  --add-module="$root"

make -j"${MAKE_JOBS:-2}"
make install

echo "$prefix/nginx/sbin/nginx"
