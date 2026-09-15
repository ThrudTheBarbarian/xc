/****************************************************************************\
|* XTSemanticAnalyzer+Analysis.m
\****************************************************************************/
#import "XTSemanticAnalyzer+Private.h"

@implementation XTSemanticAnalyzer (Analysis)

#pragma mark - Analysis

- (void)analyzeProgram:(XTProgramNode*)program
    {
    // SETTLE struct field offsets before anything reads one.
    //
    // A struct laid out BEFORE a by-value member's type was declared sized that
    // member 0, so every field after it got the member's own offset — they
    // overlapped, silently. The parser fixes the member itself when its real
    // declaration arrives (replaceFields:), but nothing revisited the structs
    // that had already embedded it.
    //
    //     struct Outer { i16 flags; Sbuf bf; i32 lbfsize; }
    //     struct Sbuf  { u8@ base; i32 size; }
    //  => fields=[(0:I16), (2:Agg(0)), (2:I32)]     lbfsize ON TOP of bf
    //
    // Writing `lbfsize` corrupted `bf.base`, and the IR opt passes fold these
    // offsets, so it was not confined to the type system. Found in newlib's
    // `__sFILE`, which embeds three `__sbuf` declared after it: 24 fields
    // collapsed onto 15 offsets. The self-hosted lowering resolves layouts on
    // demand and got it right, which is how the disagreement surfaced.
    //
    // Re-running replaceFields: recomputes offsets from the now-known widths.
    // Iterated to a FIXPOINT because a settled struct changes the width of
    // whatever embeds it, and bounded so a pathological cycle cannot spin.
    for (int round = 0; round < 8; round++)
        {
        BOOL changed = NO;
        for (XTStructType* st in [self.typeTable allStructTypes])
            {
            NSUInteger before = st.byteWidth;
            [st replaceFields:st.fields];
            if (st.byteWidth != before)
                changed = YES;
            }
        if (!changed)
            break;
        }

    // First pass: register all top-level function and class names so forward references work.
    // Group functions by name so we can mangle overload sets.
    NSMutableDictionary<NSString*, NSMutableArray<XTFunctionDeclNode*>*>* fnGroups = [NSMutableDictionary dictionary];
    // Category / extension nodes merged below. They are removed from the program
    // once the walk is done — every later pass then sees only whole classes.
    NSMutableSet<XTASTNode*>* spentParts = [NSMutableSet set];
    for (XTASTNode* decl in program.declarations)
        {
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            NSMutableArray* g = fnGroups[fn.funcName];
            if (!g)
                {
                g = [NSMutableArray array];
                fnGroups[fn.funcName] = g;
                }
            [g addObject:fn];
            // Auto-imported C protos are remembered by name: bare-call
            // resolution demotes them below `use`-promoted statics.
            if (fn.isCImport)
                [self.cImportFunctionNames addObject:fn.funcName];
            }
        else if ([decl isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            // A second definition of the same class is an ERROR, not an
            // overwrite: both bodies were still lowered against one
            // (confused) type and lowering died on the wreckage with an
            // uncaught append-after-terminator exception. (Historically
            // reachable via an import cycle back to the entry file — now
            // also closed in the preprocessor — but any duplicate must
            // fail here, cleanly.)
            XTClassDeclNode* prev = self.classesByName[cls.className];
            // A CATEGORY / EXTENSION merges into the class instead of colliding
            // with it. Methods always; ivars only from an extension `()`, and
            // only when the class is defined HERE — a class that arrived through
            // an interface has already had its size baked into everything that
            // allocates it, which is ObjC's fragile-ivar rule and ObjC's reason
            // for it. private:docs/Design/separate-compilation.md §4.
            if (cls.isCategory)
                {
                if (!prev)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"%@ '%@' extends unknown class '%@' — no declaration of it "
                                                              @"is in scope (import its module or its interface)",
                                                              cls.categoryName.length ? @"Category" : @"Extension",
                                                              cls.categoryName.length ? cls.categoryName : cls.className,
                                                              cls.className]
                                             at:cls.location];
                    continue;
                    }
                if (cls.ivars.count)
                    {
                    if (cls.categoryName.length)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"Category '%@' on '%@' cannot add instance variables — "
                                                                  @"use an extension `class %@ () { … }`, which must be "
                                                                  @"compiled with the class",
                                                                  cls.categoryName, cls.className, cls.className]
                                                 at:cls.location];
                        continue;
                        }
                    if (prev.isExternal)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"Extension cannot add instance variables to '%@': it is "
                                                                  @"defined in another module, whose instance size is already "
                                                                  @"fixed. Methods are fine; ivars need the class's own build",
                                                                  cls.className]
                                                 at:cls.location];
                        continue;
                        }
                    for (XTVariableDeclNode* iv in cls.ivars)
                        [prev appendIvar:iv];
                    }
                // Extending a class from ANOTHER module (§4.2). Two rules, and
                // each of them is a layout the client cannot rewrite:
                //
                //  · a category may not REPLACE a method the class already has:
                //    the library dispatches its own calls through its own vtable
                //    slot, which nothing here can reach, so half the program
                //    would see the override and half would not.
                //  · nor add a protocol conformance: the itable is emitted with
                //    the library's vtable.
                //
                // A LIBRARY extending an imported class is no longer refused:
                // §4.3b's owner anchor makes every extender self-contained, so
                // there is no chain depth left to arbitrate. The former §9
                // ruling ("only the final link may extend") existed only for
                // that ambiguity.
                if (prev.isExternal)
                    {
                    NSString* part = cls.categoryName.length
                                         ? [NSString stringWithFormat:@"Category '%@'", cls.categoryName]
                                         : @"Extension";
                    if (cls.protocolNames.count)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"%@ cannot add protocol conformance to '%@': it is "
                                                                  @"defined in another module, whose conformance table "
                                                                  @"is emitted with it",
                                                                  part, cls.className]
                                                 at:cls.location];
                        [spentParts addObject:cls];
                        continue;
                        }
                    BOOL clash = NO;
                    for (XTMethodDeclNode* m in cls.methods)
                        {
                        for (XTMethodDeclNode* pm in prev.methods)
                            {
                            if (![pm.methodName isEqualToString:m.methodName])
                                continue;
                            [self.diagnostics emitError:[NSString stringWithFormat:
                                                                      @"%@ cannot replace '%@.%@': the class comes from "
                                                                      @"another module, which dispatches that method through "
                                                                      @"its own table. Add a method, don't replace one",
                                                                      part, cls.className, m.methodName]
                                                     at:m.location];
                            clash = YES;
                            break;
                            }
                        }
                    if (clash)
                        {
                        [spentParts addObject:cls];
                        continue;
                        }
                    for (XTMethodDeclNode* m in cls.methods)
                        m.importedCategoryHost = cls.className;
                    // §4.3b: the category NAMES on each host feed the owner
                    // anchor symbol (`<Host>$cat$<names sorted>`), which is
                    // what keeps two modules' fallback tables distinct at the
                    // linker. A method-only anonymous extension contributes
                    // `_ext` — two modules both doing THAT still collide, and
                    // the fix is to name the category.
                    NSMutableSet<NSString*>* names = self->_catNamesByHost[cls.className];
                    if (!names)
                        {
                        names = [NSMutableSet set];
                        self->_catNamesByHost[cls.className] = names;
                        }
                    [names addObject:(cls.categoryName.length ? cls.categoryName : @"_ext")];
                    }
                for (XTMethodDeclNode* m in cls.methods)
                    [prev appendSynthesisedMethod:m];
                for (NSString* pn in cls.protocolNames)
                    [prev appendProtocolConformance:pn];
                [spentParts addObject:cls]; // dropped below; only `prev` survives
                continue;
                }
            if (prev)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Redefinition of class '%@' (previously defined at %@:%lu)",
                                                          cls.className, prev.location.filename,
                                                          (unsigned long)prev.location.line]
                                         at:cls.location];
                continue;
                }
            self.classesByName[cls.className] = cls;
            }
        else if ([decl isKindOfClass:[XTProtocolDeclNode class]])
            {
            XTProtocolDeclNode* p = (XTProtocolDeclNode*)decl;
            self.protocolsByName[p.protocolName] = p;
            }
        else if ([decl isKindOfClass:[XTVariableDeclNode class]])
            {
            // Pre-register top-level variables so forward references
            // from earlier functions resolve — matches how functions,
            // classes, structs, and enum members are handled above.
            // Auto-typed globals still need to be in declaration order
            // (type inference requires visiting the initialiser).
            XTVariableDeclNode* v = (XTVariableDeclNode*)decl;
            if (v.isGlobal && v.declaredType && !v.declaredType.isAuto)
                {
                XTSymbol* sym = [[XTSymbol alloc] initWithName:v.varName
                                                          type:v.declaredType];
                sym.storageClass = XTStorageClassHeap;
                sym.definedAt = v.location;
                if (![self.globalScope lookupLocalSymbol:v.varName])
                    {
                    [self.globalScope defineSymbol:sym];
                    }
                }
            }
        else if ([decl isKindOfClass:[XTEnumDeclNode class]])
            {
            // Pre-register enum members as globals so `c = red;` in a
            // function declared before `enum Color` resolves. The
            // parser already pre-registers the enum NAME so `Color c`
            // parses as a type; sema's original declaration-order
            // pass registered member identifiers lazily in
            // visitEnumDecl, which meant forward constant references
            // hit visitIdentifier's "Undefined identifier" arm.
            XTEnumDeclNode* en = (XTEnumDeclNode*)decl;
            if ([self.registeredEnumNames containsObject:en.enumName])
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"Duplicate enum name '%@'", en.enumName]
                                         at:en.location];
                }
            else
                {
                [self.registeredEnumNames addObject:en.enumName];
                for (XTEnumMemberNode* m in en.members)
                    {
                    XTSymbol* sym = [[XTSymbol alloc] initWithName:m.memberName
                                                              type:[XTType u8Type]];
                    sym.storageClass = XTStorageClassConst;
                    sym.constantValue = @(m.resolvedValue);
                    [self.globalScope defineSymbol:sym];
                    }
                }
            }
        }
    // The merged parts leave the program now, before any other pass walks it.
    [program removeDeclarations:spentParts];
    for (NSString* name in fnGroups)
        {
        NSArray<XTFunctionDeclNode*>* group = fnGroups[name];
        // A body-less declaration is an EXTERNAL C function: one symbol, one
        // signature, C linkage. Two rules follow, both learned from a user
        // redeclaring x86_64 Stdio's `i32 write(i32, u8*, i32)` (the blewit
        // spike): the library's private need for a syscall must never
        // interfere with a program's own declaration of it.
        //
        //   1. IDENTICAL body-less redeclarations MERGE, as repeated C
        //      prototypes do. Stdio declares `write`, the program declares
        //      `write` again with the same signature — that is one function,
        //      not a redefinition.
        //   2. A DIFFERENT-signature overload of a body-less function is
        //      refused with a diagnosis. Overloading mangles EVERY member of
        //      the set — including the C symbol — and the failure used to
        //      surface at link as `undefined symbol: write__i32_p_u64`,
        //      baffling and far from the cause.
        NSString* (^sigOf)(XTFunctionDeclNode*) = ^NSString*(XTFunctionDeclNode* fn) {
          NSMutableArray<NSString*>* ps = [NSMutableArray array];
          for (XTParamNode* p in fn.parameters)
              [ps addObject:p.paramType.displayName ?: @""];
          return [ps componentsJoinedByString:@","];
        };
        if (group.count > 1)
            {
            // Signatures that have a real DEFINITION (a body) in this group.
            NSMutableSet<NSString*>* definedSigs = [NSMutableSet set];
            for (XTFunctionDeclNode* fn in group)
                if (fn.body)
                    [definedSigs addObject:sigOf(fn)];
            NSMutableArray<XTFunctionDeclNode*>* kept = [NSMutableArray array];
            NSMutableSet<NSString*>* seenProtoSigs = [NSMutableSet set];
            for (XTFunctionDeclNode* fn in group)
                {
                if (!fn.body)
                    {
                    NSString* s = sigOf(fn);
                    // rule 1a: a prototype whose signature is DEFINED here is
                    // redundant with the definition — drop it, so a prototype
                    // plus its definition is ONE function, not a spuriously
                    // "overloaded" pair. Otherwise the pair mangles here
                    // (`foo__pCString_i32`) while a TU that sees only the lone
                    // prototype emits the unmangled `foo`, and the two never
                    // meet at link (blewit's cross-unit `gzipBody`).
                    if ([definedSigs containsObject:s])
                        continue;
                    if ([seenProtoSigs containsObject:s])
                        continue; // rule 1b: merge repeats
                    [seenProtoSigs addObject:s];
                    }
                [kept addObject:fn];
                }
            group = kept;
            }
        if (group.count > 1)
            {
            XTFunctionDeclNode* ext = nil;
            for (XTFunctionDeclNode* fn in group)
                if (!fn.body)
                    {
                    ext = fn;
                    break;
                    }
            if (ext)
                {
                NSString* extSig = sigOf(ext);
                NSMutableArray<XTFunctionDeclNode*>* survivors = [NSMutableArray arrayWithObject:ext];
                for (XTFunctionDeclNode* fn in group)
                    {
                    if (fn == ext)
                        continue;
                    if ([sigOf(fn) isEqualToString:extSig])
                        {
                        [survivors addObject:fn];
                        continue;
                        }
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Cannot overload '%@' — it is an external C function "
                                                              @"(declared without a body at %@:%lu), and a C symbol has "
                                                              @"exactly one signature. Use that signature, or wrap the "
                                                              @"call under a different name",
                                                              fn.funcName,
                                                              ext.location.filename.lastPathComponent ?: @"?",
                                                              (unsigned long)ext.location.line]
                                             at:fn.location];
                    }
                // Keep the external declaration (and any same-signature
                // definition) registered so downstream analysis continues;
                // the compile is already failing on the diagnostic above.
                if (survivors.count < group.count)
                    group = survivors;
                }
            }
            // §6's other face (task #31, found by blewit): `extern` on a
            // definition promises the SPELLED name to non-xtc consumers — a wasm
            // export label, a shared-object symbol a C caller looks up. Two
            // extern definitions of one name would have to share that label, so
            // the second is an error: overload freely, but export one.
            {
            XTFunctionDeclNode* firstExp = nil;
            for (XTFunctionDeclNode* fn in group)
                {
                if (!fn.isExported)
                    continue;
                if (!firstExp)
                    {
                    firstExp = fn;
                    continue;
                    }
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Cannot export two overloads of '%@' — `extern` promises "
                                                          @"the name itself to the outside, and both cannot own it. "
                                                          @"The other extern definition is at %@:%lu. Keep `extern` "
                                                          @"on one overload",
                                                          fn.funcName,
                                                          firstExp.location.filename.lastPathComponent ?: @"?",
                                                          (unsigned long)firstExp.location.line]
                                         at:fn.location];
                }
            }
        BOOL overloaded = (group.count > 1);
        for (XTFunctionDeclNode* fn in group)
            {
            NSMutableArray<XTType*>* paramTypes = [NSMutableArray array];
            for (XTParamNode* p in fn.parameters)
                [paramTypes addObject:p.paramType];
            if (overloaded)
                {
                fn.mangledName = [XTLabelGenerator mangleName:fn.funcName
                                                   paramTypes:paramTypes
                                                   returnType:fn.returnTypes.firstObject];
                }
            XTFunctionType* ft = [XTFunctionType functionWithReturnTypes:fn.returnTypes
                                                              paramTypes:paramTypes
                                                               isVarArgs:fn.isVarArgs];
            XTSymbol* sym = [[XTSymbol alloc] initWithName:fn.funcName type:ft];
            sym.mangledName = fn.mangledName;
            sym.storageClass = XTStorageClassFunction;
            sym.definedAt = fn.location;
            // Static-frame eligibility: a function with a nil body is
            // a forward declaration, resolved by the linker against
            // either another translation unit (separate compilation)
            // or pre-compiled asm. Either way the frame size and
            // callees are unknown to us, so the caller must route
            // through the xtc stack. Log the label so the eligibility
            // analyser can flag callers.
            if (!fn.body)
                {
                NSString* key = fn.mangledName ?: fn.funcName;
                [self.externalFunctions addObject:
                                            [@"_fn_" stringByAppendingString:key ?: @""]];
                }
            // Effect table: call sites check this to require a `try` or a
            // `throws` caller. Recorded in the PRE-PASS so a call analysed
            // before the callee's definition still sees the effect.
            if (fn.throwsError)
                {
                if (!self.throwingFunctionKeys)
                    self.throwingFunctionKeys = [NSMutableSet set];
                NSString* k = fn.mangledName ?: fn.funcName;
                if (k)
                    [self.throwingFunctionKeys addObject:k];
                }
            if (![[self currentScope] defineSymbol:sym])
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"Redefinition of '%@' with same parameter types",
                                                                       fn.funcName]
                                         at:fn.location];
                }
            }
        }
    // Resolve each class's declared parent to the parent's
    // XTClassDeclNode, and detect circular inheritance. Must run
    // after every class has been registered in `self.classesByName` (so
    // order-of-declaration doesn't matter) but before the method
    // mangling loop below — future PRs resolve inherited methods
    // through `parentClass` walks. Errors leave `parentClass` nil
    // on the offending node so downstream passes can short-circuit
    // without re-diagnosing.
    [self resolveClassHierarchy];

    // Auto-synthesise `description()` for every user class that
    // doesn't already declare one — Stdio.printf's `%@` formatter
    // dispatches through it, and Object's default returns the bare
    // placeholder `<Object>` for everything. Each synthesised body
    // packs the class's u16-widenable ivars into a heap u16[] and
    // calls `String._classDescribe`, producing `<Name>(v1, v2, …)`
    // text without each class needing to write the method by hand.
    // Skipped silently when String.xc isn't in scope (no helpers to
    // call against) or when the class is the root Object marker.
    [self synthesizeClassDescriptions];

    // Mangle methods within each class (scoped per class).
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        NSMutableDictionary<NSString*, NSMutableArray<XTMethodDeclNode*>*>* mg = [NSMutableDictionary dictionary];
        for (XTMethodDeclNode* m in cls.methods)
            {
            NSMutableArray* g = mg[m.methodName];
            if (!g)
                {
                g = [NSMutableArray array];
                mg[m.methodName] = g;
                }
            [g addObject:m];
            }
        for (NSString* mname in mg)
            {
            NSArray<XTMethodDeclNode*>* group = mg[mname];
            if (group.count < 2)
                continue;
            NSMutableSet<NSString*>* seen = [NSMutableSet set];
            for (XTMethodDeclNode* m in group)
                {
                NSMutableArray<XTType*>* paramTypes = [NSMutableArray array];
                for (XTParamNode* p in m.parameters)
                    [paramTypes addObject:p.paramType];
                NSString* mangled = [XTLabelGenerator mangleName:m.methodName
                                                      paramTypes:paramTypes
                                                      returnType:m.returnTypes.firstObject];
                if ([seen containsObject:mangled])
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:@"Redefinition of '%@.%@' with same parameter types",
                                                                           cls.className, m.methodName]
                                             at:m.location];
                    }
                else
                    {
                    [seen addObject:mangled];
                    }
                m.mangledName = mangled;
                }
            }
        }
    // PR4: with every method's mangled name settled, compute the
    // set of ancestor methods that a descendant overrides. Consumed
    // by visitMethodCallExpr / visitCallExpr to flag statically-
    // ambiguous calls until PR8 wires virtual dispatch.
    [self checkFinalMethods];
    [self computeOverriddenMethods];
    // PR8: assign class ids + vtable slots now that the override
    // set is populated. Classes with no virtual methods get an id
    // (for `new` class-id stamping) but contribute no slots; only
    // virtual calls pay the vtable cost.
    [self computeVirtualMethodTables];
    // PR5: decide which subclass inits need an auto-synthesised
    // super.init() call. Sets XTMethodDeclNode.autoSuperInit where
    // appropriate; emits diagnostics for the "subclass init but
    // parent needs args" shape that can't be auto-chained.
    [self wireSubclassInitChains];
    // PR6: symmetric dealloc-chain wiring. Sets
    // XTMethodDeclNode.autoSuperDealloc on subclass dealloc bodies
    // that don't already call super.dealloc and have an ancestor
    // with a dealloc method. Child-first teardown — codegen emits
    // the super JSR at the END of the body.
    [self wireSubclassDeallocChains];

    // Stamp every varargs function/method with slot 0 — the shared
    // pack-buffer slot at $04B0-$04EF. The pre-4c multi-slot pool is
    // gone; the variadic-reentrance check below guarantees at most one
    // variadic's va_list is live across a call, so the single buffer
    // is safely re-used.
    [self assignVarargsSlots:program];

    // Second pass: analyse bodies
    [self analyzeNode:program];

    // Stage 4c: after body analysis, snapshot the locally stack-using
    // set (so Pass C can tell leaves from intermediates), then run the
    // transitive closure of `self.stackUsingFunctions` across the call
    // graph via backward BFS to fixed point. Finally, validate every
    // :cloaked decl against the closed set and emit a chain error if
    // the decl's label is present.
    [self.locallyStackUsingFunctions setSet:self.stackUsingFunctions];
    [self propagateStackUseTransitively];
    [self propagateExtendedRamUseTransitively];
    [self validateCloakedDecls];
    [self validateVariadicNonReentrance];
    [self checkCovariantReturnOpportunities];
    [self computeStaticFrameEligibility];
    [self computeMaxCallDepths];
    [self inferCloakSafety:program];
    }

