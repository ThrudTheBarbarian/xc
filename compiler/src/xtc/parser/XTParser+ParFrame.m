/****************************************************************************\
|* XTParser+ParFrame.m
|*
|* The par frame walk (#338): a par body's frame, computed from its tree once
|* it is parsed: the captures, their types and bases in first-use order
|* (which sets the block's field layout), the globals the body names, the
|* names it assigns, and its uses of each name, as subscript bases and as
|* array updates, whether it can leave an iteration early, and which `par.x`
|* names a grid body reads. The walk visits the tree in the order the parser
|* read it, and binds the body's declarations as the parser did, in scopes
|* pushed on blkScopes above the frame's depth, so a name resolves as it did
|* where it was used. A block literal or a nested par block in the body is
|* read through the site the parser registered for it (pfwRegister): its
|* body counts toward the uses, and the names its site passes in are uses at
|* the site. What cannot be captured is still said where it is used
|* (blkNoteIdentifierUse, blkNoteBareCall), among the parse's other errors.
|* Mirrored in the port (Parser.xc, parFrameWalk).
\****************************************************************************/
#import "XTParser+Private.h"

NS_ASSUME_NONNULL_BEGIN

@implementation XTParser (ParFrame)

/****************************************************************************\
|* A literal's mk call (kind 0), or a nested written (1) or automatic (2) par
|* block's site, with the body the parser read for it, the literal's
|* parameters, the names the site noted, and for an automatic block the loop
|* as written. Only inside a par body, whose walk reads it.
\****************************************************************************/
- (void)pfwRegister:(nullable XTASTNode*)site
               body:(nullable XTASTNode*)body
             params:(nullable NSArray<XTParamNode*>*)params
              noted:(nullable NSArray<NSString*>*)noted
               kind:(NSUInteger)kind
              plain:(nullable XTASTNode*)plain
    {
    if (!site || !body)
        return;
    if (kind == 0)
        [self plRegister:site entry:@{ @"kind" : @(kind), @"body" : body, @"params" : params ?: @[] }];
    BOOL inPar = NO;
    for (NSDictionary* f in [self blkFrames])
        if ([f[@"par"] boolValue])
            inPar = YES;
    if (!inPar)
        return;
    if (!self.pfwSites)
        self.pfwSites = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                              valueOptions:NSPointerFunctionsStrongMemory];
    NSMutableDictionary* e = [NSMutableDictionary dictionary];
    e[@"body"] = body;
    e[@"params"] = params ?: @[];
    e[@"noted"] = noted ? [noted copy] : @[];
    e[@"kind"] = @(kind);
    if (plain)
        e[@"plain"] = plain;
    [self.pfwSites setObject:e forKey:site];
    }

/****************************************************************************\
|* The frame of `body`, a par body (a block) or a lifted loop, parsed in
|* `frame`: names, types, bases, wb, outer, written, refs, subBase,
|* memWritten, updates, exits and gridUsed.
\****************************************************************************/
- (NSMutableDictionary*)parFrameWalk:(XTASTNode*)body frame:(NSDictionary*)frame
    {
    NSMutableDictionary* w = [NSMutableDictionary dictionary];
    w[@"depth"] = frame[@"depth"];
    w[@"names"] = [NSMutableArray array];
    w[@"types"] = [NSMutableDictionary dictionary];
    w[@"bases"] = [NSMutableDictionary dictionary];
    w[@"wb"] = [NSMutableSet set];
    w[@"written"] = [NSMutableSet set];
    if (frame[@"grid"])
        w[@"gridUsed"] = [NSMutableSet set];
    NSMutableDictionary* savedW = self.pfw;
    BOOL savedTop = self.pfwTop;
    self.pfw = w;
    self.pfwTop = YES;
    [self blkPushScope];
    [self pfwNode:body];
    [self blkPopScope];
    self.pfw = savedW;
    self.pfwTop = savedTop;
    return w;
    }

- (void)pfwNodes:(nullable NSArray<XTASTNode*>*)nodes
    {
    for (XTASTNode* n in nodes)
        [self pfwNode:n];
    }

