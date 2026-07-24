#include "ngx_http_ffi_client.h"


struct ngx_http_ffi_client_keepalive_item_s {
    ngx_queue_t                         queue;
    ngx_http_ffi_client_keepalive_pool_t *pool;
    ngx_connection_t                   *connection;
    struct sockaddr_storage             sockaddr;
    socklen_t                           socklen;
    ngx_uint_t                          reused;
};


struct ngx_http_ffi_client_keepalive_pool_s {
    ngx_rbtree_node_t                   node;
    ngx_queue_t                         cache;
    ngx_queue_t                         free;
    ngx_uint_t                          size;
    ngx_uint_t                          connections;
    ngx_str_t                           key;
    ngx_http_ffi_client_keepalive_item_t *items;
};


static ngx_int_t ngx_http_ffi_client_set_err(u_char *err, size_t *errlen,
    const char *msg);
static ngx_int_t ngx_http_ffi_client_keepalive_build_key(
    ngx_http_request_t *r, ngx_http_ffi_client_ffi_req_t *req,
    ngx_str_t *key, u_char *err, size_t *errlen);
static ngx_http_ffi_client_keepalive_pool_t *
    ngx_http_ffi_client_keepalive_lookup(ngx_http_ffi_client_main_conf_t *fmcf,
    ngx_str_t *key);
static ngx_http_ffi_client_keepalive_pool_t *
    ngx_http_ffi_client_keepalive_lookup_node(ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel, ngx_rbtree_key_t hash, ngx_str_t *key);
static ngx_http_ffi_client_keepalive_pool_t *
    ngx_http_ffi_client_keepalive_get_pool(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen);
static ngx_uint_t ngx_http_ffi_client_keepalive_match(
    ngx_http_ffi_client_keepalive_item_t *item, ngx_peer_connection_t *peer);
static ngx_uint_t ngx_http_ffi_client_keepalive_bad_connection(
    ngx_connection_t *c);
static void ngx_http_ffi_client_keepalive_close_connection(
    ngx_connection_t *c);
static void ngx_http_ffi_client_keepalive_close_item(
    ngx_http_ffi_client_keepalive_item_t *item);
static void ngx_http_ffi_client_keepalive_dummy_handler(ngx_event_t *ev);
static void ngx_http_ffi_client_keepalive_read_handler(ngx_event_t *ev);
static ngx_int_t ngx_http_ffi_client_keepalive_close_handler(ngx_event_t *ev);


/* Bind the op to its pool. Runs before the peer address is known, so it only
 * needs the request parameters that make up the pool key. */
ngx_int_t
ngx_http_ffi_client_keepalive_bind(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen)
{
    if (ngx_http_ffi_client_keepalive_get_pool(r, op, req, err, errlen)
        == NULL)
    {
        return NGX_ERROR;
    }

    return NGX_OK;
}


ngx_int_t
ngx_http_ffi_client_keepalive_get(ngx_http_ffi_client_op_t *op)
{
    ngx_queue_t                         *q, *next;
    ngx_connection_t                    *c;
    ngx_http_ffi_client_keepalive_item_t *item;
    ngx_http_ffi_client_keepalive_pool_t *pool;

    pool = op->keepalive_pool;
    if (pool == NULL) {
        return NGX_DECLINED;
    }

    for (q = ngx_queue_head(&pool->cache);
         q != ngx_queue_sentinel(&pool->cache);
         q = next)
    {
        next = ngx_queue_next(q);
        item = ngx_queue_data(q, ngx_http_ffi_client_keepalive_item_t, queue);
        c = item->connection;

        if (c == NULL
            || ngx_http_ffi_client_keepalive_bad_connection(c)
            || !ngx_http_ffi_client_keepalive_match(item, &op->peer))
        {
            ngx_queue_remove(q);
            ngx_queue_insert_head(&pool->free, q);
            ngx_http_ffi_client_keepalive_close_item(item);

            if (pool->connections > 0) {
                pool->connections--;
            }

            continue;
        }

        ngx_queue_remove(q);
        ngx_queue_insert_head(&pool->free, q);

        if (c->read->timer_set) {
            ngx_del_timer(c->read);
        }

        c->idle = 0;
        c->data = op;
        c->log = op->r->connection->log;
        c->pool->log = c->log;
        c->read->log = c->log;
        c->write->log = c->log;

        op->peer.connection = c;
        op->peer.cached = 1;
        op->peer.sockaddr = (struct sockaddr *) &item->sockaddr;
        op->peer.socklen = item->socklen;
        /* how many times this connection has been taken out of the pool */
        op->reused = item->reused + 1;
        op->keepalive_counted = 1;

        return NGX_OK;
    }

    return NGX_DECLINED;
}


