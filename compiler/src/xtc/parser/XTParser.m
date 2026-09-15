#import "XTParser+Private.h"

// C reserved words that may not be used as variable names
static NSSet<NSString*>* sCReservedWords = nil;

@implementation XTParser

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
    [self prescanForwardTypeDeclarations];

    while (![self check:XTTokenEOF] && !_diagnostics.hasFatalError)
        {
        XTASTNode* decl = [self parseTopLevelDeclaration];
        if (decl)
            [decls addObject:decl];
        }

    // Blocks (task #26): the per-signature base classes (sorted by name)
    // and the per-literal impl classes (in creation order) join the
    // program here, as ordinary class declarations.
    [decls addObjectsFromArray:[self blkSynthesisedDeclsAt:loc]];

    return [[XTProgramNode alloc] initWithDeclarations:decls location:loc];
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
    if (cur.type == XTTokenUse)
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
    NSUInteger blkIvarMark = [self blkIvarNames].count;
    (void)blkIvarMark;

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
                [[self blkIvarNames] addObject:((XTVariableDeclNode*)decl).varName];
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
                        [[self blkIvarNames] addObject:((XTVariableDeclNode*)inner).varName];
                        }
                    }
                }
            }
        }

    [self blkPopScope]; // task #26
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
    [self expectBlockOpen];
    NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];
    while (![self checkBlockClose] && ![self check:XTTokenEOF])
        {
        // `optional bool windowShouldClose(...)` — a method a conforming
        // class may omit, leaving its vtable slot 0.
        BOOL isOptional = [self match:XTTokenOptional];
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
        if (!([self currentToken].isTypeKeyword ||
              [_typeTable isTypeName:[self currentToken].value]))
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
        firstInit = [self parseInitialiser];
        }
    XTVariableDeclNode* firstDecl = [[XTVariableDeclNode alloc] initWithName:firstName
                                                                        type:varType
                                                                 initialiser:firstInit
                                                                    location:loc];
    firstDecl.isGlobal = topLevel;
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
            nextInit = [self parseInitialiser];
            }
        XTVariableDeclNode* nextDecl = [[XTVariableDeclNode alloc] initWithName:nextName.value
                                                                           type:varType
                                                                    initialiser:nextInit
                                                                       location:nextName.location];
        nextDecl.isGlobal = topLevel;
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
        body = [self parseBlock];
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
           [kw isEqualToString:@"weak"] || [kw isEqualToString:@"outlet"];
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
        base = [XTPointerType pointerToType:base
                                  placement:p
                                     isWeak:weakThisLevel];
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

    while (![self checkBlockClose] && ![self check:XTTokenEOF] && !_diagnostics.hasFatalError)
        {
        XTASTNode* stmt = [self parseStatement];
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

/****************************************************************************\
|* Parse a single statement: if, while, for, return, break, continue, asm,
|* block, typedef, struct, enum, variable declaration, tuple assignment,
|* or expression statement.
|* @return  The parsed statement AST node, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseStatement
    {
    XTToken* cur = [self currentToken];

    switch (cur.type)
        {
    case XTTokenIf:
        return [self parseIf];
    case XTTokenWhile:
        return [self parseWhile];
    case XTTokenFor:
        return [self parseFor];
    case XTTokenSwitch:
        return [self parseSwitch];
    case XTTokenReturn:
        return [self parseReturn];
    case XTTokenBreak:
        {
        [self advance];
        [self expect:XTTokenSemicolon];
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
        if (isVarDecl && [_typeTable isTypeName:cur.value] && _pos + 1 < _tokens.count)
            {
            XTToken* next = _tokens[_pos + 1];
            if (next.type == XTTokenDot)
                isVarDecl = NO; // ClassName.method() — not a declaration
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
            firstInit = [self parseInitialiser];
            }
        [self blkBind:nameTok.value type:varType];
        }
    else if ([self match:XTTokenAssign])
        {
        firstInit = [self parseInitialiser];
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
            nextInit = [self parseInitialiser];
            }
        XTVariableDeclNode* nextDecl = [[XTVariableDeclNode alloc] initWithName:nextName.value
                                                                           type:varType
                                                                    initialiser:nextInit
                                                                       location:nextName.location];
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
    return [[XTWhileNode alloc] initWithCondition:cond body:body location:loc];
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

    while (![self checkBlockClose] && ![self check:XTTokenEOF] && !_diagnostics.hasFatalError)
        {
        if ([self check:XTTokenCase] || [self check:XTTokenDefault])
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
        XTASTNode* stmt = [self parseStatement];
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
            if ([self check:XTTokenIdentifier] &&
                [[self currentToken].value isEqualToString:@"step"])
                {
                [self advance]; // consume `step`
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
            XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];

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
            return [[XTForCStyleNode alloc] initWithLoopInit:initDecl
                                                   condition:cond
                                                   increment:incr
                                                        body:body
                                                    location:loc];
            }

        [self expect:XTTokenRParen];
        XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];

        XTVariableDeclNode* loopVar = [[XTVariableDeclNode alloc] initWithName:loopVarName ? loopVarName.value : @"_"
                                                                          type:loopType
                                                                   initialiser:nil
                                                                      location:loc];
        return [[XTForInNode alloc] initWithLoopVar:loopVar collection:collection body:body location:loc];
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
    XTASTNode* cond = [self check:XTTokenSemicolon] ? nil : [self parseExpression];
    [self expect:XTTokenSemicolon];
    XTASTNode* incr = [self check:XTTokenRParen] ? nil : [self parseExpression];
    [self expect:XTTokenRParen];

    // Optional annotations: ": unroll[, ...]"
    BOOL forceUnroll = NO;
    if ([self match:XTTokenColon])
        {
        while ([self check:XTTokenIdentifier])
            {
            XTToken* tok = [self advance];
            NSString* annotName = tok.value.lowercaseString;
            if ([annotName isEqualToString:@"unroll"])
                {
                forceUnroll = YES;
                }
            else
                {
                [_diagnostics emitWarning:[NSString stringWithFormat:@"Unknown loop annotation '%@'", tok.value]
                                 category:XTWarnUnknownAnnotation
                                       at:tok.location];
                }
            if (![self match:XTTokenComma])
                break;
            }
        }

    XTASTNode* body = [self checkBlockOpen] ? [self parseBlock] : [self parseStatement];

    XTForCStyleNode* node = [[XTForCStyleNode alloc] initWithLoopInit:init condition:cond increment:incr body:body location:loc];
    node.forceUnroll = forceUnroll;
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
                [targets addObject:[[XTIdentifierNode alloc] initWithName:n.value location:n.location]];
            }
        [self match:XTTokenComma];
        }
    [self expect:XTTokenRParen];
    [self expect:XTTokenAssign];
    XTASTNode* source = [self parseExpression];
    [self expect:XTTokenSemicolon];
    return [[XTTupleAssignNode alloc] initWithTargets:targets sourceExpr:source location:loc];
    }

// Methods moved to XTParser+ExprParser.m / .h
@end
