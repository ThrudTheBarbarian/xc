#import "XTParser+Private.h"
#import "XTLexer.h"

// C reserved words that may not be used as variable names
static NSSet<NSString*>* sCReservedWords = nil;

@implementation XTParser

@synthesize parAutoTrace = _parAutoTrace;

/****************************************************************************\
|* One-time class setup: populate the set of C reserved words that may
|* not be used as variable names in xtc source.
\****************************************************************************/
+ (void)initialize
    {
    if (self == [XTParser class])
        {
        sCReservedWords = [NSSet setWithArray:@[
            @"auto",
            @"break",
            @"case",
            @"char",
            @"const",
            @"continue",
            @"default",
            @"do",
            @"else",
            @"enum",
            @"extern",
            @"float",
            @"for",
            @"goto",
            @"if",
            @"inline",
            @"int",
            @"long",
            @"register",
            @"restrict",
            @"return",
            @"short",
            @"signed",
            @"sizeof",
            @"static",
            @"struct",
            @"switch",
            @"typedef",
            @"union",
            @"unsigned",
            @"void",
            @"volatile",
            @"while",
        ]];
        }
    }

/****************************************************************************\
|* Initialise the parser with a token stream, a type table for resolving
|* user-defined type names, and a diagnostic engine for error reporting.
|* @param tokens       Ordered array of lexer tokens to parse.
|* @param typeTable    Global type registry for resolving type names.
|* @param diagnostics  Diagnostic engine for emitting errors and warnings.
|* @return  A fully initialised parser ready for -parse.
\****************************************************************************/
- (instancetype)initWithTokens:(NSArray<XTToken*>*)tokens
                     typeTable:(XTTypeTable*)typeTable
                   diagnostics:(XTDiagnosticEngine*)diagnostics
    {
    self = [super init];
    if (self)
        {
        _tokens = [tokens mutableCopy];
        _typeTable = typeTable;
        _diagnostics = diagnostics;
        _pos = 0;
        _defaultPointerPlacement = XTPointerPlacementMain;
        _protocolNames = [NSMutableSet set];
        }
    return self;
    }

#pragma mark - Token Access

/****************************************************************************\
|* Return the token at the current position, or the EOF token if past the end.
|* @return  The current token.
\****************************************************************************/
- (XTToken*)currentToken
    {
    if (_pos < _tokens.count)
        return _tokens[_pos];
    return _tokens.lastObject; // EOF
    }

/****************************************************************************\
|* Peek ahead by `offset` tokens from the current position without advancing.
|* @param offset  Number of tokens to look ahead (0 = current token).
|* @return  The token at (pos + offset), or the EOF token if past the end.
\****************************************************************************/
- (XTToken*)peekToken:(NSUInteger)offset
    {
    NSUInteger idx = _pos + offset;
    if (idx < _tokens.count)
        return _tokens[idx];
    return _tokens.lastObject;
    }

/****************************************************************************\
|* Consume the current token and advance the position by one.
|* @return  The token that was at the current position before advancing.
\****************************************************************************/
- (XTToken*)advance
    {
    XTToken* tok = [self currentToken];
    if (_pos < _tokens.count - 1)
        _pos++;
    return tok;
    }

/****************************************************************************\
|* Test whether the current token matches the given type without consuming it.
|* @param type  The token type to check against.
|* @return  YES if the current token matches.
\****************************************************************************/
- (BOOL)check:(XTTokenType)type
    {
    return [self currentToken].type == type;
    }

/****************************************************************************\
|* YES if `t` spells the pointer sigil.
|*
|* The language is moving from `@` to `*` (`u8@` -> `u8*`, `@p` -> `*p`), so
|* both are accepted while the tree converts. `*` is unambiguous despite also
|* being multiply, because the two never occupy the same position: a sigil is
|* a suffix in a TYPE or a prefix in an expression, and multiply is infix.
\****************************************************************************/
static inline BOOL XTIsPointerSigil(XTTokenType t)
    {
    return t == XTTokenAt || t == XTTokenStar;
    }

/****************************************************************************\
|* Consume a pointer sigil if one is present.
\****************************************************************************/
- (BOOL)matchPointerSigil
    {
    if (!XTIsPointerSigil([self currentToken].type))
        return NO;
    [self advance];
    return YES;
    }

/****************************************************************************\
|* If the current token matches `type`, consume it and return YES; otherwise
|* return NO.
|* @param type  The token type to match.
|* @return  YES if the token was matched and consumed.
\****************************************************************************/
- (BOOL)match:(XTTokenType)type
    {
    if (![self check:type])
        return NO;
    [self advance];
    return YES;
    }

/****************************************************************************\
|* Assert that the current token is `type`, consume it, and return it. If the
|* token does not match, emit a diagnostic error and return nil.
|* @param type  The expected token type.
|* @return  The consumed token, or nil on mismatch.
\****************************************************************************/
- (nullable XTToken*)expect:(XTTokenType)type
    {
    if ([self check:type])
        return [self advance];
    XTToken* cur = [self currentToken];
    NSString* msg = [NSString stringWithFormat:@"Expected '%@' but found '%@'",
                                               XTTokenTypeName(type), cur.value];
    [_diagnostics emitError:msg at:cur.location];
    return nil;
    }

/****************************************************************************\
|* Return the source location of the current token.
|* @return  The current token's XTSourceLocation.
\****************************************************************************/
- (XTSourceLocation*)currentLocation
    {
    return [self currentToken].location;
    }

/****************************************************************************\
|* Resolve the size expression of a `T name[EXPR];` array declaration
|* into an element count. Accepts only compile-time integer literals.
|* The parser used to silently fall back to count=0 on anything else,
|* which let `u8 buf[someUndeclaredName];` compile as a zero-byte
|* backing storage — silently mis-emitting the whole program. Emit a
|* diagnostic instead and return 0 so downstream passes keep walking.
\****************************************************************************/
- (NSUInteger)resolveArraySizeExpr:(XTASTNode*)sizeExpr
    {
    int64_t v = 0;
    if ([self foldIntConstExpr:sizeExpr into:&v] && v > 0xFFFFFFFFLL)
        {
        // Past 32 bits the count wrapped, and the array with it (#293).
        [_diagnostics emitError:[NSString stringWithFormat:@"Array size %lld does not fit in 32 bits", (long long)v]
                             at:sizeExpr.location ?: [self currentLocation]];
        return 0;
        }
    if ([self foldIntConstExpr:sizeExpr into:&v] && v >= 0)
        {
        return (NSUInteger)v;
        }
    NSString* shown = nil;
    if ([sizeExpr isKindOfClass:[XTIdentifierNode class]])
        {
        shown = [NSString stringWithFormat:@"'%@'",
                                           ((XTIdentifierNode*)sizeExpr).identName];
        }
    [_diagnostics emitError:[NSString stringWithFormat:
                                          @"Array size must constant-fold to a non-negative integer%@",
                                          shown ? [NSString stringWithFormat:@" (%@ does not fold — check for typos or a missing #define)", shown] : @""]
                         at:sizeExpr.location ?: [self currentLocation]];
    return 0;
    }

/****************************************************************************\
|* Fold a parse-time constant integer expression: literals through the
|* arithmetic and bit operators, and unary -/~. Identifiers deliberately do
|* NOT fold — the parser holds no symbol values, and the case this exists
|* for (`u8 buf[EVSZ * MAXEV]`, both macros literal) arrives as pure
|* literals after preprocessing. Division/modulo by a folded zero refuses
|* to fold rather than trapping.
\****************************************************************************/
- (BOOL)foldIntConstExpr:(XTASTNode*)e into:(int64_t*)out
    {
    if ([e isKindOfClass:[XTLiteralIntNode class]])
        {
        *out = ((XTLiteralIntNode*)e).intValue;
        return YES;
        }
    if ([e isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)e;
        int64_t v = 0;
        if (![self foldIntConstExpr:u.operand into:&v])
            return NO;
        switch (u.op)
            {
        case XTUnaryOpNeg:
            *out = -v;
            return YES;
        case XTUnaryOpBitNot:
            *out = ~v;
            return YES;
        default:
            return NO;
            }
        }
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)e;
        int64_t l = 0, r = 0;
        if (![self foldIntConstExpr:b.left into:&l] ||
            ![self foldIntConstExpr:b.right into:&r])
            return NO;
        switch (b.op)
            {
        case XTBinaryOpAdd:
            *out = l + r;
            return YES;
        case XTBinaryOpSub:
            *out = l - r;
            return YES;
        case XTBinaryOpMul:
            *out = l * r;
            return YES;
        case XTBinaryOpDiv:
            if (r == 0)
                return NO;
            *out = l / r;
            return YES;
        case XTBinaryOpMod:
            if (r == 0)
                return NO;
            *out = l % r;
            return YES;
        case XTBinaryOpShl:
            *out = (int64_t)((uint64_t)l << (r & 63));
            return YES;
        case XTBinaryOpShr:
            *out = (int64_t)((uint64_t)l >> (r & 63));
            return YES;
        case XTBinaryOpBitAnd:
            *out = l & r;
            return YES;
        case XTBinaryOpBitOr:
            *out = l | r;
            return YES;
        case XTBinaryOpBitXor:
            *out = l ^ r;
            return YES;
        default:
            return NO;
            }
        }
    return NO;
    }

#pragma mark - Top-Level Parse

- (nullable XTProgramNode*)parse
    {
    XTSourceLocation* loc = [self currentLocation];
    NSMutableArray<XTASTNode*>* decls = [NSMutableArray array];

    // Forward-reference pre-scan. Walk the token stream once and
    // register every `class Foo` / `struct Foo` / `enum Foo` name in
    // the type table so a later user-site like `Foo x;` can resolve
    // it before the actual declaration has been parsed. For classes
    // the placeholder is the same pointer-to-class-marker that
    // parseClassDecl produces; for structs and enums we register an
    // empty placeholder that the real declaration fills in via
    // `replaceFields:` / `replaceMembers:`, so any AST node that
    // captured the placeholder picks up the real layout once the
    // body has been parsed.
    [self rewriteProtocolStaticReceivers];
    [self prescanForwardTypeDeclarations];

    while (![self check:XTTokenEOF] && !_diagnostics.hasFatalError)
        {
        XTASTNode* decl = [self parseTopLevelDeclaration];
        if (decl)
            [decls addObject:decl];
        // The program's globals so far, by name: a `par` body that uses one
        // gets it on the GPU as a buffer (gpuGlobal, XTParser+Blocks.m).
        if ([decl isKindOfClass:[XTVariableDeclNode class]] && ((XTVariableDeclNode*)decl).declaredType)
            {
            NSMutableDictionary* tv = self.blkState[@"topVars"];
            if (!tv)
                self.blkState[@"topVars"] = tv = [NSMutableDictionary dictionary];
            tv[((XTVariableDeclNode*)decl).varName] = ((XTVariableDeclNode*)decl).declaredType;
            }
        }

    // Blocks (task #26): the per-signature base classes (sorted by name)
    // and the per-literal impl classes (in creation order) join the
    // program here, as ordinary class declarations.
    [decls addObjectsFromArray:[self blkSynthesisedDeclsAt:loc]];
    // Protocols' static members (bundles-and-plugins.md §3): each protocol
    // that has them gets its companion class.
    [decls addObjectsFromArray:[self protocolCompanionsFor:decls]];

    return [[XTProgramNode alloc] initWithDeclarations:decls location:loc];
    }

/****************************************************************************|* Static members of a protocol (bundles-and-plugins.md §3): the interface
|* between a host and a plugin. `P.f(args)` names the member; the parser
|* rewrites the receiver to the protocol's companion class `_XtP_P`, which it
|* synthesises after the program: where a class of this program conforms to
|* P and defines every member as a static method (the HOST), each member
|* forwards to it and `table()` returns their addresses, in declaration order;
|* elsewhere (a PLUGIN) each member calls through the table `bind(t)` was
|* given at load. `versionMajor()` / `versionMinor()` give `:version(M.m)`.
|* Mirrored in the port's parser, text for text.
\****************************************************************************/
- (void)rewriteProtocolStaticReceivers
    {
    NSUInteger n = _tokens.count;
    NSMutableSet<NSString*>* withStatics = [NSMutableSet set];
    for (NSUInteger i = 0; i + 1 < n; i++)
        {
        if (_tokens[i].type != XTTokenProtocol || _tokens[i + 1].type != XTTokenIdentifier)
            continue;
        NSUInteger j = i + 2;
        while (j < n && _tokens[j].type != XTTokenLBrace)
            j++;
        NSInteger depth = 0;
        for (; j < n; j++)
            {
            if (_tokens[j].type == XTTokenLBrace)
                depth++;
            else if (_tokens[j].type == XTTokenRBrace && --depth == 0)
                break;
            else if (_tokens[j].type == XTTokenStatic && depth == 1)
                [withStatics addObject:_tokens[i + 1].value];
            }
        }
    if (!withStatics.count)
        return;
    NSMutableArray<XTToken*>* t = [_tokens mutableCopy];
    for (NSUInteger i = 0; i + 1 < n; i++)
        {
        XTToken* tk = t[i];
        if (tk.type != XTTokenIdentifier || t[i + 1].type != XTTokenDot || ![withStatics containsObject:tk.value])
            continue;
        if (i > 0 && (t[i - 1].type == XTTokenDot || t[i - 1].type == XTTokenProtocol))
            continue;
        t[i] = [[XTToken alloc] initWithType:XTTokenIdentifier
                                       value:[@"_XtP_" stringByAppendingString:tk.value]
                                    location:tk.location];
        }
    _tokens = t;
    }

/****************************************************************************\
|* A static member's shape between web modules, from its tokens: one letter a
|* parameter (v a number, p a pointer to numbers whose count is the next
|* parameter, n that count), then ':' and the result (v a number, - none).
|* *bad names the first type that is none of these.
\****************************************************************************/
+ (BOOL)isWebNumber:(NSString*)t
    {
    return [@[ @"i8", @"u8", @"i16", @"u16", @"i32", @"u32", @"i64", @"u64", @"float", @"double", @"bool" ] containsObject:t];
    }

+ (NSString*)webKindsOf:(NSArray<NSString*>*)params ret:(NSArray<NSString*>*)ret bad:(NSString**)bad
    {
    NSMutableArray<NSArray<NSString*>*>* ps = [NSMutableArray array];
    NSMutableArray<NSString*>* cur = [NSMutableArray array];
    for (NSString* t in params)
        {
        if ([t isEqualToString:@","])
            {
            [ps addObject:cur];
            cur = [NSMutableArray array];
            continue;
            }
        [cur addObject:t];
        }
    if (cur.count && !(cur.count == 1 && [cur[0] isEqualToString:@"void"]))
        [ps addObject:cur];
    NSMutableString* k = [NSMutableString string];
    for (NSUInteger i = 0; i < ps.count; i++)
        {
        NSArray<NSString*>* p = ps[i];
        NSUInteger stars = 0;
        for (NSUInteger j = 0; j + 1 < p.count; j++)
            if ([p[j] isEqualToString:@"*"])
                stars++;
        NSString* base = p.count > 1 ? p[0] : @"";
        NSString* type = [[p subarrayWithRange:NSMakeRange(0, p.count ? p.count - 1 : 0)] componentsJoinedByString:@""];
        if (k.length && [k hasSuffix:@"p"])
            {
            if (stars == 0 && [XTParser isWebNumber:base] && ![base isEqualToString:@"float"] &&
                ![base isEqualToString:@"double"] && ![base isEqualToString:@"bool"])
                {
                [k appendString:@"n"];
                continue;
                }
            if (bad && !*bad)
                *bad = [type stringByAppendingString:@" (the buffer's count)"];
            [k appendString:@"?"];
            continue;
            }
        if (stars == 0 && [XTParser isWebNumber:base])
            [k appendString:@"v"];
        else if (stars == 1 && [XTParser isWebNumber:base] && i + 1 < ps.count)
            [k appendString:@"p"];
        else
            {
            if (bad && !*bad)
                *bad = type;
            [k appendString:@"?"];
            }
        }
    NSString* r = [ret componentsJoinedByString:@""];
    if ([r isEqualToString:@"void"])
        [k appendString:@":-"];
    else if (ret.count == 1 && [XTParser isWebNumber:r])
        [k appendString:@":v"];
    else
        {
        if (bad && !*bad)
            *bad = r;
        [k appendString:@":?"];
        }
    return k;
    }

- (NSArray<XTASTNode*>*)protocolCompanionsFor:(NSArray<XTASTNode*>*)decls
    {
    NSArray<NSString*>* order = self.blkState[@"pstaticOrder"];
    if (!order.count)
        return @[];
    NSDictionary<NSString*, NSArray<NSDictionary*>*>* members = self.blkState[@"pstatics"];
    NSDictionary<NSString*, NSArray<NSNumber*>*>* versions = self.blkState[@"pversion"];
    NSMutableString* src = [NSMutableString string];
    BOOL webBind = NO;
    for (NSString* P in order)
        {
        NSArray<NSDictionary*>* ms = members[P];
        // The host: a class of this program conforming to P with every member static.
        NSString* provider = nil;
        for (XTASTNode* d in decls)
            {
            if (![d isKindOfClass:[XTClassDeclNode class]])
                continue;
            XTClassDeclNode* c = (XTClassDeclNode*)d;
            if (c.isExternal || ![c.protocolNames containsObject:P])
                continue;
            BOOL all = YES;
            for (NSDictionary* m in ms)
                {
                BOOL found = NO;
                for (XTMethodDeclNode* cm in c.methods)
                    if (cm.isStatic && [cm.methodName isEqualToString:m[@"name"]])
                        found = YES;
                if (!found)
                    all = NO;
                }
            if (all)
                {
                provider = c.className;
                break;
                }
            }
        NSArray<NSNumber*>* v = versions[P] ?: @[ @0, @0 ];
        NSString* C = [@"_XtP_" stringByAppendingString:P];
        // wasm32 (webModules): the provider's members are exports a plugin's
        // imports are wired to, with the shape the loader bridges them by and
        // the scratch memory it copies buffers into; with no provider, each
        // member is an import of namespace P, and bind(t) tells the loader
        // which loaded plugin answers it.
        if (self.webModules && provider)
            {
            NSMutableString* shape = [NSMutableString string];
            for (NSDictionary* m in ms)
                {
                BOOL isVoid = [m[@"ret"] isEqualToString:@"void"];
                [src appendFormat:@"extern %@ %@__%@(%@) { %@%@.%@(%@); }\n", m[@"ret"], C, m[@"name"], m[@"params"],
                                  isVoid ? @"" : @"return ", provider, m[@"name"], m[@"args"]];
                [shape appendFormat:@"%@%@:%@", shape.length ? @";" : @"", m[@"name"], m[@"kinds"]];
                }
            [src appendFormat:@"extern u8* %@__shape(void) { return \"%@\"; }\n", C, shape];
            [src appendFormat:@"extern u8* %@__alloc(u32 n) { return new u8[n]; }\n", C];
            [src appendFormat:@"extern void %@__free(u8* p) { delete p; }\n", C];
            }
        if (self.webModules && !provider)
            {
            if (!webBind)
                {
                [src appendString:@"package xcplugin;\nvoid _xt_proto_bind(u8* ns, u32 n, pointer t);\npackage __none;\n"];
                webBind = YES;
                }
            [src appendFormat:@"package %@;\n", P];
            for (NSDictionary* m in ms)
                [src appendFormat:@"%@ %@__%@(%@);\n", m[@"ret"], C, m[@"name"], m[@"params"]];
            [src appendString:@"package __none;\n"];
            }
        if (!provider && !self.webModules)
            for (NSDictionary* m in ms)
                [src appendFormat:@"typedef %@ %@_%@_t(%@);\n", m[@"ret"], C, m[@"name"], m[@"params"]];
        [src appendFormat:@"class %@\n{\n", C];
        if (provider)
            [src appendString:@"static pointer* _impl;\n"];
        else if (self.webModules)
            [src appendFormat:@"static pointer _table;\nstatic void bind(pointer t) { _table = t; _xt_proto_bind(\"%@\", (u32)%lu, t); }\n"
                              @"static pointer table(void) { return _table; }\n", P, (unsigned long)P.length];
        else
            [src appendString:@"static pointer _table;\nstatic void bind(pointer t) { _table = t; }\n"
                              @"static pointer table(void) { return _table; }\n"];
        NSUInteger k = 0;
        for (NSDictionary* m in ms)
            {
            BOOL isVoid = [m[@"ret"] isEqualToString:@"void"];
            if (!provider && self.webModules)
                [src appendFormat:@"static %@ %@(%@) { %@%@__%@(%@); }\n", m[@"ret"], m[@"name"], m[@"params"],
                                  isVoid ? @"" : @"return ", C, m[@"name"], m[@"args"]];
            else if (provider)
                [src appendFormat:@"static %@ %@(%@) { %@%@.%@(%@); }\n", m[@"ret"], m[@"name"], m[@"params"],
                                  isVoid ? @"" : @"return ", provider, m[@"name"], m[@"args"]];
            else
                [src appendFormat:@"static %@ %@(%@) { %@_%@_t* fn = (%@_%@_t*)((pointer*)_table)[%lu]; %@fn(%@); }\n",
                                  m[@"ret"], m[@"name"], m[@"params"], C, m[@"name"], C, m[@"name"], (unsigned long)k,
                                  isVoid ? @"" : @"return ", m[@"args"]];
            k++;
            }
        if (provider)
            {
            [src appendFormat:@"static pointer table(void)\n{\nif (_impl == (pointer*)0) { _impl = new pointer[%lu];", (unsigned long)ms.count];
            k = 0;
            for (NSDictionary* m in ms)
                [src appendFormat:@" _impl[%lu] = (pointer)&%@.%@;", (unsigned long)k++, provider, m[@"name"]];
            [src appendString:@" }\nreturn (pointer)_impl;\n}\n"];
            }
        [src appendFormat:@"static u32 versionMajor(void) { return (u32)%@; }\nstatic u32 versionMinor(void) { return (u32)%@; }\n}\n",
                          v[0], v[1]];
        }
    XTLexer* lexer = [[XTLexer alloc] initWithSource:src filename:@"<protocol-companions>" diagnostics:_diagnostics];
    NSArray<XTToken*>* toks = [lexer tokenise];
    XTParser* sub = [[XTParser alloc] initWithTokens:toks typeTable:_typeTable diagnostics:_diagnostics];
    sub.defaultPointerPlacement = self.defaultPointerPlacement;
    XTProgramNode* prog = [sub parse];
    return prog ? prog.declarations : @[];
    }

/****************************************************************************\
|* Pre-scan the token stream for class, struct, and enum declarations and
|* register placeholder types in the type table so forward references resolve
|* before the actual declarations are parsed.
\****************************************************************************/
- (void)prescanForwardTypeDeclarations
    {
    NSUInteger n = _tokens.count;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTToken* tok = _tokens[i];
        if (tok.type != XTTokenClass && tok.type != XTTokenStruct &&
            tok.type != XTTokenEnum && tok.type != XTTokenProtocol)
            continue;
        if (i + 1 >= n)
            continue;
        XTToken* nameTok = _tokens[i + 1];
        if (nameTok.type != XTTokenIdentifier)
            continue;

        // Skip if something else with the same name is already known
        // (another pre-existing type, a typedef alias registered by
        // #import, …). The caller's real declaration will overwrite
        // a pre-scan placeholder later, but we don't want to trample
        // a legitimate prior registration.
        XTType* existing = [_typeTable typeForName:nameTok.value];

        if (tok.type == XTTokenProtocol)
            {
            // PR9: protocol name pre-scan. Register a class-kind
            // marker so `Drawable` / `Drawable@` parse as types,
            // and remember the name so parseType can stamp the
            // `protocolConstraint` field on bare uses.
            [_protocolNames addObject:nameTok.value];
            if (existing && existing.kind == XTTypeKindClass)
                continue;
            XTType* marker = [[XTType alloc] initWithKind:XTTypeKindClass
                                              displayName:nameTok.value];
            [_typeTable registerType:marker forName:nameTok.value];
            continue;
            }
        if (tok.type == XTTokenClass)
            {
            // Register the class as the bare class-marker type. Under
            // the stack-allocated-class design (doc/heap.md), `Myclass c;`
            // means "declare `c` as an inline instance of Myclass", so
            // the type table needs to hand back the class type, not a
            // pre-wrapped pointer. Explicit pointer declarations use
            // the `@` suffix and stack pointers normally via parseType.
            if (existing && existing.kind == XTTypeKindClass)
                continue;
            XTType* classMarker = [[XTType alloc] initWithKind:XTTypeKindClass
                                                   displayName:nameTok.value];
            [_typeTable registerType:classMarker forName:nameTok.value];
            }
        else if (tok.type == XTTokenStruct)
            {
            if ([existing isKindOfClass:[XTStructType class]])
                continue;
            [_typeTable registerType:[XTStructType structNamed:nameTok.value
                                                        fields:@[]]
                             forName:nameTok.value];
            }
        else
            {
            if ([existing isKindOfClass:[XTEnumType class]])
                continue;
            [_typeTable registerType:[XTEnumType enumNamed:nameTok.value
                                                   members:@{}]
                             forName:nameTok.value];
            }
        }
    }

/****************************************************************************\
|* Parse a single top-level declaration: typedef, struct, enum, class, or
|* a function/variable declaration.
|* @return  The parsed AST node, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseTopLevelDeclaration
    {
    XTToken* cur = [self currentToken];

    if (cur.type == XTTokenTypedef)
        return [self parseTypedef];
    if (cur.type == XTTokenStruct)
        return [self parseStructDecl:YES];
    if (cur.type == XTTokenEnum)
        return [self parseEnumDecl];
    if (cur.type == XTTokenClass)
        return [self parseClassDecl];
    if (cur.type == XTTokenProtocol)
        return [self parseProtocolDecl];
    // `use Klass;` — `use` is CONTEXTUAL (an identifier everywhere else, so
    // a parameter may be called use): the directive is exactly `use NAME ;`
    // at the top level of a file.
    if (cur.type == XTTokenIdentifier && [cur.value isEqualToString:@"use"]
        && [self peekToken:1].type == XTTokenIdentifier && [self peekToken:2].type == XTTokenSemicolon)
        return [self parseUseDecl];

    // `extern` — external linkage, direction inferred from definition-presence
    // (C's rule; wasm-target.md §6):
    //   no body / no initialiser → IMPORT (defined in another module; a
    //     bodyless function already gets this implicitly — the keyword is
    //     then just the explicit spelling)
    //   with body / initialiser  → EXPORT — this module owns the definition
    //     and publishes it (wasm export section + DFE root; ordinary
    //     external linkage elsewhere)
    if (cur.type == XTTokenExtern)
        {
        [self advance];
        XTASTNode* d = [self parseFunctionOrVarDecl:YES];
        if ([d isKindOfClass:[XTVariableDeclNode class]])
            {
            XTVariableDeclNode* v = (XTVariableDeclNode*)d;
            v.isGlobal = YES;
            if (v.initialiser)
                v.isExported = YES; // exported definition
            else
                v.isExternalGlobal = YES; // import, as before
            }
        else if ([d isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* f = (XTFunctionDeclNode*)d;
            if (f.body)
                f.isExported = YES; // exported definition
            // bodyless: an import — bind it to the `#package` in force.
            else if (_currentPackage)
                f.importPackage = _currentPackage;
            }
        else if (d)
            {
            [_diagnostics emitError:@"`extern` applies to a function or global variable"
                                 at:cur.location];
            }
        return d;
        }

    // `package <name>;` — the host import namespace for subsequent bodyless
    // (imported) declarations, produced by the preprocessor's `#package`
    // directive. `package __none;` (the preprocessor's include-boundary
    // restore) clears it. State-only: no AST node.
    if (cur.type == XTTokenIdentifier && [cur.value isEqualToString:@"package"] && [self peekToken:1].type == XTTokenIdentifier && [self peekToken:2].type == XTTokenSemicolon)
        {
        [self advance];
        NSString* pkg = [self currentToken].value;
        [self advance];
        [self advance]; // ';'
        _currentPackage = [pkg isEqualToString:@"__none"] ? nil : pkg;
        return nil;
        }

    // Try function or variable declaration (both start with a type-list)
    XTASTNode* decl = [self parseFunctionOrVarDecl:YES];
    // A bodyless top-level function is an import; bind it to the package
    // (`#package`) in force at its declaration site.
    if (_currentPackage && [decl isKindOfClass:[XTFunctionDeclNode class]])
        {
        XTFunctionDeclNode* f = (XTFunctionDeclNode*)decl;
        if (!f.body)
            f.importPackage = _currentPackage;
        }
    return decl;
    }

/****************************************************************************\
|* Parse a `use ClassName;` directive. Promotes the named class's
|* static methods into the bare-identifier call lookup space for the
|* rest of the file: after `use Stdio;` the user can write
|* `printf("hi\n")` instead of `Stdio.printf("hi\n")`. The class
|* itself must be declared / imported elsewhere — sema validates
|* the name and reports unknown classes.
\****************************************************************************/
- (nullable XTASTNode*)parseUseDecl
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'use'
    XTToken* nameTok = [self expect:XTTokenIdentifier];
    [self expect:XTTokenSemicolon];
    if (!nameTok)
        return nil;
    return [[XTUseDeclNode alloc] initWithClassName:nameTok.value
                                           location:loc];
    }

#pragma mark - Typedef

