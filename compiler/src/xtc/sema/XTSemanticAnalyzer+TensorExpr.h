/****************************************************************************\
|* XTSemanticAnalyzer+TensorExpr.h
|*
|* Element-wise tensor expressions: arithmetic, comparisons, unary minus,
|* casts and Math functions over tensors (and scalars), read as one tree for
|* each expression and computed by one kernel; a write into a view, and a
|* compound assignment, in place.
\****************************************************************************/
#import "XTSemanticAnalyzer.h"

@class XTBinaryExprNode;
@class XTUnaryExprNode;
@class XTAssignExprNode;
@class XTCastExprNode;
@class XTMethodCallExprNode;

NS_ASSUME_NONNULL_BEGIN

@interface XTSemanticAnalyzer (TensorExpr)
// Each takes an analysed node; YES when it is a tensor expression, typed (or
// reported), NO to leave it to the usual rules.
- (BOOL)tensorExprBinary:(XTBinaryExprNode*)node;
- (BOOL)tensorExprUnary:(XTUnaryExprNode*)node;
- (BOOL)tensorExprCast:(XTCastExprNode*)node;
// `Math.f(t, …)`: analyses the arguments first.
- (BOOL)tensorExprMath:(XTMethodCallExprNode*)node;
// `t[.., ..] = v` and `t op= v`: in place.
- (BOOL)tensorExprAssign:(XTAssignExprNode*)node;
// A tensor written as a condition (`if (a == b)`) is refused.
- (void)tensorRefuseCondition:(XTASTNode*)cond;
// The kernels the unit's expressions need, by signature, sorted.
- (NSArray<NSString*>*)tensorKernelRequests;
@end

NS_ASSUME_NONNULL_END