ngx_int_t
ngx_http_ffi_client_keepalive_save(ngx_http_ffi_client_op_t *op)
{
    ngx_queue_t                         *q;
    ngx_connection_t                    *c;
    ngx_http_ffi_client_keepalive_item_t *item;
    ngx_http_ffi_client_keepalive_pool_t *pool;

    pool = op->keepalive_pool;
    c = op->peer.connection;

    if (pool == NULL || c == NULL) {
        return NGX_ERROR;
    }

    if (ngx_terminate || ngx_exiting
        || ngx_http_ffi_client_keepalive_bad_connection(c)
        || ngx_handle_read_event(c->read, 0) != NGX_OK)
    {
        return NGX_ERROR;
    }

    if (ngx_queue_empty(&pool->free)) {
        if (ngx_queue_empty(&pool->cache)) {
            return NGX_ERROR;
        }

        q = ngx_queue_last(&pool->cache);
        ngx_queue_remove(q);
        item = ngx_queue_data(q, ngx_http_ffi_client_keepalive_item_t, queue);
        ngx_http_ffi_client_keepalive_close_item(item);

    } else {
        q = ngx_queue_head(&pool->free);
        ngx_queue_remove(q);
        item = ngx_queue_data(q, ngx_http_ffi_client_keepalive_item_t, queue);

        if (!op->keepalive_counted) {
            pool->connections++;
        }
    }

    item->connection = c;
    item->socklen = op->peer.socklen;
    item->reused = op->reused;
    ngx_memcpy(&item->sockaddr, op->peer.sockaddr, op->peer.socklen);

    ngx_queue_insert_head(&pool->cache, q);

    op->peer.connection = NULL;
    op->keepalive_counted = 0;

    if (c->read->timer_set) {
        ngx_del_timer(c->read);
    }

    if (c->write->timer_set) {
        ngx_del_timer(c->write);
    }

    if (op->keepalive_idle_timeout) {
        ngx_add_timer(c->read, op->keepalive_idle_timeout);
    }

    c->write->handler = ngx_http_ffi_client_keepalive_dummy_handler;
    c->read->handler = ngx_http_ffi_client_keepalive_read_handler;
    c->data = item;
    c->idle = 1;
    c->log = ngx_cycle->log;
    c->pool->log = ngx_cycle->log;
    c->read->log = ngx_cycle->log;
    c->write->log = ngx_cycle->log;

    if (c->read->ready) {
        return ngx_http_ffi_client_keepalive_close_handler(c->read);
    }

    return NGX_OK;
}


