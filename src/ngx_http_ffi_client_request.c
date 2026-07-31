#include "ngx_http_ffi_client.h"

#if (NGX_SSL)
#include <openssl/x509v3.h>
#endif


static ngx_int_t ngx_http_ffi_client_get_peer(ngx_peer_connection_t *pc,
    void *data);
static ngx_int_t ngx_http_ffi_client_set_err(u_char *err, size_t *errlen,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_set_op_err(ngx_http_ffi_client_op_t *op,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_set_op_errno(ngx_http_ffi_client_op_t *op,
    ngx_err_t err, const char *fallback);
static ngx_uint_t ngx_http_ffi_client_has_crlf(u_char *data, size_t len);
static ngx_uint_t ngx_http_ffi_client_header_is_reserved(
    ngx_http_ffi_client_ffi_str_t *key);
static ngx_uint_t ngx_http_ffi_client_method_is_head(
    ngx_http_ffi_client_ffi_str_t *method);
static ngx_int_t ngx_http_ffi_client_build_host_header(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_req_t *req, ngx_str_t *host, u_char *err,
    size_t *errlen);
static ngx_uint_t ngx_http_ffi_client_connection_is_close(ngx_str_t *value);
static ngx_int_t ngx_http_ffi_client_build_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_buf_t **buf, ngx_str_t *host,
    ngx_uint_t *conn_close, u_char *err, size_t *errlen);
static ngx_int_t ngx_http_ffi_client_parse_peer(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen);
static ngx_int_t ngx_http_ffi_client_connect(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_connect(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_resolve(ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_resolve_handler(ngx_resolver_ctx_t *ctx);
static void ngx_http_ffi_client_set_cleanup(ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_clear_cleanup(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_export_err(ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen);
static void ngx_http_ffi_client_write_handler(ngx_event_t *wev);
static void ngx_http_ffi_client_read_handler(ngx_event_t *rev);
static ngx_int_t ngx_http_ffi_client_check_connect(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_prepare_connection(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_write(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_stream(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_next_chunk(ngx_http_ffi_client_op_t *op,
    ngx_http_ffi_client_ffi_chunk_t *chunk, u_char *err, size_t *errlen);
static void ngx_http_ffi_client_stateful_connected(
    ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_op_reset(ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_op_pool_cleanup(void *data);
static void ngx_http_ffi_client_cleanup(void *data);
static void ngx_http_ffi_client_close(ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_finalize(ngx_http_ffi_client_op_t *op,
    ngx_int_t rc, const char *msg);
static ngx_int_t ngx_http_ffi_client_handle_write_wait(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_handle_read_wait(
    ngx_http_ffi_client_op_t *op);
#if (NGX_SSL)
static ngx_ssl_t *ngx_http_ffi_client_ssl_ctx(
    ngx_http_ffi_client_main_conf_t *fmcf, ngx_str_t *ca, ngx_log_t *log);
static ngx_int_t ngx_http_ffi_client_ssl_init_connection(
    ngx_http_ffi_client_op_t *op);
static ngx_uint_t ngx_http_ffi_client_name_is_ip(ngx_str_t *name);
static ngx_int_t ngx_http_ffi_client_ssl_check_identity(ngx_connection_t *c,
    ngx_str_t *name);
static ngx_int_t ngx_http_ffi_client_ssl_set_sni(ngx_connection_t *c,
    ngx_str_t *name);
static void ngx_http_ffi_client_ssl_handshake_handler(ngx_connection_t *c);
#endif


ngx_int_t
ngx_http_ffi_client_start(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen)
{
    ngx_int_t                 rc;
    ngx_uint_t                is_https, conn_close;
    ngx_http_ffi_client_op_t *op;

    if (req == NULL || resp == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad request");
    }

    is_https = req->scheme.data != NULL
               && req->scheme.len == sizeof("https") - 1
               && ngx_strncmp(req->scheme.data, "https", sizeof("https") - 1)
                  == 0;

    if (req->scheme.data == NULL
        || !(is_https
             || (req->scheme.len == sizeof("http") - 1
                 && ngx_strncmp(req->scheme.data, "http",
                                sizeof("http") - 1) == 0)))
    {
        return ngx_http_ffi_client_set_err(err, errlen, "unsupported scheme");
    }

    /* scheme and the ssl flag must agree: no plaintext on an https URL */
    if ((is_https != 0) != (req->ssl != 0)) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "scheme and ssl flag mismatch");
    }

    if (req->port == 0 || req->port > 65535) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad port");
    }

    if (req->headers_len != 0 && req->headers == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid headers");
    }

    op = ngx_pcalloc(r->pool, sizeof(ngx_http_ffi_client_op_t));
    if (op == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    op->r = r;
    op->ffi_resp = resp;
    op->connect_timeout = req->connect_timeout;
    op->send_timeout = req->send_timeout;
    op->read_timeout = req->read_timeout;
    op->keepalive = req->keepalive ? 1 : 0;
    op->keepalive_idle_timeout = req->keepalive_idle_timeout;
    op->keepalive_pool_size = req->keepalive_pool_size;
    op->errlen = 0;

    if (req->ssl) {
#if (NGX_SSL)
        op->ssl = 1;
        op->ssl_verify = req->ssl_verify ? 1 : 0;
        if (req->ssl_server_name.len) {
            if (req->ssl_server_name.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "invalid TLS server name");
            }
            op->ssl_server_name.len = req->ssl_server_name.len;
            op->ssl_server_name.data = ngx_pnalloc(r->pool,
                                                   req->ssl_server_name.len);
            if (op->ssl_server_name.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }
            ngx_memcpy(op->ssl_server_name.data, req->ssl_server_name.data,
                       req->ssl_server_name.len);
        }
        if (req->ssl_trusted_certificate.len) {
            if (req->ssl_trusted_certificate.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "invalid trusted certificate");
            }
            op->ssl_trusted_certificate.len = req->ssl_trusted_certificate.len;
            op->ssl_trusted_certificate.data =
                ngx_pnalloc(r->pool, req->ssl_trusted_certificate.len);
            if (op->ssl_trusted_certificate.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }
            ngx_memcpy(op->ssl_trusted_certificate.data,
                       req->ssl_trusted_certificate.data,
                       req->ssl_trusted_certificate.len);
        }
#else
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "TLS is not supported by this build");
#endif
    }

    op->coctx = ngx_http_lua_get_cur_co_ctx(r);
    if (op->coctx == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "no coroutine context found");
    }

    if (ngx_http_ffi_client_response_parser_init(r->pool, &op->parser)
        != NGX_OK)
    {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    if (ngx_http_ffi_client_method_is_head(&req->method)) {
        ngx_http_ffi_client_response_head(&op->parser);
    }

    if (ngx_http_ffi_client_build_host_header(r->pool, req, &op->host_header,
                                              err, errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    if (ngx_http_ffi_client_build_request(r, req, &op->request,
                                          &op->host_header, &conn_close, err,
                                          errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    if (conn_close) {
        /* the request tells the peer this connection ends here, so it must not
         * come from the pool or go back into it */
        op->keepalive = 0;
    }

    if (ngx_http_ffi_client_parse_peer(r, req, op, err, errlen) == NGX_ERROR) {
        return NGX_ERROR;
    }

    if (op->keepalive
        && ngx_http_ffi_client_keepalive_bind(r, op, req, err, errlen)
           != NGX_OK)
    {
        return NGX_ERROR;
    }

    /* nothing past this point reads req: the FFI struct belongs to Lua and the
     * connect can outlive this call */

    rc = ngx_http_ffi_client_connect(op);

    if (rc == NGX_ERROR) {
        return ngx_http_ffi_client_export_err(op, err, errlen);
    }

    return rc;
}


/*
 * Acquire a connection: reuse a pooled one, resolve the host when it is a name,
 * else connect. Returns NGX_AGAIN once the operation is pending, or NGX_ERROR
 * with op->err set. Never resumes the coroutine.
 */
static ngx_int_t
ngx_http_ffi_client_connect(ngx_http_ffi_client_op_t *op)
{
    ngx_int_t  rc;

    if (op->keepalive && ngx_http_ffi_client_keepalive_get(op) == NGX_OK) {
        if (ngx_http_ffi_client_prepare_connection(op) != NGX_OK) {
            ngx_http_ffi_client_close(op);
            return ngx_http_ffi_client_set_op_err(op, "no memory");
        }

        if (op->stateful) {
            /* a pooled connection is live already: the object is connected
             * without ever parking the coroutine */
            op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
            op->connected = 1;
            return NGX_OK;
        }

        ngx_http_ffi_client_set_cleanup(op);

        op->state = NGX_HTTP_FFI_CLIENT_WRITING;
        ngx_post_event(op->peer.connection->write, &ngx_posted_events);
        return NGX_AGAIN;
    }

    if (op->peer.sockaddr == NULL) {
        /* a hostname with nothing pooled: resolve first. The cosocket checks
         * its pool before resolving too, so a reused connection costs no DNS. */
        rc = ngx_http_ffi_client_resolve(op);

        if (rc != NGX_OK) {
            /* NGX_AGAIN while the answer is pending, NGX_ERROR on failure */
            return rc;
        }

        /* answered from the resolver cache */
    }

    return ngx_http_ffi_client_do_connect(op);
}


/* Open the connection to an already known peer address. */
static ngx_int_t
ngx_http_ffi_client_do_connect(ngx_http_ffi_client_op_t *op)
{
    ngx_int_t          rc;
    ngx_connection_t  *c;

    op->peer.get = ngx_http_ffi_client_get_peer;
    op->peer.log = op->r->connection->log;
    op->peer.log_error = NGX_ERROR_ERR;

    rc = ngx_event_connect_peer(&op->peer);

    if (rc == NGX_ERROR || rc == NGX_DECLINED) {
        /* connect() failed outright, so its errno is still the last one set */
        return ngx_http_ffi_client_set_op_errno(op, ngx_socket_errno,
                                                "connect failed");
    }

    if (rc == NGX_BUSY) {
        return ngx_http_ffi_client_set_op_err(op, "no live connection");
    }

    c = op->peer.connection;
    if (ngx_http_ffi_client_prepare_connection(op) != NGX_OK) {
        ngx_http_ffi_client_close(op);
        return ngx_http_ffi_client_set_op_err(op, "no memory");
    }

    ngx_http_ffi_client_set_cleanup(op);

    if (rc == NGX_OK) {
        /* TCP already connected: TLS still needs an async handshake, so route
         * it through the CONNECTING branch of the write handler. */
#if (NGX_SSL)
        op->state = op->ssl ? NGX_HTTP_FFI_CLIENT_CONNECTING
                            : NGX_HTTP_FFI_CLIENT_WRITING;
#else
        op->state = NGX_HTTP_FFI_CLIENT_WRITING;
#endif

        if (op->stateful && op->state == NGX_HTTP_FFI_CLIENT_WRITING) {
            /* nothing left to wait for: report the connection without parking
             * the coroutine */
            ngx_http_ffi_client_clear_cleanup(op);
            op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
            op->connected = 1;
            return NGX_OK;
        }

        ngx_post_event(c->write, &ngx_posted_events);
        return NGX_AGAIN;
    }

    op->state = NGX_HTTP_FFI_CLIENT_CONNECTING;
    ngx_add_timer(c->write, op->connect_timeout);

    if (ngx_handle_write_event(c->write, 0) != NGX_OK) {
        ngx_http_ffi_client_close(op);
        ngx_http_ffi_client_clear_cleanup(op);
        return ngx_http_ffi_client_set_op_err(op,
                                              "failed to handle write event");
    }

    return NGX_AGAIN;
}


static ngx_int_t
ngx_http_ffi_client_get_peer(ngx_peer_connection_t *pc, void *data)
{
    pc->type = SOCK_STREAM;
    return NGX_OK;
}


static ngx_int_t
ngx_http_ffi_client_set_err(u_char *err, size_t *errlen, const char *msg)
{
    if (err != NULL && errlen != NULL && *errlen > 0) {
        *errlen = ngx_snprintf(err, *errlen, "%s", msg) - err;
    }

    return NGX_ERROR;
}


static ngx_int_t
ngx_http_ffi_client_set_op_err(ngx_http_ffi_client_op_t *op, const char *msg)
{
    op->errlen = ngx_snprintf(op->err, sizeof(op->err), "%s", msg) - op->err;
    return NGX_ERROR;
}


/*
 * Report a socket error by its errno text ("connection refused" and friends),
 * which is what the cosocket hands to lua-resty-http callers. Falls back to
 * `fallback` when there is no errno to name.
 */
static ngx_int_t
ngx_http_ffi_client_set_op_errno(ngx_http_ffi_client_op_t *op, ngx_err_t err,
    const char *fallback)
{
    u_char  *p;
    u_char   errstr[NGX_MAX_ERROR_STR];

    if (err == 0) {
        return ngx_http_ffi_client_set_op_err(op, fallback);
    }

    p = ngx_strerror(err, errstr, sizeof(errstr));
    op->errlen = ngx_snprintf(op->err, sizeof(op->err), "%*s", p - errstr,
                              errstr) - op->err;

    return NGX_ERROR;
}


static ngx_uint_t
ngx_http_ffi_client_has_crlf(u_char *data, size_t len)
{
    size_t  i;

    for (i = 0; i < len; i++) {
        if (data[i] == CR || data[i] == LF) {
            return 1;
        }
    }

    return 0;
}


#define ngx_http_ffi_client_header_eq(key, name)                              \
    ((key)->len == sizeof(name) - 1                                           \
     && ngx_strncasecmp((key)->data, (u_char *) name, sizeof(name) - 1) == 0)


/*
 * Headers the client writes itself, in the fixed prologue of every request. A
 * caller may still set Host, Connection and Content-Length: their values feed
 * that prologue instead of being emitted a second time.
 */
static ngx_uint_t
ngx_http_ffi_client_header_is_reserved(ngx_http_ffi_client_ffi_str_t *key)
{
    return ngx_http_ffi_client_header_eq(key, "Host")
           || ngx_http_ffi_client_header_eq(key, "Connection")
           || ngx_http_ffi_client_header_eq(key, "Content-Length")
           /* the request is always content-length framed; letting a caller add
            * Transfer-Encoding would put both on the wire, which is the classic
            * request-smuggling shape. Honoring it needs a streamed request
            * body: api7/ngx_http_ffi_client#29 */
           || ngx_http_ffi_client_header_eq(key, "Transfer-Encoding");
}


/*
 * True when a comma-separated list header carries `token`. Whole tokens are
 * compared, so a Connection of "disclose" is a different token and leaves the
 * connection alone.
 */
ngx_uint_t
ngx_http_ffi_client_has_token(ngx_str_t *value, const char *token, size_t len)
{
    u_char  *p, *start, *last, *end;

    p = value->data;
    end = value->data + value->len;

    while (p < end) {
        while (p < end && (*p == ',' || *p == ' ' || *p == '\t')) {
            p++;
        }

        start = p;

        while (p < end && *p != ',') {
            p++;
        }

        last = p;

        while (last > start && (last[-1] == ' ' || last[-1] == '\t')) {
            last--;
        }

        if ((size_t) (last - start) == len
            && ngx_strncasecmp(start, (u_char *) token, len) == 0)
        {
            return 1;
        }
    }

    return 0;
}


/* true when a Connection value asks for the connection to end */
static ngx_uint_t
ngx_http_ffi_client_connection_is_close(ngx_str_t *value)
{
    return ngx_http_ffi_client_has_token(value, "close", sizeof("close") - 1);
}


/* HEAD is case-sensitive per RFC 9110, as it is in lua-resty-http */
static ngx_uint_t
ngx_http_ffi_client_method_is_head(ngx_http_ffi_client_ffi_str_t *method)
{
    return method->data != NULL
           && method->len == sizeof("HEAD") - 1
           && ngx_strncmp(method->data, "HEAD", sizeof("HEAD") - 1) == 0;
}


static ngx_int_t
ngx_http_ffi_client_build_host_header(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_req_t *req, ngx_str_t *host, u_char *err,
    size_t *errlen)
{
    u_char      *p;
    ngx_uint_t   ipv6;

    if (req->host.len == 0 || req->host.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "host is required");
    }

    if (ngx_http_ffi_client_has_crlf(req->host.data, req->host.len)) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid host");
    }

    ipv6 = memchr(req->host.data, ':', req->host.len) != NULL;

    host->len = req->host.len + (req->port == 80 ? 0 : NGX_INT_T_LEN + 1)
                + (ipv6 ? 2 : 0);
    host->data = ngx_pnalloc(pool, host->len);
    if (host->data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    p = host->data;

    if (ipv6) {
        *p++ = '[';
    }

    p = ngx_cpymem(p, req->host.data, req->host.len);

    if (ipv6) {
        *p++ = ']';
    }

    if (req->port != 80) {
        p = ngx_sprintf(p, ":%ui", req->port);
    }

    host->len = p - host->data;

    return NGX_OK;
}


/*
 * Write the request. A caller may set Host, Connection and Content-Length, as
 * in lua-resty-http: their values replace the ones this would derive, so the
 * header is emitted once with what the caller asked for. conn_close reports
 * whether the request tells the peer the connection ends after it.
 */
static ngx_int_t
ngx_http_ffi_client_build_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_buf_t **buf, ngx_str_t *host,
    ngx_uint_t *conn_close, u_char *err, size_t *errlen)
{
    off_t                             announced;
    size_t                            len;
    u_char                           *p;
    ngx_str_t                         host_value, conn_value;
    ngx_uint_t                        i;
    ngx_http_ffi_client_ffi_header_t *h;

    if (req->method.len == 0 || req->method.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "method is required");
    }

    if (req->path.len == 0 || req->path.data == NULL || req->path.data[0] != '/')
    {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid path");
    }

    if (ngx_http_ffi_client_has_crlf(req->method.data, req->method.len)
        || ngx_http_ffi_client_has_crlf(req->path.data, req->path.len)
        || ngx_http_ffi_client_has_crlf(req->body.data, req->body.len))
    {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid request");
    }

    host_value = *host;

    if (req->keepalive) {
        ngx_str_set(&conn_value, "keep-alive");

    } else {
        ngx_str_set(&conn_value, "close");
    }

    len = 0;

    for (i = 0; i < req->headers_len; i++) {
        h = &req->headers[i];

        if (h->key.len == 0 || h->key.data == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid request header");
        }

        if (ngx_http_ffi_client_has_crlf(h->key.data, h->key.len)
            || ngx_http_ffi_client_has_crlf(h->value.data, h->value.len))
        {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid request header");
        }

        if (ngx_http_ffi_client_header_eq(&h->key, "Host")) {
            if (h->value.len) {
                host_value.data = h->value.data;
                host_value.len = h->value.len;
            }

        } else if (ngx_http_ffi_client_header_eq(&h->key, "Connection")) {
            if (h->value.len) {
                conn_value.data = h->value.data;
                conn_value.len = h->value.len;
            }

        } else if (ngx_http_ffi_client_header_eq(&h->key, "Content-Length")) {
            /* the body decides the framing: a length that disagrees with it
             * would leave the connection out of sync with the peer */
            announced = ngx_atoof(h->value.data, h->value.len);

            if (announced == NGX_ERROR
                || (size_t) announced != req->body.len)
            {
                return ngx_http_ffi_client_set_err(err, errlen,
                    "content-length does not match the body");
            }
        }

        if (ngx_http_ffi_client_header_is_reserved(&h->key)) {
            continue;
        }

        len += h->key.len + sizeof(": " CRLF) - 1 + h->value.len;
    }

    *conn_close = ngx_http_ffi_client_connection_is_close(&conn_value);

    len += req->method.len + 1 + req->path.len
           + sizeof(" HTTP/1.1" CRLF) - 1
           + sizeof("Host: " CRLF) - 1 + host_value.len
           + sizeof("Connection: " CRLF) - 1 + conn_value.len
           + sizeof("Content-Length: " CRLF) - 1 + NGX_SIZE_T_LEN
           + sizeof(CRLF) - 1
           + req->body.len;

    *buf = ngx_create_temp_buf(r->pool, len);
    if (*buf == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    p = (*buf)->last;
    p = ngx_cpymem(p, req->method.data, req->method.len);
    *p++ = ' ';
    p = ngx_cpymem(p, req->path.data, req->path.len);
    p = ngx_cpymem(p, " HTTP/1.1" CRLF, sizeof(" HTTP/1.1" CRLF) - 1);
    p = ngx_cpymem(p, "Host: ", sizeof("Host: ") - 1);
    p = ngx_cpymem(p, host_value.data, host_value.len);
    p = ngx_cpymem(p, CRLF, sizeof(CRLF) - 1);
    p = ngx_cpymem(p, "Connection: ", sizeof("Connection: ") - 1);
    p = ngx_cpymem(p, conn_value.data, conn_value.len);
    p = ngx_cpymem(p, CRLF, sizeof(CRLF) - 1);
    p = ngx_sprintf(p, "Content-Length: %uz" CRLF, req->body.len);

    for (i = 0; i < req->headers_len; i++) {
        h = &req->headers[i];

        if (ngx_http_ffi_client_header_is_reserved(&h->key)) {
            continue;
        }

        p = ngx_cpymem(p, h->key.data, h->key.len);
        p = ngx_cpymem(p, ": ", sizeof(": ") - 1);
        p = ngx_cpymem(p, h->value.data, h->value.len);
        p = ngx_cpymem(p, CRLF, sizeof(CRLF) - 1);
    }

    p = ngx_cpymem(p, CRLF, sizeof(CRLF) - 1);

    if (req->body.len != 0) {
        p = ngx_cpymem(p, req->body.data, req->body.len);
    }

    (*buf)->last = p;

    return NGX_OK;
}


/*
 * Set the peer address from the request host. Returns NGX_DECLINED when the
 * host is a name that has to go through the resolver.
 */
static ngx_int_t
ngx_http_ffi_client_parse_peer(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen)
{
    u_char      *text, *p;
    size_t       len;
    ngx_int_t    rc;
    ngx_addr_t   addr;
    ngx_str_t    host;
    ngx_uint_t   ipv6;

    host.data = req->host.data;
    host.len = req->host.len;
    ipv6 = memchr(host.data, ':', host.len) != NULL;

    len = host.len + NGX_INT_T_LEN + 4;
    text = ngx_pnalloc(r->pool, len);
    if (text == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    if (ipv6) {
        p = ngx_snprintf(text, len, "[%V]:%ui", &host, req->port);

    } else {
        p = ngx_snprintf(text, len, "%V:%ui", &host, req->port);
    }

    op->port = (in_port_t) req->port;
    op->peer_name.data = text;
    op->peer_name.len = p - text;
    op->peer.name = &op->peer_name;

    ngx_memzero(&addr, sizeof(ngx_addr_t));

    rc = ngx_parse_addr_port(r->pool, &addr, text, p - text);

    if (rc == NGX_OK) {
        op->peer.sockaddr = addr.sockaddr;
        op->peer.socklen = addr.socklen;
        return NGX_OK;
    }

    if (rc != NGX_DECLINED) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    /* a name: keep a NUL-terminated copy for the resolver, which needs it to
     * outlive this call */
    op->resolve_name.data = ngx_pnalloc(r->pool, host.len + 1);
    if (op->resolve_name.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    ngx_memcpy(op->resolve_name.data, host.data, host.len);
    op->resolve_name.data[host.len] = '\0';
    op->resolve_name.len = host.len;

    return NGX_DECLINED;
}


/*
 * Start resolving the host through the nginx resolver, matching the cosocket's
 * connect-time semantics. Returns NGX_OK when the resolver answered inline from
 * its cache, NGX_AGAIN once the answer is pending, or NGX_ERROR.
 */
static ngx_int_t
ngx_http_ffi_client_resolve(ngx_http_ffi_client_op_t *op)
{
    ngx_int_t                  rc;
    ngx_resolver_ctx_t        *rctx, temp;
    ngx_http_core_loc_conf_t  *clcf;

    clcf = ngx_http_get_module_loc_conf(op->r, ngx_http_core_module);

    temp.name = op->resolve_name;

    rctx = ngx_resolve_start(clcf->resolver, &temp);
    if (rctx == NULL) {
        return ngx_http_ffi_client_set_op_err(op,
                                              "failed to start the resolver");
    }

    if (rctx == NGX_NO_RESOLVER) {
        op->errlen = ngx_snprintf(op->err, sizeof(op->err),
                                  "no resolver defined to resolve \"%V\"",
                                  &op->resolve_name) - op->err;
        return NGX_ERROR;
    }

    rctx->name = op->resolve_name;
    rctx->handler = ngx_http_ffi_client_resolve_handler;
    rctx->data = op;
    rctx->timeout = clcf->resolver_timeout;

    op->resolve_ctx = rctx;

    /* the resolver now holds a pointer to op: cancel it if the coroutine dies */
    ngx_http_ffi_client_set_cleanup(op);

    /* a cached name is answered inline: let the handler only record the result
     * so the connect is driven from here, before the coroutine has yielded */
    op->resolve_inline = 1;
    rc = ngx_resolve_name(rctx);
    op->resolve_inline = 0;

    if (rc != NGX_OK) {
        op->resolve_ctx = NULL;
        ngx_http_ffi_client_clear_cleanup(op);
        op->errlen = ngx_snprintf(op->err, sizeof(op->err),
                                  "%V could not be resolved",
                                  &op->resolve_name) - op->err;
        return NGX_ERROR;
    }

    if (op->resolve_ctx != NULL) {
        return NGX_AGAIN;
    }

    return op->resolve_failed ? NGX_ERROR : NGX_OK;
}


/* Called when the resolver answers (or fails, or times out). */
static void
ngx_http_ffi_client_resolve_handler(ngx_resolver_ctx_t *ctx)
{
    u_char                    *p;
    socklen_t                  socklen;
    ngx_uint_t                 i;
    struct sockaddr           *sockaddr;
    ngx_http_ffi_client_op_t  *op;

    op = ctx->data;

    if (ctx->state || ctx->naddrs == 0) {
        op->errlen = ngx_snprintf(op->err, sizeof(op->err),
                                  "%V could not be resolved (%i: %s)",
                                  &ctx->name, (ngx_int_t) ctx->state,
                                  ngx_resolver_strerror(ctx->state)) - op->err;
        goto failed;
    }

    /* pick one of the answers at random, as the cosocket does */
    i = ctx->naddrs == 1 ? 0 : (ngx_uint_t) ngx_random() % ctx->naddrs;

    socklen = ctx->addrs[i].socklen;
    sockaddr = (struct sockaddr *) &op->sockaddr;

    ngx_memcpy(sockaddr, ctx->addrs[i].sockaddr, socklen);
    ngx_inet_set_port(sockaddr, op->port);

    p = ngx_pnalloc(op->r->pool, NGX_SOCKADDR_STRLEN);
    if (p == NULL) {
        ngx_http_ffi_client_set_op_err(op, "no memory");
        goto failed;
    }

    op->peer_name.data = p;
    op->peer_name.len = ngx_sock_ntop(sockaddr, socklen, p,
                                      NGX_SOCKADDR_STRLEN, 1);
    op->peer.sockaddr = sockaddr;
    op->peer.socklen = socklen;

    ngx_resolve_name_done(ctx);
    op->resolve_ctx = NULL;

    if (op->resolve_inline) {
        return;
    }

    if (ngx_http_ffi_client_do_connect(op) == NGX_ERROR) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
    }

    return;

failed:

    ngx_resolve_name_done(ctx);
    op->resolve_ctx = NULL;
    op->resolve_failed = 1;

    if (op->resolve_inline) {
        return;
    }

    ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
}


/*
 * Register the coroutine cleanup once: it cancels a pending resolve and closes
 * the connection if the coroutine goes away mid-flight.
 */
static void
ngx_http_ffi_client_set_cleanup(ngx_http_ffi_client_op_t *op)
{
    if (op->cleanup_set) {
        return;
    }

    ngx_http_lua_cleanup_co_ctx_pending_operation(op->coctx);
    ngx_http_lua_set_co_ctx_cleanup(op->coctx, ngx_http_ffi_client_cleanup, op);
    op->cleanup_set = 1;
}


static void
ngx_http_ffi_client_clear_cleanup(ngx_http_ffi_client_op_t *op)
{
    if (!op->cleanup_set) {
        return;
    }

    ngx_http_lua_set_co_ctx_cleanup(op->coctx, NULL, NULL);
    op->cleanup_set = 0;
}


/* Hand an error raised on the op back to a caller that has not yielded yet. */
static ngx_int_t
ngx_http_ffi_client_export_err(ngx_http_ffi_client_op_t *op, u_char *err,
    size_t *errlen)
{
    /* the op is done and never resumes, so it must not outlive this call as a
     * pending cleanup */
    ngx_http_ffi_client_clear_cleanup(op);

    if (op->errlen == 0) {
        ngx_http_ffi_client_set_op_err(op, "request failed");
    }

    if (err != NULL && errlen != NULL && *errlen > 0) {
        *errlen = ngx_snprintf(err, *errlen, "%*s", op->errlen, op->err) - err;
    }

    return NGX_ERROR;
}


static void
ngx_http_ffi_client_write_handler(ngx_event_t *wev)
{
    ngx_connection_t         *c;
    ngx_http_ffi_client_op_t *op;

    c = wev->data;
    op = c->data;

    if (op == NULL || op->resumed) {
        return;
    }

    /* a stateful connection the object owns but has parked nothing on */
    if (op->stateful && op->pending == NGX_HTTP_FFI_CLIENT_PENDING_NONE) {
        return;
    }

    /* "timeout" is what the cosocket reports, and what lua-resty-http callers
     * (ai-transport among them) match on to answer 504 */
    if (wev->timedout) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "timeout");
        return;
    }

    if (wev->error) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "write event error");
        return;
    }

    if (op->state == NGX_HTTP_FFI_CLIENT_CONNECTING) {
        /* NULL keeps the errno text check_connect wrote */
        if (ngx_http_ffi_client_check_connect(op) != NGX_OK) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
            return;
        }

        if (wev->timer_set) {
            ngx_del_timer(wev);
        }

#if (NGX_SSL)
        if (op->ssl && op->peer.connection->ssl == NULL) {
            (void) ngx_http_ffi_client_ssl_init_connection(op);
            return;
        }
#endif

        /* a stateful connect has no request to send: hand the connection back */
        if (op->pending == NGX_HTTP_FFI_CLIENT_PENDING_CONNECT) {
            ngx_http_ffi_client_stateful_connected(op);
            return;
        }

        op->state = NGX_HTTP_FFI_CLIENT_WRITING;
    }

    if (ngx_http_ffi_client_do_write(op) != NGX_OK) {
        return;
    }
}


static void
ngx_http_ffi_client_read_handler(ngx_event_t *rev)
{
    ngx_connection_t         *c;
    ngx_http_ffi_client_op_t *op;

    c = rev->data;
    op = c->data;

    if (op == NULL || op->resumed) {
        return;
    }

    /* a stateful connection the object owns but has parked nothing on */
    if (op->stateful && op->pending == NGX_HTTP_FFI_CLIENT_PENDING_NONE) {
        return;
    }

    if (rev->timedout) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "timeout");
        return;
    }

    if (rev->error) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "read event error");
        return;
    }

    (void) ngx_http_ffi_client_do_read(op);
}


/*
 * Report the pending socket error, if any. The errno text is what the cosocket
 * hands back ("connection refused" and friends), so callers keep the message
 * this writes instead of a generic one.
 */
static ngx_int_t
ngx_http_ffi_client_check_connect(ngx_http_ffi_client_op_t *op)
{
    int               err;
    socklen_t         len;
    ngx_connection_t *c;

    c = op->peer.connection;
    err = 0;
    len = sizeof(int);

    if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, (void *) &err, &len) == -1) {
        err = ngx_errno;
    }

    if (err) {
        (void) ngx_connection_error(c, err, "connect() failed");

        return ngx_http_ffi_client_set_op_errno(op, err, "connect failed");
    }

    return NGX_OK;
}


static ngx_int_t
ngx_http_ffi_client_prepare_connection(ngx_http_ffi_client_op_t *op)
{
    ngx_connection_t *c;

    c = op->peer.connection;

    c->data = op;
    c->write->handler = ngx_http_ffi_client_write_handler;
    c->read->handler = ngx_http_ffi_client_read_handler;
    c->log = op->r->connection->log;
    c->read->log = c->log;
    c->write->log = c->log;
    c->sendfile &= op->r->connection->sendfile;

    if (c->pool == NULL) {
        c->pool = ngx_create_pool(128, c->log);
        if (c->pool == NULL) {
            return NGX_ERROR;
        }
    }

    c->pool->log = c->log;

    return NGX_OK;
}


static ngx_int_t
ngx_http_ffi_client_do_write(ngx_http_ffi_client_op_t *op)
{
    ssize_t           n;
    ngx_connection_t *c;

    c = op->peer.connection;

    while (op->request->pos < op->request->last) {
        n = c->send(c, op->request->pos,
                    op->request->last - op->request->pos);

        if (n > 0) {
            op->request->pos += n;
            continue;
        }

        if (n == NGX_AGAIN) {
            return ngx_http_ffi_client_handle_write_wait(op);
        }

        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to send request");
        return NGX_ERROR;
    }

    if (c->write->timer_set) {
        ngx_del_timer(c->write);
    }

    if (ngx_http_ffi_client_check_connect(op) != NGX_OK) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
        return NGX_ERROR;
    }

    op->state = NGX_HTTP_FFI_CLIENT_READING;

    return ngx_http_ffi_client_do_read(op);
}


