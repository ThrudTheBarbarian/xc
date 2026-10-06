/****************************************************************************\
|* XTParser+Blocks.m — blocks v1 (private:docs/Design/blocks.md, task #26).
|*
|* Blocks are desugared ENTIRELY at parse time. The parser is the lexical
|* walker — it sees every declaration in scope order — so it can do the
|* capture analysis itself and emit only constructs the rest of the
|* pipeline already understands:
|*
|*   block b u32(u16 x, u16 y) = { return x + y; }
|*
|* becomes (1) a per-signature BASE class, synthesised once:
|*
|*   class Blk$u32$u16$u16 { u32 invoke(u16 p0, u16 p1) { return (u32)0; } }
|*
|* (2) a per-literal IMPL subclass whose ivars are the captures and whose
|* invoke override is the literal's body (capture names stay verbatim, so
|* the body's identifiers resolve to the ivars with no rewriting at all):
|*
|*   class BlkImpl$0 : Blk$u32$u16$u16 {
|*       <capture ivars…>
|*       void _set(<captures>) { <ivar stores> }        // only if captures
|*       u32 invoke(u16 x, u16 y) { return x + y; }
|*       static Blk$u32$u16$u16* mk(<captures>) {
|*           BlkImpl$0* t = new BlkImpl$0();
|*           t._set(…);
|*           return t;
|*       }
|*   }
|*
|* and (3) the literal site becomes `BlkImpl$0.mk(<captured names>)`.
|* The declared variable is a plain class POINTER to the base class, so
|* ARC, params, returns, ivars, `auto` and null-tests all ride the
|* existing class-pointer machinery; a call through the variable —
|* `b(3, 4)` — is rewritten here to `b.invoke(3, 4)`, virtual dispatch
|* through the vtable the invoke override already pays for. Sema and the
|* lowering see NOTHING new; there is no block node kind.
|*
|* v1 scope (the design note's staging): captures are BY VALUE, locals
|* and parameters only. Capturing `self`/ivars is a parse error with
|* guidance; `auto` locals must be given an explicit type to be captured
|* (their type is not known until sema). `&obj.method` as a block value
|* is v1.1 (needs a one-ivar wrapper impl).
\****************************************************************************/

#import "XTParser+Private.h"
#import "XTArrayType.h"
#import "XTToken.h"
#import "XTTypeTable.h"
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ── parser-side block state (associated storage lives in XTParser via the
//    class-extension properties declared in XTParser+Private.h) ────────────

@implementation XTParser (Blocks)

/****************************************************************************\
|* Lazily-created state accessors. The parser object predates blocks;
|* rather than threading new ivars through its designated initialiser,
|* the five pieces of state live in one mutable dictionary created on
|* first use. (One dictionary, not five properties, so the class
|* extension stays untouched and the state is trivially resettable.)
\****************************************************************************/
- (NSMutableDictionary*)blkState
    {
    static const void* kBlkStateKey = &kBlkStateKey;
    NSMutableDictionary* st = objc_getAssociatedObject(self, kBlkStateKey);
    if (!st)
        {
        st = [NSMutableDictionary dictionary];
        st[@"scopes"] = [NSMutableArray array];          // of NSMutableDictionary name→info
        st[@"frames"] = [NSMutableArray array];          // capture frames (nested literals)
        st[@"classes"] = [NSMutableArray array];         // synthesised XTClassDeclNode, emit order
        st[@"bases"] = [NSMutableDictionary dictionary]; // mangled → @[ret, params(XTParamNode)]
        st[@"counter"] = @(0);
        st[@"ivars"] = [NSMutableSet set]; // current class's ivar names
        objc_setAssociatedObject(self, kBlkStateKey, st,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    return st;
    }

- (NSMutableArray*)blkScopes
    {
    return self.blkState[@"scopes"];
    }
- (NSMutableArray*)blkFrames
    {
    return self.blkState[@"frames"];
    }
- (NSMutableArray*)blkClasses
    {
    return self.blkState[@"classes"];
    }
- (NSMutableDictionary*)blkBases
    {
    return self.blkState[@"bases"];
    }
- (NSMutableSet*)blkIvarNames
    {
    return self.blkState[@"ivars"];
    }

- (void)blkPushScope
    {
    [[self blkScopes] addObject:[NSMutableDictionary dictionary]];
    }
- (void)blkPopScope
    {
    if ([self blkScopes].count)
        [[self blkScopes] removeLastObject];
    }

/****************************************************************************\
|* Record a binding the capture analysis can see. `type` may be nil
|* (auto — capturable only with an explicit type, so remembered as
|* NSNull). `blockBase` non-nil marks a block-typed binding and names
|* its base class, which is what the call-rewrite keys on.
\****************************************************************************/
- (void)blkBind:(NSString*)name type:(nullable XTType*)type
    {
    if (!name.length || ![self blkScopes].count)
        return;
    NSMutableDictionary* top = [[self blkScopes] lastObject];
    NSMutableDictionary* info = [NSMutableDictionary dictionary];
    info[@"type"] = type ?: (id)[NSNull null];
    // A binding whose type is a pointer to a Blk$… class is a block
    // value; calls through it rewrite to .invoke dispatch.
    if ([type isKindOfClass:[XTPointerType class]])
        {
        XTType* pe = ((XTPointerType*)type).pointeeType;
        if (pe.kind == XTTypeKindClass && [pe.displayName hasPrefix:@"Blk$"])
            {
            info[@"base"] = pe.displayName;
            // The DECLARED parameter names travel with the binding — a bare
            // `b = { body }` inherits b's own names, not whichever
            // declaration first minted this signature.
            if ([self.lastBlockBaseName isEqualToString:pe.displayName] && self.lastBlockParams)
                {
                info[@"params"] = self.lastBlockParams;
                }
            }
        }
    top[name] = info;
    }

/****************************************************************************\
|* v2 (task #29): does this expression yield a block that CARRIES
|* write-back captures? Either the literal's own mk-call, or a binding
|* that was seen holding one. Such a value writes into its creating
|* frame, so it must not outlive it — return and member/element stores
|* are rejected at the sites below.
\****************************************************************************/
- (BOOL)blkIsWbValue:(nullable XTASTNode*)e
    {
    if (!e)
        return NO;
    if ([e isKindOfClass:[XTIdentifierNode class]])
        {
        NSDictionary* info = [self blkLookup:((XTIdentifierNode*)e).identName depth:NULL];
        return [info[@"holdswb"] boolValue];
        }
    if ([e isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* mc = (XTMethodCallExprNode*)e;
        if (![mc.methodName isEqualToString:@"mk"])
            return NO;
        if (![mc.receiver isKindOfClass:[XTIdentifierNode class]])
            return NO;
        return [self.blkState[@"wbImpls"]
            containsObject:((XTIdentifierNode*)mc.receiver).identName];
        }
    return NO;
    }

- (void)blkMarkHoldsWb:(NSString*)name fromInit:(nullable XTASTNode*)init
    {
    if (![self blkIsWbValue:init])
        return;
    NSDictionary* info = [self blkLookup:name depth:NULL];
    if (info)
        ((NSMutableDictionary*)info)[@"holdswb"] = @YES;
    }

// v2 (task #29): mark the just-bound name as a write-back capture target.
- (void)blkMarkWb:(NSString*)name
    {
    if (!name.length)
        return;
    NSUInteger d = 0;
    NSDictionary* info = [self blkLookup:name depth:&d];
    if (info)
        ((NSMutableDictionary*)info)[@"wb"] = @YES;
    }

// Innermost binding for `name`, plus (out) the scope index it lives at.
- (nullable NSDictionary*)blkLookup:(NSString*)name depth:(NSUInteger*)outDepth
    {
    NSArray* scopes = [self blkScopes];
    for (NSInteger i = (NSInteger)scopes.count - 1; i >= 0; i--)
        {
        NSDictionary* info = scopes[(NSUInteger)i][name];
        if (info)
            {
            if (outDepth)
                *outDepth = (NSUInteger)i;
            return info;
            }
        }
    return nil;
    }

/****************************************************************************\
|* Identifier-use hook, called from the expression parser's two
|* XTIdentifierNode creation sites. Inside a block literal's body, a
|* name that resolves OUTSIDE the literal's own scopes is a capture:
|* recorded once, in first-use order, with its declared type.
\****************************************************************************/
- (void)blkNoteIdentifierUse:(NSString*)name at:(XTSourceLocation*)loc
    {
    NSMutableArray* frames = [self blkFrames];
    if (!frames.count)
        return;
    NSMutableDictionary* frame = frames.lastObject;
    NSUInteger literalDepth = [frame[@"depth"] unsignedIntegerValue];
    NSUInteger foundDepth = 0;
    NSDictionary* info = [self blkLookup:name depth:&foundDepth];
    if (!info && [frame[@"par"] boolValue])
        {
        // A `par` body's use of a name from outside every scope: a global,
        // if the program declared one by that name (parDesugarBody filters).
        NSMutableArray* outer = frame[@"outer"];
        if (!outer)
            frame[@"outer"] = outer = [NSMutableArray array];
        if (![outer containsObject:name])
            [outer addObject:name];
        }
    if (!info)
        {
        // Not a visible local. `self` (and the enclosing class's ivars)
        // are the v1 restriction — say so rather than letting sema emit
        // "Undefined identifier" from inside a class the user never wrote.
        if ([name isEqualToString:@"self"] || [[self blkIvarNames] containsObject:name])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"a block cannot capture '%@' (v1 captures locals and "
                                                      @"parameters only) — copy it into a local first, e.g. "
                                                      @"`auto me = self;` outside the block",
                                                      name]
                                     at:loc];
            }
        return;
        }
    if (foundDepth >= literalDepth)
        return; // the literal's own local/param
    NSMutableArray* names = frame[@"names"];
    if ([names containsObject:name])
        return; // already captured
    id ty = info[@"type"];
    if (ty == [NSNull null])
        {
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"cannot capture '%@': it was declared `auto`, and a capture "
                                                  @"needs the declared type at this point — give it an explicit "
                                                  @"type",
                                                  name]
                                 at:loc];
        return;
        }
    // v2 (task #29): a `block:`-marked binding captures with write-back —
    // a working copy plus a hidden pointer to the frame slot, stored back
    // at every invocation exit. Sound only while that frame lives, so it
    // does not compose through NESTED literals (the enclosing literal's
    // copy is an ivar, not a frame slot).
    if ([info[@"wb"] boolValue])
        {
        if ([self blkFrames].count > 1)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"a `block:` capture of '%@' inside a nested block is not "
                                                      @"supported (v2) — write-back reaches the enclosing FRAME, "
                                                      @"and here the enclosing scope is itself a block",
                                                      name]
                                     at:loc];
            return;
            }
        [frame[@"wb"] addObject:name];
        }
    [names addObject:name];
    frame[@"types"][name] = ty;
    if (info[@"base"])
        frame[@"bases"][name] = info[@"base"];
    }

