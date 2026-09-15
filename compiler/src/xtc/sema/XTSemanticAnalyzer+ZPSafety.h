/****************************************************************************\
|* XTSemanticAnalyzer+ZPSafety.h
|*
|* Methods extracted from XTSemanticAnalyzer.m for manageable file size.
\****************************************************************************/
#import "XTSemanticAnalyzer.h"
#import "XTEnumType.h"
#import "XTStructType.h"
#import "XTFunctionType.h"

@class XTASTNode;
@class XTType;
@class XTSourceLocation;
@class XTClassDeclNode;
@class XTPointerType;
@class XTMemberAccessNode;
@class XTCallExprNode;
@class XTBinaryExprNode;
@class XTMethodCallExprNode;
@class XTUnaryExprNode;
@class XTPostfixExprNode;
@class XTAssignExprNode;
@class XTSubscriptExprNode;
@class XTNewExprNode;
@class XTSizeofExprNode;
@class XTCastExprNode;
@class XTTernaryExprNode;
@class XTBlockNode;
@class XTIfNode;
@class XTWhileNode;
@class XTReturnNode;
@class XTSwitchNode;
@class XTForNode;
@class XTForCStyleNode;
@class XTForInNode;
@class XTAsmIdentNode;
@class XTAsmLabelNode;
@class XTBreakNode;
@class XTContinueNode;
@class XTAsmBlockNode;
@class XTDeleteNode;
@class XTTupleAssignNode;
@class XTVariableDeclNode;
@class XTFunctionDeclNode;
@class XTMethodDeclNode;
@class XTEnumDeclNode;
@class XTStructDeclNode;
@class XTTypedefDeclNode;
@class XTProtocolDeclNode;
@class XTParamNode;
@class XTProgramNode;
@class XTLiteralIntNode;
@class XTLiteralStringNode;
@class XTLiteralFloatNode;
@class XTLiteralCharNode;
@class XTLiteralBoolNode;
@class XTIdentifierNode;
@class XTExpressionStatementNode;

NS_ASSUME_NONNULL_BEGIN

@interface XTSemanticAnalyzer (ZPSafety)

- (NSString*)labelForFunction:(XTFunctionDeclNode*)fn;
- (NSString*)labelForMethod:(XTMethodDeclNode*)m;
- (nullable NSString*)bodyStackSignalReason:(XTASTNode*)node;
- (BOOL)asmBlockTouchesXtcStack:(XTAsmBlockNode*)blk;
- (void)recordCallEdgeToLabel:(NSString*)calleeLabel;
- (void)classifyFunctionStackUse:(XTFunctionDeclNode*)fn
                           label:(NSString*)label;
- (void)classifyMethodStackUse:(XTMethodDeclNode*)m
                         label:(NSString*)label;
- (void)visitClassDecl:(XTClassDeclNode*)node;
- (void)validateWeakQualifierOnType:(nullable XTType*)t
                                 at:(XTSourceLocation*)loc
                     allowBankedKey:(BOOL)allowBankedKey;
- (void)validateWeakQualifierOnType:(nullable XTType*)t
                                 at:(XTSourceLocation*)loc;
- (void)visitVariableDecl:(XTVariableDeclNode*)node;
- (XTType*)inferTypeFromLiteral:(XTASTNode*)node;
- (void)visitStructDecl:(XTStructDeclNode*)node;
- (void)visitTypedefDecl:(XTTypedefNode*)node;
- (void)visitEnumDecl:(XTEnumDeclNode*)node;
- (void)visitBlock:(XTBlockNode*)node;
- (void)visitIf:(XTIfNode*)node;
- (void)visitWhile:(XTWhileNode*)node;
- (void)visitForCStyle:(XTForCStyleNode*)node;
- (void)visitForIn:(XTForInNode*)node;
- (void)visitReturn:(XTReturnNode*)node;
- (void)checkClassPointerAssign:(nullable XTType*)lhsType
                        rhsType:(nullable XTType*)rhsType
                        rhsNode:(XTASTNode*)rhsNode
                           site:(NSString*)site
                       location:(XTSourceLocation*)loc;
- (nullable NSNumber*)caseConstantValueOf:(XTASTNode*)expr;
- (void)visitSwitch:(XTSwitchNode*)node;
- (void)visitBreak:(XTASTNode*)node;
- (void)visitContinue:(XTASTNode*)node;
- (void)visitDelete:(XTDeleteNode*)node;
- (void)visitAsmBlock:(XTASTNode*)node;
- (void)visitExprStatement:(XTExpressionStatementNode*)node;
- (void)visitTupleAssign:(XTTupleAssignNode*)node;
- (void)visitBinaryExpr:(XTBinaryExprNode*)node;
- (void)foldBinaryExpr:(XTBinaryExprNode*)node;
- (void)visitUnaryExpr:(XTUnaryExprNode*)node;
- (void)visitPostfixExpr:(XTPostfixExprNode*)node;
- (void)visitAssignExpr:(XTAssignExprNode*)node;

@end

NS_ASSUME_NONNULL_END
