#include "ngx_http_ffi_client.h"
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
#include "ngx_http_ffi_client_hyper.h"
#endif


static ngx_int_t ngx_http_ffi_client_get_peer(ngx_peer_connection_t *pc,
    void *data);
static ngx_int_t ngx_http_ffi_client_set_err(u_char *err, size_t *errlen,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_set_op_err(ngx_http_ffi_client_op_t *op,
    const char *msg);
static ngx_uint_t ngx_http_ffi_client_has_crlf(u_char *data, size_t len);
static ngx_int_t ngx_http_ffi_client_validate_request(
    ngx_http_ffi_client_ffi_req_t *req, u_char *err, size_t *errlen);
#if !(NGX_HTTP_FFI_CLIENT_USE_HYPER)
static ngx_uint_t ngx_http_ffi_client_header_is_reserved(
    ngx_http_ffi_client_ffi_str_t *key);
static ngx_int_t ngx_http_ffi_client_build_host_header(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_req_t *req, ngx_str_t *host, u_char *err,
    size_t *errlen);
static ngx_int_t ngx_http_ffi_client_build_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_buf_t **buf, ngx_str_t *host,
    u_char *err, size_t *errlen);
#endif
static ngx_int_t ngx_http_ffi_client_parse_peer(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen);
static void ngx_http_ffi_client_write_handler(ngx_event_t *wev);
static void ngx_http_ffi_client_read_handler(ngx_event_t *rev);
static ngx_int_t ngx_http_ffi_client_check_connect(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_prepare_connection(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_write(ngx_http_ffi_client_op_t *op);
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
static ngx_int_t ngx_http_ffi_client_do_hyper_write(
    ngx_http_ffi_client_op_t *op);
#endif
static ngx_int_t ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op);
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
static ngx_int_t ngx_http_ffi_client_do_hyper_read(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_hyper_to_response(
    ngx_http_ffi_client_op_t *op);
#if (NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)
static void ngx_http_ffi_client_hyper_cleanup(void *data);
#endif
#endif
static void ngx_http_ffi_client_cleanup(void *data);
static void ngx_http_ffi_client_close(ngx_http_ffi_client_op_t *op);
static void ngx_http_ffi_client_finalize(ngx_http_ffi_client_op_t *op,
    ngx_int_t rc, const char *msg);
static ngx_int_t ngx_http_ffi_client_handle_write_wait(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_handle_read_wait(
    ngx_http_ffi_client_op_t *op);


ngx_int_t
ngx_http_ffi_client_start(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen)
{
    ngx_int_t                 rc;
    ngx_connection_t         *c;
    ngx_http_ffi_client_op_t *op;
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER && NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)
    ngx_pool_cleanup_t       *cln;
#endif

    if (req == NULL || resp == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad request");
    }

    if (req->scheme.data == NULL
        || req->scheme.len != sizeof("http") - 1
        || ngx_strncmp(req->scheme.data, "http", sizeof("http") - 1) != 0)
    {
        return ngx_http_ffi_client_set_err(err, errlen, "unsupported scheme");
    }

    if (req->port == 0 || req->port > 65535) {
        return ngx_http_ffi_client_set_err(err, errlen, "bad port");
    }

    if (req->headers_len != 0 && req->headers == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid headers");
    }

    if (req->keepalive && req->keepalive_pool_size == 0) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "bad keepalive pool size");
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

    op->coctx = ngx_http_lua_get_cur_co_ctx(r);
    if (op->coctx == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "no coroutine context found");
    }

    if (ngx_http_ffi_client_validate_request(req, err, errlen) != NGX_OK) {
        return NGX_ERROR;
    }

#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
#if !(NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH)
    op->hyper = ngx_http_ffi_client_hyper_new(req);
    if (op->hyper == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "failed to create hyper engine");
    }