/****************************************************************************\
|* `auto e = d;` / `auto e = block …{…};` — an auto local has no parsed
|* type, so a block binding is PROPAGATED from the initialiser: a bare
|* identifier copies the source binding; a literal (already desugared to
|* `BlkImpl$N.mk(…)`) reconstructs it from the impl's base class.
\****************************************************************************/
- (void)blkBindAuto:(NSString*)name fromInit:(nullable XTASTNode*)init
    {
    if (!init || !name.length || ![self blkScopes].count)
        return;
    NSDictionary* src = nil;
    if ([init isKindOfClass:[XTIdentifierNode class]])
        {
        src = [self blkLookup:((XTIdentifierNode*)init).identName depth:NULL];
        if (!src[@"base"])
            return;
        }
    else if ([init isKindOfClass:[XTCallExprNode class]])
        {
        // `auto b = makeAdder(5);` — the callee's declared return type, when
        // it is a block, hands the binding to the auto local.
        XTType* rt = self.blkState[@"fnRet"][((XTCallExprNode*)init).calleeName];
        if (![rt isKindOfClass:[XTPointerType class]])
            return;
        XTType* pe = ((XTPointerType*)rt).pointeeType;
        if (pe.kind != XTTypeKindClass || ![pe.displayName hasPrefix:@"Blk$"])
            return;
        NSString* base = pe.displayName;
        NSArray* sig = [self blkBases][base];
        NSMutableDictionary* info = [NSMutableDictionary dictionary];
        info[@"type"] = rt;
        info[@"base"] = base;
        if (sig.count > 1)
            info[@"params"] = sig[1];
        [[self blkScopes] lastObject][name] = info;
        return;
        }
    else if ([init isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* mc = (XTMethodCallExprNode*)init;
        if (![mc.methodName isEqualToString:@"mk"])
            return;
        if (![mc.receiver isKindOfClass:[XTIdentifierNode class]])
            return;
        NSString* impl = ((XTIdentifierNode*)mc.receiver).identName;
        NSString* base = self.blkState[@"implBase"][impl];
        if (!base)
            return;
        NSArray* sig = [self blkBases][base];
        NSMutableDictionary* info = [NSMutableDictionary dictionary];
        info[@"type"] = [NSNull null];
        info[@"base"] = base;
        if (sig.count > 1)
            info[@"params"] = sig[1];
        [[self blkScopes] lastObject][name] = info;
        return;
        }
    else
        {
        return;
        }
    [[self blkScopes] lastObject][name] = [src mutableCopy];
    }

// ── the `block` gate ──────────────────────────────────────────────────────

/****************************************************************************\
|* YES when the tokens at the cursor begin a block type / literal /
|* declaration: `block` followed by a type-start, or by an identifier
|* (the declared name) followed by a type-start. Deliberately narrow —
|* anything else keeps `block` an ordinary identifier, so existing code
|* using the name does not break (contextual keyword; see the design
|* note for the eventual hardening).
\****************************************************************************/
- (BOOL)blkKeywordAhead
    {
    XTToken* cur = [self currentToken];
    if (cur.type != XTTokenIdentifier || ![cur.value isEqualToString:@"block"])
        return NO;
    XTToken* t1 = [self peekToken:1];
    BOOL t1Type = t1.isTypeKeyword || t1.type == XTTokenVoid || [self.typeTable isTypeName:t1.value];
    if (t1Type)
        return YES;
    if (t1.type != XTTokenIdentifier)
        return NO;
    XTToken* t2 = [self peekToken:2];
    // `block t[2] u32(u32)` — the array declarator sits between the name and
    // the signature, so the token after the name is `[`, not a type.
    if (t2.type == XTTokenLBracket)
        return YES;
    return t2.isTypeKeyword || t2.type == XTTokenVoid || [self.typeTable isTypeName:t2.value];
    }

/****************************************************************************\
|* Sanitize a type's display name into a mangle fragment. `$` cannot
|* appear in a user-written type name, so `u8*` → `u8$P` is collision-
|* free; spaces (from qualified spellings) are dropped.
\****************************************************************************/
static NSString* blkMangleFragment(XTType* ty)
    {
    NSString* s = ty.displayName ?: @"void";
    s = [s stringByReplacingOccurrencesOfString:@"*" withString:@"$P"];
    s = [s stringByReplacingOccurrencesOfString:@"@" withString:@"$P"];
    s = [s stringByReplacingOccurrencesOfString:@" " withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@":" withString:@"$q"];
    return s;
    }

/****************************************************************************\
|* Parse `block [name] RET ( params )` from the keyword. Returns the
|* variable TYPE — a pointer to the per-signature base class — and
|* stashes the declared name / parameter nodes / base name for the
|* caller (declaration, parameter and literal sites all want them).
|* The base class itself is synthesised at most once per signature.
\****************************************************************************/
- (nullable XTType*)blkParseTypeHeader
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume `block`
    self.lastBlockDeclName = nil;
    self.lastBlockBaseName = nil;
    self.lastBlockParams = nil;
    self.lastBlockRet = nil;

    // Held LOCALLY until the end: the nested parseType calls below clear
    // the stash on entry (they must — see parseType), so stamping early
    // would lose the name to our own recursion.
    NSString* declName = nil;
    XTToken* maybeName = [self currentToken];
    if (maybeName.type == XTTokenIdentifier && ![self.typeTable isTypeName:maybeName.value] && !maybeName.isTypeKeyword)
        {
        declName = maybeName.value;
        [self advance];
        }

    // `block t[2] u32(u32 n)` — an array of blocks, the declarator bound to
    // the NAME as C puts it. Same addition as `callback`'s, and made at the
    // same time deliberately: the two headers are one grammar, and a shape
    // legal in one and not the other is the kind of difference nobody
    // discovers until they hit it. private:docs/bugs/074.
    BOOL isArray = NO;
    NSUInteger arrayCount = 0;
    if (declName && [self match:XTTokenLBracket])
        {
        isArray = YES;
        if (![self check:XTTokenRBracket])
            {
            XTASTNode* sizeExpr = [self parseExpression];
            arrayCount = [self resolveArraySizeExpr:sizeExpr];
            }
        [self expect:XTTokenRBracket];
        }

    XTType* ret = nil;
    if ([self check:XTTokenVoid] && [self peekToken:1].type == XTTokenLParen)
        {
        [self advance];
        ret = [XTType voidType];
        }
    else
        {
        ret = [self parseType];
        }
    if (!ret)
        return nil;

    if (![self match:XTTokenLParen])
        {
        [self.diagnostics emitError:@"expected '(' after a block's return type"
                                 at:loc];
        return nil;
        }
    NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
    if ([self check:XTTokenVoid] && [self peekToken:1].type == XTTokenRParen)
        {
        [self advance];
        }
    else if (![self check:XTTokenRParen])
        {
        NSUInteger idx = 0;
        while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
            {
            XTType* pt = [self parseType];
            if (!pt)
                return nil;
            NSString* pname = [NSString stringWithFormat:@"p%lu", (unsigned long)idx];
            if ([self check:XTTokenIdentifier])
                {
                pname = [self advance].value;
                }
            [params addObject:[[XTParamNode alloc] initWithType:pt
                                                           name:pname
                                                       location:loc]];
            idx++;
            if (![self match:XTTokenComma])
                break;
            }
        }
    [self expect:XTTokenRParen];

    // Mangle + base marker registration (idempotent per signature).
    NSMutableString* mangled = [NSMutableString stringWithString:@"Blk"];
    [mangled appendFormat:@"$%@", blkMangleFragment(ret)];
    for (XTParamNode* p in params)
        [mangled appendFormat:@"$%@", blkMangleFragment(p.paramType)];

    XTType* marker = [self.typeTable typeForName:mangled];
    if (!marker || marker.kind != XTTypeKindClass)
        {
        marker = [[XTType alloc] initWithKind:XTTypeKindClass displayName:mangled];
        [self.typeTable registerType:marker forName:mangled];
        }
    if (![self blkBases][mangled])
        {
        [self blkBases][(NSString*)mangled] = @[ ret, [params copy] ];
        }

    self.lastBlockDeclName = declName;
    self.lastBlockBaseName = mangled;
    self.lastBlockParams = params;
    self.lastBlockRet = ret;
    XTType* bt = [XTPointerType pointerToType:marker];
    if (isArray)
        bt = [XTArrayType arrayOfType:bt count:arrayCount];
    return bt;
    }

