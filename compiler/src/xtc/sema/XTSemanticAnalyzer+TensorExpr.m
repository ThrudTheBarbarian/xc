/****************************************************************************\
|* XTSemanticAnalyzer+TensorExpr.m
|*
|* Element-wise tensor expressions. An operator, unary minus, a cast or a
|* Math function with a tensor operand is an element-wise expression: its
|* value is a new tensor of the broadcast shape, each element computed from
|* the operands' elements at its position, under the scalar rules of the
|* element types. A whole expression is one tree: a node whose operand is
|* such a node takes that node's tree in, so `Math.sqrt(a * b + c) - e` is
|* one tree with four operands, and one kernel (XTParser+TensorKernels.m)
|* computes it, with no tensor for the parts. A write into a view (`t[..,
|* ..] = v`) and a compound assignment (`t += v`) are trees too, written in
|* place.
|*
|* The first pass types each tree and records its signature; the driver has
|* the parse write the kernels and starts again; the second pass makes each
|* tree's root a call of its kernel (`operatorCall`, as an operator method's
|* call). Mirrored in the port's sema.
\****************************************************************************/
#import "XTSemanticAnalyzer+TensorExpr.h"
#import "XTSemanticAnalyzer+Private.h"
#import "XTSemanticAnalyzer+Overload.h"
#import "XTExprNodes.h"
#import "XTDeclNodes.h"
#import "XTType.h"
#import "XTTypeTable.h"
#import "XTPointerType.h"
#import "XTDiagnosticEngine.h"
#import "XTParser.h"

// One tree: its signature (prefix, XTParser+TensorKernels.m), operands, the
// type of its elements and its rank.
@interface XTTensorTree : NSObject
@property(nonatomic, copy) NSString* sig;
@property(nonatomic) NSMutableArray<XTASTNode*>* leaves;
@property(nonatomic) XTType* elem;
@property(nonatomic) NSInteger rank;
@property(nonatomic, copy, nullable) NSString* full;
@end

@implementation XTTensorTree
@end

@implementation XTSemanticAnalyzer (TensorExpr)

// The rank of a tensor value's type (`__tensor_<T>_<R>`), 0 for any other.
static NSInteger XTTensorTypeRank(XTType* _Nullable t)
    {
    if (!t || t.kind != XTTypeKindClass || [t isKindOfClass:[XTPointerType class]])
        return 0;
    NSString* n = t.displayName;
    if (![n hasPrefix:@"__tensor_"] || n.length < 12)
        return 0;
    unichar c = [n characterAtIndex:n.length - 1];
    return c >= '1' && c <= '8' ? c - '0' : 0;
    }

// An element type as a signature and a class name spell it.
static NSString* XTElemCanon(XTType* t)
    {
    if (t.kind == XTTypeKindFloat)
        return @"f32";
    if (t.kind == XTTypeKindDouble)
        return @"f64";
    return t.displayName;
    }

// The kinds of element: an integer (not bool, not an enum), a float (f64,
// f32 or a pack), bool.
static BOOL XTElemInt(XTType* _Nullable t)
    {
    return t && t.isInteger && t.kind != XTTypeKindBool && t.kind != XTTypeKindEnum && ![t isKindOfClass:[XTPointerType class]];
    }

static BOOL XTElemFloat(XTType* _Nullable t)
    {
    return t && (t.isFloating || t.isFloatPack) && ![t isKindOfClass:[XTPointerType class]];
    }

static BOOL XTElemNumeric(XTType* _Nullable t)
    {
    return XTElemInt(t) || XTElemFloat(t) || (t && t.kind == XTTypeKindBool && ![t isKindOfClass:[XTPointerType class]]);
    }

