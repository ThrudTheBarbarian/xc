// tls_lib.xc — the --emit-lib translation unit for libtls.{so,dylib}.
//
// Pulls in the TLS implementation (xttls.xc: the TlsServer/TlsClient/TlsConn
// classes over the tlsshim C glue) and defines the ABI-gate symbol the loader
// checks. Built + installed to /opt/xcc/3p/tls by install_3p.sh.
//
// NB blewit does NOT use this: blewit links xttls.xc + the shim statically into
// its own binary (see src/build.sh). This wrapper exists only to package the
// module as a first-class 3p shared library for other xtc programs.
#import "xttls.xc"
#import "TlsVersion.xc"

// The library half of the version gate: exports tls_abi_<major>_<minor>, whose
// return value is the patch level. A client's tls_require() references it by
// name, so a minor bump (ABI break) makes the loader reject stale clients.
i32 XTLS_ABI_SYM(void) { return (i32)XTLS_PATCH; }