/****************************************************************************\
|* Parse a typedef declaration: `typedef struct { ... } alias;` or
|* `typedef type alias;`. Registers the alias name in the type table.
|* @return  An XTTypedefNode, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseTypedef
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'typedef'

    if ([self check:XTTokenStruct])
        {
        XTStructDeclNode* structNode = (XTStructDeclNode*)[self parseStructDecl:NO];
        NSString* alias = nil;
        XTToken* nameTok = [self expect:XTTokenIdentifier];
        if (nameTok)
            alias = nameTok.value;
        [self expect:XTTokenSemicolon];
        if (!alias)
            return nil;

        // Build struct type and register it
        NSMutableArray<XTStructField*>* fields = [NSMutableArray array];
        for (XTVariableDeclNode* f in structNode.fields)
            {
            XTStructField* sf = [[XTStructField alloc] initWithName:f.varName type:f.declaredType ?: [XTType u8Type]];
            [fields addObject:sf];
            }
        XTStructType* st = [XTStructType structNamed:alias fields:fields];
        st.packed = structNode.isPacked;
        [_typeTable registerType:st forName:alias];

        return [[XTTypedefNode alloc] initWithAliasName:alias
                                             targetType:st
                                             structDecl:structNode
                                               location:loc];
        }

    // Accept two forms past this point:
    //   typedef <type> <name>;                      — plain type alias
    //   typedef <retType> <name>(<params>);         — function signature
    // Detection is lookahead: after parseType + identifier, an opening
    // paren means signature. Signature form registers the name as an
    // XTFunctionType, which callers can then wrap with `@` to form a
    // function-pointer type (the xtc idiom — `@` is the pointer op).
    XTType* targetType = [self parseType];
    XTToken* nameTok = [self expect:XTTokenIdentifier];
    if (!nameTok || !targetType)
        return nil;

    if ([self check:XTTokenLParen])
        {
        [self advance]; // consume '('
        NSMutableArray<XTType*>* paramTypes = [NSMutableArray array];
        BOOL isVarArgs = NO;
        // Allow `(void)` as an explicit zero-param marker.
        if ([self check:XTTokenVoid] && [[self peekToken:1] type] == XTTokenRParen)
            {
            [self advance];
            }
        else if (![self check:XTTokenRParen])
            {
            while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
                {
                if ([self match:XTTokenEllipsis])
                    {
                    isVarArgs = YES;
                    break;
                    }
                XTType* pty = [self parseType];
                if (pty)
                    [paramTypes addObject:pty];
                // Param names in a signature typedef are optional —
                // if the next token is an identifier that ISN'T a
                // type name, consume it as a name. C-compat form
                // allows bare types: `typedef u8 cmp(u8, u8);`.
                if ([self check:XTTokenIdentifier] &&
                    ![_typeTable isTypeName:[self currentToken].value])
                    {
                    [self advance];
                    }
                if (![self match:XTTokenComma])
                    break;
                }
            }
        [self expect:XTTokenRParen];
        [self expect:XTTokenSemicolon];
        XTFunctionType* ft =
            [XTFunctionType functionWithReturnTypes:@[ targetType ]
                                         paramTypes:paramTypes
                                          isVarArgs:isVarArgs];
        [_typeTable registerType:ft forName:nameTok.value];
        return [[XTTypedefNode alloc] initWithAliasName:nameTok.value
                                             targetType:ft
                                             structDecl:nil
                                               location:loc];
        }

    [self expect:XTTokenSemicolon];
    [_typeTable registerType:targetType forName:nameTok.value];
    return [[XTTypedefNode alloc] initWithAliasName:nameTok.value
                                         targetType:targetType
                                         structDecl:nil
                                           location:loc];
    }

#pragma mark - Struct

/****************************************************************************\
|* Parse a struct declaration. Accepts both `{ }` and `[ ]` as delimiters.
|* Registers the struct type in the type table (or fills in a forward-ref
|* placeholder if one exists).
|* @param consumeSemicolon  YES to consume a trailing semicolon if present.
|* @return  An XTStructDeclNode, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseStructDecl:(BOOL)consumeSemicolon
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'struct'

    NSString* name = nil;
    if ([self check:XTTokenIdentifier])
        {
        name = [self advance].value;
        }

    // `:packed` — the same annotation position a function signature uses
    // (`: cloaked`). Total size becomes the raw field-width sum, with no
    // tail rounding to natural alignment; offsets are tight either way, so
    // this is the byte-compatibility knob for kernel/wire structs
    // (epoll_event: u32 @0, u64 @4, size 12). Contextual word, not a
    // keyword — `packed` stays usable as an identifier everywhere else.
    BOOL isPacked = NO;
    if ([self check:XTTokenColon] &&
        [self peekToken:1].type == XTTokenIdentifier &&
        [[self peekToken:1].value isEqualToString:@"packed"])
        {
        [self advance]; // ':'
        [self advance]; // 'packed'
        isPacked = YES;
        }

    // `struct Foo;` — a forward (incomplete-type) declaration with NO body. C
    // emits it so a struct can hold a POINTER to a type defined further down or
    // in another unit (`struct valstr; struct castr { valstr* v; }`), and c2xc's
    // converted output relies on it. Register an incomplete placeholder (so a
    // pointer to it resolves; a later definition fills the fields via the
    // replaceFields path below) and return an empty struct node — which is what
    // the self-hosted parser already produces for this shape (its `openBlock()`
    // is conditional, where this one used to `expectBlockOpen` and hard-error).
    if (name && [self check:XTTokenSemicolon])
        {
        if (consumeSemicolon)
            [self advance]; // ';'
        if (![_typeTable typeForName:name])
            {
            XTStructType* st = [XTStructType structNamed:name fields:@[]];
            st.packed = isPacked;
            [_typeTable registerType:st forName:name];
            }
        return [[XTStructDeclNode alloc] initWithName:name fields:@[] location:loc];
        }

    // `{ }` only. `[ ]` was accepted here for the same reason `(( ))` was
    // accepted as a block — an Atari 8-bit keyboard has no brace keys — and it
    // went when `(( ))` did, so a struct body, an enum body and an initialiser
    // now all read the way C reads them.
    [self expectBlockOpen];
    NSMutableArray<XTVariableDeclNode*>* fields = [NSMutableArray array];

    while (![self checkBlockClose] && ![self check:XTTokenEOF])
        {
        XTASTNode* decl = [self parseVarDeclStatement];
        if ([decl isKindOfClass:[XTVariableDeclNode class]])
            {
            [fields addObject:(XTVariableDeclNode*)decl];
            }
        else if ([decl isKindOfClass:[XTBlockNode class]] &&
                 ((XTBlockNode*)decl).isDeclList)
            {
            // Same unwrap as parseClassDecl: a `u8 x,y,z;` line
            // comes back as a decl-list block whose statements are
            // one XTVariableDeclNode per declarator.
            for (XTASTNode* inner in ((XTBlockNode*)decl).statements)
                {
                if ([inner isKindOfClass:[XTVariableDeclNode class]])
                    {
                    [fields addObject:(XTVariableDeclNode*)inner];
                    }
                }
            }
        }

    [self expectBlockClose];
    if (consumeSemicolon)
        [self match:XTTokenSemicolon];

    XTStructDeclNode* node = [[XTStructDeclNode alloc] initWithName:name
                                                             fields:fields
                                                           location:loc];
    node.isPacked = isPacked;
    if (name)
        {
        NSMutableArray<XTStructField*>* sfields = [NSMutableArray array];
        for (XTVariableDeclNode* f in fields)
            {
            XTStructField* sf = [[XTStructField alloc] initWithName:f.varName type:f.declaredType ?: [XTType u8Type]];
            [sfields addObject:sf];
            }
        // If a pre-scan placeholder already lives in the type table,
        // mutate it so any variable declaration that captured the
        // placeholder earlier (forward reference) picks up the real
        // fields. Otherwise register a fresh struct type.
        XTType* existing = [_typeTable typeForName:name];
        if ([existing isKindOfClass:[XTStructType class]])
            {
            [(XTStructType*)existing replaceFields:sfields];
            ((XTStructType*)existing).packed = isPacked;
            }
        else
            {
            XTStructType* st = [XTStructType structNamed:name fields:sfields];
            st.packed = isPacked;
            [_typeTable registerType:st forName:name];
            }
        }
    return node;
    }

#pragma mark - Enum

/****************************************************************************\
|* Parse an enum declaration: `enum Name = [ member, ... ]` or with braces.
|* Supports explicit member values via `member = value`. Registers the enum
|* type in the type table.
|* @return  An XTEnumDeclNode, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseEnumDecl
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'enum'

    XTToken* nameTok = [self expect:XTTokenIdentifier];
    [self expect:XTTokenAssign];

    // `{ }` only — see parseStructDecl for why `[ ]` went.
    [self expect:XTTokenLBrace];
    XTTokenType closeToken = XTTokenRBrace;

    NSMutableArray<XTEnumMemberNode*>* members = [NSMutableArray array];
    int64_t nextValue = 0;

    while (![self check:closeToken] && ![self check:XTTokenEOF])
        {
        XTToken* memberName = [self expect:XTTokenIdentifier];
        // skip bad tokens to avoid infinite loop
        if (!memberName)
            {
            [self advance];
            continue;
            }
        NSNumber* explicitValue = nil;
        if ([self match:XTTokenAssign])
            {
            XTASTNode* valExpr = [self parseExpression];
            if ([valExpr isKindOfClass:[XTLiteralIntNode class]])
                {
                nextValue = ((XTLiteralIntNode*)valExpr).intValue;
                }
            explicitValue = @(nextValue);
            }
        if (memberName)
            {
            XTEnumMemberNode* m = [[XTEnumMemberNode alloc] initWithName:memberName.value
                                                           explicitValue:explicitValue ?: @(nextValue)
                                                                location:memberName.location];
            m.resolvedValue = nextValue;
            [members addObject:m];
            }
        nextValue++;
        [self match:XTTokenComma];
        }

    [self expect:XTTokenRBrace];
    [self match:XTTokenSemicolon];

    NSString* enumName = nameTok ? nameTok.value : @"<anonymous>";
    XTEnumDeclNode* node = [[XTEnumDeclNode alloc] initWithName:enumName
                                                        members:members
                                                       location:loc];

    // Register enum type. A pre-scan placeholder from the forward-
    // reference pass gets its members filled in via replaceMembers:
    // so AST nodes that captured the empty placeholder see the real
    // member map.
    NSMutableDictionary<NSString*, NSNumber*>* memberMap = [NSMutableDictionary dictionary];
    for (XTEnumMemberNode* m in members)
        {
        memberMap[m.memberName] = @(m.resolvedValue);
        }
    XTType* existingEnum = [_typeTable typeForName:enumName];
    if ([existingEnum isKindOfClass:[XTEnumType class]])
        {
        [(XTEnumType*)existingEnum replaceMembers:memberMap];
        }
    else
        {
        XTEnumType* et = [XTEnumType enumNamed:enumName members:memberMap];
        [_typeTable registerType:et forName:enumName];
        }

    return node;
    }

#pragma mark - Class

/****************************************************************************\
|* Parse a class declaration: `class Name { ivars... methods... }`. Registers
|* the class name as a bare marker type. Multi-declarator ivar lines (e.g.
|* `u8 r,g,b;`) are unwrapped into individual ivar nodes.
|* @return  An XTClassDeclNode, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseClassDecl
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'class'

    XTToken* nameTok = [self expect:XTTokenIdentifier];
    // Register the class name as the bare class-marker type. A bare
    // `Myclass` in a declaration means an inline instance; explicit
    // pointer form is `Myclass@`, stacked normally by parseType via
    // the `ptr-suffix*` loop. The pre-scan in parseProgram may already
    // have registered this class; if so, skip (its entry is the same
    // bare marker).
    if (nameTok)
        {
        XTType* existing = [_typeTable typeForName:nameTok.value];
        if (!(existing && existing.kind == XTTypeKindClass))
            {
            XTType* classMarker = [[XTType alloc] initWithKind:XTTypeKindClass
                                                   displayName:nameTok.value];
            [_typeTable registerType:classMarker forName:nameTok.value];
            }
        }

    // Optional parent clause and optional protocol clause:
    //   class X                                — Object parent, no protos
    //   class X : Parent                       — explicit parent
    //   class X <P1, P2>                       — protocols only
    //   class X : Parent <P1, P2>              — both
    // The parent comes straight after `:` (single identifier, no
    // commas). The protocol list is a separate `<...>` block of
    // comma-separated identifiers. Sema verifies each protocol
    // exists and that the class provides every declared method.
    // `class Shape (Drawing)` / `class Shape ()` — a category or an extension.
    // `(` after a class name is unambiguous in this grammar (the name is
    // otherwise followed by `:`, `<` or the body), so this needs no new keyword
    // and leaves XTTokenType.h — whose numbering is a contract with the
    // self-hosted lexer — untouched.
    NSString* categoryName = nil;
    if ([self match:XTTokenLParen])
        {
        if ([self check:XTTokenIdentifier])
            {
            categoryName = [self currentToken].value;
            [self advance];
            }
        else
            {
            categoryName = @""; // `()` = extension
            }
        [self expect:XTTokenRParen];
        }

    NSString* parentName = nil;
    NSMutableArray<NSString*>* protocolNames = [NSMutableArray array];
    if ([self match:XTTokenColon])
        {
        XTToken* parentTok = [self expect:XTTokenIdentifier];
        if (parentTok)
            parentName = parentTok.value;
        }
    if ([self match:XTTokenLess])
        {
        XTToken* first = [self expect:XTTokenIdentifier];
        if (first)
            [protocolNames addObject:first.value];
        while ([self match:XTTokenComma])
            {
            XTToken* protoTok = [self expect:XTTokenIdentifier];
            if (protoTok)
                [protocolNames addObject:protoTok.value];
            }
        [self expect:XTTokenGreater];
        }

    [self expectBlockOpen];

    // Blocks (task #26): a CLASS-level scope so block-typed ivars are
    // visible to the call-rewrite inside method bodies (declare-before-use,
    // lexically — a block ivar declared after the method that calls it
    // needs the explicit `.invoke(…)` spelling). Ivar names are also
    // remembered for the v1 capture restriction's error message.
    [self blkPushScope];
    NSString* blkSavedClass = [self blkState][@"curClass"];
    [self blkEnterClass:nameTok.value parent:parentName];
    [self blkScanMethodNames];

    NSMutableArray<XTVariableDeclNode*>* ivars = [NSMutableArray array];
    NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];

    while (![self checkBlockClose] && ![self check:XTTokenEOF])
        {
        // Modifiers, in either order: `static` / `final` / `since("V")`.
        // `since` is CONTEXTUAL — an identifier here, a plain name anywhere
        // else — so `u32 since;` stays a legal ivar.
        BOOL isStaticMethod = NO, isFinalMethod = NO;
        NSString* sinceVersion = nil;
        while (YES)
            {
            if ([self match:XTTokenStatic])
                isStaticMethod = YES;
            else if ([self match:XTTokenFinal])
                isFinalMethod = YES;
            else if ([self check:XTTokenIdentifier] && [[self currentToken].value isEqualToString:@"since"] && [self peekToken:1].type == XTTokenLParen)
                {
                [self advance]; // since
                [self advance]; // (
                if ([self check:XTTokenStringLiteral])
                    {
                    sinceVersion = [self currentToken].value;
                    [self advance];
                    }
                else
                    {
                    [_diagnostics emitError:@"since(...) takes a version string, "
                                            @"e.g. since(\"0.4\")"
                                         at:[self currentLocation]];
                    }
                [self expect:XTTokenRParen];
                }
            else
                break;
            }

        // Peek: if the next tokens form a type followed by identifier followed by '(', it's a method
        if ([self looksLikeFunctionDecl])
            {
            XTASTNode* decl = [self parseFunctionOrVarDecl:NO];
            if ([decl isKindOfClass:[XTFunctionDeclNode class]])
                {
                XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
                XTMethodDeclNode* method = [[XTMethodDeclNode alloc] initWithName:fn.funcName
                                                                      returnTypes:fn.returnTypes
                                                                       parameters:fn.parameters
                                                                         isStatic:isStaticMethod
                                                                        isVarArgs:fn.isVarArgs
                                                                             body:fn.body
                                                                         location:fn.location];
                method.needsOS = fn.needsOS;
                method.throwsError = fn.throwsError;
                method.isAction = fn.isAction;
                method.isFinal = isFinalMethod;
                method.sinceVersion = sinceVersion;
                method.placement = fn.placement;
                method.cloakedRegionId = fn.cloakedRegionId;
                [methods addObject:method];
                }
            }
        else
            {
            XTASTNode* decl = [self parseVarDeclStatement];
            // `static u16 count;` in a class body. The modifier loop above
            // already consumed the `static`, so parseVarDeclStatement never
            // sees it — the flag has to be re-applied here or the keyword is
            // silently dropped and the ivar becomes ordinary per-instance
            // storage, which is what it used to do. See lowerStaticIvars.
            if ([decl isKindOfClass:[XTVariableDeclNode class]])
                {
                ((XTVariableDeclNode*)decl).isStatic = isStaticMethod;
                [ivars addObject:(XTVariableDeclNode*)decl];
                [self blkAddIvarName:((XTVariableDeclNode*)decl).varName];
                [self blkMarkIvar:((XTVariableDeclNode*)decl).varName]; // parSelfIvar
                }
            else if ([decl isKindOfClass:[XTBlockNode class]] &&
                     ((XTBlockNode*)decl).isDeclList)
                {
                // `u8 r,g,b;` returns a synthetic decl-list block
                // wrapping one XTVariableDeclNode per declarator.
                // Without unwrapping it here every declarator after
                // the first was dropped on the floor and the class
                // descriptor emitted only the leading ivar.
                for (XTASTNode* inner in ((XTBlockNode*)decl).statements)
                    {
                    if ([inner isKindOfClass:[XTVariableDeclNode class]])
                        {
                        ((XTVariableDeclNode*)inner).isStatic = isStaticMethod;
                        [ivars addObject:(XTVariableDeclNode*)inner];
                        [self blkAddIvarName:((XTVariableDeclNode*)inner).varName];
                        [self blkMarkIvar:((XTVariableDeclNode*)inner).varName]; // parSelfIvar
                        }
                    }
                }
            }
        }

    [self blkPopScope]; // task #26
    [self blkLeaveClass:blkSavedClass];
    [self expectBlockClose];

    NSString* className = nameTok ? nameTok.value : @"<anonymous>";
    XTClassDeclNode* cls = [[XTClassDeclNode alloc] initWithName:className
                                                      parentName:parentName
                                                   protocolNames:protocolNames
                                                           ivars:ivars
                                                         methods:methods
                                                        location:loc];
    cls.categoryName = categoryName;
    return cls;
    }

/****************************************************************************\
|* Parse a protocol declaration (PR9). Syntax:
|*   protocol Name {
|*       <return-type> methodName(<params>);
|*       ...
|*   }
|* Method signatures only — bodies are rejected. The members are
|* reused XTMethodDeclNode instances with body == nil, so sema's
|* existing signature helpers work unchanged.
\****************************************************************************/
- (nullable XTASTNode*)parseProtocolDecl
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'protocol'
    XTToken* nameTok = [self expect:XTTokenIdentifier];
    // Register a type marker so `Name` / `Name@` parses as a type
    // before sema has processed the program, and remember the name
    // in `_protocolNames` so parseType can stamp the constraint.
    // We reuse the class-marker kind since protocols plug into the
    // same pointer / dispatch machinery at the type level; sema
    // keys off the decl node to distinguish them.
    if (nameTok)
        {
        [_protocolNames addObject:nameTok.value];
        XTType* existing = [_typeTable typeForName:nameTok.value];
        if (!(existing && existing.kind == XTTypeKindClass))
            {
            XTType* marker = [[XTType alloc] initWithKind:XTTypeKindClass
                                              displayName:nameTok.value];
            [_typeTable registerType:marker forName:nameTok.value];
            }
        }
    // `:version(major.minor)` (bundles-and-plugins.md §3).
    if ([self check:XTTokenColon] && [[self peekToken:1].value isEqualToString:@"version"] && nameTok)
        {
        [self advance];
        [self advance];
        [self expect:XTTokenLParen];
        XTToken* vt = [self advance];
        NSArray<NSString*>* parts = [vt.value componentsSeparatedByString:@"."];
        NSMutableDictionary* pv = self.blkState[@"pversion"];
        if (!pv)
            self.blkState[@"pversion"] = pv = [NSMutableDictionary dictionary];
        pv[nameTok.value] = @[ @([parts[0] integerValue]), @(parts.count > 1 ? [parts[1] integerValue] : 0) ];
        [self expect:XTTokenRParen];
        }
    [self expectBlockOpen];
    NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];
    while (![self checkBlockClose] && ![self check:XTTokenEOF])
        {
        // `optional bool windowShouldClose(...)` — a method a conforming
        // class may omit, leaving its vtable slot 0.
        BOOL isOptional = [self match:XTTokenOptional];
        // `static R f(params);` — a member of the protocol's companion class
        // (rewriteProtocolStaticReceivers), not of the conforming objects:
        // kept as text for its synthesis.
        if (!isOptional && [self check:XTTokenStatic] && nameTok)
            {
            [self advance];
            NSUInteger from = _pos;
            XTASTNode* sd = [self parseFunctionOrVarDecl:NO];
            NSUInteger to = _pos;
            if (![sd isKindOfClass:[XTFunctionDeclNode class]] || ((XTFunctionDeclNode*)sd).body)
                {
                [_diagnostics emitError:@"a protocol's static member is a function signature, with no body"
                                     at:sd ? sd.location : [self currentLocation]];
                continue;
                }
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)sd;
            // Its text: the tokens before the name (the return type), and
            // between the parentheses (the parameters).
            NSMutableArray<NSString*>* ret = [NSMutableArray array];
            NSMutableArray<NSString*>* params = [NSMutableArray array];
            NSUInteger q = from;
            while (q < to && !(_tokens[q].type == XTTokenIdentifier && [_tokens[q].value isEqualToString:fn.funcName] &&
                               q + 1 < to && _tokens[q + 1].type == XTTokenLParen))
                [ret addObject:_tokens[q++].value];
            NSInteger pdepth = 0;
            for (q = q + 1; q < to; q++)
                {
                if (_tokens[q].type == XTTokenLParen && pdepth++ == 0)
                    continue;
                if (_tokens[q].type == XTTokenRParen && --pdepth == 0)
                    break;
                [params addObject:_tokens[q].value];
                }
            NSMutableArray<NSString*>* args = [NSMutableArray array];
            for (XTParamNode* pn in fn.parameters)
                [args addObject:pn.paramName];
            NSString* paramText = [params componentsJoinedByString:@" "];
            if ([paramText isEqualToString:@"void"])
                paramText = @"void";
            NSString* bad = nil;
            NSString* kinds = [XTParser webKindsOf:params ret:ret bad:&bad];
            if (self.webModules && bad)
                [_diagnostics emitError:[NSString stringWithFormat:@"%@.%@: a protocol's static member called between "
                                                                   @"web modules passes numbers, or a pointer to numbers "
                                                                   @"followed by their count; '%@' is neither",
                                                                   nameTok.value, fn.funcName, bad]
                                     at:fn.location];
            NSMutableDictionary* all = self.blkState[@"pstatics"];
            if (!all)
                self.blkState[@"pstatics"] = all = [NSMutableDictionary dictionary];
            NSMutableArray* order = self.blkState[@"pstaticOrder"];
            if (!order)
                self.blkState[@"pstaticOrder"] = order = [NSMutableArray array];
            if (!all[nameTok.value])
                {
                all[nameTok.value] = [NSMutableArray array];
                [order addObject:nameTok.value];
                }
            [all[nameTok.value] addObject:@{ @"ret" : [ret componentsJoinedByString:@" "],
                                             @"name" : fn.funcName,
                                             @"params" : paramText,
                                             @"kinds" : kinds,
                                             @"args" : [args componentsJoinedByString:@", "] }];
            continue;
            }
        if (![self looksLikeFunctionDecl])
            {
            [_diagnostics emitError:
                              @"protocol body accepts method signatures only (no ivars, no bodies)"
                                 at:[self currentLocation]];
            [self advance];
            continue;
            }
        XTASTNode* decl = [self parseFunctionOrVarDecl:NO];
        if ([decl isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)decl;
            if (fn.body != nil)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"protocol method '%@' must be a signature only — no body",
                                                      fn.funcName]
                                     at:fn.location];
                }
            XTMethodDeclNode* m = [[XTMethodDeclNode alloc]
                initWithName:fn.funcName
                 returnTypes:fn.returnTypes
                  parameters:fn.parameters
                    isStatic:NO
                   isVarArgs:fn.isVarArgs
                        body:nil
                    location:fn.location];
            m.isOptional = isOptional;
            [methods addObject:m];
            }
        }
    [self expectBlockClose];
    NSString* protoName = nameTok ? nameTok.value : @"<anonymous>";
    return [[XTProtocolDeclNode alloc] initWithName:protoName
                                            methods:methods
                                           location:loc];
    }

#pragma mark - Function or Variable Declaration

/****************************************************************************\
|* Lookahead test: does the current position look like a function declaration
|* (a type list followed by IDENT followed by '(')?  Does not consume tokens.
|* @return  YES if the pattern matches a function declaration.
\****************************************************************************/
- (BOOL)looksLikeFunctionDecl
    {
    // Scan forward: type-list IDENT ( -> function
    NSUInteger savedPos = _pos;
    [self parseTypeListLookahead];
    // Treat the refop keywords (`release`, `retain`, `delete`) as
    // valid names in declarator position so users can override the
    // auto-generated ARC `release` method.
    XTTokenType curTy = [self currentToken].type;
    BOOL nameLike = (curTy == XTTokenIdentifier ||
                     curTy == XTTokenRelease ||
                     curTy == XTTokenRetain ||
                     curTy == XTTokenDelete);
    XTTokenType nextTy = [[self peekToken:1] type];
    BOOL result = (nameLike && nextTy == XTTokenLParen);
    _pos = savedPos;
    return result;
    }

/****************************************************************************\
|* Consume a comma-separated list of types without building AST nodes.
|* Used during lookahead to skip past the return-type list in ambiguous
|* function vs. variable declarations.
\****************************************************************************/
- (void)parseTypeListLookahead
    {
    // Consume types separated by commas (without building nodes).
    // Mirrors parseType's prefix handling: optional placement /
    // weak qualifiers (`main:` / `shadow:` / `banked:` / `weak:`)
    // before each type. Without this, `banked:T@` as a return type
    // (or first-decl type generally) failed the lookahead — `banked`
    // isn't a type keyword, so the loop bailed before the actual
    // type name and `looksLikeFunctionDecl` reported "not a function
    // declaration", which then short-circuited to a variable-decl
    // parse and errored on the body.
    while (YES)
        {
        // Prefix qualifiers (colon-optional, any count): `weak outlet T@`,
        // `weak:banked:T@`, … — one shared scan/consume.
        if ([self currentBeginsQualifierPrefix])
            {
            while ([self currentToken].type == XTTokenIdentifier &&
                   [self isQualifierKeyword:[self currentToken].value])
                {
                [self advance]; // qualifier
                if ([self currentToken].type == XTTokenColon)
                    [self advance]; // optional ':'
                }
            }
        // An undeclared name followed by a pointer sigil is an opaque handle,
        // as parseType takes it, so `Missing* find(u32 d)` is a method here
        // as it is in the self-hosted parser. Judged "not a function" it was
        // read as fields and every token after it reported as an error.
        BOOL opaquePtr = [self currentToken].type == XTTokenIdentifier &&
                         ![_typeTable isTypeName:[self currentToken].value] &&
                         XTIsPointerSigil([self peekToken:1].type);
        if (!([self currentToken].isTypeKeyword ||
              [_typeTable isTypeName:[self currentToken].value]) && !opaquePtr)
            {
            break;
            }
        [self advance];
        // `C<T>` / `Map<K, V>` — skip a type-argument list, or
        // `Array<String>* give(void)` stops this scan at the `<` and the
        // method is judged "not a function declaration". `<` after a type
        // NAME is unambiguous (the same rule parseType itself relies on),
        // and a nested list may close with `>>`, which lexes as one shift
        // token and closes two levels at once. A list that never closes is
        // not a type-argument list — put the scan back on the `<` so the
        // decision comes out the way it always did.
        if ([self check:XTTokenLess])
            {
            NSUInteger anglePos = _pos;
            NSInteger depth = 0;
            BOOL closed = NO;
            while (![self check:XTTokenEOF])
                {
                XTTokenType t = [self currentToken].type;
                if (t == XTTokenSemicolon || t == XTTokenLBrace ||
                    t == XTTokenLParen)
                    break;
                if (t == XTTokenLess)
                    depth += 1;
                else if (t == XTTokenGreater)
                    depth -= 1;
                else if (t == XTTokenShiftRight)
                    depth -= 2;
                [self advance];
                if (depth <= 0)
                    {
                    closed = (depth == 0);
                    break;
                    }
                }
            if (!closed)
                _pos = anglePos;
            }
        // consume pointer suffixes
        while (XTIsPointerSigil([self currentToken].type))
            [self advance];
        // consume array suffix
        if ([self check:XTTokenLBracket])
            {
            [self advance];
            while (![self check:XTTokenRBracket] && ![self check:XTTokenEOF])
                [self advance];
            [self advance];
            }
        if (![self match:XTTokenComma])
            break;
        }
    }

/****************************************************************************\
|* Parse either a function declaration or a variable declaration (both start
|* with a type list). Disambiguates by looking for '(' after the identifier.
|* Handles multiple comma-separated declarators in the variable case.
|* @param topLevel  YES if this is a top-level (global) declaration.
|* @return  A function decl, variable decl, or synthetic block of variable decls.
\****************************************************************************/
- (nullable XTASTNode*)parseFunctionOrVarDecl:(BOOL)topLevel
    {
    XTSourceLocation* loc = [self currentLocation];

    // Leading storage-class qualifiers at FILE SCOPE, in any order and any
    // number. parseVarDeclStatement has always consumed these for a statement;
    // the top-level path did not, so `static void f(void) {}` — which UXKit is
    // full of, and which the shipped compiler accepts — failed with "Expected
    // type in declaration". `extern` is handled by parseTopLevelDeclaration
    // before this is reached, so it is not repeated here.
    BOOL isVolatile = NO, isRegister = NO, isStatic = NO, isGlobal = NO;
    while ([self check:XTTokenVolatile] || [self check:XTTokenRegister] ||
           [self check:XTTokenStatic] || [self check:XTTokenGlobal] ||
           [self check:XTTokenInline])
        {
        if ([self match:XTTokenVolatile])
            isVolatile = YES;
        if ([self match:XTTokenRegister])
            isRegister = YES;
        if ([self match:XTTokenStatic])
            isStatic = YES;
        if ([self match:XTTokenGlobal])
            isGlobal = YES;
        if ([self match:XTTokenInline])
            { /* accepted and consumed; no codegen effect */ }
        }

    NSArray<XTType*>* types = [self parseTypeList];
    if (types.count == 0)
        {
        // Skip until semicolon or block to recover
        [_diagnostics emitError:@"Expected type in declaration" at:loc];
        while (![self check:XTTokenSemicolon] && ![self check:XTTokenEOF])
            [self advance];
        [self match:XTTokenSemicolon];
        return nil;
        }

    // Accept refop keywords (`release`, `retain`, `delete`) as
    // declarator names in addition to plain identifiers. Lets users
    // override the auto-generated ARC `release(void)` method
    // explicitly. Variable declarations still require a true
    // identifier — only function/method names get the relaxed
    // treatment.
    XTToken* nameTok = nil;
    // A `callback` / `block` header carries the declared NAME inside itself —
    // `callback gTap void(i32 n);` — so by here the name is already consumed
    // and stashed. Take it, exactly as the parameter path does.
    //
    // Without this, a file-scope callback failed with "Expected 'identifier'
    // but found ';'": the header had eaten the name and this path then
    // demanded another one. It worked as a local, an ivar and a parameter,
    // because each of those reads the stash; the top level was the one place
    // that did not.
    //
    // Only when there is no name of its own to take. A FUNCTION whose return
    // type is a block carries a name inside the header too —
    // `block cb u32(u32 n) makeAdder(u32 base)` — and there the stash holds
    // the BLOCK's name, `cb`, while `makeAdder` is the declaration's. Taking
    // the stash unconditionally stole it and broke every block-returning
    // function in the tree.
    if (self.lastBlockDeclName.length && [self currentToken].type != XTTokenIdentifier)
        {
        nameTok = [[XTToken alloc] initWithType:XTTokenIdentifier
                                          value:self.lastBlockDeclName
                                       location:loc];
        self.lastBlockDeclName = nil;
        }
    XTTokenType curTy = [self currentToken].type;
    if (nameTok)
        {
        // already have it
        }
    else if (curTy == XTTokenIdentifier ||
             ((curTy == XTTokenRelease || curTy == XTTokenRetain ||
               curTy == XTTokenDelete) &&
              [self peekToken:1].type == XTTokenLParen))
        {
        nameTok = [self currentToken];
        [self advance];
        }
    else
        {
        nameTok = [self expect:XTTokenIdentifier];
        if (!nameTok)
            return nil;
        }

    if ([self check:XTTokenLParen])
        {
        // Function declaration
        return [self parseFunctionDeclWithReturnTypes:types name:nameTok.value location:loc];
        }

    // Variable declaration: first type is the type, name is already consumed
    XTType* varType = types.firstObject;

    // C-style array suffix after the variable name: `u8 vals[]` or
    // `u8 buf[400]`. The local-declaration parser has had this since
    // forever; globals were the odd one out.
    if ([self match:XTTokenLBracket])
        {
        NSUInteger count = 0;
        if (![self check:XTTokenRBracket])
            {
            XTASTNode* sizeExpr = [self parseExpression];
            count = [self resolveArraySizeExpr:sizeExpr];
            }
        [self expect:XTTokenRBracket];
        varType = [XTArrayType arrayOfType:varType count:count];
        }

    // Handle multiple declarations: u8 x, y = 5;
    NSMutableArray<XTASTNode*>* decls = [NSMutableArray array];
    NSString* firstName = nameTok.value;

    // First var
    XTASTNode* firstInit = nil;
    if ([self match:XTTokenAssign])
        {
        firstInit = [self stringInitForArrayType:varType initialiser:[self parseInitialiser]];
        }
    XTVariableDeclNode* firstDecl = [[XTVariableDeclNode alloc] initWithName:firstName
                                                                        type:varType
                                                                 initialiser:firstInit
                                                                    location:loc];
    firstDecl.isGlobal = topLevel || isGlobal;
    firstDecl.isStatic = isStatic;
    firstDecl.isVolatile = isVolatile;
    firstDecl.isRegister = isRegister;
    [decls addObject:firstDecl];
    [self blkBind:firstDecl.varName type:firstDecl.declaredType]; // task #26
    if (!firstDecl.declaredType || firstDecl.declaredType.kind == XTTypeKindAuto)
        [self blkBindAuto:firstDecl.varName fromInit:firstInit]; // task #26

    while ([self match:XTTokenComma])
        {
        XTToken* nextName = [self expect:XTTokenIdentifier];
        if (!nextName)
            break;
        XTASTNode* nextInit = nil;
        if ([self match:XTTokenAssign])
            {
            nextInit = [self stringInitForArrayType:varType initialiser:[self parseInitialiser]];
            }
        XTVariableDeclNode* nextDecl = [[XTVariableDeclNode alloc] initWithName:nextName.value
                                                                           type:varType
                                                                    initialiser:nextInit
                                                                       location:nextName.location];
        nextDecl.isGlobal = topLevel || isGlobal;
        nextDecl.isStatic = isStatic;
        nextDecl.isVolatile = isVolatile;
        nextDecl.isRegister = isRegister;
        [decls addObject:nextDecl];
        [self blkBind:nextDecl.varName type:nextDecl.declaredType]; // task #26
        }

    [self expect:XTTokenSemicolon];

    if (decls.count == 1)
        return decls.firstObject;

    // Wrap multiple decls in a block-like node (program node handles them at top level)
    // Return a synthetic "multi-decl block" - we use XTBlockNode here
    return [[XTBlockNode alloc] initWithStatements:decls location:loc];
    }

/****************************************************************************\
|* Parse a function declaration body: parameter list, optional annotations
|* (xtcStack, hwStack, naked, needsOS), and the function body block.
|* @param returnTypes  The already-parsed return type list.
|* @param name         The function name.
|* @param loc          Source location of the declaration.
|* @return  An XTFunctionDeclNode, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseFunctionDeclWithReturnTypes:(NSArray<XTType*>*)returnTypes
                                                   name:(NSString*)name
                                               location:(XTSourceLocation*)loc
    {
    // Normalise a `weak:` class-pointer RETURN type to strong (bug 155,
    // Leak B). A value RETURNED is a strong (+1) value — a `new T`, or a
    // returnsRetained call — regardless of how the return type is spelled.
    // Declaring the return `weak:T@` made the caller treat the result as
    // borrowed and skip the balancing release, so every `weak:T@ f(void)`
    // leaked its +1 unconditionally. `weak:` is a property of a STORAGE SLOT
    // (a field/local that auto-zeroes), not of a transient return value, so we
    // strip it here: the return type becomes the strong interned pointer, and
    // caller and callee then agree on ownership. The interned weak type is
    // never mutated — we swap in its strong sibling.
    if (returnTypes.count)
        {
        NSMutableArray<XTType*>* norm = nil;
        for (NSUInteger i = 0; i < returnTypes.count; i++)
            {
            XTType* rt = returnTypes[i];
            if ([rt isKindOfClass:[XTPointerType class]])
                {
                XTPointerType* pt = (XTPointerType*)rt;
                if (pt.isWeak && pt.pointeeType && pt.pointeeType.kind == XTTypeKindClass)
                    {
                    if (!norm)
                        norm = [returnTypes mutableCopy];
                    norm[i] = [XTPointerType pointerToType:pt.pointeeType
                                                 placement:pt.placement
                                                    isWeak:NO];
                    }
                }
            }
        if (norm)
            returnTypes = norm;
        }
    // Blocks (task #26): a name spelled inside a block RETURN type
    // (`block cb u32(…) getCb(…)`) is documentation only — clear the
    // side channel so the parameter loop does not adopt it. The return
    // type itself is remembered so `auto b = makeAdder(…);` can inherit
    // a block binding from the callee.
    self.lastBlockDeclName = nil;
    if (returnTypes.count)
        {
        if (!self.blkState[@"fnRet"])
            self.blkState[@"fnRet"] = [NSMutableDictionary dictionary];
        self.blkState[@"fnRet"][name] = returnTypes.firstObject;
        }
    [self advance]; // consume '('

    NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
    BOOL isVarArgs = NO;

    if ([self check:XTTokenVoid] && [[self peekToken:1] type] == XTTokenRParen)
        {
        [self advance]; // consume 'void'
        }
    else if (![self check:XTTokenRParen])
        {
        while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
            {
            if ([self match:XTTokenEllipsis])
                {
                isVarArgs = YES;
                break;
                }
            XTType* paramType = [self parseType];
            XTToken* paramName = nil;
            // task #26
            if (self.lastBlockDeclName.length)
                {
                paramName = [[XTToken alloc] initWithType:XTTokenIdentifier
                                                    value:self.lastBlockDeclName
                                                 location:loc];
                self.lastBlockDeclName = nil;
                }
            else
                {
                paramName = [self expect:XTTokenIdentifier];
                }
            if (paramType && paramName)
                {
                XTParamNode* p = [[XTParamNode alloc] initWithType:paramType
                                                              name:paramName.value
                                                          location:paramName.location];
                [params addObject:p];
                }
            if (![self match:XTTokenComma])
                break;
            }
        }

    [self expect:XTTokenRParen];

    // Parse optional annotations: ": annotation1, annotation2, ..."
    // Supported: xtcStack, hwStack, naked, needsOS (case-insensitive)
    XTStackConvention stackConv = XTStackDefault;
    BOOL isNaked = NO;
    BOOL needsOS = NO;
    BOOL isIrq = NO;
    BOOL isVbi = NO;
    BOOL isAction = NO;
    XTPlacement placement = XTPlacementDefault;
    NSString* cloakedRegionId = nil;
    if ([self match:XTTokenColon])
        {
        while ([self check:XTTokenIdentifier])
            {
            XTToken* tok = [self advance];
            NSString* annotName = tok.value.lowercaseString;
            if ([annotName isEqualToString:@"xtcstack"])
                {
                stackConv = XTStackXtc;
                }
            else if ([annotName isEqualToString:@"hwstack"])
                {
                stackConv = XTStack6502;
                }
            else if ([annotName isEqualToString:@"naked"])
                {
                isNaked = YES;
                }
            else if ([annotName isEqualToString:@"needsos"])
                {
                needsOS = YES;
                }
            else if ([annotName isEqualToString:@"irq"])
                {
                isIrq = YES;
                }
            else if ([annotName isEqualToString:@"vbi"])
                {
                isVbi = YES;
                }
            else if ([annotName isEqualToString:@"action"])
                {
                // XG-NIB target/action method: designable surface. void return,
                // one object param (the sender) — validated in sema.
                isAction = YES;
                }
            else if ([annotName isEqualToString:@"banked"])
                {
                placement = XTPlacementBanked;
                }
            else if ([annotName isEqualToString:@"shadow"])
                {
                placement = XTPlacementShadow;
                }
            else if ([annotName isEqualToString:@"main"])
                {
                placement = XTPlacementMain;
                }
            else if ([annotName isEqualToString:@"cloaked"])
                {
                placement = XTPlacementCloaked;
                // Optional `(<id>)` to pin to a specific cloaked region
                // declared in the layout's [cloaked] sections. Without
                // an id, the codegen packer first-fits across regions
                // in declaration order.
                if ([self match:XTTokenLParen])
                    {
                    if ([self check:XTTokenIdentifier])
                        {
                        cloakedRegionId = [self advance].value;
                        }
                    else
                        {
                        [_diagnostics emitError:
                                          @":cloaked(<id>) expects an identifier inside the parens"
                                             at:tok.location];
                        }
                    if (![self match:XTTokenRParen])
                        {
                        [_diagnostics emitError:
                                          @":cloaked(<id>) — missing closing ')'"
                                             at:tok.location];
                        }
                    }
                }
            else
                {
                [_diagnostics emitWarning:[NSString stringWithFormat:@"Unknown annotation '%@'", tok.value]
                                 category:XTWarnUnknownAnnotation
                                       at:tok.location];
                }
            // Consume comma separator if present
            if (![self match:XTTokenComma])
                break;
            }
        }
        // Mutually-exclusive epilogues — let the parser flag the conflict
        // before codegen has to.
        {
        int epilogueCount = (isNaked ? 1 : 0) + (isIrq ? 1 : 0) + (isVbi ? 1 : 0);
        if (epilogueCount > 1)
            {
            [_diagnostics emitError:@"function annotations :naked / :irq / :vbi are mutually exclusive"
                                 at:loc];
            }
        }
    // :irq and :vbi handlers must live in main RAM at a stable
    // address — the OS dispatcher JMPs directly through their vector
    // slot and can't go through a bank-switch trampoline. Reject
    // explicit :banked combined with either; :shadow is fine (the
    // dispatcher works equally well from shadow RAM as long as ROM
    // is off when the interrupt fires).
    if ((isIrq || isVbi) && placement == XTPlacementBanked)
        {
        [_diagnostics emitError:@":banked is incompatible with :irq / :vbi (handlers must sit at a stable address)"
                             at:loc];
        }

    // `throws` — the effect marker, between the signature and the body. Checked:
    // a caller must either handle the error or be `throws` itself.
    BOOL throwsError = NO;
    if ([self check:XTTokenThrows])
        {
        [self advance];
        throwsError = YES;
        }

    XTASTNode* body = nil;
    if ([self checkBlockOpen])
        {
        // Blocks (task #26): parameters are visible to capture analysis.
        [self blkPushScope];
        for (XTParamNode* p in params)
            [self blkBind:p.paramName type:p.paramType];
        id outerFn = self.blkState[@"fn"];
        self.blkState[@"fn"] = name ?: (id)[NSNull null];
        body = [self parseBlock];
        self.blkState[@"fn"] = outerFn ?: (id)[NSNull null];
        [self blkPopScope];
        }
    else
        {
        [self match:XTTokenSemicolon];
        }

    XTFunctionDeclNode* fn = [[XTFunctionDeclNode alloc] initWithName:name
                                                          returnTypes:returnTypes
                                                           parameters:params
                                                            isVarArgs:isVarArgs
                                                                 body:body
                                                             location:loc];
    fn.stackConvention = stackConv;
    fn.isNaked = isNaked;
    fn.throwsError = throwsError;
    fn.needsOS = needsOS;
    fn.isIrq = isIrq;
    fn.isVbi = isVbi;
    fn.isAction = isAction;
    fn.placement = placement;
    fn.cloakedRegionId = cloakedRegionId;
    return fn;
    }

#pragma mark - Type Parsing

/****************************************************************************\
|* Parse a comma-separated list of types (used for function return types).
|* @return  An array of parsed XTType objects; empty if no type is found.
\****************************************************************************/
- (NSArray<XTType*>*)parseTypeList
    {
    NSMutableArray<XTType*>* types = [NSMutableArray array];
    XTType* t = [self tryParseType];
    if (!t)
        return types;
    [types addObject:t];
    while ([self match:XTTokenComma])
        {
        XTType* next = [self tryParseType];
        if (!next)
            break;
        [types addObject:next];
        }
    return types;
    }

/****************************************************************************\
|* Try to parse a type at the current position. Returns nil without consuming
|* tokens if the current token is not a type keyword or registered type name.
|* @return  The parsed type, or nil if not a type.
\****************************************************************************/
- (nullable XTType*)tryParseType
    {
    XTToken* cur = [self currentToken];
    if (cur.isTypeKeyword || [_typeTable isTypeName:cur.value])
        {
        return [self parseType];
        }
    if ([self blkKeywordAhead])
        return [self parseType]; // task #26
    if ([self cbKeywordAhead])
        return [self parseType]; // callback (0.5)
    // Qualifier-prefixed types (`weak:T@`, `banked:T@`, etc.) also
    // start a valid type-list: a bare `weak` identifier isn't itself
    // a type keyword, but the parseType machinery knows how to
    // consume the prefix before the base type.
    if ([self looksLikeQualifierPrefixedType])
        {
        return [self parseType];
        }
    // An undefined identifier followed by a pointer sigil is an opaque-pointer
    // type (`iop*` — the incomplete-type idiom parseType accepts as void*). This
    // is only reached from a declaration's type-list (return type / first
    // declarator), where `iop* io_open(...)` is unambiguous — a bare `a * b`
    // expression never lands here. A local `iop* q;` still isn't a declaration
    // (parseStatement's detector leaves it an expression), so it stays an error,
    // exactly as the self-hosted compiler leaves it unsupported.
    if (cur.type == XTTokenIdentifier && !cur.isTypeKeyword && ![_typeTable isTypeName:cur.value] && XTIsPointerSigil([self peekToken:1].type))
        {
        return [self parseType];
        }
    return nil;
    }

