#import "XTSemanticAnalyzer+Private.h"

@implementation XTSemanticAnalyzer

// --migrate base version, process-wide like the other driver-set knobs.
static NSString* sMigrateBase = nil;
+ (void)setMigrateBaseVersion:(NSString*)base
    {
    sMigrateBase = [base copy];
    }
// The resolved support tree (uxkit/025). Everything under it ships WITH this
// compiler, so it is by definition written against this compiler's version —
// `--migrate` must not hide the new surface from it.
static NSString* sMigrateSupportRoot = nil;
+ (void)setMigrateSupportRoot:(NSString*)root
    {
    sMigrateSupportRoot = root.length ? [root stringByStandardizingPath] : nil;
    }

// Is `path` inside the support tree? Both sides are standardized first: the
// support root arrives as `<bindir>/../lib/xc` and a node's filename carries
// whatever spelling the include search produced, so a literal prefix test on
// the raw strings compares two different spellings of the same directory.
static BOOL xtPathUnderSupportRoot(NSString* path)
    {
    if (!sMigrateSupportRoot.length || !path.length)
        return NO;
    NSString* p = [path stringByStandardizingPath];
    if (![p hasPrefix:sMigrateSupportRoot])
        return NO;
    // Prefix, but on a path BOUNDARY — `/opt/xcc/lib/xcfoo` is not in
    // `/opt/xcc/lib/xc`.
    if (p.length == sMigrateSupportRoot.length)
        return YES;
    return [p characterAtIndex:sMigrateSupportRoot.length] == '/';
    }

// Dotted-numeric version compare: 1 if a > b. "0.10" > "0.9", which is why
// versions are strings and not floats.
static int xtVersionGT(NSString* a, NSString* b)
    {
    NSArray* pa = [a componentsSeparatedByString:@"."];
    NSArray* pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++)
        {
        NSInteger va = i < pa.count ? [pa[i] integerValue] : 0;
        NSInteger vb = i < pb.count ? [pb[i] integerValue] : 0;
        if (va != vb)
            return va > vb ? 1 : 0;
        }
    return 0;
    }

// Is `m` visible to the CURRENT context under --migrate? Newer-than-base
// members are hidden from old code, but stay visible (a) inside their own
// class — a 0.4 method may call its 0.4 siblings — and (b) to any caller
// itself marked newer than base, so new library code composes.
- (BOOL)memberVisibleUnderMigrate:(XTMethodDeclNode*)m
                          ofClass:(XTClassDeclNode*)owner
    {
    if (!sMigrateBase || !m.sinceVersion.length)
        return YES;
    if (!xtVersionGT(m.sinceVersion, sMigrateBase))
        return YES;
    if (self.currentClassNode && owner && self.currentClassNode == owner)
        return YES;
        // uxkit/025: code from the SUPPORT TREE is this compiler's own, so it sees
        // the whole surface. The gate exists to make a 0.3 PROGRAM's calls to the
        // two silently-reused names fail loudly; applying it to the standard
        // library made any client of an already-migrated stdlib class (Url, and
        // whatever else moved) unable to use the flag at all — which is precisely
        // the program that needs it. The library is not being migrated; it already
        // was, in the release the flag names as the target.
        {
        XTASTNode* site = self.currentFunction ?: (XTASTNode*)self.currentClassNode;
        if (site && xtPathUnderSupportRoot(site.location.filename))
            return YES;
        }
    XTFunctionDeclNode* cf = self.currentFunction;
    if ([cf isKindOfClass:[XTMethodDeclNode class]])
        {
        NSString* cs = ((XTMethodDeclNode*)cf).sinceVersion;
        if (cs.length && xtVersionGT(cs, sMigrateBase))
            return YES;
        }
    return NO;
    }

- (NSDictionary*)protocolMethodSlotsForExport
    {
    return self.protocolMethodSlots;
    }

