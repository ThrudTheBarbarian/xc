/****************************************************************************\
|* XTParser+Shapes.m
|*
|* Operators a class defines with a shape of its own: `:operator(self ** o)`,
|* `:operator(self ⊗ o)`, `:operator(√self)`. Mirrored in the port
|* (Parser.xc, "Operators a class defines").
|*
|*   * Before any expression is read, the whole token stream is scanned for
|*     `:operator(...)` patterns and `:precedence(...)` annotations, and the
|*     shapes go into a table with their precedence and associativity
|*     (prescanOperatorShapes). An imported interface adds its classes'
|*     shapes (addImportedOperatorShapes:).
|*   * A shape is made of symbol characters: + - * / % < > = ! & | ^ ~ ? : @
|*     and the Unicode Mathematical Operators block (U+2200 to U+22FF), which
|*     the lexer gives one token a character. The lexer is otherwise as it
|*     was: the parser joins adjacent operator tokens into a shape when the
|*     table has it, as it joins adjacent string literals.
|*   * A shape takes the precedence and associativity of its first character
|*     (`**` binds like `*`, `<=>` like `<`); those of the Unicode block share
|*     the level of `*`. `:precedence(op)`, `:precedence(above op)` and
|*     `:precedence(below op)`, with `, right`, set them instead. Levels are
|*     the built-in ones times four, so `above *` and `below |` sit between
|*     two built-in levels without renumbering anything.
|*   * Where the characters of a shape also read the old way (`a**b` is
|*     `a * *b`), both readings are kept: the expression is read a second time
|*     with those shapes split, and the old reading hangs on the smallest
|*     expression where the two differ (`alternative`). Sema chooses by the
|*     operands' types.
\****************************************************************************/
#import "XTParser+Private.h"
#import "XTASTDumper.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Tokens and shapes

// A token an operator a class defines can be made of: one whose characters
// are all symbol characters, or a mathematical operator.
BOOL XTShapeTokenType(XTTokenType t)
    {
    switch (t)
        {
    case XTTokenPlus:
    case XTTokenMinus:
    case XTTokenStar:
    case XTTokenSlash:
    case XTTokenPercent:
    case XTTokenAmpersand:
    case XTTokenPipe:
    case XTTokenCaret:
    case XTTokenTilde:
    case XTTokenBang:
    case XTTokenLess:
    case XTTokenGreater:
    case XTTokenLessEq:
    case XTTokenGreaterEq:
    case XTTokenEqual:
    case XTTokenNotEqual:
    case XTTokenLogicalAnd:
    case XTTokenLogicalOr:
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
    case XTTokenShiftLeft:
    case XTTokenShiftRight:
    case XTTokenRotateLeft:
    case XTTokenRotateRight:
    case XTTokenPlusPlus:
    case XTTokenMinusMinus:
    case XTTokenArrow:
    case XTTokenByte3:
    case XTTokenQuestion:
    case XTTokenColon:
    case XTTokenAt:
    case XTTokenMathOp:
        return YES;
    default:
        return NO;
        }
    }

// A built-in binary operator (not an assignment, not `?`).
static BOOL XTShapeBinaryTok(XTTokenType t)
    {
    switch (t)
        {
    case XTTokenPlus:
    case XTTokenMinus:
    case XTTokenStar:
    case XTTokenSlash:
    case XTTokenPercent:
    case XTTokenAmpersand:
    case XTTokenPipe:
    case XTTokenCaret:
    case XTTokenShiftLeft:
    case XTTokenShiftRight:
    case XTTokenRotateLeft:
    case XTTokenRotateRight:
    case XTTokenLess:
    case XTTokenGreater:
    case XTTokenLessEq:
    case XTTokenGreaterEq:
    case XTTokenEqual:
    case XTTokenNotEqual:
    case XTTokenLogicalAnd:
    case XTTokenLogicalOr:
        return YES;
    default:
        return NO;
        }
    }

