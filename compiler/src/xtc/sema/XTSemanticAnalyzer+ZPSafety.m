/****************************************************************************\
|* XTSemanticAnalyzer+ZPSafety.m
\****************************************************************************/
#import "XTSemanticAnalyzer+Private.h"

@implementation XTSemanticAnalyzer (ZPSafety)

#pragma mark - Stage 4c: transitive ZP-safety analysis

/****************************************************************************\
|* Build the stable label the codegen uses for a free function's bank-page
|* tracking entry — `_fn_<mangled>` when overloaded, `_fn_<name>` otherwise.
|* Mirrors XTBankSwitchedCodeGenerator._cloakedTargets key format so Pass
|* C's error messages and Pass B's graph keys stay in lockstep with the
|* codegen's own view.
\****************************************************************************/
- (NSString*)labelForFunction:(XTFunctionDeclNode*)fn
    {
    NSString* key = fn.mangledName ?: fn.funcName;
    return [@"_fn_" stringByAppendingString:key ?: @""];
    }

/****************************************************************************\
|* Mirror of labelForFunction but for class methods — `_cls_<Class>_<mangled>`.
|* Uses the currently-walked class name (set by visitClassDecl) since
|* XTMethodDeclNode doesn't carry the class back-pointer.
\****************************************************************************/
- (NSString*)labelForMethod:(XTMethodDeclNode*)m
    {
    NSString* key = m.mangledName ?: m.methodName;
    NSString* cls = self.currentClassNode.className ?: @"?";
    return [NSString stringWithFormat:@"_cls_%@_%@", cls, key ?: @""];
    }

/****************************************************************************\
|* Non-emitting counterpart to scanCloakedBody: walks the same AST shapes
|* and returns a short human-readable reason string the first time it
|* sees a body construct that reaches for the xtc software stack either
|* directly (inline asm) or through a runtime helper (new / delete /
|* retain / release / large local). Returns nil when the body is clean.
|* Pass A calls this for every function or method — not just cloaked
|* ones — so the `self.stackUsingFunctions` seed set reflects every
|* potential stack user before the transitive BFS runs.
\****************************************************************************/
- (nullable NSString*)bodyStackSignalReason:(XTASTNode*)node
    {
    if (!node)
        return nil;
    if ([node isKindOfClass:[XTNewExprNode class]])
        {
        return @"allocates with 'new' (heap helper pushes to xtc stack)";
        }
    if ([node isKindOfClass:[XTDeleteNode class]])
        {
        XTDeleteNode* del = (XTDeleteNode*)node;
        NSString* op = (del.op == XTRefOpRetain)    ? @"retain"
                       : (del.op == XTRefOpRelease) ? @"release"
                                                    : @"delete";
        return [NSString stringWithFormat:
                             @"uses '%@' (refcount helper pushes to xtc stack)", op];
        }
    if ([node isKindOfClass:[XTAsmBlockNode class]])
        {
        if ([self asmBlockTouchesXtcStack:(XTAsmBlockNode*)node])
            {
            return @"inline asm references the xtc software-stack pointer";
            }
        return nil;
        }
    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            NSString* r = [self bodyStackSignalReason:s];
            if (r)
                return r;
            }
        return nil;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* ifn = (XTIfNode*)node;
        NSString* r = [self bodyStackSignalReason:ifn.condition];
        if (r)
            return r;
        r = [self bodyStackSignalReason:ifn.thenBlock];
        if (r)
            return r;
        if (ifn.elseBlock)
            return [self bodyStackSignalReason:ifn.elseBlock];
        return nil;
        }
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* w = (XTWhileNode*)node;
        NSString* r = [self bodyStackSignalReason:w.condition];
        return r ?: [self bodyStackSignalReason:w.body];
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        NSString* r = [self bodyStackSignalReason:f.loopInit];
        if (r)
            return r;
        r = [self bodyStackSignalReason:f.condition];
        if (r)
            return r;
        r = [self bodyStackSignalReason:f.increment];
        return r ?: [self bodyStackSignalReason:f.body];
        }
    if ([node isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)node;
        NSString* r = [self bodyStackSignalReason:f.collection];
        return r ?: [self bodyStackSignalReason:f.body];
        }
    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        return [self bodyStackSignalReason:((XTExpressionStatementNode*)node).expression];
        }
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            {
            NSString* r = [self bodyStackSignalReason:v];
            if (r)
                return r;
            }
        return nil;
        }
    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if (vd.declaredType && vd.declaredType.byteWidth > 16)
            {
            return [NSString stringWithFormat:
                                 @"declares local '%@' of %lu bytes (spills past the ZP budget)",
                                 vd.varName, (unsigned long)vd.declaredType.byteWidth];
            }
        if (vd.initialiser)
            return [self bodyStackSignalReason:vd.initialiser];
        return nil;
        }
    if ([node isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        NSString* r = [self bodyStackSignalReason:b.left];
        return r ?: [self bodyStackSignalReason:b.right];
        }
    if ([node isKindOfClass:[XTUnaryExprNode class]])
        {
        return [self bodyStackSignalReason:((XTUnaryExprNode*)node).operand];
        }
    if ([node isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)node;
        NSString* r = [self bodyStackSignalReason:a.lhs];
        return r ?: [self bodyStackSignalReason:a.rhs];
        }
    if ([node isKindOfClass:[XTCallExprNode class]])
        {
        for (XTASTNode* a in ((XTCallExprNode*)node).arguments)
            {
            NSString* r = [self bodyStackSignalReason:a];
            if (r)
                return r;
            }
        return nil;
        }
    if ([node isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* c = (XTMethodCallExprNode*)node;
        NSString* r = [self bodyStackSignalReason:c.receiver];
        if (r)
            return r;
        for (XTASTNode* a in c.arguments)
            {
            r = [self bodyStackSignalReason:a];
            if (r)
                return r;
            }
        return nil;
        }
    if ([node isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)node;
        NSString* r = [self bodyStackSignalReason:t.condition];
        if (r)
            return r;
        r = [self bodyStackSignalReason:t.thenExpr];
        return r ?: [self bodyStackSignalReason:t.elseExpr];
        }
    if ([node isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)node;
        NSString* r = [self bodyStackSignalReason:s.base];
        return r ?: [self bodyStackSignalReason:s.index];
        }
    if ([node isKindOfClass:[XTMemberAccessNode class]])
        {
        return [self bodyStackSignalReason:((XTMemberAccessNode*)node).base];
        }
    if ([node isKindOfClass:[XTPostfixExprNode class]])
        {
        return [self bodyStackSignalReason:((XTPostfixExprNode*)node).operand];
        }
    if ([node isKindOfClass:[XTCastExprNode class]])
        {
        return [self bodyStackSignalReason:((XTCastExprNode*)node).operand];
        }
    if ([node isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* s = (XTSwitchNode*)node;
        NSString* r = [self bodyStackSignalReason:s.subject];
        if (r)
            return r;
        for (XTSwitchCase* c in s.cases)
            {
            for (XTASTNode* st in c.body)
                {
                r = [self bodyStackSignalReason:st];
                if (r)
                    return r;
                }
            }
        return nil;
        }
    if ([node isKindOfClass:[XTTupleAssignNode class]])
        {
        return [self bodyStackSignalReason:((XTTupleAssignNode*)node).sourceExpr];
        }
    return nil;
    }

/****************************************************************************\
|* Scan an inline-asm block for direct references to the xtc software stack
|* (ZP pairs $82/$83 on xl+xe, $89/$8A on xt, or the XTC_SP macros the
|* preprocessor may rewrite to either). Any match → the enclosing function
|* is locally stack-using and cannot appear inside a :cloaked transitive
|* closure. The scanner also records call edges for JSRs that name a known
|* non-stackSafe runtime helper so Pass B's worklist picks them up.
\****************************************************************************/
- (BOOL)asmBlockTouchesXtcStack:(XTAsmBlockNode*)blk
    {
    if (!blk || blk.lines.count == 0)
        return NO;
    static NSArray<NSString*>* spTokens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      spTokens = @[ @"$82", @"$83", @"$89", @"$8A", @"$8a",
                    @"XTC_SP_LO", @"XTC_SP_HI", @"XTC_SP" ];
    });
    for (NSString* raw in blk.lines)
        {
        // Strip line-level `;` comments so a comment mentioning `$82`
        // doesn't fire a false positive. xta supports both `;` and `//`
        // comment markers in source but the inline-asm lexer only
        // passes through `;`-trimmed text to the assembler; be defensive.
        NSRange semi = [raw rangeOfString:@";"];
        NSString* line = (semi.location == NSNotFound)
                             ? raw
                             : [raw substringToIndex:semi.location];
        for (NSString* tok in spTokens)
            {
            if ([line rangeOfString:tok options:NSCaseInsensitiveSearch].location != NSNotFound)
                {
                return YES;
                }
            }
        }
    return NO;
    }

/****************************************************************************\
|* Parallel scanner for the xt extended-RAM track. Returns YES iff
|* any line of the inline-asm block references the $84 or $85 ZP byte
|* (the low / high halves of xt-extended's region-C selector pair).
|*
|* Comments stripped before matching, same as `asmBlockTouchesXtcStack:`.
|* Conservative: any textual occurrence outside a comment is a hit,
|* even if the surrounding instruction is a read (e.g. `LDA $84`). A
|* read touches the value but doesn't write it, so technically no
|* save/restore bracket is required — but xt's bank registers are
|* write-only-meaningful (the read returns garbage on real hardware),
|* so a read site is effectively a bug worth flagging anyway. PR2 will
|* refine this with packer-driven flagging that doesn't depend on
|* string matching.
\****************************************************************************/
- (BOOL)asmBlockTouchesExtendedRamRegs:(XTAsmBlockNode*)blk
    {
    if (!blk || blk.lines.count == 0)
        return NO;
    static NSArray<NSString*>* extTokens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      extTokens = @[ @"$84", @"$85" ];
    });
    for (NSString* raw in blk.lines)
        {
        NSRange semi = [raw rangeOfString:@";"];
        NSString* line = (semi.location == NSNotFound)
                             ? raw
                             : [raw substringToIndex:semi.location];
        for (NSString* tok in extTokens)
            {
            if ([line rangeOfString:tok options:NSCaseInsensitiveSearch].location != NSNotFound)
                {
                return YES;
                }
            }
        }
    return NO;
    }

/****************************************************************************\
|* Mirror of bodyStackSignalReason: for the extended-RAM track. Returns YES
|* iff any inline-asm block within `node`'s subtree references $84/$85.
|* Used by classifyFunctionStackUse: / classifyMethodStackUse: to seed
|* the regionCLocallyUsing set. Doesn't return a reason string —
|* the consumer doesn't need one yet (no chain emitter for region C).
\****************************************************************************/
- (BOOL)bodyTouchesExtendedRamRegs:(XTASTNode*)node
    {
    if (!node)
        return NO;
    if ([node isKindOfClass:[XTAsmBlockNode class]])
        {
        return [self asmBlockTouchesExtendedRamRegs:(XTAsmBlockNode*)node];
        }
    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            if ([self bodyTouchesExtendedRamRegs:s])
                return YES;
            }
        return NO;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* ifn = (XTIfNode*)node;
        if ([self bodyTouchesExtendedRamRegs:ifn.condition])
            return YES;
        if ([self bodyTouchesExtendedRamRegs:ifn.thenBlock])
            return YES;
        if (ifn.elseBlock && [self bodyTouchesExtendedRamRegs:ifn.elseBlock])
            return YES;
        return NO;
        }
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* w = (XTWhileNode*)node;
        return [self bodyTouchesExtendedRamRegs:w.condition] || [self bodyTouchesExtendedRamRegs:w.body];
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        return [self bodyTouchesExtendedRamRegs:f.loopInit] || [self bodyTouchesExtendedRamRegs:f.condition] || [self bodyTouchesExtendedRamRegs:f.increment] || [self bodyTouchesExtendedRamRegs:f.body];
        }
    if ([node isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)node;
        return [self bodyTouchesExtendedRamRegs:f.collection] || [self bodyTouchesExtendedRamRegs:f.body];
        }
    if ([node isKindOfClass:[XTExpressionStatementNode class]])
        {
        return [self bodyTouchesExtendedRamRegs:
                         ((XTExpressionStatementNode*)node).expression];
        }
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            {
            if ([self bodyTouchesExtendedRamRegs:v])
                return YES;
            }
        return NO;
        }
    if ([node isKindOfClass:[XTVariableDeclNode class]])
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if (vd.initialiser)
            return [self bodyTouchesExtendedRamRegs:vd.initialiser];
        return NO;
        }
    if ([node isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* sw = (XTSwitchNode*)node;
        if ([self bodyTouchesExtendedRamRegs:sw.subject])
            return YES;
        for (XTSwitchCase* c in sw.cases)
            {
            for (XTASTNode* s in c.body)
                {
                if ([self bodyTouchesExtendedRamRegs:s])
                    return YES;
                }
            }
        return NO;
        }
    return NO;
    }