/****************************************************************************\
|* Build a reverse-edges view of `self.callEdges` and iterate the backward
|* BFS: anyone who calls a stack-using function becomes stack-using too.
|* Stops when one pass adds nothing new.
\****************************************************************************/
- (void)propagateStackUseTransitively
    {
    NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* callers =
        [NSMutableDictionary dictionary];
    for (NSString* caller in self.callEdges)
        {
        for (NSString* callee in self.callEdges[caller])
            {
            NSMutableSet* set = callers[callee];
            if (!set)
                {
                set = [NSMutableSet set];
                callers[callee] = set;
                }
            [set addObject:caller];
            }
        }
    NSMutableArray<NSString*>* worklist =
        [[self.stackUsingFunctions allObjects] mutableCopy];
    while (worklist.count > 0)
        {
        NSString* victim = worklist.lastObject;
        [worklist removeLastObject];
        NSSet* upstream = callers[victim];
        for (NSString* caller in upstream)
            {
            if (![self.stackUsingFunctions containsObject:caller])
                {
                [self.stackUsingFunctions addObject:caller];
                [worklist addObject:caller];
                }
            }
        }
    }

/****************************************************************************\
|* Backward BFS for the xt extended-RAM track, parallel to
|* propagateStackUseTransitively. Anyone who calls a function in
|* `regionCLocallyUsing` becomes part of `regionCUsing`.
|* Same fixed-point iteration; uses the same `_callEdges` graph.
|*
|* The closure's main consumer is the program-wide gates (ZP
|* reservation of $84/$85, heap.asm region-C variant, _xcall
|* trampoline shape). Per-function bracket emission stays gated
|* on `regionCLocallyUsing` (the unpropagated set).
\****************************************************************************/
- (void)propagateExtendedRamUseTransitively
    {
    [self->_regionCUsing setSet:self->_regionCLocallyUsing];
    NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* callers =
        [NSMutableDictionary dictionary];
    for (NSString* caller in self.callEdges)
        {
        for (NSString* callee in self.callEdges[caller])
            {
            NSMutableSet* set = callers[callee];
            if (!set)
                {
                set = [NSMutableSet set];
                callers[callee] = set;
                }
            [set addObject:caller];
            }
        }
    NSMutableArray<NSString*>* worklist =
        [[self->_regionCUsing allObjects] mutableCopy];
    while (worklist.count > 0)
        {
        NSString* victim = worklist.lastObject;
        [worklist removeLastObject];
        NSSet* upstream = callers[victim];
        for (NSString* caller in upstream)
            {
            if (![self->_regionCUsing containsObject:caller])
                {
                [self->_regionCUsing addObject:caller];
                [worklist addObject:caller];
                }
            }
        }
    }

/****************************************************************************\
|* For every :cloaked decl captured in Pass A, check whether its label is
|* in the closed `self.stackUsingFunctions` set. If so, BFS forward through
|* `self.callEdges` to find the shortest path to a locally-using leaf and
|* emit an error whose notes walk that chain. Chain length is capped at
|* `kChainCap` hops for readability; beyond that a trailing note says
|* "(chain continues)". The cloaked decl itself is a valid leaf (a
|* :cloaked function can self-flag through a local signal that
|* scanCloakedBody didn't catch — e.g. inline-asm SP reference or a
|* large local).
\****************************************************************************/
- (void)validateCloakedDecls
    {
    static const NSUInteger kChainCap = 5;
    for (NSDictionary* entry in self.cloakedDecls)
        {
        NSString* label = entry[@"label"];
        if (![self.stackUsingFunctions containsObject:label])
            continue;
        NSArray<NSString*>* chain = [self shortestChainFrom:label
                                                    maxHops:kChainCap];
        if (chain.count == 0)
            continue;
        // Self-case suppression: if the cloaked decl's OWN body was the
        // signal (chain length 1 and start == leaf), the fast-path
        // `checkCloakedDecl` / `scanCloakedBody` has already emitted a
        // more-precise error pointing at the offending line (the `new`
        // itself, the `delete` call, etc). Skip the transitive note to
        // avoid duplicate diagnostics for the same root cause. Signals
        // the fast-path doesn't cover — inline asm SP refs, struct
        // return, large locals, varargs — still fall through here so
        // they're reported at the decl location.
        if (chain.count == 1)
            {
            NSString* reason = self.stackUseReasons[label];
            BOOL fastPathCovered =
                [reason hasPrefix:@"allocates with 'new'"] ||
                [reason hasPrefix:@"uses 'delete'"] ||
                [reason hasPrefix:@"uses 'retain'"] ||
                [reason hasPrefix:@"uses 'release'"];
            if (fastPathCovered)
                continue;
            }

        NSString* name = entry[@"name"];
        XTSourceLocation* loc = entry[@"location"];
        NSMutableString* msg = [NSMutableString stringWithFormat:
                                                    @":cloaked '%@' transitively uses the xtc software stack",
                                                    name];

        // Walk the chain. Position 0 is the cloaked decl itself; we
        // skip renaming it (the header already names it). Intermediate
        // entries render as "calls '<name>' which"; the final entry
        // renders with its stack-use reason.
        for (NSUInteger i = 1; i < chain.count; i++)
            {
            NSString* step = chain[i];
            NSString* display = self.labelDisplayNames[step] ?: step;
            BOOL isLast = (i == chain.count - 1);
            if (isLast)
                {
                NSString* reason = self.stackUseReasons[step]
                                       ?: @"reaches the xtc stack";
                [msg appendFormat:@"\n  note: calls '%@' which %@",
                                  display, reason];
                }
            else
                {
                [msg appendFormat:@"\n  note: calls '%@' which", display];
                }
            }
        // Self-case: a cloaked decl locally flagged. Render its own
        // reason as the single note.
        if (chain.count == 1 && [self.locallyStackUsingFunctions containsObject:label])
            {
            NSString* reason = self.stackUseReasons[label]
                                   ?: @"reaches the xtc stack";
            [msg appendFormat:@"\n  note: %@", reason];
            }
        // Truncation marker if BFS hit the cap without finding a leaf.
        BOOL endedAtLeaf = (chain.count > 0) &&
                           [self.locallyStackUsingFunctions containsObject:chain.lastObject];
        if (!endedAtLeaf)
            {
            [msg appendString:@"\n  note: (chain continues)"];
            }
        // Migration escape hatch: -Wno-cloaked-transitive downgrades
        // the transitive-safety diagnostic from error to warning so
        // pre-stage-4c programs that silently worked can still build
        // while their authors refactor. Emitted via emitWarning:at:
        // (uncategorised) rather than emitWarning:category: because
        // the latter would silence it entirely.
        if ([self.diagnostics isWarningCategorySuppressed:XTWarnCloakedTransitive])
            {
            [self.diagnostics emitWarning:msg at:loc];
            }
        else
            {
            [self.diagnostics emitError:msg at:loc];
            }
        }
    }

/****************************************************************************\
|* Forward-BFS from a starting label through `self.callEdges` until either a
|* locally-stack-using label is reached (shortest chain to a leaf) or the
|* hop cap is hit. Returns the path as an array of labels (starting with
|* `start`, ending with the leaf or the deepest frontier node). Returns
|* empty when the graph has no path that stays within the closed
|* `self.stackUsingFunctions` set — which shouldn't happen in practice
|* because every transitively-flagged label has at least one flagged
|* callee, but the defensive check keeps the emitter safe.
\****************************************************************************/
- (NSArray<NSString*>*)shortestChainFrom:(NSString*)start
                                 maxHops:(NSUInteger)cap
    {
    if ([self.locallyStackUsingFunctions containsObject:start])
        {
        return @[ start ];
        }
    NSMutableDictionary<NSString*, NSString*>* parent =
        [NSMutableDictionary dictionary];
    parent[start] = start; // sentinel: start's parent is itself
    NSMutableArray<NSString*>* frontier =
        [NSMutableArray arrayWithObject:start];
    NSUInteger hops = 0;
    NSString* leaf = nil;
    NSString* lastFrontier = start;
    while (frontier.count > 0 && hops < cap && !leaf)
        {
        NSMutableArray<NSString*>* next = [NSMutableArray array];
        for (NSString* caller in frontier)
            {
            NSSet* callees = self.callEdges[caller];
            for (NSString* callee in callees)
                {
                if (![self.stackUsingFunctions containsObject:callee])
                    continue;
                if (parent[callee])
                    continue;
                parent[callee] = caller;
                if ([self.locallyStackUsingFunctions containsObject:callee])
                    {
                    leaf = callee;
                    break;
                    }
                [next addObject:callee];
                }
            if (leaf)
                break;
            }
        if (next.count > 0)
            lastFrontier = next.lastObject;
        frontier = next;
        hops++;
        }
    // Reconstruct the path: either to `leaf` (if found) or to the last
    // frontier node (to at least show something in the error output).
    NSString* tail = leaf ?: lastFrontier;
    NSMutableArray<NSString*>* chain = [NSMutableArray array];
    NSString* cur = tail;
    while (cur && ![cur isEqualToString:start])
        {
        [chain insertObject:cur atIndex:0];
        cur = parent[cur];
        if ([cur isEqualToString:start])
            break;
        }
    [chain insertObject:start atIndex:0];
    return chain;
    }

