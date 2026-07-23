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
static ngx_uint_t ngx_http_ffi_client_has_crlf(u_char *data, size_t len);
static ngx_uint_t ngx_http_ffi_client_header_is_reserved(
    ngx_http_ffi_client_ffi_str_t *key);
static ngx_int_t ngx_http_ffi_client_build_host_header(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_req_t *req, ngx_str_t *host, u_char *err,
    size_t *errlen);
static ngx_int_t ngx_http_ffi_client_build_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_buf_t **buf, ngx_str_t *host,
    u_char *err, size_t *errlen);
static ngx_int_t ngx_http_ffi_client_parse_peer(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_op_t *op,
    u_char *err, size_t *errlen);
static void ngx_http_ffi_client_write_handler(ngx_event_t *wev);
static void ngx_http_ffi_client_read_handler(ngx_event_t *rev);
static ngx_int_t ngx_http_ffi_client_check_connect(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_prepare_connection(
    ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_write(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op);
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
    ngx_uint_t                is_https;
    ngx_connection_t         *c;
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

    if (ngx_http_ffi_client_parse_peer(r, req, op, err, errlen) != NGX_OK) {
        return NGX_ERROR;
    }

    if (op->keepalive) {
        rc = ngx_http_ffi_client_keepalive_get(r, op, req, err, errlen);
        if (rc == NGX_OK) {
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
            return NGX_ERROR;
        }
    }

    op->peer.get = ngx_http_ffi_client_get_peer;
    op->peer.log = r->connection->log;
    op->peer.log_error = NGX_ERROR_ERR;

    rc = ngx_event_connect_peer(&op->peer);

    if (rc == NGX_ERROR) {
        return ngx_http_ffi_client_set_err(err, errlen, "connect failed");
    }

    if (rc == NGX_BUSY) {
        return ngx_http_ffi_client_set_err(err, errlen, "no live connection");
    }

    if (rc == NGX_DECLINED) {
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
        /* TCP already connected: TLS still needs an async handshake, so route
         * it through the CONNECTING branch of the write handler. */
#if (NGX_SSL)
        op->state = op->ssl ? NGX_HTTP_FFI_CLIENT_CONNECTING
                            : NGX_HTTP_FFI_CLIENT_WRITING;
#else
        op->state = NGX_HTTP_FFI_CLIENT_WRITING;
#endif
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

#if (NGX_SSL)
        if (op->ssl && op->peer.connection->ssl == NULL) {
            (void) ngx_http_ffi_client_ssl_init_connection(op);
            return;
        }
#endif

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
}


static ngx_int_t
ngx_http_ffi_client_do_read(ngx_http_ffi_client_op_t *op)
{
    ssize_t           n;
    ngx_int_t         rc;
    ngx_connection_t *c;
    u_char            buf[4096];

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
            ngx_http_ffi_client_finalize(op, NGX_ERROR,
                "upstream closed before complete response");
            return NGX_ERROR;
        }

        if (!op->received) {
            ngx_http_ffi_client_finalize(op, NGX_ERROR, "connect failed");
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
        if (node->ca.len == ca->len
            && ngx_memcmp(node->ca.data, ca->data, ca->len) == 0)
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

    cln = ngx_pool_cleanup_add(ngx_cycle->pool, 0);
    if (cln == NULL) {
        ngx_ssl_cleanup_ctx(ssl);
        return NULL;
    }

    cln->handler = ngx_ssl_cleanup_ctx;
    cln->data = ssl;

    node = ngx_pcalloc(ngx_cycle->pool, sizeof(ngx_http_ffi_client_ssl_ctx_t));
    if (node == NULL) {
        return NULL;
    }

    node->ssl = ssl;
    node->ca.len = ca->len;
    if (ca->len) {
        node->ca.data = ngx_pnalloc(ngx_cycle->pool, ca->len);
        if (node->ca.data == NULL) {
            return NULL;
        }
        ngx_memcpy(node->ca.data, ca->data, ca->len);
    }

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
            ? "TLS handshake timed out" : "TLS handshake failed");
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

    op->state = NGX_HTTP_FFI_CLIENT_WRITING;

    (void) ngx_http_ffi_client_do_write(op);
}

#endif


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
    ngx_http_ffi_client_keepalive_close_active(op);
}


static void
ngx_http_ffi_client_finalize(ngx_http_ffi_client_op_t *op, ngx_int_t rc,
    const char *msg)
{
    lua_State *co;

    if (op->resumed) {
        return;
    }

    op->resumed = 1;
    op->state = rc == NGX_OK ? NGX_HTTP_FFI_CLIENT_DONE
                             : NGX_HTTP_FFI_CLIENT_FAILED;

    if (rc != NGX_OK && msg != NULL) {
        ngx_http_ffi_client_set_op_err(op, msg);
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