/****************************************************************************\
|* Record a resolved call edge from the currently-walked function body to
|* `calleeLabel`. No-op if we're at file scope (no enclosing function) —
|* top-level initialisers for globals aren't the cloaked-analysis target.
\****************************************************************************/
- (void)recordCallEdgeToLabel:(NSString*)calleeLabel
    {
    if (!self.currentFunctionLabel || !calleeLabel)
        return;
    NSMutableSet* edges = self.callEdges[self.currentFunctionLabel];
    if (!edges)
        {
        edges = [NSMutableSet set];
        self.callEdges[self.currentFunctionLabel] = edges;
        }
    [edges addObject:calleeLabel];
    }

/****************************************************************************\
|* Pass A local classification for free functions. Signals:
|*   • body scan: new / delete / retain / release / large locals /
|*     inline asm referencing $82/$83/$89/$8A/SP
|*   • struct return > 4 bytes (retbuf pointer lands on the xtc stack)
|* If any fires, `label` joins `self.stackUsingFunctions` and is later treated
|* as a BFS seed in Pass B. Varargs is *not* a signal — `va_arg_*` lowers
|* to direct reads from XT_PRINTF_DATA_BUF (always-visible main RAM), so
|* the variadic ABI itself never pushes/pops the xtc stack.
\****************************************************************************/
- (void)classifyFunctionStackUse:(XTFunctionDeclNode*)fn
                           label:(NSString*)label
    {
    if (!label)
        return;
    self.labelDisplayNames[label] = fn.funcName ?: label;
    NSString* reason = nil;
    for (XTType* rt in fn.returnTypes)
        {
        if (rt.kind == XTTypeKindStruct && rt.byteWidth > 4)
            {
            reason = [NSString stringWithFormat:
                                   @"returns a %lu-byte struct by value (retbuf pointer pushed to xtc stack)",
                                   (unsigned long)rt.byteWidth];
            break;
            }
        }
    if (!reason && fn.body)
        reason = [self bodyStackSignalReason:fn.body];
    if (reason)
        {
        [self.stackUsingFunctions addObject:label];
        self.stackUseReasons[label] = reason;
        }
    // Parallel pass A for the xt extended-RAM track. Today's only signal
    // is inline-asm referencing $84/$85; PR2 adds packer-driven flagging
    // when a banked allocation lands in region C.
    if (fn.body && [self bodyTouchesExtendedRamRegs:fn.body])
        {
        [self->_regionCLocallyUsing addObject:label];
        }
    }

/****************************************************************************\
|* Mirror of classifyFunctionStackUse for class methods. Same signals. Does
|* NOT unconditionally flag methods — the stage-4 codegen re-routes the
|* emitXtcStackPushA / PopA pair through PHA / PLA on the hw stack when
|* :cloaked is active, so a cloaked method's own body doesn't push xtc
|* stack for frame save / param pop. Only body-level signals matter.
\****************************************************************************/
- (void)classifyMethodStackUse:(XTMethodDeclNode*)m
                         label:(NSString*)label
    {
    if (!label)
        return;
    NSString* cls = self.currentClassNode.className ?: @"?";
    self.labelDisplayNames[label] = [NSString stringWithFormat:@"%@.%@",
                                                               cls, m.methodName ?: @"?"];
    NSString* reason = nil;
    for (XTType* rt in m.returnTypes)
        {
        if (rt.kind == XTTypeKindStruct && rt.byteWidth > 4)
            {
            reason = [NSString stringWithFormat:
                                   @"returns a %lu-byte struct by value (retbuf pointer pushed to xtc stack)",
                                   (unsigned long)rt.byteWidth];
            break;
            }
        }
    if (!reason && m.body)
        reason = [self bodyStackSignalReason:m.body];
    if (reason)
        {
        [self.stackUsingFunctions addObject:label];
        self.stackUseReasons[label] = reason;
        }
    // Parallel pass A for the xt extended-RAM track.
    if (m.body && [self bodyTouchesExtendedRamRegs:m.body])
        {
        [self->_regionCLocallyUsing addObject:label];
        }
    }

/****************************************************************************\
|* Visit a class declaration: push a class-level scope, register ivars as
|* symbols, analyse each method, then pop scope.
|* @param node  The class declaration node.
\****************************************************************************/
- (void)visitClassDecl:(XTClassDeclNode*)node
    {
    // A category / extension node is SPENT: the collection pass moved its
    // methods and ivars onto the class itself, and that node gets visited with
    // the merged set. Walking the part as well would analyse those methods a
    // second time against a scope holding only the part's own ivars — which is
    // how `class Shape () { u16 withExtra() { return w + extra; } }` reported
    // `w` undefined even though the merge had already succeeded.
    if (node.isCategory)
        return;
    self.currentClassNode = node;

    // Register ivars in a class-level scope so methods can see them.
    // PR2: inherited ivars are visible too — walk the parent chain
    // ROOT-first and define each ancestor's ivars before the leaf's
    // own set, matching the physical instance layout (doc/
    // inheritance.md §4). A leaf ivar shadowing an inherited name
    // would overwrite the parent entry; sema diagnoses that in
    // `resolveClassHierarchy` so the scope here sees a clean set.
    [self pushScope];
    NSMutableArray<XTClassDeclNode*>* chain = [NSMutableArray array];
    for (XTClassDeclNode* c = node.parentClass; c != nil; c = c.parentClass)
        {
        [chain insertObject:c atIndex:0];
        }
    for (XTClassDeclNode* ancestor in chain)
        {
        for (XTVariableDeclNode* ivar in ancestor.ivars)
            {
            XTType* t = ivar.declaredType ?: [XTType u8Type];
            XTSymbol* sym = [[XTSymbol alloc] initWithName:ivar.varName type:t];
            sym.storageClass = XTStorageClassHeap;
            [self defineSymbol:sym];
            }
        }
    for (XTVariableDeclNode* ivar in node.ivars)
        {
        XTType* t = ivar.declaredType ?: [XTType u8Type];
        // Ivars: banked weak keys accepted on a banked-heap target
        // (heapBank != 0) — a `weak:banked:T@` ivar is a real 3-byte
        // slot inside a class payload, pointee carrying a per-instance
        // bank. On a FLAT target (heapBank == 0, e.g. arm64) there is no
        // banking, so `banked:` is a no-op qualifier and `weak:banked:T@`
        // is simply `weak:T@` — the slot lives in flat RAM, reachable
        // without any bank switch, so accept it too rather than reject.
        //
        // Multi-bank banked-heap (rambo*) takes the same accept path, but
        // _weak_zero_all_for can't yet bank-switch for cross-bank slot
        // writes (see "Outstanding bugs" in doc/Issues) — a deferred
        // runtime item, not a sema rejection.
        BOOL allowBanked = YES;
        [self validateWeakQualifierOnType:t
                                       at:ivar.location ?: node.location
                           allowBankedKey:allowBanked];
        XTSymbol* sym = [[XTSymbol alloc] initWithName:ivar.varName type:t];
        sym.storageClass = XTStorageClassHeap;
        [self defineSymbol:sym];
        }
    for (XTMethodDeclNode* m in node.methods)
        [self analyzeNode:m];
    [self popScope];
    self.currentClassNode = nil;
    }

/****************************************************************************\
|* Validate a `weak:T@`-qualified type. The weak qualifier is parsed
|* into XTPointerType.isWeak but is only meaningful for class-pointer
|* slots whose lifecycle the ARC runtime tracks.
|*
|*   - Only class pointers may be weak. Scalar pointees (u8@, i16@)
|*     and function pointers are rejected — the ARC side table keys on
|*     heap-block addresses, and non-class pointers don't own heap
|*     blocks with refcount headers.
|*   - Banked placements are accepted for locals/globals/params
|*     (3-byte side-table key) but rejected for class ivars
|*     (`allowBankedKey=NO`). Banked weak ivars put the weak slot
|*     inside a class payload that lives in the bank window; the
|*     _weak_zero_all_for path currently writes through slot
|*     addresses without bank-switching, which works for ZP/main-RAM
|*     slots but not for bank-window slots. That lifts in a follow-up.
|*
|* Combined `weak:main:` / `weak:shadow:` prefixes are tolerated: the
|* resulting pointer is still 2 bytes and the emit path is identical
|* to bare `weak:T@`, so rejecting them buys no safety while breaking
|* user code that just wants to be explicit.
|* @param t               The declared type to inspect.
|* @param loc             Source location for diagnostics.
|* @param allowBankedKey  YES at local/global/param sites — the weak
|*                        variable's slot lives in ZP or main RAM and
|*                        is reachable without a bank switch. NO at
|*                        class-ivar sites, where the slot lives in
|*                        bank-window memory on banked-heap targets.
\****************************************************************************/
- (void)validateWeakQualifierOnType:(nullable XTType*)t
                                 at:(XTSourceLocation*)loc
                     allowBankedKey:(BOOL)allowBankedKey
    {
    // Arrays of weak pointers — `weak:T@ arr[N]` — wrap an
    // XTPointerType(isWeak=YES) inside an XTArrayType. Count the
    // array's element count toward the weak-table capacity, then
    // unwrap one level so the class-pointer / banked-key checks
    // still fire on the element type. Weak pointers aren't
    // allowed as nested pointees, so a single unwrap is
    // sufficient.
    NSUInteger arrayCount = 1;
    if ([t isKindOfClass:[XTArrayType class]])
        {
        XTArrayType* at = (XTArrayType*)t;
        // elementCount == 0 means an unsized `weak:T@ arr[]` —
        // treat as 1 for accounting purposes (pessimistic
        // otherwise can't be bounded).
        arrayCount = at.elementCount ? at.elementCount : 1;
        t = at.elementType;
        }
    if (![t isKindOfClass:[XTPointerType class]])
        return;
    XTPointerType* pt = (XTPointerType*)t;
    if (!pt.isWeak)
        return;
    if (pt.pointeeType.kind != XTTypeKindClass)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"`weak:` requires a class pointer, not `%@`",
                                            pt.displayName]
                                 at:loc];
        return;
        }
    if (!allowBankedKey && pt.placement == XTPointerPlacementBanked)
        {
        [self.diagnostics emitError:
                              @"`weak:` on banked:T@ is not yet supported in this position "
                              @"(class ivars on banked-heap targets); use a flat target or "
                              @"drop the `weak:` qualifier"
                                 at:loc];
        return;
        }
    (void)arrayCount; // no capacity to count against: the weak list is intrusive
    }

/****************************************************************************\
|* Back-compat wrapper — the original two-arg form defaulted to the
|* strictest mode (banked-key rejected). Kept so pre-PR-5 call sites
|* that haven't been audited for banked-key suitability don't silently
|* start accepting banked weak.
\****************************************************************************/
- (void)validateWeakQualifierOnType:(nullable XTType*)t
                                 at:(XTSourceLocation*)loc
    {
    [self validateWeakQualifierOnType:t at:loc allowBankedKey:NO];
    }

