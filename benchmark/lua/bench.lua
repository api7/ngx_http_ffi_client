-- Bench case drivers.
--
-- Every case is a driver plus a shape, never a hand-written handler. That is
-- deliberate: the old harness hand-wrote one location per client and the two
-- drifted into different API shapes, so the published ratio credited the
-- API-shape difference to the C-vs-Lua difference. Here both columns of a pair
-- are built from one shape table, so they send the same headers, carry the same
-- timeouts, size the same pool, and consume the body the same way by
-- construction rather than by review.
--
-- A driver returns (bytes_read, status) or (nil, nil, err). The dispatcher
-- writes the same fixed-size downstream body for every case, the baseline
-- included, so the downstream write cost cancels out of the baseline
-- subtraction and only the outbound client work differs between cases.

local ffi_client = require "resty.ngx_http_ffi_client"
local resty_http = require "resty.http"

local ngx = ngx
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local pairs = pairs
local tostring = tostring
local table_sort = table.sort
local str_format = string.format
local str_rep = string.rep


local _M = {}


local cfg = {
    host = "127.0.0.1",
    port = 80,
    tls_port = 443,
    trailer_port = 8443,
    dns_host = "localhost",
    tls_server_name = "bench.local",
    -- the upstream's self-signed cert, trusted by both clients for the
    -- verify-on cases. resty.http has no per-request trust store, so its side
    -- comes from lua_ssl_trusted_certificate in the target conf; this is the
    -- same file, so both are asked to verify the identical chain.
    ca_file = "",
    pool_size = 120,
    idle_timeout = 60000,
    timeout = 60000,
    response_body = "",
}


-- Request header sets. Both columns of a pair always send the identical table,
-- so the 3-vs-30 axis prices per-request header validation rather than a
-- difference in what the two clients were asked to send. The tables are built
-- once: constructing them per request would measure Lua table construction.
local HEADERS_3 = {
    ["X-Bench-A"] = "aaaaaaaa",
    ["X-Bench-B"] = "bbbbbbbb",
    ["X-Bench-C"] = "cccccccc",
}

local HEADERS_30 = {}
do
    for i = 1, 30 do
        HEADERS_30[str_format("X-Bench-%02d", i)] = str_rep("v", 16)
    end
end

local POST_BODY = str_rep("p", 4096)


function _M.init(opts)
    for k, v in pairs(opts) do
        cfg[k] = v
    end
end


-- ===== shape =====
--
-- scheme     "http" or "https"
-- dns        resolve the peer by hostname instead of using the IP literal
-- trailers   talk to the raw TCP mock, the only peer here that sends trailers
-- path       upstream path, which selects the response framing and header count
-- method     defaults to GET
-- body       request body, for the POST axis
-- headers    request header table, for the request-header-count axis
-- keepalive  false for the short-lived-connection axis
-- stream     drain res.body_reader instead of buffering the body
-- read_body  buffer the body, but through the Lua chunk loop rather than the
--            C preread fast path (FFI only; resty.http has no other mode)
-- echo       return the body itself instead of its length, for the audit
-- pool       keepalive pool name, assigned per case by pair_case

local function peer(s)
    local scheme = s.scheme or "http"
    local https = scheme == "https"
    local port

    if https then
        port = cfg.tls_port
    elseif s.trailers then
        port = cfg.trailer_port
    else
        port = cfg.port
    end

    return scheme,
           s.dns and cfg.dns_host or cfg.host,
           port,
           s.path or "/mock",
           s.method or "GET",
           s.headers or HEADERS_3,
           s.keepalive ~= false,
           -- both clients send the same SNI for the TLS cases; left to their own
           -- devices the FFI client defaults it to the host and resty.http omits
           -- it, which would not be the same handshake
           https and cfg.tls_server_name or nil,
           -- verification is off unless a shape asks for it, so the plain tls
           -- cases keep pricing the handshake rather than the trust store
           (https and s.verify) and true or false
end


-- ===== FFI client =====

local function ffi_oneshot(s)
    local scheme, host, port, path, method, headers, keepalive, sni,
          verify = peer(s)

    local res, err = ffi_client.request_uri({
        scheme = scheme,
        host = host,
        port = port,
        method = method,
        path = path,
        headers = headers,
        body = s.body,
        timeout = cfg.timeout,
        ssl_verify = verify,
        ssl_trusted_certificate = verify and cfg.ca_file or nil,
        ssl_server_name = sni,
        keepalive = keepalive and {
            pool = s.pool,
            pool_size = cfg.pool_size,
            idle_timeout = cfg.idle_timeout,
        } or nil,
    })

    if not res then
        return nil, nil, err
    end

    if s.echo then
        return res.body, res.status
    end

    return #res.body, res.status
