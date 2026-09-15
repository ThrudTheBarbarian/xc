// Lexer.xc — the xtc tokeniser, written in xtc.
// =================================================================
//
// self-hosting M4: the first compiler module ported from Objective-C. It is a
// FAITHFUL port of src/xtc/lexer/XTLexer.m, not an improvement on it — the two
// are compared by dumping their token streams for the same input and diffing
// byte for byte (selfhost/tools/lexer-diff.sh), so every quirk of the original
// is reproduced on purpose:
//
//   * a `#` becomes an IDENTIFIER token holding "#", because inline 6502 asm
//     writes `LDA #$40` and the asm-block reconstructor concatenates tokens
//     back into a line;
//   * a lone apostrophe likewise, so English prose inside an asm comment
//     ("two's-complement") does not start a character literal;
//   * `%` is a binary-literal prefix only when the next character is 0 or 1;
//   * an unknown escape in a string literal keeps its backslash;
//   * `#line N "file"` from the preprocessor resets the line and filename.
//
// Where the port cannot be faithful, it says so:
//
//   * integer values are u32 (Token.xc explains);
//   * float literals are not encoded into the 5-byte format at lex time — the
//     token carries its source text and the encoder is a later task;
//   * columns count BYTES. The Objective-C lexer counts UTF-16 units, so a
//     non-ASCII character inside a string literal shifts the column of later
//     tokens on that line by one there and by two here. Nothing in the corpus
//     has one; if that changes, the diff harness reports it rather than the
//     difference lurking.
//
// Character classification is CharacterSet — the class added for exactly this,
// since a tokeniser is mostly character-class tests.

#import "Foundation.xc"
#import "CharacterSet.xc"
#import "TokenType.xc"
#import "Token.xc"
#import "FileTable.xc"

