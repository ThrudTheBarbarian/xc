#import "XTStmtNodes.h"

@implementation XTBlockNode
@synthesize isDeclList = _isDeclList;
/****************************************************************************\
|* Create a block node containing a sequence of statements.
|* @param statements  The ordered array of statements in this block.
|* @param location    Source location of the opening brace or '(('.
|* @return A new block node.
\****************************************************************************/
- (instancetype)initWithStatements:(NSArray<XTASTNode*>*)statements location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindBlock location:location];
    if (self)
        {
        _statements = [statements copy];
        _isDeclList = NO;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitBlock: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitBlock:)])
        [visitor visitBlock:self];
    }
@end

@implementation XTIfNode
/****************************************************************************\
|* Create an if-statement node with optional else branch.
|* @param condition  The boolean condition expression.
|* @param thenBlock  The block executed when the condition is true.
|* @param elseBlock  The else block, or nil when there is no else branch.
|* @param location   Source location of the 'if' keyword.
|* @return A new if node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition thenBlock:(XTASTNode*)thenBlock elseBlock:(nullable XTASTNode*)elseBlock location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindIf location:location];
    if (self)
        {
        _condition = condition;
        _thenBlock = thenBlock;
        _elseBlock = elseBlock;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitIf: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitIf:)])
        [visitor visitIf:self];
    }
@end

@implementation XTWhileNode
/****************************************************************************\
|* Create a while-loop node.
|* @param condition  The loop condition expression.
|* @param body       The loop body block.
|* @param location   Source location of the 'while' keyword.
|* @return A new while node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition body:(XTASTNode*)body location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindWhile location:location];
    if (self)
        {
        _condition = condition;
        _body = body;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitWhile: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitWhile:)])
        [visitor visitWhile:self];
    }
@end

@implementation XTForCStyleNode
@synthesize forceUnroll = _forceUnroll;
/****************************************************************************\
|* Create a C-style for-loop node. Any of init/condition/increment may be nil.
|* @param loopInit   The initialisation statement, or nil.
|* @param condition  The loop condition expression, or nil (infinite loop).
|* @param increment  The per-iteration increment expression, or nil.
|* @param body       The loop body block.
|* @param location   Source location of the 'for' keyword.
|* @return A new C-style for node.
\****************************************************************************/
- (instancetype)initWithLoopInit:(nullable XTASTNode*)loopInit condition:(nullable XTASTNode*)condition increment:(nullable XTASTNode*)increment body:(XTASTNode*)body location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindForCStyle location:location];
    if (self)
        {
        _loopInit = loopInit;
        _condition = condition;
        _increment = increment;
        _body = body;
        _forceUnroll = NO;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitForCStyle: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitForCStyle:)])
        [visitor visitForCStyle:self];
    }
@end

@implementation XTForInNode
/****************************************************************************\
|* Create a for-in loop node (range-based iteration over an array).
|* @param loopVar     The loop variable declaration node.
|* @param collection  The array or collection expression to iterate over.
|* @param body        The loop body block.
|* @param location    Source location of the 'for' keyword.
|* @return A new for-in node.
\****************************************************************************/
- (instancetype)initWithLoopVar:(XTASTNode*)loopVar collection:(XTASTNode*)collection body:(XTASTNode*)body location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindForIn location:location];
    if (self)
        {
        _loopVar = loopVar;
        _collection = collection;
        _body = body;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitForIn: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitForIn:)])
        [visitor visitForIn:self];
    }
@end

@implementation XTReturnNode
/****************************************************************************\
|* Create a return statement node.
|* @param values    The return value expressions (empty array for void returns).
|* @param location  Source location of the 'return' keyword.
|* @return A new return node.
\****************************************************************************/
- (instancetype)initWithValues:(NSArray<XTASTNode*>*)values location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindReturn location:location];
    if (self)
        {
        _values = [values copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitReturn: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitReturn:)])
        [visitor visitReturn:self];
    }
@end

@implementation XTGotoNode
- (instancetype)initWithTargetLabel:(NSString*)label location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindGoto location:location];
    if (self)
        _targetLabel = [label copy];
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitGoto:)])
        [visitor visitGoto:self];
    }
@end
@implementation XTLabelNode
- (instancetype)initWithLabelName:(NSString*)name location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindLabel location:location];
    if (self)
        _labelName = [name copy];
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitLabel:)])
        [visitor visitLabel:self];
    }
@end
@implementation XTBreakNode
/****************************************************************************\
|* Create a break statement node.
|* @param location  Source location of the 'break' keyword.
|* @return A new break node.
\****************************************************************************/
- (instancetype)initWithLocation:(XTSourceLocation*)location
    {
    return [super initWithKind:XTASTNodeKindBreak location:location];
    }
/****************************************************************************\
|* Dispatch to visitBreak: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitBreak:)])
        [visitor visitBreak:self];
    }
@end

@implementation XTContinueNode
/****************************************************************************\
|* Create a continue statement node.
|* @param location  Source location of the 'continue' keyword.
|* @return A new continue node.
\****************************************************************************/
- (instancetype)initWithLocation:(XTSourceLocation*)location
    {
    return [super initWithKind:XTASTNodeKindContinue location:location];
    }
