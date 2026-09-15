#import <Foundation/Foundation.h>
#import "XTIRModule.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* XTWasmBackend — IR → WebAssembly text (WAT).
|*
|* Deliberately the clean, obviously-correct bring-up form from
|* private:docs/Design/wasm-target.md §2: every function is one `loop` wrapping a
|* `br_table` on a $pc local (one arm per IR block), values live in wasm
|* locals unless they escape (then a linear-memory shadow-frame slot off the
|* mutable global $__sp, with a __stack_low limit check on entry — the shadow
|* stack has no guard page, §3). Phis demote to parallel copies on
|* predecessor edges. Struct offsets come VERBATIM from the recorded IR
|* layout (blewit #5 / Task #1084) — this backend never re-derives an offset.
|*
|* The output is assembled by xcc-ln-wasm32 (in-house — no wat2wasm), which
|* also writes the JS loader that runs the module under Node.js or a browser.
\****************************************************************************/
@interface XTWasmBackend : NSObject

/****************************************************************************\
|* Emit the whole module as WAT text. Deterministic: equal modules produce
|* byte-identical output.
\****************************************************************************/
+ (NSString*)assemblyFromModule:(XTIRModule*)mod;

/****************************************************************************\
|* Thread-safe ARC: -1 = decide per module (references _xt_thread_create),
|* 0/1 = forced off/on by -f[no-]thread-safe-arc. Decided as the FIRST thing
|* assemblyFromModule: does, because the backend has two callers (the xtcg
|* process and the in-process corpus sweep) and a decision made in only one
|* is one the other silently gets wrong. (No wasm threads yet — the flag
|* selects i32.atomic.rmw forms when they land.)
\****************************************************************************/
+ (void)setThreadSafeARCOverride:(NSInteger)mode;
+ (BOOL)threadSafeARC;

/****************************************************************************\
|* Optimisation level (default 0). At -O1+ every reducible function is
|* emitted as REAL structured control flow — nested block/loop/if with
|* br/br_if — via a dominator-tree relooper (wasm-target.md §2's "real
|* form"). -O0 keeps the br_table dispatch loop byte-for-byte (the wasm-diff
|* oracle form), and an irreducible CFG falls back to it per function. Same
|* class-setter pattern as the thread-safe-ARC override, and for the same
|* reason: the backend's callers (the xtcg process, the codegen tests) must
|* all reach the SAME switch.
\****************************************************************************/
+ (void)setOptLevel:(NSInteger)level;
+ (void)setTailCalls:(BOOL)on; // -x-wasm32,return-call

/****************************************************************************\
|* Multi-module modes (W2, wasm-target.md §12 #4 — dylink-shaped):
|* setEmitLib: this module is a LIBRARY — relocatable codegen (imports
|* env.memory / env.__indirect_function_table / __memory_base / __table_base
|* / the shared __sp+__stack_low, one data segment at __memory_base, elem at
|* __table_base, no runtime, every function exported, __addr_ getters and
|* __wasm_apply_relocs for the words data segments cannot compute).
|* setLinkLibs: this module is an APP that #imports .wasm libraries — it
|* exports memory/table/runtime/stack globals for the loader to wire each
|* library to, and resolves library symbols through package imports.
\****************************************************************************/
+ (void)setEmitLib:(BOOL)on;
+ (void)setLinkLibs:(BOOL)on;

@end

NS_ASSUME_NONNULL_END
