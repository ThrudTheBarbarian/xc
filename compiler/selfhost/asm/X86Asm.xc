// X86_64.xc — the x86-64 assembler, in xtc.
// =================================================================
//
// self-hosting M20, a port of `XAX86_64Assembler`. It consumes the
// Intel-syntax text the x86_64 back end emits and produces machine code, a
// symbol table and relocation fixups — so a Mac can build a Linux binary with
// no Linux tooling anywhere in the chain.
//
// Unlike AArch64, x86-64 is variable-length: an instruction is
// [legacy prefixes][REX][opcode][ModRM][SIB][disp][imm]. So this is table- and
// form-driven rather than one bitfield per mnemonic, and the shapes are told
// apart by what the OPERANDS are, not by the mnemonic alone.
//
// Every symbolic reference the back end emits is a FIXED-WIDTH field — rel32
// for branches, disp32 for a RIP-relative operand, a whole quad in data — so an
// instruction's size never depends on a symbol's value and one pass suffices.
// A branch-relaxing assembler would have to iterate to a fixpoint; this one
// does not.

#import "Foundation.xc"

#define X86FIX_REL32 0
#define X86FIX_PC32 1
#define X86FIX_ABS64 2
// The four below are never produced by THIS assembler. They exist because the
// linker also consumes objects it did not produce — musl's, built by clang —
// and those carry relocation kinds our own code generator has no reason to
// emit (task #47, private:docs/Design/foreign-object-linking.md). Kept here rather
// than in the merge so that one enumeration covers every fixup the writer can
// be handed, whatever produced it.
#define X86FIX_PC32DATA 3 // a PC-relative slot in DATA — musl's vfprintf
                          // builds a position-independent jump table
#define X86FIX_GOTLOAD 4  // [REX_]GOTPCRELX: a RELAXABLE GOT load. When the
                          // opcode two bytes back is mov (0x8b) it becomes
                          // lea and no slot is needed at all
#define X86FIX_GOTREF 5   // plain GOTPCREL: NOT relaxable, because the slot
                          // is read as data — it needs a real GOT entry
#define X86FIX_TPOFF32 6  // local-exec TLS: the addend IS the final
                          // %fs-relative offset, so there is no symbol to
                          // resolve

#define OP_NONE 0
#define OP_REG 1
#define OP_MEM 2
#define OP_IMM 3

