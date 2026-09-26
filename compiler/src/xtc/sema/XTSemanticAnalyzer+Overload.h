/****************************************************************************\
|* XTSemanticAnalyzer+Overload.h
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

@interface XTSemanticAnalyzer (Overload)

- (NSInteger)conversionRankFrom:(XTType*)argType
                             to:(XTType*)paramType
                       isIntLit:(BOOL)isIntLit
                       litValue:(int64_t)litValue;
- (nullable NSString*)autoboxClassNameForArgType:(nullable XTType*)argType
                                     toParamType:(nullable XTType*)paramType;
- (void)applyAutoboxToArguments:(XTASTNode*)callNode
                     paramTypes:(NSArray<XTType*>*)paramTypes;
- (nullable NSString*)numberAccessorForLhsType:(nullable XTType*)lhsType;
- (BOOL)canUnboxRhsType:(nullable XTType*)rhsType
              toLhsType:(nullable XTType*)lhsType;
- (nullable XTASTNode*)unboxRhs:(XTASTNode*)rhs
                      toLhsType:(XTType*)lhsType;
- (void)applyUnboxToArguments:(XTASTNode*)callNode
                   paramTypes:(NSArray<XTType*>*)paramTypes;
- (NSInteger)scoreCandidateParamTypes:(NSArray<XTType*>*)paramTypes
                            isVarArgs:(BOOL)isVarArgs
                            arguments:(NSArray<XTASTNode*>*)args;
- (void)checkStackInstanceStrongParamArgs:(NSArray<XTType*>*)paramTypes
                                arguments:(NSArray<XTASTNode*>*)arguments
                               calleeDesc:(NSString*)calleeDesc
                                 location:(XTSourceLocation*)loc;
- (void)checkThrowsEffectForMethod:(nullable XTMethodDeclNode*)chosen
                                at:(nullable XTSourceLocation*)loc;
- (XTASTNode*)unboxCollectionElement:(XTASTNode*)e;
- (void)checkVarargForwardAt:(nullable XTSourceLocation*)loc;
- (void)checkCovariantReturnOpportunities;
- (void)notePackingVariadicCall:(NSString*)callee at:(nullable XTSourceLocation*)loc;
- (id)tiebreakOverloadCandidates:(NSArray*)candidates
               returnTypeOfBlock:(XTType* (^)(id))returnTypeOf;
- (nullable XTType*)parameterHintForBareCall:(XTCallExprNode*)node argument:(NSUInteger)idx;
- (nullable XTType*)parameterHintForMethodCall:(XTMethodCallExprNode*)node argument:(NSUInteger)idx;
- (void)analyzeArgument:(XTASTNode*)arg withHint:(nullable XTType*)hint;
- (NSString*)describeArgTypes:(NSArray<XTASTNode*>*)args;
- (BOOL)checkArityOf:(NSString*)label
               fixed:(NSUInteger)fixed
           isVarArgs:(BOOL)isVarArgs
               given:(NSUInteger)given
            location:(nullable XTSourceLocation*)loc;
- (BOOL)checkIndirectCall:(XTCallExprNode*)node
                signature:(XTFunctionType*)ft
                    label:(NSString*)label;
- (void)checkMisfitArguments:(NSArray<XTASTNode*>*)args
                  paramTypes:(NSArray<XTType*>*)paramTypes
                      callee:(NSString*)callee
                    location:(nullable XTSourceLocation*)loc;
- (BOOL)resolveVarargsIntrinsic:(XTCallExprNode*)node;
- (BOOL)resolveArcIntrinsic:(XTCallExprNode*)node;
- (void)visitCallExpr:(XTCallExprNode*)node;
- (void)checkPrintfFormat:(NSString*)fmt
                arguments:(NSArray<XTASTNode*>*)args
               firstVaIdx:(NSUInteger)firstVaIdx
                 location:(XTSourceLocation*)loc
                 callName:(NSString*)callName;
- (NSArray*)fmtArgTypesForFormatString:(NSString*)fmt;
- (NSString*)expectedTypeForSpec:(NSString*)spec;
- (void)visitMethodCallExpr:(XTMethodCallExprNode*)node;
- (void)visitSubscriptExpr:(XTSubscriptExprNode*)node;
- (void)visitMemberAccess:(XTMemberAccessNode*)node;
- (void)visitTernaryExpr:(XTTernaryExprNode*)node;
- (void)visitIdentifier:(XTIdentifierNode*)node;
- (void)visitLiteralInt:(XTLiteralIntNode*)node;
- (void)visitLiteralFloat:(XTLiteralFloatNode*)node;
- (void)visitLiteralString:(XTLiteralStringNode*)node;
- (void)visitLiteralChar:(XTLiteralCharNode*)node;
- (void)visitLiteralBool:(XTLiteralBoolNode*)node;
- (void)visitNewExpr:(XTNewExprNode*)node;
- (void)visitSizeofExpr:(XTSizeofExprNode*)node;
- (void)visitCastExpr:(XTCastExprNode*)node;

@end

NS_ASSUME_NONNULL_END