// A token that reads as a built-in prefix operator where an operand starts.
static BOOL XTShapePrefixTok(XTTokenType t)
    {
    switch (t)
        {
    case XTTokenMinus:
    case XTTokenPlus:
    case XTTokenTilde:
    case XTTokenBang:
    case XTTokenAmpersand:
    case XTTokenStar:
    case XTTokenAt:
    case XTTokenPlusPlus:
    case XTTokenMinusMinus:
    case XTTokenLess:
    case XTTokenByte3:
        return YES;
    default:
        return NO;
        }
    }

static BOOL XTShapeAssignTok(XTTokenType t)
    {
    switch (t)
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
        return YES;
    default:
        return NO;
        }
    }

// `b` starts where `a` ends: same file and line, the next column (columns
// count UTF-16 units, as the token's length does).
static BOOL XTTokensAdjacent(XTToken* a, XTToken* b)
    {
    return [a.location.filename isEqualToString:b.location.filename] && a.location.line == b.location.line
        && b.location.column == a.location.column + a.value.length;
    }

// A binary literal (`%101`) whose `%` can end a shape.
static BOOL XTShapeBinlit(XTToken* t)
    {
    return t.type == XTTokenIntLiteral && [t.value hasPrefix:@"%"];
    }

// Do the first `n` tokens of `run` also read the old way between two
// operands: postfix `++`/`--`, then a built-in binary operator, then prefix
// operators?
static BOOL XTShapeOldInfix(NSArray<XTToken*>* run, NSUInteger n)
    {
    for (NSUInteger s = 0; s < n; s++)
        {
        BOOL ok = XTShapeBinaryTok(run[s].type);
        for (NSUInteger q = 0; ok && q < s; q++)
            ok = run[q].type == XTTokenPlusPlus || run[q].type == XTTokenMinusMinus;
        for (NSUInteger q = s + 1; ok && q < n; q++)
            ok = XTShapePrefixTok(run[q].type);
        if (ok)
            return YES;
        }
    return NO;
    }

// …or, where an operand starts, as built-in prefix operators?
static BOOL XTShapeOldPrefix(NSArray<XTToken*>* run, NSUInteger n)
    {
    for (NSUInteger q = 0; q < n; q++)
        if (!XTShapePrefixTok(run[q].type))
            return NO;
    return YES;
    }

// The characters of a shape: `**` of `_**_`, `√` of `√_`.
NSString* XTShapeCore(NSString* shape)
    {
    NSUInteger n = shape.length;
    BOOL infix = n >= 3 && [shape hasPrefix:@"_"] && [shape hasSuffix:@"_"];
    if (infix)
        return [shape substringWithRange:NSMakeRange(1, n - 2)];
    if (n >= 2 && [shape hasSuffix:@"_"])
        return [shape substringToIndex:n - 1];
    return shape;
    }

// An infix shape (`_**_`), not a prefix one (`√_`).
BOOL XTShapeIsInfix(NSString* shape)
    {
    return shape.length >= 3 && [shape hasPrefix:@"_"] && [shape hasSuffix:@"_"];
    }

// Is the shape one a class defines of its own, not a built-in operator, an
// index or a compound assignment?
BOOL XTIsUserShape(NSString* _Nullable shape)
    {
    static NSSet<NSString*>* infixBuiltin;
    static NSSet<NSString*>* prefixBuiltin;
    if (!infixBuiltin)
        {
        infixBuiltin = [NSSet setWithArray:@[ @"+", @"-", @"*", @"/", @"%", @"&", @"|", @"^", @"<<", @">>", @"<:",
                                              @":>", @"<", @"<=", @">", @">=", @"+=", @"-=", @"*=", @"/=", @"%=",
                                              @"&=", @"|=", @"^=", @"<<=", @">>=", @"<:=", @":>=" ]];
        prefixBuiltin = [NSSet setWithArray:@[ @"-", @"+", @"~", @"!" ]];
        }
    if (!shape.length || [shape hasPrefix:@"_["])
        return NO;
    if (XTShapeIsInfix(shape))
        return ![infixBuiltin containsObject:XTShapeCore(shape)];
    return ![prefixBuiltin containsObject:XTShapeCore(shape)];
    }

