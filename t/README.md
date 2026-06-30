# Tests

Integration tests use Test::Nginx with an OpenResty binary built with this
addon.

Required environment:

- `TEST_NGINX_BINARY`: path to the OpenResty/Nginx binary that includes
  `ngx_http_ffi_client_module`.
- `TEST_NGINX_LUA_PACKAGE_PATH`: path to this repository's Lua package pattern.
- `NGX_HTTP_LUA_MODULE_DIR`: path to a matching `lua-nginx-module` checkout
  when building the addon.

Example:

```bash
export NGX_HTTP_LUA_MODULE_DIR=/home/rain/git/lua-nginx-module
export TEST_NGINX_BINARY=/path/to/openresty-with-ngx-http-ffi-client
export TEST_NGINX_LUA_PACKAGE_PATH="$PWD/lib/?.lua"
prove -r t
```
