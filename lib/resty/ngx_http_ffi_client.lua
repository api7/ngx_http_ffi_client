local ffi = require("ffi")
local base = require("resty.core.base")


base.allows_subsystem("http")


local C = ffi.C
local ffi_cast = ffi.cast
local ffi_str = ffi.string
local tonumber = tonumber
local tostring = tostring
local type = type
local pairs = pairs
local string_lower = string.lower
local co_yield = coroutine._yield
local get_request = base.get_request
local get_string_buf = base.get_string_buf
local get_size_ptr = base.get_size_ptr
local FFI_OK = base.FFI_OK
local FFI_ERROR = base.FFI_ERROR
local FFI_AGAIN = base.FFI_AGAIN


if not pcall(ffi.typeof, "ngx_http_ffi_client_ffi_req_t") then
    ffi.cdef[[
    typedef struct ngx_http_request_s ngx_http_request_t;

    typedef struct {
        unsigned char *data;
        size_t len;
    } ngx_http_ffi_client_ffi_str_t;

    typedef struct {
        ngx_http_ffi_client_ffi_str_t key;
        ngx_http_ffi_client_ffi_str_t value;
    } ngx_http_ffi_client_ffi_header_t;

    typedef struct {
        ngx_http_ffi_client_ffi_str_t scheme;
        ngx_http_ffi_client_ffi_str_t host;
        uintptr_t port;
        ngx_http_ffi_client_ffi_str_t method;
        ngx_http_ffi_client_ffi_str_t path;
        ngx_http_ffi_client_ffi_header_t *headers;
        uintptr_t headers_len;
        ngx_http_ffi_client_ffi_str_t body;
        ngx_http_ffi_client_ffi_str_t keepalive_pool;
        uintptr_t keepalive;
        uintptr_t keepalive_idle_timeout;
        uintptr_t keepalive_pool_size;
        uintptr_t connect_timeout;
        uintptr_t send_timeout;
        uintptr_t read_timeout;
    } ngx_http_ffi_client_ffi_req_t;

    typedef struct {
        uintptr_t status;
        ngx_http_ffi_client_ffi_header_t *headers;
        uintptr_t headers_len;
        ngx_http_ffi_client_ffi_str_t body;
        uintptr_t reused;
    } ngx_http_ffi_client_ffi_resp_t;

    int ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
        ngx_http_ffi_client_ffi_req_t *req,
        ngx_http_ffi_client_ffi_resp_t *resp,
        unsigned char *err, size_t *errlen);
    const char *ngx_http_ffi_client_ffi_backend(void);
    ]]
end


local req_t = ffi.typeof("ngx_http_ffi_client_ffi_req_t")
local resp_t = ffi.typeof("ngx_http_ffi_client_ffi_resp_t")
local header_array_t = ffi.typeof("ngx_http_ffi_client_ffi_header_t[?]")
local ERR_BUF_SIZE = 256
local ffi_request
local ffi_backend


local _M = {
    _VERSION = "0.0.1",
}


local function set_str(dst, value)
    if value == nil then
        dst.data = nil
        dst.len = 0
        return nil
    end

    value = tostring(value)
    dst.data = ffi_cast("unsigned char *", value)
    dst.len = #value

    return value
end


local function forbidden_header(name)
    name = string_lower(name)

    return name == "host"
           or name == "connection"
           or name == "content-length"
end


local function build_headers(headers)
    if headers == nil then
        return nil, 0, nil
    end

    if type(headers) ~= "table" then
        return nil, nil, nil, "headers must be a table"
    end

    local kept = {}
    local n = 0

    for key, value in pairs(headers) do
        if type(key) ~= "string" then
            return nil, nil, nil, "header name must be a string"
        end

        if value ~= nil and not forbidden_header(key) then
            n = n + 1
            kept[n] = { key, tostring(value) }
        end
    end

    if n == 0 then
        return nil, 0, kept
    end

    local arr = header_array_t(n)

    for i = 1, n do
        set_str(arr[i - 1].key, kept[i][1])
        set_str(arr[i - 1].value, kept[i][2])
    end

    return arr, n, kept
end


