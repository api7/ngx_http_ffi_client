#include "ngx_http_ffi_client_hyper.h"


static ngx_int_t ngx_http_ffi_client_hyper_write_err(u_char *err,
    size_t *errlen, const char *msg);
static ngx_int_t ngx_http_ffi_client_hyper_copy_str(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_str_t *dst,
    ngx_http_ffi_client_ffi_str_t *src, u_char *err, size_t *errlen);


ngx_int_t
ngx_http_ffi_client_hyper_to_ffi(ngx_pool_t *pool,
    const ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen)
{
    uint16_t                                status;
    size_t                                  i, n;
    ngx_http_ffi_client_hyper_header_view_t view;
    ngx_http_ffi_client_ffi_str_t           body;
    ngx_http_ffi_client_ffi_header_t       *headers;

    if (pool == NULL || engine == NULL || resp == NULL) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "invalid hyper response");
    }

    status = ngx_http_ffi_client_hyper_status(engine);
    if (status == 0) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "hyper response is missing");
    }

    n = ngx_http_ffi_client_hyper_header_count(engine);
    headers = NULL;

    if (n > 0) {
        if (n > (size_t) -1 / sizeof(ngx_http_ffi_client_ffi_header_t)) {
            return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                       "no memory");
        }

        headers = ngx_pcalloc(pool, n * sizeof(ngx_http_ffi_client_ffi_header_t));
        if (headers == NULL) {
            return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                       "no memory");
        }
    }

    for (i = 0; i < n; i++) {
        if (ngx_http_ffi_client_hyper_header(engine, i, &view) != 0) {
            return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                       "invalid hyper header");
        }

        if (ngx_http_ffi_client_hyper_copy_str(pool, &headers[i].key,
                                               &view.key, err, errlen)
            != NGX_OK)
        {
            return NGX_ERROR;
        }

        if (ngx_http_ffi_client_hyper_copy_str(pool, &headers[i].value,
                                               &view.value, err, errlen)
            != NGX_OK)
        {
            return NGX_ERROR;
        }
    }

    if (ngx_http_ffi_client_hyper_body(engine, &body) != 0) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "invalid hyper body");
    }

    resp->status = status;
    resp->headers = headers;
    resp->headers_len = n;

    if (ngx_http_ffi_client_hyper_copy_str(pool, &resp->body, &body, err,
                                           errlen)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    return NGX_OK;
}


ngx_int_t
ngx_http_ffi_client_hyper_set_error(const ngx_http_ffi_client_hyper_t *engine,
    u_char *err, size_t *errlen)
{
    size_t                                    n, cap;
    ngx_http_ffi_client_hyper_error_view_t    view;

    if (engine == NULL) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "hyper request failed");
    }

    if (ngx_http_ffi_client_hyper_error(engine, &view) != 0) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "hyper error unavailable");
    }

    if (view.len > 0 && view.data == NULL) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "invalid hyper error view");
    }

    if (view.len == 0) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "hyper request failed");
    }

    if (err != NULL && errlen != NULL && *errlen > 0) {
        cap = *errlen;
        n = ngx_min(view.len, cap - 1);
        ngx_memcpy(err, view.data, n);
        err[n] = '\0';
        *errlen = n;
    }

    return NGX_ERROR;
}


static ngx_int_t
ngx_http_ffi_client_hyper_write_err(u_char *err, size_t *errlen,
    const char *msg)
{
    if (err != NULL && errlen != NULL && *errlen > 0) {
        *errlen = ngx_snprintf(err, *errlen, "%s", msg) - err;
    }

    return NGX_ERROR;
}


static ngx_int_t
ngx_http_ffi_client_hyper_copy_str(ngx_pool_t *pool,
    ngx_http_ffi_client_ffi_str_t *dst,
    ngx_http_ffi_client_ffi_str_t *src, u_char *err, size_t *errlen)
{
    if (src->len == 0) {
        dst->data = (u_char *) "";
        dst->len = 0;
        return NGX_OK;
    }

    if (src->data == NULL) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen,
                                                   "invalid hyper data view");
    }

    dst->data = ngx_pnalloc(pool, src->len);
    if (dst->data == NULL) {
        return ngx_http_ffi_client_hyper_write_err(err, errlen, "no memory");
    }

    ngx_memcpy(dst->data, src->data, src->len);
    dst->len = src->len;

    return NGX_OK;
}
