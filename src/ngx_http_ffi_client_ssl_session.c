#include "ngx_http_ffi_client.h"


#if (NGX_SSL)

/*
 * Client-side TLS session resumption.
 *
 * Every https connection this module opens starts a full handshake unless it
 * can offer the server a session from an earlier one. The sessions live in a
 * per-worker cache keyed by the TLS peer; a fresh connection offers the entry
 * for its key before the handshake and the entry is refilled once the peer
 * hands a new session back.
 *
 * OpenSSL reports client sessions through the new-session callback rather than
 * at handshake completion, which is what makes TLS 1.3 work here: its tickets
 * arrive after the handshake, on the first read, and a client that only saved
 * at handshake time would silently never resume on TLS 1.3.
 *
 * The connection carries its cache key in SSL ex_data, not a pointer to the
 * cache entry: an entry can be evicted and reused for another peer while the
 * connection that filled it is still open, and a stale pointer would then
 * publish a session under the wrong key.
 */

typedef struct {
    /* keyed by the crc32 of key, so equal hashes are compared in full */
    ngx_rbtree_node_t                        node;
    /* the LRU list while in use, the free list while not */
    ngx_queue_t                              queue;
    ngx_str_t                                key;
    SSL_SESSION                             *session;
} ngx_http_ffi_client_ssl_session_entry_t;


struct ngx_http_ffi_client_ssl_session_cache_s {
    ngx_rbtree_t                             rbtree;
    ngx_rbtree_node_t                        sentinel;
    ngx_queue_t                              lru;
    ngx_queue_t                              free;
    ngx_http_ffi_client_ssl_session_entry_t *entries;
};


/* what one connection needs to publish its session, hung off its SSL object */
typedef struct {
    ngx_http_ffi_client_ssl_session_cache_t *cache;
    ngx_str_t                                key;
    /* a session the peer sent before the handshake was accepted */
    SSL_SESSION                             *held;
    ngx_log_t                               *log;
    unsigned                                 accepted:1;
} ngx_http_ffi_client_ssl_session_conn_t;


static ngx_http_ffi_client_ssl_session_cache_t *
    ngx_http_ffi_client_ssl_session_cache(ngx_http_ffi_client_op_t *op);
static ngx_int_t ngx_http_ffi_client_ssl_session_key(
    ngx_http_ffi_client_op_t *op, ngx_connection_t *c, ngx_str_t *key);
static ngx_http_ffi_client_ssl_session_entry_t *
    ngx_http_ffi_client_ssl_session_lookup(
    ngx_http_ffi_client_ssl_session_cache_t *cache, ngx_str_t *key);
static ngx_http_ffi_client_ssl_session_entry_t *
    ngx_http_ffi_client_ssl_session_lookup_node(ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel, ngx_rbtree_key_t hash, ngx_str_t *key);
static void ngx_http_ffi_client_ssl_session_store(
    ngx_http_ffi_client_ssl_session_conn_t *sc, SSL_SESSION *session);
static void ngx_http_ffi_client_ssl_session_drop(
    ngx_http_ffi_client_ssl_session_cache_t *cache,
    ngx_http_ffi_client_ssl_session_entry_t *entry);
static ngx_uint_t ngx_http_ffi_client_ssl_session_expired(
    SSL_SESSION *session);
static int ngx_http_ffi_client_ssl_session_new(ngx_ssl_conn_t *ssl_conn,
    SSL_SESSION *session);
static void ngx_http_ffi_client_ssl_session_cleanup(void *data);


/* SSL ex_data slot holding ngx_http_ffi_client_ssl_session_conn_t */
static int  ngx_http_ffi_client_ssl_session_index = -1;


/*
 * Arm a client SSL_CTX to report the sessions its connections are given.
 * NO_INTERNAL keeps OpenSSL from holding its own copies: this cache is the only
 * one, so eviction and expiry stay in one place.
 */
ngx_int_t
ngx_http_ffi_client_ssl_session_cache_enable(ngx_ssl_t *ssl, ngx_log_t *log)
{
    if (ngx_http_ffi_client_ssl_session_index == -1) {
        ngx_http_ffi_client_ssl_session_index =
            SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);

        if (ngx_http_ffi_client_ssl_session_index == -1) {
            ngx_ssl_error(NGX_LOG_ALERT, log, 0,
                          "SSL_get_ex_new_index() failed");
            return NGX_ERROR;
        }
    }

    SSL_CTX_set_session_cache_mode(ssl->ctx,
                                   SSL_SESS_CACHE_CLIENT
                                   |SSL_SESS_CACHE_NO_INTERNAL);

    SSL_CTX_sess_set_new_cb(ssl->ctx, ngx_http_ffi_client_ssl_session_new);

    return NGX_OK;
}


