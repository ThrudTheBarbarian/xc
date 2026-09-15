/****************************************************************************\
|* XTParser+ExprParser.m
\****************************************************************************/
#import "XTParser+Private.h"

@implementation XTParser (ExprParser)

#pragma mark - Expression Parsing (Shunting-Yard + Recursive Descent)

// Precedence levels (higher = tighter binding)
typedef struct
    {
    int prec;
    BOOL rightAssoc;
    } XTOpInfo;

static XTOpInfo operatorInfo(XTTokenType type)
    {
    switch (type)
        {
    case XTTokenAssign:
    case XTTokenPlusAssign:
    case XTTokenMinusAssign:
    case XTTokenStarAssign:
    case XTTokenSlashAssign:
    case XTTokenPercentAssign:
    case XTTokenAmpAssign:
    case XTTokenPipeAssign:
    case XTTokenCaretAssign:
    case XTTokenShlAssign:
    case XTTokenShrAssign:
    case XTTokenRolAssign:
    case XTTokenRorAssign:
        return (XTOpInfo){1, YES};
    case XTTokenQuestion:
        return (XTOpInfo){2, YES};
    case XTTokenLogicalOr:
        return (XTOpInfo){3, NO};
    case XTTokenLogicalAnd:
        return (XTOpInfo){4, NO};
    case XTTokenPipe:
        return (XTOpInfo){5, NO};
    case XTTokenCaret:
        return (XTOpInfo){6, NO};
    case XTTokenAmpersand:
        return (XTOpInfo){7, NO};
    case XTTokenEqual:
    case XTTokenNotEqual:
        return (XTOpInfo){8, NO};
    case XTTokenLess:
    case XTTokenGreater:
    case XTTokenLessEq:
    case XTTokenGreaterEq:
        return (XTOpInfo){9, NO};
    case XTTokenShiftLeft:
    case XTTokenShiftRight:
        return (XTOpInfo){10, NO};
    case XTTokenRotateLeft:
    case XTTokenRotateRight:
        return (XTOpInfo){11, NO};
    case XTTokenPlus:
    case XTTokenMinus:
        return (XTOpInfo){12, NO};
    case XTTokenStar:
    case XTTokenSlash:
    case XTTokenPercent:
        return (XTOpInfo){13, NO};
    default:
        return (XTOpInfo){-1, NO};
        }
    }

