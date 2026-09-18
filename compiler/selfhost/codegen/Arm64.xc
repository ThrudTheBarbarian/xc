// Arm64.xc — the IR, as AArch64 assembly.
// =========================================================================
//
// self-hosting M14. The port of XTArm64Backend. The A9's back end went first
// (M9) because that is the machine the compiler has to RUN on; this one is the
// machine the compiler is BUILT on, so it is what closes the loop: with it,
// every stage on the host — preprocessor, lexer, parser, sema, IR lowering,
// optimiser, code generator — exists in xtc.
//
// The oracle is `xtcg-arm64 -O0`: same IR in, and the assembly text has to
// come out byte for byte the same. `-O0` because the optimiser is a separate
// port and already at parity — at -O0 the pipeline is a pass-through, so this
// compares the CODE GENERATOR and nothing else. `selfhost/tools/arm64-diff.sh`
// is the harness.
//
// AArch64 is a 64-bit machine: pointers are 8 bytes and every scalar value
// gets an 8-byte frame slot. As with every other backend, aggregate sizes and
// field offsets are recomputed here in the target's own widths rather than
// taken from the IR's layout table — the type-width invariant
// (private:docs/Design/type-width-invariant.md) is exactly about the two agreeing.
//
// An opcode this slice does not emit yet is recorded BY NAME and the whole
// file is refused (exit 3). A back end that quietly skipped an instruction
// would emit assembly that assembles cleanly and computes the wrong thing,
// which is the one failure this harness exists to prevent.

#import "Foundation.xc"
#import "MsFn.xc"
#import "Stdio.xc"
#import "Process.xc"
#import "Ir.xc"
#import "Homing.xc"

class Arm64
{
    IRModule* _m;
    // Thread-safe ARC (private:docs/Design/threading.md §4.1): the refcount update as an
    // ATOMIC read-modify-write. Decided per module in assembly(), on exactly
    // when the module spawns a thread — two threads sharing an object race on a
    // plain load/add/store and either leak it or free it while it is live.
    bool       _atomicArc;
    // Plain AAPCS64 instead of Darwin's two deviations: the C-variadic tail is
    // placed like a named argument, and every overflow argument gets an 8-byte
    // slot rather than being packed to its natural size. Set for `-A android`.
    bool       _aapcs64Abi;
    // Whether ARMv8.1 LSE is guaranteed. Apple Silicon is ARMv8.5; Android's
    // minSdk floor is plain armv8-a, where `ldaddlh`/`ldaddalh` do not exist —
    // the NDK assembler refuses them and a device without them takes SIGILL.
    bool       _lseAtomics;
    IRFunc*   _fn;
    String*   _out;
    Map*      _slot;            // value -> byte offset in the frame
    Map*      _defOf;           // value -> the instruction that defines it
    Map*      _useCount;        // value -> how many operands read it
    Map*      _foldedAddr;      // values whose def is folded away (never emitted)
    Map*      _foldInfo;        // a Load/Store's pointer -> the addr insn to inline
    Map*      _fusedCmps;       // ICmps emitted as part of their block's branch
    u32       _frame;           // the frame size the prologue reserves
    u32       _maxOutStack;     // AAPCS64 outgoing-argument area, at the bottom
    bool      _failed;          // an opcode this slice does not emit yet
    String*   _why;
    Array*    _missing;         // …every distinct one, for the work queue

    void init(void)
    {
        _out = new String();
        _slot = new Map();
        _missing = new Array();
        _failed = false;
        _frame = (u32)0;
        _maxOutStack = (u32)0;
        _aapcs64Abi = false;      // Darwin's deviations unless told otherwise
        _lseAtomics = true;       // Apple Silicon always has them
    }

    void setAapcs64Abi(bool on) { _aapcs64Abi = on; }
    void setLseAtomics(bool on) { _lseAtomics = on; }

    bool   failed(void)  { return _failed; }
    String* why(void)    { return _why; }
    Array* missing(void) { return _missing; }

    // Record an opcode this slice cannot emit. Recorded once each, so the
    // harness's report is the distinct work queue rather than a frequency
    // count of one file's instructions.
    void unsupported(String* op)
    {
        _failed = true;
        if (_why == (String*)0) _why = op;
        for (u32 i = (u32)0; i < _missing.count(); i = i + (u32)1)
            if (((String*)_missing.get(i)).equals(op)) return;
        _missing.add((Object*)op);
    }

