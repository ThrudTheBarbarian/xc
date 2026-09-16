// Arm32.xc — the assembly this compiler emits, as ARM machine code.
// =========================================================================
//
// self-hosting M10. There is no ARM32 assembler anywhere in this project: the
// arm9 path shells out to `arm-none-eabi-gcc`, which is fine on a development
// host and impossible on the device — the Cortex-A9 has no gcc. So the last
// gap between "the compiler runs on the A9" and "the A9 builds programs" is
// this: turn the `.s` the back end emits into bytes.
//
// It assembles the SUBSET the back end emits, not ARM in general. That is the
// whole reason it is tractable: about forty mnemonics, one addressing mode
// family, and a literal pool. Anything outside the subset is reported BY NAME
// rather than skipped — an assembler that quietly drops an instruction
// produces an object that links and crashes.
//
// The oracle is `arm-none-eabi-as`: assemble the same file both ways and
// compare the `.text` bytes. Every `.s` the back end can emit is a test case,
// which is the same free-oracle trick the rest of the port runs on.
//
// A32 encoding, for the forms used here (bit 31-28 = condition, 0b1110 = al):
//
//   data processing   cond 00 I opcode S Rn Rd operand2
//   movw/movt         cond 0011 0x00 imm4 Rd imm12
//   load/store        cond 01 I P U B W L Rn Rd offset12
//   branch            cond 101 L imm24 (signed, words, PC-relative +8)
//   push/pop          cond 100 P U S W L Rn register_list

#import "Foundation.xc"

// One entry in the object's symbol table.
class AsmSymbol
    {
    String* _name;
    u32 _section; // 0 = undefined, 1 = .text, 2 = .data, 3 = COMMON
    u32 _value;   // offset within the section (or size, for COMMON)
    u32 _size;
    bool _isGlobal;
    bool _isFunction;
    bool _hidden;

    void init(void)
        {
        _section = (u32)0;
        _value = (u32)0;
        _size = (u32)0;
        }

    static AsmSymbol* named(String* n)
        {
        AsmSymbol* s = new AsmSymbol();
        s._name = n;
        return s;
        }

    String* name(void)
        {
        return _name;
        }
    u32 section(void)
        {
        return _section;
        }
    u32 value(void)
        {
        return _value;
        }
    u32 size(void)
        {
        return _size;
        }
    bool isGlobal(void)
        {
        return _isGlobal;
        }
    bool isFunction(void)
        {
        return _isFunction;
        }
    bool hidden(void)
        {
        return _hidden;
        }
    void setSection(u32 v)
        {
        _section = v;
        }
    void setValue(u32 v)
        {
        _value = v;
        }
    void setSize(u32 v)
        {
        _size = v;
        }
    void setGlobal(void)
        {
        _isGlobal = true;
        }
    void setFunction(void)
        {
        _isFunction = true;
        }
    void setHidden(void)
        {
        _hidden = true;
        }
    }

    // One relocation: patch `offset` in `section` against `symbol`.
    class AsmReloc
    {
    u32 _section; // 1 = .text, 2 = .data
    u32 _offset;
    String* _symbol;
    u32 _type; // R_ARM_*

    void init(void)
        {
        }
    static AsmReloc* with(u32 sec, u32 off, String* sym, u32 ty)
        {
        AsmReloc* r = new AsmReloc();
        r._section = sec;
        r._offset = off;
        r._symbol = sym;
        r._type = ty;
        return r;
        }
    u32 section(void)
        {
        return _section;
        }
    u32 offset(void)
        {
        return _offset;
        }
    String* symbol(void)
        {
        return _symbol;
        }
    u32 type(void)
        {
        return _type;
        }
    }

