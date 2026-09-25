// Xt6502.xc — the IR, as banked 6502 assembly for the xt hardware.
// =========================================================================
//
// self-hosting M17. The port of XT6502Backend, and the last of the five. It is
// structurally unlike the four before it in three ways, all of which follow
// from the machine rather than from the IR.
//
// There are almost no registers. A, X and Y, and that is the lot — so a value
// does not live in a register between instructions at all. It lives in ZERO
// PAGE, and the "register allocator" is a ZP slot allocator handing out
// contiguous byte runs from a pool. A value that will not fit spills to a
// software-stack frame instead, addressed `+off,SP`.
//
// The memory map is not fixed by an ABI: which ZP bytes are the pool, which
// regions may hold code, where the bank windows are and which registers select
// them, all come from the layout file ([[Layout.xc]] reads it).
//
// And CODE IS BANKED. A function that does not fit the unbanked region is
// packed into a 16 KB code-bank page and reached through a trampoline that
// saves and restores the bank register around the call.
//
// The oracle is `xtcg-6502 -m xt -O0` over the same IR, byte for byte.
//
// An opcode this slice does not emit yet is recorded BY NAME and the whole file
// refused (exit 3) — the same discipline as the other four ports, and the more
// important here, because on a machine with three registers a silently skipped
// instruction produces assembly that is entirely plausible and wrong.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Ir.xc"
#import "Layout.xc"

class Xt6502
{
    IRModule* _m;
    IRFunc*   _fn;
    String*   _out;
    Layout*   _layout;
    bool      _failed;
    String*   _why;
    Array*    _missing;

    void init(void)
    {
        _out = new String();
        _missing = new Array();
        _failed = false;
    }

    void setLayout(Layout* l) { _layout = l; }

    // `--xtc-stack`: the calling convention of a function that carries neither
    // `:xtcStack` nor `:hwStack`. Off keeps the return address and the saved
    // registers on the hardware stack; on moves them into a software-stack
    // frame.
    bool _xtcStackDefault;
    void setXtcStackDefault(bool on) { _xtcStackDefault = on; }

    // `-Fmb <n>`: a function of fewer than n instructions stays in main RAM on
    // a banked layout rather than taking a code bank, so a call to it needs no
    // trampoline. 0, the default, banks everything but the entry point and the
    // interrupt handlers.
    u32 _fnMinBanked;
    void setFnMinBanked(u32 n) { _fnMinBanked = n; }

    // What `-dp` prints for the module last rendered: each function's
    // placement and estimated size, then the bytes used in main RAM and in
    // each code bank.
    String* _placement;
    String* placementReport(void) { return _placement == (String*)0 ? String.withCString("") : _placement; }

    bool    failed(void)  { return _failed; }
    String* why(void)     { return _why; }
    Array*  missing(void) { return _missing; }

    void unsupported(String* op)
    {
        _failed = true;
        if (_why == (String*)0) _why = op;
        for (u32 i = (u32)0; i < _missing.count(); i = i + (u32)1)
            if (((String*)_missing.get(i)).equals(op)) return;
        _missing.add((Object*)op);
    }

    // ── Type widths ──────────────────────────────────────────────────────
    //
    // The narrowest widths of any target, and the one place a POINTER is not a
    // machine word: three bytes, [addr-lo, addr-hi, data-bank]. That third byte
    // is what makes every deref uniform — the back end writes the data-bank
    // register from it, so no path has to branch on "is this banked?".
    static bool isPtrTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Ptr(")); }

    static bool isAggTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Agg(")); }

    static bool isMemTy(String* t)
    { return t != (String*)0 && t.equals(String.withCString("Mem")); }

    static bool isFloatTy(String* t)
    {
        return t != (String*)0 && (t.equals(String.withCString("F32"))
                                || t.equals(String.withCString("F64")));
    }

    static bool isSignedTy(String* t)
    {
        if (t == (String*)0) return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("I16"))
            || t.equals(String.withCString("I32")) || t.equals(String.withCString("I64"));
    }

    u32 byteWidth(String* t)
    {
        if (t == (String*)0) return (u32)0;
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8"))
         || t.equals(String.withCString("Bool"))) return (u32)1;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")))
            return (u32)2;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")))
            return (u32)4;
        // 8 whatever the arithmetic can do: width is a LAYOUT contract, and a
        // back end that disagreed with the front end would corrupt struct
        // offsets in optimised code rather than fail.
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")))
            return (u32)8;
        if (t.equals(String.withCString("F32"))) return (u32)4;   // IEEE single
        if (t.equals(String.withCString("F64"))) return (u32)8;
        if (isMemTy(t)) return (u32)0;                            // a phantom
        // Every pointer is three bytes: [addr-lo, addr-hi, bank-lo]. A main-RAM
        // pointer simply carries bank 0.
        if (isPtrTy(t)) return (u32)3;
        if (isAggTy(t)) {
            IRLayout* l = layoutOf(t);
            return l == (IRLayout*)0 ? (u32)0 : l.size();
        }
        return (u32)0;
    }

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

    // ── Zero-page slot allocation ────────────────────────────────────────
    //
    // A value's "register" is a run of contiguous ZP bytes. A multi-byte value
    // never STRADDLES a gap between pool ranges — the addressing modes read
    // consecutive addresses, so a value split across a gap would read whatever
    // lives in between.
    Map* _zpBase;               // value -> its base ZP address
    Array* _zpRanges;           // LayoutRange@, the pool
    u32 _zpRangeIndex;
    u32 _nextZp;
    bool _zpOverflow;

    void resetZp(void)
    {
        _zpBase = new Map();
        _spFrameBase = new Map();
        _spDelta = (i32)0;
        _zpRanges = _layout == (Layout*)0 ? new Array() : _layout.varsRanges();
        _zpRangeIndex = (u32)0;
        _nextZp = _zpRanges.count() > (u32)0
            ? ((LayoutRange*)_zpRanges.get((u32)0)).lo() : (u32)0;
        _zpOverflow = false;
    }

    u32 allocateSlots(IRValue* v)
    {
        u32 width = byteWidth(v.ty());
        if (width == (u32)0) return (u32)0;            // a memory phantom
        while (_zpRangeIndex < _zpRanges.count()) {
            u32 end = ((LayoutRange*)_zpRanges.get(_zpRangeIndex)).hi();
            if (_nextZp + width - (u32)1 <= end) {
                u32 base = _nextZp;
                _nextZp = _nextZp + width;
                _zpBase.set((Hashable*)v, (Object*)Number.withU32(base));
                return base;
            }
            _zpRangeIndex = _zpRangeIndex + (u32)1;
            if (_zpRangeIndex < _zpRanges.count())
                _nextZp = ((LayoutRange*)_zpRanges.get(_zpRangeIndex)).lo();
        }
        // Every range is full. The budget check upstream catches the realistic
        // cases; here the flag is raised and emission continues so the failure
        // is reported once, in one place, rather than as garbage assembly.
        _zpOverflow = true;
        return _nextZp;
    }

    // A pinned local that will not fit is an EXPECTED, recoverable spill to the
    // software-stack frame — not an error — so this reports failure by
    // returning −1 and leaves the cursor untouched, and deliberately does not
    // raise the overflow flag.
    i32 tryAllocateZP(u32 width)
    {
        u32 ri = _zpRangeIndex;
        u32 cur = _nextZp;
        while (ri < _zpRanges.count()) {
            u32 end = ((LayoutRange*)_zpRanges.get(ri)).hi();
            if (cur + width - (u32)1 <= end) {
                _zpRangeIndex = ri;
                _nextZp = cur + width;
                return (i32)cur;
            }
            ri = ri + (u32)1;
            if (ri < _zpRanges.count()) cur = ((LayoutRange*)_zpRanges.get(ri)).lo();
        }
        return (i32)-1;
    }

    i32 slotOf(IRValue* v)
    {
        if (v == (IRValue*)0) return (i32)-1;
        Object* o = _zpBase.get((Hashable*)v);
        return o == (Object*)0 ? (i32)-1 : (i32)((Number*)o).asU32();
    }

    // ── Unified value-byte addressing ────────────────────────────────────
    //
    // The xt ISA provides `d,SP` variants of exactly the byte-moving and
    // ADC/SBC/CMP instructions this back end uses, so a value living on the
    // software-stack frame is addressed by swapping its operand string from
    // `$<zp>` to `+<off>,SP` under the SAME mnemonic. That is what lets one
    // emitter serve both homes.
    //
    // (AND, ORA, EOR and BIT have no d,SP form; their frame operands stage
    // through a scratch byte at the call site instead.)
    Map* _spFrameBase;          // value -> its frame offset
    i32 _spDelta;               // how far SP has moved since the frame base

    String* operandFor(IRValue* v, u32 bi)
    {
        if (v == (IRValue*)0) return (String*)0;
        Object* sp = _spFrameBase.get((Hashable*)v);
        if (sp != (Object*)0) {
            // The offset TRACKS SP: every push and pop between the frame's
            // creation and this access shifts it, so the delta is part of the
            // address, not a correction applied later.
            i32 off = ((Number*)sp).asI32() + (i32)bi + _spDelta;
            String* o = String.withCString("+");
            o.appendFormat("%ld,SP", off);
            return o;
        }
        i32 zp = slotOf(v);
        if (zp < (i32)0) return (String*)0;
        String* o = String.withCString("$");
        o.append(hex2((u32)zp + bi));
        return o;
    }

    bool onSPFrame(IRValue* v)
    { return v != (IRValue*)0 && _spFrameBase.get((Hashable*)v) != (Object*)0; }

    // The indirect base for a pointer used with post-indexed Y: a frame pointer
    // gives `(+off,SP)` and a ZP pointer `($zp)`. The caller appends `,Y`.
    String* indirectBaseFor(IRValue* v)
    {
        if (v == (IRValue*)0) return (String*)0;
        Object* sp = _spFrameBase.get((Hashable*)v);
        if (sp != (Object*)0) {
            i32 off = ((Number*)sp).asI32() + _spDelta;
            String* o = String.withCString("(+");
            o.appendFormat("%ld,SP)", off);
            return o;
        }
        i32 zp = slotOf(v);
        if (zp < (i32)0) return (String*)0;
        String* o = String.withCString("($");
        o.append(hex2((u32)zp));
        o.appendCString(")");
        return o;
    }

    // ── SP tracking ──────────────────────────────────────────────────────
    //
    // Every push and pop moves SP, and every frame-relative operand is
    // computed from it — so the delta is maintained HERE, at the one place
    // that emits the instructions, rather than by each caller remembering.
    void emitPHA(void) { _out.appendCString("    PHA\n"); _spDelta = _spDelta + (i32)1; }
    void emitPLA(void) { _out.appendCString("    PLA\n"); _spDelta = _spDelta - (i32)1; }

    void emitAddSP(u32 n)
    {
        if (n == (u32)0) return;
        _out.appendFormat("    ADD SP, #%lu\n", n);
        _spDelta = _spDelta - (i32)n;
    }

