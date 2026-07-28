#ifndef _NGX_HTTP_FFI_CLIENT_H_INCLUDED_
#define _NGX_HTTP_FFI_CLIENT_H_INCLUDED_

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <ngx_http_lua_api.h>

#define NGX_HTTP_FFI_CLIENT_VERSION "0.0.1"
#define NGX_HTTP_FFI_CLIENT_ERR_BUF_SIZE 256
#define NGX_HTTP_FFI_CLIENT_READ_BUF_SIZE 4096


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
    ngx_uint_t                       ssl;
    ngx_uint_t                       ssl_verify;
    ngx_http_ffi_client_ffi_str_t    ssl_server_name;
    ngx_http_ffi_client_ffi_str_t    ssl_trusted_certificate;
} ngx_http_ffi_client_ffi_req_t;


typedef struct {
    ngx_uint_t                       status;
    ngx_http_ffi_client_ffi_header_t *headers;
    ngx_uint_t                       headers_len;
    ngx_http_ffi_client_ffi_str_t    body;
    ngx_uint_t                       reused;
    ngx_http_ffi_client_ffi_header_t *trailers;
    ngx_uint_t                       trailers_len;
} ngx_http_ffi_client_ffi_resp_t;


/*
 * Connect parameters for the stateful client object: everything that decides
 * which connection is opened or taken from the pool.
 */
typedef struct {
    ngx_http_ffi_client_ffi_str_t    scheme;
    ngx_http_ffi_client_ffi_str_t    host;
    ngx_uint_t                       port;
    ngx_uint_t                       keepalive;
    ngx_http_ffi_client_ffi_str_t    keepalive_pool;
    ngx_uint_t                       keepalive_pool_size;
    ngx_msec_t                       keepalive_idle_timeout;
    ngx_uint_t                       ssl;
    ngx_uint_t                       ssl_verify;
    ngx_http_ffi_client_ffi_str_t    ssl_server_name;
    ngx_http_ffi_client_ffi_str_t    ssl_trusted_certificate;
} ngx_http_ffi_client_ffi_connect_t;


/*
 * Request parameters for the stateful client object. preread_body = 1 selects
 * the buffered fast path: C reads the whole body and resumes once with
 * resp.body filled. preread_body = 0 resumes at the headers and the body is
 * pulled slice by slice through ffi_read_body.
 */
typedef struct {
    ngx_http_ffi_client_ffi_str_t    method;
    ngx_http_ffi_client_ffi_str_t    path;
    ngx_http_ffi_client_ffi_header_t *headers;
    ngx_uint_t                       headers_len;
    ngx_http_ffi_client_ffi_str_t    body;
    ngx_uint_t                       preread_body;
} ngx_http_ffi_client_ffi_reqp_t;


/*
 * One body slice handed back by ffi_read_body. data points into the module's
 * read buffer and stays valid until the next ffi_read_body call, so Lua must
 * copy what it wants to keep. eof = 1 marks the end of the body.
 */
typedef struct {
    u_char                          *data;
    size_t                           len;
    ngx_uint_t                       eof;
} ngx_http_ffi_client_ffi_chunk_t;


#if (NGX_HTTP_FFI_CLIENT_USE_LLHTTP)

#include "llhttp.h"


typedef struct {
    u_char                          *data;
    size_t                           len;
    size_t                           cap;
} ngx_http_ffi_client_dbuf_t;


typedef struct {
    llhttp_t                         parser;
    llhttp_settings_t                settings;
    ngx_pool_t                      *pool;
    ngx_array_t                      headers;
    /* headers that arrived after a chunked body, kept apart so they never show
     * up as response headers */
    ngx_array_t                      trailers;
    ngx_http_ffi_client_dbuf_t       field;
    ngx_http_ffi_client_dbuf_t       value;
    ngx_http_ffi_client_dbuf_t       body;
    ngx_uint_t                       status;
    u_char                          *err;
    size_t                          *errlen;
    /* streaming state: the body span produced by the last parse and the input
     * bytes left unparsed behind it */
    ngx_str_t                        chunk;
    u_char                          *rest;
    size_t                           rest_len;
    unsigned                         stream:1;
    unsigned                         chunk_ready:1;
    unsigned                         paused:1;
    unsigned                         headers_done:1;
    unsigned                         done:1;
    unsigned                         connection_close:1;
    unsigned                         error:1;
    /* the request was a HEAD: the response is bodyless whatever it announces */
    unsigned                         head:1;
} ngx_http_ffi_client_response_parser_t;

