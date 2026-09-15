/****************************************************************************\
|* XTParser+Private.h
|*
|* Shared private interface — class extension and helper imports.
\****************************************************************************/
#import "XTParser.h"
#import "XTDeclNodes.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTPointerType.h"
#import "XTFunctionType.h"
#import "XTArrayType.h"
#import "XTStructType.h"
#import "XTEnumType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTParser ()
@property(nonatomic) NSArray<XTToken*>* tokens;
@property(nonatomic) XTTypeTable* typeTable;
@property(nonatomic) XTDiagnosticEngine* diagnostics;
@property(nonatomic) NSUInteger pos;
@property(nonatomic) NSMutableSet<NSString*>* protocolNames;
// The `#package <name>` in force (arrives as the parser-level `package x;`
// the preprocessor emits): the host import namespace stamped onto bodyless
// (imported) top-level function declarations. nil = the default package.
@property(nonatomic, copy, nullable) NSString* currentPackage;
// Set by parseArgList when the list ended with a literal `...` — the vararg
// forwarding form. Read by the call-construction sites immediately after, the
// same way `outlet` below is. private:docs/bugs/047.
@property(nonatomic) BOOL sawVarargForward;
// Set by parseType when the type carried an `outlet` qualifier; the field-decl
// parser reads it immediately after its parseType call. Side-channel (not baked
// into the type) because `outlet` is field metadata, not a type distinction.
@property(nonatomic) BOOL lastTypeIsOutlet;
// Blocks (task #26): side-channel from blkParseTypeHeader to the
// declaration / parameter / literal sites, same pattern as lastTypeIsOutlet.
@property(nonatomic, copy, nullable) NSString* lastBlockDeclName;
@property(nonatomic, copy, nullable) NSString* lastBlockBaseName;
@property(nonatomic, strong, nullable) NSArray<XTParamNode*>* lastBlockParams;
@property(nonatomic, strong, nullable) XTType* lastBlockRet;
// v2: the declaration just parsed carried the `block:` write-back qualifier.
@property(nonatomic) BOOL lastTypeIsBlockWb;
@end

// Callbacks (0.5) — the named spelling of a bound method
// (XTParser+Callbacks.m). New SYNTAX for the existing `^` type, not a new
// type: both end in boundMethodTypeForSignature:, which interns by signature.
@class XTFunctionType;

@interface XTParser (Callbacks)
- (NSUInteger)resolveArraySizeExpr:(XTASTNode*)sizeExpr;
- (BOOL)cbKeywordAhead;
- (nullable XTType*)cbParseTypeHeader;
// Defined in XTParser.m. Shared with the `^` sigil form on purpose: it interns
// by signature, so both spellings land on one type object.
- (XTType*)boundMethodTypeForSignature:(XTFunctionType*)fn;
@end

// Blocks v1 — parse-time desugaring (XTParser+Blocks.m).
@interface XTParser (Blocks)
- (BOOL)blkKeywordAhead;
- (nullable XTType*)blkParseTypeHeader;
- (nullable XTASTNode*)blkParseLiteralExpression;
- (nullable XTASTNode*)blkParseLiteralBodyWithBase:(NSString*)baseName
                                               ret:(XTType*)ret
                                            params:(NSArray<XTParamNode*>*)params
                                          selfName:(nullable NSString*)selfName
                                                at:(XTSourceLocation*)loc;
- (NSArray<XTASTNode*>*)blkSynthesisedDeclsAt:(XTSourceLocation*)loc;
- (void)blkPushScope;
- (void)blkPopScope;
- (void)blkBind:(NSString*)name type:(nullable XTType*)type;
- (nullable NSDictionary*)blkLookup:(NSString*)name depth:(NSUInteger*)outDepth;
- (void)blkNoteIdentifierUse:(NSString*)name at:(XTSourceLocation*)loc;
- (void)blkMarkWb:(NSString*)name;
- (BOOL)blkIsWbValue:(nullable XTASTNode*)e;
- (void)blkMarkHoldsWb:(NSString*)name fromInit:(nullable XTASTNode*)init;
- (NSMutableArray*)blkFrames;
- (NSMutableArray*)blkScopes;
- (void)blkBindAuto:(NSString*)name fromInit:(nullable XTASTNode*)init;
- (NSMutableDictionary*)blkState;
- (NSMutableSet*)blkIvarNames;
- (NSMutableDictionary*)blkBases;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

@interface XTParser (CrossCat)
- (XTToken*)currentToken;
- (XTToken*)peekToken:(NSUInteger)offset;
- (XTToken*)advance;
- (BOOL)check:(XTTokenType)type;
- (BOOL)match:(XTTokenType)type;
- (nullable XTToken*)expect:(XTTokenType)type;
- (XTSourceLocation*)currentLocation;
- (nullable XTASTNode*)parseInitialiser;
- (nullable XTType*)parseType;
- (nullable XTType*)parseTypeOrAuto;
- (nullable XTASTNode*)parseStatement;
- (nullable XTASTNode*)parseDeclOrStatement;
- (nullable XTASTNode*)parseSubscriptIndex;
- (nullable XTBlockNode*)parseBlock;
- (BOOL)looksLikeQualifierPrefixedType;
- (BOOL)checkBlockOpen;
- (BOOL)looksLikeCastAhead;
- (BOOL)isQualifierKeyword:(NSString*)v;
- (BOOL)currentBeginsQualifierPrefix;
@end

#pragma clang diagnostic pop

NS_ASSUME_NONNULL_END