// Does every value of `a` convert exactly to `b`? Integers: to a wider one
// of the same signedness, or unsigned to a wider signed. Floats: the packs'
// rule. bool only to bool, and never between integers and floats.
static BOOL XTElemHolds(XTType* a, XTType* b)
    {
    if (a == b || [XTElemCanon(a) isEqualToString:XTElemCanon(b)])
        return YES;
    if (a.kind == XTTypeKindBool || b.kind == XTTypeKindBool)
        return NO;
    if (XTElemInt(a) && XTElemInt(b))
        return a.byteWidth < b.byteWidth && (a.isSigned == b.isSigned || !a.isSigned);
    if (!XTElemFloat(a) || !XTElemFloat(b))
        return NO;
    return [XTType packHolds:a in:b];
    }

static BOOL XTTensorIsLiteral(XTASTNode* n)
    {
    if (n.nodeKind == XTASTNodeKindLiteralInt)
        return !((XTLiteralIntNode*)n).isNil;
    if (n.nodeKind == XTASTNodeKindLiteralFloat || n.nodeKind == XTASTNodeKindLiteralBool)
        return YES;
    if (n.nodeKind == XTASTNodeKindUnaryExpr && ((XTUnaryExprNode*)n).op == XTUnaryOpNeg)
        {
        XTASTNode* o = ((XTUnaryExprNode*)n).operand;
        return o.nodeKind == XTASTNodeKindLiteralInt || o.nodeKind == XTASTNodeKindLiteralFloat;
        }
    return NO;
    }

- (XTType*)tensorTypeOf:(XTType*)elem rank:(NSInteger)rank
    {
    NSString* nm = [NSString stringWithFormat:@"__tensor_%@_%ld",
                                              [XTElemCanon(elem) stringByReplacingOccurrencesOfString:@"$" withString:@"_"], (long)rank];
    XTType* t = [self.typeTable typeForName:nm];
    if (!t)
        {
        t = [[XTType alloc] initWithKind:XTTypeKindClass displayName:nm];
        [self.typeTable registerType:t forName:nm];
        }
    return t;
    }

// A tensor type's element type: its class's `_get` result.
- (nullable XTType*)tensorElemOf:(XTType*)t
    {
    XTClassDeclNode* c = self.classesByName[t.displayName];
    for (XTMethodDeclNode* m in c.methods)
        if ([m.methodName isEqualToString:@"_get"] && m.returnTypes.count)
            return m.returnTypes[0];
    return nil;
    }

// The tree a node made, or nil.
- (nullable XTTensorTree*)tensorTreeOf:(XTASTNode*)n
    {
    return [self.tensorTrees objectForKey:n];
    }

// The element type an operand gives: its tree's, a tensor's, or a scalar's.
- (nullable XTType*)tensorSideElem:(XTASTNode*)x
    {
    XTTensorTree* t = [self tensorTreeOf:x];
    if (t)
        return t.elem;
    if (XTTensorTypeRank(x.resolvedType))
        return [self tensorElemOf:x.resolvedType];
    return x.resolvedType;
    }

// A literal operand takes the element type of the tensor beside it, as a
// literal stored into an element does. NO after reporting one that cannot.
- (BOOL)tensorAdoptLiteral:(XTASTNode*)lit to:(XTType*)e
    {
    if (e.isFloatPack)
        {
        if (lit.nodeKind == XTASTNodeKindLiteralBool)
            return YES;
        [self packAdoptLiteral:lit to:e];
        return YES;
        }
    if (XTElemInt(e))
        {
        BOOL neg = lit.nodeKind == XTASTNodeKindUnaryExpr;
        XTASTNode* v = neg ? ((XTUnaryExprNode*)lit).operand : lit;
        if (v.nodeKind == XTASTNodeKindLiteralFloat)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"a literal for '%@' elements is an integer", XTElemCanon(e)]
                                     at:lit.location];
            return NO;
            }
        if (v.nodeKind != XTASTNodeKindLiteralInt)
            return YES;
        int64_t x = ((XTLiteralIntNode*)v).intValue;
        if (neg)
            x = -x;
        NSUInteger bits = e.byteWidth * 8;
        BOOL fits;
        if (bits >= 64)
            fits = e.isSigned || x >= 0;
        else if (e.isSigned)
            fits = x >= -(1LL << (bits - 1)) && x < (1LL << (bits - 1));
        else
            fits = x >= 0 && x < (1LL << bits);
        if (!fits)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"%lld does not fit '%@' elements", (long long)x, XTElemCanon(e)]
                                     at:lit.location];
            return NO;
            }
        }
    return YES;
    }

