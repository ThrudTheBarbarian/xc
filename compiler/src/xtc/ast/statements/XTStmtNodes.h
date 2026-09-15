#import "XTASTNode.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* XTBlockNode
\****************************************************************************/
@interface XTBlockNode : XTASTNode
@property(nonatomic, readonly) NSArray<XTASTNode*>* statements;
/****************************************************************************\
|* YES for synthetic declaration-list blocks (e.g. "u8 a, b, c;") that should not push a scope.
\****************************************************************************/
@property(nonatomic) BOOL isDeclList;
/****************************************************************************\
|* Create a block node containing a sequence of statements.
|* @param statements  The ordered array of statements in this block.
|* @param location    Source location of the opening brace or '(('.
|* @return A new block node.
\****************************************************************************/
- (instancetype)initWithStatements:(NSArray<XTASTNode*>*)statements
                          location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTIfNode
\****************************************************************************/
@interface XTIfNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* condition;
@property(nonatomic, readonly) XTASTNode* thenBlock;
@property(nonatomic, readonly, nullable) XTASTNode* elseBlock;
/****************************************************************************\
|* Create an if-statement node with optional else branch.
|* @param condition  The boolean condition expression.
|* @param thenBlock  The block executed when the condition is true.
|* @param elseBlock  The else block, or nil when there is no else branch.
|* @param location   Source location of the 'if' keyword.
|* @return A new if node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition
                        thenBlock:(XTASTNode*)thenBlock
                        elseBlock:(nullable XTASTNode*)elseBlock
                         location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTWhileNode
\****************************************************************************/
@interface XTWhileNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* condition;
@property(nonatomic, readonly) XTASTNode* body;
/****************************************************************************\
|* Create a while-loop node.
|* @param condition  The loop condition expression.
|* @param body       The loop body block.
|* @param location   Source location of the 'while' keyword.
|* @return A new while node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition
                             body:(XTASTNode*)body
                         location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTForCStyleNode
\****************************************************************************/
@interface XTForCStyleNode : XTASTNode
@property(nonatomic, readonly, nullable) XTASTNode* loopInit;
@property(nonatomic, readonly, nullable) XTASTNode* condition;
@property(nonatomic, readonly, nullable) XTASTNode* increment;
@property(nonatomic, readonly) XTASTNode* body;
/****************************************************************************\
|* `for (...) :unroll { ... }` — force unrolling regardless of -Flu.
\****************************************************************************/
@property(nonatomic) BOOL forceUnroll;
/****************************************************************************\
|* Create a C-style for-loop node. Any of init/condition/increment may be nil.
|* @param loopInit   The initialisation statement, or nil.
|* @param condition  The loop condition expression, or nil (infinite loop).
|* @param increment  The per-iteration increment expression, or nil.
|* @param body       The loop body block.
|* @param location   Source location of the 'for' keyword.
|* @return A new C-style for node.
\****************************************************************************/
- (instancetype)initWithLoopInit:(nullable XTASTNode*)loopInit
                       condition:(nullable XTASTNode*)condition
                       increment:(nullable XTASTNode*)increment
                            body:(XTASTNode*)body
                        location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTForInNode
\****************************************************************************/
@interface XTForInNode : XTASTNode
/****************************************************************************\
|* loopVar and body are WRITABLE because sema rewrites them for a collection
|* with a PRIMITIVE element type: the element arrives boxed, so the loop binds
|* a hidden `Number*` and the body gains an unboxing declaration of the name
|* the user actually wrote (private:docs/bugs/039). `collection` is never rewritten.
\****************************************************************************/
@property(nonatomic) XTASTNode* loopVar; // XTVariableDeclNode
@property(nonatomic, readonly) XTASTNode* collection;
@property(nonatomic) XTASTNode* body;
/****************************************************************************\
|* Create a for-in loop node (range-based iteration over an array).
|* @param loopVar     The loop variable declaration node.
|* @param collection  The array or collection expression to iterate over.
|* @param body        The loop body block.
|* @param location    Source location of the 'for' keyword.
|* @return A new for-in node.
\****************************************************************************/
- (instancetype)initWithLoopVar:(XTASTNode*)loopVar
                     collection:(XTASTNode*)collection
                           body:(XTASTNode*)body
                       location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTReturnNode
\****************************************************************************/
@interface XTReturnNode : XTASTNode
/****************************************************************************\
|* Empty for void functions.
\****************************************************************************/
@property(nonatomic) NSArray<XTASTNode*>* values;
/****************************************************************************\
|* Create a return statement node.
|* @param values    The return value expressions (empty array for void returns).
|* @param location  Source location of the 'return' keyword.
|* @return A new return node.
\****************************************************************************/
- (instancetype)initWithValues:(NSArray<XTASTNode*>*)values
                      location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTBreakNode / XTContinueNode