/****************************************************************************\
|* Parse a full expression using precedence-climbing (Pratt parsing).
|* @return  The parsed expression AST node, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parseExpression
    {
    return [self parseExprWithMinPrec:0];
    }

/****************************************************************************\
|* Precedence-climbing expression parser. Parses binary operators, ternary,
|* and assignment operators with correct associativity and precedence.
|* @param minPrec  Minimum precedence level to continue parsing operators.
|* @return  The parsed expression AST subtree.
\****************************************************************************/
- (nullable XTASTNode*)parseExprWithMinPrec:(int)minPrec
    {
    XTASTNode* lhs = [self parseUnary];
    if (!lhs)
        return nil;

    while (YES)
        {
        XTToken* op = [self currentToken];
        XTOpInfo info = operatorInfo(op.type);

        // Handle ternary
        if (op.type == XTTokenQuestion && info.prec >= minPrec)
            {
            [self advance];
            XTASTNode* thenExpr = [self parseExpression];
            [self expect:XTTokenColon];
            XTASTNode* elseExpr = [self parseExprWithMinPrec:info.prec];
            lhs = [[XTTernaryExprNode alloc] initWithCondition:lhs thenExpr:thenExpr elseExpr:elseExpr location:op.location];
            continue;
            }

        if (info.prec < minPrec)
            break;

        [self advance]; // consume operator

        // Assignment operators
        if ([op isAssignmentOperator])
            {
            XTAssignOp aop = [self assignOpFromToken:op];
            XTASTNode* rhs;
            // Blocks (task #26): `b = { body };` re-binds a block variable —
            // the bare braces take their whole signature, parameter names
            // included, from the DECLARED type, so nothing is repeated.
            // Only when the LHS is a known block binding; a struct
            // initialiser list keeps its meaning everywhere else.
            NSDictionary* blkInfo = nil;
            if (aop == XTAssignOpAssign && [self check:XTTokenLBrace] && [lhs isKindOfClass:[XTIdentifierNode class]])
                {
                blkInfo = [self blkLookup:((XTIdentifierNode*)lhs).identName
                                    depth:NULL];
                if (getenv("XTC_DEBUG_BLOCKS"))
                    {
                    NSMutableArray* ss = [NSMutableArray array];
                    for (NSDictionary* sc in [self blkScopes])
                        [ss addObject:sc.allKeys.description];
                    fprintf(stderr, "BLKDBG assign lhs=%s info=%s scopes=%s\n",
                            ((XTIdentifierNode*)lhs).identName.UTF8String,
                            blkInfo.description.UTF8String ?: "nil",
                            ss.description.UTF8String);
                    }
                if (!blkInfo[@"base"])
                    blkInfo = nil;
                }
            if (blkInfo)
                {
                NSString* base = blkInfo[@"base"];
                NSArray* sig = [self blkBases][base];
                NSArray* declParams = blkInfo[@"params"] ?: sig[1];
                rhs = [self blkParseLiteralBodyWithBase:base
                                                    ret:sig[0]
                                                 params:declParams
                                               selfName:nil
                                                     at:op.location];
                [self blkMarkHoldsWb:((XTIdentifierNode*)lhs).identName
                            fromInit:rhs]; // task #29
                }
            else
                // Check for struct initialiser list: a = {1, 2, 3, 4};
                if ([self check:XTTokenLBrace] || [self check:XTTokenLBracket])
                    {
                    rhs = [self parseInitialiser];
                    }
                else
                    {
                    rhs = [self parseExprWithMinPrec:info.rightAssoc ? info.prec : info.prec + 1];
                    }
            // v2 (task #29): a write-back block stored through a member or
            // subscript outlives its frame — reject; a plain local binding
            // is tracked instead.
            if ([self blkIsWbValue:rhs])
                {
                if ([lhs isKindOfClass:[XTIdentifierNode class]])
                    {
                    [self blkMarkHoldsWb:((XTIdentifierNode*)lhs).identName
                                fromInit:rhs];
                    }
                else
                    {
                    [self.diagnostics emitError:@"a block with `block:` "
                                                @"captures cannot be stored beyond its frame — its "
                                                @"write-back targets a local slot. Write results "
                                                @"into an object instead"
                                             at:op.location];
                    }
                }
            lhs = [[XTAssignExprNode alloc] initWithOp:aop lhs:lhs rhs:rhs location:op.location];
            continue;
            }

        int nextMinPrec = info.rightAssoc ? info.prec : info.prec + 1;
        XTASTNode* rhs = [self parseExprWithMinPrec:nextMinPrec];
        lhs = [self buildBinaryExpr:op left:lhs right:rhs];
        }

    return lhs;
    }

/****************************************************************************\
|* Map an assignment token type to its corresponding XTAssignOp enum value.
|* @param tok  The assignment operator token.
|* @return  The XTAssignOp value (defaults to XTAssignOpAssign for unknown).
\****************************************************************************/
- (XTAssignOp)assignOpFromToken:(XTToken*)tok
    {
    switch (tok.type)
        {
    case XTTokenAssign:
        return XTAssignOpAssign;
    case XTTokenPlusAssign:
        return XTAssignOpAdd;
    case XTTokenMinusAssign:
        return XTAssignOpSub;
    case XTTokenStarAssign:
        return XTAssignOpMul;
    case XTTokenSlashAssign:
        return XTAssignOpDiv;
    case XTTokenPercentAssign:
        return XTAssignOpMod;
    case XTTokenAmpAssign:
        return XTAssignOpBitAnd;
    case XTTokenPipeAssign:
        return XTAssignOpBitOr;
    case XTTokenCaretAssign:
        return XTAssignOpBitXor;
    case XTTokenShlAssign:
        return XTAssignOpShl;
    case XTTokenShrAssign:
        return XTAssignOpShr;
    case XTTokenRolAssign:
        return XTAssignOpRol;
    case XTTokenRorAssign:
        return XTAssignOpRor;
    default:
        return XTAssignOpAssign;
        }
    }

