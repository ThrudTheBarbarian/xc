/****************************************************************************\
|* XTSemanticAnalyzer+Operators.m
|*
|* A method becomes an operator by carrying `:operator(pattern)`, where the
|* pattern is the operator written with the method's own names: `self + o`,
|* `-self`, `k * v`. The parser records the pattern as a SHAPE, `_` for each
|* operand (`_+_`, `-_`), and the operand names in order. Here the pattern is
|* checked against its method, and each operator expression whose operand's
|* class defines that operator becomes a call of the chosen method.
|*
|* The rules (mirrored in the port, Sema.xc):
|*
|*   * An operator applies when an operand is a class instance (a pointer to
|*     one, or one by value) whose class or an ancestor defines that operator.
|*     Such a class gives up the built-in meaning of THAT operator for its
|*     pointers: an unmatched use is an error, never pointer arithmetic. A
|*     class with no operator keeps every built-in meaning.
|*   * Candidates: instance methods of the left operand's class (pattern
|*     `self OP _`), then static methods of either operand's class (`_ OP _`),
|*     each class walked up its parents, a nearer method hiding an ancestor's
|*     with the same parameter types. An override of an instance operator is
|*     the operator, with its pattern or without. They are scored as any
|*     call's candidates are; a tie between the best is an error naming both.
|*   * The chosen method is called as an ordinary method call, so dispatch is
|*     virtual where the call would be, and ARC treats its result as any
|*     call's result.
\****************************************************************************/
#import "XTSemanticAnalyzer+Private.h"

@implementation XTSemanticAnalyzer (Operators)

#pragma mark - Spellings

// The spelling of an overloadable binary operator, nil for one with a fixed
// meaning (`&&`, `||`, `==`, `!=`).
static NSString* XTOperatorBinarySpelling(XTBinaryOp op)
    {
    switch (op)
        {
    case XTBinaryOpAdd: return @"+";
    case XTBinaryOpSub: return @"-";
    case XTBinaryOpMul: return @"*";
    case XTBinaryOpDiv: return @"/";
    case XTBinaryOpMod: return @"%";
    case XTBinaryOpBitAnd: return @"&";
    case XTBinaryOpBitOr: return @"|";
    case XTBinaryOpBitXor: return @"^";
    case XTBinaryOpShl: return @"<<";
    case XTBinaryOpShr: return @">>";
    case XTBinaryOpRol: return @"<:";
    case XTBinaryOpRor: return @":>";
    case XTBinaryOpLt: return @"<";
    case XTBinaryOpGt: return @">";
    case XTBinaryOpLe: return @"<=";
    case XTBinaryOpGe: return @">=";
    default: return nil;
        }
    }

// The same for a prefix operator.
static NSString* XTOperatorUnarySpelling(XTUnaryOp op)
    {
    switch (op)
        {
    case XTUnaryOpNeg: return @"-";
    case XTUnaryOpPlus: return @"+";
    case XTUnaryOpBitNot: return @"~";
    case XTUnaryOpLogNot: return @"!";
    default: return nil;
        }
    }

// Compound assignments: `_+=_` and the rest. (`_<=_` and `_>=_` compare.)
static BOOL XTOperatorIsCompound(NSString* shape)
    {
    static NSSet<NSString*>* compound;
    if (!compound)
        compound = [NSSet setWithArray:@[ @"_+=_", @"_-=_", @"_*=_", @"_/=_", @"_%=_", @"_&=_", @"_|=_",
                                          @"_^=_", @"_<<=_", @"_>>=_", @"_<:=_", @"_:>=_" ]];
    return [compound containsObject:shape];
    }

// Index operators: `_[_]`, `_[_,_]`, `_[_.._]`, `_[_..._]`, and their set forms.
static BOOL XTOperatorIsIndex(NSString* shape)
    {
    return [shape hasPrefix:@"_["];
    }

static BOOL XTOperatorIsIndexSet(NSString* shape)
    {
    return XTOperatorIsIndex(shape) && [shape hasSuffix:@"=_"];
    }

// The shape of an index over `count` indices, or over a range (`..`, `...`).
static NSString* XTIndexShape(NSUInteger count, NSString* _Nullable range, BOOL set)
    {
    NSMutableString* sh = [NSMutableString stringWithString:@"_["];
    if (range)
        [sh appendFormat:@"_%@_", range];
    else
        for (NSUInteger i = 0; i < count; i++)
            [sh appendString:i ? @",_" : @"_"];
    [sh appendString:set ? @"]=_" : @"]"];
    return sh;
    }