/*
 * Offer this connection the cached session for its peer, and leave behind what
 * the new-session callback needs to fill the entry again.
 */
ngx_int_t
ngx_http_ffi_client_ssl_session_offer(ngx_http_ffi_client_op_t *op,
    ngx_connection_t *c)
{
    ngx_str_t                                key;
    ngx_pool_cleanup_t                      *cln;
    ngx_http_ffi_client_ssl_session_conn_t  *sc;
    ngx_http_ffi_client_ssl_session_cache_t *cache;
    ngx_http_ffi_client_ssl_session_entry_t *entry;

    cache = ngx_http_ffi_client_ssl_session_cache(op);
    if (cache == NULL) {
        return NGX_ERROR;
    }

    if (ngx_http_ffi_client_ssl_session_key(op, c, &key) != NGX_OK) {
        return NGX_ERROR;
    }

    sc = ngx_pcalloc(c->pool, sizeof(ngx_http_ffi_client_ssl_session_conn_t));
    if (sc == NULL) {
        return NGX_ERROR;
    }

    sc->cache = cache;
    sc->key = key;
    sc->log = ngx_cycle->log;

    /* a connection that dies before its session is published still owns it */
    cln = ngx_pool_cleanup_add(c->pool, 0);
    if (cln == NULL) {
        return NGX_ERROR;
    }

    cln->handler = ngx_http_ffi_client_ssl_session_cleanup;
    cln->data = sc;

    if (SSL_set_ex_data(c->ssl->connection,
                        ngx_http_ffi_client_ssl_session_index, sc)
        == 0)
    {
        ngx_ssl_error(NGX_LOG_ALERT, c->log, 0, "SSL_set_ex_data() failed");
        return NGX_ERROR;
    }

    entry = ngx_http_ffi_client_ssl_session_lookup(cache, &key);
    if (entry == NULL) {
        return NGX_OK;
    }

    if (ngx_http_ffi_client_ssl_session_expired(entry->session)) {
        ngx_http_ffi_client_ssl_session_drop(cache, entry);
        return NGX_OK;
    }

    /* a session the peer no longer knows only costs a full handshake, so a
     * refused one is not worth failing the request over */
    (void) ngx_ssl_set_session(c, entry->session);

    ngx_queue_remove(&entry->queue);
    ngx_queue_insert_head(&cache->lru, &entry->queue);

    return NGX_OK;
}


/*
 * The handshake was accepted: publish its session. Until this runs a session is
 * only held, so a peer this client rejected never leaves one behind for the
 * next request to resume.
 */
void
ngx_http_ffi_client_ssl_session_commit(ngx_connection_t *c)
{
    SSL_SESSION                             *session;
    ngx_http_ffi_client_ssl_session_conn_t  *sc;

    if (ngx_http_ffi_client_ssl_session_index == -1
        || c->ssl == NULL
        || c->ssl->connection == NULL)
    {
        return;
    }

    sc = SSL_get_ex_data(c->ssl->connection,
                         ngx_http_ffi_client_ssl_session_index);
    if (sc == NULL) {
        return;
    }

    sc->accepted = 1;

    session = sc->held;
    if (session == NULL) {
        return;
    }

    sc->held = NULL;
    ngx_http_ffi_client_ssl_session_store(sc, session);
}


/* The worker's cache, built on first use and kept for the life of the worker. */
static ngx_http_ffi_client_ssl_session_cache_t *
ngx_http_ffi_client_ssl_session_cache(ngx_http_ffi_client_op_t *op)
{
    ngx_uint_t                               i;
    ngx_http_ffi_client_main_conf_t         *fmcf;
    ngx_http_ffi_client_ssl_session_cache_t *cache;

    fmcf = ngx_http_get_module_main_conf(op->r, ngx_http_ffi_client_module);
    if (fmcf == NULL) {
        return NULL;
    }

    if (fmcf->ssl_sessions != NULL) {
        return fmcf->ssl_sessions;
    }

    cache = ngx_pcalloc(ngx_cycle->pool,
                        sizeof(ngx_http_ffi_client_ssl_session_cache_t));
    if (cache == NULL) {
        return NULL;
    }

    cache->entries = ngx_pcalloc(ngx_cycle->pool,
        sizeof(ngx_http_ffi_client_ssl_session_entry_t)
        * NGX_HTTP_FFI_CLIENT_SSL_SESSION_CACHE_SIZE);
    if (cache->entries == NULL) {
        return NULL;
    }

    ngx_rbtree_init(&cache->rbtree, &cache->sentinel, ngx_rbtree_insert_value);
    ngx_queue_init(&cache->lru);
    ngx_queue_init(&cache->free);

    for (i = 0; i < NGX_HTTP_FFI_CLIENT_SSL_SESSION_CACHE_SIZE; i++) {
        ngx_queue_insert_head(&cache->free, &cache->entries[i].queue);
    }

    fmcf->ssl_sessions = cache;

    return cache;
}


