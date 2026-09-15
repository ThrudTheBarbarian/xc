// M68k.xc — the 68000/68030 assembler, in xtc.
// =================================================================
//
// self-hosting M23, a port of `XAM68kAssembler`. Two passes: pass 1 assigns
// label addresses by sizing each instruction, pass 2 encodes bytes and records
// the relocations an absolute-long symbol reference needs. The output is the
// GEMDOS $601A executable an Atari ST loads — the assembler and the container
// are one step here, unlike the other targets.
//
// 68k is big-endian, which is the one thing to keep in mind throughout: every
// word and longword goes out most-significant byte first.
//
// The sizing rule that makes two passes agree is worth stating once. A forward
// reference has no known displacement in pass 1, so any form whose LENGTH
// depends on the displacement would shift every label after it. That is why a
// symbolic jsr/jmp/lea on a non-PIC 68000 is unconditionally the absolute
// 6-byte form with a relocation, rather than a 4-byte bsr.w relaxed on
// overflow.

#import "Foundation.xc"

#define MOP_DREG 0
#define MOP_AREG 1
#define MOP_IMM 2
#define MOP_IND 3
#define MOP_INDDISP 4
#define MOP_PREDEC 5
#define MOP_POSTINC 6
#define MOP_ABS 7
#define MOP_PCDISP 8
#define MOP_FREG 9
#define MOP_INDEX 10
#define MOP_NONE 11