// An operand as a tree: the tree its node made, taken into the larger one,
// or a leaf, a tensor (`t:<E>:<R>`) or a scalar (`s:<E>`) of type `as`.
- (XTTensorTree*)tensorOperand:(XTASTNode*)x as:(nullable XTType*)as
    {
    XTTensorTree* t = [self tensorTreeOf:x];
    if (t)
        {
        if (!self.tensorAbsorbed)
            self.tensorAbsorbed = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                                                                    NSPointerFunctionsStrongMemory];
        [self.tensorAbsorbed addObject:x];
        return t;
        }
    XTTensorTree* l = [XTTensorTree new];
    l.leaves = [NSMutableArray arrayWithObject:x];
    NSInteger r = XTTensorTypeRank(x.resolvedType);
    l.rank = r;
    l.elem = as ?: (r ? [self tensorElemOf:x.resolvedType] : x.resolvedType);
    l.sig = r ? [NSString stringWithFormat:@"t:%@:%ld", XTElemCanon(l.elem), (long)r]
              : [NSString stringWithFormat:@"s:%@", XTElemCanon(l.elem)];
    return l;
    }

// The routines of a small float the tree computes in.
- (void)tensorNotePack:(XTType*)t
    {
    if (t.isFloatPack)
        self.packRoutines |= t.packFlags ? 3 : 1;
    }

// A node's tree is made: its type, and in the pass that has its kernel, the
// call of it. `args` are the call's arguments.
- (void)tensorFinish:(XTASTNode*)node tree:(XTTensorTree*)t full:(NSString*)full args:(NSArray<XTASTNode*>*)args
    {
    t.full = full;
    if (!self.tensorTrees)
        self.tensorTrees = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality |
                                                              NSPointerFunctionsStrongMemory
                                                 valueOptions:NSPointerFunctionsStrongMemory];
    [self.tensorTrees setObject:t forKey:node];
    [self.tensorAbsorbed removeObject:node];
    [self tensorNotePack:t.elem];
    for (XTASTNode* x in t.leaves)
        [self tensorNotePack:[self tensorSideElem:x]];
    if (![self.tensorKernelsGiven containsObject:full])
        return;
    XTCallExprNode* call = [[XTCallExprNode alloc] initWithCallee:[@"__tk_" stringByAppendingString:[XTParser tensorKernelName:full]]
                                                        arguments:args
                                                         location:node.location];
    // The operands were analysed with the expression, and what that
    // reported stands: analysed again as the call's arguments, they report
    // nothing more.
    NSUInteger mark = self.diagnostics.mark;
    BOOL fatal = self.diagnostics.hasFatalError;
    [self analyzeNode:call];
    [self.diagnostics truncateToCount:mark fatal:fatal];
    switch (node.nodeKind)
        {
    case XTASTNodeKindBinaryExpr:
        ((XTBinaryExprNode*)node).operatorCall = call;
        break;
    case XTASTNodeKindUnaryExpr:
        ((XTUnaryExprNode*)node).operatorCall = call;
        break;
    case XTASTNodeKindCastExpr:
        ((XTCastExprNode*)node).operatorCall = call;
        break;
    case XTASTNodeKindMethodCallExpr:
        ((XTMethodCallExprNode*)node).operatorCall = call;
        break;
    case XTASTNodeKindAssignExpr:
        ((XTAssignExprNode*)node).operatorCall = call;
        break;
    default:
        break;
        }
    }