#endif
#if (NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)
    cln = ngx_pool_cleanup_add(r->pool, 0);
    if (cln == NULL) {
        ngx_http_ffi_client_hyper_free(op->hyper);
        op->hyper = NULL;
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    cln->handler = ngx_http_ffi_client_hyper_cleanup;
    cln->data = op;
#endif
#else
    if (ngx_http_ffi_client_response_parser_init(r->pool, &op->parser)
        != NGX_OK)
    {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    if (ngx_http_ffi_client_build_host_header(r->pool, req, &op->host_header,
                                              err, errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    if (ngx_http_ffi_client_build_request(r, req, &op->request,
                                          &op->host_header, err, errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }
#endif

    if (ngx_http_ffi_client_parse_peer(r, req, op, err, errlen) != NGX_OK) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
        ngx_http_ffi_client_hyper_free(op->hyper);
        op->hyper = NULL;
#endif
        return NGX_ERROR;
    }

    if (op->keepalive) {
        rc = ngx_http_ffi_client_keepalive_get(r, op, req, err, errlen);
        if (rc == NGX_OK) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER && NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH)
            if (ngx_http_ffi_client_hyper_start_request(op->hyper, req) != 0)
            {
                ngx_http_ffi_client_close(op);
                return ngx_http_ffi_client_set_err(err, errlen,
                    "failed to reuse hyper session");
            }
#endif

            if (ngx_http_ffi_client_prepare_connection(op) != NGX_OK) {
                ngx_http_ffi_client_close(op);
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }

            ngx_http_lua_cleanup_co_ctx_pending_operation(op->coctx);
            ngx_http_lua_set_co_ctx_cleanup(op->coctx,
                                            ngx_http_ffi_client_cleanup, op);

            op->state = NGX_HTTP_FFI_CLIENT_WRITING;
            ngx_post_event(op->peer.connection->write, &ngx_posted_events);
            return NGX_AGAIN;
        }

        if (rc == NGX_ERROR) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
            ngx_http_ffi_client_close(op);
#endif
            return NGX_ERROR;
        }
    }

#if (NGX_HTTP_FFI_CLIENT_USE_HYPER && NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH)
    op->hyper = ngx_http_ffi_client_hyper_new(req);
    if (op->hyper == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "failed to create hyper engine");
    }
#endif

    op->peer.get = ngx_http_ffi_client_get_peer;
    op->peer.log = r->connection->log;
    op->peer.log_error = NGX_ERROR_ERR;

    rc = ngx_event_connect_peer(&op->peer);

    if (rc == NGX_ERROR) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
        ngx_http_ffi_client_close(op);
#endif
        return ngx_http_ffi_client_set_err(err, errlen, "connect failed");
    }

    if (rc == NGX_BUSY) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
        ngx_http_ffi_client_close(op);
#endif
        return ngx_http_ffi_client_set_err(err, errlen, "no live connection");
    }

    if (rc == NGX_DECLINED) {
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
        ngx_http_ffi_client_close(op);
#endif
        return ngx_http_ffi_client_set_err(err, errlen, "connect failed");
    }

    c = op->peer.connection;
    if (ngx_http_ffi_client_prepare_connection(op) != NGX_OK) {
        ngx_http_ffi_client_close(op);
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    ngx_http_lua_cleanup_co_ctx_pending_operation(op->coctx);
    ngx_http_lua_set_co_ctx_cleanup(op->coctx, ngx_http_ffi_client_cleanup,
                                    op);

    if (rc == NGX_OK) {
        op->state = NGX_HTTP_FFI_CLIENT_WRITING;
        ngx_post_event(c->write, &ngx_posted_events);
        return NGX_AGAIN;
    }

    op->state = NGX_HTTP_FFI_CLIENT_CONNECTING;
    ngx_add_timer(c->write, op->connect_timeout);

    if (ngx_handle_write_event(c->write, 0) != NGX_OK) {
        ngx_http_ffi_client_close(op);
        ngx_http_lua_set_co_ctx_cleanup(op->coctx, NULL, NULL);
        return ngx_http_ffi_client_set_err(err, errlen,
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


static ngx_int_t
ngx_http_ffi_client_validate_request(ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen)
{
    ngx_uint_t                        i;
    ngx_http_ffi_client_ffi_header_t *h;

    if (req->host.len == 0 || req->host.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "host is required");
    }

    if (ngx_http_ffi_client_has_crlf(req->host.data, req->host.len)) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid host");
    }

    if (req->method.len == 0 || req->method.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "method is required");
    }

    if (req->path.len == 0 || req->path.data == NULL || req->path.data[0] != '/')
    {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid path");
    }

    if (req->body.len != 0 && req->body.data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid request");
    }

    if (ngx_http_ffi_client_has_crlf(req->method.data, req->method.len)
        || ngx_http_ffi_client_has_crlf(req->path.data, req->path.len)
        || ngx_http_ffi_client_has_crlf(req->body.data, req->body.len))
    {
        return ngx_http_ffi_client_set_err(err, errlen, "invalid request");
    }

    for (i = 0; i < req->headers_len; i++) {
        h = &req->headers[i];

        if (h->key.len == 0 || h->key.data == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid request header");
        }

        if (h->value.len != 0 && h->value.data == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid request header");
        }

        if (ngx_http_ffi_client_has_crlf(h->key.data, h->key.len)
            || ngx_http_ffi_client_has_crlf(h->value.data, h->value.len))
        {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid request header");
        }
    }

    return NGX_OK;
}


