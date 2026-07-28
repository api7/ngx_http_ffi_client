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
local setmetatable = setmetatable
local string_lower = string.lower
local table_concat = table.concat
local ngx_encode_args = ngx.encode_args
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
        uintptr_t ssl;
        uintptr_t ssl_verify;
        ngx_http_ffi_client_ffi_str_t ssl_server_name;
        ngx_http_ffi_client_ffi_str_t ssl_trusted_certificate;
    } ngx_http_ffi_client_ffi_req_t;

    typedef struct {
        uintptr_t status;
        ngx_http_ffi_client_ffi_header_t *headers;
        uintptr_t headers_len;
        ngx_http_ffi_client_ffi_str_t body;
        uintptr_t reused;
        ngx_http_ffi_client_ffi_header_t *trailers;
        uintptr_t trailers_len;
    } ngx_http_ffi_client_ffi_resp_t;

    int ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
        ngx_http_ffi_client_ffi_req_t *req,
        ngx_http_ffi_client_ffi_resp_t *resp,
        unsigned char *err, size_t *errlen);

    typedef struct ngx_http_ffi_client_op_s ngx_http_ffi_client_op_t;

    typedef struct {
        ngx_http_ffi_client_ffi_str_t scheme;
        ngx_http_ffi_client_ffi_str_t host;
        uintptr_t port;
        uintptr_t keepalive;
        ngx_http_ffi_client_ffi_str_t keepalive_pool;
        uintptr_t keepalive_pool_size;
        uintptr_t keepalive_idle_timeout;
        uintptr_t ssl;
        uintptr_t ssl_verify;
        ngx_http_ffi_client_ffi_str_t ssl_server_name;
        ngx_http_ffi_client_ffi_str_t ssl_trusted_certificate;
    } ngx_http_ffi_client_ffi_connect_t;

    typedef struct {
        ngx_http_ffi_client_ffi_str_t method;
        ngx_http_ffi_client_ffi_str_t path;
        ngx_http_ffi_client_ffi_header_t *headers;
        uintptr_t headers_len;
        ngx_http_ffi_client_ffi_str_t body;
        uintptr_t preread_body;
    } ngx_http_ffi_client_ffi_reqp_t;

    typedef struct {
        unsigned char *data;
        size_t len;
        uintptr_t eof;
    } ngx_http_ffi_client_ffi_chunk_t;

    ngx_http_ffi_client_op_t *ngx_http_ffi_client_ffi_new(
        ngx_http_request_t *r);
    void ngx_http_ffi_client_ffi_set_timeouts(ngx_http_ffi_client_op_t *op,
        uintptr_t connect_timeout, uintptr_t send_timeout,
        uintptr_t read_timeout);
    int ngx_http_ffi_client_ffi_connect(ngx_http_request_t *r,
        ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_connect_t *cp,
        unsigned char *err, size_t *errlen);
    int ngx_http_ffi_client_ffi_send_request(ngx_http_request_t *r,
        ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_reqp_t *rp,
        ngx_http_ffi_client_ffi_resp_t *resp, unsigned char *err,
        size_t *errlen);
    int ngx_http_ffi_client_ffi_read_body(ngx_http_request_t *r,
        ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_chunk_t *chunk,
        unsigned char *err, size_t *errlen);
    int ngx_http_ffi_client_ffi_set_keepalive(ngx_http_request_t *r,
        ngx_http_ffi_client_op_t *op, uintptr_t idle_timeout,
        uintptr_t pool_size, unsigned char *err, size_t *errlen);
    void ngx_http_ffi_client_ffi_get_trailers(ngx_http_ffi_client_op_t *op,
        ngx_http_ffi_client_ffi_resp_t *resp);
    uintptr_t ngx_http_ffi_client_ffi_get_reused_times(
        ngx_http_ffi_client_op_t *op);
    void ngx_http_ffi_client_ffi_close(ngx_http_ffi_client_op_t *op);
    ]]
end


local req_t = ffi.typeof("ngx_http_ffi_client_ffi_req_t")
local resp_t = ffi.typeof("ngx_http_ffi_client_ffi_resp_t")
local header_array_t = ffi.typeof("ngx_http_ffi_client_ffi_header_t[?]")
local connect_t = ffi.typeof("ngx_http_ffi_client_ffi_connect_t")
local reqp_t = ffi.typeof("ngx_http_ffi_client_ffi_reqp_t")
local chunk_t = ffi.typeof("ngx_http_ffi_client_ffi_chunk_t")
local ERR_BUF_SIZE = 256
local DEFAULT_TIMEOUT = 60000
local DEFAULT_POOL_SIZE = 30
local ffi_request


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