/****************************************************************************\
|* For every variadic decl captured in Pass A, forward-BFS its transitive
|* callees. Any reached label that is itself variadic (including the
|* start, which signals self- or mutual recursion) is a reentrance
|* violation — the shared pack buffer at $04B0 cannot hold two live
|* va_lists. Emits a chain error naming the route. Non-variadic
|* intermediates are walked transparently; only the endpoint needs to be
|* variadic to trip the check.
|*
|* This enforces the invariant that lets the pack-buffer pool collapse
|* from 5 fixed slots to a single shared slot: with no variadic ever
|* transitively calling another variadic, the buffer is always re-used
|* top-down by a single live caller.
\****************************************************************************/
- (void)validateVariadicNonReentrance
    {
    static const NSUInteger kChainCap = 5;
    for (NSDictionary* entry in self.variadicDecls)
        {
        NSString* start = entry[@"label"];
        // Pure forwarders (variadic decls that never call va_start)
        // don't consume their own va_list, so another variadic
        // clobbering the pack buffer is harmless. This is the
        // Stdio.printfAt pattern: take `...` from the caller only to
        // let them pack through, then hand off to Stdio.printf which
        // does the actual consumption. Skip the check for those.
        if (![self.variadicFunctionsUsingVaList containsObject:start])
            continue;
        NSArray<NSString*>* chain = [self shortestVariadicPathFrom:start
                                                           maxHops:kChainCap];
        if (chain.count < 2)
            continue;
        NSString* name = entry[@"name"];
        XTSourceLocation* loc = entry[@"location"];
        NSString* leaf = chain.lastObject;
        BOOL isSelfOrMutual = [leaf isEqualToString:start];
        NSString* leafName = isSelfOrMutual
                                 ? name
                                 : (self.labelDisplayNames[leaf] ?: leaf);
        NSMutableString* msg;
        if (isSelfOrMutual)
            {
            msg = [NSMutableString stringWithFormat:
                                       @"variadic '%@' is transitively recursive — the shared "
                                       @"varargs pack buffer at $04B0 cannot hold two live "
                                       @"va_lists at once",
                                       name];
            }
        else
            {
            msg = [NSMutableString stringWithFormat:
                                       @"variadic '%@' transitively calls variadic '%@' — both "
                                       @"share the pack buffer at $04B0 and would clobber each "
                                       @"other",
                                       name, leafName];
            }
        // Walk chain[1..] emitting notes. Chain[0] is the start (named
        // in the header already); the last entry gets a "(variadic)"
        // tag, intermediates render as "calls '<name>' which".
        for (NSUInteger i = 1; i < chain.count; i++)
            {
            NSString* step = chain[i];
            BOOL isLast = (i == chain.count - 1);
            NSString* display = isLast && isSelfOrMutual
                                    ? name
                                    : (self.labelDisplayNames[step] ?: step);
            if (isLast)
                {
                [msg appendFormat:@"\n  note: calls '%@' (variadic)", display];
                }
            else
                {
                [msg appendFormat:@"\n  note: calls '%@' which", display];
                }
            }
        [self.diagnostics emitError:msg at:loc];
        }
    }

/****************************************************************************\
|* Forward BFS over `self.callEdges` from `start`, stopping at the shortest
|* reached variadic label (or a return-edge back to `start`, which
|* detects self- or mutual recursion). Returns the path as an array of
|* labels starting with `start` and ending with the conflicting leaf,
|* or empty when no variadic is reachable within `cap` hops. The leaf
|* equals `start` iff the recursion cycle closes back on the seed.
\****************************************************************************/
- (NSArray<NSString*>*)shortestVariadicPathFrom:(NSString*)start
                                        maxHops:(NSUInteger)cap
    {
    if (!self.callEdges[start])
        return @[];
    // `parent` doubles as visited-set. NSNull marks the start (used
    // during reconstruction to stop the walk). The self-return edge
    // gets a synthetic sentinel key so it's distinguishable from the
    // seed entry; the emitter renames it back to `start` when rendering.
    NSMutableDictionary* parent = [NSMutableDictionary dictionary];
    parent[start] = [NSNull null];
    NSMutableArray<NSString*>* frontier = [NSMutableArray arrayWithObject:start];
    NSString* leaf = nil;
    for (NSUInteger h = 0; h < cap && !leaf; h++)
        {
        NSMutableArray<NSString*>* next = [NSMutableArray array];
        for (NSString* caller in frontier)
            {
            for (NSString* callee in self.callEdges[caller])
                {
                if ([callee isEqualToString:start])
                    {
                    NSString* sentinel = @"__self_return";
                    parent[sentinel] = caller;
                    leaf = sentinel;
                    break;
                    }
                if (parent[callee])
                    continue;
                parent[callee] = caller;
                if ([self.variadicLabels containsObject:callee])
                    {
                    leaf = callee;
                    break;
                    }
                [next addObject:callee];
                }
            if (leaf)
                break;
            }
        frontier = next;
        }
    if (!leaf)
        return @[];
    NSMutableArray<NSString*>* chain = [NSMutableArray array];
    NSString* cur = leaf;
    NSUInteger guard = 0;
    while (cur && guard++ < cap + 2)
        {
        NSString* render = [cur isEqualToString:@"__self_return"] ? start : cur;
        [chain insertObject:render atIndex:0];
        id p = parent[cur];
        if (p == [NSNull null])
            break;
        cur = p;
        }
    return chain;
    }

/****************************************************************************\
|* Static-frame eligibility analyser. Classifies every known function in
|* `self.callEdges` as static-frame eligible or not. A function is eligible
|* iff:
|*   • it is not in any recursive cluster (no self-loop, no back-edge
|*     reaching itself through the call graph).
|*   • its address has not been taken anywhere in the program.
|*   • it is not an external (forward-declared-only) symbol.
|*
|* Eligibility is a LOCAL property — it does NOT propagate transitively
|* to callers. An eligible F calling an ineligible G is fine: F saves
|* its frame to the static buffer, then calls G; G uses the xtc stack
|* for its own frame; the two storages don't overlap. On G's return, F
|* restores from its static slot and carries on.
|*
|* Recursion detection uses per-function forward BFS over `self.callEdges`.
|* A function F is recursive iff F is reachable from itself. O(V·E),
|* entirely adequate for xtc-scale programs.
|*
|* Output: populates `self->_staticFrameEligible` — dictionary keyed by the
|* same `_fn_<mangled>` / `_cls_<Class>_<mangled>` labels as
|* `self.callEdges`, mapping to @YES (eligible) or @NO (fallback).
\****************************************************************************/
- (void)computeStaticFrameEligibility
    {
    // PR0 cross-module import: any label present in
    // `self.importedFunctionAttrs` was defined in a separately-compiled
    // module whose .asm manifest the driver slurped before this pass.
    // Drop those labels from `self.externalFunctions` (we now know their
    // attributes), and fold their `is_recursive` / `address_taken`
    // flags into the local sets so the eligibility verdict for the
    // imported function matches what a single-unit compile would have
    // produced.
    if (self.importedFunctionAttrs)
        {
        for (NSString* label in self.importedFunctionAttrs)
            {
            NSDictionary* attrs = self.importedFunctionAttrs[label];
            [self.externalFunctions removeObject:label];
            NSNumber* rec = attrs[@"is_recursive"];
            if (rec && rec.boolValue)
                {
                [self->_recursiveFunctions addObject:label];
                }
            NSNumber* at = attrs[@"address_taken"];
            if (at && at.boolValue)
                {
                [self->_addressTakenFunctions addObject:label];
                }
            }
        }

    // Stage-2 CFA: fold each indirect-call target set into `self.callEdges`
    // BEFORE recursion detection runs. If function F's body contains
    // `fp(...)` and we've tracked that `&G` reaches `fp`, then the
    // edge F → G must be visible to the recursion analyser — otherwise
    // we'd wrongly declare F eligible for a static frame when G could
    // transitively call F back.
    for (NSString* caller in self.indirectCallTargets)
        {
        NSMutableSet* edges = self.callEdges[caller];
        if (!edges)
            {
            edges = [NSMutableSet set];
            self.callEdges[caller] = edges;
            }
        [edges unionSet:self.indirectCallTargets[caller]];
        }

    [self detectRecursiveFunctions];

    NSMutableSet<NSString*>* allLabels = [NSMutableSet set];
    [allLabels unionSet:[NSSet setWithArray:self.callEdges.allKeys]];
    // Also include every label we saw as a callee — a leaf function
    // that itself does no JSRing won't appear as a caller key, but we
    // still want an eligibility entry for it.
    for (NSString* caller in self.callEdges)
        {
        [allLabels unionSet:self.callEdges[caller]];
        }
    [allLabels unionSet:self.externalFunctions];
    [allLabels unionSet:self->_addressTakenFunctions];

    for (NSString* label in allLabels)
        {
        BOOL eligible = YES;
        if ([self.externalFunctions containsObject:label])
            eligible = NO;
        // Address-taken disqualifies only if the &-of site wasn't one
        // of the CFA-tracked shapes (assignment to fnptr, init of
        // fnptr-typed local, or fnptr argument at a call site). A
        // cleanly-tracked target becomes a normal call-graph node via
        // the virtual edges folded in above; the recursion and
        // reachability checks that follow are sufficient.
        if ([self->_addressTakenFunctions containsObject:label] &&
            ![self.addressTakenCleanly containsObject:label])
            eligible = NO;
        if ([self->_recursiveFunctions containsObject:label])
            eligible = NO;
        self->_staticFrameEligible[label] = @(eligible);
        }

    // Diagnostic dump for bring-up / debugging — enabled by setting
    // the XTC_DEBUG_STATIC_FRAME environment variable. Prints every
    // known function label along with its eligibility verdict and the
    // reason(s) for any fallback. Silent by default.
    if (getenv("XTC_DEBUG_STATIC_FRAME"))
        {
        fprintf(stderr, "static-frame eligibility (%lu labels):\n",
                (unsigned long)self->_staticFrameEligible.count);
        NSArray* sorted = [self->_staticFrameEligible.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString* label in sorted)
            {
            BOOL elig = [self->_staticFrameEligible[label] boolValue];
            NSMutableArray* reasons = [NSMutableArray array];
            if ([self.externalFunctions containsObject:label])
                [reasons addObject:@"external"];
            if ([self->_addressTakenFunctions containsObject:label] &&
                ![self.addressTakenCleanly containsObject:label])
                [reasons addObject:@"addr-taken"];
            if ([self->_recursiveFunctions containsObject:label])
                [reasons addObject:@"recursive"];
            fprintf(stderr, "  %s  %s%s%s\n",
                    elig ? "ELIGIBLE" : "fallback",
                    label.UTF8String,
                    reasons.count ? "  — " : "",
                    [[reasons componentsJoinedByString:@","] UTF8String]);
            }
        }
    }

/****************************************************************************\
|* PR1 single-inheritance pre-pass: turn each class decl's declared
|* `parentName` into a resolved `parentClass` pointer. Diagnoses two
|* shapes the parser can't catch on its own:
|*
|*   • unknown parent — the identifier doesn't name any class
|*     registered in the current compilation unit. Pre-PR8 xtc has no
|*     notion of an imported class hierarchy (that's what the PR8
|*     manifest class.* keys are for), so an unknown parent is
|*     always a typo or a missing `#import`.
|*   • circular inheritance — walking parent-pointers from this class
|*     loops back to it. Both `A : A` (direct) and `A : B ; B : A`
|*     (mutual) are rejected; the diagnostic names the class whose
|*     chain was followed.
|*
|* On either error, `parentClass` is left nil — later passes treat
|* "declared parent but parentClass == nil" as "already diagnosed".
\****************************************************************************/
- (void)resolveClassHierarchy
    {
    // PR7: ensure the universal `Object` root class is registered.
    // If the user hasn't declared one themselves, synthesise a bare
    // placeholder — no ivars, no methods — so every parentless
    // class can point at it as an implicit parent without adding
    // any runtime cost. The auto-generated dealloc stub pass and
    // the init-chain / dealloc-chain wiring already handle the
    // "ancestor has no methods" case correctly (both bail out when
    // no ancestor declares the name), so existing programs stay
    // bit-exact. PR8 will populate Object with real methods and
    // wire virtual dispatch through its vtable.
    if (!self.classesByName[@"Object"])
        {
        XTSourceLocation* builtin =
            [XTSourceLocation locationWithFilename:@"<builtin>"
                                              line:0
                                            column:0];
        XTClassDeclNode* obj = [[XTClassDeclNode alloc]
             initWithName:@"Object"
               parentName:nil
            protocolNames:@[]
                    ivars:@[]
                  methods:@[]
                 location:builtin];
        self.classesByName[@"Object"] = obj;
        // Register a type-table marker so `Object@` parses. The
        // parser registers class markers lazily on each `class X`
        // decl; synthetic Object needs the same treatment so an
        // explicit `Object@ o = new Dog();` resolves.
        XTType* marker = [[XTType alloc] initWithKind:XTTypeKindClass
                                          displayName:@"Object"];
        if (![self.typeTable typeForName:@"Object"])
            {
            [self.typeTable registerType:marker forName:@"Object"];
            }
        }
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentName == nil)
            continue;
        XTClassDeclNode* parent = self.classesByName[cls.parentName];
        if (!parent)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"Unknown parent class '%@' for class '%@'",
                                                      cls.parentName, cls.className]
                                     at:cls.location];
            continue;
            }
        cls.parentClass = parent;
        }
    // PR7: every class without an explicit parent is an implicit
    // child of Object. Skip Object itself (it has no parent) and
    // skip any class whose parent-link failed above (unknown-parent
    // error) so we don't chain through a broken hierarchy.
    XTClassDeclNode* objectCls = self.classesByName[@"Object"];
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls == objectCls)
            continue;
        if (cls.parentName != nil)
            continue;
        if (cls.parentClass != nil)
            continue;
        cls.parentClass = objectCls;
        }
    // Cycle detection: per-class BFS up the parent chain; bail on
    // revisit. Run after link-up so every reachable parent is already
    // wired, and a cycle shows up as a back-edge to an already-seen
    // node.
    // Sorted, not dictionary order: exactly ONE class per cycle is severed —
    // the first whose walk revisits a seen name — and later walks then
    // terminate at the severed link. With dictionary order, WHICH class
    // loses its parent was hash-dependent, and every vtable downstream of
    // the severing differed run-to-run of the self-hosted twin (task #36).
    NSArray<NSString*>* cycleOrder =
        [self.classesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* cycleName in cycleOrder)
        {
        XTClassDeclNode* cls = self.classesByName[cycleName];
        NSMutableSet<NSString*>* seen = [NSMutableSet setWithObject:cls.className];
        XTClassDeclNode* cur = cls.parentClass;
        while (cur)
            {
            if ([seen containsObject:cur.className])
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Circular inheritance: '%@' eventually inherits from itself via '%@'",
                                                          cls.className, cur.className]
                                         at:cls.location];
                cls.parentClass = nil;
                break;
                }
            [seen addObject:cur.className];
            cur = cur.parentClass;
            }
        }
    // Ivar name uniqueness across the chain. A subclass ivar shadowing
    // an inherited name would share the leaf's ivar-offset entry with
    // its ancestor and quietly corrupt parent-typed accesses. Reject
    // at the earliest point — after parent linkage, before any scope
    // or offset computation consumes the names.
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentClass == nil)
            continue;
        for (XTVariableDeclNode* ivar in cls.ivars)
            {
            for (XTClassDeclNode* c = cls.parentClass; c != nil; c = c.parentClass)
                {
                BOOL shadowed = NO;
                for (XTVariableDeclNode* a in c.ivars)
                    {
                    if ([a.varName isEqualToString:ivar.varName])
                        {
                        shadowed = YES;
                        break;
                        }
                    }
                if (shadowed)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Subclass '%@' redeclares ivar '%@' inherited from '%@'",
                                                              cls.className, ivar.varName, c.className]
                                             at:ivar.location ?: cls.location];
                    break;
                    }
                }
            }
        }
    }

