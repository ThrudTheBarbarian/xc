/****************************************************************************\
|* XTSemanticAnalyzer+Operators.h
|*
|* Overloaded operators: methods carrying `:operator(pattern)`, and the
|* operator expressions that resolve to them.
\****************************************************************************/
#import "XTSemanticAnalyzer.h"

@class XTProgramNode;
@class XTBinaryExprNode;
@class XTUnaryExprNode;

NS_ASSUME_NONNULL_BEGIN

@interface XTSemanticAnalyzer (Operators)
/****************************************************************************\
|* Check every `:operator(pattern)` in the program against its method: each
|* operand name is `self` or a parameter, once; every parameter appears; an
|* instance method's pattern uses `self` and a static one's does not; the
|* method returns one value; a static operator has an operand of its class.
|* Refuses the annotation on a free function or a protocol method, and
|* reports a pattern the parser could not take.
\****************************************************************************/
- (void)checkOperatorMethods:(XTProgramNode*)program;
/****************************************************************************\
|* Resolve `a OP b` against the operands' operator methods. Returns NO when
|* neither operand's class defines OP, so the built-in meaning applies; YES
|* when the node now has its operator call, or an error was reported.
\****************************************************************************/
- (BOOL)resolveOperatorOfBinary:(XTBinaryExprNode*)node;
/****************************************************************************\
|* The same for a prefix operator `OP a`.
\****************************************************************************/
- (BOOL)resolveOperatorOfUnary:(XTUnaryExprNode*)node;
@end

NS_ASSUME_NONNULL_END
