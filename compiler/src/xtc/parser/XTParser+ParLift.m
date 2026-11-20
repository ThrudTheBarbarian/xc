/****************************************************************************\
|* XTParser+ParLift.m
|*
|* The --par-style=auto recogniser (#338): whether a loop becomes a par
|* block, decided from its tree once it is parsed, beside the token scan
|* (parAutoScan) that still decides. It makes the scan's decisions: the
|* verdict, the rule that kept a loop serial, the loop's form, its
|* reductions, a running total, the grid levels a nest may take, and the
|* small-loop test.
|*
|* The header is read from the tree and the source facts the parser put on
|* it (SRC_RANGE, SRC_SERIAL, SRC_GOAL, SRC_STEPBAD, SRC_DESC, and
|* SRC_PAREN and SRC_PLAIN for the condition and the step). The body's rules
|* read the token before or after a name, so a walk of the tree rebuilds the
|* loop's tokens in source order (plEmit), with the parentheses SRC_PAREN
|* records and each declaration's names, and the body's rules run on them
|* (parAutoScanBodyAfter, shared with the scan). A block literal, a nested
|* par block, a loop lifted inside the loop, and a counted `while` the
|* parser rewrote are read through the sites the parser recorded for them,
|* as they were written.
|*
|* XC_PAR_AUTO_CHECK=recog prints, for each loop the scan reads, a line
|* comparing the two: "same", or "differ" and each field that does.
|* Mirrored in the port (Parser.xc, the recogniser section).
\****************************************************************************/
#import "XTParser+Private.h"

NS_ASSUME_NONNULL_BEGIN

@implementation XTParser (ParLift)

// ── The walk: the tree's tokens in source order ─────────────────────────

- (void)plTok:(XTTokenType)t value:(NSString*)v
    {
    [self.plToks addObject:[[XTToken alloc] initWithType:t value:v location:self.plLoc]];
    }

- (void)plTok:(XTTokenType)t
    {
    [self plTok:t value:@""];
    }

// A type keyword's token type, or XTTokenEOF.
static XTTokenType plKeyword(NSString* w)
    {
    static NSDictionary<NSString*, NSNumber*>* kw;
    if (!kw)
        kw = @{ @"u8" : @(XTTokenU8), @"i8" : @(XTTokenI8), @"u16" : @(XTTokenU16), @"i16" : @(XTTokenI16),
                @"u32" : @(XTTokenU32), @"i32" : @(XTTokenI32), @"u64" : @(XTTokenU64), @"i64" : @(XTTokenI64),
                @"bool" : @(XTTokenBool), @"float" : @(XTTokenFloat), @"double" : @(XTTokenDouble),
                @"void" : @(XTTokenVoid), @"pointer" : @(XTTokenPointer), @"string" : @(XTTokenString),
                @"auto" : @(XTTokenAuto) };
    NSNumber* t = kw[w];
    return t ? (XTTokenType)t.integerValue : XTTokenEOF;
    }

// A type's spelling as tokens: its words (a type keyword as one), its
// pointer sigils as `*`, and its brackets and commas.
- (void)plTypeSpelling:(nullable NSString*)s
    {
    if (!s)
        return;
    NSUInteger n = s.length;
    NSUInteger i = 0;
    while (i < n)
        {
        unichar c = [s characterAtIndex:i];
        if (isalnum(c) || c == '_' || c == '$')
            {
            NSUInteger j = i;
            while (j < n)
                {
                unichar d = [s characterAtIndex:j];
                if (!(isalnum(d) || d == '_' || d == '$'))
                    break;
                j++;
                }
            NSString* w = [s substringWithRange:NSMakeRange(i, j - i)];
            XTTokenType k = plKeyword(w);
            if (k != XTTokenEOF)
                [self plTok:k value:w];
            else if (isdigit(c))
                [self plTok:XTTokenIntLiteral value:w];
            else
                [self plTok:XTTokenIdentifier value:w];
            i = j;
            continue;
            }
        if (c == '*' || c == '@')
            [self plTok:XTTokenStar value:@"*"];
        else if (c == '<')
            [self plTok:XTTokenLess value:@"<"];
        else if (c == '>')
            [self plTok:XTTokenGreater value:@">"];
        else if (c == ',')
            [self plTok:XTTokenComma value:@","];
        else if (c == '(')
            [self plTok:XTTokenLParen value:@"("];
        else if (c == ')')
            [self plTok:XTTokenRParen value:@")"];
        else if (c == '[')
            [self plTok:XTTokenLBracket value:@"["];
        else if (c == ']')
            [self plTok:XTTokenRBracket value:@"]"];
        else if (c == '^')
            [self plTok:XTTokenCaret value:@"^"];
        else if (c == '?')
            [self plTok:XTTokenQuestion value:@"?"];
        i++;
        }
    }

- (void)plType:(nullable XTType*)t
    {
    if (!t)
        return;
    if ([t isKindOfClass:[XTArrayType class]])
        {
        [self plType:((XTArrayType*)t).elementType];
        return;
        }
    [self plTypeSpelling:t.displayName];
    }

// A declaration's array dimensions, after its name.
- (void)plDims:(nullable XTType*)t
    {
    while ([t isKindOfClass:[XTArrayType class]])
        {
        [self plTok:XTTokenLBracket value:@"["];
        [self plTok:XTTokenIntLiteral value:[NSString stringWithFormat:@"%lu", (unsigned long)((XTArrayType*)t).elementCount]];
        [self plTok:XTTokenRBracket value:@"]"];
        t = ((XTArrayType*)t).elementType;
        }
    }