/****************************************************************************\
|* Initialise the semantic analyser with a type table and diagnostic engine.
|* @param typeTable    The global type registry for resolving type names.
|* @param diagnostics  The diagnostic engine for errors and warnings.
|* @return  A fully initialised analyser ready for -analyzeProgram:.
\****************************************************************************/
- (instancetype)initWithTypeTable:(XTTypeTable*)typeTable
                      diagnostics:(XTDiagnosticEngine*)diagnostics
    {
    self = [super init];
    if (self)
        {
        _typeTable = typeTable;
        _diagnostics = diagnostics;
        _globalScope = [[XTScope alloc] initWithParent:nil];
        _allocator = @"bump";
        _scopeStack = [NSMutableArray arrayWithObject:_globalScope];
        _registeredEnumNames = [NSMutableSet set];
        _classesByName = [NSMutableDictionary dictionary];
        _classesUsedWithTypeArgument = [NSMutableSet set];
        _protocolsByName = [NSMutableDictionary dictionary];
        _protocolMethodSlots = [NSMutableDictionary dictionary];
        _stackUsingFunctions = [NSMutableSet set];
        _locallyStackUsingFunctions = [NSMutableSet set];
        _regionCLocallyUsing = [NSMutableSet set];
        _regionCUsing = [NSMutableSet set];
        _cloakInferredSafe = [NSMutableDictionary dictionary];
        _stackUseReasons = [NSMutableDictionary dictionary];
        _labelDisplayNames = [NSMutableDictionary dictionary];
        _callEdges = [NSMutableDictionary dictionary];
        _cloakedDecls = [NSMutableArray array];
        _variadicLabels = [NSMutableSet set];
        _variadicDecls = [NSMutableArray array];
        _variadicFunctionsUsingVaList = [NSMutableSet set];
        _addressTakenFunctions = [NSMutableSet set];
        _externalFunctions = [NSMutableSet set];
        _recursiveFunctions = [NSMutableSet set];
        _overriddenMethodLabels = [NSMutableSet set];
        _classIdsByName = [NSMutableDictionary dictionary];
        _virtualSlotByLabel = [NSMutableDictionary dictionary];
        _chainSlotByLabel = [NSMutableDictionary dictionary];
        _chainHostByLabel = [NSMutableDictionary dictionary];
        _catNamesByHost = [NSMutableDictionary dictionary];
        _virtualImplByClassAndSlot = [NSMutableDictionary dictionary];
        _totalVirtualSlots = 0;
        _staticFrameEligible = [NSMutableDictionary dictionary];
        _maxCallDepth = [NSMutableDictionary dictionary];
        _indirectCallTargets = [NSMutableDictionary dictionary];
        _addressTakenCleanly = [NSMutableSet set];
        _usedClassNames = [NSMutableArray array];
        _cImportFunctionNames = [NSMutableSet set];
        }
    return self;
    }

/****************************************************************************\
|* Visit a `use ClassName;` directive. Records the class as part of the
|* bare-call lookup space; visitCallExpr falls back to the use-list
|* when ordinary free-function lookup misses. The class itself must
|* be declared (or imported) for the resolution to find it — sema
|* validates the receiver class at the call site, not here, so a
|* `use SomeClass;` for a never-imported class only errors out when
|* something actually tries to call into it.
\****************************************************************************/
- (void)visitUseDecl:(XTUseDeclNode*)node
    {
    if (node.className.length == 0)
        return;
    if (![_usedClassNames containsObject:node.className])
        {
        [(NSMutableArray*)_usedClassNames addObject:node.className];
        }
    }

/****************************************************************************\
|* If `node` is the AST shape `&funcName` (a unary address-of whose
|* operand is an identifier resolving to a function symbol), return
|* the function's call-graph label `_fn_<mangled>`. Returns nil for
|* any other shape — `&variable`, `&arr[i]`, `&structField`, a bare
|* pointer cast, etc.
\****************************************************************************/
- (nullable NSString*)addressTakenFunctionLabelFromNode:(XTASTNode*)node
    {
    if (![node isKindOfClass:[XTUnaryExprNode class]])
        return nil;
    XTUnaryExprNode* u = (XTUnaryExprNode*)node;
    if (u.op != XTUnaryOpAddrOf)
        return nil;
    if (![u.operand isKindOfClass:[XTIdentifierNode class]])
        return nil;
    NSString* ident = ((XTIdentifierNode*)u.operand).identName;
    XTSymbol* sym = [[self currentScope] lookupSymbol:ident];
    if (!sym || sym.storageClass != XTStorageClassFunction)
        return nil;
    NSString* key = sym.mangledName ?: ident;
    return [@"_fn_" stringByAppendingString:key];
    }

/****************************************************************************\
|* Record that function `target` may be invoked via an indirect call
|* from inside `fromFunction`. Both labels are in `_fn_<mangled>` /
|* `_cls_<Class>_<mangled>` form. Also marks `target` as cleanly-
|* tracked so Pass C can treat it as a normal (non-fallback)
|* eligibility candidate.
\****************************************************************************/
- (void)recordIndirectCallTarget:(NSString*)target
                 forFromFunction:(NSString*)fromFunction
    {
    if (!target || !fromFunction)
        return;
    NSMutableSet* targets = _indirectCallTargets[fromFunction];
    if (!targets)
        {
        targets = [NSMutableSet set];
        _indirectCallTargets[fromFunction] = targets;
        }
    [targets addObject:target];
    [_addressTakenCleanly addObject:target];
    }

/****************************************************************************\
|* Scan a call's argument list for `&funcName` shapes where the
|* callee's matching formal parameter is fn-pointer-typed. Record
|* the target as reachable from CALLEE's indirect-call target set —
|* this is the inter-procedural half of the CFA: qsort receives its
|* `cmp` candidates here, from every call site that passes
|* `&myCompare` as a fn-pointer argument. `calleeParams` is the
|* callee's XTParamNode array (or nil if unavailable, in which case
|* this is a no-op).
\****************************************************************************/
- (void)recordFnPointerArgs:(NSArray<XTASTNode*>*)args
                 paramTypes:(nullable NSArray<XTType*>*)paramTypes
                calleeLabel:(NSString*)calleeLabel
    {
    if (!paramTypes || !calleeLabel)
        return;
    NSUInteger n = MIN(args.count, paramTypes.count);
    for (NSUInteger i = 0; i < n; i++)
        {
        XTType* pt = paramTypes[i];
        if (![pt isKindOfClass:[XTPointerType class]])
            continue;
        if (![((XTPointerType*)pt).pointeeType isKindOfClass:[XTFunctionType class]])
            continue;
        NSString* target = [self addressTakenFunctionLabelFromNode:args[i]];
        if (target)
            {
            [self recordIndirectCallTarget:target forFromFunction:calleeLabel];
            }
        }
    [self checkPointerArgWidths:args paramTypes:paramTypes calleeLabel:calleeLabel];
    }