#if !(NGX_HTTP_FFI_CLIENT_USE_HYPER)

static ngx_uint_t
ngx_http_ffi_client_header_is_reserved(ngx_http_ffi_client_ffi_str_t *key)
{
    return (key->len == sizeof("Host") - 1
            && ngx_strncasecmp(key->data, (u_char *) "Host", key->len) == 0)
           || (key->len == sizeof("Connection") - 1
               && ngx_strncasecmp(key->data, (u_char *) "Connection",
                                  key->len) == 0)
           || (key->len == sizeof("Content-Length") - 1
               && ngx_strncasecmp(key->data, (u_char *) "Content-Length",
                                  key->len) == 0);
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


static ngx_int_t
ngx_http_ffi_client_build_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_buf_t **buf, ngx_str_t *host,
    u_char *err, size_t *errlen)
{
    size_t                            len;
    u_char                           *p;
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

    len = req->method.len + 1 + req->path.len
          + sizeof(" HTTP/1.1" CRLF) - 1
          + sizeof("Host: " CRLF) - 1 + host->len
          + (req->keepalive ? sizeof("Connection: keep-alive" CRLF) - 1
                            : sizeof("Connection: close" CRLF) - 1)
          + sizeof("Content-Length: " CRLF) - 1 + NGX_SIZE_T_LEN
          + sizeof(CRLF) - 1
          + req->body.len;

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

        if (ngx_http_ffi_client_header_is_reserved(&h->key)) {
            continue;
        }

        len += h->key.len + sizeof(": " CRLF) - 1 + h->value.len;
    }

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
    p = ngx_cpymem(p, host->data, host->len);
    p = ngx_cpymem(p, CRLF, sizeof(CRLF) - 1);
    if (req->keepalive) {
        p = ngx_cpymem(p, "Connection: keep-alive" CRLF,
                       sizeof("Connection: keep-alive" CRLF) - 1);

    } else {
        p = ngx_cpymem(p, "Connection: close" CRLF,
                       sizeof("Connection: close" CRLF) - 1);
    }
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

#endif


static ngx_int_t
ngx_http_ffi_client_parse_peer(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen)
{
    u_char      *text, *p;
    size_t       len;
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

    ngx_memzero(&addr, sizeof(ngx_addr_t));

    if (ngx_parse_addr_port(r->pool, &addr, text, p - text) != NGX_OK) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "host must be an IP address");
    }

    op->peer.sockaddr = addr.sockaddr;
    op->peer.socklen = addr.socklen;
    op->peer_name = addr.name;
    op->peer.name = &op->peer_name;

    return NGX_OK;
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

    if (wev->timedout) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR,
            op->state == NGX_HTTP_FFI_CLIENT_CONNECTING
            ? "connect timed out" : "send timed out");
        return;
    }

    if (wev->error) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "write event error");
        return;
    }

    if (op->state == NGX_HTTP_FFI_CLIENT_CONNECTING) {
        if (ngx_http_ffi_client_check_connect(op) != NGX_OK) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR, "connect failed");
            return;
        }

        if (wev->timer_set) {
            ngx_del_timer(wev);
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

    if (rev->timedout) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "read timed out");
        return;
    }

    if (rev->error) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "read event error");
        return;
    }

    (void) ngx_http_ffi_client_do_read(op);
}


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
        return NGX_ERROR;
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
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
    return ngx_http_ffi_client_do_hyper_write(op);
#else
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
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "connect failed");
        return NGX_ERROR;
    }

    op->state = NGX_HTTP_FFI_CLIENT_READING;

    return ngx_http_ffi_client_do_read(op);
#endif
}


#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)