end


local function ffi_stateful(s)
    local scheme, host, port, path, method, headers, keepalive, sni,
          verify = peer(s)

    local httpc, err = ffi_client.new()
    if not httpc then
        return nil, nil, err
    end

    httpc:set_timeouts(cfg.timeout, cfg.timeout, cfg.timeout)

    local ok
    ok, err = httpc:connect({
        scheme = scheme,
        host = host,
        port = port,
        pool = s.pool,
        pool_size = cfg.pool_size,
        ssl_verify = verify,
        ssl_trusted_certificate = verify and cfg.ca_file or nil,
        ssl_server_name = sni,
    })
    if not ok then
        return nil, nil, err
    end

    local res
    res, err = httpc:request({
        method = method,
        path = path,
        headers = headers,
        body = s.body,
        -- the buffered fast path: C reads the whole body and resumes once.
        -- read_body sends the same request but takes the Lua chunk loop back.
        preread_body = not (s.stream or s.read_body),
    })
    if not res then
        httpc:close()
        return nil, nil, err
    end

    local result

    if s.stream then
        local n = 0
        local reader = res.body_reader

        while true do
            local chunk, rerr = reader()
            if rerr then
                httpc:close()
                return nil, nil, rerr
            end
            if not chunk then
                break
            end
            n = n + #chunk
        end

        result = n

    else
        local body
        body, err = res:read_body()
        if not body then
            httpc:close()
            return nil, nil, err
        end

        result = s.echo and body or #body
    end

    if keepalive then
        ok, err = httpc:set_keepalive(cfg.idle_timeout, cfg.pool_size)
        if not ok then
            ngx_log(ngx_ERR, "ffi set_keepalive failed: ", tostring(err))
        end

    else
        httpc:close()
    end

    return result, res.status
end


-- ===== lua-resty-http =====

local function resty_oneshot(s)
    local scheme, host, port, path, method, headers, keepalive, sni,
          verify = peer(s)

    local httpc, err = resty_http.new()
    if not httpc then
        return nil, nil, err
    end

    httpc:set_timeouts(cfg.timeout, cfg.timeout, cfg.timeout)

    local res
    res, err = httpc:request_uri(
        str_format("%s://%s:%d%s", scheme, host, port, path), {
            method = method,
            headers = headers,
            body = s.body,
            -- the FFI client sends no User-Agent, so neither does this one:
            -- otherwise resty.http pays for ~55 extra bytes on every request
            use_default_user_agent = false,
            ssl_verify = verify,
            ssl_server_name = sni,
            pool = s.pool,
            pool_size = cfg.pool_size,
            keepalive = keepalive,
            keepalive_timeout = cfg.idle_timeout,
            keepalive_pool = cfg.pool_size,
        })

    if not res then
        return nil, nil, err
    end

    if s.echo then
        return res.body, res.status
    end

    return #res.body, res.status
end


local function resty_stateful(s)
    local scheme, host, port, path, method, headers, keepalive, sni,
          verify = peer(s)

    local httpc, err = resty_http.new()
    if not httpc then
        return nil, nil, err
    end

    httpc:set_timeouts(cfg.timeout, cfg.timeout, cfg.timeout)

    local ok
    ok, err = httpc:connect({
        scheme = scheme,
        host = host,
        port = port,
        pool = s.pool,
        pool_size = cfg.pool_size,
        ssl_verify = verify,
        ssl_server_name = sni,
    })
    if not ok then
        return nil, nil, err
    end

    local res
    res, err = httpc:request({
        method = method,
        path = path,
        headers = headers,
        body = s.body,
        use_default_user_agent = false,
    })
    if not res then
        httpc:close()
        return nil, nil, err
    end

    local result

    if s.stream then
        local n = 0
        local reader = res.body_reader

        while true do
            local chunk, rerr = reader()
            if rerr then
                httpc:close()
                return nil, nil, rerr
            end
            if not chunk then
                break
            end
            n = n + #chunk
        end

        result = n

    else
        local body
        body, err = res:read_body()
        if not body then
            httpc:close()
            return nil, nil, err
        end

        result = s.echo and body or #body
    end

    if keepalive then
        ok, err = httpc:set_keepalive(cfg.idle_timeout, cfg.pool_size)
        if not ok then
            ngx_log(ngx_ERR, "resty.http set_keepalive failed: ", tostring(err))
        end

    else
        httpc:close()
    end

    return result, res.status
end