/****************************************************************************\
|* Peek-only lookahead: does the current token start a pointer-type
|* qualifier prefix (`main:` / `shadow:` / `banked:` / `weak:`)
|* followed by enough tokens to form a type? Used by the sizeof,
|* cast, and statement-level decl detectors to tell a prefixed
|* type from a regular identifier expression.
|*
|* Returns YES iff the current token is a qualifier keyword, followed
|* by ':', followed by either a type token OR another qualifier
|* prefix (`weak:banked:T@` nests; the recursive `parseType` handles
|* the actual consumption). Does not advance the position.
\****************************************************************************/
- (BOOL)looksLikeQualifierPrefixedType
    {
    // Now colon-optional and any number of qualifiers — one shared scan.
    return [self currentBeginsQualifierPrefix];
    }

/****************************************************************************\
|* Parse a type specifier including pointer suffixes (@) and array suffixes
|* ([size]). Resolves built-in types, user-defined types, and the `string`
|* alias (u8@).
|* @return  The fully resolved XTType (base, pointer-wrapped, or array).
\****************************************************************************/
/****************************************************************************\
|* The bound-method type for a function signature: the 2-field struct
|* `{ pointer recv; <fn>@ code; }` that `<fn-typedef>^` denotes.
|*
|* Cached in the type table under `$bound_<fn>`, so every `^` on the same
|* signature yields the SAME type object. That identity matters: a `^` is
|* compared as a pair, and two structurally-identical-but-distinct types
|* would break assignment and equality between two `^`s that name the same
|* kind of action.
|*
|* `recv` is a plain pointer for now; it becomes `Object@` when ARC lands on
|* `^` (stage 3), so retain/release of the receiver comes for free.
\****************************************************************************/
- (XTType*)boundMethodTypeForSignature:(XTFunctionType*)fn
    {
    return [self boundMethodTypeForSignature:fn isWeak:NO];
    }

// `weak:` interns a distinct type object from the bare `^` of the same
// signature (the type is shared across every use, so the flag can't be stamped
// on the common one). Both are auto-zeroing when STORED — `weak:` is accepted
// as documentation, not as a behaviour switch. There is no unowned form: a `^`
// cannot self-check a dead receiver, so one must not be offered.
- (XTType*)boundMethodTypeForSignature:(XTFunctionType*)fn isWeak:(BOOL)isWeak
    {
    NSString* name = [NSString stringWithFormat:@"%@_%@",
                                                (isWeak ? @"$wbound" : @"$bound"), fn.displayName];
    XTType* cached = [_typeTable typeForName:name];
    if (cached)
        return cached;

    XTStructField* recv = [[XTStructField alloc]
        initWithName:@"recv"
                type:[XTPointerType pointerToType:[XTType u8Type]]];
    XTStructField* code = [[XTStructField alloc]
        initWithName:@"code"
                type:[XTPointerType pointerToType:fn]];
    XTStructType* st = [XTStructType structNamed:name fields:@[ recv, code ]];
    st.boundMethodSignature = fn;
    st.isWeakBound = isWeak;
    [_typeTable registerType:st forName:name];
    return st;
    }

// The type-prefix qualifier keywords. Placement (`main`/`shadow`/`banked`/
// `raw`), `weak` (ARC), and `outlet` (designable-surface marker). Contextual —
// not reserved words — so they are only treated as qualifiers when a type
// follows the run (see currentBeginsQualifierPrefix).
- (BOOL)isQualifierKeyword:(NSString*)v
    {
    NSString* kw = v.lowercaseString;
    return [kw isEqualToString:@"main"] || [kw isEqualToString:@"shadow"] ||
           [kw isEqualToString:@"banked"] || [kw isEqualToString:@"raw"] ||
           [kw isEqualToString:@"weak"] || [kw isEqualToString:@"outlet"] ||
           [kw isEqualToString:@"simd"];
    }

// Forward-scan (no advance): does the current position begin a run of qualifier
// keywords — each optionally followed by `:` — terminating in a type? This is
// the disambiguator that lets the trailing `:` be optional: `weak outlet T@`,
// `weak:outlet:T@`, and every mix parse, while a plain identifier that happens
// to match a qualifier keyword but ISN'T followed by a type stays an identifier.
- (BOOL)currentBeginsQualifierPrefix
    {
    NSUInteger i = 0;
    BOOL saw = NO;
    while ([self peekToken:i].type == XTTokenIdentifier &&
           [self isQualifierKeyword:[self peekToken:i].value])
        {
        saw = YES;
        i++;
        if ([self peekToken:i].type == XTTokenColon)
            i++; // optional colon
        }
    if (!saw)
        return NO;
    XTToken* t = [self peekToken:i];
    return t.isTypeKeyword || t.type == XTTokenString ||
           [_typeTable isTypeName:t.value];
    }

/****************************************************************************\
|* Does the current position — just past a `(` — hold a COMPLETE type followed
|* by the closing paren? That is the only thing that makes `( … )` a cast.
|*
|* The old test looked at ONE token: a type keyword or a known type name meant
|* "cast". A class name is a known type name, so
|*
|*     (u32)(Klass.method())
|*
|* took the cast path on the INNER paren — it read `Klass` as a cast type, then
|* demanded `)` and found `.`. The workaround was to bind the call to a local
|* first, which is not a thing a user should have to know. Any parenthesised
|* expression starting with a class name hit it: `(Klass.a() + 1)` too.
|*
|* The scan models the type grammar exactly — qualifier run, base type, `@`/`^`
|* suffixes, `[N]` array suffix, the failable `?` — and requires `)` (or the
|* `))` block token) immediately after. Anything else is an expression. It never
|* advances.
\****************************************************************************/
- (BOOL)looksLikeCastAhead
    {
    NSUInteger i = 0;
    // Blocks (task #26): `(block [name] RET(params))expr` is a cast to a
    // block type — e.g. the null idiom `(block u32(u32))0`. Scan the
    // header shape and require the cast's own closing paren after it.
    //
    // `callback` (0.5) takes the SAME branch, not a parallel one: the two
    // headers have identical shape, so a second copy of this scan would be a
    // second thing to keep in step. Without this, `(callback void(i32))0`
    // parsed as a parenthesised expression and failed at `void` — the null
    // idiom worked for `block` and for the `^` sigil, and silently not for
    // the spelling that replaces the sigil.
    NSString* kw0 = [self peekToken:0].type == XTTokenIdentifier
                        ? [self peekToken:0].value
                        : nil;
    if ([kw0 isEqualToString:@"block"] || [kw0 isEqualToString:@"callback"])
        {
        NSUInteger j = 1;
        XTToken* t = [self peekToken:j];
        if (t.type == XTTokenIdentifier && !t.isTypeKeyword && ![_typeTable isTypeName:t.value])
            {
            j++;
            t = [self peekToken:j];
            }
        if (!(t.isTypeKeyword || t.type == XTTokenVoid || [_typeTable isTypeName:t.value]))
            return NO;
        j++;
        while (XTIsPointerSigil([self peekToken:j].type))
            j++;
        if ([self peekToken:j].type != XTTokenLParen)
            return NO;
        NSUInteger depth = 0;
        while (j < _tokens.count)
            {
            XTTokenType tt = [self peekToken:j].type;
            if (tt == XTTokenLParen)
                depth++;
            else if (tt == XTTokenRParen)
                {
                depth--;
                if (depth == 0)
                    {
                    j++;
                    break;
                    }
                }
            else if (tt == XTTokenEOF)
                return NO;
            j++;
            }
        return [self peekToken:j].type == XTTokenRParen;
        }
    // Qualifier run: `main:` / `banked:` / `weak:` …, colon optional.
    while ([self peekToken:i].type == XTTokenIdentifier &&
           [self isQualifierKeyword:[self peekToken:i].value])
        {
        i++;
        if ([self peekToken:i].type == XTTokenColon)
            i++;
        }
    XTToken* base = [self peekToken:i];
    // An undefined identifier immediately followed by a pointer sigil is an
    // opaque-pointer cast — `(iop*)p`, the incomplete-type idiom parseType now
    // accepts as `void*`. Guarded tight to the sigil so `(a * b)` (a multiply,
    // where `b` follows the `*`, not `)`) still fails the RParen check below.
    BOOL baseIsOpaquePtr = base.type == XTTokenIdentifier && !base.isTypeKeyword && ![_typeTable isTypeName:base.value] && XTIsPointerSigil([self peekToken:i + 1].type);
    if (!(base.isTypeKeyword || base.type == XTTokenString ||
          [_typeTable isTypeName:base.value] || baseIsOpaquePtr))
        return NO;
    i++;
    // A typed collection's argument list, `(Array<AMSkyPoint>*)0`, as a
    // declaration takes it (astronomancy, 2026-10-25: the cast failed at the
    // `*)`). Only type words, commas, sigils and nested lists may stand inside,
    // so `(font < limit)` with a type called font stays a comparison; `>>`
    // closes two lists.
    if ([_typeTable isTypeName:base.value] && [self peekToken:i].type == XTTokenLess)
        {
        NSInteger depth = 0;
        while (YES)
            {
            XTToken* g = [self peekToken:i];
            if (g.type == XTTokenLess)
                depth++;
            else if (g.type == XTTokenGreater)
                depth--;
            else if (g.type == XTTokenShiftRight)
                depth -= 2;
            else if (!(g.type == XTTokenIdentifier || g.isTypeKeyword || g.type == XTTokenComma ||
                       XTIsPointerSigil(g.type) || g.type == XTTokenCaret))
                return NO;
            i++;
            if (depth < 0)
                return NO;
            if (depth == 0)
                break;
            }
        }
    // Pointer and bound-method suffixes, in any order: `T*`, `T**`, `fn^`.
    while (XTIsPointerSigil([self peekToken:i].type) ||
           [self peekToken:i].type == XTTokenCaret)
        i++;
    // Array suffix `[N]` — a cast to an array type is rare but legal.
    if ([self peekToken:i].type == XTTokenLBracket)
        {
        NSUInteger depth = 0;
        while (i < _tokens.count)
            {
            XTTokenType t = [self peekToken:i].type;
            if (t == XTTokenLBracket)
                depth++;
            else if (t == XTTokenRBracket)
                {
                depth--;
                if (depth == 0)
                    {
                    i++;
                    break;
                    }
                }
            else if (t == XTTokenEOF)
                return NO;
            i++;
            }
        }
    if ([self peekToken:i].type == XTTokenQuestion)
        i++; // failable cast
    XTTokenType end = [self peekToken:i].type;
    return end == XTTokenRParen;
    }

- (XTType*)parseType
    {
    // Blocks (task #26): a stale declared-name stash from an EARLIER block
    // header (e.g. a named literal) must not leak into this type's caller —
    // the header re-stamps it on the way out when this IS a block type.
    self.lastBlockDeclName = nil;
        // `weak: callback …` / `weak: block …`. Rejected — a stored callback
        // ALWAYS auto-zeroes, so the qualifier is implied and there is no other
        // behaviour to ask for (§9A.6) — but rejected with a message that SAYS so.
        //
        // Without this it read as an unqualified type named `weak`: "Unknown type
        // 'weak'", then two more errors from the leftover `:`. Every field written
        // against the older `weak:act_t^` spelling hits exactly this, so the
        // diagnostic is the whole user experience of migrating one.
        {
        XTToken* q = [self currentToken];
        if (q.type == XTTokenIdentifier && [q.value.lowercaseString isEqualToString:@"weak"])
            {
            NSUInteger j = ([self peekToken:1].type == XTTokenColon) ? 2 : 1;
            XTToken* nx = [self peekToken:j];
            BOOL cbNext = nx.type == XTTokenIdentifier && ([nx.value isEqualToString:@"callback"] || [nx.value isEqualToString:@"block"]);
            if (cbNext)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"`weak:` is implied on a %@ and cannot be written — a stored "
                                                          @"%@ always auto-zeroes when its receiver dies. Remove the "
                                                          @"qualifier.",
                                                          nx.value, nx.value]
                                         at:q.location];
                [self advance]; // `weak`
                if ([self check:XTTokenColon])
                    [self advance]; // `:`
                }
            }
        }
    // Blocks v2 (task #29): `block:T` is the write-back CAPTURE qualifier —
    // consumed here and never stored on the type. The variable stays an
    // ordinary T; the mark rides lastTypeIsBlockWb onto the parser binding,
    // which is the only place the capture analysis looks.
    if ([self currentToken].type == XTTokenIdentifier && [[self currentToken].value isEqualToString:@"block"] && [self peekToken:1].type == XTTokenColon)
        {
        [self advance];
        [self advance];
        XTType* inner = [self parseType];
        self.lastTypeIsBlockWb = YES;
        return inner;
        }
    // Blocks (task #26): `block [name] RET(params)` is a TYPE — a pointer
    // to the per-signature base class. The declared name (if any) rides
    // the lastBlockDeclName side channel to the declaration/param site.
    if ([self blkKeywordAhead])
        return [self blkParseTypeHeader];
    if ([self cbKeywordAhead])
        return [self cbParseTypeHeader]; // callback (0.5)
    // Optional pointer placement qualifier: `main:` / `shadow:` /
    // `banked:` before the base type tells the pointer where its
    // pointee lives. Only the outermost `@` picks up this qualifier —
    // inner pointer levels get the default (main) placement. Users
    // who need exotic combinations can add annotations later.
    // The default placement is configurable per-compilation via
    // -[XTParser setDefaultPointerPlacement:] (banked-heap targets
    // set this to Banked so `T@` without a qualifier lands a 3-byte
    // banked pointer that matches the allocator's return type).
    //
    // A leading `weak:` is also accepted here. It's orthogonal to
    // placement — weak:T@ flips ARC emit behaviour, not byte width —
    // but for now sema rejects the combination of `weak:` with any
    // explicit placement. The parser still consumes both so sema
    // can emit a helpful "weak: cannot combine with banked:" error
    // rather than a bare "expected type" at the second colon.
    XTPointerPlacement placement = _defaultPointerPlacement;
    BOOL placementExplicit = NO;
    BOOL isWeak = NO;
    BOOL isOutlet = NO;
    BOOL isSimd = NO;
    // Consume a run of qualifiers, colons optional and order-free
    // (`weak outlet T@`, `weak:outlet:T@`, `banked weak T@`, …). The
    // forward-scan guards against eating a bare identifier that only looks
    // like a qualifier — the run must terminate in a type.
    if ([self currentBeginsQualifierPrefix])
        {
        while ([self currentToken].type == XTTokenIdentifier &&
               [self isQualifierKeyword:[self currentToken].value])
            {
            NSString* kw = [self currentToken].value.lowercaseString;
            if ([kw isEqualToString:@"main"])
                {
                placement = XTPointerPlacementMain;
                placementExplicit = YES;
                }
            else if ([kw isEqualToString:@"shadow"])
                {
                placement = XTPointerPlacementShadow;
                placementExplicit = YES;
                }
            else if ([kw isEqualToString:@"banked"])
                {
                placement = XTPointerPlacementBanked;
                placementExplicit = YES;
                }
            else if ([kw isEqualToString:@"raw"])
                {
                placement = XTPointerPlacementRaw;
                placementExplicit = YES;
                }
            else if ([kw isEqualToString:@"weak"])
                {
                isWeak = YES;
                }
            else if ([kw isEqualToString:@"outlet"])
                {
                isOutlet = YES;
                }
            else if ([kw isEqualToString:@"simd"])
                {
                isSimd = YES;
                }
            [self advance]; // qualifier
            if ([self currentToken].type == XTTokenColon)
                [self advance]; // optional ':'
            }
        }
    _lastTypeIsOutlet = isOutlet; // side-channel for the field-decl parser

    XTToken* cur = [self currentToken];
    XTType* base = nil;

    if (cur.type == XTTokenString)
        {
        [self advance];
        base = [XTPointerType pointerToType:[XTType u8Type]];
        }
    else if (cur.isTypeKeyword || [_typeTable isTypeName:cur.value])
        {
        [self advance];
        base = [_typeTable scalarTypeForKeyword:cur.value] ?: [_typeTable typeForName:cur.value] ?
                                                                                                 : [XTType u8Type];
        }
    else
        {
        // User-defined type name. prescanForwardTypeDeclarations has already
        // registered every class / struct / enum / protocol NAME in this unit, and
        // an imported library's types are registered before the parse begins — so a
        // name that is still unknown here is genuinely unknown.
        //
        // It used to fall back to u8 in silence. That is how an imported struct that
        // the interface never exported LOOKED like it worked: `u16 f(XGRect r)`
        // compiled clean and lowered to `f(U8)`, quietly truncating the parameter.
        // A name we cannot resolve is an error, not a u8.
        [self advance];
        base = [_typeTable typeForName:cur.value];
        if (!base)
            {
            // An undefined type used ONLY as a pointer target is an opaque
            // handle — C's incomplete-type idiom (c2xc leaves `iop` undefined
            // and only ever writes `iop*`). A pointer to it is pointer-sized,
            // so there is NO truncation risk — the by-value case (an unexported
            // struct silently becoming u8, noted above) is the only thing the
            // strictness had to catch, and that still errors here. Match the
            // self-hosted compiler, which lowers such a pointer to Ptr(Void):
            // take the base as void, so `iop*` becomes `void*`. Member access /
            // deref on it still fails (incomplete type). Only when a pointer
            // sigil actually follows; a by-value use of the name stays an error.
            if (XTIsPointerSigil([self currentToken].type))
                {
                base = [XTType voidType];
                }
            else
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"Unknown type '%@'", cur.value]
                                     at:cur.location];
                base = [XTType u8Type]; // keep parsing so later errors still surface
                }
            }
        }

    // `C<T>` — a typed collection. The element type is remembered on a CLONE of
    // the class marker (the shared registry entry must stay unannotated, exactly
    // as for a protocol constraint below), and the type is otherwise the same
    // class it always was: typed collections are erased, so this changes what
    // sema substitutes and nothing about what is generated.
    //
    // `<` after a type name is unambiguous here. It means protocols only in a
    // class HEADER, and nothing at all in a type position until now, so no
    // existing spelling changes meaning.
    if (base && base.kind == XTTypeKindClass && [self check:XTTokenLess])
        {
        [self advance];
        // One argument or two: `Array<T>` / `Set<T>` / `Map<V>` against
        // `Map<K, V>`. More than two is not a thing any container has, and
        // accepting a list would imply a general type-parameter system that
        // this deliberately is not (private:docs/bugs/049).
        NSMutableArray<XTType*>* targs = [NSMutableArray array];
        XTType* first = [self parseType];
        if (first)
            [targs addObject:first];
        while (first && [self match:XTTokenComma])
            {
            XTType* next = [self parseType];
            if (!next)
                break;
            [targs addObject:next];
            }
        if (targs.count > 2)
            {
            [_diagnostics emitError:[NSString stringWithFormat:
                                                  @"'%@' takes at most two type arguments", base.displayName]
                                 at:[self currentLocation]];
            }
        XTType* elem = targs.lastObject;
        XTType* key = targs.count >= 2 ? targs.firstObject : nil;
        if (elem)
            {
            // `Array<Array<i32>>` closes with `>>`, which lexes as one shift
            // token — the C++03 problem. Split it: consume the first `>` by
            // rewriting the token in place, leaving a `>` for the outer list.
            // Deliberately confined to this loop rather than made a lexer rule.
            if ([self check:XTTokenShiftRight])
                {
                XTToken* sh = [self currentToken];
                // In a copy: a stream that is parsed again still reads `>>`
                // there, and the tokens may be a rewrite's immutable array.
                _tokens = [_tokens mutableCopy];
                [(NSMutableArray*)_tokens replaceObjectAtIndex:_pos
                                                    withObject:[XTToken tokenWithType:XTTokenGreater
                                                                                value:@">"
                                                                             location:sh.location]];
                }
            else if (![self match:XTTokenGreater])
                {
                [_diagnostics emitError:@"Expected '>' to close a type argument list"
                                     at:[self currentLocation]];
                }
            // displayName stays the BARE class name. Decorating it to
            // `Array<String>` would break every lookup that resolves a class by
            // its display name — vtables, RTTI, ivar layout — and erasure means
            // this IS an `Array`. The element type rides alongside.
            XTType* annotated = [[XTType alloc] initWithKind:XTTypeKindClass
                                                 displayName:base.displayName];
            annotated.protocolConstraint = base.protocolConstraint;
            annotated.collectionElementType = elem;
            annotated.collectionKeyType = key;
            base = annotated;
            }
        }

    // PR9: a bare protocol name used as a type stamps the
    // `protocolConstraint` field on a cloned class-kind marker so
    // sema's conformance and dispatch machinery treats the type as
    // "something that conforms to <Proto>". Clone the marker so
    // the shared pre-scan entry stays unmodified.
    if (base && base.kind == XTTypeKindClass &&
        [_protocolNames containsObject:base.displayName])
        {
        XTType* constrained = [[XTType alloc]
            initWithKind:XTTypeKindClass
             displayName:base.displayName];
        constrained.protocolConstraint = base.displayName;
        base = constrained;
        }

    // `<fn-typedef>^` — a bound method: the {recv, code} fat pointer that
    // `&obj.method` yields. `^` is to a bound method what `@` is to a pointer.
    // Handled before the `@` loop so `action_t^@` (a pointer to one) still
    // works. See private:docs/Design/bound-methods.md.
    if (base && [base isKindOfClass:[XTFunctionType class]] &&
        [self check:XTTokenCaret])
        {
        [self advance];
        // `weak:action_t^` — auto-zeroing bound method (AppKit target
        // semantics). Consumes the isWeak qualifier so it isn't also applied to
        // an outer `@`.
        base = [self boundMethodTypeForSignature:(XTFunctionType*)base
                                          isWeak:isWeak];
        isWeak = NO;
        }

    // Pointer suffixes: '@' stacks pointers normally.
    //   Myclass c        → bare class instance (stack-allocated)
    //   Myclass@ p       → pointer to class instance (heap or &stack)
    //   Myclass@@ pp     → pointer to pointer (uncommon)
    // Classes are registered as bare marker types in the pre-scan,
    // so `Myclass` alone yields `XTTypeKindClass` and each `@` wraps
    // one more level of `XTPointerType`. Only the outermost pointer
    // picks up an explicit placement qualifier; deeper levels get
    // the default (main) placement so `main:u8@@` means a
    // main-memory pointer to a (main) u8@.
    BOOL firstPointer = YES;
    while ([self matchPointerSigil])
        {
        XTPointerPlacement p = firstPointer
                                   ? placement
                                   : XTPointerPlacementMain;
        // Only the outermost pointer picks up isWeak, the same
        // way placement binds only to the outermost @. `weak:T@@`
        // means a weak pointer to a strong pointer to T, not a
        // strong pointer to a weak pointer.
        BOOL weakThisLevel = firstPointer && isWeak;
        BOOL simdThisLevel = firstPointer && isSimd;
        base = [XTPointerType pointerToType:base
                                  placement:p
                                     isWeak:weakThisLevel
                                     isSimd:simdThisLevel];
        firstPointer = NO;
        }

    // If the user wrote a qualifier but there was no `@`, that's a
    // meaningless annotation on a non-pointer type. Silently ignore
    // for now — a future sema pass could emit a diagnostic.
    (void)placementExplicit;
    (void)isWeak;

    // Array suffix: [size?]
    if ([self match:XTTokenLBracket])
        {
        NSUInteger count = 0;
        if (![self check:XTTokenRBracket])
            {
            XTASTNode* sizeExpr = [self parseExpression];
            count = [self resolveArraySizeExpr:sizeExpr];
            }
        [self expect:XTTokenRBracket];
        base = [XTArrayType arrayOfType:base count:count];
        }

    return base;
    }

#pragma mark - Statements

/****************************************************************************\
|* Parse a block of statements delimited by { } or (( )). Consumes the
|* opening and closing delimiters.
|* @return  An XTBlockNode containing the parsed statements.
\****************************************************************************/
- (XTASTNode*)parseBlock
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance];      // consume { or ((
    [self blkPushScope]; // task #26
    NSMutableArray<XTASTNode*>* stmts = [NSMutableArray array];

    while ((self.pwPending || (![self checkBlockClose] && ![self check:XTTokenEOF])) && !_diagnostics.hasFatalError)
        {
        XTASTNode* stmt = [self parseListStatement];
        if (stmt)
            [stmts addObject:stmt];
        }

    [self expectBlockClose];
    [self blkPopScope]; // task #26
    return [[XTBlockNode alloc] initWithStatements:stmts location:loc];
    }

/****************************************************************************\
|* Test whether the current token opens a block.
|* @return  YES if the current token is a block-open delimiter.
\****************************************************************************/
- (BOOL)checkBlockOpen
    {
    return [self check:XTTokenLBrace];
    }

/****************************************************************************\
|* Test whether the current token closes a block.
|* @return  YES if the current token is a block-close delimiter.
\****************************************************************************/
- (BOOL)checkBlockClose
    {
    return [self check:XTTokenRBrace];
    }

/****************************************************************************\
|* Expect and consume a block-open token, emitting a diagnostic
|* error if neither is found.
\****************************************************************************/
- (void)expectBlockOpen
    {
    if (![self match:XTTokenLBrace])
        {
        [_diagnostics emitError:@"Expected '{' to begin block" at:[self currentLocation]];
        }
    }

/****************************************************************************\
|* Expect and consume a block-close token, emitting a diagnostic
|* error if neither is found.
\****************************************************************************/
- (void)expectBlockClose
    {
    if (![self match:XTTokenRBrace])
        {
        [_diagnostics emitError:@"Expected '}' to end block" at:[self currentLocation]];
        }
    }

// A statement of a braced block or a case body: a counted `while` there
// leaves its `if (v < B) v = B;` as the statement after it (parseStatement).
- (nullable XTASTNode*)parseListStatement
    {
    self.pwInList = YES;
    return [self parseStatement];
    }

/****************************************************************************\
|* Parse a single statement: if, while, for, return, break, continue, asm,
|* block, typedef, struct, enum, variable declaration, tuple assignment,
|* or expression statement.
|* @return  The parsed statement AST node, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseStatement
    {
    BOOL inList = self.pwInList;
    self.pwInList = NO;
    if (self.pwPending)
        return [self parAutoWhileIf];
    XTToken* cur = [self currentToken];

    // `par` is a CONTEXTUAL keyword — library code uses it as a name
    // (`u32* par = …; par[i] = …`) — so it starts a block only when what
    // follows can only be one: `{`, a decorator `:`, or a name and then either.
    if (cur.type == XTTokenIdentifier && [cur.value isEqualToString:@"par"])
        {
        XTToken* t1 = [self peekToken:1];
        XTToken* t2 = [self peekToken:2];
        if (t1.type == XTTokenLBrace || t1.type == XTTokenColon
            || (t1.type == XTTokenIdentifier && (t2.type == XTTokenLBrace || t2.type == XTTokenColon)))
            return [self parsePar];
        }

    switch (cur.type)
        {
    case XTTokenIf:
        return [self parseIf];
    case XTTokenWhile:
        {
        // A loop that --par-style=auto looks at because no loop is open: the
        // loop around it, parsed again as a block's, would see one (parAutoFor).
        if (self.parAuto && [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0)
            self.parAutoDepthReads++;
        // --par-style=auto: a counted while loop becomes the `for` it amounts to,
        // which parAutoFor then takes or leaves (parAutoWhileShape).
        // Without the par runtime parAutoFor leaves the loop and asks for
        // Par.xc to be imported (the driver parses again).
        if (self.parAuto && ![[self blkFrames].lastObject[@"par"] boolValue] &&
            [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0)
            {
            XTSourceLocation* wloc = [self currentLocation];
            self.parAutoWhy = nil;
            if ([self parAutoWhileShape])
                {
                self.parAutoFromWhile = YES;
                NSUInteger at = self.pwAt, pe = self.pwPe;
                NSArray<XTToken*>* bound = [_tokens subarrayWithRange:NSMakeRange(at + 4, pe + 1 - (at + 4))];
                NSString* v = self.pwV;
                XTToken* cmp = _tokens[at + 3];
                XTASTNode* f = [self parAutoFor];
                self.pwPending = YES;
                self.pwPendV = v;
                self.pwPendBound = bound;
                self.pwPendCmp = cmp;
                self.pwPendLoc = wloc;
                if (inList)
                    return f;
                // The body of an if, else or loop: the `for` and its `if`
                // are one statement, a block, which the walk reads as the
                // `while` (plSite).
                XTASTNode* g = [self parAutoWhileIf];
                XTBlockNode* one = [[XTBlockNode alloc] initWithStatements:f ? @[ f, g ] : @[ g ] location:wloc];
                NSDictionary* site = [self.plSites objectForKey:f];
                if (site)
                    [self plRegister:one entry:@{ @"kind" : @4, @"plain" : site[@"plain"], @"inc" : site[@"inc"] }];
                return one;
                }
            NSString* wwhy = self.parAutoWhy ?: @"while-shape";
            [self parAutoTraceAt:wloc verdict:@"serial" rule:wwhy form:@"while" name:nil reds:nil grid:0 impl:nil];
            [self parGridLoop:1];
            [self parAutoLoop:1];
            XTASTNode* wn = [self parseWhile];
            [self parAutoLoop:-1];
            [self parGridLoop:-1];
            [self plCheckWhile:wn at:wloc why:wwhy];
            return wn;
            }
        [self parGridLoop:1];
        [self parAutoLoop:1];
        XTASTNode* n = [self parseWhile];
        [self parAutoLoop:-1];
        [self parGridLoop:-1];
        return n;
        }
    case XTTokenFor:
        {
        if (self.parAuto && [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0)
            self.parAutoDepthReads++;
        // --par-style=auto: an outermost loop in plain code may become a par block —
        // inside a block literal too (its captures are captured again), but
        // not inside a par body, which is a block already.
        if (self.parAuto && ![[self blkFrames].lastObject[@"par"] boolValue] &&
            [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0)
            return [self parAutoFor];
        [self parGridLoop:1];
        [self parAutoLoop:1];
        XTASTNode* n = [self parseFor];
        [self parAutoLoop:-1];
        [self parGridLoop:-1];
        return n;
        }
    case XTTokenSwitch:
        {
        [self parGridSwitch:1];
        XTASTNode* n = [self parseSwitch];
        [self parGridSwitch:-1];
        return n;
        }
    case XTTokenReturn:
        {
        XTASTNode* n = [self parseReturn];
        return n ? [self parGridReturn:(XTReturnNode*)n] : nil;
        }
    case XTTokenBreak:
        {
        [self advance];
        [self expect:XTTokenSemicolon];
        [self parGridBreakAt:cur.location];
        return [[XTBreakNode alloc] initWithLocation:cur.location];
        }
    case XTTokenContinue:
        {
        [self advance];
        [self expect:XTTokenSemicolon];
        return [[XTContinueNode alloc] initWithLocation:cur.location];
        }
    case XTTokenGoto:
        {
        // `goto <label>;` — a C-porting aid (undocumented as a language
        // feature). The label is a bare identifier; refop/ARC keywords are
        // not valid targets.
        [self advance];
        XTToken* lbl = [self expect:XTTokenIdentifier];
        [self expect:XTTokenSemicolon];
        return lbl ? [[XTGotoNode alloc] initWithTargetLabel:lbl.value location:cur.location] : nil;
        }
    case XTTokenDefer:
        return [self parseDefer];
    case XTTokenThrow:
        return [self parseThrow];
    case XTTokenTry:
        return [self parseTry];
    case XTTokenDelete:
        {
        if ([self looksLikeRefopFunctionCall])
            break;
        return [self parseRefOp:XTRefOpDelete];
        }
    case XTTokenRetain:
        {
        if ([self looksLikeRefopFunctionCall])
            break;
        return [self parseRefOp:XTRefOpRetain];
        }
    case XTTokenRelease:
        {
        if ([self looksLikeRefopFunctionCall])
            break;
        return [self parseRefOp:XTRefOpRelease];
        }
    case XTTokenAsm:
        return [self parseAsmBlock];
    case XTTokenLBrace:
        return [self parseBlock];
    case XTTokenTypedef:
        return [self parseTypedef];
    case XTTokenStruct:
        return [self parseStructDecl:YES];
    case XTTokenEnum:
        return [self parseEnumDecl];
    default:
        break;
        }

    // Tuple assignment: ( ... ) = expr;
    if (cur.type == XTTokenLParen && [self looksLikeTupleAssign])
        {
        return [self parseTupleAssign];
        }

        // Variable declaration? (may start with 'volatile')
        // But not if the type name is followed by '.' — that's a static method call (e.g. Stdio.printf)
        {
        BOOL isVarDecl = cur.isTypeKeyword || cur.type == XTTokenVolatile || cur.type == XTTokenRegister ||
                         cur.type == XTTokenStatic || cur.type == XTTokenGlobal || [_typeTable isTypeName:cur.value];
        // A declared type NAME starts a declaration only when what follows
        // could begin a declarator: another identifier, a pointer sigil, `^`,
        // or `<` (`Array<String>* a`), exactly as the self-hosted parser
        // decides. A program may name a field or variable the same as a
        // type: `font = 5;` with a type `font` in scope is an assignment, and
        // `Stdio.printf(...)` a static call. Testing only for `.` read the
        // assignment as a declaration (bug 594).
        if (isVarDecl && !cur.isTypeKeyword && [_typeTable isTypeName:cur.value] && _pos + 1 < _tokens.count)
            {
            XTTokenType nx = [_tokens[_pos + 1] type];
            if (!(nx == XTTokenIdentifier || XTIsPointerSigil(nx) || nx == XTTokenCaret || nx == XTTokenLess))
                isVarDecl = NO;
            }
        // A qualifier prefix — `main:` / `shadow:` / `banked:` /
        // `weak:` — also starts a variable declaration once followed
        // by a type token (directly, or via a nested second prefix
        // like `weak:banked:T@`). Sema is the one that rejects any
        // combinations this parser accepts structurally.
        if (!isVarDecl && [self looksLikeQualifierPrefixedType])
            {
            isVarDecl = YES;
            }
        if (!isVarDecl && [self blkKeywordAhead])
            isVarDecl = YES; // task #26
        if (!isVarDecl && [self cbKeywordAhead])
            isVarDecl = YES;                            // callback (0.5)
        if (!isVarDecl && cur.type == XTTokenIdentifier // task #29
            && [cur.value isEqualToString:@"block"] && [_tokens[_pos + 1] type] == XTTokenColon)
            isVarDecl = YES;
        if (isVarDecl)
            return [self parseVarDeclStatement];
        }

    // `<name>:` at statement position is a LABEL (a goto target). Checked after
    // the var-decl / qualifier-prefix handling above, so a contextual `weak:` /
    // `main:` type prefix is already consumed and only a real label remains.
    if (cur.type == XTTokenIdentifier && _pos + 1 < _tokens.count && _tokens[_pos + 1].type == XTTokenColon)
        {
        [self advance]; // the label name
        [self advance]; // ':'
        return [[XTLabelNode alloc] initWithLabelName:cur.value location:cur.location];
        }

    // Expression statement
    XTSourceLocation* loc = [self currentLocation];
    XTASTNode* expr = [self parseExpression];
    if (!expr)
        return nil;
    [self expect:XTTokenSemicolon];
    return [[XTExpressionStatementNode alloc] initWithExpression:expr location:loc];
    }

/****************************************************************************\
|* Parse a local variable declaration statement. Handles qualifiers (volatile,
|* register, static, global), C-style array suffixes, C reserved word
|* validation, comma-separated multi-declarators, and parameterised stack-class
|* construction (e.g. `Myclass c(a, b);`).
|* @return  A variable decl node, or a synthetic block wrapping multiple decls.
\****************************************************************************/
- (nullable XTASTNode*)parseVarDeclStatement
    {
    XTSourceLocation* loc = [self currentLocation];

    // Check for qualifiers: volatile, register, static, global (in any order)
    BOOL isVolatile = NO;
    BOOL isRegister = NO;
    BOOL isStatic = NO;
    BOOL isGlobal = NO;
    while ([self check:XTTokenVolatile] || [self check:XTTokenRegister] ||
           [self check:XTTokenStatic] || [self check:XTTokenGlobal])
        {
        if ([self match:XTTokenVolatile])
            isVolatile = YES;
        if ([self match:XTTokenRegister])
            isRegister = YES;
        if ([self match:XTTokenStatic])
            isStatic = YES;
        if ([self match:XTTokenGlobal])
            isGlobal = YES;
        }

    self.lastTypeIsBlockWb = NO;
    XTType* varType = [self parseType];
    BOOL fieldIsOutlet = self.lastTypeIsOutlet; // captured before any nested parse stomps it
    // v2 (task #29): the write-back qualifier marks the BINDING only.
    BOOL declIsBlockWb = self.lastTypeIsBlockWb;
    self.lastTypeIsBlockWb = NO;
    if (declIsBlockWb && ([varType isKindOfClass:[XTArrayType class]] || varType.kind == XTTypeKindStruct))
        {
        [_diagnostics emitError:@"`block:` write-back captures are scalars "
                                @"and pointers in v2 — an array or struct cannot copy back "
                                @"through the hidden pointer"
                             at:loc];
        declIsBlockWb = NO;
        }
    // Blocks (task #26): the declared name arrived inside the type header
    // (`block blk u32(…)`), so there is no separate identifier to expect.
    NSString* blockDeclName = self.lastBlockDeclName;
    NSString* blockBaseName = self.lastBlockBaseName;
    NSArray<XTParamNode*>* blockParams = self.lastBlockParams;
    XTType* blockRet = self.lastBlockRet;
    self.lastBlockDeclName = nil;
    XTToken* nameTok = nil;
    if (blockDeclName.length)
        {
        nameTok = [[XTToken alloc] initWithType:XTTokenIdentifier
                                          value:blockDeclName
                                       location:loc];
        }
    else
        {
        nameTok = [self expect:XTTokenIdentifier];
        }
    if (!nameTok)
        return nil;

    // C-style array suffix after variable name: u8 vals[] or u8 vals[10]
    if ([self match:XTTokenLBracket])
        {
        NSUInteger count = 0;
        if (![self check:XTTokenRBracket])
            {
            XTASTNode* sizeExpr = [self parseExpression];
            count = [self resolveArraySizeExpr:sizeExpr];
            }
        [self expect:XTTokenRBracket];
        varType = [XTArrayType arrayOfType:varType count:count];
        }

    // Validate identifier is not a C reserved word
    if ([sCReservedWords containsObject:nameTok.value])
        {
        [_diagnostics emitError:[NSString stringWithFormat:@"'%@' is a reserved word and cannot be used as a variable name", nameTok.value] at:nameTok.location];
        }

    NSMutableArray<XTASTNode*>* decls = [NSMutableArray array];
    XTASTNode* firstInit = nil;
    NSArray<XTASTNode*>* firstCtorArgs = nil;
    BOOL blockBodyInit = NO;
    if (blockDeclName.length && [self match:XTTokenAssign])
        {
        // `block b u32(…) = { body }` — the braces are the literal's BODY,
        // with the signature (names included) taken from the declaration.
        // Any other initialiser expression (another block value) parses
        // normally below.
        if ([self checkBlockOpen])
            {
            firstInit = [self blkParseLiteralBodyWithBase:blockBaseName
                                                      ret:blockRet
                                                   params:blockParams
                                                 selfName:nameTok.value
                                                       at:loc];
            blockBodyInit = YES;
            }
        else
            {
            firstInit = [self stringInitForArrayType:varType initialiser:[self parseInitialiser]];
            }
        [self blkBind:nameTok.value type:varType];
        }
    else if ([self match:XTTokenAssign])
        {
        firstInit = [self stringInitForArrayType:varType initialiser:[self parseInitialiser]];
        }
    else if ([self check:XTTokenLParen])
        {
        // Parameterised stack-class construction: `Myclass c(a, b);`
        // Desugared below into a two-statement block:
        //   1. `Myclass c;` with constructorArgs set (marker telling
        //      emitLocalVarDecl to skip the auto-init call — the
        //      explicit init call in step 2 will handle it)
        //   2. `c.init(a, b);` which goes through normal method call
        //      codegen and uses sema's overload resolution to pick
        //      the right init() variant.
        [self advance]; // consume '('
        NSMutableArray<XTASTNode*>* args = [NSMutableArray array];
        if (![self check:XTTokenRParen])
            {
            XTASTNode* first = [self parseExpression];
            if (first)
                [args addObject:first];
            while ([self match:XTTokenComma])
                {
                XTASTNode* next = [self parseExpression];
                if (next)
                    [args addObject:next];
                }
            }
        [self expect:XTTokenRParen];
        firstCtorArgs = args;
        }
    XTVariableDeclNode* firstDecl = [[XTVariableDeclNode alloc] initWithName:nameTok.value
                                                                        type:varType
                                                                 initialiser:firstInit
                                                                    location:loc];
    firstDecl.nameLocation = nameTok.location;
    firstDecl.isVolatile = isVolatile;
    firstDecl.isRegister = isRegister;
    firstDecl.isStatic = isStatic;
    firstDecl.isGlobal = isGlobal;
    firstDecl.isOutlet = fieldIsOutlet;
    firstDecl.constructorArgs = firstCtorArgs;
    [decls addObject:firstDecl];
    [self blkBind:firstDecl.varName type:firstDecl.declaredType]; // task #26
    if (declIsBlockWb)
        [self blkMarkWb:firstDecl.varName]; // task #29
    if (!firstDecl.declaredType || firstDecl.declaredType.kind == XTTypeKindAuto)
        [self blkBindAuto:firstDecl.varName fromInit:firstInit]; // task #26
    [self blkMarkHoldsWb:firstDecl.varName fromInit:firstInit];  // task #29

    while ([self match:XTTokenComma])
        {
        XTToken* nextName = [self expect:XTTokenIdentifier];
        if (!nextName)
            break;
        XTASTNode* nextInit = nil;
        if ([self match:XTTokenAssign])
            {
            nextInit = [self stringInitForArrayType:varType initialiser:[self parseInitialiser]];
            }
        XTVariableDeclNode* nextDecl = [[XTVariableDeclNode alloc] initWithName:nextName.value
                                                                           type:varType
                                                                    initialiser:nextInit
                                                                       location:nextName.location];
        nextDecl.nameLocation = nextName.location;
        nextDecl.isRegister = isRegister;
        nextDecl.isStatic = isStatic;
        nextDecl.isGlobal = isGlobal;
        nextDecl.isOutlet = fieldIsOutlet;
        [decls addObject:nextDecl];
        [self blkBind:nextDecl.varName type:nextDecl.declaredType]; // task #26
        }

    if (blockBodyInit)
        [self match:XTTokenSemicolon]; // `}` closes it, `;` optional
    else
        [self expect:XTTokenSemicolon];

    // Parameterised stack-class construction: expand the decl into
    // a synthetic two-statement block [decl, c.init(args);]. The
    // decl has constructorArgs set so emitLocalVarDecl skips its
    // default auto-init, then the explicit init() method call
    // fires via normal method-call codegen (overload resolution,
    // argument passing, self-pointer setup).
    // Only the leading declarator's constructor form is handled;
    // comma-chained declarators like `Point a(1, 2), b(3, 4);`
    // would need per-declarator expansion, which isn't supported
    // yet. The parser falls back to "no initialiser" on subsequent
    // declarators (their constructorArgs stays nil).
    if (firstCtorArgs)
        {
        XTIdentifierNode* receiver = [[XTIdentifierNode alloc]
            initWithName:nameTok.value
                location:nameTok.location];
        XTMethodCallExprNode* initCall = [[XTMethodCallExprNode alloc]
            initWithReceiver:receiver
                  methodName:@"init"
                   arguments:firstCtorArgs
                    location:loc];
        XTExpressionStatementNode* initStmt = [[XTExpressionStatementNode alloc]
            initWithExpression:initCall
                      location:loc];
        initStmt.srcFacts |= XTSrcSynth; // its arguments are the declaration's (pfwNode)
        NSMutableArray<XTASTNode*>* stmts = [NSMutableArray arrayWithArray:decls];
        [stmts addObject:initStmt];
        XTBlockNode* block = [[XTBlockNode alloc] initWithStatements:stmts location:loc];
        block.isDeclList = YES;
        return block;
        }

    if (decls.count == 1)
        return decls.firstObject;
    XTBlockNode* block = [[XTBlockNode alloc] initWithStatements:decls location:loc];
    block.isDeclList = YES;
    return block;
    }