void
ngx_http_ffi_client_keepalive_close_active(ngx_http_ffi_client_op_t *op)
{
    ngx_connection_t  *c;

    c = op->peer.connection;
    if (c == NULL) {
        return;
    }

    ngx_http_ffi_client_keepalive_close_connection(c);
    op->peer.connection = NULL;

    if (op->keepalive_counted && op->keepalive_pool != NULL
        && op->keepalive_pool->connections > 0)
    {
        op->keepalive_pool->connections--;
    }

    op->keepalive_counted = 0;
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
ngx_http_ffi_client_keepalive_build_key(ngx_http_request_t *r,
    ngx_http_ffi_client_ffi_req_t *req, ngx_str_t *key, u_char *err,
    size_t *errlen)
{
    u_char     *p;
    size_t      len, base_len, name_len, ca_len;
    ngx_str_t   base;

    /* base key: explicit pool name, else host:port */
    if (req->keepalive_pool.len != 0) {
        base.data = req->keepalive_pool.data;
        base.len = req->keepalive_pool.len;

    } else {
        base.data = ngx_pnalloc(r->pool, req->host.len + 1 + NGX_INT_T_LEN);
        if (base.data == NULL) {
            return ngx_http_ffi_client_set_err(err, errlen, "no memory");
        }

        p = ngx_cpymem(base.data, req->host.data, req->host.len);
        *p++ = ':';
        p = ngx_sprintf(p, "%ui", req->port);
        base.len = p - base.data;
    }

    name_len = req->ssl ? req->ssl_server_name.len : 0;
    ca_len = req->ssl ? req->ssl_trusted_certificate.len : 0;

    /* Tagged, length-prefixed encoding so a user pool name can never collide
     * with a TLS key:
     * [mode][verify][base_len][base][name_len][name][ca_len][ca].
     * This keeps TLS connections out of plaintext pools and apart by verify
     * mode, SNI, and trusted CA. */
    len = 1 + 1 + sizeof(size_t) + base.len + sizeof(size_t) + name_len
          + sizeof(size_t) + ca_len;

    key->data = ngx_pnalloc(r->pool, len);
    if (key->data == NULL) {
        return ngx_http_ffi_client_set_err(err, errlen, "no memory");
    }

    p = key->data;
    *p++ = req->ssl ? 1 : 0;
    *p++ = (req->ssl && req->ssl_verify) ? 1 : 0;

    base_len = base.len;
    p = ngx_cpymem(p, &base_len, sizeof(size_t));
    p = ngx_cpymem(p, base.data, base.len);

    p = ngx_cpymem(p, &name_len, sizeof(size_t));
    if (name_len) {
        p = ngx_cpymem(p, req->ssl_server_name.data, name_len);
    }

    p = ngx_cpymem(p, &ca_len, sizeof(size_t));
    if (ca_len) {
        p = ngx_cpymem(p, req->ssl_trusted_certificate.data, ca_len);
    }

    key->len = p - key->data;

    return NGX_OK;
}


static ngx_http_ffi_client_keepalive_pool_t *
ngx_http_ffi_client_keepalive_lookup(ngx_http_ffi_client_main_conf_t *fmcf,
    ngx_str_t *key)
{
    ngx_rbtree_key_t  hash;

    hash = ngx_crc32_short(key->data, key->len);

    return ngx_http_ffi_client_keepalive_lookup_node(fmcf->pools.root,
                                                     fmcf->pools.sentinel,
                                                     hash, key);
}


static ngx_http_ffi_client_keepalive_pool_t *
ngx_http_ffi_client_keepalive_lookup_node(ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel, ngx_rbtree_key_t hash, ngx_str_t *key)
{
    ngx_http_ffi_client_keepalive_pool_t  *pool;

    if (node == sentinel) {
        return NULL;
    }

    if (hash < node->key) {
        return ngx_http_ffi_client_keepalive_lookup_node(node->left, sentinel,
                                                         hash, key);
    }

    if (hash > node->key) {
        return ngx_http_ffi_client_keepalive_lookup_node(node->right, sentinel,
                                                         hash, key);
    }

    pool = (ngx_http_ffi_client_keepalive_pool_t *) node;

    if (pool->key.len == key->len
        && ngx_memcmp(pool->key.data, key->data, key->len) == 0)
    {
        return pool;
    }

    pool = ngx_http_ffi_client_keepalive_lookup_node(node->left, sentinel,
                                                     hash, key);
    if (pool != NULL) {
        return pool;
    }

    return ngx_http_ffi_client_keepalive_lookup_node(node->right, sentinel,
                                                     hash, key);
}


static ngx_http_ffi_client_keepalive_pool_t *
ngx_http_ffi_client_keepalive_get_pool(ngx_http_request_t *r,
    ngx_http_ffi_client_op_t *op, ngx_http_ffi_client_ffi_req_t *req,
    u_char *err, size_t *errlen)
{
    size_t                                i;
    ngx_str_t                             key;
    ngx_http_ffi_client_main_conf_t      *fmcf;
    ngx_http_ffi_client_keepalive_pool_t *pool;

    if (ngx_http_ffi_client_keepalive_build_key(r, req, &key, err, errlen)
        != NGX_OK)
    {
        return NULL;
    }

    fmcf = ngx_http_get_module_main_conf(r, ngx_http_ffi_client_module);
    if (fmcf == NULL) {
        ngx_http_ffi_client_set_err(err, errlen, "keepalive is unavailable");
        return NULL;
    }

    pool = ngx_http_ffi_client_keepalive_lookup(fmcf, &key);
    if (pool != NULL) {
        op->keepalive_key = pool->key;
        op->keepalive_pool = pool;
        op->keepalive_idle_timeout = req->keepalive_idle_timeout;
        op->keepalive_pool_size = pool->size;
        return pool;
    }

    pool = ngx_pcalloc(ngx_cycle->pool,
                       sizeof(ngx_http_ffi_client_keepalive_pool_t));
    if (pool == NULL) {
        ngx_http_ffi_client_set_err(err, errlen, "no memory");
        return NULL;
    }

    pool->key.len = key.len;
    pool->key.data = ngx_pnalloc(ngx_cycle->pool, key.len);
    if (pool->key.data == NULL) {
        ngx_http_ffi_client_set_err(err, errlen, "no memory");
        return NULL;
    }

    ngx_memcpy(pool->key.data, key.data, key.len);

    pool->size = req->keepalive_pool_size;
    pool->items = ngx_pcalloc(ngx_cycle->pool,
        sizeof(ngx_http_ffi_client_keepalive_item_t) * pool->size);
    if (pool->items == NULL) {
        ngx_http_ffi_client_set_err(err, errlen, "no memory");
        return NULL;
    }

    ngx_queue_init(&pool->cache);
    ngx_queue_init(&pool->free);

    for (i = 0; i < pool->size; i++) {
        pool->items[i].pool = pool;
        ngx_queue_insert_head(&pool->free, &pool->items[i].queue);
    }

    pool->node.key = ngx_crc32_short(pool->key.data, pool->key.len);
    ngx_rbtree_insert(&fmcf->pools, &pool->node);

    op->keepalive_key = pool->key;
    op->keepalive_pool = pool;
    op->keepalive_idle_timeout = req->keepalive_idle_timeout;
    op->keepalive_pool_size = pool->size;

    return pool;
}


static ngx_uint_t
ngx_http_ffi_client_keepalive_match(
    ngx_http_ffi_client_keepalive_item_t *item, ngx_peer_connection_t *peer)
{
    /* an unresolved host has no address yet: the pool key already pins the
     * host, port and TLS config, so any live connection in it fits */
    if (peer->sockaddr == NULL) {
        return 1;
    }

    return item->socklen == peer->socklen
           && ngx_memn2cmp((u_char *) &item->sockaddr,
                           (u_char *) peer->sockaddr,
                           item->socklen, peer->socklen)
              == 0;
}


static ngx_uint_t
ngx_http_ffi_client_keepalive_bad_connection(ngx_connection_t *c)
{
    return c->close
           || c->read->eof
           || c->read->pending_eof
           || c->read->error
           || c->read->timedout
           || c->write->error
           || c->write->timedout;
}


static void
ngx_http_ffi_client_keepalive_close_connection(ngx_connection_t *c)
{
    if (c->read->timer_set) {
        ngx_del_timer(c->read);
    }

    if (c->write->timer_set) {
        ngx_del_timer(c->write);
    }

    ngx_close_connection(c);
}


static void
ngx_http_ffi_client_keepalive_close_item(
    ngx_http_ffi_client_keepalive_item_t *item)
{
    if (item->connection == NULL) {
        return;
    }

    ngx_http_ffi_client_keepalive_close_connection(item->connection);
    item->connection = NULL;
}


static void
ngx_http_ffi_client_keepalive_dummy_handler(ngx_event_t *ev)
{
    ngx_log_debug0(NGX_LOG_DEBUG_HTTP, ev->log, 0,
                   "http ffi client keepalive dummy handler");
}


static void
ngx_http_ffi_client_keepalive_read_handler(ngx_event_t *ev)
{
    (void) ngx_http_ffi_client_keepalive_close_handler(ev);
}


static ngx_int_t
ngx_http_ffi_client_keepalive_close_handler(ngx_event_t *ev)
{
    int                                  n;
    u_char                               buf[1];
    ngx_connection_t                    *c;
    ngx_http_ffi_client_keepalive_item_t *item;
    ngx_http_ffi_client_keepalive_pool_t *pool;

    c = ev->data;

    if (!c->close && !c->read->timedout) {
        n = c->recv(c, buf, 1);

        if (n == NGX_AGAIN) {
            if (ngx_handle_read_event(c->read, 0) != NGX_OK) {
                goto close;
            }

            return NGX_OK;
        }
    }

close:

    item = c->data;
    pool = item->pool;

    ngx_http_ffi_client_keepalive_close_item(item);
    ngx_queue_remove(&item->queue);
    ngx_queue_insert_head(&pool->free, &item->queue);

    if (pool->connections > 0) {
        pool->connections--;
    }

    return NGX_DECLINED;
}
