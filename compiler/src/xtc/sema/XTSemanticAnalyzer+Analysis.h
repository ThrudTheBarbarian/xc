/****************************************************************************\
|* XTSemanticAnalyzer+Analysis.h
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

@interface XTSemanticAnalyzer (Analysis)

- (void)analyzeProgram:(XTProgramNode*)program;
- (void)propagateStackUseTransitively;
- (void)propagateExtendedRamUseTransitively;
- (void)validateCloakedDecls;
- (NSArray<NSString*>*)shortestChainFrom:(NSString*)start
                                 maxHops:(NSUInteger)cap;
- (void)validateVariadicNonReentrance;
- (NSArray<NSString*>*)shortestVariadicPathFrom:(NSString*)start
                                        maxHops:(NSUInteger)cap;
- (void)computeStaticFrameEligibility;
- (void)resolveClassHierarchy;
- (BOOL)class:(XTClassDeclNode*)sub inheritsFromOrEquals:(XTClassDeclNode*)sup;
- (BOOL)class:(XTClassDeclNode*)cls conformsToProtocol:(NSString*)protoName;
- (nullable XTMethodDeclNode*)zeroArgMethodNamed:(NSString*)name
                                         inClass:(XTClassDeclNode*)cls
                                   ownerClassOut:(NSString* _Nullable* _Nullable)ownerOut;
- (NSString*)propertySetterNameFor:(NSString*)ivarName;
- (nullable XTMethodDeclNode*)setterMethodNamed:(NSString*)setterName
                                        inClass:(XTClassDeclNode*)cls
                                 acceptingValue:(XTASTNode*)valueNode
                                  ownerClassOut:(NSString* _Nullable* _Nullable)ownerOut;
- (BOOL)methodSignaturesMatch:(XTMethodDeclNode*)a
                          and:(XTMethodDeclNode*)b;
- (void)wireSubclassInitChains;
- (void)wireSubclassDeallocChains;
- (void)countSuperCallsTo:(NSString*)methodName
                       in:(nullable XTASTNode*)node
                     into:(NSUInteger*)outCount;
- (void)computeOverriddenMethods;
- (void)computeVirtualMethodTables;
- (void)detectRecursiveFunctions;
- (void)computeMaxCallDepths;
- (NSInteger)depthOfLabel:(NSString*)label
                 visiting:(NSMutableSet<NSString*>*)visiting;
- (void)assignVarargsSlots:(XTProgramNode*)program;
- (void)analyzeNode:(XTASTNode*)node;

@end

NS_ASSUME_NONNULL_END