// ── synthesis ─────────────────────────────────────────────────────────────

// `return (RET)0;` — the base class's placeholder body. A cast keeps one
// shape for every return type; void gets a bare empty body instead.
- (XTBlockNode*)blkDefaultBodyForRet:(XTType*)ret at:(XTSourceLocation*)loc
    {
    if (ret.kind == XTTypeKindVoid)
        {
        return [[XTBlockNode alloc] initWithStatements:@[] location:loc];
        }
    XTASTNode* zero = [[XTLiteralIntNode alloc] initWithValue:0 location:loc];
    XTASTNode* cast = [[XTCastExprNode alloc] initWithType:ret
                                                   operand:zero
                                                  location:loc];
    XTReturnNode* r = [[XTReturnNode alloc] initWithValues:@[ cast ] location:loc];
    return [[XTBlockNode alloc] initWithStatements:@[ r ] location:loc];
    }

/****************************************************************************\
|* Synthesise the base class for every signature seen this parse.
|* Called once, from parse's end; sorted by name so the emitted order
|* is a function of the program text alone.
\****************************************************************************/
- (NSArray<XTASTNode*>*)blkSynthesisedDeclsAt:(XTSourceLocation*)loc
    {
    NSMutableArray<XTASTNode*>* out = [NSMutableArray array];
    NSArray* names = [[self blkBases].allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* name in names)
        {
        NSArray* sig = [self blkBases][name];
        XTType* ret = sig[0];
        NSArray<XTParamNode*>* declared = sig[1];
        // The base's params use positional names — a signature is shared by
        // every literal of that shape, so the user's names cannot appear here.
        NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
        for (NSUInteger i = 0; i < declared.count; i++)
            {
            XTParamNode* d = declared[i];
            [params addObject:[[XTParamNode alloc]
                                  initWithType:d.paramType
                                          name:[NSString stringWithFormat:@"p%lu", (unsigned long)i]
                                      location:loc]];
            }
        XTMethodDeclNode* invoke = [[XTMethodDeclNode alloc]
            initWithName:@"invoke"
             returnTypes:@[ ret ]
              parameters:params
                isStatic:NO
               isVarArgs:NO
                    body:[self blkDefaultBodyForRet:ret at:loc]
                location:loc];
        XTClassDeclNode* base = [[XTClassDeclNode alloc]
             initWithName:name
               parentName:nil
            protocolNames:@[]
                    ivars:@[]
                  methods:@[ invoke ]
                 location:loc];
        [out addObject:base];
        }
    [out addObjectsFromArray:[self blkClasses]];
    return out;
    }

