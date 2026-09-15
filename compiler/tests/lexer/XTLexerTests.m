#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTDiagnosticEngine.h"
#import "XTFloatEncoding.h"

#define ASSERT_TOK(tokens, idx, expectedType, msg) do { \
    if ((NSUInteger)(idx) >= (tokens).count) { fprintf(stderr, "  FAIL: %s (index %d out of bounds)\n", msg, idx); failures++; } \
    else if ((tokens)[(idx)].type != (expectedType)) { fprintf(stderr, "  FAIL: %s (expected %s, got %s '%s')\n", msg, XTTokenTypeName(expectedType).UTF8String, XTTokenTypeName((tokens)[(idx)].type).UTF8String, (tokens)[(idx)].value.UTF8String); failures++; } \
    else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

#define ASSERT_TRUE(cond, msg) do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

static NSArray<XTToken *> *lex(NSString *source) {
    XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
    XTLexer *lexer = [[XTLexer alloc] initWithSource:source filename:@"test.xc" diagnostics:diag];
    return [lexer tokenise];
}

int runLexerTests(void) {
    int failures = 0;

    // Test 1: Keywords
    {
        NSArray<XTToken *> *tokens = lex(@"if else while for return");
        ASSERT_TOK(tokens, 0, XTTokenIf, "keyword if");
        ASSERT_TOK(tokens, 1, XTTokenElse, "keyword else");
        ASSERT_TOK(tokens, 2, XTTokenWhile, "keyword while");
        ASSERT_TOK(tokens, 3, XTTokenFor, "keyword for");
        ASSERT_TOK(tokens, 4, XTTokenReturn, "keyword return");
    }

    // Test 2: Types
    {
        NSArray<XTToken *> *tokens = lex(@"i8 u8 i16 u16 i32 u32 bool float void");
        ASSERT_TOK(tokens, 0, XTTokenI8, "type i8");
        ASSERT_TOK(tokens, 1, XTTokenU8, "type u8");
        ASSERT_TOK(tokens, 2, XTTokenI16, "type i16");
        ASSERT_TOK(tokens, 3, XTTokenU16, "type u16");
        ASSERT_TOK(tokens, 4, XTTokenI32, "type i32");
        ASSERT_TOK(tokens, 5, XTTokenU32, "type u32");
        ASSERT_TOK(tokens, 6, XTTokenBool, "type bool");
        ASSERT_TOK(tokens, 7, XTTokenFloat, "type float");
        ASSERT_TOK(tokens, 8, XTTokenVoid, "type void");
    }

    // Test 3: Decimal integer
    {
        NSArray<XTToken *> *tokens = lex(@"42");
        ASSERT_TOK(tokens, 0, XTTokenIntLiteral, "decimal integer");
        ASSERT_TRUE(tokens[0].intValue == 42, "decimal value is 42");
    }

    // Test 4: Hex integer with $ prefix
    {
        NSArray<XTToken *> *tokens = lex(@"$FF");
        ASSERT_TOK(tokens, 0, XTTokenIntLiteral, "hex integer");
        ASSERT_TRUE(tokens[0].intValue == 255, "hex $FF = 255");
    }

    // Test 5: Binary integer with % prefix
    {
        NSArray<XTToken *> *tokens = lex(@"%1010");
        ASSERT_TOK(tokens, 0, XTTokenIntLiteral, "binary integer");
        ASSERT_TRUE(tokens[0].intValue == 10, "binary %1010 = 10");
    }

    // Test 6: Underscores in numbers
    {
        NSArray<XTToken *> *tokens = lex(@"1_000_000");
        ASSERT_TRUE(tokens[0].intValue == 1000000, "underscores stripped in integer");
    }

    // Test 7: Float literal
    {
        NSArray<XTToken *> *tokens = lex(@"3.14");
        ASSERT_TOK(tokens, 0, XTTokenFloatLiteral, "float literal");
        ASSERT_TRUE(tokens[0].floatData.length == 4, "float data is 4 IEEE bytes");
    }

    // Test 8: String literal
    {
        NSArray<XTToken *> *tokens = lex(@"\"hello\"");
        ASSERT_TOK(tokens, 0, XTTokenStringLiteral, "string literal");
        ASSERT_TRUE([tokens[0].value isEqualToString:@"hello"], "string value is 'hello'");
    }

    // Test 9: Char literal
    {
        NSArray<XTToken *> *tokens = lex(@"'A'");
        ASSERT_TOK(tokens, 0, XTTokenCharLiteral, "char literal");
        ASSERT_TRUE(tokens[0].intValue == 65, "char 'A' = 65");
    }

    // Test 10: Escape sequences
    {
        NSArray<XTToken *> *tokens = lex(@"'\\n'");
        ASSERT_TRUE(tokens[0].intValue == 10, "char '\\n' = 10");
    }

    // Test 11: Operators
    {
        NSArray<XTToken *> *tokens = lex(@"+ - * / % << >> <: :> ++ -- @ -> .");
        ASSERT_TOK(tokens, 0, XTTokenPlus, "op +");
        ASSERT_TOK(tokens, 1, XTTokenMinus, "op -");
        ASSERT_TOK(tokens, 2, XTTokenStar, "op *");
        ASSERT_TOK(tokens, 3, XTTokenSlash, "op /");
        ASSERT_TOK(tokens, 4, XTTokenPercent, "op %");
        ASSERT_TOK(tokens, 5, XTTokenShiftLeft, "op <<");
        ASSERT_TOK(tokens, 6, XTTokenShiftRight, "op >>");
        ASSERT_TOK(tokens, 7, XTTokenRotateLeft, "op <:");
        ASSERT_TOK(tokens, 8, XTTokenRotateRight, "op :>");
        ASSERT_TOK(tokens, 9, XTTokenPlusPlus, "op ++");
        ASSERT_TOK(tokens, 10, XTTokenMinusMinus, "op --");
        ASSERT_TOK(tokens, 11, XTTokenAt, "op @");
        ASSERT_TOK(tokens, 12, XTTokenArrow, "op ->");
        ASSERT_TOK(tokens, 13, XTTokenDot, "op .");
    }

    // Test 12: adjacent parens stay SEPARATE tokens. The lexer used to fuse
    // them into one `((` for the alternative block syntax, which meant the
    // parser had to split the token back apart to read `((T@)p).f` — the
    // syntax is gone, and with it the fusing.
    {
        NSArray<XTToken *> *tokens = lex(@"(( ))");
        ASSERT_TOK(tokens, 0, XTTokenLParen, "(");
        ASSERT_TOK(tokens, 1, XTTokenLParen, "(");
        ASSERT_TOK(tokens, 2, XTTokenRParen, ")");
        ASSERT_TOK(tokens, 3, XTTokenRParen, ")");
    }

    // Test 13: Ellipsis
    {
        NSArray<XTToken *> *tokens = lex(@"...");
        ASSERT_TOK(tokens, 0, XTTokenEllipsis, "...");
    }

    // Test 14: Comments stripped
    {
        NSArray<XTToken *> *tokens = lex(@"x // line comment\ny /* block */ z");
        ASSERT_TOK(tokens, 0, XTTokenIdentifier, "ident before line comment");
        ASSERT_TOK(tokens, 1, XTTokenIdentifier, "ident after line comment");
        ASSERT_TOK(tokens, 2, XTTokenIdentifier, "ident after block comment");
    }

    // Test 15: Assignment operators
    {
        NSArray<XTToken *> *tokens = lex(@"+= -= *= /= %= &= |= ^= <<= >>= <:= :>=");
        ASSERT_TOK(tokens, 0, XTTokenPlusAssign, "+=");
        ASSERT_TOK(tokens, 1, XTTokenMinusAssign, "-=");
        ASSERT_TOK(tokens, 2, XTTokenStarAssign, "*=");
        ASSERT_TOK(tokens, 3, XTTokenSlashAssign, "/=");
        ASSERT_TOK(tokens, 4, XTTokenPercentAssign, "%=");
        ASSERT_TOK(tokens, 5, XTTokenAmpAssign, "&=");
        ASSERT_TOK(tokens, 6, XTTokenPipeAssign, "|=");
        ASSERT_TOK(tokens, 7, XTTokenCaretAssign, "^=");
        ASSERT_TOK(tokens, 8, XTTokenShlAssign, "<<=");
        ASSERT_TOK(tokens, 9, XTTokenShrAssign, ">>=");
        ASSERT_TOK(tokens, 10, XTTokenRolAssign, "<:=");
        ASSERT_TOK(tokens, 11, XTTokenRorAssign, ":>=");
    }

    // Test 16: Float encoding round-trip
    {
        double original = 3.14;
        NSData *encoded = [XTFloatEncoding encodeDouble:original];
        double decoded = [XTFloatEncoding decodeData:encoded];
        double diff = fabs(decoded - original);
        ASSERT_TRUE(diff < 0.01, "float encode/decode round-trip 3.14");
    }

    // Test 17: Boolean literals
    {
        NSArray<XTToken *> *tokens = lex(@"true false");
        ASSERT_TOK(tokens, 0, XTTokenTrue, "true literal");
        ASSERT_TOK(tokens, 1, XTTokenFalse, "false literal");
    }

    return failures;
}