// The precedence of a built-in binary operator, spelt, times four; -1 for
// anything else.
static NSInteger XTShapeBuiltinLevel(NSString* op)
    {
    static NSDictionary<NSString*, NSNumber*>* levels;
    if (!levels)
        levels = @{ @"||" : @3, @"&&" : @4, @"|" : @5, @"^" : @6, @"&" : @7, @"==" : @8, @"!=" : @8,
                    @"<" : @9, @">" : @9, @"<=" : @9, @">=" : @9, @"<<" : @10, @">>" : @10,
                    @"<:" : @11, @":>" : @11, @"+" : @12, @"-" : @12, @"*" : @13, @"/" : @13, @"%" : @13 };
    NSNumber* l = levels[op];
    return l ? l.integerValue * 4 : -1;
    }

// The level of an infix shape with no `:precedence`: that of its first
// character, times four. A mathematical operator, `~`, `?` and `@` share
// the level of `*`; `=` and `!` that of `==`; `:` that of `:>`.
static NSInteger XTShapeFirstCharLevel(NSString* core)
    {
    unichar c = core.length ? [core characterAtIndex:0] : '*';
    switch (c)
        {
    case '|': return 5 * 4;
    case '^': return 6 * 4;
    case '&': return 7 * 4;
    case '=':
    case '!': return 8 * 4;
    case '<':
    case '>': return 9 * 4;
    case ':': return 11 * 4;
    case '+':
    case '-': return 12 * 4;
    default: return 13 * 4;
        }
    }

// A `:precedence` spec's level and associativity, packed as the table keeps
// them: level * 2, plus 1 for right.
static NSInteger XTShapeSpecEntry(NSString* spec)
    {
    BOOL right = [spec hasSuffix:@",right"];
    NSString* body = right ? [spec substringToIndex:spec.length - 6] : spec;
    unichar rel = [body characterAtIndex:0];
    NSInteger level = XTShapeBuiltinLevel([body substringFromIndex:1]);
    if (rel == '>')
        level += 1;
    else if (rel == '<')
        level -= 1;
    return level * 2 + (right ? 1 : 0);
    }

static NSString* const XTShapeDisallowed =
    @"'%@' cannot be part of an operator, which is made of the characters + - * / %% < > = ! & | ^ ~ ? : @ and "
    @"the mathematical operators U+2200 to U+22FF";

/****************************************************************************\
|* The shape of a class's own that tokens [from, to) of a pattern spell, as
|* an infix operator (`_**_`) or a prefix one (`√_`). nil, with *fault set
|* when the tokens are an operator that cannot be one, or nil when they are
|* not an attempt at one (the caller's message then applies).
\****************************************************************************/
static NSString* _Nullable XTUserShapeOf(NSArray<XTToken*>* t, NSUInteger from, NSUInteger to, BOOL infix,
                                         NSString* _Nullable* _Nonnull fault)
    {
    NSUInteger k = to - from;
    for (NSUInteger q = from; q < to; q++)
        {
        XTToken* x = t[q];
        if (XTShapeTokenType(x.type))
            continue;
        BOOL word = x.type == XTTokenIdentifier || x.type == XTTokenIntLiteral || x.type == XTTokenFloatLiteral
                    || x.type == XTTokenCharLiteral || x.type == XTTokenStringLiteral;
        unichar c0 = x.value.length ? [x.value characterAtIndex:0] : 0;
        BOOL nameLike = x.type == XTTokenIdentifier && (c0 == '_' || (c0 < 128 && isalpha(c0)));
        if (word && (k == 1 || !nameLike))
            *fault = [NSString stringWithFormat:XTShapeDisallowed, x.value];
        return nil;
        }
    if (k == 1 && t[from].type != XTTokenAt && t[from].type != XTTokenMathOp)
        {
        *fault = [NSString stringWithFormat:@"'%@' cannot be overloaded", t[from].value];
        return nil;
        }
    for (NSUInteger q = from + 1; q < to; q++)
        if (!XTTokensAdjacent(t[q - 1], t[q]))
            {
            *fault = @"the characters of an operator are written together, as in (self ** o)";
            return nil;
            }
    NSMutableString* text = [NSMutableString string];
    for (NSUInteger q = from; q < to; q++)
        [text appendString:t[q].value];
    if (infix && k >= 2
        && (XTShapeAssignTok(t[from].type) || t[from].type == XTTokenQuestion || t[from].type == XTTokenColon))
        {
        BOOL rest = YES;
        for (NSUInteger q = from + 1; q < to; q++)
            rest = rest && XTShapePrefixTok(t[q].type);
        if (rest)
            {
            *fault = [NSString stringWithFormat:@"'%@' cannot be an operator: between two operands it already reads as "
                                                @"'%@' followed by a prefix operator",
                                                text, t[from].value];
            return nil;
            }
        }
    return infix ? [NSString stringWithFormat:@"_%@_", text] : [NSString stringWithFormat:@"%@_", text];
    }