/****************************************************************************\
|* PR4 subtype helper — YES iff `sub` is the same class as `sup` or
|* any (transitive) descendant of it. Walks the `parentClass` chain
|* from `sub` up, bailing at the first match. Runs at every class-
|* pointer implicit-conversion site; the chain depth is small so
|* linear scan is fine.
\****************************************************************************/
- (BOOL)class:(XTClassDeclNode*)sub inheritsFromOrEquals:(XTClassDeclNode*)sup
    {
    for (XTClassDeclNode* c = sub; c != nil; c = c.parentClass)
        {
        if (c == sup)
            return YES;
        if ([c.className isEqualToString:sup.className])
            return YES;
        }
    return NO;
    }

/****************************************************************************\
|* PR9 conformance helper — YES iff `cls` or any ancestor lists
|* `protoName` among its declared protocols. Used by the subtype
|* compatibility rule to accept `Dog@` → `Drawable@` when Dog (or
|* an ancestor) adopts Drawable.
\****************************************************************************/
- (BOOL)class:(XTClassDeclNode*)cls conformsToProtocol:(NSString*)protoName
    {
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        {
        for (NSString* p in c.protocolNames)
            {
            if ([p isEqualToString:protoName])
                return YES;
            }
        }
    return NO;
    }

/****************************************************************************\
|* Property-accessor helpers. The feature rewrites `obj.name` to a
|* call `obj.name()` when `name` is a zero-arg method on the class
|* (or an ancestor), and rewrites `obj.name = v` to `obj.setName(v)`
|* when a matching one-arg setter exists. These helpers walk the
|* parent chain and return the first matching method (leaf class
|* wins); the caller is responsible for preferring accessor over
|* ivar when both exist.
\****************************************************************************/
- (nullable XTMethodDeclNode*)zeroArgMethodNamed:(NSString*)name
                                         inClass:(XTClassDeclNode*)cls
                                   ownerClassOut:(NSString* _Nullable* _Nullable)ownerOut
    {
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        {
        for (XTMethodDeclNode* m in c.methods)
            {
            if ([m.methodName isEqualToString:name] &&
                m.parameters.count == 0 &&
                !m.isVarArgs &&
                !m.isStatic)
                {
                if (ownerOut)
                    *ownerOut = c.className;
                return m;
                }
            }
        }
    return nil;
    }

- (NSString*)propertySetterNameFor:(NSString*)ivarName
    {
    if (ivarName.length == 0)
        return @"set";
    NSString* head = [[ivarName substringToIndex:1] uppercaseString];
    NSString* tail = [ivarName substringFromIndex:1];
    return [NSString stringWithFormat:@"set%@%@", head, tail];
    }

- (nullable XTMethodDeclNode*)setterMethodNamed:(NSString*)setterName
                                        inClass:(XTClassDeclNode*)cls
                                 acceptingValue:(XTASTNode*)valueNode
                                  ownerClassOut:(NSString* _Nullable* _Nullable)ownerOut
    {
    XTMethodDeclNode* best = nil;
    NSString* bestOwner = nil;
    NSInteger bestScore = NSIntegerMax;
    BOOL litIsInt = [valueNode isKindOfClass:[XTLiteralIntNode class]];
    int64_t litVal = litIsInt ? ((XTLiteralIntNode*)valueNode).intValue : 0;
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        {
        for (XTMethodDeclNode* m in c.methods)
            {
            if (![m.methodName isEqualToString:setterName])
                continue;
            if (m.isStatic || m.isVarArgs)
                continue;
            if (m.parameters.count != 1)
                continue;
            XTType* pt = m.parameters.firstObject.paramType;
            NSInteger sc = [self conversionRankFrom:valueNode.resolvedType
                                                 to:pt
                                           isIntLit:litIsInt
                                           litValue:litVal];
            if (sc == NSIntegerMax)
                continue;
            if (sc < bestScore)
                {
                best = m;
                bestOwner = c.className;
                bestScore = sc;
                }
            }
        // Stop at the first class that declares ANY method with this
        // name (even if no overload matched) so ancestor setters don't
        // leak through once the leaf class has started shadowing.
        BOOL anyShadow = NO;
        for (XTMethodDeclNode* m in c.methods)
            {
            if ([m.methodName isEqualToString:setterName])
                {
                anyShadow = YES;
                break;
                }
            }
        if (anyShadow)
            break;
        }
    if (ownerOut)
        *ownerOut = bestOwner;
    return best;
    }

/****************************************************************************\
|* PR4 override matcher. Two methods override each other when they
|* share the method name, the same parameter count, and a pointwise
|* equal parameter-type list. Return types aren't part of the match —
|* xtc doesn't allow return-type overloading, so the return is
|* determined by the signature.
\****************************************************************************/
- (BOOL)methodSignaturesMatch:(XTMethodDeclNode*)a
                          and:(XTMethodDeclNode*)b
    {
    if (![a.methodName isEqualToString:b.methodName])
        return NO;
    if (a.parameters.count != b.parameters.count)
        return NO;
    for (NSUInteger i = 0; i < a.parameters.count; i++)
        {
        XTType* pa = a.parameters[i].paramType;
        XTType* pb = b.parameters[i].paramType;
        if (pa.kind != pb.kind)
            return NO;
        // Class-pointer params compare by class name too.
        if ([pa isKindOfClass:[XTPointerType class]] &&
            [pb isKindOfClass:[XTPointerType class]])
            {
            XTType* pta = ((XTPointerType*)pa).pointeeType;
            XTType* ptb = ((XTPointerType*)pb).pointeeType;
            if (pta.kind != ptb.kind)
                return NO;
            if (pta.kind == XTTypeKindClass &&
                ![pta.displayName isEqualToString:ptb.displayName])
                return NO;
            }
        }
    return YES;
    }

/****************************************************************************\
|* PR5 init-chain wiring. For every class that (a) has a parent,
|* (b) declares its own init method, and (c) doesn't already call
|* `super.init(...)` anywhere in the body, decide what to do:
|*
|*   • parent has a no-arg init → flag the subclass init with
|*     `autoSuperInit = YES`; codegen inserts `super.init()` at the
|*     top of the body.
|*   • parent needs args (or has no init at all when the parent
|*     chain has a non-empty init elsewhere) → error. No automatic
|*     argument picking.
|*
|* A duplicate user-written `super.init` gets flagged by the guard
|* for unambiguity. User code with any explicit super.init opts
|* out of auto-synth entirely — the author owns the flow.
\****************************************************************************/
- (void)wireSubclassInitChains
    {
    // A subclass that declares NO init of its own ran NO initialiser AT ALL — not even
    // the inherited one. `new Button()` looked for `Button$init`, there wasn't one, and
    // it called nothing: every field the parent's init would have set stayed null. It
    // compiled clean, and survived only on luck until something dereferenced one.
    //
    // The chain already worked for a subclass that DOES declare an init (autoSuperInit
    // below). The hole was the class that declares none — so synthesise one whose body
    // is nothing but that chain, and every consumer (new, the value-instance form, the
    // interface serializer, reachability) sees a normal init.
    //
    // Skipped for an imported class: the library that DEFINES it already synthesised
    // one, and it arrives through the interface. Emitting a second body here would
    // define it twice.
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentClass == nil || cls.isExternal)
            continue;
        BOOL declaresInit = NO;
        for (XTMethodDeclNode* m in cls.methods)
            if ([m.methodName isEqualToString:@"init"])
                {
                declaresInit = YES;
                break;
                }
        if (declaresInit)
            continue;
        // An ancestor with a NO-ARG init is what we can chain to unaided.
        XTMethodDeclNode* inherited = nil;
        for (XTClassDeclNode* p = cls.parentClass; p != nil && !inherited; p = p.parentClass)
            for (XTMethodDeclNode* pm in p.methods)
                if ([pm.methodName isEqualToString:@"init"] && pm.parameters.count == 0)
                    {
                    inherited = pm;
                    break;
                    }
        if (!inherited)
            continue;
        XTMethodDeclNode* synth =
            [[XTMethodDeclNode alloc] initWithName:@"init"
                                       returnTypes:@[ [XTType voidType] ]
                                        parameters:@[]
                                          isStatic:NO
                                         isVarArgs:NO
                                              body:[[XTBlockNode alloc]
                                                       initWithStatements:@[]
                                                                 location:cls.location]
                                          location:cls.location];
        synth.autoSuperInit = YES; // the body IS the chain
        [cls appendSynthesisedMethod:synth];
        }

    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentClass == nil)
            continue;
        for (XTMethodDeclNode* m in cls.methods)
            {
            if (![m.methodName isEqualToString:@"init"])
                continue;
            if (!m.body)
                continue;
            NSUInteger superInits = 0;
            [self countSuperCallsTo:@"init" in:m.body into:&superInits];
            if (superInits > 1)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"duplicate super.init call in '%@.init'",
                                                          cls.className]
                                         at:m.location];
                continue;
                }
            if (superInits == 1)
                continue; // author owns the flow
            // No explicit super.init — look for a no-arg init up the chain.
            XTMethodDeclNode* noArgInit = nil;
            for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
                {
                BOOL parentHasAnyInit = NO;
                for (XTMethodDeclNode* pm in p.methods)
                    {
                    if (![pm.methodName isEqualToString:@"init"])
                        continue;
                    parentHasAnyInit = YES;
                    if (pm.parameters.count == 0)
                        {
                        noArgInit = pm;
                        break;
                        }
                    }
                if (noArgInit)
                    break;
                if (parentHasAnyInit)
                    break; // found an init, but not no-arg
                }
            if (noArgInit)
                {
                m.autoSuperInit = YES;
                }
            else
                {
                // Only diagnose when the parent chain actually declares an
                // init (whose args we can't guess). A parentless init tree
                // is fine — init has nothing to chain to.
                BOOL anyAncestorInit = NO;
                for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
                    {
                    for (XTMethodDeclNode* pm in p.methods)
                        {
                        if ([pm.methodName isEqualToString:@"init"])
                            {
                            anyAncestorInit = YES;
                            break;
                            }
                        }
                    if (anyAncestorInit)
                        break;
                    }
                if (anyAncestorInit)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"init on '%@' must call super.init(...) — parent "
                                                              @"chain has no no-arg init",
                                                              cls.className]
                                             at:m.location];
                    }
                }
            }
        }
    }

/****************************************************************************\
|* PR6 dealloc-chain wiring. Symmetric to wireSubclassInitChains but
|* child-first: if a subclass declares its own dealloc and doesn't
|* already call super.dealloc, flag it so codegen can auto-append
|* the super JSR at the END of the body. dealloc has no arguments
|* and no failure path, so the auto-append is always safe when any
|* ancestor declares a dealloc method. Double-call the user wrote
|* is still rejected.
\****************************************************************************/
- (void)wireSubclassDeallocChains
    {
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentClass == nil)
            continue;
        for (XTMethodDeclNode* m in cls.methods)
            {
            if (![m.methodName isEqualToString:@"dealloc"])
                continue;
            if (!m.body)
                continue;
            NSUInteger superDeallocs = 0;
            [self countSuperCallsTo:@"dealloc" in:m.body into:&superDeallocs];
            if (superDeallocs > 1)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"duplicate super.dealloc call in '%@.dealloc'",
                                                          cls.className]
                                         at:m.location];
                continue;
                }
            if (superDeallocs == 1)
                continue; // user owns placement
            // No explicit super.dealloc — auto-append iff any ancestor
            // declares a dealloc. If none do, there's nothing to chain
            // to; leaf dealloc runs on its own.
            BOOL ancestorHasDealloc = NO;
            for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
                {
                for (XTMethodDeclNode* pm in p.methods)
                    {
                    if ([pm.methodName isEqualToString:@"dealloc"])
                        {
                        ancestorHasDealloc = YES;
                        break;
                        }
                    }
                if (ancestorHasDealloc)
                    break;
                }
            if (ancestorHasDealloc)
                m.autoSuperDealloc = YES;
            }
        }
    }