/****************************************************************************\
|* Construct an XTBinaryExprNode from an operator token and left/right operands.
|* @param op     The binary operator token.
|* @param left   The left-hand operand AST node.
|* @param right  The right-hand operand AST node.
|* @return  A new XTBinaryExprNode.
\****************************************************************************/
- (XTASTNode*)buildBinaryExpr:(XTToken*)op left:(XTASTNode*)left right:(XTASTNode*)right
    {
    XTBinaryOp bop;
    switch (op.type)
        {
    case XTTokenPlus:
        bop = XTBinaryOpAdd;
        break;
    case XTTokenMinus:
        bop = XTBinaryOpSub;
        break;
    case XTTokenStar:
        bop = XTBinaryOpMul;
        break;
    case XTTokenSlash:
        bop = XTBinaryOpDiv;
        break;
    case XTTokenPercent:
        bop = XTBinaryOpMod;
        break;
    case XTTokenAmpersand:
        bop = XTBinaryOpBitAnd;
        break;
    case XTTokenPipe:
        bop = XTBinaryOpBitOr;
        break;
    case XTTokenCaret:
        bop = XTBinaryOpBitXor;
        break;
    case XTTokenShiftLeft:
        bop = XTBinaryOpShl;
        break;
    case XTTokenShiftRight:
        bop = XTBinaryOpShr;
        break;
    case XTTokenRotateLeft:
        bop = XTBinaryOpRol;
        break;
    case XTTokenRotateRight:
        bop = XTBinaryOpRor;
        break;
    case XTTokenLogicalAnd:
        bop = XTBinaryOpLogAnd;
        break;
    case XTTokenLogicalOr:
        bop = XTBinaryOpLogOr;
        break;
    case XTTokenEqual:
        bop = XTBinaryOpEq;
        break;
    case XTTokenNotEqual:
        bop = XTBinaryOpNeq;
        break;
    case XTTokenLess:
        bop = XTBinaryOpLt;
        break;
    case XTTokenGreater:
        bop = XTBinaryOpGt;
        break;
    case XTTokenLessEq:
        bop = XTBinaryOpLe;
        break;
    case XTTokenGreaterEq:
        bop = XTBinaryOpGe;
        break;
    default:
        bop = XTBinaryOpAdd;
        break;
        }
    return [[XTBinaryExprNode alloc] initWithOp:bop left:left right:right location:op.location];
    }

/****************************************************************************\
|* Parse a unary expression: prefix operators (-, ~, !, &, @, ++, --),
|* byte-extraction operators (<, >>>, >>), or fall through to postfix.
|* @return  The parsed unary or postfix expression AST node.
\****************************************************************************/
- (nullable XTASTNode*)parseUnary
    {
    XTToken* cur = [self currentToken];

    // Prefix operators
    if (cur.type == XTTokenMinus)
        {
        [self advance];
        XTASTNode* operand = [self parseUnary];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpNeg operand:operand location:cur.location];
        }
    if (cur.type == XTTokenTilde)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpBitNot operand:[self parseUnary] location:cur.location];
        }
    if (cur.type == XTTokenBang)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpLogNot operand:[self parseUnary] location:cur.location];
        }
    if (cur.type == XTTokenAmpersand)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpAddrOf operand:[self parseUnary] location:cur.location];
        }
    if (cur.type == XTTokenAt || cur.type == XTTokenStar)
        {
        // Prefix `*` is a dereference; infix `*` is multiply. Reaching here at
        // all means prefix position, so there is nothing to disambiguate.
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpDeref operand:[self parseUnary] location:cur.location];
        }
    if (cur.type == XTTokenPlusPlus)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpPreInc operand:[self parseUnary] location:cur.location];
        }
    if (cur.type == XTTokenMinusMinus)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpPreDec operand:[self parseUnary] location:cur.location];
        }
    // Byte-extraction (primarily for asm context but allowed in expressions)
    if (cur.type == XTTokenLess)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpLoByte operand:[self parseUnary] location:cur.location];
        }
    // >>>
    if (cur.type == XTTokenByte3)
        {
        [self advance];
        return [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpByte3 operand:[self parseUnary] location:cur.location];
        }
    // >> used as byte2 extractor — ambiguous; context determines
    if (cur.type == XTTokenByte2)
        {
        // In expression context this is a shift; only byte2 in asm
        // Skip here; falls through to postfix
        }

    return [self parsePostfix];
    }

/****************************************************************************\
|* Parse a primary expression followed by any postfix operators.
|* @return  The parsed postfix expression AST node.
\****************************************************************************/
- (nullable XTASTNode*)parsePostfix
    {
    XTASTNode* base = [self parsePrimary];
    return [self parsePostfixFrom:base];
    }