/****************************************************************************\
|* A pattern's shape of the class's own and its operand names: two names round
|* the operator (`self ** o`), or the operator before one (`√self`).
\****************************************************************************/
NSString* _Nullable XTPatternUserShape(NSArray<XTToken*>* t, NSString* _Nullable* _Nonnull fault,
                                       NSArray<NSString*>* _Nullable* _Nullable names)
    {
    NSUInteger n = t.count;
    *fault = nil;
    if (n >= 3 && t[0].type == XTTokenIdentifier && t[n - 1].type == XTTokenIdentifier)
        {
        NSString* key = XTUserShapeOf(t, 1, n - 1, YES, fault);
        if (key && names)
            *names = @[ t[0].value, t[n - 1].value ];
        return key;
        }
    if (n >= 2 && t[n - 1].type == XTTokenIdentifier && (n == 2 || t[0].type != XTTokenIdentifier))
        {
        NSString* key = XTUserShapeOf(t, 0, n - 1, NO, fault);
        if (key && names)
            *names = @[ t[n - 1].value ];
        return key;
        }
    return nil;
    }

/****************************************************************************\
|* `:precedence(...)`'s tokens as a spec: "=op", ">op" (above op) or "<op"
|* (below op), with ",right" for `, right`; "? <what is wrong>" otherwise.
\****************************************************************************/
NSString* XTPrecedenceSpecOf(NSArray<XTToken*>* t)
    {
    NSUInteger n = t.count;
    NSUInteger i = 0;
    NSString* rel = @"=";
    NSString* bad = @"? ':precedence' takes an operator, or 'above' or 'below' and an operator, then ', right' to "
                    @"group from the right, such as (above *, right)";
    if (n > 0 && t[0].type == XTTokenIdentifier && ([t[0].value isEqualToString:@"above"] || [t[0].value isEqualToString:@"below"]))
        {
        rel = [t[0].value isEqualToString:@"above"] ? @">" : @"<";
        i = 1;
        }
    if (i >= n || !XTShapeBinaryTok(t[i].type))
        return bad;
    NSString* op = t[i].value;
    i++;
    BOOL right = NO;
    if (i < n)
        {
        if (i + 2 == n && t[i].type == XTTokenComma && t[i + 1].type == XTTokenIdentifier
            && [t[i + 1].value isEqualToString:@"right"])
            right = YES;
        else
            return bad;
        }
    return [NSString stringWithFormat:@"%@%@%@", rel, op, right ? @",right" : @""];
    }

@implementation XTParser (Shapes)

#pragma mark - The table

/****************************************************************************\
|* Add a shape to the table: an infix one with its level and associativity
|* (from `spec`, else by its first character), a prefix one alone. The first
|* `:precedence` for a shape is the one the parse uses; sema reports two that
|* disagree.
\****************************************************************************/
- (void)addOperatorShape:(NSString*)key spec:(nullable NSString*)spec
    {
    if (!self.opShapes)
        {
        self.opShapes = [NSMutableDictionary dictionary];
        self.opShapesSet = [NSMutableSet set];
        }
    if (!XTShapeIsInfix(key))
        {
        if (!self.opShapes[key])
            self.opShapes[key] = @0;
        return;
        }
    BOOL explicit = spec.length && ![spec hasPrefix:@"?"];
    if (self.opShapes[key] && (!explicit || [self.opShapesSet containsObject:key]))
        return;
    NSInteger entry = explicit ? XTShapeSpecEntry(spec) : XTShapeFirstCharLevel(XTShapeCore(key)) * 2;
    self.opShapes[key] = @(entry);
    if (explicit)
        [self.opShapesSet addObject:key];
    }