    // ── Type sizing, AArch64-native ──────────────────────────────────────
    // A type is its SPELLING here, so these read the text rather than a kind.
    static bool isPtrTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Ptr(")); }

    static bool isAggTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Agg(")); }

    static bool isMemTy(String* t)
    { return t != (String*)0 && t.equals(String.withCString("Mem")); }

    static bool isVecTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Vec(")); }

    static bool isFloatTy(String* t)
    {
        return t != (String*)0 && (t.equals(String.withCString("F32"))
                                || t.equals(String.withCString("F64")));
    }

    // The width a scalar leaf occupies. Pointers are 8 on this target — the
    // half of the type-width invariant the BACK END owns.
    static u32 width(String* t)
    {
        if (t == (String*)0) return (u32)0;
        if (t.equals(String.withCString("I8"))  || t.equals(String.withCString("U8"))
         || t.equals(String.withCString("Bool"))) return (u32)1;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")))
            return (u32)2;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
         || t.equals(String.withCString("F32"))) return (u32)4;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))
         || t.equals(String.withCString("F64"))) return (u32)8;
        if (isPtrTy(t)) return (u32)8;
        if (isVecTy(t)) return (u32)16;
        return (u32)0;
    }

    // log2 of a global's alignment: natural, capped at 8 — the cap the front
    // end already uses for struct fields on this target. Derived from SIZE
    // because that is all the emit site has; right for every scalar, and safe
    // for an aggregate, since anything 8 bytes or larger may hold a pointer.
    static u32 globalP2Align(u32 size)
    {
        if (size >= (u32)8) return (u32)3;
        if (size >= (u32)4) return (u32)2;
        if (size >= (u32)2) return (u32)1;
        return (u32)0;
    }

    // ── Entry point ──────────────────────────────────────────────────────
    String* assembly(IRModule* m)
    {
        _m = m;
        _atomicArc = spawnsThreads(m);
        _msFns = referencesSymbol(m, String.withCString("_xt_check_bounds"))
               ? new Array() : (Array*)0;
        _out = new String();
        _out.appendCString("// Generated by XTArm64Backend — DO NOT EDIT\n");
        _out.appendCString(".text\n\n");
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            // Each function is peepholed in ISOLATION — slot offsets are
            // per-function, so a scan across a boundary would compare offsets
            // from two different frames.
            String* module = _out;
            _out = new String();
            emitFunction((IRFunc*)m.funcs().get(f));
            _out.appendCString("\n");   // the blank line before the next function
            module.append(peepholeFallthrough(peepholeCopyProp(peepholeSpills(_out))));
            _out = module;
        }
        emitModuleData(m);
        emitMsMap();
        return _out;
    }

    // One function: the slot table, then the body.
    void emitFunction(IRFunc* fn)
    {
        _fn = fn;
        // A `.L` label is file-scoped in Mach-O but the counter is per
        // function, exactly as the original's per-function context makes it.
        _labelCounter = (u32)0;
        allocateVectorRegisters(fn);
        collectDefs(fn);            // _defOf/_useCount/_maxOutStack; computeAddrFold reads defOf
        computeAddrFold(fn);        // liveness must see the folds, so this first
        buildSlots(fn);             // colouring runs liveness, so it runs AFTER the folds
        computeNoWrap(fn);          // needs defOf, which computeAddrFold built
        scanUses(fn);
        computeIntervals(fn);
        loopExtendStarts(fn);       // register homing needs the loop-aware
                                    // intervals too, not just slot colouring (bug 203)
        assignRegisters(fn);
        computeFusions(fn);         // after allocation, as the original does

        // The callee-save area sits just past the value slots, so value-slot
        // offsets (and therefore AddrOf addresses) are unchanged by homing. A
        // function that homes nothing keeps a byte-identical frame.
        _saveAreaOffset = _valueSlotEnd;
        if (_savedRegs.count() > (u32)0) {
            u32 end = _saveAreaOffset + (u32)8 * _savedRegs.count();
            _frame = (end + (u32)15) & ~(u32)15;
            if (_frame < (u32)16) _frame = (u32)16;
        }

        collectMsFn(fn);        // after allocation: homes and saves are decided,
                                //   and _saveAreaOffset is assigned just above
        emitPrologue(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            emitBlock(fn, (IRBlock*)fn.blocks().get(b));
    }

    // The checked-build parameter map (private:docs/Design/memory-safety.md). Collected
    // only when the module references _xt_check_bounds — decided from the
    // MODULE, not from a flag, for the same reason atomic ARC is: this back end
    // has two callers and a flag plumbed to one is a decision the other gets
    // wrong.
    Array* _msFns;          // of MsFn@, or 0 when this is not a checked build

    u32 _saveAreaOffset;

    // The Mach-O underscore convention: a C stub linking against `add` finds
    // `_add`.
    void emitPrologue(IRFunc* fn)
    {
        _out.appendFormat(".globl _%s\n", fn.name().cString());
        _out.appendFormat(".align 2\n_%s:\n", fn.name().cString());
        // The pre-indexed `stp [sp, #-N]!` immediate caps at 504 bytes; a
        // larger frame adjusts sp separately.
        if (_maxOutStack == (u32)0) {
            if (_frame <= (u32)504) {
                _out.appendFormat("    stp x29, x30, [sp, #-%lu]!\n", _frame);
            } else {
                emitSpAdjust(_frame, true);
                _out.appendCString("    stp x29, x30, [sp]\n");
            }
            _out.appendCString("    mov x29, sp\n");
        } else {
            // The outgoing-argument area sits at [sp, #0 .. maxOutStack); the
            // frame record goes above it.
            emitSpAdjust(_frame, true);
            if (_maxOutStack <= (u32)504) {
                _out.appendFormat("    stp x29, x30, [sp, #%lu]\n", _maxOutStack);
            } else {
                _out.appendFormat("    add x9, sp, #%lu\n", _maxOutStack);
                _out.appendCString("    stp x29, x30, [x9]\n");
            }
            _out.appendFormat("    add x29, sp, #%lu\n", _maxOutStack);
        }
        // Stow the incoming x8 before any argument marshal or body code can
        // clobber it.
        if (_sretSaveOffset != (u32)0)
            _out.appendFormat("    str x8, %s\n",
                              spMemForOff(_sretSaveOffset, String.withCString("x8")).cString());
        emitCalleeSaves(false);
        spillParams(fn);
    }

    void emitSpAdjust(u32 mag, bool grow)
    {
        String* mnem = String.withCString(grow ? "sub" : "add");
        if (mag <= (u32)4095) {
            _out.appendFormat("    %s sp, sp, #%lu\n", mnem.cString(), mag);
        } else {
            // movz/movk, not `mov #imm`: the magnitude is built 16 bits at a
            // time in the x-form so a frame past 64 KB survives.
            _out.appendFormat("    movz x9, #%lu\n", mag & (u32)$FFFF);
            if ((mag >> (u32)16) != (u32)0)
                _out.appendFormat("    movk x9, #%lu, lsl #16\n", (mag >> (u32)16) & (u32)$FFFF);
            _out.appendFormat("    %s sp, sp, x9\n", mnem.cString());
        }
    }

    // Saved before the parameter spill: a parameter may be homed in one of
    // these registers, and overwriting it first would lose the caller's value.
    void emitCalleeSaves(bool restore)
    {
        String* pair = String.withCString(restore ? "ldp" : "stp");
        String* one  = String.withCString(restore ? "ldr" : "str");
        u32 n = _savedRegs.count();
        u32 i = (u32)0;
        while (i < n) {
            String* r0 = (String*)_savedRegs.get(i);
            u32 off = _saveAreaOffset + (u32)8 * i;
            bool r0fp = isFPReg(r0);
            // Two adjacent registers of the same bank pair into one stp/ldp,
            // which the pre-indexed form can only reach within 504 bytes.
            if (i + (u32)1 < n && off <= (u32)504) {
                String* r1 = (String*)_savedRegs.get(i + (u32)1);
                if (isFPReg(r1) == r0fp) {
                    _out.appendFormat("    %s %s, %s, [sp, #%lu]\n", pair.cString(),
                                      r0.cString(), r1.cString(), off);
                    i = i + (u32)2;
                    continue;
                }
            }
            // Past the pair range — and, in a big frame, possibly past the
            // single scaled range (the save area sits ABOVE the value slots).
            if (off <= (u32)32760) {
                _out.appendFormat("    %s %s, [sp, #%lu]\n", one.cString(), r0.cString(), off);
            } else {
                if ((off & (u32)$FFF) == (u32)0 && (off >> (u32)12) <= (u32)4095) {
                    _out.appendFormat("    add x9, sp, #%lu, lsl #12\n", off >> (u32)12);
                } else {
                    _out.appendFormat("    mov w9, #%lu\n", off & (u32)$FFFF);
                    if (off > (u32)$FFFF)
                        _out.appendFormat("    movk w9, #%lu, lsl #16\n", off >> (u32)16);
                    _out.appendCString("    add x9, sp, x9\n");
                }
                _out.appendFormat("    %s %s, [x9]\n", one.cString(), r0.cString());
            }
            i = i + (u32)1;
        }
    }

    static bool isFPReg(String* r)
    {
        return r.hasPrefix(String.withCString("d")) || r.hasPrefix(String.withCString("s"));
    }

    // AAPCS64: integer and pointer parameters arrive in x0..x7, floats in the
    // independent v0..v7 bank. The last parameter is the Mem phantom — it has a
    // slot but no register, so it is skipped.
    void spillParams(IRFunc* fn)
    {
        u32 n = fn.params().count();
        u32 user = n;
        if (n > (u32)0 && isMemTy(((IRValue*)fn.params().get(n - (u32)1)).ty()))
            user = n - (u32)1;
        Array* types = new Array();
        for (u32 i = (u32)0; i < user; i = i + (u32)1)
            types.add((Object*)((IRValue*)fn.params().get(i)).ty());
        // A parameter that arrived on the stack lives in the CALLER's outgoing
        // area, which sits just above this frame — hence the frameSize bias.
        Array* offs = offsetsForTypes(types, (u32)0);
        u32 gp = (u32)0;
        u32 fp = (u32)0;
        for (u32 i = (u32)0; i < user; i = i + (u32)1) {
            IRValue* p = (IRValue*)fn.params().get(i);
            String* t = p.ty();
            i32 so = ((Number*)offs.get(i)).asI32();
            if (isFloatTy(t)) {
                if (so >= (i32)0) {
                    String* sc = fregName((u32)16, t);
                    _out.appendFormat("    ldr %s, %s\n", sc.cString(),
                                      spMemForOff(_frame + (u32)so, sc).cString());
                    storeReg(sc, p);
                    continue;
                }
                if (fp >= (u32)8) continue;
                storeReg(fregName(fp, t), p);
                fp = fp + (u32)1;
                continue;
            }
            if (isAggTy(t)) {
                // Mirrors the caller's marshal exactly, so a struct or HFA
                // parameter round-trips intact.
                if (so >= (i32)0) {
                    // Overflowed the register bank: the whole aggregate
                    // arrived on the stack, in the caller's outgoing area just
                    // above this frame. Copy it into the param's own slot
                    // (bug 20/21).
                    u32 asz = aggSize(layoutOf(t));
                    emitSpAddr(_frame + (u32)so, String.withCString("x16"));
                    emitAggCopy(asz, slotOf(p), true);
                    continue;
                }
                IRLayout* l = layoutOf(t);
                bool dbl = false;
                u32 hfa = aggHFA(l, &dbl);
                if (hfa > (u32)0) {
                    if (fp + hfa > (u32)8) { unsupported(String.withCString("param:AggStack")); continue; }
                    for (u32 k = (u32)0; k < hfa; k = k + (u32)1) {
                        String* r = String.withCString(dbl ? "d" : "s");
                        r.appendFormat("%lu", fp + k);
                        storeSlotOffset(p, (dbl ? (u32)8 : (u32)4) * k, r);
                    }
                    fp = fp + hfa;
                } else {
                    u32 nregs = gpRegsForAgg(t);
                    if (gp + nregs > (u32)8) { unsupported(String.withCString("param:AggStack")); continue; }
                    for (u32 k = (u32)0; k < nregs; k = k + (u32)1) {
                        String* r = String.withCString("x");
                        r.appendFormat("%lu", gp + k);
                        storeSlotOffset(p, (u32)8 * k, r);
                    }
                    gp = gp + nregs;
                }
                continue;
            }
            bool x = needsXReg(t);
            if (so >= (i32)0) {
                String* sc = String.withCString(x ? "x9" : "w9");
                _out.appendFormat("    ldr %s, %s\n", sc.cString(),
                                  spMemForOff(_frame + (u32)so, sc).cString());
                if (!x) canonicalise(sc, t);
                storeReg(sc, p);
                continue;
            }
            if (gp >= (u32)8) continue;
            String* r = String.withCString(x ? "x" : "w");
            r.appendFormat("%lu", gp);
            // An incoming narrow integer is canonicalised to its own range here
            // rather than at every read.
            if (!x) canonicalise(r, t);
            storeReg(r, p);
            gp = gp + (u32)1;
        }
    }

    // A block: its label, then its instructions and terminator.
    void emitBlock(IRFunc* fn, IRBlock* bb)
    {
        _bb = bb;
        _out.appendFormat("L%s_%s:\n", fn.name().cString(), bb.name().cString());
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            emitInsn(fn, (IRInsn*)bb.insns().get(i));
        if (bb.term() != (IRInsn*)0) emitInsn(fn, bb.term());
    }

    IRBlock* _bb;               // the block currently being emitted
    u32      _labelCounter;     // .Lpc_N, for the split phi-copy paths
    u32      _valueSlotEnd;     // where the value slots stop and the saves begin
    u32      _sretSaveOffset;   // the stowed x8 indirect-result pointer, or 0

    void emitInsn(IRFunc* fn, IRInsn* n)
    {
        // A FieldAddr/ElementAddr folded into a Load/Store's addressing mode,
        // or a zero constant that stores as wzr, is never emitted on its own.
        if (n.res() != (IRValue*)0 && inMap(_foldedAddr, n.res())) return;
        // An ICmp fused into its block's CondBranch is emitted there instead.
        if (n.res() != (IRValue*)0 && inMap(_fusedCmps, n.res())) return;
        // A def subsumed by a fused consumer is never emitted; a fusion SITE
        // emits the combined form in place of its own opcode.
        if (n.res() != (IRValue*)0 && inMap(_fusedAway, n.res())) return;
        if (n.res() != (IRValue*)0 && _fuseKind.get((Hashable*)n.res()) != (Object*)0)
            { emitFused(n); return; }
        // The dispatch is split across four routines purely for the frame
        // budget: one chain of string comparisons builds too many temporaries
        // for a single 16 KB frame.
        String* op = n.op();
        if (dispatchCore(n, op)) return;
        if (dispatchMemory(n, op)) return;
        if (dispatchRuntime(n, op)) return;
        if (dispatchFloat(n, op)) return;
        if (dispatchVector(n, op)) return;
        unsupported(op);
    }

    // Control flow, integer arithmetic, comparisons, casts.
    bool dispatchCore(IRInsn* n, String* op)
    {
        if (op.equals(String.withCString("Const")))  { emitConst(n);  return true; }
        if (op.equals(String.withCString("Phi")))    { return true; }   // edge copies
        if (op.equals(String.withCString("Return"))) { emitReturn(n); return true; }
        if (op.equals(String.withCString("Branch")))     { emitBranch(n); return true; }
        if (op.equals(String.withCString("CondBranch"))) { emitCondBranch(n); return true; }
        if (op.equals(String.withCString("ICmp")))   { emitICmp(n);   return true; }
        if (op.equals(String.withCString("Select"))) { emitSelect(n); return true; }
        if (op.equals(String.withCString("Neg")))    { emitUnary(n, String.withCString("neg")); return true; }
        if (op.equals(String.withCString("Not")))    { emitUnary(n, String.withCString("mvn")); return true; }
        if (op.equals(String.withCString("Unreachable"))) { _out.appendCString("    brk #0\n"); return true; }
        if (op.equals(String.withCString("SExt")) || op.equals(String.withCString("ZExt"))
         || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast")))
            { emitCast(n); return true; }
        String* mn = intBinOpMnemonic(op);
        if (mn != (String*)0) { emitBinOp(n, mn); return true; }
        if (op.equals(String.withCString("SRem")) || op.equals(String.withCString("URem")))
            { emitRem(n); return true; }
        return false;
    }

    // Memory, address arithmetic, pointer casts, direct calls.
    bool dispatchMemory(IRInsn* n, String* op)
    {
        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile")))
            { emitLoad(n); return true; }
        if (op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")))
            { emitStore(n); return true; }
        if (op.equals(String.withCString("VaStart")))     { emitVaStart(n); return true; }
        if (op.equals(String.withCString("VaArg")))       { emitVaArg(n);   return true; }
        if (op.equals(String.withCString("Call"))
         || op.equals(String.withCString("CallBanked"))
         || op.equals(String.withCString("CallCloaked"))) { emitCall(n); return true; }
        if (op.equals(String.withCString("AddrOf")))      { emitAddrOf(n); return true; }
        if (op.equals(String.withCString("FieldAddr")))   { emitFieldAddr(n); return true; }
        if (op.equals(String.withCString("ElementAddr"))) { emitElementAddr(n); return true; }
        if (op.equals(String.withCString("IntToPtr")))    { emitIntToPtr(n); return true; }
        if (op.equals(String.withCString("PtrToInt")))    { emitPtrToInt(n); return true; }
        if (op.equals(String.withCString("AggBuild")))   { emitAggBuild(n); return true; }
        if (op.equals(String.withCString("AggExtract"))) { emitAggExtract(n); return true; }
        if (op.equals(String.withCString("MemCopy"))) { emitMemHelper(n, String.withCString("_memcpy"), true); return true; }
        if (op.equals(String.withCString("MemSet")))  { emitMemHelper(n, String.withCString("_memset"), false); return true; }
        return false;
    }

    // ARC, vtables, indirect calls, downcasts, inline asm, banking.
    bool dispatchRuntime(IRInsn* n, String* op)
    {
        if (op.equals(String.withCString("Retain")))  { emitRetain(n); return true; }
        if (op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")))
            { emitRelease(n); return true; }
        if (op.equals(String.withCString("WeakRegister")))
            { emitWeakCall(n, String.withCString("__xtc_weak_register"), (u32)2, false); return true; }
        if (op.equals(String.withCString("WeakUnregister")))
            { emitWeakCall(n, String.withCString("__xtc_weak_unregister"), (u32)1, false); return true; }
        if (op.equals(String.withCString("WeakLoad")))
            { emitWeakCall(n, String.withCString("__xtc_weak_load"), (u32)1, true); return true; }
        if (op.equals(String.withCString("VTblLoad")))     { emitVTblLoad(n); return true; }
        if (op.equals(String.withCString("VTblDispatch"))) { emitVTblDispatch(n); return true; }
        if (op.equals(String.withCString("CallIndirect")))  { emitCallIndirect(n); return true; }
        if (op.equals(String.withCString("ClassDowncast"))
         || op.equals(String.withCString("ClassDowncastFailable"))) { emitDowncast(n); return true; }
        if (op.equals(String.withCString("Asm")))     { emitAsm(n); return true; }
        // The IR carries banking intent so the 6502 target can act on it; a
        // single flat address space has nothing to do.
        if (op.equals(String.withCString("BankSelectFor"))
         || op.equals(String.withCString("BankSave"))
         || op.equals(String.withCString("BankRestore"))) { _out.appendCString("    nop\n"); return true; }
        return false;
    }

    bool dispatchFloat(IRInsn* n, String* op)
    {
        if (op.equals(String.withCString("FAdd"))) { emitFBin(n, String.withCString("fadd")); return true; }
        if (op.equals(String.withCString("FSub"))) { emitFBin(n, String.withCString("fsub")); return true; }
        if (op.equals(String.withCString("FMul"))) { emitFBin(n, String.withCString("fmul")); return true; }
        if (op.equals(String.withCString("FDiv"))) { emitFBin(n, String.withCString("fdiv")); return true; }
        if (op.equals(String.withCString("FNeg")))  { emitFUnary(n, String.withCString("fneg")); return true; }
        if (op.equals(String.withCString("FSqrt"))) { emitFUnary(n, String.withCString("fsqrt")); return true; }
        if (op.equals(String.withCString("FCmp")))  { emitFCmp(n); return true; }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            { emitIntToFp(n); return true; }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")))
            { emitFpToInt(n); return true; }
        if (op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")))
            { emitFpConvert(n); return true; }
        return false;
    }

    // The integer binaries that are one AArch64 instruction, or null when the
    // opcode is not one of them.
    static String* intBinOpMnemonic(String* op)
    {
        if (op.equals(String.withCString("Add")))  return String.withCString("add");
        if (op.equals(String.withCString("Sub")))  return String.withCString("sub");
        if (op.equals(String.withCString("Mul")))  return String.withCString("mul");
        if (op.equals(String.withCString("SDiv"))) return String.withCString("sdiv");
        if (op.equals(String.withCString("UDiv"))) return String.withCString("udiv");
        if (op.equals(String.withCString("And")))  return String.withCString("and");
        if (op.equals(String.withCString("Or")))   return String.withCString("orr");
        if (op.equals(String.withCString("Xor")))  return String.withCString("eor");
        if (op.equals(String.withCString("Shl")))  return String.withCString("lsl");
        if (op.equals(String.withCString("LShr"))) return String.withCString("lsr");
        if (op.equals(String.withCString("AShr"))) return String.withCString("asr");
        return (String*)0;
    }

    void emitBinOp(IRInsn* n, String* mnem)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        if (emitMagicDivide(n)) return;
        // A small constant addend folds into the imm12 form rather than being
        // materialised into a register first.
        String* op = n.op();
        bool addsub = op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"));
        i32 k = (i32)0;
        if (addsub && imm12Operand((IROperand*)n.ops().get((u32)1), &k)) {
            String* ar = operandReg((IROperand*)n.ops().get((u32)0), scratchName((u32)16, n.res().ty()));
            String* dr = resultReg(n.res(), scratchName((u32)16, n.res().ty()));
            _out.appendFormat("    %s %s, %s, #%ld\n", mnem.cString(), dr.cString(),
                              ar.cString(), k);
            canonicaliseUnlessProven(dr, n.res());
            storeReg(dr, n.res());
            return;
        }
        // The scratches are named at the RESULT's width. Hard-coded w16/w17,
        // a 64-bit operand living in a slot was loaded with `ldr w16` and then
        // used as `mul x21, w16, x10` — an invalid mixed-width form, and four
        // bytes of an eight-byte value. Only slot-resident operands hit this;
        // a homed one is already named through homeView, which is why the
        // arithmetic fixtures passed while this was wrong.
        String* a = operandReg((IROperand*)n.ops().get((u32)0), scratchName((u32)16, n.res().ty()));
        String* b = operandReg((IROperand*)n.ops().get((u32)1), scratchName((u32)17, n.res().ty()));
        String* d = resultReg(n.res(), scratchName((u32)16, n.res().ty()));
        // A SHIFT names its count in the DESTINATION's width: `lsr x0, x1, x2`,
        // never `lsr x0, x1, w2`. The count's own type is narrow (u8), so a
        // homed count arrives as `w19` and the pair assembles only because our
        // own assembler used to be lax about it — clang rejects it outright.
        // Move it into the X scratch, which also zeroes the top half, exactly
        // what a 0..63 count wants.
        bool isShift = op.equals(String.withCString("Shl"))
                    || op.equals(String.withCString("LShr"))
                    || op.equals(String.withCString("AShr"));
        if (isShift && d.hasPrefix(String.withCString("x"))
                    && b.hasPrefix(String.withCString("w"))) {
            _out.appendFormat("    mov w17, %s\n", b.cString());
            b = String.withCString("x17");
        }
        // A LOGICAL right shift of a narrow SIGNED value must shift the value,
        // not the register. A narrow value is kept sign-extended in its w
        // register (canonicalise), so `lsr` on i16 -28820 shifted 0xFFFF8F6C
        // and pulled the extension bits down. Zero-extend to the type's width
        // first. `>>` on a signed type is an AShr, so the only producer of this
        // shape is the rotate expansion in the lowering — which is why every
        // i16/i8 rotate disagreed with the other back ends while u16/u32 were
        // right.
        if (op.equals(String.withCString("LShr")) && isSignedTy(n.res().ty())
            && width(n.res().ty()) < (u32)4
            && a.hasPrefix(String.withCString("w"))) {
            _out.appendFormat("    %s w16, %s\n",
                              width(n.res().ty()) == (u32)1 ? "uxtb" : "uxth",
                              a.cString());
            a = String.withCString("w16");
        }
        _out.appendFormat("    %s %s, %s, %s\n", mnem.cString(), d.cString(),
                          a.cString(), b.cString());
        canonicaliseUnlessProven(d, n.res());
        storeReg(d, n.res());
    }

    // Skip the uxtb/uxth when the no-wrap analysis proved the result cannot
    // overflow its width: masked and unmasked are the same value, and the mask
    // is off the loop-carried critical path.
    void canonicaliseUnlessProven(String* reg, IRValue* res)
    {
        if (_noCanon.get((Hashable*)res) != (Object*)0) return;
        canonicalise(reg, res.ty());
    }

    // ── Division by a constant → a reciprocal multiply ───────────────────
    //
    // udiv/sdiv are slow, and a divisor known at compile time can be replaced
    // by a multiply-high and a couple of shifts (Granlund-Montgomery). True
    // for every input by construction, not approximately.
    bool emitMagicDivide(IRInsn* n)
    {
        String* op = n.op();
        bool uns = op.equals(String.withCString("UDiv")) || op.equals(String.withCString("URem"));
        bool sgn = op.equals(String.withCString("SDiv")) || op.equals(String.withCString("SRem"));
        if (!uns && !sgn) return false;
        i32 dC = constDivisor(n);
        if (dC == (i32)0) return false;
        u32 W = width(n.res().ty()) * (u32)8;
        if (uns) {
            u32 d = (u32)dC;
            if (d < (u32)2 || (d & (d - (u32)1)) == (u32)0) return false;   // a power of two is a shift
            if (W != (u32)8 && W != (u32)16 && W != (u32)32) return false;
            emitMagicUnsigned(n, d, W);
            return true;
        }
        u32 ad = (u32)(dC < (i32)0 ? -dC : dC);
        if (W != (u32)32 || ad < (u32)2 || (ad & (ad - (u32)1)) == (u32)0) return false;
        emitMagicSigned(n, dC);
        return true;
    }

    void emitMagicUnsigned(IRInsn* n, u32 d, u32 W)
    {
        u32 M = (u32)0;
        u32 addIndicator = (u32)0;
        u32 sh = (u32)0;
        magicU(d, W, &M, &addIndicator, &sh);
        bool isDiv = n.op().equals(String.withCString("UDiv"));
        String* x = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        String* dst = resultReg(n.res(), String.withCString("w16"));
        emitImm32(M, String.withCString("w17"));
        // t = mulhu(x, M) = (x*M) >> W, in w15.
        _out.appendFormat("    umull x15, %s, w17\n", x.cString());
        _out.appendFormat("    lsr x15, x15, #%lu\n", W);
        String* q = isDiv ? dst : String.withCString("w15");
        if (addIndicator == (u32)0) {
            _out.appendFormat("    lsr %s, w15, #%lu\n", q.cString(), sh);
        } else {
            // The magic overflowed W bits, so the quotient is
            // t + ((x - t) >> 1), then shifted by s-1.
            _out.appendFormat("    sub w17, %s, w15\n", x.cString());
            _out.appendCString("    lsr w17, w17, #1\n");
            _out.appendCString("    add w15, w15, w17\n");
            _out.appendFormat("    lsr %s, w15, #%lu\n", q.cString(), sh - (u32)1);
        }
        if (!isDiv) {                       // r = x - q*d
            emitImm32(d, String.withCString("w17"));
            _out.appendFormat("    msub %s, %s, w17, %s\n", dst.cString(), q.cString(), x.cString());
        }
        canonicaliseUnlessProven(dst, n.res());
        storeReg(dst, n.res());
    }

    void emitMagicSigned(IRInsn* n, i32 d)
    {
        i32 M = (i32)0;
        u32 sh = (u32)0;
        magicS(d, &M, &sh);
        bool isDiv = n.op().equals(String.withCString("SDiv"));
        String* x = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        String* dst = resultReg(n.res(), String.withCString("w16"));
        emitImm32((u32)M, String.withCString("w17"));
        // q = mulhs(x, M) = (x*M) >>s 32, in w15.
        _out.appendFormat("    smull x15, %s, w17\n", x.cString());
        _out.appendCString("    asr x15, x15, #32\n");
        // The magic's sign disagreeing with the divisor's means the high part
        // came out one x short (or long) — correct it before the shift.
        if (d > (i32)0 && M < (i32)0) _out.appendFormat("    add w15, w15, %s\n", x.cString());
        if (d < (i32)0 && M > (i32)0) _out.appendFormat("    sub w15, w15, %s\n", x.cString());
        _out.appendFormat("    asr w15, w15, #%lu\n", sh);
        String* q = isDiv ? dst : String.withCString("w15");
        _out.appendFormat("    add %s, w15, w15, lsr #31\n", q.cString());   // + the sign bit
        if (!isDiv) {
            emitImm32((u32)d, String.withCString("w17"));
            _out.appendFormat("    msub %s, %s, w17, %s\n", dst.cString(), q.cString(), x.cString());
        }
        canonicaliseUnlessProven(dst, n.res());
        storeReg(dst, n.res());
    }

    // The unsigned magic number, add-indicator and shift for `d` at width W.
    //
    // The reference works in 2W-bit arithmetic; there is no 64-bit integer
    // here, so the two places it would be needed are handled directly. 2^W mod
    // d becomes ((2^W - 1) mod d + 1) mod d, and q1's doubling is tracked with
    // an overflow flag: the loop's only use of q1 is `q1 < delta` with
    // delta < 2^W, so a q1 that has overflowed is unconditionally not less and
    // the loop simply ends. q2 is meant to wrap — the result is masked to W
    // bits — so its natural u32 wraparound at W = 32 is exactly right.
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
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            if (r1 >= nc - r1) { q1 = q1 + q1 + (u32)1; r1 = r1 - (nc - r1); }
            else               { q1 = q1 + q1;          r1 = r1 + r1; }
            if (r2 + (u32)1 >= d - r2) {
                if (q2 >= twoWm1 - (u32)1) a = (u32)1;
                q2 = q2 + q2 + (u32)1;
                r2 = r2 - (d - r2 - (u32)1);
            } else {
                if (q2 >= twoWm1) a = (u32)1;
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

    // The signed magic number and shift, at W = 32 — the only width the signed
    // path takes. Same overflow treatment for q1 as the unsigned case.
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
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            q1 = q1 + q1; r1 = r1 + r1;
            if (r1 >= anc) { q1 = q1 + (u32)1; r1 = r1 - anc; }
            q2 = q2 + q2; r2 = r2 + r2;
            if (r2 >= ad) { q2 = q2 + (u32)1; r2 = r2 - ad; }
            delta = ad - r2;
            again = !q1over && (q1 < delta || (q1 == delta && r1 == (u32)0));
        }
        // The mask is the full u32 at this width, so the value is already the
        // sign-extended magic; negate it for a negative divisor.
        i32 M = (i32)(q2 + (u32)1);
        if (dIn < (i32)0) M = -M;
        *Mout = M;
        *sout = p - (u32)32;
    }

    // rem = a - (a / b) * b. Register 15 is the quotient scratch — never a
    // home — and it is named at the RESULT's width: a 64-bit remainder needs
    // `sdiv x15`, and `sdiv w15, x10, x11` is a mixed-width form clang rejects.
    void emitRem(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        if (emitMagicDivide(n)) return;
        String* a = operandReg((IROperand*)n.ops().get((u32)0), scratchName((u32)16, n.res().ty()));
        String* b = operandReg((IROperand*)n.ops().get((u32)1), scratchName((u32)17, n.res().ty()));
        String* d = resultReg(n.res(), scratchName((u32)16, n.res().ty()));
        String* dv = String.withCString(
            n.op().equals(String.withCString("SRem")) ? "sdiv" : "udiv");
        String* q = scratchName((u32)15, n.res().ty());
        _out.appendFormat("    %s %s, %s, %s\n", dv.cString(), q.cString(),
                          a.cString(), b.cString());
        _out.appendFormat("    msub %s, %s, %s, %s\n", d.cString(), q.cString(),
                          b.cString(), a.cString());
        canonicalise(d, n.res().ty());
        storeReg(d, n.res());
    }

    // The divisor as a compile-time constant, looking through the ZExt/SExt/
    // Trunc of a Const that the lowering emits for a widened literal. Zero when
    // there isn't one (a zero divisor would trap anyway, so it is safe as the
    // "no constant" answer).
    i32 constDivisor(IRInsn* n)
    {
        IROperand* dv = (IROperand*)n.ops().get((u32)1);
        if (dv.kind() == (u8)OPK_IMMI) return dv.imm();
        if (dv.kind() != (u8)OPK_USE) return (i32)0;
        IRValue* cur = dv.val();
        for (u32 g = (u32)0; g < (u32)8; g = g + (u32)1) {
            Object* o = _defOf.get((Hashable*)cur);
            if (o == (Object*)0) return (i32)0;
            IRInsn* dd = (IRInsn*)o;
            if (dd.ops().count() < (u32)1) return (i32)0;
            IROperand* a0 = (IROperand*)dd.ops().get((u32)0);
            if (dd.op().equals(String.withCString("Const")))
                return a0.kind() == (u8)OPK_IMMI ? a0.imm() : (i32)0;
            if ((dd.op().equals(String.withCString("ZExt"))
              || dd.op().equals(String.withCString("SExt"))
              || dd.op().equals(String.withCString("Trunc")))
             && a0.kind() == (u8)OPK_USE) { cur = a0.val(); continue; }
            return (i32)0;
        }
        return (i32)0;
    }

    void emitUnary(IRInsn* n, String* mnem)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        // The scratch is sized to the RESULT: an i64 negate whose result is
        // unhomed used to take `w16` as its destination while its operand
        // arrived in an x register, and `neg w16, x10` is not a legal pair.
        String* sc = scratchName((u32)16, n.res().ty());
        String* a = operandReg((IROperand*)n.ops().get((u32)0), sc);
        String* d = resultReg(n.res(), sc);
        _out.appendFormat("    %s %s, %s\n", mnem.cString(), d.cString(), a.cString());
        canonicalise(d, n.res().ty());
        storeReg(d, n.res());
    }

    // SExt / ZExt / Trunc / Bitcast. A pointer result must move all 64 bits —
    // a w16 round trip truncates the address — so it rides x16. An integer
    // result fuses the move with its canonicalising extend into one
    // instruction: `uxth Wd, Wsrc`, not `mov` plus `uxth`.
    void emitCast(IRInsn* n)
    {
        // A cast with NO RESULT computes nothing anyone reads. The lowering
        // emits these — a dead cast whose result was dropped but whose
        // instruction stayed — and the reference back end silently emits
        // nothing for them, so this is a faithful no-op, not a skipped
        // instruction. (Same family as the dangling-%?N shapes the optimiser
        // port turned up: malformed IR the back ends happen to tolerate.)
        if (n.res() == (IRValue*)0) return;
        if (n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        String* ty = n.res().ty();
        if (isFloatTy(ty) || isAggTy(ty) || isVecTy(ty)) { unsupported(n.op()); return; }
        // …and the same for an i64/u64 result. Scratching a 64-bit widening
        // through `w16` emitted `mov w16, w<src>`, which neither sign-extends
        // nor carries a high half — so the value was SPILLED as four bytes and
        // reloaded as eight, taking whatever sat in the next slot as its top
        // word. `(i64)-5` read back as 4294967291.
        bool ptr = isPtrTy(ty);
        bool wide = ptr || needsXReg(ty);
        String* reg = String.withCString(wide ? "x16" : "w16");
        // The SOURCE is loaded at the SOURCE's width, not the result's. Sharing
        // one scratch name meant a widening read its operand with `ldr x16` out
        // of a FOUR-byte slot and took the neighbouring word as the high half —
        // a `u32` 2 arrived as 4294967298.
        IROperand* so = (IROperand*)n.ops().get((u32)0);
        String* st = so.kind() == (u8)OPK_USE && so.val() != (IRValue*)0
                   ? so.val().ty() : so.ty();
        String* sreg = String.withCString((needsXReg(st) || width(st) >= (u32)8)
                                          ? "x16" : "w16");
        String* src = operandReg(so, sreg);
        String* d = resultReg(n.res(), reg);
        String* ext = ptr ? (String*)0 : extendMnemonic(ty);
        // Widening a SIGNED 32-bit value into 64 bits is `sxtw Xd, Wn`. The
        // table above answers null for I32/U32 because at 32 bits no extend is
        // needed, so without this the sign was simply dropped.
        if (ext == (String*)0 && n.op().equals(String.withCString("SExt")) && needsXReg(ty)) {
            if (st != (String*)0 && !needsXReg(st) && isSignedTy(st))
                ext = String.withCString("sxtw");
        }
        // ZERO-extending into 64 bits is a 32-bit `mov`: writing a W register
        // clears the top half of its X, and that IS the zero extension. A
        // 64-bit `mov x,x` copies the source's stale high bits instead.
        //
        // A W destination is the right INSTRUCTION and the wrong name to spill
        // from — storeReg sizes the spill from the register name, so `str w16`
        // would write four bytes into an eight-byte slot. Keep the X name for
        // the store.
        String* dStore = d;
        bool zx = (ext == (String*)0) && wide && !ptr
               && !n.op().equals(String.withCString("SExt"))
               && st != (String*)0 && width(st) <= (u32)4 && !isFloatTy(st);
        if (zx) {
            if (d.hasPrefix(String.withCString("x"))) d = wForm(d);
            if (src.hasPrefix(String.withCString("x"))) src = wForm(src);
        }
        // uxtb/uxth take only a W destination (and zeroing it clears the whole
        // X); sxtb/sxth/sxtw take either, and a 64-bit result wants X.
        if (ext != (String*)0 && wide && ext.hasPrefix(String.withCString("u"))
            && d.hasPrefix(String.withCString("x"))) d = wForm(d);
        if (ext != (String*)0) {
            // sxtb/uxth and friends read a 32-bit Wn source; a source homed in
            // an x-register (a pointer being truncated) uses its w-view.
            if (src.hasPrefix(String.withCString("x"))) src = wForm(src);
            _out.appendFormat("    %s %s, %s\n", ext.cString(), d.cString(), src.cString());
        } else {
            emitMove(d, src);
        }
        storeReg(dStore, n.res());
    }

    // The single extend instruction that canonicalises to `ty`, or null for
    // I32/U32 where a plain move suffices.
    static String* extendMnemonic(String* ty)
    {
        if (ty == (String*)0) return (String*)0;
        if (ty.equals(String.withCString("I8")))  return String.withCString("sxtb");
        if (ty.equals(String.withCString("U8")) || ty.equals(String.withCString("Bool")))
            return String.withCString("uxtb");
        if (ty.equals(String.withCString("I16"))) return String.withCString("sxth");
        if (ty.equals(String.withCString("U16"))) return String.withCString("uxth");
        return (String*)0;
    }

    // ── ARC, vtables, indirect calls ─────────────────────────────────────
    //
    // A `.L` label is FILE-scoped in Mach-O, so a bare counter would collide
    // across functions — every internal label carries the function name, with
    // `$` mapped to `_` because the assembler will not take it.
    String* localLabel(String* kind)
    {
        String* o = labelFor(kind, _labelCounter);
        _labelCounter = _labelCounter + (u32)1;
        return o;
    }

    // The same label WITHOUT taking a fresh number. A retain/release emits two
    // labels — its done label and, without LSE, the retry label of the
    // exclusive loop — and the original spends ONE counter value on both. A
    // second number here is byte-identical nowhere.
    String* labelFor(String* kind, u32 n)
    {
        String* o = String.withCString(".L");
        o.append(sanitised(_fn.name()));
        o.appendCString("_");
        o.append(kind);
        o.appendCString("_");
        o.appendFormat("%lu", n);
        return o;
    }

    static String* sanitised(String* n)
    {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < n.byteLength(); i = i + (u32)1) {
            u8 c = n.byteAt(i);
            o.appendByte(c == (u8)'$' ? (u8)'_' : c);
        }
        return o;
    }

    // Does anything in this module call the runtime's thread-create primitive?
    // The INSTRUCTION stream is the question, not the symbol table: a symbol
    // survives dead-function elimination whether or not anything still names
    // it, and a program that imports a threading library it never spawns from
    // should keep the cheaper refcount.
    // Does the module call `name` anywhere? Same walk spawnsThreads does, and
    // for the same reason: a per-module fact the back end must decide for
    // itself rather than be told.
    bool referencesSymbol(IRModule* m, String* want)
    {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (insnsName(bb.phis(), want)) return true;
                if (insnsName(bb.insns(), want)) return true;
                if (bb.term() != (IRInsn*)0 && insnNames(bb.term(), want)) return true;
            }
        }
        return false;
    }

    // One function's entry in the checked-build map: where each parameter can
    // be read from, and which callee-saved registers this frame holds, so the
    // reporter can recover the arguments of frames further out.
    //
    // A parameter the allocator homed in a REGISTER has no frame slot, and is
    // recorded as such — the walk finds it in the callee-save area of an inner
    // frame, or reports it unavailable. A confident wrong argument is worse
    // than an absent one.
    void collectMsFn(IRFunc* fn)
    {
        if (_msFns == (Array*)0) return;
        MsFn* e = new MsFn();
        e.setName(fn.name());
        u32 n = fn.params().count();
        u32 user = n;
        if (n > (u32)0 && isMemTy(((IRValue*)fn.params().get(n - (u32)1)).ty()))
            user = n - (u32)1;
        for (u32 i = (u32)0; i < user; i = i + (u32)1) {
            IRValue* p = (IRValue*)fn.params().get(i);
            String* t = p.ty();
            Object* h = _home.get((Hashable*)p);
            u32 kind = (u32)1;                       // 1 int, 2 ptr, 3 float
            if (isPtrTy(t))          kind = (u32)2;
            else if (isFloatTy(t))   kind = (u32)3;
            u32 width = fieldWidth(t);
            i64 off = (i64)-1;                       // -1 = "in a register"
            i64 reg = (i64)-1;
            if (h == (Object*)0) off = (i64)slotOf(p);
            else                 reg = (i64)regNumberOf((String*)h);
            e.addParam(off, (i64)((kind << (u32)8) | (width & (u32)0xFF)), reg);
        }
        for (u32 i = (u32)0; i < _savedRegs.count(); i = i + (u32)1)
            e.addSaved((i64)regNumberOf((String*)_savedRegs.get(i)));
        e.setSaveBase((i64)_saveAreaOffset);
        _msFns.add((Object*)e);
    }

    // `x19` -> 19, `d8` -> 72 (the float bank offset by 64), anything else -1.
    i64 regNumberOf(String* r)
    {
        if (r == 0 || r.byteLength() < (u32)2) return (i64)-1;
        u8 c = r.byteAt((u32)0);
        if (c != (u8)'x' && c != (u8)'w' && c != (u8)'d') return (i64)-1;
        u32 v = (u32)0;
        for (u32 i = (u32)1; i < r.byteLength(); i = i + (u32)1) {
            u8 d = r.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return (i64)-1;
            v = v * (u32)10 + (u32)(d - (u8)'0');
        }
        return (i64)v + (c == (u8)'d' ? (i64)64 : (i64)0);
    }

    // The map itself. ALWAYS DEFINED when this is a checked build, never weak:
    // the runtime used to declare it weak and test for null, but the address of
    // an array is never null, so the compiler folded the guard away and the
    // reporter dereferenced an unresolved symbol. The table and the checked
    // runtime link together or not at all.
    void emitMsMap(void)
    {
        if (_msFns == (Array*)0) return;
        _out.appendCString("\n// Checked-build parameter map (private:docs/Design/memory-safety.md)\n");
        _out.appendCString("    .section __DATA,__data\n    .p2align 3\n");
        for (u32 i = (u32)0; i < _msFns.count(); i = i + (u32)1) {
            MsFn* e = (MsFn*)_msFns.get(i);
            _out.appendFormat("___xt_ms_p_%ld:\n", (i32)i);
            for (u32 k = (u32)0; k < e.params().count(); k = k + (u32)3) {
                _out.appendFormat("    .quad %ld\n", (i32)((Number*)e.params().get(k)).asI32());
                _out.appendFormat("    .quad %ld\n", (i32)((Number*)e.params().get(k + (u32)1)).asI32());
                _out.appendFormat("    .quad %ld\n", (i32)((Number*)e.params().get(k + (u32)2)).asI32());
            }
            _out.appendFormat("___xt_ms_s_%ld:\n", (i32)i);
            for (u32 k = (u32)0; k < e.saved().count(); k = k + (u32)1)
                _out.appendFormat("    .quad %ld\n", (i32)((Number*)e.saved().get(k)).asI32());
            _out.appendCString("    .quad -1\n");     // end of the saved list
        }
        _out.appendCString("    .globl ___xt_ms_fns\n___xt_ms_fns:\n");
        _out.appendFormat("    .quad %ld\n", (i32)_msFns.count());
        for (u32 i = (u32)0; i < _msFns.count(); i = i + (u32)1) {
            MsFn* e = (MsFn*)_msFns.get(i);
            _out.appendFormat("    .quad _%s\n", e.name().cString());
            _out.appendFormat("    .quad %ld\n", (i32)(e.params().count() / (u32)3));
            _out.appendFormat("    .quad ___xt_ms_p_%ld\n", (i32)i);
            _out.appendFormat("    .quad %ld\n", (i32)e.saveBase());
            _out.appendFormat("    .quad ___xt_ms_s_%ld\n", (i32)i);
        }
    }

    bool spawnsThreads(IRModule* m)
    {
        String* want = String.withCString("_xt_thread_create");
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (insnsName(bb.phis(), want)) return true;
                if (insnsName(bb.insns(), want)) return true;
                if (bb.term() != (IRInsn*)0 && insnNames(bb.term(), want)) return true;
            }
        }
        return false;
    }

    bool insnsName(Array* list, String* want)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if (insnNames((IRInsn*)list.get(i), want)) return true;
        return false;
    }

    bool insnNames(IRInsn* n, String* want)
    {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_SYM) continue;
            if (o.name() != (String*)0 && o.name().equals(want)) return true;
        }
        return false;
    }

    void emitRetain(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        u32 lbl = _labelCounter;          // shared with the rcas retry label
        String* done = localLabel(String.withCString("retain_done"));
        _out.appendFormat("    cbz x16, %s\n", done.cString());
        // Skip small pointer values (< 64 KB): the Map/Set (pointer)0 and
        // (pointer)1 sentinels and any non-heap address are not refcounted
        // objects, and touching [ptr-2] would corrupt unrelated memory. A real
        // heap object sits far above 64 KB on this host.
        _out.appendCString("    cmp x16, #0x10000\n");
        _out.appendFormat("    b.lo %s\n", done.cString());
        // A refcount of ZERO means the object is being DESTROYED: the release
        // that took it to 0 is running dealloc right now. Retaining it here would
        // let the matching release take it back to 0 and dispatch dealloc AGAIN,
        // forever — which is what any strong binding of `self` inside a dealloc
        // used to cause (bug 038). A live object always holds at least one
        // reference, so 0 can only mean "already dying"; release has always had
        // the mirror-image guard, and this makes the pair symmetric.
        _out.appendCString("    ldur w17, [x16, #-4]\n");
        _out.appendFormat("    cbz w17, %s\n", done.cString());
        // A 32-bit refcount four bytes before the object. A 16-bit one
        // WRAPPED at 65,536 and freed live objects (bugs 025, 079); an 8-bit count
        // saturated at 255, so an object retained more than 255 times could
        // never be freed; strh wraps at 0x10000, which is unreachable in
        // practice, so no saturation guard is needed.
        if (_atomicArc) {
            // LDADDLH does the whole read-modify-write indivisibly. The
            // increment needs no ordering of its own (a retain publishes
            // nothing), but the release bit pairs with the acquire on the
            // release side. The old value is discarded into wzr.
            _out.appendCString("    sub x16, x16, #4\n");
            if (_lseAtomics) {
                _out.appendCString("    mov w17, #1\n");
                _out.appendCString("    ldaddl w17, wzr, [x16]\n");
            } else {
                // No LSE (Android's armv8-a baseline): the same atomic
                // increment as an exclusive load/store loop. x15/x16/x17 are
                // all reserved scratch, so it needs no spill.
                String* again = labelFor(String.withCString("rcas"), lbl);
                _out.appendFormat("%s:\n", again.cString());
                _out.appendCString("    ldaxr w17, [x16]\n");
                _out.appendCString("    add w17, w17, #1\n");
                _out.appendCString("    stlxr w15, w17, [x16]\n");
                _out.appendFormat("    cbnz w15, %s\n", again.cString());
            }
        } else {
            _out.appendCString("    add w17, w17, #1\n");
            _out.appendCString("    stur w17, [x16, #-4]\n");
        }
        _out.appendFormat("%s:\n", done.cString());
    }

    // Autorelease degrades to an immediate release; the distinct opcode is what
    // lets a real pool land later without retouching every emit site.
    void emitRelease(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x0"));
        u32 lbl = _labelCounter;          // shared with the rcas retry label
        String* done = localLabel(String.withCString("release_done"));
        _out.appendFormat("    cbz x0, %s\n", done.cString());
        _out.appendCString("    cmp x0, #0x10000\n");
        _out.appendFormat("    b.lo %s\n", done.cString());
        if (_atomicArc) {
            // Atomic decrement, and the dealloc decision comes from the value
            // THIS thread took the count down from — LDADDALH returns the OLD
            // halfword, so "I was the last reference" is old == 1. Two threads
            // re-reading a zero would both free it. The acquire half orders
            // every other thread's writes ahead of the destructor's reads.
            _out.appendCString("    sub x16, x0, #4\n");
            if (_lseAtomics) {
                _out.appendCString("    mov w17, #0xffff\n");
                _out.appendCString("    ldaddalh w17, w17, [x16]\n");
                _out.appendCString("    cmp w17, #1\n");
                _out.appendFormat("    b.ne %s\n", done.cString());
            } else {
                // No LSE: an exclusive load/store loop. It keeps the NEW count
                // and tests it against zero rather than holding the old one —
                // "I was the last reference" is old == 1, which is new == 0,
                // and that needs one register fewer. The wrap on an already
                // zero count is the same 0xffff the non-atomic path produces,
                // so the two agree exactly.
                String* again = labelFor(String.withCString("rcas"), lbl);
                _out.appendFormat("%s:\n", again.cString());
                _out.appendCString("    ldaxr w17, [x16]\n");
                _out.appendCString("    sub w17, w17, #1\n");
                _out.appendCString("    stlxr w15, w17, [x16]\n");
                _out.appendFormat("    cbnz w15, %s\n", again.cString());
                _out.appendFormat("    cbnz w17, %s\n", done.cString());
            }
        } else {
            _out.appendCString("    ldur w17, [x0, #-4]\n");
            _out.appendCString("    subs w17, w17, #1\n");
            _out.appendCString("    stur w17, [x0, #-4]\n");
            _out.appendFormat("    b.ne %s\n", done.cString());
        }
        // The C function _xtc_dealloc lands as the Mach-O symbol __xtc_dealloc.
        _out.appendCString("    bl __xtc_dealloc\n");
        _out.appendFormat("%s:\n", done.cString());
    }

    void emitWeakCall(IRInsn* n, String* sym, u32 nargs, bool hasResult)
    {
        if (n.ops().count() < nargs + (u32)1) { unsupported(n.op()); return; }
        for (u32 i = (u32)0; i < nargs; i = i + (u32)1) {
            String* r = String.withCString("x");
            r.appendFormat("%lu", i);
            materialise((IROperand*)n.ops().get(i), r);
        }
        _out.appendFormat("    bl %s\n", sym.cString());
        if (hasResult && n.res() != (IRValue*)0)
            storeReg(String.withCString("x0"), n.res());
    }

    // The code word of `&obj.method`: the same address computation as a vtable
    // dispatch, without the call. A null receiver must yield 0 rather than
    // fault, so `&nullDelegate.m` is falsy — one test covers both "no delegate"
    // and "delegate does not implement it", since an empty slot already reads
    // back as 0.
    void emitVTblLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* slot = (IROperand*)n.ops().get((u32)1);
        if (slot.kind() != (u8)OPK_IMMI) { unsupported(String.withCString("VTblLoad:slot")); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        String* done = localLabel(String.withCString("vtblload_done"));
        _out.appendCString("    mov x17, #0\n");        // stays 0 for a null receiver
        _out.appendFormat("    cbz x16, %s\n", done.cString());
        _out.appendCString("    ldr x17, [x16]\n");
        _out.appendFormat("    ldr x17, [x17, #%ld]\n", slot.imm() * (i32)8);
        _out.appendFormat("%s:\n", done.cString());
        storeReg(String.withCString("x17"), n.res());
    }

    void emitVTblDispatch(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        IROperand* slot = (IROperand*)n.ops().get((u32)1);
        if (slot.kind() != (u8)OPK_IMMI) { unsupported(String.withCString("VTblDispatch:slot")); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x0"));
        u32 argc = n.ops().count() >= (u32)3 ? n.ops().count() - (u32)3 : (u32)0;
        // The receiver consumed x0, so the GP counter starts at 1; the FP bank
        // is independent and starts at 0.
        if (!marshalArgs(n, (u32)2, argc, (u32)1)) return;
        bool sret = emitSretSetupIfNeeded(n);
        _out.appendCString("    ldr x16, [x0]\n");
        _out.appendFormat("    ldr x16, [x16, #%ld]\n", slot.imm() * (i32)8);
        _out.appendCString("    blr x16\n");
        captureResult(n, sret);
    }

    void emitCallIndirect(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        // The function pointer sits in x16, which no argument register touches.
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        if (!marshalArgs(n, (u32)1, n.ops().count() - (u32)2, (u32)0)) return;
        bool sret = emitSretSetupIfNeeded(n);
        _out.appendCString("    blr x16\n");
        captureResult(n, sret);
    }

    // The shared AAPCS64 argument marshal. Every call-shaped opcode goes
    // through this AND through outStackBytesFor, so the frame is sized by the
    // same rules the arguments are written by.
    bool marshalArgs(IRInsn* n, u32 first, u32 argc, u32 startGP)
    {
        Array* offs = argStackOffsets(n, first, argc, startGP);
        if (offs == (Array*)0) return false;
        u32 gp = startGP;
        u32 fp = (u32)0;
        for (u32 i = (u32)0; i < argc; i = i + (u32)1) {
            IROperand* a = (IROperand*)n.ops().get(first + i);
            String* aty = argType(a);
            if (isAggTy(aty)) {
                // A by-value aggregate: an HFA in consecutive v-registers, any
                // other in consecutive GP registers. A `^` bound method is a
                // pointer pair, never an HFA, so it stays GP. When it overflows
                // its register bank it is copied ENTIRELY onto the outgoing
                // stack area at its classified offset (bug 20/21).
                i32 aso = ((Number*)offs.get(i)).asI32();
                if (aso >= (i32)0) {
                    u32 asz = aggSize(layoutOf(aty));
                    emitSpAddr((u32)aso, String.withCString("x16"));
                    emitAggCopy(asz, slotOf(a.val()), false);
                    continue;
                }
                if (!marshalAggArg(a.val(), aty, &gp, &fp)) continue;
                continue;
            }
            i32 so = ((Number*)offs.get(i)).asI32();
            if (isFloatTy(aty)) {
                if (so < (i32)0) { loadValue(a.val(), fregName(fp, aty)); fp = fp + (u32)1; }
                else {
                    String* sc = fregName((u32)16, aty);
                    loadValue(a.val(), sc);
                    _out.appendFormat("    str %s, [sp, #%ld]\n", sc.cString(), so);
                }
                continue;
            }
            if (so < (i32)0) {
                String* r = String.withCString(needsXReg(aty) ? "x" : "w");
                r.appendFormat("%lu", gp);
                materialise(a, r);
                gp = gp + (u32)1;
            } else {
                String* sc = String.withCString(needsXReg(aty) ? "x9" : "w9");
                materialise(a, sc);
                _out.appendFormat("    str %s, [sp, #%ld]\n", sc.cString(), so);
            }
        }
        return true;
    }

    // The result of a call: FP in s0/d0, integers and pointers in w0/x0.
    void captureResult(IRInsn* n, bool sret)
    {
        if (n.res() == (IRValue*)0) return;
        String* rt = n.res().ty();
        if (isAggTy(rt)) { captureAggResult(n, sret); return; }
        if (isFloatTy(rt)) { storeReg(fregName((u32)0, rt), n.res()); return; }
        String* d = String.withCString(needsXReg(rt) ? "x0" : "w0");
        if (!needsXReg(rt)) canonicalise(d, rt);
        storeReg(d, n.res());
    }

    // The downcast is a pass-through: the pointer type carries the target
    // layout, so the verifier and the lowering already agree on the shape. The
    // failable form still emits its (currently empty) guard, because the label
    // is what a real runtime check will hang off.
    void emitDowncast(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        if (((IROperand*)n.ops().get((u32)1)).kind() != (u8)OPK_IMMI)
            { unsupported(String.withCString("Downcast:id")); return; }
        if (n.op().equals(String.withCString("ClassDowncastFailable"))) {
            String* done = localLabel(String.withCString("downcast_done"));
            _out.appendFormat("    cbz x16, %s\n", done.cString());
            _out.appendFormat("%s:\n", done.cString());
        }
        storeReg(String.withCString("x16"), n.res());
    }

    // memcpy / memset. The count goes in w2, which zero-extends into x2 — a
    // narrow runtime size read through x2 would pull eight bytes out of a
    // four-byte slot.
    void emitMemHelper(IRInsn* n, String* sym, bool srcIsPtr)
    {
        if (n.ops().count() < (u32)4) { unsupported(n.op()); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x0"));
        materialise((IROperand*)n.ops().get((u32)1), String.withCString(srcIsPtr ? "x1" : "w1"));
        materialise((IROperand*)n.ops().get((u32)2), String.withCString("w2"));
        _out.appendFormat("    bl %s\n", sym.cString());
    }

    // An inline-asm body is emitted verbatim — on this target it therefore has
    // to be valid AArch64, since the integrated assembler is downstream.
    // Identifier references the lowering planted as {{XTLOCAL:<vid>}} resolve
    // to the local's sp-relative slot WITHOUT enclosing brackets, so a user's
    // `str w0, [result]` becomes `str w0, [sp, #N]`.
    void emitAsm(IRInsn* n)
    {
        u32 cid = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_CPOOL) { cid = o.cid(); break; }
        }
        if (cid == (u32)$FFFF_FFFF || _m == (IRModule*)0
         || cid >= _m.consts().count()) { unsupported(String.withCString("Asm:body")); return; }
        String* text = resolveAsmLocals(bytesToString((Array*)_m.consts().get(cid)));
        _out.appendCString("    // inline asm\n");
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* l = (String*)lines.get(i);
            if (l.byteLength() == (u32)0) continue;
            _out.appendFormat("    %s\n", l.cString());
        }
    }

    // `{{XTLOCAL:<vid>}}` becomes the local's sp-relative slot WITHOUT enclosing
    // brackets, so the user's `str w0, [result]` reads `str w0, [sp, #N]` —
    // the natural memory-operand syntax on this target.
    String* resolveAsmLocals(String* text)
    {
        String* marker = String.withCString("{{XTLOCAL:");
        if (text.byteIndexOf(marker) == (u32)$FFFF_FFFF) return text;
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < text.byteLength()) {
            u32 at = text.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF) { out.append(text.substringFromByte(i)); break; }
            out.append(text.substringBytes(i, at - i));
            u32 j = at + marker.byteLength();
            u32 vid = (u32)0;
            while (j < text.byteLength() && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9') {
                vid = vid * (u32)10 + (u32)(text.byteAt(j) - (u8)'0');
                j = j + (u32)1;
            }
            if (j + (u32)1 < text.byteLength() && text.byteAt(j) == (u8)'}') j = j + (u32)2;
            IRValue* v = _fn.valueWithId(vid);
            out.appendFormat("sp, #%lu", v == (IRValue*)0 ? (u32)0 : slotOf(v));
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

    // ── Instruction fusion ───────────────────────────────────────────────
    //
    // Two float shapes collapse into single instructions: an integer-to-float
    // convert feeding a divide by 2^k becomes the fixed-point `scvtf #k`, and a
    // multiply feeding an add or subtract becomes an fma.
    Map* _fusedAway;       // values whose defining op is subsumed by a consumer
    Map* _fuseKind;        // result -> "scvtf" or "fma"
    Map* _fuseA;           // fma: the multiplicand operands, and the addend
    Map* _fuseB;
    Map* _fuseC;
    Map* _fuseMnem;
    Map* _fuseSrc;         // scvtf: the integer source operand
    Map* _fuseSigned;
    Map* _fuseBits;

    void computeFusions(IRFunc* fn)
    {
        _fusedAway = new Map();
        _fuseKind = new Map();
        _fuseA = new Map(); _fuseB = new Map(); _fuseC = new Map();
        _fuseMnem = new Map(); _fuseSrc = new Map();
        _fuseSigned = new Map(); _fuseBits = new Map();
        fuseFixedPointConverts(fn);
        fuseMultiplyAdds(fn);
    }

    // `(float)i / 2^k` is one fixed-point convert. The divisor const is NOT
    // read by the fused form, so a multi-use one (const-hoisted across a loop)
    // is fine; it is only dropped when every one of its uses fused.
    void fuseFixedPointConverts(IRFunc* fn)
    {
        Map* divFused = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("FDiv"))) continue;
                if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) continue;
                IROperand* o0 = (IROperand*)n.ops().get((u32)0);
                IROperand* o1 = (IROperand*)n.ops().get((u32)1);
                if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE) continue;
                if (useCountOf(o0.val()) != (u32)1) continue;      // the convert single-use
                Object* cd = _defOf.get((Hashable*)o0.val());
                if (cd == (Object*)0) continue;
                IRInsn* cvt = (IRInsn*)cd;
                bool sgn = cvt.op().equals(String.withCString("SIToFp"));
                if (!sgn && !cvt.op().equals(String.withCString("UIToFp"))) continue;
                if (cvt.ops().count() < (u32)1) continue;
                IROperand* src = (IROperand*)cvt.ops().get((u32)0);
                if (src.kind() != (u8)OPK_USE) continue;
                Object* dv = _defOf.get((Hashable*)o1.val());
                u32 fbits = dv == (Object*)0 ? (u32)0 : pow2FbitsOfConst((IRInsn*)dv);
                if (fbits < (u32)1) continue;
                u32 maxb = n.res().ty().equals(String.withCString("F64")) ? (u32)64 : (u32)32;
                if (fbits > maxb) continue;
                _fuseKind.set((Hashable*)n.res(), (Object*)String.withCString("scvtf"));
                _fuseSrc.set((Hashable*)n.res(), (Object*)src);
                _fuseSigned.set((Hashable*)n.res(), (Object*)Number.with(sgn ? (i32)1 : (i32)0));
                _fuseBits.set((Hashable*)n.res(), (Object*)Number.withU32(fbits));
                _fusedAway.set((Hashable*)o0.val(), (Object*)o0.val());   // the standalone convert
                Object* c = divFused.get((Hashable*)o1.val());
                divFused.set((Hashable*)o1.val(),
                             (Object*)Number.withU32((c == (Object*)0 ? (u32)0 : ((Number*)c).asU32()) + (u32)1));
            }
        }
        // A divisor whose every use fused away is now dead.
        Array* keys = divFused.allKeys();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)keys.get(i);
            if (((Number*)divFused.get((Hashable*)v)).asU32() == useCountOf(v))
                _fusedAway.set((Hashable*)v, (Object*)v);
        }
    }

    // If `c` is a Const whose float value is exactly 2^k with k >= 1, that k;
    // else zero.
    static u32 pow2FbitsOfConst(IRInsn* c)
    {
        if (c == (IRInsn*)0 || !c.op().equals(String.withCString("Const"))) return (u32)0;
        if (c.ops().count() < (u32)1) return (u32)0;
        IROperand* o = (IROperand*)c.ops().get((u32)0);
        if (o.kind() != (u8)OPK_IMMF) return (u32)0;
        String* hex = o.fpHex();
        u32 hi = (hexChunk(hex, (u32)0) << (u32)16) | hexChunk(hex, (u32)1);
        u32 lo = (hexChunk(hex, (u32)2) << (u32)16) | hexChunk(hex, (u32)3);
        u32 sign = (hi >> (u32)31) & (u32)1;
        u32 expf = (hi >> (u32)20) & (u32)$7FF;
        u32 mant = (hi & (u32)$F_FFFF) | lo;          // any mantissa bit set at all
        if (sign != (u32)0 || mant != (u32)0 || expf == (u32)0 || expf == (u32)$7FF)
            return (u32)0;
        i32 e = (i32)expf - (i32)1023;
        return e >= (i32)1 ? (u32)e : (u32)0;
    }

    // a*b+c becomes fmadd, c-a*b fmsub, a*b-c fnmsub. One IEEE rounding instead
    // of two, so NOT bit-identical to a separate fmul and fadd — but it is what
    // clang emits under default FP contraction.
    void fuseMultiplyAdds(IRFunc* fn)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                bool isAdd = n.op().equals(String.withCString("FAdd"));
                bool isSub = n.op().equals(String.withCString("FSub"));
                if (!isAdd && !isSub) continue;
                if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) continue;
                IROperand* o0 = (IROperand*)n.ops().get((u32)0);
                IROperand* o1 = (IROperand*)n.ops().get((u32)1);
                // The fused FMul must be the instruction IMMEDIATELY before the
                // add. Allocation runs BEFORE fusion and ends the multiply
                // operands' ranges at the (elided) FMul, so a value computed
                // between the FMul and the add can take their registers and the
                // fused fmadd then reads clobbered ones — which is what broke a
                // sum of two products, a*a + b*b (c2xc bug 34). Adjacency keeps
                // the fused operands live and leaves the addend (already live to
                // the add) as the non-adjacent product, emitted normally.
                IRInsn* prev = (i > (u32)0) ? (IRInsn*)bb.insns().get(i - (u32)1) : (IRInsn*)0;
                IRInsn* mul = (IRInsn*)0;
                IROperand* addend = (IROperand*)0;
                String* mnem = (String*)0;
                if (isAdd) {
                    mul = singleUseFMul(o0, prev);
                    if (mul != (IRInsn*)0) { addend = o1; mnem = String.withCString("fmadd"); }
                    else {
                        mul = singleUseFMul(o1, prev);
                        if (mul != (IRInsn*)0) { addend = o0; mnem = String.withCString("fmadd"); }
                    }
                } else {
                    mul = singleUseFMul(o1, prev);
                    if (mul != (IRInsn*)0) { addend = o0; mnem = String.withCString("fmsub"); }
                    else {
                        mul = singleUseFMul(o0, prev);
                        if (mul != (IRInsn*)0) { addend = o1; mnem = String.withCString("fnmsub"); }
                    }
                }
                if (mul == (IRInsn*)0) continue;
                _fuseKind.set((Hashable*)n.res(), (Object*)String.withCString("fma"));
                _fuseMnem.set((Hashable*)n.res(), (Object*)mnem);
                _fuseA.set((Hashable*)n.res(), (Object*)mul.ops().get((u32)0));
                _fuseB.set((Hashable*)n.res(), (Object*)mul.ops().get((u32)1));
                _fuseC.set((Hashable*)n.res(), (Object*)addend);
                _fusedAway.set((Hashable*)mul.res(), (Object*)mul.res());
            }
        }
    }

    IRInsn* singleUseFMul(IROperand* o, IRInsn* prev)
    {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) return (IRInsn*)0;
        if (useCountOf(o.val()) != (u32)1) return (IRInsn*)0;
        if (inMap(_fusedAway, o.val())) return (IRInsn*)0;
        Object* d = _defOf.get((Hashable*)o.val());
        if (d == (Object*)0) return (IRInsn*)0;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("FMul")) || n.ops().count() < (u32)2)
            return (IRInsn*)0;
        if (n != prev) return (IRInsn*)0;      // adjacency (bug 34)
        return n;
    }

    void emitFused(IRInsn* n)
    {
        String* kind = (String*)_fuseKind.get((Hashable*)n.res());
        String* ty = n.res().ty();
        if (kind.equals(String.withCString("scvtf"))) {
            IROperand* src = (IROperand*)_fuseSrc.get((Hashable*)n.res());
            String* s = operandReg(src, String.withCString("w16"));
            String* d = resultReg(n.res(), fregName((u32)0, ty));
            bool sgn = ((Number*)_fuseSigned.get((Hashable*)n.res())).asI32() != (i32)0;
            _out.appendFormat("    %s %s, %s, #%lu\n", sgn ? "scvtf" : "ucvtf",
                              d.cString(), s.cString(),
                              ((Number*)_fuseBits.get((Hashable*)n.res())).asU32());
            storeReg(d, n.res());
            return;
        }
        String* ra = operandReg((IROperand*)_fuseA.get((Hashable*)n.res()), fregName((u32)0, ty));
        String* rb = operandReg((IROperand*)_fuseB.get((Hashable*)n.res()), fregName((u32)1, ty));
        String* rc = operandReg((IROperand*)_fuseC.get((Hashable*)n.res()), fregName((u32)2, ty));
        String* d = resultReg(n.res(), fregName((u32)0, ty));
        _out.appendFormat("    %s %s, %s, %s, %s\n",
                          ((String*)_fuseMnem.get((Hashable*)n.res())).cString(),
                          d.cString(), ra.cString(), rb.cString(), rc.cString());
        storeReg(d, n.res());
    }

    // ── No-wrap (induction-bound) analysis ───────────────────────────────
    //
    // A U8/U16 arithmetic result is masked back into its width after every op.
    // When the value provably cannot reach past that width, masked and unmasked
    // are the same value and the uxtb/uxth can go — which matters most on the
    // loop-carried critical path the mask otherwise sits on.
    //
    // Bounds are UNSIGNED upper bounds. The reference computes them in 64 bits;
    // there is no 64-bit integer here, so UNBOUNDED is the u32 sentinel
    // 0xFFFFFFFF. That coincides with a genuine U32 upper bound, which is
    // harmless: every place the two would differ, the bound is compared against
    // a U8 or U16 type max and fails either way, or it caps a recursion at a
    // value the default already supplies.
    Map* _noCanon;         // results whose canonicalising extend can be dropped
    Map* _guardBound;      // value -> the upper bound a dominating guard proves
    Map* _ubMemo;          // value -> its memoised clean bound

    static u32 UNBOUNDED(void) { return (u32)$FFFF_FFFF; }

    // The unsigned maximum a canonicalised value of this type can hold. Only
    // the unsigned narrow types are bounded — a negative signed value reads as
    // a huge unsigned one, and pointers, memory and floats are not ranged.
    static u32 typeMaxU(String* t)
    {
        if (t == (String*)0) return UNBOUNDED();
        if (t.equals(String.withCString("Bool")) || t.equals(String.withCString("U8")))
            return (u32)$FF;
        if (t.equals(String.withCString("U16"))) return (u32)$FFFF;
        if (t.equals(String.withCString("U32"))) return (u32)$FFFF_FFFF;
        return UNBOUNDED();
    }

    static u32 satAdd(u32 a, u32 b)
    {
        u32 s = a + b;
        return s < a ? UNBOUNDED() : s;
    }

    static u32 satMul(u32 a, u32 b)
    {
        if (a == (u32)0 || b == (u32)0) return (u32)0;
        u32 p = a * b;
        return p / a != b ? UNBOUNDED() : p;
    }

    // The value a use holds AFTER canonicalisation, memoised. A cycle resolves
    // to the type maximum.
    u32 ubClean(IRValue* v, Array* visiting)
    {
        Object* m = _ubMemo.get((Hashable*)v);
        if (m != (Object*)0) return ((Number*)m).asU32();
        u32 tmax = typeMaxU(v.ty());
        if (hasVal(visiting, v)) return tmax;              // a cycle: be conservative
        visiting.add((Object*)v);
        u32 raw = ubRaw(v, visiting, tmax, false);
        removeVal(visiting, v);
        u32 r = raw < tmax ? raw : tmax;
        _ubMemo.set((Hashable*)v, (Object*)Number.withU32(r));
        return r;
    }

    static void removeVal(Array* a, IRValue* v)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v) { a.removeAt(i); return; }
    }

    // The PRE-mask arithmetic magnitude, from the safe ops only. Anything else
    // is unbounded — a give-up for ARITHMETIC must say unbounded, not typeMax,
    // or the caller would wrongly drop a mask that is doing real work.
    u32 ubRaw(IRValue* v, Array* visiting, u32 tmax, bool ignoreGuard)
    {
        Object* dd = _defOf.get((Hashable*)v);
        // A parameter or entry-live narrow value is canonicalised on entry, so
        // it is <= typeMax, and that IS a sound bound.
        if (dd == (Object*)0) return tmax;
        IRInsn* d = (IRInsn*)dd;
        // A guard proves v <= B at every use it dominates, and the pass that
        // records one only does so when ALL of v's non-guard uses are so
        // dominated. It also CAPS the recursion, which is what keeps a chain of
        // guarded increments bounded instead of compounding the stride.
        //
        // But the bound holds at uses DOMINATED by the guard, not at the guard
        // comparison itself: that compare reads v's raw, pre-mask value. So
        // when deciding whether v's OWN definition may skip its mask, v's own
        // guard bound is ignored — nested operands still use theirs, soundly,
        // because they are dominated.
        if (!ignoreGuard) {
            Object* gb = _guardBound.get((Hashable*)v);
            if (gb != (Object*)0) return ((Number*)gb).asU32();
        }
        String* op = d.op();
        if (op.equals(String.withCString("Const"))) {
            if (d.ops().count() < (u32)1) return UNBOUNDED();
            return immBound((IROperand*)d.ops().get((u32)0));
        }
        if (op.equals(String.withCString("Add"))) {
            if (d.ops().count() < (u32)2) return UNBOUNDED();
            return satAdd(opBound(d, (u32)0, visiting), opBound(d, (u32)1, visiting));
        }
        if (op.equals(String.withCString("Mul"))) {
            if (d.ops().count() < (u32)2) return UNBOUNDED();
            return satMul(opBound(d, (u32)0, visiting), opBound(d, (u32)1, visiting));
        }
        if (op.equals(String.withCString("Shl"))) {
            // Only a CONSTANT shift has a known multiplier; a variable one can
            // push bits arbitrarily high, so it keeps its mask.
            if (d.ops().count() < (u32)2) return UNBOUNDED();
            IROperand* sh = (IROperand*)d.ops().get((u32)1);
            if (sh.kind() != (u8)OPK_IMMI || sh.imm() < (i32)0 || sh.imm() >= (i32)32)
                return UNBOUNDED();
            return satMul(opBound(d, (u32)0, visiting), (u32)1 << (u32)sh.imm());
        }
        if (op.equals(String.withCString("And"))) {
            if (d.ops().count() < (u32)2) return UNBOUNDED();
            u32 a = opBound(d, (u32)0, visiting);
            u32 b = opBound(d, (u32)1, visiting);
            return a < b ? a : b;
        }
        if (op.equals(String.withCString("ZExt"))) {
            if (d.ops().count() < (u32)1) return UNBOUNDED();
            return opBound(d, (u32)0, visiting);
        }
        if (op.equals(String.withCString("Phi"))) {
            // Every input is <= its own type max, so the phi is too — and a
            // loop guard may tighten that further.
            Object* gb = _guardBound.get((Hashable*)v);
            return gb != (Object*)0 ? ((Number*)gb).asU32() : tmax;
        }
        // Sub (which can underflow), Or, Xor, calls, loads…
        return UNBOUNDED();
    }

    u32 opBound(IRInsn* d, u32 i, Array* visiting)
    {
        IROperand* o = (IROperand*)d.ops().get(i);
        if (o.kind() == (u8)OPK_IMMI) return immBound(o);
        if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0) return ubClean(o.val(), visiting);
        return UNBOUNDED();
    }

    static u32 immBound(IROperand* o)
    {
        if (o.kind() != (u8)OPK_IMMI) return UNBOUNDED();
        if (o.uimm()) return (u32)o.imm();
        return o.imm() >= (i32)0 ? (u32)o.imm() : UNBOUNDED();
    }

    void computeNoWrap(IRFunc* fn)
    {
        _noCanon = new Map();
        _guardBound = new Map();
        _ubMemo = new Map();
        u32 nb = fn.blocks().count();
        if (nb == (u32)0) return;
        Array* succs = new Array();
        Array* preds = new Array();
        buildCFG(fn, succs, preds);
        headerGuards(fn, succs, preds);
        exitGuards(fn, preds);
        decideNoCanon(fn);
    }

    void buildCFG(IRFunc* fn, Array* succs, Array* preds)
    {
        u32 nb = fn.blocks().count();
        for (u32 i = (u32)0; i < nb; i = i + (u32)1) {
            succs.add((Object*)new Array());
            preds.add((Object*)new Array());
        }
        for (u32 si = (u32)0; si < nb; si = si + (u32)1) {
            IRInsn* t = ((IRBlock*)fn.blocks().get(si)).term();
            if (t == (IRInsn*)0) continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1) {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                i32 ti = blockIndexOf(fn, o.blk());
                if (ti < (i32)0) continue;
                ((Array*)succs.get(si)).add((Object*)Number.with((i32)ti));
                ((Array*)preds.get((u32)ti)).add((Object*)Number.with((i32)si));
            }
        }
    }

    // A back edge L->H makes H a loop header; the body is H plus every block
    // that reaches L without passing through H. Using the PRECISE body rather
    // than the [header..latch] index span keeps a sibling exit block that merely
    // SITS inside that span out of the loop, so the guard's exit edge is
    // correctly seen to leave it.
    Array* loopBodyOf(IRFunc* fn, Array* succs, Array* preds, u32 hidx)
    {
        Array* body = (Array*)0;
        u32 nb = fn.blocks().count();
        for (u32 li = (u32)0; li < nb; li = li + (u32)1) {
            Array* ss = (Array*)succs.get(li);
            bool backEdge = false;
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                if ((u32)((Number*)ss.get(k)).asI32() == hidx && hidx <= li) backEdge = true;
            if (!backEdge) continue;
            if (body == (Array*)0) { body = new Array(); body.add((Object*)Number.with((i32)hidx)); }
            Array* wl = new Array();
            wl.add((Object*)Number.with((i32)li));
            while (wl.count() > (u32)0) {
                u32 n = (u32)((Number*)wl.get(wl.count() - (u32)1)).asI32();
                wl.removeAt(wl.count() - (u32)1);
                if (hasIdx(body, n)) continue;
                body.add((Object*)Number.with((i32)n));
                if (n == hidx) continue;
                Array* ps = (Array*)preds.get(n);
                for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1) wl.add(ps.get(k));
            }
        }
        return body;
    }

    static bool hasIdx(Array* a, u32 v)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((u32)((Number*)a.get(i)).asI32() == v) return true;
        return false;
    }

    // A loop header whose terminator tests `phi <ult/ule B` on the in-loop edge
    // bounds that phi by B.
    void headerGuards(IRFunc* fn, Array* succs, Array* preds)
    {
        u32 nb = fn.blocks().count();
        for (u32 hi = (u32)0; hi < nb; hi = hi + (u32)1) {
            Array* body = loopBodyOf(fn, succs, preds, hi);
            if (body == (Array*)0) continue;                 // not a loop header
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
            IRInsn* term = H.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))) continue;
            if (term.ops().count() < (u32)3) continue;
            IROperand* c = (IROperand*)term.ops().get((u32)0);
            if (c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0) continue;
            Object* cd = _defOf.get((Hashable*)c.val());
            if (cd == (Object*)0) continue;
            IRInsn* cmp = (IRInsn*)cd;
            if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() < (u32)2) continue;
            IROperand* o0 = (IROperand*)cmp.ops().get((u32)0);
            IROperand* o1 = (IROperand*)cmp.ops().get((u32)1);
            bool phiIs0 = isHeaderPhi(H, o0);
            bool phiIs1 = isHeaderPhi(H, o1);
            if (phiIs0 == phiIs1) continue;                  // exactly one side a phi
            IROperand* phiOp = phiIs0 ? o0 : o1;
            IROperand* boundOp = phiIs0 ? o1 : o0;
            // SOUNDNESS: the guard bounds the phi only if every in-loop block is
            // reached THROUGH this branch — exactly one target stays in the loop
            // and the other exits. Then the only way past the header into the
            // loop is the body edge, so the predicate holds at every in-loop use.
            i32 trueIdx = blockIndexOf(fn, ((IROperand*)term.ops().get((u32)1)).blk());
            i32 falseIdx = blockIndexOf(fn, ((IROperand*)term.ops().get((u32)2)).blk());
            bool trueIn = trueIdx >= (i32)0 && hasIdx(body, (u32)trueIdx);
            bool falseIn = falseIdx >= (i32)0 && hasIdx(body, (u32)falseIdx);
            if (trueIn == falseIn) continue;
            String* eff = phiIs0 ? cmp.pred() : swapPred(cmp.pred());
            if (!trueIn) eff = negatePred(eff);               // the body is the false edge
            // Only an unsigned upper bound gives a sound zero-extended bound.
            if (!eff.equals(String.withCString("ULT")) && !eff.equals(String.withCString("ULE")))
                continue;
            u32 b;
            if (boundOp.kind() == (u8)OPK_IMMI) b = immBound(boundOp);
            else if (boundOp.kind() == (u8)OPK_USE) b = ubClean(boundOp.val(), new Array());
            else continue;
            if (b == UNBOUNDED()) continue;
            // `phi < b` implies `phi <= b`, so b is a safe over-estimate for both.
            _guardBound.set((Hashable*)phiOp.val(), (Object*)Number.withU32(b));
            _ubMemo = new Map();                              // bounds changed
        }
    }

    static bool isHeaderPhi(IRBlock* H, IROperand* o)
    {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) return false;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1) {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == o.val()) return true;
        }
        return false;
    }

    static String* swapPred(String* p)
    {
        if (p == (String*)0) return p;
        if (p.equals(String.withCString("ULT"))) return String.withCString("UGT");
        if (p.equals(String.withCString("UGT"))) return String.withCString("ULT");
        if (p.equals(String.withCString("ULE"))) return String.withCString("UGE");
        if (p.equals(String.withCString("UGE"))) return String.withCString("ULE");
        if (p.equals(String.withCString("SLT"))) return String.withCString("SGT");
        if (p.equals(String.withCString("SGT"))) return String.withCString("SLT");
        if (p.equals(String.withCString("SLE"))) return String.withCString("SGE");
        if (p.equals(String.withCString("SGE"))) return String.withCString("SLE");
        return p;
    }

    // A var-trip-unrolled loop re-checks `k <= bound` before every replicated
    // body, so the increment feeding the next step is bounded by that check even
    // though it is not a loop-header phi. Generalise to ANY CondBranch on an
    // unsigned upper-bound compare whose continue edge dominates every non-guard
    // use of the value — which caps the otherwise-compounding `k += stride`
    // chain so its uxtb/uxth can drop.
    void exitGuards(IRFunc* fn, Array* preds)
    {
        u32 nb = fn.blocks().count();
        Array* dom = computeDominators(fn, preds);
        Map* useBlk = new Map();
        Map* useIn = new Map();
        collectUseSites(fn, useBlk, useIn);
        for (u32 bg = (u32)0; bg < nb; bg = bg + (u32)1) {
            IRInsn* term = ((IRBlock*)fn.blocks().get(bg)).term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))) continue;
            if (term.ops().count() < (u32)3) continue;
            IROperand* c = (IROperand*)term.ops().get((u32)0);
            if (c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0) continue;
            Object* cd = _defOf.get((Hashable*)c.val());
            if (cd == (Object*)0) continue;
            IRInsn* cmp = (IRInsn*)cd;
            if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() < (u32)2) continue;
            IROperand* o0 = (IROperand*)cmp.ops().get((u32)0);
            IROperand* o1 = (IROperand*)cmp.ops().get((u32)1);
            // Exactly one side a value to bound; the other the bound.
            IROperand* vOp = (IROperand*)0;
            IROperand* bOp = (IROperand*)0;
            bool vIs0 = true;
            if (o0.kind() == (u8)OPK_USE) { vOp = o0; bOp = o1; }
            else if (o1.kind() == (u8)OPK_USE) { vOp = o1; bOp = o0; vIs0 = false; }
            if (vOp == (IROperand*)0) continue;
            String* eff = vIs0 ? cmp.pred() : swapPred(cmp.pred());
            i32 ct;
            if (eff.equals(String.withCString("ULT")) || eff.equals(String.withCString("ULE"))) {
                ct = blockIndexOf(fn, ((IROperand*)term.ops().get((u32)1)).blk());
            } else {
                String* ne = negatePred(eff);
                if (!ne.equals(String.withCString("ULT")) && !ne.equals(String.withCString("ULE")))
                    continue;
                ct = blockIndexOf(fn, ((IROperand*)term.ops().get((u32)2)).blk());
            }
            if (ct < (i32)0) continue;
            // SOUNDNESS: the continue target's ONLY predecessor must be the
            // guard block, so the only way to reach it is across the v <= B
            // edge. A multi-pred target could be entered on a path that skips
            // the guard entirely, where v may exceed B — dominance of the uses
            // is not enough on its own.
            if (((Array*)preds.get((u32)ct)).count() != (u32)1) continue;
            u32 B;
            if (bOp.kind() == (u8)OPK_IMMI) { B = immBound(bOp); }
            else if (bOp.kind() == (u8)OPK_USE) { B = ubClean(bOp.val(), new Array()); }
            else continue;
            if (B == UNBOUNDED()) continue;
            if (!allUsesDominated(useBlk, useIn, vOp.val(), cmp, dom, (u32)ct)) continue;
            Object* cur = _guardBound.get((Hashable*)vOp.val());
            if (cur == (Object*)0 || ((Number*)cur).asU32() > B) {
                _guardBound.set((Hashable*)vOp.val(), (Object*)Number.withU32(B));
                _ubMemo = new Map();
            }
        }
    }

    // Every use of v, except the guard's own compare, must sit in a block
    // dominated by the continue target — that is what makes v <= B hold there.
    static bool allUsesDominated(Map* useBlk, Map* useIn, IRValue* v, IRInsn* cmp,
                                 Array* dom, u32 ct)
    {
        Object* bs = useBlk.get((Hashable*)v);
        if (bs == (Object*)0) return true;
        Array* blocks = (Array*)bs;
        Array* insns = (Array*)useIn.get((Hashable*)v);
        for (u32 u = (u32)0; u < blocks.count(); u = u + (u32)1) {
            if ((IRInsn*)insns.get(u) == cmp) continue;       // the guard test itself
            u32 bi = (u32)((Number*)blocks.get(u)).asI32();
            if (!hasIdx((Array*)dom.get(bi), ct)) return false;
        }
        return true;
    }

    void collectUseSites(IRFunc* fn, Map* useBlk, Map* useIn)
    {
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(bi);
            recUses(useBlk, useIn, bb.phis(), bi);
            recUses(useBlk, useIn, bb.insns(), bi);
            if (bb.term() != (IRInsn*)0) recUse(useBlk, useIn, bb.term(), bi);
        }
    }

    static void recUses(Map* useBlk, Map* useIn, Array* list, u32 bi)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            recUse(useBlk, useIn, (IRInsn*)list.get(i), bi);
    }

    static void recUse(Map* useBlk, Map* useIn, IRInsn* n, u32 bi)
    {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) continue;
            Object* have = useBlk.get((Hashable*)o.val());
            Array* bs;
            Array* ins;
            if (have == (Object*)0) {
                bs = new Array(); ins = new Array();
                useBlk.set((Hashable*)o.val(), (Object*)bs);
                useIn.set((Hashable*)o.val(), (Object*)ins);
            } else {
                bs = (Array*)have;
                ins = (Array*)useIn.get((Hashable*)o.val());
            }
            bs.add((Object*)Number.with((i32)bi));
            ins.add((Object*)n);
        }
    }

    // Iterative dominators: dom[n] = {n} union the intersection of its
    // predecessors' sets, block 0 the entry.
    Array* computeDominators(IRFunc* fn, Array* preds)
    {
        u32 nb = fn.blocks().count();
        Array* dom = new Array();
        for (u32 i = (u32)0; i < nb; i = i + (u32)1) {
            Array* set = new Array();
            if (i == (u32)0) set.add((Object*)Number.with((i32)0));
            else for (u32 k = (u32)0; k < nb; k = k + (u32)1) set.add((Object*)Number.with((i32)k));
            dom.add((Object*)set);
        }
        bool changed = true;
        while (changed) {
            changed = false;
            for (u32 n = (u32)1; n < nb; n = n + (u32)1) {
                Array* ps = (Array*)preds.get(n);
                Array* it = (Array*)0;
                for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1) {
                    u32 pi = (u32)((Number*)ps.get(k)).asI32();
                    if (it == (Array*)0) it = copyIdx((Array*)dom.get(pi));
                    else it = intersectIdx(it, (Array*)dom.get(pi));
                }
                if (it == (Array*)0) it = new Array();
                if (!hasIdx(it, n)) it.add((Object*)Number.with((i32)n));
                if (!sameIdx(it, (Array*)dom.get(n))) { dom.set(n, (Object*)it); changed = true; }
            }
        }
        return dom;
    }

    static Array* copyIdx(Array* a)
    {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1) o.add(a.get(i));
        return o;
    }

    static Array* intersectIdx(Array* a, Array* b)
    {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (hasIdx(b, (u32)((Number*)a.get(i)).asI32())) o.add(a.get(i));
        return o;
    }

    static bool sameIdx(Array* a, Array* b)
    {
        if (a.count() != b.count()) return false;
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!hasIdx(b, (u32)((Number*)a.get(i)).asI32())) return false;
        return true;
    }

    void decideNoCanon(IRFunc* fn)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0) continue;
                String* t = n.res().ty();
                if (!t.equals(String.withCString("U8")) && !t.equals(String.withCString("U16")))
                    continue;
                String* op = n.op();
                if (!op.equals(String.withCString("Add")) && !op.equals(String.withCString("Mul"))
                 && !op.equals(String.withCString("Shl")) && !op.equals(String.withCString("And"))
                 && !op.equals(String.withCString("ZExt"))) continue;
                // ignoreGuard: this value's OWN guard must not let its
                // definition drop the mask — the guard compare reads it
                // pre-mask.
                u32 raw = ubRaw(n.res(), new Array(), typeMaxU(t), true);
                if (raw <= typeMaxU(t)) _noCanon.set((Hashable*)n.res(), (Object*)n.res());
            }
        }
    }

    // ── Module-level data ────────────────────────────────────────────────
    //
    // Globals, string literals, vtables and load-time constructors. A global's
    // slot is sized in THIS target's widths, not the shared layout's: a pointer
    // is 8 bytes here, so a 2-byte reservation would let an 8-byte store spill
    // into the adjacent global — and an ARC release's load-old would then read
    // a garbage neighbour as a pointer.
    bool _initHeaderDone;
    bool _uninitHeaderDone;

    void emitModuleData(IRModule* m)
    {
        _initHeaderDone = false;
        _uninitHeaderDone = false;
        emitDataGlobals(m);
        emitStringLits(m);
        emitVTables(m);
        if (m.modinits().count() > (u32)0) {
            // dyld (and the XTOS loader's equivalent scan) runs everything in
            // __mod_init_func before main, which is what drives the XG-NIB
            // object factories' self-registration with no per-app code.
            _out.appendCString("\n// Load-time constructors\n");
            _out.appendCString("    .section __DATA,__mod_init_func,mod_init_funcs\n");
            _out.appendCString("    .p2align 3\n");
            for (u32 i = (u32)0; i < m.modinits().count(); i = i + (u32)1)
                _out.appendFormat("    .quad _%s\n", ((String*)m.modinits().get(i)).cString());
        }
    }

    void initHeader(void)
    {
        if (_initHeaderDone) return;
        _out.appendCString("\n// Module data (initialised)\n");
        _out.appendCString("    .section __DATA,__data\n");
        _initHeaderDone = true;
    }

    void emitDataGlobals(IRModule* m)
    {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            if (sym.kind() != (u8)SYM_DATAGLOBAL) continue;
            if (sym.globalTy() == (String*)0) continue;
            // An extern global is DEFINED IN ANOTHER MODULE: reserve nothing.
            // Defining it here would give this module a SECOND copy whose
            // writes never reach the defining module's — silently.
            if (sym.isExtern()) continue;
            u32 size = fieldWidth(sym.globalTy());
            if (size == (u32)0) size = (u32)8;
            Array* bytes = sym.bytes();
            if (bytes != (Array*)0 && bytes.count() > (u32)0) {
                initHeader();
                if (isAggTy(sym.globalTy()))
                    bytes = relayAggInit(bytes, layoutOf(sym.globalTy()));
                else if (isFloatTy(sym.globalTy()) && bytes.count() != size)
                    bytes = relayFloatInit(bytes, sym.globalTy());
                // Natural alignment, capped at 8 (uxkit/029) — see the
                // reference's xtArm64GlobalP2Align for why size decides it.
                _out.appendFormat("    .p2align %lu\n", (i32)globalP2Align(size));
                _out.appendFormat("    .globl _%s\n_%s:\n", sym.name().cString(),
                                  sym.name().cString());
                for (u32 b = (u32)0; b < bytes.count(); b = b + (u32)1)
                    _out.appendFormat("    .byte 0x%s\n",
                                      IRSymbol.hex2(((Number*)bytes.get(b)).asU32()).cString());
                // Pad with zeroes when the image falls short of the slot.
                for (u32 b = bytes.count(); b < size; b = b + (u32)1)
                    _out.appendCString("    .byte 0x00\n");
            } else {
                if (!_uninitHeaderDone) {
                    _out.appendCString("\n// Module data (zero-init)\n");
                    _uninitHeaderDone = true;
                }
                // `.comm`, not `.lcomm`: an xtc global escapes — it is visible
                // across translation units and to a linking C stub. The third
                // argument is log2 alignment.
                // Mach-O `.comm` takes LOG2 alignment: the old `1` meant two
                // bytes, not "none", and not enough for a pointer.
                _out.appendFormat("    .comm _%s, %lu, %lu\n", sym.name().cString(),
                                  size, (i32)globalP2Align(size));
            }
        }
    }

    // Re-lay an aggregate's initial image into this target's layout. The
    // DESTINATION is addressed at the SAME recorded field offsets as the
    // source (blewit #5: the front end lays out once and the backends read
    // the layout verbatim), so the relay's remaining jobs are width fixups —
    // a narrow source zero-extends into a wider slot — never placement.
    Array* relayAggInit(Array* src, IRLayout* l)
    {
        if (l == (IRLayout*)0) return src;
        // The full layout footprint, tail pad included.
        u32 total = l.size();
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1) {
            u32 fend = l.offsetAt(i) + fieldWidth(l.typeAt(i));
            if (fend > total) total = fend;
        }
        if (total == (u32)0) return src;
        Array* dst = new Array();
        for (u32 i = (u32)0; i < total; i = i + (u32)1) dst.add((Object*)Number.with((i32)0));
        relayInto(dst, (u32)0, src, (u32)0, l);
        return dst;
    }

    void relayInto(Array* dst, u32 dstOffset, Array* src, u32 srcOffset, IRLayout* l)
    {
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1) {
            String* t = l.typeAt(i);
            u32 srcOff = srcOffset + l.offsetAt(i);
            u32 cursor = dstOffset + l.offsetAt(i);
            u32 dstW = fieldWidth(t);
            if (isAggTy(t)) {
                relayInto(dst, cursor, src, srcOff, layoutOf(t));
                continue;
            }
            // The image span to the next field includes any inter-field
            // padding; copy only the leaf's real width so pad never smears.
            u32 srcW = irFieldWidth(l, i);
            u32 nb = srcW < dstW ? srcW : dstW;
            for (u32 b = (u32)0; b < nb; b = b + (u32)1) {
                if (srcOff + b >= src.count()) break;      // a short image: zero tail
                if (cursor + b >= dst.count()) break;
                dst.set(cursor + b, src.get(srcOff + b));
            }
        }
    }

    // A field's width in the SOURCE image: the gap to the next field's offset,
    // or to the layout's end for the last one.
    static u32 irFieldWidth(IRLayout* l, u32 idx)
    {
        u32 start = l.offsetAt(idx);
        u32 end = (idx + (u32)1 < l.fieldCount()) ? l.offsetAt(idx + (u32)1) : l.size();
        return end > start ? end - start : (u32)0;
    }

    // A float global carries the abstract value as 8 IEEE double bits; an F32
    // slot needs those narrowed. A byte-list initialiser already matches the
    // target slot size, so it bypasses this.
    Array* relayFloatInit(Array* src, String* ty)
    {
        if (ty.equals(String.withCString("F64"))) {
            Array* dst = new Array();
            for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
                dst.add(i < src.count() ? src.get(i) : (Object*)Number.with((i32)0));
            return dst;
        }
        // The bits come in little-endian, and f32BitsOfDoubleHex reads a
        // big-endian hex spelling, so build the spelling from the top byte down.
        String* hex = String.withCString("");
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1) {
            u32 idx = (u32)7 - i;
            u32 v = idx < src.count() ? ((Number*)src.get(idx)).asU32() : (u32)0;
            hex.append(IRSymbol.hex2(v));
        }
        u32 bits = f32BitsOfDoubleHex(hex);
        Array* dst = new Array();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            dst.add((Object*)Number.with((i32)((bits >> ((u32)8 * i)) & (u32)$FF)));
        return dst;
    }

    // NUL-terminated bytes in __data. `.globl` so the @PAGE/@PAGEOFF relocation
    // anchors correctly — a bare local data symbol mis-resolves under adrp/add.
    void emitStringLits(IRModule* m)
    {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            if (sym.kind() != (u8)SYM_STRINGLIT) continue;
            initHeader();
            // A literal is object-LOCAL — no .globl (bug 136; mirrors the reference).
            _out.appendFormat("_%s:\n", sym.name().cString());
            Array* b = sym.bytes();
            if (b == (Array*)0 || b.count() == (u32)0) {
                _out.appendCString("    .byte 0x00\n");
                continue;
            }
            for (u32 k = (u32)0; k < b.count(); k = k + (u32)1)
                _out.appendFormat("    .byte 0x%s\n",
                                  IRSymbol.hex2(((Number*)b.get(k)).asU32()).cString());
        }
    }

    // One 8-byte method pointer per slot, so the `<Class>$vtbl` symbol that a
    // `new` references resolves at link time.
    void emitVTables(IRModule* m)
    {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            if (sym.kind() != (u8)SYM_VTABLE) continue;
            // An imported class's vtable lives in ITS library. A second table at
            // a different address would break RTTI identity, which compares
            // vtable addresses.
            if (sym.isExtern()) continue;
            initHeader();
            _out.appendFormat("    .globl _%s\n", sym.name().cString());
            _out.appendFormat("    .p2align 3\n_%s:\n", sym.name().cString());
            Array* e = sym.slots();
            if (e == (Array*)0 || e.count() == (u32)0) {
                _out.appendCString("    .quad 0\n");
                continue;
            }
            for (u32 k = (u32)0; k < e.count(); k = k + (u32)1) {
                String* name = (String*)e.get(k);
                if (name.byteLength() == (u32)0) { _out.appendCString("    .quad 0\n"); continue; }
                // A conformance itable is (protoId, &table) pairs, and the id is
                // a VALUE — a hash of the protocol name — so it is a literal
                // quad, not a label.
                String* pfx = String.withCString("__protoid_");
                if (name.hasPrefix(pfx))
                    _out.appendFormat("    .quad %s\n", name.substringFromByte(pfx.byteLength()).cString());
                else
                    _out.appendFormat("    .quad _%s\n", name.cString());
            }
        }
    }

    // ── SIMD (the auto-vectoriser's output) ──────────────────────────────
    //
    // Vector values are loop-local: a reduction accumulator is reduced to a
    // scalar at its loop exit and the body temps die each iteration. So
    // disjoint vectorised loops REUSE registers — assigning sequentially and
    // capping at 15 exhausts once a function has more than a handful of them.
    Map* _vecReg;               // vector value -> register name
    Map* _vecClass;             // vector value -> its coalescing class

    // emitAggCopy/aggChunk tail-rebase state (finding #13's family): the frame
    // base register, its bias, and the offset both pointers were rebased by.
    String* _aggFb;
    u32 _aggFbias;
    u32 _aggReb;

    bool dispatchVector(IRInsn* n, String* op)
    {
        if (op.equals(String.withCString("VLoad")))  { emitVLoad(n);  return true; }
        if (op.equals(String.withCString("VStore"))) { emitVStore(n); return true; }
        if (op.equals(String.withCString("VSplat"))) { emitVSplat(n); return true; }
        if (op.equals(String.withCString("VAdd")) || op.equals(String.withCString("VSub"))
         || op.equals(String.withCString("VMul")) || op.equals(String.withCString("VAnd"))
         || op.equals(String.withCString("VOr"))  || op.equals(String.withCString("VXor")))
            { emitVBin(n); return true; }
        if (op.equals(String.withCString("VMax")) || op.equals(String.withCString("VMin")))
            { emitVMinMax(n); return true; }
        if (op.equals(String.withCString("VAddLP"))) { emitVAddLP(n); return true; }
        if (op.equals(String.withCString("VICmp")))  { emitVICmp(n);  return true; }
        if (op.equals(String.withCString("VReduceAdd")) || op.equals(String.withCString("VReduceMax"))
         || op.equals(String.withCString("VReduceMin"))) { emitVReduce(n); return true; }
        return false;
    }

    // The lane type a Vec(T) carries — the port spells a vector as Vec(lane),
    // so the lane is what pointeeOf's brace-matching would find.
    static String* laneOf(String* t)
    {
        if (!isVecTy(t)) return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') { if (depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4); depth = depth - (u32)1; }
            else if (c == (u8)',' && depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
        }
        return (String*)0;
    }

    // The lane-arrangement suffix for arithmetic on a vector of `lane`.
    static String* neonArr(String* lane)
    {
        u32 w = lane == (String*)0 ? (u32)4 : width(lane);
        if (w == (u32)1) return String.withCString("16b");
        if (w == (u32)2) return String.withCString("8h");
        if (w == (u32)8) return String.withCString("2d");
        return String.withCString("4s");
    }

    u32 vecIndex(IRValue* v)
    {
        Object* r = _vecReg.get((Hashable*)v);
        if (r == (Object*)0) return (u32)31;      // the allocator's backstop
        String* name = (String*)r;
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < name.byteLength(); i = i + (u32)1)
            n = n * (u32)10 + (u32)(name.byteAt(i) - (u8)'0');
        return n;
    }

    String* vecAddrOperand(IRInsn* n)
    {
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        if (p.kind() == (u8)OPK_USE && p.val() != (IRValue*)0
         && _foldInfo.get((Hashable*)p.val()) != (Object*)0)
            return foldedAddrOperand(n);
        String* o = String.withCString("[");
        o.append(operandReg(p, String.withCString("x16")));
        o.appendCString("]");
        return o;
    }

    void emitVLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        String* addr = vecAddrOperand(n);
        _out.appendFormat("    ldr q%lu, %s\n", vecIndex(n.res()), addr.cString());
    }

    void emitVStore(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        IROperand* v = (IROperand*)n.ops().get((u32)1);
        if (v.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        String* addr = vecAddrOperand(n);
        _out.appendFormat("    str q%lu, %s\n", vecIndex(v.val()), addr.cString());
    }

    void emitVSplat(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        String* arr = neonArr(laneOf(n.res().ty()));
        String* sc = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        _out.appendFormat("    dup v%lu.%s, %s\n", vecIndex(n.res()), arr.cString(), sc.cString());
    }

    void emitVBin(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        String* op = n.op();
        bool bitwise = op.equals(String.withCString("VAnd")) || op.equals(String.withCString("VOr"))
                    || op.equals(String.withCString("VXor"));
        String* lane = laneOf(n.res().ty());
        bool flt = isFloatTy(lane);
        // A bitwise op is lane-agnostic, so it always spells .16b.
        String* arr = bitwise ? String.withCString("16b") : neonArr(lane);
        String* mnem;
        if (op.equals(String.withCString("VAdd"))) mnem = String.withCString(flt ? "fadd" : "add");
        else if (op.equals(String.withCString("VSub"))) mnem = String.withCString(flt ? "fsub" : "sub");
        else if (op.equals(String.withCString("VMul"))) mnem = String.withCString(flt ? "fmul" : "mul");
        else if (op.equals(String.withCString("VAnd"))) mnem = String.withCString("and");
        else if (op.equals(String.withCString("VOr")))  mnem = String.withCString("orr");
        else mnem = String.withCString("eor");
        emitVec3(mnem, arr, vecIndex(n.res()), vecIndex(o0.val()), vecIndex(o1.val()));
    }

    void emitVec3(String* mnem, String* arr, u32 d, u32 a, u32 b)
    {
        _out.appendFormat("    %s v%lu.%s, v%lu.%s, v%lu.%s\n", mnem.cString(),
                          d, arr.cString(), a, arr.cString(), b, arr.cString());
    }

    void emitVMinMax(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        String* lane = laneOf(n.res().ty());
        bool sgn = isSignedTy(lane);
        String* mnem = n.op().equals(String.withCString("VMax"))
            ? String.withCString(sgn ? "smax" : "umax")
            : String.withCString(sgn ? "smin" : "umin");
        emitVec3(mnem, neonArr(lane), vecIndex(n.res()), vecIndex(o0.val()), vecIndex(o1.val()));
    }

    void emitVAddLP(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        String* inArr = neonArr(laneOf(o0.val().ty()));
        String* outArr = neonArr(laneOf(n.res().ty()));
        _out.appendFormat("    uaddlp v%lu.%s, v%lu.%s\n", vecIndex(n.res()), outArr.cString(),
                          vecIndex(o0.val()), inArr.cString());
    }

    void emitVICmp(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        if (o0.kind() != (u8)OPK_USE || o1.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        String* arr = neonArr(laneOf(n.res().ty()));
        // The `<` and `<=` forms reuse the `>` and `>=` instructions with the
        // operands swapped; NE is EQ with the mask inverted.
        String* p = n.pred();
        String* cm = (String*)0;
        bool swap = false;
        bool invert = false;
        if (p != (String*)0) {
            if (p.equals(String.withCString("UGT")))      cm = String.withCString("cmhi");
            else if (p.equals(String.withCString("UGE"))) cm = String.withCString("cmhs");
            else if (p.equals(String.withCString("ULT"))) { cm = String.withCString("cmhi"); swap = true; }
            else if (p.equals(String.withCString("ULE"))) { cm = String.withCString("cmhs"); swap = true; }
            else if (p.equals(String.withCString("SGT"))) cm = String.withCString("cmgt");
            else if (p.equals(String.withCString("SGE"))) cm = String.withCString("cmge");
            else if (p.equals(String.withCString("SLT"))) { cm = String.withCString("cmgt"); swap = true; }
            else if (p.equals(String.withCString("SLE"))) { cm = String.withCString("cmge"); swap = true; }
            else if (p.equals(String.withCString("EQ")))  cm = String.withCString("cmeq");
            else if (p.equals(String.withCString("NE")))  { cm = String.withCString("cmeq"); invert = true; }
        }
        if (cm == (String*)0) { unsupported(String.withCString("VICmp:pred")); return; }
        u32 a = vecIndex(o0.val());
        u32 b = vecIndex(o1.val());
        u32 d = vecIndex(n.res());
        emitVec3(cm, arr, d, swap ? b : a, swap ? a : b);
        if (invert) _out.appendFormat("    not v%lu.16b, v%lu.16b\n", d, d);
    }

    // A horizontal reduction. Only i32/u32 lanes reach here — the reduction
    // vectoriser produces nothing else, and addv has no .2d form — so the .4s
    // spelling is right by construction. The fold lands in the low s-element of
    // the same register, and fmov moves it across to the GP result.
    void emitVReduce(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE) { unsupported(n.op()); return; }
        bool sgn = isSignedTy(n.res().ty());
        String* op = n.op();
        String* mnem;
        if (op.equals(String.withCString("VReduceAdd")))      mnem = String.withCString("addv");
        else if (op.equals(String.withCString("VReduceMax"))) mnem = String.withCString(sgn ? "smaxv" : "umaxv");
        else                                                  mnem = String.withCString(sgn ? "sminv" : "uminv");
        u32 v = vecIndex(o0.val());
        _out.appendFormat("    %s s%lu, v%lu.4s\n", mnem.cString(), v, v);
        String* d = resultReg(n.res(), String.withCString("w16"));
        _out.appendFormat("    fmov %s, s%lu\n", d.cString(), v);
        storeReg(d, n.res());
    }

    // Assign v18..v31 by linear scan with reuse. The pool is DISJOINT from the
    // FP allocator's homes (d8-d15) and its d0-d7/d16-d17 scratch, so a
    // function mixing float scalars with an integer reduction cannot alias.
    void allocateVectorRegisters(IRFunc* fn)
    {
        _vecReg = new Map();
        _vecClass = new Map();
        Array* vecVals = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            collectVecs(vecVals, bb.phis());
            collectVecs(vecVals, bb.insns());
        }
        if (vecVals.count() == (u32)0) return;

        // Coalesce: a vector phi's incoming values join the phi result's class,
        // so the reduction accumulator is updated in place and the back edge
        // needs no copy.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0 || !isVecTy(p.res().ty())) continue;
                for (u32 k = (u32)0; k < p.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)p.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        _vecClass.set((Hashable*)o.val(), (Object*)p.res());
                }
            }
        }

        // A class's interval is [min, max] over the linear positions at which
        // any member is defined or read.
        Array* classes = new Array();
        Map* lo = new Map();
        Map* hi = new Map();
        Array* blkStart = new Array();
        Array* blkEnd = new Array();
        i32 pos = (i32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            blkStart.add((Object*)Number.withI32(pos));
            pos = touchList(bb.phis(), vecVals, classes, lo, hi, pos);
            pos = touchList(bb.insns(), vecVals, classes, lo, hi, pos);
            if (bb.term() != (IRInsn*)0)
                pos = touchInsn(bb.term(), vecVals, classes, lo, hi, pos);
            blkEnd.add((Object*)Number.withI32(pos > (i32)0 ? pos - (i32)1 : (i32)0));
        }

        // Back-edge-aware extension. A loop-INVARIANT vector materialised once
        // before the loop — a preheader dup of an invariant scalar — is read on
        // every iteration and must stay live across the back edge; the plain
        // [min, max] scan ends it at its last TEXTUAL use, after which a later
        // in-loop op takes its register and corrupts the splat next time round.
        // This only ever lengthens intervals, so it cannot introduce a clobber.
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1) {
            IRInsn* t = ((IRBlock*)fn.blocks().get(bi)).term();
            if (t == (IRInsn*)0) continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1) {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                i32 tgt = blockIndexOf(fn, o.blk());
                if (tgt < (i32)0 || (u32)tgt > bi) continue;      // a forward edge
                i32 loopStart = ((Number*)blkStart.get((u32)tgt)).asI32();
                i32 loopEnd = ((Number*)blkEnd.get(bi)).asI32();
                for (u32 c = (u32)0; c < classes.count(); c = c + (u32)1) {
                    IRValue* cls = (IRValue*)classes.get(c);
                    i32 l = ((Number*)lo.get((Hashable*)cls)).asI32();
                    i32 h = ((Number*)hi.get((Hashable*)cls)).asI32();
                    if (l < loopStart && h >= loopStart && h <= loopEnd)
                        hi.set((Hashable*)cls, (Object*)Number.withI32(loopEnd));
                }
            }
        }

        // Linear scan. Classes in order of interval start — which is total,
        // since no two values are defined at the same position.
        sortByStart(classes, lo);
        Array* freePool = new Array();
        for (u32 r = (u32)18; r <= (u32)31; r = r + (u32)1)
            freePool.add((Object*)Number.with((i32)r));
        Array* active = new Array();
        Map* regOf = new Map();
        for (u32 c = (u32)0; c < classes.count(); c = c + (u32)1) {
            IRValue* cls = (IRValue*)classes.get(c);
            i32 start = ((Number*)lo.get((Hashable*)cls)).asI32();
            Array* still = new Array();
            for (u32 a = (u32)0; a < active.count(); a = a + (u32)1) {
                IRValue* av = (IRValue*)active.get(a);
                if (((Number*)hi.get((Hashable*)av)).asI32() < start)
                    freePool.add((Object*)regOf.get((Hashable*)av));
                else still.add((Object*)av);
            }
            active = still;
            // Exhaustion is a HARD error: the old v31 backstop silently reused
            // a live register, which is a miscompile (#1198).
            if (freePool.count() == (u32)0) {
                Stdio.printf("xcc-cg-arm64: error: vector register pressure "
                             "exceeded the 14-register pool (v18-v31) in '%s'\n",
                             fn.name().cString());
                Process.exit((i32)1);
            }
            Object* reg = (Object*)freePool.get(freePool.count() - (u32)1);
            freePool.removeAt(freePool.count() - (u32)1);
            regOf.set((Hashable*)cls, reg);
            active.add((Object*)cls);
            sortByEnd(active, hi);
        }
        for (u32 i = (u32)0; i < vecVals.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)vecVals.get(i);
            Object* r = regOf.get((Hashable*)classOfVec(v));
            if (r == (Object*)0) continue;
            String* name = String.withCString("v");
            name.appendFormat("%ld", ((Number*)r).asI32());
            _vecReg.set((Hashable*)v, (Object*)name);
        }
    }

    IRValue* classOfVec(IRValue* v)
    {
        Object* c = _vecClass.get((Hashable*)v);
        return c == (Object*)0 ? v : (IRValue*)c;
    }

    static void collectVecs(Array* into, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1) {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() != (IRValue*)0 && isVecTy(n.res().ty()) && !hasVal(into, n.res()))
                into.add((Object*)n.res());
        }
    }

    i32 touchList(Array* list, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            pos = touchInsn((IRInsn*)list.get(i), vecVals, classes, lo, hi, pos);
        return pos;
    }

    i32 touchInsn(IRInsn* n, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
    {
        if (n.res() != (IRValue*)0) touchVec(n.res(), vecVals, classes, lo, hi, pos);
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                touchVec(o.val(), vecVals, classes, lo, hi, pos);
        }
        return pos + (i32)1;
    }

    void touchVec(IRValue* v, Array* vecVals, Array* classes, Map* lo, Map* hi, i32 pos)
    {
        if (!hasVal(vecVals, v)) return;
        IRValue* cls = classOfVec(v);
        Object* l = lo.get((Hashable*)cls);
        if (l == (Object*)0) {
            classes.add((Object*)cls);
            lo.set((Hashable*)cls, (Object*)Number.withI32(pos));
            hi.set((Hashable*)cls, (Object*)Number.withI32(pos));
            return;
        }
        if (pos < ((Number*)l).asI32()) lo.set((Hashable*)cls, (Object*)Number.withI32(pos));
        if (pos > ((Number*)hi.get((Hashable*)cls)).asI32())
            hi.set((Hashable*)cls, (Object*)Number.withI32(pos));
    }

    static void sortByStart(Array* a, Map* key) { sortByKey(a, key); }
    static void sortByEnd(Array* a, Map* key)   { sortByKey(a, key); }

    // Insertion sort on the interval endpoint. Stable, and the arrays here are
    // a handful of entries.
    static void sortByKey(Array* a, Map* key)
    {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1) {
            Object* cur = a.get(i);
            i32 ck = ((Number*)key.get((Hashable*)(IRValue*)cur)).asI32();
            u32 j = i;
            while (j > (u32)0
                && ((Number*)key.get((Hashable*)(IRValue*)a.get(j - (u32)1))).asI32() > ck) {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
            }
            a.set(j, cur);
        }
    }

    // ── Floating point ───────────────────────────────────────────────────
    //
    // This target is natively IEEE, so a float op is one instruction. s0/s1
    // (d0/d1 for a double) are the FP scratch pair.
    static String* fregName(u32 n, String* ty)
    {
        String* o = String.withCString(
            ty != (String*)0 && ty.equals(String.withCString("F64")) ? "d" : "s");
        o.appendFormat("%lu", n);
        return o;
    }

    void emitFBin(IRInsn* n, String* mnem)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        String* ty = n.res().ty();
        String* a = operandReg((IROperand*)n.ops().get((u32)0), fregName((u32)0, ty));
        String* b = operandReg((IROperand*)n.ops().get((u32)1), fregName((u32)1, ty));
        String* d = resultReg(n.res(), fregName((u32)0, ty));
        _out.appendFormat("    %s %s, %s, %s\n", mnem.cString(), d.cString(),
                          a.cString(), b.cString());
        storeReg(d, n.res());
    }

    void emitFUnary(IRInsn* n, String* mnem)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        String* ty = n.res().ty();
        String* a = operandReg((IROperand*)n.ops().get((u32)0), fregName((u32)0, ty));
        String* d = resultReg(n.res(), fregName((u32)0, ty));
        _out.appendFormat("    %s %s, %s\n", mnem.cString(), d.cString(), a.cString());
        storeReg(d, n.res());
    }

    void emitFCmp(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        String* at = opType((IROperand*)n.ops().get((u32)0));
        String* a = operandReg((IROperand*)n.ops().get((u32)0), fregName((u32)0, at));
        String* b = operandReg((IROperand*)n.ops().get((u32)1), fregName((u32)1, at));
        _out.appendFormat("    fcmp %s, %s\n", a.cString(), b.cString());
        String* d = resultReg(n.res(), String.withCString("w16"));
        _out.appendFormat("    cset %s, %s\n", d.cString(), fcmpCond(n.pred()).cString());
        storeReg(d, n.res());
    }

    // The AArch64 condition for an ordered float compare. OLT is `mi` and OLE
    // is `ls`, not `lt`/`le`: the unordered case must not compare less-than.
    static String* fcmpCond(String* p)
    {
        if (p == (String*)0) return String.withCString("eq");
        if (p.equals(String.withCString("OEQ"))) return String.withCString("eq");
        if (p.equals(String.withCString("ONE"))) return String.withCString("ne");
        if (p.equals(String.withCString("OLT"))) return String.withCString("mi");
        if (p.equals(String.withCString("OGT"))) return String.withCString("gt");
        if (p.equals(String.withCString("OLE"))) return String.withCString("ls");
        if (p.equals(String.withCString("OGE"))) return String.withCString("ge");
        return String.withCString("eq");
    }

    void emitIntToFp(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        String* a = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        String* d = resultReg(n.res(), fregName((u32)0, n.res().ty()));
        _out.appendFormat("    %s %s, %s\n",
                          n.op().equals(String.withCString("SIToFp")) ? "scvtf" : "ucvtf",
                          d.cString(), a.cString());
        storeReg(d, n.res());
    }

    // Float to integer. The spec says an out-of-range conversion produces 0
    // (§3.1, and xt6502 does), whereas fcvtz* alone saturates to INT_MAX/MIN.
    // So convert to 64 bits, re-extend the low bits at the destination width,
    // and compare: equal means it fitted.
    void emitFpToInt(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        String* at = opType((IROperand*)n.ops().get((u32)0));
        String* src = operandReg((IROperand*)n.ops().get((u32)0), fregName((u32)0, at));
        bool sgn = n.op().equals(String.withCString("FpToSI"));
        _out.appendFormat("    %s x16, %s\n", sgn ? "fcvtzs" : "fcvtzu", src.cString());
        u32 w = width(n.res().ty());
        // The re-extend-and-compare fit check only applies to a destination
        // NARROWER than the 64-bit fcvtz result. For a 64-bit destination the
        // fcvtz value IS the result; the old `else` branch re-extended the low
        // 32 BITS, so every value above 2^32 was csel'd to 0 (bug 173).
        if (w < (u32)8) {
            String* ext;
            if (sgn) ext = String.withCString(w == (u32)1 ? "sxtb x17, w16"
                                            : w == (u32)2 ? "sxth x17, w16" : "sxtw x17, w16");
            else     ext = String.withCString(w == (u32)1 ? "uxtb w17, w16"
                                            : w == (u32)2 ? "uxth w17, w16" : "mov w17, w16");
            _out.appendFormat("    %s\n", ext.cString());
            _out.appendCString("    cmp x16, x17\n");
            _out.appendCString("    csel x16, x16, xzr, eq\n");
        }
        // A 64-bit result must be STORED from x16 — w16 wrote only the low 32
        // bits, the other half of bug 173.
        String* outReg = (w >= (u32)8) ? String.withCString("x16")
                                       : String.withCString("w16");
        canonicalise(outReg, n.res().ty());
        storeReg(outReg, n.res());
    }

    void emitFpConvert(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        String* at = opType((IROperand*)n.ops().get((u32)0));
        String* src = operandReg((IROperand*)n.ops().get((u32)0), fregName((u32)0, at));
        String* d = resultReg(n.res(), fregName((u32)1, n.res().ty()));
        _out.appendFormat("    fcvt %s, %s\n", d.cString(), src.cString());
        storeReg(d, n.res());
    }

    // ── Aggregates ───────────────────────────────────────────────────────
    //
    // A struct value always lives in a frame slot — it is never homed — so
    // building one is a run of stores and reading a field is one load.
    void emitAggBuild(IRInsn* n)
    {
        if (n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IRLayout* l = layoutOf(n.res().ty());
        if (l == (IRLayout*)0) { unsupported(String.withCString("AggBuild:layout")); return; }
        u32 base = slotOf(n.res());
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* f = (IROperand*)n.ops().get(i);
            String* fty = f.kind() == (u8)OPK_USE && f.val() != (IRValue*)0
                        ? f.val().ty() : f.ty();
            u32 fw = fty == (String*)0 ? (u32)8 : fieldWidth(fty);
            String* reg = String.withCString("w17");
            String* st = String.withCString("str");
            if (isPtrTy(fty) || fw >= (u32)8) reg = String.withCString("x17");
            else if (fw >= (u32)4) { }
            else if (fw == (u32)2) st = String.withCString("strh");
            else st = String.withCString("strb");
            materialise(f, reg);
            u32 fo = fieldOffset(l, i);
            emitSpAddr(base, String.withCString("x16"));
            // A field past #4095 in a >4KB aggregate overflows the narrow
            // store immediates (finding #13's family) — fold it into x16.
            if (fo > (u32)4095) { emitAddImm(String.withCString("x16"), String.withCString("x16"), fo); fo = (u32)0; }
            _out.appendFormat("    %s %s, [x16, #%lu]\n", st.cString(), reg.cString(), fo);
        }
    }

    void emitAggExtract(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        if (src.kind() != (u8)OPK_USE || src.val() == (IRValue*)0)
            { unsupported(String.withCString("AggExtract:src")); return; }
        IRLayout* l = layoutOf(src.val().ty());
        if (l == (IRLayout*)0) { unsupported(String.withCString("AggExtract:layout")); return; }
        u32 idx = (u32)((IROperand*)n.ops().get((u32)1)).imm();
        String* rty = n.res().ty();
        u32 fw = rty == (String*)0 ? (u32)8 : fieldWidth(rty);
        bool sgn = isSignedTy(rty);
        String* reg = String.withCString("w17");
        String* ld = String.withCString("ldr");
        if (isPtrTy(rty) || fw >= (u32)8) reg = String.withCString("x17");
        else if (fw >= (u32)4) { }
        else if (fw == (u32)2) ld = String.withCString(sgn ? "ldrsh" : "ldrh");
        else ld = String.withCString(sgn ? "ldrsb" : "ldrb");
        u32 fo = fieldOffset(l, idx);
        emitSpAddr(slotOf(src.val()), String.withCString("x16"));
        // A field past #4095 in a >4KB aggregate overflows the narrow
        // load immediates (finding #13's family) — fold it into x16.
        if (fo > (u32)4095) { emitAddImm(String.withCString("x16"), String.withCString("x16"), fo); fo = (u32)0; }
        _out.appendFormat("    %s %s, [x16, #%lu]\n", ld.cString(), reg.cString(), fo);
        storeReg(reg, n.res());
    }

    // Copy `sz` bytes between the frame slot at `slot` and the address in x16,
    // in 8/4/2/1-byte chunks. A single ldr would drop every byte past the
    // first eight — a 12-byte struct came back with only its first two fields.
    void emitAggCopy(u32 sz, u32 slot, bool toFrame)
    {
        _aggFb = String.withCString("sp");
        _aggFbias = slot;
        if (slot + sz > (u32)4095) {          // past the strb/strh immediate
            emitSpAddr(slot, String.withCString("x15"));
            _aggFb = String.withCString("x15");
            _aggFbias = (u32)0;
        }
        // The tail (<8-byte chunks) of a >4KB aggregate can sit past the
        // narrow load/store immediates (strb tops out at #4095 — finding
        // #13's family); aggChunk rebases BOTH pointers once at the first
        // such chunk and _aggReb is subtracted from every later offset.
        _aggReb = (u32)0;
        u32 off = (u32)0;
        off = aggChunk(sz, off, (u32)8, String.withCString("ldr"), String.withCString("str"),
                       String.withCString("x17"), slot, toFrame);
        off = aggChunk(sz, off, (u32)4, String.withCString("ldr"), String.withCString("str"),
                       String.withCString("w17"), slot, toFrame);
        off = aggChunk(sz, off, (u32)2, String.withCString("ldrh"), String.withCString("strh"),
                       String.withCString("w17"), slot, toFrame);
        off = aggChunk(sz, off, (u32)1, String.withCString("ldrb"), String.withCString("strb"),
                       String.withCString("w17"), slot, toFrame);
    }

    u32 aggChunk(u32 sz, u32 off, u32 w, String* ld, String* st, String* reg,
                 u32 slot, bool toFrame)
    {
        while (sz - off >= w) {
            if (w < (u32)8 && _aggReb == (u32)0 && off > (u32)4095) {
                emitAddImm(String.withCString("x16"), String.withCString("x16"), off);
                emitSpAddr(slot + off, String.withCString("x15"));
                _aggFb = String.withCString("x15");
                _aggFbias = (u32)0;
                _aggReb = off;
            }
            if (toFrame) {
                _out.appendFormat("    %s %s, [x16, #%lu]\n", ld.cString(), reg.cString(),
                                  off - _aggReb);
                _out.appendFormat("    %s %s, [%s, #%lu]\n", st.cString(), reg.cString(),
                                  _aggFb.cString(), _aggFbias + off - _aggReb);
            } else {
                _out.appendFormat("    %s %s, [%s, #%lu]\n", ld.cString(), reg.cString(),
                                  _aggFb.cString(), _aggFbias + off - _aggReb);
                _out.appendFormat("    %s %s, [x16, #%lu]\n", st.cString(), reg.cString(),
                                  off - _aggReb);
            }
            off = off + w;
        }
        return off;
    }

    // A homogeneous float aggregate — up to four members of ONE float type,
    // counting through nesting. AAPCS passes and returns one in consecutive
    // v-registers rather than through memory. Zero when it is not an HFA; the
    // element kind comes back in `outIsDouble`.
    u32 aggHFA(IRLayout* l, bool* outIsDouble)
    {
        if (l == (IRLayout*)0 || l.fieldCount() == (u32)0) return (u32)0;
        String* ek = (String*)0;
        u32 count = (u32)0;
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1) {
            String* ft = l.typeAt(i);
            String* leaf = (String*)0;
            u32 nleaf = (u32)0;
            if (isAggTy(ft)) {
                bool inner = false;
                nleaf = aggHFA(layoutOf(ft), &inner);
                if (nleaf == (u32)0) return (u32)0;      // a nested non-HFA
                leaf = String.withCString(inner ? "F64" : "F32");
            } else if (isFloatTy(ft)) {
                leaf = ft;
                nleaf = (u32)1;
            } else {
                return (u32)0;                            // a non-float leaf
            }
            if (ek == (String*)0) ek = leaf;
            else if (!ek.equals(leaf)) return (u32)0;     // mixed float and double
            count = count + nleaf;
            if (count > (u32)4) return (u32)0;
        }
        if (count == (u32)0 || count > (u32)4) return (u32)0;
        // Trailing padding would break the register mapping, so the element
        // count has to account for the whole aggregate.
        bool dbl = ek.equals(String.withCString("F64"));
        if (aggSize(l) != count * (dbl ? (u32)8 : (u32)4)) return (u32)0;
        *outIsDouble = dbl;
        return count;
    }

    // The number of consecutive 64-bit GP registers a non-HFA aggregate
    // argument occupies — one per 8 bytes. The caller marshal and the callee
    // spill both read this, so a <=16-byte struct rides x{n}..x{n+1} on both
    // sides.
    u32 gpRegsForAgg(String* t) { return (aggSize(layoutOf(t)) + (u32)7) / (u32)8; }

    // ── Calls ────────────────────────────────────────────────────────────
    //
    // AAPCS64: integer and pointer arguments fill x0..x7, float and double
    // arguments the INDEPENDENT v0..v7 bank, and anything past those goes in
    // the outgoing-argument area at the bottom of the frame.
    // ── Native AAPCS va_list (bug 179) ──────────────────────────────────
    // Bytes the FIXED params spilled to the incoming stack (usually 0 — a few
    // fixed args ride x0-x7 / v0-v7). Lays the fixed param types through the
    // same slot rule the caller marshalled with, so the two cannot disagree.
    u32 fixedParamStackBytes(void)
    {
        u32 nn = _fn.params().count();
        u32 user = nn;
        if (nn > (u32)0 && isMemTy(((IRValue*)_fn.params().get(nn - (u32)1)).ty()))
            user = nn - (u32)1;
        Array* types = new Array();
        for (u32 i = (u32)0; i < user; i = i + (u32)1)
            types.add((Object*)((IRValue*)_fn.params().get(i)).ty());
        offsetsForTypes(types, (u32)0, (i32)-1);
        return _lastOutStack;
    }

    // ap = the FIRST incoming variadic stack arg. Under Darwin's rule every
    // variadic arg is on the stack, above this callee's frame: at sp + frame +
    // fixed-param-stack-bytes. Store ap into the cursor slot (operand 0).
    void emitVaStart(IRInsn* n)
    {
        if (n.ops().count() < (u32)1) return;
        emitSpAddr(_frame + fixedParamStackBytes(), String.withCString("x17"));
        emitDerefAddr((IROperand*)n.ops().get((u32)0));      // x16 = &cursor
        _out.appendCString("    str x17, [x16]\n");
    }

    // Read the next AAPCS arg from the va_list and advance the cursor one 8-byte
    // slot (a struct rides its 8-rounded size, inline). cVarargPromote widened
    // narrow ints to i32 and f32 to f64, so a float result reads the double back.
    void emitVaArg(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        emitDerefAddr((IROperand*)n.ops().get((u32)0));      // x16 = &cursor
        _out.appendCString("    ldr x17, [x16]\n");
        String* rt = n.res().ty();
        if (isPtrTy(rt) && isAggTy(pointeeOf(rt))) {
            u32 sz  = aggSize(layoutOf(pointeeOf(rt)));
            u32 adv = (sz + (u32)7) & ~(u32)7; if (adv == (u32)0) adv = (u32)8;
            _out.appendFormat("    add x9, x17, #%lu\n    str x9, [x16]\n", adv);
            storeReg(String.withCString("x17"), n.res());
            return;
        }
        _out.appendCString("    add x9, x17, #8\n    str x9, [x16]\n");
        if (rt.equals(String.withCString("F32"))) {
            _out.appendCString("    ldr d0, [x17]\n    fcvt s0, d0\n    fmov w16, s0\n");
            storeReg(String.withCString("w16"), n.res());
            return;
        }
        bool x = isPtrTy(rt) || width(rt) >= (u32)8;
        String* dst = String.withCString(x ? "x16" : "w16");
        _out.appendFormat("    ldr %s, [x17]\n", dst.cString());
        canonicalise(dst, rt);
        storeReg(dst, n.res());
    }

    // YES if this is a DIRECT call, inside a `vaforward` function, to a variadic
    // callee — a `void say(fmt,...) { fmt2(fmt,...); }` forward that re-passes
    // this function's own incoming tail (with no shared buffer, by copying it).
    bool vaForwardRelay(IRInsn* n)
    {
        if (!n.op().equals(String.withCString("Call")) || n.ops().count() < (u32)2) return false;
        IRSymbol* own = symbolNamed(_fn.name());
        if (own == (IRSymbol*)0 || !own.vaforward()) return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM) return false;
        IRSymbol* cs = symbolNamed(callee.name());
        return cs != (IRSymbol*)0 && cs.variadic();
    }

    void emitCall(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM) { unsupported(String.withCString("Call:indirect")); return; }
        if (!marshalArgs(n, (u32)1, n.ops().count() - (u32)2, (u32)0)) return;
        // Vararg forward relay (bug 179): copy a bounded window of this
        // function's incoming tail into the outgoing slots past the explicit
        // args. tailBase is what marshalArgs just left in _lastOutStack; read it
        // BEFORE fixedParamStackBytes recomputes _lastOutStack.
        if (vaForwardRelay(n)) {
            u32 tailBase = _lastOutStack;
            u32 inVa = _frame + fixedParamStackBytes();
            _out.appendFormat("    // vararg forward: relay 16 words #%lu -> #%lu\n", inVa, tailBase);
            for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
                _out.appendFormat("    ldr x9, [sp, #%lu]\n    str x9, [sp, #%lu]\n",
                                  inVa + i * (u32)8, tailBase + i * (u32)8);
        }
        bool sret = emitSretSetupIfNeeded(n);
        _out.appendFormat("    bl _%s\n", callee.name().cString());
        captureResult(n, sret);
    }

    bool marshalAggArg(IRValue* v, String* aty, u32* gp, u32* fp)
    {
        IRLayout* l = layoutOf(aty);
        bool dbl = false;
        u32 hfa = aggHFA(l, &dbl);
        if (hfa > (u32)0) {
            if (*fp + hfa > (u32)8) return false;
            for (u32 k = (u32)0; k < hfa; k = k + (u32)1) {
                String* r = String.withCString(dbl ? "d" : "s");
                r.appendFormat("%lu", *fp + k);
                loadSlotOffset(v, (dbl ? (u32)8 : (u32)4) * k, r);
            }
            *fp = *fp + hfa;
            return true;
        }
        u32 nregs = gpRegsForAgg(aty);
        if (*gp + nregs > (u32)8) { unsupported(String.withCString("Call:AggArgStack")); return false; }
        for (u32 k = (u32)0; k < nregs; k = k + (u32)1) {
            String* r = String.withCString("x");
            r.appendFormat("%lu", *gp + k);
            loadSlotOffset(v, (u32)8 * k, r);
        }
        *gp = *gp + nregs;
        return true;
    }

    // An aggregate is never homed, so a word of it is always a slot read.
    void loadSlotOffset(IRValue* v, u32 off, String* reg)
    { _out.appendFormat("    ldr %s, %s\n", reg.cString(), spMemForOff(slotOf(v) + off, reg).cString()); }

    void storeSlotOffset(IRValue* v, u32 off, String* reg)
    { _out.appendFormat("    str %s, %s\n", reg.cString(), spMemForOff(slotOf(v) + off, reg).cString()); }

    // A >16-byte NON-float aggregate return is written by the callee through a
    // hidden pointer the caller passes in x8, not returned in x0:x1. An HFA
    // (NSRect, four doubles) comes back in v0..v3 even though it is larger, so
    // it does NOT use the indirect result.
    bool emitSretSetupIfNeeded(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || !isAggTy(n.res().ty())) return false;
        IRLayout* l = layoutOf(n.res().ty());
        bool dbl = false;
        if (aggHFA(l, &dbl) > (u32)0) return false;
        if (aggSize(l) <= (u32)16) return false;
        emitSpAddr(slotOf(n.res()), String.withCString("x8"));
        return true;
    }

    void captureAggResult(IRInsn* n, bool sretUsed)
    {
        IRLayout* l = layoutOf(n.res().ty());
        bool dbl = false;
        u32 hfa = aggHFA(l, &dbl);
        if (hfa > (u32)0) {
            for (u32 k = (u32)0; k < hfa; k = k + (u32)1) {
                String* r = String.withCString(dbl ? "d" : "s");
                r.appendFormat("%lu", k);
                storeSlotOffset(n.res(), (dbl ? (u32)8 : (u32)4) * k, r);
            }
            return;
        }
        if (sretUsed) return;        // the callee already filled the slot via x8
        u32 sz = aggSize(l);
        emitSpAddr(slotOf(n.res()), String.withCString("x16"));
        _out.appendCString("    str x0, [x16]\n");
        if (sz > (u32)8) _out.appendCString("    str x1, [x16, #8]\n");
    }

    // The type an argument operand passes as.
    static String* argType(IROperand* a)
    {
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0) return (String*)0;
        return a.val().ty();
    }

    // Where each argument goes: −1 for a register, else its byte offset in the
    // outgoing-argument area. Null when an argument shape is not ported yet.
    Array* argStackOffsets(IRInsn* n, u32 first, u32 argc, u32 startGP)
    {
        Array* types = new Array();
        for (u32 i = (u32)0; i < argc; i = i + (u32)1) {
            String* t = argType((IROperand*)n.ops().get(first + i));
            types.add(t == (String*)0 ? (Object*)String.withCString("") : (Object*)t);
        }
        // A direct call to a variadic C-ABI symbol puts its ENTIRE tail on
        // the stack in 8-byte slots (Darwin's AAPCS deviation) — however many
        // registers remain. The fixed count is the declared parameter list;
        // its signature carries a trailing Mem. Because every call-shaped
        // opcode reaches offsetsForTypes through HERE, the frame sizing and
        // the marshalling cannot disagree. Mirrors the original.
        i32 vfrom = (i32)-1;
        if (n.op().equals(String.withCString("Call")) && first == (u32)1) {
            IROperand* callee = (IROperand*)n.ops().get((u32)0);
            if (callee.kind() == (u8)OPK_SYM) {
                IRSymbol* s = symbolNamed(callee.name());
                if (s != 0 && s.variadic()) {
                    // The PRINTED signature carries no trailing Mem (unlike
                    // the original's in-memory paramTypes) — the count IS the
                    // fixed count. Every variadic call (not just a C import)
                    // places its tail on the stack under the native va_list ABI
                    // (bug 179), so an xc variadic is marked too.
                    // Under plain AAPCS64 a variadic argument is placed
                    // exactly like a named one, so there is no tail to mark
                    // and the ordinary path below is already right.
                    i32 fixed = sigParamCount(s.signature());
                    if (fixed >= (i32)0 && !_aapcs64Abi) vfrom = fixed;
                }
            }
        }
        return offsetsForTypes(types, startGP, vfrom);
    }

    // Top-level parameter count of a `(A, B, Mem) -> …` signature — depth-
    // aware, so a nested `Ptr(U8, unbanked)` keeps its inner comma.
    i32 sigParamCount(String* sig)
    {
        if (sig == 0 || sig.byteLength() < (u32)2) return (i32)0;
        u32 depth = (u32)0;
        i32 count = (i32)0;
        bool any = false;
        for (u32 i = (u32)1; i < sig.byteLength(); i = i + (u32)1) {
            u8 c = sig.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') {
                if (depth == (u32)0) { if (any) count = count + (i32)1; return count; }
                depth = depth - (u32)1;
            }
            else if (c == (u8)',' && depth == (u32)0) count = count + (i32)1;
            else if (c != (u8)' ') any = true;
        }
        return count;
    }

    // The same classifier the CALLEE spills with, so a stack-passed argument
    // lands where the caller wrote it.
    Array* offsetsForTypes(Array* types, u32 startGP)
    {
        return offsetsForTypes(types, startGP, (i32)-1);
    }

    Array* offsetsForTypes(Array* types, u32 startGP, i32 vfrom)
    {
        Array* offs = new Array();
        u32 gp = startGP;
        u32 fp = (u32)0;
        u32 stk = (u32)0;
        for (u32 i = (u32)0; i < types.count(); i = i + (u32)1) {
            if (vfrom >= (i32)0 && (i32)i >= vfrom) {
                stk = (stk + (u32)7) & ~(u32)7;            // 8-byte slots
                offs.add((Object*)Number.with((i32)stk));
                stk = stk + (u32)8;
                continue;
            }
            String* t = (String*)types.get(i);
            if (t.byteLength() == (u32)0) t = (String*)0;
            if (isAggTy(t)) {
                bool dbl = false;
                u32 hfa = aggHFA(layoutOf(t), &dbl);
                bool fits = false;
                if (hfa > (u32)0) { fits = (fp + hfa <= (u32)8); if (fits) fp = fp + hfa; }
                else { u32 nr = gpRegsForAgg(t); fits = (gp + nr <= (u32)8); if (fits) gp = gp + nr; }
                if (fits) { offs.add((Object*)Number.with(-1)); continue; }
                // Overflow: once an aggregate does not fit the remaining
                // registers it is passed ENTIRELY on the stack (AAPCS C.13),
                // 8-aligned at its natural size, and the register bank is then
                // closed so no later arg backfills the gap (bug 20/21).
                if (hfa > (u32)0) fp = (u32)8; else gp = (u32)8;
                u32 asz = (aggSize(layoutOf(t)) + (u32)7) & ~(u32)7;
                stk = (stk + (u32)7) & ~(u32)7;
                offs.add((Object*)Number.with((i32)stk));
                stk = stk + asz;
                continue;
            }
            if (isFloatTy(t)) {
                if (fp < (u32)8) { fp = fp + (u32)1; offs.add((Object*)Number.with(-1)); continue; }
                u32 sz = t.equals(String.withCString("F64")) ? (u32)8 : (u32)4;
                if (_aapcs64Abi) sz = (u32)8;
                stk = (stk + sz - (u32)1) & ~(sz - (u32)1);
                offs.add((Object*)Number.with((i32)stk));
                stk = stk + sz;
                continue;
            }
            if (gp < (u32)8) { gp = gp + (u32)1; offs.add((Object*)Number.with(-1)); continue; }
            u32 sz = fieldWidth(t);
            if (sz == (u32)0) sz = (u32)4;
            // Darwin packs an overflow argument to its natural size; AAPCS64
            // rounds every one up to 8 and aligns it to 8. Both the caller's
            // marshalling and the callee's parameter reads come through here,
            // so they cannot disagree about which rule is in force.
            if (_aapcs64Abi) sz = (u32)8;
            stk = (stk + sz - (u32)1) & ~(sz - (u32)1);
            offs.add((Object*)Number.with((i32)stk));
            stk = stk + sz;
        }
        _lastOutStack = (stk + (u32)15) & ~(u32)15;
        return offs;
    }

    u32 _lastOutStack;

    // The outgoing-argument bytes one instruction needs. Every call-shaped
    // opcode has to be counted here AND marshalled the same way, or the frame
    // is sized for one convention and written with another.
    u32 outStackBytesFor(IRInsn* n)
    {
        u32 first = (u32)0;
        u32 argc = (u32)0;
        u32 startGP = (u32)0;
        String* op = n.op();
        if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked"))
         || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("CallIndirect"))) {
            if (n.ops().count() < (u32)2) return (u32)0;
            first = (u32)1; argc = n.ops().count() - (u32)2;
        } else if (op.equals(String.withCString("VTblDispatch"))) {
            if (n.ops().count() < (u32)3) return (u32)0;
            first = (u32)2; argc = n.ops().count() - (u32)3; startGP = (u32)1;  // receiver in x0
        } else {
            return (u32)0;
        }
        _lastOutStack = (u32)0;
        Array* ignored = argStackOffsets(n, first, argc, startGP);
        u32 base = ignored == (Array*)0 ? (u32)0 : _lastOutStack;
        // A forwarding call re-passes 128 bytes of the incoming tail into the
        // outgoing slots past the explicit args, so the frame must reserve them.
        if (vaForwardRelay(n)) base = base + (u32)16 * (u32)8;
        return base;
    }


    // ── Asm-text peepholes ───────────────────────────────────────────────
    //
    // These run over the generated text rather than the IR, because what they
    // clean up only exists once registers have been chosen: spill round trips,
    // staging moves into scratch, and the block walker's unconditional
    // "branch to the next block".

    static Array* linesOf(String* text) { return text.splitOnByte((u8)'\n'); }

    static String* joinLines(Array* lines)
    {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            if (i > (u32)0) o.appendCString("\n");
            o.append((String*)lines.get(i));
        }
        return o;
    }

    // Parse `<mnem> <reg>, [sp, #<off>]` (or a bare `[sp]`). The offset comes
    // back as its TEXT, which is all the comparisons need. Returns false when
    // the line is not a frame access.
    static bool parseSpLine(String* line, String** mnem, String** reg, String** off)
    {
        String* t = line.trimmed();
        u32 sp = t.byteIndexOf(String.withCString(", [sp"));
        if (sp == (u32)$FFFF_FFFF) return false;
        String* head = t.substringBytes((u32)0, sp);
        u32 spc = head.indexOfByte((u8)' ');
        if (spc == (u32)$FFFF_FFFF) return false;
        *mnem = head.substringBytes((u32)0, spc);
        *reg = head.substringFromByte(spc + (u32)1).trimmed();
        String* tail = t.substringFromByte(sp);
        u32 hash = tail.indexOfByte((u8)'#');
        if (hash == (u32)$FFFF_FFFF) {
            if (tail.hasSuffix(String.withCString("[sp]"))) { *off = String.withCString("0"); return true; }
            return false;
        }
        u32 close = tail.indexOfByte((u8)']');
        if (close == (u32)$FFFF_FFFF || close < hash) return false;
        *off = tail.substringBytes(hash + (u32)1, close - hash - (u32)1).trimmed();
        return true;
    }

    // A store into a slot nothing ever loads is dead, and a store immediately
    // followed by a load of the same slot is a register move. The dead-store
    // half is only safe in a CLEAN function: one that never materialises a
    // frame address, because spill memory can then be re-read through a base
    // pointer as [xR, #K], which a literal [sp, #N] scan cannot see.
    String* peepholeSpills(String* text)
    {
        Array* lines = linesOf(text);
        bool clean = true;
        Map* loads = new Map();          // slot offset text -> load count
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* t = ((String*)lines.get(i)).trimmed();
            // A stack-address materialisation `add/sub Rd, sp, …` with Rd not
            // sp, or a non-frame stp/ldp, makes spill memory aliasable. The
            // frame adjust `add sp, sp, #N` is not a base pointer, so it must
            // NOT disqualify the function.
            if ((t.hasPrefix(String.withCString("add ")) || t.hasPrefix(String.withCString("sub ")))
             && !t.hasPrefix(String.withCString("add sp,")) && !t.hasPrefix(String.withCString("sub sp,"))
             && t.byteIndexOf(String.withCString(", sp,")) != (u32)$FFFF_FFFF)
                clean = false;
            if ((t.hasPrefix(String.withCString("stp ")) || t.hasPrefix(String.withCString("ldp ")))
             && t.byteIndexOf(String.withCString("x29, x30")) == (u32)$FFFF_FFFF)
                clean = false;
            String* m = (String*)0; String* r = (String*)0; String* o = (String*)0;
            if (parseSpLine((String*)lines.get(i), &m, &r, &o)
             && m.hasPrefix(String.withCString("ldr"))) {
                Object* c = loads.get((Hashable*)o);
                loads.set((Hashable*)o,
                          (Object*)Number.with((i32)((c == (Object*)0 ? (u32)0 : ((Number*)c).asU32()) + (u32)1)));
            }
        }
        Array* out = new Array();
        u32 i = (u32)0;
        while (i < lines.count()) {
            String* ln = (String*)lines.get(i);
            String* sm = (String*)0; String* sr = (String*)0; String* so = (String*)0;
            if (parseSpLine(ln, &sm, &sr, &so) && sm.equals(String.withCString("str"))) {
                u32 nloads = countIn(loads, so);
                if (clean && nloads == (u32)0) { i = i + (u32)1; continue; }   // dead store
                String* lm = (String*)0; String* lr = (String*)0; String* lo = (String*)0;
                if (i + (u32)1 < lines.count()
                 && parseSpLine((String*)lines.get(i + (u32)1), &lm, &lr, &lo)
                 && lm.equals(String.withCString("ldr")) && lo.equals(so)
                 && regClass(lr) == regClass(sr)) {
                    bool dropStore = clean && nloads == (u32)1;
                    if (!dropStore) out.add((Object*)ln);
                    if (!lr.equals(sr)) {
                        u8 cls = regClass(lr);
                        String* mv = String.withCString("    ");
                        mv.appendCString(cls == (u8)'d' || cls == (u8)'s' ? "fmov " : "mov ");
                        mv.append(lr); mv.appendCString(", "); mv.append(sr);
                        out.add((Object*)mv);
                    }
                    i = i + (u32)2;
                    continue;
                }
            }
            out.add((Object*)ln);
            i = i + (u32)1;
        }
        return joinLines(out);
    }

    static u32 countIn(Map* m, String* k)
    {
        Object* c = m.get((Hashable*)k);
        return c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
    }

    // The first letter of a register name — its class. A str/ldr pair of the
    // same class moves losslessly through mov/fmov.
    static u8 regClass(String* r) { return r.byteLength() == (u32)0 ? (u8)0 : r.byteAt((u32)0); }

    // Split a trimmed line into its mnemonic and comma-separated operands.
    // Null for a label, directive, comment or blank.
    static Array* parseAsmLine(String* line, String** mnem)
    {
        String* t = line.trimmed();
        if (t.byteLength() == (u32)0 || t.hasSuffix(String.withCString(":"))
         || t.hasPrefix(String.withCString(".")) || t.hasPrefix(String.withCString("//")))
            return (Array*)0;
        u32 sp = t.indexOfByte((u8)' ');
        if (sp == (u32)$FFFF_FFFF) { *mnem = t; return new Array(); }   // a bare `ret`
        *mnem = t.substringBytes((u32)0, sp);
        Array* raw = t.substringFromByte(sp + (u32)1).splitOnByte((u8)',');
        Array* ops = new Array();
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            ops.add((Object*)((String*)raw.get(i)).trimmed());
        return ops;
    }

    // Mnemonics whose FIRST operand is not a written register — stores,
    // compares, branches, returns. A value's liveness has to keep walking past
    // them rather than treating operand 0 as a kill.
    static bool mnemWritesReg0(String* m)
    {
        string no = "str strb strh stp stur cmp cmn fcmp tst b bl br blr ret cbz cbnz tbz tbnz";
        String* hay = String.withCString(" ");
        hay.appendCString(no);
        hay.appendCString(" ");
        String* needle = String.withCString(" ");
        needle.append(m);
        needle.appendCString(" ");
        return hay.byteIndexOf(needle) == (u32)$FFFF_FFFF;
    }

    static bool isBranchMnem(String* m)
    {
        string list = "b bl br blr ret cbz cbnz tbz tbnz";
        String* hay = String.withCString(" ");
        hay.appendCString(list);
        hay.appendCString(" ");
        String* needle = String.withCString(" ");
        needle.append(m);
        needle.appendCString(" ");
        return hay.byteIndexOf(needle) != (u32)$FFFF_FFFF;
    }

    // Whether `reg` appears as a whole token in the line — including inside a
    // [base, #off] memory operand. Whole-token, so w1 does not match w16.
    static bool mentionsReg(String* line, String* reg)
    {
        u32 r = line.byteIndexOf(reg);
        while (r != (u32)$FFFF_FFFF) {
            u32 e = r + reg.byteLength();
            u8 before = r > (u32)0 ? line.byteAt(r - (u32)1) : (u8)' ';
            u8 after = e < line.byteLength() ? line.byteAt(e) : (u8)' ';
            bool alnumB = (before >= (u8)'0' && before <= (u8)'9')
                       || (before >= (u8)'a' && before <= (u8)'z');
            bool alnumA = (after >= (u8)'0' && after <= (u8)'9')
                       || (after >= (u8)'a' && after <= (u8)'z');
            if (!alnumB && !alnumA) return true;
            r = line.byteIndexOf(reg, e);
        }
        return false;
    }

    // Only these throwaway scratch registers are safe as a propagated move's
    // destination: they are never homed and never carry a value across a block
    // boundary.
    static bool isScratchDst(String* reg)
    {
        if (reg.byteLength() < (u32)2) return false;
        u8 c = reg.byteAt((u32)0);
        String* num = reg.substringFromByte((u32)1);
        if (c == (u8)'s' || c == (u8)'d')
            return num.equals(String.withCString("0")) || num.equals(String.withCString("1"))
                || num.equals(String.withCString("2")) || num.equals(String.withCString("16"));
        if (c == (u8)'w' || c == (u8)'x')
            return num.equals(String.withCString("9")) || num.equals(String.withCString("16"))
                || num.equals(String.withCString("17"));
        return false;
    }

    // A `mov scratch, src` whose ONLY consumer is the very next instruction
    // vanishes: rewrite that consumer to read src directly. Only when the
    // scratch is dead afterwards — it is overwritten there, or nothing reads it
    // again before a rewrite or a branch.
    String* peepholeCopyProp(String* text)
    {
        Array* lines = linesOf(text);
        bool again = true;
        while (again) {
            again = false;
            for (u32 i = (u32)0; i + (u32)1 < lines.count() && !again; i = i + (u32)1) {
                String* mm = (String*)0;
                Array* mo = parseAsmLine((String*)lines.get(i), &mm);
                if (mo == (Array*)0 || mo.count() != (u32)2) continue;
                if (!mm.equals(String.withCString("fmov")) && !mm.equals(String.withCString("mov")))
                    continue;
                String* dst = (String*)mo.get((u32)0);
                String* src = (String*)mo.get((u32)1);
                if (dst.equals(src) || !isScratchDst(dst)) continue;
                // The source must be a plain register — not an immediate, not a
                // shifted or extended form.
                if (src.hasPrefix(String.withCString("#"))
                 || src.indexOfByte((u8)' ') != (u32)$FFFF_FFFF) continue;

                String* cm = (String*)0;
                Array* co = parseAsmLine((String*)lines.get(i + (u32)1), &cm);
                if (co == (Array*)0 || co.count() == (u32)0) continue;
                // An FP register source (`s27`/`d5`/`v3` — NOT `sp`) may only be
                // propagated into a reg-reg move, and that move must then be an
                // `fmov`: substituting it into a GP `mov` leaves the invalid
                // `mov w0, s27`, and into any GP arithmetic op an unassemblable
                // operand (bug 203 follow-up). GP↔GP propagation is unchanged.
                bool srcFP = src.byteLength() > (u32)1
                    && (src.hasPrefix(String.withCString("s")) || src.hasPrefix(String.withCString("d"))
                        || src.hasPrefix(String.withCString("v")))
                    && src.byteAt((u32)1) >= (u8)'0' && src.byteAt((u32)1) <= (u8)'9';
                if (srcFP && !((cm.equals(String.withCString("mov")) || cm.equals(String.withCString("fmov")))
                               && co.count() == (u32)2))
                    continue;
                String* outMnem = srcFP ? String.withCString("fmov") : cm;
                // Substitute in the consumer's SOURCE operands only; operand 0
                // is its write target.
                bool used = false;
                Array* no = new Array();
                for (u32 k = (u32)0; k < co.count(); k = k + (u32)1) {
                    String* o = (String*)co.get(k);
                    if (k > (u32)0 && o.equals(dst)) { no.add((Object*)src); used = true; }
                    else no.add((Object*)o);
                }
                // A memory operand names its base inside brackets, so an
                // exact match never fires for `mov x16, x12; ldr w17, [x16]` —
                // the copy survived in front of essentially every load in a hot
                // loop. Rewrite the base of the simple forms `[dst]` and
                // `[dst, #imm]` too, restricted to the LAST operand and to
                // lines with no writeback (`!`), so a pre/post-indexed form —
                // which WRITES its base — is left alone.
                if (!used && !srcFP && src.hasPrefix(String.withCString("x"))
                    && !((String*)lines.get(i + (u32)1)).contains(String.withCString("!"))
                    && no.count() >= (u32)2)
                    {
                    u32 last = no.count() - (u32)1;
                    String* opnd = (String*)no.get(last);
                    String* plain = String.withCString("[");
                    plain.append(dst);
                    plain.appendCString("]");
                    String* pre = String.withCString("[");
                    pre.append(dst);
                    pre.appendCString(", #");
                    if (opnd.equals(plain))
                        {
                        String* rep = String.withCString("[");
                        rep.append(src);
                        rep.appendCString("]");
                        no.set(last, (Object*)rep);
                        used = true;
                        }
                    else if (opnd.hasPrefix(pre) && opnd.hasSuffix(String.withCString("]")))
                        {
                        String* rep = String.withCString("[");
                        rep.append(src);
                        rep.appendCString(", #");
                        rep.append(opnd.substringBytes(pre.byteLength(),
                                                       opnd.byteLength() - pre.byteLength()));
                        no.set(last, (Object*)rep);
                        used = true;
                        }
                    }
                if (!used) continue;
                if (!scratchDeadAfter(lines, i, dst, cm, co)) continue;
                // Rebuild the consumer, keeping its indentation, and drop the
                // move.
                String* cons = (String*)lines.get(i + (u32)1);
                String* rebuilt = cons.substringBytes((u32)0, cons.byteIndexOf(cm));
                rebuilt.append(outMnem);
                for (u32 k = (u32)0; k < no.count(); k = k + (u32)1) {
                    rebuilt.appendCString(k == (u32)0 ? " " : ", ");
                    rebuilt.append((String*)no.get(k));
                }
                lines.set(i + (u32)1, (Object*)rebuilt);
                lines.removeAt(i);
                again = true;
            }
        }
        return joinLines(lines);
    }

    static bool scratchDeadAfter(Array* lines, u32 i, String* dst, String* cm, Array* co)
    {
        if (mnemWritesReg0(cm) && ((String*)co.get((u32)0)).equals(dst)) return true;
        for (u32 j = i + (u32)2; j < lines.count(); j = j + (u32)1) {
            String* line = (String*)lines.get(j);
            String* t = line.trimmed();
            if (t.byteLength() == (u32)0) continue;
            if (t.hasSuffix(String.withCString(":"))) return true;   // block edge: dead out
            String* jm = (String*)0;
            Array* jo = parseAsmLine(line, &jm);
            // A comment or directive ends the scan the same way a label does:
            // it cannot read a register, so the scratch is dead out. (Returning
            // "still live" here instead cost every collapse that happened to
            // have an inline-asm banner downstream.)
            if (jo == (Array*)0) return true;
            if (!mnemWritesReg0(jm)) {
                if (isBranchMnem(jm)) return true;                   // dead out
                if (mentionsReg(line, dst)) return false;
                continue;
            }
            if (mentionsReg(line, dst)) {
                // A pure overwrite kills it; a read keeps it live.
                for (u32 k = (u32)1; k < jo.count(); k = k + (u32)1)
                    if (mentionsReg((String*)jo.get(k), dst)) return false;
                return ((String*)jo.get((u32)0)).equals(dst);
            }
        }
        return true;
    }

    // The block walker always emits a conditional branch as `b.<c> LT` then
    // `b LF`, never relying on layout fall-through. When the block laid out
    // next is one of the two targets, one branch is redundant: falling through
    // to LF drops the `b LF`, and falling through to LT inverts the condition
    // instead — which turns a loop's TAKEN forward branch into a not-taken one.
    //
    // Safe by construction: the two branch lines have to be ADJACENT to match,
    // so no edge phi-copy sits between them (which an inversion would break).
    String* peepholeFallthrough(String* text)
    {
        Array* lines = linesOf(text);
        bool again = true;
        while (again) {
            again = false;
            for (u32 i = (u32)0; i < lines.count() && !again; i = i + (u32)1) {
                String* t = ((String*)lines.get(i)).trimmed();
                // A lone `b L` immediately before `L:` falls through.
                if (t.hasPrefix(String.withCString("b "))) {
                    String* tgt = t.substringFromByte((u32)2).trimmed();
                    i32 j = nextRealLine(lines, i);
                    if (j >= (i32)0) {
                        String* lbl = labelOf((String*)lines.get((u32)j));
                        if (lbl != (String*)0 && lbl.equals(tgt)) {
                            lines.removeAt(i);
                            again = true;
                        }
                    }
                    continue;
                }
                bool isDot = t.hasPrefix(String.withCString("b."));
                bool isCb = t.hasPrefix(String.withCString("cbz "))
                         || t.hasPrefix(String.withCString("cbnz "));
                if (!isDot && !isCb) continue;
                i32 j = nextRealLine(lines, i);
                if (j < (i32)0) continue;
                String* jt = ((String*)lines.get((u32)j)).trimmed();
                if (!jt.hasPrefix(String.withCString("b "))) continue;   // need the pair
                String* lf = jt.substringFromByte((u32)2).trimmed();
                i32 k = nextRealLine(lines, (u32)j);
                if (k < (i32)0) continue;
                String* nextLbl = labelOf((String*)lines.get((u32)k));
                if (nextLbl == (String*)0) continue;
                u32 sp = t.indexOfByte((u8)' ');
                if (sp == (u32)$FFFF_FFFF) continue;
                String* mnem = t.substringBytes((u32)0, sp);
                String* reg = (String*)0;
                String* lt = (String*)0;
                if (isDot) {
                    lt = t.substringFromByte(sp + (u32)1).trimmed();
                } else {
                    Array* ops = t.substringFromByte(sp + (u32)1).splitOnByte((u8)',');
                    if (ops.count() != (u32)2) continue;
                    reg = ((String*)ops.get((u32)0)).trimmed();
                    lt = ((String*)ops.get((u32)1)).trimmed();
                }
                if (nextLbl.equals(lf)) {
                    lines.removeAt((u32)j);           // fall through to LF
                    again = true;
                    continue;
                }
                if (nextLbl.equals(lt)) {
                    String* cc = isDot ? mnem.substringFromByte((u32)2) : mnem;
                    String* ic = invertCC(cc);
                    if (ic == (String*)0) continue;
                    String* rep = String.withCString("    ");
                    if (isDot) { rep.appendCString("b."); rep.append(ic); rep.appendCString(" "); rep.append(lf); }
                    else { rep.append(ic); rep.appendCString(" "); rep.append(reg); rep.appendCString(", "); rep.append(lf); }
                    lines.set(i, (Object*)rep);
                    lines.removeAt((u32)j);
                    again = true;
                }
            }
        }
        return joinLines(lines);
    }

    static i32 nextRealLine(Array* lines, u32 i)
    {
        for (u32 j = i + (u32)1; j < lines.count(); j = j + (u32)1)
            if (((String*)lines.get(j)).trimmed().byteLength() > (u32)0) return (i32)j;
        return (i32)-1;
    }

    static String* labelOf(String* line)
    {
        String* t = line.trimmed();
        if (t.byteLength() > (u32)1 && t.hasSuffix(String.withCString(":")))
            return t.substringBytes((u32)0, t.byteLength() - (u32)1);
        return (String*)0;
    }

    static String* invertCC(String* cc)
    {
        if (cc.equals(String.withCString("eq")))   return String.withCString("ne");
        if (cc.equals(String.withCString("ne")))   return String.withCString("eq");
        if (cc.equals(String.withCString("lo")))   return String.withCString("hs");
        if (cc.equals(String.withCString("hs")))   return String.withCString("lo");
        if (cc.equals(String.withCString("ls")))   return String.withCString("hi");
        if (cc.equals(String.withCString("hi")))   return String.withCString("ls");
        if (cc.equals(String.withCString("lt")))   return String.withCString("ge");
        if (cc.equals(String.withCString("ge")))   return String.withCString("lt");
        if (cc.equals(String.withCString("le")))   return String.withCString("gt");
        if (cc.equals(String.withCString("gt")))   return String.withCString("le");
        if (cc.equals(String.withCString("mi")))   return String.withCString("pl");
        if (cc.equals(String.withCString("pl")))   return String.withCString("mi");
        if (cc.equals(String.withCString("cc")))   return String.withCString("cs");
        if (cc.equals(String.withCString("cs")))   return String.withCString("cc");
        if (cc.equals(String.withCString("vs")))   return String.withCString("vc");
        if (cc.equals(String.withCString("vc")))   return String.withCString("vs");
        if (cc.equals(String.withCString("cbz")))  return String.withCString("cbnz");
        if (cc.equals(String.withCString("cbnz"))) return String.withCString("cbz");
        return (String*)0;
    }

    // ── Type spelling helpers ────────────────────────────────────────────
    //
    // A pointee is read out of the type's SPELLING: `Ptr(U8, unbanked)` points
    // at U8, `Ptr(Agg(6), unbanked)` at aggregate 6. The comma that ends it is
    // the first one at nesting depth zero, so a nested `Agg(...)` survives.
    static String* pointeeOf(String* t)
    {
        if (!isPtrTy(t)) return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') { if (depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4); depth = depth - (u32)1; }
            else if (c == (u8)',' && depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
        }
        return (String*)0;
    }

    // The layout an `Agg(N)` names, or null.
    IRLayout* layoutOf(String* t)
    {
        if (!isAggTy(t)) return (IRLayout*)0;
        u32 n = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)')') break;
            if (c < (u8)'0' || c > (u8)'9') return (IRLayout*)0;
            n = n * (u32)10 + (u32)(c - (u8)'0');
        }
        if (_m == (IRModule*)0 || n >= _m.layouts().count()) return (IRLayout*)0;
        return (IRLayout*)_m.layouts().get(n);
    }

    // A field's width in THIS target's terms. The IR layout's own offsets are
    // computed with a different pointer size, so they are recomputed here from
    // arm64 widths — the back end's half of the type-width invariant.
    u32 fieldWidth(String* t)
    {
        if (t == (String*)0) return (u32)0;
        if (isAggTy(t)) return aggSize(layoutOf(t));
        if (isMemTy(t) || t.equals(String.withCString("Void"))) return (u32)0;
        return width(t);
    }

    u32 aggSize(IRLayout* l)
    {
        if (l == (IRLayout*)0) return (u32)0;
        u32 total = (u32)0;
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            total = total + fieldWidth(l.typeAt(i));
        // A field-less aggregate (an opaque byte buffer such as the varargs
        // area) carries its byte count in the layout's size with nothing to
        // sum, so never size below it. A pointer-bearing struct sums HIGHER
        // than the shared layout size, so the sum still wins there.
        if (total < l.size()) total = l.size();
        return total;
    }

    // The RECORDED layout offset (blewit #5): the front end lays fields out
    // once — naturally aligned per target — and every backend reads the same
    // offsets, so FE and backend cannot disagree. Widths still size the
    // loads/stores (the type-width invariant); they no longer place fields.
    u32 fieldOffset(IRLayout* l, u32 idx)
    {
        if (l == (IRLayout*)0 || idx >= l.fieldCount()) return aggSize(l);
        return l.offsetAt(idx);
    }

    // ── Memory ───────────────────────────────────────────────────────────
    //
    // A deref's effective address goes in x16. This is a flat host: a pointer
    // is dereferenced directly, with no address remapping.
    void emitDerefAddr(IROperand* ptr)
    {
        String* p = operandReg(ptr, String.withCString("x16"));
        if (!p.equals(String.withCString("x16"))) emitMove(String.withCString("x16"), p);
    }

    void emitLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        bool folded = p.kind() == (u8)OPK_USE && p.val() != (IRValue*)0
                   && _foldInfo.get((Hashable*)p.val()) != (Object*)0;
        if (!folded) emitDerefAddr(p);
        String* pte = n.res().ty();
        if (isAggTy(pte)) {
            // A struct value cannot ride one register: copy its full size from
            // [x16] into the result's slot in chunks.
            emitAggCopy(aggSize(layoutOf(pte)), slotOf(n.res()), true);
            return;
        }
        if (isVecTy(pte)) { unsupported(String.withCString("Load:Vec")); return; }
        String* mnem = String.withCString("ldr");
        String* dest = String.withCString("w17");
        u32 w = width(pte);
        if (isPtrTy(pte) || w >= (u32)8) { dest = String.withCString("x17"); }
        else if (w >= (u32)4) { dest = String.withCString("w17"); }
        else if (w == (u32)2) { mnem = String.withCString(isSignedTy(pte) ? "ldrsh" : "ldrh"); }
        else                  { mnem = String.withCString(isSignedTy(pte) ? "ldrsb" : "ldrb"); }
        // Load straight into the result's home when it has one; a float home
        // gives a direct `ldr s8/d8`, and the narrow ldrsb/ldrsh forms only
        // fire for GP homes, so the width stays legal.
        // Fold the address FIRST (it materialises base into x16 and the index
        // into x17), then pick the destination: a scratch destination of x17
        // reuses the index register, which is safe because the load has already
        // read both to form the address before it writes the result.
        String* addr = folded ? foldedAddrOperand(n) : String.withCString("[x16]");
        dest = resultReg(n.res(), dest);
        _out.appendFormat("    %s %s, %s\n", mnem.cString(), dest.cString(), addr.cString());
        storeReg(dest, n.res());
    }

    static bool isSignedTy(String* t)
    {
        if (t == (String*)0) return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("I16"))
            || t.equals(String.withCString("I32")) || t.equals(String.withCString("I64"));
    }

    void emitStore(IRInsn* n)
    {
        if (n.ops().count() < (u32)3) { unsupported(n.op()); return; }
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        bool folded = p.kind() == (u8)OPK_USE && p.val() != (IRValue*)0
                   && _foldInfo.get((Hashable*)p.val()) != (Object*)0;
        if (!folded) emitDerefAddr(p);
        IROperand* vop = (IROperand*)n.ops().get((u32)1);
        String* vty = (vop.kind() == (u8)OPK_USE && vop.val() != (IRValue*)0)
            ? vop.val().ty() : (String*)0;
        if (isAggTy(vty) && vop.kind() == (u8)OPK_USE) {
            emitAggCopy(aggSize(layoutOf(vty)), slotOf(vop.val()), false);
            return;
        }
        if (isVecTy(vty)) { unsupported(String.withCString("Store:Vec")); return; }
        String* mnem = String.withCString("str");
        String* vreg = String.withCString("w17");
        u32 w = vty == (String*)0 ? (u32)4 : width(vty);
        if (isPtrTy(vty) || w >= (u32)8) { vreg = String.withCString("x17"); }
        else if (w >= (u32)4) { vreg = String.withCString("w17"); }
        else if (w == (u32)2) { mnem = String.withCString("strh"); }
        else                  { mnem = String.withCString("strb"); }
        // An integer `Const #0` value stores the zero register directly — no
        // mov, no extend, and (when single-use) its definition is elided too.
        String* addr = folded ? foldedAddrOperand(n) : String.withCString("[x16]");
        if (isIntZeroConst(vop)) {
            vreg = String.withCString((isPtrTy(vty) || w >= (u32)8) ? "xzr" : "wzr");
        } else {
            // With a fold live, x16 (base) and x17 (index) are both needed for
            // the addressing mode, so the value stages in x15/w15 instead.
            // NOT x18: that is the platform-reserved register on Darwin and the
            // kernel may clobber it between the mov and the str.
            if (folded) vreg = String.withCString(vreg.equals(String.withCString("x17")) ? "x15" : "w15");
            vreg = operandReg(vop, vreg);
        }
        _out.appendFormat("    %s %s, %s\n", mnem.cString(), vreg.cString(), addr.cString());
    }

    // A use of an integer/bool `Const #0`: its value IS the zero register, so a
    // consumer can store it without materialising anything.
    bool isIntZeroConst(IROperand* o)
    {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) return false;
        Object* d = _defOf.get((Hashable*)o.val());
        if (d == (Object*)0) return false;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("Const")) || n.res() == (IRValue*)0) return false;
        if (isFloatTy(n.res().ty())) return false;
        if (n.ops().count() < (u32)1) return false;
        IROperand* a0 = (IROperand*)n.ops().get((u32)0);
        return a0.kind() == (u8)OPK_IMMI && a0.imm() == (i32)0;
    }

    // `add reg, sp, #off`, safely. The add immediate is 12 bits, so a slot high
    // in a big frame has its offset built into the register first.
    // The frame-slot addressing operand for a load/store of `reg` at
    // [sp + off] — `[sp, #off]` while the scaled immediate encodes (16380
    // for a w/s view, 32760 for x/d), else the address is STAGED in x9 and
    // the access goes register-indirect. This is what lifted the old 16 KB
    // frame budget: a big frame is merely slower at its far end. x16 stands
    // in when x9/w9 itself carries the data.
    String* spMemForOff(u32 off, String* reg)
    {
        u32 max = (reg.hasPrefix(String.withCString("w"))
                || reg.hasPrefix(String.withCString("s"))) ? (u32)16380 : (u32)32760;
        if (off <= max) {
            String* m = String.withCString("[sp, #");
            m.appendFormat("%lu]", off);
            return m;
        }
        String* addr = (reg.equals(String.withCString("x9"))
                     || reg.equals(String.withCString("w9")))
                     ? String.withCString("x16") : String.withCString("x9");
        emitSpAddr(off, addr);
        String* m2 = String.withCString("[");
        m2.append(addr);
        m2.appendCString("]");
        return m2;
    }

    void emitSpAddr(u32 off, String* reg)
    {
        if (off <= (u32)4095) {
            _out.appendFormat("    add %s, sp, #%lu\n", reg.cString(), off);
        } else if ((off & (u32)$FFF) == (u32)0 && (off >> (u32)12) <= (u32)4095) {
            _out.appendFormat("    add %s, sp, #%lu, lsl #12\n", reg.cString(), off >> (u32)12);
        } else {
            String* w = wForm(reg);
            _out.appendFormat("    mov %s, #%lu\n", w.cString(), off & (u32)$FFFF);
            if (off > (u32)$FFFF)
                _out.appendFormat("    movk %s, #%lu, lsl #16\n", w.cString(), off >> (u32)16);
            _out.appendFormat("    add %s, sp, %s\n", reg.cString(), reg.cString());
        }
    }

    // Emit `add <dest>, <base>, #<off>` safely. The add immediate is 12-bit
    // (0-4095, optionally <<12), so a large object-field offset — an ivar
    // sitting behind a 32KB array ivar (finding #13) — splits into
    // `hi, lsl #12` + `lo`, or materialises through x17 past 16MB. `dest` may
    // alias `base`; neither is ever x17 (the operand scratch is x16).
    void emitAddImm(String* dest, String* base, u32 off)
    {
        if (off <= (u32)4095) {
            _out.appendFormat("    add %s, %s, #%lu\n", dest.cString(), base.cString(), off);
        } else if (off <= (u32)$FFFFFF) {
            _out.appendFormat("    add %s, %s, #%lu, lsl #12\n",
                              dest.cString(), base.cString(), off >> (u32)12);
            if ((off & (u32)$FFF) != (u32)0)
                _out.appendFormat("    add %s, %s, #%lu\n",
                                  dest.cString(), dest.cString(), off & (u32)$FFF);
        } else {
            _out.appendFormat("    movz x17, #%lu\n", off & (u32)$FFFF);
            u32 sh = (u32)16;
            while (sh < (u32)64) {
                u32 chunk = (u32)(((u64)off >> (u64)sh) & (u64)$FFFF);
                if (chunk != (u32)0)
                    _out.appendFormat("    movk x17, #%lu, lsl #%lu\n", chunk, sh);
                sh = sh + (u32)16;
            }
            _out.appendFormat("    add %s, %s, x17\n", dest.cString(), base.cString());
        }
    }

    // &symbol, or the address of a pinned local.
    void emitAddrOf(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* op = (IROperand*)n.ops().get((u32)0);
        String* dest = resultReg(n.res(), String.withCString("x16"));
        if (op.kind() == (u8)OPK_SYM) {
            // A symbol defined in ANOTHER module, or an external function
            // (a body-less prototype resolved at link), has no address fixed
            // at static-link time, so it is taken through the GOT — a direct
            // adrp/add fails with "target does not have address".
            if (symbolIsExternal(op.name())) {
                _out.appendFormat("    adrp %s, _%s@GOTPAGE\n", dest.cString(), op.name().cString());
                _out.appendFormat("    ldr %s, [%s, _%s@GOTPAGEOFF]\n",
                                  dest.cString(), dest.cString(), op.name().cString());
            } else {
                _out.appendFormat("    adrp %s, _%s@PAGE\n", dest.cString(), op.name().cString());
                _out.appendFormat("    add %s, %s, _%s@PAGEOFF\n",
                                  dest.cString(), dest.cString(), op.name().cString());
            }
            storeReg(dest, n.res());
            return;
        }
        if (op.kind() == (u8)OPK_USE) {
            emitSpAddr(slotOf(op.val()), dest);
            storeReg(dest, n.res());
            return;
        }
        unsupported(String.withCString("AddrOf:operand"));
    }

    bool symbolIsExternal(String* name)
    {
        IRSymbol* sym = symbolNamed(name);
        if (sym == (IRSymbol*)0) return true;
        if (sym.isExtern()) return true;
        if (!sym.isFunc()) return false;
        // A function symbol is external exactly when no function of that name
        // is DEFINED in this module; a local one keeps the direct adrp/add.
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)_m.funcs().get(i)).name().equals(name)) return false;
        return true;
    }

    IRSymbol* symbolNamed(String* name)
    {
        if (_m == (IRModule*)0) return (IRSymbol*)0;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name)) return s;
        }
        return (IRSymbol*)0;
    }

    void emitFieldAddr(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        String* base = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        String* dest = resultReg(n.res(), String.withCString("x16"));
        // Safe add: an ivar behind a 32KB array ivar overflows the 12-bit
        // immediate (finding #13).
        emitAddImm(dest, base, fieldByteOffset(n));
        storeReg(dest, n.res());
    }

    u32 fieldByteOffset(IRInsn* n)
    {
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        if (b.kind() != (u8)OPK_USE || b.val() == (IRValue*)0) return (u32)0;
        IRLayout* l = layoutOf(pointeeOf(b.val().ty()));
        if (l == (IRLayout*)0) return (u32)0;
        return fieldOffset(l, (u32)((IROperand*)n.ops().get((u32)1)).imm());
    }

    // The element stride an ElementAddr scales by, in this target's widths.
    u32 elemSize(IRInsn* n)
    {
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        if (b.kind() != (u8)OPK_USE || b.val() == (IRValue*)0) return (u32)1;
        String* pte = pointeeOf(b.val().ty());
        if (pte == (String*)0) return (u32)1;
        if (isAggTy(pte)) return aggSize(layoutOf(pte));
        if (isPtrTy(pte)) return (u32)8;
        u32 w = width(pte);
        return w == (u32)0 ? (u32)1 : w;
    }

    // An ElementAddr index that resolves to a compile-time constant, seen
    // through the ZExt/SExt/Trunc of a Const the lowering emits for a widened
    // literal.
    bool constIndex(IRInsn* ea, i32* out)
    {
        if (ea.ops().count() < (u32)2) return false;
        IROperand* idx = (IROperand*)ea.ops().get((u32)1);
        if (idx.kind() == (u8)OPK_IMMI) { *out = idx.imm(); return true; }
        if (idx.kind() != (u8)OPK_USE) return false;
        IRValue* cur = idx.val();
        for (u32 g = (u32)0; g < (u32)8; g = g + (u32)1) {
            Object* o = _defOf.get((Hashable*)cur);
            if (o == (Object*)0) return false;
            IRInsn* d = (IRInsn*)o;
            if (d.ops().count() < (u32)1) return false;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("Const"))) {
                if (a0.kind() != (u8)OPK_IMMI) return false;
                *out = a0.imm();
                return true;
            }
            if ((d.op().equals(String.withCString("ZExt"))
              || d.op().equals(String.withCString("SExt"))
              || d.op().equals(String.withCString("Trunc")))
             && a0.kind() == (u8)OPK_USE) { cur = a0.val(); continue; }
            return false;
        }
        return false;
    }

    void emitElementAddr(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        u32 es = elemSize(n);
        i32 k = (i32)0;
        // A constant index — the pointer-IV advance `p + step`, or the negated
        // index of `p - N` — is one immediate add or sub when the byte offset
        // fits imm12.
        if (constIndex(n, &k)) {
            i32 mag = k < (i32)0 ? -k : k;
            if ((i32)((u32)mag * es) <= (i32)4095 && mag <= (i32)4095) {
                i32 off = k * (i32)es;
                String* base = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
                String* dest = resultReg(n.res(), String.withCString("x16"));
                if (off >= (i32)0)
                    _out.appendFormat("    add %s, %s, #%ld\n", dest.cString(), base.cString(), off);
                else
                    _out.appendFormat("    sub %s, %s, #%ld\n", dest.cString(), base.cString(), -off);
                storeReg(dest, n.res());
                return;
            }
        }
        String* base = operandReg((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        // A SIGNED index (the negated offset of `p - N`) must be SIGN-extended
        // into the 64-bit address; uxtw would turn −2 into +0xFFFFFFFE and walk
        // off into a wild address. A 64-BIT index needs neither: its home view
        // IS an X register, and the W-only uxtw/sxtw forms are invalid with it
        // (blewit finding #8) — the shifted-register lsl form takes it whole.
        IROperand* io = (IROperand*)n.ops().get((u32)1);
        bool sgn = io.kind() == (u8)OPK_USE && io.val() != (IRValue*)0
                && isSignedTy(io.val().ty());
        bool idx64 = io.kind() == (u8)OPK_USE && io.val() != (IRValue*)0
                  && needsXReg(io.val().ty());
        // The extended-register add both widens the index and scales it, so a
        // homed index — the hot case, where the index IS the induction
        // variable — needs no separate materialise.
        String* idx = operandReg((IROperand*)n.ops().get((u32)1),
                                 String.withCString(idx64 ? "x17" : "w17"));
        String* dest = resultReg(n.res(), String.withCString("x16"));
        String* ext = String.withCString(idx64 ? "lsl" : (sgn ? "sxtw" : "uxtw"));
        if (es == (u32)1) {
            if (idx64)
                _out.appendFormat("    add %s, %s, %s\n", dest.cString(), base.cString(),
                                  idx.cString());
            else
                _out.appendFormat("    add %s, %s, %s, %s\n", dest.cString(), base.cString(),
                                  idx.cString(), ext.cString());
        } else if ((es & (es - (u32)1)) == (u32)0) {
            u32 shift = (u32)0;
            for (u32 v = es; v > (u32)1; v = v >> (u32)1) shift = shift + (u32)1;
            if (shift <= (u32)4 || idx64) {
                // The extended-register form's shift field only reaches 4 (×16);
                // the X-index lsl form reaches 63, so it never splits.
                _out.appendFormat("    add %s, %s, %s, %s #%lu\n", dest.cString(),
                                  base.cString(), idx.cString(), ext.cString(), shift);
            } else {
                _out.appendFormat("    %s x17, %s\n", ext.cString(), idx.cString());
                _out.appendFormat("    add %s, %s, x17, lsl #%lu\n", dest.cString(),
                                  base.cString(), shift);
            }
        } else {
            // A non-power-of-two stride needs a multiply.
            if (idx64)
                _out.appendFormat("    mov x17, %s\n", idx.cString());
            else
                _out.appendFormat("    %s x17, %s\n", ext.cString(), idx.cString());
            _out.appendFormat("    mov x15, #%lu\n", es);
            _out.appendFormat("    madd %s, x17, x15, %s\n", dest.cString(), base.cString());
        }
        storeReg(dest, n.res());
    }

    void emitIntToPtr(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        // The source slot was written by a 32-bit store, so its upper four
        // bytes are stale: read it 32-bit first, and the "a write to w<n>
        // zero-extends x<n>" rule gives a clean pointer-width value.
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        // An int→ptr is a 16-bit address value, masked so the Map/Set
        // `(pointer)0` / `(pointer)1` sentinels and the `(u16)(pointer)N == N`
        // round trip stay honest. Native pointers never come through here —
        // they arrive from Call or AddrOf at full host width.
        _out.appendCString("    and w16, w16, #0xFFFF\n");
        storeReg(String.withCString("x16"), n.res());
    }

    void emitPtrToInt(IRInsn* n)
    {
        if (n.res() == (IRValue*)0) return;              // no result: nothing to compute
        if (n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("x16"));
        String* d = String.withCString(needsXReg(n.res().ty()) ? "x16" : "w16");
        // Canonicalise to the result width: `(u16)ptr` keeps only the low 16
        // bits. Without this the result is the full low 32, which is usually
        // hidden by a call or parameter boundary re-canonicalising — but when
        // the value is consumed directly the high bits make an equal pair
        // miscompare.
        canonicalise(d, n.res().ty());
        storeReg(d, n.res());
    }

    // ── Comparison ───────────────────────────────────────────────────────
    static String* condString(String* pred)
    {
        if (pred == (String*)0) return String.withCString("eq");
        if (pred.equals(String.withCString("EQ")))  return String.withCString("eq");
        if (pred.equals(String.withCString("NE")))  return String.withCString("ne");
        if (pred.equals(String.withCString("SLT"))) return String.withCString("lt");
        if (pred.equals(String.withCString("SGT"))) return String.withCString("gt");
        if (pred.equals(String.withCString("SLE"))) return String.withCString("le");
        if (pred.equals(String.withCString("SGE"))) return String.withCString("ge");
        if (pred.equals(String.withCString("ULT"))) return String.withCString("lo");
        if (pred.equals(String.withCString("UGT"))) return String.withCString("hi");
        if (pred.equals(String.withCString("ULE"))) return String.withCString("ls");
        if (pred.equals(String.withCString("UGE"))) return String.withCString("hs");
        return (String*)0;
    }

    static String* negatePred(String* p)
    {
        if (p.equals(String.withCString("EQ")))  return String.withCString("NE");
        if (p.equals(String.withCString("NE")))  return String.withCString("EQ");
        if (p.equals(String.withCString("SLT"))) return String.withCString("SGE");
        if (p.equals(String.withCString("SGE"))) return String.withCString("SLT");
        if (p.equals(String.withCString("SGT"))) return String.withCString("SLE");
        if (p.equals(String.withCString("SLE"))) return String.withCString("SGT");
        if (p.equals(String.withCString("ULT"))) return String.withCString("UGE");
        if (p.equals(String.withCString("UGE"))) return String.withCString("ULT");
        if (p.equals(String.withCString("UGT"))) return String.withCString("ULE");
        if (p.equals(String.withCString("ULE"))) return String.withCString("UGT");
        return p;
    }

    // The type an operand reads as: a use's value type, else the type the
    // immediate was spelled with.
    static String* opType(IROperand* o)
    {
        if (o.kind() == (u8)OPK_USE) return o.val() == (IRValue*)0 ? (String*)0 : o.val().ty();
        return o.ty();
    }

    // Emit the `cmp` that sets the flags and return its condition string.
    // Shared by the standalone ICmp (→ cset) and the fused CondBranch
    // (→ b.<cond>).
    String* emitCompare(IRInsn* n)
    {
        IROperand* o0 = (IROperand*)n.ops().get((u32)0);
        IROperand* o1 = (IROperand*)n.ops().get((u32)1);
        String* t0 = opType(o0);
        String* t1 = opType(o1);
        // Pointers are 8 bytes here, so comparing them through w-registers
        // would truncate to the low word and two distinct heap pointers whose
        // low halves collide would read equal.
        if (needsXReg(t0) || needsXReg(t1)) {
            materialise(o0, String.withCString("x16"));
            materialise(o1, String.withCString("x17"));
            _out.appendCString("    cmp x16, x17\n");
            return condString(n.pred());
        }
        // A small constant right-hand side folds into `cmp r, #imm`, eliding
        // the `mov` that would otherwise feed the compare — this sits on the
        // loop-control path that gates every back edge.
        i32 k = (i32)0;
        if (imm12Operand(o1, &k)) {
            String* r0 = operandReg(o0, String.withCString("w16"));
            _out.appendFormat("    cmp %s, #%ld\n", r0.cString(), k);
            return condString(n.pred());
        }
        String* r0 = operandReg(o0, String.withCString("w16"));
        String* r1 = operandReg(o1, String.withCString("w17"));
        _out.appendFormat("    cmp %s, %s\n", r0.cString(), r1.cString());
        return condString(n.pred());
    }

    // An operand that is a 0..4095 constant — the `cmp`/`add` imm12 form.
    //
    // `v` is i64, not i32, because imm() IS i64 and the narrowing was a
    // miscompile: a constant that is zero in its low 32 bits but non-zero
    // above them — `1 << 32`, the borrow in a bignum subtract — truncated to
    // 0, passed the 0..4095 test, and folded to `add xD, xN, #0`. The addend
    // did not fail to fit; it VANISHED, silently, in code that had already
    // materialised it correctly with movz/movk. Compare in the full width and
    // narrow only after the range test has passed.
    bool imm12Operand(IROperand* o, i32* out)
    {
        i64 v = (i64)0;
        if (o.kind() == (u8)OPK_IMMI) {
            v = o.imm();
        } else if (o.kind() == (u8)OPK_USE) {
            Object* d = _defOf.get((Hashable*)o.val());
            if (d == (Object*)0) return false;
            IRInsn* n = (IRInsn*)d;
            if (!n.op().equals(String.withCString("Const"))) return false;
            if (n.ops().count() < (u32)1) return false;
            IROperand* a0 = (IROperand*)n.ops().get((u32)0);
            if (a0.kind() != (u8)OPK_IMMI) return false;
            v = a0.imm();
        } else {
            return false;
        }
        if (v < (i64)0 || v > (i64)4095) return false;
        *out = (i32)v;
        return true;
    }

    void emitICmp(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2) { unsupported(n.op()); return; }
        String* cond = emitCompare(n);
        if (cond == (String*)0) { unsupported(String.withCString("ICmp:pred")); return; }
        String* d = resultReg(n.res(), String.withCString("w16"));
        _out.appendFormat("    cset %s, %s\n", d.cString(), cond.cString());
        // The result is Bool — already 0/1, so no canonicalisation.
        storeReg(d, n.res());
    }

    // cond ? t : f. The register width follows the value type: a pointer
    // selected through w-registers would have its address truncated.
    // An operand into a specific FP register. A use is loaded straight there; a
    // constant has no FP immediate form on AArch64, so it goes through a GP
    // scratch and `fmov`. Mirrors the original's loadFPOperand: same scratch
    // (x14/w14), same order, so the two back ends emit the same text.
    void loadFPOperand(IROperand* o, String* reg, bool dbl)
    {
        if (o.kind() == (u8)OPK_USE) { loadValue(o.val(), reg); return; }
        String* gp = String.withCString(dbl ? "x14" : "w14");
        materialise(o, gp);
        _out.appendFormat("    fmov %s, %s\n", reg.cString(), gp.cString());
    }

    void emitSelect(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)3) { unsupported(n.op()); return; }
        String* ty = n.res().ty();
        // A float/double Select needs the FP bank and `fcsel` — the integer path
        // below would `csel` into a `d` register, which is not a legal
        // instruction. If-conversion turns `if (x < 0.0) x = -x;` into one of
        // these, so ANY float code with a conditional reaches here: this single
        // refusal was 71 of the 74 failures in the first corpus sweep run
        // through the xc compiler.
        if (isFloatTy(ty)) {
            bool dbl = ty.equals(String.withCString("F64"));
            String* f1 = fregName((u32)17, ty);
            String* f2 = fregName((u32)15, ty);
            String* f0 = fregName((u32)16, ty);
            materialise((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
            loadFPOperand((IROperand*)n.ops().get((u32)1), f1, dbl);
            loadFPOperand((IROperand*)n.ops().get((u32)2), f2, dbl);
            _out.appendCString("    cmp w16, #0\n");
            _out.appendFormat("    fcsel %s, %s, %s, ne\n",
                              f0.cString(), f1.cString(), f2.cString());
            storeReg(f0, n.res());
            return;
        }
        bool x = needsXReg(ty);
        materialise((IROperand*)n.ops().get((u32)0), String.withCString("w16"));
        String* r1 = operandReg((IROperand*)n.ops().get((u32)1),
                                String.withCString(x ? "x17" : "w17"));
        String* r2 = operandReg((IROperand*)n.ops().get((u32)2),
                                String.withCString(x ? "x15" : "w15"));
        _out.appendCString("    cmp w16, #0\n");
        String* r0 = resultReg(n.res(), String.withCString(x ? "x16" : "w16"));
        _out.appendFormat("    csel %s, %s, %s, ne\n", r0.cString(), r1.cString(), r2.cString());
        canonicalise(r0, ty);
        storeReg(r0, n.res());
    }

    // ── Branches ─────────────────────────────────────────────────────────
    String* blockLabel(IRBlock* b)
    {
        String* s = String.withCString("L");
        s.append(_fn.name());
        s.appendCString("_");
        s.append(b.name());
        return s;
    }

    void emitBranch(IRInsn* n)
    {
        if (n.ops().count() < (u32)1) { unsupported(n.op()); return; }
        IROperand* t = (IROperand*)n.ops().get((u32)0);
        if (t.kind() != (u8)OPK_BLOCK) { unsupported(n.op()); return; }
        emitPhiCopies(_bb, t.blk());
        _out.appendFormat("    b %s\n", blockLabel(t.blk()).cString());
    }

    void emitCondBranch(IRInsn* n)
    {
        if (n.ops().count() < (u32)3) { unsupported(n.op()); return; }
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        IRBlock* t = ((IROperand*)n.ops().get((u32)1)).blk();
        IRBlock* f = ((IROperand*)n.ops().get((u32)2)).blk();
        // Fused: the condition is a single-use ICmp from this block. Emit the
        // cmp (setting the flags) and branch on the condition directly, skipping
        // the materialised 0/1 bool and its cbnz. The cmp runs FIRST; the phi
        // copies are movs and loads, which do not touch the flags, so they may
        // clobber the cmp's scratch afterwards and the b.<cond> still reads
        // right.
        if (c.kind() == (u8)OPK_USE && c.val() != (IRValue*)0 && inMap(_fusedCmps, c.val())) {
            IRInsn* icmp = (IRInsn*)_fusedCmps.get((Hashable*)c.val());
            // `x == 0` / `x != 0` becomes cbz/cbnz directly, eliding the cmp #0
            // that gates the branch — the hot loop-control and null-check path.
            // Only when NEITHER out-edge needs phi copies: cbz reads a register
            // rather than the flags, so an intervening copy could clobber the
            // operand.
            IROperand* zval = icmpZeroTestValue(icmp);
            if (zval != (IROperand*)0
             && !phiCopiesNeeded(t, _bb) && !phiCopiesNeeded(f, _bb)) {
                String* vt = opType(zval);
                String* reg = operandReg(zval, String.withCString(needsXReg(vt) ? "x16" : "w16"));
                bool eq = icmp.pred() != (String*)0
                       && icmp.pred().equals(String.withCString("EQ"));
                _out.appendFormat("    %s %s, %s\n", eq ? "cbz" : "cbnz", reg.cString(),
                                  blockLabel(t).cString());
                _out.appendFormat("    b %s\n", blockLabel(f).cString());
                return;
            }
            String* cond = emitCompare(icmp);
            if (cond == (String*)0) { unsupported(String.withCString("ICmp:pred")); return; }
            if (takenPhiClobbersFallSrc(t, f, _bb)) {
                // The taken copies would clobber a value the fall copies read,
                // so they go on the taken path only — inverted, to skip to fall.
                String* lf = String.withCString(".Lpc_");
                lf.appendFormat("%lu", _labelCounter);
                _labelCounter = _labelCounter + (u32)1;
                _out.appendFormat("    b.%s %s\n",
                                  condString(negatePred(icmp.pred())).cString(), lf.cString());
                emitPhiCopies(_bb, t);
                _out.appendFormat("    b %s\n", blockLabel(t).cString());
                _out.appendFormat("%s:\n", lf.cString());
                emitPhiCopies(_bb, f);
                _out.appendFormat("    b %s\n", blockLabel(f).cString());
                return;
            }
            emitPhiCopies(_bb, t);
            _out.appendFormat("    b.%s %s\n", cond.cString(), blockLabel(t).cString());
            emitPhiCopies(_bb, f);
            _out.appendFormat("    b %s\n", blockLabel(f).cString());
            return;
        }
        // The taken-edge phi copies use w16/w17 as scratch, so they run BEFORE
        // the condition is materialised — otherwise a copy clobbers w16 and the
        // cbnz tests a stale value. Doing them unconditionally is safe unless a
        // taken-edge copy DESTINATION is a fall-edge copy SOURCE, in which case
        // the taken copies must run on the taken path only.
        if (takenPhiClobbersFallSrc(t, f, _bb)) {
            materialise(c, String.withCString("w16"));
            String* lf = String.withCString(".Lpc_");
            lf.appendFormat("%lu", _labelCounter);
            _labelCounter = _labelCounter + (u32)1;
            _out.appendFormat("    cbz w16, %s\n", lf.cString());
            emitPhiCopies(_bb, t);
            _out.appendFormat("    b %s\n", blockLabel(t).cString());
            _out.appendFormat("%s:\n", lf.cString());
            emitPhiCopies(_bb, f);
            _out.appendFormat("    b %s\n", blockLabel(f).cString());
            return;
        }
        emitPhiCopies(_bb, t);
        materialise(c, String.withCString("w16"));
        _out.appendFormat("    cbnz w16, %s\n", blockLabel(t).cString());
        emitPhiCopies(_bb, f);
        _out.appendFormat("    b %s\n", blockLabel(f).cString());
    }

    // ── Phi-edge copies ──────────────────────────────────────────────────
    //
    // A phi is realised by copies on each incoming edge, emitted just before
    // the terminator that takes it.
    void emitPhiCopies(IRBlock* from, IRBlock* to)
    {
        if (to == (IRBlock*)0) return;
        Array* phis = new Array();
        Array* srcs = new Array();
        for (u32 i = (u32)0; i < to.phis().count(); i = i + (u32)1) {
            IRInsn* phi = (IRInsn*)to.phis().get(i);
            if (!phi.op().equals(String.withCString("Phi"))) continue;
            // A vector phi is usually a reduction accumulator coalesced onto
            // one v-register at function-emit start (same register ⇒ no-op),
            // and must never route through the w16 scalar scratch below. But a
            // SHARED preheader incoming — one init splat feeding U accumulator
            // phis (#1198) — can coalesce with only ONE of them; the others
            // need a real full-width edge copy (orr = the v-to-v move). The
            // srcs are all the one shared register, so in-order emission
            // cannot lose a copy.
            if (phi.res() != (IRValue*)0 && isVecTy(phi.res().ty())) {
                IROperand* vsrc = phiSourceFrom(phi, from);
                if (vsrc != (IROperand*)0 && vsrc.kind() == (u8)OPK_USE) {
                    Object* dr = _vecReg.get((Hashable*)phi.res());
                    Object* sr = _vecReg.get((Hashable*)vsrc.val());
                    if (dr != (Object*)0 && sr != (Object*)0
                        && !((String*)dr).equals((String*)sr))
                        _out.appendFormat("    orr %s.16b, %s.16b, %s.16b\n",
                                          ((String*)dr).cString(),
                                          ((String*)sr).cString(),
                                          ((String*)sr).cString());
                }
                continue;
            }
            IROperand* src = phiSourceFrom(phi, from);
            if (src == (IROperand*)0) continue;
            phis.add((Object*)phi);
            srcs.add((Object*)src);
        }
        if (phis.count() == (u32)0) return;
        // The copies are a PARALLEL assignment. Emitting them in phi order
        // assumes no phi's incoming value is a SIBLING phi on the same edge,
        // and the loop unroller breaks that: an outer header gets `v <- i`
        // next to `i <- i+1`, and copying i first makes v read the NEW i.
        // So a copy whose result another pending copy reads goes last.
        Array* pending = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1) pending.add((Object*)phis.get(i));
        while (pending.count() > (u32)0) {
            u32 pick = (u32)$FFFF_FFFF;
            for (u32 i = (u32)0; i < phis.count() && pick == (u32)$FFFF_FFFF; i = i + (u32)1) {
                if (!isPending(pending, (IRInsn*)phis.get(i))) continue;
                IRValue* did = ((IRInsn*)phis.get(i)).res();
                bool blocked = false;
                for (u32 o = (u32)0; o < phis.count() && !blocked; o = o + (u32)1) {
                    if (o == i) continue;
                    if (!isPending(pending, (IRInsn*)phis.get(o))) continue;
                    IROperand* so = (IROperand*)srcs.get(o);
                    if (so.kind() == (u8)OPK_USE && so.val() == did) blocked = true;
                }
                if (!blocked) pick = i;
            }
            if (pick != (u32)$FFFF_FFFF) {
                emitOnePhiCopy((IRInsn*)phis.get(pick), (IROperand*)srcs.get(pick));
                removePending(pending, (IRInsn*)phis.get(pick));
                continue;
            }
            // Residual cycle: every pending copy's DEST is read by another
            // pending copy, so no single-step order is safe — a swap
            // `%a<-%b, %b<-%a` copied in place loses one value (bug 199:
            // loop-swapped class-pointer locals came back unchanged). A parallel
            // assignment sequentialises correctly by reading EVERY source into a
            // scratch register first, then writing every dest — SP is untouched,
            // so slot-homed members stay addressable. GP members use x15/x16/x17
            // (never home registers; spMemForOff's address temp is x9, so it
            // can't clobber them); FP members use s/d16..18. Aggregate cycles
            // (never seen — a struct phi lives in a slot, not a register swap)
            // and cycles wider than the scratch pool fall back to the in-place
            // single step, no worse than pre-fix.
            u32 gpNeed = (u32)0; u32 fpNeed = (u32)0; bool bail = false;
            for (u32 i = (u32)0; i < phis.count() && !bail; i = i + (u32)1) {
                if (!isPending(pending, (IRInsn*)phis.get(i))) continue;
                String* pty = ((IRInsn*)phis.get(i)).res().ty();
                if (isAggTy(pty)) { bail = true; }
                else if (isFloatTy(pty)) fpNeed = fpNeed + (u32)1;
                else gpNeed = gpNeed + (u32)1;
            }
            if (bail || gpNeed > (u32)3 || fpNeed > (u32)3) {
                u32 fb = (u32)$FFFF_FFFF;                 // last-resort single step
                for (u32 i = (u32)0; i < phis.count() && fb == (u32)$FFFF_FFFF; i = i + (u32)1)
                    if (isPending(pending, (IRInsn*)phis.get(i))) fb = i;
                emitOnePhiCopy((IRInsn*)phis.get(fb), (IROperand*)srcs.get(fb));
                removePending(pending, (IRInsn*)phis.get(fb));
                continue;
            }
            // Phase 1: read every source into its own scratch register.
            Array* staged = new Array();
            u32 gpUsed = (u32)0; u32 fpUsed = (u32)0;
            for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1) {
                if (!isPending(pending, (IRInsn*)phis.get(i))) continue;
                String* pty = ((IRInsn*)phis.get(i)).res().ty();
                String* reg;
                if (isFloatTy(pty)) { reg = phiCycleScratch(fpUsed, pty); fpUsed = fpUsed + (u32)1; }
                else { reg = phiCycleScratch(gpUsed, pty); gpUsed = gpUsed + (u32)1; }
                materialise((IROperand*)srcs.get(i), reg);
                staged.add((Object*)reg);
            }
            // Phase 2: write every dest from its scratch register.
            u32 si = (u32)0;
            for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1) {
                if (!isPending(pending, (IRInsn*)phis.get(i))) continue;
                storeReg((String*)staged.get(si), ((IRInsn*)phis.get(i)).res());
                si = si + (u32)1;
                removePending(pending, (IRInsn*)phis.get(i));
            }
        }
    }

    // Scratch register for a residual phi-copy cycle: slot 0..2. GP members ride
    // x15/x16/x17 (or w-views), FP members s/d16..18 — none is a home register,
    // so reading all sources then writing all dests cannot clobber a live value.
    static String* phiCycleScratch(u32 slot, String* pty)
    {
        if (isFloatTy(pty)) {
            bool d = pty.equals(String.withCString("F64"));
            if (slot == (u32)0) return String.withCString(d ? "d16" : "s16");
            if (slot == (u32)1) return String.withCString(d ? "d17" : "s17");
            return String.withCString(d ? "d18" : "s18");
        }
        bool x = needsXReg(pty);
        if (slot == (u32)0) return String.withCString(x ? "x15" : "w15");
        if (slot == (u32)1) return String.withCString(x ? "x16" : "w16");
        return String.withCString(x ? "x17" : "w17");
    }

    static bool isPending(Array* pending, IRInsn* n)
    {
        for (u32 i = (u32)0; i < pending.count(); i = i + (u32)1)
            if ((IRInsn*)pending.get(i) == n) return true;
        return false;
    }

    static void removePending(Array* pending, IRInsn* n)
    {
        for (u32 i = (u32)0; i < pending.count(); i = i + (u32)1)
            if ((IRInsn*)pending.get(i) == n) { pending.removeAt(i); return; }
    }

    // A phi's incoming value on the edge from `from`, or null when there
    // isn't one — the operands are (block, value) pairs.
    static IROperand* phiSourceFrom(IRInsn* phi, IRBlock* from)
    {
        for (u32 i = (u32)0; i + (u32)1 < phi.ops().count(); i = i + (u32)2) {
            IROperand* b = (IROperand*)phi.ops().get(i);
            if (b.kind() == (u8)OPK_BLOCK && b.blk() == from)
                return (IROperand*)phi.ops().get(i + (u32)1);
        }
        return (IROperand*)0;
    }

    void emitOnePhiCopy(IRInsn* phi, IROperand* vop)
    {
        String* pty = phi.res().ty();
        // An AGGREGATE phi is a slot-to-slot copy, not a register move.
        // Aggregates are never homed, so sizing a register from the phi's type
        // falls back to a 32-bit view and copies the FIRST FOUR BYTES — an
        // 8-byte Rect through a ternary kept its x,y and zeroed its w,h.
        // Compiles clean, naturally.
        if (isAggTy(pty)) {
            if (vop.kind() != (u8)OPK_USE || vop.val() == (IRValue*)0)
                { unsupported(String.withCString("Phi:AggConst")); return; }
            emitSpAddr(slotOf(vop.val()), String.withCString("x16"));
            emitAggCopy(aggSize(layoutOf(pty)), slotOf(phi.res()), true);
            return;
        }
        bool fp = isFloatTy(pty);
        Object* h = _home.get((Hashable*)phi.res());
        if (h != (Object*)0 && vop.kind() == (u8)OPK_USE) {
            // Homed result and an SSA use: materialise straight into the home.
            loadValue(vop.val(), homeView((String*)h, pty));
            return;
        }
        // Unhomed, or a constant operand (a float immediate has to build
        // through a GP register) — stage via scratch and let storeReg settle it.
        String* scratch = (fp && vop.kind() == (u8)OPK_USE)
            ? String.withCString(pty.equals(String.withCString("F64")) ? "d16" : "s16")
            : String.withCString(needsXReg(pty) ? "x16" : "w16");
        String* src = operandReg(vop, scratch);
        storeReg(src, phi.res());
    }

    // An `x == 0` / `x != 0` test (EQ/NE against an integer or pointer zero,
    // either an immediate or a use of a Const #0) returns the non-zero operand,
    // which is what cbz/cbnz tests. Null otherwise.
    IROperand* icmpZeroTestValue(IRInsn* icmp)
    {
        if (icmp == (IRInsn*)0 || icmp.ops().count() < (u32)2) return (IROperand*)0;
        String* pr = icmp.pred();
        if (pr == (String*)0) return (IROperand*)0;
        if (!pr.equals(String.withCString("EQ")) && !pr.equals(String.withCString("NE")))
            return (IROperand*)0;
        IROperand* o0 = (IROperand*)icmp.ops().get((u32)0);
        IROperand* o1 = (IROperand*)icmp.ops().get((u32)1);
        IROperand* val = (IROperand*)0;
        if (isZeroOperand(o1))      val = o0;
        else if (isZeroOperand(o0)) val = o1;
        if (val == (IROperand*)0) return (IROperand*)0;
        // cbz/cbnz are GP-register only. An ICmp never has float operands, but
        // guard anyway.
        if (isFloatTy(opType(val))) return (IROperand*)0;
        return val;
    }

    bool isZeroOperand(IROperand* o)
    {
        if (o.kind() == (u8)OPK_IMMI) return o.imm() == (i32)0;
        return isIntZeroConst(o);
    }

    // Whether branching from `from` to `target` needs edge copies at all.
    static bool phiCopiesNeeded(IRBlock* target, IRBlock* from)
    {
        if (target == (IRBlock*)0) return false;
        for (u32 i = (u32)0; i < target.phis().count(); i = i + (u32)1) {
            IRInsn* phi = (IRInsn*)target.phis().get(i);
            if (!phi.op().equals(String.withCString("Phi"))) continue;
            if (phiSourceFrom(phi, from) != (IROperand*)0) return true;
        }
        return false;
    }

    // Whether a taken-edge copy DESTINATION is a fall-edge copy SOURCE. When it
    // is, emitting the taken copies unconditionally would destroy a value the
    // fall copies still read — a rotated loop's `pb_i <- i+1` back-edge copy
    // wrecking the exit edge's `last <- pb_i`.
    static bool takenPhiClobbersFallSrc(IRBlock* t, IRBlock* f, IRBlock* from)
    {
        if (t == (IRBlock*)0 || f == (IRBlock*)0) return false;
        Array* dests = new Array();
        for (u32 i = (u32)0; i < t.phis().count(); i = i + (u32)1) {
            IRInsn* phi = (IRInsn*)t.phis().get(i);
            if (!phi.op().equals(String.withCString("Phi")) || phi.res() == (IRValue*)0) continue;
            if (phiSourceFrom(phi, from) != (IROperand*)0) dests.add((Object*)phi.res());
        }
        if (dests.count() == (u32)0) return false;
        for (u32 i = (u32)0; i < f.phis().count(); i = i + (u32)1) {
            IRInsn* phi = (IRInsn*)f.phis().get(i);
            if (!phi.op().equals(String.withCString("Phi"))) continue;
            IROperand* src = phiSourceFrom(phi, from);
            if (src == (IROperand*)0 || src.kind() != (u8)OPK_USE) continue;
            for (u32 k = (u32)0; k < dests.count(); k = k + (u32)1)
                if ((IRValue*)dests.get(k) == src.val()) return true;
        }
        return false;
    }

    // An integer constant, then canonicalised to its own type's range — a U8
    // Const is `mov` plus `uxtb`, because the mov writes the whole register and
    // the value must read back as a byte.
    void emitConst(IRInsn* n)
    {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) { unsupported(String.withCString("Const")); return; }
        // A non-homed small unsigned Const is rebuilt at each use, so its slot
        // definition is dead — nothing to emit.
        i32 ignored = (i32)0;
        if (rematConst(n.res(), &ignored)) return;
        IROperand* k = (IROperand*)n.ops().get((u32)0);
        String* ty = n.res().ty();
        if (isFloatTy(ty)) {
            // The immediate carries the abstract value as raw IEEE-754 double
            // bits, and this target is natively IEEE, so the pattern goes
            // straight to the slot. An F32 is the double narrowed first.
            //
            // A float-typed Const can also arrive spelled as an INTEGER zero
            // (`Const #0:F32`, the zero-initialiser form); its raw bits are
            // zero, which is what the reference reads off a non-float operand.
            String* hex = k.kind() == (u8)OPK_IMMF
                ? k.fpHex() : String.withCString("0000000000000000");
            if (ty.equals(String.withCString("F64"))) {
                emitBits64(hex, String.withCString("x16"));
                storeReg(String.withCString("x16"), n.res());
            } else {
                emitImm32(f32BitsOfDoubleHex(hex), String.withCString("w16"));
                storeReg(String.withCString("w16"), n.res());
            }
            return;
        }
        if (k.kind() != (u8)OPK_IMMI) { unsupported(String.withCString("Const:nonint")); return; }
        // The scratch is sized to the RESULT. Hardcoding w16 meant an UNHOMED
        // 64-bit constant materialised only its low half — materialise() picks
        // its 32-bit path from the register NAME — and storeReg then wrote four
        // bytes where the value is eight, so the next 8-byte load took its top
        // half from frame garbage. Invisible at -O2+, where the constant folds.
        String* dst = resultReg(n.res(), scratchName((u32)16, ty));
        materialise(k, dst);
        canonicalise(dst, ty);
        storeReg(dst, n.res());
    }

    // A 32-bit pattern into a w-register: movz, then movk for a non-zero high
    // half.
    void emitImm32(u32 bits, String* reg)
    {
        _out.appendFormat("    movz %s, #%lu\n", reg.cString(), bits & (u32)$FFFF);
        if ((bits >> (u32)16) != (u32)0)
            _out.appendFormat("    movk %s, #%lu, lsl #16\n",
                              reg.cString(), (bits >> (u32)16) & (u32)$FFFF);
    }

    // The IEEE-754 single-precision bits of a double given as 16 hex digits.
    // Done on the bit pattern rather than by arithmetic so it round-trips
    // exactly, and so a host without an f64 type still gets it right: rebias
    // the exponent by (127 - 1023) and take the top 23 mantissa bits.
    // Round-to-nearest-even, matching the C cast the original performs.
    static u32 f32BitsOfDoubleHex(String* hex)
    {
        u32 hi = (hexChunk(hex, (u32)0) << (u32)16) | hexChunk(hex, (u32)1);
        u32 lo = (hexChunk(hex, (u32)2) << (u32)16) | hexChunk(hex, (u32)3);
        u32 sign = (hi >> (u32)31) & (u32)1;
        u32 exp = (hi >> (u32)20) & (u32)$7FF;
        u32 mhi = hi & (u32)$F_FFFF;                  // top 20 mantissa bits
        if (exp == (u32)0 && mhi == (u32)0 && lo == (u32)0) return sign << (u32)31;
        if (exp == (u32)$7FF) {                       // inf / NaN
            u32 m = (mhi != (u32)0 || lo != (u32)0) ? (u32)1 : (u32)0;
            return (sign << (u32)31) | (u32)$7F80_0000 | (m << (u32)22);
        }
        i32 e = (i32)exp - (i32)1023 + (i32)127;
        if (e >= (i32)255) return (sign << (u32)31) | (u32)$7F80_0000;
        if (e <= (i32)0)   return sign << (u32)31;    // underflows to zero
        // 52 mantissa bits down to 23: keep the top 23, round on bit 29.
        u32 m23 = (mhi << (u32)3) | (lo >> (u32)29);
        u32 rest = lo & (u32)$1FFF_FFFF;
        u32 half = (u32)$1000_0000;
        bool up = rest > half || (rest == half && (m23 & (u32)1) != (u32)0);
        if (up) {
            m23 = m23 + (u32)1;
            if (m23 > (u32)$7F_FFFF) { m23 = (u32)0; e = e + (i32)1; }
            if (e >= (i32)255) return (sign << (u32)31) | (u32)$7F80_0000;
        }
        return (sign << (u32)31) | ((u32)e << (u32)23) | m23;
    }

    // Narrow the register to its type's range. A w-register write already
    // zero-extends to 64 bits, so only the sub-word types need masking.
    void canonicalise(String* reg, String* ty)
    {
        if (ty == (String*)0) return;
        if (ty.equals(String.withCString("U8")) || ty.equals(String.withCString("Bool")))
            _out.appendFormat("    uxtb %s, %s\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("U16")))
            _out.appendFormat("    uxth %s, %s\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("I8")))
            _out.appendFormat("    sxtb %s, %s\n", reg.cString(), reg.cString());
        else if (ty.equals(String.withCString("I16")))
            _out.appendFormat("    sxth %s, %s\n", reg.cString(), reg.cString());
    }

    bool isHomed(IRValue* v)
    { return _home.get((Hashable*)v) != (Object*)0; }

    // The value into x0 (or s0/d0, or the aggregate convention), then the
    // epilogue. Operands are [value, memInput], the value optional — so a
    // single operand is the memory token alone and there is nothing to return.
    void emitReturn(IRInsn* n)
    {
        if (n.ops().count() > (u32)1) {
            IROperand* v = (IROperand*)n.ops().get((u32)0);
            String* ty = (v.kind() == (u8)OPK_USE && v.val() != (IRValue*)0)
                ? v.val().ty() : (String*)0;
            if (isAggTy(ty)) {
                returnAggregate(v.val(), ty);
            } else if (isFloatTy(ty)) {
                loadValue(v.val(), fregName((u32)0, ty));
            } else {
                materialise(v, String.withCString(needsXReg(ty) ? "x0" : "w0"));
            }
        }
        emitEpilogue();
    }

    // AAPCS: an HFA returns in v0..v(n-1); a <=16-byte aggregate in x0:x1; a
    // larger non-HFA is written through the x8 pointer the caller passed, which
    // the prologue stowed.
    void returnAggregate(IRValue* v, String* ty)
    {
        IRLayout* l = layoutOf(ty);
        bool dbl = false;
        u32 hfa = aggHFA(l, &dbl);
        if (hfa > (u32)0) {
            for (u32 k = (u32)0; k < hfa; k = k + (u32)1) {
                String* r = String.withCString(dbl ? "d" : "s");
                r.appendFormat("%lu", k);
                loadSlotOffset(v, (dbl ? (u32)8 : (u32)4) * k, r);
            }
            return;
        }
        u32 sz = aggSize(l);
        if (sz > (u32)16 && _sretSaveOffset != (u32)0) {
            _out.appendFormat("    ldr x16, %s\n",
                              spMemForOff(_sretSaveOffset, String.withCString("x16")).cString());
            emitAggCopy(sz, slotOf(v), false);
            return;
        }
        emitSpAddr(slotOf(v), String.withCString("x16"));
        _out.appendCString("    ldr x0, [x16]\n");
        if (sz > (u32)8) _out.appendCString("    ldr x1, [x16, #8]\n");
    }

    void emitEpilogue(void)
    {
        emitCalleeSaves(true);
        if (_maxOutStack == (u32)0) {
            if (_frame <= (u32)504) {
                _out.appendFormat("    ldp x29, x30, [sp], #%lu\n", _frame);
            } else {
                _out.appendCString("    ldp x29, x30, [sp]\n");
                emitSpAdjust(_frame, false);
            }
        } else {
            if (_maxOutStack <= (u32)504) {
                _out.appendFormat("    ldp x29, x30, [sp, #%lu]\n", _maxOutStack);
            } else {
                _out.appendFormat("    add x9, sp, #%lu\n", _maxOutStack);
                _out.appendCString("    ldp x29, x30, [x9]\n");
            }
            emitSpAdjust(_frame, false);
        }
        _out.appendCString("    ret\n");
    }

    // ── Register naming ──────────────────────────────────────────────────
    //
    // A home register is stored canonically (x19, d8) and VIEWED at the width
    // the value's type needs: w-form for a narrow integer, x-form for a pointer
    // or 64-bit integer, s/d for float/double. The same physical register,
    // spelled to match the access.
    String* homeView(String* canon, String* ty)
    {
        String* num = canon.substringFromByte((u32)1);
        if (canon.hasPrefix(String.withCString("d"))
         || canon.hasPrefix(String.withCString("s"))) {
            String* o = String.withCString(
                ty != (String*)0 && ty.equals(String.withCString("F64")) ? "d" : "s");
            o.append(num);
            return o;
        }
        String* o = String.withCString(needsXReg(ty) ? "x" : "w");
        o.append(num);
        return o;
    }

    // Which values need the 64-bit x view. Pointers and memory tokens, and
    // nothing else — the original's irTypeNeedsXReg, matched exactly. An I64
    // therefore rides a w-register here too; widening it would be a change to
    // the code generator, not to its port.
    static bool needsXReg(String* ty)
    {
        if (ty == (String*)0) return false;
        // A 64-bit integer occupies a full X register, and the arithmetic
        // mnemonics are the same at both widths — so naming the register `x`
        // is most of what i64/u64 need on this target.
        return isPtrTy(ty) || isMemTy(ty)
            || ty.equals(String.withCString("I64"))
            || ty.equals(String.withCString("U64"));
    }

    // The scratch register (16 or 17) sized to a type.
    static String* scratchName(u32 n, String* ty)
    {
        String* o = String.withCString(needsXReg(ty) ? "x" : "w");
        o.appendFormat("%lu", n);
        return o;
    }

    // Move src to dst, choosing the mnemonic from the register classes: GP to
    // GP is `mov`, anything touching an FP register is `fmov`. Identical
    // registers emit nothing.
    void emitMove(String* dst, String* src)
    {
        if (dst.equals(src)) return;
        bool dFP = dst.hasPrefix(String.withCString("s")) || dst.hasPrefix(String.withCString("d"));
        bool sFP = src.hasPrefix(String.withCString("s")) || src.hasPrefix(String.withCString("d"));
        if (dFP || sFP) { _out.appendFormat("    fmov %s, %s\n", dst.cString(), src.cString()); return; }
        // `mov x, w` and `mov w, x` are illegal. When the widths differ, move
        // in w-form: writing w<n> zero-extends into the whole of x<n>, which is
        // the right semantics both for an unsigned narrow-to-wide widen and for
        // a wide-to-narrow low-word read.
        bool dX = dst.hasPrefix(String.withCString("x"));
        bool sX = src.hasPrefix(String.withCString("x"));
        if (dX != sX) {
            String* wd = dX ? wForm(dst) : dst;
            String* ws = sX ? wForm(src) : src;
            if (wd.equals(ws)) return;
            _out.appendFormat("    mov %s, %s\n", wd.cString(), ws.cString());
            return;
        }
        _out.appendFormat("    mov %s, %s\n", dst.cString(), src.cString());
    }

    static String* wForm(String* r)
    {
        String* o = String.withCString("w");
        o.append(r.substringFromByte((u32)1));
        return o;
    }

    // The register holding an operand, without a load where possible: a homed
    // use returns its home directly and emits nothing, so an op reads it in
    // place. Anything else is materialised into `scratch`.
    String* operandReg(IROperand* op, String* scratch)
    {
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0) {
            Object* h = _home.get((Hashable*)op.val());
            if (h != (Object*)0) return homeView((String*)h, op.val().ty());
        }
        materialise(op, scratch);
        return scratch;
    }

    // Where an op writes its result: its home register if it has one, so the
    // instruction lands straight in it with no store, else `scratch`, which the
    // caller then commits with storeReg.
    String* resultReg(IRValue* v, String* scratch)
    {
        Object* h = _home.get((Hashable*)v);
        if (h != (Object*)0) return homeView((String*)h, v.ty());
        return scratch;
    }

    void storeReg(String* reg, IRValue* v)
    {
        Object* h = _home.get((Hashable*)v);
        if (h != (Object*)0) { emitMove(homeView((String*)h, v.ty()), reg); return; }
        _out.appendFormat("    str %s, %s\n", reg.cString(),
                          spMemForOff(slotOf(v), reg).cString());
    }

    // Get an operand's value into a specific register.
    void materialise(IROperand* op, String* reg)
    {
        if (op.kind() == (u8)OPK_USE) { loadValue(op.val(), reg); return; }
        if (op.kind() == (u8)OPK_IMMI) {
            i64 v = op.imm();
            // A small non-negative immediate is one `mov`; anything else is
            // built 16 bits at a time with movz/movk — through the FULL 64
            // bits, because a wide literal reaches here now.
            if (v >= (i64)0 && v <= (i64)$FFFF) {
                _out.appendFormat("    mov %s, #%ld\n", reg.cString(), (i32)v);
            } else if (reg.hasPrefix(String.withCString("x"))) {
                // An X destination takes the FULL 64 bits, built 16 at a time.
                u64 bits = (u64)v;
                _out.appendFormat("    movz %s, #%lu\n", reg.cString(),
                                  (u32)(bits & (u64)$FFFF));
                u32 sh = (u32)16;
                while (sh < (u32)64) {
                    u32 chunk = (u32)((bits >> (u64)sh) & (u64)$FFFF);
                    if (chunk != (u32)0)
                        _out.appendFormat("    movk %s, #%lu, lsl #%lu\n",
                                          reg.cString(), chunk, sh);
                    sh = sh + (u32)16;
                }
            } else {
                // A W destination has no bits above 31, so `movk w, lsl #32`
                // is not a form — only the low two chunks exist.
                u32 bits = (u32)v;
                _out.appendFormat("    movz %s, #%lu\n", reg.cString(), bits & (u32)$FFFF);
                if ((bits >> (u32)16) != (u32)0)
                    _out.appendFormat("    movk %s, #%lu, lsl #16\n",
                                      reg.cString(), (bits >> (u32)16) & (u32)$FFFF);
            }
            return;
        }
        if (op.kind() == (u8)OPK_IMMF) {
            // A float immediate is spelled by its raw bits, so it is built into
            // the x-form of the register whole — a w-form movz would drop the
            // top half of a double.
            String* xr = reg.hasPrefix(String.withCString("w")) ? xForm(reg) : reg;
            emitBits64(op.fpHex(), xr);
            return;
        }
        unsupported(String.withCString("operand"));
    }

    static String* xForm(String* r)
    {
        String* o = String.withCString("x");
        o.append(r.substringFromByte((u32)1));
        return o;
    }

    // Build a 64-bit pattern, given as 16 hex digits, via movz plus a movk per
    // non-zero 16-bit chunk. The zero chunks are skipped exactly as the
    // original does — movz has already cleared them.
    void emitBits64(String* hex, String* xr)
    {
        u32 lo = hexChunk(hex, (u32)3);
        _out.appendFormat("    movz %s, #%lu\n", xr.cString(), lo);
        for (u32 c = (u32)2; ; c = c - (u32)1) {
            u32 v = hexChunk(hex, c);
            if (v != (u32)0)
                _out.appendFormat("    movk %s, #%lu, lsl #%lu\n",
                                  xr.cString(), v, ((u32)3 - c) * (u32)16);
            if (c == (u32)0) break;
        }
    }

    // Chunk 0 is the most significant 16 bits (the first four hex digits).
    static u32 hexChunk(String* hex, u32 chunk)
    {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1) {
            u32 idx = chunk * (u32)4 + i;
            if (idx >= hex.byteLength()) return v;
            u8 c = hex.byteAt(idx);
            u32 d = (u32)0;
            if (c >= (u8)'0' && c <= (u8)'9')      d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f') d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F') d = (u32)(c - (u8)'A') + (u32)10;
            v = v * (u32)16 + d;
        }
        return v;
    }

    // Read a value into `reg`: from its home register when it has one (its slot
    // is never written, so a slot load would be stale), by rematerialising a
    // small unsigned constant inline, else from its stack slot.
    void loadValue(IRValue* v, String* reg)
    {
        if (v == (IRValue*)0) { unsupported(String.withCString("operand")); return; }
        Object* h = _home.get((Hashable*)v);
        if (h != (Object*)0) { emitMove(reg, homeView((String*)h, v.ty())); return; }
        i32 imm = (i32)0;
        if (rematConst(v, &imm)) {
            _out.appendFormat("    mov %s, #%ld\n", reg.cString(), imm);
            return;
        }
        _out.appendFormat("    ldr %s, %s\n", reg.cString(),
                          spMemForOff(slotOf(v), reg).cString());
    }

    // A non-homed integer Const that materialises in a single `mov #imm`
    // already canonical for its type — so a use rebuilds it inline instead of
    // round-tripping through a stack slot. Unsigned only: `mov w,#v` with
    // v <= typeMax needs no uxt, whereas a signed type's sxt could differ from
    // the raw immediate.
    bool rematConst(IRValue* v, i32* out)
    {
        if (_home.get((Hashable*)v) != (Object*)0) return false;
        Object* d = _defOf.get((Hashable*)v);
        if (d == (Object*)0) return false;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("Const"))) return false;
        if (n.res() == (IRValue*)0) return false;
        String* k = n.res().ty();
        if (!(k.equals(String.withCString("U8")) || k.equals(String.withCString("U16"))
           || k.equals(String.withCString("U32")) || k.equals(String.withCString("Bool"))))
            return false;
        if (n.ops().count() < (u32)1) return false;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_IMMI) return false;
        i32 val = o.imm();
        u32 max = unsignedTypeMax(k);
        if (max > (u32)$FFFF) max = (u32)$FFFF;      // single-mov range
        if (val < (i32)0 || (u32)val > max) return false;
        *out = val;
        return true;
    }

    static u32 unsignedTypeMax(String* t)
    {
        if (t.equals(String.withCString("Bool")) || t.equals(String.withCString("U8")))
            return (u32)$FF;
        if (t.equals(String.withCString("U16"))) return (u32)$FFFF;
        return (u32)$FFFFFFFF;
    }

    // Print the homing decision, function by function: the callee-saved
    // registers the prologue would save, then each homed value's register.
    // This is how the allocator is checked before any emitter exists.
    void dumpHomes(IRModule* m)
    {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            _fn = fn;
            buildSlots(fn);
            scanUses(fn);
            computeIntervals(fn);
            assignRegisters(fn);
            fn.number();                 // stamp print ids so values are nameable
            Stdio.printf("%s: frame=%lu saved=[", fn.name().cString(), _frame);
            for (u32 i = (u32)0; i < _savedRegs.count(); i = i + (u32)1) {
                if (i > (u32)0) Stdio.printf(" ");
                Stdio.printf("%s", ((String*)_savedRegs.get(i)).cString());
            }
            Stdio.printf("]\n");
            Array* all = new Array();
            collectKeys(all, fn);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1) {
                IRValue* v = (IRValue*)all.get(i);
                Object* h = _home.get((Hashable*)v);
                if (h == (Object*)0) continue;
                Stdio.printf("    %%%ld -> %s\n", (i32)v.pid(),
                             ((String*)h).cString());
            }
        }
    }

    // ── Register homing ──────────────────────────────────────────────────
    //
    // arm64 does NOT use the shared XTHomingAllocator the A9, the 68000 and
    // x86-64 share — it has its own, and this is the port of that. Values used
    // inside a loop are the ones whose per-iteration reload dominates, so loop
    // membership (and nesting DEPTH) is the ranking signal rather than a static
    // use count: a value read once per innermost iteration of a nested loop
    // beats one read several times in the enclosing loop, because its dynamic
    // count is multiplied by the outer trip.
    Map*  _home;         // value -> register name
    Array* _savedRegs;   // the callee-saved homes, in prologue/epilogue order

    Map* homes(void) { return _home; }
    Array* savedRegs(void) { return _savedRegs; }

    // Back-edge nesting depth per block. A terminator edge whose target sits at
    // or before its source in declaration order is a back edge, and the
    // contiguous range [target..source] is that loop's body — this front end
    // emits loop bodies as contiguous ranges, so the approximation is tight.
    Array* blockDepths(IRFunc* fn)
    {
        Array* depth = new Array();
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            depth.add((Object*)Number.withU32((u32)0));
        for (u32 si = (u32)0; si < fn.blocks().count(); si = si + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(si);
            if (b.term() == (IRInsn*)0) continue;
            for (u32 k = (u32)0; k < b.term().ops().count(); k = k + (u32)1) {
                IROperand* o = (IROperand*)b.term().ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                u32 ti = blockIndexOf(fn, o.blk());
                if (ti > si) continue;                 // forward edge
                for (u32 b2 = ti; b2 <= si; b2 = b2 + (u32)1)
                    depth.set(b2, (Object*)Number.withU32(
                        ((Number*)depth.get(b2)).asU32() + (u32)1));
            }
        }
        return depth;
    }

    u32 blockIndexOf(IRFunc* fn, IRBlock* b)
    {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b) return i;
        return fn.blocks().count();
    }

    // Which values are eligible for a home, and how hot each is. Anything whose
    // address is taken has to stay in its slot; so does a memory token, an
    // aggregate, a void and a vector (those go to the NEON pool). A value
    // nothing reads is not worth a register. An `Asm` anywhere homes NOTHING —
    // the body refers to slots directly and cannot be told a value moved.
    Map*  _uses;        // value -> static use count
    Map*  _hotDepth;    // value -> deepest loop nesting it is read at
    Array* _addrTaken;  // values whose address escapes
    bool  _hasAsm;

    void scanUses(IRFunc* fn)
    {
        _uses = new Map();
        _hotDepth = new Map();
        _addrTaken = new Array();
        _hasAsm = false;
        Array* depth = blockDepths(fn);
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(bi);
            u32 d = ((Number*)depth.get(bi)).asU32();
            scanList(b.phis(), d);
            scanList(b.insns(), d);
            if (b.term() != (IRInsn*)0) scanInsn(b.term(), d);
        }
    }

    void scanList(Array* list, u32 d)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            scanInsn((IRInsn*)list.get(i), d);
    }

    void scanInsn(IRInsn* n, u32 d)
    {
        if (n.op().equals(String.withCString("Asm"))) _hasAsm = true;
        if (n.op().equals(String.withCString("AddrOf")) && n.ops().count() >= (u32)1) {
            IROperand* o = (IROperand*)n.ops().get((u32)0);
            if (o.kind() == (u8)OPK_USE && !hasVal(_addrTaken, o.val()))
                _addrTaken.add((Object*)o.val());
        }
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) continue;
            _uses.set((Hashable*)o.val(), (Object*)Number.withU32(useCount(o.val()) + (u32)1));
            if (d == (u32)0) continue;
            if (hotDepthOf(o.val()) < d)
                _hotDepth.set((Hashable*)o.val(), (Object*)Number.withU32(d));
        }
    }

    u32 useCount(IRValue* v)
    {
        Object* o = _uses.get((Hashable*)v);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
    }

    u32 hotDepthOf(IRValue* v)
    {
        Object* o = _hotDepth.get((Hashable*)v);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
    }

    static bool hasVal(Array* a, IRValue* v)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v) return true;
        return false;
    }

    // ── Live intervals ───────────────────────────────────────────────────
    //
    // A backward dataflow fixpoint (live-in / live-out per block), then one
    // interval per value. Positions are DOUBLED so a def and a use at the same
    // instruction can be told apart: a def sits at 2p+1 and a read at 2p, which
    // is what lets a value defined by an instruction share a register with one
    // that dies at it.
    Map* _start;        // value -> interval start
    Map* _end;          // value -> interval end
    Array* _phiRes;     // values defined by a phi
    Array* _crossCall;  // values live across a call
    Array* _callPos;    // undoubled positions of call-emitting instructions

    i32 startOf(IRValue* v)
    { Object* o = _start.get((Hashable*)v); return o == (Object*)0 ? (i32)0 : ((Number*)o).asI32(); }

    i32 endOf(IRValue* v)
    { Object* o = _end.get((Hashable*)v); return o == (Object*)0 ? (i32)0 : ((Number*)o).asI32(); }

    // Does this opcode emit a call, so that anything live across it must take a
    // callee-saved home? Direct calls plus the opcodes arm64 lowers to a hidden
    // runtime `bl`. Note what is NOT here: Retain is inlined, ProtoDispatch
    // does not reach this backend, and the divides are hardware instructions —
    // guessing any of those in would wrongly push values out of the
    // caller-saved tier and change which registers get used.
    static bool emitsCall(String* op)
    {
        return op.equals(String.withCString("Call"))
            || op.equals(String.withCString("CallBanked"))
            || op.equals(String.withCString("CallCloaked"))
            || op.equals(String.withCString("CallIndirect"))
            || op.equals(String.withCString("CallBankedIndirect"))
            || op.equals(String.withCString("VTblDispatch"))
            || op.equals(String.withCString("MemCopy"))
            || op.equals(String.withCString("MemSet"))
            || op.equals(String.withCString("Release"))
            || op.equals(String.withCString("Autorelease"))
            || op.equals(String.withCString("WeakRegister"))
            || op.equals(String.withCString("WeakUnregister"))
            || op.equals(String.withCString("WeakLoad"));
    }

    // The backward dataflow. Per block: the values it defines, its
    // upward-exposed uses, the phi results it holds, and the values its
    // SUCCESSORS' phis read along the edge from it. Then live-in / live-out to
    // a fixpoint, and one interval per value.
    void computeIntervals(IRFunc* fn)
    {
        _start = new Map();
        _end = new Map();
        _phiRes = new Array();
        _crossCall = new Array();
        _callPos = new Array();
        u32 nb = fn.blocks().count();
        if (nb == (u32)0) return;

        Array* defSet = new Array();
        Array* ueUse = new Array();
        Array* phiResAt = new Array();
        Array* phiEdge = new Array();
        Array* blkEnd = new Array();
        for (u32 i = (u32)0; i < nb; i = i + (u32)1) {
            defSet.add((Object*)new Array());   ueUse.add((Object*)new Array());
            phiResAt.add((Object*)new Array()); phiEdge.add((Object*)new Array());
            blkEnd.add((Object*)Number.withI32((i32)0));
        }
        _defPos = new Map();
        _lastUse = new Map();
        numberBlocks(fn, nb, defSet, ueUse, phiResAt, blkEnd);
        buildPhiEdges(fn, nb, phiEdge);
        Array* succIdx = buildSuccIdx(fn, nb);
        Array* liveOut = solveLiveness(nb, defSet, ueUse, phiResAt, phiEdge, succIdx);
        finishIntervals(fn, nb, blkEnd, liveOut);
        _blkEnd = blkEnd;   // slot colouring needs the loop spans (see buildSlots)
    }

    Map* _defPos;
    Map* _lastUse;
    Array* _blkEnd;      // each block's LAST undoubled position

    // Walk the blocks once, numbering every instruction and recording defs,
    // upward-exposed uses, phi results and call positions.
    void numberBlocks(IRFunc* fn, u32 nb, Array* defSet, Array* ueUse,
                      Array* phiResAt, Array* blkEnd)
    {
        Map* defPos = _defPos;
        Map* lastUse = _lastUse;
        i32 pos = (i32)0;
        for (u32 bi = (u32)0; bi < nb; bi = bi + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(bi);
            Array* defs = (Array*)defSet.get(bi);
            Array* ue = (Array*)ueUse.get(bi);
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1) {
                IRInsn* p = (IRInsn*)b.phis().get(i);
                if (p.res() != (IRValue*)0) {
                    defPos.set((Hashable*)p.res(), (Object*)Number.withI32(pos));
                    addVal(defs, p.res());
                    addVal((Array*)phiResAt.get(bi), p.res());
                    addVal(_phiRes, p.res());
                }
                pos = pos + (i32)1;      // a phi's operands are EDGE uses, below
            }
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)b.insns().get(i);
                noteUses(n, defs, ue, lastUse, pos);
                if (emitsCall(n.op())) _callPos.add((Object*)Number.withI32(pos));
                if (n.res() != (IRValue*)0) {
                    defPos.set((Hashable*)n.res(), (Object*)Number.withI32(pos));
                    addVal(defs, n.res());
                }
                pos = pos + (i32)1;
            }
            if (b.term() != (IRInsn*)0) {
                noteUses(b.term(), defs, ue, lastUse, pos);
                if (emitsCall(b.term().op())) _callPos.add((Object*)Number.withI32(pos));
                pos = pos + (i32)1;
            }
            blkEnd.set(bi, (Object*)Number.withI32(pos - (i32)1));
        }
    }

    Array* buildSuccIdx(IRFunc* fn, u32 nb)
    {
        Array* succIdx = new Array();
        for (u32 bi = (u32)0; bi < nb; bi = bi + (u32)1) {
            Array* s = new Array();
            IRInsn* t = ((IRBlock*)fn.blocks().get(bi)).term();
            if (t != (IRInsn*)0)
                for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)t.ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                    u32 si = blockIndexOf(fn, o.blk());
                    if (si < nb) s.add((Object*)Number.withU32(si));
                }
            succIdx.add((Object*)s);
        }
        return succIdx;
    }

    // A successor's phi reads its incoming value on the edge FROM this block,
    // so that value is live out of the predecessor even though the predecessor
    // never mentions it.
    void buildPhiEdges(IRFunc* fn, u32 nb, Array* phiEdge)
    {
        for (u32 si = (u32)0; si < nb; si = si + (u32)1) {
            IRBlock* sb = (IRBlock*)fn.blocks().get(si);
            for (u32 i = (u32)0; i < sb.phis().count(); i = i + (u32)1) {
                IRInsn* phi = (IRInsn*)sb.phis().get(i);
                for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2) {
                    IROperand* bo = (IROperand*)phi.ops().get(k);
                    IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                    if (bo.kind() != (u8)OPK_BLOCK || bo.blk() == (IRBlock*)0) continue;
                    if (vo.kind() != (u8)OPK_USE) continue;
                    u32 pb = blockIndexOf(fn, bo.blk());
                    if (pb < nb) addVal((Array*)phiEdge.get(pb), vo.val());
                }
            }
        }

    }

    Array* solveLiveness(u32 nb, Array* defSet, Array* ueUse, Array* phiResAt,
                         Array* phiEdge, Array* succIdx)
    {
        Array* liveIn = new Array();
        Array* liveOut = new Array();
        for (u32 i = (u32)0; i < nb; i = i + (u32)1) {
            liveIn.add((Object*)new Array());
            liveOut.add((Object*)new Array());
        }
        bool changed = true;
        while (changed) {
            changed = false;
            for (u32 r = nb; r > (u32)0; r = r - (u32)1) {
                u32 bi = r - (u32)1;
                Array* out = copyVals((Array*)phiEdge.get(bi));
                Array* ss = (Array*)succIdx.get(bi);
                for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1) {
                    u32 sn = ((Number*)ss.get(k)).asU32();
                    Array* sin = copyVals((Array*)liveIn.get(sn));
                    minusVals(sin, (Array*)phiResAt.get(sn));
                    unionVals(out, sin);
                }
                Array* inn = copyVals((Array*)ueUse.get(bi));
                Array* od = copyVals(out);
                minusVals(od, (Array*)defSet.get(bi));
                unionVals(inn, od);
                if (!sameVals(out, (Array*)liveOut.get(bi))
                 || !sameVals(inn, (Array*)liveIn.get(bi))) {
                    liveOut.set(bi, (Object*)out);
                    liveIn.set(bi, (Object*)inn);
                    changed = true;
                }
            }
        }

        return liveOut;
    }

    // A value's interval ends at the later of its last read and the end of any
    // block it is live out of.
    void finishIntervals(IRFunc* fn, u32 nb, Array* blkEnd, Array* liveOut)
    {
        Map* defPos = _defPos;
        Map* lastUse = _lastUse;
        Map* endByVal = new Map();
        Array* all = new Array();
        for (u32 bi = (u32)0; bi < nb; bi = bi + (u32)1) {
            i32 be = (i32)2 * ((Number*)blkEnd.get(bi)).asI32() + (i32)2;
            Array* lo = (Array*)liveOut.get(bi);
            for (u32 k = (u32)0; k < lo.count(); k = k + (u32)1) {
                IRValue* v = (IRValue*)lo.get(k);
                Object* cur = endByVal.get((Hashable*)v);
                if (cur == (Object*)0 || be > ((Number*)cur).asI32())
                    endByVal.set((Hashable*)v, (Object*)Number.withI32(be));
                addVal(all, v);
            }
        }
        collectKeys(all, fn);

        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)all.get(i);
            Object* dp = defPos.get((Hashable*)v);
            // No def position means a parameter or an entry-live value: its
            // interval starts at 0.
            i32 st = dp == (Object*)0 ? (i32)0
                   : (i32)2 * ((Number*)dp).asI32() + (i32)1;
            i32 en = st;
            Object* lu = lastUse.get((Hashable*)v);
            if (lu != (Object*)0) {
                i32 e2 = (i32)2 * ((Number*)lu).asI32();
                if (e2 > en) en = e2;
            }
            Object* eb = endByVal.get((Hashable*)v);
            if (eb != (Object*)0) {
                i32 e3 = ((Number*)eb).asI32();
                if (e3 > en) en = e3;
            }
            _start.set((Hashable*)v, (Object*)Number.withI32(st));
            _end.set((Hashable*)v, (Object*)Number.withI32(en));
            for (u32 c = (u32)0; c < _callPos.count(); c = c + (u32)1) {
                i32 cp = (i32)2 * ((Number*)_callPos.get(c)).asI32();
                if (st <= cp && cp <= en) { addVal(_crossCall, v); break; }
            }
        }
    }

    // Every value the function mentions, so a value whose ONLY consumer is a
    // phi-edge operand still gets a real interval. Such a value has no body def
    // position and no body last-use; left at the default point interval [0,0]
    // it would be judged not to overlap a value defined in that same
    // predecessor, the two would share a register, and the second def would
    // clobber the first before the edge copy read it.
    // Candidates in VALUE-ID order, which is what the allocator's tie-break
    // resolves to: two values of equal hotness and use count are ranked by the
    // lower id. Program order is a different order — a phi and the value that
    // feeds it can be numbered either way round — and the sort is stable, so
    // getting this wrong quietly swaps two registers.
    // Every value the function CONTAINS, in the order the IR printer numbers
    // them: params, pinned locals, then all results and memory-results in block
    // order, then operand-only uses. This is bug 065's ordering, and it is the
    // one order both compilers can agree on — the port reads the printed text,
    // so anything keyed off creation order ties differently for the same
    // program. It feeds BOTH consumers: the frame-slot walk and the register
    // allocator's candidate list, whose insertion sort is stable and therefore
    // breaks equal-hotness ties in exactly this order (which is what the
    // original spells out explicitly in its byUsesDesc comparator).
    //
    // It used to be "every parsed id, then fresh values by creation seq". That
    // over-counted — an id present in the table but nowhere in the function
    // still took a frame slot — and it tied the wrong way in the allocator.
    void collectKeys(Array* all, IRFunc* fn)
    {
        Map* seen = new Map();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            seen.set((Hashable*)all.get(i), all.get(i));
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            seeVal(all, seen, (IRValue*)fn.params().get(i));
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            seeVal(all, seen, ((IRPinned*)fn.pinned().get(i)).val());
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            seeResults(all, seen, blockInsns((IRBlock*)fn.blocks().get(b)));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            seeUses(all, seen, blockInsns((IRBlock*)fn.blocks().get(b)));
    }

    void collectFreshKeys(Array* fresh, IRFunc* fn, Array* known)
    {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            noteFreshKey(fresh, known, (IRValue*)fn.params().get(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            freshKeysIn(fresh, known, bb.phis());
            freshKeysIn(fresh, known, bb.insns());
            if (bb.term() != (IRInsn*)0) freshKeysOne(fresh, known, bb.term());
        }
    }

    void freshKeysIn(Array* fresh, Array* known, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            freshKeysOne(fresh, known, (IRInsn*)list.get(i));
    }

    void freshKeysOne(Array* fresh, Array* known, IRInsn* n)
    {
        noteFreshKey(fresh, known, n.res());
        noteFreshKey(fresh, known, n.memRes());
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE) noteFreshKey(fresh, known, o.val());
        }
    }

    static void noteFreshKey(Array* fresh, Array* known, IRValue* v)
    {
        if (v == (IRValue*)0) return;
        if (hasVal(known, v) || hasVal(fresh, v)) return;
        fresh.add((Object*)v);
    }

    void collectFrom(Array* all, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            collectOne(all, (IRInsn*)list.get(i));
    }

    void collectOne(Array* all, IRInsn* n)
    {
        if (n.res() != (IRValue*)0) addVal(all, n.res());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0) addVal(all, o.val());
        }
    }

    void noteUses(IRInsn* n, Array* defs, Array* ue, Map* lastUse, i32 pos)
    {
        noteOperands(n, defs, ue, lastUse, pos);
        if (n.ops().count() < (u32)1) return;
        IROperand* p0 = (IROperand*)n.ops().get((u32)0);
        if (p0.kind() != (u8)OPK_USE || p0.val() == (IRValue*)0) return;
        // A Load/Store that folds its FieldAddr/ElementAddr pointer reads that
        // address op's base (and index) at THIS position — the computation moves
        // down to here. Without extending those ranges the allocator sees the
        // index die at the now-elided address op and reuses its register for
        // something defined before the load, clobbering it.
        Object* fa = _foldInfo.get((Hashable*)p0.val());
        if (fa != (Object*)0) noteOperands((IRInsn*)fa, defs, ue, lastUse, pos);
        // A CondBranch that fuses its ICmp re-emits the cmp here, so the ICmp's
        // operands are read at THIS position, not the elided ICmp's. Same
        // hazard: a value defined between the two would otherwise take an
        // operand's register.
        if (n.op().equals(String.withCString("CondBranch")) && inMap(_fusedCmps, p0.val()))
            noteOperands((IRInsn*)_fusedCmps.get((Hashable*)p0.val()), defs, ue, lastUse, pos);
    }

    void noteOperands(IRInsn* n, Array* defs, Array* ue, Map* lastUse, i32 pos)
    {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) continue;
            if (!hasVal(defs, o.val())) addVal(ue, o.val());
            lastUse.set((Hashable*)o.val(), (Object*)Number.withI32(pos));
        }
    }

    static void addVal(Array* a, IRValue* v)
    { if (v != (IRValue*)0 && !hasVal(a, v)) a.add((Object*)v); }

    static Array* copyVals(Array* a)
    {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1) o.add(a.get(i));
        return o;
    }

    static void unionVals(Array* a, Array* b)
    {
        for (u32 i = (u32)0; i < b.count(); i = i + (u32)1) addVal(a, (IRValue*)b.get(i));
    }

    static void minusVals(Array* a, Array* b)
    {
        for (u32 i = a.count(); i > (u32)0; i = i - (u32)1)
            if (hasVal(b, (IRValue*)a.get(i - (u32)1))) a.removeAt(i - (u32)1);
    }

    static bool sameVals(Array* a, Array* b)
    {
        if (a.count() != b.count()) return false;
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!hasVal(b, (IRValue*)a.get(i))) return false;
        return true;
    }

    // ── Register assignment ──────────────────────────────────────────────
    //
    // Greedy in priority order, letting values whose live ranges do NOT overlap
    // share a register. Two tiers: the caller-saved x10-x14 first, because a
    // home there needs no prologue save, then the callee-saved x19-x27. A value
    // live across a call may only take the callee-saved tier.
    //
    // A phi result takes a register exclusively. Its register is written by the
    // predecessor-edge copies, whose timing the interval model does not track,
    // so sharing it with anything would be unsound.
    void assignRegisters(IRFunc* fn)
    {
        _home = new Map();
        _savedRegs = new Array();
        if (_hasAsm) return;      // an Asm body reads slots directly: home nothing

        // The callee-save area sits just past the value slots, and a 64-bit
        // scaled immediate reaches 32760, so a big slot region pushes it out of
        // range. This used to give up on homing entirely at that point — which
        // meant a function holding a few large arrays on the stack got NO
        // register allocation at all, and reloaded even a loop-invariant base
        // pointer from its slot every iteration. emitCalleeSaves already stages
        // an out-of-range save or restore through x9, so there is nothing left
        // to protect against; the frame ceiling in buildSlotTable is the bound.

        Array* gp = new Array();
        Array* fp = new Array();
        selectCandidates(fn, gp, fp);
        sortByHotness(gp);
        sortByHotness(fp);

        Array* gpCallee = new Array();
        gpCallee.add((Object*)String.withCString("x19"));
        gpCallee.add((Object*)String.withCString("x20"));
        gpCallee.add((Object*)String.withCString("x21"));
        gpCallee.add((Object*)String.withCString("x22"));
        gpCallee.add((Object*)String.withCString("x23"));
        gpCallee.add((Object*)String.withCString("x24"));
        gpCallee.add((Object*)String.withCString("x25"));
        gpCallee.add((Object*)String.withCString("x26"));
        gpCallee.add((Object*)String.withCString("x27"));
        // x9 is the large-frame sp-adjust temp, x15-x17 the load/op/store
        // scratch and x8 the indirect-result register, so the caller-saved
        // tier is exactly x10-x14.
        Array* gpCaller = new Array();
        gpCaller.add((Object*)String.withCString("x10"));
        gpCaller.add((Object*)String.withCString("x11"));
        gpCaller.add((Object*)String.withCString("x12"));
        gpCaller.add((Object*)String.withCString("x13"));
        gpCaller.add((Object*)String.withCString("x14"));
        Array* fpCallee = new Array();
        fpCallee.add((Object*)String.withCString("d8"));
        fpCallee.add((Object*)String.withCString("d9"));
        fpCallee.add((Object*)String.withCString("d10"));
        fpCallee.add((Object*)String.withCString("d11"));
        fpCallee.add((Object*)String.withCString("d12"));
        fpCallee.add((Object*)String.withCString("d13"));
        fpCallee.add((Object*)String.withCString("d14"));
        fpCallee.add((Object*)String.withCString("d15"));
        // There is no FP caller-saved tier: v0-v15 are FP scratch and v16-v31
        // are the auto-vectoriser's pool.
        Array* fpCaller = new Array();

        assignTier(gp, gpCallee, gpCaller);
        assignTier(fp, fpCallee, fpCaller);
        sortSaved(gpCallee, fpCallee);
        coalescePhiInputs(fn, gpCaller, fpCaller);
    }

    // ── Phi-input coalescing ─────────────────────────────────────────────
    //
    // A loop-carried accumulator `v = phi + x` computes the new value in
    // scratch, spills it, and the back-edge phi copy reloads it into the phi's
    // home R — a spill and a reload every iteration, plus a spill across any
    // call in between. Giving v the SAME home R produces it straight into R and
    // collapses the back-edge copy to the no-op move the phi emitter already
    // drops. Allocation only; nothing about emission changes.
    //
    // Soundness rests on REGISTER liveness, not SSA liveness. Inside the body R
    // holds the current-iteration value P up to the instruction that makes v
    // (which reads P, then writes R), after which P must not be read again in
    // the body. A use of P outside the body is a loop-exit read of the carried
    // value, and after the loop R holds the final v — so those reads are
    // satisfied by R too.
    void coalescePhiInputs(IRFunc* fn, Array* gpCaller, Array* fpCaller)
    {
        u32 nb = fn.blocks().count();
        // Definition block, per value, so "defined inside the loop body" is a
        // question about block indices.
        Map* defBlk = new Map();
        for (u32 bi = (u32)0; bi < nb; bi = bi + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(bi);
            noteDefBlocks(defBlk, b.phis(), bi);
            noteDefBlocks(defBlk, b.insns(), bi);
            if (b.term() != (IRInsn*)0 && b.term().res() != (IRValue*)0)
                defBlk.set((Hashable*)b.term().res(), (Object*)Number.with((i32)bi));
        }
        Array* coalesced = new Array();
        for (u32 si = (u32)0; si < nb; si = si + (u32)1) {
            IRBlock* src = (IRBlock*)fn.blocks().get(si);
            IRInsn* term = src.term();
            if (term == (IRInsn*)0) continue;
            for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1) {
                IROperand* to = (IROperand*)term.ops().get(k);
                if (to.kind() != (u8)OPK_BLOCK || to.blk() == (IRBlock*)0) continue;
                i32 ti = blockIndexOf(fn, to.blk());
                if (ti < (i32)0 || (u32)ti > si) continue;      // not a back edge
                IRBlock* header = to.blk();
                for (u32 pi = (u32)0; pi < header.phis().count(); pi = pi + (u32)1) {
                    IRInsn* phi = (IRInsn*)header.phis().get(pi);
                    if (phi.res() == (IRValue*)0) continue;
                    if (hasVal(coalesced, phi.res())) continue;
                    Object* rh = _home.get((Hashable*)phi.res());
                    if (rh == (Object*)0) continue;             // the phi is unhomed
                    String* R = (String*)rh;
                    IROperand* vo = phiSourceFrom(phi, src);
                    if (vo == (IROperand*)0 || vo.kind() != (u8)OPK_USE) continue;
                    IRValue* vIn = vo.val();
                    if (vIn == (IRValue*)0 || vIn == phi.res()) continue;
                    // v may already have a home: re-home it onto R, which is
                    // exclusive to the phi so nothing else contends. Not if it
                    // is itself a phi result, though — that is a nested
                    // accumulator, and taking its register just pushes the copy
                    // inward.
                    Object* vh = _home.get((Hashable*)vIn);
                    if (vh != (Object*)0) {
                        if (((String*)vh).equals(R)) continue;
                        if (hasVal(_phiRes, vIn)) continue;
                    }
                    if (hasVal(_addrTaken, vIn)) continue;
                    String* vt = vIn.ty();
                    if (vt == (String*)0) continue;
                    if (isMemTy(vt) || isAggTy(vt) || vt.equals(String.withCString("Void"))) continue;
                    if (isFPReg(R) != isFloatTy(vt)) continue;
                    Object* db = defBlk.get((Hashable*)vIn);
                    if (db == (Object*)0) continue;
                    i32 dbi = ((Number*)db).asI32();
                    if (dbi < ti || dbi > (i32)si) continue;    // must be in the body
                    // PRECISE interference. With doubled positions the back-edge
                    // value `v = P op x` is defined exactly at P's last read, so
                    // v.start = 2p+1 > P.end = 2p and the two are disjoint —
                    // while a value still live past the step (a pointer whose OLD
                    // value is dereferenced after `p = p.next`) overlaps and is
                    // rejected.
                    if (!hasIvl(phi.res()) || !hasIvl(vIn)) continue;
                    i32 ps = ivlStart(phi.res());
                    i32 pe = ivlEnd(phi.res());
                    i32 vs = ivlStart(vIn);
                    i32 ve = ivlEnd(vIn);
                    if (vs <= pe && ps <= ve) continue;         // they overlap
                    // A caller-saved phi home is only safe for v when v crosses
                    // no call: a call AFTER the phi's last body use leaves the
                    // phi caller-saveable but can still sit inside v's range.
                    if (hasVal(_crossCall, vIn)
                     && (hasStr(gpCaller, R) || hasStr(fpCaller, R))) continue;
                    _home.set((Hashable*)vIn, (Object*)R);
                    addVal(coalesced, phi.res());
                }
            }
        }
    }

    static void noteDefBlocks(Map* m, Array* list, u32 bi)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1) {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() != (IRValue*)0) m.set((Hashable*)n.res(), (Object*)Number.with((i32)bi));
        }
    }

    bool hasIvl(IRValue* v)
    { return _start.get((Hashable*)v) != (Object*)0 && _end.get((Hashable*)v) != (Object*)0; }

    i32 ivlStart(IRValue* v) { return ((Number*)_start.get((Hashable*)v)).asI32(); }
    i32 ivlEnd(IRValue* v)   { return ((Number*)_end.get((Hashable*)v)).asI32(); }

    // Eligible values. Address-taken stays in its slot (something reads it
    // through a pointer); memory tokens, aggregates, voids and vectors are not
    // GP/FP scalars; a value nothing reads is not worth a register.
    //
    // A float is homed ONLY when it is loop-resident. Float homes live in
    // d8-d15, but feeding and retrieving them across call boundaries needs a
    // GP<->FP fmov each way, and in straight-line float code those brackets
    // cost more than the slot traffic they replace. A loop-carried FP
    // accumulator is the case where the per-iteration reload saved dwarfs the
    // one-time bracket. GP values have no such penalty, so they are not gated.
    void selectCandidates(IRFunc* fn, Array* gp, Array* fp)
    {
        Array* all = new Array();
        collectKeys(all, fn);
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)all.get(i);
            String* t = v.ty();
            if (t == (String*)0) continue;
            if (hasVal(_addrTaken, v)) continue;
            if (isMemTy(t) || isAggTy(t) || isVecTy(t)
                || t.equals(String.withCString("Void"))) continue;
            if (useCount(v) == (u32)0) continue;
            if (isFloatTy(t)) {
                if (hotDepthOf(v) > (u32)0) fp.add((Object*)v);
            } else {
                gp.add((Object*)v);
            }
        }
    }

    // Deepest loop use first, then static use count. Insertion sort: the
    // candidate lists are register-pool sized in practice.
    void sortByHotness(Array* a)
    {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)a.get(i);
            u32 j = i;
            while (j > (u32)0 && hotter(v, (IRValue*)a.get(j - (u32)1))) {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
            }
            a.set(j, (Object*)v);
        }
    }

    bool hotter(IRValue* a, IRValue* b)
    {
        u32 da = hotDepthOf(a);
        u32 db = hotDepthOf(b);
        if (da != db) return da > db;
        return useCount(a) > useCount(b);
    }


    // One tier pass. Registers are tried caller-saved first (no prologue save
    // needed) then callee-saved; a value live across a call skips the caller
    // tier entirely. A register may be shared by values whose intervals do not
    // overlap — which is what lets an unrolled serial chain, each link dead
    // once the next is computed, pack onto one or two registers instead of
    // spilling around the calls between them.
    void assignTier(Array* cands, Array* callee, Array* caller)
    {
        Array* regs = new Array();
        for (u32 i = (u32)0; i < caller.count(); i = i + (u32)1) regs.add(caller.get(i));
        for (u32 i = (u32)0; i < callee.count(); i = i + (u32)1) regs.add(callee.get(i));
        u32 nCaller = caller.count();

        // Per register: the intervals already placed there, and whether a phi
        // has claimed it exclusively.
        Array* lo = new Array();
        Array* hi = new Array();
        Array* excl = new Array();
        for (u32 i = (u32)0; i < regs.count(); i = i + (u32)1) {
            lo.add((Object*)new Array());
            hi.add((Object*)new Array());
            excl.add((Object*)Number.withU32((u32)0));
        }

        for (u32 c = (u32)0; c < cands.count(); c = c + (u32)1) {
            IRValue* v = (IRValue*)cands.get(c);
            i32 s = startOf(v);
            i32 e = endOf(v);
            bool isPhi = hasVal(_phiRes, v);
            bool mayCaller = !hasVal(_crossCall, v);
            u32 chosen = regs.count();
            for (u32 r = (u32)0; r < regs.count(); r = r + (u32)1) {
                if (!mayCaller && r < nCaller) continue;
                if (((Number*)excl.get(r)).asU32() != (u32)0) continue;
                Array* rlo = (Array*)lo.get(r);
                if (isPhi) {
                    // A phi's register is written by the predecessor-edge
                    // copies, whose timing the interval model does not model,
                    // so it must be untouched by anything else.
                    if (rlo.count() == (u32)0) { chosen = r; break; }
                    continue;
                }
                Array* rhi = (Array*)hi.get(r);
                bool ok = true;
                for (u32 k = (u32)0; k < rlo.count(); k = k + (u32)1) {
                    i32 s2 = ((Number*)rlo.get(k)).asI32();
                    i32 e2 = ((Number*)rhi.get(k)).asI32();
                    if (s <= e2 && s2 <= e) { ok = false; break; }
                }
                if (ok) { chosen = r; break; }
            }
            if (chosen == regs.count()) continue;      // unhomed: stays in its slot
            String* reg = (String*)regs.get(chosen);
            _home.set((Hashable*)v, (Object*)reg);
            ((Array*)lo.get(chosen)).add((Object*)Number.withI32(s));
            ((Array*)hi.get(chosen)).add((Object*)Number.withI32(e));
            if (isPhi) excl.set(chosen, (Object*)Number.withU32((u32)1));
            if (chosen >= nCaller && !hasStr(_savedRegs, reg))
                _savedRegs.add((Object*)reg);
        }
    }

    // The prologue and every epilogue walk _savedRegs together, so the order
    // has to be stable rather than discovery order.
    void sortSaved(Array* gpCallee, Array* fpCallee)
    {
        Array* sorted = new Array();
        for (u32 i = (u32)0; i < gpCallee.count(); i = i + (u32)1)
            if (hasStr(_savedRegs, (String*)gpCallee.get(i))) sorted.add(gpCallee.get(i));
        for (u32 i = (u32)0; i < fpCallee.count(); i = i + (u32)1)
            if (hasStr(_savedRegs, (String*)fpCallee.get(i))) sorted.add(fpCallee.get(i));
        _savedRegs = sorted;
    }

    static bool hasStr(Array* a, String* s)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s)) return true;
        return false;
    }

    // Each value gets max(8, round8(width)) bytes: 8 for every scalar and
    // pointer, and the rounded aggregate size for an aggregate, so a
    // multi-field tuple fits its slot instead of running into the next one.
    // The outgoing-argument area sits at the bottom of the frame, below the
    // saved x29/x30, for any call that passes past x0..x7 / v0..v7.
    // Defs, use counts and the outgoing-argument area. Split out of buildSlots
    // because computeAddrFold READS _defOf yet must run BEFORE slots are
    // assigned: slot colouring runs the live-interval analysis, and that
    // analysis extends a folded address op's base and index forward to the
    // Load/Store that re-materialises them (see noteUses). Colouring on
    // unextended intervals would reuse a slot while a folded address still had
    // to read it — the register allocator's hazard, one level down.
    void collectDefs(IRFunc* fn)
    {
        _defOf = new Map();
        _useCount = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            noteDefs(bb.phis());
            noteDefs(bb.insns());
            if (bb.term() != (IRInsn*)0) noteDef(bb.term());
        }
        // The outgoing-argument area is sized by the widest call in the
        // function, and sits at the very bottom of the frame.
        _maxOutStack = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                u32 want = outStackBytesFor((IRInsn*)bb.insns().get(i));
                if (want > _maxOutStack) _maxOutStack = want;
            }
        }
    }

    // Stable insertion sort by interval start. The STABILITY is what supplies
    // the original's tie-break: it orders equal starts by value id, and this
    // array is built in exactly that sequence.
    void sortByIntervalStart(Array* a)
    {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)a.get(i);
            i32 s = startOf(v);
            u32 j = i;
            while (j > (u32)0 && startOf((IRValue*)a.get(j - (u32)1)) > s) {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
            }
            a.set(j, (Object*)v);
        }
    }

    // The width a value occupies in the frame: 8, or a whole number of 8s for
    // an aggregate.
    u32 slotWidthOf(IRValue* v)
    {
        u32 w = (u32)8;
        if (v != (IRValue*)0 && isAggTy(v.ty())) {
            u32 a = aggSize(layoutOf(v.ty()));
            w = (a + (u32)7) & ~(u32)7;
            if (w < (u32)8) w = (u32)8;
        }
        return w;
    }

    // May this value SHARE a frame slot with one whose live range does not
    // overlap? Refused, because a shared slot would be silent corruption:
    //   * any function containing inline asm — an asm body may name a slot
    //     directly, and nothing here can see that reference;
    //   * an ADDRESS-TAKEN value, or a declared pinned local — the pointer
    //     outlives the interval by definition;
    //   * an AGGREGATE — its slot is read through field offsets, so a later
    //     occupant would alias the fields;
    //   * a value with no interval, which means the analysis never saw it.
    // Only a value still DEFINED in this function may be coloured -- passes run
    // before codegen (VaArgExpand runs even at -O0) leave dead result ids
    // registered with no def. Derived from the IR, not from interval-map
    // presence: the two compilers agree on every interval they COMPUTE but not
    // on which dead ids they carry.
    Map* _definedVals;

    void buildDefinedSet(IRFunc* fn)
    {
        _definedVals = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0) _definedVals.set((Hashable*)p.res(), (Object*)p.res());
            }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0) _definedVals.set((Hashable*)n.res(), (Object*)n.res());
            }
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                _definedVals.set((Hashable*)bb.term().res(), (Object*)bb.term().res());
        }
    }

    bool slotShareable(IRValue* v, bool hasAsm, Map* noShare)
    {
        if (hasAsm) return false;
        if (v == (IRValue*)0) return false;
        if (_definedVals == (Map*)0 || _definedVals.get((Hashable*)v) == (Object*)0) return false;
        if (isAggTy(v.ty())) return false;
        if (noShare.get((Hashable*)v) != (Object*)0) return false;
        if (_start.get((Hashable*)v) == (Object*)0) return false;
        if (_end.get((Hashable*)v) == (Object*)0) return false;
        return true;
    }

    // Loop-aware START extension shared by slot colouring and register homing.
    // The intervals are LINEAR and the CFG is not: a value defined mid-loop and
    // live across the BACK EDGE is live again at EARLIER positions next
    // iteration, which [def..end] never covers — so a value confined to that
    // earlier region looks disjoint and would be handed the same slot/register,
    // clobbering the loop-carried one (bug 203, register homing). Pulling the
    // START back to the loop header makes the interval span the loop; only
    // lengthens intervals, so it can remove reuse but never introduce a clobber.
    void loopExtendStarts(IRFunc* fn)
    {
            for (u32 li = (u32)0; li < fn.blocks().count(); li = li + (u32)1) {
                if (_blkEnd == (Array*)0 || li >= _blkEnd.count()) continue;
                IRBlock* lb = (IRBlock*)fn.blocks().get(li);
                if (lb.term() == (IRInsn*)0) continue;
                for (u32 k = (u32)0; k < lb.term().ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)lb.term().ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                    i32 hb = (i32)-1;
                    for (u32 q = (u32)0; q < fn.blocks().count(); q = q + (u32)1)
                        if ((IRBlock*)fn.blocks().get(q) == o.blk()) { hb = (i32)q; break; }
                    if (hb < (i32)0 || (u32)hb > li) continue;   // forward edge, not a loop
                    i32 loopLo = hb == (i32)0 ? (i32)0
                        : (i32)2 * (((Number*)_blkEnd.get((u32)(hb - (i32)1))).asI32() + (i32)1);
                    i32 latchEnd = (i32)2 * ((Number*)_blkEnd.get(li)).asI32() + (i32)2;
                    Array* ks = _start.allKeys();
                    for (u32 q = (u32)0; q < ks.count(); q = q + (u32)1) {
                        IRValue* v = (IRValue*)ks.get(q);
                        if (endOf(v) < latchEnd) continue;
                        if (startOf(v) <= loopLo) continue;
                        _start.set((Hashable*)v, (Object*)Number.withI32(loopLo));
                    }
                }
            }
    }

    void buildSlots(IRFunc* fn)
    {
        _slot = new Map();
        buildDefinedSet(fn);
        computeIntervals(fn);   // fold-aware: computeAddrFold has already run

        // Loop-aware extension -- without this the colouring is UNSOUND, and
        // that is what made the first attempt miscompile rather than merely
        // under-perform. The intervals are LINEAR and the CFG is not: a value
        // defined mid-loop and live across the BACK EDGE is live again at
        // EARLIER positions next iteration, which [def..end] never covers, so a
        // value confined to that earlier region looks disjoint and would be
        // handed the same slot.
        //
        // A loop-carried value is exactly one the pass already pushed out to the
        // latch's end, since it is live-out there. Pulling its START back to the
        // loop header makes its interval span the loop. Only lengthens
        // intervals, so it can remove reuse but never introduce a clobber.
        loopExtendStarts(fn);
        // Slots go in VALUE-ID order over every id the function ever allocated,
        // gaps included — the frame layout is a function of the id COUNT, not of
        // which ids survive. Walking definitions instead would miss a pinned
        // local (never an instruction result, but it has a slot and an AddrOf
        // that computes it) and would shift every later slot besides.
        // ── Stack-slot COLOURING ────────────────────────────────────────────
        //
        // A slot used to be handed to every value in turn, so the frame was the
        // SUM of everything the function ever defined — a temporary dead after
        // three instructions cost as much as one live throughout. Values whose
        // live ranges do not overlap now share a slot, exactly as registers do.
        //
        // The sequence colouring runs over is the one the ORIGINAL assigns slots
        // to, and bug 065 CHANGED what that is. It used to be "every parsed id
        // in order, then the lowering passes' values in CREATION order", which
        // is what the two lists below used to build. 065 made the original walk
        // the function instead — params, pinned locals, then every result and
        // memory-result in block order, then operand-only uses — and number
        // slots in THAT order, over only the values the function actually
        // contains. Two consequences, both of which this must mirror or the
        // frames differ for the same program:
        //
        //   * ORDER: results and memory-results come before operand-only uses,
        //     across the whole function — not interleaved per instruction.
        //   * MEMBERSHIP: an id the function does not contain gets NO slot. The
        //     old walk added one per id in the table, gaps included, and each
        //     absent id still advanced the offset.
        //
        // Left unmirrored this is not a crash and not wrong code — both frames
        // are valid. It is every fixture differing by the same 236 lines
        // (xcc-diff 0/968), which is the shape a parity bug takes.
        Array* ordered = new Array();
        collectKeys(ordered, fn);

        // A function with inline asm is refused outright; address-taken values
        // and declared pinned locals keep private slots.
        bool hasAsm = false;
        Map* noShare = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.op().equals(String.withCString("Asm"))) hasAsm = true;
                if (n.op().equals(String.withCString("AddrOf")) && n.ops().count() >= (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get((u32)0);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        noShare.set((Hashable*)o.val(), (Object*)o.val());
                }
            }
        }
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1) {
            IRPinned* p = (IRPinned*)fn.pinned().get(i);
            if (p.val() != (IRValue*)0) noShare.set((Hashable*)p.val(), (Object*)p.val());
        }
        // PHI results and their inputs never share.
        //
        // A phi is realised as a COPY at the end of each predecessor: the
        // incoming value is read there and the phi's slot written there, both at
        // a point where SSA liveness says the phi result is not yet live. A slot
        // shared with anything live on that edge is clobbered by the copy, and no
        // interval reasoning about the phi result can see it -- an independent
        // liveness verifier over this colouring reports ZERO conflicts while the
        // code is still wrong, which is what pointed here. Same shape as the
        // lost-copy bug the homing allocator hit in #683.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) {
                IRInsn* phi = (IRInsn*)bb.phis().get(i);
                if (phi.res() != (IRValue*)0)
                    noShare.set((Hashable*)phi.res(), (Object*)phi.res());
                for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)phi.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        noShare.set((Hashable*)o.val(), (Object*)o.val());
                }
            }
        }

        u32 cur = _maxOutStack + (u32)16;   // [0..maxOut) args, then x29/x30

        // Pass 1: everything that cannot share keeps its own slot, in sequence
        // order, so a function with nothing colourable lays out exactly as before.
        for (u32 i = (u32)0; i < ordered.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)ordered.get(i);
            if (slotShareable(v, hasAsm, noShare)) continue;
            u32 w = slotWidthOf(v);
            if (v != (IRValue*)0) _slot.set((Hashable*)v, (Object*)Number.with((i32)cur));
            cur = cur + w;
        }

        // Pass 2: colour the rest, greedily, over intervals sorted by start. A
        // slot is reusable once its previous occupant's interval has ENDED —
        // strictly before this one starts, never equal, since doubled positions
        // make a def and a last-use at the same instruction share a number.
        Array* order = new Array();
        for (u32 i = (u32)0; i < ordered.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)ordered.get(i);
            if (slotShareable(v, hasAsm, noShare)) order.add((Object*)v);
        }
        sortByIntervalStart(order);
        Array* freeSlots = new Array();     // offsets
        Array* freeUntil = new Array();     // the end position of each one's last occupant
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)order.get(i);
            i32 st = startOf(v);
            i32 en = endOf(v);
            i32 pick = (i32)-1;
            for (u32 k = (u32)0; k < freeSlots.count(); k = k + (u32)1) {
                if (((Number*)freeUntil.get(k)).asI32() < st) {
                    pick = ((Number*)freeSlots.get(k)).asI32();
                    freeSlots.removeAt(k);
                    freeUntil.removeAt(k);
                    break;
                }
            }
            if (pick < (i32)0) { pick = (i32)cur; cur = cur + (u32)8; }
            _slot.set((Hashable*)v, (Object*)Number.with(pick));
            freeSlots.add((Object*)Number.with(pick));
            freeUntil.add((Object*)Number.with(en));
        }
        // A function returning a >16-byte non-HFA aggregate is handed a hidden
        // result pointer in x8; reserve a slot to stow it, since every `return`
        // writes through it and any call in between would clobber x8.
        _sretSaveOffset = (u32)0;
        String* rt = fn.ret();
        if (isAggTy(rt)) {
            IRLayout* rl = layoutOf(rt);
            bool rdbl = false;
            if (aggHFA(rl, &rdbl) == (u32)0 && aggSize(rl) > (u32)16) {
                _sretSaveOffset = cur;
                cur = cur + (u32)8;
            }
        }
        _valueSlotEnd = cur;                   // the save area, if any, starts here
        _frame = (cur + (u32)15) & ~(u32)15;   // the stack stays 16-aligned
    }

    void noteDefs(Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            noteDef((IRInsn*)list.get(i));
    }

    void noteDef(IRInsn* n)
    {
        if (n.res() != (IRValue*)0) _defOf.set((Hashable*)n.res(), (Object*)n);
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) continue;
            Object* c = _useCount.get((Hashable*)o.val());
            u32 v = c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
            _useCount.set((Hashable*)o.val(), (Object*)Number.with((i32)(v + (u32)1)));
        }
    }

    u32 useCountOf(IRValue* v)
    {
        Object* c = _useCount.get((Hashable*)v);
        return c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
    }

    static bool inMap(Map* m, IRValue* v)
    { return m.get((Hashable*)v) != (Object*)0; }

    // ── Address folding, and the ICmp/CondBranch fusion ──────────────────
    //
    // A single-use FieldAddr/ElementAddr feeding a scalar Load/Store can be
    // addressed by the ldr/str itself, through the [base, #off] and
    // [base, idx, lsl #s] forms — which saves the separate address op AND the
    // x16 staging move. Aggregates keep the multi-chunk path.
    void computeAddrFold(IRFunc* fn)
    {
        _foldedAddr = new Map();
        _foldInfo = new Map();
        _fusedCmps = new Map();

        // A single-use ICmp feeding its OWN block's CondBranch fuses into the
        // branch: the cmp sets the flags and the branch reads them, so the
        // materialised 0/1 bool and its cbnz both disappear.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch"))) continue;
            if (t.ops().count() < (u32)1) continue;
            IROperand* c = (IROperand*)t.ops().get((u32)0);
            if (c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0) continue;
            Object* d = _defOf.get((Hashable*)c.val());
            if (d == (Object*)0) continue;
            IRInsn* cmp = (IRInsn*)d;
            if (!cmp.op().equals(String.withCString("ICmp")) || cmp.res() == (IRValue*)0) continue;
            if (useCountOf(c.val()) != (u32)1) continue;
            if (!listContains(bb.insns(), cmp)) continue;
            _fusedCmps.set((Hashable*)c.val(), (Object*)cmp);
        }

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                String* op = n.op();
                bool isLoad = op.equals(String.withCString("Load"))
                           || op.equals(String.withCString("LoadVolatile"));
                bool isStore = op.equals(String.withCString("Store"))
                            || op.equals(String.withCString("StoreVolatile"));
                // A Store whose value is a single-use integer Const #0 stores the
                // zero register directly, so the const's mov/extend/spill goes
                // away. A multi-use zero still stores wzr but keeps its def.
                if (isStore && n.ops().count() >= (u32)3) {
                    IROperand* vo = (IROperand*)n.ops().get((u32)1);
                    if (isIntZeroConst(vo) && useCountOf(vo.val()) == (u32)1)
                        _foldedAddr.set((Hashable*)vo.val(), (Object*)vo.val());
                }
                // Bug 070: a 128-bit vector load/store whose address is
                // ElementAddr(base, CONSTANT index) — a pointer-IV unrolled
                // copy's `p + k*vw` — folds the byte offset into the
                // `ldr/str q, [base, #imm]` immediate. The scaled-immediate
                // range is its own: a multiple of 16, up to 65520, NOT the
                // scalar accessWidth rule (which caps at 8 and would reject
                // every offset above 32760).
                //
                // Only the DECISION was missing: vecAddrOperand already asks
                // _foldInfo and defers to foldedAddrOperand, so the emit side
                // has always been able to write this form.
                if (op.equals(String.withCString("VLoad"))
                 || op.equals(String.withCString("VStore"))) {
                    if (n.ops().count() < (u32)1) continue;
                    IROperand* vp = (IROperand*)n.ops().get((u32)0);
                    if (vp.kind() != (u8)OPK_USE || vp.val() == (IRValue*)0) continue;
                    if (useCountOf(vp.val()) != (u32)1) continue;
                    Object* vd = _defOf.get((Hashable*)vp.val());
                    if (vd == (Object*)0) continue;
                    IRInsn* ea = (IRInsn*)vd;
                    if (!ea.op().equals(String.withCString("ElementAddr"))) continue;
                    if (ea.res() == (IRValue*)0 || ea.ops().count() < (u32)2) continue;
                    i32 vk = (i32)0;
                    if (!constIndex(ea, &vk) || vk < (i32)0) continue;
                    u32 voff = (u32)vk * elemSize(ea);
                    if (voff % (u32)16 != (u32)0 || voff > (u32)65520) continue;
                    _foldInfo.set((Hashable*)vp.val(), (Object*)ea);
                    _foldedAddr.set((Hashable*)ea.res(), (Object*)ea.res());
                    continue;
                }
                if (!isLoad && !isStore) continue;
                if (isLoad && (n.ops().count() < (u32)2 || n.res() == (IRValue*)0)) continue;
                if (isStore && n.ops().count() < (u32)3) continue;
                String* xfer = isLoad ? n.res().ty()
                                      : argType((IROperand*)n.ops().get((u32)1));
                if (isAggTy(xfer)) continue;              // the multi-chunk path
                IROperand* ptr = (IROperand*)n.ops().get((u32)0);
                if (ptr.kind() != (u8)OPK_USE || ptr.val() == (IRValue*)0) continue;
                if (useCountOf(ptr.val()) != (u32)1) continue;
                Object* ad = _defOf.get((Hashable*)ptr.val());
                if (ad == (Object*)0) continue;
                IRInsn* a = (IRInsn*)ad;
                if (a.res() == (IRValue*)0 || a.ops().count() < (u32)2) continue;
                u32 w = accessWidth(xfer);
                if (a.op().equals(String.withCString("ElementAddr"))) {
                    // The register-offset form needs a power-of-two element no
                    // wider than 8 whose scale equals the transfer size — the
                    // plain array case.
                    u32 es = elemSize(a);
                    if (es == (u32)0 || (es & (es - (u32)1)) != (u32)0) continue;
                    if (es > (u32)8 || es != w) continue;
                    _foldInfo.set((Hashable*)ptr.val(), (Object*)a);
                    _foldedAddr.set((Hashable*)a.res(), (Object*)a.res());
                } else if (a.op().equals(String.withCString("FieldAddr"))) {
                    u32 off = fieldByteOffset(a);
                    // The scaled unsigned-immediate field: a multiple of the
                    // access width whose quotient fits 12 bits.
                    if (w == (u32)0 || off % w != (u32)0 || off / w > (u32)4095) continue;
                    _foldInfo.set((Hashable*)ptr.val(), (Object*)a);
                    _foldedAddr.set((Hashable*)a.res(), (Object*)a.res());
                }
            }
        }
    }

    // The transfer size a scalar access uses.
    static u32 accessWidth(String* t)
    {
        if (t == (String*)0) return (u32)1;
        if (needsXReg(t) || width(t) >= (u32)8) return (u32)8;
        if (width(t) >= (u32)4) return (u32)4;
        if (width(t) == (u32)2) return (u32)2;
        return (u32)1;
    }

    static bool listContains(Array* list, IRInsn* n)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if ((IRInsn*)list.get(i) == n) return true;
        return false;
    }

    // Materialise a folded Load/Store's base (and, for an ElementAddr, its
    // index) and return the fused addressing operand. The base lands in x16 or
    // its home; the index extends in place out of w17 or its home. Callers must
    // keep x16/x17 off the value/dest register when a fold is live.
    String* foldedAddrOperand(IRInsn* n)
    {
        IROperand* ptr = (IROperand*)n.ops().get((u32)0);
        IRInsn* a = (IRInsn*)_foldInfo.get((Hashable*)ptr.val());
        String* base = operandReg((IROperand*)a.ops().get((u32)0), String.withCString("x16"));
        if (a.op().equals(String.withCString("FieldAddr"))) {
            String* o = String.withCString("[");
            o.appendFormat("%s, #%lu]", base.cString(), fieldByteOffset(a));
            return o;
        }
        // A constant index addresses by immediate — the unrolled pointer-IV
        // copy's [p, #k*scale] — but only inside the access's scaled range;
        // otherwise the extended-register form below, which has no such limit.
        i32 k = (i32)0;
        if (constIndex(a, &k) && k >= (i32)0) {
            u32 off = (u32)k * elemSize(a);
            // A vector access transfers 16 bytes and has its own immediate
            // range (multiple of 16, <= 65520). Running it through the scalar
            // accessWidth — which caps at 8 — would refuse every offset above
            // 32760 that computeAddrFold had already accepted, quietly costing
            // the fold and leaving exactly the diff bug 070 was about.
            bool isVec = n.op().equals(String.withCString("VLoad"))
                      || n.op().equals(String.withCString("VStore"));
            u32 accW = isVec ? (u32)16
                             : accessWidth(n.op().equals(String.withCString("Store"))
                                || n.op().equals(String.withCString("StoreVolatile"))
                                   ? argType((IROperand*)n.ops().get((u32)1))
                                   : n.res().ty());
            // 4095 covers both: the scalar scaled-immediate limit, and the
            // vector one (65520 / 16 is exactly 4095).
            if (accW != (u32)0 && off % accW == (u32)0 && off / accW <= (u32)4095) {
                String* o = String.withCString("[");
                o.appendFormat("%s, #%lu]", base.cString(), off);
                return o;
            }
        }
        // The extended-register form widens the 32-bit index in place, so a
        // homed index is read straight from its register with no staging move.
        // A SIGNED index must SIGN-extend: uxtw would turn −4 into +0xFFFC and
        // address a wild page. A 64-BIT index is already address-width — its
        // home view is an X register, and uxtw/sxtw are W-only forms (blewit
        // finding #8) — so it takes the lsl form whole.
        IROperand* io = (IROperand*)a.ops().get((u32)1);
        bool idx64 = io.kind() == (u8)OPK_USE && io.val() != (IRValue*)0
                  && needsXReg(io.val().ty());
        String* idx = operandReg(io, String.withCString(idx64 ? "x17" : "w17"));
        bool sgn = io.kind() == (u8)OPK_USE && io.val() != (IRValue*)0
                && isSignedTy(io.val().ty());
        u32 es = elemSize(a);
        u32 shift = (u32)0;
        for (u32 v = es; v > (u32)1; v = v >> (u32)1) shift = shift + (u32)1;
        String* o = String.withCString("[");
        o.appendFormat("%s, %s, %s #%lu]", base.cString(), idx.cString(),
                       idx64 ? "lsl" : (sgn ? "sxtw" : "uxtw"), shift);
        return o;
    }

    // The 065 walk: first sighting wins, nulls are not values, and a value is
    // enrolled exactly once. `blockInsns` is the original's `all` array — phis,
    // then instructions, then the terminator — so the two traversals visit the
    // same things in the same order.
    Array* blockInsns(IRBlock* bb)
    {
        Array* all = new Array();
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
            all.add(bb.phis().get(i));
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            all.add(bb.insns().get(i));
        if (bb.term() != (IRInsn*)0) all.add((Object*)bb.term());
        return all;
    }

    void seeVal(Array* into, Map* seen, IRValue* v)
    {
        if (v == (IRValue*)0) return;
        if (seen.get((Hashable*)v) != (Object*)0) return;
        seen.set((Hashable*)v, (Object*)v);
        into.add((Object*)v);
    }

    void seeResults(Array* into, Map* seen, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1) {
            IRInsn* n = (IRInsn*)list.get(i);
            seeVal(into, seen, n.res());
            // The memory token is a SECOND result, printed like one. Omitting
            // it drops LIVE ids and shrinks the frame.
            seeVal(into, seen, n.memRes());
        }
    }

    void seeUses(Array* into, Map* seen, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1) {
            IRInsn* n = (IRInsn*)list.get(i);
            for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1) {
                IROperand* o = (IROperand*)n.ops().get(j);
                if (o.kind() == (u8)OPK_USE) seeVal(into, seen, o.val());
            }
        }
    }

    void collectFresh(Array* into, Array* vals)
    {
        for (u32 i = (u32)0; i < vals.count(); i = i + (u32)1)
            noteFresh(into, (IRValue*)vals.get(i));
    }

    void collectFreshInsns(Array* into, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            collectFreshInsn(into, (IRInsn*)list.get(i));
    }

    void collectFreshInsn(Array* into, IRInsn* n)
    {
        noteFresh(into, n.res());
        noteFresh(into, n.memRes());
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE) noteFresh(into, o.val());
        }
    }

    void noteFresh(Array* into, IRValue* v)
    {
        if (v == (IRValue*)0) return;
        if (_slot.get((Hashable*)v) != (Object*)0) return;
        if (hasVal(into, v)) return;
        into.add((Object*)v);
    }

    // Insertion sort on the creation sequence.
    static void sortBySeq(Array* a)
    {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1) {
            Object* cur = a.get(i);
            u32 ck = ((IRValue*)cur).seq();
            u32 j = i;
            while (j > (u32)0 && ((IRValue*)a.get(j - (u32)1)).seq() > ck) {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
            }
            a.set(j, cur);
        }
    }

    u32 slotsFor(Array* vals, u32 cur)
    {
        for (u32 i = (u32)0; i < vals.count(); i = i + (u32)1)
            cur = noteSlot((IRValue*)vals.get(i), cur);
        return cur;
    }

    u32 slotsForInsns(Array* list, u32 cur)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            cur = slotsForInsn((IRInsn*)list.get(i), cur);
        return cur;
    }

    u32 slotsForInsn(IRInsn* n, u32 cur)
    {
        if (n.res() != (IRValue*)0)    cur = noteSlot(n.res(), cur);
        if (n.memRes() != (IRValue*)0) cur = noteSlot(n.memRes(), cur);
        return cur;
    }

    u32 noteSlot(IRValue* v, u32 cur)
    {
        if (v == (IRValue*)0) return cur;
        if (_slot.get((Hashable*)v) != (Object*)0) return cur;
        _slot.set((Hashable*)v, (Object*)Number.withU32(cur));
        u32 w = (u32)8;
        if (isAggTy(v.ty())) {
            u32 a = aggSize(layoutOf(v.ty()));
            w = (a + (u32)7) & ~(u32)7;
            if (w < (u32)8) w = (u32)8;
        }
        return cur + w;
    }

    u32 slotOf(IRValue* v)
    {
        Object* o = _slot.get((Hashable*)v);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
    }
}
