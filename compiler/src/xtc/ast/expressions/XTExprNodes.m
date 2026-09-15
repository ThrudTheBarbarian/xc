#import "XTExprNodes.h"

@implementation XTBinaryExprNode
/****************************************************************************\
|* Create a binary expression node (e.g. a + b, x == y).
|* @param op        The binary operator.
|* @param left      The left-hand operand expression.
|* @param right     The right-hand operand expression.
|* @param location  Source location of the operator token.
|* @return A new binary expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTBinaryOp)op left:(XTASTNode*)left right:(XTASTNode*)right location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindBinaryExpr location:location];
    if (self)
        {
        _op = op;
        _left = left;
        _right = right;
        }
    return self;
    }
- (void)replaceLeft:(XTASTNode*)left
    {
    _left = left;
    }
- (void)replaceRight:(XTASTNode*)right
    {
    _right = right;
    }
/****************************************************************************\
|* Dispatch to visitBinaryExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitBinaryExpr:)])
        [visitor visitBinaryExpr:self];
    }
@end

@implementation XTUnaryExprNode
/****************************************************************************\
|* Create a unary (prefix) expression node (e.g. -x, !flag, &var).
|* @param op        The unary operator.
|* @param operand   The operand expression.
|* @param location  Source location of the operator token.
|* @return A new unary expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTUnaryOp)op operand:(XTASTNode*)operand location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindUnaryExpr location:location];
    if (self)
        {
        _op = op;
        _operand = operand;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitUnaryExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitUnaryExpr:)])
        [visitor visitUnaryExpr:self];
    }
@end

@implementation XTPostfixExprNode
/****************************************************************************\
|* Create a postfix expression node (i++ or i--).
|* @param op        The postfix operator (increment or decrement).
|* @param operand   The operand expression.
|* @param location  Source location of the operator token.
|* @return A new postfix expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTPostfixOp)op operand:(XTASTNode*)operand location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindPostfixExpr location:location];
    if (self)
        {
        _postfixOp = op;
        _operand = operand;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitPostfixExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitPostfixExpr:)])
        [visitor visitPostfixExpr:self];
    }
@end

@implementation XTAssignExprNode
/****************************************************************************\
|* Create an assignment expression node (=, +=, -=, etc.).
|* @param op        The assignment operator variant.
|* @param lhs       The left-hand side (target) expression.
|* @param rhs       The right-hand side (value) expression.
|* @param location  Source location of the operator token.
|* @return A new assignment expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTAssignOp)op lhs:(XTASTNode*)lhs rhs:(XTASTNode*)rhs location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindAssignExpr location:location];
    if (self)
        {
        _assignOp = op;
        _lhs = lhs;
        _rhs = rhs;
        }
    return self;
    }
- (void)collapseToPlainAssignWithRhs:(XTASTNode*)rhs
    {
    _assignOp = XTAssignOpAssign;
    _rhs = rhs;
    }
- (void)replaceRhs:(XTASTNode*)rhs
    {
    _rhs = rhs;
    }
/****************************************************************************\
|* Dispatch to visitAssignExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitAssignExpr:)])
        [visitor visitAssignExpr:self];
    }
@end

@implementation XTCallExprNode
@synthesize forceInline = _forceInline;
@synthesize resolvedMangledName = _resolvedMangledName;
/****************************************************************************\
|* Create a function call expression node.
|* @param callee    The name of the function being called.
|* @param args      Array of argument expressions.
|* @param location  Source location of the callee identifier.
|* @return A new call expression node.
\****************************************************************************/
- (instancetype)initWithCallee:(NSString*)callee arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindCallExpr location:location];
    if (self)
        {
        _calleeName = [callee copy];
        _arguments = [args copy];
        _forceInline = NO;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitCallExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitCallExpr:)])
        [visitor visitCallExpr:self];
    }
@end

@implementation XTMethodCallExprNode
@synthesize resolvedMangledName = _resolvedMangledName;
/****************************************************************************\
|* Create a method call expression node (receiver.method(args)).
|* @param receiver    The receiver expression (object the method is called on).
|* @param methodName  The method name being invoked.
|* @param args        Array of argument expressions.
|* @param location    Source location of the method name.
|* @return A new method call expression node.
\****************************************************************************/
- (instancetype)initWithReceiver:(XTASTNode*)receiver methodName:(NSString*)methodName arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindMethodCallExpr location:location];
    if (self)
        {
        _receiver = receiver;
        _methodName = [methodName copy];
        _arguments = [args copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitMethodCallExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitMethodCallExpr:)])
        [visitor visitMethodCallExpr:self];
    }