// How an index is named in a message: `[]`, `[..]`, `[...]`, then `=`.
static NSString* XTIndexSpelling(NSString* _Nullable range, BOOL set)
    {
    return [NSString stringWithFormat:@"[%@]%@", range ?: @"", set ? @"=" : @""];
    }

// The binary operator of a compound assignment, nil for `=`.
static NSString* XTAssignBinarySpelling(XTAssignOp op)
    {
    switch (op)
        {
    case XTAssignOpAdd: return @"+";
    case XTAssignOpSub: return @"-";
    case XTAssignOpMul: return @"*";
    case XTAssignOpDiv: return @"/";
    case XTAssignOpMod: return @"%";
    case XTAssignOpBitAnd: return @"&";
    case XTAssignOpBitOr: return @"|";
    case XTAssignOpBitXor: return @"^";
    case XTAssignOpShl: return @"<<";
    case XTAssignOpShr: return @">>";
    case XTAssignOpRol: return @"<:";
    case XTAssignOpRor: return @":>";
    default: return nil;
        }
    }

static XTBinaryOp XTAssignBinaryOp(XTAssignOp op)
    {
    switch (op)
        {
    case XTAssignOpSub: return XTBinaryOpSub;
    case XTAssignOpMul: return XTBinaryOpMul;
    case XTAssignOpDiv: return XTBinaryOpDiv;
    case XTAssignOpMod: return XTBinaryOpMod;
    case XTAssignOpBitAnd: return XTBinaryOpBitAnd;
    case XTAssignOpBitOr: return XTBinaryOpBitOr;
    case XTAssignOpBitXor: return XTBinaryOpBitXor;
    case XTAssignOpShl: return XTBinaryOpShl;
    case XTAssignOpShr: return XTBinaryOpShr;
    case XTAssignOpRol: return XTBinaryOpRol;
    case XTAssignOpRor: return XTBinaryOpRor;
    default: return XTBinaryOpAdd;
        }
    }

#pragma mark - Classes

/****************************************************************************\
|* The class an operand belongs to: a pointer to a class instance, or an
|* instance by value. nil for anything else, a protocol-typed pointer
|* included.
\****************************************************************************/
- (nullable XTClassDeclNode*)operatorClassOfType:(nullable XTType*)t
    {
    if (!t)
        return nil;
    if ([t isKindOfClass:[XTPointerType class]])
        {
        XTType* pe = ((XTPointerType*)t).pointeeType;
        if (pe && pe.kind == XTTypeKindClass && ![pe isKindOfClass:[XTPointerType class]])
            return self.classesByName[pe.displayName];
        return nil;
        }
    if (t.kind == XTTypeKindClass)
        return self.classesByName[t.displayName];
    return nil;
    }

// Does the class or an ancestor define an operator of this shape?
- (BOOL)operatorClass:(XTClassDeclNode*)cls defines:(NSString*)shape
    {
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        for (XTMethodDeclNode* m in c.methods)
            if ([m.operatorShape isEqualToString:shape])
                return YES;
    return NO;
    }

// Does the class or an ancestor define an index operator of any shape? One
// that does gives up the built-in index for its pointers.
- (BOOL)operatorClassDefinesIndex:(XTClassDeclNode*)cls
    {
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        for (XTMethodDeclNode* m in c.methods)
            if (m.operatorShape && XTOperatorIsIndex(m.operatorShape))
                return YES;
    return NO;
    }

// Does the class or an ancestor define any operator?
- (BOOL)operatorClassHasOperators:(XTClassDeclNode*)cls
    {
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        for (XTMethodDeclNode* m in c.methods)
            if (m.operatorShape)
                return YES;
    return NO;
    }

// Same parameter types, by spelling.
static BOOL XTOperatorSameParams(XTMethodDeclNode* a, XTMethodDeclNode* b)
    {
    if (a.parameters.count != b.parameters.count)
        return NO;
    for (NSUInteger i = 0; i < a.parameters.count; i++)
        {
        NSString* x = a.parameters[i].paramType.displayName ?: @"";
        NSString* y = b.parameters[i].paramType.displayName ?: @"";
        if (![x isEqualToString:y])
            return NO;
        }
    return YES;
    }

#pragma mark - Checking the patterns