static NSString* plBinarySpelling(XTBinaryOp op, XTTokenType* t)
    {
    switch (op)
        {
    case XTBinaryOpAdd: *t = XTTokenPlus; return @"+";
    case XTBinaryOpSub: *t = XTTokenMinus; return @"-";
    case XTBinaryOpMul: *t = XTTokenStar; return @"*";
    case XTBinaryOpDiv: *t = XTTokenSlash; return @"/";
    case XTBinaryOpMod: *t = XTTokenPercent; return @"%";
    case XTBinaryOpBitAnd: *t = XTTokenAmpersand; return @"&";
    case XTBinaryOpBitOr: *t = XTTokenPipe; return @"|";
    case XTBinaryOpBitXor: *t = XTTokenCaret; return @"^";
    case XTBinaryOpShl: *t = XTTokenShiftLeft; return @"<<";
    case XTBinaryOpShr: *t = XTTokenShiftRight; return @">>";
    case XTBinaryOpRol: *t = XTTokenRotateLeft; return @"<:";
    case XTBinaryOpRor: *t = XTTokenRotateRight; return @":>";
    case XTBinaryOpLogAnd: *t = XTTokenLogicalAnd; return @"&&";
    case XTBinaryOpLogOr: *t = XTTokenLogicalOr; return @"||";
    case XTBinaryOpEq: *t = XTTokenEqual; return @"==";
    case XTBinaryOpNeq: *t = XTTokenNotEqual; return @"!=";
    case XTBinaryOpLt: *t = XTTokenLess; return @"<";
    case XTBinaryOpGt: *t = XTTokenGreater; return @">";
    case XTBinaryOpLe: *t = XTTokenLessEq; return @"<=";
    case XTBinaryOpGe: *t = XTTokenGreaterEq; return @">=";
        }
    *t = XTTokenPlus;
    return @"+";
    }

static NSString* plAssignSpelling(XTAssignOp op, XTTokenType* t)
    {
    switch (op)
        {
    case XTAssignOpAssign: *t = XTTokenAssign; return @"=";
    case XTAssignOpAdd: *t = XTTokenPlusAssign; return @"+=";
    case XTAssignOpSub: *t = XTTokenMinusAssign; return @"-=";
    case XTAssignOpMul: *t = XTTokenStarAssign; return @"*=";
    case XTAssignOpDiv: *t = XTTokenSlashAssign; return @"/=";
    case XTAssignOpMod: *t = XTTokenPercentAssign; return @"%=";
    case XTAssignOpBitAnd: *t = XTTokenAmpAssign; return @"&=";
    case XTAssignOpBitOr: *t = XTTokenPipeAssign; return @"|=";
    case XTAssignOpBitXor: *t = XTTokenCaretAssign; return @"^=";
    case XTAssignOpShl: *t = XTTokenShlAssign; return @"<<=";
    case XTAssignOpShr: *t = XTTokenShrAssign; return @">>=";
    case XTAssignOpRol: *t = XTTokenRolAssign; return @"<:=";
    case XTAssignOpRor: *t = XTTokenRorAssign; return @":>=";
        }
    *t = XTTokenAssign;
    return @"=";
    }

- (void)plExprs:(nullable NSArray<XTASTNode*>*)es
    {
    BOOL first = YES;
    for (XTASTNode* e in es)
        {
        if (!first)
            [self plTok:XTTokenComma value:@","];
        first = NO;
        [self plExpr:e];
        }
    }

// A name as its token: the parser reads a type keyword, `delete`, `retain`
// and `release` as names in places, and `par.x` in a grid as `par$x`.
- (void)plName:(NSString*)name synth:(BOOL)synth
    {
    if (synth && [name hasPrefix:@"par$"])
        {
        [self plTok:XTTokenIdentifier value:@"par"];
        [self plTok:XTTokenDot value:@"."];
        [self plTok:XTTokenIdentifier value:[name substringFromIndex:4]];
        return;
        }
    XTTokenType k = plKeyword(name);
    if (synth && k != XTTokenEOF)
        [self plTok:k value:name];
    else if (synth && [name isEqualToString:@"delete"])
        [self plTok:XTTokenDelete value:name];
    else if (synth && [name isEqualToString:@"retain"])
        [self plTok:XTTokenRetain value:name];
    else if (synth && [name isEqualToString:@"release"])
        [self plTok:XTTokenRelease value:name];
    else
        [self plTok:XTTokenIdentifier value:name];
    }

- (void)plExpr:(nullable XTASTNode*)e
    {
    if (!e)
        return;
    NSDictionary* site = [self.plSites objectForKey:e];
    if (site)
        {
        [self plSite:site];
        return;
        }
    BOOL paren = (e.srcFacts & XTSrcParen) != 0;
    if (paren)
        [self plTok:XTTokenLParen value:@"("];
    [self plExprInner:e];
    if (paren)
        [self plTok:XTTokenRParen value:@")"];
    }