@end

@implementation XTSubscriptExprNode
/****************************************************************************\
|* Create a subscript (array indexing) expression node.
|* @param base      The array or pointer expression.
|* @param index     The index expression.
|* @param location  Source location of the opening bracket.
|* @return A new subscript expression node.
\****************************************************************************/
- (instancetype)initWithBase:(XTASTNode*)base index:(XTASTNode*)index location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindSubscriptExpr location:location];
    if (self)
        {
        _base = base;
        _index = index;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitSubscriptExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitSubscriptExpr:)])
        [visitor visitSubscriptExpr:self];
    }
@end

@implementation XTSliceExprNode
- (instancetype)initWithBase:(XTASTNode*)base
                   startExpr:(XTASTNode*)startExpr
                     endExpr:(XTASTNode*)endExpr
                   inclusive:(BOOL)inclusive
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindSliceExpr location:location];
    if (self)
        {
        _base = base;
        _startExpr = startExpr;
        _endExpr = endExpr;
        _inclusive = inclusive;
        }
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitSliceExpr:)])
        [visitor visitSliceExpr:self];
    }
@end

@implementation XTRangeExprNode
- (instancetype)initWithStart:(XTASTNode*)startExpr
                          end:(XTASTNode*)endExpr
                    inclusive:(BOOL)inclusive
                     location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindRangeExpr location:location];
    if (self)
        {
        _startExpr = startExpr;
        _endExpr = endExpr;
        _inclusive = inclusive;
        }
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitRangeExpr:)])
        [visitor visitRangeExpr:self];
    }
@end

@implementation XTMemberAccessNode
/****************************************************************************\
|* Create a member-access expression node (dot or arrow).
|* @param base      The struct/class expression.
|* @param member    The name of the member being accessed.
|* @param isArrow   YES for '->' (pointer dereference + access), NO for '.'.
|* @param location  Source location of the dot or arrow token.
|* @return A new member access node.
\****************************************************************************/
- (instancetype)initWithBase:(XTASTNode*)base memberName:(NSString*)member isArrow:(BOOL)isArrow location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindMemberAccess location:location];
    if (self)
        {
        _base = base;
        _memberName = [member copy];
        _isArrow = isArrow;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitMemberAccess: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitMemberAccess:)])
        [visitor visitMemberAccess:self];
    }
@end

@implementation XTTernaryExprNode
/****************************************************************************\
|* Create a ternary conditional expression node (cond ? then : else).
|* @param condition  The boolean condition expression.
|* @param thenExpr   The expression evaluated when the condition is true.
|* @param elseExpr   The expression evaluated when the condition is false.
|* @param location   Source location of the '?' token.
|* @return A new ternary expression node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition thenExpr:(XTASTNode*)thenExpr elseExpr:(XTASTNode*)elseExpr location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindTernaryExpr location:location];
    if (self)
        {
        _condition = condition;
        _thenExpr = thenExpr;
        _elseExpr = elseExpr;
        }
    return self;
    }
- (void)replaceThenExpr:(XTASTNode*)thenExpr
    {
    _thenExpr = thenExpr;
    }
- (void)replaceElseExpr:(XTASTNode*)elseExpr
    {
    _elseExpr = elseExpr;
    }
/****************************************************************************\
|* Dispatch to visitTernaryExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitTernaryExpr:)])
        [visitor visitTernaryExpr:self];
    }
@end

@implementation XTCastExprNode
/****************************************************************************\
|* Create a type-cast expression node. Sets resolvedType to castType immediately.
|* @param type      The target type to cast to.
|* @param operand   The expression being cast.
|* @param location  Source location of the cast.
|* @return A new cast expression node.
\****************************************************************************/
- (instancetype)initWithType:(XTType*)type operand:(XTASTNode*)operand location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindCastExpr location:location];
    if (self)
        {
        _castType = type;
        _operand = operand;
        self.resolvedType = type;
        }
    return self;
    }
- (void)replaceOperand:(XTASTNode*)operand
    {
    _operand = operand;
    }