/****************************************************************************\
|* The first thing wrong with one operator method's pattern, or nil.
\****************************************************************************/
- (nullable NSString*)operatorPatternFault:(XTMethodDeclNode*)m inClass:(XTClassDeclNode*)cls
    {
    NSString* name = m.methodName;
    if (m.isVarArgs)
        return [NSString stringWithFormat:@"operator method '%@' cannot take '...'", name];
    BOOL isVoid = m.returnTypes.count == 0 || (m.returnTypes.count == 1 && m.returnTypes[0].kind == XTTypeKindVoid);
    // An index set and a compound assignment are statements.
    BOOL statement = XTOperatorIsIndexSet(m.operatorShape) || XTOperatorIsCompound(m.operatorShape);
    if (statement && !isVoid)
        return [NSString stringWithFormat:@"operator method '%@' must return void: an index set or compound assignment is a statement", name];
    if (!statement && (m.returnTypes.count != 1 || isVoid))
        return [NSString stringWithFormat:@"operator method '%@' must return one value", name];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    BOOL usesSelf = NO;
    for (NSString* op in m.operatorOperands)
        {
        if ([seen containsObject:op])
            return [NSString stringWithFormat:@"'%@' appears twice in the :operator pattern of '%@'", op, name];
        [seen addObject:op];
        if ([op isEqualToString:@"self"])
            {
            if (m.isStatic)
                return [NSString stringWithFormat:@"the :operator pattern of static method '%@' cannot use self", name];
            usesSelf = YES;
            continue;
            }
        BOOL isParam = NO;
        for (XTParamNode* p in m.parameters)
            if ([p.paramName isEqualToString:op])
                isParam = YES;
        if (!isParam)
            return [NSString stringWithFormat:@"'%@' in the :operator pattern of '%@' is neither self nor one of its parameters", op, name];
        }
    for (XTParamNode* p in m.parameters)
        if (![seen containsObject:p.paramName])
            return [NSString stringWithFormat:@"parameter '%@' of '%@' does not appear in its :operator pattern", p.paramName, name];
    if (!m.isStatic && !usesSelf)
        return [NSString stringWithFormat:@"the :operator pattern of instance method '%@' must use self", name];
    if (m.isStatic)
        {
        BOOL own = NO;
        for (XTParamNode* p in m.parameters)
            {
            XTClassDeclNode* pc = [self operatorClassOfType:p.paramType];
            if (pc && [self class:pc inheritsFromOrEquals:cls])
                own = YES;
            }
        if (!own)
            return [NSString stringWithFormat:@"static operator '%@' needs an operand of its own class '%@'", name, cls.className];
        }
    // An index or a compound assignment applies to the receiver.
    if ((XTOperatorIsIndex(m.operatorShape) || XTOperatorIsCompound(m.operatorShape))
        && ![m.operatorOperands.firstObject isEqualToString:@"self"])
        return [NSString stringWithFormat:@"the :operator pattern of '%@' must apply its operator to self, as in (self[i]) or (self += o)", name];
    return nil;
    }

- (void)checkOperatorMethods:(XTProgramNode*)program
    {
    for (XTASTNode* decl in program.declarations)
        {
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            if (fn.operatorShape || fn.operatorFault)
                [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' is not a method: an operator is defined by a method of one of its operands' classes", fn.funcName]
                                         at:fn.location];
            }
        else if ([decl isKindOfClass:[XTProtocolDeclNode class]])
            {
            for (XTMethodDeclNode* m in ((XTProtocolDeclNode*)decl).methods)
                if (m.operatorShape || m.operatorFault)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:@"protocol method '%@' cannot be an operator yet", m.methodName]
                                             at:m.location];
                    m.operatorShape = nil;
                    }
            }
        else if ([decl isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            for (XTMethodDeclNode* m in cls.methods)
                {
                if (m.operatorFault)
                    {
                    [self.diagnostics emitError:m.operatorFault at:m.location];
                    continue;
                    }
                if (!m.operatorShape)
                    continue;
                NSString* fault = [self operatorPatternFault:m inClass:cls];
                if (fault)
                    {
                    [self.diagnostics emitError:fault at:m.location];
                    m.operatorShape = nil;
                    }
                else
                    self.hasOperatorMethods = YES;
                }
            }
        }
    }

#pragma mark - Resolving an operator expression

