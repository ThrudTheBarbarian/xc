#import "XTDeclNodes.h"

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTProgramNode
/****************************************************************************\
|* Create the program root node with its top-level declarations.
|* @param declarations  Array of top-level declaration nodes.
|* @param location      Source location for the start of the program.
|* @return A new program node.
\****************************************************************************/
- (instancetype)initWithDeclarations:(NSArray<XTASTNode*>*)declarations
                            location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindProgram location:location];
    if (self)
        {
        _declarations = [declarations copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitProgram: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitProgram:)])
        [visitor visitProgram:self];
    }

- (void)removeDeclarations:(NSSet<XTASTNode*>*)spent
    {
    if (!spent.count)
        return;
    NSMutableArray* keep = [NSMutableArray arrayWithCapacity:_declarations.count];
    for (XTASTNode* d in _declarations)
        if (![spent containsObject:d])
            [keep addObject:d];
    _declarations = [keep copy];
    }

@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTParamNode
/****************************************************************************\
|* Create a parameter node with an explicit type and name.
|* @param type      The declared type of the parameter.
|* @param name      The parameter name as it appears in source.
|* @param location  Source location of the parameter declaration.
|* @return A new parameter node.
\****************************************************************************/
- (instancetype)initWithType:(XTType*)type name:(NSString*)name location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindParam location:location];
    if (self)
        {
        _paramType = type;
        _paramName = [name copy];
        }
    return self;
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTFunctionDeclNode
/****************************************************************************\
|* Create a function declaration (or forward declaration if body is nil).
|* @param name         The unmangled function name.
|* @param returnTypes  Array of return types (multiple for tuple returns).
|* @param parameters   Array of XTParamNode for the function signature.
|* @param isVarArgs    YES if the function accepts variadic arguments.
|* @param body         The function body block, or nil for a forward declaration.
|* @param location     Source location of the function declaration.
|* @return A new function declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                 returnTypes:(NSArray<XTType*>*)returnTypes
                  parameters:(NSArray<XTParamNode*>*)parameters
                   isVarArgs:(BOOL)isVarArgs
                        body:(nullable XTASTNode*)body
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindFunctionDecl location:location];
    if (self)
        {
        _funcName = [name copy];
        _mangledName = [name copy];
        _returnTypes = [returnTypes copy];
        _parameters = [parameters copy];
        _isVarArgs = isVarArgs;
        _varargsSlot = -1;
        _body = body;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitFunctionDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitFunctionDecl:)])
        [visitor visitFunctionDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTVariableDeclNode
@synthesize isRegister = _isRegister;
@synthesize isStatic = _isStatic;
/****************************************************************************\
|* Create a variable declaration node.
|* @param name         The variable name.
|* @param type         The declared type, or nil when declared with 'auto'.
|* @param initialiser  The initialiser expression, or nil when absent.
|* @param location     Source location of the variable declaration.
|* @return A new variable declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                        type:(nullable XTType*)type
                 initialiser:(nullable XTASTNode*)initialiser
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindVariableDecl location:location];
    if (self)
        {
        _varName = [name copy];
        _declaredType = type;
        _initialiser = initialiser;
        _isGlobal = NO;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitVariableDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitVariableDecl:)])
        [visitor visitVariableDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTStructDeclNode
/****************************************************************************\
|* Create a struct declaration node.
|* @param name      The struct tag name, or nil for anonymous structs.
|* @param fields    Array of field declarations.
|* @param location  Source location of the struct keyword.
|* @return A new struct declaration node.
\****************************************************************************/
- (instancetype)initWithName:(nullable NSString*)name
                      fields:(NSArray<XTVariableDeclNode*>*)fields
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindStructDecl location:location];
    if (self)
        {
        _structName = [name copy];
        _fields = [fields copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitStructDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitStructDecl:)])
        [visitor visitStructDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTTypedefNode
/****************************************************************************\
|* Create a typedef node.
|* @param alias       The new alias name being introduced.
|* @param targetType  The existing type being aliased, or nil when a struct decl follows.
|* @param structDecl  An inline struct declaration, or nil when aliasing an existing type.
|* @param location    Source location of the typedef keyword.
|* @return A new typedef declaration node.
\****************************************************************************/
- (instancetype)initWithAliasName:(NSString*)alias
                       targetType:(nullable XTType*)targetType
                       structDecl:(nullable XTStructDeclNode*)structDecl
                         location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindTypedefDecl location:location];
    if (self)
        {
        _aliasName = [alias copy];
        _targetType = targetType;
        _structDecl = structDecl;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitTypedefDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitTypedefDecl:)])
        [visitor visitTypedefDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTUseDeclNode
- (instancetype)initWithClassName:(NSString*)className
                         location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindUseDecl location:location];
    if (self)
        {
        _className = [className copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitUseDecl: on the visitor when present, else swallow.
|* The use directive has no codegen — it's a pure sema-time hint that
|* expands the bare-call lookup space, so visitors that don't care
|* (codegen, optimiser) are free to ignore it.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitUseDecl:)])
        {
        [visitor performSelector:@selector(visitUseDecl:) withObject:self];
        }
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTEnumMemberNode
/****************************************************************************\
|* Create an enum member node.
|* @param name      The member identifier.
|* @param value     The explicit integer value, or nil for auto-assignment by sema.
|* @param location  Source location of the member name.
|* @return A new enum member node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
               explicitValue:(nullable NSNumber*)value
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindEnumMember location:location];
    if (self)
        {
        _memberName = [name copy];
        _explicitValue = value;
        _resolvedValue = 0;
        }
    return self;
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTEnumDeclNode
/****************************************************************************\
|* Create an enum declaration node.
|* @param name      The enum tag name.
|* @param members   Array of XTEnumMemberNode values.
|* @param location  Source location of the enum keyword.
|* @return A new enum declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                     members:(NSArray<XTEnumMemberNode*>*)members
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindEnumDecl location:location];
    if (self)
        {
        _enumName = [name copy];
        _members = [members copy];
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitEnumDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitEnumDecl:)])
        [visitor visitEnumDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTMethodDeclNode
/****************************************************************************\
|* Create a method declaration node.
|* @param name         The unmangled method name.
|* @param returnTypes  Array of return types.
|* @param parameters   Array of XTParamNode for the method signature.
|* @param isStatic     YES if this is a class-level (static) method.
|* @param isVarArgs    YES if the method accepts variadic arguments.
|* @param body         The method body block, or nil for a forward declaration.
|* @param location     Source location of the method declaration.
|* @return A new method declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                 returnTypes:(NSArray<XTType*>*)returnTypes
                  parameters:(NSArray<XTParamNode*>*)parameters
                    isStatic:(BOOL)isStatic
                   isVarArgs:(BOOL)isVarArgs
                        body:(nullable XTASTNode*)body
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindMethodDecl location:location];
    if (self)
        {
        _methodName = [name copy];
        _mangledName = [name copy];
        _returnTypes = [returnTypes copy];
        _parameters = [parameters copy];
        _isStatic = isStatic;
        _isVarArgs = isVarArgs;
        _varargsSlot = -1;
        _body = body;
        }
    return self;
    }
/****************************************************************************\
|* Dispatch to visitMethodDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitMethodDecl:)])
        [visitor visitMethodDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTClassDeclNode
/****************************************************************************\
|* Create a class declaration node.
|* @param name      The class name.
|* @param ivars     Array of instance-variable declarations.
|* @param methods   Array of method declarations.
|* @param location  Source location of the class keyword.
|* @return A new class declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                  parentName:(nullable NSString*)parentName
               protocolNames:(NSArray<NSString*>*)protocolNames
                       ivars:(NSArray<XTVariableDeclNode*>*)ivars
                     methods:(NSArray<XTMethodDeclNode*>*)methods
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindClassDecl location:location];
    if (self)
        {
        _className = [name copy];
        _parentName = [parentName copy];
        _protocolNames = [protocolNames copy] ?: @[];
        _ivars = [ivars copy];
        _methods = [methods copy];
        }
    return self;
    }
- (BOOL)isCategory
    {
    return self.categoryName != nil;
    }

// Append an ivar contributed by an extension. Order is the merge order, which
// the caller fixes deterministically (by file, then line) so a build's layout
// depends on the SET of parts, not on which was reached first.
- (void)appendIvar:(XTVariableDeclNode*)ivar
    {
    if (!ivar)
        return;
    NSMutableArray<XTVariableDeclNode*>* v = [_ivars mutableCopy];
    [v addObject:ivar];
    _ivars = [v copy];
    }

- (void)appendSynthesisedMethod:(XTMethodDeclNode*)method
    {
    if (!method)
        return;
    NSMutableArray<XTMethodDeclNode*>* m = [_methods mutableCopy];
    [m addObject:method];
    _methods = [m copy];
    }

- (void)appendProtocolConformance:(NSString*)protocolName
    {
    if (!protocolName.length)
        return;
    if ([_protocolNames containsObject:protocolName])
        return;
    _protocolNames = [(_protocolNames ?: @[]) arrayByAddingObject:protocolName];
    }
/****************************************************************************\
|* Dispatch to visitClassDecl: on the visitor.
|* @param visitor  An object conforming to XTASTVisitor.
\****************************************************************************/
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    if ([visitor respondsToSelector:@selector(visitClassDecl:)])
        [visitor visitClassDecl:self];
    }
@end

// ─────────────────────────────────────────────────────────────────────────────
@implementation XTProtocolDeclNode
- (instancetype)initWithName:(NSString*)name
                     methods:(NSArray<XTMethodDeclNode*>*)methods
                    location:(XTSourceLocation*)location
    {
    self = [super initWithKind:XTASTNodeKindProtocolDecl location:location];
    if (self)
        {
        _protocolName = [name copy];
        _methods = [methods copy];
        }
    return self;
    }
- (void)acceptVisitor:(id<XTASTVisitor>)visitor
    {
    (void)visitor;
    // Protocols carry no bodies — sema inspects them as
    // declarations on the program node, not through the visitor.
    }
@end
