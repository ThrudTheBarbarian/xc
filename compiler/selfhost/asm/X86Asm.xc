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
#import <NumLit>
#import <SortStable>
#import <DwarfWriter>
#import <SectionBytes>
#import <GasString>

#import "X86AsmDefs.xc"
// The four below are never produced by THIS assembler. They exist because the
// linker also consumes objects it did not produce — musl's, built by clang —
// and those carry relocation kinds our own code generator has no reason to
// emit (task #47, private:docs/Design/foreign-object-linking.md). Kept here rather
// than in the merge so that one enumeration covers every fixup the writer can
// be handed, whatever produced it.
                          // builds a position-independent jump table
                          // opcode two bytes back is mov (0x8b) it becomes
                          // lea and no slot is needed at all
                          // is read as data — it needs a real GOT entry
                          // %fs-relative offset, so there is no symbol to
                          // resolve

// The size an opmask register (k0-k7) parses to: no real operand is this wide,
// so it cannot be mistaken for a GPR or a vector register.

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

// Mnemonics as numbers. encodeInsn looks the mnemonic up once, and the
// encoders and their tables compare the number instead of the String, each
// comparison of which built and freed a String. encVex128 looks up the
// mnemonic without its `v` the same way. Every mnemonic an encoder tests is
// here; anything else is x86Unknown and still reaches the "unhandled
// mnemonic" error. The numbering is private to the process.
enum X86Mnemonic = {
    x86Unknown = 0,
    x86Adc, x86Add, x86Addpd, x86Addps, x86Addsd, x86Addss,
    x86And, x86Andnpd, x86Andnps, x86Andpd, x86Andps, x86Bt,
    x86Btc, x86Btr, x86Bts, x86Call, x86Cdq, x86Cdqe,
    x86Cmp, x86Cmppd, x86Cmpps, x86Cmpxchg, x86Comisd, x86Comiss,
    x86Cpuid, x86Cqo, x86Cvtdq2pd, x86Cvtdq2ps, x86Cvtpd2ps, x86Cvtps2pd,
    x86Cvtsd2si, x86Cvtsd2ss, x86Cvtsi2sd, x86Cvtsi2ss, x86Cvtss2sd, x86Cvtss2si,
    x86Cvttpd2dq, x86Cvttps2dq, x86Cvttsd2si, x86Cvttss2si, x86Cwd, x86Dec,
    x86Div, x86Divpd, x86Divps, x86Divsd, x86Divss, x86Fmadd213pd,
    x86Fmadd213ps, x86Fmadd213sd, x86Fmadd213ss, x86Fmadd231pd, x86Fmadd231ps, x86Fmadd231sd,
    x86Fmadd231ss, x86Fmsub213pd, x86Fmsub213ps, x86Fmsub213sd, x86Fmsub213ss, x86Fmsub231pd,
    x86Fmsub231ps, x86Fmsub231sd, x86Fmsub231ss, x86Fnmadd213pd, x86Fnmadd213ps, x86Fnmadd213sd,
    x86Fnmadd213ss, x86Fnmadd231pd, x86Fnmadd231ps, x86Fnmadd231sd, x86Fnmadd231ss, x86Hlt,
    x86Idiv, x86Imul, x86Inc, x86Jmp, x86Lea, x86Leave,
    x86Lfence, x86Lock, x86Maxpd, x86Maxps, x86Maxsd, x86Maxss,
    x86Mfence, x86Minpd, x86Minps, x86Minsd, x86Minss, x86Mov,
    x86Movabs, x86Movapd, x86Movaps, x86Movd, x86Movdqa, x86Movdqu,
    x86Movq, x86Movsd, x86Movss, x86Movsx, x86Movsxd, x86Movupd,
    x86Movups, x86Movzx, x86Mul, x86Mulpd, x86Mulps, x86Mulsd,
    x86Mulss, x86Neg, x86Nop, x86Not, x86Or, x86Orpd,
    x86Orps, x86Pabsb, x86Pabsd, x86Pabsw, x86Paddb, x86Paddd,
    x86Paddq, x86Paddw, x86Pand, x86Pandn, x86Pause, x86Pcmpeqb,
    x86Pcmpeqd, x86Pcmpeqw, x86Pcmpgtb, x86Pcmpgtd, x86Pcmpgtw, x86Phaddd,
    x86Phaddw, x86Pmaddubsw, x86Pmaddwd, x86Pmaxsb, x86Pmaxsd, x86Pmaxsw,
    x86Pmaxub, x86Pmaxud, x86Pmaxuw, x86Pminsb, x86Pminsd, x86Pminsw,
    x86Pminub, x86Pminud, x86Pminuw, x86Pmulld, x86Pmullw, x86Pmuludq,
    x86Pop, x86Por, x86Pshufd, x86Pshufhw, x86Pshuflw, x86Pslld,
    x86Psllq, x86Psllw, x86Psrad, x86Psraw, x86Psrld, x86Psrlq,
    x86Psrlw, x86Psubd, x86Psubw, x86Punpcklbw, x86Punpckldq, x86Punpcklqdq,
    x86Push, x86Pxor, x86Rdtsc, x86Ret, x86Rex64, x86Rol,
    x86Ror, x86Sal, x86Sar, x86Sbb, x86Sfence, x86Shl,
    x86Shr, x86Shufpd, x86Shufps, x86Sqrtpd, x86Sqrtps, x86Sqrtsd,
    x86Sqrtss, x86Sub, x86Subpd, x86Subps, x86Subsd, x86Subss,
    x86Syscall, x86Test, x86Ucomisd, x86Ucomiss, x86Ud2, x86Unpckhpd,
    x86Unpckhps, x86Unpcklpd, x86Unpcklps, x86Vbroadcastsd, x86Vbroadcastss, x86Vcomisd,
    x86Vcomiss, x86Vcvtdq2ps, x86Vcvtph2ps, x86Vcvtps2ph, x86Vcvttps2dq, x86Vcvttsd2si, x86Vcvttss2si, x86Vextractf128,
    x86Vextracti128, x86Vmovaps, x86Vmovd, x86Vmovdqa, x86Vmovdqu, x86Vmovq,
    x86Vmovsd, x86Vmovss, x86Vmovups, x86Vpabsb, x86Vpabsd, x86Vpabsw,
    x86Vpblendd, x86Vpbroadcastb, x86Vpbroadcastd, x86Vpbroadcastq, x86Vpbroadcastw, x86Vpshufd,
    x86Vpslld, x86Vpsllq, x86Vpsllw, x86Vpsrad, x86Vpsraw, x86Vpsrld,
    x86Vpsrlq, x86Vpsrlw, x86Vshufps, x86Vsqrtpd, x86Vsqrtps, x86Vucomisd,
    x86Vucomiss, x86Vzeroupper, x86Xadd, x86Xchg, x86Xgetbv, x86Xor,
    x86Xorpd, x86Xorps
};

