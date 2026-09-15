// Token.xc — one lexical token.
// =================================================================
//
// self-hosting M4. The xtc-language counterpart of src/xtc/lexer/XTToken.m,
// carrying the same four things: what kind of token it is, the source text it
// came from, a parsed integer payload for the literals that have one, and where
// it was.
//
// Differences from the Objective-C original, both deliberate:
//
//   * `intValue` is an i64, matching the original's int64_t. It was a u32
//     until the language grew i64 — the comment that used to sit here said
//     "the language needs i64 before the lexer can be fixed", and that is
//     exactly what happened.
//
//   * float literals carry their SOURCE TEXT only. The Objective-C lexer
//     encodes them into the 5-byte format at lex time (XTFloatEncoding); doing
//     that here means porting the encoder, which is its own task. The token
//     stream comparison does not depend on it — the oracle dumps the raw text
//     for float literals too.

#import "Foundation.xc"
#import "TokenType.xc"

class Token
    {
    u16 _type;      // a TokenType value
    String* _value; // source text (already unescaped, for string literals)
    i64 _intValue;  // int and char literals; 0 for everything else
    u32 _line;      // 1-based
    u32 _col;       // 1-based, in UTF-16 code units (see Lexer._advance)
    // The file this token came from, as an index into an INTERNED table — not
    // a String reference. The lexer knows the name (`#line N "file"` from the
    // preprocessor moves it) and it never reached the token, so nothing
    // downstream could say where anything was.
    //
    // An INDEX because the runtime's refcount is a u16 that WRAPS: one String
    // retained once per token passes 65,536 on any large file, comes back to
    // zero, and the next release frees a live object. selfhost/opt/Opt.xc is
    // 117k tokens and aborted the lexer the moment tokens held the pointer.
    // An id costs 4 bytes, retains nothing, and cannot wrap the count.
    u32 _fileId;

    void init(void)
        {
        _type = (u16)0;
        _value = (String*)0;
        _intValue = (i64)0;
        _line = (u32)0;
        _col = (u32)0;
        _fileId = (u32)0;
        }

    static Token* with(u16 type, String* value, u32 line, u32 col)
        {
        Token* t = new Token();
        t._type = type;
        t._value = value;
        t._line = line;
        t._col = col;
        return t;
        }

    static Token* withInt(u16 type, String* value, i64 intValue, u32 line, u32 col)
        {
        Token* t = Token.with(type, value, line, col);
        t._intValue = intValue;
        return t;
        }

    u16 type(void)
        {
        return _type;
        }
    String* value(void)
        {
        return _value;
        }
    i64 intValue(void)
        {
        return _intValue;
        }
    u32 line(void)
        {
        return _line;
        }
    u32 col(void)
        {
        return _col;
        }
    u32 fileId(void)
        {
        return _fileId;
        }
    void setFileId(u32 f)
        {
        _fileId = f;
        }
    // The NAME, resolved through the intern table. Only diagnostics need it.
    String* file(void)
        {
        return FileTable.name(_fileId);
        }

    bool isType(u16 t)
        {
        return _type == t;
        }
    bool isEOF(void)
        {
        return _type == (u16)tokEOF;
        }

    String* description(void)
        {
        String* s = String.withCString("");
        s.appendFormat("%lu:%lu #%lu ", _line, _col, (u32)_type);
        if (_value != 0)
            s.append(_value);
        return s;
        }
    }
