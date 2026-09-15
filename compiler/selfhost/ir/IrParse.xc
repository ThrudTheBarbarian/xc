// IrParse.xc — read the IR text back.
// =========================================================================
//
// self-hosting M8. `Ir.xc` prints the IR; this reads it. Together they are the
// process boundary: the front end prints, `xtcg-<arch>` parses, and until this
// existed a self-hosted back end had nothing to read with.
//
// The ORACLE is free. The text a module prints is the text this must accept,
// so `print(parse(text))` has to reproduce `text` BYTE FOR BYTE — no new dump
// mode, no fixtures to write, and every `.xc` in the tree is a test case.
//
// Two things make it much smaller than the original's 1,800 lines:
//
//   * A TYPE is its SPELLING here (the same shortcut the rest of the port
//     takes), so a type is read by scanning to the end of its balanced
//     parentheses and kept as text. There is no type table to rebuild and no
//     structural equality to get right.
//   * An OPERAND holds the VALUE, not an id. Values are collected in a first
//     pass over the function's lines — the definitions are all visible as
//     `%N:TYPE` — so by the time operands are read every `%N` resolves,
//     including a phi's reference to a value defined in a textually later
//     block.
//
// Line handling matches the original: a line ending in `,` continues onto the
// next (the only continuation rule), and `;` runs to end of line. The printer
// emits neither, but hand-written IR uses both and a back end has to take it.

#import "Foundation.xc"
#import "Files.xc"
#import "Ir.xc"

