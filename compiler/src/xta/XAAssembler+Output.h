/****************************************************************************\
|* XAAssembler+Output.h
|*
|* Methods extracted from XAAssembler.m for manageable file size.
\****************************************************************************/
#import "XAAssembler+Private.h"

@class XASegment;

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

@interface XAAssembler (Output)

- (BOOL)writeXEX:(NSArray<XASegment*>*)segments
      entryPoint:(uint16_t)entry
          toFile:(NSString*)path;
- (BOOL)writePRG:(NSArray<XASegment*>*)segments
      entryPoint:(uint16_t)entry
          toFile:(NSString*)path;
- (BOOL)writeBankedXEX:(NSArray<XASegment*>*)segments
            entryPoint:(uint16_t)entry
                toFile:(NSString*)path;
- (nullable NSString*)generateListing;

@end

NS_ASSUME_NONNULL_END
