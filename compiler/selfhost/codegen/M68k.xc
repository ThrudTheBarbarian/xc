// M68k.xc — the IR, as Motorola 68000/68030 assembly.
// =========================================================================
//
// self-hosting M15. The port of XTM68kBackend, for the Atari ST/TT. Third
// back end after the A9's (M9) and the host's (M14), and the first one to
// reuse [[Homing.xc]] — arm64 has its own allocator, but m68k, arm9 and x86_64
// all drive the shared XTHomingAllocator, so the port of that is already here.
//
// The oracle is `xtcg-68k -O0` over the same IR, byte for byte;
// `selfhost/tools/m68k-diff.sh` is the harness. -O0 because the optimiser is a
// separate port and already at parity, so what is compared is the CODE
// GENERATOR alone.
//
// Two things make this target read differently from the two before it. It is
// BIG-ENDIAN, so every initialiser image laid down in the IR's little-endian
// order has to be reversed on the way out — and a pointer, canonically 3 bytes
// on this platform, is zero-extended to 4 first. And its frame is a LINK A6
// frame: results live at negative offsets from a6, parameters at positive ones
// in the caller-pushed area, so a slot offset is signed and the two halves are
// addressed the same way.
//
// An opcode this slice does not emit yet is recorded BY NAME and the whole file
// refused (exit 3). A back end that quietly skipped an instruction would emit
// assembly that assembles cleanly and computes the wrong thing, which is the
// one failure this harness exists to prevent.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Ir.xc"
#import "Homing.xc"

