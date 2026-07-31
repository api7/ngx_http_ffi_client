#include "ngx_http_ffi_client.h"


static ngx_int_t ngx_http_ffi_client_set_err(u_char *err, size_t *errlen,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_response_append(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *data, size_t len);
static u_char *ngx_http_ffi_client_find_header_end(u_char *start,
    u_char *last);
static ngx_int_t ngx_http_ffi_client_parse_headers(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *header_end,
    u_char *err, size_t *errlen);
static ngx_int_t ngx_http_ffi_client_parse_content_length(ngx_str_t *value,
    off_t *out);
static ngx_uint_t ngx_http_ffi_client_str_eq_lc(ngx_str_t *s,
    const char *name);
static ngx_int_t ngx_http_ffi_client_response_update_body(
    ngx_http_ffi_client_response_parser_t *parser, u_char *err,
    size_t *errlen);


ngx_int_t
ngx_http_ffi_client_response_parser_init(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser)
{
    ngx_memzero(parser, sizeof(ngx_http_ffi_client_response_parser_t));

    parser->content_length = -1;

    if (ngx_array_init(&parser->headers, pool, 4,
                       sizeof(ngx_http_ffi_client_ffi_header_t))
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    /* this backend rejects chunked responses, so a trailer can never reach it;
     * the array exists to keep the two backends interchangeable */
    if (ngx_array_init(&parser->trailers, pool, 1,
                       sizeof(ngx_http_ffi_client_ffi_header_t))
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    return NGX_OK;
}


void
ngx_http_ffi_client_response_head(
    ngx_http_ffi_client_response_parser_t *parser)
{
    parser->head = 1;
}


ngx_int_t
ngx_http_ffi_client_response_parse(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *data, size_t len,
    u_char *err, size_t *errlen)
{
    u_char      *header_end;
    ngx_int_t    rc;

    if (parser->done) {
        return NGX_OK;
    }

    if (data == NULL) {
        /* nothing is left unparsed: this parser consumes every byte it is fed */
        len = 0;
    }

    if (len > 0
        && ngx_http_ffi_client_response_append(pool, parser, data, len)
           != NGX_OK)
    {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    if (parser->raw == NULL) {
        return NGX_OK;
    }

    while (!parser->headers_done) {
        header_end = ngx_http_ffi_client_find_header_end(parser->raw->pos,
                                                         parser->raw->last);
        if (header_end == NULL) {
            return NGX_OK;
        }

        rc = ngx_http_ffi_client_parse_headers(pool, parser, header_end, err,
                                               errlen);
        if (rc != NGX_OK) {
            return rc;
        }

        if (parser->interim) {
            /* the interim response is consumed here: its bytes and everything
             * it declared go, and the loop reads the message behind it */
            parser->raw->pos = header_end + 4;
            parser->headers.nelts = 0;
            parser->status = 0;
            parser->content_length = -1;
            parser->connection_close = 0;
            parser->interim = 0;
            continue;
        }

        parser->header_size = (header_end + 4) - parser->raw->pos;
        parser->headers_done = 1;
    }

    return ngx_http_ffi_client_response_update_body(parser, err, errlen);
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
    resp->body.data = parser->body.data;
    resp->body.len = parser->body.len;

    ngx_http_ffi_client_response_trailers_to_ffi(parser, resp);

    return NGX_OK;
}


void
ngx_http_ffi_client_response_trailers_to_ffi(
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp)
{
    resp->trailers = parser->trailers.elts;
    resp->trailers_len = parser->trailers.nelts;
}


/* status and headers only: the streaming path resumes Lua before the body */
ngx_int_t
ngx_http_ffi_client_response_headers_to_ffi(
    ngx_http_ffi_client_response_parser_t *parser,
    ngx_http_ffi_client_ffi_resp_t *resp, u_char *err, size_t *errlen)
{
    if (!parser->headers_done) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "response headers are incomplete");
    }

    resp->status = parser->status;
    resp->headers = parser->headers.elts;
    resp->headers_len = parser->headers.nelts;
    resp->body.data = (u_char *) "";
    resp->body.len = 0;

    /* trailers only exist once the body has been read to the end */
    resp->trailers = NULL;
    resp->trailers_len = 0;

    return NGX_OK;
}


void
ngx_http_ffi_client_response_stream(
    ngx_http_ffi_client_response_parser_t *parser)
{
    parser->stream = 1;
}


ngx_uint_t
ngx_http_ffi_client_response_pending(
    ngx_http_ffi_client_response_parser_t *parser)
{
    /* every byte fed in is parsed on the spot, so nothing is ever held back */
    (void) parser;

    return 0;
}


void
ngx_http_ffi_client_response_take_chunk(
    ngx_http_ffi_client_response_parser_t *parser, ngx_str_t *chunk)
{
    *chunk = parser->chunk;

    parser->taken += parser->chunk.len;
    parser->chunk.data = NULL;
    parser->chunk.len = 0;
    parser->chunk_ready = 0;
}


/*
 * The peer closed its side. A close-framed message ends here; with a declared
 * content-length a close before that length is a truncated response.
 */
ngx_int_t
ngx_http_ffi_client_response_eof(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *err, size_t *errlen)
{
    (void) pool;

    if (parser->done) {
        return NGX_OK;
    }

    if (parser->headers_done && parser->eof_framed) {
        parser->done = 1;
        return NGX_OK;
    }

    return ngx_http_ffi_client_set_err(err, errlen,
        "upstream closed before complete response");
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
ngx_http_ffi_client_response_append(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *data, size_t len)
{
    size_t       used, size;
    ngx_buf_t  *b;

    if (parser->raw == NULL) {
        size = ngx_max((size_t) 4096, len);
        parser->raw = ngx_create_temp_buf(pool, size);
        if (parser->raw == NULL) {
            return NGX_ERROR;
        }
    }

    used = parser->raw->last - parser->raw->pos;

    if ((size_t) (parser->raw->end - parser->raw->last) < len) {
        size = ngx_max(used + len, used * 2);
        size = ngx_max(size, (size_t) 4096);

        b = ngx_create_temp_buf(pool, size);
        if (b == NULL) {
            return NGX_ERROR;
        }

        b->last = ngx_cpymem(b->last, parser->raw->pos, used);
        parser->raw = b;
    }

    parser->raw->last = ngx_cpymem(parser->raw->last, data, len);

    return NGX_OK;
}


static u_char *
ngx_http_ffi_client_find_header_end(u_char *start, u_char *last)
{
    u_char  *p;

    if (last - start < 4) {
        return NULL;
    }

    for (p = start; p <= last - 4; p++) {
        if (p[0] == CR && p[1] == LF && p[2] == CR && p[3] == LF) {
            return p;
        }
    }

    return NULL;
}


static ngx_int_t
ngx_http_ffi_client_parse_headers(ngx_pool_t *pool,
    ngx_http_ffi_client_response_parser_t *parser, u_char *header_end,
    u_char *err, size_t *errlen)
{
    u_char                             *p, *line_end, *colon, *headers_last;
    u_char                             *key_start, *key_end;
    u_char                             *value_start, *value_end;
    ngx_int_t                           status;
    off_t                               content_length;
    ngx_str_t                           key, value;
    ngx_http_ffi_client_ffi_header_t   *header;

    headers_last = header_end + 2;

    p = parser->raw->pos;
    line_end = ngx_strlchr(p, headers_last, LF);

    if (line_end == NULL || line_end == p || line_end[-1] != CR) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "invalid response status line");
    }

    if (line_end - p < 12
        || ngx_strncmp(p, "HTTP/1.", sizeof("HTTP/1.") - 1) != 0
        || (p[7] != '0' && p[7] != '1')
        || p[8] != ' ')
    {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "invalid response status line");
    }

    status = ngx_atoi(p + 9, 3);
    if (status == NGX_ERROR) {
        return ngx_http_ffi_client_set_err(err, errlen,
                                           "invalid response status");
    }

    parser->status = (ngx_uint_t) status;
    parser->connection_close = p[7] == '0';
    p = line_end + 1;

    while (p < header_end) {
        line_end = ngx_strlchr(p, headers_last, LF);
        if (line_end == NULL || line_end == p || line_end[-1] != CR) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid response header");
        }

        colon = ngx_strlchr(p, line_end - 1, ':');
        if (colon == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid response header");
        }

        key_start = p;
        key_end = colon;
        while (key_end > key_start
               && (key_end[-1] == ' ' || key_end[-1] == '\t'))
        {
            key_end--;
        }

        if (key_end == key_start) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "invalid response header");
        }

        value_start = colon + 1;
        value_end = line_end - 1;

        while (value_start < value_end
               && (*value_start == ' ' || *value_start == '\t'))
        {
            value_start++;
        }

        while (value_end > value_start
               && (value_end[-1] == ' ' || value_end[-1] == '\t'))
        {
            value_end--;
        }

        key.len = key_end - key_start;
        key.data = ngx_pnalloc(pool, key.len);
        if (key.data == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen, "no memory");
        }
        ngx_memcpy(key.data, key_start, key.len);

        value.len = value_end - value_start;
        if (value.len == 0) {
            value.data = (u_char *) "";

        } else {
            value.data = ngx_pnalloc(pool, value.len);
            if (value.data == NULL) {
                return ngx_http_ffi_client_set_err(err, errlen, "no memory");
            }

            ngx_memcpy(value.data, value_start, value.len);
        }

        header = ngx_array_push(&parser->headers);
        if (header == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen, "no memory");
        }

        header->key.data = key.data;
        header->key.len = key.len;
        header->value.data = value.data;
        header->value.len = value.len;

        if (ngx_http_ffi_client_str_eq_lc(&key, "Content-Length")) {
            if (ngx_http_ffi_client_parse_content_length(&value,
                                                         &content_length)
                != NGX_OK)
            {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "invalid content-length");
            }

            if (parser->content_length != -1
                && parser->content_length != content_length)
            {
                return ngx_http_ffi_client_set_err(err, errlen,
                    "conflicting content-length");
            }

            parser->content_length = content_length;
        }

        if (ngx_http_ffi_client_str_eq_lc(&key, "Transfer-Encoding")) {
            if (ngx_http_ffi_client_has_token(&value, "chunked",
                                              sizeof("chunked") - 1))
            {
                return ngx_http_ffi_client_set_err(err, errlen,
                                                   "chunked response is not supported");
            }

            /* any other coding leaves the framing undefined for this backend,
             * and accepting it next to a content-length is how responses get
             * smuggled */
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "transfer-encoding is not supported");
        }

        if (ngx_http_ffi_client_str_eq_lc(&key, "Connection")) {
            /* whole tokens only: "disclose" carries no close token, and a
             * substring match on "keep-alive" could clear a real close */
            if (ngx_http_ffi_client_has_token(&value, "close",
                                              sizeof("close") - 1))
            {
                parser->connection_close = 1;

            } else if (ngx_http_ffi_client_has_token(&value, "keep-alive",
                                                     sizeof("keep-alive") - 1))
            {
                parser->connection_close = 0;
            }
        }

        p = line_end + 1;
    }

    /*
     * An interim response is not the answer: the real one follows it on the
     * same connection, so it is dropped and the parser starts over. 101 is the
     * exception, the connection stops speaking HTTP after it and this client
     * has nothing to hand it over to.
     */
    if (parser->status < 200) {
        if (parser->status == 101) {
            return ngx_http_ffi_client_set_err(err, errlen,
                                               "protocol switch is not supported");
        }

        parser->interim = 1;

        return NGX_OK;
    }

    /*
     * A HEAD response and the bodyless status codes carry the header fields of
     * a body they never send, so the content-length they announce must be
     * ignored rather than waited for.
     */
    if (parser->head || parser->status == 204 || parser->status == 304) {
        parser->content_length = 0;
        return NGX_OK;
    }

    if (parser->content_length == -1) {
        /* no length and no chunked encoding: the body runs to the close */
        parser->eof_framed = 1;
        parser->connection_close = 1;
        parser->content_length = NGX_MAX_OFF_T_VALUE;
    }

    return NGX_OK;
}