// The type a cast of a mismatch suggests: f32 for floats that fit it, f64
// for the others, i64 for integers; the float's for an integer and a float.
static NSString* XTSuggestElem(XTType* a, XTType* b)
    {
    if (XTElemInt(a) && XTElemInt(b))
        return @"i64";
    if (!XTElemFloat(a))
        return XTElemCanon(b);
    if (!XTElemFloat(b))
        return XTElemCanon(a);
    return (a.kind == XTTypeKindDouble || b.kind == XTTypeKindDouble) ? @"f64" : @"f32";
    }

// An operand's type as a message names it: the tensor's, or the scalar's.
- (NSString*)tensorOperandName:(XTASTNode*)x
    {
    XTTensorTree* t = [self tensorTreeOf:x];
    if (t)
        return [self tensorTypeOf:t.elem rank:t.rank].displayName;
    if (XTElemNumeric(x.resolvedType))
        return XTElemCanon(x.resolvedType);
    return x.resolvedType.displayName ?: @"?";
    }

// The common element type of two operands, or nil after reporting there is none.
- (nullable XTType*)tensorCommon:(XTASTNode*)l elem:(XTType*)le with:(XTASTNode*)r elem:(XTType*)re
                            rank:(NSInteger)rank at:(XTSourceLocation*)loc
    {
    if (XTElemHolds(le, re))
        return re;
    if (XTElemHolds(re, le))
        return le;
    NSString* sug = [NSString stringWithFormat:@"__tensor_%@_%ld", XTSuggestElem(le, re), (long)rank];
    [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' and '%@' have no common element type: neither holds every value "
                                                           @"of the other; cast one, as in (%@)x",
                                                           [self tensorOperandName:l], [self tensorOperandName:r], sug]
                             at:loc];
    return nil;
    }

// Two operands' elements, a literal taking the other's type. NO after an error.
- (BOOL)tensorPair:(XTASTNode*)l :(XTASTNode*)r le:(XTType* _Nullable*)le re:(XTType* _Nullable*)re
    {
    *le = [self tensorSideElem:l];
    *re = [self tensorSideElem:r];
    BOOL lt = [self tensorTreeOf:l] || XTTensorTypeRank(l.resolvedType);
    BOOL rt = [self tensorTreeOf:r] || XTTensorTypeRank(r.resolvedType);
    for (int side = 0; side < 2; side++)
        {
        XTASTNode* x = side ? r : l;
        BOOL isT = side ? rt : lt;
        if (isT || XTElemNumeric(x.resolvedType))
            continue;
        [self.diagnostics emitError:[NSString stringWithFormat:@"a tensor expression takes tensors and numbers, not '%@'",
                                                               x.resolvedType.displayName ?: @"?"]
                                 at:x.location];
        return NO;
        }
    if (!lt && XTTensorIsLiteral(l) && *re)
        {
        if (![self tensorAdoptLiteral:l to:*re])
            return NO;
        *le = *re;
        }
    if (!rt && XTTensorIsLiteral(r) && *le)
        {
        if (![self tensorAdoptLiteral:r to:*le])
            return NO;
        *re = *le;
        }
    return *le && *re;
    }

static NSString* XTTensorBinarySpelling(XTBinaryOp op)
    {
    switch (op)
        {
    case XTBinaryOpAdd: return @"+";
    case XTBinaryOpSub: return @"-";
    case XTBinaryOpMul: return @"*";
    case XTBinaryOpDiv: return @"/";
    case XTBinaryOpMod: return @"%";
    case XTBinaryOpEq: return @"==";
    case XTBinaryOpNeq: return @"!=";
    case XTBinaryOpLt: return @"<";
    case XTBinaryOpGt: return @">";
    case XTBinaryOpLe: return @"<=";
    case XTBinaryOpGe: return @">=";
    case XTBinaryOpBitAnd: return @"&";
    case XTBinaryOpBitOr: return @"|";
    case XTBinaryOpBitXor: return @"^";
    case XTBinaryOpShl: return @"<<";
    case XTBinaryOpShr: return @">>";
    case XTBinaryOpLogAnd: return @"&&";
    case XTBinaryOpLogOr: return @"||";
    default: return @"?";
        }
    }

