// TokenType.xc — the token kinds, numbered exactly as XTTokenType is.
// =================================================================
//
// GENERATED from src/xtc/lexer/XTTokenType.h by
// selfhost/tools/gen-token-types.py. Do not edit by hand: the numbers are a
// CONTRACT between the two lexers, whose token dumps are compared byte for
// byte, and a hand-transcribed copy of 115 enumerators is wrong in one place
// for months before anyone notices.
//
// Append-only, like the Objective-C enum it mirrors: inserting in the middle
// renumbers every later token and breaks separately-compiled objects.

enum TokenType = {
    tokIntLiteral     = 0,
    tokFloatLiteral   = 1,
    tokCharLiteral    = 2,
    tokStringLiteral  = 3,
    tokTrue           = 4,
    tokFalse          = 5,
    tokIf             = 6,
    tokElse           = 7,
    tokWhile          = 8,
    tokFor            = 9,
    tokIn             = 10,
    tokReturn         = 11,
    tokBreak          = 12,
    tokContinue       = 13,
    tokStruct         = 14,
    tokTypedef        = 15,
    tokEnum           = 16,
    tokClass          = 17,
    tokNew            = 18,
    tokDelete         = 19,
    tokRetain         = 20,
    tokRelease        = 21,
    tokAuto           = 22,
    tokVolatile       = 23,
    tokAsm            = 24,
    tokSizeof         = 25,
    tokI8             = 26,
    tokU8             = 27,
    tokI16            = 28,
    tokU16            = 29,
    tokI32            = 30,
    tokU32            = 31,
    tokBool           = 32,
    tokFloat          = 33,
    tokVoid           = 34,
    tokPointer        = 35,
    tokString         = 36,
    tokIdentifier     = 37,
    tokPlus           = 38,
    tokMinus          = 39,
    tokStar           = 40,
    tokSlash          = 41,
    tokPercent        = 42,
    tokAmpersand      = 43,
    tokPipe           = 44,
    tokCaret          = 45,
    tokTilde          = 46,
    tokShiftLeft      = 47,
    tokShiftRight     = 48,
    tokRotateLeft     = 49,
    tokRotateRight    = 50,
    tokLoByte         = 51,
    tokHiByte         = 52,
    tokByte2          = 53,
    tokByte3          = 54,
    tokLogicalAnd     = 55,
    tokLogicalOr      = 56,
    tokBang           = 57,
    tokEqual          = 58,
    tokNotEqual       = 59,
    tokLess           = 60,
    tokGreater        = 61,
    tokLessEq         = 62,
    tokGreaterEq      = 63,
    tokAssign         = 64,
    tokPlusAssign     = 65,
    tokMinusAssign    = 66,
    tokStarAssign     = 67,
    tokSlashAssign    = 68,
    tokPercentAssign  = 69,
    tokAmpAssign      = 70,
    tokPipeAssign     = 71,
    tokCaretAssign    = 72,
    tokShlAssign      = 73,
    tokShrAssign      = 74,
    tokRolAssign      = 75,
    tokRorAssign      = 76,
    tokPlusPlus       = 77,
    tokMinusMinus     = 78,
    tokAt             = 79,
    tokArrow          = 80,
    tokDot            = 81,
    tokLParen         = 82,
    tokRParen         = 83,
    tokLBrace         = 84,
    tokRBrace         = 85,
    tokLBracket       = 86,
    tokRBracket       = 87,
    tokSemicolon      = 88,
    tokComma          = 89,
    tokColon          = 90,
    tokQuestion       = 91,
    tokEllipsis       = 92,
    tokEOF            = 93,
    tokStatic         = 94,
    tokExtern         = 95,
    tokRegister       = 96,
    tokGlobal         = 97,
    tokInline         = 98,
    tokDouble         = 99,
    tokSwitch         = 100,
    tokCase           = 101,
    tokDefault        = 102,
    tokDotDot         = 103,
    tokProtocol       = 104,
    tokFinal          = 105,
    tokOptional       = 106,
    tokUse            = 107,
    tokDefer          = 108,
    tokThrows         = 109,
    tokThrow          = 110,
    tokTry            = 111,
    tokCatch          = 112,
    tokI64            = 113,
    tokU64            = 114,
    tokGoto           = 115
};

// The count, for a bounds check on a dumped stream.
#define TOKEN_TYPE_COUNT 116