static ngx_int_t
ngx_http_ffi_client_parse_content_length(ngx_str_t *value, off_t *out)
{
    off_t    n;
    size_t   i;

    if (value->len == 0) {
        return NGX_ERROR;
    }

    n = 0;

    for (i = 0; i < value->len; i++) {
        if (value->data[i] < '0' || value->data[i] > '9') {
            return NGX_ERROR;
        }

        if (n > (NGX_MAX_OFF_T_VALUE - (value->data[i] - '0')) / 10) {
            return NGX_ERROR;
        }

        n = n * 10 + (value->data[i] - '0');
    }

    *out = n;

    return NGX_OK;
}


static ngx_uint_t
ngx_http_ffi_client_str_eq_lc(ngx_str_t *s, const char *name)
{
    size_t  len;

    len = ngx_strlen((u_char *) name);

    return s->len == len
           && ngx_strncasecmp(s->data, (u_char *) name, len) == 0;
}



static ngx_int_t
ngx_http_ffi_client_response_update_body(
    ngx_http_ffi_client_response_parser_t *parser, u_char *err,
    size_t *errlen)
{
    u_char  *body_start;
    size_t   body_len;

    body_start = parser->raw->pos + parser->header_size;
    body_len = parser->raw->last - body_start;

    if (!parser->eof_framed && body_len > (size_t) parser->content_length) {
        return ngx_http_ffi_client_set_err(err, errlen,
            "response body is larger than content-length");
    }

    parser->body.data = body_start;
    parser->body.len = body_len;

    if (parser->stream && body_len > parser->taken) {
        /* recomputed from taken every time, so a reallocated raw buffer never
         * leaves the span dangling */
        parser->chunk.data = body_start + parser->taken;
        parser->chunk.len = body_len - parser->taken;
        parser->chunk_ready = 1;
    }

    /* a close-framed body has no announced end: only the close finishes it */
    if (!parser->eof_framed && body_len == (size_t) parser->content_length) {
        parser->done = 1;
    }

    return NGX_OK;
}
