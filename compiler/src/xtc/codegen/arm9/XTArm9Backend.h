// XTArm9Backend.h — emit ARMv7-A (AArch32 / A32) assembly text for an
// XTIRModule, for the Zynq-7020 Cortex-A9 (xtos) target.
//
// This is the FOUNDATION of the A32 backend. It is a clean, obviously-correct
// "every value gets a 32-bit stack slot, load → op → store" emitter — the
// same shape the arm64 backend started from — so instruction selection can
// grow incrementally with the corpus as its regression net.
//
// Coverage so far (the integer/control-flow bring-up subset):
//   - Const, integer arith/bitwise/shift/neg/not, ICmp
//   - SExt / ZExt / Trunc / Bitcast / Copy
//   - Branch / CondBranch / Phi, Return
//   - direct Call (AAPCS32: args r0–r3 then stack, return r0)
// Unhandled opcodes emit a `@ TODO:` marker + a zero placeholder and log to
// stderr, so partial programs still assemble while the backend fills in.
//
// ABI: AAPCS32, -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard (read from the
// Vitis BSP; FP lowering is future work). 32-bit pointers/words.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

@interface XTArm9Backend : NSObject

/// Render `mod` as ARMv7-A (A32) assembly suitable for
/// `arm-none-eabi-gcc -mcpu=cortex-a9 -c <out>.s`. Deterministic.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod;

/// Position-independent code (Tier-2 ET_DYN). When enabled, AddrOf of a symbol
/// loads its address from a literal pool (`ldr rX, =sym`) — a relocation the
/// PIC loader handles (R_ARM_RELATIVE for a local symbol) — instead of the
/// absolute movw/movt (R_ARM_MOVW_ABS_NC, not a permitted dynamic reloc).
/// Internal symbols are also marked `.hidden` so their references stay
/// non-preemptible (RELATIVE, not ABS32/GLOB_DAT); `main` keeps default
/// visibility so the loader finds it in `.dynsym`. Set before
/// assemblyFromModule:. Default NO (Tier-1 static ET_EXEC).
+ (void)setPIC:(BOOL)pic;
+ (BOOL)pic;

/// Thread-safe ARC — the refcount update through the A9's exclusive monitor
/// (`ldrexh`/`strexh`) instead of a plain load/add/store
/// (private:docs/Design/threading.md §4.1). Resolved per module inside
/// assemblyFromModule: — atomic exactly when the module spawns a thread — and
/// forced by this override: 1 = always, 0 = never, -1 (default) = decide.
///
/// XTOS has no in-process thread syscalls yet (threading Phase 3), so today
/// nothing on this target sets the symbol that triggers it; the codegen is here
/// so that when the kernel work lands, the refcount is already correct.
/// `ldrex`/`strex` is deliberately preferred over an interrupt-disable bracket:
/// it is unprivileged, so it works whether the loaded body runs in User or
/// System mode, and it stays correct if the second A9 core is ever brought up.
+ (void)setThreadSafeARCOverride:(NSInteger)mode;
+ (BOOL)threadSafeARC;

/// Library build mode (--emit-lib): keep every function at default (exported)
/// visibility so an app linking this `.so` can resolve the public class API.
/// Set before assemblyFromModule:. Default NO.
+ (void)setEmitLib:(BOOL)lib;

@end

NS_ASSUME_NONNULL_END