// The tree of `l op r`, op a binary spelling (`+`, `<`, …), or nil after an
// error. Shared by binary operators, compound assignment and Math.pow.
- (nullable XTTensorTree*)tensorTreeOp:(NSString*)op left:(XTASTNode*)l right:(XTASTNode*)r
                                  lsig:(nullable XTTensorTree*)lt at:(XTSourceLocation*)loc
    {
    XTType* le = nil;
    XTType* re = nil;
    if (![self tensorPair:l :r le:&le re:&re])
        return nil;
    NSInteger rank = MAX([self tensorTreeOf:l] ? [self tensorTreeOf:l].rank : XTTensorTypeRank(l.resolvedType),
                         [self tensorTreeOf:r] ? [self tensorTreeOf:r].rank : XTTensorTypeRank(r.resolvedType));
    if (lt)
        rank = MAX(rank, lt.rank);
    BOOL cmp = [@[ @"==", @"!=", @"<", @">", @"<=", @">=" ] containsObject:op];
    XTType* c = [self tensorCommon:l elem:le with:r elem:re rank:rank at:loc];
    if (!c)
        return nil;
    if (c.kind == XTTypeKindBool && !([op isEqualToString:@"=="] || [op isEqualToString:@"!="]))
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"bool elements take only == and !=, not '%@'", op] at:loc];
        return nil;
        }
    if ([op isEqualToString:@"%"] && !XTElemInt(c))
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%%' takes integer elements, not '%@'", XTElemCanon(c)] at:loc];
        return nil;
        }
    XTTensorTree* a = lt ?: [self tensorOperand:l as:le];
    XTTensorTree* b = [self tensorOperand:r as:re];
    XTTensorTree* t = [XTTensorTree new];
    t.sig = [NSString stringWithFormat:@"%@:%@ %@ %@", op, XTElemCanon(c), a.sig, b.sig];
    t.leaves = [NSMutableArray arrayWithArray:a.leaves];
    [t.leaves addObjectsFromArray:b.leaves];
    t.elem = cmp ? [XTType boolType] : c;
    t.rank = rank;
    [self tensorNotePack:c];
    return t;
    }

- (BOOL)tensorExprBinary:(XTBinaryExprNode*)node
    {
    XTASTNode* l = node.left;
    XTASTNode* r = node.right;
    NSInteger lr = XTTensorTypeRank(l.resolvedType);
    NSInteger rr = XTTensorTypeRank(r.resolvedType);
    if (!lr && !rr)
        return NO;
    XTType* tt = lr ? l.resolvedType : r.resolvedType;
    NSString* op = XTTensorBinarySpelling(node.op);
    BOOL ok = node.op == XTBinaryOpAdd || node.op == XTBinaryOpSub || node.op == XTBinaryOpMul || node.op == XTBinaryOpDiv ||
              node.op == XTBinaryOpMod || node.op == XTBinaryOpEq || node.op == XTBinaryOpNeq || node.op == XTBinaryOpLt ||
              node.op == XTBinaryOpGt || node.op == XTBinaryOpLe || node.op == XTBinaryOpGe;
    if (!ok)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' does not take '%@': a tensor expression takes + - * / %%, "
                                                               @"the comparisons, unary -, casts and Math functions",
                                                               tt.displayName, op]
                                 at:node.location];
        node.resolvedType = tt;
        return YES;
        }
    XTTensorTree* t = [self tensorTreeOp:op left:l right:r lsig:nil at:node.location];
    if (!t)
        {
        node.resolvedType = tt;
        return YES;
        }
    node.resolvedType = [self tensorTypeOf:t.elem rank:t.rank];
    [self tensorFinish:node tree:t full:[@"new " stringByAppendingString:t.sig] args:t.leaves];
    return YES;
    }