/****************************************************************************\
|* Parse a chain of postfix operations (++, --, [], ., ->, function call)
|* starting from an already-parsed base expression.
|* @param base  The base expression to apply postfix operators to.
|* @return  The final postfix expression, potentially deeply nested.
\****************************************************************************/
- (nullable XTASTNode*)parsePostfixFrom:(XTASTNode*)base
    {
    if (!base)
        return nil;

    while (YES)
        {
        XTToken* cur = [self currentToken];
        if (cur.type == XTTokenPlusPlus)
            {
            [self advance];
            base = [[XTPostfixExprNode alloc] initWithOp:XTPostfixOpInc operand:base location:cur.location];
            }
        else if (cur.type == XTTokenMinusMinus)
            {
            [self advance];
            base = [[XTPostfixExprNode alloc] initWithOp:XTPostfixOpDec operand:base location:cur.location];
            }
        else if (cur.type == XTTokenLBracket)
            {
            [self advance];
            // Slice form: `arr[m..n]` / `arr[..n]` / `arr[m..]` /
            // `arr[m...n]`. The parser produces an XTSliceExprNode
            // for any subscript that contains `..` or `...`; the
            // bounds either parse to expressions or stay nil for
            // the implicit-edge forms. Plain `arr[i]` keeps the
            // existing single-index XTSubscriptExprNode.
            XTASTNode* startExpr = nil;
            XTASTNode* endExpr = nil;
            BOOL isSlice = NO;
            BOOL inclusive = NO;
            if ([self check:XTTokenDotDot] || [self check:XTTokenEllipsis])
                {
                inclusive = [self check:XTTokenEllipsis];
                [self advance];
                isSlice = YES;
                if (![self check:XTTokenRBracket])
                    {
                    endExpr = [self parseExpression];
                    }
                }
            else
                {
                startExpr = [self parseExpression];
                if ([self check:XTTokenDotDot] || [self check:XTTokenEllipsis])
                    {
                    inclusive = [self check:XTTokenEllipsis];
                    [self advance];
                    isSlice = YES;
                    if (![self check:XTTokenRBracket])
                        {
                        endExpr = [self parseExpression];
                        }
                    }
                }
            [self expect:XTTokenRBracket];
            if (isSlice)
                {
                base = [[XTSliceExprNode alloc] initWithBase:base
                                                   startExpr:startExpr
                                                     endExpr:endExpr
                                                   inclusive:inclusive
                                                    location:cur.location];
                }
            else
                {
                base = [[XTSubscriptExprNode alloc] initWithBase:base index:startExpr location:cur.location];
                }
            }
        else if (cur.type == XTTokenDot)
            {
            [self advance];
            // Accept refop keywords as member names so user-defined
            // `release` / `retain` / `delete` methods can be called
            // through the dot syntax.
            XTTokenType mty = [self currentToken].type;
            XTToken* member = (mty == XTTokenRelease ||
                               mty == XTTokenRetain ||
                               mty == XTTokenDelete)
                                  ? [self currentToken]
                                  : [self expect:XTTokenIdentifier];
            if (mty == XTTokenRelease || mty == XTTokenRetain ||
                mty == XTTokenDelete)
                {
                [self advance];
                }
            if (member)
                base = [[XTMemberAccessNode alloc] initWithBase:base memberName:member.value isArrow:NO location:cur.location];
            }
        else if (cur.type == XTTokenArrow)
            {
            [self advance];
            XTTokenType mty = [self currentToken].type;
            XTToken* member = (mty == XTTokenRelease ||
                               mty == XTTokenRetain ||
                               mty == XTTokenDelete)
                                  ? [self currentToken]
                                  : [self expect:XTTokenIdentifier];
            if (mty == XTTokenRelease || mty == XTTokenRetain ||
                mty == XTTokenDelete)
                {
                [self advance];
                }
            if (member)
                base = [[XTMemberAccessNode alloc] initWithBase:base memberName:member.value isArrow:YES location:cur.location];
            }
        else if (cur.type == XTTokenLParen)
            {
            // Method call on an expression.
            [self match:XTTokenLParen];
            NSArray<XTASTNode*>* args = [self parseArgList];
            [self expect:XTTokenRParen];
            if ([base isKindOfClass:[XTMemberAccessNode class]])
                {
                XTMemberAccessNode* ma = (XTMemberAccessNode*)base;
                base = [self stampFwd:[[XTMethodCallExprNode alloc] initWithReceiver:ma.base
                                                                          methodName:ma.memberName
                                                                           arguments:args
                                                                            location:cur.location]];
                }
            else if ([base isKindOfClass:[XTIdentifierNode class]])
                {
                XTIdentifierNode* ident = (XTIdentifierNode*)base;
                base = [self stampFwd:[[XTCallExprNode alloc] initWithCallee:ident.identName arguments:args location:cur.location]];
                }
            else
                {
                // A callee that is not a name — `tbl[0](5)`, `makeCb()(6)`.
                // The callee EXPRESSION rides on the node; sema types it and
                // decides what kind of call this is. It used to be a call to
                // the literal name `<indirect>`, which then failed as an
                // undeclared function, naming something the user never wrote
                // (private:docs/bugs/074).
                XTCallExprNode* ic =
                    [[XTCallExprNode alloc] initWithCallee:@"<indirect>"
                                                 arguments:args
                                                  location:cur.location];
                ic.calleeExpr = base;
                base = [self stampFwd:ic];
                }
            }
        else
            {
            break;
            }
        }
    return base;
    }