/****************************************************************************\
|* Add the operator methods of `cls` and its ancestors to the candidates: the
|* instance ones or the static ones, as asked. A method hides an ancestor's
|* with the same parameter types, and a method already present is not added
|* twice (the two operands may share a class).
\****************************************************************************/
- (void)addOperatorCandidatesOf:(XTClassDeclNode*)cls
                          shape:(NSString*)shape
                       isStatic:(BOOL)wantStatic
                          cands:(NSMutableArray<XTMethodDeclNode*>*)cands
                         owners:(NSMutableArray<XTClassDeclNode*>*)owners
    {
    NSUInteger first = cands.count;
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        {
        NSUInteger nearer = cands.count;
        for (XTMethodDeclNode* m in c.methods)
            {
            if (![m.operatorShape isEqualToString:shape] || m.isStatic != wantStatic)
                continue;
            // An override in a nearer class is the operator too, written with
            // its pattern or not: the call names it, as `a.plus(b)` would.
            XTMethodDeclNode* use = m;
            XTClassDeclNode* useOwner = c;
            for (XTClassDeclNode* n = cls; !wantStatic && n != nil && n != c && use == m; n = n.parentClass)
                for (XTMethodDeclNode* o in n.methods)
                    if (!o.isStatic && [o.methodName isEqualToString:m.methodName] && XTOperatorSameParams(o, m))
                        {
                        use = o;
                        useOwner = n;
                        break;
                        }
            if ([cands indexOfObjectIdenticalTo:use] != NSNotFound)
                continue;
            BOOL hidden = NO;
            for (NSUInteger i = first; i < nearer; i++)
                if (XTOperatorSameParams(cands[i], use))
                    hidden = YES;
            if (hidden)
                continue;
            [cands addObject:use];
            [owners addObject:useOwner];
            }
        }
    }

/****************************************************************************\
|* The call one candidate makes of the operands: an instance method is called
|* on the first operand with the rest as arguments; a static one on its class
|* with the operands as arguments, in the order its parameters name them.
\****************************************************************************/
- (XTMethodCallExprNode*)operatorCallOf:(XTMethodDeclNode*)m
                                  owner:(XTClassDeclNode*)owner
                               operands:(NSArray<XTASTNode*>*)ops
                                     at:(XTSourceLocation*)loc
    {
    if (!m.isStatic)
        return [[XTMethodCallExprNode alloc] initWithReceiver:ops[0]
                                                   methodName:m.methodName
                                                    arguments:[ops subarrayWithRange:NSMakeRange(1, ops.count - 1)]
                                                     location:loc];
    NSMutableArray<XTASTNode*>* args = [NSMutableArray array];
    for (XTParamNode* p in m.parameters)
        {
        NSUInteger at = [m.operatorOperands indexOfObject:p.paramName];
        [args addObject:ops[at < ops.count ? at : 0]];
        }
    XTIdentifierNode* recv = [[XTIdentifierNode alloc] initWithName:owner.className location:loc];
    return [[XTMethodCallExprNode alloc] initWithReceiver:recv
                                               methodName:m.methodName
                                                arguments:args
                                                 location:loc];
    }