/****************************************************************************\
|* Parse a literal's body and synthesise its impl class. The header has
|* already been parsed (stashes hold the signature); the cursor sits on
|* `{`. Returns the replacement expression: `BlkImpl$N.mk(captures…)`.
\****************************************************************************/
- (nullable XTASTNode*)blkParseLiteralBodyWithBase:(NSString*)baseName
                                               ret:(XTType*)ret
                                            params:(NSArray<XTParamNode*>*)params
                                          selfName:(nullable NSString*)selfName
                                                at:(XTSourceLocation*)loc
    {
    NSUInteger counter = [self.blkState[@"counter"] unsignedIntegerValue];
    self.blkState[@"counter"] = @(counter + 1);
    NSString* implName = [NSString stringWithFormat:@"BlkImpl$%lu",
                                                    (unsigned long)counter];
    if (!self.blkState[@"implBase"])
        self.blkState[@"implBase"] = [NSMutableDictionary dictionary];
    self.blkState[@"implBase"][implName] = baseName;

    // Register the impl's class marker so `new $BlkImplN()` resolves.
    XTType* implMarker = [[XTType alloc] initWithKind:XTTypeKindClass
                                          displayName:implName];
    [self.typeTable registerType:implMarker forName:implName];

    // Capture frame + a scope holding the literal's own params (and, for a
    // named literal, its own name — self-reference dispatches on `self`).
    NSMutableDictionary* frame = [NSMutableDictionary dictionary];
    frame[@"depth"] = @([self blkScopes].count);
    frame[@"names"] = [NSMutableArray array];
    frame[@"types"] = [NSMutableDictionary dictionary];
    frame[@"bases"] = [NSMutableDictionary dictionary];
    frame[@"wb"] = [NSMutableSet set];
    frame[@"selfName"] = selfName ?: (id)[NSNull null];
    [[self blkFrames] addObject:frame];
    [self blkPushScope];
    for (XTParamNode* p in params)
        [self blkBind:p.paramName type:p.paramType];

    XTBlockNode* body = (XTBlockNode*)[self parseBlock];

    [self blkPopScope];
    [[self blkFrames] removeLastObject];

    NSArray<NSString*>* capNames = frame[@"names"];
    NSDictionary* capTypes = frame[@"types"];
    NSDictionary* capBases = frame[@"bases"];
    NSSet* wbSet = frame[@"wb"];
    // Write-back captures, in capture order (v2, task #29).
    NSMutableArray<NSString*>* wbNames = [NSMutableArray array];
    for (NSString* cn in capNames)
        if ([wbSet containsObject:cn])
            [wbNames addObject:cn];

    // A capture that is itself a block passes through as its base-class
    // pointer — the ivar's type is the same marker pointer. A write-back
    // capture adds a hidden `T*` beside its working copy: `name$wb` ($ is
    // unspellable in source, and these names are never lexed).
    NSMutableArray<XTVariableDeclNode*>* ivars = [NSMutableArray array];
    for (NSString* cn in capNames)
        {
        [ivars addObject:[[XTVariableDeclNode alloc]
                             initWithName:cn
                                     type:capTypes[cn]
                              initialiser:nil
                                 location:loc]];
        }
    for (NSString* wn in wbNames)
        {
        [ivars addObject:[[XTVariableDeclNode alloc]
                             initWithName:[wn stringByAppendingString:@"$wb"]
                                     type:[XTPointerType pointerToType:capTypes[wn]]
                              initialiser:nil
                                 location:loc]];
        }
    (void)capBases;

    NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];

    // _set(v0…, w0…): ivar stores — values, then write-back pointers.
    if (capNames.count)
        {
        NSMutableArray<XTParamNode*>* sp = [NSMutableArray array];
        NSMutableArray<XTASTNode*>* stores = [NSMutableArray array];
        for (NSUInteger i = 0; i < capNames.count; i++)
            {
            NSString* cn = capNames[i];
            NSString* vn = [NSString stringWithFormat:@"v%lu", (unsigned long)i];
            [sp addObject:[[XTParamNode alloc] initWithType:capTypes[cn]
                                                       name:vn
                                                   location:loc]];
            XTASTNode* lhs = [[XTIdentifierNode alloc] initWithName:cn location:loc];
            XTASTNode* rhs = [[XTIdentifierNode alloc] initWithName:vn location:loc];
            XTASTNode* as = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign
                                                             lhs:lhs
                                                             rhs:rhs
                                                        location:loc];
            [stores addObject:[[XTExpressionStatementNode alloc]
                                  initWithExpression:as
                                            location:loc]];
            }
        for (NSUInteger i = 0; i < wbNames.count; i++)
            {
            NSString* wn = wbNames[i];
            NSString* pn = [NSString stringWithFormat:@"w%lu", (unsigned long)i];
            [sp addObject:[[XTParamNode alloc]
                              initWithType:[XTPointerType pointerToType:capTypes[wn]]
                                      name:pn
                                  location:loc]];
            XTASTNode* lhs = [[XTIdentifierNode alloc]
                initWithName:[wn stringByAppendingString:@"$wb"]
                    location:loc];
            XTASTNode* rhs = [[XTIdentifierNode alloc] initWithName:pn location:loc];
            XTASTNode* as = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign
                                                             lhs:lhs
                                                             rhs:rhs
                                                        location:loc];
            [stores addObject:[[XTExpressionStatementNode alloc]
                                  initWithExpression:as
                                            location:loc]];
            }
        XTBlockNode* setBody = [[XTBlockNode alloc] initWithStatements:stores
                                                              location:loc];
        [methods addObject:[[XTMethodDeclNode alloc]
                               initWithName:@"_set"
                                returnTypes:@[ [XTType voidType] ]
                                 parameters:sp
                                   isStatic:NO
                                  isVarArgs:NO
                                       body:setBody
                                   location:loc]];
        }

    // invoke override: the literal's body, verbatim — prefixed, when there
    // are write-back captures, with ONE synthesised defer that stores every
    // working copy back through its pointer. A defer runs on every exit,
    // the throw-unwind path included, which is exactly §4's contract.
    XTASTNode* invokeBody = body;
    if (wbNames.count)
        {
        NSMutableArray<XTASTNode*>* wbStores = [NSMutableArray array];
        for (NSString* wn in wbNames)
            {
            XTASTNode* ptr = [[XTIdentifierNode alloc]
                initWithName:[wn stringByAppendingString:@"$wb"]
                    location:loc];
            XTASTNode* deref = [[XTUnaryExprNode alloc]
                initWithOp:XTUnaryOpDeref
                   operand:ptr
                  location:loc];
            XTASTNode* val = [[XTIdentifierNode alloc] initWithName:wn location:loc];
            XTASTNode* as = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign
                                                             lhs:deref
                                                             rhs:val
                                                        location:loc];
            [wbStores addObject:[[XTExpressionStatementNode alloc]
                                    initWithExpression:as
                                              location:loc]];
            }
        XTBlockNode* dBody = [[XTBlockNode alloc] initWithStatements:wbStores
                                                            location:loc];
        XTDeferNode* d = [[XTDeferNode alloc] initWithBody:dBody location:loc];
        NSMutableArray<XTASTNode*>* stmts = [NSMutableArray arrayWithObject:d];
        [stmts addObjectsFromArray:((XTBlockNode*)body).statements];
        invokeBody = [[XTBlockNode alloc] initWithStatements:stmts location:loc];
        }
    [methods addObject:[[XTMethodDeclNode alloc]
                           initWithName:@"invoke"
                            returnTypes:@[ ret ]
                             parameters:params
                               isStatic:NO
                              isVarArgs:NO
                                   body:invokeBody
                               location:loc]];

        // static mk(c0…, p0…) → base*: new + _set + return (upcast).
        {
        NSMutableArray<XTParamNode*>* mp = [NSMutableArray array];
        NSMutableArray<XTASTNode*>* mkArgs = [NSMutableArray array];
        for (NSUInteger i = 0; i < capNames.count; i++)
            {
            NSString* cn = capNames[i];
            NSString* an = [NSString stringWithFormat:@"c%lu", (unsigned long)i];
            [mp addObject:[[XTParamNode alloc] initWithType:capTypes[cn]
                                                       name:an
                                                   location:loc]];
            [mkArgs addObject:[[XTIdentifierNode alloc] initWithName:an location:loc]];
            }
        for (NSUInteger i = 0; i < wbNames.count; i++)
            {
            NSString* wn = wbNames[i];
            NSString* an = [NSString stringWithFormat:@"p%lu", (unsigned long)i];
            [mp addObject:[[XTParamNode alloc]
                              initWithType:[XTPointerType pointerToType:capTypes[wn]]
                                      name:an
                                  location:loc]];
            [mkArgs addObject:[[XTIdentifierNode alloc] initWithName:an location:loc]];
            }
        XTType* baseMarker = [self.typeTable typeForName:baseName];
        XTType* basePtr = [XTPointerType pointerToType:baseMarker];
        XTType* implPtr = [XTPointerType pointerToType:implMarker];

        NSMutableArray<XTASTNode*>* stmts = [NSMutableArray array];
        XTASTNode* newE = [[XTNewExprNode alloc] initWithClassName:implName
                                                         arguments:@[]
                                                          location:loc];
        [stmts addObject:[[XTVariableDeclNode alloc] initWithName:@"t"
                                                             type:implPtr
                                                      initialiser:newE
                                                         location:loc]];
        if (capNames.count)
            {
            XTASTNode* recv = [[XTIdentifierNode alloc] initWithName:@"t" location:loc];
            XTASTNode* setCall = [[XTMethodCallExprNode alloc]
                initWithReceiver:recv
                      methodName:@"_set"
                       arguments:mkArgs
                        location:loc];
            [stmts addObject:[[XTExpressionStatementNode alloc]
                                 initWithExpression:setCall
                                           location:loc]];
            }
        XTASTNode* tRef = [[XTIdentifierNode alloc] initWithName:@"t" location:loc];
        [stmts addObject:[[XTReturnNode alloc] initWithValues:@[ tRef ] location:loc]];
        XTBlockNode* mkBody = [[XTBlockNode alloc] initWithStatements:stmts
                                                             location:loc];
        [methods addObject:[[XTMethodDeclNode alloc]
                               initWithName:@"mk"
                                returnTypes:@[ basePtr ]
                                 parameters:mp
                                   isStatic:YES
                                  isVarArgs:NO
                                       body:mkBody
                                   location:loc]];
        }

    XTClassDeclNode* impl = [[XTClassDeclNode alloc]
         initWithName:implName
           parentName:baseName
        protocolNames:@[]
                ivars:ivars
              methods:methods
             location:loc];
    [[self blkClasses] addObject:impl];

    // The replacement expression. Capture args are USES of the captured
    // names — when this literal sits inside an OUTER literal, those uses
    // must register with the outer frame too (nothing "parses" them).
    // Write-back captures also pass `&name`: an ordinary address-of, so
    // the frame slot is pinned by the machinery user code already uses.
    NSMutableArray<XTASTNode*>* args = [NSMutableArray array];
    for (NSString* cn in capNames)
        {
        [args addObject:[[XTIdentifierNode alloc] initWithName:cn location:loc]];
        [self blkNoteIdentifierUse:cn at:loc];
        }
    for (NSString* wn in wbNames)
        {
        XTASTNode* slot = [[XTIdentifierNode alloc] initWithName:wn location:loc];
        [args addObject:[[XTUnaryExprNode alloc] initWithOp:XTUnaryOpAddrOf
                                                    operand:slot
                                                   location:loc]];
        }
    if (wbNames.count)
        {
        if (!self.blkState[@"wbImpls"])
            self.blkState[@"wbImpls"] = [NSMutableSet set];
        [self.blkState[@"wbImpls"] addObject:implName];
        }
    XTASTNode* cls = [[XTIdentifierNode alloc] initWithName:implName location:loc];
    return [[XTMethodCallExprNode alloc] initWithReceiver:cls
                                               methodName:@"mk"
                                                arguments:args
                                                 location:loc];
    }

