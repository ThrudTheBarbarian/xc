// X86_64.xc — the IR, as x86-64 assembly (System V and Win64).
// =========================================================================
//
// self-hosting M16. The port of XTX86_64Backend. Fourth back end after the
// A9's (M9), the host's (M14) and the Atari ST's (M15), and the one that
// covers TWO targets: the same instruction selection serves System V AMD64
// (Linux, `-A x86_64`) and Win64 (`-A win64`), which differ only in the
// calling convention — four integer argument registers rather than six, one
// positional file shared by integers and floats, a mandatory 32-byte shadow
// space below every call's stack arguments, and a hidden sret pointer in rcx.
//
// The oracle is `xtcg-x86_64 -O0` (and `xtcg-win64 -O0`) over the same IR,
// byte for byte; `selfhost/tools/x86-diff.sh` is the harness.
//
// Intel syntax, so the musl cross-clang assembler and ld.lld turn the .s into
// a static ELF. That makes one thing this port has to get right that no
// earlier one did: a symbol whose name collides with a REGISTER or an operand
// keyword has to be renamed, because in Intel syntax a bare `ax` is a register
// and not a label.
//
// An opcode this slice does not emit yet is recorded BY NAME and the whole file
// refused (exit 3). A back end that quietly skipped an instruction would emit
// assembly that assembles cleanly and computes the wrong thing, which is the
// one failure this harness exists to prevent.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Process.xc"
#import "Ir.xc"
#import "Homing.xc"