\****************************************************************************/
@interface XTBreakNode : XTASTNode
/****************************************************************************\
|* Create a break statement node.
|* @param location  Source location of the 'break' keyword.
|* @return A new break node.
\****************************************************************************/
- (instancetype)initWithLocation:(XTSourceLocation*)location;
@end

@interface XTGotoNode : XTASTNode
// `goto <label>;` — a porting aid for C code (not promoted in the language docs).
@property(nonatomic, copy) NSString* targetLabel;
- (instancetype)initWithTargetLabel:(NSString*)label location:(XTSourceLocation*)location;
@end
@interface XTLabelNode : XTASTNode
// `<name>:` at statement position — a goto target.
@property(nonatomic, copy) NSString* labelName;
- (instancetype)initWithLabelName:(NSString*)name location:(XTSourceLocation*)location;
@end
@interface XTContinueNode : XTASTNode
/****************************************************************************\
|* Create a continue statement node.
|* @param location  Source location of the 'continue' keyword.
|* @return A new continue node.
\****************************************************************************/
- (instancetype)initWithLocation:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* Reference-count operation performed on a heap pointer by XTDeleteNode.
|*   XTRefOpDelete  — decrement refcount, free when it hits 0 (identical
|*                    to XTRefOpRelease; `delete ptr;` is preserved as a
|*                    deprecated synonym for `release ptr;`).
|*   XTRefOpRetain  — increment refcount (saturates at 255).
|*   XTRefOpRelease — decrement refcount, free when it hits 0.
\****************************************************************************/
typedef NS_ENUM(NSInteger, XTRefOp) {
    XTRefOpDelete,
    XTRefOpRetain,
    XTRefOpRelease,
};

/****************************************************************************\
|* XTDeleteNode — `delete ptr;`, `retain ptr;`, or `release ptr;`.
|* All three share a single AST node carrying an `op` discriminator; the
|* operand must resolve to a heap pointer. For class pointers, the
|* `release`/`delete` paths emit a JSR to the class's dealloc() method
|* before freeing (array operands iterate dealloc() across all elements).
|* `retain` is always a simple refcount increment regardless of pointee.
\****************************************************************************/
/****************************************************************************\
|* `defer { ... }` — run the body when the enclosing scope exits, by ANY path:
|* falling off the end, `return`, `break`, `continue`. Multiple defers in one
|* scope run last-registered-first.
|*
|* It is a STATEMENT, not a value: the body is lowered inline at each exit of the
|* scope that registered it, so nothing is captured and nothing is allocated —
|* which is why this needs no closures, a feature the language does not have.
|* The body therefore reads its scope's locals directly, because it is emitted
|* in that scope.
|*
|* See private:docs/Design/exceptions-and-defer.md §4.
\****************************************************************************/
@interface XTDeferNode : XTASTNode
@property(nonatomic, strong) XTASTNode* body; // the block to run at exit
- (instancetype)initWithBody:(XTASTNode*)body
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* `throw expr;` — raise an error. Lowers to: store the value through the
|* function's hidden error out-parameter, run every enclosing scope's defers and
|* ARC teardown, and return. See private:docs/Design/exceptions-and-defer.md §5.
\****************************************************************************/
@interface XTThrowNode : XTASTNode
@property(nonatomic, strong) XTASTNode* operand; // the Error@ being raised
- (instancetype)initWithOperand:(XTASTNode*)operand
                       location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* One `catch` arm. `typeName` nil means the arm is untyped and catches
|* everything; otherwise the arm runs only when the in-flight error is an
|* instance of that class, tested with the same RTTI conformance check that
|* backs `(T@ ?)obj` — so it works across module boundaries for free.
\****************************************************************************/
@interface XTCatchClause : NSObject
@property(nonatomic, copy, nullable) NSString* typeName;
@property(nonatomic, copy) NSString* varName;
@property(nonatomic, strong) XTASTNode* block;
@property(nonatomic, strong) XTSourceLocation* location;
@end

/****************************************************************************\
|* `try { ... } catch (T e) { ... } catch (e) { ... }` — run the guarded block;
|* if a call in it raises, the first matching arm handles the error.
|*
|* Arms are tested in SOURCE ORDER, so a broader arm written first shadows the
|* ones after it — sema warns rather than silently dropping them.
\****************************************************************************/
@interface XTTryNode : XTASTNode
@property(nonatomic, strong) XTASTNode* tryBlock;
@property(nonatomic, copy) NSArray<XTCatchClause*>* catchClauses;
- (instancetype)initWithTryBlock:(XTASTNode*)tryBlock
                    catchClauses:(NSArray<XTCatchClause*>*)catchClauses
                        location:(XTSourceLocation*)location;
@end

@interface XTDeleteNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* operand;
@property(nonatomic, readonly) XTRefOp op;