- (void)pfwNode:(nullable XTASTNode*)n
    {
    if (!n)
        return;
    if ([n isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* name = ((XTIdentifierNode*)n).identName;
        if (n.srcFacts & XTSrcSynth)
            [self pfwGridName:name];
        else
            [self pfwUse:name];
        return;
        }
    if (n.srcFacts & XTSrcSynth)
        return;
    NSDictionary* site = self.pfwSites ? [self.pfwSites objectForKey:n] : nil;
    if (site)
        {
        [self pfwSite:n entry:site];
        return;
        }
    if ([n isKindOfClass:[XTBlockNode class]])
        {
        XTBlockNode* b = (XTBlockNode*)n;
        if (b.isDeclList)
            {
            [self pfwNodes:b.statements];
            return;
            }
        [self blkPushScope];
        [self pfwNodes:b.statements];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTVariableDeclNode class]])
        {
        // Bound once its initialiser (or constructor arguments) is read.
        XTVariableDeclNode* d = (XTVariableDeclNode*)n;
        [self pfwNode:d.initialiser];
        [self pfwNodes:d.constructorArgs];
        [self blkBind:d.varName type:d.declaredType];
        if (!d.declaredType || d.declaredType.kind == XTTypeKindAuto)
            [self blkBindAuto:d.varName fromInit:d.initialiser];
        return;
        }
    if ([n isKindOfClass:[XTForCStyleNode class]])
        {
        XTForCStyleNode* f = (XTForCStyleNode*)n;
        XTVariableDeclNode* d = [f.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopInit : nil;
        if (f.srcFacts & XTSrcRange)
            {
            // A range: its bounds, then the body with the variable bound; the
            // condition's and the step's use of the variable are the parser's.
            [self pfwNode:d.initialiser];
            if ([f.condition isKindOfClass:[XTBinaryExprNode class]])
                [self pfwNode:((XTBinaryExprNode*)f.condition).right];
            [self blkPushScope];
            if (d)
                [self blkBind:d.varName type:d.declaredType];
            [self pfwNode:f.body];
            [self blkPopScope];
            return;
            }
        // The variable is bound from the condition on (parseFor).
        if (d)
            [self pfwNode:d.initialiser];
        else
            [self pfwNode:f.loopInit];
        [self blkPushScope];
        if (d)
            [self blkBind:d.varName type:d.declaredType];
        [self pfwNode:f.condition];
        [self pfwNode:f.increment];
        [self pfwNode:f.body];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)n;
        [self pfwNode:f.collection];
        [self blkPushScope];
        if ([f.loopVar isKindOfClass:[XTVariableDeclNode class]])
            {
            XTVariableDeclNode* v = (XTVariableDeclNode*)f.loopVar;
            [self blkBind:v.varName type:v.declaredType];
            }
        [self pfwNode:f.body];
        [self blkPopScope];
        return;
        }
    if ([n isKindOfClass:[XTTupleAssignNode class]])
        {
        // The value, then the declared targets are bound; a bare target is
        // read as a token, not as a name.
        XTTupleAssignNode* t = (XTTupleAssignNode*)n;
        [self pfwNode:t.sourceExpr];
        for (XTASTNode* d in t.targets)
            if ([d isKindOfClass:[XTVariableDeclNode class]])
                [self blkBind:((XTVariableDeclNode*)d).varName type:((XTVariableDeclNode*)d).declaredType];
        return;
        }
    if ([n isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)n;
        [self pfwNode:a.lhs];
        [self pfwNode:a.rhs];
        [self pfwWrite:a.lhs];
        [self pfwUpdate:a.lhs op:a.assignOp rhs:a.rhs];
        return;
        }
    if ([n isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)n;
        [self pfwNode:u.operand];
        if (u.op == XTUnaryOpAddrOf)
            [self pfwMemWrite:u.operand];
        if (u.op == XTUnaryOpPreInc || u.op == XTUnaryOpPreDec)
            [self pfwWrite:u.operand];
        return;
        }
    if ([n isKindOfClass:[XTPostfixExprNode class]])
        {
        XTPostfixExprNode* p = (XTPostfixExprNode*)n;
        [self pfwNode:p.operand];
        [self pfwWrite:p.operand];
        if (p.postfixOp == XTPostfixOpInc)
            [self pfwUpdate:p.operand op:XTAssignOpAdd rhs:nil];
        return;
        }
    if ([n isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)n;
        [self pfwNode:s.base];
        [self pfwNode:s.index];
        if ([s.base isKindOfClass:[XTIdentifierNode class]])
            [self pfwCount:@"subBase" name:((XTIdentifierNode*)s.base).identName by:1];
        return;
        }
    if ([n isKindOfClass:[XTSliceExprNode class]])
        {
        XTSliceExprNode* s = (XTSliceExprNode*)n;
        [self pfwNode:s.base];
        [self pfwNode:s.startExpr];
        [self pfwNode:s.endExpr];
        return;
        }
    if ([n isKindOfClass:[XTCallExprNode class]])
        {
        // A callee that is not a name, read first. A name read as a name
        // (`(f)(x)`, or `delete(…)`) is a use before the arguments; a name
        // called as it is written is a use after them when it is a local or
        // a parameter (#437).
        XTCallExprNode* c = (XTCallExprNode*)n;
        if (c.calleeExpr)
            {
            [self pfwNode:c.calleeExpr];
            [self pfwNodes:c.arguments];
            return;
            }
        NSString* callee = c.calleeName;
        BOOL asName = (c.srcFacts & XTSrcParenCallee) || [callee isEqualToString:@"delete"] ||
                      [callee isEqualToString:@"retain"] || [callee isEqualToString:@"release"];
        if (asName)
            [self pfwUse:callee];
        [self pfwNodes:c.arguments];
        NSUInteger depth = 0;
        if (!asName && [self blkLookup:callee depth:&depth])
            [self pfwUse:callee];
        return;
        }
    if ([n isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)n;
        if (m.srcFacts & XTSrcCalled)
            {
            // `b(…)` through a block binding: a use of b after the arguments.
            // A named literal calling itself is `self.invoke(…)`, no use.
            [self pfwNodes:m.arguments];
            if ([m.receiver isKindOfClass:[XTIdentifierNode class]] &&
                ![((XTIdentifierNode*)m.receiver).identName isEqualToString:@"self"])
                [self pfwUse:((XTIdentifierNode*)m.receiver).identName];
            return;
            }
        [self pfwNode:m.receiver];
        [self pfwNodes:m.arguments];
        return;
        }
    if ([n isKindOfClass:[XTMemberAccessNode class]])
        {
        [self pfwNode:((XTMemberAccessNode*)n).base];
        return;
        }
    if ([n isKindOfClass:[XTBinaryExprNode class]])
        {
        [self pfwNode:((XTBinaryExprNode*)n).left];
        [self pfwNode:((XTBinaryExprNode*)n).right];
        return;
        }
    if ([n isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)n;
        [self pfwNode:t.condition];
        [self pfwNode:t.thenExpr];
        [self pfwNode:t.elseExpr];
        return;
        }
    if ([n isKindOfClass:[XTCastExprNode class]])
        {
        [self pfwNode:((XTCastExprNode*)n).operand];
        return;
        }
    if ([n isKindOfClass:[XTRangeExprNode class]])
        {
        [self pfwNode:((XTRangeExprNode*)n).startExpr];
        [self pfwNode:((XTRangeExprNode*)n).endExpr];
        return;
        }
    if ([n isKindOfClass:[XTNewExprNode class]])
        {
        XTNewExprNode* e = (XTNewExprNode*)n;
        [self pfwNode:e.countExpr];
        [self pfwNodes:e.arguments];
        return;
        }
    if ([n isKindOfClass:[XTSizeofExprNode class]])
        {
        id o = ((XTSizeofExprNode*)n).operand;
        if ([o isKindOfClass:[XTASTNode class]])
            [self pfwNode:o];
        return;
        }
    if ([n isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* i = (XTIfNode*)n;
        [self pfwNode:i.condition];
        [self pfwNode:i.thenBlock];
        [self pfwNode:i.elseBlock];
        return;
        }
    if ([n isKindOfClass:[XTWhileNode class]])
        {
        [self pfwNode:((XTWhileNode*)n).condition];
        [self pfwNode:((XTWhileNode*)n).body];
        return;
        }
    if ([n isKindOfClass:[XTReturnNode class]])
        {
        self.pfw[@"exits"] = @YES;
        [self pfwNodes:((XTReturnNode*)n).values];
        return;
        }
    if ([n isKindOfClass:[XTBreakNode class]] || [n isKindOfClass:[XTContinueNode class]])
        {
        self.pfw[@"exits"] = @YES;
        return;
        }
    if ([n isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self pfwNode:((XTExpressionStatementNode*)n).expression];
        return;
        }
    if ([n isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* s = (XTSwitchNode*)n;
        [self pfwNode:s.subject];
        for (XTSwitchCase* c in s.cases)
            {
            for (XTCaseLabel* l in c.labels)
                {
                [self pfwNode:l.singleValue];
                [self pfwNode:l.rangeLo];
                [self pfwNode:l.rangeHi];
                }
            [self pfwNodes:c.body];
            }
        return;
        }
    if ([n isKindOfClass:[XTDeferNode class]])
        {
        [self pfwNode:((XTDeferNode*)n).body];
        return;
        }
    if ([n isKindOfClass:[XTThrowNode class]])
        {
        [self pfwNode:((XTThrowNode*)n).operand];
        return;
        }
    if ([n isKindOfClass:[XTTryNode class]])
        {
        XTTryNode* t = (XTTryNode*)n;
        [self pfwNode:t.tryBlock];
        for (XTCatchClause* c in t.catchClauses)
            [self pfwNode:c.block];
        return;
        }
    if ([n isKindOfClass:[XTDeleteNode class]])
        {
        [self pfwNode:((XTDeleteNode*)n).operand];
        return;
        }
    }

/****************************************************************************\
|* A literal or a nested block, read as the parser read it: an automatic
|* block's loop as written first (parsed before the block), the body in its
|* own frame, then the names its site passes in.
\****************************************************************************/
- (void)pfwSite:(XTASTNode*)n entry:(NSDictionary*)e
    {
    NSUInteger kind = [e[@"kind"] unsignedIntegerValue];
    if (kind == 2)
        [self pfwNode:e[@"plain"]];
    BOOL savedTop = self.pfwTop;
    self.pfwTop = NO;
    [self blkPushScope];
    for (XTParamNode* p in e[@"params"])
        [self blkBind:p.paramName type:p.paramType];
    [self pfwNode:e[@"body"]];
    [self blkPopScope];
    self.pfwTop = savedTop;
    if (kind == 0)
        {
        // The mk call: its class reference and write-back slots are the
        // parser's, its capture arguments uses.
        [self pfwNodes:((XTMethodCallExprNode*)n).arguments];
        return;
        }
    for (NSString* name in e[@"noted"])
        [self pfwUse:name];
    }

- (void)pfwCount:(NSString*)key name:(NSString*)name by:(NSUInteger)by
    {
    NSMutableDictionary* m = self.pfw[key];
    if (!m)
        self.pfw[key] = m = [NSMutableDictionary dictionary];
    m[name] = @([m[name] unsignedIntegerValue] + by);
    }

/****************************************************************************\
|* A use of a name: counted, and at the body's own level a capture when it
|* resolves outside the body, or a global when it resolves nowhere.
\****************************************************************************/
- (void)pfwUse:(NSString*)name
    {
    [self pfwCount:@"refs" name:name by:1];
    if (!self.pfwTop)
        return;
    NSUInteger foundDepth = 0;
    NSDictionary* info = [self blkLookup:name depth:&foundDepth];
    if (!info)
        {
        NSMutableArray* outer = self.pfw[@"outer"];
        if (!outer)
            self.pfw[@"outer"] = outer = [NSMutableArray array];
        if (![outer containsObject:name])
            [outer addObject:name];
        return;
        }
    if (foundDepth >= [self.pfw[@"depth"] unsignedIntegerValue])
        return;
    NSMutableArray* names = self.pfw[@"names"];
    if ([names containsObject:name])
        return;
    id ty = info[@"type"];
    if (ty == [NSNull null])
        return;
    if ([info[@"wb"] boolValue])
        {
        // The frame itself is off the stack by now: any frame left is one
        // the block sits in.
        if ([self blkFrames].count > 0)
            return;
        [self.pfw[@"wb"] addObject:name];
        }
    [names addObject:name];
    self.pfw[@"types"][name] = ty;
    if (info[@"base"])
        self.pfw[@"bases"][name] = info[@"base"];
    }

// `par.x` … in a `par :grid` body, which the parser reads as these names.
- (void)pfwGridName:(NSString*)name
    {
    NSMutableSet* used = self.pfw[@"gridUsed"];
    if (!self.pfwTop || !used)
        return;
    if ([@[ @"par$x", @"par$y", @"par$z", @"par$w", @"par$h", @"par$d" ] containsObject:name])
        [used addObject:name];
    }

// An assignment's target: a name the body writes, or an element or field of
// the array or struct it is rooted at (memWritten).
- (void)pfwWrite:(nullable XTASTNode*)t
    {
    [self pfwMemWrite:t];
    if (self.pfwTop && [t isKindOfClass:[XTIdentifierNode class]])
        [self.pfw[@"written"] addObject:((XTIdentifierNode*)t).identName];
    }

- (void)pfwMemWrite:(nullable XTASTNode*)t
    {
    if (!t || [t isKindOfClass:[XTIdentifierNode class]])
        return;
    NSString* root = parRootName(t);
    if (!root)
        return;
    NSMutableSet* mw = self.pfw[@"memWritten"];
    if (!mw)
        self.pfw[@"memWritten"] = mw = [NSMutableSet set];
    [mw addObject:root];
    }

- (void)pfwUpdate:(nullable XTASTNode*)t op:(XTAssignOp)aop rhs:(nullable XTASTNode*)rhs
    {
    NSUInteger uses = 0;
    NSString* key = parUpdateKey(t, aop, rhs, &uses);
    if (key)
        [self pfwCount:@"updates" name:key by:uses];
    }

/****************************************************************************\
|* The frame of a par body or a lifted loop parsed in `frame`, from its tree,
|* into `frame`, which parDesugarBody then reads.
\****************************************************************************/
- (void)parFrameFill:(NSMutableDictionary*)frame body:(nullable XTASTNode*)body
    {
    if (!body)
        return;
    NSDictionary* w = [self parFrameWalk:body frame:frame];
    for (NSString* k in w)
        if (![k isEqualToString:@"depth"])
            frame[k] = w[k];
    }

@end

NS_ASSUME_NONNULL_END