/****************************************************************************\
|* A pointer argument whose POINTEE WIDTH differs from the parameter's is a
|* refusal, not a conversion. `i32*` where `i64*` is declared lets the callee
|* write eight bytes into four; `i64*` where `i32*` is declared leaves the
|* caller's high half untouched, which is how a `delta < 0` guard in the
|* vectoriser came to be unfirable — the sign never reached it.
|*
|* Nothing diagnosed either direction before. Measured across the whole tree —
|* fixtures, support library and the self-hosted compiler — the check fires on
|* EIGHT call sites, all of them one source line, and that line was the bug
|* above. `u8*`-as-`string` never trips it: those are same-width or void*.
|*
|* Deliberately NOT refused: void* (the escape hatch), function pointers,
|* structs and classes (a different question — layout, not width), and
|* same-width differences, which are sign only. private:docs/bugs/244.
\****************************************************************************/
- (void)checkPointerArgWidths:(NSArray<XTASTNode*>*)args
                   paramTypes:(nullable NSArray<XTType*>*)paramTypes
                  calleeLabel:(NSString*)calleeLabel
    {
    if (!paramTypes)
        return;
    NSUInteger n = MIN(args.count, paramTypes.count);
    for (NSUInteger i = 0; i < n; i++)
        {
        XTType* pt = paramTypes[i];
        XTType* at = args[i].resolvedType;
        if (![pt isKindOfClass:[XTPointerType class]] || ![at isKindOfClass:[XTPointerType class]])
            continue;
        XTType* pp = ((XTPointerType*)pt).pointeeType;
        XTType* ap = ((XTPointerType*)at).pointeeType;
        if (!pp || !ap || pp.kind == XTTypeKindVoid || ap.kind == XTTypeKindVoid)
            continue;
        if ([pp isKindOfClass:[XTFunctionType class]] || [ap isKindOfClass:[XTFunctionType class]])
            continue;
        if (pp.kind == XTTypeKindStruct || ap.kind == XTTypeKindStruct
            || pp.kind == XTTypeKindClass || ap.kind == XTTypeKindClass)
            continue;
        if (pp.byteWidth == ap.byteWidth || pp.byteWidth == 0 || ap.byteWidth == 0)
            continue;
        [self.diagnostics emitError:[NSString stringWithFormat:
            @"argument %lu of '%@' is a %@* where a %@* is declared — the pointee "
            @"widths differ (%lu vs %lu), so the callee would read or write the "
            @"wrong number of bytes. Cast if that is really meant",
            (unsigned long)(i + 1),
            // The CFA label, not the source name — `_fn_foo` reads as noise in
            // a diagnostic the user has to act on.
            [calleeLabel hasPrefix:@"_fn_"] ? [calleeLabel substringFromIndex:4] : calleeLabel,
            ap.displayName, pp.displayName,
            (unsigned long)ap.byteWidth, (unsigned long)pp.byteWidth]
                                 at:args[i].location];
        }
    }

#pragma mark - Scope Management

/****************************************************************************\
|* Return the innermost (current) scope from the scope stack.
|* @return  The current XTScope.
\****************************************************************************/
- (XTScope*)currentScope
    {
    return _scopeStack.lastObject;
    }

/****************************************************************************\
|* Push a new child scope onto the scope stack, parented to the current scope.
\****************************************************************************/
- (void)pushScope
    {
    XTScope* child = [[XTScope alloc] initWithParent:[self currentScope]];
    [_scopeStack addObject:child];
    }

/****************************************************************************\
|* Pop the current scope off the stack. Never pops the global scope.
\****************************************************************************/
- (void)popScope
    {
    if (_scopeStack.count > 1)
        [_scopeStack removeLastObject];
    }

/****************************************************************************\
|* Define a symbol in the current scope (no location).
|* @param sym  The symbol to define.
\****************************************************************************/
- (void)defineSymbol:(XTSymbol*)sym
    {
    [self defineSymbol:sym at:nil];
    }