/****************************************************************************\
|* Every `:operator(pattern)` in the token stream with a shape of a class's
|* own, and the `:precedence(...)` beside it. An annotation run is `:` and a
|* word, with a parenthesised argument or not, then more joined by `:` or `,`.
\****************************************************************************/
- (void)prescanOperatorShapes
    {
    NSArray<XTToken*>* tk = self.tokens;
    NSUInteger n = tk.count;
    for (NSUInteger i = 0; i + 1 < n; i++)
        {
        if (tk[i].type != XTTokenColon || tk[i + 1].type != XTTokenIdentifier)
            continue;
        NSArray<XTToken*>* opArgs = nil;
        NSArray<XTToken*>* precArgs = nil;
        NSUInteger j = i;
        while (j + 1 < n && (tk[j].type == XTTokenColon || (j > i && tk[j].type == XTTokenComma))
               && tk[j + 1].type == XTTokenIdentifier)
            {
            NSString* w = tk[j + 1].value.lowercaseString;
            NSUInteger k = j + 2;
            NSArray<XTToken*>* args = nil;
            if (k < n && tk[k].type == XTTokenLParen)
                {
                NSUInteger depth = 0;
                NSUInteger q = k + 1;
                for (; q < n; q++)
                    {
                    XTTokenType ty = tk[q].type;
                    if (ty == XTTokenEOF || (ty == XTTokenRParen && depth == 0))
                        break;
                    if (ty == XTTokenLParen || ty == XTTokenLBracket)
                        depth++;
                    else if ((ty == XTTokenRParen || ty == XTTokenRBracket) && depth > 0)
                        depth--;
                    }
                args = [tk subarrayWithRange:NSMakeRange(k + 1, q - (k + 1))];
                k = q < n ? q + 1 : q;
                }
            if (args && [w isEqualToString:@"operator"])
                opArgs = args;
            if (args && [w isEqualToString:@"precedence"])
                precArgs = args;
            j = k;
            }
        if (opArgs)
            {
            NSString* fault = nil;
            NSString* key = XTPatternUserShape(opArgs, &fault, NULL);
            if (key)
                [self addOperatorShape:key spec:precArgs ? XTPrecedenceSpecOf(precArgs) : nil];
            }
        i = j - 1;
        }
    }

- (void)addShapesOfImports:(NSArray<XTASTNode*>*)decls
    {
    for (XTASTNode* d in decls)
        {
        if (![d isKindOfClass:[XTClassDeclNode class]])
            continue;
        for (XTMethodDeclNode* m in ((XTClassDeclNode*)d).methods)
            if (XTIsUserShape(m.operatorShape))
                [self addOperatorShape:m.operatorShape spec:m.operatorPrecedence];
        }
    }

/****************************************************************************\
|* `:precedence(...)` after the word: its spec, or what is wrong with it.
\****************************************************************************/
- (NSString*)parsePrecedenceSpec
    {
    NSString* bad = XTPrecedenceSpecOf(@[]);
    if (![self check:XTTokenLParen])
        return bad;
    [self advance];
    NSMutableArray<XTToken*>* t = [NSMutableArray array];
    NSInteger depth = 0;
    while (![self check:XTTokenEOF])
        {
        XTTokenType ty = [self currentToken].type;
        if (ty == XTTokenRParen && depth == 0)
            break;
        if (ty == XTTokenLParen || ty == XTTokenLBracket)
            depth++;
        else if ((ty == XTTokenRParen || ty == XTTokenRBracket) && depth > 0)
            depth--;
        [t addObject:[self advance]];
        }
    [self expect:XTTokenRParen];
    return XTPrecedenceSpecOf(t);
    }

#pragma mark - Reading a shape