/****************************************************************************\
|* Visit a variable declaration: analyse the initialiser, perform auto type
|* inference, and define the symbol in the current scope.
|* @param node  The variable declaration node.
\****************************************************************************/
- (void)visitVariableDecl:(XTVariableDeclNode*)node
    {
    // Locals + globals: banked weak keys accepted (3-byte side-table
    // entry + per-entry bank byte). The weak variable's slot lives
    // in ZP or main RAM, reachable without a bank switch.
    [self validateWeakQualifierOnType:node.declaredType
                                   at:node.location
                       allowBankedKey:YES];
    if (node.initialiser)
        {
        XTType* prev = self.expectedType;
        // For `auto` vars we have no declared type yet; leave the
        // expected hint as-is (inherited from outside) so the
        // initialiser's overload resolver can still see a useful
        // type. For explicit declared types, set the hint so e.g.
        // `double x = Math.PI();` picks the dp overload.
        if (node.declaredType && !node.declaredType.isAuto)
            {
            self.expectedType = node.declaredType;
            }
        // `u8 buf[10] = 0..9;` is the ONE position where a range survives the
        // parser (the `for … in` form is desugared where it is parsed), so it
        // is also the only position where visitRangeExpr should stay quiet.
        // Anywhere else a range is not a value and has nothing to lower to —
        // see private:docs/bugs/048.
        BOOL prevRangeOK = self.rangeInInitialiserPosition;
        self.rangeInInitialiserPosition =
            [node.declaredType isKindOfClass:[XTArrayType class]];
        [self analyzeNode:node.initialiser];
        self.rangeInInitialiserPosition = prevRangeOK;
        self.expectedType = prev;

        // Stage-2 CFA: `<fnptr> fp = &funcName;` in a local decl.
        // Mirror of visitAssignExpr's record.
        NSString* target = [self addressTakenFunctionLabelFromNode:node.initialiser];
        if (target && self.currentFunctionLabel)
            {
            XTType* dt = node.declaredType;
            if ([dt isKindOfClass:[XTPointerType class]] &&
                [((XTPointerType*)dt).pointeeType isKindOfClass:[XTFunctionType class]])
                {
                [self recordIndirectCallTarget:target
                               forFromFunction:self.currentFunctionLabel];
                }
            }

        // Unboxing: `i32 v = arr.get(0);` — primitive LHS, class-
        // pointer RHS expected to carry a Number at runtime. Splice
        // `((Number@)arr.get(0)).asI32()` in front of the type-
        // compatibility check so the rewritten initialiser reports
        // a primitive resolved type and the class-pointer-assign
        // diagnostic doesn't fire on a path the user clearly meant
        // to be a value extraction.
        if (node.declaredType && !node.declaredType.isAuto &&
            [self canUnboxRhsType:node.initialiser.resolvedType
                        toLhsType:node.declaredType])
            {
            XTASTNode* unboxed = [self unboxRhs:node.initialiser
                                      toLhsType:node.declaredType];
            if (unboxed)
                node.initialiser = unboxed;
            }

        // PR4: class-pointer initialiser compatibility. Same rule as
        // visitAssignExpr — reject unrelated class pointers; allow
        // exact match and upcast-to-ancestor.
        if (node.declaredType && !node.declaredType.isAuto)
            {
            [self checkClassPointerAssign:node.declaredType
                                  rhsType:node.initialiser.resolvedType
                                  rhsNode:node.initialiser
                                     site:@"initialiser"
                                 location:node.location];
            }
        }

    // Auto type inference
    if (!node.declaredType || node.declaredType.isAuto)
        {
        if (node.initialiser && node.initialiser.resolvedType)
            {
            node.declaredType = node.initialiser.resolvedType;
            }
        else if (node.initialiser)
            {
            node.declaredType = [self inferTypeFromLiteral:node.initialiser];
            }
        }

    // Infer a sizeless array's length from its initialiser list:
    // `u8 a[] = {10,20,30}` parses to an XTArrayType with elementCount 0
    // and an XTBlockNode initialiser. Without this the count stays 0, so
    // byteWidth is 0 (no storage) and `for x in a` reads length 0 and
    // never iterates. Each sizeless decl gets its own XTArrayType
    // instance (arrayOfType: doesn't intern), so in-place update is safe.
    if ([node.declaredType isKindOfClass:[XTArrayType class]])
        {
        XTArrayType* at = (XTArrayType*)node.declaredType;
        if (at.elementCount == 0 && [node.initialiser isKindOfClass:[XTBlockNode class]])
            {
            NSUInteger n = ((XTBlockNode*)node.initialiser).statements.count;
            if (n > 0)
                at.elementCount = n;
            }
        }

    XTType* finalType = node.declaredType ?: [XTType u8Type];
    // A global with an explicit (non-auto) type was already registered
    // during the forward-reference pre-pass in analyzeProgram. Don't
    // re-define it — that would produce a spurious "Redefinition"
    // error. Auto globals fall through to the normal defineSymbol path.
    if (node.isGlobal && [self.globalScope lookupLocalSymbol:node.varName] && node.declaredType && !node.declaredType.isAuto)
        {
        node.resolvedType = finalType;
        return;
        }
    XTSymbol* sym = [[XTSymbol alloc] initWithName:node.varName type:finalType];
    sym.storageClass = node.isGlobal ? XTStorageClassHeap : XTStorageClassStack;
    [self defineSymbol:sym at:node.location];

    node.resolvedType = finalType;
    }

/****************************************************************************\
|* Infer a type from a literal AST node. Returns the narrowest type that fits
|* the literal value: u8/u16/u32 for integers, float for floats, u8@ for
|* strings, bool for bools, u8 for chars.
|* @param node  The literal AST node to infer from.
|* @return  The inferred XTType; defaults to u8 for unknown nodes.
\****************************************************************************/
- (XTType*)inferTypeFromLiteral:(XTASTNode*)node
    {
    if ([node isKindOfClass:[XTLiteralIntNode class]])
        {
        int64_t v = ((XTLiteralIntNode*)node).intValue;
        if (v >= 0)
            {
            if (v <= 255)
                return [XTType u8Type];
            if (v <= 65535)
                return [XTType u16Type];
            return [XTType u32Type];
            }
        else
            {
            if (v >= -128)
                return [XTType i8Type];
            if (v >= -32768)
                return [XTType i16Type];
            return [XTType i32Type];
            }
        }
    if ([node isKindOfClass:[XTLiteralFloatNode class]])
        {
        XTLiteralFloatNode* lit = (XTLiteralFloatNode*)node;
        return lit.floatData.length == 8 ? [XTType doubleType] : [XTType floatType];
        }
    if ([node isKindOfClass:[XTLiteralStringNode class]])
        return [XTPointerType pointerToType:[XTType u8Type]];
    if ([node isKindOfClass:[XTLiteralBoolNode class]])
        return [XTType boolType];
    if ([node isKindOfClass:[XTLiteralCharNode class]])
        return [XTType u8Type];
    return [XTType u8Type];
    }

/****************************************************************************\
|* Visit a struct declaration: resolve field types but do not register
|* fields as variables in the enclosing scope.
|* @param node  The struct declaration node.
\****************************************************************************/
- (void)visitStructDecl:(XTStructDeclNode*)node
    {
    // Struct fields define the type layout — don't register them as variables
    // in the enclosing scope. Just resolve their types.
    for (XTVariableDeclNode* f in node.fields)
        {
        if (f.declaredType && f.declaredType.isAuto && f.initialiser)
            {
            f.declaredType = f.initialiser.resolvedType ?: [XTType u8Type];
            }
        }
    }

/****************************************************************************\
|* Visit a typedef declaration: analyse any embedded struct declaration.
|* @param node  The typedef node.
\****************************************************************************/
- (void)visitTypedefDecl:(XTTypedefNode*)node
    {
    if (node.structDecl)
        [self analyzeNode:node.structDecl];
    }

/****************************************************************************\
|* Visit an enum declaration. Members were pre-registered in the global scope
|* during the forward-reference pre-pass; nothing to do on the body walk.
|* @param node  The enum declaration node.
\****************************************************************************/
- (void)visitEnumDecl:(XTEnumDeclNode*)node
    {
    // The pre-pass over program.declarations already registered this
    // enum's members in the global scope so forward references work,
    // so there's nothing to do on the body-analysis walk. Duplicate-
    // name detection happens during that pre-pass.
    (void)node;
    }

/****************************************************************************\
|* Visit a block: push/pop a scope around the statements unless it is a
|* synthetic declaration-list block (e.g. `u8 a, b;`).
|* @param node  The block node.
\****************************************************************************/
- (void)visitBlock:(XTBlockNode*)node
    {
    // Don't push scope for synthetic declaration-list blocks (e.g. "Block a, b;")
    if (!node.isDeclList)
        [self pushScope];
    for (XTASTNode* stmt in node.statements)
        [self analyzeNode:stmt];
    if (!node.isDeclList)
        [self popScope];
    }

/****************************************************************************\
|* Visit an if node: analyse condition, then-block, and optional else-block.
|* @param node  The if statement node.
\****************************************************************************/
- (void)visitIf:(XTIfNode*)node
    {
    [self analyzeNode:node.condition];
    [self analyzeNode:node.thenBlock];
    if (node.elseBlock)
        [self analyzeNode:node.elseBlock];
    }

/****************************************************************************\
|* Visit a defer node: analyse the body in the CURRENT scope.
|*
|* The body is lowered inline at each exit of this scope, so it is analysed
|* here, where it was written — it reads the enclosing scope's locals, and
|* visitBlock will push its own scope for the braces as usual.
|*
|* Without this the body was never analysed at all: XTDeferNode.acceptVisitor
|* dispatches visitDefer:, and with no implementation the whole subtree was
|* skipped, so lowering met an un-annotated call and reported "method call on
|* non-class receiver".
|* @param node  The defer statement node.
\****************************************************************************/
- (void)visitDefer:(XTDeferNode*)node
    {
    if (!node.body)
        return;
    [self deferBodyRejectEscapes:node.body loopDepth:0];
    [self analyzeNode:node.body];
    }

/****************************************************************************\
|* Reject control flow that would leave a `defer` body.
|*
|* The body is emitted inline at EVERY exit of its scope, so a `return` in it
|* has no single meaning (which exit? and what of the return value already
|* computed?), and a `break`/`continue` that escapes the body would retarget a
|* loop the body is not in. Both are rejected rather than defined.
|*
|* `break`/`continue` INSIDE a loop or switch written within the body are fine —
|* they target that construct — so a depth counter tracks whether we are still
|* able to escape.
|* @param node       Subtree to check.
|* @param loopDepth  Enclosing loops/switches seen so far within the body.
\****************************************************************************/
- (void)deferBodyRejectEscapes:(XTASTNode*)node loopDepth:(NSInteger)loopDepth
    {
    if (!node)
        return;
    if ([node isKindOfClass:[XTReturnNode class]])
        {
        [self.diagnostics emitError:@"'return' is not allowed inside a 'defer' body — "
                                    @"the body runs at every exit of its scope, so there "
                                    @"is no single return for it to perform"
                                 at:node.location];
        return;
        }
    if (loopDepth == 0 && [node isKindOfClass:[XTBreakNode class]])
        {
        [self.diagnostics emitError:@"'break' cannot leave a 'defer' body"
                                 at:node.location];
        return;
        }
    if (loopDepth == 0 && [node isKindOfClass:[XTContinueNode class]])
        {
        [self.diagnostics emitError:@"'continue' cannot leave a 'defer' body"
                                 at:node.location];
        return;
        }
    // A nested defer is checked on its own visit; do not descend twice.
    if ([node isKindOfClass:[XTDeferNode class]])
        return;

    // Only STATEMENT-bearing nodes can hide an escape, so walk those. There is
    // no generic child accessor on XTASTNode; expressions cannot contain
    // return/break/continue, so they need no visit.
    if ([node isKindOfClass:[XTBlockNode class]])
        {
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            [self deferBodyRejectEscapes:st loopDepth:loopDepth];
        return;
        }
    if ([node isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* n = (XTIfNode*)node;
        [self deferBodyRejectEscapes:n.thenBlock loopDepth:loopDepth];
        [self deferBodyRejectEscapes:n.elseBlock loopDepth:loopDepth];
        return;
        }
    // Inside a loop/switch written in the body, break/continue target THAT
    // construct and are legal; only `return` stays banned.
    if ([node isKindOfClass:[XTWhileNode class]])
        {
        [self deferBodyRejectEscapes:((XTWhileNode*)node).body loopDepth:loopDepth + 1];
        return;
        }
    if ([node isKindOfClass:[XTForCStyleNode class]])
        {
        [self deferBodyRejectEscapes:((XTForCStyleNode*)node).body loopDepth:loopDepth + 1];
        return;
        }
    if ([node isKindOfClass:[XTForInNode class]])
        {
        [self deferBodyRejectEscapes:((XTForInNode*)node).body loopDepth:loopDepth + 1];
        return;
        }
    if ([node isKindOfClass:[XTSwitchNode class]])
        {
        for (XTSwitchCase* c in ((XTSwitchNode*)node).cases)
            for (XTASTNode* st in c.body)
                [self deferBodyRejectEscapes:st loopDepth:loopDepth + 1];
        return;
        }
    }

/****************************************************************************\
|* Visit a while node: analyse condition and body.
|* @param node  The while loop node.
\****************************************************************************/
- (void)visitWhile:(XTWhileNode*)node
    {
    [self analyzeNode:node.condition];
    [self analyzeNode:node.body];
    }

/****************************************************************************\
|* Visit a C-style for loop: push scope, analyse init/cond/incr/body, pop.
|* @param node  The C-style for node.
\****************************************************************************/
- (void)visitForCStyle:(XTForCStyleNode*)node
    {
    [self pushScope];
    if (node.loopInit)
        [self analyzeNode:node.loopInit];
    if (node.condition)
        [self analyzeNode:node.condition];
    if (node.increment)
        [self analyzeNode:node.increment];
    [self analyzeNode:node.body];
    [self popScope];
    }

/****************************************************************************\
|* Visit a for-in loop: push scope, analyse loop var/collection/body, pop.
|* @param node  The for-in loop node.
\****************************************************************************/
- (void)visitForIn:(XTForInNode*)node
    {
    [self pushScope];
    // The COLLECTION is analysed first, because the loop variable's type may
    // have to come from it. The grammar makes that type optional —
    // `for (v in a)` — and nothing used to fill it in: lowering then found no
    // element type and returned without emitting a loop at all, so the body
    // silently never ran (bug 036). A loop that quietly does nothing reads as
    // "the collection was empty", which is the worst way for this to fail.
    [self analyzeNode:node.collection];
    XTVariableDeclNode* lv = [node.loopVar isKindOfClass:[XTVariableDeclNode class]]
                                 ? (XTVariableDeclNode*)node.loopVar
                                 : nil;
    if (lv && (!lv.declaredType || lv.declaredType.isAuto))
        {
        XTType* ct = node.collection.resolvedType;
        XTType* elem = nil;
        if ([ct isKindOfClass:[XTArrayType class]])
            elem = ((XTArrayType*)ct).elementType;
        else if (ct && ct.kind == XTTypeKindPointer)
            elem = ((XTPointerType*)ct).pointeeType;
        if (elem)
            {
            lv.declaredType = elem;
            }
        else
            {
            // Everything else (an Enumerable class, a slice expression whose
            // element type sema cannot see here) is REJECTED rather than
            // lowered into nothing. Naming the type always works.
            [self.diagnostics emitError:
                                  @"cannot infer the element type for this 'for ... in' — "
                                  @"give the loop variable a type, e.g. `for (u16 v in xs)`"
                                     at:node.location];
            }
        }
    // A collection with a PRIMITIVE element type hands back a BOXED value: the
    // container really holds `Number`s, and only the declared element type says
    // otherwise. `i32 v = a.get(i)` unboxes because the call path runs the
    // assignment-context rewrite; `for (i32 v in a)` did not, and the loop
    // variable received the Number POINTER reinterpreted as an integer — a
    // large, plausible, wrong number (bug 039).
    //
    // Rather than teach for-in its own unboxing rule — a second copy of the
    // policy, which is how this diverged in the first place — bind the element
    // under a HIDDEN name typed `Number*` and give the body a declaration of
    // the name the user wrote, initialised from it. That declaration is an
    // ordinary assignment context, so `unboxRhs:toLhsType:` fires on it exactly
    // as it does everywhere else, and everything downstream sees a plain local.
    if (lv && lv.declaredType && [self numberAccessorForLhsType:lv.declaredType])
        {
        XTType* collT = node.collection.resolvedType;
        XTType* carrier = [collT isKindOfClass:[XTPointerType class]]
                              ? ((XTPointerType*)collT).pointeeType
                              : collT;
        XTType* elem = carrier.collectionElementType;
        if (elem && !(elem.kind == XTTypeKindClass))
            {
            XTType* numberType = [self.typeTable typeForName:@"Number"];
            if (numberType)
                {
                NSString* hidden = [NSString stringWithFormat:@"__forin_boxed_%@", lv.varName];
                XTType* boxedT = [XTPointerType pointerToType:numberType];
                XTVariableDeclNode* bound =
                    [[XTVariableDeclNode alloc] initWithName:hidden
                                                        type:boxedT
                                                 initialiser:nil
                                                    location:lv.location];
                XTIdentifierNode* ref =
                    [[XTIdentifierNode alloc] initWithName:hidden
                                                  location:lv.location];
                ref.resolvedType = boxedT;
                XTVariableDeclNode* unboxed =
                    [[XTVariableDeclNode alloc] initWithName:lv.varName
                                                        type:lv.declaredType
                                                 initialiser:ref
                                                    location:lv.location];
                NSMutableArray<XTASTNode*>* stmts = [NSMutableArray arrayWithObject:unboxed];
                if ([node.body isKindOfClass:[XTBlockNode class]])
                    [stmts addObjectsFromArray:((XTBlockNode*)node.body).statements];
                else if (node.body)
                    [stmts addObject:node.body];
                node.loopVar = bound;
                node.body = [[XTBlockNode alloc] initWithStatements:stmts
                                                           location:node.location];
                }
            }
        }

    [self analyzeNode:node.loopVar];
    [self analyzeNode:node.body];
    [self popScope];
    }

/****************************************************************************\
|* Visit a throw node: analyse the operand.
|*
|* The operand must conform to `Error`; that check belongs with the effect rules
|* (E1 follow-up) — here we only make sure the expression itself is analysed, so
|* lowering meets an annotated tree.
|* @param node  The throw statement node.
\****************************************************************************/
- (void)visitThrow:(XTThrowNode*)node
    {
    if (!node.operand)
        return;
    [self analyzeNode:node.operand];

    // The operand must conform to `Error` (design §6.4). Without this any class
    // pointer could be thrown, and a handler's `e.message()` would then be a
    // call on something that does not have it.
    XTType* t = node.operand.resolvedType;
    if (!t || t.kind != XTTypeKindPointer)
        {
        [self.diagnostics emitError:@"'throw' wants a class reference conforming to 'Error'"
                                 at:node.location];
        return;
        }
    XTType* pointee = ((XTPointerType*)t).pointeeType;
    NSString* cname = pointee.displayName;
    // `Object@` is the untyped binder's type — re-throwing a caught error is
    // legitimate and cannot be checked statically, so it is allowed through.
    if ([cname isEqualToString:@"Object"])
        return;
    XTClassDeclNode* cls = cname ? self.classesByName[cname] : nil;
    if (!cls)
        return; // unknown class: other diagnostics cover it
    BOOL conforms = NO;
    for (XTClassDeclNode* c = cls; c; c = c.parentName ? self.classesByName[c.parentName] : nil)
        {
        if ([c.protocolNames containsObject:@"Error"])
            {
            conforms = YES;
            break;
            }
        }
    if (!conforms)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"'%@' cannot be thrown — it does not conform to 'Error'. Add <Error> to "
                                                  @"its class line and implement 'String@ message(void)'",
                                                  cname]
                                 at:node.location];
        }
    }

