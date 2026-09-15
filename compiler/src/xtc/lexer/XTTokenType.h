#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XTTokenType) {
    // ── Literals ──────────────────────────────────────────────────────────────
    XTTokenIntLiteral,
    XTTokenFloatLiteral,
    XTTokenCharLiteral,
    XTTokenStringLiteral,
    XTTokenTrue,
    XTTokenFalse,

    // ── Keywords ──────────────────────────────────────────────────────────────
    XTTokenIf,
    XTTokenElse,
    XTTokenWhile,
    XTTokenFor,
    XTTokenIn,
    XTTokenReturn,
    XTTokenBreak,
    XTTokenContinue,
    XTTokenStruct,
    XTTokenTypedef,
    XTTokenEnum,
    XTTokenClass,
    XTTokenNew,
    XTTokenDelete,
    XTTokenRetain,
    XTTokenRelease,
    XTTokenAuto,
    XTTokenVolatile,
    XTTokenAsm,
    XTTokenSizeof,

    // ── Types ─────────────────────────────────────────────────────────────────
    XTTokenI8,
    XTTokenU8,
    XTTokenI16,
    XTTokenU16,
    XTTokenI32,
    XTTokenU32,
    XTTokenBool,
    XTTokenFloat,
    XTTokenVoid,
    XTTokenPointer,
    XTTokenString, // 'string' keyword (alias for u8@)

    // ── Identifier ────────────────────────────────────────────────────────────
    XTTokenIdentifier,

    // ── Arithmetic Operators ──────────────────────────────────────────────────
    XTTokenPlus,    // +
    XTTokenMinus,   // -
    XTTokenStar,    // *
    XTTokenSlash,   // /
    XTTokenPercent, // %

    // ── Bitwise Operators ─────────────────────────────────────────────────────
    XTTokenAmpersand, // &  (also address-of)
    XTTokenPipe,      // |
    XTTokenCaret,     // ^
    XTTokenTilde,     // ~

    // ── Shift / Rotate ────────────────────────────────────────────────────────
    XTTokenShiftLeft,   // <<
    XTTokenShiftRight,  // >>
    XTTokenRotateLeft,  // <:
    XTTokenRotateRight, // :>

    // ── Byte-Extraction (assembly / pointer context) ──────────────────────────
    XTTokenLoByte, // < (prefix on symbol/constant in asm)
    XTTokenHiByte, // > (prefix on symbol/constant in asm)
    XTTokenByte2,  // >> (bits 16..23)
    XTTokenByte3,  // >>> (bits 24..31)

    // ── Logical Operators ─────────────────────────────────────────────────────
    XTTokenLogicalAnd, // &&
    XTTokenLogicalOr,  // ||
    XTTokenBang,       // !

    // ── Comparison Operators ──────────────────────────────────────────────────
    XTTokenEqual,     // ==
    XTTokenNotEqual,  // !=
    XTTokenLess,      // <
    XTTokenGreater,   // >
    XTTokenLessEq,    // <=
    XTTokenGreaterEq, // >=

    // ── Assignment Operators ──────────────────────────────────────────────────
    XTTokenAssign,        // =
    XTTokenPlusAssign,    // +=
    XTTokenMinusAssign,   // -=
    XTTokenStarAssign,    // *=
    XTTokenSlashAssign,   // /=
    XTTokenPercentAssign, // %=
    XTTokenAmpAssign,     // &=
    XTTokenPipeAssign,    // |=
    XTTokenCaretAssign,   // ^=
    XTTokenShlAssign,     // <<=
    XTTokenShrAssign,     // >>=
    XTTokenRolAssign,     // <:=
    XTTokenRorAssign,     // :>=

    // ── Increment / Decrement ─────────────────────────────────────────────────
    XTTokenPlusPlus,   // ++
    XTTokenMinusMinus, // --

    // ── Pointer / Member Operators ────────────────────────────────────────────
    XTTokenAt,    // @  (pointer type modifier / dereference)
    XTTokenArrow, // ->
    XTTokenDot,   // .

    // ── Punctuation ───────────────────────────────────────────────────────────
    XTTokenLParen,    // (
    XTTokenRParen,    // )
    XTTokenLBrace,    // {
    XTTokenRBrace,    // }
    XTTokenLBracket,  // [
    XTTokenRBracket,  // ]
    XTTokenSemicolon, // ;
    XTTokenComma,     // ,
    XTTokenColon,     // :
    XTTokenQuestion,  // ?
    XTTokenEllipsis,  // ...

    // ── End of File ───────────────────────────────────────────────────────────
    XTTokenEOF,

    // ── Added after initial enum layout (to avoid shifting existing values) ──
    XTTokenStatic,
    XTTokenExtern, // extern — a global DEFINED in another module
    XTTokenRegister,
    XTTokenGlobal,
    XTTokenInline,
    XTTokenDouble,
    XTTokenSwitch,
    XTTokenCase,
    XTTokenDefault,
    XTTokenDotDot,   // ..  (range separator in case labels)
    XTTokenProtocol, // PR9 — `protocol Name { … }` interface decl
    XTTokenFinal,    // `final` — this method may not be overridden. Opts a
                     // method back OUT of the vtable under --emit-lib, where
                     // every exported method is otherwise given a slot
                     // because the program isn't whole. Needs no codegen: a
                     // method with no slot already lowers to a direct call.
    XTTokenOptional, // `optional` — marks a protocol method as one a
                     // conforming class may omit. Its vtable slot then
                     // stays 0, which is what makes `&d.m` come back
                     // null. See private:docs/Design/bound-methods.md.
    XTTokenUse,      // 'use' keyword — promotes a class's static
                     // methods so they can be called as bare
                     // identifiers within the file scope.
    XTTokenDefer,    // 'defer' keyword — run a block at scope exit.
                     // Appended rather than grouped with the other
                     // statement keywords on purpose: inserting into the
                     // middle renumbers every later token.
    XTTokenThrows,   // 'throws' — effect marker on a function signature
    XTTokenThrow,    // 'throw'  — raise an Error@
    XTTokenTry,      // 'try'    — guard a block
    XTTokenCatch,    // 'catch'  — handle an error
    XTTokenI64,      // i64 — 64-bit signed
    XTTokenU64,      // u64 — 64-bit unsigned
    XTTokenGoto,     // 'goto' — a C-porting aid (undocumented language feature)
};

