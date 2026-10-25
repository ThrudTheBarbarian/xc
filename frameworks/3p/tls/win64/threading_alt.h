/* threading_alt.h — Mbed TLS's platform mutex and condition variable for
 * win64 (MBEDTLS_THREADING_ALT, tls_win64_config.h): an SRWLOCK and a
 * CONDITION_VARIABLE, each one pointer, declared without <windows.h>. The
 * shim (tlsshim.c) supplies the functions over them. */
#ifndef XT_TLS_THREADING_ALT_H
#define XT_TLS_THREADING_ALT_H
typedef struct { void *opaque; } mbedtls_platform_mutex_t;
typedef struct { void *opaque; } mbedtls_platform_condition_variable_t;
#endif
