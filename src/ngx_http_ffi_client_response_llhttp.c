#include "ngx_http_ffi_client.h"


#define ngx_http_ffi_client_llhttp_parser(p)                                  \
    ((ngx_http_ffi_client_response_parser_t *) (p)->data)


static ngx_int_t ngx_http_ffi_client_set_err(u_char *err, size_t *errlen,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_dbuf_append(ngx_pool_t *pool,
    ngx_http_ffi_client_dbuf_t *b, const u_char *data, size_t len);

static int ngx_http_ffi_client_on_header_field(llhttp_t *p, const char *at,
    size_t len);
static int ngx_http_ffi_client_on_header_value(llhttp_t *p, const char *at,
    size_t len);
static int ngx_http_ffi_client_on_header_value_complete(llhttp_t *p);
static int ngx_http_ffi_client_on_headers_complete(llhttp_t *p);
static int ngx_http_ffi_client_on_body(llhttp_t *p, const char *at,
    size_t len);
static int ngx_http_ffi_client_on_message_complete(llhttp_t *p);


ngx_int_t
ngx_http_ffi_client_response_parser_init(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser)
{
    ngx_memzero(parser, sizeof(ngx_http_ffi_client_response_parser_t));

    if (ngx_array_init(&parser->headers, pool, 8,
                       sizeof(ngx_http_ffi_client_ffi_header_t))
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    llhttp_settings_init(&parser->settings);

    parser->settings.on_header_field = ngx_http_ffi_client_on_header_field;
    parser->settings.on_header_value = ngx_http_ffi_client_on_header_value;
    parser->settings.on_header_value_complete =
        ngx_http_ffi_client_on_header_value_complete;
    parser->settings.on_headers_complete =
        ngx_http_ffi_client_on_headers_complete;
    parser->settings.on_body = ngx_http_ffi_client_on_body;
    parser->settings.on_message_complete =
        ngx_http_ffi_client_on_message_complete;

    llhttp_init(&parser->parser, HTTP_RESPONSE, &parser->settings);
    parser->parser.data = parser;
    parser->pool = pool;

    return NGX_OK;
}


ngx_int_t
ngx_http_ffi_client_response_parse(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *data, size_t len,
    u_char *err, size_t *errlen)
{
    llhttp_errno_t  rc;

    if (parser->done) {
        return NGX_OK;
    }

    parser->pool = pool;
    parser->err = err;
    parser->errlen = errlen;
    parser->error = 0;

    rc = llhttp_execute(&parser->parser, (const char *) data, len);

    if (rc == HPE_OK) {
        return NGX_OK;
    }

    if (parser->error) {
        /* a callback already wrote the error message */
        return NGX_ERROR;
    }

    return ngx_http_ffi_client_set_err(err, errlen,
                                       llhttp_get_error_reason(&parser->parser));
}


ngx_int_t
ngx_http_ffi_client_response_to_ffi(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen)
{
    (void) pool;

    if (!parser->done) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "response body is incomplete");
    }

    resp->status = parser->status;
    resp->headers = parser->headers.elts;
    resp->headers_len = parser->headers.nelts;
    resp->body.data = parser->body.len ? parser->body.data : (u_char *) "";
    resp->body.len = parser->body.len;

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
ngx_http_ffi_client_dbuf_append(ngx_pool_t *pool,
    ngx_http_ffi_client_dbuf_t *b, const u_char *data, size_t len)
{
    size_t   ncap;
    u_char  *nd;

    if (len == 0) {
        return NGX_OK;
    }

    if (b->len + len > b->cap) {
        ncap = b->cap ? b->cap * 2 : 256;
        while (ncap < b->len + len) {
            ncap *= 2;
        }

        nd = ngx_pnalloc(pool, ncap);
        if (nd == NULL) {
            return NGX_ERROR;
        }

        if (b->len) {
            ngx_memcpy(nd, b->data, b->len);
        }

        b->data = nd;
        b->cap = ncap;
    }

    ngx_memcpy(b->data + b->len, data, len);
    b->len += len;

    return NGX_OK;
}


static int
ngx_http_ffi_client_on_header_field(llhttp_t *p, const char *at, size_t len)
{
    ngx_http_ffi_client_response_parser_t *parser;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    if (ngx_http_ffi_client_dbuf_append(parser->pool, &parser->field,
                                        (const u_char *) at, len)
        != NGX_OK)
    {
        parser->error = 1;
        (void) ngx_http_ffi_client_set_err(parser->err, parser->errlen,
                                           "no memory");
        return -1;
    }

    return 0;
}


static int
ngx_http_ffi_client_on_header_value(llhttp_t *p, const char *at, size_t len)
{
    ngx_http_ffi_client_response_parser_t *parser;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    if (ngx_http_ffi_client_dbuf_append(parser->pool, &parser->value,
                                        (const u_char *) at, len)
        != NGX_OK)
    {
        parser->error = 1;
        (void) ngx_http_ffi_client_set_err(parser->err, parser->errlen,
                                           "no memory");
        return -1;
    }

    return 0;
}


static int
ngx_http_ffi_client_on_header_value_complete(llhttp_t *p)
{
    ngx_http_ffi_client_response_parser_t *parser;
    ngx_http_ffi_client_ffi_header_t      *h;
    u_char                                *k, *v;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    h = ngx_array_push(&parser->headers);
    if (h == NULL) {
        goto failed;
    }

    if (parser->field.len) {
        k = ngx_pnalloc(parser->pool, parser->field.len);
        if (k == NULL) {
            goto failed;
        }
        ngx_memcpy(k, parser->field.data, parser->field.len);

    } else {
        k = (u_char *) "";
    }

    h->key.data = k;
    h->key.len = parser->field.len;

    if (parser->value.len) {
        v = ngx_pnalloc(parser->pool, parser->value.len);
        if (v == NULL) {
            goto failed;
        }
        ngx_memcpy(v, parser->value.data, parser->value.len);

    } else {
        v = (u_char *) "";
    }

    h->value.data = v;
    h->value.len = parser->value.len;

    parser->field.len = 0;
    parser->value.len = 0;

    return 0;

failed:

    parser->error = 1;
    (void) ngx_http_ffi_client_set_err(parser->err, parser->errlen,
                                       "no memory");
    return -1;
}


static int
ngx_http_ffi_client_on_headers_complete(llhttp_t *p)
{
    ngx_http_ffi_client_response_parser_t *parser;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    parser->status = llhttp_get_status_code(p);
    parser->headers_done = 1;

    return 0;
}


static int
ngx_http_ffi_client_on_body(llhttp_t *p, const char *at, size_t len)
{
    ngx_http_ffi_client_response_parser_t *parser;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    if (ngx_http_ffi_client_dbuf_append(parser->pool, &parser->body,
                                        (const u_char *) at, len)
        != NGX_OK)
    {
        parser->error = 1;
        (void) ngx_http_ffi_client_set_err(parser->err, parser->errlen,
                                           "no memory");
        return -1;
    }

    return 0;
}


static int
ngx_http_ffi_client_on_message_complete(llhttp_t *p)
{
    ngx_http_ffi_client_response_parser_t *parser;

    parser = ngx_http_ffi_client_llhttp_parser(p);

    parser->done = 1;
    parser->connection_close = llhttp_should_keep_alive(p) ? 0 : 1;

    return 0;
}