#define R_ARM_ABS32 $02
#define R_ARM_CALL $1C

    class Arm32
    {
    Array* _bytes;     // Number@ per emitted byte — the .text payload
    Array* _data;      // …and the .data one
    Array* _syms;      // AsmSymbol@
    Array* _relocs;    // AsmReloc@
    Array* _pool;      // symbols pending a literal-pool word
    Array* _poolSites; // …and the instruction offset each was loaded by
    u32 _section;      // 1 = .text, 2 = .data
    Array* _missing;   // mnemonics outside the subset
    bool _failed;
    String* _why;

    void init(void)
        {
        }

    Array* bytes(void)
        {
        return _bytes;
        }
    Array* data(void)
        {
        return _data;
        }
    Array* symbols(void)
        {
        return _syms;
        }
    Array* relocations(void)
        {
        return _relocs;
        }
    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }
    Array* missing(void)
        {
        return _missing;
        }

    void giveUp(String* what)
        {
        if (_missing == 0)
            _missing = new Array();
        for (u32 i = (u32)0; i < _missing.count(); i = i + (u32)1)
            if (((String*)_missing.get(i)).equals(what))
                return;
        _missing.add((Object*)what);
        if (_failed)
            return;
        _failed = true;
        _why = String.withString(what);
        }

    // ── Registers and conditions ─────────────────────────────────────────
    // r0-r15, plus the three names that are register numbers by another
    // spelling: sp is r13, lr r14, pc r15.
    static i32 regNumber(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0)
            return (i32)-1;
        if (t.equals(String.withCString("sp")))
            return (i32)13;
        if (t.equals(String.withCString("lr")))
            return (i32)14;
        if (t.equals(String.withCString("pc")))
            return (i32)15;
        if (t.equals(String.withCString("ip")))
            return (i32)12;
        if (t.byteAt((u32)0) != (u8)'r')
            return (i32)-1;
        u32 v = (u32)0;
        for (u32 i = (u32)1; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (i32)-1;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return v <= (u32)15 ? (i32)v : (i32)-1;
        }

    // The four-bit condition field. `al` (always) is the absence of a suffix.
    static i32 condCode(String* c)
        {
        if (c == 0 || c.byteLength() == (u32)0)
            return (i32)14;
        if (c.equals(String.withCString("eq")))
            return (i32)0;
        if (c.equals(String.withCString("ne")))
            return (i32)1;
        if (c.equals(String.withCString("hs")))
            return (i32)2;
        if (c.equals(String.withCString("cs")))
            return (i32)2;
        if (c.equals(String.withCString("lo")))
            return (i32)3;
        if (c.equals(String.withCString("cc")))
            return (i32)3;
        if (c.equals(String.withCString("mi")))
            return (i32)4;
        if (c.equals(String.withCString("pl")))
            return (i32)5;
        if (c.equals(String.withCString("vs")))
            return (i32)6;
        if (c.equals(String.withCString("vc")))
            return (i32)7;
        if (c.equals(String.withCString("hi")))
            return (i32)8;
        if (c.equals(String.withCString("ls")))
            return (i32)9;
        if (c.equals(String.withCString("ge")))
            return (i32)10;
        if (c.equals(String.withCString("lt")))
            return (i32)11;
        if (c.equals(String.withCString("gt")))
            return (i32)12;
        if (c.equals(String.withCString("le")))
            return (i32)13;
        if (c.equals(String.withCString("al")))
            return (i32)14;
        return (i32)-1;
        }

    // The data-processing opcode field, or -1 for a mnemonic that is not one.
    static i32 dpOpcode(String* m)
        {
        if (m.equals(String.withCString("and")))
            return (i32)0;
        if (m.equals(String.withCString("eor")))
            return (i32)1;
        if (m.equals(String.withCString("sub")))
            return (i32)2;
        if (m.equals(String.withCString("rsb")))
            return (i32)3;
        if (m.equals(String.withCString("add")))
            return (i32)4;
        if (m.equals(String.withCString("adc")))
            return (i32)5;
        if (m.equals(String.withCString("sbc")))
            return (i32)6;
        if (m.equals(String.withCString("rsc")))
            return (i32)7;
        if (m.equals(String.withCString("tst")))
            return (i32)8;
        if (m.equals(String.withCString("teq")))
            return (i32)9;
        if (m.equals(String.withCString("cmp")))
            return (i32)10;
        if (m.equals(String.withCString("cmn")))
            return (i32)11;
        if (m.equals(String.withCString("orr")))
            return (i32)12;
        if (m.equals(String.withCString("mov")))
            return (i32)13;
        if (m.equals(String.withCString("bic")))
            return (i32)14;
        if (m.equals(String.withCString("mvn")))
            return (i32)15;
        return (i32)-1;
        }

    // ── Immediates ───────────────────────────────────────────────────────
    // An ARM data-processing immediate is an 8-bit value rotated RIGHT by an
    // even amount. The encoder must find the rotation; there is no other way
    // to spell a constant in one instruction.
    static i32 encodeImm12(u32 v)
        {
        for (u32 rot = (u32)0; rot < (u32)16; rot = rot + (u32)1)
            {
            u32 sh = rot * (u32)2;
            u32 rotated = sh == (u32)0 ? v : ((v << sh) | (v >> ((u32)32 - sh)));
            if (rotated <= (u32)255)
                return (i32)((rot << 8) | rotated);
            }
        return (i32)-1;
        }

    // ── Emission ─────────────────────────────────────────────────────────
    void word(u32 w)
        {
        if (_bytes == 0)
            _bytes = new Array();
        _bytes.add((Object*)Number.with(w & (u32)$FF));
        _bytes.add((Object*)Number.with((w >> 8) & (u32)$FF));
        _bytes.add((Object*)Number.with((w >> 16) & (u32)$FF));
        _bytes.add((Object*)Number.with((w >> 24) & (u32)$FF));
        }

    u32 here(void)
        {
        return _bytes == 0 ? (u32)0 : _bytes.count();
        }

    // ── Instructions ─────────────────────────────────────────────────────
    // `<op>{cond}{s} Rd, Rn, <operand2>` — the shape most of the subset has.
    // A comparison writes no destination and always sets the flags; a move
    // reads no first operand.
    void dataProcessing(i32 cond, i32 opcode, bool setFlags,
                        u32 rd, u32 rn, i32 imm12, u32 rm, u32 shiftKind, u32 shiftAmt)
        {
        u32 w = ((u32)cond << 28) | ((u32)opcode << 21) | (rn << 16) | (rd << 12);
        if (setFlags)
            w = w | ((u32)1 << 20);
        if (imm12 >= (i32)0)
            w = w | ((u32)1 << 25) | (u32)imm12;
        else
            w = w | (shiftAmt << 7) | (shiftKind << 5) | rm;
        word(w);
        }

    // `movw`/`movt` — a bare 16-bit immediate, split 4 + 12.
    void movImm16(i32 cond, bool top, u32 rd, u32 imm16)
        {
        u32 op = top ? (u32)$34 : (u32)$30;
        word(((u32)cond << 28) | (op << 20) | (((imm16 >> 12) & (u32)$F) << 16) | (rd << 12) | (imm16 & (u32)$FFF));
        }

    // `<ldr|str>{b} Rt, [Rn, #±off]` — the word/byte form, offset12.
    void loadStore(i32 cond, bool load, bool byte, u32 rt, u32 rn, i32 off)
        {
        u32 up = off >= (i32)0 ? (u32)1 : (u32)0;
        u32 mag = off >= (i32)0 ? (u32)off : (u32)(-off);
        u32 w = ((u32)cond << 28) | ((u32)1 << 26) | ((u32)1 << 24) | (up << 23);
        if (byte)
            w = w | ((u32)1 << 22);
        if (load)
            w = w | ((u32)1 << 20);
        word(w | (rn << 16) | (rt << 12) | (mag & (u32)$FFF));
        }

    // The halfword and signed forms are a different encoding entirely: the
    // offset splits 4 + 4 around a fixed nibble.
    void loadStoreHalf(i32 cond, bool load, u32 rt, u32 rn, i32 off,
                       bool signedOp, bool halfword)
        {
        u32 up = off >= (i32)0 ? (u32)1 : (u32)0;
        u32 mag = off >= (i32)0 ? (u32)off : (u32)(-off);
        u32 w = ((u32)cond << 28) | ((u32)1 << 24) | (up << 23) | ((u32)1 << 22);
        if (load)
            w = w | ((u32)1 << 20);
        u32 sh = (u32)1 << 5; // H bit
        if (signedOp)
            sh = sh | ((u32)1 << 6); // S bit
        if (signedOp && !halfword)
            sh = ((u32)1 << 6); // ldrsb: S set, H clear
        word(w | (rn << 16) | (rt << 12) | (((mag >> 4) & (u32)$F) << 8) | (u32)$90 | sh | (mag & (u32)$F));
        }

    // `push`/`pop` are the load/store-multiple forms with sp as the base:
    // push = stmdb sp!, pop = ldmia sp!.
    void pushPop(i32 cond, bool pop, u32 regList)
        {
        u32 w = ((u32)cond << 28) | ((u32)1 << 27) | ((u32)1 << 21) | ((u32)13 << 16);
        if (pop)
            w = w | ((u32)1 << 23) | ((u32)1 << 20); // U (up) + L (load)
        else
            w = w | ((u32)1 << 24); // P (pre-decrement)
        word(w | regList);
        }

    // A branch's immediate is the WORD distance from pc, and pc reads as the
    // instruction's address plus eight.
    void branch(i32 cond, bool link, i32 targetOffset, u32 at)
        {
        i32 delta = (targetOffset - (i32)at - (i32)8) >> 2;
        u32 w = ((u32)cond << 28) | ((u32)5 << 25) | ((u32)delta & (u32)$FFFFFF);
        if (link)
            w = w | ((u32)1 << 24);
        word(w);
        }

    void branchExchange(i32 cond, bool link, u32 rm)
        {
        u32 op = link ? (u32)$3 : (u32)$1;
        word(((u32)cond << 28) | (u32)$12FFF00 | (op << 4) | rm);
        }

    // uxtb/uxth/sxtb/sxth with no rotation — the only forms emitted.
    void extend(i32 cond, bool sign, bool halfword, u32 rd, u32 rm)
        {
        u32 op = sign ? (halfword ? (u32)$6B : (u32)$6A)
                      : (halfword ? (u32)$6F : (u32)$6E);
        word(((u32)cond << 28) | (op << 20) | ((u32)$F << 16) | (rd << 12) | ((u32)7 << 4) | rm);
        }

    void multiply(i32 cond, u32 rd, u32 rm, u32 rs)
        {
        word(((u32)cond << 28) | (rd << 16) | ((u32)9 << 4) | (rs << 8) | rm);
        }

    void multiplyAccumulate(i32 cond, u32 rd, u32 rm, u32 rs, u32 rn)
        {
        word(((u32)cond << 28) | ((u32)1 << 21) | (rd << 16) | (rn << 12) | (rs << 8) | ((u32)9 << 4) | rm);
        }

    // ── Assembling a file ────────────────────────────────────────────────
    // Two passes: the first places every label, the second encodes. A branch
    // has to know where it is going before it can be encoded, and forward
    // branches are the common case.
    Map* _labels; // label -> byte offset in .text
    Array* _lines;
    u32 _pc;      // the byte offset being emitted at
    bool _inText; // .text vs .data — only .text is assembled here

    Array* assemble(String* text)
        {
        _lines = text.splitOnByte((u8)10);
        _labels = new Map();
        _syms = new Array();
        _relocs = new Array();
        _pool = new Array();
        _poolSites = new Array();
        // Pass 1 places every label — a branch cannot be encoded until it knows
        // where it is going, and forward branches are the common case. The
        // literal pool is placed here too, because a pool word occupies space
        // and everything after it shifts.
        _pass = (u32)1;
        run();
        // Pass 2 encodes, with the same pool placement.
        _pass = (u32)2;
        run();
        return _bytes;
        }

    u32 _pass;

    void run(void)
        {
        _bytes = new Array();
        _data = new Array();
        _section = (u32)1;
        _pc = (u32)0;
        _dataPc = (u32)0;
        _pool = new Array();
        _poolSites = new Array();
        if (_pass == (u32)2)
            _relocs = new Array();
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            line(((String*)_lines.get(i)).trimmed());
        flushPool();
        }

    u32 _dataPc;

    // Where the next byte goes, in whichever section is current.
    u32 cursor(void)
        {
        return _section == (u32)1 ? _pc : _dataPc;
        }

    void line(String* text)
        {
        if (text.byteLength() == (u32)0)
            return;
        // A trailing comment. The back end never emits one, but the runtime
        // written BY HAND does, and an operand with a comment glued to it parses
        // as a bad register — which is then reported as an unknown MNEMONIC,
        // pointing at the one thing that was fine.
        //
        // Both spellings, because the oracle takes both: `@` is traditional ARM
        // and `//` is what the licence header on every generated runtime .s
        // uses. While only `@` was cut, every arm9 self-host link died on the
        // first line of rtgen-arm9.s with `unsupported ARM assembly: //`.
        //
        // Quoted strings are respected, so a `//` inside a .asciz survives.
        text = stripComment(text).trimmed();
        if (text.byteLength() == (u32)0)
            return;
        // `label: instruction` on one line — likewise a hand-written form.
        u32 colon = text.indexOfByte((u8)':');
        if (colon != String.notFound() && colon + (u32)1 < text.byteLength())
            {
            String* head = text.substringBytes((u32)0, colon + (u32)1);
            String* tail = text.substringFromByte(colon + (u32)1).trimmed();
            String* l = labelOn(head);
            if (l != 0 && tail.byteLength() > (u32)0)
                {
                defineLabel(l);
                text = tail;
                }
            }
        String* lab = labelOn(text);
        if (lab != 0)
            {
            defineLabel(lab);
            return;
            }
        if (text.byteAt((u32)0) == (u8)'@')
            return;
        if (text.byteAt((u32)0) == (u8)'/' && text.byteLength() > (u32)1
            && text.byteAt((u32)1) == (u8)'/')
            return;
        if (text.byteAt((u32)0) == (u8)'.')
            {
            directive(text);
            return;
            }
        if (_section != (u32)1)
            return; // no instructions in .data
        if (_pass == (u32)1)
            {
            // Pass 1 does not encode, but it must see a `ldr =sym`: the pool
            // word it needs occupies space, and everything after the pool
            // shifts by it. It must also see every symbol a relocation will
            // name, because the table those indices point into is built here.
            notePoolUse(text);
            noteSymbolUse(text);
            _pc = _pc + (u32)4;
            return;
            }
        instruction(text);
        _pc = _pc + (u32)4;
        }

    // Pass 1's view of `ldr rX, =sym`: remember that this pool will need a
    // word, so its size is known before any label after it is placed.
    void notePoolUse(String* text)
        {
        u32 eq = text.indexOfByte((u8)'=');
        if (eq == String.notFound())
            return;
        if (!text.hasPrefix(String.withCString("ldr")))
            return;
        _pool.add((Object*)text.substringFromByte(eq + (u32)1).trimmed());
        _poolSites.add((Object*)Number.with(_pc));
        }

    // A `bl <name>` or `ldr rX, =<name>` names a symbol the relocation will
    // need an index for — even one this file never defines.
    void noteSymbolUse(String* text)
        {
        u32 sp = (u32)0;
        while (sp < text.byteLength() && text.byteAt(sp) != (u8)' ' && text.byteAt(sp) != (u8)9)
            sp = sp + (u32)1;
        String* m = text.substringBytes((u32)0, sp);
        String* rest = text.substringFromByte(sp).trimmed();
        if (m.equals(String.withCString("bl")) || m.equals(String.withCString("b")))
            {
            if (rest.byteLength() == (u32)0)
                return;
            if (rest.hasPrefix(String.withCString(".L")))
                return;
            if (Arm32.isNumericRef(rest))
                return;
            symbolFor(rest);
            return;
            }
        u32 eq = text.indexOfByte((u8)'=');
        if (eq != String.notFound() && m.hasPrefix(String.withCString("ldr")))
            symbolFor(text.substringFromByte(eq + (u32)1).trimmed());
        }

    static bool isNumericRef(String* t)
        {
        if (t.byteLength() < (u32)2)
            return false;
        u8 last = t.byteAt(t.byteLength() - (u32)1);
        if (last != (u8)'f' && last != (u8)'b')
            return false;
        return Arm32.isNumericLabel(t.substringBytes((u32)0, t.byteLength() - (u32)1));
        }

    void defineLabel(String* name)
        {
        if (_pass != (u32)1)
            return;
        // A NUMERIC label (`1:`) may be defined many times; a reference says
        // which one by direction — `1f` the next one forward, `1b` the last one
        // back. So they are kept as a list of positions rather than a binding.
        if (Arm32.isNumericLabel(name))
            {
            if (_numeric == 0)
                _numeric = new Map();
            Object* have = _numeric.get((Hashable*)name);
            Array* list = have == 0 ? new Array() : (Array*)have;
            list.add((Object*)Number.with(cursor()));
            _numeric.set((Hashable*)name, (Object*)list);
            return;
            }
        _labels.set((Hashable*)name, (Object*)Number.with(cursor()));
        // A `.L` label is assembler-internal and does not belong in the symbol
        // table — UNLESS something took its address (`.word .LANCHOR0+16`, how a
        // compiler names its own static data). Recorded whether or not anything
        // has referenced it YET: a reference that comes AFTER the label would
        // otherwise create a second, undefined symbol.
        if (name.hasPrefix(String.withCString(".L")))
            {
            AsmSymbol* l = symbolFor(name);
            l.setSection(_section);
            l.setValue(cursor());
            return;
            }
        AsmSymbol* sym = symbolFor(name);
        sym.setSection(_section);
        sym.setValue(cursor());
        }

    Map* _numeric; // "1" -> Array@ of the offsets it is defined at

    static bool isNumericLabel(String* n)
        {
        if (n == 0 || n.byteLength() == (u32)0)
            return false;
        for (u32 i = (u32)0; i < n.byteLength(); i = i + (u32)1)
            if (n.byteAt(i) < (u8)'0' || n.byteAt(i) > (u8)'9')
                return false;
        return true;
        }

    // `1f` / `1b` — the nearest definition of that number in the named
    // direction. -1 when there is none, which is a malformed file.
    i32 numericTarget(String* ref)
        {
        if (ref.byteLength() < (u32)2 || _numeric == 0)
            return (i32)-1;
        u8 dir = ref.byteAt(ref.byteLength() - (u32)1);
        if (dir != (u8)'f' && dir != (u8)'b')
            return (i32)-1;
        String* num = ref.substringBytes((u32)0, ref.byteLength() - (u32)1);
        if (!Arm32.isNumericLabel(num))
            return (i32)-1;
        Object* have = _numeric.get((Hashable*)num);
        if (have == 0)
            return (i32)-1;
        Array* list = (Array*)have;
        i32 best = (i32)-1;
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            u32 at = ((Number*)list.get(i)).asU32();
            if (dir == (u8)'f')
                {
                if (at > _pc && best < (i32)0)
                    best = (i32)at;
                }
            else if (at <= _pc)
                best = (i32)at;
            }
        return best;
        }

    // The symbol table is built in pass 1 and read in pass 2, so a `.global`
    // that follows the label it names still applies.
    bool isGlobalName(String* name)
        {
        for (u32 i = (u32)0; i < _syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)_syms.get(i);
            if (s.name().equals(name))
                return s.isGlobal();
            }
        return false;
        }

    AsmSymbol* symbolFor(String* name)
        {
        for (u32 i = (u32)0; i < _syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)_syms.get(i);
            if (s.name().equals(name))
                return s;
            }
        AsmSymbol* s = AsmSymbol.named(name);
        _syms.add((Object*)s);
        return s;
        }

    // ── Directives ───────────────────────────────────────────────────────
    void directive(String* text)
        {
        u32 sp = (u32)0;
        while (sp < text.byteLength() && text.byteAt(sp) != (u8)' ' && text.byteAt(sp) != (u8)9)
            sp = sp + (u32)1;
        String* d = text.substringBytes((u32)0, sp);
        String* rest = text.substringFromByte(sp).trimmed();
        if (d.equals(String.withCString(".text")))
            {
            _section = (u32)1;
            return;
            }
        if (d.equals(String.withCString(".data")))
            {
            _section = (u32)2;
            return;
            }
        if (d.equals(String.withCString(".bss")))
            {
            _section = (u32)2;
            return;
            }
        if (d.equals(String.withCString(".section")))
            {
            // The NAME decides, not the directive. `.section .text.startup` is
            // CODE, and reading it as data put `main` in the writable segment —
            // where the loader jumped, taking a prefetch abort at the image's
            // own base.
            String* nm = rest;
            u32 c2 = nm.indexOfByte((u8)',');
            if (c2 != String.notFound())
                nm = nm.substringBytes((u32)0, c2).trimmed();
            _section = nm.hasPrefix(String.withCString(".text")) ? (u32)1 : (u32)2;
            return;
            }
        if (d.equals(String.withCString(".ltorg")))
            {
            flushPool();
            return;
            }
        if (d.equals(String.withCString(".global")) || d.equals(String.withCString(".globl")))
            {
            if (_pass == (u32)1)
                symbolFor(rest).setGlobal();
            return;
            }
        if (d.equals(String.withCString(".hidden")))
            {
            if (_pass == (u32)1)
                symbolFor(rest).setHidden();
            return;
            }
        if (d.equals(String.withCString(".type")))
            {
            typeDirective(rest);
            return;
            }
        // computed below
        if (d.equals(String.withCString(".size")))
            {
            return;
            }
        if (d.equals(String.withCString(".comm")))
            {
            commDirective(rest);
            return;
            }
        if (d.equals(String.withCString(".byte")))
            {
            emitByte(rest);
            return;
            }
        if (d.equals(String.withCString(".word")))
            {
            emitWord(rest);
            return;
            }
        if (d.equals(String.withCString(".p2align")))
            {
            align(rest);
            return;
            }
        if (d.equals(String.withCString(".set")) || d.equals(String.withCString(".equ")))
            {
            setDirective(rest);
            return;
            }
        if (d.equals(String.withCString(".zero")) || d.equals(String.withCString(".space")))
            {
            u32 n = Arm32.decimalValue(rest);
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                putByte((u32)0);
            return;
            }
        // .file/.syntax/.arch/.fpu/.incbin and friends carry no payload here.
        }

    // `.set name, . + 0` — how a compiler names an anchor into its own data.
    // Only the location-relative form is understood; anything else is REPORTED,
    // because a `.set` quietly ignored is a symbol that resolves to zero at run
    // time.
    void setDirective(String* rest)
        {
        u32 comma = rest.indexOfByte((u8)',');
        if (comma == String.notFound())
            {
            giveUp(String.withCString(".set (no value)"));
            return;
            }
        String* name = rest.substringBytes((u32)0, comma).trimmed();
        String* val = rest.substringFromByte(comma + (u32)1).trimmed();
        if (!val.hasPrefix(String.withCString(".")))
            {
            String* w = String.withCString(".set ");
            w.append(val);
            giveUp(w);
            return;
            }
        u32 extra = (u32)0;
        u32 plus = val.indexOfByte((u8)'+');
        if (plus != String.notFound())
            extra = Arm32.immediateValue(val.substringFromByte(plus + (u32)1).trimmed());
        if (_pass != (u32)1)
            return;
        _labels.set((Hashable*)name, (Object*)Number.with(cursor() + extra));
        AsmSymbol* sym = symbolFor(name);
        sym.setSection(_section);
        sym.setValue(cursor() + extra);
        }

    void typeDirective(String* rest)
        {
        if (_pass != (u32)1)
            return;
        u32 comma = rest.indexOfByte((u8)',');
        if (comma == String.notFound())
            return;
        String* name = rest.substringBytes((u32)0, comma).trimmed();
        String* kind = rest.substringFromByte(comma + (u32)1).trimmed();
        if (kind.byteIndexOf(String.withCString("function")) != String.notFound())
            symbolFor(name).setFunction();
        }

    // `.comm name, size, align` — a zero-filled global that the linker places.
    void commDirective(String* rest)
        {
        if (_pass != (u32)1)
            return;
        Array* parts = rest.splitOnByte((u8)',');
        if (parts.count() == (u32)0)
            return;
        AsmSymbol* s = symbolFor(((String*)parts.get((u32)0)).trimmed());
        s.setSection((u32)3); // COMMON
        s.setGlobal();
        if (parts.count() > (u32)1)
            s.setSize(Arm32.decimalValue(((String*)parts.get((u32)1)).trimmed()));
        // A COMMON symbol's `value` is its alignment, not an offset.
        s.setValue((u32)4);
        }

    static u32 decimalValue(String* t)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return v;
        }

    void putByte(u32 b)
        {
        if (_section == (u32)1)
            {
            if (_pass == (u32)2)
                _bytes.add((Object*)Number.with(b & (u32)$FF));
            _pc = _pc + (u32)1;
            return;
            }
        if (_pass == (u32)2)
            _data.add((Object*)Number.with(b & (u32)$FF));
        _dataPc = _dataPc + (u32)1;
        }

    void emitByte(String* rest)
        {
        Array* parts = rest.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            putByte(Arm32.immediateValue(hashed(((String*)parts.get(i)).trimmed())));
        }

    // `.byte 0x0A` has no `#`, but the immediate reader wants one.
    static String* hashed(String* t)
        {
        String* s = String.withCString("#");
        s.append(t);
        return s;
        }

    // Strip an end-of-line comment, in either spelling the oracle accepts: `@`,
    // traditional ARM, and `//`, which is what the licence header on every
    // generated runtime .s uses.
    //
    // NOT `;`. The arm64 assembler cuts on it because clang's arm64 output
    // comments that way, but on ARM32 `arm-none-eabi-as` reads `;` as a
    // STATEMENT SEPARATOR — `mov r0, #1 ; mov r0, #2` assembles to two
    // instructions — so cutting there would delete real code.
    //
    // Quoted strings are respected: the oracle keeps the `//` in a .asciz of
    // "http://example/x", and so must we.
    static String* stripComment(String* l)
        {
        bool inStr = false;
        for (u32 i = (u32)0; i < l.byteLength(); i = i + (u32)1)
            {
            u8 c = l.byteAt(i);
            if (c == (u8)'"')
                {
                inStr = !inStr;
                continue;
                }
            if (inStr)
                continue;
            if (c == (u8)'@')
                return l.substringBytes((u32)0, i);
            if (c == (u8)'/' && i + (u32)1 < l.byteLength()
                && l.byteAt(i + (u32)1) == (u8)'/')
                return l.substringBytes((u32)0, i);
            }
        return l;
        }

    // `.word 0` is a literal; `.word symbol` is a relocation against it.
    void emitWord(String* rest)
        {
        Array* parts = rest.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* t = ((String*)parts.get(i)).trimmed();
            if (t.byteLength() > (u32)0 && t.byteAt((u32)0) >= (u8)'0' && t.byteAt((u32)0) <= (u8)'9')
                {
                u32 v = Arm32.immediateValue(Arm32.hashed(t));
                putByte(v);
                putByte(v >> 8);
                putByte(v >> 16);
                putByte(v >> 24);
                continue;
                }
            // `.word sym+16` — an ARM REL relocation carries its addend IN the
            // word, so the offset is written and the linker adds the symbol.
            String* name = t;
            u32 addend = (u32)0;
            u32 plus = t.indexOfByte((u8)'+');
            if (plus != String.notFound())
                {
                name = t.substringBytes((u32)0, plus).trimmed();
                addend = Arm32.immediateValue(t.substringFromByte(plus + (u32)1).trimmed());
                }
            if (_pass == (u32)2)
                _relocs.add((Object*)AsmReloc.with(_section, cursor(), name, (u32)R_ARM_ABS32));
            if (_pass == (u32)1)
                symbolFor(name);
            putByte(addend);
            putByte(addend >> 8);
            putByte(addend >> 16);
            putByte(addend >> 24);
            }
        }

    void align(String* rest)
        {
        u32 p = Arm32.decimalValue(rest);
        u32 mask = ((u32)1 << p) - (u32)1;
        while ((cursor() & mask) != (u32)0)
            putByte((u32)0);
        }

    // ── The literal pool ─────────────────────────────────────────────────
    // `ldr rX, =sym` becomes a pc-relative load of a word that holds the
    // symbol's address. The word goes in the next pool — which is what
    // `.ltorg` marks — and carries the relocation.
    void flushPool(void)
        {
        if (_pool.count() == (u32)0)
            return;
        if (_section != (u32)1)
            {
            _pool = new Array();
            _poolSites = new Array();
            return;
            }
        for (u32 i = (u32)0; i < _pool.count(); i = i + (u32)1)
            {
            String* sym = (String*)_pool.get(i);
            u32 site = ((Number*)_poolSites.get(i)).asU32();
            if (_pass == (u32)2)
                {
                // Patch the ldr's 12-bit offset: pool word minus (site + 8).
                u32 disp = _pc - (site + (u32)8);
                u32 idx = site;
                u32 w = ((Number*)_bytes.get(idx)).asU32() | (((Number*)_bytes.get(idx + (u32)1)).asU32() << 8) | (((Number*)_bytes.get(idx + (u32)2)).asU32() << 16) | (((Number*)_bytes.get(idx + (u32)3)).asU32() << 24);
                w = (w & ~(u32)$FFF) | (disp & (u32)$FFF);
                _bytes.set(idx, (Object*)Number.with(w & (u32)$FF));
                _bytes.set(idx + (u32)1, (Object*)Number.with((w >> 8) & (u32)$FF));
                _bytes.set(idx + (u32)2, (Object*)Number.with((w >> 16) & (u32)$FF));
                _bytes.set(idx + (u32)3, (Object*)Number.with((w >> 24) & (u32)$FF));
                _relocs.add((Object*)AsmReloc.with((u32)1, _pc, sym, (u32)R_ARM_ABS32));
                }
            putByte((u32)0);
            putByte((u32)0);
            putByte((u32)0);
            putByte((u32)0);
            }
        _pool = new Array();
        _poolSites = new Array();
        }

    // A label definition is a bare name followed by `:`.
    String* labelOn(String* line)
        {
        if (line.byteLength() == (u32)0 || line.byteAt((u32)0) == (u8)'.')
            {
            // `.L…:` is a local label, which still defines a position.
            if (line.byteLength() == (u32)0)
                return (String*)0;
            if (line.byteAt(line.byteLength() - (u32)1) != (u8)':')
                return (String*)0;
            }
        if (line.byteAt(line.byteLength() - (u32)1) != (u8)':')
            return (String*)0;
        String* name = line.substringBytes((u32)0, line.byteLength() - (u32)1);
        for (u32 i = (u32)0; i < name.byteLength(); i = i + (u32)1)
            {
            u8 c = name.byteAt(i);
            bool ok = (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_' || c == (u8)'.' || c == (u8)'$';
            if (!ok)
                return (String*)0;
            }
        return name;
        }

    // ── One instruction ──────────────────────────────────────────────────
    // `mnemonic operand, operand, …`, with the operands split on commas that
    // are not inside brackets.
    void instruction(String* line)
        {
        u32 sp = (u32)0;
        while (sp < line.byteLength() && line.byteAt(sp) != (u8)' ' && line.byteAt(sp) != (u8)9)
            sp = sp + (u32)1;
        String* mnem = line.substringBytes((u32)0, sp);
        Array* ops = splitOperands(line.substringFromByte(sp).trimmed());
        encode(mnem, ops);
        }

    Array* splitOperands(String* rest)
        {
        Array* out = new Array();
        u32 depth = (u32)0;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= rest.byteLength(); i = i + (u32)1)
            {
            if (i == rest.byteLength())
                {
                if (i > start)
                    out.add((Object*)rest.substringBytes(start, i - start).trimmed());
                break;
                }
            u8 c = rest.byteAt(i);
            if (c == (u8)'[' || c == (u8)'{')
                depth = depth + (u32)1;
            else if (c == (u8)']' || c == (u8)'}')
                depth = depth - (u32)1;
            else if (c == (u8)',' && depth == (u32)0)
                {
                out.add((Object*)rest.substringBytes(start, i - start).trimmed());
                start = i + (u32)1;
                }
            }
        return out;
        }

    // Split a mnemonic into its base and condition suffix: `moveq` is `mov` +
    // `eq`, `subs` is `sub` with the flag bit. The base is found by trying the
    // longest match that leaves a valid suffix.
    String* _base;
    i32 _cond;
    bool _setFlags;

    bool splitMnemonic(String* m)
        {
        _setFlags = false;
        _cond = (i32)14;
        _base = m;
        if (Arm32.dpOpcode(m) >= (i32)0 || Arm32.isKnownBase(m))
            return true;
        // `<base>s`
        if (m.byteLength() > (u32)1 && m.byteAt(m.byteLength() - (u32)1) == (u8)'s')
            {
            String* b = m.substringBytes((u32)0, m.byteLength() - (u32)1);
            if (Arm32.dpOpcode(b) >= (i32)0 || Arm32.isShiftOp(b) || b.equals(String.withCString("umull")) || b.equals(String.withCString("smull")))
                {
                _base = b;
                _setFlags = true;
                return true;
                }
            }
        // `<base><cond>`
        if (m.byteLength() > (u32)2)
            {
            String* c = m.substringFromByte(m.byteLength() - (u32)2);
            String* b = m.substringBytes((u32)0, m.byteLength() - (u32)2);
            i32 cc = Arm32.condCode(c);
            if (cc >= (i32)0 && (Arm32.dpOpcode(b) >= (i32)0 || Arm32.isKnownBase(b)))
                {
                _base = b;
                _cond = cc;
                return true;
                }
            }
        return false;
        }

    static bool isKnownBase(String* m)
        {
        return m.equals(String.withCString("b")) || m.equals(String.withCString("bl")) || m.equals(String.withCString("bx")) || m.equals(String.withCString("blx")) || m.equals(String.withCString("ldr")) || m.equals(String.withCString("str")) || m.equals(String.withCString("ldrb")) || m.equals(String.withCString("strb")) || m.equals(String.withCString("ldrh")) || m.equals(String.withCString("strh")) || m.equals(String.withCString("ldrsb")) || m.equals(String.withCString("ldrsh")) || m.equals(String.withCString("push")) || m.equals(String.withCString("pop")) || m.equals(String.withCString("movw")) || m.equals(String.withCString("movt")) || m.equals(String.withCString("uxtb")) || m.equals(String.withCString("uxth")) || m.equals(String.withCString("sxtb")) || m.equals(String.withCString("sxth")) || m.equals(String.withCString("mul")) || m.equals(String.withCString("mla")) || m.equals(String.withCString("lsl")) || m.equals(String.withCString("lsr")) || m.equals(String.withCString("asr")) || m.equals(String.withCString("ror")) || m.equals(String.withCString("svc")) || m.equals(String.withCString("swi")) || m.equals(String.withCString("udf"))
               // Barriers and the exclusive pair — what atomic ARC and the thread
               // primitives compile to on this target.
               || m.equals(String.withCString("dmb")) || m.equals(String.withCString("dsb")) || m.equals(String.withCString("isb")) || m.equals(String.withCString("ldrex")) || m.equals(String.withCString("ldrexb")) || m.equals(String.withCString("ldrexh")) || m.equals(String.withCString("strex")) || m.equals(String.withCString("strexb")) || m.equals(String.withCString("strexh"))
               // Count-leading-zeros, the exclusive-monitor clear, the double-word
               // pair, the long multiplies and the coprocessor move — what a
               // compiled runtime uses and a hand-written one wants.
               || m.equals(String.withCString("clz")) || m.equals(String.withCString("clrex")) || m.equals(String.withCString("ldrd")) || m.equals(String.withCString("strd")) || m.equals(String.withCString("mrc")) || m.equals(String.withCString("mcr")) || m.equals(String.withCString("umull")) || m.equals(String.withCString("smull"));
        }

    // The barrier domain, by name. $FFFFFFFF for one this does not know, so an
    // unrecognised option is reported rather than silently assembled as `sy`.
    static u32 barrierOption(String* o)
        {
        if (o.equals(String.withCString("sy")))
            return (u32)15;
        if (o.equals(String.withCString("st")))
            return (u32)14;
        if (o.equals(String.withCString("ish")))
            return (u32)11;
        if (o.equals(String.withCString("ishst")))
            return (u32)10;
        if (o.equals(String.withCString("nsh")))
            return (u32)7;
        if (o.equals(String.withCString("nshst")))
            return (u32)6;
        if (o.equals(String.withCString("osh")))
            return (u32)3;
        if (o.equals(String.withCString("oshst")))
            return (u32)2;
        return (u32)$FFFFFFFF;
        }

    // `#123`, `#0x1F`, `#$1F` — the immediate forms that reach here.
    static bool isImmediate(String* t)
        {
        return t != 0 && t.byteLength() > (u32)0 && t.byteAt((u32)0) == (u8)'#';
        }

    // `#123`, `#0x1F`, `#$1F` — and the SAME forms WITHOUT the `#`, which
    // `movt rD, 22612` really is spelled as. Skipping character 0 blindly turned
    // that into 2612: a wrong constant, silently assembled.
    static u32 immediateValue(String* t)
        {
        u32 i = (t.byteLength() > (u32)0 && t.byteAt((u32)0) == (u8)'#') ? (u32)1 : (u32)0;
        bool neg = false;
        if (i < t.byteLength() && t.byteAt(i) == (u8)'-')
            {
            neg = true;
            i = i + (u32)1;
            }
        u32 v = (u32)0;
        bool hex = false;
        if (i + (u32)1 < t.byteLength() && t.byteAt(i) == (u8)'0' && (t.byteAt(i + (u32)1) == (u8)'x' || t.byteAt(i + (u32)1) == (u8)'X'))
            {
            hex = true;
            i = i + (u32)2;
            }
        else if (i < t.byteLength() && t.byteAt(i) == (u8)'$')
            {
            hex = true;
            i = i + (u32)1;
            }
        while (i < t.byteLength())
            {
            u8 c = t.byteAt(i);
            u32 d = (u32)16;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (hex && c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (hex && c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            else
                break;
            v = hex ? (v * (u32)16 + d) : (v * (u32)10 + d);
            i = i + (u32)1;
            }
        return neg ? (u32)0 - v : v;
        }

    // ── Encoding one instruction ─────────────────────────────────────────
    void encode(String* mnem, Array* ops)
        {
        // A `v`-prefixed mnemonic is floating point and has its own shape —
        // its suffixes are precisions, not conditions, so it must not go
        // through the condition-suffix split.
        if (Arm32.isVfpMnemonic(mnem))
            {
            if (!encodeVfp(mnem, ops))
                giveUp(mnem);
            return;
            }
        if (!splitMnemonic(mnem))
            {
            giveUp(mnem);
            return;
            }
        String* b = _base;
        if (b.equals(String.withCString("push")) || b.equals(String.withCString("pop")))
            {
            bool pop = b.equals(String.withCString("pop"));
            u32 list = registerList(ops);
            // ONE register is a plain store/load with writeback, not a
            // load/store-multiple — what `as` emits and the ARM ARM prefers.
            if (list != (u32)0 && (list & (list - (u32)1)) == (u32)0)
                {
                u32 r = (u32)0;
                while (((list >> r) & (u32)1) == (u32)0)
                    r = r + (u32)1;
                word(((u32)_cond << 28) | (pop ? (u32)$49D0004 : (u32)$52D0004) | (r << 12));
                return;
                }
            pushPop(_cond, pop, list);
            return;
            }
        if (b.equals(String.withCString("b")) || b.equals(String.withCString("bl")))
            {
            encodeBranch(b.equals(String.withCString("bl")), ops);
            return;
            }
        if (b.equals(String.withCString("bx")) || b.equals(String.withCString("blx")))
            {
            i32 rm = Arm32.regNumber((String*)ops.get((u32)0));
            if (rm < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            branchExchange(_cond, b.equals(String.withCString("blx")), (u32)rm);
            return;
            }
        if (b.equals(String.withCString("movw")) || b.equals(String.withCString("movt")))
            {
            i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
            if (rd < (i32)0 || ops.count() < (u32)2)
                {
                giveUp(mnem);
                return;
                }
            movImm16(_cond, b.equals(String.withCString("movt")), (u32)rd,
                     Arm32.immediateValue((String*)ops.get((u32)1)) & (u32)$FFFF);
            return;
            }
        if (Arm32.isExtendOp(b))
            {
            i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
            i32 rm = Arm32.regNumber((String*)ops.get((u32)1));
            if (rd < (i32)0 || rm < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            extend(_cond, b.byteAt((u32)0) == (u8)'s',
                   b.equals(String.withCString("uxth")) || b.equals(String.withCString("sxth")),
                   (u32)rd, (u32)rm);
            return;
            }
        if (b.equals(String.withCString("mul")))
            {
            i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
            i32 rm = Arm32.regNumber((String*)ops.get((u32)1));
            i32 rs = Arm32.regNumber((String*)ops.get((u32)2));
            if (rd < (i32)0 || rm < (i32)0 || rs < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            multiply(_cond, (u32)rd, (u32)rm, (u32)rs);
            return;
            }
        if (b.equals(String.withCString("mla")))
            {
            i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
            i32 rm = Arm32.regNumber((String*)ops.get((u32)1));
            i32 rs = Arm32.regNumber((String*)ops.get((u32)2));
            i32 rn = Arm32.regNumber((String*)ops.get((u32)3));
            if (rd < (i32)0 || rm < (i32)0 || rs < (i32)0 || rn < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            multiplyAccumulate(_cond, (u32)rd, (u32)rm, (u32)rs, (u32)rn);
            return;
            }
        if (b.equals(String.withCString("svc")) || b.equals(String.withCString("swi")))
            {
            // A supervisor call: the 24-bit comment field is what the kernel's
            // dispatcher ignores (the number is in r7), but it is encoded.
            u32 imm = ops.count() > (u32)0
                          ? Arm32.immediateValue((String*)ops.get((u32)0))
                          : (u32)0;
            word(((u32)_cond << 28) | ((u32)$F << 24) | (imm & (u32)$FFFFFF));
            return;
            }
        if (b.equals(String.withCString("udf")))
            {
            // The permanently-undefined encoding, which is what a trap is.
            word((u32)$E7F000F0);
            return;
            }
        if (b.equals(String.withCString("dmb")) || b.equals(String.withCString("dsb")) || b.equals(String.withCString("isb")))
            {
            encodeBarrier(b, ops, mnem);
            return;
            }
        if (b.hasPrefix(String.withCString("ldrex")) || b.hasPrefix(String.withCString("strex")))
            {
            encodeExclusive(b, ops, mnem);
            return;
            }
        if (b.equals(String.withCString("clz")))
            {
            encodeClz(ops, mnem);
            return;
            }
        if (b.equals(String.withCString("clrex")))
            {
            word((u32)$F57FF01F);
            return;
            }
        if (b.equals(String.withCString("umull")) || b.equals(String.withCString("smull")))
            {
            encodeLongMultiply(b, ops, mnem);
            return;
            }
        if (b.equals(String.withCString("ldrd")) || b.equals(String.withCString("strd")))
            {
            encodeDoubleWord(b, ops, mnem);
            return;
            }
        if (b.equals(String.withCString("mrc")) || b.equals(String.withCString("mcr")))
            {
            encodeCoproc(b, ops, mnem);
            return;
            }
        if (Arm32.isMemOp(b))
            {
            encodeMemory(b, ops, mnem);
            return;
            }
        if (Arm32.isShiftOp(b))
            {
            encodeShift(b, ops, mnem);
            return;
            }
        i32 dp = Arm32.dpOpcode(b);
        if (dp >= (i32)0)
            {
            encodeDataProcessing(dp, ops, mnem);
            return;
            }
        giveUp(mnem);
        }

    static bool isExtendOp(String* b)
        {
        return b.equals(String.withCString("uxtb")) || b.equals(String.withCString("uxth")) || b.equals(String.withCString("sxtb")) || b.equals(String.withCString("sxth"));
        }

    static bool isMemOp(String* b)
        {
        return b.equals(String.withCString("ldr")) || b.equals(String.withCString("str")) || b.equals(String.withCString("ldrb")) || b.equals(String.withCString("strb")) || b.equals(String.withCString("ldrh")) || b.equals(String.withCString("strh")) || b.equals(String.withCString("ldrsb")) || b.equals(String.withCString("ldrsh"));
        }

    static bool isShiftOp(String* b)
        {
        return b.equals(String.withCString("lsl")) || b.equals(String.withCString("lsr")) || b.equals(String.withCString("asr")) || b.equals(String.withCString("ror"));
        }

    // `{r4-r11, lr}` -> the 16-bit register mask. The braces make the whole
    // list ONE operand (the commas inside are not separators), so the items
    // are split here rather than by the operand splitter.
    u32 registerList(Array* ops)
        {
        String* inner = String.withCString("");
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                inner.appendCString(",");
            inner.append((String*)ops.get(i));
            }
        while (inner.byteLength() > (u32)0 && (inner.byteAt((u32)0) == (u8)'{' || inner.byteAt((u32)0) == (u8)' '))
            inner = inner.substringFromByte((u32)1);
        while (inner.byteLength() > (u32)0 && (inner.byteAt(inner.byteLength() - (u32)1) == (u8)'}' || inner.byteAt(inner.byteLength() - (u32)1) == (u8)' '))
            inner = inner.substringBytes((u32)0, inner.byteLength() - (u32)1);
        u32 mask = (u32)0;
        Array* items = inner.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < items.count(); i = i + (u32)1)
            {
            String* t = ((String*)items.get(i)).trimmed();
            if (t.byteLength() == (u32)0)
                continue;
            u32 dash = t.indexOfByte((u8)'-');
            if (dash != String.notFound())
                {
                i32 lo = Arm32.regNumber(t.substringBytes((u32)0, dash).trimmed());
                i32 hi = Arm32.regNumber(t.substringFromByte(dash + (u32)1).trimmed());
                if (lo < (i32)0 || hi < (i32)0)
                    continue;
                for (i32 r = lo; r <= hi; r = r + (i32)1)
                    mask = mask | ((u32)1 << (u32)r);
                continue;
                }
            i32 r = Arm32.regNumber(t);
            if (r >= (i32)0)
                mask = mask | ((u32)1 << (u32)r);
            }
        return mask;
        }

    void encodeBranch(bool link, Array* ops)
        {
        if (ops.count() == (u32)0)
            {
            giveUp(String.withCString("b <nothing>"));
            return;
            }
        String* target = (String*)ops.get((u32)0);
        i32 numeric = numericTarget(target);
        if (numeric >= (i32)0)
            {
            branch(_cond, link, numeric, _pc);
            return;
            }
        Object* at = _labels.get((Hashable*)target);
        // A label this file defines resolves here — UNLESS it is global. A
        // global symbol can be preempted at link time, so baking a
        // displacement in is not the assembler's decision to make, and `as`
        // relocates those too (which is how the byte comparison found it).
        if (at != 0 && !isGlobalName(target))
            {
            branch(_cond, link, (i32)((Number*)at).asU32(), _pc);
            return;
            }
        // A branch to a symbol this file does not define is a RELOCATION: the
        // displacement is left as the encoding's own "branch to itself" and the
        // linker fills it in. (The addend an ARM REL relocation carries lives
        // in the instruction, which is why it is -8 >> 2 = 0xFFFFFE.)
        _relocs.add((Object*)AsmReloc.with((u32)1, _pc, target, (u32)R_ARM_CALL));
        // The addend an ARM REL relocation carries lives IN the instruction,
        // and for a call it is -8: the displacement that branches to the
        // instruction itself, which is what the linker adds its own offset to.
        branch(_cond, link, (i32)_pc, _pc);
        }

    // A memory barrier. The option is a NAME, not a number: `ish` is the inner
    // shareable domain, which is what an SMP atomic needs.
    void encodeBarrier(String* b, Array* ops, String* mnem)
        {
        u32 opt = ops.count() > (u32)0
                      ? Arm32.barrierOption((String*)ops.get((u32)0))
                      : (u32)15;
        if (opt == (u32)$FFFFFFFF)
            {
            giveUp(mnem);
            return;
            }
        u32 kind = b.equals(String.withCString("dmb")) ? (u32)$50
                                                       : (b.equals(String.withCString("dsb")) ? (u32)$40 : (u32)$60);
        word((u32)$F57FF000 | kind | opt);
        }

    // The exclusive pair, which is what an atomic read-modify-write is built
    // from: `ldrexh rT, [rN]` and `strexh rD, rT, [rN]` — note the operand
    // order, the STATUS register comes first on the store.
    void encodeExclusive(String* b, Array* ops, String* mnem)
        {
        bool load = b.byteAt((u32)0) == (u8)'l';
        String* width = b.substringFromByte((u32)5); // "", "b" or "h"
        u32 sizeBits = (u32)0;
        if (width.byteLength() == (u32)0)
            sizeBits = (u32)$00;
        else if (width.equals(String.withCString("b")))
            sizeBits = (u32)$04;
        else if (width.equals(String.withCString("h")))
            sizeBits = (u32)$06;
        else
            {
            giveUp(mnem);
            return;
            }
        u32 addrIdx = load ? (u32)1 : (u32)2;
        if (ops.count() < addrIdx + (u32)1)
            {
            giveUp(mnem);
            return;
            }
        String* addr = (String*)ops.get(addrIdx);
        if (addr.byteLength() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        if (addr.byteAt((u32)0) != (u8)'[')
            {
            giveUp(mnem);
            return;
            }
        if (addr.byteAt(addr.byteLength() - (u32)1) != (u8)']')
            {
            giveUp(mnem);
            return;
            }
        i32 rn = Arm32.regNumber(addr.substringBytes((u32)1, addr.byteLength() - (u32)2).trimmed());
        i32 r0 = Arm32.regNumber((String*)ops.get((u32)0));
        if (rn < (i32)0 || r0 < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        if (load)
            {
            word(((u32)_cond << 28) | (u32)$1900000 | (sizeBits << 20) | ((u32)rn << 16) | ((u32)r0 << 12) | (u32)$F9F);
            return;
            }
        i32 rt = Arm32.regNumber((String*)ops.get((u32)1));
        if (rt < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        word(((u32)_cond << 28) | (u32)$1800000 | (sizeBits << 20) | ((u32)rn << 16) | ((u32)r0 << 12) | (u32)$F90 | (u32)rt);
        }

    void encodeClz(Array* ops, String* mnem)
        {
        if (ops.count() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
        i32 rm = Arm32.regNumber((String*)ops.get((u32)1));
        if (rd < (i32)0 || rm < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        word(((u32)_cond << 28) | (u32)$16F0F10 | ((u32)rd << 12) | (u32)rm);
        }

    // `umull rdLo, rdHi, rn, rm` — the 64-bit product of two 32-bit registers.
    // The opcode is bits 23-21 (100 unsigned / 110 signed), NOT a byte: writing
    // it as one lands in the wrong field entirely.
    void encodeLongMultiply(String* b, Array* ops, String* mnem)
        {
        if (ops.count() < (u32)4)
            {
            giveUp(mnem);
            return;
            }
        i32 rdlo = Arm32.regNumber((String*)ops.get((u32)0));
        i32 rdhi = Arm32.regNumber((String*)ops.get((u32)1));
        i32 rn = Arm32.regNumber((String*)ops.get((u32)2));
        i32 rm = Arm32.regNumber((String*)ops.get((u32)3));
        if (rdlo < (i32)0 || rdhi < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        if (rn < (i32)0 || rm < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        u32 op = b.equals(String.withCString("smull")) ? (u32)6 : (u32)4;
        word(((u32)_cond << 28) | (op << 21) | (_setFlags ? ((u32)1 << 20) : (u32)0) | ((u32)rdhi << 16) | ((u32)rdlo << 12) | ((u32)rm << 8) | ((u32)9 << 4) | (u32)rn);
        }

    // `ldrd r4, r5, [rN, #off]` — a register PAIR named by its first; the offset
    // splits 4+4 around a fixed nibble as the halfword forms do.
    void encodeDoubleWord(String* b, Array* ops, String* mnem)
        {
        bool ld = b.equals(String.withCString("ldrd"));
        if (ops.count() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        i32 rt = Arm32.regNumber((String*)ops.get((u32)0));
        String* addr = (String*)ops.get(ops.count() - (u32)1);
        if (rt < (i32)0 || addr.byteLength() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        if (addr.byteAt((u32)0) != (u8)'[')
            {
            giveUp(mnem);
            return;
            }
        if (addr.byteAt(addr.byteLength() - (u32)1) != (u8)']')
            {
            giveUp(mnem);
            return;
            }
        Array* parts = splitOperands(addr.substringBytes((u32)1, addr.byteLength() - (u32)2));
        if (parts.count() == (u32)0)
            {
            giveUp(mnem);
            return;
            }
        i32 rn = Arm32.regNumber(((String*)parts.get((u32)0)).trimmed());
        if (rn < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        i32 off = (i32)0;
        if (parts.count() > (u32)1)
            {
            String* o = ((String*)parts.get((u32)1)).trimmed();
            if (!Arm32.isImmediate(o))
                {
                giveUp(mnem);
                return;
                }
            off = (i32)Arm32.immediateValue(o);
            }
        u32 up = off >= (i32)0 ? (u32)1 : (u32)0;
        u32 mag = off >= (i32)0 ? (u32)off : (u32)(-off);
        word(((u32)_cond << 28) | ((u32)1 << 24) | (up << 23) | ((u32)1 << 22) | ((u32)rn << 16) | ((u32)rt << 12) | (((mag >> 4) & (u32)$F) << 8) | (ld ? (u32)$D0 : (u32)$F0) | (mag & (u32)$F));
        }

    // `mrc p15, 0, r0, c13, c0, 3` — read a coprocessor register. The thread
    // pointer lives behind one of these, which is why a runtime needs it.
    void encodeCoproc(String* b, Array* ops, String* mnem)
        {
        if (ops.count() < (u32)6)
            {
            giveUp(mnem);
            return;
            }
        u32 cp = Arm32.cpNumber((String*)ops.get((u32)0), (u8)'p');
        u32 op1 = Arm32.decimalValue((String*)ops.get((u32)1));
        i32 rt = Arm32.regNumber((String*)ops.get((u32)2));
        u32 crn = Arm32.cpNumber((String*)ops.get((u32)3), (u8)'c');
        u32 crm = Arm32.cpNumber((String*)ops.get((u32)4), (u8)'c');
        u32 op2 = Arm32.decimalValue((String*)ops.get((u32)5));
        if (rt < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        word(((u32)_cond << 28) | ((u32)$E << 24) | (op1 << 21) | ((b.equals(String.withCString("mrc")) ? (u32)1 : (u32)0) << 20) | (crn << 16) | ((u32)rt << 12) | (cp << 8) | (op2 << 5) | ((u32)1 << 4) | crm);
        }

    // `ldr rD, [rN]` / `[rN, #off]` — the only addressing forms the back end
    // emits. `ldr rD, =sym` is a literal-pool load and needs the pool, which
    // belongs with relocations.
    void encodeMemory(String* b, Array* ops, String* mnem)
        {
        if (ops.count() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        i32 rt = Arm32.regNumber((String*)ops.get((u32)0));
        String* addr = (String*)ops.get((u32)1);
        if (rt < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        if (addr.byteLength() > (u32)0 && addr.byteAt((u32)0) == (u8)'=')
            {
            // `ldr rX, =sym` is a pc-relative load of a word that holds the
            // symbol's address. The word is placed at the next pool (`.ltorg`)
            // and carries the relocation; the offset is patched then, because
            // only then is the distance known.
            String* sym = addr.substringFromByte((u32)1).trimmed();
            _pool.add((Object*)sym);
            _poolSites.add((Object*)Number.with(_pc));
            // `ldr rT, [pc, #0]` — pc is r15, and the displacement is filled in
            // when the pool is flushed.
            loadStore(_cond, true, false, (u32)rt, (u32)15, (i32)0);
            return;
            }
        // `ldr r0, .L9+4` — a PC-relative load from a LABEL, which is how a
        // compiler addresses its own constant pool. The displacement is
        // measured from pc, which reads as this instruction's address plus
        // eight.
        if (addr.byteLength() > (u32)0 && addr.byteAt((u32)0) != (u8)'[')
            {
            String* name = addr;
            i32 extra = (i32)0;
            u32 plus = addr.byteIndexOf(String.withCString("+"), (u32)0);
            if (plus != String.notFound())
                {
                name = addr.substringBytes((u32)0, plus).trimmed();
                extra = (i32)Arm32.decimalValue(
                    addr.substringFromByte(plus + (u32)1).trimmed());
                }
            Object* at = _labels.get((Hashable*)name);
            if (at == (Object*)0)
                {
                giveUp(mnem);
                return;
                }
            i32 disp = (i32)((Number*)at).asU32() + extra - (i32)_pc - (i32)8;
            bool byteOp = b.equals(String.withCString("ldrb")) || b.equals(String.withCString("strb"));
            if (!b.equals(String.withCString("ldr")) && !byteOp)
                {
                giveUp(mnem);
                return;
                }
            loadStore(_cond, true, byteOp, (u32)rt, (u32)15, disp);
            return;
            }
        if (addr.byteLength() < (u32)2 || addr.byteAt((u32)0) != (u8)'[')
            {
            giveUp(mnem);
            return;
            }
        // `[rN, …]!` is pre-indexed with writeback; `[rN], #off` is
        // post-indexed — the bracket closes before the offset. Both appear in
        // compiler output and in any hand-written loop that walks a pointer.
        bool writeback = false;
        bool postIndexed = false;
        if (addr.hasSuffix(String.withCString("!")))
            {
            writeback = true;
            addr = addr.substringBytes((u32)0, addr.byteLength() - (u32)1);
            }
        u32 rb = addr.byteIndexOf(String.withCString("]"), (u32)0);
        if (rb == String.notFound())
            {
            giveUp(mnem);
            return;
            }
        String* inner = addr.substringBytes((u32)1, rb - (u32)1);
        String* postOff = (String*)0;
        if (rb + (u32)1 < addr.byteLength())
            {
            postIndexed = true;
            String* tail = addr.substringFromByte(rb + (u32)1).trimmed();
            if (tail.hasPrefix(String.withCString(",")))
                tail = tail.substringFromByte((u32)1).trimmed();
            postOff = tail;
            }
        else if (ops.count() > (u32)2)
            {
            // `ldr lr, [ip], #4` — the bracket CLOSES before the comma, so the
            // offset is a separate operand rather than part of the address. It
            // has to be picked up here, or the instruction silently assembles
            // as a plain `[ip]` load and the pointer never advances.
            postIndexed = true;
            postOff = ((String*)ops.get((u32)2)).trimmed();
            }
        Array* parts = splitOperands(inner);
        if (postOff != (String*)0 && postOff.byteLength() > (u32)0)
            parts.add((Object*)postOff);
        if (parts.count() == (u32)0)
            {
            giveUp(mnem);
            return;
            }
        i32 rn = Arm32.regNumber(((String*)parts.get((u32)0)).trimmed());
        if (rn < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        bool load = b.byteAt((u32)0) == (u8)'l';
        bool byteOp = b.equals(String.withCString("ldrb")) || b.equals(String.withCString("strb"));
        bool plainLdrStr = b.equals(String.withCString("ldr")) || b.equals(String.withCString("str"));
        // A REGISTER offset, optionally shifted: `[r3, r4, lsl #2]`. Bit 25
        // selects it, and the shift sits where a data-processing operand's
        // would.
        if (parts.count() > (u32)1 && !Arm32.isImmediate(((String*)parts.get((u32)1)).trimmed()))
            {
            i32 rm = Arm32.regNumber(((String*)parts.get((u32)1)).trimmed());
            if (rm < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            u32 kind = (u32)0;
            u32 amt = (u32)0;
            if (parts.count() > (u32)2)
                {
                String* sh = ((String*)parts.get((u32)2)).trimmed();
                u32 sp2 = sh.byteIndexOf(String.withCString(" "), (u32)0);
                if (sp2 == String.notFound())
                    {
                    giveUp(mnem);
                    return;
                    }
                kind = Arm32.shiftKind(sh.substringBytes((u32)0, sp2));
                amt = Arm32.immediateValue(sh.substringFromByte(sp2 + (u32)1).trimmed()) & (u32)31;
                }
            // The half and signed forms encode differently — refused rather
            // than assembled as a word access.
            if (!byteOp && !plainLdrStr)
                {
                giveUp(mnem);
                return;
                }
            u32 w = ((u32)_cond << (u32)28) | ((u32)1 << (u32)26) | ((u32)1 << (u32)25) | ((u32)1 << (u32)23);
            if (!postIndexed)
                w = w | ((u32)1 << (u32)24);
            if (writeback)
                w = w | ((u32)1 << (u32)21);
            if (byteOp)
                w = w | ((u32)1 << (u32)22);
            if (load)
                w = w | ((u32)1 << (u32)20);
            word(w | ((u32)rn << (u32)16) | ((u32)rt << (u32)12) | (amt << (u32)7) | (kind << (u32)5) | (u32)rm);
            return;
            }
        i32 off = (i32)0;
        if (parts.count() > (u32)1)
            {
            String* o = ((String*)parts.get((u32)1)).trimmed();
            if (!Arm32.isImmediate(o))
                {
                giveUp(mnem);
                return;
                }
            off = (i32)Arm32.immediateValue(o);
            }
        if (writeback || postIndexed)
            {
            // The immediate-offset indexed forms share one encoding with the
            // plain one: P says pre/post and W says write the base back.
            u32 up = off >= (i32)0 ? (u32)1 : (u32)0;
            u32 mag = off >= (i32)0 ? (u32)off : (u32)(-off);
            if (!byteOp && !plainLdrStr)
                {
                giveUp(mnem);
                return;
                }
            u32 w = ((u32)_cond << (u32)28) | ((u32)1 << (u32)26) | (up << (u32)23);
            if (!postIndexed)
                w = w | ((u32)1 << (u32)24) | ((u32)1 << (u32)21);
            if (byteOp)
                w = w | ((u32)1 << (u32)22);
            if (load)
                w = w | ((u32)1 << (u32)20);
            word(w | ((u32)rn << (u32)16) | ((u32)rt << (u32)12) | (mag & (u32)$FFF));
            return;
            }
        if (b.equals(String.withCString("ldrb")) || b.equals(String.withCString("strb")))
            {
            loadStore(_cond, load, true, (u32)rt, (u32)rn, off);
            return;
            }
        if (b.equals(String.withCString("ldrh")) || b.equals(String.withCString("strh")))
            {
            loadStoreHalf(_cond, load, (u32)rt, (u32)rn, off, false, true);
            return;
            }
        if (b.equals(String.withCString("ldrsh")))
            {
            loadStoreHalf(_cond, true, (u32)rt, (u32)rn, off, true, true);
            return;
            }
        if (b.equals(String.withCString("ldrsb")))
            {
            loadStoreHalf(_cond, true, (u32)rt, (u32)rn, off, true, false);
            return;
            }
        loadStore(_cond, load, false, (u32)rt, (u32)rn, off);
        }

    // A bare shift is a `mov` with the shift applied to the source.
    void encodeShift(String* b, Array* ops, String* mnem)
        {
        if (ops.count() < (u32)3)
            {
            giveUp(mnem);
            return;
            }
        i32 rd = Arm32.regNumber((String*)ops.get((u32)0));
        i32 rm = Arm32.regNumber((String*)ops.get((u32)1));
        String* amt = (String*)ops.get((u32)2);
        if (rd < (i32)0 || rm < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        u32 kind = Arm32.shiftKind(b);
        if (Arm32.isImmediate(amt))
            {
            dataProcessing(_cond, (i32)13, _setFlags, (u32)rd, (u32)0, (i32)-1,
                           (u32)rm, kind, Arm32.immediateValue(amt) & (u32)31);
            return;
            }
        i32 rs = Arm32.regNumber(amt);
        if (rs < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        // Register-controlled shift: bit 4 set, Rs in bits 11-8.
        word(((u32)_cond << 28) | ((u32)13 << 21) | ((u32)rd << 12) | ((u32)rs << 8) | (kind << 5) | ((u32)1 << 4) | (u32)rm);
        }

    // `p15` / `c13` — a coprocessor or coprocessor-register number, which is
    // written with a letter prefix that carries no information.
    static u32 cpNumber(String* t, u8 prefix)
        {
        if (t.byteLength() > (u32)0 && t.byteAt((u32)0) == prefix)
            return Arm32.decimalValue(t.substringFromByte((u32)1));
        return Arm32.decimalValue(t);
        }

    static u32 shiftKind(String* b)
        {
        if (b.equals(String.withCString("lsl")))
            return (u32)0;
        if (b.equals(String.withCString("lsr")))
            return (u32)1;
        if (b.equals(String.withCString("asr")))
            return (u32)2;
        return (u32)3; // ror
        }

    // `mov rD, <op2>`, `cmp rN, <op2>`, `add rD, rN, <op2>` — the three arities
    // the data-processing forms come in, told apart by which fields the opcode
    // actually uses.
    void encodeDataProcessing(i32 dp, Array* ops, String* mnem)
        {
        bool noDest = (dp == (i32)8 || dp == (i32)9 || dp == (i32)10 || dp == (i32)11);
        bool noFirst = (dp == (i32)13 || dp == (i32)15);
        if (ops.count() < (u32)2)
            {
            giveUp(mnem);
            return;
            }
        u32 rd = (u32)0;
        u32 rn = (u32)0;
        u32 opIdx = (u32)1;
        if (noDest)
            {
            i32 n = Arm32.regNumber((String*)ops.get((u32)0));
            if (n < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            rn = (u32)n;
            }
        else if (noFirst)
            {
            i32 d = Arm32.regNumber((String*)ops.get((u32)0));
            if (d < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            rd = (u32)d;
            }
        else
            {
            if (ops.count() < (u32)3)
                {
                giveUp(mnem);
                return;
                }
            i32 d = Arm32.regNumber((String*)ops.get((u32)0));
            i32 n = Arm32.regNumber((String*)ops.get((u32)1));
            if (d < (i32)0 || n < (i32)0)
                {
                giveUp(mnem);
                return;
                }
            rd = (u32)d;
            rn = (u32)n;
            opIdx = (u32)2;
            }
        String* op2 = (String*)ops.get(opIdx);
        bool flags = _setFlags || noDest;
        if (Arm32.isImmediate(op2))
            {
            i32 enc = Arm32.encodeImm12(Arm32.immediateValue(op2));
            if (enc < (i32)0)
                {
                giveUp(String.withCString("immediate not encodable"));
                return;
                }
            dataProcessing(_cond, dp, flags, rd, rn, enc, (u32)0, (u32)0, (u32)0);
            return;
            }
        // A shifted register: `r1, lsl #3`, which arrives as its own operand.
        u32 kind = (u32)0;
        u32 amt = (u32)0;
        i32 rm = Arm32.regNumber(op2);
        if (rm < (i32)0)
            {
            giveUp(mnem);
            return;
            }
        if (ops.count() > opIdx + (u32)1)
            {
            String* sh = (String*)ops.get(opIdx + (u32)1);
            u32 sp2 = sh.indexOfByte((u8)' ');
            if (sp2 == String.notFound())
                {
                giveUp(mnem);
                return;
                }
            kind = Arm32.shiftKind(sh.substringBytes((u32)0, sp2));
            String* by = sh.substringFromByte(sp2 + (u32)1).trimmed();
            if (!Arm32.isImmediate(by))
                {
                // A REGISTER-specified shift (`orr r1, r1, r0, lsr r3`): Rs
                // sits in bits 11-8 and bit 4 says so. Reading it as an
                // immediate silently shifted by the register NUMBER — `lsr r3`
                // became `lsr #3`, which assembles, runs, and is wrong.
                i32 rs = Arm32.regNumber(by);
                if (rs < (i32)0)
                    {
                    giveUp(mnem);
                    return;
                    }
                word(((u32)_cond << (u32)28) | ((u32)dp << (u32)21) | (flags ? ((u32)1 << (u32)20) : (u32)0) | (rn << (u32)16) | (rd << (u32)12) | ((u32)rs << (u32)8) | (kind << (u32)5) | ((u32)1 << (u32)4) | (u32)rm);
                return;
                }
            amt = Arm32.immediateValue(by) & (u32)31;
            }
        dataProcessing(_cond, dp, flags, rd, rn, (i32)-1, (u32)rm, kind, amt);
        }

    // ── VFP / NEON ───────────────────────────────────────────────────────
    // The floating-point subset the back end emits. A single-precision
    // register splits into (D, M): the low four bits go where a core register
    // number would, the top bit into a field of its own — and the two swap
    // places between the single and double forms, which is the whole trick to
    // getting these encodings right.
    static bool isVfpMnemonic(String* m)
        {
        return m.byteLength() > (u32)0 && m.byteAt((u32)0) == (u8)'v';
        }

    // `s5` -> 5 with `single` true; `d3` -> 3 with it false.
    static i32 vfpRegNumber(String* t, Array* singleOut)
        {
        if (t == 0 || t.byteLength() < (u32)2)
            return (i32)-1;
        u8 k = t.byteAt((u32)0);
        if (k != (u8)'s' && k != (u8)'d')
            return (i32)-1;
        u32 v = (u32)0;
        for (u32 i = (u32)1; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (i32)-1;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        singleOut.add((Object*)Number.with(k == (u8)'s' ? (u32)1 : (u32)0));
        return (i32)v;
        }

    // The mnemonic's `.f32` / `.f64` / `.s32` suffixes, split off the base.
    Array* splitDotted(String* m)
        {
        Array* parts = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= m.byteLength(); i = i + (u32)1)
            {
            if (i == m.byteLength() || m.byteAt(i) == (u8)'.')
                {
                parts.add((Object*)m.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        return parts;
        }

    bool encodeVfp(String* mnem, Array* ops)
        {
        Array* parts = splitDotted(mnem);
        String* b = (String*)parts.get((u32)0);
        bool dbl = parts.count() > (u32)1 && ((String*)parts.get((u32)1)).equals(String.withCString("f64"));
        if (b.equals(String.withCString("vldr")) || b.equals(String.withCString("vstr")))
            return vfpLoadStore(b.equals(String.withCString("vldr")), ops);
        if (b.equals(String.withCString("vld1")) || b.equals(String.withCString("vst1")))
            return neonListLoadStore(b.equals(String.withCString("vld1")), parts, ops);
        if (b.equals(String.withCString("vdup")))
            return neonDup(parts, ops);
        if (b.equals(String.withCString("vpaddl")))
            return neonPaddl(parts, ops);
        // `vmov.32 rD, dN[i]` — a lane out of a NEON register. Told from the VFP
        // `vmov` by its type suffix, which the scalar form never carries.
        if (b.equals(String.withCString("vmov")) && parts.count() > (u32)1)
            return neonMoveLane(parts, ops);
        if (neonThreeSame(b, parts, ops))
            return true;
        if (b.equals(String.withCString("vmov")))
            return vfpMove(ops);
        if (b.equals(String.withCString("vcvt")))
            return vfpConvert(parts, ops);
        if (b.equals(String.withCString("vcmp")))
            return vfpCompare(dbl, ops);
        if (b.equals(String.withCString("vmrs")) || b.equals(String.withCString("vmsr")))
            return vfpStatus(b.equals(String.withCString("vmrs")), ops);
        if (b.equals(String.withCString("vneg")) || b.equals(String.withCString("vsqrt")))
            return vfpArithmetic((u32)0, dbl, b, ops);
        u32 bits = Arm32.vfpArithBits(b);
        if (bits == (u32)$FFFFFFFF)
            return false;
        return vfpArithmetic(bits, dbl, b, ops);
        }

    // The three-bit opcode a VFP data-processing instruction carries, in the
    // order the encoding uses (not the order they are written).
    // The opcode is NOT a contiguous field: bits 23, 21 and 20 select the
    // operation and bit 22 is the destination register's high bit, so the
    // encoding is given here as the word to OR in rather than as a number to
    // shift. Bit 6 is the last opcode bit (add vs subtract).
    static u32 vfpArithBits(String* b)
        {
        if (b.equals(String.withCString("vmul")))
            return (u32)1 << 21;
        if (b.equals(String.withCString("vadd")))
            return ((u32)1 << 21) | ((u32)1 << 20);
        if (b.equals(String.withCString("vsub")))
            return ((u32)1 << 21) | ((u32)1 << 20) | ((u32)1 << 6);
        if (b.equals(String.withCString("vdiv")))
            return (u32)1 << 23;
        if (b.equals(String.withCString("vmla")))
            return (u32)0;
        return (u32)$FFFFFFFF;
        }

    // vldr/vstr: `<reg>, [rN, #±off]`, the offset in WORDS (single) or
    // double-words — it is always a multiple of four, encoded /4.
    bool vfpLoadStore(bool load, Array* ops)
        {
        if (ops.count() < (u32)2)
            return false;
        Array* sg = new Array();
        i32 vd = Arm32.vfpRegNumber((String*)ops.get((u32)0), sg);
        if (vd < (i32)0)
            return false;
        bool single = ((Number*)sg.get((u32)0)).asU32() == (u32)1;
        String* addr = (String*)ops.get((u32)1);
        if (addr.byteLength() < (u32)2 || addr.byteAt((u32)0) != (u8)'[')
            return false;
        Array* parts = splitOperands(addr.substringBytes((u32)1, addr.byteLength() - (u32)2));
        i32 rn = Arm32.regNumber(((String*)parts.get((u32)0)).trimmed());
        if (rn < (i32)0)
            return false;
        i32 off = (i32)0;
        if (parts.count() > (u32)1)
            {
            String* o = ((String*)parts.get((u32)1)).trimmed();
            if (!Arm32.isImmediate(o))
                return false;
            off = (i32)Arm32.immediateValue(o);
            }
        u32 up = off >= (i32)0 ? (u32)1 : (u32)0;
        u32 mag = (off >= (i32)0 ? (u32)off : (u32)(-off)) >> 2;
        u32 d = single ? ((u32)vd & (u32)1) : (((u32)vd >> 4) & (u32)1);
        u32 vdField = single ? ((u32)vd >> 1) : ((u32)vd & (u32)$F);
        u32 w = (u32)$E << 28 | ((u32)$D << 24) | (up << 23) | (d << 22) | ((load ? (u32)1 : (u32)0) << 20) | ((u32)rn << 16) | (vdField << 12) | ((single ? (u32)$A : (u32)$B) << 8) | (mag & (u32)$FF);
        word(w);
        return true;
        }

    // ── NEON integer ─────────────────────────────────────────────────────
    // The auto-vectoriser's output. A Q register is a PAIR of D registers, so
    // `q10` is D20 and every field below is a D-register number split the way
    // the VFP double forms split theirs: bit 4 to the D/N/M flag, the low four
    // to the field. -1 for anything that is not a NEON register; `quadOut`
    // receives 1 for a `q`.
    static i32 neonRegNumber(String* t, Array* quadOut)
        {
        if (t == 0 || t.byteLength() < (u32)2)
            return (i32)-1;
        u8 k = t.byteAt((u32)0);
        if (k != (u8)'q' && k != (u8)'d')
            return (i32)-1;
        u32 v = (u32)0;
        for (u32 i = (u32)1; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (i32)-1;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        quadOut.add((Object*)Number.with(k == (u8)'q' ? (u32)1 : (u32)0));
        return (i32)(k == (u8)'q' ? v * (u32)2 : v);
        }

    // The element size a `.i32` / `.s16` / `.u8` suffix names.
    static i32 neonSizeBits(String* ty)
        {
        if (ty.byteLength() < (u32)2)
            return (i32)-1;
        String* bits = ty.substringFromByte((u32)1); // drop the i/s/u/f
        if (bits.equals(String.withCString("8")))
            return (i32)0;
        if (bits.equals(String.withCString("16")))
            return (i32)1;
        if (bits.equals(String.withCString("32")))
            return (i32)2;
        if (bits.equals(String.withCString("64")))
            return (i32)3;
        return (i32)-1;
        }

    // `<op>.<ty> <Vd>, <Vn>, <Vm>` — the "three registers of the same length"
    // family, which is ONE encoding with an opcode, a U bit and bit 4 selecting
    // the operation:
    //
    //   1111 001 U 0 D size Vn Vd opc N Q M b4 Vm
    //
    // Only the forms the back end emits are listed, and every row appears in
    // tests/asm-arm32/neon.s: an encoding no test covers is a liability rather
    // than a feature. (The bitwise ops are the trap — their "size" field selects
    // WHICH operation: 00 VAND, 01 VBIC, 10 VORR, 11 VORN.)
    bool neonThreeSame(String* b, Array* parts, Array* ops)
        {
        u32 u = (u32)0;
        u32 opc = (u32)0;
        u32 b4 = (u32)0;
        bool sizeFromSuffix = true;
        bool dOnly = false;
        if (b.equals(String.withCString("vadd")))
            {
            u = (u32)0;
            opc = (u32)8;
            b4 = (u32)0;
            }
        else if (b.equals(String.withCString("vsub")))
            {
            u = (u32)1;
            opc = (u32)8;
            b4 = (u32)0;
            }
        else if (b.equals(String.withCString("vmul")))
            {
            u = (u32)0;
            opc = (u32)9;
            b4 = (u32)1;
            }
        else if (b.equals(String.withCString("vceq")))
            {
            u = (u32)1;
            opc = (u32)8;
            b4 = (u32)1;
            }
        else if (b.equals(String.withCString("vmax")))
            {
            u = (u32)0;
            opc = (u32)6;
            b4 = (u32)0;
            }
        else if (b.equals(String.withCString("vmin")))
            {
            u = (u32)0;
            opc = (u32)6;
            b4 = (u32)1;
            }
        else if (b.equals(String.withCString("vpadd")))
            {
            u = (u32)0;
            opc = (u32)$B;
            b4 = (u32)1;
            dOnly = true;
            }
        else if (b.equals(String.withCString("vpmax")))
            {
            u = (u32)0;
            opc = (u32)$A;
            b4 = (u32)0;
            dOnly = true;
            }
        else if (b.equals(String.withCString("vpmin")))
            {
            u = (u32)0;
            opc = (u32)$A;
            b4 = (u32)1;
            dOnly = true;
            }
        else if (b.equals(String.withCString("vand")))
            {
            u = (u32)0;
            opc = (u32)1;
            b4 = (u32)1;
            sizeFromSuffix = false;
            }
        else if (b.equals(String.withCString("vorr")))
            {
            u = (u32)0;
            opc = (u32)1;
            b4 = (u32)1;
            sizeFromSuffix = false;
            }
        else
            return false;

        // A `.f32` suffix means the FLOATING-point form, a different encoding —
        // leave it to the VFP path rather than assembling nonsense.
        if (parts.count() > (u32)1 && ((String*)parts.get((u32)1)).hasPrefix(String.withCString("f")))
            return false;
        u32 size = (u32)0;
        if (sizeFromSuffix)
            {
            if (parts.count() < (u32)2)
                return false;
            i32 s = Arm32.neonSizeBits((String*)parts.get((u32)1));
            if (s < (i32)0)
                return false;
            size = (u32)s;
            }
        else
            {
            size = b.equals(String.withCString("vorr")) ? (u32)2 : (u32)0;
            }
        if (ops.count() < (u32)3)
            return false;
        Array* q1 = new Array();
        Array* q2 = new Array();
        Array* q3 = new Array();
        i32 vd = Arm32.neonRegNumber((String*)ops.get((u32)0), q1);
        i32 vn = Arm32.neonRegNumber((String*)ops.get((u32)1), q2);
        i32 vm = Arm32.neonRegNumber((String*)ops.get((u32)2), q3);
        if (vd < (i32)0 || vn < (i32)0 || vm < (i32)0)
            return false;
        u32 qd = ((Number*)q1.get((u32)0)).asU32();
        if (qd != ((Number*)q2.get((u32)0)).asU32())
            return false;
        if (qd != ((Number*)q3.get((u32)0)).asU32())
            return false;
        if (dOnly && qd == (u32)1)
            return false; // pairwise ops are D-only
        word((u32)$F2000000 | (u << 24) | ((((u32)vd >> 4) & (u32)1) << 22) | (size << 20) | (((u32)vn & (u32)$F) << 16) | (((u32)vd & (u32)$F) << 12) | (opc << 8) | ((((u32)vn >> 4) & (u32)1) << 7) | (qd << 6) | ((((u32)vm >> 4) & (u32)1) << 5) | (b4 << 4) | ((u32)vm & (u32)$F));
        return true;
        }

    // `vdup.32 q10, r0` — broadcast a core register across every lane. The
    // element size is TWO bits in two different places (B at 22, E at 5), which
    // is why it is a table rather than a shift.
    bool neonDup(Array* parts, Array* ops)
        {
        if (parts.count() < (u32)2 || ops.count() < (u32)2)
            return false;
        String* sz = (String*)parts.get((u32)1);
        u32 bBit = (u32)0;
        u32 eBit = (u32)0;
        if (sz.equals(String.withCString("8")))
            {
            bBit = (u32)1;
            eBit = (u32)0;
            }
        else if (sz.equals(String.withCString("16")))
            {
            bBit = (u32)0;
            eBit = (u32)1;
            }
        else if (sz.equals(String.withCString("32")))
            {
            bBit = (u32)0;
            eBit = (u32)0;
            }
        else
            return false;
        Array* q1 = new Array();
        i32 vd = Arm32.neonRegNumber((String*)ops.get((u32)0), q1);
        i32 rt = Arm32.regNumber((String*)ops.get((u32)1));
        if (vd < (i32)0 || rt < (i32)0)
            return false;
        word((u32)$EE800B10 | (bBit << 22) | (((Number*)q1.get((u32)0)).asU32() << 21) | (((u32)vd & (u32)$F) << 16) | ((u32)rt << 12) | ((((u32)vd >> 4) & (u32)1) << 7) | (eBit << 5));
        return true;
        }

    // `vpaddl.u16 q10, q9` — pairwise add long, each pair of lanes summed into
    // one of twice the width.
    bool neonPaddl(Array* parts, Array* ops)
        {
        if (parts.count() < (u32)2 || ops.count() < (u32)2)
            return false;
        String* ty = (String*)parts.get((u32)1);
        bool uns = ty.hasPrefix(String.withCString("u"));
        if (!uns && !ty.hasPrefix(String.withCString("s")))
            return false;
        i32 s = Arm32.neonSizeBits(ty);
        if (s < (i32)0)
            return false;
        Array* q1 = new Array();
        Array* q2 = new Array();
        i32 vd = Arm32.neonRegNumber((String*)ops.get((u32)0), q1);
        i32 vm = Arm32.neonRegNumber((String*)ops.get((u32)1), q2);
        if (vd < (i32)0 || vm < (i32)0)
            return false;
        u32 qd = ((Number*)q1.get((u32)0)).asU32();
        if (qd != ((Number*)q2.get((u32)0)).asU32())
            return false;
        word((u32)$F3B00200 | ((((u32)vd >> 4) & (u32)1) << 22) | ((u32)s << 18) | (((u32)vd & (u32)$F) << 12) | ((uns ? (u32)1 : (u32)0) << 7) | (qd << 6) | ((((u32)vm >> 4) & (u32)1) << 5) | ((u32)vm & (u32)$F));
        return true;
        }

    // `vmov.32 r0, d20[0]` — one lane out to a core register. Only the .32 form
    // is emitted, and only that way round; the other widths index the lane
    // across more than one field and nothing here needs them.
    bool neonMoveLane(Array* parts, Array* ops)
        {
        if (parts.count() < (u32)2 || ops.count() < (u32)2)
            return false;
        if (!((String*)parts.get((u32)1)).equals(String.withCString("32")))
            return false;
        i32 rt = Arm32.regNumber((String*)ops.get((u32)0));
        if (rt < (i32)0)
            return false;
        String* src = (String*)ops.get((u32)1);
        u32 lb = src.indexOfByte((u8)'[');
        if (lb == String.notFound())
            return false;
        if (src.byteAt(src.byteLength() - (u32)1) != (u8)']')
            return false;
        Array* q1 = new Array();
        i32 vn = Arm32.neonRegNumber(src.substringBytes((u32)0, lb), q1);
        if (vn < (i32)0)
            return false;
        if (((Number*)q1.get((u32)0)).asU32() == (u32)1)
            return false; // D only
        u32 idx = Arm32.decimalValue(src.substringBytes(lb + (u32)1,
                                                        src.byteLength() - lb - (u32)2));
        if (idx > (u32)1)
            return false;
        word((u32)$EE100B10 | (idx << 21) | (((u32)vn & (u32)$F) << 16) | ((u32)rt << 12) | ((((u32)vn >> 4) & (u32)1) << 7));
        return true;
        }

    // `vld1.8 {d30, d31}, [r0]!` — NEON "multiple single elements". The back
    // end emits exactly the two-register form, for block copies; the one- and
    // four-register forms are here because the list length is the only thing
    // that changes and all three are checked against `as`.
    //
    //   1111 0100 0 D L 0  Rn  Vd  type  size align  Rm
    //
    // `type` is the LIST LENGTH, and not in a sane order: 1 reg is 0b0111, 2 is
    // 0b1010, 4 is 0b0010. `Rm` is the writeback selector rather than a
    // register — 0b1101 (sp) means "advance by the transfer size", 0b1111 (pc)
    // means "do not". The three-register form is deliberately absent: nothing
    // emits it, and an encoding no test covers is a liability, not a feature.
    //
    // This was MISSING from the subset until 2026-08-14, and every arm9 program
    // that copies a struct emits it. The differential could not see it because
    // its corpus was four hand-written files — the same trap this project keeps
    // hitting: green because nothing exercised it.
    bool neonListLoadStore(bool load, Array* parts, Array* ops)
        {
        if (ops.count() < (u32)2 || parts.count() < (u32)2)
            return false;
        String* sz = (String*)parts.get((u32)1);
        u32 size = (u32)0;
        if (sz.equals(String.withCString("8")))
            size = (u32)0;
        else if (sz.equals(String.withCString("16")))
            size = (u32)1;
        else if (sz.equals(String.withCString("32")))
            size = (u32)2;
        else if (sz.equals(String.withCString("64")))
            size = (u32)3;
        else
            return false;

        // The register list. `{d30, d31}` is ONE operand, so its commas are
        // split here rather than by the operand splitter.
        String* list = (String*)ops.get((u32)0);
        if (list.byteLength() < (u32)2)
            return false;
        if (list.byteAt((u32)0) != (u8)'{')
            return false;
        if (list.byteAt(list.byteLength() - (u32)1) != (u8)'}')
            return false;
        Array* items = list.substringBytes((u32)1, list.byteLength() - (u32)2).splitOnByte((u8)',');
        Array* regs = new Array();
        for (u32 i = (u32)0; i < items.count(); i = i + (u32)1)
            {
            Array* sg = new Array();
            i32 r = Arm32.vfpRegNumber(((String*)items.get(i)).trimmed(), sg);
            if (r < (i32)0)
                return false;
            if (((Number*)sg.get((u32)0)).asU32() == (u32)1)
                return false; // D only
            regs.add((Object*)Number.with((u32)r));
            }
        u32 type = (u32)0;
        if (regs.count() == (u32)1)
            type = (u32)7;
        else if (regs.count() == (u32)2)
            type = (u32)$A;
        else if (regs.count() == (u32)4)
            type = (u32)2;
        else
            return false;
        // Consecutive, which the encoding assumes: only the first is named.
        for (u32 i = (u32)1; i < regs.count(); i = i + (u32)1)
            if (((Number*)regs.get(i)).asU32() != ((Number*)regs.get(i - (u32)1)).asU32() + (u32)1)
                return false;

        String* addr = (String*)ops.get((u32)1);
        bool writeback = false;
        if (addr.byteLength() > (u32)0 && addr.byteAt(addr.byteLength() - (u32)1) == (u8)'!')
            {
            writeback = true;
            addr = addr.substringBytes((u32)0, addr.byteLength() - (u32)1);
            }
        if (addr.byteLength() < (u32)2)
            return false;
        if (addr.byteAt((u32)0) != (u8)'[')
            return false;
        if (addr.byteAt(addr.byteLength() - (u32)1) != (u8)']')
            return false;
        i32 rn = Arm32.regNumber(addr.substringBytes((u32)1, addr.byteLength() - (u32)2).trimmed());
        if (rn < (i32)0)
            return false;

        u32 vd = ((Number*)regs.get((u32)0)).asU32();
        word((u32)$F4000000 | (((vd >> 4) & (u32)1) << 22) | (load ? ((u32)1 << 21) : (u32)0) | ((u32)rn << 16) | ((vd & (u32)$F) << 12) | (type << 8) | (size << 6) | (writeback ? (u32)$D : (u32)$F));
        return true;
        }

    // vmov between a core register and a single-precision one, either way.
    bool vfpMove(Array* ops)
        {
        if (ops.count() < (u32)2)
            return false;
        Array* sg1 = new Array();
        Array* sg2 = new Array();
        i32 a = Arm32.vfpRegNumber((String*)ops.get((u32)0), sg1);
        i32 b = Arm32.vfpRegNumber((String*)ops.get((u32)1), sg2);
        i32 ra = Arm32.regNumber((String*)ops.get((u32)0));
        i32 rb = Arm32.regNumber((String*)ops.get((u32)1));
        // vmov sN, rM  (to the FPU)
        if (a >= (i32)0 && rb >= (i32)0)
            {
            word((u32)$EE000A10 | ((((u32)a >> 1) & (u32)$F) << 16) | (((u32)a & (u32)1) << 7) | ((u32)rb << 12));
            return true;
            }
        // vmov rN, sM  (from it)
        if (ra >= (i32)0 && b >= (i32)0)
            {
            word((u32)$EE100A10 | ((((u32)b >> 1) & (u32)$F) << 16) | (((u32)b & (u32)1) << 7) | ((u32)ra << 12));
            return true;
            }
        return false;
        }

    bool vfpCompare(bool dbl, Array* ops)
        {
        if (ops.count() < (u32)2)
            return false;
        Array* s1 = new Array();
        Array* s2 = new Array();
        i32 vd = Arm32.vfpRegNumber((String*)ops.get((u32)0), s1);
        i32 vm = Arm32.vfpRegNumber((String*)ops.get((u32)1), s2);
        if (vd < (i32)0 || vm < (i32)0)
            return false;
        word((u32)$EEB40040 | vfpFields(vd, vm, (i32)0, dbl));
        return true;
        }

    // `vmrs APSR_nzcv, fpscr` and `vmsr fpscr, rN` — the two spellings that
    // reach here, and the only two the back end emits.
    bool vfpStatus(bool toCore, Array* ops)
        {
        if (ops.count() < (u32)2)
            return false;
        if (toCore)
            {
            String* dst = (String*)ops.get((u32)0);
            u32 rt = dst.equals(String.withCString("APSR_nzcv")) ? (u32)15
                                                                 : (u32)Arm32.regNumber(dst);
            word((u32)$EEF10A10 | (rt << 12));
            return true;
            }
        i32 rt = Arm32.regNumber((String*)ops.get((u32)1));
        if (rt < (i32)0)
            return false;
        word((u32)$EEE10A10 | ((u32)rt << 12));
        return true;
        }

    // The register fields, which move depending on precision: a single's low
    // bit is the D/M flag and its top four bits the field; a double's are the
    // other way round.
    u32 vfpFields(i32 vd, i32 vm, i32 vn, bool dbl)
        {
        u32 d = dbl ? (((u32)vd >> 4) & (u32)1) : ((u32)vd & (u32)1);
        u32 vdF = dbl ? ((u32)vd & (u32)$F) : ((u32)vd >> 1);
        u32 m = dbl ? (((u32)vm >> 4) & (u32)1) : ((u32)vm & (u32)1);
        u32 vmF = dbl ? ((u32)vm & (u32)$F) : ((u32)vm >> 1);
        u32 n = dbl ? (((u32)vn >> 4) & (u32)1) : ((u32)vn & (u32)1);
        u32 vnF = dbl ? ((u32)vn & (u32)$F) : ((u32)vn >> 1);
        // Bits 11-8 are the coprocessor field: 0b1010 for single precision,
        // 0b1011 for double. Every VFP data-processing form carries it, and
        // leaving it out is the difference between `vadd.f32` and nonsense.
        return (d << 22) | (vnF << 16) | (vdF << 12) | (n << 7) | (m << 5) | vmF | ((u32)$A << 8) | (dbl ? ((u32)1 << 8) : (u32)0);
        }

    bool vfpArithmetic(u32 opBits, bool dbl, String* b, Array* ops)
        {
        bool unary = b.equals(String.withCString("vneg")) || b.equals(String.withCString("vsqrt"));
        u32 need = unary ? (u32)2 : (u32)3;
        if (ops.count() < need)
            return false;
        Array* s1 = new Array();
        Array* s2 = new Array();
        Array* s3 = new Array();
        i32 vd = Arm32.vfpRegNumber((String*)ops.get((u32)0), s1);
        if (vd < (i32)0)
            return false;
        if (unary)
            {
            i32 vm = Arm32.vfpRegNumber((String*)ops.get((u32)1), s2);
            if (vm < (i32)0)
                return false;
            // vneg is 0xEEB10040-based, vsqrt 0xEEB100C0.
            u32 base = b.equals(String.withCString("vneg")) ? (u32)$EEB10040 : (u32)$EEB100C0;
            word(base | vfpFields(vd, vm, (i32)0, dbl));
            return true;
            }
        i32 vn = Arm32.vfpRegNumber((String*)ops.get((u32)1), s2);
        i32 vm = Arm32.vfpRegNumber((String*)ops.get((u32)2), s3);
        if (vn < (i32)0 || vm < (i32)0)
            return false;
        word((u32)$EE000000 | opBits | vfpFields(vd, vm, vn, dbl));
        return true;
        }

    // vcvt between the two float widths, and between float and integer.
    bool vfpConvert(Array* parts, Array* ops)
        {
        if (parts.count() < (u32)3 || ops.count() < (u32)2)
            return false;
        String* to = (String*)parts.get((u32)1);
        String* from = (String*)parts.get((u32)2);
        Array* s1 = new Array();
        Array* s2 = new Array();
        i32 vd = Arm32.vfpRegNumber((String*)ops.get((u32)0), s1);
        i32 vm = Arm32.vfpRegNumber((String*)ops.get((u32)1), s2);
        if (vd < (i32)0 || vm < (i32)0)
            return false;
        bool toF64 = to.equals(String.withCString("f64"));
        bool fromF64 = from.equals(String.withCString("f64"));
        bool toF32 = to.equals(String.withCString("f32"));
        bool fromF32 = from.equals(String.withCString("f32"));
        if ((toF64 && fromF32) || (toF32 && fromF64))
            {
            // f32<->f64: the source precision picks the encoding's sz bit and
            // the DESTINATION is the other width, so the fields are mixed.
            u32 d = toF64 ? (((u32)vd >> 4) & (u32)1) : ((u32)vd & (u32)1);
            u32 vdF = toF64 ? ((u32)vd & (u32)$F) : ((u32)vd >> 1);
            u32 m = fromF64 ? (((u32)vm >> 4) & (u32)1) : ((u32)vm & (u32)1);
            u32 vmF = fromF64 ? ((u32)vm & (u32)$F) : ((u32)vm >> 1);
            word((u32)$EEB700C0 | ((u32)$A << 8) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (fromF64 ? ((u32)1 << 8) : (u32)0));
            return true;
            }
        bool toInt = to.equals(String.withCString("s32")) || to.equals(String.withCString("u32"));
        if (toInt)
            {
            // float -> int, round toward zero: opc2 = 101 (signed) / 100.
            bool sgn = to.equals(String.withCString("s32"));
            u32 d = (u32)vd & (u32)1;
            u32 vdF = (u32)vd >> 1;
            u32 m = fromF64 ? (((u32)vm >> 4) & (u32)1) : ((u32)vm & (u32)1);
            u32 vmF = fromF64 ? ((u32)vm & (u32)$F) : ((u32)vm >> 1);
            word((u32)$EEBC00C0 | ((u32)$A << 8) | ((sgn ? (u32)1 : (u32)0) << 16) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (fromF64 ? ((u32)1 << 8) : (u32)0));
            return true;
            }
        // int -> float: the SOURCE is the integer, in a single register.
        bool sgn = from.equals(String.withCString("s32"));
        u32 d = toF64 ? (((u32)vd >> 4) & (u32)1) : ((u32)vd & (u32)1);
        u32 vdF = toF64 ? ((u32)vd & (u32)$F) : ((u32)vd >> 1);
        u32 m = (u32)vm & (u32)1;
        u32 vmF = (u32)vm >> 1;
        word((u32)$EEB80040 | ((u32)$A << 8) | ((sgn ? (u32)1 : (u32)0) << 7) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (toF64 ? ((u32)1 << 8) : (u32)0));
        return true;
        }
    }