/****************************************************************************\
|* Define a symbol in the current scope at a given source location. Reports
|* a diagnostic error on redefinition with a note pointing to the prior site.
|* @param sym  The symbol to define.
|* @param loc  Source location of the definition (for diagnostics).
\****************************************************************************/
- (void)defineSymbol:(XTSymbol*)sym at:(nullable XTSourceLocation*)loc
    {
    sym.definedAt = loc;
    XTSymbol* existing = [[self currentScope] lookupLocalSymbol:sym.symbolName];
    if (existing)
        {
        [_diagnostics emitError:[NSString stringWithFormat:@"Redefinition of '%@'", sym.symbolName]
                             at:loc ?: [XTSourceLocation locationWithFilename:@"<sema>" line:0 column:0]];
        if (existing.definedAt)
            {
            [_diagnostics emitNote:[NSString stringWithFormat:@"Previous definition of '%@' was here", sym.symbolName]
                                at:existing.definedAt];
            }
        }
    else
        {
        [[self currentScope] defineSymbol:sym];
        }
    }

// Methods moved to XTSemanticAnalyzer+Analysis.m / .h
#pragma mark - XTASTVisitor

/****************************************************************************\
|* Visit a program node: analyse each top-level declaration in order.
|* @param node  The program root node.
\****************************************************************************/
- (void)visitProgram:(XTProgramNode*)node
    {
    for (XTASTNode* decl in node.declarations)
        [self analyzeNode:decl];
    }

/****************************************************************************\
|* Visit a function declaration: push scope, define parameters, analyse body,
|* run escape analysis, then pop scope.
|* @param node  The function declaration node.
\****************************************************************************/
- (void)visitFunctionDecl:(XTFunctionDeclNode*)node
    {
    _currentFunction = node;
    _currentReturnTypes = node.returnTypes;
    _currentFunctionThrows = [node isKindOfClass:[XTFunctionDeclNode class]]
                                 ? ((XTFunctionDeclNode*)node).throwsError
                                 : NO;
    self.fnForwardsVarargs = NO;
    self.fnPackingCallee = nil;
    self.fnPackingCallLoc = nil;
    NSString* prevLabel = _currentFunctionLabel;
    _currentFunctionLabel = [self labelForFunction:node];
    [self pushScope];
    // Define params in function scope
    for (XTParamNode* p in node.parameters)
        {
        // Params follow the local rule: banked weak keys allowed.
        [self validateWeakQualifierOnType:p.paramType
                                       at:p.location ?: node.location
                           allowBankedKey:YES];
        XTSymbol* sym = [[XTSymbol alloc] initWithName:p.paramName type:p.paramType];
        sym.storageClass = XTStorageClassStack;
        [self defineSymbol:sym];
        }
    // A C-ABI callee (a C import, or a bodyless variadic — the two forms
    // XTFnIsCABI recognises) cannot take a `callback`. A callback is a two-word
    // {recv, code} pair with no C representation — a bound method is not a C
    // function pointer — and marshalling both words shifts every following
    // argument into the wrong register, silently (bug 165d: the arg after a
    // non-last callback was corrupted). Use `pointer` for a C function pointer,
    // casting a widened free function to it where one is genuinely meant.
    if (node.isCImport || (node.isVarArgs && node.body == nil))
        {
        for (XTParamNode* cbp in node.parameters)
            {
            if (cbp.paramType && cbp.paramType.boundMethodSignature != nil)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"a C-ABI function cannot take a `callback` parameter ('%@') — "
                                                          @"a callback is a two-word pair with no C representation; use `pointer`",
                                                          cbp.paramName]
                                         at:cbp.location ?: node.location];
                }
            }
        }
    if (node.body)
        [self analyzeNode:node.body];
    if (node.body)
        [self runEscapeAnalysisOnBody:node.body];
    if (node.body)
        [self runGuardCheckOnBody:node.body];
    if (node.placement == XTPlacementCloaked)
        {
        [self checkCloakedDecl:node.funcName
                     isVarArgs:node.isVarArgs
                          body:node.body
                      location:node.location];
        [_cloakedDecls addObject:@{@"label" : _currentFunctionLabel,
                                   @"name" : node.funcName,
                                   @"location" : node.location}];
        }
    // A C-imported variadic (printf / snprintf / vprintf …) passes its args by
    // the native AAPCS/C ABI, NOT through the shared $04B0 pack buffer, so it
    // can't clobber an xtc va_list. Keep it OUT of the variadic-clobber sets so
    // an xtc variadic (Stdio.printf) may call libc snprintf for %f formatting.
    //
    // A BODYLESS variadic prototype (`i32 printf(u8* f, ...);` declared inline,
    // or a cross-unit forward decl) is likewise external: it has no body to run
    // va_start, so it never touches THIS unit's pack buffer, and its real
    // definition (a native, or another unit's) is guarded where it lives. Left
    // in the set, the ubiquitous `void log(fmt, ...) { …; printf(fmt, a, b); }`
    // was rejected as a buffer-clobber, though the va_list is fully consumed
    // into locals before printf and printf reads registers (bug 175). The
    // reentrance guard is inherently INTRA-unit; an extern endpoint can't be
    // one of its edges.
    if (node.isVarArgs && !node.isCImport && node.body)
        {
        [_variadicLabels addObject:_currentFunctionLabel];
        [_variadicDecls addObject:@{@"label" : _currentFunctionLabel,
                                    @"name" : node.funcName,
                                    @"location" : node.location}];
        }
    [self classifyFunctionStackUse:node label:_currentFunctionLabel];
    [self popScope];
    _currentFunctionLabel = prevLabel;
    _currentFunction = nil;
    _currentReturnTypes = nil;
    _currentFunctionThrows = NO;
    }

