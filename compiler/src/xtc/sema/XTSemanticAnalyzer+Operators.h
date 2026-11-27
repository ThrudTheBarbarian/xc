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
@class XTAssignExprNode;
@class XTMethodDeclNode;
@class XTClassDeclNode;

NS_ASSUME_NONNULL_BEGIN

@interface XTSemanticAnalyzer (Operators)
/****************************************************************************\
|* Check every `:operator(pattern)` in the program against its method: each
|* operand name is `self` or a parameter, once; every parameter appears; an
|* instance method's pattern uses `self` and a static one's does not; the
|* method returns one value; a static operator has an operand of its class.
|* Refuses the annotation on a free function and on an `optional` protocol
|* method, and reports a pattern the parser could not take.
\****************************************************************************/
- (void)checkOperatorMethods:(XTProgramNode*)program;
/****************************************************************************\
|* A protocol requirement that is an operator (`req`), implemented by `impl`
|* (found in `implCls`) for `cls`, which conforms to protocol `pname`: the
|* implementing method must be the same operator, the same shape with the
|* operands in the same roles. An override is the operator of the method it
|* overrides. Reports what to write when it is not.
\****************************************************************************/
- (void)checkOperatorRequirement:(XTMethodDeclNode*)req
                        protocol:(NSString*)pname
                            impl:(XTMethodDeclNode*)impl
                              in:(XTClassDeclNode*)implCls
                           class:(XTClassDeclNode*)cls;
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
/****************************************************************************\
|* `m[i]`, `m[i, j]` or `m[a..b]` on a class with an index operator: the get
|* call, or nothing yet for the target of an assignment (`target`). Returns NO
|* when the base's class has no index operator, so the built-in index applies.
\****************************************************************************/
- (BOOL)resolveIndexOperatorOf:(XTASTNode*)node target:(BOOL)target;
// `t.permute(p0, …)` on a tensor class `cls`: a permutation of its
// dimensions, as integer literals. NO after reporting what is wrong.
- (BOOL)tensorPermuteOK:(XTMethodCallExprNode*)node cls:(NSString*)cls;
/****************************************************************************\
|* An assignment through an operator: the index set (`m[i] = v`), get, op and
|* set for `m[i] += v`, the compound operator (`a += b`), or `a = a + b` when
|* the class defines `+` and no `+=` that matches. Returns NO when none
|* applies. Operands are analysed.
\****************************************************************************/
- (BOOL)resolveOperatorOfAssign:(XTAssignExprNode*)node;
/****************************************************************************\
|* An expression read two ways (an operator a class defines whose characters
|* also read the old way, `a**b`): `node` holds the new reading, `alt` the old
|* one. The operator reading is kept when an operand's class defines each such
|* operator in it, the old one when none does; both type-checking, or some
|* defined and some not, is an error. `node` is analysed as the one kept.
\****************************************************************************/
- (void)chooseReadingOf:(XTASTNode*)node alternative:(XTASTNode*)alt;
@end

NS_ASSUME_NONNULL_END