/****************************************************************************\
|* Parse an initialiser expression. Handles array/struct initialiser lists
|* delimited by { }, recursing for nested lists. Falls back to a single
|* expression otherwise.
|*
|* `[ ... ]` was accepted here as an alternative, for the same reason `(( ))`
|* was accepted as a block: an Atari 8-bit keyboard has no brace keys. `(( ))`
|* is gone, so this went with it — an initialiser is now spelled the way C
|* spells one, and there is one form to learn instead of two. (The ENUM body
|* is a separate parse path and still takes either.)
|* @return  The initialiser AST node (expression or synthetic block for lists).
\****************************************************************************/
// `u8 name[8] = "ABCDEFG";` — a string literal initialising an array of bytes
// is the list of its bytes and a NUL, as C reads it. Left as the literal it
// stored the POINTER's bytes into the array (both compilers, the Base64
// alphabet), so it is rewritten here, where the declared type is known; an
// unsized array then takes its size from the list.
- (nullable XTASTNode*)stringInitForArrayType:(nullable XTType*)type initialiser:(nullable XTASTNode*)init
    {
    if (![init isKindOfClass:[XTLiteralStringNode class]] || ![type isKindOfClass:[XTArrayType class]])
        return init;
    NSString* elem = ((XTArrayType*)type).elementType.displayName;
    if (![elem isEqualToString:@"u8"] && ![elem isEqualToString:@"i8"])
        return init;
    XTSourceLocation* loc = init.location;
    NSData* bytes = [((XTLiteralStringNode*)init).stringValue dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray<XTASTNode*>* items = [NSMutableArray arrayWithCapacity:bytes.length + 1];
    const uint8_t* b = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++)
        [items addObject:[[XTLiteralIntNode alloc] initWithValue:(int64_t)b[i] location:loc]];
    [items addObject:[[XTLiteralIntNode alloc] initWithValue:0 location:loc]];
    return [[XTBlockNode alloc] initWithStatements:items location:loc];
    }

- (nullable XTASTNode*)parseInitialiser
    {
    XTSourceLocation* loc = [self currentLocation];
    if ([self check:XTTokenLBrace])
        {
        // Array / struct initialiser list
        [self advance];
        NSMutableArray<XTASTNode*>* items = [NSMutableArray array];
        while (![self check:XTTokenRBrace] && ![self check:XTTokenEOF])
            {
            // Recurse for nested initialiser lists so a struct-of-struct
            // (or array-of-struct) literal like
            //   Outer o = { 1, { 2, 3 }, 4 };
            // doesn't try to parse the inner `{...}` as an expression
            // (which returns nil and crashes the array append).
            XTASTNode* item = [self check:XTTokenLBrace]
                                  ? [self parseInitialiser]
                                  : [self parseExpression];
            if (item)
                [items addObject:item];
            [self match:XTTokenComma];
            }
        [self advance]; // consume }
        // Return a synthetic "initialiser list" as a block node
        return [[XTBlockNode alloc] initWithStatements:items location:loc];
        }
    // Range form: `start..end` / `start...end`. Same lexer tokens
    // as the for-in range form; parseExpression stops at `..` so
    // we pick it up here. Both bounds required — open forms only
    // make sense bound to an array (slice expression), and that's
    // what `arr[m..]` / `arr[..n]` are for.
    XTASTNode* first = [self parseExpression];
    if ([self check:XTTokenDotDot] || [self check:XTTokenEllipsis])
        {
        BOOL inclusive = [self check:XTTokenEllipsis];
        [self advance];
        XTASTNode* endExpr = [self parseExpression];
        return [[XTRangeExprNode alloc] initWithStart:first
                                                  end:endExpr
                                            inclusive:inclusive
                                             location:loc];
        }
    return first;
    }

/****************************************************************************\
|* Parse an if statement with optional else / else-if chains.
|* @return  An XTIfNode.
\****************************************************************************/
- (nullable XTASTNode*)parseIf
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'if'
    [self expect:XTTokenLParen];
    XTASTNode* condition = [self parseExpression];
    [self expect:XTTokenRParen];
    XTASTNode* thenBlock = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];
    XTASTNode* elseBlock = nil;
    if ([self match:XTTokenElse])
        {
        elseBlock = [self check:XTTokenIf] ? [self parseIf] : ([self checkBlockOpen] ? [self parseBlock] : [self parseStatement]);
        }
    return [[XTIfNode alloc] initWithCondition:condition thenBlock:thenBlock elseBlock:elseBlock location:loc];
    }

/****************************************************************************\
|* Parse a while loop: `while (condition) body`.
|* @return  An XTWhileNode.
\****************************************************************************/
- (nullable XTASTNode*)parseWhile
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'while'
    [self expect:XTTokenLParen];
    XTASTNode* cond = [self parseExpression];
    [self expect:XTTokenRParen];
    XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];
    XTWhileNode* w = [[XTWhileNode alloc] initWithCondition:cond body:body location:loc];
    // The goal of the loop or block around it, else the file's or the build's:
    // a while loop has no annotation of its own. As the port.
    w.goal = [self loopGoal:0];
    return w;
    }

/****************************************************************************\
|* A loop's goal: its own (annotation bits 2 speed, 4 accuracy), else the goal
|* of the loop or block it sits in, else the file's #goal, else -fgoal=; 0 for
|* none (the built-in default, accuracy).
\****************************************************************************/
- (NSUInteger)loopGoal:(NSUInteger)annots
    {
    if (annots & 2)
        return 1;
    if (annots & 4)
        return 2;
    return self.goalNow ?: self.goalDefault;
    }

/****************************************************************************\
|* Parse `throw expr;` — raise an error.
|* @return  An XTThrowNode.
\****************************************************************************/
- (nullable XTASTNode*)parseThrow
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'throw'
    XTASTNode* operand = [self parseExpression];
    if (!operand)
        return nil;
    [self expect:XTTokenSemicolon];
    return [[XTThrowNode alloc] initWithOperand:operand location:loc];
    }

/****************************************************************************\
|* Parse `try { ... } catch (name) { ... }`.
|*
|* E1 takes ONE untyped handler; the typed `catch (IOError e)` chain is E2, and
|* the binder is parsed as a bare identifier so adding a leading type later is a
|* pure extension rather than a change.
|* @return  An XTTryNode.
\****************************************************************************/
- (nullable XTASTNode*)parseTry
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'try'
    if (![self checkBlockOpen])
        {
        [_diagnostics emitError:@"'try' wants a block: try { ... } catch (e) { ... }"
                             at:[self currentLocation]];
        return nil;
        }
    XTASTNode* tryBlock = [self parseBlock];
    if (!tryBlock)
        return nil;
    if (![self check:XTTokenCatch])
        {
        [_diagnostics emitError:@"'try' must be followed by 'catch (name) { ... }'"
                             at:[self currentLocation]];
        return nil;
        }

    NSMutableArray<XTCatchClause*>* clauses = [NSMutableArray array];
    while ([self check:XTTokenCatch])
        {
        XTSourceLocation* cloc = [self currentLocation];
        [self advance]; // consume 'catch'
        [self expect:XTTokenLParen];

        // `catch (T e)` or `catch (e)`. Two identifiers means the first is a
        // type; one means an untyped arm that catches everything.
        XTToken* first = [self currentToken];
        if (first.type != XTTokenIdentifier)
            {
            [_diagnostics emitError:@"'catch' wants a binding name: catch (e) or catch (T e)"
                                 at:[self currentLocation]];
            return nil;
            }
        [self advance];
        NSString* typeName = nil;
        NSString* varName = first.value;
        if ([self check:XTTokenIdentifier])
            {
            typeName = first.value;
            varName = [self currentToken].value;
            [self advance];
            }
        [self expect:XTTokenRParen];
        if (![self checkBlockOpen])
            {
            [_diagnostics emitError:@"'catch' wants a block" at:[self currentLocation]];
            return nil;
            }
        XTASTNode* blk = [self parseBlock];
        if (!blk)
            return nil;

        XTCatchClause* c = [[XTCatchClause alloc] init];
        c.typeName = typeName;
        c.varName = varName;
        c.block = blk;
        c.location = cloc;
        [clauses addObject:c];
        }
    return [[XTTryNode alloc] initWithTryBlock:tryBlock
                                  catchClauses:clauses
                                      location:loc];
    }

/****************************************************************************\
|* Parse `defer { ... }` — a block to run when the enclosing scope exits.
|*
|* The body must be a BLOCK, not a bare statement. `while`/`if` accept either,
|* but a defer body is emitted at several exit points rather than one, so
|* requiring braces keeps what is deferred unambiguous at a glance — and leaves
|* `defer` followed by a bare statement free to mean something later.
|* @return  An XTDeferNode.
\****************************************************************************/
/****************************************************************************\
|* Parse `par [name] (:reduce(op var))* [:goal(speed|accuracy)] { body }`, the data-parallel
|* block. The reduction operator is one of + * & | ^ min max.
\****************************************************************************/
// --par-style=auto: a `for` loop in plain code becomes a `par` block when its shape
// allows — `for (T i in a..b) { … }` whose body writes only its own locals,
// array elements, and integer reductions (`acc = acc + e` or `acc += e`, with
// acc used nowhere else in the body), with no break of its own, return, goto,
// label, and no outer name incremented, taken by address or written through a
// member. The decision is made on the TOKENS, before parsing, so both parsers
// decide alike without a trial parse; a loop that qualifies is parsed inside a
// par frame, as `par <file:line> :reduce(op acc) { for … }` would be. What the
// tokens cannot tell — a dependence between items, a call the GPU cannot make
// — par-check decides after lowering, and demotes an auto block to a serial
// run rather than refusing it. Mirrored in the port (parAutoFor).
- (void)parAutoLoop:(NSInteger)delta
    {
    NSInteger d = [self.blkState[@"loopDepth"] integerValue] + delta;
    self.blkState[@"loopDepth"] = @(d);
    }

- (XTTokenType)parTokType:(NSUInteger)i
    {
    return i < _tokens.count ? ((XTToken*)_tokens[i]).type : XTTokenEOF;
    }

- (NSString*)parTokValue:(NSUInteger)i
    {
    return i < _tokens.count ? (((XTToken*)_tokens[i]).value ?: @"") : @"";
    }

static BOOL parAutoAnyAssignOp(XTTokenType t)
    {
    return t >= XTTokenAssign && t <= XTTokenCaretAssign;
    }

// The index just past the statement that starts at `from` (its `;`, or the
// `}` of its block): a block, an `if` with its `else`, a `for`, `while` or
// `switch` and its body, `do S while (…);`, else the `;` at depth 0. 0 when
// the tokens run out. Mirrored in the port.
- (NSUInteger)parAutoStatementEnd:(NSUInteger)from limit:(NSUInteger)n
    {
    XTTokenType t = [self parTokType:from];
    if (t == XTTokenLBrace)
        {
        NSUInteger d = 0;
        for (NSUInteger i = from; i < n; i++)
            {
            XTTokenType ty = [self parTokType:i];
            if (ty == XTTokenLBrace)
                d++;
            else if (ty == XTTokenRBrace && --d == 0)
                return i;
            }
        return 0;
        }
    if (t == XTTokenIf || t == XTTokenFor || t == XTTokenWhile || t == XTTokenSwitch)
        {
        // The parenthesised head, then the statement; `if` may go on with `else`.
        if ([self parTokType:from + 1] != XTTokenLParen)
            return 0;
        NSUInteger d = 0;
        NSUInteger i = from + 1;
        for (; i < n; i++)
            {
            XTTokenType ty = [self parTokType:i];
            if (ty == XTTokenLParen)
                d++;
            else if (ty == XTTokenRParen && --d == 0)
                break;
            }
        if (i >= n)
            return 0;
        NSUInteger e = [self parAutoStatementEnd:i + 1 limit:n];
        if (e == 0)
            return 0;
        if (t == XTTokenIf && [self parTokType:e + 1] == XTTokenElse)
            return [self parAutoStatementEnd:e + 2 limit:n];
        return e;
        }
    NSUInteger d = 0;
    for (NSUInteger i = from; i < n; i++)
        {
        XTTokenType ty = [self parTokType:i];
        if (ty == XTTokenLParen || ty == XTTokenLBracket || ty == XTTokenLBrace)
            d++;
        else if (ty == XTTokenRParen || ty == XTTokenRBracket || ty == XTTokenRBrace)
            d--;
        else if (ty == XTTokenSemicolon && d == 0)
            return i;
        }
    return 0;
    }

// parAutoScan's refusal: the rule, for XC_PAR_AUTO_TRACE. Mirrored in the port.
- (BOOL)parAutoNo:(NSString*)rule
    {
    self.parAutoWhy = rule;
    return NO;
    }

// -Wpar-auto, at the loop the cursor is on: why it stays a loop.
- (void)parAutoWarnSerial:(NSString*)why
    {
    if (self.plStream && !self.plWarn)
        return;
    [_diagnostics emitWarning:[@"this loop runs serially, not as a 'par' block (--par-style): " stringByAppendingString:why]
                     category:XTWarnParAuto
                           at:[self currentLocation]];
    }

// Token i is a variable's name: an identifier not after `.` or `->`.
- (BOOL)parAutoIsVarTok:(NSUInteger)i
    {
    XTTokenType p = [self parTokType:i - 1];
    return [self parTokType:i] == XTTokenIdentifier && p != XTTokenDot && p != XTTokenArrow;
    }

// The variable at token i is written there: assigned, or stepped by ++ or
// --. A declaration of the name (a type before it) is not a write, nor is a
// store through it.
- (BOOL)parAutoWritesAt:(NSUInteger)i
    {
    XTTokenType nx = [self parTokType:i + 1];
    XTTokenType pv = [self parTokType:i - 1];
    if ((i >= 1 && i - 1 < _tokens.count && ((XTToken*)_tokens[i - 1]).isTypeKeyword) ||
        (pv == XTTokenIdentifier && [_typeTable isTypeName:[self parTokValue:i - 1]]))
        return NO;
    // `*p = …` writes what p points at, not p.
    if (pv == XTTokenStar && parAutoAnyAssignOp(nx))
        return NO;
    return parAutoAnyAssignOp(nx) || nx == XTTokenPlusPlus || nx == XTTokenMinusMinus ||
           pv == XTTokenPlusPlus || pv == XTTokenMinusMinus;
    }

// #415: the body [bs, be) writes the loop's own variable (`i++`, `i += 2`,
// `i = …`). A block's work items each have their own copy, and the loop as
// written skips or repeats iterations. Mirrored in the port.
- (BOOL)parAutoIVWrittenFrom:(NSUInteger)bs to:(NSUInteger)be var:(NSString*)var
    {
    for (NSUInteger i = bs; i < be; i++)
        if ([self parAutoIsVarTok:i] && [[self parTokValue:i] isEqualToString:var] && [self parAutoWritesAt:i])
            return YES;
    return NO;
    }

// #416: a block reads the loop's bound [b0, b1) once, before its items run;
// the loop as written reads it before every iteration. A bound that names
// the loop's variable or a variable the body [bs, be) writes, or that reads
// memory (a subscript, a member, a call, `*p`) through a name the body stores
// through, keeps the loop serial. A call in the body is not taken as a store,
// as elsewhere in the scan. The reason for -Wpar-auto (and the rule in
// parAutoWhy), else nil. Mirrored in the port.
- (nullable NSString*)parAutoBoundFrom:(NSUInteger)b0 to:(NSUInteger)b1 writtenFrom:(NSUInteger)bs to:(NSUInteger)be var:(NSString*)var
    {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    BOOL mem = NO;
    for (NSUInteger i = b0; i < b1; i++)
        {
        XTTokenType t = [self parTokType:i];
        if (t == XTTokenLBracket || t == XTTokenDot || t == XTTokenArrow)
            mem = YES;
        if (t == XTTokenStar)
            {
            XTTokenType p = [self parTokType:i - 1];
            if (i == b0 || !(p == XTTokenIdentifier || p == XTTokenIntLiteral || p == XTTokenRParen || p == XTTokenRBracket))
                mem = YES;
            }
        if (![self parAutoIsVarTok:i])
            continue;
        if ([self parTokType:i + 1] == XTTokenLParen)
            {
            mem = YES;
            continue;
            }
        NSString* nm = [self parTokValue:i];
        if ([_typeTable isTypeName:nm])
            continue;
        if ([nm isEqualToString:var])
            {
            self.parAutoWhy = @"bound-write";
            return [NSString stringWithFormat:@"its bound reads its loop variable '%@'", nm];
            }
        [names addObject:nm];
        }
    for (NSUInteger i = bs; i < be; i++)
        {
        if (![self parAutoIsVarTok:i])
            continue;
        NSString* nm = [self parTokValue:i];
        if (![names containsObject:nm])
            continue;
        if ([self parAutoWritesAt:i])
            {
            self.parAutoWhy = @"bound-write";
            return [NSString stringWithFormat:@"its bound reads '%@', which its body writes", nm];
            }
        if (!mem)
            continue;
        // Through the name: a store at the end of its subscripts and members
        // (a method call ends them), or `*p = …`.
        NSUInteger j = i + 1;
        BOOL chained = NO;
        while (j < be)
            {
            XTTokenType t = [self parTokType:j];
            if (t == XTTokenLBracket)
                {
                NSUInteger d = 0;
                while (j < be)
                    {
                    XTTokenType tj = [self parTokType:j];
                    if (tj == XTTokenLBracket)
                        d++;
                    if (tj == XTTokenRBracket && --d == 0)
                        break;
                    j++;
                    }
                j++;
                chained = YES;
                continue;
                }
            if ((t == XTTokenDot || t == XTTokenArrow) && [self parTokType:j + 1] == XTTokenIdentifier &&
                [self parTokType:j + 2] != XTTokenLParen)
                {
                j += 2;
                chained = YES;
                continue;
                }
            break;
            }
        XTTokenType at = [self parTokType:j];
        XTTokenType pv = [self parTokType:i - 1];
        BOOL stored = chained && (parAutoAnyAssignOp(at) || at == XTTokenPlusPlus || at == XTTokenMinusMinus ||
                                  pv == XTTokenPlusPlus || pv == XTTokenMinusMinus);
        if (pv == XTTokenStar && parAutoAnyAssignOp([self parTokType:i + 1]))
            stored = YES;
        if (stored)
            {
            self.parAutoWhy = @"bound-memory";
            return [NSString stringWithFormat:@"its bound reads memory through '%@', which its body may write", nm];
            }
        }
    return nil;
    }

// The grid levels (3, 2, or 1 for none) a perfect nest may take, the body of
// its level `level - 1` being [bs, be): a level whose body writes its own
// variable or a name in its header runs as written inside the block, for the
// reasons of #415 and #416 one level in. Mirrored in the port.
- (NSUInteger)parAutoGridCapFrom:(NSUInteger)bs to:(NSUInteger)be level:(NSUInteger)level
    {
    if (level > 3 || [self parTokType:bs] != XTTokenFor || [self parTokType:bs + 1] != XTTokenLParen)
        return 3;
    NSUInteger n = _tokens.count;
    NSUInteger e = [self parAutoStatementEnd:bs limit:n];
    if (e == 0 || (e + 1 != be && e != be))
        return 3;
    NSUInteger he = 0, d = 0;
    NSString* iv = nil;
    NSString* ivEq = nil;
    for (NSUInteger i = bs + 1; i < e; i++)
        {
        XTTokenType t = [self parTokType:i];
        if (t == XTTokenLParen)
            d++;
        else if (t == XTTokenRParen)
            {
            if (--d == 0)
                {
                he = i;
                break;
                }
            }
        else if (d == 1 && t == XTTokenIn && [self parTokType:i - 1] == XTTokenIdentifier && !iv)
            iv = [self parTokValue:i - 1];
        else if (d == 1 && t == XTTokenAssign && [self parTokType:i - 1] == XTTokenIdentifier && !ivEq)
            ivEq = [self parTokValue:i - 1];
        }
    if (!iv)
        iv = ivEq;
    if (he == 0 || !iv)
        return 3;
    NSMutableArray<NSString*>* names = [NSMutableArray arrayWithObject:iv];
    for (NSUInteger i = bs + 2; i < he; i++)
        {
        if (![self parAutoIsVarTok:i] || [self parTokType:i + 1] == XTTokenLParen)
            continue;
        NSString* nm = [self parTokValue:i];
        if ([_typeTable isTypeName:nm] || [nm isEqualToString:iv] || [nm isEqualToString:@"step"])
            continue;
        [names addObject:nm];
        }
    // The level's annotations, then its body.
    NSUInteger k = he + 1;
    if ([self parTokType:k] == XTTokenColon)
        {
        k++;
        while ([self parTokType:k] == XTTokenIdentifier)
            {
            k++;
            if ([self parTokType:k] == XTTokenLParen)
                {
                NSUInteger pd = 0;
                while (k < e)
                    {
                    XTTokenType t = [self parTokType:k];
                    if (t == XTTokenLParen)
                        pd++;
                    if (t == XTTokenRParen && --pd == 0)
                        break;
                    k++;
                    }
                k++;
                }
            if ([self parTokType:k] != XTTokenComma)
                break;
            k++;
            }
        }
    NSUInteger ibs = k, ibe = e;
    if ([self parTokType:k] == XTTokenLBrace)
        ibs = k + 1;
    for (NSUInteger i = ibs; i < ibe; i++)
        {
        if (![self parAutoIsVarTok:i] || ![self parAutoWritesAt:i])
            continue;
        if ([names containsObject:[self parTokValue:i]])
            return level - 1;
        }
    return [self parAutoGridCapFrom:ibs to:ibe level:level + 1];
    }

// XC_PAR_AUTO_TRACE: the line for a loop --par-style=auto looked at, at `loc`:
// where (file:line, #n for the n-th on the line), the verdict and the rule
// that decided it, the loop's form, and for a block its name, reductions,
// grid rank and ParImpl number ("-" where there is none). A loop of the
// standard library or the prelude is not listed. Mirrored in the port.
- (void)parAutoTraceAt:(XTSourceLocation*)loc verdict:(NSString*)verdict rule:(nullable NSString*)rule form:(NSString*)form
                  name:(nullable NSString*)name reds:(nullable NSString*)reds grid:(NSUInteger)grid impl:(nullable NSString*)impl
    {
    if (!self.parAutoTraceOn)
        return;
    NSString* file = loc.filename ?: @"?";
    if ([self.libraryFiles containsObject:file])
        return;
    NSString* pos = [NSString stringWithFormat:@"%@:%lu", file.lastPathComponent, (unsigned long)loc.line];
    if (!_parAutoTrace)
        _parAutoTrace = [NSMutableArray array];
    [_parAutoTrace addObject:[NSString stringWithFormat:@"par-auto-trace: %@\t%@ rule=%@ form=%@ name=%@ reds=%@ grid=%@ impl=%@", pos,
                                                        verdict, rule ?: @"?", form, name ?: @"-", reds ?: @"-",
                                                        grid ? [NSString stringWithFormat:@"%lu", (unsigned long)grid] : @"-",
                                                        impl ?: @"-"]];
    }

// The lines in order. A trace line is kept as `file:line`, a tab and the
// rest, and the n-th line at a place (n > 1) is named `file:line#n` here, so
// a loop's line can go where the loop starts after the lines of the loops
// inside it (parAutoFor). As the port.
- (nullable NSMutableArray<NSString*>*)parAutoTrace
    {
    if (!_parAutoTrace)
        return nil;
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* seen = [NSMutableDictionary dictionary];
    NSString* pre = @"par-auto-trace: ";
    for (NSString* l in _parAutoTrace)
        {
        NSRange tab = [l rangeOfString:@"\t"];
        if (![l hasPrefix:pre] || tab.location == NSNotFound)
            {
            [out addObject:l];
            continue;
            }
        NSString* pos = [l substringWithRange:NSMakeRange(pre.length, tab.location - pre.length)];
        NSUInteger nth = seen[pos].unsignedIntegerValue + 1;
        seen[pos] = @(nth);
        NSString* at = nth > 1 ? [NSString stringWithFormat:@"%@#%lu", pos, (unsigned long)nth] : pos;
        [out addObject:[NSString stringWithFormat:@"%@%@ %@", pre, at, [l substringFromIndex:tab.location + 1]]];
        }
    return out;
    }

// Move a's entries from `from` on to index `to` (to <= from). As the port.
static void parAutoMoveTail(NSMutableArray* _Nullable a, NSUInteger from, NSUInteger to)
    {
    if (!a || from >= a.count || to >= from)
        return;
    NSArray* tail = [a subarrayWithRange:NSMakeRange(from, a.count - from)];
    [a removeObjectsInRange:NSMakeRange(from, a.count - from)];
    [a insertObjects:tail atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(to, tail.count)]];
    }

// XC_PAR_AUTO_CHECK: the token scan on the loop at the cursor, for its
// verdict and the source facts it read (parAutoScan); its warnings are the
// recogniser's to give. As the port.
- (NSMutableDictionary*)parAutoScanCheck:(BOOL)fromWhile
    {
    NSArray<XTToken*>* realToks = _tokens;
    NSUInteger realPos = _pos;
    NSUInteger diagAt = _diagnostics.diagnostics.count;
    BOOL fatalAt = _diagnostics.hasFatalError;
    if (fromWhile)
        _tokens = [self parAutoWhileStream:YES];
    NSMutableArray<NSArray<NSString*>*>* reds = [NSMutableArray array];
    NSUInteger goal = 0;
    BOOL scanned = [self parAutoScan:reds goal:&goal];
    _tokens = realToks;
    _pos = realPos;
    [_diagnostics truncateToCount:diagAt fatal:fatalAt];
    NSMutableDictionary* s = [NSMutableDictionary dictionary];
    s[@"lift"] = @(scanned);
    s[@"form"] = fromWhile ? @"while" : self.parAutoForm;
    if (!scanned)
        s[@"rule"] = self.parAutoWhy ?: @"?";
    else
        {
        NSMutableArray<NSString*>* rl = [NSMutableArray array];
        for (NSArray<NSString*>* r in reds)
            [rl addObject:[NSString stringWithFormat:@"%@:%@%@", r[0], r[1], r.count > 2 ? @"[]" : @""]];
        s[@"reds"] = [rl componentsJoinedByString:@","];
        s[@"grid"] = @(self.parAutoGridCap);
        s[@"goal"] = @(goal);
        if (self.parScanAcc)
            s[@"scan"] = [NSString stringWithFormat:@"%@:%@", self.parScanOp, self.parScanAcc];
        }
    self.parScanAcc = nil;
    self.parScanOp = nil;
    return s;
    }

// What a parse of a loop changes that parAutoRollback puts back: the cursor
// and the tokens (a rewrite copies them), the diagnostics and the trace, the
// block, ParImpl, :scan and lifted-loop numbers, the classes made, the
// runtime request, the `if` a counted `while` leaves, and what the last
// declaration noted. As the port.
- (NSDictionary*)parAutoMark
    {
    NSMutableDictionary* m = [NSMutableDictionary dictionary];
    m[@"tokens"] = _tokens;
    m[@"pos"] = @(_pos);
    m[@"diag"] = @(_diagnostics.diagnostics.count);
    m[@"fatal"] = @(_diagnostics.hasFatalError);
    m[@"trace"] = @(_parAutoTrace.count);
    m[@"wants"] = @(_parAutoWantsRuntime);
    m[@"blk"] = self.blkState[@"counter"] ?: @0;
    m[@"par"] = self.blkState[@"parCounter"] ?: @0;
    m[@"seq"] = @(self.scanSeq);
    m[@"auto"] = self.blkState[@"parAutoCounter"] ?: @0;
    m[@"labels"] = @(self.parAutoLabelLog.count);
    m[@"classes"] = @([self blkClasses].count);
    m[@"pw"] = @(self.pwPending);
    if (self.pwPendV) m[@"pwV"] = self.pwPendV;
    if (self.pwPendBound) m[@"pwBound"] = self.pwPendBound;
    if (self.pwPendCmp) m[@"pwCmp"] = self.pwPendCmp;
    if (self.pwPendLoc) m[@"pwLoc"] = self.pwPendLoc;
    if (self.lastBlockDeclName) m[@"lastName"] = self.lastBlockDeclName;
    if (self.lastBlockBaseName) m[@"lastBase"] = self.lastBlockBaseName;
    if (self.lastBlockParams) m[@"lastParams"] = self.lastBlockParams;
    if (self.lastBlockRet) m[@"lastRet"] = self.lastBlockRet;
    m[@"lastWb"] = @(self.lastTypeIsBlockWb);
    m[@"outlet"] = @(self.lastTypeIsOutlet);
    m[@"vararg"] = @(self.sawVarargForward);
    return m;
    }

- (void)parAutoRollback:(NSDictionary*)m
    {
    _tokens = m[@"tokens"];
    _pos = [m[@"pos"] unsignedIntegerValue];
    [_diagnostics truncateToCount:[m[@"diag"] unsignedIntegerValue] fatal:[m[@"fatal"] boolValue]];
    NSUInteger trace = [m[@"trace"] unsignedIntegerValue];
    if (_parAutoTrace.count > trace)
        [_parAutoTrace removeObjectsInRange:NSMakeRange(trace, _parAutoTrace.count - trace)];
    _parAutoWantsRuntime = [m[@"wants"] boolValue];
    self.blkState[@"counter"] = m[@"blk"];
    self.blkState[@"parCounter"] = m[@"par"];
    self.scanSeq = [m[@"seq"] unsignedIntegerValue];
    self.blkState[@"parAutoCounter"] = m[@"auto"];
    NSUInteger labels = [m[@"labels"] unsignedIntegerValue];
    NSMutableDictionary<NSString*, NSNumber*>* counts = self.blkState[@"parAutoLabels"];
    while (self.parAutoLabelLog.count > labels)
        {
        NSString* name = self.parAutoLabelLog.lastObject;
        [self.parAutoLabelLog removeLastObject];
        counts[name] = @(counts[name].unsignedIntegerValue - 1);
        }
    NSMutableArray* classes = [self blkClasses];
    NSUInteger nc = [m[@"classes"] unsignedIntegerValue];
    if (classes.count > nc)
        [classes removeObjectsInRange:NSMakeRange(nc, classes.count - nc)];
    self.pwPending = [m[@"pw"] boolValue];
    self.pwPendV = m[@"pwV"];
    self.pwPendBound = m[@"pwBound"];
    self.pwPendCmp = m[@"pwCmp"];
    self.pwPendLoc = m[@"pwLoc"];
    self.lastBlockDeclName = m[@"lastName"];
    self.lastBlockBaseName = m[@"lastBase"];
    self.lastBlockParams = m[@"lastParams"];
    self.lastBlockRet = m[@"lastRet"];
    self.lastTypeIsBlockWb = [m[@"lastWb"] boolValue];
    self.lastTypeIsOutlet = [m[@"outlet"] boolValue];
    self.sawVarargForward = [m[@"vararg"] boolValue];
    }

// A line for the driver to print with the trace (XC_PAR_AUTO_CHECK).
- (void)parAutoAddLine:(NSString*)line
    {
    if (!_parAutoTrace)
        _parAutoTrace = [NSMutableArray array];
    [_parAutoTrace addObject:line];
    }

// ParImpl numbers [from, to) for XC_PAR_AUTO_TRACE: `n`, `a..b`, or nil.
static NSString* _Nullable parAutoImplSpan(NSUInteger from, NSUInteger to)
    {
    if (to <= from)
        return nil;
    if (to - from > 1)
        return [NSString stringWithFormat:@"%lu..%lu", (unsigned long)from, (unsigned long)(to - 1)];
    return [NSString stringWithFormat:@"%lu", (unsigned long)from];
    }

// XC_PAR_AUTO_CHECK: a fact parAutoScan read from the tokens.
- (void)pacNote:(XTSrcFact)bit value:(BOOL)v
    {
    self.pacSeen |= bit;
    if (v)
        self.pacVal |= bit;
    else
        self.pacVal &= ~(NSUInteger)bit;
    }

// A loop's source facts from its annotations (parseLoopAnnotations): `serial`,
// a `goal` of its own, spelt as the scan spells them, and an annotation the
// parser does not know.
- (XTSrcFact)parAutoLoopFacts:(NSUInteger)annots
    {
    XTSrcFact f = 0;
    if (annots & 32)
        f |= XTSrcSerial;
    if (annots & 16)
        f |= XTSrcGoal;
    if (annots & 64)
        f |= XTSrcAnnot;
    return f;
    }