/****************************************************************************\
|* Visit a method declaration: push scope, define params, analyse body,
|* run escape analysis, then pop scope.
|* @param node  The method declaration node.
\****************************************************************************/
- (void)visitMethodDecl:(XTMethodDeclNode*)node
    {
    NSArray<XTType*>* prevRet = _currentReturnTypes;
    XTMethodDeclNode* prevMethod = _currentMethod;
    NSString* prevLabel = _currentFunctionLabel;
    _currentReturnTypes = node.returnTypes;
    _currentFunctionThrows = node.throwsError;
    self.fnForwardsVarargs = NO;
    self.fnPackingCallee = nil;
    self.fnPackingCallLoc = nil;
    _currentMethod = node;
    _currentFunctionLabel = [self labelForMethod:node];
    [self pushScope];
    for (XTParamNode* p in node.parameters)
        {
        // Params follow the local rule: banked weak keys allowed.
        [self validateWeakQualifierOnType:p.paramType
                                       at:p.location ?: node.location
                           allowBankedKey:YES];
        XTSymbol* sym = [[XTSymbol alloc] initWithName:p.paramName type:p.paramType];
        sym.storageClass = XTStorageClassStack;
        [self defineSymbol:sym];
        }
    if (node.body)
        [self analyzeNode:node.body];
    if (node.body)
        [self runEscapeAnalysisOnBody:node.body];
    if (node.body)
        [self runGuardCheckOnBody:node.body];
    if (node.placement == XTPlacementCloaked)
        {
        [self checkCloakedDecl:node.methodName
                     isVarArgs:node.isVarArgs
                          body:node.body
                      location:node.location];
        [_cloakedDecls addObject:@{@"label" : _currentFunctionLabel,
                                   @"name" : [NSString stringWithFormat:@"%@.%@",
                                                                        _currentClassNode.className ?: @"?",
                                                                        node.methodName],
                                   @"location" : node.location}];
        }
    if (node.isVarArgs)
        {
        [_variadicLabels addObject:_currentFunctionLabel];
        NSString* display = [NSString stringWithFormat:@"%@.%@",
                                                       _currentClassNode.className ?: @"?",
                                                       node.methodName];
        [_variadicDecls addObject:@{@"label" : _currentFunctionLabel,
                                    @"name" : display,
                                    @"location" : node.location}];
        }
    [self classifyMethodStackUse:node label:_currentFunctionLabel];
    [self popScope];
    _currentFunctionLabel = prevLabel;
    _currentReturnTypes = prevRet;
    _currentMethod = prevMethod;
    }

/****************************************************************************\
|* :cloaked decls run in the xe library bank with PORTB = $30. While that
|* bank is mapped, the xtc stack (which lives at $4000 on xe) is hidden —
|* any push/pop corrupts the library image. This check catches the obvious
|* violations from the body: new, delete, retain, release. Param count and
|* stack-spilled locals are enforced by the codegen which knows the ZP
|* budget. Varargs are *not* rejected here: `va_arg_*` lowers to direct
|* reads from XT_PRINTF_DATA_BUF (a fixed buffer in main RAM, always
|* visible regardless of PORTB), `va_start` is just a cursor init, and
|* `va_end` is a no-op — nothing in the variadic ABI touches the xtc
|* stack. A varargs function whose body is otherwise cloak-safe is fine
|* in the library bank.
|*
|* Target-compatibility (xt / xl can't host :cloaked) is enforced in the
|* codegen where the memory model is visible.
\****************************************************************************/
- (void)checkCloakedDecl:(NSString*)name
               isVarArgs:(BOOL)isVarArgs
                    body:(nullable XTASTNode*)body
                location:(XTSourceLocation*)loc
    {
    (void)isVarArgs;
    if (body)
        [self scanCloakedBody:body funcName:name];
    }