local function response_table(resp)
    local headers = {}

    for i = 0, tonumber(resp.headers_len) - 1 do
        local header = resp.headers[i]
        local key = ffi_str(header.key.data, header.key.len)
        local value = ffi_str(header.value.data, header.value.len)
        headers[key] = value
    end

    local body = ""
    if resp.body.data ~= nil and resp.body.len > 0 then
        body = ffi_str(resp.body.data, resp.body.len)
    end

    return {
        status = tonumber(resp.status),
        headers = headers,
        body = body,
        reused = resp.reused ~= 0,
    }
end


function _M.backend()
    if not ffi_backend then
        local ok
        ok, ffi_backend = pcall(function()
            return C.ngx_http_ffi_client_ffi_backend
        end)

        if not ok then
            ffi_backend = nil
            return nil, "ngx_http_ffi_client_module is not loaded"
        end
    end

    return ffi_str(ffi_backend())
end


function _M.request(opts)
    if type(opts) ~= "table" then
        error("opts must be a table", 2)
    end

    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    local scheme = opts.scheme or "http"
    if scheme ~= "http" then
        return nil, "unsupported scheme"
    end

    if type(opts.host) ~= "string" or opts.host == "" then
        return nil, "host is required"
    end

    local port = tonumber(opts.port or 80)
    if not port or port < 1 or port > 65535 then
        return nil, "bad port"
    end

    local method = opts.method or "GET"
    local path = opts.path or "/"
    local body = opts.body
    local keepalive = opts.keepalive

    if body ~= nil and type(body) ~= "string" then
        body = tostring(body)
    end

    if keepalive ~= nil and type(keepalive) ~= "table" then
        return nil, "keepalive must be a table"
    end

    local keepalive_pool
    local keepalive_idle_timeout = 0
    local keepalive_pool_size = 0

    if keepalive then
        keepalive_pool = keepalive.pool
        if keepalive_pool ~= nil and type(keepalive_pool) ~= "string" then
            return nil, "keepalive.pool must be a string"
        end

        keepalive_idle_timeout =
            tonumber(keepalive.idle_timeout or 60000)
        if not keepalive_idle_timeout or keepalive_idle_timeout < 0 then
            return nil, "bad keepalive.idle_timeout"
        end

        keepalive_pool_size = tonumber(keepalive.pool_size or 30)
        if not keepalive_pool_size or keepalive_pool_size < 1 then
            return nil, "bad keepalive.pool_size"
        end
    end

    local header_arr, header_count, header_refs, header_err =
        build_headers(opts.headers)

    if header_err then
        return nil, header_err
    end

    local req = req_t()
    local resp = resp_t()
    local refs = {
        set_str(req.scheme, scheme),
        set_str(req.host, opts.host),
        set_str(req.method, method),
        set_str(req.path, path),
        set_str(req.body, body),
        set_str(req.keepalive_pool, keepalive_pool),
        header_arr,
        header_refs,
    }

    req.port = port
    req.headers = header_arr
    req.headers_len = header_count
    req.keepalive = keepalive and 1 or 0
    req.keepalive_idle_timeout = keepalive_idle_timeout
    req.keepalive_pool_size = keepalive_pool_size
    req.connect_timeout = tonumber(opts.connect_timeout or opts.timeout or 60000)
    req.send_timeout = tonumber(opts.send_timeout or opts.timeout or 60000)
    req.read_timeout = tonumber(opts.read_timeout or opts.timeout or 60000)

    local err = get_string_buf(ERR_BUF_SIZE)
    local errlen = get_size_ptr()
    errlen[0] = ERR_BUF_SIZE

    if not ffi_request then
        local ok
        ok, ffi_request = pcall(function()
            return C.ngx_http_ffi_client_ffi_request
        end)

        if not ok then
            ffi_request = nil
            return nil, "ngx_http_ffi_client_module is not loaded"
        end
    end

    local rc = ffi_request(r, req, resp, err, errlen)

    if rc == FFI_OK then
        return response_table(resp)
    end

    if rc == FFI_ERROR then
        return nil, ffi_str(err, errlen[0])
    end

    if rc ~= FFI_AGAIN then
        return nil, "unexpected ffi return code: " .. tonumber(rc)
    end

    local ok, yield_err = co_yield()

    if refs == nil then
        return nil, "internal error"
    end

    if not ok then
        return nil, yield_err
    end

    return response_table(resp)
end


return _M
