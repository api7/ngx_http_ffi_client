# Tests

Integration tests use Test::Nginx with an OpenResty binary built with this
addon. The current suite covers the HTTP/1.1 client behavior in this repository;
HTTP/2 and HTTP/3 are outside the current test scope.

Required environment:

- `TEST_NGINX_BINARY`: path to the OpenResty/Nginx binary that includes
  `ngx_http_ffi_client_module`.
- `TEST_NGINX_LUA_PACKAGE_PATH`: path to this repository's Lua package pattern.
- `NGX_HTTP_LUA_MODULE_DIR`: path to a matching `lua-nginx-module` checkout
  when building the addon.
- `PERL5LIB`: path to the `test-nginx` `lib` directory when Test::Nginx is
  not installed system-wide.

Example:

```bash
export NGX_HTTP_LUA_MODULE_DIR=/home/rain/git/lua-nginx-module
export TEST_NGINX_BINARY=/path/to/openresty-with-ngx-http-ffi-client
export TEST_NGINX_LUA_PACKAGE_PATH="$PWD/lib/?.lua"
export PERL5LIB=/home/rain/git/test-nginx/lib
prove -r t
```

The GitHub Actions workflow in `.github/workflows/ci.yml` installs the required
Perl dependencies, builds OpenResty with this addon, and runs the same `prove`
suite.
