/****************************************************************************\
|* XTSemanticAnalyzer+GuardCheck.m
|*
|* `-Wunguarded-action` — a `^` called without having been tested since its
|* last assignment.
|*
|* WHY THIS IS A WARNING AND NOT A TYPE RULE
|* -----------------------------------------
|* A stored `^` never retains its receiver (private:docs/Design/bound-methods.md §6:
|* retain-by-default would refcount `.text` for a widened function, and would
|* close a cycle for the back-references that are almost every real `^`). What
|* makes that safe instead of a dangling pointer is AUTO-ZEROING: the slot is
|* linked into the receiver's chain and its code word is zeroed on dealloc, so
|* the `^` goes correctly falsy.
|*
|* Falsy — not harmless. Calling it anyway dispatches through a nulled receiver
|* and crashes, exactly as calling a null function pointer does. `if (f) f()` is
|* therefore the contract, and this warns where it is missing. It is the same
|* shape as a null-pointer check, so it is a warning rather than an error:
|* the programmer may know something we cannot see.
|*
|* THE PREDICATE
|* -------------
|* "Tested since its last assignment", NOT "syntactically test-then-call". The
|* natural spelling loads to a local first —
|*
|*     Cb^ f = x.cb;   if (f) { f(); }
|*
|* — and a syntactic rule would false-positive on exactly the idiom worth
|* recommending. So a binding becomes GUARDED when tested and stays guarded
|* until something assigns to it.
|*
|* Three things this gets right, all of which cost more than they look:
|*
|*   1. JOINS INTERSECT. A binding is guarded after an if/else only if it was
|*      guarded on BOTH paths. Union would suppress the warning on a path that
|*      was never guarded — a false negative, and the wrong direction to be
|*      wrong in for a safety warning.
|*   2. THE NEGATIVE SEED IS DIVERGENCE, NOT `return`. `if (!f) return;` is
|*      really "if (!f) <does not fall through>", so `throw`, `break` and
|*      `continue` seed it too. People write the guard-and-bail idiom all of
|*      those ways.
|*   3. ONLY A LOCAL BINDING IS TRACKED. `x.cb` is a field: any intervening
|*      call could reassign it, so proving it stays guarded needs alias
|*      analysis we do not have. Tracking names only means the analysis is
|*      exact on the load-to-local idiom and silent on field paths — which
|*      nudges toward the spelling that is also the one we can prove.
\****************************************************************************/
#import "XTSemanticAnalyzer+Private.h"

@implementation XTSemanticAnalyzer (GuardCheck)

/****************************************************************************\
|* Does this node name a local binding of `^` type? Returns its name, or nil.
\****************************************************************************/
- (nullable NSString*)gcBoundBindingName:(nullable XTASTNode*)n
    {
    if (!n || n.nodeKind != XTASTNodeKindIdentifier)
        return nil;
    XTIdentifierNode* id_ = (XTIdentifierNode*)n;
    if (!id_.resolvedType || id_.resolvedType.boundMethodSignature == nil)
        return nil;
    return id_.identName;
    }

/****************************************************************************\
|* The binding a condition proves NON-NULL when taken, e.g. `f`, `f != 0`.
|* Strip a cast so `if ((Cb^)f)` reads the same as `if (f)`.
\****************************************************************************/
- (nullable NSString*)gcTruthyBinding:(nullable XTASTNode*)cond
    {
    if (!cond)
        return nil;
    if (cond.nodeKind == XTASTNodeKindCastExpr)
        return [self gcTruthyBinding:((XTCastExprNode*)cond).operand];
    NSString* direct = [self gcBoundBindingName:cond];
    if (direct)
        return direct;
    if (cond.nodeKind == XTASTNodeKindBinaryExpr)
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)cond;
        // `f != 0` proves it; `f == 0` does not (that is the negative form).
        if (b.op == XTBinaryOpNeq)
            {
            NSString* l = [self gcBoundBindingName:b.left];
            if (l && [self gcIsNullLiteral:b.right])
                return l;
            NSString* r = [self gcBoundBindingName:b.right];
            if (r && [self gcIsNullLiteral:b.left])
                return r;
            }
        // `a && b` — both halves hold on the taken path.
        if (b.op == XTBinaryOpLogAnd)
            {
            NSString* l = [self gcTruthyBinding:b.left];
            if (l)
                return l;
            return [self gcTruthyBinding:b.right];
            }
        }
    return nil;
    }