/****************************************************************************\
|* Choose among the operator methods of shape `shape` for already-analysed
|* operands: the instance and static ones of `lc` and the static ones of `rc`.
|* Returns the analysed call. Returns nil with *ambiguous NO when nothing
|* matches (nothing is reported), and with *ambiguous YES after reporting a
|* tie between the best.
\****************************************************************************/
- (nullable XTMethodCallExprNode*)operatorPickForShape:(NSString*)shape
                                              spelling:(NSString*)op
                                              operands:(NSArray<XTASTNode*>*)ops
                                                    at:(XTSourceLocation*)loc
                                                  left:(nullable XTClassDeclNode*)lc
                                                 right:(nullable XTClassDeclNode*)rc
                                             ambiguous:(BOOL*)ambiguous
    {
    *ambiguous = NO;
    NSMutableArray<XTMethodDeclNode*>* cands = [NSMutableArray array];
    NSMutableArray<XTClassDeclNode*>* owners = [NSMutableArray array];
    if (lc)
        {
        [self addOperatorCandidatesOf:lc shape:shape isStatic:NO cands:cands owners:owners];
        [self addOperatorCandidatesOf:lc shape:shape isStatic:YES cands:cands owners:owners];
        }
    if (rc)
        [self addOperatorCandidatesOf:rc shape:shape isStatic:YES cands:cands owners:owners];

    NSInteger best = NSIntegerMax;
    NSMutableArray<NSNumber*>* tied = [NSMutableArray array];
    NSMutableArray<XTMethodCallExprNode*>* calls = [NSMutableArray array];
    for (NSUInteger i = 0; i < cands.count; i++)
        {
        XTMethodCallExprNode* call = [self operatorCallOf:cands[i] owner:owners[i] operands:ops at:loc];
        [calls addObject:call];
        NSMutableArray<XTType*>* pt = [NSMutableArray array];
        for (XTParamNode* p in cands[i].parameters)
            [pt addObject:p.paramType];
        NSInteger sc = [self scoreCandidateParamTypes:pt isVarArgs:NO arguments:call.arguments];
        if (sc == NSIntegerMax)
            continue;
        if (sc < best)
            {
            best = sc;
            [tied removeAllObjects];
            }
        if (sc == best)
            [tied addObject:@(i)];
        }
    if (tied.count == 0)
        return nil;
    if (tied.count > 1)
        {
        NSUInteger a = tied[0].unsignedIntegerValue;
        NSUInteger b = tied[1].unsignedIntegerValue;
        [self.diagnostics emitError:[NSString stringWithFormat:@"operator '%@' on (%@) is ambiguous: '%@.%@' and '%@.%@' both match",
                                                               op, [self describeArgTypes:ops], owners[a].className, cands[a].methodName,
                                                               owners[b].className, cands[b].methodName]
                                 at:loc];
        *ambiguous = YES;
        return nil;
        }
    NSUInteger w = tied[0].unsignedIntegerValue;
    XTMethodCallExprNode* call = calls[w];
    call.operatorMethod = cands[w];
    if (cands[w].isStatic)
        [self analyzeNode:call.receiver];
    [self analyzeNode:call];
    return call;
    }

/****************************************************************************\
|* Resolve an operator over already-analysed operands. Returns nil with
|* *handled NO when no operand's class defines the operator; otherwise
|* *handled is YES and the result is the analysed call, or nil after an error.
\****************************************************************************/
- (nullable XTASTNode*)operatorCallForShape:(NSString*)shape
                                   spelling:(NSString*)op
                                   operands:(NSArray<XTASTNode*>*)ops
                                         at:(XTSourceLocation*)loc
                                    handled:(BOOL*)handled
    {
    *handled = NO;
    if (!self.hasOperatorMethods)
        return nil;
    XTClassDeclNode* lc = [self operatorClassOfType:ops[0].resolvedType];
    XTClassDeclNode* rc = ops.count > 1 ? [self operatorClassOfType:ops[1].resolvedType] : nil;
    BOOL optL = lc && [self operatorClass:lc defines:shape];
    BOOL optR = rc && [self operatorClass:rc defines:shape];
    if (!optL && !optR)
        return nil;
    *handled = YES;

    BOOL ambiguous = NO;
    XTMethodCallExprNode* call = [self operatorPickForShape:shape spelling:op operands:ops at:loc
                                                       left:lc right:rc ambiguous:&ambiguous];
    if (call || ambiguous)
        return call;
    NSString* msg;
    if (ops.count == 1)
        msg = [NSString stringWithFormat:@"'%@' has no prefix '%@' taking '%@'", lc.className, op,
                                         [self describeArgTypes:ops]];
    else if (optL)
        msg = [NSString stringWithFormat:@"'%@' has no '%@' taking '%@'", lc.className, op,
                                         [self describeArgTypes:@[ ops[1] ]]];
    else
        msg = [NSString stringWithFormat:@"'%@' has no '%@' taking '%@' on the left", rc.className, op,
                                         [self describeArgTypes:@[ ops[0] ]]];
    [self.diagnostics emitError:msg at:loc];
    return nil;
    }

- (BOOL)resolveOperatorOfBinary:(XTBinaryExprNode*)node
    {
    NSString* op = XTOperatorBinarySpelling(node.op);
    if (!op)
        return NO;
    BOOL handled = NO;
    XTASTNode* call = [self operatorCallForShape:[NSString stringWithFormat:@"_%@_", op]
                                        spelling:op
                                        operands:@[ node.left, node.right ]
                                              at:node.location
                                         handled:&handled];
    if (!handled)
        return NO;
    node.operatorCall = call;
    node.resolvedType = call ? (call.resolvedType ?: [XTType u8Type]) : [XTType u8Type];
    return YES;
    }