class MOp
    {
    u32 _kind;
    u32 _reg;
    i32 _value;
    bool _isSym;
    String* _sym;
    u32 _idxReg;
    bool _idxIsAddr;
    bool _idxLong;
    u32 _scale;

    void init(void)
        {
        _kind = (u32)MOP_NONE;
        _reg = (u32)0;
        _value = (i32)0;
        _isSym = false;
        _idxReg = (u32)0;
        _idxIsAddr = false;
        _idxLong = true;
        _scale = (u32)0;
        }

    u32 kind(void)
        {
        return _kind;
        }
    u32 reg(void)
        {
        return _reg;
        }
    i32 value(void)
        {
        return _value;
        }
    bool isSym(void)
        {
        return _isSym;
        }
    String* sym(void)
        {
        return _sym;
        }
    u32 idxReg(void)
        {
        return _idxReg;
        }
    bool idxIsAddr(void)
        {
        return _idxIsAddr;
        }
    bool idxLong(void)
        {
        return _idxLong;
        }
    u32 scale(void)
        {
        return _scale;
        }

    void setKind(u32 v)
        {
        _kind = v;
        }
    void setReg(u32 v)
        {
        _reg = v;
        }
    void setValue(i32 v)
        {
        _value = v;
        }
    void setSym(String* s)
        {
        _isSym = true;
        _sym = s;
        }
    void setIdx(u32 r, bool isAddr, bool isLong, u32 sc)
        {
        _idxReg = r;
        _idxIsAddr = isAddr;
        _idxLong = isLong;
        _scale = sc;
        }
    }

    class M68kAsm
    {
    u32 _cpu;  // 68000 by default; 68020+ gets 32-bit PC-relative
    bool _pic; // the 68000 GOT/a5 model
    bool _gotMode;
    Map* _gotSlots;   // symbol -> slot index
    Array* _gotOrder; // String@
    bool _failed;
    String* _why;
    // The last symbol `symLookup` could not find, or null. Pass 1 misses
    // forward references legitimately; pass 2 has the whole table, and a
    // miss there used to resolve to 0 SILENTLY. The pass-2 loop clears this
    // before each line and refuses if it is set — mirroring the reference,
    // which grew the same check when bug 126 (an 80-byte symbol buffer that
    // truncated a label, so its use missed and branched to offset 0) showed
    // that a silent 0 is what lets a wrong name assemble at all.
    String* _missingSym;

    void init(void)
        {
        _cpu = (u32)68000;
        _pic = false;
        _failed = false;
        }

    void setCpu(u32 v)
        {
        _cpu = v;
        }
    void setPic(bool v)
        {
        _pic = v;
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

    // ── Numbers and registers ────────────────────────────────────────────
    bool _numOk;

    i32 parseNum(String* s0)
        {
        _numOk = false;
        if (s0 == (String*)0)
            return (i32)0;
        String* s = s0.trimmed();
        if (s.byteLength() == (u32)0)
            return (i32)0;
        i32 sign = (i32)1;
        if (s.hasPrefix(String.withCString("-")))
            {
            sign = (i32)-1;
            s = s.substringFromByte((u32)1);
            }
        else if (s.hasPrefix(String.withCString("+")))
            s = s.substringFromByte((u32)1);
        u32 base = (u32)10;
        if (s.hasPrefix(String.withCString("$")))
            {
            base = (u32)16;
            s = s.substringFromByte((u32)1);
            }
        else if (s.hasPrefix(String.withCString("0x")) || s.hasPrefix(String.withCString("0X")))
            {
            base = (u32)16;
            s = s.substringFromByte((u32)2);
            }
        else if (s.hasPrefix(String.withCString("%")))
            {
            base = (u32)2;
            s = s.substringFromByte((u32)1);
            }
        if (s.byteLength() == (u32)0)
            return (i32)0;
        u32 v = (u32)0;
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
            if (d >= base)
                return (i32)0;
            v = v * base + d;
            }
        _numOk = true;
        return sign * (i32)v;
        }

    // Returns the register number, or -1. `_regIsAddr` says which file.
    bool _regIsAddr;

    i32 parseReg(String* s0)
        {
        if (s0 == (String*)0)
            return (i32)-1;
        String* s = s0.trimmed().lowercased();
        if (s.equals(String.withCString("sp")))
            {
            _regIsAddr = true;
            return (i32)7;
            }
        if (s.byteLength() != (u32)2)
            return (i32)-1;
        u8 f = s.byteAt((u32)0);
        u8 d = s.byteAt((u32)1);
        if (d < (u8)'0' || d > (u8)'7')
            return (i32)-1;
        if (f == (u8)'d')
            {
            _regIsAddr = false;
            return (i32)(d - (u8)'0');
            }
        if (f == (u8)'a')
            {
            _regIsAddr = true;
            return (i32)(d - (u8)'0');
            }
        return (i32)-1;
        }

    // ── Operands ─────────────────────────────────────────────────────────
    MOp* parseOperand(String* raw0)
        {
        MOp* o = new MOp();
        String* raw = raw0.trimmed();
        if (raw.byteLength() == (u32)0)
            return o;

        if (raw.hasPrefix(String.withCString("#")))
            {
            String* rest = raw.substringFromByte((u32)1);
            o.setKind((u32)MOP_IMM);
            i32 v = parseNum(rest);
            if (_numOk)
                o.setValue(v);
            else
                o.setSym(rest);
            return o;
            }
        i32 r = parseReg(raw);
        if (r >= (i32)0)
            {
            o.setKind(_regIsAddr ? (u32)MOP_AREG : (u32)MOP_DREG);
            o.setReg((u32)r);
            return o;
            }
        String* lc = raw.lowercased();
        if (lc.byteLength() == (u32)3 && lc.hasPrefix(String.withCString("fp")))
            {
            u8 c = lc.byteAt((u32)2);
            if (c >= (u8)'0' && c <= (u8)'7')
                {
                o.setKind((u32)MOP_FREG);
                o.setReg((u32)(c - (u8)'0'));
                return o;
                }
            }
        if (raw.hasPrefix(String.withCString("-(")) && raw.hasSuffix(String.withCString(")")))
            {
            i32 br = parseReg(raw.substringBytes((u32)2, raw.byteLength() - (u32)3));
            if (br < (i32)0 || !_regIsAddr)
                {
                fail(String.withCString("bad -(An)"));
                return o;
                }
            o.setKind((u32)MOP_PREDEC);
            o.setReg((u32)br);
            return o;
            }
        if (raw.hasPrefix(String.withCString("(")) && raw.hasSuffix(String.withCString(")+")))
            {
            i32 br = parseReg(raw.substringBytes((u32)1, raw.byteLength() - (u32)3));
            if (br < (i32)0 || !_regIsAddr)
                {
                fail(String.withCString("bad (An)+"));
                return o;
                }
            o.setKind((u32)MOP_POSTINC);
            o.setReg((u32)br);
            return o;
            }
        if (raw.hasPrefix(String.withCString("(")) && raw.hasSuffix(String.withCString(")")))
            return parseParenForm(raw.substringBytes((u32)1, raw.byteLength() - (u32)2), o);

        u32 paren = raw.byteIndexOf(String.withCString("("));
        if (paren != (u32)$FFFF_FFFF && raw.hasSuffix(String.withCString(")")))
            {
            String* disp = raw.substringBytes((u32)0, paren);
            String* inner = raw.substringBytes(paren + (u32)1, raw.byteLength() - paren - (u32)2);
            if (inner.lowercased().equals(String.withCString("pc")))
                {
                o.setKind((u32)MOP_PCDISP);
                o.setValue(parseNum(disp));
                return o;
                }
            i32 br = parseReg(inner);
            if (br < (i32)0 || !_regIsAddr)
                {
                fail(String.withCString("bad disp(An)"));
                return o;
                }
            o.setKind((u32)MOP_INDDISP);
            o.setReg((u32)br);
            o.setValue(parseNum(disp));
            return o;
            }
        // Bare: an absolute number, or a symbol (abs.l).
        o.setKind((u32)MOP_ABS);
        i32 v = parseNum(raw);
        if (_numOk)
            o.setValue(v);
        else
            o.setSym(raw);
        return o;
        }

    // `(An)` or the 68020 indexed `(An,Xn.SIZE*SCALE)`.
    MOp* parseParenForm(String* inner, MOp* o)
        {
        u32 comma = inner.byteIndexOf(String.withCString(","));
        if (comma != (u32)$FFFF_FFFF)
            {
            i32 breg = parseReg(inner.substringBytes((u32)0, comma));
            if (breg < (i32)0 || !_regIsAddr)
                {
                fail(String.withCString("bad (An,Xn) base"));
                return o;
                }
            String* idxS = inner.substringFromByte(comma + (u32)1).trimmed();
            u32 dot = idxS.byteIndexOf(String.withCString("."));
            String* regS = dot == (u32)$FFFF_FFFF ? idxS : idxS.substringBytes((u32)0, dot);
            i32 ireg = parseReg(regS);
            if (ireg < (i32)0)
                {
                fail(String.withCString("bad index register"));
                return o;
                }
            bool iAddr = _regIsAddr;
            bool isLong = true;
            u32 scale = (u32)0;
            if (dot != (u32)$FFFF_FFFF)
                {
                String* suf = idxS.substringFromByte(dot + (u32)1).lowercased();
                isLong = !suf.hasPrefix(String.withCString("w"));
                u32 star = suf.byteIndexOf(String.withCString("*"));
                if (star != (u32)$FFFF_FFFF)
                    {
                    i32 sc = parseNum(suf.substringFromByte(star + (u32)1));
                    scale = sc == (i32)2 ? (u32)1 : sc == (i32)4 ? (u32)2
                                                : sc == (i32)8   ? (u32)3
                                                                 : (u32)0;
                    }
                }
            o.setKind((u32)MOP_INDEX);
            o.setReg((u32)breg);
            o.setIdx((u32)ireg, iAddr, isLong, scale);
            return o;
            }
        i32 br = parseReg(inner);
        if (br < (i32)0 || !_regIsAddr)
            {
            fail(String.withCString("bad (An)"));
            return o;
            }
        o.setKind((u32)MOP_IND);
        o.setReg((u32)br);
        return o;
        }

    // The 6-bit effective-address field: mode in the top three bits, register
    // in the low three.
    static u32 eaField(MOp* o)
        {
        u32 k = o.kind();
        if (k == (u32)MOP_DREG)
            return ((u32)0 << (u32)3) | o.reg();
        if (k == (u32)MOP_AREG)
            return ((u32)1 << (u32)3) | o.reg();
        if (k == (u32)MOP_IND)
            return ((u32)2 << (u32)3) | o.reg();
        if (k == (u32)MOP_POSTINC)
            return ((u32)3 << (u32)3) | o.reg();
        if (k == (u32)MOP_PREDEC)
            return ((u32)4 << (u32)3) | o.reg();
        if (k == (u32)MOP_INDDISP)
            return ((u32)5 << (u32)3) | o.reg();
        if (k == (u32)MOP_INDEX)
            return ((u32)6 << (u32)3) | o.reg();
        if (k == (u32)MOP_ABS)
            return ((u32)7 << (u32)3) | (u32)1; // abs.l
        if (k == (u32)MOP_PCDISP)
            return ((u32)7 << (u32)3) | (u32)2;
        if (k == (u32)MOP_IMM)
            return ((u32)7 << (u32)3) | (u32)4;
        return (u32)0;
        }

    // ── Emission ─────────────────────────────────────────────────────────
    Array* _d;  // the instruction being built
    Array* _rr; // relocation offsets within _d, or null in pass 1

    void a16(u32 w)
        {
        _d.add((Object*)Number.withU32((w >> (u32)8) & (u32)$FF));
        _d.add((Object*)Number.withU32(w & (u32)$FF));
        }

    void a32(u32 l)
        {
        a16((l >> (u32)16) & (u32)$FFFF);
        a16(l & (u32)$FFFF);
        }

    // `symA-symB` resolves to a link-time constant and needs no relocation —
    // used by the GOT/a5 setup and by PIC vtable offsets.
    static bool symIsDiff(MOp* o)
        {
        if (!o.isSym())
            return false;
        String* p = o.sym();
        if (p.byteLength() == (u32)0 || p.byteAt((u32)0) == (u8)'-')
            return false;
        return p.byteIndexOf(String.withCString("-")) != (u32)$FFFF_FFFF;
        }

    i32 symLookup(Map* syms, String* name)
        {
        Object* v = syms.get((Hashable*)name);
        if (v == (Object*)0)
            {
            _missingSym = name;
            return (i32)0;
            }
        return (i32)((Number*)v).asU32();
        }

    i32 symVal(Map* syms, MOp* o)
        {
        if (!o.isSym())
            return o.value();
        if (symIsDiff(o))
            {
            String* s = o.sym();
            u32 dash = s.byteIndexOf(String.withCString("-"));
            return symLookup(syms, s.substringBytes((u32)0, dash)) - symLookup(syms, s.substringFromByte(dash + (u32)1));
            }
        return symLookup(syms, o.sym());
        }

    // The extension words for one effective address. An abs.l reference to a
    // SINGLE symbol records a relocation; a symbol DIFFERENCE is a constant and
    // needs none.
    void appendExt(MOp* o, u32 size, Map* syms)
        {
        u32 k = o.kind();
        if (k == (u32)MOP_INDDISP || k == (u32)MOP_PCDISP)
            {
            a16((u32)o.value() & (u32)$FFFF);
            return;
            }
        // brief extension word, disp8 = 0
        if (k == (u32)MOP_INDEX)
            {
            u32 ext = (o.idxIsAddr() ? ((u32)1 << (u32)15) : (u32)0) | ((o.idxReg() & (u32)7) << (u32)12) | (o.idxLong() ? ((u32)1 << (u32)11) : (u32)0) | ((o.scale() & (u32)3) << (u32)9);
            a16(ext);
            return;
            }
        if (k == (u32)MOP_ABS)
            {
            if (_rr != (Array*)0 && o.isSym() && !symIsDiff(o))
                _rr.add((Object*)Number.withU32(_d.count()));
            a32((u32)symVal(syms, o));
            return;
            }
        if (k == (u32)MOP_IMM)
            {
            if (size == (u32)4)
                {
                if (o.isSym() && !symIsDiff(o) && _rr != (Array*)0)
                    _rr.add((Object*)Number.withU32(_d.count()));
                a32((u32)symVal(syms, o));
                }
            else
                {
                a16((u32)symVal(syms, o) & (u32)$FFFF);
                }
            }
        }

    static i32 branchCC(String* m)
        {
        if (m.equals(String.withCString("bra")))
            return (i32)0;
        if (m.equals(String.withCString("bsr")))
            return (i32)1;
        if (m.equals(String.withCString("bhi")))
            return (i32)2;
        if (m.equals(String.withCString("bls")))
            return (i32)3;
        if (m.equals(String.withCString("bcc")) || m.equals(String.withCString("bhs")))
            return (i32)4;
        if (m.equals(String.withCString("bcs")) || m.equals(String.withCString("blo")))
            return (i32)5;
        if (m.equals(String.withCString("bne")))
            return (i32)6;
        if (m.equals(String.withCString("beq")))
            return (i32)7;
        if (m.equals(String.withCString("bvc")))
            return (i32)8;
        if (m.equals(String.withCString("bvs")))
            return (i32)9;
        if (m.equals(String.withCString("bpl")))
            return (i32)10;
        if (m.equals(String.withCString("bmi")))
            return (i32)11;
        if (m.equals(String.withCString("bge")))
            return (i32)12;
        if (m.equals(String.withCString("blt")))
            return (i32)13;
        if (m.equals(String.withCString("bgt")))
            return (i32)14;
        if (m.equals(String.withCString("ble")))
            return (i32)15;
        return (i32)-1;
        }

    static i32 sccCC(String* m)
        {
        if (m.equals(String.withCString("st")))
            return (i32)0;
        if (m.equals(String.withCString("sf")))
            return (i32)1;
        if (m.equals(String.withCString("shi")))
            return (i32)2;
        if (m.equals(String.withCString("sls")))
            return (i32)3;
        if (m.equals(String.withCString("scc")) || m.equals(String.withCString("shs")))
            return (i32)4;
        if (m.equals(String.withCString("scs")) || m.equals(String.withCString("slo")))
            return (i32)5;
        if (m.equals(String.withCString("sne")))
            return (i32)6;
        if (m.equals(String.withCString("seq")))
            return (i32)7;
        if (m.equals(String.withCString("svc")))
            return (i32)8;
        if (m.equals(String.withCString("svs")))
            return (i32)9;
        if (m.equals(String.withCString("spl")))
            return (i32)10;
        if (m.equals(String.withCString("smi")))
            return (i32)11;
        if (m.equals(String.withCString("sge")))
            return (i32)12;
        if (m.equals(String.withCString("slt")))
            return (i32)13;
        if (m.equals(String.withCString("sgt")))
            return (i32)14;
        if (m.equals(String.withCString("sle")))
            return (i32)15;
        return (i32)-1;
        }

    u32 gotSlotFor(String* sym)
        {
        Object* s = _gotSlots.get((Hashable*)sym);
        if (s != (Object*)0)
            return ((Number*)s).asU32();
        u32 idx = _gotOrder.count();
        _gotSlots.set((Hashable*)sym, (Object*)Number.withU32(idx));
        _gotOrder.add((Object*)sym);
        return idx;
        }

    // ── One instruction ──────────────────────────────────────────────────
    //
    // `curOff` is the item's byte offset, for the PC-relative forms. `_rr` is
    // null in pass 1, which is also how the code knows not to range-check a
    // displacement whose target is still an unresolved forward reference.
    bool _hit;

    Array* encode(String* mnem, u32 size, Array* ops, Map* syms, u32 curOff, Array* rr)
        {
        _d = new Array();
        _rr = rr;
        _hit = false;

        if (mnem.equals(String.withCString(".dc.l")) || mnem.equals(String.withCString(".dc.w")))
            return encodeDc(mnem, ops, syms);

        MOp* o0 = ops.count() > (u32)0 ? parseOperand((String*)ops.get((u32)0)) : new MOp();
        MOp* o1 = ops.count() > (u32)1 ? parseOperand((String*)ops.get((u32)1)) : new MOp();
        if (_failed)
            return (Array*)0;

        u32 sb = size == (u32)1 ? (u32)0 : size == (u32)2 ? (u32)1
                                                          : (u32)2;

        encFpuBranch(mnem, o0, syms, curOff);
        if (_hit)
            return _d;
        encBranch(mnem, o0, syms, curOff);
        if (_hit)
            return _d;
        encMoves(mnem, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _d;
        encAlu(mnem, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _d;
        encUnary(mnem, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _d;
        encMulDiv(mnem, size, o0, o1, syms);
        if (_hit)
            return _d;
        encFpu(mnem, size, o0, o1, syms);
        if (_hit)
            return _d;
        encControl(mnem, size, o0, o1, syms, curOff);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _d;

        String* m = String.withCString("unsupported mnemonic '");
        m.append(mnem);
        m.appendCString("'");
        fail(m);
        return (Array*)0;
        }

    // `.dc.l` of a symbol emits a relocated four-byte pointer; `symA-symB` is a
    // relocation-free difference (a PIC vtable slot holding method - base).
    Array* encodeDc(String* mnem, Array* ops, Map* syms)
        {
        bool isLong = mnem.equals(String.withCString(".dc.l"));
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            String* t = (String*)ops.get(i);
            u32 dash = t.byteIndexOf(String.withCString("-"));
            if (dash != (u32)$FFFF_FFFF && dash > (u32)0)
                {
                MOp* a = parseOperand(t.substringBytes((u32)0, dash).trimmed());
                MOp* b = parseOperand(t.substringFromByte(dash + (u32)1).trimmed());
                u32 v = (u32)(symVal(syms, a) - symVal(syms, b));
                if (isLong)
                    a32(v);
                else
                    a16(v & (u32)$FFFF);
                continue;
                }
            MOp* e = parseOperand(t);
            u32 v = (u32)symVal(syms, e);
            if (isLong)
                {
                if (e.kind() == (u32)MOP_ABS && e.isSym() && _rr != (Array*)0)
                    _rr.add((Object*)Number.withU32(_d.count()));
                a32(v);
                }
            else
                {
                a16(v & (u32)$FFFF);
                }
            }
        return _d;
        }

    // FBcc — the FPU conditional branch, a word displacement.
    void encFpuBranch(String* mnem, MOp* o0, Map* syms, u32 curOff)
        {
        i32 p = fbCode(mnem);
        if (p < (i32)0)
            return;
        i32 target = symVal(syms, o0);
        a16((u32)$F280 | (u32)p);
        a16((u32)(target - (i32)(curOff + (u32)2)) & (u32)$FFFF);
        _hit = true;
        }

    static i32 fbCode(String* m)
        {
        if (m.equals(String.withCString("fbeq")))
            return (i32)$01;
        if (m.equals(String.withCString("fbne")))
            return (i32)$0E;
        if (m.equals(String.withCString("fbgt")))
            return (i32)$12;
        if (m.equals(String.withCString("fbge")))
            return (i32)$13;
        if (m.equals(String.withCString("fblt")))
            return (i32)$14;
        if (m.equals(String.withCString("fble")))
            return (i32)$15;
        return (i32)-1;
        }

    // Always the word form, so pass 1 and pass 2 size it the same.
    void encBranch(String* mnem, MOp* o0, Map* syms, u32 curOff)
        {
        i32 cc = branchCC(mnem);
        if (cc < (i32)0)
            return;
        i32 target = symVal(syms, o0);
        i32 disp = target - (i32)(curOff + (u32)2);
        a16((u32)$6000 | ((u32)cc << (u32)8));
        a16((u32)disp & (u32)$FFFF);
        _hit = true;
        }

    void encMoves(String* mnem, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        if (mnem.equals(String.withCString("move")) || mnem.equals(String.withCString("movea")))
            {
            u32 top = size == (u32)1 ? (u32)$1000 : size == (u32)2 ? (u32)$3000
                                                                   : (u32)$2000;
            u32 sEa = eaField(o0);
            u32 dEa = eaField(o1);
            a16(top | ((dEa & (u32)7) << (u32)9) | ((dEa >> (u32)3) << (u32)6) | ((sEa >> (u32)3) << (u32)3) | (sEa & (u32)7));
            appendExt(o0, size, syms);
            appendExt(o1, size, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("moveq")))
            {
            // The byte is sign-extended to 32 bits; a signed byte or the
            // unsigned bit pattern is fine, anything wider is not.
            if (o0.kind() != (u32)MOP_IMM || o0.value() < (i32)-128 || o0.value() > (i32)255)
                {
                fail(String.withCString("moveq immediate out of range — must be -128..255 (one byte, sign-extended)"));
                return;
                }
            a16((u32)$7000 | (o1.reg() << (u32)9) | ((u32)o0.value() & (u32)$FF));
            _hit = true;
            return;
            }
        }

    // ── The binary ALU group ─────────────────────────────────────────────
    void encAlu(String* mnem, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        i32 base = aluBase(mnem);
        if (base < (i32)0)
            return;
        bool isEor = mnem.equals(String.withCString("eor"));
        bool isCmp = mnem.equals(String.withCString("cmp"));
        // the xxxI forms
        if (o0.kind() == (u32)MOP_IMM)
            {
            i32 ik = aluImmKind(mnem);
            a16(((u32)ik << (u32)9) | (sb << (u32)6) | eaField(o1));
            appendExt(o0, size, syms); // the immediate
            appendExt(o1, size, syms); // the destination
            _hit = true;
            return;
            }
        // ADDA/SUBA/CMPA <ea>,An
        if (o1.kind() == (u32)MOP_AREG && !isEor)
            {
            u32 opm = size == (u32)2 ? (u32)3 : (u32)7;
            a16((u32)base | (o1.reg() << (u32)9) | (opm << (u32)6) | eaField(o0));
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        // EOR Dx,<ea>, no <ea>,Dn form
        if (isEor)
            {
            if (o0.kind() != (u32)MOP_DREG)
                {
                fail(String.withCString("eor source must be a data register"));
                return;
                }
            a16((u32)base | (o0.reg() << (u32)9) | (((u32)4 | sb) << (u32)6) | eaField(o1));
            appendExt(o1, size, syms);
            _hit = true;
            return;
            }
        // add/sub/and/or Dn,<mem>: source is a data register, destination
        // memory. cmp has no such form — it is always <ea>,Dn.
        if (o0.kind() == (u32)MOP_DREG && o1.kind() != (u32)MOP_DREG && !isCmp)
            {
            a16((u32)base | (o0.reg() << (u32)9) | (((u32)4 | sb) << (u32)6) | eaField(o1));
            appendExt(o1, size, syms);
            _hit = true;
            return;
            }
        a16((u32)base | (o1.reg() << (u32)9) | (sb << (u32)6) | eaField(o0));
        appendExt(o0, size, syms);
        _hit = true;
        }

    static i32 aluBase(String* m)
        {
        if (m.equals(String.withCString("add")))
            return (i32)$D000;
        if (m.equals(String.withCString("sub")))
            return (i32)$9000;
        if (m.equals(String.withCString("and")))
            return (i32)$C000;
        if (m.equals(String.withCString("or")))
            return (i32)$8000;
        if (m.equals(String.withCString("cmp")))
            return (i32)$B000;
        if (m.equals(String.withCString("eor")))
            return (i32)$B000;
        return (i32)-1;
        }

    static i32 aluImmKind(String* m)
        {
        if (m.equals(String.withCString("or")))
            return (i32)0;
        if (m.equals(String.withCString("and")))
            return (i32)1;
        if (m.equals(String.withCString("sub")))
            return (i32)2;
        if (m.equals(String.withCString("add")))
            return (i32)3;
        if (m.equals(String.withCString("eor")))
            return (i32)5;
        if (m.equals(String.withCString("cmp")))
            return (i32)6;
        return (i32)0;
        }

    // ── Shifts, quick arithmetic, Scc, the single-EA unaries ─────────────
    void encUnary(String* mnem, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        i32 sh = shiftType(mnem);
        if (sh >= (i32)0)
            {
            u32 dir = mnem.hasSuffix(String.withCString("l")) ? (u32)1 : (u32)0;
            u32 word = (u32)$E000 | (dir << (u32)8) | (sb << (u32)6) | ((u32)sh << (u32)3) | o1.reg();
            if (o0.kind() == (u32)MOP_DREG)
                word = word | (o0.reg() << (u32)9) | ((u32)1 << (u32)5); // count in Dn
            else
                {
                if (o0.kind() != (u32)MOP_IMM || o0.value() < (i32)1 || o0.value() > (i32)8)
                    {
                    fail(String.withCString("immediate shift count out of range — must be 1..8"));
                    return;
                    }
                word = word | (((u32)o0.value() & (u32)7) << (u32)9);
                }
            a16(word);
            _hit = true;
            return;
            }
        bool isAddq = mnem.equals(String.withCString("addq"));
        if (isAddq || mnem.equals(String.withCString("subq")))
            {
            if (o0.kind() != (u32)MOP_IMM || o0.value() < (i32)1 || o0.value() > (i32)8)
                {
                fail(String.withCString("addq/subq immediate out of range — must be 1..8 (three bits; a larger value would silently wrap)"));
                return;
                }
            u32 n = (u32)o0.value() & (u32)7; // 8 encodes as 0
            a16((isAddq ? (u32)$5000 : (u32)$5100) | (n << (u32)9) | (sb << (u32)6) | eaField(o1));
            appendExt(o1, size, syms);
            _hit = true;
            return;
            }
        i32 sc = sccCC(mnem);
        if (sc >= (i32)0)
            {
            a16((u32)$50C0 | ((u32)sc << (u32)8) | eaField(o0));
            appendExt(o0, (u32)1, syms);
            _hit = true;
            return;
            }
        i32 un = unaryBase(mnem);
        if (un >= (i32)0)
            {
            a16((u32)un | (sb << (u32)6) | eaField(o0));
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("ext")))
            {
            a16((size == (u32)4 ? (u32)$48C0 : (u32)$4880) | o0.reg());
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("swap")))
            {
            a16((u32)$4840 | o0.reg());
            _hit = true;
            return;
            }
        bool isAddx = mnem.equals(String.withCString("addx"));
        if (isAddx || mnem.equals(String.withCString("subx")))
            {
            a16((isAddx ? (u32)$D100 : (u32)$9100) | (o1.reg() << (u32)9) | (sb << (u32)6) | o0.reg());
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("exg")))
            {
            if (o0.kind() == (u32)MOP_DREG && o1.kind() == (u32)MOP_DREG)
                a16((u32)$C140 | (o0.reg() << (u32)9) | o1.reg());
            else if (o0.kind() == (u32)MOP_AREG && o1.kind() == (u32)MOP_AREG)
                a16((u32)$C148 | (o0.reg() << (u32)9) | o1.reg());
            // Dx,Ay — data register first
            else
                {
                u32 dr = o0.kind() == (u32)MOP_DREG ? o0.reg() : o1.reg();
                u32 ar = o0.kind() == (u32)MOP_AREG ? o0.reg() : o1.reg();
                a16((u32)$C188 | (dr << (u32)9) | ar);
                }
            _hit = true;
            return;
            }
        }

    static i32 shiftType(String* m)
        {
        if (m.equals(String.withCString("asl")) || m.equals(String.withCString("asr")))
            return (i32)0;
        if (m.equals(String.withCString("lsl")) || m.equals(String.withCString("lsr")))
            return (i32)1;
        if (m.equals(String.withCString("roxl")) || m.equals(String.withCString("roxr")))
            return (i32)2;
        if (m.equals(String.withCString("rol")) || m.equals(String.withCString("ror")))
            return (i32)3;
        return (i32)-1;
        }

    static i32 unaryBase(String* m)
        {
        if (m.equals(String.withCString("negx")))
            return (i32)$4000;
        if (m.equals(String.withCString("clr")))
            return (i32)$4200;
        if (m.equals(String.withCString("neg")))
            return (i32)$4400;
        if (m.equals(String.withCString("not")))
            return (i32)$4600;
        if (m.equals(String.withCString("tst")))
            return (i32)$4A00;
        return (i32)-1;
        }

    // ── Multiply and divide ──────────────────────────────────────────────
    void encMulDiv(String* mnem, u32 size, MOp* o0, MOp* o1, Map* syms)
        {
        bool isMuls = mnem.equals(String.withCString("muls"));
        if (isMuls || mnem.equals(String.withCString("mulu")))
            {
            // the 68000 16x16 form
            if (size == (u32)2)
                {
                a16((isMuls ? (u32)$C1C0 : (u32)$C0C0) | (o1.reg() << (u32)9) | eaField(o0));
                appendExt(o0, (u32)2, syms);
                _hit = true;
                return;
                }
            a16((u32)$4C00 | eaField(o0)); // the 68020 long form
            a16((o1.reg() << (u32)12) | (isMuls ? (u32)$0800 : (u32)0));
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        bool isDivs = mnem.equals(String.withCString("divs"));
        if (isDivs || mnem.equals(String.withCString("divu")))
            {
            a16((u32)$4C40 | eaField(o0));
            a16((o1.reg() << (u32)12) | (isDivs ? (u32)$0800 : (u32)0) | o1.reg());
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        }

    // ── 68881/68882 FPU (line F, coprocessor id 1) ───────────────────────
    void encFpu(String* mnem, u32 size, MOp* o0, MOp* o1, Map* syms)
        {
        i32 opm = fpuOpmode(mnem);
        if (opm >= (i32)0)
            {
            // The FPU source specifier: .l (long int) 0, .s 1, .w 4, .d 5, .b 6.
            // Our size codes are 4=.l 5=.s 2=.w 8=.d 1=.b.
            u32 fmt = size == (u32)4 ? (u32)0 : size == (u32)5 ? (u32)1
                                            : size == (u32)2   ? (u32)4
                                            : size == (u32)8   ? (u32)5
                                            : size == (u32)1   ? (u32)6
                                                               : (u32)1;
            u32 eabytes = size == (u32)8 ? (u32)8 : (u32)4;
            if (mnem.equals(String.withCString("fmove")) && o0.kind() == (u32)MOP_FREG && o1.kind() != (u32)MOP_FREG)
                {
                a16((u32)$F200 | eaField(o1)); // store fpN to <ea>
                a16((u32)$6000 | (fmt << (u32)10) | (o0.reg() << (u32)7));
                appendExt(o1, eabytes, syms);
                _hit = true;
                return;
                }
            u32 dst = o1.reg();
            if (o0.kind() == (u32)MOP_FREG)
                {
                a16((u32)$F200);
                a16((o0.reg() << (u32)10) | (dst << (u32)7) | (u32)opm);
                }
            else
                {
                a16((u32)$F200 | eaField(o0));
                a16((u32)$4000 | (fmt << (u32)10) | (dst << (u32)7) | (u32)opm);
                appendExt(o0, eabytes, syms);
                }
            _hit = true;
            return;
            }
        i32 fc = fsccCode(mnem);
        if (fc >= (i32)0)
            {
            a16((u32)$F240 | eaField(o0));
            a16((u32)fc);
            appendExt(o0, (u32)1, syms);
            _hit = true;
            return;
            }
        }

    static i32 fpuOpmode(String* m)
        {
        if (m.equals(String.withCString("fmove")))
            return (i32)$00;
        if (m.equals(String.withCString("fadd")))
            return (i32)$22;
        if (m.equals(String.withCString("fsub")))
            return (i32)$28;
        if (m.equals(String.withCString("fmul")))
            return (i32)$23;
        if (m.equals(String.withCString("fdiv")))
            return (i32)$20;
        if (m.equals(String.withCString("fneg")))
            return (i32)$1A;
        if (m.equals(String.withCString("fabs")))
            return (i32)$18;
        if (m.equals(String.withCString("fcmp")))
            return (i32)$38;
        if (m.equals(String.withCString("fsqrt")))
            return (i32)$04;
        if (m.equals(String.withCString("fintrz")))
            return (i32)$03;
        if (m.equals(String.withCString("fint")))
            return (i32)$01;
        if (m.equals(String.withCString("ftst")))
            return (i32)$3A;
        if (m.equals(String.withCString("fsin")))
            return (i32)$0E;
        if (m.equals(String.withCString("fcos")))
            return (i32)$1D;
        if (m.equals(String.withCString("ftan")))
            return (i32)$0F;
        if (m.equals(String.withCString("fasin")))
            return (i32)$0C;
        if (m.equals(String.withCString("facos")))
            return (i32)$1C;
        if (m.equals(String.withCString("fatan")))
            return (i32)$0A;
        if (m.equals(String.withCString("fetox")))
            return (i32)$10;
        if (m.equals(String.withCString("flogn")))
            return (i32)$14;
        if (m.equals(String.withCString("flog10")))
            return (i32)$15;
        if (m.equals(String.withCString("flog2")))
            return (i32)$16;
        if (m.equals(String.withCString("ftwotox")))
            return (i32)$11;
        if (m.equals(String.withCString("ftentox")))
            return (i32)$12;
        if (m.equals(String.withCString("fsinh")))
            return (i32)$02;
        if (m.equals(String.withCString("fcosh")))
            return (i32)$19;
        if (m.equals(String.withCString("ftanh")))
            return (i32)$09;
        return (i32)-1;
        }

    static i32 fsccCode(String* m)
        {
        if (m.equals(String.withCString("fseq")))
            return (i32)$01;
        if (m.equals(String.withCString("fsne")))
            return (i32)$0E;
        if (m.equals(String.withCString("fsgt")))
            return (i32)$12;
        if (m.equals(String.withCString("fsge")))
            return (i32)$13;
        if (m.equals(String.withCString("fslt")))
            return (i32)$14;
        if (m.equals(String.withCString("fsle")))
            return (i32)$15;
        return (i32)-1;
        }

    // ── Control and misc ─────────────────────────────────────────────────
    //
    // A reference to a program symbol: on a non-PIC 68000 it becomes the
    // ABSOLUTE 6-byte form with a load-time relocation rather than a 4-byte
    // bsr.w relaxed on overflow. Both passes then size it the same, and the
    // call reaches anywhere — bsr.w simply fails the build once a program's
    // code span passes 32 KB, which is not a large program.
    void encControl(String* mnem, u32 size, MOp* o0, MOp* o1, Map* syms, u32 curOff)
        {
        bool picSym = o0.kind() == (u32)MOP_ABS && o0.isSym();
        bool wide = _cpu >= (u32)68020;
        bool got = _gotMode && picSym && !symIsDiff(o0);

        if (mnem.equals(String.withCString("jsr")))
            {
            // move.l sym@GOT(a5),a1 ; jsr (a1)
            if (got)
                {
                a16((u32)$226D);
                a16(gotSlotFor(o0.sym()) * (u32)4);
                a16((u32)$4E91);
                _hit = true;
                return;
                }
            if (picSym)
                {
                i32 disp = symVal(syms, o0) - (i32)(curOff + (u32)2);
                if (wide)
                    {
                    a16((u32)$61FF);
                    a32((u32)disp);
                    _hit = true;
                    return;
                    }
                if (!_pic)
                    {
                    a16((u32)$4E80 | eaField(o0));
                    appendExt(o0, (u32)4, syms);
                    _hit = true;
                    return;
                    }
                if (!pcDisp16Ok(disp))
                    {
                    fail(String.withCString("bsr out of +/-32KB (build -A 68030, or -mpic for the 68000 GOT model)"));
                    return;
                    }
                a16((u32)$6100);
                a16((u32)disp & (u32)$FFFF);
                _hit = true;
                return;
                }
            a16((u32)$4E80 | eaField(o0));
            appendExt(o0, (u32)4, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("jmp")))
            {
            if (got)
                {
                a16((u32)$226D);
                a16(gotSlotFor(o0.sym()) * (u32)4);
                a16((u32)$4ED1);
                _hit = true;
                return;
                }
            if (picSym)
                {
                i32 disp = symVal(syms, o0) - (i32)(curOff + (u32)2);
                if (wide)
                    {
                    a16((u32)$60FF);
                    a32((u32)disp);
                    _hit = true;
                    return;
                    }
                if (!_pic)
                    {
                    a16((u32)$4EC0 | eaField(o0));
                    appendExt(o0, (u32)4, syms);
                    _hit = true;
                    return;
                    }
                if (!pcDisp16Ok(disp))
                    {
                    fail(String.withCString("bra out of +/-32KB (build -A 68030 or -mpic)"));
                    return;
                    }
                a16((u32)$6000);
                a16((u32)disp & (u32)$FFFF);
                _hit = true;
                return;
                }
            a16((u32)$4EC0 | eaField(o0));
            appendExt(o0, (u32)4, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("pea")))
            {
            // move.l sym@GOT(a5),-(sp)
            if (got)
                {
                a16((u32)$2F2D);
                a16(gotSlotFor(o0.sym()) * (u32)4);
                _hit = true;
                return;
                }
            if (picSym)
                {
                i32 disp = symVal(syms, o0) - (i32)(curOff + (u32)2);
                if (wide)
                    {
                    a16((u32)$4840 | (((u32)7 << (u32)3) | (u32)3));
                    a16((u32)$0170);
                    a32((u32)disp);
                    _hit = true;
                    return;
                    }
                if (!_pic)
                    {
                    a16((u32)$4840 | eaField(o0));
                    appendExt(o0, (u32)4, syms);
                    _hit = true;
                    return;
                    }
                if (!pcDisp16Ok(disp))
                    {
                    fail(String.withCString("pea out of +/-32KB (build -A 68030 or -mpic)"));
                    return;
                    }
                a16((u32)$4840 | (((u32)7 << (u32)3) | (u32)2));
                a16((u32)disp & (u32)$FFFF);
                _hit = true;
                return;
                }
            a16((u32)$4840 | eaField(o0));
            appendExt(o0, (u32)4, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("lea")))
            {
            // move.l sym@GOT(a5),An
            if (got)
                {
                a16((u32)$206D | (o1.reg() << (u32)9));
                a16(gotSlotFor(o0.sym()) * (u32)4);
                _hit = true;
                return;
                }
            if (picSym)
                {
                i32 disp = symVal(syms, o0) - (i32)(curOff + (u32)2);
                if (wide)
                    {
                    a16((u32)$41C0 | (o1.reg() << (u32)9) | (((u32)7 << (u32)3) | (u32)3));
                    a16((u32)$0170);
                    a32((u32)disp);
                    _hit = true;
                    return;
                    }
                if (!_pic)
                    {
                    a16((u32)$41C0 | (o1.reg() << (u32)9) | eaField(o0));
                    appendExt(o0, (u32)4, syms);
                    _hit = true;
                    return;
                    }
                if (!pcDisp16Ok(disp))
                    {
                    fail(String.withCString("lea out of +/-32KB (build -A 68030 or -mpic)"));
                    return;
                    }
                a16((u32)$41C0 | (o1.reg() << (u32)9) | (((u32)7 << (u32)3) | (u32)2));
                a16((u32)disp & (u32)$FFFF);
                _hit = true;
                return;
                }
            a16((u32)$41C0 | (o1.reg() << (u32)9) | eaField(o0));
            appendExt(o0, (u32)4, syms);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("link")))
            {
            a16((u32)$4E50 | o0.reg());
            a16((u32)o1.value() & (u32)$FFFF);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("unlk")))
            {
            a16((u32)$4E58 | o0.reg());
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("rts")))
            {
            a16((u32)$4E75);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("rte")))
            {
            a16((u32)$4E73);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("rtr")))
            {
            a16((u32)$4E77);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("nop")))
            {
            a16((u32)$4E71);
            _hit = true;
            return;
            }
        // ILLEGAL ($4AFC) — the architecturally-guaranteed illegal instruction,
        // which is how the back end lowers `Unreachable` (a failed checked
        // downcast). A mnemonic the code generator emits and the assembler does
        // not know is exactly the gap the no-fallback rule exists to expose.
        if (mnem.equals(String.withCString("illegal")))
            {
            a16((u32)$4AFC);
            _hit = true;
            return;
            }
        if (mnem.equals(String.withCString("trap")))
            {
            if (o0.kind() != (u32)MOP_IMM || o0.value() < (i32)0 || o0.value() > (i32)15)
                {
                fail(String.withCString("trap vector out of range — must be 0..15"));
                return;
                }
            a16((u32)$4E40 | ((u32)o0.value() & (u32)$F));
            _hit = true;
            return;
            }
        }

    // Pass 1 has unresolved forward references, so the range check only applies
    // once the relocation list exists — that is, in pass 2.
    bool pcDisp16Ok(i32 d)
        {
        if (_rr == (Array*)0)
            return true;
        return d >= (i32)-32768 && d <= (i32)32767;
        }

    // ── Line parsing ─────────────────────────────────────────────────────
    //
    // Split a comma-separated operand list, honouring parens so `12(a6),d0`
    // stays two operands.
    static Array* splitOperands(String* s)
        {
        Array* out = new Array();
        i32 depth = (i32)0;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)'(')
                depth = depth + (i32)1;
            else if (c == (u8)')')
                depth = depth - (i32)1;
            else if (c == (u8)',' && depth == (i32)0)
                {
                out.add((Object*)s.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        String* last = s.substringFromByte(start).trimmed();
        if (last.byteLength() > (u32)0)
            out.add((Object*)last);
        return out;
        }

    // An item is a label, a directive, or an instruction. Both passes walk the
    // same list, so the parse happens once.
    Array* _itemKind; // 0 = label, 1 = directive, 2 = instruction
    Array* _itemA;    // label name / directive name / mnemonic
    Array* _itemB;    // directive args (String@) / operand list (Array@)
    Array* _itemSize; // instruction size code

    void parseSource(String* source)
        {
        _itemKind = new Array();
        _itemA = new Array();
        _itemB = new Array();
        _itemSize = new Array();
        Array* lines = source.splitOnByte((u8)'\n');
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1)
            {
            String* line = (String*)lines.get(li);
            u32 semi = line.byteIndexOf(String.withCString(";"));
            if (semi != (u32)$FFFF_FFFF)
                line = line.substringBytes((u32)0, semi);
            String* trimmed = line.trimmed();
            if (trimmed.byteLength() == (u32)0)
                continue;
            // A label sits at column 0 as `name:`.
            bool indented = line.hasPrefix(String.withCString(" ")) || line.hasPrefix(String.withCString("\t"));
            if (!indented)
                {
                u32 colon = trimmed.byteIndexOf(String.withCString(":"));
                if (colon != (u32)$FFFF_FFFF)
                    {
                    String* lbl = trimmed.substringBytes((u32)0, colon);
                    // A label named after a register can never be referenced
                    // — every operand mention parses as the REGISTER — so
                    // defining one is always a bug in whatever emitted the
                    // asm (the backend mangles them; see m68kSym). Mirrors
                    // the reference assembler's refusal.
                    String* ll = lbl.lowercased();
                    bool sh = parseReg(lbl) >= (i32)0;
                    if (ll.byteLength() == (u32)3 && ll.hasPrefix(String.withCString("fp")) && ll.byteAt((u32)2) >= (u8)'0' && ll.byteAt((u32)2) <= (u8)'7')
                        sh = true;
                    if (sh)
                        {
                        String* m = String.withCString("label '");
                        m.append(lbl);
                        m.appendCString("' shadows a register name");
                        fail(m);
                        return;
                        }
                    addItem((u32)0, lbl, (Object*)0, (u32)0);
                    trimmed = trimmed.substringFromByte(colon + (u32)1).trimmed();
                    if (trimmed.byteLength() == (u32)0)
                        continue;
                    }
                }
            u32 sp = firstSpace(trimmed);
            String* head = sp == (u32)$FFFF_FFFF ? trimmed : trimmed.substringBytes((u32)0, sp);
            String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                                 : trimmed.substringFromByte(sp).trimmed();
            // `.dc.l`/`.dc.w` may hold relocatable symbols, so they go through
            // the encoder (which records relocations); other directives are
            // plain data.
            if (head.equals(String.withCString(".dc.l")) || head.equals(String.withCString(".dc.w")))
                {
                addItem((u32)2, head, (Object*)(rest.byteLength() > (u32)0 ? splitOperands(rest) : new Array()),
                        (u32)4);
                continue;
                }
            if (head.hasPrefix(String.withCString(".")))
                {
                addItem((u32)1, head, (Object*)rest, (u32)0);
                continue;
                }
            String* mnem = head;
            String* szs = (String*)0;
            u32 dot = head.byteIndexOf(String.withCString("."));
            if (dot != (u32)$FFFF_FFFF)
                {
                mnem = head.substringBytes((u32)0, dot);
                szs = head.substringFromByte(dot + (u32)1);
                }
            u32 size = (u32)2;
            if (szs != (String*)0)
                {
                if (szs.equals(String.withCString("b")))
                    size = (u32)1;
                else if (szs.equals(String.withCString("l")))
                    size = (u32)4;
                else if (szs.equals(String.withCString("w")))
                    size = (u32)2;
                else if (szs.equals(String.withCString("s")))
                    size = (u32)5; // FPU single
                else if (szs.equals(String.withCString("d")))
                    size = (u32)8; // FPU double
                }
            addItem((u32)2, mnem.lowercased(),
                    (Object*)(rest.byteLength() > (u32)0 ? splitOperands(rest) : new Array()), size);
            }
        }

    void addItem(u32 kind, String* a, Object* b, u32 size)
        {
        _itemKind.add((Object*)Number.withU32(kind));
        _itemA.add((Object*)a);
        _itemB.add(b == (Object*)0 ? (Object*)String.withCString("") : b);
        _itemSize.add((Object*)Number.withU32(size));
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

    // The bytes a plain data directive contributes, in both passes.
    Array* dataForDir(String* dir, String* args, u32 curOff)
        {
        Array* d = new Array();
        if (dir.equals(String.withCString(".even")))
            {
            if ((curOff & (u32)1) != (u32)0)
                d.add((Object*)Number.withU32((u32)0));
            return d;
            }
        if (dir.equals(String.withCString(".ascii")) || dir.equals(String.withCString(".asciz")))
            {
            u32 q1 = args.byteIndexOf(String.withCString("\""));
            u32 q2 = lastQuote(args);
            if (q1 != (u32)$FFFF_FFFF && q2 > q1)
                {
                String* str = args.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
                u32 i = (u32)0;
                while (i < str.byteLength())
                    {
                    u8 c = str.byteAt(i);
                    if (c == (u8)'\\' && i + (u32)1 < str.byteLength())
                        {
                        u8 n = str.byteAt(i + (u32)1);
                        if (n == (u8)'n')
                            {
                            d.add((Object*)Number.withU32((u32)10));
                            i = i + (u32)2;
                            continue;
                            }
                        if (n == (u8)'r')
                            {
                            d.add((Object*)Number.withU32((u32)13));
                            i = i + (u32)2;
                            continue;
                            }
                        if (n == (u8)'0')
                            {
                            d.add((Object*)Number.withU32((u32)0));
                            i = i + (u32)2;
                            continue;
                            }
                        }
                    d.add((Object*)Number.withU32((u32)c));
                    i = i + (u32)1;
                    }
                }
            if (dir.equals(String.withCString(".asciz")))
                d.add((Object*)Number.withU32((u32)0));
            return d;
            }
        if (dir.equals(String.withCString(".space")) || dir.equals(String.withCString(".ds.b")))
            {
            i32 n = parseNum(args);
            if (_numOk)
                for (i32 k = (i32)0; k < n; k = k + (i32)1)
                    d.add((Object*)Number.withU32((u32)0));
            return d;
            }
        if (dir.equals(String.withCString(".dc.b")) || dir.equals(String.withCString(".byte")))
            {
            Array* toks = splitOperands(args);
            for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
                {
                i32 v = parseNum((String*)toks.get(i));
                if (_numOk)
                    d.add((Object*)Number.withU32((u32)v & (u32)$FF));
                }
            return d;
            }
        return d;
        }

    static u32 lastQuote(String* s)
        {
        u32 f = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == (u8)'"')
                f = i;
        return f;
        }

    // ── The two passes, and the $601A image ──────────────────────────────
    //
    // Segments lie contiguously — GEMDOS loads text and data adjacently and
    // zeroes bss after — so offsets run sequentially across all three and the
    // pass only records where .data and .bss begin, to split the sizes.
    Array* _image; // the finished executable

    Array* image(void)
        {
        return _image;
        }

    void assemble(String* source)
        {
        parseSource(source);
        if (_failed)
            return;
        _gotMode = _pic && _cpu < (u32)68020;
        _gotSlots = new Map();
        _gotOrder = new Array();
        Map* syms = new Map();

        u32 off = (u32)0;
        u32 segDataStart = (u32)0;
        u32 segBssStart = (u32)0;
        bool haveData = false;
        bool haveBss = false;
        for (u32 i = (u32)0; i < _itemKind.count(); i = i + (u32)1)
            {
            u32 kind = ((Number*)_itemKind.get(i)).asU32();
            if (kind == (u32)0)
                {
                // A label defined twice is a hard error — the map would keep
                // the later one silently (bug 128's second `_start`).
                if (syms.get((Hashable*)(String*)_itemA.get(i)) != (Object*)0)
                    {
                    String* m = String.withCString("duplicate label '");
                    m.append((String*)_itemA.get(i));
                    m.appendCString("'");
                    fail(m);
                    return;
                    }
                syms.set((Hashable*)(String*)_itemA.get(i), (Object*)Number.withU32(off));
                continue;
                }
            if (kind == (u32)1)
                {
                String* dir = (String*)_itemA.get(i);
                if (dir.equals(String.withCString(".data")))
                    {
                    segDataStart = off;
                    haveData = true;
                    continue;
                    }
                if (dir.equals(String.withCString(".bss")))
                    {
                    segBssStart = off;
                    haveBss = true;
                    continue;
                    }
                if (dir.equals(String.withCString(".text")) || dir.equals(String.withCString(".globl")))
                    continue;
                off = off + dataForDir(dir, (String*)_itemB.get(i), off).count();
                continue;
                }
            Array* enc = encode((String*)_itemA.get(i), ((Number*)_itemSize.get(i)).asU32(),
                                (Array*)_itemB.get(i), syms, off, (Array*)0);
            if (enc == (Array*)0)
                {
                if (!_failed)
                    fail(String.withCString("encode error (pass 1)"));
                return;
                }
            off = off + enc.count();
            }
        // The GOT lives at the end of the in-file image. In GOT mode the back
        // end folds bss into .data, so no separate bss segment is displaced.
        if (_gotMode)
            {
            syms.set((Hashable*)String.withCString("_GOT"), (Object*)Number.withU32(off));
            off = off + _gotOrder.count() * (u32)4;
            }

        u32 totalOff = off;
        u32 tsize = haveData ? segDataStart : (haveBss ? segBssStart : totalOff);
        u32 dataEnd = haveBss ? segBssStart : totalOff;
        u32 dsize = haveData ? (dataEnd - segDataStart) : (u32)0;
        u32 bsize = haveBss ? (totalOff - segBssStart) : (u32)0;

        // Pass 2. The image is text plus data — everything before .bss; bss
        // reserves no file bytes, its labels were assigned in pass 1 and the
        // loader zeroes it.
        Array* text = new Array();
        Array* relocs = new Array();
        bool inBss = false;
        for (u32 i = (u32)0; i < _itemKind.count(); i = i + (u32)1)
            {
            u32 kind = ((Number*)_itemKind.get(i)).asU32();
            if (kind == (u32)0)
                continue;
            if (kind == (u32)1)
                {
                String* dir = (String*)_itemA.get(i);
                if (dir.equals(String.withCString(".bss")))
                    {
                    inBss = true;
                    continue;
                    }
                if (dir.equals(String.withCString(".text")) || dir.equals(String.withCString(".data")) || dir.equals(String.withCString(".globl")))
                    continue;
                if (inBss)
                    continue;
                Array* dd = dataForDir(dir, (String*)_itemB.get(i), text.count());
                for (u32 k = (u32)0; k < dd.count(); k = k + (u32)1)
                    text.add(dd.get(k));
                continue;
                }
            if (inBss)
                continue;
            Array* rr = new Array();
            u32 base = text.count();
            _missingSym = (String*)0;
            Array* enc = encode((String*)_itemA.get(i), ((Number*)_itemSize.get(i)).asU32(),
                                (Array*)_itemB.get(i), syms, base, rr);
            if (enc == (Array*)0)
                {
                if (!_failed)
                    fail(String.withCString("encode error (pass 2)"));
                return;
                }
            if (_missingSym != (String*)0)
                {
                String* m = String.withCString("undefined symbol '");
                m.append(_missingSym);
                m.appendCString("' in '");
                m.append((String*)_itemA.get(i));
                m.appendCString("'");
                fail(m);
                return;
                }
            for (u32 k = (u32)0; k < rr.count(); k = k + (u32)1)
                relocs.add((Object*)Number.withU32(base + ((Number*)rr.get(k)).asU32()));
            for (u32 k = (u32)0; k < enc.count(); k = k + (u32)1)
                text.add(enc.get(k));
            }
        // The GOT: one relocated longword per referenced symbol, in slot order.
        if (_gotMode)
            {
            for (u32 i = (u32)0; i < _gotOrder.count(); i = i + (u32)1)
                {
                String* sym = (String*)_gotOrder.get(i);
                relocs.add((Object*)Number.withU32(text.count()));
                _missingSym = (String*)0;
                u32 v = (u32)symLookup(syms, sym);
                if (_missingSym != (String*)0)
                    {
                    String* m = String.withCString("undefined symbol '");
                    m.append(_missingSym);
                    m.appendCString("' in the GOT");
                    fail(m);
                    return;
                    }
                text.add((Object*)Number.withU32((v >> (u32)24) & (u32)$FF));
                text.add((Object*)Number.withU32((v >> (u32)16) & (u32)$FF));
                text.add((Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
                text.add((Object*)Number.withU32(v & (u32)$FF));
                }
            }
        emit601A(text, relocs, tsize, dsize, bsize);
        }

    void emit601A(Array* text, Array* relocs, u32 tsize, u32 dsize, u32 bsize)
        {
        _d = new Array();
        a16((u32)$601A); // magic
        a32(tsize);
        a32(dsize);
        a32(bsize);
        a32((u32)0); // ssize
        a32((u32)0); // res1
        // prgflags (MiNT). The generated code is fully position-independent, so
        // it is safe to load into and allocate from alternative (TT/fast) RAM.
        // FASTLOAD is left OFF so the OS still zeroes the TPA heap — the
        // runtime does not pre-zero it.
        a32((u32)$06); // PF_TTRAMLOAD | PF_TTRAMMEM
        a16((u32)0);   // absflag 0 -> a relocation table follows
        _image = new Array();
        for (u32 i = (u32)0; i < _d.count(); i = i + (u32)1)
            _image.add(_d.get(i));
        for (u32 i = (u32)0; i < text.count(); i = i + (u32)1)
            _image.add(text.get(i));

        // The DRI relocation stream: the first fixup as a longword, then one
        // advance byte per subsequent fixup, where 1 means "skip 254".
        sortNumbers(relocs);
        if (relocs.count() == (u32)0)
            {
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                _image.add((Object*)Number.withU32((u32)0));
            return;
            }
        u32 prev = ((Number*)relocs.get((u32)0)).asU32();
        _image.add((Object*)Number.withU32((prev >> (u32)24) & (u32)$FF));
        _image.add((Object*)Number.withU32((prev >> (u32)16) & (u32)$FF));
        _image.add((Object*)Number.withU32((prev >> (u32)8) & (u32)$FF));
        _image.add((Object*)Number.withU32(prev & (u32)$FF));
        for (u32 i = (u32)1; i < relocs.count(); i = i + (u32)1)
            {
            u32 cur = ((Number*)relocs.get(i)).asU32();
            u32 delta = cur - prev;
            while (delta > (u32)254)
                {
                _image.add((Object*)Number.withU32((u32)1));
                delta = delta - (u32)254;
                }
            _image.add((Object*)Number.withU32(delta & (u32)$FF));
            prev = cur;
            }
        _image.add((Object*)Number.withU32((u32)0));
        }

    static void sortNumbers(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* v = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)a.get(j - (u32)1)).asU32() > ((Number*)v).asU32())
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, v);
            }
        }
    }