/****************************************************************************\
|* Count `super.<methodName>(...)` call sites inside an AST subtree.
|* Recursive walker covering every statement / expression shape that
|* can transitively hold a method call. Used by
|* `wireSubclassInitChains` / `wireSubclassDeallocChains` to
|* distinguish "no explicit call" (auto-synth candidate) from
|* "exactly one explicit call" (author owns the flow) from "more
|* than one" (duplicate call error).
\****************************************************************************/
- (void)countSuperCallsTo:(NSString*)methodName
                       in:(nullable XTASTNode*)node
                     into:(NSUInteger*)outCount
    {
    if (!node || !outCount)
        return;
    if ([node isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* mc = (XTMethodCallExprNode*)node;
        if ([mc.receiver isKindOfClass:[XTIdentifierNode class]] &&
            [((XTIdentifierNode*)mc.receiver).identName isEqualToString:@"super"] &&
            [mc.methodName isEqualToString:methodName])
            {
            (*outCount)++;
            }
        for (XTASTNode* a in mc.arguments)
            [self countSuperCallsTo:methodName in:a into:outCount];
        [self countSuperCallsTo:methodName in:mc.receiver into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            [self countSuperCallsTo:methodName in:s into:outCount];
            }
        return;
        }
    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self countSuperCallsTo:methodName in:((XTExpressionStatementNode*)node).expression into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* ifn = (XTIfNode*)node;
        [self countSuperCallsTo:methodName in:ifn.condition into:outCount];
        [self countSuperCallsTo:methodName in:ifn.thenBlock into:outCount];
        [self countSuperCallsTo:methodName in:ifn.elseBlock into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* wn = (XTWhileNode*)node;
        [self countSuperCallsTo:methodName in:wn.condition into:outCount];
        [self countSuperCallsTo:methodName in:wn.body into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* fn = (XTForCStyleNode*)node;
        [self countSuperCallsTo:methodName in:fn.loopInit into:outCount];
        [self countSuperCallsTo:methodName in:fn.condition into:outCount];
        [self countSuperCallsTo:methodName in:fn.increment into:outCount];
        [self countSuperCallsTo:methodName in:fn.body into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            {
            [self countSuperCallsTo:methodName in:v into:outCount];
            }
        return;
        }
    if ([node isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* ae = (XTAssignExprNode*)node;
        [self countSuperCallsTo:methodName in:ae.lhs into:outCount];
        [self countSuperCallsTo:methodName in:ae.rhs into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* be = (XTBinaryExprNode*)node;
        [self countSuperCallsTo:methodName in:be.left into:outCount];
        [self countSuperCallsTo:methodName in:be.right into:outCount];
        return;
        }
    if ([node isKindOfClass:[XTCallExprNode class]])
        {
        for (XTASTNode* a in ((XTCallExprNode*)node).arguments)
            {
            [self countSuperCallsTo:methodName in:a into:outCount];
            }
        return;
        }
    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        [self countSuperCallsTo:methodName in:((XTVariableDeclNode*)node).initialiser into:outCount];
        return;
        }
    }

/****************************************************************************\
|* Build `self.overriddenMethodLabels` — every (class, method) whose
|* signature is redeclared by some descendant class. Computed once
|* after the parent chain is linked so the per-call guard in
|* visitMethodCallExpr / visitCallExpr just does a set lookup.
|* Until PR8 assigns real virtual dispatch, any call that statically
|* resolves to one of these labels is potentially wrong — the
|* receiver might hold a subclass pointer at runtime and the user
|* expected the override to run.
\****************************************************************************/
/****************************************************************************\
|* Enforce `final`. Without these two checks it would be an unsound promise —
|* a way to silently devirtualise a method that IS overridden.
|*
|*  1. A subclass may not override a final method.
|*  2. A final method may not satisfy a protocol requirement: a protocol call
|*     dispatches through a vtable slot, and `final` is precisely a request for
|*     no slot, so the call would have nothing to land on.
\****************************************************************************/
- (void)checkFinalMethods
    {
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        for (XTMethodDeclNode* m in cls.methods)
            {
            // (1) does this method override a `final` one in an ancestor?
            for (XTClassDeclNode* a = cls.parentClass; a != nil; a = a.parentClass)
                {
                for (XTMethodDeclNode* am in a.methods)
                    {
                    if (!am.isFinal)
                        continue;
                    if (![self methodSignaturesMatch:am and:m])
                        continue;
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"'%@' cannot override '%@.%@' — it is declared 'final'",
                                                              cls.className, a.className, am.methodName]
                                             at:m.location ?: cls.location];
                    }
                }
            if (!m.isFinal)
                continue;
            // (2) does this final method satisfy a protocol the class adopts?
            for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                {
                for (NSString* pname in c.protocolNames)
                    {
                    XTProtocolDeclNode* proto = self.protocolsByName[pname];
                    if (!proto)
                        continue;
                    for (XTMethodDeclNode* reqM in proto.methods)
                        {
                        if (![self methodSignaturesMatch:m and:reqM])
                            continue;
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"'%@.%@' cannot be 'final' — it implements protocol "
                                                                  @"'%@', and a protocol call dispatches through a "
                                                                  @"vtable slot that 'final' removes",
                                                                  cls.className, m.methodName, pname]
                                                 at:m.location ?: cls.location];
                        }
                    }
                }
            }
        }
    }

// Per-class vtable size (bug 201, library build): parent's size + this class's
// own true roots (methods it declares that no visible ancestor declares),
// numbered after the parent's slots in sorted-label order. Assigns each own
// root its slot in _virtualSlotByLabel and memoises the total. Mirror of the
// self-hosted Vtable._vsizeFor.
- (NSUInteger)vsizeForClass:(XTClassDeclNode*)cls
                       memo:(NSMutableDictionary<NSString*, NSNumber*>*)memo
    {
    if (!cls.className)
        return 0;
    NSNumber* have = memo[cls.className];
    if (have)
        return have.unsignedIntegerValue;
    memo[cls.className] = @0; // cycle guard
    NSUInteger base = cls.parentClass ? [self vsizeForClass:cls.parentClass memo:memo] : 0;
    NSMutableArray<NSString*>* own = [NSMutableArray array];
    for (XTMethodDeclNode* m in cls.methods)
        {
        if (m.isStatic)
            continue;
        if ([m.methodName isEqualToString:@"init"])
            continue;
        if (m.isFinal)
            continue;
        BOOL ovr = NO;
        for (XTClassDeclNode* a = cls.parentClass; a != nil && !ovr; a = a.parentClass)
            for (XTMethodDeclNode* am in a.methods)
                if ([self methodSignaturesMatch:am and:m])
                    {
                    ovr = YES;
                    break;
                    }
        if (ovr)
            continue; // an override shares its root's slot
        [own addObject:[NSString stringWithFormat:@"_cls_%@_%@",
                                                  cls.className, (m.mangledName ?: m.methodName)]];
        }
    [own sortUsingSelector:@selector(compare:)];
    NSUInteger n = base;
    for (NSString* l in own)
        {
        if (self->_chainSlotByLabel[l])
            continue; // §4.2 chain, not vtable
        if (self->_virtualSlotByLabel[l])
            continue; // adopted: keep the library's number
        self->_virtualSlotByLabel[l] = @(n);
        n++;
        }
    memo[cls.className] = @(n);
    return n;
    }

- (void)computeOverriddenMethods
    {
    // Library build: the program is NOT whole. The overrides live in a client
    // that doesn't exist yet, so "nothing overrides this method" is not a fact
    // we're entitled to — devirtualising on it would make an app's override
    // permanently unreachable. Treat every instance method of every class as
    // an override root so it earns a vtable slot.
    //
    // Static methods are excluded: they take no `self`, so there is nothing to
    // dispatch on. `init` is excluded too — it runs on a known concrete class
    // at `new` time, never through a base pointer.
    if (self.libraryBuild)
        {
        for (XTClassDeclNode* cls in self.classesByName.allValues)
            {
            for (XTMethodDeclNode* m in cls.methods)
                {
                if (m.isStatic)
                    continue;
                if ([m.methodName isEqualToString:@"init"])
                    continue;
                // `final` — the author asserts no client overrides this, so it
                // needs no slot and keeps its direct call. Enforced below: an
                // override of a final method is an error, so this cannot
                // silently devirtualise something a client really does override.
                if (m.isFinal)
                    continue;
                NSString* key = m.mangledName ?: m.methodName;
                [self.overriddenMethodLabels addObject:
                                                 [NSString stringWithFormat:@"_cls_%@_%@", cls.className, key]];
                }
            }
        }
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if (cls.parentClass == nil)
            continue;
        for (XTMethodDeclNode* child in cls.methods)
            {
            // Walk ancestors looking for a matching signature. First
            // match wins — once we've recorded one override for the
            // ancestor's label, further matches against deeper
            // ancestors don't add new information.
            for (XTClassDeclNode* a = cls.parentClass; a != nil; a = a.parentClass)
                {
                XTMethodDeclNode* match = nil;
                for (XTMethodDeclNode* m in a.methods)
                    {
                    if ([self methodSignaturesMatch:m and:child])
                        {
                        match = m;
                        break;
                        }
                    }
                if (match)
                    {
                    // §4.3b: a chain-dispatched method that arrived through an
                    // interface cannot be overridden here — the iface does not
                    // carry the chain's shape (owner anchor, slot count), so
                    // the override could only be mis-slotted and the extending
                    // module's dispatch would silently never reach it. (In the
                    // extending compilation itself the flag is not yet stamped
                    // at this point, so the legitimate same-module override is
                    // unaffected.)
                    if (match.isChainMethod)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"Cannot override '%@.%@': it is a category method "
                                                                  @"dispatched through another module's category "
                                                                  @"chain, whose shape the interface does not carry. "
                                                                  @"Override it in the module that defines the "
                                                                  @"category (separate-compilation §4.3b)",
                                                                  a.className, match.methodName]
                                                 at:child.location];
                        break;
                        }
                    NSString* key = match.mangledName ?: match.methodName;
                    NSString* label = [NSString stringWithFormat:@"_cls_%@_%@",
                                                                 a.className, key];
                    [self.overriddenMethodLabels addObject:label];
                    break;
                    }
                }
            }
        }
    }