#else

typedef struct {
    ngx_uint_t                       status;
    ngx_array_t                      headers;
    ngx_array_t                      trailers;
    off_t                            content_length;
    ngx_str_t                        body;
    ngx_buf_t                       *raw;
    size_t                           header_size;
    /* streaming state: the body span produced by the last parse and how much of
     * the body has been handed out already */
    ngx_str_t                        chunk;
    size_t                           taken;
    unsigned                         stream:1;
    unsigned                         chunk_ready:1;
    unsigned                         headers_done:1;
    unsigned                         done:1;
    unsigned                         connection_close:1;
    unsigned                         head:1;
    /* no content-length and no chunked encoding: the body ends at the close */
    unsigned                         eof_framed:1;
} ngx_http_ffi_client_response_parser_t;

#endif


typedef struct ngx_http_ffi_client_keepalive_pool_s
    ngx_http_ffi_client_keepalive_pool_t;
typedef struct ngx_http_ffi_client_keepalive_item_s
    ngx_http_ffi_client_keepalive_item_t;


#if (NGX_SSL)
/* one cached client SSL_CTX per distinct trust config (trusted CA path) */
typedef struct ngx_http_ffi_client_ssl_ctx_s ngx_http_ffi_client_ssl_ctx_t;

struct ngx_http_ffi_client_ssl_ctx_s {
    ngx_http_ffi_client_ssl_ctx_t    *next;
    ngx_str_t                         ca;
    ngx_ssl_t                        *ssl;
};
#endif


typedef struct {
    ngx_rbtree_t                      pools;
    ngx_rbtree_node_t                 sentinel;
#if (NGX_SSL)
    ngx_http_ffi_client_ssl_ctx_t    *ssl_ctxs;
#endif
} ngx_http_ffi_client_main_conf_t;


typedef enum {
    NGX_HTTP_FFI_CLIENT_CONNECTING = 0,
    NGX_HTTP_FFI_CLIENT_HANDSHAKING,
    NGX_HTTP_FFI_CLIENT_WRITING,
    NGX_HTTP_FFI_CLIENT_READING,
    NGX_HTTP_FFI_CLIENT_DONE,
    NGX_HTTP_FFI_CLIENT_FAILED
} ngx_http_ffi_client_state_e;


/* which stateful call the coroutine is currently parked on */
typedef enum {
    NGX_HTTP_FFI_CLIENT_PENDING_NONE = 0,
    NGX_HTTP_FFI_CLIENT_PENDING_CONNECT,
    NGX_HTTP_FFI_CLIENT_PENDING_REQUEST,
    NGX_HTTP_FFI_CLIENT_PENDING_READ_BODY
} ngx_http_ffi_client_pending_e;


typedef struct ngx_http_ffi_client_op_s ngx_http_ffi_client_op_t;


struct ngx_http_ffi_client_op_s {
    ngx_http_request_t                  *r;
    ngx_http_lua_co_ctx_t               *coctx;
    ngx_http_ffi_client_ffi_resp_t      *ffi_resp;
    ngx_peer_connection_t                peer;
    ngx_str_t                            peer_name;
    ngx_resolver_ctx_t                  *resolve_ctx;
    ngx_str_t                            resolve_name;
    struct sockaddr_storage              sockaddr;
    in_port_t                            port;
    ngx_http_ffi_client_state_e          state;
    ngx_buf_t                           *request;
    ngx_http_ffi_client_response_parser_t parser;
    ngx_msec_t                           connect_timeout;
    ngx_msec_t                           send_timeout;
    ngx_msec_t                           read_timeout;
    ngx_str_t                            host_header;
    ngx_str_t                            keepalive_key;
    ngx_http_ffi_client_keepalive_pool_t *keepalive_pool;
    ngx_msec_t                           keepalive_idle_timeout;
    ngx_uint_t                           keepalive_pool_size;
    ngx_uint_t                           reused;
    u_char                               err[NGX_HTTP_FFI_CLIENT_ERR_BUF_SIZE];
    size_t                               errlen;
    /* stateful-object state; the one-shot path leaves all of it zero */
    ngx_http_ffi_client_pending_e        pending;
    ngx_http_ffi_client_ffi_chunk_t     *ffi_chunk;
    ngx_str_t                            host;
    u_char                              *rbuf;
    size_t                               rbuf_size;
    size_t                               body_offset;
    unsigned                             resumed:1;
    unsigned                             keepalive:1;
    unsigned                             keepalive_counted:1;
    unsigned                             received:1;
    unsigned                             cleanup_set:1;
    unsigned                             resolve_inline:1;
    unsigned                             resolve_failed:1;
    unsigned                             stateful:1;
    unsigned                             preread:1;
    unsigned                             connected:1;
    unsigned                             conn_broken:1;
    unsigned                             request_sent:1;
    /* the request said Connection: close, so this connection ends with it */
    unsigned                             close_requested:1;
#if (NGX_SSL)
    ngx_str_t                            ssl_server_name;
    ngx_str_t                            ssl_trusted_certificate;
    unsigned                             ssl:1;
    unsigned                             ssl_verify:1;
#endif
};


