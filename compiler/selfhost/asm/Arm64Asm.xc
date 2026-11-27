// Arm64.xc — the AArch64 assembler, in xtc.
// =================================================================
//
// self-hosting M18, a port of `XAArm64Assembler`. It encodes the subset the
// arm64 back end emits (plus what clang emits in the host runtime the driver
// links alongside) into machine code, and byte-parity with the original — which
// is itself byte-parity with `clang -c` — is the bar.
//
// Two things shape the code more than the instruction set does.
//
// An assembler that quietly drops an instruction produces an object file that
// LINKS and then crashes somewhere unrelated, so an unrecognised mnemonic is an
// error by NAME, never a skip. The same reasoning runs through the branch
// range checks: masking an out-of-range displacement into its field yields a
// valid-looking instruction that jumps somewhere else entirely.
//
// And everything the linker has to finish — a call to another object, an
// `adrp`/`add` symbol pair, a `.quad` pointer — leaves a FIXUP behind rather
// than a guessed value.

#import "Foundation.xc"
#import <U64>
#import <SortStable>
#import <DwarfWriter>
#import <SectionBytes>
#import <GasString>

#import "Arm64AsmDefs.xc"

class Arm64Fixup
{
    u32     _offset;
    u32     _kind;
    String* _symbol;
    u32     _scale;         // PageOff12: log2 of the access size; 0 for `add`
    i32     _addend;        // sym + addend; only the archive reader sets it

    void init(void) { _offset = (u32)0; _kind = (u32)0; _scale = (u32)0; _addend = (i32)0; }

    static Arm64Fixup* make(u32 off, u32 kind, String* sym, u32 scale)
    {
        Arm64Fixup* f = new Arm64Fixup();
        f._offset = off; f._kind = kind; f._symbol = sym; f._scale = scale;
        return f;
    }

    u32     offset(void) { return _offset; }
    u32     kind(void)   { return _kind; }
    String* symbol(void) { return _symbol; }
    u32     scale(void)  { return _scale; }
    i32     addend(void) { return _addend; }
    // The linker rewrites fixups it merged from foreign objects (bug 138): a
    // GOT kind relaxed once its target turned out to be in the image, a data
    // slot moved by the ObjC repartition, an ADDEND carried from the reloc
    // before it.
    void    setOffset(u32 o) { _offset = o; }
    void    setKind(u32 k)   { _kind = k; }
    void    setScale(u32 s)  { _scale = s; }
    void    setAddend(i32 a) { _addend = a; }
}

// A parsed register. `ok` is false when the text was not a register at all,
// which is how the operand shapes are told apart — `mov` with a register second
// operand is a different instruction from `mov` with an immediate.
class RegRef
{
    bool _ok;
    u32  _num;
    bool _is64;
    bool _isSP;
    void init(void) { _ok = false; _num = (u32)0; _is64 = false; _isSP = false; }
    bool ok(void)   { return _ok; }
    u32  num(void)  { return _num; }
    bool is64(void) { return _is64; }
    bool isSP(void) { return _isSP; }
    static RegRef* no(void) { return new RegRef(); }
    static RegRef* yes(u32 n, bool w64, bool sp)
    { RegRef* r = new RegRef(); r._ok = true; r._num = n; r._is64 = w64; r._isSP = sp; return r; }
}

// A scalar FP/SIMD register: size 0=b 1=h 2=s 3=d 4=q.
class FRegRef
{
    bool _ok;
    u32  _num;
    u32  _sz;
    void init(void) { _ok = false; _num = (u32)0; _sz = (u32)0; }
    bool ok(void)  { return _ok; }
    u32  num(void) { return _num; }
    u32  sz(void)  { return _sz; }
    static FRegRef* no(void) { return new FRegRef(); }
    static FRegRef* yes(u32 n, u32 z)
    { FRegRef* r = new FRegRef(); r._ok = true; r._num = n; r._sz = z; return r; }
}

// A NEON register `vN.<arrangement>`, or one lane of one (`vN.s[1]`).
// An SME/SVE operand: a predicate (num, size or -1 as $FFFF_FFFF), a Z
// register (num, size), a ZA slice (tile, vert, size, rs = Ws-12, off) or an
// SVE address (rn, rm or $FFFF_FFFF, lsl).
class SmeRef
{
    bool _ok;
    u32  _a;
    u32  _b;
    u32  _c;
    u32  _d;
    u32  _e;
    void init(void) { _ok = false; _a = (u32)0; _b = (u32)0; _c = (u32)0; _d = (u32)0; _e = (u32)0; }
    bool ok(void) { return _ok; }
    u32  a(void)  { return _a; }
    u32  b(void)  { return _b; }
    u32  c(void)  { return _c; }
    u32  d(void)  { return _d; }
    u32  e(void)  { return _e; }
    static SmeRef* no(void) { return new SmeRef(); }
    static SmeRef* yes(u32 a, u32 b, u32 c, u32 d, u32 e)
    { SmeRef* r = new SmeRef(); r._ok = true; r._a = a; r._b = b; r._c = c; r._d = d; r._e = e; return r; }
}

class VRegRef
{
    bool _ok;
    u32  _num;
    u32  _size;     // element size: 0=b 1=h 2=s 3=d
    u32  _q;        // 1 for the 128-bit arrangements
    u32  _idx;      // lane index, for the element form
    void init(void) { _ok = false; }
    bool ok(void)   { return _ok; }
    u32  num(void)  { return _num; }
    u32  size(void) { return _size; }
    u32  q(void)    { return _q; }
    u32  idx(void)  { return _idx; }
    static VRegRef* no(void) { return new VRegRef(); }
    static VRegRef* yes(u32 n, u32 sz, u32 q, u32 idx)
    { VRegRef* r = new VRegRef(); r._ok = true; r._num = n; r._size = sz; r._q = q; r._idx = idx; return r; }
}

// Mnemonics as numbers. encodeLine looks the mnemonic up once, and the
// encoders and their tables compare the number instead of the String, each
// comparison of which built and freed a String. Every mnemonic an encoder
// tests is here, plus the operation names lseOpcFor reads off an LSE atomic
// (`clr`, `set`). Anything else is a64Unknown and still reaches the
// "unhandled mnemonic" error. The numbering is private to the process.
enum Arm64Mnemonic = {
    a64Unknown = 0,
    a64Abs, a64Add, a64Adds, a64Addv, a64Adr, a64Adrp,
    a64And, a64Ands, a64Asr, a64B, a64Bic, a64Bics,
    a64Bif, a64Bit, a64Bl, a64Blr, a64Br, a64Brk,
    a64Bsl, a64Cbnz, a64Cbz, a64Ccmn, a64Ccmp, a64Cinc,
    a64Cinv, a64Clr, a64Clrex, a64Cmeq, a64Cmge, a64Cmgt,
    a64Cmhi, a64Cmhs, a64Cmn, a64Cmp, a64Cmphi, a64Cneg,
    a64Cnt, a64Cntb, a64Cntd, a64Cnth, a64Cntw, a64Csel,
    a64Cset, a64Csetm, a64Csinc, a64Csinv, a64Csneg, a64Dmb,
    a64Dsb, a64Dup, a64Dupm, a64Eon, a64Eor, a64Ext,
    a64Fabs, a64Fadd, a64Faddp, a64Fcmeq, a64Fcmge, a64Fcmgt,
    a64Fcmp, a64Fcmuo, a64Fcsel, a64Fcvt, a64Fcvtzs, a64Fcvtzu,
    a64Fdiv, a64Fmadd, a64Fmax, a64Fmin, a64Fmla, a64Fmls,
    a64Fmopa, a64Fmov, a64Fmsub, a64Fmul, a64Fneg, a64Fnmadd,
    a64Fnmsub, a64Frintz, a64Fsqrt, a64Fsub, a64Hlt, a64Isb,
    a64Ld1, a64Ld1d, a64Ld1w, a64Ldp, a64Ldr, a64Ldrb,
    a64Ldrh, a64Ldrsb, a64Ldrsh, a64Ldrsw, a64Ldur, a64Ldurb,
    a64Ldurh, a64Ldursb, a64Ldursh, a64Ldursw, a64Lsl, a64Lsr,
    a64Madd, a64Mla, a64Mls, a64Mov, a64Mova, a64Movk,
    a64Movn, a64Movz, a64Msub, a64Msubl, a64Mul, a64Mvn,
    a64Neg, a64Nop, a64Not, a64Orn, a64Orr, a64Pfalse,
    a64Ptest, a64Ptrue, a64Rdsvl, a64Ret, a64Rev16, a64Rev32,
    a64Rev64, a64Ror, a64Saba, a64Sabd, a64Saddlp, a64Saddlv,
    a64Scvtf, a64Sdiv, a64Set, a64Shl, a64Sli, a64Smaddl,
    a64Smax, a64Smaxv, a64Smin, a64Sminv, a64Smopa, a64Smstart,
    a64Smstop, a64Smulh, a64Smull, a64Smull2, a64Sshl, a64Sshr,
    a64St1, a64St1d, a64St1w, a64Stp, a64Str, a64Strb,
    a64Strh, a64Stur, a64Sturb, a64Sturh, a64Sub, a64Subs,
    a64Sumopa, a64Svc, a64Sxtb, a64Sxth, a64Sxtw, a64Tbnz,
    a64Tbz, a64Trn1, a64Trn2, a64Tst, a64Uaba, a64Uabd,
    a64Uaddlp, a64Uaddlv, a64Ucvtf, a64Udiv, a64Umaddl, a64Umax,
    a64Umaxv, a64Umin, a64Uminv, a64Umopa, a64Umulh, a64Umull,
    a64Umull2, a64Ushl, a64Ushr, a64Usmopa, a64Usra, a64Uxtb,
    a64Uxth, a64Uxtw, a64Uzp1, a64Uzp2, a64Whilelo, a64Whilelt,
    a64Zero, a64Zip1, a64Zip2,
    a64Fcvtl, a64Fcvtl2, a64Fcvtn, a64Fcvtn2, a64Xtn, a64Xtn2,
    a64Ushll, a64Ushll2, a64Shll, a64Shll2
};

class Arm64Mn
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
        Arm64Mn.def(a64Abs, "abs"); Arm64Mn.def(a64Add, "add"); Arm64Mn.def(a64Adds, "adds");
        Arm64Mn.def(a64Addv, "addv"); Arm64Mn.def(a64Adr, "adr"); Arm64Mn.def(a64Adrp, "adrp");
        Arm64Mn.def(a64And, "and"); Arm64Mn.def(a64Ands, "ands"); Arm64Mn.def(a64Asr, "asr");
        Arm64Mn.def(a64B, "b"); Arm64Mn.def(a64Bic, "bic"); Arm64Mn.def(a64Bics, "bics");
        Arm64Mn.def(a64Bif, "bif"); Arm64Mn.def(a64Bit, "bit"); Arm64Mn.def(a64Bl, "bl");
        Arm64Mn.def(a64Blr, "blr"); Arm64Mn.def(a64Br, "br"); Arm64Mn.def(a64Brk, "brk");
        Arm64Mn.def(a64Bsl, "bsl"); Arm64Mn.def(a64Cbnz, "cbnz"); Arm64Mn.def(a64Cbz, "cbz");
        Arm64Mn.def(a64Ccmn, "ccmn"); Arm64Mn.def(a64Ccmp, "ccmp"); Arm64Mn.def(a64Cinc, "cinc");
        Arm64Mn.def(a64Cinv, "cinv"); Arm64Mn.def(a64Clr, "clr"); Arm64Mn.def(a64Clrex, "clrex");
        Arm64Mn.def(a64Cmeq, "cmeq"); Arm64Mn.def(a64Cmge, "cmge"); Arm64Mn.def(a64Cmgt, "cmgt");
        Arm64Mn.def(a64Cmhi, "cmhi"); Arm64Mn.def(a64Cmhs, "cmhs"); Arm64Mn.def(a64Cmn, "cmn");
        Arm64Mn.def(a64Cmp, "cmp"); Arm64Mn.def(a64Cmphi, "cmphi"); Arm64Mn.def(a64Cneg, "cneg");
        Arm64Mn.def(a64Cnt, "cnt"); Arm64Mn.def(a64Cntb, "cntb"); Arm64Mn.def(a64Cntd, "cntd");
        Arm64Mn.def(a64Cnth, "cnth"); Arm64Mn.def(a64Cntw, "cntw"); Arm64Mn.def(a64Csel, "csel");
        Arm64Mn.def(a64Cset, "cset"); Arm64Mn.def(a64Csetm, "csetm"); Arm64Mn.def(a64Csinc, "csinc");
        Arm64Mn.def(a64Csinv, "csinv"); Arm64Mn.def(a64Csneg, "csneg"); Arm64Mn.def(a64Dmb, "dmb");
        Arm64Mn.def(a64Dsb, "dsb"); Arm64Mn.def(a64Dup, "dup"); Arm64Mn.def(a64Dupm, "dupm");
        Arm64Mn.def(a64Eon, "eon"); Arm64Mn.def(a64Eor, "eor"); Arm64Mn.def(a64Ext, "ext");
        Arm64Mn.def(a64Fabs, "fabs"); Arm64Mn.def(a64Fadd, "fadd"); Arm64Mn.def(a64Faddp, "faddp");
        Arm64Mn.def(a64Fcmeq, "fcmeq"); Arm64Mn.def(a64Fcmge, "fcmge"); Arm64Mn.def(a64Fcmgt, "fcmgt");
        Arm64Mn.def(a64Fcmp, "fcmp"); Arm64Mn.def(a64Fcmuo, "fcmuo"); Arm64Mn.def(a64Fcsel, "fcsel");
        Arm64Mn.def(a64Fcvt, "fcvt"); Arm64Mn.def(a64Fcvtzs, "fcvtzs"); Arm64Mn.def(a64Fcvtzu, "fcvtzu");
        Arm64Mn.def(a64Fdiv, "fdiv"); Arm64Mn.def(a64Fmadd, "fmadd"); Arm64Mn.def(a64Fmax, "fmax");
        Arm64Mn.def(a64Fmin, "fmin"); Arm64Mn.def(a64Fmla, "fmla"); Arm64Mn.def(a64Fmls, "fmls");
        Arm64Mn.def(a64Fmopa, "fmopa"); Arm64Mn.def(a64Fmov, "fmov"); Arm64Mn.def(a64Fmsub, "fmsub");
        Arm64Mn.def(a64Fmul, "fmul"); Arm64Mn.def(a64Fneg, "fneg"); Arm64Mn.def(a64Fnmadd, "fnmadd");
        Arm64Mn.def(a64Fnmsub, "fnmsub"); Arm64Mn.def(a64Frintz, "frintz"); Arm64Mn.def(a64Fsqrt, "fsqrt");
        Arm64Mn.def(a64Fsub, "fsub"); Arm64Mn.def(a64Hlt, "hlt"); Arm64Mn.def(a64Isb, "isb");
        Arm64Mn.def(a64Ld1, "ld1"); Arm64Mn.def(a64Ld1d, "ld1d"); Arm64Mn.def(a64Ld1w, "ld1w");
        Arm64Mn.def(a64Ldp, "ldp"); Arm64Mn.def(a64Ldr, "ldr"); Arm64Mn.def(a64Ldrb, "ldrb");
        Arm64Mn.def(a64Ldrh, "ldrh"); Arm64Mn.def(a64Ldrsb, "ldrsb"); Arm64Mn.def(a64Ldrsh, "ldrsh");
        Arm64Mn.def(a64Ldrsw, "ldrsw"); Arm64Mn.def(a64Ldur, "ldur"); Arm64Mn.def(a64Ldurb, "ldurb");
        Arm64Mn.def(a64Ldurh, "ldurh"); Arm64Mn.def(a64Ldursb, "ldursb"); Arm64Mn.def(a64Ldursh, "ldursh");
        Arm64Mn.def(a64Ldursw, "ldursw"); Arm64Mn.def(a64Lsl, "lsl"); Arm64Mn.def(a64Lsr, "lsr");
        Arm64Mn.def(a64Madd, "madd"); Arm64Mn.def(a64Mla, "mla"); Arm64Mn.def(a64Mls, "mls");
        Arm64Mn.def(a64Mov, "mov"); Arm64Mn.def(a64Mova, "mova"); Arm64Mn.def(a64Movk, "movk");
        Arm64Mn.def(a64Movn, "movn"); Arm64Mn.def(a64Movz, "movz"); Arm64Mn.def(a64Msub, "msub");
        Arm64Mn.def(a64Msubl, "msubl"); Arm64Mn.def(a64Mul, "mul"); Arm64Mn.def(a64Mvn, "mvn");
        Arm64Mn.def(a64Neg, "neg"); Arm64Mn.def(a64Nop, "nop"); Arm64Mn.def(a64Not, "not");
        Arm64Mn.def(a64Orn, "orn"); Arm64Mn.def(a64Orr, "orr"); Arm64Mn.def(a64Pfalse, "pfalse");
        Arm64Mn.def(a64Ptest, "ptest"); Arm64Mn.def(a64Ptrue, "ptrue"); Arm64Mn.def(a64Rdsvl, "rdsvl");
        Arm64Mn.def(a64Ret, "ret"); Arm64Mn.def(a64Rev16, "rev16"); Arm64Mn.def(a64Rev32, "rev32");
        Arm64Mn.def(a64Rev64, "rev64"); Arm64Mn.def(a64Ror, "ror"); Arm64Mn.def(a64Saba, "saba");
        Arm64Mn.def(a64Sabd, "sabd"); Arm64Mn.def(a64Saddlp, "saddlp"); Arm64Mn.def(a64Saddlv, "saddlv");
        Arm64Mn.def(a64Scvtf, "scvtf"); Arm64Mn.def(a64Sdiv, "sdiv"); Arm64Mn.def(a64Set, "set");
        Arm64Mn.def(a64Shl, "shl"); Arm64Mn.def(a64Sli, "sli"); Arm64Mn.def(a64Smaddl, "smaddl");
        Arm64Mn.def(a64Smax, "smax"); Arm64Mn.def(a64Smaxv, "smaxv"); Arm64Mn.def(a64Smin, "smin");
        Arm64Mn.def(a64Sminv, "sminv"); Arm64Mn.def(a64Smopa, "smopa"); Arm64Mn.def(a64Smstart, "smstart");
        Arm64Mn.def(a64Smstop, "smstop"); Arm64Mn.def(a64Smulh, "smulh"); Arm64Mn.def(a64Smull, "smull");
        Arm64Mn.def(a64Smull2, "smull2"); Arm64Mn.def(a64Sshl, "sshl"); Arm64Mn.def(a64Sshr, "sshr");
        Arm64Mn.def(a64St1, "st1"); Arm64Mn.def(a64St1d, "st1d"); Arm64Mn.def(a64St1w, "st1w");
        Arm64Mn.def(a64Stp, "stp"); Arm64Mn.def(a64Str, "str"); Arm64Mn.def(a64Strb, "strb");
        Arm64Mn.def(a64Strh, "strh"); Arm64Mn.def(a64Stur, "stur"); Arm64Mn.def(a64Sturb, "sturb");
        Arm64Mn.def(a64Sturh, "sturh"); Arm64Mn.def(a64Sub, "sub"); Arm64Mn.def(a64Subs, "subs");
        Arm64Mn.def(a64Sumopa, "sumopa"); Arm64Mn.def(a64Svc, "svc"); Arm64Mn.def(a64Sxtb, "sxtb");
        Arm64Mn.def(a64Sxth, "sxth"); Arm64Mn.def(a64Sxtw, "sxtw"); Arm64Mn.def(a64Tbnz, "tbnz");
        Arm64Mn.def(a64Tbz, "tbz"); Arm64Mn.def(a64Trn1, "trn1"); Arm64Mn.def(a64Trn2, "trn2");
        Arm64Mn.def(a64Tst, "tst"); Arm64Mn.def(a64Uaba, "uaba"); Arm64Mn.def(a64Uabd, "uabd");
        Arm64Mn.def(a64Uaddlp, "uaddlp"); Arm64Mn.def(a64Uaddlv, "uaddlv"); Arm64Mn.def(a64Ucvtf, "ucvtf");
        Arm64Mn.def(a64Udiv, "udiv"); Arm64Mn.def(a64Umaddl, "umaddl"); Arm64Mn.def(a64Umax, "umax");
        Arm64Mn.def(a64Umaxv, "umaxv"); Arm64Mn.def(a64Umin, "umin"); Arm64Mn.def(a64Uminv, "uminv");
        Arm64Mn.def(a64Umopa, "umopa"); Arm64Mn.def(a64Umulh, "umulh"); Arm64Mn.def(a64Umull, "umull");
        Arm64Mn.def(a64Umull2, "umull2"); Arm64Mn.def(a64Ushl, "ushl"); Arm64Mn.def(a64Ushr, "ushr");
        Arm64Mn.def(a64Usmopa, "usmopa"); Arm64Mn.def(a64Usra, "usra"); Arm64Mn.def(a64Uxtb, "uxtb");
        Arm64Mn.def(a64Uxth, "uxth"); Arm64Mn.def(a64Uxtw, "uxtw"); Arm64Mn.def(a64Uzp1, "uzp1");
        Arm64Mn.def(a64Uzp2, "uzp2"); Arm64Mn.def(a64Whilelo, "whilelo"); Arm64Mn.def(a64Whilelt, "whilelt");
        Arm64Mn.def(a64Zero, "zero"); Arm64Mn.def(a64Zip1, "zip1"); Arm64Mn.def(a64Zip2, "zip2");
        Arm64Mn.def(a64Fcvtl, "fcvtl"); Arm64Mn.def(a64Fcvtl2, "fcvtl2"); Arm64Mn.def(a64Fcvtn, "fcvtn");
        Arm64Mn.def(a64Fcvtn2, "fcvtn2"); Arm64Mn.def(a64Xtn, "xtn"); Arm64Mn.def(a64Xtn2, "xtn2");
        Arm64Mn.def(a64Ushll, "ushll"); Arm64Mn.def(a64Ushll2, "ushll2"); Arm64Mn.def(a64Shll, "shll");
        Arm64Mn.def(a64Shll2, "shll2");
    }

    // The number of a mnemonic, or a64Unknown for one no encoder tests.
    static u16 find(String* mnemonic)
    {
        if (_byName == (Map*)0)
            Arm64Mn.build();
        Number* mc = (Number*)_byName.get((Hashable*)mnemonic);
        if (mc == (Number*)0)
            return a64Unknown;
        return mc.asU16();
    }
}

class Arm64Asm
{
    // The exception tables of the last text assembled (C/C++ input): per
    // function an Array@ [its label, the LSDA's bytes, Array@ of (Number
    // offset, String@ typeinfo) for each type-table entry], for the object
    // writer's __gcc_except_tab and its FDEs.
    static Array* _lsdas;
    static void setLsdas(Array* a) { _lsdas = a; }
    // ELF type tables: 8-byte entries (0x9c, a data word holding the
    // typeinfo, as clang's DW.stub), not Mach-O's 4-byte GOT slots (0x9b).
    static bool _lsdaElf;
    static void setLsdaElf(bool b) { _lsdaElf = b; }
    static Array* takeLsdas(void)
        {
        Array* a = _lsdas;
        _lsdas = (Array*)0;
        return a;
        }

    static Array* buildLsdas(Array* raw, Map* syms)
        {
        return DwarfWriter.buildLsdas(raw, syms, _lsdaElf ? (u32)$9C : (u32)$9B);
        }

    Array*  _fixups;        // Arm64Fixup@
    Map*    _symbols;       // name -> offset within its own section
    SectionBytes* _dataBytes; // the __data image
    u32 _dataAlign;           // the largest alignment anything in it asked for
    Array*  _dataSyms;      // String@, names that live in __data
    Array*  _globals;       // `.globl` names, in order
    Map*    _commonSyms;    // `.comm` COMMON: name -> [size, log2align] (bug 169)
    SectionBytes* _textBytes; // the __text image
    // Bug 066: the __DATA,__mod_init_func pointer array — the load-time
    // constructors — kept SEPARATE from _dataBytes, with its fixups' offsets
    // relative to itself. The linker appends it after every other contribution
    // to __data and shifts these fixups to match, then hands its length to the
    // writer, which gives it a real S_MOD_INIT_FUNC_POINTERS section. Without
    // that section TYPE dyld treats the pointers as inert data and no
    // constructor runs at all.
    //
    // Separate rather than "the tail of __data" because every object and
    // archive appends its own data during the link, so a range recorded here
    // would stop being the tail the moment anything else contributed.
    SectionBytes* _modInitBytes;
    Array*  _modInitFixups; // Arm64Fixup@
    bool    _failed;
    String* _why;