/****************************************************************************\
|* The binding a condition proves NULL when taken: `!f`, `f == 0`. Paired with
|* a diverging body this is the guard-and-bail idiom, and what it proves is
|* about the code AFTER the `if`.
\****************************************************************************/
- (nullable NSString*)gcFalsyBinding:(nullable XTASTNode*)cond
    {
    if (!cond)
        return nil;
    if (cond.nodeKind == XTASTNodeKindCastExpr)
        return [self gcFalsyBinding:((XTCastExprNode*)cond).operand];
    if (cond.nodeKind == XTASTNodeKindUnaryExpr)
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)cond;
        if (u.op == XTUnaryOpLogNot)
            return [self gcTruthyBinding:u.operand];
        }
    if (cond.nodeKind == XTASTNodeKindBinaryExpr)
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)cond;
        if (b.op == XTBinaryOpEq)
            {
            NSString* l = [self gcBoundBindingName:b.left];
            if (l && [self gcIsNullLiteral:b.right])
                return l;
            NSString* r = [self gcBoundBindingName:b.right];
            if (r && [self gcIsNullLiteral:b.left])
                return r;
            }
        }
    return nil;
    }

- (BOOL)gcIsNullLiteral:(nullable XTASTNode*)n
    {
    if (!n)
        return NO;
    if (n.nodeKind == XTASTNodeKindCastExpr)
        return [self gcIsNullLiteral:((XTCastExprNode*)n).operand];
    if (n.nodeKind != XTASTNodeKindLiteralInt)
        return NO;
    return ((XTLiteralIntNode*)n).intValue == 0;
    }

/****************************************************************************\
|* Walk an EXPRESSION: warn at an unguarded bound call, and drop a binding's
|* guarded bit where it is assigned. Arguments are walked too — a call can
|* appear anywhere, including inside another call's argument list.
\****************************************************************************/
- (void)gcWalkExpr:(nullable XTASTNode*)n guarded:(NSMutableSet<NSString*>*)g
    {
    if (!n)
        return;
    switch (n.nodeKind)
        {
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* c = (XTCallExprNode*)n;
        for (XTASTNode* a in c.arguments)
            [self gcWalkExpr:a guarded:g];
        if (c.isBoundCall && c.calleeName.length && ![g containsObject:c.calleeName])
            {
            [self.diagnostics emitWarning:
                                  [NSString stringWithFormat:
                                                @"`%@` is a callback and is called without being checked — "
                                                @"it empties when its receiver dies, and calling it then "
                                                @"dispatches through a dead object. Guard it: "
                                                @"`if (%@) { %@(…); }`",
                                                c.calleeName, c.calleeName, c.calleeName]
                                 category:XTWarnUnguardedAction
                                       at:n.location];
            }
        return;
        }
    case XTASTNodeKindAssignExpr:
        {
        XTAssignExprNode* a = (XTAssignExprNode*)n;
        [self gcWalkExpr:a.rhs guarded:g];
        // The new value is unproven whatever the old one was.
        NSString* dst = [self gcBoundBindingName:a.lhs];
        if (dst)
            [g removeObject:dst];
        else
            [self gcWalkExpr:a.lhs guarded:g];
        return;
        }
    case XTASTNodeKindBinaryExpr:
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)n;
        [self gcWalkExpr:b.left guarded:g];
        // `f && f()` is a guard: the right side runs only if the left held.
        if (b.op == XTBinaryOpLogAnd)
            {
            NSString* t = [self gcTruthyBinding:b.left];
            if (t)
                {
                NSMutableSet* inner = [g mutableCopy];
                [inner addObject:t];
                [self gcWalkExpr:b.right guarded:inner];
                return;
                }
            }
        [self gcWalkExpr:b.right guarded:g];
        return;
        }
    case XTASTNodeKindTernaryExpr:
        {
        // `f ? f() : 0` guards its then-arm the same way.
        XTTernaryExprNode* t = (XTTernaryExprNode*)n;
        [self gcWalkExpr:t.condition guarded:g];
        NSString* tb = [self gcTruthyBinding:t.condition];
        NSMutableSet* thenG = tb ? [g mutableCopy] : g;
        if (tb)
            [thenG addObject:tb];
        [self gcWalkExpr:t.thenExpr guarded:thenG];
        [self gcWalkExpr:t.elseExpr guarded:g];
        return;
        }
    default:
        break;
        }
    for (XTASTNode* kid in [self gcChildrenOf:n])
        [self gcWalkExpr:kid guarded:g];
    }

