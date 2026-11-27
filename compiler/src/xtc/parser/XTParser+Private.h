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
// :scan blocks made so far (#144): their generated names' suffix.
@property(nonatomic) NSUInteger scanSeq;
// A :scan for --par-style=auto: a loop that does not fit stays a loop, unreported.
@property(nonatomic) BOOL scanQuiet;
// Parsing what parScanExpand made: its own loops (the short-range one) are not scans again.
@property(nonatomic) NSUInteger scanInside;
// The scan expansion: its parts while its made code is parsed
// (parScanExpand), the bodies it has put in (scSplice), and the last
// refusal (scFail).
@property(nonatomic, strong, nullable) NSDictionary* scanSplice;
@property(nonatomic) NSUInteger scanSpliced;
@property(nonatomic, copy, nullable) NSString* scFailMsg;
@property(nonatomic, strong, nullable) XTSourceLocation* scFailLoc;
// The recogniser found a running total (#144): its variable and operator.
@property(nonatomic, copy, nullable) NSString* parScanAcc;
@property(nonatomic, copy, nullable) NSString* parScanOp;
// XC_PAR_AUTO_TRACE (parAutoTraceLine): the rule that kept the loop the
// recogniser last read serial, the grid levels its nest may take
// (parAutoGridCap), and whether parAutoFor's loop was a `while`.
@property(nonatomic, copy, nullable) NSString* parAutoWhy;
@property(nonatomic) NSUInteger parAutoGridCap;
@property(nonatomic) BOOL parAutoFromWhile;
// parAutoFor (as the port): decisions made on the loop depth so far, the
// parAutoFor calls open, and the names parAutoLabels counted, in order.
@property(nonatomic) NSUInteger parAutoDepthReads;
@property(nonatomic) NSUInteger fnTok;   // where the function being parsed opens its body (#147)
@property(nonatomic, copy, nullable) NSString* parAutoFused;   // fused lifted loops: the block's name (#147)
@property(nonatomic) BOOL parAutoNoFuseOnce;                    // the site parses again without fusing: the fused block form was refused
@property(nonatomic, nullable) NSMutableArray* parAutoFuseSaid;   // their -Wpar-auto lines, said once the block is built
@property(nonatomic) NSUInteger parAutoNest;
@property(nonatomic, strong, nullable) NSMutableArray<NSString*>* parAutoLabelLog;
// The par frame walk (XTParser+ParFrame.m): the frame it fills, whether it is
// at the body's own level, the sites the parser registered for it, and the
// names parDesugarBody's site notes, for pfwRegister.
@property(nonatomic, strong, nullable) NSMutableDictionary* pfw;
@property(nonatomic) BOOL pfwTop;
@property(nonatomic, strong, nullable) NSMapTable* pfwSites;
@property(nonatomic, strong, nullable) NSMutableArray<NSString*>* pfwNoted;
// Walking a lifted loop's copy (parAutoFor): the copy, which `self.f` is
// rewritten in (pfwSelfIvar).
@property(nonatomic) BOOL pfwAuto;
@property(nonatomic, strong, nullable) XTASTNode* pfwRoot;
// The --par-style=auto recogniser (XTParser+ParLift.m): the tokens its walk
// rebuilds and the names each declaration there declares (by the index of
// its first token), the location they carry, whether the scan's body rules
// are reading them (plStream), the sites the parser recorded for the walk,
// and the increment of the last `while` parAutoWhileShape took (1 `v++`,
// 2 `++v`, 3 `v += 1`, 4 `v = v + 1`).
@property(nonatomic, strong, nullable) NSMutableArray<XTToken*>* plToks;
@property(nonatomic, strong, nullable) NSMutableDictionary<NSNumber*, NSArray<NSString*>*>* plDecls;
// The index of an address-of's `&` among those tokens -> the variable it
// takes the address of, or of an element or member of, else @"" (plAddrRoot).
@property(nonatomic, strong, nullable) NSMutableDictionary<NSNumber*, NSString*>* plAddrs;
// The index of a call argument's first token among those tokens -> the
// variables it may pass a pointer from, comma-separated, each marked with
// what it reads through (plArgRoots).
@property(nonatomic, strong, nullable) NSMutableDictionary<NSNumber*, NSString*>* plArgs;
@property(nonatomic, strong, nullable) XTSourceLocation* plLoc;
@property(nonatomic) BOOL plStream;
@property(nonatomic, strong, nullable) NSMapTable* plSites;
@property(nonatomic) NSInteger plWhileInc;
@property(nonatomic) BOOL plSkipWhileIf;
@property(nonatomic) NSUInteger plLits;
// The walk for a :scan body (scBodyOk): names, break, return and goto at
// their place, literals as spelt.
@property(nonatomic) BOOL plExact;
// The counted `while` parAutoWhileShape took: where the `while`, the `)`
// closing its condition and its increment are, and
// its counter with its type (parseAutoWhile).
@property(nonatomic) NSUInteger pwAt;
@property(nonatomic) NSUInteger pwPe;
@property(nonatomic) NSUInteger pwInc;
@property(nonatomic, strong, nullable) XTType* pwVt;
@property(nonatomic, copy, nullable) NSString* pwV;
// The `if (v < B) v = B;` such a `while` leaves after its `for` (parAutoWhileIf):
// the counter, B's tokens with the `)` after them, the comparison and the
// `while`'s location. In a braced block or a case body (pwInList, set by
// parseListStatement) it is the next statement; elsewhere it goes with the
// `for` in a block.
@property(nonatomic) BOOL pwInList;
@property(nonatomic) BOOL pwPending;
@property(nonatomic, copy, nullable) NSString* pwPendV;
@property(nonatomic, strong, nullable) NSArray<XTToken*>* pwPendBound;
@property(nonatomic, strong, nullable) XTToken* pwPendCmp;
@property(nonatomic, strong, nullable) XTSourceLocation* pwPendLoc;
// Operators a class defines with a shape of its own (XTParser+Shapes.m): the
// table, shape -> level * 2 + (1 when it groups from the right), level 0 for
// a prefix shape; the shapes whose level a `:precedence` set; whether the
// expression is being read with the shapes that also read the old way split;
// and the operators joined so far in the expression being read that also
// read the old way.
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString*, NSNumber*>* opShapes;
@property(nonatomic, strong, nullable) NSMutableSet<NSString*>* opShapesSet;
@property(nonatomic) BOOL splitShapes;
@property(nonatomic, strong, nullable) NSMutableArray<XTASTNode*>* shapeSites;
// Bracket shapes (`|x|`, `⌊x⌋`): the bracket that closes the one whose
// operand is being read, when no parenthesis or argument list lies between;
// the closing bracket of a bracket whose operand the next parseExpression
// reads; and whether the current token is a `||` whose first bar is taken.
@property(nonatomic, copy, nullable) NSString* bracketClose;
@property(nonatomic, copy, nullable) NSString* bracketBody;
@property(nonatomic) BOOL halfBar;
@end

