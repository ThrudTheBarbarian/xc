#import "XTASTNode.h"

@implementation XTASTNode

/****************************************************************************\
|* Designated initialiser for all AST nodes.
|* @param kind      The node-kind enum value identifying the concrete subclass.
|* @param location  Source location where the construct begins.
|* @return A new AST node, or nil on allocation failure.
\****************************************************************************/
- (instancetype)initWithKind:(XTASTNodeKind)kind location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _nodeKind = kind;
        _location = location;
        }
    return self;
    }

/****************************************************************************\
|* Dispatch to the appropriate visitor method. Subclasses override this to
|* call the concrete visit* selector; the base implementation does nothing.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    // Subclasses override to dispatch to the correct visitor method.
    }

@end
