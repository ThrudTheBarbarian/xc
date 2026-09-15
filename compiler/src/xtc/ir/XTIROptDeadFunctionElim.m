#import "XTIROptDeadFunctionElim.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRSymbol.h"

// Library build mode (xtc --emit-lib): the module IS a shared library, so its
// public API is reachable from outside this translation unit even though nothing
// here calls it. Keep every function — the linker/visibility decides what's
// actually exported.
static BOOL sKeepAllFunctions = NO;

@implementation XTIROptDeadFunctionElim

+ (void)setKeepAllFunctions:(BOOL)keep
    {
    sKeepAllFunctions = keep;
    }

- (NSString*)passName
    {
    return @"dead-function-elim";
    }
- (NSInteger)minOptLevel
    {
    return 1;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;

    // Map function-name → XTIRFunction for quick lookup.
    NSMutableDictionary<NSString*, XTIRFunction*>* fnByName =
        [NSMutableDictionary dictionaryWithCapacity:mod.functions.count];
    for (XTIRFunction* fn in mod.functions)
        {
        fnByName[fn.name] = fn;
        }

    // Seed: anything that's an entry point or otherwise visible from
    // outside the IR module. We never remove these.
    NSMutableSet<NSString*>* reachable = [NSMutableSet set];
    NSMutableArray<NSString*>* worklist = [NSMutableArray array];

    void (^seed)(NSString*) = ^(NSString* name) {
      if (name && fnByName[name] && ![reachable containsObject:name])
          {
          [reachable addObject:name];
          [worklist addObject:name];
          }
    };

    // 1. main is the canonical entry point.
    seed(@"main");

    // 1b. Load-time constructors are roots: nothing in the program CALLS them
    // (the backend references each only from the target constructor list, which
    // is emitted after this pass), yet they must survive — and keep alive what
    // they reference (the XG-NIB factory, and through it the reflection helpers).
    for (NSString* initName in mod.moduleInitFunctionNames)
        seed(initName);

    // Library mode: seed EVERY function — the whole module is the API surface.
    if (sKeepAllFunctions)
        {
        for (XTIRFunction* fn in mod.functions)
            seed(fn.name);
        }

    // 2. Any function symbol whose `escapes` flag is set is potentially
    // reachable via a function pointer / indirect call we can't trace.
    // 3. Every vtable's targets are reachable (virtual dispatch we can't
    // statically resolve at the call site).
    // 4. Any symbol whose backing function we don't recognise as a known
    // entry — but which IS a function symbol — is conservatively kept
    // (it might be referenced from inline asm we can't introspect).
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind == XTIRSymbolKindFunction)
            {
            if (sym.escapes)
                seed(sym.name);
            // `extern`-on-a-definition = part of the module's public surface
            // (wasm export). Nothing in-module need call it — the HOST does
            // (wasm-target.md §6: exported is load-bearing on wasm; a
            // DFE-stripped export fails at instance.exports call time, in
            // the browser, far from the build).
            if ([sym.attributes[@"exported"] boolValue])
                seed(sym.name);
            }
        else if (sym.kind == XTIRSymbolKindVTable)
            {
            for (NSString* slotName in sym.vtableEntryNames)
                {
                seed(slotName);
                }
            }
        }

    // Walk the call graph. For each reachable function, scan its insn
    // operands for symbol references and add the targets.
    while (worklist.count > 0)
        {
        NSString* fnName = worklist.lastObject;
        [worklist removeLastObject];
        XTIRFunction* fn = fnByName[fnName];
        if (!fn)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* insn in bb.instructions)
                {
                // Any symbol operand (Sym kind) might be a function ref.
                // We accept call ops AND AddrOf-style references — both
                // indicate the function is alive.
                for (XTIROperand* op in insn.operands)
                    {
                    if (op.kind != XTIROperandKindSym)
                        continue;
                    XTIRSymbol* target = [mod symbolForId:op.symbolId];
                    if (!target)
                        continue;
                    if (target.kind == XTIRSymbolKindFunction)
                        {
                        seed(target.name);
                        }
                    else if (target.kind == XTIRSymbolKindVTable)
                        {
                        for (NSString* slotName in target.vtableEntryNames)
                            {
                            seed(slotName);
                            }
                        }
                    }
                }
            }
        }

    // Drop functions that didn't survive the walk. Keep their symbol
    // entries (the IR's symbol table is referenced by-id elsewhere; a
    // stray symbol entry with a nil .function is benign and would be
    // expensive to renumber). The function bodies are the size driver
    // anyway — dropping them is what shrinks the emitted asm.
    NSMutableArray<XTIRFunction*>* survivors = [NSMutableArray array];
    for (XTIRFunction* fn in mod.functions)
        {
        if ([reachable containsObject:fn.name])
            {
            [survivors addObject:fn];
            }
        }
    if (survivors.count != mod.functions.count)
        {
        [mod.functions removeAllObjects];
        [mod.functions addObjectsFromArray:survivors];
        }
    return YES;
    }

@end
