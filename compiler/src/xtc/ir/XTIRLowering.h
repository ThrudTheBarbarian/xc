// XTIRLowering.h — AST → newIR lowering for the trivial subset.
//
// Subset:
//   - Free functions with integer/bool params and integer/bool/void return.
//   - Integer arithmetic, bitwise, comparison.
//   - Function-local SSA-only variables (no AddrOf, no globals).
//   - if / if-else / while / return.
//   - Direct calls to in-module free functions (CallConv::Standard).
//   - Integer literals.
//
// Out-of-scope features emit a diagnostic and abort lowering for that
// function — the IR is never silently wrong.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;
@class XTProgramNode;
@class XTDiagnosticEngine;

@interface XTIRLowering : NSObject

+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag;

// nativeVarargs: the target uses the native AAPCS va_list (arm9) rather than the
// $04B0 pack buffer — so a variadic call marshals its tail per the C ABI and
// va_start yields a real va_list (which a variadic xtc fn can hand to libc
// vprintf). NO on every other target (they keep the pack buffer).
+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag
                       nativeVarargs:(BOOL)nativeVarargs;

// boundsCheck: -fbounds-check. Emit a runtime bounds check at every subscript.
// A DEBUG mode — never shipped enabled — so it optimises for a small site and a
// useful report, not for speed.
+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag
                       nativeVarargs:(BOOL)nativeVarargs
                         boundsCheck:(BOOL)boundsCheck;

/****************************************************************************\
|* Dispatch protocols through a per-class ITABLE (ProtoDispatch/ProtoLoad)
|* instead of a slot in the flat program-global vtable numbering. On for targets
|* that can be linked as multiple modules (arm9), where a global slot number is
|* unachievable. Mirrors XTSemanticAnalyzer.itableProtocols; see
|* private:docs/Design/protocol-slot-collisions.md.
\****************************************************************************/
+ (void)setItableProtocols:(BOOL)on;
+ (BOOL)itableProtocols;

/****************************************************************************\
|* Race-free static-init once (private:docs/Design/threading.md §9.5). -1 = decide per
|* module — on exactly when the program declares the thread-spawn primitive —
|* 0/1 = forced by -fno-thread-safe-arc / -fthread-safe-arc. Gated because a
|* single-threaded program should pay nothing: same instruction stream as
|* before, so the corpus and the self-hosting differentials do not move.
\****************************************************************************/
+ (void)setThreadSafeStatics:(int)mode;
+ (int)threadSafeStatics;

+ (void)setVtableConforms:(BOOL)on;
+ (BOOL)vtableConforms;

// Runtime-ancestry vtables (parent link at entry 0 + walking downcast). ON for the
// cross-`.so` backends (arm9/arm64/x86_64/win64); OFF for xt6502/m68k, which keep the
// compile-time-subtree downcast and a parent-free vtable.
+ (void)setVtableAncestry:(BOOL)on;
+ (BOOL)vtableAncestry;

@end

NS_ASSUME_NONNULL_END
