/* tls_win64_config.h — the Mbed TLS user configuration (TF_PSA_CRYPTO_USER_
 * CONFIG_FILE) of the win64 libraries and of the win64 shim, which must agree:
 * the PSA core's mutexes over Windows SRW locks (threading_alt.h, set by the
 * shim before psa_crypto_init), not pthreads, which Windows has only through
 * an extra DLL. Without threading, two connections handshaking at once raced
 * in PSA's shared random generator and key slots (2026-10-24). */
#undef MBEDTLS_THREADING_PTHREAD
#ifndef MBEDTLS_THREADING_C
#define MBEDTLS_THREADING_C
#endif
#define MBEDTLS_THREADING_ALT