/****************************************************************************\
|* Visit a try/catch node.
|*
|* The guarded block is analysed in its own scope (visitBlock pushes one). The
|* handler gets a scope of its own in which the catch binder is declared as an
|* `Object@` — E1 has a single untyped handler, so the binder is the most general
|* reference type and `e.message()` resolves through the Error protocol. Typed
|* handlers (E2) will narrow this to the named class.
|* @param node  The try statement node.
\****************************************************************************/
- (void)visitTry:(XTTryNode*)node
    {
    self.tryDepth = self.tryDepth + 1;
    if (node.tryBlock)
        [self analyzeNode:node.tryBlock];
    self.tryDepth = self.tryDepth - 1;

    // Each arm gets its own scope with the binder declared. A TYPED arm binds at
    // the named class, so `e.method()` resolves against it directly; an untyped
    // arm binds at Object@, the most general reference.
    BOOL sawCatchAll = NO;
    for (XTCatchClause* c in node.catchClauses)
        {
        if (sawCatchAll)
            {
            [self.diagnostics emitWarning:
                                  @"this 'catch' can never run — an earlier arm already catches everything"
                                 category:XTWarnUnreachableCatch
                                       at:c.location];
            }
        if (c.typeName.length == 0)
            sawCatchAll = YES;

        [self pushScope];
        if (c.varName.length)
            {
            XTType* bound = nil;
            if (c.typeName.length)
                {
                XTType* named = [self.typeTable typeForName:c.typeName];
                if (!named)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"unknown type '%@' in catch", c.typeName]
                                             at:c.location];
                    }
                else
                    {
                    bound = (XTType*)[XTPointerType pointerToType:named];
                    }
                }
            if (!bound)
                {
                XTType* objType = [self.typeTable typeForName:@"Object"];
                bound = objType ? (XTType*)[XTPointerType pointerToType:objType]
                                : [XTType pointerType];
                }
            XTSymbol* sym = [[XTSymbol alloc] initWithName:c.varName type:bound];
            [self.currentScope defineSymbol:sym];
            }
        if (c.block)
            [self analyzeNode:c.block];
        [self popScope];
        }
    }

/****************************************************************************\
|* Visit a return node: analyse each return value expression.
|* @param node  The return statement node.
\****************************************************************************/
- (void)visitReturn:(XTReturnNode*)node
    {
    NSArray<XTType*>* retTypes = self.currentReturnTypes;

    // A bare `return;` in a function that declares a return type gives the
    // caller an UNDEFINED value — whatever the return register happens to
    // hold. Nothing caught it: the IR lowering emitted a Return with no value
    // operand into a `-> (T, Mem)` signature, which is malformed IR that every
    // backend then interpreted for itself.
    //
    // It is not hypothetical. `selfhost/codegen/Xt6502.xc` had
    // `bool dispatchCore(...) { ... if (op.equals("Phi")) return; ... }`, whose
    // caller reads the result to decide whether the opcode was handled — so
    // whether a Phi counted as handled was undefined. It also made the ported
    // and original lowerings disagree (the port synthesised `false`), which is
    // how it was found: a 1039-line diff in the self-hosting differential.
    if (node.values.count == 0 && retTypes.count > 0)
        {
        BOOL declaresValue = NO;
        for (XTType* t in retTypes)
            if (t && t.kind != XTTypeKindVoid)
                {
                declaresValue = YES;
                break;
                }
        if (declaresValue)
            {
            NSMutableArray<NSString*>* names = [NSMutableArray array];
            for (XTType* t in retTypes)
                [names addObject:t ? t.description : @"?"];
            [self.diagnostics emitError:
                                  [NSString stringWithFormat:
                                                @"`return;` with no value in a function returning %@ — "
                                                @"the caller would read an undefined value",
                                                [names componentsJoinedByString:@", "]]
                                     at:node.location];
            }
        }
    XTType* prev = self.expectedType;
    for (NSUInteger i = 0; i < node.values.count; i++)
        {
        self.expectedType = (i < retTypes.count) ? retTypes[i] : nil;
        [self analyzeNode:node.values[i]];
        }
    self.expectedType = prev;

    // Remember the class this actually returns, so a method declaring its
    // PARENT's (or protocol's) return type can be told it could declare its
    // own. AFTER the values are analysed — before it, every resolvedType is
    // still nil and the answer is uniformly "unknown". Intersected across
    // returns: two that disagree record "?", which suppresses the suggestion.
    // See checkCovariantReturnOpportunities.
    if (node.values.count == 1)
        {
        XTASTNode* rv = node.values.firstObject;
        // Look THROUGH an explicit upcast. `return (Object*)b;` is the shape
        // this diagnostic exists for — the code knows it has a Bag and is
        // discarding that on the way out — so the cast must not hide it.
        if ([rv isKindOfClass:[XTCastExprNode class]])
            {
            XTASTNode* inner = ((XTCastExprNode*)rv).operand;
            if (inner.resolvedType)
                rv = inner;
            }
        XTType* rt = rv.resolvedType;
        NSString* cls = nil;
        if ([rt isKindOfClass:[XTPointerType class]])
            {
            XTType* pointee = ((XTPointerType*)rt).pointeeType;
            if (pointee && pointee.kind == XTTypeKindClass)
                cls = pointee.displayName;
            }
        id owner = self.currentMethod ?: (id)self.currentFunction;
        if (owner && cls)
            {
            NSString* seen = [owner observedReturnClass];
            if (!seen)
                [owner setObservedReturnClass:cls];
            else if (![seen isEqualToString:cls])
                [owner setObservedReturnClass:@"?"];
            }
        else if (owner)
            {
            [owner setObservedReturnClass:@"?"]; // returns something non-class
            }
        }

    // Unboxing: `return arr.get(0);` where the function returns a
    // primitive numeric. Replace each gappy slot with the
    // `((Number@)expr).asXXX()` rewrite so the return value comes
    // back primitive-typed. Loops over every return slot — multi-
    // return functions can mix primitive and class-pointer slots
    // independently.
    NSMutableArray<XTASTNode*>* unboxedValues = nil;
    for (NSUInteger i = 0; i < node.values.count && i < retTypes.count; i++)
        {
        if (![self canUnboxRhsType:node.values[i].resolvedType
                         toLhsType:retTypes[i]])
            continue;
        XTASTNode* unboxed = [self unboxRhs:node.values[i]
                                  toLhsType:retTypes[i]];
        if (!unboxed)
            continue;
        if (!unboxedValues)
            unboxedValues = [node.values mutableCopy];
        unboxedValues[i] = unboxed;
        }
    if (unboxedValues)
        node.values = unboxedValues;

    // PR4: class-pointer return compatibility — same rule as assign,
    // keyed on the function's declared return type tuple.
    for (NSUInteger i = 0; i < node.values.count && i < retTypes.count; i++)
        {
        [self checkClassPointerAssign:retTypes[i]
                              rhsType:node.values[i].resolvedType
                              rhsNode:node.values[i]
                                 site:@"return"
                             location:node.location];
        }
    }

