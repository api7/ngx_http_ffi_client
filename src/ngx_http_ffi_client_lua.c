#include "ngx_http_ffi_client.h"


ngx_int_t
ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen)
{
    if (r == NULL) {
        if (err != NULL && errlen != NULL && *errlen > 0) {
            *errlen = ngx_snprintf(err, *errlen, "no request found") - err;
        }

        return NGX_ERROR;
    }

    return ngx_http_ffi_client_start(r, req, resp, err, errlen);
}
