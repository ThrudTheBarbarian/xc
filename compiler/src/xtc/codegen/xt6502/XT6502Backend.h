// XT6502Backend.h — emit xt 6502 assembly text for an XTIRModule.
//
// Pure function: input is an IR module, output is `.asm` source ready
// for `bin/osx/xcc-as` to assemble (and `bin/osx/xcc-sim-6502` to simulate).
//
// Coverage matches task #11's lowering subset:
//   - integer arith / bitwise / comparison
//   - SExt / ZExt / Trunc / Bitcast
//   - if / while CFG with phis
//   - direct Call (CallConv::Standard)
//
// Calling convention follows docs/6502/6502-embellishments.md §4
// plus the resolution flagged in STACK-ABI.md §9: caller pushes args
// right-to-left, with HIGH byte first within each multi-byte arg.
// This puts byte 0 (LSB) at the LOWER SP-relative offset in the
// callee — matching the 6502's natural little-endian memory layout.
// Return value: A (low byte), X (high byte) for ≤16-bit returns.
//
// Stack-ABI budget per STACK-ABI.md §6.1: N + K ≤ 119 (where N =
// pinned-locals size, K = total param-byte width). For the trivial
// subset, the lowering doesn't produce pinned locals, so N = 0 and
// the budget is K ≤ 119 — well outside what the four fixtures hit.
// A diagnostic fires if the constraint is ever violated.
//
// Register allocation: every IR value gets a dedicated ZP slot
// drawn from the memory model's `[zp] vars` ranges (defaulting to
// $A0..$FF, 96 bytes, when no model is supplied). Sequential
// allocation walking each range in turn, no recycling — this is the
// equivalent of arm64's "stack slot per value" choice, traded for ZP
// bytes. Optimisation passes land later.
//
// Memory-model awareness (task #55): the backend takes an
// XTMemoryModel and drives placement from it — the ZP var pool from
// `zpVarsRanges`, and a `.code_regions` declaration from
// `mainRegionRanges` so xta's overflow check fires if code+data
// would cross into screen RAM. The model is nullable; a nil model
// falls back to the historical hard-coded $A0..$FF pool and emits no
// `.code_regions` (matching the pre-#55 output exactly).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;
@class XTDiagnosticEngine;
@class XTMemoryModel;

@interface XT6502Backend : NSObject

/// Render `mod` as xt 6502 assembly source for `model`'s memory
/// map. Deterministic — equal modules + models produce byte-identical
/// text. Returns nil on a hard error (frame too large, unsupported
/// opcode); populates `diag` with errors when given. `model` may be
/// nil (falls back to the default $A0..$FF ZP pool, no `.code_regions`).
+ (nullable NSString*)assemblyFromModule:(XTIRModule*)mod
                             memoryModel:(nullable XTMemoryModel*)model
                             diagnostics:(nullable XTDiagnosticEngine*)diag;

@end

NS_ASSUME_NONNULL_END