/****************************************************************************\
|* The longest shape in the table that the tokens from the current one spell,
|* infix or prefix: its key, or nil. *len is how many tokens it takes;
|* *binlit says it ends with the `%` of the binary literal after them (whose
|* digits are then the operand, in decimal); *ambiguous says its characters
|* also read the old way. While the expression is read the old way
|* (splitShapes), a shape that also reads the old way is passed over.
\****************************************************************************/
- (nullable NSString*)shapeAtCurrentInfix:(BOOL)infix
                                      len:(NSUInteger*)len
                                   binlit:(BOOL*)binlit
                                ambiguous:(BOOL*)ambiguous
    {
    if (!self.opShapes.count)
        return nil;
    NSArray<XTToken*>* tk = self.tokens;
    NSUInteger p = self.pos;
    NSMutableArray<XTToken*>* run = [NSMutableArray array];
    while (run.count < 8 && p + run.count < tk.count)
        {
        XTToken* t = tk[p + run.count];
        if (!XTShapeTokenType(t.type) || (run.count && !XTTokensAdjacent(run.lastObject, t)))
            break;
        [run addObject:t];
        }
    if (!run.count)
        return nil;
    NSUInteger after = p + run.count;
    BOOL tail = after < tk.count && XTShapeBinlit(tk[after]) && XTTokensAdjacent(run.lastObject, tk[after]);
    for (NSInteger j = (NSInteger)run.count + (tail ? 1 : 0); j >= 1; j--)
        {
        BOOL withTail = tail && j == (NSInteger)run.count + 1;
        NSUInteger nt = withTail ? run.count : (NSUInteger)j;
        NSMutableString* text = [NSMutableString string];
        for (NSUInteger q = 0; q < nt; q++)
            [text appendString:run[q].value];
        if (withTail)
            [text appendString:@"%"];
        NSString* key = infix ? [NSString stringWithFormat:@"_%@_", text] : [NSString stringWithFormat:@"%@_", text];
        if (!self.opShapes[key])
            continue;
        BOOL old = infix ? XTShapeOldInfix(run, nt) : XTShapeOldPrefix(run, nt);
        if (old && self.splitShapes)
            continue;
        *len = nt;
        *binlit = withTail;
        *ambiguous = old;
        return key;
        }
    return nil;
    }

/****************************************************************************\
|* With the current token a binary literal whose `%` ended a shape: the token
|* in its place that its digits make, a decimal literal one column on.
\****************************************************************************/
- (XTToken*)shapeDecimalFrom:(XTToken*)bt
    {
    NSString* digits = [bt.value substringFromIndex:1];
    uint64_t v = 0;
    for (NSUInteger q = 0; q < digits.length; q++)
        v = v * 10 + (uint64_t)([digits characterAtIndex:q] - '0');
    XTSourceLocation* loc = [XTSourceLocation locationWithFilename:bt.location.filename
                                                              line:bt.location.line
                                                            column:bt.location.column + 1];
    return [[XTToken alloc] initWithType:XTTokenIntLiteral value:digits intValue:(int64_t)v location:loc];
    }

/****************************************************************************\
|* The right operand of an infix shape, at `prec`; the operand of a prefix
|* one (prec < 0). After a shape that took a binary literal's `%`, its digits
|* are read as the decimal literal they spell.
\****************************************************************************/
- (nullable XTASTNode*)parseShapeOperandAt:(int)prec binlit:(BOOL)binlit
    {
    if (!binlit)
        return prec < 0 ? [self parseUnary] : [self parseExprWithMinPrec:prec];
    NSMutableArray<XTToken*>* tk = (NSMutableArray<XTToken*>*)self.tokens;
    NSUInteger at = self.pos;
    XTToken* bt = tk[at];
    tk[at] = [self shapeDecimalFrom:bt];
    XTASTNode* r = prec < 0 ? [self parseUnary] : [self parseExprWithMinPrec:prec];
    tk[at] = bt;
    return r;
    }