    void init(void)
    {
        _fixups = new Array(); _symbols = new Map();
        _dataBytes = new SectionBytes(); _dataAlign = (u32)1; _dataSyms = new Array(); _globals = new Array(); _textBytes = new SectionBytes();
        _commonSyms = new Map();
        _modInitBytes = new SectionBytes(); _modInitFixups = new Array();
        _failed = false;
    }

    Array*  fixups(void)     { return _fixups; }
    SectionBytes* modInitBytes(void) { return _modInitBytes; }
    Array*  modInitFixups(void) { return _modInitFixups; }

    // Bug 066 / bug 124: append the constructor pointer array to the END of
    // `dataBytes`, 8-aligned, shifting its fixups to match, and return its
    // length. Both writers describe that tail — Mach-O with an
    // S_MOD_INIT_FUNC_POINTERS section, ELF with DT_INIT_ARRAY — and a caller
    // that forgets to append it silently drops every load-time constructor,
    // with nothing to diagnose. One copy, because the android link, the APK
    // link and xtlnandroid must all produce the same bytes.
    static u32 appendModInit(Arm64Asm* as, SectionBytes* dataBytes, Array* fixups)
    {
        u32 miLen = as.modInitBytes().length();
        if (miLen == (u32)0) return (u32)0;
        dataBytes.padTo((u32)8);
        u32 base = dataBytes.length();
        dataBytes.append(as.modInitBytes());
        for (u32 i = (u32)0; i < as.modInitFixups().count(); i = i + (u32)1) {
            Arm64Fixup* f = (Arm64Fixup*)as.modInitFixups().get(i);
            Arm64Fixup* g = Arm64Fixup.make(base + f.offset(), f.kind(), f.symbol(), f.scale());
            g.setAddend(f.addend());
            fixups.add((Object*)g);
        }
        return miLen;
    }
    Map*    symbols(void)    { return _symbols; }
    SectionBytes* dataBytes(void) { return _dataBytes; }
    // The largest alignment the data was laid out to (a `.p2align`, a local
    // zero-fill's, a demoted common's, or one noted by the link), which the
    // image's data address must keep.
    u32 dataAlign(void) { return _dataAlign; }
    void noteDataAlign(u32 al) { if (al > _dataAlign) _dataAlign = al; }
    SectionBytes* textBytes(void) { return _textBytes; }
    Array*  dataSyms(void)   { return _dataSyms; }
    Array*  globals(void)    { return _globals; }     // names under .globl — the object's exports
    Map*    commonSyms(void) { return _commonSyms; }  // `.comm` commons: name -> [size, log2align]
    bool    failed(void)     { return _failed; }
    String* why(void)        { return _why; }