/****************************************************************************\
|* PR4 class-pointer compat — reject assignment / return of an
|* unrelated class pointer into a class-pointer slot. Exact-class
|* match is always allowed; upcast (RHS = descendant of LHS) is
|* allowed and participates in subtype compatibility. `null` and
|* non-class-pointer traffic are left alone — the rule is specific
|* to class-pointer ↔ class-pointer assignments.
\****************************************************************************/
- (void)checkClassPointerAssign:(nullable XTType*)lhsType
                        rhsType:(nullable XTType*)rhsType
                        rhsNode:(XTASTNode*)rhsNode
                           site:(NSString*)site
                       location:(XTSourceLocation*)loc
    {
    if (!lhsType || !rhsType)
        return;

    // A BLOCK is not a bound method (uxkit/030). Blocks desugar to a class
    // pointer `Blk$<sig>*`; a `^` is a two-word (receiver, code) pair. Storing
    // the one in the other type-checked and then failed in two different silent
    // ways — the slot read back FALSE and the call never happened, or it read
    // TRUE and the call took SIGBUS inside the callee. Neither said anything.
    //
    // The refusal is PERMANENT and goes BOTH ways (settled 2026-08-28,
    // private:docs/Design/bound-methods.md §7). This comment used to say the
    // unification was planned; it is a NON-GOAL. A block owns its captures, a
    // callback never owns its receiver and auto-zeroes when stored — unifying
    // them would either retain the receiver, closing exactly the cycles §6
    // rejects, or make `block` mean two different lifetimes depending on how it
    // was built.
    if (rhsType.boundMethodSignature == nil && lhsType.boundMethodSignature != nil)
        {
        XTType* rpk = [rhsType isKindOfClass:[XTPointerType class]]
                          ? ((XTPointerType*)rhsType).pointeeType
                          : nil;
        if (rpk && rpk.kind == XTTypeKindClass && [rpk.displayName hasPrefix:@"Blk$"])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"%@: a block cannot be stored in a bound-method ('^') slot — "
                                                      @"a block is a class reference and a '^' is a (receiver, code) "
                                                      @"pair, so the value would be read back as null or called as "
                                                      @"garbage. Pass '&obj.method' where a '^' is expected, or make "
                                                      @"the slot a block type.",
                                                      site]
                                     at:loc];
            return;
            }
        }

    // ...and the OTHER direction, which was silently accepted. `b = &c.m;`
    // where b is a block compiled clean, tested TRUE, and then the call did
    // NOTHING — a callback that never fires, which is the button that does
    // nothing. Exactly the silent shape the refusal above exists to prevent,
    // missing only because the check was written one-way.
    if (rhsType.boundMethodSignature != nil && lhsType.boundMethodSignature == nil)
        {
        XTType* lpk = [lhsType isKindOfClass:[XTPointerType class]]
                          ? ((XTPointerType*)lhsType).pointeeType
                          : nil;
        if (lpk && lpk.kind == XTTypeKindClass && [lpk.displayName hasPrefix:@"Blk$"])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"%@: a bound method cannot be stored in a block slot — a block "
                                                      @"OWNS what it captures and a callback never owns its receiver, "
                                                      @"so the conversion would either retain the receiver (closing a "
                                                      @"reference cycle) or give you a block with no owner. It is a "
                                                      @"non-goal, not a missing feature. Declare the slot as "
                                                      @"'callback <name> RET(params)' instead.",
                                                      site]
                                     at:loc];
            return;
            }
        }

    if (![lhsType isKindOfClass:[XTPointerType class]])
        return;
    if (![rhsType isKindOfClass:[XTPointerType class]])
        return;
    XTType* lp = ((XTPointerType*)lhsType).pointeeType;
    XTType* rp = ((XTPointerType*)rhsType).pointeeType;
    if (!lp || !rp)
        return;
    if (lp.kind != XTTypeKindClass && rp.kind != XTTypeKindClass)
        return;
    // Exactly ONE side is a class pointer: a raw pointer is not a class
    // reference, and letting one through silently is how `String* x = buf;`
    // compiled, dispatched through byte-soup, and killed a worker before
    // anything complained (blewit, 2026-08-22). `pointer` (the untyped
    // escape hatch) never reaches here — it is not an XTPointerType — and
    // an explicit `(T*)p` cast retypes the value before this check sees it,
    // so both deliberate outs survive. The null-literal idiom is honoured
    // in both directions.
    if (lp.kind != rp.kind &&
        (lp.kind == XTTypeKindClass || rp.kind == XTTypeKindClass))
        {
        if ([rhsNode isKindOfClass:[XTLiteralIntNode class]] &&
            ((XTLiteralIntNode*)rhsNode).intValue == 0)
            return;
        if (lp.kind == XTTypeKindClass)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"%@: a raw '%@' is not a class reference '%@*' — build one "
                                                      @"(e.g. %@.withBytes / a constructor), or cast explicitly if "
                                                      @"the pointer really holds an instance",
                                                      site, rhsType.displayName ?: @"pointer",
                                                      lp.displayName, lp.displayName]
                                     at:loc];
            }
        else
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"%@: a class reference '%@*' is not a raw '%@' — take the "
                                                      @"bytes you mean (e.g. cString()/bytes()), or cast explicitly",
                                                      site, rp.displayName, lhsType.displayName ?: @"pointer"]
                                     at:loc];
            }
        return;
        }
    // PR9: destination with a protocol constraint accepts any
    // class pointer whose class conforms to the protocol.
    NSString* destProto = lp.protocolConstraint;
    if (destProto.length > 0)
        {
        // A value already typed as the same protocol (e.g. a protocol-typed
        // parameter stored into a protocol-typed ivar) is compatible — a
        // protocol is trivially "itself". This is what lets a framework keep a
        // delegate as `SomeProtocol@`.
        if ([rp.displayName isEqualToString:destProto] ||
            [rp.protocolConstraint isEqualToString:destProto])
            return;
        XTClassDeclNode* rc = self.classesByName[rp.displayName];
        if (rc && [self class:rc conformsToProtocol:destProto])
            return;
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"%@: '%@' does not conform to protocol '%@'",
                                                  site, rp.displayName, destProto]
                                 at:loc];
        return;
        }
    if ([lp.displayName isEqualToString:rp.displayName])
        return;
    // Upcast a protocol reference to `Object@` (#9): every class that conforms to
    // a protocol descends from Object, so a `P@` is always a valid `Object@`. This
    // is the bridge the nib loader needs to hold a resolved UIDesignable as an
    // `Object@` outlet value. (The reverse — `Object@` → `P@` — is a runtime
    // conformance downcast, handled at the cast site, not here.)
    if (rp.protocolConstraint.length > 0 && [lp.displayName isEqualToString:@"Object"])
        return;
    XTClassDeclNode* lc = self.classesByName[lp.displayName];
    XTClassDeclNode* rc = self.classesByName[rp.displayName];
    if (lc && rc && [self class:rc inheritsFromOrEquals:lc])
        return;
    // `null` cast / zero-literal slipping through the pointer path —
    // `(T@)0` has class-pointer type post-cast. Allow the common null
    // idiom so user code keeps compiling.
    if ([rhsNode isKindOfClass:[XTLiteralIntNode class]] &&
        ((XTLiteralIntNode*)rhsNode).intValue == 0)
        return;
    [self.diagnostics emitError:[NSString stringWithFormat:
                                              @"%@: '%@' is not a subclass of '%@'",
                                              site, rp.displayName, lp.displayName]
                             at:loc];
    }

/****************************************************************************\
|* Extract a compile-time integer value from a case-label expression.
|* Accepts integer literals (any width) and identifiers bound to enum
|* constants (their symbol carries `constantValue`). Returns nil for
|* anything else.
\****************************************************************************/
- (nullable NSNumber*)caseConstantValueOf:(XTASTNode*)expr
    {
    if ([expr isKindOfClass:[XTLiteralIntNode class]])
        {
        return @(((XTLiteralIntNode*)expr).intValue);
        }
    if ([expr isKindOfClass:[XTIdentifierNode class]])
        {
        XTIdentifierNode* id = (XTIdentifierNode*)expr;
        XTSymbol* sym = [[self currentScope] lookupSymbol:id.identName];
        if (sym && sym.constantValue)
            return sym.constantValue;
        }
    return nil;
    }

/****************************************************************************\
|* Visit a switch statement: validate subject is integer/enum/bool, fold
|* every case label to a constant, flag duplicates and multiple defaults.
|* @param node  The switch statement node.
\****************************************************************************/
- (void)visitSwitch:(XTSwitchNode*)node
    {
    [self analyzeNode:node.subject];
    XTType* st = node.subject.resolvedType;
    BOOL subjectOk = NO;
    if (st)
        {
        switch (st.kind)
            {
        case XTTypeKindI8:
        case XTTypeKindU8:
        case XTTypeKindI16:
        case XTTypeKindU16:
        case XTTypeKindI32:
        case XTTypeKindU32:
        case XTTypeKindBool:
        case XTTypeKindEnum:
            subjectOk = YES;
            break;
        default:
            break;
            }
        }
    if (!subjectOk)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"switch subject must be integer, bool, or enum (got %@)",
                                                  st ? st.displayName : @"<unresolved>"]
                                 at:node.location];
        }

    NSMutableSet<NSNumber*>* seenSingles = [NSMutableSet set];
    BOOL haveDefault = NO;
    for (XTSwitchCase* arm in node.cases)
        {
        if (arm.isDefault)
            {
            if (haveDefault)
                {
                [self.diagnostics emitError:@"duplicate 'default' label in switch" at:arm.location];
                }
            haveDefault = YES;
            }
        for (XTCaseLabel* label in arm.labels)
            {
            if (!label.isRange)
                {
                [self analyzeNode:label.singleValue];
                NSNumber* cv = [self caseConstantValueOf:label.singleValue];
                if (!cv)
                    {
                    [self.diagnostics emitError:@"case label must be a constant integer or enum value"
                                             at:label.location];
                    continue;
                    }
                if ([seenSingles containsObject:cv])
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"duplicate case label %@", cv]
                                             at:label.location];
                    }
                else
                    {
                    [seenSingles addObject:cv];
                    }
                }
            else
                {
                NSNumber *loN = nil, *hiN = nil;
                if (label.rangeLo)
                    {
                    [self analyzeNode:label.rangeLo];
                    loN = [self caseConstantValueOf:label.rangeLo];
                    if (!loN)
                        {
                        [self.diagnostics emitError:@"range-case lo bound must be a constant integer or enum value"
                                                 at:label.rangeLo.location];
                        }
                    }
                if (label.rangeHi)
                    {
                    [self analyzeNode:label.rangeHi];
                    hiN = [self caseConstantValueOf:label.rangeHi];
                    if (!hiN)
                        {
                        [self.diagnostics emitError:@"range-case hi bound must be a constant integer or enum value"
                                                 at:label.rangeHi.location];
                        }
                    }
                if (loN && hiN && loN.longLongValue > hiN.longLongValue)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"range-case lo (%@) must be <= hi (%@)", loN, hiN]
                                             at:label.location];
                    }
                }
            }
        for (XTASTNode* stmt in arm.body)
            {
            [self analyzeNode:stmt];
            }
        }
    }

/****************************************************************************\
|* Visit a break node: no semantic action needed.
\****************************************************************************/
- (void)visitBreak:(XTASTNode*)node
    {
    (void)node;
    }
/****************************************************************************\
|* Visit a continue node: no semantic action needed.
\****************************************************************************/
- (void)visitContinue:(XTASTNode*)node
    {
    (void)node;
    }

/****************************************************************************\
|* Visit a delete node: recurse into the operand, validate that its
|* resolved type is a heap pointer (XTPointerType) and that the active
|* allocator can actually free. Bump-only targets reject `delete` at
|* compile time.
\****************************************************************************/
- (void)visitDelete:(XTDeleteNode*)node
    {
    [self analyzeNode:node.operand];

    NSString* kw = (node.op == XTRefOpRetain)    ? @"retain"
                   : (node.op == XTRefOpRelease) ? @"release"
                                                 : @"delete";

    if (![self.allocator isEqualToString:@"heap"])
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"`%@` requires -falloc=heap (not supported on bump-only targets)", kw]
                                 at:node.location];
        return;
        }

    XTType* t = node.operand.resolvedType;
    if (!t)
        return; // earlier error
    if (![t isKindOfClass:[XTPointerType class]])
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"`%@` operand must be a heap pointer, got %@", kw, t]
                                 at:node.location];
        return;
        }

    // Automatic reference counting gate — CLASS pointees only.
    //
    // ARC inserts retain/release around strong class-pointer locals,
    // assignments and returns, so a hand-written retain / release /
    // delete on top of that would double-decrement and free an object
    // that is still aliased. Reject all three, and say what to do
    // instead.
    //
    // It does NOT apply to anything else. ARC never manages a struct
    // array or a primitive array (`new Point[4]`, `new u8[20]`), so
    // `delete` is the ONLY way to free one and there is no second
    // decrement to collide with. This gate used to reject those too,
    // which is why 17 fixtures carried `-farc=off` — not because they
    // wanted manual class lifecycle, but because it was the only way to
    // free memory ARC was never going to free. That flag is gone
    // (bug 026: it changed no IR, so those were ARC builds anyway).
    XTType* pointee = ((XTPointerType*)t).pointeeType;
    if (pointee && pointee.kind == XTTypeKindClass)
        {
        NSString* hint = (node.op == XTRefOpDelete)
                             ? @"let the scope exit release it"
                             : @"the compiler manages class refcounts automatically";
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"`%@` is not allowed on a class instance under ARC — %@", kw, hint]
                                 at:node.location];
        }
    }
/****************************************************************************\
|* Visit an asm block: no semantic action needed.
\****************************************************************************/
- (void)visitAsmBlock:(XTASTNode*)node
    {
    XTAsmBlockNode* blk = (XTAsmBlockNode*)node;
    if (![blk isKindOfClass:[XTAsmBlockNode class]])
        return;
    // A small curated set of runtime labels that are known to touch the
    // xtc software stack. These live outside XTRuntimeRoutineMap (they're
    // emitted inline by codegen, not pulled via the helper map), so sema
    // names them explicitly. Any JSR to one of these from inline asm
    // inside a user function makes that function locally stack-using.
    // Unknown JSR targets are ignored — they typically reference either
    // user code (already covered by XTCallExprNode edges), forward asm
    // labels inside the same block, or Atari OS vectors (out of scope).
    static NSSet<NSString*>* knownUnsafeAsmTargets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      knownUnsafeAsmTargets = [NSSet setWithObjects:
                                         @"_xcall", @"_xcall_main",
                                         @"_heap_init", @"_heap_alloc", @"_heap_alloc16",
                                         @"_heap_free", @"_retain", @"_release",
                                         nil];
    });
    for (NSString* raw in blk.lines)
        {
        NSRange semi = [raw rangeOfString:@";"];
        NSString* line = (semi.location == NSNotFound)
                             ? raw
                             : [raw substringToIndex:semi.location];
        NSRange jsr = [line rangeOfString:@"jsr"
                                  options:NSCaseInsensitiveSearch];
        if (jsr.location == NSNotFound)
            continue;
        NSString* rest = [line substringFromIndex:NSMaxRange(jsr)];
        NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
        rest = [rest stringByTrimmingCharactersInSet:ws];
        if (rest.length == 0)
            continue;
        NSCharacterSet* identSet = [NSCharacterSet characterSetWithCharactersInString:
                                                       @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
        NSUInteger end = 0;
        while (end < rest.length &&
               [identSet characterIsMember:[rest characterAtIndex:end]])
            {
            end++;
            }
        if (end == 0)
            continue;
        NSString* target = [rest substringToIndex:end];
        if (![knownUnsafeAsmTargets containsObject:target])
            continue;
        NSString* synth = [@"_rt_" stringByAppendingString:target];
        [self recordCallEdgeToLabel:synth];
        [self.stackUsingFunctions addObject:synth];
        self.labelDisplayNames[synth] = target;
        self.stackUseReasons[synth] =
            [NSString stringWithFormat:
                          @"is a runtime helper that pushes to the xtc stack"];
        }
    }