// An integer literal's value as parAutoScan reads it: decimal, or hex after
// `0x`, up to the first character that is not a digit of the base. A leading
// 0 is a decimal digit, as the lexer reads it: the language has no octal.
// Mirrored in the port (parLiteralValue).
static unsigned long long parLiteralValue(NSString* t)
    {
    const char* s = t.UTF8String;
    size_t n = strlen(s);
    size_t i = 0;
    unsigned base = 10;
    if (n > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        {
        base = 16;
        i = 2;
        }
    unsigned long long v = 0;
    for (; i < n; i++)
        {
        char c = s[i];
        unsigned d = c >= '0' && c <= '9' ? (unsigned)(c - '0')
                   : c >= 'a' && c <= 'f' ? (unsigned)(c - 'a') + 10
                   : c >= 'A' && c <= 'F' ? (unsigned)(c - 'A') + 10 : 99;
        if (d >= base)
            break;
        v = v * base + d;
        }
    return v;
    }

// A range `for` with `in` at token `inAt`: its bounds are two integer
// literals that descend, as parAutoScan reads them (parLiteralValue).
- (BOOL)parAutoDescends:(NSUInteger)inAt
    {
    XTTokenType dots = [self parTokType:inAt + 2];
    if ([self parTokType:inAt] != XTTokenIn || [self parTokType:inAt + 1] != XTTokenIntLiteral ||
        (dots != XTTokenDotDot && dots != XTTokenEllipsis) || [self parTokType:inAt + 3] != XTTokenIntLiteral)
        return NO;
    return parLiteralValue([self parTokValue:inAt + 1]) > parLiteralValue([self parTokValue:inAt + 3]);
    }

// Whether a range's end bound holds the name `step` (a variable, callee or
// member) outside parentheses and brackets, where the scan reads it as a
// `step` with no literal after it. Mirrored in the port.
BOOL pacStepInBound(XTASTNode* _Nullable e)
    {
    if (!e || (e.srcFacts & XTSrcParen))
        return NO;
    BOOL bareCallee = (e.srcFacts & XTSrcParenCallee) == 0;
    if ([e isKindOfClass:[XTIdentifierNode class]])
        return [((XTIdentifierNode*)e).identName isEqualToString:@"step"];
    if ([e isKindOfClass:[XTCallExprNode class]])
        return bareCallee && [((XTCallExprNode*)e).calleeName isEqualToString:@"step"];
    if ([e isKindOfClass:[XTMemberAccessNode class]])
        return [((XTMemberAccessNode*)e).memberName isEqualToString:@"step"] || pacStepInBound(((XTMemberAccessNode*)e).base);
    if ([e isKindOfClass:[XTMethodCallExprNode class]])
        return (bareCallee && [((XTMethodCallExprNode*)e).methodName isEqualToString:@"step"]) ||
               pacStepInBound(((XTMethodCallExprNode*)e).receiver);
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        return pacStepInBound(((XTBinaryExprNode*)e).left) || pacStepInBound(((XTBinaryExprNode*)e).right);
    if ([e isKindOfClass:[XTAssignExprNode class]])
        return pacStepInBound(((XTAssignExprNode*)e).lhs) || pacStepInBound(((XTAssignExprNode*)e).rhs);
    if ([e isKindOfClass:[XTTernaryExprNode class]])
        return pacStepInBound(((XTTernaryExprNode*)e).condition) || pacStepInBound(((XTTernaryExprNode*)e).thenExpr) ||
               pacStepInBound(((XTTernaryExprNode*)e).elseExpr);
    if ([e isKindOfClass:[XTUnaryExprNode class]])
        return pacStepInBound(((XTUnaryExprNode*)e).operand);
    if ([e isKindOfClass:[XTPostfixExprNode class]])
        return pacStepInBound(((XTPostfixExprNode*)e).operand);
    if ([e isKindOfClass:[XTCastExprNode class]])
        return pacStepInBound(((XTCastExprNode*)e).operand);
    if ([e isKindOfClass:[XTSubscriptExprNode class]])
        return pacStepInBound(((XTSubscriptExprNode*)e).base);
    return NO;
    }

// The node whose first token is `e`'s first token, one level down, or nil.
XTASTNode* _Nullable pacFirstKid(XTASTNode* e)
    {
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        return ((XTBinaryExprNode*)e).left;
    if ([e isKindOfClass:[XTAssignExprNode class]])
        return ((XTAssignExprNode*)e).lhs;
    if ([e isKindOfClass:[XTTernaryExprNode class]])
        return ((XTTernaryExprNode*)e).condition;
    if ([e isKindOfClass:[XTPostfixExprNode class]])
        return ((XTPostfixExprNode*)e).operand;
    if ([e isKindOfClass:[XTMemberAccessNode class]])
        return ((XTMemberAccessNode*)e).base;
    if ([e isKindOfClass:[XTSubscriptExprNode class]])
        return ((XTSubscriptExprNode*)e).base;
    if ([e isKindOfClass:[XTMethodCallExprNode class]])
        return ((XTMethodCallExprNode*)e).receiver;
    return nil;
    }

BOOL pacIsVar(XTASTNode* _Nullable e, NSString* v)
    {
    return [e isKindOfClass:[XTIdentifierNode class]] && !(e.srcFacts & XTSrcParen) &&
           [((XTIdentifierNode*)e).identName isEqualToString:v];
    }

BOOL pacIsOne(XTASTNode* _Nullable e)
    {
    return [e isKindOfClass:[XTLiteralIntNode class]] && !(e.srcFacts & XTSrcParen) && (e.srcFacts & XTSrcPlain) &&
           ((XTLiteralIntNode*)e).intValue == 1;
    }

// The C-style condition parAutoScan takes: its first two tokens are the
// declared variable and `<` or `<=`. Mirrored in the port.
static BOOL pacCondOk(XTForCStyleNode* loop)
    {
    if (![loop.loopInit isKindOfClass:[XTVariableDeclNode class]])
        return NO;
    NSString* var = ((XTVariableDeclNode*)loop.loopInit).varName;
    XTASTNode* n = loop.condition;
    while (n && !(n.srcFacts & XTSrcParen))
        {
        XTASTNode* first = pacFirstKid(n);
        if (!first)
            return NO;
        if ([first isKindOfClass:[XTIdentifierNode class]])
            {
            if (!pacIsVar(first, var) || ![n isKindOfClass:[XTBinaryExprNode class]])
                return NO;
            XTBinaryOp op = ((XTBinaryExprNode*)n).op;
            return op == XTBinaryOpLt || op == XTBinaryOpLe;
            }
        n = first;
        }
    return NO;
    }

// The C-style step parAutoScan takes, as its tokens: `v++`, `++v`, `v += 1`
// or `v = v + 1`, the 1 spelled so, nothing in parentheses. Mirrored in the port.
static BOOL pacStepOk(XTForCStyleNode* loop)
    {
    if (![loop.loopInit isKindOfClass:[XTVariableDeclNode class]])
        return NO;
    NSString* var = ((XTVariableDeclNode*)loop.loopInit).varName;
    XTASTNode* st = loop.increment;
    if (!st || (st.srcFacts & XTSrcParen))
        return NO;
    if ([st isKindOfClass:[XTPostfixExprNode class]])
        return ((XTPostfixExprNode*)st).postfixOp == XTPostfixOpInc && pacIsVar(((XTPostfixExprNode*)st).operand, var);
    if ([st isKindOfClass:[XTUnaryExprNode class]])
        return ((XTUnaryExprNode*)st).op == XTUnaryOpPreInc && pacIsVar(((XTUnaryExprNode*)st).operand, var);
    if (![st isKindOfClass:[XTAssignExprNode class]])
        return NO;
    XTAssignExprNode* a = (XTAssignExprNode*)st;
    if (!pacIsVar(a.lhs, var))
        return NO;
    if (a.assignOp == XTAssignOpAdd)
        return pacIsOne(a.rhs);
    if (a.assignOp != XTAssignOpAssign || ![a.rhs isKindOfClass:[XTBinaryExprNode class]] || (a.rhs.srcFacts & XTSrcParen))
        return NO;
    XTBinaryExprNode* b = (XTBinaryExprNode*)a.rhs;
    return b.op == XTBinaryOpAdd && pacIsVar(b.left, var) && pacIsOne(b.right);
    }

// One fact for parAutoCheck's line; NO when scan and node disagree.
static BOOL pacFact(NSMutableString* out, NSString* name, XTSrcFact bit, NSUInteger seen, NSUInteger val, NSUInteger have)
    {
    if (!(seen & bit))
        return YES;
    BOOL s = (val & bit) != 0;
    BOOL h = (have & bit) != 0;
    [out appendFormat:@" %@=%d", name, s ? 1 : 0];
    if (s != h)
        [out appendFormat:@"/%d!", h ? 1 : 0];
    return s == h;
    }

// XC_PAR_AUTO_CHECK=flags: the line for the loop at `loc`, comparing each
// fact the scan read (seen, val) with what the node says: its source facts,
// and for the C-style condition and step the shape the tree gives with them.
// `name=v` where the two agree, `name=scan/node!` where not. Mirrored in the port.
- (void)parAutoCheck:(nullable XTASTNode*)loop at:(XTSourceLocation*)loc seen:(NSUInteger)seen val:(NSUInteger)val
    {
    if (!self.parAutoCheckOn || !seen)
        return;
    NSString* file = loc.filename ?: @"?";
    if ([self.libraryFiles containsObject:file])
        return;
    XTForCStyleNode* fc = [loop isKindOfClass:[XTForCStyleNode class]] ? (XTForCStyleNode*)loop : nil;
    BOOL range = fc && (fc.srcFacts & XTSrcRange);
    NSUInteger have = 0;
    if (range)
        have |= XTSrcRange;
    if (fc)
        have |= fc.srcFacts & (XTSrcSerial | XTSrcGoal);
    if (range && ((fc.srcFacts & XTSrcStepBad) ||
                  ([fc.condition isKindOfClass:[XTBinaryExprNode class]] && pacStepInBound(((XTBinaryExprNode*)fc.condition).right))))
        have |= XTSrcStepBad;
    if (range && (fc.srcFacts & XTSrcDesc))
        have |= XTSrcDesc;
    if (fc && pacCondOk(fc))
        have |= XTSrcChkCond;
    if (fc && pacStepOk(fc))
        have |= XTSrcChkStep;
    NSMutableString* facts = [NSMutableString string];
    BOOL ok = pacFact(facts, @"range", XTSrcRange, seen, val, have);
    ok = pacFact(facts, @"serial", XTSrcSerial, seen, val, have) && ok;
    ok = pacFact(facts, @"goal", XTSrcGoal, seen, val, have) && ok;
    ok = pacFact(facts, @"stepbad", XTSrcStepBad, seen, val, have) && ok;
    ok = pacFact(facts, @"desc", XTSrcDesc, seen, val, have) && ok;
    ok = pacFact(facts, @"cond", XTSrcChkCond, seen, val, have) && ok;
    ok = pacFact(facts, @"step", XTSrcChkStep, seen, val, have) && ok;
    if (!_parAutoTrace)
        _parAutoTrace = [NSMutableArray array];
    [_parAutoTrace addObject:[NSString stringWithFormat:@"par-auto-check: %@:%lu:%lu %@%@", file.lastPathComponent,
                                                        (unsigned long)loc.line, (unsigned long)loc.column, ok ? @"ok" : @"differ", facts]];
    }

// The scan behind parAutoFor: the cursor is at the `for`. Fills `reds`
// (op, name pairs) and says whether the loop qualifies.
- (nullable XTASTNode*)parAutoScanFor:(XTASTNode*)plain at:(NSUInteger)forPos
    {
    NSUInteger plainEnd = _pos;
    NSUInteger diagMark = _diagnostics.diagnostics.count;
    NSUInteger errMark = _diagnostics.errorCount;
    NSArray<XTToken*>* saved = [_tokens copy];
    XTSourceLocation* loc = ((XTToken*)_tokens[forPos]).location;
    XTToken* (^T)(XTTokenType, NSString*) = ^XTToken*(XTTokenType ty, NSString* val) {
      return [[XTToken alloc] initWithType:ty value:val location:loc];
    };
    NSString* op = self.parScanOp;
    XTTokenType ot = [op isEqualToString:@"+"] ? XTTokenPlus : [op isEqualToString:@"|"] ? XTTokenPipe
                   : [op isEqualToString:@"&"] ? XTTokenAmpersand : [op isEqualToString:@"^"] ? XTTokenCaret : XTTokenIdentifier;
    NSArray* head = @[ T(XTTokenIdentifier, @"par"), T(XTTokenColon, @":"), T(XTTokenIdentifier, @"scan"), T(XTTokenLParen, @"("),
                       T(ot, op), T(XTTokenIdentifier, self.parScanAcc), T(XTTokenRParen, @")"), T(XTTokenLBrace, @"{") ];
    NSMutableArray<XTToken*>* spliced = [_tokens mutableCopy];
    [spliced insertObject:T(XTTokenRBrace, @"}") atIndex:plainEnd];
    [spliced insertObjects:head atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(forPos, head.count)]];
    _tokens = spliced;
    _pos = forPos;
    self.scanQuiet = YES;
    BOOL ok = [self parScanRewrite];
    self.scanQuiet = NO;
    self.parScanAcc = nil;
    if (ok)
        {
        self.scanInside++;
        XTASTNode* s = [self parseStatement];
        self.scanInside--;
        if (s && _diagnostics.errorCount == errMark)
            return s;
        }
    _tokens = saved;
    [_diagnostics truncateToCount:diagMark];
    _pos = plainEnd;
    return plain;
    }

- (BOOL)parAutoScan:(NSMutableArray<NSArray<NSString*>*>*)reds goal:(NSUInteger*)goalOut
    {
    NSUInteger at = _pos;
    NSUInteger n = _tokens.count;
    *goalOut = self.goalNow ?: self.goalDefault;
    self.parScanAcc = nil;
    self.parScanOp = nil;
    self.parAutoWhy = nil;
    self.parAutoForm = @"for";
    self.parAutoGridCap = 3;
    self.pacSeen = 0;
    self.pacVal = 0;
    if ([self parTokType:at + 1] != XTTokenLParen)
        return [self parAutoNo:@"header"];
    // Not in the standard library or the prelude: a loop of the par runtime
    // itself, wrapped and demoted, called the runtime from inside the runtime.
    NSString* file = [self currentToken].location.filename;
    if (file && [self.libraryFiles containsObject:file])
        return [self parAutoNo:@"library"];
    // The header: `( T? i in a .. b )` or `( T? i in a ... b )`, with a
    // positive literal `step` or none (the desugaring counts a stride's
    // iterations from 0); or the C-style `( T i = a; i < b; i++ )` with
    // `<=`, `++i`, `i += 1` or `i = i + 1` as well (what the desugaring takes
    // as a step).
    NSUInteger depth = 0;
    NSUInteger pe = 0;
    BOOL sawIn = NO;
    BOOL sawDots = NO;
    NSString* var = nil;
    NSUInteger semi1 = 0;
    NSUInteger semi2 = 0;
    for (NSUInteger i = at + 1; i < n; i++)
        {
        XTTokenType ty = [self parTokType:i];
        if (ty == XTTokenLParen || ty == XTTokenLBracket)
            depth++;
        else if (ty == XTTokenRParen || ty == XTTokenRBracket)
            {
            depth--;
            if (depth == 0)
                {
                pe = i;
                break;
                }
            }
        else if (depth == 1)
            {
            if (ty == XTTokenIn && [self parTokType:i - 1] == XTTokenIdentifier)
                {
                sawIn = YES;
                var = [self parTokValue:i - 1];
                }
            else if (ty == XTTokenDotDot || ty == XTTokenEllipsis)
                sawDots = YES;
            else if (ty == XTTokenIdentifier && sawDots && [[self parTokValue:i] isEqualToString:@"step"] &&
                     ([self parTokType:i + 1] != XTTokenIntLiteral || [[self parTokValue:i + 1] isEqualToString:@"0"]))
                {
                [self pacNote:XTSrcStepBad value:YES];
                return [self parAutoNo:@"step"];
                }
            else if (ty == XTTokenSemicolon)
                {
                if (semi1 == 0) semi1 = i;
                else if (semi2 == 0) semi2 = i;
                else return [self parAutoNo:@"header"];
                }
            }
        }
    if (pe == 0)
        return [self parAutoNo:@"header"];
    [self pacNote:XTSrcRange value:sawIn && sawDots];
    [self pacNote:XTSrcStepBad value:NO];
    if (sawIn)
        self.parAutoForm = @"range";
    // The bound the loop as written reads before each iteration: after the
    // `<` or `<=`, or after the `..` or `...` up to a `step`. Mirrored in the port.
    NSUInteger bndFrom = 0, bndTo = 0;
    if (!sawIn)
        {
        // C-style: `T i = a` ; `i < b` or `i <= b` ; the step.
        if (semi1 == 0 || semi2 == 0 || semi1 < at + 3 || [self parTokType:semi1 - 1] == XTTokenAssign)
            return [self parAutoNo:@"header"];
        NSUInteger eq = 0;
        for (NSUInteger i = at + 2; i < semi1; i++)
            if ([self parTokType:i] == XTTokenAssign) { eq = i; break; }
        if (eq == 0 || [self parTokType:eq - 1] != XTTokenIdentifier)
            return [self parAutoNo:@"header"];
        // The loop must declare its variable (`T i = a`): a block's work
        // item gets its own, and `for (i = 0; …)` on an outer `i` left the
        // block with none (both compilers refused the program).
        if (eq < at + 4)
            return [self parAutoNo:@"outer-variable"];
        var = [self parTokValue:eq - 1];
        BOOL condOk = [self parTokType:semi1 + 1] == XTTokenIdentifier && [[self parTokValue:semi1 + 1] isEqualToString:var] &&
                      ([self parTokType:semi1 + 2] == XTTokenLess || [self parTokType:semi1 + 2] == XTTokenLessEq);
        [self pacNote:XTSrcChkCond value:condOk];
        if (!condOk)
            return [self parAutoNo:@"condition"];
        bndFrom = semi1 + 3;
        bndTo = semi2;
        NSUInteger s = semi2 + 1;
        BOOL stepOk = NO;
        if ([self parTokType:s] == XTTokenIdentifier && [[self parTokValue:s] isEqualToString:var])
            {
            if ([self parTokType:s + 1] == XTTokenPlusPlus && s + 2 == pe)
                stepOk = YES;
            else if ([self parTokType:s + 1] == XTTokenPlusAssign && [self parTokType:s + 2] == XTTokenIntLiteral &&
                     [[self parTokValue:s + 2] isEqualToString:@"1"] && s + 3 == pe)
                stepOk = YES;
            else if ([self parTokType:s + 1] == XTTokenAssign && [self parTokType:s + 2] == XTTokenIdentifier &&
                     [[self parTokValue:s + 2] isEqualToString:var] && [self parTokType:s + 3] == XTTokenPlus &&
                     [self parTokType:s + 4] == XTTokenIntLiteral && [[self parTokValue:s + 4] isEqualToString:@"1"] && s + 5 == pe)
                stepOk = YES;
            }
        else if ([self parTokType:s] == XTTokenPlusPlus && [self parTokType:s + 1] == XTTokenIdentifier &&
                 [[self parTokValue:s + 1] isEqualToString:var] && s + 2 == pe)
            stepOk = YES;
        [self pacNote:XTSrcChkStep value:stepOk];
        if (!stepOk)
            return [self parAutoNo:@"step"];
        }
    else if (!sawDots || !var || semi1 != 0)
        return [self parAutoNo:@"header"];
    else
        {
        NSUInteger d = 0;
        for (NSUInteger i = at + 1; i < pe; i++)
            {
            XTTokenType ty = [self parTokType:i];
            if (ty == XTTokenLParen || ty == XTTokenLBracket)
                d++;
            else if (ty == XTTokenRParen || ty == XTTokenRBracket)
                d--;
            else if (d == 1 && bndFrom == 0 && (ty == XTTokenDotDot || ty == XTTokenEllipsis))
                bndFrom = i + 1;
            else if (d == 1 && bndFrom != 0 && bndTo == 0 && ty == XTTokenIdentifier && [[self parTokValue:i] isEqualToString:@"step"])
                bndTo = i;
            }
        if (bndTo == 0)
            bndTo = pe;
        }
    // `in 10..0`: a range whose literal bounds descend counts down, and a
    // block's range ascends. Mirrored in the port.
    for (NSUInteger i = at + 2; sawIn && i + 1 < pe; i++)
        if (([self parTokType:i] == XTTokenDotDot || [self parTokType:i] == XTTokenEllipsis)
            && [self parTokType:i - 1] == XTTokenIntLiteral && [self parTokType:i - 2] == XTTokenIn
            && [self parTokType:i + 1] == XTTokenIntLiteral)
            {
            unsigned long long a0 = parLiteralValue([self parTokValue:i - 1]);
            unsigned long long b0 = parLiteralValue([self parTokValue:i + 1]);
            if (a0 > b0)
                {
                [self pacNote:XTSrcDesc value:YES];
                return [self parAutoNo:@"descending"];
                }
            }
    if (sawIn)
        [self pacNote:XTSrcDesc value:NO];
    // The loop's annotations, `: a, goal(speed), …` after the header: `serial`
    // keeps the loop as it is, and a `goal` is the block's goal, over the
    // unit's default.
    BOOL sawGoal = NO;
    if ([self parTokType:pe + 1] == XTTokenColon)
        {
        NSUInteger i = pe + 2;
        while ([self parTokType:i] == XTTokenIdentifier)
            {
            NSString* an = [self parTokValue:i];
            if ([an isEqualToString:@"serial"])
                {
                [self pacNote:XTSrcSerial value:YES];
                return [self parAutoNo:@"serial"];
                }
            if ([an isEqualToString:@"goal"])
                sawGoal = YES;
            if ([an isEqualToString:@"goal"] && [self parTokType:i + 1] == XTTokenLParen &&
                [self parTokType:i + 2] == XTTokenIdentifier && [self parTokType:i + 3] == XTTokenRParen)
                {
                *goalOut = [[self parTokValue:i + 2] isEqualToString:@"speed"] ? 1 : 2;
                i += 4;
                }
            else
                i++;
            if ([self parTokType:i] != XTTokenComma)
                break;
            i++;
            }
        pe = i - 1;
        }
    [self pacNote:XTSrcSerial value:NO];
    [self pacNote:XTSrcGoal value:sawGoal];
    return [self parAutoScanBodyAfter:pe var:var boundFrom:bndFrom to:bndTo reds:reds goal:goalOut];
    }

// The body of the loop whose header ends at token pe, for parAutoScan, and
// for the recogniser on the tokens its walk rebuilt (XTParser+ParLift.m):
// the body's tokens, its names and their uses, its reductions, and the
// tests of #415 and #416 against the bound [bndFrom, bndTo). Mirrored in
// the port.
- (BOOL)parAutoScanBodyAfter:(NSUInteger)pe
                         var:(NSString*)var
                   boundFrom:(NSUInteger)bndFrom
                          to:(NSUInteger)bndTo
                        reds:(NSMutableArray<NSArray<NSString*>*>*)reds
                        goal:(NSUInteger*)goalOut
    {
    NSUInteger n = _tokens.count;
    // The body: a block, to its `}`; or one plain statement, to its `;` (a
    // bare `if`, loop or switch as the body is left alone).
    NSUInteger bs = 0;
    NSUInteger be = 0;
    NSUInteger depth = 0;
    if ([self parTokType:pe + 1] == XTTokenLBrace)
        {
        bs = pe + 2;
        for (NSUInteger i = pe + 1; i < n; i++)
            {
            XTTokenType ty = [self parTokType:i];
            if (ty == XTTokenLBrace)
                depth++;
            else if (ty == XTTokenRBrace)
                {
                depth--;
                if (depth == 0)
                    {
                    be = i;
                    break;
                    }
                }
            }
        }
    else
        {
        // One statement, to its end: `if (…) S [else S]`, `for (…) S`,
        // `while (…) S` and `switch (…) {…}` as well as `…;` (from 0.8.1).
        XTTokenType first = [self parTokType:pe + 1];
        if (first == XTTokenSemicolon || first == XTTokenEOF)
            return [self parAutoNo:@"body"];
        bs = pe + 1;
        NSUInteger end = [self parAutoStatementEnd:pe + 1 limit:n];
        if (end == 0)
            return [self parAutoNo:@"body"];
        be = end;
        }
    if (be == 0)
        return [self parAutoNo:@"body"];
    // A body that reads its function's variadic arguments (va_arg_…, va_start,
    // va_end) stays where it is: a block's body runs in a frame of its own,
    // where the function's va_list is not. Even a demoted block runs there,
    // and a varargs loop crashed. Mirrored in the port.
    for (NSUInteger t = bs; t < be; t++)
        if ([self parTokType:t] == XTTokenIdentifier && [[self parTokValue:t] hasPrefix:@"va_"])
            return [self parAutoNo:@"varargs"];
    NSMutableSet<NSString*>* declared = [NSMutableSet setWithObject:var];
    NSMutableDictionary<NSString*, NSString*>* accOps = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* accWant = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* uses = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSString*>* arrOps = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* arrWant = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* arrNames = [NSMutableArray array];
    NSMutableArray<NSNumber*>* innerAt = [NSMutableArray array];
    BOOL pendingInner = NO;
    NSUInteger bd = 0;
    NSUInteger pd = 0;
    for (NSUInteger i = bs; i < be; i++)
        {
        XTTokenType ty = [self parTokType:i];
        XTTokenType prev = [self parTokType:i - 1];
        BOOL stmtStart = prev == XTTokenSemicolon || prev == XTTokenLBrace || prev == XTTokenRBrace ||
                         prev == XTTokenRParen || prev == XTTokenElse;
        if (ty == XTTokenLBrace)
            {
            bd++;
            if (pendingInner)
                {
                [innerAt addObject:@(bd)];
                pendingInner = NO;
                }
            continue;
            }
        if (ty == XTTokenRBrace)
            {
            if (innerAt.count && innerAt.lastObject.unsignedIntegerValue == bd)
                [innerAt removeLastObject];
            bd--;
            continue;
            }
        if (ty == XTTokenLParen || ty == XTTokenLBracket)
            pd++;
        if (ty == XTTokenRParen || ty == XTTokenRBracket)
            pd--;
        if (ty == XTTokenFor || ty == XTTokenWhile || ty == XTTokenSwitch)
            pendingInner = YES;
        if (ty == XTTokenReturn)
            return [self parAutoNo:@"return"];
        if (ty == XTTokenGoto)
            return [self parAutoNo:@"goto"];
        if (ty == XTTokenBreak && innerAt.count == 0)
            return [self parAutoNo:@"break"];
        // A declaration: its declarators are the body's own names.
        BOOL declStart = stmtStart || (prev == XTTokenLParen && [self parTokType:i - 2] == XTTokenFor);
        if ((declStart && ty != XTTokenIdentifier) ||
            (declStart && ty == XTTokenIdentifier && [_typeTable isTypeName:[self parTokValue:i]]))
            {
            // On the tokens the recogniser's walk rebuilt, the declarators
            // its declaration statement names (plDecls).
            NSArray<NSString*>* walked = self.plStream ? self.plDecls[@(i)] : nil;
            if (walked && (((XTToken*)_tokens[i]).isTypeKeyword || [_typeTable isTypeName:[self parTokValue:i]]))
                [declared addObjectsFromArray:walked];
            NSUInteger save = _pos;
            _pos = i;
            if (!self.plStream && ([self currentToken].isTypeKeyword || [_typeTable isTypeName:[self currentToken].value]))
                {
                [self parseTypeListLookahead];
                NSUInteger j = _pos;
                while (j < be && [self parTokType:j] == XTTokenIdentifier)
                    {
                    [declared addObject:[self parTokValue:j]];
                    // To the next declarator after a top-level comma, or stop.
                    NSUInteger d2 = 0;
                    while (j < be && !(d2 == 0 && ([self parTokType:j] == XTTokenComma || [self parTokType:j] == XTTokenSemicolon)))
                        {
                        XTTokenType tj = [self parTokType:j];
                        if (tj == XTTokenLParen || tj == XTTokenLBracket || tj == XTTokenLBrace)
                            d2++;
                        if (tj == XTTokenRParen || tj == XTTokenRBracket || tj == XTTokenRBrace)
                            d2--;
                        j++;
                        }
                    if ([self parTokType:j] != XTTokenComma)
                        break;
                    j++;
                    }
                }
            _pos = save;
            }
        if (ty != XTTokenIdentifier)
            continue;
        NSString* name = [self parTokValue:i];
        uses[name] = @([uses[name] unsignedIntegerValue] + 1);
        XTTokenType next = [self parTokType:i + 1];
        if (next == XTTokenIn)
            {
            [declared addObject:name];
            continue;
            }
        if (stmtStart && next == XTTokenColon)
            return [self parAutoNo:@"label"];
        BOOL own = [declared containsObject:name];
        if (prev == XTTokenAmpersand && next != XTTokenLBracket && !own)
            return [self parAutoNo:@"address"];
        // `acc++;` as a statement of its own: a `+` reduction (from 0.8.1).
        if (stmtStart && next == XTTokenPlusPlus && [self parTokType:i + 2] == XTTokenSemicolon && !own &&
            ![name isEqualToString:var] && !accOps[name])
            {
            accOps[name] = @"+";
            accWant[name] = @1;
            [names addObject:name];
            continue;
            }
        if ((next == XTTokenPlusPlus || next == XTTokenMinusMinus || prev == XTTokenPlusPlus || prev == XTTokenMinusMinus) && !own)
            return [self parAutoNo:@"outer-step"];
        // `h[k] op= e`, `h[k]++` or `h[k] = h[k] op e`, op one of + | & ^, on
        // an outer name: an array reduction (:reduce(op h[])) when every use
        // of h in the loop is such an update with the one op, and h is an
        // array of integers of a size known when the program is built (both
        // checked after the walk). Mirrored in the port.
        if (stmtStart && next == XTTokenLBracket && !own && ![name isEqualToString:var])
            {
            NSUInteger want = 0;
            NSString* sym = [self parAutoArrUpdateAt:i limit:be name:name want:&want];
            if (sym)
                {
                NSString* had = arrOps[name];
                if (!had)
                    {
                    arrOps[name] = sym;
                    [arrNames addObject:name];
                    }
                else if (![had isEqualToString:sym])
                    arrOps[name] = @"?";
                arrWant[name] = @([arrWant[name] unsignedIntegerValue] + want);
                }
            continue;
            }
        if (stmtStart && parAutoAnyAssignOp(next))
            {
            if ([name isEqualToString:var])
                return [self parAutoNo:@"iv-write"];
            if (own)
                continue;
            if (accOps[name])
                return [self parAutoNo:@"outer-write"];
            NSString* sym = nil;
            NSUInteger want = 1;
            if (next == XTTokenPlusAssign) sym = @"+";
            else if (next == XTTokenStarAssign) sym = @"*";
            else if (next == XTTokenAmpAssign) sym = @"&";
            else if (next == XTTokenPipeAssign) sym = @"|";
            else if (next == XTTokenCaretAssign) sym = @"^";
            else if (next == XTTokenAssign && [self parTokType:i + 2] == XTTokenIdentifier && [[self parTokValue:i + 2] isEqualToString:name])
                {
                XTTokenType o = [self parTokType:i + 3];
                if (o == XTTokenPlus) sym = @"+";
                else if (o == XTTokenStar) sym = @"*";
                else if (o == XTTokenAmpersand) sym = @"&";
                else if (o == XTTokenPipe) sym = @"|";
                else if (o == XTTokenCaret) sym = @"^";
                // `acc = acc op e` only when op joins all of e: in
                // `h = h * C + x` the + binds outside the *, and the
                // iterations depend on each other (a Horner hash came out 0
                // under --par-style=auto, par_gpu_wide, 2026-10-17).
                if (sym && ![self parAutoTailFrom:i + 4 limit:be isOp:o again:YES]) sym = nil;
                want = 2;
                }
            // `if (x < acc) acc = x;`: a min (or max) reduction (from 0.8.1).
            if (!sym && next == XTTokenAssign)
                {
                sym = [self parAutoMinMaxAt:i name:name limit:be];
                want = 2;
                }
            if (!sym)
                return [self parAutoNo:@"outer-write"];
            accOps[name] = sym;
            accWant[name] = @(want);
            [names addObject:name];
            continue;
            }
        if (stmtStart && (next == XTTokenDot || next == XTTokenArrow) && !own)
            {
            // A member written through an outer name.
            NSUInteger d2 = 0;
            for (NSUInteger j = i + 1; j < be; j++)
                {
                XTTokenType tj = [self parTokType:j];
                if (tj == XTTokenLParen || tj == XTTokenLBracket)
                    d2++;
                if (tj == XTTokenRParen || tj == XTTokenRBracket)
                    d2--;
                if (d2 == 0 && tj == XTTokenSemicolon)
                    break;
                if (d2 == 0 && parAutoAnyAssignOp(tj))
                    return [self parAutoNo:@"member-write"];
                }
            }
        }
    for (NSString* acc in names)
        {
        // A local of an integer type: a float reduction reassociates (not the
        // default), and a global is not a reduction.
        NSUInteger depth2 = 0;
        NSDictionary* info = [self blkLookup:acc depth:&depth2];
        XTType* ty = info[@"type"];
        if (![ty isKindOfClass:[XTType class]])
            return [self parAutoNo:@"reduction-type"];
        XTTypeKind k = ty.kind;
        BOOL isInt = k == XTTypeKindU8 || k == XTTypeKindI8 || k == XTTypeKindU16 || k == XTTypeKindI16 ||
                     k == XTTypeKindU32 || k == XTTypeKindI32 || k == XTTypeKindU64 || k == XTTypeKindI64;
        // A float reduction only under an EXPLICIT speed goal (the unit's, or
        // the loop's): its sum reassociates across the items, and + is its
        // only shape.
        BOOL isFloat = (k == XTTypeKindFloat || k == XTTypeKindDouble) && *goalOut == 1 &&
                       [accOps[acc] isEqualToString:@"+"];
        if (!isInt && !isFloat)
            return [self parAutoNo:@"reduction-type"];
        NSNumber* want = accWant[acc];
        NSNumber* have = uses[acc];
        if (!have || !want)
            return [self parAutoNo:@"reduction-uses"];
        if (have.unsignedIntegerValue != want.unsignedIntegerValue)
            {
            // A running total (#144): the other uses are stores `X[i] = acc;`,
            // X an outer array used for nothing else. The loop becomes a
            // :scan, alone (no other reduction with it). Mirrored in the port.
            NSString* op = accOps[acc];
            if (self.scanInside || self.parScanAcc || [op isEqualToString:@"*"])
                return [self parAutoNo:@"reduction-uses"];
            NSUInteger stores = [self parAutoScanStoresFrom:bs to:be acc:acc var:var uses:uses declared:declared];
            if (stores == 0 || have.unsignedIntegerValue != want.unsignedIntegerValue + stores)
                return [self parAutoNo:@"reduction-uses"];
            self.parScanAcc = acc;
            self.parScanOp = op;
            continue;
            }
        [reds addObject:@[ accOps[acc], acc ]];
        }
    if (self.parScanAcc && (names.count != 1 || arrNames.count != 0))
        {
        self.parScanAcc = nil;
        return [self parAutoNo:@"scan-alone"];
        }
    // The array reductions, after the scalar ones. An array that fails a test
    // is no reduction, and the loop goes on as it would without one.
    for (NSString* h in arrNames)
        {
        NSString* sym = arrOps[h];
        NSNumber* want = arrWant[h];
        NSNumber* have = uses[h];
        if (!have || !want || have.unsignedIntegerValue != want.unsignedIntegerValue)
            continue;
        NSUInteger depth2 = 0;
        NSDictionary* info = [self blkLookup:h depth:&depth2];
        XTType* ty = info[@"type"];
        if (![ty isKindOfClass:[XTType class]])
            ty = self.blkState[@"topVars"][h];
        if (![self parArrReducible:ty op:sym])
            continue;
        [reds addObject:@[ sym, h, @"[]" ]];
        }
    // A loop that qualifies so far, but whose body writes its variable (#415)
    // or changes what its bound reads (#416), stays a loop. Mirrored in the port.
    if ([self parAutoIVWrittenFrom:bs to:be var:var])
        {
        [self parAutoWarnSerial:[NSString stringWithFormat:@"its body writes its loop variable '%@'", var]];
        self.parScanAcc = nil;
        return [self parAutoNo:@"iv-write"];
        }
    NSString* bw = [self parAutoBoundFrom:bndFrom to:bndTo writtenFrom:bs to:be var:var];
    if (bw)
        {
        [self parAutoWarnSerial:bw];
        self.parScanAcc = nil;
        return NO;
        }
    // A perfect nest's inner levels, for parAutoGridNest.
    self.parAutoGridCap = [self parAutoGridCapFrom:bs to:be level:2];
    return YES;
    }

// For a running total in [bs, be): the stores `X[var] = acc;` at a
// statement's start, X an outer name whose every use is such a store; their
// number, else 0. Mirrored in the port (parAutoScanStores).
- (NSUInteger)parAutoScanStoresFrom:(NSUInteger)bs to:(NSUInteger)be acc:(NSString*)acc var:(NSString*)var
                               uses:(NSDictionary<NSString*, NSNumber*>*)uses declared:(NSSet<NSString*>*)declared
    {
    NSMutableDictionary<NSString*, NSNumber*>* per = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    NSUInteger total = 0;
    for (NSUInteger i = bs; i < be; i++)
        {
        if ([self parTokType:i] != XTTokenIdentifier || ![[self parTokValue:i] isEqualToString:acc])
            continue;
        XTTokenType pv = [self parTokType:i - 1];
        if (pv == XTTokenDot || pv == XTTokenArrow)
            continue;
        if (i < bs + 5 || pv != XTTokenAssign || [self parTokType:i - 2] != XTTokenRBracket ||
            [self parTokType:i - 3] != XTTokenIdentifier || ![[self parTokValue:i - 3] isEqualToString:var] ||
            [self parTokType:i - 4] != XTTokenLBracket || [self parTokType:i - 5] != XTTokenIdentifier ||
            [self parTokType:i + 1] != XTTokenSemicolon)
            continue;
        XTTokenType st = [self parTokType:i - 6];
        if (i - 5 != bs && st != XTTokenSemicolon && st != XTTokenLBrace && st != XTTokenRBrace)
            continue;
        NSString* x = [self parTokValue:i - 5];
        if ([x isEqualToString:acc] || [x isEqualToString:var] || [declared containsObject:x])
            return 0;
        if (!per[x])
            [order addObject:x];
        per[x] = @(per[x].unsignedIntegerValue + 1);
        total++;
        }
    for (NSString* x in order)
        if (!uses[x] || uses[x].unsignedIntegerValue != per[x].unsignedIntegerValue)
            return 0;
    return total;
    }