/****************************************************************************\
|* PR8: build the virtual-dispatch tables.
|*
|*  1. Assign every class a dense 0..N-1 class id (sorted by name
|*     for deterministic output). The id is stamped into the
|*     class-id byte at `new` time and indexes the runtime
|*     class-vtable pointer tables.
|*  2. Allocate a global vtable slot to every method that was
|*     flagged as an override root by `computeOverriddenMethods`.
|*     Iterating sorted labels keeps the slot assignment
|*     deterministic.
|*  3. For every class / slot pair, resolve the concrete impl to
|*     invoke: walk the class's chain from leaf toward the root;
|*     pick the nearest self-or-ancestor whose matching method's
|*     signature equals the root. A class that doesn't descend
|*     from the slot's root class gets no entry (the runtime
|*     never dispatches it at that slot — only matching instances
|*     reach that code path).
|*  4. Record the slot on every participant method's label so
|*     call sites sema has already resolved can look up whether
|*     virtual dispatch applies.
\****************************************************************************/
- (void)computeVirtualMethodTables
    {
    // (1) class-id assignment. Ids start at 1 so id 0 can act as
    // the universal "not a class" / "walk terminator" sentinel —
    // consumed by the `as` / `as?` downcast walker, which treats
    // hitting 0 in the __class_parent chain as "reached the root
    // without a match". Vtable lookup tables carry a leading
    // dummy slot at index 0 to keep the `LDA tbl,Y` addressing
    // aligned.
    NSArray* sortedClassNames = [self.classesByName.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger nextId = 1;
    for (NSString* name in sortedClassNames)
        {
        self->_classIdsByName[name] = @(nextId++);
        }

    // (2) slot assignment. Iterate root labels in sorted order so
    // the slot indices stay stable across runs.
    NSUInteger nextSlot = 0;

    // Adopt any slots an imported library already committed to. Its vtables are
    // emitted; we cannot renumber them, so its numbering is authoritative and ours
    // starts above the highest slot it used. (Before this, the client numbered from
    // 0 and dispatched through a `Proto@` receiver into the wrong slot entirely.)
    for (NSString* lbl in self.importedMethodSlots)
        {
        NSNumber* sl = self.importedMethodSlots[lbl];
        self->_virtualSlotByLabel[lbl] = sl;
        if (sl.unsignedIntegerValue + 1 > nextSlot)
            nextSlot = sl.unsignedIntegerValue + 1;
        // An imported method that HAS a slot participates in the vtable, and the
        // client has to know that — otherwise it builds no vtable for the imported
        // class at all and `new VApp()` leaves the object's vtable pointer NULL.
        // Direct calls devirtualise and work, so it looks fine; but the LIBRARY's own
        // internal virtual calls (`self.boot()`) then read through a null vtable.
        //
        // In a client nothing overrides an imported method, so it is not an override
        // root by the local rule — but under --emit-lib EVERY instance method is one,
        // which is exactly why the library dispatches on it. The interface says so;
        // honour it.
        [self.overriddenMethodLabels addObject:lbl];
        }
    // In itable mode a library's protocol NUMBERING is not ours to adopt — we never
    // dispatch through it. Adopting it is what would create the unsatisfiable
    // collision between two independent libraries.
    for (NSString* pn in (self.itableProtocols ? @{} : self.importedProtocolSlots))
        {
        NSMutableDictionary<NSString*, NSNumber*>* ps = [NSMutableDictionary dictionary];
        for (NSString* mn in self.importedProtocolSlots[pn])
            {
            NSNumber* sl = self.importedProtocolSlots[pn][mn];
            ps[mn] = sl;
            if (sl.unsignedIntegerValue + 1 > nextSlot)
                nextSlot = sl.unsignedIntegerValue + 1;
            }
        self.protocolMethodSlots[pn] = ps;
        }

    // Snapshotted only NOW: the imported labels above are roots too, and taking this
    // before folding them in is what left an imported class with no vtable at all.
    NSArray* sortedRootLabels = [self.overriddenMethodLabels.allObjects
        sortedArrayUsingSelector:@selector(compare:)];

    // ── Category-chain roots (separate-compilation §4.2) ────────────────────
    // A method a category added to a class from ANOTHER module cannot take a
    // vtable slot: the class's vtable was emitted when its library was built,
    // and every slot past its end is a read into the next object in that
    // library's data. Such a method is numbered in a CHAIN slot space of its
    // own — per extended class, 0-based, so the client's `<Host>$cat` table and
    // every subclass table it emits agree — and reached through vtable header
    // word 2. Only methods that are override roots need it at all; one nothing
    // overrides keeps its direct call, exactly as before.
    // Only the multi-module targets carry the chain word (it rides the same
    // switch as the ancestry link — see XTVtblHeaderWords). xt6502 and m68k link
    // as one module, so a category there is a compile-time merge and the vtable
    // path is the only path; they must not be given chain slots the lowering
    // will not emit a table for.
    BOOL chainCapable = (self.vtableConforms || self.itableProtocols);
    // (a) the category methods, by the class each was added to.
    NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* catByHost =
        [NSMutableDictionary dictionary];
    for (NSString* cname in (chainCapable ? sortedClassNames : @[]))
        {
        for (XTMethodDeclNode* m in self.classesByName[cname].methods)
            {
            if (!m.importedCategoryHost.length)
                continue;
            NSMutableSet* s = catByHost[m.importedCategoryHost];
            if (!s)
                {
                s = [NSMutableSet set];
                catByHost[m.importedCategoryHost] = s;
                }
            [s addObject:(m.mangledName ?: m.methodName)];
            }
        }
    // (b) the numbering, per host, in sorted order so it does not depend on the
    // order the parts were reached.
    NSMutableDictionary<NSString*, NSNumber*>* chainSlotCount = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* slotOfHost =
        [NSMutableDictionary dictionary];
    for (NSString* host in [catByHost.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        NSMutableDictionary<NSString*, NSNumber*>* sl = [NSMutableDictionary dictionary];
        NSUInteger k = 0;
        for (NSString* mn in [catByHost[host].allObjects
                 sortedArrayUsingSelector:@selector(compare:)])
            sl[mn] = @(k++);
        slotOfHost[host] = sl;
        chainSlotCount[host] = @(k);
        }
    self->_chainSlotCountByHost = chainSlotCount;
    // §4.3b: the owner anchor per host — the fallback table's symbol,
    // `<Host>$cat$<Cat1>[$<Cat2>…]` over this compilation's sorted category
    // names. Distinct per (host, extender) at the linker, so two modules may
    // each extend one class; entry [0] of every table in the family will hold
    // this symbol's address, and dispatch compares it to decide "mine or not".
    NSMutableDictionary<NSString*, NSString*>* anchors = [NSMutableDictionary dictionary];
    for (NSString* host in catByHost)
        {
        NSArray<NSString*>* ns = [(self->_catNamesByHost[host].allObjects ?: @[])
            sortedArrayUsingSelector:@selector(compare:)];
        anchors[host] = [NSString stringWithFormat:@"%@$cat$%@", host,
                                                   (ns.count ? [ns componentsJoinedByString:@"$"] : @"_ext")];
        }
    self->_chainAnchorByHost = anchors;
    // (c) every override root that IS such a method, or that overrides one in an
    // ancestor. It has to be the ancestor walk and not the label alone: a
    // subclass that overrides a category method is its own root
    // (`computeOverriddenMethods` records the nearest ancestor declaring it), and
    // keying off "this class declares a category method" would leave that root in
    // the VTABLE slot space — where its name sorts decides whether it works,
    // which is not a property any dispatch should have.
    for (NSString* rootLabel in sortedRootLabels)
        {
        if (![rootLabel hasPrefix:@"_cls_"])
            continue;
        NSString* tail = [rootLabel substringFromIndex:5];
        NSRange us = [tail rangeOfString:@"_"];
        if (us.location == NSNotFound)
            continue;
        NSString* rootCls = [tail substringToIndex:us.location];
        NSString* mangled = [tail substringFromIndex:us.location + 1];
        for (XTClassDeclNode* c = self.classesByName[rootCls]; c != nil; c = c.parentClass)
            {
            NSNumber* k = slotOfHost[c.className][mangled];
            if (!k)
                continue;
            self->_chainSlotByLabel[rootLabel] = k;
            self->_chainHostByLabel[rootLabel] = c.className;
            break;
            }
        }

    if (self.libraryBuild)
        {
        // Per-class deterministic numbering (bug 201): a root method's slot is
        // its owning class's PARENT vtable size + its index among the class's
        // own true roots (sorted) — a pure function of the class's ancestor
        // chain, which every independently compiled object sees identically, so
        // two objects agree and an override lands at its root's slot in every
        // one. A program-global counter numbers the same class differently per
        // object (each sees a different subset), which is the split-build crash.
        NSMutableDictionary<NSString*, NSNumber*>* vmemo = [NSMutableDictionary dictionary];
        for (NSString* cn in [self.classesByName.allKeys
                 sortedArrayUsingSelector:@selector(compare:)])
            {
            NSUInteger vs = [self vsizeForClass:self.classesByName[cn] memo:vmemo];
            if (vs > nextSlot)
                nextSlot = vs;
            }
        }
    else
        {
        for (NSString* rootLabel in sortedRootLabels)
            {
            if (self->_virtualSlotByLabel[rootLabel])
                continue; // imported: already fixed
            if (self->_chainSlotByLabel[rootLabel])
                continue; // §4.2: chain, not vtable
            self->_virtualSlotByLabel[rootLabel] = @(nextSlot);
            nextSlot++;
            }
        }
    // PR9: each protocol method picks up its own vtable slot,
    // independent of whether any class literally "overrides" it.
    // Every conforming class's matching implementation lands in
    // the same slot so dispatch through a `Proto@` receiver reaches
    // the right body regardless of the leaf class id.
    NSArray* sortedProtoNames = [self.protocolsByName.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* pname in sortedProtoNames)
        {
        XTProtocolDeclNode* proto = self.protocolsByName[pname];
        NSMutableDictionary<NSString*, NSNumber*>* slots = self.protocolMethodSlots[pname];
        if (!slots)
            {
            slots = [NSMutableDictionary dictionary];
            self.protocolMethodSlots[pname] = slots;
            }
        for (XTMethodDeclNode* m in proto.methods)
            {
            if (slots[m.methodName])
                continue; // imported: the library fixed it
            slots[m.methodName] = @(nextSlot);
            nextSlot++;
            }
        }
    self.totalVirtualSlots = nextSlot;
    // XTC_DUMP_VSLOTS=1 prints the slot assignment to stderr: every override
    // root with its slot, then every protocol method with its slot. The
    // numbering is an ABI fact shared with the self-hosted analyser
    // (selfhost/sema/), and "which methods are roots" is the part that is hard
    // to infer from the outside — a root nothing overrides in the file you are
    // looking at still consumes its slot.
    if (getenv("XTC_DUMP_VSLOTS"))
        {
        NSArray* rl = [self->_virtualSlotByLabel.allKeys sortedArrayUsingComparator:
                                                             ^NSComparisonResult(NSString* a, NSString* b) {
                                                               return [self->_virtualSlotByLabel[a] compare:self->_virtualSlotByLabel[b]];
                                                             }];
        for (NSString* l in rl)
            fprintf(stderr, "vslot root  %2ld  %s\n",
                    (long)[self->_virtualSlotByLabel[l] integerValue], l.UTF8String);
        for (NSString* pn in [self.protocolMethodSlots.allKeys sortedArrayUsingSelector:@selector(compare:)])
            for (NSString* mn in self.protocolMethodSlots[pn])
                fprintf(stderr, "vslot proto %2ld  %s.%s\n",
                        (long)[self.protocolMethodSlots[pn][mn] integerValue],
                        pn.UTF8String, mn.UTF8String);
        fprintf(stderr, "vslot total %lu\n", (unsigned long)self.totalVirtualSlots);
        }
    if (self.totalVirtualSlots == 0)
        return; // nothing virtual in this program

    // Fill protocol slots for every conforming class. A class conforms
    // to protocol P when it lists P in its `protocolNames` and provides
    // a matching-signature method (own or inherited). Missing / wrong-
    // signature methods are diagnosed; matches bind the class's impl
    // to the protocol's slot alongside the PR8 override-fill below.
    //
    // SORTED by class name, not dictionary order: the override fill below
    // REBINDS a participant label to its root's slot as it goes, so which
    // classes see the rebound number depends on iteration order — with
    // dictionary order that made the emitted vtable entry ARRAYS
    // hash-dependent (the synthesised-description chain is where it showed:
    // whether a grandchild's slot-0 entry is filled depended on whether its
    // parent was visited first). The affected entries are map-unreachable,
    // so this changes bytes, never dispatch (task #36; the self-hosted twin
    // mirrors the sorted order).
    NSArray<NSString*>* fillOrder =
        [self.classesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    // The FILL reads slots from a PRISTINE snapshot: the participant rebind
    // below serves CALL SITES (a statically-resolved descendant override
    // still finds the vtable slot), and letting it also steer later classes'
    // fills made every table's content depend on iteration order. With the
    // snapshot, each class's fill is a pure function of the assignment —
    // order-independent, and exactly reproducible by the self-hosted twin.
    NSDictionary<NSString*, NSNumber*>* pristineSlots =
        [self->_virtualSlotByLabel copy];
    for (NSString* fillName in fillOrder)
        {
        XTClassDeclNode* cls = self.classesByName[fillName];
        // Which (protocol, method) already claimed each slot in THIS class's vtable.
        // Two INDEPENDENTLY built libraries both number their protocol slots from the
        // same base — neither knows the other exists — so a class conforming to a
        // protocol from each can be handed the SAME slot twice. A flat vtable cannot
        // satisfy that: the library's own dispatch sites already bake its number in,
        // so we cannot renumber it. One impl would overwrite the other and every call
        // through the loser would silently run the wrong method.
        //
        // Refuse. (The real fix is to take protocols out of the flat slot space
        // altogether — see private:docs/Design/protocol-slot-collisions.md.)
        NSMutableDictionary<NSNumber*, NSString*>* claimed = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSArray<NSString*>*>* itabs = [NSMutableDictionary dictionary];
        for (NSString* pname in cls.protocolNames)
            {
            XTProtocolDeclNode* proto = self.protocolsByName[pname];
            if (!proto)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Unknown protocol '%@' on class '%@'",
                                                          pname, cls.className]
                                         at:cls.location];
                continue;
                }
            for (XTMethodDeclNode* reqM in proto.methods)
                {
                XTMethodDeclNode* impl = nil;
                XTClassDeclNode* implCls = nil;
                for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                    {
                    for (XTMethodDeclNode* cm in c.methods)
                        {
                        if ([self methodSignaturesMatch:cm and:reqM])
                            {
                            impl = cm;
                            implCls = c;
                            break;
                            }
                        }
                    if (impl)
                        break;
                    }
                if (!impl)
                    {
                    // An `optional` method may be omitted: its slot stays
                    // empty, which the backends emit as a null word — and
                    // that null is exactly what makes `&obj.method` come
                    // back falsy at the call site.
                    if (reqM.isOptional)
                        continue;
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Class '%@' claims conformance to protocol '%@' "
                                                              @"but doesn't implement '%@'",
                                                              cls.className, pname, reqM.methodName]
                                             at:cls.location];
                    continue;
                    }
                NSNumber* slotNum = self.protocolMethodSlots[pname][reqM.methodName];
                if (!slotNum)
                    continue;
                NSString* claimKey = [NSString stringWithFormat:@"%@.%@", pname, reqM.methodName];
                NSString* prior = claimed[slotNum];
                if (prior && ![prior isEqualToString:claimKey] && !self.itableProtocols)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Class '%@' cannot conform to both '%@' and '%@': they were "
                                                              @"assigned the same vtable slot (%@) by DIFFERENT libraries, "
                                                              @"each of which numbered its protocols without knowing the "
                                                              @"other existed. One would silently overwrite the other. "
                                                              @"Build the libraries so one imports the other (then its "
                                                              @"numbering composes), or drop one conformance.",
                                                              cls.className, prior, claimKey, slotNum]
                                             at:cls.location];
                    continue;
                    }
                claimed[slotNum] = claimKey;
                NSString* implLabel = [NSString stringWithFormat:@"_cls_%@_%@",
                                                                 implCls.className,
                                                                 (impl.mangledName ?: impl.methodName)];
                // Every conforming class's impl picks up the slot.
                self->_virtualSlotByLabel[implLabel] = slotNum;
                }
            }
        // The itable rows. Walk the ANCESTOR CHAIN, not just this class's own
        // `protocolNames` — conformance is inherited. Every class implicitly descends
        // from Object, which conforms to Hashable/Comparable, so a plain `class Box {}`
        // is reachable through `Hashable@` without listing anything. Building the itable
        // from the direct list only left those rows out, the scan missed, and dispatch
        // called through null. (The vtable fill has always walked the chain; the itable
        // has to agree with it.)
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            {
            for (NSString* pname in c.protocolNames)
                {
                if (itabs[pname])
                    continue; // nearest declaration wins
                XTProtocolDeclNode* proto = self.protocolsByName[pname];
                if (!proto)
                    continue;
                // One impl symbol per method, in the protocol's DECLARATION order.
                // `@""` where an `optional` is unimplemented — a null entry, which is
                // exactly what `&obj.method` tests for.
                NSMutableArray<NSString*>* row = [NSMutableArray array];
                for (XTMethodDeclNode* reqM in proto.methods)
                    {
                    XTMethodDeclNode* impl = nil;
                    XTClassDeclNode* implCls = nil;
                    for (XTClassDeclNode* k = cls; k != nil && !impl; k = k.parentClass)
                        for (XTMethodDeclNode* cm in k.methods)
                            if ([self methodSignaturesMatch:cm and:reqM])
                                {
                                impl = cm;
                                implCls = k;
                                break;
                                }
                    [row addObject:(impl ? [NSString stringWithFormat:@"%@$%@",
                                                                      implCls.className, (impl.mangledName ?: impl.methodName)]
                                         : @"")];
                    }
                itabs[pname] = row;
                }
            }
        if (itabs.count)
            cls.protocolImplSymbols = itabs;
        }

    // (3) + (4) vtable fill per class.
    for (NSString* cname in sortedClassNames)
        {
        XTClassDeclNode* cls = self.classesByName[cname];
        NSMutableDictionary<NSNumber*, NSString*>* slots = [NSMutableDictionary dictionary];
        self->_virtualImplByClassAndSlot[cname] = slots;
        // The IR lowering builds this class's vtable + methodSlot from the
        // numbering below (so vtable slot N == resolvedVirtualSlot N):
        // slotSym[slot] = the impl method-function symbol, nameSlot[name] =
        // the slot a virtual call by that source name dispatches through.
        NSMutableDictionary<NSNumber*, NSString*>* slotSym = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* nameSlot = [NSMutableDictionary dictionary];
        // §4.2: the same two maps for the category-chain slot space, filled by
        // the same walk. A class touches these only if it is, or descends from,
        // an extended class — `chainHost` stays nil otherwise and nothing is
        // stamped, so a program with no imported category is bit-identical.
        NSMutableDictionary<NSNumber*, NSString*>* chainSym = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, NSNumber*>* chainNameSlot = [NSMutableDictionary dictionary];
        NSString* chainHost = nil;
        for (NSString* rootLabel in sortedRootLabels)
            {
            // Parse `_cls_<A>_<mangled>` — `_cls_` prefix has 5
            // chars; the rest splits at the first underscore that
            // separates class name from mangled tail. We find the
            // root method by searching class A's methods for a
            // matching mangled-name key.
            if (![rootLabel hasPrefix:@"_cls_"])
                continue;
            NSString* tail = [rootLabel substringFromIndex:5];
            NSRange us = [tail rangeOfString:@"_"];
            if (us.location == NSNotFound)
                continue;
            NSString* rootClsName = [tail substringToIndex:us.location];
            NSString* rootMangled = [tail substringFromIndex:us.location + 1];
            XTClassDeclNode* rootCls = self.classesByName[rootClsName];
            if (!rootCls)
                continue;
            XTMethodDeclNode* rootMethod = nil;
            for (XTMethodDeclNode* m in rootCls.methods)
                {
                NSString* k = m.mangledName ?: m.methodName;
                if ([k isEqualToString:rootMangled])
                    {
                    rootMethod = m;
                    break;
                    }
                }
            if (!rootMethod)
                continue;

            // cls must descend from rootCls (or BE rootCls) to
            // participate in this slot.
            BOOL descendant = NO;
            for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                {
                if (c == rootCls)
                    {
                    descendant = YES;
                    break;
                    }
                }
            if (!descendant)
                continue;

            // Nearest self-or-ancestor whose signature matches the root.
            XTMethodDeclNode* impl = nil;
            XTClassDeclNode* implCls = nil;
            for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                {
                for (XTMethodDeclNode* cm in c.methods)
                    {
                    if ([self methodSignaturesMatch:cm and:rootMethod])
                        {
                        impl = cm;
                        implCls = c;
                        break;
                        }
                    }
                if (impl)
                    break;
                if (c == rootCls)
                    break;
                }
            if (!impl || !implCls)
                continue;
            NSString* implLabel = [NSString stringWithFormat:@"_cls_%@_%@",
                                                             implCls.className,
                                                             (impl.mangledName ?: impl.methodName)];
            NSNumber* chainNum = self->_chainSlotByLabel[rootLabel];
            if (chainNum)
                {
                // §4.2 root: the impl goes in this class's chain table, not its
                // vtable. `chainHost` is the extended class — every class in the
                // family shares its numbering, so a base-pointer call indexes the
                // same slot whichever subclass it lands on.
                //
                // One chain word per class means ONE host's slot space: a class
                // descending from TWO chain-extended ancestors cannot carry
                // both, and a silent pick would drop the other host's
                // overrides — refuse it (§4.3b).
                NSString* newHost = self->_chainHostByLabel[rootLabel];
                if (chainHost && newHost && ![chainHost isEqualToString:newHost])
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Class '%@' descends from two chain-extended classes "
                                                              @"('%@' and '%@'): one category-chain word cannot carry "
                                                              @"both slot spaces. Extend only one class on any "
                                                              @"inheritance path (separate-compilation §4.3b)",
                                                              cls.className, chainHost, newHost]
                                             at:cls.location];
                    continue;
                    }
                chainHost = newHost;
                chainSym[chainNum] = [NSString stringWithFormat:@"%@$%@",
                                                                implCls.className,
                                                                (impl.mangledName ?: impl.methodName)];
                chainNameSlot[rootMethod.methodName] = chainNum;
                self->_chainSlotByLabel[implLabel] = chainNum;
                self->_chainHostByLabel[implLabel] = chainHost;
                // §4.3b: mark it for the interface, so a client importing this
                // class knows the method is chain-dispatched and refuses to
                // override it (the iface does not carry the chain's shape).
                impl.isChainMethod = YES;
                continue;
                }
            NSNumber* slotNum = pristineSlots[rootLabel];
            if (!slotNum)
                slotNum = self->_virtualSlotByLabel[rootLabel];
            // Per-class numbering (bug 201, library build) gives a slot only to a
            // TRUE root; an override's own label has none (its impl is placed at
            // the root's slot when this loop reaches the root label). Without the
            // global counter's "every label gets a number", a missing slot here
            // is an override label — skip it rather than use a nil dictionary key.
            if (!slotNum)
                continue;
            slots[slotNum] = implLabel;
            slotSym[slotNum] = [NSString stringWithFormat:@"%@$%@",
                                                          implCls.className,
                                                          (impl.mangledName ?: impl.methodName)];
            nameSlot[rootMethod.methodName] = slotNum;
            // Participant label picks up the same slot so call
            // sites that statically resolved to a descendant's
            // override still hit the vtable path.
            self->_virtualSlotByLabel[implLabel] = slotNum;
            }
        // PR9: fill protocol slots for classes that conform. For
        // every protocol the class lists (directly or through an
        // ancestor), find the class's matching impl and store it
        // at the protocol-method's slot.
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            {
            for (NSString* pname in c.protocolNames)
                {
                XTProtocolDeclNode* proto = self.protocolsByName[pname];
                if (!proto)
                    continue;
                NSDictionary<NSString*, NSNumber*>* pslots =
                    self.protocolMethodSlots[pname];
                for (XTMethodDeclNode* reqM in proto.methods)
                    {
                    NSNumber* slotNum = pslots[reqM.methodName];
                    if (!slotNum)
                        continue;
                    if (slots[slotNum])
                        continue; // already filled
                    XTMethodDeclNode* impl = nil;
                    XTClassDeclNode* implCls = nil;
                    for (XTClassDeclNode* w = cls; w != nil; w = w.parentClass)
                        {
                        for (XTMethodDeclNode* cm in w.methods)
                            {
                            if ([self methodSignaturesMatch:cm and:reqM])
                                {
                                impl = cm;
                                implCls = w;
                                break;
                                }
                            }
                        if (impl)
                            break;
                        }
                    if (!impl)
                        continue;
                    NSString* implLabel =
                        [NSString stringWithFormat:@"_cls_%@_%@",
                                                   implCls.className,
                                                   (impl.mangledName ?: impl.methodName)];
                    slots[slotNum] = implLabel;
                    slotSym[slotNum] = [NSString stringWithFormat:@"%@$%@",
                                                                  implCls.className,
                                                                  (impl.mangledName ?: impl.methodName)];
                    nameSlot[reqM.methodName] = slotNum;
                    }
                }
            }
        // Stamp the authoritative vtable onto the class node for the IR
        // lowering: a slot→impl-symbol array sized to totalVirtualSlots
        // (@"" for slots this class doesn't fill) plus methodName→slot, so
        // the lowering's vtable slot N holds the impl that
        // resolvedVirtualSlot == N dispatches to.
        NSMutableArray<NSString*>* symArr =
            [NSMutableArray arrayWithCapacity:self.totalVirtualSlots];
        for (NSUInteger i = 0; i < self.totalVirtualSlots; i++)
            {
            NSString* s = slotSym[@(i)];
            [symArr addObject:(s ?: @"")];
            }
        cls.vtableSlotSymbols = symArr;
        cls.vtableMethodSlots = nameSlot;
        // XTC_DUMP_VSLOTS=1 also prints the FILLED table per class — the thing
        // the back end emits — next to the root map printed above. Bug 136 was
        // the two disagreeing in a library build, and only a dump of both
        // sides shows it.
        if (getenv("XTC_DUMP_VSLOTS"))
            {
            fprintf(stderr, "vslot fill %-16s total=%lu:", cls.className.UTF8String,
                    (unsigned long)self.totalVirtualSlots);
            for (NSUInteger i = 0; i < symArr.count; i++)
                if (symArr[i].length)
                    fprintf(stderr, " [%lu]=%s", (unsigned long)i, symArr[i].UTF8String);
            fprintf(stderr, "\n");
            }
        // §4.2: the chain table, sized to the HOST's slot count so every class in
        // the family lays out identically — a subclass that overrides only slot 1
        // still needs slot 0 present and pointing at the class it inherited it
        // from, or a base-pointer call through slot 0 reads the wrong entry.
        if (chainHost)
            {
            // An EXTERNAL family member other than the host gets NO table: its
            // vtable lives in its own module with a null chain word, so a table
            // emitted here would be unreachable dead weight — and two extenders
            // importing the same library would both emit it, colliding at the
            // link on a symbol neither can use (`Derived2$cat` defined twice).
            // The external HOST is the exception: its table here IS this
            // compilation's fallback/anchor.
            BOOL extNonHost = cls.isExternal && ![cls.className isEqualToString:chainHost];
            if (!extNonHost)
                {
                NSUInteger n = _chainSlotCountByHost[chainHost].unsignedIntegerValue;
                NSMutableArray<NSString*>* cArr = [NSMutableArray arrayWithCapacity:n];
                for (NSUInteger i = 0; i < n; i++)
                    [cArr addObject:(chainSym[@(i)] ?: @"")];
                cls.categoryChainSymbols = cArr;
                cls.categoryChainHost = chainHost;
                cls.categoryChainMethodSlots = chainNameSlot;
                cls.categoryChainAnchor = self->_chainAnchorByHost[chainHost];
                }
            }
        }
    }

