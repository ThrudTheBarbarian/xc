#import <Foundation/Foundation.h>
#import "XTSourceLocation.h"
#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTASTNodeKind) {
    // Declarations
    XTASTNodeKindProgram,
    XTASTNodeKindFunctionDecl,
    XTASTNodeKindMethodDecl,
    XTASTNodeKindVariableDecl,
    XTASTNodeKindStructDecl,
    XTASTNodeKindTypedefDecl,
    XTASTNodeKindEnumDecl,
    XTASTNodeKindEnumMember,
    XTASTNodeKindClassDecl,
    XTASTNodeKindProtocolDecl,
    XTASTNodeKindUseDecl,
    XTASTNodeKindParam,
    // Statements
    XTASTNodeKindBlock,
    XTASTNodeKindIf,
    XTASTNodeKindWhile,
    XTASTNodeKindForCStyle,
    XTASTNodeKindForIn,
    XTASTNodeKindReturn,
    XTASTNodeKindBreak,
    XTASTNodeKindContinue,
    XTASTNodeKindGoto,
    XTASTNodeKindLabel,
    XTASTNodeKindSwitch,
    XTASTNodeKindAsmBlock,
    XTASTNodeKindExprStatement,
    XTASTNodeKindTupleAssign,
    XTASTNodeKindDelete,
    // Expressions
    XTASTNodeKindBinaryExpr,
    XTASTNodeKindUnaryExpr,
    XTASTNodeKindPostfixExpr,
    XTASTNodeKindAssignExpr,
    XTASTNodeKindCallExpr,
    XTASTNodeKindMethodCallExpr,
    XTASTNodeKindSubscriptExpr,
    XTASTNodeKindSliceExpr,
    XTASTNodeKindRangeExpr,
    XTASTNodeKindMemberAccess,
    XTASTNodeKindTernaryExpr,
    XTASTNodeKindCastExpr,
    XTASTNodeKindIdentifier,
    XTASTNodeKindLiteralInt,
    XTASTNodeKindLiteralFloat,
    XTASTNodeKindLiteralString,
    XTASTNodeKindLiteralChar,
    XTASTNodeKindLiteralBool,
    XTASTNodeKindNewExpr,
    XTASTNodeKindSizeofExpr,
    XTASTNodeKindDefer, // appended: mid-enum insertion renumbers the rest
    XTASTNodeKindThrow,
    XTASTNodeKindTry,
};

@protocol XTASTVisitor;

@interface XTASTNode : NSObject

@property(nonatomic, readonly) XTASTNodeKind nodeKind;
@property(nonatomic, readonly) XTSourceLocation* location;
/****************************************************************************\
|* Set by the semantic analyser.
\****************************************************************************/
@property(nonatomic, nullable) XTType* resolvedType;

/****************************************************************************\
|* Designated initialiser for all AST nodes.
|* @param kind      The node-kind enum value identifying the concrete subclass.
|* @param location  Source location where the construct begins.
|* @return A new AST node, or nil on allocation failure.
\****************************************************************************/
- (instancetype)initWithKind:(XTASTNodeKind)kind
                    location:(XTSourceLocation*)location NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Dispatch to the appropriate visitor method. Subclasses override this to
|* call the concrete visit* selector; the base implementation does nothing.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor;

@end

/****************************************************************************\
|* Visitor protocol — one visit method per concrete node kind.
|* All methods are optional; the default implementation does nothing.
\****************************************************************************/
@protocol XTASTVisitor <NSObject>
@optional
- (void)visitProgram:(XTASTNode*)node;
- (void)visitFunctionDecl:(XTASTNode*)node;
- (void)visitMethodDecl:(XTASTNode*)node;
- (void)visitVariableDecl:(XTASTNode*)node;
- (void)visitStructDecl:(XTASTNode*)node;
- (void)visitTypedefDecl:(XTASTNode*)node;
- (void)visitEnumDecl:(XTASTNode*)node;
- (void)visitClassDecl:(XTASTNode*)node;
- (void)visitBlock:(XTASTNode*)node;
- (void)visitIf:(XTASTNode*)node;
- (void)visitWhile:(XTASTNode*)node;
- (void)visitForCStyle:(XTASTNode*)node;
- (void)visitForIn:(XTASTNode*)node;
- (void)visitReturn:(XTASTNode*)node;
- (void)visitBreak:(XTASTNode*)node;
- (void)visitContinue:(XTASTNode*)node;
- (void)visitGoto:(XTASTNode*)node;
- (void)visitLabel:(XTASTNode*)node;
- (void)visitDefer:(XTASTNode*)node;
- (void)visitThrow:(XTASTNode*)node;
- (void)visitTry:(XTASTNode*)node;
- (void)visitSwitch:(XTASTNode*)node;
- (void)visitAsmBlock:(XTASTNode*)node;
- (void)visitExprStatement:(XTASTNode*)node;
- (void)visitTupleAssign:(XTASTNode*)node;
- (void)visitDelete:(XTASTNode*)node;
- (void)visitBinaryExpr:(XTASTNode*)node;
- (void)visitUnaryExpr:(XTASTNode*)node;
- (void)visitPostfixExpr:(XTASTNode*)node;
- (void)visitAssignExpr:(XTASTNode*)node;
- (void)visitCallExpr:(XTASTNode*)node;
- (void)visitMethodCallExpr:(XTASTNode*)node;
- (void)visitSubscriptExpr:(XTASTNode*)node;
- (void)visitSliceExpr:(XTASTNode*)node;
- (void)visitRangeExpr:(XTASTNode*)node;
- (void)visitMemberAccess:(XTASTNode*)node;
- (void)visitTernaryExpr:(XTASTNode*)node;
- (void)visitIdentifier:(XTASTNode*)node;
- (void)visitLiteralInt:(XTASTNode*)node;
- (void)visitLiteralFloat:(XTASTNode*)node;
- (void)visitLiteralString:(XTASTNode*)node;
- (void)visitLiteralChar:(XTASTNode*)node;
- (void)visitLiteralBool:(XTASTNode*)node;
- (void)visitNewExpr:(XTASTNode*)node;
- (void)visitSizeofExpr:(XTASTNode*)node;
- (void)visitCastExpr:(XTASTNode*)node;
@end

NS_ASSUME_NONNULL_END