// At token i, a name followed by `[` at a statement's start: the operator of
// `h[k] op= e` (op one of + | & ^), of `h[k]++;` (+), or of `h[k] = h[k] op e`
// with the same index token for token and op binding all of e, else nil.
// *wantOut is the uses of h the statement makes. Mirrored in the port
// (parAutoArrUpdate).
- (nullable NSString*)parAutoArrUpdateAt:(NSUInteger)i limit:(NSUInteger)be name:(NSString*)name want:(NSUInteger*)wantOut
    {
    NSUInteger d = 0;
    NSUInteger rb = 0;
    for (NSUInteger j = i + 1; j < be; j++)
        {
        XTTokenType t = [self parTokType:j];
        if (t == XTTokenLBracket || t == XTTokenLParen)
            d++;
        else if (t == XTTokenRBracket || t == XTTokenRParen)
            {
            d--;
            if (d == 0)
                {
                rb = j;
                break;
                }
            }
        }
    if (rb == 0)
        return nil;
    XTTokenType t = [self parTokType:rb + 1];
    *wantOut = 1;
    if (t == XTTokenPlusAssign) return @"+";
    if (t == XTTokenPipeAssign) return @"|";
    if (t == XTTokenAmpAssign) return @"&";
    if (t == XTTokenCaretAssign) return @"^";
    if (t == XTTokenPlusPlus && [self parTokType:rb + 2] == XTTokenSemicolon) return @"+";
    if (t != XTTokenAssign || [self parTokType:rb + 2] != XTTokenIdentifier || ![[self parTokValue:rb + 2] isEqualToString:name])
        return nil;
    // The same index on the right, token for token, with no call or member
    // in it (the parser compares the two as trees, parSameIndex).
    NSUInteger at = rb + 2;
    for (NSUInteger q = 1; q <= rb - i; q++)
        {
        XTTokenType ta = [self parTokType:i + q];
        if (ta != [self parTokType:at + q] || ![[self parTokValue:i + q] isEqualToString:[self parTokValue:at + q]])
            return nil;
        if (ta == XTTokenDot || ta == XTTokenArrow)
            return nil;
        if (ta == XTTokenIdentifier && [self parTokType:i + q + 1] == XTTokenLParen)
            return nil;
        }
    NSUInteger o = at + (rb - i) + 1;
    XTTokenType ot = [self parTokType:o];
    NSString* sym = ot == XTTokenPlus ? @"+" : ot == XTTokenPipe ? @"|" : ot == XTTokenAmpersand ? @"&"
                    : ot == XTTokenCaret ? @"^" : nil;
    if (!sym || ![self parAutoTailFrom:o + 1 limit:be isOp:ot again:NO])
        return nil;
    *wantOut = 2;
    return sym;
    }

// At `acc = E;` (the cursor's token i is acc, at a statement's start): "min"
// or "max" when the statement is the whole body of `if (E cmp acc)` or
// `if (acc cmp E)` with the same E, token for token, and no else, else nil.
// `E < acc` keeps the smaller, a min; `E > acc` the larger; reversed when
// acc is on the left. Mirrored in the port (parAutoMinMax).
/****************************************************************************\
|* Whether the statement's tail, from token `from` to its `;`, is one operand
|* of `op`: every binary operator at its top level is `op` or binds more
|* tightly (unary ones, after an operator or an opening bracket, do not
|* count). `acc = acc op e` is a reduction only then. Without `again`, `op`
|* itself ends the operand too: `h[k] = h[k] + a + b` adds to h[k] + a.
\****************************************************************************/
static BOOL parAutoIsBinOp(XTTokenType t)
    {
    return t == XTTokenPlus || t == XTTokenMinus || t == XTTokenStar || t == XTTokenSlash || t == XTTokenPercent || t == XTTokenShiftLeft || t == XTTokenShiftRight || t == XTTokenLess || t == XTTokenLessEq || t == XTTokenGreater || t == XTTokenGreaterEq || t == XTTokenEqual || t == XTTokenNotEqual || t == XTTokenAmpersand || t == XTTokenPipe || t == XTTokenCaret || t == XTTokenLogicalAnd || t == XTTokenLogicalOr || t == XTTokenQuestion;
    }

// C's binary-operator precedence, higher binding more tightly.
static NSUInteger parAutoPrec(XTTokenType t)
    {
    if (t == XTTokenStar || t == XTTokenSlash || t == XTTokenPercent) return 10;
    if (t == XTTokenPlus || t == XTTokenMinus) return 9;
    if (t == XTTokenShiftLeft || t == XTTokenShiftRight) return 8;
    if (t == XTTokenLess || t == XTTokenLessEq || t == XTTokenGreater || t == XTTokenGreaterEq) return 7;
    if (t == XTTokenEqual || t == XTTokenNotEqual) return 6;
    if (t == XTTokenAmpersand) return 5;
    if (t == XTTokenCaret) return 4;
    if (t == XTTokenPipe) return 3;
    if (t == XTTokenLogicalAnd) return 2;
    if (t == XTTokenLogicalOr) return 1;
    if (t == XTTokenQuestion) return 0;
    return 0;
    }

- (BOOL)parAutoTailFrom:(NSUInteger)from limit:(NSUInteger)be isOp:(XTTokenType)op again:(BOOL)again
    {
    NSUInteger depth = 0;
    for (NSUInteger j = from; j < be; j++)
        {
        XTTokenType t = [self parTokType:j];
        if (t == XTTokenLParen || t == XTTokenLBracket || t == XTTokenLBrace)
            {
            depth++;
            continue;
            }
        if (t == XTTokenRParen || t == XTTokenRBracket || t == XTTokenRBrace)
            {
            if (depth == 0)
                return YES;
            depth--;
            continue;
            }
        if (depth > 0)
            continue;
        if (t == XTTokenSemicolon || t == XTTokenComma)
            return YES;
        if (!parAutoIsBinOp(t))
            continue;
        XTTokenType pt = j > from ? [self parTokType:j - 1] : XTTokenLParen;
        BOOL unary = j == from || pt == XTTokenLParen || pt == XTTokenLBracket || pt == XTTokenComma ||
                     pt == XTTokenAssign || parAutoIsBinOp(pt);
        if (unary)
            continue;
        // `op` again, or an operator that binds more tightly (part of the
        // operand): anything else takes `acc op …` as its own operand.
        if ((t != op || !again) && parAutoPrec(t) <= parAutoPrec(op))
            return NO;
        }
    return YES;
    }

- (nullable NSString*)parAutoMinMaxAt:(NSUInteger)i name:(NSString*)name limit:(NSUInteger)be
    {
    if (i < 4 || [self parTokType:i - 1] != XTTokenRParen)
        return nil;
    // The condition's parentheses.
    NSUInteger p = i - 1;
    NSInteger d = 0;
    while (p > 0)
        {
        XTTokenType t = [self parTokType:p];
        if (t == XTTokenRParen) d++;
        if (t == XTTokenLParen) d--;
        if (d == 0)
            break;
        p--;
        }
    if (d != 0 || p == 0 || [self parTokType:p - 1] != XTTokenIf)
        return nil;
    // The one comparison at depth 0 inside.
    NSUInteger cmp = 0;
    d = 0;
    for (NSUInteger j = p + 1; j < i - 1; j++)
        {
        XTTokenType t = [self parTokType:j];
        if (t == XTTokenLParen || t == XTTokenLBracket) d++;
        if (t == XTTokenRParen || t == XTTokenRBracket) d--;
        if (d == 0 && (t == XTTokenLess || t == XTTokenGreater || t == XTTokenLessEq || t == XTTokenGreaterEq))
            {
            if (cmp)
                return nil;
            cmp = j;
            }
        }
    if (!cmp)
        return nil;
    BOOL accLeft = cmp == p + 2 && [self parTokType:p + 1] == XTTokenIdentifier && [[self parTokValue:p + 1] isEqualToString:name];
    BOOL accRight = cmp + 2 == i - 1 && [self parTokType:cmp + 1] == XTTokenIdentifier && [[self parTokValue:cmp + 1] isEqualToString:name];
    if (accLeft == accRight)
        return nil;
    NSUInteger es = accLeft ? cmp + 1 : p + 1;
    NSUInteger ee = accLeft ? i - 1 : cmp;
    // The right-hand side: E again, to the statement's end.
    NSUInteger r = i + 2;
    for (NSUInteger j = es; j < ee; j++, r++)
        {
        if (r >= be || [self parTokType:r] != [self parTokType:j])
            return nil;   // (a bare body's range ends AT its semicolon, below)
        NSString* vj = [self parTokValue:j];
        NSString* vr = [self parTokValue:r];
        if ((vj.length || vr.length) && ![vj ?: @"" isEqualToString:vr ?: @""])
            return nil;
        }
    if (r > be || [self parTokType:r] != XTTokenSemicolon || [self parTokType:r + 1] == XTTokenElse)
        return nil;
    XTTokenType c = [self parTokType:cmp];
    BOOL less = c == XTTokenLess || c == XTTokenLessEq;
    return (less != accLeft) ? @"min" : @"max";
    }

// An expression made of literals, casts, arithmetic and names other than
// `avoid`: a bound of an inner loop that does not depend on the outer index.
static BOOL parAutoBoundFree(XTASTNode* e, NSString* avoid)
    {
    if ([e isKindOfClass:[XTLiteralIntNode class]])
        return YES;
    if ([e isKindOfClass:[XTIdentifierNode class]])
        return ![((XTIdentifierNode*)e).identName isEqualToString:avoid];
    if ([e isKindOfClass:[XTCastExprNode class]])
        return parAutoBoundFree(((XTCastExprNode*)e).operand, avoid);
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        return parAutoBoundFree(((XTBinaryExprNode*)e).left, avoid) && parAutoBoundFree(((XTBinaryExprNode*)e).right, avoid);
    return NO;
    }

// The parts of an ascending loop `for (T v = a; v < b | v <= b; v++)`, as the
// desugaring takes it (the range form desugars to this): nil when it is not one.
static XTForCStyleNode* _Nullable parAutoAscending(XTASTNode* node, XTVariableDeclNode* _Nonnull* _Nonnull ivOut,
                                                    XTBinaryExprNode* _Nonnull* _Nonnull condOut)
    {
    if (![node isKindOfClass:[XTForCStyleNode class]])
        return nil;
    XTForCStyleNode* loop = (XTForCStyleNode*)node;
    XTVariableDeclNode* iv = [loop.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)loop.loopInit : nil;
    XTBinaryExprNode* cond = [loop.condition isKindOfClass:[XTBinaryExprNode class]] ? (XTBinaryExprNode*)loop.condition : nil;
    if (!iv || !iv.initialiser || !iv.declaredType || !cond || (cond.op != XTBinaryOpLt && cond.op != XTBinaryOpLe) ||
        ![cond.left isKindOfClass:[XTIdentifierNode class]] ||
        ![((XTIdentifierNode*)cond.left).identName isEqualToString:iv.varName])
        return nil;
    XTASTNode* inc = loop.increment;
    BOOL stepOk = NO;
    if ([inc isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)inc;
        stepOk = a.assignOp == XTAssignOpAdd && [a.rhs isKindOfClass:[XTLiteralIntNode class]] &&
                 ((XTLiteralIntNode*)a.rhs).intValue == 1;
        if (!stepOk && a.assignOp == XTAssignOpAssign && [a.rhs isKindOfClass:[XTBinaryExprNode class]])
            {
            XTBinaryExprNode* b = (XTBinaryExprNode*)a.rhs;
            stepOk = b.op == XTBinaryOpAdd && [b.left isKindOfClass:[XTIdentifierNode class]] &&
                     [((XTIdentifierNode*)b.left).identName isEqualToString:iv.varName] &&
                     [b.right isKindOfClass:[XTLiteralIntNode class]] && ((XTLiteralIntNode*)b.right).intValue == 1;
            }
        }
    else if ([inc isKindOfClass:[XTPostfixExprNode class]])
        stepOk = ((XTPostfixExprNode*)inc).postfixOp == XTPostfixOpInc;
    else if ([inc isKindOfClass:[XTUnaryExprNode class]])
        stepOk = ((XTUnaryExprNode*)inc).op == XTUnaryOpPreInc;
    if (!stepOk)
        return nil;
    *ivOut = iv;
    *condOut = cond;
    return loop;
    }

// A perfect two-deep nest — the outer loop's body is one ascending inner loop
// whose bounds do not mention the outer index — as a grid block's body: the
// two indices declared from the point (`par$y` the outer, `par$x` the inner),
// then the inner body; the frame gets the grid's W and H, evaluated once at
// the site. nil when the loop is not such a nest. Mirrored in the port.
// `cap` is the grid levels the nest may take (parAutoGridCap).
- (nullable XTBlockNode*)parAutoGridNest:(XTASTNode*)node frame:(NSMutableDictionary*)frame at:(XTSourceLocation*)loc
                                     cap:(NSUInteger)cap
    {
    XTVariableDeclNode* iv1 = nil;
    XTBinaryExprNode* cond1 = nil;
    XTForCStyleNode* outer = cap >= 2 ? parAutoAscending(node, &iv1, &cond1) : nil;
    if (!outer)
        return nil;
    // The inner loop: the outer body's one statement, braced or not.
    XTASTNode* innerNode = outer.body;
    if ([innerNode isKindOfClass:[XTBlockNode class]])
        {
        if (((XTBlockNode*)innerNode).statements.count != 1)
            return nil;
        innerNode = ((XTBlockNode*)innerNode).statements[0];
        }
    XTVariableDeclNode* iv2 = nil;
    XTBinaryExprNode* cond2 = nil;
    XTForCStyleNode* inner = parAutoAscending(innerNode, &iv2, &cond2);
    if (!inner || !parAutoBoundFree(iv2.initialiser, iv1.varName) || !parAutoBoundFree(cond2.right, iv1.varName))
        return nil;
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
    XTASTNode* (^extent)(XTVariableDeclNode*, XTBinaryExprNode*) = ^XTASTNode*(XTVariableDeclNode* iv, XTBinaryExprNode* cond) {
      XTASTNode* n = bin(XTBinaryOpSub, cast(i64T, cond.right), cast(i64T, iv.initialiser));
      if (cond.op == XTBinaryOpLe)
          n = bin(XTBinaryOpAdd, n, [[XTLiteralIntNode alloc] initWithValue:1 location:loc]);
      return n;
    };
    // A perfect THREE-deep nest (the inner body one loop whose bounds use
    // neither outer index) is one 3-D grid: par$z the outer, par$y the
    // middle, par$x the inner.
    XTASTNode* thirdNode = inner.body;
    if ([thirdNode isKindOfClass:[XTBlockNode class]])
        thirdNode = ((XTBlockNode*)thirdNode).statements.count == 1 ? ((XTBlockNode*)thirdNode).statements[0] : nil;
    XTVariableDeclNode* iv3 = nil;
    XTBinaryExprNode* cond3 = nil;
    XTForCStyleNode* third = cap >= 3 && thirdNode ? parAutoAscending(thirdNode, &iv3, &cond3) : nil;
    if (third && !(parAutoBoundFree(iv3.initialiser, iv1.varName) && parAutoBoundFree(cond3.right, iv1.varName) &&
                   parAutoBoundFree(iv3.initialiser, iv2.varName) && parAutoBoundFree(cond3.right, iv2.varName)))
        third = nil;
    XTASTNode* (^decl)(XTVariableDeclNode*, NSString*) = ^XTASTNode*(XTVariableDeclNode* iv, NSString* coord) {
      return [[XTVariableDeclNode alloc] initWithName:iv.varName type:iv.declaredType
                                          initialiser:cast(iv.declaredType, bin(XTBinaryOpAdd, cast(iv.declaredType, iv.initialiser),
                                                                                  cast(iv.declaredType, ident(coord))))
                                             location:loc];
    };
    NSMutableArray<XTASTNode*>* st = [NSMutableArray array];
    XTASTNode* innermost = inner.body;
    if (third)
        {
        frame[@"grid"] = @[ extent(iv3, cond3), extent(iv2, cond2), extent(iv1, cond1) ];
        frame[@"gridUsed"] = [NSMutableSet setWithObjects:@"par$x", @"par$y", @"par$z", nil];
        [st addObject:decl(iv1, @"par$z")];
        [st addObject:decl(iv2, @"par$y")];
        [st addObject:decl(iv3, @"par$x")];
        innermost = third.body;
        }
    else
        {
        frame[@"grid"] = @[ extent(iv2, cond2), extent(iv1, cond1) ];
        frame[@"gridUsed"] = [NSMutableSet setWithObjects:@"par$x", @"par$y", nil];
        [st addObject:decl(iv1, @"par$y")];
        [st addObject:decl(iv2, @"par$x")];
        }
    if ([innermost isKindOfClass:[XTBlockNode class]])
        [st addObjectsFromArray:((XTBlockNode*)innermost).statements];
    else
        [st addObject:innermost];
    return [[XTBlockNode alloc] initWithStatements:st location:loc];
    }

/****************************************************************************\
|* --par-style=auto's `while` form: `while (v < B) { …; v++; }`, v a local of an
|* integer type, B names and integer literals only, the increment the body's
|* last statement and v written nowhere else, no break, continue, return or
|* goto. It is parsed as
|*     for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1)
|*         { T v = __autopar_w; …the body without the increment… }
|*     if (v < B) v = B;            (<= B: v = B + 1)
|* — the loop's own iterations with v's final value after it. YES when the
|* `while` at _pos has the shape; it notes where its parts are (pwAt…) for
|* parseAutoWhile and parAutoWhileToks. Mirrored in the port.
\****************************************************************************/
- (BOOL)parAutoWhileShape
    {
    NSUInteger at = _pos, n = _tokens.count;
    if ([self parTokType:at + 1] != XTTokenLParen || [self parTokType:at + 2] != XTTokenIdentifier)
        return NO;
    NSString* v = [self parTokValue:at + 2];
    XTTokenType cmp = [self parTokType:at + 3];
    if (cmp != XTTokenLess && cmp != XTTokenLessEq)
        return NO;
    // The bound: names, integer literals, + - * /, casts and parentheses,
    // up to the `)` that closes the condition.
    NSUInteger pe = at + 4, pd = 0;
    while (pe < n)
        {
        XTTokenType t = [self parTokType:pe];
        if (t == XTTokenRParen && pd == 0)
            break;
        if (t == XTTokenLParen)
            pd++;
        else if (t == XTTokenRParen)
            pd--;
        else if (t != XTTokenIdentifier && t != XTTokenIntLiteral && t != XTTokenPlus && t != XTTokenMinus &&
                 t != XTTokenStar && t != XTTokenSlash && !((XTToken*)_tokens[pe]).isTypeKeyword)
            return NO;
        if (t == XTTokenIdentifier && [[self parTokValue:pe] isEqualToString:v])
            return NO;
        pe++;
        }
    if (pe >= n || pe == at + 4 || [self parTokType:pe + 1] != XTTokenLBrace)
        return NO;
    NSUInteger be = 0, depth = 0;
    for (NSUInteger i = pe + 1; i < n; i++)
        {
        XTTokenType t = [self parTokType:i];
        if (t == XTTokenLBrace)
            depth++;
        else if (t == XTTokenRBrace && --depth == 0)
            {
            be = i;
            break;
            }
        }
    if (be == 0)
        return NO;
    // The increment, the last statement: `v++;`, `++v;`, `v += 1;` or `v = v + 1;`.
    NSUInteger inc = 0;
    if ([self parTokType:be - 1] != XTTokenSemicolon)
        return NO;
    if (be >= pe + 5 && [self parTokType:be - 3] == XTTokenIdentifier && [[self parTokValue:be - 3] isEqualToString:v] &&
        [self parTokType:be - 2] == XTTokenPlusPlus)
        inc = be - 3;
    else if (be >= pe + 5 && [self parTokType:be - 3] == XTTokenPlusPlus && [self parTokType:be - 2] == XTTokenIdentifier &&
             [[self parTokValue:be - 2] isEqualToString:v])
        inc = be - 3;
    else if (be >= pe + 6 && [self parTokType:be - 4] == XTTokenIdentifier && [[self parTokValue:be - 4] isEqualToString:v] &&
             [self parTokType:be - 3] == XTTokenPlusAssign && [self parTokType:be - 2] == XTTokenIntLiteral &&
             [[self parTokValue:be - 2] isEqualToString:@"1"])
        inc = be - 4;
    else if (be >= pe + 8 && [self parTokType:be - 6] == XTTokenIdentifier && [[self parTokValue:be - 6] isEqualToString:v] &&
             [self parTokType:be - 5] == XTTokenAssign && [self parTokType:be - 4] == XTTokenIdentifier &&
             [[self parTokValue:be - 4] isEqualToString:v] && [self parTokType:be - 3] == XTTokenPlus &&
             [self parTokType:be - 2] == XTTokenIntLiteral && [[self parTokValue:be - 2] isEqualToString:@"1"])
        inc = be - 6;
    if (inc == 0 || inc <= pe + 1)
        return NO;
    NSInteger incForm = inc == be - 3 ? ([self parTokType:inc] == XTTokenPlusPlus ? 2 : 1) : inc == be - 4 ? 3 : 4;
    // Before the increment's statement starts, the previous one ended.
    XTTokenType before = [self parTokType:inc - 1];
    if (before != XTTokenSemicolon && before != XTTokenRBrace && before != XTTokenLBrace)
        return NO;
    for (NSUInteger i = pe + 2; i < inc; i++)
        {
        XTTokenType t = [self parTokType:i];
        if (t == XTTokenBreak || t == XTTokenContinue || t == XTTokenReturn || t == XTTokenGoto)
            return NO;
        if (t == XTTokenIdentifier && [[self parTokValue:i] isEqualToString:v])
            {
            XTTokenType nx = [self parTokType:i + 1];
            XTTokenType pv = [self parTokType:i - 1];
            if (parAutoAnyAssignOp(nx) || nx == XTTokenPlusPlus || nx == XTTokenMinusMinus ||
                pv == XTTokenPlusPlus || pv == XTTokenMinusMinus || pv == XTTokenAmpersand)
                return NO;
            }
        }
    // #416: a bound the body changes. The `for` reads it once when it is a
    // block, and `v = B` after it would read the changed one. Mirrored in the port.
    NSString* bw = [self parAutoBoundFrom:at + 4 to:pe writtenFrom:pe + 2 to:inc var:v];
    if (bw)
        {
        [self parAutoWarnSerial:bw];
        return NO;
        }
    // v: a local of an integer type, spelt as its keyword. #463: a field
    // (the class scope's ivar binding) or a global (no binding) is not one:
    // the rewrite's fresh variable and its `v = B` after the loop hold for a
    // local only. Mirrored in the port.
    NSUInteger d = 0;
    NSDictionary* info = [self blkLookup:v depth:&d];
    if (!info || [info[@"ivar"] boolValue])
        {
        [self parAutoWarnSerial:[NSString stringWithFormat:@"its counter '%@' is not a local variable", v]];
        return NO;
        }
    XTType* vt = [info[@"type"] isKindOfClass:[XTType class]] ? info[@"type"] : nil;
    NSDictionary<NSString*, NSNumber*>* kw = @{ @"u8" : @(XTTokenU8), @"i8" : @(XTTokenI8), @"u16" : @(XTTokenU16),
                                                @"i16" : @(XTTokenI16), @"u32" : @(XTTokenU32), @"i32" : @(XTTokenI32),
                                                @"u64" : @(XTTokenU64), @"i64" : @(XTTokenI64) };
    NSNumber* tt = vt ? kw[vt.displayName] : nil;
    if (!tt)
        return NO;
    self.pwAt = at;
    self.pwPe = pe;
    self.pwBe = be;
    self.pwInc = inc;
    self.pwTt = tt.integerValue;
    self.pwVt = vt;
    self.pwV = v;
    self.plWhileInc = incForm;
    return YES;
    }

// The `for` parAutoWhileShape's loop amounts to, as tokens, for the token
// scan to read (parAutoScan) and for a running total's `par :scan` rewrite
// (parAutoScanFor):
//     for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1)
//         { T v = __autopar_w; …the body without the increment… }
// With `withIf`, the `if (v < B) v = B;` after it too. The parse builds the
// same as a tree (parseAutoWhile). Mirrored in the port.
- (NSArray<XTToken*>*)parAutoWhileToks:(BOOL)withIf
    {
    NSUInteger at = self.pwAt, pe = self.pwPe, inc = self.pwInc;
    NSString* v = self.pwV;
    XTType* vt = self.pwVt;
    XTTokenType tt = self.pwTt;
    XTTokenType cmp = [self parTokType:at + 3];
    XTSourceLocation* loc = ((XTToken*)_tokens[at]).location;
    NSString* w = @"__autopar_w";
    XTToken* (^T)(XTTokenType, NSString*) = ^XTToken*(XTTokenType ty, NSString* val) {
      return [[XTToken alloc] initWithType:ty value:val location:loc];
    };
    XTToken* (^I)(int64_t) = ^XTToken*(int64_t x) {
      return [[XTToken alloc] initWithType:XTTokenIntLiteral value:[NSString stringWithFormat:@"%lld", (long long)x]
                                  intValue:x location:loc];
    };
    NSArray* bound = [_tokens subarrayWithRange:NSMakeRange(at + 4, pe - (at + 4))];
    NSMutableArray* out = [NSMutableArray array];
    [out addObjectsFromArray:@[ T(XTTokenFor, @"for"), T(XTTokenLParen, @"("), T(tt, vt.displayName),
                                T(XTTokenIdentifier, w), T(XTTokenAssign, @"="), T(XTTokenIdentifier, v),
                                T(XTTokenSemicolon, @";"), T(XTTokenIdentifier, w), _tokens[at + 3] ]];
    [out addObjectsFromArray:bound];
    [out addObjectsFromArray:@[ T(XTTokenSemicolon, @";"), T(XTTokenIdentifier, w), T(XTTokenPlusAssign, @"+="), I(1),
                                T(XTTokenRParen, @")"), T(XTTokenLBrace, @"{"), T(tt, vt.displayName),
                                T(XTTokenIdentifier, v), T(XTTokenAssign, @"="), T(XTTokenIdentifier, w),
                                T(XTTokenSemicolon, @";") ]];
    [out addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(pe + 2, inc - (pe + 2))]];
    [out addObject:T(XTTokenRBrace, @"}")];
    if (!withIf)
        return out;
    [out addObjectsFromArray:@[ T(XTTokenIf, @"if"), T(XTTokenLParen, @"("), T(XTTokenIdentifier, v), _tokens[at + 3] ]];
    [out addObjectsFromArray:bound];
    [out addObjectsFromArray:@[ T(XTTokenRParen, @")"), T(XTTokenIdentifier, v), T(XTTokenAssign, @"=") ]];
    [out addObjectsFromArray:bound];
    if (cmp == XTTokenLessEq)
        [out addObjectsFromArray:@[ T(XTTokenPlus, @"+"), I(1) ]];
    [out addObject:T(XTTokenSemicolon, @";")];
    return out;
    }

// The token stream with the `while` at pwAt replaced by parAutoWhileToks:
// what the scan reads.
- (NSArray<XTToken*>*)parAutoWhileStream:(BOOL)withIf
    {
    NSMutableArray<XTToken*>* s = [_tokens mutableCopy];
    [s replaceObjectsInRange:NSMakeRange(self.pwAt, self.pwBe + 1 - self.pwAt) withObjectsFromArray:[self parAutoWhileToks:withIf]];
    return s;
    }

// A name read at a made token, as parsePrimary reads one.
- (XTIdentifierNode*)pwIdent:(NSString*)name at:(XTSourceLocation*)loc
    {
    [self blkNoteIdentifierUse:name at:loc];
    return [[XTIdentifierNode alloc] initWithName:name location:loc];
    }

// The literal 1 at a made token.
- (XTLiteralIntNode*)pwOneAt:(XTSourceLocation*)loc
    {
    XTLiteralIntNode* one = [[XTLiteralIntNode alloc] initWithValue:1 location:loc];
    one.srcFacts |= XTSrcPlain;
    return one;
    }

/****************************************************************************\
|* The `while` at _pos, which parAutoWhileShape took (`v`, `vt` its counter
|* and type, `incTok` and `incLen` its increment statement), parsed as the
|* `for` parAutoWhileToks spells: the nodes, locations and bindings that
|* `for`'s tokens give, the made parts at the `while`. The `if` after it
|* comes from the next statement of the block, or is put with it in a
|* block where the `while` was a lone statement (pwPending, parseStatement).
|* Mirrored in the port.
\****************************************************************************/
- (nullable XTASTNode*)parseAutoWhile:(NSString*)v type:(XTType*)vt inc:(XTToken*)incTok length:(NSUInteger)incLen
    {
    XTSourceLocation* loc = [self currentLocation];
    NSString* w = @"__autopar_w";
    [self advance]; // `while`
    [self expect:XTTokenLParen];
    [self advance]; // v
    XTType* t = [_typeTable scalarTypeForKeyword:vt.displayName] ?: [_typeTable typeForName:vt.displayName] ?: [XTType u8Type];
    // T __autopar_w = v;
    self.lastBlockDeclName = nil;
    _lastTypeIsOutlet = NO;
    XTASTNode* init = [[XTVariableDeclNode alloc] initWithName:w type:t initialiser:[self pwIdent:v at:loc] location:loc];
    [self blkPushScope];
    [self blkBind:w type:t];
    // __autopar_w < B
    XTASTNode* left = [self pwIdent:w at:loc];
    XTToken* op = [self advance];
    XTASTNode* right = [self parseExprWithMinPrec:[self rhsMinPrecAfter:op.type]];
    XTASTNode* cond = [self buildBinaryExpr:op left:left right:right];
    [self expect:XTTokenRParen];
    // __autopar_w += 1
    XTASTNode* incrLhs = [self pwIdent:w at:loc];
    XTASTNode* incr = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAdd lhs:incrLhs rhs:[self pwOneAt:loc] location:loc];
    NSUInteger goal = [self loopGoal:0];
    NSUInteger savedGoal = self.goalNow;
    self.goalNow = goal;
    // { T v = __autopar_w; …the body up to the increment… }
    [self advance]; // `{`
    [self blkPushScope];
    NSMutableArray<XTASTNode*>* stmts = [NSMutableArray array];
    self.lastTypeIsBlockWb = NO;
    self.lastBlockDeclName = nil;
    _lastTypeIsOutlet = NO;
    XTVariableDeclNode* decl = [[XTVariableDeclNode alloc] initWithName:v type:t initialiser:[self pwIdent:w at:loc] location:loc];
    decl.nameLocation = loc;
    decl.isOutlet = NO;
    [stmts addObject:decl];
    [self blkBind:v type:t];
    [self blkMarkHoldsWb:v fromInit:decl.initialiser];
    while ((self.pwPending || ([self currentToken] != incTok && ![self checkBlockClose] && ![self check:XTTokenEOF]))
           && !_diagnostics.hasFatalError)
        {
        XTASTNode* stmt = [self parseListStatement];
        if (stmt)
            [stmts addObject:stmt];
        }
    if ([self currentToken] == incTok)
        for (NSUInteger i = 0; i < incLen; i++)
            [self advance];
    [self expectBlockClose];
    [self blkPopScope];
    XTASTNode* body = [[XTBlockNode alloc] initWithStatements:stmts location:loc];
    self.goalNow = savedGoal;
    [self blkPopScope];
    XTForCStyleNode* node = [[XTForCStyleNode alloc] initWithLoopInit:init condition:cond increment:incr body:body location:loc];
    node.forceUnroll = NO;
    node.goal = goal;
    node.srcFacts |= [self parAutoLoopFacts:0];
    return node;
    }

/****************************************************************************\
|* The `if (v < B) v = B;` (`<= B`: `v = B + 1`) a counted `while` leaves
|* after its `for` (parseAutoWhile), with B read again from its own tokens:
|* the next statement of the block, or the second statement of the block
|* parseStatement makes for a lone `while`. Mirrored in the port.
\****************************************************************************/
- (nullable XTASTNode*)pwBound:(int)minPrec
    {
    NSArray<XTToken*>* savedToks = _tokens;
    NSUInteger savedPos = _pos;
    _tokens = self.pwPendBound;
    _pos = 0;
    XTASTNode* e = [self parseExprWithMinPrec:minPrec];
    _tokens = savedToks;
    _pos = savedPos;
    return e;
    }

- (nullable XTASTNode*)parAutoWhileIf
    {
    self.pwPending = NO;
    XTSourceLocation* loc = self.pwPendLoc;
    NSString* v = self.pwPendV;
    XTToken* cmp = self.pwPendCmp;
    XTASTNode* left = [self pwIdent:v at:loc];
    XTASTNode* right = [self pwBound:[self rhsMinPrecAfter:cmp.type]];
    XTASTNode* condition = [self buildBinaryExpr:cmp left:left right:right];
    XTASTNode* lhs = [self pwIdent:v at:loc];
    XTASTNode* rhs = [self pwBound:[self rhsMinPrecAfter:XTTokenAssign]];
    if (cmp.type == XTTokenLessEq)
        rhs = [[XTBinaryExprNode alloc] initWithOp:XTBinaryOpAdd left:rhs right:[self pwOneAt:loc] location:loc];
    if ([self blkIsWbValue:rhs])
        [self blkMarkHoldsWb:v fromInit:rhs];
    XTASTNode* assign = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign lhs:lhs rhs:rhs location:loc];
    XTASTNode* thenBlock = [[XTExpressionStatementNode alloc] initWithExpression:assign location:loc];
    return [[XTIfNode alloc] initWithCondition:condition thenBlock:thenBlock elseBlock:nil location:loc];
    }

// A constant bound (literals, casts, + - *): its value, or -1. As the port's
// parAutoConst, which folds as parFoldConstant does.
static int64_t parAutoFold(XTASTNode* e, BOOL* ok)
    {
    if ([e isKindOfClass:[XTLiteralIntNode class]])
        {
        *ok = YES;
        return ((XTLiteralIntNode*)e).intValue;
        }
    if ([e isKindOfClass:[XTCastExprNode class]])
        return parAutoFold(((XTCastExprNode*)e).operand, ok);
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)e;
        BOOL okl = NO, okr = NO;
        int64_t l = parAutoFold(b.left, &okl);
        int64_t r = parAutoFold(b.right, &okr);
        if (okl && okr && (b.op == XTBinaryOpAdd || b.op == XTBinaryOpSub || b.op == XTBinaryOpMul))
            {
            *ok = YES;
            return b.op == XTBinaryOpAdd ? l + r : b.op == XTBinaryOpSub ? l - r : l * r;
            }
        }
    *ok = NO;
    return 0;
    }
static int64_t parAutoConst(XTASTNode* e)
    {
    BOOL ok = NO;
    int64_t v = parAutoFold(e, &ok);
    return ok && v >= 0 ? v : -1;
    }

// A loop threads cannot pay for: a constant count of under 65536 iterations
// whose tokens (from..to) hold no loop, goto, `new` or call. Waking the
// threads costs more than the work (4096 element stores took 923 us as a
// block, a few as a loop), and the block's code in the function crowds the
// loops after it. As the port.
- (BOOL)parAutoSmall:(XTASTNode*)loop from:(NSUInteger)from to:(NSUInteger)to
    {
    XTVariableDeclNode* iv = nil;
    XTBinaryExprNode* cond = nil;
    if (!parAutoAscending(loop, &iv, &cond))
        return NO;
    int64_t lo = parAutoConst(iv.initialiser);
    int64_t hi = parAutoConst(cond.right);
    if (lo < 0 || hi < 0 || hi - lo >= 65536)
        return NO;
    // The `for` itself is the first token.
    for (NSUInteger i = from + 1; i < to && i < _tokens.count; i++)
        {
        XTTokenType t = _tokens[i].type;
        if (t == XTTokenFor || t == XTTokenWhile || t == XTTokenGoto || t == XTTokenNew)
            return NO;
        if (t == XTTokenIdentifier && i + 1 < _tokens.count && _tokens[i + 1].type == XTTokenLParen)
            return NO;
        }
    return YES;
    }

// --par-style=auto on the loop at the cursor. The site table the recogniser
// reads holds the sites of the outermost loop being parsed. As the port.
- (nullable XTASTNode*)parAutoFor
    {
    if (self.parAutoNest == 0)
        self.plSites = nil;
    self.parAutoNest++;
    XTASTNode* out = [self parAutoForAt];
    self.parAutoNest--;
    return out;
    }

