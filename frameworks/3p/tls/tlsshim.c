// tlsshim.c — thin, reusable Mbed TLS wrapper for the xtc TLS module.
//
// xtc binds to these small functions (see xttls.xc) rather than to Mbed TLS's
// large, version-churning structs: the shim owns the structs (correct sizeof
// from the real headers) and hands xtc opaque handles. Server AND client, so
// both blewit (server) and the XG web-client link the same module.
//
// Built against Mbed TLS 4.x: the RNG comes from PSA (psa_crypto_init()), so
// there is no ctr_drbg/entropy plumbing or mbedtls_ssl_conf_rng().
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/net_sockets.h>
#include <psa/crypto.h>
#include <stdlib.h>

static int g_psa = 0;
static int ensure_psa(void) {
    if (!g_psa) { if (psa_crypto_init() != PSA_SUCCESS) return -1; g_psa = 1; }
    return 0;
}

// ---- server context (one per listener) ----
typedef struct {
    mbedtls_ssl_config conf;
    mbedtls_x509_crt   cert;
    mbedtls_pk_context key;
} xt_tls_server;

void *xt_tls_server_new(const char *cert_path, const char *key_path) {
    if (ensure_psa()) return NULL;
    xt_tls_server *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    mbedtls_ssl_config_init(&s->conf);
    mbedtls_x509_crt_init(&s->cert);
    mbedtls_pk_init(&s->key);
    if (mbedtls_x509_crt_parse_file(&s->cert, cert_path) != 0) goto fail;
    if (mbedtls_pk_parse_keyfile(&s->key, key_path, NULL) != 0) goto fail;
    if (mbedtls_ssl_config_defaults(&s->conf, MBEDTLS_SSL_IS_SERVER,
            MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) goto fail;
    if (mbedtls_ssl_conf_own_cert(&s->conf, &s->cert, &s->key) != 0) goto fail;
    return s;
fail:
    mbedtls_pk_free(&s->key); mbedtls_x509_crt_free(&s->cert);
    mbedtls_ssl_config_free(&s->conf); free(s);
    return NULL;
}

// ---- client context (one, reusable across connections) ----
typedef struct {
    mbedtls_ssl_config conf;
    mbedtls_x509_crt   ca;
    int                have_ca;
} xt_tls_client;

// ca_path may be NULL. With no CA the spike accepts any certificate
// (VERIFY_NONE) — a production client MUST pass a CA bundle so verification is
// REQUIRED. TODO: expose verify mode + hostname checking.
void *xt_tls_client_new(const char *ca_path) {
    if (ensure_psa()) return NULL;
    xt_tls_client *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_x509_crt_init(&c->ca);
    if (mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT,
            MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) { free(c); return NULL; }
    if (ca_path) {
        // A CA was requested. If it can't be loaded, FAIL — never silently
        // downgrade to no verification (that would MITM-expose the caller who
        // asked for verification, e.g. blewit's agemin status check).
        if (mbedtls_x509_crt_parse_file(&c->ca, ca_path) != 0) {
            mbedtls_x509_crt_free(&c->ca);
            mbedtls_ssl_config_free(&c->conf);
            free(c);
            return NULL;
        }
        mbedtls_ssl_conf_ca_chain(&c->conf, &c->ca, NULL);
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        c->have_ca = 1;
    } else {
        // Explicit null CA = accept any cert (dev/spike only).
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);
    }
    return c;
}

// ---- a live TLS connection (server- or client-side) ----
typedef struct {
    mbedtls_ssl_context ssl;
    mbedtls_net_context net;
} xt_tls_conn;

// Allocate a connection + wire the BIO, but DON'T handshake. Shared by the
// blocking and non-blocking entry points.
static xt_tls_conn *conn_alloc(mbedtls_ssl_config *conf, int fd, const char *hostname) {
    xt_tls_conn *co = calloc(1, sizeof(*co));
    if (!co) return NULL;
    mbedtls_ssl_init(&co->ssl);
    mbedtls_net_init(&co->net);
    co->net.fd = fd;
    if (mbedtls_ssl_setup(&co->ssl, conf) != 0) { free(co); return NULL; }
    if (hostname) mbedtls_ssl_set_hostname(&co->ssl, hostname);
    mbedtls_ssl_set_bio(&co->ssl, &co->net, mbedtls_net_send, mbedtls_net_recv, NULL);
    return co;
}