static ngx_int_t
ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op)
{
    ssize_t           n;
    ngx_int_t         rc;
    ngx_connection_t *c;
    u_char            buf[NGX_HTTP_FFI_CLIENT_READ_BUF_SIZE];

    if (op->stateful && !op->preread) {
        return ngx_http_ffi_client_do_stream(op);
    }

    c = op->peer.connection;

    for ( ;; ) {
        n = c->recv(c, buf, sizeof(buf));

        if (n > 0) {
            op->received = 1;
            op->errlen = sizeof(op->err);
            rc = ngx_http_ffi_client_response_parse(op->r->pool, &op->parser,
                                                    buf, n, op->err,
                                                    &op->errlen);
            if (rc != NGX_OK) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            if (op->parser.done) {
                op->errlen = sizeof(op->err);
                rc = ngx_http_ffi_client_response_to_ffi(op->r->pool,
                                                         &op->parser,
                                                         op->ffi_resp,
                                                         op->err,
                                                         &op->errlen);
                if (rc != NGX_OK) {
                    ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                    return NGX_ERROR;
                }

                op->ffi_resp->reused = op->reused;
                ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
                return NGX_OK;
            }

            continue;
        }

        if (n == NGX_AGAIN) {
            return ngx_http_ffi_client_handle_read_wait(op);
        }

        if (n == 0) {
            /* a message framed by the connection close ends here; anything else
             * is truncated and response_eof says so */
            op->errlen = sizeof(op->err);

            if (ngx_http_ffi_client_response_eof(op->r->pool, &op->parser,
                                                 op->err, &op->errlen)
                != NGX_OK)
            {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            op->errlen = sizeof(op->err);
            rc = ngx_http_ffi_client_response_to_ffi(op->r->pool, &op->parser,
                                                     op->ffi_resp, op->err,
                                                     &op->errlen);
            if (rc != NGX_OK) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            /* the peer is gone: this connection can never go back to the pool */
            op->parser.connection_close = 1;
            op->ffi_resp->reused = op->reused;
            ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
            return NGX_OK;
        }

        if (!op->received) {
            /*
             * Nothing ever arrived, so it is the connect that failed, not the
             * read. A refused peer wakes the read event first on Linux and
             * lands here with SO_ERROR already consumed, so the errno the recv
             * left behind is what names it.
             */
            (void) ngx_http_ffi_client_set_op_errno(op, ngx_socket_errno,
                                                    "connect failed");
            ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
            return NGX_ERROR;
        }

        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to read response");
        return NGX_ERROR;
    }
}


/*
 * Produce the next body slice out of what the parser has already been fed.
 * NGX_OK when chunk was filled, NGX_AGAIN when the socket has to be read again,
 * NGX_ERROR on a parse failure with err written.
 */
static ngx_int_t
ngx_http_ffi_client_next_chunk(ngx_http_ffi_client_op_t *op,
    ngx_http_ffi_client_ffi_chunk_t *chunk, u_char *err, size_t *errlen)
{
    ngx_str_t  span;

    for ( ;; ) {
        if (op->parser.chunk_ready) {
            ngx_http_ffi_client_response_take_chunk(&op->parser, &span);

            /* an empty slice is not an answer: keep going, an empty one only
             * ever means EOF */
            if (span.len == 0 && !op->parser.done) {
                continue;
            }

            chunk->data = span.len ? span.data : (u_char *) "";
            chunk->len = span.len;
            chunk->eof = op->parser.done ? 1 : 0;

            return NGX_OK;
        }

        if (op->parser.done) {
            chunk->data = (u_char *) "";
            chunk->len = 0;
            chunk->eof = 1;

            return NGX_OK;
        }

        if (ngx_http_ffi_client_response_pending(&op->parser) == 0) {
            return NGX_AGAIN;
        }

        /* bytes are still sitting behind the last pause: parse them before
         * going back to the socket */
        if (ngx_http_ffi_client_response_parse(op->r->pool, &op->parser, NULL,
                                               0, err, errlen)
            != NGX_OK)
        {
            return NGX_ERROR;
        }
    }
}


/*
 * Incremental reader for the stateful object: resume Lua once the headers are
 * in, then hand the body out one parser span at a time. Everything already in
 * the read buffer is parsed before the socket is touched again, and the loop
 * keeps draining while the connection reports readable, so bytes buffered
 * inside the TLS layer are never stranded.
 */
static ngx_int_t
ngx_http_ffi_client_do_stream(ngx_http_ffi_client_op_t *op)
{
    ssize_t            n;
    ngx_int_t          rc;
    ngx_connection_t  *c;

    c = op->peer.connection;

    for ( ;; ) {

        if (op->pending == NGX_HTTP_FFI_CLIENT_PENDING_REQUEST) {
            if (op->parser.headers_done) {
                op->errlen = sizeof(op->err);

                if (ngx_http_ffi_client_response_headers_to_ffi(&op->parser,
                        op->ffi_resp, op->err, &op->errlen)
                    != NGX_OK)
                {
                    ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                    return NGX_ERROR;
                }

                op->ffi_resp->reused = op->reused;
                ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
                return NGX_OK;
            }

        } else {
            op->errlen = sizeof(op->err);
            rc = ngx_http_ffi_client_next_chunk(op, op->ffi_chunk, op->err,
                                                &op->errlen);

            if (rc == NGX_ERROR) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            if (rc == NGX_OK) {
                ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
                return NGX_OK;
            }
        }

        if (ngx_http_ffi_client_response_pending(&op->parser)) {
            op->errlen = sizeof(op->err);

            if (ngx_http_ffi_client_response_parse(op->r->pool, &op->parser,
                                                   NULL, 0, op->err,
                                                   &op->errlen)
                != NGX_OK)
            {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            continue;
        }

        n = c->recv(c, op->rbuf, op->rbuf_size);

        if (n > 0) {
            op->received = 1;
            op->errlen = sizeof(op->err);

            if (ngx_http_ffi_client_response_parse(op->r->pool, &op->parser,
                                                   op->rbuf, n, op->err,
                                                   &op->errlen)
                != NGX_OK)
            {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            continue;
        }

        if (n == NGX_AGAIN) {
            return ngx_http_ffi_client_handle_read_wait(op);
        }

        if (n == 0) {
            /* a message framed by the connection close ends here */
            op->errlen = sizeof(op->err);

            if (ngx_http_ffi_client_response_eof(op->r->pool, &op->parser,
                                                 op->err, &op->errlen)
                != NGX_OK)
            {
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            continue;
        }

        if (!op->received) {
            /*
             * Nothing ever arrived, so it is the connect that failed, not the
             * read. A refused peer wakes the read event first on Linux and
             * lands here with SO_ERROR already consumed, so the errno the recv
             * left behind is what names it.
             */
            (void) ngx_http_ffi_client_set_op_errno(op, ngx_socket_errno,
                                                    "connect failed");
            ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
            return NGX_ERROR;
        }

        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to read response");
        return NGX_ERROR;
    }
}


static ngx_int_t
ngx_http_ffi_client_handle_write_wait(ngx_http_ffi_client_op_t *op)
{
    ngx_connection_t *c;

    c = op->peer.connection;

    if (!c->write->timer_set) {
        ngx_add_timer(c->write, op->send_timeout);
    }

    if (ngx_handle_write_event(c->write, 0) != NGX_OK) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                     "failed to handle write event");
        return NGX_ERROR;
    }

    return NGX_AGAIN;
}


static ngx_int_t
ngx_http_ffi_client_handle_read_wait(ngx_http_ffi_client_op_t *op)
{
    ngx_connection_t *c;

    c = op->peer.connection;

    if (!c->read->timer_set) {
        ngx_add_timer(c->read, op->read_timeout);
    }

    if (ngx_handle_read_event(c->read, 0) != NGX_OK) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                     "failed to handle read event");
        return NGX_ERROR;
    }

    return NGX_AGAIN;
}