-- ===== case table =====
--
-- Names are <driver>.<shape>. The headline ratio compares the same shape across
-- the ffi.* and resty.* columns; the gap between ffi.oneshot and ffi.stateful
-- separately prices the C fast path against this library's own Lua object
-- layer.

local cases = {}


local function pair_case(name, shape)
    for _, driver in ipairs({ "ffi", "resty" }) do
        local copy = {}

        for k, v in pairs(shape) do
            copy[k] = v
        end

        -- separate pools, so one client can never be handed a connection the
        -- other opened and look free for whichever case ran second
        copy.pool = "bench-" .. driver .. "-" .. name

        local fn
        if driver == "ffi" then
            fn = shape.oneshot and ffi_oneshot or ffi_stateful
        else
            fn = shape.oneshot and resty_oneshot or resty_stateful
        end

        cases[driver .. "." .. name] = { fn = fn, shape = copy }
    end
end


-- the 2x2: one-shot and stateful, on both clients, against the same upstream
pair_case("oneshot", { oneshot = true })
pair_case("stateful", {})

-- read mode
pair_case("readbody", { read_body = true })
pair_case("stream", { stream = true })

-- connection lifetime
pair_case("short", { keepalive = false })

-- method
pair_case("post", { method = "POST", body = POST_BODY, path = "/mock/sink" })

-- transport: pooled connections amortise the handshake away, so the
-- short-lived TLS case is the one that prices a fresh handshake
pair_case("tls", { scheme = "https" })
pair_case("tlsshort", { scheme = "https", keepalive = false })
-- verify on: these price the trust store, which the two cases above
-- deliberately do not. Both clients trust the same self-signed upstream cert.
pair_case("tlsverify", { scheme = "https", verify = true })
pair_case("tlsverifyshort",
          { scheme = "https", verify = true, keepalive = false })

-- peer address
pair_case("dns", { dns = true })

-- response framing
pair_case("chunked", { path = "/mock/chunked" })
pair_case("trailers", { trailers = true, path = "/" })

-- response header count
pair_case("hdr40", { path = "/mock/headers40" })
pair_case("cookies", { path = "/mock/cookies" })

-- request header count
pair_case("req30", { headers = HEADERS_30 })


function _M.run(name)
    local case = cases[name]
    if not case then
        ngx.status = 500
        ngx.print("unknown bench case: ", tostring(name))
        return
    end

    local n, status, err = case.fn(case.shape)

    if not n then
        ngx.status = 502
        ngx_log(ngx_ERR, "bench case ", name, " failed: ", tostring(err))
        ngx.print(tostring(err))
        return
    end

    ngx.status = status

    -- every case, baseline included, writes the same downstream bytes, so the
    -- baseline subtraction removes an identical downstream cost from each
    local body = cfg.response_body
    ngx.header["Content-Length"] = #body
    ngx.print(body)
end


function _M.baseline()
    local body = cfg.response_body
    ngx.header["Content-Length"] = #body
    ngx.print(body)
end


-- Report what a case actually did: status and bytes read. The runner calls this
-- during the fairness audit, before any load, so nothing here costs anything on
-- the measured path.
function _M.audit(name)
    local case = cases[name]
    if not case then
        ngx.status = 500
        ngx.say("unknown bench case: ", tostring(name))
        return
    end

    local n, status, err = case.fn(case.shape)

    if not n then
        ngx.status = 502
        ngx.say("case=", name, " error=", tostring(err))
        return
    end

    ngx.say("case=", name, " status=", status, " bytes=", n)
end


-- Run a case against the upstream's echo endpoint, which replies with the raw
-- request header block it received. The runner diffs the two columns of a pair:
-- if the bytes differ, the pair is not measuring the same request, and that is
-- a fairness failure before any load is applied.
function _M.echo(name)
    local case = cases[name]
    if not case then
        ngx.status = 500
        ngx.say("unknown bench case: ", tostring(name))
        return
    end

    local shape = {}
    for k, v in pairs(case.shape) do
        shape[k] = v
    end

    shape.path = "/mock/echo"
    -- the raw TCP trailer mock has no echo endpoint, so this pair is audited
    -- against the http mock instead
    shape.trailers = nil
    -- echoing is a buffered read whatever the case's own read mode is
    shape.stream = nil
    shape.read_body = nil
    shape.echo = true
    shape.pool = shape.pool .. "-echo"

    local body, _, err = case.fn(shape)

    if not body then
        ngx.status = 502
        ngx.say("error: ", tostring(err))
        return
    end

    ngx.print(body)
end


function _M.case_names()
    local names = {}

    for name in pairs(cases) do
        names[#names + 1] = name
    end

    table_sort(names)

    return names
end


return _M
