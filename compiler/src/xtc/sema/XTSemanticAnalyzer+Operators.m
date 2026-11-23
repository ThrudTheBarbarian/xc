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
    if (m.returnTypes.count != 1 || m.returnTypes[0].kind == XTTypeKindVoid)
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

    NSString* types = [self describeArgTypes:ops];
    if (tied.count == 0)
        {
        NSString* msg;
        if (ops.count == 1)
            msg = [NSString stringWithFormat:@"'%@' has no prefix '%@' taking '%@'", lc.className, op, types];
        else if (optL)
            msg = [NSString stringWithFormat:@"'%@' has no '%@' taking '%@'", lc.className, op,
                                             [self describeArgTypes:@[ ops[1] ]]];
        else
            msg = [NSString stringWithFormat:@"'%@' has no '%@' taking '%@' on the left", rc.className, op,
                                             [self describeArgTypes:@[ ops[0] ]]];
        [self.diagnostics emitError:msg at:loc];
        return nil;
        }
    if (tied.count > 1)
        {
        NSUInteger a = tied[0].unsignedIntegerValue;
        NSUInteger b = tied[1].unsignedIntegerValue;
        [self.diagnostics emitError:[NSString stringWithFormat:@"operator '%@' on (%@) is ambiguous: '%@.%@' and '%@.%@' both match",
                                                               op, types, owners[a].className, cands[a].methodName,
                                                               owners[b].className, cands[b].methodName]
                                 at:loc];
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

@end
