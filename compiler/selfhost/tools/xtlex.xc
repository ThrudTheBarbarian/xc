// xtlex.xc — dump a source file's token stream, using the xtc lexer.
// =================================================================
//
// self-hosting M4. The counterpart of `xtc-fe --dump-tokens`, which does the
// same thing with the Objective-C lexer. selfhost/tools/lexer-diff.sh runs both
// over every fixture and diffs the output byte for byte; that diff IS the test
// that the ported lexer is faithful.
//
//   xtlex <file.xc>
//
// One line per token:  <line> <col> <type> <intValue> <escaped text>
//
// The type is the numeric TokenType. The escape rules — backslash, the three
// whitespace characters, and \xHH for anything outside printable ASCII — are a
// contract with XTEscapeTokenText in src/xtc-fe/main.m, not a formatting
// preference: a difference in escaping would show up as a difference in
// lexing, which is the one thing this must not do.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "TokenType.xc"
#import "Token.xc"
#import "Lexer.xc"

// UPPERCASE hex, two digits — as the oracle's "\\x%02X" produces.
u8 hexDigit(u8 nibble)
    {
    if (nibble < (u8)10)
        return (u8)((u8)'0' + nibble);
    return (u8)((u8)'A' + (nibble - (u8)10));
    }

String* escapeTokenText(String* s)
    {
    String* out = String.withCString("");
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        {
        u8 c = s.byteAt(i);
        if (c == (u8)92)
            out.appendCString("\\\\");
        else if (c == (u8)10)
            out.appendCString("\\n");
        else if (c == (u8)9)
            out.appendCString("\\t");
        else if (c == (u8)13)
            out.appendCString("\\r");
        else if (c < (u8)32 || c > (u8)126)
            {
            out.appendCString("\\x");
            out.appendByte(hexDigit(c >> (u8)4));
            out.appendByte(hexDigit(c & (u8)$0F));
            }
        else
            {
            out.appendByte(c);
            }
        }
    return out;
    }

void main(void)
    {
    if (Process.argumentCount() < (u32)2)
        {
        Stdio.printf("usage: xtlex <file.xc>\n");
        Process.exit((i32)2);
        return;
        }

    String* path = Process.argument((u32)1);
    String* src = Files.readText(path);
    if (src == 0)
        {
        Stdio.printf("xtlex: cannot read '%s'\n", path.cString());
        Process.exit((i32)1);
        return;
        }

    Lexer* lex = Lexer.with(src, path);
    Array* tokens = lex.tokenise();

    // One appendFormat per token into a single String, then one write: this is
    // the shape the compiler's asm emitters have, so it is also the first real
    // measurement of whether that shape is fast enough (String grows
    // geometrically now — Task #811).
    String* out = String.withCString("");
    for (u32 i = (u32)0; i < tokens.count(); i = i + (u32)1)
        {
        Token* t = (Token*)tokens.get(i);
        // A float literal's `intValue` carries this port's own `d`-suffix flag
        // (Token.xc), which the original has no equivalent of — it prints 0.
        // The flag must not leak into the comparison.
        i64 payload = (t.type() == (u16)tokFloatLiteral) ? (i64)0 : t.intValue();
        // The payload is printed by String.withI64, not "%ld": appendFormat
        // understands one `l`, so its widest integer is 32 bits, and the oracle
        // prints `%lld`. Widening the token payload without widening the way it
        // is PRINTED just moves the truncation one stage downstream.
        out.appendFormat("%lu %lu %lu %s %s\n",
                         t.line(), t.col(), (u32)t.type(),
                         String.withI64(payload).cString(),
                         escapeTokenText(t.value()).cString());
        }
    Stdio.printf("%s", out.cString());
    }