class X86Fixup
    {
    u32 _offset;
    u32 _kind;
    String* _symbol;
    i32 _addend;

    void init(void)
        {
        }

    static X86Fixup* make(u32 off, u32 kind, String* sym, i32 addend)
        {
        X86Fixup* f = new X86Fixup();
        f._offset = off;
        f._kind = kind;
        f._symbol = sym;
        f._addend = addend;
        return f;
        }

    u32 offset(void)
        {
        return _offset;
        }
    u32 kind(void)
        {
        return _kind;
        }
    String* symbol(void)
        {
        return _symbol;
        }
    i32 addend(void)
        {
        return _addend;
        }
    void setOffset(u32 v)
        {
        _offset = v;
        }
    }

    // One parsed operand. A memory operand carries no width of its own unless a
    // `ptr` prefix says otherwise, which is why `size` can be zero.
    class XOperand
    {
    u32 _kind;
    u32 _reg;
    u32 _size;
    bool _forceRex;
    i32 _base;  // -1 when absent
    i32 _index; // -1 when absent
    u32 _scale;
    i32 _disp;
    bool _ripRel;
    u32 _seg; // segment-override prefix byte, 0 for none
    String* _symbol;
    u32 _immHi; // the high half of a 64-bit immediate

    void init(void)
        {
        _immHi = (u32)0;
        _kind = (u32)OP_NONE;
        _reg = (u32)0;
        _size = (u32)0;
        _forceRex = false;
        _base = (i32)-1;
        _index = (i32)-1;
        _scale = (u32)1;
        _disp = (i32)0;
        _ripRel = false;
        _seg = (u32)0;
        }

    u32 kind(void)
        {
        return _kind;
        }
    u32 reg(void)
        {
        return _reg;
        }
    u32 size(void)
        {
        return _size;
        }
    bool forceRex(void)
        {
        return _forceRex;
        }
    i32 base(void)
        {
        return _base;
        }
    i32 index(void)
        {
        return _index;
        }
    u32 scale(void)
        {
        return _scale;
        }
    i32 disp(void)
        {
        return _disp;
        }
    bool ripRel(void)
        {
        return _ripRel;
        }
    u32 seg(void)
        {
        return _seg;
        }
    String* symbol(void)
        {
        return _symbol;
        }
    // immediates reuse the disp slot
    i32 imm(void)
        {
        return _disp;
        }
    u32 immHi(void)
        {
        return _immHi;
        }

    void setKind(u32 v)
        {
        _kind = v;
        }
    void setReg(u32 v)
        {
        _reg = v;
        }
    void setSize(u32 v)
        {
        _size = v;
        }
    void setForceRex(bool v)
        {
        _forceRex = v;
        }
    void setBase(i32 v)
        {
        _base = v;
        }
    void setIndex(i32 v)
        {
        _index = v;
        }
    void setScale(u32 v)
        {
        _scale = v;
        }
    void setDisp(i32 v)
        {
        _disp = v;
        }
    void setRipRel(bool v)
        {
        _ripRel = v;
        }
    void setSeg(u32 v)
        {
        _seg = v;
        }
    void setSymbol(String* v)
        {
        _symbol = v;
        }
    void setImmHi(u32 v)
        {
        _immHi = v;
        }

    // The r/m register number: the register itself for a register operand, the
    // base for a memory one.
    i32 rmReg(void)
        {
        return _kind == (u32)OP_REG ? (i32)_reg : _base;
        }
    }

    class X86Asm
    {
    Array* _text; // Number@ per byte
    Array* _data;
    Array* _fixups;     // X86Fixup@
    Map* _symbols;      // name -> offset within its own section
    Array* _dataSyms;   // String@
    Array* _globalSyms; // String@
    Map* _commonSyms;   // `.comm` COMMON: name -> [size, byteAlign] (bug 36 x-obj)
    bool _failed;
    String* _why;
    bool _skipSect; // inside a CodeView .debug$ section — emit nothing

    u32 _insnBase;      // offset in .text of the instruction being encoded
    i32 _ripDispOffset; // -1 when this instruction has no rip operand
    String* _ripSymbol;
    i32 _ripAddend;

    void init(void)
        {
        _text = new Array();
        _data = new Array();
        _fixups = new Array();
        _symbols = new Map();
        _dataSyms = new Array();
        _globalSyms = new Array();
        _commonSyms = new Map();
        _failed = false;
        _skipSect = false;
        }

    Array* text(void)
        {
        return _text;
        }
    Array* data(void)
        {
        return _data;
        }
    Array* fixups(void)
        {
        return _fixups;
        }
    Map* symbols(void)
        {
        return _symbols;
        }
    Array* dataSyms(void)
        {
        return _dataSyms;
        }
    Array* globalSyms(void)
        {
        return _globalSyms;
        }
    Map* commonSyms(void)
        {
        return _commonSyms;
        }

    // A single-unit IMAGE materialises its COMMON (`.comm`) tentative globals
    // into zeroed local storage here — no link stage allocates them. A `-c`
    // object keeps them as commons for the ELF writer (SHN_COMMON), so separate
    // units merge them (C tentative-definition merge). Mirrors the arm64 port.
    void demoteCommonsToLocalData(void)
        {
        if (_commonSyms.count() == (u32)0)
            return;
        Array* names = _commonSyms.allKeys();
        for (u32 i = (u32)1; i < names.count(); i = i + (u32)1)
            {
            Object* cur = names.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)names.get(j - (u32)1)).compare((String*)cur) > (i32)0)
                {
                names.set(j, names.get(j - (u32)1));
                j = j - (u32)1;
                }
            names.set(j, cur);
            }
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
            {
            String* nm = (String*)names.get(k);
            Array* info = (Array*)_commonSyms.get((Hashable*)nm);
            u32 sz = ((Number*)info.get((u32)0)).asU32();
            u32 al = ((Number*)info.get((u32)1)).asU32();
            if (al < (u32)1)
                al = (u32)1;
            while (_data.count() % al != (u32)0)
                _data.add((Object*)Number.withU32((u32)0));
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_data.count()));
            _dataSyms.add((Object*)nm);
            for (u32 i = (u32)0; i < sz; i = i + (u32)1)
                _data.add((Object*)Number.withU32((u32)0));
            }
        _commonSyms = new Map();
        }
    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void fail(String* m)
        {
        if (!_failed)
            {
            _failed = true;
            _why = m;
            }
        }

    void failWith(String* what, String* detail)
        {
        String* m = new String();
        m.append(what);
        if (detail != (String*)0)
            {
            m.appendCString(" '");
            m.append(detail);
            m.appendCString("'");
            }
        fail(m);
        }

    // ── Registers ────────────────────────────────────────────────────────
    //
    // Returns the number, or -1 when the text is not a register. `size` and
    // `needRex` come back through the out fields. The 8-bit forms are the
    // subtle part: spl/bpl/sil/dil are numbers 4-7, the SAME numbers that mean
    // ah/ch/dh/bh WITHOUT a REX prefix — so a REX byte, even an all-zero one,
    // is what selects the low-byte forms.
    u32 _regSize;
    bool _regNeedRex;

    i32 parseReg(String* s0)
        {
        _regSize = (u32)0;
        _regNeedRex = false;
        if (s0 == (String*)0)
            return (i32)-1;
        String* s = s0.trimmed().lowercased();
        if (s.byteLength() < (u32)2)
            return (i32)-1;
        i32 n = named64(s);
        if (n >= (i32)0)
            {
            _regSize = (u32)8;
            return n;
            }
        n = named32(s);
        if (n >= (i32)0)
            {
            _regSize = (u32)4;
            return n;
            }
        n = named16(s);
        if (n >= (i32)0)
            {
            _regSize = (u32)2;
            return n;
            }
        n = named8(s);
        if (n >= (i32)0)
            {
            _regSize = (u32)1;
            _regNeedRex = n >= (i32)4;
            return n;
            }
        n = namedLegacy8(s);
        if (n >= (i32)0)
            {
            _regSize = (u32)1;
            _regNeedRex = false;
            return n;
            }
        // rN / rNd / rNw / rNb, and xmmN.
        if (s.hasPrefix(String.withCString("xmm")))
            {
            i32 v = smallNumber(s, (u32)3);
            if (v < (i32)0 || v > (i32)15)
                return (i32)-1;
            _regSize = (u32)16;
            return v;
            }
        if (s.byteAt((u32)0) != (u8)'r')
            return (i32)-1;
        u32 end = s.byteLength();
        u32 sz = (u32)8;
        u8 last = s.byteAt(end - (u32)1);
        if (last == (u8)'d')
            {
            sz = (u32)4;
            end = end - (u32)1;
            }
        else if (last == (u8)'w')
            {
            sz = (u32)2;
            end = end - (u32)1;
            }
        else if (last == (u8)'b')
            {
            sz = (u32)1;
            end = end - (u32)1;
            }
        i32 v = smallNumber(s.substringBytes((u32)0, end), (u32)1);
        if (v < (i32)8 || v > (i32)15)
            return (i32)-1;
        _regSize = sz;
        return v;
        }

    static i32 smallNumber(String* s, u32 from)
        {
        if (from >= s.byteLength())
            return (i32)-1;
        u32 v = (u32)0;
        for (u32 i = from; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (i32)-1;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return (i32)v;
        }

    static i32 indexOfName(String* s, String* list)
        {
        // `list` is a comma-separated table; the position IS the register
        // number, which is what makes these tables readable.
        u32 idx = (u32)0;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= list.byteLength(); i = i + (u32)1)
            {
            if (i == list.byteLength() || list.byteAt(i) == (u8)',')
                {
                if (s.equals(list.substringBytes(start, i - start)))
                    return (i32)idx;
                idx = idx + (u32)1;
                start = i + (u32)1;
                }
            }
        return (i32)-1;
        }

    static i32 named64(String* s)
        {
        return indexOfName(s, String.withCString("rax,rcx,rdx,rbx,rsp,rbp,rsi,rdi"));
        }
    static i32 named32(String* s)
        {
        return indexOfName(s, String.withCString("eax,ecx,edx,ebx,esp,ebp,esi,edi"));
        }
    static i32 named16(String* s)
        {
        return indexOfName(s, String.withCString("ax,cx,dx,bx,sp,bp,si,di"));
        }
    static i32 named8(String* s)
        {
        return indexOfName(s, String.withCString("al,cl,dl,bl,spl,bpl,sil,dil"));
        }

    // ah/ch/dh/bh are 4-7 with NO REX; they exist only in the legacy encoding.
    static i32 namedLegacy8(String* s)
        {
        if (s.equals(String.withCString("ah")))
            return (i32)4;
        if (s.equals(String.withCString("ch")))
            return (i32)5;
        if (s.equals(String.withCString("dh")))
            return (i32)6;
        if (s.equals(String.withCString("bh")))
            return (i32)7;
        return (i32)-1;
        }

    // ── Numbers ──────────────────────────────────────────────────────────
    //
    // The value is accumulated in two 32-bit halves. Most immediates fit the low
    // one and callers use only that, but a `movabs` magic-division multiplier or
    // a double's bit pattern genuinely needs all 64 — losing the high half there
    // does not fail, it silently multiplies by the wrong constant.
    bool _numOk;
    u32 _numHi;

    i32 parseNum(String* s0)
        {
        _numOk = false;
        _numHi = (u32)0;
        if (s0 == (String*)0)
            return (i32)0;
        String* s = s0.trimmed();
        if (s.byteLength() == (u32)0)
            return (i32)0;
        bool neg = false;
        if (s.hasPrefix(String.withCString("-")))
            {
            neg = true;
            s = s.substringFromByte((u32)1);
            }
        else if (s.hasPrefix(String.withCString("+")))
            s = s.substringFromByte((u32)1);
        u32 base = (u32)10;
        if (s.hasPrefix(String.withCString("0x")) || s.hasPrefix(String.withCString("0X")))
            {
            base = (u32)16;
            s = s.substringFromByte((u32)2);
            }
        if (s.byteLength() == (u32)0)
            return (i32)0;
        u32 lo = (u32)0;
        u32 hi = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            u32 d;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (base == (u32)16 && c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (base == (u32)16 && c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            else
                return (i32)0;
            // (hi:lo) = (hi:lo) * base + d, with the carry out of the low half
            // made explicit — a shift-and-add would lose it.
            u32 lo0 = lo;
            u32 newLo = lo * base;
            u32 carry = mulCarry(lo0, base);
            hi = hi * base + carry;
            u32 sum = newLo + d;
            if (sum < newLo)
                hi = hi + (u32)1;
            lo = sum;
            }
        if (neg)
            {
            // Two's complement across both halves.
            u32 nlo = ~lo + (u32)1;
            u32 nhi = ~hi;
            if (nlo == (u32)0)
                nhi = nhi + (u32)1;
            lo = nlo;
            hi = nhi;
            }
        _numHi = hi;
        _numOk = true;
        return (i32)lo;
        }

    // The high 32 bits of a 32x32 product, computed in 16-bit halves so nothing
    // overflows on the way.
    static u32 mulCarry(u32 a, u32 b)
        {
        u32 al = a & (u32)$FFFF;
        u32 ah = a >> (u32)16;
        u32 bl = b & (u32)$FFFF;
        u32 bh = b >> (u32)16;
        u32 mid = ah * bl + ((al * bl) >> (u32)16);
        u32 mid2 = al * bh + (mid & (u32)$FFFF);
        return ah * bh + (mid >> (u32)16) + (mid2 >> (u32)16);
        }

    // ── Operands ─────────────────────────────────────────────────────────
    XOperand* parseOperand(String* tok)
        {
        XOperand* o = new XOperand();
        String* s = tok.trimmed();
        if (s.byteLength() == (u32)0)
            return o;

        u32 forced = sizePrefix(s);
        if (forced != (u32)0)
            s = s.substringFromByte(prefixLength(s)).trimmed();

        // Segment override — `fs:[…]` / `gs:[…]`. The thread pointer lives
        // behind one of these, so a thread-local read is a load rather than a
        // lookup; nothing else this compiler emits uses a segment.
        u32 segByte = (u32)0;
        String* ls = s.lowercased();
        if (ls.hasPrefix(String.withCString("fs:")))
            segByte = (u32)$64;
        else if (ls.hasPrefix(String.withCString("gs:")))
            segByte = (u32)$65;
        else if (ls.hasPrefix(String.withCString("es:")))
            segByte = (u32)$26;
        else if (ls.hasPrefix(String.withCString("ss:")))
            segByte = (u32)$36;
        else if (ls.hasPrefix(String.withCString("ds:")))
            segByte = (u32)$3E;
        else if (ls.hasPrefix(String.withCString("cs:")))
            segByte = (u32)$2E;
        if (segByte != (u32)0)
            s = s.substringFromByte((u32)3).trimmed();

        if (s.hasPrefix(String.withCString("[")))
            {
            o.setKind((u32)OP_MEM);
            o.setSeg(segByte);
            o.setSize(forced);
            String* inner = stripSpaces(s.substringBytes((u32)1, s.byteLength() - (u32)2));
            Array* terms = splitSigned(inner);
            for (u32 i = (u32)0; i < terms.count(); i = i + (u32)1)
                {
                String* t = (String*)terms.get(i);
                u32 star = t.byteIndexOf(String.withCString("*"));
                // index*scale, or scale*index
                if (star != (u32)$FFFF_FFFF)
                    {
                    String* lhs = t.substringBytes((u32)0, star);
                    String* rhs = t.substringFromByte(star + (u32)1);
                    i32 rn = parseReg(lhs);
                    if (rn >= (i32)0)
                        {
                        i32 sc = parseNum(rhs);
                        if (_numOk)
                            {
                            o.setIndex(rn);
                            o.setScale((u32)sc);
                            continue;
                            }
                        }
                    rn = parseReg(rhs);
                    if (rn >= (i32)0)
                        {
                        i32 sc = parseNum(lhs);
                        if (_numOk)
                            {
                            o.setIndex(rn);
                            o.setScale((u32)sc);
                            continue;
                            }
                        }
                    failWith(String.withCString("bad index term"), t);
                    return o;
                    }
                if (t.lowercased().equals(String.withCString("rip")))
                    {
                    o.setRipRel(true);
                    continue;
                    }
                i32 rn = parseReg(t);
                if (rn >= (i32)0)
                    {
                    if (o.base() < (i32)0)
                        o.setBase(rn);
                    else
                        o.setIndex(rn);
                    continue;
                    }
                i32 v = parseNum(t);
                if (_numOk)
                    {
                    o.setDisp(o.disp() + v);
                    continue;
                    }
                o.setSymbol(t); // a symbolic displacement
                }
            return o;
            }

        i32 rn = parseReg(s);
        if (rn >= (i32)0)
            {
            o.setKind((u32)OP_REG);
            o.setReg((u32)rn);
            o.setSize(_regSize);
            o.setForceRex(_regNeedRex);
            return o;
            }
        i32 v = parseNum(s);
        if (_numOk)
            {
            o.setKind((u32)OP_IMM);
            o.setDisp(v);
            o.setSize(forced);
            o.setImmHi(_numHi);
            return o;
            }

        // A bare identifier is a symbolic immediate or a branch target. `foo@PLT`
        // is just `foo` here: this is the whole-program linker, so it either
        // binds the call directly or routes it through a thunk of its own, and
        // the relocation flavour carries nothing to act on.
        u32 at = s.byteIndexOf(String.withCString("@PLT"));
        if (at != (u32)$FFFF_FFFF && at + (u32)4 == s.byteLength())
            s = s.substringBytes((u32)0, at);
        o.setKind((u32)OP_IMM);
        o.setSymbol(s);
        o.setDisp((i32)0);
        o.setSize(forced);
        return o;
        }

    static u32 sizePrefix(String* s0)
        {
        String* s = s0.lowercased();
        if (s.hasPrefix(String.withCString("byte ptr")))
            return (u32)1;
        if (s.hasPrefix(String.withCString("word ptr")))
            return (u32)2;
        if (s.hasPrefix(String.withCString("dword ptr")))
            return (u32)4;
        if (s.hasPrefix(String.withCString("qword ptr")))
            return (u32)8;
        if (s.hasPrefix(String.withCString("xmmword ptr")))
            return (u32)16;
        return (u32)0;
        }

    static u32 prefixLength(String* s0)
        {
        String* s = s0.lowercased();
        if (s.hasPrefix(String.withCString("xmmword ptr")))
            return (u32)11;
        if (s.hasPrefix(String.withCString("dword ptr")))
            return (u32)9;
        if (s.hasPrefix(String.withCString("qword ptr")))
            return (u32)9;
        if (s.hasPrefix(String.withCString("byte ptr")))
            return (u32)8;
        if (s.hasPrefix(String.withCString("word ptr")))
            return (u32)8;
        return (u32)0;
        }

    static String* stripSpaces(String* s)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c != (u8)' ' && c != (u8)'\t')
                o.appendByte(c);
            }
        return o;
        }

    // Split on + and -, KEEPING a leading minus with its term, so `[rbp-8]`
    // yields "rbp" and "-8".
    static Array* splitSigned(String* inner)
        {
        Array* terms = new Array();
        String* cur = new String();
        for (u32 i = (u32)0; i < inner.byteLength(); i = i + (u32)1)
            {
            u8 c = inner.byteAt(i);
            if ((c == (u8)'+' || c == (u8)'-') && cur.byteLength() > (u32)0)
                {
                terms.add((Object*)cur);
                cur = new String();
                }
            if (c == (u8)'-')
                cur.appendByte((u8)'-');
            else if (c != (u8)'+')
                cur.appendByte(c);
            }
        if (cur.byteLength() > (u32)0)
            terms.add((Object*)cur);
        return terms;
        }

    // Intel condition-code suffix -> the cc nibble, shared by setcc and jcc.
    static i32 ccCode(String* x)
        {
        if (x.equals(String.withCString("o")))
            return (i32)0;
        if (x.equals(String.withCString("no")))
            return (i32)1;
        if (x.equals(String.withCString("b")) || x.equals(String.withCString("c")) || x.equals(String.withCString("nae")))
            return (i32)2;
        if (x.equals(String.withCString("ae")) || x.equals(String.withCString("nb")) || x.equals(String.withCString("nc")))
            return (i32)3;
        if (x.equals(String.withCString("e")) || x.equals(String.withCString("z")))
            return (i32)4;
        if (x.equals(String.withCString("ne")) || x.equals(String.withCString("nz")))
            return (i32)5;
        if (x.equals(String.withCString("be")) || x.equals(String.withCString("na")))
            return (i32)6;
        if (x.equals(String.withCString("a")) || x.equals(String.withCString("nbe")))
            return (i32)7;
        if (x.equals(String.withCString("s")))
            return (i32)8;
        if (x.equals(String.withCString("ns")))
            return (i32)9;
        if (x.equals(String.withCString("p")) || x.equals(String.withCString("pe")))
            return (i32)10;
        if (x.equals(String.withCString("np")) || x.equals(String.withCString("po")))
            return (i32)11;
        if (x.equals(String.withCString("l")) || x.equals(String.withCString("nge")))
            return (i32)12;
        if (x.equals(String.withCString("ge")) || x.equals(String.withCString("nl")))
            return (i32)13;
        if (x.equals(String.withCString("le")) || x.equals(String.withCString("ng")))
            return (i32)14;
        if (x.equals(String.withCString("g")) || x.equals(String.withCString("nle")))
            return (i32)15;
        return (i32)-1;
        }

    // ── Byte emission ────────────────────────────────────────────────────
    Array* _out; // the instruction being built

    void e8(u32 v)
        {
        _out.add((Object*)Number.withU32(v & (u32)$FF));
        }
    void e16(u32 v)
        {
        e8(v);
        e8(v >> (u32)8);
        }
    void e32(u32 v)
        {
        e8(v);
        e8(v >> (u32)8);
        e8(v >> (u32)16);
        e8(v >> (u32)24);
        }

    // A 64-bit immediate. Only movabs takes one; everything else uses imm32,
    // which the CPU sign-extends.
    void e64(u32 lo, u32 hi)
        {
        e32(lo);
        e32(hi);
        }

    void eImmOsz(u32 osz, i32 v)
        {
        if (osz == (u32)1)
            e8((u32)v);
        else if (osz == (u32)2)
            e16((u32)v);
        else
            e32((u32)v);
        }

    // REX: 0100 W R X B. Emitted only when needed — W for 64-bit, any extended
    // register, or an 8-bit spl/bpl/sil/dil.
    //
    // An ABSENT base or index arrives as -1, and (-1 & 8) is 8, which would set
    // REX.X or REX.B and emit a spurious prefix. Clamp both.
    void eRex(bool w, i32 reg, i32 index, i32 rm, bool force)
        {
        u32 r = reg < (i32)0 ? (u32)0 : (u32)reg;
        u32 x = index < (i32)0 ? (u32)0 : (u32)index;
        u32 b = rm < (i32)0 ? (u32)0 : (u32)rm;
        u32 rex = (u32)$40 | (w ? (u32)8 : (u32)0) | ((r & (u32)8) != (u32)0 ? (u32)4 : (u32)0) | ((x & (u32)8) != (u32)0 ? (u32)2 : (u32)0) | ((b & (u32)8) != (u32)0 ? (u32)1 : (u32)0);
        if (w || (r & (u32)8) != (u32)0 || (x & (u32)8) != (u32)0 || (b & (u32)8) != (u32)0 || force)
            e8(rex);
        }

    // ModRM, SIB and displacement for a reg-and-rm pair. Where a RIP-relative
    // disp32 was written, and for which symbol, is published in the _rip fields
    // so the caller can attach the fixup without every return path doing so.
    void eModRM(u32 reg, XOperand* rm)
        {
        if (rm.kind() == (u32)OP_REG)
            {
            e8((u32)$C0 | ((reg & (u32)7) << (u32)3) | (rm.reg() & (u32)7));
            return;
            }
        i32 base = rm.base();
        i32 index = rm.index();
        bool needSib = index >= (i32)0 || (base >= (i32)0 && ((u32)base & (u32)7) == (u32)4); // rsp/r12
        u32 mod;
        if (rm.disp() == (i32)0 && base >= (i32)0 && ((u32)base & (u32)7) != (u32)5)
            mod = (u32)0;
        else if (rm.disp() >= (i32)-128 && rm.disp() <= (i32)127)
            mod = (u32)1;
        else
            mod = (u32)2;
        if (base < (i32)0)
            mod = (u32)0; // disp32 or rip-relative
        u32 rmField = needSib ? (u32)4 : (base >= (i32)0 ? ((u32)base & (u32)7) : (u32)5);
        // A segment-overridden operand with neither base nor index is an
        // ABSOLUTE displacement — `fs:[0]` means offset 0 within that segment,
        // not "0 bytes from here". rip-relative would read the wrong memory, so
        // this takes the SIB form the absolute encoding requires: mod=00,
        // rm=100, SIB base=101 index=100, disp32.
        if (rm.seg() != (u32)0 && index < (i32)0 && base < (i32)0 && !rm.ripRel() && rm.symbol() == (String*)0)
            {
            e8(((reg & (u32)7) << (u32)3) | (u32)4);
            e8((u32)$25);
            e32((u32)rm.disp());
            return;
            }
        // INDEX WITH NO BASE — `[4*rsi]`, which clang emits for a scaled offset
        // it has nothing to add to. It is not rip-relative and it is not just a
        // disp32: the only encoding is mod=00 + SIB with base=101, and that form
        // ALWAYS carries a disp32 even when the displacement is zero. Falling
        // into the rip-relative branch below dropped the SIB byte, so the
        // instruction came out ONE BYTE SHORT and everything after it in the
        // function decoded as garbage (bug 032).
        if (index >= (i32)0 && base < (i32)0 && !rm.ripRel())
            {
            e8(((reg & (u32)7) << (u32)3) | (u32)4);
            u32 ss0 = rm.scale() == (u32)8 ? (u32)3 : rm.scale() == (u32)4 ? (u32)2
                                                  : rm.scale() == (u32)2   ? (u32)1
                                                                           : (u32)0;
            e8((ss0 << (u32)6) | (((u32)index & (u32)7) << (u32)3) | (u32)5);
            e32((u32)rm.disp());
            return;
            }
        if (rm.ripRel() || base < (i32)0)
            {
            e8(((reg & (u32)7) << (u32)3) | (u32)5);
            if (rm.symbol() != (String*)0)
                {
                _ripDispOffset = (i32)_out.count();
                _ripSymbol = rm.symbol();
                _ripAddend = rm.disp(); // `[rip + sym + 80]` — the 80 is the target's
                }
            e32((u32)rm.disp());
            return;
            }
        e8((mod << (u32)6) | ((reg & (u32)7) << (u32)3) | rmField);
        if (needSib)
            {
            u32 ss = rm.scale() == (u32)8 ? (u32)3 : rm.scale() == (u32)4 ? (u32)2
                                                 : rm.scale() == (u32)2   ? (u32)1
                                                                          : (u32)0;
            u32 idx = index >= (i32)0 ? ((u32)index & (u32)7) : (u32)4;
            u32 bs = base >= (i32)0 ? ((u32)base & (u32)7) : (u32)5;
            e8((ss << (u32)6) | (idx << (u32)3) | bs);
            }
        if (mod == (u32)1)
            e8((u32)rm.disp());
        else if (mod == (u32)2)
            e32((u32)rm.disp());
        }

    void recordRel32(String* sym, u32 off)
        {
        if (sym == (String*)0)
            return;
        _fixups.add((Object*)X86Fixup.make(_insnBase + off, (u32)X86FIX_REL32, sym, (i32)-4));
        }

    // ── One instruction ──────────────────────────────────────────────────
    bool _hit;
    Array* _ops; // XOperand@
    u32 _osz;
    bool _w;
    bool _force8;

    Array* encodeOne(String* line)
        {
        _ripDispOffset = (i32)-1;
        _ripSymbol = (String*)0;
        _ripAddend = (i32)0;
        Array* bytes = encodeInsn(line);
        if (bytes != (Array*)0 && _ripDispOffset >= (i32)0 && _ripSymbol != (String*)0)
            {
            // The CPU adds the disp32 to the address of the NEXT instruction, so
            // the addend is minus however many bytes follow the displacement —
            // normally four, but more when an immediate trails it.
            i32 addend = _ripAddend - ((i32)bytes.count() - _ripDispOffset);
            // A `@GOTPCREL` specifier on the operand. The back end emits
            // `mov reg, [rip + sym@GOTPCREL]` to take the address of a symbol
            // that may live in ANOTHER shared object — an imported
            // `<Class>$vtbl`, say. It is the relaxable-mov GOT load: strip the
            // suffix and mark it GOTLOAD, so the writer either relaxes it
            // (symbol defined here) or points it at a loader-filled GOT slot
            // (symbol imported). The PC-relative addend is identical to a plain
            // PC32; only the kind and the symbol differ.
            //
            // Without this the suffix stayed part of the NAME, and the link
            // refused a symbol literally called `Adder$vtbl@GOTPCREL`.
            String* sym = _ripSymbol;
            u32 kind = (u32)X86FIX_PC32;
            String* got = String.withCString("@GOTPCREL");
            if (sym.byteLength() > got.byteLength() && sym.hasSuffix(got))
                {
                sym = sym.substringBytes((u32)0, sym.byteLength() - got.byteLength());
                kind = (u32)X86FIX_GOTLOAD;
                }
            _fixups.add((Object*)X86Fixup.make(_insnBase + (u32)_ripDispOffset,
                                               kind, sym, addend));
            }
        return bytes;
        }

    XOperand* opAt(u32 i)
        {
        return i < _ops.count() ? (XOperand*)_ops.get(i) : (XOperand*)0;
        }

    Array* encodeInsn(String* line)
        {
        _out = new Array();
        _hit = false;
        String* s = line.trimmed();
        u32 sp = firstSpace(s);
        String* mn = (sp == (u32)$FFFF_FFFF ? s : s.substringBytes((u32)0, sp)).lowercased();
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("") : s.substringFromByte(sp);

        // `lock` is a PREFIX, not an instruction: encode what follows it, then
        // put 0xF0 in front — AFTER any 0x66 operand-size prefix, because that
        // is the order clang writes and this assembler is held byte-identical
        // to clang.
        if (mn.equals(String.withCString("lock")))
            {
            Array* inner = encodeInsn(rest.trimmed());
            if (inner == (Array*)0)
                return (Array*)0;
            Array* o = new Array();
            u32 at = (u32)0;
            if (inner.count() > (u32)0 && ((Number*)inner.get((u32)0)).asU32() == (u32)$66)
                {
                o.add(inner.get((u32)0));
                at = (u32)1;
                }
            o.add((Object*)Number.withU32((u32)$F0));
            for (u32 i = at; i < inner.count(); i = i + (u32)1)
                o.add(inner.get(i));
            if (_ripDispOffset >= (i32)0)
                _ripDispOffset = _ripDispOffset + (i32)1;
            _out = o;
            return _out;
            }

        // `rex64` is likewise a PREFIX — REX.W on its own line. clang emits it
        // on the indirect tail-call thunk (`rex64 jmp rdx`), where the W bit is
        // architecturally redundant but present in the bytes we are held
        // identical to. If the inner encoding already carries a REX byte, set W
        // in THAT one: two REX bytes would decode the first as a no-op prefix
        // and change the instruction.
        if (mn.equals(String.withCString("rex64")))
            {
            Array* inner = encodeInsn(rest.trimmed());
            if (inner == (Array*)0)
                return (Array*)0;
            Array* o = new Array();
            u32 i = (u32)0;
            while (i < inner.count())
                {
                u32 pb = ((Number*)inner.get(i)).asU32();
                if (pb != (u32)$66 && pb != (u32)$F2 && pb != (u32)$F3 && pb != (u32)$F0)
                    break;
                o.add(inner.get(i));
                i = i + (u32)1;
                }
            bool haveRex = false;
            if (i < inner.count())
                {
                u32 rb = ((Number*)inner.get(i)).asU32();
                if ((rb & (u32)$F0) == (u32)$40)
                    {
                    o.add((Object*)Number.withU32(rb | (u32)$08));
                    i = i + (u32)1;
                    haveRex = true;
                    }
                }
            if (!haveRex)
                {
                o.add((Object*)Number.withU32((u32)$48));
                if (_ripDispOffset >= (i32)0)
                    _ripDispOffset = _ripDispOffset + (i32)1;
                }
            for (; i < inner.count(); i = i + (u32)1)
                o.add(inner.get(i));
            _out = o;
            return _out;
            }

        _ops = new Array();
        Array* toks = splitOperandList(rest);
        for (u32 i = (u32)0; i < toks.count() && i < (u32)4; i = i + (u32)1)
            {
            XOperand* o = parseOperand((String*)toks.get(i));
            if (_failed)
                return (Array*)0;
            _ops.add((Object*)o);
            }
        XOperand* a = opAt((u32)0);
        XOperand* b = opAt((u32)1);

        // The operand size comes from a register operand, else a `ptr`
        // override, else eight.
        _osz = (u32)8;
        if (a != (XOperand*)0 && a.kind() == (u32)OP_REG)
            _osz = a.size();
        else if (b != (XOperand*)0 && b.kind() == (u32)OP_REG)
            _osz = b.size();
        else if (a != (XOperand*)0 && a.kind() == (u32)OP_MEM && a.size() != (u32)0)
            _osz = a.size();
        _w = _osz == (u32)8;

        // A segment override is the OUTERMOST prefix: it precedes the
        // operand-size 0x66 and the REX byte, so it goes out first and once.
        for (u32 i = (u32)0; i < _ops.count(); i = i + (u32)1)
            {
            XOperand* so = (XOperand*)_ops.get(i);
            if (so.kind() == (u32)OP_MEM && so.seg() != (u32)0)
                {
                e8(so.seg());
                i = _ops.count();
                }
            }

        // A 16-bit GPR operation takes the 0x66 operand-size prefix, and it must
        // come BEFORE any REX byte — so it is emitted here, once, ahead of every
        // path below. SSE mnemonics cannot be caught by this: their register
        // operands are xmm, which parse at size 16, so _osz is never 2 there.
        if (_osz == (u32)2)
            e8((u32)$66);

        // spl/bpl/sil/dil are numbers 4-7 in an 8-bit operand — the SAME numbers
        // that mean ah/ch/dh/bh without REX. A REX byte, even an all-zero one,
        // is what selects the low-byte forms, so if ANY operand is one of them
        // every path must emit it. Missing this turned `cmp dil, 1` into
        // `cmp bh, 1`: it assembled, it ran, and it compared the wrong register.
        _force8 = false;
        for (u32 i = (u32)0; i < _ops.count(); i = i + (u32)1)
            {
            XOperand* o = (XOperand*)_ops.get(i);
            if (o.kind() == (u32)OP_REG && o.forceRex())
                _force8 = true;
            }

        encGroupA(mn, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupB(mn, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupC(mn, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupD(mn, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;

        failWith(String.withCString("unhandled mnemonic"), mn);
        return (Array*)0;
        }

    static u32 firstSpace(String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t')
                return i;
            }
        return (u32)$FFFF_FFFF;
        }

    // Operands split on commas at bracket depth zero.
    static Array* splitOperandList(String* r)
        {
        Array* out = new Array();
        i32 depth = (i32)0;
        u32 st = (u32)0;
        for (u32 i = (u32)0; i < r.byteLength(); i = i + (u32)1)
            {
            u8 c = r.byteAt(i);
            if (c == (u8)'[')
                depth = depth + (i32)1;
            else if (c == (u8)']')
                depth = depth - (i32)1;
            else if (c == (u8)',' && depth == (i32)0)
                {
                out.add((Object*)r.substringBytes(st, i - st).trimmed());
                st = i + (u32)1;
                }
            }
        String* last = r.substringFromByte(st).trimmed();
        if (last.byteLength() > (u32)0)
            out.add((Object*)last);
        return out;
        }

    // ── Group A: the zero-operand forms, push/pop, the ALU group and mov ──
    void encGroupA(String* mn, XOperand* a, XOperand* b)
        {
        if (mn.equals(String.withCString("ret")))
            {
            e8((u32)$C3);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("leave")))
            {
            e8((u32)$C9);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("nop")))
            {
            e8((u32)$90);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("cdq")))
            {
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("cqo")))
            {
            e8((u32)$48);
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("syscall")))
            {
            e8((u32)$0F);
            e8((u32)$05);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("hlt")))
            {
            e8((u32)$F4);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("ud2")))
            {
            e8((u32)$0F);
            e8((u32)$0B);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("cwd")))
            {
            e8((u32)$66);
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("cdqe")))
            {
            e8((u32)$48);
            e8((u32)$98);
            _hit = true;
            return;
            }

        // ── atomics, fences and the bit-test group (private:docs/Design/threading.md) ──
        if (mn.equals(String.withCString("mfence")))
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$F0);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("lfence")))
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$E8);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("sfence")))
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$F8);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("pause")))
            {
            e8((u32)$F3);
            e8((u32)$90);
            _hit = true;
            return;
            }
            // bt / bts / btr / btc — r/m is the destination, the register or the
            // immediate selects the bit.
            {
            u32 btOp = (u32)0;
            u32 btExt = (u32)0;
            bool isBt = false;
            if (mn.equals(String.withCString("bt")))
                {
                btOp = (u32)$A3;
                btExt = (u32)4;
                isBt = true;
                }
            if (mn.equals(String.withCString("bts")))
                {
                btOp = (u32)$AB;
                btExt = (u32)5;
                isBt = true;
                }
            if (mn.equals(String.withCString("btr")))
                {
                btOp = (u32)$B3;
                btExt = (u32)6;
                isBt = true;
                }
            if (mn.equals(String.withCString("btc")))
                {
                btOp = (u32)$BB;
                btExt = (u32)7;
                isBt = true;
                }
            if (isBt && a != (XOperand*)0 && b != (XOperand*)0)
                {
                if (b.kind() == (u32)OP_REG)
                    {
                    eRex(_w, (i32)b.reg(), a.index(),
                         a.kind() == (u32)OP_REG ? (i32)a.reg() : a.base(), _force8);
                    e8((u32)$0F);
                    e8(btOp);
                    eModRM(b.reg(), a);
                    _hit = true;
                    return;
                    }
                if (b.kind() == (u32)OP_IMM && b.symbol() == (String*)0)
                    {
                    eRex(_w, (i32)0, a.index(),
                         a.kind() == (u32)OP_REG ? (i32)a.reg() : a.base(), _force8);
                    e8((u32)$0F);
                    e8((u32)$BA);
                    eModRM(btExt, a);
                    e8((u32)b.imm() & (u32)$FF);
                    _hit = true;
                    return;
                    }
                }
            }
        // xadd / cmpxchg / xchg — r/m is the destination, the register is `b`.
        if ((mn.equals(String.withCString("xadd")) || mn.equals(String.withCString("cmpxchg")) || mn.equals(String.withCString("xchg"))) && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == (u32)OP_REG)
            {
            eRex(_w, (i32)b.reg(), a.index(),
                 a.kind() == (u32)OP_REG ? (i32)a.reg() : a.base(), _force8);
            if (mn.equals(String.withCString("xchg")))
                {
                e8(_osz == (u32)1 ? (u32)$86 : (u32)$87);
                }
            else
                {
                e8((u32)$0F);
                u32 op = mn.equals(String.withCString("xadd")) ? (u32)$C1 : (u32)$B1;
                e8(_osz == (u32)1 ? op - (u32)1 : op);
                }
            eModRM(b.reg(), a);
            _hit = true;
            return;
            }

        bool isPush = mn.equals(String.withCString("push"));
        if ((isPush || mn.equals(String.withCString("pop"))) && a != (XOperand*)0 && a.kind() == (u32)OP_REG)
            {
            if ((a.reg() & (u32)8) != (u32)0)
                e8((u32)$41);
            e8((isPush ? (u32)$50 : (u32)$58) + (a.reg() & (u32)7));
            _hit = true;
            return;
            }

        i32 ext = aluExt(mn);
        if (ext >= (i32)0 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            if (b.kind() == (u32)OP_IMM && b.symbol() == (String*)0)
                {
                // There is no `and r64, imm64` — nor or/xor/add/sub/cmp. The
                // widest immediate any of them takes is an imm32, SIGN-EXTENDED
                // to 64 bits. A wider constant has no encoding at all, and
                // emitting the low half is not a smaller version of the right
                // answer: `x & 0xFF00FF00FF` became `x & 0x00FF00FF` and every
                // 64-bit AND lost its high word (bug 089). REFUSE it — the
                // caller's job is to stage the constant in a register first,
                // which is what the back end now does.
                if (_osz == (u32)8 && !fitsImm32(b))
                    {
                    failWith(String.withCString(
                                 "64-bit immediate does not fit an imm32 field — "
                                 "load it into a register first"),
                             mn);
                    return;
                    }
                bool imm8 = b.imm() >= (i32)-128 && b.imm() <= (i32)127;
                // The accumulator short form saves the ModRM byte, but only for a
                // full-width immediate — with an imm8 the `83 /ext ib` form is
                // shorter still, and clang always picks that, so matching keeps
                // the comparison byte-exact.
                if (a.kind() == (u32)OP_REG && a.reg() == (u32)0 && !imm8 && _osz != (u32)1)
                    {
                    eRex(_w, (i32)0, (i32)0, (i32)0, _force8);
                    e8((u32)ext * (u32)8 + (u32)$05);
                    eImmOsz(_osz, b.imm());
                    _hit = true;
                    return;
                    }
                eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
                if (_osz == (u32)1)
                    e8((u32)$80);
                else
                    e8(imm8 ? (u32)$83 : (u32)$81);
                eModRM((u32)ext, a);
                if (_osz == (u32)1 || imm8)
                    e8((u32)b.imm());
                else
                    eImmOsz(_osz, b.imm());
                _hit = true;
                return;
                }
            // r/m, r
            if (b.kind() == (u32)OP_REG)
                {
                eRex(_w, (i32)b.reg(), a.index(), a.rmReg(), _force8);
                e8((u32)ext * (u32)8 + (_osz == (u32)1 ? (u32)$00 : (u32)$01));
                eModRM(b.reg(), a);
                _hit = true;
                return;
                }
            // r, r/m
            if (a.kind() == (u32)OP_REG && b.kind() == (u32)OP_MEM)
                {
                eRex(_w, (i32)a.reg(), b.index(), b.base(), _force8);
                e8((u32)ext * (u32)8 + (_osz == (u32)1 ? (u32)$02 : (u32)$03));
                eModRM(a.reg(), b);
                _hit = true;
                return;
                }
            }

        if (mn.equals(String.withCString("mov")) && a != (XOperand*)0 && b != (XOperand*)0)
            {
            if (b.kind() == (u32)OP_IMM && b.symbol() == (String*)0)
                {
                // A 64-bit register taking a value that is NOT the sign-extension
                // of its low 32 bits needs movabs, which is ten bytes against
                // C7's seven. Getting this wrong does not fail: the instruction
                // is merely three bytes shorter, and every call displacement
                // after it in the section comes out wrong.
                if (a.kind() == (u32)OP_REG && _osz == (u32)8 && !fitsImm32(b))
                    {
                    eRex(true, (i32)0, (i32)0, (i32)a.reg(), false);
                    e8((u32)$B8 + (a.reg() & (u32)7));
                    e64((u32)b.imm(), b.immHi());
                    _hit = true;
                    return;
                    }
                // mov r8, imm8
                if (a.kind() == (u32)OP_REG && _osz == (u32)1)
                    {
                    eRex(false, (i32)0, (i32)0, (i32)a.reg(), _force8);
                    e8((u32)$B0 + (a.reg() & (u32)7));
                    e8((u32)b.imm());
                    _hit = true;
                    return;
                    }
                if (a.kind() == (u32)OP_REG && (_osz == (u32)2 || _osz == (u32)4))
                    {
                    eRex(false, (i32)0, (i32)0, (i32)a.reg(), _force8);
                    e8((u32)$B8 + (a.reg() & (u32)7));
                    eImmOsz(_osz, b.imm());
                    _hit = true;
                    return;
                    }
                // r64 falls through to C7 /0 with a sign-extended imm32 — B8+rd
                // under REX.W is `movabs` and would want eight immediate bytes.
                eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
                e8(_osz == (u32)1 ? (u32)$C6 : (u32)$C7);
                eModRM((u32)0, a);
                eImmOsz(_osz, b.imm());
                _hit = true;
                return;
                }
            // r/m, r
            if (b.kind() == (u32)OP_REG)
                {
                eRex(_w, (i32)b.reg(), a.index(), a.rmReg(), _force8);
                e8(_osz == (u32)1 ? (u32)$88 : (u32)$89);
                eModRM(b.reg(), a);
                _hit = true;
                return;
                }
            // r, r/m
            if (a.kind() == (u32)OP_REG && b.kind() == (u32)OP_MEM)
                {
                eRex(_w, (i32)a.reg(), b.index(), b.base(), _force8);
                e8(_osz == (u32)1 ? (u32)$8A : (u32)$8B);
                eModRM(a.reg(), b);
                _hit = true;
                return;
                }
            }

        if (mn.equals(String.withCString("lea")) && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == (u32)OP_REG && b.kind() == (u32)OP_MEM)
            {
            eRex(a.size() == (u32)8, (i32)a.reg(), b.index(), b.base(), _force8);
            e8((u32)$8D);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        }

    // True when the 64-bit value is exactly the sign-extension of its low half,
    // which is what an imm32 field can carry.
    static bool fitsImm32(XOperand* o)
        {
        bool negative = ((u32)o.imm() & (u32)$8000_0000) != (u32)0;
        return o.immHi() == (negative ? (u32)$FFFF_FFFF : (u32)0);
        }

    static i32 aluExt(String* m)
        {
        if (m.equals(String.withCString("add")))
            return (i32)0;
        if (m.equals(String.withCString("or")))
            return (i32)1;
        if (m.equals(String.withCString("adc")))
            return (i32)2;
        if (m.equals(String.withCString("sbb")))
            return (i32)3;
        if (m.equals(String.withCString("and")))
            return (i32)4;
        if (m.equals(String.withCString("sub")))
            return (i32)5;
        if (m.equals(String.withCString("xor")))
            return (i32)6;
        if (m.equals(String.withCString("cmp")))
            return (i32)7;
        return (i32)-1;
        }

    // ── Group B: extends, the unary group, inc/dec, test, setcc, shifts ──
    void encGroupB(String* mn, XOperand* a, XOperand* b)
        {
        if (mn.equals(String.withCString("movsxd")) && a != (XOperand*)0 && b != (XOperand*)0)
            {
            eRex(true, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$63);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        bool zx = mn.equals(String.withCString("movzx"));
        if ((zx || mn.equals(String.withCString("movsx"))) && a != (XOperand*)0 && b != (XOperand*)0)
            {
            u32 srcSize = b.kind() == (u32)OP_REG ? b.size()
                                                  : (b.size() != (u32)0 ? b.size() : (u32)1);
            // 0F B6/B7 and 0F BE/BF extend from a BYTE or a WORD only. A 32-bit
            // source is a different instruction (movsxd), and there is no movzx
            // from 32 at all because a plain 32-bit mov already zero-extends.
            // Left to the size arithmetic both silently encoded as extend-from-
            // byte: assembled fine, ran, and read one byte where four were meant.
            if (srcSize >= (u32)4)
                {
                fail(String.withCString("movzx/movsx cannot extend from a 4-byte source — use movsxd for 32->64, or a plain 32-bit mov to zero-extend"));
                return;
                }
            eRex(a.size() == (u32)8, (i32)a.reg(), b.index(), b.rmReg(), _force8);
            e8((u32)$0F);
            e8((zx ? (u32)$B6 : (u32)$BE) + (srcSize == (u32)2 ? (u32)1 : (u32)0));
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        i32 un = unaryExt(mn);
        if (un >= (i32)0 && a != (XOperand*)0 && _ops.count() == (u32)1)
            {
            eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
            e8(_osz == (u32)1 ? (u32)$F6 : (u32)$F7);
            eModRM((u32)un, a);
            _hit = true;
            return;
            }
        bool isInc = mn.equals(String.withCString("inc"));
        if ((isInc || mn.equals(String.withCString("dec"))) && a != (XOperand*)0 && _ops.count() == (u32)1)
            {
            eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
            e8(_osz == (u32)1 ? (u32)$FE : (u32)$FF);
            eModRM(isInc ? (u32)0 : (u32)1, a);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("test")) && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == (u32)OP_IMM && b.symbol() == (String*)0)
            {
            if (a.kind() == (u32)OP_REG && a.reg() == (u32)0 && !_force8)
                {
                eRex(_w, (i32)0, (i32)0, (i32)0, false);
                e8(_osz == (u32)1 ? (u32)$A8 : (u32)$A9);
                }
            else
                {
                eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
                e8(_osz == (u32)1 ? (u32)$F6 : (u32)$F7);
                eModRM((u32)0, a);
                }
            eImmOsz(_osz, b.imm());
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("test")) && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == (u32)OP_REG)
            {
            eRex(_w, (i32)b.reg(), a.index(), a.rmReg(), _force8);
            e8(_osz == (u32)1 ? (u32)$84 : (u32)$85);
            eModRM(b.reg(), a);
            _hit = true;
            return;
            }
        if (mn.hasPrefix(String.withCString("set")) && a != (XOperand*)0)
            {
            i32 cc = ccCode(mn.substringFromByte((u32)3));
            if (cc >= (i32)0)
                {
                eRex(false, (i32)0, a.index(), a.rmReg(), _force8);
                e8((u32)$0F);
                e8((u32)$90 + (u32)cc);
                eModRM((u32)0, a);
                _hit = true;
                return;
                }
            }
        i32 sh = shiftExt(mn);
        if (sh >= (i32)0 && a != (XOperand*)0)
            {
            eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
            // no count = by 1
            if (b == (XOperand*)0)
                {
                e8(_osz == (u32)1 ? (u32)$D0 : (u32)$D1);
                eModRM((u32)sh, a);
                }
            // by cl
            else if (b.kind() == (u32)OP_REG)
                {
                e8(_osz == (u32)1 ? (u32)$D2 : (u32)$D3);
                eModRM((u32)sh, a);
                }
            // by 1, short form
            else if (b.imm() == (i32)1)
                {
                e8(_osz == (u32)1 ? (u32)$D0 : (u32)$D1);
                eModRM((u32)sh, a);
                }
            else
                {
                e8(_osz == (u32)1 ? (u32)$C0 : (u32)$C1);
                eModRM((u32)sh, a);
                e8((u32)b.imm());
                }
            _hit = true;
            return;
            }
        }

    static i32 unaryExt(String* m)
        {
        if (m.equals(String.withCString("not")))
            return (i32)2;
        if (m.equals(String.withCString("neg")))
            return (i32)3;
        if (m.equals(String.withCString("mul")))
            return (i32)4;
        if (m.equals(String.withCString("imul")))
            return (i32)5;
        if (m.equals(String.withCString("div")))
            return (i32)6;
        if (m.equals(String.withCString("idiv")))
            return (i32)7;
        return (i32)-1;
        }

    static i32 shiftExt(String* m)
        {
        if (m.equals(String.withCString("rol")))
            return (i32)0;
        if (m.equals(String.withCString("ror")))
            return (i32)1;
        if (m.equals(String.withCString("shl")) || m.equals(String.withCString("sal")))
            return (i32)4;
        if (m.equals(String.withCString("shr")))
            return (i32)5;
        if (m.equals(String.withCString("sar")))
            return (i32)7;
        return (i32)-1;
        }

    // ── Group C: imul forms, movabs, branches, cmovcc ────────────────────
    void encGroupC(String* mn, XOperand* a, XOperand* b)
        {
        if (mn.equals(String.withCString("imul")) && a != (XOperand*)0 && b != (XOperand*)0 && _ops.count() == (u32)2 && a.kind() == (u32)OP_REG)
            {
            eRex(_w, (i32)a.reg(), b.index(), b.rmReg(), _force8);
            e8((u32)$0F);
            e8((u32)$AF);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("imul")) && _ops.count() == (u32)3 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            i32 iv = ((XOperand*)_ops.get((u32)2)).imm();
            bool imm8 = iv >= (i32)-128 && iv <= (i32)127;
            eRex(_w, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8(imm8 ? (u32)$6B : (u32)$69);
            eModRM(a.reg(), b);
            if (imm8)
                e8((u32)iv);
            else
                e32((u32)iv);
            _hit = true;
            return;
            }
        if (mn.equals(String.withCString("movabs")) && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == (u32)OP_REG)
            {
            eRex(true, (i32)0, (i32)0, (i32)a.reg(), false);
            e8((u32)$B8 + (a.reg() & (u32)7));
            e64((u32)b.imm(), b.immHi());
            _hit = true;
            return;
            }
        bool isCall = mn.equals(String.withCString("call"));
        if ((isCall || mn.equals(String.withCString("jmp"))) && a != (XOperand*)0)
            {
            // indirect
            if (a.kind() == (u32)OP_REG || a.kind() == (u32)OP_MEM)
                {
                eRex(false, (i32)0, a.index(), a.rmReg(), _force8);
                e8((u32)$FF);
                eModRM(isCall ? (u32)2 : (u32)4, a);
                _hit = true;
                return;
                }
            e8(isCall ? (u32)$E8 : (u32)$E9);
            recordRel32(a.symbol(), _out.count());
            e32((u32)0);
            _hit = true;
            return;
            }
        if (mn.hasPrefix(String.withCString("j")) && a != (XOperand*)0)
            {
            i32 cc = ccCode(mn.substringFromByte((u32)1));
            if (cc >= (i32)0)
                {
                e8((u32)$0F);
                e8((u32)$80 + (u32)cc);
                recordRel32(a.symbol(), _out.count());
                e32((u32)0);
                _hit = true;
                return;
                }
            }
        if (mn.hasPrefix(String.withCString("cmov")) && a != (XOperand*)0 && b != (XOperand*)0)
            {
            i32 cc = ccCode(mn.substringFromByte((u32)4));
            if (cc >= (i32)0)
                {
                eRex(_w, (i32)a.reg(), b.index(), b.rmReg(), false);
                e8((u32)$0F);
                e8((u32)$40 + (u32)cc);
                eModRM(a.reg(), b);
                _hit = true;
                return;
                }
            }
        }

    // ── Group D: SSE/SSE2 — scalar float and the vectoriser's packed forms ──
    //
    // The encoding is [mandatory prefix F3/F2/66][REX][0F][opcode][ModRM], and
    // the prefix comes BEFORE the REX byte. The destination is the ModRM.reg
    // field, the source the r/m.
    void encGroupD(String* mn, XOperand* a, XOperand* b)
        {
        u32 rr = sseRR(mn);
        if (rr != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0)
            {
            u32 pfx = rr >> (u32)8;
            if (pfx != (u32)0)
                e8(pfx);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8(rr & (u32)$FF);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        u32 t3 = sse38(mn);
        if (t3 != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0)
            {
            e8(t3 >> (u32)8);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$38);
            e8(t3 & (u32)$FF);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        u32 si = sseShiftI(mn);
        if (si != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == (u32)OP_REG && b.kind() == (u32)OP_IMM)
            {
            e8((u32)$66);
            eRex(false, (i32)0, (i32)-1, (i32)a.reg(), false);
            e8((u32)$0F);
            e8(si >> (u32)8);
            e8((u32)$C0 | ((si & (u32)7) << (u32)3) | (a.reg() & (u32)7));
            e8((u32)b.imm() & (u32)$FF);
            _hit = true;
            return;
            }
        // shufps/shufpd xmm, xmm/m, imm8 — reg/rm plus a trailing selector.
        if ((mn.equals(String.withCString("shufps")) || mn.equals(String.withCString("shufpd"))) && a != (XOperand*)0 && b != (XOperand*)0 && opAt((u32)2) != (XOperand*)0 && opAt((u32)2).kind() == (u32)OP_IMM)
            {
            if (mn.equals(String.withCString("shufpd")))
                e8((u32)$66);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$C6);
            eModRM(a.reg(), b);
            e8((u32)opAt((u32)2).imm() & (u32)$FF);
            _hit = true;
            return;
            }
        // movss/movsd/movdqu/movdqa — the direction picks load or store.
        u32 mv = sseMov(mn);
        if (mv != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0)
            {
            u32 pfx = (mv >> (u32)16) & (u32)$FF;
            bool store = a.kind() == (u32)OP_MEM;
            XOperand* rmOp = store ? a : b;
            u32 regField = store ? b.reg() : a.reg();
            if (pfx != (u32)0)
                e8(pfx);
            eRex(false, (i32)regField, rmOp.index(), rmOp.rmReg(), false);
            e8((u32)$0F);
            e8(store ? (mv & (u32)$FF) : ((mv >> (u32)8) & (u32)$FF));
            eModRM(regField, rmOp);
            _hit = true;
            return;
            }
        // cvtsi2ss/sd (xmm from GP) and cvttss2si/cvttsd2si (GP from xmm):
        // REX.W follows the GP operand's width and sits AFTER the prefix.
        u32 cv = sseCvt(mn);
        if (cv != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0)
            {
            bool gpIsSrc = ((cv >> (u32)16) & (u32)1) != (u32)0;
            XOperand* gp = gpIsSrc ? b : a;
            e8((cv >> (u32)8) & (u32)$FF);
            eRex(gp.size() == (u32)8, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8(cv & (u32)$FF);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        u32 shp = sseShuf(mn);
        if (shp != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0 && _ops.count() == (u32)3)
            {
            e8(shp);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$70);
            eModRM(a.reg(), b);
            e8((u32)((XOperand*)_ops.get((u32)2)).imm());
            _hit = true;
            return;
            }
        // pmulld — a three-byte opcode.
        if (mn.equals(String.withCString("pmulld")) && a != (XOperand*)0 && b != (XOperand*)0)
            {
            e8((u32)$66);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$38);
            e8((u32)$40);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        // movd/movq between an xmm and a GP register or memory.
        bool isMovd = mn.equals(String.withCString("movd"));
        if ((isMovd || mn.equals(String.withCString("movq"))) && a != (XOperand*)0 && b != (XOperand*)0 && (a.size() == (u32)16 || b.size() == (u32)16))
            {
            bool toXmm = a.size() == (u32)16;
            XOperand* xmm = toXmm ? a : b;
            XOperand* other = toXmm ? b : a;
            e8((u32)$66);
            eRex(!isMovd, (i32)xmm.reg(), other.index(), other.rmReg(), false);
            e8((u32)$0F);
            e8(toXmm ? (u32)$6E : (u32)$7E);
            eModRM(xmm.reg(), other);
            _hit = true;
            return;
            }
        // The SSE compares spell their predicate in the mnemonic and encode it
        // as the trailing imm8.
        if (mn.hasPrefix(String.withCString("cmp")) && mn.byteLength() > (u32)5 && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == (u32)OP_REG && a.size() == (u32)16)
            {
            String* tail = mn.substringFromByte(mn.byteLength() - (u32)2);
            i32 pfx = cmpSuffix(tail);
            if (pfx >= (i32)0)
                {
                i32 pv = cmpPredicate(mn.substringBytes((u32)3, mn.byteLength() - (u32)5));
                if (pv >= (i32)0)
                    {
                    if (pfx != (i32)0)
                        e8((u32)pfx);
                    eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
                    e8((u32)$0F);
                    e8((u32)$C2);
                    eModRM(a.reg(), b);
                    e8((u32)pv);
                    _hit = true;
                    return;
                    }
                }
            }
        }

    // Packed as (prefix << 8) | opcode; $FFFF_FFFF means "not in this table".
    static u32 sseRR(String* m)
        {
        if (m.equals(String.withCString("addss")))
            return (u32)$F358;
        if (m.equals(String.withCString("addsd")))
            return (u32)$F258;
        if (m.equals(String.withCString("subss")))
            return (u32)$F35C;
        if (m.equals(String.withCString("subsd")))
            return (u32)$F25C;
        if (m.equals(String.withCString("subpd")))
            return (u32)$665C;
        if (m.equals(String.withCString("subps")))
            return (u32)$005C;
        if (m.equals(String.withCString("addpd")))
            return (u32)$6658;
        if (m.equals(String.withCString("addps")))
            return (u32)$0058;
        if (m.equals(String.withCString("mulpd")))
            return (u32)$6659;
        if (m.equals(String.withCString("mulps")))
            return (u32)$0059;
        if (m.equals(String.withCString("divpd")))
            return (u32)$665E;
        if (m.equals(String.withCString("divps")))
            return (u32)$005E;
        if (m.equals(String.withCString("mulss")))
            return (u32)$F359;
        if (m.equals(String.withCString("mulsd")))
            return (u32)$F259;
        if (m.equals(String.withCString("divss")))
            return (u32)$F35E;
        if (m.equals(String.withCString("divsd")))
            return (u32)$F25E;
        if (m.equals(String.withCString("sqrtss")))
            return (u32)$F351;
        if (m.equals(String.withCString("sqrtsd")))
            return (u32)$F251;
        if (m.equals(String.withCString("ucomiss")))
            return (u32)$002E;
        if (m.equals(String.withCString("ucomisd")))
            return (u32)$662E;
        if (m.equals(String.withCString("comiss")))
            return (u32)$002F;
        if (m.equals(String.withCString("comisd")))
            return (u32)$662F;
        if (m.equals(String.withCString("cvtss2sd")))
            return (u32)$F35A;
        if (m.equals(String.withCString("cvtsd2ss")))
            return (u32)$F25A;
        if (m.equals(String.withCString("xorps")))
            return (u32)$0057;
        if (m.equals(String.withCString("xorpd")))
            return (u32)$6657;
        if (m.equals(String.withCString("andps")))
            return (u32)$0054;
        if (m.equals(String.withCString("andpd")))
            return (u32)$6654;
        if (m.equals(String.withCString("andnps")))
            return (u32)$0055;
        if (m.equals(String.withCString("andnpd")))
            return (u32)$6655;
        if (m.equals(String.withCString("orps")))
            return (u32)$0056;
        if (m.equals(String.withCString("orpd")))
            return (u32)$6656;
        if (m.equals(String.withCString("unpcklpd")))
            return (u32)$6614;
        if (m.equals(String.withCString("unpcklps")))
            return (u32)$0014;
        if (m.equals(String.withCString("unpckhpd")))
            return (u32)$6615;
        if (m.equals(String.withCString("unpckhps")))
            return (u32)$0015;
        if (m.equals(String.withCString("paddd")))
            return (u32)$66FE;
        if (m.equals(String.withCString("paddw")))
            return (u32)$66FD;
        if (m.equals(String.withCString("paddb")))
            return (u32)$66FC;
        if (m.equals(String.withCString("paddq")))
            return (u32)$66D4;
        if (m.equals(String.withCString("psubd")))
            return (u32)$66FA;
        if (m.equals(String.withCString("psubw")))
            return (u32)$66F9;
        if (m.equals(String.withCString("maxsd")))
            return (u32)$F25F;
        if (m.equals(String.withCString("maxss")))
            return (u32)$F35F;
        if (m.equals(String.withCString("minsd")))
            return (u32)$F25D;
        if (m.equals(String.withCString("minss")))
            return (u32)$F35D;
        if (m.equals(String.withCString("maxpd")))
            return (u32)$665F;
        if (m.equals(String.withCString("maxps")))
            return (u32)$005F;
        if (m.equals(String.withCString("minpd")))
            return (u32)$665D;
        if (m.equals(String.withCString("minps")))
            return (u32)$005D;
        if (m.equals(String.withCString("cvttpd2dq")))
            return (u32)$66E6;
        if (m.equals(String.withCString("cvtdq2pd")))
            return (u32)$F3E6;
        if (m.equals(String.withCString("cvttps2dq")))
            return (u32)$F35B;
        if (m.equals(String.withCString("cvtdq2ps")))
            return (u32)$005B;
        if (m.equals(String.withCString("cvtps2pd")))
            return (u32)$005A;
        if (m.equals(String.withCString("cvtpd2ps")))
            return (u32)$665A;
        if (m.equals(String.withCString("punpckldq")))
            return (u32)$6662;
        if (m.equals(String.withCString("punpcklqdq")))
            return (u32)$666C;
        if (m.equals(String.withCString("pand")))
            return (u32)$66DB;
        if (m.equals(String.withCString("por")))
            return (u32)$66EB;
        if (m.equals(String.withCString("pxor")))
            return (u32)$66EF;
        if (m.equals(String.withCString("psrld")))
            return (u32)$66D2;
        if (m.equals(String.withCString("pslld")))
            return (u32)$66F2;
        if (m.equals(String.withCString("psrlq")))
            return (u32)$66D3;
        if (m.equals(String.withCString("psllq")))
            return (u32)$66F3;
        // The vectoriser's widening-sum / dot-product reductions reach these;
        // absent until bug 029.
        if (m.equals(String.withCString("pcmpeqd")))
            return (u32)$6676;
        if (m.equals(String.withCString("pcmpgtd")))
            return (u32)$6666;
        // The BYTE and WORD lane widths of the same two compares. Only the
        // dword forms existed, so the back end emitted a dword compare for
        // byte lanes and string_scan counted zero matches instead of 64
        // (bug 223).
        if (m.equals(String.withCString("pcmpeqb")))
            return (u32)$6674;
        if (m.equals(String.withCString("pcmpgtb")))
            return (u32)$6664;
        if (m.equals(String.withCString("pcmpeqw")))
            return (u32)$6675;
        if (m.equals(String.withCString("pcmpgtw")))
            return (u32)$6665;
        if (m.equals(String.withCString("pmaddwd")))
            return (u32)$66F5;
        if (m.equals(String.withCString("punpcklbw")))
            return (u32)$6660;
        // The i16 multiply a widening product lowers to (vectorize_dot,
        // vectorize_widen_tail).
        if (m.equals(String.withCString("pmullw")))
            return (u32)$66D5;
        return (u32)$FFFF_FFFF;
        }

    // SSSE3 three-byte opcodes: [66][REX][0F][38][op][ModRM]. Same operand
    // shape as sseRR with one more opcode byte.
    static u32 sse38(String* m)
        {
        if (m.equals(String.withCString("pabsb")))
            return (u32)$661C;
        if (m.equals(String.withCString("pabsw")))
            return (u32)$661D;
        if (m.equals(String.withCString("pabsd")))
            return (u32)$661E;
        if (m.equals(String.withCString("phaddw")))
            return (u32)$6601;
        if (m.equals(String.withCString("phaddd")))
            return (u32)$6602;
        if (m.equals(String.withCString("pmaddubsw")))
            return (u32)$6604;
        // SSE4.1: the signed i32 lane max/min, which is what a `max` reduction
        // over i32 lowers to (vectorize_maxmin).
        if (m.equals(String.withCString("pmaxsd")))
            return (u32)$663D;
        if (m.equals(String.withCString("pminsd")))
            return (u32)$6639;
        return (u32)$FFFF_FFFF;
        }

    // Shift a vector by an IMMEDIATE: [66][REX][0F][op][ModRM /ext][ib]. The
    // shifted register goes in r/m and the opcode extension in reg — the
    // reverse of every other form here, so it cannot share their table.
    // Packed as (opcode << 8) | ext.
    static u32 sseShiftI(String* m)
        {
        if (m.equals(String.withCString("psrlw")))
            return (u32)$7102;
        if (m.equals(String.withCString("psraw")))
            return (u32)$7104;
        if (m.equals(String.withCString("psllw")))
            return (u32)$7106;
        if (m.equals(String.withCString("psrldi")))
            return (u32)$7202;
        return (u32)$FFFF_FFFF;
        }

    // Packed as (prefix << 16) | (loadOp << 8) | storeOp.
    static u32 sseMov(String* m)
        {
        if (m.equals(String.withCString("movss")))
            return (u32)$F31011;
        if (m.equals(String.withCString("movsd")))
            return (u32)$F21011;
        if (m.equals(String.withCString("movups")))
            return (u32)$001011;
        if (m.equals(String.withCString("movaps")))
            return (u32)$002829;
        if (m.equals(String.withCString("movdqu")))
            return (u32)$F36F7F;
        if (m.equals(String.withCString("movdqa")))
            return (u32)$666F7F;
        if (m.equals(String.withCString("movupd")))
            return (u32)$661011;
        if (m.equals(String.withCString("movapd")))
            return (u32)$662829;
        return (u32)$FFFF_FFFF;
        }

    // Packed as (gpIsSrc << 16) | (prefix << 8) | opcode.
    static u32 sseCvt(String* m)
        {
        if (m.equals(String.withCString("cvtsi2ss")))
            return (u32)$01F32A;
        if (m.equals(String.withCString("cvtsi2sd")))
            return (u32)$01F22A;
        if (m.equals(String.withCString("cvttss2si")))
            return (u32)$00F32C;
        if (m.equals(String.withCString("cvttsd2si")))
            return (u32)$00F22C;
        if (m.equals(String.withCString("cvtss2si")))
            return (u32)$00F32D;
        if (m.equals(String.withCString("cvtsd2si")))
            return (u32)$00F22D;
        return (u32)$FFFF_FFFF;
        }

    static u32 sseShuf(String* m)
        {
        if (m.equals(String.withCString("pshufd")))
            return (u32)$66;
        if (m.equals(String.withCString("pshuflw")))
            return (u32)$F2;
        if (m.equals(String.withCString("pshufhw")))
            return (u32)$F3;
        return (u32)$FFFF_FFFF;
        }

    static i32 cmpSuffix(String* t)
        {
        if (t.equals(String.withCString("sd")))
            return (i32)$F2;
        if (t.equals(String.withCString("ss")))
            return (i32)$F3;
        if (t.equals(String.withCString("pd")))
            return (i32)$66;
        if (t.equals(String.withCString("ps")))
            return (i32)$00;
        return (i32)-1;
        }

    static i32 cmpPredicate(String* p)
        {
        if (p.equals(String.withCString("eq")))
            return (i32)0;
        if (p.equals(String.withCString("lt")))
            return (i32)1;
        if (p.equals(String.withCString("le")))
            return (i32)2;
        if (p.equals(String.withCString("unord")))
            return (i32)3;
        if (p.equals(String.withCString("neq")))
            return (i32)4;
        if (p.equals(String.withCString("nlt")))
            return (i32)5;
        if (p.equals(String.withCString("nle")))
            return (i32)6;
        if (p.equals(String.withCString("ord")))
            return (i32)7;
        return (i32)-1;
        }

    // ── Whole-file assembly ──────────────────────────────────────────────
    //
    // Strip a `#` or `//` comment, honouring double quotes so a `#` inside a
    // string survives. The back end emits `#`; clang's own output uses both.
    static String* stripAsmComment(String* l)
        {
        bool inq = false;
        for (u32 i = (u32)0; i < l.byteLength(); i = i + (u32)1)
            {
            u8 c = l.byteAt(i);
            if (c == (u8)'"')
                {
                inq = !inq;
                continue;
                }
            if (inq)
                continue;
            if (c == (u8)'#')
                return l.substringBytes((u32)0, i);
            if (c == (u8)'/' && i + (u32)1 < l.byteLength() && l.byteAt(i + (u32)1) == (u8)'/')
                return l.substringBytes((u32)0, i);
            }
        return l;
        }

    // A directive's operands, split on top-level commas with quotes respected.
    static Array* splitDirectiveOps(String* rest)
        {
        Array* out = new Array();
        bool inq = false;
        u32 st = (u32)0;
        for (u32 i = (u32)0; i < rest.byteLength(); i = i + (u32)1)
            {
            u8 c = rest.byteAt(i);
            if (c == (u8)'"')
                inq = !inq;
            else if (c == (u8)',' && !inq)
                {
                String* t = rest.substringBytes(st, i - st).trimmed();
                if (t.byteLength() > (u32)0)
                    out.add((Object*)t);
                st = i + (u32)1;
                }
            }
        String* t = rest.substringFromByte(st).trimmed();
        if (t.byteLength() > (u32)0)
            out.add((Object*)t);
        return out;
        }

    // A `.quad` operand naming a symbol rather than a number — a vtable slot,
    // say. It becomes eight zero bytes and an absolute-64 fixup.
    bool isSymbolOperand(String* t)
        {
        if (t.byteLength() == (u32)0)
            return false;
        parseNum(t);
        if (_numOk)
            return false;
        u8 c = t.byteAt((u32)0);
        return c == (u8)'_' || c == (u8)'.' || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z');
        }

    void assemble(String* source)
        {
        u32 section = (u32)0; // 0 = text, 1 = data
        Array* lines = source.splitOnByte((u8)'\n');
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1)
            {
            String* l = stripAsmComment((String*)lines.get(li)).trimmed();
            if (l.byteLength() == (u32)0)
                continue;

            // Only a section change ends a debug-section skip; everything else
            // in there is debug payload, labels included.
            if (_skipSect)
                {
                if (!(l.hasPrefix(String.withCString(".section")) || l.hasPrefix(String.withCString(".text")) || l.hasPrefix(String.withCString(".data")) || l.hasPrefix(String.withCString(".bss"))))
                    continue;
                _skipSect = false;
                }

            if (l.hasPrefix(String.withCString(".")) && !l.hasSuffix(String.withCString(":")))
                {
                section = handleDirective(l, section);
                if (_failed)
                    return;
                continue;
                }
            if (l.hasSuffix(String.withCString(":")))
                {
                String* lbl = l.substringBytes((u32)0, l.byteLength() - (u32)1);
                // Letting a redefinition win produced code that assembled,
                // linked and jumped into the wrong function: two
                // clang-generated runtime files both used `.LBB0_1`, and every
                // branch in the first landed in the second. Whoever
                // concatenated them has to fix it.
                if (_symbols.get((Hashable*)lbl) != (Object*)0)
                    {
                    failWith(String.withCString("symbol defined twice — if this is a concatenation of separately compiled files, their local labels need namespacing"), lbl);
                    return;
                    }
                if (section == (u32)0)
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(_text.count()));
                else
                    {
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(_data.count()));
                    _dataSyms.add((Object*)lbl);
                    }
                continue;
                }
            // `name = expr` — the OTHER spelling of `.set name, expr`, which
            // clang emits for the COFF feature symbol (`@feat.00 = 0`). An
            // unknown directive carries no bytes and defines no symbol, so
            // `.set` is already ignored; this spelling must be ignored
            // identically or the two disagree. It reached the mnemonic path
            // instead, where `@feat.00` read as an opcode — and since a link
            // failure counts as an ORACLE failure, ldwin-diff went to 0
            // compared / 785 skipped while still printing `ok`.
            //
            // Only a plain integer is safe to drop; a symbol ALIAS (`a = b`)
            // needs a real definition, and discarding one would mis-link
            // rather than fail.
            u32 eqAt = indexOfChar(l, (u8)'=');
            if (eqAt != (u32)$FFFF_FFFF)
                {
                String* nm = l.substringBytes((u32)0, eqAt).trimmed();
                String* rv = l.substringFromByte(eqAt + (u32)1).trimmed();
                if (nm.byteLength() > (u32)0 && isPlainIntLiteral(rv))
                    continue;
                failWith(String.withCString("symbol assignment is not a plain integer — an alias needs a real definition"), l);
                return;
                }

            if (section != (u32)0)
                {
                failWith(String.withCString("unexpected line in the data section"), l);
                return;
                }
            _insnBase = _text.count();
            Array* bytes = encodeOne(l);
            if (bytes == (Array*)0)
                {
                String* m = String.withCString("line '");
                m.append(l);
                m.appendCString("': ");
                if (_why != (String*)0)
                    m.append(_why);
                _failed = false;
                fail(m);
                return;
                }
            for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
                _text.add(bytes.get(i));
            }
        resolveLocalBranches();
        }

    u32 handleDirective(String* l, u32 section)
        {
        u32 sp = firstSpace(l);
        String* d = sp == (u32)$FFFF_FFFF ? l : l.substringBytes((u32)0, sp);
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                             : l.substringFromByte(sp).trimmed();
        if (d.equals(String.withCString(".text")))
            return (u32)0;
        if (d.equals(String.withCString(".data")) || d.equals(String.withCString(".bss")))
            return (u32)1;
        if (d.equals(String.withCString(".section")))
            {
            // CodeView debug sections carry nothing the image needs, and their
            // contents use label ARITHMETIC (`.long .Ltmp1-.Ltmp0`) that this
            // assembler has no expression evaluator for. An unrecognised
            // section used to fall through to data, so every CodeView byte was
            // appended to __data.
            if (rest.hasPrefix(String.withCString(".debug")))
                {
                _skipSect = true;
                return section;
                }
            return rest.hasPrefix(String.withCString(".text")) ? (u32)0 : (u32)1;
            }
        if (d.equals(String.withCString(".globl")) || d.equals(String.withCString(".global")))
            {
            // Carries no bytes, but names what a shared object exports.
            Array* ns = splitDirectiveOps(rest);
            for (u32 i = (u32)0; i < ns.count(); i = i + (u32)1)
                _globalSyms.add(ns.get(i));
            return section;
            }
        if (d.equals(String.withCString(".comm")) || d.equals(String.withCString(".lcomm")))
            {
            // `.comm name, size, align` — a COMMON (C tentative def): recorded as
            // external-undefined-with-size so the LINKER gives ONE slot every unit
            // binds to. `.lcomm` is the LOCAL form (private storage, materialised
            // here). A single-unit image demotes its commons before the write.
            Array* cops = splitDirectiveOps(rest);
            if (cops.count() < (u32)2)
                return section;
            i32 sz = parseNum((String*)cops.get((u32)1));
            i32 alg = (i32)0;
            if (cops.count() > (u32)2)
                {
                i32 g = parseNum((String*)cops.get((u32)2));
                if (_numOk)
                    alg = g;
                }
            String* nm = (String*)cops.get((u32)0);
            if (d.equals(String.withCString(".comm")))
                {
                Array* info = new Array();
                info.add((Object*)Number.withU32((u32)sz));
                info.add((Object*)Number.withU32(alg > (i32)0 ? (u32)alg : (u32)1));
                _commonSyms.set((Hashable*)nm, (Object*)info);
                return section;
                }
            if (alg > (i32)1)
                while (_data.count() % (u32)alg != (u32)0)
                    _data.add((Object*)Number.withU32((u32)0));
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_data.count()));
            _dataSyms.add((Object*)nm);
            for (i32 i = (i32)0; i < sz; i = i + (i32)1)
                _data.add((Object*)Number.withU32((u32)0));
            return section;
            }
        // Debug and type annotations carry no bytes at all.
        if (d.equals(String.withCString(".type")) || d.equals(String.withCString(".size")) || d.equals(String.withCString(".intel_syntax")) || d.equals(String.withCString(".file")) || d.equals(String.withCString(".ident")) || d.equals(String.withCString(".local")))
            return section;

        if (d.equals(String.withCString(".p2align")) || d.equals(String.withCString(".align")))
            {
            Array* ao = splitDirectiveOps(rest);
            i32 n = ao.count() > (u32)0 ? parseNum((String*)ao.get((u32)0)) : (i32)0;
            u32 al = (u32)1 << (u32)n;
            // Code pads with NOPs, data with zeros.
            if (section == (u32)0)
                while (_text.count() % al != (u32)0)
                    _text.add((Object*)Number.withU32((u32)$90));
            else
                while (_data.count() % al != (u32)0)
                    _data.add((Object*)Number.withU32((u32)0));
            return section;
            }

        return handleDataDirective(d, rest, l, section);
        }

    // Split out purely for the arm64 frame budget: a chain of literal
    // comparisons builds more temporaries than one frame can hold.
    u32 handleDataDirective(String* d, String* rest, String* l, u32 section)
        {
        Array* sec = section == (u32)0 ? _text : _data;
        Array* ops = splitDirectiveOps(rest);
        if (d.equals(String.withCString(".zero")) || d.equals(String.withCString(".space")))
            {
            i32 n = ops.count() > (u32)0 ? parseNum((String*)ops.get((u32)0)) : (i32)0;
            i32 fill = (i32)0;
            if (ops.count() > (u32)1)
                {
                i32 f = parseNum((String*)ops.get((u32)1));
                if (_numOk)
                    fill = f;
                }
            for (i32 i = (i32)0; i < n; i = i + (i32)1)
                sec.add((Object*)Number.withU32((u32)fill & (u32)$FF));
            return section;
            }
        if (d.equals(String.withCString(".ascii")) || d.equals(String.withCString(".asciz")) || d.equals(String.withCString(".string")))
            {
            u32 q1 = rest.byteIndexOf(String.withCString("\""));
            u32 q2 = lastQuote(rest);
            if (q1 == (u32)$FFFF_FFFF || q2 <= q1)
                {
                failWith(String.withCString("bad string in"), l);
                return section;
                }
            String* str = rest.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
            u32 i = (u32)0;
            while (i < str.byteLength())
                {
                u8 c = str.byteAt(i);
                if (c == (u8)'\\' && i + (u32)1 < str.byteLength())
                    {
                    i = i + (u32)1;
                    u8 n = str.byteAt(i);
                    if (n == (u8)'n')
                        c = (u8)10;
                    else if (n == (u8)'t')
                        c = (u8)9;
                    else if (n == (u8)'r')
                        c = (u8)13;
                    else if (n == (u8)'0')
                        c = (u8)0;
                    else
                        c = n;
                    }
                sec.add((Object*)Number.withU32((u32)c));
                i = i + (u32)1;
                }
            if (!d.equals(String.withCString(".ascii")))
                sec.add((Object*)Number.withU32((u32)0));
            return section;
            }
        u32 width = dataWidth(d);
        if (width == (u32)0)
            return section; // unknown directive: no bytes
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            String* t = (String*)ops.get(i);
            if (width == (u32)8 && isSymbolOperand(t))
                {
                // The writer tells a data fixup from a text one by KIND alone,
                // so a symbolic .quad in the text section would have its offset
                // read against the wrong section and patch a random address.
                // The back end only ever emits these in .rodata; say so rather
                // than corrupt silently if that ever changes.
                if (section == (u32)0)
                    {
                    failWith(String.withCString("a symbolic .quad is only supported in data"), l);
                    return section;
                    }
                _fixups.add((Object*)X86Fixup.make(sec.count(), (u32)X86FIX_ABS64, t, (i32)0));
                for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
                    sec.add((Object*)Number.withU32((u32)0));
                continue;
                }
            i32 v = parseNum(t);
            if (!_numOk)
                {
                failWith(String.withCString("bad data value"), t);
                return section;
                }
            u32 hi = _numHi;
            for (u32 k = (u32)0; k < width; k = k + (u32)1)
                {
                u32 byte = k < (u32)4 ? (((u32)v >> ((u32)8 * k)) & (u32)$FF)
                                      : ((hi >> ((u32)8 * (k - (u32)4))) & (u32)$FF);
                sec.add((Object*)Number.withU32(byte));
                }
            }
        return section;
        }

    static u32 dataWidth(String* d)
        {
        if (d.equals(String.withCString(".byte")))
            return (u32)1;
        if (d.equals(String.withCString(".short")) || d.equals(String.withCString(".hword")) || d.equals(String.withCString(".2byte")))
            return (u32)2;
        if (d.equals(String.withCString(".long")) || d.equals(String.withCString(".word")) || d.equals(String.withCString(".4byte")))
            return (u32)4;
        if (d.equals(String.withCString(".quad")) || d.equals(String.withCString(".8byte")))
            return (u32)8;
        return (u32)0;
        }

    static u32 indexOfChar(String* s, u8 c)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == c)
                return i;
        return (u32)$FFFF_FFFF;
        }

    // The right-hand side of a `name = expr` symbol assignment, restricted to a
    // plain integer literal. Deliberately NOT parseNum: the reference assembler
    // must make the identical accept/reject call (XAX86_64Assembler.m), and one
    // spelled-out rule is easier to hold in step than two number parsers.
    static bool isPlainIntLiteral(String* s)
        {
        if (s.byteLength() == (u32)0)
            return false;
        u32 i = (u32)0;
        u8 c0 = s.byteAt((u32)0);
        if (c0 == (u8)'+' || c0 == (u8)'-')
            i = (u32)1;
        bool hex = false;
        if (s.byteLength() > i + (u32)1 && s.byteAt(i) == (u8)'0')
            {
            u8 x = s.byteAt(i + (u32)1);
            if (x == (u8)'x' || x == (u8)'X')
                hex = true;
            }
        if (hex)
            i = i + (u32)2;
        if (i >= s.byteLength())
            return false;
        for (; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            bool dig = c >= (u8)'0' && c <= (u8)'9';
            bool hd = hex && ((c >= (u8)'a' && c <= (u8)'f') || (c >= (u8)'A' && c <= (u8)'F'));
            if (!dig && !hd)
                return false;
            }
        return true;
        }

    static u32 lastQuote(String* s)
        {
        u32 f = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == (u8)'"')
                f = i;
        return f;
        }

    // A call or jcc to a label in this same text needs no relocation, so it is
    // resolved here rather than left for every consumer to re-derive.
    // Everything else — data references, imports, .quad pointers — needs final
    // addresses and stays a fixup.
    void resolveLocalBranches(void)
        {
        Array* unresolved = new Array();
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            Object* target = _symbols.get((Hashable*)f.symbol());
            bool isData = false;
            for (u32 k = (u32)0; k < _dataSyms.count(); k = k + (u32)1)
                if (((String*)_dataSyms.get(k)).equals(f.symbol()))
                    {
                    isData = true;
                    break;
                    }
            if (f.kind() == (u32)X86FIX_REL32 && target != (Object*)0 && !isData)
                {
                i32 rel = (i32)((Number*)target).asU32() - (i32)f.offset() + f.addend();
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    _text.set(f.offset() + k, (Object*)Number.withU32(((u32)rel >> ((u32)8 * k)) & (u32)$FF));
                continue;
                }
            unresolved.add((Object*)f);
            }
        _fixups = unresolved;
        }
    }
