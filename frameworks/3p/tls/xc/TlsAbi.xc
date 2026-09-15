// TlsAbi.xc — the CLIENT half of the version gate for libtls. Import it in any client:
//
//     #use <tls>
//     #import "TlsAbi.xc"
//     if (!tls_require((i32)0)) { ...refuse to run... }     // needs >= major.minor.0
//
// Calling it makes the client REFERENCE tls_abi_<major>_<minor>. If libtls has had an ABI
// break since the client was compiled, that symbol is gone and the loader rejects the client
// BY NAME, at load, instead of letting it die as PC=0 in a rearranged vtable.
//
// The result is CONSUMED on purpose. A call whose value is unused is dead-code eliminated, no
// relocation is emitted, and the gate silently vanishes. A guard that can be optimised away is
// not a guard. (See /opt/xcc/3p/xg/xc/XGAbi.xc — the two hard-won rules are its.)
#import "TlsVersion.xc"

i32 gXtlsPatch;

bool tls_require(i32 minPatch) {
    gXtlsPatch = XTLS_ABI_SYM();      // the ABI reference the loader checks
    return gXtlsPatch >= minPatch;    // consumed: survives dead-code elimination
}