/****************************************************************************\
|* Populate `self->_recursiveFunctions` with every label F such that F is
|* reachable from itself via one or more forward edges in `self.callEdges`.
|* Covers both direct self-loops (F → F) and mutual recursion
|* (F → G → F, F → G → H → F, …). Implemented as per-function forward
|* BFS rather than a full Tarjan SCC — the O(V·E) cost is negligible
|* at xtc scale (a few hundred functions at most) and the boolean
|* "is F recursive" is all we need; full SCC identity is overkill.
\****************************************************************************/
- (void)detectRecursiveFunctions
    {
    for (NSString* start in self.callEdges)
        {
        NSMutableSet<NSString*>* visited = [NSMutableSet set];
        NSMutableArray<NSString*>* frontier =
            [[self.callEdges[start] allObjects] mutableCopy];
        while (frontier.count > 0)
            {
            NSString* node = frontier.lastObject;
            [frontier removeLastObject];
            if ([node isEqualToString:start])
                {
                [self->_recursiveFunctions addObject:start];
                break;
                }
            if ([visited containsObject:node])
                continue;
            [visited addObject:node];
            NSSet* next = self.callEdges[node];
            for (NSString* n in next)
                {
                if (![visited containsObject:n])
                    [frontier addObject:n];
                }
            }
        }
    }

/****************************************************************************\
|* Populate `self->_maxCallDepth` — the longest acyclic forward call path
|* rooted at each label in `self.callEdges`. Leaves get 0; a label that
|* only calls leaves gets 1; etc. Recursive labels are skipped (the
|* depth is unbounded in principle — the manifest emitter records
|* absence-of-key rather than a sentinel, so a downstream tool reading
|* the manifest knows the depth is conservatively unknown).
|*
|* Implemented as iterative DFS with memoisation. The call graph is
|* small enough (a few hundred labels, fanout ≤ a handful) that
|* explicit stack management isn't strictly needed, but the iterative
|* form avoids any chance of blowing the Objective-C recursion stack
|* on a pathological input.
\****************************************************************************/
- (void)computeMaxCallDepths
    {
    NSMutableSet<NSString*>* roots = [NSMutableSet set];
    [roots addObjectsFromArray:self.callEdges.allKeys];
    for (NSString* caller in self.callEdges)
        [roots unionSet:self.callEdges[caller]];

    for (NSString* root in roots)
        {
        if (self->_maxCallDepth[root])
            continue;
        if ([self->_recursiveFunctions containsObject:root])
            continue;
        [self depthOfLabel:root visiting:[NSMutableSet set]];
        }
    }

/****************************************************************************\
|* Recursive helper for `computeMaxCallDepths`. Returns the length of
|* the longest acyclic forward path from `label`, memoising into
|* `self->_maxCallDepth` on the way back up. `visiting` guards against
|* cycles picked up through edges that the recursion detector didn't
|* flag (shouldn't happen — defensive only); any such edge is skipped
|* and the computed depth for the enclosing label is unmemoised.
\****************************************************************************/
- (NSInteger)depthOfLabel:(NSString*)label
                 visiting:(NSMutableSet<NSString*>*)visiting
    {
    if ([self->_recursiveFunctions containsObject:label])
        return -1;
    NSNumber* cached = self->_maxCallDepth[label];
    if (cached)
        return cached.integerValue;
    if ([visiting containsObject:label])
        return -1; // defensive
    [visiting addObject:label];

    NSInteger best = 0;
    BOOL allChildrenSound = YES;
    for (NSString* child in self.callEdges[label])
        {
        NSInteger childDepth = [self depthOfLabel:child visiting:visiting];
        if (childDepth < 0)
            {
            allChildrenSound = NO;
            continue;
            }
        if (childDepth + 1 > best)
            best = childDepth + 1;
        }
    [visiting removeObject:label];
    if (allChildrenSound)
        {
        self->_maxCallDepth[label] = @(best);
        }
    return best;
    }

/****************************************************************************\
|* Assign every variadic function and method to the single shared
|* pack-buffer slot at $04B0. Pre-collapse (stage 4c + follow-up) the
|* pool held 5 separate slots — slot 0 for Stdio.printf/printfAt, slots
|* 1..4 for user varargs — so that a chain of variadic calls couldn't
|* step on each other's live va_lists. With the variadic-reentrance
|* check in sema enforcing "no active variadic calls another active
|* variadic", the buffer is always safely re-used top-down by a single
|* caller; the 5-slot budget and its "6 varargs" overflow error become
|* unnecessary. Every variadic just gets slot 0.
\****************************************************************************/
- (void)assignVarargsSlots:(XTProgramNode*)program
    {
    for (XTASTNode* decl in program.declarations)
        {
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            if (fn.isVarArgs)
                fn.varargsSlot = 0;
            }
        else if ([decl isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            for (XTMethodDeclNode* m in cls.methods)
                {
                if (m.isVarArgs)
                    m.varargsSlot = 0;
                }
            }
        }
    }

/****************************************************************************\
|* Dispatch a single AST node through the visitor interface for analysis.
|* @param node  The AST node to analyse; nil is a no-op.
\****************************************************************************/
- (void)analyzeNode:(XTASTNode*)node
    {
    if (!node)
        return;
    [node acceptVisitor:self];
    }

#pragma mark - Cloak-safety inference

/****************************************************************************\
|* Argument-window threshold: total param-byte width above which the
|* banked calling convention spills into a per-fn `_args_<fn>` buffer
|* in main RAM. Mirrors XT_ARG_WINDOW_SIZE in the banked codegen.
\****************************************************************************/
#define XTC_CLOAK_REG_WINDOW 16

/****************************************************************************\
|* Pessimistic inline-asm scanner. Returns YES iff any line in `block`
|* mentions a token that we treat as "touches the xtc software stack."
|* The xtc stack pointer lives at $89/$8A on banked targets, with the
|* base symbol `stack_low`. Indirect-Y reads through it look like
|* `(sp),Y` (lower-cased mnemonic chunk). We over-match — false
|* positives just leave a method out of the auto-cloak set, while a
|* missed reference would crash at runtime under PORTB=$30.
\****************************************************************************/
static BOOL asmBlockTouchesXtcStack(XTAsmBlockNode* block)
    {
    NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString* raw in block.lines)
        {
        NSString* line = [raw stringByTrimmingCharactersInSet:ws];
        if (line.length == 0)
            continue;
        // Strip trailing comment so a `; touches stack on x10` stays
        // benign, while a comment-stripped instruction still gets
        // matched.
        NSRange comment = [line rangeOfString:@";"];
        if (comment.location != NSNotFound)
            {
            line = [line substringToIndex:comment.location];
            }
        NSString* upper = [line uppercaseString];
        if ([upper rangeOfString:@"$89"].location != NSNotFound)
            return YES;
        if ([upper rangeOfString:@"$8A"].location != NSNotFound)
            return YES;
        if ([upper rangeOfString:@"(SP)"].location != NSNotFound)
            return YES;
        if ([upper rangeOfString:@"STACK_LOW"].location != NSNotFound)
            return YES;
        if ([upper rangeOfString:@"STACK_TOP"].location != NSNotFound)
            return YES;
        }
    return NO;
    }

/****************************************************************************\
|* Recursive AST walker — returns YES iff any inline-asm block reachable
|* from `node` touches the xtc stack. Conservative: every node kind we
|* don't know how to descend into bails to NO (the asm walker only
|* fires on XTAsmBlockNode).
\****************************************************************************/
static BOOL nodeContainsStackTouchingAsm(XTASTNode* node);
static BOOL nodeContainsStackTouchingAsm(XTASTNode* node)
    {
    if (!node)
        return NO;
    switch (node.nodeKind)
        {
    case XTASTNodeKindAsmBlock:
        return asmBlockTouchesXtcStack((XTAsmBlockNode*)node);
    case XTASTNodeKindBlock:
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            if (nodeContainsStackTouchingAsm(s))
                return YES;
            }
        return NO;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        return nodeContainsStackTouchingAsm(n.condition) || nodeContainsStackTouchingAsm(n.thenBlock) || nodeContainsStackTouchingAsm(n.elseBlock);
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* n = (XTWhileNode*)node;
        return nodeContainsStackTouchingAsm(n.condition) || nodeContainsStackTouchingAsm(n.body);
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* n = (XTForCStyleNode*)node;
        return nodeContainsStackTouchingAsm(n.loopInit) || nodeContainsStackTouchingAsm(n.condition) || nodeContainsStackTouchingAsm(n.increment) || nodeContainsStackTouchingAsm(n.body);
        }
    case XTASTNodeKindForIn:
        {
        XTForInNode* n = (XTForInNode*)node;
        return nodeContainsStackTouchingAsm(n.loopVar) || nodeContainsStackTouchingAsm(n.collection) || nodeContainsStackTouchingAsm(n.body);
        }
    case XTASTNodeKindReturn:
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            {
            if (nodeContainsStackTouchingAsm(v))
                return YES;
            }
        return NO;
        }
    case XTASTNodeKindExprStatement:
        return nodeContainsStackTouchingAsm(((XTExpressionStatementNode*)node).expression);
    default:
        return NO;
        }
    }

