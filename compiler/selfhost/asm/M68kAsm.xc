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
#import <GasString>

#import "M68kAsmDefs.xc"

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

// Mnemonics as numbers. encode looks the mnemonic (its size suffix already
// split off) up once, and the encoders and their tables compare the number
// instead of the String, each comparison of which built and freed a String.
// Every mnemonic an encoder tests is here; anything else is m68Unknown and
// still reaches the "unsupported mnemonic" error. The numbering is private
// to the process.
enum M68kMnemonic = {
    m68Unknown = 0,
    m68DcL, m68DcW, m68Add, m68Adda, m68Addq, m68Addx,
    m68And, m68Asl, m68Asr, m68Bcc, m68Bcs, m68Beq,
    m68Bge, m68Bgt, m68Bhi, m68Bhs, m68Ble, m68Blo,
    m68Bls, m68Blt, m68Bmi, m68Bne, m68Bpl, m68Bra,
    m68Bsr, m68Bvc, m68Bvs, m68Clr, m68Cmp, m68Cmpa,
    m68Divs, m68Divu, m68Eor, m68Exg, m68Ext, m68Fabs,
    m68Facos, m68Fadd, m68Fasin, m68Fatan, m68Fbeq, m68Fbge,
    m68Fbgt, m68Fble, m68Fblt, m68Fbne, m68Fcmp, m68Fcos,
    m68Fcosh, m68Fdiv, m68Fetox, m68Fint, m68Fintrz, m68Flog10,
    m68Flog2, m68Flogn, m68Fmove, m68Fmul, m68Fneg, m68Fseq,
    m68Fsge, m68Fsgt, m68Fsin, m68Fsinh, m68Fsle, m68Fslt,
    m68Fsne, m68Fsqrt, m68Fsub, m68Ftan, m68Ftanh, m68Ftentox,
    m68Ftst, m68Ftwotox, m68Illegal, m68Jmp, m68Jsr, m68Lea,
    m68Link, m68Lsl, m68Lsr, m68Move, m68Movea, m68Moveq,
    m68Muls, m68Mulu, m68Neg, m68Negx, m68Nop, m68Not,
    m68Or, m68Pea, m68Rol, m68Ror, m68Roxl, m68Roxr,
    m68Rte, m68Rtr, m68Rts, m68Scc, m68Scs, m68Seq,
    m68Sf, m68Sge, m68Sgt, m68Shi, m68Shs, m68Sle,
    m68Slo, m68Sls, m68Slt, m68Smi, m68Sne, m68Spl,
    m68St, m68Sub, m68Suba, m68Subq, m68Subx, m68Svc,
    m68Svs, m68Swap, m68Trap, m68Tst, m68Unlk
};