/****************************************************************************\
|* Parse a primary expression: literals (int, float, string, char, bool),
|* `new`, `sizeof`, parenthesised expressions, cast expressions, `inline:`
|* force-inline calls, identifiers, and function calls.
|* @return  The parsed primary expression AST node, or nil on error.
\****************************************************************************/
- (nullable XTASTNode*)parsePrimary
    {
    XTToken* cur = [self currentToken];
    XTSourceLocation* loc = cur.location;

    // inline: funcName(args) or inline:receiver.method(args) — force
    // inline at call site. The trailing call may be either a free
    // function (XTCallExprNode) or a method call (XTMethodCallExprNode);
    // postfix parsing produces the right shape based on whether a `.`
    // followed the identifier.
    if (cur.type == XTTokenInline && self.pos + 1 < self.tokens.count && self.tokens[self.pos + 1].type == XTTokenColon)
        {
        [self advance]; // consume 'inline'
        [self advance]; // consume ':'
        XTASTNode* expr = [self parsePrimary];
        expr = [self parsePostfixFrom:expr];
        if ([expr isKindOfClass:[XTCallExprNode class]])
            {
            ((XTCallExprNode*)expr).forceInline = YES;
            }
        else if ([expr isKindOfClass:[XTMethodCallExprNode class]])
            {
            ((XTMethodCallExprNode*)expr).forceInline = YES;
            }
        return expr;
        }

    switch (cur.type)
        {
    case XTTokenIntLiteral:
        {
        [self advance];
        return [[XTLiteralIntNode alloc] initWithValue:cur.intValue location:loc];
        }
    case XTTokenFloatLiteral:
        {
        [self advance];
        return [[XTLiteralFloatNode alloc] initWithFloatData:cur.floatData location:loc];
        }
    case XTTokenStringLiteral:
        {
        [self advance];
        // ADJACENT STRING LITERALS CONCATENATE, as in C: `"ab" "cd"` is
        // `"abcd"`, and a newline between them makes no difference. Done
        // here rather than in the lexer so the TOKEN STREAM is unchanged —
        // `lexer-diff` compares that, and there is nothing to gain from
        // moving the seam earlier.
        //
        // It earns its keep on long diagnostic strings, which are otherwise
        // a single unbreakable line: the alternative is a source line as
        // wide as the message.
        NSString* joined = cur.value;
        while ([self currentToken].type == XTTokenStringLiteral)
            {
            joined = [joined stringByAppendingString:[self currentToken].value];
            [self advance];
            }
        return [[XTLiteralStringNode alloc] initWithString:joined location:loc];
        }
    case XTTokenCharLiteral:
        {
        [self advance];
        return [[XTLiteralCharNode alloc] initWithChar:(uint8_t)cur.intValue location:loc];
        }
    case XTTokenTrue:
        {
        [self advance];
        return [[XTLiteralBoolNode alloc] initWithBool:YES location:loc];
        }
    case XTTokenFalse:
        {
        [self advance];
        return [[XTLiteralBoolNode alloc] initWithBool:NO location:loc];
        }
    case XTTokenNew:
        {
        [self advance];
        // Type-name: either a keyword type (u8, u16, …) or a user
        // identifier (class or struct name). Anything else is an
        // error.
        XTToken* typeTok = [self currentToken];
        NSString* typeName = nil;
        if (typeTok.isTypeKeyword || typeTok.type == XTTokenIdentifier)
            {
            typeName = typeTok.value;
            [self advance];
            }
        else
            {
            [self expect:XTTokenIdentifier]; // emits the error
            typeName = @"";
            }
        // Optional `[ count ]` for array allocation.
        XTASTNode* countExpr = nil;
        if ([self check:XTTokenLBracket])
            {
            [self advance];
            countExpr = [self parseExpression];
            [self expect:XTTokenRBracket];
            }
        // Optional `( args )` for constructor invocation (classes
        // only — sema rejects for primitives/structs). Absence of
        // parens is allowed for all forms including class with
        // no-arg init.
        NSArray<XTASTNode*>* args = @[];
        if ([self check:XTTokenLParen])
            {
            // match: splits `((` into `(` + `(`; a plain advance would
            // swallow both parens and break e.g. `new Foo((pointer)0)`.
            [self match:XTTokenLParen];
            args = [self parseArgList];
            [self expect:XTTokenRParen];
            }
        return [[XTNewExprNode alloc] initWithClassName:typeName
                                              arguments:args
                                              countExpr:countExpr
                                               location:loc];
        }
    case XTTokenSizeof:
        {
        [self advance];
        [self expect:XTTokenLParen];
        // Could be a type or an expression. A leading qualifier
        // prefix (`main:` / `shadow:` / `banked:` / `weak:`)
        // followed by a type forces the type path —
        // `sizeof(banked:u8@)` is a type query, not an
        // identifier expression.
        // Same disambiguation as a cast, and for the same reason:
        // `sizeof(Klass.method())` is a size-of-an-expression, and the
        // one-token test read `Klass` as the type and then choked on `.`.
        id operand = [self looksLikeCastAhead] ? (id)[self parseType]
                                               : (id)[self parseExpression];
        [self expect:XTTokenRParen];
        return [[XTSizeofExprNode alloc] initWithOperand:operand location:loc];
        }
    case XTTokenLParen:
        {
        [self match:XTTokenLParen];

        // Check for cast expression: (type)expr
        // Also handle qualifier-prefixed types — `(main:u8@)expr`,
        // `(banked:T@)expr`, `(weak:Foo@)expr` etc. A leading
        // `main:` / `shadow:` / `banked:` / `weak:` identifier
        // followed by a type means the cast path, not an
        // expression; the qualifier tags the resulting pointer.
        // A cast is a COMPLETE type followed by `)` — nothing less. Testing
        // only the first token made `(Klass.method())` a cast to `Klass`
        // (see looksLikeCastAhead).
        if ([self looksLikeCastAhead])
            {
            XTType* castType = [self parseType];
            // Failable-cast marker: `(T@ ?) expr`. Consuming a
            // `?` inside the cast parens sets the cast node's
            // isFailable bit; sema rejects it on non-class-
            // pointer casts and codegen emits a null-on-fail
            // runtime class-id check for class-pointer downcasts.
            BOOL failable = NO;
            if ([self check:XTTokenQuestion])
                {
                [self advance];
                failable = YES;
                }
            [self expect:XTTokenRParen];
            XTASTNode* operand = [self parseUnary];
            XTCastExprNode* castNode =
                [[XTCastExprNode alloc] initWithType:castType
                                             operand:operand
                                            location:loc];
            castNode.isFailable = failable;
            return castNode;
            }

        XTASTNode* inner = [self parseExpression];
        [self expect:XTTokenRParen];
        return inner;
        }
    case XTTokenDelete:
    case XTTokenRetain:
    case XTTokenRelease:
        {
        // Refop keywords accepted as identifiers in expression
        // context when followed by `(` — i.e. when the user is
        // calling a free function they defined named `delete` /
        // `retain` / `release`. The statement-level dispatcher
        // already gates on `peekToken == XTTokenLParen`, so by
        // construction we only land here for a function-call
        // shape. parsePostfix's XTTokenLParen branch handles
        // the actual call.
        if ([self peekToken:1].type != XTTokenLParen)
            {
            // Not a function call — emit the same "unexpected
            // token" error a bare refop keyword would produce
            // in expression position.
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"unexpected '%@' in expression", cur.value]
                                     at:loc];
            return nil;
            }
        [self advance];
        [self blkNoteIdentifierUse:cur.value at:loc]; // task #26
        return [[XTIdentifierNode alloc] initWithName:cur.value
                                             location:loc];
        }
    case XTTokenIdentifier:
        {
        // Blocks (task #26): `block [name] RET(params) { body }` in
        // expression position is a literal; it desugars here to the
        // impl class's `mk(…)` call. Gated narrowly — see
        // blkKeywordAhead — so `block` stays usable as a name.
        if ([self blkKeywordAhead])
            {
            XTASTNode* lit = [self blkParseLiteralExpression];
            if (lit)
                return lit;
            return nil;
            }
        [self advance];
        // If followed by '(' it's a function call. Use match: so a merged
        // (( token splits — otherwise f((x)) loses its opening paren.
        if ([self check:XTTokenLParen])
            {
            [self match:XTTokenLParen];

            // C-style `va_arg(ap, TYPE)` sugar: the second
            // argument is a type name, not an expression. Rewrite
            // to the canonical typed intrinsic so the rest of
            // sema / codegen doesn't need to know about the
            // sugar. The typed forms (va_arg_u16, va_arg_double,
            // …) remain the authoritative wire calls.
            if ([cur.value isEqualToString:@"va_arg"])
                {
                NSMutableArray* args = [NSMutableArray array];
                XTASTNode* cursor = [self parseExpression];
                if (cursor)
                    [args addObject:cursor];
                [self expect:XTTokenComma];
                XTToken* peek = [self currentToken];
                NSString* typedCallee = nil;
                XTType* structPointee = nil;
                if (peek.isTypeKeyword || [self.typeTable isTypeName:peek.value])
                    {
                    XTType* ty = [self parseType];
                    typedCallee = [self vaArgTypedCalleeForType:ty
                                                       location:loc];
                    // `va_arg(ap, T@)` where T is a user-defined
                    // struct: the packed argument is the struct's
                    // raw bytes (user varargs pack at full struct
                    // width, not the (data_ptr, desc_ptr) pair
                    // printf's `%@` path uses). Codegen returns a
                    // pointer into the buffer and advances the
                    // cursor by sizeof(T). Capture T here so sema
                    // can type the return as `T@` and codegen can
                    // size the advance — vaArgTypedCalleeForType
                    // returns `va_arg_struct_ptr` as the sentinel
                    // name for this form.
                    if ([typedCallee isEqualToString:@"va_arg_struct_ptr"] && [ty isKindOfClass:[XTPointerType class]])
                        {
                        structPointee = ((XTPointerType*)ty).pointeeType;
                        }
                    // A CLASS pointee rides va_arg_ptr (the slot holds a
                    // pointer VALUE, advanced by pointer width — nothing
                    // struct_ptr-shaped about it), but the REQUESTED type
                    // should still be what the expression means: without
                    // it `va_arg(ap, Object*)` typed as u8*, which reads
                    // as a raw pointer to every later check. Codegen is
                    // unaffected — the lowering keys on the callee name.
                    if ([typedCallee isEqualToString:@"va_arg_ptr"] && [ty isKindOfClass:[XTPointerType class]])
                        {
                        XTType* pe = ((XTPointerType*)ty).pointeeType;
                        if (pe && pe.kind == XTTypeKindClass)
                            structPointee = pe;
                        }
                    }
                [self expect:XTTokenRParen];
                XTCallExprNode* call = [[XTCallExprNode alloc]
                    initWithCallee:(typedCallee ?: @"va_arg")
                         arguments:args
                          location:loc];
                call.vaArgStructType = structPointee;
                return call;
                }

            NSArray<XTASTNode*>* args = [self parseArgList];
            [self expect:XTTokenRParen];
                // Blocks (task #26): a call through a block-typed binding —
                // `b(3, 4)` — is `b.invoke(3, 4)`, virtual dispatch through
                // the base class's vtable. A named literal calling itself
                // dispatches on `self` (it IS the impl instance).
                {
                NSMutableArray* frames = [self blkFrames];
                NSDictionary* selfFrame = frames.lastObject;
                id sn = selfFrame[@"selfName"];
                if ([sn isKindOfClass:[NSString class]] && [sn isEqualToString:cur.value])
                    {
                    XTASTNode* recv = [[XTIdentifierNode alloc]
                        initWithName:@"self"
                            location:loc];
                    return [[XTMethodCallExprNode alloc]
                        initWithReceiver:recv
                              methodName:@"invoke"
                               arguments:args
                                location:loc];
                    }
                NSDictionary* info = [self blkLookup:cur.value depth:NULL];
                if (info[@"base"])
                    {
                    [self blkNoteIdentifierUse:cur.value at:loc];
                    XTASTNode* recv = [[XTIdentifierNode alloc]
                        initWithName:cur.value
                            location:loc];
                    return [[XTMethodCallExprNode alloc]
                        initWithReceiver:recv
                              methodName:@"invoke"
                               arguments:args
                                location:loc];
                    }
                }
            return [self stampFwd:[[XTCallExprNode alloc] initWithCallee:cur.value arguments:args location:loc]];
            }
        [self blkNoteIdentifierUse:cur.value at:loc]; // task #26
        return [[XTIdentifierNode alloc] initWithName:cur.value location:loc];
        }
    default:
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"Unexpected token '%@' in expression", cur.value]
                                 at:loc];
        [self advance];
        return nil;
        }
        }
    }