    // A LEAF function issues no call of any kind, so it is never re-entered and
    // its spills can be static main-RAM slots. A non-leaf needs a
    // per-invocation software-stack frame.
    static bool functionIsLeaf(IRFunc* fn)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (isCallOp(((IRInsn*)bb.insns().get(i)).op())) return false;
            if (bb.term() != (IRInsn*)0 && isCallOp(bb.term().op())) return false;
        }
        return true;
    }

    static bool isCallOp(String* op)
    {
        return op.equals(String.withCString("Call"))
            || op.equals(String.withCString("CallIndirect"))
            || op.equals(String.withCString("VTblDispatch"));
    }

    // ── Frame-slot allocation ────────────────────────────────────────────
    //
    // Every non-address-taken, non-memory value goes on the SP hardware frame
    // rather than zero page — which is what relieves the ZP-overflow wall.
    // Pointers ride the frame too and dereference in place via `(d,SP),Y`.
    //
    // Slots are assigned by graph colouring over a liveness-derived
    // interference graph, so values that are never simultaneously live SHARE a
    // slot. Five extra interference rules are layered on top of plain SSA
    // liveness, and each exists because of a way the emitted code reads a slot
    // that liveness does not model.
    u32 _spFrameSize;
    Map* _frameWidth;           // value -> its byte width (frame-eligible only)
    Array* _frameOrder;         // deterministic assignment order

    void computeFrameSlots(IRFunc* fn, Array* pinned)
    {
        _spFrameBase = new Map();
        _frameWidth = new Map();
        _frameOrder = new Array();
        _spFrameSize = (u32)0;
        // User parameters are NOT given fresh local slots: they are addressed
        // in place at their incoming caller-stack offsets, so the prologue's
        // per-call entry copy would collapse to a self-move. Their incoming
        // region is disjoint from the local area, so leaving them out of the
        // graph is safe — no local can be coloured onto a parameter's slot.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            considerList(bb.phis(), pinned);
            considerList(bb.insns(), pinned);
            if (bb.term() != (IRInsn*)0) considerInsn(bb.term(), pinned);
        }
        if (_frameOrder.count() == (u32)0) return;
        Map* interf = buildInterference(fn);
        colourFrame(interf);
    }

    void considerList(Array* list, Array* pinned)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            considerInsn((IRInsn*)list.get(i), pinned);
    }

    void considerInsn(IRInsn* n, Array* pinned)
    {
        consider(n.res(), pinned);
        consider(n.memRes(), pinned);
    }

    void consider(IRValue* v, Array* pinned)
    {
        if (v == (IRValue*)0) return;
        if (_frameWidth.get((Hashable*)v) != (Object*)0) return;
        if (hasVal(pinned, v)) return;              // needs a real address
        u32 w = byteWidth(v.ty());
        if (w == (u32)0) return;                    // a memory phantom
        _frameWidth.set((Hashable*)v, (Object*)Number.withU32(w));
        _frameOrder.add((Object*)v);
    }

    bool frameEligible(IRValue* v)
    { return v != (IRValue*)0 && _frameWidth.get((Hashable*)v) != (Object*)0; }

    u32 widthOfFrame(IRValue* v)
    {
        Object* o = _frameWidth.get((Hashable*)v);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
    }

    static bool hasVal(Array* a, IRValue* v)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v) return true;
        return false;
    }

    // Two values interfere iff they are simultaneously live at some program
    // point. Marking every pair in the live set at each point is more robust
    // than a def-versus-live-out rule, which misses values that share a point
    // where NEITHER is defined — two parameters, or two phis in one block.
    Map* buildInterference(IRFunc* fn)
    {
        Array* liveOut = new Array();
        Array* liveIn = new Array();
        solveLiveness(fn, liveIn, liveOut);
        Map* interf = new Map();
        for (u32 i = (u32)0; i < _frameOrder.count(); i = i + (u32)1)
            interf.set((Hashable*)(IRValue*)_frameOrder.get(i), (Object*)new Array());
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* live = copyVals((Array*)liveOut.get(b));
            interfereAll(interf, live);
            Array* rev = reversedInsns(bb);
            for (u32 i = (u32)0; i < rev.count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)rev.get(i);
                // A DEAD def is never added to any live set by SSA liveness, so
                // without this it would interfere with nothing and be coloured
                // onto a slot a value live across it is holding — a dead
                // `Const #0` landing on the receiver pointer's slot, whose
                // store then clobbers it.
                connectDef(interf, n.res(), live);
                connectDef(interf, n.memRes(), live);
                if (n.res() != (IRValue*)0) removeVal(live, n.res());
                if (n.memRes() != (IRValue*)0) removeVal(live, n.memRes());
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0) addVal(live, o.val());
                }
                interfereAll(interf, live);
            }
        }
        forceParamsApart(fn, interf);
        forcePhiResultsApart(fn, interf, liveOut);
        forceLoadPointersApart(fn, interf);
        forceWideOverlapsApart(fn, interf);
        return interf;
    }

    // Parameters are copied into their slots at entry IN ORDER, so two sharing
    // a slot would have the second copy clobber the first. A non-parameter is
    // defined in the body before use, so an entry-time clobber is harmless.
    void forceParamsApart(IRFunc* fn, Map* interf)
    {
        Array* ps = new Array();
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)fn.params().get(i);
            if (frameEligible(v)) ps.add((Object*)v);
        }
        for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1)
            for (u32 j = i + (u32)1; j < ps.count(); j = j + (u32)1)
                mark(interf, (IRValue*)ps.get(i), (IRValue*)ps.get(j));
    }

    // A successor's phi results are materialised by edge copies emitted at the
    // END of each predecessor — after its body but BEFORE its terminator reads
    // the branch condition. So a phi result must not share a slot with anything
    // live at that point, INCLUDING the terminator's own operands. Standard SSA
    // liveness misses this because the phi result is "defined" at the
    // successor's entry, not here.
    void forcePhiResultsApart(IRFunc* fn, Map* interf, Array* liveOut)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == (IRInsn*)0) continue;
            Array* liveAtBranch = copyVals((Array*)liveOut.get(b));
            for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1) {
                IROperand* o = (IROperand*)term.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0) addVal(liveAtBranch, o.val());
            }
            for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1) {
                IROperand* o = (IROperand*)term.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                IRBlock* succ = o.blk();
                for (u32 pi = (u32)0; pi < succ.phis().count(); pi = pi + (u32)1) {
                    IRValue* pr = ((IRInsn*)succ.phis().get(pi)).res();
                    if (!frameEligible(pr)) continue;
                    for (u32 x = (u32)0; x < liveAtBranch.count(); x = x + (u32)1)
                        mark(interf, pr, (IRValue*)liveAtBranch.get(x));
                }
            }
        }
    }

    // A multi-byte Load RE-READS its pointer through `(d,SP),Y` for every
    // result byte, so writing a result byte into the pointer's own slot would
    // corrupt the next byte's dereference. SSA liveness has the pointer dying
    // at the Load, so it would not interfere.
    void forceLoadPointersApart(IRFunc* fn, Map* interf)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("Load"))
                 && !n.op().equals(String.withCString("LoadVolatile"))) continue;
                if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1) continue;
                IROperand* p = (IROperand*)n.ops().get((u32)0);
                if (p.kind() != (u8)OPK_USE) continue;
                mark(interf, n.res(), p.val());
            }
        }
    }

    // A multi-byte op emits a byte loop: write result_b, then read
    // operand_{b+1}. If a two-or-more-byte result PARTIALLY overlaps a
    // two-or-more-byte operand, writing the low result byte corrupts an operand
    // byte the next iteration reads. Exact same-range coalescing would be safe
    // — read before write, per byte — but greedy colouring cannot guarantee
    // exactness, so any overlap is forbidden. Single-byte values have no
    // cross-byte read and are exempt.
    void forceWideOverlapsApart(IRFunc* fn, Map* interf)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* all = allInsns(bb);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)all.get(i);
                if (n.res() == (IRValue*)0 || widthOfFrame(n.res()) < (u32)2) continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE) continue;
                    if (widthOfFrame(o.val()) >= (u32)2) mark(interf, n.res(), o.val());
                }
            }
        }
    }

    void connectDef(Map* interf, IRValue* r, Array* live)
    {
        if (!frameEligible(r)) return;
        for (u32 i = (u32)0; i < live.count(); i = i + (u32)1)
            mark(interf, r, (IRValue*)live.get(i));
    }

    void interfereAll(Map* interf, Array* live)
    {
        Array* fe = new Array();
        for (u32 i = (u32)0; i < live.count(); i = i + (u32)1)
            if (frameEligible((IRValue*)live.get(i))) fe.add(live.get(i));
        for (u32 i = (u32)0; i < fe.count(); i = i + (u32)1)
            for (u32 j = i + (u32)1; j < fe.count(); j = j + (u32)1)
                mark(interf, (IRValue*)fe.get(i), (IRValue*)fe.get(j));
    }

    void mark(Map* interf, IRValue* a, IRValue* b)
    {
        if (a == b || !frameEligible(a) || !frameEligible(b)) return;
        addVal((Array*)interf.get((Hashable*)a), b);
        addVal((Array*)interf.get((Hashable*)b), a);
    }

    // Greedy width-aware colouring: the lowest free offset at or above 7.
    //
    // SP+0 is the guard byte and SP+1..SP+6 the saved registers, so the local
    // area starts at SP+7 — and `PSH #N` allocates N+7.
    void colourFrame(Map* interf)
    {
        // Under the xtc-stack convention there is no guard byte and there are
        // no saved registers on the hardware stack: the locals start at SP+1.
        u32 base = _frameLocalsBase;
        u32 maxEnd = base;
        for (u32 i = (u32)0; i < _frameOrder.count(); i = i + (u32)1) {
            IRValue* k = (IRValue*)_frameOrder.get(i);
            u32 w = widthOfFrame(k);
            Array* occLo = new Array();
            Array* occHi = new Array();
            Array* nbrs = (Array*)interf.get((Hashable*)k);
            for (u32 x = (u32)0; x < nbrs.count(); x = x + (u32)1) {
                IRValue* nb = (IRValue*)nbrs.get(x);
                Object* ox = _spFrameBase.get((Hashable*)nb);
                if (ox == (Object*)0) continue;
                u32 lo = ((Number*)ox).asU32();
                occLo.add((Object*)Number.withU32(lo));
                occHi.add((Object*)Number.withU32(lo + widthOfFrame(nb)));
            }
            sortRangesByLo(occLo, occHi);
            u32 o = base;
            for (u32 r = (u32)0; r < occLo.count(); r = r + (u32)1) {
                u32 lo = ((Number*)occLo.get(r)).asU32();
                u32 hi = ((Number*)occHi.get(r)).asU32();
                if (o < hi && o + w > lo) o = hi;      // overlaps: bump past it
            }
            _spFrameBase.set((Hashable*)k, (Object*)Number.withU32(o));
            if (o + w > maxEnd) maxEnd = o + w;
        }
        _spFrameSize = maxEnd - base;                  // N, the PSH immediate
    }

    static void sortRangesByLo(Array* lo, Array* hi)
    {
        for (u32 i = (u32)1; i < lo.count(); i = i + (u32)1) {
            Object* cl = lo.get(i);
            Object* ch = hi.get(i);
            u32 key = ((Number*)cl).asU32();
            u32 j = i;
            while (j > (u32)0 && ((Number*)lo.get(j - (u32)1)).asU32() > key) {
                lo.set(j, lo.get(j - (u32)1));
                hi.set(j, hi.get(j - (u32)1));
                j = j - (u32)1;
            }
            lo.set(j, cl);
            hi.set(j, ch);
        }
    }

    // ── Liveness ─────────────────────────────────────────────────────────
    void solveLiveness(IRFunc* fn, Array* liveIn, Array* liveOut)
    {
        u32 nb = fn.blocks().count();
        Array* gen = new Array();
        Array* kill = new Array();
        for (u32 b = (u32)0; b < nb; b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* g = new Array();
            Array* k = new Array();
            Array* seq = allInsns(bb);
            for (u32 i = (u32)0; i < seq.count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)seq.get(i);
                for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0) continue;
                    if (!hasVal(k, o.val())) addVal(g, o.val());
                }
                if (n.res() != (IRValue*)0) addVal(k, n.res());
                if (n.memRes() != (IRValue*)0) addVal(k, n.memRes());
            }
            gen.add((Object*)g);
            kill.add((Object*)k);
            liveIn.add((Object*)new Array());
            liveOut.add((Object*)new Array());
        }
        bool changed = true;
        while (changed) {
            changed = false;
            for (u32 bi = nb; bi > (u32)0; bi = bi - (u32)1) {
                u32 b = bi - (u32)1;
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                Array* out = new Array();
                if (bb.term() != (IRInsn*)0)
                    for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1) {
                        IROperand* o = (IROperand*)bb.term().ops().get(k);
                        if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0) continue;
                        i32 si = blockIndexOf(fn, o.blk());
                        if (si < (i32)0) continue;
                        unionVals(out, (Array*)liveIn.get((u32)si));
                    }
                Array* inn = copyVals((Array*)gen.get(b));
                Array* outMinusKill = minusVals(out, (Array*)kill.get(b));
                unionVals(inn, outMinusKill);
                if (!sameVals(out, (Array*)liveOut.get(b))
                 || !sameVals(inn, (Array*)liveIn.get(b))) {
                    liveOut.set(b, (Object*)out);
                    liveIn.set(b, (Object*)inn);
                    changed = true;
                }
            }
        }
    }

    static Array* allInsns(IRBlock* bb)
    {
        Array* a = new Array();
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) a.add(bb.phis().get(i));
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) a.add(bb.insns().get(i));
        if (bb.term() != (IRInsn*)0) a.add((Object*)bb.term());
        return a;
    }

    static Array* reversedInsns(IRBlock* bb)
    {
        Array* a = allInsns(bb);
        Array* r = new Array();
        for (u32 i = a.count(); i > (u32)0; i = i - (u32)1) r.add(a.get(i - (u32)1));
        return r;
    }

    i32 blockIndexOf(IRFunc* fn, IRBlock* b)
    {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b) return (i32)i;
        return (i32)-1;
    }

    static void addVal(Array* a, IRValue* v)
    { if (v != (IRValue*)0 && !hasVal(a, v)) a.add((Object*)v); }

    static void removeVal(Array* a, IRValue* v)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v) { a.removeAt(i); return; }
    }

    static Array* copyVals(Array* a)
    {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1) o.add(a.get(i));
        return o;
    }

    static void unionVals(Array* into, Array* from)
    {
        for (u32 i = (u32)0; i < from.count(); i = i + (u32)1)
            addVal(into, (IRValue*)from.get(i));
    }

    static Array* minusVals(Array* a, Array* b)
    {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!hasVal(b, (IRValue*)a.get(i))) o.add(a.get(i));
        return o;
    }

    static bool sameVals(Array* a, Array* b)
    {
        if (a.count() != b.count()) return false;
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!hasVal(b, (IRValue*)a.get(i))) return false;
        return true;
    }

    // ── Entry point ──────────────────────────────────────────────────────
    String* assembly(IRModule* m)
    {
        _m = m;
        _out = new String();
        _out.appendCString("; Generated by XT6502Backend — DO NOT EDIT\n");
        if (_layout == (Layout*)0) {
            unsupported(String.withCString("no-layout"));
            return _out;
        }
        emitCodeRegions();
        emitHeaderGap();
        _spillDecls = new Array();
        if (banking()) { emitBanked(m); return _out; }
        // The 6502 has no `JSR (ind)`; JMP ($85) fakes it. The BANKED path's
        // harness defines this itself (and the bank-aware __xt_indcall
        // alongside), but the flat codegen harnesses do not — without it the
        // JSR resolves to an undefined symbol, which the assembler quietly
        // makes $0000, and every dispatch jumps there.
        if (needsIndJmp(m)) _out.appendCString("__xt_indjmp:\n    JMP ($85)\n");
        beginPlacement();
        IRFunc* entry = entryFunction(m);
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 before = _out.byteLength();
            emitFunction(fn);
            if (fn.blocks().count() == (u32)0) continue;
            notePlacement(fn, (u32)0, _out.substringFromByte(before),
                          fn == entry ? String.withCString("entry") : (String*)0);
        }
        finishPlacement((u32)0);
        emitModuleData(m);
        return _out;
    }

    // ── Placement report (-dp) ───────────────────────────────────────────
    Array* _placeNames;         // String@, in emission order
    Array* _placeWhere;         // String@ — main / irq / vbi / bank N
    Array* _placeSizes;         // Number@, estimated bytes
    Array* _placeNotes;         // String@ or a zero-length string
    Array* _placeBanks;         // Number@, 0 = unbanked

    void beginPlacement(void)
    {
        _placeNames = new Array();
        _placeWhere = new Array();
        _placeSizes = new Array();
        _placeNotes = new Array();
        _placeBanks = new Array();
    }

    void notePlacement(IRFunc* fn, u32 bank, String* text, String* note)
    {
        String* where = String.withCString("main");
        if (bank != (u32)0) {
            where = String.withCString("bank ");
            where.appendFormat("%lu", bank);
        } else if (isIrq(fn)) where = String.withCString("irq");
        else if (isVbi(fn)) where = String.withCString("vbi");
        _placeNames.add((Object*)fn.name());
        _placeWhere.add((Object*)where);
        _placeSizes.add((Object*)Number.withU32(asmByteSize(text)));
        _placeNotes.add((Object*)(note == (String*)0 ? String.withCString("") : note));
        _placeBanks.add((Object*)Number.withU32(bank));
    }

    static String* padRight(String* s, u32 width)
    {
        String* o = String.withString(s);
        while (o.byteLength() < width) o.appendCString(" ");
        return o;
    }

    static String* padLeftNum(u32 v, u32 width)
    {
        String* num = String.withCString("");
        num.appendFormat("%lu", v);
        String* o = String.withCString("");
        while (o.byteLength() + num.byteLength() < width) o.appendCString(" ");
        o.append(num);
        return o;
    }

    void finishPlacement(u32 bankSize)
    {
        String* r = String.withCString("xcc: placement for layout '");
        r.append(_layout.name());
        r.appendCString("' (sizes are the compiler's estimates, an upper bound):\n");
        u32 mainBytes = (u32)0;
        u32 bankCount = (u32)0;
        for (u32 i = (u32)0; i < _placeNames.count(); i = i + (u32)1) {
            u32 sz = ((Number*)_placeSizes.get(i)).asU32();
            u32 b = ((Number*)_placeBanks.get(i)).asU32();
            if (b == (u32)0) mainBytes = mainBytes + sz;
            else if (b > bankCount) bankCount = b;
            r.appendCString("  ");
            r.append(padRight((String*)_placeWhere.get(i), (u32)8));
            r.appendCString(" ");
            r.append(padLeftNum(sz, (u32)6));
            r.appendCString(" bytes  ");
            r.append((String*)_placeNames.get(i));
            String* note = (String*)_placeNotes.get(i);
            if (note.byteLength() > (u32)0) {
                r.appendCString(" (");
                r.append(note);
                r.appendCString(")");
            }
            r.appendCString("\n");
        }
        r.appendCString("xcc: bytes used by generated code:\n");
        r.appendCString("  ");
        r.append(padRight(String.withCString("main"), (u32)8));
        r.appendCString(" ");
        r.append(padLeftNum(mainBytes, (u32)6));
        r.appendCString(" bytes (the runtime shares this region)\n");
        for (u32 b = (u32)1; b <= bankCount; b = b + (u32)1) {
            u32 used = (u32)0;
            for (u32 i = (u32)0; i < _placeNames.count(); i = i + (u32)1)
                if (((Number*)_placeBanks.get(i)).asU32() == b)
                    used = used + ((Number*)_placeSizes.get(i)).asU32();
            String* label = String.withCString("bank ");
            label.appendFormat("%lu", b);
            r.appendCString("  ");
            r.append(padRight(label, (u32)8));
            r.appendCString(" ");
            r.append(padLeftNum(used, (u32)6));
            r.appendFormat(" of %lu bytes\n", bankSize);
        }
        _placement = r;
    }

    static bool needsIndJmp(IRModule* m)
    {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                    String* op = ((IRInsn*)bb.insns().get(i)).op();
                    if (op.equals(String.withCString("VTblDispatch"))
                     || op.equals(String.withCString("CallIndirect"))) return true;
                }
            }
        }
        return false;
    }

    // ── Banked emission ──────────────────────────────────────────────────
    //
    // The unbanked generated code and the module data must CONTINUE the
    // harness's single `.code_regions` flow, so the assembler's auto-spill can
    // carry the unbanked program across the screen, bank-window and heap gaps.
    // An `.org` back to the main region here would reset PC on top of the
    // runtime's own spill and let the multi-KB float runtime overflow into
    // screen RAM. Hence the order: unbanked functions with no `.org`, then the
    // module data, then the banked `.org` pages as a separate block.
    //
    // Functions render into buffers first because the module-data pass has to
    // see the COMPLETE spill declarations — from the banked functions too —
    // before it is emitted between them.
    void emitBanked(IRModule* m)
    {
        assignBanks(m);
        String* unbanked = new String();
        String* banked = new String();
        String* real = _out;
        beginPlacement();
        IRFunc* entry = entryFunction(m);

        _out = unbanked;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0) continue;
            if (bankForCallee(fn.name()) != (u32)0) continue;
            _currentBank = (u32)0;
            u32 before = _out.byteLength();
            emitFunction(fn);
            String* note = (String*)0;
            if (fn == entry) note = String.withCString("entry");
            else if (!isIrq(fn) && !isVbi(fn) && keptInMain(fn.name())) {
                note = String.withCString("");
                note.appendFormat("%lu instructions, under -Fmb %lu",
                                  insnCountOf(fn.name()), _fnMinBanked);
            }
            notePlacement(fn, (u32)0, _out.substringFromByte(before), note);
        }
        _out = banked;
        for (u32 b = (u32)1; b <= _bankCount; b = b + (u32)1) {
            _out.appendFormat("; --- code bank %lu (via $%s) ---\n",
                              b, hex4(_layout.codeBankReg()).cString());
            _out.appendFormat("    .org $%s\n", hex4(_layout.bankWindowStart()).cString());
            for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
                IRFunc* fn = (IRFunc*)m.funcs().get(f);
                if (fn.blocks().count() == (u32)0) continue;
                if (bankForCallee(fn.name()) != b) continue;
                _currentBank = b;
                u32 before = _out.byteLength();
                emitFunction(fn);
                notePlacement(fn, b, _out.substringFromByte(before), (String*)0);
            }
        }
        finishPlacement(_layout.bankWindowEnd() - _layout.bankWindowStart() + (u32)1);
        _out = real;
        _out.appendCString("; --- unbanked code + data (continues the harness region flow — no .org) ---\n");
        _out.append(unbanked);
        emitModuleData(m);
        _out.append(banked);
    }

    u32 _bankCount;

    // The entry stays unbanked — the harness reaches it with a direct JSR — as
    // do the hardware-dispatched handlers: the ROM jumps straight to an :irq or
    // :vbi body with no trampoline, so it cannot live behind a bank register.
    // Everything else banks, first-fit in module order.
    //
    // Sizing is iterative because a cross-bank call site is wider than a plain
    // JSR, and which calls are cross-bank is exactly what the placement
    // decides. Re-render with the CURRENT map, re-pack, repeat until the map
    // stops moving — the same convergence the assembler's long-branch rewriter
    // uses.
    Map* _insnCounts;           // function name -> instructions, for -Fmb

    u32 insnCountOf(String* name)
    {
        if (_insnCounts == (Map*)0) return (u32)0;
        Object* o = _insnCounts.get((Hashable*)name);
        return o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
    }

    // Under -Fmb, a function smaller than the threshold stays in main RAM.
    bool keptInMain(String* name)
    {
        if (_fnMinBanked == (u32)0 || _insnCounts == (Map*)0) return false;
        Object* o = _insnCounts.get((Hashable*)name);
        return o != (Object*)0 && ((Number*)o).asU32() < _fnMinBanked;
    }

    void assignBanks(IRModule* m)
    {
        _insnCounts = new Map();
        _bankMap = new Map();
        _bankCount = (u32)0;
        u32 bankSize = _layout.bankWindowEnd() - _layout.bankWindowStart() + (u32)1;
        // The first pack has no map at all, so it cannot see any cross-bank
        // expansion; hold it a safe margin below the real bank size and let the
        // unused tail spill into the next of the 16 banks.
        packBanks(m, measureSizes(m, false),
                  bankSize > (u32)2048 ? bankSize - (u32)2048 : bankSize);
        // Refinement measures exactly, so it packs against a much smaller
        // margin — 1 KB, to absorb the assembler's own branch expansion.
        u32 refined = bankSize > (u32)1024 ? bankSize - (u32)1024 : bankSize;
        for (u32 iter = (u32)0; iter < (u32)8; iter = iter + (u32)1) {
            Map* before = _bankMap;
            packBanks(m, measureSizes(m, true), refined);
            if (sameBankMap(m, before, _bankMap)) break;
        }
        // The emission loop runs 1.._bankCount, so the count MUST come from the
        // FINAL map: a function the refinement pushed into a bank beyond a
        // stale count would never be emitted at all, and its label would
        // resolve to $0000.
        _bankCount = (u32)0;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            u32 b = bankForCallee(((IRFunc*)m.funcs().get(f)).name());
            if (b > _bankCount) _bankCount = b;
        }
    }

    // Render each function into a throwaway buffer and measure it. The
    // per-call pad covers the trampoline the assembler expands each cross-bank
    // JSR into, which the rendered text does not yet show.
    Map* measureSizes(IRModule* m, bool withMap)
    {
        Map* sizes = new Map();
        String* real = _out;
        Array* realSpills = _spillDecls;
        Map* realMap = _bankMap;
        if (!withMap) { _bankMap = new Map(); _bankingOff = true; }
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0) continue;
            _out = new String();
            _spillDecls = new Array();
            _currentBank = withMap ? bankForCallee(fn.name()) : (u32)0;
            emitFunction(fn);
            sizes.set((Hashable*)fn.name(),
                      (Object*)Number.withU32(asmByteSize(_out) + (u32)16 * callCount(fn)));
            // -Fmb decides from this first, bank-independent render only, so
            // the choice cannot move while the refinement iterates.
            if (!withMap)
                _insnCounts.set((Hashable*)fn.name(), (Object*)Number.withU32(asmInsnCount(_out)));
        }
        _out = real;
        _spillDecls = realSpills;
        _bankMap = realMap;
        _bankingOff = false;
        return sizes;
    }

    static u32 callCount(IRFunc* fn)
    {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (((IRInsn*)bb.insns().get(i)).op().equals(String.withCString("Call")))
                    n = n + (u32)1;
        }
        return n;
    }

    void packBanks(IRModule* m, Map* sizes, u32 budget)
    {
        Map* map = new Map();
        IRFunc* entry = entryFunction(m);
        u32 count = (u32)0;
        u32 used = (u32)0;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0) continue;
            if (fn == entry || mustStayUnbanked(fn.name()) || keptInMain(fn.name())) {
                map.set((Hashable*)fn.name(), (Object*)Number.withU32((u32)0));
                continue;
            }
            Object* szo = sizes.get((Hashable*)fn.name());
            u32 sz = szo == (Object*)0 ? (u32)0 : ((Number*)szo).asU32();
            if (count == (u32)0 || used + sz > budget) { count = count + (u32)1; used = (u32)0; }
            map.set((Hashable*)fn.name(), (Object*)Number.withU32(count));
            used = used + sz;
        }
        _bankMap = map;
    }

    bool sameBankMap(IRModule* m, Map* a, Map* b)
    {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            String* n = ((IRFunc*)m.funcs().get(f)).name();
            Object* x = a.get((Hashable*)n);
            Object* y = b.get((Hashable*)n);
            u32 xv = x == (Object*)0 ? (u32)0 : ((Number*)x).asU32();
            u32 yv = y == (Object*)0 ? (u32)0 : ((Number*)y).asU32();
            if (xv != yv) return false;
        }
        return true;
    }

    // `main` if the module has one, else the first function with a body —
    // mirroring the harness's own choice, so the entry JSR reaches it directly.
    static IRFunc* entryFunction(IRModule* m)
    {
        IRFunc* first = (IRFunc*)0;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0) continue;
            if (fn.name().equals(String.withCString("main"))) return fn;
            if (first == (IRFunc*)0) first = fn;
        }
        return first;
    }

    bool mustStayUnbanked(String* name)
    {
        if (_m == (IRModule*)0) return false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.kind() != (u8)SYM_FUNCTION || !s.name().equals(name)) continue;
            return s.irq() || s.vbi();
        }
        return false;
    }

    // ── Assembled-size estimate ──────────────────────────────────────────
    //
    // One line, one instruction. This only has to be an UPPER bound: the
    // packer must never let a function silently overflow its bank, and the
    // assembler's own region checks are the real backstop. So a branch counts
    // as 5 bytes — its worst case after the assembler rewrites an
    // out-of-range one into inverse-branch-plus-JMP — rather than 2.
    u32 asmByteSize(String* text)
    {
        u32 total = (u32)0;
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* line = ((String*)lines.get(i)).trimmed();
            if (line.byteLength() == (u32)0 || line.hasPrefix(String.withCString(";"))) continue;
            u32 sc = line.byteIndexOf(String.withCString(";"));
            if (sc != (u32)$FFFF_FFFF) {
                line = line.substringBytes((u32)0, sc).trimmed();
                if (line.byteLength() == (u32)0) continue;
            }
            if (line.hasSuffix(String.withCString(":"))) continue;      // label only
            u32 colon = line.byteIndexOf(String.withCString(":"));
            if (colon != (u32)$FFFF_FFFF) {
                line = line.substringFromByte(colon + (u32)1).trimmed();
                if (line.byteLength() == (u32)0) continue;
            }
            u32 ws = firstSpace(line);
            String* mn = ws == (u32)$FFFF_FFFF ? line : line.substringBytes((u32)0, ws);
            String* operand = ws == (u32)$FFFF_FFFF ? String.withCString("")
                                                    : line.substringFromByte(ws).trimmed();
            String* m = mn.uppercased();
            if (m.equals(String.withCString(".BYTE")))  { total = total + commaCount(operand); continue; }
            if (m.equals(String.withCString(".WORD")))  { total = total + (u32)2 * commaCount(operand); continue; }
            if (m.equals(String.withCString(".SPACE"))) { total = total + parseNum(operand); continue; }
            if (m.hasPrefix(String.withCString("."))) continue;         // other directives
            if (isBranchMnemonic(m)) { total = total + (u32)5; continue; }
            if (m.equals(String.withCString("PSH")) || m.equals(String.withCString("PLL"))
             || m.equals(String.withCString("ADD"))) { total = total + (u32)2; continue; }
            if (operand.byteLength() == (u32)0) { total = total + (u32)1; continue; }   // implied
            if (operand.hasPrefix(String.withCString("#"))) { total = total + (u32)2; continue; }
            if (operand.hasPrefix(String.withCString("("))) {
                total = total + (m.equals(String.withCString("JMP")) ? (u32)3 : (u32)2);
                continue;
            }
            if (operand.byteIndexOf(String.withCString(",SP")) != (u32)$FFFF_FFFF)
                { total = total + (u32)2; continue; }
            if (m.equals(String.withCString("JMP")) || m.equals(String.withCString("JSR")))
                { total = total + (u32)3; continue; }
            if (operand.hasPrefix(String.withCString("$"))) {
                u32 comma = operand.byteIndexOf(String.withCString(","));
                u32 baseLen = comma == (u32)$FFFF_FFFF ? operand.byteLength() : comma;
                total = total + (baseLen - (u32)1 <= (u32)2 ? (u32)2 : (u32)3);
                continue;
            }
            total = total + (u32)3;                                     // symbol → absolute
        }
        return total;
    }

    // The instructions in rendered text: every line that is not blank, a
    // comment, a bare label or a directive.
    u32 asmInsnCount(String* text)
    {
        u32 n = (u32)0;
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* line = ((String*)lines.get(i)).trimmed();
            if (line.byteLength() == (u32)0 || line.hasPrefix(String.withCString(";"))) continue;
            u32 sc = line.byteIndexOf(String.withCString(";"));
            if (sc != (u32)$FFFF_FFFF) {
                line = line.substringBytes((u32)0, sc).trimmed();
                if (line.byteLength() == (u32)0) continue;
            }
            if (line.hasSuffix(String.withCString(":"))) continue;
            u32 colon = line.byteIndexOf(String.withCString(":"));
            if (colon != (u32)$FFFF_FFFF) {
                line = line.substringFromByte(colon + (u32)1).trimmed();
                if (line.byteLength() == (u32)0) continue;
            }
            if (line.hasPrefix(String.withCString("."))) continue;
            n = n + (u32)1;
        }
        return n;
    }

    static bool isBranchMnemonic(String* m)
    {
        return m.equals(String.withCString("BEQ")) || m.equals(String.withCString("BNE"))
            || m.equals(String.withCString("BCC")) || m.equals(String.withCString("BCS"))
            || m.equals(String.withCString("BPL")) || m.equals(String.withCString("BMI"))
            || m.equals(String.withCString("BVC")) || m.equals(String.withCString("BVS"))
            || m.equals(String.withCString("BRA"));
    }

    static u32 firstSpace(String* s)
    {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t') return i;
        }
        return (u32)$FFFF_FFFF;
    }

    static u32 commaCount(String* s)
    {
        u32 n = (u32)1;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == (u8)',') n = n + (u32)1;
        return n;
    }

    static u32 parseNum(String* s)
    {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9') break;
            n = n * (u32)10 + (u32)(c - (u8)'0');
        }
        return n;
    }

    // ── Module data ──────────────────────────────────────────────────────
    void emitModuleData(IRModule* m)
    {
        if (_spillDecls != (Array*)0 && _spillDecls.count() > (u32)0) {
            _out.appendCString("; Pinned-local spill slots (STACK-ABI §11.3)\n");
            for (u32 i = (u32)0; i + (u32)1 < _spillDecls.count(); i = i + (u32)2)
                _out.appendFormat("%s: .space %lu\n",
                                  ((String*)_spillDecls.get(i)).cString(),
                                  ((Number*)_spillDecls.get(i + (u32)1)).asU32());
        }
        bool header = false;
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_DATAGLOBAL || s.globalTy() == (String*)0) continue;
            u32 size = byteWidth(s.globalTy());
            if (size == (u32)0) size = (u32)2;
            if (!header) { _out.appendCString("; Module data\n"); header = true; }
            Array* bytes = s.bytes();
            // A float initialiser arrives as raw IEEE DOUBLE bits — the
            // abstract value — so it is re-encoded at the target's own width
            // here. Copying the eight bytes through would write a double where
            // the loads read a single.
            if (bytes != (Array*)0 && bytes.count() > (u32)0
                && isFloatTy(s.globalTy()) && bytes.count() != size)
                bytes = encodeFloatHex(hexOfBytes(bytes), size);
            if (bytes != (Array*)0 && bytes.count() > (u32)0) {
                String* vals = new String();
                for (u32 b = (u32)0; b < bytes.count(); b = b + (u32)1) {
                    if (b > (u32)0) vals.appendCString(",");
                    vals.appendFormat("$%s", hex2(((Number*)bytes.get(b)).asU32()).cString());
                }
                for (u32 b = bytes.count(); b < size; b = b + (u32)1) vals.appendCString(",$00");
                _out.appendFormat("_%s: .byte %s\n", s.name().cString(), vals.cString());
            } else {
                _out.appendFormat("_%s: .space %lu\n", s.name().cString(), size);
            }
        }
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_STRINGLIT) continue;
            if (!header) { _out.appendCString("; Module data\n"); header = true; }
            Array* bytes = s.bytes();
            if (bytes == (Array*)0 || bytes.count() == (u32)0) {
                _out.appendFormat("_%s: .byte $00\n", s.name().cString());
                continue;
            }
            String* vals = new String();
            for (u32 b = (u32)0; b < bytes.count(); b = b + (u32)1) {
                if (b > (u32)0) vals.appendCString(",");
                vals.appendFormat("$%s", hex2(((Number*)bytes.get(b)).asU32()).cString());
            }
            _out.appendFormat("_%s: .byte %s\n", s.name().cString(), vals.cString());
        }
        // A vtable slot is three bytes — `.byte <bank>` then `.word <addr>`.
        // The bank lets dispatch select the code window before the indirect
        // jump, so a vtable target can live in a bank instead of being pinned
        // unbanked. NOTE the slot's byte order [bank, lo, hi] is NOT a function
        // pointer VALUE's [lo, hi, bank]; anything reading a slot into a
        // pointer has to transpose.
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_VTABLE) continue;
            if (!header) { _out.appendCString("; Module data\n"); header = true; }
            Array* slots = s.slots();
            if (slots == (Array*)0 || slots.count() == (u32)0) {
                _out.appendFormat("_%s: .byte $00\n    .word $0000\n", s.name().cString());
                continue;
            }
            _out.appendFormat("_%s:\n", s.name().cString());
            for (u32 k = (u32)0; k < slots.count(); k = k + (u32)1) {
                String* e = (String*)slots.get(k);
                if (e == (String*)0 || e.byteLength() == (u32)0) {
                    _out.appendCString("    .byte $00\n    .word $0000\n");
                    continue;
                }
                _out.appendFormat("    .byte $%s\n    .word _%s\n",
                                  hex2(bankForCallee(e)).cString(), e.cString());
            }
        }
        // Every function's code bank as a link-time constant, because `AddrOf
        // @fn` bakes it into byte 2 of the three-byte function pointer so a
        // later indirect call can bank-switch to it. The allocator's dealloc
        // descriptor reads the same constant — it used to hard-code bank 1,
        // which was wrong the moment a destructor packed into bank 2.
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0) continue;
            _out.appendFormat("__dbank_%s = $%s\n", fn.name().cString(),
                              hex2(bankForCallee(fn.name())).cString());
        }
        // Aliases so an inline-asm reference to the source-level name resolves
        // to the underscored label rather than being silently taken as an
        // undefined symbol — which the assembler resolves to $0000.
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_DATAGLOBAL) continue;
            _out.appendFormat("%s = _%s\n", s.name().cString(), s.name().cString());
        }
    }

    // Banking is active when the layout declares BOTH a code window and an
    // unbanked region to overflow from.
    bool banking(void)
    {
        if (_bankingOff) return false;
        return _layout.hasBanking() && _layout.bankWindowStart() != (u32)0
            && _layout.mainRanges().count() > (u32)0;
    }

    // The FIRST sizing pass renders as though the target were flat — there is
    // no bank map yet, so there is nothing for a bank-select or a cross-bank
    // call site to key off. Leaving banking on there measured bank-select code
    // that the placement had not yet decided on, and one function landed a bank
    // late.
    bool _bankingOff;

    // `.code_regions` tells the assembler where code may live, so it fails the
    // build on an overflow rather than spilling into screen RAM. On the BANKED
    // path the runtime harness owns a single unified declaration that also
    // covers the system region — and the assembler RESETS its region list on
    // every `.code_regions`, so emitting a second one here would re-split the
    // two blocks and let the runtime silently overrun into screen RAM.
    void emitCodeRegions(void)
    {
        if (_layout.mainRanges().count() == (u32)0) return;
        _out.appendFormat("; memory model: %s (entry $%s)\n",
                          _layout.name().cString(), hex4(_layout.entryAddress()).cString());
        if (banking()) {
            _out.appendCString("; (banked: unified .code_regions provided by the runtime harness — task #121)\n");
            return;
        }
        _out.appendCString(".code_regions ");
        for (u32 i = (u32)0; i < _layout.mainRanges().count(); i = i + (u32)1) {
            LayoutRange* r = (LayoutRange*)_layout.mainRanges().get(i);
            if (i > (u32)0) _out.appendCString(", ");
            _out.appendFormat("$%s-$%s", hex4(r.lo()).cString(), hex4(r.hi()).cString());
        }
        _out.appendCString("\n");
    }

    // One blank line closes the header, banked or flat.
    void emitHeaderGap(void) { _out.appendCString("\n"); }

    void emitFunction(IRFunc* fn)
    {
        _fn = fn;
        _labelCounter = (u32)0;
        _callSaveSets = (Map*)0;
        _usesSoftStack = false;
        _frameOffsets = new Map();
        _frameLocalsSize = (u32)0;
        // The calling convention: `:xtcStack` / `:hwStack` on the function,
        // else the --xtc-stack default. An interrupt handler keeps its shape.
        _xtcStack = !isIrq(fn) && !isVbi(fn)
            && (symbolAttr(fn.name(), String.withCString("xtcstack"))
                || (_xtcStackDefault && !symbolAttr(fn.name(), String.withCString("hwstack"))));
        _frameLocalsBase = _xtcStack ? (u32)1 : (u32)7;
        _softFrameHeader = _xtcStack ? (u32)8 : (u32)2;
        if (_xtcStack) {
            if (_layout.stackEnd() == (u32)0)
                { unsupported(String.withCString("xtcstack:nostackregion")); return; }
            _usesSoftStack = true;
        }
        resetZp();
        _isLeaf = functionIsLeaf(fn);
        Array* pinned = collectPinned(fn);
        computeFrameSlots(fn, pinned);
        placeParamsInPlace(fn, pinned);
        placeAddressableValues(fn, pinned);
        computeKnownAddrs(fn);
        if (!checkFrameBudget(fn)) return;
        emitPrologue(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            emitBlock(fn, (IRBlock*)fn.blocks().get(b));
        _out.appendCString("\n");
    }

    bool _isLeaf;

    // The xtc-stack calling convention (`:xtcStack`, or `--xtc-stack` on a
    // function without `:hwStack`): the return address and the registers PSH
    // would save go into the software-stack frame instead. The prologue pulls
    // the return address off the hardware stack, so the hardware frame holds
    // only the SP-frame locals, at +1..+N with no guard byte or saved
    // registers, and the parameters start at +N+1. The software frame's header
    // grows from the caller's FP (2 bytes) to FP, return address, P, A, X and
    // Y (8 bytes).
    bool _xtcStack;
    u32  _frameLocalsBase;      // 7, or 1 under the xtc-stack convention
    u32  _softFrameHeader;      // 2, or 8 under the xtc-stack convention

    // The SP-relative offset of the first parameter byte once the prologue
    // has run: +N+10 after PSH #N, +N+1 under the xtc-stack convention.
    u32 paramBase(void)
    {
        return _xtcStack ? _spFrameSize + (u32)1 : _spFrameSize + (u32)10;
    }

    // A value must stay in ADDRESSABLE storage — zero page or a spill slot,
    // never the hidden hardware stack — as soon as its address is ever formed.
    // Two ways that happens: it is a declared pinned local, or it is the
    // operand of an AddrOf. The second catches address-taken PARAMETERS, which
    // are not in the frame info, since a parameter's slot was historically its
    // addressability.
    Array* collectPinned(IRFunc* fn)
    {
        Array* out = new Array();
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            addVal(out, ((IRPinned*)fn.pinned().get(i)).val());
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("AddrOf"))) continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE) addVal(out, o.val());
                }
            }
        }
        // An inline-asm reference to a local needs ZP-style addressing —
        // `name`, `name+1`, `(name),Y` — which the hidden stack cannot
        // provide, so anything an asm block names is pinned too.
        collectAsmLocals(fn, out);
        return out;
    }

    void collectAsmLocals(IRFunc* fn, Array* out)
    {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("Asm"))) continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_CPOOL) continue;
                    if (_m == (IRModule*)0 || o.cid() >= _m.consts().count()) continue;
                    pinAsmLocals(fn, bytesToString((Array*)_m.consts().get(o.cid())), out);
                }
            }
        }
    }

    void pinAsmLocals(IRFunc* fn, String* text, Array* out)
    {
        String* marker = String.withCString("{{XTLOCAL:");
        u32 i = (u32)0;
        while (true) {
            u32 at = text.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF) return;
            u32 j = at + marker.byteLength();
            u32 vid = (u32)0;
            while (j < text.byteLength() && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9') {
                vid = vid * (u32)10 + (u32)(text.byteAt(j) - (u8)'0');
                j = j + (u32)1;
            }
            IRValue* v = fn.valueWithId(vid);
            if (v != (IRValue*)0) addVal(out, v);
            i = j;
        }
    }

    static String* bytesToString(Array* bytes)
    {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            o.appendByte((u8)((Number*)bytes.get(i)).asU32());
        return o;
    }

    // A user parameter is addressed IN PLACE at its incoming caller-stack
    // offset rather than copied to a fresh local, so the prologue's per-call
    // entry copy collapses to a self-move and is skipped.
    //
    // After `PSH #N` the frame reads
    //   [guard@+0, regs@+1..+6, locals@+7..+N+6, gap@+N+7,
    //    ret@+N+8..+N+9, params@+N+10..]
    // so parameter 0 starts at +N+10, and byte 0 — the LSB — is at the lower
    // offset.
    void placeParamsInPlace(IRFunc* fn, Array* pinned)
    {
        u32 n = fn.params().count();
        u32 user = n;
        if (n > (u32)0 && isMemTy(((IRValue*)fn.params().get(n - (u32)1)).ty()))
            user = n - (u32)1;
        u32 off = paramBase();
        for (u32 i = (u32)0; i < user; i = i + (u32)1) {
            IRValue* p = (IRValue*)fn.params().get(i);
            u32 w = byteWidth(p.ty());
            if (w == (u32)0) continue;
            // A pinned parameter keeps its addressable home; only its
            // incoming copy reads this offset.
            if (!hasVal(pinned, p))
                _spFrameBase.set((Hashable*)p, (Object*)Number.withU32(off));
            off = off + w;
        }
    }

    // Pinned locals and other address-taken values live in ADDRESSABLE storage
    // — zero page first, spilling to main RAM when it runs out. They can never
    // live on the hidden hardware stack, which LDA/STA and `(zp),Y` cannot
    // reach at all.
    Map* _spillLabel;           // value -> its main-RAM spill label

    void placeAddressableValues(IRFunc* fn, Array* pinned)
    {
        _spillLabel = new Map();
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1) {
            IRPinned* pl = (IRPinned*)fn.pinned().get(i);
            IRValue* pv = pl.val();
            if (pv == (IRValue*)0) continue;
            u32 width = byteWidth(pv.ty());
            if (width == (u32)0) continue;
            // The ZP pinned-local pool is SHARED BY EVERY FUNCTION, so a local
            // whose pointer is dereferenced across a call — a stack-allocated
            // class instance reached through self — cannot live there: a
            // callee, even a transitively reached one, would reuse the pool and
            // clobber it. Those go straight to a per-function spill, a stable
            // address no callee can take.
            i32 base = pl.esc() ? (i32)-1 : tryAllocateZP(width);
            if (base >= (i32)0) {
                _zpBase.set((Hashable*)pv, (Object*)Number.withU32((u32)base));
                continue;
            }
            spillToMain(fn, pv, width);
        }
        // An address-taken value that was never DECLARED a pinned local — a
        // by-value struct parameter read through AddrOf and FieldAddr — still
        // needs addressable storage, and was excluded from the frame above.
        // In a DETERMINISTIC order — parameters, then each block's phis,
        // instructions and terminator — because the ZP pool is handed out
        // first-come and the order therefore decides the addresses.
        Array* extra = new Array();
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            collectExtraAddrTaken(extra, (IRValue*)fn.params().get(i), pinned);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            Array* seq = allInsns((IRBlock*)fn.blocks().get(b));
            for (u32 i = (u32)0; i < seq.count(); i = i + (u32)1)
                collectExtraAddrTaken(extra, ((IRInsn*)seq.get(i)).res(), pinned);
        }
        for (u32 i = (u32)0; i < extra.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)extra.get(i);
            u32 width = byteWidth(v.ty());
            i32 base = tryAllocateZP(width);
            if (base >= (i32)0) {
                _zpBase.set((Hashable*)v, (Object*)Number.withU32((u32)base));
                continue;
            }
            spillToMain(fn, v, width);
        }
    }

    // A candidate is address-taken, has a width, and has not already been given
    // a home — including a software-stack FRAME slot. Missing that last test
    // hands a framed local a second, ZP home: nothing reads it, but it is live
    // across every call, so each call site saves and restores a byte that does
    // not exist as far as the rest of the function is concerned.
    void collectExtraAddrTaken(Array* out, IRValue* v, Array* pinned)
    {
        if (v == (IRValue*)0 || !hasVal(pinned, v)) return;
        if (slotOf(v) >= (i32)0) return;
        if (_spillLabel.get((Hashable*)v) != (Object*)0) return;
        if (_frameOffsets.get((Hashable*)v) != (Object*)0) return;
        if (byteWidth(v.ty()) == (u32)0) return;
        if (hasVal(out, v)) return;
        out.add((Object*)v);
    }

    Array* _spillDecls;         // (label, width) pairs the module data emits

    void spillToMain(IRFunc* fn, IRValue* v, u32 width)
    {
        // A LEAF is never re-entered, so a static slot is safe. A non-leaf
        // would alias across re-entry, so it gets a per-invocation frame on the
        // software stack instead (STACK-ABI 11.3) — which needs the layout to
        // declare a [stack] region.
        if (!_isLeaf) {
            if (_layout.stackEnd() == (u32)0)
                { unsupported(String.withCString("spill:nostackregion")); return; }
            _usesSoftStack = true;
            _frameOffsets.set((Hashable*)v, (Object*)Number.withU32(_frameLocalsSize));
            _frameLocalsSize = _frameLocalsSize + width;
            return;
        }
        String* label = String.withCString("_spill_");
        label.append(fn.name());
        label.appendCString("_");
        label.appendFormat("%lu", v.pid());
        _spillLabel.set((Hashable*)v, (Object*)label);
        if (_spillDecls == (Array*)0) _spillDecls = new Array();
        _spillDecls.add((Object*)label);
        _spillDecls.add((Object*)Number.withU32(width));
    }

    // Three prologue shapes. An `:irq` handler is NAKED — no PSH at all, so
    // the body's first byte is its first opcode. A `:vbi` handler saves A, X
    // and Y by hand, because the ROM dispatches deferred VBIs without saving
    // anything and the handler is expected to preserve them itself. Everything
    // else uses `PSH #N`, which saves the six registers plus the guard byte
    // and allocates N local bytes in one instruction.
    void emitPrologue(IRFunc* fn)
    {
        _out.appendFormat("_%s:\n", fn.name().cString());
        _spDelta = (i32)0;
        if (isIrq(fn)) return;
        if (isVbi(fn)) {
            _out.appendCString("    PHA\n    TXA\n    PHA\n    TYA\n    PHA\n");
            return;
        }
        if (_xtcStack) emitXtcStackPrologue();
        else _out.appendFormat("    PSH #%lu\n", _spFrameSize);
        emitEntryArgZero(fn);
        emitParamSpill(fn);
        if (!_xtcStack) emitSoftStackPush();
    }

    // The xtc-stack prologue. Where PSH #N keeps the registers and the return
    // address on the hardware stack, this moves them into a frame on the
    // software stack:
    //   FP+0,+1  caller's FP      FP+2,+3  return address (hi, lo)
    //   FP+4     P   FP+5 A   FP+6 X   FP+7 Y      FP+8..  spilled locals
    // P, A, X and Y are pushed first so they reach the frame unchanged, then
    // pulled with the return address beneath them. The hardware stack then
    // holds only the N SP-frame local bytes, allocated with ADD SP, and the
    // arguments the caller pushed.
    void emitXtcStackPrologue(void)
    {
        _out.appendCString("    ; --- xtc-stack frame push: return address and registers ---\n");
        _out.appendCString("    PHP\n    PHA\n    TXA\n    PHA\n    TYA\n    PHA\n");
        _out.appendCString("    LDY #$07\n");
        // Y, X, A, P, return address lo, return address hi: FP+7 down to FP+2.
        for (u32 k = (u32)0; k < (u32)6; k = k + (u32)1) {
            if (k > (u32)0) _out.appendCString("    DEY\n");
            _out.appendCString("    PLA\n    STA ($8A),Y\n");
        }
        _out.appendCString("    DEY\n    LDA $8D\n    STA ($8A),Y\n");   // caller FP hi
        _out.appendCString("    DEY\n    LDA $8C\n    STA ($8A),Y\n");   // caller FP lo
        u32 total = _softFrameHeader + _frameLocalsSize;
        _out.appendCString("    LDA $8A\n    STA $8C\n");                 // FP = SSP
        _out.appendCString("    LDA $8B\n    STA $8D\n");
        _out.appendCString("    CLC\n");                                  // SSP += total
        _out.appendFormat("    LDA $8A\n    ADC #$%s\n    STA $8A\n",
                          hex2(total & (u32)$FF).cString());
        _out.appendFormat("    LDA $8B\n    ADC #$%s\n    STA $8B\n",
                          hex2((total >> (u32)8) & (u32)$FF).cString());
        if (_spFrameSize > (u32)0)
            _out.appendFormat("    ADD SP, #-%lu\n", _spFrameSize);
    }

    // The matching epilogue, run once the return value is staged in $B0..:
    // free the SP-frame locals, push the return address back with the saved
    // registers above it, drop the software frame (SSP = FP, FP = the caller's
    // FP), then pull Y, X, A and P. The caller emits the result and the RTS.
    void emitXtcStackEpilogue(void)
    {
        if (_spFrameSize > (u32)0)
            _out.appendFormat("    ADD SP, #%lu\n", _spFrameSize);
        _out.appendCString("    ; --- xtc-stack frame pop: return address and registers ---\n");
        _out.appendCString("    LDY #$02\n");
        // Return address hi, lo, then P, A, X, Y: FP+2 up to FP+7.
        for (u32 k = (u32)0; k < (u32)6; k = k + (u32)1) {
            if (k > (u32)0) _out.appendCString("    INY\n");
            _out.appendCString("    LDA ($8C),Y\n    PHA\n");
        }
        _out.appendCString("    LDA $8C\n    STA $8A\n");                 // SSP = FP
        _out.appendCString("    LDA $8D\n    STA $8B\n");
        _out.appendCString("    LDY #$01\n    LDA ($8A),Y\n    STA $8D\n"); // FP = caller FP
        _out.appendCString("    DEY\n    LDA ($8A),Y\n    STA $8C\n");
        _out.appendCString("    PLA\n    TAY\n    PLA\n    TAX\n    PLA\n    PLP\n");
    }

    // The entry function is reached from the startup code, which pushes
    // nothing — so a `main` that declares argc/argv would read whatever the
    // stack happened to hold. Zero its incoming parameter bytes, which is
    // argc == 0 and argv == NULL on a target with no command line (bug 121).
    void emitEntryArgZero(IRFunc* fn)
    {
        // NOT entryFunction() — it falls back to the FIRST function when a
        // module has no `main`, and zeroing there wipes a caller's pushed
        // arguments. The entry is `main` by name; `_main` -> `_xt_main` is an
        // asm-text rename applied after codegen.
        if (!fn.name().equals(String.withCString("main"))) return;
        u32 user = userParamCount(fn);
        if (user == (u32)0) return;
        u32 off = paramBase();
        u32 end = off;
        for (u32 i = (u32)0; i < user; i = i + (u32)1)
            end = end + byteWidth(((IRValue*)fn.params().get(i)).ty());
        _out.appendCString("    ; entry: no caller pushed our args — "
                           "argc=0, argv=NULL (bug 121)\n");
        _out.appendCString("    LDA #$00\n");
        for (; off < end; off = off + (u32)1)
            _out.appendFormat("    STA +%lu,SP\n", off);
    }

    // Copy the user parameters from the caller's stack into their homes. Any
    // parameter left addressed IN PLACE gives a self-move, which is skipped —
    // in a function with no pinned parameters this whole loop emits nothing.
    void emitParamSpill(IRFunc* fn)
    {
        u32 user = userParamCount(fn);
        u32 off = paramBase();
        for (u32 i = (u32)0; i < user; i = i + (u32)1) {
            IRValue* p = (IRValue*)fn.params().get(i);
            u32 w = byteWidth(p.ty());
            for (u32 b = (u32)0; b < w; b = b + (u32)1) {
                String* dest = operandFor(p, b);
                String* src = String.withCString("+");
                src.appendFormat("%lu,SP", off + b);
                if (dest != (String*)0 && dest.equals(src)) continue;
                _out.appendFormat("    LDA %s\n", src.cString());
                _out.appendFormat("    STA %s\n",
                                  dest == (String*)0 ? "$00" : dest.cString());
            }
            off = off + w;
        }
    }

    // The trailing Mem parameter is a phantom, not a real incoming argument.
    static u32 userParamCount(IRFunc* fn)
    {
        u32 n = fn.params().count();
        if (n > (u32)0 && isMemTy(((IRValue*)fn.params().get(n - (u32)1)).ty()))
            return n - (u32)1;
        return n;
    }

    // The SP frame plus the incoming parameters must fit the 119-byte budget.
    // Only SP-frame bytes count: a pinned local lives in zero page or a
    // main-RAM spill, so counting it here once wrongly refused a 300-byte
    // array that was never on the stack at all.
    bool checkFrameBudget(IRFunc* fn)
    {
        u32 k = (u32)0;
        u32 user = userParamCount(fn);
        for (u32 i = (u32)0; i < user; i = i + (u32)1)
            k = k + byteWidth(((IRValue*)fn.params().get(i)).ty());
        if (_spFrameSize + k > (u32)119) {
            unsupported(String.withCString("frame:budget"));
            return false;
        }
        return true;
    }

    bool _usesSoftStack;
    Map* _frameOffsets;         // value -> its byte offset in the locals area
    u32  _frameLocalsSize;

    // A per-invocation frame on the software stack, for the non-leaf pinned
    // locals that missed zero page (STACK-ABI 11.3). It reserves 2 +
    // frameLocalsSize bytes at SSP: the first two hold the caller's FP, the
    // rest are the locals. Emitted AFTER the parameter spill so the
    // SP-relative parameter offsets above are untouched.
    void emitSoftStackPush(void)
    {
        if (!_usesSoftStack) return;
        u32 total = (u32)2 + _frameLocalsSize;
        _out.appendCString("    ; --- software-stack frame push (§11.3) ---\n");
        _out.appendCString("    LDY #$00\n");
        _out.appendCString("    LDA $8C\n    STA ($8A),Y\n");     // caller FP lo
        _out.appendCString("    INY\n");
        _out.appendCString("    LDA $8D\n    STA ($8A),Y\n");     // caller FP hi
        _out.appendCString("    LDA $8A\n    STA $8C\n");         // FP = SSP
        _out.appendCString("    LDA $8B\n    STA $8D\n");
        _out.appendCString("    CLC\n");                          // SSP += total
        _out.appendFormat("    LDA $8A\n    ADC #$%s\n    STA $8A\n",
                          hex2(total & (u32)$FF).cString());
        _out.appendFormat("    LDA $8B\n    ADC #$%s\n    STA $8B\n",
                          hex2((total >> (u32)8) & (u32)$FF).cString());
    }

    // The matching pop: SSP = FP (drop this frame), FP = the caller FP saved at
    // the frame base. It clobbers A/X/Y but not $B0.., so a staged return value
    // survives it.
    void emitSoftStackPop(void)
    {
        if (!_usesSoftStack) return;
        _out.appendCString("    ; --- software-stack frame pop (§11.3) ---\n");
        _out.appendCString("    LDY #$00\n");
        _out.appendCString("    LDA ($8C),Y\n");                  // caller FP lo
        emitPHA();
        _out.appendCString("    INY\n");
        _out.appendCString("    LDA ($8C),Y\n");                  // caller FP hi
        _out.appendCString("    TAX\n");
        _out.appendCString("    LDA $8C\n    STA $8A\n");         // SSP = FP
        _out.appendCString("    LDA $8D\n    STA $8B\n");
        emitPLA();                                                 // FP = caller FP
        _out.appendCString("    STA $8C\n    STX $8D\n");
    }

    bool isIrq(IRFunc* fn) { return symbolFlag(fn.name(), String.withCString("irq")); }
    bool isVbi(IRFunc* fn) { return symbolFlag(fn.name(), String.withCString("vbi")); }

    // A generically carried symbol attribute — `xtcstack`, `hwstack`.
    bool symbolAttr(String* name, String* key)
    {
        if (_m == (IRModule*)0) return false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name)) return s.attr(key);
        }
        return false;
    }

    bool symbolFlag(String* name, String* which)
    {
        if (_m == (IRModule*)0) return false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (!s.name().equals(name)) continue;
            if (which.equals(String.withCString("irq"))) return s.irq();
            return s.vbi();
        }
        return false;
    }

    void emitBlock(IRFunc* fn, IRBlock* bb)
    {
        _out.appendFormat("%s:\n", blockLabel(fn, bb).cString());
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            emitInsn(fn, bb, (IRInsn*)bb.insns().get(i));
        if (bb.term() != (IRInsn*)0) emitInsn(fn, bb, bb.term());
    }

    void emitInsn(IRFunc* fn, IRBlock* bb, IRInsn* n)
    {
        String* op = n.op();
        if (dispatchCore(fn, bb, n, op)) return;
        if (dispatchMemory(fn, bb, n, op)) return;
        if (dispatchFloat(fn, bb, n, op)) return;
        if (dispatchRuntime(fn, bb, n, op)) return;
        unsupported(op);
    }

    // Dispatch is split four ways purely for the arm64 frame budget: one
    // chain of literal comparisons builds more temporaries than a single
    // frame can hold.
    bool dispatchCore(IRFunc* fn, IRBlock* bb, IRInsn* n, String* op)   // the shapes every function has: constants, arithmetic, control flow and calls
    {
        if (op.equals(String.withCString("Phi"))) return true;   // handled: edge copies
        if (op.equals(String.withCString("Const"))) { emitConst(n); return true; }
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")))
            { emitAddSub(n); return true; }
        if (op.equals(String.withCString("Asm")))    { emitAsm(n); return true; }
        if (op.equals(String.withCString("Branch")))     { emitBranch(bb, n); return true; }
        if (op.equals(String.withCString("CondBranch"))) { emitCondBranch(bb, n); return true; }
        if (op.equals(String.withCString("Return")))     { emitReturn(n); return true; }
        if (op.equals(String.withCString("Unreachable"))) { _out.appendCString("    BRK\n"); return true; }
        if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked"))
            || op.equals(String.withCString("CallCloaked"))) { emitCall(n); return true; }
        if (op.equals(String.withCString("ICmp")))    { emitICmp(n); return true; }
        if (op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor")))  { emitBitwise(n); return true; }
        if (op.equals(String.withCString("Not")))     { emitNot(n); return true; }
        if (op.equals(String.withCString("Neg")))     { emitNeg(n); return true; }
        if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("SDiv"))
            || op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SRem"))
            || op.equals(String.withCString("URem"))) { emitMulDiv(n); return true; }
        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr"))
            || op.equals(String.withCString("AShr")) || op.equals(String.withCString("Rol"))
            || op.equals(String.withCString("Ror")))  { emitShift(n); return true; }
        if (op.equals(String.withCString("ZExt")))    { emitZExt(n); return true; }
        if (op.equals(String.withCString("SExt")))    { emitSExt(n); return true; }
        if (op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast")))
            { emitTruncBitcast(n); return true; }
        return false;
    }

    bool dispatchMemory(IRFunc* fn, IRBlock* bb, IRInsn* n, String* op)   // memory, addressing and aggregates
    {
        if (op.equals(String.withCString("AddrOf"))) { emitAddrOf(n); return true; }
        if (op.equals(String.withCString("Select")))  { emitSelect(n); return true; }
        if (op.equals(String.withCString("MemCopy")))  { emitMemCopy(n); return true; }
        if (op.equals(String.withCString("MemSet")))   { emitMemSet(n); return true; }
        if (op.equals(String.withCString("AggBuild")))   { emitAggBuild(n); return true; }
        if (op.equals(String.withCString("AggExtract"))) { emitAggExtract(n); return true; }
        if (op.equals(String.withCString("ElementAddr"))) { emitElementAddr(n); return true; }
        if (op.equals(String.withCString("IntToPtr")))    { emitIntToPtr(n); return true; }
        if (op.equals(String.withCString("PtrToInt")))    { emitPtrToInt(n); return true; }
        if (op.equals(String.withCString("FieldAddr"))) { emitFieldAddr(n); return true; }
        if (op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")))
            { emitStore(n); return true; }
        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile")))
            { emitLoad(n); return true; }
        return false;
    }

    bool dispatchFloat(IRFunc* fn, IRBlock* bb, IRInsn* n, String* op)   // the float ops, all of which reach IEEE through MECH
    {
        if (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub"))
            || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv")))
            { emitFArith(n); return true; }
        if (op.equals(String.withCString("FNeg")))   { emitFNeg(n); return true; }
        if (op.equals(String.withCString("FCmp")))   { emitFCmp(n); return true; }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            { emitIntToFp(n); return true; }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")))
            { emitFpToInt(n); return true; }
        if (op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")))
            { emitFpCast(n); return true; }
        if (op.equals(String.withCString("FSqrt")))  { emitFSqrt(n); return true; }
        return false;
    }

    bool dispatchRuntime(IRFunc* fn, IRBlock* bb, IRInsn* n, String* op)   // dispatch, ARC, weak references and the banking ops
    {
        if (op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("CallIndirect")))
            { emitIndirectCall(n); return true; }
        if (op.equals(String.withCString("VTblLoad")))   { emitVTblLoad(n); return true; }
        if (op.equals(String.withCString("ClassDowncast"))
            || op.equals(String.withCString("ClassDowncastFailable"))) { emitPtrToInt(n); return true; }
        if (op.equals(String.withCString("BankSelectFor"))) { emitBankSelectFor(n); return true; }
        if (op.equals(String.withCString("BankSave")))     { emitBankSave(); return true; }
        if (op.equals(String.withCString("BankRestore")))  { emitBankRestore(); return true; }
        if (op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release"))
            || op.equals(String.withCString("Autorelease"))) { emitArc(n); return true; }
        if (op.equals(String.withCString("WeakRegister")))   { emitWeakRegister(n); return true; }
        if (op.equals(String.withCString("WeakUnregister"))) { emitWeakUnregister(n); return true; }
        if (op.equals(String.withCString("WeakLoad")))       { emitWeakLoad(n); return true; }
        return false;
    }


    // ── Operand bytes ────────────────────────────────────────────────────
    //
    // Everything here is a BYTE at a time, little-endian. There is one A
    // register, so an operand is loaded into it, used, and stored — per byte.
    bool loadOperandByte(IROperand* op, u32 bi)
    {
        if (op.kind() == (u8)OPK_USE) {
            IRValue* v = op.val();
            u32 w = v == (IRValue*)0 ? (u32)0 : byteWidth(v.ty());
            // A value NARROWER than the byte being asked for has no slot byte
            // there, and reading one would pull in a neighbouring value. The
            // proper extension is emitted instead: zero for unsigned, the sign
            // byte for signed — and carry-preserving, because an add or
            // subtract byte chain calls this BETWEEN bytes and would otherwise
            // lose the carry it is accumulating.
            if (w != (u32)0 && bi >= w) {
                if (isSignedTy(v.ty())) {
                    String* msb = operandFor(v, w - (u32)1);
                    _out.appendFormat("    PHP\n    LDA %s\n    ASL A\n    LDA #$00\n", msb.cString());
                    _out.appendCString("    ADC #$FF\n    EOR #$FF\n    PLP\n");
                } else {
                    _out.appendCString("    LDA #$00\n");
                }
                return true;
            }
            String* operand = operandFor(v, bi);
            if (operand == (String*)0) return false;
            _out.appendFormat("    LDA %s\n", operand.cString());
            return true;
        }
        if (op.kind() == (u8)OPK_IMMI) {
            _out.appendFormat("    LDA #$%s\n", hex2(byteOfImm(op, bi)).cString());
            return true;
        }
        if (op.kind() == (u8)OPK_IMMF) {
            Array* enc = encodeFloatHex(op.fpHex(), op.ty() == (String*)0 ? (u32)4 : byteWidth(op.ty()));
            u32 b = bi < enc.count() ? ((Number*)enc.get(bi)).asU32() : (u32)0;
            _out.appendFormat("    LDA #$%s\n", hex2(b).cString());
            return true;
        }
        return false;
    }

    // Any byte of an immediate, up to eight: the payload is 64 bits now, and
    // capping at four returned 0 for the top half of a wide literal rather
    // than its bytes.
    static u32 byteOfImm(IROperand* op, u32 bi)
    {
        if (bi >= (u32)8) return (u32)0;
        return (u32)(((u64)op.imm() >> ((u64)8 * (u64)bi)) & (u64)$FF);
    }

    void storeAToValue(IRValue* v, u32 bi)
    {
        String* operand = operandFor(v, bi);
        if (operand == (String*)0) return;
        _out.appendFormat("    STA %s\n", operand.cString());
    }

    // A float constant's bytes in THIS target's layout, little-endian. Under
    // the current model that layout IS IEEE — a 4-byte single or an 8-byte
    // double — so an f64 is the pattern as it stands and an f32 is it narrowed.
    Array* encodeFloatHex(String* hex, u32 width)
    {
        Array* out = new Array();
        if (width == (u32)8) {
            for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
                out.add((Object*)Number.withU32(hexByte(hex, ((u32)7 - i) * (u32)2)));
            return out;
        }
        u32 bits = f32BitsOfHex(hex);
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            out.add((Object*)Number.withU32((bits >> ((u32)8 * i)) & (u32)$FF));
        return out;
    }

    static u32 hexByte(String* hex, u32 at)
    {
        return hexNibble(hex, at) * (u32)16 + hexNibble(hex, at + (u32)1);
    }

    static u32 hexNibble(String* hex, u32 i)
    {
        if (i >= hex.byteLength()) return (u32)0;
        u8 c = hex.byteAt(i);
        if (c >= (u8)'0' && c <= (u8)'9') return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f') return (u32)(c - (u8)'a') + (u32)10;
        if (c >= (u8)'A' && c <= (u8)'F') return (u32)(c - (u8)'A') + (u32)10;
        return (u32)0;
    }

    // The IEEE single bits of a double spelled as 16 big-endian hex digits.
    // The big-endian hex spelling encodeFloatHex reads, from the little-endian
    // byte array the IR carries.
    static String* hexOfBytes(Array* bytes)
    {
        String* o = new String();
        u32 i = bytes.count() > (u32)8 ? (u32)8 : bytes.count();
        while (i > (u32)0) {
            i = i - (u32)1;
            u32 v = ((Number*)bytes.get(i)).asU32() & (u32)$FF;
            o.appendByte(hexDigit((v >> (u32)4) & (u32)$F));
            o.appendByte(hexDigit(v & (u32)$F));
        }
        for (u32 k = bytes.count(); k < (u32)8; k = k + (u32)1) o.appendCString("00");
        return o;
    }

    static u32 f32BitsOfHex(String* hex)
    {
        u32 hi = (u32)0;
        u32 lo = (u32)0;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1) {
            hi = (hi << (u32)8) | hexByte(hex, i * (u32)2);
            lo = (lo << (u32)8) | hexByte(hex, (i + (u32)4) * (u32)2);
        }
        u32 sign = (hi >> (u32)31) & (u32)1;
        u32 exp = (hi >> (u32)20) & (u32)$7FF;
        u32 mhi = hi & (u32)$F_FFFF;
        if (exp == (u32)0 && mhi == (u32)0 && lo == (u32)0) return sign << (u32)31;
        if (exp == (u32)$7FF) {
            u32 mq = (mhi != (u32)0 || lo != (u32)0) ? (u32)1 : (u32)0;
            return (sign << (u32)31) | (u32)$7F80_0000 | (mq << (u32)22);
        }
        i32 e = (i32)exp - (i32)1023 + (i32)127;
        if (e >= (i32)255) return (sign << (u32)31) | (u32)$7F80_0000;
        if (e <= (i32)0)   return sign << (u32)31;
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

    // ── Emitters ─────────────────────────────────────────────────────────
    void emitConst(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* op = (IROperand*)n.ops().get((u32)0);
        String* ty = n.res().ty();
        if (isFloatTy(ty)) {
            // The IR carries the abstract value as raw IEEE double bits; the
            // BACK END owns the byte layout, so it encodes here and splats.
            Array* enc = encodeFloatHex(op.kind() == (u8)OPK_IMMF
                                        ? op.fpHex() : String.withCString("0000000000000000"),
                                        byteWidth(ty));
            for (u32 b = (u32)0; b < enc.count(); b = b + (u32)1) {
                _out.appendFormat("    LDA #$%s\n", hex2(((Number*)enc.get(b)).asU32()).cString());
                storeAToValue(n.res(), b);
            }
            return;
        }
        u32 width = byteWidth(ty);
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte(op, b);
            storeAToValue(n.res(), b);
        }
    }

    // A pointer's ADDRESS bytes, then its bank byte. Every AddrOf result is a
    // flat-memory pointer, so the bank is zero — and it still has to be
    // WRITTEN, because the slot may hold a stale bank from a previous value
    // and every dereference reads byte 2 into the data-bank register.
    void emitAddrOf(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        // Consumed only by the absolute fast path — the pointer slot is never
        // read, so materialising it is pure dead code.
        if (isSuppressed(n.res())) return;
        IROperand* op = (IROperand*)n.ops().get((u32)0);
        bool fnBankWritten = false;
        if (op.kind() == (u8)OPK_SYM) {
            // `<sym` and `>sym` are the assembler's low- and high-byte
            // extraction operators, so the address stays a link-time constant.
            _out.appendFormat("    LDA #<_%s\n", op.name().cString());
            storeAToValue(n.res(), (u32)0);
            _out.appendFormat("    LDA #>_%s\n", op.name().cString());
            storeAToValue(n.res(), (u32)1);
            // A FUNCTION pointer carries the function's CODE bank in byte 2 —
            // the same link-time constant a vtable slot holds — so a later
            // indirect call can bank-switch to it. A data symbol is flat bank-0
            // main RAM and takes the zero written below.
            if (banking() && symbolIsFunction(op.name())
                && byteWidth(n.res().ty()) > (u32)2) {
                _out.appendFormat("    LDA #__dbank_%s\n", op.name().cString());
                storeAToValue(n.res(), (u32)2);
                fnBankWritten = true;
            }
        } else if (op.kind() == (u8)OPK_USE) {
            Object* fo = _frameOffsets.get((Hashable*)op.val());
            Object* sp = _spillLabel.get((Hashable*)op.val());
            if (fo != (Object*)0) {
                // In the software-stack frame: address = FP + header + offset,
                // the header being the caller FP saved at the frame base (and,
                // under the xtc-stack convention, the return address and the
                // registers after it).
                u32 disp = _softFrameHeader + ((Number*)fo).asU32();
                _out.appendCString("    CLC\n");
                _out.appendFormat("    LDA $8C\n    ADC #$%s\n", hex2(disp & (u32)$FF).cString());
                storeAToValue(n.res(), (u32)0);
                _out.appendFormat("    LDA $8D\n    ADC #$%s\n",
                                  hex2((disp >> (u32)8) & (u32)$FF).cString());
                storeAToValue(n.res(), (u32)1);
            } else if (sp != (Object*)0) {
                // Spilled to main RAM: its address is the 16-bit spill label.
                _out.appendFormat("    LDA #<%s\n", ((String*)sp).cString());
                storeAToValue(n.res(), (u32)0);
                _out.appendFormat("    LDA #>%s\n", ((String*)sp).cString());
                storeAToValue(n.res(), (u32)1);
            } else {
                i32 zp = slotOf(op.val());
                if (zp < (i32)0) { unsupported(String.withCString("AddrOf:home")); return; }
                // A pinned local in zero page IS its address, and a ZP address
                // is one byte, so the high byte is always zero.
                _out.appendFormat("    LDA #$%s\n", hex2((u32)zp).cString());
                storeAToValue(n.res(), (u32)0);
                _out.appendCString("    LDA #$00\n");
                storeAToValue(n.res(), (u32)1);
            }
        } else {
            unsupported(String.withCString("AddrOf:operand"));
            return;
        }
        u32 w = byteWidth(n.res().ty());
        for (u32 b = (u32)2; b < w; b = b + (u32)1) {
            if (b == (u32)2 && fnBankWritten) continue;       // code bank already there
            _out.appendCString("    LDA #$00\n");
            storeAToValue(n.res(), b);
        }
    }

    bool symbolIsFunction(String* name)
    {
        if (_m == (IRModule*)0) return false;
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name)) return s.kind() == (u8)SYM_FUNCTION;
        }
        return false;
    }

    // ── Indirect and vtable dispatch ─────────────────────────────────────
    //
    // The 6502 has no `JSR (ind)`. The idiom is to stage the target in the
    // module scratch pair $85/$86 and JSR a fixed trampoline that JMPs
    // through it; the callee's RTS lands after the JSR.
    //
    // The receiver is the dispatched method's `self`, so it is pushed AFTER
    // the explicit arguments, landing on TOP where the callee reads its first
    // parameter. Pushing it first put it BELOW the arguments and every
    // dispatched method that took arguments read garbage.
    void emitIndirectCall(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) return;
        emitCallerSave(n);
        bool isVtbl = n.op().equals(String.withCString("VTblDispatch"));
        u32 firstArg = isVtbl ? (u32)2 : (u32)1;
        IROperand* recvOrFn = (IROperand*)n.ops().get((u32)0);
        u32 pushed = (u32)0;
        u32 argCount = n.ops().count() >= firstArg + (u32)1
                     ? n.ops().count() - firstArg - (u32)1 : (u32)0;
        u32 i = argCount;
        while (i > (u32)0) {
            i = i - (u32)1;
            IROperand* a = (IROperand*)n.ops().get(firstArg + i);
            u32 argW = (u32)1;
            if (a.kind() == (u8)OPK_USE) argW = byteWidth(a.val().ty());
            else if (a.kind() == (u8)OPK_IMMI && a.ty() != (String*)0) argW = byteWidth(a.ty());
            u32 b = argW;
            while (b > (u32)0) { b = b - (u32)1; loadOperandByte(a, b); emitPHA(); pushed = pushed + (u32)1; }
        }
        if (isVtbl) {
            u32 recvW = recvOrFn.kind() == (u8)OPK_USE ? byteWidth(recvOrFn.val().ty())
                      : byteWidth(recvOrFn.ty());
            if (recvW == (u32)0) recvW = (u32)4;
            u32 b = recvW;
            while (b > (u32)0) { b = b - (u32)1; loadOperandByte(recvOrFn, b); emitPHA(); pushed = pushed + (u32)1; }
        }
        bool bankAware = banking();
        if (isVtbl) {
            IROperand* slotOp = (IROperand*)n.ops().get((u32)1);
            if (recvOrFn.kind() != (u8)OPK_USE) return;
            // The arguments are already pushed, so the indirect base has to
            // reflect spDelta — indirectBaseFor folds it in.
            String* recvInd = indirectBaseFor(recvOrFn.val());
            if (recvInd == (String*)0) return;
            u32 off = (u32)slotOp.imm() * (u32)3;
            if (off > (u32)253) { unsupported(String.withCString("VTblDispatch:slot")); return; }
            emitBankSelectAlways(recvOrFn.val());   // ungated — see 054
            _out.appendCString("    LDY #$00\n");
            _out.appendFormat("    LDA %s,Y\n    STA $85\n", recvInd.cString());
            _out.appendCString("    INY\n");
            _out.appendFormat("    LDA %s,Y\n    STA $86\n", recvInd.cString());
            // The slot at vtbl + slot*3 is [bank, addr-lo, addr-hi].
            _out.appendFormat("    LDY #$%s\n", hex2(off).cString());
            _out.appendCString("    LDA ($85),Y\n");
            if (bankAware) _out.appendCString("    STA _xc_bank\n");
            _out.appendCString("    INY\n    LDA ($85),Y\n");
            emitPHA();                                  // addr-lo
            _out.appendCString("    INY\n    LDA ($85),Y\n    STA $86\n");
            emitPLA();
            _out.appendCString("    STA $85\n");
        } else {
            // The function pointer is [addr-lo, addr-hi, code-bank] — the same
            // triple AddrOf @fn builds.
            if (recvOrFn.kind() != (u8)OPK_USE) return;
            String* lo = operandFor(recvOrFn.val(), (u32)0);
            String* hi = operandFor(recvOrFn.val(), (u32)1);
            if (lo == (String*)0 || hi == (String*)0) return;
            String* bk = operandFor(recvOrFn.val(), (u32)2);
            _out.appendFormat("    LDA %s\n    STA $85\n", lo.cString());
            _out.appendFormat("    LDA %s\n    STA $86\n", hi.cString());
            if (bankAware) {
                if (bk != (String*)0) _out.appendFormat("    LDA %s\n", bk.cString());
                else                  _out.appendCString("    LDA #$00\n");
                _out.appendCString("    STA _xc_bank\n");
            }
        }
        _out.appendFormat("    JSR %s\n", bankAware ? "__xt_indcall" : "__xt_indjmp");
        u32 remaining = pushed;
        while (remaining > (u32)0) {
            u32 chunk = remaining > (u32)127 ? (u32)127 : remaining;
            emitAddSP(chunk);
            remaining = remaining - chunk;
        }
        // A WIDE return (float / aggregate / any scalar past 4 bytes) rides the
        // $B0 MAILBOX, not A/X/Y/$89. This site knew only the register form, so
        // an i64 returned through a virtual or protocol call harvested four
        // bytes from the wrong place and kept a correct high word with a
        // garbage low one. Guard: tests/fixtures/int64_return_dispatch.xc.
        if (n.res() != (IRValue*)0) {
            u32 rW = byteWidth(n.res().ty());
            String* rt = n.res().ty();
            if (isFloatTy(rt) || isAggTy(rt) || rW > (u32)4) {
                for (u32 b = (u32)0; b < rW && b < (u32)16; b = b + (u32)1) {
                    _out.appendFormat("    LDA $%s\n", hex2((u32)$B0 + b).cString());
                    storeAToValue(n.res(), b);
                }
            } else {
            if (rW >= (u32)1) storeAToValue(n.res(), (u32)0);
            if (rW >= (u32)2) { _out.appendCString("    TXA\n"); storeAToValue(n.res(), (u32)1); }
            if (rW >= (u32)3) { _out.appendCString("    TYA\n"); storeAToValue(n.res(), (u32)2); }
            if (rW >= (u32)4) { _out.appendCString("    LDA $89\n"); storeAToValue(n.res(), (u32)3); }
            }
        }
        emitCallerRestore(n);
    }

    // The vtable read without the call — the code word of `&obj.method`. The
    // byte orders have to be TRANSPOSED: a vtable SLOT is [bank, addr-lo,
    // addr-hi], a function-pointer VALUE is [addr-lo, addr-hi, code-bank].
    //
    // A null receiver yields a null pointer rather than faulting, so
    // `&nullDelegate.m` is merely falsy. An empty slot is already all-zero in
    // the emitted vtable, so "optional method not implemented" falls out for
    // free.
    void emitVTblLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        IROperand* recv = (IROperand*)n.ops().get((u32)0);
        IROperand* slotOp = (IROperand*)n.ops().get((u32)1);
        if (recv.kind() != (u8)OPK_USE || slotOp.kind() != (u8)OPK_IMMI) return;
        u32 off = (u32)slotOp.imm() * (u32)3;
        if (off > (u32)253) { unsupported(String.withCString("VTblLoad:slot")); return; }
        String* recvInd = indirectBaseFor(recv.val());
        if (recvInd == (String*)0) return;
        u32 resW = byteWidth(n.res().ty());
        u32 lbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        _out.appendCString("    LDA #$00\n");
        for (u32 b = (u32)0; b < resW; b = b + (u32)1) storeAToValue(n.res(), b);
        // Test the two address bytes with LDA plus branches rather than
        // LDA/ORA: the receiver may live on the SP frame, and `+n,SP` is a
        // valid mode for LDA and STA but NOT for ORA.
        String* rLo = operandFor(recv.val(), (u32)0);
        String* rHi = operandFor(recv.val(), (u32)1);
        if (rLo == (String*)0 || rHi == (String*)0) return;
        _out.appendFormat("    LDA %s\n", rLo.cString());
        _out.appendFormat("    BNE .Lvtl_go_%lu\n", lbl);
        _out.appendFormat("    LDA %s\n", rHi.cString());
        _out.appendFormat("    BEQ .Lvtl_done_%lu\n", lbl);
        _out.appendFormat(".Lvtl_go_%lu:\n", lbl);
        emitBankSelectAlways(recv.val());           // ungated — see 054
        _out.appendCString("    LDY #$00\n");
        _out.appendFormat("    LDA %s,Y\n    STA $85\n", recvInd.cString());
        _out.appendCString("    INY\n");
        _out.appendFormat("    LDA %s,Y\n    STA $86\n", recvInd.cString());
        _out.appendFormat("    LDY #$%s\n", hex2(off).cString());
        _out.appendCString("    LDA ($85),Y\n");                 // bank
        if (resW > (u32)2) storeAToValue(n.res(), (u32)2);
        _out.appendCString("    INY\n    LDA ($85),Y\n");        // addr-lo
        storeAToValue(n.res(), (u32)0);
        _out.appendCString("    INY\n    LDA ($85),Y\n");        // addr-hi
        storeAToValue(n.res(), (u32)1);
        _out.appendFormat(".Lvtl_done_%lu:\n", lbl);
    }

    // ── Banking ops ──────────────────────────────────────────────────────
    //
    // Window 1 is the code window, 2 the data window; anything else has no
    // bank register on this target and is a no-op.
    void emitBankSelectFor(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) return;
        IROperand* win = (IROperand*)n.ops().get((u32)0);
        IROperand* sel = (IROperand*)n.ops().get((u32)1);
        i32 window = win.kind() == (u8)OPK_IMMI ? (i32)win.imm() : (i32)0;
        if (window == (i32)1) {
            loadOperandByte(sel, (u32)0);
            _out.appendCString("    STA __bank_code_reg\n");
        } else if (window == (i32)2) {
            loadOperandByte(sel, (u32)0);
            _out.appendCString("    STA __bank_data_reg\n");
        }
    }

    // Push the selectors so a callee that switches banks can be returned from.
    void emitBankSave(void)
    {
        _out.appendCString("    LDA __bank_code_reg\n");
        emitPHA();
        _out.appendCString("    LDA __bank_data_reg\n");
        emitPHA();
    }

    void emitBankRestore(void)
    {
        emitPLA();
        _out.appendCString("    STA __bank_data_reg\n");
        emitPLA();
        _out.appendCString("    STA __bank_code_reg\n");
    }

    // ── Select ───────────────────────────────────────────────────────────
    //
    // `cond ? a : b` without introducing a block. The copy is driven by the
    // RESULT width, so a three-byte pointer carries its bank byte across too.
    void emitSelect(IRInsn* n)
    {
        if (n.ops().count() < (u32)3 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        if (width == (u32)0) width = (u32)1;
        loadOperandByte((IROperand*)n.ops().get((u32)0), (u32)0);
        u32 lbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        _out.appendFormat("    BEQ .Lselfalse_%lu\n", lbl);
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)1), b);
            storeAToValue(n.res(), b);
        }
        _out.appendFormat("    JMP .Lselend_%lu\n", lbl);
        _out.appendFormat(".Lselfalse_%lu:\n", lbl);
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)2), b);
            storeAToValue(n.res(), b);
        }
        _out.appendFormat(".Lselend_%lu:\n", lbl);
    }

    // ── Bulk memory ──────────────────────────────────────────────────────
    void emitMemCopy(IRInsn* n)
    {
        if (n.ops().count() < (u32)4) return;
        IROperand* dst = (IROperand*)n.ops().get((u32)0);
        IROperand* src = (IROperand*)n.ops().get((u32)1);
        IROperand* sz  = (IROperand*)n.ops().get((u32)2);
        for (u32 b = (u32)0; b < (u32)2; b = b + (u32)1) {
            loadOperandByte(dst, b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$85 + b).cString());
        }
        for (u32 b = (u32)0; b < (u32)2; b = b + (u32)1) {
            loadOperandByte(src, b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$87 + b).cString());
        }
        loadOperandByte(sz, (u32)0);
        if (sz.kind() == (u8)OPK_IMMI && sz.ty() != (String*)0 && byteWidth(sz.ty()) >= (u32)2) {
            _out.appendCString("    TAY\n");
            loadOperandByte(sz, (u32)1);
            _out.appendCString("    TAX\n    TYA\n");
        } else {
            _out.appendCString("    LDX #$00\n");
        }
        _out.appendCString("    JSR __xtc_memcpy\n");
    }

    void emitMemSet(IRInsn* n)
    {
        if (n.ops().count() < (u32)4) return;
        IROperand* dst = (IROperand*)n.ops().get((u32)0);
        IROperand* vop = (IROperand*)n.ops().get((u32)1);
        IROperand* sz  = (IROperand*)n.ops().get((u32)2);
        for (u32 b = (u32)0; b < (u32)2; b = b + (u32)1) {
            loadOperandByte(dst, b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$85 + b).cString());
        }
        loadOperandByte(vop, (u32)0);
        _out.appendCString("    TAY\n");
        loadOperandByte(sz, (u32)0);
        if (sz.kind() == (u8)OPK_IMMI && sz.ty() != (String*)0 && byteWidth(sz.ty()) >= (u32)2) {
            emitPHA();
            loadOperandByte(sz, (u32)1);
            _out.appendCString("    TAX\n");
            emitPLA();
        } else {
            _out.appendCString("    LDX #$00\n");
        }
        _out.appendCString("    JSR __xtc_memset\n");
    }

    // ── Aggregates ───────────────────────────────────────────────────────
    //
    // The result aggregate's slot can ALIAS an operand's — most sharply for a
    // multi-return tuple whose byte-0 local lands on an incoming parameter, so
    // `return 11, p0` would store field 0 over p0 before field 1 read it. Read
    // EVERY field into the $B0 scratch first, then copy scratch to the result:
    // the same parallel-copy discipline the phi edges use.
    void emitAggBuild(IRInsn* n)
    {
        if (n.res() == (IRValue*)0) return;
        IRLayout* l = layoutOf(n.res().ty());
        if (l == (IRLayout*)0) return;
        u32 scratch = (u32)$B0;
        u32 so = (u32)0;
        u32 nf = l.fieldCount() < n.ops().count() ? l.fieldCount() : n.ops().count();
        for (u32 i = (u32)0; i < nf; i = i + (u32)1) {
            u32 fw = byteWidth(l.typeAt(i));
            IROperand* fo = (IROperand*)n.ops().get(i);
            if (fo.kind() != (u8)OPK_USE) { so = so + fw; continue; }
            for (u32 b = (u32)0; b < fw; b = b + (u32)1) {
                loadOperandByte(fo, b);
                _out.appendFormat("    STA $%s\n", hex2(scratch + so).cString());
                so = so + (u32)1;
            }
        }
        so = (u32)0;
        for (u32 i = (u32)0; i < nf; i = i + (u32)1) {
            u32 off = l.offsetAt(i);
            u32 fw = byteWidth(l.typeAt(i));
            if (((IROperand*)n.ops().get(i)).kind() != (u8)OPK_USE) { so = so + fw; continue; }
            for (u32 b = (u32)0; b < fw; b = b + (u32)1) {
                _out.appendFormat("    LDA $%s\n", hex2(scratch + so).cString());
                so = so + (u32)1;
                storeAToValue(n.res(), off + b);
            }
        }
    }

    void emitAggExtract(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        IROperand* aggOp = (IROperand*)n.ops().get((u32)0);
        IROperand* idxOp = (IROperand*)n.ops().get((u32)1);
        if (aggOp.kind() != (u8)OPK_USE) return;
        IRLayout* l = layoutOf(aggOp.val().ty());
        if (l == (IRLayout*)0) return;
        u32 fi = (u32)idxOp.imm();
        if (fi >= l.fieldCount()) return;
        u32 off = l.offsetAt(fi);
        u32 fw = byteWidth(l.typeAt(fi));
        for (u32 b = (u32)0; b < fw; b = b + (u32)1) {
            String* src = operandFor(aggOp.val(), off + b);
            if (src == (String*)0) return;
            _out.appendFormat("    LDA %s\n", src.cString());
            storeAToValue(n.res(), b);
        }
    }

    // ── ARC and weak references ──────────────────────────────────────────
    //
    // The helpers take the pointer in A (lo), X (hi) and Y (bank). The low
    // byte parks in $93 — the bump allocator's scratch, free because the heap
    // is the free-list one — rather than on the stack: a PHA would move SP and
    // shift every SP-relative operand read after it by a byte.
    void emitArc(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) return;
        IROperand* ptr = (IROperand*)n.ops().get((u32)0);
        loadOperandByte(ptr, (u32)0);
        _out.appendCString("    STA $93\n");
        loadOperandByte(ptr, (u32)1);
        _out.appendCString("    TAX\n");
        loadOperandByte(ptr, (u32)2);
        _out.appendCString("    TAY\n");
        _out.appendCString("    LDA $93\n");
        // Autorelease degrades to a release.
        _out.appendFormat("    JSR %s\n",
            n.op().equals(String.withCString("Retain")) ? "__xtc_retain" : "__xtc_release");
    }

    // The object's BANK is part of the side-table key alongside its address,
    // so all three bytes are staged, not just the main-RAM pair.
    void emitWeakRegister(IRInsn* n)
    {
        if (n.ops().count() < (u32)3) return;
        for (u32 b = (u32)0; b < (u32)3; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$84 + b).cString());
        }
        for (u32 b = (u32)0; b < (u32)3; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)1), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$87 + b).cString());
        }
        _out.appendCString("    JSR __xtc_weak_register\n");
    }

    // The slot's bank matters as well as its address: unregister walks the
    // intrusive links sitting in front of the slot and has to map its bank to
    // reach them.
    void emitWeakUnregister(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) return;
        for (u32 b = (u32)0; b < (u32)3; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$84 + b).cString());
        }
        _out.appendCString("    JSR __xtc_weak_unregister\n");
    }

    void emitWeakLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        for (u32 b = (u32)0; b < (u32)2; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$84 + b).cString());
        }
        _out.appendCString("    JSR __xtc_weak_load\n");
        u32 w = byteWidth(n.res().ty());
        storeAToValue(n.res(), (u32)0);
        _out.appendCString("    TXA\n");
        if (w >= (u32)2) storeAToValue(n.res(), (u32)1);
        if (w >= (u32)3) { _out.appendCString("    TYA\n"); storeAToValue(n.res(), (u32)2); }
        if (w >= (u32)4) { _out.appendCString("    LDA $89\n"); storeAToValue(n.res(), (u32)3); }
    }

    // ── Float ────────────────────────────────────────────────────────────
    //
    // Every target's `float` is 4-byte IEEE single now; xt6502 reaches IEEE
    // through the MECH math coprocessor, so the bespoke 5-byte softfloat is
    // gone and each of these is a MECH op word over the native little-endian
    // IEEE bits.
    void emitFArith(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        u32 w = byteWidth(n.res().ty());
        u32 mcType = w == (u32)8 ? (u32)1 : (u32)0;         // F64 : F32
        String* op = n.op();
        u32 mcOp = op.equals(String.withCString("FAdd")) ? (u32)$01
                 : op.equals(String.withCString("FSub")) ? (u32)$02
                 : op.equals(String.withCString("FMul")) ? (u32)$03 : (u32)$04;
        emitMechBinop(n, w, mcType, mcOp, w, false, w);
    }

    // A negation is one EOR of the IEEE sign bit — bit 7 of the top byte — so
    // it never needs a MECH round trip.
    void emitFNeg(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        u32 w = byteWidth(a.kind() == (u8)OPK_USE ? a.val().ty() : n.res().ty());
        for (u32 b = (u32)0; b < w; b = b + (u32)1) {
            loadOperandByte(a, b);
            if (b == w - (u32)1) _out.appendCString("    EOR #$80\n");
            storeAToValue(n.res(), b);
        }
    }

    // MECH CMP writes an i32 -1/0/+1 into S2; its low byte is $FF/$00/$01, the
    // same convention the old fpCmp returned in A, so the predicate mapping is
    // unchanged. Read it while the page is still mapped and stash it across the
    // unmap, which clobbers A.
    void emitFCmp(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        u32 w = byteWidth(a.val().ty());
        u32 mcType = w == (u32)8 ? (u32)1 : (u32)0;
        mechMap();
        mechStore(a, w, (u32)0, w, false);
        mechStore((IROperand*)n.ops().get((u32)1), w, (u32)1, w, false);
        mechOpWord((u32)0, ((mcType & (u32)3) << (u32)6) | (u32)$0A, (u32)0, (u32)1, (u32)2);
        mechRun((u32)1);
        _out.appendCString("    LDA $4050\n");     // S2 low byte
        _out.appendCString("    STA $B0\n");       // stash across the unmap
        mechUnmap();
        _out.appendCString("    LDA $B0\n");
        String* p = n.pred();
        u32 cmpK = (u32)$00;
        bool wantEq = true;
        if (p.equals(String.withCString("OEQ")))      { cmpK = (u32)$00; wantEq = true; }
        else if (p.equals(String.withCString("ONE"))) { cmpK = (u32)$00; wantEq = false; }
        else if (p.equals(String.withCString("OLT"))) { cmpK = (u32)$FF; wantEq = true; }
        else if (p.equals(String.withCString("OGT"))) { cmpK = (u32)$01; wantEq = true; }
        else if (p.equals(String.withCString("OLE"))) { cmpK = (u32)$01; wantEq = false; }
        else if (p.equals(String.withCString("OGE"))) { cmpK = (u32)$FF; wantEq = false; }
        u32 l = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        _out.appendFormat("    CMP #$%s\n", hex2(cmpK).cString());
        _out.appendFormat("    %s .Lfcmp%lu_t\n", wantEq ? "BEQ" : "BNE", l);
        _out.appendCString("    LDA #0\n");
        _out.appendFormat("    JMP .Lfcmp%lu_d\n", l);
        _out.appendFormat(".Lfcmp%lu_t:\n    LDA #1\n.Lfcmp%lu_d:\n", l, l);
        storeAToValue(n.res(), (u32)0);
    }

    // MECH CVT, integer source. MECH's integer types are SIGNED, so a u32 has
    // to widen to a non-negative i64; anything narrower sign- or zero-extends
    // to i32.
    void emitIntToFp(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        u32 sw = byteWidth(a.val().ty());
        u32 dw = byteWidth(n.res().ty());
        bool sgn = n.op().equals(String.withCString("SIToFp"));
        u32 srcType = (u32)2;
        u32 srcBytes = (u32)4;
        bool sx = sgn;
        if (!sgn && sw == (u32)4) { srcType = (u32)3; srcBytes = (u32)8; sx = false; }
        emitMechUnary(n, sw, srcType, srcBytes, sx, dw == (u32)8 ? (u32)1 : (u32)0,
                      (u32)$20, dw);
    }

    // MECH CVT, float source. The low `iw` bytes are the truncated integer's
    // bit pattern — right for u32/u16/u8 too, since the low 32 bits of the
    // wrapped i32 equal the unsigned value.
    void emitFpToInt(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        u32 fw = byteWidth(a.val().ty());
        u32 iw = byteWidth(n.res().ty());
        emitMechUnary(n, fw, fw == (u32)8 ? (u32)1 : (u32)0, fw, false, (u32)2, (u32)$20, iw);
    }

    void emitFpCast(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        u32 sw = byteWidth(a.val().ty());
        u32 dw = byteWidth(n.res().ty());
        emitMechUnary(n, sw, sw == (u32)8 ? (u32)1 : (u32)0, sw, false,
                      dw == (u32)8 ? (u32)1 : (u32)0, (u32)$20, dw);
    }

    void emitFSqrt(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 w = byteWidth(n.res().ty());
        u32 t = w == (u32)8 ? (u32)1 : (u32)0;
        emitMechUnary(n, w, t, w, false, t, (u32)$07, w);
    }

    // ── Call ─────────────────────────────────────────────────────────────
    //
    // Arguments are pushed right to left, low byte last within each argument,
    // onto the hidden hardware stack. Values live across the call that hold a
    // ZP slot are saved BELOW the arguments first, because the callee reuses
    // the very same ZP pool.
    Map* _bankMap;              // callee name -> its code bank (0 = unbanked)
    u32  _currentBank;

    void emitCall(IRInsn* n)
    {
        if (n.ops().count() < (u32)2) return;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM) return;
        String* name = callee.name();
        if (name == (String*)0) return;

        emitCallerSave(n);

        u32 argCount = n.ops().count() - (u32)2;
        u32 pushed = (u32)0;
        u32 i = argCount;
        while (i > (u32)0) {
            i = i - (u32)1;
            IROperand* a = (IROperand*)n.ops().get(i + (u32)1);
            u32 argW = (u32)1;
            if (a.kind() == (u8)OPK_USE) argW = byteWidth(a.val().ty());
            else if (a.kind() == (u8)OPK_IMMI && a.ty() != (String*)0) argW = byteWidth(a.ty());
            // High byte first. PHA moves SP, so spDelta ACCUMULATES across the
            // bytes — the offset formula `base + bi + spDelta` keeps each load
            // pointed at the right absolute frame slot as the stack shrinks.
            u32 b = argW;
            while (b > (u32)0) {
                b = b - (u32)1;
                loadOperandByte(a, b);
                emitPHA();
                pushed = pushed + (u32)1;
            }
        }

        // Cross-bank dispatch. When the callee lives in a different code bank
        // it goes through the unbanked `_xcall` trampoline, which saves
        // __bank_code_reg, selects the callee's bank, calls, and restores —
        // so the switch never swaps the code page out from under the fetcher,
        // which would derail a banked caller. A callee that is unbanked or in
        // this bank stays a plain JSR. The arguments are already on the
        // hardware stack and survive the switch untouched.
        u32 calleeBank = bankForCallee(name);
        if (banking() && calleeBank != (u32)0 && calleeBank != _currentBank) {
            _out.appendFormat("    LDA #<_%s\n", name.cString());
            _out.appendCString("    STA _xcall_vec\n");
            _out.appendFormat("    LDA #>_%s\n", name.cString());
            _out.appendCString("    STA _xcall_vec+1\n");
            _out.appendFormat("    LDA #$%s\n", hex2(calleeBank).cString());
            _out.appendCString("    STA _xc_bank\n");
            _out.appendCString("    JSR _xcall\n");
        } else {
            _out.appendFormat("    JSR _%s\n", name.cString());
        }

        // Harvest the return value BEFORE popping the arguments: ADD SP
        // expands to TSX/TXA/CLC/ADC/TAX/TXS and so clobbers A and X, which
        // are return bytes 0 and 1.
        if (n.res() != (IRValue*)0) {
            u32 rW = byteWidth(n.res().ty());
            // A 64-bit scalar rides the mailbox too: A/X/Y plus $89 carry four
            // bytes and no more, and $B0.. already moves eight for a double.
            bool viaMailbox = isFloatTy(n.res().ty()) || isAggTy(n.res().ty())
                           || byteWidth(n.res().ty()) > (u32)4;
            if (viaMailbox) {
                if (rW > (u32)16) { unsupported(String.withCString("Call:aggwidth")); return; }
                harvestMailbox(n.res(), rW);
            } else if (rW > (u32)4) {
                unsupported(String.withCString("Call:retwidth")); return;
            } else {
                if (rW >= (u32)1) storeAToValue(n.res(), (u32)0);
                if (rW >= (u32)2) { _out.appendCString("    TXA\n"); storeAToValue(n.res(), (u32)1); }
                if (rW >= (u32)3) { _out.appendCString("    TYA\n"); storeAToValue(n.res(), (u32)2); }
                // Only pointers are 3 bytes, so a 4-byte return is a u32 and
                // its top byte still rides $89.
                if (rW >= (u32)4) { _out.appendCString("    LDA $89\n"); storeAToValue(n.res(), (u32)3); }
            }
        }
        u32 remaining = pushed;
        while (remaining > (u32)0) {
            u32 chunk = remaining > (u32)127 ? (u32)127 : remaining;
            emitAddSP(chunk);
            remaining = remaining - chunk;
        }
        emitCallerRestore(n);
    }

    u32 bankForCallee(String* name)
    {
        if (_bankMap == (Map*)0) return (u32)0;
        Object* b = _bankMap.get((Hashable*)name);
        return b == (Object*)0 ? (u32)0 : ((Number*)b).asU32();
    }

    // Each preserved ZP byte is read non-destructively and pushed, ascending;
    // the saved bytes end up BELOW the arguments, so the callee's SP-relative
    // parameter offsets are unchanged.
    void emitCallerSave(IRInsn* n)
    {
        Array* bytes = saveBytesForCall(n);
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1) {
            _out.appendFormat("    LDA $%s\n", hex2(((Number*)bytes.get(i)).asU32()).cString());
            emitPHA();
        }
    }

    // The matching pops, descending. The call's own result is excluded from the
    // save set, so the slot just harvested into is never overwritten here.
    void emitCallerRestore(IRInsn* n)
    {
        Array* bytes = saveBytesForCall(n);
        u32 i = bytes.count();
        while (i > (u32)0) {
            i = i - (u32)1;
            emitPLA();
            _out.appendFormat("    STA $%s\n", hex2(((Number*)bytes.get(i)).asU32()).cString());
        }
    }

    Map* _callSaveSets;

    Array* saveBytesForCall(IRInsn* n)
    {
        if (_callSaveSets == (Map*)0) computeCallSaveSets(_fn);
        Object* a = _callSaveSets.get((Hashable*)n);
        return a == (Object*)0 ? new Array() : (Array*)a;
    }

    // What must survive a call = the values live immediately AFTER it, cut down
    // to the ones holding a ZP slot, minus the call's own result. Phis are
    // treated conservatively as block-level uses, which can only over-
    // approximate a live range — a few extra slots saved, never fewer, so it
    // cannot reintroduce a clobber.
    void computeCallSaveSets(IRFunc* fn)
    {
        _callSaveSets = new Map();
        if (fn.blocks().count() == (u32)0) return;
        Array* liveIn = new Array();
        Array* liveOut = new Array();
        solveLiveness(fn, liveIn, liveOut);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* live = copyVals((Array*)liveOut.get(b));
            Array* rev = reversedInsns(bb);
            for (u32 i = (u32)0; i < rev.count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)rev.get(i);
                if (isCallOp(n.op())) {
                    Array* bytes = zpBytesForLive(live, n.res());
                    if (bytes.count() > (u32)0) _callSaveSets.set((Hashable*)n, (Object*)bytes);
                }
                if (n.res() != (IRValue*)0) removeVal(live, n.res());
                if (n.memRes() != (IRValue*)0) removeVal(live, n.memRes());
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0) addVal(live, o.val());
                }
            }
        }
    }

    // The live values' ZP bytes, de-duplicated and ascending.
    Array* zpBytesForLive(Array* live, IRValue* except)
    {
        Array* marks = new Array();
        for (u32 i = (u32)0; i < (u32)256; i = i + (u32)1) marks.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)0; i < live.count(); i = i + (u32)1) {
            IRValue* v = (IRValue*)live.get(i);
            if (v == except) continue;
            i32 base = slotOf(v);
            if (base < (i32)0) continue;
            u32 w = byteWidth(v.ty());
            for (u32 b = (u32)0; b < w; b = b + (u32)1) {
                u32 a = (u32)base + b;
                if (a < (u32)256) marks.set(a, (Object*)Number.withU32((u32)1));
            }
        }
        Array* out = new Array();
        for (u32 i = (u32)0; i < (u32)256; i = i + (u32)1)
            if (((Number*)marks.get(i)).asU32() != (u32)0) out.add((Object*)Number.withU32(i));
        return out;
    }

    // ── Bitwise / negation ───────────────────────────────────────────────
    void emitBitwise(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        String* mn = n.op().equals(String.withCString("And")) ? String.withCString("AND")
                   : n.op().equals(String.withCString("Or"))  ? String.withCString("ORA")
                                                              : String.withCString("EOR");
        IROperand* r = (IROperand*)n.ops().get((u32)1);
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            if (r.kind() == (u8)OPK_USE) {
                if (onSPFrame(r.val())) {
                    // AND/ORA/EOR have no d,SP form. Stage the RHS byte through
                    // $BF with LDX/STX, which leaves A — the LHS — alone.
                    _out.appendFormat("    LDX %s\n", operandFor(r.val(), b).cString());
                    _out.appendCString("    STX $BF\n");
                    _out.appendFormat("    %s $BF\n", mn.cString());
                } else {
                    _out.appendFormat("    %s $%s\n", mn.cString(),
                                      hex2((u32)slotOf(r.val()) + b).cString());
                }
            } else if (r.kind() == (u8)OPK_IMMI) {
                _out.appendFormat("    %s #$%s\n", mn.cString(),
                    hex2(byteOfImm(r, b)).cString());
            }
            storeAToValue(n.res(), b);
        }
    }

    void emitNot(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendCString("    EOR #$FF\n");
            storeAToValue(n.res(), b);
        }
    }

    // Two's complement, ~x + 1, carried across the bytes.
    void emitNeg(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        _out.appendCString("    CLC\n");
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendCString("    EOR #$FF\n");
            _out.appendCString(b == (u32)0 ? "    ADC #$01\n" : "    ADC #$00\n");
            storeAToValue(n.res(), b);
        }
    }

    // ── Mul / Div / Rem ──────────────────────────────────────────────────
    //
    // The 6502 has neither multiply nor divide. Runtime routines under
    // support/xt6502/asm/{u,i}{8,16,32}/ take their operands in the $B0-$BF ZP
    // block — a and b consecutively, result back at $B0 — and the call site is
    // a plain JSR to `_<widthtag><Op>`.
    void emitMulDiv(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        bool isSigned = isSignedTy(n.res().ty());
        String* op = n.op();
        // 32-bit goes to the MECH math coprocessor instead: a software 32-bit
        // divide is ~2-3k cycles, far past MECH's flat ~23us doorbell floor at
        // every turbo tier, so the offload always wins. MECH integer ops are
        // signed, so unsigned Div/Rem widen to i64 (MC_T_I64=3).
        if (width == (u32)4) {
            u32 mcType = (u32)2;
            u32 mcOp = (u32)$03;
            bool zx = false;
            if (op.equals(String.withCString("Mul")))       { mcType = (u32)2; mcOp = (u32)$03; }
            else if (op.equals(String.withCString("SDiv"))) { mcType = (u32)2; mcOp = (u32)$04; }
            else if (op.equals(String.withCString("UDiv"))) { mcType = (u32)3; mcOp = (u32)$04; zx = true; }
            else if (op.equals(String.withCString("SRem"))) { mcType = (u32)2; mcOp = (u32)$0B; }
            else if (op.equals(String.withCString("URem"))) { mcType = (u32)3; mcOp = (u32)$0B; zx = true; }
            emitMechBinop(n, (u32)4, mcType, mcOp, zx ? (u32)8 : (u32)4, false, (u32)4);
            return;
        }
        String* opName = op.equals(String.withCString("Mul")) ? String.withCString("Mul")
            : (op.equals(String.withCString("SDiv")) || op.equals(String.withCString("UDiv")))
                ? String.withCString("Div") : String.withCString("Mod");
        String* tag = widthTag(width, isSigned);
        if (tag == (String*)0) { unsupported(String.withCString("MulDiv:width")); return; }
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$B0 + b).cString());
        }
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)1), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$B0 + width + b).cString());
        }
        _out.appendFormat("    JSR _%s%s\n", tag.cString(), opName.cString());
        harvestMailbox(n.res(), width);
    }

    static String* widthTag(u32 width, bool isSigned)
    {
        if (width == (u32)1) return String.withCString(isSigned ? "i8"  : "u8");
        if (width == (u32)2) return String.withCString(isSigned ? "i16" : "u16");
        if (width == (u32)4) return String.withCString(isSigned ? "i32" : "u32");
        if (width == (u32)8) return String.withCString(isSigned ? "i64" : "u64");
        return (String*)0;
    }

    void harvestMailbox(IRValue* res, u32 width)
    {
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            _out.appendFormat("    LDA $%s\n", hex2((u32)$B0 + b).cString());
            storeAToValue(res, b);
        }
    }

    // Shifts use the same mailbox convention: value in $B0.., count in the byte
    // just past it. The count is always U8.
    void emitShift(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        u32 width = byteWidth(n.res().ty());
        String* tag = width == (u32)1 ? String.withCString("u8")
                    : width == (u32)2 ? String.withCString("u16")
                    : width == (u32)4 ? String.withCString("u32")
                    : width == (u32)8 ? String.withCString("u64") : (String*)0;
        if (tag == (String*)0) { unsupported(String.withCString("Shift:width")); return; }
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            _out.appendFormat("    STA $%s\n", hex2((u32)$B0 + b).cString());
        }
        loadOperandByte((IROperand*)n.ops().get((u32)1), (u32)0);
        _out.appendFormat("    STA $%s\n", hex2((u32)$B0 + width).cString());
        _out.appendFormat("    JSR _%s%s\n", tag.cString(), n.op().cString());
        harvestMailbox(n.res(), width);
    }

    // ── ElementAddr ──────────────────────────────────────────────────────
    //
    // The stride is the BACKEND width of the pointee, not the IR type's
    // intrinsic one: the latter is window-unaware and reports 0 for a pointer
    // pointee, which once strided a `pointer@` array at 1 byte instead of 2 —
    // every slot overlapped, so only the last write survived and get(0..n-2)
    // read garbage while get(last) read right.
    void emitElementAddr(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        IROperand* baseOp = (IROperand*)n.ops().get((u32)0);
        IROperand* idxOp = (IROperand*)n.ops().get((u32)1);
        if (baseOp.kind() != (u8)OPK_USE) return;
        String* baseLo = operandFor(baseOp.val(), (u32)0);
        String* baseHi = operandFor(baseOp.val(), (u32)1);
        if (baseLo == (String*)0 || baseHi == (String*)0) return;
        u32 elemSize = (u32)1;
        String* pte = pointeeOf(baseOp.val().ty());
        if (pte != (String*)0) {
            u32 w = byteWidth(pte);
            if (w > (u32)0) elemSize = w;
        }
        if (elemSize > (u32)$FFFF)
            { unsupported(String.withCString("ElementAddr:stride")); return; }
        u32 iw = idxOp.kind() == (u8)OPK_USE ? byteWidth(idxOp.val().ty()) : (u32)1;
        bool banked = byteWidth(baseOp.val().ty()) > (u32)2;
        if (elemSize == (u32)1) {
            _out.appendCString("    CLC\n");
            loadOperandByte(idxOp, (u32)0);
            _out.appendFormat("    ADC %s\n", baseLo.cString());
            storeAToValue(n.res(), (u32)0);
            if (iw >= (u32)2) loadOperandByte(idxOp, (u32)1);
            else              _out.appendCString("    LDA #$00\n");
            _out.appendFormat("    ADC %s\n", baseHi.cString());
            storeAToValue(n.res(), (u32)1);
            // The bank byte comes through unchanged — an element of a banked
            // object is in the object's bank.
            if (banked) { loadOperandByte(baseOp, (u32)2); storeAToValue(n.res(), (u32)2); }
            return;
        }
        // base + idx * elemSize. The zero-extended index and the constant
        // stride go into the $B0.. mailbox and through the same _u16Mul the `*`
        // operator uses. Indices are unsigned, so a 16-bit product is right, and
        // $B0-$B3 are transient — the base lives in the frame or the ZP pool,
        // never the mailbox, so it survives the call.
        loadOperandByte(idxOp, (u32)0);
        _out.appendCString("    STA $B0\n");
        if (iw >= (u32)2) loadOperandByte(idxOp, (u32)1);
        else              _out.appendCString("    LDA #$00\n");
        _out.appendCString("    STA $B1\n");
        _out.appendFormat("    LDA #$%s\n    STA $B2\n", hex2(elemSize & (u32)$FF).cString());
        _out.appendFormat("    LDA #$%s\n    STA $B3\n",
                          hex2((elemSize >> (u32)8) & (u32)$FF).cString());
        _out.appendCString("    JSR _u16Mul\n");
        _out.appendCString("    CLC\n");
        _out.appendCString("    LDA $B0\n");
        _out.appendFormat("    ADC %s\n", baseLo.cString());
        storeAToValue(n.res(), (u32)0);
        _out.appendCString("    LDA $B1\n");
        _out.appendFormat("    ADC %s\n", baseHi.cString());
        storeAToValue(n.res(), (u32)1);
        if (banked) { loadOperandByte(baseOp, (u32)2); storeAToValue(n.res(), (u32)2); }
    }

    // IntToPtr widens; the source width has to be known or loadOperandByte
    // reads whatever adjacent slot follows, which is another live value.
    void emitIntToPtr(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 dstW = byteWidth(n.res().ty());
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        u32 srcW = src.kind() == (u8)OPK_USE ? byteWidth(src.val().ty()) : dstW;
        for (u32 b = (u32)0; b < dstW; b = b + (u32)1) {
            if (b < srcW) loadOperandByte(src, b);
            else          _out.appendCString("    LDA #$00\n");
            storeAToValue(n.res(), b);
        }
    }

    // PtrToInt narrows — copy what fits and drop the high bytes.
    void emitPtrToInt(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 w = byteWidth(n.res().ty());
        for (u32 b = (u32)0; b < w; b = b + (u32)1) {
            loadOperandByte((IROperand*)n.ops().get((u32)0), b);
            storeAToValue(n.res(), b);
        }
    }

    // ── MECH math coprocessor ────────────────────────────────────────────
    //
    // An 8 KB mailbox banked in at $D5C6: operand slots from $4040 (8 bytes
    // each), an op-word array from $4840, the op count at $4000, and the
    // doorbell/done bit at $D5C7.
    void mechMap(void)   { _out.appendCString("    LDA #$01\n    STA $D5C6\n"); }
    void mechUnmap(void) { _out.appendCString("    LDA #$00\n    STA $D5C6\n"); }

    void emitMechBinop(IRInsn* n, u32 opW, u32 mcType, u32 mcOp,
                       u32 slotBytes, bool sx, u32 rBytes)
    {
        mechMap();
        mechStore((IROperand*)n.ops().get((u32)0), opW, (u32)0, slotBytes, sx);
        mechStore((IROperand*)n.ops().get((u32)1), opW, (u32)1, slotBytes, sx);
        mechOpWord((u32)0, ((mcType & (u32)3) << (u32)6) | (mcOp & (u32)$3F),
                   (u32)0, (u32)1, (u32)2);
        mechRun((u32)1);
        mechResult(n, (u32)2, rBytes);
        mechUnmap();
    }

    // For CVT (0x20) byte 2 carries the SOURCE element type; every other unary
    // op ignores it.
    void emitMechUnary(IRInsn* n, u32 srcW, u32 srcType, u32 srcBytes, bool sx,
                       u32 dstType, u32 mcOp, u32 rBytes)
    {
        mechMap();
        mechStore((IROperand*)n.ops().get((u32)0), srcW, (u32)0, srcBytes, sx);
        u32 s2 = mcOp == (u32)$20 ? srcType & (u32)3 : (u32)0;
        mechOpWord((u32)0, ((dstType & (u32)3) << (u32)6) | (mcOp & (u32)$3F),
                   (u32)0, s2, (u32)2);
        mechRun((u32)1);
        mechResult(n, (u32)2, rBytes);
        mechUnmap();
    }

    void mechStore(IROperand* op, u32 opW, u32 slot, u32 slotBytes, bool sx)
    {
        u32 base = (u32)$4040 + slot * (u32)8;
        for (u32 b = (u32)0; b < opW; b = b + (u32)1) {
            loadOperandByte(op, b);
            _out.appendFormat("    STA $%s\n", hex4(base + b).cString());
        }
        if (slotBytes <= opW) return;
        if (sx) {
            u32 lbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
            // LDX #$00 comes FIRST — it sets N/Z, so the operand load has to
            // follow it for the BPL to test the operand's sign, not the
            // immediate's.
            _out.appendCString("    LDX #$00\n");
            loadOperandByte(op, opW - (u32)1);
            _out.appendFormat("    BPL .Lsx%lu\n    LDX #$FF\n.Lsx%lu:\n    TXA\n", lbl, lbl);
        } else {
            _out.appendCString("    LDA #$00\n");
        }
        for (u32 b = opW; b < slotBytes; b = b + (u32)1)
            _out.appendFormat("    STA $%s\n", hex4(base + b).cString());
    }

    void mechOpWord(u32 idx, u32 b0, u32 s1, u32 s2, u32 dst)
    {
        u32 base = (u32)$4840 + idx * (u32)4;
        _out.appendFormat("    LDA #$%s\n    STA $%s\n",
                          hex2(b0 & (u32)$FF).cString(), hex4(base).cString());
        _out.appendFormat("    LDA #$%s\n    STA $%s\n",
                          hex2(s1 & (u32)$FF).cString(), hex4(base + (u32)1).cString());
        _out.appendFormat("    LDA #$%s\n    STA $%s\n",
                          hex2(s2 & (u32)$FF).cString(), hex4(base + (u32)2).cString());
        _out.appendFormat("    LDA #$%s\n    STA $%s\n",
                          hex2(dst & (u32)$FF).cString(), hex4(base + (u32)3).cString());
    }

    // op_count = n, ring the doorbell, spin on done.
    void mechRun(u32 n)
    {
        u32 lbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        _out.appendFormat("    LDA #$%s\n    STA $4000\n", hex2(n & (u32)$FF).cString());
        _out.appendFormat("    LDA #$%s\n    STA $4001\n",
                          hex2((n >> (u32)8) & (u32)$FF).cString());
        _out.appendCString("    STA $D5C7\n");
        _out.appendFormat(".Lmech%lu:\n    LDA $D5C7\n    AND #$01\n    BEQ .Lmech%lu\n",
                          lbl, lbl);
    }

    void mechResult(IRInsn* n, u32 slot, u32 bytes)
    {
        u32 base = (u32)$4040 + slot * (u32)8;
        for (u32 b = (u32)0; b < bytes; b = b + (u32)1) {
            _out.appendFormat("    LDA $%s\n", hex4(base + b).cString());
            storeAToValue(n.res(), b);
        }
    }

    // ── Known compile-time addresses ─────────────────────────────────────
    //
    // A Ptr value whose address is a link-time constant — `AddrOf @sym`, or a
    // Bitcast of one — can be loaded and stored ABSOLUTELY (`LDA _sym+2`)
    // instead of building a three-byte pointer, writing the data-bank register
    // and going indirect. AddrOf results are always flat bank-0 main RAM, so
    // the direct form is exactly equivalent.
    //
    // Element and field chains deliberately do NOT fold into an absolute
    // symbol: aggregate-offset addressing off a global goes back on the generic
    // indirect path, which is the choice the earlier roll-out settled on.
    Map* _absSym;               // value -> its absolute symbol label
    Array* _suppressed;         // AddrOf results whose materialisation is dead

    void computeKnownAddrs(IRFunc* fn)
    {
        _absSym = new Map();
        _suppressed = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0 || !isPtrTy(n.res().ty())) continue;
                if (n.ops().count() < (u32)1) continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (n.op().equals(String.withCString("AddrOf"))) {
                    if (o.kind() != (u8)OPK_SYM || o.name() == (String*)0) continue;
                    String* lbl = String.withCString("_");
                    lbl.append(o.name());
                    _absSym.set((Hashable*)n.res(), (Object*)lbl);
                } else if (n.op().equals(String.withCString("Bitcast"))) {
                    if (o.kind() != (u8)OPK_USE) continue;
                    Object* src = _absSym.get((Hashable*)o.val());
                    if (src != (Object*)0) _absSym.set((Hashable*)n.res(), src);
                }
            }
        }
        findSuppressibleAddrOfs(fn);
    }

    // An `AddrOf @sym` whose pointer bytes are never actually read can skip its
    // materialisation entirely. Two guards keep that provably safe: a SCALAR
    // pointee only — an aggregate or pointer pointee flows into FieldAddr,
    // dispatch or a call as a base, uses this scan may not recognise — and
    // SAME-BLOCK uses only, because a cross-block use (the static-init guard's
    // load and store sit in different blocks) is exactly the shape that once
    // dropped a live pointer.
    void findSuppressibleAddrOfs(IRFunc* fn)
    {
        Array* cand = new Array();
        Array* candBlock = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("AddrOf"))) continue;
                if (n.res() == (IRValue*)0) continue;
                if (_absSym.get((Hashable*)n.res()) == (Object*)0) continue;
                String* pte = pointeeOf(n.res().ty());
                if (!isScalarLeafTy(pte)) continue;
                cand.add((Object*)n.res());
                candBlock.add((Object*)Number.withU32(b));
            }
        }
        if (cand.count() == (u32)0) return;
        Array* dead = new Array();
        for (u32 i = (u32)0; i < cand.count(); i = i + (u32)1) dead.add((Object*)Number.withU32((u32)0));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* seq = allInsns(bb);
            for (u32 i = (u32)0; i < seq.count(); i = i + (u32)1) {
                IRInsn* n = (IRInsn*)seq.get(i);
                bool isLoadStore = n.op().equals(String.withCString("Load"))
                    || n.op().equals(String.withCString("LoadVolatile"))
                    || n.op().equals(String.withCString("Store"))
                    || n.op().equals(String.withCString("StoreVolatile"));
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1) {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE) continue;
                    for (u32 c = (u32)0; c < cand.count(); c = c + (u32)1) {
                        if ((IRValue*)cand.get(c) != o.val()) continue;
                        bool sameBlock = ((Number*)candBlock.get(c)).asU32() == b;
                        if (!(isLoadStore && k == (u32)0 && sameBlock))
                            dead.set(c, (Object*)Number.withU32((u32)1));
                    }
                }
            }
        }
        for (u32 c = (u32)0; c < cand.count(); c = c + (u32)1)
            if (((Number*)dead.get(c)).asU32() == (u32)0) _suppressed.add(cand.get(c));
    }

    static bool isScalarLeafTy(String* t)
    {
        if (t == (String*)0) return false;
        // I64/U64 included: the reference spells this `XTIRTypeKindIsInteger`,
        // which grew the 64-bit kinds for free, while this list had to be told.
        // Nothing in the tree took the address of a 64-bit GLOBAL until
        // tests/fixtures/int64_unary.xc, so the two stayed silently out of step
        // and the port emitted a dead `LDA #<_sym` triple the reference elides.
        return isFloatTy(t) || t.equals(String.withCString("Bool"))
            || t.equals(String.withCString("I8"))  || t.equals(String.withCString("U8"))
            || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"))
            || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
            || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"));
    }

    String* absSymFor(IRValue* v)
    {
        if (_absSym == (Map*)0 || v == (IRValue*)0) return (String*)0;
        Object* o = _absSym.get((Hashable*)v);
        return o == (Object*)0 ? (String*)0 : (String*)o;
    }

    static String* absSymOperand(String* label, u32 byteIndex)
    {
        if (byteIndex == (u32)0) return label;
        String* o = String.withCString(label.cString());
        o.appendFormat("+%lu", byteIndex);
        return o;
    }

    bool isSuppressed(IRValue* v)
    {
        if (_suppressed == (Array*)0) return false;
        for (u32 i = (u32)0; i < _suppressed.count(); i = i + (u32)1)
            if ((IRValue*)_suppressed.get(i) == v) return true;
        return false;
    }

    // ── Control flow ─────────────────────────────────────────────────────
    u32 _labelCounter;

    void emitBranch(IRBlock* bb, IRInsn* n)
    {
        if (n.ops().count() < (u32)1) return;
        IROperand* t = (IROperand*)n.ops().get((u32)0);
        if (t.kind() != (u8)OPK_BLOCK) return;
        emitPhiCopies(bb, t.blk());
        _out.appendFormat("    JMP %s\n", blockLabel(_fn, t.blk()).cString());
    }

    // Both successors' phi copies run BEFORE the physical branch — both blocks
    // are reachable, so the copies have to be done without knowing which way
    // the jump goes. The allocator never aliases a phi source with a phi
    // result, so they cannot conflict; the condition is simply re-loaded
    // afterwards, since the copies clobber A.
    void emitCondBranch(IRBlock* bb, IRInsn* n)
    {
        if (n.ops().count() < (u32)3) return;
        IROperand* cond = (IROperand*)n.ops().get((u32)0);
        IROperand* t = (IROperand*)n.ops().get((u32)1);
        IROperand* f = (IROperand*)n.ops().get((u32)2);
        loadOperandByte(cond, (u32)0);
        emitPhiCopies(bb, t.blk());
        emitPhiCopies(bb, f.blk());
        loadOperandByte(cond, (u32)0);
        // BEQ has the same ±127 reach as BRA, but here it spans only the
        // 3-byte JMP-true, which is always in range; the JMPs carry the
        // long-distance cases.
        u32 lbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        _out.appendFormat("    BEQ .Lcbsk_%lu\n", lbl);
        _out.appendFormat("    JMP %s\n", blockLabel(_fn, t.blk()).cString());
        _out.appendFormat(".Lcbsk_%lu:\n", lbl);
        _out.appendFormat("    JMP %s\n", blockLabel(_fn, f.blk()).cString());
    }

    // Phi copies are a PARALLEL assignment: a loop's `v <- c` and `c <- c+1`
    // must both read the OLD c, so a naive in-order copy is off by one. Emit in
    // dependency order — a copy whose destination nothing pending still reads
    // is safe now — and break a residual cycle by stashing one destination in
    // the $B0.. scratch (free at a branch) and redirecting reads to it. The
    // hardware stack is not an option: SP-relative slots would shift under it.
    void emitPhiCopies(IRBlock* pred, IRBlock* succ)
    {
        Array* dests = new Array();
        Array* srcs = new Array();
        for (u32 i = (u32)0; i < succ.phis().count(); i = i + (u32)1) {
            IRInsn* phi = (IRInsn*)succ.phis().get(i);
            if (phi.res() == (IRValue*)0) continue;
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2) {
                IROperand* bop = (IROperand*)phi.ops().get(k);
                if (bop.kind() != (u8)OPK_BLOCK || bop.blk() != pred) continue;
                dests.add((Object*)phi.res());
                srcs.add((Object*)phi.ops().get(k + (u32)1));
                break;
            }
        }
        u32 n = dests.count();
        if (n == (u32)0) return;
        Array* pending = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) pending.add((Object*)Number.withU32(i));
        Map* redir = new Map();
        u32 scratch = (u32)$B0;
        while (pending.count() > (u32)0) {
            i32 pick = (i32)-1;
            for (u32 pi = (u32)0; pi < pending.count(); pi = pi + (u32)1) {
                u32 idx = ((Number*)pending.get(pi)).asU32();
                IRValue* d = (IRValue*)dests.get(idx);
                bool blocked = false;
                for (u32 oi = (u32)0; oi < pending.count(); oi = oi + (u32)1) {
                    u32 o = ((Number*)pending.get(oi)).asU32();
                    if (o == idx) continue;
                    IROperand* so = (IROperand*)srcs.get(o);
                    if (so.kind() == (u8)OPK_USE && so.val() == d) { blocked = true; break; }
                }
                if (!blocked) { pick = (i32)pi; break; }
            }
            if (pick < (i32)0) {                     // cycle: stash one, redirect
                pick = (i32)0;
                u32 idx = ((Number*)pending.get((u32)0)).asU32();
                IRValue* d = (IRValue*)dests.get(idx);
                u32 w = byteWidth(d.ty());
                for (u32 b = (u32)0; b < w; b = b + (u32)1) {
                    String* o = operandFor(d, b);
                    if (o == (String*)0) continue;
                    _out.appendFormat("    LDA %s\n    STA $%s\n",
                                      o.cString(), hex2(scratch + b).cString());
                }
                redir.set((Hashable*)d, (Object*)Number.withU32(scratch));
                scratch = scratch + w;
            }
            u32 idx = ((Number*)pending.get((u32)pick)).asU32();
            IRValue* d = (IRValue*)dests.get(idx);
            IROperand* sv = (IROperand*)srcs.get(idx);
            u32 w = byteWidth(d.ty());
            for (u32 b = (u32)0; b < w; b = b + (u32)1) {
                Object* rs = sv.kind() == (u8)OPK_USE ? redir.get((Hashable*)sv.val()) : (Object*)0;
                if (rs != (Object*)0)
                    _out.appendFormat("    LDA $%s\n",
                                      hex2(((Number*)rs).asU32() + b).cString());
                else
                    loadOperandByte(sv, b);
                storeAToValue(d, b);
            }
            pending.removeAt((u32)pick);
        }
    }

    // The return value lives on the SP frame, and `PLL` both restores the
    // caller's registers and deallocates that frame — so a frame-resident
    // result can be neither read after the PLL nor held in a register through
    // it. Stage it into the ZP $B0.. mailbox, which PLL leaves alone (and which
    // is also the float return register), then move it into A/X/Y/$89
    // afterwards. Convention: 1 byte A; 2 bytes A=lo,X=hi; 3 bytes A,X,Y
    // (bank in Y); 4 bytes A,X,Y,$89; float/double/aggregate stay in $B0...
    void emitReturn(IRInsn* n)
    {
        bool hasValue = n.ops().count() > (u32)1;
        IROperand* v = hasValue ? (IROperand*)n.ops().get((u32)0) : (IROperand*)0;
        IRValue* rvv = hasValue && v.kind() == (u8)OPK_USE ? v.val() : (IRValue*)0;
        u32 rW = rvv != (IRValue*)0 ? byteWidth(rvv.ty()) : (u32)1;
        bool isFloat = rvv != (IRValue*)0 && isFloatTy(rvv.ty());
        bool isAgg = rvv != (IRValue*)0 && isAggTy(rvv.ty());
        // A scalar wider than the A/X/Y/$89 quartet — i64/u64 — is LEFT in the
        // $B0.. mailbox for the caller to harvest, the same contract float,
        // double and by-value structs already use.
        bool isWideScalar = hasValue && !isFloat && !isAgg && rW > (u32)4;
        if (hasValue && isAgg && rW > (u32)16)
            { unsupported(String.withCString("Return:aggwidth")); return; }
        // spDelta is 0 at a terminator, so the operand is settled.
        if (hasValue && v.kind() == (u8)OPK_USE) {
            for (u32 b = (u32)0; b < rW; b = b + (u32)1) {
                String* src = operandFor(rvv, b);
                if (src == (String*)0) break;
                _out.appendFormat("    LDA %s\n", src.cString());
                _out.appendFormat("    STA $%s\n", hex2((u32)$B0 + b).cString());
            }
        }
        // PLL #N mirrors the prologue's PSH #N (SP += N+7, guard byte
        // included); without it SP is left low and RTS returns to garbage.
        // The :irq / :vbi shapes skipped the PSH and pop by hand below.
        if (_xtcStack) emitXtcStackEpilogue();
        else if (!isIrq(_fn) && !isVbi(_fn))
            _out.appendFormat("    PLL #%lu\n", _spFrameSize);
        if (!_xtcStack) emitSoftStackPop();
        if (hasValue) {
            if (isFloat || isAgg || isWideScalar) {
                // already staged in the $B0.. mailbox
            } else if (v.kind() == (u8)OPK_USE) {
                // $B3 goes to $89 BEFORE $B0 reaches A — loading $B3 clobbers A.
                if (rW >= (u32)4) _out.appendCString("    LDA $B3\n    STA $89\n");
                if (rW >= (u32)3) _out.appendCString("    LDY $B2\n");
                if (rW >= (u32)2) _out.appendCString("    LDX $B1\n");
                _out.appendCString("    LDA $B0\n");
            } else if (v.kind() == (u8)OPK_IMMI) {
                i32 imm = (i32)v.imm();
                if (rW >= (u32)4) {
                    _out.appendFormat("    LDA #$%s\n", hex2(((u32)imm >> (u32)24) & (u32)$FF).cString());
                    _out.appendCString("    STA $89\n");
                }
                if (rW >= (u32)3)
                    _out.appendFormat("    LDY #$%s\n", hex2(((u32)imm >> (u32)16) & (u32)$FF).cString());
                if (rW >= (u32)2)
                    _out.appendFormat("    LDX #$%s\n", hex2(((u32)imm >> (u32)8) & (u32)$FF).cString());
                _out.appendFormat("    LDA #$%s\n", hex2((u32)imm & (u32)$FF).cString());
            }
        }
        if (isIrq(_fn)) { _out.appendCString("    RTI\n"); return; }
        if (isVbi(_fn)) {
            _out.appendCString("    PLA\n    TAY\n    PLA\n    TAX\n    PLA\n");
            _out.appendCString("    JMP $E462\n");    // XITVBV
            return;
        }
        _out.appendCString("    RTS\n");
    }

    // ── Compare ──────────────────────────────────────────────────────────
    //
    // High byte to low, falling through to the low-byte CMP while the high
    // bytes are equal. After the last CMP, C = (a >= b) unsigned and Z =
    // (a == b), and the Bool result is derived from those two flags.
    void emitICmp(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) return;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        IROperand* r = (IROperand*)n.ops().get((u32)1);
        u32 w = a.kind() == (u8)OPK_USE ? byteWidth(a.val().ty()) : (u32)1;
        String* p = n.pred();
        bool signedCmp = false;
        String* eff = p;
        if (p.equals(String.withCString("SLT"))) { eff = String.withCString("ULT"); signedCmp = true; }
        else if (p.equals(String.withCString("SGT"))) { eff = String.withCString("UGT"); signedCmp = true; }
        else if (p.equals(String.withCString("SLE"))) { eff = String.withCString("ULE"); signedCmp = true; }
        else if (p.equals(String.withCString("SGE"))) { eff = String.withCString("UGE"); signedCmp = true; }

        u32 label = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        u32 b = w;
        while (b > (u32)0) {
            b = b - (u32)1;
            bool highByte = b == w - (u32)1;
            if (signedCmp && highByte) {
                // Flip both sign bits so the unsigned CMP yields the signed
                // ordering. $BF is free here — only Mul and the float helpers
                // touch $B0-$BF.
                if (r.kind() == (u8)OPK_USE) {
                    _out.appendFormat("    LDA %s\n", operandFor(r.val(), b).cString());
                    _out.appendCString("    EOR #$80\n    STA $BF\n");
                    loadOperandByte(a, b);
                    _out.appendCString("    EOR #$80\n    CMP $BF\n");
                } else if (r.kind() == (u8)OPK_IMMI) {
                    u32 bv = byteOfImm(r, b) ^ (u32)$80;
                    loadOperandByte(a, b);
                    _out.appendCString("    EOR #$80\n");
                    _out.appendFormat("    CMP #$%s\n", hex2(bv).cString());
                }
            } else {
                loadOperandByte(a, b);
                if (r.kind() == (u8)OPK_USE)
                    _out.appendFormat("    CMP %s\n", operandFor(r.val(), b).cString());
                else if (r.kind() == (u8)OPK_IMMI)
                    _out.appendFormat("    CMP #$%s\n",
                        hex2(byteOfImm(r, b)).cString());
            }
            if (b > (u32)0) _out.appendFormat("    BNE .Licmp%lu_done\n", label);
        }
        _out.appendFormat(".Licmp%lu_done:\n", label);

        //   EQ  Z=1        NE  Z=0        ULT C=0        UGE C=1
        //   UGT C=1 AND Z=0               ULE C=0 OR  Z=1
        u32 setLbl = _labelCounter; _labelCounter = _labelCounter + (u32)1;
        String* yes = (String*)0;
        if (eff.equals(String.withCString("EQ")))  yes = String.withCString("BEQ");
        else if (eff.equals(String.withCString("NE")))  yes = String.withCString("BNE");
        else if (eff.equals(String.withCString("ULT"))) yes = String.withCString("BCC");
        else if (eff.equals(String.withCString("UGE"))) yes = String.withCString("BCS");
        if (yes != (String*)0) {
            // Branch on the LIVE flags BEFORE touching A: `LDA #$00` clears Z,
            // which would make the Z-testing BEQ/BNE always or never true.
            // BCC/BCS were unaffected because LDA leaves carry alone — which is
            // exactly why ULT/UGE worked while EQ/NE silently returned true.
            _out.appendFormat("    %s .Licmp%lu_set\n", yes.cString(), setLbl);
            _out.appendCString("    LDA #$00\n");
            _out.appendFormat("    BRA .Licmp%lu_store\n", setLbl);
            _out.appendFormat(".Licmp%lu_set:\n", setLbl);
            _out.appendCString("    LDA #$01\n");
            _out.appendFormat(".Licmp%lu_store:\n", setLbl);
            storeAToValue(n.res(), (u32)0);
            return;
        }
        bool isUGT = eff.equals(String.withCString("UGT"));
        if (!isUGT && !eff.equals(String.withCString("ULE")))
            { unsupported(String.withCString("ICmp:pred")); return; }
        // Two early-outs, both branching on the live flags — 6502 branches
        // don't touch flags, so Z survives the BCC for the following BEQ.
        // Loading A first would clear Z and break the a == b case.
        String* fall = isUGT ? String.withCString("$01") : String.withCString("$00");
        String* flip = isUGT ? String.withCString("$00") : String.withCString("$01");
        _out.appendFormat("    BCC .Licmp%lu_flip\n", setLbl);
        _out.appendFormat("    BEQ .Licmp%lu_flip\n", setLbl);
        _out.appendFormat("    LDA #%s\n", fall.cString());
        _out.appendFormat("    BRA .Licmp%lu_store\n", setLbl);
        _out.appendFormat(".Licmp%lu_flip:\n", setLbl);
        _out.appendFormat("    LDA #%s\n", flip.cString());
        _out.appendFormat(".Licmp%lu_store:\n", setLbl);
        storeAToValue(n.res(), (u32)0);
    }

    // ── Width conversions ────────────────────────────────────────────────
    u32 srcWidthOf(IROperand* o, u32 fallback)
    {
        if (o.kind() == (u8)OPK_USE) return byteWidth(o.val().ty());
        if (o.kind() == (u8)OPK_IMMI && o.ty() != (String*)0) return byteWidth(o.ty());
        return fallback;
    }

    void emitZExt(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        u32 srcW = src.kind() == (u8)OPK_USE ? byteWidth(src.val().ty()) : (u32)1;
        u32 dstW = byteWidth(n.res().ty());
        for (u32 b = (u32)0; b < dstW; b = b + (u32)1) {
            if (b < srcW) loadOperandByte(src, b);
            else          _out.appendCString("    LDA #$00\n");
            storeAToValue(n.res(), b);
        }
    }

    void emitSExt(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        u32 srcW = src.kind() == (u8)OPK_USE ? byteWidth(src.val().ty()) : (u32)1;
        u32 dstW = byteWidth(n.res().ty());
        for (u32 b = (u32)0; b < srcW; b = b + (u32)1) {
            loadOperandByte(src, b);
            storeAToValue(n.res(), b);
        }
        if (dstW <= srcW) return;
        if (src.kind() == (u8)OPK_USE) {
            // The high bytes need $00 or $FF replicated from the source's sign
            // bit. `BIT <msb>` derives N from memory IMMEDIATELY before the
            // BPL, so the dependency is explicit rather than resting on no
            // intervening instruction happening to touch A.
            u32 labelN = _labelCounter; _labelCounter = _labelCounter + (u32)1;
            if (onSPFrame(src.val())) {
                // BIT has no d,SP form — stage the MSB through $BF.
                _out.appendFormat("    LDA %s\n",
                                  operandFor(src.val(), srcW - (u32)1).cString());
                _out.appendCString("    STA $BF\n    LDA #$00\n    BIT $BF\n");
            } else {
                i32 srcBase = slotOf(src.val());
                _out.appendCString("    LDA #$00\n");
                _out.appendFormat("    BIT $%s\n",
                                  hex2((u32)srcBase + srcW - (u32)1).cString());
            }
            _out.appendFormat("    BPL .Lse%lu_done\n", labelN);
            _out.appendCString("    LDA #$FF\n");
            _out.appendFormat(".Lse%lu_done:\n", labelN);
            for (u32 b = srcW; b < dstW; b = b + (u32)1) storeAToValue(n.res(), b);
        } else if (src.kind() == (u8)OPK_IMMI) {
            // Constant source: the sign-extended high bytes are known now, so
            // there is no runtime flag dependency at all.
            i32 v = (i32)src.imm();
            bool negative = (((u32)v >> ((u32)8 * srcW - (u32)1)) & (u32)1) != (u32)0;
            _out.appendFormat("    LDA #$%s\n", (negative ? String.withCString("FF")
                                                          : String.withCString("00")).cString());
            for (u32 b = srcW; b < dstW; b = b + (u32)1) storeAToValue(n.res(), b);
        }
    }

    // Bitcast may widen as well as narrow, so the source width has to be known:
    // without it loadOperandByte reads whatever adjacent slot follows, which is
    // some other live value.
    void emitTruncBitcast(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) return;
        u32 dstW = byteWidth(n.res().ty());
        IROperand* src = (IROperand*)n.ops().get((u32)0);
        u32 srcW = srcWidthOf(src, dstW);
        // Widening a 2-byte pointer into a 3-byte banked one: the bank byte is
        // the heap's implicit bank, not zero, or loads through the widened
        // pointer reach the wrong data page.
        bool toBankedPtr = dstW > srcW && dstW > (u32)2;
        for (u32 b = (u32)0; b < dstW; b = b + (u32)1) {
            if (b < srcW) loadOperandByte(src, b);
            else if (toBankedPtr && b == (u32)2)
                _out.appendCString("    LDA #heap_bank_first\n");
            else _out.appendCString("    LDA #$00\n");
            storeAToValue(n.res(), b);
        }
    }

    // ── Inline asm ───────────────────────────────────────────────────────
    //
    // The body is emitted verbatim, with three kinds of planted token resolved
    // first. Each names something the assembly cannot know for itself: where a
    // pinned local ended up, which byte of it, or where a static class's data
    // block starts.
    void emitAsm(IRInsn* n)
    {
        u32 cid = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_CPOOL) { cid = o.cid(); break; }
        }
        if (cid == (u32)$FFFF_FFFF || _m == (IRModule*)0 || cid >= _m.consts().count()) return;
        String* text = bytesToString((Array*)_m.consts().get(cid));
        text = resolveLocals(text);
        text = resolveLocalBytes(text);
        text = resolveIvars(text);
        _out.appendCString("    ; inline asm\n");
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* l = (String*)lines.get(i);
            if (l.byteLength() == (u32)0) continue;
            _out.appendFormat("    %s\n", l.cString());
        }
    }

    // `{{XTLOCAL:<vid>}}` — a whole pinned local: its ZP byte, or its spill
    // label when it did not fit.
    String* resolveLocals(String* text)
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
            j = readNumber(text, j, &vid);
            j = skipCloser(text, j);
            out.append(localOperand(vid, (u32)0));
            i = j;
        }
        return out;
    }

    // `{{XTLOCALB:<vid>:<byte>}}` — ONE byte of a pinned local, selected by an
    // asm byte-extraction operator. The bytes sit consecutively in the slot, so
    // byte k is at `$slot+k` — and it is emitted as a ZP ADDRESS, not a `#`
    // immediate, so `LDA <val` reads the byte's VALUE rather than its address.
    String* resolveLocalBytes(String* text)
    {
        String* marker = String.withCString("{{XTLOCALB:");
        if (text.byteIndexOf(marker) == (u32)$FFFF_FFFF) return text;
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < text.byteLength()) {
            u32 at = text.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF) { out.append(text.substringFromByte(i)); break; }
            out.append(text.substringBytes(i, at - i));
            u32 j = at + marker.byteLength();
            u32 vid = (u32)0;
            u32 byte = (u32)0;
            j = readNumber(text, j, &vid);
            if (j < text.byteLength() && text.byteAt(j) == (u8)':') j = j + (u32)1;
            j = readNumber(text, j, &byte);
            j = skipCloser(text, j);
            out.append(localOperand(vid, byte));
            i = j;
        }
        return out;
    }

    String* localOperand(u32 vid, u32 byte)
    {
        IRValue* v = _fn.valueWithId(vid);
        i32 slot = slotOf(v);
        if (slot >= (i32)0) {
            String* o = String.withCString("$");
            o.append(hex2((u32)slot + byte));
            return o;
        }
        Object* sp = v == (IRValue*)0 ? (Object*)0 : _spillLabel.get((Hashable*)v);
        if (sp == (Object*)0) return String.withCString("$00");
        String* o = String.withCString(((String*)sp).cString());
        if (byte != (u32)0) o.appendFormat("+%lu", byte);
        return o;
    }

    // `{{XTIVAR:<symId>:<byteOff>}}` — a static utility class's ivar. Without
    // this the bare ivar name leaks as an undefined symbol and resolves to
    // $0000.
    String* resolveIvars(String* text)
    {
        String* marker = String.withCString("{{XTIVAR:");
        if (text.byteIndexOf(marker) == (u32)$FFFF_FFFF) return text;
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < text.byteLength()) {
            u32 at = text.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF) { out.append(text.substringFromByte(i)); break; }
            out.append(text.substringBytes(i, at - i));
            u32 j = at + marker.byteLength();
            u32 sid = (u32)0;
            u32 off = (u32)0;
            j = readNumber(text, j, &sid);
            if (j < text.byteLength() && text.byteAt(j) == (u8)':') j = j + (u32)1;
            j = readNumber(text, j, &off);
            j = skipCloser(text, j);
            if (_m != (IRModule*)0 && sid < _m.syms().count())
                out.appendFormat("_%s+%lu", ((IRSymbol*)_m.syms().get(sid)).name().cString(), off);
            else
                out.appendCString("$00");
            i = j;
        }
        return out;
    }

    static u32 readNumber(String* text, u32 i, u32* out)
    {
        u32 n = (u32)0;
        while (i < text.byteLength() && text.byteAt(i) >= (u8)'0' && text.byteAt(i) <= (u8)'9') {
            n = n * (u32)10 + (u32)(text.byteAt(i) - (u8)'0');
            i = i + (u32)1;
        }
        *out = n;
        return i;
    }

    static u32 skipCloser(String* text, u32 i)
    {
        if (i + (u32)1 < text.byteLength() && text.byteAt(i) == (u8)'}') return i + (u32)2;
        return i;
    }

    // A struct field's address: the base pointer plus a compile-time offset,
    // added across the pointer's ADDRESS bytes only — the bank byte comes
    // through unchanged, because a field of a banked object is in the same
    // bank as the object.
    void emitFieldAddr(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* b = (IROperand*)n.ops().get((u32)0);
        IROperand* ix = (IROperand*)n.ops().get((u32)1);
        if (b.kind() != (u8)OPK_USE || ix.kind() != (u8)OPK_IMMI)
            { unsupported(String.withCString("FieldAddr:operand")); return; }
        u32 off = fieldByteOffset(b.val(), (u32)ix.imm());
        _out.appendCString("    CLC\n");
        loadOperandByte(b, (u32)0);
        _out.appendFormat("    ADC #$%s\n", hex2(off & (u32)$FF).cString());
        storeAToValue(n.res(), (u32)0);
        loadOperandByte(b, (u32)1);
        _out.appendFormat("    ADC #$%s\n", hex2((off >> (u32)8) & (u32)$FF).cString());
        storeAToValue(n.res(), (u32)1);
        u32 w = byteWidth(n.res().ty());
        for (u32 k = (u32)2; k < w; k = k + (u32)1) {
            loadOperandByte(b, k);
            storeAToValue(n.res(), k);
        }
    }

    u32 fieldByteOffset(IRValue* base, u32 idx)
    {
        IRLayout* l = layoutOf(pointeeOf(base.ty()));
        if (l == (IRLayout*)0) return (u32)0;
        return l.offsetAt(idx);
    }

    // ── Memory ───────────────────────────────────────────────────────────
    //
    // Every access goes through `(ptr),Y` with Y walking the bytes, and every
    // 3-byte pointer selects its data bank FIRST.
    void emitStore(IRInsn* n)
    {
        if (n.ops().count() < (u32)3) { unsupported(n.op()); return; }
        IROperand* ptrOp = (IROperand*)n.ops().get((u32)0);
        IROperand* valOp = (IROperand*)n.ops().get((u32)1);
        if (ptrOp.kind() != (u8)OPK_USE) { unsupported(String.withCString("Store:ptr")); return; }
        String* abs = absSymFor(ptrOp.val());
        if (abs != (String*)0) {
            u32 sw = valueWidthOf(valOp);
            for (u32 b = (u32)0; b < sw; b = b + (u32)1) {
                loadOperandByte(valOp, b);
                _out.appendFormat("    STA %s\n", absSymOperand(abs, b).cString());
            }
            return;
        }
        String* ind = indirectBaseFor(ptrOp.val());
        if (ind == (String*)0) { unsupported(String.withCString("Store:home")); return; }
        emitBankSelect(ptrOp.val());
        u32 w = valueWidthOf(valOp);
        for (u32 b = (u32)0; b < w; b = b + (u32)1) {
            loadOperandByte(valOp, b);
            if (b == (u32)0) _out.appendCString("    LDY #$00\n");
            else             _out.appendCString("    INY\n");
            _out.appendFormat("    STA %s,Y\n", ind.cString());
        }
    }

    void emitLoad(IRInsn* n)
    {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        IROperand* ptrOp = (IROperand*)n.ops().get((u32)0);
        if (ptrOp.kind() != (u8)OPK_USE) { unsupported(String.withCString("Load:ptr")); return; }
        // AddrOf results are flat bank-0 main RAM, so a direct absolute load is
        // exactly the generic set-bank-0 + indirect-Y deref, minus the pointer
        // build, the __bank_data_reg write and the indirection.
        String* abs = absSymFor(ptrOp.val());
        if (abs != (String*)0) {
            u32 lw = byteWidth(n.res().ty());
            for (u32 b = (u32)0; b < lw; b = b + (u32)1) {
                _out.appendFormat("    LDA %s\n", absSymOperand(abs, b).cString());
                storeAToValue(n.res(), b);
            }
            return;
        }
        String* ind = indirectBaseFor(ptrOp.val());
        if (ind == (String*)0) { unsupported(String.withCString("Load:home")); return; }
        emitBankSelect(ptrOp.val());
        u32 w = byteWidth(n.res().ty());
        for (u32 b = (u32)0; b < w; b = b + (u32)1) {
            if (b == (u32)0) _out.appendCString("    LDY #$00\n");
            else             _out.appendCString("    INY\n");
            _out.appendFormat("    LDA %s,Y\n", ind.cString());
            storeAToValue(n.res(), b);
        }
    }

    // The data bank is selected from the pointer's OWN byte 2, on every 3-byte
    // pointer — not from the IR's window tag. A FieldAddr or ElementAddr into a
    // banked object is unbanked-TYPED yet addresses the window, so a
    // tag-driven test missed it and the access used whatever bank happened to
    // be selected — wrong the moment it drifted. Byte 2 of zero selects the
    // main-RAM aperture, so the flat case costs the same two instructions and
    // needs no branch.
    void emitBankSelect(IRValue* ptr)
    {
        if (!banking()) return;
        emitBankSelectAlways(ptr);
    }

    // The same select, WITHOUT the sizing pass's suppression.
    //
    // Selecting the data bank does not depend on the code-bank map — it reads
    // byte 2 of the pointer at run time — so a dispatch receiver's select is
    // emitted even while the first sizing pass is pretending the target is
    // flat. The original does exactly this: it gates the Load/Store selects on
    // `bankingActive` and leaves the two DISPATCH selects ungated. Routing all
    // four through one gate made the port measure the dispatch-heavy Number
    // accessors 5 bytes light, which packed `Number$asI32` into bank 8 where
    // the original put it in 9 — and from there the two disagreed about which
    // calls were cross-bank. private:docs/bugs/054.
    //
    // The LAYOUT's banking still gates it: a flat target has no data-bank
    // register to write.
    void emitBankSelectAlways(IRValue* ptr)
    {
        if (!_layout.hasBanking() || _layout.bankWindowStart() == (u32)0
            || _layout.mainRanges().count() == (u32)0) return;
        if (ptr == (IRValue*)0 || !isPtrTy(ptr.ty())) return;
        if (byteWidth(ptr.ty()) < (u32)3) return;
        String* bankByte = operandFor(ptr, (u32)2);
        if (bankByte == (String*)0) return;
        _out.appendFormat("    LDA %s\n", bankByte.cString());
        _out.appendCString("    STA __bank_data_reg\n");
    }

    // A stored value's width comes from the operand's own type — and an
    // immediate carries its type in the IR, which is the only way to know how
    // many bytes a `Store ptr, #0` writes.
    u32 valueWidthOf(IROperand* op)
    {
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0) return byteWidth(op.val().ty());
        if (op.kind() == (u8)OPK_IMMI && op.ty() != (String*)0) return byteWidth(op.ty());
        return (u32)1;
    }

    // Multi-byte add and subtract, little-endian, carry chaining through the
    // bytes — which is why every helper called in between has to preserve it.
    void emitAddSub(IRInsn* n)
    {
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0) { unsupported(n.op()); return; }
        bool add = n.op().equals(String.withCString("Add"));
        u32 width = byteWidth(n.res().ty());
        _out.appendCString(add ? "    CLC\n" : "    SEC\n");
        String* mnem = String.withCString(add ? "ADC" : "SBC");
        IROperand* lhs = (IROperand*)n.ops().get((u32)0);
        IROperand* rhs = (IROperand*)n.ops().get((u32)1);
        for (u32 b = (u32)0; b < width; b = b + (u32)1) {
            loadOperandByte(lhs, b);
            if (rhs.kind() == (u8)OPK_USE) {
                // ADC and SBC both have a d,SP form, so a frame operand swaps
                // in mechanically under the same mnemonic.
                String* operand = operandFor(rhs.val(), b);
                if (operand == (String*)0) { unsupported(String.withCString("AddSub:rhs")); return; }
                _out.appendFormat("    %s %s\n", mnem.cString(), operand.cString());
            } else if (rhs.kind() == (u8)OPK_IMMI) {
                _out.appendFormat("    %s #$%s\n", mnem.cString(), hex2(byteOfImm(rhs, b)).cString());
            } else {
                unsupported(String.withCString("AddSub:rhs"));
                return;
            }
            storeAToValue(n.res(), b);
        }
    }

    String* blockLabel(IRFunc* fn, IRBlock* bb)
    {
        String* s = String.withCString("_");
        s.append(fn.name());
        s.appendCString("__");
        s.append(bb.name());
        return s;
    }

    // Four UPPERCASE hex digits — appendFormat has no zero-padded hex, and the
    // assembly wants `$D5C0`.
    static String* hex4(u32 v)
    {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            o.appendByte(hexDigit((v >> ((u32)4 * ((u32)3 - i))) & (u32)$F));
        return o;
    }

    static String* hex2(u32 v)
    {
        String* o = String.withCString("");
        o.appendByte(hexDigit((v >> (u32)4) & (u32)$F));
        o.appendByte(hexDigit(v & (u32)$F));
        return o;
    }

    static u8 hexDigit(u32 d)
    {
        string digits = "0123456789ABCDEF";
        return digits[d];
    }
}
