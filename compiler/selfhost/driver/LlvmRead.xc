// LlvmRead.xc — the C path's reader: LLVM IR text, as clang writes it for C
// before LLVM's own passes (`clang -O1 -Xclang -disable-llvm-passes -S
// -emit-llvm`), to an IRModule.
// =========================================================================
//
// cpp-front-end.md, "The C path". clang compiles C; xcc reads what clang
// made of it and finds the loops to make par blocks of. Read before LLVM's
// passes the IR has the shape xc's own lowering gives its optimiser: every
// local an alloca (here a pinned slot, which xc's mem2reg promotes), loops
// tested at the top, counters in their own width.
//
// The subset is what clang emits for plain C: the integer and float scalar
// types and ptr; alloca, load, store, getelementptr over a scalar or an
// array of scalars, the arithmetic, icmp, fcmp, select, the casts, phi, br,
// ret, and calls (to a C function, or an llvm.* intrinsic this file knows).
// A function that uses anything else is not read: `why()` says what, and the
// caller leaves the function to clang.
//
// LLVM's pointers are opaque (`ptr`). xc's are typed, so a pointer is read
// as Ptr(U8) and given its element type where it is used: a getelementptr,
// a load or a store casts it (Bitcast) to the type it addresses.

#import "Foundation.xc"
#import "Ir.xc"
#import "FloatEncoding.xc"