-- Host, Connection and Content-Length reach C and feed the request prologue.
-- Transfer-Encoding stays out: this client always frames the body with a
-- Content-Length, and both on the wire is the request-smuggling shape (#29).
local function forbidden_header(name)
    return string_lower(name) == "transfer-encoding"
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


local function header_table(arr, count)
    local out = {}

    for i = 0, tonumber(count) - 1 do
        local header = arr[i]
        out[ffi_str(header.key.data, header.key.len)] =
            ffi_str(header.value.data, header.value.len)
    end

    return out
end


local function response_table(resp)
    local body = ""
    if resp.body.data ~= nil and resp.body.len > 0 then
        body = ffi_str(resp.body.data, resp.body.len)
    end

    return {
        status = tonumber(resp.status),
        headers = header_table(resp.headers, resp.headers_len),
        trailers = header_table(resp.trailers, resp.trailers_len),
        body = body,
        reused = resp.reused ~= 0,
    }
end


function _M.request_uri(opts)
    if type(opts) ~= "table" then
        error("opts must be a table", 2)
    end

    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    local scheme = opts.scheme or "http"
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "unsupported scheme"
    end

    local ssl = scheme == "https"

    if type(opts.host) ~= "string" or opts.host == "" then
        return nil, "host is required"
    end

    local port = tonumber(opts.port or (ssl and 443 or 80))
    if not port or port < 1 or port > 65535 then
        return nil, "bad port"
    end

    -- verify defaults on for https; pass ssl_verify = false to disable
    local ssl_verify = ssl and opts.ssl_verify ~= false

    if opts.ssl_server_name ~= nil
       and (type(opts.ssl_server_name) ~= "string"
            or opts.ssl_server_name == "")
    then
        return nil, "ssl_server_name must be a non-empty string"
    end

    local ssl_server_name = opts.ssl_server_name or opts.host
    local ssl_trusted_certificate = opts.ssl_trusted_certificate

    if ssl_trusted_certificate ~= nil
       and type(ssl_trusted_certificate) ~= "string"
    then
        return nil, "ssl_trusted_certificate must be a string"
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
        set_str(req.ssl_server_name, ssl and ssl_server_name or nil),
        set_str(req.ssl_trusted_certificate,
                ssl and ssl_trusted_certificate or nil),
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
    req.ssl = ssl and 1 or 0
    req.ssl_verify = ssl_verify and 1 or 0

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


-- ===== stateful client object (lua-resty-http compatible) =====
--
-- The methods live on their own table, so httpc:request() (the object, one
-- request on an owned connection) never collides with _M.request_uri() (the
-- one-shot). Both drive the same C engine.


local client = {}
local client_mt = { __index = client }

local res_mt

local c_loaded
local c_new, c_set_timeouts, c_connect, c_send, c_read, c_keepalive
local c_reused, c_close, c_trailers


local function load_stateful()
    if c_loaded then
        return true
    end

    local ok = pcall(function()
        c_new = C.ngx_http_ffi_client_ffi_new
        c_set_timeouts = C.ngx_http_ffi_client_ffi_set_timeouts
        c_connect = C.ngx_http_ffi_client_ffi_connect
        c_send = C.ngx_http_ffi_client_ffi_send_request
        c_read = C.ngx_http_ffi_client_ffi_read_body
        c_keepalive = C.ngx_http_ffi_client_ffi_set_keepalive
        c_reused = C.ngx_http_ffi_client_ffi_get_reused_times
        c_close = C.ngx_http_ffi_client_ffi_close
        c_trailers = C.ngx_http_ffi_client_ffi_get_trailers
    end)

    if not ok then
        return false
    end

    c_loaded = true
    return true
end


local function new_err_buf()
    local err = get_string_buf(ERR_BUF_SIZE)
    local errlen = get_size_ptr()
    errlen[0] = ERR_BUF_SIZE

    return err, errlen
end


function _M.new()
    if not load_stateful() then
        return nil, "ngx_http_ffi_client_module is not loaded"
    end

    return setmetatable({
        _op = nil,
        _connected = false,
        _refs = {},
        connect_timeout = DEFAULT_TIMEOUT,
        send_timeout = DEFAULT_TIMEOUT,
        read_timeout = DEFAULT_TIMEOUT,
    }, client_mt)
end


function client.set_timeout(self, timeout)
    return client.set_timeouts(self, timeout, timeout, timeout)
end


function client.set_timeouts(self, connect_timeout, send_timeout, read_timeout)
    self.connect_timeout = connect_timeout or self.connect_timeout
    self.send_timeout = send_timeout or self.send_timeout
    self.read_timeout = read_timeout or self.read_timeout

    if self._op ~= nil then
        c_set_timeouts(self._op, self.connect_timeout, self.send_timeout,
                       self.read_timeout)
    end
end


-- connect{ scheme, host, port, pool, pool_size, ssl_verify, ssl_server_name,
--          ssl_trusted_certificate } or connect(host, port)
function client.connect(self, opts, port_arg)
    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    local host, port, scheme, pool, pool_size
    local ssl_verify, ssl_server_name, ssl_trusted_certificate

    if type(opts) == "table" then
        host = opts.host
        port = opts.port
        scheme = opts.scheme or "http"
        pool = opts.pool
        pool_size = opts.pool_size
        ssl_verify = opts.ssl_verify
        ssl_server_name = opts.ssl_server_name
        ssl_trusted_certificate = opts.ssl_trusted_certificate

    else
        host = opts
        port = port_arg
        scheme = "http"
    end

    if scheme ~= "http" and scheme ~= "https" then
        return nil, "unsupported scheme"
    end

    local ssl = scheme == "https"

    if type(host) ~= "string" or host == "" then
        return nil, "host is required"
    end

    port = tonumber(port or (ssl and 443 or 80))
    if not port or port < 1 or port > 65535 then
        return nil, "bad port"
    end

    -- verify defaults on for https; pass ssl_verify = false to disable
    ssl_verify = ssl and ssl_verify ~= false

    if ssl_server_name ~= nil
       and (type(ssl_server_name) ~= "string" or ssl_server_name == "")
    then
        return nil, "ssl_server_name must be a non-empty string"
    end

    if ssl_trusted_certificate ~= nil
       and type(ssl_trusted_certificate) ~= "string"
    then
        return nil, "ssl_trusted_certificate must be a string"
    end

    if pool ~= nil and type(pool) ~= "string" then
        return nil, "pool must be a string"
    end

    pool_size = tonumber(pool_size or DEFAULT_POOL_SIZE)
    if not pool_size or pool_size < 1 then
        return nil, "bad pool_size"
    end

    if self._op == nil then
        local op = c_new(r)
        if op == nil then
            return nil, "no memory"
        end

        self._op = op
    end

    c_set_timeouts(self._op, self.connect_timeout, self.send_timeout,
                   self.read_timeout)

    local cp = connect_t()
    self._refs.connect = {
        set_str(cp.scheme, scheme),
        set_str(cp.host, host),
        set_str(cp.keepalive_pool, pool),
        set_str(cp.ssl_server_name, ssl and (ssl_server_name or host) or nil),
        set_str(cp.ssl_trusted_certificate,
                ssl and ssl_trusted_certificate or nil),
    }

    cp.port = port
    cp.keepalive = 1
    cp.keepalive_pool_size = pool_size
    cp.keepalive_idle_timeout = 0
    cp.ssl = ssl and 1 or 0
    cp.ssl_verify = ssl_verify and 1 or 0

    local err, errlen = new_err_buf()
    local rc = c_connect(r, self._op, cp, err, errlen)

    if rc == FFI_ERROR then
        return nil, ffi_str(err, errlen[0])
    end

    if rc == FFI_AGAIN then
        local ok, yield_err = co_yield()
        if not ok then
            return nil, yield_err
        end

    elseif rc ~= FFI_OK then
        return nil, "unexpected ffi return code: " .. tonumber(rc)
    end

    self._connected = true

    return 1
end


-- One body slice. The C side hands back a pointer into its read buffer that is
-- only valid until the next call, so the copy into a Lua string happens here.
local function read_chunk(self)
    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    local chunk = self._chunk
    local err, errlen = new_err_buf()

    local rc = c_read(r, self._op, chunk, err, errlen)

    if rc == FFI_ERROR then
        return nil, ffi_str(err, errlen[0])
    end

    if rc == FFI_AGAIN then
        local ok, yield_err = co_yield()
        if not ok then
            return nil, yield_err
        end

    elseif rc ~= FFI_OK then
        return nil, "unexpected ffi return code: " .. tonumber(rc)
    end

    if chunk.len == 0 then
        return nil, nil, true
    end

    return ffi_str(chunk.data, chunk.len), nil, chunk.eof ~= 0
end


local function make_body_reader(res, resp)
    local self = res._httpc
    local done = false

    return function()
        if done then
            return nil
        end

        local chunk, err, eof = read_chunk(self)

        if err then
            done = true
            return nil, err
        end

        if eof then
            done = true
            -- trailers arrive behind the last chunk, so they are only readable
            -- now that the body is fully consumed
            c_trailers(self._op, resp)
            res.trailers = header_table(resp.trailers, resp.trailers_len)
        end

        return chunk
    end
end


local function res_read_body(res)
    -- already read, or handed over whole by the preread fast path
    if res.body then
        return res.body
    end

    local reader = res.body_reader
    if not reader then
        return nil, "no body reader"
    end

    local parts = {}
    local n = 0

    while true do
        local chunk, err = reader()
        if err then
            return nil, err
        end

        if not chunk then
            break
        end

        n = n + 1
        parts[n] = chunk
    end

    res.body = table_concat(parts)

    return res.body
end


res_mt = { __index = { read_body = res_read_body } }


-- request{ method, path, query, headers, body, preread_body }
function client.request(self, params)
    if not self._connected or self._op == nil then
        return nil, "not connected"
    end

    if params ~= nil and type(params) ~= "table" then
        error("params must be a table", 2)
    end

    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    params = params or {}

    local method = params.method or "GET"
    local path = params.path or "/"

    local query = params.query
    if query ~= nil then
        if type(query) == "table" then
            query = ngx_encode_args(query)
        elseif type(query) ~= "string" then
            return nil, "query must be a string or table"
        end

        if query ~= "" then
            local sep = path:find("?", 1, true) and "&" or "?"
            path = path .. sep .. query
        end
    end

    local body = params.body
    if body ~= nil and type(body) ~= "string" then
        body = tostring(body)
    end

    local header_arr, header_count, header_refs, header_err =
        build_headers(params.headers)

    if header_err then
        return nil, header_err
    end

    local rp = reqp_t()
    local resp = resp_t()

    self._refs.request = {
        set_str(rp.method, method),
        set_str(rp.path, path),
        set_str(rp.body, body),
        header_arr,
        header_refs,
        resp,
    }

    rp.headers = header_arr
    rp.headers_len = header_count
    rp.preread_body = params.preread_body and 1 or 0

    local err, errlen = new_err_buf()
    local rc = c_send(r, self._op, rp, resp, err, errlen)

    if rc == FFI_ERROR then
        return nil, ffi_str(err, errlen[0])
    end

    if rc == FFI_AGAIN then
        local ok, yield_err = co_yield()
        if not ok then
            self._connected = false
            return nil, yield_err
        end

    elseif rc ~= FFI_OK then
        return nil, "unexpected ffi return code: " .. tonumber(rc)
    end

    if self._chunk == nil then
        self._chunk = chunk_t()
    end

    local res = setmetatable({
        status = tonumber(resp.status),
        headers = header_table(resp.headers, resp.headers_len),
        trailers = {},
        _httpc = self,
    }, res_mt)

    if rp.preread_body ~= 0 then
        -- the fast path already read the whole body in that single resume
        res.body = resp.body.len > 0
                   and ffi_str(resp.body.data, resp.body.len) or ""
        res.trailers = header_table(resp.trailers, resp.trailers_len)
    end

    res.body_reader = make_body_reader(res, resp)

    return res
end


function client.get_reused_times(self)
    if self._op == nil then
        return 0
    end

    return tonumber(c_reused(self._op))
end


function client.set_keepalive(self, timeout, pool_size)
    if self._op == nil then
        return nil, "not connected"
    end

    local r = get_request()
    if not r then
        error("no request found", 2)
    end

    local err, errlen = new_err_buf()
    local rc = c_keepalive(r, self._op, timeout or 0, pool_size or 0, err,
                           errlen)

    self._connected = false

    if rc == FFI_OK then
        return 1
    end

    return nil, ffi_str(err, errlen[0])
end


function client.close(self)
    if self._op ~= nil then
        c_close(self._op)
    end

    self._connected = false

    return 1
end


return _M