/****************************************************************************\
|* An infix shape at the current token, with lhs read: nil when there is none
|* or it binds less tightly than minPrec (*stop then says to stop). Otherwise
|* the operator node, its right operand read.
\****************************************************************************/
- (nullable XTASTNode*)parseInfixShapeAfter:(XTASTNode*)lhs minPrec:(int)minPrec stop:(BOOL*)stop
    {
    *stop = NO;
    NSUInteger len = 0;
    BOOL tail = NO, amb = NO;
    NSString* key = [self shapeAtCurrentInfix:YES len:&len binlit:&tail ambiguous:&amb];
    if (!key)
        return nil;
    NSInteger entry = self.opShapes[key].integerValue;
    int prec = (int)(entry >> 1);
    BOOL right = (entry & 1) != 0;
    if (prec < minPrec)
        {
        *stop = YES;
        return nil;
        }
    XTToken* first = [self currentToken];
    for (NSUInteger q = 0; q < len; q++)
        [self advance];
    XTASTNode* rhs = [self parseShapeOperandAt:right ? prec : prec + 1 binlit:tail];
    XTBinaryExprNode* b = [[XTBinaryExprNode alloc] initWithOp:XTBinaryOpUser left:lhs right:rhs location:first.location];
    b.userOp = XTShapeCore(key);
    if (amb && self.shapeSites)
        {
        b.twoReadings = YES;
        [self.shapeSites addObject:b];
        }
    return b;
    }

/****************************************************************************\
|* A prefix shape at the current token, and its operand; nil when none.
\****************************************************************************/
- (nullable XTASTNode*)parsePrefixShape
    {
    NSUInteger len = 0;
    BOOL tail = NO, amb = NO;
    NSString* key = [self shapeAtCurrentInfix:NO len:&len binlit:&tail ambiguous:&amb];
    if (!key)
        return nil;
    XTToken* first = [self currentToken];
    for (NSUInteger q = 0; q < len; q++)
        [self advance];
    XTASTNode* opnd = [self parseShapeOperandAt:-1 binlit:tail];
    XTUnaryExprNode* u = [[XTUnaryExprNode alloc] initWithOp:XTUnaryOpUser operand:opnd location:first.location];
    u.userOp = XTShapeCore(key);
    if (amb && self.shapeSites)
        {
        u.twoReadings = YES;
        [self.shapeSites addObject:u];
        }
    return u;
    }

/****************************************************************************\
|* `a--` before `>`: is the `--` the start of an infix shape here (`-->`)?
\****************************************************************************/
- (BOOL)infixShapeAtCurrent
    {
    NSUInteger len = 0;
    BOOL tail = NO, amb = NO;
    return [self shapeAtCurrentInfix:YES len:&len binlit:&tail ambiguous:&amb] != nil;
    }

#pragma mark - Two readings

// The sub-expressions the two readings are compared through, and what else
// must match for a node to be the same in both; nil for any other node.
static NSArray<XTASTNode*>* _Nullable XTReadingKids(XTASTNode* n)
    {
    if ([n isKindOfClass:[XTBinaryExprNode class]])
        return @[ ((XTBinaryExprNode*)n).left, ((XTBinaryExprNode*)n).right ];
    if ([n isKindOfClass:[XTUnaryExprNode class]])
        return @[ ((XTUnaryExprNode*)n).operand ];
    if ([n isKindOfClass:[XTTernaryExprNode class]])
        return @[ ((XTTernaryExprNode*)n).condition, ((XTTernaryExprNode*)n).thenExpr, ((XTTernaryExprNode*)n).elseExpr ];
    if ([n isKindOfClass:[XTAssignExprNode class]])
        return @[ ((XTAssignExprNode*)n).lhs, ((XTAssignExprNode*)n).rhs ];
    if ([n isKindOfClass:[XTCastExprNode class]])
        return @[ ((XTCastExprNode*)n).operand ];
    return nil;
    }

static NSString* XTReadingHead(XTASTNode* n)
    {
    NSString* dump = [XTASTDumper dump:n];
    NSRange nl = [dump rangeOfString:@"\n"];
    return nl.location == NSNotFound ? dump : [dump substringToIndex:nl.location];
    }

