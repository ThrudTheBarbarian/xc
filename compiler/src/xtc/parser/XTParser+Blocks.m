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

@end

NS_ASSUME_NONNULL_END