/****************************************************************************\
|* The sub-expressions worth descending into. Deliberately a short list: this
|* pass only has to find calls and assignments, and an unknown node shape
|* costing a missed warning is better than one costing a wrong warning.
\****************************************************************************/
- (NSArray<XTASTNode*>*)gcChildrenOf:(XTASTNode*)n
    {
    NSMutableArray* out = [NSMutableArray array];
    switch (n.nodeKind)
        {
    case XTASTNodeKindUnaryExpr:
        [out addObject:((XTUnaryExprNode*)n).operand];
        break;
    case XTASTNodeKindCastExpr:
        [out addObject:((XTCastExprNode*)n).operand];
        break;
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)n;
        if (m.receiver)
            [out addObject:m.receiver];
        for (XTASTNode* a in m.arguments)
            [out addObject:a];
        break;
        }
    default:
        break;
        }
    return out;
    }

/****************************************************************************\
|* Walk a STATEMENT. Returns YES when control cannot fall out of it — which is
|* what makes `if (!f) return;` seed the guard for everything after the `if`.
\****************************************************************************/
- (BOOL)gcWalkStmt:(nullable XTASTNode*)n guarded:(NSMutableSet<NSString*>*)g
    {
    if (!n)
        return NO;
    switch (n.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        for (XTASTNode* s in ((XTBlockNode*)n).statements)
            if ([self gcWalkStmt:s guarded:g])
                return YES; // rest unreachable
        return NO;
        }
    case XTASTNodeKindReturn:
        for (XTASTNode* v in ((XTReturnNode*)n).values)
            [self gcWalkExpr:v guarded:g];
        return YES;
    case XTASTNodeKindBreak:
    case XTASTNodeKindContinue:
        return YES;
    case XTASTNodeKindIf:
        {
        XTIfNode* f = (XTIfNode*)n;
        [self gcWalkExpr:f.condition guarded:g];
        NSString* truthy = [self gcTruthyBinding:f.condition];
        NSString* falsy = [self gcFalsyBinding:f.condition];

        NSMutableSet* thenG = [g mutableCopy];
        if (truthy)
            [thenG addObject:truthy];
        BOOL thenDiverges = [self gcWalkStmt:f.thenBlock guarded:thenG];

        NSMutableSet* elseG = [g mutableCopy];
        if (falsy)
            [elseG addObject:falsy]; // else-of-`!f` proves f
        BOOL elseDiverges = f.elseBlock
                                ? [self gcWalkStmt:f.elseBlock guarded:elseG]
                                : NO;

        if (thenDiverges && elseDiverges)
            return YES;
        // JOIN. Guarded after only if guarded on every path that reaches
        // here — intersection, not union. A diverging arm contributes
        // nothing, which is exactly how `if (!f) return;` promotes f.
        NSMutableSet* out = nil;
        if (thenDiverges)
            out = elseG;
        else if (elseDiverges)
            out = thenG;
        else
            {
            out = [thenG mutableCopy];
            [out intersectSet:elseG];
            }
        [g setSet:out];
        return NO;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)n;
        [self gcWalkExpr:w.condition guarded:g];
        NSString* truthy = [self gcTruthyBinding:w.condition];
        NSMutableSet* bodyG = [g mutableCopy];
        if (truthy)
            [bodyG addObject:truthy];
        [self gcWalkStmt:w.body guarded:bodyG];
        // The body may not run, and may assign — nothing it proves escapes.
        return NO;
        }
    case XTASTNodeKindExprStatement:
        [self gcWalkExpr:((XTExpressionStatementNode*)n).expression guarded:g];
        return NO;
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)n;
        [self gcWalkStmt:f.loopInit guarded:g];
        [self gcWalkExpr:f.condition guarded:g];
        NSMutableSet* bodyG = [g mutableCopy];
        [self gcWalkStmt:f.body guarded:bodyG];
        [self gcWalkExpr:f.increment guarded:bodyG];
        return NO; // may not run; proves nothing after
        }
    case XTASTNodeKindForIn:
        {
        NSMutableSet* bodyG = [g mutableCopy];
        [self gcWalkStmt:((XTForInNode*)n).body guarded:bodyG];
        return NO;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* v = (XTVariableDeclNode*)n;
        [self gcWalkExpr:v.initialiser guarded:g];
        // A redeclaration rebinds the name: whatever was proved is stale.
        if (v.varName)
            [g removeObject:v.varName];
        return NO;
        }
    default:
        // Anything else (switch, asm, delete…) proves nothing and is not
        // descended into. Conservative in the SAFE direction: it can only
        // cost a warning we did not emit, never produce a wrong one.
        return NO;
        }
    }

/****************************************************************************\
|* Entry point — one walk per function body, starting with nothing proved.
\****************************************************************************/
- (void)runGuardCheckOnBody:(XTASTNode*)body
    {
    if (!body)
        return;
    [self gcWalkStmt:body guarded:[NSMutableSet set]];
    }

@end
