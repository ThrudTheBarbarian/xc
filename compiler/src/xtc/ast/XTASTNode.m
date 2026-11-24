#import <objc/runtime.h>
#import "XTASTNode.h"

// Store an object into an ivar, retaining it as a strong reference. Apple's
// runtime needs the StrongDefault form for ivars without ownership metadata;
// the GNUstep runtime's object_setIvar already honours each ivar's ownership.
#if defined(__APPLE__)
#define astSetIvar(o, iv, v) object_setIvarWithStrongDefault((o), (iv), (v))
#else
#define astSetIvar(o, iv, v) object_setIvar((o), (iv), (v))
#endif

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

/****************************************************************************\
|* Become `other`, a node of the same class, ivar by ivar (objects shared,
|* not copied). Nothing happens for a node of another class.
\****************************************************************************/
- (void)adoptReading:(XTASTNode*)other
    {
    if (object_getClass(other) != object_getClass(self))
        return;
    for (Class c = object_getClass(self); c && c != [NSObject class]; c = class_getSuperclass(c))
        {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++)
            {
            const char* enc = ivar_getTypeEncoding(ivars[i]);
            if (enc && enc[0] == '@')
                astSetIvar(self, ivars[i], object_getIvar(other, ivars[i]));
            else if (enc)
                {
                NSUInteger size = 0;
                NSGetSizeAndAlignment(enc, &size, NULL);
                ptrdiff_t off = ivar_getOffset(ivars[i]);
                memcpy((char*)(__bridge void*)self + off, (const char*)(__bridge void*)other + off, size);
                }
            }
        free(ivars);
        }
    }

@end