class X86Mn
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
        X86Mn.def(x86Adc, "adc"); X86Mn.def(x86Add, "add"); X86Mn.def(x86Addpd, "addpd");
        X86Mn.def(x86Addps, "addps"); X86Mn.def(x86Addsd, "addsd"); X86Mn.def(x86Addss, "addss");
        X86Mn.def(x86And, "and"); X86Mn.def(x86Andnpd, "andnpd"); X86Mn.def(x86Andnps, "andnps");
        X86Mn.def(x86Andpd, "andpd"); X86Mn.def(x86Andps, "andps"); X86Mn.def(x86Bt, "bt");
        X86Mn.def(x86Btc, "btc"); X86Mn.def(x86Btr, "btr"); X86Mn.def(x86Bts, "bts");
        X86Mn.def(x86Call, "call"); X86Mn.def(x86Cdq, "cdq"); X86Mn.def(x86Cdqe, "cdqe");
        X86Mn.def(x86Cmp, "cmp"); X86Mn.def(x86Cmppd, "cmppd"); X86Mn.def(x86Cmpps, "cmpps");
        X86Mn.def(x86Cmpxchg, "cmpxchg"); X86Mn.def(x86Comisd, "comisd"); X86Mn.def(x86Comiss, "comiss");
        X86Mn.def(x86Cpuid, "cpuid"); X86Mn.def(x86Cqo, "cqo"); X86Mn.def(x86Cvtdq2pd, "cvtdq2pd");
        X86Mn.def(x86Cvtdq2ps, "cvtdq2ps"); X86Mn.def(x86Cvtpd2ps, "cvtpd2ps"); X86Mn.def(x86Cvtps2pd, "cvtps2pd");
        X86Mn.def(x86Cvtsd2si, "cvtsd2si"); X86Mn.def(x86Cvtsd2ss, "cvtsd2ss"); X86Mn.def(x86Cvtsi2sd, "cvtsi2sd");
        X86Mn.def(x86Cvtsi2ss, "cvtsi2ss"); X86Mn.def(x86Cvtss2sd, "cvtss2sd"); X86Mn.def(x86Cvtss2si, "cvtss2si");
        X86Mn.def(x86Cvttpd2dq, "cvttpd2dq"); X86Mn.def(x86Cvttps2dq, "cvttps2dq"); X86Mn.def(x86Cvttsd2si, "cvttsd2si");
        X86Mn.def(x86Cvttss2si, "cvttss2si"); X86Mn.def(x86Cwd, "cwd"); X86Mn.def(x86Dec, "dec");
        X86Mn.def(x86Div, "div"); X86Mn.def(x86Divpd, "divpd"); X86Mn.def(x86Divps, "divps");
        X86Mn.def(x86Divsd, "divsd"); X86Mn.def(x86Divss, "divss"); X86Mn.def(x86Fmadd213pd, "fmadd213pd");
        X86Mn.def(x86Fmadd213ps, "fmadd213ps"); X86Mn.def(x86Fmadd213sd, "fmadd213sd"); X86Mn.def(x86Fmadd213ss, "fmadd213ss");
        X86Mn.def(x86Fmadd231pd, "fmadd231pd"); X86Mn.def(x86Fmadd231ps, "fmadd231ps"); X86Mn.def(x86Fmadd231sd, "fmadd231sd");
        X86Mn.def(x86Fmadd231ss, "fmadd231ss"); X86Mn.def(x86Fmsub213pd, "fmsub213pd"); X86Mn.def(x86Fmsub213ps, "fmsub213ps");
        X86Mn.def(x86Fmsub213sd, "fmsub213sd"); X86Mn.def(x86Fmsub213ss, "fmsub213ss"); X86Mn.def(x86Fmsub231pd, "fmsub231pd");
        X86Mn.def(x86Fmsub231ps, "fmsub231ps"); X86Mn.def(x86Fmsub231sd, "fmsub231sd"); X86Mn.def(x86Fmsub231ss, "fmsub231ss");
        X86Mn.def(x86Fnmadd213pd, "fnmadd213pd"); X86Mn.def(x86Fnmadd213ps, "fnmadd213ps"); X86Mn.def(x86Fnmadd213sd, "fnmadd213sd");
        X86Mn.def(x86Fnmadd213ss, "fnmadd213ss"); X86Mn.def(x86Fnmadd231pd, "fnmadd231pd"); X86Mn.def(x86Fnmadd231ps, "fnmadd231ps");
        X86Mn.def(x86Fnmadd231sd, "fnmadd231sd"); X86Mn.def(x86Fnmadd231ss, "fnmadd231ss"); X86Mn.def(x86Hlt, "hlt");
        X86Mn.def(x86Idiv, "idiv"); X86Mn.def(x86Imul, "imul"); X86Mn.def(x86Inc, "inc");
        X86Mn.def(x86Jmp, "jmp"); X86Mn.def(x86Lea, "lea"); X86Mn.def(x86Leave, "leave");
        X86Mn.def(x86Lfence, "lfence"); X86Mn.def(x86Lock, "lock"); X86Mn.def(x86Maxpd, "maxpd");
        X86Mn.def(x86Maxps, "maxps"); X86Mn.def(x86Maxsd, "maxsd"); X86Mn.def(x86Maxss, "maxss");
        X86Mn.def(x86Mfence, "mfence"); X86Mn.def(x86Minpd, "minpd"); X86Mn.def(x86Minps, "minps");
        X86Mn.def(x86Minsd, "minsd"); X86Mn.def(x86Minss, "minss"); X86Mn.def(x86Mov, "mov");
        X86Mn.def(x86Movabs, "movabs"); X86Mn.def(x86Movapd, "movapd"); X86Mn.def(x86Movaps, "movaps");
        X86Mn.def(x86Movd, "movd"); X86Mn.def(x86Movdqa, "movdqa"); X86Mn.def(x86Movdqu, "movdqu");
        X86Mn.def(x86Movq, "movq"); X86Mn.def(x86Movsd, "movsd"); X86Mn.def(x86Movss, "movss");
        X86Mn.def(x86Movsx, "movsx"); X86Mn.def(x86Movsxd, "movsxd"); X86Mn.def(x86Movupd, "movupd");
        X86Mn.def(x86Movups, "movups"); X86Mn.def(x86Movzx, "movzx"); X86Mn.def(x86Mul, "mul");
        X86Mn.def(x86Mulpd, "mulpd"); X86Mn.def(x86Mulps, "mulps"); X86Mn.def(x86Mulsd, "mulsd");
        X86Mn.def(x86Mulss, "mulss"); X86Mn.def(x86Neg, "neg"); X86Mn.def(x86Nop, "nop");
        X86Mn.def(x86Not, "not"); X86Mn.def(x86Or, "or"); X86Mn.def(x86Orpd, "orpd");
        X86Mn.def(x86Orps, "orps"); X86Mn.def(x86Pabsb, "pabsb"); X86Mn.def(x86Pabsd, "pabsd");
        X86Mn.def(x86Pabsw, "pabsw"); X86Mn.def(x86Paddb, "paddb"); X86Mn.def(x86Paddd, "paddd");
        X86Mn.def(x86Paddq, "paddq"); X86Mn.def(x86Paddw, "paddw"); X86Mn.def(x86Pand, "pand");
        X86Mn.def(x86Pandn, "pandn"); X86Mn.def(x86Pause, "pause"); X86Mn.def(x86Pcmpeqb, "pcmpeqb");
        X86Mn.def(x86Pcmpeqd, "pcmpeqd"); X86Mn.def(x86Pcmpeqw, "pcmpeqw"); X86Mn.def(x86Pcmpgtb, "pcmpgtb");
        X86Mn.def(x86Pcmpgtd, "pcmpgtd"); X86Mn.def(x86Pcmpgtw, "pcmpgtw"); X86Mn.def(x86Phaddd, "phaddd");
        X86Mn.def(x86Phaddw, "phaddw"); X86Mn.def(x86Pmaddubsw, "pmaddubsw"); X86Mn.def(x86Pmaddwd, "pmaddwd");
        X86Mn.def(x86Pmaxsb, "pmaxsb"); X86Mn.def(x86Pmaxsd, "pmaxsd"); X86Mn.def(x86Pmaxsw, "pmaxsw");
        X86Mn.def(x86Pmaxub, "pmaxub"); X86Mn.def(x86Pmaxud, "pmaxud"); X86Mn.def(x86Pmaxuw, "pmaxuw");
        X86Mn.def(x86Pminsb, "pminsb"); X86Mn.def(x86Pminsd, "pminsd"); X86Mn.def(x86Pminsw, "pminsw");
        X86Mn.def(x86Pminub, "pminub"); X86Mn.def(x86Pminud, "pminud"); X86Mn.def(x86Pminuw, "pminuw");
        X86Mn.def(x86Pmulld, "pmulld"); X86Mn.def(x86Pmullw, "pmullw"); X86Mn.def(x86Pmuludq, "pmuludq");
        X86Mn.def(x86Pop, "pop"); X86Mn.def(x86Por, "por"); X86Mn.def(x86Pshufd, "pshufd");
        X86Mn.def(x86Pshufhw, "pshufhw"); X86Mn.def(x86Pshuflw, "pshuflw"); X86Mn.def(x86Pslld, "pslld");
        X86Mn.def(x86Psllq, "psllq"); X86Mn.def(x86Psllw, "psllw"); X86Mn.def(x86Psrad, "psrad");
        X86Mn.def(x86Psraw, "psraw"); X86Mn.def(x86Psrld, "psrld"); X86Mn.def(x86Psrlq, "psrlq");
        X86Mn.def(x86Psrlw, "psrlw"); X86Mn.def(x86Psubd, "psubd"); X86Mn.def(x86Psubw, "psubw");
        X86Mn.def(x86Punpcklbw, "punpcklbw"); X86Mn.def(x86Punpckldq, "punpckldq"); X86Mn.def(x86Punpcklqdq, "punpcklqdq");
        X86Mn.def(x86Push, "push"); X86Mn.def(x86Pxor, "pxor"); X86Mn.def(x86Rdtsc, "rdtsc");
        X86Mn.def(x86Ret, "ret"); X86Mn.def(x86Rex64, "rex64"); X86Mn.def(x86Rol, "rol");
        X86Mn.def(x86Ror, "ror"); X86Mn.def(x86Sal, "sal"); X86Mn.def(x86Sar, "sar");
        X86Mn.def(x86Sbb, "sbb"); X86Mn.def(x86Sfence, "sfence"); X86Mn.def(x86Shl, "shl");
        X86Mn.def(x86Shr, "shr"); X86Mn.def(x86Shufpd, "shufpd"); X86Mn.def(x86Shufps, "shufps");
        X86Mn.def(x86Sqrtpd, "sqrtpd"); X86Mn.def(x86Sqrtps, "sqrtps"); X86Mn.def(x86Sqrtsd, "sqrtsd");
        X86Mn.def(x86Sqrtss, "sqrtss"); X86Mn.def(x86Sub, "sub"); X86Mn.def(x86Subpd, "subpd");
        X86Mn.def(x86Subps, "subps"); X86Mn.def(x86Subsd, "subsd"); X86Mn.def(x86Subss, "subss");
        X86Mn.def(x86Syscall, "syscall"); X86Mn.def(x86Test, "test"); X86Mn.def(x86Ucomisd, "ucomisd");
        X86Mn.def(x86Ucomiss, "ucomiss"); X86Mn.def(x86Ud2, "ud2"); X86Mn.def(x86Unpckhpd, "unpckhpd");
        X86Mn.def(x86Unpckhps, "unpckhps"); X86Mn.def(x86Unpcklpd, "unpcklpd"); X86Mn.def(x86Unpcklps, "unpcklps");
        X86Mn.def(x86Vbroadcastsd, "vbroadcastsd"); X86Mn.def(x86Vbroadcastss, "vbroadcastss"); X86Mn.def(x86Vcomisd, "vcomisd");
        X86Mn.def(x86Vcomiss, "vcomiss"); X86Mn.def(x86Vcvtdq2ps, "vcvtdq2ps"); X86Mn.def(x86Vcvttps2dq, "vcvttps2dq");
        X86Mn.def(x86Vcvtph2ps, "vcvtph2ps"); X86Mn.def(x86Vcvtps2ph, "vcvtps2ph");
        X86Mn.def(x86Vcvttsd2si, "vcvttsd2si"); X86Mn.def(x86Vcvttss2si, "vcvttss2si"); X86Mn.def(x86Vextractf128, "vextractf128");
        X86Mn.def(x86Vextracti128, "vextracti128"); X86Mn.def(x86Vmovaps, "vmovaps"); X86Mn.def(x86Vmovd, "vmovd");
        X86Mn.def(x86Vmovdqa, "vmovdqa"); X86Mn.def(x86Vmovdqu, "vmovdqu"); X86Mn.def(x86Vmovq, "vmovq");
        X86Mn.def(x86Vmovsd, "vmovsd"); X86Mn.def(x86Vmovss, "vmovss"); X86Mn.def(x86Vmovups, "vmovups");
        X86Mn.def(x86Vpabsb, "vpabsb"); X86Mn.def(x86Vpabsd, "vpabsd"); X86Mn.def(x86Vpabsw, "vpabsw");
        X86Mn.def(x86Vpblendd, "vpblendd"); X86Mn.def(x86Vpbroadcastb, "vpbroadcastb"); X86Mn.def(x86Vpbroadcastd, "vpbroadcastd");
        X86Mn.def(x86Vpbroadcastq, "vpbroadcastq"); X86Mn.def(x86Vpbroadcastw, "vpbroadcastw"); X86Mn.def(x86Vpshufd, "vpshufd");
        X86Mn.def(x86Vpslld, "vpslld"); X86Mn.def(x86Vpsllq, "vpsllq"); X86Mn.def(x86Vpsllw, "vpsllw");
        X86Mn.def(x86Vpsrad, "vpsrad"); X86Mn.def(x86Vpsraw, "vpsraw"); X86Mn.def(x86Vpsrld, "vpsrld");
        X86Mn.def(x86Vpsrlq, "vpsrlq"); X86Mn.def(x86Vpsrlw, "vpsrlw"); X86Mn.def(x86Vshufps, "vshufps");
        X86Mn.def(x86Vsqrtpd, "vsqrtpd"); X86Mn.def(x86Vsqrtps, "vsqrtps"); X86Mn.def(x86Vucomisd, "vucomisd");
        X86Mn.def(x86Vucomiss, "vucomiss"); X86Mn.def(x86Vzeroupper, "vzeroupper"); X86Mn.def(x86Xadd, "xadd");
        X86Mn.def(x86Xchg, "xchg"); X86Mn.def(x86Xgetbv, "xgetbv"); X86Mn.def(x86Xor, "xor");
        X86Mn.def(x86Xorpd, "xorpd"); X86Mn.def(x86Xorps, "xorps");
        }

    // The number of a mnemonic, or x86Unknown for one no encoder tests.
    static u16 find(String* mnemonic)
        {
        if (_byName == (Map*)0)
            X86Mn.build();
        Number* mc = (Number*)_byName.get((Hashable*)mnemonic);
        if (mc == (Number*)0)
            return x86Unknown;
        return mc.asU16();
        }
    }

    class X86Asm
    {
    SectionBytes* _text;
    SectionBytes* _data;
    Array* _fixups;     // X86Fixup@
    Map* _symbols;      // name -> offset within its own section
    Array* _dataSyms;   // String@
    Array* _globalSyms; // String@
    Map* _commonSyms;   // `.comm` COMMON: name -> [size, byteAlign] (bug 36 x-obj)
    SectionBytes* _bss; // `.bss`, appended after all the data once the pass is done (bug 642)
    u32 _bssAlign;      // the largest alignment a `.bss` .p2align asked for (at least 16)
    Array* _bssLabels;  // the labels defined in it, rebased then
    bool _failed;
    String* _why;
    bool _skipSect; // inside a CodeView .debug$ section — emit nothing
    DwarfWriter* _dwarf; // -g: the line table, if the text has one
    Array* _seh;        // win64 unwind entries, one Array@ per function (sehFunctions)
    Array* _lsdaRaw;    // each function's .xc_lsda lines (C++ handlers)
    Array* _lsdaCur;
    Array* _sehCur;     // the function between .seh_proc and .seh_endproc
    Map* _evex;     // EVEX forms: mnemonic -> packed form/map/pp/W/opcode/N
    Map* _evexX;    // the shifts whose count is an xmm register

    u32 _insnBase;      // offset in .text of the instruction being encoded
    i32 _ripDispOffset; // -1 when this instruction has no rip operand
    String* _ripSymbol;
    i32 _ripAddend;

    void init(void)
        {
        _text = new SectionBytes();
        _data = new SectionBytes();
        _fixups = new Array();
        _symbols = new Map();
        _dataSyms = new Array();
        _globalSyms = new Array();
        _commonSyms = new Map();
        _seh = new Array();
        _lsdaRaw = new Array();
        _bss = new SectionBytes();
        _bssAlign = (u32)16;
        _bssLabels = new Array();
        _failed = false;
        _skipSect = false;
        }

    SectionBytes* text(void)
        {
        return _text;
        }
    SectionBytes* data(void)
        {
        return _data;
        }
    // The exception tables of the last text assembled (C++ handlers): as
    // Arm64Asm's, per function [its label, the LSDA, the type-table entries'
    // (offset, typeinfo)]. The object writer names the type entries' form
    // (ELF 0x9b, PE 0x00); the labels are this text's.
    static Array* _lsdaLines;
    static Map* _lsdaSyms;
    static Array* takeLsdas(u32 ttEnc)
        {
        Array* raw = _lsdaLines;
        _lsdaLines = (Array*)0;
        if (raw == (Array*)0 || raw.count() == (u32)0)
            return (Array*)0;
        return DwarfWriter.buildLsdas(raw, _lsdaSyms, ttEnc);
        }

    // win64 unwind entries (`.seh_proc` … `.seh_endproc`, C/C++ input): per
    // function an Array@ of [name, start, prologue size, end, codes], codes a
    // flat Number@ list of (offset in the function, UWOP_*, register, value).
    Array* sehFunctions(void)
        {
        return _seh;
        }

    static u32 sehRegister(String* r)
        {
        if (r.hasPrefix(String.withCString("xmm")))
            {
            u32 n = (u32)0;
            for (u32 k = (u32)3; k < r.byteLength(); k = k + (u32)1)
                n = n * (u32)10 + (u32)(r.byteAt(k) - (u8)'0');
            return n;
            }
        Array* names = String.withCString("rax rcx rdx rbx rsp rbp rsi rdi").splitOnByte((u8)' ');
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
            if (((String*)names.get(k)).equals(r)) return k;
        u32 n = (u32)0;
        for (u32 k = (u32)1; k < r.byteLength(); k = k + (u32)1)
            n = n * (u32)10 + (u32)(r.byteAt(k) - (u8)'0');
        return n;
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
        SortStable.byString(names);   // n log n (#335); the names are distinct
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
            {
            String* nm = (String*)names.get(k);
            Array* info = (Array*)_commonSyms.get((Hashable*)nm);
            u32 sz = ((Number*)info.get((u32)0)).asU32();
            u32 al = ((Number*)info.get((u32)1)).asU32();
            if (al < (u32)1)
                al = (u32)1;
            _data.padTo(al);
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_data.length()));
            _dataSyms.add((Object*)nm);
            _data.appendZeros(sz);
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
        // ymmN: the same registers at 32 bytes; a ymm operand sets VEX.L.
        if (s.hasPrefix(String.withCString("ymm")))
            {
            i32 v = smallNumber(s, (u32)3);
            if (v < (i32)0 || v > (i32)15)
                return (i32)-1;
            _regSize = (u32)32;
            return v;
            }
        // zmmN: 32 registers at 64 bytes; a zmm operand selects EVEX, whose
        // R', V' and X bits carry bit 4. zmm16-31 exist only there; any other
        // encoding refuses them (encodeOne). As the reference.
        if (s.hasPrefix(String.withCString("zmm")))
            {
            i32 v = smallNumber(s, (u32)3);
            if (v < (i32)0 || v > (i32)31)
                return (i32)-1;
            _regSize = (u32)64;
            return v;
            }
        // k0-k7, the AVX-512 opmask registers, at a size no other operand has.
        if (s.byteLength() == (u32)2 && s.byteAt((u32)0) == (u8)'k')
            {
            i32 v = smallNumber(s, (u32)1);
            if (v < (i32)0 || v > (i32)7)
                return (i32)-1;
            _regSize = (u32)XK_SIZE;
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
        // A sign, `0x` hex or decimal, all of the operand (NumLit, #336); the
        // value 64-bit, its high half in _numHi.
        u64 mag = (u64)0;
        bool neg = false;
        u32 end = (u32)0;
        if (NumLit.scan(s, (u32)0, (u32)0, &mag, &neg, &end) == (u32)0 || end != s.byteLength())
            return (i32)0;
        u64 v = neg ? (u64)0 - mag : mag;
        _numHi = (u32)(v >> (u64)32);
        _numOk = true;
        return (i32)(u32)v;
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
        if (s.hasPrefix(String.withCString("ymmword ptr")))
            return (u32)32;
        if (s.hasPrefix(String.withCString("zmmword ptr")))
            return (u32)64;
        return (u32)0;
        }

    static u32 prefixLength(String* s0)
        {
        String* s = s0.lowercased();
        if (s.hasPrefix(String.withCString("xmmword ptr")))
            return (u32)11;
        if (s.hasPrefix(String.withCString("ymmword ptr")))
            return (u32)11;
        if (s.hasPrefix(String.withCString("zmmword ptr")))
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
    bool _evexUsed;  // set by eEvex: zmm16-31 are legal only then

    Array* encodeOne(String* line)
        {
        _ripDispOffset = (i32)-1;
        _ripSymbol = (String*)0;
        _ripAddend = (i32)0;
        _evexUsed = false;
        Array* bytes = encodeInsn(line);
        // zmm16-31 exist only in the EVEX encoding: any other one would drop
        // bit 4 and name zmm0-15 instead, silently. As the reference.
        if (bytes != (Array*)0 && !_evexUsed && X86Asm.namesHighZmm(line))
            {
            String* m = String.withCString("zmm16-31 need an EVEX encoding: '");
            m.append(line);
            m.appendByte((u8)$27);
            fail(m);
            return (Array*)0;
            }
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
        // The encoders test this number, not the String (#330).
        u16 mc = X86Mn.find(mn);

        // `lock` is a PREFIX, not an instruction: encode what follows it, then
        // put 0xF0 in front — AFTER any 0x66 operand-size prefix, because that
        // is the order clang writes and this assembler is held byte-identical
        // to clang.
        if (mc == x86Lock)
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
        if (mc == x86Rex64)
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

        // A broadcast from a GENERAL register: only EVEX has it, at every
        // width (7A b / 7B w / 7C d, q with W1); the table forms read the
        // register number as an xmm one. As the reference.
        if (_ops.count() == (u32)2 && a.kind() == (u32)OP_REG
            && (a.size() == (u32)16 || a.size() == (u32)32 || a.size() == (u32)64)
            && b.kind() == (u32)OP_REG
            && (b.size() == (u32)1 || b.size() == (u32)2 || b.size() == (u32)4 || b.size() == (u32)8)
            && mn.hasPrefix(String.withCString("vpbroadcast")) && mn.byteLength() == (u32)12)
            {
            u8 e = mn.byteAt((u32)11);
            u32 bop = e == (u8)'b' ? (u32)$7A : e == (u8)'w' ? (u32)$7B : (u32)$7C;
            eEvex((u32)2, (u32)1, e == (u8)'q' ? (u32)1 : (u32)0, a.reg(), (i32)-1, b,
                  a.size() == (u32)64 ? (u32)2 : a.size() == (u32)32 ? (u32)1 : (u32)0);
            e8(bop);
            eModRM(a.reg(), b);
            return _out;
            }
        encGroupA(mn, mc, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupB(mn, mc, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupC(mn, mc, a, b);
        if (_hit || _failed)
            return _failed ? (Array*)0 : _out;
        encGroupD(mn, mc, a, b);
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
    void encGroupA(String* mn, u16 mc, XOperand* a, XOperand* b)
        {
        if (mc == x86Ret)
            {
            e8((u32)$C3);
            _hit = true;
            return;
            }
        if (mc == x86Leave)
            {
            e8((u32)$C9);
            _hit = true;
            return;
            }
        if (mc == x86Nop)
            {
            e8((u32)$90);
            _hit = true;
            return;
            }
        if (mc == x86Cdq)
            {
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mc == x86Cqo)
            {
            e8((u32)$48);
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mc == x86Syscall)
            {
            e8((u32)$0F);
            e8((u32)$05);
            _hit = true;
            return;
            }
        if (mc == x86Hlt)
            {
            e8((u32)$F4);
            _hit = true;
            return;
            }
        if (mc == x86Ud2)
            {
            e8((u32)$0F);
            e8((u32)$0B);
            _hit = true;
            return;
            }
        if (mc == x86Cwd)
            {
            e8((u32)$66);
            e8((u32)$99);
            _hit = true;
            return;
            }
        if (mc == x86Cdqe)
            {
            e8((u32)$48);
            e8((u32)$98);
            _hit = true;
            return;
            }

        // ── atomics, fences and the bit-test group (private:docs/Design/threading.md) ──
        if (mc == x86Mfence)
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$F0);
            _hit = true;
            return;
            }
        if (mc == x86Lfence)
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$E8);
            _hit = true;
            return;
            }
        if (mc == x86Sfence)
            {
            e8((u32)$0F);
            e8((u32)$AE);
            e8((u32)$F8);
            _hit = true;
            return;
            }
        if (mc == x86Pause)
            {
            e8((u32)$F3);
            e8((u32)$90);
            _hit = true;
            return;
            }
        // The CPU-feature reads behind runtime SIMD dispatch (_xt_simd_select).
        // The cycle counter (the runtime's stack-guard seed).
        if (mc == x86Rdtsc)
            {
            e8((u32)$0F);
            e8((u32)$31);
            _hit = true;
            return;
            }
        if (mc == x86Cpuid)
            {
            e8((u32)$0F);
            e8((u32)$A2);
            _hit = true;
            return;
            }
        if (mc == x86Xgetbv)
            {
            e8((u32)$0F);
            e8((u32)$01);
            e8((u32)$D0);
            _hit = true;
            return;
            }
            // bt / bts / btr / btc — r/m is the destination, the register or the
            // immediate selects the bit.
            {
            u32 btOp = (u32)0;
            u32 btExt = (u32)0;
            bool isBt = false;
            if (mc == x86Bt)
                {
                btOp = (u32)$A3;
                btExt = (u32)4;
                isBt = true;
                }
            if (mc == x86Bts)
                {
                btOp = (u32)$AB;
                btExt = (u32)5;
                isBt = true;
                }
            if (mc == x86Btr)
                {
                btOp = (u32)$B3;
                btExt = (u32)6;
                isBt = true;
                }
            if (mc == x86Btc)
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
        if ((mc == x86Xadd || mc == x86Cmpxchg || mc == x86Xchg) && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == OP_REG)
            {
            eRex(_w, (i32)b.reg(), a.index(),
                 a.kind() == (u32)OP_REG ? (i32)a.reg() : a.base(), _force8);
            if (mc == x86Xchg)
                {
                e8(_osz == (u32)1 ? (u32)$86 : (u32)$87);
                }
            else
                {
                e8((u32)$0F);
                u32 op = mc == x86Xadd ? $C1 : $B1;
                e8(_osz == (u32)1 ? op - (u32)1 : op);
                }
            eModRM(b.reg(), a);
            _hit = true;
            return;
            }

        bool isPush = mc == x86Push;
        if ((isPush || mc == x86Pop) && a != (XOperand*)0 && a.kind() == OP_REG)
            {
            if ((a.reg() & (u32)8) != (u32)0)
                e8((u32)$41);
            e8((isPush ? (u32)$50 : (u32)$58) + (a.reg() & (u32)7));
            _hit = true;
            return;
            }

        i32 ext = aluExt(mc);
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

        if (mc == x86Mov && a != (XOperand*)0 && b != (XOperand*)0)
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
                // A memory destination has no movabs form at all, so a value
                // that is not a sign-extended imm32 is refused: masked, it
                // stored `mov qword ptr [rax], 0x100000000` as 0.
                if (_osz == (u32)8 && !fitsImm32(b))
                    {
                    failWith(String.withCString(
                                 "64-bit immediate does not fit an imm32 field — "
                                 "load it into a register first"),
                             mn);
                    return;
                    }
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

        if (mc == x86Lea && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == OP_REG && b.kind() == OP_MEM)
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

    static i32 aluExt(u16 mc)
        {
        if (mc == x86Add)
            return (i32)0;
        if (mc == x86Or)
            return (i32)1;
        if (mc == x86Adc)
            return (i32)2;
        if (mc == x86Sbb)
            return (i32)3;
        if (mc == x86And)
            return (i32)4;
        if (mc == x86Sub)
            return (i32)5;
        if (mc == x86Xor)
            return (i32)6;
        if (mc == x86Cmp)
            return (i32)7;
        return (i32)-1;
        }

    // ── Group B: extends, the unary group, inc/dec, test, setcc, shifts ──
    void encGroupB(String* mn, u16 mc, XOperand* a, XOperand* b)
        {
        if (mc == x86Movsxd && a != (XOperand*)0 && b != (XOperand*)0)
            {
            eRex(true, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$63);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        bool zx = mc == x86Movzx;
        if ((zx || mc == x86Movsx) && a != (XOperand*)0 && b != (XOperand*)0)
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
        i32 un = unaryExt(mc);
        if (un >= (i32)0 && a != (XOperand*)0 && _ops.count() == (u32)1)
            {
            eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
            e8(_osz == (u32)1 ? (u32)$F6 : (u32)$F7);
            eModRM((u32)un, a);
            _hit = true;
            return;
            }
        bool isInc = mc == x86Inc;
        if ((isInc || mc == x86Dec) && a != (XOperand*)0 && _ops.count() == 1)
            {
            eRex(_w, (i32)0, a.index(), a.rmReg(), _force8);
            e8(_osz == (u32)1 ? (u32)$FE : (u32)$FF);
            eModRM(isInc ? (u32)0 : (u32)1, a);
            _hit = true;
            return;
            }
        if (mc == x86Test && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == OP_IMM && b.symbol() == (String*)0)
            {
            // As for the ALU forms: the immediate is a sign-extended imm32,
            // and `test rcx, 0x100000000` became `test rcx, 0`.
            if (_osz == (u32)8 && !fitsImm32(b))
                {
                failWith(String.withCString(
                             "64-bit immediate does not fit an imm32 field — "
                             "load it into a register first"),
                         mn);
                return;
                }
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
        if (mc == x86Test && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() == OP_REG)
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
        i32 sh = shiftExt(mc);
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

    static i32 unaryExt(u16 mc)
        {
        if (mc == x86Not)
            return (i32)2;
        if (mc == x86Neg)
            return (i32)3;
        if (mc == x86Mul)
            return (i32)4;
        if (mc == x86Imul)
            return (i32)5;
        if (mc == x86Div)
            return (i32)6;
        if (mc == x86Idiv)
            return (i32)7;
        return (i32)-1;
        }

    static i32 shiftExt(u16 mc)
        {
        if (mc == x86Rol)
            return (i32)0;
        if (mc == x86Ror)
            return (i32)1;
        if (mc == x86Shl || mc == x86Sal)
            return (i32)4;
        if (mc == x86Shr)
            return (i32)5;
        if (mc == x86Sar)
            return (i32)7;
        return (i32)-1;
        }

    // ── Group C: imul forms, movabs, branches, cmovcc ────────────────────
    void encGroupC(String* mn, u16 mc, XOperand* a, XOperand* b)
        {
        if (mc == x86Imul && a != (XOperand*)0 && b != (XOperand*)0 && _ops.count() == 2 && a.kind() == OP_REG)
            {
            eRex(_w, (i32)a.reg(), b.index(), b.rmReg(), _force8);
            e8((u32)$0F);
            e8((u32)$AF);
            eModRM(a.reg(), b);
            _hit = true;
            return;
            }
        if (mc == x86Imul && _ops.count() == 3 && a != (XOperand*)0 && b != (XOperand*)0)
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
        if (mc == x86Movabs && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == OP_REG)
            {
            eRex(true, (i32)0, (i32)0, (i32)a.reg(), false);
            e8((u32)$B8 + (a.reg() & (u32)7));
            e64((u32)b.imm(), b.immHi());
            _hit = true;
            return;
            }
        bool isCall = mc == x86Call;
        if ((isCall || mc == x86Jmp) && a != (XOperand*)0)
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
    // ── VEX.128 three-operand forms of the SSE table ──
    //
    // `vaddps xmm0, xmm1, xmm2` is `addps` with a VEX prefix and a
    // NON-DESTRUCTIVE first source, so the same opcode serves both and sseRR
    // stays the only place a mnemonic is listed. A second table would be a
    // copy to drift.
    //
    //   2-byte  C5 [R vvvv L pp]                 when X=B=0 and the map is 0F
    //   3-byte  C4 [RXB mmmmm] [W vvvv L pp]     otherwise
    //
    // VEX.128 only — the 256-bit half needs a register pool and vzeroupper
    // discipline, which is not encoding work. private:docs/bugs/231.
    bool encVex128(String* mn, XOperand* a)
        {
        if (mn.byteLength() < (u32)2 || mn.byteAt((u32)0) != (u8)'v')
            return false;
        if (a == (XOperand*)0)
            return false;
        String* base = mn.substringFromByte((u32)1);
        u16 bc = X86Mn.find(base);
        // vcmpps/vcmppd carry the predicate as a fourth, immediate operand.
        bool cmp = bc == x86Cmpps || bc == x86Cmppd;
        bool imm4 = cmp && _ops.count() == (u32)4 && opAt((u32)3) != (XOperand*)0 && opAt((u32)3).kind() == (u32)OP_IMM;
        if (_ops.count() != (u32)3 && !imm4)
            return false;
        u32 rr = cmp ? (bc == x86Cmppd ? $66C2 : $C2) : sseRR(bc);
        // Three-operand scalar forms not in sseRR (their legacy encodings
        // differ): vmovss/vmovsd reg, reg, reg merge the low element, and
        // vcvtsi2ss/sd take a GPR or memory source, W1 for 64 bits. As the
        // reference.
        bool cvtsi = false;
        if (rr == $FFFF_FFFF && bc == x86Movss) rr = $F310;
        if (rr == $FFFF_FFFF && bc == x86Movsd) rr = $F210;
        if (rr == $FFFF_FFFF && bc == x86Cvtsi2ss) { rr = $F32A; cvtsi = true; }
        if (rr == $FFFF_FFFF && bc == x86Cvtsi2sd) { rr = $F22A; cvtsi = true; }
        u32 map = (u32)1;
        // The 0F38 map: the SSE4.1 lane min/max and the 32-bit multiply.
        if (rr == (u32)$FFFF_FFFF)
            {
            rr = vex38(bc);
            map = (u32)2;
            }
        if (rr == (u32)$FFFF_FFFF)
            return false;
        XOperand* s1 = (XOperand*)_ops.get((u32)1);
        XOperand* s2 = (XOperand*)_ops.get((u32)2);
        if (s1 == (XOperand*)0 || s2 == (XOperand*)0)
            return false;
        if (s1.kind() != (u32)OP_REG || s2.kind() == (u32)OP_IMM)
            return false;
        // COMMUTE when the operation allows it and it buys a byte: the two-byte
        // form cannot hold a high register in r/m, but with the sources swapped
        // that register moves into vvvv, which it can. clang does this, so
        // matching it is required for byte-identity. NOT for sub or div, and
        // NOT for min/max — `minps a, b` returns b when either is NaN, so
        // swapping changes the answer.
        if (vexCommutes(bc) && s2.kind() == OP_REG
            && (s2.reg() & (u32)8) != (u32)0 && (s1.reg() & (u32)8) == (u32)0)
            {
            XOperand* t = s1; s1 = s2; s2 = t;
            }
        u32 pfx = rr >> (u32)8;
        u32 pp = pfx == (u32)$66 ? (u32)1 : pfx == (u32)$F3 ? (u32)2
               : pfx == (u32)$F2 ? (u32)3 : (u32)0;
        i32 bb = s2.kind() == (u32)OP_REG ? (i32)s2.reg() : s2.rmReg();
        i32 xx = s2.kind() == (u32)OP_REG ? (i32)0 : s2.index();
        if (bb < (i32)0) bb = (i32)0;
        if (xx < (i32)0) xx = (i32)0;
        u32 vvvv = (~s1.reg()) & (u32)$0F;
        u32 rhi = (a.reg() & (u32)8) != (u32)0 ? (u32)0 : (u32)$80;
        // VEX.L: 256-bit when the operands are ymm.
        u32 L = (a.size() == (u32)32 || s1.size() == (u32)32 || s2.size() == (u32)32) ? (u32)4 : (u32)0;
        // VEX.W: a 64-bit integer source of vcvtsi2ss/sd.
        u32 W = (cvtsi && s2.kind() == (u32)OP_REG && s2.size() == (u32)8) ? (u32)1 : (u32)0;
        // VEX.W: the double forms of the scalar FMAs.
        if (map == (u32)2 && base.hasPrefix(String.withCString("f"))
            && (base.hasSuffix(String.withCString("sd")) || base.hasSuffix(String.withCString("pd"))))
            W = (u32)1;
        if (cvtsi)
            L = (u32)0;
        if (map == (u32)1 && W == (u32)0 && (xx & (i32)8) == (i32)0 && (bb & (i32)8) == (i32)0)
            {
            e8((u32)$C5);
            e8(rhi | (vvvv << (u32)3) | L | pp);
            }
        else
            {
            e8((u32)$C4);
            e8(rhi | ((xx & (i32)8) != (i32)0 ? (u32)0 : (u32)$40)
                   | ((bb & (i32)8) != (i32)0 ? (u32)0 : (u32)$20) | map);
            e8((W << (u32)7) | (vvvv << (u32)3) | L | pp);
            }
        e8(rr & (u32)$FF);
        eModRM(a.reg(), s2);
        if (imm4)
            e8((u32)opAt((u32)3).imm() & (u32)$FF);
        _hit = true;
        return true;
        }

    // The 0F38-map VEX forms, as (prefix << 8) | opcode like sseRR.
    static u32 vex38(u16 mc)
        {
        if (mc == x86Pmaxsd) return $663D;
        if (mc == x86Pminsd) return $6639;
        if (mc == x86Pmaxud) return $663F;
        if (mc == x86Pminud) return $663B;
        if (mc == x86Pmaxsb) return $663C;
        if (mc == x86Pminsb) return $6638;
        if (mc == x86Pmaxuw) return $663E;
        if (mc == x86Pminuw) return $663A;
        if (mc == x86Pmulld) return $6640;
        // The u8 pair sum the 256-bit widening reductions use (bug 644).
        if (mc == x86Pmaddubsw) return $6604;
        // Scalar FMA (:goal(speed) code's fused multiply-adds), VEX.W1 for the
        // double forms.
        if (mc == x86Fmadd231ss || mc == x86Fmadd231sd) return $66B9;
        if (mc == x86Fmsub231ss || mc == x86Fmsub231sd) return $66BB;
        if (mc == x86Fnmadd231ss || mc == x86Fnmadd231sd) return $66BD;
        if (mc == x86Fmadd213ss || mc == x86Fmadd213sd) return $66A9;
        if (mc == x86Fmsub213ss || mc == x86Fmsub213sd) return $66AB;
        if (mc == x86Fnmadd213ss || mc == x86Fnmadd213sd) return $66AD;
        // Packed FMA (vector code's fused multiply-adds), VEX.W1 for the double
        // forms.
        if (mc == x86Fmadd231ps || mc == x86Fmadd231pd) return $66B8;
        if (mc == x86Fmsub231ps || mc == x86Fmsub231pd) return $66BA;
        if (mc == x86Fnmadd231ps || mc == x86Fnmadd231pd) return $66BC;
        if (mc == x86Fmadd213ps || mc == x86Fmadd213pd) return $66A8;
        if (mc == x86Fmsub213ps || mc == x86Fmsub213pd) return $66AA;
        if (mc == x86Fnmadd213ps || mc == x86Fnmadd213pd) return $66AC;
        return (u32)$FFFF_FFFF;
        }

    // A VEX prefix for a form with no first source (vvvv = the given value,
    // 1111 for "none"): the two-byte form when it can hold it.
    void eVex(u32 rr, i32 xx, i32 bb, u32 map, u32 vvvv, u32 L, u32 pp)
        {
        u32 rhi = (rr & (u32)8) != (u32)0 ? (u32)0 : (u32)$80;
        if (map == (u32)1 && (xx & (i32)8) == (i32)0 && (bb & (i32)8) == (i32)0)
            {
            e8((u32)$C5);
            e8(rhi | (vvvv << (u32)3) | L | pp);
            }
        else
            {
            e8((u32)$C4);
            e8(rhi | ((xx & (i32)8) != (i32)0 ? (u32)0 : (u32)$40)
                   | ((bb & (i32)8) != (i32)0 ? (u32)0 : (u32)$20) | map);
            e8((vvvv << (u32)3) | L | pp);
            }
        }

    // ModRM for an EVEX instruction: eModRM, except that an 8-bit
    // displacement is scaled by N, the memory operand's size ("disp8*N"). A
    // multiple of N that fits after dividing takes the short form, holding
    // disp/N; any other non-zero displacement takes disp32. The forms with no
    // base register carry a disp32 already, and are eModRM's.
    void eModRMN(u32 reg, XOperand* rm, u32 n)
        {
        if (rm.kind() == (u32)OP_REG || rm.base() < (i32)0 || rm.ripRel() || rm.seg() != (u32)0)
            {
            eModRM(reg, rm);
            return;
            }
        i32 base = rm.base();
        i32 index = rm.index();
        bool needSib = index >= (i32)0 || ((u32)base & (u32)7) == (u32)4;
        i32 d = rm.disp();
        i32 q = (i32)0;
        u32 mod;
        if (d == (i32)0 && ((u32)base & (u32)7) != (u32)5)
            mod = (u32)0;
        else if (n > (u32)0 && d % (i32)n == (i32)0 && d / (i32)n >= (i32)-128 && d / (i32)n <= (i32)127)
            {
            mod = (u32)1;
            q = d / (i32)n;
            }
        else
            mod = (u32)2;
        e8((mod << (u32)6) | ((reg & (u32)7) << (u32)3) | (needSib ? (u32)4 : ((u32)base & (u32)7)));
        if (needSib)
            {
            u32 ss = rm.scale() == (u32)8 ? (u32)3 : rm.scale() == (u32)4 ? (u32)2
                                                 : rm.scale() == (u32)2   ? (u32)1
                                                                          : (u32)0;
            u32 idx = index >= (i32)0 ? ((u32)index & (u32)7) : (u32)4;
            e8((ss << (u32)6) | (idx << (u32)3) | ((u32)base & (u32)7));
            }
        if (mod == (u32)1)
            e8((u32)q);
        else if (mod == (u32)2)
            e32((u32)d);
        }

    // The 4-byte EVEX prefix: 62, then
    //   P0  R X B R' 0 m m m    R, X, B, R' inverted; mmm the map (1 0F, 2 0F38, 3 0F3A)
    //   P1  W v v v v 1 p p     vvvv the first source inverted (1111 when none)
    //   P2  z L'L b V' a a a    L'L the length (2 = 512); V' inverted; aaa the opmask
    // Registers are 0-15, so R' and V' are always 1. For a register r/m, X holds
    // bit 4 of that register (1, inverted); for memory, the index's bit 3.
    // R' holds bit 4 of the reg register and V' bit 4 of vvvv's (both
    // inverted); for a register r/m, X holds bit 4 of that register. As the
    // reference.
    void eEvex(u32 map, u32 pp, u32 w, u32 reg, i32 vreg, XOperand* rm, u32 ll)
        {
        i32 bb = rm.kind() == (u32)OP_REG ? (i32)rm.reg() : rm.base();
        i32 xx = rm.kind() == (u32)OP_REG ? (i32)((rm.reg() & (u32)16) >> (u32)1) : rm.index();
        if (bb < (i32)0) bb = (i32)0;
        if (xx < (i32)0) xx = (i32)0;
        u32 vv = vreg < (i32)0 ? (u32)0 : (u32)vreg;
        u32 vvvv = vreg < (i32)0 ? (u32)$0F : ((~(u32)vreg) & (u32)$0F);
        _evexUsed = true;
        e8((u32)$62);
        e8(((reg & (u32)8) != (u32)0 ? (u32)0 : (u32)$80) | (((u32)xx & (u32)8) != (u32)0 ? (u32)0 : (u32)$40)
           | (((u32)bb & (u32)8) != (u32)0 ? (u32)0 : (u32)$20) | ((reg & (u32)16) != (u32)0 ? (u32)0 : (u32)$10)
           | (map & (u32)7));
        e8((w != (u32)0 ? (u32)$80 : (u32)0) | (vvvv << (u32)3) | (u32)4 | (pp & (u32)3));
        e8((ll << (u32)5) | ((vv & (u32)16) != (u32)0 ? (u32)0 : (u32)8));
        }

    // A register number 16-31 (zmm16-31) named in an instruction's text.
    static bool namesHighZmm(String* s)
        {
        String* t = s.lowercased();
        u32 n = t.byteLength();
        for (u32 i = (u32)0; i + (u32)4 < n; i = i + (u32)1)
            {
            if (t.byteAt(i) != (u8)'z' || t.byteAt(i + (u32)1) != (u8)'m' || t.byteAt(i + (u32)2) != (u8)'m')
                continue;
            if (i > (u32)0 && X86Asm.identByte(t.byteAt(i - (u32)1)))
                continue;
            u8 d1 = t.byteAt(i + (u32)3);
            u8 d2 = t.byteAt(i + (u32)4);
            if (d2 < (u8)'0' || d2 > (u8)'9')
                continue;
            if (i + (u32)5 < n && X86Asm.identByte(t.byteAt(i + (u32)5)))
                continue;
            u32 v = (u32)(d1 - (u8)'0') * (u32)10 + (u32)(d2 - (u8)'0');
            if (d1 >= (u8)'1' && d1 <= (u8)'3' && v >= (u32)16 && v <= (u32)31)
                return true;
            }
        return false;
        }

    static bool identByte(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }

    static void evAdd(Map* m, String* name, u32 form, u32 map, u32 pp, u32 w, u32 op, u32 n)
        {
        u32 v = (form << (u32)28) | (map << (u32)24) | (pp << (u32)20) | (w << (u32)16) | (op << (u32)8) | n;
        m.set((Hashable*)name, (Object*)Number.withU32(v));
        }

    // The EVEX table, as the reference's: form, map, pp, W, opcode, N (the
    // memory operand's size for disp8*N; for form 7 the /ext).
    void evexTables(void)
        {
        Map* m = new Map();
        evAdd(m, String.withCString("vaddps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$58, (u32)64);
        evAdd(m, String.withCString("vaddpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$58, (u32)64);
        evAdd(m, String.withCString("vsubps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$5C, (u32)64);
        evAdd(m, String.withCString("vsubpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$5C, (u32)64);
        evAdd(m, String.withCString("vmulps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$59, (u32)64);
        evAdd(m, String.withCString("vmulpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$59, (u32)64);
        evAdd(m, String.withCString("vdivps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$5E, (u32)64);
        evAdd(m, String.withCString("vdivpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$5E, (u32)64);
        evAdd(m, String.withCString("vmaxps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$5F, (u32)64);
        evAdd(m, String.withCString("vmaxpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$5F, (u32)64);
        evAdd(m, String.withCString("vminps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$5D, (u32)64);
        evAdd(m, String.withCString("vminpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$5D, (u32)64);
        evAdd(m, String.withCString("vandps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$54, (u32)64);
        evAdd(m, String.withCString("vandpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$54, (u32)64);
        evAdd(m, String.withCString("vandnps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$55, (u32)64);
        evAdd(m, String.withCString("vandnpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$55, (u32)64);
        evAdd(m, String.withCString("vorps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$56, (u32)64);
        evAdd(m, String.withCString("vorpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$56, (u32)64);
        evAdd(m, String.withCString("vxorps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$57, (u32)64);
        evAdd(m, String.withCString("vxorpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$57, (u32)64);
        evAdd(m, String.withCString("vunpcklps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$14, (u32)64);
        evAdd(m, String.withCString("vunpcklpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$14, (u32)64);
        evAdd(m, String.withCString("vunpckhps"), (u32)1, (u32)1, (u32)0, (u32)0, (u32)$15, (u32)64);
        evAdd(m, String.withCString("vunpckhpd"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$15, (u32)64);
        evAdd(m, String.withCString("vpaddb"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$FC, (u32)64);
        evAdd(m, String.withCString("vpaddw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$FD, (u32)64);
        evAdd(m, String.withCString("vpaddd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$FE, (u32)64);
        evAdd(m, String.withCString("vpaddq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$D4, (u32)64);
        evAdd(m, String.withCString("vpsubb"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$F8, (u32)64);
        evAdd(m, String.withCString("vpsubw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$F9, (u32)64);
        evAdd(m, String.withCString("vpsubd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$FA, (u32)64);
        evAdd(m, String.withCString("vpsubq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$FB, (u32)64);
        evAdd(m, String.withCString("vpandd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$DB, (u32)64);
        evAdd(m, String.withCString("vpandq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$DB, (u32)64);
        evAdd(m, String.withCString("vpandnd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$DF, (u32)64);
        evAdd(m, String.withCString("vpandnq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$DF, (u32)64);
        evAdd(m, String.withCString("vpord"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$EB, (u32)64);
        evAdd(m, String.withCString("vporq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$EB, (u32)64);
        evAdd(m, String.withCString("vpxord"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$EF, (u32)64);
        evAdd(m, String.withCString("vpxorq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$EF, (u32)64);
        evAdd(m, String.withCString("vpmullw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$D5, (u32)64);
        evAdd(m, String.withCString("vpmuludq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$F4, (u32)64);
        evAdd(m, String.withCString("vpmaddwd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$F5, (u32)64);
        evAdd(m, String.withCString("vpunpcklbw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$60, (u32)64);
        evAdd(m, String.withCString("vpunpcklwd"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$61, (u32)64);
        evAdd(m, String.withCString("vpunpckldq"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$62, (u32)64);
        evAdd(m, String.withCString("vpunpcklqdq"), (u32)1, (u32)1, (u32)1, (u32)1, (u32)$6C, (u32)64);
        evAdd(m, String.withCString("vpmaxsw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$EE, (u32)64);
        evAdd(m, String.withCString("vpminsw"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$EA, (u32)64);
        evAdd(m, String.withCString("vpmaxub"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$DE, (u32)64);
        evAdd(m, String.withCString("vpminub"), (u32)1, (u32)1, (u32)1, (u32)0, (u32)$DA, (u32)64);
        evAdd(m, String.withCString("vpmulld"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$40, (u32)64);
        evAdd(m, String.withCString("vpmullq"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$40, (u32)64);
        // Packed FMA: reg = the destination (the addend for 231, a factor for 213).
        evAdd(m, String.withCString("vfmadd231ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$B8, (u32)64);
        evAdd(m, String.withCString("vfmadd231pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$B8, (u32)64);
        evAdd(m, String.withCString("vfmsub231ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$BA, (u32)64);
        evAdd(m, String.withCString("vfmsub231pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$BA, (u32)64);
        evAdd(m, String.withCString("vfnmadd231ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$BC, (u32)64);
        evAdd(m, String.withCString("vfnmadd231pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$BC, (u32)64);
        evAdd(m, String.withCString("vfmadd213ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$A8, (u32)64);
        evAdd(m, String.withCString("vfmadd213pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$A8, (u32)64);
        evAdd(m, String.withCString("vfmsub213ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$AA, (u32)64);
        evAdd(m, String.withCString("vfmsub213pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$AA, (u32)64);
        evAdd(m, String.withCString("vfnmadd213ps"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$AC, (u32)64);
        evAdd(m, String.withCString("vfnmadd213pd"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$AC, (u32)64);
        evAdd(m, String.withCString("vpmaxsd"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3D, (u32)64);
        evAdd(m, String.withCString("vpminsd"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$39, (u32)64);
        evAdd(m, String.withCString("vpmaxud"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3F, (u32)64);
        evAdd(m, String.withCString("vpminud"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3B, (u32)64);
        evAdd(m, String.withCString("vpmaxsq"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$3D, (u32)64);
        evAdd(m, String.withCString("vpminsq"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$39, (u32)64);
        evAdd(m, String.withCString("vpmaxuq"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$3F, (u32)64);
        evAdd(m, String.withCString("vpminuq"), (u32)1, (u32)2, (u32)1, (u32)1, (u32)$3B, (u32)64);
        evAdd(m, String.withCString("vpmaxsb"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3C, (u32)64);
        evAdd(m, String.withCString("vpminsb"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$38, (u32)64);
        evAdd(m, String.withCString("vpmaxuw"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3E, (u32)64);
        evAdd(m, String.withCString("vpminuw"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$3A, (u32)64);
        evAdd(m, String.withCString("vpmaddubsw"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$04, (u32)64);
        evAdd(m, String.withCString("vmovdqu32"), (u32)2, (u32)1, (u32)2, (u32)0, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovdqu64"), (u32)2, (u32)1, (u32)2, (u32)1, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovdqu8"), (u32)2, (u32)1, (u32)3, (u32)0, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovdqu16"), (u32)2, (u32)1, (u32)3, (u32)1, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovdqa32"), (u32)2, (u32)1, (u32)1, (u32)0, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovdqa64"), (u32)2, (u32)1, (u32)1, (u32)1, (u32)$6F, (u32)64);
        evAdd(m, String.withCString("vmovups"), (u32)2, (u32)1, (u32)0, (u32)0, (u32)$10, (u32)64);
        evAdd(m, String.withCString("vmovupd"), (u32)2, (u32)1, (u32)1, (u32)1, (u32)$10, (u32)64);
        evAdd(m, String.withCString("vmovaps"), (u32)2, (u32)1, (u32)0, (u32)0, (u32)$28, (u32)64);
        evAdd(m, String.withCString("vmovapd"), (u32)2, (u32)1, (u32)1, (u32)1, (u32)$28, (u32)64);
        evAdd(m, String.withCString("vpbroadcastb"), (u32)3, (u32)2, (u32)1, (u32)0, (u32)$78, (u32)1);
        evAdd(m, String.withCString("vpbroadcastw"), (u32)3, (u32)2, (u32)1, (u32)0, (u32)$79, (u32)2);
        evAdd(m, String.withCString("vpbroadcastd"), (u32)3, (u32)2, (u32)1, (u32)0, (u32)$58, (u32)4);
        evAdd(m, String.withCString("vpbroadcastq"), (u32)3, (u32)2, (u32)1, (u32)1, (u32)$59, (u32)8);
        evAdd(m, String.withCString("vbroadcastss"), (u32)3, (u32)2, (u32)1, (u32)0, (u32)$18, (u32)4);
        evAdd(m, String.withCString("vbroadcastsd"), (u32)3, (u32)2, (u32)1, (u32)1, (u32)$19, (u32)8);
        evAdd(m, String.withCString("vpcmpeqb"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$74, (u32)64);
        evAdd(m, String.withCString("vpcmpgtb"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$64, (u32)64);
        evAdd(m, String.withCString("vpcmpeqw"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$75, (u32)64);
        evAdd(m, String.withCString("vpcmpgtw"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$65, (u32)64);
        evAdd(m, String.withCString("vpcmpeqd"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$76, (u32)64);
        evAdd(m, String.withCString("vpcmpgtd"), (u32)4, (u32)1, (u32)1, (u32)0, (u32)$66, (u32)64);
        evAdd(m, String.withCString("vpcmpeqq"), (u32)4, (u32)2, (u32)1, (u32)1, (u32)$29, (u32)64);
        evAdd(m, String.withCString("vpcmpgtq"), (u32)4, (u32)2, (u32)1, (u32)1, (u32)$37, (u32)64);
        evAdd(m, String.withCString("vcmpps"), (u32)5, (u32)1, (u32)0, (u32)0, (u32)$C2, (u32)64);
        evAdd(m, String.withCString("vcmppd"), (u32)5, (u32)1, (u32)1, (u32)1, (u32)$C2, (u32)64);
        evAdd(m, String.withCString("vpcmpd"), (u32)5, (u32)3, (u32)1, (u32)0, (u32)$1F, (u32)64);
        evAdd(m, String.withCString("vpcmpud"), (u32)5, (u32)3, (u32)1, (u32)0, (u32)$1E, (u32)64);
        evAdd(m, String.withCString("vpcmpq"), (u32)5, (u32)3, (u32)1, (u32)1, (u32)$1F, (u32)64);
        evAdd(m, String.withCString("vpcmpuq"), (u32)5, (u32)3, (u32)1, (u32)1, (u32)$1E, (u32)64);
        evAdd(m, String.withCString("vpcmpb"), (u32)5, (u32)3, (u32)1, (u32)0, (u32)$3F, (u32)64);
        evAdd(m, String.withCString("vpcmpub"), (u32)5, (u32)3, (u32)1, (u32)0, (u32)$3E, (u32)64);
        evAdd(m, String.withCString("vpcmpw"), (u32)5, (u32)3, (u32)1, (u32)1, (u32)$3F, (u32)64);
        evAdd(m, String.withCString("vpcmpuw"), (u32)5, (u32)3, (u32)1, (u32)1, (u32)$3E, (u32)64);
        evAdd(m, String.withCString("vpmovm2b"), (u32)6, (u32)2, (u32)2, (u32)0, (u32)$28, (u32)0);
        evAdd(m, String.withCString("vpmovm2w"), (u32)6, (u32)2, (u32)2, (u32)1, (u32)$28, (u32)0);
        evAdd(m, String.withCString("vpmovm2d"), (u32)6, (u32)2, (u32)2, (u32)0, (u32)$38, (u32)0);
        evAdd(m, String.withCString("vpmovm2q"), (u32)6, (u32)2, (u32)2, (u32)1, (u32)$38, (u32)0);
        evAdd(m, String.withCString("vpsrlw"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$71, (u32)2);
        evAdd(m, String.withCString("vpsraw"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$71, (u32)4);
        evAdd(m, String.withCString("vpsllw"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$71, (u32)6);
        evAdd(m, String.withCString("vpsrld"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$72, (u32)2);
        evAdd(m, String.withCString("vpsrad"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$72, (u32)4);
        evAdd(m, String.withCString("vpslld"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$72, (u32)6);
        evAdd(m, String.withCString("vprold"), (u32)7, (u32)1, (u32)1, (u32)0, (u32)$72, (u32)1);
        evAdd(m, String.withCString("vpsrlq"), (u32)7, (u32)1, (u32)1, (u32)1, (u32)$73, (u32)2);
        evAdd(m, String.withCString("vpsraq"), (u32)7, (u32)1, (u32)1, (u32)1, (u32)$72, (u32)4);
        evAdd(m, String.withCString("vpsllq"), (u32)7, (u32)1, (u32)1, (u32)1, (u32)$73, (u32)6);
        evAdd(m, String.withCString("vextracti64x4"), (u32)8, (u32)3, (u32)1, (u32)1, (u32)$3B, (u32)32);
        evAdd(m, String.withCString("vextractf64x4"), (u32)8, (u32)3, (u32)1, (u32)1, (u32)$1B, (u32)32);
        evAdd(m, String.withCString("vextracti32x4"), (u32)8, (u32)3, (u32)1, (u32)0, (u32)$39, (u32)16);
        evAdd(m, String.withCString("vextractf32x4"), (u32)8, (u32)3, (u32)1, (u32)0, (u32)$19, (u32)16);
        evAdd(m, String.withCString("vpshufd"), (u32)9, (u32)1, (u32)1, (u32)0, (u32)$70, (u32)64);
        evAdd(m, String.withCString("vpshufhw"), (u32)9, (u32)1, (u32)2, (u32)0, (u32)$70, (u32)64);
        evAdd(m, String.withCString("vpshuflw"), (u32)9, (u32)1, (u32)3, (u32)0, (u32)$70, (u32)64);
        evAdd(m, String.withCString("vshufps"), (u32)10, (u32)1, (u32)0, (u32)0, (u32)$C6, (u32)64);
        evAdd(m, String.withCString("vshufpd"), (u32)10, (u32)1, (u32)1, (u32)1, (u32)$C6, (u32)64);
        evAdd(m, String.withCString("vpternlogd"), (u32)10, (u32)3, (u32)1, (u32)0, (u32)$25, (u32)64);
        // vpermi2d zmm(idx, dst), zmm(table 1), zmm(table 2): VMulHi's merge.
        evAdd(m, String.withCString("vpermi2d"), (u32)1, (u32)2, (u32)1, (u32)0, (u32)$76, (u32)64);
        evAdd(m, String.withCString("vpternlogq"), (u32)10, (u32)3, (u32)1, (u32)1, (u32)$25, (u32)64);
        evAdd(m, String.withCString("vinserti64x4"), (u32)10, (u32)3, (u32)1, (u32)1, (u32)$3A, (u32)32);
        evAdd(m, String.withCString("vinsertf64x4"), (u32)10, (u32)3, (u32)1, (u32)1, (u32)$1A, (u32)32);
        evAdd(m, String.withCString("vpabsb"), (u32)12, (u32)2, (u32)1, (u32)0, (u32)$1C, (u32)64);
        evAdd(m, String.withCString("vpabsw"), (u32)12, (u32)2, (u32)1, (u32)0, (u32)$1D, (u32)64);
        evAdd(m, String.withCString("vpabsd"), (u32)12, (u32)2, (u32)1, (u32)0, (u32)$1E, (u32)64);
        evAdd(m, String.withCString("vpabsq"), (u32)12, (u32)2, (u32)1, (u32)1, (u32)$1F, (u32)64);
        evAdd(m, String.withCString("vsqrtps"), (u32)12, (u32)1, (u32)0, (u32)0, (u32)$51, (u32)64);
        evAdd(m, String.withCString("vsqrtpd"), (u32)12, (u32)1, (u32)1, (u32)1, (u32)$51, (u32)64);
        evAdd(m, String.withCString("vcvtdq2ps"), (u32)12, (u32)1, (u32)0, (u32)0, (u32)$5B, (u32)64);
        evAdd(m, String.withCString("vcvttps2dq"), (u32)12, (u32)1, (u32)2, (u32)0, (u32)$5B, (u32)64);
        evAdd(m, String.withCString("vcvtps2dq"), (u32)12, (u32)1, (u32)1, (u32)0, (u32)$5B, (u32)64);
        evAdd(m, String.withCString("vcvtps2pd"), (u32)12, (u32)1, (u32)0, (u32)0, (u32)$5A, (u32)32);
        evAdd(m, String.withCString("vcvtpd2ps"), (u32)12, (u32)1, (u32)1, (u32)1, (u32)$5A, (u32)64);
        evAdd(m, String.withCString("vcvttpd2dq"), (u32)12, (u32)1, (u32)1, (u32)1, (u32)$E6, (u32)64);
        evAdd(m, String.withCString("vcvtdq2pd"), (u32)12, (u32)1, (u32)2, (u32)0, (u32)$E6, (u32)32);
        _evex = m;
        Map* x = new Map();
        evAdd(x, String.withCString("vpsrlw"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$D1, (u32)16);
        evAdd(x, String.withCString("vpsraw"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$E1, (u32)16);
        evAdd(x, String.withCString("vpsllw"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$F1, (u32)16);
        evAdd(x, String.withCString("vpsrld"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$D2, (u32)16);
        evAdd(x, String.withCString("vpsrad"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$E2, (u32)16);
        evAdd(x, String.withCString("vpslld"), (u32)11, (u32)1, (u32)1, (u32)0, (u32)$F2, (u32)16);
        evAdd(x, String.withCString("vpsrlq"), (u32)11, (u32)1, (u32)1, (u32)1, (u32)$D3, (u32)16);
        evAdd(x, String.withCString("vpsllq"), (u32)11, (u32)1, (u32)1, (u32)1, (u32)$F3, (u32)16);
        _evexX = x;
        }

    // ── EVEX.512: AVX-512 forms (F, DQ, BW, VL) ──
    // Any instruction with a zmm operand, encoded from the table above. The
    // forms, by where each operand goes, are the reference's:
    //   1 dst, src1, src2       reg = dst, vvvv = src1, r/m = src2
    //   2 move                  load: reg = dst, r/m = src; store: the reverse
    //   3 broadcast             reg = dst, r/m = the xmm or element in memory
    //   4 compare into k        reg = k, vvvv = src1, r/m = src2   (5: + imm)
    //   6 k to vector           reg = dst, r/m = k
    //   7 shift by immediate    vvvv = dst, r/m = src, reg = the /ext
    //   8 extract               reg = the zmm source, r/m = the dest, imm
    //   9 shuffle by immediate  reg = dst, r/m = src, imm
    //  10 dst, src1, src2, imm  reg = dst, vvvv = src1, r/m = src2, imm
    //  11 shift by xmm count    as 1, the count an xmm (N 16)
    //  12 unary                 reg = dst, r/m = src
    bool encEvex(String* mn, XOperand* a, XOperand* b)
        {
        bool zmm = false;
        for (u32 i = (u32)0; i < _ops.count(); i = i + (u32)1)
            {
            XOperand* o = (XOperand*)_ops.get(i);
            if (o.kind() == (u32)OP_REG && o.size() == (u32)64)
                zmm = true;
            }
        if (!zmm)
            return false;
        if (_evex == (Map*)0)
            evexTables();
        u32 n0 = _ops.count();
        Number* ent = (Number*)_evex.get((Hashable*)mn);
        if (ent != (Number*)0 && (ent.asU32() >> (u32)28) == (u32)7 && n0 == (u32)3
            && ((XOperand*)_ops.get((u32)2)).kind() != (u32)OP_IMM)
            ent = (Number*)_evexX.get((Hashable*)mn);
        _hit = true;
        if (ent == (Number*)0)
            {
            String* m = String.withCString("x86-64: no EVEX (zmm) form of '");
            m.append(mn);
            m.appendByte((u8)$27);
            fail(m);
            return true;
            }
        u32 v = ent.asU32();
        u32 form = v >> (u32)28;
        u32 map = (v >> (u32)24) & (u32)$0F;
        u32 pp = (v >> (u32)20) & (u32)$0F;
        u32 w = (v >> (u32)16) & (u32)$0F;
        u32 op = (v >> (u32)8) & (u32)$FF;
        u32 n = v & (u32)$FF;
        XOperand* c = n0 > (u32)2 ? (XOperand*)_ops.get((u32)2) : (XOperand*)0;
        XOperand* dd = n0 > (u32)3 ? (XOperand*)_ops.get((u32)3) : (XOperand*)0;
        if (form == (u32)1 || form == (u32)11)
            {
            if (n0 == (u32)3 && a.kind() == (u32)OP_REG && b.kind() == (u32)OP_REG && c.kind() != (u32)OP_IMM)
                {
                eEvex(map, pp, w, a.reg(), (i32)b.reg(), c, (u32)2);
                e8(op);
                eModRMN(a.reg(), c, n);
                return true;
                }
            }
        else if (form == (u32)2)
            {
            if (n0 == (u32)2)
                {
                bool store = a.kind() == (u32)OP_MEM;
                XOperand* regop = store ? b : a;
                XOperand* rmop = store ? a : b;
                if (regop.kind() == (u32)OP_REG)
                    {
                    u32 sop = op == (u32)$6F ? (u32)$7F : op + (u32)1;
                    eEvex(map, pp, w, regop.reg(), (i32)-1, rmop, (u32)2);
                    e8(store ? sop : op);
                    eModRMN(regop.reg(), rmop, n);
                    return true;
                    }
                }
            }
        else if (form == (u32)3 || form == (u32)12)
            {
            if (n0 == (u32)2 && a.kind() == (u32)OP_REG)
                {
                eEvex(map, pp, w, a.reg(), (i32)-1, b, (u32)2);
                e8(op);
                eModRMN(a.reg(), b, n);
                return true;
                }
            }
        else if (form == (u32)4)
            {
            if (n0 == (u32)3 && a.size() == (u32)XK_SIZE && b.kind() == (u32)OP_REG && c.kind() != (u32)OP_IMM)
                {
                eEvex(map, pp, w, a.reg(), (i32)b.reg(), c, (u32)2);
                e8(op);
                eModRMN(a.reg(), c, n);
                return true;
                }
            }
        else if (form == (u32)5)
            {
            if (n0 == (u32)4 && a.size() == (u32)XK_SIZE && b.kind() == (u32)OP_REG && dd.kind() == (u32)OP_IMM)
                {
                eEvex(map, pp, w, a.reg(), (i32)b.reg(), c, (u32)2);
                e8(op);
                eModRMN(a.reg(), c, n);
                e8((u32)dd.imm());
                return true;
                }
            }
        else if (form == (u32)6)
            {
            if (n0 == (u32)2 && a.kind() == (u32)OP_REG && b.size() == (u32)XK_SIZE)
                {
                eEvex(map, pp, w, a.reg(), (i32)-1, b, (u32)2);
                e8(op);
                eModRM(a.reg(), b);
                return true;
                }
            }
        else if (form == (u32)7)
            {
            if (n0 == (u32)3 && a.kind() == (u32)OP_REG && c.kind() == (u32)OP_IMM)
                {
                eEvex(map, pp, w, n, (i32)a.reg(), b, (u32)2);
                e8(op);
                eModRMN(n, b, (u32)64);
                e8((u32)c.imm());
                return true;
                }
            }
        else if (form == (u32)8)
            {
            if (n0 == (u32)3 && b.kind() == (u32)OP_REG && c.kind() == (u32)OP_IMM)
                {
                eEvex(map, pp, w, b.reg(), (i32)-1, a, (u32)2);
                e8(op);
                eModRMN(b.reg(), a, n);
                e8((u32)c.imm());
                return true;
                }
            }
        else if (form == (u32)9)
            {
            if (n0 == (u32)3 && a.kind() == (u32)OP_REG && c.kind() == (u32)OP_IMM)
                {
                eEvex(map, pp, w, a.reg(), (i32)-1, b, (u32)2);
                e8(op);
                eModRMN(a.reg(), b, n);
                e8((u32)c.imm());
                return true;
                }
            }
        else if (form == (u32)10)
            {
            if (n0 == (u32)4 && a.kind() == (u32)OP_REG && b.kind() == (u32)OP_REG && dd.kind() == (u32)OP_IMM)
                {
                eEvex(map, pp, w, a.reg(), (i32)b.reg(), c, (u32)2);
                e8(op);
                eModRMN(a.reg(), c, n);
                e8((u32)dd.imm());
                return true;
                }
            }
        String* m = String.withCString("x86-64: '");
        m.append(mn);
        m.appendCString("' with these operands has no EVEX (zmm) form");
        fail(m);
        return true;
        }

    // ── AVX/AVX2 forms that are not a three-operand SSE op ──
    // vzeroupper; two-operand moves and broadcasts; vextract{i,f}128 (the
    // source in reg, the destination in r/m); the immediate shifts (the
    // DESTINATION in vvvv, the source in r/m). As the reference encodes them.
    bool encAvx(String* mn, u16 mc, XOperand* a, XOperand* b)
        {
        if (mn.byteLength() < (u32)2 || mn.byteAt((u32)0) != (u8)'v')
            return false;
        if (mc == x86Vzeroupper && _ops.count() == 0)
            {
            e8((u32)$C5); e8((u32)$F8); e8((u32)$77);
            _hit = true;
            return true;
            }
        // vmovd/vmovq between an xmm and a GP register or memory: movd and
        // movq's VEX forms (66 0F 6E/7E; W1 for the 64-bit one). An AVX
        // function uses these, never the legacy forms: a legacy write to an
        // xmm whose upper ymm half is live made the AVX2 md5 22x slower than
        // its SSE build on a Zen 3.
        bool isVmovd = mc == x86Vmovd;
        if ((isVmovd || mc == x86Vmovq) && _ops.count() == 2 && a != (XOperand*)0 && b != (XOperand*)0
            && (a.size() == (u32)16) != (b.size() == (u32)16))
            {
            bool toXmm = a.size() == (u32)16;
            XOperand* xmm = toXmm ? a : b;
            XOperand* other = toXmm ? b : a;
            i32 bb = other.kind() == (u32)OP_REG ? (i32)other.reg() : other.rmReg();
            i32 xx = other.kind() == (u32)OP_REG ? (i32)0 : other.index();
            if (bb < (i32)0) bb = (i32)0;
            if (xx < (i32)0) xx = (i32)0;
            if (isVmovd)
                eVex(xmm.reg(), xx, bb, (u32)1, (u32)$0F, (u32)0, (u32)1);
            else
                {
                // The three-byte form, for W.
                u32 rhi = (xmm.reg() & (u32)8) != (u32)0 ? (u32)0 : (u32)$80;
                e8((u32)$C4);
                e8(rhi | ((xx & (i32)8) != (i32)0 ? (u32)0 : (u32)$40) | ((bb & (i32)8) != (i32)0 ? (u32)0 : (u32)$20) | (u32)1);
                e8((u32)$80 | ((u32)$0F << (u32)3) | (u32)1);
                }
            e8(toXmm ? (u32)$6E : (u32)$7E);
            eModRM(xmm.reg(), other);
            _hit = true;
            return true;
            }
        // pp, map, load opcode, store opcode (0 = none)
        u32 pp = (u32)0; u32 map = (u32)0; u32 ld = (u32)0; u32 st = (u32)0;
        bool bcast = false;
        if (mc == x86Vmovdqu)      { pp = 2; map = 1; ld = $6F; st = $7F; }
        else if (mc == x86Vmovdqa) { pp = 1; map = 1; ld = $6F; st = $7F; }
        else if (mc == x86Vmovups) { pp = 0; map = 1; ld = $10; st = $11; }
        else if (mc == x86Vmovaps) { pp = 0; map = 1; ld = $28; st = $29; }
        else if (mc == x86Vpbroadcastb) { pp = 1; map = 2; ld = $78; bcast = true; }
        else if (mc == x86Vpbroadcastw) { pp = 1; map = 2; ld = $79; bcast = true; }
        else if (mc == x86Vpbroadcastd) { pp = 1; map = 2; ld = $58; bcast = true; }
        else if (mc == x86Vpbroadcastq) { pp = 1; map = 2; ld = $59; bcast = true; }
        else if (mc == x86Vbroadcastss) { pp = 1; map = 2; ld = $18; bcast = true; }
        else if (mc == x86Vbroadcastsd) { pp = 1; map = 2; ld = $19; bcast = true; }
        else if (mc == x86Vpabsb) { pp = 1; map = 2; ld = $1C; }
        else if (mc == x86Vpabsw) { pp = 1; map = 2; ld = $1D; }
        else if (mc == x86Vpabsd) { pp = 1; map = 2; ld = $1E; }
        // 2-operand VEX arithmetic (vvvv = 1111): the float square root.
        else if (mc == x86Vsqrtps) { pp = 0; map = 1; ld = $51; }
        else if (mc == x86Vsqrtpd) { pp = 1; map = 1; ld = $51; }
        // and the lane conversions, int to float and float to int (#27).
        else if (mc == x86Vcvtdq2ps) { pp = 0; map = 1; ld = $5B; }
        else if (mc == x86Vcvttps2dq) { pp = 2; map = 1; ld = $5B; }
        // F16C: four halves to floats (VEX.128.66.0F38.W0 13 /r).
        else if (mc == x86Vcvtph2ps) { pp = 1; map = 2; ld = $13; }
        // The scalar compares, and the scalar moves to or from memory (a
        // register-to-register vmovss takes three operands, encVex128): what an
        // AVX function's scalar float code uses. As the reference.
        else if (mc == x86Vucomiss) { pp = 0; map = 1; ld = $2E; }
        else if (mc == x86Vucomisd) { pp = 1; map = 1; ld = $2E; }
        else if (mc == x86Vcomiss) { pp = 0; map = 1; ld = $2F; }
        else if (mc == x86Vcomisd) { pp = 1; map = 1; ld = $2F; }
        else if (mc == x86Vmovss) { pp = 2; map = 1; ld = $10; st = $11; }
        else if (mc == x86Vmovsd) { pp = 3; map = 1; ld = $10; st = $11; }
        // vcvttss2si / vcvttsd2si r, xmm/m: VEX.LIG.F3/F2.0F.W 2C /r, W1 for a
        // 64-bit destination; reg = the GPR, r/m = the source.
        if ((mc == x86Vcvttss2si || mc == x86Vcvttsd2si)
            && _ops.count() == (u32)2 && a != (XOperand*)0 && b != (XOperand*)0 && a.kind() == (u32)OP_REG)
            {
            u32 tpp = mc == x86Vcvttss2si ? 2 : 3;
            u32 W = a.size() == (u32)8 ? (u32)1 : (u32)0;
            i32 bb = b.kind() == (u32)OP_REG ? (i32)b.reg() : b.rmReg();
            i32 xx = b.kind() == (u32)OP_REG ? (i32)0 : b.index();
            if (bb < (i32)0) bb = (i32)0;
            if (xx < (i32)0) xx = (i32)0;
            u32 rhi = (a.reg() & (u32)8) != (u32)0 ? (u32)0 : (u32)$80;
            if (W == (u32)0 && (xx & (i32)8) == (i32)0 && (bb & (i32)8) == (i32)0)
                {
                e8((u32)$C5);
                e8(rhi | ((u32)$0F << (u32)3) | tpp);
                }
            else
                {
                e8((u32)$C4);
                e8(rhi | ((xx & (i32)8) != (i32)0 ? (u32)0 : (u32)$40) | ((bb & (i32)8) != (i32)0 ? (u32)0 : (u32)$20) | (u32)1);
                e8((W << (u32)7) | ((u32)$0F << (u32)3) | tpp);
                }
            e8((u32)$2C);
            eModRM(a.reg(), b);
            _hit = true;
            return true;
            }
        if (map != (u32)0 && _ops.count() == (u32)2 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            bool store = a.kind() == (u32)OP_MEM && st != (u32)0;
            // Register to register from a high source into a low destination:
            // the store opcode puts the source in ModRM.reg, where VEX.R reaches
            // it, so the two-byte prefix still fits. clang picks the same form.
            if (!store && st != (u32)0 && a.kind() == (u32)OP_REG && b.kind() == (u32)OP_REG
                && (b.reg() & (u32)8) != (u32)0 && (a.reg() & (u32)8) == (u32)0)
                store = true;
            XOperand* regop = store ? b : a;
            XOperand* rmop = store ? a : b;
            u32 L = (a.size() == (u32)32 || b.size() == (u32)32) ? (u32)4 : (u32)0;
            if (bcast)
                L = a.size() == (u32)32 ? (u32)4 : (u32)0;
            i32 bb = rmop.kind() == (u32)OP_REG ? (i32)rmop.reg() : rmop.rmReg();
            i32 xx = rmop.kind() == (u32)OP_REG ? (i32)0 : rmop.index();
            if (bb < (i32)0) bb = (i32)0;
            if (xx < (i32)0) xx = (i32)0;
            eVex(regop.reg(), xx, bb, map, (u32)$0F, L, pp);
            e8(store ? st : ld);
            eModRM(regop.reg(), rmop);
            _hit = true;
            return true;
            }
        if (mc == x86Vcvtps2ph && _ops.count() == 3 && a != (XOperand*)0 && b != (XOperand*)0
            && b.kind() == (u32)OP_REG && b.size() == 16)
            {
            // F16C, VEX.128.66.0F3A.W0 1D /r ib: reg = the xmm source, r/m =
            // the destination, the immediate the rounding control. As the
            // reference.
            XOperand* im = (XOperand*)_ops.get(2);
            if (im.kind() == (u32)OP_IMM)
                {
                i32 bb = a.kind() == (u32)OP_REG ? (i32)a.reg() : a.rmReg();
                i32 xx = a.kind() == (u32)OP_REG ? 0 : a.index();
                if (bb < 0) bb = 0;
                if (xx < 0) xx = 0;
                eVex(b.reg(), xx, bb, 3, $0F, 0, 1);
                e8($1D);
                eModRM(b.reg(), a);
                e8((u32)im.disp() & $FF);
                _hit = true;
                return true;
                }
            }
        bool exti = mc == x86Vextracti128;
        bool extf = mc == x86Vextractf128;
        if ((exti || extf) && _ops.count() == (u32)3 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            XOperand* im = (XOperand*)_ops.get((u32)2);
            if (im.kind() == (u32)OP_IMM)
                {
                i32 bb = a.kind() == (u32)OP_REG ? (i32)a.reg() : a.rmReg();
                i32 xx = a.kind() == (u32)OP_REG ? (i32)0 : a.index();
                if (bb < (i32)0) bb = (i32)0;
                if (xx < (i32)0) xx = (i32)0;
                eVex(b.reg(), xx, bb, (u32)3, (u32)$0F, (u32)4, (u32)1);
                e8(exti ? (u32)$39 : (u32)$19);
                eModRM(b.reg(), a);
                e8((u32)im.disp() & (u32)$FF);
                _hit = true;
                return true;
                }
            }
        if (mc == x86Vpshufd && _ops.count() == 3 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            XOperand* im = (XOperand*)_ops.get((u32)2);
            if (im.kind() == (u32)OP_IMM)
                {
                u32 L = a.size() == (u32)32 ? (u32)4 : (u32)0;
                i32 bb = b.kind() == (u32)OP_REG ? (i32)b.reg() : b.rmReg();
                i32 xx = b.kind() == (u32)OP_REG ? (i32)0 : b.index();
                if (bb < (i32)0) bb = (i32)0;
                if (xx < (i32)0) xx = (i32)0;
                eVex(a.reg(), xx, bb, (u32)1, (u32)$0F, L, (u32)1);
                e8((u32)$70);
                eModRM(a.reg(), b);
                e8((u32)im.disp() & (u32)$FF);
                _hit = true;
                return true;
                }
            }
        if (mc == x86Vshufps && _ops.count() == 4 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            XOperand* s2 = (XOperand*)_ops.get((u32)2);
            XOperand* im = (XOperand*)_ops.get((u32)3);
            if (s2.kind() != (u32)OP_IMM && im.kind() == (u32)OP_IMM)
                {
                u32 L = (a.size() == (u32)32 || b.size() == (u32)32) ? (u32)4 : (u32)0;
                i32 bb = s2.kind() == (u32)OP_REG ? (i32)s2.reg() : s2.rmReg();
                i32 xx = s2.kind() == (u32)OP_REG ? (i32)0 : s2.index();
                if (bb < (i32)0) bb = (i32)0;
                if (xx < (i32)0) xx = (i32)0;
                eVex(a.reg(), xx, bb, (u32)1, (~b.reg()) & (u32)$0F, L, (u32)0);
                e8((u32)$C6);
                eModRM(a.reg(), s2);
                e8((u32)im.disp() & (u32)$FF);
                _hit = true;
                return true;
                }
            }
        // vpblendd dst, src1, src2/m, imm8: VEX.66.0F3A.W0 02 (AVX2), the
        // same operand shape as vshufps. VMulHi's AVX2 merge.
        if (mc == x86Vpblendd && _ops.count() == 4 && a != (XOperand*)0 && b != (XOperand*)0)
            {
            XOperand* s2 = (XOperand*)_ops.get((u32)2);
            XOperand* im = (XOperand*)_ops.get((u32)3);
            if (s2.kind() != (u32)OP_IMM && im.kind() == (u32)OP_IMM)
                {
                u32 L = (a.size() == (u32)32 || b.size() == (u32)32) ? (u32)4 : (u32)0;
                i32 bb = s2.kind() == (u32)OP_REG ? (i32)s2.reg() : s2.rmReg();
                i32 xx = s2.kind() == (u32)OP_REG ? (i32)0 : s2.index();
                if (bb < (i32)0) bb = (i32)0;
                if (xx < (i32)0) xx = (i32)0;
                eVex(a.reg(), xx, bb, (u32)3, (~b.reg()) & (u32)$0F, L, (u32)1);
                e8((u32)$02);
                eModRM(a.reg(), s2);
                e8((u32)im.disp() & (u32)$FF);
                _hit = true;
                return true;
                }
            }
        // vpsrl/vpsra/vpsll by an immediate: opcode and /ext
        u32 sop = (u32)0; u32 sext = (u32)0;
        if (mc == x86Vpsrlw) { sop = $71; sext = 2; }
        else if (mc == x86Vpsraw) { sop = $71; sext = 4; }
        else if (mc == x86Vpsllw) { sop = $71; sext = 6; }
        else if (mc == x86Vpsrld) { sop = $72; sext = 2; }
        else if (mc == x86Vpsrad) { sop = $72; sext = 4; }
        else if (mc == x86Vpslld) { sop = $72; sext = 6; }
        else if (mc == x86Vpsrlq) { sop = $73; sext = 2; }
        else if (mc == x86Vpsllq) { sop = $73; sext = 6; }
        if (sop != (u32)0 && _ops.count() == (u32)3 && a != (XOperand*)0 && b != (XOperand*)0
            && b.kind() == (u32)OP_REG)
            {
            XOperand* im = (XOperand*)_ops.get((u32)2);
            if (im.kind() == (u32)OP_IMM)
                {
                u32 L = a.size() == (u32)32 ? (u32)4 : (u32)0;
                eVex((u32)0, (i32)0, (i32)b.reg(), (u32)1, (~a.reg()) & (u32)$0F, L, (u32)1);
                e8(sop);
                e8((u32)$C0 | (sext << (u32)3) | (b.reg() & (u32)7));
                e8((u32)im.disp() & (u32)$FF);
                _hit = true;
                return true;
                }
            }
        return false;
        }

    static bool vexCommutes(u16 mc)
        {
        return mc == x86Addps || mc == x86Addpd
            || mc == x86Addss || mc == x86Addsd
            || mc == x86Mulps || mc == x86Mulpd
            || mc == x86Mulss || mc == x86Mulsd
            || mc == x86Andps || mc == x86Andpd
            || mc == x86Orps  || mc == x86Orpd
            || mc == x86Xorps || mc == x86Xorpd
            || mc == x86Pand  || mc == x86Por
            || mc == x86Pxor  || mc == x86Paddb
            || mc == x86Paddw || mc == x86Paddd
            || mc == x86Paddq
            || mc == x86Pmuludq
            || mc == x86Pmullw
            || mc == x86Pcmpeqb
            || mc == x86Pcmpeqw
            || mc == x86Pcmpeqd
            || mc == x86Pmaxsw
            || mc == x86Pminsw
            || mc == x86Pmaxub
            || mc == x86Pminub;
        }

    void encGroupD(String* mn, u16 mc, XOperand* a, XOperand* b)
        {
        if (encEvex(mn, a, b))
            return;
        if (encAvx(mn, mc, a, b))
            return;
        if (encVex128(mn, a))
            return;
        u32 rr = sseRR(mc);
        // b must NOT be an immediate. Four of these mnemonics (psrlw/psrld/
        // psrlq and psllq) ALSO have a shift-by-immediate form, handled below
        // out of its own table because the operands sit in the opposite ModRM
        // fields. Without this test `psrld xmm2, 2` matched here and eModRM
        // encoded the literal 2 as if it were a register operand: a silently
        // WRONG encoding that disassembled as garbage and segfaulted, rather
        // than a refusal.
        if (rr != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() != (u32)OP_IMM)
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
        u32 t3 = sse38(mc);
        if (t3 != (u32)$FFFF_FFFF && a != (XOperand*)0 && b != (XOperand*)0 && b.kind() != (u32)OP_IMM)
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
        u32 si = sseShiftI(mc);
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
        if ((mc == x86Shufps || mc == x86Shufpd) && a != (XOperand*)0 && b != (XOperand*)0 && opAt(2) != (XOperand*)0 && opAt(2).kind() == OP_IMM)
            {
            if (mc == x86Shufpd)
                e8((u32)$66);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$C6);
            eModRM(a.reg(), b);
            e8((u32)opAt((u32)2).imm() & (u32)$FF);
            _hit = true;
            return;
            }
        // cmpps/cmppd xmm, xmm/m, imm8 — the same shape, opcode C2; the imm8 is
        // the predicate (3 = unordered: a lane holding a NaN).
        if ((mc == x86Cmpps || mc == x86Cmppd) && a != (XOperand*)0 && b != (XOperand*)0 && opAt(2) != (XOperand*)0 && opAt(2).kind() == OP_IMM)
            {
            if (mc == x86Cmppd)
                e8((u32)$66);
            eRex(false, (i32)a.reg(), b.index(), b.rmReg(), false);
            e8((u32)$0F);
            e8((u32)$C2);
            eModRM(a.reg(), b);
            e8((u32)opAt((u32)2).imm() & (u32)$FF);
            _hit = true;
            return;
            }
        // movss/movsd/movdqu/movdqa — the direction picks load or store.
        u32 mv = sseMov(mc);
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
        u32 cv = sseCvt(mc);
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
        u32 shp = sseShuf(mc);
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
        if (mc == x86Pmulld && a != (XOperand*)0 && b != (XOperand*)0)
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
        bool isMovd = mc == x86Movd;
        if ((isMovd || mc == x86Movq) && a != (XOperand*)0 && b != (XOperand*)0 && (a.size() == 16 || b.size() == 16))
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
    static u32 sseRR(u16 mc)
        {
        if (mc == x86Addss)
            return (u32)$F358;
        if (mc == x86Addsd)
            return (u32)$F258;
        if (mc == x86Subss)
            return (u32)$F35C;
        if (mc == x86Subsd)
            return (u32)$F25C;
        if (mc == x86Subpd)
            return (u32)$665C;
        if (mc == x86Subps)
            return (u32)$005C;
        if (mc == x86Addpd)
            return (u32)$6658;
        if (mc == x86Addps)
            return (u32)$0058;
        if (mc == x86Mulpd)
            return (u32)$6659;
        if (mc == x86Mulps)
            return (u32)$0059;
        if (mc == x86Divpd)
            return (u32)$665E;
        if (mc == x86Divps)
            return (u32)$005E;
        if (mc == x86Mulss)
            return (u32)$F359;
        if (mc == x86Mulsd)
            return (u32)$F259;
        if (mc == x86Divss)
            return (u32)$F35E;
        if (mc == x86Divsd)
            return (u32)$F25E;
        if (mc == x86Sqrtss)
            return (u32)$F351;
        if (mc == x86Sqrtsd)
            return (u32)$F251;
        if (mc == x86Sqrtps)
            return (u32)$0051;
        if (mc == x86Sqrtpd)
            return (u32)$6651;
        if (mc == x86Ucomiss)
            return (u32)$002E;
        if (mc == x86Ucomisd)
            return (u32)$662E;
        if (mc == x86Comiss)
            return (u32)$002F;
        if (mc == x86Comisd)
            return (u32)$662F;
        if (mc == x86Cvtss2sd)
            return (u32)$F35A;
        if (mc == x86Cvtsd2ss)
            return (u32)$F25A;
        if (mc == x86Xorps)
            return (u32)$0057;
        if (mc == x86Xorpd)
            return (u32)$6657;
        if (mc == x86Andps)
            return (u32)$0054;
        if (mc == x86Andpd)
            return (u32)$6654;
        if (mc == x86Andnps)
            return (u32)$0055;
        if (mc == x86Andnpd)
            return (u32)$6655;
        if (mc == x86Orps)
            return (u32)$0056;
        if (mc == x86Orpd)
            return (u32)$6656;
        if (mc == x86Unpcklpd)
            return (u32)$6614;
        if (mc == x86Unpcklps)
            return (u32)$0014;
        if (mc == x86Unpckhpd)
            return (u32)$6615;
        if (mc == x86Unpckhps)
            return (u32)$0015;
        if (mc == x86Paddd)
            return (u32)$66FE;
        if (mc == x86Paddw)
            return (u32)$66FD;
        if (mc == x86Paddb)
            return (u32)$66FC;
        if (mc == x86Paddq)
            return (u32)$66D4;
        if (mc == x86Psubd)
            return (u32)$66FA;
        if (mc == x86Psubw)
            return (u32)$66F9;
        if (mc == x86Maxsd)
            return (u32)$F25F;
        if (mc == x86Maxss)
            return (u32)$F35F;
        if (mc == x86Minsd)
            return (u32)$F25D;
        if (mc == x86Minss)
            return (u32)$F35D;
        if (mc == x86Maxpd)
            return (u32)$665F;
        if (mc == x86Maxps)
            return (u32)$005F;
        if (mc == x86Minpd)
            return (u32)$665D;
        if (mc == x86Minps)
            return (u32)$005D;
        if (mc == x86Cvttpd2dq)
            return (u32)$66E6;
        if (mc == x86Cvtdq2pd)
            return (u32)$F3E6;
        if (mc == x86Cvttps2dq)
            return (u32)$F35B;
        if (mc == x86Cvtdq2ps)
            return (u32)$005B;
        if (mc == x86Cvtps2pd)
            return (u32)$005A;
        if (mc == x86Cvtpd2ps)
            return (u32)$665A;
        if (mc == x86Punpckldq)
            return (u32)$6662;
        if (mc == x86Punpcklqdq)
            return (u32)$666C;
        if (mc == x86Pand)
            return (u32)$66DB;
        // VBsl's select below 64 bytes: ~mask & b (#27).
        if (mc == x86Pandn)
            return (u32)$66DF;
        if (mc == x86Por)
            return (u32)$66EB;
        if (mc == x86Pxor)
            return (u32)$66EF;
        if (mc == x86Psrld)
            return (u32)$66D2;
        if (mc == x86Pslld)
            return (u32)$66F2;
        if (mc == x86Psrlq)
            return (u32)$66D3;
        if (mc == x86Psllq)
            return (u32)$66F3;
        // The vectoriser's widening-sum / dot-product reductions reach these;
        // absent until bug 029.
        if (mc == x86Pcmpeqd)
            return (u32)$6676;
        if (mc == x86Pcmpgtd)
            return (u32)$6666;
        // The BYTE and WORD lane widths of the same two compares. Only the
        // dword forms existed, so the back end emitted a dword compare for
        // byte lanes and string_scan counted zero matches instead of 64
        // (bug 223).
        if (mc == x86Pcmpeqb)
            return (u32)$6674;
        if (mc == x86Pcmpgtb)
            return (u32)$6664;
        if (mc == x86Pcmpeqw)
            return (u32)$6675;
        if (mc == x86Pcmpgtw)
            return (u32)$6665;
        if (mc == x86Pmaddwd)
            return (u32)$66F5;
        if (mc == x86Punpcklbw)
            return (u32)$6660;
        // The i16 multiply a widening product lowers to (vectorize_dot,
        // vectorize_widen_tail).
        if (mc == x86Pmullw)
            return (u32)$66D5;
        // The SSE2 word / byte lane min and max (16-bit signed, 8-bit
        // unsigned); the other widths and signs are SSE4.1, in VEX's 0F38 map.
        if (mc == x86Pmaxsw)
            return (u32)$66EE;
        if (mc == x86Pminsw)
            return (u32)$66EA;
        if (mc == x86Pmaxub)
            return (u32)$66DE;
        if (mc == x86Pminub)
            return (u32)$66DA;
        // The unsigned 32x32 -> 64 lane product over lanes 0 and 2. SSE2 has no
        // other widening integer multiply, and it is what the VMulHi sequence
        // is built from.
        if (mc == x86Pmuludq)
            return (u32)$66F4;
        return (u32)$FFFF_FFFF;
        }

    // SSSE3 three-byte opcodes: [66][REX][0F][38][op][ModRM]. Same operand
    // shape as sseRR with one more opcode byte.
    static u32 sse38(u16 mc)
        {
        if (mc == x86Pabsb)
            return (u32)$661C;
        if (mc == x86Pabsw)
            return (u32)$661D;
        if (mc == x86Pabsd)
            return (u32)$661E;
        if (mc == x86Phaddw)
            return (u32)$6601;
        if (mc == x86Phaddd)
            return (u32)$6602;
        if (mc == x86Pmaddubsw)
            return (u32)$6604;
        // SSE4.1: the signed i32 lane max/min, which is what a `max` reduction
        // over i32 lowers to (vectorize_maxmin).
        if (mc == x86Pmaxsd)
            return (u32)$663D;
        if (mc == x86Pminsd)
            return (u32)$6639;
        return (u32)$FFFF_FFFF;
        }

    // Shift a vector by an IMMEDIATE: [66][REX][0F][op][ModRM /ext][ib]. The
    // shifted register goes in r/m and the opcode extension in reg — the
    // reverse of every other form here, so it cannot share their table.
    // Packed as (opcode << 8) | ext.
    static u32 sseShiftI(u16 mc)
        {
        if (mc == x86Psrlw)
            return (u32)$7102;
        if (mc == x86Psraw)
            return (u32)$7104;
        if (mc == x86Psllw)
            return (u32)$7106;
        // These four were MISSING and the fifth was spelled `psrldi`, which is
        // not an instruction. Nothing emitted a lane shift by an immediate on
        // x86 until VLShr and VMulHi landed, so the table was never exercised:
        // the reference assembler had all eight and this one had three and a
        // typo. asx86-diff compares assembled BYTES for the fixtures that
        // exist, so a mnemonic nobody emits is untested on BOTH sides.
        if (mc == x86Psrld)
            return (u32)$7202;
        if (mc == x86Psrad)
            return (u32)$7204;
        if (mc == x86Pslld)
            return (u32)$7206;
        if (mc == x86Psrlq)
            return (u32)$7302;
        if (mc == x86Psllq)
            return (u32)$7306;
        return (u32)$FFFF_FFFF;
        }

    // Packed as (prefix << 16) | (loadOp << 8) | storeOp.
    static u32 sseMov(u16 mc)
        {
        if (mc == x86Movss)
            return (u32)$F31011;
        if (mc == x86Movsd)
            return (u32)$F21011;
        if (mc == x86Movups)
            return (u32)$001011;
        if (mc == x86Movaps)
            return (u32)$002829;
        if (mc == x86Movdqu)
            return (u32)$F36F7F;
        if (mc == x86Movdqa)
            return (u32)$666F7F;
        if (mc == x86Movupd)
            return (u32)$661011;
        if (mc == x86Movapd)
            return (u32)$662829;
        return (u32)$FFFF_FFFF;
        }

    // Packed as (gpIsSrc << 16) | (prefix << 8) | opcode.
    static u32 sseCvt(u16 mc)
        {
        if (mc == x86Cvtsi2ss)
            return (u32)$01F32A;
        if (mc == x86Cvtsi2sd)
            return (u32)$01F22A;
        if (mc == x86Cvttss2si)
            return (u32)$00F32C;
        if (mc == x86Cvttsd2si)
            return (u32)$00F22C;
        if (mc == x86Cvtss2si)
            return (u32)$00F32D;
        if (mc == x86Cvtsd2si)
            return (u32)$00F22D;
        return (u32)$FFFF_FFFF;
        }

    static u32 sseShuf(u16 mc)
        {
        if (mc == x86Pshufd)
            return (u32)$66;
        if (mc == x86Pshuflw)
            return (u32)$F2;
        if (mc == x86Pshufhw)
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
            if (inq && c == (u8)'\\')
                {
                i = i + (u32)1; // \" stays inside the string
                continue;
                }
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
        _dwarf = (DwarfWriter*)0;
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
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(_text.length()));
                else if (section == (u32)2)
                    {
                    // bss-relative for now; rebased after the pass (bug 642)
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(_bss.length()));
                    _bssLabels.add((Object*)lbl);
                    }
                else
                    {
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(_data.length()));
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
            _insnBase = _text.length();
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
                _text.appendByte((u8)((Number*)bytes.get(i)).asU32());
            // -g: rbp now addresses the saved rbp and the return address above
            // it, so the call frame is rbp + 16 from here.
            if (l.hasPrefix(String.withCString("mov")) && l.hasSuffix(String.withCString("rbp, rsp")))
                {
                if (_dwarf == (DwarfWriter*)0)
                    _dwarf = new DwarfWriter();
                _dwarf.addFrameSetup(_text.length(), (u32)16);
                }
            }
        // The functions' exception tables, every label placed.
        _lsdaLines = _lsdaRaw;
        _lsdaSyms = _symbols;
        if (_dwarf != (DwarfWriter*)0 && (_dwarf.hasRows() || _dwarf.hasSaves()))
            DwarfWriter.setPending(_dwarf);
        // The bss, after all the data (bug 642): its labels become data symbols
        // at their final offsets. Before the branch resolution, which must see
        // them as data. Mirrors the reference assembler.
        if (_bss.length() > (u32)0)
            {
            // At the largest alignment inside it, so a 16 KB-aligned array
            // (gpu-globals) keeps its alignment once appended.
            _data.padTo(_bssAlign);
            u32 base = _data.length();
            _data.append(_bss);
            for (u32 i = (u32)0; i < _bssLabels.count(); i = i + (u32)1)
                {
                String* lbl = (String*)_bssLabels.get(i);
                u32 off = ((Number*)_symbols.get((Hashable*)lbl)).asU32();
                _symbols.set((Hashable*)lbl, (Object*)Number.withU32(base + off));
                _dataSyms.add((Object*)lbl);
                }
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
        if (d.equals(String.withCString(".data")))
            return (u32)1;
        if (d.equals(String.withCString(".bss")))
            return (u32)2;
        // -g: `.file <n> "<path>"` and `.loc <n> <line> [<col>]` are the line
        // table, recorded against the text offset they precede.
        // -g: `.xc_var "<name>" <reg> <offset> "<type>"` (`.xc_param` for a
        // parameter) — a variable of the function being assembled.
        // win64 unwind entries (C/C++ input), as GNU as spells them: each
        // prologue step at the offset it ends, for Pe's .pdata/.xdata.
        if (d.hasPrefix(String.withCString(".xc_lsda_")))
            {
            if (d.equals(String.withCString(".xc_lsda_begin"))) _lsdaCur = new Array();
            if (_lsdaCur != (Array*)0) _lsdaCur.add((Object*)l);
            if (d.equals(String.withCString(".xc_lsda_end")) && _lsdaCur != (Array*)0)
                {
                _lsdaRaw.add((Object*)_lsdaCur);
                _lsdaCur = (Array*)0;
                }
            return section;
            }
        if (d.hasPrefix(String.withCString(".seh_")))
            {
            u32 here = _text.length();
            if (d.equals(String.withCString(".seh_proc")))
                {
                _sehCur = new Array();
                _sehCur.add((Object*)rest);
                _sehCur.add((Object*)Number.withU32(here));
                _sehCur.add((Object*)Number.withU32((u32)0));
                _sehCur.add((Object*)Number.withU32(here));
                _sehCur.add((Object*)new Array());
                return section;
                }
            if (_sehCur == (Array*)0)
                return section;
            u32 at = here - ((Number*)_sehCur.get((u32)1)).asU32();
            Array* codes = (Array*)_sehCur.get((u32)4);
            Array* ops = rest.splitOnByte((u8)',');
            String* r0 = ops.count() > (u32)0 ? ((String*)ops.get((u32)0)).trimmed() : String.withCString("");
            u32 v = (u32)0;
            if (ops.count() > (u32)1)
                {
                String* vs = ((String*)ops.get((u32)1)).trimmed();
                for (u32 k = (u32)0; k < vs.byteLength(); k = k + (u32)1)
                    v = v * (u32)10 + (u32)(vs.byteAt(k) - (u8)'0');
                }
            u32 op = (u32)$FFFF;
            u32 reg = (u32)0;
            if (d.equals(String.withCString(".seh_pushreg"))) { op = (u32)0; reg = X86Asm.sehRegister(r0); }
            else if (d.equals(String.withCString(".seh_stackalloc")))
                {
                op = (u32)1;
                for (u32 k = (u32)0; k < r0.byteLength(); k = k + (u32)1)
                    v = v * (u32)10 + (u32)(r0.byteAt(k) - (u8)'0');
                }
            else if (d.equals(String.withCString(".seh_savereg"))) { op = (u32)4; reg = X86Asm.sehRegister(r0); }
            else if (d.equals(String.withCString(".seh_savexmm"))) { op = (u32)8; reg = X86Asm.sehRegister(r0); }
            else if (d.equals(String.withCString(".seh_endprologue")))
                _sehCur.set((u32)2, (Object*)Number.withU32(at));
            else if (d.equals(String.withCString(".seh_endproc")))
                {
                _sehCur.set((u32)3, (Object*)Number.withU32(here));
                _seh.add((Object*)_sehCur);
                _sehCur = (Array*)0;
                }
            if (op != (u32)$FFFF)
                {
                codes.add((Object*)Number.withU32(at));
                codes.add((Object*)Number.withU32(op));
                codes.add((Object*)Number.withU32(reg));
                codes.add((Object*)Number.withU32(v));
                }
            return section;
            }
        // `.xc_saves <reg>:<cfa offset> ...` (C/C++ input): where the frame
        // just set up keeps rbp, the return address and each callee-saved
        // register, for the unwind tables.
        if (d.equals(String.withCString(".xc_saves")))
            {
            if (_dwarf != (DwarfWriter*)0)
                _dwarf.addSaves(rest.trimmed());
            return section;
            }
        if (d.equals(String.withCString(".xc_var")) || d.equals(String.withCString(".xc_param")))
            {
            _dwarf = DwarfWriter.variableDirective(_dwarf, rest, d.equals(String.withCString(".xc_param")),
                                                   _text.length());
            return section;
            }
        if (d.equals(String.withCString(".file")) || d.equals(String.withCString(".loc")))
            {
            _dwarf = DwarfWriter.directive(_dwarf, rest, (u32)0, d.equals(String.withCString(".file")),
                                           section == (u32)0, _text.length());
            return section;
            }
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
            return rest.hasPrefix(String.withCString(".text")) ? (u32)0
                 : (rest.hasPrefix(String.withCString(".bss")) ? (u32)2 : (u32)1);
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
                _data.padTo((u32)alg);
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_data.length()));
            _dataSyms.add((Object*)nm);
            if (sz > (i32)0)
                _data.appendZeros((u32)sz);
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
                emitNops(_text, (al - _text.length() % al) % al);
            else if (section == (u32)2)
                {
                _bss.padTo(al);
                if (al > _bssAlign)
                    _bssAlign = al;
                }
            else
                _data.padTo(al);
            return section;
            }

        return handleDataDirective(d, rest, l, section);
        }

    // Code padding as multi-byte NOPs (the recommended 0F 1F forms, at most
    // 10 bytes each, as assemblers use for generic x86-64): padding that
    // execution falls into then costs one instruction per 10 bytes, not one
    // per byte (#41). As the reference's emitNops.
    static void emitNops(SectionBytes* t, u32 n)
        {
        while (n > (u32)0)
            {
            u32 k = n > (u32)10 ? (u32)10 : n;
            if (k == (u32)2 || k == (u32)6 || k >= (u32)9)
                t.appendByte((u8)$66);
            if (k == (u32)10)
                t.appendByte((u8)$2E);
            if (k == (u32)1 || k == (u32)2)
                t.appendByte((u8)$90);
            else
                {
                t.appendByte((u8)$0F);
                t.appendByte((u8)$1F);
                // ModRM: [rax] (3), [rax+d8] (4), [rax+rax+d8] (5, 6),
                // [rax+d32] (7), [rax+rax+d32] (8-10).
                u32 core = k == (u32)6 || k >= (u32)9 ? k - (k == (u32)10 ? (u32)2 : (u32)1) : k;
                if (core == (u32)3)
                    t.appendByte((u8)$00);
                else if (core == (u32)4)
                    { t.appendByte((u8)$40); t.appendByte((u8)$00); }
                else if (core == (u32)5)
                    { t.appendByte((u8)$44); t.appendByte((u8)$00); t.appendByte((u8)$00); }
                else if (core == (u32)7)
                    { t.appendByte((u8)$80); t.appendZeros((u32)4); }
                else
                    { t.appendByte((u8)$84); t.appendByte((u8)$00); t.appendZeros((u32)4); }
                }
            n = n - k;
            }
        }

    // Split out purely for the arm64 frame budget: a chain of literal
    // comparisons builds more temporaries than one frame can hold.
    u32 handleDataDirective(String* d, String* rest, String* l, u32 section)
        {
        SectionBytes* sec = section == (u32)0 ? _text : (section == (u32)2 ? _bss : _data);
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
            if (((u32)fill & (u32)$FF) == (u32)0)
                {
                if (n > (i32)0)
                    sec.appendZeros((u32)n);
                }
            else
                for (i32 i = (i32)0; i < n; i = i + (i32)1)
                    sec.appendByte((u8)((u32)fill & (u32)$FF));
            return section;
            }
        if (d.equals(String.withCString(".ascii")) || d.equals(String.withCString(".asciz")) || d.equals(String.withCString(".string")))
            {
            Data* bytes = GasString.decode(rest, !d.equals(String.withCString(".ascii")));
            if (bytes == (Data*)0)
                {
                failWith(String.withCString("bad string in"), l);
                return section;
                }
            sec.appendData(bytes);
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
                if (section != (u32)1)
                    {
                    failWith(String.withCString("a symbolic .quad is only supported in data"), l);
                    return section;
                    }
                _fixups.add((Object*)X86Fixup.make(sec.length(), (u32)X86FIX_ABS64, t, (i32)0));
                sec.appendZeros((u32)8);
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
                sec.appendByte((u8)byte);
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

    // A call or jcc to a label in this same text needs no relocation, so it is
    // resolved here rather than left for every consumer to re-derive.
    // Everything else — data references, imports, .quad pointers — needs final
    // addresses and stays a fixup.
    void resolveLocalBranches(void)
        {
        Array* unresolved = new Array();
        // The data symbols as a set (#335): a scan per fixup made this
        // O(fixups x data symbols).
        Map* dataSet = new Map();
        for (u32 k = (u32)0; k < _dataSyms.count(); k = k + (u32)1)
            dataSet.set((Hashable*)_dataSyms.get(k), _dataSyms.get(k));
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            Object* target = _symbols.get((Hashable*)f.symbol());
            bool isData = dataSet.get((Hashable*)f.symbol()) != (Object*)0;
            if (f.kind() == (u32)X86FIX_REL32 && target != (Object*)0 && !isData)
                {
                i32 rel = (i32)((Number*)target).asU32() - (i32)f.offset() + f.addend();
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    _text.setByteAt(f.offset() + k, (u8)(((u32)rel >> ((u32)8 * k)) & (u32)$FF));
                continue;
                }
            unresolved.add((Object*)f);
            }
        _fixups = unresolved;
        }
    }