// Operators a class defines with a shape of its own (XTParser+Shapes.m).
@interface XTParser (Packs)
- (void)fusePackSuffixes;
- (NSUInteger)parFuseFnEnd;
- (BOOL)parTensorFresh:(NSString*)n end:(NSUInteger)end;
// Tensor views (XTParser+Tensors.m): a view or reshape whose shapes are known
// as it parses, a write through a broadcast view, and two slices of one
// tensor split at the same place.
- (void)tensorCheckConstantView:(XTMethodCallExprNode*)call;
- (void)tensorReportDeferred;
- (void)tensorCheckBroadcastWrite:(XTASTNode*)lhs at:(XTSourceLocation*)loc;
- (BOOL)parTensorDisjoint:(NSString*)a with:(NSString*)b end:(NSUInteger)end;
- (nullable NSString*)parTensorRoot:(NSString*)n end:(NSUInteger)end;
// The run-time test that sends a par block with tensors to one thread, or nil
// (XTParser+Blocks.m).
- (nullable XTASTNode*)parTensorGuardFor:(NSArray<NSString*>*)caps
                                   types:(NSDictionary<NSString*, XTType*>*)types
                                 written:(nullable NSSet<NSString*>*)written
                                   fresh:(NSSet<NSString*>*)fresh
                                 fieldOf:(NSString* (^)(NSString*))fieldOf
                                      at:(XTSourceLocation*)loc;
@end

@interface XTParser (Shapes)
- (void)prescanOperatorShapes;
- (void)addShapesOfImports:(NSArray<XTASTNode*>*)decls;
- (NSString*)parsePrecedenceSpec;
- (nullable XTASTNode*)parseInfixShapeAfter:(XTASTNode*)lhs minPrec:(int)minPrec stop:(BOOL*)stop;
- (nullable XTASTNode*)parsePrefixShape;
- (BOOL)infixShapeAtCurrent;
- (nullable XTASTNode*)parseExpressionReadings;
- (BOOL)atBracketOpen;
- (BOOL)atBracketStop;
- (nullable XTASTNode*)parseBracket;
@end
BOOL XTShapeTokenType(XTTokenType t);
NSString* _Nullable XTPatternUserShape(NSArray<XTToken*>* t, NSString* _Nullable* _Nonnull fault,
                                       NSArray<NSString*>* _Nullable* _Nullable names);
NSString* XTPrecedenceSpecOf(NSArray<XTToken*>* t);

// The par frame walk (XTParser+ParFrame.m).
@interface XTParser (ParFrame)
- (void)pfwRegister:(nullable XTASTNode*)site
               body:(nullable XTASTNode*)body
             params:(nullable NSArray<XTParamNode*>*)params
              noted:(nullable NSArray<NSString*>*)noted
               kind:(NSUInteger)kind
              plain:(nullable XTASTNode*)plain;
- (NSMutableDictionary*)parFrameWalk:(XTASTNode*)body frame:(NSDictionary*)frame;
- (void)parFrameFill:(NSMutableDictionary*)frame body:(nullable XTASTNode*)body;
@end