// The loop is parsed as it stands, with each loop inside it looked at on its
// own, and the recogniser reads its tree (plRecogniseFor). A loop that stays a
// loop keeps that parse; its trace line and its -Wpar-auto warnings go where
// it starts, before those of the loops inside it. A loop that becomes a block
// is parsed as the block's loop, nothing in it lifted: the parse is taken
// back and the loop parsed again where the first parse looked at a loop
// inside it or read the loop depth, so the block, its numbers and its
// diagnostics are those of the one parse. As the port.
- (nullable XTASTNode*)parAutoForAt
    {
    BOOL fromWhile = self.parAutoFromWhile;
    self.parAutoFromWhile = NO;
    XTSourceLocation* traceAt = [self currentLocation];
    // A counted `while` (parAutoWhileShape): the parses below build its `for`
    // from the `while` (parseAutoWhile).
    NSString* wv = nil;
    XTType* wvt = nil;
    XTToken* wInc = nil;
    NSUInteger wIncLen = 0;
    NSArray<XTToken*>* wToks = nil;
    NSInteger whileInc = self.plWhileInc;
    if (fromWhile)
        {
        wv = self.pwV;
        wvt = self.pwVt;
        wInc = _tokens[self.pwInc];
        wIncLen = whileInc == 4 ? 6 : whileInc == 3 ? 4 : 3;
        wToks = [self parAutoWhileToks:NO];
        }
    // XC_PAR_AUTO_CHECK: the token scan's verdict, for the recogniser's to be
    // compared with once the loop is parsed.
    NSMutableDictionary* scanV = nil;
    NSUInteger pacSeen = 0, pacVal = 0;
    if (self.parAutoRecogOn || self.parAutoCheckOn)
        {
        scanV = [self parAutoScanCheck:fromWhile];
        pacSeen = self.pacSeen;
        pacVal = self.pacVal;
        }
    NSDictionary* mark = [self parAutoMark];
    NSUInteger forPos = _pos;
    NSUInteger blkAt = [self.blkState[@"counter"] unsignedIntegerValue];
    NSUInteger parAt = [self.blkState[@"parCounter"] unsignedIntegerValue];
    NSUInteger seqAt = self.scanSeq;
    NSUInteger plainDiag = _diagnostics.diagnostics.count;
    NSUInteger traceMark = _parAutoTrace.count;
    NSUInteger depthReads = self.parAutoDepthReads;
    [self parGridLoop:1];
    XTASTNode* plain = fromWhile ? [self parseAutoWhile:wv type:wvt inc:wInc length:wIncLen] : [self parseFor];
    [self parGridLoop:-1];
    NSUInteger plainEnd0 = _pos;
    // The verdict, with the -Wpar-auto warnings of a loop that stays a loop
    // before the diagnostics of its parse.
    NSUInteger recDiag = _diagnostics.diagnostics.count;
    self.plWarn = YES;
    NSMutableDictionary* v = [[self plRecogniseFor:plain at:traceAt] mutableCopy];
    self.plWarn = NO;
    [_diagnostics moveDiagnosticsFrom:recDiag to:plainDiag];
    BOOL lift = [v[@"lift"] boolValue];
    NSString* form = fromWhile ? @"while" : v[@"form"];
    // Without the par runtime the loop stays a loop, and the driver is told:
    // it parses again with Par.xc imported (--par-style=auto imports it).
    BOOL haveRuntime = [self.typeTable typeForName:@"ParChunk"] != nil;
    if (lift && !haveRuntime)
        _parAutoWantsRuntime = YES;
    if (!lift || !haveRuntime)
        {
        NSUInteger tm = _parAutoTrace.count;
        [self parAutoTraceAt:traceAt verdict:@"serial" rule:lift ? @"no-runtime" : v[@"rule"] form:form name:nil reds:nil grid:0 impl:nil];
        parAutoMoveTail(_parAutoTrace, tm, traceMark);
        [self parAutoCheck:plain at:traceAt seen:pacSeen val:pacVal];
        [self plCheckVerdict:scanV recog:v plain:plain at:traceAt fromWhile:fromWhile inc:whileInc from:forPos to:plainEnd0];
        if (fromWhile && plain)
            [self plRegister:plain entry:@{ @"kind" : @3, @"plain" : plain, @"inc" : @(whileInc) }];
        return plain;
        }
    // The block's loop, parsed as --par-style=cpu parses it (nothing in it
    // lifted): the site falls back to it when par-check demotes the block,
    // and a small loop stays that loop.
    if (self.parAutoDepthReads != depthReads)
        {
        [self parAutoRollback:mark];
        [self parGridLoop:1];
        [self parAutoLoop:1];
        plain = fromWhile ? [self parseAutoWhile:wv type:wvt inc:wInc length:wIncLen] : [self parseFor];
        [self parAutoLoop:-1];
        [self parGridLoop:-1];
        }
    [self parAutoCheck:plain at:traceAt seen:pacSeen val:pacVal];
    [self plCheckVerdict:scanV recog:v plain:plain at:traceAt fromWhile:fromWhile inc:whileInc from:forPos to:_pos];
    NSArray<NSArray<NSString*>*>* reds = v[@"redList"] ?: @[];
    NSUInteger goal = [v[@"goal"] unsignedIntegerValue];
    NSUInteger gridCap = [v[@"grid"] unsignedIntegerValue];
    self.parScanAcc = v[@"scanAcc"];
    self.parScanOp = v[@"scanOp"];
    // The site the walk reads in place of what this returns (plSites): the
    // loop as written, or the `while` it was.
    NSDictionary* plEntry = plain ? (fromWhile ? @{ @"kind" : @3, @"plain" : plain, @"inc" : @(whileInc) }
                                               : @{ @"kind" : @2, @"plain" : plain })
                                  : nil;
    if (!plain || [v[@"small"] boolValue])
        {
        [self parAutoTraceAt:traceAt verdict:@"serial" rule:plain ? @"small" : @"parse" form:form name:nil reds:nil grid:0 impl:nil];
        if (fromWhile && plain)
            [self plRegister:plain entry:plEntry];
        return plain;
        }
    // A running total (#144): the loop's tokens become
    // `par :scan(op acc) { for … }`, which parScanRewrite turns into blocks;
    // a loop the rewrite does not take stays the loop. As the port.
    if (self.parScanAcc)
        {
        NSString* sreds = [NSString stringWithFormat:@"%@:%@", self.parScanOp, self.parScanAcc];
        NSUInteger implFrom = [self.blkState[@"parCounter"] unsignedIntegerValue];
        // The rewrite reads the loop's tokens: a `while` gives way to its
        // `for`'s, and comes back when the rewrite does not take it.
        NSArray<XTToken*>* kept = nil;
        NSUInteger wEnd = _pos;
        if (fromWhile)
            {
            kept = _tokens;
            NSMutableArray<XTToken*>* spliced = [_tokens mutableCopy];
            [spliced replaceObjectsInRange:NSMakeRange(forPos, wEnd - forPos) withObjectsFromArray:wToks];
            _tokens = spliced;
            _pos = forPos + wToks.count;
            }
        XTASTNode* sc = [self parAutoScanFor:plain at:forPos];
        if (kept && sc == plain)
            {
            _tokens = kept;
            _pos = wEnd;
            }
        if (sc != plain || fromWhile)
            [self plRegister:sc entry:plEntry];
        if (sc == plain)
            [self parAutoTraceAt:traceAt verdict:@"serial" rule:@"scan-refused" form:form name:nil reds:nil grid:0 impl:nil];
        else
            [self parAutoTraceAt:traceAt verdict:@"lifted" rule:@"scan" form:form name:nil reds:sreds grid:0
                            impl:parAutoImplSpan(implFrom, [self.blkState[@"parCounter"] unsignedIntegerValue])];
        return sc;
        }
    // A loop whose body holds a block literal or a written par block stays
    // the loop. As the port.
    NSUInteger plainEnd = _pos;
    XTSourceLocation* loc = _tokens[forPos].location;
    if ([self.blkState[@"counter"] unsignedIntegerValue] != blkAt ||
        [self.blkState[@"parCounter"] unsignedIntegerValue] != parAt || self.scanSeq != seqAt)
        {
        [_diagnostics emitWarning:@"this loop runs serially, not as a 'par' block (--par-style): its body holds a block"
                         category:XTWarnParAuto
                               at:loc];
        [self parAutoTraceAt:traceAt verdict:@"serial" rule:@"body-block" form:form name:nil reds:nil grid:0 impl:nil];
        if (fromWhile)
            [self plRegister:plain entry:plEntry];
        return plain;
        }
    // A loop the block form refuses stays the loop: an error the loop's
    // parse, the walk of its copy or its desugaring reports (a capture of self
    // or of an ivar, say) is taken back, and the loop as parsed above is the
    // statement. A loop of a method that reads self.n failed to compile (UXKit
    // had 25). As the port.
    NSUInteger diagMark = _diagnostics.diagnostics.count;
    NSUInteger errMark = _diagnostics.errorCount;
    for (NSUInteger k = plainDiag; k < diagMark; k++)
        if (_diagnostics.diagnostics[k].level == XTDiagnosticLevelError)
            {
            [self parAutoRefusedWhy:_diagnostics.diagnostics[k].message at:loc];
            [self parAutoTraceAt:traceAt verdict:@"serial" rule:@"block-refused" form:form name:nil reds:nil grid:0 impl:nil];
            if (fromWhile)
                [self plRegister:plain entry:plEntry];
            return plain;
            }
    NSMutableDictionary* frame = [NSMutableDictionary dictionary];
    frame[@"plain"] = plain;
    frame[@"depth"] = @([self blkScopes].count);
    frame[@"names"] = [NSMutableArray array];
    frame[@"types"] = [NSMutableDictionary dictionary];
    frame[@"bases"] = [NSMutableDictionary dictionary];
    frame[@"wb"] = [NSMutableSet set];
    frame[@"selfName"] = [NSNull null];
    frame[@"par"] = @YES;
    frame[@"written"] = [NSMutableSet set];
    // In main, outside every loop and block literal: it runs once per program
    // run (runsOnce, for the probe's report).
    if ([self.blkState[@"fn"] isEqual:@"main"] && [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0 && [self blkFrames].count == 0)
        frame[@"once"] = @YES;
    // The block's goal: the loop's own, else the goal of the loop or block it
    // sits in, else the file's or the build's, else speed, as a written
    // block's. A float sum still lifts only under an explicit speed goal.
    // As the port.
    if (goal != 2)
        frame[@"fast"] = @YES;
    frame[@"auto"] = @YES;
    // The block's loop: a copy of the loop as parsed, with the goals the
    // block's own gives it, and its frame from the walk of the copy, which
    // also says what the block cannot capture and reads `self.f` as the ivar
    // (pfwSelfIvar), as a parse in the block's frame did. As the port.
    XTASTNode* loop = XTASTDeepCopy(plain);
    parAutoGoals(loop, goal == 2 ? 2 : 1);
    self.pfwAuto = YES;
    self.pfwRoot = loop;
    [self parFrameFill:frame body:loop];
    self.pfwAuto = NO;
    self.pfwRoot = nil;
    if (_diagnostics.errorCount > errMark)
        {
        [self parAutoTakeBack:diagMark at:loc];
        _pos = plainEnd;
        [self parAutoTraceAt:traceAt verdict:@"serial" rule:@"block-refused" form:form name:nil reds:nil grid:0 impl:nil];
        if (fromWhile)
            [self plRegister:plain entry:plEntry];
        return plain;
        }
    // The warnings the loop's parse gave, again: the block's parse gave them a
    // second time.
    for (NSUInteger k = plainDiag; k < diagMark; k++)
        {
        XTDiagnostic* d = _diagnostics.diagnostics[k];
        if (d.level == XTDiagnosticLevelWarning)
            [_diagnostics emitWarning:d.message at:d.location];
        else if (d.level == XTDiagnosticLevelNote)
            [_diagnostics emitNote:d.message at:d.location];
        }
    // A perfect two-deep nest becomes one block over the W*H grid (the
    // :grid form): W*H work items in one dispatch rather than H items each
    // running W serially, which matters when H is small.
    XTBlockNode* body = [self parAutoGridNest:loop frame:frame at:loc cap:gridCap];
    if (!body)
        body = [[XTBlockNode alloc] initWithStatements:@[ loop ] location:loc];
    // Named where the loop is, file:line (a second one on the line #2, as the
    // C path names its blocks), so a program can ask where a lifted loop ran
    // (Par.ranOn) and XC_PAR_REPORT says which loop it is. As the port.
    NSUInteger c = [self.blkState[@"parAutoCounter"] unsignedIntegerValue] + 1;
    self.blkState[@"parAutoCounter"] = @(c);
    NSString* name = [NSString stringWithFormat:@"%@:%lu", loc.filename.lastPathComponent ?: @"?", (unsigned long)loc.line];
    NSMutableDictionary<NSString*, NSNumber*>* labels = self.blkState[@"parAutoLabels"];
    if (!labels)
        {
        labels = [NSMutableDictionary dictionary];
        self.blkState[@"parAutoLabels"] = labels;
        }
    NSUInteger nth = labels[name].unsignedIntegerValue + 1;
    labels[name] = @(nth);
    if (!self.parAutoLabelLog)
        self.parAutoLabelLog = [NSMutableArray array];
    [self.parAutoLabelLog addObject:name];
    if (nth > 1)
        name = [NSString stringWithFormat:@"%@#%lu", name, (unsigned long)nth];
    NSMutableArray* savedNoted = self.pfwNoted;
    self.pfwNoted = [NSMutableArray array];
    XTASTNode* out = [self parDesugarBody:body frame:frame name:name reductions:reds at:loc];
    [self pfwRegister:out body:loop params:nil noted:self.pfwNoted kind:2 plain:plain];
    self.pfwNoted = savedNoted;
    if (!out || _diagnostics.errorCount > errMark)
        {
        [self parAutoTakeBack:diagMark at:loc];
        _pos = plainEnd;
        [self parAutoTraceAt:traceAt verdict:@"serial" rule:@"block-refused" form:form name:nil reds:nil grid:0 impl:nil];
        if (fromWhile)
            [self plRegister:plain entry:plEntry];
        return plain;
        }
    [self plRegister:out entry:plEntry];
    if (self.parAutoTraceOn)
        {
        NSMutableArray<NSString*>* rl = [NSMutableArray array];
        for (NSArray<NSString*>* r in reds)
            [rl addObject:[NSString stringWithFormat:@"%@:%@%@", r[0], r[1], r.count > 2 ? @"[]" : @""]];
        NSArray* grid = frame[@"grid"];
        NSUInteger pc = [self.blkState[@"parCounter"] unsignedIntegerValue];
        [self parAutoTraceAt:traceAt verdict:@"lifted" rule:@"block" form:form name:name
                        reds:rl.count ? [rl componentsJoinedByString:@","] : nil
                        grid:grid ? grid.count : 1
                        impl:pc ? parAutoImplSpan(pc - 1, pc) : nil];
        }
    return out;
    }

// The block form of a loop failed: its diagnostics go, and -Wpar-auto says
// why the loop stays a loop, with the first error the block form reported.
// As the port (parAutoRefused).
- (void)parAutoTakeBack:(NSUInteger)diagMark at:(XTSourceLocation*)loc
    {
    NSString* why = nil;
    NSArray<XTDiagnostic*>* all = _diagnostics.diagnostics;
    for (NSUInteger k = diagMark; k < all.count && !why; k++)
        if (all[k].level == XTDiagnosticLevelError)
            why = all[k].message;
    [_diagnostics truncateToCount:diagMark];
    [self parAutoRefusedWhy:why at:loc];
    }

// -Wpar-auto's line for a block form refused with the error `why`. As the port.
- (void)parAutoRefusedWhy:(nullable NSString*)why at:(XTSourceLocation*)loc
    {
    if (why)
        [_diagnostics emitWarning:[NSString stringWithFormat:@"this loop runs serially, not as a 'par' block (--par-style): "
                                                             @"its block form is refused: %@", why]
                         category:XTWarnParAuto
                               at:loc];
    }

/****************************************************************************\
|* :scan (#144): `par [name] :scan(op acc) [:goal(…)] { for (T i in a..b) {
|* … } }`, a running total. The tokens are rewritten, before parsing, into
|* pieces a par block already has: a block over 256 chunks (each runs its
|* slice serially with its own accumulator from the operator's identity,
|* stores the per-item values and records its total), a serial scan of the
|* totals from acc (acc ends as the overall total), and a block over the
|* chunks that combines each chunk's offset into its slice of every array
|* the loop stored acc into (a range under 65536 items runs as the loop,
|* over the same bounds). acc may only be updated (acc += e, acc = acc +
|* e, acc++, and `if (e < acc) acc = e;` / `if (e > acc) acc = e;` for min
|* and max) and stored (a[i] = acc;), the output arrays used nowhere else.
|* The generated blocks carry `:__scanpass` (chunks own disjoint slices: no
|* dependence test, CPU only). A float scan under the accuracy goal stays a
|* serial loop. YES when it rewrote. Mirrored in the port.
\****************************************************************************/
- (NSUInteger)scClose:(NSUInteger)i
    {
    XTTokenType o = [self parTokType:i];
    XTTokenType c = o == XTTokenLParen ? XTTokenRParen : o == XTTokenLBrace ? XTTokenRBrace : XTTokenRBracket;
    NSInteger d = 0;
    for (NSUInteger k = i; k < _tokens.count; k++)
        {
        XTTokenType t = [self parTokType:k];
        if (t == o)
            d++;
        else if (t == c && --d == 0)
            return k;
        }
    return 0;
    }

- (BOOL)scStmtStart:(NSUInteger)p body:(NSUInteger)bo
    {
    XTTokenType t = [self parTokType:p];
    return p == bo || t == XTTokenSemicolon || t == XTTokenLBrace || t == XTTokenRBrace;
    }

- (NSUInteger)scExprEnd:(NSUInteger)q limit:(NSUInteger)lim acc:(NSString*)acc
    {
    NSInteger d = 0;
    for (NSUInteger k = q; k < lim; k++)
        {
        XTTokenType t = [self parTokType:k];
        if (t == XTTokenLParen || t == XTTokenLBracket)
            d++;
        else if (t == XTTokenRParen || t == XTTokenRBracket)
            d--;
        else if (t == XTTokenSemicolon && d == 0)
            return k == q ? 0 : k;
        else if (t == XTTokenIdentifier && [[self parTokValue:k] isEqualToString:acc])
            return 0;
        }
    return 0;
    }

- (BOOL)scSame:(NSUInteger)a as:(NSUInteger)b count:(NSUInteger)n
    {
    for (NSUInteger k = 0; k < n; k++)
        if ([self parTokType:a + k] != [self parTokType:b + k] || ![[self parTokValue:a + k] isEqualToString:[self parTokValue:b + k]])
            return NO;
    return YES;
    }

static BOOL scIntType(NSString* t)
    {
    return [@[ @"u8", @"i8", @"u16", @"i16", @"u32", @"i32", @"u64", @"i64" ] containsObject:t ?: @""];
    }

static BOOL scSigned(NSString* t)
    {
    return [@[ @"i8", @"i16", @"i32", @"i64" ] containsObject:t ?: @""];
    }

static NSString* scIdentity(NSString* op, NSString* t)
    {
    if ([op isEqualToString:@"&"] || ([op isEqualToString:@"min"] && !scSigned(t) && scIntType(t)))
        return [NSString stringWithFormat:@"~(%@)0", t];
    if ([op isEqualToString:@"min"] || [op isEqualToString:@"max"])
        {
        NSString* big = [t isEqualToString:@"i8"] ? @"127" : [t isEqualToString:@"i16"] ? @"32767"
                       : [t isEqualToString:@"i32"] ? @"2147483647" : @"9223372036854775807";
        if ([op isEqualToString:@"min"])
            return [NSString stringWithFormat:@"(%@)%@", t, big];
        if (scSigned(t))
            return [NSString stringWithFormat:@"((%@)0 - (%@)%@ - (%@)1)", t, t, big, t];
        return [NSString stringWithFormat:@"(%@)0", t];
        }
    return [NSString stringWithFormat:@"(%@)0", t];
    }

static NSString* scCombine(NSString* op, NSString* r, NSString* v)
    {
    if ([op isEqualToString:@"min"])
        return [NSString stringWithFormat:@"if (%@ < %@) %@ = %@;", v, r, r, v];
    if ([op isEqualToString:@"max"])
        return [NSString stringWithFormat:@"if (%@ > %@) %@ = %@;", v, r, r, v];
    return [NSString stringWithFormat:@"%@ = %@ %@ %@;", r, r, op, v];
    }

- (BOOL)parScanRewrite
    {
    NSUInteger at = _pos;
    XTToken* pt = _tokens[at];
    NSUInteger k = at + 1;
    NSString* name = nil;
    if ([self parTokType:k] == XTTokenIdentifier && [self parTokType:k + 1] != XTTokenAssign)
        name = [self parTokValue:k++];
    NSString *op = nil, *acc = nil;
    NSUInteger s0 = 0, s1 = 0;
    NSMutableArray* goal = [NSMutableArray array];
    BOOL other = NO;
    while ([self parTokType:k] == XTTokenColon && [self parTokType:k + 1] == XTTokenIdentifier)
        {
        NSUInteger d0 = k, dEnd = k + 2;
        if ([self parTokType:dEnd] == XTTokenLParen)
            {
            NSUInteger c = [self scClose:dEnd];
            if (c == 0)
                return NO;
            dEnd = c + 1;
            }
        NSString* dn = [self parTokValue:d0 + 1];
        if ([dn isEqualToString:@"scan"])
            {
            s0 = d0;
            s1 = dEnd;
            NSUInteger q = d0 + 3;
            XTTokenType t = [self parTokType:q];
            if (t == XTTokenPlus)
                op = @"+";
            else if (t == XTTokenPipe)
                op = @"|";
            else if (t == XTTokenAmpersand)
                op = @"&";
            else if (t == XTTokenCaret)
                op = @"^";
            else if (t == XTTokenIdentifier && ([[self parTokValue:q] isEqualToString:@"min"] || [[self parTokValue:q] isEqualToString:@"max"]))
                op = [self parTokValue:q];
            if (op && [self parTokType:q + 1] == XTTokenIdentifier && dEnd == q + 3)
                acc = [self parTokValue:q + 1];
            }
        else if ([dn isEqualToString:@"goal"])
            [goal addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(d0, dEnd - d0)]];
        else
            other = YES;
        k = dEnd;
        }
    if (s1 == 0)
        return NO;
    XTToken* st = _tokens[s0 + 1];
    // The block then parses on as written, its :scan(…) skipped.
    // For --par-style=auto (quiet) the loop stays a loop.
    void (^fail)(NSString*, XTToken*) = ^(NSString* msg, XTToken* t) {
      if (!self.scanQuiet)
          [self->_diagnostics emitError:msg at:t.location];
    };
    if (!acc)
        {
        fail(@"':scan' wants an operator (+ | & ^ min max) and a variable: :scan(+ total)", st);
        return NO;
        }
    if (other)
        {
        fail(@"':scan' combines only with ':goal'", st);
        return NO;
        }
    NSString* shape = @"a ':scan' block is one loop: par :scan(+ acc) { for (T i in a..b) { … } }";
    if ([self parTokType:k] != XTTokenLBrace)
        {
        fail(shape, st);
        return NO;
        }
    NSUInteger be = [self scClose:k];
    NSUInteger f = k + 1;
    BOOL ok = be != 0 && [self parTokType:f] == XTTokenFor && [self parTokType:f + 1] == XTTokenLParen &&
              [self parTokType:f + 3] == XTTokenIdentifier && [self parTokType:f + 4] == XTTokenIn &&
              scIntType([self parTokValue:f + 2]);
    NSUInteger fc = ok ? [self scClose:f + 1] : 0;
    NSUInteger rg = 0;
    BOOL incl = NO;
    if (fc != 0)
        {
        NSInteger d = 0;
        for (NSUInteger q = f + 5; q < fc; q++)
            {
            XTTokenType t = [self parTokType:q];
            if (t == XTTokenLParen || t == XTTokenLBracket)
                d++;
            else if (t == XTTokenRParen || t == XTTokenRBracket)
                d--;
            else if (d == 0 && (t == XTTokenDotDot || t == XTTokenEllipsis))
                {
                rg = q;
                incl = t == XTTokenEllipsis;
                break;
                }
            }
        }
    NSUInteger bo = fc + 1;
    NSUInteger bc = rg != 0 && [self parTokType:bo] == XTTokenLBrace ? [self scClose:bo] : 0;
    if (rg == 0 || rg == f + 5 || rg + 1 == fc || bc == 0 || bc + 1 != be)
        {
        fail(shape, st);
        return NO;
        }
    NSString* ity = [self parTokValue:f + 2];
    NSString* iv = [self parTokValue:f + 3];
    NSUInteger dd = 0;
    NSDictionary* info = [self blkLookup:acc depth:&dd];
    XTType* atyT = [info[@"type"] isKindOfClass:[XTType class]] ? info[@"type"] : nil;
    NSString* aty = atyT.displayName;
    BOOL isFloat = [aty isEqualToString:@"float"] || [aty isEqualToString:@"double"];
    if (!aty || (!isFloat && !scIntType(aty)))
        {
        fail([NSString stringWithFormat:@"':scan' wants '%@' to be a local variable of an integer or floating type", acc], st);
        return NO;
        }
    if (isFloat && ![op isEqualToString:@"+"])
        {
        fail(@"a floating-point ':scan' takes only +", st);
        return NO;
        }
    BOOL mm = [op isEqualToString:@"min"] || [op isEqualToString:@"max"];
    NSMutableArray<NSString*>* outs = [NSMutableArray array];
    NSUInteger updates = 0;
    for (NSUInteger q = bo + 1; q < bc; q++)
        {
        XTTokenType t = [self parTokType:q];
        if (t == XTTokenBreak || t == XTTokenReturn || t == XTTokenGoto)
            {
            fail(@"a ':scan' loop has no break, return or goto", _tokens[q]);
            return NO;
            }
        if (t != XTTokenIdentifier || ![[self parTokValue:q] isEqualToString:acc])
            continue;
        XTTokenType pv = [self parTokType:q - 1];
        if (pv == XTTokenDot || pv == XTTokenArrow)
            continue;
        if (q >= bo + 6 && pv == XTTokenAssign && [self parTokType:q - 2] == XTTokenRBracket &&
            [self parTokType:q - 3] == XTTokenIdentifier && [[self parTokValue:q - 3] isEqualToString:iv] &&
            [self parTokType:q - 4] == XTTokenLBracket && [self parTokType:q - 5] == XTTokenIdentifier &&
            [self parTokType:q + 1] == XTTokenSemicolon && [self scStmtStart:q - 6 body:bo])
            {
            if (![outs containsObject:[self parTokValue:q - 5]])
                [outs addObject:[self parTokValue:q - 5]];
            q++;
            continue;
            }
        NSUInteger e = 0;
        if ([self scStmtStart:q - 1 body:bo])
            {
            XTTokenType t1 = [self parTokType:q + 1];
            BOOL opAssign = ([op isEqualToString:@"+"] && t1 == XTTokenPlusAssign) || ([op isEqualToString:@"|"] && t1 == XTTokenPipeAssign) ||
                            ([op isEqualToString:@"&"] && t1 == XTTokenAmpAssign) || ([op isEqualToString:@"^"] && t1 == XTTokenCaretAssign);
            if (opAssign)
                e = [self scExprEnd:q + 2 limit:bc acc:acc];
            else if ([op isEqualToString:@"+"] && t1 == XTTokenPlusPlus && [self parTokType:q + 2] == XTTokenSemicolon)
                e = q + 2;
            else if (t1 == XTTokenAssign && [self parTokType:q + 2] == XTTokenIdentifier && [[self parTokValue:q + 2] isEqualToString:acc] && !mm)
                {
                XTTokenType t3 = [self parTokType:q + 3];
                BOOL same = ([op isEqualToString:@"+"] && t3 == XTTokenPlus) || ([op isEqualToString:@"|"] && t3 == XTTokenPipe) ||
                            ([op isEqualToString:@"&"] && t3 == XTTokenAmpersand) || ([op isEqualToString:@"^"] && t3 == XTTokenCaret);
                if (same)
                    e = [self scExprEnd:q + 4 limit:bc acc:acc];
                }
            }
        if (e == 0 && [op isEqualToString:@"+"] && pv == XTTokenPlusPlus && [self scStmtStart:q - 2 body:bo] &&
            [self parTokType:q + 1] == XTTokenSemicolon)
            e = q + 1;
        if (e == 0 && mm && pv == ([op isEqualToString:@"min"] ? XTTokenLess : XTTokenGreater) &&
            [self parTokType:q + 1] == XTTokenRParen && [self parTokType:q + 2] == XTTokenIdentifier &&
            [[self parTokValue:q + 2] isEqualToString:acc] && [self parTokType:q + 3] == XTTokenAssign)
            {
            NSUInteger p = 0;
            for (NSUInteger j = q - 2; j > bo; j--)
                if ([self parTokType:j] == XTTokenLParen && [self scClose:j] == q + 1)
                    {
                    p = j;
                    break;
                    }
            NSUInteger e2 = [self scExprEnd:q + 4 limit:bc acc:acc];
            if (p != 0 && [self parTokType:p - 1] == XTTokenIf && [self scStmtStart:p - 2 body:bo] && e2 != 0 &&
                q - 1 - (p + 1) == e2 - (q + 4) && q - 1 > p + 1 && [self scSame:p + 1 as:q + 4 count:e2 - (q + 4)])
                {
                BOOL clean = YES;
                for (NSUInteger j = p + 1; j < q - 1; j++)
                    if ([self parTokType:j] == XTTokenIdentifier && [[self parTokValue:j] isEqualToString:acc])
                        clean = NO;
                if (clean)
                    e = e2;
                }
            }
        if (e == 0)
            {
            NSString* upd = mm ? [NSString stringWithFormat:@": if (e %@ %@) %@ = e;", [op isEqualToString:@"min"] ? @"<" : @">", acc, acc]
                               : [NSString stringWithFormat:@" %@= e", op];
            fail([NSString stringWithFormat:@"in a ':scan' loop '%@' may only be updated (%@%@) and stored (a[i] = %@;)", acc, acc, upd, acc],
                 _tokens[q]);
            return NO;
            }
        updates++;
        q = e;
        }
    if (updates == 0 || outs.count == 0)
        {
        fail(updates == 0 ? @"a ':scan' loop updates its variable"
                          : [NSString stringWithFormat:@"a ':scan' loop stores its running value (a[i] = %@;); with no store it is a :reduce", acc],
             st);
        return NO;
        }
    for (NSUInteger q = bo + 1; q < bc; q++)
        {
        if ([self parTokType:q] != XTTokenIdentifier || ![outs containsObject:[self parTokValue:q]])
            continue;
        if ([self parTokType:q - 1] == XTTokenDot || [self parTokType:q - 1] == XTTokenArrow)
            continue;
        if ([self parTokType:q + 1] == XTTokenLBracket && [self parTokType:q + 2] == XTTokenIdentifier &&
            [[self parTokValue:q + 2] isEqualToString:iv] && [self parTokType:q + 3] == XTTokenRBracket &&
            [self parTokType:q + 4] == XTTokenAssign && [self parTokType:q + 5] == XTTokenIdentifier &&
            [[self parTokValue:q + 5] isEqualToString:acc] && [self parTokType:q + 6] == XTTokenSemicolon)
            continue;
        NSString* X = [self parTokValue:q];
        fail([NSString stringWithFormat:@"a ':scan' loop's output array '%@' is only stored, by %@[i] = %@;", X, X, acc], _tokens[q]);
        return NO;
        }
    BOOL accuracy = (self.goalNow ?: self.goalDefault) == 2;
    for (XTToken* g in goal)
        {
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"accuracy"])
            accuracy = YES;
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"speed"])
            accuracy = NO;
        }
    XTSourceLocation* loc = pt.location;
    NSMutableArray* out = [NSMutableArray array];
    if (isFloat && accuracy)
        {
        [out addObject:[[XTToken alloc] initWithType:XTTokenLBrace value:@"{" location:loc]];
        [out addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(f, be - f)]];
        [out addObject:[[XTToken alloc] initWithType:XTTokenRBrace value:@"}" location:loc]];
        NSMutableArray<XTToken*>* spliced = [_tokens mutableCopy];
        [spliced replaceObjectsInRange:NSMakeRange(at, be + 1 - at) withObjectsFromArray:out];
        _tokens = spliced;
        return YES;
        }
    NSUInteger n = ++self.scanSeq;
    NSString *T = ity, *A = aty;
    NSMutableString* src = [NSMutableString string];
    [src appendFormat:@"{ %@ __xs_a%lu = (__XC_SCAN_A__); %@ __xs_e%lu = (__XC_SCAN_B__)%@;\n", T, (unsigned long)n, T, (unsigned long)n,
                      incl ? @" + 1" : @""];
    [src appendFormat:@"u64 __xs_n%lu = __xs_e%lu > __xs_a%lu ? (u64)(__xs_e%lu - __xs_a%lu) : (u64)0;\n", (unsigned long)n, (unsigned long)n,
                      (unsigned long)n, (unsigned long)n, (unsigned long)n];
    // Short ranges run as the loop (waking the threads costs more).
    [src appendFormat:@"if (__xs_n%lu < (u64)65536) { for (%@ %@ in __xs_a%lu..__xs_e%lu) { __XC_SCAN_PLAIN__ } } else {\n", (unsigned long)n, T, iv,
                      (unsigned long)n, (unsigned long)n];
    [src appendFormat:@"%@ __xs_t%lu[256];\n", A, (unsigned long)n];
    NSString* lohi = [NSString stringWithFormat:@"%@ __xs_lo = __xs_a%lu + (%@)(__xs_n%lu * (u64)__xs_c / (u64)256); "
                                                 "%@ __xs_hi = __xs_a%lu + (%@)(__xs_n%lu * (u64)(__xs_c + (u32)1) / (u64)256);\n",
                                                T, (unsigned long)n, T, (unsigned long)n, T, (unsigned long)n, T, (unsigned long)n];
    [src appendFormat:@"par %@ :device(cpu) :__scanpass __XC_SCAN_GOAL__ { for (u32 __xs_c in 0..256) {\n", name ?: @""];
    [src appendString:lohi];
    [src appendFormat:@"%@ __xs_s = %@;\n", A, scIdentity(op, aty)];
    [src appendFormat:@"for (%@ %@ in __xs_lo..__xs_hi) { __XC_SCAN_BODY__ }\n", T, iv];
    [src appendFormat:@"__xs_t%lu[__xs_c] = __xs_s; } }\n", (unsigned long)n];
    [src appendFormat:@"%@ __xs_r%lu = %@;\n", A, (unsigned long)n, acc];
    NSString* rn = [NSString stringWithFormat:@"__xs_r%lu", (unsigned long)n];
    [src appendFormat:@"for (u32 __xs_c in 0..256) { %@ __xs_v = __xs_t%lu[__xs_c]; __xs_t%lu[__xs_c] = __xs_r%lu; %@ }\n", A, (unsigned long)n,
                      (unsigned long)n, (unsigned long)n, scCombine(op, rn, @"__xs_v")];
    NSString* name2 = name ? [name stringByAppendingString:@"_offsets"] : @"";
    [src appendFormat:@"par %@ :device(cpu) :__scanpass __XC_SCAN_GOAL__ { for (u32 __xs_c in 0..256) {\n", name2];
    [src appendString:lohi];
    [src appendFormat:@"%@ __xs_o = __xs_t%lu[__xs_c];\n", A, (unsigned long)n];
    [src appendFormat:@"for (%@ %@ in __xs_lo..__xs_hi) {", T, iv];
    for (NSString* X in outs)
        {
        if (mm)
            [src appendFormat:@" if (__xs_o %@ (%@)%@[%@]) %@[%@] = __xs_o;", [op isEqualToString:@"min"] ? @"<" : @">", A, X, iv, X, iv];
        else
            [src appendFormat:@" %@[%@] = (%@)(__xs_o %@ (%@)%@[%@]);", X, iv, A, op, A, X, iv];
        }
    [src appendString:@" } } }\n"];
    [src appendFormat:@"%@ = __xs_r%lu; } }\n", acc, (unsigned long)n];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:src filename:@"<scan>" diagnostics:_diagnostics];
    for (XTToken* g in [lexer tokenise])
        {
        if (g.type == XTTokenEOF)
            break;
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"__XC_SCAN_A__"])
            {
            [out addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(f + 5, rg - (f + 5))]];
            continue;
            }
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"__XC_SCAN_B__"])
            {
            [out addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(rg + 1, fc - (rg + 1))]];
            continue;
            }
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"__XC_SCAN_GOAL__"])
            {
            [out addObjectsFromArray:goal];
            continue;
            }
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"__XC_SCAN_PLAIN__"])
            {
            [out addObjectsFromArray:[_tokens subarrayWithRange:NSMakeRange(bo + 1, bc - (bo + 1))]];
            continue;
            }
        if (g.type == XTTokenIdentifier && [g.value isEqualToString:@"__XC_SCAN_BODY__"])
            {
            for (NSUInteger q = bo + 1; q < bc; q++)
                {
                XTToken* b = _tokens[q];
                XTTokenType pv = [self parTokType:q - 1];
                if (b.type == XTTokenIdentifier && [b.value isEqualToString:acc] && pv != XTTokenDot && pv != XTTokenArrow)
                    [out addObject:[[XTToken alloc] initWithType:XTTokenIdentifier value:@"__xs_s" location:b.location]];
                else
                    [out addObject:b];
                }
            continue;
            }
        if (g.type == XTTokenIntLiteral)
            [out addObject:[[XTToken alloc] initWithType:g.type value:g.value intValue:g.intValue location:loc]];
        else
            [out addObject:[[XTToken alloc] initWithType:g.type value:g.value location:loc]];
        }
    NSMutableArray<XTToken*>* spliced = [_tokens mutableCopy];
        [spliced replaceObjectsInRange:NSMakeRange(at, be + 1 - at) withObjectsFromArray:out];
        _tokens = spliced;
    return YES;
    }