- (void)plExprInner:(XTASTNode*)e
    {
    if ([e isKindOfClass:[XTIdentifierNode class]])
        {
        [self plName:((XTIdentifierNode*)e).identName synth:(e.srcFacts & XTSrcSynth) != 0];
        return;
        }
    if ([e isKindOfClass:[XTLiteralIntNode class]])
        {
        XTLiteralIntNode* l = (XTLiteralIntNode*)e;
        if (l.isNil)
            [self plTok:XTTokenNil value:@"nil"];
        else if (e.srcFacts & XTSrcPlain)
            [self plTok:XTTokenIntLiteral value:[NSString stringWithFormat:@"%lld", (long long)l.intValue]];
        else
            {
            // Equal to no other literal: only a decimal spelling is known.
            self.plLits++;
            [self plTok:XTTokenIntLiteral value:[NSString stringWithFormat:@"#%lu", (unsigned long)self.plLits]];
            }
        return;
        }
    if ([e isKindOfClass:[XTLiteralFloatNode class]])
        {
        [self plTok:XTTokenFloatLiteral value:@"0.0"];
        return;
        }
    if ([e isKindOfClass:[XTLiteralStringNode class]])
        {
        [self plTok:XTTokenStringLiteral value:((XTLiteralStringNode*)e).stringValue ?: @""];
        return;
        }
    if ([e isKindOfClass:[XTLiteralCharNode class]])
        {
        [self plTok:XTTokenCharLiteral value:[NSString stringWithFormat:@"%u", ((XTLiteralCharNode*)e).charValue]];
        return;
        }
    if ([e isKindOfClass:[XTLiteralBoolNode class]])
        {
        BOOL b = ((XTLiteralBoolNode*)e).boolValue;
        [self plTok:b ? XTTokenTrue : XTTokenFalse value:b ? @"true" : @"false"];
        return;
        }
    if ([e isKindOfClass:[XTBinaryExprNode class]])
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)e;
        XTTokenType t;
        NSString* s = plBinarySpelling(b.op, &t);
        [self plExpr:b.left];
        [self plTok:t value:s];
        [self plExpr:b.right];
        return;
        }
    if ([e isKindOfClass:[XTUnaryExprNode class]])
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)e;
        switch (u.op)
            {
        case XTUnaryOpNeg: [self plTok:XTTokenMinus value:@"-"]; break;
        case XTUnaryOpBitNot: [self plTok:XTTokenTilde value:@"~"]; break;
        case XTUnaryOpLogNot: [self plTok:XTTokenBang value:@"!"]; break;
        case XTUnaryOpAddrOf: [self plTok:XTTokenAmpersand value:@"&"]; break;
        case XTUnaryOpDeref: [self plTok:XTTokenStar value:@"*"]; break;
        case XTUnaryOpPreInc: [self plTok:XTTokenPlusPlus value:@"++"]; break;
        case XTUnaryOpPreDec: [self plTok:XTTokenMinusMinus value:@"--"]; break;
        case XTUnaryOpLoByte: [self plTok:XTTokenLess value:@"<"]; break;
        case XTUnaryOpHiByte: [self plTok:XTTokenGreater value:@">"]; break;
        case XTUnaryOpByte2: [self plTok:XTTokenShiftRight value:@">>"]; break;
        case XTUnaryOpByte3: [self plTok:XTTokenByte3 value:@">>>"]; break;
            }
        [self plExpr:u.operand];
        return;
        }
    if ([e isKindOfClass:[XTPostfixExprNode class]])
        {
        XTPostfixExprNode* p = (XTPostfixExprNode*)e;
        [self plExpr:p.operand];
        if (p.postfixOp == XTPostfixOpInc)
            [self plTok:XTTokenPlusPlus value:@"++"];
        else
            [self plTok:XTTokenMinusMinus value:@"--"];
        return;
        }
    if ([e isKindOfClass:[XTAssignExprNode class]])
        {
        XTAssignExprNode* a = (XTAssignExprNode*)e;
        XTTokenType t;
        NSString* s = plAssignSpelling(a.assignOp, &t);
        [self plExpr:a.lhs];
        [self plTok:t value:s];
        [self plExpr:a.rhs];
        return;
        }
    if ([e isKindOfClass:[XTCallExprNode class]])
        {
        XTCallExprNode* c = (XTCallExprNode*)e;
        if (c.calleeExpr)
            [self plExpr:c.calleeExpr];
        else if (c.srcFacts & XTSrcParenCallee)
            {
            [self plTok:XTTokenLParen value:@"("];
            [self plName:c.calleeName synth:NO];
            [self plTok:XTTokenRParen value:@")"];
            }
        else
            [self plName:c.calleeName synth:NO];
        [self plTok:XTTokenLParen value:@"("];
        [self plExprs:c.arguments];
        if (c.forwardsVarargs)
            {
            if (c.arguments.count)
                [self plTok:XTTokenComma value:@","];
            [self plTok:XTTokenEllipsis value:@"..."];
            }
        [self plTok:XTTokenRParen value:@")"];
        return;
        }
    if ([e isKindOfClass:[XTMethodCallExprNode class]])
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)e;
        if ((m.srcFacts & XTSrcCalled) && [m.receiver isKindOfClass:[XTIdentifierNode class]])
            [self plTok:XTTokenIdentifier value:((XTIdentifierNode*)m.receiver).identName];
        else
            {
            [self plExpr:m.receiver];
            [self plTok:XTTokenDot value:@"."];
            if (m.srcFacts & XTSrcParenCallee)
                {
                [self plTok:XTTokenLParen value:@"("];
                [self plTok:XTTokenIdentifier value:m.methodName];
                [self plTok:XTTokenRParen value:@")"];
                }
            else
                [self plTok:XTTokenIdentifier value:m.methodName];
            }
        [self plTok:XTTokenLParen value:@"("];
        [self plExprs:m.arguments];
        if (m.forwardsVarargs)
            {
            if (m.arguments.count)
                [self plTok:XTTokenComma value:@","];
            [self plTok:XTTokenEllipsis value:@"..."];
            }
        [self plTok:XTTokenRParen value:@")"];
        return;
        }
    if ([e isKindOfClass:[XTSubscriptExprNode class]])
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)e;
        [self plExpr:s.base];
        [self plTok:XTTokenLBracket value:@"["];
        [self plExpr:s.index];
        [self plTok:XTTokenRBracket value:@"]"];
        return;
        }
    if ([e isKindOfClass:[XTSliceExprNode class]])
        {
        XTSliceExprNode* s = (XTSliceExprNode*)e;
        [self plExpr:s.base];
        [self plTok:XTTokenLBracket value:@"["];
        [self plExpr:s.startExpr];
        [self plTok:s.inclusive ? XTTokenEllipsis : XTTokenDotDot value:s.inclusive ? @"..." : @".."];
        [self plExpr:s.endExpr];
        [self plTok:XTTokenRBracket value:@"]"];
        return;
        }
    if ([e isKindOfClass:[XTRangeExprNode class]])
        {
        XTRangeExprNode* r = (XTRangeExprNode*)e;
        [self plExpr:r.startExpr];
        [self plTok:r.inclusive ? XTTokenEllipsis : XTTokenDotDot value:r.inclusive ? @"..." : @".."];
        [self plExpr:r.endExpr];
        return;
        }
    if ([e isKindOfClass:[XTMemberAccessNode class]])
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)e;
        [self plExpr:m.base];
        [self plTok:m.isArrow ? XTTokenArrow : XTTokenDot value:m.isArrow ? @"->" : @"."];
        [self plTok:XTTokenIdentifier value:m.memberName];
        return;
        }
    if ([e isKindOfClass:[XTTernaryExprNode class]])
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)e;
        [self plExpr:t.condition];
        [self plTok:XTTokenQuestion value:@"?"];
        [self plExpr:t.thenExpr];
        [self plTok:XTTokenColon value:@":"];
        [self plExpr:t.elseExpr];
        return;
        }
    if ([e isKindOfClass:[XTCastExprNode class]])
        {
        XTCastExprNode* c = (XTCastExprNode*)e;
        [self plTok:XTTokenLParen value:@"("];
        [self plType:c.castType];
        if (c.isFailable)
            [self plTok:XTTokenQuestion value:@"?"];
        [self plTok:XTTokenRParen value:@")"];
        [self plExpr:c.operand];
        return;
        }
    if ([e isKindOfClass:[XTNewExprNode class]])
        {
        XTNewExprNode* n = (XTNewExprNode*)e;
        [self plTok:XTTokenNew value:@"new"];
        [self plTypeSpelling:n.className];
        if (n.countExpr)
            {
            [self plTok:XTTokenLBracket value:@"["];
            [self plExpr:n.countExpr];
            [self plTok:XTTokenRBracket value:@"]"];
            }
        else
            {
            [self plTok:XTTokenLParen value:@"("];
            [self plExprs:n.arguments];
            [self plTok:XTTokenRParen value:@")"];
            }
        return;
        }
    if ([e isKindOfClass:[XTSizeofExprNode class]])
        {
        id o = ((XTSizeofExprNode*)e).operand;
        [self plTok:XTTokenSizeof value:@"sizeof"];
        [self plTok:XTTokenLParen value:@"("];
        if ([o isKindOfClass:[XTASTNode class]])
            [self plExpr:o];
        else if ([o isKindOfClass:[XTType class]])
            [self plType:o];
        [self plTok:XTTokenRParen value:@")"];
        return;
        }
    if ([e isKindOfClass:[XTBlockNode class]])
        {
        // An initialiser list.
        [self plTok:XTTokenLBrace value:@"{"];
        [self plExprs:((XTBlockNode*)e).statements];
        [self plTok:XTTokenRBrace value:@"}"];
        return;
        }
    }

