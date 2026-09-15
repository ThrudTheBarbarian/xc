// XTArm64Backend.h — emit AArch64 (arm64) assembly text for an
// XTIRModule. Pure function: input is an IR module, output is `.s`
// source ready for `clang -arch arm64` to assemble + link.
//
// Coverage matches task #11's lowering subset:
//   - integer arith / bitwise / comparison
//   - SExt / ZExt / Trunc / Bitcast
//   - if / while CFG with phis
//   - direct Call (CallConv::Standard)
//
// Memory tokens are phantoms — they thread through the IR but emit
// no instructions. The trivial subset has no Load/Store.
//
// Implementation choice: every IR value (including parameters and
// memory tokens) gets its own 32-bit stack slot. The emitter
// load → op → canonicalize → store for each instruction. Slow but
// obviously correct; optimisation passes land later.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

@interface XTArm64Backend : NSObject

/// Render `mod` as an AArch64 assembly source string suitable for
/// `clang -arch arm64 -c <out>.s`. Deterministic — equal modules
/// produce byte-identical output.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod;

/// Thread-safe ARC: emit the refcount update as an ATOMIC read-modify-write
/// instead of the plain load/add/store (private:docs/Design/threading.md §4.1).
///
/// The decision is made per module inside `assemblyFromModule:` — atomic
/// exactly when the module spawns a thread — so every caller gets it, whether
/// the backend is driven by xtcg-arm64 or in-process by the corpus sweep. This
/// override forces the answer: 1 = always atomic, 0 = never, -1 (the default)
/// = decide from the module. It is what `-fthread-safe-arc` /
/// `-fno-thread-safe-arc` set.
+ (void)setThreadSafeARCOverride:(NSInteger)mode;

// Use the plain AAPCS64 argument rules instead of Darwin's two deviations from
// them. Set for `-A android`; left off, the Darwin rules stand, which is what
// macOS and iOS want. The two differences, both invisible until they aren't:
//
//   * the C-variadic TAIL. Darwin puts the whole tail on the stack however many
//     argument registers remain; AAPCS64 places a variadic argument exactly
//     like a named one. A call made the Darwin way hands the callee its
//     arguments in places it never looks, and printf prints garbage.
//   * STACK SLOT SIZE. Darwin packs an overflow argument to its natural size;
//     AAPCS64 gives every one an 8-byte slot. This only bites past the eighth
//     argument of a class, which is exactly where a C-variadic call with a long
//     tail ends up — so the two deviations are usually hit by the same call.
+ (void)setAapcs64Abi:(BOOL)on;

// Whether the target is guaranteed to have LSE (the ARMv8.1 large-system atomic
// instructions). Apple Silicon is ARMv8.5, so `ldaddlh`/`ldaddalh` are always
// available there and the atomic refcount is one instruction. Android's minSdk
// floor is plain armv8-a, where they are NOT: the NDK assembler rejects them
// outright ("instruction requires: lse"), and a device without them would take
// SIGILL — which an emulator running on an ARMv8.5 host would never show. Off,
// the same atomic becomes an ldaxrh/stlxrh loop.
+ (void)setLseAtomics:(BOOL)on;

/// What the last `assemblyFromModule:` actually decided. For tests.
+ (BOOL)threadSafeARC;

@end

NS_ASSUME_NONNULL_END