class Lexer
    {
    String* _src; // whole source text
    u8* _b;       // cached _src.cString() — the hot path is byte reads
    u32 _len;
    String* _file; // current filename (a #line directive may change it)
    u32 _fileId;   // …and its interned id, which is what TOKENS carry:
                   //   a String retained per token wraps the u16
                   //   refcount on a large file. See FileTable.
    u32 _pos;
    u32 _line;
    u32 _col;
    Array* _tokens;
    u32 _errors; // count, kept for callers that only ask "did it lex?"
    // …and the MESSAGES. The count alone was all there was, with a comment
    // saying diagnostics were the driver's job — and the driver never asked,
    // so a lexical error was detected and then silently dropped. `"\x80"` was
    // the visible consequence: the reference rejects a \x above 7F with a
    // fix-it, the port counted it and carried on, and the byte vanished from
    // the string with nothing said (bug 212).
    Array* _diags; // of String@ — "file:line:col: error: text"

    // Character classes, built once per lexer.
    CharacterSet* _digits;
    CharacterSet* _hexDigits;
    CharacterSet* _identStart;
    CharacterSet* _identCont;

    void init(void)
        {
        _src = (String*)0;
        _b = (u8*)0;
        _len = (u32)0;
        _file = (String*)0;
        _fileId = (u32)0;
        _pos = (u32)0;
        _line = (u32)1;
        _col = (u32)1;
        _tokens = new Array();
        _errors = (u32)0;
        _diags = new Array();

        _digits = CharacterSet.decimalDigits();
        _hexDigits = CharacterSet.hexDigits();
        _identStart = CharacterSet.letters();
        _identStart.add((u8)'_');
        _identCont = CharacterSet.identifiers();
        }

    static Lexer* with(String* source, String* filename)
        {
        Lexer* l = new Lexer();
        l._src = source;
        l._b = source.cString();
        l._len = source.byteLength();
        l._file = filename;
        l._fileId = FileTable.idFor(filename);
        return l;
        }

    u32 errorCount(void)
        {
        return _errors;
        }
    Array* diagnostics(void)
        {
        return _diags;
        }

    // A positioned lexical error, in the reference's wording. Callers pass the
    // text only; the position comes from where the lexer currently is, which is
    // the escape being read.
    void _err(string msg)
        {
        _errors = _errors + (u32)1;
        String* out = String.withCString("");
        out.append(_file != (String*)0 ? _file : String.withCString("?"));
        out.appendByte((u8)':');
        out.append(String.withU32(_line));
        out.appendByte((u8)':');
        out.append(String.withU32(_col));
        out.appendCString(": error: ");
        out.appendCString(msg);
        _diags.add((Object*)out);
        }
    String* filename(void)
        {
        return _file;
        }

    // ── Character access ─────────────────────────────────────────
    // 0 at end of source, exactly as the Objective-C `currentChar` returns.
    u8 _cur(void)
        {
        if (_pos >= _len)
            return (u8)0;
        return _b[_pos];
        }

    u8 _peek(u32 offset)
        {
        u32 idx = _pos + offset;
        if (idx >= _len)
            return (u8)0;
        return _b[idx];
        }

    void _advance(void)
        {
        if (_pos >= _len)
            return;
        u8 ch = _b[_pos];
        _pos = _pos + (u32)1;
        // Columns count UTF-16 CODE UNITS, not bytes, because that is what the
        // original counts: it lexes an NSString through characterAtIndex:, so a
        // 3-byte UTF-8 em-dash is ONE unit there and was three here. Every
        // source with a non-ASCII character in a string or comment reported
        // columns 2 too far from that point on — seven files in the tree, all
        // from a single `—`.
        //
        // A continuation byte (10xxxxxx) is part of the character before it and
        // advances nothing. A 4-byte lead (11110xxx) is outside the BMP, which
        // UTF-16 spells as a SURROGATE PAIR — two units, so two columns.
        if (ch == (u8)10)
            {
            _line = _line + (u32)1;
            _col = (u32)1;
            }
        else if ((ch & (u8)$C0) == (u8)$80)
            {
            }
        else if (ch >= (u8)$F0)
            {
            _col = _col + (u32)2;
            }
        else
            {
            _col = _col + (u32)1;
            }
        }

    // Every token is stamped with the file it came from, here rather than at
    // the five construction sites — `#line` can move `_file` between any two
    // tokens, and one chokepoint cannot disagree with itself.
    void _add(Token* t)
        {
        t.setFileId(_fileId);
        _tokens.add((Object*)t);
        }

    // ── Tokenise ─────────────────────────────────────────────────
    Array* tokenise(void)
        {
        while (_pos < _len)
            {
            _skipWhitespaceAndComments();
            if (_pos >= _len)
                break;
            if (_cur() == (u8)'#' && _matchLineDirective())
                continue;
            _scanToken();
            }
        _add(Token.with((u16)tokEOF, String.withCString(""), _line, _col));
        return _tokens;
        }

    // `#line N "filename"` from the preprocessor. Consumes the whole line and
    // resets the position tracking; returns false if this `#` starts something
    // else (an asm immediate, say).
    bool _matchLineDirective(void)
        {
        if (_pos + (u32)5 >= _len)
            return false;
        if (_peek((u32)1) != (u8)'l')
            return false;
        if (_peek((u32)2) != (u8)'i')
            return false;
        if (_peek((u32)3) != (u8)'n')
            return false;
        if (_peek((u32)4) != (u8)'e')
            return false;
        if (_peek((u32)5) != (u8)32)
            return false;

        u32 start = _pos;
        while (_pos < _len && _b[_pos] != (u8)10)
            _pos = _pos + (u32)1;
        if (_pos < _len)
            _pos = _pos + (u32)1; // consume the newline

        String* directive = _src.substringBytes(start, _pos - start).trimmed();
        // Past "#line", the number, then optionally a quoted filename.
        String* rest = directive.substringFromByte((u32)5).trimmed();

        u32 idx = (u32)0;
        u32 num = (u32)0;
        bool sawDigit = false;
        while (idx < rest.byteLength() && _digits.contains(rest.byteAt(idx)))
            {
            num = num * (u32)10 + (u32)(rest.byteAt(idx) - (u8)48);
            sawDigit = true;
            idx = idx + (u32)1;
            }
        if (sawDigit)
            _line = num;

        String* afterNum = rest.substringFromByte(idx).trimmed();
        if (afterNum.byteLength() >= (u32)2 && afterNum.byteAt((u32)0) == (u8)34 && afterNum.byteAt(afterNum.byteLength() - (u32)1) == (u8)34)
            {
            _file = afterNum.substringBytes((u32)1, afterNum.byteLength() - (u32)2);
            _fileId = FileTable.idFor(_file);
            }

        _col = (u32)1;
        return true;
        }

    void _skipWhitespaceAndComments(void)
        {
        while (_pos < _len)
            {
            u8 ch = _cur();
            if (ch == (u8)32 || ch == (u8)9 || ch == (u8)13 || ch == (u8)10)
                {
                _advance();
                }
            else if (ch == (u8)'/' && _peek((u32)1) == (u8)'/')
                {
                while (_pos < _len && _cur() != (u8)10)
                    _advance();
                }
            else if (ch == (u8)'/' && _peek((u32)1) == (u8)'*')
                {
                _advance();
                _advance();
                while (_pos < _len)
                    {
                    if (_cur() == (u8)'*' && _peek((u32)1) == (u8)'/')
                        {
                        _advance();
                        _advance();
                        break;
                        }
                    _advance();
                    }
                }
            else
                {
                break;
                }
            }
        }

    void _scanToken(void)
        {
        u32 line = _line;
        u32 col = _col;
        u8 ch = _cur();

        // "
        if (ch == (u8)34)
            {
            _scanStringLiteral(line, col);
            return;
            }

        // A character literal only when the lookahead really has the shape of
        // one. Anything else falls through to punctuation, which is what keeps
        // an English apostrophe inside an asm comment from starting a scan that
        // runs to the end of the line.
        // '
        if (ch == (u8)39)
            {
            u8 p1 = _peek((u32)1);
            u8 p2 = _peek((u32)2);
            u8 p3 = _peek((u32)3);
            bool isEscape = (p1 == (u8)92 && p3 == (u8)39);
            // Hex escapes are longer: '\xNN' closes at 5, '\uNNNN' at 7.
            if (p1 == (u8)92 && p2 == (u8)'x')
                isEscape = (_peek((u32)5) == (u8)39);
            if (p1 == (u8)92 && p2 == (u8)'u')
                isEscape = (_peek((u32)7) == (u8)39);
            bool isSimple = (p1 != (u8)92 && p1 != (u8)0 && p2 == (u8)39);
            if (isEscape || isSimple)
                {
                _scanCharLiteral(line, col);
                return;
                }
            }

        if (ch == (u8)'$')
            {
            _scanHexLiteral(line, col, (u32)1, String.withCString("$"));
            return;
            }
        // `0x` / `0X` as an alias for `$`. Checked before the plain-digit path
        // so `0xFF` cannot lex as a decimal 0 followed by an identifier;
        // nothing else in the grammar starts `0x`.
        if (ch == (u8)'0' && (_peek((u32)1) == (u8)'x' || _peek((u32)1) == (u8)'X') && _hexDigits.contains(_peek((u32)2)))
            {
            _scanHexLiteral(line, col, (u32)2, String.withCString("0x"));
            return;
            }
        if (ch == (u8)'%' && (_peek((u32)1) == (u8)'0' || _peek((u32)1) == (u8)'1'))
            {
            _scanBinLiteral(line, col);
            return;
            }
        if (_digits.contains(ch))
            {
            _scanNumericLiteral(line, col);
            return;
            }
        if (_identStart.contains(ch))
            {
            _scanIdentifierOrKeyword(line, col);
            return;
            }

        _scanOperatorOrPunct(line, col);
        }

    // ── String literal ───────────────────────────────────────────
    // Read exactly `n` hex digits for a \x / \u / \U escape. -1 (and an
    // error) on a short or non-hex run.
    i64 _readHexEsc(u32 n)
        {
        i64 v = (i64)0;
        u32 i = (u32)0;
        while (i < n)
            {
            u8 c = _cur();
            i64 d = (i64)0 - (i64)1;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (i64)(c - (u8)'0');
            if (c >= (u8)'a' && c <= (u8)'f')
                d = (i64)10 + (i64)(c - (u8)'a');
            if (c >= (u8)'A' && c <= (u8)'F')
                d = (i64)10 + (i64)(c - (u8)'A');
            if (d < (i64)0)
                {
                _errors = _errors + (u32)1;
                return (i64)0 - (i64)1;
                }
            v = v * (i64)16 + d;
            _advance();
            i = i + (u32)1;
            }
        return v;
        }

    // Append code point `cp` as UTF-8. Encoded BY HAND: the library String's
    // appendChar means different things on the byte-oriented xt6502 String,
    // and these sources build for every target. \x is capped at 7F and a
    // surrogate / beyond-U+10FFFF value is rejected, as the original does.
    void _appendEscCp(String* buf, i64 cp, bool isX)
        {
        if (cp < (i64)0)
            return;
        if (isX && cp > (i64)$7F)
            {
            _err("\\x above 7F would be a bare byte inside a UTF-8 string — "
                 "write the character with \\u00NN, or build raw bytes with "
                 "appendByte");
            return;
            }
        if ((cp >= (i64)$D800 && cp <= (i64)$DFFF) || cp > (i64)$10FFFF)
            {
            _errors = _errors + (u32)1;
            return;
            }
        u32 v = (u32)cp;
        if (v <= (u32)$7F)
            {
            buf.appendByte((u8)v);
            return;
            }
        if (v <= (u32)$7FF)
            {
            buf.appendByte((u8)((u32)$C0 | (v >> (u32)6)));
            buf.appendByte((u8)((u32)$80 | (v & (u32)$3F)));
            return;
            }
        if (v <= (u32)$FFFF)
            {
            buf.appendByte((u8)((u32)$E0 | (v >> (u32)12)));
            buf.appendByte((u8)((u32)$80 | ((v >> (u32)6) & (u32)$3F)));
            buf.appendByte((u8)((u32)$80 | (v & (u32)$3F)));
            return;
            }
        buf.appendByte((u8)((u32)$F0 | (v >> (u32)18)));
        buf.appendByte((u8)((u32)$80 | ((v >> (u32)12) & (u32)$3F)));
        buf.appendByte((u8)((u32)$80 | ((v >> (u32)6) & (u32)$3F)));
        buf.appendByte((u8)((u32)$80 | (v & (u32)$3F)));
        }

    void _scanStringLiteral(u32 line, u32 col)
        {
        _advance(); // opening quote
        String* buf = String.withCString("");
        while (_pos < _len)
            {
            u8 ch = _cur();
            if (ch == (u8)34)
                {
                _advance();
                break;
                }
            // unterminated
            if (ch == (u8)10)
                {
                _errors = _errors + (u32)1;
                break;
                }
            // backslash
            if (ch == (u8)92)
                {
                _advance();
                u8 esc = _cur();
                _advance();
                if (esc == (u8)'n')
                    buf.appendByte((u8)10);
                else if (esc == (u8)'t')
                    buf.appendByte((u8)9);
                else if (esc == (u8)'r')
                    buf.appendByte((u8)13);
                else if (esc == (u8)'0')
                    buf.appendByte((u8)0);
                else if (esc == (u8)92)
                    buf.appendByte((u8)92);
                else if (esc == (u8)34)
                    buf.appendByte((u8)34);
                else if (esc == (u8)39)
                    buf.appendByte((u8)39);
                // Hex escapes (0.4): \xNN an ASCII byte, \uNNNN / \UNNNNNNNN
                // Unicode code points, appended as UTF-8.
                else if (esc == (u8)'x')
                    _appendEscCp(buf, _readHexEsc((u32)2), true);
                else if (esc == (u8)'u')
                    _appendEscCp(buf, _readHexEsc((u32)4), false);
                else if (esc == (u8)'U')
                    _appendEscCp(buf, _readHexEsc((u32)8), false);
                else
                    {
                    // Unknown escape keeps its backslash, as the original does.
                    buf.appendByte((u8)92);
                    buf.appendByte(esc);
                    }
                }
            else
                {
                buf.appendByte(ch);
                _advance();
                }
            }
        _add(Token.with((u16)tokStringLiteral, buf, line, col));
        }

    // ── Char literal ─────────────────────────────────────────────
    void _scanCharLiteral(u32 line, u32 col)
        {
        _advance(); // opening quote
        u8 value = (u8)0;
        u8 ch = _cur();
        // backslash
        if (ch == (u8)92)
            {
            _advance();
            u8 esc = _cur();
            _advance();
            if (esc == (u8)'n')
                value = (u8)10;
            else if (esc == (u8)'t')
                value = (u8)9;
            else if (esc == (u8)'r')
                value = (u8)13;
            else if (esc == (u8)'0')
                value = (u8)0;
            else if (esc == (u8)92)
                value = (u8)92;
            else if (esc == (u8)39)
                value = (u8)39;
            else if (esc == (u8)'x')
                {
                i64 v = _readHexEsc((u32)2);
                if (v > (i64)$7F)
                    {
                    _errors = _errors + (u32)1;
                    v = (i64)0;
                    }
                if (v >= (i64)0)
                    value = (u8)v;
                }
            else if (esc == (u8)'u')
                {
                i64 v = _readHexEsc((u32)4);
                if (v > (i64)$FF)
                    {
                    _errors = _errors + (u32)1;
                    v = (i64)0;
                    }
                if (v >= (i64)0)
                    value = (u8)v;
                }
            else
                value = esc;
            }
        else
            {
            value = ch;
            _advance();
            }
        if (_cur() != (u8)39)
            _errors = _errors + (u32)1;
        else
            _advance();

        // The token's TEXT is the decimal value, matching the original.
        _add(Token.withInt((u16)tokCharLiteral, String.withU32((u32)value),
                           (i64)value, line, col));
        }

    // ── Numeric literals ─────────────────────────────────────────
    void _scanHexLiteral(u32 line, u32 col, u32 prefixLen, String* displayPrefix)
        {
        for (u32 i = (u32)0; i < prefixLen; i = i + (u32)1)
            _advance(); // $ or 0x
        String* raw = String.withCString("");
        while (_pos < _len)
            {
            u8 ch = _cur();
            if (ch == (u8)'_')
                {
                _advance();
                continue;
                }
            if (_hexDigits.contains(ch))
                {
                raw.appendByte(ch);
                _advance();
                }
            else
                break;
            }
        if (raw.isEmpty())
            {
            _errors = _errors + (u32)1;
            return;
            }

        i64 val = (i64)0;
        for (u32 i = (u32)0; i < raw.byteLength(); i = i + (u32)1)
            val = val * (i64)16 + (i64)Lexer._hexValue(raw.byteAt(i));

        // The token keeps the spelling as WRITTEN, so a token dump of `0xFF`
        // says `0xFF` rather than silently reporting `$FF`.
        String* disp = String.withString(displayPrefix);
        disp.append(raw);
        _add(Token.withInt((u16)tokIntLiteral, disp, val, line, col));
        }

    static u32 _hexValue(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (u32)(c - (u8)'a') + (u32)10;
        return (u32)(c - (u8)'A') + (u32)10;
        }

    void _scanBinLiteral(u32 line, u32 col)
        {
        _advance(); // %
        String* raw = String.withCString("");
        while (_pos < _len)
            {
            u8 ch = _cur();
            if (ch == (u8)'_')
                {
                _advance();
                continue;
                }
            if (ch == (u8)'0' || ch == (u8)'1')
                {
                raw.appendByte(ch);
                _advance();
                }
            else
                break;
            }
        if (raw.isEmpty())
            {
            _errors = _errors + (u32)1;
            return;
            }

        i64 val = (i64)0;
        for (u32 i = (u32)0; i < raw.byteLength(); i = i + (u32)1)
            val = val * (i64)2 + (i64)(raw.byteAt(i) - (u8)'0');

        String* disp = String.withCString("%");
        disp.append(raw);
        _add(Token.withInt((u16)tokIntLiteral, disp, val, line, col));
        }

    void _scanNumericLiteral(u32 line, u32 col)
        {
        String* raw = String.withCString("");
        bool isFloat = false;

        while (_pos < _len)
            {
            u8 ch = _cur();
            if (ch == (u8)'_')
                {
                _advance();
                continue;
                }
            if (_digits.contains(ch))
                {
                raw.appendByte(ch);
                _advance();
                }
            else if (ch == (u8)'.' && !isFloat && _digits.contains(_peek((u32)1)))
                {
                isFloat = true;
                raw.appendByte(ch);
                _advance();
                }
            else if ((ch == (u8)'e' || ch == (u8)'E') && isFloat)
                {
                raw.appendByte(ch);
                _advance();
                if (_cur() == (u8)'+' || _cur() == (u8)'-')
                    {
                    raw.appendByte(_cur());
                    _advance();
                    }
                }
            else
                {
                break;
                }
            }

        // A `d`/`D` suffix means double, and implies float even without a point.
        bool isDouble = false;
        if (_cur() == (u8)'d' || _cur() == (u8)'D')
            {
            isFloat = true;
            isDouble = true;
            _advance();
            }

        if (isFloat)
            {
            // The token carries the SOURCE TEXT; FloatEncoding turns it into
            // the 5- or 8-byte form when something needs the bytes. intValue
            // doubles as the "was there a `d` suffix" flag, since a float
            // literal has no integer payload of its own.
            _add(Token.withInt((u16)tokFloatLiteral, raw,
                               isDouble ? (i64)1 : (i64)0, line, col));
            return;
            }

        i64 val = (i64)0;
        for (u32 i = (u32)0; i < raw.byteLength(); i = i + (u32)1)
            val = val * (i64)10 + (i64)(raw.byteAt(i) - (u8)'0');
        _add(Token.withInt((u16)tokIntLiteral, raw, val, line, col));
        }

    // ── Identifier / keyword ─────────────────────────────────────
    void _scanIdentifierOrKeyword(u32 line, u32 col)
        {
        u32 start = _pos;
        while (_pos < _len && _identCont.contains(_cur()))
            _advance();
        String* word = _src.substringBytes(start, _pos - start);

        u16 kw = Lexer._keywordType(word);
        if (kw != (u16)$FFFF)
            _add(Token.with(kw, word, line, col));
        else
            _add(Token.with((u16)tokIdentifier, word, line, col));
        }

    // The keyword table as a comparison chain rather than a Map: a Map lookup
    // costs a hash of the word plus a probe, and every miss (most identifiers)
    // pays it in full. Dispatching on the first byte first means a typical
    // identifier does one byte compare and stops.
    //
    // $FFFF means "not a keyword" — no token type can collide with it.
    static u16 _keywordType(String* w)
        {
        u32 n = w.byteLength();
        if (n < (u32)2 || n > (u32)8)
            return (u16)$FFFF;
        u8 c = w.byteAt((u32)0);

        if (c == (u8)'i')
            {
            if (Lexer._is(w, "if"))
                return (u16)tokIf;
            if (Lexer._is(w, "in"))
                return (u16)tokIn;
            if (Lexer._is(w, "inline"))
                return (u16)tokInline;
            if (Lexer._is(w, "i8"))
                return (u16)tokI8;
            if (Lexer._is(w, "i16"))
                return (u16)tokI16;
            if (Lexer._is(w, "i32"))
                return (u16)tokI32;
            if (Lexer._is(w, "i64"))
                return (u16)tokI64;
            return (u16)$FFFF;
            }
        if (c == (u8)'e')
            {
            if (Lexer._is(w, "else"))
                return (u16)tokElse;
            if (Lexer._is(w, "enum"))
                return (u16)tokEnum;
            if (Lexer._is(w, "extern"))
                return (u16)tokExtern;
            return (u16)$FFFF;
            }
        if (c == (u8)'w')
            {
            if (Lexer._is(w, "while"))
                return (u16)tokWhile;
            return (u16)$FFFF;
            }
        if (c == (u8)'f')
            {
            if (Lexer._is(w, "for"))
                return (u16)tokFor;
            if (Lexer._is(w, "false"))
                return (u16)tokFalse;
            if (Lexer._is(w, "float"))
                return (u16)tokFloat;
            if (Lexer._is(w, "final"))
                return (u16)tokFinal;
            return (u16)$FFFF;
            }
        if (c == (u8)'r')
            {
            if (Lexer._is(w, "return"))
                return (u16)tokReturn;
            if (Lexer._is(w, "retain"))
                return (u16)tokRetain;
            if (Lexer._is(w, "release"))
                return (u16)tokRelease;
            if (Lexer._is(w, "register"))
                return (u16)tokRegister;
            return (u16)$FFFF;
            }
        if (c == (u8)'b')
            {
            if (Lexer._is(w, "break"))
                return (u16)tokBreak;
            if (Lexer._is(w, "bool"))
                return (u16)tokBool;
            return (u16)$FFFF;
            }
        if (c == (u8)'c')
            {
            if (Lexer._is(w, "continue"))
                return (u16)tokContinue;
            if (Lexer._is(w, "class"))
                return (u16)tokClass;
            if (Lexer._is(w, "case"))
                return (u16)tokCase;
            if (Lexer._is(w, "catch"))
                return (u16)tokCatch;
            return (u16)$FFFF;
            }
        if (c == (u8)'d')
            {
            if (Lexer._is(w, "delete"))
                return (u16)tokDelete;
            if (Lexer._is(w, "double"))
                return (u16)tokDouble;
            if (Lexer._is(w, "default"))
                return (u16)tokDefault;
            if (Lexer._is(w, "defer"))
                return (u16)tokDefer;
            return (u16)$FFFF;
            }
        if (c == (u8)'s')
            {
            if (Lexer._is(w, "struct"))
                return (u16)tokStruct;
            if (Lexer._is(w, "static"))
                return (u16)tokStatic;
            if (Lexer._is(w, "sizeof"))
                return (u16)tokSizeof;
            if (Lexer._is(w, "string"))
                return (u16)tokString;
            if (Lexer._is(w, "switch"))
                return (u16)tokSwitch;
            return (u16)$FFFF;
            }
        if (c == (u8)'t')
            {
            if (Lexer._is(w, "typedef"))
                return (u16)tokTypedef;
            if (Lexer._is(w, "true"))
                return (u16)tokTrue;
            if (Lexer._is(w, "throws"))
                return (u16)tokThrows;
            if (Lexer._is(w, "throw"))
                return (u16)tokThrow;
            if (Lexer._is(w, "try"))
                return (u16)tokTry;
            return (u16)$FFFF;
            }
        if (c == (u8)'p')
            {
            if (Lexer._is(w, "protocol"))
                return (u16)tokProtocol;
            if (Lexer._is(w, "pointer"))
                return (u16)tokPointer;
            return (u16)$FFFF;
            }
        if (c == (u8)'o')
            {
            if (Lexer._is(w, "optional"))
                return (u16)tokOptional;
            return (u16)$FFFF;
            }
        if (c == (u8)'n')
            {
            if (Lexer._is(w, "new"))
                return (u16)tokNew;
            return (u16)$FFFF;
            }
        if (c == (u8)'a')
            {
            if (Lexer._is(w, "auto"))
                return (u16)tokAuto;
            if (Lexer._is(w, "asm"))
                return (u16)tokAsm;
            return (u16)$FFFF;
            }
        if (c == (u8)'v')
            {
            if (Lexer._is(w, "volatile"))
                return (u16)tokVolatile;
            if (Lexer._is(w, "void"))
                return (u16)tokVoid;
            return (u16)$FFFF;
            }
        if (c == (u8)'g')
            {
            if (Lexer._is(w, "global"))
                return (u16)tokGlobal;
            if (Lexer._is(w, "goto"))
                return (u16)tokGoto;
            return (u16)$FFFF;
            }
        if (c == (u8)'u')
            {
            if (Lexer._is(w, "use"))
                return (u16)tokUse;
            if (Lexer._is(w, "u8"))
                return (u16)tokU8;
            if (Lexer._is(w, "u16"))
                return (u16)tokU16;
            if (Lexer._is(w, "u32"))
                return (u16)tokU32;
            if (Lexer._is(w, "u64"))
                return (u16)tokU64;
            return (u16)$FFFF;
            }
        return (u16)$FFFF;
        }

    // Compare a String against a literal WITHOUT allocating one to compare
    // against — a keyword probe runs on every identifier in the file.
    static bool _is(String* w, string lit)
        {
        u8* a = w.cString();
        u8* b = (u8*)lit;
        u32 i = (u32)0;
        while (b[i] != (u8)0)
            {
            if (i >= w.byteLength())
                return false;
            if (a[i] != b[i])
                return false;
            i = i + (u32)1;
            }
        return i == w.byteLength();
        }

    // ── Operators and punctuation ────────────────────────────────
    void _emit(u16 type, string text, u32 n, u32 line, u32 col)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            _advance();
        _add(Token.with(type, String.withCString(text), line, col));
        }

    void _scanOperatorOrPunct(u32 line, u32 col)
        {
        u8 c1 = _cur();
        u8 c2 = _peek((u32)1);
        u8 c3 = _peek((u32)2);

        if (c1 == (u8)'(')
            {
            _emit((u16)tokLParen, "(", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)')')
            {
            _emit((u16)tokRParen, ")", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'{')
            {
            _emit((u16)tokLBrace, "{", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'}')
            {
            _emit((u16)tokRBrace, "}", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'[')
            {
            _emit((u16)tokLBracket, "[", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)']')
            {
            _emit((u16)tokRBracket, "]", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)';')
            {
            _emit((u16)tokSemicolon, ";", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)',')
            {
            _emit((u16)tokComma, ",", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'?')
            {
            _emit((u16)tokQuestion, "?", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'~')
            {
            _emit((u16)tokTilde, "~", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'@')
            {
            _emit((u16)tokAt, "@", (u32)1, line, col);
            return;
            }

        if (c1 == (u8)':')
            {
            if (c2 == (u8)'>')
                {
                if (c3 == (u8)'=')
                    {
                    _emit((u16)tokRorAssign, ":>=", (u32)3, line, col);
                    return;
                    }
                _emit((u16)tokRotateRight, ":>", (u32)2, line, col);
                return;
                }
            _emit((u16)tokColon, ":", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'+')
            {
            if (c2 == (u8)'+')
                {
                _emit((u16)tokPlusPlus, "++", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokPlusAssign, "+=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokPlus, "+", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'-')
            {
            if (c2 == (u8)'-')
                {
                _emit((u16)tokMinusMinus, "--", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'>')
                {
                _emit((u16)tokArrow, "->", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokMinusAssign, "-=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokMinus, "-", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'*')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokStarAssign, "*=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokStar, "*", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'/')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokSlashAssign, "/=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokSlash, "/", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'%')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokPercentAssign, "%=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokPercent, "%", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'&')
            {
            if (c2 == (u8)'&')
                {
                _emit((u16)tokLogicalAnd, "&&", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokAmpAssign, "&=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokAmpersand, "&", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'|')
            {
            if (c2 == (u8)'|')
                {
                _emit((u16)tokLogicalOr, "||", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokPipeAssign, "|=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokPipe, "|", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'^')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokCaretAssign, "^=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokCaret, "^", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'!')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokNotEqual, "!=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokBang, "!", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'=')
            {
            if (c2 == (u8)'=')
                {
                _emit((u16)tokEqual, "==", (u32)2, line, col);
                return;
                }
            _emit((u16)tokAssign, "=", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'<')
            {
            if (c2 == (u8)'<')
                {
                if (c3 == (u8)'=')
                    {
                    _emit((u16)tokShlAssign, "<<=", (u32)3, line, col);
                    return;
                    }
                _emit((u16)tokShiftLeft, "<<", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)':')
                {
                if (c3 == (u8)'=')
                    {
                    _emit((u16)tokRolAssign, "<:=", (u32)3, line, col);
                    return;
                    }
                _emit((u16)tokRotateLeft, "<:", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokLessEq, "<=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokLess, "<", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'>')
            {
            if (c2 == (u8)'>' && c3 == (u8)'>')
                {
                _emit((u16)tokByte3, ">>>", (u32)3, line, col);
                return;
                }
            if (c2 == (u8)'>')
                {
                if (c3 == (u8)'=')
                    {
                    _emit((u16)tokShrAssign, ">>=", (u32)3, line, col);
                    return;
                    }
                _emit((u16)tokShiftRight, ">>", (u32)2, line, col);
                return;
                }
            if (c2 == (u8)'=')
                {
                _emit((u16)tokGreaterEq, ">=", (u32)2, line, col);
                return;
                }
            _emit((u16)tokGreater, ">", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)'.')
            {
            if (c2 == (u8)'.' && c3 == (u8)'.')
                {
                _emit((u16)tokEllipsis, "...", (u32)3, line, col);
                return;
                }
            if (c2 == (u8)'.')
                {
                _emit((u16)tokDotDot, "..", (u32)2, line, col);
                return;
                }
            _emit((u16)tokDot, ".", (u32)1, line, col);
            return;
            }

        // A 6502 immediate prefix, and a stray apostrophe, both survive as
        // identifier tokens so an asm block can be put back together verbatim.
        if (c1 == (u8)'#')
            {
            _emit((u16)tokIdentifier, "#", (u32)1, line, col);
            return;
            }
        if (c1 == (u8)39)
            {
            _emit((u16)tokIdentifier, "'", (u32)1, line, col);
            return;
            }

        // Anything else is an error; consume it so the scan makes progress.
        _errors = _errors + (u32)1;
        _advance();
        }
    }