#if (NGX_SSL)

/*
 * Lazily build one client SSL_CTX per distinct trust config, cached on
 * main_conf. `ca` is an optional trusted-CA file path (empty = system store
 * only). Returns NULL on failure without caching a half-built context.
 */
static ngx_ssl_t *
ngx_http_ffi_client_ssl_ctx(ngx_http_ffi_client_main_conf_t *fmcf,
    ngx_str_t *ca, ngx_log_t *log)
{
    u_char                         *path;
    ngx_ssl_t                      *ssl;
    ngx_pool_cleanup_t             *cln;
    ngx_http_ffi_client_ssl_ctx_t  *node;

    for (node = fmcf->ssl_ctxs; node != NULL; node = node->next) {
        /* guard memcmp: NULL pointers with len 0 are UB */
        if (node->ca.len == ca->len
            && (ca->len == 0
                || ngx_memcmp(node->ca.data, ca->data, ca->len) == 0))
        {
            return node->ssl;
        }
    }

    ssl = ngx_pcalloc(ngx_cycle->pool, sizeof(ngx_ssl_t));
    if (ssl == NULL) {
        return NULL;
    }

    ssl->log = ngx_cycle->log;

    if (ngx_ssl_create(ssl, NGX_SSL_TLSv1_2 | NGX_SSL_TLSv1_3, NULL) != NGX_OK) {
        return NULL;
    }

    /* verify mode stays NONE so the handshake completes and we inspect the
     * result ourselves. An unusable trust store is a hard init failure: don't
     * cache a context that would fail every verify-on request. */
    if (SSL_CTX_set_default_verify_paths(ssl->ctx) == 0) {
        ngx_ssl_error(NGX_LOG_ALERT, log, 0,
                      "SSL_CTX_set_default_verify_paths() failed");
        ngx_ssl_cleanup_ctx(ssl);
        return NULL;
    }

    if (ca->len) {
        path = ngx_pnalloc(ngx_cycle->pool, ca->len + 1);
        if (path == NULL) {
            ngx_ssl_cleanup_ctx(ssl);
            return NULL;
        }

        ngx_memcpy(path, ca->data, ca->len);
        path[ca->len] = '\0';

        if (SSL_CTX_load_verify_locations(ssl->ctx, (char *) path, NULL) == 0) {
            ngx_ssl_error(NGX_LOG_ALERT, log, 0,
                          "SSL_CTX_load_verify_locations(\"%s\") failed", path);
            ngx_ssl_cleanup_ctx(ssl);
            return NULL;
        }
    }

    SSL_CTX_set_verify_depth(ssl->ctx, 100);

    /* build the cache node before registering cleanup so an alloc failure
     * frees the context instead of orphaning it until worker exit */
    node = ngx_pcalloc(ngx_cycle->pool, sizeof(ngx_http_ffi_client_ssl_ctx_t));
    if (node == NULL) {
        ngx_ssl_cleanup_ctx(ssl);
        return NULL;
    }

    node->ssl = ssl;
    node->ca.len = ca->len;
    if (ca->len) {
        node->ca.data = ngx_pnalloc(ngx_cycle->pool, ca->len);
        if (node->ca.data == NULL) {
            ngx_ssl_cleanup_ctx(ssl);
            return NULL;
        }
        ngx_memcpy(node->ca.data, ca->data, ca->len);
    }

    cln = ngx_pool_cleanup_add(ngx_cycle->pool, 0);
    if (cln == NULL) {
        ngx_ssl_cleanup_ctx(ssl);
        return NULL;
    }

    cln->handler = ngx_ssl_cleanup_ctx;
    cln->data = ssl;

    node->next = fmcf->ssl_ctxs;
    fmcf->ssl_ctxs = node;

    return ssl;
}