- (void)scanCloakedBody:(XTASTNode*)node funcName:(NSString*)name
    {
    if (!node)
        return;
    if ([node isKindOfClass:[XTNewExprNode class]])
        {
        [_diagnostics emitError:
                          [NSString stringWithFormat:
                                        @":cloaked '%@' cannot use 'new' (heap allocation needs "
                                        @"the xtc stack, hidden while PORTB = $30)",
                                        name]
                             at:node.location];
        return;
        }
    if ([node isKindOfClass:[XTDeleteNode class]])
        {
        XTDeleteNode* del = (XTDeleteNode*)node;
        NSString* op = (del.op == XTRefOpRetain)    ? @"retain"
                       : (del.op == XTRefOpRelease) ? @"release"
                                                    : @"delete";
        [_diagnostics emitError:
                          [NSString stringWithFormat:
                                        @":cloaked '%@' cannot use '%@' (refcount helpers push "
                                        @"to the xtc stack)",
                                        name, op]
                             at:node.location];
        return;
        }
    // Recurse into block/if/while/for/expression subtrees. We don't need
    // to model every node kind — just enumerate children.
    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            [self scanCloakedBody:s funcName:name];
            }
        return;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* ifn = (XTIfNode*)node;
        [self scanCloakedBody:ifn.condition funcName:name];
        [self scanCloakedBody:ifn.thenBlock funcName:name];
        if (ifn.elseBlock)
            [self scanCloakedBody:ifn.elseBlock funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self scanCloakedBody:w.condition funcName:name];
        [self scanCloakedBody:w.body funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self scanCloakedBody:f.loopInit funcName:name];
        [self scanCloakedBody:f.condition funcName:name];
        [self scanCloakedBody:f.increment funcName:name];
        [self scanCloakedBody:f.body funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)node;
        [self scanCloakedBody:f.collection funcName:name];
        [self scanCloakedBody:f.body funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self scanCloakedBody:((XTExpressionStatementNode*)node).expression
                     funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        XTReturnNode* r = (XTReturnNode*)node;
        for (XTASTNode* v in r.values)
            [self scanCloakedBody:v funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if (vd.initialiser)
            {
            [self scanCloakedBody:vd.initialiser funcName:name];
            }
        return;
        }
    if ([node isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        [self scanCloakedBody:b.left funcName:name];
        [self scanCloakedBody:b.right funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTUnaryExprNode class]])
        {
        [self scanCloakedBody:((XTUnaryExprNode*)node).operand funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)node;
        [self scanCloakedBody:a.lhs funcName:name];
        [self scanCloakedBody:a.rhs funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTCallExprNode class]])
        {
        XTCallExprNode* c = (XTCallExprNode*)node;
        for (XTASTNode* a in c.arguments)
            [self scanCloakedBody:a funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* c = (XTMethodCallExprNode*)node;
        [self scanCloakedBody:c.receiver funcName:name];
        for (XTASTNode* a in c.arguments)
            [self scanCloakedBody:a funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)node;
        [self scanCloakedBody:t.condition funcName:name];
        [self scanCloakedBody:t.thenExpr funcName:name];
        [self scanCloakedBody:t.elseExpr funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)node;
        [self scanCloakedBody:s.base funcName:name];
        [self scanCloakedBody:s.index funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTMemberAccessNode class]])
        {
        [self scanCloakedBody:((XTMemberAccessNode*)node).base funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTPostfixExprNode class]])
        {
        [self scanCloakedBody:((XTPostfixExprNode*)node).operand funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTCastExprNode class]])
        {
        [self scanCloakedBody:((XTCastExprNode*)node).operand funcName:name];
        return;
        }
    if ([node isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* s = (XTSwitchNode*)node;
        [self scanCloakedBody:s.subject funcName:name];
        for (XTSwitchCase* c in s.cases)
            {
            for (XTASTNode* st in c.body)
                {
                [self scanCloakedBody:st funcName:name];
                }
            }
        return;
        }
    if ([node isKindOfClass:[XTTupleAssignNode class]])
        {
        XTTupleAssignNode* t = (XTTupleAssignNode*)node;
        [self scanCloakedBody:t.sourceExpr funcName:name];
        return;
        }
    }

// Methods moved to XTSemanticAnalyzer+ZPSafety.m / .h
// Methods moved to XTSemanticAnalyzer+Overload.m / .h
#pragma mark - Escape analysis (Phase 3)

/****************************************************************************\
|* A lightweight post-type-check pass that walks a function/method body and
|* flags stack-class addresses that provably escape the enclosing scope, plus
|* `new` expressions inside loops. See doc/heap.md §Escape analysis.
\****************************************************************************/

- (void)runEscapeAnalysisOnBody:(XTASTNode*)body
    {
    _escStackClassDepth = [NSMutableDictionary dictionary];
    _escAliasOf = [NSMutableDictionary dictionary];
    _escBlockDepth = 0;
    [self escWalkStmt:body];
    _escStackClassDepth = nil;
    _escAliasOf = nil;
    }

/****************************************************************************\
|* Determine whether an expression is (or aliases) an address/pointer into a
|* tracked stack-allocated class local. Returns the origin variable name, or
|* nil if the expression carries no tracked stack-class origin. A bare field
|* read like `p.x` produces a scalar value, not an address, and is not an
|* escape — only `&p`, `&p.field`, or a pointer local previously tagged as
|* aliasing a stack instance count.
\****************************************************************************/
- (nullable NSString*)escOriginOfExpr:(nullable XTASTNode*)expr
    {
    if (!expr)
        return nil;
    if ([expr isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)expr;
        if (u.op == XTUnaryOpAddrOf)
            return [self escRootOfLvalue:u.operand];
        return nil;
        }
    if ([expr isKindOfClass:[XTIdentifierNode class]])
        {
        // A bare identifier only carries origin when it's a pointer alias we
        // previously tagged — a bare stack-class value is not an address.
        NSString* n = ((XTIdentifierNode*)expr).identName;
        return _escAliasOf[n];
        }
    if ([expr isKindOfClass:[XTCastExprNode class]])
        {
        return [self escOriginOfExpr:((XTCastExprNode*)expr).operand];
        }
    return nil;
    }