    // Give every COMMON real storage in __data and define it locally, then clear
    // the common set. For single-unit IMAGE builds (executable/dylib), which
    // have no separate link stage; the object (`-c`) path keeps commons. Sorted
    // order (as MachO.sortNames) so the reference and this
    // assembler lay them out identically (bug 169).
    void demoteCommonsToLocalData(void)
    {
        if (_commonSyms.count() == (u32)0) return;
        Array* names = _commonSyms.allKeys();
        SortStable.byString(names);   // n log n (#335); the names are distinct
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1) {
            String* nm = (String*)names.get(k);
            Array* info = (Array*)_commonSyms.get((Hashable*)nm);
            u32 sz = ((Number*)info.get((u32)0)).asU32();
            u32 alg = ((Number*)info.get((u32)1)).asU32();
            u32 al = (u32)1 << alg;
            noteDataAlign(al);
            _dataBytes.padTo(al);
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_dataBytes.length()));
            _dataSyms.add((Object*)nm);
            _dataBytes.appendZeros(sz);
        }
        _commonSyms = new Map();
    }
    // The Mach-O image paths' alternative (bug 642): the COMMON symbols as a
    // sorted list of [name, size, log2align], cleared from the assembler. The
    // link driver gives them zero-fill storage AFTER the mod-init tail —
    // outside the data bytes, so the writer describes them as __bss and the
    // file does not carry them. Mirrors the reference's takeCommons.
    Array* takeCommons(void)
    {
        Array* out = new Array();
        Array* names = _commonSyms.allKeys();
        SortStable.byString(names);   // n log n (#335); the names are distinct
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1) {
            String* nm = (String*)names.get(k);
            Array* info = (Array*)_commonSyms.get((Hashable*)nm);
            Array* c = new Array();
            c.add((Object*)nm);
            c.add(info.get((u32)0));
            c.add(info.get((u32)1));
            out.add((Object*)c);
        }
        _commonSyms = new Map();
        return out;
    }
    // Give the commons from takeCommons their __bss offsets: each past the end
    // of `data`, aligned as declared (at least 8), in list order. A name the
    // symbol table already defines keeps that definition (a strong def beats a
    // common). Returns the run's length. Mirrors the reference's allocateBss.
    static u32 allocateBss(Array* commons, SectionBytes* data, Map* symbols, Array* dataSyms)
    {
        u32 cursor = (u32)0;
        for (u32 i = (u32)0; i < commons.count(); i = i + (u32)1) {
            Array* c = (Array*)commons.get(i);
            String* nm = (String*)c.get((u32)0);
            if (symbols.get((Hashable*)nm) != (Object*)0) continue;
            u32 sz = ((Number*)c.get((u32)1)).asU32();
            u32 al = (u32)1 << ((Number*)c.get((u32)2)).asU32();
            if (al < (u32)8) al = (u32)8;
            while (cursor % al != (u32)0) cursor = cursor + (u32)1;
            symbols.set((Hashable*)nm, (Object*)Number.withU32(data.length() + cursor));
            dataSyms.add((Object*)nm);
            cursor = cursor + sz;
        }
        return cursor;
    }

    void fail(String* msg)
    {
        if (_failed) return;
        _failed = true;
        _why = msg;
    }

    void failFmt(String* what, String* detail)
    {
        String* m = new String();
        m.append(what);
        if (detail != (String*)0) { m.appendCString(" "); m.append(detail); }
        fail(m);
    }

    // ── the GNU/ELF dialect ──────────────────────────────────────────────
    //
    // Rewrite ELF-flavoured AArch64 asm into the Mach-O flavour this assembler
    // parses. The two differ only in how a symbol reference is SPELLED — the
    // instructions are identical — so one normalising pre-pass buys the whole
    // dialect rather than a second spelling at every operand site:
    //
    //     adrp x1, sym          ->  adrp x1, sym@PAGE
    //     :lo12:sym             ->  sym@PAGEOFF
    //     :got:sym              ->  sym@GOTPAGE
    //     :got_lo12:sym         ->  sym@GOTPAGEOFF
    //
    // Needed because the Android runtime (support/arm64/runtime/rt-android.s
    // and glue-android.s) is generated by the NDK clang, which targets ELF: it
    // must be assembled from exactly the text clang produced, or the ABI it was
    // generated for stops being the ABI it is checked against. Idempotent on
    // asm that is already Mach-O flavoured, so it is safe over a mixed input.
    static bool isSymByte(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
    }

    static bool isSymStart(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
    }

    // `:<op>:sym` → `sym<mod>`, in place, once per line (clang emits at most one).
    static String* elfOperatorToMacho(String* l, String* op, String* mod)
    {
        u32 at = l.byteIndexOf(op);
        if (at == (u32)$FFFF_FFFF) return l;
        u32 sb = at + op.byteLength();
        u32 se = sb;
        while (se < l.byteLength() && isSymByte(l.byteAt(se))) se = se + (u32)1;
        if (se == sb || !isSymStart(l.byteAt(sb))) return l;
        String* o = new String();
        o.append(l.substringBytes((u32)0, at));
        o.append(l.substringBytes(sb, se - sb));
        o.append(mod);
        o.append(l.substringBytes(se, l.byteLength() - se));
        return o;
    }

    static String* machoDialectFromElf(String* elfAsm)
    {
        if (elfAsm == (String*)0) return new String();
        Array* lines = elfAsm.splitOnByte((u8)'\n');
        String* out = new String();
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
            String* l = (String*)lines.get(li);
            // `:got_lo12:` first: it is the longest, and stating the order says
            // the intent even though no shorter pattern can match inside it.
            l = elfOperatorToMacho(l, String.withCString(":got_lo12:"),
                                      String.withCString("@GOTPAGEOFF"));
            l = elfOperatorToMacho(l, String.withCString(":got:"),
                                      String.withCString("@GOTPAGE"));
            l = elfOperatorToMacho(l, String.withCString(":lo12:"),
                                      String.withCString("@PAGEOFF"));
            // A BARE symbol operand on adrp. Anything already carrying an `@`
            // is left alone, which is what makes this idempotent. The symbol
            // must run to end of line, so a decorated or commented operand is
            // not touched.
            if (l.trimmed().hasPrefix(String.withCString("adrp"))
             && l.byteIndexOf(String.withCString("@")) == (u32)$FFFF_FFFF) {
                u32 c = l.byteIndexOf(String.withCString(","));
                if (c != (u32)$FFFF_FFFF) {
                    u32 sb = c + (u32)1;
                    while (sb < l.byteLength()
                        && (l.byteAt(sb) == (u8)' ' || l.byteAt(sb) == (u8)'\t'))
                        sb = sb + (u32)1;
                    u32 se = sb;
                    while (se < l.byteLength() && isSymByte(l.byteAt(se))) se = se + (u32)1;
                    bool tail = true;
                    for (u32 k = se; k < l.byteLength(); k = k + (u32)1) {
                        u8 ch = l.byteAt(k);
                        if (ch != (u8)' ' && ch != (u8)'\t' && ch != (u8)'\r') { tail = false; }
                    }
                    if (se > sb && tail && isSymStart(l.byteAt(sb))) {
                        String* o = new String();
                        o.append(l.substringBytes((u32)0, se));
                        o.appendCString("@PAGE");
                        o.append(l.substringBytes(se, l.byteLength() - se));
                        l = o;
                    }
                }
            }
            if (li > (u32)0) out.appendByte((u8)'\n');
            out.append(l);
        }
        return out;
    }

    // ── Operand parsing ──────────────────────────────────────────────────
    //
    // A GP register. `sp`/`wsp` are 31 with the SP flag, which changes the
    // encoding of add/sub (the shifted-register form cannot name SP, so those
    // become the extended-register form).
    static RegRef* parseReg(String* s0)
    {
        if (s0 == (String*)0) return RegRef.no();
        String* s = s0.trimmed();
        if (s.equals(String.withCString("sp")))  return RegRef.yes((u32)31, true, true);
        if (s.equals(String.withCString("wsp"))) return RegRef.yes((u32)31, false, true);
        if (s.equals(String.withCString("xzr"))) return RegRef.yes((u32)31, true, false);
        if (s.equals(String.withCString("wzr"))) return RegRef.yes((u32)31, false, false);
        if (s.equals(String.withCString("fp")))  return RegRef.yes((u32)29, true, false);
        if (s.equals(String.withCString("lr")))  return RegRef.yes((u32)30, true, false);
        if (s.byteLength() < (u32)2) return RegRef.no();
        u8 c = s.byteAt((u32)0);
        if (c != (u8)'w' && c != (u8)'x') return RegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < s.byteLength(); i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return RegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)30) return RegRef.no();
        return RegRef.yes(n, c == (u8)'x', false);
    }

    static FRegRef* parseFReg(String* s0)
    {
        if (s0 == (String*)0) return FRegRef.no();
        String* s = s0.trimmed();
        if (s.byteLength() < (u32)2) return FRegRef.no();
        u8 c = s.byteAt((u32)0);
        u32 z;
        if (c == (u8)'b') z = (u32)0;
        else if (c == (u8)'h') z = (u32)1;
        else if (c == (u8)'s') z = (u32)2;
        else if (c == (u8)'d') z = (u32)3;
        else if (c == (u8)'q') z = (u32)4;
        else return FRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < s.byteLength(); i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return FRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return FRegRef.no();
        return FRegRef.yes(n, z);
    }

    static VRegRef* parseVReg(String* s0)
    {
        if (s0 == (String*)0) return VRegRef.no();
        String* s = s0.trimmed();
        if (!s.hasPrefix(String.withCString("v"))) return VRegRef.no();
        u32 dot = s.byteIndexOf(String.withCString("."));
        if (dot == (u32)$FFFF_FFFF) return VRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < dot; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return VRegRef.no();
        String* arr = s.substringFromByte(dot + (u32)1);
        if (arr.equals(String.withCString("8b")))  return VRegRef.yes(n, (u32)0, (u32)0, (u32)0);
        if (arr.equals(String.withCString("16b"))) return VRegRef.yes(n, (u32)0, (u32)1, (u32)0);
        if (arr.equals(String.withCString("4h")))  return VRegRef.yes(n, (u32)1, (u32)0, (u32)0);
        if (arr.equals(String.withCString("8h")))  return VRegRef.yes(n, (u32)1, (u32)1, (u32)0);
        if (arr.equals(String.withCString("2s")))  return VRegRef.yes(n, (u32)2, (u32)0, (u32)0);
        if (arr.equals(String.withCString("4s")))  return VRegRef.yes(n, (u32)2, (u32)1, (u32)0);
        if (arr.equals(String.withCString("1d")))  return VRegRef.yes(n, (u32)3, (u32)0, (u32)0);
        if (arr.equals(String.withCString("2d")))  return VRegRef.yes(n, (u32)3, (u32)1, (u32)0);
        return VRegRef.no();
    }

    static VRegRef* parseVElem(String* s0)
    {
        if (s0 == (String*)0) return VRegRef.no();
        String* s = s0.trimmed();
        if (!s.hasPrefix(String.withCString("v"))) return VRegRef.no();
        u32 dot = s.byteIndexOf(String.withCString("."));
        u32 lb = s.byteIndexOf(String.withCString("["));
        u32 rb = s.byteIndexOf(String.withCString("]"));
        if (dot == (u32)$FFFF_FFFF || lb == (u32)$FFFF_FFFF || rb == (u32)$FFFF_FFFF) return VRegRef.no();
        if (!(dot < lb && lb < rb)) return VRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < dot; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return VRegRef.no();
        String* ty = s.substringBytes(dot + (u32)1, lb - dot - (u32)1);
        u32 sz;
        if (ty.equals(String.withCString("b"))) sz = (u32)0;
        else if (ty.equals(String.withCString("h"))) sz = (u32)1;
        else if (ty.equals(String.withCString("s"))) sz = (u32)2;
        else if (ty.equals(String.withCString("d"))) sz = (u32)3;
        else return VRegRef.no();
        u32 idx = (u32)0;
        for (u32 i = lb + (u32)1; i < rb; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            idx = idx * (u32)10 + (u32)(d - (u8)'0');
        }
        return VRegRef.yes(n, sz, (u32)0, idx);
    }

    // An immediate: `#…` or bare, hex or decimal, optionally negative, with
    // `_` digit separators dropped. `ok` distinguishes "not a number" from
    // "the number zero", which decides operand shape all over the encoder.
    bool _immOk;

    U64* parseImm(String* s0)
    {
        _immOk = false;
        if (s0 == (String*)0) return U64.zero();
        String* s = s0.trimmed();
        if (s.hasPrefix(String.withCString("#"))) s = s.substringFromByte((u32)1);
        String* clean = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) != (u8)'_') clean.appendByte(s.byteAt(i));
        s = clean;
        if (s.byteLength() == (u32)0) return U64.zero();
        bool neg = false;
        if (s.hasPrefix(String.withCString("-"))) { neg = true; s = s.substringFromByte((u32)1); }
        u32 base = (u32)10;
        if (s.hasPrefix(String.withCString("0x")) || s.hasPrefix(String.withCString("0X"))) {
            base = (u32)16; s = s.substringFromByte((u32)2);
        }
        if (s.byteLength() == (u32)0) return U64.zero();
        U64* v = U64.zero();
        U64* b = U64.fromU32(base);
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            u32 d;
            if (c >= (u8)'0' && c <= (u8)'9') d = (u32)(c - (u8)'0');
            else if (base == (u32)16 && c >= (u8)'a' && c <= (u8)'f') d = (u32)(c - (u8)'a') + (u32)10;
            else if (base == (u32)16 && c >= (u8)'A' && c <= (u8)'F') d = (u32)(c - (u8)'A') + (u32)10;
            else return U64.zero();
            v = mul64small(v, b).plus(U64.fromU32(d));
        }
        _immOk = true;
        return neg ? v.negated() : v;
    }

    // Only ever called with a base of 10 or 16, so a shift-and-add is enough
    // and there is no need for a general 64x64 multiply.
    static U64* mul64small(U64* v, U64* b)
    {
        if (b.lo() == (u32)16 && b.hi() == (u32)0) return v.shl((u32)4);
        // times ten = (v << 3) + (v << 1)
        return v.shl((u32)3).plus(v.shl((u32)1));
    }

    bool immOk(void) { return _immOk; }

    // ── Line handling ────────────────────────────────────────────────────
    //
    // Strip an end-of-line comment — `//` from our back end, `;` from clang's
    // arm64 output — but not one inside a quoted string, or a `.asciz` holding
    // a semicolon loses its tail.
    static String* stripComment(String* l)
    {
        bool inStr = false;
        for (u32 i = (u32)0; i < l.byteLength(); i = i + (u32)1) {
            u8 c = l.byteAt(i);
            if (inStr && c == (u8)'\\') { i = i + (u32)1; continue; }   // \" stays inside
            if (c == (u8)'"') { inStr = !inStr; continue; }
            if (inStr) continue;
            if (c == (u8)';') return l.substringBytes((u32)0, i);
            if (c == (u8)'/' && i + (u32)1 < l.byteLength() && l.byteAt(i + (u32)1) == (u8)'/')
                return l.substringBytes((u32)0, i);
        }
        return l;
    }

    // xtc's inline-asm capture re-tokenises the body, and because `@` is the
    // language's pointer operator it re-emits `_g@PAGE` as `_g @ PAGE`. clang
    // tolerates the spaces, so this must too: otherwise the symbol keeps a
    // trailing space, never matches the defined name, and the adrp/add pair
    // resolves to zero — a wild store.
    static String* normPageMod(String* op)
    {
        if (op.byteIndexOf(String.withCString("@")) == (u32)$FFFF_FFFF) return op;
        String* out = new String();
        u32 i = (u32)0;
        while (i < op.byteLength()) {
            u8 c = op.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t') {
                u32 j = i;
                while (j < op.byteLength() && (op.byteAt(j) == (u8)' ' || op.byteAt(j) == (u8)'\t'))
                    j = j + (u32)1;
                if (j < op.byteLength() && op.byteAt(j) == (u8)'@') { i = j; continue; }
                out.appendByte(c); i = i + (u32)1; continue;
            }
            if (c == (u8)'@') {
                out.appendByte(c);
                u32 j = i + (u32)1;
                while (j < op.byteLength() && (op.byteAt(j) == (u8)' ' || op.byteAt(j) == (u8)'\t'))
                    j = j + (u32)1;
                i = j; continue;
            }
            out.appendByte(c); i = i + (u32)1;
        }
        return out;
    }

    // Split on commas at bracket depth zero, so `[x0, #8]` stays one operand.
    static Array* splitOperands(String* s)
    {
        Array* out = new Array();
        i32 depth = (i32)0;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)'[') depth = depth + (i32)1;
            else if (c == (u8)']') depth = depth - (i32)1;
            else if (c == (u8)',' && depth == (i32)0) {
                out.add((Object*)normPageMod(s.substringBytes(start, i - start).trimmed()));
                start = i + (u32)1;
            }
        }
        String* last = normPageMod(s.substringFromByte(start).trimmed());
        if (last.byteLength() > (u32)0) out.add((Object*)last);
        return out;
    }

    static i32 condCode(String* cc)
    {
        if (cc.equals(String.withCString("eq"))) return (i32)0;
        if (cc.equals(String.withCString("ne"))) return (i32)1;
        if (cc.equals(String.withCString("cs")) || cc.equals(String.withCString("hs"))) return (i32)2;
        if (cc.equals(String.withCString("cc")) || cc.equals(String.withCString("lo"))) return (i32)3;
        if (cc.equals(String.withCString("mi"))) return (i32)4;
        if (cc.equals(String.withCString("pl"))) return (i32)5;
        if (cc.equals(String.withCString("vs"))) return (i32)6;
        if (cc.equals(String.withCString("vc"))) return (i32)7;
        if (cc.equals(String.withCString("hi"))) return (i32)8;
        if (cc.equals(String.withCString("ls"))) return (i32)9;
        if (cc.equals(String.withCString("ge"))) return (i32)10;
        if (cc.equals(String.withCString("lt"))) return (i32)11;
        if (cc.equals(String.withCString("gt"))) return (i32)12;
        if (cc.equals(String.withCString("le"))) return (i32)13;
        if (cc.equals(String.withCString("al"))) return (i32)14;
        return (i32)-1;
    }

    static u32 firstSpace(String* s)
    {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t') return i;
        }
        return (u32)$FFFF_FFFF;
    }

    static String* opAt(Array* ops, u32 i)
    {
        return i < ops.count() ? (String*)ops.get(i) : String.withCString("");
    }

    // ── The bitmask (logical) immediate ──────────────────────────────────
    //
    // N:immr:imms, thirteen bits describing a repeating run of ones. Ported
    // from LLVM's processLogicalImmediate; the shape is not obvious and is not
    // worth re-deriving. Returns $FFFF_FFFF when the value is not encodable,
    // which is a real answer — `and x0, x0, #5` genuinely has no encoding.
    static bool isMask64(U64* v)
    {
        if (v.isZero()) return false;
        return v.plus(U64.fromU32((u32)1)).anded(v).isZero();
    }

    static bool isShiftedMask64(U64* v)
    {
        if (v.isZero()) return false;
        return isMask64(v.minus(U64.fromU32((u32)1)).ored(v));
    }

    static u32 encodeLogImm(U64* imm0, u32 regSize)
    {
        U64* imm = imm0;
        if (imm.isZero() || imm.isOnes()) return (u32)$FFFF_FFFF;
        if (regSize != (u32)64) {
            if (!imm.shr(regSize).isZero()) return (u32)$FFFF_FFFF;
            if (imm.equals64(U64.ones().shr((u32)64 - regSize))) return (u32)$FFFF_FFFF;
        }
        u32 size = regSize;
        while (true) {
            size = size / (u32)2;
            U64* m = U64.maskLow(size);
            if (!imm.anded(m).equals64(imm.shr(size).anded(m))) { size = size * (u32)2; break; }
            if (size <= (u32)2) break;
        }
        U64* mask = U64.ones().shr((u32)64 - size);
        imm = imm.anded(mask);
        u32 cto;
        u32 i;
        if (isShiftedMask64(imm)) {
            i = imm.ctz();
            cto = imm.shr(i).notted().ctz();
        } else {
            imm = imm.ored(mask.notted());
            if (!isShiftedMask64(imm.notted())) return (u32)$FFFF_FFFF;
            u32 clo = imm.notted().clz();
            i = (u32)64 - clo;
            cto = clo + imm.notted().ctz() - ((u32)64 - size);
        }
        u32 immr = (size - i) & (size - (u32)1);
        // nimms = ~(size-1) << 1, then the low bits carry cto-1.
        U64* nimms = U64.fromU32(size - (u32)1).notted().shl((u32)1);
        nimms = nimms.ored(U64.fromU32(cto - (u32)1));
        u32 N = ((nimms.shr((u32)6).lo() & (u32)1) ^ (u32)1) & (u32)1;
        return (N << (u32)12) | (immr << (u32)6) | (nimms.lo() & (u32)$3F);
    }

    // ── Encoding one line ────────────────────────────────────────────────
    //
    // `resolveLocal` is filled in by the caller's symbol table: a TEXT label
    // gives its address and a relative branch; anything else becomes a fixup.
    Map*  _resolveSyms;
    Map*  _resolveDataSyms;   // the data symbols, as a set
    bool  _lastWasLocal;

    u32 resolveTarget(String* name)
    {
        _lastWasLocal = false;
        if (_resolveSyms == (Map*)0) return (u32)0;
        Object* a = _resolveSyms.get((Hashable*)name);
        if (a == (Object*)0) return (u32)0;
        if (_resolveDataSyms != (Map*)0 && _resolveDataSyms.get((Hashable*)name) != (Object*)0) return (u32)0;
        _lastWasLocal = true;
        return ((Number*)a).asU32();
    }

    void addFixup(u32 pc, u32 kind, String* sym, u32 scale)
    {
        _fixups.add((Object*)Arm64Fixup.make(pc, kind, sym, scale));
    }

    // Set by every encoder that recognised its line. The dispatch chain reads
    // it instead of a sentinel word, because 0x00000000 is a real encoding.
    bool _hit;

    u32 encodeLine(String* raw, u32 pc)
    {
        _hit = false;
        String* line = stripComment(raw).trimmed();
        if (line.byteLength() == (u32)0) { fail(String.withCString("empty line")); return (u32)0; }
        u32 sp = firstSpace(line);
        String* mn = sp == (u32)$FFFF_FFFF ? line : line.substringBytes((u32)0, sp);
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                             : line.substringFromByte(sp).trimmed();
        Array* ops = splitOperands(rest);
        // The encoders test this number, not the String (#330).
        u16 mc = Arm64Mn.find(mn);

        u32 w = encSme(mn, mc, ops);            if (_hit) return w;
        w = encNeon(mn, mc, ops, pc);           if (_hit) return w;
        w = encAtomics(mn, mc, ops, pc);        if (_hit) return w;
        w = encMoves(mn, mc, ops, pc);          if (_hit) return w;
        w = encFloat(mn, mc, ops, pc);          if (_hit) return w;
        w = encAddSubLogic(mn, mc, ops, pc);    if (_hit) return w;
        w = encBitfieldMul(mn, mc, ops, pc);    if (_hit) return w;
        w = encMemory(mn, mc, ops, pc);         if (_hit) return w;
        w = encBranches(mn, mc, ops, pc);       if (_hit) return w;

        String* m = String.withCString("unhandled mnemonic: ");
        m.append(mn);
        fail(m);
        return (u32)0;
    }


    // ── atomics and barriers (private:docs/Design/threading.md) ──────────────────
    //
    // Threading puts these in the toolchain's path two ways: the runtime's C
    // atomics compile to them, and the back end emits `ldaddh`/`ldaddalh`
    // inline for the ARC refcount under -fthread-safe-arc.
    //
    //   LDAR/STLR   size 001000 1 L 0 11111 1 11111 Rn Rt
    //   LD<op>/SWP  size 111000 A R 1 Rs  o3 opc 00 Rn Rt
    //   CAS         size 0010001 A 1 Rs  R  11111    Rn Rt
    //
    // The suffix carries BOTH the width (b/h) and the ordering (a/l/al), so the
    // mnemonic is taken apart rather than looked up: `ldaddalh` is add,
    // acquire-release, halfword. Width comes off FIRST — `l` (release) and
    // `b`/`h` can both end a mnemonic, and only that order is unambiguous.
    // Everything here is LOCAL: an earlier cut kept the pieces in ivars and the
    // assembler faulted on ordinary code long before it reached an atomic.
    static u32 lseOpcFor(u16 mc)
    {
        if (mc == a64Add)  return 0;
        if (mc == a64Clr)  return 1;
        if (mc == a64Eor)  return 2;
        if (mc == a64Set)  return 3;
        if (mc == a64Smax) return 4;
        if (mc == a64Smin) return 5;
        if (mc == a64Umax) return 6;
        if (mc == a64Umin) return 7;
        return (u32)$FFFF_FFFF;
    }

    // `[x16]` → `x16`. The memory operand of every form here is a bare base
    // register in brackets; nothing takes an offset.
    static String* atMemBase(String* op)
    {
        String* t = op.trimmed();
        String* o = new String();
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c != (u8)'[' && c != (u8)']' && c != (u8)' ') o.appendByte(c);
        }
        return o;
    }

    u32 encAtomics(String* mn, u16 mc, Array* ops, u32 pc)
    {
        // ── load/store EXCLUSIVE ──────────────────────────────────────────
        //   size 001000 o2 L o1 Rs o0 Rt2 Rn Rt
        // L picks load vs store, o0 the acquire/release ordering. Not an
        // optional corner: Android's armv8-a baseline has no LSE, so an atomic
        // read-modify-write IS an ldaxr/stlxr pair and the `cas*` forms below
        // are never reached there.
        if (mn.hasPrefix(String.withCString("ldxr")) || mn.hasPrefix(String.withCString("ldaxr"))
         || mn.hasPrefix(String.withCString("stxr")) || mn.hasPrefix(String.withCString("stlxr"))) {
            bool isLoad = mn.hasPrefix(String.withCString("ld"));
            bool acqRel = mn.hasPrefix(String.withCString("ldaxr"))
                       || mn.hasPrefix(String.withCString("stlxr"));
            u32 o0 = acqRel ? (u32)1 : (u32)0;
            String* sfx = mn.substringFromByte(acqRel ? (u32)5 : (u32)4);
            i32 sz = (i32)-2;
            if (sfx.byteLength() == (u32)0) sz = (i32)-1;
            else if (sfx.equals(String.withCString("b"))) sz = (i32)0;
            else if (sfx.equals(String.withCString("h"))) sz = (i32)1;
            u32 want = isLoad ? (u32)2 : (u32)3;
            if (sz != (i32)-2 && ops.count() == want) {
                u32 ti = isLoad ? (u32)0 : (u32)1;
                RegRef* t = parseReg(opAt(ops, ti));
                RegRef* n = parseReg(atMemBase(opAt(ops, ops.count() - (u32)1)));
                u32 rs = (u32)31;
                bool rsOk = true;
                if (!isLoad) {
                    RegRef* sr = parseReg(opAt(ops, (u32)0));
                    if (sr.ok()) rs = sr.num(); else rsOk = false;
                }
                if (t.ok() && n.ok() && rsOk) {
                    if (sz < (i32)0) sz = t.is64() ? (i32)3 : (i32)2;
                    _hit = true;
                    return ((u32)sz << (u32)30) | (u32)$08000000
                         | ((isLoad ? (u32)1 : (u32)0) << (u32)22)
                         | (rs << (u32)16) | (o0 << (u32)15) | ((u32)31 << (u32)10)
                         | (n.num() << (u32)5) | t.num();
                }
            }
        }
        // clrex — drop the exclusive monitor on such a loop's failure path.
        if (mc == a64Clrex) { _hit = true; return $D5033F5F; }

        // ldar{b|h} / stlr{b|h}  Rt, [Xn]
        if (ops.count() == (u32)2 && mn.byteLength() >= (u32)4
            && (mn.hasPrefix(String.withCString("ldar"))
             || mn.hasPrefix(String.withCString("stlr")))) {
            bool isLoad = mn.hasPrefix(String.withCString("ldar"));
            String* sfx = mn.substringFromByte((u32)4);
            i32 sz = (i32)-2;
            if (sfx.byteLength() == (u32)0) sz = (i32)-1;
            else if (sfx.equals(String.withCString("b"))) sz = (i32)0;
            else if (sfx.equals(String.withCString("h"))) sz = (i32)1;
            if (sz != (i32)-2) {
                RegRef* t = parseReg(opAt(ops, (u32)0));
                RegRef* n = parseReg(atMemBase(opAt(ops, (u32)1)));
                if (t.ok() && n.ok()) {
                    if (sz < (i32)0) sz = t.is64() ? (i32)3 : (i32)2;
                    _hit = true;
                    return ((u32)sz << (u32)30) | (u32)$08000000 | ((u32)1 << (u32)23)
                         | ((isLoad ? (u32)1 : (u32)0) << (u32)22) | ((u32)31 << (u32)16)
                         | ((u32)1 << (u32)15) | ((u32)31 << (u32)10)
                         | (n.num() << (u32)5) | t.num();
                }
            }
        }

        // ld<op>{a}{l}{b|h} / swp{a}{l}{b|h} / cas{a}{l}{b|h}   Rs, Rt, [Xn]
        if (ops.count() == (u32)3) {
            bool isSwp = mn.hasPrefix(String.withCString("swp"));
            bool isCas = mn.hasPrefix(String.withCString("cas"));
            bool isLd  = mn.hasPrefix(String.withCString("ld"));
            if (isSwp || isCas || isLd) {
                u32 plen = (isSwp || isCas) ? (u32)3 : (u32)2;
                String* t = mn.substringFromByte(plen);
                i32 sz = (i32)-1; u32 A = (u32)0; u32 R = (u32)0;
                if (t.byteLength() > (u32)0 && t.hasSuffix(String.withCString("b"))) {
                    sz = (i32)0; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                } else if (t.byteLength() > (u32)0 && t.hasSuffix(String.withCString("h"))) {
                    sz = (i32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                }
                if (t.byteLength() >= (u32)2 && t.hasSuffix(String.withCString("al"))) {
                    A = (u32)1; R = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)2);
                } else if (t.byteLength() >= (u32)1 && t.hasSuffix(String.withCString("a"))) {
                    A = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                } else if (t.byteLength() >= (u32)1 && t.hasSuffix(String.withCString("l"))) {
                    R = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                }
                u32 opc = (isSwp || isCas) ? 0 : lseOpcFor(Arm64Mn.find(t));
                bool shaped = (isSwp || isCas) ? t.byteLength() == (u32)0
                                               : opc != (u32)$FFFF_FFFF;
                if (shaped) {
                    RegRef* rs = parseReg(opAt(ops, (u32)0));
                    RegRef* rt = parseReg(opAt(ops, (u32)1));
                    RegRef* rn = parseReg(atMemBase(opAt(ops, (u32)2)));
                    if (rs.ok() && rt.ok() && rn.ok()) {
                        if (sz < (i32)0) sz = rs.is64() ? (i32)3 : (i32)2;
                        _hit = true;
                        if (isCas)
                            return ((u32)sz << (u32)30) | (u32)$08A00000 | (A << (u32)22)
                                 | (rs.num() << (u32)16) | (R << (u32)15) | ((u32)31 << (u32)10)
                                 | (rn.num() << (u32)5) | rt.num();
                        return ((u32)sz << (u32)30) | (u32)$38000000 | (A << (u32)23)
                             | (R << (u32)22) | ((u32)1 << (u32)21) | (rs.num() << (u32)16)
                             | ((isSwp ? (u32)1 : (u32)0) << (u32)15) | (opc << (u32)12)
                             | (rn.num() << (u32)5) | rt.num();
                    }
                }
            }
        }

        // dmb/dsb <option>, isb
        if ((mc == a64Dmb || mc == a64Dsb)
            && ops.count() == (u32)1) {
            String* o = opAt(ops, (u32)0);
            u32 opt = (u32)$FFFF_FFFF;
            if (o.equals(String.withCString("oshld"))) opt = (u32)1;
            else if (o.equals(String.withCString("oshst"))) opt = (u32)2;
            else if (o.equals(String.withCString("osh")))   opt = (u32)3;
            else if (o.equals(String.withCString("nshld"))) opt = (u32)5;
            else if (o.equals(String.withCString("nshst"))) opt = (u32)6;
            else if (o.equals(String.withCString("nsh")))   opt = (u32)7;
            else if (o.equals(String.withCString("ishld"))) opt = (u32)9;
            else if (o.equals(String.withCString("ishst"))) opt = (u32)10;
            else if (o.equals(String.withCString("ish")))   opt = (u32)11;
            else if (o.equals(String.withCString("ld")))    opt = (u32)13;
            else if (o.equals(String.withCString("st")))    opt = (u32)14;
            else if (o.equals(String.withCString("sy")))    opt = (u32)15;
            if (opt != (u32)$FFFF_FFFF) {
                u32 opc2 = mc == a64Dmb ? 5 : 4;
                _hit = true;
                return (u32)$D503309F | (opt << (u32)8) | (opc2 << (u32)5);
            }
        }
        if (mc == a64Isb) { _hit = true; return $D5033FDF; }
        return (u32)0;
    }

    // ── NEON ─────────────────────────────────────────────────────────────
    //
    // Dispatched FIRST, because it shares mnemonics with the scalar handlers
    // (add, mul, the f-ops) and is told apart only by the operands being
    // vector registers. Fields OR'd in: Q<<30, size<<22, Rm<<16, Rn<<5, Rd.
    // FP16 arithmetic (three-same FP16, FEAT_FP16) on .4h/.8h, whose
    // encoding the float table's one size bit cannot spell; and the widen and
    // narrow between .4h/.8h and .4s, where the `2` forms take or write the
    // high half, so Q comes from the 8-lane operand and must agree with the
    // suffix. As the reference's handlers ahead of its int3 table.
    u32 encNeonHalf(String* mn, u16 mc, Array* ops, VRegRef* d)
    {
        if (!d.ok())
            return (u32)0;
        if (d.size() == (u32)1 && ops.count() == (u32)3) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* m = parseVReg(opAt(ops, (u32)2));
            u32 hb = mc == a64Fadd ? (u32)$0E401400 : mc == a64Fsub ? (u32)$0EC01400
                   : mc == a64Fmul ? (u32)$2E401C00 : mc == a64Fdiv ? (u32)$2E403C00 : (u32)0;
            if (n.ok() && m.ok() && hb != (u32)0) {
                _hit = true;
                return hb | (d.q() << (u32)30) | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
            }
        }
        if (d.size() == (u32)1 && ops.count() == (u32)2 && mc == a64Fsqrt) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            if (n.ok()) {
                _hit = true;
                return (u32)$2EF9F800 | (d.q() << (u32)30) | (n.num() << (u32)5) | d.num();
            }
        }
        bool fl = mc == a64Fcvtl || mc == a64Fcvtl2;
        bool fn = mc == a64Fcvtn || mc == a64Fcvtn2;
        bool xt = mc == a64Xtn || mc == a64Xtn2;
        bool us = mc == a64Ushll || mc == a64Ushll2;
        bool sl = mc == a64Shll || mc == a64Shll2;
        if (!(fl || fn || xt || us || sl) || ops.count() < (u32)2)
            return (u32)0;
        VRegRef* s = parseVReg(opAt(ops, (u32)1));
        if (!s.ok()) {
            fail(String.withCString("bad widen or narrow source"));
            return (u32)0;
        }
        bool two = mc == a64Fcvtl2 || mc == a64Fcvtn2 || mc == a64Xtn2 || mc == a64Ushll2 || mc == a64Shll2;
        bool widen = fl || us || sl;
        u32 wq = widen ? d.q() : s.q();
        u32 ws = widen ? d.size() : s.size();
        u32 nq = widen ? s.q() : d.q();
        u32 ns = widen ? s.size() : d.size();
        if (ws != (u32)2 || wq != (u32)1 || ns != (u32)1 || (nq == (u32)1) != two) {
            fail(String.withCString("unsupported widen or narrow arrangement"));
            return (u32)0;
        }
        u32 q = nq << (u32)30;
        if (fl) { _hit = true; return (u32)$0E217800 | q | (s.num() << (u32)5) | d.num(); }
        if (fn) { _hit = true; return (u32)$0E216800 | q | (s.num() << (u32)5) | d.num(); }
        if (xt) { _hit = true; return (u32)$0E612800 | q | (s.num() << (u32)5) | d.num(); }
        if (ops.count() != (u32)3 || !opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
            fail(String.withCString("a widening shift needs a shift"));
            return (u32)0;
        }
        U64* shv = parseImm(opAt(ops, (u32)2));
        if (!_immOk || shv.hi() != (u32)0) { fail(String.withCString("bad shift amount")); return (u32)0; }
        u32 sh = shv.lo();
        if (sl) {
            if (sh != (u32)16) {
                fail(String.withCString("shll shift must be 16"));
                return (u32)0;
            }
            _hit = true;
            return (u32)$2E613800 | q | (s.num() << (u32)5) | d.num();
        }
        if (sh > (u32)15) {
            fail(String.withCString("ushll shift out of range 0..15"));
            return (u32)0;
        }
        _hit = true;
        return (u32)$2F00A400 | q | (((u32)16 + sh) << (u32)16) | (s.num() << (u32)5) | d.num();
    }

    u32 encNeon(String* mn, u16 mc, Array* ops, u32 pc)
    {
        VRegRef* d = ops.count() >= (u32)1 ? parseVReg(opAt(ops, (u32)0)) : VRegRef.no();

        // dup Vd.T, Rn — splat a GP register across the lanes.
        if (d.ok() && mc == a64Dup && ops.count() == 2
            && !opAt(ops, (u32)1).hasPrefix(String.withCString("v"))) {
            RegRef* n = parseReg(opAt(ops, (u32)1));
            if (!n.ok()) { fail(String.withCString("bad dup source")); return (u32)0; }
            _hit = true;
            return (u32)$0E000C00 | (d.q() << (u32)30) | (((u32)1 << d.size()) << (u32)16)
                 | (n.num() << (u32)5) | d.num();
        }

        // The 16-bit floats' lanes (float sizes P1), byte-exact from clang.
        u32 hw = encNeonHalf(mn, mc, ops, d);
        if (_hit || _failed)
            return hw;

        if (d.ok() && ops.count() == (u32)3) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* m = parseVReg(opAt(ops, (u32)2));
            if (n.ok() && m.ok()) {
                u32 b = neonInt3(mc);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonLogic3(mc);       // no size field: 8b/16b arrangements only
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (m.num() << (u32)16)
                         | (n.num() << (u32)5) | d.num();
                }
                b = neonFloat3(mc);       // one sz bit at 22: 0 for .2s/.4s, 1 for .2d
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | ((d.size() == (u32)3 ? (u32)1 : (u32)0) << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonPerm(mc);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonWiden3(mc);
                if (b != (u32)0) {
                    if (n.size() != m.size() || n.q() != m.q()) {
                        fail(String.withCString("widening multiply sources disagree"));
                        return (u32)0;
                    }
                    // The suffix IS the half-selector; a mismatch would quietly
                    // encode the other half of the register.
                    bool hi = mn.hasSuffix(String.withCString("2"));
                    if ((n.q() == (u32)1) != hi) {
                        fail(String.withCString("widening multiply suffix does not match its sources"));
                        return (u32)0;
                    }
                    if (d.size() != n.size() + (u32)1) {
                        fail(String.withCString("widening multiply destination must be twice the source width"));
                        return (u32)0;
                    }
                    _hit = true;
                    return b | (n.q() << (u32)30) | (n.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
            }
        }
        // ushr/sshr Vd.T, Vn.T, #shift
        if (d.ok() && ops.count() == (u32)3
            && opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
            u32 bs = neonShrImm(mc);
            if (bs != (u32)0) {
                VRegRef* n = parseVReg(opAt(ops, (u32)1));
                if (!n.ok() || n.size() != d.size() || n.q() != d.q()) {
                    fail(String.withCString("shift-right arrangements disagree"));
                    return (u32)0;
                }
                U64* sh = parseImm(opAt(ops, (u32)2));
                if (!_immOk) { fail(String.withCString("bad shift amount")); return (u32)0; }
                u32 esize = (u32)8 << d.size();
                u32 amt = sh.lo();
                if (amt < (u32)1 || amt > esize) {
                    fail(String.withCString("shift-right amount out of range"));
                    return (u32)0;
                }
                _hit = true;
                return bs | (d.q() << (u32)30) | (((u32)2 * esize - amt) << (u32)16)
                     | (n.num() << (u32)5) | d.num();
            }
            // Shift left by immediate: immh:immb holds (esize + shift), shift
            // 0 .. esize - 1. sli (shift left and insert, keeping Vd's low
            // bits) has the same field with U set.
            if (mc == a64Shl || mc == a64Sli) {
                VRegRef* n = parseVReg(opAt(ops, (u32)1));
                if (!n.ok() || n.size() != d.size() || n.q() != d.q()) {
                    fail(String.withCString("shift-left arrangements disagree"));
                    return (u32)0;
                }
                U64* sh = parseImm(opAt(ops, (u32)2));
                if (!_immOk) { fail(String.withCString("bad shift amount")); return (u32)0; }
                u32 esize = (u32)8 << d.size();
                u32 amt = sh.lo();
                if (amt >= esize) {
                    fail(String.withCString("shift-left amount out of range"));
                    return (u32)0;
                }
                _hit = true;
                u32 base = mc == a64Sli ? $2F005400 : $0F005400;
                return base | (d.q() << (u32)30) | ((esize + amt) << (u32)16)
                     | (n.num() << (u32)5) | d.num();
            }
        }
        if (d.ok() && ops.count() == (u32)2) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            // mov Vd.T, Vn.T: the alias of orr Vd.T, Vn.T, Vn.T.
            if (n.ok() && mc == a64Mov && n.q() == d.q()) {
                _hit = true;
                return (u32)$0EA01C00 | (d.q() << (u32)30) | (n.num() << (u32)16) | (n.num() << (u32)5) | d.num();
            }
            if (n.ok()) {
                u32 bp = neonPairLong(mc);
                if (bp != (u32)0) {
                    _hit = true;
                    return bp | (n.q() << (u32)30) | (n.size() << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
                u32 b = neonMisc2i(mc);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
                b = neonMisc2f(mc);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | ((d.size() == (u32)3 ? (u32)1 : (u32)0) << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
            }
        }
        // ext Vd.16b, Vn.16b, Vm.16b, #imm4 — a byte extract across two regs.
        if (d.ok() && mc == a64Ext && ops.count() == 4) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* m = parseVReg(opAt(ops, (u32)2));
            if (n.ok() && m.ok()) {
                U64* idx = parseImm(opAt(ops, (u32)3));
                _hit = true;
                return (u32)$2E000000 | (d.q() << (u32)30) | (m.num() << (u32)16)
                     | ((idx.lo() & (u32)$F) << (u32)11) | (n.num() << (u32)5) | d.num();
            }
        }
        // Across-lanes reduction: the destination is a SCALAR, the source a vector.
        if (!d.ok() && ops.count() == (u32)2) {
            u32 b = neonReduce(mc);
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            if (b != (u32)0 && n.ok()) {
                FRegRef* rd = parseFReg(opAt(ops, (u32)0));
                if (!rd.ok()) { fail(String.withCString("bad reduce destination")); return (u32)0; }
                _hit = true;
                return b | (n.q() << (u32)30) | (n.size() << (u32)22)
                     | (n.num() << (u32)5) | rd.num();
            }
        }
        // By-element: Vd.T, Vn.T, Vm.Ts[i]. H:L:M hold the lane — for .s the
        // index is L(21):H(11), for .d just H(11) — and Vm is four bits plus
        // M(20), so only v0-v15 can be the indexed operand.
        if (d.ok() && ops.count() == (u32)3) {
            u32 b = neonElem(mc);
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* e = parseVElem(opAt(ops, (u32)2));
            if (b != (u32)0 && n.ok() && e.ok()) {
                u32 L; u32 H; u32 sz;
                if (e.size() == (u32)2) { sz = (u32)0; L = e.idx() & (u32)1; H = (e.idx() >> (u32)1) & (u32)1; }
                else                    { sz = (u32)1; L = (u32)0; H = e.idx() & (u32)1; }
                u32 M = (e.num() >> (u32)4) & (u32)1;
                _hit = true;
                return b | (d.q() << (u32)30) | (sz << (u32)22) | (L << (u32)21) | (M << (u32)20)
                     | ((e.num() & (u32)$F) << (u32)16) | (H << (u32)11)
                     | (n.num() << (u32)5) | d.num();
            }
        }
        // dup Vd.T, Vn.Ts[i] — splat one lane across all of them.
        if (d.ok() && mc == a64Dup && ops.count() == 2) {
            VRegRef* e = parseVElem(opAt(ops, (u32)1));
            if (e.ok()) {
                u32 imm5 = (e.idx() << (e.size() + (u32)1)) | ((u32)1 << e.size());
                _hit = true;
                return (u32)$0E000400 | (d.q() << (u32)30) | (imm5 << (u32)16)
                     | (e.num() << (u32)5) | d.num();
            }
        }
        // ld1/st1 { Vt.T }, [Xn] — the single-register, no-offset form. The
        // brace list arrives as ONE operand, because splitOperands does not
        // break on the inner comma of a single-register list.
        if ((mc == a64Ld1 || mc == a64St1)
            && ops.count() == (u32)2 && opAt(ops, (u32)0).hasPrefix(String.withCString("{"))) {
            String* inner = stripBraces(opAt(ops, (u32)0));
            VRegRef* t = parseVReg(inner);
            String* mem = opAt(ops, (u32)1);
            if (t.ok() && mem.hasPrefix(String.withCString("["))
                && mem.hasSuffix(String.withCString("]"))) {
                RegRef* bn = parseReg(mem.substringBytes((u32)1, mem.byteLength() - (u32)2).trimmed());
                if (!bn.ok()) { fail(String.withCString("bad ld1/st1 base")); return (u32)0; }
                u32 base = mc == a64Ld1 ? $0C407000 : $0C007000;
                _hit = true;
                return base | (t.q() << (u32)30) | (t.size() << (u32)10)
                     | (bn.num() << (u32)5) | t.num();
            }
        }
        return (u32)0;
    }

    // ── SME / streaming SVE (private:docs/Design/simd-sme-plan.md) ───────────
    //
    // Exactly the instructions the matrix kernel is built from: smstart/smstop,
    // ptrue, whilelt/whilelo, cnt{b,h,w,d}, zero {za…}, ld1w/st1w/ld1d/st1d to
    // a Z register or a ZA tile slice, mov (tile slice to vector) and fmopa.
    // Base opcodes from clang's assembler, fields OR'd in. Every number is
    // strictly digits (smeDigits), so `za1x.s` is refused, not read as za1.

    // all digits, 1..3 of them; $FFFF_FFFF when not
    static u32 smeDigits(String* t)
    {
        if (t.byteLength() == (u32)0 || t.byteLength() > (u32)3) return (u32)$FFFF_FFFF;
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9') return (u32)$FFFF_FFFF;
            n = n * (u32)10 + (u32)(c - (u8)'0');
        }
        return n;
    }

    // trim '{', '}' and ' ' from both ends
    static String* smeTrimBraces(String* t)
    {
        u32 a = (u32)0;
        u32 b = t.byteLength();
        while (a < b && (t.byteAt(a) == (u8)'{' || t.byteAt(a) == (u8)'}' || t.byteAt(a) == (u8)' ')) a = a + (u32)1;
        while (b > a && (t.byteAt(b - (u32)1) == (u8)'{' || t.byteAt(b - (u32)1) == (u8)'}' || t.byteAt(b - (u32)1) == (u8)' ')) b = b - (u32)1;
        return t.substringBytes(a, b - a);
    }

    // split on every ',' (no nesting), pieces untrimmed
    static Array* smeSplit(String* t)
    {
        Array* out = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1) {
            if (t.byteAt(i) == (u8)',') {
                out.add((Object*)t.substringBytes(start, i - start));
                start = i + (u32)1;
            }
        }
        out.add((Object*)t.substringFromByte(start));
        return out;
    }

    static u32 smeElem(String* e)
    {
        if (e.equals(String.withCString("b"))) return (u32)0;
        if (e.equals(String.withCString("h"))) return (u32)1;
        if (e.equals(String.withCString("s"))) return (u32)2;
        if (e.equals(String.withCString("d"))) return (u32)3;
        return (u32)$FFFF_FFFF;
    }

    // p<n>[.b|.h|.s|.d|/z|/m] -> a = num, b = size or $FFFF_FFFF
    static SmeRef* smePReg(String* s0)
    {
        String* t = s0.lowercased();
        if (!t.hasPrefix(String.withCString("p")) || t.byteLength() < (u32)2) return SmeRef.no();
        u32 i = (u32)1;
        u32 n = (u32)0;
        u32 digits = (u32)0;
        while (i < t.byteLength() && t.byteAt(i) >= (u8)'0' && t.byteAt(i) <= (u8)'9') {
            n = n * (u32)10 + (u32)(t.byteAt(i) - (u8)'0');
            i = i + (u32)1;
            digits = digits + (u32)1;
        }
        if (digits == (u32)0 || n > (u32)15) return SmeRef.no();
        String* tail = t.substringFromByte(i);
        u32 sz = (u32)$FFFF_FFFF;
        if (tail.equals(String.withCString(".b"))) sz = (u32)0;
        else if (tail.equals(String.withCString(".h"))) sz = (u32)1;
        else if (tail.equals(String.withCString(".s"))) sz = (u32)2;
        else if (tail.equals(String.withCString(".d"))) sz = (u32)3;
        else if (!(tail.byteLength() == (u32)0 || tail.equals(String.withCString("/z"))
                   || tail.equals(String.withCString("/m")))) return SmeRef.no();
        return SmeRef.yes(n, sz, (u32)0, (u32)0, (u32)0);
    }

    // z<n>.<b|h|s|d> (braces optional) -> a = num, b = size
    static SmeRef* smeZReg(String* s0)
    {
        String* t = smeTrimBraces(s0.lowercased());
        if (!t.hasPrefix(String.withCString("z")) || t.byteLength() < (u32)4
            || t.hasPrefix(String.withCString("za"))) return SmeRef.no();
        u32 dot = t.byteIndexOf(String.withCString("."));
        if (dot == (u32)$FFFF_FFFF) return SmeRef.no();
        u32 n = smeDigits(t.substringBytes((u32)1, dot - (u32)1));
        if (n == (u32)$FFFF_FFFF) return SmeRef.no();
        u32 sz = smeElem(t.substringFromByte(dot + (u32)1));
        if (sz == (u32)$FFFF_FFFF || n > (u32)31) return SmeRef.no();
        return SmeRef.yes(n, sz, (u32)0, (u32)0, (u32)0);
    }

    // za<t><h|v>.<s|d>[w<12..15>, <off>] (braces optional)
    //   -> a = tile, b = vert, c = size, d = Ws-12, e = off
    static SmeRef* smeZASlice(String* s0)
    {
        String* t = smeTrimBraces(s0.lowercased());
        if (!t.hasPrefix(String.withCString("za")) || t.byteLength() < (u32)6) return SmeRef.no();
        u32 i = (u32)2;
        u32 n = (u32)0;
        u32 digits = (u32)0;
        while (i < t.byteLength() && t.byteAt(i) >= (u8)'0' && t.byteAt(i) <= (u8)'9') {
            n = n * (u32)10 + (u32)(t.byteAt(i) - (u8)'0');
            i = i + (u32)1;
            digits = digits + (u32)1;
        }
        if (digits == (u32)0 || i >= t.byteLength()) return SmeRef.no();
        u8 hv = t.byteAt(i);
        i = i + (u32)1;
        if (hv != (u8)'h' && hv != (u8)'v') return SmeRef.no();
        if (i + (u32)2 > t.byteLength() || t.byteAt(i) != (u8)'.') return SmeRef.no();
        u8 e = t.byteAt(i + (u32)1);
        u32 sz = e == (u8)'s' ? (u32)2 : (e == (u8)'d' ? (u32)3 : (u32)$FFFF_FFFF);
        if (sz == (u32)$FFFF_FFFF) return SmeRef.no();
        u32 lb = t.byteIndexOf(String.withCString("["));
        u32 rb = t.byteIndexOf(String.withCString("]"));
        if (lb != i + (u32)2 || rb != t.byteLength() - (u32)1) return SmeRef.no();
        Array* parts = smeSplit(t.substringBytes(lb + (u32)1, rb - lb - (u32)1));
        if (parts.count() != (u32)2) return SmeRef.no();
        String* w = ((String*)parts.get((u32)0)).trimmed();
        String* o = ((String*)parts.get((u32)1)).trimmed();
        if (o.hasPrefix(String.withCString("#"))) o = o.substringFromByte((u32)1);
        if (!w.hasPrefix(String.withCString("w"))) return SmeRef.no();
        u32 wn = smeDigits(w.substringFromByte((u32)1));
        u32 ov = smeDigits(o);
        if (wn == (u32)$FFFF_FFFF || ov == (u32)$FFFF_FFFF) return SmeRef.no();
        if (wn < (u32)12 || wn > (u32)15) return SmeRef.no();
        u32 maxTile = sz == (u32)2 ? (u32)3 : (u32)7;
        u32 maxOff = sz == (u32)2 ? (u32)3 : (u32)1;
        if (n > maxTile || ov > maxOff) return SmeRef.no();
        return SmeRef.yes(n, hv == (u8)'v' ? (u32)1 : (u32)0, sz, wn - (u32)12, ov);
    }

    // [xn] or [xn, xm, lsl #k] -> a = rn, b = rm or $FFFF_FFFF, c = k
    static SmeRef* smeMem(String* s)
    {
        if (!s.hasPrefix(String.withCString("[")) || !s.hasSuffix(String.withCString("]"))) return SmeRef.no();
        Array* parts = smeSplit(s.substringBytes((u32)1, s.byteLength() - (u32)2));
        RegRef* n = parseReg(((String*)parts.get((u32)0)).trimmed());
        if (!n.ok() || !n.is64()) return SmeRef.no();
        if (parts.count() == (u32)1) return SmeRef.yes(n.num(), (u32)$FFFF_FFFF, (u32)0, (u32)0, (u32)0);
        if (parts.count() != (u32)3) return SmeRef.no();
        RegRef* m = parseReg(((String*)parts.get((u32)1)).trimmed());
        if (!m.ok() || !m.is64() || m.isSP()) return SmeRef.no();
        String* sh = ((String*)parts.get((u32)2)).trimmed().lowercased();
        if (!sh.hasPrefix(String.withCString("lsl"))) return SmeRef.no();
        sh = sh.substringFromByte((u32)3);
        u32 a = (u32)0;
        u32 b = sh.byteLength();
        while (a < b && (sh.byteAt(a) == (u8)' ' || sh.byteAt(a) == (u8)'#')) a = a + (u32)1;
        while (b > a && (sh.byteAt(b - (u32)1) == (u8)' ' || sh.byteAt(b - (u32)1) == (u8)'#')) b = b - (u32)1;
        u32 k = smeDigits(sh.substringBytes(a, b - a));
        if (k == (u32)$FFFF_FFFF) return SmeRef.no();
        return SmeRef.yes(n.num(), m.num(), k, (u32)0, (u32)0);
    }

    u32 smeBad(String* mn, String* what)
    {
        String* m = new String();
        m.append(mn);
        m.append(String.withCString(": "));
        m.append(what);
        fail(m);
        _hit = true;
        return (u32)0;
    }

    u32 encSme(String* mn, u16 mc, Array* ops)
    {
        bool start = mc == a64Smstart;
        if (start || mc == a64Smstop) {
            u32 mask = (u32)3;
            if (ops.count() == (u32)1) {
                String* o = opAt(ops, (u32)0).lowercased();
                if (o.equals(String.withCString("sm"))) mask = (u32)1;
                else if (o.equals(String.withCString("za"))) mask = (u32)2;
                else return smeBad(mn, String.withCString("bad operand"));
            } else if (ops.count() != (u32)0) return smeBad(mn, String.withCString("takes at most one operand"));
            _hit = true;
            return (u32)$D503407F | (((mask << (u32)1) | (start ? (u32)1 : (u32)0)) << (u32)8);
        }
        if (mc == a64Ptrue) {
            SmeRef* p = ops.count() == (u32)1 ? smePReg(opAt(ops, (u32)0)) : SmeRef.no();
            if (!p.ok() || p.b() == (u32)$FFFF_FFFF) return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$2518E3E0 | (p.b() << (u32)22) | p.a();
        }
        bool lo = mc == a64Whilelo;
        if (lo || mc == a64Whilelt) {
            if (ops.count() != (u32)3) return smeBad(mn, String.withCString("bad operands"));
            SmeRef* p = smePReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            if (!p.ok() || p.b() == (u32)$FFFF_FFFF || !n.ok() || !m.ok() || n.is64() != m.is64())
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$25200400 | (lo ? (u32)$800 : (u32)0) | (p.b() << (u32)22) | (m.num() << (u32)16)
                 | ((n.is64() ? (u32)1 : (u32)0) << (u32)12) | (n.num() << (u32)5) | p.a();
        }
        u32 csz = (u32)$FFFF_FFFF;
        if (mc == a64Cntb) csz = 0;
        else if (mc == a64Cnth) csz = 1;
        else if (mc == a64Cntw) csz = 2;
        else if (mc == a64Cntd) csz = 3;
        if (csz != (u32)$FFFF_FFFF) {
            RegRef* d = ops.count() == (u32)1 ? parseReg(opAt(ops, (u32)0)) : RegRef.no();
            if (!d.ok() || !d.is64() || d.isSP()) return smeBad(mn, String.withCString("bad operand"));
            _hit = true;
            return (u32)$0420E3E0 | (csz << (u32)22) | d.num();
        }
        if (mc == a64Zero) {
            String* all = new String();
            for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) {
                if (i > (u32)0) all.append(String.withCString(","));
                all.append(opAt(ops, i));
            }
            Array* tiles = smeSplit(smeTrimBraces(all.lowercased()));
            u32 mask = (u32)0;
            for (u32 i = (u32)0; i < tiles.count(); i = i + (u32)1) {
                String* t = ((String*)tiles.get(i)).trimmed();
                if (t.equals(String.withCString("za"))) { mask = mask | (u32)$FF; continue; }
                u32 dot = t.byteIndexOf(String.withCString("."));
                String* bad = String.withCString("bad tile ");
                bad.append(t);
                if (!t.hasPrefix(String.withCString("za")) || dot == (u32)$FFFF_FFFF) return smeBad(mn, bad);
                u32 n = smeDigits(t.substringBytes((u32)2, dot - (u32)2));
                if (n == (u32)$FFFF_FFFF) return smeBad(mn, bad);
                String* e = t.substringFromByte(dot + (u32)1);
                if (e.equals(String.withCString("d")) && n <= (u32)7) mask = mask | ((u32)1 << n);
                else if (e.equals(String.withCString("s")) && n <= (u32)3) mask = mask | ((u32)$11 << n);
                else if (e.equals(String.withCString("h")) && n <= (u32)1) mask = mask | ((u32)$55 << n);
                else if (e.equals(String.withCString("b")) && n == (u32)0) mask = mask | (u32)$FF;
                else return smeBad(mn, bad);
            }
            _hit = true;
            return (u32)$C0080000 | mask;
        }
        bool isLd = mc == a64Ld1w || mc == a64Ld1d;
        bool isSt = mc == a64St1w || mc == a64St1d;
        if (isLd || isSt) {
            bool dw = mn.hasSuffix(String.withCString("d"));
            if (ops.count() != (u32)3) return smeBad(mn, String.withCString("bad operands"));
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* mem = smeMem(opAt(ops, (u32)2));
            if (!pg.ok() || pg.a() > (u32)7 || !mem.ok()) return smeBad(mn, String.withCString("bad operands"));
            if (isLd != opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/z")))
                return smeBad(mn, String.withCString(isLd ? "predicate must be /z" : "predicate must be plain"));
            bool indexed = mem.b() != (u32)$FFFF_FFFF;
            if (indexed && mem.c() != (dw ? (u32)3 : (u32)2))
                return smeBad(mn, String.withCString(dw ? "index must be lsl #3" : "index must be lsl #2"));
            SmeRef* za = smeZASlice(opAt(ops, (u32)0));
            if (za.ok()) {
                if (za.c() != (dw ? (u32)3 : (u32)2)) return smeBad(mn, String.withCString("tile element size"));
                u32 base = dw ? (isLd ? (u32)$E0C00000 : (u32)$E0E00000) : (isLd ? (u32)$E0800000 : (u32)$E0A00000);
                u32 zf = dw ? ((za.a() << (u32)1) | za.e()) : ((za.a() << (u32)2) | za.e());
                _hit = true;
                return base | ((indexed ? mem.b() : (u32)31) << (u32)16) | (za.b() << (u32)15) | (za.d() << (u32)13)
                     | (pg.a() << (u32)10) | (mem.a() << (u32)5) | zf;
            }
            SmeRef* zt = smeZReg(opAt(ops, (u32)0));
            if (!zt.ok() || zt.b() != (dw ? (u32)3 : (u32)2)) {
                String* bad = String.withCString("bad register list ");
                bad.append(opAt(ops, (u32)0));
                return smeBad(mn, bad);
            }
            u32 base;
            if (!indexed) base = dw ? (isLd ? (u32)$A5E0A000 : (u32)$E5E0E000) : (isLd ? (u32)$A540A000 : (u32)$E540E000);
            else base = (dw ? (isLd ? (u32)$A5E04000 : (u32)$E5E04000) : (isLd ? (u32)$A5404000 : (u32)$E5404000))
                      | (mem.b() << (u32)16);
            _hit = true;
            return base | (pg.a() << (u32)10) | (mem.a() << (u32)5) | zt.a();
        }
        if ((mc == a64Mov || mc == a64Mova) && ops.count() == 3
            && opAt(ops, (u32)2).lowercased().hasPrefix(String.withCString("za"))) {
            SmeRef* zd = smeZReg(opAt(ops, (u32)0));
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* za = smeZASlice(opAt(ops, (u32)2));
            if (!zd.ok() || !pg.ok() || pg.a() > (u32)7
                || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/m")) || !za.ok() || zd.b() != za.c())
                return smeBad(mn, String.withCString("bad operands"));
            u32 zf = za.c() == (u32)3 ? ((za.a() << (u32)1) | za.e()) : ((za.a() << (u32)2) | za.e());
            _hit = true;
            return (u32)$C0020000 | (za.c() << (u32)22) | (za.b() << (u32)15) | (za.d() << (u32)13)
                 | (pg.a() << (u32)10) | (zf << (u32)5) | zd.a();
        }
        if (mc == a64Fcmuo) {
            if (ops.count() != (u32)4) return smeBad(mn, String.withCString("bad operands"));
            SmeRef* pd = smePReg(opAt(ops, (u32)0));
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* zn = smeZReg(opAt(ops, (u32)2));
            SmeRef* zm = smeZReg(opAt(ops, (u32)3));
            if (!pd.ok() || !pg.ok() || pg.a() > (u32)7
                || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/z")) || !zn.ok() || !zm.ok()
                || (pd.b() != (u32)2 && pd.b() != (u32)3) || zn.b() != pd.b() || zm.b() != pd.b())
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$6500C000 | (pd.b() << (u32)22) | (zm.a() << (u32)16) | (pg.a() << (u32)10)
                 | (zn.a() << (u32)5) | pd.a();
        }
        // SVE integer forms the NaN scan uses, taken only when the first operand
        // is a Z register (the scalar and NEON and/mov/umax are untouched).
        SmeRef* z0 = ops.count() >= (u32)2 ? smeZReg(opAt(ops, (u32)0)) : SmeRef.no();
        bool firstZ = z0.ok() && !opAt(ops, (u32)0).lowercased().hasPrefix(String.withCString("za"));
        bool isAnd = mc == a64And && firstZ && ops.count() == 3
                  && opAt(ops, (u32)2).hasPrefix(String.withCString("#"));
        bool isMovI = (mc == a64Mov || mc == a64Dupm) && firstZ
                   && ops.count() == (u32)2 && opAt(ops, (u32)1).hasPrefix(String.withCString("#"));
        if (isAnd || isMovI) {
            U64* v = parseImm(opAt(ops, isAnd ? (u32)2 : (u32)1));
            if (!_immOk || (z0.b() != (u32)2 && z0.b() != (u32)3))
                return smeBad(mn, String.withCString("bad immediate"));
            if (isAnd) {
                SmeRef* zn = smeZReg(opAt(ops, (u32)1));
                if (!zn.ok() || zn.a() != z0.a() || zn.b() != z0.b())
                    return smeBad(mn, String.withCString("Zdn must repeat"));
            }
            bool small = (v.hi() == (u32)0 && v.lo() <= (u32)127)
                      || (v.hi() == (u32)$FFFFFFFF && v.lo() >= (u32)$FFFFFF80);
            if (isMovI && mc == a64Mov && small) {
                _hit = true;
                return (u32)$2538C000 | (z0.b() << (u32)22) | ((v.lo() & (u32)$FF) << (u32)5) | z0.a();
            }
            U64* u = v;
            if (z0.b() == (u32)2) {
                if (v.hi() != (u32)0)
                    return smeBad(mn, String.withCString("immediate out of range"));
                u = U64.with(v.lo(), v.lo()); // the 32-bit pattern, replicated
            }
            u32 bm = encodeLogImm(u, (u32)64);
            if (bm == (u32)$FFFF_FFFF)
                return smeBad(mn, String.withCString("not a bitmask immediate"));
            _hit = true;
            return (isAnd ? (u32)$05800000 : (u32)$05C00000) | (bm << (u32)5) | z0.a();
        }
        if (mc == a64Umax && firstZ && ops.count() == 4) {
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* zn = smeZReg(opAt(ops, (u32)2));
            SmeRef* zm = smeZReg(opAt(ops, (u32)3));
            if (!pg.ok() || pg.a() > (u32)7 || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/m"))
                || !zn.ok() || zn.a() != z0.a() || zn.b() != z0.b() || !zm.ok() || zm.b() != z0.b())
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$04090000 | (z0.b() << (u32)22) | (pg.a() << (u32)10) | (zm.a() << (u32)5) | z0.a();
        }
        // The integer kernel's forms (private:docs/Design/simd-sme-plan.md).
        // Base opcodes from clang's assembler, fields OR'd in.
        {
            // smopa/umopa/usmopa/sumopa ZAda.s, Pn/m, Pm/m, Zn.b, Zm.b (four to a
            // word); smopa/umopa ZAda.s, …, Zn.h, Zm.h (SME2, two to a word);
            // smopa/umopa ZAda.d, …, Zn.h, Zm.h (I16I64)
            u32 kind = mc == a64Smopa ? 0 : mc == a64Umopa ? 1
                     : mc == a64Usmopa ? 2 : mc == a64Sumopa ? 3 : 4;
            if (kind < (u32)4) {
                if (ops.count() != (u32)5) return smeBad(mn, String.withCString("needs 5 operands"));
                String* t = opAt(ops, (u32)0).lowercased();
                u32 dot = t.byteIndexOf(String.withCString("."));
                if (!t.hasPrefix(String.withCString("za")) || dot == (u32)$FFFF_FFFF) return smeBad(mn, String.withCString("bad tile"));
                u32 tile = smeDigits(t.substringBytes((u32)2, dot - (u32)2));
                if (tile == (u32)$FFFF_FFFF) return smeBad(mn, String.withCString("bad tile"));
                String* e = t.substringFromByte(dot + (u32)1);
                u32 tsz = e.equals(String.withCString("d")) ? (u32)3 : (e.equals(String.withCString("s")) ? (u32)2 : (u32)$FFFF_FFFF);
                SmeRef* pn = smePReg(opAt(ops, (u32)1));
                SmeRef* pm = smePReg(opAt(ops, (u32)2));
                SmeRef* zn = smeZReg(opAt(ops, (u32)3));
                SmeRef* zm = smeZReg(opAt(ops, (u32)4));
                if (tsz == (u32)$FFFF_FFFF || tile > (tsz == (u32)2 ? (u32)3 : (u32)7) || !pn.ok() || !pm.ok()
                    || pn.a() > (u32)7 || pm.a() > (u32)7 || !zn.ok() || !zm.ok() || zn.b() != zm.b())
                    return smeBad(mn, String.withCString("bad operands"));
                u32 base = (u32)0;
                if (tsz == (u32)2 && zn.b() == (u32)0)
                    base = kind == (u32)0 ? (u32)$A0800000 : kind == (u32)1 ? (u32)$A1A00000 : kind == (u32)2 ? (u32)$A1800000 : (u32)$A0A00000;
                else if (tsz == (u32)2 && zn.b() == (u32)1 && kind < (u32)2)
                    base = kind == (u32)1 ? (u32)$A1800008 : (u32)$A0800008;
                else if (tsz == (u32)3 && zn.b() == (u32)1 && kind < (u32)2)
                    base = kind == (u32)1 ? (u32)$A1E00000 : (u32)$A0C00000;
                else
                    return smeBad(mn, String.withCString("no such form"));
                _hit = true;
                return base | (zm.a() << (u32)16) | (pm.a() << (u32)13) | (pn.a() << (u32)10) | (zn.a() << (u32)5) | tile;
            }
            // uzp1/uzp2/zip1/zip2 Zd.T, Zn.T, Zm.T (the SVE forms; NEON's name v registers)
            u32 perm = mc == a64Uzp1 ? $05206800 : mc == a64Uzp2 ? $05206C00
                     : mc == a64Zip1 ? $05206000 : mc == a64Zip2 ? $05206400 : 0;
            if (perm != (u32)0 && firstZ && ops.count() == (u32)3) {
                SmeRef* zn = smeZReg(opAt(ops, (u32)1));
                SmeRef* zm = smeZReg(opAt(ops, (u32)2));
                if (!zn.ok() || !zm.ok() || zn.b() != z0.b() || zm.b() != z0.b()) return smeBad(mn, String.withCString("bad operands"));
                _hit = true;
                return perm | (z0.b() << (u32)22) | (zm.a() << (u32)16) | (zn.a() << (u32)5) | z0.a();
            }
            // orr Zd.d, Zn.d, Zm.d (unpredicated, bitwise)
            if (mc == a64Orr && firstZ && ops.count() == 3) {
                SmeRef* zn = smeZReg(opAt(ops, (u32)1));
                SmeRef* zm = smeZReg(opAt(ops, (u32)2));
                if (!zn.ok() || !zm.ok() || z0.b() != (u32)3 || zn.b() != (u32)3 || zm.b() != (u32)3)
                    return smeBad(mn, String.withCString("bad vector operands"));
                _hit = true;
                return (u32)$04603000 | (zm.a() << (u32)16) | (zn.a() << (u32)5) | z0.a();
            }
            // lsl Zd.T, Zn.T, #shift (unpredicated)
            if (mc == a64Lsl && firstZ && ops.count() == 3 && opAt(ops, 2).hasPrefix(String.withCString("#"))) {
                SmeRef* zn = smeZReg(opAt(ops, (u32)1));
                U64* v = parseImm(opAt(ops, (u32)2));
                if (!zn.ok() || zn.b() != z0.b() || !_immOk || v.hi() != (u32)0 || v.lo() >= ((u32)8 << z0.b()))
                    return smeBad(mn, String.withCString("bad vector operands"));
                u32 tsz = ((u32)8 << z0.b()) + v.lo();  // tszh:tszl:imm3 = element size + shift
                _hit = true;
                return (u32)$04209C00 | ((tsz >> (u32)5) << (u32)22) | (((tsz >> (u32)3) & (u32)3) << (u32)19) | ((tsz & (u32)7) << (u32)16)
                     | (zn.a() << (u32)5) | z0.a();
            }
            // smax/smin Zdn.T, Pg/m, Zdn.T, Zm.T (umax is above, with the NaN scan's forms)
            bool isSmax = mc == a64Smax;
            if ((isSmax || mc == a64Smin) && firstZ && ops.count() == 4) {
                SmeRef* pg = smePReg(opAt(ops, (u32)1));
                SmeRef* zn = smeZReg(opAt(ops, (u32)2));
                SmeRef* zm = smeZReg(opAt(ops, (u32)3));
                if (!pg.ok() || pg.a() > (u32)7 || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/m"))
                    || !zn.ok() || zn.a() != z0.a() || zn.b() != z0.b() || !zm.ok() || zm.b() != z0.b())
                    return smeBad(mn, String.withCString("bad operands"));
                _hit = true;
                return (isSmax ? (u32)$04080000 : (u32)$040A0000) | (z0.b() << (u32)22) | (pg.a() << (u32)10) | (zm.a() << (u32)5) | z0.a();
            }
            // umaxv/smaxv/sminv Vd, Pg, Zn.T: the reduction to a scalar
            u32 redv = mc == a64Umaxv ? $04092000 : mc == a64Smaxv ? $04082000
                     : mc == a64Sminv ? $040A2000 : 0;
            if (redv != (u32)0 && ops.count() == (u32)3) {
                String* vd = opAt(ops, (u32)0).lowercased();
                u8 c0 = vd.byteLength() > (u32)1 ? vd.byteAt((u32)0) : (u8)0;
                u32 vs = c0 == (u8)'b' ? (u32)0 : c0 == (u8)'h' ? (u32)1 : c0 == (u8)'s' ? (u32)2 : c0 == (u8)'d' ? (u32)3 : (u32)$FFFF_FFFF;
                u32 rd = vd.byteLength() > (u32)1 ? smeDigits(vd.substringFromByte((u32)1)) : (u32)$FFFF_FFFF;
                SmeRef* pg = smePReg(opAt(ops, (u32)1));
                SmeRef* zn = smeZReg(opAt(ops, (u32)2));
                if (vs == (u32)$FFFF_FFFF || rd == (u32)$FFFF_FFFF || rd > (u32)31 || !pg.ok() || pg.b() != (u32)$FFFF_FFFF || pg.a() > (u32)7
                    || !zn.ok() || zn.b() != vs)
                    return smeBad(mn, String.withCString("bad operands"));
                _hit = true;
                return redv | (zn.b() << (u32)22) | (pg.a() << (u32)10) | (zn.a() << (u32)5) | rd;
            }
            // dup Zd.T, Wn|Xn (a scalar broadcast)
            if (mc == a64Dup && firstZ && ops.count() == 2 && !opAt(ops, 1).hasPrefix(String.withCString("#"))) {
                RegRef* rn = parseReg(opAt(ops, (u32)1));
                if (!rn.ok() || rn.isSP()) return smeBad(mn, String.withCString("bad scalar operand"));
                _hit = true;
                return (u32)$05203800 | (z0.b() << (u32)22) | (rn.num() << (u32)5) | z0.a();
            }
            // mov|mova ZA<t><h|v>.T[Ws, off], Pg/m, Zn.T  (vector to tile slice)
            if ((mc == a64Mov || mc == a64Mova) && ops.count() == 3
                && opAt(ops, (u32)0).lowercased().hasPrefix(String.withCString("za"))) {
                SmeRef* za = smeZASlice(opAt(ops, (u32)0));
                SmeRef* pg = smePReg(opAt(ops, (u32)1));
                SmeRef* zn = smeZReg(opAt(ops, (u32)2));
                if (!za.ok() || !pg.ok() || pg.a() > (u32)7 || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/m"))
                    || !zn.ok() || zn.b() != za.c())
                    return smeBad(mn, String.withCString("bad operands"));
                u32 zf = za.c() == (u32)3 ? ((za.a() << (u32)1) | za.e()) : ((za.a() << (u32)2) | za.e());
                _hit = true;
                return (u32)$C0800000 | (za.c() << (u32)22) | (za.b() << (u32)15) | (za.d() << (u32)13) | (pg.a() << (u32)10)
                     | (zn.a() << (u32)5) | zf;
            }
        }
        if (mc == a64Cmphi) {
            if (ops.count() != (u32)4) return smeBad(mn, String.withCString("bad operands"));
            SmeRef* pd = smePReg(opAt(ops, (u32)0));
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* zn = smeZReg(opAt(ops, (u32)2));
            SmeRef* zm = smeZReg(opAt(ops, (u32)3));
            if (!pd.ok() || pd.b() == (u32)$FFFF_FFFF || !pg.ok() || pg.a() > (u32)7
                || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/z")) || !zn.ok() || !zm.ok()
                || zn.b() != pd.b() || zm.b() != pd.b())
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$24001010 | (pd.b() << (u32)22) | (zm.a() << (u32)16) | (pg.a() << (u32)10)
                 | (zn.a() << (u32)5) | pd.a();
        }
        if (mc == a64Rdsvl) {
            RegRef* d = ops.count() == (u32)2 ? parseReg(opAt(ops, (u32)0)) : RegRef.no();
            String* im = opAt(ops, (u32)1);
            if (!d.ok() || !d.is64() || d.isSP() || !im.hasPrefix(String.withCString("#")))
                return smeBad(mn, String.withCString("bad operands"));
            // `#` and an optional `-` before plain digits
            bool neg = im.hasPrefix(String.withCString("#-"));
            u32 mag = smeDigits(im.substringFromByte(neg ? (u32)2 : (u32)1));
            if (mag == (u32)$FFFF_FFFF || mag > (neg ? (u32)32 : (u32)31))
                return smeBad(mn, String.withCString("bad operands"));
            u32 field = neg ? (((u32)64 - mag) & (u32)$3F) : mag;
            _hit = true;
            return (u32)$04BF5800 | (field << (u32)5) | d.num();
        }
        if (mc == a64Pfalse) {
            SmeRef* pd = ops.count() == (u32)1 ? smePReg(opAt(ops, (u32)0)) : SmeRef.no();
            if (!pd.ok() || pd.b() != (u32)0)
                return smeBad(mn, String.withCString("bad operand"));
            _hit = true;
            return (u32)$2518E400 | pd.a();
        }
        // The predicate form of orr; the scalar and NEON forms never name a p register.
        if (mc == a64Orr && ops.count() == 4
            && opAt(ops, (u32)0).lowercased().hasPrefix(String.withCString("p"))) {
            SmeRef* pd = smePReg(opAt(ops, (u32)0));
            SmeRef* pg = smePReg(opAt(ops, (u32)1));
            SmeRef* pn = smePReg(opAt(ops, (u32)2));
            SmeRef* pm = smePReg(opAt(ops, (u32)3));
            if (!pd.ok() || pd.b() != (u32)0 || !pg.ok() || !opAt(ops, (u32)1).lowercased().hasSuffix(String.withCString("/z"))
                || !pn.ok() || pn.b() != (u32)0 || !pm.ok() || pm.b() != (u32)0)
                return smeBad(mn, String.withCString("bad predicate operands"));
            _hit = true;
            return (u32)$25804000 | (pm.a() << (u32)16) | (pg.a() << (u32)10) | (pn.a() << (u32)5) | pd.a();
        }
        if (mc == a64Ptest) {
            if (ops.count() != (u32)2) return smeBad(mn, String.withCString("bad operands"));
            SmeRef* pg = smePReg(opAt(ops, (u32)0));
            SmeRef* pn = smePReg(opAt(ops, (u32)1));
            String* g = opAt(ops, (u32)0).lowercased();
            if (!pg.ok() || pg.b() != (u32)$FFFF_FFFF || !pn.ok() || pn.b() != (u32)0
                || g.hasSuffix(String.withCString("/z")) || g.hasSuffix(String.withCString("/m")))
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (u32)$2550C000 | (pg.a() << (u32)10) | (pn.a() << (u32)5);
        }
        if (mc == a64Fmopa) {
            if (ops.count() != (u32)5) return smeBad(mn, String.withCString("needs 5 operands"));
            String* t = opAt(ops, (u32)0).lowercased();
            u32 dot = t.byteIndexOf(String.withCString("."));
            if (!t.hasPrefix(String.withCString("za")) || dot == (u32)$FFFF_FFFF) return smeBad(mn, String.withCString("bad tile"));
            u32 tile = smeDigits(t.substringBytes((u32)2, dot - (u32)2));
            if (tile == (u32)$FFFF_FFFF) return smeBad(mn, String.withCString("bad tile"));
            String* e = t.substringFromByte(dot + (u32)1);
            u32 tsz = e.equals(String.withCString("d")) ? (u32)3 : (e.equals(String.withCString("s")) ? (u32)2 : (u32)$FFFF_FFFF);
            SmeRef* pn = smePReg(opAt(ops, (u32)1));
            SmeRef* pm = smePReg(opAt(ops, (u32)2));
            SmeRef* zn = smeZReg(opAt(ops, (u32)3));
            SmeRef* zm = smeZReg(opAt(ops, (u32)4));
            if (tsz == (u32)$FFFF_FFFF || tile > (tsz == (u32)2 ? (u32)3 : (u32)7) || !pn.ok() || !pm.ok()
                || pn.a() > (u32)7 || pm.a() > (u32)7 || !zn.ok() || !zm.ok() || zn.b() != tsz || zm.b() != tsz)
                return smeBad(mn, String.withCString("bad operands"));
            _hit = true;
            return (tsz == (u32)2 ? (u32)$80800000 : (u32)$80C00000) | (zm.a() << (u32)16) | (pm.a() << (u32)13)
                 | (pn.a() << (u32)10) | (zn.a() << (u32)5) | tile;
        }
        return (u32)0;
    }

    static String* stripBraces(String* s)
    {
        String* out = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)'{' || c == (u8)'}') continue;
            out.appendByte(c);
        }
        return out.trimmed();
    }

    // Zero means "not in this table" — none of the real base opcodes is zero.
    static u32 neonInt3(u16 mc)
    {
        if (mc == a64Add)  return $0E208400;
        if (mc == a64Sub)  return $2E208400;
        if (mc == a64Mul)  return $0E209C00;
        if (mc == a64Mla)  return $0E209400;
        if (mc == a64Mls)  return $2E209400;
        if (mc == a64Smax) return $0E206400;
        if (mc == a64Smin) return $0E206C00;
        if (mc == a64Umax) return $2E206400;
        if (mc == a64Umin) return $2E206C00;
        if (mc == a64Cmeq) return $2E208C00;
        if (mc == a64Cmgt) return $0E203400;
        if (mc == a64Cmge) return $0E203C00;
        if (mc == a64Cmhi) return $2E203400;
        if (mc == a64Cmhs) return $2E203C00;
        if (mc == a64Sshl) return $0E204400;
        if (mc == a64Ushl) return $2E204400;
        if (mc == a64Saba) return $0E207C00;
        if (mc == a64Uaba) return $2E207C00;
        if (mc == a64Sabd) return $0E207400;
        if (mc == a64Uabd) return $2E207400;
        return (u32)0;
    }

    static u32 neonLogic3(u16 mc)
    {
        if (mc == a64And) return $0E201C00;
        if (mc == a64Bic) return $0E601C00;
        if (mc == a64Orr) return $0EA01C00;
        if (mc == a64Orn) return $0EE01C00;
        if (mc == a64Eor) return $2E201C00;
        // Bitwise select: bsl takes the mask in Vd, bit/bif in Vm (insert
        // Vn's bits where the mask is set / clear).
        if (mc == a64Bsl) return $2E601C00;
        if (mc == a64Bit) return $2EA01C00;
        if (mc == a64Bif) return $2EE01C00;
        return (u32)0;
    }

    static u32 neonFloat3(u16 mc)
    {
        if (mc == a64Fadd)  return $0E20D400;
        if (mc == a64Fsub)  return $0EA0D400;
        if (mc == a64Fmul)  return $2E20DC00;
        if (mc == a64Fdiv)  return $2E20FC00;
        if (mc == a64Fmla)  return $0E20CC00;
        if (mc == a64Fmls)  return $0EA0CC00;
        if (mc == a64Fmax)  return $0E20F400;
        if (mc == a64Fmin)  return $0EA0F400;
        if (mc == a64Fcmeq) return $0E20E400;
        if (mc == a64Fcmgt) return $2EA0E400;
        if (mc == a64Fcmge) return $2E20E400;
        // FADDP (vector): the P form is the base with bit 29 set, so .4s is
        // 0x6E20D400 (verified against the host assembler). The float
        // horizontal reduction uses it.
        if (mc == a64Faddp) return $2E20D400;
        return (u32)0;
    }

    static u32 neonMisc2i(u16 mc)
    {
        if (mc == a64Neg)   return $2E20B800;
        if (mc == a64Abs)   return $0E20B800;
        if (mc == a64Not)   return $2E205800;
        if (mc == a64Mvn)   return $2E205800;
        if (mc == a64Cnt)   return $0E205800;
        if (mc == a64Rev64) return $0E200800;
        if (mc == a64Rev16) return $0E201800;
        if (mc == a64Rev32) return $2E200800;
        return (u32)0;
    }

    static u32 neonMisc2f(u16 mc)
    {
        if (mc == a64Fneg)   return $2EA0F800;
        if (mc == a64Fabs)   return $0EA0F800;
        if (mc == a64Scvtf)  return $0E21D800;
        if (mc == a64Ucvtf)  return $2E21D800;
        if (mc == a64Fcvtzs) return $0EA1B800;
        if (mc == a64Fcvtzu) return $2EA1B800;
        if (mc == a64Frintz) return $0EA19800;
        // FSQRT (vector): the P form, .4s = 0x6EA1F800.
        if (mc == a64Fsqrt)  return $2EA1F800;
        return (u32)0;
    }

    static u32 neonReduce(u16 mc)
    {
        if (mc == a64Addv)   return $0E31B800;
        if (mc == a64Saddlv) return $0E303800;
        if (mc == a64Uaddlv) return $2E303800;
        if (mc == a64Smaxv)  return $0E30A800;
        if (mc == a64Sminv)  return $0E31A800;
        if (mc == a64Umaxv)  return $2E30A800;
        if (mc == a64Uminv)  return $2E31A800;
        return (u32)0;
    }

    // Pairwise add long: adds ADJACENT lanes of Vn and widens, so the
    // destination arrangement is HALF the lane count at twice the width
    // (`uaddlp v0.4s, v1.8h`). Both Q and size come from the SOURCE, unlike
    // every other 2-register form here — which is why it gets its own case.
    // The vectoriser's widening-sum reduction emits it (bug 028).
    static u32 neonPairLong(u16 mc)
    {
        if (mc == a64Saddlp) return $0E202800;
        if (mc == a64Uaddlp) return $2E202800;
        return (u32)0;
    }

    // Widening 3-different: multiplies the lanes of Vn and Vm into a
    // destination of HALF the lane count at twice the width
    // (`umull v0.2d, v1.2s, v2.2s`). The `2` suffix is the same instruction
    // reading the HIGH half of its sources, which is what Q selects — so Q and
    // size both come from the SOURCE, as they do for neonPairLong.
    // The vectoriser's VMulHi emits the pair to build a 32x32 high half.
    static u32 neonWiden3(u16 mc)
    {
        if (mc == a64Smull)  return $0E20C000;
        if (mc == a64Umull)  return $2E20C000;
        if (mc == a64Smull2) return $0E20C000;
        if (mc == a64Umull2) return $2E20C000;
        return (u32)0;
    }

    // Shift right by immediate. immh:immb holds (2*esize - shift), so the
    // encoded field GROWS as the shift shrinks and a shift of 0 is not
    // encodable at all — callers emit a move instead.
    static u32 neonShrImm(u16 mc)
    {
        if (mc == a64Ushr) return $2F000400;
        if (mc == a64Sshr) return $0F000400;
        // Shift right and accumulate into Vd (a rotate's second half).
        if (mc == a64Usra) return $2F001400;
        return (u32)0;
    }

    static u32 neonPerm(u16 mc)
    {
        if (mc == a64Zip1) return $0E003800;
        if (mc == a64Zip2) return $0E007800;
        if (mc == a64Uzp1) return $0E001800;
        if (mc == a64Uzp2) return $0E005800;
        if (mc == a64Trn1) return $0E002800;
        if (mc == a64Trn2) return $0E006800;
        return (u32)0;
    }

    static u32 neonElem(u16 mc)
    {
        if (mc == a64Fmla) return $0F801000;
        if (mc == a64Fmls) return $0F805000;
        if (mc == a64Fmul) return $0F809000;
        if (mc == a64Mul)  return $0F808000;
        if (mc == a64Mla)  return $2F800000;
        if (mc == a64Mls)  return $6F804000;
        return (u32)0;
    }

    // ── mov / movz / movk / movn ─────────────────────────────────────────
    u32 encMoves(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64Mov) {
            if (ops.count() < (u32)2) { fail(String.withCString("mov needs 2 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            if (!d.ok()) { fail(String.withCString("bad mov destination")); return (u32)0; }
            if (opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
                U64* imm = parseImm(opAt(ops, (u32)1));
                if (!_immOk) { fail(String.withCString("bad mov immediate")); return (u32)0; }
                _hit = true;
                return encMovImm(d, imm);
            }
            RegRef* m = parseReg(opAt(ops, (u32)1));
            if (!m.ok()) { fail(String.withCString("bad mov source")); return (u32)0; }
            _hit = true;
            // Anything touching SP becomes `add Rd, Rm, #0`: the orr-with-zero
            // form cannot name the stack pointer.
            if (d.isSP() || m.isSP())
                return (d.is64() ? (u32)$91000000 : (u32)$11000000) | (m.num() << (u32)5) | d.num();
            return (d.is64() ? (u32)$AA0003E0 : (u32)$2A0003E0) | (m.num() << (u32)16) | d.num();
        }
        if (mc == a64Movz || mc == a64Movk
         || mc == a64Movn) {
            if (ops.count() < (u32)2) { fail(String.withCString("movz/movk needs 2 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            if (!d.ok()) { fail(String.withCString("bad movz destination")); return (u32)0; }
            U64* imm = parseImm(opAt(ops, (u32)1));
            if (!_immOk) { fail(String.withCString("bad movz immediate")); return (u32)0; }
            // The immediate is 16 bits and the shift a multiple of 16 that
            // stays inside the register; both used to be masked, so
            // `movz x0, #0x12345` became #0x2345 and `lsl #8` shift 0.
            if (imm.hi() != (u32)0 || imm.lo() > (u32)$FFFF) {
                fail(String.withCString("movz/movk/movn immediate is wider than 16 bits"));
                return (u32)0;
            }
            u32 hw = (u32)0;
            if (ops.count() >= (u32)3) {
                String* sh = opAt(ops, (u32)2);
                u32 h = sh.byteIndexOf(String.withCString("#"));
                if (h != (u32)$FFFF_FFFF) {
                    U64* sv = parseImm(sh.substringFromByte(h));
                    if (_immOk) {
                        if (sv.hi() != (u32)0 || (sv.lo() % (u32)16) != (u32)0
                            || sv.lo() / (u32)16 > (d.is64() ? (u32)3 : (u32)1)) {
                            fail(String.withCString("movz/movk/movn shift must be lsl #0, 16, 32 or 48 (0 or 16 for a W register)"));
                            return (u32)0;
                        }
                        hw = sv.lo() / (u32)16;
                    }
                }
            }
            u32 base = mc == a64Movk ? (d.is64() ? $F2800000 : $72800000)
                     : mc == a64Movn ? (d.is64() ? $92800000 : $12800000)
                                                             : (d.is64() ? (u32)$D2800000 : (u32)$52800000);
            _hit = true;
            return base | (hw << (u32)21) | ((imm.lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        return (u32)0;
    }

    // One instruction only — clang spells wider constants as an explicit
    // movz/movk pair, so this never has to invent a second word. MOVZ first,
    // then MOVN of the complement, then ORR of a bitmask.
    u32 encMovImm(RegRef* d, U64* imm)
    {
        u32 nsh = d.is64() ? (u32)4 : (u32)2;
        U64* u = d.is64() ? imm : U64.with((u32)0, imm.lo());
        for (u32 sft = (u32)0; sft < nsh; sft = sft + (u32)1) {
            U64* mask = U64.fromU32((u32)$FFFF).shl((u32)16 * sft);
            if (u.anded(mask.notted()).isZero())
                return (d.is64() ? (u32)$D2800000 : (u32)$52800000) | (sft << (u32)21)
                     | ((u.shr((u32)16 * sft).lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        U64* nv = u.notted();
        if (!d.is64()) nv = U64.with((u32)0, nv.lo());
        for (u32 sft = (u32)0; sft < nsh; sft = sft + (u32)1) {
            U64* mask = U64.fromU32((u32)$FFFF).shl((u32)16 * sft);
            if (nv.anded(mask.notted()).isZero())
                return (d.is64() ? (u32)$92800000 : (u32)$12800000) | (sft << (u32)21)
                     | ((nv.shr((u32)16 * sft).lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        u32 bm = encodeLogImm(u, d.is64() ? (u32)64 : (u32)32);
        if (bm != (u32)$FFFF_FFFF)
            return (d.is64() ? (u32)$B2000000 : (u32)$32000000) | (bm << (u32)10)
                 | ((u32)31 << (u32)5) | d.num();
        fail(String.withCString("mov immediate needs more than one instruction"));
        _hit = false;
        return (u32)0;
    }

    // ── Scalar floating point ────────────────────────────────────────────
    //
    // Bit 22 ("ty") selects single from double throughout.
    u32 encFloat(String* mn, u16 mc, Array* ops, u32 pc)
    {
        bool fLike = mn.hasPrefix(String.withCString("f"))
                  || mc == a64Scvtf
                  || mc == a64Ucvtf;
        if (!fLike) return (u32)0;

        FRegRef* d = parseFReg(opAt(ops, (u32)0));

        // The four 3-source FP ops share one encoding group; o1 (bit 21) and
        // o0 (bit 15) select which: fmadd 00, fmsub 01, fnmadd 10, fnmsub 11.
        if ((mc == a64Fmadd || mc == a64Fmsub
             || mc == a64Fnmadd || mc == a64Fnmsub)
            && ops.count() == (u32)4 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            FRegRef* a = parseFReg(opAt(ops, (u32)3));
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            u32 base = (u32)$1F000000;
            if (mc == a64Fmsub)  base = $1F008000;
            if (mc == a64Fnmadd) base = $1F200000;
            if (mc == a64Fnmsub) base = $1F208000;
            _hit = true;
            return base | ty | (m.num() << (u32)16) | (a.num() << (u32)10)
                 | (n.num() << (u32)5) | d.num();
        }
        u32 f3 = fpArith3(mc);
        if (f3 != (u32)0 && ops.count() == (u32)3 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            // ftype (bits 23:22): 00 single, 01 double, 11 half (FEAT_FP16).
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : d.sz() == 1 ? $00C00000 : (u32)0;
            _hit = true;
            return f3 | ty | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
        }
        // fcsel — the FP conditional select. The integer csel cannot take an FP
        // destination, so a float `?:` or an if-converted `if (x < 0) x = -x`
        // needs this one.
        if (mc == a64Fcsel && ops.count() == 4 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad fcsel condition")); return (u32)0; }
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return (u32)$1E200C00 | ty | (m.num() << (u32)16) | ((u32)cc << (u32)12)
                 | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Fneg || mc == a64Fsqrt) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : d.sz() == 1 ? $00C00000 : (u32)0;
            u32 base = mc == a64Fneg ? $1E214000 : $1E21C000;
            _hit = true;
            return base | ty | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Fcmp) {
            FRegRef* n = parseFReg(opAt(ops, (u32)0));
            FRegRef* m = parseFReg(opAt(ops, (u32)1));
            u32 ty = n.sz() == (u32)3 ? (u32)$00400000 : n.sz() == 1 ? $00C00000 : (u32)0;
            _hit = true;
            return (u32)$1E202000 | ty | (m.num() << (u32)16) | (n.num() << (u32)5);
        }
        if (mc == a64Fcvt) {
            // ftype (bits 23:22) the source's size, opc (bits 16:15) the
            // destination's: 00 single, 01 double, 11 half. As the reference.
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            bool okd = ops.count() == 2 && d.ok() && d.sz() >= 1 && d.sz() <= 3;
            bool okn = ops.count() == 2 && n.ok() && n.sz() >= 1 && n.sz() <= 3;
            if (!okd || !okn || d.sz() == n.sz()) { fail(String.withCString("unsupported fcvt")); return (u32)0; }
            u32 ft = n.sz() == 1 ? 3 : n.sz() - 2;
            u32 opc = d.sz() == 1 ? 3 : d.sz() - 2;
            _hit = true;
            return $1E224000 | (ft << 22) | (opc << 15) | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Fmov) return encFmov(ops);

        // The SIMD-scalar round-trip forms keep an integer in an FP register:
        // scvtf/ucvtf take one as their SOURCE, fcvtzs/fcvtzu produce one as
        // their DESTINATION, and that operand being d/s rather than a GPR is
        // what selects this encoding over the GPR one below.
        bool toFP = mc == a64Scvtf || mc == a64Ucvtf;
        bool isFcvtz = mc == a64Fcvtzs || mc == a64Fcvtzu;
        if (toFP || isFcvtz) {
            String* discr = toFP ? opAt(ops, (u32)1) : opAt(ops, (u32)0);
            bool discrIsFP = discr.byteLength() > (u32)0
                && (discr.byteAt((u32)0) == (u8)'d' || discr.byteAt((u32)0) == (u8)'s');
            if (discrIsFP) {
                FRegRef* n = parseFReg(opAt(ops, (u32)1));
                u32 dbl = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
                u32 base;
                if (mc == a64Scvtf)       base = $5E21D800 | dbl;
                else if (mc == a64Ucvtf)  base = $7E21D800 | dbl;
                else if (mc == a64Fcvtzs) base = $5EA1B800 | dbl;
                else                                              base = (u32)$7EA1B800 | dbl;
                _hit = true;
                return base | (n.num() << (u32)5) | d.num();
            }
        }
        if (toFP) {
            RegRef* n = parseReg(opAt(ops, (u32)1));
            if (ops.count() >= (u32)3 && opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
                U64* fb = parseImm(opAt(ops, (u32)2));
                u32 base = mc == a64Scvtf ? $1E020000 : $1E030000;
                u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
                u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
                u32 scale = (u32)64 - fb.lo();
                _hit = true;
                return base | sf | ty | (scale << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            u32 base = mc == a64Scvtf
                     ? (d.sz() == (u32)3 ? (u32)$1E620000 : (u32)$1E220000)
                     : (d.sz() == (u32)3 ? (u32)$1E630000 : (u32)$1E230000);
            u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return base | sf | (n.num() << (u32)5) | d.num();
        }
        if (isFcvtz) {
            RegRef* rd = parseReg(opAt(ops, (u32)0));
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            u32 base = mc == a64Fcvtzs
                     ? (n.sz() == (u32)3 ? (u32)$1E780000 : (u32)$1E380000)
                     : (n.sz() == (u32)3 ? (u32)$1E790000 : (u32)$1E390000);
            u32 sf = rd.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return base | sf | (n.num() << (u32)5) | rd.num();
        }
        return (u32)0;
    }

    static u32 fpArith3(u16 mc)
    {
        if (mc == a64Fadd) return $1E202800;
        if (mc == a64Fsub) return $1E203800;
        if (mc == a64Fmul) return $1E200800;
        if (mc == a64Fdiv) return $1E201800;
        return (u32)0;
    }

    u32 encFmov(Array* ops)
    {
        FRegRef* d = parseFReg(opAt(ops, (u32)0));
        if (ops.count() >= (u32)2 && d.ok()
            && opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
            _hit = true;
            return encFmovImm(d, opAt(ops, (u32)1).substringFromByte((u32)1));
        }
        FRegRef* n = parseFReg(opAt(ops, (u32)1));
        if (d.ok() && n.ok()) {
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return (u32)$1E204000 | ty | (n.num() << (u32)5) | d.num();
        }
        RegRef* gn = parseReg(opAt(ops, (u32)1));
        if (d.ok() && gn.ok()) {                        // GPR -> FP
            u32 base = d.sz() == (u32)3 ? (u32)$9E670000 : (u32)$1E270000;
            _hit = true;
            return base | (gn.num() << (u32)5) | d.num();
        }
        RegRef* gd = parseReg(opAt(ops, (u32)0));
        if (gd.ok() && n.ok()) {                        // FP -> GPR
            u32 base = n.sz() == (u32)3 ? (u32)$9E660000 : (u32)$1E260000;
            _hit = true;
            return base | (n.num() << (u32)5) | gd.num();
        }
        fail(String.withCString("unsupported fmov"));
        return (u32)0;
    }

    // The 8-bit FP immediate is found by BRUTE FORCE — all 256 patterns are
    // expanded and compared. There is a closed form, but the search is 256
    // iterations at assembly time and cannot get the rounding subtly wrong.
    // The comparison is on the decimal SPELLING, because reconstructing a
    // double from text is exactly the problem BigNat exists to solve, and an
    // 8-bit immediate has only 256 possible spellings to match against.
    u32 encFmovImm(FRegRef* d, String* text)
    {
        bool dbl = d.sz() == (u32)3;
        String* want = normaliseFpText(text);
        for (u32 i = (u32)0; i < (u32)256; i = i + (u32)1) {
            if (!normaliseFpText(vfpExpandText(i)).equals(want)) continue;
            return (dbl ? (u32)$1E601000 : (u32)$1E201000) | (i << (u32)13) | d.num();
        }
        fail(String.withCString("fmov immediate is not an 8-bit fp immediate"));
        _hit = false;
        return (u32)0;
    }

    // VFPExpandImm renders exactly: a sign, a 4-bit mantissa over 16, and a
    // power of two — so the value is +/- (16+m)/16 * 2^e, a dyadic rational
    // whose decimal expansion terminates. The single and double forms describe
    // the SAME 256 values, so the width does not enter here.
    //
    //   b6 = 1  ->  biased exponent 124+lowExp, so e = lowExp - 3
    //   b6 = 0  ->  biased exponent 128+lowExp, so e = lowExp + 1
    static String* vfpExpandText(u32 i)
    {
        u32 sign = (i >> (u32)7) & (u32)1;
        u32 b6 = (i >> (u32)6) & (u32)1;
        u32 lowExp = (i >> (u32)4) & (u32)3;
        u32 mant = i & (u32)$F;
        i32 e = b6 != (u32)0 ? ((i32)lowExp - (i32)3) : ((i32)lowExp + (i32)1);
        return fpDecimalText(sign != (u32)0, (u32)16 + mant, e);
    }

    // (num/16) * 2^e as an exact decimal string. e is in [-4, 4] here, so the
    // result never needs more than a handful of fractional digits.
    static String* fpDecimalText(bool neg, u32 num, i32 e)
    {
        // value = num * 2^e / 16 = num * 2^(e-4).
        i32 shift = e - (i32)4;
        u32 intPart;
        u32 fracNum;
        u32 fracDen;
        if (shift >= (i32)0) {
            intPart = num << (u32)shift;
            fracNum = (u32)0; fracDen = (u32)1;
        } else {
            u32 den = (u32)1 << (u32)(-shift);
            intPart = num / den;
            fracNum = num - intPart * den;
            fracDen = den;
        }
        String* o = new String();
        if (neg) o.appendCString("-");
        o.appendFormat("%lu", intPart);
        if (fracNum != (u32)0) {
            o.appendCString(".");
            // Long division, at most as many digits as the denominator has bits.
            for (u32 k = (u32)0; k < (u32)12 && fracNum != (u32)0; k = k + (u32)1) {
                fracNum = fracNum * (u32)10;
                u32 digit = fracNum / fracDen;
                fracNum = fracNum - digit * fracDen;
                o.appendByte((u8)((u32)'0' + digit));
            }
        }
        return o;
    }

    // Drop a leading `+`, a trailing `.0`, and any trailing zeros after a
    // decimal point, so `2.0`, `2.` and `2` all compare equal.
    static String* normaliseFpText(String* t0)
    {
        String* t = t0.trimmed();
        if (t.hasPrefix(String.withCString("+"))) t = t.substringFromByte((u32)1);
        if (t.byteIndexOf(String.withCString(".")) == (u32)$FFFF_FFFF) return t;
        u32 end = t.byteLength();
        while (end > (u32)0 && t.byteAt(end - (u32)1) == (u8)'0') end = end - (u32)1;
        if (end > (u32)0 && t.byteAt(end - (u32)1) == (u8)'.') end = end - (u32)1;
        return t.substringBytes((u32)0, end);
    }

    // ── add / sub / cmp / neg, and the logical group ─────────────────────
    u32 encAddSubLogic(String* mn, u16 mc, Array* ops, u32 pc)
    {
        // add Xd, Xn, sym@PAGEOFF — the second half of an adrp pair. The imm12
        // is left at zero and the linker fills it in.
        if (mc == a64Add && ops.count() >= 3
            && opAt(ops, (u32)2).byteIndexOf(String.withCString("@")) != (u32)$FFFF_FFFF) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            String* sym = opAt(ops, (u32)2);
            String* bare = sym.substringBytes((u32)0, sym.byteIndexOf(String.withCString("@")));
            addFixup(pc, (u32)FIXUP_PAGEOFF12, bare, (u32)0);
            _hit = true;
            return (d.is64() ? (u32)$91000000 : (u32)$11000000) | (n.num() << (u32)5) | d.num();
        }
        u32 immBase = addSubImmBase(mc);
        bool isCmp = mc == a64Cmp || mc == a64Cmn;
        bool isNeg = mc == a64Neg;
        if (immBase != (u32)0 || isCmp || isNeg) {
            u16 key = isCmp ? (mc == a64Cmp ? a64Subs : a64Adds)
                        : isNeg ? a64Sub : mc;
            // Normalise to an explicit destination: cmp becomes subs to the
            // zero register, neg becomes sub FROM it.
            Array* o = new Array();
            if (isCmp) {
                RegRef* n0 = parseReg(opAt(ops, (u32)0));
                o.add((Object*)(n0.is64() ? String.withCString("xzr") : String.withCString("wzr")));
                for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            } else if (isNeg) {
                o.add(ops.get((u32)0));
                o.add((Object*)(opAt(ops, (u32)0).hasPrefix(String.withCString("x"))
                                ? String.withCString("xzr") : String.withCString("wzr")));
                for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            } else {
                for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            }
            // Immediate vs register is decided by operand 2, NOT the last one.
            // The shifted spelling `add Rd, Rn, #imm, lsl #12` ends in a shift,
            // so testing the last operand sent it down the REGISTER path, which
            // then tried to parse `#1` as a register ("bad rm #1"). That form is
            // valid AArch64 and emitSpAddr emits it for any frame-slot address
            // at a 4096-aligned offset. A register shift (`add x0, x1, x2,
            // lsl #3`) still has a register at operand 2 and is unaffected.
            bool lastImm = o.count() > (u32)2
                && ((String*)o.get((u32)2)).hasPrefix(String.withCString("#"));
            if (lastImm && !isNeg) { _hit = true; return encAddSubImm(addSubImmBase(key), o); }
            _hit = true;
            return encAddSubReg(addSubRegBase(key), o);
        }
        // `tst Rn, op` IS `ands ZR, Rn, op`. Rewriting it into the alias it
        // stands for reuses the bitmask-immediate encoder below; a second copy
        // of that is the kind that drifts. Normalised into LOCALS rather than
        // by reassigning the parameters — same shape as the cmp/neg rewrite
        // above, and reassigning a borrowed parameter here segfaulted.
        u16 lmc = mc;
        Array* lops = ops;
        if (mc == a64Tst && ops.count() >= 2) {
            bool wide = opAt(ops, (u32)0).hasPrefix(String.withCString("x"))
                     || opAt(ops, (u32)0).hasPrefix(String.withCString("X"));
            Array* a2 = new Array();
            String* zr = String.withCString("wzr");
            if (wide) zr = String.withCString("xzr");
            a2.add((Object*)zr);
            for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) a2.add(ops.get(i));
            lmc = a64Ands;
            lops = a2;
        }
        u32 logBase = logRegBase(lmc);
        if (logBase != (u32)0) {
            if (lops.count() < (u32)3) { fail(String.withCString("logical op needs 3 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(lops, (u32)0));
            RegRef* n = parseReg(opAt(lops, (u32)1));
            if (!d.ok() || !n.ok()) { fail(String.withCString("bad logical register")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            if (opAt(lops, (u32)2).hasPrefix(String.withCString("#"))) {
                U64* v = parseImm(opAt(lops, (u32)2));
                if (!_immOk) { fail(String.withCString("bad logical immediate")); return (u32)0; }
                u32 bm = encodeLogImm(v, d.is64() ? (u32)64 : (u32)32);
                if (bm == (u32)$FFFF_FFFF) { fail(String.withCString("value is not a valid bitmask immediate")); return (u32)0; }
                _hit = true;
                return logImmBase(lmc) | sf | (bm << 10) | (n.num() << 5) | d.num();
            }
            RegRef* m = parseReg(opAt(lops, (u32)2));
            if (!m.ok()) { fail(String.withCString("bad logical register")); return (u32)0; }
            u32 shTy = (u32)0; u32 shAmt = (u32)0;
            if (lops.count() >= (u32)4) {                  // `, <lsl|lsr|asr|ror> #imm`
                String* sw = opAt(lops, (u32)3);
                u32 hash = (u32)$FFFF_FFFF;
                for (u32 i = (u32)0; i < sw.byteLength(); i = i + (u32)1)
                    if (sw.byteAt(i) == (u8)'#') { hash = i; break; }
                if (hash == (u32)$FFFF_FFFF) { fail(String.withCString("bad logical shift")); return (u32)0; }
                String* kind = sw.substringBytes((u32)0, hash).trimmed();
                if (kind.equals(String.withCString("lsl"))) shTy = (u32)0;
                else if (kind.equals(String.withCString("lsr"))) shTy = (u32)1;
                else if (kind.equals(String.withCString("asr"))) shTy = (u32)2;
                else if (kind.equals(String.withCString("ror"))) shTy = (u32)3;
                else { fail(String.withCString("bad logical shift")); return (u32)0; }
                U64* av = parseImm(sw.substringFromByte(hash));
                if (!_immOk) { fail(String.withCString("bad logical shift amount")); return (u32)0; }
                shAmt = av.lo() & (d.is64() ? (u32)63 : (u32)31);
            }
            _hit = true;
            return logBase | sf | (shTy << (u32)22) | (m.num() << (u32)16)
                 | (shAmt << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Mvn) {          // orn Rd, ZR, Rm
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* m = parseReg(opAt(ops, (u32)1));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$2A200000 | sf | (m.num() << (u32)16) | ((u32)31 << (u32)5) | d.num();
        }
        return (u32)0;
    }

    static u32 addSubImmBase(u16 mc)
    {
        if (mc == a64Add)  return $11000000;
        if (mc == a64Sub)  return $51000000;
        if (mc == a64Adds) return $31000000;
        if (mc == a64Subs) return $71000000;
        return (u32)0;
    }

    static u32 addSubRegBase(u16 mc)
    {
        if (mc == a64Add)  return $0B000000;
        if (mc == a64Sub)  return $4B000000;
        if (mc == a64Adds) return $2B000000;
        if (mc == a64Subs) return $6B000000;
        return (u32)0;
    }

    // The N-bit forms — "op with the inverted second operand" — sit at
    // +0x200000 from their plain siblings. clang emits `bic Wd,Wn,Wm,asr #31`
    // for a signed-max idiom, which is how they reach this assembler.
    static u32 logRegBase(u16 mc)
    {
        if (mc == a64And)  return $0A000000;
        if (mc == a64Orr)  return $2A000000;
        if (mc == a64Eor)  return $4A000000;
        if (mc == a64Ands) return $6A000000;
        if (mc == a64Bic)  return $0A200000;
        if (mc == a64Orn)  return $2A200000;
        if (mc == a64Eon)  return $4A200000;
        if (mc == a64Bics) return $6A200000;
        return (u32)0;
    }

    static u32 logImmBase(u16 mc)
    {
        if (mc == a64And)  return $12000000;
        if (mc == a64Orr)  return $32000000;
        if (mc == a64Eor)  return $52000000;
        if (mc == a64Ands) return $72000000;
        return (u32)0;
    }

    // The immediate form takes 12 bits, optionally shifted left by 12 — so a
    // value that is a multiple of 4096 still fits.
    // The `#N` of a `lsl #N` modifier, as a string parseImm can read.
    String* shiftAmountOf(String* mod)
    {
        for (u32 i = (u32)0; i < mod.byteLength(); i = i + (u32)1)
            if (mod.byteAt(i) == (u8)'#') return mod.substringBytes(i, mod.byteLength() - i);
        return String.withCString("");
    }

    u32 encAddSubImm(u32 base, Array* o)
    {
        RegRef* d = parseReg((String*)o.get((u32)0));
        RegRef* n = parseReg((String*)o.get((u32)1));
        if (!d.ok() || !n.ok()) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        // One width bit (sf), taken from Rd: a mixed `add x10, w16, #1` is
        // invalid AArch64 and would silently read the X view of the source
        // (blewit's #8 followup). Reject, as the reference does.
        if (d.is64() != n.is64()) {
            fail(String.withCString("add/sub width mismatch"));
            _hit = false;
            return (u32)0;
        }
        U64* imm = parseImm((String*)o.get((u32)2));
        if (!_immOk) { fail(String.withCString("bad add/sub immediate")); _hit = false; return (u32)0; }
        u32 sh = (u32)0;
        u32 v = imm.lo();
        bool negative = imm.hi() != (u32)0;
        if (o.count() > (u32)3) {
            // EXPLICIT shift: `add Rd, Rn, #imm, lsl #12`. The immediate is then
            // the UNSHIFTED value -- `#1, lsl #12` is 4096, not 1 -- so it is
            // taken as written and the shift bit set, rather than divided down
            // as the bare spelling is below. Reversing that would encode 1 for
            // 4096: silently wrong code rather than a rejection.
            String* mod = (String*)o.get((u32)3);
            if (!mod.hasPrefix(String.withCString("lsl"))) {
                fail(String.withCString("bad add/sub shift"));
                _hit = false;
                return (u32)0;
            }
            U64* amt = parseImm(shiftAmountOf(mod));
            if (!_immOk || amt.hi() != (u32)0
                || (amt.lo() != (u32)0 && amt.lo() != (u32)12)) {
                fail(String.withCString("add/sub shift must be 0 or 12"));
                _hit = false;
                return (u32)0;
            }
            if (amt.lo() == (u32)12) sh = (u32)1;
            if (negative || v > (u32)$FFF) {
                fail(String.withCString("add/sub immediate out of range"));
                _hit = false;
                return (u32)0;
            }
        } else if (negative || v > (u32)$FFF) {
            if (!negative && (v & (u32)$FFF) == (u32)0 && (v >> (u32)12) <= (u32)$FFF) {
                sh = (u32)1; v = v >> (u32)12;
            } else {
                fail(String.withCString("add/sub immediate out of range"));
                _hit = false;
                return (u32)0;
            }
        }
        u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
        return base | sf | (sh << (u32)22) | ((v & (u32)$FFF) << (u32)10)
             | (n.num() << (u32)5) | d.num();
    }

    u32 encAddSubReg(u32 base, Array* o)
    {
        RegRef* d = parseReg((String*)o.get((u32)0));
        RegRef* n = parseReg((String*)o.get((u32)1));
        if (!d.ok() || !n.ok() || o.count() < (u32)3) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        RegRef* m = parseReg((String*)o.get((u32)2));
        if (!m.ok()) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
        if (o.count() >= (u32)4) {
            String* mod = ((String*)o.get((u32)3)).trimmed();
            u32 ws = firstSpace(mod);
            String* kw = ws == (u32)$FFFF_FFFF ? mod : mod.substringBytes((u32)0, ws);
            i32 shk = shiftKind(kw);
            u32 amt = (u32)0;
            u32 h = mod.byteIndexOf(String.withCString("#"));
            if (h != (u32)$FFFF_FFFF) { U64* a = parseImm(mod.substringFromByte(h)); if (_immOk) amt = a.lo(); }
            if (shk >= (i32)0)
                return base | sf | ((u32)shk << (u32)22) | (m.num() << (u32)16)
                     | ((amt & (u32)$3F) << (u32)10) | (n.num() << (u32)5) | d.num();
            i32 opt = extendKind(kw);
            if (opt < (i32)0) { fail(String.withCString("bad extend modifier")); _hit = false; return (u32)0; }
            // The extend name IMPLIES the index width (uxtb/h/w + sxtb/h/w
            // take Wm; uxtx/sxtx take Xm) and no encoding bit distinguishes
            // them, so a mismatched spelling silently encodes an instruction
            // reading the OTHER view of the register (blewit finding #8).
            // Reject, as the reference assembler does.
            if ((opt == (i32)3 || opt == (i32)7) != m.is64()) {
                fail(String.withCString("extend modifier requires the other index width"));
                _hit = false;
                return (u32)0;
            }
            return base | (u32)$00200000 | sf | (m.num() << (u32)16) | ((u32)opt << (u32)13)
                 | ((amt & (u32)7) << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        // SP cannot appear in the shifted-register form, so anything naming it
        // uses the extended form with a zero shift.
        if (d.isSP() || n.isSP()) {
            u32 opt = d.is64() ? (u32)3 : (u32)2;
            return base | (u32)$00200000 | sf | (m.num() << (u32)16) | (opt << (u32)13)
                 | (n.num() << (u32)5) | d.num();
        }
        return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
    }

    static i32 shiftKind(String* m)
    {
        if (m.equals(String.withCString("lsl"))) return (i32)0;
        if (m.equals(String.withCString("lsr"))) return (i32)1;
        if (m.equals(String.withCString("asr"))) return (i32)2;
        return (i32)-1;
    }

    static i32 extendKind(String* m)
    {
        if (m.equals(String.withCString("uxtb"))) return (i32)0;
        if (m.equals(String.withCString("uxth"))) return (i32)1;
        if (m.equals(String.withCString("uxtw"))) return (i32)2;
        if (m.equals(String.withCString("uxtx"))) return (i32)3;
        if (m.equals(String.withCString("sxtb"))) return (i32)4;
        if (m.equals(String.withCString("sxth"))) return (i32)5;
        if (m.equals(String.withCString("sxtw"))) return (i32)6;
        if (m.equals(String.withCString("sxtx"))) return (i32)7;
        return (i32)-1;
    }

    // ── bitfield, shifts, multiply, conditional select ───────────────────
    u32 encBitfieldMul(String* mn, u16 mc, Array* ops, u32 pc)
    {
        u32 w = encBitfieldShift(mn, mc, ops, pc);  if (_hit || _failed) return w;
        w = encMulDiv(mn, mc, ops, pc);             if (_hit || _failed) return w;
        return encCondSelect(mn, mc, ops, pc);
    }

    u32 encBitfieldShift(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64Uxtb || mc == a64Uxth
         || mc == a64Uxtw || mc == a64Sxtb
         || mc == a64Sxth || mc == a64Sxtw) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            bool sign = mn.hasPrefix(String.withCString("s"));
            u32 imms = mn.hasSuffix(String.withCString("b")) ? (u32)7
                     : mn.hasSuffix(String.withCString("h")) ? (u32)15 : (u32)31;
            u32 base = sign ? (d.is64() ? (u32)$93400000 : (u32)$13000000)
                            : (d.is64() ? (u32)$D3400000 : (u32)$53000000);
            _hit = true;
            return base | (imms << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Lsl || mc == a64Lsr
         || mc == a64Asr || mc == a64Ror) {
            if (ops.count() < (u32)3) { fail(String.withCString("shift needs 3 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            if (!opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
                RegRef* m = parseReg(opAt(ops, (u32)2));
                if (!m.ok()) { fail(String.withCString("bad shift register")); return (u32)0; }
                u32 base = mc == a64Lsl ? $1AC02000
                         : mc == a64Lsr ? $1AC02400
                         : mc == a64Asr ? $1AC02800 : $1AC02C00;
                _hit = true;
                return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
            }
            U64* sv = parseImm(opAt(ops, (u32)2));
            if (!_immOk) { fail(String.withCString("bad shift amount")); return (u32)0; }
            u32 sAmt = sv.lo();
            u32 W = d.is64() ? (u32)64 : (u32)32;
            _hit = true;
            if (mc == a64Lsl) {
                u32 immr = (W - sAmt) % W;
                u32 imms = W - (u32)1 - sAmt;
                u32 base = d.is64() ? (u32)$D3400000 : (u32)$53000000;
                return base | (immr << (u32)16) | (imms << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            if (mc == a64Lsr) {
                u32 base = d.is64() ? (u32)$D3400000 : (u32)$53000000;
                return base | (sAmt << (u32)16) | ((W - (u32)1) << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            u32 base = d.is64() ? (u32)$93400000 : (u32)$13000000;
            return base | (sAmt << (u32)16) | ((W - (u32)1) << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    u32 encMulDiv(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64Mul) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            _hit = true;
            return encMul3(d.is64() ? (u32)$9B000000 : (u32)$1B000000, d.num(), n.num(), m.num(), (u32)31);
        }
        if (mc == a64Madd || mc == a64Msub) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            RegRef* a = parseReg(opAt(ops, (u32)3));
            u32 base = mc == a64Msub
                     ? (d.is64() ? (u32)$9B008000 : (u32)$1B008000)
                     : (d.is64() ? (u32)$9B000000 : (u32)$1B000000);
            _hit = true;
            return encMul3(base, d.num(), n.num(), m.num(), a.num());
        }
        if (mc == a64Umull || mc == a64Smull) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            _hit = true;
            return encMul3(mc == a64Umull ? $9BA00000 : $9B200000,
                           d.num(), n.num(), m.num(), (u32)31);
        }
        // The high 64 bits of a 64x64 product (#309: 64-bit division by a
        // constant). Ra is 31.
        if (mc == a64Umulh || mc == a64Smulh) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            _hit = true;
            return encMul3(mc == a64Umulh ? $9BC00000 : $9B400000,
                           d.num(), n.num(), m.num(), (u32)31);
        }
        if (mc == a64Umaddl || mc == a64Smaddl
         || mc == a64Msubl) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            RegRef* a = parseReg(opAt(ops, (u32)3));
            _hit = true;
            return encMul3(mc == a64Smaddl ? $9B200000 : $9BA00000,
                           d.num(), n.num(), m.num(), a.num());
        }
        if (mc == a64Sdiv || mc == a64Udiv) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 base = mc == a64Sdiv ? $1AC00C00 : $1AC00800;
            _hit = true;
            return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    u32 encCondSelect(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64Cset) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)1));
            if (cc < (i32)0) { fail(String.withCString("bad cset condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$1A800400 | sf | ((u32)31 << (u32)16) | (((u32)cc ^ (u32)1) << (u32)12)
                 | ((u32)31 << (u32)5) | d.num();
        }
        if (mc == a64Csetm) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)1));
            if (cc < (i32)0) { fail(String.withCString("bad csetm condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$5A800000 | sf | ((u32)31 << (u32)16) | (((u32)cc ^ (u32)1) << (u32)12)
                 | ((u32)31 << (u32)5) | d.num();
        }
        // ccmp/ccmn Rn, #imm5|Rm, #nzcv, cond — compare when the condition
        // holds, otherwise just plant #nzcv in the flags. clang emits it for a
        // short-circuit comparison, so the self-hosted runtime met it as soon
        // as a host C file with a compound condition was assembled here.
        if (mc == a64Ccmp || mc == a64Ccmn) {
            RegRef* n = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad ccmp condition")); return (u32)0; }
            U64* nz = parseImm(opAt(ops, (u32)2));
            if (!_immOk || nz.hi() != (u32)0 || nz.lo() > (u32)15) {
                fail(String.withCString("bad ccmp nzcv")); return (u32)0;
            }
            u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
            u32 opbit = mc == a64Ccmp ? $40000000 : 0;
            u32 base = (u32)$3A400000 | opbit | sf | ((u32)cc << (u32)12)
                     | (n.num() << (u32)5) | nz.lo();
            _hit = true;
            if (opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
                U64* imm = parseImm(opAt(ops, (u32)1));
                if (!_immOk || imm.hi() != (u32)0 || imm.lo() > (u32)31) {
                    fail(String.withCString("bad ccmp immediate")); _hit = false; return (u32)0;
                }
                return base | (u32)$800 | (imm.lo() << (u32)16);
            }
            RegRef* m = parseReg(opAt(ops, (u32)1));
            return base | (m.num() << (u32)16);
        }
        // The four conditional selects differ only in bit 30 (invert) and bits
        // 11:10 (increment).
        // cinc/cinv/cneg Rd, Rn, cond == csinc/csinv/csneg Rd, Rn, Rn, invert(cond)
        // — the two-operand aliases clang emits (found by the iOS shim, stage 4).
        if (mc == a64Cinc || mc == a64Cinv
         || mc == a64Cneg) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            i32 cc = condCode(opAt(ops, (u32)2));
            if (cc < (i32)0) { fail(String.withCString("bad cinc condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 inv = (mc == a64Cinv || mc == a64Cneg)
                    ? (u32)$40000000 : (u32)0;
            u32 op2 = (mc == a64Cinc || mc == a64Cneg)
                    ? (u32)$400 : (u32)0;
            _hit = true;
            return (u32)$1A800000 | inv | op2 | sf | (n.num() << (u32)16)
                 | (((u32)cc ^ (u32)1) << (u32)12) | (n.num() << (u32)5) | d.num();
        }
        if (mc == a64Csel || mc == a64Csinc
         || mc == a64Csinv || mc == a64Csneg) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad csel condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 inv = (mc == a64Csinv || mc == a64Csneg)
                    ? (u32)$40000000 : (u32)0;
            u32 op2 = (mc == a64Csinc || mc == a64Csneg)
                    ? (u32)$400 : (u32)0;
            _hit = true;
            return (u32)$1A800000 | inv | op2 | sf | (m.num() << (u32)16)
                 | ((u32)cc << (u32)12) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    static u32 encMul3(u32 base, u32 rd, u32 rn, u32 rm, u32 ra)
    {
        return base | (rm << (u32)16) | (ra << (u32)10) | (rn << (u32)5) | rd;
    }

    // ── Memory ───────────────────────────────────────────────────────────
    //
    // The addressing tail: `[Xn]`, `[Xn, #imm]`, `[Xn, #imm]!` (pre-index) or
    // `[Xn], #imm` (post-index). Mode 0 = offset, 1 = pre, 2 = post.
    u32 _memRn;
    i32 _memImm;
    u32 _memMode;

    bool parseMem(Array* ops, u32 memIdx)
    {
        _memImm = (i32)0; _memMode = (u32)0;
        String* m = opAt(ops, memIdx);
        // `] !` is `]!` (#359): inline asm reaches here re-spaced token by
        // token, so a pre-index operand written `[x1, #8]!` arrives as
        // `[ x1,#8 ] !`.
        if (m.hasSuffix(String.withCString("!"))) {
            String* core = m.substringBytes((u32)0, m.byteLength() - (u32)1).trimmed();
            if (core.hasSuffix(String.withCString("]"))) {
                m = String.withString(core);
                m.appendCString("!");
            }
        }
        if (!m.hasPrefix(String.withCString("["))) { fail(String.withCString("expected [ in memory operand")); return false; }
        if (m.hasSuffix(String.withCString("]")) && memIdx + (u32)1 < ops.count()) {
            String* inner = m.substringBytes((u32)1, m.byteLength() - (u32)2);
            RegRef* b = parseReg(inner);
            if (!b.ok()) { fail(String.withCString("bad memory base")); return false; }
            U64* v = parseImm(opAt(ops, memIdx + (u32)1));
            if (!_immOk) { fail(String.withCString("bad post-index immediate")); return false; }
            _memRn = b.num(); _memImm = (i32)v.lo(); _memMode = (u32)2;
            return true;
        }
        bool pre = false;
        String* body = m;
        if (body.hasSuffix(String.withCString("]!"))) {
            pre = true;
            body = body.substringBytes((u32)1, body.byteLength() - (u32)3);
        } else if (body.hasSuffix(String.withCString("]"))) {
            body = body.substringBytes((u32)1, body.byteLength() - (u32)2);
        } else {
            fail(String.withCString("unterminated memory operand")); return false;
        }
        Array* parts = splitOperands(body);
        if (parts.count() < (u32)1) { fail(String.withCString("empty memory operand")); return false; }
        RegRef* b = parseReg((String*)parts.get((u32)0));
        if (!b.ok()) { fail(String.withCString("bad memory base")); return false; }
        _memRn = b.num();
        if (parts.count() >= (u32)2) {
            U64* v = parseImm((String*)parts.get((u32)1));
            if (!_immOk) { fail(String.withCString("bad memory offset")); return false; }
            _memImm = (i32)v.lo();
        }
        _memMode = pre ? (u32)1 : (u32)0;
        return true;
    }

    u32 encMemory(String* mn, u16 mc, Array* ops, u32 pc)
    {
        // An FP load/store is told from a GP one by its destination register.
        if ((mc == a64Ldr || mc == a64Str)
            && ops.count() >= (u32)2) {
            FRegRef* t = parseFReg(opAt(ops, (u32)0));
            if (t.ok()) return encFpLoadStore(mn, mc, ops, pc, t);
        }
        u32 uoff = ldstUoff(mc);
        u32 unsc = ldstUnsc(mc);
        i32 scale = ldstScale(mc);
        bool forceUnscaled = isUnscaledOnly(mc);
        if (scale < 0) return encPairOrAddr(mn, mc, ops, pc);

        RegRef* t = parseReg(opAt(ops, (u32)0));
        if (!t.ok()) { fail(String.withCString("bad load/store register")); return (u32)0; }
        bool sizedByReg = mc == a64Ldr || mc == a64Str
                       || mc == a64Ldur || mc == a64Stur;
        u32 sc = (u32)scale;
        if (sizedByReg) {
            u32 sizeBits = t.is64() ? (u32)$C0000000 : (u32)$80000000;
            sc = t.is64() ? (u32)3 : (u32)2;
            uoff = (uoff & (u32)$3FFFFFFF) | sizeBits;
            unsc = (unsc & (u32)$3FFFFFFF) | sizeBits;
        }
        String* mem = opAt(ops, (u32)1);
        String* inner = (mem.hasPrefix(String.withCString("[")) && mem.hasSuffix(String.withCString("]")))
                      ? mem.substringBytes((u32)1, mem.byteLength() - (u32)2) : mem;
        // [Xn, sym@PAGEOFF] — the load half of an adrp pair; imm12 stays zero.
        bool innerIsGot = inner.byteIndexOf(String.withCString("@GOTPAGEOFF")) != (u32)$FFFF_FFFF;
        if (innerIsGot || inner.byteIndexOf(String.withCString("@PAGEOFF")) != (u32)$FFFF_FFFF) {
            Array* sp2 = splitOperands(inner);
            RegRef* bn = sp2.count() >= (u32)2 ? parseReg((String*)sp2.get((u32)0)) : RegRef.no();
            if (bn.ok()) {
                String* sy = (String*)sp2.get((u32)1);
                String* bare = sy.substringBytes((u32)0, sy.byteIndexOf(String.withCString("@")));
                // A GOT slot is always eight bytes, so the writer scales the
                // displacement itself and the access size does not enter.
                addFixup(pc, innerIsGot ? (u32)FIXUP_GOTPAGEOFF12 : (u32)FIXUP_PAGEOFF12,
                         bare, innerIsGot ? (u32)0 : sc);
                _hit = true;
                return uoff | (bn.num() << (u32)5) | t.num();
            }
        }
        // The register-offset form: [Xn, Wm, uxtw #s] / [Xn, Xm, lsl #s].
        Array* mp = splitOperands(inner);
        if (mp.count() >= (u32)2) {
            RegRef* bn = parseReg((String*)mp.get((u32)0));
            RegRef* bm = parseReg((String*)mp.get((u32)1));
            if (bn.ok() && bm.ok()) {
                u32 regBase = (unsc & (u32)$3FFFFFFF)
                            | (sizedByReg ? (t.is64() ? (u32)$C0000000 : (u32)$80000000)
                                          : (unsc & (u32)$C0000000))
                            | (u32)$00200800;
                u32 option = bm.is64() ? (u32)3 : (u32)2;
                u32 S = (u32)0;
                for (u32 k = (u32)2; k < mp.count(); k = k + (u32)1) {
                    String* e = ((String*)mp.get(k)).trimmed();
                    u32 ws = firstSpace(e);
                    String* kw = ws == (u32)$FFFF_FFFF ? e : e.substringBytes((u32)0, ws);
                    i32 o = memExtendKind(kw);
                    if (o >= (i32)0) option = (u32)o;
                    if (e.byteIndexOf(String.withCString("#")) != (u32)$FFFF_FFFF) S = (u32)1;
                }
                // The option IMPLIES the index width (uxtw/sxtw ↔ Wm,
                // lsl/sxtx ↔ Xm) — no separate bit exists, so a mismatched
                // spelling would encode an instruction reading the OTHER
                // view of the register (blewit finding #8). Reject it, as
                // the reference does.
                if ((option == (u32)3 || option == (u32)7) != bm.is64()) {
                    fail(String.withCString("index extend width mismatch"));
                    _hit = false;
                    return (u32)0;
                }
                _hit = true;
                return regBase | (bm.num() << (u32)16) | (option << (u32)13) | (S << (u32)12)
                     | (bn.num() << (u32)5) | t.num();
            }
        }
        if (!parseMem(ops, (u32)1)) return (u32)0;
        _hit = true;
        if (!forceUnscaled && _memMode == (u32)0 && _memImm >= (i32)0
            && ((u32)_memImm % ((u32)1 << sc)) == (u32)0
            && ((u32)_memImm >> sc) <= (u32)$FFF)
            return uoff | (((u32)_memImm >> sc) << (u32)10) | (_memRn << (u32)5) | t.num();
        // The unscaled, pre- and post-index forms carry a signed 9-bit byte
        // offset. Masking a wider one gave a different address in silence
        // (`ldr x0, [x1, #-300]` came out as #-44).
        if (_memImm < (i32)-256 || _memImm > (i32)255) {
            fail(String.withCString("load/store offset out of range (the unscaled and indexed forms reach -256..255)"));
            return (u32)0;
        }
        u32 imm9 = (u32)_memImm & (u32)$1FF;
        u32 idx = _memMode == (u32)1 ? (u32)$C00 : _memMode == (u32)2 ? (u32)$400 : (u32)0;
        return unsc | (imm9 << (u32)12) | idx | (_memRn << (u32)5) | t.num();
    }

    u32 encFpLoadStore(String* mn, u16 mc, Array* ops, u32 pc, FRegRef* t)
    {
        bool isL = mc == a64Ldr;
        u32 fscale = t.sz();
        // b and h (sz 0, 1) carry their size in bits 31:30 as s and d do.
        u32 fbase = t.sz() == (u32)4 ? (isL ? (u32)$3DC00000 : (u32)$3D800000)
                  : t.sz() == (u32)3 ? (isL ? (u32)$FD400000 : (u32)$FD000000)
                  : t.sz() == (u32)2 ? (isL ? (u32)$BD400000 : (u32)$BD000000)
                                     : (t.sz() << (u32)30) | (isL ? (u32)$3D400000 : (u32)$3D000000);
        String* fmem = opAt(ops, (u32)1);
        String* fin = (fmem.hasPrefix(String.withCString("[")) && fmem.hasSuffix(String.withCString("]")))
                    ? fmem.substringBytes((u32)1, fmem.byteLength() - (u32)2) : fmem;
        if (fin.byteIndexOf(String.withCString("@PAGEOFF")) != (u32)$FFFF_FFFF) {
            Array* fp2 = splitOperands(fin);
            RegRef* bn = fp2.count() >= (u32)2 ? parseReg((String*)fp2.get((u32)0)) : RegRef.no();
            if (bn.ok()) {
                String* sy = (String*)fp2.get((u32)1);
                String* bare = sy.substringBytes((u32)0, sy.byteIndexOf(String.withCString("@")));
                addFixup(pc, (u32)FIXUP_PAGEOFF12, bare, fscale);
                _hit = true;
                return fbase | (bn.num() << (u32)5) | t.num();
            }
        }
        // The register-offset form: `str d9, [x10, x17, lsl #3]` /
        // `[x11, w10, sxtw #3]`. The GP path has it; the FP path used to fall
        // straight to parseMem, which rejects a register second operand as a
        // "bad memory offset" (c2xc 09 — a scaled double store `d[i] = x`). The
        // encoding is the FP unscaled base (uoff with bits 25:24 cleared) plus
        // bit 21 and the "10" in bits 11:10, then Rm/option/S like the GP form.
        Array* fmp = splitOperands(fin);
        if (fmp.count() >= (u32)2) {
            RegRef* fbn = parseReg((String*)fmp.get((u32)0));
            RegRef* fbm = parseReg((String*)fmp.get((u32)1));
            if (fbn.ok() && fbm.ok()) {
                u32 fregBase = (fbase & ~(u32)$03000000) | (u32)$00200800;
                u32 foption = fbm.is64() ? (u32)3 : (u32)2;
                u32 fS = (u32)0;
                for (u32 k = (u32)2; k < fmp.count(); k = k + (u32)1) {
                    String* e = ((String*)fmp.get(k)).trimmed();
                    u32 ws = firstSpace(e);
                    String* kw = ws == (u32)$FFFF_FFFF ? e : e.substringBytes((u32)0, ws);
                    i32 o = memExtendKind(kw);
                    if (o >= (i32)0) foption = (u32)o;
                    if (e.byteIndexOf(String.withCString("#")) != (u32)$FFFF_FFFF) fS = (u32)1;
                }
                if ((foption == (u32)3 || foption == (u32)7) != fbm.is64()) {
                    fail(String.withCString("index extend width mismatch"));
                    _hit = false;
                    return (u32)0;
                }
                _hit = true;
                return fregBase | (fbm.num() << (u32)16) | (foption << (u32)13) | (fS << (u32)12)
                     | (fbn.num() << (u32)5) | t.num();
            }
        }
        if (!parseMem(ops, (u32)1)) return (u32)0;
        _hit = true;
        if (_memMode == (u32)0 && _memImm >= (i32)0
            && ((u32)_memImm % ((u32)1 << fscale)) == (u32)0
            && ((u32)_memImm >> fscale) <= (u32)$FFF)
            return fbase | (((u32)_memImm >> fscale) << (u32)10) | (_memRn << (u32)5) | t.num();
        if (_memImm < (i32)-256 || _memImm > (i32)255) {
            fail(String.withCString("load/store offset out of range (the unscaled and indexed forms reach -256..255)"));
            return (u32)0;
        }
        u32 imm9 = (u32)_memImm & (u32)$1FF;
        u32 unscBase = (fbase & (u32)$3FFFFFFF)
                     | (t.sz() == (u32)3 ? (u32)$C0000000 : t.sz() < (u32)2 ? (t.sz() << (u32)30) : (u32)$80000000);
        u32 idx = _memMode == (u32)1 ? (u32)$C00 : _memMode == (u32)2 ? (u32)$400 : (u32)0;
        return (unscBase & ~(u32)$00000C00) | (imm9 << (u32)12) | idx
             | (_memRn << (u32)5) | t.num();
    }

    static i32 memExtendKind(String* m)
    {
        if (m.equals(String.withCString("lsl"))) return (i32)3;
        return extendKind(m);
    }

    static bool isUnscaledOnly(u16 mc)
    {
        return mc == a64Stur || mc == a64Ldur
            || mc == a64Sturb || mc == a64Ldurb
            || mc == a64Sturh || mc == a64Ldurh
            || mc == a64Ldursb || mc == a64Ldursh
            || mc == a64Ldursw;
    }

    static u32 ldstUoff(u16 mc)
    {
        if (mc == a64Str)   return $B9000000;
        if (mc == a64Ldr)   return $B9400000;
        if (mc == a64Strb)  return $39000000;
        if (mc == a64Ldrb)  return $39400000;
        if (mc == a64Strh)  return $79000000;
        if (mc == a64Ldrh)  return $79400000;
        if (mc == a64Ldrsb) return $39C00000;
        if (mc == a64Ldrsh) return $79C00000;
        if (mc == a64Ldrsw) return $B9800000;
        if (mc == a64Stur)   return $B8000000;
        if (mc == a64Ldur)   return $B8400000;
        if (mc == a64Sturb)  return $38000000;
        if (mc == a64Ldurb)  return $38400000;
        if (mc == a64Sturh)  return $78000000;
        if (mc == a64Ldurh)  return $78400000;
        if (mc == a64Ldursb) return $38C00000;
        if (mc == a64Ldursh) return $78C00000;
        if (mc == a64Ldursw) return $B8800000;
        return (u32)0;
    }

    static u32 ldstUnsc(u16 mc)
    {
        if (mc == a64Str)   return $B8000000;
        if (mc == a64Ldr)   return $B8400000;
        if (mc == a64Strb)  return $38000000;
        if (mc == a64Ldrb)  return $38400000;
        if (mc == a64Strh)  return $78000000;
        if (mc == a64Ldrh)  return $78400000;
        if (mc == a64Ldrsb) return $38C00000;
        if (mc == a64Ldrsh) return $78C00000;
        if (mc == a64Ldrsw) return $B8800000;
        return ldstUoff(mc);
    }

    static i32 ldstScale(u16 mc)
    {
        if (mc == a64Str || mc == a64Ldr
         || mc == a64Ldrsw || mc == a64Stur
         || mc == a64Ldur || mc == a64Ldursw) return 2;
        if (mc == a64Strb || mc == a64Ldrb
         || mc == a64Ldrsb || mc == a64Sturb
         || mc == a64Ldurb || mc == a64Ldursb) return 0;
        if (mc == a64Strh || mc == a64Ldrh
         || mc == a64Ldrsh || mc == a64Sturh
         || mc == a64Ldurh || mc == a64Ldursh) return 1;
        return (i32)-1;
    }

    // ── Load/store pair, adrp/adr ────────────────────────────────────────
    // A pair's offset is a signed 7-bit count of access-sized units, so it
    // must be a multiple of the access size and within -64..63 of them.
    // Masking it wrapped `stp x29, x30, [sp, #-528]!` round to a small
    // positive offset.
    bool pairOffsetOk(u32 scale)
    {
        i32 unit = (i32)1 << (i32)scale;
        if ((_memImm & (unit - (i32)1)) != (i32)0) {
            fail(String.withCString("ldp/stp offset is not a multiple of the access size"));
            return false;
        }
        i32 n = _memImm >> (i32)scale;
        if (n < (i32)-64 || n > (i32)63) {
            fail(String.withCString("ldp/stp offset out of range (reaches -64..63 times the access size)"));
            return false;
        }
        return true;
    }

    u32 encPairOrAddr(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64Stp || mc == a64Ldp) {
            bool L = mc == a64Ldp;
            FRegRef* ft = parseFReg(opAt(ops, (u32)0));
            FRegRef* ft2 = parseFReg(opAt(ops, (u32)1));
            if (ft.ok() && ft2.ok()) {
                if (!parseMem(ops, (u32)2)) return (u32)0;
                u32 scale = ft.sz();
                if (!pairOffsetOk(scale)) return (u32)0;
                u32 imm7 = ((u32)(_memImm >> (i32)scale)) & (u32)$7F;
                u32 fb = ft.sz() == (u32)4
                       ? (_memMode == (u32)1 ? (u32)$AD800000 : _memMode == (u32)2 ? (u32)$AC800000 : (u32)$AD000000)
                       : ft.sz() == (u32)3
                       ? (_memMode == (u32)1 ? (u32)$6D800000 : _memMode == (u32)2 ? (u32)$6C800000 : (u32)$6D000000)
                       : (_memMode == (u32)1 ? (u32)$2D800000 : _memMode == (u32)2 ? (u32)$2C800000 : (u32)$2D000000);
                if (L) fb = fb | (u32)$00400000;
                _hit = true;
                return fb | (imm7 << (u32)15) | (ft2.num() << (u32)10)
                     | (_memRn << (u32)5) | ft.num();
            }
            RegRef* t = parseReg(opAt(ops, (u32)0));
            RegRef* t2 = parseReg(opAt(ops, (u32)1));
            if (!t.ok() || !t2.ok()) { fail(String.withCString("bad pair register")); return (u32)0; }
            if (!parseMem(ops, (u32)2)) return (u32)0;
            u32 scale = t.is64() ? (u32)3 : (u32)2;
            if (!pairOffsetOk(scale)) return (u32)0;
            u32 imm7 = ((u32)(_memImm >> (i32)scale)) & (u32)$7F;
            u32 base32 = _memMode == (u32)0 ? (t.is64() ? (u32)$A9000000 : (u32)$29000000)
                       : _memMode == (u32)1 ? (t.is64() ? (u32)$A9800000 : (u32)$29800000)
                                            : (t.is64() ? (u32)$A8800000 : (u32)$28800000);
            if (L) base32 = base32 | (u32)$00400000;
            _hit = true;
            return base32 | (imm7 << (u32)15) | (t2.num() << (u32)10)
                 | (_memRn << (u32)5) | t.num();
        }
        if (mc == a64Adrp || mc == a64Adr) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            String* sym = opAt(ops, (u32)1);
            String* bare = sym;
            u32 at = sym.byteIndexOf(String.withCString("@"));
            if (at != (u32)$FFFF_FFFF) bare = sym.substringBytes((u32)0, at);
            u8 c0 = bare.byteLength() > (u32)0 ? bare.byteAt((u32)0) : (u8)0;
            bool isName = c0 == (u8)'_' || c0 == (u8)'.'
                       || (c0 >= (u8)'A' && c0 <= (u8)'Z') || (c0 >= (u8)'a' && c0 <= (u8)'z');
            if (!isName) { fail(String.withCString("adr needs a symbol")); return (u32)0; }
            // `sym@GOTPAGE` is the page of the symbol's __got SLOT, not of the
            // symbol: the target is an imported DATA symbol with no in-image
            // address to take.
            bool isGot = at != (u32)$FFFF_FFFF
                      && sym.substringFromByte(at).hasPrefix(String.withCString("@GOTPAGE"));
            u32 kind = mc == a64Adrp
                     ? (isGot ? (u32)FIXUP_GOTPAGE21 : (u32)FIXUP_PAGE21)
                     : (isGot ? (u32)FIXUP_GOTPAGEOFF12 : (u32)FIXUP_PAGEOFF12);
            addFixup(pc, kind, bare, (u32)0);
            _hit = true;
            return (mc == a64Adrp ? $90000000 : $10000000) | d.num();
        }
        return (u32)0;
    }

    // ── Branches and system ──────────────────────────────────────────────
    //
    // A conditional branch carries a SIGNED displacement in a narrow field —
    // 19 bits for b.cond/cbz/cbnz, 14 for tbz/tbnz. Masking an out-of-range
    // one into the field yields a valid-looking instruction that jumps
    // somewhere else entirely, and the program dies far away with the PC in
    // the middle of nothing. So each is CHECKED. The check is not theoretical:
    // it fired on a self-hosted link of a program with Foundation plus the
    // self-hosted preprocessor, whose crash was a truncated branch.
    u32 encBranches(String* mn, u16 mc, Array* ops, u32 pc)
    {
        if (mc == a64B || mc == a64Bl) {
            String* tgt = opAt(ops, (u32)0);
            u32 addr = resolveTarget(tgt);
            u32 base = mc == a64Bl ? $94000000 : $14000000;
            _hit = true;
            if (_lastWasLocal) {
                i32 rel = ((i32)addr - (i32)pc) >> (i32)2;
                if (rel < (i32)-33554432 || rel >= (i32)33554432) {
                    fail(String.withCString("b/bl out of range (reaches +/-128MB)"));
                    return (u32)0;
                }
                return base | ((u32)rel & (u32)$03FFFFFF);
            }
            addFixup(pc, (u32)FIXUP_BRANCH26, tgt, (u32)0);
            return base;
        }
        if (mn.hasPrefix(String.withCString("b."))) {
            i32 cc = condCode(mn.substringFromByte((u32)2));
            if (cc < (i32)0) { fail(String.withCString("bad branch condition")); return (u32)0; }
            u32 addr = resolveTarget(opAt(ops, (u32)0));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-262144 || rel >= (i32)262144) {
                fail(String.withCString("conditional branch out of range (b.cond reaches +/-1MB)"));
                return (u32)0;
            }
            _hit = true;
            return (u32)$54000000 | (((u32)rel & (u32)$7FFFF) << (u32)5) | (u32)cc;
        }
        if (mc == a64Cbz || mc == a64Cbnz) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            u32 addr = resolveTarget(opAt(ops, (u32)1));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-262144 || rel >= (i32)262144) {
                fail(String.withCString("cbz/cbnz out of range (reaches +/-1MB)"));
                return (u32)0;
            }
            u32 base = mc == a64Cbnz ? $35000000 : $34000000;
            if (d.is64()) base = base | (u32)$80000000;
            _hit = true;
            return base | (((u32)rel & (u32)$7FFFF) << (u32)5) | d.num();
        }
        if (mc == a64Tbz || mc == a64Tbnz) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            U64* bit = parseImm(opAt(ops, (u32)1));
            if (!_immOk) { fail(String.withCString("bad test-bit index")); return (u32)0; }
            u32 addr = resolveTarget(opAt(ops, (u32)2));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-8192 || rel >= (i32)8192) {
                fail(String.withCString("tbz/tbnz out of range (reaches +/-32KB)"));
                return (u32)0;
            }
            u32 op = mc == a64Tbnz ? 1 : 0;
            _hit = true;
            return (u32)$36000000 | (((bit.lo() >> (u32)5) & (u32)1) << (u32)31) | (op << (u32)24)
                 | ((bit.lo() & (u32)$1F) << (u32)19) | (((u32)rel & (u32)$3FFF) << (u32)5) | d.num();
        }
        if (mc == a64Ret) {
            u32 r = (u32)30;
            if (ops.count() > (u32)0) { RegRef* x = parseReg(opAt(ops, (u32)0)); if (x.ok()) r = x.num(); }
            _hit = true;
            return (u32)$D65F0000 | (r << (u32)5);
        }
        if ((mc == a64Svc || mc == a64Brk
          || mc == a64Hlt) && ops.count() == 1) {
            U64* imm = parseImm(opAt(ops, (u32)0));
            u32 base = mc == a64Svc ? $D4000001
                     : mc == a64Brk ? $D4200000 : $D4400000;
            _hit = true;
            return base | ((imm.lo() & (u32)$FFFF) << (u32)5);
        }
        if (mc == a64Blr || mc == a64Br) {
            RegRef* n = parseReg(opAt(ops, (u32)0));
            _hit = true;
            return (mc == a64Blr ? $D63F0000 : $D61F0000)
                 | (n.num() << (u32)5);
        }
        if (mc == a64Nop) { _hit = true; return $D503201F; }
        return (u32)0;
    }

    // ── Data directives ──────────────────────────────────────────────────
    //
    // Numeric operands only. A symbol-valued `.quad` is handled separately,
    // because it needs a rebased pointer and a fixup rather than eight bytes
    // of a guess.
    bool _wasDirective;

    bool emitDataDirective(String* l, SectionBytes* into)
    {
        _wasDirective = false;
        u32 sp = firstSpace(l);
        String* mn = sp == (u32)$FFFF_FFFF ? l : l.substringBytes((u32)0, sp);
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                             : l.substringFromByte(sp).trimmed();
        u32 width = (u32)0;
        if (mn.equals(String.withCString(".byte"))) width = (u32)1;
        else if (mn.equals(String.withCString(".hword")) || mn.equals(String.withCString(".short"))
              || mn.equals(String.withCString(".2byte"))) width = (u32)2;
        else if (mn.equals(String.withCString(".word")) || mn.equals(String.withCString(".long"))
              || mn.equals(String.withCString(".4byte"))) width = (u32)4;
        else if (mn.equals(String.withCString(".quad")) || mn.equals(String.withCString(".8byte"))
              || mn.equals(String.withCString(".xword")))
            width = (u32)8;
        else if (mn.equals(String.withCString(".ascii")) || mn.equals(String.withCString(".asciz"))
              || mn.equals(String.withCString(".string"))) {
            Data* bytes = GasString.decode(rest, !mn.equals(String.withCString(".ascii")));
            if (bytes == (Data*)0) { fail(String.withCString("bad string directive")); return true; }
            into.appendData(bytes);
            _wasDirective = true;
            return true;
        }
        else if (mn.equals(String.withCString(".space")) || mn.equals(String.withCString(".zero"))) {
            Array* a = splitOperands(rest);
            U64* n = parseImm((String*)a.get((u32)0));
            u32 fill = (u32)0;
            if (a.count() > (u32)1) { U64* f = parseImm((String*)a.get((u32)1)); if (_immOk) fill = f.lo(); }
            if ((fill & (u32)$FF) == (u32)0)
                into.appendZeros(n.lo());
            else
                for (u32 i = (u32)0; i < n.lo(); i = i + (u32)1)
                    into.appendByte((u8)(fill & (u32)$FF));
            _wasDirective = true;
            return true;
        }
        else return false;

        Array* toks = splitOperands(rest);
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1) {
            U64* v = parseImm((String*)toks.get(i));
            if (!_immOk) { fail(String.withCString("bad data value")); return true; }
            for (u32 b = (u32)0; b < width; b = b + (u32)1)
                into.appendByte((u8)v.byteAt(b));
        }
        _wasDirective = true;
        return true;
    }

    // `.quad <symbol>` — a symbol-valued pointer (a vtable slot, say), which
    // becomes eight rebased bytes and a fixup rather than a number.
    static String* quadSymbolOperand(String* l)
    {
        u32 sp = firstSpace(l);
        if (sp == (u32)$FFFF_FFFF) return (String*)0;
        String* mn = l.substringBytes((u32)0, sp);
        if (!mn.equals(String.withCString(".quad")) && !mn.equals(String.withCString(".8byte"))
         && !mn.equals(String.withCString(".xword")))
            return (String*)0;
        String* rest = l.substringFromByte(sp).trimmed();
        if (rest.byteIndexOf(String.withCString(",")) != (u32)$FFFF_FFFF) return (String*)0;
        u8 c = rest.byteLength() > (u32)0 ? rest.byteAt((u32)0) : (u8)0;
        if (c >= (u8)'0' && c <= (u8)'9') return (String*)0;
        if (c == (u8)'-' || c == (u8)'#') return (String*)0;
        bool isName = c == (u8)'_' || c == (u8)'.'
                   || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z');
        return isName ? rest : (String*)0;
    }

    // ── The two passes ───────────────────────────────────────────────────
    //
    // Section 0 is __text and section 1 is __DATA,__data; each has its OWN
    // address space, and the linker assigns the final bases. Pass 1 places the
    // labels and lays down the data; pass 2 encodes the text, by which point
    // every local label's address is known.
    void assemble(String* asmText)
    {
        Array* lines = asmText.splitOnByte((u8)'\n');
        Array* insns = new Array();
        u32 textAddr = (u32)0;
        u32 dataAddr = (u32)0;
        u32 section = (u32)0;
        bool inModInit = false;      // bug 066: inside __DATA,__mod_init_func
        DwarfWriter* dwarf = (DwarfWriter*)0;  // -g: the line table, if the text has one
        u32 pendingFrame = (u32)16;  // -g: the call frame's distance above x29 (.xc_frame)
        Array* lsdaRaw = new Array();    // each function's .xc_lsda lines
        Array* lsdaCur = (Array*)0;

        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
            String* l = stripComment((String*)lines.get(li)).trimmed();
            if (l.byteLength() == (u32)0) continue;
            // A line starting with '.' is a DIRECTIVE unless it ends with ':',
            // in which case it is a local label like `.Lmain_retain_done_0:`
            // and must be recorded, not skipped as something unrecognised.
            if (l.hasPrefix(String.withCString(".")) && !l.hasSuffix(String.withCString(":"))) {
                if (l.hasPrefix(String.withCString(".text"))) { section = (u32)0; inModInit = false; continue; }
                if (l.hasPrefix(String.withCString(".section"))) {
                    section = l.byteIndexOf(String.withCString("__text")) != (u32)$FFFF_FFFF ? (u32)0 : (u32)1;
                    // Bug 066: __mod_init_func's pointers are ordinary __DATA
                    // bytes; what makes dyld CALL them is the section type, and
                    // folding them anonymously into __data is exactly why
                    // load-time constructors never ran.
                    //
                    // Bug 124: match WITHOUT the leading underscores, and accept
                    // the ELF spelling. The android path strips one `_` after a
                    // comma from the whole unit, so this directive arrives as
                    // `.section _DATA,_mod_init_func,...` and a `__mod_init_func`
                    // needle misses — putting android back in exactly the state
                    // bug 066 fixed for Mach-O. The leading dot on `.init_array`
                    // keeps `.preinit_array` from matching.
                    inModInit = section == (u32)1
                        && (l.byteIndexOf(String.withCString("mod_init_func")) != (u32)$FFFF_FFFF
                         || l.byteIndexOf(String.withCString(".init_array")) != (u32)$FFFF_FFFF);
                    continue;
                }
                if (l.hasPrefix(String.withCString(".data"))) { section = (u32)1; inModInit = false; continue; }
                // ELF spelling. Zero bytes laid here are still the LAST thing
                // in the image's data, and the writers drop a trailing zero run
                // from the file, so .bss costs nothing on disk.
                if (l.hasPrefix(String.withCString(".bss"))) { section = (u32)1; continue; }
                if (l.hasPrefix(String.withCString(".align")) || l.hasPrefix(String.withCString(".p2align"))) {
                    u32 skip = l.hasPrefix(String.withCString(".p2align")) ? (u32)8 : (u32)6;
                    // `.p2align 2, 0x0` — clang's ELF output carries a FILL
                    // operand its Mach-O output does not, and the whole
                    // "2, 0x0" does not parse as an immediate: the alignment
                    // was silently dropped, leaving `_xt_threads_active` three
                    // bytes off and its 4-byte `ldr` page offset unencodable.
                    String* aTxt = l.substringFromByte(skip).trimmed();
                    u32 comma = aTxt.byteIndexOf(String.withCString(","));
                    if (comma != (u32)$FFFF_FFFF) aTxt = aTxt.substringBytes((u32)0, comma);
                    U64* a = parseImm(aTxt.trimmed());
                    u32 al = (u32)1 << a.lo();
                    // In text the padding is NOPS, emitted as instructions: moving
                    // the address without emitting anything would put every
                    // later label out of step with the bytes.
                    if (section == (u32)0) {
                        while (textAddr % al != (u32)0) {
                            insns.add((Object*)String.withCString("nop"));
                            textAddr = textAddr + (u32)4;
                        }
                    }
                    else {
                        noteDataAlign(al);
                        while (dataAddr % al != (u32)0) {
                            _dataBytes.appendByte((u8)0);
                            dataAddr = dataAddr + (u32)1;
                        }
                    }
                    continue;
                }
                if (l.hasPrefix(String.withCString(".comm")) || l.hasPrefix(String.withCString(".zerofill"))
                 || l.hasPrefix(String.withCString(".lcomm"))) {
                    // A zero-initialised global, allocated in __data. `.comm`
                    // and `.lcomm` name it first; `.zerofill` puts the segment
                    // and section in front, so the name is operand 2.
                    u32 sp0 = firstSpace(l);
                    if (sp0 == (u32)$FFFF_FFFF) continue;
                    Array* a = splitOperands(l.substringFromByte(sp0).trimmed());
                    u32 ni = l.hasPrefix(String.withCString(".zerofill")) ? (u32)2 : (u32)0;
                    if (a.count() > ni + (u32)1) {
                        String* nm = ((String*)a.get(ni)).trimmed();
                        U64* sz = parseImm((String*)a.get(ni + (u32)1));
                        u32 alg = (u32)0;
                        if (a.count() > ni + (u32)2) { U64* g = parseImm((String*)a.get(ni + (u32)2)); if (_immOk) alg = g.lo(); }
                        // `.comm` is a COMMON (external tentative def): NO storage
                        // in this object, so the linker gives it one shared slot
                        // and every unit binds to it (bug 169). `.lcomm` /
                        // `.zerofill` stay a private LOCAL zero-init in __data.
                        if (l.hasPrefix(String.withCString(".comm"))) {
                            Array* info = new Array();
                            info.add((Object*)Number.withU32(sz.lo()));
                            info.add((Object*)Number.withU32(alg));
                            _commonSyms.set((Hashable*)nm, (Object*)info);
                        } else {
                            u32 al = (u32)1 << alg;
                            noteDataAlign(al);
                            while (dataAddr % al != (u32)0) {
                                _dataBytes.appendByte((u8)0);
                                dataAddr = dataAddr + (u32)1;
                            }
                            _symbols.set((Hashable*)nm, (Object*)Number.withU32(dataAddr));
                            _dataSyms.add((Object*)nm);
                            _dataBytes.appendZeros(sz.lo());
                            dataAddr = dataAddr + sz.lo();
                        }
                    }
                    continue;
                }
                // -g: `.file <n> "<path>"` and `.loc <n> <line> [<col>]` are the
                // line table, recorded against the text offset they precede.
                // -g: `.xc_frame <n>` — the next frame setup leaves the call
                // frame n bytes above the frame pointer, x29/x30 at its bottom.
                // `.xc_saves <reg>:<cfa offset> ...` (C/C++ input) — where the
                // frame just set up keeps x29, x30 and each callee-saved
                // register, for the unwind tables.
                // `.xc_lsda_begin/_cs/_actions/_type/_end` (C/C++ input): a
                // function's exception tables, built once its labels are placed.
                if (l.hasPrefix(String.withCString(".xc_lsda_"))) {
                    if (l.hasPrefix(String.withCString(".xc_lsda_begin"))) lsdaCur = new Array();
                    if (lsdaCur != (Array*)0) lsdaCur.add((Object*)l);
                    if (l.hasPrefix(String.withCString(".xc_lsda_end")) && lsdaCur != (Array*)0) {
                        lsdaRaw.add((Object*)lsdaCur);
                        lsdaCur = (Array*)0;
                    }
                    continue;
                }
                if (l.hasPrefix(String.withCString(".xc_saves"))) {
                    if (dwarf != (DwarfWriter*)0) dwarf.addSaves(l.substringFromByte((u32)9).trimmed());
                    continue;
                }
                if (l.hasPrefix(String.withCString(".xc_frame"))) {
                    DwarfScan* fsc = DwarfScan.over(l, (u32)9);
                    if (fsc.scanInt()) pendingFrame = (u32)fsc.value();
                    continue;
                }
                // -g: `.xc_var "<name>" <reg> <offset> "<type>"` (`.xc_param`
                // for a parameter) — a variable of the function being assembled.
                if (l.hasPrefix(String.withCString(".xc_var")) || l.hasPrefix(String.withCString(".xc_param"))) {
                    dwarf = DwarfWriter.variableDirective(dwarf, l, l.hasPrefix(String.withCString(".xc_param")),
                                                          textAddr);
                    continue;
                }
                if (l.hasPrefix(String.withCString(".file")) || l.hasPrefix(String.withCString(".loc"))) {
                    bool isFile = l.hasPrefix(String.withCString(".file"));
                    dwarf = DwarfWriter.directive(dwarf, l, isFile ? (u32)5 : (u32)4, isFile,
                                                  section == (u32)0, textAddr);
                    continue;
                }
                if (l.hasPrefix(String.withCString(".globl"))) {
                    // Visibility: the object writer exports exactly these; every
                    // other defined symbol is local to its object (bug 136).
                    String* nm = l.substringFromByte((u32)6).trimmed();
                    if (nm.byteLength() > (u32)0) _globals.add((Object*)nm);
                    continue;
                }
                if (section == (u32)1) {
                    String* qsym = quadSymbolOperand(l);
                    if (qsym != (String*)0) {
                        // Bug 066: a constructor pointer goes to its own buffer,
                        // its fixup offset relative to that buffer; the linker
                        // places both once it knows where the array lands.
                        SectionBytes* dst = inModInit ? _modInitBytes : _dataBytes;
                        u32 at = inModInit ? dst.length() : dataAddr;
                        Arm64Fixup* f = Arm64Fixup.make(at, (u32)FIXUP_POINTER64, qsym, (u32)0);
                        if (inModInit) { _modInitFixups.add((Object*)f); }
                        else           { _fixups.add((Object*)f); }
                        dst.appendZeros((u32)8);
                        if (!inModInit) dataAddr = dataAddr + (u32)8;
                        continue;
                    }
                    u32 before = _dataBytes.length();
                    if (emitDataDirective(l, _dataBytes)) {
                        if (_failed) return;
                        dataAddr = dataAddr + (_dataBytes.length() - before);
                        continue;
                    }
                }
                continue;                       // .subsections_via_symbols and friends
            }
            if (l.hasSuffix(String.withCString(":"))) {
                String* lbl = l.substringBytes((u32)0, l.byteLength() - (u32)1);
                // Defined TWICE in one unit is an error, not last-one-wins: the
                // symbol table is flat, so a second definition silently
                // retargets every branch to the first — and two clang-generated
                // files concatenated together both spell their local labels
                // `.LBB0_1`. `Lloh<N>` is exempt: Darwin numbers those
                // linker-optimization-hint markers per FUNCTION, so rt-macos.s
                // legitimately defines Lloh5 twice, and they are only `.loh`
                // operands — never branch targets.
                if (_symbols.get((Hashable*)lbl) != (Object*)0
                 && !lbl.hasPrefix(String.withCString("Lloh"))) {
                    failFmt(String.withCString("duplicate label"), lbl);
                    return;
                }
                if (section == (u32)0) _symbols.set((Hashable*)lbl, (Object*)Number.withU32(textAddr));
                else {
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(dataAddr));
                    _dataSyms.add((Object*)lbl);
                }
                continue;
            }
            if (section == (u32)0) {
                insns.add((Object*)l);
                textAddr = textAddr + (u32)4;
                // -g: the frame pointer now addresses the saved {x29, x30} pair,
                // so the call frame is x29 + 16 from here.
                if (l.hasPrefix(String.withCString("add x29, sp")) || l.equals(String.withCString("mov x29, sp"))) {
                    if (dwarf == (DwarfWriter*)0) dwarf = new DwarfWriter();
                    dwarf.addFrameSetup(textAddr, pendingFrame);
                    pendingFrame = (u32)16;
                }
            }
            else {
                u32 before = _dataBytes.length();
                if (emitDataDirective(l, _dataBytes)) {
                    if (_failed) return;
                    dataAddr = dataAddr + (_dataBytes.length() - before);
                }
            }
        }

        // -g: hand the line table to whichever writer places this text.
        // …and the unwind tables' frame records (C/C++ input), with or without.
        if (dwarf != (DwarfWriter*)0 && (dwarf.hasRows() || dwarf.hasSaves())) DwarfWriter.setPending(dwarf);

        // The source lines are all consumed: pass 2 reads `insns`.
        lines = (Array*)0;
        // The functions' exception tables, now every text label has its place.
        Arm64Asm.setLsdas(Arm64Asm.buildLsdas(lsdaRaw, _symbols));

        // Pass 2. Only TEXT symbols resolve as local: a data symbol reaches
        // code through an adrp/add pair, never a relative branch.
        _resolveSyms = _symbols;
        // As a set (#335): every branch asked whether its target was data,
        // and a scan of the data symbols made that O(branches x data).
        _resolveDataSyms = new Map();
        for (u32 i = (u32)0; i < _dataSyms.count(); i = i + (u32)1)
            _resolveDataSyms.set((Hashable*)_dataSyms.get(i), (Object*)_dataSyms.get(i));
        u32 pc = (u32)0;
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1) {
            String* insn = (String*)insns.get(i);
            u32 w = encodeLine(insn, pc);
            if (_failed) {
                String* m = String.withCString("line '");
                m.append(insn);
                m.appendCString("': ");
                m.append(_why);
                _why = m;
                return;
            }
            _textBytes.appendLE(w, (u32)4);
            // Each line is read once; letting it go now keeps pass 2 from
            // holding every instruction's text until the image is done.
            insns.set(i, (Object*)0);
            pc = pc + (u32)4;
        }
    }
}