- (BOOL)resolveOperatorOfUnary:(XTUnaryExprNode*)node
    {
    NSString* op = XTOperatorUnarySpelling(node.op);
    if (!op)
        return NO;
    BOOL handled = NO;
    XTASTNode* call = [self operatorCallForShape:[NSString stringWithFormat:@"%@_", op]
                                        spelling:op
                                        operands:@[ node.operand ]
                                              at:node.location
                                         handled:&handled];
    if (!handled)
        return NO;
    node.operatorCall = call;
    node.resolvedType = call ? (call.resolvedType ?: [XTType u8Type]) : [XTType u8Type];
    return YES;
    }

#pragma mark - Index operators and assignment

// An index node's base, indices and range spelling (nil for a plain index).
// A slice with a bound left out has fewer than two indices.
static void XTIndexParts(XTASTNode* node, XTASTNode* _Nullable* _Nonnull base,
                         NSMutableArray<XTASTNode*>* idx, NSString* _Nullable* _Nonnull range)
    {
    if ([node isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)node;
        *base = s.base;
        if (s.index)
            [idx addObject:s.index];
        [idx addObjectsFromArray:s.extraIndices ?: @[]];
        *range = nil;
        return;
        }
    XTSliceExprNode* s = (XTSliceExprNode*)node;
    *base = s.base;
    if (s.startExpr)
        [idx addObject:s.startExpr];
    if (s.endExpr)
        [idx addObject:s.endExpr];
    *range = s.inclusive ? @"..." : @"..";
    }

// The class with an index operator that an index node's base belongs to, or nil.
- (nullable XTClassDeclNode*)indexOperatorClassOf:(XTASTNode*)node
    {
    if (!self.hasOperatorMethods)
        return nil;
    if (![node isKindOfClass:[XTSubscriptExprNode class]] && ![node isKindOfClass:[XTSliceExprNode class]])
        return nil;
    XTASTNode* base = nil;
    NSString* range = nil;
    XTIndexParts(node, &base, [NSMutableArray array], &range);
    XTClassDeclNode* cls = [self operatorClassOfType:base.resolvedType];
    return cls && [self operatorClassDefinesIndex:cls] ? cls : nil;
    }

/****************************************************************************\
|* The get call of an index node on a class with an index operator, or nil
|* after reporting why there is none.
\****************************************************************************/
- (nullable XTMethodCallExprNode*)indexGetCallOf:(XTASTNode*)node cls:(XTClassDeclNode*)cls
    {
    XTASTNode* base = nil;
    NSString* range = nil;
    NSMutableArray<XTASTNode*>* idx = [NSMutableArray array];
    XTIndexParts(node, &base, idx, &range);
    if (range && idx.count != 2)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a range index on '%@' needs both bounds", cls.className]
                                 at:node.location];
        return nil;
        }
    NSString* shape = XTIndexShape(idx.count, range, NO);
    NSString* op = XTIndexSpelling(range, NO);
    if (![self operatorClass:cls defines:shape] && [self operatorClass:cls defines:XTIndexShape(idx.count, range, YES)])
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has '%@=' but no '%@' to read an element with",
                                                               cls.className, op, op]
                                 at:node.location];
        return nil;
        }
    NSMutableArray<XTASTNode*>* ops = [NSMutableArray arrayWithObject:base];
    [ops addObjectsFromArray:idx];
    BOOL ambiguous = NO;
    XTMethodCallExprNode* call = [self operatorPickForShape:shape spelling:op operands:ops at:node.location
                                                       left:cls right:nil ambiguous:&ambiguous];
    if (!call && !ambiguous)
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has no '%@' taking '%@'", cls.className, op,
                                                               [self describeArgTypes:idx]]
                                 at:node.location];
    return call;
    }

- (BOOL)resolveIndexOperatorOf:(XTASTNode*)node target:(BOOL)target
    {
    XTClassDeclNode* cls = [self indexOperatorClassOf:node];
    if (!cls)
        return NO;
    // The target of an assignment is not read: the assignment resolves it.
    if (target)
        return YES;
    XTMethodCallExprNode* call = [self indexGetCallOf:node cls:cls];
    if ([node isKindOfClass:[XTSubscriptExprNode class]])
        ((XTSubscriptExprNode*)node).operatorCall = call;
    else
        ((XTSliceExprNode*)node).operatorCall = call;
    node.resolvedType = call ? (call.resolvedType ?: [XTType u8Type]) : [XTType u8Type];
    return YES;
    }

