// UXAbi.xc — the CLIENT half of the version gate. Import this in any client of libUXKit.so:
//
//     if (!ux_require((i32)4)) { ...refuse to run... }     // needs >= major.minor.4
//
// Calling it makes the client REFERENCE UXKit_abi_<major>_<minor>. If libUXKit.so has had an ABI
// break since the client was compiled, that symbol is gone and the loader rejects the client
// BY NAME, at load, instead of letting it die as PC=0 in a stale vtable.
//
// The result is CONSUMED on purpose. A call whose value is unused is dead-code eliminated, no
// relocation is emitted, and the gate silently vanishes — which is exactly what happened the
// first time this was built. A guard that can be optimised away is not a guard.
#import "UXVersion.xc"

i32 gXtgPatch;

bool ux_require(i32 minPatch)
    {
    gXtgPatch = UXK_ABI_SYM();    // the ABI reference the loader checks
    return gXtgPatch >= minPatch; // consumed: survives dead-code elimination
    }