// A declaration statement: its qualifiers, its type, each declarator, `;`.
// The declarators' names are recorded at the type's first token (plDecls).
- (void)plDecls:(NSArray<XTVariableDeclNode*>*)ds semicolon:(BOOL)semi
    {
    XTVariableDeclNode* d0 = ds.firstObject;
    if (!d0)
        return;
    if (d0.isStatic)
        [self plTok:XTTokenStatic value:@"static"];
    if (d0.isGlobal)
        [self plTok:XTTokenGlobal value:@"global"];
    if (d0.isVolatile)
        [self plTok:XTTokenVolatile value:@"volatile"];
    if (d0.isRegister)
        [self plTok:XTTokenRegister value:@"register"];
    NSUInteger typeAt = self.plToks.count;
    if (d0.declaredType)
        [self plType:d0.declaredType];
    else
        [self plTok:XTTokenAuto value:@"auto"];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    BOOL first = YES;
    for (XTVariableDeclNode* d in ds)
        {
        if (!first)
            [self plTok:XTTokenComma value:@","];
        first = NO;
        [names addObject:d.varName];
        [self plTok:XTTokenIdentifier value:d.varName];
        [self plDims:d.declaredType];
        if (d.constructorArgs)
            {
            [self plTok:XTTokenLParen value:@"("];
            [self plExprs:d.constructorArgs];
            [self plTok:XTTokenRParen value:@")"];
            }
        else if (d.initialiser)
            {
            [self plTok:XTTokenAssign value:@"="];
            [self plExpr:d.initialiser];
            }
        }
    if (typeAt < self.plToks.count)
        self.plDecls[@(typeAt)] = names;
    if (semi)
        [self plTok:XTTokenSemicolon value:@";"];
    }

- (void)plStmts:(nullable NSArray<XTASTNode*>*)ss
    {
    for (XTASTNode* s in ss)
        {
        if (self.plSkipWhileIf)
            {
            // The `if (v < B) v = B;` a rewritten `while` left after it (or
            // after the statement it was the body of).
            self.plSkipWhileIf = NO;
            continue;
            }
        [self plStmt:s];
        }
    }

- (void)plBody:(nullable XTASTNode*)b
    {
    [self plStmt:b];
    }

// A loop's annotations, `: unroll, serial, goal(speed)`.
- (void)plAnnotations:(XTASTNode*)n unroll:(BOOL)unroll goal:(NSInteger)goal
    {
    BOOL serial = (n.srcFacts & XTSrcSerial) != 0;
    BOOL ownGoal = (n.srcFacts & XTSrcGoal) != 0;
    BOOL other = (n.srcFacts & XTSrcAnnot) != 0;
    if (!unroll && !serial && !ownGoal && !other)
        return;
    [self plTok:XTTokenColon value:@":"];
    BOOL first = YES;
    if (other)
        {
        // An annotation the parser does not know (its word is not kept).
        [self plTok:XTTokenIdentifier value:@"_"];
        first = NO;
        }
    if (unroll)
        {
        [self plTok:XTTokenIdentifier value:@"unroll"];
        first = NO;
        }
    if (serial)
        {
        if (!first)
            [self plTok:XTTokenComma value:@","];
        [self plTok:XTTokenIdentifier value:@"serial"];
        first = NO;
        }
    if (ownGoal)
        {
        if (!first)
            [self plTok:XTTokenComma value:@","];
        [self plTok:XTTokenIdentifier value:@"goal"];
        [self plTok:XTTokenLParen value:@"("];
        [self plTok:XTTokenIdentifier value:goal == 1 ? @"speed" : @"accuracy"];
        [self plTok:XTTokenRParen value:@")"];
        }
    }

