#include "ngx_http_ffi_client.h"


static ngx_int_t ngx_http_ffi_client_init(ngx_conf_t *cf);
static void *ngx_http_ffi_client_create_main_conf(ngx_conf_t *cf);
static void ngx_http_ffi_client_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);


static ngx_http_module_t ngx_http_ffi_client_module_ctx = {
    NULL,                         /* preconfiguration */
    ngx_http_ffi_client_init,     /* postconfiguration */

    ngx_http_ffi_client_create_main_conf, /* create main configuration */
    NULL,                         /* init main configuration */

    NULL,                         /* create server configuration */
    NULL,                         /* merge server configuration */

    NULL,                         /* create location configuration */
    NULL                          /* merge location configuration */
};


ngx_module_t ngx_http_ffi_client_module = {
    NGX_MODULE_V1,
    &ngx_http_ffi_client_module_ctx,   /* module context */
    NULL,                              /* module directives */
    NGX_HTTP_MODULE,                   /* module type */
    NULL,                              /* init master */
    NULL,                              /* init module */
    NULL,                              /* init process */
    NULL,                              /* init thread */
    NULL,                              /* exit thread */
    NULL,                              /* exit process */
    NULL,                              /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_int_t
ngx_http_ffi_client_init(ngx_conf_t *cf)
{
    return NGX_OK;
}


static void *
ngx_http_ffi_client_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_ffi_client_main_conf_t  *fmcf;

    fmcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_ffi_client_main_conf_t));
    if (fmcf == NULL) {
        return NULL;
    }

    ngx_rbtree_init(&fmcf->pools, &fmcf->sentinel,
                    ngx_http_ffi_client_rbtree_insert_value);

    return fmcf;
}


static void
ngx_http_ffi_client_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t  **p;

    for ( ;; ) {
        p = (node->key < temp->key) ? &temp->left : &temp->right;

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}