/****************************************************************************\
|* Visit an expression statement: analyse the contained expression.
|* @param node  The expression statement node.
\****************************************************************************/
- (void)visitExprStatement:(XTExpressionStatementNode*)node
    {
    [self analyzeNode:node.expression];
    }

/****************************************************************************\
|* Visit a tuple assignment: analyse the source expression and any target
|* variable declarations.
|* @param node  The tuple assignment node.
\****************************************************************************/
- (void)visitTupleAssign:(XTTupleAssignNode*)node
    {
    [self analyzeNode:node.sourceExpr];
    for (XTASTNode* target in node.targets)
        {
        if ([target isKindOfClass:[XTVariableDeclNode class]])
            {
            [self analyzeNode:target];
            }
        }
    }

/****************************************************************************\
|* Visit a binary expression: analyse both operands, compute the widened
|* result type, promote shifts whose count overflows the LHS width, and
|* attempt constant folding.
|* @param node  The binary expression node.
\****************************************************************************/
- (void)visitBinaryExpr:(XTBinaryExprNode*)node
    {
    // Propagate the outer expected type down to both operands —
    // this is what lets `2.0d * Math.PI()` resolve PI()'s zero-arg
    // overload as double when the binop itself is in a double
    // context (e.g. `double x = 2.0d * Math.PI();`). Operands are
    // analysed independently; their per-operand resolved types
    // still drive the widened result type below.
    [self analyzeNode:node.left];
    [self analyzeNode:node.right];
    // An operand that reads a primitive element out of a typed collection is
    // the BOX until it is unboxed, and the operator below types itself from
    // its operands — so this has to happen before that, not after (bug 046).
    [node replaceLeft:[self unboxCollectionElement:node.left]];
    [node replaceRight:[self unboxCollectionElement:node.right]];

    XTType* lt = node.left.resolvedType;
    XTType* rt = node.right.resolvedType;
    if (lt && rt)
        {
        // The operator's type is the WIDENING OF ITS OPERANDS, and nothing
        // else. `u8 + u8` is a u8 and wraps at 8 bits; only genuinely
        // mixed-width operands widen (`u8 + u16` -> u16). The result then
        // converts to whatever it is assigned to, so widening is a property of
        // the ASSIGNMENT, not of the operator.
        //
        // This used to C-promote every sub-word add/sub/mul/div/mod to 32 bits,
        // so that `u32 x = u16a * u16b` gave the true product. That made an
        // expression's meaning depend on where its result went — the very thing
        // the no-promotion rule exists to prevent — and it disagreed with the
        // language spec, which the corpus never noticed
        // because it pinned `u8 c = a + b` (truncated on store, so 44 either
        // way) and the genuinely mixed case, but never `u16 w = <u8> + <u8>`.
        // Decided 2026-08-05: operands decide. See private:docs/bugs/041.
        //
        // To get a wider result, widen the OPERANDS: `(u32)a * (u32)b`.
        //
        // `p - q` is the exception: a pointer DIFFERENCE is not a pointer. It
        // asks how far apart two addresses are, and the answer is a COUNT, in
        // ELEMENTS as C has it. Without this it fell into the width comparison
        // below, which sees two equal-width unsigned operands and hands back
        // the POINTER type — so `q - p` was typed `double*`, and from there the
        // reference refused to lower it at all while the port emitted a raw
        // BYTE subtraction. One compiler rejected valid C, the other answered
        // in the wrong unit (bug 206).
        //
        // The type is C's ptrdiff_t: a signed integer that spans the TARGET's
        // address space. 8-byte pointers give i64, 4-byte give i32, and the
        // banked 6502's 3-byte pointer (16-bit address plus a bank byte, and a
        // single allocation cannot span banks) gives i16.
        //
        // This was briefly a fixed i32 on every target, justified by the
        // self-hosted sema having no pointer width to consult. That reasoning
        // was wrong twice over: a 32-bit difference across a 64-bit address
        // space is simply the wrong type, and the byte-identity the two
        // compilers owe each other requires them to make the SAME choice, not a
        // FIXED one — both asking the target's width agree perfectly. The port
        // now gets the width the same way lowering already did.
        if (node.op == XTBinaryOpSub && lt && rt && lt.kind == XTTypeKindPointer && rt.kind == XTTypeKindPointer)
            {
            NSUInteger pw = [XTPointerType heapPointerWidth];
            node.resolvedType = pw >= 8   ? [XTType i64Type]
                                : pw >= 4 ? [XTType i32Type]
                                          : [XTType i16Type];
            }
        else
            {
            node.resolvedType = [XTType widenType:lt with:rt];
            }
        }
    else
        {
        node.resolvedType = lt ?: rt ?
                                     : [XTType u8Type];
        }

    // A COMPARISON yields bool, whatever it compared. This used to fall through
    // to the widening above, so `a < b` on two i64s was typed i64 — the operand
    // type, not the result's. Lowering emits `ICmp -> Bool` regardless, so the
    // wrong type was invisible until something CONSUMED it: a ternary widens its
    // arms to the union of their types, so
    //
    //     bool up = k != 0 ? viaCall(k) : ((hi - 4) < (4 - lo));
    //
    // took union(bool, i64) = i64, widened the CALL arm with a ZExt, and left
    // the comparison arm alone because it already believed it was i64. The phi
    // then had an i64 result with a Bool incoming — malformed IR on every
    // target, and only wasm validates types, so only wasm rejected it. Native
    // builds of the same source ran, which is what made it look wasm-specific.
    // (Reported from blewit's spike/xcc-ternary.)
    switch (node.op)
        {
    case XTBinaryOpEq:
    case XTBinaryOpNeq:
    case XTBinaryOpLt:
    case XTBinaryOpGt:
    case XTBinaryOpLe:
    case XTBinaryOpGe:
    case XTBinaryOpLogAnd:
    case XTBinaryOpLogOr:
        node.resolvedType = [XTType boolType];
        break;
    default:
        break;
        }

    // Promote `X << C` when the compile-time constant shift count
    // C is ≥ the LHS bit width: every bit of the LHS would
    // otherwise be shifted out at LHS width, so the user must
    // mean for the operand to be promoted first. `u8 << 8` was
    // folding to u8(0), `u8 << 16` to u8(0), `u16 << 16` to
    // u16(0), etc. Widen to the smallest type that can hold all
    // the shifted bits — u16 for a u8 shifted by 8–15, u32 for
    // any shift that overflows u16.
    // Non-overflowing shifts (u16 << 8, u8 << 4, …) are left
    // alone: the LHS keeps bits that matter, top-bit loss is
    // standard C behaviour, and existing idioms like
    // `fieldVal = (fieldVal << 8) | lo` in Stdio.printStruct
    // rely on the shift staying at u16 width.
    if (node.op == XTBinaryOpShl &&
        [node.right isKindOfClass:[XTLiteralIntNode class]] &&
        lt && lt.isInteger)
        {
        int64_t cnt = ((XTLiteralIntNode*)node.right).intValue;
        NSUInteger lhsBits = lt.byteWidth * 8;
        if (cnt > 0 && (NSUInteger)cnt >= lhsBits)
            {
            NSUInteger neededBits = lhsBits + (NSUInteger)cnt;
            NSUInteger neededBytes = (neededBits <= 16) ? 2 : 4;
            NSUInteger currentBytes = node.resolvedType ? node.resolvedType.byteWidth : 1;
            if (neededBytes > currentBytes)
                {
                BOOL isSigned = node.resolvedType.isSigned;
                if (neededBytes == 2)
                    {
                    node.resolvedType = isSigned ? [XTType i16Type] : [XTType u16Type];
                    }
                else
                    {
                    node.resolvedType = isSigned ? [XTType i32Type] : [XTType u32Type];
                    }
                }
            }
        }

    // Constant folding for integer binary ops
    [self foldBinaryExpr:node];
    }