- (instancetype)initWithOperand:(XTASTNode*)operand
                       location:(XTSourceLocation*)location;

- (instancetype)initWithOperand:(XTASTNode*)operand
                             op:(XTRefOp)op
                       location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTCaseLabel — one case label. Either a single value (`singleValue`
|* set, both range bounds nil) or a range (`rangeLo`/`rangeHi`, either
|* nullable for unbounded). `case 5..9:` has both bounds; `case ..5:`
|* has rangeHi only; `case 12..:` has rangeLo only.
\****************************************************************************/
@interface XTCaseLabel : NSObject
@property(nonatomic, readonly, nullable) XTASTNode* singleValue;
@property(nonatomic, readonly, nullable) XTASTNode* rangeLo;
@property(nonatomic, readonly, nullable) XTASTNode* rangeHi;
@property(nonatomic, readonly) BOOL isRange;
@property(nonatomic, readonly) XTSourceLocation* location;
- (instancetype)initWithSingleValue:(XTASTNode*)value
                           location:(XTSourceLocation*)location;
- (instancetype)initWithRangeLo:(nullable XTASTNode*)lo
                        rangeHi:(nullable XTASTNode*)hi
                       location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTSwitchCase — one arm of a switch. `labels` is an ordered list of
|* XTCaseLabel (single values or ranges); when `isDefault`, `labels` is
|* empty. `body` is the array of statements that run when this arm
|* matches; fall-through to the next arm is C-style (terminate with
|* `break` to exit the switch).
\****************************************************************************/
@interface XTSwitchCase : NSObject
@property(nonatomic, readonly) NSArray<XTCaseLabel*>* labels;
@property(nonatomic, readonly) NSArray<XTASTNode*>* body;
@property(nonatomic, readonly) BOOL isDefault;
@property(nonatomic, readonly) XTSourceLocation* location;
- (instancetype)initWithLabels:(NSArray<XTCaseLabel*>*)labels
                          body:(NSArray<XTASTNode*>*)body
                     isDefault:(BOOL)isDefault
                      location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTSwitchNode — `switch (subject) { case V: ... default: ... }`.
|* Cases are in source order. Fall-through is C-style; `break` jumps to
|* the end of the switch.
\****************************************************************************/
@interface XTSwitchNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* subject;
@property(nonatomic, readonly) NSArray<XTSwitchCase*>* cases;
- (instancetype)initWithSubject:(XTASTNode*)subject
                          cases:(NSArray<XTSwitchCase*>*)cases
                       location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTAsmBlockNode
\****************************************************************************/
@interface XTAsmBlockNode : XTASTNode
/****************************************************************************\
|* Each element is a raw assembly source line (may reference visible symbols).
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* lines;
/****************************************************************************\
|* User-supplied `clobbers(...)` bitmask (bit 0 = A, 1 = X, 2 = Y).
|* -1 if the programmer didn't annotate the block. The codegen scans
|* the block and warns when the declared set is a strict subset of
|* the computed set; otherwise the annotation is advisory only.
\****************************************************************************/
@property(nonatomic) NSInteger userClobbers;
/****************************************************************************\
|* Create an inline assembly block node.
|* @param lines     Array of raw assembly source lines.
|* @param location  Source location of the 'asm' keyword.
|* @return A new asm block node with userClobbers defaulting to -1.
\****************************************************************************/
- (instancetype)initWithLines:(NSArray<NSString*>*)lines
                     location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTExpressionStatementNode
\****************************************************************************/
@interface XTExpressionStatementNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* expression;
/****************************************************************************\
|* Create an expression-statement node (an expression used as a statement).
|* @param expression  The expression being executed for its side effects.
|* @param location    Source location of the expression.
|* @return A new expression statement node.
\****************************************************************************/
- (instancetype)initWithExpression:(XTASTNode*)expression
                          location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTTupleAssignNode  e.g. (u8 a, i16 b) = myFunc();
\****************************************************************************/
@interface XTTupleAssignNode : XTASTNode
/****************************************************************************\
|* Each element is an XTVariableDeclNode (possibly with existing symbol) or XTIdentifierNode.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<XTASTNode*>* targets;
@property(nonatomic, readonly) XTASTNode* sourceExpr;
/****************************************************************************\
|* Create a tuple-assignment node for unpacking multiple return values.
|* @param targets     Array of target nodes (variable decls or identifiers).
|* @param sourceExpr  The expression producing the tuple (typically a call).
|* @param location    Source location of the opening parenthesis.
|* @return A new tuple assignment node.
\****************************************************************************/
- (instancetype)initWithTargets:(NSArray<XTASTNode*>*)targets
                     sourceExpr:(XTASTNode*)sourceExpr
                       location:(XTSourceLocation*)location;
@end

NS_ASSUME_NONNULL_END
