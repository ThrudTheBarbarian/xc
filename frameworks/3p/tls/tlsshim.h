//
//  tlsshim.h — the public C API of tlsshim.c (an opaque-handle wrapper over
//  Mbed TLS). Vendored from the blewit project (its TLS module) so xcc-sign's
//  Route 1 (App Store Connect over HTTPS) and the general 3p/tls xtc library
//  share one source of truth. The caller never sees an mbedtls_* type.
//

#ifndef XT_TLSSHIM_H
#define XT_TLSSHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// TLS client: verify against `ca_path` (a PEM CA bundle) when non-NULL; a NULL
// CA disables verification (dev only — Route 1 always passes the system bundle).
void *xt_tls_client_new(const char *ca_path);
// TLS server (unused by xcc-sign; part of the shared module).
void *xt_tls_server_new(const char *cert_path, const char *key_path);

// Blocking connect (handshake included) over an already-connected socket `fd`;
// `hostname` drives SNI + certificate hostname verification. Returns a conn.
void *xt_tls_connect(void *client, int fd, const char *hostname);
void *xt_tls_accept(void *server, int fd);

// Non-blocking variants: wrap without handshaking, then drive xt_tls_handshake.
void *xt_tls_wrap_client(void *client, int fd, const char *hostname);
void *xt_tls_wrap_server(void *server, int fd);
int   xt_tls_handshake(void *conn);

int   xt_tls_recv(void *conn, unsigned char *buf, int len);   // one record
int   xt_tls_send(void *conn, const unsigned char *buf, int len);
int   xt_tls_read(void *conn, unsigned char *buf, int len);   // fill (loops)
int   xt_tls_write(void *conn, const unsigned char *buf, int len);  // all
void  xt_tls_close(void *conn);

#ifdef __cplusplus
}
#endif

#endif
