/****************************************************************************\
|* XTParser+ExprParser.h
|*
|* Methods extracted from XTParser.m for manageable file size.
\****************************************************************************/
#import "XTParser+Private.h"
#import "XTExprNodes.h"
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

@interface XTParser (ExprParser)

- (nullable XTASTNode*)parseExpression;
- (nullable XTASTNode*)parseExprWithMinPrec:(int)minPrec;
- (XTAssignOp)assignOpFromToken:(XTToken*)tok;
- (XTASTNode*)buildBinaryExpr:(XTToken*)op left:(XTASTNode*)left right:(XTASTNode*)right;
- (nullable XTASTNode*)parseUnary;
- (nullable XTASTNode*)parsePostfix;
- (nullable XTASTNode*)parsePostfixFrom:(XTASTNode*)base;
- (nullable XTASTNode*)parsePrimary;
- (NSArray<XTASTNode*>*)parseArgList;
- (nullable NSString*)vaArgTypedCalleeForType:(XTType*)ty
                                     location:(XTSourceLocation*)loc;

@end

NS_ASSUME_NONNULL_END