// A `for`: its header, recording where its parts start for the recogniser
// (plMarks) when it is the loop being read, then its annotations and body.
- (void)plFor:(XTForCStyleNode*)f marks:(nullable NSMutableDictionary*)marks
    {
    [self plTok:XTTokenFor value:@"for"];
    [self plTok:XTTokenLParen value:@"("];
    XTVariableDeclNode* d = [f.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopInit : nil;
    if (f.srcFacts & XTSrcRange)
        {
        // `T v in a .. b [step s]`, from the C-style form it became.
        if (d.declaredType)
            [self plType:d.declaredType];
        [self plTok:XTTokenIdentifier value:d ? d.varName : @"_"];
        [self plTok:XTTokenIn value:@"in"];
        [self plExpr:d.initialiser];
        XTBinaryExprNode* c = [f.condition isKindOfClass:[XTBinaryExprNode class]] ? (XTBinaryExprNode*)f.condition : nil;
        BOOL incl = c && (c.op == XTBinaryOpLe || c.op == XTBinaryOpGe);
        [self plTok:incl ? XTTokenEllipsis : XTTokenDotDot value:incl ? @"..." : @".."];
        marks[@"bndFrom"] = @(self.plToks.count);
        [self plExpr:c.right];
        marks[@"bndTo"] = @(self.plToks.count);
        XTAssignExprNode* st = [f.increment isKindOfClass:[XTAssignExprNode class]] ? (XTAssignExprNode*)f.increment : nil;
        int64_t mag = [st.rhs isKindOfClass:[XTLiteralIntNode class]] ? ((XTLiteralIntNode*)st.rhs).intValue : 1;
        BOOL down = st && st.assignOp == XTAssignOpSub;
        BOOL lits = [d.initialiser isKindOfClass:[XTLiteralIntNode class]] && [c.right isKindOfClass:[XTLiteralIntNode class]];
        if (f.srcFacts & XTSrcStepBad)
            {
            [self plTok:XTTokenIdentifier value:@"step"];
            [self plTok:XTTokenIdentifier value:@"_"];
            }
        else if (mag != 1 || (down && !lits))
            {
            [self plTok:XTTokenIdentifier value:@"step"];
            if (down)
                [self plTok:XTTokenMinus value:@"-"];
            [self plTok:XTTokenIntLiteral value:[NSString stringWithFormat:@"%lld", (long long)mag]];
            }
        }
    else
        {
        marks[@"initFrom"] = @(self.plToks.count);
        if (d)
            [self plDecls:@[ d ] semicolon:YES];
        else if ([f.loopInit isKindOfClass:[XTBlockNode class]] && ((XTBlockNode*)f.loopInit).isDeclList)
            [self plDecls:(NSArray<XTVariableDeclNode*>*)((XTBlockNode*)f.loopInit).statements semicolon:YES];
        else
            {
            [self plExpr:f.loopInit];
            [self plTok:XTTokenSemicolon value:@";"];
            }
        marks[@"initTo"] = @(self.plToks.count - 1);
        marks[@"condFrom"] = @(self.plToks.count);
        [self plExpr:f.condition];
        marks[@"condTo"] = @(self.plToks.count);
        [self plTok:XTTokenSemicolon value:@";"];
        [self plExpr:f.increment];
        }
    [self plTok:XTTokenRParen value:@")"];
    [self plAnnotations:f unroll:f.forceUnroll goal:f.goal];
    marks[@"pe"] = @(self.plToks.count - 1);
    [self plBody:f.body];
    }

// A site the parser recorded: a block literal (0), a written par block (1),
// a lifted loop (2), a counted `while` it rewrote to a `for` (3), as written.
- (void)plSite:(NSDictionary*)e
    {
    NSInteger kind = [e[@"kind"] integerValue];
    if (kind == 2)
        {
        [self plStmt:e[@"plain"]];
        return;
        }
    if (kind == 3)
        {
        [self plWhileFrom:e[@"plain"] inc:[e[@"inc"] integerValue]];
        self.plSkipWhileIf = YES;
        return;
        }
    if (kind == 1)
        {
        // A written par block: its header as written, then its body.
        for (XTToken* t in e[@"head"])
            [self plTok:t.type value:t.value ?: @""];
        [self plStmt:e[@"body"]];
        return;
        }
    [self plTok:XTTokenIdentifier value:@"block"];
    [self plTok:XTTokenVoid value:@"void"];
    [self plTok:XTTokenLParen value:@"("];
    BOOL first = YES;
    for (XTParamNode* p in e[@"params"])
        {
        if (!first)
            [self plTok:XTTokenComma value:@","];
        first = NO;
        [self plType:p.paramType];
        [self plTok:XTTokenIdentifier value:p.paramName];
        }
    [self plTok:XTTokenRParen value:@")"];
    [self plStmt:e[@"body"]];
    }

// `while (v < B) { …; v++; }` from the `for` the parser made of it:
// `for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1) { T v =
// __autopar_w; … }`, with the increment as it was spelt (1 `v++`, 2 `++v`,
// 3 `v += 1`, 4 `v = v + 1`).
- (void)plWhileFrom:(nullable XTASTNode*)n inc:(NSInteger)inc
    {
    XTForCStyleNode* f = [n isKindOfClass:[XTForCStyleNode class]] ? (XTForCStyleNode*)n : nil;
    XTVariableDeclNode* d = [f.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopInit : nil;
    XTBinaryExprNode* c = [f.condition isKindOfClass:[XTBinaryExprNode class]] ? (XTBinaryExprNode*)f.condition : nil;
    if (!f || !d || !c || ![d.initialiser isKindOfClass:[XTIdentifierNode class]])
        {
        [self plStmt:n];
        return;
        }
    NSString* v = ((XTIdentifierNode*)d.initialiser).identName;
    [self plTok:XTTokenWhile value:@"while"];
    [self plTok:XTTokenLParen value:@"("];
    [self plTok:XTTokenIdentifier value:v];
    [self plTok:c.op == XTBinaryOpLe ? XTTokenLessEq : XTTokenLess value:c.op == XTBinaryOpLe ? @"<=" : @"<"];
    [self plExpr:c.right];
    [self plTok:XTTokenRParen value:@")"];
    [self plTok:XTTokenLBrace value:@"{"];
    NSArray<XTASTNode*>* ss = [f.body isKindOfClass:[XTBlockNode class]] ? ((XTBlockNode*)f.body).statements : @[];
    if (ss.count > 1)
        [self plStmts:[ss subarrayWithRange:NSMakeRange(1, ss.count - 1)]];
    switch (inc)
        {
    case 2:
        [self plTok:XTTokenPlusPlus value:@"++"];
        [self plTok:XTTokenIdentifier value:v];
        break;
    case 3:
        [self plTok:XTTokenIdentifier value:v];
        [self plTok:XTTokenPlusAssign value:@"+="];
        [self plTok:XTTokenIntLiteral value:@"1"];
        break;
    case 4:
        [self plTok:XTTokenIdentifier value:v];
        [self plTok:XTTokenAssign value:@"="];
        [self plTok:XTTokenIdentifier value:v];
        [self plTok:XTTokenPlus value:@"+"];
        [self plTok:XTTokenIntLiteral value:@"1"];
        break;
    default:
        [self plTok:XTTokenIdentifier value:v];
        [self plTok:XTTokenPlusPlus value:@"++"];
        break;
        }
    [self plTok:XTTokenSemicolon value:@";"];
    [self plTok:XTTokenRBrace value:@"}"];
    }

- (void)plStmt:(nullable XTASTNode*)n
    {
    if (!n || (n.srcFacts & XTSrcSynth))
        return;
    NSDictionary* site = [self.plSites objectForKey:n];
    if (site)
        {
        [self plSite:site];
        return;
        }
    if ([n isKindOfClass:[XTBlockNode class]])
        {
        XTBlockNode* b = (XTBlockNode*)n;
        if (b.isDeclList)
            {
            NSMutableArray<XTVariableDeclNode*>* ds = [NSMutableArray array];
            for (XTASTNode* s in b.statements)
                if ([s isKindOfClass:[XTVariableDeclNode class]])
                    [ds addObject:(XTVariableDeclNode*)s];
            [self plDecls:ds semicolon:YES];
            return;
            }
        [self plTok:XTTokenLBrace value:@"{"];
        [self plStmts:b.statements];
        [self plTok:XTTokenRBrace value:@"}"];
        return;
        }
    if ([n isKindOfClass:[XTVariableDeclNode class]])
        {
        [self plDecls:@[ (XTVariableDeclNode*)n ] semicolon:YES];
        return;
        }
    if ([n isKindOfClass:[XTExpressionStatementNode class]])
        {
        [self plExpr:((XTExpressionStatementNode*)n).expression];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTIfNode class]])
        {
        XTIfNode* i = (XTIfNode*)n;
        [self plTok:XTTokenIf value:@"if"];
        [self plTok:XTTokenLParen value:@"("];
        [self plExpr:i.condition];
        [self plTok:XTTokenRParen value:@")"];
        [self plBody:i.thenBlock];
        if (i.elseBlock)
            {
            [self plTok:XTTokenElse value:@"else"];
            [self plBody:i.elseBlock];
            }
        return;
        }
    if ([n isKindOfClass:[XTWhileNode class]])
        {
        XTWhileNode* w = (XTWhileNode*)n;
        [self plTok:XTTokenWhile value:@"while"];
        [self plTok:XTTokenLParen value:@"("];
        [self plExpr:w.condition];
        [self plTok:XTTokenRParen value:@")"];
        [self plBody:w.body];
        return;
        }
    if ([n isKindOfClass:[XTForCStyleNode class]])
        {
        [self plFor:(XTForCStyleNode*)n marks:nil];
        return;
        }
    if ([n isKindOfClass:[XTForInNode class]])
        {
        XTForInNode* f = (XTForInNode*)n;
        [self plTok:XTTokenFor value:@"for"];
        [self plTok:XTTokenLParen value:@"("];
        XTVariableDeclNode* v = [f.loopVar isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopVar : nil;
        if (v.declaredType)
            [self plType:v.declaredType];
        [self plTok:XTTokenIdentifier value:v ? v.varName : @"_"];
        [self plTok:XTTokenIn value:@"in"];
        [self plExpr:f.collection];
        [self plTok:XTTokenRParen value:@")"];
        [self plBody:f.body];
        return;
        }
    if ([n isKindOfClass:[XTReturnNode class]])
        {
        [self plTok:XTTokenReturn value:@"return"];
        [self plExprs:((XTReturnNode*)n).values];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTBreakNode class]])
        {
        [self plTok:XTTokenBreak value:@"break"];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTContinueNode class]])
        {
        [self plTok:XTTokenContinue value:@"continue"];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTGotoNode class]])
        {
        [self plTok:XTTokenGoto value:@"goto"];
        [self plTok:XTTokenIdentifier value:((XTGotoNode*)n).targetLabel];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTLabelNode class]])
        {
        [self plTok:XTTokenIdentifier value:((XTLabelNode*)n).labelName];
        [self plTok:XTTokenColon value:@":"];
        return;
        }
    if ([n isKindOfClass:[XTSwitchNode class]])
        {
        XTSwitchNode* s = (XTSwitchNode*)n;
        [self plTok:XTTokenSwitch value:@"switch"];
        [self plTok:XTTokenLParen value:@"("];
        [self plExpr:s.subject];
        [self plTok:XTTokenRParen value:@")"];
        [self plTok:XTTokenLBrace value:@"{"];
        for (XTSwitchCase* c in s.cases)
            {
            if (c.isDefault && !c.labels.count)
                {
                [self plTok:XTTokenDefault value:@"default"];
                [self plTok:XTTokenColon value:@":"];
                }
            for (XTCaseLabel* l in c.labels)
                {
                [self plTok:XTTokenCase value:@"case"];
                if (l.isRange)
                    {
                    [self plExpr:l.rangeLo];
                    [self plTok:XTTokenDotDot value:@".."];
                    [self plExpr:l.rangeHi];
                    }
                else
                    [self plExpr:l.singleValue];
                [self plTok:XTTokenColon value:@":"];
                }
            if (c.isDefault && c.labels.count)
                {
                [self plTok:XTTokenDefault value:@"default"];
                [self plTok:XTTokenColon value:@":"];
                }
            [self plStmts:c.body];
            }
        [self plTok:XTTokenRBrace value:@"}"];
        return;
        }
    if ([n isKindOfClass:[XTDeferNode class]])
        {
        [self plTok:XTTokenDefer value:@"defer"];
        [self plStmt:((XTDeferNode*)n).body];
        return;
        }
    if ([n isKindOfClass:[XTThrowNode class]])
        {
        [self plTok:XTTokenThrow value:@"throw"];
        [self plExpr:((XTThrowNode*)n).operand];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTTryNode class]])
        {
        XTTryNode* t = (XTTryNode*)n;
        [self plTok:XTTokenTry value:@"try"];
        [self plStmt:t.tryBlock];
        for (XTCatchClause* c in t.catchClauses)
            {
            [self plTok:XTTokenCatch value:@"catch"];
            [self plTok:XTTokenLParen value:@"("];
            if (c.typeName)
                [self plTypeSpelling:c.typeName];
            [self plTok:XTTokenIdentifier value:c.varName];
            [self plTok:XTTokenRParen value:@")"];
            [self plStmt:c.block];
            }
        return;
        }
    if ([n isKindOfClass:[XTDeleteNode class]])
        {
        XTDeleteNode* d = (XTDeleteNode*)n;
        if (d.op == XTRefOpRetain)
            [self plTok:XTTokenRetain value:@"retain"];
        else if (d.op == XTRefOpRelease)
            [self plTok:XTTokenRelease value:@"release"];
        else
            [self plTok:XTTokenDelete value:@"delete"];
        [self plExpr:d.operand];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    if ([n isKindOfClass:[XTAsmBlockNode class]])
        {
        [self plTok:XTTokenAsm value:@"asm"];
        [self plTok:XTTokenLBrace value:@"{"];
        [self plTok:XTTokenRBrace value:@"}"];
        return;
        }
    if ([n isKindOfClass:[XTTupleAssignNode class]])
        {
        XTTupleAssignNode* t = (XTTupleAssignNode*)n;
        [self plTok:XTTokenLParen value:@"("];
        BOOL first = YES;
        for (XTASTNode* x in t.targets)
            {
            if (!first)
                [self plTok:XTTokenComma value:@","];
            first = NO;
            if ([x isKindOfClass:[XTVariableDeclNode class]])
                {
                XTVariableDeclNode* d = (XTVariableDeclNode*)x;
                [self plType:d.declaredType];
                [self plTok:XTTokenIdentifier value:d.varName];
                }
            else
                [self plExpr:x];
            }
        [self plTok:XTTokenRParen value:@")"];
        [self plTok:XTTokenAssign value:@"="];
        [self plExpr:t.sourceExpr];
        [self plTok:XTTokenSemicolon value:@";"];
        return;
        }
    // An expression where a statement goes (a `for`'s init clause).
    [self plExpr:n];
    }