/* true if name is an IPv4/IPv6 literal rather than a DNS name */
static ngx_uint_t
ngx_http_ffi_client_name_is_ip(ngx_str_t *name)
{
    if (ngx_inet_addr(name->data, name->len) != INADDR_NONE) {
        return 1;
    }

#if (NGX_HAVE_INET6)
    {
        u_char  buf[16];

        if (ngx_inet6_addr(name->data, name->len, buf) == NGX_OK) {
            return 1;
        }
    }
#endif

    return 0;
}


/*
 * Match the peer cert against the target name. ngx_ssl_check_host covers DNS
 * SANs only, so IP literals are matched against iPAddress SANs directly.
 */
static ngx_int_t
ngx_http_ffi_client_ssl_check_identity(ngx_connection_t *c, ngx_str_t *name)
{
    u_char    *ip;
    X509      *cert;
    ngx_int_t  rc;

    if (!ngx_http_ffi_client_name_is_ip(name)) {
        return ngx_ssl_check_host(c, name);
    }

    cert = SSL_get_peer_certificate(c->ssl->connection);
    if (cert == NULL) {
        return NGX_ERROR;
    }

    ip = ngx_pnalloc(c->pool, name->len + 1);
    if (ip == NULL) {
        X509_free(cert);
        return NGX_ERROR;
    }

    ngx_memcpy(ip, name->data, name->len);
    ip[name->len] = '\0';

    rc = (X509_check_ip_asc(cert, (char *) ip, 0) == 1) ? NGX_OK : NGX_ERROR;

    X509_free(cert);

    return rc;
}


