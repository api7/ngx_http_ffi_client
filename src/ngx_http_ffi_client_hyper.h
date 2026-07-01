#ifndef _NGX_HTTP_FFI_CLIENT_HYPER_H_INCLUDED_
#define _NGX_HTTP_FFI_CLIENT_HYPER_H_INCLUDED_

#include "ngx_http_ffi_client.h"

#include <stdbool.h>
#include <stdint.h>


#ifndef NGX_HTTP_FFI_CLIENT_HYPER_T_DEFINED
#define NGX_HTTP_FFI_CLIENT_HYPER_T_DEFINED
typedef struct ngx_http_ffi_client_hyper_s ngx_http_ffi_client_hyper_t;
#endif


/*
 * POC Rust hyper engine contract:
 * - Engine pointers are opaque and must be used serially on one Nginx worker
 *   thread. Concurrent FFI calls for the same engine pointer are unsupported.
 * - Output, body, header, and error views are borrowed from the Rust engine.
 *   They are valid only while the engine is alive and until the next mutating
 *   FFI call or free. C callers must copy view bytes before poll/feed/
 *   consume_output/close_read/free.
 */

typedef struct {
    ngx_http_ffi_client_ffi_str_t    key;
    ngx_http_ffi_client_ffi_str_t    value;
} ngx_http_ffi_client_hyper_header_view_t;


typedef struct {
    const char                      *data;
    size_t                           len;
} ngx_http_ffi_client_hyper_error_view_t;


typedef struct {
    uint32_t                         done;
    uint32_t                         want_read;
    uint32_t                         want_write;
    uint32_t                         error;
} ngx_http_ffi_client_hyper_poll_result_t;


ngx_http_ffi_client_hyper_t *ngx_http_ffi_client_hyper_new(
    const ngx_http_ffi_client_ffi_req_t *req);
void ngx_http_ffi_client_hyper_free(ngx_http_ffi_client_hyper_t *engine);
int ngx_http_ffi_client_hyper_feed(ngx_http_ffi_client_hyper_t *engine,
    const u_char *data, size_t len);
int ngx_http_ffi_client_hyper_close_read(ngx_http_ffi_client_hyper_t *engine);
int ngx_http_ffi_client_hyper_poll(ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_hyper_poll_result_t *result);
int ngx_http_ffi_client_hyper_output(const ngx_http_ffi_client_hyper_t *engine,
    const u_char **data, size_t *len);
int ngx_http_ffi_client_hyper_consume_output(
    ngx_http_ffi_client_hyper_t *engine, size_t n);
uint16_t ngx_http_ffi_client_hyper_status(
    const ngx_http_ffi_client_hyper_t *engine);
size_t ngx_http_ffi_client_hyper_header_count(
    const ngx_http_ffi_client_hyper_t *engine);
int ngx_http_ffi_client_hyper_header(
    const ngx_http_ffi_client_hyper_t *engine, size_t idx,
    ngx_http_ffi_client_hyper_header_view_t *out);
int ngx_http_ffi_client_hyper_body(const ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_ffi_str_t *out);
bool ngx_http_ffi_client_hyper_connection_close(
    const ngx_http_ffi_client_hyper_t *engine);
bool ngx_http_ffi_client_hyper_keepalive_reusable(
    ngx_http_ffi_client_hyper_t *engine);
bool ngx_http_ffi_client_hyper_session_reusable(
    const ngx_http_ffi_client_hyper_t *engine);
int ngx_http_ffi_client_hyper_start_request(
    ngx_http_ffi_client_hyper_t *engine,
    const ngx_http_ffi_client_ffi_req_t *req);
int ngx_http_ffi_client_hyper_error(const ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_hyper_error_view_t *out);

ngx_int_t ngx_http_ffi_client_hyper_to_ffi(ngx_pool_t *pool,
    const ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_hyper_to_ffi_borrowed(ngx_pool_t *pool,
    const ngx_http_ffi_client_hyper_t *engine,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_hyper_set_error(
    const ngx_http_ffi_client_hyper_t *engine, u_char *err, size_t *errlen);

#endif /* _NGX_HTTP_FFI_CLIENT_HYPER_H_INCLUDED_ */