- (BOOL)tensorExprUnary:(XTUnaryExprNode*)node
    {
    XTASTNode* x = node.operand;
    NSInteger rank = XTTensorTypeRank(x.resolvedType);
    if (!rank)
        return NO;
    // `&t` and `*p` keep their meaning; `~`, `!` and `+` are refused.
    if (node.op != XTUnaryOpNeg && node.op != XTUnaryOpBitNot && node.op != XTUnaryOpLogNot && node.op != XTUnaryOpPlus)
        return NO;
    if (node.op != XTUnaryOpNeg)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' takes no prefix operator but '-' in a tensor expression",
                                                               x.resolvedType.displayName]
                                 at:node.location];
        node.resolvedType = x.resolvedType;
        return YES;
        }
    XTTensorTree* a = [self tensorTreeOf:x] ?: [self tensorOperand:x as:nil];
    if (a.elem.kind == XTTypeKindBool)
        {
        [self.diagnostics emitError:@"bool elements take no unary '-'" at:node.location];
        node.resolvedType = x.resolvedType;
        return YES;
        }
    if ([self tensorTreeOf:x])
        [self tensorOperand:x as:nil];
    XTTensorTree* t = [XTTensorTree new];
    t.sig = [NSString stringWithFormat:@"neg:%@ %@", XTElemCanon(a.elem), a.sig];
    t.leaves = [a.leaves mutableCopy];
    t.elem = a.elem;
    t.rank = a.rank;
    node.resolvedType = [self tensorTypeOf:t.elem rank:t.rank];
    [self tensorFinish:node tree:t full:[@"new " stringByAppendingString:t.sig] args:t.leaves];
    return YES;
    }

- (BOOL)tensorExprCast:(XTCastExprNode*)node
    {
    NSInteger rank = XTTensorTypeRank(node.castType);
    if (!rank)
        return NO;
    XTASTNode* x = node.operand;
    NSInteger xr = XTTensorTypeRank(x.resolvedType);
    if (!xr)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a cast to '%@' takes a tensor, not '%@'",
                                                               node.castType.displayName, x.resolvedType.displayName ?: @"?"]
                                 at:node.location];
        return YES;
        }
    if (xr != rank)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a cast to '%@' keeps the rank: it takes a tensor of rank %ld, not "
                                                               @"'%@'",
                                                               node.castType.displayName, (long)rank, x.resolvedType.displayName]
                                 at:node.location];
        return YES;
        }
    XTType* to = [self tensorElemOf:node.castType];
    if (!to)
        return YES;
    XTTensorTree* a = [self tensorOperand:x as:nil];
    XTTensorTree* t = [XTTensorTree new];
    t.sig = [NSString stringWithFormat:@"cast:%@ %@", XTElemCanon(to), a.sig];
    t.leaves = [a.leaves mutableCopy];
    t.elem = to;
    t.rank = rank;
    [self tensorFinish:node tree:t full:[@"new " stringByAppendingString:t.sig] args:t.leaves];
    return YES;
    }