/****************************************************************************\
|* Constant-fold a binary expression whose both operands are integer literals.
|* Computes the result in-place and updates the node's resolved type. Division
|* or modulus by zero is left unfolded.
|* @param node  The binary expression node to fold.
\****************************************************************************/
// The full-precision integer value of a wholly-constant expression, or NO if
// the node is not a compile-time integer constant. Recurses through nested
// binary ops so a CHAIN of literals — `CKE * CKR * 16` — is evaluated whole, in
// 64 bits, instead of one node at a time. Folding one node at a time truncated
// the chain: `192 * 128` folded to a u16 (24576 fits), then `* 16` ran in that
// u16 width and wrapped to 0, silently (bug 198). A constant expression has no
// runtime and no wrapping intent, so it is evaluated at full width; the §3.1
// same-width-wrapping rule still governs RUNTIME arithmetic, where an operand is
// a variable and this returns NO.
- (BOOL)constantIntValueOf:(XTASTNode*)node into:(int64_t*)out
    {
    if ([node isKindOfClass:[XTLiteralIntNode class]])
        {
        *out = ((XTLiteralIntNode*)node).intValue;
        return YES;
        }
    if ([node isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        int64_t lv = 0, rv = 0;
        if (![self constantIntValueOf:b.left into:&lv])
            return NO;
        if (![self constantIntValueOf:b.right into:&rv])
            return NO;
        switch (b.op)
            {
        case XTBinaryOpAdd:
            *out = lv + rv;
            return YES;
        case XTBinaryOpSub:
            *out = lv - rv;
            return YES;
        case XTBinaryOpMul:
            *out = lv * rv;
            return YES;
        case XTBinaryOpDiv:
            if (rv == 0)
                return NO;
            *out = lv / rv;
            return YES;
        case XTBinaryOpMod:
            if (rv == 0)
                return NO;
            *out = lv % rv;
            return YES;
        case XTBinaryOpBitAnd:
            *out = lv & rv;
            return YES;
        case XTBinaryOpBitOr:
            *out = lv | rv;
            return YES;
        case XTBinaryOpBitXor:
            *out = lv ^ rv;
            return YES;
        case XTBinaryOpShl:
            *out = lv << rv;
            return YES;
        case XTBinaryOpShr:
            *out = lv >> rv;
            return YES;
        case XTBinaryOpEq:
            *out = (lv == rv) ? 1 : 0;
            return YES;
        case XTBinaryOpNeq:
            *out = (lv != rv) ? 1 : 0;
            return YES;
        case XTBinaryOpLt:
            *out = (lv < rv) ? 1 : 0;
            return YES;
        case XTBinaryOpGt:
            *out = (lv > rv) ? 1 : 0;
            return YES;
        case XTBinaryOpLe:
            *out = (lv <= rv) ? 1 : 0;
            return YES;
        case XTBinaryOpGe:
            *out = (lv >= rv) ? 1 : 0;
            return YES;
        default:
            return NO;
            }
        }
    return NO;
    }

- (void)foldBinaryExpr:(XTBinaryExprNode*)node
    {
    // An operand may itself be a constant CHAIN (`192 * 128`) rather than a bare
    // literal — evaluate both wholly, in full precision, so the chain does not
    // truncate at each step (bug 198). A runtime operand (a variable) is not
    // constant and stops the fold, preserving §3.1 wrapping for real arithmetic.
    int64_t lv = 0, rv = 0;
    if (![self constantIntValueOf:node.left into:&lv])
        return;
    if (![self constantIntValueOf:node.right into:&rv])
        return;
    int64_t result = 0;
    switch (node.op)
        {
    case XTBinaryOpAdd:
        result = lv + rv;
        break;
    case XTBinaryOpSub:
        result = lv - rv;
        break;
    case XTBinaryOpMul:
        result = lv * rv;
        break;
    case XTBinaryOpDiv:
        if (rv == 0)
            return;
        result = lv / rv;
        break;
    case XTBinaryOpMod:
        if (rv == 0)
            return;
        result = lv % rv;
        break;
    case XTBinaryOpBitAnd:
        result = lv & rv;
        break;
    case XTBinaryOpBitOr:
        result = lv | rv;
        break;
    case XTBinaryOpBitXor:
        result = lv ^ rv;
        break;
    case XTBinaryOpShl:
        result = lv << rv;
        break;
    case XTBinaryOpShr:
        result = lv >> rv;
        break;
    case XTBinaryOpEq:
        result = (lv == rv) ? 1 : 0;
        break;
    case XTBinaryOpNeq:
        result = (lv != rv) ? 1 : 0;
        break;
    case XTBinaryOpLt:
        result = (lv < rv) ? 1 : 0;
        break;
    case XTBinaryOpGt:
        result = (lv > rv) ? 1 : 0;
        break;
    case XTBinaryOpLe:
        result = (lv <= rv) ? 1 : 0;
        break;
    case XTBinaryOpGe:
        result = (lv >= rv) ? 1 : 0;
        break;
    default:
        return;
        }
    // The folded node's type must be wide enough for BOTH the operands and the
    // result, because lowerBinaryExpr coerces the operands to node.resolvedType.
    // Sizing it from the RESULT alone truncated the operands when the result is
    // narrower than they are: `840 / 56` folded as (840 & 0xFF)/56 = 72/56 = 1,
    // and `840 / 7` as 72/7 = 10 (bug 180) — the dividend taken mod 256. Sizing
    // it from the OPERANDS alone would instead break `15 * 56 / 56` (u8*u8 wraps
    // to 72). Take the WIDER of the operand-widened type and the result type.
    XTType* resultTy = [self inferTypeFromLiteral:[[XTLiteralIntNode alloc]
                                                      initWithValue:result
                                                           location:node.location]];
    XTType* operandTy = [XTType widenType:node.left.resolvedType with:node.right.resolvedType];
    NSUInteger ow = operandTy ? operandTy.byteWidth : 0;
    NSUInteger rw = resultTy ? resultTy.byteWidth : 0;
    node.resolvedType = (operandTy && ow > rw) ? operandTy : resultTy;
    }

/****************************************************************************\
|* Visit a unary expression: analyse the operand and resolve the result type
|* based on the operator (neg, bitwise not, logical not, addr-of, deref, etc.).
|* @param node  The unary expression node.
\****************************************************************************/
/****************************************************************************\
|* The bound-method type `{ pointer recv; <fn>@ code; }` for a signature,
|* cached in the type table under `$bound_<fn>` so every `^` on the same
|* signature yields the SAME type object (a `^` is compared as a pair, so
|* two structurally-identical-but-distinct types would break equality and
|* assignment between two `^`s naming the same kind of action).
|*
|* Mirrors XTParser's boundMethodTypeForSignature: — the parser interns the
|* type the user SPELLS (`act_t^`), this interns the one `&obj.method`
|* PRODUCES, and they must land on the same object.
\****************************************************************************/
- (XTType*)boundMethodTypeForSignature:(XTFunctionType*)fn
    {
    NSString* name = [NSString stringWithFormat:@"$bound_%@", fn.displayName];
    XTType* cached = [self.typeTable typeForName:name];
    if (cached)
        return cached;

    XTStructField* recv = [[XTStructField alloc]
        initWithName:@"recv"
                type:[XTPointerType pointerToType:[XTType u8Type]]];
    XTStructField* code = [[XTStructField alloc]
        initWithName:@"code"
                type:[XTPointerType pointerToType:fn]];
    XTStructType* st = [XTStructType structNamed:name fields:@[ recv, code ]];
    st.boundMethodSignature = fn;
    [self.typeTable registerType:st forName:name];
    return st;
    }

/****************************************************************************\
|* Resolve `&obj.method` into a bound-method (fat pointer) value.
|*
|* Returns NO when the member isn't a method, leaving the caller to fall
|* through to ordinary `&` handling (so `&obj.ivar` still means what it
|* always did).
|*
|* Works off a concrete class receiver OR a protocol-typed one. The protocol
|* case is the whole point: `&delegate.windowShouldClose` on a protocol
|* pointer picks up the slot, so the `^` reads the receiver's runtime vtable
|* and comes back NULL when the class didn't implement an `optional` method.
\****************************************************************************/
- (BOOL)analyzeBoundMethodRef:(XTUnaryExprNode*)node
    {
    XTMemberAccessNode* ma = (XTMemberAccessNode*)node.operand;

    // `&Controller.onClick` — a STATIC method. The base names a class, not an
    // instance, so it must be recognised before analyzeNode: is let near it
    // (`Controller` is not a variable and would resolve to nothing).
    //
    // A static method takes no `self`, so this is not a bound method at all —
    // it's an ordinary FUNCTION POINTER, and that's exactly the right type for
    // it. It then reaches a `^` parameter through the same `@`→`^` widening
    // (and the same adapter thunk) that a free function does, so
    // `setAction(&Controller.onClick)` works with no special case.
    if (ma.base.nodeKind == XTASTNodeKindIdentifier)
        {
        NSString* baseName = ((XTIdentifierNode*)ma.base).identName;
        XTClassDeclNode* cls = self.classesByName[baseName];
        // A local variable of the same name shadows the class name.
        BOOL shadowed = [[self currentScope] lookupSymbol:baseName] != nil;
        if (cls && !shadowed)
            {
            XTMethodDeclNode* sm = nil;
            XTClassDeclNode* smCls = nil;
            for (XTClassDeclNode* c = cls; c != nil && !sm; c = c.parentClass)
                {
                for (XTMethodDeclNode* cm in c.methods)
                    {
                    if (!cm.isStatic)
                        continue;
                    if ([cm.methodName isEqualToString:ma.memberName])
                        {
                        sm = cm;
                        smCls = c;
                        break;
                        }
                    }
                }
            if (!sm)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"class '%@' has no static method '%@' to take the address of",
                                                          baseName, ma.memberName]
                                         at:node.location];
                node.resolvedType = [XTType pointerType];
                return YES;
                }
            NSMutableArray<XTType*>* sptypes = [NSMutableArray array];
            for (XTParamNode* p in sm.parameters)
                [sptypes addObject:p.paramType];
            XTFunctionType* sfn = [XTFunctionType
                functionWithReturnTypes:(sm.returnTypes ?: @[ [XTType voidType] ])
                             paramTypes:sptypes
                              isVarArgs:sm.isVarArgs];
            ma.resolvedBoundMethod = sm;
            ma.resolvedBoundClass = smCls.className;
            ma.resolvedBoundSlot = nil; // statics never dispatch
            ma.resolvedType = [XTPointerType pointerToType:sfn];
            node.resolvedType = ma.resolvedType;
            return YES;
            }
        }

    [self analyzeNode:ma.base];

    // Peel the receiver down to the class / protocol marker it names.
    XTType* rt = ma.base.resolvedType;
    XTType* carrier = nil;
    if ([rt isKindOfClass:[XTPointerType class]])
        carrier = ((XTPointerType*)rt).pointeeType;
    else if (rt && rt.kind == XTTypeKindClass)
        carrier = rt;
    if (!carrier)
        return NO;

    XTMethodDeclNode* m = nil;
    NSString* implClass = nil;
    NSNumber* slot = nil;

    NSString* protoName = carrier.protocolConstraint;
    if (protoName.length > 0)
        {
        // Protocol receiver: the signature comes from the protocol, and the
        // slot is the protocol's — the impl is whatever the runtime class
        // put there (possibly nothing, for an optional method).
        XTProtocolDeclNode* proto = self.protocolsByName[protoName];
        if (!proto)
            return NO;
        for (XTMethodDeclNode* pm in proto.methods)
            {
            if ([pm.methodName isEqualToString:ma.memberName])
                {
                m = pm;
                break;
                }
            }
        if (!m)
            return NO;
        slot = self.protocolMethodSlots[protoName][ma.memberName];
        ma.resolvedBoundProtocol = protoName;
        NSUInteger pi = 0;
        for (XTMethodDeclNode* pm in proto.methods)
            {
            if ([pm.methodName isEqualToString:ma.memberName])
                {
                ma.resolvedBoundProtoIndex = @(pi);
                break;
                }
            pi++;
            }
        }
    else
        {
        // Concrete class receiver: walk self-and-ancestors for the method.
        XTClassDeclNode* cls = self.classesByName[carrier.displayName];
        if (!cls)
            return NO;
        for (XTClassDeclNode* c = cls; c != nil && !m; c = c.parentClass)
            {
            for (XTMethodDeclNode* cm in c.methods)
                {
                if (cm.isStatic)
                    continue;
                if ([cm.methodName isEqualToString:ma.memberName])
                    {
                    m = cm;
                    implClass = c.className;
                    break;
                    }
                }
            }
        if (!m)
            return NO; // not a method — probably an ivar; let `&` handle it
        // A slot only exists if the method is an override root (or a protocol
        // requirement). No slot → the `^` binds the symbol directly.
        NSString* label = [NSString stringWithFormat:@"_cls_%@_%@",
                                                     implClass, (m.mangledName ?: m.methodName)];
        slot = self->_virtualSlotByLabel[label];
        }

    // The `^`'s signature is the method's, WITHOUT the implicit self — self
    // rides in the `recv` word and is prepended again at the call.
    NSMutableArray<XTType*>* ptypes = [NSMutableArray array];
    for (XTParamNode* p in m.parameters)
        [ptypes addObject:p.paramType];
    XTFunctionType* fn = [XTFunctionType
        functionWithReturnTypes:(m.returnTypes ?: @[ [XTType voidType] ])
                     paramTypes:ptypes
                      isVarArgs:m.isVarArgs];

    ma.resolvedBoundMethod = m;
    ma.resolvedBoundClass = implClass;
    ma.resolvedBoundSlot = slot;
    // §4.2: a category method on an imported class has a chain slot instead. It
    // must NOT fall through to the direct-symbol path — that would bind the
    // extended class's body into the `^` and ignore a subclass override, which
    // is precisely what the chain exists to prevent.
    if (!slot && implClass.length)
        {
        NSString* lbl = [NSString stringWithFormat:@"_cls_%@_%@",
                                                   implClass, (m.mangledName ?: m.methodName)];
        ma.resolvedBoundChainSlot = self->_chainSlotByLabel[lbl];
        ma.resolvedBoundChainHost = self->_chainHostByLabel[lbl];
        if (ma.resolvedBoundChainHost.length)
            ma.resolvedBoundChainAnchor =
                self->_chainAnchorByHost[ma.resolvedBoundChainHost];
        }
    ma.resolvedType = [self boundMethodTypeForSignature:fn];
    node.resolvedType = ma.resolvedType;
    return YES;
    }