/****************************************************************************\
|* A full literal in expression position: `block [name] RET(params) { … }`.
|* The caller has verified blkKeywordAhead.
\****************************************************************************/
- (nullable XTASTNode*)blkParseLiteralExpression
    {
    XTSourceLocation* loc = [self currentLocation];
    if (![self blkParseTypeHeader])
        return nil;
    NSString* name = self.lastBlockDeclName;
    NSString* base = self.lastBlockBaseName;
    NSArray<XTParamNode*>* params = self.lastBlockParams;
    XTType* ret = self.lastBlockRet;
    if (![self checkBlockOpen])
        {
        [self.diagnostics emitError:@"expected '{' to open the block's body "
                                    @"(a bare block type is not an expression)"
                                 at:loc];
        return nil;
        }
    return [self blkParseLiteralBodyWithBase:base
                                         ret:ret
                                      params:params
                                    selfName:name
                                          at:loc];
    }



NS_ASSUME_NONNULL_END

#pragma mark - par blocks (CPU path)

/****************************************************************************\
|* A write to a bare name inside a `par` body: recorded on the par frame, so a
|* captured scalar the body assigns can be refused — each work item has its
|* own copy, and the write would vanish.
\****************************************************************************/
- (void)parNoteWriteTarget:(nullable XTASTNode*)target
    {
    NSMutableDictionary* frame = [self blkFrames].lastObject;
    if (!frame[@"par"] || ![target isKindOfClass:[XTIdentifierNode class]])
        return;
    [frame[@"written"] addObject:((XTIdentifierNode*)target).identName];
    }

/****************************************************************************\
|* The innermost capture frame when it is a `par :grid` body's, else nil. A
|* block literal inside the body has its own frame, so a `return` there is
|* the literal's.
\****************************************************************************/
- (nullable NSMutableDictionary*)parGridFrame
    {
    NSMutableDictionary* frame = [self blkFrames].lastObject;
    return frame[@"grid"] ? frame : nil;
    }

/****************************************************************************\
|* `par.x`, `par.y`, `par.z`, `par.width`, `par.height`, `par.depth` in a
|* `par :grid` body, at the current token: consumed and returned as the name
|* the desugaring declares. Anything else is left alone (nil).
\****************************************************************************/
- (nullable XTASTNode*)parGridMemberAt:(XTSourceLocation*)loc
    {
    NSMutableDictionary* frame = [self parGridFrame];
    if (!frame || ![[self currentToken].value isEqualToString:@"par"] || [self peekToken:1].type != XTTokenDot
        || [self peekToken:2].type != XTTokenIdentifier)
        return nil;
    NSString* m = [self peekToken:2].value;
    NSDictionary* names = @{@"x" : @"par$x", @"y" : @"par$y", @"z" : @"par$z",
                            @"width" : @"par$w", @"height" : @"par$h", @"depth" : @"par$d"};
    NSString* n = names[m];
    if (!n)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a 'par :grid' body has par.x, par.y, par.z, "
                                                                 "par.width, par.height and par.depth, not par.%@", m]
                                 at:loc];
        n = @"par$x"; // parsing goes on as if it were par.x
        }
    [self advance];
    [self advance];
    [self advance];
    [frame[@"gridUsed"] addObject:n];
    return [[XTIdentifierNode alloc] initWithName:n location:loc];
    }

// Loops and switches entered inside a `par :grid` body, for parGridReturn: and
// parGridBreakAt:.
- (void)parGridLoop:(int)delta
    {
    NSMutableDictionary* frame = [self parGridFrame];
    if (frame)
        frame[@"loops"] = @([(NSNumber*)frame[@"loops"] intValue] + delta);
    }

- (void)parGridSwitch:(int)delta
    {
    NSMutableDictionary* frame = [self parGridFrame];
    if (frame)
        frame[@"switches"] = @([(NSNumber*)frame[@"switches"] intValue] + delta);
    }

/****************************************************************************\
|* A `break` outside every loop and switch of a `par :grid` body would end the
|* whole chunk of work items, not this one; `return` is what ends a work item.
\****************************************************************************/
- (void)parGridBreakAt:(XTSourceLocation*)loc
    {
    NSMutableDictionary* frame = [self parGridFrame];
    if (frame && [(NSNumber*)frame[@"loops"] intValue] == 0 && [(NSNumber*)frame[@"switches"] intValue] == 0)
        [self.diagnostics emitError:@"'break' would leave the 'par :grid' body; 'return' ends a work item" at:loc];
    }

/****************************************************************************\
|* `return;` in a `par :grid` body ends the work item: the body runs inside the
|* loop over the grid's points, so it becomes `continue`. Inside a loop of the
|* body's own that `continue` would go to that loop instead, so it is refused
|* there.
\****************************************************************************/
- (nullable XTASTNode*)parGridReturn:(XTReturnNode*)ret
    {
    NSMutableDictionary* frame = [self parGridFrame];
    if (!frame)
        return ret;
    if (ret.values.count)
        {
        [self.diagnostics emitError:@"a 'par :grid' body returns no value: 'return;' ends the work item"
                                 at:ret.location];
        return ret;
        }
    if ([(NSNumber*)frame[@"loops"] intValue] > 0)
        {
        [self.diagnostics emitError:@"'return' inside a loop of a 'par :grid' body: 'break' out of the loop "
                                     "and return after it"
                                 at:ret.location];
        return ret;
        }
    return [[XTContinueNode alloc] initWithLocation:ret.location];
    }

/****************************************************************************\
|* A `par :grid(w, h[, d])` body as the loop form: one loop over the w*h*d
|* points, x fastest, with the point and the grid's size declared at the top
|* of each work item (only those the body uses). The sizes are evaluated once,
|* before the block, into locals the body captures: returned for the site to
|* declare first. A block without :grid is left alone (and gets no
|* declarations).
\****************************************************************************/
- (NSArray<XTASTNode*>*)parGridLoopFor:(XTBlockNode* _Nonnull* _Nonnull)bodyRef
                                 frame:(NSDictionary*)frame
                                    at:(XTSourceLocation*)loc
    {
    NSArray<XTASTNode*>* grid = frame[@"grid"];
    if (!grid)
        return @[];
    NSSet* used = frame[@"gridUsed"];
    XTType* u32T = [self.typeTable typeForName:@"u32"];
    XTType* i64T = [self.typeTable typeForName:@"i64"];
    XTASTNode* (^ident)(NSString*) = ^XTASTNode*(NSString* n) {
      return [[XTIdentifierNode alloc] initWithName:n location:loc];
    };
    XTASTNode* (^cast)(XTType*, XTASTNode*) = ^XTASTNode*(XTType* t, XTASTNode* e) {
      return [[XTCastExprNode alloc] initWithType:t operand:e location:loc];
    };
    XTASTNode* (^bin)(XTBinaryOp, XTASTNode*, XTASTNode*) = ^XTASTNode*(XTBinaryOp op, XTASTNode* l, XTASTNode* r) {
      return [[XTBinaryExprNode alloc] initWithOp:op left:l right:r location:loc];
    };
    XTASTNode* (^decl)(NSString*, XTASTNode*) = ^XTASTNode*(NSString* n, XTASTNode* e) {
      return [[XTVariableDeclNode alloc] initWithName:n type:u32T initialiser:e location:loc];
    };

    // The sizes, in the order the captures list them: width, height, depth.
    BOOL hasD = grid.count == 3;
    NSMutableArray<XTASTNode*>* decls = [NSMutableArray array];
    NSMutableArray<NSString*>* sizes = [NSMutableArray arrayWithObjects:@"par$w", @"par$h", nil];
    [decls addObject:decl(@"par$w", cast(u32T, grid[0]))];
    [decls addObject:decl(@"par$h", cast(u32T, grid[1]))];
    // A 3-D grid captures its depth; a 2-D one's is 1, declared in the work
    // item, so a par$d capture means 3-D (the independence check reads that).
    if (hasD)
        {
        [decls addObject:decl(@"par$d", cast(u32T, grid[2]))];
        [sizes addObject:@"par$d"];
        }
    NSMutableArray* names = frame[@"names"];
    NSMutableDictionary* types = frame[@"types"];
    for (NSString* n in sizes)
        {
        if (![names containsObject:n])
            [names addObject:n];
        types[n] = u32T;
        }

    // Each work item: its point, from the flat index.
    NSMutableArray<XTASTNode*>* st = [NSMutableArray array];
    if ([used containsObject:@"par$x"])
        [st addObject:decl(@"par$x", bin(XTBinaryOpMod, ident(@"par$i"), ident(@"par$w")))];
    if ([used containsObject:@"par$y"])
        [st addObject:decl(@"par$y", bin(XTBinaryOpMod, bin(XTBinaryOpDiv, ident(@"par$i"), ident(@"par$w")),
                                         ident(@"par$h")))];
    if (!hasD && [used containsObject:@"par$d"])
        [st addObject:decl(@"par$d", cast(u32T, [[XTLiteralIntNode alloc] initWithValue:1 location:loc]))];
    if ([used containsObject:@"par$z"])
        [st addObject:decl(@"par$z", bin(XTBinaryOpDiv, ident(@"par$i"),
                                         bin(XTBinaryOpMul, ident(@"par$w"), ident(@"par$h"))))];
    [st addObjectsFromArray:(*bodyRef).statements];
    XTBlockNode* item = [[XTBlockNode alloc] initWithStatements:st location:loc];

    // for (u32 par$i in 0..w*h[*d]), counted in i64 at the site.
    XTASTNode* count = bin(XTBinaryOpMul, cast(i64T, ident(@"par$w")), cast(i64T, ident(@"par$h")));
    if (hasD)
        count = bin(XTBinaryOpMul, count, cast(i64T, ident(@"par$d")));
    XTVariableDeclNode* iv = [[XTVariableDeclNode alloc] initWithName:@"par$i" type:u32T
                                                          initialiser:cast(u32T, [[XTLiteralIntNode alloc] initWithValue:0 location:loc])
                                                             location:loc];
    XTForCStyleNode* loop = [[XTForCStyleNode alloc]
        initWithLoopInit:iv
               condition:bin(XTBinaryOpLt, ident(@"par$i"), count)
               increment:[[XTAssignExprNode alloc] initWithOp:XTAssignOpAdd lhs:ident(@"par$i")
                                                         rhs:[[XTLiteralIntNode alloc] initWithValue:1 location:loc]
                                                    location:loc]
                    body:item
                location:loc];
    *bodyRef = [[XTBlockNode alloc] initWithStatements:@[ loop ] location:loc];
    return decls;
    }