// Human-readable names for diagnostics / debugging
static inline NSString* XTTokenTypeName(XTTokenType type)
    {
    switch (type)
        {
    case XTTokenIntLiteral:
        return @"integer literal";
    case XTTokenFloatLiteral:
        return @"float literal";
    case XTTokenCharLiteral:
        return @"character literal";
    case XTTokenStringLiteral:
        return @"string literal";
    case XTTokenTrue:
        return @"true";
    case XTTokenFalse:
        return @"false";
    case XTTokenIf:
        return @"if";
    case XTTokenElse:
        return @"else";
    case XTTokenDefer:
        return @"defer";
    case XTTokenThrows:
        return @"throws";
    case XTTokenThrow:
        return @"throw";
    case XTTokenTry:
        return @"try";
    case XTTokenCatch:
        return @"catch";
    case XTTokenWhile:
        return @"while";
    case XTTokenFor:
        return @"for";
    case XTTokenIn:
        return @"in";
    case XTTokenReturn:
        return @"return";
    case XTTokenBreak:
        return @"break";
    case XTTokenContinue:
        return @"continue";
    case XTTokenGoto:
        return @"goto";
    case XTTokenStruct:
        return @"struct";
    case XTTokenTypedef:
        return @"typedef";
    case XTTokenEnum:
        return @"enum";
    case XTTokenClass:
        return @"class";
    case XTTokenNew:
        return @"new";
    case XTTokenDelete:
        return @"delete";
    case XTTokenRetain:
        return @"retain";
    case XTTokenRelease:
        return @"release";
    case XTTokenAuto:
        return @"auto";
    case XTTokenI64:
        return @"i64";
    case XTTokenU64:
        return @"u64";
    case XTTokenVolatile:
        return @"volatile";
    case XTTokenAsm:
        return @"asm";
    case XTTokenSizeof:
        return @"sizeof";
    case XTTokenUse:
        return @"use";
    case XTTokenI8:
        return @"i8";
    case XTTokenU8:
        return @"u8";
    case XTTokenI16:
        return @"i16";
    case XTTokenU16:
        return @"u16";
    case XTTokenI32:
        return @"i32";
    case XTTokenU32:
        return @"u32";
    case XTTokenBool:
        return @"bool";
    case XTTokenFloat:
        return @"float";
    case XTTokenDouble:
        return @"double";
    case XTTokenVoid:
        return @"void";
    case XTTokenPointer:
        return @"pointer";
    case XTTokenString:
        return @"string";
    case XTTokenIdentifier:
        return @"identifier";
    case XTTokenPlus:
        return @"+";
    case XTTokenMinus:
        return @"-";
    case XTTokenStar:
        return @"*";
    case XTTokenSlash:
        return @"/";
    case XTTokenPercent:
        return @"%";
    case XTTokenAmpersand:
        return @"&";
    case XTTokenPipe:
        return @"|";
    case XTTokenCaret:
        return @"^";
    case XTTokenTilde:
        return @"~";
    case XTTokenShiftLeft:
        return @"<<";
    case XTTokenShiftRight:
        return @">>";
    case XTTokenRotateLeft:
        return @"<:";
    case XTTokenRotateRight:
        return @":>";
    case XTTokenLoByte:
        return @"<";
    case XTTokenHiByte:
        return @">";
    case XTTokenByte2:
        return @">>";
    case XTTokenByte3:
        return @">>>";
    case XTTokenLogicalAnd:
        return @"&&";
    case XTTokenLogicalOr:
        return @"||";
    case XTTokenBang:
        return @"!";
    case XTTokenEqual:
        return @"==";
    case XTTokenNotEqual:
        return @"!=";
    case XTTokenLess:
        return @"<";
    case XTTokenGreater:
        return @">";
    case XTTokenLessEq:
        return @"<=";
    case XTTokenGreaterEq:
        return @">=";
    case XTTokenAssign:
        return @"=";
    case XTTokenPlusAssign:
        return @"+=";
    case XTTokenMinusAssign:
        return @"-=";
    case XTTokenStarAssign:
        return @"*=";
    case XTTokenSlashAssign:
        return @"/=";
    case XTTokenPercentAssign:
        return @"%=";
    case XTTokenAmpAssign:
        return @"&=";
    case XTTokenPipeAssign:
        return @"|=";
    case XTTokenCaretAssign:
        return @"^=";
    case XTTokenShlAssign:
        return @"<<=";
    case XTTokenShrAssign:
        return @">>=";
    case XTTokenRolAssign:
        return @"<:=";
    case XTTokenRorAssign:
        return @":>=";
    case XTTokenPlusPlus:
        return @"++";
    case XTTokenMinusMinus:
        return @"--";
    case XTTokenAt:
        return @"@";
    case XTTokenArrow:
        return @"->";
    case XTTokenDot:
        return @".";
    case XTTokenLParen:
        return @"(";
    case XTTokenRParen:
        return @")";
    case XTTokenLBrace:
        return @"{";
    case XTTokenRBrace:
        return @"}";
    case XTTokenLBracket:
        return @"[";
    case XTTokenRBracket:
        return @"]";
    case XTTokenSemicolon:
        return @";";
    case XTTokenComma:
        return @",";
    case XTTokenColon:
        return @":";
    case XTTokenQuestion:
        return @"?";
    case XTTokenEllipsis:
        return @"...";
    case XTTokenStatic:
        return @"static";
    case XTTokenExtern:
        return @"extern";
    case XTTokenRegister:
        return @"register";
    case XTTokenGlobal:
        return @"global";
    case XTTokenInline:
        return @"inline";
    case XTTokenSwitch:
        return @"switch";
    case XTTokenCase:
        return @"case";
    case XTTokenDefault:
        return @"default";
    case XTTokenDotDot:
        return @"..";
    case XTTokenProtocol:
        return @"protocol";
    case XTTokenFinal:
        return @"final";
    case XTTokenOptional:
        return @"optional";
    case XTTokenEOF:
        return @"EOF";
        }
    return @"<unknown>";
    }