- (nullable XTASTNode*)parsePar
    {
    // :scan (#144): rewritten into plain blocks first.
    if ([self parScanRewrite])
        {
        self.scanInside++;
        XTASTNode* sc = [self parseStatement];
        self.scanInside--;
        return sc;
        }
    XTSourceLocation* loc = [self currentLocation];
    NSUInteger parAt = _pos;
    [self advance]; // consume 'par'
    NSString* name = nil;
    if ([self check:XTTokenIdentifier])
        {
        name = [self currentToken].value;
        [self advance];
        }
    NSMutableArray<NSArray<NSString*>*>* reductions = [NSMutableArray array];
    NSMutableArray<NSString*>* constants = [NSMutableArray array];   // :constant(a, b): captured arrays the GPU reads as constants
    // :goal(speed) (the default) or :goal(accuracy): its own, else the goal of
    // the loop or block it sits in, else the file's #goal or -fgoal=, else speed.
    BOOL accuracy = (self.goalNow ?: self.goalDefault) == 2;
    // :grid(w, h[, d]): the work items are the points of a 2-D or 3-D grid,
    // and the body is any code, run once per point.
    NSMutableArray<XTASTNode*>* grid = nil;
    // :device(cpu|gpu|gpus|all|auto): the developer's DEFAULT device, below
    // XC_PAR, the user's settings and Par.device, above auto (which then does
    // not measure the block): ParDevice's codes, 0 for auto, -1 when absent.
    NSInteger device = -1;
    BOOL scanPass = NO;
    while ([self check:XTTokenColon])
        {
        [self advance];
        XTToken* dec = [self expect:XTTokenIdentifier];
        if (!dec)
            return nil;
        if ([dec.value isEqualToString:@"grid"])
            {
            if (grid)
                {
                [_diagnostics emitError:@"'par' takes one ':grid'" at:dec.location];
                return nil;
                }
            if (![self expect:XTTokenLParen])
                return nil;
            grid = [NSMutableArray array];
            do
                {
                XTASTNode* e = [self parseExpression];
                if (!e)
                    return nil;
                [grid addObject:e];
                } while ([self match:XTTokenComma]);
            if (![self expect:XTTokenRParen])
                return nil;
            if (grid.count < 2 || grid.count > 3)
                {
                [_diagnostics emitError:@"':grid' takes a width and a height, and optionally a depth: "
                                         ":grid(w, h) or :grid(w, h, d)"
                                     at:dec.location];
                return nil;
                }
            continue;
            }
        if ([dec.value isEqualToString:@"device"])
            {
            if (device >= 0)
                {
                [_diagnostics emitError:@"'par' takes one ':device'" at:dec.location];
                return nil;
                }
            if (![self expect:XTTokenLParen])
                return nil;
            XTToken* d = [self expect:XTTokenIdentifier];
            if (!d)
                return nil;
            NSDictionary<NSString*, NSNumber*>* codes = @{ @"auto" : @0, @"cpu" : @1, @"gpu" : @2, @"gpus" : @3, @"all" : @4 };
            if (!codes[d.value])
                {
                [_diagnostics emitError:[NSString stringWithFormat:@"':device' takes cpu, gpu, gpus, all or auto, not '%@'", d.value]
                                     at:d.location];
                return nil;
                }
            device = codes[d.value].integerValue;
            if (![self expect:XTTokenRParen])
                return nil;
            continue;
            }
        if ([dec.value isEqualToString:@"goal"])
            {
            if (![self expect:XTTokenLParen])
                return nil;
            XTToken* g = [self expect:XTTokenIdentifier];
            if (!g)
                return nil;
            if (![g.value isEqualToString:@"speed"] && ![g.value isEqualToString:@"accuracy"])
                {
                [_diagnostics emitError:[NSString stringWithFormat:@"':goal' takes speed or accuracy, not '%@'", g.value]
                                     at:g.location];
                return nil;
                }
            accuracy = [g.value isEqualToString:@"accuracy"];
            if (![self expect:XTTokenRParen])
                return nil;
            continue;
            }
        // :constant(a, b): the named captured arrays are read-only data the
        // GPU may hold in its constant memory (par-blocks.md §3, storage
        // hints): a hint, never a change of meaning; the CPU path ignores it.
        if ([dec.value isEqualToString:@"constant"])
            {
            if (![self expect:XTTokenLParen])
                return nil;
            for (;;)
                {
                XTToken* nm = [self expect:XTTokenIdentifier];
                if (!nm)
                    return nil;
                [constants addObject:nm.value];
                if ([self currentToken].type != XTTokenComma)
                    break;
                [self advance];
                }
            if (![self expect:XTTokenRParen])
                return nil;
            continue;
            }
        // :__scanpass: a block a :scan was rewritten into (parScanRewrite);
        // its chunks own disjoint slices.
        if ([dec.value isEqualToString:@"__scanpass"])
            {
            scanPass = YES;
            continue;
            }
        // :scan(…) here: parScanRewrite has already said what is wrong.
        if ([dec.value isEqualToString:@"scan"])
            {
            if ([self check:XTTokenLParen])
                {
                NSInteger d = 1;
                [self advance];
                while (d > 0 && ![self check:XTTokenEOF])
                    {
                    if ([self check:XTTokenLParen])
                        d++;
                    else if ([self check:XTTokenRParen])
                        d--;
                    [self advance];
                    }
                }
            continue;
            }
        if (![dec.value isEqualToString:@"reduce"])
            {
            [_diagnostics emitError:[NSString stringWithFormat:@"'par' has no decorator ':%@' "
                                                                 "(it takes :reduce(op var), :scan(op var), :grid(w, h[, d]), "
                                                                 ":goal(speed|accuracy), :constant(a, b) and "
                                                                 ":device(cpu|gpu|gpus|all|auto))",
                                                               dec.value]
                                 at:dec.location];
            return nil;
            }
        [self expect:XTTokenLParen];
        XTToken* opTok = [self currentToken];
        NSString* op = nil;
        switch (opTok.type)
            {
        case XTTokenPlus: op = @"+"; break;
        case XTTokenStar: op = @"*"; break;
        case XTTokenAmpersand: op = @"&"; break;
        case XTTokenPipe: op = @"|"; break;
        case XTTokenCaret: op = @"^"; break;
        case XTTokenIdentifier:
            if ([opTok.value isEqualToString:@"min"] || [opTok.value isEqualToString:@"max"])
                op = opTok.value;
            break;
        default:
            break;
            }
        if (!op)
            {
            [_diagnostics emitError:@"':reduce' wants an operator (+ * & | ^ min max) and a "
                                     "variable: :reduce(+ sum)"
                                 at:opTok.location];
            return nil;
            }
        [self advance];
        XTToken* var = [self expect:XTTokenIdentifier];
        // `:reduce(+ h[])`: an array reduction, each chunk updating a private
        // copy of the array h (a third element, "[]").
        BOOL isArray = NO;
        if (var && [self match:XTTokenLBracket])
            {
            if (![self expect:XTTokenRBracket])
                return nil;
            isArray = YES;
            }
        [self expect:XTTokenRParen];
        if (!var)
            return nil;
        [reductions addObject:isArray ? @[ op, var.value, @"[]" ] : @[ op, var.value ]];
        }
    if (![self checkBlockOpen])
        {
        [_diagnostics emitError:@"'par' wants a block: par { ... }" at:[self currentLocation]];
        return nil;
        }
    // The body is parsed inside a capture frame, as a block literal's is, and
    // its frame computed from its tree (parFrameFill).
    NSMutableDictionary* frame = [NSMutableDictionary dictionary];
    frame[@"depth"] = @([self blkScopes].count);
    frame[@"names"] = [NSMutableArray array];
    frame[@"types"] = [NSMutableDictionary dictionary];
    frame[@"bases"] = [NSMutableDictionary dictionary];
    frame[@"wb"] = [NSMutableSet set];
    frame[@"selfName"] = [NSNull null];
    frame[@"par"] = @YES;
    frame[@"written"] = [NSMutableSet set];
    // In main, outside every loop and block literal: it runs once per program
    // run (runsOnce, for the probe's report).
    self.parAutoDepthReads++;
    if ([self.blkState[@"fn"] isEqual:@"main"] && [self.blkState[@"loopDepth"] unsignedIntegerValue] == 0 && [self blkFrames].count == 0)
        frame[@"once"] = @YES;
    if (grid)
        {
        frame[@"grid"] = grid;
        frame[@"gridUsed"] = [NSMutableSet set];
        frame[@"loops"] = @0;
        }
    [[self blkFrames] addObject:frame];
    [self blkPushScope];
    NSUInteger savedGoal = self.goalNow;
    self.goalNow = accuracy ? 2 : 1;
    // The header as written, for the recogniser's walk (plSite).
    // TODO(#338): removed in part C step 4–6, when a written par is copied
    // from its tree.
    NSArray<XTToken*>* head = self.parAuto ? [_tokens subarrayWithRange:NSMakeRange(parAt, _pos - parAt)] : nil;
    XTBlockNode* body = (XTBlockNode*)[self parseBlock];
    self.goalNow = savedGoal;
    [self blkPopScope];
    [[self blkFrames] removeLastObject];
    if (!body)
        return nil;
    // The block's frame, from the body's tree.
    [self parFrameFill:frame body:body];
    // The speed goal lets the GPU use its fast maths (approximate sin, cos,
    // exp, ln and pow); the CPU path is the same for both goals. The
    // desugaring marks the block's GPU placeholder with it.
    if (!accuracy)
        frame[@"fast"] = @YES;
    if (constants.count > 0)
        frame[@"constant"] = constants;
    if (device > 0)
        frame[@"device"] = @(device);
    if (scanPass)
        frame[@"scanpass"] = @YES;
    NSMutableArray* savedNoted = self.pfwNoted;
    self.pfwNoted = [NSMutableArray array];
    XTASTNode* out = [self parDesugarBody:body frame:frame name:name reductions:reductions at:loc];
    [self pfwRegister:out body:body params:nil noted:self.pfwNoted kind:1 plain:nil];
    if (out && body && head)
        [self plRegister:out entry:@{ @"kind" : @1, @"body" : body, @"head" : head }];
    self.pfwNoted = savedNoted;
    return out;
    }

- (nullable XTASTNode*)parseDefer
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'defer'
    if (![self checkBlockOpen])
        {
        [_diagnostics emitError:@"'defer' wants a block: defer { ... }"
                             at:[self currentLocation]];
        return nil;
        }
    XTASTNode* body = [self parseBlock];
    if (!body)
        return nil;
    return [[XTDeferNode alloc] initWithBody:body location:loc];
    }

/****************************************************************************\
|* Parse a switch statement: `switch (expr) { case V: ... default: ... }`.
|* Consecutive `case V:` labels with no statements between them collapse
|* into a single arm with multiple match values. Bodies fall through C-style
|* until a `break` or the end of the switch is reached.
|* @return  An XTSwitchNode.
\****************************************************************************/
- (nullable XTASTNode*)parseSwitch
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'switch'
    [self expect:XTTokenLParen];
    XTASTNode* subject = [self parseExpression];
    [self expect:XTTokenRParen];

    if (![self checkBlockOpen])
        {
        [_diagnostics emitError:@"expected '{' or '((' after switch (...)" at:[self currentLocation]];
        return nil;
        }
    XTSourceLocation* blockLoc = [self currentLocation];
    [self advance]; // consume '{' or '(('

    NSMutableArray<XTSwitchCase*>* cases = [NSMutableArray array];
    NSMutableArray<XTCaseLabel*>* pendingLabels = [NSMutableArray array];
    NSMutableArray<XTASTNode*>* pendingBody = [NSMutableArray array];
    BOOL pendingIsDefault = NO;
    BOOL haveOpenArm = NO;
    XTSourceLocation* armLoc = nil;

    while ((self.pwPending || (![self checkBlockClose] && ![self check:XTTokenEOF])) && !_diagnostics.hasFatalError)
        {
        if (!self.pwPending && ([self check:XTTokenCase] || [self check:XTTokenDefault]))
            {
            // If the current arm has accumulated body statements, close
            // it before opening a new one — a `case`/`default` after
            // body statements starts a fresh arm (no fall-through label
            // collapsing across statements).
            if (haveOpenArm && pendingBody.count > 0)
                {
                [cases addObject:[[XTSwitchCase alloc] initWithLabels:pendingLabels
                                                                 body:pendingBody
                                                            isDefault:pendingIsDefault
                                                             location:armLoc]];
                pendingLabels = [NSMutableArray array];
                pendingBody = [NSMutableArray array];
                pendingIsDefault = NO;
                haveOpenArm = NO;
                }
            if (!haveOpenArm)
                {
                armLoc = [self currentLocation];
                haveOpenArm = YES;
                }
            if ([self match:XTTokenCase])
                {
                XTSourceLocation* labelLoc = [self currentLocation];
                XTCaseLabel* label = nil;
                if ([self check:XTTokenDotDot])
                    {
                    // `case ..hi:` — unbounded low, bounded high.
                    [self advance]; // consume ..
                    XTASTNode* hi = [self parseExpression];
                    label = [[XTCaseLabel alloc] initWithRangeLo:nil rangeHi:hi location:labelLoc];
                    }
                else
                    {
                    XTASTNode* lo = [self parseExpression];
                    if ([self match:XTTokenDotDot])
                        {
                        // `case lo..hi:` or `case lo..:`.
                        if ([self check:XTTokenColon])
                            {
                            label = [[XTCaseLabel alloc] initWithRangeLo:lo rangeHi:nil location:labelLoc];
                            }
                        else
                            {
                            XTASTNode* hi = [self parseExpression];
                            label = [[XTCaseLabel alloc] initWithRangeLo:lo rangeHi:hi location:labelLoc];
                            }
                        }
                    else if (lo)
                        {
                        label = [[XTCaseLabel alloc] initWithSingleValue:lo location:labelLoc];
                        }
                    }
                if (label)
                    [pendingLabels addObject:label];
                [self expect:XTTokenColon];
                }
            else
                {
                [self advance]; // consume 'default'
                pendingIsDefault = YES;
                [self expect:XTTokenColon];
                }
            continue;
            }
        if (!haveOpenArm)
            {
            [_diagnostics emitError:@"statement before first 'case' in switch body"
                                 at:[self currentLocation]];
            // Skip the offending statement so we don't infinite-loop.
            (void)[self parseStatement];
            continue;
            }
        XTASTNode* stmt = [self parseListStatement];
        if (stmt)
            [pendingBody addObject:stmt];
        }

    if (haveOpenArm)
        {
        [cases addObject:[[XTSwitchCase alloc] initWithLabels:pendingLabels
                                                         body:pendingBody
                                                    isDefault:pendingIsDefault
                                                     location:armLoc]];
        }

    (void)blockLoc;
    [self expectBlockClose];
    return [[XTSwitchNode alloc] initWithSubject:subject cases:cases location:loc];
    }

/****************************************************************************\
|* A for loop's optional annotations, after its `)`: `: unroll`, and from the
|* 0.72 `: goal(speed)` / `: goal(accuracy)`, comma-separated.
|* @return  1 for unroll, 2 for goal(speed), 4 for goal(accuracy), or'd.
\****************************************************************************/
- (NSUInteger)parseLoopAnnotations
    {
    NSUInteger annots = 0;
    if (![self match:XTTokenColon])
        return annots;
    while ([self check:XTTokenIdentifier])
        {
        XTToken* tok = [self advance];
        // Lower case only, as documented and as the port and the auto scan
        // read them: `: Serial` is an unknown annotation.
        NSString* annotName = tok.value;
        if ([annotName isEqualToString:@"unroll"])
            {
            annots |= 1;
            }
        else if ([annotName isEqualToString:@"serial"])
            {
            // --par-style=auto leaves this loop alone (parAutoScan reads it from
            // the tokens); otherwise it means nothing. 32: XTSrcSerial.
            annots |= 8 | 32;
            }
        else if ([annotName isEqualToString:@"goal"])
            {
            annots |= 16; // written on the loop (XTSrcGoal)
            [self expect:XTTokenLParen];
            XTToken* g = [self check:XTTokenIdentifier] ? [self advance] : nil;
            if ([g.value isEqualToString:@"speed"])
                annots = (annots & ~(NSUInteger)4) | 2;
            else if ([g.value isEqualToString:@"accuracy"])
                annots = (annots & ~(NSUInteger)2) | 4;
            else
                [_diagnostics emitError:[NSString stringWithFormat:@"':goal' takes speed or accuracy, not '%@'",
                                                                   g.value ?: @""]
                                     at:g ? g.location : tok.location];
            [self expect:XTTokenRParen];
            }
        else
            {
            annots |= 64; // XTSrcAnnot
            [_diagnostics emitWarning:[NSString stringWithFormat:@"Unknown loop annotation '%@'", tok.value]
                             category:XTWarnUnknownAnnotation
                                   at:tok.location];
            }
        if (![self match:XTTokenComma])
            break;
        }
    return annots;
    }

/****************************************************************************\
|* Parse a for loop: either for-in (`for (type? var in collection)`) or
|* C-style (`for (init; cond; incr)`). Supports optional `: unroll` annotation.
|* @return  An XTForInNode or XTForCStyleNode.
\****************************************************************************/
- (nullable XTASTNode*)parseFor
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'for'
    [self expect:XTTokenLParen];

    // Determine: for-in or C-style
    // for-in: (type? IDENT 'in' ...) — look ahead for 'in' keyword
    NSUInteger savedPos = _pos;
    BOOL isForIn = NO;

    // Try to detect for-in pattern
    if ([self currentToken].isTypeKeyword || [_typeTable isTypeName:[self currentToken].value])
        {
        [self parseTypeListLookahead];
        if ([self check:XTTokenIdentifier] && [[self peekToken:1] type] == XTTokenIn)
            {
            isForIn = YES;
            }
        }
    else if ([self check:XTTokenIdentifier] && [[self peekToken:1] type] == XTTokenIn)
        {
        isForIn = YES;
        }
    _pos = savedPos;

    if (isForIn)
        {
        XTType* loopType = nil;
        if ([self currentToken].isTypeKeyword || [_typeTable isTypeName:[self currentToken].value])
            {
            loopType = [self parseType];
            }
        XTToken* loopVarName = [self expect:XTTokenIdentifier];
        NSUInteger inAt = _pos;
        [self expect:XTTokenIn];
        XTASTNode* collection = [self parseExpression];

        // Range form: `for (T? i in start..end)` or `... start...end`.
        // The `..` token isn't a binary operator in the expression
        // grammar (same way it isn't inside `case lo..hi:`), so
        // parseExpression stops at it and we pick up the rest here.
        // Rewrite to an equivalent C-style for so sema and codegen
        // see only the existing loop shape:
        //   for (T i in 0..N)            →  for (T i = 0; i <  N; i += 1)
        //   for (T i in 0...N)           →  for (T i = 0; i <= N; i += 1)
        //   for (T i in 0..N step 2)     →  for (T i = 0; i <  N; i += 2)
        //   for (T i in N..0)            →  for (T i = N; i >  0; i -= 1)   (literal-bounds auto-flip)
        //   for (T i in N..0 step -2)    →  for (T i = N; i >  0; i -= 2)
        // Direction:
        //   - explicit `step <neg>` → descending
        //   - else literal bounds with start > end → descending
        //   - else ascending
        // Inconsistent combos (e.g. `0..10 step -1`) emit a parse
        // error since the body would never run; the user almost
        // certainly mistyped one or the other.
        if ([self check:XTTokenDotDot] || [self check:XTTokenEllipsis])
            {
            BOOL isInclusive = [self check:XTTokenEllipsis];
            [self advance]; // consume .. or ...
            XTASTNode* startExpr = collection;
            XTASTNode* endExpr = [self parseExpression];

            // Optional `step <signed-int-literal>` clause. `step` is a
            // contextual identifier — never reserved globally, so a
            // user variable named `step` outside this position keeps
            // working. Step must constant-fold to a signed integer at
            // parse time; non-literal step is rejected so the
            // direction can be decided here.
            int64_t stepValue = 0;
            BOOL stepExplicit = NO;
            BOOL stepBad = NO;
            if ([self check:XTTokenIdentifier] &&
                [[self currentToken].value isEqualToString:@"step"])
                {
                [self advance]; // consume `step`
                stepBad = ![self check:XTTokenIntLiteral] || [[self currentToken].value isEqualToString:@"0"];
                XTASTNode* stepNode = [self parseExpression];
                int64_t sv = 0;
                BOOL ok = NO;
                if ([stepNode isKindOfClass:[XTLiteralIntNode class]])
                    {
                    sv = ((XTLiteralIntNode*)stepNode).intValue;
                    ok = YES;
                    }
                else if ([stepNode isKindOfClass:[XTUnaryExprNode class]] &&
                         ((XTUnaryExprNode*)stepNode).op == XTUnaryOpNeg &&
                         [((XTUnaryExprNode*)stepNode).operand
                             isKindOfClass:[XTLiteralIntNode class]])
                    {
                    sv = -((XTLiteralIntNode*)((XTUnaryExprNode*)stepNode).operand).intValue;
                    ok = YES;
                    }
                if (!ok)
                    {
                    [_diagnostics emitError:
                                      @"for-in range step must be a compile-time integer literal (e.g. `step 2`, `step -1`)"
                                         at:loc];
                    sv = 1; // recover
                    }
                if (sv == 0)
                    {
                    [_diagnostics emitError:
                                      @"for-in range step cannot be zero — the loop would never make progress"
                                         at:loc];
                    sv = 1; // recover
                    }
                stepValue = sv;
                stepExplicit = YES;
                }
            [self expect:XTTokenRParen];
            NSUInteger rangeAnnots = [self parseLoopAnnotations];
            NSUInteger rangeGoal = [self loopGoal:rangeAnnots];
            // The loop variable is a local of the body: a block literal or a
            // `par` inside it captures it like any other.
            [self blkPushScope];
            if (loopVarName)
                [self blkBind:loopVarName.value type:loopType];
            NSUInteger savedGoal = self.goalNow;
            self.goalNow = rangeGoal;
            XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];
            self.goalNow = savedGoal;
            [self blkPopScope];

            // Direction decision. Resolve the four cases:
            //   stepExplicit          → direction = sign(stepValue)
            //   else literal bounds   → direction from start vs end
            //   else                  → ascending (default +1)
            BOOL bothBoundsLiteral =
                [startExpr isKindOfClass:[XTLiteralIntNode class]] &&
                [endExpr isKindOfClass:[XTLiteralIntNode class]];
            int64_t lowLit = bothBoundsLiteral ? ((XTLiteralIntNode*)startExpr).intValue : 0;
            int64_t hiLit = bothBoundsLiteral ? ((XTLiteralIntNode*)endExpr).intValue : 0;
            BOOL isDescending = NO;
            if (stepExplicit)
                {
                isDescending = (stepValue < 0);
                // Validate direction consistency with literal bounds.
                if (bothBoundsLiteral)
                    {
                    BOOL boundsAscending = (lowLit < hiLit) ||
                                           (isInclusive && lowLit == hiLit);
                    BOOL boundsDescending = (lowLit > hiLit) ||
                                            (isInclusive && lowLit == hiLit);
                    if (isDescending && !boundsDescending)
                        {
                        [_diagnostics emitError:
                                          @"for-in range with negative step requires start >= end (start > end for `..`); the loop body would never run"
                                             at:loc];
                        }
                    else if (!isDescending && !boundsAscending)
                        {
                        [_diagnostics emitError:
                                          @"for-in range with positive step requires start <= end (start < end for `..`); the loop body would never run"
                                             at:loc];
                        }
                    }
                }
            else if (bothBoundsLiteral && lowLit > hiLit)
                {
                // Auto-flip: `for (i in 10..0)` — descending, step -1.
                isDescending = YES;
                stepValue = -1;
                }
            else
                {
                // Default: ascending, step +1.
                stepValue = 1;
                }

            // Default loop var type to u8 when both bounds are
            // u8-valued integer literals (and stepValue's magnitude
            // also fits the iteration). Anything else requires an
            // explicit type — the parser doesn't run sema's full
            // constant-folding, so we stay surface-level here.
            if (!loopType)
                {
                int64_t mag = stepValue < 0 ? -stepValue : stepValue;
                BOOL bothU8Literals = bothBoundsLiteral &&
                                      lowLit >= 0 && lowLit <= 255 &&
                                      hiLit >= 0 && hiLit <= 255 &&
                                      mag <= 255;
                if (bothU8Literals)
                    {
                    loopType = [_typeTable scalarTypeForKeyword:@"u8"] ?: [XTType u8Type];
                    }
                else
                    {
                    [_diagnostics emitError:
                                      @"for-in range loop variable needs an explicit type when bounds aren't u8 literals (e.g. `for (u16 i in 0..1000)`)"
                                         at:loc];
                    loopType = [_typeTable scalarTypeForKeyword:@"u16"] ?: [XTType u16Type];
                    }
                }

            // Synthesise the equivalent C-style for. Comparison op
            // depends on direction × inclusive:
            //   asc exclusive  →  i <  end
            //   asc inclusive  →  i <= end
            //   desc exclusive →  i >  end
            //   desc inclusive →  i >= end
            // Increment uses += for positive step, -= for negative
            // (so the codegen sees a clean unsigned-magnitude rhs).
            NSString* vname = loopVarName ? loopVarName.value : @"_";
            XTVariableDeclNode* initDecl =
                [[XTVariableDeclNode alloc] initWithName:vname
                                                    type:loopType
                                             initialiser:startExpr
                                                location:loc];
            XTIdentifierNode* condRef =
                [[XTIdentifierNode alloc] initWithName:vname
                                              location:loc];
            XTBinaryOp condOp;
            if (isDescending)
                condOp = isInclusive ? XTBinaryOpGe : XTBinaryOpGt;
            else
                condOp = isInclusive ? XTBinaryOpLe : XTBinaryOpLt;
            XTBinaryExprNode* cond =
                [[XTBinaryExprNode alloc] initWithOp:condOp
                                                left:condRef
                                               right:endExpr
                                            location:loc];
            XTIdentifierNode* incrLhs =
                [[XTIdentifierNode alloc] initWithName:vname
                                              location:loc];
            int64_t mag = stepValue < 0 ? -stepValue : stepValue;
            XTLiteralIntNode* stepLit =
                [[XTLiteralIntNode alloc] initWithValue:mag
                                               location:loc];
            XTAssignExprNode* incr =
                [[XTAssignExprNode alloc] initWithOp:(isDescending
                                                          ? XTAssignOpSub
                                                          : XTAssignOpAdd)
                                                 lhs:incrLhs
                                                 rhs:stepLit
                                            location:loc];
            XTForCStyleNode* rangeNode = [[XTForCStyleNode alloc] initWithLoopInit:initDecl
                                                                         condition:cond
                                                                         increment:incr
                                                                              body:body
                                                                          location:loc];
            rangeNode.forceUnroll = (rangeAnnots & 1) != 0;
            rangeNode.goal = rangeGoal;
            rangeNode.srcFacts |= XTSrcRange | [self parAutoLoopFacts:rangeAnnots];
            if (stepBad)
                rangeNode.srcFacts |= XTSrcStepBad;
            if ([self parAutoDescends:inAt])
                rangeNode.srcFacts |= XTSrcDesc;
            return rangeNode;
            }

        [self expect:XTTokenRParen];
        // The loop variable is a local of the body: a block literal or a
        // `par` inside it captures it like any other.
        [self blkPushScope];
        if (loopVarName)
            [self blkBind:loopVarName.value type:loopType];
        XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];
        [self blkPopScope];

        XTVariableDeclNode* loopVar = [[XTVariableDeclNode alloc] initWithName:loopVarName ? loopVarName.value : @"_"
                                                                          type:loopType
                                                                   initialiser:nil
                                                                      location:loc];
        XTForInNode* fi = [[XTForInNode alloc] initWithLoopVar:loopVar collection:collection body:body location:loc];
        fi.goal = [self loopGoal:0];
        return fi;
        }

    // C-style for
    XTASTNode* init = nil;
    if (![self check:XTTokenSemicolon])
        {
        if ([self currentToken].isTypeKeyword || [_typeTable isTypeName:[self currentToken].value])
            {
            XTType* t = [self parseType];
            XTToken* n = [self expect:XTTokenIdentifier];
            XTASTNode* iv = nil;
            if ([self match:XTTokenAssign])
                iv = [self parseInitialiser];
            init = [[XTVariableDeclNode alloc] initWithName:n ? n.value : @"_" type:t initialiser:iv location:loc];
            }
        else
            {
            init = [self parseExpression];
            }
        }
    [self expect:XTTokenSemicolon];
    // The loop variable is a local of the loop, from its condition on: bound
    // before the condition and the step are parsed, so `t < n` and `t++` name
    // it and not an outer `t` it shadows (a `par` made of the loop took the
    // outer String t for a captured scalar the loop assigned). A block
    // literal or a `par` inside the body captures it like any other. As the
    // port, which binds a declaration where it is parsed.
    [self blkPushScope];
    if ([init isKindOfClass:[XTVariableDeclNode class]])
        [self blkBind:((XTVariableDeclNode*)init).varName type:((XTVariableDeclNode*)init).declaredType];
    XTASTNode* cond = [self check:XTTokenSemicolon] ? nil : [self parseExpression];
    [self expect:XTTokenSemicolon];
    XTASTNode* incr = [self check:XTTokenRParen] ? nil : [self parseExpression];
    [self expect:XTTokenRParen];

    NSUInteger annots = [self parseLoopAnnotations];
    NSUInteger goal = [self loopGoal:annots];

    NSUInteger savedGoal = self.goalNow;
    self.goalNow = goal;
    XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];
    self.goalNow = savedGoal;
    [self blkPopScope];

    XTForCStyleNode* node = [[XTForCStyleNode alloc] initWithLoopInit:init condition:cond increment:incr body:body location:loc];
    node.forceUnroll = (annots & 1) != 0;
    node.goal = goal;
    node.srcFacts |= [self parAutoLoopFacts:annots];
    return node;
    }

/****************************************************************************\
|* Parse a return statement with zero or more comma-separated return values.
|* @return  An XTReturnNode containing the return value expressions.
\****************************************************************************/
- (nullable XTASTNode*)parseReturn
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'return'
    NSMutableArray<XTASTNode*>* values = [NSMutableArray array];
    if (![self check:XTTokenSemicolon])
        {
        [values addObject:[self parseExpression]];
        while ([self match:XTTokenComma])
            {
            [values addObject:[self parseExpression]];
            }
        }
    // v2 (task #29): a block carrying `block:` captures writes back into
    // THIS frame — returning it hands the caller a write into a dead frame.
    for (XTASTNode* v in values)
        {
        if ([self blkIsWbValue:v])
            {
            [_diagnostics emitError:@"a block with `block:` captures cannot "
                                    @"be returned — its write-back targets this frame. Write "
                                    @"results into an object (an ivar, a box) instead"
                                 at:loc];
            }
        }
    [self expect:XTTokenSemicolon];
    return [[XTReturnNode alloc] initWithValues:values location:loc];
    }

/****************************************************************************\
|* Disambiguate `delete <expr>;` (refop, single operand expression) from
|* `delete(args)` (call to a user-defined free function named `delete` /
|* `retain` / `release`). Returns YES when the call-site shape is
|* unambiguously a function call.
|*
|* Heuristic: scan from `delete` through the matching `)`. If the
|* contents are empty (`delete()`) or contain a top-level comma
|* (`delete(a, b)`) the refop interpretation can't fit — refop's
|* operand is a single expression and xtc doesn't have a comma
|* operator. Single-arg `delete(x);` stays as a refop to preserve
|* existing fixtures like `delete (Box@)0;` (cast in parens) — users
|* who define a single-arg free function named `delete` should rename
|* it or invoke via `inline:delete(x)` (forces parsePrimary's refop-
|* keyword-as-identifier branch).
\****************************************************************************/
- (BOOL)looksLikeRefopFunctionCall
    {
    // Token 0 = the refop keyword. Token 1 must be `(`.
    if ([self peekToken:1].type != XTTokenLParen)
        return NO;

    // Walk the token stream from position+2 to the matching `)`.
    // Track paren depth and watch for a top-level `,`.
    NSUInteger depth = 1;
    NSUInteger pos = self.pos + 2;
    if (pos < self.tokens.count &&
        [self.tokens[pos] type] == XTTokenRParen)
        {
        return YES; // empty args list — must be a call
        }
    BOOL sawTopComma = NO;
    while (pos < self.tokens.count && depth > 0)
        {
        XTTokenType t = [self.tokens[pos] type];
        if (t == XTTokenLParen)
            depth++;
        else if (t == XTTokenRParen)
            depth--;
        else if (t == XTTokenComma && depth == 1)
            {
            sawTopComma = YES;
            }
        else if (t == XTTokenSemicolon || t == XTTokenEOF)
            return NO;
        pos++;
        }
    return sawTopComma;
    }

/****************************************************************************\
|* Parse a refcount statement: `delete <expr>;`, `retain <expr>;`, or
|* `release <expr>;`. All three share the same AST shape (XTDeleteNode)
|* differentiated by the `op` discriminator. Sema validates the operand
|* resolves to a heap-allocated pointer and that -falloc=heap is active.
\****************************************************************************/
- (nullable XTASTNode*)parseRefOp:(XTRefOp)op
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'delete' / 'retain' / 'release'
    XTASTNode* operand = [self parseExpression];
    [self expect:XTTokenSemicolon];
    return [[XTDeleteNode alloc] initWithOperand:operand op:op location:loc];
    }

/****************************************************************************\
|* Parse an inline assembly block: `asm { ... }` with optional trailing
|* `: clobbers(A, X, Y)` annotation. Reconstructs assembly lines from the
|* token stream, preserving `#` and `.` adjacency for 6502 syntax.
|* @return  An XTAsmBlockNode with the reconstructed lines and clobber mask.
\****************************************************************************/
- (nullable XTASTNode*)parseAsmBlock
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume 'asm'
    [self expectBlockOpen];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    // Collect lines until block close — we need raw text
    // Because the lexer tokenised everything, we reconstruct from tokens
    NSMutableString* currentLine = [NSMutableString string];
    NSUInteger prevLine = [self currentToken].location.line;

    while (![self checkBlockClose] && ![self check:XTTokenEOF])
        {
        XTToken* tok = [self advance];
        NSUInteger curLine = tok.location.line;
        if (curLine != prevLine && currentLine.length > 0)
            {
            [lines addObject:[currentLine copy]];
            [currentLine setString:@""];
            prevLine = curLine;
            }
        // Don't insert space after '#' (6502 immediate prefix) or before/after
        // byte-extraction operators when they are adjacent to operands.
        // Also suppress space after '.' so dot-prefixed local labels
        // like `.loop` and `.done` survive reconstruction — without
        // this the token stream emits `. loop` and the assembler
        // fails to resolve the label. And suppress space BEFORE
        // a comma so indexed addressing modes like `LDA tab,Y`
        // survive token round-trip — xta's symbol parser greedily
        // absorbs trailing whitespace and a comma into the symbol
        // name otherwise, breaking reference resolution.
        BOOL suppressSpace = NO;
        if (currentLine.length > 0)
            {
            unichar lastChar = [currentLine characterAtIndex:currentLine.length - 1];
            if (lastChar == '#' || lastChar == '.' || lastChar == ',' ||
                lastChar == '+')
                {
                suppressSpace = YES;
                }
            }
        if (tok.value.length > 0)
            {
            unichar firstCh = [tok.value characterAtIndex:0];
            if (firstCh == ',' || firstCh == '+')
                suppressSpace = YES;
            }
        if (currentLine.length > 0 && !suppressSpace)
            [currentLine appendString:@" "];
        [currentLine appendString:tok.value];
        prevLine = curLine;
        }
    if (currentLine.length > 0)
        [lines addObject:[currentLine copy]];
    [self expectBlockClose];

    XTAsmBlockNode* block = [[XTAsmBlockNode alloc] initWithLines:lines location:loc];

    // Optional `: clobbers(A, X, Y)` annotation. Parsed as a bitmask
    // (bit 0 = A, 1 = X, 2 = Y). The codegen scans the block to
    // compute what it actually touches and warns if the declared
    // set is a strict subset of the computed set — that way a
    // typo like `clobbers(X)` over a `LDY`-containing block is
    // caught at compile time instead of silently corrupting an
    // outer loop.
    if ([self check:XTTokenColon])
        {
        XTToken* next = [self peekToken:1];
        if (next && next.type == XTTokenIdentifier &&
            [next.value isEqualToString:@"clobbers"])
            {
            [self advance]; // consume ':'
            [self advance]; // consume 'clobbers'
            [self expect:XTTokenLParen];
            NSInteger mask = 0;
            BOOL first = YES;
            while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
                {
                if (!first)
                    [self expect:XTTokenComma];
                first = NO;
                XTToken* regTok = [self advance];
                if (regTok.type != XTTokenIdentifier || regTok.value.length != 1)
                    {
                    [_diagnostics emitError:@"clobbers() expects A, X or Y"
                                         at:regTok.location];
                    break;
                    }
                unichar r = [[regTok.value uppercaseString] characterAtIndex:0];
                if (r == 'A')
                    mask |= 0x1;
                else if (r == 'X')
                    mask |= 0x2;
                else if (r == 'Y')
                    mask |= 0x4;
                else
                    {
                    [_diagnostics emitError:[NSString stringWithFormat:
                                                          @"clobbers() expects A, X or Y, got '%@'", regTok.value]
                                         at:regTok.location];
                    }
                }
            [self expect:XTTokenRParen];
            block.userClobbers = mask;
            }
        }

    return block;
    }

/****************************************************************************\
|* Lookahead test: does the current position look like a tuple assignment
|* `(targets...) = expr;`?  Scans past the parenthesised target list to
|* check for '='. Does not consume tokens.
|* @return  YES if the pattern matches a tuple assignment.
\****************************************************************************/
- (BOOL)looksLikeTupleAssign
    {
    // ( [type?] IDENT, ... ) =
    NSUInteger savedPos = _pos;
    [self advance]; // skip (
    while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
        {
        [self advance];
        }
    [self advance]; // skip )
    BOOL result = [self check:XTTokenAssign];
    _pos = savedPos;
    return result;
    }

/****************************************************************************\
|* Parse a tuple assignment: `(type? var1, type? var2, ...) = expr;`.
|* Targets can be new variable declarations (with type) or existing identifiers.
|* @return  An XTTupleAssignNode.
\****************************************************************************/
- (nullable XTASTNode*)parseTupleAssign
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume '('
    NSMutableArray<XTASTNode*>* targets = [NSMutableArray array];

    while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
        {
        // Optional type followed by name
        if ([self currentToken].isTypeKeyword || [_typeTable isTypeName:[self currentToken].value])
            {
            XTType* t = [self parseType];
            XTToken* n = [self expect:XTTokenIdentifier];
            if (n)
                {
                [targets addObject:[[XTVariableDeclNode alloc] initWithName:n.value type:t initialiser:nil location:n.location]];
                }
            }
        else
            {
            XTToken* n = [self expect:XTTokenIdentifier];
            if (n)
                {
                // Read as a token, not as a name: no capture (pfwNode).
                XTASTNode* tn = [[XTIdentifierNode alloc] initWithName:n.value location:n.location];
                tn.srcFacts |= XTSrcSynth;
                [targets addObject:tn];
                }
            }
        [self match:XTTokenComma];
        }
    [self expect:XTTokenRParen];
    [self expect:XTTokenAssign];
    XTASTNode* source = [self parseExpression];
    [self expect:XTTokenSemicolon];
    // A declared target is a local of the enclosing block from here on, as a
    // plain declaration is once its initialiser has been parsed: a block or
    // `par` body that reads it captures it, which needs the binding.
    for (XTASTNode* t in targets)
        if ([t isKindOfClass:[XTVariableDeclNode class]])
            [self blkBind:((XTVariableDeclNode*)t).varName type:((XTVariableDeclNode*)t).declaredType];
    return [[XTTupleAssignNode alloc] initWithTargets:targets sourceExpr:source location:loc];
    }

// Methods moved to XTParser+ExprParser.m / .h
@end