/****************************************************************************\
|* `par [name] (:reduce(op var))* { for (T i in a..b) { … } }` → a ParChunk
|* subclass and its run, the way a block literal becomes a class
|* (private: docs/Design/par-phase1-plan.md, P3). The class's ivars are the
|* captures (a fixed array as a pointer to its first element: `a[i]` reads the
|* same through it) and the reduction variables; run() is the loop over
|* [lo, hi); copyChunk() and merge() serve Par.run (support/generic/lib/Par.xc).
|* The site becomes: make the chunk, Par.run it, fold the reductions back.
\****************************************************************************/
- (nullable XTASTNode*)parDesugarBody:(XTBlockNode*)body
                                 frame:(NSDictionary*)frame
                                  name:(nullable NSString*)parName
                            reductions:(NSArray<NSArray<NSString*>*>*)reductions
                                    at:(XTSourceLocation*)loc
    {
    NSString* label = parName ? [NSString stringWithFormat:@"par %@", parName] : @"par";
    NSArray<XTASTNode*>* gridDecls = [self parGridLoopFor:&body frame:frame at:loc];
    // ── the loop form: exactly one ascending `for (T i in a..b)` ──
    XTForCStyleNode* loop = body.statements.count == 1 && [body.statements[0] isKindOfClass:[XTForCStyleNode class]]
                                ? (XTForCStyleNode*)body.statements[0] : nil;
    XTVariableDeclNode* iv = [loop.loopInit isKindOfClass:[XTVariableDeclNode class]]
                                 ? (XTVariableDeclNode*)loop.loopInit : nil;
    XTBinaryExprNode* cond = [loop.condition isKindOfClass:[XTBinaryExprNode class]]
                                 ? (XTBinaryExprNode*)loop.condition : nil;
    XTAssignExprNode* step = [loop.increment isKindOfClass:[XTAssignExprNode class]]
                                 ? (XTAssignExprNode*)loop.increment : nil;
    BOOL ok = loop && iv && iv.initialiser && iv.declaredType && cond
              && (cond.op == XTBinaryOpLt || cond.op == XTBinaryOpLe)
              && [cond.left isKindOfClass:[XTIdentifierNode class]]
              && [((XTIdentifierNode*)cond.left).identName isEqualToString:iv.varName]
              && step && step.assignOp == XTAssignOpAdd
              && [step.rhs isKindOfClass:[XTLiteralIntNode class]] && ((XTLiteralIntNode*)step.rhs).intValue == 1;
    if (!ok)
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"a '%@' block's body is one ascending loop: "
                                                                 "par { for (T i in a..b) { ... } }",
                                                               label]
                                 at:loc];
        return nil;
        }
    if (![self.typeTable typeForName:@"ParChunk"])
        {
        [self.diagnostics emitError:@"a 'par' block needs its runtime: #import \"Par.xc\"" at:loc];
        return nil;
        }
    XTType* ivT = iv.declaredType;

    // ── captures, reductions, writes ──
    NSArray<NSString*>* frameNames = frame[@"names"];
    NSDictionary* frameTypes = frame[@"types"];
    NSSet* written = frame[@"written"];
    NSMutableDictionary<NSString*, NSArray<NSString*>*>* redByVar = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, XTType*>* redTypes = [NSMutableDictionary dictionary];
    for (NSArray<NSString*>* r in reductions)
        {
        NSUInteger d = 0;
        NSDictionary* info = [self blkLookup:r[1] depth:&d];
        XTType* t = frameTypes[r[1]] ?: (info ? info[@"type"] : nil);
        if (![t isKindOfClass:[XTType class]])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"':reduce(%@ %@)': '%@' is not a local "
                                                                     "declared before the '%@' block",
                                                                   r[0], r[1], r[1], label]
                                     at:loc];
            return nil;
            }
        redByVar[r[1]] = r;
        redTypes[r[1]] = t;
        }
    NSMutableArray<NSString*>* caps = [NSMutableArray array];
    for (NSString* cn in frameNames)
        if (!redByVar[cn])
            [caps addObject:cn];
    for (NSString* cn in caps)
        {
        XTType* t = frameTypes[cn];
        if ([written containsObject:cn] && ![t isKindOfClass:[XTArrayType class]])
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"a '%@' block cannot assign to '%@': every work "
                                                                     "item has its own copy of it. Make it a reduction "
                                                                     "(:reduce(+ %@)) or write into an array",
                                                                   label, cn, cn]
                                     at:loc];
            return nil;
            }
        }

    // ── the class ──
    NSUInteger counter = [self.blkState[@"parCounter"] unsignedIntegerValue];
    self.blkState[@"parCounter"] = @(counter + 1);
    NSString* implName = [NSString stringWithFormat:@"ParImpl$%lu", (unsigned long)counter];
    XTType* implMarker = [[XTType alloc] initWithKind:XTTypeKindClass displayName:implName];
    [self.typeTable registerType:implMarker forName:implName];
    XTType* implPtr = [XTPointerType pointerToType:implMarker];
    XTType* chunkPtr = [XTPointerType pointerToType:[self.typeTable typeForName:@"ParChunk"]];
    XTType* i64T = [self.typeTable typeForName:@"i64"];

    XTASTNode* (^ident)(NSString*) = ^XTASTNode*(NSString* n) {
      return [[XTIdentifierNode alloc] initWithName:n location:loc];
    };
    XTASTNode* (^member)(NSString*, NSString*) = ^XTASTNode*(NSString* b, NSString* m) {
      return [[XTMemberAccessNode alloc] initWithBase:ident(b) memberName:m isArrow:NO location:loc];
    };
    XTASTNode* (^stmt)(XTASTNode*) = ^XTASTNode*(XTASTNode* e) {
      return [[XTExpressionStatementNode alloc] initWithExpression:e location:loc];
    };
    XTASTNode* (^assign)(XTASTNode*, XTASTNode*) = ^XTASTNode*(XTASTNode* l, XTASTNode* r) {
      return stmt([[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign lhs:l rhs:r location:loc]);
    };
    XTASTNode* (^cast)(XTType*, XTASTNode*) = ^XTASTNode*(XTType* t, XTASTNode* e) {
      return [[XTCastExprNode alloc] initWithType:t operand:e location:loc];
    };
    // A reduction's starting value: the identity for + * ^, and for the
    // idempotent & | min max the variable's current value (min(x, x) == x).
    XTASTNode* (^startOf)(NSArray<NSString*>*, XTASTNode*) = ^XTASTNode*(NSArray<NSString*>* r, XTASTNode* cur) {
      NSString* op = r[0];
      XTType* t = redTypes[r[1]];
      if ([op isEqualToString:@"+"] || [op isEqualToString:@"^"])
          return cast(t, [[XTLiteralIntNode alloc] initWithValue:0 location:loc]);
      if ([op isEqualToString:@"*"])
          return cast(t, [[XTLiteralIntNode alloc] initWithValue:1 location:loc]);
      return cur;
    };
    // `dst = dst OP src` for + * & | ^; for min / max `if (src < dst) dst = src`.
    XTASTNode* (^fold)(NSString*, XTASTNode*, XTASTNode*, XTASTNode*) =
        ^XTASTNode*(NSString* op, XTASTNode* dst, XTASTNode* dst2, XTASTNode* src) {
          if ([op isEqualToString:@"min"] || [op isEqualToString:@"max"])
              {
              XTASTNode* c = [[XTBinaryExprNode alloc] initWithOp:([op isEqualToString:@"min"] ? XTBinaryOpLt : XTBinaryOpGt)
                                                             left:src
                                                            right:dst2
                                                         location:loc];
              XTBlockNode* then = [[XTBlockNode alloc] initWithStatements:@[ assign(dst, src) ] location:loc];
              return [[XTIfNode alloc] initWithCondition:c thenBlock:then elseBlock:nil location:loc];
              }
          XTBinaryOp bop = [op isEqualToString:@"+"] ? XTBinaryOpAdd
                           : [op isEqualToString:@"*"] ? XTBinaryOpMul
                           : [op isEqualToString:@"&"] ? XTBinaryOpBitAnd
                           : [op isEqualToString:@"|"] ? XTBinaryOpBitOr
                                                       : XTBinaryOpBitXor;
          return assign(dst, [[XTBinaryExprNode alloc] initWithOp:bop left:dst2 right:src location:loc]);
        };

    NSMutableArray<XTVariableDeclNode*>* ivars = [NSMutableArray array];
    for (NSString* cn in caps)
        {
        XTType* t = frameTypes[cn];
        if ([t isKindOfClass:[XTArrayType class]])
            t = [XTPointerType pointerToType:((XTArrayType*)t).elementType];
        [ivars addObject:[[XTVariableDeclNode alloc] initWithName:cn type:t initialiser:nil location:loc]];
        }
    for (NSArray<NSString*>* r in reductions)
        [ivars addObject:[[XTVariableDeclNode alloc] initWithName:r[1] type:redTypes[r[1]] initialiser:nil location:loc]];

    NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];
    // run(): the loop over [lo, hi), the body verbatim.
        {
        XTVariableDeclNode* init = [[XTVariableDeclNode alloc] initWithName:iv.varName
                                                                       type:ivT
                                                                initialiser:cast(ivT, ident(@"lo"))
                                                                   location:loc];
        XTASTNode* c = [[XTBinaryExprNode alloc] initWithOp:XTBinaryOpLt
                                                       left:ident(iv.varName)
                                                      right:cast(ivT, ident(@"hi"))
                                                   location:loc];
        XTForCStyleNode* f = [[XTForCStyleNode alloc] initWithLoopInit:init
                                                             condition:c
                                                             increment:loop.increment
                                                                  body:loop.body
                                                              location:loc];
        XTBlockNode* rb = [[XTBlockNode alloc] initWithStatements:@[ f ] location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"run" returnTypes:@[ [XTType voidType] ]
                                                       parameters:@[] isStatic:NO isVarArgs:NO body:rb location:loc]];
        }
    // copyChunk(): a fresh chunk with the same captures, reductions at their start.
        {
        NSMutableArray<XTASTNode*>* st = [NSMutableArray array];
        [st addObject:[[XTVariableDeclNode alloc] initWithName:@"t" type:implPtr
                                                   initialiser:[[XTNewExprNode alloc] initWithClassName:implName
                                                                                              arguments:@[]
                                                                                               location:loc]
                                                      location:loc]];
        for (NSString* cn in caps)
            [st addObject:assign(member(@"t", cn), ident(cn))];
        for (NSArray<NSString*>* r in reductions)
            [st addObject:assign(member(@"t", r[1]), startOf(r, ident(r[1])))];
        [st addObject:[[XTReturnNode alloc] initWithValues:@[ ident(@"t") ] location:loc]];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"copyChunk" returnTypes:@[ chunkPtr ]
                                                       parameters:@[] isStatic:NO isVarArgs:NO
                                                             body:[[XTBlockNode alloc] initWithStatements:st location:loc]
                                                         location:loc]];
        }
    // gpuLength(k): the byte length of own ivar k when it is a captured array
    // (a GPU buffer), else -1. The GPU runtime sizes its buffers from this.
        {
        NSMutableArray<XTASTNode*>* st = [NSMutableArray array];
        XTType* i32T = [self.typeTable typeForName:@"i32"];
        NSUInteger j = 0;
        for (NSString* cn in caps)
            {
            XTType* t = frameTypes[cn];
            if ([t isKindOfClass:[XTArrayType class]] && ((XTArrayType*)t).elementCount > 0)
                {
                XTArrayType* at = (XTArrayType*)t;
                XTASTNode* bytes = [[XTBinaryExprNode alloc]
                    initWithOp:XTBinaryOpMul
                          left:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:(int64_t)at.elementCount location:loc])
                         right:cast(i64T, [[XTSizeofExprNode alloc] initWithOperand:at.elementType location:loc])
                      location:loc];
                XTASTNode* test = [[XTBinaryExprNode alloc]
                    initWithOp:XTBinaryOpEq
                          left:ident(@"k")
                         right:cast(i32T, [[XTLiteralIntNode alloc] initWithValue:(int64_t)j location:loc])
                      location:loc];
                XTBlockNode* then = [[XTBlockNode alloc]
                    initWithStatements:@[ [[XTReturnNode alloc] initWithValues:@[ bytes ] location:loc] ]
                              location:loc];
                [st addObject:[[XTIfNode alloc] initWithCondition:test thenBlock:then elseBlock:nil location:loc]];
                }
            j++;
            }
        XTASTNode* none = [[XTBinaryExprNode alloc]
            initWithOp:XTBinaryOpSub
                  left:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:0 location:loc])
                 right:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:1 location:loc])
              location:loc];
        [st addObject:[[XTReturnNode alloc] initWithValues:@[ none ] location:loc]];
        XTParamNode* p = [[XTParamNode alloc] initWithType:i32T name:@"k" location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"gpuLength" returnTypes:@[ i64T ]
                                                       parameters:@[ p ] isStatic:NO isVarArgs:NO
                                                             body:[[XTBlockNode alloc] initWithStatements:st location:loc]
                                                         location:loc]];
        }
    // gpuGlobal(name) / gpuGlobalBytes(name): where each global the body
    // uses lives and how big it is, by the name the Metal kernel's header
    // gives it. The runtime copies each one in and back, as a buffer.
        {
        NSDictionary* topVars = self.blkState[@"topVars"];
        NSMutableArray<NSString*>* globs = [NSMutableArray array];
        for (NSString* n in frame[@"outer"])
            if (topVars[n])
                [globs addObject:n];
        XTType* u8p = [XTPointerType pointerToType:[self.typeTable typeForName:@"u8"]];
        XTType* ptrT = [self.typeTable typeForName:@"pointer"];
        NSMutableArray<XTASTNode*>* addrSt = [NSMutableArray array];
        NSMutableArray<XTASTNode*>* sizeSt = [NSMutableArray array];
        for (NSString* g in globs)
            {
            XTASTNode* (^isName)(void) = ^XTASTNode*(void) {
                return [[XTCallExprNode alloc] initWithCallee:@"parSameName"
                                                    arguments:@[ ident(@"name"),
                                                                 [[XTLiteralStringNode alloc] initWithString:g location:loc] ]
                                                     location:loc];
            };
            XTASTNode* target = ident(g);
            if ([topVars[g] isKindOfClass:[XTArrayType class]])
                target = [[XTSubscriptExprNode alloc] initWithBase:ident(g)
                                                             index:[[XTLiteralIntNode alloc] initWithValue:0 location:loc]
                                                          location:loc];
            XTASTNode* addr = cast(ptrT, [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpAddrOf operand:target location:loc]);
            XTBlockNode* thenA = [[XTBlockNode alloc]
                initWithStatements:@[ [[XTReturnNode alloc] initWithValues:@[ addr ] location:loc] ] location:loc];
            [addrSt addObject:[[XTIfNode alloc] initWithCondition:isName() thenBlock:thenA elseBlock:nil location:loc]];
            // count * sizeof(element), not sizeof(g): sizeof is a u16, so a
            // global over 64 KB would come out wrapped (bug 615).
            XTASTNode* bytes = cast(i64T, [[XTSizeofExprNode alloc] initWithOperand:ident(g) location:loc]);
            if ([topVars[g] isKindOfClass:[XTArrayType class]] && ((XTArrayType*)topVars[g]).elementCount > 0)
                bytes = [[XTBinaryExprNode alloc]
                    initWithOp:XTBinaryOpMul
                          left:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:(int64_t)((XTArrayType*)topVars[g]).elementCount
                                                                         location:loc])
                         right:cast(i64T, [[XTSizeofExprNode alloc] initWithOperand:((XTArrayType*)topVars[g]).elementType
                                                                           location:loc])
                      location:loc];
            XTBlockNode* thenS = [[XTBlockNode alloc]
                initWithStatements:@[ [[XTReturnNode alloc] initWithValues:@[ bytes ] location:loc] ] location:loc];
            [sizeSt addObject:[[XTIfNode alloc] initWithCondition:isName() thenBlock:thenS elseBlock:nil location:loc]];
            }
        [addrSt addObject:[[XTReturnNode alloc]
                              initWithValues:@[ cast(ptrT, [[XTLiteralIntNode alloc] initWithValue:0 location:loc]) ]
                                    location:loc]];
        [sizeSt addObject:[[XTReturnNode alloc]
                              initWithValues:@[ [[XTBinaryExprNode alloc]
                                                   initWithOp:XTBinaryOpSub
                                                         left:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:0 location:loc])
                                                        right:cast(i64T, [[XTLiteralIntNode alloc] initWithValue:1 location:loc])
                                                     location:loc] ]
                                    location:loc]];
        XTParamNode* pa = [[XTParamNode alloc] initWithType:u8p name:@"name" location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"gpuGlobal" returnTypes:@[ ptrT ]
                                                       parameters:@[ pa ] isStatic:NO isVarArgs:NO
                                                             body:[[XTBlockNode alloc] initWithStatements:addrSt location:loc]
                                                         location:loc]];
        XTParamNode* pb = [[XTParamNode alloc] initWithType:u8p name:@"name" location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"gpuGlobalBytes" returnTypes:@[ i64T ]
                                                       parameters:@[ pb ] isStatic:NO isVarArgs:NO
                                                             body:[[XTBlockNode alloc] initWithStatements:sizeSt location:loc]
                                                         location:loc]];
        }
    // parName(): what the block is called at run time (its device setting,
    // reports): its source name, or file:line for an unnamed block.
        {
        NSString* nm = parName ?: [NSString stringWithFormat:@"%@:%lu", loc.filename.lastPathComponent ?: @"?",
                                                             (unsigned long)loc.line];
        XTBlockNode* b = [[XTBlockNode alloc]
            initWithStatements:@[ [[XTReturnNode alloc]
                                     initWithValues:@[ [[XTLiteralStringNode alloc] initWithString:nm location:loc] ]
                                           location:loc] ]
                      location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"parName"
                                                      returnTypes:@[ [XTPointerType pointerToType:[self.typeTable typeForName:@"u8"]] ]
                                                       parameters:@[] isStatic:NO isVarArgs:NO body:b location:loc]];
        }
    // gpuSource(): the kernel's GPU source. A placeholder string, unique per
    // block, that the lowering replaces with the printed kernel (or with ""
    // when the block cannot run on the GPU); `__XC_PAR_FAST_<n>__` for a
    // block whose goal is speed (the default), whose kernel may use fast maths.
        {
        XTASTNode* lit = [[XTLiteralStringNode alloc]
            initWithString:[NSString stringWithFormat:frame[@"fast"] ? @"__XC_PAR_FAST_%lu__" : @"__XC_PAR_MSL_%lu__",
                                                      (unsigned long)counter]
                  location:loc];
        XTBlockNode* b = [[XTBlockNode alloc]
            initWithStatements:@[ [[XTReturnNode alloc] initWithValues:@[ lit ] location:loc] ]
                      location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"gpuSource"
                                                      returnTypes:@[ [XTPointerType pointerToType:[self.typeTable typeForName:@"u8"]] ]
                                                       parameters:@[] isStatic:NO isVarArgs:NO body:b location:loc]];
        }
    // merge(other): fold another chunk's reductions into this one's.
        {
        NSMutableArray<XTASTNode*>* st = [NSMutableArray array];
        // The downcast only when there is something to fold: an unused `o`
        // reads as a never-used local to the analyser (-Wanalyze).
        if (reductions.count)
            [st addObject:[[XTVariableDeclNode alloc] initWithName:@"o" type:implPtr
                                                       initialiser:cast(implPtr, ident(@"other"))
                                                          location:loc]];
        for (NSArray<NSString*>* r in reductions)
            [st addObject:fold(r[0], ident(r[1]), ident(r[1]), member(@"o", r[1]))];
        XTParamNode* p = [[XTParamNode alloc] initWithType:chunkPtr name:@"other" location:loc];
        [methods addObject:[[XTMethodDeclNode alloc] initWithName:@"merge" returnTypes:@[ [XTType voidType] ]
                                                       parameters:@[ p ] isStatic:NO isVarArgs:NO
                                                             body:[[XTBlockNode alloc] initWithStatements:st location:loc]
                                                         location:loc]];
        }
    XTClassDeclNode* impl = [[XTClassDeclNode alloc] initWithName:implName
                                                       parentName:@"ParChunk"
                                                    protocolNames:@[]
                                                            ivars:ivars
                                                          methods:methods
                                                         location:loc];
    [[self blkClasses] addObject:impl];

    // ── the site ──
    NSString* pv = [NSString stringWithFormat:@"$par%lu", (unsigned long)counter];
    NSMutableArray<XTASTNode*>* site = [NSMutableArray arrayWithArray:gridDecls];
    [site addObject:[[XTVariableDeclNode alloc] initWithName:pv type:implPtr
                                                 initialiser:[[XTNewExprNode alloc] initWithClassName:implName
                                                                                            arguments:@[]
                                                                                             location:loc]
                                                    location:loc]];
    for (NSString* cn in caps)
        {
        XTASTNode* v = ident(cn);
        if ([frameTypes[cn] isKindOfClass:[XTArrayType class]])
            v = [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpAddrOf
                                            operand:[[XTSubscriptExprNode alloc] initWithBase:ident(cn)
                                                                                         index:[[XTLiteralIntNode alloc] initWithValue:0 location:loc]
                                                                                      location:loc]
                                           location:loc];
        [site addObject:assign(member(pv, cn), v)];
        [self blkNoteIdentifierUse:cn at:loc];
        }
    for (NSArray<NSString*>* r in reductions)
        {
        [site addObject:assign(member(pv, r[1]), startOf(r, ident(r[1])))];
        [self blkNoteIdentifierUse:r[1] at:loc];
        }
    XTASTNode* hi = cond.right;
    if (cond.op == XTBinaryOpLe)
        hi = [[XTBinaryExprNode alloc] initWithOp:XTBinaryOpAdd left:cast(i64T, hi)
                                            right:[[XTLiteralIntNode alloc] initWithValue:1 location:loc] location:loc];
    XTASTNode* run = [[XTMethodCallExprNode alloc] initWithReceiver:ident(@"Par")
                                                         methodName:@"run"
                                                          arguments:@[ ident(pv), cast(i64T, iv.initialiser), cast(i64T, hi) ]
                                                           location:loc];
    [site addObject:stmt(run)];
    for (NSArray<NSString*>* r in reductions)
        {
        NSString* op = r[0];
        BOOL idem = [op isEqualToString:@"&"] || [op isEqualToString:@"|"] || [op isEqualToString:@"min"]
                    || [op isEqualToString:@"max"];
        [site addObject:idem ? assign(ident(r[1]), member(pv, r[1]))
                             : fold(op, ident(r[1]), ident(r[1]), member(pv, r[1]))];
        }
    return [[XTBlockNode alloc] initWithStatements:site location:loc];
    }

@end