/****************************************************************************\
|* Visit the cast. If the visitor implements visitCastExpr: (sema uses
|* this to propagate the cast's target type as the expected-type hint
|* during operand resolution, so overloaded calls like
|* `(double)Math.PI()` pick the double overload), dispatch there.
|* Otherwise fall back to visiting the operand directly.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitCastExpr:)])
        {
        [visitor visitCastExpr:self];
        }
    else
        {
        [_operand acceptVisitor:visitor];
        }
    }
@end

@implementation XTIdentifierNode
/****************************************************************************\
|* Create an identifier reference node.
|* @param name      The identifier string.
|* @param location  Source location of the identifier.
|* @return A new identifier node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindIdentifier location:location];
    if (self)
        {
        _identName = [name copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitIdentifier: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitIdentifier:)])
        [visitor visitIdentifier:self];
    }
@end

@implementation XTLiteralIntNode
/****************************************************************************\
|* Create an integer literal node.
|* @param value     The parsed 64-bit integer value.
|* @param location  Source location of the literal.
|* @return A new integer literal node.
\****************************************************************************/
- (instancetype)initWithValue:(int64_t)value location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLiteralInt location:location];
    if (self)
        {
        _intValue = value;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitLiteralInt: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLiteralInt:)])
        [visitor visitLiteralInt:self];
    }
@end

@implementation XTLiteralFloatNode
/****************************************************************************\
|* Create a float literal node from pre-encoded 5-byte data.
|* @param data      The 5-byte encoded float data (produced at lex time).
|* @param location  Source location of the literal.
|* @return A new float literal node.
\****************************************************************************/
- (instancetype)initWithFloatData:(NSData*)data location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLiteralFloat location:location];
    if (self)
        {
        _floatData = data;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitLiteralFloat: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLiteralFloat:)])
        [visitor visitLiteralFloat:self];
    }
@end

@implementation XTLiteralStringNode
/****************************************************************************\
|* Create a string literal node.
|* @param value     The string content (escape sequences already resolved).
|* @param location  Source location of the opening quote.
|* @return A new string literal node.
\****************************************************************************/
- (instancetype)initWithString:(NSString*)value location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLiteralString location:location];
    if (self)
        {
        _stringValue = [value copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitLiteralString: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLiteralString:)])
        [visitor visitLiteralString:self];
    }
@end

@implementation XTLiteralCharNode
/****************************************************************************\
|* Create a character literal node.
|* @param value     The character value as an unsigned byte.
|* @param location  Source location of the opening quote.
|* @return A new character literal node.
\****************************************************************************/
- (instancetype)initWithChar:(uint8_t)value location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLiteralChar location:location];
    if (self)
        {
        _charValue = value;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitLiteralChar: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLiteralChar:)])
        [visitor visitLiteralChar:self];
    }
@end

@implementation XTLiteralBoolNode
/****************************************************************************\
|* Create a boolean literal node (true or false).
|* @param value     The boolean value.
|* @param location  Source location of the literal.
|* @return A new boolean literal node.
\****************************************************************************/
- (instancetype)initWithBool:(BOOL)value location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLiteralBool location:location];
    if (self)
        {
        _boolValue = value;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitLiteralBool: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLiteralBool:)])
        [visitor visitLiteralBool:self];
    }
@end

@implementation XTNewExprNode
/****************************************************************************\
|* Create a 'new' heap-allocation expression node.
|* @param name      The class name to instantiate.
|* @param args      Array of constructor argument expressions.
|* @param location  Source location of the 'new' keyword.
|* @return A new 'new' expression node.
\****************************************************************************/
- (instancetype)initWithClassName:(NSString*)name arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location
    {
    return [self initWithClassName:name arguments:args countExpr:nil location:location];
    }
- (instancetype)initWithClassName:(NSString*)name
                        arguments:(NSArray<XTASTNode*>*)args
                        countExpr:(nullable XTASTNode*)count
                         location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindNewExpr location:location];
    if (self)
        {
        _className = [name copy];
        _arguments = [args copy];
        _countExpr = count;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitNewExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitNewExpr:)])
        [visitor visitNewExpr:self];
    }
@end

@implementation XTSizeofExprNode
/****************************************************************************\
|* Create a sizeof expression node.
|* @param operand   Either an XTType (for sizeof(type)) or an XTASTNode
|*                  (for sizeof(expr)).
|* @param location  Source location of the 'sizeof' keyword.
|* @return A new sizeof expression node.
\****************************************************************************/
- (instancetype)initWithOperand:(id)operand location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindSizeofExpr location:location];
    if (self)
        {
        _operand = operand;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitSizeofExpr: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitSizeofExpr:)])
        [visitor visitSizeofExpr:self];
    }
@end