/****************************************************************************\
|* Hang `o`, the old reading of the expression `u` was read as, on the
|* smallest expression of `u` where the two differ. NO when that is not an
|* operator in both (the readings are then not kept).
\****************************************************************************/
- (BOOL)attachReading:(XTASTNode*)o to:(XTASTNode*)u
    {
    XTASTNode* us = u;
    XTASTNode* os = o;
    while (YES)
        {
        NSArray<XTASTNode*>* uk = XTReadingKids(us);
        NSArray<XTASTNode*>* ok = XTReadingKids(os);
        if (!uk || !ok || uk.count != ok.count || us.nodeKind != os.nodeKind
            || ![XTReadingHead(us) isEqualToString:XTReadingHead(os)])
            break;
        NSUInteger differ = 0;
        NSUInteger at = 0;
        for (NSUInteger i = 0; i < uk.count; i++)
            if (![[XTASTDumper dump:uk[i]] isEqualToString:[XTASTDumper dump:ok[i]]])
                {
                differ++;
                at = i;
                }
        if (differ != 1)
            break;
        us = uk[at];
        os = ok[at];
        }
    if ([us isKindOfClass:[XTBinaryExprNode class]] && [os isKindOfClass:[XTBinaryExprNode class]])
        {
        ((XTBinaryExprNode*)us).alternative = os;
        return YES;
        }
    if ([us isKindOfClass:[XTUnaryExprNode class]] && [os isKindOfClass:[XTUnaryExprNode class]])
        {
        ((XTUnaryExprNode*)us).alternative = os;
        return YES;
        }
    return NO;
    }

// What the parse of an expression may leave behind besides its tree: block
// literals and par blocks made, :scan blocks rewritten, loops lifted. An
// expression that made any is not read a second time.
- (NSString*)shapeSideEffects
    {
    return [NSString stringWithFormat:@"%@/%@/%@/%lu", self.blkState[@"counter"], self.blkState[@"parCounter"],
                                      self.blkState[@"parAutoCounter"], (unsigned long)self.scanSeq];
    }

/****************************************************************************\
|* A full expression in a unit with shapes. Read with the shapes joined; when
|* one joined there also reads the old way, read again with those split. Both
|* readings parse: the old one hangs on the new (attachReading:to:). Only the
|* old one parses: it is the expression. Only the new one: it is, and its
|* shapes read one way.
\****************************************************************************/
- (nullable XTASTNode*)parseExpressionReadings
    {
    NSMutableArray<XTASTNode*>* outerSites = self.shapeSites;
    BOOL outerSplit = self.splitShapes;
    NSMutableArray<XTASTNode*>* sites = [NSMutableArray array];
    self.shapeSites = sites;
    self.splitShapes = NO;
    NSUInteger start = self.pos;
    NSUInteger mark = [self.diagnostics mark];
    NSString* effects = [self shapeSideEffects];
    XTASTNode* u = [self parseExprWithMinPrec:0];
    if (sites.count)
        {
        NSUInteger endU = self.pos;
        BOOL uFailed = !u || [self.diagnostics errorCountSince:mark] > 0;
        BOOL attached = NO;
        if ([[self shapeSideEffects] isEqualToString:effects])
            {
            NSUInteger mark2 = [self.diagnostics mark];
            self.pos = start;
            self.splitShapes = YES;
            self.shapeSites = nil;
            XTASTNode* o = [self parseExprWithMinPrec:0];
            BOOL oFailed = !o || [self.diagnostics errorCountSince:mark2] > 0;
            NSUInteger endO = self.pos;
            NSArray<XTDiagnostic*>* oDiags = [self.diagnostics takeSince:mark2];
            self.splitShapes = NO;
            self.pos = endU;
            if (!oFailed && endO == endU)
                {
                if (uFailed)
                    {
                    [self.diagnostics rollbackTo:mark];
                    [self.diagnostics restore:oDiags];
                    u = o;
                    }
                else
                    attached = [self attachReading:o to:u];
                }
            }
        if (!attached)
            for (XTASTNode* s in sites)
                {
                if ([s isKindOfClass:[XTBinaryExprNode class]])
                    ((XTBinaryExprNode*)s).twoReadings = NO;
                else
                    ((XTUnaryExprNode*)s).twoReadings = NO;
                }
        }
    self.shapeSites = outerSites;
    self.splitShapes = outerSplit;
    return u;
    }

@end

NS_ASSUME_NONNULL_END