- (void)visitUnaryExpr:(XTUnaryExprNode*)node
    {
    // `&obj.method` — a bound method reference. Must be tried BEFORE the
    // operand is analysed: for a zero-arg method the property-getter rewrite
    // would read `obj.method` as a CALL, making `&obj.method` the address of
    // the result rather than a reference to the method.
    if (node.op == XTUnaryOpAddrOf &&
        [node.operand isKindOfClass:[XTMemberAccessNode class]] &&
        [self analyzeBoundMethodRef:node])
        {
        return;
        }
    [self analyzeNode:node.operand];
    XTType* ot = node.operand.resolvedType;
    switch (node.op)
        {
    case XTUnaryOpNeg:
        {
        // Negating a literal: pick the narrowest signed type that
        // fits the negated value. Without this, `-200` inherits
        // the `u8` type of the literal 200, the compiler stores
        // only the low byte ($38) and downstream sign-extension
        // code sees a positive value. Same for `-5` (fits i8) vs
        // `-300` (needs i16) vs `-40000` (needs i32).
        // Literal operands: pick the narrowest signed type that
        // fits the negated value.
        if ([node.operand isKindOfClass:[XTLiteralIntNode class]])
            {
            int64_t v = -((XTLiteralIntNode*)node.operand).intValue;
            if (v >= -128)
                node.resolvedType = [XTType i8Type];
            else if (v >= -32768)
                node.resolvedType = [XTType i16Type];
            else if (v >= INT32_MIN)
                node.resolvedType = [XTType i32Type];
            // Below INT32_MIN this used to stop at i32, so `-1747915140643999929`
            // lowered as `%:I32 = Neg %:U64` — a 64-bit operand with a 32-bit
            // result. Every backend mis-handled it differently (arm64 emitted
            // `neg w10, x10` and its assembler rejected the pair; xt6502 and
            // m68k each printed a different truncation; wasm32 built an
            // invalid module), which is what made it look like four bugs.
            // The self-hosted sema (selfhost/sema/Types.xc, forValue) has had
            // this rung all along — this is the reference compiler catching up.
            else
                node.resolvedType = [XTType i64Type];
            break;
            }
        // Non-literal operands: same width but signed when the
        // input was unsigned. The legacy AST codegen relied on
        // `emitWideStoreExtensionForRHS` to sign-extend at the
        // store site, but the new-IR coerceValue picks SExt vs
        // ZExt off the value's IR signedness — and an unsigned
        // result from `-x` for unsigned `x` ZExt-widens to the
        // destination, dropping the sign bit (stale_x T6:
        // `i16 s = -(5+3);` stored `$00F8 = 248` instead of
        // `$FFF8 = -8` because `(5+3)` is `u8`, so `-(5+3)` was
        // typed `u8` too and i16-coerce ZExt'd it). Same width
        // (no information loss); concrete classes that want
        // unsigned wraparound use an explicit cast.
        if (ot && ot.isInteger && !ot.isSigned)
            {
            if (ot.byteWidth == 1)
                node.resolvedType = [XTType i8Type];
            else if (ot.byteWidth == 2)
                node.resolvedType = [XTType i16Type];
            else if (ot.byteWidth == 4)
                node.resolvedType = [XTType i32Type];
            else if (ot.byteWidth == 8)
                node.resolvedType = [XTType i64Type];
            else
                node.resolvedType = ot;
            break;
            }
        node.resolvedType = ot ?: [XTType i8Type];
        break;
        }
    case XTUnaryOpBitNot:
        node.resolvedType = ot ?: [XTType i8Type];
        break;
    case XTUnaryOpLogNot:
        node.resolvedType = [XTType boolType];
        break;
    case XTUnaryOpAddrOf:
        node.resolvedType = ot ? [XTPointerType pointerToType:ot] : [XTType pointerType];
        // Static-frame eligibility: taking the address of a
        // function (eg. `fp = &foo;`) means callers could dispatch
        // through that pointer to an unknown target. Record the
        // referenced function so the analyser can force its call
        // chain onto the xtc stack — the call graph is incomplete
        // for it. The check is conservative: we only flag when
        // the operand is a bare identifier resolving to a function
        // symbol, not an arbitrary expression (which wouldn't be
        // a static function target anyway).
        if ([node.operand isKindOfClass:[XTIdentifierNode class]])
            {
            NSString* ident = ((XTIdentifierNode*)node.operand).identName;
            XTSymbol* sym = [[self currentScope] lookupSymbol:ident];
            if (sym && sym.storageClass == XTStorageClassFunction)
                {
                NSString* key = sym.mangledName ?: ident;
                [self->_addressTakenFunctions addObject:
                                                  [@"_fn_" stringByAppendingString:key]];
                }
            }
        break;
    case XTUnaryOpDeref:
        if ([ot isKindOfClass:[XTPointerType class]])
            {
            node.resolvedType = ((XTPointerType*)ot).pointeeType;
            }
        else
            {
            // Dereferencing a SCALAR is nonsense, and used to resolve
            // silently to u8: the program compiled, then read whatever
            // address the value happened to hold and died. `*p.Real` —
            // C's `(*p).Real` with the parentheses lost — is the shape
            // that found it, and `.` auto-dereferences a pointer here, so
            // the correct spellings are `p.Real` or `(*p).Real` (bug 214).
            //
            // Scoped to the kinds that can NEVER be dereferenced. Pointer,
            // array, struct, enum, class, function, auto and void are left
            // exactly as they were: the opaque `pointer` type is kind
            // Pointer but not an XTPointerType, arrays decay, and an
            // unresolved `auto` must not be diagnosed before inference.
            // Integers included. Dereferencing one is the 6502
            // absolute-address idiom, but it is a SIX-THOUSAND-TWO
            // idiom: the only sites in the whole tree were two lines in
            // the near-duplicate 6502 Stdio.xc files, and weakening the
            // rule on all eight targets to carry them was the wrong
            // trade. Those two now say what they mean —
            // `*(main:u8*)screenPtr` — which is already the house style
            // three lines up in the same file
            // (`out = (main:u8*)XT_STDIO_FMT_BUF;`).
            //
            // So an address held in an integer is still writable; it just
            // has to be spelled as a pointer at the point of use. A bare
            // `*someInt` is a bug on every target, and that is what
            // `*p.Real` was.
            BOOL scalar = ot && (ot.kind == XTTypeKindI8 || ot.kind == XTTypeKindU8 || ot.kind == XTTypeKindI16 || ot.kind == XTTypeKindU16 || ot.kind == XTTypeKindI32 || ot.kind == XTTypeKindU32 || ot.kind == XTTypeKindI64 || ot.kind == XTTypeKindU64 || ot.kind == XTTypeKindBool || ot.kind == XTTypeKindFloat || ot.kind == XTTypeKindDouble);
            if (scalar)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"cannot dereference '%@' — it is not a pointer",
                                                          ot.displayName]
                                         at:node.location];
                }
            node.resolvedType = [XTType u8Type];
            }
        break;
    default:
        node.resolvedType = ot ?: [XTType u8Type];
        break;
        }
    }

/****************************************************************************\
|* Visit a postfix expression (++ / --): analyse the operand and inherit type.
|* @param node  The postfix expression node.
\****************************************************************************/
- (void)visitPostfixExpr:(XTPostfixExprNode*)node
    {
    [self analyzeNode:node.operand];
    node.resolvedType = node.operand.resolvedType ?: [XTType u8Type];
    }

/****************************************************************************\
|* Visit an assignment expression: analyse LHS and RHS, resolve to LHS type.
|* @param node  The assignment expression node.
\****************************************************************************/
- (void)visitAssignExpr:(XTAssignExprNode*)node
    {
    // Property-accessor feature: suppress the getter rewrite while
    // resolving the LHS — the LHS is a write target, not a read.
    BOOL prevLV = self.memberAccessAsLValue;
    self.memberAccessAsLValue = YES;
    [self analyzeNode:node.lhs];
    self.memberAccessAsLValue = prevLV;

    // Analyse the RHS first. We need a resolved type on it to
    // evaluate setter-candidate compatibility for the compound
    // desugar below.
    XTType* prev = self.expectedType;
    if (node.lhs.resolvedType)
        self.expectedType = node.lhs.resolvedType;
    [self analyzeNode:node.rhs];
    self.expectedType = prev;
    node.resolvedType = node.lhs.resolvedType ?: node.rhs.resolvedType ?
                                                                       : [XTType u8Type];

    // Unboxing: `v = arr.get(0);` where v is a primitive numeric
    // and the RHS resolved to a class pointer. Splice the
    // `((Number@)rhs).asXXX()` rewrite in so downstream codegen
    // sees a primitive expression. Only fires for the plain `=`
    // assignment — compound (`+=` etc) needs the full unboxed
    // value first, which the desugar branch below handles
    // separately when both LHS and RHS shapes line up.
    if (node.assignOp == XTAssignOpAssign &&
        [self canUnboxRhsType:node.rhs.resolvedType
                    toLhsType:node.lhs.resolvedType])
        {
        XTASTNode* unboxed = [self unboxRhs:node.rhs
                                  toLhsType:node.lhs.resolvedType];
        if (unboxed)
            {
            [node replaceRhs:unboxed];
            node.resolvedType = node.lhs.resolvedType;
            }
        }

    // Compound assignment against a class-member LHS with a
    // matching setter desugars into the plain form
    // `x.prop = x.prop OP v`. A fresh XTMemberAccessNode is
    // synthesised for the read side so the getter-stamp can fire
    // on it independently of the write-target node. The original
    // base expression is shared; it will be evaluated twice if the
    // setter actually exists. That matches C's evaluation rule for
    // compound LHSes and keeps the emission path simple — users
    // with side-effectful bases (e.g. `getBox().n += 1`) should
    // spell out the expansion explicitly.
    if (node.assignOp != XTAssignOpAssign &&
        [node.lhs isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* ma = (XTMemberAccessNode*)node.lhs;
        XTType* baseT = ma.base.resolvedType;
        if ([baseT isKindOfClass:[XTPointerType class]])
            {
            baseT = ((XTPointerType*)baseT).pointeeType;
            }
        if (baseT && baseT.kind == XTTypeKindClass)
            {
            XTClassDeclNode* cls = self.classesByName[baseT.displayName];
            NSString* setterName =
                cls ? [self propertySetterNameFor:ma.memberName] : nil;
            NSString* setterOwnerProbe = nil;
            XTMethodDeclNode* setterProbe =
                (cls && setterName)
                    ? [self setterMethodNamed:setterName
                                      inClass:cls
                               acceptingValue:node.rhs
                                ownerClassOut:&setterOwnerProbe]
                    : nil;
            (void)setterOwnerProbe;
            if (setterProbe)
                {
                XTBinaryOp binOp = XTBinaryOpAdd;
                BOOL mapped = YES;
                switch (node.assignOp)
                    {
                case XTAssignOpAdd:
                    binOp = XTBinaryOpAdd;
                    break;
                case XTAssignOpSub:
                    binOp = XTBinaryOpSub;
                    break;
                case XTAssignOpMul:
                    binOp = XTBinaryOpMul;
                    break;
                case XTAssignOpDiv:
                    binOp = XTBinaryOpDiv;
                    break;
                case XTAssignOpMod:
                    binOp = XTBinaryOpMod;
                    break;
                case XTAssignOpBitAnd:
                    binOp = XTBinaryOpBitAnd;
                    break;
                case XTAssignOpBitOr:
                    binOp = XTBinaryOpBitOr;
                    break;
                case XTAssignOpBitXor:
                    binOp = XTBinaryOpBitXor;
                    break;
                case XTAssignOpShl:
                    binOp = XTBinaryOpShl;
                    break;
                case XTAssignOpShr:
                    binOp = XTBinaryOpShr;
                    break;
                case XTAssignOpRol:
                    binOp = XTBinaryOpRol;
                    break;
                case XTAssignOpRor:
                    binOp = XTBinaryOpRor;
                    break;
                default:
                    mapped = NO;
                    break;
                    }
                if (mapped)
                    {
                    // Synthesise a fresh read-side member access;
                    // analyse it in non-LV context so the getter
                    // stamp fires. Then wrap it + the (already
                    // analysed) RHS in a binary expr, compute the
                    // widened result type by hand (skipping
                    // visitBinaryExpr to avoid re-visiting the
                    // RHS), and collapse the assign node.
                    XTMemberAccessNode* readSide =
                        [[XTMemberAccessNode alloc]
                            initWithBase:ma.base
                              memberName:ma.memberName
                                 isArrow:ma.isArrow
                                location:ma.location];
                    BOOL savedLV2 = self.memberAccessAsLValue;
                    self.memberAccessAsLValue = NO;
                    [self analyzeNode:readSide];
                    self.memberAccessAsLValue = savedLV2;
                    XTBinaryExprNode* bin =
                        [[XTBinaryExprNode alloc] initWithOp:binOp
                                                        left:readSide
                                                       right:node.rhs
                                                    location:node.location];
                    XTType* lt = readSide.resolvedType;
                    XTType* rt = node.rhs.resolvedType;
                    if (lt && rt)
                        {
                        bin.resolvedType = [XTType widenType:lt with:rt];
                        }
                    else
                        {
                        bin.resolvedType = lt ?: rt ?
                                                    : [XTType u8Type];
                        }
                    [node collapseToPlainAssignWithRhs:bin];
                    node.resolvedType = bin.resolvedType;
                    }
                }
            }
        }

    // If the LHS is a class-member access, look for a matching
    // `setName(T)` method on the class or an ancestor. A hit makes
    // this assignment route through the setter at codegen time:
    // the assign node carries the resolved method and the RHS is
    // passed as its single argument. Compound ops were desugared
    // above so we only get here with a plain `=`.
    if (node.assignOp == XTAssignOpAssign &&
        [node.lhs isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* ma = (XTMemberAccessNode*)node.lhs;
        XTType* baseT = ma.base.resolvedType;
        if ([baseT isKindOfClass:[XTPointerType class]])
            {
            baseT = ((XTPointerType*)baseT).pointeeType;
            }
        if (baseT && baseT.kind == XTTypeKindClass)
            {
            XTClassDeclNode* cls = self.classesByName[baseT.displayName];
            if (cls)
                {
                NSString* setterName =
                    [self propertySetterNameFor:ma.memberName];
                NSString* setterOwner = nil;
                XTMethodDeclNode* setter =
                    [self setterMethodNamed:setterName
                                    inClass:cls
                             acceptingValue:node.rhs
                              ownerClassOut:&setterOwner];
                if (setter)
                    {
                    node.resolvedSetterMethod = setter;
                    node.resolvedSetterName =
                        setter.mangledName ?: setter.methodName;
                    node.resolvedSetterClass = setterOwner;
                    node.resolvedType =
                        setter.returnTypes.firstObject ?: [XTType voidType];
                    }
                }
            }
        }

    // PR4: class-pointer assignment compatibility. RHS's class must
    // equal the LHS's class or be a (transitive) descendant of it.
    // Sema was silently permissive pre-PR4 because the pointee
    // `kind` bit matched for any two class pointers — that let
    // `Animal@ a = vehicle;` slip through and produce surprising
    // runtime behaviour. The `null` literal stays legal (rhs kind
    // is XTTypeKindPointer with a non-class pointee or a zero-
    // resolved bare literal) and non-class pointer traffic
    // bypasses the check.
    if (node.assignOp == XTAssignOpAssign)
        {
        [self checkClassPointerAssign:node.lhs.resolvedType
                              rhsType:node.rhs.resolvedType
                              rhsNode:node.rhs
                                 site:@"assignment"
                             location:node.location];
        }

    // Stage-2 CFA: `<fnptr> = &funcName;` — record funcName as a
    // possible target of any indirect call site inside the enclosing
    // function. Requires the LHS to resolve as pointer-to-function.
    NSString* targetLabel = [self addressTakenFunctionLabelFromNode:node.rhs];
    if (targetLabel && self.currentFunctionLabel)
        {
        XTType* lhsT = node.lhs.resolvedType;
        if ([lhsT isKindOfClass:[XTPointerType class]] &&
            [((XTPointerType*)lhsT).pointeeType isKindOfClass:[XTFunctionType class]])
            {
            [self recordIndirectCallTarget:targetLabel
                           forFromFunction:self.currentFunctionLabel];
            }
        }
    }

@end