- (BOOL)tensorExprMath:(XTMethodCallExprNode*)node
    {
    if (node.receiver.nodeKind != XTASTNodeKindIdentifier ||
        ![((XTIdentifierNode*)node.receiver).identName isEqualToString:@"Math"])
        return NO;
    NSString* name = node.methodName;
    NSArray<NSString*>* floats = @[ @"sqrt", @"exp", @"ln", @"sin", @"cos", @"tan", @"atan", @"abs", @"pow" ];
    if (node.arguments.count == 0 || node.arguments.count > 2)
        return NO;
    // The arguments, analysed to see whether one is a tensor; when none is,
    // what that reported goes, and the call's own analysis reports it.
    NSUInteger mark = self.diagnostics.mark;
    BOOL fatal = self.diagnostics.hasFatalError;
    BOOL any = NO;
    for (XTASTNode* a in node.arguments)
        {
        [self analyzeNode:a];
        if (XTTensorTypeRank(a.resolvedType))
            any = YES;
        }
    if (!any)
        {
        [self.diagnostics truncateToCount:mark fatal:fatal];
        return NO;
        }
    // The receiver names the class, typed as the call's own analysis types it.
    [self analyzeNode:node.receiver];
    XTASTNode* x = node.arguments[0];
    XTType* tt = x.resolvedType;
    if (![floats containsObject:name] || node.arguments.count != ([name isEqualToString:@"pow"] ? 2u : 1u))
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"Math.%@ has no tensor form; the tensor forms are sqrt, exp, ln, sin, "
                                                               @"cos, tan, atan and abs of one tensor, and pow of two operands",
                                                               name]
                                 at:node.location];
        node.resolvedType = tt;
        return YES;
        }
    XTTensorTree* t = nil;
    if ([name isEqualToString:@"pow"])
        {
        XTTensorTree* p = [self tensorTreeOp:@"*" left:x right:node.arguments[1] lsig:nil at:node.location];
        if (!p)
            {
            node.resolvedType = XTTensorTypeRank(tt) ? tt : node.arguments[1].resolvedType;
            return YES;
            }
        // The product's tree, with pow in place of `*`.
        NSRange sp = [p.sig rangeOfString:@" "];
        t = p;
        t.sig = [NSString stringWithFormat:@"fn:pow:%@%@", XTElemCanon(p.elem), [p.sig substringFromIndex:sp.location]];
        }
    else
        {
        XTTensorTree* a = [self tensorTreeOf:x] ?: [self tensorOperand:x as:nil];
        XTType* e = a.elem;
        BOOL fl = XTElemFloat(e);
        BOOL in = [name isEqualToString:@"abs"] && XTElemInt(e) && e.isSigned && e.byteWidth <= 4;
        if (!fl && !in)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"Math.%@ takes tensors of f64, f32, f16, bf16, f8 or f4%@, not '%@'",
                                                                   name, [name isEqualToString:@"abs"] ? @", or i8, i16 or i32" : @"",
                                                                   [self tensorOperandName:x]]
                                     at:node.location];
            node.resolvedType = tt;
            return YES;
            }
        if ([self tensorTreeOf:x])
            [self tensorOperand:x as:nil];
        t = [XTTensorTree new];
        t.sig = [NSString stringWithFormat:@"fn:%@:%@ %@", name, XTElemCanon(e), a.sig];
        t.leaves = [a.leaves mutableCopy];
        t.elem = e;
        t.rank = a.rank;
        }
    if (!XTElemFloat(t.elem))
        {
        if (![name isEqualToString:@"abs"])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"Math.%@ takes tensors of f64, f32, f16, bf16, f8 or f4, not '%@'",
                                                                   name, [self tensorOperandName:x]]
                                     at:node.location];
            node.resolvedType = tt;
            return YES;
            }
        }
    node.resolvedType = [self tensorTypeOf:t.elem rank:t.rank];
    [self tensorFinish:node tree:t full:[@"new " stringByAppendingString:t.sig] args:t.leaves];
    return YES;
    }