class M68k
    {
    IRModule* _m;
    IRFunc* _fn;
    String* _out;
    u32 _cpu;        // 68000 or 68030
    bool _hardFloat; // 68881 FPU codegen rather than soft-float
    bool _pic;       // -mpic: the GOT/a5 model for >32KB 68000
    u32 _labelSeq;   // unique local labels, reset per MODULE
    bool _failed;
    String* _why;
    Array* _missing;

    void init(void)
        {
        _out = new String();
        _missing = new Array();
        _failed = false;
        _cpu = (u32)68000;
        _hardFloat = false;
        _pic = false;
        _labelSeq = (u32)0;
        }

    void setCpu(u32 c)
        {
        _cpu = c;
        }
    void setHardFloat(bool v)
        {
        _hardFloat = v;
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
    Array* missing(void)
        {
        return _missing;
        }

    // Record an opcode this slice cannot emit — once each, so the harness's
    // report is the distinct work queue rather than a frequency count.
    void unsupported(String* op)
        {
        _failed = true;
        if (_why == (String*)0)
            _why = op;
        for (u32 i = (u32)0; i < _missing.count(); i = i + (u32)1)
            if (((String*)_missing.get(i)).equals(op))
                return;
        _missing.add((Object*)op);
        }

    // ── Type sizing, m68k-native ─────────────────────────────────────────
    // A type is its SPELLING here, so these read the text rather than a kind.
    static bool isPtrTy(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Ptr("));
        }

    static bool isAggTy(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Agg("));
        }

    static bool isMemTy(String* t)
        {
        return t != (String*)0 && t.equals(String.withCString("Mem"));
        }

    static bool isVecTy(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Vec("));
        }

    static bool isFloatTy(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
        }

    static bool isIntegerTy(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"));
        }

    static bool isSignedTy(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("I64"));
        }

    // The IR's own width for a scalar leaf — the FRONT END's half of the
    // type-width invariant, which is what an initialiser image is laid out in.
    static u32 irWidth(String* t)
        {
        if (t == (String*)0)
            return (u32)0;
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("Bool")))
            return (u32)1;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")))
            return (u32)2;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("F32")))
            return (u32)4;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")) || t.equals(String.withCString("F64")))
            return (u32)8;
        return (u32)0;
        }

    // The width THIS target lays a field out as. A pointer is 4 bytes here —
    // the back end's half of the invariant — and an aggregate is the sum of
    // its fields at these widths, never below its declared size.
    u32 fieldWidth(String* t)
        {
        if (t == (String*)0)
            return (u32)4;
        if (isPtrTy(t))
            return (u32)4;
        if (isAggTy(t))
            return aggSize(layoutOf(t));
        u32 w = irWidth(t);
        return w == (u32)0 ? (u32)1 : w;
        }

    u32 aggSize(IRLayout* l)
        {
        if (l == (IRLayout*)0)
            return (u32)1;
        u32 s = (u32)0;
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            s = s + fieldWidth(l.typeAt(i));
        // Honour the PADDED layout size: a struct's trailing alignment pad is
        // part of its footprint, so an array of it strides by the padded size.
        if (s < l.size())
            s = l.size();
        return s == (u32)0 ? (u32)1 : s;
        }

    // The RECORDED layout offset (blewit #5): the front end lays fields out
    // once — naturally aligned per target (cap 2 here: the m68k C ABI, and
    // what keeps a multi-byte field off an odd address) — and every backend
    // reads the same offsets. Widths still size the loads/stores.
    u32 fieldOffset(IRLayout* l, u32 idx)
        {
        if (l == (IRLayout*)0 || idx >= l.fieldCount())
            return aggSize(l);
        return l.offsetAt(idx);
        }

    // The pointee of a `Ptr(T, banked)` spelling: T ends at the first comma at
    // nesting depth zero, so a nested `Agg(...)` survives.
    static String* pointeeOf(String* t)
        {
        if (!isPtrTy(t))
            return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c == (u8)'(')
                depth = depth + (u32)1;
            else if (c == (u8)')')
                {
                if (depth == (u32)0)
                    return t.substringBytes((u32)4, i - (u32)4);
                depth = depth - (u32)1;
                }
            else if (c == (u8)',' && depth == (u32)0)
                return t.substringBytes((u32)4, i - (u32)4);
            }
        return (String*)0;
        }

    IRLayout* layoutOf(String* t)
        {
        if (!isAggTy(t))
            return (IRLayout*)0;
        u32 n = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c == (u8)')')
                break;
            if (c < (u8)'0' || c > (u8)'9')
                return (IRLayout*)0;
            n = n * (u32)10 + (u32)(c - (u8)'0');
            }
        if (_m == (IRModule*)0 || n >= _m.layouts().count())
            return (IRLayout*)0;
        return (IRLayout*)_m.layouts().get(n);
        }

    // ── Entry point ──────────────────────────────────────────────────────
    String* assembly(IRModule* m)
        {
        _m = m;
        _out = new String();
        _labelSeq = (u32)0;
        // The GOT/a5 model only matters on the 68000: the 68020 and up have
        // 32-bit PC-relative addressing, which is zero-relocation PIC with no
        // size limit.
        if (_cpu >= (u32)68020)
            _pic = false;
        _out.appendFormat("; xtcg-68k — Atari ST/TT (m%lu) assembly\n", _cpu);
        _out.appendFormat("; module \"%s\"\n\n", m.name().cString());
        _out.appendCString("\t.text\n\n");
        emitCrt0(m);
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            emitFunction((IRFunc*)m.funcs().get(f));
            _out.appendCString("\n");
            }
        emitRuntimeStubs(m);
        emitDataSection(m);
        return _out;
        }

    // GEMDOS enters at the first byte of TEXT, so a module with a `main` gets a
    // tiny entry wrapper: shrink the TPA, set up a stack, call main, Pterm with
    // its result as the exit code.
    void emitCrt0(IRModule* m)
        {
        bool hasMain = false;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            if (((IRFunc*)m.funcs().get(f)).name().equals(String.withCString("main")))
                hasMain = true;
        if (!hasMain)
            return;
        _out.appendCString("\t.globl\t_start\n_start:\n");
        // Mshrink the TPA down to basepage + text + data + bss + a stack
        // reserve, releasing the rest so the OS can reuse it — essential under
        // MiNT multitasking. The basepage pointer is at 4(sp) on entry.
        _out.appendCString("\tmove.l\t4(sp),a0\n");  // a0 = basepage
        _out.appendCString("\tmove.l\t12(a0),d0\n"); // p_tlen
        _out.appendCString("\tadd.l\t20(a0),d0\n");  // + p_dlen
        _out.appendCString("\tadd.l\t28(a0),d0\n");  // + p_blen
        _out.appendCString("\tadd.l\t#$4100,d0\n");  // + basepage + 16K stack
        _out.appendCString("\tmove.l\ta0,d1\n\tadd.l\td0,d1\n\tmove.l\td1,sp\n");
        _out.appendCString("\tmove.l\td0,-(sp)\n\tmove.l\ta0,-(sp)\n\tclr.w\t-(sp)\n");
        _out.appendCString("\tmove.w\t#$4a,-(sp)\n\ttrap\t#1\n\tlea\t12(sp),sp\n");
        if (_pic)
            {
            // Capture the runtime PC (bsr pushes it), then point a5 at the GOT
            // via a link-time-constant offset — no relocation.
            _out.appendCString("\tbsr\t.Lpicpc\n.Lpicpc:\n\tmove.l\t(sp)+,a5\n");
            _out.appendCString("\tadd.l\t#_GOT-.Lpicpc,a5\n");
            }
        _out.appendCString("\tjsr\tmain\n");
        _out.appendCString("\tmove.w\td0,-(sp)\t; exit code\n");
        _out.appendCString("\tmove.w\t#$4c,-(sp)\t; Pterm\n");
        _out.appendCString("\ttrap\t#1\n\n");
        }

    // ── Frame layout ─────────────────────────────────────────────────────
    //
    // A LINK A6 frame. Parameters sit in the caller-pushed area at POSITIVE
    // offsets from a6 (8, 12, …); pinned locals and value slots at NEGATIVE
    // ones. A slot offset is therefore signed, and both halves address the
    // same way.
    Map* _slot; // value -> signed a6 displacement
    i32 _frameSize;
    Homing* _homing;
    Array* _homeSaves; // callee-saved d-regs used, in pool order
    Map* _homeSaveOff; // reg name -> a6 displacement

    void assignSlots(IRFunc* fn)
        {
        _slot = new Map();
        // Parameters, left to right, in the caller's pushed area.
        i32 argOff = (i32)8;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            IRValue* p = (IRValue*)fn.params().get(i);
            String* t = p.ty();
            if (isMemTy(t))
                continue;
            _slot.set((Hashable*)p, (Object*)Number.withI32(argOff));
            // An aggregate is passed BY VALUE: the caller pushes the whole
            // struct, so it occupies its full 4-aligned size, not one long —
            // and AddrOf(param) then points at that pushed copy.
            if (isAggTy(t))
                argOff = argOff + (i32)((aggSize(layoutOf(t)) + (u32)3) & ~(u32)3);
            else if (isF64(t) || isI64(t))
                argOff = argOff + (i32)8;
            else
                argOff = argOff + (i32)4;
            }
        // Pinned locals occupy a fixed region just below a6. Their region is
        // recomputed at M68K widths: the front end's offsets assume the IR's
        // canonical 2/3-byte pointers, which UNDER-sizes a pointer array — an
        // address-taken `T@ a[3]` reserves 9 bytes but is addressed with the
        // 4-byte stride, so a[2] at +8 would overflow the slot and corrupt the
        // frame.
        u32 pinSize = (u32)0;
        Array* pinOff = new Array();
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            {
            IRPinned* p = (IRPinned*)fn.pinned().get(i);
            pinOff.add((Object*)Number.withU32(pinSize));
            u32 sz = fieldWidth(p.ty());
            pinSize = pinSize + ((sz + (u32)1) & ~(u32)1); // each entry even-aligned
            }
        pinSize = (pinSize + (u32)1) & ~(u32)1;
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            {
            IRPinned* p = (IRPinned*)fn.pinned().get(i);
            _slot.set((Hashable*)p.val(),
                      (Object*)Number.withI32(-(i32)pinSize + (i32)((Number*)pinOff.get(i)).asU32()));
            }
        // Value slots stack downward below the pinned region.
        i32 next = (i32)pinSize;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            next = slotsForList(bb.phis(), next);
            next = slotsForList(bb.insns(), next);
            }
        _frameSize = next;
        }

    i32 slotsForList(Array* list, i32 next)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            next = noteSlot(((IRInsn*)list.get(i)).res(), next);
        return next;
        }

    i32 noteSlot(IRValue* r, i32 next)
        {
        if (r == (IRValue*)0 || isMemTy(r.ty()))
            return next;
        if (_slot.get((Hashable*)r) != (Object*)0)
            return next;
        i32 sz = (i32)4;
        String* t = r.ty();
        if (isAggTy(t))
            sz = (i32)((aggSize(layoutOf(t)) + (u32)3) & ~(u32)3);
        else if (isF64(t) || isI64(t))
            sz = (i32)8; // two longs, like a double
        next = next + sz;
        _slot.set((Hashable*)r, (Object*)Number.withI32(-next));
        return next;
        }

    i32 slotOf(IRValue* v)
        {
        if (v == (IRValue*)0)
            return (i32)0;
        Object* o = _slot.get((Hashable*)v);
        return o == (Object*)0 ? (i32)0 : ((Number*)o).asI32();
        }

    String* homeOf(IRValue* v)
        {
        if (_homing == (Homing*)0 || v == (IRValue*)0)
            return (String*)0;
        return _homing.homeOf(v.pid());
        }

    // d5-d7 are callee-saved homes, persisted across the whole function. d3-d4
    // are offered as CALLER-saved: the allocator only puts a value there if its
    // live range crosses no call, so the hand-written helpers' d3/d4 clobbers
    // (__udivmod's remainder and counter, __fmt_double's precision) can never
    // corrupt a homed value and no prologue save is needed. Per-instruction
    // codegen uses only d0-d2 as scratch, so d3-d4 stay free.
    void assignHomes(IRFunc* fn)
        {
        Array* callee = new Array();
        callee.add((Object*)String.withCString("d5"));
        callee.add((Object*)String.withCString("d6"));
        callee.add((Object*)String.withCString("d7"));
        Array* caller = new Array();
        caller.add((Object*)String.withCString("d3"));
        caller.add((Object*)String.withCString("d4"));
        Homing* h = new Homing();
        // An ICmp fused into its branch and an address op folded into a memory
        // operand are never emitted, so a register homed for either is reserved
        // for nothing.
        Array* ex = _fusedCmp.allKeys();
        for (u32 i = (u32)0; i < ex.count(); i = i + (u32)1)
            h.exclude(((IRValue*)ex.get(i)).pid());
        Array* ef = _fold.allKeys();
        for (u32 i = (u32)0; i < ef.count(); i = i + (u32)1)
            h.exclude(((IRValue*)ef.get(i)).pid());
        // A walking pointer lives in an ADDRESS register, which this allocator
        // knows nothing about — homing it in a data register too would reserve
        // one for a value that is never read from it.
        Array* ep = _ptrAReg.allKeys();
        for (u32 i = (u32)0; i < ep.count(); i = i + (u32)1)
            h.exclude(((IRValue*)ep.get(i)).pid());
        // A 64-bit integer does not fit in a home. The allocator would happily
        // put one in d3, and every consumer reads it from its SLOT — so the
        // value is written to a register and read from memory nothing wrote:
        // the low half looks right and the high half is whatever the slot held.
        // i64 lives in a slot, like a double.
        for (u32 wb = (u32)0; wb < fn.blocks().count(); wb = wb + (u32)1)
            {
            IRBlock* wbb = (IRBlock*)fn.blocks().get(wb);
            for (u32 wi = (u32)0; wi < wbb.insns().count(); wi = wi + (u32)1)
                {
                IRInsn* win = (IRInsn*)wbb.insns().get(wi);
                if (win.res() != (IRValue*)0 && isI64(win.res().ty()))
                    h.exclude(win.res().pid());
                }
            }
        // A PARAMETER is not an instruction result, so the loop above never
        // sees one: `i64 add(i64 a, i64 b)` homed both into single registers
        // holding half of each.
        for (u32 wp = (u32)0; wp < fn.params().count(); wp = wp + (u32)1)
            {
            IRValue* wpv = (IRValue*)fn.params().get(wp);
            if (wpv != (IRValue*)0 && isI64(wpv.ty()))
                h.exclude(wpv.pid());
            }
        // Floats route to an EMPTY FP pool, so they stay in slots; pointers do
        // home in d-registers, and an operand load moves d to a for `(aN)`.
        h.run(fn, callee, caller, new Array(), new Array());
        _homing = h;
        _homeSaves = h.usedCalleeSaved();
        _homeSaveOff = new Map();
        for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
            {
            _frameSize = _frameSize + (i32)4;
            _homeSaveOff.set((Hashable*)(String*)_homeSaves.get(i),
                             (Object*)Number.withI32(-_frameSize));
            }
        // a2-a4 are callee-saved too. Walk the pool in order, not the map, so
        // the save list is stable regardless of which loop claimed which.
        _ptrARegSaves = new Array();
        _ptrARegSaveOff = new Map();
        Array* apool = new Array();
        apool.add((Object*)String.withCString("a2"));
        apool.add((Object*)String.withCString("a3"));
        apool.add((Object*)String.withCString("a4"));
        Array* used = _ptrAReg.allValues();
        for (u32 i = (u32)0; i < apool.count(); i = i + (u32)1)
            {
            String* r = (String*)apool.get(i);
            bool inUse = false;
            for (u32 k = (u32)0; k < used.count(); k = k + (u32)1)
                if (((String*)used.get(k)).equals(r))
                    inUse = true;
            if (!inUse)
                continue;
            _ptrARegSaves.add((Object*)r);
            _frameSize = _frameSize + (i32)4;
            _ptrARegSaveOff.set((Hashable*)r, (Object*)Number.withI32(-_frameSize));
            }
        }

    bool _dumpHomes;
    void setDumpHomes(bool v)
        {
        _dumpHomes = v;
        }

    void emitFunction(IRFunc* fn)
        {
        _fn = fn;
        assignSlots(fn);
        computeFusedCmps(fn); // all three feed the allocator's exclusion set
        computeFolds(fn);
        detectPointerIVs(fn);
        assignHomes(fn);
        // `link a6,#-N` and `d16(a6)` addressing use a 16-bit SIGNED
        // displacement, so a frame cannot exceed 32768 bytes. Fail loudly
        // rather than emit a displacement that wraps.
        if (_frameSize > (i32)32768)
            {
            unsupported(String.withCString("frame-budget"));
            return;
            }
        if (_dumpHomes)
            {
            Stdio.printf("%s: frame=%ld saved=[", fn.name().cString(), _frameSize);
            for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
                Stdio.printf("%s ", ((String*)_homeSaves.get(i)).cString());
            Stdio.printf("]\n");
            for (u32 v = (u32)0; v < fn.byId().count(); v = v + (u32)1)
                {
                IRValue* val = fn.valueWithId(v);
                if (val == (IRValue*)0)
                    continue;
                String* h = homeOf(val);
                if (h != (String*)0)
                    Stdio.printf("    %%%lu -> %s\n", v, h.cString());
                }
            }
        _out.appendFormat("\t.globl\t%s\n%s:\n", m68kSym(fn.name()).cString(), m68kSym(fn.name()).cString());
        _out.appendFormat("\tlink\ta6,#-%ld\n", _frameSize);
        for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
            {
            String* r = (String*)_homeSaves.get(i);
            _out.appendFormat("\tmove.l\t%s,%ld(a6)\n", r.cString(),
                              ((Number*)_homeSaveOff.get((Hashable*)r)).asI32());
            }
        for (u32 i = (u32)0; i < _ptrARegSaves.count(); i = i + (u32)1)
            {
            String* r = (String*)_ptrARegSaves.get(i);
            _out.appendFormat("\tmove.l\t%s,%ld(a6)\n", r.cString(),
                              ((Number*)_ptrARegSaveOff.get((Hashable*)r)).asI32());
            }
        // Seed homed PARAMETERS: they arrive on the caller's stack at a
        // positive a6 offset, so their home register would otherwise hold
        // whatever the caller left in it.
        seedHomedParams(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            emitBlock(fn, (IRBlock*)fn.blocks().get(b));
        }

    void seedHomedParams(IRFunc* fn)
        {
        // In value-id order, which is the order the reference's dictionary
        // iteration produces for the parameter ids it seeds.
        for (u32 vid = (u32)0; vid < fn.byId().count(); vid = vid + (u32)1)
            {
            IRValue* v = fn.valueWithId(vid);
            if (v == (IRValue*)0)
                continue;
            String* h = homeOf(v);
            if (h == (String*)0)
                continue;
            i32 off = slotOf(v);
            if (off > (i32)0)
                _out.appendFormat("\tmove.l\t%ld(a6),%s\n", off, h.cString());
            }
        }

    // A global (or function) named a0-a7/d0-d7/sp/pc/sr/ccr/usp/fp0-fp7
    // assembles as the REGISTER, not the symbol: the assembler tries register
    // names first, as Motorola syntax requires, so `lea a1,a0` silently used
    // address-register a1. Reserved names get a trailing '$' — user
    // identifiers cannot contain '$', and the method-mangled forms are
    // `Class$sel`, never `name$`, so the suffix cannot collide. Mirrors
    // m68kSym in XTM68kBackend.m; label and every reference route through it.
    String* m68kSym(String* name)
        {
        if (name == (String*)0)
            return name;
        u32 len = name.byteLength();
        if (len < (u32)2 || len > (u32)3)
            return name;
        u8 c0 = name.byteAt((u32)0) | (u8)$20; // ASCII lowercase
        u8 c1 = name.byteAt((u32)1) | (u8)$20;
        bool hit = false;
        if (len == (u32)2)
            {
            u8 d1 = name.byteAt((u32)1);
            if ((c0 == (u8)'a' || c0 == (u8)'d') && d1 >= (u8)'0' && d1 <= (u8)'7')
                hit = true;
            if (c0 == (u8)'s' && c1 == (u8)'p')
                hit = true;
            if (c0 == (u8)'p' && c1 == (u8)'c')
                hit = true;
            if (c0 == (u8)'s' && c1 == (u8)'r')
                hit = true;
            }
        else
            {
            u8 c2 = name.byteAt((u32)2) | (u8)$20;
            u8 d2 = name.byteAt((u32)2);
            if (c0 == (u8)'f' && c1 == (u8)'p' && d2 >= (u8)'0' && d2 <= (u8)'7')
                hit = true;
            if (c0 == (u8)'c' && c1 == (u8)'c' && c2 == (u8)'r')
                hit = true;
            if (c0 == (u8)'u' && c1 == (u8)'s' && c2 == (u8)'p')
                hit = true;
            }
        if (!hit)
            return name;
        String* m = String.withString(name);
        m.appendCString("$");
        return m;
        }

    String* blockLabel(IRFunc* fn, IRBlock* bb)
        {
        String* s = String.withCString(".");
        s.append(fn.name());
        s.appendCString("$");
        s.append(bb.name());
        return s;
        }

    void emitBlock(IRFunc* fn, IRBlock* bb)
        {
        _out.appendFormat("%s:\n", blockLabel(fn, bb).cString());
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            // A pointer-IV advance is DEFERRED past the loads that read the
            // pre-advance pointer, then emitted in place below.
            if (n.res() != (IRValue*)0 && _ptrAdvance.get((Hashable*)n.res()) != (Object*)0)
                continue;
            emitInsn(fn, bb, n);
            }
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() == (IRValue*)0)
                continue;
            Object* d = _ptrAdvance.get((Hashable*)n.res());
            if (d == (Object*)0)
                continue;
            String* reg = ptrRegOf(n.res());
            i32 disp = ((Number*)d).asI32();
            if (disp >= (i32)1 && disp <= (i32)8)
                _out.appendFormat("\taddq.l\t#%ld,%s\n", disp, reg.cString());
            else if (disp >= (i32)-8 && disp <= (i32)-1)
                _out.appendFormat("\tsubq.l\t#%ld,%s\n", -disp, reg.cString());
            else
                _out.appendFormat("\tadda.l\t#%ld,%s\n", disp, reg.cString());
            }
        if (bb.term() != (IRInsn*)0)
            emitInsn(fn, bb, bb.term());
        }

    void emitInsn(IRFunc* fn, IRBlock* bb, IRInsn* n)
        {
        String* op = n.op();
        if (op.equals(String.withCString("Phi")))
            return; // edge copies
        // 64-bit values, intercepted before every path below — all of which
        // work in `.l` registers and would silently compute the low half only.
        if (n.res() != (IRValue*)0 && isI64(n.res().ty()) && emitInt64(n, op))
            return;
        String* mn = intBinOpMnemonic(op);
        if (mn != (String*)0)
            {
            emitBinary(mn, n);
            return;
            }
        if (op.equals(String.withCString("Neg")))
            {
            emitUnary(n, String.withCString("neg"));
            return;
            }
        if (op.equals(String.withCString("Not")))
            {
            emitUnary(n, String.withCString("not"));
            return;
            }
        if (op.equals(String.withCString("Const")))
            {
            emitConst(n);
            return;
            }
        if (op.equals(String.withCString("Copy")))
            {
            emitCopy(n);
            return;
            }
        if (op.equals(String.withCString("Load")))
            {
            emitLoad(fn, n);
            return;
            }
        if (op.equals(String.withCString("Store")))
            {
            emitStore(fn, n);
            return;
            }
        if (op.equals(String.withCString("ZExt")))
            {
            emitZExt(n);
            return;
            }
        if (op.equals(String.withCString("SExt")))
            {
            emitSExt(n);
            return;
            }
        if (op.equals(String.withCString("Trunc")))
            {
            emitTrunc(n);
            return;
            }
        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")))
            {
            emitShift(n);
            return;
            }
        if (op.equals(String.withCString("Mul")))
            {
            emitMul(n);
            return;
            }
        if (op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")))
            {
            emitDiv(n);
            return;
            }
        if (op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem")))
            {
            emitRem(n);
            return;
            }
        if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")))
            {
            emitCall(fn, n);
            return;
            }
        if (op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")))
            {
            emitCallIndirect(n);
            return;
            }
        if (op.equals(String.withCString("Retain")))
            {
            emitRetain(n);
            return;
            }
        if (op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")))
            {
            emitRelease(n);
            return;
            }
        if (op.equals(String.withCString("WeakRegister")))
            {
            emitWeakRegister(n);
            return;
            }
        if (op.equals(String.withCString("WeakUnregister")))
            {
            emitWeakUnregister(n);
            return;
            }
        if (op.equals(String.withCString("WeakLoad")))
            {
            emitWeakLoad(n);
            return;
            }
        if (op.equals(String.withCString("Select")))
            {
            emitSelect(n);
            return;
            }
        if (op.equals(String.withCString("AggBuild")))
            {
            emitAggBuild(n);
            return;
            }
        if (op.equals(String.withCString("AggExtract")))
            {
            emitAggExtract(n);
            return;
            }
        if (op.equals(String.withCString("VTblDispatch")))
            {
            emitVTblDispatch(n);
            return;
            }
        if (op.equals(String.withCString("VTblLoad")))
            {
            emitVTblLoad(n);
            return;
            }
        // A failed CHECKED downcast `(T*)p` lands here, and it IS reachable —
        // the comment this replaces claimed otherwise. Falling through meant
        // the cast silently succeeded with a mistyped pointer and the program
        // carried on, exiting 0, so a failed cast looked like a clean run.
        // Use `(T* ?)p` when failure is a possibility rather than a bug.
        if (op.equals(String.withCString("Unreachable")))
            {
            _out.appendCString("\tillegal\n"); // $4AFC
            return;
            }
        // Inline asm is intrinsically per-architecture, and the only asm this
        // back end sees is the shared ARC/library asm, #if-guarded to 6502 and
        // arm64 and therefore empty here — ARC runs through the __arc_retain /
        // __arc_release CALLS, not the asm. A real m68k asm block would need
        // verbatim emission with slot substitution; none exists yet.
        if (op.equals(String.withCString("Asm")))
            return;
        if (op.equals(String.withCString("Call")))
            {
            emitCall(fn, n);
            return;
            }
        if (op.equals(String.withCString("Return")))
            {
            emitReturn(fn, n);
            return;
            }
        if (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv")))
            {
            emitFBin(n);
            return;
            }
        if (op.equals(String.withCString("FNeg")))
            {
            emitFNeg(n);
            return;
            }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")))
            {
            emitFpToInt(fn, n);
            return;
            }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            {
            emitIntToFp(n);
            return;
            }
        if (op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")))
            {
            emitFpConvert(fn, n);
            return;
            }
        if (op.equals(String.withCString("FCmp")))
            {
            emitFCmp(fn, n);
            return;
            }
        if (op.equals(String.withCString("ICmp")))
            {
            emitICmp(n);
            return;
            }
        if (op.equals(String.withCString("Branch")))
            {
            emitBranch(fn, bb, n);
            return;
            }
        if (op.equals(String.withCString("CondBranch")))
            {
            emitCondBranch(fn, bb, n);
            return;
            }
        if (op.equals(String.withCString("IntToPtr")) || op.equals(String.withCString("PtrToInt")))
            {
            emitCopy(n);
            return;
            }
        if (op.equals(String.withCString("Bitcast")))
            {
            emitBitcast(n);
            return;
            }
        if (op.equals(String.withCString("AddrOf")))
            {
            emitAddrOf(n);
            return;
            }
        if (op.equals(String.withCString("FieldAddr")))
            {
            emitFieldAddr(n);
            return;
            }
        if (op.equals(String.withCString("ElementAddr")))
            {
            emitElementAddr(n);
            return;
            }
        unsupported(op);
        }

    // ── Casts and shifts ─────────────────────────────────────────────────
    void emitZExt(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        loadOperand(src, String.withCString("d0"));
        maskToWidth(widthOfOperand(src));
        storeReg(String.withCString("d0"), n.res());
        }

    void emitSExt(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        loadOperand(src, String.withCString("d0"));
        signExtendFrom(widthOfOperand(src));
        storeReg(String.withCString("d0"), n.res());
        }

    // Truncation must CLEAR the high bits: a stored value keeps its full 32,
    // so an unmasked `(u16)x` leaves stale upper bits that later full-width
    // u16 arithmetic — `val / 10` in a digit loop — reads as a huge number and
    // overruns a fixed buffer.
    void emitTrunc(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        // A Trunc with NO RESULT — a dead cast the lowering leaves behind, and
        // present in the reference's own IR (arm64 hit the same shape, #931).
        // The reference still emits the operand LOAD, then masks to a
        // default width of 4 (so no mask) and stores to a result that isn't
        // there (so no store). Reproduced exactly: the load is observable.
        if (n.res() == (IRValue*)0)
            {
            loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
            return;
            }
        // Truncating FROM 64 bits reads the LOW long, which is at off+4:
        // m68k is big-endian and the pack stores the high long first.
        IROperand* t0 = (IROperand*)n.ops().get((u32)0);
        if (t0.kind() == (u8)OPK_USE && t0.val() != (IRValue*)0 && isI64(t0.val().ty()))
            {
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n", slotOf(t0.val()) + (i32)4);
            maskToWidth(irWidth(n.res().ty()));
            storeReg(String.withCString("d0"), n.res());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        maskToWidth(irWidth(n.res().ty()));
        storeReg(String.withCString("d0"), n.res());
        }

    void maskToWidth(u32 w)
        {
        if (w == (u32)1)
            _out.appendCString("\tand.l\t#$ff,d0\n");
        else if (w == (u32)2)
            _out.appendCString("\tand.l\t#$ffff,d0\n");
        }

    void signExtendFrom(u32 w)
        {
        if (w == (u32)1)
            _out.appendCString("\text.w\td0\n\text.l\td0\n");
        else if (w == (u32)2)
            _out.appendCString("\text.l\td0\n");
        }

    // The shift is full-width, so a narrow operand's HIGH bits have to be right
    // first: asr.l needs the value sign-extended (else it shifts in zeroes) and
    // lsr.l needs it zero-extended (else stale upper bits shift DOWN into the
    // result — (u8)253 >> 2 gave 255 instead of 63). Shl is unaffected: its
    // result's low bits do not depend on the high ones.
    void emitShift(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        String* op = n.op();
        String* m = String.withCString(op.equals(String.withCString("Shl")) ? "lsl"
                                                                            : (op.equals(String.withCString("LShr")) ? "lsr" : "asr"));
        IROperand* v = (IROperand*)n.ops().get((u32)0);
        loadOperand(v, String.withCString("d0"));
        u32 vw = widthOfOperand(v);
        if (op.equals(String.withCString("AShr")))
            signExtendFrom(vw);
        else if (op.equals(String.withCString("LShr")))
            maskToWidth(vw);
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        _out.appendFormat("\t%s.l\td1,d0\n", m.cString());
        storeReg(String.withCString("d0"), n.res());
        }

    void emitMul(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        if (_cpu >= (u32)68020)
            _out.appendCString("\tmuls.l\td1,d0\n");
        else
            _out.appendCString("\tjsr\t__mulsi3\n");
        storeReg(String.withCString("d0"), n.res());
        }

    // Widen a narrow value to a full 32 bits before a 32-bit divide: signed for
    // a signed opcode, masked for an unsigned one. Without it, an (i16)-5511
    // left in the low word divides as +60025.
    void extendForDiv(String* r, IRInsn* n, bool sgn)
        {
        u32 w = n.res() == (IRValue*)0 ? (u32)4 : irWidth(n.res().ty());
        if (w >= (u32)4 || w == (u32)0)
            return;
        if (sgn)
            {
            if (w == (u32)1)
                _out.appendFormat("\text.w\t%s\n\text.l\t%s\n", r.cString(), r.cString());
            else
                _out.appendFormat("\text.l\t%s\n", r.cString());
            }
        else
            {
            _out.appendFormat("\tand.l\t#$%s,%s\n", w == (u32)1 ? "FF" : "FFFF", r.cString());
            }
        }

    void emitDiv(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        bool uns = n.op().equals(String.withCString("UDiv"));
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        extendForDiv(String.withCString("d0"), n, !uns);
        extendForDiv(String.withCString("d1"), n, !uns);
        if (_cpu >= (u32)68020)
            _out.appendFormat("\t%s\td1,d0\n", uns ? "divu.l" : "divs.l");
        else
            _out.appendFormat("\tjsr\t%s\n", uns ? "__udivsi3" : "__divsi3");
        storeReg(String.withCString("d0"), n.res());
        }

    // rem = a - (a/b)*b. The low 32 bits of q*b are sign-agnostic, so one
    // sequence covers both signednesses.
    void emitRem(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        bool uns = n.op().equals(String.withCString("URem"));
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        extendForDiv(String.withCString("d0"), n, !uns);
        extendForDiv(String.withCString("d1"), n, !uns);
        if (_cpu >= (u32)68020)
            {
            _out.appendCString("\tmove.l\td0,d2\n");                       // save a
            _out.appendFormat("\t%s\td1,d0\n", uns ? "divu.l" : "divs.l"); // d0 = a/b
            _out.appendCString("\tmuls.l\td1,d0\n");                       // d0 = (a/b)*b
            _out.appendCString("\tsub.l\td0,d2\n");
            storeReg(String.withCString("d2"), n.res());
            return;
            }
        _out.appendFormat("\tjsr\t%s\n", uns ? "__umodsi3" : "__modsi3");
        storeReg(String.withCString("d0"), n.res());
        }

    // ── Calls and returns ────────────────────────────────────────────────
    //
    // Arguments are pushed RIGHT TO LEFT as longs and the caller cleans the
    // stack; the result comes back in d0 (d0:d1 for a double, an sret buffer
    // for an aggregate).
    void emitCall(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM)
            {
            unsupported(String.withCString("Call:indirect"));
            return;
            }
        String* name = callee.name();
        u32 argc = n.ops().count() >= (u32)2 ? n.ops().count() - (u32)2 : (u32)0;
        String* resPte = n.res() == (IRValue*)0 ? (String*)0 : pointeeOf(n.res().ty());

        // The allocators take an element SIZE computed with the IR's 2-byte
        // pointers, which is too small here: a single `new T` would
        // under-allocate and the initialiser's wider field stores would run
        // into the next heap object. Override it with the m68k-native size.
        if (name.equals(String.withCString("_xtc_alloc")) && argc == (u32)3 && resPte != (String*)0)
            {
            loadOperand((IROperand*)n.ops().get((u32)3), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n"); // deallocPtr
            _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", fieldWidth(resPte));
            loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n"); // count
            _out.appendFormat("\tjsr\t%s\n\tlea\t12(sp),sp\n", m68kSym(name).cString());
            captureScalarResult(n);
            return;
            }
        if (name.hasPrefix(String.withCString("_xtc_new_")) && argc == (u32)2 && resPte != (String*)0)
            {
            _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", fieldWidth(resPte));
            loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n"); // count
            _out.appendFormat("\tjsr\t%s\n\tlea\t8(sp),sp\n", m68kSym(name).cString());
            captureScalarResult(n);
            return;
            }

        // An aggregate return travels through an sret buffer — d0:d1 cannot
        // hold a struct larger than 8 bytes — passed as a hidden trailing
        // argument, so it is pushed FIRST.
        bool aggRet = n.res() != (IRValue*)0 && isAggTy(n.res().ty());
        u32 popBytes = (u32)0;
        if (aggRet)
            {
            _out.appendFormat("\tlea\t%ld(a6),a0\n\tmove.l\ta0,-(sp)\n", slotOf(n.res()));
            popBytes = popBytes + (u32)4;
            }
        for (u32 k = argc; k > (u32)0; k = k - (u32)1)
            {
            IROperand* ao = (IROperand*)n.ops().get(k);
            String* at = ao.kind() == (u8)OPK_USE && ao.val() != (IRValue*)0
                             ? ao.val().ty()
                             : ao.ty();
            if (isAggTy(at) && ao.kind() == (u8)OPK_USE)
                {
                // A by-value aggregate is pushed whole, HIGH long first, so its
                // byte 0 lands at the lowest pushed address — the parameter's
                // own offset.
                i32 abase = slotOf(ao.val());
                u32 asz = (aggSize(layoutOf(at)) + (u32)3) & ~(u32)3;
                for (i32 o = (i32)asz - (i32)4; o >= (i32)0; o = o - (i32)4)
                    _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n", abase + o);
                popBytes = popBytes + asz;
                }
            else if ((isF64(at) || isI64(at)) && ao.kind() == (u8)OPK_USE)
                {
                // A double AND an i64 are two longs: push the LOW one first so
                // the high long lands at the lower address — big-endian order.
                // Without the i64 arm an eight-byte argument went out as one
                // long and every later argument shifted with it.
                i32 doff = slotOf(ao.val());
                _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n",
                                  doff + (i32)4, doff);
                popBytes = popBytes + (u32)8;
                }
            else
                {
                loadOperand(ao, String.withCString("d0"));
                _out.appendCString("\tmove.l\td0,-(sp)\n");
                popBytes = popBytes + (u32)4;
                }
            }
        _out.appendFormat("\tjsr\t%s\n", m68kSym(name).cString());
        if (popBytes != (u32)0)
            _out.appendFormat("\tlea\t%lu(sp),sp\n", popBytes);
        if (n.res() != (IRValue*)0 && (isF64(n.res().ty()) || isI64(n.res().ty())))
            {
            i32 base = slotOf(n.res());
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", base, base + (i32)4);
            return;
            }
        if (aggRet)
            return; // the callee already wrote it through the sret
        captureScalarResult(n);
        }

    void captureScalarResult(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || isMemTy(n.res().ty()))
            return;
        if (storeWideReturn(n))
            return;
        storeReg(String.withCString("d0"), n.res());
        }

    // An eight-byte scalar return arrives in d0:d1 (high:low) — TWO longs, and
    // every call site has to store both. VTblDispatch stored d0 alone, so an
    // i64 returned through a virtual or protocol call kept its high word and
    // lost its low one, while the same method called directly was fine.
    // Returns true when it stored the result.
    bool storeWideReturn(IRInsn* n)
        {
        if (n.res() == (IRValue*)0)
            return false;
        String* rt = n.res().ty();
        if (!isF64(rt) && !isI64(rt))
            return false;
        // NO `base < 0` guard: a6-relative slots ARE negative (-60, -64), so
        // that test rejects every real slot and silently stores one long.
        i32 base = slotOf(n.res());
        _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n",
                          base, base + (i32)4);
        return true;
        }

    void emitReturn(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() >= (u32)1)
            {
            IROperand* v = (IROperand*)n.ops().get((u32)0);
            String* vt = v.kind() == (u8)OPK_USE && v.val() != (IRValue*)0
                             ? v.val().ty()
                             : (String*)0;
            // returned in d0:d1
            if (isF64(vt) || isI64(vt))
                {
                i32 base = slotOf(v.val());
                _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\t%ld(a6),d1\n",
                                  base, base + (i32)4);
                }
            else if (isAggTy(vt))
                {
                emitAggReturn(fn, v);
                }
            else if (v.kind() == (u8)OPK_IMMI || v.kind() == (u8)OPK_USE)
                {
                // A VOID return's only operand is the memory token, and it
                // reaches here — the reference tests the OPERAND's type, which
                // a use never carries, so the token goes through loadOperand
                // and comes out as its unmapped-use note. Filtering on the
                // VALUE's type instead would silently drop that line.
                loadOperand(v, String.withCString("d0"));
                }
            }
        for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
            {
            String* r = (String*)_homeSaves.get(i);
            _out.appendFormat("\tmove.l\t%ld(a6),%s\n",
                              ((Number*)_homeSaveOff.get((Hashable*)r)).asI32(), r.cString());
            }
        for (u32 i = (u32)0; i < _ptrARegSaves.count(); i = i + (u32)1)
            {
            String* r = (String*)_ptrARegSaves.get(i);
            _out.appendFormat("\tmove.l\t%ld(a6),%s\n",
                              ((Number*)_ptrARegSaveOff.get((Hashable*)r)).asI32(), r.cString());
            }
        _out.appendCString("\tunlk\ta6\n\trts\n");
        }

    // The caller's sret buffer arrives as the implicit trailing argument, just
    // past the real parameters — and each aggregate parameter occupies its full
    // pushed size, not one long, so the offset has to be summed rather than
    // counted.
    void emitAggReturn(IRFunc* fn, IROperand* v)
        {
        i32 base = slotOf(v.val());
        u32 sz = (aggSize(layoutOf(v.val().ty())) + (u32)3) & ~(u32)3;
        i32 sretOff = (i32)8;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            String* t = ((IRValue*)fn.params().get(i)).ty();
            if (isMemTy(t))
                continue;
            if (isAggTy(t))
                sretOff = sretOff + (i32)((aggSize(layoutOf(t)) + (u32)3) & ~(u32)3);
            else if (isF64(t) || isI64(t))
                sretOff = sretOff + (i32)8;
            else
                sretOff = sretOff + (i32)4;
            }
        _out.appendFormat("\tmove.l\t%ld(a6),a0\n", sretOff);
        for (u32 o = (u32)0; o < sz; o = o + (u32)4)
            _out.appendFormat("\tmove.l\t%ld(a6),%lu(a0)\n", base + (i32)o, o);
        }

    // ── Pointer-IV address-register homing ───────────────────────────────
    //
    // The optimiser's pointer-IV pass produces a walking pointer: a Ptr phi `p`
    // whose back-edge value is `pNext = ElementAddr(p, const)`. Both map to ONE
    // address register out of a2-a4 and the pointer walks in place — the
    // advance is deferred to the end of its block, after the loads that read
    // the PRE-advance pointer, and emitted as an in-place add.
    //
    // Only formed when EVERY use of p is an address base or the advance itself,
    // never a value. That is what makes advancing the register in place safe:
    // nothing is holding the old pointer expecting it to stay put.
    Map* _ptrAReg;        // p and pNext -> the address register
    Map* _ptrAdvance;     // pNext -> its byte displacement
    Map* _ptrBase;        // p -> the preheader-edge base operand
    Array* _ptrARegSaves; // a2-a4 actually used, in order
    Map* _ptrARegSaveOff;

    void detectPointerIVs(IRFunc* fn)
        {
        _ptrAReg = new Map();
        _ptrAdvance = new Map();
        _ptrBase = new Map();
        Map* defOf = new Map();
        Map* useIn = new Map(); // value -> Array of the insns that read it
        Map* useAt = new Map(); // value -> Array of the operand indices
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            noteDefUse(defOf, useIn, useAt, bb.phis());
            noteDefUse(defOf, useIn, useAt, bb.insns());
            if (bb.term() != (IRInsn*)0)
                noteDefUseOne(defOf, useIn, useAt, bb.term());
            }
        Array* pool = new Array();
        pool.add((Object*)String.withCString("a2"));
        pool.add((Object*)String.withCString("a3"));
        pool.add((Object*)String.withCString("a4"));
        u32 next = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                {
                if (next >= pool.count())
                    return;
                IRInsn* phi = (IRInsn*)H.phis().get(i);
                if (phi.res() == (IRValue*)0 || phi.ops().count() != (u32)4)
                    continue;
                String* pt = phi.res().ty();
                if (!isPtrTy(pt))
                    continue;
                String* pte = pointeeOf(pt);
                if (pte == (String*)0)
                    continue;
                // The two incoming values; the latch edge's is the advance.
                IROperand* v0 = (IROperand*)phi.ops().get((u32)1);
                IROperand* v1 = (IROperand*)phi.ops().get((u32)3);
                IROperand* pNextOp = (IROperand*)0;
                IROperand* baseOp = (IROperand*)0;
                for (u32 e = (u32)0; e < (u32)2; e = e + (u32)1)
                    {
                    IROperand* vo = e == (u32)1 ? v1 : v0;
                    if (vo.kind() != (u8)OPK_USE || vo.val() == (IRValue*)0)
                        continue;
                    Object* dd = defOf.get((Hashable*)vo.val());
                    if (dd == (Object*)0)
                        continue;
                    IRInsn* d = (IRInsn*)dd;
                    if (!d.op().equals(String.withCString("ElementAddr")))
                        continue;
                    if (d.ops().count() < (u32)2)
                        continue;
                    IROperand* b0 = (IROperand*)d.ops().get((u32)0);
                    IROperand* b1 = (IROperand*)d.ops().get((u32)1);
                    if (b0.kind() != (u8)OPK_USE || b0.val() != phi.res())
                        continue;
                    if (b1.kind() != (u8)OPK_IMMI)
                        continue;
                    pNextOp = vo;
                    baseOp = e == (u32)1 ? v0 : v1;
                    }
                if (pNextOp == (IROperand*)0 || baseOp == (IROperand*)0)
                    continue;
                IRInsn* advInsn = (IRInsn*)defOf.get((Hashable*)pNextOp.val());
                i32 disp = ((IROperand*)advInsn.ops().get((u32)1)).imm() * (i32)fieldWidth(pte);
                if (disp == (i32)0)
                    continue;
                if (!walksCleanly(useIn, useAt, phi, phi.res(), pNextOp.val(), advInsn))
                    continue;
                String* reg = (String*)pool.get(next);
                next = next + (u32)1;
                _ptrAReg.set((Hashable*)phi.res(), (Object*)reg);
                _ptrAReg.set((Hashable*)pNextOp.val(), (Object*)reg);
                _ptrAdvance.set((Hashable*)pNextOp.val(), (Object*)Number.withI32(disp));
                _ptrBase.set((Hashable*)phi.res(), (Object*)baseOp);
                }
            }
        }

    // Every use of `p` is the advance or an address base (operand 0 of a Load
    // or Store), and `pNext` is read only by the phi's own back edge.
    static bool walksCleanly(Map* useIn, Map* useAt, IRInsn* phi,
                             IRValue* p, IRValue* pNext, IRInsn* advInsn)
        {
        Object* ui = useIn.get((Hashable*)p);
        if (ui != (Object*)0)
            {
            Array* ins = (Array*)ui;
            Array* ats = (Array*)useAt.get((Hashable*)p);
            for (u32 k = (u32)0; k < ins.count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)ins.get(k);
                if (n == advInsn)
                    continue;
                u32 at = ((Number*)ats.get(k)).asU32();
                bool mem = n.op().equals(String.withCString("Load")) || n.op().equals(String.withCString("Store"));
                if (mem && at == (u32)0)
                    continue;
                return false;
                }
            }
        Object* un = useIn.get((Hashable*)pNext);
        if (un != (Object*)0)
            {
            Array* ins = (Array*)un;
            for (u32 k = (u32)0; k < ins.count(); k = k + (u32)1)
                if ((IRInsn*)ins.get(k) != phi)
                    return false;
            }
        return true;
        }

    static void noteDefUse(Map* defOf, Map* useIn, Map* useAt, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            noteDefUseOne(defOf, useIn, useAt, (IRInsn*)list.get(i));
        }

    static void noteDefUseOne(Map* defOf, Map* useIn, Map* useAt, IRInsn* n)
        {
        if (n.res() != (IRValue*)0)
            defOf.set((Hashable*)n.res(), (Object*)n);
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            Object* have = useIn.get((Hashable*)o.val());
            Array* ins;
            Array* ats;
            if (have == (Object*)0)
                {
                ins = new Array();
                ats = new Array();
                useIn.set((Hashable*)o.val(), (Object*)ins);
                useAt.set((Hashable*)o.val(), (Object*)ats);
                }
            else
                {
                ins = (Array*)have;
                ats = (Array*)useAt.get((Hashable*)o.val());
                }
            ins.add((Object*)n);
            ats.add((Object*)Number.withU32(k));
            }
        }

    String* ptrRegOf(IRValue* v)
        {
        if (v == (IRValue*)0)
            return (String*)0;
        Object* r = _ptrAReg.get((Hashable*)v);
        return r == (Object*)0 ? (String*)0 : (String*)r;
        }

    // ── ARC ──────────────────────────────────────────────────────────────
    //
    // A 16-bit refcount at obj-2. Values below 64 KB are skipped: the Map/Set
    // sentinels and any non-heap address are not refcounted objects, and real
    // heap objects live above the load base.
    void emitRetain(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        u32 lbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a0"));
        _out.appendCString("\tmove.l\ta0,d0\n\tcmp.l\t#$10000,d0\n");
        _out.appendFormat("\tbcs\t.Lrt%lu\n", lbl);
        // A refcount of ZERO means the object is being DESTROYED: the release
        // that took it to 0 is running dealloc right now. Retaining it here would
        // let the matching release take it back to 0 and dispatch dealloc AGAIN,
        // forever — which is what any strong binding of `self` inside a dealloc
        // used to cause (bug 038). A live object always holds at least one
        // reference, so 0 can only mean "already dying"; release has always had
        // the mirror-image guard, and this makes the pair symmetric.
        _out.appendCString("\tmove.w\t-2(a0),d1\n");
        _out.appendFormat("\tbeq\t.Lrt%lu\n", lbl);
        _out.appendCString("\taddq.w\t#1,d1\n\tmove.w\td1,-2(a0)\n");
        _out.appendFormat(".Lrt%lu:\n", lbl);
        }

    void emitRelease(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        u32 lbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a0"));
        _out.appendCString("\tmove.l\ta0,d0\n\tcmp.l\t#$10000,d0\n");
        _out.appendFormat("\tbcs\t.Lrl%lu\n", lbl);
        _out.appendCString("\tmove.w\t-2(a0),d1\n\tsubq.w\t#1,d1\n\tmove.w\td1,-2(a0)\n");
        _out.appendFormat("\tbne\t.Lrl%lu\n", lbl);
        _out.appendCString("\tmove.l\ta0,-(sp)\n\tjsr\t_xtc_dealloc\n\taddq.l\t#4,sp\n");
        _out.appendFormat(".Lrl%lu:\n", lbl);
        }

    void emitWeakRegister(IRInsn* n)
        {
        if (n.ops().count() < (u32)3)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        _out.appendCString("\tjsr\t__xtc_weak_register\n");
        }

    void emitWeakUnregister(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        _out.appendCString("\tjsr\t__xtc_weak_unregister\n");
        }

    // The slot's memory is zeroed IN PLACE by the dealloc path, so a plain load
    // reads null once the pointee is gone.
    void emitWeakLoad(IRInsn* n)
        {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a0"));
        _out.appendCString("\tmove.l\t(a0),d0\n");
        storeReg(String.withCString("d0"), n.res());
        }

    // There is no conditional move on the 68000/68030, so a Select branches
    // around itself.
    void emitSelect(IRInsn* n)
        {
        if (n.ops().count() < (u32)3 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        u32 lbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        _out.appendFormat("\ttst.l\td0\n\tbeq.s\t.Lsel%luf\n", lbl);
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d0"));
        _out.appendFormat("\tbra.s\t.Lsel%lud\n.Lsel%luf:\n", lbl, lbl);
        loadOperand((IROperand*)n.ops().get((u32)2), String.withCString("d0"));
        _out.appendFormat(".Lsel%lud:\n", lbl);
        storeReg(String.withCString("d0"), n.res());
        }

    // ── Aggregates ───────────────────────────────────────────────────────
    void emitAggBuild(IRInsn* n)
        {
        if (n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        IRLayout* l = layoutOf(n.res().ty());
        if (l == (IRLayout*)0)
            {
            unsupported(String.withCString("AggBuild:layout"));
            return;
            }
        i32 base = slotOf(n.res());
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            loadOperand((IROperand*)n.ops().get(i), String.withCString("d0"));
            u32 fw = fieldWidth(l.typeAt(i));
            String* sfx = String.withCString(fw == (u32)1 ? "b" : (fw == (u32)2 ? "w" : "l"));
            _out.appendFormat("\tmove.%s\td0,%ld(a6)\n", sfx.cString(),
                              base + (i32)fieldOffset(l, i));
            }
        }

    void emitAggExtract(IRInsn* n)
        {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        if (src.kind() != (u8)OPK_USE || src.val() == (IRValue*)0)
            {
            unsupported(String.withCString("AggExtract:src"));
            return;
            }
        IRLayout* l = layoutOf(src.val().ty());
        if (l == (IRLayout*)0)
            {
            unsupported(String.withCString("AggExtract:layout"));
            return;
            }
        u32 idx = (u32)((IROperand*)n.ops().get((u32)1)).imm();
        i32 off = slotOf(src.val()) + (i32)fieldOffset(l, idx);
        String* rty = n.res().ty();
        u32 fw = irWidth(rty);
        if (fw == (u32)0)
            fw = (u32)4;
        bool sgn = isSignedTy(rty);
        if (fw == (u32)1)
            {
            if (sgn)
                _out.appendFormat("\tmove.b\t%ld(a6),d0\n\text.w\td0\n\text.l\td0\n", off);
            else
                _out.appendFormat("\tmoveq\t#0,d0\n\tmove.b\t%ld(a6),d0\n", off);
            }
        else if (fw == (u32)2)
            {
            if (sgn)
                _out.appendFormat("\tmove.w\t%ld(a6),d0\n\text.l\td0\n", off);
            else
                _out.appendFormat("\tmoveq\t#0,d0\n\tmove.w\t%ld(a6),d0\n", off);
            }
        else
            {
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n", off);
            }
        storeReg(String.withCString("d0"), n.res());
        }

    // ── Virtual dispatch ─────────────────────────────────────────────────
    //
    // The vtable pointer is at receiver+0 and a slot holds (method −
    // vtable_base) — a relocation-free OFFSET, which the dispatcher adds back.
    void emitVTblDispatch(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        IROperand* recv = (IROperand*)n.ops().get((u32)0);
        i32 slot = ((IROperand*)n.ops().get((u32)1)).imm();
        u32 argc = n.ops().count() >= (u32)3 ? n.ops().count() - (u32)3 : (u32)0;
        for (u32 k = argc; k > (u32)0; k = k - (u32)1)
            {
            loadOperand((IROperand*)n.ops().get((u32)1 + k), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n");
            }
        loadOperand(recv, String.withCString("d0")); // self goes last, so lowest
        _out.appendCString("\tmove.l\td0,-(sp)\n");
        loadOperand(recv, String.withCString("a0"));
        _out.appendCString("\tmove.l\t(a0),a1\n"); // the vtable's runtime address
        if (slot != (i32)0)
            _out.appendFormat("\tmove.l\t%ld(a1),d0\n", slot * (i32)4);
        else
            _out.appendCString("\tmove.l\t(a1),d0\n");
        _out.appendCString("\tadd.l\td0,a1\n\tjsr\t(a1)\n");
        _out.appendFormat("\tlea\t%lu(sp),sp\n", (u32)4 * (argc + (u32)1));
        captureScalarResult(n);
        }

    // The same address computation without the call — the code word of
    // `&obj.method`. TWO null cases, and here they are NOT the same test.
    //
    // A slot holds an OFFSET, so an EMPTY slot holds 0 and blindly adding the
    // base would yield vtable_base: a bogus non-null "method". Harmless for
    // dispatch, which never dispatches an empty slot, and fatal here, where a
    // null result is exactly how an unimplemented `optional` method reports
    // itself. So the zero offset is caught BEFORE the base is added. A null
    // receiver must likewise give 0 rather than fault, so one `if (h)` covers
    // both "no delegate" and "does not implement it".
    void emitVTblLoad(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        IROperand* recv = (IROperand*)n.ops().get((u32)0);
        i32 slot = ((IROperand*)n.ops().get((u32)1)).imm();
        u32 lbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        loadOperand(recv, String.withCString("a0"));
        _out.appendCString("\tmoveq\t#0,d0\n");  // the default: null
        _out.appendCString("\tmove.l\ta0,d1\n"); // sets Z when recv is null
        _out.appendFormat("\tbeq\t.Lvtl%lu\n", lbl);
        _out.appendCString("\tmove.l\t(a0),a1\n");
        if (slot != (i32)0)
            _out.appendFormat("\tmove.l\t%ld(a1),d0\n", slot * (i32)4);
        else
            _out.appendCString("\tmove.l\t(a1),d0\n");
        _out.appendFormat("\tbeq\t.Lvtl%lu\n", lbl); // an empty slot stays 0
        _out.appendCString("\tadd.l\ta1,d0\n");
        _out.appendFormat(".Lvtl%lu:\n", lbl);
        captureScalarResult(n);
        }

    void emitCallIndirect(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        u32 argc = n.ops().count() >= (u32)2 ? n.ops().count() - (u32)2 : (u32)0;
        for (u32 k = argc; k > (u32)0; k = k - (u32)1)
            {
            loadOperand((IROperand*)n.ops().get(k), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n");
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a1"));
        _out.appendCString("\tjsr\t(a1)\n");
        if (argc != (u32)0)
            _out.appendFormat("\tlea\t%lu(sp),sp\n", (u32)4 * argc);
        if (n.res() == (IRValue*)0)
            return;
        String* rt = n.res().ty();
        if (isF64(rt) || isI64(rt))
            {
            i32 base = slotOf(n.res());
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", base, base + (i32)4);
            return;
            }
        if (isAggTy(rt))
            {
            i32 base = slotOf(n.res());
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n", base);
            if (aggSize(layoutOf(rt)) > (u32)4)
                _out.appendFormat("\tmove.l\td1,%ld(a6)\n", base + (i32)4);
            return;
            }
        captureScalarResult(n);
        }

    // ── Floating point ───────────────────────────────────────────────────
    //
    // Floats live in FRAME SLOTS, never in a home register — the FP pool handed
    // to the allocator is empty — so every float operation reads and writes
    // a6-relative memory. With a 68881 that is one instruction; without one it
    // is a libgcc-style call.
    static bool isF64(String* t)
        {
        return t != (String*)0 && t.equals(String.withCString("F64"));
        }

    // A 64-bit INTEGER. Eight bytes, and it travels every route a double
    // already does — two longs in a slot, high long first (big-endian), d0:d1
    // for a return — so almost everywhere this is asked next to isF64.
    static bool isI64(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")));
        }

    // The FPU format suffix an operand's type takes.
    String* fsfxOp(IROperand* op)
        {
        String* t = op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0
                        ? op.val().ty()
                        : op.ty();
        return String.withCString(isF64(t) ? "d" : "s");
        }

    i32 slotOfOperand(IROperand* op)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return (i32)0;
        return slotOf(op.val());
        }

    void emitFBin(IRInsn* n)
        {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        bool dbl = isF64(n.res().ty());
        i32 o0 = slotOfOperand((IROperand*)n.ops().get((u32)0));
        i32 o1 = slotOfOperand((IROperand*)n.ops().get((u32)1));
        i32 r = slotOf(n.res());
        String* op = n.op();
        if (_hardFloat)
            {
            String* m = op.equals(String.withCString("FAdd")) ? String.withCString("fadd")
                                                              : (op.equals(String.withCString("FSub")) ? String.withCString("fsub")
                                                                                                       : (op.equals(String.withCString("FMul")) ? String.withCString("fmul")
                                                                                                                                                : String.withCString("fdiv")));
            String* sf = String.withCString(dbl ? "d" : "s");
            _out.appendFormat("\tfmove.%s\t%ld(a6),fp0\n", sf.cString(), o0);
            _out.appendFormat("\t%s.%s\t%ld(a6),fp0\n", m.cString(), sf.cString(), o1);
            _out.appendFormat("\tfmove.%s\tfp0,%ld(a6)\n", sf.cString(), r);
            return;
            }
        String* sop = op.equals(String.withCString("FAdd")) ? String.withCString("add")
                                                            : (op.equals(String.withCString("FSub")) ? String.withCString("sub")
                                                                                                     : (op.equals(String.withCString("FMul")) ? String.withCString("mul")
                                                                                                                                              : String.withCString("div")));
        emitSoftFloatBinary(sop, dbl, o0, o1, r);
        }

    // Soft float through the libgcc-style runtime. An f32 passes its arguments
    // in d0/d1 and returns in d0; an f64 pushes both (high long first, this
    // being big-endian) and returns in d0:d1.
    void emitSoftFloatBinary(String* op, bool dbl, i32 o0, i32 o1, i32 r)
        {
        if (dbl)
            {
            _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o1 + (i32)4, o1);
            _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o0 + (i32)4, o0);
            _out.appendFormat("\tjsr\t__%sdf3\n\tlea\t16(sp),sp\n", op.cString());
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", r, r + (i32)4);
            return;
            }
        _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\t%ld(a6),d1\n", o0, o1);
        _out.appendFormat("\tjsr\t__%ssf3\n\tmove.l\td0,%ld(a6)\n", op.cString(), r);
        }

    // Negation is just the sign bit, soft or hard.
    void emitFNeg(IRInsn* n)
        {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        bool dbl = isF64(n.res().ty());
        i32 o0 = slotOfOperand((IROperand*)n.ops().get((u32)0));
        i32 r = slotOf(n.res());
        if (o0 != r)
            {
            _out.appendFormat("\tmove.l\t%ld(a6),%ld(a6)\n", o0, r);
            if (dbl)
                _out.appendFormat("\tmove.l\t%ld(a6),%ld(a6)\n", o0 + (i32)4, r + (i32)4);
            }
        // Big-endian, so the sign bit is in the FIRST long.
        _out.appendFormat("\teor.l\t#$80000000,%ld(a6)\n", r);
        }

    // Float to integer. The spec says an out-of-range conversion produces 0,
    // which is what arm64 and xt6502 do — but the FPU's fmove.l saturates to
    // INT_MAX/MIN instead. So the IEEE EXPONENT is checked first: once the
    // unbiased exponent reaches the destination's bit width the magnitude
    // cannot fit, and the result is 0.
    void emitFpToInt(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        bool dbl = fsfxOp(src).equals(String.withCString("d"));
        i32 o0 = slotOfOperand(src);
        // A 64-bit RESULT cannot use the paths below: they produce d0 and store
        // one long, which big-endian puts in the HIGH half — so (i64)7.0d came
        // back as 7<<32. The 68881 has no 64-bit integer conversion either, so
        // both float modes take the HLE helper, which returns d0:d1.
        if (isI64(n.res().ty()))
            {
            bool uns = n.op().equals(String.withCString("FpToUI"));
            String* h = dbl ? (uns ? String.withCString("__fixunsdfdi")
                                   : String.withCString("__fixdfdi"))
                            : (uns ? String.withCString("__fixunssfdi")
                                   : String.withCString("__fixsfdi"));
            if (dbl)
                {
                _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n",
                                  o0 + (i32)4, o0);
                _out.appendFormat("\tjsr\t%s\n\taddq.l\t#8,sp\n", h.cString());
                }
            else
                {
                _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tjsr\t%s\n", o0, h.cString());
                }
            i32 rw = slotOf(n.res());
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", rw, rw + (i32)4);
            return;
            }
        if (_hardFloat)
            {
            u32 vid = n.res().pid();
            u32 w = irWidth(n.res().ty());
            if (w == (u32)0)
                w = (u32)4;
            i32 thr = (i32)((u32)8 * w) - (n.op().equals(String.withCString("FpToSI")) ? (i32)1 : (i32)0);
            if (dbl)
                {
                _out.appendFormat("\tmove.l\t%ld(a6),d1\n\tswap\td1\n\tlsr.w\t#4,d1\n", o0);
                _out.appendFormat("\tand.w\t#$7ff,d1\n\tcmp.w\t#%ld,d1\n\tbge.s\t.fsat%lu\n",
                                  (i32)1023 + thr, vid);
                _out.appendFormat("\tfmove.d\t%ld(a6),fp0\n\tfmove.l\tfp0,d0\n", o0);
                }
            else
                {
                _out.appendFormat("\tmove.l\t%ld(a6),d1\n\tswap\td1\n\tlsr.w\t#7,d1\n", o0);
                _out.appendFormat("\tand.w\t#$ff,d1\n\tcmp.w\t#%ld,d1\n\tbge.s\t.fsat%lu\n",
                                  (i32)127 + thr, vid);
                _out.appendFormat("\tfmove.s\t%ld(a6),fp0\n\tfmove.l\tfp0,d0\n", o0);
                }
            _out.appendFormat("\tbra.s\t.fsd%lu\n.fsat%lu:\tmoveq\t#0,d0\n.fsd%lu:\n", vid, vid, vid);
            }
        else if (dbl)
            {
            _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o0 + (i32)4, o0);
            _out.appendCString("\tjsr\t__fixdfsi\n\taddq.l\t#8,sp\n");
            }
        else
            {
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tjsr\t__fixsfsi\n", o0);
            }
        storeReg(String.withCString("d0"), n.res());
        }

    void emitIntToFp(IRInsn* n)
        {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        bool dbl = isF64(n.res().ty());
        i32 r = slotOf(n.res());
        // A 64-bit SOURCE cannot use the paths below: loadOperand brings ONE
        // long into d0, which big-endian makes the HIGH half — so (double)(i64)3
        // read 0 and produced 0.0. Same reasoning as emitFpToInt.
        IROperand* s0 = (IROperand*)n.ops().get((u32)0);
        if (s0.kind() == (u8)OPK_USE && s0.val() != (IRValue*)0 && isI64(s0.val().ty()))
            {
            bool uns = n.op().equals(String.withCString("UIToFp"));
            String* h = dbl ? (uns ? String.withCString("__floatundidf")
                                   : String.withCString("__floatdidf"))
                            : (uns ? String.withCString("__floatundisf")
                                   : String.withCString("__floatdisf"));
            pushInt64Operand(s0);
            _out.appendFormat("\tjsr\t%s\n\taddq.l\t#8,sp\n", h.cString());
            if (dbl)
                _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", r, r + (i32)4);
            else
                _out.appendFormat("\tmove.l\td0,%ld(a6)\n", r);
            return;
            }
        loadOperand(s0, String.withCString("d0"));
        if (_hardFloat)
            {
            _out.appendFormat("\tfmove.l\td0,fp0\n\tfmove.%s\tfp0,%ld(a6)\n", dbl ? "d" : "s", r);
            }
        else if (dbl)
            {
            _out.appendFormat("\tjsr\t__floatsidf\n\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n",
                              r, r + (i32)4);
            }
        else
            {
            _out.appendFormat("\tjsr\t__floatsisf\n\tmove.l\td0,%ld(a6)\n", r);
            }
        }

    void emitFpConvert(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        bool toDbl = isF64(n.res().ty());
        i32 o0 = slotOfOperand(src);
        i32 r = slotOf(n.res());
        if (_hardFloat)
            {
            _out.appendFormat("\tfmove.%s\t%ld(a6),fp0\n", fsfxOp(src).cString(), o0);
            _out.appendFormat("\tfmove.%s\tfp0,%ld(a6)\n", toDbl ? "d" : "s", r);
            }
        else if (toDbl)
            {
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tjsr\t__extendsfdf2\n", o0);
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", r, r + (i32)4);
            }
        else
            {
            _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o0 + (i32)4, o0);
            _out.appendFormat("\tjsr\t__truncdfsf2\n\taddq.l\t#8,sp\n\tmove.l\td0,%ld(a6)\n", r);
            }
        }

    void emitFCmp(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        IROperand* b = (IROperand*)n.ops().get((u32)1);
        bool dbl = fsfxOp(a).equals(String.withCString("d"));
        i32 o0 = slotOfOperand(a);
        i32 o1 = slotOfOperand(b);
        if (_hardFloat)
            {
            String* sf = String.withCString(dbl ? "d" : "s");
            _out.appendFormat("\tfmove.%s\t%ld(a6),fp0\n", sf.cString(), o0);
            _out.appendFormat("\tfcmp.%s\t%ld(a6),fp0\n", sf.cString(), o1);
            _out.appendFormat("\t%s\td2\n\tand.l\t#1,d2\n", fpuCond(n.pred()).cString());
            }
        else
            {
            // The soft comparison returns sign(a - b) in {-1, 0, 1}, so the
            // predicate becomes an integer test against zero.
            if (dbl)
                {
                _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o1 + (i32)4, o1);
                _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n", o0 + (i32)4, o0);
                _out.appendCString("\tjsr\t__cmpdf2\n\tlea\t16(sp),sp\n");
                }
            else
                {
                _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\t%ld(a6),d1\n\tjsr\t__cmpsf2\n", o0, o1);
                }
            _out.appendFormat("\tmoveq\t#0,d2\n\ttst.l\td0\n\ts%s\td2\n\tand.l\t#1,d2\n",
                              softFCond(n.pred()).cString());
            }
        storeReg(String.withCString("d2"), n.res());
        }

    // The predicate order is the IR's own: OEQ, ONE, OLT, OGT, OLE, OGE.
    static String* fpuCond(String* p)
        {
        if (p == (String*)0)
            return String.withCString("fseq");
        if (p.equals(String.withCString("OEQ")))
            return String.withCString("fseq");
        if (p.equals(String.withCString("ONE")))
            return String.withCString("fsne");
        if (p.equals(String.withCString("OLT")))
            return String.withCString("fslt");
        if (p.equals(String.withCString("OGT")))
            return String.withCString("fsgt");
        if (p.equals(String.withCString("OLE")))
            return String.withCString("fsle");
        if (p.equals(String.withCString("OGE")))
            return String.withCString("fsge");
        return String.withCString("fseq");
        }

    static String* softFCond(String* p)
        {
        if (p == (String*)0)
            return String.withCString("eq");
        if (p.equals(String.withCString("OEQ")))
            return String.withCString("eq");
        if (p.equals(String.withCString("ONE")))
            return String.withCString("ne");
        if (p.equals(String.withCString("OLT")))
            return String.withCString("lt");
        if (p.equals(String.withCString("OGT")))
            return String.withCString("gt");
        if (p.equals(String.withCString("OLE")))
            return String.withCString("le");
        if (p.equals(String.withCString("OGE")))
            return String.withCString("ge");
        return String.withCString("eq");
        }

    // ── Compare-and-branch fusion ────────────────────────────────────────
    //
    // An ICmp that is a block's LAST instruction and whose result is read only
    // by that block's CondBranch leaves its flags set and the branch reads them
    // directly — no Scc, no boolean, no tst.
    Map* _fusedCmp;

    void computeFusedCmps(IRFunc* fn)
        {
        _fusedCmp = new Map();
        Map* uc = countUses(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")))
                continue;
            if (t.ops().count() < (u32)1)
                continue;
            IROperand* cond = (IROperand*)t.ops().get((u32)0);
            if (cond.kind() != (u8)OPK_USE || cond.val() == (IRValue*)0)
                continue;
            if (countIn(uc, cond.val()) != (u32)1)
                continue;
            if (bb.insns().count() == (u32)0)
                continue;
            IRInsn* last = (IRInsn*)bb.insns().get(bb.insns().count() - (u32)1);
            if (!last.op().equals(String.withCString("ICmp")))
                continue;
            if (last.res() != cond.val())
                continue;
            // A 64-bit compare goes through a helper returning sign(a-b) in d0,
            // so the flags a fused branch would read are those of `tst.l d0` —
            // a SIGNED test — whatever the operands' signedness was. Keep the
            // boolean rather than translating the predicate at the branch.
            if (last.ops().count() >= (u32)1 && isI64(operandTy((IROperand*)last.ops().get((u32)0))))
                continue;
            _fusedCmp.set((Hashable*)cond.val(), (Object*)last);
            }
        }

    Map* countUses(IRFunc* fn)
        {
        Map* uc = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            countUsesIn(uc, bb.phis());
            countUsesIn(uc, bb.insns());
            if (bb.term() != (IRInsn*)0)
                countUsesOne(uc, bb.term());
            }
        return uc;
        }

    static void countUsesIn(Map* uc, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            countUsesOne(uc, (IRInsn*)list.get(i));
        }

    static void countUsesOne(Map* uc, IRInsn* n)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            Object* c = uc.get((Hashable*)o.val());
            uc.set((Hashable*)o.val(),
                   (Object*)Number.withU32((c == (Object*)0 ? (u32)0 : ((Number*)c).asU32()) + (u32)1));
            }
        }

    static u32 countIn(Map* uc, IRValue* v)
        {
        Object* c = uc.get((Hashable*)v);
        return c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
        }

    // A single-use ElementAddr/FieldAddr IMMEDIATELY followed by the scalar
    // Load/Store that consumes it folds into that memory operand.
    void computeFolds(IRFunc* fn)
        {
        _fold = new Map();
        Map* uc = countUses(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* ins = bb.insns();
            for (u32 i = (u32)0; i + (u32)1 < ins.count(); i = i + (u32)1)
                {
                IRInsn* ea = (IRInsn*)ins.get(i);
                bool isEA = ea.op().equals(String.withCString("ElementAddr"));
                if (!isEA && !ea.op().equals(String.withCString("FieldAddr")))
                    continue;
                if (ea.res() == (IRValue*)0)
                    continue;
                if (countIn(uc, ea.res()) != (u32)1)
                    continue;
                IRInsn* nx = (IRInsn*)ins.get(i + (u32)1);
                bool isLoad = nx.op().equals(String.withCString("Load"));
                bool isStore = nx.op().equals(String.withCString("Store"));
                if (!isLoad && !isStore)
                    continue;
                if (nx.ops().count() < (u32)1)
                    continue;
                IROperand* p = (IROperand*)nx.ops().get((u32)0);
                if (p.kind() != (u8)OPK_USE || p.val() != ea.res())
                    continue;
                // A struct copy stays a byte loop; there is no memory operand
                // for it to fold into.
                String* mt = isLoad
                                 ? (nx.res() == (IRValue*)0 ? (String*)0 : nx.res().ty())
                                 : transferTy(nx);
                if (isAggTy(mt))
                    continue;
                if (isEA)
                    {
                    u32 st = elemStride(ea);
                    if (st != (u32)1 && st != (u32)2 && st != (u32)4 && st != (u32)8)
                        continue;
                    // The scaled index mode is a 68020 addition.
                    if (st > (u32)1 && _cpu < (u32)68020)
                        continue;
                    }
                _fold.set((Hashable*)ea.res(), (Object*)ea);
                }
            }
        }

    static String* transferTy(IRInsn* st)
        {
        if (st.ops().count() < (u32)2)
            return (String*)0;
        IROperand* v = (IROperand*)st.ops().get((u32)1);
        if (v.kind() == (u8)OPK_USE && v.val() != (IRValue*)0)
            return v.val().ty();
        return v.ty();
        }

    // ── Compares and branches ────────────────────────────────────────────
    void emitICmp(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        // A 64-bit compare cannot be one `cmp.l`: comparing the high longs
        // alone made `7 == 0` true, which is how String.withU64 returned "0"
        // for every input. It goes through a helper returning sign(a-b) in d0,
        // exactly as the soft-float compare does.
        String* ct0 = operandTy((IROperand*)n.ops().get((u32)0));
        String* ct1 = operandTy((IROperand*)n.ops().get((u32)1));
        if ((isI64(ct0) || isI64(ct1)) && n.res() != (IRValue*)0)
            {
            bool sgn = ct0.equals(String.withCString("I64")) || ct1.equals(String.withCString("I64"));
            pushInt64Operand((IROperand*)n.ops().get((u32)1));
            pushInt64Operand((IROperand*)n.ops().get((u32)0));
            _out.appendFormat("\tjsr\t%s\n\tlea\t16(sp),sp\n",
                              sgn ? "__cmpdi2" : "__ucmpdi2");
            _out.appendCString("\tmoveq\t#0,d2\n\ttst.l\td0\n");
            _out.appendFormat("\ts%s\td2\n", condForSignOf(n.pred()).cString());
            _out.appendCString("\tand.l\t#1,d2\n");
            storeReg(String.withCString("d2"), n.res());
            return;
            }
        // Compare at the OPERAND width: dirty high bits in the 32-bit slots
        // would otherwise corrupt a narrow u8/u16 comparison.
        u32 w0 = widthOfOperand((IROperand*)n.ops().get((u32)0));
        u32 w1 = widthOfOperand((IROperand*)n.ops().get((u32)1));
        u32 w = w0 > w1 ? w0 : w1;
        String* sz = String.withCString(w == (u32)1 ? "b" : (w == (u32)2 ? "w" : "l"));
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        loadOperand((IROperand*)n.ops().get((u32)1), String.withCString("d1"));
        if (n.res() != (IRValue*)0 && _fusedCmp.get((Hashable*)n.res()) != (Object*)0)
            {
            // Fused: leave the flags set and emit no boolean at all.
            _out.appendFormat("\tcmp.%s\td1,d0\n", sz.cString());
            return;
            }
        _out.appendCString("\tmoveq\t#0,d2\n"); // pre-clear; cmp sets the flags below
        _out.appendFormat("\tcmp.%s\td1,d0\n", sz.cString());
        _out.appendFormat("\ts%s\td2\n", condFor(n.pred()).cString());
        _out.appendCString("\tand.l\t#1,d2\n");
        storeReg(String.withCString("d2"), n.res());
        }

    void emitBranch(IRFunc* fn, IRBlock* bb, IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* t = (IROperand*)n.ops().get((u32)0);
        if (t.kind() != (u8)OPK_BLOCK)
            {
            unsupported(n.op());
            return;
            }
        emitPhiCopies(fn, bb, t.blk());
        _out.appendFormat("\tbra\t%s\n", blockLabel(fn, t.blk()).cString());
        }

    void emitCondBranch(IRFunc* fn, IRBlock* bb, IRInsn* n)
        {
        if (n.ops().count() < (u32)3)
            {
            unsupported(n.op());
            return;
            }
        IROperand* cond = (IROperand*)n.ops().get((u32)0);
        IRBlock* tb = ((IROperand*)n.ops().get((u32)1)).blk();
        IRBlock* fb = ((IROperand*)n.ops().get((u32)2)).blk();
        u32 lbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        IRInsn* fcmp = bb.insns().count() > (u32)0
                           ? (IRInsn*)bb.insns().get(bb.insns().count() - (u32)1)
                           : (IRInsn*)0;
        bool fused = cond.kind() == (u8)OPK_USE && cond.val() != (IRValue*)0 && _fusedCmp.get((Hashable*)cond.val()) != (Object*)0 && fcmp != (IRInsn*)0 && fcmp.res() == cond.val();
        if (fused)
            {
            // The ICmp already emitted its `cmp` and the flags are still set:
            // branch to the FALSE edge on the negated predicate.
            _out.appendFormat("\tb%s\t.Lcbf%lu\n", condForNegated(fcmp.pred()).cString(), lbl);
            }
        else
            {
            loadOperand(cond, String.withCString("d0"));
            _out.appendCString("\ttst.l\td0\n");
            _out.appendFormat("\tbeq\t.Lcbf%lu\n", lbl);
            }
        emitPhiCopies(fn, bb, tb);
        _out.appendFormat("\tbra\t%s\n", blockLabel(fn, tb).cString());
        _out.appendFormat(".Lcbf%lu:\n", lbl);
        emitPhiCopies(fn, bb, fb);
        _out.appendFormat("\tbra\t%s\n", blockLabel(fn, fb).cString());
        }

    // ── Phi-edge copies ──────────────────────────────────────────────────
    void emitPhiCopies(IRFunc* fn, IRBlock* from, IRBlock* to)
        {
        if (to == (IRBlock*)0)
            return;
        Array* dests = new Array();
        Array* srcs = new Array();
        for (u32 i = (u32)0; i < to.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)to.phis().get(i);
            IROperand* src = phiSourceFrom(phi, from);
            if (src == (IROperand*)0 || phi.res() == (IRValue*)0)
                continue;
            dests.add((Object*)phi.res());
            srcs.add((Object*)src);
            }
        if (dests.count() == (u32)0)
            return;
        // Sequential copies are safe iff no phi's DEST location is a DIFFERENT
        // phi's SOURCE location — a sequential write would clobber a source not
        // yet read. A location is a home register OR a frame slot, and the slot
        // half is load-bearing: when one phi's source is itself another phi's
        // dest (`v0 <- lc4` beside `lc4 <- lc4+1` after the inner loop unrolls),
        // writing lc4's slot first hands v0 the post-increment value. Both live
        // in slots, so a register-only check misses it.
        bool safe = true;
        for (u32 i = (u32)0; i < dests.count() && safe; i = i + (u32)1)
            {
            IRValue* d = (IRValue*)dests.get(i);
            if (isAggTy(d.ty()))
                continue; // aggregates take the byte-copy path
            String* rd = locOf(d);
            if (rd == (String*)0)
                continue;
            for (u32 j = (u32)0; j < srcs.count() && safe; j = j + (u32)1)
                {
                if (i == j)
                    continue;
                IROperand* sj = (IROperand*)srcs.get(j);
                if (sj.kind() != (u8)OPK_USE || sj.val() == (IRValue*)0)
                    continue;
                String* rs = locOf(sj.val());
                if (rs != (String*)0 && rs.equals(rd))
                    safe = false;
                }
            }
        if (safe)
            {
            for (u32 i = (u32)0; i < dests.count(); i = i + (u32)1)
                emitOnePhiCopy((IRValue*)dests.get(i), (IROperand*)srcs.get(i));
            return;
            }
        // A cycle: read EVERY source (push) before writing ANY dest (pop in
        // reverse). Aggregates are excluded — they have their own slot and
        // cannot ride the 4-byte scalar shuffle.
        Array* cd = new Array();
        Array* cs = new Array();
        for (u32 i = (u32)0; i < dests.count(); i = i + (u32)1)
            {
            IRValue* d = (IRValue*)dests.get(i);
            IROperand* sv = (IROperand*)srcs.get(i);
            // Address-register and aggregate destinations are handled directly:
            // neither can ride the 4-byte scalar stack shuffle.
            if (ptrRegOf(d) != (String*)0)
                {
                emitOnePhiCopy(d, sv);
                continue;
                }
            if (isAggTy(d.ty()) && sv.kind() == (u8)OPK_USE)
                {
                emitAggPhiCopy(d, sv);
                continue;
                }
            // Eight-byte scalar: copied in place, exactly as an aggregate is.
            // Both step outside the read-all-then-write-all discipline, so a
            // cycle whose members are 64-bit would still be wrong — no such
            // cycle exists today, and it would need a wide shuffle.
            if (emitWidePhiCopy(d, sv))
                continue;
            cd.add((Object*)d);
            cs.add((Object*)sv);
            }
        for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
            {
            loadOperand((IROperand*)cs.get(i), String.withCString("d0"));
            _out.appendCString("\tmove.l\td0,-(sp)\n");
            }
        for (u32 i = cd.count(); i > (u32)0; i = i - (u32)1)
            {
            _out.appendCString("\tmove.l\t(sp)+,d0\n");
            storeReg(String.withCString("d0"), (IRValue*)cd.get(i - (u32)1));
            }
        }

    void emitOnePhiCopy(IRValue* d, IROperand* src)
        {
        // A walking pointer's dest IS its address register. On the BACK edge
        // the source is that same register — already advanced in place — so
        // there is nothing to do; on the preheader edge the base loads into it.
        String* destAReg = ptrRegOf(d);
        if (destAReg != (String*)0)
            {
            String* srcAReg = src.kind() == (u8)OPK_USE ? ptrRegOf(src.val()) : (String*)0;
            if (srcAReg == (String*)0 || !srcAReg.equals(destAReg))
                loadOperand(src, destAReg);
            return;
            }
        // An AGGREGATE phi is a slot-to-slot BYTE COPY. A struct always lives
        // in a frame slot (aggregates are never homed), so a 4-byte move copies
        // only its first four bytes — an 8-byte Rect through a ternary kept its
        // x,y and zeroed w,h.
        if (isAggTy(d.ty()) && src.kind() == (u8)OPK_USE)
            {
            emitAggPhiCopy(d, src);
            return;
            }
        if (emitWidePhiCopy(d, src))
            return;
        String* ea = eaOf(src);
        if (ea == (String*)0)
            {
            loadOperand(src, String.withCString("d0"));
            ea = String.withCString("d0");
            }
        String* dHome = homeOf(d);
        if (dHome != (String*)0)
            {
            // Single-write: the home register is authoritative, so the slot is
            // deliberately not mirrored.
            if (!ea.equals(dHome))
                _out.appendFormat("\tmove.l\t%s,%s\n", ea.cString(), dHome.cString());
            return;
            }
        // Memory to memory is a legal move on this machine.
        _out.appendFormat("\tmove.l\t%s,%ld(a6)\n", ea.cString(), slotOf(d));
        }

    // An i64 phi is EIGHT bytes in a slot, so the `move.l` on the scalar path
    // copies only its high long and leaves the low one holding whatever the
    // slot had. Aggregates already had this fix; the eight-byte scalars did not.
    //
    // F64 travels this path too: a double through a ternary or round a loop is
    // a phi of the same width and lost its low long the same way. It stayed
    // invisible for as long as anyone tested with 1.5 / 3.25 / 7.75 — every one
    // of those has a ZERO low word, so half a copy still gives the right
    // answer. 3.1 does not.
    bool emitWidePhiCopy(IRValue* d, IROperand* src)
        {
        if (!isI64(d.ty()) && !isF64(d.ty()))
            return false;
        i32 dd = slotOf(d);
        if (src.kind() == (u8)OPK_IMMI)
            {
            i64 v = src.imm();
            _out.appendFormat("\tmove.l\t#%lu,%ld(a6)\n", (u32)(v >> (i64)32), dd);
            _out.appendFormat("\tmove.l\t#%lu,%ld(a6)\n", (u32)v, dd + (i32)4);
            return true;
            }
        if (src.kind() == (u8)OPK_IMMF)
            {
            // The IEEE double pattern, most-significant long first. substring
            // is (start, LENGTH), and the IR spells the pattern in lower case
            // while the assembly uses upper — as the Const case does.
            String* hx = src.fpHex();
            _out.appendFormat("\tmove.l\t#$%s,%ld(a6)\n",
                              upperHex(hx.substringBytes((u32)0, (u32)8)).cString(), dd);
            _out.appendFormat("\tmove.l\t#$%s,%ld(a6)\n",
                              upperHex(hx.substringBytes((u32)8, (u32)8)).cString(), dd + (i32)4);
            return true;
            }
        if (src.kind() != (u8)OPK_USE || src.val() == (IRValue*)0)
            return false;
        i32 ss = slotOf(src.val());
        _out.appendFormat("\tmove.l\t%ld(a6),%ld(a6)\n", ss, dd);
        _out.appendFormat("\tmove.l\t%ld(a6),%ld(a6)\n", ss + (i32)4, dd + (i32)4);
        return true;
        }

    void emitAggPhiCopy(IRValue* d, IROperand* src)
        {
        u32 wide = aggSize(layoutOf(d.ty()));
        _out.appendFormat("\tlea\t%ld(a6),a0\n", slotOf(d));
        _out.appendFormat("\tlea\t%ld(a6),a1\n", slotOf(src.val()));
        u32 nlbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        _out.appendFormat("\tmove.l\t#%lu,d0\n.Lphicpy%lu:\n\tmove.b\t(a1)+,(a0)+\n", wide, nlbl);
        _out.appendFormat("\tsubq.l\t#1,d0\n\tbne.s\t.Lphicpy%lu\n", nlbl);
        }

    // Where a value lives — its home register, or its frame slot.
    String* locOf(IRValue* v)
        {
        String* h = homeOf(v);
        if (h != (String*)0)
            return h;
        String* s = String.withCString("");
        s.appendFormat("%ld(a6)", slotOf(v));
        return s;
        }

    static IROperand* phiSourceFrom(IRInsn* phi, IRBlock* from)
        {
        for (u32 i = (u32)0; i + (u32)1 < phi.ops().count(); i = i + (u32)2)
            {
            IROperand* b = (IROperand*)phi.ops().get(i);
            if (b.kind() == (u8)OPK_BLOCK && b.blk() == from)
                return (IROperand*)phi.ops().get(i + (u32)1);
            }
        return (IROperand*)0;
        }

    // ── Constants ────────────────────────────────────────────────────────
    void emitConst(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* op = (IROperand*)n.ops().get((u32)0);
        if (op.kind() == (u8)OPK_IMMI)
            {
            String* home = homeOf(n.res());
            if (home != (String*)0) // single-write the home
                _out.appendFormat("\tmove.l\t#%s,%s\n", immText(op).cString(), home.cString());
            else
                _out.appendFormat("\tmove.l\t#%s,%ld(a6)\n", immText(op).cString(), slotOf(n.res()));
            return;
            }
        if (op.kind() == (u8)OPK_IMMF)
            {
            // The immediate is the IEEE DOUBLE bit pattern; an F32 slot takes
            // the narrowed single. Both go out most-significant long first,
            // which is this machine's order.
            i32 off = slotOf(n.res());
            String* hex = op.fpHex();
            if (n.res().ty().equals(String.withCString("F64")))
                {
                // The IR spells the pattern in lower case; the assembly uses
                // upper, as every other hex constant here does.
                _out.appendFormat("\tmove.l\t#$%s,%ld(a6)\n",
                                  upperHex(hex.substringBytes((u32)0, (u32)8)).cString(), off);
                _out.appendFormat("\tmove.l\t#$%s,%ld(a6)\n",
                                  upperHex(hex.substringBytes((u32)8, (u32)8)).cString(), off + (i32)4);
                }
            else
                {
                _out.appendFormat("\tmove.l\t#$%s,%ld(a6)\n", hex8(f32BitsOfHex(hex)).cString(), off);
                }
            return;
            }
        unsupported(String.withCString("Const:nonint"));
        }

    static String* upperHex(String* h)
        {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < h.byteLength(); i = i + (u32)1)
            {
            u8 c = h.byteAt(i);
            o.appendByte(c >= (u8)'a' && c <= (u8)'f' ? (u8)(c - (u8)32) : c);
            }
        return o;
        }

    // Eight uppercase hex digits — appendFormat's %x is lowercase and takes no
    // width, and the assembly wants `$0000000A`.
    static String* hex8(u32 v)
        {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            o.append(IRSymbol.hex2((v >> ((u32)8 * ((u32)3 - i))) & (u32)$FF));
        return o;
        }

    // The IEEE single bits of a double spelled as 16 BIG-endian hex digits.
    static u32 f32BitsOfHex(String* hex)
        {
        Array* le = new Array();
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            {
            u32 idx = ((u32)7 - i) * (u32)2;
            le.add((Object*)Number.withU32(hexByte(hex, idx)));
            }
        return f32BitsOfLE(le);
        }

    static u32 hexByte(String* hex, u32 at)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < (u32)2; i = i + (u32)1)
            {
            if (at + i >= hex.byteLength())
                return v;
            u8 c = hex.byteAt(at + i);
            u32 d = (u32)0;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            v = v * (u32)16 + d;
            }
        return v;
        }

    // A reinterpret to a NARROW integer — `(u16)i16expr` — has to present the
    // canonical narrow value with clean high bits. The source may carry stale
    // upper bits (a 32-bit Sub result, a sign-extended i16) that a later
    // full-width operation such as a `val / 10` digit loop would misread.
    void emitBitcast(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        // Bool is deliberately NOT masked: the reference's integer predicate
        // covers I8..U32 only, and a Bool is already 0 or 1 by construction.
        String* rt = n.res() == (IRValue*)0 ? (String*)0 : n.res().ty();
        if (isIntegerTy(rt))
            maskToWidth(irWidth(rt));
        storeReg(String.withCString("d0"), n.res());
        }

    void emitCopy(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        storeReg(String.withCString("d0"), n.res());
        }

    // ── Memory ───────────────────────────────────────────────────────────
    //
    // A single-use ElementAddr/FieldAddr immediately consumed by a scalar
    // Load/Store folds into that memory operand — a scaled index for an array,
    // a displacement for a struct field. The address op is then never emitted.
    Map* _fold; // addr result -> the addr insn to inline

    // The base (and, for an ElementAddr, the index) into registers, then the
    // fused addressing operand.
    String* foldedMemOp(IRFunc* fn, IRInsn* ea)
        {
        loadOperand((IROperand*)ea.ops().get((u32)0), String.withCString("a0"));
        if (ea.op().equals(String.withCString("FieldAddr")))
            {
            u32 off = fieldByteOffset(ea);
            if (off == (u32)0)
                return String.withCString("(a0)");
            String* o = String.withCString("");
            o.appendFormat("%lu(a0)", off);
            return o;
            }
        u32 stride = elemStride(ea);
        IROperand* idx = (IROperand*)ea.ops().get((u32)1);
        // A 64-bit index skips the home check entirely — a 32-bit home holds
        // one half; the slot pair is authoritative (see loadOperandLow32).
        bool idx64 = idx.kind() == (u8)OPK_USE && idx.val() != (IRValue*)0 && isI64(idx.val().ty());
        String* idxReg = idx64 ? (String*)0 : operandHome(idx);
        if (idxReg == (String*)0)
            {
            loadOperandLow32(idx, String.withCString("d1"));
            idxReg = String.withCString("d1");
            }
        String* o = String.withCString("(a0,");
        o.append(idxReg);
        if (stride == (u32)1)
            o.appendCString(".l)");
        else
            o.appendFormat(".l*%lu)", stride);
        return o;
        }

    u32 fieldByteOffset(IRInsn* n)
        {
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        if (b.kind() != (u8)OPK_USE || b.val() == (IRValue*)0)
            return (u32)0;
        IRLayout* l = layoutOf(pointeeOf(b.val().ty()));
        if (l == (IRLayout*)0)
            return (u32)0;
        return fieldOffset(l, (u32)((IROperand*)n.ops().get((u32)1)).imm());
        }

    // An ElementAddr scales by the RESULT pointer's pointee, which is the
    // element type.
    u32 elemStride(IRInsn* n)
        {
        if (n.res() == (IRValue*)0)
            return (u32)1;
        String* pte = pointeeOf(n.res().ty());
        if (pte == (String*)0)
            return (u32)1;
        return fieldWidth(pte);
        }

    // A memory access addresses through the walking pointer's own register
    // when it has one, else through a folded address mode, else through a0.
    String* addressOperand(IRFunc* fn, IROperand* p)
        {
        if (p.kind() == (u8)OPK_USE && p.val() != (IRValue*)0)
            {
            String* pareg = ptrRegOf(p.val());
            if (pareg != (String*)0)
                {
                String* o = String.withCString("(");
                o.append(pareg);
                o.appendCString(")");
                return o;
                }
            if (isFolded(p.val()))
                return foldedMemOp(fn, (IRInsn*)_fold.get((Hashable*)p.val()));
            }
        loadOperand(p, String.withCString("a0"));
        return String.withCString("(a0)");
        }

    bool isFolded(IRValue* v)
        {
        return v != (IRValue*)0 && _fold.get((Hashable*)v) != (Object*)0;
        }

    void emitLoad(IRFunc* fn, IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        String* rt = n.res().ty();
        if (isAggTy(rt))
            {
            // A whole-struct load copies the full m68k width into the result's
            // slot; a 4-byte move.l would take only the first field or two.
            u32 wide = aggSize(layoutOf(rt));
            loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a1"));
            _out.appendFormat("\tlea\t%ld(a6),a0\n", slotOf(n.res()));
            emitByteCopyLoop(wide);
            return;
            }
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        String* mem = addressOperand(fn, p);
        u32 w = isPtrTy(rt) ? (u32)4 : irWidth(rt);
        if (w == (u32)0)
            w = (u32)4;
        bool sgn = isSignedTy(rt);
        if (w == (u32)1)
            {
            if (sgn)
                _out.appendFormat("\tmove.b\t%s,d0\n\text.w\td0\n\text.l\td0\n", mem.cString());
            else
                _out.appendFormat("\tmoveq\t#0,d0\n\tmove.b\t%s,d0\n", mem.cString());
            }
        else if (w == (u32)2)
            {
            if (sgn)
                _out.appendFormat("\tmove.w\t%s,d0\n\text.l\td0\n", mem.cString());
            else
                _out.appendFormat("\tmoveq\t#0,d0\n\tmove.w\t%s,d0\n", mem.cString());
            }
        else if (w == (u32)8 && (isI64(rt) || isF64(rt)))
            {
            // Two longs, high first (big-endian), straight into the slot: the
            // 4-byte arm below loaded only the high word and then stored it as
            // if it were the whole value. F64 as well as i64 — `*p = 3.1d` read
            // back as something else, and that is what made every `%lf` print
            // at float precision (the vararg buffer is written through a
            // pointer).
            //
            // The SECOND long is at address+4, and the only way to say that for
            // an arbitrary addressing mode is to put the address in a register
            // first: string-prefixing "4" onto `mem` produced `4-8(a6)`, which
            // the assembler rejects. It worked only while every 8-byte load
            // came through plain `(a0)`.
            // `lea mem,a0` first, then (a0) and 4(a0). That works for EVERY
            // addressing mode `mem` can be — a walking pointer's (aN), a folded
            // displacement, an absolute — where reloading the pointer OPERAND
            // does not: with the address FOLDED, operand[0]'s slot is never
            // written, so the load came back from garbage.
            i32 db = slotOf(n.res());
            if (!mem.equals(String.withCString("(a0)")))
                _out.appendFormat("\tlea\t%s,a0\n", mem.cString());
            _out.appendCString("\tmove.l\t(a0),d0\n");
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n", db);
            _out.appendCString("\tmove.l\t4(a0),d0\n");
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n", db + (i32)4);
            return;
            }
        else
            {
            _out.appendFormat("\tmove.l\t%s,d0\n", mem.cString());
            }
        storeReg(String.withCString("d0"), n.res());
        }

    void emitStore(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        IROperand* valOp = (IROperand*)n.ops().get((u32)1);
        String* vt = valOp.kind() == (u8)OPK_USE && valOp.val() != (IRValue*)0
                         ? valOp.val().ty()
                         : valOp.ty();
        if (isAggTy(vt))
            {
            // The value is a materialised aggregate in a frame slot — byte-copy
            // its full width, not one long.
            u32 wide = aggSize(layoutOf(vt));
            loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("a0"));
            _out.appendFormat("\tlea\t%ld(a6),a1\n", slotOf(valOp.val()));
            emitByteCopyLoop(wide);
            return;
            }
        // An eight-byte value is two longs in a slot; copy both, high first.
        // F64 as well as i64: `*p = 3.1d` stored ONE long, so the value read
        // back was not the value written. Only visible with a constant whose
        // low word is non-zero — 1.5, 3.25 and 7.75 all survive a half-store.
        if ((isI64(vt) || isF64(vt)) && valOp.kind() == (u8)OPK_USE && valOp.val() != (IRValue*)0)
            {
            // The DESTINATION goes through the same addressOperand machinery
            // the narrow path below uses, then is `lea`d into a0 so the second
            // long can be written at +4. Reloading operand[0] from its slot was
            // wrong whenever the address had been FOLDED: that slot is never
            // written, so the store landed on garbage and the value did not
            // arrive at all.
            String* dmem = addressOperand(fn, (IROperand*)n.ops().get((u32)0));
            if (!dmem.equals(String.withCString("(a0)")))
                _out.appendFormat("\tlea\t%s,a0\n", dmem.cString());
            i32 so = slotOf(valOp.val());
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\td0,(a0)\n", so);
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\td0,4(a0)\n", so + (i32)4);
            return;
            }
        loadOperand(valOp, String.withCString("d0"));
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        String* mem = addressOperand(fn, p);
        u32 w = widthOfOperand(valOp);
        if (w == (u32)1)
            _out.appendFormat("\tmove.b\td0,%s\n", mem.cString());
        else if (w == (u32)2)
            _out.appendFormat("\tmove.w\td0,%s\n", mem.cString());
        else
            _out.appendFormat("\tmove.l\td0,%s\n", mem.cString());
        }

    // The IR width an operand is read at. A pointer's IR width is 0, so the
    // default of 4 covers it.
    // The IR TYPE an operand is read at (null when it has none) — the
    // type-level companion to widthOfOperand.
    static String* operandTy(IROperand* op)
        {
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            return op.val().ty();
        return op.ty();
        }

    static u32 widthOfOperand(IROperand* op)
        {
        String* t = (String*)0;
        if (op.kind() == (u8)OPK_IMMI)
            t = op.ty();
        else if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            t = op.val().ty();
        u32 w = irWidth(t);
        return w == (u32)0 ? (u32)4 : w;
        }

    void emitByteCopyLoop(u32 wide)
        {
        u32 nlbl = _labelSeq;
        _labelSeq = _labelSeq + (u32)1;
        _out.appendFormat("\tmove.l\t#%lu,d0\n.Lcpy%lu:\n\tmove.b\t(a1)+,(a0)+\n", wide, nlbl);
        _out.appendFormat("\tsubq.l\t#1,d0\n\tbne.s\t.Lcpy%lu\n", nlbl);
        }

    void emitAddrOf(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        if (src.kind() == (u8)OPK_SYM)
            {
            _out.appendFormat("\tlea\t%s,a0\n", m68kSym(src.name()).cString());
            storeReg(String.withCString("a0"), n.res());
            return;
            }
        if (src.kind() == (u8)OPK_USE && src.val() != (IRValue*)0)
            {
            // The address of a pinned local: its slot IS the object.
            _out.appendFormat("\tlea\t%ld(a6),a0\n", slotOf(src.val()));
            storeReg(String.withCString("a0"), n.res());
            return;
            }
        unsupported(String.withCString("AddrOf:operand"));
        }

    void emitFieldAddr(IRInsn* n)
        {
        if (n.res() != (IRValue*)0 && isFolded(n.res()))
            return; // folded into its Load/Store
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        u32 off = fieldByteOffset(n);
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        if (off != (u32)0)
            _out.appendFormat("\tadd.l\t#%lu,d0\n", off);
        storeReg(String.withCString("d0"), n.res());
        }

    void emitElementAddr(IRInsn* n)
        {
        if (n.res() != (IRValue*)0 && isFolded(n.res()))
            return; // folded into its Load/Store
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        u32 stride = elemStride(n);
        IROperand* idxOp = (IROperand*)n.ops().get((u32)1);
        if (idxOp.kind() == (u8)OPK_IMMI)
            {
            // A constant index — the pointer-IV advance `pNext = p + step` —
            // folds the whole offset to a compile-time displacement, computed
            // straight in the result's home register.
            i32 disp = idxOp.imm() * (i32)stride;
            String* rhome = n.res() == (IRValue*)0 ? (String*)0 : homeOf(n.res());
            String* dst = rhome != (String*)0 ? rhome : String.withCString("d0");
            loadOperand((IROperand*)n.ops().get((u32)0), dst);
            if (disp >= (i32)1 && disp <= (i32)8)
                _out.appendFormat("\taddq.l\t#%ld,%s\n", disp, dst.cString());
            else if (disp >= (i32)-8 && disp <= (i32)-1)
                _out.appendFormat("\tsubq.l\t#%ld,%s\n", -disp, dst.cString());
            else if (disp != (i32)0)
                _out.appendFormat("\tadd.l\t#%ld,%s\n", disp, dst.cString());
            storeReg(dst, n.res());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        // A 64-bit index reads its LOW long — plain loadOperand brings the
        // HIGH half, resolving every u64-indexed element to element 0.
        loadOperandLow32(idxOp, String.withCString("d1"));
        if (stride == (u32)2)
            _out.appendCString("\tlsl.l\t#1,d1\n");
        else if (stride == (u32)4)
            _out.appendCString("\tlsl.l\t#2,d1\n");
        else if (stride == (u32)8)
            _out.appendCString("\tlsl.l\t#3,d1\n");
        else if (stride != (u32)1)
            {
            if (_cpu >= (u32)68020)
                {
                _out.appendFormat("\tmove.l\t#%lu,d2\n", stride);
                _out.appendCString("\tmuls.l\td2,d1\n");
                }
            else
                {
                // __mulsi3 takes its arguments in d0/d1, returns in d0 and may
                // clobber d1-d5 — so it cannot scale d1 in place, and it would
                // eat the base sitting in d0. Spill the base, multiply per the
                // helper's ABI, reassemble. (A power of two never reaches here.)
                _out.appendCString("\tmove.l\td0,-(sp)\n");
                _out.appendCString("\tmove.l\td1,d0\n");
                _out.appendFormat("\tmove.l\t#%lu,d1\n", stride);
                _out.appendCString("\tjsr\t__mulsi3\n");
                _out.appendCString("\tmove.l\td0,d1\n");
                _out.appendCString("\tmove.l\t(sp)+,d0\n");
                }
            }
        _out.appendCString("\tadd.l\td1,d0\n");
        storeReg(String.withCString("d0"), n.res());
        }

    // The integer binaries that are one m68k ALU instruction, or null.
    static String* intBinOpMnemonic(String* op)
        {
        if (op.equals(String.withCString("Add")))
            return String.withCString("add");
        if (op.equals(String.withCString("Sub")))
            return String.withCString("sub");
        if (op.equals(String.withCString("And")))
            return String.withCString("and");
        if (op.equals(String.withCString("Or")))
            return String.withCString("or");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("eor");
        return (String*)0;
        }

    // An immediate's TEXT. A large U32 read back through a signed 32-bit
    // integer comes out negative — the reference carries 64 bits and never has
    // to choose — so the operand's own unsigned flag decides the spelling.
    static String* immText(IROperand* op)
        {
        String* s = String.withCString("");
        if (op.uimm())
            s.appendFormat("%lu", (u32)op.imm());
        else
            s.appendFormat("%ld", op.imm());
        return s;
        }

    // ── Operand helpers ──────────────────────────────────────────────────
    //
    // A value lives in one of three places: a home register, a frame slot, or
    // (for an immediate) nowhere at all.
    void loadOperand(IROperand* op, String* reg)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmove.l\t#%s,%s\n", immText(op).cString(), reg.cString());
            return;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            unsupported(String.withCString("operand"));
            return;
            }
        String* pareg = ptrRegOf(op.val()); // a walking pointer IS its register
        if (pareg != (String*)0)
            {
            if (!pareg.equals(reg))
                _out.appendFormat("\tmove.l\t%s,%s\n", pareg.cString(), reg.cString());
            return;
            }
        String* home = homeOf(op.val());
        if (home != (String*)0)
            {
            if (!home.equals(reg))
                _out.appendFormat("\tmove.l\t%s,%s\n", home.cString(), reg.cString());
            return;
            }
        // A value with NO slot is a memory token that reached an operand
        // position — it holds nothing to load. The reference notes it and
        // emits no instruction; loading from 0(a6) instead would read the
        // saved frame pointer.
        if (!hasSlot(op.val()))
            {
            // No id: it is not stable across a dump-and-reparse of the IR
            // (the printer renumbers), and this note is about a value that
            // holds nothing anyway. See the matching comment in the reference.
            _out.appendFormat("\t; <unmapped use> -> %s\n", reg.cString());
            return;
            }
        _out.appendFormat("\tmove.l\t%ld(a6),%s\n", slotOf(op.val()), reg.cString());
        }

    // loadOperand, except a 64-bit operand reads its LOW long. An i64 lives
    // in an 8-byte slot pair (high at slot, low at slot+4 — big-endian), and
    // loadOperand's single move.l from the slot base delivers the HIGH half.
    // Consumers that use a 64-bit value AS a 32-bit quantity (element index,
    // truncation source) want the significant half.
    void loadOperandLow32(IROperand* op, String* reg)
        {
        // The SLOT is authoritative for a 64-bit value even when the homing
        // pass gave it a register: a 32-bit home can hold only one half, and
        // every 64-bit producer writes the slot pair. Read low = slot+4.
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0 && isI64(op.val().ty()) && hasSlot(op.val()))
            {
            _out.appendFormat("\tmove.l\t%ld(a6),%s\n", slotOf(op.val()) + (i32)4, reg.cString());
            return;
            }
        loadOperand(op, reg);
        }

    bool hasSlot(IRValue* v)
        {
        return v != (IRValue*)0 && _slot.get((Hashable*)v) != (Object*)0;
        }

    // A homed value lives in its register and is written THERE ONLY — the slot
    // mirror is skipped. What still reads slots directly (float ops,
    // stack-passed arguments) consumes only UN-homed values, so those slots
    // stay authoritative.
    void storeReg(String* reg, IRValue* r)
        {
        if (r == (IRValue*)0)
            return;
        String* home = homeOf(r);
        if (home != (String*)0)
            {
            if (!home.equals(reg))
                _out.appendFormat("\tmove.l\t%s,%s\n", reg.cString(), home.cString());
            return;
            }
        _out.appendFormat("\tmove.l\t%s,%ld(a6)\n", reg.cString(), slotOf(r));
        }

    // The cheapest addressing for an ALU source: an immediate (addq/subq for a
    // 1..8 add or sub), a home register, or a memory slot — m68k ALU ops take a
    // memory source directly.
    void emitAlu(String* mnem, IROperand* src, String* dst)
        {
        if (src.kind() == (u8)OPK_IMMI)
            {
            bool addsub = mnem.equals(String.withCString("add")) || mnem.equals(String.withCString("sub"));
            // addq/subq take 1..8. The test is on the VALUE and nothing else:
            //   * `!src.uimm()` used to exclude every UNSIGNED immediate, so
            //     `x + 3u` came out as a full `add.l #3` — which is why every
            //     m68k file diverged from the reference at -O3 (bug 082). uimm
            //     records how the bits READ, not how big they are, and for 1..8
            //     signed and unsigned are the same eight values.
            //   * the comparison is i64. Truncating to i32 first would let
            //     0x100000003 look like 3 and emit `addq #3` for it — the
            //     opposite mistake, and a silent one.
            i64 k = src.imm();
            if (addsub && k >= (i64)1 && k <= (i64)8)
                _out.appendFormat("\t%sq.l\t#%lld,%s\n", mnem.cString(), k, dst.cString());
            else
                _out.appendFormat("\t%s.l\t#%s,%s\n", mnem.cString(), immText(src).cString(),
                                  dst.cString());
            return;
            }
        String* ea = (String*)0;
        if (src.kind() == (u8)OPK_USE && src.val() != (IRValue*)0)
            {
            String* home = homeOf(src.val());
            if (home != (String*)0)
                ea = home;
            // eor has NO `<ea>,Dn` form on m68k — only `Dn,<ea>` — so a spilled
            // eor source has to come through a data register.
            else if (!mnem.equals(String.withCString("eor")))
                {
                ea = String.withCString("");
                ea.appendFormat("%ld(a6)", slotOf(src.val()));
                }
            }
        if (ea == (String*)0)
            {
            loadOperand(src, String.withCString("d1"));
            ea = String.withCString("d1");
            }
        _out.appendFormat("\t%s.l\t%s,%s\n", mnem.cString(), ea.cString(), dst.cString());
        }

    // dst = op0 <mnem> op1. Two-address, computed directly in the result's home
    // register when it has one, so a homed accumulator or induction variable
    // never round-trips through scratch.
    // ── 64-bit integers ──────────────────────────────────────────────────
    //
    // An i64 lives in a MEMORY SLOT exactly as a double does, so the register
    // allocator needs no notion of a pair and the only new thing here is the
    // call. Each arithmetic operation is one line-A HLE helper (selectors
    // $20-$2C, implemented in src/xst/sim68k.c) taking both operands on the
    // stack high word first and returning in d0:d1 — the same shape the
    // soft-float f64 path already uses.
    //
    // Returns false for an opcode this does not handle, so the caller falls
    // through to the ordinary paths.
    bool emitInt64(IRInsn* n, String* op)
        {
        i32 r = slotOf(n.res());
        u32 nops = n.ops().count();
        if (nops < (u32)1)
            return false;
        IROperand* a0 = (IROperand*)n.ops().get((u32)0);
        // A 64-bit CONSTANT needs both longs written. The Const path emits a
        // single `move.l #imm`, which left the high word holding whatever the
        // slot had — a correct low half and a wrong high half.
        if (op.equals(String.withCString("Const")) && a0.kind() == (u8)OPK_IMMI)
            {
            i64 v = a0.imm();
            _out.appendFormat("\tmove.l\t#%lu,%ld(a6)\n", (u32)(v >> (i64)32), r);
            _out.appendFormat("\tmove.l\t#%lu,%ld(a6)\n", (u32)v, r + (i32)4);
            return true;
            }
        // Widening INTO 64 bits. `(u64)1000000` is not a 64-bit constant — it
        // is a 32-bit Const followed by a ZExt — so without this the low long
        // was written and the high long kept whatever the slot held.
        if (op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")))
            {
            loadOperand(a0, String.withCString("d0"));
            extendD0ToPair(op.equals(String.withCString("SExt")), widthOfOperand(a0));
            // Big-endian: the HIGH long sits at the lower address.
            _out.appendFormat("\tmove.l\td1,%ld(a6)\n\tmove.l\td0,%ld(a6)\n", r, r + (i32)4);
            return true;
            }
        // A same-width reinterpretation (i64 <-> u64) is an eight-byte copy,
        // not the `move.l` the generic Bitcast falls through to.
        if (op.equals(String.withCString("Bitcast")) && a0.kind() == (u8)OPK_USE && a0.val() != (IRValue*)0 && isI64(a0.val().ty()))
            {
            i32 so = slotOf(a0.val());
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\td0,%ld(a6)\n", so, r);
            _out.appendFormat("\tmove.l\t%ld(a6),d0\n\tmove.l\td0,%ld(a6)\n",
                              so + (i32)4, r + (i32)4);
            return true;
            }
        // The UNARY 64-bit ops. Without this they fell through to the 32-bit
        // `neg.l d0` / `not.l d0`, touching only the low long. Expressed as the
        // equivalent binary helper call (0 - x, x ^ -1) rather than the m68k
        // `neg.l`+`negx.l` pair, because the simulator implements neither NEGX
        // nor ADDX, so that pair assembles and then traps at run time.
        if (nops == (u32)1)
            {
            bool isNeg = op.equals(String.withCString("Neg"));
            if (!isNeg && !op.equals(String.withCString("Not")))
                return false;
            if (isNeg)
                {
                pushInt64Operand(a0); // a1 = x
                _out.appendCString("\tmove.l\t#0,-(sp)\n");
                _out.appendCString("\tmove.l\t#0,-(sp)\n"); // a0 = 0
                }
            else
                {
                _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", (u32)-1);
                _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", (u32)-1); // a1 = -1
                pushInt64Operand(a0);                                 // a0 = x
                }
            _out.appendFormat("\tjsr\t%s\n\tlea\t16(sp),sp\n",
                              isNeg ? "__subdi3" : "__xordi3");
            _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n",
                              r, r + (i32)4);
            return true;
            }
        if (nops < (u32)2)
            return false;
        String* h = (String*)0;
        if (op.equals(String.withCString("Add")))
            h = String.withCString("__adddi3");
        else if (op.equals(String.withCString("Sub")))
            h = String.withCString("__subdi3");
        else if (op.equals(String.withCString("Mul")))
            h = String.withCString("__muldi3");
        else if (op.equals(String.withCString("SDiv")))
            h = String.withCString("__divdi3");
        else if (op.equals(String.withCString("UDiv")))
            h = String.withCString("__udivdi3");
        else if (op.equals(String.withCString("SRem")))
            h = String.withCString("__moddi3");
        else if (op.equals(String.withCString("URem")))
            h = String.withCString("__umoddi3");
        else if (op.equals(String.withCString("And")))
            h = String.withCString("__anddi3");
        else if (op.equals(String.withCString("Or")))
            h = String.withCString("__ordi3");
        else if (op.equals(String.withCString("Xor")))
            h = String.withCString("__xordi3");
        else if (op.equals(String.withCString("Shl")))
            h = String.withCString("__ashldi3");
        else if (op.equals(String.withCString("LShr")))
            h = String.withCString("__lshrdi3");
        else if (op.equals(String.withCString("AShr")))
            h = String.withCString("__ashrdi3");
        if (h == (String*)0)
            return false;
        pushInt64Operand((IROperand*)n.ops().get((u32)1));
        pushInt64Operand(a0);
        _out.appendFormat("\tjsr\t%s\n\tlea\t16(sp),sp\n", h.cString());
        _out.appendFormat("\tmove.l\td0,%ld(a6)\n\tmove.l\td1,%ld(a6)\n", r, r + (i32)4);
        return true;
        }

    // Push one 64-bit operand: LOW long first, so the high long ends up at the
    // lower address (big-endian), matching how a double is passed.
    //
    // An operand of a 64-bit operation is NOT always 64 bits wide. A shift
    // count is the everyday case — `v >> n` lowers as `LShr %wide, %n:U8` —
    // and reading two longs out of a four-byte slot takes the next slot along
    // as the high half, so the count comes out enormous and the result zero.
    void pushInt64Operand(IROperand* op)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            i64 v = op.imm();
            _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", (u32)v);
            _out.appendFormat("\tmove.l\t#%lu,-(sp)\n", (u32)(v >> (i64)32));
            return;
            }
        String* st = op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0
                         ? op.val().ty()
                         : (String*)0;
        if (!isI64(st))
            {
            loadOperand(op, String.withCString("d0"));
            extendD0ToPair(isSignedTy(st), widthOfOperand(op));
            _out.appendCString("\tmove.l\td0,-(sp)\n\tmove.l\td1,-(sp)\n"); // low, then high
            return;
            }
        i32 off = slotOf(op.val());
        _out.appendFormat("\tmove.l\t%ld(a6),-(sp)\n\tmove.l\t%ld(a6),-(sp)\n",
                          off + (i32)4, off);
        }

    // Extend the 32-bit value in d0 to the pair d1:d0 (high:low), in place.
    void extendD0ToPair(bool sgn, u32 w)
        {
        if (sgn)
            {
            if (w == (u32)1)
                _out.appendCString("\text.w\td0\n\text.l\td0\n");
            else if (w == (u32)2)
                _out.appendCString("\text.l\td0\n");
            // Smear the sign across the high long: d1 = d0 >> 31 (arithmetic).
            _out.appendCString("\tmove.l\td0,d1\n\tasr.l\t#8,d1\n\tasr.l\t#8,d1\n\tasr.l\t#8,d1\n\tasr.l\t#7,d1\n");
            }
        else
            {
            if (w == (u32)1)
                _out.appendCString("\tand.l\t#$ff,d0\n");
            else if (w == (u32)2)
                _out.appendCString("\tand.l\t#$ffff,d0\n");
            _out.appendCString("\tmoveq\t#0,d1\n");
            }
        }

    void emitBinary(String* mnem, IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            {
            unsupported(n.op());
            return;
            }
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        IROperand* b = (IROperand*)n.ops().get((u32)1);
        bool commut = !mnem.equals(String.withCString("sub"));
        String* rhome = n.res() == (IRValue*)0 ? (String*)0 : homeOf(n.res());
        String* dst = rhome != (String*)0 ? rhome : String.withCString("d0");
        String* aHome = operandHome(a);
        String* bHome = operandHome(b);
        bool aInDst = aHome != (String*)0 && aHome.equals(dst);
        bool bInDst = bHome != (String*)0 && bHome.equals(dst);

        IROperand* src;
        if (aInDst)
            {
            src = b; // dst already holds a
            }
        else if (bInDst && commut)
            {
            src = a; // dst holds b; commute
            }
        else if (bInDst)
            {
            // A subtract with the SUBTRAHEND already in dst: stash it, load the
            // minuend over it, then subtract.
            _out.appendFormat("\tmove.l\t%s,d1\n", dst.cString());
            loadOperand(a, dst);
            _out.appendFormat("\tsub.l\td1,%s\n", dst.cString());
            storeReg(dst, n.res());
            return;
            }
        else
            {
            loadOperand(a, dst);
            src = b;
            }
        emitAlu(mnem, src, dst);
        storeReg(dst, n.res());
        }

    String* operandHome(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (String*)0;
        return homeOf(o.val());
        }

    void emitUnary(IRInsn* n, String* mnem)
        {
        if (n.ops().count() < (u32)1)
            {
            unsupported(n.op());
            return;
            }
        loadOperand((IROperand*)n.ops().get((u32)0), String.withCString("d0"));
        _out.appendFormat("\t%s.l\td0\n", mnem.cString());
        storeReg(String.withCString("d0"), n.res());
        }

    // Scc/Bcc condition for an ICmp predicate, and for its NEGATION — a fused
    // CondBranch branches on the negation, so it can skip materialising the
    // boolean at all.
    static String* condFor(String* p)
        {
        if (p == (String*)0)
            return String.withCString("eq");
        if (p.equals(String.withCString("EQ")))
            return String.withCString("eq");
        if (p.equals(String.withCString("NE")))
            return String.withCString("ne");
        if (p.equals(String.withCString("SLT")))
            return String.withCString("lt");
        if (p.equals(String.withCString("SGT")))
            return String.withCString("gt");
        if (p.equals(String.withCString("SLE")))
            return String.withCString("le");
        if (p.equals(String.withCString("SGE")))
            return String.withCString("ge");
        if (p.equals(String.withCString("ULT")))
            return String.withCString("cs");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("hi");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("ls");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("cc");
        return String.withCString("eq");
        }

    // The predicate applied to a -1/0/1 helper RESULT, which is always tested
    // SIGNED — the operands' own signedness was already spent on choosing the
    // helper. Reusing condFor here would emit `cs`/`hi` against a signed value.
    static String* condForSignOf(String* p)
        {
        if (p == (String*)0)
            return String.withCString("eq");
        if (p.equals(String.withCString("NE")))
            return String.withCString("ne");
        if (p.equals(String.withCString("SLT")) || p.equals(String.withCString("ULT")))
            return String.withCString("lt");
        if (p.equals(String.withCString("SGT")) || p.equals(String.withCString("UGT")))
            return String.withCString("gt");
        if (p.equals(String.withCString("SLE")) || p.equals(String.withCString("ULE")))
            return String.withCString("le");
        if (p.equals(String.withCString("SGE")) || p.equals(String.withCString("UGE")))
            return String.withCString("ge");
        return String.withCString("eq");
        }

    static String* condForNegated(String* p)
        {
        if (p == (String*)0)
            return String.withCString("ne");
        if (p.equals(String.withCString("EQ")))
            return String.withCString("ne");
        if (p.equals(String.withCString("NE")))
            return String.withCString("eq");
        if (p.equals(String.withCString("SLT")))
            return String.withCString("ge");
        if (p.equals(String.withCString("SGT")))
            return String.withCString("le");
        if (p.equals(String.withCString("SLE")))
            return String.withCString("gt");
        if (p.equals(String.withCString("SGE")))
            return String.withCString("lt");
        if (p.equals(String.withCString("ULT")))
            return String.withCString("cc");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("ls");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("hi");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("cs");
        return String.withCString("ne");
        }

    // The addressing a phi-edge copy reads its source through: an immediate,
    // a home register, or a memory slot.
    String* eaOf(IROperand* op)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            String* s = String.withCString("#");
            s.append(immText(op));
            return s;
            }
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            {
            String* home = homeOf(op.val());
            if (home != (String*)0)
                return home;
            String* s = String.withCString("");
            s.appendFormat("%ld(a6)", slotOf(op.val()));
            return s;
            }
        return (String*)0;
        }

    // ── Runtime stubs ────────────────────────────────────────────────────
    //
    // Helpers are reached as `jsr <name>` either from an IR Call (_putc) or
    // introduced by the back end during lowering (__mulsi3, …). Which ones are
    // needed is decided by SCANNING THE ALREADY-EMITTED CODE — the stubs are
    // appended after it, so their own labels are not present yet and cannot
    // make a helper look used by defining it.
    bool usesHelper(String* name)
        {
        String* needle = String.withCString("\tjsr\t");
        needle.append(name);
        needle.appendCString("\n");
        return _out.byteIndexOf(needle) != (u32)$FFFF_FFFF;
        }

    bool moduleDefines(IRModule* m, String* name)
        {
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)m.funcs().get(i)).name().equals(name))
                return true;
        return false;
        }

    void emitRuntimeStubs(IRModule* m)
        {
        String* putc = String.withCString("_putc");
        if (usesHelper(putc) && !moduleDefines(m, putc))
            {
            _out.appendCString("; runtime: _putc(u8) -> GEMDOS Cconout\n");
            _out.appendCString("\t.globl\t_putc\n_putc:\n");
            _out.appendCString("\tmove.l\t4(sp),d0\n");
            _out.appendCString("\tmove.w\td0,-(sp)\n");
            _out.appendCString("\tmove.w\t#2,-(sp)\t; Cconout\n");
            _out.appendCString("\ttrap\t#1\n");
            _out.appendCString("\taddq.l\t#4,sp\n");
            _out.appendCString("\trts\n\n");
            }
            // The GEMDOS runtime behind Files.xc and Process.xc (bugs 127/128) —
            // the mirror of XTM68kBackend.emitRuntimeStubs, generated from the same text.
            {
            String* nm = String.withCString("_xt_file_open");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_open(path, mode) -> handle, <0 on failure : GEMDOS Fopen/Fcreate\n");
                _out.appendCString("\t.globl\t_xt_file_open\n");
                _out.appendCString("_xt_file_open:\n");
                _out.appendCString("\tmove.l\td3,-(sp)\n");
                _out.appendCString("\tmove.l\t12(sp),a0\t\t; mode string\n");
                _out.appendCString("\tmove.b\t(a0),d3\t\t\t; first byte: r / w / a\n");
                _out.appendCString("\tmoveq\t#119,d1\t\t\t; 'w' -> create (truncate)\n");
                _out.appendCString("\tcmp.b\td1,d3\n");
                _out.appendCString("\tbeq\t.xfo_create\n");
                _out.appendCString("\tmoveq\t#0,d2\t\t\t; 'r' -> read-only\n");
                _out.appendCString("\tmove.b\t1(a0),d1\n");
                _out.appendCString("\tmoveq\t#43,d0\t\t\t; '+' -> read/write\n");
                _out.appendCString("\tcmp.b\td0,d1\n");
                _out.appendCString("\tbne\t.xfo_m1\n");
                _out.appendCString("\tmoveq\t#2,d2\n");
                _out.appendCString(".xfo_m1:\n");
                _out.appendCString("\tmoveq\t#97,d1\t\t\t; 'a' -> read/write, then seek to the end\n");
                _out.appendCString("\tcmp.b\td1,d3\n");
                _out.appendCString("\tbne\t.xfo_m2\n");
                _out.appendCString("\tmoveq\t#2,d2\n");
                _out.appendCString(".xfo_m2:\n");
                _out.appendCString("\tmove.w\td2,-(sp)\t\t; mode\n");
                _out.appendCString("\tmove.l\t10(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$3D,-(sp)\t\t; Fopen\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#8,sp\n");
                _out.appendCString("\tmoveq\t#97,d1\n");
                _out.appendCString("\tcmp.b\td1,d3\n");
                _out.appendCString("\tbne\t.xfo_done\n");
                _out.appendCString("\tmove.l\td0,d0\t\t\t; append to a missing file -> create it\n");
                _out.appendCString("\tbmi\t.xfo_create\n");
                _out.appendCString("\tmove.l\td0,d3\t\t\t; handle\n");
                _out.appendCString("\tmove.w\t#2,-(sp)\t\t; SEEK_END\n");
                _out.appendCString("\tmove.w\td3,-(sp)\n");
                _out.appendCString("\tmove.l\t#0,-(sp)\t\t; offset 0\n");
                _out.appendCString("\tmove.w\t#$42,-(sp)\t\t; Fseek\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\tlea\t10(sp),sp\n");
                _out.appendCString("\tmove.l\td3,d0\n");
                _out.appendCString("\tbra\t.xfo_done\n");
                _out.appendCString(".xfo_create:\n");
                _out.appendCString("\tmove.w\t#0,-(sp)\t\t; attributes\n");
                _out.appendCString("\tmove.l\t10(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$3C,-(sp)\t\t; Fcreate\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#8,sp\n");
                _out.appendCString(".xfo_done:\n");
                _out.appendCString("\tmove.l\t(sp)+,d3\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_read");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_read(handle, buf, n) -> bytes read, <0 on failure : GEMDOS Fread\n");
                _out.appendCString("\t.globl\t_xt_file_read\n");
                _out.appendCString("_xt_file_read:\n");
                _out.appendCString("\tmove.l\t8(sp),-(sp)\t\t; buf\n");
                _out.appendCString("\tmove.l\t16(sp),-(sp)\t\t; n\n");
                _out.appendCString("\tmove.w\t14(sp),-(sp)\t\t; handle\n");
                _out.appendCString("\tmove.w\t#$3F,-(sp)\t\t; Fread\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\tlea\t12(sp),sp\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_write");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_write(handle, buf, n) -> bytes written, <0 on failure : GEMDOS Fwrite\n");
                _out.appendCString("\t.globl\t_xt_file_write\n");
                _out.appendCString("_xt_file_write:\n");
                _out.appendCString("\tmove.l\t8(sp),-(sp)\t\t; buf\n");
                _out.appendCString("\tmove.l\t16(sp),-(sp)\t\t; n\n");
                _out.appendCString("\tmove.w\t14(sp),-(sp)\t\t; handle\n");
                _out.appendCString("\tmove.w\t#$40,-(sp)\t\t; Fwrite\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\tlea\t12(sp),sp\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_close");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_close(handle) : GEMDOS Fclose\n");
                _out.appendCString("\t.globl\t_xt_file_close\n");
                _out.appendCString("_xt_file_close:\n");
                _out.appendCString("\tmove.w\t6(sp),-(sp)\t\t; handle\n");
                _out.appendCString("\tmove.w\t#$3E,-(sp)\t\t; Fclose\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#4,sp\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_size");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_size(path) -> bytes, -1 when it cannot be opened : Fopen/Fseek/Fclose\n");
                _out.appendCString("\t.globl\t_xt_file_size\n");
                _out.appendCString("_xt_file_size:\n");
                _out.appendCString("\tmove.l\td3,-(sp)\n");
                _out.appendCString("\tmove.w\t#0,-(sp)\t\t; read-only\n");
                _out.appendCString("\tmove.l\t10(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$3D,-(sp)\t\t; Fopen\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#8,sp\n");
                _out.appendCString("\tmove.l\td0,d0\n");
                _out.appendCString("\tbmi\t.xfz_fail\n");
                _out.appendCString("\tmove.l\td0,d3\t\t\t; handle\n");
                _out.appendCString("\tmove.w\t#2,-(sp)\t\t; SEEK_END\n");
                _out.appendCString("\tmove.w\td3,-(sp)\n");
                _out.appendCString("\tmove.l\t#0,-(sp)\t\t; offset 0\n");
                _out.appendCString("\tmove.w\t#$42,-(sp)\t\t; Fseek -> d0 = size\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\tlea\t10(sp),sp\n");
                _out.appendCString("\tmove.l\td0,-(sp)\t\t; keep the size across Fclose\n");
                _out.appendCString("\tmove.w\td3,-(sp)\n");
                _out.appendCString("\tmove.w\t#$3E,-(sp)\t\t; Fclose\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#4,sp\n");
                _out.appendCString("\tmove.l\t(sp)+,d0\n");
                _out.appendCString("\tbra\t.xfz_done\n");
                _out.appendCString(".xfz_fail:\n");
                _out.appendCString("\tmoveq\t#-1,d0\n");
                _out.appendCString(".xfz_done:\n");
                _out.appendCString("\tmove.l\t(sp)+,d3\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_exists");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_exists(path) -> 1 / 0 : Fopen read-only, Fclose\n");
                _out.appendCString("\t.globl\t_xt_file_exists\n");
                _out.appendCString("_xt_file_exists:\n");
                _out.appendCString("\tmove.w\t#0,-(sp)\t\t; read-only\n");
                _out.appendCString("\tmove.l\t6(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$3D,-(sp)\t\t; Fopen\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#8,sp\n");
                _out.appendCString("\tmove.l\td0,d0\n");
                _out.appendCString("\tbmi\t.xfe_no\n");
                _out.appendCString("\tmove.w\td0,-(sp)\n");
                _out.appendCString("\tmove.w\t#$3E,-(sp)\t\t; Fclose\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#4,sp\n");
                _out.appendCString("\tmoveq\t#1,d0\n");
                _out.appendCString("\trts\n");
                _out.appendCString(".xfe_no:\n");
                _out.appendCString("\tmoveq\t#0,d0\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_exists_exact");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_exists_exact(path) -> 1 / 0 : TOS names are case-insensitive, same answer as exists\n");
                _out.appendCString("\t.globl\t_xt_file_exists_exact\n");
                _out.appendCString("_xt_file_exists_exact:\n");
                _out.appendCString("\tmove.w\t#0,-(sp)\t\t; read-only\n");
                _out.appendCString("\tmove.l\t6(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$3D,-(sp)\t\t; Fopen\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#8,sp\n");
                _out.appendCString("\tmove.l\td0,d0\n");
                _out.appendCString("\tbmi\t.xfx_no\n");
                _out.appendCString("\tmove.w\td0,-(sp)\n");
                _out.appendCString("\tmove.w\t#$3E,-(sp)\t\t; Fclose\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#4,sp\n");
                _out.appendCString("\tmoveq\t#1,d0\n");
                _out.appendCString("\trts\n");
                _out.appendCString(".xfx_no:\n");
                _out.appendCString("\tmoveq\t#0,d0\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_file_chmod_exec");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_file_chmod_exec(path) -> 0 : TOS has no execute bit\n");
                _out.appendCString("\t.globl\t_xt_file_chmod_exec\n");
                _out.appendCString("_xt_file_chmod_exec:\n");
                _out.appendCString("\tmoveq\t#0,d0\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_mkdir");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_mkdir(path) -> 0 on success, <0 on failure : GEMDOS Dcreate\n");
                _out.appendCString("\t.globl\t_xt_mkdir\n");
                _out.appendCString("_xt_mkdir:\n");
                _out.appendCString("\tmove.l\t4(sp),-(sp)\t\t; path\n");
                _out.appendCString("\tmove.w\t#$39,-(sp)\t\t; Dcreate\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\taddq.l\t#6,sp\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_exit");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_exit(code) : GEMDOS Pterm, never returns\n");
                _out.appendCString("\t.globl\t_xt_exit\n");
                _out.appendCString("_xt_exit:\n");
                _out.appendCString("\tmove.w\t6(sp),-(sp)\t\t; low word of the code\n");
                _out.appendCString("\tmove.w\t#$4C,-(sp)\t\t; Pterm\n");
                _out.appendCString("\ttrap\t#1\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_argc");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_argc() -> 1 + words on the GEMDOS command line (argv[0] is the name TOS does not pass)\n");
                _out.appendCString("; The basepage sits 256 bytes before TEXT, so no startup storage is needed to find\n");
                _out.appendCString("; it. A NUL is a separator like a space — _xt_argv writes them in place — and only\n");
                _out.appendCString("; the length byte ends the line.\n");
                _out.appendCString("\t.globl\t_xt_argc\n");
                _out.appendCString("_xt_argc:\n");
                _out.appendCString("\tmove.l\td3,-(sp)\n");
                _out.appendCString("\tlea\t_start,a0\n");
                _out.appendCString("\tlea\t-256(a0),a0\t\t; basepage\n");
                _out.appendCString("\tmoveq\t#0,d1\n");
                _out.appendCString("\tmove.b\t128(a0),d1\t\t; command-line length\n");
                _out.appendCString("\tlea\t129(a0),a0\t\t; its first byte\n");
                _out.appendCString("\tmoveq\t#0,d0\t\t\t; words so far\n");
                _out.appendCString("\tmoveq\t#32,d2\t\t\t; ' '\n");
                _out.appendCString(".xac_skip:\n");
                _out.appendCString("\tmove.l\td1,d1\n");
                _out.appendCString("\tbeq\t.xac_done\n");
                _out.appendCString("\tmove.b\t(a0),d3\n");
                _out.appendCString("\tbeq\t.xac_sep\n");
                _out.appendCString("\tcmp.b\td2,d3\n");
                _out.appendCString("\tbne\t.xac_word\n");
                _out.appendCString(".xac_sep:\n");
                _out.appendCString("\taddq.l\t#1,a0\n");
                _out.appendCString("\tsubq.l\t#1,d1\n");
                _out.appendCString("\tbra\t.xac_skip\n");
                _out.appendCString(".xac_word:\n");
                _out.appendCString("\taddq.l\t#1,d0\n");
                _out.appendCString(".xac_in:\n");
                _out.appendCString("\tmove.l\td1,d1\n");
                _out.appendCString("\tbeq\t.xac_done\n");
                _out.appendCString("\tmove.b\t(a0),d3\n");
                _out.appendCString("\tbeq\t.xac_skip\n");
                _out.appendCString("\tcmp.b\td2,d3\n");
                _out.appendCString("\tbeq\t.xac_skip\n");
                _out.appendCString("\taddq.l\t#1,a0\n");
                _out.appendCString("\tsubq.l\t#1,d1\n");
                _out.appendCString("\tbra\t.xac_in\n");
                _out.appendCString(".xac_done:\n");
                _out.appendCString("\taddq.l\t#1,d0\t\t\t; + argv[0]\n");
                _out.appendCString("\tmove.l\t(sp)+,d3\n");
                _out.appendCString("\trts\n");
                _out.appendCString("\n");
                }
            }
            {
            String* nm = String.withCString("_xt_argv");
            if (usesHelper(nm) && !moduleDefines(m, nm))
                {
                _out.appendCString("; runtime: _xt_argv(i) -> the i-th word, NUL-terminated IN PLACE in the basepage's line; \"\" when out of range\n");
                _out.appendCString("\t.globl\t_xt_argv\n");
                _out.appendCString("_xt_argv:\n");
                _out.appendCString("\tmove.l\td3,-(sp)\n");
                _out.appendCString("\tmove.l\t8(sp),d0\t\t; index\n");
                _out.appendCString("\tlea\t_start,a0\n");
                _out.appendCString("\tlea\t-256(a0),a0\t\t; basepage\n");
                _out.appendCString("\tmoveq\t#0,d1\n");
                _out.appendCString("\tmove.b\t128(a0),d1\t\t; command-line length\n");
                _out.appendCString("\tlea\t129(a0),a0\n");
                _out.appendCString("\tmoveq\t#32,d2\t\t\t; ' '\n");
                _out.appendCString("\tmove.l\td0,d0\n");
                _out.appendCString("\tbeq\t.xav_empty\t\t; argv[0]: TOS passes no program name\n");
                _out.appendCString("\tbmi\t.xav_empty\n");
                _out.appendCString(".xav_skip:\n");
                _out.appendCString("\tmove.l\td1,d1\n");
                _out.appendCString("\tbeq\t.xav_empty\n");
                _out.appendCString("\tmove.b\t(a0),d3\n");
                _out.appendCString("\tbeq\t.xav_sep\n");
                _out.appendCString("\tcmp.b\td2,d3\n");
                _out.appendCString("\tbne\t.xav_word\n");
                _out.appendCString(".xav_sep:\n");
                _out.appendCString("\taddq.l\t#1,a0\n");
                _out.appendCString("\tsubq.l\t#1,d1\n");
                _out.appendCString("\tbra\t.xav_skip\n");
                _out.appendCString(".xav_word:\n");
                _out.appendCString("\tsubq.l\t#1,d0\n");
                _out.appendCString("\tbeq\t.xav_found\n");
                _out.appendCString(".xav_in:\n");
                _out.appendCString("\tmove.l\td1,d1\n");
                _out.appendCString("\tbeq\t.xav_empty\n");
                _out.appendCString("\tmove.b\t(a0),d3\n");
                _out.appendCString("\tbeq\t.xav_skip\n");
                _out.appendCString("\tcmp.b\td2,d3\n");
                _out.appendCString("\tbeq\t.xav_skip\n");
                _out.appendCString("\taddq.l\t#1,a0\n");
                _out.appendCString("\tsubq.l\t#1,d1\n");
                _out.appendCString("\tbra\t.xav_in\n");
                _out.appendCString(".xav_found:\n");
                _out.appendCString("\tmove.l\ta0,-(sp)\t\t; the word's start\n");
                _out.appendCString(".xav_end:\n");
                _out.appendCString("\tmove.l\td1,d1\n");
                _out.appendCString("\tbeq\t.xav_term\n");
                _out.appendCString("\tmove.b\t(a0),d3\n");
                _out.appendCString("\tbeq\t.xav_ret\t\t; already terminated by an earlier call\n");
                _out.appendCString("\tcmp.b\td2,d3\n");
                _out.appendCString("\tbeq\t.xav_term\n");
                _out.appendCString("\taddq.l\t#1,a0\n");
                _out.appendCString("\tsubq.l\t#1,d1\n");
                _out.appendCString("\tbra\t.xav_end\n");
                _out.appendCString(".xav_term:\n");
                _out.appendCString("\tmove.b\t#0,(a0)\t\t\t; the delimiter (or the byte past a <=124-byte line, still inside the field)\n");
                _out.appendCString(".xav_ret:\n");
                _out.appendCString("\tmove.l\t(sp)+,d0\n");
                _out.appendCString("\tmove.l\t(sp)+,d3\n");
                _out.appendCString("\trts\n");
                _out.appendCString(".xav_empty:\n");
                _out.appendCString("\tlea\t.xav_nul,a0\n");
                _out.appendCString("\tmove.l\ta0,d0\n");
                _out.appendCString("\tmove.l\t(sp)+,d3\n");
                _out.appendCString("\trts\n");
                _out.appendCString(".xav_nul:\n");
                _out.appendCString("\t.dc.l\t0\n");
                _out.appendCString("\n");
                }
            }
        emitNewShims(m);
        // `.length` of a runtime-sized heap array (private:docs/bugs/045): the element
        // count the allocator wrote at header+0, i.e. obj-14. u16,
        // zero-extended into d0 (the u16 return convention). Mirror of the
        // original, same position: after the shims, before the allocator.
        if (_out.byteIndexOf(String.withCString("\tjsr\t_xtc_count")) != (u32)$FFFF_FFFF)
            {
            _out.appendCString("\t.globl\t_xtc_count\n_xtc_count:\n");
            _out.appendCString("\tmove.l\t4(sp),a0\n");
            _out.appendCString("\tmoveq\t#0,d0\n");
            _out.appendCString("\tmove.w\t-14(a0),d0\n");
            _out.appendCString("\trts\n\n");
            }
        // The allocator is referenced by the shims just emitted as well as by
        // the body, so this scan comes after them.
        if (_out.byteIndexOf(String.withCString("\tjsr\t_xtc_alloc\n")) != (u32)$FFFF_FFFF)
            {
            _out.appendCString("; runtime: _xtc_alloc(count, stride, deallocPtr) -> zeroed object, refcount 1\n");
            _out.appendCString("; 14-byte header: [count:2][elemSize:2][dealloc:4][weak_head:4][refcount:2],\n");
            _out.appendCString("; obj=base+14. weak_head is the intrusive weak-reference chain (no table);\n");
            _out.appendCString("; it sits BEFORE the refcount so refcount stays at obj-2 and not one line of\n");
            _out.appendCString("; the inline ARC changes. See private:docs/Design/weak-refs-intrusive.md.\n\t.globl\t_xtc_alloc\n");
            _out.appendCString("_xtc_alloc:\n\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tjsr\t__mulsi3\n\tmove.l\td0,d1\n");
            _out.appendCString("\tadd.l\t#14,d0\n\tmove.l\td1,-(sp)\n\tmove.l\td0,-(sp)\n\tmove.w\t#$48,-(sp)\n");
            _out.appendCString("\ttrap\t#1\n\taddq.l\t#6,sp\n\tmove.l\t(sp)+,d2\n\ttst.l\td0\n\tble.s\t.xa_fail\n");
            _out.appendCString("\tmove.l\td0,a0\n\tmove.w\t6(sp),(a0)\n\tmove.w\t10(sp),2(a0)\n\tmove.l\t12(sp),4(a0)\n");
            _out.appendCString("\tclr.l\t8(a0)\n\tmove.w\t#1,12(a0)\n\tadd.l\t#14,d0\n\tmove.l\td0,a1\n.xa_zl:\n");
            _out.appendCString("\ttst.l\td2\n\tbeq.s\t.xa_done\n\tclr.b\t(a1)+\n\tsubq.l\t#1,d2\n\tbra.s\t.xa_zl\n");
            _out.appendCString(".xa_done:\n\trts\n.xa_fail:\n\tmoveq\t#0,d0\n\trts\n\n");
            }
        bool usesWeak = usesHelper(String.withCString("__xtc_weak_register")) || usesHelper(String.withCString("__xtc_weak_unregister"));
        if (usesHelper(String.withCString("_xtc_dealloc")))
            {
            _out.appendCString("; runtime: _xtc_dealloc(obj) -> dispatch dealloc per element (count at\n");
            _out.appendCString("; obj-14, stride obj-12) then Mfree(obj-14). Loop state in an a6 frame so it\n");
            _out.appendCString("; survives the dealloc calls. count>=1 (single object => one dispatch).\n");
            _out.appendCString("\t.globl\t_xtc_dealloc\n_xtc_dealloc:\n\tlink\ta6,#-8\n\tmove.l\t8(a6),a0\n");
            // Auto-zero any weak reference to this object BEFORE the memory
            // is freed and possibly reused, then reload obj into a0.
            if (usesWeak)
                {
                _out.appendCString("\tmove.l\ta0,d0\n\tjsr\t__xtc_weak_zero_all_for\n\tmove.l\t8(a6),a0\n");
                }
            _out.appendCString("\ttst.l\t-10(a0)\n\tbeq.s\t.xd_free\n\tmove.w\t#$8000,-2(a0)\n\tmove.w\t-14(a0),-2(a6)\n");
            _out.appendCString("\tmove.w\t-12(a0),-4(a6)\n\tmove.l\ta0,-8(a6)\n.xd_loop:\n\ttst.w\t-2(a6)\n");
            _out.appendCString("\tbeq.s\t.xd_free\n\tmove.l\t-8(a6),-(sp)\n\tmove.l\t8(a6),a0\n\tmove.l\t-10(a0),a1\n");
            _out.appendCString("\tjsr\t(a1)\n\taddq.l\t#4,sp\n\tmove.w\t-4(a6),d0\n\text.l\td0\n\tadd.l\td0,-8(a6)\n");
            _out.appendCString("\tsubq.w\t#1,-2(a6)\n\tbra.s\t.xd_loop\n.xd_free:\n\tmove.l\t8(a6),d0\n\tsub.l\t#14,d0\n");
            _out.appendCString("\tmove.l\td0,-(sp)\n\tmove.w\t#$49,-(sp)\n\ttrap\t#1\n\taddq.l\t#6,sp\n\tunlk\ta6\n\trts\n");
            _out.appendCString("\n");
            }
        if (usesHelper(String.withCString("_xtc_bank")))
            {
            _out.appendCString("; runtime: _xtc_bank(u8 type, u8 idx) -> lazily-allocated zeroed 12 KB region\n");
            _out.appendCString("\t.globl\t_xtc_bank\n_xtc_bank:\n\tlink\ta6,#0\n\tmoveq\t#0,d0\n\tmove.b\t11(a6),d0\n");
            _out.appendCString("\tlsl.l\t#8,d0\n\tmoveq\t#0,d1\n\tmove.b\t15(a6),d1\n\tadd.l\td1,d0\n\tlsl.l\t#2,d0\n");
            _out.appendCString("\tlea\t_xtc_bank_regions,a0\n\tadd.l\td0,a0\n\tmove.l\t(a0),d0\n\tbne.s\t.xb_done\n");
            _out.appendCString("\tmove.l\ta0,-(sp)\n\tmove.l\t#12288,-(sp)\n\tmove.w\t#$48,-(sp)\n\ttrap\t#1\n");
            _out.appendCString("\taddq.l\t#6,sp\n\tmove.l\t(sp)+,a0\n\tmove.l\td0,(a0)\n\tmove.l\td0,a1\n");
            _out.appendCString("\tmove.l\t#12288,d1\n.xb_zl:\n\tclr.b\t(a1)+\n\tsubq.l\t#1,d1\n\tbne.s\t.xb_zl\n");
            _out.appendCString(".xb_done:\n\tmove.l\t(a0),d0\n\tunlk\ta6\n\trts\n\n");
            }
        if (usesWeak)
            {
            _out.appendCString("; runtime: intrusive weak-reference list — NO TABLE, no cap, no scan.\n");
            _out.appendCString("; slot[-2]=pprev  slot[-1]=next  slot[0]=referent; obj's chain head at obj-6.\n;\n");
            _out.appendCString("; `pprev` is the ADDRESS OF THE POINTER THAT POINTS AT THIS SLOT (the Linux\n");
            _out.appendCString("; hlist idiom), not the previous slot. Unlink is then O(1) and never needs the\n");
            _out.appendCString("; object — which matters: a WIDENED `^` holds a FUNCTION pointer in its referent\n");
            _out.appendCString("; word, so recovering the object by reading *slot would treat .text as a header.\n");
            _out.appendCString("; It also makes pprev!=0 an unambiguous 'am I linked?' test (with a plain prev,\n");
            _out.appendCString("; prev==0 means EITHER unlinked OR head-of-chain).\n;\n");
            _out.appendCString("; Replaces a 64-entry table that was scanned on every store AND on every\n");
            _out.appendCString("; dealloc — including for the vast majority of objects that had no weak refs at\n");
            _out.appendCString("; all. Registers used: d0/d1/a0/a1 (all scratch).\n\t.globl\t__xtc_weak_unregister\n");
            _out.appendCString("__xtc_weak_unregister:\n\tmove.l\td0,a0\n\tmove.l\t-8(a0),d1\n\tbeq.s\t.wku_x\n");
            _out.appendCString("\tmove.l\td1,a1\n\tmove.l\t-4(a0),d1\n\tmove.l\td1,(a1)\n\ttst.l\td1\n\tbeq.s\t.wku_c\n");
            _out.appendCString("\tmove.l\td1,a1\n\tmove.l\t-8(a0),d1\n\tmove.l\td1,-8(a1)\n.wku_c:\n\tclr.l\t-8(a0)\n");
            _out.appendCString("\tclr.l\t-4(a0)\n.wku_x:\n\trts\n\t.globl\t__xtc_weak_register\n__xtc_weak_register:\n");
            _out.appendCString("\tmove.l\td1,-(sp)\n\tjsr\t__xtc_weak_unregister\n\tmove.l\t(sp)+,d1\n\ttst.l\td1\n");
            _out.appendCString("\tbeq.s\t.wkr_x\n\tmove.l\td0,a0\n\tmove.l\td1,a1\n\tlea\t-6(a1),a1\n\tmove.l\t(a1),d1\n");
            _out.appendCString("\tmove.l\ta1,-8(a0)\n\tmove.l\td1,-4(a0)\n\tmove.l\ta0,(a1)\n\ttst.l\td1\n");
            _out.appendCString("\tbeq.s\t.wkr_x\n\tmove.l\td1,a1\n\tmove.l\ta0,d1\n\tsubq.l\t#4,d1\n\tmove.l\td1,-8(a1)\n");
            _out.appendCString(".wkr_x:\n\trts\n\t.globl\t__xtc_weak_zero_all_for\n__xtc_weak_zero_all_for:\n\ttst.l\td0\n");
            _out.appendCString("\tbeq.s\t.wkz_x\n\tmove.l\td0,a1\n\tlea\t-6(a1),a1\n\tmove.l\t(a1),d1\n\tclr.l\t(a1)\n");
            _out.appendCString(".wkz_l:\n\ttst.l\td1\n\tbeq.s\t.wkz_x\n\tmove.l\td1,a0\n\tmove.l\t-4(a0),d1\n");
            _out.appendCString("\tclr.l\t(a0)\n\tclr.l\t-8(a0)\n\tclr.l\t-4(a0)\n\tbra.s\t.wkz_l\n.wkz_x:\n\trts\n\n");
            }
        if (usesHelper(String.withCString("_xt_clk_reset")) || usesHelper(String.withCString("_xt_clk_ticks")) || usesHelper(String.withCString("_xt_clk_delay")))
            {
            _out.appendCString("; runtime: monotonic counter clock (Time.xc)\n\t.even\n__xt_clk_ticks_store:\n\t.dc.l\t0\n");
            _out.appendCString("\t.globl\t_xt_clk_reset\n_xt_clk_reset:\n\tlea\t__xt_clk_ticks_store,a0\n\tclr.l\t(a0)\n");
            _out.appendCString("\trts\n\t.globl\t_xt_clk_ticks\n_xt_clk_ticks:\n\tlea\t__xt_clk_ticks_store,a0\n");
            _out.appendCString("\tmove.l\t(a0),d0\n\tadd.l\t#1000,d0\n\tmove.l\td0,(a0)\n\trts\n\t.globl\t_xt_clk_delay\n");
            _out.appendCString("_xt_clk_delay:\n\tlea\t__xt_clk_ticks_store,a0\n\tmove.l\t4(sp),d0\n\tadd.l\td0,(a0)\n");
            _out.appendCString("\trts\n\n");
            }
        bool needFmt = usesHelper(String.withCString("_xtc_pf")) || usesHelper(String.withCString("_xtc_pd")) || usesHelper(String.withCString("_xtc_pfp")) || usesHelper(String.withCString("_xtc_pdp"));
        if (needFmt && _hardFloat)
            {
            _out.appendCString("; runtime: float/double -> ASCII (printf %f/%lf)\n\t.even\n__fp_ten:\n\t.dc.l\t$41200000\n");
            _out.appendCString("__fp_half:\n\t.dc.l\t$3F000000\n__print_u32:\n\tmoveq\t#0,d2\n.pu_div:\n\tmove.l\t#10,d1\n");
            _out.appendCString("\tbsr\t__udivmod\n\tmove.l\td4,-(sp)\n\taddq.l\t#1,d2\n\ttst.l\td0\n\tbne.s\t.pu_div\n");
            _out.appendCString(".pu_pr:\n\tmove.l\t(sp)+,d0\n\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n");
            _out.appendCString("\taddq.l\t#4,sp\n\tsubq.l\t#1,d2\n\tbne.s\t.pu_pr\n\trts\n__fmt_double:\n\tftst\tfp0\n");
            _out.appendCString("\tfbge.s\t.fd_pos\n\tmove.l\t#45,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n");
            _out.appendCString("\tfneg\tfp0,fp0\n.fd_pos:\n\tfintrz\tfp0,fp1\n\tfmove.l\tfp1,d0\n\tmove.l\td3,-(sp)\n");
            _out.appendCString("\tbsr\t__print_u32\n\tmove.l\t(sp)+,d3\n\tmove.l\t#46,d0\n\tmove.l\td0,-(sp)\n");
            _out.appendCString("\tjsr\t_putc\n\taddq.l\t#4,sp\n\tfsub\tfp1,fp0\n.fd_lp:\n\ttst.l\td3\n\tbeq.s\t.fd_dn\n");
            _out.appendCString("\tsubq.l\t#1,d3\n\tfmul.s\t__fp_ten,fp0\n\tfintrz\tfp0,fp1\n\tfmove.l\tfp1,d0\n");
            _out.appendCString("\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tfsub\tfp1,fp0\n");
            _out.appendCString("\tbra.s\t.fd_lp\n.fd_dn:\n\trts\n\t.globl\t_xtc_pd\n_xtc_pd:\n\tfmove.d\t4(sp),fp0\n");
            _out.appendCString("\tmoveq\t#10,d3\n\tbra\t__fmt_double\n\t.globl\t_xtc_pf\n_xtc_pf:\n\tfmove.s\t4(sp),fp0\n");
            _out.appendCString("\tmoveq\t#6,d3\n\tbra\t__fmt_double\n\t.globl\t_xtc_pdp\n_xtc_pdp:\n\tfmove.d\t4(sp),fp0\n");
            _out.appendCString("\tmove.l\t12(sp),d3\n\tbne.s\t__fmt_double\n\tmoveq\t#10,d3\n\tbra\t__fmt_double\n");
            _out.appendCString("\t.globl\t_xtc_pfp\n_xtc_pfp:\n\tfmove.s\t4(sp),fp0\n\tmove.l\t8(sp),d3\n");
            _out.appendCString("\tbne.s\t__fmt_double\n\tmoveq\t#6,d3\n\tbra\t__fmt_double\n\n");
            }
        if (needFmt && !_hardFloat)
            {
            _out.appendCString("; runtime: soft-float double -> ASCII (printf %f/%lf, no FPU)\n__print_u32:\n");
            _out.appendCString("\tmoveq\t#0,d2\n.su_div:\n\tmove.l\t#10,d1\n\tbsr\t__udivmod\n\tmove.l\td4,-(sp)\n");
            _out.appendCString("\taddq.l\t#1,d2\n\ttst.l\td0\n\tbne.s\t.su_div\n.su_pr:\n\tmove.l\t(sp)+,d0\n");
            _out.appendCString("\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tsubq.l\t#1,d2\n");
            _out.appendCString("\tbne.s\t.su_pr\n\trts\n__fmt_dbl_soft:\n\tlink\ta6,#-24\n\tmove.l\td0,-4(a6)\n");
            _out.appendCString("\tmove.l\td1,-8(a6)\n\tmove.l\td3,-12(a6)\n\tand.l\t#$80000000,d0\n\tbeq.s\t.sf_pos\n");
            _out.appendCString("\tmove.l\t#45,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tmove.l\t-4(a6),d0\n");
            _out.appendCString("\tand.l\t#$7fffffff,d0\n\tmove.l\td0,-4(a6)\n.sf_pos:\n\tmove.l\t#$3fe00000,-16(a6)\n");
            _out.appendCString("\tclr.l\t-20(a6)\n\tmove.l\t-12(a6),-24(a6)\n.sf_rnd:\n\tmove.l\t-24(a6),d0\n");
            _out.appendCString("\tble.s\t.sf_rdn\n\tclr.l\t-(sp)\n\tmove.l\t#$40240000,-(sp)\n\tmove.l\t-20(a6),-(sp)\n");
            _out.appendCString("\tmove.l\t-16(a6),-(sp)\n\tjsr\t__divdf3\n\tlea\t16(sp),sp\n\tmove.l\td0,-16(a6)\n");
            _out.appendCString("\tmove.l\td1,-20(a6)\n\tsubq.l\t#1,-24(a6)\n\tbra.s\t.sf_rnd\n.sf_rdn:\n");
            _out.appendCString("\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tmove.l\t-8(a6),-(sp)\n");
            _out.appendCString("\tmove.l\t-4(a6),-(sp)\n\tjsr\t__adddf3\n\tlea\t16(sp),sp\n\tmove.l\td0,-4(a6)\n");
            _out.appendCString("\tmove.l\td1,-8(a6)\n\tmove.l\t-8(a6),-(sp)\n\tmove.l\t-4(a6),-(sp)\n\tjsr\t__fixdfsi\n");
            _out.appendCString("\taddq.l\t#8,sp\n\tmove.l\td0,-24(a6)\n\tjsr\t__print_u32\n\tmove.l\t#46,-(sp)\n");
            _out.appendCString("\tjsr\t_putc\n\taddq.l\t#4,sp\n\tmove.l\t-24(a6),d0\n\tjsr\t__floatsidf\n");
            _out.appendCString("\tmove.l\td1,-(sp)\n\tmove.l\td0,-(sp)\n\tmove.l\t-8(a6),-(sp)\n\tmove.l\t-4(a6),-(sp)\n");
            _out.appendCString("\tjsr\t__subdf3\n\tlea\t16(sp),sp\n\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n.sf_dlp:\n");
            _out.appendCString("\tmove.l\t-12(a6),d0\n\tble.s\t.sf_dn\n\tclr.l\t-(sp)\n\tmove.l\t#$40240000,-(sp)\n");
            _out.appendCString("\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tjsr\t__muldf3\n\tlea\t16(sp),sp\n");
            _out.appendCString("\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n\tmove.l\t-20(a6),-(sp)\n");
            _out.appendCString("\tmove.l\t-16(a6),-(sp)\n\tjsr\t__fixdfsi\n\taddq.l\t#8,sp\n\tmove.l\td0,-24(a6)\n");
            _out.appendCString("\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tmove.l\t-24(a6),d0\n");
            _out.appendCString("\tjsr\t__floatsidf\n\tmove.l\td1,-(sp)\n\tmove.l\td0,-(sp)\n\tmove.l\t-20(a6),-(sp)\n");
            _out.appendCString("\tmove.l\t-16(a6),-(sp)\n\tjsr\t__subdf3\n\tlea\t16(sp),sp\n\tmove.l\td0,-16(a6)\n");
            _out.appendCString("\tmove.l\td1,-20(a6)\n\tsubq.l\t#1,-12(a6)\n\tbra.s\t.sf_dlp\n.sf_dn:\n\tunlk\ta6\n\trts\n");
            _out.appendCString("\t.globl\t_xtc_pd\n_xtc_pd:\n\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tmoveq\t#10,d3\n");
            _out.appendCString("\tbra\t__fmt_dbl_soft\n\t.globl\t_xtc_pf\n_xtc_pf:\n\tmove.l\t4(sp),d0\n");
            _out.appendCString("\tjsr\t__extendsfdf2\n\tmoveq\t#6,d3\n\tbra\t__fmt_dbl_soft\n\t.globl\t_xtc_pdp\n");
            _out.appendCString("_xtc_pdp:\n\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tmove.l\t12(sp),d3\n\tbne.s\t.pdp1\n");
            _out.appendCString("\tmoveq\t#10,d3\n.pdp1:\n\tbra\t__fmt_dbl_soft\n\t.globl\t_xtc_pfp\n_xtc_pfp:\n");
            _out.appendCString("\tmove.l\t4(sp),d0\n\tjsr\t__extendsfdf2\n\tmove.l\t8(sp),d3\n\tbne.s\t.pfp1\n");
            _out.appendCString("\tmoveq\t#6,d3\n.pfp1:\n\tbra\t__fmt_dbl_soft\n\n");
            }
        emitXmOps();
        // pow(a,b) is exp(b*ln(a)) — there is no single 68881 instruction.
        if (_hardFloat && usesHelper(String.withCString("_xm_powf")))
            {
            _out.appendCString("\t.globl\t_xm_powf\n_xm_powf:\n\tfmove.s\t4(sp),fp0\n\tflogn\tfp0,fp0\n");
            _out.appendCString("\tfmove.s\t8(sp),fp1\n\tfmul\tfp1,fp0\n\tfetox\tfp0,fp0\n\tfmove.s\tfp0,d0\n\trts\n\n");
            }
        if (_hardFloat && usesHelper(String.withCString("_xm_pow")))
            {
            _out.appendCString("\t.globl\t_xm_pow\n_xm_pow:\n\tfmove.d\t4(sp),fp0\n\tflogn\tfp0,fp0\n");
            _out.appendCString("\tfmove.d\t12(sp),fp1\n\tfmul\tfp1,fp0\n\tfetox\tfp0,fp0\n\tfmove.d\tfp0,-(sp)\n");
            _out.appendCString("\tmove.l\t(sp)+,d0\n\tmove.l\t(sp)+,d1\n\trts\n\n");
            }
        emitMathHLE();
        // __udivmod is an INTERNAL subroutine of the hard-float formatter
        // (__print_u32 bsr's it), not an ABI-visible math call, so it stays asm.
        if (needFmt)
            {
            _out.appendCString("; runtime: __udivmod — unsigned 32/32, quotient d0, remainder d4\n__udivmod:\n");
            _out.appendCString("\tmoveq\t#0,d4\n\tmoveq\t#31,d3\n.udm_loop:\n\tadd.l\td0,d0\n\troxl.l\t#1,d4\n");
            _out.appendCString("\tcmp.l\td1,d4\n\tbcs.s\t.udm_no\n\tsub.l\td1,d4\n\taddq.l\t#1,d0\n.udm_no:\n");
            _out.appendCString("\tsubq.l\t#1,d3\n\tbpl.s\t.udm_loop\n\trts\n\n");
            }
        }

    // A CLASS `new T` lowers straight to `_xtc_alloc(count, stride, dealloc)`,
    // so it needs no per-class stub. But `_xtc_new_<T>` is still emitted by the
    // lowering for NON-class allocations — a primitive-element array (`new
    // u8[N]`) or a heap STRUCT (`new Point()`) — and each keeps a thin shim
    // forwarding to _xtc_alloc with a null dealloc. A primitive takes only the
    // count and supplies its fixed element size; a struct's `size` argument has
    // already been overridden to the m68k-native size at the call site.
    // Arguments push in reverse, so `count` lands at 4(sp).
    void emitNewShims(IRModule* m)
        {
        String* pfx = String.withCString("_xtc_new_");
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_RUNTIME || !s.name().hasPrefix(pfx))
                continue;
            String* cls = s.name().substringFromByte(pfx.byteLength());
            i32 psz = primitiveSize(cls);
            _out.appendFormat("\t.globl\t%s\n%s:\n", s.name().cString(), s.name().cString());
            if (psz > (i32)0)
                {
                _out.appendCString("\tclr.l\t-(sp)\n");           // dealloc = 0
                _out.appendFormat("\tmove.l\t#%ld,-(sp)\n", psz); // fixed element size
                _out.appendCString("\tmove.l\t12(sp),-(sp)\n");   // count
                _out.appendCString("\tjsr\t_xtc_alloc\n\tlea\t12(sp),sp\n\trts\n\n");
                }
            else
                {
                _out.appendCString("\tclr.l\t-(sp)\n");         // dealloc = 0
                _out.appendCString("\tmove.l\t12(sp),-(sp)\n"); // size
                _out.appendCString("\tmove.l\t12(sp),-(sp)\n"); // count
                _out.appendCString("\tjsr\t_xtc_alloc\n\tlea\t12(sp),sp\n\trts\n\n");
                }
            }
        }

    // The element size of a PRIMITIVE type name, or 0 when the suffix names a
    // struct (whose size arrives as an argument instead).
    static i32 primitiveSize(String* t)
        {
        if (t.equals(String.withCString("u8")) || t.equals(String.withCString("i8")) || t.equals(String.withCString("bool")))
            return (i32)1;
        if (t.equals(String.withCString("u16")) || t.equals(String.withCString("i16")))
            return (i32)2;
        if (t.equals(String.withCString("u32")) || t.equals(String.withCString("i32")) || t.equals(String.withCString("pointer")) || t.equals(String.withCString("string")) || t.equals(String.withCString("float")))
            return (i32)4;
        if (t.equals(String.withCString("double")))
            return (i32)8;
        return (i32)0;
        }

    // libm through the 68881 transcendentals: xtc's Math.* lowers to
    // `_xm_<op>f` (float) / `_xm_<op>` (double), each one FPU instruction whose
    // result the emulator (and the Zynq m68k JIT) computes with native libm.
    // A float returns in d0, a double in d0:d1.
    void emitXmOps(void)
        {
        if (!_hardFloat)
            return;
        Array* ops = new Array();
        Array* mns = new Array();
        addXm(ops, mns, "sqrt", "fsqrt");
        addXm(ops, mns, "sin", "fsin");
        addXm(ops, mns, "cos", "fcos");
        addXm(ops, mns, "tan", "ftan");
        addXm(ops, mns, "atan", "fatan");
        addXm(ops, mns, "asin", "fasin");
        addXm(ops, mns, "acos", "facos");
        addXm(ops, mns, "ln", "flogn");
        addXm(ops, mns, "exp", "fetox");
        addXm(ops, mns, "log10", "flog10");
        addXm(ops, mns, "log2", "flog2");
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            String* op = (String*)ops.get(i);
            String* mn = (String*)mns.get(i);
            String* fname = String.withCString("_xm_");
            fname.append(op);
            fname.appendCString("f");
            if (usesHelper(fname))
                {
                _out.appendFormat("\t.globl\t_xm_%sf\n_xm_%sf:\n", op.cString(), op.cString());
                _out.appendCString("\tfmove.s\t4(sp),fp0\n");
                _out.appendFormat("\t%s\tfp0,fp0\n", mn.cString());
                _out.appendCString("\tfmove.s\tfp0,d0\n\trts\n\n");
                }
            String* dname = String.withCString("_xm_");
            dname.append(op);
            if (usesHelper(dname))
                {
                _out.appendFormat("\t.globl\t_xm_%s\n_xm_%s:\n", op.cString(), op.cString());
                _out.appendCString("\tfmove.d\t4(sp),fp0\n");
                _out.appendFormat("\t%s\tfp0,fp0\n", mn.cString());
                _out.appendCString("\tfmove.d\tfp0,-(sp)\n\tmove.l\t(sp)+,d0\n\tmove.l\t(sp)+,d1\n\trts\n\n");
                }
            }
        }

    static void addXm(Array* ops, Array* mns, string op, string mn)
        {
        ops.add((Object*)String.withCString(op));
        mns.add((Object*)String.withCString(mn));
        }

    // ── FPU-less math helpers as line-A HLE stubs ────────────────────────
    //
    // Soft-float arithmetic, conversion and comparison, and the 68000's 32-bit
    // integer mul/div/mod, each compile to a two-word `line-A + rts`. The A9
    // JIT (or xst) executes the operation on native maths honouring the m68k C
    // ABI and preserves d2-d7/a2-a6, which is what lets the register allocator
    // home there. Under hard float or 68020+, the hardware instruction is
    // emitted inline and none of these symbols is referenced at all.
    void emitMathHLE(void)
        {
        Array* names = new Array();
        Array* codes = new Array();
        addHLE(names, codes, "__addsf3", $00);
        addHLE(names, codes, "__subsf3", $01);
        addHLE(names, codes, "__mulsf3", $02);
        addHLE(names, codes, "__divsf3", $03);
        addHLE(names, codes, "__cmpsf2", $05);
        addHLE(names, codes, "__adddf3", $08);
        addHLE(names, codes, "__subdf3", $09);
        addHLE(names, codes, "__muldf3", $0A);
        addHLE(names, codes, "__divdf3", $0B);
        addHLE(names, codes, "__cmpdf2", $0D);
        addHLE(names, codes, "__fixsfsi", $10);
        addHLE(names, codes, "__fixdfsi", $11);
        addHLE(names, codes, "__floatsisf", $12);
        addHLE(names, codes, "__floatsidf", $13);
        addHLE(names, codes, "__extendsfdf2", $14);
        addHLE(names, codes, "__truncdfsf2", $15);
        addHLE(names, codes, "__mulsi3", $18);
        addHLE(names, codes, "__divsi3", $19);
        addHLE(names, codes, "__udivsi3", $1A);
        addHLE(names, codes, "__modsi3", $1B);
        addHLE(names, codes, "__umodsi3", $1C);
        // The 64-bit integer pack, same shape: both operands on the stack high
        // word first, result in d0:d1.
        addHLE(names, codes, "__adddi3", $20);
        addHLE(names, codes, "__subdi3", $21);
        addHLE(names, codes, "__muldi3", $22);
        addHLE(names, codes, "__divdi3", $23);
        addHLE(names, codes, "__udivdi3", $24);
        addHLE(names, codes, "__moddi3", $25);
        addHLE(names, codes, "__umoddi3", $26);
        addHLE(names, codes, "__ashldi3", $27);
        addHLE(names, codes, "__lshrdi3", $28);
        addHLE(names, codes, "__ashrdi3", $29);
        addHLE(names, codes, "__anddi3", $2A);
        addHLE(names, codes, "__ordi3", $2B);
        addHLE(names, codes, "__xordi3", $2C);
        // Compare, returning sign(a-b) in d0 as __cmpdf2 does: a 64-bit compare
        // cannot be one cmp.l, and comparing only the high longs made `7 == 0`
        // true.
        addHLE(names, codes, "__cmpdi2", $2D);
        addHLE(names, codes, "__ucmpdi2", $2E);
        // 64-bit integer <-> floating point. Referenced in BOTH float modes,
        // unlike everything above: the 68881 converts .b/.w/.l only, so there
        // is no hardware instruction for a 64-bit integer and -mhard-float has
        // to come through the HLE too.
        addHLE(names, codes, "__floatdidf", $2F);
        addHLE(names, codes, "__floatundidf", $30);
        addHLE(names, codes, "__floatdisf", $31);
        addHLE(names, codes, "__floatundisf", $32);
        addHLE(names, codes, "__fixdfdi", $33);
        addHLE(names, codes, "__fixunsdfdi", $34);
        addHLE(names, codes, "__fixsfdi", $35);
        addHLE(names, codes, "__fixunssfdi", $36);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* nm = (String*)names.get(i);
            if (!usesHelper(nm))
                continue;
            u32 word = (u32)$A000 | ((Number*)codes.get(i)).asU32();
            _out.appendFormat("\t.globl\t%s\n%s:\n", nm.cString(), nm.cString());
            _out.appendFormat("\t.dc.w\t$%s\t; line-A math HLE\n\trts\n\n", hex4(word).cString());
            }
        }

    static void addHLE(Array* names, Array* codes, string nm, u32 code)
        {
        names.add((Object*)String.withCString(nm));
        codes.add((Object*)Number.withU32(code));
        }

    static String* hex4(u32 v)
        {
        String* o = String.withCString("");
        o.append(IRSymbol.hex2((v >> (u32)8) & (u32)$FF));
        o.append(IRSymbol.hex2(v & (u32)$FF));
        return o;
        }

    // ── Data ─────────────────────────────────────────────────────────────
    //
    // String literals, vtables and initialised globals go to .data; the
    // uninitialised ones to .bss, size only, so they stay out of the $601A
    // file and the loader zeroes them. Both follow the .text code — execution
    // never reaches here, since every function ends in rts.
    bool _anyData;

    void emitDataSection(IRModule* m)
        {
        _anyData = false;
        String* bss = new String();
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() == (u8)SYM_STRINGLIT)
                {
                dataHeader();
                _out.appendFormat("%s:\n", m68kSym(s.name()).cString());
                appendBytes(s.bytes());
                }
            else if (s.kind() == (u8)SYM_VTABLE)
                {
                dataHeader();
                _out.appendFormat("\t.even\n%s:\n", m68kSym(s.name()).cString());
                emitVTableSlots(s);
                }
            else if (s.kind() == (u8)SYM_DATAGLOBAL)
                {
                emitDataGlobal(s, bss);
                }
            }
        // The bank region table: regions[3 types][256 idx] of 4-byte pointers,
        // zero-initialised — the lazy-alloc check keys off NULL.
        if (_out.byteIndexOf(String.withCString("_xtc_bank_regions")) != (u32)$FFFF_FFFF)
            {
            String* tbl = String.withCString("\t.even\n_xtc_bank_regions:\n\t.space\t3072\n");
            if (_pic)
                {
                dataHeader();
                _out.append(tbl);
                }
            else
                bss.append(tbl);
            }
        if (bss.byteLength() > (u32)0)
            {
            _out.appendCString("\n; ── bss ──\n\t.bss\n");
            _out.append(bss);
            }
        }

    void dataHeader(void)
        {
        if (_anyData)
            return;
        _out.appendCString("\n; ── data ──\n\t.data\n\t.even\n");
        _anyData = true;
        }

    // A vtable slot holds an OFFSET, not an address (relocation-free, and the
    // dispatcher adds the base back). So "empty slot" and "null method" are NOT
    // the same bit pattern: an empty slot is offset 0, and base + 0 is the
    // vtable's own address — a bogus NON-NULL pointer. Anything reading a slot
    // as a VALUE rather than dispatching through it has to test the offset for
    // zero BEFORE adding the base.
    void emitVTableSlots(IRSymbol* s)
        {
        Array* e = s.slots();
        if (e == (Array*)0)
            return;
        for (u32 k = (u32)0; k < e.count(); k = k + (u32)1)
            {
            String* entry = (String*)e.get(k);
            bool empty = entry.byteLength() == (u32)0 || entry.equals(String.withCString("_"));
            // An empty slot still occupies 4 bytes, or every later method's
            // slot offset shifts.
            if (empty)
                _out.appendCString("\t.dc.l\t0\n");
            else
                _out.appendFormat("\t.dc.l\t%s-%s\n", m68kSym(entry).cString(), m68kSym(s.name()).cString());
            }
        }

    void emitDataGlobal(IRSymbol* s, String* bss)
        {
        // Size by the LARGER of the m68k width and the IR width. The m68k width
        // fixes a pointer (canonical 3 here, 4 there) and an aggregate with
        // pointer fields; the IR width covers an opaque buffer like
        // __xtc_va_buf, whose declared size exceeds its layout's field sum.
        // Using only one of the two under-sizes a global and makes neighbours
        // overlap.
        u32 w = (u32)1;
        String* ty = s.globalTy();
        if (ty != (String*)0)
            {
            u32 mw = fieldWidth(ty);
            u32 bw = irWidth(ty);
            w = mw > bw ? mw : bw;
            }
        Array* bytes = s.bytes();
        if (bytes != (Array*)0 && bytes.count() > (u32)0)
            {
            dataHeader();
            _out.appendFormat("\t.even\n%s:\n", m68kSym(s.name()).cString());
            appendBytes(padTo(relayInit(bytes, ty, w), w));
            return;
            }
        if (_pic)
            {
            // GOT mode keeps one contiguous in-file image (the GOT is appended
            // after data and relocated), so an uninitialised global stays in
            // .data as zeroed storage rather than a separate .bss.
            dataHeader();
            _out.appendFormat("\t.even\n%s:\n\t.space\t%lu\n", m68kSym(s.name()).cString(), w);
            return;
            }
        bss.appendFormat("\t.even\n%s:\n\t.space\t%lu\n", m68kSym(s.name()).cString(), w);
        }

    // The IR stores an initialiser in its canonical LITTLE-endian order and
    // this machine is BIG-endian, so a scalar integer's bytes reverse on the
    // way out. Strings and byte buffers keep their order.
    Array* relayInit(Array* bytes, String* ty, u32 w)
        {
        if (ty == (String*)0)
            return bytes;
        if (ty.equals(String.withCString("F32")) && bytes.count() == (u32)8)
            {
            // The image is 8 little-endian double bits; narrow to IEEE single
            // and emit big-endian.
            u32 fb = f32BitsOfLE(bytes);
            Array* r = new Array();
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                r.add((Object*)Number.with((i32)((fb >> ((u32)8 * ((u32)3 - k))) & (u32)$FF)));
            return r;
            }
        if (ty.equals(String.withCString("F64")) && bytes.count() == (u32)8)
            return reversed(bytes);
        if (isAggTy(ty))
            return relayAgg(bytes, layoutOf(ty));
        if (isPtrTy(ty))
            {
            // A pointer initialiser arrives at the target's canonical width
            // (3 bytes here) but is READ as a big-endian long. Zero-extend to
            // 4, then reverse. The scalar-integer branch cannot do it: it only
            // knows the fixed integer widths, and a pointer's IR width is 0.
            Array* r = new Array();
            for (u32 k = (u32)0; k < w; k = k + (u32)1)
                r.add(k < bytes.count() ? bytes.get(k) : (Object*)Number.with((i32)0));
            return reversed(r);
            }
        bool scalarInt = ty.equals(String.withCString("I16")) || ty.equals(String.withCString("U16")) || ty.equals(String.withCString("I32")) || ty.equals(String.withCString("U32"));
        if (scalarInt && (bytes.count() == (u32)2 || bytes.count() == (u32)4))
            return reversed(bytes);
        return bytes;
        }

    static Array* reversed(Array* a)
        {
        Array* r = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            r.add(a.get(a.count() - (u32)1 - i));
        return r;
        }

    static Array* padTo(Array* a, u32 w)
        {
        // The payload can be narrower than the slot the rest of codegen reads —
        // a 3-byte pointer initialiser in a 4-byte pointer — and emitting only
        // the payload let the NEXT symbol's first byte become part of this one.
        if (a.count() >= w)
            return a;
        Array* r = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            r.add(a.get(i));
        while (r.count() < w)
            r.add((Object*)Number.with((i32)0));
        return r;
        }

    // Re-lay an aggregate image from the IR's widths and endianness into this
    // target's: fields at m68k widths, each scalar leaf byte-reversed.
    Array* relayAgg(Array* src, IRLayout* l)
        {
        if (l == (IRLayout*)0)
            return src;
        // The DESTINATION is addressed at the SAME recorded field offsets as
        // the source (blewit #5), and the extent is the full layout footprint
        // — tail pad included, matching the reference's relay.
        u32 total = l.size();
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            {
            u32 fend = l.offsetAt(i) + fieldWidth(l.typeAt(i));
            if (fend > total)
                total = fend;
            }
        Array* dst = new Array();
        for (u32 i = (u32)0; i < total; i = i + (u32)1)
            dst.add((Object*)Number.with((i32)0));
        relayInto(dst, (u32)0, src, (u32)0, l);
        return dst;
        }

    void relayInto(Array* dst, u32 dstOffset, Array* src, u32 srcOffset, IRLayout* l)
        {
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            {
            String* t = l.typeAt(i);
            u32 srcOff = srcOffset + l.offsetAt(i);
            u32 cursor = dstOffset + l.offsetAt(i);
            u32 dstW = fieldWidth(t);
            if (isAggTy(t))
                {
                relayInto(dst, cursor, src, srcOff, layoutOf(t));
                continue;
                }
            // The image span to the next field includes any inter-field
            // padding; copy only the leaf's real width so pad never smears.
            u32 srcW = srcFieldWidth(l, i);
            u32 nb = srcW < dstW ? srcW : dstW;
            for (u32 b = (u32)0; b < nb; b = b + (u32)1)
                {
                if (srcOff + b >= src.count())
                    break; // a short image: zero tail
                if (cursor + b >= dst.count())
                    break;
                dst.set(cursor + b, src.get(srcOff + b));
                }
            // Little-endian in, big-endian out.
            if (dstW > (u32)1 && cursor + dstW <= dst.count())
                for (u32 k = (u32)0; k < dstW / (u32)2; k = k + (u32)1)
                    {
                    Object* tmp = dst.get(cursor + k);
                    dst.set(cursor + k, dst.get(cursor + dstW - (u32)1 - k));
                    dst.set(cursor + dstW - (u32)1 - k, tmp);
                    }
            }
        }

    // A field's width in the SOURCE image: the gap to the next field's offset,
    // or to the layout's end for the last one.
    static u32 srcFieldWidth(IRLayout* l, u32 idx)
        {
        u32 start = l.offsetAt(idx);
        u32 end = (idx + (u32)1 < l.fieldCount()) ? l.offsetAt(idx + (u32)1) : l.size();
        return end > start ? end - start : (u32)0;
        }

    // The IEEE single bits of a little-endian double image. Done on the bit
    // pattern rather than by arithmetic so it round-trips exactly on a host
    // without an f64 type: rebias the exponent by (127 - 1023), take the top 23
    // mantissa bits, round to nearest even.
    static u32 f32BitsOfLE(Array* b)
        {
        u32 hi = (u32)0;
        u32 lo = (u32)0;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            {
            lo = lo | (byteAt(b, i) << ((u32)8 * i));
            hi = hi | (byteAt(b, i + (u32)4) << ((u32)8 * i));
            }
        u32 sign = (hi >> (u32)31) & (u32)1;
        u32 exp = (hi >> (u32)20) & (u32)$7FF;
        u32 mhi = hi & (u32)$F_FFFF;
        if (exp == (u32)0 && mhi == (u32)0 && lo == (u32)0)
            return sign << (u32)31;
        if (exp == (u32)$7FF)
            {
            u32 mq = (mhi != (u32)0 || lo != (u32)0) ? (u32)1 : (u32)0;
            return (sign << (u32)31) | (u32)$7F80_0000 | (mq << (u32)22);
            }
        i32 e = (i32)exp - (i32)1023 + (i32)127;
        if (e >= (i32)255)
            return (sign << (u32)31) | (u32)$7F80_0000;
        if (e <= (i32)0)
            return sign << (u32)31;
        u32 m23 = (mhi << (u32)3) | (lo >> (u32)29);
        u32 rest = lo & (u32)$1FFF_FFFF;
        u32 half = (u32)$1000_0000;
        bool up = rest > half || (rest == half && (m23 & (u32)1) != (u32)0);
        if (up)
            {
            m23 = m23 + (u32)1;
            if (m23 > (u32)$7F_FFFF)
                {
                m23 = (u32)0;
                e = e + (i32)1;
                }
            if (e >= (i32)255)
                return (sign << (u32)31) | (u32)$7F80_0000;
            }
        return (sign << (u32)31) | ((u32)e << (u32)23) | m23;
        }

    static u32 byteAt(Array* b, u32 i)
        {
        return i < b.count() ? ((Number*)b.get(i)).asU32() : (u32)0;
        }

    // Twelve bytes to a line, as the reference does.
    void appendBytes(Array* data)
        {
        if (data == (Array*)0)
            return;
        u32 i = (u32)0;
        while (i < data.count())
            {
            _out.appendCString("\t.dc.b\t");
            for (u32 j = i; j < data.count() && j < i + (u32)12; j = j + (u32)1)
                {
                if (j > i)
                    _out.appendCString(",");
                _out.appendCString("$");
                _out.append(IRSymbol.hex2(((Number*)data.get(j)).asU32()));
                }
            _out.appendCString("\n");
            i = i + (u32)12;
            }
        }
    }