class LlvmReader
    {
    IRModule* _m;
    String* _why;           // the first construct a function used that is not read; 0 when all were
    Map* _globals;          // "@name" -> its symbol name in the module
    Map* _globalElem;       // "@name" -> the IR type an AddrOf of it addresses (the element of an array)
    Map* _retTy;            // "@name" -> the function's IR return type
    Map* _defined;          // "@name" -> 1 for a function defined in this file
    u32 _strN;
    String* _path;          // the C file, for source lines (0: none)
    u32 _fileId;
    Map* _locs;             // "!N" -> Number@ line << 16 | column, from the DILocations

    // Per function.
    IRFunc* _fn;
    IRBlock* _blk;
    IRValue* _mem;
    Map* _vals;             // "%name" -> IRValue@
    Map* _pins;             // "%name" -> IRPinned@ (an alloca)
    Map* _blocks;           // label -> IRBlock@
    u32 _pinOff;

    // The line being read, and where in it.
    String* _s;
    u32 _p;

    void init(void)
        {
        _globals = new Map();
        _globalElem = new Map();
        _retTy = new Map();
        _defined = new Map();
        _strN = (u32)0;
        }

    String* why(void)
        {
        return _why;
        }

    // The C file the IR came from: its instructions then carry its lines
    // (clang's -gline-tables-only), as -g puts them on xc's, which is how
    // the outliner tells the program's loops from the library's.
    void setPath(String* p)
        {
        _path = p;
        }

    // The module, or 0 when the text is not LLVM IR this file reads.
    static IRModule* readText(String* text, LlvmReader* r)
        {
        return r.read(text);
        }

    IRModule* read(String* text)
        {
        IRModule* m = new IRModule();
        m.setName(String.withCString("c"));
        return readInto(text, m);
        }

    // The C program's functions and globals added to m (a module lowered
    // from xc: the par runtime, for the outliner's blocks).
    IRModule* readInto(String* text, IRModule* m)
        {
        _m = m;
        Array* lines = text.splitOnByte((u8)10);
        _locs = new Map();
        if (_path != (String*)0)
            {
            _fileId = IRDbg.fileIdForSourcePath(_path);
            for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
                {
                String* l = (String*)lines.get(i);
                if (!l.hasPrefix(String.withCString("!")))
                    continue;
                u32 at = l.indexOfByte((u8)'=');
                if (at == (u32)$FFFFFFFF || !l.substringFromByte(at).hasPrefix(String.withCString("= !DILocation(")))
                    continue;
                String* key = l.substringBytes((u32)0, at).trimmed();
                u32 line = numAfter(l, "line: ");
                u32 col = numAfter(l, "column: ");
                _locs.set((Hashable*)key, (Object*)Number.with((line << (u32)16) | (col & (u32)$FFFF)));
                }
            }
        // Globals and declarations first: a function may use one defined below it.
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(String.withCString("@")))
                readGlobal(l);
            else if (l.hasPrefix(String.withCString("declare ")))
                readDeclare(l);
            else if (l.hasPrefix(String.withCString("define ")))
                readSignature(l, false);
            }
        u32 i = (u32)0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                {
                i = i + (u32)1;
                continue;
                }
            u32 end = i + (u32)1;
            while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                end = end + (u32)1;
            readFunction(lines, i, end);
            i = end + (u32)1;
            }
        return _m;
        }

    static u32 numAfter(String* l, u8* key)
        {
        String* k = String.withCString(key);
        for (u32 i = (u32)0; i + k.byteLength() <= l.byteLength(); i = i + (u32)1)
            {
            bool same = true;
            for (u32 j = (u32)0; j < k.byteLength() && same; j = j + (u32)1)
                same = l.byteAt(i + j) == k.byteAt(j);
            if (!same)
                continue;
            u32 n = (u32)0;
            for (u32 j = i + k.byteLength(); j < l.byteLength() && l.byteAt(j) >= (u8)'0' && l.byteAt(j) <= (u8)'9'; j = j + (u32)1)
                n = n * (u32)10 + (u32)(l.byteAt(j) - (u8)'0');
            return n;
            }
        return (u32)0;
        }

    // The line's `!dbg !N` as the current source position (or none).
    void lineOf(String* l)
        {
        IRDbg.clearCurrent();
        if (_path == (String*)0)
            return;
        String* k = String.withCString("!dbg !");
        for (u32 i = (u32)0; i + k.byteLength() <= l.byteLength(); i = i + (u32)1)
            {
            bool same = true;
            for (u32 j = (u32)0; j < k.byteLength() && same; j = j + (u32)1)
                same = l.byteAt(i + j) == k.byteAt(j);
            if (!same)
                continue;
            u32 e = i + k.byteLength();
            while (e < l.byteLength() && l.byteAt(e) >= (u8)'0' && l.byteAt(e) <= (u8)'9')
                e = e + (u32)1;
            Number* loc = (Number*)_locs.get((Hashable*)l.substringBytes(i + (u32)5, e - i - (u32)5));
            if (loc != (Number*)0)
                IRDbg.setCurrent(_fileId, loc.asU32() >> (u32)16, loc.asU32() & (u32)$FFFF);
            return;
            }
        }

    // ── the cursor over one line ────────────────────────────────────────

    void at(String* s)
        {
        _s = s;
        _p = (u32)0;
        }
    bool more(void)
        {
        ws();
        return _p < _s.byteLength();
        }
    void ws(void)
        {
        while (_p < _s.byteLength() && (_s.byteAt(_p) == (u8)' ' || _s.byteAt(_p) == (u8)9))
            _p = _p + (u32)1;
        }
    u8 peek(void)
        {
        ws();
        return _p < _s.byteLength() ? _s.byteAt(_p) : (u8)0;
        }
    bool eat(u8* tok)
        {
        ws();
        String* t = String.withCString(tok);
        if (_p + t.byteLength() > _s.byteLength())
            return false;
        for (u32 k = (u32)0; k < t.byteLength(); k = k + (u32)1)
            if (_s.byteAt(_p + k) != t.byteAt(k))
                return false;
        // A word must end at a word's end.
        u32 e = _p + t.byteLength();
        u8 last = t.byteAt(t.byteLength() - (u32)1);
        if (isWordByte(last) && e < _s.byteLength() && isWordByte(_s.byteAt(e)))
            return false;
        _p = e;
        return true;
        }
    static bool isWordByte(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'.' || c == (u8)'$' || c == (u8)'-';
        }
    // A word: letters, digits, `_ . $ -`, or a `%`/`@` name.
    String* word(void)
        {
        ws();
        u32 b = _p;
        if (_p < _s.byteLength() && (_s.byteAt(_p) == (u8)'%' || _s.byteAt(_p) == (u8)'@'))
            _p = _p + (u32)1;
        if (_p < _s.byteLength() && _s.byteAt(_p) == (u8)'"')
            {
            // A quoted name: `@"odd name"`.
            _p = _p + (u32)1;
            while (_p < _s.byteLength() && _s.byteAt(_p) != (u8)'"')
                _p = _p + (u32)1;
            _p = _p + (u32)1;
            return _s.substringBytes(b, _p - b);
            }
        while (_p < _s.byteLength() && isWordByte(_s.byteAt(_p)))
            _p = _p + (u32)1;
        return _s.substringBytes(b, _p - b);
        }
    // The attributes LLVM writes beside a value or a function: skipped.
    void skipAttrs(void)
        {
        bool again = true;
        while (again)
            {
            again = false;
            ws();
            u32 save = _p;
            String* w = word();
            if (w.equals(String.withCString("noundef")) || w.equals(String.withCString("nonnull"))
                || w.equals(String.withCString("nocapture")) || w.equals(String.withCString("readonly"))
                || w.equals(String.withCString("writeonly")) || w.equals(String.withCString("signext"))
                || w.equals(String.withCString("zeroext")) || w.equals(String.withCString("noalias"))
                || w.equals(String.withCString("inreg")) || w.equals(String.withCString("returned"))
                || w.equals(String.withCString("nofree")) || w.equals(String.withCString("immarg")))
                again = true;
            else if (w.equals(String.withCString("align")) || w.equals(String.withCString("dereferenceable"))
                     || w.equals(String.withCString("dereferenceable_or_null")))
                {
                skipParens();
                word();
                again = true;
                }
            else
                _p = save;
            }
        }
    void skipParens(void)
        {
        if (peek() != (u8)'(')
            return;
        u32 depth = (u32)0;
        while (_p < _s.byteLength())
            {
            u8 c = _s.byteAt(_p);
            _p = _p + (u32)1;
            if (c == (u8)'(')
                depth = depth + (u32)1;
            else if (c == (u8)')')
                {
                depth = depth - (u32)1;
                if (depth == (u32)0)
                    return;
                }
            }
        }

    // ── types ────────────────────────────────────────────────────────────

    // An LLVM type at the cursor, as LLVM spells it (`i32`, `[8 x i8]`), or 0.
    String* llType(void)
        {
        ws();
        if (peek() == (u8)'[')
            {
            u32 b = _p;
            u32 depth = (u32)0;
            while (_p < _s.byteLength())
                {
                u8 c = _s.byteAt(_p);
                _p = _p + (u32)1;
                if (c == (u8)'[')
                    depth = depth + (u32)1;
                else if (c == (u8)']')
                    {
                    depth = depth - (u32)1;
                    if (depth == (u32)0)
                        break;
                    }
                }
            return _s.substringBytes(b, _p - b);
            }
        if (peek() == (u8)'{' || peek() == (u8)'<' || peek() == (u8)'%')
            return (String*)0;
        String* w = word();
        if (w.byteLength() == (u32)0)
            return (String*)0;
        return w;
        }

    // The IR type of a scalar LLVM type, or 0.
    static String* irOf(String* t)
        {
        if (t == (String*)0)
            return (String*)0;
        if (t.equals(String.withCString("i1"))) return String.withCString("Bool");
        if (t.equals(String.withCString("i8"))) return String.withCString("I8");
        if (t.equals(String.withCString("i16"))) return String.withCString("I16");
        if (t.equals(String.withCString("i32"))) return String.withCString("I32");
        if (t.equals(String.withCString("i64"))) return String.withCString("I64");
        if (t.equals(String.withCString("float"))) return String.withCString("F32");
        if (t.equals(String.withCString("double"))) return String.withCString("F64");
        if (t.equals(String.withCString("ptr"))) return String.withCString("Ptr(U8, unbanked)");
        if (t.equals(String.withCString("void"))) return String.withCString("Void");
        return (String*)0;
        }
    static u32 widthOf(String* irT)
        {
        if (irT.equals(String.withCString("Bool")) || irT.equals(String.withCString("I8"))) return (u32)1;
        if (irT.equals(String.withCString("I16"))) return (u32)2;
        if (irT.equals(String.withCString("I32")) || irT.equals(String.withCString("F32"))) return (u32)4;
        return (u32)8;
        }
    static String* ptrTo(String* irT)
        {
        return String.withFormat("Ptr(%s, unbanked)", irT.cString());
        }
    // `[N x T]` -> N and T (in _arrN, the return), or 0 when it is not an array of a scalar.
    u32 _arrN;
    String* arrayOf(String* t)
        {
        if (t == (String*)0 || !t.hasPrefix(String.withCString("[")))
            return (String*)0;
        u32 x = t.indexOfByte((u8)'x');
        if (x == (u32)$FFFFFFFF)
            return (String*)0;
        u32 n = (u32)0;
        for (u32 k = (u32)1; k < x; k = k + (u32)1)
            {
            u8 c = t.byteAt(k);
            if (c >= (u8)'0' && c <= (u8)'9')
                n = n * (u32)10 + (u32)(c - (u8)'0');
            }
        _arrN = n;
        String* inner = t.substringBytes(x + (u32)1, t.byteLength() - x - (u32)2).trimmed();
        return irOf(inner);
        }

    // ── globals and declarations ────────────────────────────────────────

    String* symFor(String* llName)
        {
        String* have = (String*)_globals.get((Hashable*)llName);
        if (have != (String*)0)
            return have;
        String* n = llName.substringFromByte((u32)1);
        if (n.hasPrefix(String.withCString("\"")) || n.indexOfByte((u8)'.') != (u32)$FFFFFFFF)
            {
            _strN = _strN + (u32)1;
            n = String.withFormat("cg_%u", _strN);
            }
        _globals.set((Hashable*)llName, (Object*)n);
        return n;
        }

    bool hasSym(String* n)
        {
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            if (((IRSymbol*)_m.syms().get(i)).name().equals(n))
                return true;
        return false;
        }

    void readGlobal(String* l)
        {
        at(l);
        String* name = word();
        if (!eat("="))
            return;
        // linkage and the like, up to `global` / `constant`.
        bool found = false;
        for (u32 guard = (u32)0; guard < (u32)8 && !found; guard = guard + (u32)1)
            {
            String* w = word();
            if (w.equals(String.withCString("global")) || w.equals(String.withCString("constant")))
                found = true;
            if (w.byteLength() == (u32)0)
                return;
            }
        if (!found)
            return;
        String* t = llType();
        String* sym = symFor(name);
        String* elem = arrayOf(t);
        if (elem != (String*)0)
            {
            u32 n = _arrN;
            ws();
            if (_s.substringFromByte(_p).hasPrefix(String.withCString("c\"")))
                {
                // A string: its bytes, `\XX` escapes undone.
                _p = _p + (u32)2;
                Array* bytes = new Array();
                while (_p < _s.byteLength() && _s.byteAt(_p) != (u8)'"')
                    {
                    u8 c = _s.byteAt(_p);
                    if (c == (u8)'\\' && _p + (u32)2 < _s.byteLength())
                        {
                        c = (u8)(hexNibble(_s.byteAt(_p + (u32)1)) * (u8)16 + hexNibble(_s.byteAt(_p + (u32)2)));
                        _p = _p + (u32)3;
                        }
                    else
                        _p = _p + (u32)1;
                    bytes.add((Object*)Number.with((u32)c));
                    }
                _m.addSym(IRSymbol.stringLit(sym, bytes));
                _globalElem.set((Hashable*)name, (Object*)elem);
                return;
                }
            IRLayout* L = IRLayout.array(elem, n, widthOf(elem), widthOf(elem));
            u32 id = _m.addLayout(L);
            _m.addSym(IRSymbol.dataGlobal(sym, String.withFormat("Agg(%u)", id)));
            _globalElem.set((Hashable*)name, (Object*)elem);
            return;
            }
        String* it = irOf(t);
        if (it != (String*)0 && !it.equals(String.withCString("Void")))
            {
            // A scalar (its initial value is not carried yet: zero).
            _m.addSym(IRSymbol.dataGlobal(sym, it));
            _globalElem.set((Hashable*)name, (Object*)it);
            }
        }
    static u8 hexNibble(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9') return (u8)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f') return (u8)(c - (u8)'a' + (u8)10);
        if (c >= (u8)'A' && c <= (u8)'F') return (u8)(c - (u8)'A' + (u8)10);
        return (u8)0;
        }

    void readDeclare(String* l)
        {
        readSignature(l, true);
        }

    // `define`/`declare RET @name(PARAMS)`: the symbol, with the C ABI.
    void readSignature(String* l, bool decl)
        {
        at(l);
        word(); // define / declare
        String* ret = (String*)0;
        String* name = (String*)0;
        for (u32 guard = (u32)0; guard < (u32)12 && name == (String*)0; guard = guard + (u32)1)
            {
            ws();
            if (peek() == (u8)'@')
                {
                name = word();
                break;
                }
            u32 save = _p;
            String* t = llType();
            if (t != (String*)0 && irOf(t) != (String*)0)
                ret = t;
            if (_p == save)
                _p = _p + (u32)1;
            }
        if (name == (String*)0 || ret == (String*)0)
            return;
        // llvm.* intrinsics are not symbols.
        if (name.hasPrefix(String.withCString("@llvm.")))
            return;
        String* sym = symFor(name);
        _retTy.set((Hashable*)name, (Object*)irOf(ret));
        if (!decl)
            _defined.set((Hashable*)name, (Object*)Number.with((u32)1));
        Array* ptys = new Array();
        bool variadic = false;
        if (eat("("))
            {
            while (more() && peek() != (u8)')')
                {
                if (eat("..."))
                    {
                    variadic = true;
                    continue;
                    }
                String* pt = llType();
                if (pt == (String*)0)
                    return;
                ptys.add((Object*)irOf(pt));
                skipAttrs();
                if (peek() == (u8)'%')
                    word();
                eat(",");
                }
            }
        String* sig = String.withCString("(");
        for (u32 i = (u32)0; i < ptys.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                sig.appendCString(", ");
            sig.append((String*)ptys.get(i));
            }
        sig.appendCString(") -> ");
        sig.append(irOf(ret));
        // A function this file defines is compiled by xcc and called only
        // from it (the whole program is read): xc's own convention. A C
        // library function is reached through the C ABI. A symbol the
        // module has already (a C function the xc runtime declares too)
        // stays as it is.
        if (!hasSym(sym))
            _m.addSym(IRSymbol.func(sym, sig, variadic, decl));
        }

    // ── a function ───────────────────────────────────────────────────────

    void fail(u8* what)
        {
        if (_why == (String*)0)
            _why = String.withFormat("%s (in %s: `%s`)", what, _fn != (IRFunc*)0 ? _fn.name().cString() : "?",
                                     _s != (String*)0 ? _s.trimmed().cString() : "");
        _bad = true;
        }
    bool _bad;

    void readFunction(Array* lines, u32 head, u32 end)
        {
        at((String*)lines.get(head));
        word();
        String* ret = (String*)0;
        String* name = (String*)0;
        for (u32 guard = (u32)0; guard < (u32)12 && name == (String*)0; guard = guard + (u32)1)
            {
            ws();
            if (peek() == (u8)'@')
                {
                name = word();
                break;
                }
            u32 save = _p;
            String* t = llType();
            if (t != (String*)0 && irOf(t) != (String*)0)
                ret = t;
            if (_p == save)
                _p = _p + (u32)1;
            }
        if (name == (String*)0 || ret == (String*)0)
            return;
        _fn = new IRFunc();
        _fn.setName(symFor(name));
        _fn.setRet(irOf(ret));
        _vals = new Map();
        _pins = new Map();
        _blocks = new Map();
        _pinOff = (u32)0;
        _bad = false;
        u32 nParams = (u32)0;
        if (eat("("))
            {
            while (more() && peek() != (u8)')')
                {
                String* pt = llType();
                if (pt == (String*)0 || irOf(pt) == (String*)0)
                    {
                    fail("a parameter of a type not read");
                    return;
                    }
                skipAttrs();
                String* pn = word();
                IRValue* v = new IRValue(irOf(pt));
                _fn.addParam(v);
                _vals.set((Hashable*)pn, (Object*)v);
                nParams = nParams + (u32)1;
                eat(",");
                }
            }
        _mem = new IRValue(String.withCString("Mem"));
        _fn.addParam(_mem);
        // The entry block: its own label when the IR names its values, else
        // the next number after the parameters.
        _blk = (IRBlock*)0;
        u32 first = head + (u32)1;
        while (first < end && ((String*)lines.get(first)).trimmed().byteLength() == (u32)0)
            first = first + (u32)1;
        if (first >= end || ((String*)lines.get(first)).hasPrefix(String.withCString(" ")))
            {
            _blk = blockNamed(String.withFormat("%u", nParams));
            _fn.addBlock(_blk);
            }
        for (u32 i = head + (u32)1; i < end && !_bad; i = i + (u32)1)
            {
            String* l = (String*)lines.get(i);
            String* t = l.trimmed();
            if (t.byteLength() == (u32)0 || t.hasPrefix(String.withCString(";")))
                continue;
            // A label: `10:` (with a `; preds` comment after it).
            if (!l.hasPrefix(String.withCString(" ")))
                {
                u32 colon = t.indexOfByte((u8)':');
                if (colon != (u32)$FFFFFFFF)
                    {
                    IRBlock* nb = blockNamed(t.substringBytes((u32)0, colon));
                    // A block reached by falling through is not LLVM: each ends in a terminator.
                    _blk = nb;
                    _fn.addBlock(nb);
                    continue;
                    }
                }
            lineOf(t);
            readInsn(t);
            }
        IRDbg.clearCurrent();
        if (_bad)
            return;
        _fn.setPinnedSize(_pinOff);
        _m.addFunc(_fn);
        }

    IRBlock* blockNamed(String* label)
        {
        IRBlock* b = (IRBlock*)_blocks.get((Hashable*)label);
        if (b == (IRBlock*)0)
            {
            b = new IRBlock(String.withFormat("bb_%s", label.cString()));
            _blocks.set((Hashable*)label, (Object*)b);
            }
        return b;
        }

    // The value `%name` has, made now (with type t) when it is defined later.
    IRValue* valNamed(String* name, String* t)
        {
        IRValue* v = (IRValue*)_vals.get((Hashable*)name);
        if (v == (IRValue*)0)
            {
            v = new IRValue(t);
            _vals.set((Hashable*)name, (Object*)v);
            }
        return v;
        }

    // ── operands ────────────────────────────────────────────────────────

    IRValue* emit(String* op, String* ty, IROperand* a, IROperand* b, IROperand* c)
        {
        IRInsn* n = IRInsn.with(op);
        IRValue* r = new IRValue(ty);
        n.setRes(r);
        if (a != (IROperand*)0) n.add(a);
        if (b != (IROperand*)0) n.add(b);
        if (c != (IROperand*)0) n.add(c);
        _blk.add(n);
        return r;
        }

    // An operand of IR type t at the cursor: a value, a global's address, or a
    // constant (made a Const). 0, with the function failed, when not read.
    IRValue* operand(String* t)
        {
        ws();
        u8 c = peek();
        if (c == (u8)'%')
            {
            String* n = word();
            IRPinned* pin = (IRPinned*)_pins.get((Hashable*)n);
            if (pin != (IRPinned*)0)
                return emit(String.withCString("AddrOf"), ptrTo(pin.val().ty()), IROperand.useVal(pin.val()), (IROperand*)0, (IROperand*)0);
            return valNamed(n, t);
            }
        if (c == (u8)'@')
            {
            String* n = word();
            String* sym = (String*)_globals.get((Hashable*)n);
            if (sym == (String*)0)
                {
                fail("a global not read");
                return (IRValue*)0;
                }
            String* e = (String*)_globalElem.get((Hashable*)n);
            String* pt = e != (String*)0 ? ptrTo(e) : String.withCString("Ptr(U8, unbanked)");
            return emit(String.withCString("AddrOf"), pt, IROperand.sym(sym), (IROperand*)0, (IROperand*)0);
            }
        // A constant expression `getelementptr inbounds (T, ptr @g, i64 0, i64 K)`:
        // the element's address, made here.
        ws();
        if (_s.substringFromByte(_p).hasPrefix(String.withCString("getelementptr")))
            {
            word();
            eat("inbounds");
            eat("nuw");
            eat("nusw");
            if (!eat("("))
                {
                fail("a constant expression not read");
                return (IRValue*)0;
                }
            IRValue* g = gepValue();
            eat(")");
            return g;
            }
        u32 cb = _p;
        while (_p < _s.byteLength() && _s.byteAt(_p) != (u8)',' && _s.byteAt(_p) != (u8)')'
               && _s.byteAt(_p) != (u8)' ' && _s.byteAt(_p) != (u8)']')
            _p = _p + (u32)1;
        String* w = _s.substringBytes(cb, _p - cb);
        if (w.equals(String.withCString("true")) || w.equals(String.withCString("false")))
            return emit(String.withCString("Const"), t, IROperand.immI(w.equals(String.withCString("true")) ? (i64)1 : (i64)0, t), (IROperand*)0, (IROperand*)0);
        if (w.equals(String.withCString("null")))
            {
            IRValue* z = emit(String.withCString("Const"), String.withCString("I64"), IROperand.immI((i64)0, String.withCString("I64")), (IROperand*)0, (IROperand*)0);
            return emit(String.withCString("IntToPtr"), t, IROperand.useVal(z), (IROperand*)0, (IROperand*)0);
            }
        if (w.equals(String.withCString("undef")) || w.equals(String.withCString("poison")) || w.equals(String.withCString("zeroinitializer")))
            {
            if (t.hasPrefix(String.withCString("F")))
                return emit(String.withCString("Const"), t, IROperand.immF(String.withCString("0000000000000000"), t), (IROperand*)0, (IROperand*)0);
            return emit(String.withCString("Const"), t, IROperand.immI((i64)0, t), (IROperand*)0, (IROperand*)0);
            }
        if (t.hasPrefix(String.withCString("F")))
            {
            String* hex = (String*)0;
            if (w.hasPrefix(String.withCString("0x")))
                hex = w.substringFromByte((u32)2);
            else
                {
                // The encoder's hex is in memory order (little-endian):
                // the IR's is the number's, most significant byte first.
                String* le = FloatEncoding.hexForLiteral(w, true);
                hex = new String();
                for (u32 k = le.byteLength(); k >= (u32)2; k = k - (u32)2)
                    hex.append(le.substringBytes(k - (u32)2, (u32)2));
                }
            return emit(String.withCString("Const"), t, IROperand.immF(hex, t), (IROperand*)0, (IROperand*)0);
            }
        if (w.byteLength() > (u32)0 && (w.byteAt((u32)0) == (u8)'-' || (w.byteAt((u32)0) >= (u8)'0' && w.byteAt((u32)0) <= (u8)'9')))
            {
            i64 v = (i64)0;
            bool neg = w.byteAt((u32)0) == (u8)'-';
            for (u32 k = neg ? (u32)1 : (u32)0; k < w.byteLength(); k = k + (u32)1)
                v = v * (i64)10 + (i64)(w.byteAt(k) - (u8)'0');
            if (neg)
                v = (i64)0 - v;
            return emit(String.withCString("Const"), t, IROperand.immI(v, t), (IROperand*)0, (IROperand*)0);
            }
        fail("an operand not read");
        return (IRValue*)0;
        }

    // `TYPE operand` (with its attributes), as a value of that type.
    IRValue* typedOperand(void)
        {
        String* t = irOf(llType());
        if (t == (String*)0)
            {
            fail("an operand of a type not read");
            return (IRValue*)0;
            }
        skipAttrs();
        return operand(t);
        }

    // v as a pointer to `elemT` (LLVM's are untyped).
    IRValue* asPtrTo(IRValue* v, String* elemT)
        {
        String* want = ptrTo(elemT);
        if (v.ty().equals(want))
            return v;
        return emit(String.withCString("Bitcast"), want, IROperand.useVal(v), (IROperand*)0, (IROperand*)0);
        }

    // ── instructions ─────────────────────────────────────────────────────

    void readInsn(String* full)
        {
        // The metadata attached after the operands (`, !dbg !29, !tbaa !20`)
        // is not read: the line ends where it starts.
        String* line = full;
        for (u32 i = (u32)0; i + (u32)2 < full.byteLength(); i = i + (u32)1)
            if (full.byteAt(i) == (u8)',' && full.byteAt(i + (u32)1) == (u8)' ' && full.byteAt(i + (u32)2) == (u8)'!')
                {
                line = full.substringBytes((u32)0, i);
                break;
                }
        at(line);
        String* res = (String*)0;
        if (peek() == (u8)'%')
            {
            u32 save = _p;
            res = word();
            if (!eat("="))
                {
                _p = save;
                res = (String*)0;
                }
            }
        String* op = word();
        if (op.equals(String.withCString("alloca")))
            {
            String* t = irOf(llType());
            if (t == (String*)0 || t.equals(String.withCString("Void")))
                {
                fail("an alloca of a type not read");
                return;
                }
            IRPinned* p = IRPinned.with(new IRValue(t), t, _pinOff, false);
            _pinOff = _pinOff + (u32)8;
            _fn.addPinned(p);
            _pins.set((Hashable*)res, (Object*)p);
            return;
            }
        if (op.equals(String.withCString("load")))
            {
            eat("volatile");
            String* t = irOf(llType());
            eat(",");
            IRValue* addr = typedOperand();
            if (t == (String*)0 || addr == (IRValue*)0)
                {
                fail("a load not read");
                return;
                }
            addr = asPtrTo(addr, t);
            IRInsn* ld = IRInsn.with(String.withCString("Load"));
            IRValue* r = valNamed(res, t);
            r.setTy(t);
            IRValue* mo = new IRValue(String.withCString("Mem"));
            ld.setRes(r);
            ld.setMemRes(mo);
            ld.add(IROperand.useVal(addr));
            ld.add(IROperand.useVal(_mem));
            _blk.add(ld);
            _mem = mo;
            return;
            }
        if (op.equals(String.withCString("store")))
            {
            eat("volatile");
            IRValue* v = typedOperand();
            eat(",");
            IRValue* addr = typedOperand();
            if (v == (IRValue*)0 || addr == (IRValue*)0)
                {
                fail("a store not read");
                return;
                }
            addr = asPtrTo(addr, v.ty());
            IRInsn* st = IRInsn.with(String.withCString("Store"));
            IRValue* mo = new IRValue(String.withCString("Mem"));
            st.add(IROperand.useVal(addr));
            st.add(IROperand.useVal(v));
            st.add(IROperand.useVal(_mem));
            st.setMemRes(mo);
            _blk.add(st);
            _mem = mo;
            return;
            }
        if (op.equals(String.withCString("getelementptr")))
            {
            readGep(res);
            return;
            }
        String* bin = binOp(op);
        if (bin != (String*)0)
            {
            // flags: nsw nuw exact disjoint fast and the like.
            while (eat("nsw") || eat("nuw") || eat("exact") || eat("disjoint") || eat("fast") || eat("nnan")
                   || eat("ninf") || eat("nsz") || eat("arcp") || eat("contract") || eat("afn") || eat("reassoc"))
                {
                }
            String* t = irOf(llType());
            IRValue* a = operand(t);
            eat(",");
            IRValue* b = operand(t);
            if (t == (String*)0 || a == (IRValue*)0 || b == (IRValue*)0)
                {
                fail("an arithmetic instruction not read");
                return;
                }
            define(res, bin, t, IROperand.useVal(a), IROperand.useVal(b), (IROperand*)0, (String*)0);
            return;
            }
        if (op.equals(String.withCString("fneg")))
            {
            String* t = irOf(llType());
            IRValue* a = operand(t);
            if (a == (IRValue*)0)
                return;
            IRValue* z = emit(String.withCString("Const"), t, IROperand.immF(String.withCString("8000000000000000"), t), (IROperand*)0, (IROperand*)0);
            define(res, String.withCString("FSub"), t, IROperand.useVal(z), IROperand.useVal(a), (IROperand*)0, (String*)0);
            return;
            }
        if (op.equals(String.withCString("icmp")) || op.equals(String.withCString("fcmp")))
            {
            while (eat("fast") || eat("nnan") || eat("ninf") || eat("nsz") || eat("samesign"))
                {
                }
            String* pred = word().uppercased();
            String* t = irOf(llType());
            IRValue* a = operand(t);
            eat(",");
            IRValue* b = operand(t);
            if (t == (String*)0 || a == (IRValue*)0 || b == (IRValue*)0)
                {
                fail("a compare not read");
                return;
                }
            define(res, String.withCString(op.equals(String.withCString("icmp")) ? "ICmp" : "FCmp"), String.withCString("Bool"),
                   IROperand.useVal(a), IROperand.useVal(b), (IROperand*)0, pred);
            return;
            }
        String* cast = castOp(op);
        if (cast != (String*)0)
            {
            eat("nneg");
            IRValue* a = typedOperand();
            if (!eat("to"))
                {
                fail("a cast not read");
                return;
                }
            String* t = irOf(llType());
            if (a == (IRValue*)0 || t == (String*)0)
                {
                fail("a cast not read");
                return;
                }
            define(res, cast, t, IROperand.useVal(a), (IROperand*)0, (IROperand*)0, (String*)0);
            return;
            }
        if (op.equals(String.withCString("select")))
            {
            IRValue* c = typedOperand();
            eat(",");
            IRValue* a = typedOperand();
            eat(",");
            IRValue* b = typedOperand();
            if (c == (IRValue*)0 || a == (IRValue*)0 || b == (IRValue*)0)
                {
                fail("a select not read");
                return;
                }
            define(res, String.withCString("Select"), a.ty(), IROperand.useVal(c), IROperand.useVal(a), IROperand.useVal(b), (String*)0);
            return;
            }
        if (op.equals(String.withCString("phi")))
            {
            String* t = irOf(llType());
            IRInsn* phi = IRInsn.with(String.withCString("Phi"));
            IRValue* r = valNamed(res, t);
            r.setTy(t);
            phi.setRes(r);
            while (eat("["))
                {
                // A phi's constant operand is made in its predecessor: here,
                // it is made at the top of this block, which dominates nothing
                // it must; so only values are read.
                ws();
                if (peek() != (u8)'%')
                    {
                    fail("a phi with a constant operand");
                    return;
                    }
                String* vn = word();
                eat(",");
                String* bn = word().substringFromByte((u32)1);
                eat("]");
                eat(",");
                phi.add(IROperand.block(blockNamed(bn)));
                phi.add(IROperand.useVal(valNamed(vn, t)));
                }
            _blk.addPhi(phi);
            return;
            }
        if (op.equals(String.withCString("br")))
            {
            if (eat("label"))
                {
                String* l = word().substringFromByte((u32)1);
                IRInsn* b = IRInsn.with(String.withCString("Branch"));
                b.add(IROperand.block(blockNamed(l)));
                _blk.setTerm(b);
                return;
                }
            IRValue* c = typedOperand();
            eat(",");
            eat("label");
            String* l1 = word().substringFromByte((u32)1);
            eat(",");
            eat("label");
            String* l2 = word().substringFromByte((u32)1);
            if (c == (IRValue*)0)
                return;
            IRInsn* b = IRInsn.with(String.withCString("CondBranch"));
            b.add(IROperand.useVal(c));
            b.add(IROperand.block(blockNamed(l1)));
            b.add(IROperand.block(blockNamed(l2)));
            _blk.setTerm(b);
            return;
            }
        if (op.equals(String.withCString("ret")))
            {
            IRInsn* r = IRInsn.with(String.withCString("Return"));
            if (!eat("void"))
                {
                IRValue* v = typedOperand();
                if (v == (IRValue*)0)
                    return;
                r.add(IROperand.useVal(v));
                }
            r.add(IROperand.useVal(_mem));
            _blk.setTerm(r);
            return;
            }
        if (op.equals(String.withCString("call")) || op.equals(String.withCString("tail")) || op.equals(String.withCString("notail")))
            {
            if (!op.equals(String.withCString("call")))
                eat("call");
            readCall(res);
            return;
            }
        if (op.equals(String.withCString("unreachable")))
            {
            _blk.setTerm(IRInsn.with(String.withCString("Unreachable")));
            return;
            }
        fail(String.withFormat("an instruction not read: %s", op.cString()).cString());
        }

    // r = op(a, b, c), the result named `res` (already referenced or not).
    void define(String* res, String* op, String* t, IROperand* a, IROperand* b, IROperand* c, String* pred)
        {
        IRInsn* n = IRInsn.with(op);
        IRValue* r = res != (String*)0 ? valNamed(res, t) : new IRValue(t);
        r.setTy(t);
        n.setRes(r);
        if (pred != (String*)0)
            n.setPred(pred);
        if (a != (IROperand*)0) n.add(a);
        if (b != (IROperand*)0) n.add(b);
        if (c != (IROperand*)0) n.add(c);
        _blk.add(n);
        }

    static String* binOp(String* op)
        {
        if (op.equals(String.withCString("add"))) return String.withCString("Add");
        if (op.equals(String.withCString("sub"))) return String.withCString("Sub");
        if (op.equals(String.withCString("mul"))) return String.withCString("Mul");
        if (op.equals(String.withCString("sdiv"))) return String.withCString("SDiv");
        if (op.equals(String.withCString("udiv"))) return String.withCString("UDiv");
        if (op.equals(String.withCString("srem"))) return String.withCString("SRem");
        if (op.equals(String.withCString("urem"))) return String.withCString("URem");
        if (op.equals(String.withCString("shl"))) return String.withCString("Shl");
        if (op.equals(String.withCString("lshr"))) return String.withCString("LShr");
        if (op.equals(String.withCString("ashr"))) return String.withCString("AShr");
        if (op.equals(String.withCString("and"))) return String.withCString("And");
        if (op.equals(String.withCString("or"))) return String.withCString("Or");
        if (op.equals(String.withCString("xor"))) return String.withCString("Xor");
        if (op.equals(String.withCString("fadd"))) return String.withCString("FAdd");
        if (op.equals(String.withCString("fsub"))) return String.withCString("FSub");
        if (op.equals(String.withCString("fmul"))) return String.withCString("FMul");
        if (op.equals(String.withCString("fdiv"))) return String.withCString("FDiv");
        return (String*)0;
        }

    static String* castOp(String* op)
        {
        if (op.equals(String.withCString("sext"))) return String.withCString("SExt");
        if (op.equals(String.withCString("zext"))) return String.withCString("ZExt");
        if (op.equals(String.withCString("trunc"))) return String.withCString("Trunc");
        if (op.equals(String.withCString("sitofp"))) return String.withCString("SIToFp");
        if (op.equals(String.withCString("uitofp"))) return String.withCString("UIToFp");
        if (op.equals(String.withCString("fptosi"))) return String.withCString("FpToSI");
        if (op.equals(String.withCString("fptoui"))) return String.withCString("FpToUI");
        if (op.equals(String.withCString("fpext"))) return String.withCString("FpExt");
        if (op.equals(String.withCString("fptrunc"))) return String.withCString("FpTrunc");
        if (op.equals(String.withCString("bitcast"))) return String.withCString("Bitcast");
        if (op.equals(String.withCString("ptrtoint"))) return String.withCString("PtrToInt");
        if (op.equals(String.withCString("inttoptr"))) return String.withCString("IntToPtr");
        return (String*)0;
        }

    // `getelementptr [inbounds] T, ptr base, idx...`: an element of a scalar
    // array (one index), or of an array type (`[N x T]`, a first index of 0
    // then one more).
    void readGep(String* res)
        {
        eat("inbounds");
        eat("nuw");
        eat("nusw");
        IRValue* g = gepValue();
        if (g == (IRValue*)0)
            return;
        // The result takes the name: a use before this line made it already.
        IRValue* r = valNamed(res, g.ty());
        if (r != g)
            {
            IRInsn* last = (IRInsn*)_blk.insns().get(_blk.insns().count() - (u32)1);
            r.setTy(g.ty());
            last.setRes(r);
            }
        }

    // `T, ptr base, idx...` (after `getelementptr [inbounds]`): the
    // element's address.
    IRValue* gepValue(void)
        {
        String* t = llType();
        eat(",");
        IRValue* base = typedOperand();
        if (base == (IRValue*)0)
            return (IRValue*)0;
        Array* idx = new Array();
        while (eat(","))
            {
            IRValue* i = typedOperand();
            if (i == (IRValue*)0)
                return (IRValue*)0;
            idx.add((Object*)i);
            }
        String* elem = irOf(t);
        IRValue* ix = (IRValue*)0;
        if (elem != (String*)0 && idx.count() == (u32)1)
            ix = (IRValue*)idx.get((u32)0);
        else
            {
            elem = arrayOf(t);
            if (elem == (String*)0 || idx.count() != (u32)2)
                {
                fail("a getelementptr not read (a struct, or more indices)");
                return (IRValue*)0;
                }
            // The first index steps over whole arrays: only 0 is read.
            ix = (IRValue*)idx.get((u32)1);
            }
        IRValue* b = asPtrTo(base, elem);
        return emit(String.withCString("ElementAddr"), ptrTo(elem), IROperand.useVal(b), IROperand.useVal(ix), (IROperand*)0);
        }

    // `call RET [(SIG)] @f(ARGS)`.
    void readCall(String* res)
        {
        String* rt = irOf(llType());
        if (rt == (String*)0)
            {
            fail("a call of a type not read");
            return;
            }
        // A function type for a variadic callee: `(ptr, ...)`.
        if (peek() == (u8)'(')
            skipParens();
        skipAttrs();
        ws();
        if (peek() != (u8)'@')
            {
            fail("an indirect call");
            return;
            }
        String* callee = word();
        // Markers that mean nothing to xc: not even their operands are read
        // (an alloca's address taken for one would keep the slot in memory).
        if (callee.hasPrefix(String.withCString("@llvm.lifetime.")) || callee.hasPrefix(String.withCString("@llvm.dbg."))
            || callee.hasPrefix(String.withCString("@llvm.assume")))
            return;
        Array* args = new Array();
        if (eat("("))
            {
            while (more() && peek() != (u8)')')
                {
                IRValue* a = typedOperand();
                if (a == (IRValue*)0)
                    return;
                args.add((Object*)a);
                eat(",");
                }
            }
        // a * b + c, fused or not as the target likes: a multiply and an add.
        if (callee.hasPrefix(String.withCString("@llvm.fmuladd.")) && args.count() == (u32)3)
            {
            IRValue* p = emit(String.withCString("FMul"), rt, IROperand.useVal((IRValue*)args.get((u32)0)),
                              IROperand.useVal((IRValue*)args.get((u32)1)), (IROperand*)0);
            define(res, String.withCString("FAdd"), rt, IROperand.useVal(p), IROperand.useVal((IRValue*)args.get((u32)2)),
                   (IROperand*)0, (String*)0);
            return;
            }
        if (callee.hasPrefix(String.withCString("@llvm.")))
            {
            // Markers that mean nothing to xc.
            if (callee.hasPrefix(String.withCString("@llvm.lifetime.")) || callee.hasPrefix(String.withCString("@llvm.dbg."))
                || callee.hasPrefix(String.withCString("@llvm.assume")))
                return;
            // The maths: the C library's functions of the same name.
            String* lib = (String*)0;
            if (callee.hasPrefix(String.withCString("@llvm.sqrt.f64"))) lib = String.withCString("sqrt");
            else if (callee.hasPrefix(String.withCString("@llvm.sqrt.f32"))) lib = String.withCString("sqrtf");
            else if (callee.hasPrefix(String.withCString("@llvm.fabs.f64"))) lib = String.withCString("fabs");
            else if (callee.hasPrefix(String.withCString("@llvm.fabs.f32"))) lib = String.withCString("fabsf");
            if (lib == (String*)0)
                {
                fail(String.withFormat("an intrinsic not read: %s", callee.cString()).cString());
                return;
                }
            String* n = String.withFormat("@%s", lib.cString());
            if (_globals.get((Hashable*)n) == (Object*)0)
                {
                _globals.set((Hashable*)n, (Object*)lib);
                String* sig = String.withFormat("(%s) -> %s", rt.cString(), rt.cString());
                _m.addSym(IRSymbol.func(lib, sig, false, true));
                }
            callee = n;
            }
        String* sym = (String*)_globals.get((Hashable*)callee);
        if (sym == (String*)0)
            {
            fail("a call to a function not declared");
            return;
            }
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        c.setCc(String.withCString("CallConv::Standard"));
        c.add(IROperand.sym(sym));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            c.add(IROperand.useVal((IRValue*)args.get(i)));
        c.add(IROperand.useVal(_mem));
        if (!rt.equals(String.withCString("Void")))
            {
            IRValue* r = res != (String*)0 ? valNamed(res, rt) : new IRValue(rt);
            r.setTy(rt);
            c.setRes(r);
            }
        IRValue* mo = new IRValue(String.withCString("Mem"));
        c.setMemRes(mo);
        _blk.add(c);
        _mem = mo;
        }
    }