/****************************************************************************\
|* Walk an lvalue inside `&(...)` to find the root stack-class variable, if
|* any. `&c`, `&c.x`, `&c.x.y` all return `c`.
\****************************************************************************/
- (nullable NSString*)escRootOfLvalue:(nullable XTASTNode*)expr
    {
    if (!expr)
        return nil;
    if ([expr isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* n = ((XTIdentifierNode*)expr).identName;
        if (_escStackClassDepth[n])
            return n;
        return nil;
        }
    if ([expr isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)expr;
        if (!m.isArrow)
            return [self escRootOfLvalue:m.base];
        }
    return nil;
    }

/****************************************************************************\
|* Walk a statement subtree during escape analysis, tracking stack-class
|* declarations, aliases, block depth, and loop depth. Reports errors when
|* a stack-class address escapes via return.
|* @param node  The statement AST node to walk (nil is a no-op).
\****************************************************************************/
- (void)escWalkStmt:(nullable XTASTNode*)node
    {
    if (!node)
        return;

    if ([node isKindOfClass:[XTBlockNode class]])
        {
        _escBlockDepth++;
        NSInteger depth = _escBlockDepth;
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            [self escWalkStmt:s];
            }
        // Drop locals (and aliases targeting them) declared at this depth.
        NSArray* keys = [_escStackClassDepth.allKeys copy];
        for (NSString* k in keys)
            {
            if (_escStackClassDepth[k].integerValue == depth)
                {
                [_escStackClassDepth removeObjectForKey:k];
                }
            }
        NSArray* akeys = [_escAliasOf.allKeys copy];
        for (NSString* k in akeys)
            {
            NSString* orig = _escAliasOf[k];
            if (!_escStackClassDepth[orig])
                {
                [_escAliasOf removeObjectForKey:k];
                }
            }
        _escBlockDepth--;
        return;
        }

    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        XTVariableDeclNode* v = (XTVariableDeclNode*)node;
        if (v.initialiser)
            [self escWalkExpr:v.initialiser];
        XTType* t = v.declaredType;
        BOOL isStackClass = t && t.kind == XTTypeKindClass;
        BOOL isClassPtr = [t isKindOfClass:[XTPointerType class]] && ((XTPointerType*)t).pointeeType && ((XTPointerType*)t).pointeeType.kind == XTTypeKindClass;
        if (isStackClass)
            {
            _escStackClassDepth[v.varName] = @(_escBlockDepth);
            }
        else if (isClassPtr && v.initialiser)
            {
            NSString* origin = [self escOriginOfExpr:v.initialiser];
            if (origin)
                _escAliasOf[v.varName] = origin;
            }
        return;
        }

    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* n = (XTIfNode*)node;
        [self escWalkExpr:n.condition];
        [self escWalkStmt:n.thenBlock];
        [self escWalkStmt:n.elseBlock];
        return;
        }

    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* n = (XTForCStyleNode*)node;
        if (n.loopInit)
            [self escWalkStmt:n.loopInit];
        if (n.condition)
            [self escWalkExpr:n.condition];
        if (n.increment)
            [self escWalkExpr:n.increment];
        if (n.body)
            [self escWalkStmt:n.body];
        return;
        }

    if ([node isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* n = (XTForInNode*)node;
        [self escWalkExpr:n.collection];
        [self escWalkStmt:n.body];
        return;
        }

    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* n = (XTWhileNode*)node;
        [self escWalkExpr:n.condition];
        [self escWalkStmt:n.body];
        return;
        }

    if ([node isKindOfClass:[XTReturnNode class]])
        {
        XTReturnNode* r = (XTReturnNode*)node;
        for (XTASTNode* v in r.values)
            {
            [self escWalkExpr:v];
            NSString* origin = [self escOriginOfExpr:v];
            if (origin)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"cannot return address or value derived from stack-allocated instance '%@' — its storage dies when the enclosing block ends",
                                                      origin]
                                     at:r.location];
                }
            }
        return;
        }

    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self escWalkExpr:((XTExpressionStatementNode*)node).expression];
        return;
        }
    // break, continue, asm block, etc. — nothing to do.
    }