/****************************************************************************\
|* Parse a comma-separated argument list (the contents between parentheses
|* in a function or method call). Stops at ')'.
|* @return  An array of expression AST nodes (empty if no arguments).
\****************************************************************************/
// Move the flag parseArgList just set onto the call node it belongs to, and
// clear it, so the next call in the same expression starts clean.
- (id)stampFwd:(id)call
    {
    if (self.sawVarargForward)
        {
        if ([call isKindOfClass:[XTCallExprNode class]])
            ((XTCallExprNode*)call).forwardsVarargs = YES;
        else if ([call isKindOfClass:[XTMethodCallExprNode class]])
            ((XTMethodCallExprNode*)call).forwardsVarargs = YES;
        self.sawVarargForward = NO;
        }
    return call;
    }

- (NSArray<XTASTNode*>*)parseArgList
    {
    self.sawVarargForward = NO;
    NSMutableArray<XTASTNode*>* args = [NSMutableArray array];
    if ([self check:XTTokenRParen])
        return args;
    // A literal `...` in the ARGUMENT position means "pass my own variadic tail
    // through" — `Stdio.printf(fmt, ...)`. It contributes NO argument: on every
    // target but arm9 the values were packed by the original caller and never
    // left that buffer, so forwarding is the absence of a repack. Recorded as a
    // flag on the call so the AST is identical to the same call without it, and
    // checked in sema. private:docs/bugs/047.
    if ([self check:XTTokenEllipsis])
        {
        [self advance];
        self.sawVarargForward = YES;
        return args;
        }
    XTASTNode* first = [self parseExpression];
    if (first)
        [args addObject:first];
    while ([self match:XTTokenComma])
        {
        if ([self check:XTTokenEllipsis])
            {
            [self advance];
            self.sawVarargForward = YES;
            continue;
            }
        XTASTNode* next = [self parseExpression];
        if (next)
            [args addObject:next];
        }
    return args;
    }

