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
    ngx_http_ffi_client_ffi_str_t    keepalive_pool;
    ngx_uint_t                       keepalive;
    ngx_msec_t                       keepalive_idle_timeout;
    ngx_uint_t                       keepalive_pool_size;
    ngx_msec_t                       connect_timeout;
    ngx_msec_t                       send_timeout;
    ngx_msec_t                       read_timeout;
} ngx_http_ffi_client_ffi_req_t;


typedef struct {
    ngx_uint_t                       status;
    ngx_http_ffi_client_ffi_header_t *headers;
    ngx_uint_t                       headers_len;
    ngx_http_ffi_client_ffi_str_t    body;
    ngx_uint_t                       reused;
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
    unsigned                         connection_close:1;
} ngx_http_ffi_client_response_parser_t;


typedef struct ngx_http_ffi_client_keepalive_pool_s
    ngx_http_ffi_client_keepalive_pool_t;
typedef struct ngx_http_ffi_client_keepalive_item_s
    ngx_http_ffi_client_keepalive_item_t;

#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
#ifndef NGX_HTTP_FFI_CLIENT_HYPER_T_DEFINED
#define NGX_HTTP_FFI_CLIENT_HYPER_T_DEFINED
typedef struct ngx_http_ffi_client_hyper_s ngx_http_ffi_client_hyper_t;
#endif
#endif


typedef struct {
    ngx_rbtree_t                      pools;
    ngx_rbtree_node_t                 sentinel;
} ngx_http_ffi_client_main_conf_t;


typedef enum {
    NGX_HTTP_FFI_CLIENT_CONNECTING = 0,
    NGX_HTTP_FFI_CLIENT_WRITING,
    NGX_HTTP_FFI_CLIENT_READING,
    NGX_HTTP_FFI_CLIENT_DONE,
    NGX_HTTP_FFI_CLIENT_FAILED
} ngx_http_ffi_client_state_e;


typedef struct ngx_http_ffi_client_op_s ngx_http_ffi_client_op_t;


struct ngx_http_ffi_client_op_s {
    ngx_http_request_t                  *r;
    ngx_http_lua_co_ctx_t               *coctx;
    ngx_http_ffi_client_ffi_resp_t      *ffi_resp;
    ngx_peer_connection_t                peer;
    ngx_str_t                            peer_name;
    ngx_http_ffi_client_state_e          state;
    ngx_buf_t                           *request;
    ngx_http_ffi_client_response_parser_t parser;
#if (NGX_HTTP_FFI_CLIENT_USE_HYPER)
    ngx_http_ffi_client_hyper_t          *hyper;
#endif
    ngx_msec_t                           connect_timeout;
    ngx_msec_t                           send_timeout;
    ngx_msec_t                           read_timeout;
    ngx_str_t                            host_header;
    ngx_str_t                            keepalive_key;
    ngx_http_ffi_client_keepalive_pool_t *keepalive_pool;
    ngx_msec_t                           keepalive_idle_timeout;
    ngx_uint_t                           keepalive_pool_size;
    u_char                               err[NGX_HTTP_FFI_CLIENT_ERR_BUF_SIZE];
    size_t                               errlen;
    unsigned                             resumed:1;
    unsigned                             keepalive:1;
    unsigned                             keepalive_counted:1;
    unsigned                             reused:1;
};


extern ngx_module_t ngx_http_ffi_client_module;


ngx_int_t ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen);
const char *ngx_http_ffi_client_ffi_backend(void);
ngx_int_t ngx_http_ffi_client_start(ngx_http_request_t *r,
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

ngx_int_t ngx_http_ffi_client_keepalive_get(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_keepalive_save(ngx_http_ffi_client_op_t *op);
void ngx_http_ffi_client_keepalive_close_active(ngx_http_ffi_client_op_t *op);

#endif /* _NGX_HTTP_FFI_CLIENT_H_INCLUDED_ */
