// Arm9.xc — the IR, as ARMv7-A (A32) assembly.
// =========================================================================
//
// self-hosting M8. The port of XTArm9Backend — the first BACK END to exist in
// xtc, and the one that matters most: the Zynq Cortex-A9 is the machine the
// compiler is meant to run on, and it cannot host a compiler whose code
// generator only exists in Objective-C.
//
// The oracle is `xtcg-arm9 -O0`: same IR in, and the assembly text has to come
// out byte for byte the same. `-O0` because the optimiser is a separate port —
// at -O0 the pipeline is a pass-through, so this compares the CODE GENERATOR
// and nothing else.
//
// A32 is a 32-bit machine: pointers are 4 bytes. The IR's layouts carry the
// front end's own widths, so aggregate sizes and field offsets are recomputed
// here in A32-native widths — the same thing every other backend does, and the
// reason the type-width invariant is written down (private:docs/Design/type-width-invariant.md).

#import "Foundation.xc"
#import "Ir.xc"
#import "Homing.xc"

class Arm9
    {
    IRModule* _m;
    // Thread-safe ARC (private:docs/Design/threading.md §4.1): the refcount update
    // through the A9's exclusive monitor. On exactly when the module spawns a
    // thread — which today is never on this target, because XTOS has no
    // in-process thread syscalls yet (threading Phase 3). The codegen is here
    // so that when the kernel work lands, the refcount is already correct.
    bool _atomicArc;
    // -fthread-safe-arc / -fno-thread-safe-arc: 1 forces atomic refcounts, 0
    // forces plain ones, -1 (the default) leaves the per-module decision above.
    i32 _arcOverride;
    // --emit-lib / -c: every function this module defines is part of its
    // exported surface, so it keeps DEFAULT visibility. Hiding them is right
    // for a program (a hidden symbol's references stay R_ARM_RELATIVE rather
    // than becoming preemptible GLOB_DATs) and wrong for a library, where it
    // exports nothing and the app that links it dies at load naming a method
    // the .so plainly contains.
    bool _emitLib;
    IRFunc* _fn;
    String* _out;
    Map* _slot;          // value id -> byte offset in the frame
    u32 _frame;          // the frame size the prologue subtracts
    bool _sret;          // this function returns via a hidden pointer…
    u32 _sretSlot;       // …saved here on entry
    u32 _lastStackBytes; // classifyArgs' outgoing-stack total
    u32 _outArgBytes;    // outgoing-arg area: stores below this are a CALLEE's
    Homing* _homing;     // which values live in registers
    u32 _arcLabel;       // module-unique suffix for inline ARC labels
    u32 _vaListOff;      // where a native va_list starts in the frame
    bool _nativeVa;      // …and whether this function has one
    BitSet* _dead;       // pure constants nothing reads
    BitSet* _fusedCmp;   // ICmp results consumed ONLY by their CondBranch
    bool _failed;        // an opcode this slice does not emit yet
    String* _why;
    Array* _missing; // …every one of them, for the work queue

    void init(void)
        {
        _emitLib = false;
        _arcOverride = (i32)-1;
        }

    void setThreadSafeArcOverride(i32 mode)
        {
        _arcOverride = mode;
        }

    void setEmitLib(bool on)
        {
        _emitLib = on;
        }

    // ── Type sizing, A32-native ──────────────────────────────────────────
    // A type is its SPELLING here, so these read the text rather than a kind.
    static bool isPtrTy(String* t)
        {
        return t != 0 && t.hasPrefix(String.withCString("Ptr("));
        }

    static bool isAggTy(String* t)
        {
        return t != 0 && t.hasPrefix(String.withCString("Agg("));
        }

    static bool isMemTy(String* t)
        {
        return t != 0 && t.equals(String.withCString("Mem"));
        }

    static bool isFloatTy(String* t)
        {
        return t != 0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
        }

    // `Agg(N)` -> N.
    static u32 aggIndex(String* t)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return v;
        }

    // `Ptr(<pointee>, window)` -> the pointee spelling.
    static String* pointeeOf(String* t)
        {
        if (!Arm9.isPtrTy(t))
            return (String*)0;
        u32 depth = (u32)0;
        u32 start = (u32)4;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c == (u8)'(')
                depth = depth + (u32)1;
            else if (c == (u8)')')
                {
                if (depth == (u32)0)
                    return t.substringBytes(start, i - start);
                depth = depth - (u32)1;
                }
            else if (c == (u8)',' && depth == (u32)0)
                {
                return t.substringBytes(start, i - start);
                }
            }
        return (String*)0;
        }

    u32 fieldWidth(String* t)
        {
        if (t == 0)
            return (u32)0;
        if (Arm9.isPtrTy(t))
            return (u32)4; // 32-bit host pointer
        if (t.equals(String.withCString("F64")))
            return (u32)8;
        // 8 wherever the ARITHMETIC lands: width is a layout contract, so the
        // front end and this back end must agree or an optimiser-folded struct
        // offset reads at the wrong address.
        if (Arm9.isI64(t))
            return (u32)8;
        if (t.equals(String.withCString("F32")))
            return (u32)4;
        if (t.equals(String.withCString("I32")))
            return (u32)4;
        if (t.equals(String.withCString("U32")))
            return (u32)4;
        if (t.equals(String.withCString("I16")))
            return (u32)2;
        if (t.equals(String.withCString("U16")))
            return (u32)2;
        if (t.equals(String.withCString("I8")))
            return (u32)1;
        if (t.equals(String.withCString("U8")))
            return (u32)1;
        if (t.equals(String.withCString("Bool")))
            return (u32)1;
        if (Arm9.isAggTy(t))
            return aggSize(Arm9.aggIndex(t));
        return (u32)0; // Void / Mem
        }

    // The A32 size of an aggregate: its fields summed at THIS machine's widths,
    // never below the layout's own size (a field-less buffer carries its size
    // there and has nothing to sum).
    u32 aggSize(u32 layoutIndex)
        {
        if (layoutIndex >= _m.layouts().count())
            return (u32)0;
        IRLayout* L = (IRLayout*)_m.layouts().get(layoutIndex);
        u32 total = (u32)0;
        for (u32 i = (u32)0; i < L.fieldCount(); i = i + (u32)1)
            total = total + fieldWidth(L.typeAt(i));
        if (total < L.size())
            total = L.size();
        return total;
        }

    // The RECORDED layout offset (blewit #5): the front end lays fields out
    // once — naturally aligned per target — and every backend reads the same
    // offsets. Widths still size the loads/stores; they no longer place fields.
    u32 fieldOffset(u32 layoutIndex, u32 idx)
        {
        if (layoutIndex >= _m.layouts().count())
            return (u32)0;
        IRLayout* L = (IRLayout*)_m.layouts().get(layoutIndex);
        if (idx >= L.fieldCount())
            return aggSize(layoutIndex);
        return L.offsetAt(idx);
        }

    // ── Module ───────────────────────────────────────────────────────────

    // ── Spill peephole ───────────────────────────────────────────────────
    //
    // Mirrors XTArm9Backend's a9PeepholeSpills byte for byte. arm9 DUAL-WRITES
    // homed values (register AND slot), so most spill stores have no reader —
    // 101 `str` against 10 `ldr` on a reduction kernel, on an in-order core.
    //
    //   (always) store->load forward: `str R,[sp,#N]` then `ldr R2,[sp,#N]`
    //            becomes `mov R2, R` (dropped when R2 == R).
    //   (leaf)   dead store: `str R,[sp,#N]` with no `ldr` of #N anywhere.
    //
    // The dead form needs the frame to be provably all this function's own:
    //   * a CALL disqualifies it — arm9 writes outgoing stack ARGUMENTS to
    //     [sp,#0..N) and the CALLEE reads them, so a load count in this
    //     function calls them dead and deleting them ships frame garbage.
    //   * so does a materialised stack address, an ldm/stm, inline asm, or ANY
    //     [sp access this parser cannot read exactly (ldrd reads a PAIR; vldr
    //     reads a float slot) — an inexact count must not claim to be one.
    bool a9SpParse(String* line, String* outMnem, String* outReg, String* outOff)
        {
        String* s = line.trimmed();
        u32 at = s.byteIndexOf(String.withCString(", [sp"));
        if (at == String.notFound())
            return false;
        String* head = s.substringToByte(at);
        u32 sp = (u32)0;
        bool found = false;
        for (u32 i = (u32)0; i < head.byteLength(); i = i + (u32)1)
            {
            u8 c = head.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t')
                {
                sp = i;
                found = true;
                break;
                }
            }
        if (!found)
            return false;
        String* m = head.substringToByte(sp);
        if (!m.equals(String.withCString("str")) && !m.equals(String.withCString("ldr")))
            return false;
        String* r = head.substringFromByte(sp + (u32)1).trimmed();
        if (r.contains(String.withCString("{")))
            return false;
        String* tail = s.substringFromByte(at);
        if (tail.contains(String.withCString("!")))
            return false;
        if (tail.contains(String.withCString(", r")))
            return false;
        u32 hash = tail.byteIndexOf(String.withCString("#"));
        outMnem.setTo(m);
        outReg.setTo(r);
        if (hash == String.notFound())
            {
            if (tail.hasSuffix(String.withCString("[sp]")))
                {
                outOff.setTo(String.withCString("0"));
                return true;
                }
            return false;
            }
        u32 close = tail.byteIndexOf(String.withCString("]"));
        if (close == String.notFound() || close <= hash)
            return false;
        outOff.setTo(tail.substringBytes(hash + (u32)1, close - hash - (u32)1).trimmed());
        return true;
        }

    String* peepholeSpills(String* text)
        {
        Array* lines = text.splitOnByte((u8)'\n');
        bool clean = true;
        Map* loads = new Map();
        String* m = String.withCString("");
        String* r = String.withCString("");
        String* o = String.withCString("");

        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* ln = (String*)lines.get(i);
            String* t = ln.trimmed();
            if (t.contains(String.withCString("@ inline asm")))
                return text;
            bool addSub = t.hasPrefix(String.withCString("add ")) || t.hasPrefix(String.withCString("add\t")) || t.hasPrefix(String.withCString("sub ")) || t.hasPrefix(String.withCString("sub\t"));
            if (addSub && !t.contains(String.withCString("sub\tsp,")) && !t.contains(String.withCString("add\tsp,")) && !t.hasPrefix(String.withCString("add sp,")) && !t.hasPrefix(String.withCString("sub sp,")) && t.contains(String.withCString(", sp")))
                clean = false;
            if (t.hasPrefix(String.withCString("ldm")) || t.hasPrefix(String.withCString("stm")))
                clean = false;
            // `mov Rd, sp` is the SAME materialisation as `add Rd, sp, #0` —
            // emitAlu shortcuts a zero offset to a mov, which is what an
            // AddrOf of the frame's FIRST slot (a leaf's aggregate parameter)
            // produces. Mirrors the reference's rule (struct_byval T1 on arm9).
            bool movp = t.hasPrefix(String.withCString("mov ")) || t.hasPrefix(String.withCString("mov\t"));
            if (movp && (t.hasSuffix(String.withCString(", sp")) || t.contains(String.withCString(", sp @"))))
                clean = false;
            // NOTE: a call no longer disqualifies the whole function — the
            // outgoing-argument area is a property of the OFFSET, honoured at
            // the dead-store decision below.
            bool parsed = a9SpParse(ln, m, r, o);
            if (!parsed && t.contains(String.withCString("[sp")))
                clean = false;
            if (parsed && m.equals(String.withCString("ldr")))
                {
                Object* cur = loads.get((Hashable*)o);
                u32 n = cur == (Object*)0 ? (u32)0 : ((Number*)cur).asU32();
                loads.set((Hashable*)String.withCString(o.cString()), (Object*)Number.withU32(n + (u32)1));
                }
            }

        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < lines.count())
            {
            String* ln = (String*)lines.get(i);
            String* sm = String.withCString("");
            String* sr = String.withCString("");
            String* so = String.withCString("");
            bool isStore = a9SpParse(ln, sm, sr, so) && sm.equals(String.withCString("str"));
            if (isStore)
                {
                Object* lc = loads.get((Hashable*)so);
                u32 nl = lc == (Object*)0 ? (u32)0 : ((Number*)lc).asU32();
                if (clean && nl == (u32)0 && Arm9.offValue(so) >= _outArgBytes)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                if (i + (u32)1 < lines.count())
                    {
                    String* lm = String.withCString("");
                    String* lr = String.withCString("");
                    String* lo = String.withCString("");
                    if (a9SpParse((String*)lines.get(i + (u32)1), lm, lr, lo) && lm.equals(String.withCString("ldr")) && lo.equals(so) && sr.hasPrefix(String.withCString("r")) && lr.hasPrefix(String.withCString("r")))
                        {
                        bool dropStore = clean && nl == (u32)1 && Arm9.offValue(so) >= _outArgBytes;
                        if (!dropStore)
                            {
                            out.append(ln);
                            out.appendCString("\n");
                            }
                        if (!lr.equals(sr))
                            out.appendFormat("\tmov\t%s, %s\n", lr.cString(), sr.cString());
                        i = i + (u32)2;
                        continue;
                        }
                    }
                }
            out.append(ln);
            if (i + (u32)1 < lines.count())
                out.appendCString("\n");
            i = i + (u32)1;
            }
        return out;
        }

    String* assembly(IRModule* mod)
        {
        _m = mod;
        _atomicArc = _arcOverride >= (i32)0 ? _arcOverride != (i32)0 : spawnsThreads(mod);
        _out = String.withCString("");
        // A `.file` naming the MODULE, not the temp `.s`: without one gas falls
        // back to whatever temporary object name it was handed, which is random
        // per build and lands in .symtab as an STT_FILE.
        _out.appendFormat("\t.file\t\"%s.xc\"\n", mod.name().cString());
        _out.appendCString("\t.syntax unified\n\t.arch armv7-a\n\t.fpu neon\n\t.text\n\n");
        if (needsItable(mod))
            emitItableHelper();
        // Per-FUNCTION buffer so the spill peephole's dead-store count, which is
        // only exact within one frame, sees exactly one frame.
        for (u32 i = (u32)0; i < mod.funcs().count(); i = i + (u32)1)
            {
            String* saved = _out;
            _out = String.withCString("");
            emitFunction((IRFunc*)mod.funcs().get(i));
            String* fbuf = _out;
            _out = saved;
            _out.append(peepholeSpills(fbuf));
            }
        emitModuleData();
        return _out;
        }

    // Does any dispatch in this module go through an itable? Then the lookup
    // helper is emitted once, ahead of the code that calls it.
    bool needsItable(IRModule* mod)
        {
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)mod.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* blk = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                    {
                    String* op = ((IRInsn*)blk.insns().get(i)).op();
                    if (op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("ProtoLoad")))
                        return true;
                    }
                }
            }
        return false;
        }

    // Receiver + protocol id -> that protocol's method table, in r12. A runtime
    // helper rather than inline code because after marshalling only r12 and lr
    // are free, and the scan needs three live values. Two entry points: the
    // second is for an sret call, where the receiver is in r1 because r0 is
    // carrying the result pointer.
    void emitItableHelper(void)
        {
        _out.appendCString("\t.text\n\t.p2align 2\n");
        emitItableEntry(String.withCString("_xtc_itable"), String.withCString("r0"));
        emitItableEntry(String.withCString("_xtc_itable_s"), String.withCString("r1"));
        _out.appendCString("\n");
        }

    void emitItableEntry(String* name, String* recv)
        {
        _out.appendFormat("\t.global\t%s\n\t.hidden\t%s\n", name.cString(), name.cString());
        _out.appendFormat("\t.type\t%s, %%function\n%s:\n", name.cString(), name.cString());
        _out.appendCString("\tpush\t{r0, r1}\n");
        _out.appendFormat("\tldr\tr0, [%s]\n", recv.cString());
        // vtable entry 1 is the itable; entry 0 is the parent link.
        _out.appendCString("\tldr\tr0, [r0, #4]\n");
        _out.appendCString("\tcmp\tr0, #0\n\tbeq\t1f\n0:\n");
        _out.appendCString("\tldr\tr1, [r0]\n\tcmp\tr1, #0\n\tbeq\t1f\n");
        _out.appendCString("\tcmp\tr1, r12\n\tbeq\t2f\n");
        _out.appendCString("\tadd\tr0, r0, #8\n\tb\t0b\n2:\n");
        _out.appendCString("\tldr\tr12, [r0, #4]\n\tpop\t{r0, r1}\n\tbx\tlr\n1:\n");
        // A miss is null — an unimplemented optional requirement.
        _out.appendCString("\tmov\tr12, #0\n\tpop\t{r0, r1}\n\tbx\tlr\n");
        }

    // Module-level data: globals, string literals, vtables, load-time
    // constructors. ELF/GNU-as syntax, bare symbol names, 4-byte pointers.
    void emitModuleData(void)
        {
        bool emitted = false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.kind() != (u8)SYM_DATAGLOBAL || s.dataType() == 0)
                continue;
            // An extern global is DEFINED IN ANOTHER MODULE: reserve nothing.
            // A `.comm` here gave this module its own zeroed copy, so reads
            // never saw the defining module's value.
            if (s.isExtern())
                continue;
            // A zero-init global is a `.comm` and needs no section of its own —
            // only a global with a PAYLOAD opens `.data`.
            Array* b = s.bytes();
            if (b != 0 && b.count() > (u32)0 && !emitted)
                {
                _out.appendCString("\n\t.data\n");
                emitted = true;
                }
            emitGlobal(s);
            }
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.kind() != (u8)SYM_STRINGLIT)
                continue;
            if (!emitted)
                {
                _out.appendCString("\n\t.data\n");
                emitted = true;
                }
            _out.appendFormat("\t.global\t%s\n%s:\n", s.name().cString(), s.name().cString());
            Array* b = s.bytes();
            if (b == 0 || b.count() == (u32)0)
                {
                _out.appendCString("\t.byte\t0x00\n");
                continue;
                }
            for (u32 j = (u32)0; j < b.count(); j = j + (u32)1)
                _out.appendFormat("\t.byte\t0x%s\n",
                                  IRSymbol.hex2(((Number*)b.get(j)).asU32()).cString());
            }
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.kind() != (u8)SYM_VTABLE)
                continue;
            if (!emitted)
                {
                _out.appendCString("\n\t.data\n");
                emitted = true;
                }
            emitVtable(s);
            }
        if (_m.modinits().count() > (u32)0)
            {
            _out.appendCString("\t.section .init_array,\"aw\",%init_array\n\t.p2align 2\n");
            for (u32 i = (u32)0; i < _m.modinits().count(); i = i + (u32)1)
                _out.appendFormat("\t.word\t%s\n",
                                  ((String*)_m.modinits().get(i)).cString());
            }
        }

    void emitGlobal(IRSymbol* s)
        {
        u32 size = fieldWidth(s.dataType());
        if (size == (u32)0)
            size = (u32)4;
        Array* b = s.bytes();
        if (b == 0 || b.count() == (u32)0)
            {
            // `.comm` so the symbol is global — it escapes to a linking C stub.
            _out.appendFormat("\t.comm\t%s, %ld, 4\n", s.name().cString(), (i32)size);
            return;
            }
        // A float global carries its value as the 8 bytes of an IEEE double;
        // the slot it lands in is the TARGET's width, so an F32 is re-encoded
        // to single precision rather than truncated.
        if (Arm9.isFloatTy(s.dataType()) && b.count() != size)
            b = floatInitBytes(s, b, size);
        _out.appendFormat("\t.global\t%s\n%s:\n", s.name().cString(), s.name().cString());
        for (u32 i = (u32)0; i < b.count(); i = i + (u32)1)
            _out.appendFormat("\t.byte\t0x%s\n",
                              IRSymbol.hex2(((Number*)b.get(i)).asU32()).cString());
        for (u32 i = b.count(); i < size; i = i + (u32)1)
            _out.appendCString("\t.byte\t0x00\n");
        }

    // The double's raw bytes, little-endian, re-encoded for the declared type.
    Array* floatInitBytes(IRSymbol* sym, Array* b, u32 size)
        {
        u32 lo = (u32)0;
        u32 hi = (u32)0;
        for (u32 i = (u32)0; i < (u32)4 && i < b.count(); i = i + (u32)1)
            lo = lo | (((Number*)b.get(i)).asU32() << (i * (u32)8));
        for (u32 i = (u32)4; i < (u32)8 && i < b.count(); i = i + (u32)1)
            hi = hi | (((Number*)b.get(i)).asU32() << ((i - (u32)4) * (u32)8));
        Array* out = new Array();
        if (sym.dataType().equals(String.withCString("F64")))
            {
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                out.add((Object*)Number.with((lo >> (i * (u32)8)) & (u32)$FF));
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                out.add((Object*)Number.with((hi >> (i * (u32)8)) & (u32)$FF));
            return out;
            }
        u32 f = Arm9.doubleBitsToFloatBits(hi, lo);
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            out.add((Object*)Number.with((f >> (i * (u32)8)) & (u32)$FF));
        return out;
        }

    void emitVtable(IRSymbol* s)
        {
        _out.appendFormat("\t.global\t%s\n\t.p2align 2\n%s:\n",
                          s.name().cString(), s.name().cString());
        Array* e = s.slots();
        if (e == 0 || e.count() == (u32)0)
            {
            _out.appendCString("\t.word\t0\n");
            return;
            }
        for (u32 i = (u32)0; i < e.count(); i = i + (u32)1)
            {
            String* n = (String*)e.get(i);
            if (n.byteLength() == (u32)0)
                {
                _out.appendCString("\t.word\t0\n");
                continue;
                }
            // An itable is (protoId, &table) pairs; the id is a VALUE, so it is
            // emitted as a literal word rather than a label.
            if (n.hasPrefix(String.withCString("__protoid_")))
                {
                _out.appendFormat("\t.word\t%s\n", n.substringFromByte((u32)10).cString());
                continue;
                }
            _out.appendFormat("\t.word\t%s\n", n.cString());
            }
        }

    // ── Functions ────────────────────────────────────────────────────────
    void emitFunction(IRFunc* fn)
        {
        _fn = fn;
        String* label = fn.name();
        _out.appendFormat("\t.global\t%s\n\t.type\t%s, %%function\n",
                          label.cString(), label.cString());
        // PIC: hide internal symbols so their references stay non-preemptible.
        // `main` keeps default visibility — the loader resolves the entry from
        // .dynsym.
        if (!_emitLib && !label.equals(String.withCString("main")))
            _out.appendFormat("\t.hidden\t%s\n", label.cString());
        _out.appendFormat("%s:\n", label.cString());

        homeValues();
        allocateVectorRegisters(fn);
        computeDefMap();
        computePostIncEA();
        computeDeadConsts();
        computeFusedCmps();
        _nativeVa = usesNativeVa() || isVaForward();
        assignSlots();

        // A native-va_list variadic function saves its incoming r0-r3 FIRST, so
        // [r0,r1,r2,r3 | the caller's stack args] is one contiguous block just
        // below them — which is exactly what a va_list has to point into.
        if (_nativeVa)
            _out.appendCString("\tpush\t{r0-r3}\n");
        _out.appendCString("\tpush\t{r4-r11, lr}\n");
        if (_frame > (u32)0)
            emitAlu(String.withCString("sub"), String.withCString("sp"),
                    String.withCString("sp"), _frame,
                    String.withCString("r12"));
        spillParams();

        u32 lastPoolLen = _out.byteLength();
        u32 poolSeq = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)fn.blocks().get(b);
            _out.appendFormat("%s:\n", blockLabel(blk).cString());
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                emitInsn((IRInsn*)blk.insns().get(i));
                // A `ldr rX, =sym` must reach its literal pool within ±4 KB, and
                // one basic block can be longer than that on its own. Flush
                // mid-block once enough text has accumulated, branching over the
                // pool so it is never executed.
                if (_out.byteLength() - lastPoolLen > (u32)8000)
                    {
                    String* skip = String.withCString(".Lpool_");
                    skip.append(label);
                    skip.appendFormat("_%ld", (i32)poolSeq);
                    poolSeq = poolSeq + (u32)1;
                    _out.appendFormat("\tb\t%s\n\t.ltorg\n%s:\n",
                                      skip.cString(), skip.cString());
                    lastPoolLen = _out.byteLength();
                    }
                }
            if (blk.term() != 0)
                emitTerminator(blk.term(), blk);
            else
                emitFrameReturn();
            // Every block ends in a non-fall-through terminator, so an inline
            // pool here is branched over rather than executed.
            _out.appendCString("\t.ltorg\n");
            lastPoolLen = _out.byteLength();
            }
        _out.appendFormat("\t.size\t%s, .-%s\n", label.cString(), label.cString());
        _out.appendCString("\t.ltorg\n");
        _out.appendCString("\n");
        }

    // Backend DCE for pure constant chains nothing reads. An instruction is
    // skippable when it is a Const or a width cast AND every use of its result
    // is itself skippable — which, for a value with no uses at all, is
    // vacuously true. (In the original this also drops the chains orphaned by
    // the vectoriser's constant-inlined splats; there are none at -O0, but the
    // no-consumer case fires either way and the oracle emits nothing for it.)
    void computeDeadConsts(void)
        {
        _dead = BitSet.withCapacity(_fn.byId().count() + (u32)1);
        Array* defs = new Array(); // value id -> defining IRInsn@
        for (u32 i = (u32)0; i < _fn.byId().count() + (u32)1; i = i + (u32)1)
            defs.add((Object*)0);
        Array* users = new Array(); // value id -> Array@ of IRInsn@
        for (u32 i = (u32)0; i < _fn.byId().count() + (u32)1; i = i + (u32)1)
            users.add((Object*)new Array());
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* insn = (IRInsn*)blk.insns().get(i);
                if (insn.res() != 0 && insn.res().pid() < defs.count())
                    defs.set(insn.res().pid(), (Object*)insn);
                }
            noteUsers(blk, users);
            }
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 v = (u32)0; v < defs.count(); v = v + (u32)1)
                {
                if (_dead.has(v))
                    continue;
                Object* d = defs.get(v);
                if (d == 0)
                    continue;
                if (!Arm9.isPureConstOp(((IRInsn*)d).op()))
                    continue;
                Array* us = (Array*)users.get(v);
                bool allDead = true;
                for (u32 k = (u32)0; k < us.count() && allDead; k = k + (u32)1)
                    {
                    IRInsn* u = (IRInsn*)us.get(k);
                    // A VSplat that traced its operand to a constant materialises
                    // the immediate itself, so it is not a reader — which is what
                    // lets the whole Const→ZExt→mask chain behind it go. Without
                    // this the chain is emitted and then never read.
                    if (inlinedByVSplat(u, v))
                        continue;
                    if (u.res() == 0 || !_dead.has(u.res().pid()))
                        allDead = false;
                    }
                if (allDead)
                    {
                    _dead.add(v);
                    changed = true;
                    }
                }
            }
        }

    bool inlinedByVSplat(IRInsn* u, u32 vid)
        {
        if (!u.op().equals(String.withCString("VSplat")))
            return false;
        if (u.ops().count() < (u32)1)
            return false;
        IROperand* o0 = (IROperand*)u.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
            return false;
        if (o0.val().pid() != vid)
            return false;
        return traceConst(o0, new Array());
        }

    // Compare-branch fusion (mirrors XTArm9Backend's sFusedCmp). An ICmp whose
    // result is read ONLY by its own block's CondBranch is not emitted where it
    // stands; the terminator re-emits `cmp` and branches on the condition, so
    // the boolean is never built. That was five instructions per loop test —
    // cmp / mov #0 / mov<cc> #1 / copies / cmp #0 / beq.
    //
    // Every condition is load-bearing: LAST instruction of the block, so nothing
    // between it and the branch touches the flags; SAME block; exactly ONE use,
    // since a second reader still needs the value; and 32-bit only, because the
    // i64 path is subs+sbcs with its own operand swapping rather than one cmp.
    void computeFusedCmps(void)
        {
        _fusedCmp = BitSet.withCapacity(_fn.byId().count() + (u32)1);
        Array* users = new Array();
        for (u32 i = (u32)0; i < _fn.byId().count() + (u32)1; i = i + (u32)1)
            users.add((Object*)new Array());
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            noteUsers((IRBlock*)_fn.blocks().get(b), users);

        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            IRInsn* term = blk.term();
            if (term == (IRInsn*)0)
                continue;
            if (!term.op().equals(String.withCString("CondBranch")))
                continue;
            IROperand* cop = (IROperand*)0;
            for (u32 i = (u32)0; i < term.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)term.ops().get(i);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                    {
                    cop = o;
                    break;
                    }
                }
            if (cop == (IROperand*)0)
                continue;
            if (blk.insns().count() == (u32)0)
                continue;
            IRInsn* last = (IRInsn*)blk.insns().get(blk.insns().count() - (u32)1);
            if (last.res() == (IRValue*)0)
                continue;
            if (!last.op().equals(String.withCString("ICmp")))
                continue;
            if (last.res().pid() != cop.val().pid())
                continue;
            if (((Array*)users.get(cop.val().pid())).count() != (u32)1)
                continue;
            bool wide = false;
            for (u32 i = (u32)0; i < last.ops().count(); i = i + (u32)1)
                {
                String* t = operandType((IROperand*)last.ops().get(i));
                if (t != (String*)0 && (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))))
                    wide = true;
                }
            if (wide)
                continue;
            if (Arm9.condForICmp(last.pred()) == (String*)0)
                continue;
            _fusedCmp.add(last.res().pid());
            }
        }

    // Branch-taken-on-FALSE condition: the inverse of the compare's own.
    // Decimal offset from a parsed `[sp, #N]`. There is no String->int helper in
    // the library, and the peephole needs the NUMBER to compare against the
    // outgoing-argument boundary, not the text.
    static u32 offValue(String* s)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return v;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return v;
        }

    static String* invCond(String* cc)
        {
        if (cc.equals(String.withCString("eq")))
            return String.withCString("ne");
        if (cc.equals(String.withCString("ne")))
            return String.withCString("eq");
        if (cc.equals(String.withCString("lt")))
            return String.withCString("ge");
        if (cc.equals(String.withCString("ge")))
            return String.withCString("lt");
        if (cc.equals(String.withCString("gt")))
            return String.withCString("le");
        if (cc.equals(String.withCString("le")))
            return String.withCString("gt");
        if (cc.equals(String.withCString("lo")))
            return String.withCString("hs");
        if (cc.equals(String.withCString("hs")))
            return String.withCString("lo");
        if (cc.equals(String.withCString("hi")))
            return String.withCString("ls");
        if (cc.equals(String.withCString("ls")))
            return String.withCString("hi");
        return String.withCString("eq");
        }

    void noteUsers(IRBlock* blk, Array* users)
        {
        for (u32 i = (u32)0; i < blk.phis().count(); i = i + (u32)1)
            noteUsersOf((IRInsn*)blk.phis().get(i), users);
        for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
            noteUsersOf((IRInsn*)blk.insns().get(i), users);
        if (blk.term() != 0)
            noteUsersOf(blk.term(), users);
        }

    void noteUsersOf(IRInsn* insn, Array* users)
        {
        for (u32 i = (u32)0; i < insn.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)insn.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (o.val().pid() >= users.count())
                continue;
            ((Array*)users.get(o.val().pid())).add((Object*)insn);
            }
        }

    static bool isPureConstOp(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast"));
        }

    // A FORWARDER — `printf(fmt, ...)` — has no VaStart of its own, but still
    // needs its incoming r0-r3 homed contiguously with its stack args, because
    // that block IS the tail it relays. private:docs/bugs/047.
    // Look a symbol up by name — the port has no index, and the back end needs
    // one only for the two vararg-forwarding questions below.
    IRSymbol* symNamed(String* n)
        {
        if (_m == (IRModule*)0 || n == (String*)0)
            return (IRSymbol*)0;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name() != (String*)0 && s.name().equals(n))
                return s;
            }
        return (IRSymbol*)0;
        }

    bool isVaForward(void)
        {
        IRSymbol* s = symNamed(_fn.name());
        if (s == (IRSymbol*)0)
            return false;
        return s.vaforward();
        }

    // The index at which `callee`'s variadic tail starts, or $FFFFFFFF when it
    // is not an xtc variadic. C-ABI callees (libc printf) are excluded: they
    // follow plain AAPCS and must not get the 8-aligned tail.
    u32 varargTailIndexFor(String* callee)
        {
        IRSymbol* s = symNamed(callee);
        if (s == (IRSymbol*)0)
            return (u32)$FFFFFFFF;
        if (!s.variadic() || s.cabi())
            return (u32)$FFFFFFFF;
        IRFunc* f = funcNamed(callee);
        if (f == (IRFunc*)0)
            return (u32)$FFFFFFFF;
        u32 named = (u32)0;
        for (u32 i = (u32)0; i < f.params().count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)f.params().get(i);
            if (pv != (IRValue*)0 && isMemTy(pv.ty()))
                continue;
            named = named + (u32)1;
            }
        return named;
        }

    IRFunc* funcNamed(String* n)
        {
        if (_m == (IRModule*)0 || n == (String*)0)
            return (IRFunc*)0;
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(i);
            if (f.name() != (String*)0 && f.name().equals(n))
                return f;
            }
        return (IRFunc*)0;
        }

    // How many words of variadic tail a forwarder relays. The count cannot be
    // known (the format string decides at run time), so it is capped, exactly
    // as the other targets' 128-byte pack buffer caps them. Copying more than
    // the callee reads is harmless: it reads only what its format names.
    u32 vaForwardWords(void)
        {
        return (u32)16;
        }

    // Relay this function's incoming tail into the callee's slots. Tail word i
    // belongs at callee slot k+i; slots 0-3 are r0-r3, slots >= 4 the outgoing
    // stack. Slots k..3 are disjoint from the 0..k-1 marshalArgs just filled.
    void emitVaForwardRelay(u32 k)
        {
        _out.appendFormat("\t@ vararg forward: relay %lu words to slot %lu+\n",
                          vaForwardWords(), k);
        for (u32 i = (u32)0; i < vaForwardWords(); i = i + (u32)1)
            {
            u32 dst = k + i;
            u32 src = _vaListOff + i * (u32)4;
            if (dst < (u32)4)
                {
                _out.appendFormat("\tldr\tr%lu, [sp, #%lu]\n", dst, src);
                }
            else
                {
                _out.appendFormat("\tldr\tr12, [sp, #%lu]\n", src);
                _out.appendFormat("\tstr\tr12, [sp, #%lu]\n", (dst - (u32)4) * (u32)4);
                }
            }
        }

    bool usesNativeVa(void)
        {
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                if (((IRInsn*)blk.insns().get(i)).op().equals(String.withCString("VaStart")))
                    return true;
            }
        return false;
        }

    // Register homing. The pool is the callee-saved r4-r11 — the prologue
    // already pushes them, so a home costs nothing. There is no caller-saved
    // tier on arm9: r0-r3 and r12 are all scratch here. A function containing
    // inline asm is skipped entirely, because an asm body may name a local by
    // its fixed sp-relative slot.
    void homeValues(void)
        {
        _homing = (Homing*)0;
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                if (((IRInsn*)blk.insns().get(i)).op().equals(String.withCString("Asm")))
                    return;
            }
        Array* callee = new Array();
        callee.add((Object*)String.withCString("r4"));
        callee.add((Object*)String.withCString("r5"));
        callee.add((Object*)String.withCString("r6"));
        callee.add((Object*)String.withCString("r7"));
        callee.add((Object*)String.withCString("r8"));
        callee.add((Object*)String.withCString("r9"));
        callee.add((Object*)String.withCString("r10"));
        callee.add((Object*)String.withCString("r11"));
        Homing* h = new Homing();
        // A 64-bit value occupies two words and cannot live in one home. Left
        // homeable, the allocator puts it in (say) r5 while every consumer
        // reads its SLOT — so the value is written to a register and read from
        // memory nothing wrote: a correct low half and a garbage high half.
        for (u32 hb = (u32)0; hb < _fn.blocks().count(); hb = hb + (u32)1)
            {
            IRBlock* hbb = (IRBlock*)_fn.blocks().get(hb);
            for (u32 hi = (u32)0; hi < hbb.insns().count(); hi = hi + (u32)1)
                {
                IRInsn* hin = (IRInsn*)hbb.insns().get(hi);
                if (hin.res() != (IRValue*)0 && Arm9.isI64(hin.res().ty()))
                    h.exclude(hin.res().pid());
                }
            }
        // A PARAMETER is not an instruction result, so the loop above misses
        // it: `i64 add(i64 a, i64 b)` homed a into r4 holding only its low word.
        for (u32 hp = (u32)0; hp < _fn.params().count(); hp = hp + (u32)1)
            {
            IRValue* hpv = (IRValue*)_fn.params().get(hp);
            if (hpv != (IRValue*)0 && Arm9.isI64(hpv.ty()))
                h.exclude(hpv.pid());
            }
        h.run(_fn, callee, new Array(), new Array(), new Array());
        _homing = h;
        }

    String* homeOf(IRValue* v)
        {
        if (_homing == 0 || v == 0)
            return (String*)0;
        return _homing.homeOf(v.pid());
        }

    // Every value gets a byte-offset frame slot, sized by its A32-native width.
    // Walking ids rather than results covers params and PINNED locals too —
    // those are never an instruction result, they only appear as AddrOf
    // operands. The outgoing-argument area sits at the BOTTOM of the frame, so
    // stack args live at [sp,#0..] and sp never moves around a call.
    void assignSlots(void)
        {
        _slot = new Map();
        u32 maxOut = maxOutgoingStack();
        maxOut = (maxOut + (u32)7) & ~(u32)7;
        // The spill peephole needs this boundary: [sp,#0..maxOut) holds stack
        // ARGUMENTS the CALLEE reads, so no load here refers to them and a load
        // count would call them dead. Above it every slot is this frame's own.
        _outArgBytes = maxOut;
        u32 cur = maxOut;
        _sret = returnsViaSret(_fn.ret());
        if (_sret)
            {
            _sretSlot = cur;
            cur = cur + (u32)4;
            }
        // PRINT order, not id order — mirrors the reference (bug 090).
        Array* order = _fn.valuesInPrintOrder();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            IRValue* val = (IRValue*)order.get(i);
            if (Arm9.isMemTy(val.ty()))
                continue;
            _slot.set((Hashable*)Number.with(val.pid()), (Object*)Number.with(cur));
            u32 w = fieldWidth(val.ty());
            if (w < (u32)4)
                w = (u32)4; // minimum register-width slot
            w = (w + (u32)3) & ~(u32)3;
            cur = cur + w;
            }
        u32 frame = (cur + (u32)7) & ~(u32)7;
        // AAPCS wants sp 8-byte aligned at a public call. `push {r4-r11, lr}` is
        // nine words — odd — and `frame` is already a multiple of 8, so the sub
        // cannot fix it. Pad so (36 + frame) is a multiple of 8.
        if (((u32)36 + frame) & (u32)7)
            frame = frame + (u32)4;
        _frame = frame;
        }

    i32 slotOf(IRValue* v)
        {
        if (v == 0)
            return (i32)-1;
        Object* o = _slot.get((Hashable*)Number.with(v.pid()));
        return o == 0 ? (i32)-1 : (i32)((Number*)o).asU32();
        }

    bool returnsViaSret(String* t)
        {
        return Arm9.isAggTy(t) && aggSize(Arm9.aggIndex(t)) > (u32)4;
        }

    // ── AAPCS32 argument classification ──────────────────────────────────
    // Words a value of this type occupies: a double is two, everything else
    // (including a float and a pointer) is one; an aggregate is its size in
    // words.
    u32 argWords(String* t)
        {
        if (Arm9.isAggTy(t))
            {
            u32 w = (aggSize(Arm9.aggIndex(t)) + (u32)3) / (u32)4;
            return w == (u32)0 ? (u32)1 : w;
            }
        return (Arm9.isF64(t) || Arm9.isI64(t)) ? (u32)2 : (u32)1;
        }

    bool argNeeds8Align(String* t)
        {
        return Arm9.isF64(t) || Arm9.isI64(t);
        }

    // Classify into core registers and the outgoing stack area. Returns four
    // numbers per argument — regStart, regWords, stackOff, stackWords — and
    // leaves the total stack footprint in _lastStackBytes.
    Array* classifyArgs(Array* types, bool sret)
        {
        return classifyArgsAt(types, sret, (u32)$FFFFFFFF);
        }

    // `varargAt` is the index at which the VARIADIC tail begins, or $FFFFFFFF.
    //
    // An xtc variadic on this target starts its tail 8-ALIGNED, which plain
    // AAPCS does not require. The reason is forwarding: a forwarder relays its
    // own tail into the callee's slots word for word, and the callee re-aligns
    // 8-byte reads against ITS base — so if the two bases differ in
    // 8-alignment, every `double` in the tail is read one word out.
    // `withFormat(fmt, …)` has one named word and `appendFormat(self, fmt, …)`
    // has two, which is exactly that case. Both sides apply the rule; C-ABI
    // callees are excluded, since libc follows plain AAPCS. private:docs/bugs/047.
    Array* classifyArgsAt(Array* types, bool sret, u32 varargAt)
        {
        Array* res = new Array();
        u32 ncrn = sret ? (u32)1 : (u32)0;
        u32 nsaa = (u32)0;
        bool stacked = false;
        for (u32 i = (u32)0; i < types.count(); i = i + (u32)1)
            {
            String* t = (String*)types.get(i);
            if (i == varargAt)
                {
                if (!stacked && (ncrn & (u32)1) != (u32)0)
                    ncrn = ncrn + (u32)1;
                if (stacked && (nsaa & (u32)7) != (u32)0)
                    nsaa = nsaa + (u32)4;
                }
            u32 words = argWords(t);
            if (argNeeds8Align(t))
                {
                if (!stacked && (ncrn & (u32)1) != (u32)0)
                    ncrn = ncrn + (u32)1;
                if (stacked && (nsaa & (u32)7) != (u32)0)
                    nsaa = nsaa + (u32)4;
                }
            u32 regStart = (u32)0;
            u32 regWords = (u32)0;
            u32 stackOff = (u32)0;
            u32 stackWords = (u32)0;
            if (!stacked && ncrn + words <= (u32)4)
                {
                regStart = ncrn;
                regWords = words;
                ncrn = ncrn + words;
                }
            else if (!stacked && ncrn < (u32)4)
                {
                regStart = ncrn;
                regWords = (u32)4 - ncrn;
                stackWords = words - regWords;
                stackOff = nsaa;
                nsaa = nsaa + stackWords * (u32)4;
                ncrn = (u32)4;
                stacked = true;
                }
            else
                {
                stacked = true;
                stackOff = nsaa;
                stackWords = words;
                nsaa = nsaa + words * (u32)4;
                }
            Array* one = new Array();
            one.add((Object*)Number.with(regStart));
            one.add((Object*)Number.with(regWords));
            one.add((Object*)Number.with(stackOff));
            one.add((Object*)Number.with(stackWords));
            res.add((Object*)one);
            }
        _lastStackBytes = nsaa;
        return res;
        }

    // The largest outgoing-argument footprint of any call this function makes.
    u32 maxOutgoingStack(void)
        {
        u32 maxOut = (u32)0;
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* insn = (IRInsn*)blk.insns().get(i);
                if (!isArgPassing(insn.op()))
                    continue;
                Array* ats = argTypesOf(insn);
                bool cSret = insn.res() != 0 && !Arm9.isMemTy(insn.res().ty()) && returnsViaSret(insn.res().ty());
                String* cCallee = (String*)0;
                for (u32 z = (u32)0; z < insn.ops().count(); z = z + (u32)1)
                    {
                    IROperand* o = (IROperand*)insn.ops().get(z);
                    if (o.kind() == (u8)OPK_SYM)
                        {
                        cCallee = o.name();
                        z = insn.ops().count();
                        }
                    }
                u32 cVaAt = varargTailIndexFor(cCallee);
                Array* clocs = classifyArgsAt(ats, cSret, cVaAt);
                u32 need = _lastStackBytes;
                // A forwarding call also writes the relayed tail into the
                // outgoing area, past whatever the explicit args used — reserve
                // for it, or the relay lands on this function's own locals.
                if (isVaForward() && insn.op().equals(String.withCString("Call")))
                    {
                    u32 k = cSret ? (u32)1 : (u32)0;
                    for (u32 z = (u32)0; z < clocs.count(); z = z + (u32)1)
                        k = k + ((Number*)((Array*)clocs.get(z)).get((u32)1)).asU32();
                    if ((k & (u32)1) != (u32)0)
                        k = k + (u32)1;
                    u32 last = k + vaForwardWords();
                    if (last > (u32)4 && (last - (u32)4) * (u32)4 > need)
                        need = (last - (u32)4) * (u32)4;
                    }
                if (need > maxOut)
                    maxOut = need;
                }
            }
        return maxOut;
        }

    static bool isArgPassing(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallBankedIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch"));
        }

    // The by-value argument types of a call-shaped instruction. Which operands
    // are arguments depends on the shape: an indirect call leads with the
    // callee, a vtable dispatch carries a slot index, an itable dispatch a
    // protocol id AND a method index — none of those are arguments.
    Array* argTypesOf(IRInsn* insn)
        {
        bool cIndirect = insn.op().equals(String.withCString("CallIndirect")) || insn.op().equals(String.withCString("CallBankedIndirect"));
        bool cVtbl = insn.op().equals(String.withCString("VTblDispatch"));
        bool cProto = insn.op().equals(String.withCString("ProtoDispatch"));
        Array* ats = new Array();
        for (u32 i = (u32)0; i < insn.ops().count(); i = i + (u32)1)
            {
            if (cIndirect && i == (u32)0)
                continue;
            if (cVtbl && i == (u32)1)
                continue;
            if (cProto && (i == (u32)1 || i == (u32)2))
                continue;
            IROperand* o = (IROperand*)insn.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (Arm9.isMemTy(o.val().ty()))
                continue;
            ats.add((Object*)o.val().ty());
            }
        return ats;
        }

    // Spill the incoming parameters to their slots. An aggregate arrives split
    // across r0-r3 and the incoming stack area; each word is copied in turn.
    void spillParams(void)
        {
        if (_sret)
            emitSpAccess(String.withCString("str"), String.withCString("r0"), _sretSlot);
        Array* ptypes = new Array();
        Array* pvals = new Array();
        for (u32 i = (u32)0; i < _fn.params().count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)_fn.params().get(i);
            if (pv == 0 || Arm9.isMemTy(pv.ty()))
                continue;
            ptypes.add((Object*)pv.ty());
            pvals.add((Object*)pv);
            }
        Array* locs = classifyArgs(ptypes, _sret);
        // A va_list starts after the words the NAMED arguments consumed in
        // r0-r3 (an sret pointer among them): the saved block sits at
        // sp + frame + 36, and the first variadic argument follows the named
        // ones inside it.
        if (_nativeVa)
            {
            u32 used = _sret ? (u32)1 : (u32)0;
            for (u32 i = (u32)0; i < locs.count(); i = i + (u32)1)
                used = used + ((Number*)((Array*)locs.get(i)).get((u32)1)).asU32();
            // The tail starts 8-ALIGNED — the caller placed it there — so the
            // base is computed the same way, or the two disagree by a word.
            if ((used & (u32)1) != (u32)0)
                used = used + (u32)1;
            if (used > (u32)4)
                used = (u32)4;
            _vaListOff = _frame + (u32)36 + used * (u32)4;
            }
        for (u32 i = (u32)0; i < pvals.count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)pvals.get(i);
            i32 so = slotOf(pv);
            if (so < (i32)0)
                continue;
            Array* L = (Array*)locs.get(i);
            u32 regStart = ((Number*)L.get((u32)0)).asU32();
            u32 regWords = ((Number*)L.get((u32)1)).asU32();
            u32 stOff = ((Number*)L.get((u32)2)).asU32();
            u32 stWords = ((Number*)L.get((u32)3)).asU32();
            for (u32 k = (u32)0; k < regWords; k = k + (u32)1)
                {
                String* r = String.withCString("r");
                r.appendFormat("%ld", (i32)(regStart + k));
                emitSpAccess(String.withCString("str"), r, (u32)so + (u32)4 * k);
                }
            for (u32 k = (u32)0; k < stWords; k = k + (u32)1)
                {
                emitSpAccess(String.withCString("ldr"), String.withCString("r12"),
                             _frame + (u32)36 + stOff + (u32)4 * k);
                _out.appendFormat("\tstr\tr12, [sp, #%ld]\n",
                                  (i32)((u32)so + (u32)4 * (regWords + k)));
                }
            String* home = homeOf(pv);
            if (home != 0)
                {
                if (regWords >= (u32)1)
                    _out.appendFormat("\tmov\t%s, r%ld\n", home.cString(), (i32)regStart);
                else
                    emitSpAccess(String.withCString("ldr"), home, (u32)so);
                }
            }
        }

    String* blockLabel(IRBlock* b)
        {
        String* s = String.withCString(".L_");
        s.append(_fn.name());
        s.appendCString("_");
        s.append(b.name());
        return s;
        }

    // ── Emission primitives ──────────────────────────────────────────────
    // An ARM data-processing immediate is an 8-bit value rotated right by an
    // even amount. Anything else has to go through a scratch register.
    static bool encodableImm(u32 v)
        {
        for (u32 rot = (u32)0; rot < (u32)16; rot = rot + (u32)1)
            {
            u32 sh = rot * (u32)2;
            u32 rotated = sh == (u32)0 ? v : ((v << sh) | (v >> ((u32)32 - sh)));
            if (rotated <= (u32)255)
                return true;
            }
        return false;
        }

    void emitAlu(String* op, String* dst, String* lhs, u32 imm, String* scratch)
        {
        if (imm == (u32)0)
            {
            if (!dst.equals(lhs))
                _out.appendFormat("\tmov\t%s, %s\n", dst.cString(), lhs.cString());
            return;
            }
        if (Arm9.encodableImm(imm))
            {
            _out.appendFormat("\t%s\t%s, %s, #%lu\n", op.cString(), dst.cString(),
                              lhs.cString(), imm);
            return;
            }
        emitMovImm((i32)imm, scratch);
        _out.appendFormat("\t%s\t%s, %s, %s\n", op.cString(), dst.cString(),
                          lhs.cString(), scratch.cString());
        }

    // Any 32-bit immediate, via ARMv7's movw/movt pair.
    void emitMovImm(i32 imm, String* reg)
        {
        u32 u = (u32)imm;
        _out.appendFormat("\tmovw\t%s, #%lu\n", reg.cString(), u & (u32)$FFFF);
        if (((u >> 16) & (u32)$FFFF) != (u32)0)
            _out.appendFormat("\tmovt\t%s, #%lu\n", reg.cString(), (u >> 16) & (u32)$FFFF);
        }

    // `<mnem> reg, [sp, #off]`, staging sp+off through r12 when the offset is
    // out of the instruction's immediate range. Halfword and signed-byte forms
    // take 8 bits; word and unsigned-byte take 12.
    void emitSpAccess(String* mnem, String* reg, u32 off)
        {
        bool narrow = mnem.equals(String.withCString("strh")) || mnem.equals(String.withCString("ldrh")) || mnem.equals(String.withCString("ldrsh")) || mnem.equals(String.withCString("ldrsb"));
        u32 limit = narrow ? (u32)255 : (u32)4095;
        if (off <= limit)
            {
            _out.appendFormat("\t%s\t%s, [sp, #%lu]\n", mnem.cString(), reg.cString(), off);
            return;
            }
        emitAlu(String.withCString("add"), String.withCString("r12"),
                String.withCString("sp"), off, String.withCString("r12"));
        _out.appendFormat("\t%s\t%s, [r12]\n", mnem.cString(), reg.cString());
        }

    // `ldr reg, [base, #off]` for an off that may pass A32's 12-bit (4095)
    // immediate, where the CALLER OWNS base — the high bits fold into it in
    // place. No scratch is needed: whatever is left after the low 12 bits is a
    // multiple of 4096, and a multiple of 4096 up to $FF000 is an encodable
    // rotated immediate.
    //
    // This is what a vtable slot load needs. Dispatch is BY NAME, so a slot
    // index is a translation-unit-wide method-name id and every class's vtable
    // is as wide as the count of distinct method names in the unit, however few
    // methods the class has. Folding the offset into the instruction capped a
    // unit at 1024 method names — a cliff, not a slope (XG bug 021).
    void emitFarLoad(String* reg, String* base, u32 off)
        {
        u32 hi = off & ~(u32)$FFF;
        while (hi != (u32)0)
            {
            u32 chunk = hi > (u32)$FF000 ? (u32)$FF000 : hi;
            _out.appendFormat("\tadd\t%s, %s, #%lu\n", base.cString(), base.cString(), chunk);
            hi = hi - chunk;
            }
        _out.appendFormat("\tldr\t%s, [%s, #%lu]\n", reg.cString(), base.cString(),
                          off & (u32)$FFF);
        }

    // Keep a block copy's base register in range: the copy walks a struct with
    // `[addr, #i]`, so a struct over 4 KB would emit an unencodable offset —
    // the same defect as the slot load, and just as silent. Advance the base
    // and return the new bias to subtract from later offsets. The caller must
    // own `addr`; every call site loads it into r1 and drops it after.
    u32 rebase(String* addr, u32 off, u32 bias)
        {
        if (off - bias <= (u32)4092)
            return bias;
        u32 step = (off - bias) & ~(u32)$FFF;
        _out.appendFormat("\tadd\t%s, %s, #%lu\n", addr.cString(), addr.cString(), step);
        return bias + step;
        }

    // Load an operand into a register: a homed value from its register, an
    // unhomed one from its slot, an immediate through movw/movt.
    void loadOperand(IROperand* op, String* reg)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            String* home = homeOf(op.val());
            if (home != 0)
                {
                if (!home.equals(reg))
                    _out.appendFormat("\tmov\t%s, %s\n", reg.cString(), home.cString());
                return;
                }
            i32 so = slotOf(op.val());
            if (so >= (i32)0)
                emitSpAccess(String.withCString("ldr"), reg, (u32)so);
            else
                _out.appendFormat("\tmov\t%s, #0\t\t@ phantom/unslotted %%%ld\n",
                                  reg.cString(), (i32)(op.val() == 0 ? (u32)0 : op.val().pid()));
            return;
            }
        if (op.kind() == (u8)OPK_IMMI)
            {
            emitMovImm(op.imm(), reg);
            return;
            }
        _out.appendFormat("\tmov\t%s, #0\t\t@ TODO operand kind %ld\n",
                          reg.cString(), (i32)op.kind());
        }

    // A homed value stays live in its register AND is written to its slot: a
    // direct-slot reader — a stack-passed call argument, an sret copy — has to
    // see valid data there too.
    void storeResult(IRValue* v, String* reg)
        {
        String* home = homeOf(v);
        if (home != 0 && !home.equals(reg))
            _out.appendFormat("\tmov\t%s, %s\n", home.cString(), reg.cString());
        i32 so = slotOf(v);
        if (so >= (i32)0)
            emitSpAccess(String.withCString("str"), reg, (u32)so);
        }

    // Reduce a register to a type's width and signedness. A narrow result
    // computed at full register width has to be canonicalised, or a consumer
    // that compares the raw bits sees a different value.
    void canonicalise(String* reg, String* ty)
        {
        if (ty == 0)
            return;
        if (ty.equals(String.withCString("U8")))
            _out.appendFormat("\tand\t%s, %s, #255\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("Bool")))
            _out.appendFormat("\tand\t%s, %s, #1\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("I8")))
            _out.appendFormat("\tsxtb\t%s, %s\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("U16")))
            _out.appendFormat("\tuxth\t%s, %s\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("I16")))
            _out.appendFormat("\tsxth\t%s, %s\n", reg.cString(), reg.cString());
        }

    static bool isSignedTy(String* t)
        {
        return t != 0 && (t.equals(String.withCString("I8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("I32")));
        }

    String* operandType(IROperand* o)
        {
        if (o.kind() == (u8)OPK_USE && o.val() != 0)
            return o.val().ty();
        return o.ty();
        }

    // ── Instructions ─────────────────────────────────────────────────────
    void emitInsn(IRInsn* insn)
        {
        if (insn.res() != 0 && _dead != 0 && _dead.has(insn.res().pid()))
            return;
        // The `add` folded into a vector op's post-increment writeback.
        if (insn.res() != 0 && _vecSkip != 0 && _vecSkip.has(insn.res().pid()))
            return;
        // A fused compare is emitted by its CondBranch, not here.
        if (insn.res() != 0 && _fusedCmp != 0 && _fusedCmp.has(insn.res().pid()))
            return;
        String* op = insn.op();
        Array* ops = insn.ops();
        IRValue* res = insn.res();

        // 64-bit values, intercepted before every path below — all of which
        // work one word at a time and would silently compute the low half.
        if (res != 0 && Arm9.isI64(res.ty()) && emitInt64(insn, op, ops, res))
            return;

        String* mnem = Arm9.binaryMnemonic(op);
        if (mnem != 0 && ops.count() >= (u32)2 && res != 0)
            {
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
            // A right shift acts on the whole register, but a narrow operand
            // sits in its slot un-extended — an i8 −16 is 0x000000F0 there. So
            // the left side is canonicalised first: AShr needs the sign bits,
            // LShr needs the high bits clear.
            if (op.equals(String.withCString("AShr")) || op.equals(String.withCString("LShr")))
                {
                String* lt = operandType((IROperand*)ops.get((u32)0));
                // ... and for LShr that extension must be UNSIGNED even when the
                // operand's type is signed. Passing the operand type straight in
                // sign-extended it, so `lsr` on i16 -28820 shifted 0xFFFF8F6C and
                // pulled the extension bits down. `>>` on a signed type is an
                // AShr, so the only producer of this shape is the rotate
                // expansion in the shared lowering: every i8/i16 `<:` / `:>` was
                // wrong here while the unsigned ones were right.
                if (op.equals(String.withCString("LShr")) && Arm9.isSignedTy(lt) && fieldWidth(lt) < (u32)4)
                    {
                    if (fieldWidth(lt) == (u32)1)
                        _out.appendCString("\tand\tr0, r0, #255\n");
                    else
                        _out.appendCString("\tuxth\tr0, r0\n");
                    }
                else
                    {
                    canonicalise(String.withCString("r0"), lt);
                    }
                }
            _out.appendFormat("\t%s\tr0, r0, r1\n", mnem.cString());
            storeResult(res, String.withCString("r0"));
            return;
            }
        emitOther(insn, op, ops, res);
        }

    // Load one 64-bit operand into a register pair. arm9 is LITTLE-endian, so
    // the low word is at the LOWER address — the opposite of m68k's pack, which
    // is exactly the kind of detail that silently swaps halves if copied over.
    // The IR TYPE an operand is read at (null when it has none).
    static String* operandTy(IROperand* op)
        {
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            return op.val().ty();
        return op.ty();
        }

    // Load a branch or select condition into `reg` as a word that is zero
    // exactly when the condition is false. A 64-bit condition ORs its two
    // halves (into `scratch` as well): read as its low word alone, `1 << 32`
    // was false (bug 293).
    void loadCondition(IROperand* op, String* reg, String* scratch)
        {
        if (Arm9.isI64(operandTy(op)))
            {
            loadInt64(op, reg, scratch);
            _out.appendFormat("\torr\t%s, %s, %s\n", reg.cString(), reg.cString(), scratch.cString());
            return;
            }
        loadOperand(op, reg);
        }

    void loadInt64(IROperand* op, String* lo, String* hi)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            // An immediate has no slot; reading offset 0 would take whatever
            // sits at the bottom of the frame. Both halves come from the
            // 64-bit value — sign-extending a 32-bit one was only ever right
            // because the payload could not hold more.
            emitMovImm((i32)op.imm(), lo);
            emitMovImm((i32)(op.imm() >> (i64)32), hi);
            return;
            }
        i32 so = op.kind() == (u8)OPK_USE ? slotOf(op.val()) : (i32)-1;
        if (so < (i32)0)
            {
            _out.appendFormat("\tmov\t%s, #0\n", lo.cString());
            _out.appendFormat("\tmov\t%s, #0\n", hi.cString());
            return;
            }
        emitSpAccess(String.withCString("ldr"), lo, (u32)so);
        emitSpAccess(String.withCString("ldr"), hi, (u32)so + (u32)4);
        }

    // Neg / Not on a 64-bit value. Without this they fell through to the
    // 32-bit path, which writes the LOW word only and leaves the high word
    // holding whatever the frame had — `i64 x = -5000000000;` (a Neg over a
    // wide Const) printed a high half of $A5A5A5A5, the stack fill pattern.
    bool emitInt64Unary(String* op, Array* ops, i32 rs)
        {
        bool isNeg = op.equals(String.withCString("Neg"));
        if (!isNeg && !op.equals(String.withCString("Not")))
            return false;
        loadInt64((IROperand*)ops.get((u32)0), String.withCString("r0"),
                  String.withCString("r1"));
        if (isNeg)
            {
            // 0 - x across both words, spelled with subs/sbc (which the Sub
            // path already relies on) rather than rsbs/rsc.
            _out.appendCString("\tmov\tr2, #0\n\tmov\tr3, #0\n");
            _out.appendCString("\tsubs\tr0, r2, r0\n\tsbc\tr1, r3, r1\n");
            }
        else
            {
            _out.appendCString("\tmvn\tr0, r0\n\tmvn\tr1, r1\n");
            }
        emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)rs);
        emitSpAccess(String.withCString("str"), String.withCString("r1"), (u32)rs + (u32)4);
        return true;
        }

    // Every 64-bit-result instruction. Returns false for one this does not
    // handle, so the caller falls through to the ordinary paths.
    //
    // Multiply, divide, modulo and the shifts call libgcc, which arm9 already
    // links. Add, subtract and the bitwise ops do NOT: libgcc has no __adddi3 /
    // __subdi3 / __anddi3 / __ordi3 / __xordi3 on ARM, because every compiler
    // emits them inline. They are two instructions each here.
    bool emitInt64(IRInsn* insn, String* op, Array* ops, IRValue* res)
        {
        i32 rs = slotOf(res);
        if (rs < (i32)0 || ops.count() < (u32)1)
            return false;
        // Producing a 64-bit value from a narrower one, or from another 64-bit
        // one: each falls through to a one-word path that leaves the high word
        // holding whatever the slot did.
        if (op.equals(String.withCString("Const")) || op.equals(String.withCString("Bitcast")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")))
            {
            IROperand* a0 = (IROperand*)ops.get((u32)0);
            if (op.equals(String.withCString("Const")) && a0.kind() == (u8)OPK_IMMI)
                {
                emitMovImm((i32)a0.imm(), String.withCString("r0"));
                emitMovImm((i32)(a0.imm() >> (i64)32), String.withCString("r1"));
                }
            else if (op.equals(String.withCString("Const")) || op.equals(String.withCString("Bitcast")))
                {
                loadInt64(a0, String.withCString("r0"), String.withCString("r1"));
                }
            else
                {
                loadOperand(a0, String.withCString("r0"));
                String* st = operandType(a0);
                u32 sw = fieldWidth(st);
                if (op.equals(String.withCString("SExt")))
                    {
                    if (sw == (u32)1)
                        _out.appendCString("\tsxtb\tr0, r0\n");
                    else if (sw == (u32)2)
                        _out.appendCString("\tsxth\tr0, r0\n");
                    _out.appendCString("\tasr\tr1, r0, #31\n");
                    }
                else
                    {
                    if (sw == (u32)1)
                        _out.appendCString("\tand\tr0, r0, #255\n");
                    else if (sw == (u32)2)
                        _out.appendCString("\tuxth\tr0, r0\n");
                    _out.appendCString("\tmov\tr1, #0\n");
                    }
                }
            emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)rs);
            emitSpAccess(String.withCString("str"), String.withCString("r1"), (u32)rs + (u32)4);
            return true;
            }
        // The UNARY 64-bit ops — in their own method, so emitInt64's frame
        // (already near the 16 KB arm64 budget) does not grow.
        if (ops.count() == (u32)1 && emitInt64Unary(op, ops, rs))
            return true;
        if (ops.count() < (u32)2)
            return false;
        String* h = (String*)0;
        String* loOp = (String*)0;
        String* hiOp = (String*)0;
        if (op.equals(String.withCString("Add")))
            {
            loOp = String.withCString("adds");
            hiOp = String.withCString("adc");
            }
        else if (op.equals(String.withCString("Sub")))
            {
            loOp = String.withCString("subs");
            hiOp = String.withCString("sbc");
            }
        else if (op.equals(String.withCString("And")))
            {
            loOp = String.withCString("and");
            hiOp = String.withCString("and");
            }
        else if (op.equals(String.withCString("Or")))
            {
            loOp = String.withCString("orr");
            hiOp = String.withCString("orr");
            }
        else if (op.equals(String.withCString("Xor")))
            {
            loOp = String.withCString("eor");
            hiOp = String.withCString("eor");
            }
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
        else if (op.equals(String.withCString("Shl")))
            h = String.withCString("__ashldi3");
        else if (op.equals(String.withCString("LShr")))
            h = String.withCString("__lshrdi3");
        else if (op.equals(String.withCString("AShr")))
            h = String.withCString("__ashrdi3");
        if (h == (String*)0 && loOp == (String*)0)
            return false;
        loadInt64((IROperand*)ops.get((u32)0), String.withCString("r0"),
                  String.withCString("r1"));
        // A shift takes its COUNT in r2 as a SINGLE word — that is libgcc's
        // signature, `__ashldi3(long long, int)`.
        bool isShift = op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr"));
        if (isShift)
            loadOperand((IROperand*)ops.get((u32)1), String.withCString("r2"));
        else
            loadInt64((IROperand*)ops.get((u32)1), String.withCString("r2"),
                      String.withCString("r3"));
        if (h != (String*)0)
            _out.appendFormat("\tbl\t%s\n", h.cString());
        else
            {
            _out.appendFormat("\t%s\tr0, r0, r2\n", loOp.cString());
            _out.appendFormat("\t%s\tr1, r1, r3\n", hiOp.cString());
            }
        emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)rs);
        emitSpAccess(String.withCString("str"), String.withCString("r1"), (u32)rs + (u32)4);
        return true;
        }

    static String* binaryMnemonic(String* op)
        {
        if (op.equals(String.withCString("Add")))
            return String.withCString("add");
        if (op.equals(String.withCString("Sub")))
            return String.withCString("sub");
        if (op.equals(String.withCString("Mul")))
            return String.withCString("mul");
        if (op.equals(String.withCString("And")))
            return String.withCString("and");
        if (op.equals(String.withCString("Or")))
            return String.withCString("orr");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("eor");
        if (op.equals(String.withCString("Shl")))
            return String.withCString("lsl");
        if (op.equals(String.withCString("LShr")))
            return String.withCString("lsr");
        if (op.equals(String.withCString("AShr")))
            return String.withCString("asr");
        return (String*)0;
        }

    void emitOther(IRInsn* insn, String* op, Array* ops, IRValue* res)
        {
        if (dispatchVector(insn, op, ops, res))
            return;
        if (op.equals(String.withCString("Const")))
            {
            emitConst(insn, ops, res);
            return;
            }
        if (op.equals(String.withCString("Copy")) || op.equals(String.withCString("IntToPtr")))
            {
            if (res == 0 || ops.count() == (u32)0)
                return;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            storeResult(res, String.withCString("r0"));
            return;
            }
        if (op.equals(String.withCString("Bitcast")) || op.equals(String.withCString("PtrToInt")))
            {
            if (res == 0 || ops.count() == (u32)0)
                return;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            canonicalise(String.withCString("r0"), res.ty());
            storeResult(res, String.withCString("r0"));
            return;
            }
        if (op.equals(String.withCString("Neg")))
            {
            if (res == 0 || ops.count() == (u32)0)
                return;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            _out.appendCString("\trsb\tr0, r0, #0\n");
            storeResult(res, String.withCString("r0"));
            return;
            }
        if (op.equals(String.withCString("Not")))
            {
            if (res == 0 || ops.count() == (u32)0)
                return;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            _out.appendCString("\tmvn\tr0, r0\n");
            storeResult(res, String.withCString("r0"));
            return;
            }
        if (op.equals(String.withCString("ZExt")) || op.equals(String.withCString("Trunc")))
            {
            emitZExtTrunc(op, ops, res);
            return;
            }
        if (op.equals(String.withCString("SExt")))
            {
            emitSExt(ops, res);
            return;
            }
        if (op.equals(String.withCString("ICmp")))
            {
            emitICmp(insn, ops, res);
            return;
            }
        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile")))
            {
            emitLoad(ops, res);
            return;
            }
        if (op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")))
            {
            emitStore(ops);
            return;
            }
        if (op.equals(String.withCString("AddrOf")))
            {
            emitAddrOf(ops, res);
            return;
            }
        if (op.equals(String.withCString("FieldAddr")))
            {
            emitFieldAddr(insn, ops, res);
            return;
            }
        if (op.equals(String.withCString("ElementAddr")))
            {
            emitElementAddr(insn, ops, res);
            return;
            }
        if (Arm9.isPlainCall(op))
            {
            emitCall(insn, op, ops, res);
            return;
            }
        if (op.equals(String.withCString("VTblDispatch")))
            {
            emitDispatch(ops, res, (u32)2, false);
            return;
            }
        if (op.equals(String.withCString("ProtoDispatch")))
            {
            emitDispatch(ops, res, (u32)3, true);
            return;
            }
        if (op.equals(String.withCString("VTblLoad")))
            {
            emitVTblLoad(ops, res);
            return;
            }
        if (op.equals(String.withCString("ProtoLoad")))
            {
            emitProtoLoad(ops, res);
            return;
            }
        if (Arm9.isFloatBinary(op))
            {
            emitFloatBinary(op, ops, res);
            return;
            }
        if (op.equals(String.withCString("FNeg")) || op.equals(String.withCString("FSqrt")))
            {
            emitFloatUnary(op, ops, res);
            return;
            }
        if (op.equals(String.withCString("FCmp")))
            {
            emitFCmp(insn, ops, res);
            return;
            }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            {
            emitIntToFloat(op, ops, res);
            return;
            }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")))
            {
            emitFloatToInt(op, ops, res);
            return;
            }
        if (op.equals(String.withCString("FpExt")))
            {
            emitFpConvert(ops, res, true);
            return;
            }
        if (op.equals(String.withCString("FpTrunc")))
            {
            emitFpConvert(ops, res, false);
            return;
            }
        if (op.equals(String.withCString("Select")))
            {
            emitSelect(ops, res);
            return;
            }
        if (op.equals(String.withCString("SDiv")) || op.equals(String.withCString("UDiv")))
            {
            emitDivHelper(op, ops, res, String.withCString("r0"));
            return;
            }
        if (op.equals(String.withCString("SRem")) || op.equals(String.withCString("URem")))
            {
            emitDivHelper(op, ops, res, String.withCString("r1"));
            return;
            }
        if (emitOtherB(insn, op, ops, res))
            return;
        giveUp(op);
        }

    // The second half of the dispatch. Split only because a single function
    // that touches this many locals exceeds the arm64 backend's 16 KB frame
    // budget — the diagnostic names it, and splitting is the fix.
    bool emitOtherB(IRInsn* insn, String* op, Array* ops, IRValue* res)
        {
        if (op.equals(String.withCString("AggBuild")))
            {
            emitAggBuild(ops, res);
            return true;
            }
        if (op.equals(String.withCString("AggExtract")))
            {
            emitAggExtract(ops, res);
            return true;
            }
        if (op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")))
            {
            emitMemHelper(op, ops);
            return true;
            }
        if (op.equals(String.withCString("WeakRegister")))
            {
            if (ops.count() < (u32)2)
                return true;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
            _out.appendCString("\tbl\t_xtc_weak_register\n");
            return true;
            }
        if (op.equals(String.withCString("WeakUnregister")))
            {
            if (ops.count() == (u32)0)
                return true;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            _out.appendCString("\tbl\t_xtc_weak_unregister\n");
            return true;
            }
        if (op.equals(String.withCString("WeakLoad")))
            {
            if (ops.count() == (u32)0 || res == 0)
                return true;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            _out.appendCString("\tbl\t_xtc_weak_load\n");
            storeResult(res, String.withCString("r0"));
            return true;
            }
        if (op.equals(String.withCString("VaStart")))
            {
            emitVaStart(ops);
            return true;
            }
        if (op.equals(String.withCString("VaArg")))
            {
            emitVaArg(ops, res);
            return true;
            }
        if (op.equals(String.withCString("Asm")))
            {
            emitAsm(ops);
            return true;
            }
        if (op.equals(String.withCString("Rol")) || op.equals(String.withCString("Ror")))
            {
            if (res == 0 || ops.count() < (u32)2)
                return true;
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
            loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
            // There is no rotate-left: rol n is ror (32 − n).
            if (op.equals(String.withCString("Rol")))
                _out.appendCString("\trsb\tr1, r1, #32\n");
            _out.appendCString("\tror\tr0, r0, r1\n");
            storeResult(res, String.withCString("r0"));
            return true;
            }
        if (op.equals(String.withCString("Autorelease")))
            {
            emitRelease(ops);
            return true;
            }
        if (op.equals(String.withCString("Retain")))
            {
            emitRetain(ops);
            return true;
            }
        if (op.equals(String.withCString("Release")))
            {
            emitRelease(ops);
            return true;
            }
        return false;
        }

    static bool isPlainCall(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallBankedIndirect"));
        }

    // AAPCS32. A direct call names its callee with a Sym; an indirect one leads
    // with the function-pointer value. Cloaked and banked are 6502 banking
    // concepts — on a flat machine they collapse to a plain call. An aggregate
    // argument passes by value, split across r0-r3 and the outgoing stack area;
    // an aggregate result over 4 bytes uses sret, so the hidden result pointer
    // takes r0 and the real arguments shift up.
    void emitCall(IRInsn* insn, String* op, Array* ops, IRValue* res)
        {
        bool indirect = op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect"));
        String* callee = (String*)0;
        IROperand* calleeOp = (IROperand*)0;
        Array* args = new Array();
        Array* argTypes = new Array();
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)ops.get(i);
            if (indirect && i == (u32)0)
                {
                calleeOp = o;
                continue;
                }
            if (o.kind() == (u8)OPK_SYM)
                {
                callee = o.name();
                continue;
                }
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (Arm9.isMemTy(o.val().ty()))
                continue;
            args.add((Object*)o);
            argTypes.add((Object*)o.val().ty());
            }
        bool sret = res != 0 && !Arm9.isMemTy(res.ty()) && returnsViaSret(res.ty());
        u32 vaAt = indirect ? (u32)$FFFFFFFF : varargTailIndexFor(callee);
        marshalArgsAt(args, argTypes, sret, res, vaAt);
        // A forwarding call inside a `vaforward` function relays this function's
        // own incoming tail into the callee's slots. Sema guarantees such a
        // function reads no varargs of its own, so its homed r0-r3 block is
        // untouched and IS the tail. private:docs/bugs/047.
        if (!indirect && isVaForward())
            {
            IRSymbol* cs = symNamed(callee);
            if (cs != (IRSymbol*)0 && cs.variadic())
                {
                Array* alocs = classifyArgsAt(argTypes, sret, vaAt);
                u32 k = sret ? (u32)1 : (u32)0;
                for (u32 i = (u32)0; i < alocs.count(); i = i + (u32)1)
                    k = k + ((Number*)((Array*)alocs.get(i)).get((u32)1)).asU32();
                if ((k & (u32)1) != (u32)0)
                    k = k + (u32)1; // tail base is 8-aligned
                emitVaForwardRelay(k);
                }
            }
        if (indirect)
            {
            // The function pointer goes in r12 — caller-saved, and free once the
            // arguments are marshalled.
            loadOperand(calleeOp, String.withCString("r12"));
            _out.appendCString("\tblx\tr12\n");
            }
        else
            {
            _out.appendFormat("\tbl\t%s\n",
                              callee == 0 ? "0 @ TODO unknown callee" : callee.cString());
            }
        if (!sret)
            storeCallResult(res);
        }

    // Virtual and itable dispatch differ only in how the callee is found: a
    // vtable dispatch indexes a fixed slot, an itable one scans for a protocol
    // id first. Everything either side of that — marshalling, the call, the
    // result — is the same, so it is written once.
    void emitDispatch(Array* ops, IRValue* res, u32 firstArg, bool viaItable)
        {
        if (ops.count() < firstArg)
            return;
        IROperand* idxOp = (IROperand*)ops.get(firstArg - (u32)1);
        if (idxOp.kind() != (u8)OPK_IMMI)
            return;
        Array* args = new Array();
        Array* argTypes = new Array();
        IROperand* recv = (IROperand*)ops.get((u32)0);
        args.add((Object*)recv);
        argTypes.add((Object*)(recv.kind() == (u8)OPK_USE && recv.val() != 0
                                   ? recv.val().ty()
                                   : (String*)0));
        for (u32 i = firstArg; i < ops.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)ops.get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (Arm9.isMemTy(o.val().ty()))
                continue;
            args.add((Object*)o);
            argTypes.add((Object*)o.val().ty());
            }
        bool sret = res != 0 && !Arm9.isMemTy(res.ty()) && returnsViaSret(res.ty());
        marshalArgs(args, argTypes, sret, res);
        // The receiver landed in r0 — or r1, when the sret pointer took r0.
        String* recvReg = String.withCString(sret ? "r1" : "r0");
        if (viaItable)
            emitItableLookup(recvReg, (u32)((IROperand*)ops.get((u32)1)).imm());
        else
            _out.appendFormat("\tldr\tr12, [%s]\n", recvReg.cString());
        emitFarLoad(String.withCString("r12"), String.withCString("r12"),
                    (u32)(idxOp.imm() * (i32)4));
        _out.appendCString("\tblx\tr12\n");
        if (!sret)
            storeCallResult(res);
        }

    void emitItableLookup(String* recvReg, u32 pid)
        {
        _out.appendFormat("\tmovw\tr12, #%lu\n", pid & (u32)$FFFF);
        _out.appendFormat("\tmovt\tr12, #%lu\n", (pid >> 16) & (u32)$FFFF);
        _out.appendFormat("\tbl\t%s\n",
                          recvReg.equals(String.withCString("r1")) ? "_xtc_itable_s"
                                                                   : "_xtc_itable");
        }

    // The same address computation without the call — the code word of
    // `&obj.method`. A null receiver yields 0 rather than faulting, so
    // `&nullDelegate.m` is falsy; an empty vtable slot is already 0, which is
    // what makes an unimplemented `optional` method falsy too.
    void emitVTblLoad(Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == 0 || Arm9.isMemTy(res.ty()))
            return;
        IROperand* idxOp = (IROperand*)ops.get((u32)1);
        if (idxOp.kind() != (u8)OPK_IMMI)
            return;
        String* lbl = String.withCString(".L_vtl_");
        lbl.appendFormat("%ld", (i32)_arcLabel);
        _arcLabel = _arcLabel + (u32)1;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        _out.appendCString("\tmov\tr12, #0\n\tcmp\tr0, #0\n");
        _out.appendFormat("\tbeq\t%s\n", lbl.cString());
        _out.appendCString("\tldr\tr12, [r0]\n");
        emitFarLoad(String.withCString("r12"), String.withCString("r12"),
                    (u32)(idxOp.imm() * (i32)4));
        _out.appendFormat("%s:\n", lbl.cString());
        storeResult(res, String.withCString("r12"));
        }

    void emitProtoLoad(Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)3 || res == 0 || Arm9.isMemTy(res.ty()))
            return;
        IROperand* pidOp = (IROperand*)ops.get((u32)1);
        IROperand* idxOp = (IROperand*)ops.get((u32)2);
        if (pidOp.kind() != (u8)OPK_IMMI || idxOp.kind() != (u8)OPK_IMMI)
            return;
        String* lbl = String.withCString(".L_pl_");
        lbl.appendFormat("%ld", (i32)_arcLabel);
        _arcLabel = _arcLabel + (u32)1;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        _out.appendCString("\tmov\tr12, #0\n\tcmp\tr0, #0\n");
        _out.appendFormat("\tbeq\t%s\n", lbl.cString());
        emitItableLookup(String.withCString("r0"), (u32)pidOp.imm());
        // A miss also leaves 0 — the class did not implement an `optional`,
        // which is exactly what respondsTo tests. Never index through null.
        _out.appendCString("\tcmp\tr12, #0\n");
        _out.appendFormat("\tbeq\t%s\n", lbl.cString());
        emitFarLoad(String.withCString("r12"), String.withCString("r12"),
                    (u32)(idxOp.imm() * (i32)4));
        _out.appendFormat("%s:\n", lbl.cString());
        storeResult(res, String.withCString("r12"));
        }

    void marshalArgs(Array* args, Array* argTypes, bool sret, IRValue* res)
        {
        marshalArgsAt(args, argTypes, sret, res, (u32)$FFFFFFFF);
        }

    void marshalArgsAt(Array* args, Array* argTypes, bool sret, IRValue* res, u32 varargAt)
        {
        Array* locs = classifyArgsAt(argTypes, sret, varargAt);
        // Stack arguments FIRST, so the register loads that follow are not
        // clobbered by the copying.
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            Array* L = (Array*)locs.get(i);
            u32 regWords = ((Number*)L.get((u32)1)).asU32();
            u32 stOff = ((Number*)L.get((u32)2)).asU32();
            u32 stWords = ((Number*)L.get((u32)3)).asU32();
            if (stWords == (u32)0)
                continue;
            IROperand* a = (IROperand*)args.get(i);
            i32 s = slotOf(a.val());
            u32 so = s < (i32)0 ? (u32)0 : (u32)s;
            for (u32 k = (u32)0; k < stWords; k = k + (u32)1)
                {
                emitSpAccess(String.withCString("ldr"), String.withCString("r0"),
                             so + (u32)4 * (regWords + k));
                emitSpAccess(String.withCString("str"), String.withCString("r0"),
                             stOff + (u32)4 * k);
                }
            }
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            Array* L = (Array*)locs.get(i);
            u32 regStart = ((Number*)L.get((u32)0)).asU32();
            u32 regWords = ((Number*)L.get((u32)1)).asU32();
            if (regWords == (u32)0)
                continue;
            IROperand* a = (IROperand*)args.get(i);
            if (regWords == (u32)1 && a.kind() != (u8)OPK_USE)
                {
                String* r = String.withCString("r");
                r.appendFormat("%ld", (i32)regStart);
                loadOperand(a, r);
                continue;
                }
            i32 s = slotOf(a.val());
            u32 so = s < (i32)0 ? (u32)0 : (u32)s;
            for (u32 k = (u32)0; k < regWords; k = k + (u32)1)
                {
                String* r = String.withCString("r");
                r.appendFormat("%ld", (i32)(regStart + k));
                emitSpAccess(String.withCString("ldr"), r, so + (u32)4 * k);
                }
            }
        if (sret)
            {
            // r0 = the address of the result slot; the callee writes the
            // aggregate there.
            i32 rs = slotOf(res);
            emitAlu(String.withCString("add"), String.withCString("r0"),
                    String.withCString("sp"), rs < (i32)0 ? (u32)0 : (u32)rs,
                    String.withCString("r12"));
            }
        }

    void storeCallResult(IRValue* res)
        {
        if (res == 0 || Arm9.isMemTy(res.ty()))
            return;
        i32 rs = slotOf(res);
        // a small aggregate is in r0
        if (Arm9.isAggTy(res.ty()))
            {
            if (rs >= (i32)0)
                emitSpAccess(String.withCString("str"),
                             String.withCString("r0"), (u32)rs);
            return true;
            }
        // r0:r1, two words
        if (Arm9.isF64(res.ty()) || Arm9.isI64(res.ty()))
            {
            if (rs >= (i32)0)
                {
                emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)rs);
                emitSpAccess(String.withCString("str"), String.withCString("r1"), (u32)rs + (u32)4);
                }
            return true;
            }
        storeResult(res, String.withCString("r0"));
        }

    // ── Floating point ───────────────────────────────────────────────────
    // The ABI is softfp: a float LIVES as raw bits in its slot and travels in
    // core registers, but the arithmetic is genuine VFP. So every float op is
    // load-to-VFP, compute, store-back.
    static bool isFloatBinary(String* op)
        {
        return op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv"));
        }

    // vldr/vstr reach ±1020 only; a slot beyond that needs a staged base.
    void emitVfp(String* mnem, String* reg, u32 off)
        {
        if (off <= (u32)1020)
            {
            _out.appendFormat("\t%s\t%s, [sp, #%lu]\n", mnem.cString(), reg.cString(), off);
            return true;
            }
        emitAlu(String.withCString("add"), String.withCString("r12"),
                String.withCString("sp"), off, String.withCString("r12"));
        _out.appendFormat("\t%s\t%s, [r12]\n", mnem.cString(), reg.cString());
        }

    void vfpLoad(String* reg, IROperand* op)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            i32 s = slotOf(op.val());
            emitVfp(String.withCString("vldr"), reg, s < (i32)0 ? (u32)0 : (u32)s);
            return true;
            }
        _out.appendFormat("\t@ TODO vfpLoad operand kind %ld\n", (i32)op.kind());
        }

    void vfpStore(String* reg, IRValue* v)
        {
        i32 s = slotOf(v);
        if (s >= (i32)0)
            emitVfp(String.withCString("vstr"), reg, (u32)s);
        }

    static bool isF64(String* t)
        {
        return t != 0 && t.equals(String.withCString("F64"));
        }

    // A 64-bit INTEGER. Eight bytes like a double, and it travels the same
    // routes — two words in a slot, r0:r1 for a return, an even register pair
    // for an argument — so almost everywhere this is asked next to isF64.
    static bool isI64(String* t)
        {
        return t != 0 && (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")));
        }

    void emitFloatBinary(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == 0)
            return;
        bool d = Arm9.isF64(res.ty());
        String* sfx = String.withCString(d ? "f64" : "f32");
        String* ra = String.withCString(d ? "d2" : "s0");
        String* rb = String.withCString(d ? "d3" : "s1");
        string m = "vdiv";
        if (op.equals(String.withCString("FAdd")))
            m = "vadd";
        else if (op.equals(String.withCString("FSub")))
            m = "vsub";
        else if (op.equals(String.withCString("FMul")))
            m = "vmul";
        vfpLoad(ra, (IROperand*)ops.get((u32)0));
        vfpLoad(rb, (IROperand*)ops.get((u32)1));
        _out.appendFormat("\t%s.%s\t%s, %s, %s\n", m, sfx.cString(),
                          ra.cString(), ra.cString(), rb.cString());
        vfpStore(ra, res);
        }

    void emitFloatUnary(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() == (u32)0 || res == 0)
            return true;
        bool d = Arm9.isF64(res.ty());
        String* ra = String.withCString(d ? "d2" : "s0");
        vfpLoad(ra, (IROperand*)ops.get((u32)0));
        _out.appendFormat("\t%s.%s\t%s, %s\n",
                          op.equals(String.withCString("FNeg")) ? "vneg" : "vsqrt",
                          d ? "f64" : "f32", ra.cString(), ra.cString());
        vfpStore(ra, res);
        }

    static String* condForFCmp(String* p)
        {
        if (p == 0)
            return (String*)0;
        if (p.equals(String.withCString("OEQ")))
            return String.withCString("eq");
        if (p.equals(String.withCString("ONE")))
            return String.withCString("ne");
        if (p.equals(String.withCString("OLT")))
            return String.withCString("mi");
        if (p.equals(String.withCString("OGT")))
            return String.withCString("gt");
        if (p.equals(String.withCString("OLE")))
            return String.withCString("ls");
        if (p.equals(String.withCString("OGE")))
            return String.withCString("ge");
        return (String*)0;
        }

    void emitFCmp(IRInsn* insn, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == 0)
            return;
        bool d = Arm9.isF64(operandType((IROperand*)ops.get((u32)0)));
        String* ra = String.withCString(d ? "d2" : "s0");
        String* rb = String.withCString(d ? "d3" : "s1");
        vfpLoad(ra, (IROperand*)ops.get((u32)0));
        vfpLoad(rb, (IROperand*)ops.get((u32)1));
        _out.appendFormat("\tvcmp.%s\t%s, %s\n\tvmrs\tAPSR_nzcv, fpscr\n",
                          d ? "f64" : "f32", ra.cString(), rb.cString());
        String* cc = Arm9.condForFCmp(insn.pred());
        _out.appendCString("\tmov\tr0, #0\n");
        if (cc != 0)
            _out.appendFormat("\tmov%s\tr0, #1\n", cc.cString());
        storeResult(res, String.withCString("r0"));
        }

    void emitIntToFloat(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() == (u32)0 || res == 0)
            return true;
        bool d = Arm9.isF64(res.ty());
        bool sgn = op.equals(String.withCString("SIToFp"));
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        // A narrow source has to be extended before it is a number.
        canonicalise(String.withCString("r0"), operandType((IROperand*)ops.get((u32)0)));
        _out.appendCString("\tvmov\ts0, r0\n");
        String* dst = String.withCString(d ? "d2" : "s0");
        _out.appendFormat("\tvcvt.%s.%s32\t%s, s0\n", d ? "f64" : "f32",
                          sgn ? "s" : "u", dst.cString());
        vfpStore(dst, res);
        }

    // An out-of-range float→int SATURATES TO ZERO (LANGUAGE-SPEC §3.1), which
    // takes two tests: re-extending the low bits catches a value that overflows
    // a NARROW destination, and the FPSCR invalid-operation flag catches a vcvt
    // that saturated the 32-bit conversion itself.
    void emitFloatToInt(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() == (u32)0 || res == 0)
            return true;
        String* st = operandType((IROperand*)ops.get((u32)0));
        bool d = Arm9.isF64(st);
        bool sgn = op.equals(String.withCString("FpToSI"));
        String* src = String.withCString(d ? "d2" : "s0");
        vfpLoad(src, (IROperand*)ops.get((u32)0));
        _out.appendCString("\tvmrs\tr1, fpscr\n\tbic\tr1, r1, #1\n\tvmsr\tfpscr, r1\n");
        _out.appendFormat("\tvcvt.%s32.%s\ts0, %s\n", sgn ? "s" : "u",
                          d ? "f64" : "f32", src.cString());
        _out.appendCString("\tvmov\tr0, s0\n");
        _out.appendCString("\tmov\tr1, r0\n");
        canonicalise(String.withCString("r1"), res.ty());
        _out.appendCString("\tcmp\tr0, r1\n\tmovne\tr0, #0\n");
        _out.appendCString("\tvmrs\tr1, fpscr\n\ttst\tr1, #1\n\tmovne\tr0, #0\n");
        canonicalise(String.withCString("r0"), res.ty());
        storeResult(res, String.withCString("r0"));
        }

    void emitFpConvert(Array* ops, IRValue* res, bool widen)
        {
        if (ops.count() == (u32)0 || res == 0)
            return true;
        if (widen)
            {
            vfpLoad(String.withCString("s0"), (IROperand*)ops.get((u32)0));
            _out.appendCString("\tvcvt.f64.f32\td2, s0\n");
            vfpStore(String.withCString("d2"), res);
            return true;
            }
        vfpLoad(String.withCString("d2"), (IROperand*)ops.get((u32)0));
        _out.appendCString("\tvcvt.f32.f64\ts0, d2\n");
        vfpStore(String.withCString("s0"), res);
        }

    // An aggregate is assembled field by field into the result's slot, at this
    // machine's field offsets.
    void emitAggBuild(Array* ops, IRValue* res)
        {
        if (res == 0 || !Arm9.isAggTy(res.ty()))
            return;
        i32 bs = slotOf(res);
        if (bs < (i32)0)
            return;
        u32 layout = Arm9.aggIndex(res.ty());
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            IROperand* f = (IROperand*)ops.get(i);
            String* fty = operandType(f);
            loadOperand(f, String.withCString("r0"));
            u32 foff = (u32)bs + fieldOffset(layout, i);
            u32 w = fieldWidth(fty);
            string st = "str";
            if (!Arm9.isPtrTy(fty))
                {
                if (w == (u32)2)
                    st = "strh";
                else if (w == (u32)1)
                    st = "strb";
                }
            emitSpAccess(String.withCString(st), String.withCString("r0"), foff);
            }
        }

    void emitAggExtract(Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == 0)
            return;
        IROperand* srcOp = (IROperand*)ops.get((u32)0);
        String* aggTy = operandType(srcOp);
        if (!Arm9.isAggTy(aggTy))
            return;
        i32 ss = slotOf(srcOp.val());
        if (ss < (i32)0)
            return;
        u32 foff = (u32)ss + fieldOffset(Arm9.aggIndex(aggTy),
                                         (u32)((IROperand*)ops.get((u32)1)).imm());
        String* rty = res.ty();
        u32 w = fieldWidth(rty);
        bool sgn = Arm9.isSignedTy(rty);
        string ld = "ldr";
        if (!Arm9.isPtrTy(rty))
            {
            if (w == (u32)2)
                ld = sgn ? "ldrsh" : "ldrh";
            else if (w == (u32)1)
                ld = sgn ? "ldrsb" : "ldrb";
            }
        emitSpAccess(String.withCString(ld), String.withCString("r0"), foff);
        storeResult(res, String.withCString("r0"));
        }

    void emitMemHelper(String* op, Array* ops)
        {
        if (ops.count() < (u32)3)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
        loadOperand((IROperand*)ops.get((u32)2), String.withCString("r2"));
        _out.appendFormat("\tbl\t%s\n",
                          op.equals(String.withCString("MemCopy")) ? "memcpy" : "memset");
        }

    // Native AAPCS va_list: `ap` is the address of the first VARIADIC argument,
    // which the prologue arranged to be contiguous with the saved r0-r3. The
    // variadic function hands that straight to libc's vprintf.
    void emitVaStart(Array* ops)
        {
        if (ops.count() == (u32)0)
            return;
        emitAlu(String.withCString("add"), String.withCString("r0"),
                String.withCString("sp"), _vaListOff, String.withCString("r12"));
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r1"));
        _out.appendCString("\tstr\tr0, [r1]\n");
        }

    // Read the next argument out of a va_list and advance it. The caller
    // promoted narrow integers to int and floats to double, so a narrow or
    // float result reads the PROMOTED width and then converts back.
    void emitVaArg(Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        String* rt = res.ty();
        bool f64 = Arm9.isF64(rt);
        bool f32 = rt != 0 && rt.equals(String.withCString("F32"));
        // A 64-bit INTEGER is 8-byte aligned and 8 bytes wide, exactly as an
        // f64 is — AAPCS makes no distinction. It used to fall through to the
        // generic word branch below, which reads ONE word and advances four:
        // `%lld` printed garbage and every following argument shifted by a
        // word. Only f64 had been taught the rule.
        bool wide64 = Arm9.isI64(rt); // `i64` is a TYPE KEYWORD, not a name
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r1"));
        _out.appendCString("\tldr\tr2, [r1]\n");
        // An 8-byte type is 8-aligned in the list.
        if (f64 || f32 || wide64)
            _out.appendCString("\tadd\tr2, r2, #7\n\tbic\tr2, r2, #7\n");
        if (wide64)
            {
            i32 ro = slotOf(res);
            _out.appendCString("\tldr\tr0, [r2]\n\tldr\tr3, [r2, #4]\n");
            _out.appendCString("\tadd\tr2, r2, #8\n\tstr\tr2, [r1]\n");
            if (ro >= (i32)0)
                {
                emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ro);
                emitSpAccess(String.withCString("str"), String.withCString("r3"), (u32)ro + (u32)4);
                }
            return;
            }
        if (f64)
            {
            _out.appendCString("\tvldr\td0, [r2]\n\tadd\tr3, r2, #8\n\tstr\tr3, [r1]\n");
            vfpStore(String.withCString("d0"), res);
            return;
            }
        if (f32)
            {
            _out.appendCString("\tvldr\td0, [r2]\n\tvcvt.f32.f64\ts0, d0\n");
            _out.appendCString("\tadd\tr3, r2, #8\n\tstr\tr3, [r1]\n");
            vfpStore(String.withCString("s0"), res);
            return;
            }
        String* pte = Arm9.pointeeOf(rt);
        if (Arm9.isAggTy(pte))
            {
            // A struct-by-value vararg sits INLINE in the list, so what comes
            // back is a pointer to it — the cursor itself — not a load of its
            // first word.
            u32 sz = aggSize(Arm9.aggIndex(pte));
            u32 adv = ((sz + (u32)3) / (u32)4) * (u32)4;
            if (adv == (u32)0)
                adv = (u32)4;
            _out.appendCString("\tmov\tr0, r2\n");
            _out.appendFormat("\tadd\tr3, r2, #%lu\n\tstr\tr3, [r1]\n", adv);
            storeResult(res, String.withCString("r0"));
            return;
            }
        _out.appendCString("\tldr\tr0, [r2]\n\tadd\tr3, r2, #4\n\tstr\tr3, [r1]\n");
        canonicalise(String.withCString("r0"), rt);
        storeResult(res, String.withCString("r0"));
        }

    // `asm { … }` — the body goes out verbatim. Homing is suppressed for any
    // function containing one, so a body may name a local by its fixed
    // sp-relative slot, which is what `{{XTLOCAL:n}}` resolves to.
    void emitAsm(Array* ops)
        {
        u32 cid = (u32)0;
        bool found = false;
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)ops.get(i);
            if (o.kind() != (u8)OPK_CPOOL)
                continue;
            cid = o.cid();
            found = true;
            }
        if (!found || cid >= _m.consts().count())
            return;
        Array* bytes = (Array*)_m.consts().get(cid);
        String* text = String.withCString("");
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            {
            u32 b = ((Number*)bytes.get(i)).asU32();
            if (b != (u32)0)
                text.appendByte((u8)b);
            }
        text = resolveAsmLocals(text);
        _out.appendCString("\t@ inline asm\n");
        Array* lines = text.splitOnByte((u8)10);
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (t.byteLength() > (u32)0)
                _out.appendFormat("\t%s\n", t.cString());
            }
        }

    // `{{XTLOCAL:n}}` -> `sp, #<slot>`. The lowering emits the token because it
    // does not know the frame layout; this is where the frame is known.
    String* resolveAsmLocals(String* text)
        {
        String* marker = String.withCString("{{XTLOCAL:");
        if (text.byteIndexOf(marker) == String.notFound())
            return text;
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < text.byteLength())
            {
            if (text.byteAt(i) == (u8)'{' && i + marker.byteLength() <= text.byteLength() && text.substringBytes(i, marker.byteLength()).equals(marker))
                {
                u32 j = i + marker.byteLength();
                u32 vid = (u32)0;
                while (j < text.byteLength() && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9')
                    {
                    vid = vid * (u32)10 + (u32)(text.byteAt(j) - (u8)'0');
                    j = j + (u32)1;
                    }
                while (j < text.byteLength() && text.byteAt(j) == (u8)'}')
                    j = j + (u32)1;
                Object* so = _slot.get((Hashable*)Number.with(vid));
                out.appendFormat("sp, #%ld", (i32)(so == 0 ? (u32)0 : ((Number*)so).asU32()));
                i = j;
                continue;
                }
            out.appendByte(text.byteAt(i));
            i = i + (u32)1;
            }
        return out;
        }

    void emitSelect(Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() < (u32)3)
            return;
        loadCondition((IROperand*)ops.get((u32)0), String.withCString("r2"), String.withCString("r3"));
        loadOperand((IROperand*)ops.get((u32)1), String.withCString("r0"));
        loadOperand((IROperand*)ops.get((u32)2), String.withCString("r1"));
        _out.appendCString("\tcmp\tr2, #0\n\tmoveq\tr0, r1\n");
        storeResult(res, String.withCString("r0"));
        }

    // The Cortex-A9 has NO hardware integer divide — sdiv/udiv are undefined
    // there — so division and remainder go through the EABI runtime helpers.
    // The divmod pair returns the quotient in r0 and the remainder in r1.
    void emitDivHelper(String* op, Array* ops, IRValue* res, String* resultReg)
        {
        if (res == 0 || ops.count() < (u32)2)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
        string helper = "__aeabi_uidiv";
        if (op.equals(String.withCString("SDiv")))
            helper = "__aeabi_idiv";
        else if (op.equals(String.withCString("SRem")))
            helper = "__aeabi_idivmod";
        else if (op.equals(String.withCString("URem")))
            helper = "__aeabi_uidivmod";
        _out.appendFormat("\tbl\t%s\n", helper);
        storeResult(res, resultReg);
        }

    void emitConst(IRInsn* insn, Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        IROperand* o = (IROperand*)ops.get((u32)0);
        if (o.kind() == (u8)OPK_IMMF)
            {
            emitFloatConst(o, res);
            return;
            }
        loadOperand(o, String.withCString("r0"));
        storeResult(res, String.withCString("r0"));
        }

    // softfp: a float lives as raw IEEE bits in its slot, so a float constant
    // is just those bits written there. The operand always carries the DOUBLE
    // pattern; an F32 result is narrowed to single precision first.
    void emitFloatConst(IROperand* o, IRValue* res)
        {
        i32 so = slotOf(res);
        u32 base = so < (i32)0 ? (u32)0 : (u32)so;
        u32 hi = Arm9.hexWord(o.fpHex(), (u32)0);
        u32 lo = Arm9.hexWord(o.fpHex(), (u32)8);
        if (Arm9.isF64(res.ty()))
            {
            emitMovImm((i32)lo, String.withCString("r0"));
            emitMovImm((i32)hi, String.withCString("r1"));
            emitSpAccess(String.withCString("str"), String.withCString("r0"), base);
            emitSpAccess(String.withCString("str"), String.withCString("r1"), base + (u32)4);
            return;
            }
        emitMovImm((i32)Arm9.doubleBitsToFloatBits(hi, lo), String.withCString("r0"));
        emitSpAccess(String.withCString("str"), String.withCString("r0"), base);
        }

    // Eight hex digits of a 16-digit pattern, as a word.
    static u32 hexWord(String* hex, u32 at)
        {
        u32 v = (u32)0;
        for (u32 i = at; i < at + (u32)8 && i < hex.byteLength(); i = i + (u32)1)
            {
            u8 c = hex.byteAt(i);
            u32 d = (u32)0;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            v = (v << 4) | d;
            }
        return v;
        }

    // IEEE754 double bits -> float bits, round-to-nearest-even — the same
    // narrowing a `(float)` cast does, done on the PATTERN because that is what
    // the IR carries. Sign, then the 11-bit exponent rebiased to 8, then 52
    // mantissa bits rounded to 23. Overflow goes to infinity and a value too
    // small to represent goes to zero; a subnormal result is not produced,
    // which matches what the source-level conversion already did.
    static u32 doubleBitsToFloatBits(u32 hi, u32 lo)
        {
        u32 sign = (hi >> 31) & (u32)1;
        u32 exp = (hi >> 20) & (u32)$7FF;
        u32 mantHi = hi & (u32)$FFFFF; // top 20 mantissa bits
        if (exp == (u32)0 && mantHi == (u32)0 && lo == (u32)0)
            return sign << 31;
        // inf / NaN keep their kind
        if (exp == (u32)$7FF)
            {
            u32 m = (mantHi != (u32)0 || lo != (u32)0) ? (u32)$400000 : (u32)0;
            return (sign << 31) | ((u32)255 << 23) | m;
            }
        i32 e = (i32)exp - (i32)1023 + (i32)127;
        if (e >= (i32)255)
            return (sign << 31) | ((u32)255 << 23); // overflow -> inf
        if (e <= (i32)0)
            return sign << 31; // underflow -> 0
        // 23 mantissa bits, plus the guard bit and a sticky OR of the rest.
        u32 mant = (mantHi << 3) | (lo >> 29);
        u32 guard = (lo >> 28) & (u32)1;
        u32 sticky = ((lo & (u32)$FFFFFFF) != (u32)0) ? (u32)1 : (u32)0;
        if (guard == (u32)1 && (sticky == (u32)1 || (mant & (u32)1) == (u32)1))
            {
            mant = mant + (u32)1;
            // carried out of the mantissa
            if (mant > (u32)$7FFFFF)
                {
                mant = (u32)0;
                e = e + (i32)1;
                if (e >= (i32)255)
                    return (sign << 31) | ((u32)255 << 23);
                }
            }
        return (sign << 31) | ((u32)e << 23) | mant;
        }

    void emitZExtTrunc(String* op, Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        if (op.equals(String.withCString("Trunc")))
            {
            // Truncate to the result's width AND signedness: a signed narrow
            // result is sign-extended, an unsigned one zero-extended.
            canonicalise(String.withCString("r0"), res.ty());
            }
        else
            {
            // ZExt zero-fills to the narrower of source and result width.
            u32 w = fieldWidth(res.ty());
            u32 sw = fieldWidth(operandType((IROperand*)ops.get((u32)0)));
            u32 mw = sw < w ? sw : w;
            if (mw == (u32)1)
                _out.appendCString("\tand\tr0, r0, #255\n");
            else if (mw == (u32)2)
                _out.appendCString("\tuxth\tr0, r0\n");
            }
        storeResult(res, String.withCString("r0"));
        }

    void emitSExt(Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        u32 sw = fieldWidth(operandType((IROperand*)ops.get((u32)0)));
        if (sw == (u32)1)
            _out.appendCString("\tsxtb\tr0, r0\n");
        else if (sw == (u32)2)
            _out.appendCString("\tsxth\tr0, r0\n");
        // Sign-extend from the SOURCE width, then canonicalise to the RESULT
        // type: `(u16)(i8 -1)` is 65535, not 0xFFFFFFFF.
        canonicalise(String.withCString("r0"), res.ty());
        storeResult(res, String.withCString("r0"));
        }

    static String* condForICmp(String* p)
        {
        if (p == 0)
            return (String*)0;
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
            return String.withCString("lo");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("hi");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("ls");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("hs");
        return (String*)0;
        }

    void emitICmp(IRInsn* insn, Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() < (u32)2)
            return;
        String* cc = Arm9.condForICmp(insn.pred());
        // A 64-bit compare is not one `cmp`: the single-word path below reads
        // the LOW word of each operand and ignores the rest, so `7 == 0` came
        // out true. Done inline rather than through libgcc's __cmpdi2 — that
        // call works, but drags newlib in behind it (undefined abort/calloc/
        // fprintf/_impure_ptr/free), which is a lot of loader surface for three
        // instructions.
        String* ct0 = operandTy((IROperand*)ops.get((u32)0));
        String* ct1 = operandTy((IROperand*)ops.get((u32)1));
        if (Arm9.isI64(ct0) || Arm9.isI64(ct1))
            {
            bool sgn = ct0.equals(String.withCString("I64")) || ct1.equals(String.withCString("I64"));
            String* p = insn.pred();
            bool ordered = !p.equals(String.withCString("EQ")) && !p.equals(String.withCString("NE"));
            if (sgn && ordered)
                {
                // The signed orderings all reduce to lt/ge on a 64-bit
                // SUBTRACTION: `subs` then `sbcs` leaves N and V set from the
                // full-width result, which is exactly the signed comparison.
                // `a > b` is `b < a`, so the two "greater" forms swap operands
                // rather than needing a condition that also reads Z — Z here
                // reflects only the high word and would be wrong.
                bool swap = p.equals(String.withCString("SGT")) || p.equals(String.withCString("SLE"));
                String* cc2 = (p.equals(String.withCString("SLT")) || p.equals(String.withCString("SGT")))
                                  ? String.withCString("lt")
                                  : String.withCString("ge");
                loadInt64((IROperand*)ops.get(swap ? (u32)1 : (u32)0),
                          String.withCString("r0"), String.withCString("r1"));
                loadInt64((IROperand*)ops.get(swap ? (u32)0 : (u32)1),
                          String.withCString("r2"), String.withCString("r3"));
                _out.appendCString("\tsubs\tr12, r0, r2\n\tsbcs\tr12, r1, r3\n");
                _out.appendCString("\tmov\tr0, #0\n");
                _out.appendFormat("\tmov%s\tr0, #1\n", cc2.cString());
                storeResult(res, String.withCString("r0"));
                return;
                }
            // Equality, and the unsigned orderings: compare the high words, and
            // only if they are equal let the low words decide. `cmpeq` is
            // exactly that, and the unsigned conditions read C/Z, which both
            // comparisons set correctly.
            loadInt64((IROperand*)ops.get((u32)0),
                      String.withCString("r0"), String.withCString("r1"));
            loadInt64((IROperand*)ops.get((u32)1),
                      String.withCString("r2"), String.withCString("r3"));
            _out.appendCString("\tcmp\tr1, r3\n\tcmpeq\tr0, r2\n\tmov\tr0, #0\n");
            if (cc != 0)
                _out.appendFormat("\tmov%s\tr0, #1\n", cc.cString());
            storeResult(res, String.withCString("r0"));
            return;
            }
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
        _out.appendCString("\tcmp\tr0, r1\n\tmov\tr0, #0\n");
        if (cc != 0)
            _out.appendFormat("\tmov%s\tr0, #1\n", cc.cString());
        storeResult(res, String.withCString("r0"));
        }

    void emitLoad(Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r1"));
        String* pte = res.ty();
        if (Arm9.isAggTy(pte))
            {
            blockCopyToSlot(res, String.withCString("r1"),
                            aggSize(Arm9.aggIndex(pte)));
            return;
            }
        // Eight bytes is two words, for an i64 exactly as for a double: without
        // the integer arm, `*p = someU64` wrote one word and what came back was
        // not what went in.
        if (Arm9.isF64(pte) || Arm9.isI64(pte))
            {
            i32 rs = slotOf(res);
            _out.appendCString("\tldr\tr0, [r1]\n\tldr\tr2, [r1, #4]\n");
            if (rs >= (i32)0)
                {
                emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)rs);
                emitSpAccess(String.withCString("str"), String.withCString("r2"), (u32)rs + (u32)4);
                }
            return;
            }
        u32 w = fieldWidth(pte);
        String* ld = String.withCString("ldr");
        if (!Arm9.isPtrTy(pte))
            {
            if (w == (u32)2)
                ld = String.withCString(Arm9.isSignedTy(pte) ? "ldrsh" : "ldrh");
            else if (w == (u32)1)
                ld = String.withCString(Arm9.isSignedTy(pte) ? "ldrsb" : "ldrb");
            }
        _out.appendFormat("\t%s\tr0, [r1]\n", ld.cString());
        storeResult(res, String.withCString("r0"));
        }

    void emitStore(Array* ops)
        {
        if (ops.count() < (u32)2)
            return;
        IROperand* vop = (IROperand*)ops.get((u32)1);
        String* vty = operandType(vop);
        if (Arm9.isAggTy(vty) && vop.kind() == (u8)OPK_USE)
            {
            loadOperand((IROperand*)ops.get((u32)0), String.withCString("r1"));
            blockCopyFromSlot(vop.val(), String.withCString("r1"),
                              aggSize(Arm9.aggIndex(vty)));
            return;
            }
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r1"));
        // eight bytes is two words
        if (Arm9.isF64(vty) || Arm9.isI64(vty))
            {
            i32 vs = vop.kind() == (u8)OPK_USE ? slotOf(vop.val()) : (i32)-1;
            u32 so = vs < (i32)0 ? (u32)0 : (u32)vs;
            emitSpAccess(String.withCString("ldr"), String.withCString("r0"), so);
            emitSpAccess(String.withCString("ldr"), String.withCString("r2"), so + (u32)4);
            _out.appendCString("\tstr\tr0, [r1]\n\tstr\tr2, [r1, #4]\n");
            return;
            }
        loadOperand(vop, String.withCString("r0"));
        u32 w = fieldWidth(vty);
        String* st = String.withCString("str");
        if (!Arm9.isPtrTy(vty))
            {
            if (w == (u32)2)
                st = String.withCString("strh");
            else if (w == (u32)1)
                st = String.withCString("strb");
            }
        _out.appendFormat("\t%s\tr0, [r1]\n", st.cString());
        }

    // An aggregate moves in words then bytes: one ldr would drop everything
    // past the first four.
    void blockCopyToSlot(IRValue* v, String* addr, u32 size)
        {
        i32 s = slotOf(v);
        if (s < (i32)0)
            return;
        u32 base = (u32)s;
        u32 i = (u32)0;
        u32 bias = (u32)0;
        while (i + (u32)4 <= size)
            {
            bias = rebase(addr, i, bias);
            _out.appendFormat("\tldr\tr2, [%s, #%lu]\n", addr.cString(), i - bias);
            emitSpAccess(String.withCString("str"), String.withCString("r2"), base + i);
            i = i + (u32)4;
            }
        while (i < size)
            {
            bias = rebase(addr, i, bias);
            _out.appendFormat("\tldrb\tr2, [%s, #%lu]\n", addr.cString(), i - bias);
            emitSpAccess(String.withCString("strb"), String.withCString("r2"), base + i);
            i = i + (u32)1;
            }
        }

    void blockCopyFromSlot(IRValue* v, String* addr, u32 size)
        {
        i32 s = slotOf(v);
        if (s < (i32)0)
            return;
        u32 base = (u32)s;
        u32 i = (u32)0;
        u32 bias = (u32)0;
        while (i + (u32)4 <= size)
            {
            emitSpAccess(String.withCString("ldr"), String.withCString("r2"), base + i);
            bias = rebase(addr, i, bias);
            _out.appendFormat("\tstr\tr2, [%s, #%lu]\n", addr.cString(), i - bias);
            i = i + (u32)4;
            }
        while (i < size)
            {
            emitSpAccess(String.withCString("ldrb"), String.withCString("r2"), base + i);
            bias = rebase(addr, i, bias);
            _out.appendFormat("\tstrb\tr2, [%s, #%lu]\n", addr.cString(), i - bias);
            i = i + (u32)1;
            }
        }

    void emitAddrOf(Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() == (u32)0)
            return;
        IROperand* o = (IROperand*)ops.get((u32)0);
        if (o.kind() == (u8)OPK_SYM)
            {
            // PIC: the address comes out of a literal pool, which the loader
            // relocates. The absolute movw/movt pair would be shorter and is
            // wrong in a position-independent object.
            _out.appendFormat("\tldr\tr0, =%s\n", o.name().cString());
            }
        else if (o.kind() == (u8)OPK_USE)
            {
            i32 s = slotOf(o.val());
            emitAlu(String.withCString("add"), String.withCString("r0"),
                    String.withCString("sp"), s < (i32)0 ? (u32)0 : (u32)s,
                    String.withCString("r12"));
            }
        else
            {
            _out.appendFormat("\tmov\tr0, #0\t\t@ TODO AddrOf operand kind %ld\n",
                              (i32)o.kind());
            }
        storeResult(res, String.withCString("r0"));
        }

    // The pointee of a base operand — what an ElementAddr strides by and what a
    // FieldAddr indexes into.
    String* pointeeOfOperand(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return (String*)0;
        return Arm9.pointeeOf(o.val().ty());
        }

    void emitFieldAddr(IRInsn* insn, Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() < (u32)2)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        u32 off = (u32)0;
        String* pte = pointeeOfOperand((IROperand*)ops.get((u32)0));
        if (Arm9.isAggTy(pte))
            off = fieldOffset(Arm9.aggIndex(pte),
                              (u32)((IROperand*)ops.get((u32)1)).imm());
        emitAlu(String.withCString("add"), String.withCString("r0"),
                String.withCString("r0"), off, String.withCString("r12"));
        storeResult(res, String.withCString("r0"));
        }

    void emitElementAddr(IRInsn* insn, Array* ops, IRValue* res)
        {
        if (res == 0 || ops.count() < (u32)2)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        loadOperand((IROperand*)ops.get((u32)1), String.withCString("r1"));
        String* pte = pointeeOfOperand((IROperand*)ops.get((u32)0));
        u32 es = fieldWidth(pte);
        if (es == (u32)0)
            es = (u32)1;
        emitScaledAdd(es);
        storeResult(res, String.withCString("r0"));
        }

    // r0 = r0 + r1·stride. A power of two folds into the shifted-register form;
    // anything else needs a multiply.
    void emitScaledAdd(u32 es)
        {
        if (es == (u32)1)
            {
            _out.appendCString("\tadd\tr0, r0, r1\n");
            return;
            }
        u32 sh = (u32)0;
        u32 v = es;
        while ((v & (u32)1) == (u32)0 && v > (u32)1)
            {
            v = v >> 1;
            sh = sh + (u32)1;
            }
        if (v == (u32)1)
            {
            _out.appendFormat("\tadd\tr0, r0, r1, lsl #%lu\n", sh);
            return;
            }
        // A non-power-of-two stride is one instruction here: the A9 has a
        // multiply-accumulate.
        emitMovImm((i32)es, String.withCString("r2"));
        _out.appendCString("\tmla\tr0, r1, r2, r0\n");
        }

    // ARC: the refcount is a halfword just below the object. A pointer below
    // 0x10000 is a non-heap object (a static instance, or null) and is left
    // alone — the same test both the runtime and every other backend uses.
    // Does anything in this module call the runtime's thread-create primitive?
    // The instruction stream is the question, not the symbol table.
    bool spawnsThreads(IRModule* m)
        {
        String* want = String.withCString("_xt_thread_create");
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (insnsName(bb.phis(), want))
                    return true;
                if (insnsName(bb.insns(), want))
                    return true;
                if (bb.term() != (IRInsn*)0 && insnNames(bb.term(), want))
                    return true;
                }
            }
        return false;
        }

    bool insnsName(Array* list, String* want)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if (insnNames((IRInsn*)list.get(i), want))
                return true;
        return false;
        }

    bool insnNames(IRInsn* n, String* want)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_SYM)
                continue;
            if (o.name() != (String*)0 && o.name().equals(want))
                return true;
            }
        return false;
        }

    void emitRetain(Array* ops)
        {
        if (ops.count() == (u32)0)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        String* lbl = arcLabel();
        _out.appendCString("\tcmp\tr0, #0x10000\n");
        _out.appendFormat("\tblo\t%s\n", lbl.cString());
        // A refcount of ZERO means the object is being DESTROYED: the release
        // that took it to 0 is running dealloc right now. Retaining it here would
        // let the matching release take it back to 0 and dispatch dealloc AGAIN,
        // forever — which is what any strong binding of `self` inside a dealloc
        // used to cause (bug 038). A live object always holds at least one
        // reference, so 0 can only mean "already dying"; release has always had
        // the mirror-image guard, and this makes the pair symmetric.
        _out.appendCString("\tldrh\tr1, [r0, #-2]\n\tcmp\tr1, #0\n");
        _out.appendFormat("\tbeq\t%s\n", lbl.cString());
        if (_atomicArc)
            {
            // LDREXH tags the address; STREXH stores only if nothing else wrote
            // it in between and reports failure in r2, so the loop re-runs on a
            // lost race. Unprivileged, so it works whether the body runs in User
            // or System mode, and still correct if a second core is brought up.
            String* retry = arcLabel();
            _out.appendFormat("\tsub\tr3, r0, #2\n%s:\n", retry.cString());
            _out.appendCString("\tldrexh\tr1, [r3]\n\tadd\tr1, r1, #1\n\tstrexh\tr2, r1, [r3]\n");
            _out.appendFormat("\tcmp\tr2, #0\n\tbne\t%s\n", retry.cString());
            }
        else
            {
            _out.appendCString("\tldrh\tr1, [r0, #-2]\n\tadd\tr1, r1, #1\n\tstrh\tr1, [r0, #-2]\n");
            }
        _out.appendFormat("%s:\n", lbl.cString());
        }

    void emitRelease(Array* ops)
        {
        if (ops.count() == (u32)0)
            return;
        loadOperand((IROperand*)ops.get((u32)0), String.withCString("r0"));
        String* lbl = arcLabel();
        _out.appendCString("\tcmp\tr0, #0x10000\n");
        _out.appendFormat("\tblo\t%s\n", lbl.cString());
        if (_atomicArc)
            {
            // Same monitor loop, decrementing. "Was I the last reference?" uses
            // the value THIS iteration stored (r1 == 0), which only one thread
            // can produce; the barrier orders other threads' writes ahead of the
            // destructor's reads.
            String* retry = arcLabel();
            _out.appendFormat("\tsub\tr3, r0, #2\n%s:\n", retry.cString());
            _out.appendCString("\tldrexh\tr1, [r3]\n\tsub\tr1, r1, #1\n\tstrexh\tr2, r1, [r3]\n");
            _out.appendFormat("\tcmp\tr2, #0\n\tbne\t%s\n", retry.cString());
            _out.appendCString("\tdmb\tish\n");
            _out.appendFormat("\tcmp\tr1, #0\n\tbne\t%s\n", lbl.cString());
            }
        else
            {
            _out.appendCString("\tldrh\tr1, [r0, #-2]\n\tsubs\tr1, r1, #1\n\tstrh\tr1, [r0, #-2]\n");
            _out.appendFormat("\tbne\t%s\n", lbl.cString());
            }
        _out.appendCString("\tbl\t_xtc_dealloc\n");
        _out.appendFormat("%s:\n", lbl.cString());
        }

    // ELF `.L` labels are file-scoped, so the counter is module-wide rather
    // than per function.
    String* arcLabel(void)
        {
        String* s = String.withCString(".L_arc_");
        s.appendFormat("%ld", (i32)_arcLabel);
        _arcLabel = _arcLabel + (u32)1;
        return s;
        }

    // ── Terminators ──────────────────────────────────────────────────────
    // A native-va_list function pushed {r0-r3} on entry, so it drops those 16
    // bytes and returns through lr; every other function pops pc directly.
    void emitFrameReturn(void)
        {
        if (_frame > (u32)0)
            emitAlu(String.withCString("add"), String.withCString("sp"),
                    String.withCString("sp"), _frame,
                    String.withCString("r12"));
        if (_nativeVa)
            {
            _out.appendCString("\tpop\t{r4-r11, lr}\n\tadd\tsp, sp, #16\n\tbx\tlr\n");
            return;
            }
        _out.appendCString("\tpop\t{r4-r11, pc}\n");
        }

    void emitTerminator(IRInsn* t, IRBlock* blk)
        {
        String* op = t.op();
        Array* ops = t.ops();
        if (op.equals(String.withCString("Return")))
            {
            emitReturn(ops);
            return;
            }
        if (op.equals(String.withCString("Branch")))
            {
            if (ops.count() == (u32)0)
                return;
            IRBlock* dst = ((IROperand*)ops.get((u32)0)).blk();
            emitPhiEdge(blk, dst);
            _out.appendFormat("\tb\t%s\n", blockLabel(dst).cString());
            return;
            }
        if (op.equals(String.withCString("CondBranch")))
            {
            emitCondBranch(t, blk);
            return;
            }
        // A failed CHECKED downcast `(T*)p` lands here, and it IS reachable.
        // This used to fall out of the function, so the cast silently succeeded
        // with a mistyped pointer and the program exited 0 — a failed cast
        // looked like a clean run. Fixed in the original first, then here.
        // Use `(T* ?)p` when failure is a possibility rather than a bug.
        if (op.equals(String.withCString("Unreachable")))
            {
            _out.appendCString("\tudf\t#0\n");
            return;
            }
        // Anything else gets the original's placeholder, verbatim — including
        // its opcode NUMBER, which is the one place this port has to know the
        // enum rather than the spelling.
        _out.appendFormat("\t@ TODO terminator %ld\n", (i32)Arm9.opcodeNumber(op));
        emitFrameReturn();
        }

    void emitReturn(Array* ops)
        {
        IROperand* rv = (IROperand*)0;
        if (ops.count() >= (u32)1)
            {
            IROperand* o = (IROperand*)ops.get((u32)0);
            bool isMem = o.kind() == (u8)OPK_USE && o.val() != 0 && Arm9.isMemTy(o.val().ty());
            if (o.kind() != (u8)OPK_BLOCK && !isMem)
                rv = o;
            }
        if (rv != 0)
            {
            String* rvt = operandType(rv);
            if (Arm9.isAggTy(rvt) && returnsViaSret(_fn.ret()))
                {
                // sret: copy the aggregate from its slot to the saved result
                // pointer, and hand that pointer back in r0.
                emitSpAccess(String.withCString("ldr"), String.withCString("r1"), _sretSlot);
                blockCopyFromSlot(rv.val(), String.withCString("r1"),
                                  aggSize(Arm9.aggIndex(rvt)));
                _out.appendCString("\tmov\tr0, r1\n");
                }
            else if (Arm9.isF64(rvt) || Arm9.isI64(rvt))
                {
                // softfp: a double — and an i64 — come back in r0:r1, two words
                // from the slot. Without the i64 arm the scalar path below
                // loaded r0 alone and the caller read the callee's leftover r1
                // as the high half.
                i32 vs = rv.kind() == (u8)OPK_USE ? slotOf(rv.val()) : (i32)-1;
                u32 so = vs < (i32)0 ? (u32)0 : (u32)vs;
                emitSpAccess(String.withCString("ldr"), String.withCString("r0"), so);
                emitSpAccess(String.withCString("ldr"), String.withCString("r1"), so + (u32)4);
                }
            else
                {
                loadOperand(rv, String.withCString("r0"));
                // A narrow scalar return is canonicalised to the DECLARED
                // return type: that is the callee's half of the AAPCS contract,
                // and a caller comparing the raw bits depends on it.
                if (!Arm9.isAggTy(rvt))
                    canonicalise(String.withCString("r0"), _fn.ret());
                }
            }
        emitFrameReturn();
        }

    void emitCondBranch(IRInsn* t, IRBlock* blk)
        {
        Array* ops = t.ops();
        IROperand* cond = (IROperand*)0;
        IRBlock* tb = (IRBlock*)0;
        IRBlock* fb = (IRBlock*)0;
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)ops.get(i);
            if (o.kind() == (u8)OPK_BLOCK)
                {
                if (tb == 0)
                    tb = o.blk();
                else if (fb == 0)
                    fb = o.blk();
                }
            else if (cond == 0)
                cond = o;
            }
        // The phi copies belong to ONE edge each, so the false side is reached
        // by an inverted branch to a label of this block's own.
        String* flab = String.withCString(".L_");
        flab.append(_fn.name());
        flab.appendCString("_");
        flab.append(blk.name());
        flab.appendCString("_f");

        IRInsn* fcmp = (IRInsn*)0;
        if (cond != 0 && cond.kind() == (u8)OPK_USE && cond.val() != (IRValue*)0 && _fusedCmp != 0 && _fusedCmp.has(cond.val().pid()))
            {
            // The fused compare is the last instruction of this block.
            if (blk.insns().count() > (u32)0)
                {
                IRInsn* cand = (IRInsn*)blk.insns().get(blk.insns().count() - (u32)1);
                if (cand.res() != (IRValue*)0 && cand.res().pid() == cond.val().pid())
                    fcmp = cand;
                }
            }
        if (fcmp != (IRInsn*)0 && fcmp.ops().count() >= (u32)2)
            {
            loadOperand((IROperand*)fcmp.ops().get((u32)0), String.withCString("r0"));
            loadOperand((IROperand*)fcmp.ops().get((u32)1), String.withCString("r1"));
            _out.appendCString("\tcmp\tr0, r1\n");
            _out.appendFormat("\tb%s\t%s\n",
                              Arm9.invCond(Arm9.condForICmp(fcmp.pred())).cString(), flab.cString());
            }
        else
            {
            if (cond != 0)
                loadCondition(cond, String.withCString("r0"), String.withCString("r1"));
            _out.appendCString("\tcmp\tr0, #0\n");
            _out.appendFormat("\tbeq\t%s\n", flab.cString());
            }
        if (tb != 0)
            {
            emitPhiEdge(blk, tb);
            _out.appendFormat("\tb\t%s\n", blockLabel(tb).cString());
            }
        _out.appendFormat("%s:\n", flab.cString());
        if (fb != 0)
            {
            emitPhiEdge(blk, fb);
            _out.appendFormat("\tb\t%s\n", blockLabel(fb).cString());
            }
        }

    // The numeric opcode the original's placeholder prints. Only the
    // terminators that reach the default arm need one.
    static i32 opcodeNumber(String* op)
        {
        if (op.equals(String.withCString("Unreachable")))
            return (i32)61;
        return (i32)0;
        }

    // The values a phi takes on THIS edge, copied into the phi's slot before
    // the branch.
    //
    // These are a PARALLEL assignment. Emitting them in order is wrong when one
    // copy's source is a sibling's destination — after an inner loop unrolls,
    // `v0 <- lc4` sits next to `lc4 <- lc4+1`, and doing lc4 first hands v0 the
    // post-increment value. So a copy goes only when no pending copy still
    // reads its destination; a residual true cycle (a swap) is rare and is
    // broken by taking the first pending one.
    void emitPhiEdge(IRBlock* from, IRBlock* to)
        {
        if (to == 0)
            return;
        Array* dests = new Array();
        Array* srcs = new Array();
        for (u32 i = (u32)0; i < to.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)to.phis().get(i);
            if (phi.res() == 0)
                continue;
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != from)
                    continue;
                IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                if (vectorPhiCopy(phi.res(), vo))
                    {
                    k = phi.ops().count();
                    continue;
                    }
                if (widePhiCopy(phi.res(), vo))
                    {
                    k = phi.ops().count();
                    continue;
                    }
                if (aggregatePhiCopy(phi.res(), vo))
                    {
                    k = phi.ops().count();
                    continue;
                    }
                dests.add((Object*)phi.res());
                srcs.add((Object*)vo);
                k = phi.ops().count();
                }
            }
        emitParallelCopies(dests, srcs);
        }

    // A VECTOR phi lives in a q-register, not a slot — never route it through
    // r0. Coalesced (same q) it is a no-op; but a SHARED preheader incoming —
    // one init splat feeding several accumulator phis — coalesces with only
    // ONE of them, so the others need a q-to-q move. `vorr qD, qS, qS` is the
    // NEON register move, and the sources all being the one shared register
    // means in-order emission cannot lose a copy.
    bool vectorPhiCopy(IRValue* dst, IROperand* vo)
        {
        if (!Arm9.isVecTy(dst.ty()))
            return false;
        if (_vecReg == (Map*)0)
            return true;
        Object* dq = _vecReg.get((Hashable*)dst);
        Object* sq = (vo.kind() == (u8)OPK_USE && vo.val() != (IRValue*)0)
                         ? _vecReg.get((Hashable*)vo.val())
                         : (Object*)0;
        if (dq != (Object*)0 && sq != (Object*)0 && ((Number*)dq).asU32() != ((Number*)sq).asU32())
            _out.appendFormat("\tvorr\tq%lu, q%lu, q%lu\n",
                              ((Number*)dq).asU32(), ((Number*)sq).asU32(),
                              ((Number*)sq).asU32());
        return true;
        }

    // An AGGREGATE phi is a slot-to-slot BLOCK COPY. Routing a struct through
    // r0 would copy its first four bytes and leave the rest as whatever the
    // frame held — which on this target is stack poison, so an 8-byte struct
    // through a ternary came back with garbage in its tail.
    // An i64 phi is EIGHT bytes in a slot, and the one-word path leaves the
    // high half holding whatever the frame did — on this target that is stack
    // poison, so a `u64` loop variable arriving through a phi had a non-zero
    // high word and `v > 0` was permanently true. String.withU64 spun forever.
    //
    // A DOUBLE is the same eight bytes in the same kind of slot, and lost its
    // value outright the same way.
    bool widePhiCopy(IRValue* dst, IROperand* vo)
        {
        if (!Arm9.isI64(dst.ty()) && !Arm9.isF64(dst.ty()))
            return false;
        i32 ds = slotOf(dst);
        if (ds < (i32)0)
            return false;
        // An immediate source, integer or float: the bits go down directly.
        // arm9 is LITTLE-endian, so the low word is at the lower address.
        if (vo.kind() == (u8)OPK_IMMI)
            {
            emitMovImm((i32)vo.imm(), String.withCString("r0"));
            emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds);
            emitMovImm((i32)(vo.imm() >> (i64)32), String.withCString("r0"));
            emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds + (u32)4);
            return true;
            }
        if (vo.kind() == (u8)OPK_IMMF)
            {
            String* hx = vo.fpHex();
            emitMovImm((i32)Arm9.hexWord(hx, (u32)8), String.withCString("r0"));
            emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds);
            emitMovImm((i32)Arm9.hexWord(hx, (u32)0), String.withCString("r0"));
            emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds + (u32)4);
            return true;
            }
        if (vo.kind() != (u8)OPK_USE)
            return false;
        i32 ss = slotOf(vo.val());
        if (ss < (i32)0)
            return false;
        emitSpAccess(String.withCString("ldr"), String.withCString("r0"), (u32)ss);
        emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds);
        emitSpAccess(String.withCString("ldr"), String.withCString("r0"), (u32)ss + (u32)4);
        emitSpAccess(String.withCString("str"), String.withCString("r0"), (u32)ds + (u32)4);
        return true;
        }

    bool aggregatePhiCopy(IRValue* dst, IROperand* vo)
        {
        if (!Arm9.isAggTy(dst.ty()) || vo.kind() != (u8)OPK_USE)
            return false;
        i32 ds = slotOf(dst);
        if (ds < (i32)0)
            return false;
        // r1 = sp + slot, built with movw/movt so a large frame offset cannot
        // overflow the add's rotated immediate.
        _out.appendFormat("\tmovw\tr1, #%lu\n", (u32)ds & (u32)$FFFF);
        _out.appendFormat("\tmovt\tr1, #%lu\n", ((u32)ds >> 16) & (u32)$FFFF);
        _out.appendCString("\tadd\tr1, r1, sp\n");
        blockCopyFromSlot(vo.val(), String.withCString("r1"),
                          aggSize(Arm9.aggIndex(dst.ty())));
        return true;
        }

    void emitParallelCopies(Array* dests, Array* srcs)
        {
        u32 n = dests.count();
        if (n == (u32)0)
            return;
        Array* done = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            done.add((Object*)Number.with((u32)0));
        u32 remaining = n;
        while (remaining > (u32)0)
            {
            i32 pick = (i32)-1;
            for (u32 i = (u32)0; i < n && pick < (i32)0; i = i + (u32)1)
                {
                if (((Number*)done.get(i)).asU32() != (u32)0)
                    continue;
                IRValue* d = (IRValue*)dests.get(i);
                bool blocked = false;
                for (u32 o = (u32)0; o < n && !blocked; o = o + (u32)1)
                    {
                    if (o == i || ((Number*)done.get(o)).asU32() != (u32)0)
                        continue;
                    IROperand* so = (IROperand*)srcs.get(o);
                    if (so.kind() == (u8)OPK_USE && so.val() == d)
                        blocked = true;
                    }
                if (!blocked)
                    pick = (i32)i;
                }
            if (pick >= (i32)0)
                {
                loadOperand((IROperand*)srcs.get((u32)pick), String.withCString("r0"));
                storeResult((IRValue*)dests.get((u32)pick), String.withCString("r0"));
                done.set((u32)pick, (Object*)Number.with((u32)1));
                remaining = remaining - (u32)1;
                continue;
                }
            // Residual cycle: every pending copy's DEST is another copy's SOURCE,
            // so no single-step order is safe — a swap `%a<-%b, %b<-%a` copied in
            // place loses one value (bug 199: loop-swapped class-pointer locals
            // came back unchanged). arm9 slots are sp-relative so a stack shuffle
            // would shift every [sp,#off]; instead read EVERY source into its own
            // scratch register (r0/r2/r3 — never home registers, homes are
            // r4-r11), then write every dest. Only 32-bit scalars reach here
            // (wide/agg/vector phis are copied inline), so one GP register per
            // member suffices. A cycle wider than the 3-register pool falls back
            // to the in-place single step, no worse than pre-fix.
            if (remaining > (u32)3)
                {
                u32 fb = (u32)$FFFF_FFFF;
                for (u32 i = (u32)0; i < n && fb == (u32)$FFFF_FFFF; i = i + (u32)1)
                    if (((Number*)done.get(i)).asU32() == (u32)0)
                        fb = i;
                loadOperand((IROperand*)srcs.get(fb), String.withCString("r0"));
                storeResult((IRValue*)dests.get(fb), String.withCString("r0"));
                done.set(fb, (Object*)Number.with((u32)1));
                remaining = remaining - (u32)1;
                continue;
                }
            Array* pool = new Array();
            pool.add((Object*)String.withCString("r0"));
            pool.add((Object*)String.withCString("r2"));
            pool.add((Object*)String.withCString("r3"));
            Array* cyc = new Array();
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                if (((Number*)done.get(i)).asU32() == (u32)0)
                    cyc.add((Object*)Number.with(i));
            for (u32 k = (u32)0; k < cyc.count(); k = k + (u32)1)
                loadOperand((IROperand*)srcs.get(((Number*)cyc.get(k)).asU32()),
                            (String*)pool.get(k));
            for (u32 k = (u32)0; k < cyc.count(); k = k + (u32)1)
                {
                u32 idx = ((Number*)cyc.get(k)).asU32();
                storeResult((IRValue*)dests.get(idx), (String*)pool.get(k));
                done.set(idx, (Object*)Number.with((u32)1));
                remaining = remaining - (u32)1;
                }
            }
        }

    // ── NEON (aarch32 Advanced SIMD) ─────────────────────────────────────
    //
    // The vectoriser's output, mirroring the arm64 lowering onto q8..q15. The
    // pool cannot grow: q0-q7 alias the scalar VFP registers d0-d15, which the
    // float path already owns.
    //
    // These were missing entirely while the profile turned vectorisation ON for
    // arm9, so `-A arm9 -O2` refused any vectorisable loop with "unsupported:
    // VLoad VStore". a9-diff runs at -O0, where the vectoriser never runs, so
    // nothing saw it until `--emit-lib` (which keeps every function) was run
    // through the shipped driver.
    Map* _vecReg;     // vector value -> q index
    Map* _vecClass;   // vector value -> its coalescing class
    Map* _postIncEA;  // pointer value -> the ElementAddr folded into `!`
    BitSet* _vecSkip; // …and the advance instructions that therefore vanish
    Map* _defOf;      // value -> the instruction that defines it

    static bool isVecTy(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Vec("));
        }

    // The lane type a Vec(T) carries.
    static String* laneOf(String* t)
        {
        if (!Arm9.isVecTy(t))
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

    // Data-type suffix for size-agnostic integer ops (add/sub/mul) or float:
    // `.i8/.i16/.i32` or `.f32` (2's-complement add/sub/mul are sign-independent).
    String* neonI(String* lane)
        {
        if (lane != (String*)0 && Arm9.isFloatTy(lane))
            return String.withCString("f32");
        u32 w = lane == (String*)0 ? (u32)4 : fieldWidth(lane);
        if (w == (u32)1)
            return String.withCString("i8");
        if (w == (u32)2)
            return String.withCString("i16");
        return String.withCString("i32");
        }

    // Sign-aware suffix for max/min/compare/widen: u8/s8/u16/s16/u32/s32.
    String* neonU(String* lane)
        {
        u32 w = lane == (String*)0 ? (u32)4 : fieldWidth(lane);
        String* o = String.withCString(
            lane != (String*)0 && Arm9.isSignedTy(lane) ? "s" : "u");
        if (w == (u32)1)
            o.appendCString("8");
        else if (w == (u32)2)
            o.appendCString("16");
        else
            o.appendCString("32");
        return o;
        }

    // Element-size-only suffix for vld1/vst1/vdup: 8/16/32.
    String* neonSz(String* lane)
        {
        u32 w = lane == (String*)0 ? (u32)4 : fieldWidth(lane);
        if (w == (u32)1)
            return String.withCString("8");
        if (w == (u32)2)
            return String.withCString("16");
        return String.withCString("32");
        }

    // The q index assigned to a vector value. 8 is the allocator's backstop and
    // is only ever reached for a value the allocator never saw.
    u32 vq(IRValue* v)
        {
        if (_vecReg == (Map*)0 || v == (IRValue*)0)
            return (u32)8;
        Object* r = _vecReg.get((Hashable*)v);
        return r == (Object*)0 ? (u32)8 : ((Number*)r).asU32();
        }

    bool dispatchVector(IRInsn* n, String* op, Array* ops, IRValue* res)
        {
        if (op.equals(String.withCString("VLoad")))
            {
            emitVLoad(n, ops, res);
            return true;
            }
        if (op.equals(String.withCString("VStore")))
            {
            emitVStore(n, ops);
            return true;
            }
        if (op.equals(String.withCString("VSplat")))
            {
            emitVSplat(n, ops, res);
            return true;
            }
        if (op.equals(String.withCString("VAdd")) || op.equals(String.withCString("VSub")) || op.equals(String.withCString("VMul")) || op.equals(String.withCString("VAnd")) || op.equals(String.withCString("VOr")) || op.equals(String.withCString("VXor")))
            {
            emitVBin(op, ops, res);
            return true;
            }
        if (op.equals(String.withCString("VMax")) || op.equals(String.withCString("VMin")))
            {
            emitVMinMax(op, ops, res);
            return true;
            }
        if (op.equals(String.withCString("VAddLP")))
            {
            emitVAddLP(ops, res);
            return true;
            }
        if (op.equals(String.withCString("VICmp")))
            {
            emitVICmp(n, ops, res);
            return true;
            }
        if (op.equals(String.withCString("VReduceAdd")) || op.equals(String.withCString("VReduceMax")) || op.equals(String.withCString("VReduceMin")))
            {
            emitVReduce(op, ops, res);
            return true;
            }
        return false;
        }

    // The ElementAddr folded into this memory op's writeback, or null.
    IRInsn* postIncFor(IROperand* p)
        {
        if (_postIncEA == (Map*)0 || p.kind() != (u8)OPK_USE || p.val() == (IRValue*)0)
            return (IRInsn*)0;
        return (IRInsn*)_postIncEA.get((Hashable*)p.val());
        }

    void emitVLoad(IRInsn* n, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)1 || res == (IRValue*)0)
            {
            giveUp(n.op());
            return;
            }
        u32 q = vq(res);
        IROperand* p = (IROperand*)ops.get((u32)0);
        loadOperand(p, String.withCString("r0"));
        IRInsn* ea = postIncFor(p);
        _out.appendFormat("\tvld1.%s\t{d%lu, d%lu}, [r0]%s\n",
                          neonSz(Arm9.laneOf(res.ty())).cString(),
                          (u32)2 * q, (u32)2 * q + (u32)1,
                          ea != (IRInsn*)0 ? "!" : "");
        if (ea != (IRInsn*)0 && ea.res() != (IRValue*)0)
            storeResult(ea.res(), String.withCString("r0")); // the advanced pointer
        }

    void emitVStore(IRInsn* n, Array* ops)
        {
        if (ops.count() < (u32)2)
            {
            giveUp(n.op());
            return;
            }
        IROperand* v = (IROperand*)ops.get((u32)1);
        if (v.kind() != (u8)OPK_USE || v.val() == (IRValue*)0)
            {
            giveUp(n.op());
            return;
            }
        u32 q = vq(v.val());
        IROperand* p = (IROperand*)ops.get((u32)0);
        loadOperand(p, String.withCString("r0"));
        IRInsn* ea = postIncFor(p);
        _out.appendFormat("\tvst1.%s\t{d%lu, d%lu}, [r0]%s\n",
                          neonSz(Arm9.laneOf(v.val().ty())).cString(),
                          (u32)2 * q, (u32)2 * q + (u32)1,
                          ea != (IRInsn*)0 ? "!" : "");
        if (ea != (IRInsn*)0 && ea.res() != (IRValue*)0)
            storeResult(ea.res(), String.withCString("r0"));
        }

    void emitVSplat(IRInsn* n, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)1 || res == (IRValue*)0)
            {
            giveUp(n.op());
            return;
            }
        String* lane = Arm9.laneOf(res.ty());
        IROperand* src = (IROperand*)ops.get((u32)0);
        // Constant splat: materialise the immediate straight into r0 (movw/movt)
        // and vdup — skipping the naive Const→slot→ZExt→mask→slot→reload chain,
        // which is the dominant per-copy cost in vectorised loops.
        Array* c = new Array();
        if (traceConst(src, c))
            {
            u32 w = lane == (String*)0 ? (u32)4 : fieldWidth(lane);
            u32 mask = w == (u32)1 ? (u32)$FF : (w == (u32)2 ? (u32)$FFFF : (u32)$FFFF_FFFF);
            emitMovImm((i32)(((Number*)c.get((u32)0)).asU32() & mask), String.withCString("r0"));
            }
        else
            {
            loadOperand(src, String.withCString("r0"));
            }
        _out.appendFormat("\tvdup.%s\tq%lu, r0\n", neonSz(lane).cString(), vq(res));
        }

    // Trace an operand back to a compile-time constant through ZExt/SExt/
    // Trunc/Bitcast. The depth cap is the reference's: a cycle here would hang
    // the compiler rather than mis-compile, but neither is acceptable.
    bool traceConst(IROperand* op, Array* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out.add((Object*)Number.with((u32)op.imm()));
            return true;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return false;
        IRValue* v = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            IRInsn* def = _defOf == (Map*)0 ? (IRInsn*)0 : (IRInsn*)_defOf.get((Hashable*)v);
            if (def == (IRInsn*)0 || def.ops().count() < (u32)1)
                return false;
            IROperand* o0 = (IROperand*)def.ops().get((u32)0);
            if (def.op().equals(String.withCString("Const")))
                {
                if (o0.kind() != (u8)OPK_IMMI)
                    return false;
                out.add((Object*)Number.with((u32)o0.imm()));
                return true;
                }
            if ((def.op().equals(String.withCString("ZExt")) || def.op().equals(String.withCString("SExt")) || def.op().equals(String.withCString("Trunc")) || def.op().equals(String.withCString("Bitcast"))) && o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0)
                {
                v = o0.val();
                continue;
                }
            return false;
            }
        return false;
        }

    void emitVBin(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        IROperand* o0 = (IROperand*)ops.get((u32)0);
        IROperand* o1 = (IROperand*)ops.get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            {
            giveUp(op);
            return;
            }
        u32 a = vq(o0.val());
        u32 b = vq(o1.val());
        u32 d = vq(res);
        if (op.equals(String.withCString("VAnd")) || op.equals(String.withCString("VOr")) || op.equals(String.withCString("VXor")))
            {
            // 128-bit bitwise: no size suffix.
            string m = op.equals(String.withCString("VAnd")) ? "vand"
                                                             : (op.equals(String.withCString("VOr")) ? "vorr" : "veor");
            _out.appendFormat("\t%s\tq%lu, q%lu, q%lu\n", m, d, a, b);
            return;
            }
        string m = op.equals(String.withCString("VAdd")) ? "vadd"
                                                         : (op.equals(String.withCString("VSub")) ? "vsub" : "vmul");
        _out.appendFormat("\t%s.%s\tq%lu, q%lu, q%lu\n", m,
                          neonI(Arm9.laneOf(res.ty())).cString(), d, a, b);
        }

    void emitVMinMax(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        IROperand* o0 = (IROperand*)ops.get((u32)0);
        IROperand* o1 = (IROperand*)ops.get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            {
            giveUp(op);
            return;
            }
        _out.appendFormat("\t%s.%s\tq%lu, q%lu, q%lu\n",
                          op.equals(String.withCString("VMax")) ? "vmax" : "vmin",
                          neonU(Arm9.laneOf(res.ty())).cString(),
                          vq(res), vq(o0.val()), vq(o1.val()));
        }

    void emitVAddLP(Array* ops, IRValue* res)
        {
        String* op = String.withCString("VAddLP");
        if (ops.count() < (u32)1 || res == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        IROperand* o0 = (IROperand*)ops.get((u32)0);
        if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        // The suffix is the SOURCE lane width — vpaddl widens ×2, so reading it
        // off the result would name the wrong element size.
        _out.appendFormat("\tvpaddl.%s\tq%lu, q%lu\n",
                          neonU(Arm9.laneOf(o0.val().ty())).cString(),
                          vq(res), vq(o0.val()));
        }

    void emitVICmp(IRInsn* n, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)2 || res == (IRValue*)0)
            {
            giveUp(n.op());
            return;
            }
        IROperand* o0 = (IROperand*)ops.get((u32)0);
        IROperand* o1 = (IROperand*)ops.get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            {
            giveUp(n.op());
            return;
            }
        // `<` and `<=` reuse `>` and `>=` with the operands swapped; NE is EQ
        // with the mask inverted.
        String* p = n.pred();
        String* cm = (String*)0;
        bool swap = false;
        bool invert = false;
        if (p != (String*)0)
            {
            if (p.equals(String.withCString("UGT")) || p.equals(String.withCString("SGT")))
                cm = String.withCString("vcgt");
            else if (p.equals(String.withCString("UGE")) || p.equals(String.withCString("SGE")))
                cm = String.withCString("vcge");
            else if (p.equals(String.withCString("ULT")) || p.equals(String.withCString("SLT")))
                {
                cm = String.withCString("vcgt");
                swap = true;
                }
            else if (p.equals(String.withCString("ULE")) || p.equals(String.withCString("SLE")))
                {
                cm = String.withCString("vcge");
                swap = true;
                }
            else if (p.equals(String.withCString("EQ")))
                cm = String.withCString("vceq");
            else if (p.equals(String.withCString("NE")))
                {
                cm = String.withCString("vceq");
                invert = true;
                }
            }
        if (cm == (String*)0)
            {
            giveUp(String.withCString("VICmp:pred"));
            return;
            }
        u32 a = vq(o0.val());
        u32 b = vq(o1.val());
        u32 d = vq(res);
        // vceq takes the size-only suffix (i8/i16/i32); vcgt/vcge take sign+size.
        String* lane = Arm9.laneOf(res.ty());
        String* suf = cm.equals(String.withCString("vceq")) ? neonI(lane) : neonU(lane);
        _out.appendFormat("\t%s.%s\tq%lu, q%lu, q%lu\n", cm.cString(), suf.cString(),
                          d, swap ? b : a, swap ? a : b);
        if (invert)
            _out.appendFormat("\tvmvn\tq%lu, q%lu\n", d, d);
        }

    // Horizontal add / max / min of 4×i32 down to a GP scalar.
    void emitVReduce(String* op, Array* ops, IRValue* res)
        {
        if (ops.count() < (u32)1 || res == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        IROperand* o0 = (IROperand*)ops.get((u32)0);
        if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
            {
            giveUp(op);
            return;
            }
        u32 q = vq(o0.val());
        u32 dl = (u32)2 * q;
        u32 dh = dl + (u32)1;
        if (op.equals(String.withCString("VReduceAdd")))
            {
            _out.appendFormat("\tvadd.i32\td%lu, d%lu, d%lu\n", dl, dl, dh);
            _out.appendFormat("\tvpadd.i32\td%lu, d%lu, d%lu\n", dl, dl, dl);
            }
        else
            {
            bool mx = op.equals(String.withCString("VReduceMax"));
            String* su = neonU(res.ty());
            _out.appendFormat("\t%s.%s\td%lu, d%lu, d%lu\n", mx ? "vmax" : "vmin",
                              su.cString(), dl, dl, dh);
            _out.appendFormat("\t%s.%s\td%lu, d%lu, d%lu\n", mx ? "vpmax" : "vpmin",
                              su.cString(), dl, dl, dl);
            }
        _out.appendFormat("\tvmov.32\tr0, d%lu[0]\n", dl);
        storeResult(res, String.withCString("r0"));
        }

    // ── vector register allocation ───────────────────────────────────────
    //
    // Coalesce through phis, live intervals over a linear position, back-edge
    // extension, then a linear scan over q8..q15. The same shape the arm64
    // allocator uses, and for the same reason: a loop-INVARIANT splat
    // materialised in the preheader is read every iteration and must stay live
    // across the back edge, or a later in-loop op takes its register and
    // corrupts it next time round.
    void allocateVectorRegisters(IRFunc* fn)
        {
        _vecReg = new Map();
        _vecClass = new Map();
        Array* vecVals = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            collectVecs(vecVals, bb.phis());
            collectVecs(vecVals, bb.insns());
            }
        if (vecVals.count() == (u32)0)
            return;

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() == (IRValue*)0 || !Arm9.isVecTy(ph.res().ty()))
                    continue;
                for (u32 k = (u32)0; k < ph.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)ph.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        _vecClass.set((Hashable*)o.val(), (Object*)ph.res());
                    }
                }
            }

        Array* classes = new Array();
        Map* lo = new Map();
        Map* hi = new Map();
        Array* blkStart = new Array();
        Array* blkEnd = new Array();
        i32 pos = (i32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            blkStart.add((Object*)Number.withI32(pos));
            pos = vTouchList(bb.phis(), vecVals, classes, lo, hi, pos);
            pos = vTouchList(bb.insns(), vecVals, classes, lo, hi, pos);
            if (bb.term() != (IRInsn*)0)
                pos = vTouchInsn(bb.term(), vecVals, classes, lo, hi, pos);
            blkEnd.add((Object*)Number.withI32(pos > (i32)0 ? pos - (i32)1 : (i32)0));
            }

        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(bi)).term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                i32 tgt = vBlockIndexOf(fn, o.blk());
                if (tgt < (i32)0 || (u32)tgt > bi)
                    continue; // a forward edge
                i32 loopStart = ((Number*)blkStart.get((u32)tgt)).asI32();
                i32 loopEnd = ((Number*)blkEnd.get(bi)).asI32();
                for (u32 c = (u32)0; c < classes.count(); c = c + (u32)1)
                    {
                    IRValue* cls = (IRValue*)classes.get(c);
                    i32 l = ((Number*)lo.get((Hashable*)cls)).asI32();
                    i32 h = ((Number*)hi.get((Hashable*)cls)).asI32();
                    if (l < loopStart && h >= loopStart && h <= loopEnd)
                        hi.set((Hashable*)cls, (Object*)Number.withI32(loopEnd));
                    }
                }
            }

        vSortByKey(classes, lo);
        Array* freePool = new Array();
        for (u32 r = (u32)8; r <= (u32)15; r = r + (u32)1)
            freePool.add((Object*)Number.with(r));
        Array* active = new Array();
        Map* regOf = new Map();
        for (u32 c = (u32)0; c < classes.count(); c = c + (u32)1)
            {
            IRValue* cls = (IRValue*)classes.get(c);
            i32 start = ((Number*)lo.get((Hashable*)cls)).asI32();
            Array* still = new Array();
            for (u32 a = (u32)0; a < active.count(); a = a + (u32)1)
                {
                IRValue* av = (IRValue*)active.get(a);
                if (((Number*)hi.get((Hashable*)av)).asI32() < start)
                    freePool.add((Object*)regOf.get((Hashable*)av));
                else
                    still.add((Object*)av);
                }
            active = still;
            // Exhaustion is a HARD error. The pool cannot grow (q0-q7 alias the
            // scalar VFP d0-d15), and a silent fallback to one fixed register
            // reuses a LIVE one — a miscompile, not degraded code (#1198).
            if (freePool.count() == (u32)0)
                {
                Stdio.printf("xcc-cg-arm9: error: vector register pressure exceeded "
                             "the 8-register NEON pool (q8-q15) in '%s'\n",
                             fn.name().cString());
                Process.exit((i32)1);
                }
            Object* reg = freePool.get(freePool.count() - (u32)1);
            freePool.removeAt(freePool.count() - (u32)1);
            regOf.set((Hashable*)cls, reg);
            active.add((Object*)cls);
            vSortByKey(active, hi);
            }
        for (u32 i = (u32)0; i < vecVals.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)vecVals.get(i);
            Object* r = regOf.get((Hashable*)classOfVec(v));
            if (r == (Object*)0)
                continue;
            _vecReg.set((Hashable*)v, r);
            }
        }

    IRValue* classOfVec(IRValue* v)
        {
        Object* c = _vecClass.get((Hashable*)v);
        return c == (Object*)0 ? v : (IRValue*)c;
        }

    static void collectVecs(Array* into, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() != (IRValue*)0 && Arm9.isVecTy(n.res().ty()) && !Arm9.vHasVal(into, n.res()))
                into.add((Object*)n.res());
            }
        }

    static bool vHasVal(Array* a, IRValue* v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v)
                return true;
        return false;
        }

    static i32 vBlockIndexOf(IRFunc* fn, IRBlock* b)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b)
                return (i32)i;
        return (i32)-1;
        }

    i32 vTouchList(Array* list, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            pos = vTouchInsn((IRInsn*)list.get(i), vecVals, classes, lo, hi, pos);
        return pos;
        }

    i32 vTouchInsn(IRInsn* n, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        if (n.res() != (IRValue*)0)
            vTouch(n.res(), vecVals, classes, lo, hi, pos);
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                vTouch(o.val(), vecVals, classes, lo, hi, pos);
            }
        return pos + (i32)1;
        }

    void vTouch(IRValue* v, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        if (!Arm9.vHasVal(vecVals, v))
            return;
        IRValue* cls = classOfVec(v);
        Object* l = lo.get((Hashable*)cls);
        if (l == (Object*)0)
            {
            classes.add((Object*)cls);
            lo.set((Hashable*)cls, (Object*)Number.withI32(pos));
            hi.set((Hashable*)cls, (Object*)Number.withI32(pos));
            return;
            }
        if (pos < ((Number*)l).asI32())
            lo.set((Hashable*)cls, (Object*)Number.withI32(pos));
        if (pos > ((Number*)hi.get((Hashable*)cls)).asI32())
            hi.set((Hashable*)cls, (Object*)Number.withI32(pos));
        }

    // Insertion sort on the interval endpoint. Stable, and these arrays are a
    // handful of entries.
    static void vSortByKey(Array* a, Map* key)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* cur = a.get(i);
            i32 ck = ((Number*)key.get((Hashable*)(IRValue*)cur)).asI32();
            u32 j = i;
            while (j > (u32)0 && ((Number*)key.get((Hashable*)(IRValue*)a.get(j - (u32)1))).asI32() > ck)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, cur);
            }
        }

    // ── post-increment addressing ────────────────────────────────────────
    //
    // `vld1 {…}, [r0]!` advances the pointer for free. An ElementAddr that adds
    // exactly 16 bytes to a pointer whose ONLY memory reader is one vector op
    // in the same block, and whose result nothing in that block reads, folds
    // into that op's writeback and the separate `add` disappears.
    //
    // Every condition is load-bearing: two readers and the pointer would be
    // advanced twice; an in-block reader of the advanced value would see it
    // before the memory op ran.
    // value -> defining instruction, for the constant trace a VSplat does.
    void computeDefMap(void)
        {
        _defOf = new Map();
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n.res() != (IRValue*)0)
                    _defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        }

    void computePostIncEA(void)
        {
        _vecSkip = BitSet.withCapacity(_fn.byId().count() + (u32)1);
        _postIncEA = new Map();
        Array* users = new Array();
        for (u32 i = (u32)0; i < _fn.byId().count() + (u32)1; i = i + (u32)1)
            users.add((Object*)new Array());
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            noteUsers((IRBlock*)_fn.blocks().get(b), users);

        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* ea = (IRInsn*)blk.insns().get(i);
                if (!ea.op().equals(String.withCString("ElementAddr")))
                    continue;
                if (ea.ops().count() < (u32)2 || ea.res() == (IRValue*)0)
                    continue;
                IROperand* base = (IROperand*)ea.ops().get((u32)0);
                IROperand* idx = (IROperand*)ea.ops().get((u32)1);
                if (idx.kind() != (u8)OPK_IMMI)
                    continue;
                if (base.kind() != (u8)OPK_USE || base.val() == (IRValue*)0)
                    continue;
                u32 es = fieldWidth(pointeeOfOperand(base));
                if (es == (u32)0)
                    es = (u32)1;
                if ((i64)es * idx.imm() != (i64)16)
                    continue;
                if (base.val().pid() >= users.count())
                    continue;
                // Exactly one memory op is addressed by the base, in this block.
                Array* bu = (Array*)users.get(base.val().pid());
                IRInsn* memOp = (IRInsn*)0;
                u32 nAddr = (u32)0;
                for (u32 k = (u32)0; k < bu.count(); k = k + (u32)1)
                    {
                    IRInsn* u = (IRInsn*)bu.get(k);
                    if (!u.op().equals(String.withCString("VLoad")) && !u.op().equals(String.withCString("VStore")))
                        continue;
                    if (u.ops().count() < (u32)1)
                        continue;
                    IROperand* a0 = (IROperand*)u.ops().get((u32)0);
                    if (a0.kind() != (u8)OPK_USE || a0.val() != base.val())
                        continue;
                    nAddr = nAddr + (u32)1;
                    memOp = u;
                    }
                if (nAddr != (u32)1 || !Arm9.blockHas(blk, memOp))
                    continue;
                // The advanced pointer must not be read within this block.
                bool safe = true;
                if (ea.res().pid() < users.count())
                    {
                    Array* au = (Array*)users.get(ea.res().pid());
                    for (u32 k = (u32)0; k < au.count() && safe; k = k + (u32)1)
                        {
                        IRInsn* u = (IRInsn*)au.get(k);
                        if (!u.op().equals(String.withCString("Phi")) && Arm9.blockHas(blk, u))
                            safe = false;
                        }
                    }
                if (!safe)
                    continue;
                _postIncEA.set((Hashable*)base.val(), (Object*)ea);
                _vecSkip.add(ea.res().pid()); // the advance `add` disappears
                }
            }
        }

    static bool blockHas(IRBlock* blk, IRInsn* n)
        {
        if (n == (IRInsn*)0)
            return false;
        for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
            if ((IRInsn*)blk.insns().get(i) == n)
                return true;
        return false;
        }

    // A shape this slice does not emit yet. Loud, and named — a backend that
    // quietly skipped an instruction would produce code that assembles, runs,
    // and is wrong. Every distinct opcode is collected, not just the first,
    // because the list is the work queue.
    void giveUp(String* op)
        {
        if (_missing == 0)
            _missing = new Array();
        for (u32 i = (u32)0; i < _missing.count(); i = i + (u32)1)
            if (((String*)_missing.get(i)).equals(op))
                return;
        _missing.add((Object*)op);
        if (_failed)
            return;
        _failed = true;
        _why = String.withString(op);
        }

    Array* missing(void)
        {
        return _missing;
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }
    }