/****************************************************************************\
|* Dispatch to visitContinue: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitContinue:)])
        [visitor visitContinue:self];
    }
@end

@implementation XTDeferNode
/****************************************************************************\
|* Create a defer statement node.
|* @param body      The block to run when the enclosing scope exits.
|* @param location  Source location of the 'defer' keyword.
|* @return A new defer node.
\****************************************************************************/
- (instancetype)initWithBody:(XTASTNode*)body
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindDefer location:location];
    if (self)
        _body = body;
    return self;
    }

/****************************************************************************\
|* Dispatch to visitDefer: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitDefer:)])
        [visitor visitDefer:self];
    }
@end

@implementation XTThrowNode
- (instancetype)initWithOperand:(XTASTNode*)operand
                       location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindThrow location:location];
    if (self)
        _operand = operand;
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitThrow:)])
        [visitor visitThrow:self];
    }
@end

@implementation XTCatchClause
@end

@implementation XTTryNode
- (instancetype)initWithTryBlock:(XTASTNode*)tryBlock
                    catchClauses:(NSArray<XTCatchClause*>*)catchClauses
                        location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindTry location:location];
    if (self)
        {
        _tryBlock = tryBlock;
        _catchClauses = [catchClauses copy];
        }
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitTry:)])
        [visitor visitTry:self];
    }
@end

@implementation XTDeleteNode
- (instancetype)initWithOperand:(XTASTNode*)operand
                       location:(XTSourceLocation*)location
    {
    return [self initWithOperand:operand op:XTRefOpDelete location:location];
    }
- (instancetype)initWithOperand:(XTASTNode*)operand
                             op:(XTRefOp)op
                       location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindDelete location:location];
    if (self)
        {
        _operand = operand;
        _op = op;
        }
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitDelete:)])
        [visitor visitDelete:self];
    }
@end

@implementation XTCaseLabel
- (instancetype)initWithSingleValue:(XTASTNode*)value
                           location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _singleValue = value;
        _isRange = NO;
        _location = location;
        }
    return self;
    }
- (instancetype)initWithRangeLo:(nullable XTASTNode*)lo
                        rangeHi:(nullable XTASTNode*)hi
                       location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _rangeLo = lo;
        _rangeHi = hi;
        _isRange = YES;
        _location = location;
        }
    return self;
    }
@end

@implementation XTSwitchCase
- (instancetype)initWithLabels:(NSArray<XTCaseLabel*>*)labels
                          body:(NSArray<XTASTNode*>*)body
                     isDefault:(BOOL)isDefault
                      location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _labels = [labels copy];
        _body = [body copy];
        _isDefault = isDefault;
        _location = location;
        }
    return self;
    }
@end

@implementation XTSwitchNode
/****************************************************************************\
|* Create a switch-statement node.
|* @param subject   The expression whose value selects a case.
|* @param cases     Ordered list of XTSwitchCase arms.
|* @param location  Source location of the 'switch' keyword.
|* @return A new switch node.
\****************************************************************************/
- (instancetype)initWithSubject:(XTASTNode*)subject
                          cases:(NSArray<XTSwitchCase*>*)cases
                       location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindSwitch location:location];
    if (self)
        {
        _subject = subject;
        _cases = [cases copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitSwitch: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitSwitch:)])
        [visitor visitSwitch:self];
    }
@end

@implementation XTAsmBlockNode
@synthesize userClobbers = _userClobbers;
/****************************************************************************\
|* Create an inline assembly block node.
|* @param lines     Array of raw assembly source lines.
|* @param location  Source location of the 'asm' keyword.
|* @return A new asm block node with userClobbers defaulting to -1.
\****************************************************************************/
- (instancetype)initWithLines:(NSArray<NSString*>*)lines location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindAsmBlock location:location];
    if (self)
        {
        _lines = [lines copy];
        _userClobbers = -1;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitAsmBlock: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitAsmBlock:)])
        [visitor visitAsmBlock:self];
    }
@end

@implementation XTExpressionStatementNode
/****************************************************************************\
|* Create an expression-statement node (an expression used as a statement).
|* @param expression  The expression being executed for its side effects.
|* @param location    Source location of the expression.
|* @return A new expression statement node.
\****************************************************************************/
- (instancetype)initWithExpression:(XTASTNode*)expression location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindExprStatement location:location];
    if (self)
        {
        _expression = expression;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitExprStatement: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitExprStatement:)])
        [visitor visitExprStatement:self];
    }
@end

@implementation XTTupleAssignNode
/****************************************************************************\
|* Create a tuple-assignment node for unpacking multiple return values.
|* @param targets     Array of target nodes (variable decls or identifiers).
|* @param sourceExpr  The expression producing the tuple (typically a call).
|* @param location    Source location of the opening parenthesis.
|* @return A new tuple assignment node.
\****************************************************************************/
- (instancetype)initWithTargets:(NSArray<XTASTNode*>*)targets sourceExpr:(XTASTNode*)sourceExpr location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindTupleAssign location:location];
    if (self)
        {
        _targets = [targets copy];
        _sourceExpr = sourceExpr;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitTupleAssign: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitTupleAssign:)])
        [visitor visitTupleAssign:self];
    }
@end