extern ngx_module_t ngx_http_ffi_client_module;


ngx_int_t ngx_http_ffi_client_ffi_request(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_http_ffi_client_ffi_resp_t *resp,
    u_char *err, size_t *errlen);
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
ngx_int_t ngx_http_ffi_client_response_headers_to_ffi(
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen);
void ngx_http_ffi_client_response_trailers_to_ffi(
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp);

/*
 * Mark the response as the answer to a HEAD request. RFC 9110 gives such a
 * response the header fields of a GET, including Content-Length, but no body,
 * so the framing has to come from the request method rather than the headers.
 */
void ngx_http_ffi_client_response_head(
    ngx_http_ffi_client_response_parser_t *parser);

/*
 * Streaming reads. In streaming mode the parser hands body bytes out as spans
 * into the caller's read buffer instead of accumulating them: a parse stops at
 * the first body span, leaving the rest of the input buffered for the next
 * call.
 */
void ngx_http_ffi_client_response_stream(
    ngx_http_ffi_client_response_parser_t *parser);
ngx_uint_t ngx_http_ffi_client_response_pending(
    ngx_http_ffi_client_response_parser_t *parser);
void ngx_http_ffi_client_response_take_chunk(
    ngx_http_ffi_client_response_parser_t *parser, ngx_str_t *chunk);
ngx_int_t ngx_http_ffi_client_response_eof(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *err,
    size_t *errlen);

ngx_int_t ngx_http_ffi_client_keepalive_bind(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_keepalive_get(ngx_http_ffi_client_op_t *op);
ngx_int_t ngx_http_ffi_client_keepalive_save(ngx_http_ffi_client_op_t *op);
void ngx_http_ffi_client_keepalive_close_active(ngx_http_ffi_client_op_t *op);


/* stateful client object entry points (frozen ABI) */
ngx_http_ffi_client_op_t *ngx_http_ffi_client_ffi_new(ngx_http_request_t *r);
void ngx_http_ffi_client_ffi_set_timeouts(ngx_http_ffi_client_op_t *op,
    ngx_msec_t connect_timeout, ngx_msec_t send_timeout,
    ngx_msec_t read_timeout);
ngx_int_t ngx_http_ffi_client_ffi_connect(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_connect_t *cp,
    u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_ffi_send_request(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_reqp_t *rp,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen);
ngx_int_t ngx_http_ffi_client_ffi_read_body(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_chunk_t *chunk,
    u_char *err, size_t *errlen);
void ngx_http_ffi_client_ffi_get_trailers(ngx_http_ffi_client_op_t *op,
    ngx_http_ffi_client_ffi_resp_t *resp);
ngx_int_t ngx_http_ffi_client_ffi_set_keepalive(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_msec_t idle_timeout,
    ngx_uint_t pool_size, u_char *err, size_t *errlen);
ngx_uint_t ngx_http_ffi_client_ffi_get_reused_times(
    ngx_http_ffi_client_op_t *op);
void ngx_http_ffi_client_ffi_close(ngx_http_ffi_client_op_t *op);

#endif /* _NGX_HTTP_FFI_CLIENT_H_INCLUDED_ */