/****************************************************************************\
|* Walk an expression subtree during escape analysis. Detects assignments
|* of stack-class addresses to globals or heap fields, and warns about
|* `new` inside loops.
|* @param expr  The expression AST node to walk (nil is a no-op).
\****************************************************************************/
- (void)escWalkExpr:(nullable XTASTNode*)expr
    {
    if (!expr)
        return;

    if ([expr isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)expr;
        [self escWalkExpr:a.rhs];
        if (a.assignOp == XTAssignOpAssign)
            {
            NSString* origin = [self escOriginOfExpr:a.rhs];
            if (origin)
                {
                [self escClassifyAssignTarget:a.lhs origin:origin location:a.location];
                }
            }
        [self escWalkExpr:a.lhs];
        return;
        }

    if ([expr isKindOfClass:[XTNewExprNode class]])
        {
        // No "new in a loop will leak" warning here any more. It fired on
        // loop depth alone and its claim was FALSE in every shape it fired
        // on: under ARC a discarded `new` is released, a loop-local is
        // released each iteration, and a stored one is owned by whatever
        // stored it — measured, 10 made / 10 freed for each (private:docs/bugs/086).
        // Its advice ("declare a stack-allocated `T c;` instead") turned the
        // commonest correct use, building a collection, into a dangling
        // pointer. The shipped compiler never had the rule; now neither does
        // this one.
        XTNewExprNode* n = (XTNewExprNode*)expr;
        for (XTASTNode* arg in n.arguments)
            [self escWalkExpr:arg];
        return;
        }

    if ([expr isKindOfClass:[XTCallExprNode class]])
        {
        for (XTASTNode* arg in ((XTCallExprNode*)expr).arguments)
            [self escWalkExpr:arg];
        return;
        }
    if ([expr isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)expr;
        [self escWalkExpr:m.receiver];
        for (XTASTNode* arg in m.arguments)
            [self escWalkExpr:arg];
        return;
        }
    if ([expr isKindOfClass:[XTUnaryExprNode class]])
        {
        [self escWalkExpr:((XTUnaryExprNode*)expr).operand];
        return;
        }
    if ([expr isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)expr;
        [self escWalkExpr:b.left];
        [self escWalkExpr:b.right];
        return;
        }
    if ([expr isKindOfClass:[XTMemberAccessNode class]])
        {
        [self escWalkExpr:((XTMemberAccessNode*)expr).base];
        return;
        }
    if ([expr isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)expr;
        [self escWalkExpr:s.base];
        [self escWalkExpr:s.index];
        return;
        }
    if ([expr isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)expr;
        [self escWalkExpr:t.condition];
        [self escWalkExpr:t.thenExpr];
        [self escWalkExpr:t.elseExpr];
        return;
        }
    if ([expr isKindOfClass:[XTCastExprNode class]])
        {
        [self escWalkExpr:((XTCastExprNode*)expr).operand];
        return;
        }
    if ([expr isKindOfClass:[XTPostfixExprNode class]])
        {
        [self escWalkExpr:((XTPostfixExprNode*)expr).operand];
        return;
        }
    // identifiers, literals, sizeof — nothing to walk
    }

/****************************************************************************\
|* Classify the target of an assignment where the RHS carries a tracked
|* stack-class origin. Warns if the address escapes to a global, a heap-
|* reachable field, or an outer-scope stack instance.
|* @param lhs     The assignment target expression.
|* @param origin  The name of the stack-class variable whose address escapes.
|* @param loc     Source location for diagnostic messages.
\****************************************************************************/
- (void)escClassifyAssignTarget:(XTASTNode*)lhs
                         origin:(NSString*)origin
                       location:(XTSourceLocation*)loc
    {
    if ([lhs isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* n = ((XTIdentifierNode*)lhs).identName;
        // If we already know it's a local pointer / stack-class we're tracking,
        // record (or update) the alias; no diagnostic for same-function locals.
        if (_escStackClassDepth[n] || _escAliasOf[n])
            {
            _escAliasOf[n] = origin;
            return;
            }
        // Otherwise, see whether it resolves to a global — those outlive the
        // stack instance's scope and warrant a warning.
        XTSymbol* sym = [[self currentScope] lookupSymbol:n];
        if (sym && sym.storageClass == XTStorageClassHeap)
            {
            [_diagnostics emitWarning:[NSString stringWithFormat:
                                                    @"storing address of stack-allocated '%@' in global '%@' may outlive its storage",
                                                    origin, n]
                             category:XTWarnEscape
                                   at:loc];
            }
        return;
        }
    if ([lhs isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)lhs;
        if (m.isArrow)
            {
            // `heapInstance->field = &stack;` — heap lifetime is unbounded.
            [_diagnostics emitWarning:[NSString stringWithFormat:
                                                    @"storing address of stack-allocated '%@' in heap-reachable field '%@' may outlive its storage",
                                                    origin, m.memberName]
                             category:XTWarnEscape
                                   at:loc];
            return;
            }
        // `otherStack.field = &stack;` — check whether the target's enclosing
        // block is strictly outside the source's block.
        NSString* baseOrigin = [self escOriginOfExpr:m.base];
        if (baseOrigin && ![baseOrigin isEqualToString:origin])
            {
            NSNumber* baseDepth = _escStackClassDepth[baseOrigin];
            NSNumber* origDepth = _escStackClassDepth[origin];
            if (baseDepth && origDepth && baseDepth.integerValue < origDepth.integerValue)
                {
                [_diagnostics emitWarning:[NSString stringWithFormat:
                                                        @"storing address of inner stack-allocated '%@' into outer stack-instance field '%@.%@' — outer outlives inner",
                                                        origin, baseOrigin, m.memberName]
                                 category:XTWarnEscape
                                       at:loc];
                }
            }
        }
    }

@end
