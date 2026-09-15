/****************************************************************************\
|* XTM68kBackend.h — IR → Motorola 68000/68030 assembly (Atari ST/TT).
|*
|* The 68k counterpart to XTArm64Backend / XT6502Backend. Walks an
|* XTIRModule and emits Motorola-syntax assembly text for the xta68
|* assembler (which turns it into a GEMDOS $601A executable).
|*
|* Status: bootstrap (M2.0/M2.2). Straight-line integer functions lower
|* via a naive slot-per-SSA-value frame model. Control flow, calls,
|* memory ops and floats are being filled in incrementally.
\****************************************************************************/
#import <Foundation/Foundation.h>

@class XTIRModule;

NS_ASSUME_NONNULL_BEGIN

@interface XTM68kBackend : NSObject

/// Emit assembly for the module. `cpu` is 68000 (default) or 68030; on the
/// 030 the backend may use 32-bit MULS.L/DIVS.L natively instead of runtime
/// helper calls.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu;

/// `hardFloat` = YES emits 68881/68882 FPU instructions (incl. libm
/// transcendentals); NO (default) uses the soft-float runtime so the
/// output runs on a base 68000 ST with no FPU.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu
                      hardFloat:(BOOL)hardFloat;

/// `pic` = YES (on the 68000) emits the GOT/a5 position-independent model:
/// symbolic call/jump/data references go through a Global Offset Table
/// addressed by a5, lifting the ±32KB PC-relative limit so programs over
/// 32KB work (required for MiNT). On 68020+ it's a no-op (32-bit PC-relative
/// is already unbounded PIC).
+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu
                      hardFloat:(BOOL)hardFloat
                            pic:(BOOL)pic;

/// Convenience: 68000.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod;

@end

NS_ASSUME_NONNULL_END