// An operand read twice is evaluated once, first, unless reading it again
// costs nothing and changes nothing: a name or a literal.
static void XTSharedRvalue(XTASTNode* e, NSMutableArray<XTASTNode*>* out)
    {
    if (!e)
        return;
    switch (e.nodeKind)
        {
    case XTASTNodeKindIdentifier:
    case XTASTNodeKindLiteralInt:
    case XTASTNodeKindLiteralFloat:
    case XTASTNodeKindLiteralString:
    case XTASTNodeKindLiteralChar:
    case XTASTNodeKindLiteralBool:
        return;
    default:
        [out addObject:e];
        }
    }

// The operands of an lvalue that its address is computed from: a pointer's
// value is shared, an inline array or struct is reached through its own
// lvalue.
static void XTSharedLvalue(XTASTNode* lv, NSMutableArray<XTASTNode*>* out)
    {
    if ([lv isKindOfClass:[XTSubscriptExprNode class]] && !((XTSubscriptExprNode*)lv).operatorCall)
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)lv;
        if ([s.base.resolvedType isKindOfClass:[XTPointerType class]])
            XTSharedRvalue(s.base, out);
        else
            XTSharedLvalue(s.base, out);
        XTSharedRvalue(s.index, out);
        }
    else if ([lv isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)lv;
        if (m.isArrow || [m.base.resolvedType isKindOfClass:[XTPointerType class]])
            XTSharedRvalue(m.base, out);
        else
            XTSharedLvalue(m.base, out);
        }
    else if ([lv isKindOfClass:[XTUnaryExprNode class]] && ((XTUnaryExprNode*)lv).op == XTUnaryOpDeref)
        XTSharedRvalue(((XTUnaryExprNode*)lv).operand, out);
    }

// `obj.p` where obj's class (or an ancestor) has a one-parameter `setP`: an
// assignment to it is a property write. The type of the setter's parameter,
// or nil for anything else.
- (nullable XTType*)operatorPropertyTypeOf:(XTASTNode*)lv
    {
    if (![lv isKindOfClass:[XTMemberAccessNode class]])
        return nil;
    XTMemberAccessNode* m = (XTMemberAccessNode*)lv;
    XTClassDeclNode* cls = [self operatorClassOfType:m.base.resolvedType];
    NSString* name = m.memberName;
    if (!cls || name.length == 0)
        return nil;
    NSString* setter = [NSString stringWithFormat:@"set%@%@", [[name substringToIndex:1] uppercaseString],
                                                  [name substringFromIndex:1]];
    for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
        for (XTMethodDeclNode* md in c.methods)
            if ([md.methodName isEqualToString:setter] && md.parameters.count == 1)
                return md.parameters[0].paramType;
    return nil;
    }

// `l OP r` over analysed operands, typed: an operator's call or the built-in.
- (XTBinaryExprNode*)operatorBinary:(XTBinaryOp)op left:(XTASTNode*)l right:(XTASTNode*)r at:(XTSourceLocation*)loc
    {
    XTBinaryExprNode* bin = [[XTBinaryExprNode alloc] initWithOp:op left:l right:r location:loc];
    bin.operandsAnalysed = YES;
    [self analyzeNode:bin];
    return bin;
    }