/*
 * The cache key: verify mode, peer address, SNI, trusted CA.
 *
 * A resumed handshake skips the certificate exchange and answers
 * SSL_get_verify_result() from the session, so every input the handshake was
 * judged on has to be part of the key. That makes it at least as strict as the
 * keepalive pool key, which is tagged the same way except that it groups by the
 * caller's pool name; a session is keyed by the address actually connected to,
 * so a pool that spans peers still resumes each one only against itself.
 *
 * The CA is folded away with verify off, matching the SSL_CTX cache: nothing
 * reads it there either, and keying on it would split the cache per caller for
 * no gain.
 */
static ngx_int_t
ngx_http_ffi_client_ssl_session_key(ngx_http_ffi_client_op_t *op,
    ngx_connection_t *c, ngx_str_t *key)
{
    u_char  *p;
    size_t   len, addr_len, name_len, ca_len;

    addr_len = op->peer_name.len;
    name_len = op->ssl_server_name.len;
    ca_len = op->ssl_verify ? op->ssl_trusted_certificate.len : 0;

    /* tagged, length-prefixed so no two different keys can encode alike */
    len = 1 + sizeof(size_t) + addr_len + sizeof(size_t) + name_len
          + sizeof(size_t) + ca_len;

    key->data = ngx_pnalloc(c->pool, len);
    if (key->data == NULL) {
        return NGX_ERROR;
    }

    p = key->data;
    *p++ = op->ssl_verify ? 1 : 0;

    p = ngx_cpymem(p, &addr_len, sizeof(size_t));
    if (addr_len) {
        p = ngx_cpymem(p, op->peer_name.data, addr_len);
    }

    p = ngx_cpymem(p, &name_len, sizeof(size_t));
    if (name_len) {
        p = ngx_cpymem(p, op->ssl_server_name.data, name_len);
    }

    p = ngx_cpymem(p, &ca_len, sizeof(size_t));
    if (ca_len) {
        p = ngx_cpymem(p, op->ssl_trusted_certificate.data, ca_len);
    }

    key->len = p - key->data;

    return NGX_OK;
}


static ngx_http_ffi_client_ssl_session_entry_t *
ngx_http_ffi_client_ssl_session_lookup(
    ngx_http_ffi_client_ssl_session_cache_t *cache, ngx_str_t *key)
{
    ngx_rbtree_key_t  hash;

    hash = ngx_crc32_short(key->data, key->len);

    return ngx_http_ffi_client_ssl_session_lookup_node(cache->rbtree.root,
                                                       cache->rbtree.sentinel,
                                                       hash, key);
}


static ngx_http_ffi_client_ssl_session_entry_t *
ngx_http_ffi_client_ssl_session_lookup_node(ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel, ngx_rbtree_key_t hash, ngx_str_t *key)
{
    ngx_http_ffi_client_ssl_session_entry_t  *entry;

    if (node == sentinel) {
        return NULL;
    }

    if (hash < node->key) {
        return ngx_http_ffi_client_ssl_session_lookup_node(node->left, sentinel,
                                                           hash, key);
    }

    if (hash > node->key) {
        return ngx_http_ffi_client_ssl_session_lookup_node(node->right, sentinel,
                                                           hash, key);
    }

    entry = (ngx_http_ffi_client_ssl_session_entry_t *) node;

    if (entry->key.len == key->len
        && ngx_memcmp(entry->key.data, key->data, key->len) == 0)
    {
        return entry;
    }

    /* equal hashes, different keys: both subtrees may hold the match */
    entry = ngx_http_ffi_client_ssl_session_lookup_node(node->left, sentinel,
                                                        hash, key);
    if (entry != NULL) {
        return entry;
    }

    return ngx_http_ffi_client_ssl_session_lookup_node(node->right, sentinel,
                                                       hash, key);
}


/*
 * Put a session in the cache under this connection's key, taking over the
 * reference the caller holds. A full cache gives up its least recently used
 * entry.
 */