- (BOOL)tensorExprAssign:(XTAssignExprNode*)node
    {
    XTASTNode* lhs = node.lhs;
    XTASTNode* base = nil;
    BOOL slice = NO;
    if (lhs.nodeKind == XTASTNodeKindSliceExpr)
        {
        base = ((XTSliceExprNode*)lhs).base;
        slice = YES;
        }
    else if (lhs.nodeKind == XTASTNodeKindSubscriptExpr)
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)lhs;
        base = s.base;
        BOOL range = [s.index isKindOfClass:[XTRangeExprNode class]];
        for (XTASTNode* x in s.extraIndices ?: @[])
            if ([x isKindOfClass:[XTRangeExprNode class]])
                range = YES;
        slice = range;
        }
    XTASTNode* dest = nil;
    if (slice && XTTensorTypeRank(base.resolvedType))
        {
        // The view the slice gives, as it would be read.
        XTASTNode* prev = self.operatorIndexTarget;
        self.operatorIndexTarget = nil;
        [self analyzeNode:lhs];
        self.operatorIndexTarget = prev;
        dest = lhs;
        }
    else if (!slice && node.assignOp != XTAssignOpAssign && XTTensorTypeRank(lhs.resolvedType))
        dest = lhs;
    if (!dest)
        return NO;
    node.resolvedType = [XTType voidType];
    XTType* dt = dest.resolvedType;
    NSInteger drank = XTTensorTypeRank(dt);
    if (!drank)
        return YES;
    XTType* de = [self tensorElemOf:dt];
    XTASTNode* v = node.rhs;
    XTTensorTree* t = nil;
    if (node.assignOp == XTAssignOpAssign)
        {
        XTType* ve = [self tensorSideElem:v];
        if (!XTTensorTypeRank(v.resolvedType) && ![self tensorTreeOf:v])
            {
            if (!XTElemNumeric(v.resolvedType))
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"a tensor expression takes tensors and numbers, not '%@'",
                                                                       v.resolvedType.displayName ?: @"?"]
                                         at:v.location];
                return YES;
                }
            if (XTTensorIsLiteral(v))
                {
                if (![self tensorAdoptLiteral:v to:de])
                    return YES;
                ve = de;
                }
            }
        t = [self tensorOperand:v as:ve];
        }
    else
        {
        // `t op= v` is `t = t op v`, written in place: `d` reads the
        // destination's own element.
        NSDictionary<NSNumber*, NSString*>* ops = @{
            @(XTAssignOpAdd) : @"+", @(XTAssignOpSub) : @"-", @(XTAssignOpMul) : @"*", @(XTAssignOpDiv) : @"/", @(XTAssignOpMod) : @"%"
        };
        NSString* op = ops[@(node.assignOp)];
        if (!op)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' takes no compound assignment but += -= *= /= and %%=",
                                                                   dt.displayName]
                                     at:node.location];
            return YES;
            }
        XTTensorTree* d = [XTTensorTree new];
        d.sig = @"d";
        d.leaves = [NSMutableArray array];
        d.elem = de;
        d.rank = drank;
        t = [self tensorTreeOp:op left:dest right:v lsig:d at:node.location];
        if (!t)
            return YES;
        }
    if (t.rank > drank)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a value of rank %ld does not fit '%@', of rank %ld", (long)t.rank,
                                                               dt.displayName, (long)drank]
                                 at:node.location];
        return YES;
        }
    if (!XTElemHolds(t.elem, de))
        {
        NSString* vn = t.rank ? [self tensorTypeOf:t.elem rank:t.rank].displayName : XTElemCanon(t.elem);
        NSString* cast = t.rank ? [self tensorTypeOf:de rank:t.rank].displayName : XTElemCanon(de);
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' does not hold every value of '%@': cast it, as in (%@)x",
                                                               dt.displayName, vn, cast]
                                 at:node.location];
        return YES;
        }
    NSMutableArray<XTASTNode*>* args = [NSMutableArray arrayWithObject:dest];
    [args addObjectsFromArray:t.leaves];
    [self tensorFinish:node tree:t full:[NSString stringWithFormat:@"set:%@:%ld %@", XTElemCanon(de), (long)drank, t.sig] args:args];
    return YES;
    }

- (void)tensorRefuseCondition:(XTASTNode*)cond
    {
    if (XTTensorTypeRank(cond.resolvedType))
        [self.diagnostics emitError:[NSString stringWithFormat:@"'%@' is not a condition: test its elements one at a time",
                                                               cond.resolvedType.displayName]
                                 at:cond.location];
    }

- (NSArray<NSString*>*)tensorKernelRequests
    {
    NSMutableSet<NSString*>* out = [NSMutableSet set];
    for (XTASTNode* n in self.tensorTrees)
        if (![self.tensorAbsorbed containsObject:n])
            {
            XTTensorTree* t = [self.tensorTrees objectForKey:n];
            if (t.full)
                [out addObject:t.full];
            }
    return [out.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }

@end