/* SNI for DNS names only; IP literals are not valid SNI hostnames. */
static ngx_int_t
ngx_http_ffi_client_ssl_set_sni(ngx_connection_t *c, ngx_str_t *name)
{
#ifdef SSL_CTRL_SET_TLSEXT_HOSTNAME
    u_char  *p;

    if (ngx_http_ffi_client_name_is_ip(name)) {
        return NGX_OK;
    }

    p = ngx_pnalloc(c->pool, name->len + 1);
    if (p == NULL) {
        return NGX_ERROR;
    }

    ngx_memcpy(p, name->data, name->len);
    p[name->len] = '\0';

    if (SSL_set_tlsext_host_name(c->ssl->connection, (char *) p) == 0) {
        ngx_ssl_error(NGX_LOG_ERR, c->log, 0,
                      "SSL_set_tlsext_host_name(\"%s\") failed", p);
        return NGX_ERROR;
    }
#endif

    return NGX_OK;
}


/* Start the TLS handshake once TCP is connected. */
static ngx_int_t
ngx_http_ffi_client_ssl_init_connection(ngx_http_ffi_client_op_t *op)
{
    ngx_int_t                         rc;
    ngx_ssl_t                        *ssl;
    ngx_connection_t                 *c;
    ngx_http_ffi_client_main_conf_t  *fmcf;

    c = op->peer.connection;

    fmcf = ngx_http_get_module_main_conf(op->r, ngx_http_ffi_client_module);

    ssl = ngx_http_ffi_client_ssl_ctx(fmcf, &op->ssl_trusted_certificate,
                                      c->log);
    if (ssl == NULL) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to init TLS");
        return NGX_ERROR;
    }

    if (ngx_ssl_create_connection(ssl, c, NGX_SSL_BUFFER | NGX_SSL_CLIENT)
        != NGX_OK)
    {
        ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                     "failed to create TLS connection");
        return NGX_ERROR;
    }

    if (op->ssl_server_name.len
        && ngx_http_ffi_client_ssl_set_sni(c, &op->ssl_server_name) != NGX_OK)
    {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to set TLS SNI");
        return NGX_ERROR;
    }

    op->state = NGX_HTTP_FFI_CLIENT_HANDSHAKING;

    rc = ngx_ssl_handshake(c);

    if (rc == NGX_AGAIN) {
        if (!c->read->timer_set) {
            ngx_add_timer(c->read, op->connect_timeout);
        }

        c->ssl->handler = ngx_http_ffi_client_ssl_handshake_handler;
        return NGX_AGAIN;
    }

    ngx_http_ffi_client_ssl_handshake_handler(c);
    return NGX_OK;
}


