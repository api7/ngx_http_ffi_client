#ifndef _NGX_HTTP_FFI_CLIENT_H_INCLUDED_
#define _NGX_HTTP_FFI_CLIENT_H_INCLUDED_

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <ngx_http_lua_api.h>

#define NGX_HTTP_FFI_CLIENT_VERSION "0.0.1"
#define NGX_HTTP_FFI_CLIENT_ERR_BUF_SIZE 256


typedef struct {
    u_char                         *data;
    size_t                          len;
} ngx_http_ffi_client_ffi_str_t;


typedef struct {
    ngx_http_ffi_client_ffi_str_t    key;
    ngx_http_ffi_client_ffi_str_t    value;
} ngx_http_ffi_client_ffi_header_t;


typedef struct {
    ngx_http_ffi_client_ffi_str_t    scheme;
    ngx_http_ffi_client_ffi_str_t    host;
    ngx_uint_t                       port;
    ngx_http_ffi_client_ffi_str_t    method;
    ngx_http_ffi_client_ffi_str_t    path;
    ngx_http_ffi_client_ffi_header_t *headers;
    ngx_uint_t                       headers_len;
    ngx_http_ffi_client_ffi_str_t    body;
    ngx_msec_t                       connect_timeout;
    ngx_msec_t                       send_timeout;
    ngx_msec_t                       read_timeout;
} ngx_http_ffi_client_ffi_req_t;


typedef struct {
    ngx_uint_t                       status;
    ngx_http_ffi_client_ffi_header_t *headers;
    ngx_uint_t                       headers_len;
    ngx_http_ffi_client_ffi_str_t    body;
} ngx_http_ffi_client_ffi_resp_t;


typedef struct {
    ngx_uint_t                       status;
    ngx_array_t                      headers;
    off_t                            content_length;
    ngx_str_t                        body;
    ngx_buf_t                       *raw;
    size_t                           header_size;
    unsigned                         headers_done:1;
    unsigned                         done:1;
} ngx_http_ffi_client_response_parser_t;


ngx_int_t ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen);

ngx_int_t ngx_http_ffi_client_response_parser_init(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser);
ngx_int_t ngx_http_ffi_client_response_parse(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *data, size_t len,
    u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_response_to_ffi(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen);

#endif /* _NGX_HTTP_FFI_CLIENT_H_INCLUDED_ */
