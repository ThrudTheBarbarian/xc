// TlsVersion.xc — libtls.so is major.minor.patch, and the ABI lives in the SYMBOL NAME.
//
// Follows the XG model exactly (/opt/xcc/3p/xg/xc/XGVersion.xc). A client compiled against
// one libtls and run against another must not jump a stale vtable offset and die as PC=0
// naming neither the library nor the mismatch — so the ABI generation is encoded in a symbol:
//
//   major   a conceptual redesign — a different library, in effect.
//   minor   AN ABI BREAK — a layout moved. A client built against 1.0 CANNOT run on 1.1.
//   patch   compatible: additions and fixes. 1.0.7 satisfies a client that needs 1.0.4.
//
//   major.minor -> THE SYMBOL NAME. libtls defines tls_abi_1_0; a client CALLS it. Bump the
//                  minor and that symbol ceases to exist, so the LOADER refuses the stale
//                  client by name, before main() runs — exact-match by construction, and it
//                  cannot be outrun by a stale layout crashing first.
//   patch       -> A RETURNED NUMBER. tls_abi_1_0() returns the patch level, so a client asks
//                  for a MINIMUM and a newer library still satisfies it.
//
// Bump MINOR whenever a TlsServer/TlsClient/TlsConn field or method offset moves.

#define XTLS_MAJOR 1
#define XTLS_MINOR 0
#define XTLS_PATCH 0

// Build the symbol name from the numbers. The two-level form is required: CAT2 pastes its
// arguments RAW, so CAT expands them first — else the name would come out `tls_abi_XTLS_MAJOR`.
#define XTLS_CAT2(a,b) a##b
#define XTLS_CAT(a,b)  XTLS_CAT2(a,b)
#define XTLS_ABI_SYM   XTLS_CAT(XTLS_CAT(tls_abi_, XTLS_MAJOR), XTLS_CAT(_, XTLS_MINOR))