/* Called when the handshake settles (done, failed, or timed out). */
static void
ngx_http_ffi_client_ssl_handshake_handler(ngx_connection_t *c)
{
    long                       verify;
    ngx_http_ffi_client_op_t  *op;

    op = c->data;

    if (!c->ssl->handshaked) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR,
            (c->read->timedout || c->write->timedout)
            ? "timeout" : "TLS handshake failed");
        return;
    }

    if (op->ssl_verify) {
        /* verifying the chain without an identity check accepts a cert for any
         * trusted host, so a server name is mandatory here. */
        if (op->ssl_server_name.len == 0) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                "TLS verification requires a server name");
            return;
        }

        verify = SSL_get_verify_result(c->ssl->connection);

        if (verify != X509_V_OK) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                         "TLS certificate verify failed");
            return;
        }

        if (ngx_http_ffi_client_ssl_check_identity(c, &op->ssl_server_name)
            != NGX_OK)
        {
            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                         "TLS certificate host mismatch");
            return;
        }
    }

    if (c->read->timer_set) {
        ngx_del_timer(c->read);
    }

    if (c->write->timer_set) {
        ngx_del_timer(c->write);
    }

    /* ngx_ssl_handshake swapped c->recv/c->send to the TLS variants; restore
     * our own event handlers and send the request. */
    c->read->handler = ngx_http_ffi_client_read_handler;
    c->write->handler = ngx_http_ffi_client_write_handler;

    /* a stateful connect ends at the handshake: there is no request yet */
    if (op->pending == NGX_HTTP_FFI_CLIENT_PENDING_CONNECT) {
        ngx_http_ffi_client_stateful_connected(op);
        return;
    }

    op->state = NGX_HTTP_FFI_CLIENT_WRITING;

    (void) ngx_http_ffi_client_do_write(op);
}

#endif


/* lua-nginx-module hands the co ctx itself to the cleanup, not the data */
static void
ngx_http_ffi_client_cleanup(void *data)
{
    ngx_http_lua_co_ctx_t    *coctx = data;
    ngx_http_ffi_client_op_t *op;

    op = ngx_http_lua_get_co_ctx_data(coctx);

    if (op == NULL || op->resumed) {
        return;
    }

    op->resumed = 1;
    op->cleanup_set = 0;
    op->state = NGX_HTTP_FFI_CLIENT_FAILED;

    if (op->resolve_ctx != NULL) {
        ngx_resolve_name_done(op->resolve_ctx);
        op->resolve_ctx = NULL;
    }

    if (op->stateful) {
        op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
        op->conn_broken = 1;
        op->connected = 0;
    }

    ngx_http_ffi_client_close(op);
}


/*
 * Last resort for the stateful object: an idle connection it still owns when
 * the request ends (the Lua code never called set_keepalive or close) would
 * otherwise stay open until the worker exits.
 */
static void
ngx_http_ffi_client_op_pool_cleanup(void *data)
{
    ngx_http_ffi_client_op_t  *op = data;

    op->connected = 0;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;

    ngx_http_ffi_client_close(op);
}


static void
ngx_http_ffi_client_close(ngx_http_ffi_client_op_t *op)
{
    ngx_http_ffi_client_keepalive_close_active(op);
}


