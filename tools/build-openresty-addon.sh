#!/usr/bin/env bash
set -euo pipefail

backend="${1:-c}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

openresty_version="${OPENRESTY_VERSION:-1.31.1.1}"
pcre2_version="${PCRE2_VERSION:-10.45}"
workdir="${NGX_HTTP_FFI_CLIENT_BUILD_DIR:-/tmp/ngx_http_ffi_client_build}"
prefix="${OPENRESTY_PREFIX:-$workdir/openresty-$backend}"

case "$backend" in
  c|hyper) ;;
  *)
    echo "usage: $0 [c|hyper]" >&2
    exit 2
    ;;
esac

mkdir -p "$workdir"
cd "$workdir"

if [ ! -d "openresty-$openresty_version" ]; then
  curl -fsSLO "https://openresty.org/download/openresty-$openresty_version.tar.gz"
  tar -zxf "openresty-$openresty_version.tar.gz"
fi

if [ ! -d "pcre2-$pcre2_version" ]; then
  curl -fsSLO "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pcre2_version/pcre2-$pcre2_version.tar.gz"
  tar -zxf "pcre2-$pcre2_version.tar.gz"
fi

cd "$workdir/openresty-$openresty_version"
ngx_lua_dir="$(find "$PWD/bundle" -maxdepth 1 -type d -name 'ngx_lua-*' | head -n 1)"
test -n "$ngx_lua_dir"

extra_env=()
if [ "$backend" = "hyper" ]; then
  extra_env+=(NGX_HTTP_FFI_CLIENT_USE_HYPER=1)
fi

env "${extra_env[@]}" NGX_HTTP_LUA_MODULE_DIR="$ngx_lua_dir" ./configure \
  --prefix="$prefix" \
  --with-pcre="$workdir/pcre2-$pcre2_version" \
  --add-module="$root"

make -j"${MAKE_JOBS:-2}"
make install

echo "$prefix/nginx/sbin/nginx"
