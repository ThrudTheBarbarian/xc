// OptStrengthReduce.xc — the StrengthReduce pass, ported from src/xtc/ir/XTIROptStrengthReduce.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (StrengthReduce)
    {

    // ── strength-reduce ──────────────────────────────────────────────────
    //
    // Multiply and divide by a power of two become a shift, and the ×0 / %1
    // cases become a constant. `x*1` and `x/1` are deliberately left alone:
    // reducing them to `x` needs a use-rewrite, and the xt6502 backend has no
    // Copy to lower, so the identities that pay are the ones emitting a
    // supported Shl / LShr / And / Const.
    final void strengthReduce(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            srInFunc((IRFunc*)m.funcs().get(f));
        }

    final void srInFunc(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        bool changed = srFloat(fn, defOf);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (srInsn(bb, i, defOf))
                    changed = true;
            }
        if (!changed)
            return;
        srSweepDead(fn);
        }

    // Drop Const / ZExt / SExt / Trunc whose result nothing reads any more —
    // the detached multiplier constant and its widening — to a fixpoint, since
    // removing a widening can orphan the constant behind it. Shared by
    // strength-reduce and const-operand-fold, which end the same way.
    final void srSweepDead(IRFunc* fn)
        {
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* used = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.phis().get(k));
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.insns().get(k));
                if (bb.term() != (IRInsn*)0)
                    srNoteUses(used, bb.term());
                }
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i - (u32)1);
                    if (!srIsPure(n.op()))
                        continue;
                    if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
                        continue;
                    if (used.get((Hashable*)n.res()) != (Object*)0)
                        continue;
                    bb.insns().removeAt(i - (u32)1);
                    removed = true;
                    }
                }
            }
        }

    final void srNoteUses(Map* used, IRInsn* n)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE)
                used.set((Hashable*)o.val(), (Object*)o.val());
            }
        }

    final bool srIsPure(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc"));
        }

    final bool srInsn(IRBlock* bb, u32 i, Map* defOf)
        {
        IRInsn* n = (IRInsn*)bb.insns().get(i);
        String* op = n.op();
        bool isMul = op.equals(String.withCString("Mul"));
        if (!isMul && !op.equals(String.withCString("UDiv")) && !op.equals(String.withCString("URem")) && !op.equals(String.withCString("SDiv")) && !op.equals(String.withCString("SRem")))
            return false;
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
            return false;

        // The constant must be the RHS; Mul commutes, so its LHS is tried too,
        // keeping the other operand as the variable.
        i64 c = (i64)0;
        bool cu = false;
        IROperand* xop = (IROperand*)0;
        if (srConst(defOf, (IROperand*)n.ops().get((u32)1), &c, &cu))
            xop = (IROperand*)n.ops().get((u32)0);
        else if (isMul && srConst(defOf, (IROperand*)n.ops().get((u32)0), &c, &cu))
            xop = (IROperand*)n.ops().get((u32)1);
        else
            return false;

        String* rt = n.res().ty();
        u32 widthBits = srWidth(rt) * (u32)8;
        i32 k = srLog2Pow2(c); // 64-bit aware: the original resolves int64_t
        // The shift count stays in range, so nothing depends on the runtime
        // shift routine's out-of-range behaviour.
        bool pow2 = k >= (i32)1 && widthBits > (u32)0 && (u32)k < widthBits;

        IRInsn* repl = (IRInsn*)0;
        if (isMul)
            {
            if (c == (i64)0)
                repl = srConstZero(n, rt);
            else if (pow2)
                repl = srBinImm(n, String.withCString("Shl"), xop,
                                (i64)k, false, String.withCString("U8"));
            }
        else if (op.equals(String.withCString("UDiv")))
            {
            if (pow2)
                repl = srBinImm(n, String.withCString("LShr"), xop,
                                (i64)k, false, String.withCString("U8"));
            }
        else if (op.equals(String.withCString("URem")))
            {
            if (c == (i64)1)
                repl = srConstZero(n, rt);
            else if (pow2)
                repl = srBinImm(n, String.withCString("And"), xop,
                                c - (i64)1, cu, rt);
            }
        else if (op.equals(String.withCString("SRem")))
            {
            if (c == (i64)1)
                repl = srConstZero(n, rt); // x%1 == 0, any sign
            }
        if (repl == (IRInsn*)0)
            return false;
        bb.insns().set(i, (Object*)repl);
        return true;
        }

    // ── the float rewrites, all exact ──────────────────────────────────────
    //
    // On a target that fuses no plain multiply-add (_srFloatMul), outside
    // :goal(speed) code: x / c, c = ±2^e, is x * (1/c) when 1/c is a normal
    // number of the type: both are the one correctly rounded x·2^-e, NaN,
    // infinities and signed zeros alike. The constant is rewritten in place,
    // so every use of it must be such a divisor. And x * 2 is x + x, and (x * -2) + c with the product read
    // only there is c - (x + x): -2x is -(2x) exactly, and c + -(p) is c - p
    // by definition. clang writes C's `0.0f - 2.0f * v` as fmuladd(-2, v, 0),
    // which C perlin's gradient pays as two multiplies and an add where GCC
    // does one add and a subtract from zero; the x + x it then shares with the
    // other arm's 2v. Code under :goal(speed) is left as it is: its products
    // fuse.
    final bool srFloat(IRFunc* fn, Map* defOf)
        {
        bool changed = false;
        Map* uses = new Map(); // value -> Array@ of the instructions reading it, once per operand
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                srfNote(uses, (IRInsn*)bb.phis().get(k));
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                srfNote(uses, (IRInsn*)bb.insns().get(k));
            if (bb.term() != (IRInsn*)0)
                srfNote(uses, bb.term());
            }
        bool mulOk = _srFloatMul && fn.speedHeaders().count() == (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0 || n.ops().count() != (u32)2)
                    continue;
                // A contract-marked add takes only the shared -2 rewrite below.
                bool contract = n.pred() != (String*)0;
                if (contract && (!n.pred().equals(String.withCString("contract")) || !n.op().equals(String.withCString("FAdd"))))
                    continue;
                String* ty = n.res().ty();
                if (!ty.equals(String.withCString("F32")) && !ty.equals(String.withCString("F64")))
                    continue;
                IROperand* a = (IROperand*)n.ops().get((u32)0);
                IROperand* c = (IROperand*)n.ops().get((u32)1);
                // The divide too only where products never fuse: a multiply
                // where a divide stood is one arm64 fuses with the add after
                // it, rounding once where the program rounded twice, and -O3
                // then disagreed with -O0 (math_rand_float_range, ahl).
                if (n.op().equals(String.withCString("FDiv")) && mulOk)
                    {
                    IRInsn* k = srfConstOf(defOf, c, ty);
                    if (k == (IRInsn*)0)
                        continue;
                    String* rh = srfRecipHex(((IROperand*)k.ops().get((u32)0)).fpHex(), ty.equals(String.withCString("F32")));
                    if (rh == (String*)0)
                        continue;
                    Array* us = (Array*)uses.get((Hashable*)c.val());
                    bool allDiv = us != (Array*)0;
                    for (u32 j = (u32)0; allDiv && j < us.count(); j = j + (u32)1)
                        {
                        IRInsn* u = (IRInsn*)us.get(j);
                        if (!u.op().equals(String.withCString("FDiv")) || u.ops().count() != (u32)2 || u.pred() != (String*)0
                            || u.res() == (IRValue*)0 || !u.res().ty().equals(ty))
                            allDiv = false;
                        else
                            {
                            IROperand* u0 = (IROperand*)u.ops().get((u32)0);
                            IROperand* u1 = (IROperand*)u.ops().get((u32)1);
                            if (u1.kind() != (u8)OPK_USE || u1.val() != c.val()
                                || (u0.kind() == (u8)OPK_USE && u0.val() == c.val()))
                                allDiv = false;
                            }
                        }
                    if (!allDiv)
                        continue;
                    k.ops().set((u32)0, (Object*)IROperand.immF(rh, ((IROperand*)k.ops().get((u32)0)).ty()));
                    for (u32 j = (u32)0; j < us.count(); j = j + (u32)1)
                        srfRetag(fn, (IRInsn*)us.get(j), "FMul", (IROperand*)0, (IROperand*)0);
                    changed = true;
                    continue;
                    }
                // In :goal(speed) code, at a contract-marked add, and on a
                // target that fuses (arm64), only the (x * -2) + c rewrite, and
                // only where the block already adds x + x: the sum is then
                // shared (CSE), so c - (x + x) is one subtract where the product
                // and the add were two (or one fused, where a select's arm did
                // not take the add away: #22), and nothing is lost. Contract allows the unfused evaluation,
                // and c - (x + x) is that exactly. C perlin's gradient, whose
                // `0.0f - 2.0f * v` arm sits beside a `2.0f * v` (#24).
                bool sharedOnly = !mulOk || contract;
                if (sharedOnly && !_srShared)
                    continue;
                if (n.op().equals(String.withCString("FMul")) && !sharedOnly)
                    {
                    // x * 2 (either side) -> x + x
                    IROperand* x = (IROperand*)0;
                    if (srfIsConst(defOf, c, ty, "4000000000000000"))
                        x = a;
                    else if (srfIsConst(defOf, a, ty, "4000000000000000"))
                        x = c;
                    if (x == (IROperand*)0)
                        continue;
                    srfRetag(fn, n, "FAdd", x, x);
                    changed = true;
                    continue;
                    }
                if (n.op().equals(String.withCString("FAdd")))
                    {
                    // (x * -2) + c, either side, the product read only here
                    for (u32 side = (u32)0; side < (u32)2; side = side + (u32)1)
                        {
                        IROperand* p = side == (u32)0 ? a : c;
                        IROperand* o = side == (u32)0 ? c : a;
                        if (p.kind() != (u8)OPK_USE || p.val() == (IRValue*)0)
                            continue;
                        if (o.kind() == (u8)OPK_USE && o.val() == p.val())
                            continue;
                        IRInsn* d = (IRInsn*)defOf.get((Hashable*)p.val());
                        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("FMul")) || d.ops().count() != (u32)2
                            || d.pred() != (String*)0 || d.res() == (IRValue*)0 || !d.res().ty().equals(ty))
                            continue;
                        Array* du = (Array*)uses.get((Hashable*)p.val());
                        if (du == (Array*)0 || du.count() != (u32)1)
                            continue;
                        IROperand* d0 = (IROperand*)d.ops().get((u32)0);
                        IROperand* d1 = (IROperand*)d.ops().get((u32)1);
                        IROperand* x = (IROperand*)0;
                        if (srfIsConst(defOf, d1, ty, "C000000000000000"))
                            x = d0;
                        else if (srfIsConst(defOf, d0, ty, "C000000000000000"))
                            x = d1;
                        if (x == (IROperand*)0)
                            continue;
                        IRInsn* tw = (IRInsn*)0;
                        if (sharedOnly)
                            {
                            tw = srfTwiceIn(bb, x, ty, defOf, uses);
                            if (tw == (IRInsn*)0)
                                continue;
                            if (tw.op().equals(String.withCString("FMul")))
                                srfRetag(fn, tw, "FAdd", x, x);
                            }
                        srfRetag(fn, d, "FAdd", x, x);
                        srfRetag(fn, n, "FSub", o, p);
                        changed = true;
                        side = (u32)2;
                        }
                    }
                }
            }
        return changed;
        }

    // The 2x of x in bb that the -2 rewrite can share: an exact x + x, or an
    // x * 2 that no add reads (so it fuses with nothing), which becomes x + x
    // with it. 0 when there is neither.
    final IRInsn* srfTwiceIn(IRBlock* bb, IROperand* x, String* ty, Map* defOf, Map* uses)
        {
        if (x.kind() != (u8)OPK_USE || x.val() == (IRValue*)0)
            return (IRInsn*)0;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* t = (IRInsn*)bb.insns().get(i);
            if (t.pred() != (String*)0 || t.ops().count() != (u32)2 || t.res() == (IRValue*)0 || !t.res().ty().equals(ty))
                continue;
            IROperand* t0 = (IROperand*)t.ops().get((u32)0);
            IROperand* t1 = (IROperand*)t.ops().get((u32)1);
            if (t.op().equals(String.withCString("FAdd")))
                {
                if (t0.kind() == (u8)OPK_USE && t1.kind() == (u8)OPK_USE && t0.val() == x.val() && t1.val() == x.val())
                    return t;
                continue;
                }
            if (!t.op().equals(String.withCString("FMul")))
                continue;
            bool isX = (t0.kind() == (u8)OPK_USE && t0.val() == x.val() && srfIsConst(defOf, t1, ty, "4000000000000000"))
                       || (t1.kind() == (u8)OPK_USE && t1.val() == x.val() && srfIsConst(defOf, t0, ty, "4000000000000000"));
            if (!isX)
                continue;
            Array* tu = (Array*)uses.get((Hashable*)t.res());
            bool fuses = false;
            for (u32 j = (u32)0; tu != (Array*)0 && j < tu.count(); j = j + (u32)1)
                {
                String* uo = ((IRInsn*)tu.get(j)).op();
                if (uo.equals(String.withCString("FAdd")) || uo.equals(String.withCString("FSub")))
                    fuses = true;
                }
            if (!fuses)
                return t;
            }
        return (IRInsn*)0;
        }

    final void srfNote(Map* uses, IRInsn* n)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            Array* l = (Array*)uses.get((Hashable*)o.val());
            if (l == (Array*)0)
                {
                l = new Array();
                uses.set((Hashable*)o.val(), (Object*)l);
                }
            l.add((Object*)n);
            }
        }

    // The Const defining o, when it is a float immediate of type ty.
    final IRInsn* srfConstOf(Map* defOf, IROperand* o, String* ty)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || !o.val().ty().equals(ty))
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1)
            return (IRInsn*)0;
        IROperand* k = (IROperand*)d.ops().get((u32)0);
        if (k.kind() != (u8)OPK_IMMF || k.fpHex() == (String*)0 || k.fpHex().byteLength() != (u32)16)
            return (IRInsn*)0;
        return d;
        }

    // Compared as BITS: a constant's hex is lowercase from the reference's
    // text and uppercase from clang's, and the reference compares the bits.
    final bool srfIsConst(Map* defOf, IROperand* o, String* ty, u8* hex)
        {
        IRInsn* d = srfConstOf(defOf, o, ty);
        if (d == (IRInsn*)0)
            return false;
        u64 a = (u64)0;
        u64 b = (u64)0;
        return srfBits(((IROperand*)d.ops().get((u32)0)).fpHex(), &a) && srfBits(String.withCString(hex), &b) && a == b;
        }

    // A double's bits from its 16 hex digits, either case.
    final bool srfBits(String* hex, u64* out)
        {
        if (hex == (String*)0 || hex.byteLength() != (u32)16)
            return false;
        u64 bits = (u64)0;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            u8 ch = hex.byteAt(i);
            u64 v = (u64)0;
            if (ch >= (u8)48 && ch <= (u8)57)
                v = (u64)(ch - (u8)48);
            else if (ch >= (u8)65 && ch <= (u8)70)
                v = (u64)(ch - (u8)55);
            else if (ch >= (u8)97 && ch <= (u8)102)
                v = (u64)(ch - (u8)87);
            else
                return false;
            bits = (bits << (u64)4) | v;
            }
        *out = bits;
        return true;
        }

    // The bits of 1/c when c (a double's bits, in hex) is ±2^e and 1/c is a
    // normal number of the type, else 0.
    final String* srfRecipHex(String* hex, bool f32)
        {
        u64 bits = (u64)0;
        if (!srfBits(hex, &bits))
            return (String*)0;
        if ((bits & (u64)$FFFFFFFFFFFFF) != (u64)0)
            return (String*)0;
        i64 ex = (i64)((bits >> (u64)52) & (u64)$7FF);
        if (ex == (i64)0 || ex == (i64)$7FF)
            return (String*)0;
        i64 e = ex - (i64)1023;   // c = ±2^e, 1/c = ±2^-e
        i64 lo = f32 ? (i64)-126 : (i64)-1022;
        i64 hi = f32 ? (i64)127 : (i64)1023;
        if (-e < lo || -e > hi || e < lo || e > hi)
            return (String*)0;
        u64 r = (bits & ((u64)1 << (u64)63)) | ((u64)((i64)1023 - e) << (u64)52);
        // Lowercase, as the reference prints a constant's bits.
        string digits = "0123456789abcdef";
        String* out = String.withCString("");
        for (i32 sh = (i32)60; sh >= (i32)0; sh = sh - (i32)4)
            out.appendByte(digits[(u32)((r >> (u64)sh) & (u64)$F)]);
        return out;
        }

    // Replace n, wherever it sits, by `op` over the given operands (its own,
    // when both are 0), keeping its result and location.
    final void srfRetag(IRFunc* fn, IRInsn* n, u8* op, IROperand* x, IROperand* y)
        {
        IRInsn* r = IRInsn.with(String.withCString(op));
        r.copyDbg(n);
        r.setRes(n.res());
        r.add(x != (IROperand*)0 ? x : (IROperand*)n.ops().get((u32)0));
        r.add(y != (IROperand*)0 ? y : (IROperand*)n.ops().get((u32)1));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if ((IRInsn*)bb.insns().get(i) == n)
                    {
                    bb.insns().set(i, (Object*)r);
                    return;
                    }
            }
        }

    final IRInsn* srBinImm(IRInsn* n, String* newOp, IROperand* xop,
                     i64 imm, bool isU, String* immTy)
        {
        IRInsn* r = IRInsn.with(newOp);
        r.copyDbg(n);
        r.setRes(n.res());
        r.add(xop);
        r.add(mkImm(imm, isU, immTy));
        return r;
        }

    // An integer immediate that prints the way the one it came from printed —
    // `%lu` for bits that read unsigned, `%ld` otherwise. Rebuilding a folded
    // constant without this turns `#2246822519:U32` into `#-2048144777:U32`.
    final IROperand* mkImm(i64 v, bool isU, String* ty)
        {
        return isU ? IROperand.immU64((u64)v, ty) : IROperand.immI(v, ty);
        }

    final IRInsn* srConstZero(IRInsn* n, String* rt)
        {
        IRInsn* r = IRInsn.with(String.withCString("Const"));
        r.copyDbg(n);
        r.setRes(n.res());
        r.add(IROperand.immI((i32)0, rt));
        return r;
        }

    // log2(n) when n is a positive power of two, else -1.
    final i32 srLog2Pow2(i64 n)
        {
        if (n <= (i64)0)
            return (i32)-1;
        u64 u = (u64)n;
        if ((u & (u - (u64)1)) != (u64)0)
            return (i32)-1;
        i32 k = (i32)0;
        while ((u >> (u64)k) != (u64)1)
            k = k + (i32)1;
        return k;
        }

    // Byte width of a scalar type spelling. Wider than irWidth (which the
    // narrower needs kept as it is) because a Mul result can be 64-bit.
    final u32 srWidth(String* t)
        {
        if (t == (String*)0)
            return (u32)0;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")))
            return (u32)8;
        return self.irWidth(t);
        }

    // ── const-operand-fold ───────────────────────────────────────────────
    //
    // Fold a constant RHS into an immediate, so the backend emits `ADC #k` /
    // `CMP #k` / `imul r,r,#k` directly instead of materialising the constant
    // into a register or slot and loading it back. Every backend's operand
    // loader already accepts an ImmI here.
    final void constOperandFold(IRModule* m)
        {
        // To a fixed point: evaluating a constant pair turns an instruction
        // into a Const, which the next round can then fold into its consumer
        // as an immediate. One round leaves `mov w16,#160; add w16,w16,w11`
        // where two give `add w16,w11,#160`.
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 round = (u32)0;
            while (round < (u32)8 && cofInFunc(fn))
                round = round + (u32)1;
            }
        }

    // Integer width and signedness of a scalar type spelling. Exactly the
    // eight kinds the original's XTIRTypeKindIsInteger accepts, minus the two
    // 64-bit ones — see the note on cofEvalPair.
    final bool cofIntBits(String* t, u32* bits, bool* sgn)
        {
        if (t == (String*)0)
            return false;
        if (t.equals(String.withCString("I8")))  { *bits = (u32)8;  *sgn = true;  return true; }
        if (t.equals(String.withCString("U8")))  { *bits = (u32)8;  *sgn = false; return true; }
        if (t.equals(String.withCString("I16"))) { *bits = (u32)16; *sgn = true;  return true; }
        if (t.equals(String.withCString("U16"))) { *bits = (u32)16; *sgn = false; return true; }
        if (t.equals(String.withCString("I32"))) { *bits = (u32)32; *sgn = true;  return true; }
        if (t.equals(String.withCString("U32"))) { *bits = (u32)32; *sgn = false; return true; }
        return false;
        }

    // Both operands known: evaluate the operation at compile time, in the
    // RESULT's width and signedness. False for anything not decidable here —
    // a division (the divisor may be zero), a shift past the width, a type
    // wider than 32 bits (a wide unsigned immediate is spelled differently by
    // the two compilers, and this fold never fires on one in a hot loop).
    final bool cofEvalPair(String* op, i64 a, i64 b, String* rty, i64* out)
        {
        u32 bits = (u32)0;
        bool sgn = false;
        if (!cofIntBits(rty, &bits, &sgn))
            return false;
        u64 mask = ((u64)1 << (u64)bits) - (u64)1;
        u64 ua = (u64)a & mask;
        u64 ub = (u64)b & mask;
        u64 r = (u64)0;
        if (op.equals(String.withCString("Add")))
            r = ua + ub;
        else if (op.equals(String.withCString("Sub")))
            r = ua - ub;
        else if (op.equals(String.withCString("And")))
            r = ua & ub;
        else if (op.equals(String.withCString("Or")))
            r = ua | ub;
        else if (op.equals(String.withCString("Xor")))
            r = ua ^ ub;
        else if (op.equals(String.withCString("Mul")))
            r = ua * ub;
        else if (op.equals(String.withCString("Shl")))
            {
            if (b < (i64)0 || (u64)b >= (u64)bits)
                return false;
            r = ua << (u64)b;
            }
        else if (op.equals(String.withCString("LShr")))
            {
            if (b < (i64)0 || (u64)b >= (u64)bits)
                return false;
            r = ua >> (u64)b;
            }
        else if (op.equals(String.withCString("AShr")))
            {
            if (b < (i64)0 || (u64)b >= (u64)bits)
                return false;
            i64 sa = (i64)ua;
            if ((ua & ((u64)1 << (u64)(bits - (u32)1))) != (u64)0)
                sa = (i64)(ua | ~mask);
            r = (u64)(sa >> (i64)b);
            }
        else
            return false;
        r = r & mask;
        if (sgn && (r & ((u64)1 << (u64)(bits - (u32)1))) != (u64)0)
            *out = (i64)(r | ~mask);
        else
            *out = (i64)r;
        return true;
        }

    // Add, Mul and the bitwise ops do not care which side a constant is on,
    // but the immediate fold only looks at the RHS. Canonicalising puts the
    // constant where it can be used.
    final bool cofCommutative(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Mul"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor"));
        }

    final bool cofInFunc(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        bool changed = false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!cofFoldable(n.op()) || n.ops().count() < (u32)2)
                    continue;
                IROperand* lhs = (IROperand*)n.ops().get((u32)0);
                IROperand* rhs = (IROperand*)n.ops().get((u32)1);

                // Both sides constant: evaluate it. The unrollers substitute
                // the induction variable with a literal, so a fully unrolled
                // body is full of `Const k` feeding an arithmetic op on
                // another constant.
                i64 lk = (i64)0;
                bool lku = false;
                bool haveL = false;
                if (lhs.kind() == (u8)OPK_IMMI)
                    { lk = lhs.imm(); haveL = true; }
                else if (lhs.kind() == (u8)OPK_USE)
                    haveL = cofConst(defOf, lhs.val(), &lk, &lku);
                i64 rk = (i64)0;
                bool rku = false;
                bool haveR = false;
                if (rhs.kind() == (u8)OPK_IMMI)
                    { rk = rhs.imm(); haveR = true; }
                else if (rhs.kind() == (u8)OPK_USE)
                    haveR = cofConst(defOf, rhs.val(), &rk, &rku);

                i64 folded = (i64)0;
                if (haveL && haveR && n.res() != (IRValue*)0
                    && cofEvalPair(n.op(), lk, rk, n.res().ty(), &folded))
                    {
                    IRInsn* c = IRInsn.with(String.withCString("Const"));
                    c.copyDbg(n);
                    c.setRes(n.res());
                    c.setMemRes(n.memRes());
                    c.add(IROperand.immI(folded, n.res().ty()));
                    bb.insns().set(i, (Object*)c);
                    changed = true;
                    continue;
                    }
                // Constant on the left of a commutative op: swap it to the
                // right, where the immediate fold can see it.
                if (haveL && !haveR && cofCommutative(n.op())
                    && lhs.kind() == (u8)OPK_USE && rhs.kind() == (u8)OPK_USE)
                    {
                    n.ops().set((u32)0, (Object*)rhs);
                    n.ops().set((u32)1, (Object*)lhs);
                    IROperand* t = lhs;
                    lhs = rhs;
                    rhs = t;
                    rk = lk;
                    rku = lku;
                    haveR = true;
                    changed = true;
                    }

                if (rhs.kind() != (u8)OPK_USE)
                    continue;
                i64 k = rk;
                bool ku = rku;
                if (!haveR)
                    continue;
                String* immTy = rhs.val().ty();
                if (immTy == (String*)0)
                    continue;
                n.ops().set((u32)1, (Object*)mkImm(k, ku, immTy));
                changed = true;
                }
            }
        if (!changed)
            return false;
        // Dead-strip the Const / ZExt / SExt / Trunc the fold detached, to a
        // fixpoint — removing a ZExt can orphan the Const behind it.
        //
        // NOT srSweepDead: that uses the broad pure set (Add, Mul, And, shifts,
        // AddrOf…) and so cascades into arithmetic the original's sweep leaves
        // alone. Harmless while the fold only orphaned conversions, but once it
        // follows Trunc the chains run deeper, and the two compilers then
        // number IR values differently — invisible on arm64, where registers
        // are allocated, and 793/793 differing on wasm32, whose locals are
        // named straight from value ids.
        cofSweepDead(fn);
        return true;
        }

    // The fold's own dead-strip: exactly the four opcodes the original's sweep
    // considers, so both compilers orphan and remove the same instructions.
    final void cofSweepDead(IRFunc* fn)
        {
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* used = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.phis().get(k));
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.insns().get(k));
                if (bb.term() != (IRInsn*)0)
                    srNoteUses(used, bb.term());
                }
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i - (u32)1);
                    String* o = n.op();
                    bool pure = o.equals(String.withCString("Const"))
                             || o.equals(String.withCString("ZExt"))
                             || o.equals(String.withCString("SExt"))
                             || o.equals(String.withCString("Trunc"));
                    if (!pure)
                        continue;
                    if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
                        continue;
                    if (used.get((Hashable*)n.res()) != (Object*)0)
                        continue;
                    bb.insns().removeAt(i - (u32)1);
                    removed = true;
                    }
                }
            }
        }

    final bool cofFoldable(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem"));
        }

    // A compile-time integer through ZExt / SExt / Trunc of a Const.
    //
    // A TRUNC narrows the value, so each one is re-applied to the constant
    // afterwards (innermost first) in its own width and signedness. Without
    // this a narrowed literal never folds — which is what a shift count is,
    // since lowering gives the count its own narrow type — and the back end
    // then materialises the constant, homes it to a frame slot and extends it
    // before a shift the hardware takes as an immediate.
    final bool cofConst(Map* defOf, IRValue* v, i64* out, bool* isU)
        {
        IRValue* cur = v;
        Array* truncBits = new Array();     // outermost first; negative = signed
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                i64 val = k.imm();
                u32 ti = truncBits.count();
                while (ti > (u32)0)
                    {
                    ti = ti - (u32)1;
                    i32 spec = ((Number*)truncBits.get(ti)).asI32();
                    i32 bits = spec < (i32)0 ? -spec : spec;
                    if (bits > (i32)0 && bits < (i32)64)
                        {
                        u64 mask = ((u64)1 << (u64)bits) - (u64)1;
                        u64 uv = (u64)val & mask;
                        if (spec < (i32)0
                         && (uv & ((u64)1 << (u64)(bits - (i32)1))) != (u64)0)
                            val = (i64)(uv | ~mask);
                        else
                            val = (i64)uv;
                        }
                    }
                out[0] = val;
                isU[0] = k.uimm();
                return true;
                }
            if (def.op().equals(String.withCString("Trunc")))
                {
                if (def.res() == (IRValue*)0 || def.ops().count() < (u32)1)
                    return false;
                String* rt = def.res().ty();
                u32 w = self.irWidth(rt);
                if (w == (u32)0 || w > (u32)8)
                    return false;
                i32 bits = (i32)((i32)w * (i32)8);
                bool sgn = rt.hasPrefix(String.withCString("I"));
                truncBits.add((Object*)Number.with(sgn ? -bits : bits));
                IROperand* tsrc = (IROperand*)def.ops().get((u32)0);
                if (tsrc.kind() != (u8)OPK_USE)
                    return false;
                cur = tsrc.val();
                continue;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    // A compile-time integer, through the widened-literal form.
    final bool srConst(Map* defOf, IROperand* op, i64* out, bool* isU)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            isU[0] = op.uimm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                isU[0] = k.uimm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }
    }