// ── The recogniser ──────────────────────────────────────────────────────

// The C-style condition the scan takes, its first two tokens `var` and `<`
// or `<=` (as pacCondOk, for any variable).
static BOOL plCondOk(XTASTNode* _Nullable n, NSString* var)
    {
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

// The C-style step the scan takes (as pacStepOk, for any variable).
static BOOL plStepOk(XTASTNode* _Nullable st, NSString* var)
    {
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

// The walk's tokens for `n`, a loop: the parser's tokens are set aside and
// these read in their place, until plEnd.
- (void)plBegin
    {
    self.plToks = [NSMutableArray array];
    self.plDecls = [NSMutableDictionary dictionary];
    self.plLits = 0;
    self.plSkipWhileIf = NO;
    }

- (NSDictionary*)plStateSave
    {
    NSMutableDictionary* s = [NSMutableDictionary dictionary];
    s[@"tokens"] = self.tokens;
    s[@"pos"] = @(self.pos);
    if (self.parAutoWhy) s[@"why"] = self.parAutoWhy;
    if (self.parAutoForm) s[@"form"] = self.parAutoForm;
    s[@"cap"] = @(self.parAutoGridCap);
    if (self.parScanAcc) s[@"acc"] = self.parScanAcc;
    if (self.parScanOp) s[@"op"] = self.parScanOp;
    s[@"seen"] = @(self.pacSeen);
    s[@"val"] = @(self.pacVal);
    return s;
    }

- (void)plStateRestore:(NSDictionary*)s
    {
    self.tokens = s[@"tokens"];
    self.pos = [s[@"pos"] unsignedIntegerValue];
    self.parAutoWhy = s[@"why"];
    self.parAutoForm = s[@"form"];
    self.parAutoGridCap = [s[@"cap"] unsignedIntegerValue];
    self.parScanAcc = s[@"acc"];
    self.parScanOp = s[@"op"];
    self.pacSeen = [s[@"seen"] unsignedIntegerValue];
    self.pacVal = [s[@"val"] unsignedIntegerValue];
    self.plStream = NO;
    self.plToks = nil;
    self.plDecls = nil;
    }

// The recogniser's verdict on `loop`, a `for` as parsed (the loop as
// written, or the `for` a counted `while` became): lift, rule, form, reds,
// grid, scan and goal, as parAutoFor reads them from the scan, and small.
- (NSDictionary*)plRecogniseFor:(nullable XTASTNode*)loop at:(XTSourceLocation*)loc
    {
    NSMutableDictionary* v = [NSMutableDictionary dictionary];
    v[@"lift"] = @NO;
    v[@"form"] = @"for";
    NSUInteger goal = self.goalNow ?: self.goalDefault;
    NSString* file = loc.filename;
    if (file && [self.libraryFiles containsObject:file])
        {
        v[@"rule"] = @"library";
        return v;
        }
    if ([loop isKindOfClass:[XTForInNode class]])
        {
        v[@"form"] = @"range";
        v[@"rule"] = @"header";
        return v;
        }
    if (![loop isKindOfClass:[XTForCStyleNode class]])
        {
        v[@"rule"] = @"header";
        return v;
        }
    XTForCStyleNode* f = (XTForCStyleNode*)loop;
    XTVariableDeclNode* d = [f.loopInit isKindOfClass:[XTVariableDeclNode class]] ? (XTVariableDeclNode*)f.loopInit : nil;
    BOOL range = (f.srcFacts & XTSrcRange) != 0;
    if (!range && d && [d.varName isEqualToString:@"__autopar_w"])
        v[@"form"] = @"while";
    // The loop's tokens, from its tree.
    NSDictionary* saved = [self plStateSave];
    self.plLoc = loc;
    [self plBegin];
    NSMutableDictionary* marks = [NSMutableDictionary dictionary];
    [self plFor:f marks:marks];
    NSArray<XTToken*>* toks = self.plToks;
    NSDictionary* decls = self.plDecls;
    self.plToks = nil;
    NSString* var = nil;
    NSUInteger bndFrom = 0, bndTo = 0;
    NSString* rule = nil;
    if (range)
        {
        if (![v[@"form"] isEqualToString:@"while"])
            v[@"form"] = @"range";
        XTBinaryExprNode* c = [f.condition isKindOfClass:[XTBinaryExprNode class]] ? (XTBinaryExprNode*)f.condition : nil;
        var = d.varName;
        // A `step` with no literal stops the scan before it names the form.
        if ((f.srcFacts & XTSrcStepBad) || pacStepInBound(c.right))
            {
            rule = @"step";
            v[@"form"] = @"for";
            }
        else if (f.srcFacts & XTSrcDesc)
            rule = @"descending";
        bndFrom = [marks[@"bndFrom"] unsignedIntegerValue];
        bndTo = [marks[@"bndTo"] unsignedIntegerValue];
        }
    else
        {
        // The init clause, as the scan reads its tokens: the first `=`, a
        // name before it, and a type before the name.
        NSUInteger i0 = [marks[@"initFrom"] unsignedIntegerValue];
        NSUInteger semi1 = [marks[@"initTo"] unsignedIntegerValue];
        NSUInteger eq = 0;
        for (NSUInteger i = i0; i < semi1; i++)
            if (toks[i].type == XTTokenAssign)
                {
                eq = i;
                break;
                }
        // The scan's token numbers count from the `for` (0) and its `(` (1).
        if (semi1 == i0 || toks[semi1 - 1].type == XTTokenAssign)
            rule = @"header";
        else if (eq == 0 || toks[eq - 1].type != XTTokenIdentifier)
            rule = @"header";
        else if (eq < 4)
            rule = @"outer-variable";
        else
            {
            var = toks[eq - 1].value;
            if (!plCondOk(f.condition, var))
                rule = @"condition";
            else if (!plStepOk(f.increment, var))
                rule = @"step";
            bndFrom = [marks[@"condFrom"] unsignedIntegerValue] + 2;
            bndTo = [marks[@"condTo"] unsignedIntegerValue];
            }
        }
    if (!rule && (f.srcFacts & XTSrcSerial))
        rule = @"serial";
    if (!rule && (f.srcFacts & XTSrcGoal))
        goal = f.goal == 1 ? 1 : 2;
    if (rule)
        {
        v[@"rule"] = rule;
        [self plStateRestore:saved];
        return v;
        }
    // The body, on the walk's tokens.
    self.tokens = toks;
    self.pos = 0;
    self.plStream = YES;
    self.plDecls = [decls mutableCopy];
    self.parAutoWhy = nil;
    self.parAutoGridCap = 3;
    self.parScanAcc = nil;
    self.parScanOp = nil;
    NSMutableArray<NSArray<NSString*>*>* reds = [NSMutableArray array];
    BOOL lift = [self parAutoScanBodyAfter:[marks[@"pe"] unsignedIntegerValue] var:var boundFrom:bndFrom to:bndTo reds:reds goal:&goal];
    v[@"lift"] = @(lift);
    if (lift)
        v[@"goal"] = @(goal);
    if (!lift)
        v[@"rule"] = self.parAutoWhy ?: @"?";
    else
        {
        v[@"grid"] = @(self.parAutoGridCap);
        NSMutableArray<NSString*>* rl = [NSMutableArray array];
        for (NSArray<NSString*>* r in reds)
            [rl addObject:[NSString stringWithFormat:@"%@:%@%@", r[0], r[1], r.count > 2 ? @"[]" : @""]];
        v[@"reds"] = [rl componentsJoinedByString:@","];
        if (self.parScanAcc)
            v[@"scan"] = [NSString stringWithFormat:@"%@:%@", self.parScanOp, self.parScanAcc];
        v[@"small"] = @([self parAutoSmall:f from:0 to:toks.count]);
        }
    [self plStateRestore:saved];
    return v;
    }

// The recogniser on a `while` the scan left alone (or on the `while` a
// rewritten `for` was, `inc` its increment's spelling): whether the counted
// form takes it, and the rule when it does not.
- (NSDictionary*)plRecogniseWhile:(nullable XTASTNode*)n inc:(NSInteger)inc at:(XTSourceLocation*)loc
    {
    NSDictionary* saved = [self plStateSave];
    self.plLoc = loc;
    [self plBegin];
    if ([n isKindOfClass:[XTForCStyleNode class]])
        [self plWhileFrom:n inc:inc];
    else
        [self plStmt:n];
    self.tokens = self.plToks;
    self.pos = 0;
    self.plStream = YES;
    self.parAutoWhy = nil;
    BOOL ok = [self parAutoWhileShape];
    NSString* why = self.parAutoWhy;
    [self plStateRestore:saved];
    return @{ @"lift" : @(ok), @"rule" : ok ? @"-" : (why ?: @"while-shape") };
    }

static NSString* plField(NSDictionary* d, NSString* k)
    {
    id x = d[k];
    if (!x)
        return @"-";
    if ([x isKindOfClass:[NSNumber class]])
        return [x stringValue];
    return [x length] ? x : @"-";
    }

// XC_PAR_AUTO_CHECK=recog: the line for the loop at `loc`, the scan's
// verdict against the recogniser's, field by field.
- (void)plCompare:(NSDictionary*)scan recog:(NSDictionary*)recog at:(XTSourceLocation*)loc
    {
    NSString* file = loc.filename ?: @"?";
    if ([self.libraryFiles containsObject:file])
        return;
    NSMutableString* out = [NSMutableString string];
    BOOL same = YES;
    for (NSString* k in @[ @"lift", @"rule", @"form", @"reds", @"grid", @"scan", @"goal", @"small", @"while" ])
        {
        NSString* a = plField(scan, k);
        NSString* b = plField(recog, k);
        [out appendFormat:@" %@=%@", k, a];
        if (![a isEqualToString:b])
            {
            [out appendFormat:@"/%@!", b];
            same = NO;
            }
        }
    [self parAutoAddLine:[NSString stringWithFormat:@"par-auto-check: %@:%lu:%lu recog %@%@", file.lastPathComponent,
                                                    (unsigned long)loc.line, (unsigned long)loc.column,
                                                    same ? @"same" : @"differ", out]];
    }

- (void)plCheckFor:(nullable XTASTNode*)plain at:(XTSourceLocation*)loc scan:(NSDictionary*)scan fromWhile:(BOOL)fromWhile
    {
    if (!self.parAutoRecogOn)
        return;
    NSMutableDictionary* r = [[self plRecogniseFor:plain at:loc] mutableCopy];
    if (fromWhile)
        {
        // The `while` it was, too: the counted form must take it.
        NSDictionary* w = [self plRecogniseWhile:plain inc:self.plWhileInc at:loc];
        if (![w[@"lift"] boolValue])
            r[@"while"] = w[@"rule"];
        }
    [self plCompare:scan recog:r at:loc];
    }

- (void)plCheckWhile:(nullable XTASTNode*)w at:(XTSourceLocation*)loc why:(NSString*)why
    {
    if (!self.parAutoRecogOn)
        return;
    NSDictionary* r = [self plRecogniseWhile:w inc:0 at:loc];
    NSMutableDictionary* scan = [NSMutableDictionary dictionary];
    scan[@"lift"] = @NO;
    scan[@"rule"] = why;
    scan[@"form"] = @"while";
    NSMutableDictionary* recog = [NSMutableDictionary dictionary];
    recog[@"lift"] = r[@"lift"];
    recog[@"rule"] = [r[@"lift"] boolValue] ? @"-" : r[@"rule"];
    recog[@"form"] = @"while";
    [self plCompare:scan recog:recog at:loc];
    }

// A site for the walk: kind as plSite reads it.
- (void)plRegister:(nullable XTASTNode*)site entry:(NSDictionary*)e
    {
    if (!site || !self.parAutoRecogOn)
        return;
    if (!self.plSites)
        self.plSites = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                             valueOptions:NSPointerFunctionsStrongMemory];
    [self.plSites setObject:e forKey:site];
    }

@end

NS_ASSUME_NONNULL_END