static void *conn_setup(mbedtls_ssl_config *conf, int fd, const char *hostname) {
    xt_tls_conn *co = conn_alloc(conf, fd, hostname);
    if (!co) return NULL;
    int r;
    while ((r = mbedtls_ssl_handshake(&co->ssl)) != 0) {
        if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) {
            mbedtls_ssl_free(&co->ssl); free(co); return NULL;
        }
    }
    return co;
}

// ---- blocking API (simple callers; blocking socket) ----
void *xt_tls_accept(void *server, int fd) {
    return conn_setup(&((xt_tls_server *)server)->conf, fd, NULL);
}
void *xt_tls_connect(void *client, int fd, const char *hostname) {
    return conn_setup(&((xt_tls_client *)client)->conf, fd, hostname);
}

// ---- non-blocking API (event loops; the socket must be O_NONBLOCK) ----
// Create a connection WITHOUT handshaking; drive it with xt_tls_handshake on
// each readable/writable event until it returns 0.
void *xt_tls_wrap_server(void *server, int fd) {
    return conn_alloc(&((xt_tls_server *)server)->conf, fd, NULL);
}
void *xt_tls_wrap_client(void *client, int fd, const char *hostname) {
    return conn_alloc(&((xt_tls_client *)client)->conf, fd, hostname);
}
// 0 = handshake complete; 1 = want read; 2 = want write; -1 = error.
int xt_tls_handshake(void *conn) {
    int r = mbedtls_ssl_handshake(&((xt_tls_conn *)conn)->ssl);
    if (r == 0) return 0;
    if (r == MBEDTLS_ERR_SSL_WANT_READ)  return 1;
    if (r == MBEDTLS_ERR_SSL_WANT_WRITE) return 2;
    return -1;
}
// >0 = bytes; 0 = clean close; -1 = error; -2 = want read; -3 = want write.
// TLS 1.3: a server sends a post-handshake NewSessionTicket; mbedtls surfaces it
// from ssl_read so the app could save it for resumption. We don't resume — the
// ticket is consumed, loop on to the next record (app data or WANT_READ).
int xt_tls_recv(void *conn, unsigned char *buf, int len) {
    mbedtls_ssl_context *ssl = &((xt_tls_conn *)conn)->ssl;
    int r;
    do { r = mbedtls_ssl_read(ssl, buf, len); }
    while (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);
    if (r >= 0) return r;
    if (r == MBEDTLS_ERR_SSL_WANT_READ)  return -2;
    if (r == MBEDTLS_ERR_SSL_WANT_WRITE) return -3;
    if (r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
    return -1;
}
// >0 = bytes accepted; -1 = error; -2 = want read; -3 = want write.
int xt_tls_send(void *conn, const unsigned char *buf, int len) {
    int r = mbedtls_ssl_write(&((xt_tls_conn *)conn)->ssl, buf, len);
    if (r >= 0) return r;
    if (r == MBEDTLS_ERR_SSL_WANT_READ)  return -2;
    if (r == MBEDTLS_ERR_SSL_WANT_WRITE) return -3;
    return -1;
}

// >0 = bytes; 0 = clean close; <0 = error.
int xt_tls_read(void *conn, unsigned char *buf, int len) {
    xt_tls_conn *co = conn; int r;
    do { r = mbedtls_ssl_read(&co->ssl, buf, len); }
    while (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE
           || r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);   // TLS 1.3: skip post-handshake tickets
    return r;
}
// Writes all `len` bytes (blocking). Returns len, or <0 on error.
int xt_tls_write(void *conn, const unsigned char *buf, int len) {
    xt_tls_conn *co = conn; int r, off = 0;
    while (off < len) {
        r = mbedtls_ssl_write(&co->ssl, buf + off, len - off);
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (r <= 0) return r;
        off += r;
    }
    return off;
}
void xt_tls_close(void *conn) {
    xt_tls_conn *co = conn;
    mbedtls_ssl_close_notify(&co->ssl);
    mbedtls_ssl_free(&co->ssl);
    free(co);   // the fd is owned by the caller (xtc closes it)
}
