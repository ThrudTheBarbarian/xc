#import <Foundation/Foundation.h>
#import "XTIRModule.h"

@class XTMemoryModel;

NS_ASSUME_NONNULL_BEGIN

// Shared runtime/wrapping emitter for the new-IR pipeline.
//
// The corpus harness (tests/corpus/XTCorpusSweep.m) and the production driver
// (XTCompilerDriver) both need to take the raw backend-generated 6502 asm and
// wrap it with:
//   - the xt6502 startup / runtime harness template (ZP layout, software
//     stack, retain/release stubs, bump heap, _xcall trampoline);
//   - per-class `__xtc_new_<T>` allocator stubs routed through the real
//     free-list `_heap_alloc16`;
//   - unbanked thunks for the banked float/double arithmetic runtime;
//   - the user's backend asm.
//
// Factored out of XTCorpusSweep.m so both call sites share a single source
// of truth — and the driver's `-fnew-ir -m xt` output becomes a complete
// assembleable program identical in structure to what the corpus produces.
@interface XTIRRuntimeEmitter : NSObject

/****************************************************************************\
|* Load a runtime-template asm file. Tries the path verbatim first (cwd =
|* project root, the usual case from `make test` / `make corpus`), then a
|* sibling `../` fallback for runners that cwd into tests/. Returns @"" if
|* the file is missing.
\****************************************************************************/
+ (NSString*)readTemplateAtPath:(NSString*)relPath;

/****************************************************************************\
|* Set the xtc home root that `readTemplateAtPath:` resolves against (so the
|* runtime harness + asm templates are found regardless of the caller's cwd).
|* Pass the value resolved from -H / $XTC_HOME. nil restores cwd-relative.
\****************************************************************************/
+ (void)setSupportRoot:(nullable NSString*)root;

/****************************************************************************\
|* What the startup does when main returns (xcc -Q). NO, the default, keeps
|* the harness's `RTS` back to the loader; YES replaces it with a jump to
|* itself (`-Q loop`), so the machine spins.
\****************************************************************************/
+ (void)setQuitLoop:(BOOL)loop;

/****************************************************************************\
|* Append the standard `_<name>:` thunks for a set of banked-runtime entry
|* points (task #121). Each thunk trampolines through the harness's `_xcall`
|* into the banked label `<name>`, selecting bank `<bankSymbol>` — a
|* `__bank_<id>` value xta publishes for the matching `.bank <id>` region.
\****************************************************************************/
+ (void)appendBankedRuntimeThunksInto:(NSMutableString*)out
                           entryNames:(NSArray<NSString*>*)entryNames
                           bankSymbol:(NSString*)bankSymbol;

/****************************************************************************\
|* Wrap raw xt6502 backend asm into a complete program. The result includes
|* the harness template, per-class allocator stubs, banked runtime thunks,
|* and the input `generatedAsm`. `harnessPath` is the path to the runtime
|* template — both call sites pass `support/xt6502/runtime/xt6502-harness.asm`
|* for now (TODO: move under support/ once the runtime template is no
|* longer corpus-flavoured).
\****************************************************************************/
+ (NSString*)wrapXt6502Asm:(NSString*)generatedAsm
                 forModule:(XTIRModule*)mod
               memoryModel:(XTMemoryModel*)model
               harnessPath:(NSString*)harnessPath;

@end

NS_ASSUME_NONNULL_END