static void
ngx_http_ffi_client_ssl_session_store(
    ngx_http_ffi_client_ssl_session_conn_t *sc, SSL_SESSION *session)
{
    ngx_queue_t                             *q;
    ngx_http_ffi_client_ssl_session_cache_t *cache;
    ngx_http_ffi_client_ssl_session_entry_t *entry;

    cache = sc->cache;

    entry = ngx_http_ffi_client_ssl_session_lookup(cache, &sc->key);

    if (entry != NULL) {
        SSL_SESSION_free(entry->session);
        entry->session = session;

        ngx_queue_remove(&entry->queue);
        ngx_queue_insert_head(&cache->lru, &entry->queue);

        return;
    }

    if (ngx_queue_empty(&cache->free)) {
        q = ngx_queue_last(&cache->lru);
        entry = ngx_queue_data(q, ngx_http_ffi_client_ssl_session_entry_t,
                               queue);
        ngx_http_ffi_client_ssl_session_drop(cache, entry);
    }

    q = ngx_queue_head(&cache->free);
    entry = ngx_queue_data(q, ngx_http_ffi_client_ssl_session_entry_t, queue);

    /* the key outlives the connection it was built on, so it gets its own
     * allocation, freed when the entry is dropped */
    entry->key.data = ngx_alloc(sc->key.len, sc->log);
    if (entry->key.data == NULL) {
        SSL_SESSION_free(session);
        return;
    }

    ngx_memcpy(entry->key.data, sc->key.data, sc->key.len);
    entry->key.len = sc->key.len;
    entry->session = session;
    entry->node.key = ngx_crc32_short(entry->key.data, entry->key.len);

    ngx_rbtree_insert(&cache->rbtree, &entry->node);

    ngx_queue_remove(q);
    ngx_queue_insert_head(&cache->lru, q);
}


/* Empty an entry and hand it back to the free list. */
static void
ngx_http_ffi_client_ssl_session_drop(
    ngx_http_ffi_client_ssl_session_cache_t *cache,
    ngx_http_ffi_client_ssl_session_entry_t *entry)
{
    SSL_SESSION_free(entry->session);
    entry->session = NULL;

    ngx_free(entry->key.data);
    entry->key.data = NULL;
    entry->key.len = 0;

    ngx_rbtree_delete(&cache->rbtree, &entry->node);

    ngx_queue_remove(&entry->queue);
    ngx_queue_insert_head(&cache->free, &entry->queue);
}


/*
 * Offering a session the peer has timed out only costs a round trip, but an
 * entry nothing asks for again would sit there for the life of the worker, so
 * expiry is checked where it is cheap: on the way out.
 */
static ngx_uint_t
ngx_http_ffi_client_ssl_session_expired(SSL_SESSION *session)
{
    time_t  started;

#if (OPENSSL_VERSION_NUMBER >= 0x30400000L && !defined LIBRESSL_VERSION_NUMBER)
    started = SSL_SESSION_get_time_ex(session);
#else
    started = (time_t) SSL_SESSION_get_time(session);
#endif

    return started + (time_t) SSL_SESSION_get_timeout(session) <= ngx_time();
}


/*
 * OpenSSL hands over a session: at handshake completion on TLS 1.2, and with
 * every ticket the peer sends afterwards on TLS 1.3. Returning 1 keeps the
 * reference, which the cache then owns.
 */
static int
ngx_http_ffi_client_ssl_session_new(ngx_ssl_conn_t *ssl_conn,
    SSL_SESSION *session)
{
    ngx_http_ffi_client_ssl_session_conn_t  *sc;

    sc = SSL_get_ex_data(ssl_conn, ngx_http_ffi_client_ssl_session_index);

    /* no ex_data: this caller turned resumption off */
    if (sc == NULL) {
        return 0;
    }

#if (OPENSSL_VERSION_NUMBER >= 0x10101000L && !defined LIBRESSL_VERSION_NUMBER)
    if (!SSL_SESSION_is_resumable(session)) {
        return 0;
    }
#endif

    if (!sc->accepted) {
        SSL_SESSION_free(sc->held);
        sc->held = session;
        return 1;
    }

    ngx_http_ffi_client_ssl_session_store(sc, session);

    return 1;
}


static void
ngx_http_ffi_client_ssl_session_cleanup(void *data)
{
    ngx_http_ffi_client_ssl_session_conn_t  *sc = data;

    SSL_SESSION_free(sc->held);
    sc->held = NULL;
}

#endif