class X86_64
    {
    IRModule* _m;
    // Thread-safe ARC (private:docs/Design/threading.md §4.1): a LOCK-prefixed refcount
    // update, on exactly when the module spawns a thread.
    bool _atomicArc;
    // -fthread-safe-arc / -fno-thread-safe-arc: 1 forces atomic refcounts, 0
    // forces plain ones, -1 (the default) leaves the per-module decision above.
    i32 _arcOverride;
    IRFunc* _fn;
    String* _out;
    bool _win64; // the Win64 ABI rather than System V
    bool _failed;
    String* _why;
    Array* _missing;

    void init(void)
        {
        _out = new String();
        _missing = new Array();
        _failed = false;
        _arcOverride = (i32)-1;
        _win64 = false;
        }

    void setWin64(bool v)
        {
        _win64 = v;
        }

    void setThreadSafeArcOverride(i32 mode)
        {
        _arcOverride = mode;
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

    // ── Symbol names ─────────────────────────────────────────────────────
    //
    // In Intel syntax a bare `ax`, `si` or `r12` IS a register, and `byte` or
    // `ptr` is an operand keyword — so a program symbol spelled like one has to
    // be renamed, or the assembler reads the label as an instruction operand.
    // The suffix is `$x`, which no source identifier can produce.
    Array* _reservedNames;

    void buildReserved(void)
        {
        if (_reservedNames != (Array*)0)
            return;
        _reservedNames = new Array();
        addWords("flags eflags rflags ip eip rip cs ds es fs gs ss st");
        addWords("byte word dword qword xmmword ptr offset short near far");
        addWords("al ah ax eax rax bl bh bx ebx rbx cl ch cx ecx rcx dl dh dx edx rdx");
        addWords("si esi rsi sil di edi rdi dil sp esp rsp spl bp ebp rbp bpl");
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            String* base = String.withCString("r");
            base.appendFormat("%lu", i);
            _reservedNames.add((Object*)base);
            addSuffixed(base, "d");
            addSuffixed(base, "w");
            addSuffixed(base, "b");
            String* x = String.withCString("xmm");
            x.appendFormat("%lu", i);
            _reservedNames.add((Object*)x);
            }
        }

    void addSuffixed(String* base, string sfx)
        {
        String* s = String.withCString(base.cString());
        s.appendCString(sfx);
        _reservedNames.add((Object*)s);
        }

    void addWords(string list)
        {
        Array* parts = String.withCString(list).splitOnByte((u8)' ');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            _reservedNames.add(parts.get(i));
        }

    String* safeSym(String* n)
        {
        if (n == (String*)0 || n.byteLength() == (u32)0)
            return n;
        buildReserved();
        String* lower = String.withCString("");
        for (u32 i = (u32)0; i < n.byteLength(); i = i + (u32)1)
            {
            u8 c = n.byteAt(i);
            lower.appendByte(c >= (u8)'A' && c <= (u8)'Z' ? (u8)(c + (u8)32) : c);
            }
        for (u32 i = (u32)0; i < _reservedNames.count(); i = i + (u32)1)
            if (((String*)_reservedNames.get(i)).equals(lower))
                {
                String* o = String.withCString(n.cString());
                o.appendCString("$x");
                return o;
                }
        return n;
        }

    // ── Type sizing, x86-64 native ───────────────────────────────────────
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

    static bool isSignedTy(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("I32"));
        }

    // The IR's own width for a scalar leaf.
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
        // A vector is 128 bits — one xmm register — and the reference's
        // XTIRType.byteWidth says so. This table had no row for it, so a
        // Vec(U8) fell to 0, took the 8-byte minimum slot, and every value
        // after it in a vectorised function sat 8 bytes higher than the
        // reference's: 153 files at -O3, all differing by 134 lines, all one
        // `Data$withBytes` (bug 090). A 16-byte value in an 8-byte slot is
        // also a corruption waiting for the first spill.
        if (t.hasPrefix(String.withCString("Vec(")))
            return (u32)16;
        return (u32)0;
        }

    // The width a branch or select condition is tested at: 8 for a pointer or
    // a 64-bit integer, else 4. A condition is true when ANY of its bits is
    // set, so `test eax, eax` read an i64 of 1 << 32, or a pointer whose low
    // 32 bits are zero, as false (bug 293).
    static u32 condWidth(IROperand* op)
        {
        if (op.kind() == (u8)OPK_USE)
            return (op.val() != (IRValue*)0 && widthOfValue(op.val()) >= (u32)8) ? (u32)8 : (u32)4;
        if (op.kind() == (u8)OPK_IMMI && op.ty() != (String*)0)
            return (isPtrTy(op.ty()) || irWidth(op.ty()) >= (u32)8) ? (u32)8 : (u32)4;
        return (u32)4;
        }

    // The width a value loads and stores at: its own, clamped to 1..8. A
    // pointer's IR width is 0 here, so the default of 8 covers it.
    static u32 widthOfValue(IRValue* v)
        {
        if (v == (IRValue*)0)
            return (u32)8;
        u32 w = irWidth(v.ty());
        if (w == (u32)0)
            w = (u32)8;
        if (w > (u32)8)
            w = (u32)8;
        return w;
        }

    // The width THIS target lays a FIELD out as. The shared layout sizes fields
    // with the front end's widths, where a pointer is 2 bytes; storing a 64-bit
    // host pointer into a 2-byte ivar truncates it and clobbers the next field.
    // So the back end owns its own widths — the other half of the type-width
    // invariant.
    u32 fieldWidth(String* t)
        {
        if (t == (String*)0)
            return (u32)0;
        if (isPtrTy(t))
            return (u32)8;
        if (isAggTy(t))
            return aggSize(layoutOf(t));
        if (isMemTy(t) || t.equals(String.withCString("Void")))
            return (u32)0;
        return irWidth(t);
        }

    u32 aggSize(IRLayout* l)
        {
        if (l == (IRLayout*)0)
            return (u32)0;
        u32 total = (u32)0;
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            total = total + fieldWidth(l.typeAt(i));
        // Never below the declared size: a field-less byte buffer carries its
        // count there and has nothing to sum.
        if (total < l.size())
            total = l.size();
        return total;
        }

    // The RECORDED layout offset (blewit #5): the front end lays fields out
    // once — naturally aligned per target — and every backend reads the same
    // offsets. Widths still size the loads/stores; they no longer place fields.
    u32 fieldOffset(IRLayout* l, u32 idx)
        {
        if (l == (IRLayout*)0 || idx >= l.fieldCount())
            return aggSize(l);
        return l.offsetAt(idx);
        }

    // A value's frame footprint: its full native size — an aggregate gets its
    // whole extent, so AddrOf of a pinned local addresses real storage —
    // rounded up to 8.
    u32 slotSizeOf(IRValue* v)
        {
        String* t = v.ty();
        u32 w = isAggTy(t) ? aggSize(layoutOf(t)) : irWidth(t);
        if (w < (u32)8)
            w = (u32)8;
        return (w + (u32)7) & ~(u32)7;
        }

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

    // ── Register naming ──────────────────────────────────────────────────
    //
    // The scratch bases a/c/d, viewed at a byte width.
    static String* reg(u8 base, u32 w)
        {
        if (base == (u8)'a')
            return String.withCString(w == (u32)1 ? "al" : (w == (u32)2 ? "ax" : (w == (u32)4 ? "eax" : "rax")));
        if (base == (u8)'c')
            return String.withCString(w == (u32)1 ? "cl" : (w == (u32)2 ? "cx" : (w == (u32)4 ? "ecx" : "rcx")));
        if (base == (u8)'d')
            return String.withCString(w == (u32)1 ? "dl" : (w == (u32)2 ? "dx" : (w == (u32)4 ? "edx" : "rdx")));
        return String.withCString("rax");
        }

    // A named 64-bit home register at a width. The r8-r15 names take a width
    // SUFFIX (r8d/r8w/r8b); the eight legacy registers each spell their views
    // differently, and rsi/rdi/rbp/rsp have no 8-bit view at all before REX
    // (sil/dil/bpl/spl). A table beats three special cases: "rdid" is accepted
    // by nothing, and the in-house assembler refused it loudly the moment rdi
    // entered a register pool.
    static String* regView(String* r64, u32 w)
        {
        u32 k = w == (u32)1 ? (u32)0 : (w == (u32)2 ? (u32)1 : (w == (u32)4 ? (u32)2 : (u32)3));
        if (r64.equals(String.withCString("rax")))
            return String.withCString(k == (u32)0 ? "al" : (k == (u32)1 ? "ax" : (k == (u32)2 ? "eax" : "rax")));
        if (r64.equals(String.withCString("rbx")))
            return String.withCString(k == (u32)0 ? "bl" : (k == (u32)1 ? "bx" : (k == (u32)2 ? "ebx" : "rbx")));
        if (r64.equals(String.withCString("rcx")))
            return String.withCString(k == (u32)0 ? "cl" : (k == (u32)1 ? "cx" : (k == (u32)2 ? "ecx" : "rcx")));
        if (r64.equals(String.withCString("rdx")))
            return String.withCString(k == (u32)0 ? "dl" : (k == (u32)1 ? "dx" : (k == (u32)2 ? "edx" : "rdx")));
        if (r64.equals(String.withCString("rsi")))
            return String.withCString(k == (u32)0 ? "sil" : (k == (u32)1 ? "si" : (k == (u32)2 ? "esi" : "rsi")));
        if (r64.equals(String.withCString("rdi")))
            return String.withCString(k == (u32)0 ? "dil" : (k == (u32)1 ? "di" : (k == (u32)2 ? "edi" : "rdi")));
        if (r64.equals(String.withCString("rbp")))
            return String.withCString(k == (u32)0 ? "bpl" : (k == (u32)1 ? "bp" : (k == (u32)2 ? "ebp" : "rbp")));
        if (r64.equals(String.withCString("rsp")))
            return String.withCString(k == (u32)0 ? "spl" : (k == (u32)1 ? "sp" : (k == (u32)2 ? "esp" : "rsp")));
        String* o = String.withCString(r64.cString());
        if (w == (u32)1)
            o.appendCString("b");
        else if (w == (u32)2)
            o.appendCString("w");
        else if (w == (u32)4)
            o.appendCString("d");
        return o;
        }

    static String* sizeKw(u32 w)
        {
        if (w == (u32)1)
            return String.withCString("byte ptr");
        if (w == (u32)2)
            return String.withCString("word ptr");
        if (w == (u32)4)
            return String.withCString("dword ptr");
        return String.withCString("qword ptr");
        }

    // ── Entry point ──────────────────────────────────────────────────────
    String* assembly(IRModule* m)
        {
        _m = m;
        _atomicArc = _arcOverride >= (i32)0 ? _arcOverride != (i32)0 : spawnsThreads(m);
        _out = new String();
        _out.appendCString("\t.intel_syntax noprefix\n\t.text\n");
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0)
                continue; // an external prototype
            // Each function is peepholed in ISOLATION: slot offsets are
            // per-function, and the scan reasons about a straight-line region.
            String* module = _out;
            _out = new String();
            emitFunction(fn);
            module.append(peepholeFallthrough(peepholeCopyProp(_out)));
            _out = module;
            }
        emitModuleData(m);
        return _out;
        }

    // ── Frame ────────────────────────────────────────────────────────────
    //
    // One slot per non-memory value at [rbp-off], laid out in VALUE-ID order —
    // an aggregate gets its whole extent, so AddrOf of a pinned local addresses
    // real storage. The callee-save area follows, then (Win64) the hidden sret
    // pointer, and the whole thing rounds to 16 so rsp stays aligned at a call.
    Map* _slot;
    u32 _frame;
    Homing* _homing;
    Array* _homeSaves; // callee-saved registers used, in pool order
    Map* _homeSaveOff; // register -> its [rbp-off]
    u32 _sretOff;      // Win64's hidden result pointer, or 0
    bool _hasAsm;      // an inline-asm body: home nothing

    void emitFunction(IRFunc* fn)
        {
        _fn = fn;
        _hasAsm = functionHasAsm(fn);
        assignSlots(fn);
        buildDefOf(fn);
        assignVectorRegs(fn);
        computeFoldsAndFusion(fn); // both feed the allocator's exclusion set
        assignHomes(fn);
        // The callee-save area sits past the value slots, then Win64's hidden
        // result pointer; the frame rounds to 16 so rsp stays aligned at a call.
        u32 cur = _frame;
        _homeSaveOff = new Map();
        for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
            {
            cur = cur + (u32)8;
            _homeSaveOff.set((Hashable*)(String*)_homeSaves.get(i), (Object*)Number.withU32(cur));
            }
        _sretOff = (u32)0;
        bool hasSret = returnsBigAgg(fn.ret()) || returnsSysVMemAgg(fn.ret());
        if (hasSret)
            {
            cur = cur + (u32)8;
            _sretOff = cur;
            }
        _frame = (cur + (u32)15) & ~(u32)15;

        // `.type … @function` is ELF-only; PE/COFF rejects it.
        if (_win64)
            _out.appendFormat("\t.globl\t%s\n%s:\n", fn.name().cString(), fn.name().cString());
        else
            _out.appendFormat("\t.globl\t%s\n\t.type\t%s, @function\n%s:\n",
                              fn.name().cString(), fn.name().cString(), fn.name().cString());
        _out.appendCString("\tpush\trbp\n\tmov\trbp, rsp\n");
        if (_frame != (u32)0)
            _out.appendFormat("\tsub\trsp, %lu\n", _frame);
        for (u32 i = (u32)0; i < _homeSaves.count(); i = i + (u32)1)
            {
            String* r = (String*)_homeSaves.get(i);
            _out.appendFormat("\tmov\t[rbp-%lu], %s\n",
                              ((Number*)_homeSaveOff.get((Hashable*)r)).asU32(), r.cString());
            }
        if (hasSret)
            _out.appendFormat("\tmov\t[rbp-%lu], %s\n", _sretOff,
                              _win64 ? "rcx" : "rdi");
        if (_win64)
            spillWin64Params(fn, hasSret);
        else
            spillSysVParams(fn, hasSret);
        seedHomedParams(fn);
        // A loop head is a block some LATER block branches back to. Computed
        // once here, as the original does, so both compilers mark the same set.
        Array* loopHead = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            loopHead.add((Object*)Number.with((u32)0));
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* pb = (IRBlock*)fn.blocks().get(bi);
            if (pb.term() == (IRInsn*)0)
                continue;
            for (u32 q = (u32)0; q < pb.term().ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)pb.term().ops().get(q);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                for (u32 hb = (u32)0; hb < fn.blocks().count(); hb = hb + (u32)1)
                    if ((IRBlock*)fn.blocks().get(hb) == o.blk() && hb <= bi)
                        loopHead.set(hb, (Object*)Number.with((u32)1));
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            emitBlock(fn, (IRBlock*)fn.blocks().get(b),
                      ((Number*)loopHead.get(b)).asU32() != (u32)0);
        }

    // rbx and r12-r15 are the callee-saved pool; there is no caller-saved tier
    // here, and floats stay in slots. A function containing inline asm homes
    // nothing: the asm may name a local by its slot.
    void assignHomes(IRFunc* fn)
        {
        _homing = (Homing*)0;
        _homeSaves = new Array();
        if (_hasAsm)
            return;
        Array* callee = new Array();
        callee.add((Object*)String.withCString("rbx"));
        callee.add((Object*)String.withCString("r12"));
        callee.add((Object*)String.withCString("r13"));
        callee.add((Object*)String.withCString("r14"));
        callee.add((Object*)String.withCString("r15"));
        Homing* h = new Homing();
        // A folded address is never materialised and a fused ICmp result is
        // never stored, so a home for either reserves a register for nothing.
        Array* ef = _fold.allKeys();
        for (u32 i = (u32)0; i < ef.count(); i = i + (u32)1)
            h.exclude(((IRValue*)ef.get(i)).pid());
        Array* ec = _fusedCmp.allKeys();
        for (u32 i = (u32)0; i < ec.count(); i = i + (u32)1)
            h.exclude(((IRValue*)ec.get(i)).pid());
        Array* es = _selSkip.allKeys();
        for (u32 i = (u32)0; i < es.count(); i = i + (u32)1)
            h.exclude(((IRValue*)es.get(i)).pid());
        // The folds also EXTEND live ranges: a folded address's base and index
        // are read at the Load, not at the elided address op.
        Map* byId = new Map();
        Array* fk = _fold.allKeys();
        for (u32 i = (u32)0; i < fk.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)fk.get(i);
            byId.set((Hashable*)Number.with(v.pid()), _fold.get((Hashable*)v));
            }
        h.setFoldInfo(byId);
        // …and so does a Select-fused ICmp: its compare is re-issued at the
        // Select, so its operands are read there.
        Map* selById = new Map();
        Array* sk = _selSkip.allKeys();
        for (u32 i = (u32)0; i < sk.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)sk.get(i);
            selById.set((Hashable*)Number.with(v.pid()), _selSkip.get((Hashable*)v));
            }
        h.setSelInfo(selById);
        // Floats used to stay in slots entirely, and float_math showed it:
        // sixteen instructions for four of arithmetic, every intermediate
        // stored and immediately reloaded. Every xmm is caller-saved under
        // SysV, so these are a CALLER tier and the allocator's crossesCall
        // test keeps anything live across a call out of them by itself.
        //
        // xmm0/xmm1 are emission scratch and xmm2-xmm15 are the vectoriser's
        // pool, so this is gated on the function having no Vec value at all,
        // exactly as arm64 gates d18-d31.
        bool fnHasVector = false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* vb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < vb.insns().count(); i = i + (u32)1)
                {
                IRInsn* vi = (IRInsn*)vb.insns().get(i);
                if (vi.res() != (IRValue*)0 && isVecTy(vi.res().ty()))
                    fnHasVector = true;
                }
            for (u32 i = (u32)0; i < vb.phis().count(); i = i + (u32)1)
                {
                IRInsn* vp = (IRInsn*)vb.phis().get(i);
                if (vp.res() != (IRValue*)0 && isVecTy(vp.res().ty()))
                    fnHasVector = true;
                }
            }
        Array* fpCaller = new Array();
        if (!fnHasVector)
            {
            fpCaller.add((Object*)String.withCString("xmm8"));
            fpCaller.add((Object*)String.withCString("xmm9"));
            fpCaller.add((Object*)String.withCString("xmm10"));
            fpCaller.add((Object*)String.withCString("xmm11"));
            fpCaller.add((Object*)String.withCString("xmm12"));
            fpCaller.add((Object*)String.withCString("xmm13"));
            fpCaller.add((Object*)String.withCString("xmm14"));
            fpCaller.add((Object*)String.withCString("xmm15"));
            }
        // GP caller tier. SysV leaves only five callee-saved registers, so a
        // function with more than five hot values put the rest in slots and the
        // hot loop became store/reload traffic — call_depth spent 25 of its 60
        // loop instructions moving temporaries in and out of the frame. These
        // are caller-saved on their ABI and are NOT emission scratch (rax, rcx
        // and rdx are), so a value that crosses no call may live in one for
        // free. The allocator's crossesCall test is inclusive at both ends, so a
        // value that is an operand OR the result of a call is already barred.
        //
        // A parameter homed in one of these is safe even though four of them are
        // incoming-argument registers: the prologue SPILLS every parameter to
        // its slot first and only then seeds the homes from those slots, so
        // nothing reads an argument register after the seeding starts.
        //
        // Under Win64 rdi and rsi are callee-saved, so only r8-r11 qualify.
        Array* gpCaller = new Array();
        if (!_win64)
            {
            gpCaller.add((Object*)String.withCString("rdi"));
            gpCaller.add((Object*)String.withCString("rsi"));
            }
        gpCaller.add((Object*)String.withCString("r8"));
        gpCaller.add((Object*)String.withCString("r9"));
        gpCaller.add((Object*)String.withCString("r10"));
        gpCaller.add((Object*)String.withCString("r11"));
        h.run(fn, callee, gpCaller, new Array(), fpCaller);
        _homing = h;
        _homeSaves = h.usedCalleeSaved();
        }

    // System V: integer and pointer arguments in rdi, rsi, rdx, rcx, r8, r9;
    // floats in xmm0-7 on an INDEPENDENT counter; anything past those on the
    // stack above the return address.
    void spillSysVParams(IRFunc* fn, bool hasSret)
        {
        Array* iregs = sysvArgRegs();
        // A hidden sret consumes rdi, shifting the GP arguments right by one.
        u32 ireg = hasSret ? (u32)1 : (u32)0;
        u32 freg = (u32)0;
        u32 sidx = (u32)0;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)fn.params().get(i);
            if (pv == (IRValue*)0 || isMemTy(pv.ty()))
                continue;
            u32 s = slotOf(pv);
            String* t = pv.ty();
            if (isAggTy(t))
                {
                // A struct by value rides ceil(size/8) consecutive GP argument
                // registers, one 8-byte chunk each, mirroring the caller. It is
                // skipped symmetrically if it would overflow past r9.
                u32 nregs = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (hasSlot(pv) && ireg + nregs <= iregs.count())
                    {
                    for (u32 k = (u32)0; k < nregs; k = k + (u32)1)
                        {
                        _out.appendFormat("\tmov\t[rbp-%lu], %s\n", s - (u32)8 * k,
                                          ((String*)iregs.get(ireg)).cString());
                        ireg = ireg + (u32)1;
                        }
                    }
                }
            else if (isFloatTy(t))
                {
                if (hasSlot(pv) && freg < (u32)8)
                    _out.appendFormat("\tmov%s\t[rbp-%lu], xmm%lu\n",
                                      t.equals(String.withCString("F64")) ? "sd" : "ss", s, freg);
                freg = freg + (u32)1;
                }
            else if (ireg < iregs.count())
                {
                if (hasSlot(pv))
                    _out.appendFormat("\tmov\t[rbp-%lu], %s\n", s,
                                      ((String*)iregs.get(ireg)).cString());
                ireg = ireg + (u32)1;
                }
            else
                {
                // Overflow: the caller passed it on the stack, above the return
                // address — [rbp+16] first, then +8 each, in parameter order.
                // Slots are at least 8 bytes, so a full 8-byte copy is safe.
                if (hasSlot(pv))
                    {
                    _out.appendFormat("\tmov\trax, [rbp+%lu]\n", (u32)16 + (u32)8 * sidx);
                    _out.appendFormat("\tmov\t[rbp-%lu], rax\n", s);
                    }
                sidx = sidx + (u32)1;
                }
            }
        }

    // Win64: ONE positional counter shared by integers and floats. Position p
    // below 4 is [rcx,rdx,r8,r9][p] or xmm{p}; anything past is on the stack
    // above the caller's mandatory 32-byte shadow store — the first at
    // [rbp+48], then +8 each. A >8-byte struct arrives BY REFERENCE, one
    // positional slot holding a pointer to the caller's copy.
    void spillWin64Params(IRFunc* fn, bool hasSret)
        {
        Array* ireg4 = win64ArgRegs();
        u32 pos = hasSret ? (u32)1 : (u32)0; // rcx is the sret when present
        u32 sstack = (u32)0;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)fn.params().get(i);
            if (pv == (IRValue*)0 || isMemTy(pv.ty()))
                continue;
            u32 s = slotOf(pv);
            String* t = pv.ty();
            if (isAggTy(t) && aggSize(layoutOf(t)) > (u32)8)
                {
                if (pos < (u32)4)
                    _out.appendFormat("\tmov\trax, %s\n", ((String*)ireg4.get(pos)).cString());
                else
                    _out.appendFormat("\tmov\trax, [rbp+%lu]\n", (u32)48 + (u32)8 * sstack);
                if (pos >= (u32)4)
                    sstack = sstack + (u32)1;
                if (hasSlot(pv))
                    {
                    // rax holds the pointer and r10 the word scratch; neither is
                    // an argument register.
                    u32 q = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                    for (u32 k = (u32)0; k < q; k = k + (u32)1)
                        {
                        _out.appendFormat("\tmov\tr10, [rax+%lu]\n", (u32)8 * k);
                        _out.appendFormat("\tmov\t[rbp-%lu], r10\n", s - (u32)8 * k);
                        }
                    }
                pos = pos + (u32)1;
                continue;
                }
            // <=8 bytes: by value
            if (isAggTy(t))
                {
                if (pos < (u32)4)
                    {
                    if (hasSlot(pv))
                        _out.appendFormat("\tmov\t[rbp-%lu], %s\n", s,
                                          ((String*)ireg4.get(pos)).cString());
                    }
                else if (hasSlot(pv))
                    {
                    _out.appendFormat("\tmov\trax, [rbp+%lu]\n", (u32)48 + (u32)8 * sstack);
                    _out.appendFormat("\tmov\t[rbp-%lu], rax\n", s);
                    }
                if (pos >= (u32)4)
                    sstack = sstack + (u32)1;
                pos = pos + (u32)1;
                continue;
                }
            if (isFloatTy(t))
                {
                if (pos < (u32)4)
                    {
                    if (hasSlot(pv))
                        _out.appendFormat("\tmov%s\t[rbp-%lu], xmm%lu\n",
                                          t.equals(String.withCString("F64")) ? "sd" : "ss", s, pos);
                    }
                else if (hasSlot(pv))
                    {
                    _out.appendFormat("\tmov\trax, [rbp+%lu]\n", (u32)48 + (u32)8 * sstack);
                    _out.appendFormat("\tmov\t[rbp-%lu], rax\n", s);
                    }
                if (pos >= (u32)4)
                    sstack = sstack + (u32)1;
                pos = pos + (u32)1;
                continue;
                }
            if (pos < (u32)4)
                {
                if (hasSlot(pv))
                    _out.appendFormat("\tmov\t[rbp-%lu], %s\n", s,
                                      ((String*)ireg4.get(pos)).cString());
                }
            else if (hasSlot(pv))
                {
                _out.appendFormat("\tmov\trax, [rbp+%lu]\n", (u32)48 + (u32)8 * sstack);
                _out.appendFormat("\tmov\t[rbp-%lu], rax\n", s);
                }
            if (pos >= (u32)4)
                sstack = sstack + (u32)1;
            pos = pos + (u32)1;
            }
        }

    // A homed parameter is seeded from the slot the spill above always wrote;
    // every reader uses the home from here on.
    void seedHomedParams(IRFunc* fn)
        {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)fn.params().get(i);
            if (pv == (IRValue*)0)
                continue;
            String* home = homeOf(pv);
            if (home == (String*)0 || !hasSlot(pv))
                continue;
            // A float parameter homed in an xmm needs the FP load. `mov xmm9,
            // [rbp-16]` is not an instruction — and the in-house assembler
            // ACCEPTED it rather than refusing, so logical_not_float simply
            // read rubbish for its parameters instead of failing to build.
            if (isXmmHome(home))
                _out.appendFormat("\tmov%s\t%s, [rbp-%lu]\n",
                                  pv.ty().equals(String.withCString("F64")) ? "sd" : "ss",
                                  home.cString(), slotOf(pv));
            else
                _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", home.cString(), slotOf(pv));
            }
        }

    static Array* sysvArgRegs(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("rdi"));
        a.add((Object*)String.withCString("rsi"));
        a.add((Object*)String.withCString("rdx"));
        a.add((Object*)String.withCString("rcx"));
        a.add((Object*)String.withCString("r8"));
        a.add((Object*)String.withCString("r9"));
        return a;
        }

    static Array* win64ArgRegs(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("rcx"));
        a.add((Object*)String.withCString("rdx"));
        a.add((Object*)String.withCString("r8"));
        a.add((Object*)String.withCString("r9"));
        return a;
        }

    // ── Division by a constant → a reciprocal multiply ───────────────────
    //
    // Granlund-Montgomery. The reference computes the magic in 2W-bit
    // arithmetic and this language has no 64-bit integer, so the two places
    // that need it are handled directly: 2^W mod d becomes
    // ((2^W - 1) mod d + 1) mod d, and the quotient's doubling carries an
    // overflow FLAG — the loop's only use of it is `q1 < delta` with
    // delta < 2^W, so an overflowed q1 is unconditionally not less. q2 is MEANT
    // to wrap, so its natural u32 wraparound at W=32 is exactly right.
    bool constDivisor(IROperand* op, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            *out = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return false;
        IRValue* cur = op.val();
        for (u32 g = (u32)0; g < (u32)8; g = g + (u32)1)
            {
            IRInsn* d = defInsnFor(cur);
            if (d == (IRInsn*)0 || d.ops().count() < (u32)1)
                return false;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("Const")))
                {
                if (a0.kind() != (u8)OPK_IMMI)
                    return false;
                *out = a0.imm();
                return true;
                }
            if ((d.op().equals(String.withCString("ZExt")) || d.op().equals(String.withCString("SExt")) || d.op().equals(String.withCString("Trunc"))) && a0.kind() == (u8)OPK_USE)
                {
                cur = a0.val();
                continue;
                }
            return false;
            }
        return false;
        }

    Map* _defOf;

    IRInsn* defInsnFor(IRValue* v)
        {
        if (_defOf == (Map*)0)
            return (IRInsn*)0;
        Object* o = _defOf.get((Hashable*)v);
        return o == (Object*)0 ? (IRInsn*)0 : (IRInsn*)o;
        }

    void buildDefOf(IRFunc* fn)
        {
        _defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            noteDefs(bb.phis());
            noteDefs(bb.insns());
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                _defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
            }
        }

    void noteDefs(Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() != (IRValue*)0)
                _defOf.set((Hashable*)n.res(), (Object*)n);
            }
        }

    void emitMagicUnsigned(IRInsn* n, i32 dC, bool rem)
        {
        u32 M = (u32)0;
        u32 addInd = (u32)0;
        u32 sh = (u32)0;
        magicU((u32)dC, (u32)32, &M, &addInd, &sh);
        IROperand* x = (IROperand*)n.ops().get((u32)0);
        loadExt(x, (u8)'a', false, (u32)4);
        _out.appendFormat("\tmov\tecx, %lu\n", M);
        _out.appendCString("\tmul\tecx\n"); // edx = mulhu(x, M)
        if (addInd == (u32)0)
            {
            if (sh > (u32)0)
                _out.appendFormat("\tshr\tedx, %lu\n", sh);
            }
        else
            {
            // The magic overflowed W bits, so the quotient is t + ((x−t) >> 1),
            // then shifted by s−1.
            loadExt(x, (u8)'a', false, (u32)4);
            _out.appendCString("\tsub\teax, edx\n");
            _out.appendCString("\tshr\teax, 1\n");
            _out.appendCString("\tadd\tedx, eax\n");
            if (sh > (u32)1)
                _out.appendFormat("\tshr\tedx, %lu\n", sh - (u32)1);
            }
        // r = x − q*d
        if (rem)
            {
            _out.appendFormat("\timul\tecx, edx, %ld\n", dC);
            loadExt(x, (u8)'a', false, (u32)4);
            _out.appendCString("\tsub\teax, ecx\n");
            store((u8)'a', n.res());
            }
        else
            {
            store((u8)'d', n.res());
            }
        }

    void emitMagicSigned(IRInsn* n, i32 dC, bool rem)
        {
        i32 Ms = (i32)0;
        u32 sh = (u32)0;
        magicS(dC, &Ms, &sh);
        IROperand* x = (IROperand*)n.ops().get((u32)0);
        loadExt(x, (u8)'a', true, (u32)4);
        _out.appendFormat("\tmov\tecx, %lu\n", (u32)Ms);
        _out.appendCString("\timul\tecx\n"); // edx = mulhs(x, M)
        // The magic's sign disagreeing with the divisor's leaves the high part
        // one x short (or long) — corrected before the shift.
        if (dC > (i32)0 && Ms < (i32)0)
            {
            loadExt(x, (u8)'a', true, (u32)4);
            _out.appendCString("\tadd\tedx, eax\n");
            }
        if (dC < (i32)0 && Ms > (i32)0)
            {
            loadExt(x, (u8)'a', true, (u32)4);
            _out.appendCString("\tsub\tedx, eax\n");
            }
        if (sh > (u32)0)
            _out.appendFormat("\tsar\tedx, %lu\n", sh);
        _out.appendCString("\tmov\teax, edx\n"); // + the sign bit
        _out.appendCString("\tshr\teax, 31\n");
        _out.appendCString("\tadd\tedx, eax\n");
        if (rem)
            {
            _out.appendFormat("\timul\tecx, edx, %ld\n", dC);
            loadExt(x, (u8)'a', true, (u32)4);
            _out.appendCString("\tsub\teax, ecx\n");
            store((u8)'a', n.res());
            }
        else
            {
            store((u8)'d', n.res());
            }
        }

    static void magicU(u32 d, u32 W, u32* Mout, u32* aout, u32* sout)
        {
        u32 twoWm1 = (u32)1 << (W - (u32)1);
        u32 maxu = W == (u32)32 ? (u32)$FFFF_FFFF : (((u32)1 << W) - (u32)1);
        u32 a = (u32)0;
        u32 p = W - (u32)1;
        u32 nc = maxu - ((maxu % d) + (u32)1) % d;
        u32 q1 = twoWm1 / nc;
        u32 r1 = twoWm1 - q1 * nc;
        bool q1over = false;
        u32 q2 = (twoWm1 - (u32)1) / d;
        u32 r2 = (twoWm1 - (u32)1) - q2 * d;
        u32 delta = (u32)0;
        bool again = true;
        while (again)
            {
            p = p + (u32)1;
            if (q1 >= twoWm1)
                q1over = true;
            if (r1 >= nc - r1)
                {
                q1 = q1 + q1 + (u32)1;
                r1 = r1 - (nc - r1);
                }
            else
                {
                q1 = q1 + q1;
                r1 = r1 + r1;
                }
            if (r2 + (u32)1 >= d - r2)
                {
                if (q2 >= twoWm1 - (u32)1)
                    a = (u32)1;
                q2 = q2 + q2 + (u32)1;
                r2 = r2 - (d - r2 - (u32)1);
                }
            else
                {
                if (q2 >= twoWm1)
                    a = (u32)1;
                q2 = q2 + q2;
                r2 = r2 + r2 + (u32)1;
                }
            delta = d - (u32)1 - r2;
            again = p < (u32)2 * W && !q1over && (q1 < delta || (q1 == delta && r1 == (u32)0));
            }
        *Mout = (q2 + (u32)1) & maxu;
        *aout = a;
        *sout = p - W;
        }

    static void magicS(i32 dIn, i32* Mout, u32* sout)
        {
        u32 twoWm1 = (u32)$8000_0000;
        u32 ad = (u32)(dIn < (i32)0 ? -dIn : dIn);
        u32 t = twoWm1 + (((u32)dIn >> (u32)31) & (u32)1);
        u32 anc = t - (u32)1 - t % ad;
        u32 p = (u32)31;
        u32 q1 = twoWm1 / anc;
        u32 r1 = twoWm1 - q1 * anc;
        bool q1over = false;
        u32 q2 = twoWm1 / ad;
        u32 r2 = twoWm1 - q2 * ad;
        u32 delta = (u32)0;
        bool again = true;
        while (again)
            {
            p = p + (u32)1;
            if (q1 >= twoWm1)
                q1over = true;
            q1 = q1 + q1;
            r1 = r1 + r1;
            if (r1 >= anc)
                {
                q1 = q1 + (u32)1;
                r1 = r1 - anc;
                }
            q2 = q2 + q2;
            r2 = r2 + r2;
            if (r2 >= ad)
                {
                q2 = q2 + (u32)1;
                r2 = r2 - ad;
                }
            delta = ad - r2;
            again = !q1over && (q1 < delta || (q1 == delta && r1 == (u32)0));
            }
        i32 M = (i32)(q2 + (u32)1);
        if (dIn < (i32)0)
            M = -M;
        *Mout = M;
        *sout = p - (u32)32;
        }

    // ── Floating point (SSE) ─────────────────────────────────────────────
    //
    // Floats live in frame slots and move through xmm0/xmm1 — they are never
    // homed, since the allocator is handed an empty FP pool.
    // Move a value between its HOME register and a GP register, choosing the
    // cross-file instruction when the home is an xmm one. `mov ecx, xmm9` is
    // not an instruction: between the integer and FP files it is movd (32) or
    // movq (64). Floats are homed now, and a Load or Store of float BITS still
    // goes through a GP register, so both directions occur.
    bool isXmmHome(String* r)
        {
        return r != (String*)0 && r.hasPrefix(String.withCString("xmm"));
        }

    void movFromHome(String* home, u32 w, String* dst)
        {
        if (isXmmHome(home))
            _out.appendFormat("\t%s\t%s, %s\n", w >= (u32)8 ? "movq" : "movd",
                              dst.cString(), home.cString());
        else
            _out.appendFormat("\tmov\t%s, %s\n", dst.cString(), regView(home, w).cString());
        }

    void movIntoHome(String* home, u32 w, String* src)
        {
        if (isXmmHome(home))
            _out.appendFormat("\t%s\t%s, %s\n", w >= (u32)8 ? "movq" : "movd",
                              home.cString(), src.cString());
        else
            _out.appendFormat("\tmov\t%s, %s\n", regView(home, w).cString(), src.cString());
        }

    void loadF(IROperand* op, String* xmm)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            _out.appendFormat("\txorps\t%s, %s\n", xmm.cString(), xmm.cString());
            return;
            }
        // A HOMED float never has its slot written, so reading the slot here
        // would read whatever was in it before the value was homed.
        String* fh = homeOf(op.val());
        if (isXmmHome(fh))
            {
            if (!fh.equals(xmm))
                _out.appendFormat("\tmovaps\t%s, %s\n", xmm.cString(), fh.cString());
            return;
            }
        if (!hasSlot(op.val()))
            {
            _out.appendFormat("\txorps\t%s, %s\n", xmm.cString(), xmm.cString());
            return;
            }
        _out.appendFormat("\tmov%s\t%s, [rbp-%lu]\n",
                          op.val().ty().equals(String.withCString("F64")) ? "sd" : "ss",
                          xmm.cString(), slotOf(op.val()));
        }

    void storeF(String* xmm, IRValue* res)
        {
        if (res == (IRValue*)0)
            return;
        String* fh = homeOf(res);
        if (isXmmHome(fh))
            {
            if (!fh.equals(xmm))
                _out.appendFormat("\tmovaps\t%s, %s\n", fh.cString(), xmm.cString());
            return;
            }
        if (!hasSlot(res))
            return;
        _out.appendFormat("\tmov%s\t[rbp-%lu], %s\n",
                          res.ty().equals(String.withCString("F64")) ? "sd" : "ss",
                          slotOf(res), xmm.cString());
        }

    // Every float op used to stage through the xmm0/xmm1 scratch pair even when
    // both operands were already homed — 35 register-to-register movaps around
    // 8 arithmetic instructions in float_math's loop, where arm64 emits none.
    // Emitting straight into the result's home collapses that: loadF into a
    // register the value already occupies emits nothing, and storeF back out
    // of it likewise. The one hazard is a two-operand form whose destination
    // is ALSO where the second operand lives; that falls back to the scratch.
    String* fdstFor(IRValue* res, IROperand* other, IROperand* first)
        {
        String* h = homeOf(res);
        if (!isXmmHome(h))
            return String.withCString("xmm0");
        if (other != (IROperand*)0 && other.kind() == (u8)OPK_USE && other.val() != (IRValue*)0)
            {
            // The same VALUE in both operands (x*x) is safe: the read happens
            // from the destination, which still holds it.
            bool sameValue = first != (IROperand*)0 && first.kind() == (u8)OPK_USE
                             && first.val() == other.val();
            String* oh = homeOf(other.val());
            if (!sameValue && isXmmHome(oh) && oh.equals(h))
                return String.withCString("xmm0");
            }
        return h;
        }

    // The second operand's own home when it has one — no copy needed —
    // otherwise load it into the xmm1 scratch and use that.
    String* fsrcFor(IROperand* op)
        {
        if (op != (IROperand*)0 && op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            {
            String* h = homeOf(op.val());
            if (isXmmHome(h))
                return h;
            }
        String* x1 = String.withCString("xmm1");
        loadF(op, x1);
        return x1;
        }

    // A float value's own home when it has one, else the xmm0 scratch. Used by
    // Store, where xmm0 is free (unlike a binary op, whose first operand may
    // already be sitting there).
    String* fsrcForStore(IROperand* op)
        {
        if (op != (IROperand*)0 && op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            {
            String* h = homeOf(op.val());
            if (isXmmHome(h))
                return h;
            }
        String* x0 = String.withCString("xmm0");
        loadF(op, x0);
        return x0;
        }

    void emitFBin(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        bool d = n.res().ty().equals(String.withCString("F64"));
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        String* D = fdstFor(n.res(), o1, o0);
        loadF(o0, D);
        String* S = fsrcFor(o1);
        String* op = n.op();
        String* mn = op.equals(String.withCString("FAdd")) ? String.withCString("add")
                                                           : (op.equals(String.withCString("FSub")) ? String.withCString("sub")
                                                                                                    : (op.equals(String.withCString("FMul")) ? String.withCString("mul")
                                                                                                                                             : String.withCString("div")));
        _out.appendFormat("\t%s%s\t%s, %s\n", mn.cString(), d ? "sd" : "ss",
                          D.cString(), S.cString());
        storeF(D, n.res());
        }

    // Negation is 0 − x, which keeps the sign of a zero right without needing a
    // sign-mask constant in memory.
    void emitFNeg(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        bool d = n.res().ty().equals(String.withCString("F64"));
        // The operand goes to the scratch FIRST, so zeroing the destination
        // cannot destroy it even when result and operand share a home.
        loadF((IROperand*)n.ops().get((u32)0), String.withCString("xmm0"));
        String* Dn = homeOf(n.res());
        if (!isXmmHome(Dn) || Dn.equals(String.withCString("xmm0")))
            Dn = String.withCString("xmm1");
        _out.appendFormat("\txorps\t%s, %s\n", Dn.cString(), Dn.cString());
        _out.appendFormat("\tsub%s\t%s, xmm0\n", d ? "sd" : "ss", Dn.cString());
        storeF(Dn, n.res());
        }

    void emitFSqrt(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        bool d = n.res().ty().equals(String.withCString("F64"));
        String* Sq = fsrcFor((IROperand*)n.ops().get((u32)0));
        String* Dq = fdstFor(n.res(), (IROperand*)0, (IROperand*)0);
        _out.appendFormat("\tsqrt%s\t%s, %s\n", d ? "sd" : "ss", Dq.cString(), Sq.cString());
        storeF(Dq, n.res());
        }

    void emitIntToFp(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        bool d = n.res().ty().equals(String.withCString("F64"));
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        u32 w = (src.kind() == (u8)OPK_USE && widthOfValue(src.val()) >= (u32)8) ? (u32)8 : (u32)4;
        // cvtsi2* reads a SIGNED register, so a signed source must be
        // sign-extended — zero-extending would turn a negative i8 into a large
        // positive integer.
        if (n.op().equals(String.withCString("SIToFp")))
            loadExt(src, (u8)'a', true, w);
        else
            loadZX(src, (u8)'a');
        _out.appendFormat("\tcvtsi2%s\txmm0, %s\n", d ? "sd" : "ss", reg((u8)'a', w).cString());
        storeF(String.withCString("xmm0"), n.res());
        }

    // The spec saturates an out-of-range or NaN conversion to 0; cvtt* yields
    // the "integer indefinite" (0x8000…0) for those, so that value maps to 0.
    void emitFpToInt(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        bool d = src.kind() == (u8)OPK_USE && src.val() != (IRValue*)0 && src.val().ty().equals(String.withCString("F64"));
        u32 rw = widthOfValue(n.res());
        loadF(src, String.withCString("xmm0"));
        _out.appendFormat("\tcvtt%s2si\t%s, xmm0\n", d ? "sd" : "ss",
                          reg((u8)'a', rw >= (u32)8 ? (u32)8 : (u32)4).cString());
        if (rw >= (u32)8)
            _out.appendCString("\txor\tecx, ecx\n\tmov\trdx, 0x8000000000000000\n\tcmp\trax, rdx\n\tcmove\trax, rcx\n");
        else
            _out.appendCString("\txor\tecx, ecx\n\tcmp\teax, 0x80000000\n\tcmove\teax, ecx\n");
        store((u8)'a', n.res());
        }

    void emitFpConvert(IRInsn* n, bool widen)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        String* Sc = fsrcFor((IROperand*)n.ops().get((u32)0));
        String* Dc = fdstFor(n.res(), (IROperand*)0, (IROperand*)0);
        _out.appendFormat("\t%s\t%s, %s\n", widen ? "cvtss2sd" : "cvtsd2ss",
                          Dc.cString(), Sc.cString());
        storeF(Dc, n.res());
        }

    // ucomis* sets CF and ZF like an UNSIGNED compare, so seta/setae are the
    // ordered > and >= (a NaN gives false); the < and <= forms swap their
    // operands to reuse them.
    void emitFCmp(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        bool d = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 && o0.val().ty().equals(String.withCString("F64"));
        String* p = n.pred();
        bool swap = p != (String*)0 && (p.equals(String.withCString("OLT")) || p.equals(String.withCString("OLE")));
        loadF((IROperand*)n.ops().get(swap ? (u32)1 : (u32)0), String.withCString("xmm0"));
        loadF((IROperand*)n.ops().get(swap ? (u32)0 : (u32)1), String.withCString("xmm1"));
        _out.appendFormat("\tucomi%s\txmm0, xmm1\n", d ? "sd" : "ss");
        String* cc;
        if (p != (String*)0 && p.equals(String.withCString("OEQ")))
            cc = String.withCString("sete");
        else if (p != (String*)0 && p.equals(String.withCString("ONE")))
            cc = String.withCString("setne");
        else if (p != (String*)0 && (p.equals(String.withCString("OGE")) || p.equals(String.withCString("OLE"))))
            cc = String.withCString("setae");
        else
            cc = String.withCString("seta");
        _out.appendFormat("\t%s\tal\n\tmovzx\teax, al\n", cc.cString());
        store((u8)'a', n.res());
        }

    // ── SIMD (SSE) ───────────────────────────────────────────────────────
    //
    // Vector values are loop-local, so disjoint vectorised loops REUSE
    // registers. The pool is xmm2-xmm15, all caller-saved on System V — and a
    // vectorised loop body contains no calls by construction, so no prologue
    // save is needed. xmm0 and xmm1 stay free as the shuffle scratch the
    // reductions and unsigned compares need.
    Map* _vec;      // a vector value -> its register
    Map* _vecClass; // a vector value -> its coalescing class

    String* vecOf(IRValue* v)
        {
        if (_vec == (Map*)0 || v == (IRValue*)0)
            return (String*)0;
        Object* o = _vec.get((Hashable*)v);
        return o == (Object*)0 ? (String*)0 : (String*)o;
        }

    // The lane type a Vec(T) carries.
    static String* laneOf(String* t)
        {
        if (!isVecTy(t))
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

    void emitVLoad(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        String* d = vecOf(n.res());
        if (d == (String*)0)
            return;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        bool flt = isFloatTy(laneOf(n.res().ty()));
        _out.appendFormat("\t%s\t%s, [rax]\n", flt ? "movups" : "movdqu", d.cString());
        }

    void emitVStore(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            return;
        IROperand* v = (IROperand*)n.ops().get((u32)1);
        if (v.kind() != (u8)OPK_USE)
            return;
        String* sv = vecOf(v.val());
        if (sv == (String*)0)
            return;
        bool flt = isFloatTy(laneOf(v.val().ty()));
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendFormat("\t%s\t[rax], %s\n", flt ? "movups" : "movdqu", sv.cString());
        }

    void emitVSplat(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        String* d = vecOf(n.res());
        if (d == (String*)0)
            return;
        String* lane = laneOf(n.res().ty());
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        if (lane != (String*)0 && lane.equals(String.withCString("F64")))
            {
            loadF(src, d);
            _out.appendFormat("\tunpcklpd\t%s, %s\n", d.cString(), d.cString());
            return;
            }
        if (lane != (String*)0 && lane.equals(String.withCString("F32")))
            {
            loadF(src, d);
            _out.appendFormat("\tshufps\t%s, %s, 0\n", d.cString(), d.cString());
            return;
            }
        loadZX(src, (u8)'a');
        _out.appendFormat("\tmovd\t%s, eax\n", d.cString());
        u32 lw = lane == (String*)0 ? (u32)4 : irWidth(lane);
        if (lw == (u32)2)
            {
            // A dword pshufd would splat a 16-bit scalar as [c,0,c,0,…], zeroing
            // the odd lanes; the low WORD has to be broadcast first.
            _out.appendFormat("\tpshuflw\t%s, %s, 0\n\tpshufd\t%s, %s, 0\n",
                              d.cString(), d.cString(), d.cString(), d.cString());
            }
        else if (lw == (u32)1)
            {
            _out.appendFormat("\tpunpcklbw\t%s, %s\n\tpshuflw\t%s, %s, 0\n\tpshufd\t%s, %s, 0\n",
                              d.cString(), d.cString(), d.cString(), d.cString(),
                              d.cString(), d.cString());
            }
        else
            {
            _out.appendFormat("\tpshufd\t%s, %s, 0\n", d.cString(), d.cString());
            }
        }

    void emitVBin(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            return;
        String* d = vecOf(n.res());
        String* a = vecOf(o0.val());
        String* b = vecOf(o1.val());
        if (d == (String*)0 || a == (String*)0 || b == (String*)0)
            return;
        String* lane = laneOf(n.res().ty());
        String* mn = sseMnemFor(n.op(), lane);
        if (mn == (String*)0)
            {
            unsupported(String.withCString("VBin:lane"));
            return;
            }
        bool flt = isFloatTy(lane);
        String* mov = String.withCString(flt ? "movaps" : "movdqa");
        bool commut = !n.op().equals(String.withCString("VSub"));
        // The two-address destructive form: compute in d, keeping whichever
        // source already sits there when the op allows it.
        if (d.equals(a))
            {
            _out.appendFormat("\t%s\t%s, %s\n", mn.cString(), d.cString(), b.cString());
            }
        else if (commut && d.equals(b))
            {
            _out.appendFormat("\t%s\t%s, %s\n", mn.cString(), d.cString(), a.cString());
            }
        else
            {
            _out.appendFormat("\t%s\t%s, %s\n", mov.cString(), d.cString(), a.cString());
            _out.appendFormat("\t%s\t%s, %s\n", mn.cString(), d.cString(), b.cString());
            }
        }

    // Integer lanes need SSE2, and pmulld SSE4.1; float lanes plain SSE.
    static String* sseMnemFor(String* op, String* lane)
        {
        bool flt = isFloatTy(lane);
        if (flt)
            {
            bool d = lane.equals(String.withCString("F64"));
            if (op.equals(String.withCString("VAdd")))
                return String.withCString(d ? "addpd" : "addps");
            if (op.equals(String.withCString("VSub")))
                return String.withCString(d ? "subpd" : "subps");
            if (op.equals(String.withCString("VMul")))
                return String.withCString(d ? "mulpd" : "mulps");
            if (op.equals(String.withCString("VAnd")))
                return String.withCString(d ? "andpd" : "andps");
            if (op.equals(String.withCString("VOr")))
                return String.withCString(d ? "orpd" : "orps");
            if (op.equals(String.withCString("VXor")))
                return String.withCString(d ? "xorpd" : "xorps");
            if (op.equals(String.withCString("VMax")))
                return String.withCString(d ? "maxpd" : "maxps");
            if (op.equals(String.withCString("VMin")))
                return String.withCString(d ? "minpd" : "minps");
            return (String*)0;
            }
        u32 w = lane == (String*)0 ? (u32)4 : irWidth(lane);
        bool sgn = isSignedTy(lane);
        if (op.equals(String.withCString("VAdd")))
            return String.withCString(w == (u32)1 ? "paddb" : (w == (u32)2 ? "paddw" : (w == (u32)4 ? "paddd" : "paddq")));
        if (op.equals(String.withCString("VSub")))
            return String.withCString(w == (u32)1 ? "psubb" : (w == (u32)2 ? "psubw" : (w == (u32)4 ? "psubd" : "psubq")));
        if (op.equals(String.withCString("VMul")))
            {
            // There is no byte-lane multiply.
            if (w == (u32)2)
                return String.withCString("pmullw");
            if (w == (u32)4)
                return String.withCString("pmulld");
            return (String*)0;
            }
        if (op.equals(String.withCString("VAnd")))
            return String.withCString("pand");
        if (op.equals(String.withCString("VOr")))
            return String.withCString("por");
        if (op.equals(String.withCString("VXor")))
            return String.withCString("pxor");
        if (op.equals(String.withCString("VMax")))
            {
            if (w == (u32)4)
                return String.withCString(sgn ? "pmaxsd" : "pmaxud");
            if (w == (u32)2)
                return String.withCString(sgn ? "pmaxsw" : "pmaxuw");
            if (w == (u32)1)
                return String.withCString(sgn ? "pmaxsb" : "pmaxub");
            return (String*)0;
            }
        if (op.equals(String.withCString("VMin")))
            {
            if (w == (u32)4)
                return String.withCString(sgn ? "pminsd" : "pminud");
            if (w == (u32)2)
                return String.withCString(sgn ? "pminsw" : "pminuw");
            if (w == (u32)1)
                return String.withCString(sgn ? "pminsb" : "pminub");
            return (String*)0;
            }
        return (String*)0;
        }

    // The HIGH half of a 32x32 lane product. SSE2 gives only pmuludq, which
    // multiplies the EVEN lanes (0 and 2) into two 64-bit results, so the four
    // high halves take two products and a re-interleave:
    //
    //   xmm0 = hi(a0*b0), hi(a2*b2)   in lanes 0 and 2
    //   xmm1 = hi(a1*b1), hi(a3*b3)   in lanes 0 and 2   (operands swapped
    //                                  within each pair by pshufd 0xB1)
    //   shufps 0x88 gathers <h0,h2,h1,h3>, pshufd 0xD8 puts it back in order.
    //
    // The operand order matters for aliasing: `a` is dead once both shuffles
    // have read it, and `b` is read into the DESTINATION last, so d may alias
    // either input without losing a value that is still needed.
    void emitVMulHi(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            return;
        String* d = vecOf(n.res());
        String* a = vecOf(o0.val());
        String* b = vecOf(o1.val());
        if (d == (String*)0 || a == (String*)0 || b == (String*)0)
            return;
        _out.appendFormat("\tmovdqa\txmm0, %s\n", a.cString());
        _out.appendFormat("\tpmuludq\txmm0, %s\n", b.cString());
        _out.appendCString("\tpsrlq\txmm0, 32\n");
        _out.appendFormat("\tpshufd\txmm1, %s, 0xB1\n", a.cString());
        _out.appendFormat("\tpshufd\t%s, %s, 0xB1\n", d.cString(), b.cString());
        _out.appendFormat("\tpmuludq\txmm1, %s\n", d.cString());
        _out.appendCString("\tpsrlq\txmm1, 32\n");
        _out.appendFormat("\tmovdqa\t%s, xmm0\n", d.cString());
        _out.appendFormat("\tshufps\t%s, xmm1, 0x88\n", d.cString());
        _out.appendFormat("\tpshufd\t%s, %s, 0xD8\n", d.cString(), d.cString());
        }

    // Lane-wise logical shift right by a CONSTANT. SSE2 spells this
    // psrlw/psrld/psrlq by lane width, all two-address and all taking the count
    // as an 8-bit immediate — there is no lane-wise variable shift below AVX2,
    // and the IR never asks for one.
    void emitVLShr(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE)
            return;
        String* d = vecOf(n.res());
        String* a = vecOf(o0.val());
        if (d == (String*)0 || a == (String*)0)
            return;
        String* lane = laneOf(n.res().ty());
        u32 lw = fieldWidth(lane);
        if (lw != (u32)2 && lw != (u32)4 && lw != (u32)8)
            return; // no byte-lane shift in SSE
        String* mn = String.withCString(lw == (u32)2 ? "psrlw" : (lw == (u32)8 ? "psrlq" : "psrld"));
        if (!d.equals(a))
            _out.appendFormat("\tmovdqa\t%s, %s\n", d.cString(), a.cString());
        _out.appendFormat("\t%s\t%s, %d\n", mn.cString(), d.cString(),
                          ((IROperand*)n.ops().get((u32)1)).imm());
        }

    void emitVReduceAdd(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE)
            return;
        String* v = vecOf(o.val());
        if (v == (String*)0)
            return;
        _out.appendFormat("\tphaddd\t%s, %s\n\tphaddd\t%s, %s\n",
                          v.cString(), v.cString(), v.cString(), v.cString());
        _out.appendFormat("\tmovd\teax, %s\n", v.cString());
        store((u8)'a', n.res());
        }

    // The four lanes fold pairwise through two shuffles; xmm0 is free scratch.
    void emitVReduceMinMax(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE)
            return;
        String* v = vecOf(o.val());
        if (v == (String*)0)
            return;
        bool sgn = isSignedTy(n.res().ty());
        String* mn = n.op().equals(String.withCString("VReduceMax"))
                         ? String.withCString(sgn ? "pmaxsd" : "pmaxud")
                         : String.withCString(sgn ? "pminsd" : "pminud");
        _out.appendFormat("\tpshufd\txmm0, %s, 0x4E\n\t%s\t%s, xmm0\n",
                          v.cString(), mn.cString(), v.cString());
        _out.appendFormat("\tpshufd\txmm0, %s, 0xB1\n\t%s\t%s, xmm0\n",
                          v.cString(), mn.cString(), v.cString());
        _out.appendFormat("\tmovd\teax, %s\n", v.cString());
        store((u8)'a', n.res());
        }

    void emitVICmp(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE)
            return;
        String* d = vecOf(n.res());
        String* a = vecOf(o0.val());
        String* b = vecOf(o1.val());
        if (d == (String*)0 || a == (String*)0 || b == (String*)0)
            return;
        String* p = n.pred();
        bool useEq = false;
        bool swap = false;
        bool invert = false;
        bool uns = false;
        if (p == (String*)0)
            return;
        if (p.equals(String.withCString("SGT")))
            {
            }
        else if (p.equals(String.withCString("SLT")))
            {
            swap = true;
            }
        else if (p.equals(String.withCString("SGE")))
            {
            swap = true;
            invert = true;
            }
        else if (p.equals(String.withCString("SLE")))
            {
            invert = true;
            }
        else if (p.equals(String.withCString("UGT")))
            {
            uns = true;
            }
        else if (p.equals(String.withCString("ULT")))
            {
            uns = true;
            swap = true;
            }
        else if (p.equals(String.withCString("UGE")))
            {
            uns = true;
            swap = true;
            invert = true;
            }
        else if (p.equals(String.withCString("ULE")))
            {
            uns = true;
            invert = true;
            }
        else if (p.equals(String.withCString("EQ")))
            {
            useEq = true;
            }
        else if (p.equals(String.withCString("NE")))
            {
            useEq = true;
            invert = true;
            }
        else
            return;
        String* lhs = swap ? b : a;
        String* rhs = swap ? a : b;
        // The compare must be taken at the LANE width. Every mnemonic here used
        // to be the `d` (32-bit) form whatever the lanes were, so a vector of
        // BYTES was compared four at a time as one dword and a match needed all
        // four to coincide: `if (buf[i] == 44) n++` counted 0 instead of 64,
        // silently, in string_scan (bug 223).
        u32 lw = fieldWidth(laneOf(n.res().ty()));
        if (lw != (u32)1 && lw != (u32)2 && lw != (u32)4)
            return;         // 64-bit lanes need SSE4.2 pcmpgtq; not emitted today
        String* sfx = String.withCString(lw == (u32)1 ? "b" : (lw == (u32)2 ? "w" : "d"));
        if (uns && !useEq)
            {
            // There is no unsigned packed compare, so both sides are biased by
            // the lane's sign bit — flipping it turns unsigned order into
            // signed order. All-ones shifted into place gives the mask; for
            // BYTES that needs 0x01 per byte first (pabsb of all-ones),
            // because shifting all-ones left by 7 in 16-bit units leaves
            // 0xFF80, not 0x8080.
            if (lw == (u32)1)
                _out.appendCString("\tpcmpeqd\txmm1, xmm1\n\tpabsb\txmm1, xmm1\n\tpsllw\txmm1, 7\n");
            else if (lw == (u32)2)
                _out.appendCString("\tpcmpeqd\txmm1, xmm1\n\tpsllw\txmm1, 15\n");
            else
                _out.appendCString("\tpcmpeqd\txmm1, xmm1\n\tpslld\txmm1, 31\n");
            _out.appendFormat("\tmovdqa\t%s, %s\n\tpxor\t%s, xmm1\n",
                              d.cString(), lhs.cString(), d.cString());
            _out.appendFormat("\tmovdqa\txmm0, %s\n\tpxor\txmm0, xmm1\n", rhs.cString());
            _out.appendFormat("\tpcmpgt%s\t%s, xmm0\n", sfx.cString(), d.cString());
            }
        else
            {
            String* cmp = String.withCString(useEq ? "pcmpeq" : "pcmpgt");
            cmp.append(sfx);
            if (d.equals(lhs))
                {
                _out.appendFormat("\t%s\t%s, %s\n", cmp.cString(), d.cString(), rhs.cString());
                }
            else if (useEq && d.equals(rhs))
                {
                _out.appendFormat("\t%s\t%s, %s\n", cmp.cString(), d.cString(), lhs.cString());
                }
            else
                {
                _out.appendFormat("\tmovdqa\t%s, %s\n", d.cString(), lhs.cString());
                _out.appendFormat("\t%s\t%s, %s\n", cmp.cString(), d.cString(), rhs.cString());
                }
            }
        if (invert)
            _out.appendFormat("\tpcmpeqd\txmm0, xmm0\n\tpxor\t%s, xmm0\n", d.cString());
        }

    // A widening pairwise add: u8 pairs to u16 via pmaddubsw against all-ones
    // bytes, or u16 pairs to u32 via pmaddwd against all-ones words.
    void emitVAddLP(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE)
            return;
        String* d = vecOf(n.res());
        String* a = vecOf(o.val());
        if (d == (String*)0 || a == (String*)0)
            return;
        String* inLane = laneOf(o.val().ty());
        u32 iw = inLane == (String*)0 ? (u32)2 : fieldWidth(inLane);
        if (!d.equals(a))
            _out.appendFormat("\tmovdqa\t%s, %s\n", d.cString(), a.cString());
        if (iw == (u32)1)
            {
            _out.appendCString("\tpcmpeqd\txmm0, xmm0\n\tpabsb\txmm0, xmm0\n");
            _out.appendFormat("\tpmaddubsw\t%s, xmm0\n", d.cString());
            }
        else
            {
            _out.appendCString("\tpcmpeqd\txmm0, xmm0\n\tpsrlw\txmm0, 15\n");
            _out.appendFormat("\tpmaddwd\t%s, xmm0\n", d.cString());
            }
        }

    // Linear scan over xmm8-xmm15, with a vector phi's incoming values coalesced
    // onto the phi's own class so a reduction accumulator updates in place.
    void assignVectorRegs(IRFunc* fn)
        {
        _vec = new Map();
        _vecClass = new Map();
        if (_hasAsm)
            return;
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
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0 || !isVecTy(p.res().ty()))
                    continue;
                for (u32 k = (u32)0; k < p.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        _vecClass.set((Hashable*)o.val(), (Object*)p.res());
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
            pos = touchList(bb.phis(), vecVals, classes, lo, hi, pos);
            pos = touchList(bb.insns(), vecVals, classes, lo, hi, pos);
            if (bb.term() != (IRInsn*)0)
                pos = touchInsn(bb.term(), vecVals, classes, lo, hi, pos);
            blkEnd.add((Object*)Number.withI32(pos > (i32)0 ? pos - (i32)1 : (i32)0));
            }
        // A loop-invariant vector materialised before the loop is read on every
        // iteration, but the plain [min, max] scan ends it at its last TEXTUAL
        // use — after which a later in-loop op takes its register and corrupts
        // it. Extending across the back edge only ever lengthens an interval.
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
                i32 tgt = blockIndexOf(fn, o.blk());
                if (tgt < (i32)0 || (u32)tgt > bi)
                    continue;
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
        sortByStart(classes, lo);
        // Pool: xmm2..xmm15 (xmm0/xmm1 stay emission scratch). Allocation pops
        // from the END, so the order is reverse preference: xmm15..xmm8 first
        // (the historical pool), then xmm5..xmm2, and xmm7/xmm6 dead last —
        // those two are callee-saved on Win64 (the prologue does not save xmm
        // regs), so they are touched only under pressure no real program has
        // reached (#1198).
        Array* freePool = new Array();
        freePool.add((Object*)Number.withU32((u32)6));
        freePool.add((Object*)Number.withU32((u32)7));
        for (u32 r = (u32)2; r <= (u32)5; r = r + (u32)1)
            freePool.add((Object*)Number.withU32(r));
        for (u32 r = (u32)8; r <= (u32)15; r = r + (u32)1)
            freePool.add((Object*)Number.withU32(r));
        Array* active = new Array();
        // Which instruction defines each class, and which classes are phi
        // results — for the two-address coalescing below.
        Map* defOfCls = new Map();
        Array* phiCls = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() != (IRValue*)0 && isVecTy(ph.res().ty()))
                    phiCls.add((Object*)classOfVec(ph.res()));
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0 && isVecTy(n.res().ty()))
                    defOfCls.set((Hashable*)classOfVec(n.res()), (Object*)n);
                }
            }

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
            // Exhaustion is a HARD error: the old xmm15 fallback silently
            // reused a live register, which is a miscompile (#1198).
            if (freePool.count() == (u32)0)
                {
                Stdio.printf("xcc-cg-x86_64: error: vector register pressure "
                             "exceeded the 14-register SSE pool in '%s'\n",
                             fn.name().cString());
                Process.exit((i32)1);
                }
            // TWO-ADDRESS COALESCING. x86 vector ops are destructive, so when
            // the result takes a different register from a source that DIES at
            // this instruction the emitter must copy — the movdqa arm64 never
            // needs, being three-address. Linear scan will not reuse the source
            // because it frees a register only when `hi < start`, and here the
            // source dies exactly AT the position the result is born, which for
            // a two-address op is precisely when reuse is correct.
            Object* r = (Object*)0;
            Object* dobj = defOfCls.get((Hashable*)cls);
            if (dobj != (Object*)0 && !vecHasCls(phiCls, cls))
                {
                IRInsn* def = (IRInsn*)dobj;
                if (!def.op().equals(String.withCString("VLoad")) && def.ops().count() >= (u32)1)
                    {
                    IROperand* o0 = (IROperand*)def.ops().get((u32)0);
                    if (o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0)
                        {
                        IRValue* acls = classOfVec(o0.val());
                        Object* ahi = hi.get((Hashable*)acls);
                        if (acls != cls && !vecHasCls(phiCls, acls)
                            && regOf.get((Hashable*)acls) != (Object*)0
                            && ahi != (Object*)0 && ((Number*)ahi).asI32() == start
                            && vecHasCls(active, acls))
                            {
                            r = regOf.get((Hashable*)acls);
                            active.remove((Object*)acls); // its interval ends here
                            }
                        }
                    }
                }
            if (r == (Object*)0)
                {
                r = (Object*)freePool.get(freePool.count() - (u32)1);
                freePool.removeAt(freePool.count() - (u32)1);
                }
            regOf.set((Hashable*)cls, r);
            active.add((Object*)cls);
            sortByEnd(active, hi);
            }
        for (u32 i = (u32)0; i < vecVals.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)vecVals.get(i);
            Object* r = regOf.get((Hashable*)classOfVec(v));
            if (r == (Object*)0)
                continue;
            String* name = String.withCString("xmm");
            name.appendFormat("%lu", ((Number*)r).asU32());
            _vec.set((Hashable*)v, (Object*)name);
            }
        }

    // Membership by identity; `hasValue` lives in Opt.xc and is not in scope.
    bool vecHasCls(Array* a, IRValue* v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v)
                return true;
        return false;
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
            if (n.res() != (IRValue*)0 && isVecTy(n.res().ty()) && !hasVal(into, n.res()))
                into.add((Object*)n.res());
            }
        }

    static bool hasVal(Array* a, IRValue* v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v)
                return true;
        return false;
        }

    i32 touchList(Array* list, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            pos = touchInsn((IRInsn*)list.get(i), vecVals, classes, lo, hi, pos);
        return pos;
        }

    i32 touchInsn(IRInsn* n, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        if (n.res() != (IRValue*)0)
            touchVec(n.res(), vecVals, classes, lo, hi, pos);
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                touchVec(o.val(), vecVals, classes, lo, hi, pos);
            }
        return pos + (i32)1;
        }

    void touchVec(IRValue* v, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
        {
        if (!hasVal(vecVals, v))
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

    i32 blockIndexOf(IRFunc* fn, IRBlock* b)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b)
                return (i32)i;
        return (i32)-1;
        }

    static void sortByStart(Array* a, Map* key)
        {
        sortByKey(a, key);
        }
    static void sortByEnd(Array* a, Map* key)
        {
        sortByKey(a, key);
        }

    static void sortByKey(Array* a, Map* key)
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

    // ── Aggregate returns ────────────────────────────────────────────────
    //
    // Win64 returns anything over 8 bytes through the hidden sret pointer, so
    // whatever reaches the register path there is at most 8 bytes and lives
    // entirely in rax. System V returns up to 16 in rax:rdx.
    void aggToRetRegs(IRValue* v)
        {
        if (!hasSlot(v))
            return;
        u32 off = slotOf(v);
        _out.appendFormat("\tmov\trax, [rbp-%lu]\n", off);
        if (!_win64 && aggSize(layoutOf(v.ty())) > (u32)8)
            _out.appendFormat("\tmov\trdx, [rbp-%lu]\n", off - (u32)8);
        }

    void aggFromRetRegs(IRValue* res)
        {
        if (!hasSlot(res))
            return;
        u32 off = slotOf(res);
        _out.appendFormat("\tmov\t[rbp-%lu], rax\n", off);
        if (!_win64 && aggSize(layoutOf(res.ty())) > (u32)8)
            _out.appendFormat("\tmov\t[rbp-%lu], rdx\n", off - (u32)8);
        }

    // The hidden result (Win64 >8B, System V >16B MEMORY class): copy the
    // struct through the caller's pointer, saved at entry, then return that
    // pointer in rax — both ABIs require it there.
    void returnAggViaSret(IRValue* v)
        {
        _out.appendFormat("\tmov\trax, [rbp-%lu]\n", _sretOff);
        if (hasSlot(v))
            {
            u32 q = (aggSize(layoutOf(v.ty())) + (u32)7) / (u32)8;
            for (u32 k = (u32)0; k < q; k = k + (u32)1)
                {
                _out.appendFormat("\tmov\tr10, [rbp-%lu]\n", slotOf(v) - (u32)8 * k);
                _out.appendFormat("\tmov\t[rax+%lu], r10\n", (u32)8 * k);
                }
            }
        _out.appendFormat("\tmov\trax, [rbp-%lu]\n", _sretOff);
        }

    // ── ARC, weak refs, aggregates, virtual dispatch ─────────────────────
    //
    // A u16 refcount two bytes before the object. Anything below 0x10000 is
    // skipped: sentinels and non-heap addresses are not refcounted objects, and
    // a real heap object lives far above that.
    u32 _arcLabel;

    static String* arg0Reg(bool win64)
        {
        return String.withCString(win64 ? "rcx" : "rdi");
        }
    static String* arg1Reg(bool win64)
        {
        return String.withCString(win64 ? "rdx" : "rsi");
        }

    // A fixed-target runtime call. Win64 requires the caller to reserve the
    // 32-byte shadow store around it; System V is a bare call. The argument
    // registers must already be loaded — this only frames the call.
    void emitRTCall(String* target)
        {
        if (_win64)
            _out.appendFormat("\tsub\trsp, 32\n\tcall\t%s\n\tadd\trsp, 32\n", target.cString());
        else
            _out.appendFormat("\tcall\t%s\n", target.cString());
        }

    // Does anything in this module call the runtime's thread-create primitive?
    // The instruction stream is the question, not the symbol table — a symbol
    // outlives the calls to it.
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

    void emitRetain(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            return;
        u32 lbl = _arcLabel;
        _arcLabel = _arcLabel + (u32)1;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendFormat("\tcmp\trax, 0x10000\n\tjb\t.L_arc_%lu\n", lbl);
        // A refcount of ZERO means the object is being DESTROYED: the release
        // that took it to 0 is running dealloc right now. Retaining it here would
        // let the matching release take it back to 0 and dispatch dealloc AGAIN,
        // forever — which is what any strong binding of `self` inside a dealloc
        // used to cause (bug 038). A live object always holds at least one
        // reference, so 0 can only mean "already dying"; release has always had
        // the mirror-image guard, and this makes the pair symmetric.
        _out.appendCString("\tcmp\tdword ptr [rax-4], 0\n");
        _out.appendFormat("\tje\t.L_arc_%lu\n", lbl);
        // `lock` is what makes the read-modify-write indivisible; a plain
        // `add word ptr [mem], 1` loses one thread's increment.
        if (_atomicArc)
            _out.appendCString("\tlock add\tdword ptr [rax-4], 1\n");
        else
            _out.appendCString("\tadd\tdword ptr [rax-4], 1\n");
        _out.appendFormat(".L_arc_%lu:\n", lbl);
        }

    void emitRelease(IRInsn* n)
        {
        if (n.ops().count() < (u32)1)
            return;
        u32 lbl = _arcLabel;
        _arcLabel = _arcLabel + (u32)1;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendFormat("\tcmp\trax, 0x10000\n\tjb\t.L_arc_%lu\n", lbl);
        if (_atomicArc)
            {
            // XADD returns the PREVIOUS value in the source register, so "I
            // took the last reference" is old == 1 — decided from this thread's
            // own exchange, never from a re-read two threads could both see as
            // zero. cx = -1 makes the exchange a decrement.
            _out.appendCString("\tmov\tecx, -1\n");
            _out.appendCString("\tlock xadd\tdword ptr [rax-4], ecx\n");
            _out.appendCString("\tcmp\tecx, 1\n");
            _out.appendFormat("\tjne\t.L_arc_%lu\n", lbl);
            }
        else
            {
            _out.appendCString("\tsub\tdword ptr [rax-4], 1\n");
            _out.appendFormat("\tjnz\t.L_arc_%lu\n", lbl);
            }
        _out.appendFormat("\tmov\t%s, rax\n", arg0Reg(_win64).cString());
        emitRTCall(String.withCString("_xtc_dealloc"));
        _out.appendFormat(".L_arc_%lu:\n", lbl);
        }

    void emitWeakRegister(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            return;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        loadZX((IROperand*)n.ops().get((u32)1), (u8)'c');
        // Argument 1 moves FIRST: on Win64 it is rdx and argument 0 is rcx, so
        // filling argument 0 would otherwise clobber rcx before it is read.
        _out.appendFormat("\tmov\t%s, rcx\n\tmov\t%s, rax\n",
                          arg1Reg(_win64).cString(), arg0Reg(_win64).cString());
        emitRTCall(String.withCString("_xtc_weak_register"));
        }

    void emitWeakOne(IRInsn* n, String* sym, bool hasResult)
        {
        if (n.ops().count() < (u32)1)
            return;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendFormat("\tmov\t%s, rax\n", arg0Reg(_win64).cString());
        emitRTCall(sym);
        if (hasResult && n.res() != (IRValue*)0)
            store((u8)'a', n.res());
        }

    void emitAggBuild(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || !isAggTy(n.res().ty()) || !hasSlot(n.res()))
            return;
        IRLayout* l = layoutOf(n.res().ty());
        if (l == (IRLayout*)0)
            return;
        u32 base = slotOf(n.res());
        for (u32 i = (u32)0; i < n.ops().count() && i < l.fieldCount(); i = i + (u32)1)
            {
            u32 fw = fieldWidth(l.typeAt(i));
            if (fw == (u32)0)
                fw = (u32)8;
            if (fw > (u32)8)
                fw = (u32)8;
            loadZX((IROperand*)n.ops().get(i), (u8)'a');
            _out.appendFormat("\tmov\t[rbp-%lu], %s\n", base - fieldOffset(l, i),
                              reg((u8)'a', fw).cString());
            }
        }

    void emitAggExtract(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        IROperand* ix = (IROperand*)n.ops().get((u32)1);
        if (ix.kind() != (u8)OPK_IMMI)
            return;
        if (src.kind() != (u8)OPK_USE || src.val() == (IRValue*)0 || !hasSlot(src.val()))
            return;
        IRLayout* l = layoutOf(src.val().ty());
        if (l == (IRLayout*)0)
            return;
        u32 addr = slotOf(src.val()) - fieldOffset(l, (u32)ix.imm());
        u32 rw = widthOfValue(n.res());
        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", reg((u8)'a', rw).cString(), addr);
        store((u8)'a', n.res());
        }

    // The callee comes from the receiver's vtable: [recv] gives the table, and
    // [vtbl + slot*8] the function pointer. Otherwise the same marshalling as a
    // plain call, then an indirect call through r11.
    void emitVTblDispatch(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            return;
        IROperand* slotOp = (IROperand*)n.ops().get((u32)1);
        if (slotOp.kind() != (u8)OPK_IMMI)
            return;
        if (_win64)
            {
            emitWin64VTblDispatch(n, slotOp);
            return;
            }
        u32 argEnd = n.ops().count();
        if (argEnd > (u32)2)
            {
            IROperand* last = (IROperand*)n.ops().get(argEnd - (u32)1);
            if (last.kind() == (u8)OPK_USE && last.val() != (IRValue*)0 && isMemTy(last.val().ty()))
                argEnd = argEnd - (u32)1;
            }
        Array* args = new Array();
        args.add((Object*)(IROperand*)n.ops().get((u32)0)); // the receiver is argument 0
        for (u32 i = (u32)2; i < argEnd; i = i + (u32)1)
            args.add(n.ops().get(i));
        Array* ir64 = sysvArgRegs();
        Array* ir32 = sysvArgRegs32();
        // A >16-byte aggregate result is MEMORY class: rdi carries the hidden
        // result pointer, so the receiver and every GP argument shift right by
        // one (the callee prologue shifts identically off hasSret).
        bool vMemRet = n.res() != (IRValue*)0 && returnsSysVMemAgg(n.res().ty());
        // uxkit/033: System V passes integer/pointer arguments past r9 on the
        // STACK, and this path used to marshal only what fitted in registers —
        // every argument from the 7th on (the receiver included) was silently
        // dropped, along with the `sub rsp` that reserves room for them, so the
        // callee read its own caller's leftovers. Only the INDIRECT path was
        // wrong: a class-typed call devirtualises to a direct one, and at -O2+
        // the inliner removes it, so it took a protocol receiver and seven
        // arguments to show at all. Same pre-pass as the direct path, so the
        // two agree by construction.
        u32 cIreg = vMemRet ? (u32)1 : (u32)0;
        u32 cFreg = (u32)0;
        u32 nstack = (u32)0;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IROperand* a = (IROperand*)args.get(i);
            String* t = a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 ? a.val().ty() : (String*)0;
            if (isAggTy(t))
                {
                u32 nr = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (cIreg + nr <= (u32)6)
                    cIreg = cIreg + nr;
                }
            else if (isFloatTy(t) && cFreg < (u32)8)
                {
                cFreg = cFreg + (u32)1;
                }
            else if (cIreg < (u32)6)
                {
                cIreg = cIreg + (u32)1;
                }
            else
                {
                nstack = nstack + (u32)1;
                }
            }
        u32 vResv = ((nstack * (u32)8) + (u32)15) & ~(u32)15; // 16-align
        if (vResv != (u32)0)
            _out.appendFormat("\tsub\trsp, %lu\n", vResv);

        u32 ireg = vMemRet ? (u32)1 : (u32)0;
        u32 freg = (u32)0;
        u32 sidx = (u32)0;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IROperand* a = (IROperand*)args.get(i);
            String* t = a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 ? a.val().ty() : (String*)0;
            if (isAggTy(t))
                {
                // A by-value aggregate — INCLUDING a two-word bound method
                // (receiver, code) — occupies ceil(size/8) consecutive GP
                // argument registers, the same private convention the plain call
                // path uses. Loading a single register per argument truncated a
                // 16-byte `^` to its receiver word and dropped the code word,
                // which only ever showed across a shared object, since a local
                // call devirtualises to a direct one.
                u32 nregs = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (hasSlot(a.val()) && ireg + nregs <= (u32)6)
                    {
                    for (u32 k = (u32)0; k < nregs; k = k + (u32)1)
                        {
                        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n",
                                          ((String*)ir64.get(ireg)).cString(),
                                          slotOf(a.val()) - (u32)8 * k);
                        ireg = ireg + (u32)1;
                        }
                    }
                }
            else if (isFloatTy(t) && freg < (u32)8)
                {
                String* x = String.withCString("xmm");
                x.appendFormat("%lu", freg);
                loadF(a, x);
                freg = freg + (u32)1;
                }
            else if (ireg < (u32)6)
                {
                readArgOp(a, (String*)ir64.get(ireg), (String*)ir32.get(ireg));
                ireg = ireg + (u32)1;
                }
            else
                {
                // Through rax into the reserved area — [rsp+0], [rsp+8], … in
                // source order, exactly as the direct path does. rax is free
                // scratch: it is reloaded with the receiver below.
                loadZX(a, (u8)'a');
                _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)8 * sidx);
                sidx = sidx + (u32)1;
                }
            }
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendCString("\tmov\tr11, [rax]\n"); // the vtable at object+0
        _out.appendFormat("\tmov\tr11, [r11 + %ld]\n", slotOp.imm() * (i32)8);
        _out.appendFormat("\tmov\teax, %lu\n", freg); // al = the vector-argument count
        if (vMemRet && hasSlot(n.res()))              // hidden sret → rdi = &result slot
            _out.appendFormat("\tlea\trdi, [rbp-%lu]\n", slotOf(n.res()));
        _out.appendCString("\tcall\tr11\n");
        // Reclaim the outgoing stack-argument area (uxkit/033 — this path used
        // to reserve none).
        if (vResv != (u32)0)
            _out.appendFormat("\tadd\trsp, %lu\n", vResv);
        if (vMemRet)
            return; // result already written through sret into its slot
        captureResult(n);
        }

    // Protocol dispatch (bug 201): a `Proto*` receiver reaches its method through
    // the per-class ITABLE, whose layout is unit-independent (protocol id + the
    // method's declaration index), so a split build in which each object numbers
    // its vtables from source still agrees. Operands: [recv, protoId(immU),
    // index(immU16), args..., mem]. Marshalling is emitVTblDispatch's verbatim;
    // only the callee resolution differs — an inline walk of the itable
    // (vtable header entry 1 = the (protoId,&table) list, 0-terminated) instead
    // of a fixed vtable slot. arm9 does the same through a runtime helper.
    void emitProtoDispatchX86(IRFunc* fn, IRInsn* n)
        {
        if (n.ops().count() < (u32)3)
            return;
        IROperand* pidOp = (IROperand*)n.ops().get((u32)1);
        IROperand* idxOp = (IROperand*)n.ops().get((u32)2);
        if (idxOp.kind() != (u8)OPK_IMMI)
            return;
        u32 argEnd = n.ops().count();
        if (argEnd > (u32)3)
            {
            IROperand* last = (IROperand*)n.ops().get(argEnd - (u32)1);
            if (last.kind() == (u8)OPK_USE && last.val() != (IRValue*)0 && isMemTy(last.val().ty()))
                argEnd = argEnd - (u32)1;
            }
        Array* args = new Array();
        args.add((Object*)(IROperand*)n.ops().get((u32)0)); // the receiver is argument 0
        for (u32 i = (u32)3; i < argEnd; i = i + (u32)1)
            args.add(n.ops().get(i));
        Array* ir64 = sysvArgRegs();
        Array* ir32 = sysvArgRegs32();
        bool vMemRet = n.res() != (IRValue*)0 && returnsSysVMemAgg(n.res().ty());
        u32 cIreg = vMemRet ? (u32)1 : (u32)0;
        u32 cFreg = (u32)0;
        u32 nstack = (u32)0;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IROperand* a = (IROperand*)args.get(i);
            String* t = a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 ? a.val().ty() : (String*)0;
            if (isAggTy(t))
                {
                u32 nr = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (cIreg + nr <= (u32)6)
                    cIreg = cIreg + nr;
                }
            else if (isFloatTy(t) && cFreg < (u32)8)
                {
                cFreg = cFreg + (u32)1;
                }
            else if (cIreg < (u32)6)
                {
                cIreg = cIreg + (u32)1;
                }
            else
                {
                nstack = nstack + (u32)1;
                }
            }
        u32 vResv = ((nstack * (u32)8) + (u32)15) & ~(u32)15;
        if (vResv != (u32)0)
            _out.appendFormat("\tsub\trsp, %lu\n", vResv);
        u32 ireg = vMemRet ? (u32)1 : (u32)0;
        u32 freg = (u32)0;
        u32 sidx = (u32)0;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IROperand* a = (IROperand*)args.get(i);
            String* t = a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 ? a.val().ty() : (String*)0;
            if (isAggTy(t))
                {
                u32 nregs = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (hasSlot(a.val()) && ireg + nregs <= (u32)6)
                    {
                    for (u32 k = (u32)0; k < nregs; k = k + (u32)1)
                        {
                        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n",
                                          ((String*)ir64.get(ireg)).cString(),
                                          slotOf(a.val()) - (u32)8 * k);
                        ireg = ireg + (u32)1;
                        }
                    }
                }
            else if (isFloatTy(t) && freg < (u32)8)
                {
                String* x = String.withCString("xmm");
                x.appendFormat("%lu", freg);
                loadF(a, x);
                freg = freg + (u32)1;
                }
            else if (ireg < (u32)6)
                {
                readArgOp(a, (String*)ir64.get(ireg), (String*)ir32.get(ireg));
                ireg = ireg + (u32)1;
                }
            else
                {
                loadZX(a, (u8)'a');
                _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)8 * sidx);
                sidx = sidx + (u32)1;
                }
            }
        // ── itable walk: recv -> vtable -> itable(entry 1) -> match protoId -> &table -> [index]
        u32 lbl = _arcLabel;
        _arcLabel = _arcLabel + (u32)1;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a'); // rax = recv
        _out.appendCString("\tmov\tr11, [rax]\n");        // vtable
        _out.appendCString("\tmov\tr11, [r11 + 8]\n");    // itable ptr (header entry 1)
        _out.appendFormat(".L_it_%lu:\n", lbl);
        _out.appendCString("\tmov\tr10, [r11]\n"); // entry protoId
        _out.appendFormat("\tcmp\tr10d, %lu\n", pidOp.imm() & (u32)$FFFF_FFFF);
        _out.appendFormat("\tje\t.L_ith_%lu\n", lbl);
        _out.appendCString("\ttest\tr10, r10\n");
        _out.appendFormat("\tjz\t.L_itm_%lu\n", lbl); // 0 terminates -> miss
        _out.appendCString("\tadd\tr11, 16\n");
        _out.appendFormat("\tjmp\t.L_it_%lu\n", lbl);
        _out.appendFormat(".L_itm_%lu:\n", lbl);
        _out.appendCString("\txor\tr11d, r11d\n"); // miss: null (a non-optional never misses)
        _out.appendFormat("\tjmp\t.L_itc_%lu\n", lbl);
        _out.appendFormat(".L_ith_%lu:\n", lbl);
        _out.appendCString("\tmov\tr11, [r11 + 8]\n"); // &table
        _out.appendFormat("\tmov\tr11, [r11 + %ld]\n", idxOp.imm() * (i32)8);
        _out.appendFormat(".L_itc_%lu:\n", lbl);
        _out.appendFormat("\tmov\teax, %lu\n", freg); // al = vector-arg count
        if (vMemRet && hasSlot(n.res()))
            _out.appendFormat("\tlea\trdi, [rbp-%lu]\n", slotOf(n.res()));
        _out.appendCString("\tcall\tr11\n");
        if (vResv != (u32)0)
            _out.appendFormat("\tadd\trsp, %lu\n", vResv);
        if (vMemRet)
            return;
        captureResult(n);
        }

    // Protocol dispatch under the Win64 ABI. The marshalling is the direct
    // path's (`emitWin64Call`) — 32-byte shadow store, one POSITIONAL counter
    // spanning integers and floats, a >8-byte struct passed BY REFERENCE into
    // a caller-owned copy, positions 4+ on the stack at [rsp+32] — and the only
    // difference is where the callee comes from: the receiver's vtable rather
    // than a symbol.
    //
    // This was `unsupported: VTblDispatch:win64` — a flat refusal — so a third
    // of UXKit's win64 suite could not be built at all while the same sources
    // built and passed on 0.4 (uxkit bug 034-A). The refusal predates `-A
    // win64` being wired into the shipped driver, which is why nothing noticed:
    // until then this back end was never asked.
    void emitWin64VTblDispatch(IRInsn* n, IROperand* slotOp)
        {
        u32 argEnd = n.ops().count();
        if (argEnd > (u32)2)
            {
            IROperand* last = (IROperand*)n.ops().get(argEnd - (u32)1);
            if (last.kind() == (u8)OPK_USE && last.val() != (IRValue*)0 && isMemTy(last.val().ty()))
                argEnd = argEnd - (u32)1;
            }
        Array* args = new Array();
        args.add((Object*)(IROperand*)n.ops().get((u32)0)); // the receiver is argument 0
        for (u32 i = (u32)2; i < argEnd; i = i + (u32)1)
            args.add(n.ops().get(i));

        bool bigRet = n.res() != (IRValue*)0 && returnsBigAgg(n.res().ty());
        u32 cpos = bigRet ? (u32)1 : (u32)0;
        u32 wstack = (u32)0;
        u32 copyBytes = (u32)0;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            String* t = vtblArgTy((IROperand*)args.get(i));
            if (isAggTy(t) && aggSize(layoutOf(t)) > (u32)8)
                copyBytes = copyBytes + ((aggSize(layoutOf(t)) + (u32)15) & ~(u32)15);
            if (cpos >= (u32)4)
                wstack = wstack + (u32)1;
            cpos = cpos + (u32)1;
            }
        u32 copyBase = (u32)32 + wstack * (u32)8;
        u32 resv = ((copyBase + copyBytes) + (u32)15) & ~(u32)15;
        _out.appendFormat("\tsub\trsp, %lu\n", resv);

        Array* ir4 = win64ArgRegs();
        Array* ir4d = win64ArgRegs32();
        u32 pos = bigRet ? (u32)1 : (u32)0;
        u32 sstack = (u32)0;
        u32 copyOff = copyBase;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IROperand* a = (IROperand*)args.get(i);
            String* t = vtblArgTy(a);
            if (isAggTy(t) && aggSize(layoutOf(t)) > (u32)8)
                {
                u32 sz = aggSize(layoutOf(t));
                if (hasSlot(a.val()))
                    copyQwords(sz, slotOf(a.val()), copyOff);
                if (pos < (u32)4)
                    {
                    _out.appendFormat("\tlea\t%s, [rsp+%lu]\n",
                                      ((String*)ir4.get(pos)).cString(), copyOff);
                    }
                else
                    {
                    _out.appendFormat("\tlea\trax, [rsp+%lu]\n", copyOff);
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                copyOff = copyOff + ((sz + (u32)15) & ~(u32)15);
                pos = pos + (u32)1;
                continue;
                }
            // <=8 bytes: by value
            if (isAggTy(t))
                {
                if (pos < (u32)4)
                    {
                    if (hasSlot(a.val()))
                        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n",
                                          ((String*)ir4.get(pos)).cString(), slotOf(a.val()));
                    }
                else if (hasSlot(a.val()))
                    {
                    _out.appendFormat("\tmov\trax, [rbp-%lu]\n", slotOf(a.val()));
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                pos = pos + (u32)1;
                continue;
                }
            if (isFloatTy(t))
                {
                if (pos < (u32)4)
                    {
                    String* x = String.withCString("xmm");
                    x.appendFormat("%lu", pos);
                    loadF(a, x);
                    }
                else
                    {
                    loadZX(a, (u8)'a');
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                pos = pos + (u32)1;
                continue;
                }
            if (pos < (u32)4)
                {
                readArgOp(a, (String*)ir4.get(pos), (String*)ir4d.get(pos));
                }
            else
                {
                loadZX(a, (u8)'a');
                _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                sstack = sstack + (u32)1;
                }
            pos = pos + (u32)1;
            }
        // The callee, from the receiver's vtable. rax is free scratch here —
        // it is not an argument register in this ABI, and every argument above
        // has already been placed.
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendCString("\tmov\tr11, [rax]\n"); // the vtable at object+0
        _out.appendFormat("\tmov\tr11, [r11 + %ld]\n", slotOp.imm() * (i32)8);
        if (bigRet && hasSlot(n.res())) // the hidden result pointer
            _out.appendFormat("\tlea\trcx, [rbp-%lu]\n", slotOf(n.res()));
        _out.appendCString("\tcall\tr11\n");
        _out.appendFormat("\tadd\trsp, %lu\n", resv);
        if (bigRet)
            return; // already written through the sret
        captureResult(n);
        }

    // The declared type of a dispatch argument, or null when it has none.
    static String* vtblArgTy(IROperand* a)
        {
        if (a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0)
            return a.val().ty();
        return (String*)0;
        }

    // The same address computation without the call — the code word of
    // `&obj.method`. A null receiver yields 0 rather than faulting, so
    // `&nullDelegate.m` is falsy instead of a crash; an empty slot is already 0
    // in the emitted table, which is what makes an unimplemented `optional`
    // method falsy.
    void emitVTblLoad(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            return;
        IROperand* slotOp = (IROperand*)n.ops().get((u32)1);
        if (slotOp.kind() != (u8)OPK_IMMI)
            return;
        if (n.res() == (IRValue*)0 || isMemTy(n.res().ty()))
            return;
        u32 lbl = _arcLabel;
        _arcLabel = _arcLabel + (u32)1;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendCString("\txor\tr11, r11\n"); // the default: null
        _out.appendCString("\ttest\trax, rax\n");
        _out.appendFormat("\tjz\t.L_vtl_%lu\n", lbl);
        _out.appendCString("\tmov\tr11, [rax]\n");
        _out.appendFormat("\tmov\tr11, [r11 + %ld]\n", slotOp.imm() * (i32)8);
        _out.appendFormat(".L_vtl_%lu:\n", lbl);
        _out.appendCString("\tmov\trax, r11\n");
        store((u8)'a', n.res());
        }

    // Take the address of a protocol method (&s.method) through the itable
    // (bug 201). Same unit-independent walk as ProtoDispatch, but STORE the
    // resolved pointer instead of calling it. Null receiver, absent itable, a
    // miss (unimplemented optional), or a null slot all yield null — which is
    // exactly what a `&s.method` null test / respondsTo relies on. r10 is the
    // walk cursor, r11 the result, rax scratch.
    void emitProtoLoadX86(IRInsn* n)
        {
        if (n.ops().count() < (u32)3)
            return;
        IROperand* pidOp = (IROperand*)n.ops().get((u32)1);
        IROperand* idxOp = (IROperand*)n.ops().get((u32)2);
        if (pidOp.kind() != (u8)OPK_IMMI || idxOp.kind() != (u8)OPK_IMMI)
            return;
        if (n.res() == (IRValue*)0 || isMemTy(n.res().ty()))
            return;
        u32 lbl = _arcLabel;
        _arcLabel = _arcLabel + (u32)1;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a'); // rax = recv
        _out.appendCString("\txor\tr11d, r11d\n");        // result default null
        _out.appendCString("\ttest\trax, rax\n");
        _out.appendFormat("\tjz\t.L_pld_%lu\n", lbl);  // null recv
        _out.appendCString("\tmov\tr10, [rax]\n");     // vtable
        _out.appendCString("\tmov\tr10, [r10 + 8]\n"); // itable ptr (header entry 1)
        _out.appendCString("\ttest\tr10, r10\n");
        _out.appendFormat("\tjz\t.L_pld_%lu\n", lbl); // no itable
        _out.appendFormat(".L_pli_%lu:\n", lbl);
        _out.appendCString("\tmov\trax, [r10]\n"); // entry protoId
        _out.appendFormat("\tcmp\teax, %lu\n", pidOp.imm() & (u32)$FFFF_FFFF);
        _out.appendFormat("\tje\t.L_plh_%lu\n", lbl);
        _out.appendCString("\ttest\trax, rax\n");
        _out.appendFormat("\tjz\t.L_pld_%lu\n", lbl); // terminator -> miss
        _out.appendCString("\tadd\tr10, 16\n");
        _out.appendFormat("\tjmp\t.L_pli_%lu\n", lbl);
        _out.appendFormat(".L_plh_%lu:\n", lbl);
        _out.appendCString("\tmov\tr10, [r10 + 8]\n");                        // &table
        _out.appendFormat("\tmov\tr11, [r10 + %ld]\n", idxOp.imm() * (i32)8); // method ptr
        _out.appendFormat(".L_pld_%lu:\n", lbl);
        _out.appendCString("\tmov\trax, r11\n");
        store((u8)'a', n.res());
        }

    // The argument registers are never home registers, so materialising them in
    // order cannot clobber an earlier one.
    void emitMemHelper(IRInsn* n, String* sym)
        {
        if (n.ops().count() < (u32)3)
            return;
        Array* ir64 = _win64 ? win64ArgRegs() : sysvArgRegs();
        Array* ir32 = _win64 ? win64ArgRegs32() : sysvArgRegs32();
        for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1)
            readArgOp((IROperand*)n.ops().get(i), (String*)ir64.get(i), (String*)ir32.get(i));
        emitRTCall(sym);
        }

    static Array* win64ArgRegs32(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("ecx"));
        a.add((Object*)String.withCString("edx"));
        a.add((Object*)String.withCString("r8d"));
        a.add((Object*)String.withCString("r9d"));
        return a;
        }

    // An asm body is emitted verbatim. Homing and address folding are already
    // suppressed for any function containing one, so a body may refer to locals
    // by their fixed rbp-relative slots.
    void emitAsm(IRInsn* n)
        {
        u32 cid = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_CPOOL)
                {
                cid = o.cid();
                break;
                }
            }
        if (cid == (u32)$FFFF_FFFF || _m == (IRModule*)0 || cid >= _m.consts().count())
            return;
        String* text = resolveAsmLocals(bytesToString((Array*)_m.consts().get(cid)));
        _out.appendCString("\t# inline asm\n");
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (t.byteLength() > (u32)0)
                _out.appendFormat("\t%s\n", t.cString());
            }
        }

    String* resolveAsmLocals(String* text)
        {
        String* marker = String.withCString("{{XTLOCAL:");
        if (text.byteIndexOf(marker) == (u32)$FFFF_FFFF)
            return text;
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < text.byteLength())
            {
            u32 at = text.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF)
                {
                out.append(text.substringFromByte(i));
                break;
                }
            out.append(text.substringBytes(i, at - i));
            u32 j = at + marker.byteLength();
            u32 vid = (u32)0;
            while (j < text.byteLength() && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9')
                {
                vid = vid * (u32)10 + (u32)(text.byteAt(j) - (u8)'0');
                j = j + (u32)1;
                }
            if (j + (u32)1 < text.byteLength() && text.byteAt(j) == (u8)'}')
                j = j + (u32)2;
            IRValue* v = _fn.valueWithId(vid);
            if (v != (IRValue*)0 && hasSlot(v))
                out.appendFormat("rbp-%lu", slotOf(v));
            else
                out.appendCString("rbp");
            i = j;
            }
        return out;
        }

    static String* bytesToString(Array* bytes)
        {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            o.appendByte((u8)((Number*)bytes.get(i)).asU32());
        return o;
        }

    // ── Copy-propagation peephole ────────────────────────────────────────
    //
    // A `mov <scratch>, <reg>` whose value is read once can vanish: the
    // consumer reads the source register directly. This is what turns the
    // stack-machine shape the emitters produce — load a pointer into rax, then
    // dereference rax — into the single memory operand a homed pointer allows.
    //
    // The scratch registers are rax, rcx and rdx, and the soundness argument is
    // that a scratch register is NEVER live INTO a basic block: the back end
    // reloads it before use at every branch target. So the only reads of this
    // definition are on the straight-line path until it is redefined.
    Map* _canon; // a register spelling -> its 64-bit family name
    Map* _views; // a family name -> every spelling of it

    void buildRegTables(void)
        {
        if (_canon != (Map*)0)
            return;
        _canon = new Map();
        _views = new Map();
        addFamily("rax", "rax eax ax al");
        addFamily("rbx", "rbx ebx bx bl");
        addFamily("rcx", "rcx ecx cx cl");
        addFamily("rdx", "rdx edx dx dl");
        addFamily("rsi", "rsi esi si sil");
        addFamily("rdi", "rdi edi di dil");
        addFamily("rbp", "rbp ebp bp bpl");
        addFamily("rsp", "rsp esp sp spl");
        for (u32 n = (u32)8; n <= (u32)15; n = n + (u32)1)
            {
            String* c = String.withCString("r");
            c.appendFormat("%lu", n);
            String* list = String.withCString(c.cString());
            list.appendCString(" ");
            list.append(c);
            list.appendCString("d ");
            list.append(c);
            list.appendCString("w ");
            list.append(c);
            list.appendCString("b");
            addFamily(c.cString(), list.cString());
            }
        }

    void addFamily(string canon, string spellings)
        {
        String* c = String.withCString(canon);
        Array* parts = String.withCString(spellings).splitOnByte((u8)' ');
        Array* views = new Array();
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* sp = (String*)parts.get(i);
            if (sp.byteLength() == (u32)0)
                continue;
            _canon.set((Hashable*)sp, (Object*)c);
            views.add((Object*)sp);
            }
        _views.set((Hashable*)c, (Object*)views);
        }

    String* canonOf(String* r)
        {
        buildRegTables();
        Object* o = _canon.get((Hashable*)r);
        return o == (Object*)0 ? (String*)0 : (String*)o;
        }

    // Whole-token presence: `r12` must not match inside `r12d`, and `al` must
    // not match inside `flags`.
    static bool mentions(String* s, String* tok)
        {
        u32 at = s.byteIndexOf(tok);
        while (at != (u32)$FFFF_FFFF)
            {
            u32 e = at + tok.byteLength();
            u8 before = at > (u32)0 ? s.byteAt(at - (u32)1) : (u8)' ';
            u8 after = e < s.byteLength() ? s.byteAt(e) : (u8)' ';
            if (!isWordChar(before) && !isWordChar(after))
                return true;
            at = s.byteIndexOf(tok, e);
            }
        return false;
        }

    static bool isWordChar(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }

    static String* substTok(String* s, String* from, String* to)
        {
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < s.byteLength())
            {
            u32 at = s.byteIndexOf(from, i);
            if (at == (u32)$FFFF_FFFF)
                {
                out.append(s.substringFromByte(i));
                break;
                }
            u32 e = at + from.byteLength();
            u8 before = at > (u32)0 ? s.byteAt(at - (u32)1) : (u8)' ';
            u8 after = e < s.byteLength() ? s.byteAt(e) : (u8)' ';
            out.append(s.substringBytes(i, at - i));
            if (!isWordChar(before) && !isWordChar(after))
                out.append(to);
            else
                out.append(from);
            i = e;
            }
        return out;
        }

    // A line split into (mnemonic, operands), or null for a label, directive,
    // comment or blank. Operands split on ", " — this back end never emits a
    // comma inside a `[base + idx*scale]` operand.
    static Array* parseLine(String* line, String** mnem)
        {
        String* t = line.trimmed();
        if (t.byteLength() == (u32)0 || t.hasSuffix(String.withCString(":")) || t.hasPrefix(String.withCString(".")) || t.hasPrefix(String.withCString("#")))
            return (Array*)0;
        u32 sp = t.indexOfByte((u8)' ');
        u32 tb = t.indexOfByte((u8)'\t');
        if (tb < sp)
            sp = tb;
        if (sp == (u32)$FFFF_FFFF)
            {
            *mnem = t;
            return new Array();
            }
        *mnem = t.substringBytes((u32)0, sp);
        Array* raw = t.substringFromByte(sp + (u32)1).trimmed().splitOnByte((u8)',');
        Array* ops = new Array();
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            ops.add((Object*)((String*)raw.get(i)).trimmed());
        return ops;
        }

    static bool inWordList(string list, String* m)
        {
        String* hay = String.withCString(" ");
        hay.appendCString(list);
        hay.appendCString(" ");
        String* needle = String.withCString(" ");
        needle.append(m);
        needle.appendCString(" ");
        return hay.byteIndexOf(needle) != (u32)$FFFF_FFFF;
        }

    // Mnemonics whose operand 0 is a written destination register.
    static bool writesOp0(String* m)
        {
        return inWordList("mov movzx movsx movsxd lea add sub imul and or xor neg not sar shl shr inc dec cmove cmovne cmovl cmovg cmovle cmovge cmovb cmova cmovbe cmovae", m);
        }

    // Control transfers — a scratch register is dead out past them.
    static bool isCtrl(String* m)
        {
        return m.hasPrefix(String.withCString("j")) || m.equals(String.withCString("call")) || m.equals(String.withCString("ret"));
        }

    // Mnemonics with IMPLICIT rax/rdx clobbers, invisible in the operand list —
    // a hard barrier for a scan that reasons only about explicit operands.
    static bool implicitClobber(String* m)
        {
        return inWordList("div idiv mul cqo cdq cwd cdqe cbw cwde", m);
        }

    // A variable shift's count MUST be cl, so a `mov cl, r` feeding one cannot
    // be forwarded — `shl eax, r12b` is not an instruction.
    static bool isShift(String* m)
        {
        return inWordList("shl shr sar sal rol ror rcl rcr", m);
        }


    // ── Fallthrough peephole ─────────────────────────────────────────────
    //
    // Drop `jmp L` when L is the very next label, and invert a conditional
    // whose TAKEN target is next so the fall-through is the other side. This
    // back end had no such pass: every block ended in a taken branch even when
    // its target immediately followed, so mem_copy's vectorised body carried
    // `jmp .L_main_bb_7_for_body_vu1` as one instruction in five. arm64 has
    // had this since it was written.
    String* ftInvert(String* cc)
        {
        if (cc.equals(String.withCString("e")))   return String.withCString("ne");
        if (cc.equals(String.withCString("ne")))  return String.withCString("e");
        if (cc.equals(String.withCString("z")))   return String.withCString("nz");
        if (cc.equals(String.withCString("nz")))  return String.withCString("z");
        if (cc.equals(String.withCString("b")))   return String.withCString("ae");
        if (cc.equals(String.withCString("ae")))  return String.withCString("b");
        if (cc.equals(String.withCString("be")))  return String.withCString("a");
        if (cc.equals(String.withCString("a")))   return String.withCString("be");
        if (cc.equals(String.withCString("l")))   return String.withCString("ge");
        if (cc.equals(String.withCString("ge")))  return String.withCString("l");
        if (cc.equals(String.withCString("le")))  return String.withCString("g");
        if (cc.equals(String.withCString("g")))   return String.withCString("le");
        if (cc.equals(String.withCString("s")))   return String.withCString("ns");
        if (cc.equals(String.withCString("ns")))  return String.withCString("s");
        if (cc.equals(String.withCString("c")))   return String.withCString("nc");
        if (cc.equals(String.withCString("nc")))  return String.withCString("c");
        if (cc.equals(String.withCString("o")))   return String.withCString("no");
        if (cc.equals(String.withCString("no")))  return String.withCString("o");
        if (cc.equals(String.withCString("p")))   return String.withCString("np");
        if (cc.equals(String.withCString("np")))  return String.withCString("p");
        return (String*)0;
        }

    // The label a line declares, or 0.
    String* ftLabelOf(String* ln)
        {
        String* t = ln.trimmed();
        if (t.byteLength() < (u32)2)
            return (String*)0;
        if (t.byteAt(t.byteLength() - (u32)1) != (u8)':')
            return (String*)0;
        return t.substringToByte(t.byteLength() - (u32)1);
        }

    // The next line that is neither blank nor a directive: .p2align sits
    // between a jump and the label it falls into once loop heads are aligned.
    i32 ftNextReal(Array* lines, u32 i)
        {
        for (u32 j = i + (u32)1; j < lines.count(); j = j + (u32)1)
            {
            String* t = ((String*)lines.get(j)).trimmed();
            if (t.byteLength() == (u32)0)
                continue;
            if (t.hasPrefix(String.withCString(".p2align")))
                continue;
            if (t.hasPrefix(String.withCString("#")))
                continue;
            return (i32)j;
            }
        return (i32)-1;
        }

    // The target of `jmp X`, or 0 when the line is not an unconditional jump.
    String* ftJmpTarget(String* t)
        {
        if (!t.hasPrefix(String.withCString("jmp")))
            return (String*)0;
        if (t.byteLength() < (u32)5)
            return (String*)0;
        u8 c = t.byteAt((u32)3);
        if (c != (u8)'\t' && c != (u8)' ')
            return (String*)0;
        return t.substringFromByte((u32)4).trimmed();
        }

    String* peepholeFallthrough(String* text)
        {
        Array* lines = text.splitOnByte((u8)'\n');
        bool again = true;
        while (again)
            {
            again = false;
            for (u32 i = (u32)0; i < lines.count() && !again; i = i + (u32)1)
                {
                String* t = ((String*)lines.get(i)).trimmed();
                String* tgt = ftJmpTarget(t);
                if (tgt != (String*)0)
                    {
                    i32 j = ftNextReal(lines, i);
                    if (j < (i32)0)
                        continue;
                    String* lb = ftLabelOf((String*)lines.get((u32)j));
                    if (lb != (String*)0 && lb.equals(tgt))
                        {
                        lines.removeAt(i);
                        again = true;
                        }
                    continue;
                    }
                if (t.byteLength() < (u32)3 || t.byteAt((u32)0) != (u8)'j')
                    continue;
                u32 sp = (u32)0;
                for (u32 q = (u32)1; q < t.byteLength() && sp == (u32)0; q = q + (u32)1)
                    if (t.byteAt(q) == (u8)'\t' || t.byteAt(q) == (u8)' ')
                        sp = q;
                if (sp == (u32)0)
                    continue;
                String* ic = ftInvert(t.substringBytes((u32)1, sp - (u32)1));
                if (ic == (String*)0)
                    continue;
                String* LT = t.substringFromByte(sp).trimmed();
                i32 j = ftNextReal(lines, i);
                if (j < (i32)0)
                    continue;
                String* LF = ftJmpTarget(((String*)lines.get((u32)j)).trimmed());
                if (LF == (String*)0)
                    continue;
                i32 k = ftNextReal(lines, (u32)j);
                if (k < (i32)0)
                    continue;
                String* nextLbl = ftLabelOf((String*)lines.get((u32)k));
                if (nextLbl == (String*)0)
                    continue;
                if (nextLbl.equals(LF))
                    {
                    lines.removeAt((u32)j);
                    again = true;
                    continue;
                    }
                if (nextLbl.equals(LT))
                    {
                    String* nl = String.withCString("\tj");
                    nl.append(ic);
                    nl.appendCString("\t");
                    nl.append(LF);
                    lines.set(i, (Object*)nl);
                    lines.removeAt((u32)j);
                    again = true;
                    }
                }
            }
        String* out = String.withCString("");
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                out.appendCString("\n");
            out.append((String*)lines.get(i));
            }
        return out;
        }

    String* peepholeCopyProp(String* text)
        {
        Array* lines = text.splitOnByte((u8)'\n');
        bool again = true;
        while (again)
            {
            again = false;
            for (u32 i = (u32)0; i + (u32)1 < lines.count() && !again; i = i + (u32)1)
                {
                String* mm = (String*)0;
                Array* mo = parseLine((String*)lines.get(i), &mm);
                if (mo == (Array*)0 || mo.count() != (u32)2)
                    continue;
                if (!mm.equals(String.withCString("mov")))
                    continue;
                String* D = (String*)mo.get((u32)0);
                String* S = (String*)mo.get((u32)1);
                if (D.equals(S))
                    continue;
                String* dcanon = canonOf(D);
                if (dcanon == (String*)0)
                    continue; // D is not a bare register
                if (!dcanon.equals(String.withCString("rax")) && !dcanon.equals(String.withCString("rcx")) && !dcanon.equals(String.withCString("rdx")))
                    continue; // D must be scratch
                String* scanon = canonOf(S);
                if (scanon == (String*)0)
                    continue; // S must be a bare register
                i32 cons = findConsumer(lines, i, D, dcanon, scanon);
                if (cons < (i32)0)
                    continue;
                String* cm = (String*)0;
                Array* co = parseLine((String*)lines.get((u32)cons), &cm);
                if (co == (Array*)0)
                    continue;
                if (isShift(cm) && dcanon.equals(String.withCString("rcx")))
                    continue;
                bool cWr0 = writesOp0(cm) && co.count() >= (u32)1 && canonOf((String*)co.get((u32)0)) != (String*)0;
                bool used = false;
                Array* no = new Array();
                for (u32 k = (u32)0; k < co.count(); k = k + (u32)1)
                    {
                    String* o = (String*)co.get(k);
                    if ((k > (u32)0 || !cWr0) && mentions(o, D))
                        {
                        no.add((Object*)substTok(o, D, S));
                        used = true;
                        }
                    else
                        {
                        no.add((Object*)o);
                        }
                    }
                if (!used)
                    continue;
                if (!deadAfter(lines, (u32)cons, D, dcanon, cm, co))
                    continue;
                String* line = (String*)lines.get((u32)cons);
                String* rebuilt = line.substringBytes((u32)0, line.byteIndexOf(cm));
                rebuilt.append(cm);
                for (u32 k = (u32)0; k < no.count(); k = k + (u32)1)
                    {
                    rebuilt.appendCString(k == (u32)0 ? "\t" : ", ");
                    rebuilt.append((String*)no.get(k));
                    }
                lines.set((u32)cons, (Object*)rebuilt);
                lines.removeAt(i);
                again = true;
                }
            }
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                o.appendCString("\n");
            o.append((String*)lines.get(i));
            }
        return o;
        }

    // The first line that USES D as a source, through "transparent" lines only.
    // Adjacency is not required: the value is often computed between the move
    // and its store. The scan stops at a control transfer, an implicit clobber,
    // a write to S, a redefinition of D, or a block boundary.
    i32 findConsumer(Array* lines, u32 i, String* D, String* dcanon, String* scanon)
        {
        Array* dviews = viewsOf(dcanon);
        for (u32 j = i + (u32)1; j < lines.count(); j = j + (u32)1)
            {
            String* jm = (String*)0;
            Array* jo = parseLine((String*)lines.get(j), &jm);
            if (jo == (Array*)0)
                {
                if (((String*)lines.get(j)).trimmed().byteLength() == (u32)0)
                    continue;
                return (i32)-1; // a label or directive
                }
            if (isCtrl(jm) || implicitClobber(jm))
                return (i32)-1;
            bool wr0 = writesOp0(jm) && jo.count() >= (u32)1 && canonOf((String*)jo.get((u32)0)) != (String*)0;
            if (wr0)
                {
                String* w = canonOf((String*)jo.get((u32)0));
                if (w.equals(scanon))
                    return (i32)-1; // S clobbered
                }
            bool dInSrc = false;
            for (u32 k = wr0 ? (u32)1 : (u32)0; k < jo.count() && !dInSrc; k = k + (u32)1)
                if (mentionsAny((String*)jo.get(k), dviews))
                    dInSrc = true;
            if (dInSrc)
                {
                // D is an ACCUMULATOR here — also written — so the move is live.
                if (wr0 && canonOf((String*)jo.get((u32)0)).equals(dcanon))
                    return (i32)-1;
                return (i32)j;
                }
            if (wr0 && canonOf((String*)jo.get((u32)0)).equals(dcanon))
                return (i32)-1; // dead store
            }
        return (i32)-1;
        }

    // D's whole register family must be dead after the consumer. A read before
    // any kill means live; a pure redefinition, or reaching the end with no
    // read, means dead. This is what keeps the ARC null check safe:
    // `cmp p, #; jb .skip; add [p-2], 1` has a later `[rax-2]` read, so the
    // move into rax is kept.
    bool deadAfter(Array* lines, u32 cons, String* D, String* dcanon, String* cm, Array* co)
        {
        Array* dviews = viewsOf(dcanon);
        for (u32 j = cons + (u32)1; j < lines.count(); j = j + (u32)1)
            {
            String* jm = (String*)0;
            Array* jo = parseLine((String*)lines.get(j), &jm);
            if (jo == (Array*)0)
                continue; // a label, directive or blank
            if (implicitClobber(jm))
                return false; // a hidden use: assume live
            if (mentionsAny((String*)lines.get(j), dviews))
                {
                // A pure overwrite of exactly D, with D absent from the sources,
                // KILLS the old value before it is read.
                bool pureDef = writesOp0(jm) && jo.count() >= (u32)1 && ((String*)jo.get((u32)0)).equals(D);
                bool srcReads = false;
                if (pureDef)
                    for (u32 k = (u32)1; k < jo.count(); k = k + (u32)1)
                        if (mentionsAny((String*)jo.get(k), dviews))
                            srcReads = true;
                return pureDef && !srcReads;
                }
            }
        return true;
        }

    Array* viewsOf(String* canon)
        {
        buildRegTables();
        Object* o = _views.get((Hashable*)canon);
        return o == (Object*)0 ? new Array() : (Array*)o;
        }

    static bool mentionsAny(String* s, Array* toks)
        {
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            if (mentions(s, (String*)toks.get(i)))
                return true;
        return false;
        }

    // ── Address folding and compare fusion ───────────────────────────────
    //
    // A single-use ElementAddr/FieldAddr folds into its consumer's MEMORY
    // OPERAND, which on this machine is a real addressing mode. A load's
    // consumer has to be adjacent; a STORE's need not be, because the base and
    // index are recomputed at the store site.
    void computeFoldsAndFusion(IRFunc* fn)
        {
        _fold = new Map();
        _fusedCmp = new Map();
        _selSkip = new Map();
        _selCmp = new Map();
        if (_hasAsm)
            return;
        Map* uc = new Map();
        Map* useOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            // Phi operands live in a SEPARATE list from the instructions, and a
            // value consumed only by a loop-carried phi — a pointer advance's
            // back edge — is still multiply-used and must NOT be folded away.
            countIn(uc, useOf, bb.phis());
            countIn(uc, useOf, bb.insns());
            if (bb.term() != (IRInsn*)0)
                countOne(uc, useOf, bb.term());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* ins = bb.insns();
            for (u32 i = (u32)0; i < ins.count(); i = i + (u32)1)
                {
                IRInsn* ea = (IRInsn*)ins.get(i);
                bool isEA = ea.op().equals(String.withCString("ElementAddr"));
                if (!isEA && !ea.op().equals(String.withCString("FieldAddr")))
                    continue;
                if (ea.res() == (IRValue*)0)
                    continue;
                if (useCount(uc, ea.res()) != (u32)1)
                    continue;
                if (isEA)
                    {
                    // Only a power-of-two stride is an x86 scale factor.
                    IROperand* bop = (IROperand*)ea.ops().get((u32)0);
                    u32 st = (u32)1;
                    if (bop.kind() == (u8)OPK_USE && bop.val() != (IRValue*)0)
                        {
                        String* pte = pointeeOf(bop.val().ty());
                        if (pte != (String*)0)
                            st = fieldWidth(pte);
                        }
                    if (st != (u32)1 && st != (u32)2 && st != (u32)4 && st != (u32)8)
                        continue;
                    }
                Object* cu = useOf.get((Hashable*)ea.res());
                if (cu == (Object*)0)
                    continue;
                IRInsn* cons = (IRInsn*)cu;
                if (cons.ops().count() < (u32)1)
                    continue;
                IROperand* p0 = (IROperand*)cons.ops().get((u32)0);
                if (p0.kind() != (u8)OPK_USE || p0.val() != ea.res())
                    continue;
                // (a) An ADJACENT load folds into its source operand.
                if (cons.op().equals(String.withCString("Load")) && i + (u32)1 < ins.count() && (IRInsn*)ins.get(i + (u32)1) == cons && !(cons.res() != (IRValue*)0 && isAggTy(cons.res().ty())))
                    {
                    _fold.set((Hashable*)ea.res(), (Object*)ea);
                    continue;
                    }
                // (b) A store whose ADDRESS is this value folds into its
                // destination operand, adjacent or not. An aggregate store keeps
                // the byte-copy path.
                if (cons.op().equals(String.withCString("Store")) && cons.ops().count() >= (u32)2)
                    {
                    IROperand* vv = (IROperand*)cons.ops().get((u32)1);
                    String* vt = vv.kind() == (u8)OPK_USE && vv.val() != (IRValue*)0
                                     ? vv.val().ty()
                                     : (String*)0;
                    if (isAggTy(vt))
                        continue;
                    _fold.set((Hashable*)ea.res(), (Object*)ea);
                    }
                }
            }
        // A block ending in a CondBranch whose condition is an ICmp that is the
        // block's LAST instruction — so the flags reach the branch untouched —
        // and is read only by that branch.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")))
                continue;
            IROperand* cond = (IROperand*)0;
            for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)term.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK)
                    {
                    cond = o;
                    break;
                    }
                }
            if (cond == (IROperand*)0 || cond.kind() != (u8)OPK_USE)
                continue;
            if (cond.val() == (IRValue*)0 || useCount(uc, cond.val()) != (u32)1)
                continue;
            if (bb.insns().count() == (u32)0)
                continue;
            IRInsn* last = (IRInsn*)bb.insns().get(bb.insns().count() - (u32)1);
            if (!last.op().equals(String.withCString("ICmp")))
                continue;
            if (last.res() != cond.val())
                continue;
            _fusedCmp.set((Hashable*)cond.val(), (Object*)last);
            }
        // Compare-and-select fusion: an ICmp whose ONLY use is a Select
        // condition in the same block. Without it the condition is materialised
        // (setcc/movzx) and then tested AGAIN before the cmov — four
        // instructions to re-derive flags the cmp already set. Fused, the ICmp
        // emits nothing and the compare is re-issued at the Select, whose cmov
        // reads the flags directly. Immediate right-hand side only: the
        // re-issue then needs one scratch register, and rax/rdx are taken.
        for (u32 b2 = (u32)0; b2 < fn.blocks().count(); b2 = b2 + (u32)1)
            {
            IRBlock* bb2 = (IRBlock*)fn.blocks().get(b2);
            Map* defs = new Map();
            for (u32 i2 = (u32)0; i2 < bb2.insns().count(); i2 = i2 + (u32)1)
                {
                IRInsn* in2 = (IRInsn*)bb2.insns().get(i2);
                if (in2.res() != (IRValue*)0)
                    defs.set((Hashable*)in2.res(), (Object*)in2);
                }
            for (u32 i2 = (u32)0; i2 < bb2.insns().count(); i2 = i2 + (u32)1)
                {
                IRInsn* in2 = (IRInsn*)bb2.insns().get(i2);
                if (!in2.op().equals(String.withCString("Select")))
                    continue;
                if (in2.res() == (IRValue*)0 || in2.ops().count() < (u32)3)
                    continue;
                IROperand* c2 = (IROperand*)in2.ops().get((u32)0);
                if (c2.kind() != (u8)OPK_USE || c2.val() == (IRValue*)0)
                    continue;
                if (useCount(uc, c2.val()) != (u32)1)
                    continue;
                IRInsn* cmp2 = (IRInsn*)defs.get((Hashable*)c2.val());
                if (cmp2 == (IRInsn*)0 || !cmp2.op().equals(String.withCString("ICmp")))
                    continue;
                if (cmp2.ops().count() < (u32)2)
                    continue;
                if (_fusedCmp.get((Hashable*)c2.val()) != (Object*)0)
                    continue;
                IROperand* r2 = (IROperand*)cmp2.ops().get((u32)1);
                if (r2.kind() != (u8)OPK_IMMI)
                    continue;
                i64 k2 = r2.imm();
                if (k2 < (i64)-2147483648 || k2 > (i64)2147483647)
                    continue;
                _selSkip.set((Hashable*)c2.val(), (Object*)cmp2);
                _selCmp.set((Hashable*)in2.res(), (Object*)cmp2);
                }
            }
        }

    static void countIn(Map* uc, Map* useOf, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            countOne(uc, useOf, (IRInsn*)list.get(i));
        }

    static void countOne(Map* uc, Map* useOf, IRInsn* n)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            Object* c = uc.get((Hashable*)o.val());
            uc.set((Hashable*)o.val(),
                   (Object*)Number.withU32((c == (Object*)0 ? (u32)0 : ((Number*)c).asU32()) + (u32)1));
            // Only meaningful while the count stays at one.
            useOf.set((Hashable*)o.val(), (Object*)n);
            }
        }

    static u32 useCount(Map* uc, IRValue* v)
        {
        Object* c = uc.get((Hashable*)v);
        return c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
        }

    // ── Calls ────────────────────────────────────────────────────────────
    //
    // Direct: [callee(Sym), arg0, …, mem]. Indirect: operand 0 is a
    // function-pointer use. Banked and cloaked are 6502 concepts and are plain
    // calls on a native target.
    void emitCall(IRFunc* fn, IRInsn* n, bool indirect)
        {
        if (n.ops().count() < (u32)1)
            return;
        IROperand* c0 = (IROperand*)n.ops().get((u32)0);
        if (!indirect && c0.kind() != (u8)OPK_SYM)
            return;
        u32 argEnd = n.ops().count();
        if (argEnd > (u32)1)
            {
            IROperand* last = (IROperand*)n.ops().get(argEnd - (u32)1);
            if (last.kind() == (u8)OPK_USE && last.val() != (IRValue*)0 && isMemTy(last.val().ty()))
                argEnd = argEnd - (u32)1; // drop the mem token
            }
        if (_win64)
            emitWin64Call(fn, n, indirect, argEnd);
        else
            emitSysVCall(fn, n, indirect, argEnd);
        }

    // Win64: the caller reserves a 32-byte shadow store, room for the stack
    // arguments (positions 4 and up), and a copy area for any >8-byte struct,
    // which is passed BY REFERENCE. A single POSITIONAL counter spans integers
    // and floats — each argument, scalar or struct, takes exactly one slot.
    void emitWin64Call(IRFunc* fn, IRInsn* n, bool indirect, u32 argEnd)
        {
        bool bigRet = n.res() != (IRValue*)0 && returnsBigAgg(n.res().ty());
        u32 cpos = bigRet ? (u32)1 : (u32)0;
        u32 wstack = (u32)0;
        u32 copyBytes = (u32)0;
        for (u32 i = (u32)1; i < argEnd; i = i + (u32)1)
            {
            String* t = argTypeOf(n, i);
            if (isAggTy(t) && aggSize(layoutOf(t)) > (u32)8)
                copyBytes = copyBytes + ((aggSize(layoutOf(t)) + (u32)15) & ~(u32)15);
            if (cpos >= (u32)4)
                wstack = wstack + (u32)1;
            cpos = cpos + (u32)1;
            }
        u32 copyBase = (u32)32 + wstack * (u32)8;
        u32 resv = ((copyBase + copyBytes) + (u32)15) & ~(u32)15;
        _out.appendFormat("\tsub\trsp, %lu\n", resv);

        Array* ir4 = win64ArgRegs();
        Array* ir4d = win64ArgRegs32();
        u32 pos = bigRet ? (u32)1 : (u32)0;
        u32 sstack = (u32)0;
        u32 copyOff = copyBase;
        for (u32 i = (u32)1; i < argEnd; i = i + (u32)1)
            {
            IROperand* a = (IROperand*)n.ops().get(i);
            String* t = argTypeOf(n, i);
            if (isAggTy(t) && aggSize(layoutOf(t)) > (u32)8)
                {
                u32 sz = aggSize(layoutOf(t));
                if (hasSlot(a.val()))
                    copyQwords(sz, slotOf(a.val()), copyOff);
                if (pos < (u32)4)
                    {
                    _out.appendFormat("\tlea\t%s, [rsp+%lu]\n",
                                      ((String*)ir4.get(pos)).cString(), copyOff);
                    }
                else
                    {
                    _out.appendFormat("\tlea\trax, [rsp+%lu]\n", copyOff);
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                copyOff = copyOff + ((sz + (u32)15) & ~(u32)15);
                pos = pos + (u32)1;
                continue;
                }
            // <=8 bytes: by value
            if (isAggTy(t))
                {
                if (pos < (u32)4)
                    {
                    if (hasSlot(a.val()))
                        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n",
                                          ((String*)ir4.get(pos)).cString(), slotOf(a.val()));
                    }
                else if (hasSlot(a.val()))
                    {
                    _out.appendFormat("\tmov\trax, [rbp-%lu]\n", slotOf(a.val()));
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                pos = pos + (u32)1;
                continue;
                }
            if (isFloatTy(t))
                {
                if (pos < (u32)4)
                    {
                    String* x = String.withCString("xmm");
                    x.appendFormat("%lu", pos);
                    loadF(a, x);
                    }
                else
                    {
                    loadZX(a, (u8)'a');
                    _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                    sstack = sstack + (u32)1;
                    }
                pos = pos + (u32)1;
                continue;
                }
            if (pos < (u32)4)
                {
                readArgOp(a, (String*)ir4.get(pos), (String*)ir4d.get(pos));
                }
            else
                {
                loadZX(a, (u8)'a');
                _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)32 + (u32)8 * sstack);
                sstack = sstack + (u32)1;
                }
            pos = pos + (u32)1;
            }
        if (indirect)
            {
            loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
            _out.appendCString("\tmov\tr11, rax\n");
            }
        if (bigRet && hasSlot(n.res())) // the hidden result pointer
            _out.appendFormat("\tlea\trcx, [rbp-%lu]\n", slotOf(n.res()));
        if (indirect)
            _out.appendCString("\tcall\tr11\n");
        else
            _out.appendFormat("\tcall\t%s\n", ((IROperand*)n.ops().get((u32)0)).name().cString());
        _out.appendFormat("\tadd\trsp, %lu\n", resv);
        if (bigRet)
            return; // already written through the sret
        captureResult(n);
        }

    // Copy an aggregate from a frame slot into the outgoing copy area, a
    // quadword at a time. r10 is the scratch — never an argument register.
    void copyQwords(u32 sz, u32 fromSlot, u32 toOff)
        {
        u32 q = (sz + (u32)7) / (u32)8;
        for (u32 k = (u32)0; k < q; k = k + (u32)1)
            {
            // Through rax, as the reference does (bug 142: r10 here was the one
            // divergence between the two win64 back ends — every fixture at
            // -O0, since the library's struct copies are kept there).
            _out.appendFormat("\tmov\trax, [rbp-%lu]\n", fromSlot - (u32)8 * k);
            _out.appendFormat("\tmov\t[rsp+%lu], rax\n", toOff + (u32)8 * k);
            }
        }

    void emitSysVCall(IRFunc* fn, IRInsn* n, bool indirect, u32 argEnd)
        {
        // A pre-pass sizes the outgoing area so ONE `sub rsp` reserves it, kept
        // 16-aligned. Only integer stack arguments are counted; a struct or
        // float overflowing its register file is not supported here, and is
        // skipped symmetrically with the callee's spill.
        // A >16-byte aggregate RESULT is MEMORY class: rdi carries a hidden
        // pointer to the result slot, shifting the GP arguments right by one.
        bool memRet = n.res() != (IRValue*)0 && returnsSysVMemAgg(n.res().ty());
        u32 cIreg = memRet ? (u32)1 : (u32)0;
        u32 cFreg = (u32)0;
        u32 nstack = (u32)0;
        for (u32 i = (u32)1; i < argEnd; i = i + (u32)1)
            {
            String* t = argTypeOf(n, i);
            if (isAggTy(t))
                {
                u32 nr = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (cIreg + nr <= (u32)6)
                    cIreg = cIreg + nr;
                }
            else if (isFloatTy(t) && cFreg < (u32)8)
                {
                cFreg = cFreg + (u32)1;
                }
            else if (cIreg < (u32)6)
                {
                cIreg = cIreg + (u32)1;
                }
            else
                {
                nstack = nstack + (u32)1;
                }
            }
        u32 resv = ((nstack * (u32)8) + (u32)15) & ~(u32)15;
        if (resv != (u32)0)
            _out.appendFormat("\tsub\trsp, %lu\n", resv);

        Array* ir64 = sysvArgRegs();
        Array* ir32 = sysvArgRegs32();
        u32 ireg = memRet ? (u32)1 : (u32)0;
        u32 freg = (u32)0;
        u32 sidx = (u32)0;
        for (u32 i = (u32)1; i < argEnd; i = i + (u32)1)
            {
            IROperand* a = (IROperand*)n.ops().get(i);
            String* t = argTypeOf(n, i);
            if (isAggTy(t))
                {
                // The private xtc convention, shared with arm64: a by-value
                // struct occupies ceil(size/8) consecutive GP argument
                // registers, one per 8-byte chunk, and the callee spills them
                // back. Slots are padded to a multiple of 8, so the tail
                // chunk's over-read stays inside the slot.
                u32 nregs = (aggSize(layoutOf(t)) + (u32)7) / (u32)8;
                if (hasSlot(a.val()) && ireg + nregs <= (u32)6)
                    {
                    for (u32 k = (u32)0; k < nregs; k = k + (u32)1)
                        {
                        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n",
                                          ((String*)ir64.get(ireg)).cString(),
                                          slotOf(a.val()) - (u32)8 * k);
                        ireg = ireg + (u32)1;
                        }
                    }
                }
            else if (isFloatTy(t) && freg < (u32)8)
                {
                String* x = String.withCString("xmm");
                x.appendFormat("%lu", freg);
                loadF(a, x);
                freg = freg + (u32)1;
                }
            else if (ireg < (u32)6)
                {
                readArgOp(a, (String*)ir64.get(ireg), (String*)ir32.get(ireg));
                ireg = ireg + (u32)1;
                }
            else
                {
                // Materialised zero-extended through rax into the reserved
                // area, in source order. rax is free here — it is reloaded
                // below as the vector-argument count.
                loadZX(a, (u8)'a');
                _out.appendFormat("\tmov\t[rsp+%lu], rax\n", (u32)8 * sidx);
                sidx = sidx + (u32)1;
                }
            }
        if (indirect)
            {
            loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
            _out.appendCString("\tmov\tr11, rax\n");
            }
        if (memRet && hasSlot(n.res())) // hidden sret → rdi = &result slot
            _out.appendFormat("\tlea\trdi, [rbp-%lu]\n", slotOf(n.res()));
        // al carries the number of vector arguments, which the variadic ABI
        // requires of every call, variadic or not.
        _out.appendFormat("\tmov\teax, %lu\n", freg);
        if (indirect)
            _out.appendCString("\tcall\tr11\n");
        else
            _out.appendFormat("\tcall\t%s\n", ((IROperand*)n.ops().get((u32)0)).name().cString());
        if (resv != (u32)0)
            _out.appendFormat("\tadd\trsp, %lu\n", resv);
        if (memRet)
            return; // result already written through sret into its slot
        captureResult(n);
        }

    String* argTypeOf(IRInsn* n, u32 i)
        {
        IROperand* a = (IROperand*)n.ops().get(i);
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
            return (String*)0;
        return a.val().ty();
        }

    void captureResult(IRInsn* n)
        {
        IRValue* res = n.res();
        if (res == (IRValue*)0 || isMemTy(res.ty()))
            return;
        if (isAggTy(res.ty()))
            {
            aggFromRetRegs(res);
            return;
            }
        if (isFloatTy(res.ty()))
            {
            storeF(String.withCString("xmm0"), res);
            return;
            }
        store((u8)'a', res);
        }

    // A call argument into a named argument register, width- and home-aware.
    void readArgOp(IROperand* a, String* r64, String* r32)
        {
        if (a.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmov\t%s, %s\n", r64.cString(), immText(a).cString());
            return;
            }
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
            {
            _out.appendFormat("\txor\t%s, %s\n", r64.cString(), r64.cString());
            return;
            }
        IRValue* v = a.val();
        u32 w = widthOfValue(v);
        String* home = homeOf(v);
        if (home != (String*)0)
            {
            if (w >= (u32)8)
                movFromHome(home, (u32)8, r64);
            else if (w == (u32)4)
                movFromHome(home, (u32)4, r32);
            else
                _out.appendFormat("\tmovzx\t%s, %s\n", r32.cString(), regView(home, w).cString());
            return;
            }
        if (!hasSlot(v))
            _out.appendFormat("\txor\t%s, %s\n", r64.cString(), r64.cString());
        else if (w >= (u32)8)
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", r64.cString(), slotOf(v));
        else if (w == (u32)4)
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", r32.cString(), slotOf(v));
        else
            _out.appendFormat("\tmovzx\t%s, %s [rbp-%lu]\n", r32.cString(),
                              sizeKw(w).cString(), slotOf(v));
        }

    static Array* sysvArgRegs32(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("edi"));
        a.add((Object*)String.withCString("esi"));
        a.add((Object*)String.withCString("edx"));
        a.add((Object*)String.withCString("ecx"));
        a.add((Object*)String.withCString("r8d"));
        a.add((Object*)String.withCString("r9d"));
        return a;
        }

    // ── Addresses and memory ─────────────────────────────────────────────
    Map* _fold; // an addr result -> the addr insn folded into it

    bool isFolded(IRValue* v)
        {
        return _fold != (Map*)0 && v != (IRValue*)0 && _fold.get((Hashable*)v) != (Object*)0;
        }

    void emitAddrOf(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() == (u8)OPK_SYM)
            {
            String* nm = safeSym(o.name());
            if ((symbolIsExtern(o.name()) || functionIsImported(o.name())) && !_win64)
                {
                // Imported from another shared object — an imported class's
                // vtable, say, or a function with no body here (another
                // library's Base$dealloc for `new Base[N]`). Its address is not
                // fixed at static-link time, so it comes FROM the GOT rather
                // than a direct RIP-relative form. A static link relaxes the
                // load back to the lea when the image defines the symbol.
                _out.appendFormat("\tmov\trax, [rip+%s@GOTPCREL]\n", nm.cString());
                }
            else
                {
                _out.appendFormat("\tlea\trax, [rip+%s]\n", nm.cString());
                }
            }
        else if (o.kind() == (u8)OPK_USE && hasSlot(o.val()))
            {
            _out.appendFormat("\tlea\trax, [rbp-%lu]\n", slotOf(o.val()));
            }
        else
            {
            _out.appendCString("\txor\teax, eax\n");
            }
        store((u8)'a', n.res());
        }

    // A function symbol with no function of that name DEFINED in this module:
    // a prototype, or a method of a class imported from another library.
    bool functionIsImported(String* name)
        {
        if (_m == (IRModule*)0)
            return false;
        IRSymbol* sym = (IRSymbol*)0;
        for (u32 i = (u32)0; i < _m.syms().count() && sym == (IRSymbol*)0; i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name))
                sym = s;
            }
        if (sym == (IRSymbol*)0 || !sym.isFunc())
            return false;
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)_m.funcs().get(i)).name().equals(name))
                return false;
        return true;
        }

    bool symbolIsExtern(String* name)
        {
        if (_m == (IRModule*)0)
            return false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name))
                return s.isExtern();
            }
        return false;
        }

    // addr = base + index * stride, the stride being the base pointee's NATIVE
    // width — a pointer element is 8 bytes here, not the front end's 2 or 4.
    void emitElementAddr(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        if (isFolded(n.res()))
            return; // folded into its Load
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        u32 stride = (u32)1;
        if (b.kind() == (u8)OPK_USE && b.val() != (IRValue*)0)
            {
            String* pte = pointeeOf(b.val().ty());
            if (pte != (String*)0)
                stride = fieldWidth(pte);
            }
        if (stride == (u32)0)
            stride = (u32)1;
        // A CONSTANT index folds into the displacement, and a HOMED base is
        // already in a register, so `p + 4` is one lea. It used to be four
        // instructions —
        //   mov rax, <base> ; mov rcx, 4 ; lea rax, [rax+rcx*4] ; mov <dst>, rax
        // — and mem_copy's vectorised body was mostly that: eight instructions
        // of addressing for four of work, twice per unrolled copy.
        String* rh = homeOf(n.res());
        if (rh != (String*)0 && isXmmHome(rh))
            rh = (String*)0; // an address never lives in an xmm
        String* dst = rh != (String*)0 ? rh : String.withCString("rax");
        String* bh = (String*)0;
        if (b.kind() == (u8)OPK_USE && b.val() != (IRValue*)0)
            bh = homeOf(b.val());
        if (bh != (String*)0 && isXmmHome(bh))
            bh = (String*)0;
        String* bReg = bh;
        if (bReg == (String*)0)
            {
            loadZX(b, (u8)'a');
            bReg = String.withCString("rax");
            }
        IROperand* ix = (IROperand*)n.ops().get((u32)1);
        if (ix.kind() == (u8)OPK_IMMI)
            {
            i64 disp = ix.imm() * (i64)stride;
            if (disp == (i64)0)
                {
                if (!dst.equals(bReg))
                    _out.appendFormat("\tmov\t%s, %s\n", dst.cString(), bReg.cString());
                }
            else
                {
                // appendFormat understands ONE `l`, so its widest integer is 32
                // bits and it has no `%+` — `%+lld` came out literally. Build
                // the signed displacement by hand, as the printer does.
                _out.appendCString("\tlea\t");
                _out.append(dst);
                _out.appendCString(", [");
                _out.append(bReg);
                if (disp >= (i64)0)
                    _out.appendCString("+");
                _out.append(String.withI64(disp));
                _out.appendCString("]\n");
                }
            }
        else
            {
            // rcx is emission scratch and never a home, so loading the index
            // into it cannot disturb a homed base.
            loadIndex(ix, (u8)'c');
            if (stride == (u32)1 || stride == (u32)2 || stride == (u32)4 || stride == (u32)8)
                _out.appendFormat("\tlea\t%s, [%s + rcx*%lu]\n", dst.cString(), bReg.cString(), stride);
            else
                {
                _out.appendFormat("\timul\trcx, rcx, %lu\n", stride);
                _out.appendFormat("\tlea\t%s, [%s + rcx]\n", dst.cString(), bReg.cString());
                }
            }
        if (rh == (String*)0)
            store((u8)'a', n.res());
        }

    void emitFieldAddr(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        if (isFolded(n.res()))
            return;
        u32 off = fieldByteOffset(n);
        // Same as ElementAddr: a homed base needs no load, and the offset is a
        // displacement rather than a separate add.
        IROperand* b0 = (IROperand*)n.ops().get((u32)0);
        String* rh = homeOf(n.res());
        if (rh != (String*)0 && isXmmHome(rh))
            rh = (String*)0;
        String* dst = rh != (String*)0 ? rh : String.withCString("rax");
        String* bh = (String*)0;
        if (b0.kind() == (u8)OPK_USE && b0.val() != (IRValue*)0)
            bh = homeOf(b0.val());
        if (bh != (String*)0 && isXmmHome(bh))
            bh = (String*)0;
        String* bReg = bh;
        if (bReg == (String*)0)
            {
            loadZX(b0, (u8)'a');
            bReg = String.withCString("rax");
            }
        if (off != (u32)0)
            _out.appendFormat("\tlea\t%s, [%s+%lu]\n", dst.cString(), bReg.cString(), off);
        else if (!dst.equals(bReg))
            _out.appendFormat("\tmov\t%s, %s\n", dst.cString(), bReg.cString());
        if (rh == (String*)0)
            store((u8)'a', n.res());
        }

    u32 fieldByteOffset(IRInsn* n)
        {
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        IROperand* ix = (IROperand*)n.ops().get((u32)1);
        if (b.kind() != (u8)OPK_USE || b.val() == (IRValue*)0)
            return (u32)0;
        if (ix.kind() != (u8)OPK_IMMI)
            return (u32)0;
        IRLayout* l = layoutOf(pointeeOf(b.val().ty()));
        if (l == (IRLayout*)0)
            return (u32)0;
        u32 idx = (u32)ix.imm();
        if (idx >= l.fieldCount())
            return (u32)0;
        return fieldOffset(l, idx);
        }

    // The memory operand for a folded address: `[base + idx*s]` or
    // `[base + off]`. A homed pointer base is used directly (it is 64-bit
    // valid); an unhomed one zero-extends into rax. The INDEX is always
    // zero- or sign-extended into rcx, because a memory operand uses the whole
    // 64-bit index and dirty high bits from a homed 32-bit one would corrupt
    // the address. Base first, then index.
    String* foldedMemOp(IRInsn* ea)
        {
        IROperand* bop = (IROperand*)ea.ops().get((u32)0);
        String* bhome = bop.kind() == (u8)OPK_USE ? homeOf(bop.val()) : (String*)0;
        String* baseReg;
        if (bhome != (String*)0)
            baseReg = regView(bhome, (u32)8);
        else
            {
            loadZX(bop, (u8)'a');
            baseReg = String.withCString("rax");
            }
        if (ea.op().equals(String.withCString("FieldAddr")))
            {
            u32 off = fieldByteOffset(ea);
            String* o = String.withCString("[");
            o.append(baseReg);
            if (off != (u32)0)
                o.appendFormat(" + %lu]", off);
            else
                o.appendCString("]");
            return o;
            }
        u32 stride = (u32)1;
        if (bop.kind() == (u8)OPK_USE && bop.val() != (IRValue*)0)
            {
            String* pte = pointeeOf(bop.val().ty());
            if (pte != (String*)0)
                stride = fieldWidth(pte);
            }
        if (stride == (u32)0)
            stride = (u32)1;

        // A HOMED UNSIGNED 32-bit index is the index register directly, with no
        // staging mov: on x86-64 every write to a 32-bit register zero-extends
        // into its 64-bit half, so a home last written as `mov r12d, ...` already
        // has the clean upper bits the rcx zero-extend was establishing.
        //
        // ONLY unsigned, only width 4. A signed narrow index still goes through
        // loadIndex's movsxd — a negative i32 homed by a 32-bit write reads as a
        // huge POSITIVE 64-bit index, addressing outside the object.
        String* idxReg = (String*)0;
        IROperand* iop = (IROperand*)ea.ops().get((u32)1);
        if (iop.kind() == (u8)OPK_USE && iop.val() != (IRValue*)0)
            {
            IRValue* iv = iop.val();
            String* ihome = homeOf(iv);
            u32 iw = fieldWidth(iv.ty());
            if (ihome != (String*)0 && iw == (u32)4 && !isSignedTy(iv.ty()))
                idxReg = regView(ihome, (u32)8);
            }
        if (idxReg == (String*)0)
            {
            loadIndex(iop, (u8)'c');
            idxReg = String.withCString("rcx");
            }
        String* o = String.withCString("[");
        o.append(baseReg);
        o.appendFormat(" + %s*%lu]", idxReg.cString(), stride);
        return o;
        }

    void emitLoad(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        String* rt = n.res().ty();
        if (p.kind() == (u8)OPK_USE && isFolded(p.val()) && !isAggTy(rt))
            {
            String* memop = foldedMemOp((IRInsn*)_fold.get((Hashable*)p.val()));
            // A FLOAT loads straight into an xmm. It used to go through a
            // general register and then movd/movq across — two instructions and
            // a domain crossing for what movss/movsd does in one.
            if (isFloatTy(rt))
                {
                String* Df = fdstFor(n.res(), (IROperand*)0, (IROperand*)0);
                _out.appendFormat("\tmov%s\t%s, %s\n",
                                  rt.equals(String.withCString("F64")) ? "sd" : "ss",
                                  Df.cString(), memop.cString());
                storeF(Df, n.res());
                return;
                }
            u32 w = widthOfValue(n.res());
            _out.appendFormat("\tmov\t%s, %s\n", reg((u8)'d', w).cString(), memop.cString());
            store((u8)'d', n.res());
            return;
            }
        loadZX(p, (u8)'a');
        if (isAggTy(rt))
            {
            if (hasSlot(n.res()))
                copyAgg(aggSize(layoutOf(rt)), String.withCString("rax"), slotOf(n.res()), true);
            return;
            }
        if (isFloatTy(rt))
            {
            String* Df = fdstFor(n.res(), (IROperand*)0, (IROperand*)0);
            _out.appendFormat("\tmov%s\t%s, [rax]\n",
                              rt.equals(String.withCString("F64")) ? "sd" : "ss", Df.cString());
            storeF(Df, n.res());
            return;
            }
        u32 w = widthOfValue(n.res());
        _out.appendFormat("\tmov\t%s, [rax]\n", reg((u8)'c', w).cString());
        store((u8)'c', n.res());
        }

    void emitStore(IRInsn* n)
        {
        if (n.ops().count() < (u32)2)
            return;
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        IROperand* v = (IROperand*)n.ops().get((u32)1);
        String* vt = v.kind() == (u8)OPK_USE && v.val() != (IRValue*)0 ? v.val().ty() : (String*)0;
        if (p.kind() == (u8)OPK_USE && isFolded(p.val()) && !isAggTy(vt))
            {
            u32 w = vt == (String*)0 ? (u32)4 : widthOfValue(v.val());
            // A FLOAT goes straight out of an xmm. Its source is chosen before
            // the address is formed, as rdx is below — though an xmm could not
            // be clobbered by the rax/rcx address scratch in any case.
            if (isFloatTy(vt))
                {
                String* Sf = fsrcForStore(v);
                String* memopF = foldedMemOp((IRInsn*)_fold.get((Hashable*)p.val()));
                _out.appendFormat("\tmov%s\t%s, %s\n",
                                  vt.equals(String.withCString("F64")) ? "sd" : "ss",
                                  memopF.cString(), Sf.cString());
                return;
                }
            // The value goes to rdx FIRST: rdx is never a home register nor one
            // of the address computation's rax/rcx scratch, so forming the
            // address afterwards cannot clobber it.
            load(v, (u8)'d');
            String* memop = foldedMemOp((IRInsn*)_fold.get((Hashable*)p.val()));
            _out.appendFormat("\tmov\t%s, %s\n", memop.cString(), reg((u8)'d', w).cString());
            return;
            }
        loadZX(p, (u8)'a');
        if (isAggTy(vt))
            {
            if (hasSlot(v.val()))
                copyAgg(aggSize(layoutOf(vt)), String.withCString("rax"), slotOf(v.val()), false);
            return;
            }
        if (isFloatTy(vt))
            {
            String* Sf = fsrcForStore(v);
            _out.appendFormat("\tmov%s\t[rax], %s\n",
                              vt.equals(String.withCString("F64")) ? "sd" : "ss", Sf.cString());
            return;
            }
        u32 w = vt == (String*)0 ? (u32)4 : widthOfValue(v.val());
        load(v, (u8)'c');
        _out.appendFormat("\tmov\t[rax], %s\n", reg((u8)'c', w).cString());
        }

    // Block-copy between a pointer and a frame slot whose byte 0 is at
    // [rbp-slotOff], in 8/4/2/1-byte chunks through rcx.
    void copyAgg(u32 size, String* ptrReg, u32 slotOff, bool toSlot)
        {
        u32 o = (u32)0;
        while (o < size)
            {
            u32 c = (size - o >= (u32)8) ? (u32)8
                                         : ((size - o >= (u32)4) ? (u32)4
                                                                 : ((size - o >= (u32)2) ? (u32)2 : (u32)1));
            String* r = reg((u8)'c', c);
            String* mem = String.withCString("[");
            mem.append(ptrReg);
            mem.appendFormat("+%lu]", o);
            String* frm = String.withCString("[rbp-");
            frm.appendFormat("%lu]", slotOff - o);
            String* src = toSlot ? mem : frm;
            String* dst = toSlot ? frm : mem;
            _out.appendFormat("\tmov\t%s, %s\n\tmov\t%s, %s\n", r.cString(), src.cString(),
                              dst.cString(), r.cString());
            o = o + c;
            }
        }

    // ── Control flow ─────────────────────────────────────────────────────
    void emitTerminator(IRFunc* fn, IRBlock* bb, IRInsn* t)
        {
        String* op = t.op();
        if (op.equals(String.withCString("Return")))
            {
            emitReturn(fn, t);
            return;
            }
        if (op.equals(String.withCString("Branch")))
            {
            emitBranch(fn, bb, t);
            return;
            }
        if (op.equals(String.withCString("CondBranch")))
            {
            emitCondBranch(fn, bb, t);
            return;
            }
        // A failed CHECKED downcast `(T*)p` lands here, and it IS reachable.
        // Falling out through the epilogue meant the cast silently succeeded
        // with a mistyped pointer and the function RETURNED — so on the hosts a
        // failed cast exited 0 and looked like a clean run. Fixed in the
        // reference first, then here.
        if (op.equals(String.withCString("Unreachable")))
            {
            _out.appendCString("\tud2\n");
            return;
            }
        // Any other terminator still falls out through the epilogue: the block
        // has to END.
        emitEpilogue();
        }

    void emitEpilogue(void)
        {
        emitHomeRestore();
        if (_frame != (u32)0)
            _out.appendFormat("\tadd\trsp, %lu\n", _frame);
        _out.appendCString("\tpop\trbp\n\tret\n");
        }

    // In a STABLE order — the reference enumerated a dictionary here, so the
    // restore sequence came out in Foundation's hash order and did not even
    // match the prologue's save order (#947).
    void emitHomeRestore(void)
        {
        Array* order = sortedRegs(_homeSaves);
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* r = (String*)order.get(i);
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", r.cString(),
                              ((Number*)_homeSaveOff.get((Hashable*)r)).asU32());
            }
        }

    static Array* sortedRegs(Array* a)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            o.add(a.get(i));
        for (u32 i = (u32)1; i < o.count(); i = i + (u32)1)
            {
            Object* cur = o.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)o.get(j - (u32)1)).compare((String*)cur) > (i32)0)
                {
                o.set(j, o.get(j - (u32)1));
                j = j - (u32)1;
                }
            o.set(j, cur);
            }
        return o;
        }

    void emitReturn(IRFunc* fn, IRInsn* t)
        {
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            IRValue* v = o.kind() == (u8)OPK_USE ? o.val() : (IRValue*)0;
            if (v != (IRValue*)0 && isMemTy(v.ty()))
                continue;
            if (v != (IRValue*)0 && isAggTy(v.ty()))
                {
                // Hidden sret (Win64 >8B, System V >16B MEMORY class): the
                // slot is set for either ABI, and both require rax = the
                // sret pointer on return.
                if (_sretOff != (u32)0)
                    returnAggViaSret(v);
                else
                    aggToRetRegs(v);
                break;
                }
            if (v != (IRValue*)0 && isFloatTy(v.ty()))
                {
                loadF(o, String.withCString("xmm0"));
                break;
                }
            load(o, (u8)'a');
            break;
            }
        emitEpilogue();
        }

    void emitBranch(IRFunc* fn, IRBlock* bb, IRInsn* t)
        {
        if (t.ops().count() < (u32)1)
            return;
        IROperand* o = (IROperand*)t.ops().get((u32)0);
        if (o.kind() != (u8)OPK_BLOCK)
            return;
        phiEdges(fn, bb, o.blk());
        _out.appendFormat("\tjmp\t%s\n", blockLabel(fn, o.blk()).cString());
        }

    void emitCondBranch(IRFunc* fn, IRBlock* bb, IRInsn* t)
        {
        IROperand* cond = (IROperand*)0;
        IRBlock* tb = (IRBlock*)0;
        IRBlock* fb = (IRBlock*)0;
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK)
                {
                if (tb == (IRBlock*)0)
                    tb = o.blk();
                else if (fb == (IRBlock*)0)
                    fb = o.blk();
                }
            else if (cond == (IROperand*)0)
                {
                cond = o;
                }
            }
        String* flab = String.withCString(".Lf_");
        flab.append(fn.name());
        flab.appendCString("_");
        flab.append(bb.name());
        IRInsn* fcmp = bb.insns().count() > (u32)0
                           ? (IRInsn*)bb.insns().get(bb.insns().count() - (u32)1)
                           : (IRInsn*)0;
        bool fused = cond != (IROperand*)0 && cond.kind() == (u8)OPK_USE && inFused(cond.val()) && fcmp != (IRInsn*)0 && fcmp.res() == cond.val();
        if (fused)
            {
            // The ICmp already emitted its cmp and the flags are still set:
            // branch to the FALSE target on the negated predicate.
            _out.appendFormat("\t%s\t%s\n", jccForNegated(fcmp.pred()).cString(), flab.cString());
            }
        else
            {
            // The condition ZERO-extends: a narrow bool loaded as `mov al` leaves
            // stale high bits, and `test eax, eax` would then read a false
            // condition as non-zero.
            u32 cw = (u32)4;
            if (cond != (IROperand*)0)
                {
                loadZX(cond, (u8)'a');
                cw = condWidth(cond);
                }
            _out.appendFormat("\ttest\t%s, %s\n", reg((u8)'a', cw).cString(), reg((u8)'a', cw).cString());
            _out.appendFormat("\tje\t%s\n", flab.cString());
            }
        if (tb != (IRBlock*)0)
            {
            phiEdges(fn, bb, tb);
            _out.appendFormat("\tjmp\t%s\n", blockLabel(fn, tb).cString());
            }
        _out.appendFormat("%s:\n", flab.cString());
        if (fb != (IRBlock*)0)
            {
            phiEdges(fn, bb, fb);
            _out.appendFormat("\tjmp\t%s\n", blockLabel(fn, fb).cString());
            }
        }

    static String* jccForNegated(String* p)
        {
        if (p == (String*)0)
            return String.withCString("jne");
        if (p.equals(String.withCString("EQ")))
            return String.withCString("jne");
        if (p.equals(String.withCString("NE")))
            return String.withCString("je");
        if (p.equals(String.withCString("SLT")))
            return String.withCString("jge");
        if (p.equals(String.withCString("SLE")))
            return String.withCString("jg");
        if (p.equals(String.withCString("SGT")))
            return String.withCString("jle");
        if (p.equals(String.withCString("SGE")))
            return String.withCString("jl");
        if (p.equals(String.withCString("ULT")))
            return String.withCString("jae");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("ja");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("jbe");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("jb");
        return String.withCString("jne");
        }

    // ── Phi-edge copies ──────────────────────────────────────────────────
    void phiEdges(IRFunc* fn, IRBlock* from, IRBlock* to)
        {
        if (to == (IRBlock*)0)
            return;
        Array* dests = new Array();
        Array* srcs = new Array();
        for (u32 i = (u32)0; i < to.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)to.phis().get(i);
            if (!phi.op().equals(String.withCString("Phi")) || phi.res() == (IRValue*)0)
                continue;
            IROperand* inc = phiSourceFrom(phi, from);
            if (inc == (IROperand*)0)
                continue;
            if (isVecTy(phi.res().ty()))
                {
                // A vector phi is coalesced onto ONE register, so the back edge
                // needs no copy; only a genuinely different register moves.
                String* dv = vecOf(phi.res());
                String* sv = inc.kind() == (u8)OPK_USE ? vecOf(inc.val()) : (String*)0;
                if (dv != (String*)0 && sv != (String*)0 && !dv.equals(sv))
                    _out.appendFormat("\tmovdqa\t%s, %s\n", dv.cString(), sv.cString());
                continue;
                }
            dests.add((Object*)phi.res());
            srcs.add((Object*)inc);
            }
        if (dests.count() == (u32)0)
            return;
        // Safe iff no copy's DEST location aliases a DIFFERENT copy's SOURCE.
        bool safe = true;
        for (u32 i = (u32)0; i < dests.count() && safe; i = i + (u32)1)
            {
            String* dloc = phiLocOf((IRValue*)dests.get(i));
            if (dloc == (String*)0)
                continue;
            for (u32 j = (u32)0; j < srcs.count() && safe; j = j + (u32)1)
                {
                if (i == j)
                    continue;
                IROperand* sj = (IROperand*)srcs.get(j);
                if (sj.kind() != (u8)OPK_USE || sj.val() == (IRValue*)0)
                    continue;
                String* sloc = phiLocOf(sj.val());
                if (sloc != (String*)0 && sloc.equals(dloc))
                    safe = false;
                }
            }
        if (safe)
            {
            for (u32 i = (u32)0; i < dests.count(); i = i + (u32)1)
                {
                load((IROperand*)srcs.get(i), (u8)'a');
                store((u8)'a', (IRValue*)dests.get(i));
                }
            return;
            }
        // Aliased: read EVERY source before writing ANY dest. push/pop are
        // 64-bit and balanced, so the branch point's rsp alignment is kept.
        for (u32 i = (u32)0; i < srcs.count(); i = i + (u32)1)
            {
            load((IROperand*)srcs.get(i), (u8)'a');
            _out.appendCString("\tpush\trax\n");
            }
        for (u32 i = dests.count(); i > (u32)0; i = i - (u32)1)
            {
            _out.appendCString("\tpop\trax\n");
            store((u8)'a', (IRValue*)dests.get(i - (u32)1));
            }
        }

    String* phiLocOf(IRValue* v)
        {
        String* h = homeOf(v);
        if (h != (String*)0)
            return h;
        if (!hasSlot(v))
            return (String*)0;
        String* s = String.withCString("[rbp-");
        s.appendFormat("%lu]", slotOf(v));
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

    // ── Operand access ───────────────────────────────────────────────────
    //
    // Three shapes, because x86 cares which one you use: a plain load at the
    // value's natural width, a ZERO-extended load (addresses and indices need
    // the whole 64-bit register clean), and a SIGN-aware index load.
    void load(IROperand* op, u8 base)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmov\t%s, %s\n", reg(base, (u32)8).cString(), immText(op).cString());
            return;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            _out.appendFormat("\txor\t%s, %s\n", reg(base, (u32)8).cString(), reg(base, (u32)8).cString());
            return;
            }
        IRValue* v = op.val();
        u32 w = widthOfValue(v);
        String* home = homeOf(v);
        if (home != (String*)0)
            {
            movFromHome(home, w, reg(base, w));
            return;
            }
        if (!hasSlot(v))
            {
            _out.appendFormat("\txor\t%s, %s\n", reg(base, (u32)8).cString(), reg(base, (u32)8).cString());
            return;
            }
        // A sub-8 mov leaves the high bits as they were, so the natural-width
        // view is used and any caller needing more extends explicitly.
        _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", reg(base, w).cString(), slotOf(v));
        }

    void loadZX(IROperand* op, u8 base)
        {
        String* r32 = reg(base, (u32)4);
        String* r64 = reg(base, (u32)8);
        if (op.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmov\t%s, %s\n", r64.cString(), immText(op).cString());
            return;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            _out.appendFormat("\txor\t%s, %s\n", r64.cString(), r64.cString());
            return;
            }
        IRValue* v = op.val();
        u32 w = widthOfValue(v);
        String* home = homeOf(v);
        if (home != (String*)0)
            {
            if (w >= (u32)8)
                movFromHome(home, (u32)8, r64);
            else if (w == (u32)4)
                movFromHome(home, (u32)4, r32);
            else
                _out.appendFormat("\tmovzx\t%s, %s\n", r32.cString(), regView(home, w).cString());
            return;
            }
        if (!hasSlot(v))
            {
            _out.appendFormat("\txor\t%s, %s\n", r64.cString(), r64.cString());
            return;
            }
        u32 sl = slotOf(v);
        if (w >= (u32)8)
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", r64.cString(), sl);
        else if (w == (u32)4)
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", r32.cString(), sl); // zero-extends
        else
            _out.appendFormat("\tmovzx\t%s, %s [rbp-%lu]\n", r32.cString(),
                              sizeKw(w).cString(), sl);
        }

    // An element index extends to 64 bits by its OWN signedness. `u16@ p =
    // &a[3]; @(p - (i16)2) = v;` lowers to a signed 16-bit index of −2;
    // zero-extending it made that 65534 and the store landed 128 KB past the
    // array. arm64 got this right, so it only ever showed on x86-64.
    void loadIndex(IROperand* op, u8 base)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            loadZX(op, base);
            return;
            }
        IRValue* v = op.val();
        u32 w = fieldWidth(v.ty());
        if (w == (u32)0 || w >= (u32)8 || !isSignedTy(v.ty()))
            {
            loadZX(op, base);
            return;
            }
        String* r64 = reg(base, (u32)8);
        String* home = homeOf(v);
        // 32-to-64 is spelled movsxd, a DISTINCT opcode. Getting it wrong is not
        // a syntax nit: `movsx r64, r32` assembles as a sign-extend from a BYTE
        // on anything that accepts it, and clang rejects it outright.
        if (home != (String*)0)
            {
            _out.appendFormat("\t%s\t%s, %s\n", w == (u32)4 ? "movsxd" : "movsx",
                              r64.cString(), regView(home, w).cString());
            return;
            }
        if (!hasSlot(v))
            {
            _out.appendFormat("\txor\t%s, %s\n", r64.cString(), r64.cString());
            return;
            }
        u32 sl = slotOf(v);
        if (w == (u32)4)
            _out.appendFormat("\tmovsxd\t%s, dword ptr [rbp-%lu]\n", r64.cString(), sl);
        else
            _out.appendFormat("\tmovsx\t%s, %s [rbp-%lu]\n", r64.cString(),
                              sizeKw(w).cString(), sl);
        }

    // An operand extended (sign or zero) to a COMPARE width, so a cmp never
    // sees stale high bits from a narrow load.
    void loadExt(IROperand* op, u8 base, bool sgn, u32 w)
        {
        String* rw = reg(base, w);
        if (op.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmov\t%s, %s\n", rw.cString(), immText(op).cString());
            return;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            {
            _out.appendFormat("\txor\t%s, %s\n", rw.cString(), rw.cString());
            return;
            }
        IRValue* v = op.val();
        u32 nat = widthOfValue(v);
        String* home = homeOf(v);
        // 32->64 has its own spellings and NEITHER is movsx/movzx: signed is
        // `movsxd` (a distinct opcode), unsigned is a plain 32-bit `mov`,
        // because writing a 32-bit register zero-extends into the full 64.
        // The assembler rejects `movsx rax, ebx` outright — it only became
        // reachable once a 32-bit value could widen to i64.
        bool w32to64 = (nat == (u32)4 && w == (u32)8);
        if (home != (String*)0)
            {
            if (nat >= w)
                movFromHome(home, w, rw);
            else if (w32to64)
                _out.appendFormat("\t%s\t%s, %s\n", sgn ? "movsxd" : "mov",
                                  sgn ? rw.cString() : reg(base, (u32)4).cString(),
                                  regView(home, (u32)4).cString());
            else
                _out.appendFormat("\t%s\t%s, %s\n", sgn ? "movsx" : "movzx",
                                  rw.cString(), regView(home, nat).cString());
            return;
            }
        if (!hasSlot(v))
            {
            _out.appendFormat("\txor\t%s, %s\n", rw.cString(), rw.cString());
            return;
            }
        u32 sl = slotOf(v);
        if (nat >= w)
            _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", rw.cString(), sl);
        else if (w32to64)
            _out.appendFormat("\t%s\t%s, dword ptr [rbp-%lu]\n", sgn ? "movsxd" : "mov",
                              sgn ? rw.cString() : reg(base, (u32)4).cString(), sl);
        else
            _out.appendFormat("\t%s\t%s, %s [rbp-%lu]\n", sgn ? "movsx" : "movzx",
                              rw.cString(), sizeKw(nat).cString(), sl);
        }

    // A homed result lives in its register; an unhomed one goes to its slot at
    // its own width.
    void store(u8 base, IRValue* res)
        {
        if (res == (IRValue*)0)
            return;
        u32 w = widthOfValue(res);
        String* home = homeOf(res);
        if (home != (String*)0)
            {
            movIntoHome(home, w, reg(base, w));
            return;
            }
        if (!hasSlot(res))
            return;
        _out.appendFormat("\tmov\t[rbp-%lu], %s\n", slotOf(res), reg(base, w).cString());
        }

    // An immediate's TEXT, at the payload's full 64 bits. The reference prints
    // `%lld` from an int64_t; appendFormat understands one `l`, so this goes
    // through String.withI64 / withU64 instead of a format specifier. The
    // unsigned flag still decides the spelling, because a value with the top
    // bit set is a magnitude on one path and a negative number on the other.
    static String* immText(IROperand* op)
        {
        if (op.uimm() && op.imm() < (i64)0)
            return String.withU64((u64)op.imm());
        return String.withI64(op.imm());
        }

    // An operand as an x86 SOURCE at width w, usable as the second operand of a
    // two-address op writing `resR`: an immediate, a home register view, or slot
    // memory. If it currently lives in resR — where producing the result would
    // clobber it — it is copied to rcx first.
    String* srcOperand(IROperand* op, u32 w, String* resR)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            // In 64-bit mode EVERY arithmetic/logical immediate is an imm32,
            // SIGN-EXTENDED — there is no `and r64, imm64`, nor or/xor/add/sub.
            // Handing one a wider constant loses its top 32 bits: `x &
            // 0xFF00FF00FF` assembled as `x & 0x00FF00FF` and every 64-bit AND
            // came back with a zero high word (bug 089). The imul path above
            // already guards this and its comment claimed the general path
            // staged wide constants in a register — it did not, until here.
            //
            // rcx is the scratch everywhere else in this method, so it is only
            // wrong when rcx IS the destination; rax is free in that case,
            // because this path touches nothing but the result and one scratch.
            if (w == (u32)8 && (op.imm() > (i64)2147483647 || op.imm() < (i64)0 - (i64)2147483648))
                {
                u8 sc = resR.equals(reg((u8)'c', w)) ? (u8)'a' : (u8)'c';
                _out.appendFormat("\tmov\t%s, %s\n", reg(sc, w).cString(),
                                  immText(op).cString());
                return reg(sc, w);
                }
            return immText(op);
            }
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            {
            String* home = homeOf(op.val());
            if (home != (String*)0)
                {
                String* hv = regView(home, w);
                if (hv.equals(resR))
                    {
                    _out.appendFormat("\tmov\t%s, %s\n", reg((u8)'c', w).cString(), hv.cString());
                    return reg((u8)'c', w);
                    }
                return hv;
                }
            if (hasSlot(op.val()))
                {
                String* o = String.withCString("[rbp-");
                o.appendFormat("%lu]", slotOf(op.val()));
                return o;
                }
            }
        _out.appendFormat("\tmov\t%s, 0\n", reg((u8)'c', w).cString());
        return reg((u8)'c', w);
        }

    String* blockLabel(IRFunc* fn, IRBlock* bb)
        {
        String* s = String.withCString(".L_");
        s.append(fn.name());
        s.appendCString("_");
        s.append(bb.name());
        return s;
        }

    void emitBlock(IRFunc* fn, IRBlock* bb, bool loopHead)
        {
        // Align loop heads. x86 fetches in 16-byte windows, so a hot loop whose
        // head straddles one costs throughput every iteration — and whether it
        // straddles is decided by however much code happens to precede it.
        // Regenerating the RUNTIME (which branch_mix never calls in its loop)
        // moved that benchmark 57ms -> 79ms, a 37% swing from pure layout.
        // THIRTY-TWO, and only because the ELF writer now puts .text on a
        // 64-byte boundary. The assembler pads relative to the START of the
        // section, so a section-relative 32-byte boundary is an absolute one
        // only when the section itself is at least that aligned; at the old
        // align-16 base every head landed at 16 mod 32, in the middle of a
        // fetch window, which is worse than the arbitrary phase align-4 gives.
        // Both halves together, measured on the x86-64 host over all nineteen
        // benchmarks: mem_copy -27%, sort_small -18%, branch_mix +12%, the
        // rest within 2%; 1.9% faster on the geometric mean. The point is as
        // much that the phase is now DETERMINISTIC — it no longer re-rolls
        // when unrelated code ahead of a hot function changes size, which had
        // produced 37% swings between byte-identical loops. private:docs/bugs/232.
        if (loopHead)
            _out.appendCString("\t.p2align\t5, 0x90\n");
        _out.appendFormat("%s:\n", blockLabel(fn, bb).cString());
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            emitInsn(fn, bb, (IRInsn*)bb.insns().get(i));
        if (bb.term() != (IRInsn*)0)
            emitTerminator(fn, bb, bb.term());
        else
            emitEpilogue();
        }

    void emitInsn(IRFunc* fn, IRBlock* bb, IRInsn* n)
        {
        // The dispatch is split for the frame budget alone: one chain of string
        // comparisons builds more temporaries than a 16 KB frame holds.
        String* op = n.op();
        if (op.equals(String.withCString("Phi")))
            return; // edge copies
        if (dispatchCore(n, op))
            return;
        if (dispatchMemory(fn, n, op))
            return;
        if (dispatchRuntime(fn, n, op))
            return;
        if (dispatchFloat(n, op))
            return;
        if (dispatchVector(n, op))
            return;
        unsupported(op);
        }

    bool dispatchCore(IRInsn* n, String* op)
        {
        if (op.equals(String.withCString("Const")))
            {
            emitConst(n);
            return true;
            }
        if (op.equals(String.withCString("ZExt")))
            {
            emitZExt(n);
            return true;
            }
        if (op.equals(String.withCString("SExt")))
            {
            emitSExt(n);
            return true;
            }
        if (op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Copy")) || op.equals(String.withCString("Bitcast")))
            {
            emitPlainCast(n);
            return true;
            }
        if (op.equals(String.withCString("IntToPtr")))
            {
            emitIntToPtr(n);
            return true;
            }
        if (op.equals(String.withCString("PtrToInt")))
            {
            emitReinterpret(n);
            return true;
            }
        String* mn = intBinOpMnemonic(op);
        if (mn != (String*)0)
            {
            emitBinary(n, mn);
            return true;
            }
        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")))
            {
            emitShift(n);
            return true;
            }
        if (op.equals(String.withCString("Neg")) || op.equals(String.withCString("Not")))
            {
            emitUnary(n);
            return true;
            }
        if (op.equals(String.withCString("UDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("SRem")))
            {
            emitDivRem(n);
            return true;
            }
        if (op.equals(String.withCString("ICmp")))
            {
            emitICmp(n);
            return true;
            }
        if (op.equals(String.withCString("Select")))
            {
            emitSelect(n);
            return true;
            }
        return false;
        }

    bool dispatchMemory(IRFunc* fn, IRInsn* n, String* op)
        {
        if (op.equals(String.withCString("AddrOf")))
            {
            emitAddrOf(n);
            return true;
            }
        if (op.equals(String.withCString("ElementAddr")))
            {
            emitElementAddr(n);
            return true;
            }
        if (op.equals(String.withCString("FieldAddr")))
            {
            emitFieldAddr(n);
            return true;
            }
        if (op.equals(String.withCString("Load")))
            {
            emitLoad(n);
            return true;
            }
        if (op.equals(String.withCString("Store")))
            {
            emitStore(n);
            return true;
            }
        if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")))
            {
            emitCall(fn, n, false);
            return true;
            }
        if (op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")))
            {
            emitCall(fn, n, true);
            return true;
            }
        if (op.equals(String.withCString("MemCopy")))
            {
            emitMemHelper(n, String.withCString("memcpy"));
            return true;
            }
        if (op.equals(String.withCString("MemSet")))
            {
            emitMemHelper(n, String.withCString("memset"));
            return true;
            }
        return false;
        }

    bool dispatchRuntime(IRFunc* fn, IRInsn* n, String* op)
        {
        if (op.equals(String.withCString("Retain")))
            {
            emitRetain(n);
            return true;
            }
        if (op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")))
            {
            emitRelease(n);
            return true;
            }
        if (op.equals(String.withCString("WeakRegister")))
            {
            emitWeakRegister(n);
            return true;
            }
        if (op.equals(String.withCString("WeakUnregister")))
            {
            emitWeakOne(n, String.withCString("_xtc_weak_unregister"), false);
            return true;
            }
        if (op.equals(String.withCString("WeakLoad")))
            {
            emitWeakOne(n, String.withCString("_xtc_weak_load"), true);
            return true;
            }
        if (op.equals(String.withCString("AggBuild")))
            {
            emitAggBuild(n);
            return true;
            }
        if (op.equals(String.withCString("AggExtract")))
            {
            emitAggExtract(n);
            return true;
            }
        if (op.equals(String.withCString("VTblDispatch")))
            {
            emitVTblDispatch(fn, n);
            return true;
            }
        if (op.equals(String.withCString("ProtoDispatch")))
            {
            emitProtoDispatchX86(fn, n);
            return true;
            }
        if (op.equals(String.withCString("VTblLoad")))
            {
            emitVTblLoad(n);
            return true;
            }
        if (op.equals(String.withCString("ProtoLoad")))
            {
            emitProtoLoadX86(n);
            return true;
            }
        if (op.equals(String.withCString("Asm")))
            {
            emitAsm(n);
            return true;
            }
        // The optimiser's unreachable marker: control provably never gets here.
        if (op.equals(String.withCString("Unreachable")))
            return true;
        return false;
        }

    bool dispatchFloat(IRInsn* n, String* op)
        {
        if (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv")))
            {
            emitFBin(n);
            return true;
            }
        if (op.equals(String.withCString("FNeg")))
            {
            emitFNeg(n);
            return true;
            }
        if (op.equals(String.withCString("FSqrt")))
            {
            emitFSqrt(n);
            return true;
            }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            {
            emitIntToFp(n);
            return true;
            }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")))
            {
            emitFpToInt(n);
            return true;
            }
        if (op.equals(String.withCString("FpExt")))
            {
            emitFpConvert(n, true);
            return true;
            }
        if (op.equals(String.withCString("FpTrunc")))
            {
            emitFpConvert(n, false);
            return true;
            }
        if (op.equals(String.withCString("FCmp")))
            {
            emitFCmp(n);
            return true;
            }
        return false;
        }

    bool dispatchVector(IRInsn* n, String* op)
        {
        if (op.equals(String.withCString("VLoad")))
            {
            emitVLoad(n);
            return true;
            }
        if (op.equals(String.withCString("VStore")))
            {
            emitVStore(n);
            return true;
            }
        if (op.equals(String.withCString("VSplat")))
            {
            emitVSplat(n);
            return true;
            }
        if (op.equals(String.withCString("VAdd")) || op.equals(String.withCString("VSub")) || op.equals(String.withCString("VMul")) || op.equals(String.withCString("VAnd")) || op.equals(String.withCString("VOr")) || op.equals(String.withCString("VXor")) || op.equals(String.withCString("VMax")) || op.equals(String.withCString("VMin")))
            {
            emitVBin(n);
            return true;
            }
        if (op.equals(String.withCString("VMulHi")))
            {
            emitVMulHi(n);
            return true;
            }
        if (op.equals(String.withCString("VLShr")))
            {
            emitVLShr(n);
            return true;
            }
        if (op.equals(String.withCString("VReduceAdd")))
            {
            emitVReduceAdd(n);
            return true;
            }
        if (op.equals(String.withCString("VReduceMax")) || op.equals(String.withCString("VReduceMin")))
            {
            emitVReduceMinMax(n);
            return true;
            }
        if (op.equals(String.withCString("VICmp")))
            {
            emitVICmp(n);
            return true;
            }
        if (op.equals(String.withCString("VAddLP")))
            {
            emitVAddLP(n);
            return true;
            }
        return false;
        }

    static String* intBinOpMnemonic(String* op)
        {
        if (op.equals(String.withCString("Add")))
            return String.withCString("add");
        if (op.equals(String.withCString("Sub")))
            return String.withCString("sub");
        if (op.equals(String.withCString("Mul")))
            return String.withCString("imul");
        if (op.equals(String.withCString("And")))
            return String.withCString("and");
        if (op.equals(String.withCString("Or")))
            return String.withCString("or");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("xor");
        return (String*)0;
        }

    void emitConst(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        IROperand* k = (IROperand*)n.ops().get((u32)0);
        // A HOMED float constant has to reach its HOME. This used to write the
        // raw bits into the slot and stop — "the slot is read back with
        // movss/movsd", which stopped being true when floats got registers.
        // float_math's `double acc = 0.0` then started at whatever the seeding
        // loop had left in that xmm, and came out exactly 1 too high.
        String* chome = homeOf(n.res());
        if (isFloatTy(n.res().ty()) && k.kind() == (u8)OPK_IMMF && isXmmHome(chome))
            {
            String* h2 = k.fpHex();
            if (n.res().ty().equals(String.withCString("F64")))
                {
                _out.appendFormat("\tmovabs\trax, %s\n", decOfHex64(h2).cString());
                _out.appendFormat("\tmovq\t%s, rax\n", chome.cString());
                }
            else
                {
                _out.appendFormat("\tmov\teax, %lu\n", f32BitsOfHex(h2));
                _out.appendFormat("\tmovd\t%s, eax\n", chome.cString());
                }
            return;
            }
        if (isFloatTy(n.res().ty()) && k.kind() == (u8)OPK_IMMF && hasSlot(n.res()))
            {
            // The immediate carries the raw IEEE DOUBLE bits; the slot is read
            // back with movss/movsd, so the pattern goes straight in. An F32
            // narrows first.
            String* hex = k.fpHex();
            if (n.res().ty().equals(String.withCString("F64")))
                {
                _out.appendFormat("\tmovabs\trax, %s\n", decOfHex64(hex).cString());
                _out.appendFormat("\tmov\t[rbp-%lu], rax\n", slotOf(n.res()));
                }
            else
                {
                _out.appendFormat("\tmov\tdword ptr [rbp-%lu], %lu\n",
                                  slotOf(n.res()), f32BitsOfHex(hex));
                }
            return;
            }
        load(k, (u8)'a');
        store((u8)'a', n.res());
        }

    // A 16-hex-digit pattern as an unsigned DECIMAL, which is how `movabs`
    // spells it. There is no 64-bit integer here, so the digits are produced by
    // long division on the two halves.
    static String* decOfHex64(String* hex)
        {
        Array* digits = new Array();
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            digits.add((Object*)Number.withU32(hexDigit(hex, i)));
        String* outDigits = String.withCString("");
        bool any = false;
        // Repeated division by 10 over the base-16 digit string.
        while (true)
            {
            u32 rem = (u32)0;
            bool nonZero = false;
            for (u32 i = (u32)0; i < digits.count(); i = i + (u32)1)
                {
                u32 cur = rem * (u32)16 + ((Number*)digits.get(i)).asU32();
                u32 q = cur / (u32)10;
                rem = cur % (u32)10;
                digits.set(i, (Object*)Number.withU32(q));
                if (q != (u32)0)
                    nonZero = true;
                }
            String* d = String.withCString("");
            d.appendFormat("%lu", rem);
            d.append(outDigits);
            outDigits = d;
            any = true;
            if (!nonZero)
                break;
            }
        return any ? outDigits : String.withCString("0");
        }

    static u32 hexDigit(String* hex, u32 i)
        {
        if (i >= hex.byteLength())
            return (u32)0;
        u8 c = hex.byteAt(i);
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (u32)(c - (u8)'a') + (u32)10;
        if (c >= (u8)'A' && c <= (u8)'F')
            return (u32)(c - (u8)'A') + (u32)10;
        return (u32)0;
        }

    static u32 f32BitsOfHex(String* hex)
        {
        Array* le = new Array();
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            {
            u32 idx = ((u32)7 - i) * (u32)2;
            le.add((Object*)Number.withU32(hexDigit(hex, idx) * (u32)16 + hexDigit(hex, idx + (u32)1)));
            }
        return f32BitsOfLE(le);
        }

    void emitZExt(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        store((u8)'a', n.res());
        }

    void emitSExt(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        u32 dw = widthOfValue(n.res());
        loadExt((IROperand*)n.ops().get((u32)0), (u8)'a', true, dw < (u32)4 ? (u32)4 : dw);
        store((u8)'a', n.res());
        }

    void emitPlainCast(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        load((IROperand*)n.ops().get((u32)0), (u8)'a');
        store((u8)'a', n.res());
        }

    // A reinterpret zero-extends, so a width change leaves no stale high bits.
    void emitReinterpret(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        loadZX((IROperand*)n.ops().get((u32)0), (u8)'a');
        store((u8)'a', n.res());
        }

    // An integer becomes a full 64-bit pointer (bug 360): a signed source is
    // sign-extended, an unsigned one zero-extended.
    void emitIntToPtr(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        loadIndex((IROperand*)n.ops().get((u32)0), (u8)'a');
        store((u8)'a', n.res());
        }

    void emitBinary(IRInsn* n, String* mn)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        u32 w = widthOfValue(n.res());
        if (w < (u32)4)
            w = (u32)4;
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        // imul takes an immediate ONLY in its three-operand form; the
        // two-address path below cannot spell one.
        //
        // And that immediate is an imm32, SIGN-EXTENDED — there is no
        // imul r64, r/m64, imm64. A wider multiplier silently lost its top
        // 32 bits here (x * 0x100000001B3 became x * 0x1B3 — the FNV-1a 64
        // prime, so every 64-bit hash disagreed with arm64). Wide constants
        // fall through to the general path, whose srcOperand stages them in
        // a register.
        if (mn.equals(String.withCString("imul")) && o1.kind() == (u8)OPK_IMMI && !(w == (u32)8 && (o1.imm() > (i64)2147483647 || o1.imm() < (i64)0 - (i64)2147483648)))
            {
            String* rh = homeOf(n.res());
            String* dst = rh != (String*)0 ? regView(rh, w) : reg((u8)'a', w);
            if (o0.kind() == (u8)OPK_USE)
                {
                String* src = srcOperand(o0, w, String.withCString(""));
                _out.appendFormat("\timul\t%s, %s, %s\n", dst.cString(), src.cString(),
                                  immText(o1).cString());
                }
            else
                {
                movOperand(o0, dst, w);
                _out.appendFormat("\timul\t%s, %s, %s\n", dst.cString(), dst.cString(),
                                  immText(o1).cString());
                }
            if (rh == (String*)0)
                store((u8)'a', n.res());
            return;
            }
        String* resHome = homeOf(n.res());
        // Two-address form when the result is homed: compute directly in the
        // result register rather than round-tripping through scratch. For a
        // commutative op, keep whichever operand already sits there.
        if (resHome != (String*)0 && (w == (u32)4 || w == (u32)8))
            {
            String* resR = regView(resHome, w);
            bool commut = !mn.equals(String.withCString("sub"));
            IROperand* keep = o0;
            IROperand* other = o1;
            if (commut && sameHome(o1, resHome))
                {
                keep = o1;
                other = o0;
                }
            bool keepInRes = sameHome(keep, resHome);
            // `other` is staged FIRST — into rcx if it currently lives in resR —
            // so producing `keep` into resR cannot clobber it.
            String* os = srcOperand(other, w, resR);
            if (!keepInRes)
                movOperand(keep, resR, w);
            _out.appendFormat("\t%s\t%s, %s\n", mn.cString(), resR.cString(), os.cString());
            return;
            }
        load(o0, (u8)'a');
        load(o1, (u8)'c');
        _out.appendFormat("\t%s\t%s, %s\n", mn.cString(), reg((u8)'a', w).cString(),
                          reg((u8)'c', w).cString());
        store((u8)'a', n.res());
        }

    bool sameHome(IROperand* op, String* home)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return false;
        String* h = homeOf(op.val());
        return h != (String*)0 && h.equals(home);
        }

    void movOperand(IROperand* op, String* dst, u32 w)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            _out.appendFormat("\tmov\t%s, %s\n", dst.cString(), immText(op).cString());
            return;
            }
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
            {
            String* home = homeOf(op.val());
            if (home != (String*)0)
                {
                movFromHome(home, w, dst);
                return;
                }
            if (hasSlot(op.val()))
                {
                _out.appendFormat("\tmov\t%s, [rbp-%lu]\n", dst.cString(), slotOf(op.val()));
                return;
                }
            }
        _out.appendFormat("\tmov\t%s, 0\n", dst.cString());
        }

    // A right shift pulls the HIGH bits down, so a narrow operand loaded with
    // stale high bits gives garbage — the value is extended to the full shift
    // width first, arithmetically for AShr and with zeroes otherwise.
    void emitShift(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        u32 w = widthOfValue(n.res());
        if (w < (u32)4)
            w = (u32)4;
        String* op = n.op();
        bool ashr = op.equals(String.withCString("AShr"));
        loadExt((IROperand*)n.ops().get((u32)0), (u8)'a', ashr, w);
        String* mn = String.withCString(op.equals(String.withCString("Shl")) ? "shl"
                                                                             : (op.equals(String.withCString("LShr")) ? "shr" : "sar"));
        IROperand* cnt = (IROperand*)n.ops().get((u32)1);
        if (cnt.kind() == (u8)OPK_IMMI)
            {
            // The CPU masks cl the same way, so the constant is masked to match.
            i32 c = cnt.imm() & (w == (u32)8 ? (i32)63 : (i32)31);
            _out.appendFormat("\t%s\t%s, %ld\n", mn.cString(), reg((u8)'a', w).cString(), c);
            }
        else
            {
            load(cnt, (u8)'c');
            _out.appendFormat("\t%s\t%s, cl\n", mn.cString(), reg((u8)'a', w).cString());
            }
        store((u8)'a', n.res());
        }

    void emitUnary(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return;
        u32 w = widthOfValue(n.res());
        if (w < (u32)4)
            w = (u32)4;
        load((IROperand*)n.ops().get((u32)0), (u8)'a');
        _out.appendFormat("\t%s\t%s\n", n.op().equals(String.withCString("Neg")) ? "neg" : "not",
                          reg((u8)'a', w).cString());
        store((u8)'a', n.res());
        }

    void emitICmp(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        // Fused into a Select: the compare is re-issued at the cmov so the
        // flags reach it directly. Nothing to emit here.
        if (inSelSkip(n.res()))
            return;
        String* p = n.pred();
        bool sg = isSignedPred(p);
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        u32 wl = o0.kind() == (u8)OPK_USE ? widthOfValue(o0.val()) : (u32)4;
        u32 wr = o1.kind() == (u8)OPK_USE ? widthOfValue(o1.val()) : (u32)4;
        u32 w = wl > wr ? wl : wr;
        if (w < (u32)4)
            w = (u32)4;
        loadExt(o0, (u8)'a', sg, w);
        // FOLD A CONSTANT RIGHT-HAND SIDE. x86 has `cmp r32, imm32` and
        // `cmp r64, imm32` (sign-extended); nothing used either, so every
        // comparison against a literal cost an extra `mov` into rcx first, in
        // every loop guard in every program. arm64 folds the same operand from
        // the same IR, which already carries it as an immediate.
        //
        // Against ZERO, `test r, r` sets the same flags with no immediate at
        // all — but only for equality and the unsigned predicates, because
        // `test` clears CF and OF and the signed tests read those.
        bool folded = false;
        if (o1.kind() == (u8)OPK_IMMI)
            {
            i64 k = o1.imm();
            bool fits = w <= (u32)4 || (k >= (i64)-2147483648 && k <= (i64)2147483647);
            if (fits)
                {
                bool zeroOK = k == (i64)0
                              && (p.equals(String.withCString("EQ")) || p.equals(String.withCString("NE"))
                                  || p.equals(String.withCString("ULT")) || p.equals(String.withCString("UGE")));
                if (zeroOK)
                    {
                    _out.appendFormat("\ttest\t%s, %s\n", reg((u8)'a', w).cString(),
                                      reg((u8)'a', w).cString());
                    folded = true;
                    }
                else
                    {
                    // Print a 32-bit immediate in its SIGNED reading: the bit
                    // pattern is what a 32-bit compare tests, and `cmp eax, -1`
                    // takes the sign-extended imm8 encoding where
                    // `cmp eax, 4294967295` takes imm32. The assembler chooses
                    // by whether the printed value fits a signed byte.
                    i64 pk = w == (u32)4 ? (i64)(i32)k : k;
                    _out.appendCString("\tcmp\t");
                    _out.append(reg((u8)'a', w));
                    _out.appendCString(", ");
                    _out.append(String.withI64(pk));
                    _out.appendCString("\n");
                    folded = true;
                    }
                }
            }
        if (!folded)
            {
            loadExt(o1, (u8)'c', sg, w);
            _out.appendFormat("\tcmp\t%s, %s\n", reg((u8)'a', w).cString(), reg((u8)'c', w).cString());
            }
        // Fused into the block's CondBranch: the flags reach the branch, so no
        // boolean is materialised.
        if (inFused(n.res()))
            return;
        _out.appendFormat("\t%s\tal\n\tmovzx\teax, al\n", setccFor(p).cString());
        store((u8)'a', n.res());
        }

    bool inFused(IRValue* v)
        {
        return _fusedCmp != (Map*)0 && v != (IRValue*)0 && _fusedCmp.get((Hashable*)v) != (Object*)0;
        }

    bool inSelSkip(IRValue* v)
        {
        return _selSkip != (Map*)0 && v != (IRValue*)0 && _selSkip.get((Hashable*)v) != (Object*)0;
        }

    // cmov taken when the ICmp predicate is FALSE — a fused Select moves its
    // FALSE value over the true one already in the destination.
    static String* cmovForNegated(String* p)
        {
        if (p == (String*)0)
            return String.withCString("cmovne");
        if (p.equals(String.withCString("EQ")))
            return String.withCString("cmovne");
        if (p.equals(String.withCString("NE")))
            return String.withCString("cmove");
        if (p.equals(String.withCString("SLT")))
            return String.withCString("cmovge");
        if (p.equals(String.withCString("SLE")))
            return String.withCString("cmovg");
        if (p.equals(String.withCString("SGT")))
            return String.withCString("cmovle");
        if (p.equals(String.withCString("SGE")))
            return String.withCString("cmovl");
        if (p.equals(String.withCString("ULT")))
            return String.withCString("cmovae");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("cmova");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("cmovbe");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("cmovb");
        return String.withCString("cmovne");
        }

    Map* _fusedCmp;
    Map* _selSkip;
    Map* _selCmp;

    static bool isSignedPred(String* p)
        {
        if (p == (String*)0)
            return false;
        return p.equals(String.withCString("SLT")) || p.equals(String.withCString("SLE")) || p.equals(String.withCString("SGT")) || p.equals(String.withCString("SGE"));
        }

    static String* setccFor(String* p)
        {
        if (p == (String*)0)
            return String.withCString("sete");
        if (p.equals(String.withCString("EQ")))
            return String.withCString("sete");
        if (p.equals(String.withCString("NE")))
            return String.withCString("setne");
        if (p.equals(String.withCString("SLT")))
            return String.withCString("setl");
        if (p.equals(String.withCString("SLE")))
            return String.withCString("setle");
        if (p.equals(String.withCString("SGT")))
            return String.withCString("setg");
        if (p.equals(String.withCString("SGE")))
            return String.withCString("setge");
        if (p.equals(String.withCString("ULT")))
            return String.withCString("setb");
        if (p.equals(String.withCString("ULE")))
            return String.withCString("setbe");
        if (p.equals(String.withCString("UGT")))
            return String.withCString("seta");
        if (p.equals(String.withCString("UGE")))
            return String.withCString("setae");
        return String.withCString("sete");
        }

    // cond ? a : b, branchless.
    void emitSelect(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)3)
            return;
        u32 w = widthOfValue(n.res());
        if (w < (u32)4)
            w = (u32)4;
        load((IROperand*)n.ops().get((u32)1), (u8)'a');   // the true value
        load((IROperand*)n.ops().get((u32)2), (u8)'d');   // the false value
        // The condition is an ICmp read only here: re-issue its compare now
        // (rax/rdx hold the two values, rcx is free) and let the cmov read the
        // flags. Take the FALSE value when the predicate does not hold.
        IRInsn* scmp = _selCmp == (Map*)0 ? (IRInsn*)0 : (IRInsn*)_selCmp.get((Hashable*)n.res());
        IROperand* c0 = (IROperand*)n.ops().get((u32)0);
        if (scmp != (IRInsn*)0 && c0.kind() == (u8)OPK_USE && inSelSkip(c0.val()))
            {
            String* sp = scmp.pred();
            bool ssg = isSignedPred(sp);
            IROperand* so0 = (IROperand*)scmp.ops().get((u32)0);
            u32 cw = so0.kind() == (u8)OPK_USE ? widthOfValue(so0.val()) : (u32)4;
            if (cw < (u32)4)
                cw = (u32)4;
            loadExt(so0, (u8)'c', ssg, cw);
            i64 k = ((IROperand*)scmp.ops().get((u32)1)).imm();
            bool zeroOK = k == (i64)0
                          && (sp.equals(String.withCString("EQ")) || sp.equals(String.withCString("NE"))
                              || sp.equals(String.withCString("ULT")) || sp.equals(String.withCString("UGE")));
            if (zeroOK)
                _out.appendFormat("\ttest\t%s, %s\n", reg((u8)'c', cw).cString(),
                                  reg((u8)'c', cw).cString());
            else
                {
                i64 pk = cw == (u32)4 ? (i64)(i32)k : k;
                _out.appendCString("\tcmp\t");
                _out.append(reg((u8)'c', cw));
                _out.appendCString(", ");
                _out.append(String.withI64(pk));
                _out.appendCString("\n");
                }
            _out.appendFormat("\t%s\t%s, %s\n", cmovForNegated(sp).cString(),
                              reg((u8)'a', w).cString(), reg((u8)'d', w).cString());
            store((u8)'a', n.res());
            return;
            }
        loadZX(c0, (u8)'c'); // the condition
        u32 ccw = condWidth(c0);
        _out.appendFormat("\ttest\t%s, %s\n", reg((u8)'c', ccw).cString(), reg((u8)'c', ccw).cString());
        _out.appendFormat("\tcmove\t%s, %s\n", reg((u8)'a', w).cString(), reg((u8)'d', w).cString());
        store((u8)'a', n.res());
        }

    // x86 division: the dividend in eax, the divisor in ecx; the quotient comes
    // back in eax and the remainder in edx. Signed needs cdq first, unsigned a
    // zeroed edx.
    void emitDivRem(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
            return;
        String* op = n.op();
        bool sgned = op.equals(String.withCString("SDiv")) || op.equals(String.withCString("SRem"));
        bool rem = op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem"));
        u32 w = widthOfValue(n.res());
        if (w < (u32)4)
            w = (u32)4;
        // A constant divisor becomes a reciprocal multiply, avoiding the
        // 20-to-40-cycle div. Every xtc integer type is at most 32 bits, so the
        // dividend extends to 32 and one W=32 magic serves every width.
        i32 dC = (i32)0;
        if (w == (u32)4 && constDivisor((IROperand*)n.ops().get((u32)1), &dC))
            {
            u32 ad = (u32)(dC < (i32)0 ? -dC : dC);
            bool nonPow2 = ad >= (u32)2 && (ad & (ad - (u32)1)) != (u32)0;
            if (nonPow2 && !sgned)
                {
                emitMagicUnsigned(n, dC, rem);
                return;
                }
            if (nonPow2 && sgned)
                {
                emitMagicSigned(n, dC, rem);
                return;
                }
            }
        loadExt((IROperand*)n.ops().get((u32)0), (u8)'a', sgned, w);
        loadExt((IROperand*)n.ops().get((u32)1), (u8)'c', sgned, w);
        if (sgned)
            _out.appendFormat("\t%s\n", w == (u32)8 ? "cqo" : "cdq");
        else
            _out.appendCString("\txor\tedx, edx\n");
        _out.appendFormat("\t%s\t%s\n", sgned ? "idiv" : "div", reg((u8)'c', w).cString());
        store(rem ? (u8)'d' : (u8)'a', n.res());
        }

    static bool functionHasAsm(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (((IRInsn*)bb.insns().get(i)).op().equals(String.withCString("Asm")))
                    return true;
            }
        return false;
        }

    // A >8-byte aggregate return travels through a hidden pointer rather than
    // in registers — the WIN64 threshold. System V returns up to 16 bytes in
    // rax:rdx; gating on the ABI keeps a System V frame from reserving a slot
    // an under-16-byte return never uses.
    bool returnsBigAgg(String* t)
        {
        return _win64 && isAggTy(t) && aggSize(layoutOf(t)) > (u32)8;
        }

    // System V: an aggregate over 16 bytes is MEMORY class — returned through
    // a hidden pointer in rdi (shifting the GP args right by one), which the
    // callee also hands back in rax. Before this predicate the port packed
    // EVERY aggregate into rax:rdx, so a 32-byte struct came back with its
    // last 16 bytes never written (hfa_struct_return).
    bool returnsSysVMemAgg(String* t)
        {
        return !_win64 && isAggTy(t) && aggSize(layoutOf(t)) > (u32)16;
        }

    void assignSlots(IRFunc* fn)
        {
        _slot = new Map();
        u32 cur = (u32)0;
        // PRINT order, not id order — mirrors the reference (bug 090).
        Array* order = fn.valuesInPrintOrder();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)order.get(i);
            if (isMemTy(v.ty()))
                continue;
            cur = cur + slotSizeOf(v);
            _slot.set((Hashable*)v, (Object*)Number.withU32(cur));
            }
        _frame = cur;
        }

    u32 slotOf(IRValue* v)
        {
        if (v == (IRValue*)0)
            return (u32)0;
        Object* o = _slot.get((Hashable*)v);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
        }

    bool hasSlot(IRValue* v)
        {
        return v != (IRValue*)0 && _slot.get((Hashable*)v) != (Object*)0;
        }

    String* homeOf(IRValue* v)
        {
        if (_homing == (Homing*)0 || v == (IRValue*)0)
            return (String*)0;
        return _homing.homeOf(v.pid());
        }

    // ── Module data ──────────────────────────────────────────────────────
    void emitModuleData(IRModule* m)
        {
        String* rodata = new String();
        String* data = new String();
        String* bss = new String();
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            if (sym.kind() == (u8)SYM_STRINGLIT)
                {
                rodata.appendFormat("%s:\n", safeSym(sym.name()).cString());
                emitBytes(sym.bytes(), rodata);
                }
            else if (sym.kind() == (u8)SYM_DATAGLOBAL)
                {
                // An extern global is defined in ANOTHER module: reserving
                // storage here would give this one a second copy whose writes
                // never reach the other's.
                if (sym.isExtern())
                    continue;
                emitDataGlobal(sym, data, bss);
                }
            }
        String* vtbl = new String();
        emitVTables(m, vtbl);
        if (rodata.byteLength() > (u32)0)
            {
            _out.appendCString("\t.section .rodata\n");
            _out.append(rodata);
            }
        if (vtbl.byteLength() > (u32)0)
            {
            _out.appendCString("\t.data\n");
            _out.append(vtbl);
            }
        if (data.byteLength() > (u32)0)
            {
            _out.appendCString("\t.data\n");
            _out.append(data);
            }
        if (bss.byteLength() > (u32)0)
            {
            _out.appendCString("\t.bss\n");
            _out.append(bss);
            }
        // Load-time constructors: a table in .data between __xt_ctors_start
        // and __xt_ctors_end, walked by crt-linux.s / crt-win64.s before main
        // (bug 134 — the .init_array entry this used to emit was folded into
        // .data and never walked). The entry module always defines the
        // bounds, empty or not; a module without main or constructors defines
        // nothing. Mirrors the reference.
        bool hasMain = false;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            if (((IRFunc*)m.funcs().get(f)).name().equals(String.withCString("main")))
                hasMain = true;
        if (m.modinits().count() > (u32)0 || hasMain)
            {
            _out.appendCString("\t.data\n\t.p2align 3\n\t.globl\t__xt_ctors_start\n__xt_ctors_start:\n");
            for (u32 i = (u32)0; i < m.modinits().count(); i = i + (u32)1)
                _out.appendFormat("\t.quad\t%s\n", ((String*)m.modinits().get(i)).cString());
            _out.appendCString("\t.globl\t__xt_ctors_end\n__xt_ctors_end:\n");
            }
        }

    void emitDataGlobal(IRSymbol* sym, String* data, String* bss)
        {
        String* gt = sym.globalTy();
        Array* bytes = sym.bytes();
        if (bytes != (Array*)0 && bytes.count() > (u32)0)
            {
            if (isAggTy(gt))
                bytes = relayAgg(bytes, layoutOf(gt));
            // A float global's initialiser arrives as 8 IEEE-double bits
            // whatever its declared width, so an F32 would otherwise keep the
            // double's low four (zero) bytes. A byte-list initialiser already
            // matches the slot size and bypasses this.
            else if (isFloatTy(gt) && bytes.count() != fieldWidth(gt))
                bytes = relayFloat(bytes, gt);
            // A file-scope global has EXTERNAL linkage in C — export it so
            // separate units share one definition (win64/PE keeps its own path).
            if (!_win64)
                data.appendFormat("\t.globl\t%s\n", safeSym(sym.name()).cString());
            data.appendFormat("%s:\n", safeSym(sym.name()).cString());
            emitBytes(bytes, data);
            return;
            }
        // Uninitialised, so zeroed BSS — sized with the RECOMPUTED native width,
        // not the front end's. A bare class-pointer global has front-end width
        // 0, which reserved one byte, and an 8-byte pointer store then clobbered
        // the next global — whose stale value faulted the ARC release before the
        // assignment.
        u32 sz = fieldWidth(gt);
        if (sz == (u32)0)
            sz = (u32)1;
        if (_win64)
            {
            bss.appendFormat("%s:\n\t.zero\t%lu\n", safeSym(sym.name()).cString(), sz);
            }
        else
            {
            // An UNINITIALISED file-scope global is a C tentative definition ->
            // a COMMON symbol, so separately-compiled units (and #used C
            // libraries) merge it to one slot. A local .bss def gave each unit a
            // PRIVATE copy (c2xc bug 36, cross-object variant).
            u32 al = sz >= (u32)8 ? (u32)8 : (sz >= (u32)4 ? (u32)4 : (sz >= (u32)2 ? (u32)2 : (u32)1));
            bss.appendFormat("\t.comm\t%s, %lu, %lu\n", safeSym(sym.name()).cString(), sz, al);
            }
        }

    // One 8-byte pointer per slot — host pointers are 8 bytes here.
    void emitVTables(IRModule* m, String* vtbl)
        {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            if (sym.kind() != (u8)SYM_VTABLE)
                continue;
            // An imported class's vtable lives in ITS library; a second table at
            // a different address would break RTTI identity, which compares
            // vtable addresses.
            if (sym.isExtern())
                continue;
            String* nm = safeSym(sym.name());
            vtbl.appendFormat("\t.globl\t%s\n\t.p2align 2\n%s:\n", nm.cString(), nm.cString());
            Array* e = sym.slots();
            if (e == (Array*)0 || e.count() == (u32)0)
                {
                vtbl.appendCString("\t.quad\t0\n");
                continue;
                }
            for (u32 k = (u32)0; k < e.count(); k = k + (u32)1)
                {
                String* entry = (String*)e.get(k);
                if (entry.byteLength() == (u32)0)
                    {
                    vtbl.appendCString("\t.quad\t0\n");
                    continue;
                    }
                // A conformance itable is (protoId, &table) pairs, and the id is
                // a literal VALUE, not a label.
                String* pfx = String.withCString("__protoid_");
                if (entry.hasPrefix(pfx))
                    vtbl.appendFormat("\t.quad\t%s\n", entry.substringFromByte(pfx.byteLength()).cString());
                else
                    vtbl.appendFormat("\t.quad\t%s\n", entry.cString());
                }
            }
        }

    // Re-lay an aggregate image from the IR's widths into this target's. Both
    // are little-endian, so only the field OFFSETS move.
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
        if (total == (u32)0)
            return src;
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
            }
        }

    static u32 srcFieldWidth(IRLayout* l, u32 idx)
        {
        u32 start = l.offsetAt(idx);
        u32 end = (idx + (u32)1 < l.fieldCount()) ? l.offsetAt(idx + (u32)1) : l.size();
        return end > start ? end - start : (u32)0;
        }

    Array* relayFloat(Array* src, String* ty)
        {
        if (ty.equals(String.withCString("F64")))
            {
            Array* dst = new Array();
            for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
                dst.add(i < src.count() ? src.get(i) : (Object*)Number.with((i32)0));
            return dst;
            }
        u32 bits = f32BitsOfLE(src);
        Array* dst = new Array();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            dst.add((Object*)Number.with((i32)((bits >> ((u32)8 * i)) & (u32)$FF)));
        return dst;
        }

    // The IEEE single bits of a little-endian double image. Done on the bit
    // pattern so it round-trips exactly on a host without an f64 type.
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

    // Eight bytes to a line, as the reference does.
    void emitBytes(Array* bytes, String* into)
        {
        if (bytes == (Array*)0)
            return;
        u32 i = (u32)0;
        while (i < bytes.count())
            {
            into.appendCString("\t.byte\t");
            for (u32 j = i; j < bytes.count() && j < i + (u32)8; j = j + (u32)1)
                {
                if (j > i)
                    into.appendCString(", ");
                into.appendFormat("%lu", ((Number*)bytes.get(j)).asU32());
                }
            into.appendCString("\n");
            i = i + (u32)8;
            }
        }
    }