// The human name of each token kind, as XTTokenTypeName spells it — for
// diagnostics only. A kind the reference does not name comes back as `?`.
class TokenNames
{
    u8 _unused;
    void init(void) { _unused = (u8)0; }
    static string of(u16 t)
    {
        if (t == (u16)tokIntLiteral) return "integer literal";
        if (t == (u16)tokFloatLiteral) return "float literal";
        if (t == (u16)tokCharLiteral) return "character literal";
        if (t == (u16)tokStringLiteral) return "string literal";
        if (t == (u16)tokTrue) return "true";
        if (t == (u16)tokFalse) return "false";
        if (t == (u16)tokIf) return "if";
        if (t == (u16)tokElse) return "else";
        if (t == (u16)tokDefer) return "defer";
        if (t == (u16)tokThrows) return "throws";
        if (t == (u16)tokThrow) return "throw";
        if (t == (u16)tokTry) return "try";
        if (t == (u16)tokCatch) return "catch";
        if (t == (u16)tokWhile) return "while";
        if (t == (u16)tokFor) return "for";
        if (t == (u16)tokIn) return "in";
        if (t == (u16)tokReturn) return "return";
        if (t == (u16)tokBreak) return "break";
        if (t == (u16)tokContinue) return "continue";
        if (t == (u16)tokGoto) return "goto";
        if (t == (u16)tokStruct) return "struct";
        if (t == (u16)tokTypedef) return "typedef";
        if (t == (u16)tokEnum) return "enum";
        if (t == (u16)tokClass) return "class";
        if (t == (u16)tokNew) return "new";
        if (t == (u16)tokDelete) return "delete";
        if (t == (u16)tokRetain) return "retain";
        if (t == (u16)tokRelease) return "release";
        if (t == (u16)tokAuto) return "auto";
        if (t == (u16)tokI64) return "i64";
        if (t == (u16)tokU64) return "u64";
        if (t == (u16)tokVolatile) return "volatile";
        if (t == (u16)tokAsm) return "asm";
        if (t == (u16)tokSizeof) return "sizeof";
        if (t == (u16)tokUse) return "use";
        if (t == (u16)tokI8) return "i8";
        if (t == (u16)tokU8) return "u8";
        if (t == (u16)tokI16) return "i16";
        if (t == (u16)tokU16) return "u16";
        if (t == (u16)tokI32) return "i32";
        if (t == (u16)tokU32) return "u32";
        if (t == (u16)tokBool) return "bool";
        if (t == (u16)tokFloat) return "float";
        if (t == (u16)tokDouble) return "double";
        if (t == (u16)tokVoid) return "void";
        if (t == (u16)tokPointer) return "pointer";
        if (t == (u16)tokString) return "string";
        if (t == (u16)tokIdentifier) return "identifier";
        if (t == (u16)tokPlus) return "+";
        if (t == (u16)tokMinus) return "-";
        if (t == (u16)tokStar) return "*";
        if (t == (u16)tokSlash) return "/";
        if (t == (u16)tokPercent) return "%";
        if (t == (u16)tokAmpersand) return "&";
        if (t == (u16)tokPipe) return "|";
        if (t == (u16)tokCaret) return "^";
        if (t == (u16)tokTilde) return "~";
        if (t == (u16)tokShiftLeft) return "<<";
        if (t == (u16)tokShiftRight) return ">>";
        if (t == (u16)tokRotateLeft) return "<:";
        if (t == (u16)tokRotateRight) return ":>";
        if (t == (u16)tokLoByte) return "<";
        if (t == (u16)tokHiByte) return ">";
        if (t == (u16)tokByte2) return ">>";
        if (t == (u16)tokByte3) return ">>>";
        if (t == (u16)tokLogicalAnd) return "&&";
        if (t == (u16)tokLogicalOr) return "||";
        if (t == (u16)tokBang) return "!";
        if (t == (u16)tokEqual) return "==";
        if (t == (u16)tokNotEqual) return "!=";
        if (t == (u16)tokLess) return "<";
        if (t == (u16)tokGreater) return ">";
        if (t == (u16)tokLessEq) return "<=";
        if (t == (u16)tokGreaterEq) return ">=";
        if (t == (u16)tokAssign) return "=";
        if (t == (u16)tokPlusAssign) return "+=";
        if (t == (u16)tokMinusAssign) return "-=";
        if (t == (u16)tokStarAssign) return "*=";
        if (t == (u16)tokSlashAssign) return "/=";
        if (t == (u16)tokPercentAssign) return "%=";
        if (t == (u16)tokAmpAssign) return "&=";
        if (t == (u16)tokPipeAssign) return "|=";
        if (t == (u16)tokCaretAssign) return "^=";
        if (t == (u16)tokShlAssign) return "<<=";
        if (t == (u16)tokShrAssign) return ">>=";
        if (t == (u16)tokRolAssign) return "<:=";
        if (t == (u16)tokRorAssign) return ":>=";
        if (t == (u16)tokPlusPlus) return "++";
        if (t == (u16)tokMinusMinus) return "--";
        if (t == (u16)tokAt) return "@";
        if (t == (u16)tokArrow) return "->";
        if (t == (u16)tokDot) return ".";
        if (t == (u16)tokLParen) return "(";
        if (t == (u16)tokRParen) return ")";
        if (t == (u16)tokLBrace) return "{";
        if (t == (u16)tokRBrace) return "}";
        if (t == (u16)tokLBracket) return "[";
        if (t == (u16)tokRBracket) return "]";
        if (t == (u16)tokSemicolon) return ";";
        if (t == (u16)tokComma) return ",";
        if (t == (u16)tokColon) return ":";
        if (t == (u16)tokQuestion) return "?";
        if (t == (u16)tokEllipsis) return "...";
        if (t == (u16)tokStatic) return "static";
        if (t == (u16)tokExtern) return "extern";
        if (t == (u16)tokRegister) return "register";
        if (t == (u16)tokGlobal) return "global";
        if (t == (u16)tokInline) return "inline";
        if (t == (u16)tokSwitch) return "switch";
        if (t == (u16)tokCase) return "case";
        if (t == (u16)tokDefault) return "default";
        if (t == (u16)tokDotDot) return "..";
        if (t == (u16)tokProtocol) return "protocol";
        if (t == (u16)tokFinal) return "final";
        if (t == (u16)tokOptional) return "optional";
        if (t == (u16)tokEOF) return "EOF";
        return "?";
    }
}