static ngx_int_t
ngx_http_ffi_client_do_hyper_write(ngx_http_ffi_client_op_t *op)
{
    ssize_t                                  n;
    size_t                                   len;
    const u_char                            *data;
    ngx_connection_t                        *c;
    ngx_http_ffi_client_hyper_poll_result_t  result;

    c = op->peer.connection;

    if (ngx_http_ffi_client_hyper_poll(op->hyper, &result) != 0) {
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "hyper poll failed");
        return NGX_ERROR;
    }

    if (result.error) {
        op->errlen = sizeof(op->err);
        (void) ngx_http_ffi_client_hyper_set_error(op->hyper, op->err,
                                                   &op->errlen);
        ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
        return NGX_ERROR;
    }

    for ( ;; ) {
        if (ngx_http_ffi_client_hyper_output(op->hyper, &data, &len) != 0) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR, "hyper output failed");
            return NGX_ERROR;
        }

        if (len == 0) {
            break;
        }

        n = c->send(c, (u_char *) data, len);

        if (n > 0) {
            if (ngx_http_ffi_client_hyper_consume_output(op->hyper, n) != 0) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                             "hyper output consume failed");
                return NGX_ERROR;
            }

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
        ngx_http_ffi_client_finalize(op, NGX_ERROR, "connect failed");
        return NGX_ERROR;
    }

    op->state = NGX_HTTP_FFI_CLIENT_READING;

    return ngx_http_ffi_client_do_read(op);
}

#endif


static ngx_int_t
ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op)
{
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
    return ngx_http_ffi_client_do_hyper_read(op);
#else
    ssize_t           n;
    ngx_int_t         rc;
    ngx_connection_t *c;
    u_char            buf[4096];

    c = op->peer.connection;

    for ( ;; ) {
        n = c->recv(c, buf, sizeof(buf));

        if (n > 0) {
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
            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                "upstream closed before complete response");
            return NGX_ERROR;
        }

        if (op->parser.raw == NULL) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR, "connect failed");
            return NGX_ERROR;
        }

        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to read response");
        return NGX_ERROR;
    }
#endif
}


#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)

static ngx_int_t
ngx_http_ffi_client_do_hyper_read(ngx_http_ffi_client_op_t *op)
{
    ssize_t                                  n;
    ngx_int_t                                rc;
    ngx_connection_t                        *c;
    u_char                                   buf[4096];
    ngx_http_ffi_client_hyper_poll_result_t  result;

    c = op->peer.connection;

    for ( ;; ) {
        n = c->recv(c, buf, sizeof(buf));

        if (n > 0) {
            if (ngx_http_ffi_client_hyper_feed(op->hyper, buf, n) != 0) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                             "hyper feed failed");
                return NGX_ERROR;
            }

            if (ngx_http_ffi_client_hyper_poll(op->hyper, &result) != 0) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                             "hyper poll failed");
                return NGX_ERROR;
            }

            if (result.error) {
                op->errlen = sizeof(op->err);
                (void) ngx_http_ffi_client_hyper_set_error(op->hyper, op->err,
                                                           &op->errlen);
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            if (result.done) {
                rc = ngx_http_ffi_client_hyper_to_response(op);
                if (rc != NGX_OK) {
                    ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                    return NGX_ERROR;
                }

                ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
                return NGX_OK;
            }

            continue;
        }

        if (n == NGX_AGAIN) {
            return ngx_http_ffi_client_handle_read_wait(op);
        }

        if (n == 0) {
            if (ngx_http_ffi_client_hyper_close_read(op->hyper) != 0) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                             "hyper close read failed");
                return NGX_ERROR;
            }

            if (ngx_http_ffi_client_hyper_poll(op->hyper, &result) != 0) {
                ngx_http_ffi_client_finalize(op, NGX_ERROR,
                                             "hyper poll failed");
                return NGX_ERROR;
            }

            if (result.error) {
                op->errlen = sizeof(op->err);
                (void) ngx_http_ffi_client_hyper_set_error(op->hyper, op->err,
                                                           &op->errlen);
                ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                return NGX_ERROR;
            }

            if (result.done) {
                rc = ngx_http_ffi_client_hyper_to_response(op);
                if (rc != NGX_OK) {
                    ngx_http_ffi_client_finalize(op, NGX_ERROR, NULL);
                    return NGX_ERROR;
                }

                ngx_http_ffi_client_finalize(op, NGX_OK, NULL);
                return NGX_OK;
            }

            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                "upstream closed before complete response");
            return NGX_ERROR;
        }

        ngx_http_ffi_client_finalize(op, NGX_ERROR, "failed to read response");
        return NGX_ERROR;
    }
}