/****************************************************************************\
|* Sum the byte widths of every parameter on a function/method. Used to
|* gate "args fit in the $B0..$BF register window" — beyond that, the
|* caller spills into a per-fn `_args_<fn>` buffer in main RAM, which
|* is reachable under PORTB=$30 but the spill protocol itself uses the
|* xtc stack (the caller's args are pushed to (SP),Y before the JSR).
|* So wide-param functions can't currently be cloak-safe.
\****************************************************************************/
static NSUInteger sumParamBytes(NSArray<XTParamNode*>* params)
    {
    NSUInteger total = 0;
    for (XTParamNode* p in params)
        {
        total += p.paramType ? p.paramType.byteWidth : 1;
        }
    return total;
    }

/****************************************************************************\
|* Per-decl direct cloak-safety verdict. A YES from this function only
|* means the decl's own body emits cloak-compatible code; transitive
|* safety (every callee also safe) is computed in a fixed-point pass
|* over `self.callEdges` after all direct verdicts are known.
\****************************************************************************/
- (BOOL)isDirectlyCloakSafeFunction:(XTFunctionDeclNode*)fn
                              label:(NSString*)label
    {
    if (fn.isIrq || fn.isVbi)
        return NO; // RTI epilogue, not RTS — separate ABI
    if ([self.externalFunctions containsObject:label])
        return NO;
    if (!fn.body)
        return NO;
    if (sumParamBytes(fn.parameters) > XTC_CLOAK_REG_WINDOW)
        return NO;
    NSNumber* eligible = self->_staticFrameEligible[label];
    if (!eligible || !eligible.boolValue)
        return NO;
    if (nodeContainsStackTouchingAsm(fn.body))
        return NO;
    // Address-taken functions reach the call site through the
    // _xtc_ijsr trampoline (`JMP ($00BE)` after the caller stages
    // the target address), which doesn't know to wrap the call in
    // a cloaked PORTB bracket. A cloaked target reached via fn-
    // pointer would JMP into bytes that map to a numbered bank
    // (PORTB ≠ $32), not the cloaked image at $4000+ in main RAM.
    // Even cleanly-tracked &-sites count: the CFA edge folding
    // helps eligibility analysis reason about callees but doesn't
    // change the *runtime* dispatch shape — every fn-pointer call
    // still goes through the bracket-less ijsr trampoline.
    // fn_pointer.xc's header already documents this constraint
    // for `:banked` targets; the same logic applies to `:cloaked`.
    if ([self->_addressTakenFunctions containsObject:label])
        return NO;
    return YES;
    }

- (BOOL)isDirectlyCloakSafeMethod:(XTMethodDeclNode*)m
                            label:(NSString*)label
                          inClass:(XTClassDeclNode*)cls
    {
    if ([self.externalFunctions containsObject:label])
        return NO;
    if (!m.body)
        return NO;
    if (sumParamBytes(m.parameters) > XTC_CLOAK_REG_WINDOW)
        return NO;
    NSNumber* eligible = self->_staticFrameEligible[label];
    if (!eligible || !eligible.boolValue)
        return NO;
    if (nodeContainsStackTouchingAsm(m.body))
        return NO;
    // Heap-class instance methods are eligible: the cloaked emit
    // routes (self),Y access through `_ivar_load_byte` /
    // `_ivar_store_byte` (Phase 1c), which save+set+restore PORTB
    // around the access. The frame-restore epilogue uses
    // `_arc_retval_lo` / `_arc_retval_hi` static slots to preserve
    // A/X across the hw-stack frame pops on stack-in-bank-0 layouts.
    return YES;
    }

/****************************************************************************\
|* Compute the auto-cloak verdict for every function/method in the
|* program. Two-phase:
|*   1. Per-decl direct safety (own body is cloak-compatible).
|*   2. Fixed-point: any decl with a non-cloak-safe callee becomes
|*      not-cloak-safe.
|*
|* Honours `self.callEdges` (already merged with the indirect-call set
|* by `computeStaticFrameEligibility`). Indirect/virtual call sites that
|* sema couldn't resolve to concrete targets dragged the decl's
|* `staticFrameEligible` to NO already, so the direct-safety check
|* filters them out automatically.
|*
|* Result lands in `self->_cloakInferredSafe`. Codegen reads this when
|* `--auto-cloak` is enabled.
\****************************************************************************/
- (void)inferCloakSafety:(XTProgramNode*)program
    {
    [self->_cloakInferredSafe removeAllObjects];

    // Phase 1: direct safety for every fn / method we can see.
    for (XTASTNode* decl in program.declarations)
        {
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            NSString* label = [@"_fn_" stringByAppendingString:
                                           (fn.mangledName ?: fn.funcName ?
                                                                          : @"")];
            BOOL safe = [self isDirectlyCloakSafeFunction:fn label:label];
            self->_cloakInferredSafe[label] = @(safe);
            }
        else if ([decl isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            for (XTMethodDeclNode* m in cls.methods)
                {
                NSString* label = [NSString stringWithFormat:@"_cls_%@_%@",
                                                             cls.className,
                                                             (m.mangledName ?: m.methodName ?
                                                                                            : @"")];
                BOOL safe = [self isDirectlyCloakSafeMethod:m
                                                      label:label
                                                    inClass:cls];
                self->_cloakInferredSafe[label] = @(safe);
                }
            }
        }

    // Phase 2: fixed-point. Any decl whose callee set contains a
    // not-safe label becomes not-safe itself. Repeat until stable.
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSString* label in self->_cloakInferredSafe.allKeys)
            {
            if (![self->_cloakInferredSafe[label] boolValue])
                continue;
            NSSet<NSString*>* callees = self.callEdges[label];
            if (!callees)
                continue;
            for (NSString* callee in callees)
                {
                NSNumber* cs = self->_cloakInferredSafe[callee];
                // Unknown callee (not in the table — e.g. external,
                // or runtime-asm helper not represented as a decl):
                // unsafe by default. Runtime helpers that *are*
                // cloak-safe (the stackSafe-tagged arithmetic
                // routines) get pulled into cloaked by the existing
                // pure-cloaked promotion pass downstream — they
                // don't need to be in this table for that to work.
                if (!cs || !cs.boolValue)
                    {
                    self->_cloakInferredSafe[label] = @NO;
                    changed = YES;
                    break;
                    }
                }
            }
        }

    if (getenv("XTC_DEBUG_CLOAK_INFER"))
        {
        NSArray* sorted = [self->_cloakInferredSafe.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        NSUInteger nSafe = 0;
        for (NSString* k in sorted)
            {
            if ([self->_cloakInferredSafe[k] boolValue])
                nSafe++;
            }
        fprintf(stderr,
                "auto-cloak: %lu / %lu decls are cloak-safe\n",
                (unsigned long)nSafe, (unsigned long)sorted.count);
        for (NSString* k in sorted)
            {
            BOOL safe = [self->_cloakInferredSafe[k] boolValue];
            fprintf(stderr, "  %s  %s\n",
                    safe ? "SAFE  " : "unsafe",
                    k.UTF8String);
            }
        }
    }

#pragma mark - Auto-synthesised class `description()`

// Build the synthesised `description()` body for `cls`:
//
//   String@ description(void) {
//       u16@ vals = new u16[(u16)N];
//       vals[0] = (u16)<ivar0>;
//       …
//       vals[N-1] = (u16)<ivarN-1>;
//       return String._classDescribe("<ClassName>", vals, (u8)N);
//   }
//
// Only u16-castable ivars (integer scalars) contribute slots — class
// pointers, structs, arrays, and aggregates are skipped from the
// `vals` array (the ivar set isn't a stable contract anyway and a
// later runtime-reflection upgrade can format them properly). The
// surface is `<Name>(v1, v2, …)` with one decimal per included ivar.
// Returns nil when the class has no u16-castable ivars; the caller
// then leaves the class on Object's default `<Object>` placeholder.
- (nullable XTMethodDeclNode*)synthesizeDescriptionMethodFor:(XTClassDeclNode*)cls
                                                    location:(XTSourceLocation*)loc
    {
    XTType* u8t = [XTType u8Type];
    XTType* u16t = [XTType u16Type];

    // Filter ivars to those that can be widened to u16.
    NSMutableArray<XTVariableDeclNode*>* includedIvars = [NSMutableArray array];
    for (XTVariableDeclNode* ivar in cls.ivars)
        {
        if (!ivar.declaredType)
            continue;
        if (ivar.isStatic)
            continue; // class-level: no instance slot
        if (!ivar.declaredType.isInteger)
            continue; // skip ptrs / aggs / floats
        [includedIvars addObject:ivar];
        }
    if (includedIvars.count == 0)
        return nil;
    NSUInteger n = includedIvars.count;

    XTType* u8Ptr = [XTPointerType pointerToType:u8t];
    XTType* u16Ptr = [XTPointerType pointerToType:u16t];
    // String.xc may not have registered its marker in the type table
    // yet (the parser registers markers lazily and synthesis runs in
    // a one-pass position relative to that); fall back to building a
    // marker by hand if classesByName carries the declaration. The
    // marker is class-typed with the right display name — that's all
    // sema's downstream method-call lookup needs to resolve `String@`.
    XTType* strMarker = [self.typeTable typeForName:@"String"];
    if (!strMarker && self.classesByName[@"String"])
        {
        strMarker = [[XTType alloc] initWithKind:XTTypeKindClass
                                     displayName:@"String"];
        [self.typeTable registerType:strMarker forName:@"String"];
        }
    if (!strMarker)
        return nil; // String.xc not in scope
    XTType* strPtr = [XTPointerType pointerToType:strMarker];

    NSMutableArray<XTASTNode*>* stmts = [NSMutableArray array];

    // u16@ vals = new u16[(u16)N];
    XTLiteralIntNode* nLit = [[XTLiteralIntNode alloc] initWithValue:(int64_t)n location:loc];
    XTCastExprNode* nCast = [[XTCastExprNode alloc] initWithType:u16t operand:nLit location:loc];
    XTNewExprNode* newU16 = [[XTNewExprNode alloc] initWithClassName:@"u16"
                                                           arguments:@[]
                                                           countExpr:nCast
                                                            location:loc];
    XTVariableDeclNode* valsDecl =
        [[XTVariableDeclNode alloc] initWithName:@"vals"
                                            type:u16Ptr
                                     initialiser:newU16
                                        location:loc];
    [stmts addObject:valsDecl];

    // vals[i] = (u16)<ivar_i>;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTVariableDeclNode* ivar = includedIvars[i];
        XTIdentifierNode* valsRef =
            [[XTIdentifierNode alloc] initWithName:@"vals"
                                          location:loc];
        XTLiteralIntNode* idxLit =
            [[XTLiteralIntNode alloc] initWithValue:(int64_t)i
                                           location:loc];
        XTSubscriptExprNode* lhs =
            [[XTSubscriptExprNode alloc] initWithBase:valsRef
                                                index:idxLit
                                             location:loc];
        XTIdentifierNode* ivarRef =
            [[XTIdentifierNode alloc] initWithName:ivar.varName
                                          location:loc];
        XTCastExprNode* rhs =
            [[XTCastExprNode alloc] initWithType:u16t
                                         operand:ivarRef
                                        location:loc];
        XTAssignExprNode* assign =
            [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign
                                             lhs:lhs
                                             rhs:rhs
                                        location:loc];
        // Wrap the assign-expr as a statement — IR lowering's
        // dispatch table reads XTASTNodeKindExpressionStatement.
        XTExpressionStatementNode* stmt =
            [[XTExpressionStatementNode alloc] initWithExpression:assign
                                                         location:loc];
        [stmts addObject:stmt];
        }

    // Compute the per-ivar signedness bitmask. Caps at 8 ivars
    // because _classDescribe takes a u8 mask — extra signed ivars
    // (rare) display as unsigned aliases, which is the same UX cost
    // as them showing as `65531` and is cheap to lift later if any
    // class actually has 9+ signed ivars.
    uint64_t signedMask = 0;
    for (NSUInteger i = 0; i < n && i < 8; i++)
        {
        XTVariableDeclNode* ivar = includedIvars[i];
        if (ivar.declaredType.isSigned)
            signedMask |= ((uint64_t)1) << i;
        }

    // return String._classDescribe("<ClassName>", vals, (u8)N, (u8)mask);
    XTIdentifierNode* stringRef =
        [[XTIdentifierNode alloc] initWithName:@"String"
                                      location:loc];
    XTLiteralStringNode* nameLit =
        [[XTLiteralStringNode alloc] initWithString:cls.className
                                           location:loc];
    XTIdentifierNode* valsRef2 =
        [[XTIdentifierNode alloc] initWithName:@"vals"
                                      location:loc];
    XTLiteralIntNode* cntLit =
        [[XTLiteralIntNode alloc] initWithValue:(int64_t)n
                                       location:loc];
    XTCastExprNode* cntCast =
        [[XTCastExprNode alloc] initWithType:u8t
                                     operand:cntLit
                                    location:loc];
    XTLiteralIntNode* maskLit =
        [[XTLiteralIntNode alloc] initWithValue:(int64_t)signedMask
                                       location:loc];
    XTCastExprNode* maskCast =
        [[XTCastExprNode alloc] initWithType:u8t
                                     operand:maskLit
                                    location:loc];
    XTMethodCallExprNode* call =
        [[XTMethodCallExprNode alloc] initWithReceiver:stringRef
                                            methodName:@"_classDescribe"
                                             arguments:@[ nameLit, valsRef2, cntCast, maskCast ]
                                              location:loc];
    XTReturnNode* ret =
        [[XTReturnNode alloc] initWithValues:@[ call ]
                                    location:loc];
    [stmts addObject:ret];

    XTBlockNode* body =
        [[XTBlockNode alloc] initWithStatements:stmts
                                       location:loc];

    return [[XTMethodDeclNode alloc] initWithName:@"description"
                                      returnTypes:@[ strPtr ]
                                       parameters:@[]
                                         isStatic:NO
                                        isVarArgs:NO
                                             body:body
                                         location:loc];
    (void)u8Ptr;
    }

// Walk every class. Skip the Object root marker, String (whose
// description() is reserved for content), and any class that
// already provides a no-arg description() override. Append the
// synthesised method onto each remaining class so downstream
// mangling / vtable / lowering passes treat it like a user-written
// method.
- (void)synthesizeClassDescriptions
    {
    XTSourceLocation* loc =
        [XTSourceLocation locationWithFilename:@"<synth-description>"
                                          line:0
                                        column:0];
    for (XTClassDeclNode* cls in self.classesByName.allValues)
        {
        if ([cls.className isEqualToString:@"Object"])
            continue;
        if ([cls.className isEqualToString:@"String"])
            continue;
        BOOL hasOwn = NO;
        for (XTMethodDeclNode* m in cls.methods)
            {
            if ([m.methodName isEqualToString:@"description"] && m.parameters.count == 0)
                {
                hasOwn = YES;
                break;
                }
            }
        if (hasOwn)
            continue;
        XTMethodDeclNode* synth = [self synthesizeDescriptionMethodFor:cls
                                                              location:loc];
        if (synth)
            [cls appendSynthesisedMethod:synth];
        }
    }

@end