static void
ngx_http_ffi_client_finalize(ngx_http_ffi_client_op_t *op, ngx_int_t rc,
    const char *msg)
{
    lua_State        *co;
    ngx_connection_t *c;

    if (op->resumed) {
        return;
    }

    op->resumed = 1;
    op->state = rc == NGX_OK ? NGX_HTTP_FFI_CLIENT_DONE
                             : NGX_HTTP_FFI_CLIENT_FAILED;

    /* drop the cleanup before resuming: the resume helper takes over the co ctx
     * data slot that the cleanup reads op from */
    ngx_http_ffi_client_clear_cleanup(op);

    if (rc != NGX_OK && msg != NULL) {
        ngx_http_ffi_client_set_op_err(op, msg);
    }

    /*
     * The stateful object owns its connection across calls, so completion here
     * only ends one call on it: success leaves the connection open for the next
     * request (set_keepalive or close decides its fate later), failure closes it
     * as broken.
     */
    if (op->stateful) {
        op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
        op->ffi_resp = NULL;
        op->ffi_chunk = NULL;

        c = op->peer.connection;

        if (c != NULL) {
            if (c->read->timer_set) {
                ngx_del_timer(c->read);
            }

            if (c->write->timer_set) {
                ngx_del_timer(c->write);
            }
        }

        co = ngx_http_lua_get_co_ctx_vm(op->coctx);

        if (rc == NGX_OK) {
            lua_pushboolean(co, 1);
            ngx_http_lua_set_cur_co_ctx(op->r, op->coctx);
            ngx_http_lua_co_ctx_resume_helper(op->coctx, 1);
            return;
        }

        op->conn_broken = 1;
        op->connected = 0;
        ngx_http_ffi_client_close(op);

        if (op->errlen == 0) {
            ngx_http_ffi_client_set_op_err(op, "request failed");
        }

        lua_pushnil(co);
        lua_pushlstring(co, (const char *) op->err, op->errlen);
        ngx_http_lua_set_cur_co_ctx(op->r, op->coctx);
        ngx_http_lua_co_ctx_resume_helper(op->coctx, 2);
        return;
    }

    if (rc == NGX_OK
        && op->keepalive
        && !op->parser.connection_close
        && ngx_http_ffi_client_keepalive_save(op) == NGX_OK)
    {
        /* saved for reuse */

    } else {
        ngx_http_ffi_client_close(op);
    }

    co = ngx_http_lua_get_co_ctx_vm(op->coctx);

    if (rc == NGX_OK) {
        lua_pushboolean(co, 1);
        ngx_http_lua_set_cur_co_ctx(op->r, op->coctx);
        ngx_http_lua_co_ctx_resume_helper(op->coctx, 1);
        return;
    }

    if (op->errlen == 0) {
        ngx_http_ffi_client_set_op_err(op, "request failed");
    }

    lua_pushnil(co);
    lua_pushlstring(co, (const char *) op->err, op->errlen);
    ngx_http_lua_set_cur_co_ctx(op->r, op->coctx);
    ngx_http_lua_co_ctx_resume_helper(op->coctx, 2);
}


/*
 * Wipe everything that belongs to one connection, keeping what belongs to the
 * Lua object: the request it was created on, its timeouts and its read buffer.
 */
static void
ngx_http_ffi_client_op_reset(ngx_http_ffi_client_op_t *op)
{
    u_char              *rbuf;
    size_t               rbuf_size;
    ngx_msec_t           connect_timeout, send_timeout, read_timeout;
    ngx_http_request_t  *r;

    ngx_http_ffi_client_clear_cleanup(op);

    /* a no-op unless a previous connect left something half-open */
    ngx_http_ffi_client_close(op);

    r = op->r;
    rbuf = op->rbuf;
    rbuf_size = op->rbuf_size;
    connect_timeout = op->connect_timeout;
    send_timeout = op->send_timeout;
    read_timeout = op->read_timeout;

    ngx_memzero(op, sizeof(ngx_http_ffi_client_op_t));

    op->r = r;
    op->stateful = 1;
    op->rbuf = rbuf;
    op->rbuf_size = rbuf_size;
    op->connect_timeout = connect_timeout;
    op->send_timeout = send_timeout;
    op->read_timeout = read_timeout;
}


/* Resume a stateful connect: the connection is up, no request has been sent. */
static void
ngx_http_ffi_client_stateful_connected(ngx_http_ffi_client_op_t *op)
{
    lua_State  *co;

    if (op->resumed) {
        return;
    }

    op->resumed = 1;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
    op->connected = 1;
    op->state = NGX_HTTP_FFI_CLIENT_DONE;

    ngx_http_ffi_client_clear_cleanup(op);

    co = ngx_http_lua_get_co_ctx_vm(op->coctx);
    lua_pushboolean(co, 1);
    ngx_http_lua_set_cur_co_ctx(op->r, op->coctx);
    ngx_http_lua_co_ctx_resume_helper(op->coctx, 1);
}


ngx_http_ffi_client_op_t *
ngx_http_ffi_client_ffi_new(ngx_http_request_t *r)
{
    ngx_pool_cleanup_t        *cln;
    ngx_http_ffi_client_op_t  *op;

    if (r == NULL) {
        return NULL;
    }

    op = ngx_pcalloc(r->pool, sizeof(ngx_http_ffi_client_op_t));
    if (op == NULL) {
        return NULL;
    }

    cln = ngx_pool_cleanup_add(r->pool, 0);
    if (cln == NULL) {
        return NULL;
    }

    cln->handler = ngx_http_ffi_client_op_pool_cleanup;
    cln->data = op;

    op->r = r;
    op->stateful = 1;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
    op->connect_timeout = 60000;
    op->send_timeout = 60000;
    op->read_timeout = 60000;

    return op;
}


void
ngx_http_ffi_client_ffi_set_timeouts(ngx_http_ffi_client_op_t *op,
    ngx_msec_t connect_timeout, ngx_msec_t send_timeout,
    ngx_msec_t read_timeout)
{
    if (op == NULL) {
        return;
    }

    if (connect_timeout > 0) {
        op->connect_timeout = connect_timeout;
    }

    if (send_timeout > 0) {
        op->send_timeout = send_timeout;
    }

    if (read_timeout > 0) {
        op->read_timeout = read_timeout;
    }
}


/*
 * Open (or take from the pool) the connection the object owns. Returns NGX_OK
 * when it is usable right away, NGX_AGAIN once the coroutine has to wait for
 * the connect or the TLS handshake, NGX_ERROR with err set.
 */
ngx_int_t
ngx_http_ffi_client_ffi_connect(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_connect_t *cp,
    u_char *err, size_t *errlen)
{
    ngx_int_t                      rc;
    ngx_uint_t                     is_https;
    ngx_http_ffi_client_ffi_req_t  req;

    if (op == NULL || cp == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad connect");
    }

    if (op->connected) {
        return ngx_http_ffi_client_set_err(err, errlen, "already connected");
    }

    /* the object may be reconnected after set_keepalive or close, so nothing
     * from the previous connection may leak into the new one */
    ngx_http_ffi_client_op_reset(op);

    is_https = cp->scheme.data != NULL
               && cp->scheme.len == sizeof("https") - 1
               && ngx_strncmp(cp->scheme.data, "https", sizeof("https") - 1)
                  == 0;

    if (cp->scheme.data == NULL
        || !(is_https
             || (cp->scheme.len == sizeof("http") - 1
                 && ngx_strncmp(cp->scheme.data, "http",
                                sizeof("http") - 1) == 0)))
    {
        return ngx_http_ffi_client_set_err(err, errlen, "unsupported scheme");
    }

    /* scheme and the ssl flag must agree: no plaintext on an https URL */
    if ((is_https != 0) != (cp->ssl != 0)) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "scheme and ssl flag mismatch");
    }

    if (cp->port == 0 || cp->port > 65535) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad port");
    }

    op->coctx = ngx_http_lua_get_cur_co_ctx(r);
    if (op->coctx == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "no coroutine context found");
    }

    if (cp->ssl) {
#if (NGX_SSL)
        op->ssl = 1;
        op->ssl_verify = cp->ssl_verify ? 1 : 0;

        if (cp->ssl_server_name.len) {
            if (cp->ssl_server_name.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "invalid TLS server name");
            }

            op->ssl_server_name.len = cp->ssl_server_name.len;
            op->ssl_server_name.data = ngx_pnalloc(r->pool,
                                                   cp->ssl_server_name.len);
            if (op->ssl_server_name.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }

            ngx_memcpy(op->ssl_server_name.data, cp->ssl_server_name.data,
                       cp->ssl_server_name.len);
        }

        if (cp->ssl_trusted_certificate.len) {
            if (cp->ssl_trusted_certificate.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "invalid trusted certificate");
            }

            op->ssl_trusted_certificate.len = cp->ssl_trusted_certificate.len;
            op->ssl_trusted_certificate.data =
                ngx_pnalloc(r->pool, cp->ssl_trusted_certificate.len);
            if (op->ssl_trusted_certificate.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }

            ngx_memcpy(op->ssl_trusted_certificate.data,
                       cp->ssl_trusted_certificate.data,
                       cp->ssl_trusted_certificate.len);
        }