static ngx_int_t
ngx_http_ffi_client_hyper_to_response(ngx_http_ffi_client_op_t *op)
{
    ngx_int_t  rc;

    op->errlen = sizeof(op->err);

#if (NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)
    /*
     * Benchmark-only A/B gate: keep response bytes borrowed from the Rust
     * engine until the request pool cleanup runs.
     *
     * TODO: replace this with an explicit production ownership contract before
     * exposing a no-copy response path outside benchmark builds.
     */
    rc = ngx_http_ffi_client_hyper_to_ffi_borrowed(op->r->pool, op->hyper,
                                                   op->ffi_resp, op->err,
                                                   &op->errlen);
#else
    rc = ngx_http_ffi_client_hyper_to_ffi(op->r->pool, op->hyper,
                                          op->ffi_resp, op->err,
                                          &op->errlen);
#endif

    if (rc != NGX_OK) {
        return NGX_ERROR;
    }

#if (NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)
    op->hyper_borrow_response = 1;
#endif
    op->ffi_resp->reused = op->reused;

    return NGX_OK;
}


#if (NGX_HTTP_FFI_CLIENT_HYPER_BORROW_RESPONSE_BENCH)

static void
ngx_http_ffi_client_hyper_cleanup(void *data)
{
    ngx_http_ffi_client_op_t *op = data;

    if (op != NULL && op->hyper != NULL) {
        ngx_http_ffi_client_hyper_free(op->hyper);
        op->hyper = NULL;
    }
}

#endif

#endif


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


static void
ngx_http_ffi_client_cleanup(void *data)
{
    ngx_http_ffi_client_op_t *op = data;

    if (op == NULL || op->resumed) {
        return;
    }

    op->resumed = 1;
    op->state = NGX_HTTP_FFI_CLIENT_FAILED;
    ngx_http_ffi_client_close(op);
}


static void
ngx_http_ffi_client_close(ngx_http_ffi_client_op_t *op)
{
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
    if (op->hyper != NULL) {
        ngx_http_ffi_client_hyper_free(op->hyper);
        op->hyper = NULL;
    }
#endif

    ngx_http_ffi_client_keepalive_close_active(op);
}


static void
ngx_http_ffi_client_finalize(ngx_http_ffi_client_op_t *op, ngx_int_t rc,
    const char *msg)
{
    lua_State  *co;
    ngx_uint_t  saved;

    if (op->resumed) {
        return;
    }

    op->resumed = 1;
    op->state = rc == NGX_OK ? NGX_HTTP_FFI_CLIENT_DONE
                             : NGX_HTTP_FFI_CLIENT_FAILED;

    if (rc != NGX_OK && msg != NULL) {
        ngx_http_ffi_client_set_op_err(op, msg);
    }

    saved = 0;

#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
#if (NGX_HTTP_FFI_CLIENT_HYPER_SESSION_BENCH)
    /*
     * Benchmark-only session reuse path: cache the Rust hyper sender/
     * connection state together with the Nginx fd. This removes per-request
     * hyper engine construction from reused keepalive requests while keeping
     * the same fd safety checks in the Nginx keepalive pool.
     *
     * TODO: turn this into an explicit production ownership contract before
     * exposing it outside benchmark builds.
     */
    if (rc == NGX_OK
        && op->keepalive
        && ngx_http_ffi_client_hyper_session_reusable(op->hyper)
        && ngx_http_ffi_client_keepalive_save(op) == NGX_OK)
    {
        saved = 1;
    }
#elif (NGX_HTTP_FFI_CLIENT_HYPER_KEEPALIVE_BENCH)
    /*
     * Benchmark-only keepalive path inspired by lua-nginx-module cosocket
     * setkeepalive: Rust first proves the hyper read buffer and wrapper IO
     * buffers are empty, then the existing Nginx keepalive pool checks the fd
     * state before caching it.
     *
     * TODO: replace this gate with a production contract that preserves or
     * safely detaches all hyper per-connection state across pooled requests.
     */
    if (rc == NGX_OK
        && op->keepalive
        && ngx_http_ffi_client_hyper_keepalive_reusable(op->hyper)
        && ngx_http_ffi_client_keepalive_save(op) == NGX_OK)
    {
        saved = 1;
    }
#else
    /*
     * Until the hyper engine can prove no unread or internal buffered bytes
     * remain, hyper connections are closed after each response.
     */
#endif
#else
    if (rc == NGX_OK
        && op->keepalive
        && !op->parser.connection_close
        && ngx_http_ffi_client_keepalive_save(op) == NGX_OK)
    {
        saved = 1;
    }
#endif

#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
    if (rc == NGX_OK && op->hyper_borrow_response) {
        if (!saved) {
            ngx_http_ffi_client_keepalive_close_active(op);
        }

    } else {
        ngx_http_ffi_client_close(op);
    }
#else
    if (!saved) {
        ngx_http_ffi_client_close(op);
    }
#endif

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