// A lifted loop's copy (XTParser+ParFrame.m): the tree copied, and the goals
// a parse in the block's frame gives its loops.
XTASTNode* XTASTDeepCopy(XTASTNode* n);
void XTASTRename(XTASTNode* n, NSString* from, NSString* to);
void XTASTEachChild(id obj, void (^f)(id child));
// Adjacent par blocks fused (#147; XTParser+ParFrame.m).
NSMutableDictionary* XTParFuseScan(XTASTNode* body, NSString* iv);
BOOL XTParFuseSame(XTASTNode* _Nullable a, XTASTNode* _Nullable b);
BOOL XTParFuseBound(XTASTNode* _Nullable e, NSSet* written);
BOOL XTParFuseMath(NSString* _Nullable n);
void XTParFuseSetBody(XTForCStyleNode* loop, XTASTNode* body);
void XTParFuseRename(id n, NSString* x, NSString* iv, NSString* to);
void parAutoGoals(XTASTNode* n, NSInteger g);

// The --par-style=auto recogniser (XTParser+ParLift.m).
@interface XTParser (ParLift)
- (NSDictionary*)plRecogniseFor:(nullable XTASTNode*)loop at:(XTSourceLocation*)loc;
- (void)plRegister:(nullable XTASTNode*)site entry:(NSDictionary*)e;
- (NSArray<XTToken*>*)plScanToks:(XTASTNode*)body at:(XTSourceLocation*)loc;
@end

// XTParser.m: the body rules the recogniser runs on its walk's tokens.
@interface XTParser ()
- (BOOL)parAutoScanBodyAfter:(NSUInteger)pe
                         var:(NSString*)var
                   boundFrom:(NSUInteger)bndFrom
                          to:(NSUInteger)bndTo
                        reds:(NSMutableArray<NSArray<NSString*>*>*)reds
                        goal:(NSUInteger*)goalOut;
- (BOOL)parAutoWhileShape;
- (BOOL)parAutoSmall:(XTASTNode*)loop from:(NSUInteger)from to:(NSUInteger)to;
@end
BOOL pacStepInBound(XTASTNode* _Nullable e);
XTASTNode* _Nullable pacFirstKid(XTASTNode* e);
BOOL pacIsVar(XTASTNode* _Nullable e, NSString* v);
BOOL pacIsOne(XTASTNode* _Nullable e);

// XTParser+Blocks.m: the name an element access is rooted at, and the key an
// array update is counted under, with its uses.
NSString* _Nullable parRootName(XTASTNode* _Nullable n);
NSString* _Nullable parUpdateKey(XTASTNode* _Nullable target, XTAssignOp aop, XTASTNode* _Nullable rhs, NSUInteger* uses);

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
- (nullable NSString*)parSelfIvar;
- (void)blkMarkIvar:(NSString*)name;
- (void)blkNoteIdentifierUse:(NSString*)name at:(XTSourceLocation*)loc;
- (void)blkMarkWb:(NSString*)name;
- (BOOL)blkIsWbValue:(nullable XTASTNode*)e;
- (void)blkMarkHoldsWb:(NSString*)name fromInit:(nullable XTASTNode*)init;
- (NSMutableArray*)blkFrames;
- (NSMutableArray*)blkClasses;
- (BOOL)parArrReducible:(nullable XTType*)t op:(NSString*)op;
- (nullable XTASTNode*)parGridMemberAt:(XTSourceLocation*)loc;
- (void)parGridLoop:(int)delta;
- (void)parGridSwitch:(int)delta;
- (void)parGridBreakAt:(XTSourceLocation*)loc;
- (nullable XTASTNode*)parGridReturn:(XTReturnNode*)ret;
- (nullable XTASTNode*)parDesugarBody:(XTBlockNode*)body
                                 frame:(NSDictionary*)frame
                                  name:(nullable NSString*)name
                            reductions:(NSArray<NSArray<NSString*>*>*)reductions
                                    at:(XTSourceLocation*)loc;
- (NSMutableArray*)blkScopes;
- (void)blkBindAuto:(NSString*)name fromInit:(nullable XTASTNode*)init;
- (NSMutableDictionary*)blkState;
- (void)blkEnterClass:(nullable NSString*)name parent:(nullable NSString*)parent;
- (void)blkLeaveClass:(nullable NSString*)saved;
- (void)blkAddIvarName:(NSString*)name;
- (void)blkScanMethodNames;
- (void)blkNoteBareCall:(NSString*)name at:(XTSourceLocation*)loc;
- (void)blkBareCallCheck:(NSString*)name at:(XTSourceLocation*)loc;
- (void)blkCaptureError:(NSUInteger)which name:(NSString*)name at:(XTSourceLocation*)loc;
- (BOOL)blkIsIvar:(NSString*)name;
- (BOOL)blkIsLaterIvar:(NSString*)name;
- (nullable XTType*)blkLaterIvarType:(NSString*)name;
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
- (nullable XTASTNode*)parseListStatement;
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

// A pointer to numbers or structs, or an array of them, once `strip` elements
// are read through it (XTParser.m).
BOOL parAutoPointsToData(XTType* _Nullable t, NSUInteger strip);

NS_ASSUME_NONNULL_END