class M68kMn
    {
    static Map* _byName;   // mnemonic -> its number (Number@)
    u8 _unused;            // no instances: every entry point is static

    static void def(u16 mc, string name)
        {
        _byName.set((Hashable*)String.withCString(name), (Object*)Number.with(mc));
        }

    static void build(void)
        {
        _byName = new Map();
        M68kMn.def(m68DcL, ".dc.l"); M68kMn.def(m68DcW, ".dc.w"); M68kMn.def(m68Add, "add");
        M68kMn.def(m68Adda, "adda"); M68kMn.def(m68Addq, "addq"); M68kMn.def(m68Addx, "addx");
        M68kMn.def(m68And, "and"); M68kMn.def(m68Asl, "asl"); M68kMn.def(m68Asr, "asr");
        M68kMn.def(m68Bcc, "bcc"); M68kMn.def(m68Bcs, "bcs"); M68kMn.def(m68Beq, "beq");
        M68kMn.def(m68Bge, "bge"); M68kMn.def(m68Bgt, "bgt"); M68kMn.def(m68Bhi, "bhi");
        M68kMn.def(m68Bhs, "bhs"); M68kMn.def(m68Ble, "ble"); M68kMn.def(m68Blo, "blo");
        M68kMn.def(m68Bls, "bls"); M68kMn.def(m68Blt, "blt"); M68kMn.def(m68Bmi, "bmi");
        M68kMn.def(m68Bne, "bne"); M68kMn.def(m68Bpl, "bpl"); M68kMn.def(m68Bra, "bra");
        M68kMn.def(m68Bsr, "bsr"); M68kMn.def(m68Bvc, "bvc"); M68kMn.def(m68Bvs, "bvs");
        M68kMn.def(m68Clr, "clr"); M68kMn.def(m68Cmp, "cmp"); M68kMn.def(m68Cmpa, "cmpa");
        M68kMn.def(m68Divs, "divs"); M68kMn.def(m68Divu, "divu"); M68kMn.def(m68Eor, "eor");
        M68kMn.def(m68Exg, "exg"); M68kMn.def(m68Ext, "ext"); M68kMn.def(m68Fabs, "fabs");
        M68kMn.def(m68Facos, "facos"); M68kMn.def(m68Fadd, "fadd"); M68kMn.def(m68Fasin, "fasin");
        M68kMn.def(m68Fatan, "fatan"); M68kMn.def(m68Fbeq, "fbeq"); M68kMn.def(m68Fbge, "fbge");
        M68kMn.def(m68Fbgt, "fbgt"); M68kMn.def(m68Fble, "fble"); M68kMn.def(m68Fblt, "fblt");
        M68kMn.def(m68Fbne, "fbne"); M68kMn.def(m68Fcmp, "fcmp"); M68kMn.def(m68Fcos, "fcos");
        M68kMn.def(m68Fcosh, "fcosh"); M68kMn.def(m68Fdiv, "fdiv"); M68kMn.def(m68Fetox, "fetox");
        M68kMn.def(m68Fint, "fint"); M68kMn.def(m68Fintrz, "fintrz"); M68kMn.def(m68Flog10, "flog10");
        M68kMn.def(m68Flog2, "flog2"); M68kMn.def(m68Flogn, "flogn"); M68kMn.def(m68Fmove, "fmove");
        M68kMn.def(m68Fmul, "fmul"); M68kMn.def(m68Fneg, "fneg"); M68kMn.def(m68Fseq, "fseq");
        M68kMn.def(m68Fsge, "fsge"); M68kMn.def(m68Fsgt, "fsgt"); M68kMn.def(m68Fsin, "fsin");
        M68kMn.def(m68Fsinh, "fsinh"); M68kMn.def(m68Fsle, "fsle"); M68kMn.def(m68Fslt, "fslt");
        M68kMn.def(m68Fsne, "fsne"); M68kMn.def(m68Fsqrt, "fsqrt"); M68kMn.def(m68Fsub, "fsub");
        M68kMn.def(m68Ftan, "ftan"); M68kMn.def(m68Ftanh, "ftanh"); M68kMn.def(m68Ftentox, "ftentox");
        M68kMn.def(m68Ftst, "ftst"); M68kMn.def(m68Ftwotox, "ftwotox"); M68kMn.def(m68Illegal, "illegal");
        M68kMn.def(m68Jmp, "jmp"); M68kMn.def(m68Jsr, "jsr"); M68kMn.def(m68Lea, "lea");
        M68kMn.def(m68Link, "link"); M68kMn.def(m68Lsl, "lsl"); M68kMn.def(m68Lsr, "lsr");
        M68kMn.def(m68Move, "move"); M68kMn.def(m68Movea, "movea"); M68kMn.def(m68Moveq, "moveq");
        M68kMn.def(m68Muls, "muls"); M68kMn.def(m68Mulu, "mulu"); M68kMn.def(m68Neg, "neg");
        M68kMn.def(m68Negx, "negx"); M68kMn.def(m68Nop, "nop"); M68kMn.def(m68Not, "not");
        M68kMn.def(m68Or, "or"); M68kMn.def(m68Pea, "pea"); M68kMn.def(m68Rol, "rol");
        M68kMn.def(m68Ror, "ror"); M68kMn.def(m68Roxl, "roxl"); M68kMn.def(m68Roxr, "roxr");
        M68kMn.def(m68Rte, "rte"); M68kMn.def(m68Rtr, "rtr"); M68kMn.def(m68Rts, "rts");
        M68kMn.def(m68Scc, "scc"); M68kMn.def(m68Scs, "scs"); M68kMn.def(m68Seq, "seq");
        M68kMn.def(m68Sf, "sf"); M68kMn.def(m68Sge, "sge"); M68kMn.def(m68Sgt, "sgt");
        M68kMn.def(m68Shi, "shi"); M68kMn.def(m68Shs, "shs"); M68kMn.def(m68Sle, "sle");
        M68kMn.def(m68Slo, "slo"); M68kMn.def(m68Sls, "sls"); M68kMn.def(m68Slt, "slt");
        M68kMn.def(m68Smi, "smi"); M68kMn.def(m68Sne, "sne"); M68kMn.def(m68Spl, "spl");
        M68kMn.def(m68St, "st"); M68kMn.def(m68Sub, "sub"); M68kMn.def(m68Suba, "suba");
        M68kMn.def(m68Subq, "subq"); M68kMn.def(m68Subx, "subx"); M68kMn.def(m68Svc, "svc");
        M68kMn.def(m68Svs, "svs"); M68kMn.def(m68Swap, "swap"); M68kMn.def(m68Trap, "trap");
        M68kMn.def(m68Tst, "tst"); M68kMn.def(m68Unlk, "unlk");
        }

    // The number of a mnemonic, or m68Unknown for one no encoder tests.
    static u16 find(String* mnemonic)
        {
        if (_byName == (Map*)0)
            M68kMn.build();
        Number* mc = (Number*)_byName.get((Hashable*)mnemonic);
        if (mc == (Number*)0)
            return m68Unknown;
        return mc.asU16();
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
    Data* _d;  // the instruction being built
    Array* _rr; // relocation offsets within _d, or null in pass 1

    void a16(u32 w)
        {
        _d.appendByte((u8)((w >> (u32)8) & (u32)$FF));
        _d.appendByte((u8)(w & (u32)$FF));
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
            // A d16 past -32768..32767 was masked, so a field 40000 bytes in
            // was stored 25 KB below the object (#289); it is refused.
            if (!pcDisp16Ok(o.value()))
                fail(String.withFormat("displacement %ld does not fit 16 bits", o.value()));
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
                _rr.add((Object*)Number.withU32(_d.length()));
            a32((u32)symVal(syms, o));
            return;
            }
        if (k == (u32)MOP_IMM)
            {
            if (size == (u32)4)
                {
                if (o.isSym() && !symIsDiff(o) && _rr != (Array*)0)
                    _rr.add((Object*)Number.withU32(_d.length()));
                a32((u32)symVal(syms, o));
                }
            else
                {
                // A word immediate, signed or unsigned (#289).
                i32 iv = symVal(syms, o);
                if (_rr != (Array*)0 && (iv < (i32)-32768 || iv > (i32)65535))
                    fail(String.withFormat("immediate %ld does not fit 16 bits", iv));
                a16((u32)iv & (u32)$FFFF);
                }
            }
        }

    static i32 branchCC(u16 mc)
        {
        if (mc == m68Bra)
            return (i32)0;
        if (mc == m68Bsr)
            return (i32)1;
        if (mc == m68Bhi)
            return (i32)2;
        if (mc == m68Bls)
            return (i32)3;
        if (mc == m68Bcc || mc == m68Bhs)
            return (i32)4;
        if (mc == m68Bcs || mc == m68Blo)
            return (i32)5;
        if (mc == m68Bne)
            return (i32)6;
        if (mc == m68Beq)
            return (i32)7;
        if (mc == m68Bvc)
            return (i32)8;
        if (mc == m68Bvs)
            return (i32)9;
        if (mc == m68Bpl)
            return (i32)10;
        if (mc == m68Bmi)
            return (i32)11;
        if (mc == m68Bge)
            return (i32)12;
        if (mc == m68Blt)
            return (i32)13;
        if (mc == m68Bgt)
            return (i32)14;
        if (mc == m68Ble)
            return (i32)15;
        return (i32)-1;
        }

    static i32 sccCC(u16 mc)
        {
        if (mc == m68St)
            return (i32)0;
        if (mc == m68Sf)
            return (i32)1;
        if (mc == m68Shi)
            return (i32)2;
        if (mc == m68Sls)
            return (i32)3;
        if (mc == m68Scc || mc == m68Shs)
            return (i32)4;
        if (mc == m68Scs || mc == m68Slo)
            return (i32)5;
        if (mc == m68Sne)
            return (i32)6;
        if (mc == m68Seq)
            return (i32)7;
        if (mc == m68Svc)
            return (i32)8;
        if (mc == m68Svs)
            return (i32)9;
        if (mc == m68Spl)
            return (i32)10;
        if (mc == m68Smi)
            return (i32)11;
        if (mc == m68Sge)
            return (i32)12;
        if (mc == m68Slt)
            return (i32)13;
        if (mc == m68Sgt)
            return (i32)14;
        if (mc == m68Sle)
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

    Data* encode(String* mnem, u32 size, Array* ops, Map* syms, u32 curOff, Array* rr)
        {
        _d = new Data();
        _rr = rr;
        _hit = false;
        // The encoders test this number, not the String (#330).
        u16 mc = M68kMn.find(mnem);

        if (mc == m68DcL || mc == m68DcW)
            return encodeDc(mnem, mc, ops, syms);

        MOp* o0 = ops.count() > (u32)0 ? parseOperand((String*)ops.get((u32)0)) : new MOp();
        MOp* o1 = ops.count() > (u32)1 ? parseOperand((String*)ops.get((u32)1)) : new MOp();
        if (_failed)
            return (Data*)0;

        u32 sb = size == (u32)1 ? (u32)0 : size == (u32)2 ? (u32)1
                                                          : (u32)2;

        encFpuBranch(mnem, mc, o0, syms, curOff);
        if (_hit)
            return _d;
        encBranch(mnem, mc, o0, syms, curOff);
        if (_hit)
            return _d;
        encMoves(mnem, mc, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Data*)0 : _d;
        encAlu(mnem, mc, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Data*)0 : _d;
        encUnary(mnem, mc, size, sb, o0, o1, syms);
        if (_hit || _failed)
            return _failed ? (Data*)0 : _d;
        encMulDiv(mnem, mc, size, o0, o1, syms);
        if (_hit)
            return _d;
        encFpu(mnem, mc, size, o0, o1, syms);
        if (_hit)
            return _d;
        encControl(mnem, mc, size, o0, o1, syms, curOff);
        if (_hit || _failed)
            return _failed ? (Data*)0 : _d;

        String* m = String.withCString("unsupported mnemonic '");
        m.append(mnem);
        m.appendCString("'");
        fail(m);
        return (Data*)0;
        }

    // `.dc.l` of a symbol emits a relocated four-byte pointer; `symA-symB` is a
    // relocation-free difference (a PIC vtable slot holding method - base).
    Data* encodeDc(String* mnem, u16 mc, Array* ops, Map* syms)
        {
        bool isLong = mc == m68DcL;
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
                if (e.kind() == (u32)MOP_ABS && e.isSym() && _rr != (Data*)0)
                    _rr.add((Object*)Number.withU32(_d.length()));
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
    void encFpuBranch(String* mnem, u16 mc, MOp* o0, Map* syms, u32 curOff)
        {
        i32 p = fbCode(mc);
        if (p < (i32)0)
            return;
        i32 target = symVal(syms, o0);
        a16((u32)$F280 | (u32)p);
        if (!pcDisp16Ok(target - (i32)(curOff + (u32)2)))
            fail(String.withFormat("%s: branch out of the 16-bit range", mnem.cString()));
        a16((u32)(target - (i32)(curOff + (u32)2)) & (u32)$FFFF);
        _hit = true;
        }

    static i32 fbCode(u16 mc)
        {
        if (mc == m68Fbeq)
            return (i32)$01;
        if (mc == m68Fbne)
            return (i32)$0E;
        if (mc == m68Fbgt)
            return (i32)$12;
        if (mc == m68Fbge)
            return (i32)$13;
        if (mc == m68Fblt)
            return (i32)$14;
        if (mc == m68Fble)
            return (i32)$15;
        return (i32)-1;
        }

    // Always the word form, so pass 1 and pass 2 size it the same.
    void encBranch(String* mnem, u16 mc, MOp* o0, Map* syms, u32 curOff)
        {
        i32 cc = branchCC(mc);
        if (cc < (i32)0)
            return;
        i32 target = symVal(syms, o0);
        i32 disp = target - (i32)(curOff + (u32)2);
        a16((u32)$6000 | ((u32)cc << (u32)8));
        if (!pcDisp16Ok(disp))
            fail(String.withFormat("%s: branch out of the 16-bit range", mnem.cString()));
        a16((u32)disp & (u32)$FFFF);
        _hit = true;
        }

    void encMoves(String* mnem, u16 mc, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        if (mc == m68Move || mc == m68Movea)
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
        if (mc == m68Moveq)
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
    void encAlu(String* mnem, u16 mc, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        // adda/suba/cmpa are the add/sub/cmp forms with an address register
        // destination, which the code generator now names (#289).
        if (mc == m68Adda)
            mc = m68Add;
        else if (mc == m68Suba)
            mc = m68Sub;
        else if (mc == m68Cmpa)
            mc = m68Cmp;
        i32 base = aluBase(mc);
        if (base < (i32)0)
            return;
        bool isEor = mc == m68Eor;
        bool isCmp = mc == m68Cmp;
        // the xxxI forms; an address register takes an immediate only through
        // ADDA/SUBA/CMPA #imm,An (ADDI to An does not exist), below
        if (o0.kind() == (u32)MOP_IMM && o1.kind() != (u32)MOP_AREG)
            {
            i32 ik = aluImmKind(mc);
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

    static i32 aluBase(u16 mc)
        {
        if (mc == m68Add)
            return (i32)$D000;
        if (mc == m68Sub)
            return (i32)$9000;
        if (mc == m68And)
            return (i32)$C000;
        if (mc == m68Or)
            return (i32)$8000;
        if (mc == m68Cmp)
            return (i32)$B000;
        if (mc == m68Eor)
            return (i32)$B000;
        return (i32)-1;
        }

    static i32 aluImmKind(u16 mc)
        {
        if (mc == m68Or)
            return (i32)0;
        if (mc == m68And)
            return (i32)1;
        if (mc == m68Sub)
            return (i32)2;
        if (mc == m68Add)
            return (i32)3;
        if (mc == m68Eor)
            return (i32)5;
        if (mc == m68Cmp)
            return (i32)6;
        return (i32)0;
        }

    // ── Shifts, quick arithmetic, Scc, the single-EA unaries ─────────────
    void encUnary(String* mnem, u16 mc, u32 size, u32 sb, MOp* o0, MOp* o1, Map* syms)
        {
        i32 sh = shiftType(mc);
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
        bool isAddq = mc == m68Addq;
        if (isAddq || mc == m68Subq)
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
        i32 sc = sccCC(mc);
        if (sc >= (i32)0)
            {
            a16((u32)$50C0 | ((u32)sc << (u32)8) | eaField(o0));
            appendExt(o0, (u32)1, syms);
            _hit = true;
            return;
            }
        i32 un = unaryBase(mc);
        if (un >= (i32)0)
            {
            a16((u32)un | (sb << (u32)6) | eaField(o0));
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        if (mc == m68Ext)
            {
            a16((size == (u32)4 ? (u32)$48C0 : (u32)$4880) | o0.reg());
            _hit = true;
            return;
            }
        if (mc == m68Swap)
            {
            a16((u32)$4840 | o0.reg());
            _hit = true;
            return;
            }
        bool isAddx = mc == m68Addx;
        if (isAddx || mc == m68Subx)
            {
            a16((isAddx ? (u32)$D100 : (u32)$9100) | (o1.reg() << (u32)9) | (sb << (u32)6) | o0.reg());
            _hit = true;
            return;
            }
        if (mc == m68Exg)
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

    static i32 shiftType(u16 mc)
        {
        if (mc == m68Asl || mc == m68Asr)
            return (i32)0;
        if (mc == m68Lsl || mc == m68Lsr)
            return (i32)1;
        if (mc == m68Roxl || mc == m68Roxr)
            return (i32)2;
        if (mc == m68Rol || mc == m68Ror)
            return (i32)3;
        return (i32)-1;
        }

    static i32 unaryBase(u16 mc)
        {
        if (mc == m68Negx)
            return (i32)$4000;
        if (mc == m68Clr)
            return (i32)$4200;
        if (mc == m68Neg)
            return (i32)$4400;
        if (mc == m68Not)
            return (i32)$4600;
        if (mc == m68Tst)
            return (i32)$4A00;
        return (i32)-1;
        }

    // ── Multiply and divide ──────────────────────────────────────────────
    void encMulDiv(String* mnem, u16 mc, u32 size, MOp* o0, MOp* o1, Map* syms)
        {
        bool isMuls = mc == m68Muls;
        if (isMuls || mc == m68Mulu)
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
        bool isDivs = mc == m68Divs;
        if (isDivs || mc == m68Divu)
            {
            a16((u32)$4C40 | eaField(o0));
            a16((o1.reg() << (u32)12) | (isDivs ? (u32)$0800 : (u32)0) | o1.reg());
            appendExt(o0, size, syms);
            _hit = true;
            return;
            }
        }

    // ── 68881/68882 FPU (line F, coprocessor id 1) ───────────────────────
    void encFpu(String* mnem, u16 mc, u32 size, MOp* o0, MOp* o1, Map* syms)
        {
        i32 opm = fpuOpmode(mc);
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
            if (mc == m68Fmove && o0.kind() == MOP_FREG && o1.kind() != MOP_FREG)
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
        i32 fc = fsccCode(mc);
        if (fc >= (i32)0)
            {
            a16((u32)$F240 | eaField(o0));
            a16((u32)fc);
            appendExt(o0, (u32)1, syms);
            _hit = true;
            return;
            }
        }

    static i32 fpuOpmode(u16 mc)
        {
        if (mc == m68Fmove)
            return (i32)$00;
        if (mc == m68Fadd)
            return (i32)$22;
        if (mc == m68Fsub)
            return (i32)$28;
        if (mc == m68Fmul)
            return (i32)$23;
        if (mc == m68Fdiv)
            return (i32)$20;
        if (mc == m68Fneg)
            return (i32)$1A;
        if (mc == m68Fabs)
            return (i32)$18;
        if (mc == m68Fcmp)
            return (i32)$38;
        if (mc == m68Fsqrt)
            return (i32)$04;
        if (mc == m68Fintrz)
            return (i32)$03;
        if (mc == m68Fint)
            return (i32)$01;
        if (mc == m68Ftst)
            return (i32)$3A;
        if (mc == m68Fsin)
            return (i32)$0E;
        if (mc == m68Fcos)
            return (i32)$1D;
        if (mc == m68Ftan)
            return (i32)$0F;
        if (mc == m68Fasin)
            return (i32)$0C;
        if (mc == m68Facos)
            return (i32)$1C;
        if (mc == m68Fatan)
            return (i32)$0A;
        if (mc == m68Fetox)
            return (i32)$10;
        if (mc == m68Flogn)
            return (i32)$14;
        if (mc == m68Flog10)
            return (i32)$15;
        if (mc == m68Flog2)
            return (i32)$16;
        if (mc == m68Ftwotox)
            return (i32)$11;
        if (mc == m68Ftentox)
            return (i32)$12;
        if (mc == m68Fsinh)
            return (i32)$02;
        if (mc == m68Fcosh)
            return (i32)$19;
        if (mc == m68Ftanh)
            return (i32)$09;
        return (i32)-1;
        }

    static i32 fsccCode(u16 mc)
        {
        if (mc == m68Fseq)
            return (i32)$01;
        if (mc == m68Fsne)
            return (i32)$0E;
        if (mc == m68Fsgt)
            return (i32)$12;
        if (mc == m68Fsge)
            return (i32)$13;
        if (mc == m68Fslt)
            return (i32)$14;
        if (mc == m68Fsle)
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
    void encControl(String* mnem, u16 mc, u32 size, MOp* o0, MOp* o1, Map* syms, u32 curOff)
        {
        bool picSym = o0.kind() == (u32)MOP_ABS && o0.isSym();
        bool wide = _cpu >= (u32)68020;
        bool got = _gotMode && picSym && !symIsDiff(o0);

        if (mc == m68Jsr)
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
        if (mc == m68Jmp)
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
        if (mc == m68Pea)
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
        if (mc == m68Lea)
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
        if (mc == m68Link)
            {
            a16((u32)$4E50 | o0.reg());
            a16((u32)o1.value() & (u32)$FFFF);
            _hit = true;
            return;
            }
        if (mc == m68Unlk)
            {
            a16((u32)$4E58 | o0.reg());
            _hit = true;
            return;
            }
        if (mc == m68Rts)
            {
            a16((u32)$4E75);
            _hit = true;
            return;
            }
        if (mc == m68Rte)
            {
            a16((u32)$4E73);
            _hit = true;
            return;
            }
        if (mc == m68Rtr)
            {
            a16((u32)$4E77);
            _hit = true;
            return;
            }
        if (mc == m68Nop)
            {
            a16((u32)$4E71);
            _hit = true;
            return;
            }
        // ILLEGAL ($4AFC) — the architecturally-guaranteed illegal instruction,
        // which is how the back end lowers `Unreachable` (a failed checked
        // downcast). A mnemonic the code generator emits and the assembler does
        // not know is exactly the gap the no-fallback rule exists to expose.
        if (mc == m68Illegal)
            {
            a16((u32)$4AFC);
            _hit = true;
            return;
            }
        if (mc == m68Trap)
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
    Data* dataForDir(String* dir, String* args, u32 curOff)
        {
        Data* d = new Data();
        if (dir.equals(String.withCString(".even")))
            {
            if ((curOff & (u32)1) != (u32)0)
                d.appendByte((u8)0);
            return d;
            }
        if (dir.equals(String.withCString(".ascii")) || dir.equals(String.withCString(".asciz")))
            {
            Data* bytes = GasString.decode(args, dir.equals(String.withCString(".asciz")));
            if (bytes == (Data*)0)
                {
                fail(String.withCString("bad string directive"));
                return d;
                }
            return bytes;
            }
        if (dir.equals(String.withCString(".space")) || dir.equals(String.withCString(".ds.b")))
            {
            i32 n = parseNum(args);
            if (_numOk)
                for (i32 k = (i32)0; k < n; k = k + (i32)1)
                    d.appendByte((u8)0);
            return d;
            }
        if (dir.equals(String.withCString(".dc.b")) || dir.equals(String.withCString(".byte")))
            {
            Array* toks = splitOperands(args);
            for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
                {
                i32 v = parseNum((String*)toks.get(i));
                if (_numOk)
                    d.appendByte((u8)((u32)v & (u32)$FF));
                }
            return d;
            }
        return d;
        }

    // ── The two passes, and the $601A image ──────────────────────────────
    //
    // Segments lie contiguously — GEMDOS loads text and data adjacently and
    // zeroes bss after — so offsets run sequentially across all three and the
    // pass only records where .data and .bss begin, to split the sizes.
    Data* _image; // the finished executable

    Data* image(void)
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
                off = off + dataForDir(dir, (String*)_itemB.get(i), off).length();
                continue;
                }
            Data* enc = encode((String*)_itemA.get(i), ((Number*)_itemSize.get(i)).asU32(),
                                (Array*)_itemB.get(i), syms, off, (Array*)0);
            if (enc == (Array*)0)
                {
                if (!_failed)
                    fail(String.withCString("encode error (pass 1)"));
                return;
                }
            off = off + enc.length();
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
        Data* text = new Data();
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
                Data* dd = dataForDir(dir, (String*)_itemB.get(i), text.length());
                text.append(dd);
                continue;
                }
            if (inBss)
                continue;
            Array* rr = new Array();
            u32 base = text.length();
            _missingSym = (String*)0;
            Data* enc = encode((String*)_itemA.get(i), ((Number*)_itemSize.get(i)).asU32(),
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
            text.append(enc);
            }
        // The GOT: one relocated longword per referenced symbol, in slot order.
        if (_gotMode)
            {
            for (u32 i = (u32)0; i < _gotOrder.count(); i = i + (u32)1)
                {
                String* sym = (String*)_gotOrder.get(i);
                relocs.add((Object*)Number.withU32(text.length()));
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
                text.appendByte((u8)((v >> (u32)24) & (u32)$FF));
                text.appendByte((u8)((v >> (u32)16) & (u32)$FF));
                text.appendByte((u8)((v >> (u32)8) & (u32)$FF));
                text.appendByte((u8)(v & (u32)$FF));
                }
            }
        emit601A(text, relocs, tsize, dsize, bsize);
        }

    void emit601A(Data* text, Array* relocs, u32 tsize, u32 dsize, u32 bsize)
        {
        _d = new Data();
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
        _image = new Data();
        _image.append(_d);
        _image.append(text);

        // The DRI relocation stream: the first fixup as a longword, then one
        // advance byte per subsequent fixup, where 1 means "skip 254".
        sortNumbers(relocs);
        if (relocs.count() == (u32)0)
            {
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                _image.appendByte((u8)0);
            return;
            }
        u32 prev = ((Number*)relocs.get((u32)0)).asU32();
        _image.appendByte((u8)((prev >> (u32)24) & (u32)$FF));
        _image.appendByte((u8)((prev >> (u32)16) & (u32)$FF));
        _image.appendByte((u8)((prev >> (u32)8) & (u32)$FF));
        _image.appendByte((u8)(prev & (u32)$FF));
        for (u32 i = (u32)1; i < relocs.count(); i = i + (u32)1)
            {
            u32 cur = ((Number*)relocs.get(i)).asU32();
            u32 delta = cur - prev;
            while (delta > (u32)254)
                {
                _image.appendByte((u8)1);
                delta = delta - (u32)254;
                }
            _image.appendByte((u8)(delta & (u32)$FF));
            prev = cur;
            }
        _image.appendByte((u8)0);
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