#else
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "TLS is not supported by this build");
#endif
    }

    op->keepalive = cp->keepalive ? 1 : 0;
    op->keepalive_idle_timeout = cp->keepalive_idle_timeout;
    op->keepalive_pool_size = cp->keepalive_pool_size;

    /* a one-shot request view of the connect params, so the host header, peer
     * and keepalive-key helpers are shared verbatim with the one-shot path */
    ngx_memzero(&req, sizeof(ngx_http_ffi_client_ffi_req_t));
    req.scheme = cp->scheme;
    req.host = cp->host;
    req.port = cp->port;
    req.keepalive = cp->keepalive;
    req.keepalive_pool = cp->keepalive_pool;
    req.keepalive_pool_size = cp->keepalive_pool_size;
    req.keepalive_idle_timeout = cp->keepalive_idle_timeout;
    req.ssl = cp->ssl;
    req.ssl_verify = cp->ssl_verify;
    req.ssl_server_name = cp->ssl_server_name;
    req.ssl_trusted_certificate = cp->ssl_trusted_certificate;

    if (ngx_http_ffi_client_build_host_header(r->pool, &req, &op->host_header,
                                              err, errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    if (ngx_http_ffi_client_parse_peer(r, &req, op, err, errlen) == NGX_ERROR) {
        return NGX_ERROR;
    }

    if (op->keepalive
        && ngx_http_ffi_client_keepalive_bind(r, op, &req, err, errlen)
           != NGX_OK)
    {
        return NGX_ERROR;
    }

    /* nothing past this point reads cp: the FFI struct belongs to Lua and the
     * connect can outlive this call */

    op->resumed = 0;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_CONNECT;

    rc = ngx_http_ffi_client_connect(op);

    if (rc == NGX_ERROR) {
        op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;
        return ngx_http_ffi_client_export_err(op, err, errlen);
    }

    return rc;
}


/*
 * Send one request on the owned connection. Always returns NGX_AGAIN on
 * success: the write is driven from the event loop, so the coroutine parks
 * first and is resumed at the response headers (or, with preread_body, once the
 * whole body has been read).
 */
ngx_int_t
ngx_http_ffi_client_ffi_send_request(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_reqp_t *rp,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen)
{
    ngx_uint_t                     conn_close;
    ngx_connection_t              *c;
    ngx_http_ffi_client_ffi_req_t  req;

    if (op == NULL || rp == NULL || resp == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad request");
    }

    if (!op->connected || op->conn_broken || op->peer.connection == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "not connected");
    }

    if (op->pending != NGX_HTTP_FFI_CLIENT_PENDING_NONE) {
        return ngx_http_ffi_client_set_err(err, errlen, "busy");
    }

    /* sending again over an unread response (or one that must close) would desync the connection */
    if (op->request_sent
        && (!op->parser.done || op->parser.connection_close
            || op->close_requested))
    {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           op->parser.done
                                               ? "connection is closing"
                                               : "previous response is not fully read");
    }

    if (rp->headers_len != 0 && rp->headers == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid headers");
    }

    op->coctx = ngx_http_lua_get_cur_co_ctx(r);
    if (op->coctx == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "no coroutine context found");
    }

    if (ngx_http_ffi_client_response_parser_init(r->pool, &op->parser)
        != NGX_OK)
    {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    if (ngx_http_ffi_client_method_is_head(&rp->method)) {
        ngx_http_ffi_client_response_head(&op->parser);
    }

    ngx_memzero(&req, sizeof(ngx_http_ffi_client_ffi_req_t));
    req.method = rp->method;
    req.path = rp->path;
    req.headers = rp->headers;
    req.headers_len = rp->headers_len;
    req.body = rp->body;
    /* the object owns the connection, so the wire always says keep-alive; when
     * to give it up is set_keepalive's and close's call */
    req.keepalive = 1;

    if (ngx_http_ffi_client_build_request(r, &req, &op->request,
                                          &op->host_header, &conn_close, err,
                                          errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    /* a caller Connection: close makes this the last request on the object's
     * connection, so it must not be pooled or reused afterwards */
    op->close_requested = conn_close ? 1 : 0;

    op->preread = rp->preread_body ? 1 : 0;

    if (!op->preread) {
        if (op->rbuf == NULL) {
            op->rbuf = ngx_pnalloc(r->pool,
                                   NGX_HTTP_FFI_CLIENT_READ_BUF_SIZE);
            if (op->rbuf == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }

            op->rbuf_size = NGX_HTTP_FFI_CLIENT_READ_BUF_SIZE;
        }

        ngx_http_ffi_client_response_stream(&op->parser);
    }

    op->ffi_resp = resp;
    op->ffi_chunk = NULL;
    op->body_offset = 0;
    op->received = 0;
    op->request_sent = 1;
    op->resumed = 0;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_REQUEST;
    op->state = NGX_HTTP_FFI_CLIENT_WRITING;

    ngx_http_ffi_client_set_cleanup(op);

    c = op->peer.connection;
    ngx_post_event(c->write, &ngx_posted_events);

    return NGX_AGAIN;
}


/*
 * Pull the next body slice. Returns NGX_OK when the slice came straight out of
 * what is already parsed (no yield), NGX_AGAIN once the coroutine has to wait
 * for more bytes, NGX_ERROR with err set.
 */
ngx_int_t
ngx_http_ffi_client_ffi_read_body(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_chunk_t *chunk,
    u_char *err, size_t *errlen)
{
    ngx_int_t  rc;

    if (op == NULL || chunk == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad read");
    }

    if (op->pending != NGX_HTTP_FFI_CLIENT_PENDING_NONE) {
        return ngx_http_ffi_client_set_err(err, errlen, "busy");
    }

    if (op->preread) {
        /* the buffered fast path already read the whole body: hand it out in
         * one slice, then report EOF */
        if (op->body_offset >= op->parser.body.len) {
            chunk->data = (u_char *) "";
            chunk->len = 0;
            chunk->eof = 1;

            return NGX_OK;
        }

        chunk->data = op->parser.body.data + op->body_offset;
        chunk->len = op->parser.body.len - op->body_offset;
        chunk->eof = 1;
        op->body_offset += chunk->len;

        return NGX_OK;
    }

    if (!op->request_sent) {
        return ngx_http_ffi_client_set_err(err, errlen, "no response to read");
    }

    rc = ngx_http_ffi_client_next_chunk(op, chunk, err, errlen);

    if (rc == NGX_ERROR) {
        /* a malformed response leaves the stream out of sync */
        ngx_http_ffi_client_ffi_close(op);
        return NGX_ERROR;
    }

    if (rc == NGX_OK) {
        return NGX_OK;
    }

    if (op->conn_broken || !op->connected || op->peer.connection == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "connection closed");
    }

    op->coctx = ngx_http_lua_get_cur_co_ctx(r);
    if (op->coctx == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "no coroutine context found");
    }

    op->ffi_chunk = chunk;
    op->resumed = 0;
    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_READ_BODY;
    op->state = NGX_HTTP_FFI_CLIENT_READING;

    ngx_http_ffi_client_set_cleanup(op);

    ngx_post_event(op->peer.connection->read, &ngx_posted_events);

    return NGX_AGAIN;
}


/*
 * Trailers of the response just read. They only exist once the body has been
 * consumed to the end, so Lua calls this after the reader reports EOF.
 */
void
ngx_http_ffi_client_ffi_get_trailers(ngx_http_ffi_client_op_t *op,
    ngx_http_ffi_client_ffi_resp_t *resp)
{
    if (op == NULL || resp == NULL) {
        return;
    }

    resp->trailers = NULL;
    resp->trailers_len = 0;

    if (!op->parser.done) {
        return;
    }

    ngx_http_ffi_client_response_trailers_to_ffi(&op->parser, resp);
}


ngx_uint_t
ngx_http_ffi_client_ffi_get_reused_times(ngx_http_ffi_client_op_t *op)
{
    return op == NULL ? 0 : op->reused;
}


/*
 * Give the connection back to the pool. idle_timeout is how long it may sit
 * there, with 0 meaning it never expires. pool_size sizes the pool when this
 * call is the one that creates it; a pool that already exists keeps the size it
 * was created with. Lua resolves the defaults it exposes, and a pool_size of 0
 * from any other caller falls back to NGX_HTTP_FFI_CLIENT_KEEPALIVE_POOL_SIZE.
 */
ngx_int_t
ngx_http_ffi_client_ffi_set_keepalive(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_msec_t idle_timeout,
    ngx_uint_t pool_size, u_char *err, size_t *errlen)
{
    (void) r;

    if (op == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad handle");
    }

    if (op->pending != NGX_HTTP_FFI_CLIENT_PENDING_NONE) {
        return ngx_http_ffi_client_set_err(err, errlen, "busy");
    }

    /* an unread response leaves the connection out of sync with the peer, so it
     * must not go back into the pool */
    if (!op->connected || op->conn_broken || op->peer.connection == NULL
        || !op->keepalive || op->keepalive_key.len == 0
        || op->parser.connection_close
        || op->close_requested
        || (op->request_sent && !op->parser.done))
    {
        ngx_http_ffi_client_ffi_close(op);
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "connection not reusable");
    }

    op->keepalive_idle_timeout = idle_timeout;

    if (pool_size > 0) {
        op->keepalive_pool_size = pool_size;
    }

    if (ngx_http_ffi_client_keepalive_save(op) != NGX_OK) {
        ngx_http_ffi_client_ffi_close(op);
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "failed to set keepalive");
    }

    op->connected = 0;
    op->request_sent = 0;
    ngx_http_ffi_client_clear_cleanup(op);

    return NGX_OK;
}


void
ngx_http_ffi_client_ffi_close(ngx_http_ffi_client_op_t *op)
{
    if (op == NULL) {
        return;
    }

    op->pending = NGX_HTTP_FFI_CLIENT_PENDING_NONE;

    ngx_http_ffi_client_close(op);

    op->connected = 0;
    op->conn_broken = 0;
    op->request_sent = 0;
    op->close_requested = 0;

    ngx_http_ffi_client_clear_cleanup(op);
}