- (BOOL)resolveOperatorOfAssign:(XTAssignExprNode*)node
    {
    if (!self.hasOperatorMethods)
        return NO;
    XTASTNode* lhs = node.lhs;
    NSString* bop = XTAssignBinarySpelling(node.assignOp);

    // Through an index operator: `m[i] = v`, or `m[i] op= v` as get, op, set.
    XTClassDeclNode* icls = [self indexOperatorClassOf:lhs];
    if (icls)
        {
        XTASTNode* base = nil;
        NSString* range = nil;
        NSMutableArray<XTASTNode*>* idx = [NSMutableArray array];
        XTIndexParts(lhs, &base, idx, &range);
        node.resolvedType = [XTType voidType];
        if (range && idx.count != 2)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"a range index on '%@' needs both bounds", icls.className]
                                     at:lhs.location];
            return YES;
            }
        NSString* setShape = XTIndexShape(idx.count, range, YES);
        NSString* setOp = XTIndexSpelling(range, YES);
        XTASTNode* value = node.rhs;
        NSMutableArray<XTASTNode*>* shared = nil;
        if (bop)
            {
            XTMethodCallExprNode* get = [self indexGetCallOf:lhs cls:icls];
            if (!get)
                return YES;
            XTBinaryExprNode* bin = [self operatorBinary:XTAssignBinaryOp(node.assignOp) left:get right:node.rhs at:node.location];
            // Built-in arithmetic is done at the element's type, as `x op= y` is.
            if (!bin.operatorCall && get.resolvedType)
                bin.resolvedType = get.resolvedType;
            value = bin;
            shared = [NSMutableArray array];
            if ([base.resolvedType isKindOfClass:[XTPointerType class]])
                XTSharedRvalue(base, shared);
            else
                XTSharedLvalue(base, shared);
            for (XTASTNode* x in idx)
                XTSharedRvalue(x, shared);
            }
        if (![self operatorClass:icls defines:setShape] && [self operatorClass:icls defines:XTIndexShape(idx.count, range, NO)])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has '%@' but no '%@' to assign an element with",
                                                                   icls.className, XTIndexSpelling(range, NO), setOp]
                                     at:lhs.location];
            return YES;
            }
        NSMutableArray<XTASTNode*>* ops = [NSMutableArray arrayWithObject:base];
        [ops addObjectsFromArray:idx];
        [ops addObject:value];
        BOOL ambiguous = NO;
        XTMethodCallExprNode* set = [self operatorPickForShape:setShape spelling:setOp operands:ops at:node.location
                                                          left:icls right:nil ambiguous:&ambiguous];
        if (!set && !ambiguous)
            {
            [idx addObject:value];
            [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has no '%@' taking '%@'", icls.className, setOp,
                                                                   [self describeArgTypes:idx]]
                                     at:node.location];
            }
        node.operatorCall = set;
        node.operatorShared = shared.count ? shared : nil;
        return YES;
        }

    // A compound assignment on a class that defines the operator, in place or
    // in its plain form.
    if (!bop)
        return NO;
    // A property's class is its setter's parameter's.
    XTType* propT = [self operatorPropertyTypeOf:lhs];
    XTClassDeclNode* lc = [self operatorClassOfType:propT ?: lhs.resolvedType];
    if (!lc)
        return NO;
    NSString* cShape = [NSString stringWithFormat:@"_%@=_", bop];
    NSString* cOp = [bop stringByAppendingString:@"="];
    BOOL hasC = [self operatorClass:lc defines:cShape];
    BOOL hasP = [self operatorClass:lc defines:[NSString stringWithFormat:@"_%@_", bop]];
    if (!hasC && !hasP)
        {
        // The built-in compound on a class pointer steps it by an integer. A
        // class that defines operators gets no silent `p += q` of two
        // pointers.
        XTType* rt = node.rhs.resolvedType;
        if ([self operatorClassHasOperators:lc] && !(rt && rt.isInteger) && !propT)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has no '%@' or '%@' taking '%@'", lc.className, cOp, bop,
                                                                   [self describeArgTypes:@[ node.rhs ]]]
                                     at:node.location];
            node.resolvedType = [XTType voidType];
            return YES;
            }
        return NO;
        }
    if (propT)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' through an operator cannot assign to the property '%@'; write the assignment out",
                                                               cOp, ((XTMemberAccessNode*)lhs).memberName]
                                 at:node.location];
        node.resolvedType = [XTType voidType];
        return YES;
        }
    if (hasC)
        {
        BOOL ambiguous = NO;
        XTMethodCallExprNode* call = [self operatorPickForShape:cShape spelling:cOp operands:@[ lhs, node.rhs ] at:node.location
                                                           left:lc right:nil ambiguous:&ambiguous];
        if (call || ambiguous || !hasP)
            {
            if (!call && !ambiguous)
                [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' has no '%@' taking '%@'", lc.className, cOp,
                                                                       [self describeArgTypes:@[ node.rhs ]]]
                                         at:node.location];
            node.operatorCall = call;
            node.resolvedType = [XTType voidType];
            return YES;
            }
        }
    // `a op= b` is `a = a op b`, with what the target's address is computed
    // from evaluated once.
    XTBinaryExprNode* bin = [self operatorBinary:XTAssignBinaryOp(node.assignOp) left:lhs right:node.rhs at:node.location];
    NSMutableArray<XTASTNode*>* shared = [NSMutableArray array];
    XTSharedLvalue(lhs, shared);
    [node collapseToPlainAssignWithRhs:bin];
    node.operatorFallback = YES;
    node.operatorShared = shared.count ? shared : nil;
    node.resolvedType = lhs.resolvedType ?: [XTType u8Type];
    [self checkClassPointerAssign:lhs.resolvedType
                          rhsType:bin.resolvedType
                          rhsNode:bin
                             site:@"assignment"
                         location:node.location];
    return YES;
    }

@end