class IrParser
    {
    Array* _lines; // String@, comments stripped and continuations joined
    u32 _li;       // the line being read
    String* _cur;  // …its text
    u32 _ci;       // …and the cursor into it
    bool _failed;
    String* _why;
    IRModule* _m;
    Map* _vals;   // per function: print-id (as text) -> IRValue@
    Map* _blocks; // per function: block name -> IRBlock@
    IRFunc* _fn;

    void init(void)
        {
        _li = (u32)0;
        _ci = (u32)0;
        _failed = false;
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void giveUp(String* w)
        {
        if (_failed)
            return;
        _failed = true;
        _why = w;
        }

    void giveUpAt(string what)
        {
        String* w = String.withCString(what);
        w.appendFormat(" (line %ld: ", (i32)(_li + (u32)1));
        w.append(_cur == 0 ? String.withCString("") : _cur);
        w.appendCString(")");
        giveUp(w);
        }

    // ── Entry ────────────────────────────────────────────────────────────
    static IRModule* parseText(String* text, IrParser* into)
        {
        return into.run(text);
        }

    IRModule* run(String* text)
        {
        prepare(text);
        if (_failed)
            return (IRModule*)0;
        _m = new IRModule();
        if (!expectWord("module"))
            {
            giveUpAt("expected `module`");
            return (IRModule*)0;
            }
        String* name = quoted();
        if (name == 0)
            {
            giveUpAt("expected a module name");
            return (IRModule*)0;
            }
        _m.setName(name);
        if (!expectChar((u8)'{'))
            {
            giveUpAt("expected `{`");
            return (IRModule*)0;
            }
        nextLine();
        while (!_failed && _li < _lines.count())
            {
            if (atChar((u8)'}'))
                {
                nextLine();
                break;
                }
            item();
            if (_failed)
                return (IRModule*)0;
            }
        return _m;
        }

    // ── Lines ────────────────────────────────────────────────────────────
    // Comments out, continuations joined, blanks dropped. The line NUMBERS in
    // a diagnostic are this array's, not the file's — a joined line has no one
    // number and saying the first would be a guess.
    void prepare(String* text)
        {
        _lines = new Array();
        Array* raw = text.splitOnByte((u8)10);
        String* pending = (String*)0;
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            {
            String* line = stripComment((String*)raw.get(i)).trimmed();
            if (pending != 0)
                {
                pending.appendCString(" ");
                pending.append(line);
                line = pending;
                pending = (String*)0;
                }
            if (line.byteLength() == (u32)0)
                continue;
            if (line.byteAt(line.byteLength() - (u32)1) == (u8)',')
                {
                pending = String.withString(line);
                continue;
                }
            _lines.add((Object*)line);
            }
        if (pending != 0)
            _lines.add((Object*)pending);
        _li = (u32)0;
        _cur = _lines.count() > (u32)0 ? (String*)_lines.get((u32)0) : String.withCString("");
        _ci = (u32)0;
        }

    // `;` starts a comment — but not inside a string literal, and the byte
    // lists are full of them.
    String* stripComment(String* s)
        {
        bool inStr = false;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)34)
                inStr = !inStr;
            else if (c == (u8)';' && !inStr)
                return s.substringBytes((u32)0, i);
            }
        return s;
        }

    void nextLine(void)
        {
        _li = _li + (u32)1;
        _ci = (u32)0;
        _cur = _li < _lines.count() ? (String*)_lines.get(_li) : String.withCString("");
        }

    // ── Cursor ───────────────────────────────────────────────────────────
    void skipSpace(void)
        {
        while (_ci < _cur.byteLength() && (_cur.byteAt(_ci) == (u8)' ' || _cur.byteAt(_ci) == (u8)9))
            _ci = _ci + (u32)1;
        }

    bool atEnd(void)
        {
        skipSpace();
        return _ci >= _cur.byteLength();
        }

    bool atChar(u8 c)
        {
        skipSpace();
        return _ci < _cur.byteLength() && _cur.byteAt(_ci) == c;
        }

    bool expectChar(u8 c)
        {
        if (!atChar(c))
            return false;
        _ci = _ci + (u32)1;
        return true;
        }

    static bool isIdentChar(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
        }

    // A bare identifier. Symbol names carry `$` and `.`, so both are letters
    // as far as this is concerned.
    String* word(void)
        {
        skipSpace();
        u32 start = _ci;
        while (_ci < _cur.byteLength() && IrParser.isIdentChar(_cur.byteAt(_ci)))
            _ci = _ci + (u32)1;
        if (_ci == start)
            return (String*)0;
        return _cur.substringBytes(start, _ci - start);
        }

    bool expectWord(string w)
        {
        u32 save = _ci;
        String* got = word();
        if (got != 0 && got.equals(String.withCString(w)))
            return true;
        _ci = save;
        return false;
        }

    String* quoted(void)
        {
        skipSpace();
        if (_ci >= _cur.byteLength() || _cur.byteAt(_ci) != (u8)34)
            return (String*)0;
        _ci = _ci + (u32)1;
        u32 start = _ci;
        while (_ci < _cur.byteLength() && _cur.byteAt(_ci) != (u8)34)
            _ci = _ci + (u32)1;
        String* out = _cur.substringBytes(start, _ci - start);
        if (_ci < _cur.byteLength())
            _ci = _ci + (u32)1;
        return out;
        }

    // A decimal integer, optionally negative, optionally `$hex`.
    i32 number(void)
        {
        skipSpace();
        bool neg = false;
        if (_ci < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'-')
            {
            neg = true;
            _ci = _ci + (u32)1;
            }
        if (_ci < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'$')
            {
            _ci = _ci + (u32)1;
            u32 h = (u32)0;
            while (_ci < _cur.byteLength() && IrParser.hexDigit(_cur.byteAt(_ci)) >= (i32)0)
                {
                h = h * (u32)16 + (u32)IrParser.hexDigit(_cur.byteAt(_ci));
                _ci = _ci + (u32)1;
                }
            return neg ? -(i32)h : (i32)h;
            }
        u32 v = (u32)0;
        while (_ci < _cur.byteLength() && _cur.byteAt(_ci) >= (u8)'0' && _cur.byteAt(_ci) <= (u8)'9')
            {
            v = v * (u32)10 + (u32)(_cur.byteAt(_ci) - (u8)'0');
            _ci = _ci + (u32)1;
            }
        return neg ? -(i32)v : (i32)v;
        }

    static i32 hexDigit(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (i32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (i32)(c - (u8)'a') + (i32)10;
        if (c >= (u8)'A' && c <= (u8)'F')
            return (i32)(c - (u8)'A') + (i32)10;
        return (i32)-1;
        }

    // A TYPE is its spelling: an identifier, then any balanced `(...)` that
    // follows it. `Ptr(Agg(3), unbanked)` comes back as itself, which is what
    // the model stores and the printer emits.
    String* typeSpelling(void)
        {
        skipSpace();
        u32 start = _ci;
        while (_ci < _cur.byteLength() && IrParser.isIdentChar(_cur.byteAt(_ci)))
            _ci = _ci + (u32)1;
        if (_ci < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'(')
            {
            u32 depth = (u32)0;
            while (_ci < _cur.byteLength())
                {
                u8 c = _cur.byteAt(_ci);
                if (c == (u8)'(')
                    depth = depth + (u32)1;
                else if (c == (u8)')')
                    {
                    depth = depth - (u32)1;
                    if (depth == (u32)0)
                        {
                        _ci = _ci + (u32)1;
                        break;
                        }
                    }
                _ci = _ci + (u32)1;
                }
            }
        if (_ci == start)
            return (String*)0;
        return _cur.substringBytes(start, _ci - start);
        }

    // ── Module items ─────────────────────────────────────────────────────
    void item(void)
        {
        u32 save = _ci;
        String* w = word();
        if (w == 0)
            {
            giveUpAt("expected a module item");
            return;
            }
        if (w.equals(String.withCString("layout")))
            {
            layout();
            return;
            }
        if (w.equals(String.withCString("constant")))
            {
            constant();
            return;
            }
        if (w.equals(String.withCString("modinit")))
            {
            modinit();
            return;
            }
        if (w.equals(String.withCString("symbol")))
            {
            symbol();
            return;
            }
        if (w.equals(String.withCString("function")))
            {
            function();
            return;
            }
        _ci = save;
        giveUpAt("unknown module item");
        }

    // `layout N: size=S align=A [fields=[(off:TYPE), …]]`
    void layout(void)
        {
        number();
        expectChar((u8)':');
        expectWord("size");
        expectChar((u8)'=');
        u32 size = (u32)number();
        expectWord("align");
        expectChar((u8)'=');
        u32 align = (u32)number();
        IRLayout* L = IRLayout.with(size, align);
        if (expectWord("fields"))
            {
            expectChar((u8)'=');
            expectChar((u8)'[');
            while (!atChar((u8)']') && !atEnd())
                {
                expectChar((u8)'(');
                u32 off = (u32)number();
                expectChar((u8)':');
                String* ty = typeSpelling();
                expectChar((u8)')');
                L.addField(off, ty == 0 ? String.withCString("Void") : ty);
                if (!expectChar((u8)','))
                    break;
                }
            expectChar((u8)']');
            }
        _m.addLayout(L);
        nextLine();
        }

    // `constant N: string bytes=[#$XX, …]`
    void constant(void)
        {
        number();
        expectChar((u8)':');
        expectWord("string");
        expectWord("bytes");
        expectChar((u8)'=');
        _m.addConst(byteList());
        nextLine();
        }

    void modinit(void)
        {
        String* n = quoted();
        if (n != 0)
            _m.addModInit(n);
        nextLine();
        }

    // `[#$XX, #$YY, …]` — the spelling every byte sequence uses.
    Array* byteList(void)
        {
        Array* out = new Array();
        if (!expectChar((u8)'['))
            return out;
        while (!atChar((u8)']') && !atEnd())
            {
            expectChar((u8)'#');
            out.add((Object*)Number.with((u32)number()));
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)']');
        return out;
        }

    // ── Symbols ──────────────────────────────────────────────────────────
    // `symbol NAME: <kind> …`, then an indented `attributes:` line and
    // optionally a `flags:` one. The attribute KEYS say which of the three
    // function shapes it is — a method has `static`, a free function has
    // `cabi`, a synthesised one has neither — and that is what has to be
    // recovered, because it decides what the printer emits.
    void symbol(void)
        {
        String* name = word();
        if (name == 0)
            {
            giveUpAt("expected a symbol name");
            return;
            }
        if (!expectChar((u8)':'))
            {
            giveUpAt("expected `:` after a symbol name");
            return;
            }
        String* kind = word();
        if (kind == 0)
            {
            giveUpAt("expected a symbol kind");
            return;
            }
        IRSymbol* sym = symbolBody(name, kind);
        if (sym == 0)
            return;
        nextLine();
        attributesInto(sym);
        flagsInto(sym);
        _m.addSym(sym);
        }

    IRSymbol* symbolBody(String* name, String* kind)
        {
        if (kind.equals(String.withCString("function")))
            {
            // The signature is the rest of the line, verbatim — the model
            // keeps it as a spelling and prints it back unchanged.
            skipSpace();
            String* sig = _cur.substringFromByte(_ci);
            _ci = _cur.byteLength();
            return IRSymbol.func(name, sig.trimmed(), false, false);
            }
        if (kind.equals(String.withCString("runtime")))
            {
            _ci = _cur.byteLength();
            return IRSymbol.runtime(name);
            }
        if (kind.equals(String.withCString("dataglobal")))
            {
            String* ty = typeSpelling();
            IRSymbol* s = IRSymbol.dataGlobal(name, ty == 0 ? String.withCString("Void") : ty);
            // dataGlobal() escapes by construction; here the FLAGS line is the
            // authority, and it is only printed when something is set.
            s.setFlag(String.withCString("escapes"), false);
            if (expectWord("init"))
                s.setBytes(byteList());
            return s;
            }
        if (kind.equals(String.withCString("stringlit")))
            return IRSymbol.stringLit(name, byteList());
        if (kind.equals(String.withCString("vtable")))
            return IRSymbol.vtable(name, slotList());
        giveUpAt("unknown symbol kind");
        return (IRSymbol*)0;
        }

    // `[A$m, _, B$m]` — `_` is an empty slot, which the model spells "".
    Array* slotList(void)
        {
        Array* out = new Array();
        if (!expectChar((u8)'['))
            return out;
        while (!atChar((u8)']') && !atEnd())
            {
            String* w = word();
            if (w == 0)
                break;
            if (w.equals(String.withCString("_")))
                w = String.withCString("");
            out.add((Object*)w);
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)']');
        return out;
        }

    // `attributes: { banked: false, cabi: false, … }` — consumed only when the
    // line really is one, so a symbol without the line leaves the cursor alone.
    void attributesInto(IRSymbol* sym)
        {
        u32 save = _ci;
        if (!expectWord("attributes"))
            {
            _ci = save;
            return;
            }
        expectChar((u8)':');
        expectChar((u8)'{');
        bool sawStatic = false;
        bool sawCabi = false;
        while (!atChar((u8)'}') && !atEnd())
            {
            String* key = word();
            if (key == 0)
                break;
            expectChar((u8)':');
            bool val = expectWord("true");
            if (!val)
                expectWord("false");
            if (key.equals(String.withCString("static")))
                sawStatic = true;
            if (key.equals(String.withCString("cabi")))
                sawCabi = true;
            sym.setAttr(key, val);
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)'}');
        // A RUNTIME symbol prints one fixed attribute set and asks nothing
        // about shape; the other kinds carry it in their keys.
        if (sym.kind() == (u8)SYM_FUNCTION)
            {
            if (sawStatic)
                sym.setMethodShape();
            else if (!sawCabi)
                sym.setPlain();
            }
        nextLine();
        }

    void flagsInto(IRSymbol* sym)
        {
        u32 save = _ci;
        if (!expectWord("flags"))
            {
            _ci = save;
            return;
            }
        expectChar((u8)':');
        expectChar((u8)'{');
        while (!atChar((u8)'}') && !atEnd())
            {
            String* key = word();
            if (key == 0)
                break;
            expectChar((u8)':');
            bool val = expectWord("true");
            if (!val)
                expectWord("false");
            sym.setFlag(key, val);
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)'}');
        nextLine();
        }

    // ── Functions ────────────────────────────────────────────────────────
    // `function NAME(%0: T, …) -> (T, Mem) {`, then an optional frame line,
    // then blocks. Two passes over the body: the first collects every value
    // DEFINITION so a phi can name a value the text has not reached yet, the
    // second builds the instructions.
    void function(void)
        {
        _fn = new IRFunc();
        _vals = new Map();
        _blocks = new Map();
        String* name = word();
        if (name == 0)
            {
            giveUpAt("expected a function name");
            return;
            }
        _fn.setName(name);
        if (!params())
            return;
        returnType();
        expectChar((u8)'{');
        u32 body = _li + (u32)1;
        u32 end = bodyEnd(body);
        nextLine();
        frameLine();
        unrollLine();
        collectDefs(_li, end);
        while (!_failed && _li < end)
            blockOrInsn();
        if (_li < _lines.count())
            nextLine(); // the closing `}`
        _m.addFunc(_fn);
        }

    // The line index of the function's closing brace — the first line that is
    // nothing but `}`. No instruction can look like that, and the module's own
    // brace is only ever reached after the last function has been consumed.
    u32 bodyEnd(u32 from)
        {
        for (u32 i = from; i < _lines.count(); i = i + (u32)1)
            if (((String*)_lines.get(i)).equals(String.withCString("}")))
                return i;
        return _lines.count();
        }

    bool params(void)
        {
        if (!expectChar((u8)'('))
            {
            giveUpAt("expected `(`");
            return false;
            }
        while (!atChar((u8)')') && !atEnd())
            {
            String* id = valueId();
            if (id == 0)
                {
                giveUpAt("expected a parameter");
                return false;
                }
            expectChar((u8)':');
            String* ty = typeSpelling();
            _fn.addParam(defineValue(id, ty == 0 ? String.withCString("Void") : ty));
            if (!expectChar((u8)','))
                break;
            }
        if (!expectChar((u8)')'))
            {
            giveUpAt("expected `)`");
            return false;
            }
        return true;
        }

    // `-> (T, Mem)` carries a value; `-> Mem` is the void shape.
    void returnType(void)
        {
        expectChar((u8)'-');
        expectChar((u8)'>');
        if (expectChar((u8)'('))
            {
            String* ty = typeSpelling();
            _fn.setRet(ty == 0 ? String.withCString("Void") : ty);
            expectChar((u8)',');
            word();
            expectChar((u8)')');
            return;
            }
        word(); // `Mem`
        _fn.setRet(String.withCString("Void"));
        }

    // `unroll: [bb_x, ...]` — the loop headers `: unroll` asked for. Read back
    // into the same list the printer wrote, so the hint survives the
    // front-end/back-end process boundary: the two halves only ever exchange IR
    // TEXT, so without this the optimiser in xcc-cg-<arch> would never see it.
    //
    // Emitted only when non-empty, so this returns untouched on the vast
    // majority of functions — `_ci = save` and no line advance, exactly as
    // frameLine does when there is no frame.
    void unrollLine(void)
        {
        u32 save = _ci;
        if (!expectWord("unroll"))
            {
            _ci = save;
            return;
            }
        expectChar((u8)':');
        expectChar((u8)'[');
        while (!atChar((u8)']') && !atEnd())
            {
            String* nm = word();
            if (nm == (String*)0)
                break;
            _fn.addUnrollHeader(nm);
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)']');
        nextLine();
        }

    // `frame: { pinned: [(%2:U16 @0 esc), …], size: 4 }`
    void frameLine(void)
        {
        u32 save = _ci;
        if (!expectWord("frame"))
            {
            _ci = save;
            return;
            }
        expectChar((u8)':');
        expectChar((u8)'{');
        if (expectWord("pinned"))
            {
            expectChar((u8)':');
            expectChar((u8)'[');
            while (!atChar((u8)']') && !atEnd())
                {
                expectChar((u8)'(');
                String* id = valueId();
                expectChar((u8)':');
                String* ty = typeSpelling();
                expectChar((u8)'@');
                u32 off = (u32)number();
                bool esc = expectWord("esc");
                expectChar((u8)')');
                _fn.addPinned(IRPinned.with(defineValue(id, ty), ty, off, esc));
                if (!expectChar((u8)','))
                    break;
                }
            expectChar((u8)']');
            expectChar((u8)',');
            }
        if (expectWord("size"))
            {
            expectChar((u8)':');
            _fn.setPinnedSize((u32)number());
            }
        expectChar((u8)'}');
        nextLine();
        }

    // ── Values ───────────────────────────────────────────────────────────
    String* valueId(void)
        {
        skipSpace();
        if (_ci >= _cur.byteLength() || _cur.byteAt(_ci) != (u8)'%')
            return (String*)0;
        _ci = _ci + (u32)1;
        u32 start = _ci;
        while (_ci < _cur.byteLength() && _cur.byteAt(_ci) >= (u8)'0' && _cur.byteAt(_ci) <= (u8)'9')
            _ci = _ci + (u32)1;
        if (_ci == start)
            return (String*)0;
        return _cur.substringBytes(start, _ci - start);
        }

    IRValue* defineValue(String* id, String* ty)
        {
        Object* have = _vals.get((Hashable*)id);
        if (have != 0)
            {
            IRValue* v = (IRValue*)have;
            if (ty != 0)
                v.setTy(ty);
            return v;
            }
        IRValue* v = new IRValue(ty == 0 ? String.withCString("Void") : ty);
        // The id the TEXT gave it, kept as the value's own: a back end assigns
        // frame slots in id order, so the numbering has to survive parsing.
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < id.byteLength(); i = i + (u32)1)
            n = n * (u32)10 + (u32)(id.byteAt(i) - (u8)'0');
        v.setPid(n);
        _vals.set((Hashable*)id, (Object*)v);
        if (_fn != 0)
            _fn.noteValue(n, v);
        return v;
        }

    IRValue* useValue(String* id)
        {
        Object* have = _vals.get((Hashable*)id);
        if (have != 0)
            return (IRValue*)have;
        // A reference the definition pass never saw. It cannot be made right
        // by guessing a type, so it is a hard stop rather than a Void that
        // prints as something plausible.
        String* w = String.withCString("undefined value %");
        w.append(id);
        giveUp(w);
        return new IRValue(String.withCString("Void"));
        }

    // Pass 1. Every DEFINITION in the body — the LHS of each instruction, and
    // every block name — before a single operand is resolved.
    void collectDefs(u32 from, u32 to)
        {
        u32 saveLi = _li;
        u32 saveCi = _ci;
        for (u32 i = from; i < to; i = i + (u32)1)
            {
            _li = i;
            _ci = (u32)0;
            _cur = (String*)_lines.get(i);
            collectDefsOnLine();
            }
        _li = saveLi;
        _ci = saveCi;
        _cur = _li < _lines.count() ? (String*)_lines.get(_li) : String.withCString("");
        }

    void collectDefsOnLine(void)
        {
        skipSpace();
        if (blockHeaderName() != 0)
            return;
        String* first = valueId();
        if (first == 0)
            return;
        if (expectChar((u8)':'))
            {
            String* ty = typeSpelling();
            defineValue(first, ty);
            if (expectChar((u8)','))
                {
                String* mem = valueId();
                if (mem != 0)
                    defineValue(mem, String.withCString("Mem"));
                }
            return;
            }
        // `%12 = Store …` — a memory result on its own.
        defineValue(first, String.withCString("Mem"));
        }

    // A block header is a bare name followed by `:` and nothing else. `preds:`
    // looks the same, so it is named out; every other line with a `:` on it
    // has something after it.
    String* blockHeaderName(void)
        {
        u32 save = _ci;
        String* w = word();
        if (w == 0)
            {
            _ci = save;
            return (String*)0;
            }
        if (w.equals(String.withCString("preds")))
            {
            _ci = save;
            return (String*)0;
            }
        if (!expectChar((u8)':'))
            {
            _ci = save;
            return (String*)0;
            }
        if (!atEnd())
            {
            _ci = save;
            return (String*)0;
            }
        return w;
        }

    IRBlock* blockNamed(String* name)
        {
        Object* have = _blocks.get((Hashable*)name);
        if (have != 0)
            return (IRBlock*)have;
        IRBlock* b = new IRBlock(name);
        _blocks.set((Hashable*)name, (Object*)b);
        return b;
        }

    // ── Blocks and instructions ──────────────────────────────────────────
    void blockOrInsn(void)
        {
        String* name = blockHeaderName();
        if (name != 0)
            {
            IRBlock* b = blockNamed(name);
            _fn.addBlock(b);
            nextLine();
            skipPreds();
            return;
            }
        if (expectWord("preds"))
            {
            nextLine();
            return;
            }
        instruction();
        }

    // The printer recomputes `preds:` from the terminators, so what the text
    // says about them is not read back — reading it would give the model a
    // second, disagreeing copy of a derived fact.
    void skipPreds(void)
        {
        u32 save = _ci;
        if (!expectWord("preds"))
            {
            _ci = save;
            return;
            }
        nextLine();
        }

    void instruction(void)
        {
        if (_fn.blocks().count() == (u32)0)
            {
            giveUpAt("instruction outside a block");
            return;
            }
        IRBlock* blk = (IRBlock*)_fn.blocks().get(_fn.blocks().count() - (u32)1);
        IRValue* res = (IRValue*)0;
        IRValue* mem = (IRValue*)0;
        u32 save = _ci;
        String* first = valueId();
        if (first != 0)
            {
            if (expectChar((u8)':'))
                {
                typeSpelling();
                res = useValue(first);
                if (expectChar((u8)','))
                    {
                    String* m = valueId();
                    if (m != 0)
                        mem = useValue(m);
                    }
                expectChar((u8)'=');
                }
            else if (expectChar((u8)'='))
                {
                mem = useValue(first);
                }
            else
                {
                _ci = save;
                }
            }
        String* op = word();
        if (op == 0)
            {
            giveUpAt("expected an opcode");
            return;
            }
        IRInsn* insn = IRInsn.with(op);
        insn.setRes(res);
        insn.setMemRes(mem);
        operands(insn, op);
        if (_failed)
            return;
        place(blk, insn, op);
        nextLine();
        }

    // A phi goes in the block's phi list, a terminator in its terminator slot,
    // everything else in the instruction list — the three the printer emits in
    // that order.
    void place(IRBlock* blk, IRInsn* insn, String* op)
        {
        if (op.equals(String.withCString("Phi")))
            {
            blk.addPhi(insn);
            return;
            }
        if (IrParser.isTerminator(op))
            {
            blk.setTerm(insn);
            return;
            }
        blk.add(insn);
        }

    static bool isTerminator(String* op)
        {
        return op.equals(String.withCString("Return")) || op.equals(String.withCString("Branch")) || op.equals(String.withCString("CondBranch")) || op.equals(String.withCString("Switch")) || op.equals(String.withCString("Unreachable"));
        }

    static bool isCallOp(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect"));
        }

    void operands(IRInsn* insn, String* op)
        {
        if (op.equals(String.withCString("Phi")))
            {
            phiOperands(insn);
            return;
            }
        if (IrParser.isCallOp(op))
            {
            callOperands(insn);
            return;
            }
        // ICmp / FCmp / VICmp lead with a PREDICATE, which is a bare word where
        // an operand would otherwise start. VICmp joined them when the printer
        // was fixed to emit one: before that the text carried a lane-wise
        // compare with no operator, and the back end could only refuse it.
        if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")) || op.equals(String.withCString("VICmp")))
            {
            skipSpace();
            if (!atEnd() && IrParser.isIdentChar(_cur.byteAt(_ci)))
                {
                insn.setPred(word());
                expectChar((u8)',');
                }
            }
        while (!atEnd() && !_failed)
            {
            IROperand* o = operand();
            if (o == 0)
                break;
            insn.add(o);
            if (!expectChar((u8)','))
                break;
            }
        }

    // `Phi [(bb_a, %1), (bb_b, %2)]` — stored flat, block then value, which is
    // the order the printer walks them back out in.
    void phiOperands(IRInsn* insn)
        {
        if (!expectChar((u8)'['))
            return;
        while (!atChar((u8)']') && !atEnd() && !_failed)
            {
            expectChar((u8)'(');
            IROperand* b = operand();
            expectChar((u8)',');
            IROperand* v = operand();
            expectChar((u8)')');
            if (b == 0 || v == 0)
                break;
            insn.add(b);
            insn.add(v);
            if (!expectChar((u8)','))
                break;
            }
        expectChar((u8)']');
        }

    // `<callee>, [args…], CallConv::Kind, %mem` — flattened to callee, args,
    // mem, with the convention held beside them.
    void callOperands(IRInsn* insn)
        {
        IROperand* callee = operand();
        if (callee == 0)
            {
            giveUpAt("expected a callee");
            return;
            }
        insn.add(callee);
        expectChar((u8)',');
        if (expectChar((u8)'['))
            {
            while (!atChar((u8)']') && !atEnd() && !_failed)
                {
                IROperand* a = operand();
                if (a == 0)
                    break;
                insn.add(a);
                if (!expectChar((u8)','))
                    break;
                }
            expectChar((u8)']');
            expectChar((u8)',');
            }
        insn.setCc(callConv());
        expectChar((u8)',');
        IROperand* mem = operand();
        if (mem != 0)
            insn.add(mem);
        }

    String* callConv(void)
        {
        u32 save = _ci;
        String* head = word();
        if (head == 0 || !head.equals(String.withCString("CallConv")))
            {
            _ci = save;
            return String.withCString("CallConv::Standard");
            }
        expectChar((u8)':');
        expectChar((u8)':');
        String* kind = word();
        String* out = String.withCString("CallConv::");
        out.append(kind == 0 ? String.withCString("Standard") : kind);
        return out;
        }

    IROperand* operand(void)
        {
        skipSpace();
        if (atEnd())
            return (IROperand*)0;
        u8 c = _cur.byteAt(_ci);
        if (c == (u8)'%')
            {
            String* id = valueId();
            if (id == 0)
                return (IROperand*)0;
            return IROperand.useVal(useValue(id));
            }
        if (c == (u8)'@')
            {
            _ci = _ci + (u32)1;
            String* n = word();
            return IROperand.sym(n == 0 ? String.withCString("") : n);
            }
        if (c == (u8)'#')
            return immediate();
        if (c == (u8)'-' && _ci + (u32)1 < _cur.byteLength() && !IrParser.isDigit(_cur.byteAt(_ci + (u32)1)))
            {
            _ci = _ci + (u32)1; // a bare `-`: no operands
            return (IROperand*)0;
            }
        // Anything else is a BLOCK name — the only bare word an operand can be.
        String* w = word();
        if (w == 0)
            return (IROperand*)0;
        return IROperand.block(blockNamed(w));
        }

    static bool isDigit(u8 c)
        {
        return c >= (u8)'0' && c <= (u8)'9';
        }

    // `#123:U16`, `#-6:I16`, `#fp<16 hex>:F64`, `#cpool:3`.
    IROperand* immediate(void)
        {
        _ci = _ci + (u32)1; // the `#`
        // `fp` is a PREFIX, not a word: the hex digits run straight on from it
        // (`#fp3ff0000000000000:F32`), so reading a whole identifier here
        // swallows the number and leaves nothing to compare.
        if (_ci + (u32)1 < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'f' && _cur.byteAt(_ci + (u32)1) == (u8)'p')
            {
            _ci = _ci + (u32)2;
            return floatImm();
            }
        u32 save = _ci;
        String* w = word();
        if (w != 0 && w.equals(String.withCString("cpool")))
            {
            expectChar((u8)':');
            return IROperand.cpool((u32)number());
            }
        _ci = save;
        return intImm();
        }

    IROperand* floatImm(void)
        {
        u32 start = _ci;
        while (_ci < _cur.byteLength() && IrParser.hexDigit(_cur.byteAt(_ci)) >= (i32)0)
            _ci = _ci + (u32)1;
        String* hex = _cur.substringBytes(start, _ci - start);
        expectChar((u8)':');
        String* ty = typeSpelling();
        return IROperand.immF(hex, ty == 0 ? String.withCString("F64") : ty);
        }

    // A NEGATIVE immediate keeps its sign; a non-negative one is read as an
    // unsigned quantity, because that is the only reading that survives the
    // round trip: `#4294967290:U32` does not fit an i32 and would print back
    // as `-6`. Both spell the same digits for anything that fits both.
    IROperand* intImm(void)
        {
        skipSpace();
        bool neg = false;
        if (_ci < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'-')
            {
            neg = true;
            _ci = _ci + (u32)1;
            }
        // Accumulated at 64 bits: the back ends read IR TEXT, so a 32-bit
        // accumulator here truncated every wide Const before any of them saw
        // it — the front end printed `#1000000000000` and the back end
        // materialised its low half.
        u64 v = (u64)0;
        if (_ci < _cur.byteLength() && _cur.byteAt(_ci) == (u8)'$')
            {
            _ci = _ci + (u32)1;
            while (_ci < _cur.byteLength() && IrParser.hexDigit(_cur.byteAt(_ci)) >= (i32)0)
                {
                v = v * (u64)16 + (u64)IrParser.hexDigit(_cur.byteAt(_ci));
                _ci = _ci + (u32)1;
                }
            }
        else
            {
            while (_ci < _cur.byteLength() && IrParser.isDigit(_cur.byteAt(_ci)))
                {
                v = v * (u64)10 + (u64)(_cur.byteAt(_ci) - (u8)'0');
                _ci = _ci + (u32)1;
                }
            }
        String* ty = String.withCString("U16");
        if (expectChar((u8)':'))
            {
            String* t = typeSpelling();
            if (t != 0)
                ty = t;
            }
        if (neg)
            return IROperand.immI((i64)0 - (i64)v, ty);
        return IROperand.immU64(v, ty);
        }
    }