/****************************************************************************\
|* Map a parsed type to the matching va_arg_<type> intrinsic name for
|* the C-style `va_arg(ap, TYPE)` sugar. Pointer-typed arguments all
|* collapse to `va_arg_ptr` (since they're a bare 2-byte value on the
|* wire); `string` — the u8@ alias — uses the semantically-identical
|* `va_arg_string` so existing diagnostic messages stay consistent.
|* Returns nil if no matching intrinsic exists; the caller then reports
|* a parse-level error for the bad type.
\****************************************************************************/
- (nullable NSString*)vaArgTypedCalleeForType:(XTType*)ty
                                     location:(XTSourceLocation*)loc
    {
    if (!ty)
        return nil;
    if ([ty isKindOfClass:[XTPointerType class]])
        {
        // `string` in xtc is u8@; callers often write va_arg(ap, string).
        // Both paths read 2 bytes the same way; route `string` through
        // va_arg_string so any string-specific diagnostic keeps its tag.
        if ([ty.displayName isEqualToString:@"string"])
            return @"va_arg_string";
        // Pointer-to-struct: use the distinct va_arg_struct_ptr form.
        // User varargs packers emit the struct's raw bytes at full
        // struct width, so the callee must advance the cursor by
        // sizeof(T), not 2. The cursor->buffer pointer computation
        // also differs from va_arg_ptr (which reads a packed pointer
        // value); va_arg_struct_ptr returns a pointer INTO the buffer
        // at the current cursor position. Caller side stores the
        // pointee type on the call node for codegen to size the
        // advance.
        XTType* pointee = ((XTPointerType*)ty).pointeeType;
        if (pointee && pointee.kind == XTTypeKindStruct)
            {
            return @"va_arg_struct_ptr";
            }
        return @"va_arg_ptr";
        }
    switch (ty.kind)
        {
    case XTTypeKindU8:
        return @"va_arg_u8";
    case XTTypeKindI8:
        return @"va_arg_i8";
    case XTTypeKindU16:
        return @"va_arg_u16";
    case XTTypeKindI16:
        return @"va_arg_i16";
    case XTTypeKindU32:
        return @"va_arg_u32";
    case XTTypeKindI32:
        return @"va_arg_i32";
    case XTTypeKindFloat:
        return @"va_arg_float";
    case XTTypeKindDouble:
        return @"va_arg_double";
    default:
        break;
        }
    [self.diagnostics emitError:[NSString stringWithFormat:
                                              @"va_arg: no typed intrinsic for type '%@'", ty.displayName]
                             at:loc];
    return nil;
    }

@end
