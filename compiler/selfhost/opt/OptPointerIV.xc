// OptPointerIV.xc — the PointerIV pass, ported from src/xtc/ir/XTIROptPointerIV.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (PointerIV)
    {

    // ── pointer-iv ───────────────────────────────────────────────────────
    //
    // Loop array addressing becomes an advancing pointer. `a[i]` inside a
    // counted loop is an ElementAddr recomputed from the induction variable
    // every iteration; this replaces it with a pointer phi stepped by the
    // loop's constant stride, so the body loads through `(p)` and adds the
    // step once. The variable-trip unroller then threads each pointer phi
    // through the copies, and no copy recomputes an address at all.
    //
    // Off on the 6502: its ZP walking pointer plus the per-iteration advance
    // costs more than the index arithmetic it would replace.
    final void pointerIV(IRModule* m)
        {
        if (!_profile.pointerIV())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop per scan; repeat until nothing more rewrites (a
            // function may hold several independent loops).
            u32 iter = (u32)0;
            while (iter < (u32)64 && pivOnce(fn))
                iter = iter + (u32)1;
            }
        }

    final bool pivOnce(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)p.res(), (Object*)p);
                defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)n.res(), (Object*)n);
                defBlk.set((Hashable*)n.res(), (Object*)bb);
                }
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            if (pivLoop(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk))
                return true;
        return false;
        }

    final bool pivLoop(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (!pivShape(fn, H, defOf, defBlk))
            return false;
        IRInsn* ivPhi = _pivIvPhi;
        IRBlock* B = _pivLatch;
        IRBlock* PH = _pivPre;
        IRValue* iv = ivPhi.res();

        // Loop-invariant-base ElementAddrs at affine-iv indices, grouped by
        // base. Insertion order, NOT hash order: the original walks an
        // NSDictionary here and the group order decides which pointer phi is
        // emitted first, so a dictionary would make the printed IR depend on
        // hashing. First appearance scanning the body is the stable choice.
        Array* bases = new Array();  // IRValue@
        Array* groups = new Array(); // Array@ of [IRInsn@, offset]
        Array* shapes = new Array(); // per group: Number s, hasInv, invScale, and the inv (or base)
        _pivInvs = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (!n.op().equals(String.withCString("ElementAddr")) || n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                continue;
            IROperand* baseOp = (IROperand*)n.ops().get((u32)0);
            IROperand* idxOp = (IROperand*)n.ops().get((u32)1);
            if (baseOp.kind() != (u8)OPK_USE || idxOp.kind() != (u8)OPK_USE)
                continue;
            if (!pivInvariantBase(baseOp.val(), H, B, defOf, defBlk))
                continue;
            if (baseOp.val().ty() == (String*)0 || !baseOp.val().ty().hasPrefix(String.withCString("Ptr(")))
                continue;
            i32 off = (i32)0;
            i64 af[5];
            af[0] = (i64)1; af[1] = (i64)0; af[2] = (i64)0; af[3] = (i64)0; af[4] = (i64)0;
            if (pivAffine(idxOp.val(), iv, defOf, &off, (u32)0))
                af[1] = (i64)off;
            else if (!pivAffIdx(idxOp, iv, defOf, defBlk, H, B, af, (u32)0)
                     || af[0] <= (i64)0 || af[0] * (i64)_pivStep > (i64)65536)
                continue;
            if (af[1] < (i64)0)
                continue;
            IRValue* inv = af[2] != (i64)0 ? (IRValue*)_pivInvs.get((u32)af[4]) : (IRValue*)0;
            u32 gi = pivGroupOf(bases, shapes, baseOp.val(), af, inv);
            if (gi == bases.count())
                {
                bases.add((Object*)baseOp.val());
                groups.add((Object*)new Array());
                Array* sh = new Array();
                sh.add((Object*)Number.withI64(af[0]));
                sh.add((Object*)Number.withI64(af[2]));
                sh.add((Object*)Number.withI64(af[3]));
                sh.add(inv != (IRValue*)0 ? (Object*)inv : (Object*)baseOp.val());
                shapes.add((Object*)sh);
                }
            Array* g = (Array*)groups.get(gi);
            g.add((Object*)n);
            g.add((Object*)Number.withI32((i32)af[1]));
            }
        if (bases.count() == (u32)0)
            return false;
        // Over the cap below, keep only the plain stride-1 groups: a strided or
        // offset access must not cost a loop the pointers it already had.
        if (bases.count() > (u32)3)
            {
            u32 k = bases.count();
            while (k > (u32)0)
                {
                k = k - (u32)1;
                Array* sh = (Array*)shapes.get(k);
                if (((Number*)sh.get((u32)0)).asI64() != (i64)1 || ((Number*)sh.get((u32)1)).asI64() != (i64)0)
                    {
                    bases.removeAt(k);
                    groups.removeAt(k);
                    shapes.removeAt(k);
                    }
                }
            if (bases.count() == (u32)0)
                return false;
            }
        // Register-pressure cap. Each base becomes a loop-carried pointer phi
        // that the unroller threads through every copy — roughly two live
        // values apiece, against a nine-register callee-saved home pool.
        //
        // Re-measured 2026-09-18, best of five at -O3:
        //
        //   cap   array_map   mem_copy   struct_copy   matrix_mul   sieve
        //    2      15392       8253        16379        10082      32689
        //    3      12480       8138        16397         9996      32184
        //    4      12658       8548        15427        10005      33221
        //
        // 3 is the sweet spot, and 2 was leaving a fifth of array_map on the
        // table: it reads a[i] and b[i] and writes c[i], so THREE bases, and at
        // a cap of 2 the loop recomputed `base + i*4` three times per vector and
        // spilled the store address, there being only one address scratch.
        // 4 is only slightly worse than 3, so this is a tuning parameter and
        // not a cliff. Re-measure before moving it.
        if (bases.count() > (u32)3)
            return false;

        // Where the induction variable STARTS — the iv phi's preheader incoming.
        // The pointer phi must begin at `base + ivInit`, not at `base`.
        IROperand* pivInit = (IROperand*)0;
        if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == B)
            {
            pivInit = (IROperand*)ivPhi.ops().get((u32)3);
            }
        else
            {
            pivInit = (IROperand*)ivPhi.ops().get((u32)1);
            }
        pivRewrite(fn, H, B, PH, ivPhi.res().ty(), bases, groups, shapes, defOf, pivInit);
        return true;
        }

    final u32 pivGroupOf(Array* bases, Array* shapes, IRValue* base, i64* af, IRValue* inv)
        {
        for (u32 k = (u32)0; k < bases.count(); k = k + (u32)1)
            {
            if ((IRValue*)bases.get(k) != base)
                continue;
            Array* sh = (Array*)shapes.get(k);
            if (((Number*)sh.get((u32)0)).asI64() != af[0] || ((Number*)sh.get((u32)1)).asI64() != af[2]
                || ((Number*)sh.get((u32)2)).asI64() != af[3])
                continue;
            if (af[2] != (i64)0 && (IRValue*)sh.get((u32)3) != inv)
                continue;
            return k;
            }
        return bases.count();
        }

    // An immediate, or a Const (seen through one ZExt) that is not negative.
    final bool pivConstZ(Map* defOf, IROperand* o, i64* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = (i64)o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE)
            return false;
        Object* dd = defOf.get((Hashable*)o.val());
        if (dd == (Object*)0)
            return false;
        IRInsn* d = (IRInsn*)dd;
        if (d.op().equals(String.withCString("ZExt")) && d.ops().count() >= (u32)1
            && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            {
            Object* d2 = defOf.get((Hashable*)((IROperand*)d.ops().get((u32)0)).val());
            if (d2 == (Object*)0)
                return false;
            d = (IRInsn*)d2;
            }
        if (!d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1)
            return false;
        IROperand* k = (IROperand*)d.ops().get((u32)0);
        if (k.kind() != (u8)OPK_IMMI || k.imm() < (i32)0)
            return false;
        out[0] = (i64)k.imm();
        return true;
        }

    // The index as iv*s + inv*invScale + off (the reference explains):
    // r = [s, off, hasInv, invScale, index of inv in _pivInvs].
    final bool pivAffIdx(IROperand* o, IRValue* iv, Map* defOf, Map* defBlk, IRBlock* H, IRBlock* B,
                   i64* r, u32 depth)
        {
        r[0] = (i64)0; r[1] = (i64)0; r[2] = (i64)0; r[3] = (i64)0; r[4] = (i64)0;
        i64 c = (i64)0;
        if (o.kind() == (u8)OPK_USE && o.val() == iv)
            {
            r[0] = (i64)1;
            return true;
            }
        if (pivConstZ(defOf, o, &c))
            {
            r[1] = c;
            return true;
            }
        if (o.kind() != (u8)OPK_USE || depth > (u32)16)
            return false;
        IRValue* v = o.val();
        if (v.ty() == (String*)0 || !v.ty().equals(iv.ty()))
            return false;
        Object* blk = defBlk.get((Hashable*)v);
        Object* dd = defOf.get((Hashable*)v);
        if ((blk == (Object*)0 && dd == (Object*)0)
            || (blk != (Object*)0 && (IRBlock*)blk != H && (IRBlock*)blk != B))
            {
            r[2] = (i64)1;
            r[3] = (i64)1;
            r[4] = (i64)_pivInvs.count();
            _pivInvs.add((Object*)v);
            return true;
            }
        if (dd == (Object*)0)
            return false;
        IRInsn* d = (IRInsn*)dd;
        if (d.ops().count() < (u32)2)
            return false;
        i64 a[5];
        i64 b[5];
        if (d.op().equals(String.withCString("Add")))
            {
            if (!pivAffIdx((IROperand*)d.ops().get((u32)0), iv, defOf, defBlk, H, B, a, depth + (u32)1))
                return false;
            if (!pivAffIdx((IROperand*)d.ops().get((u32)1), iv, defOf, defBlk, H, B, b, depth + (u32)1))
                return false;
            if (a[2] != (i64)0 && b[2] != (i64)0)
                return false;
            r[0] = a[0] + b[0];
            r[1] = a[1] + b[1];
            r[2] = (a[2] != (i64)0 || b[2] != (i64)0) ? (i64)1 : (i64)0;
            r[3] = a[2] != (i64)0 ? a[3] : b[3];
            r[4] = a[2] != (i64)0 ? a[4] : b[4];
            return true;
            }
        i64 k = (i64)0;
        IROperand* x = (IROperand*)0;
        if (d.op().equals(String.withCString("Mul")))
            {
            if (pivConstZ(defOf, (IROperand*)d.ops().get((u32)1), &k))
                x = (IROperand*)d.ops().get((u32)0);
            else if (pivConstZ(defOf, (IROperand*)d.ops().get((u32)0), &k))
                x = (IROperand*)d.ops().get((u32)1);
            }
        else if (d.op().equals(String.withCString("Shl")) && pivConstZ(defOf, (IROperand*)d.ops().get((u32)1), &k)
                 && k >= (i64)0 && k < (i64)31)
            {
            k = (i64)1 << k;
            x = (IROperand*)d.ops().get((u32)0);
            }
        if (x == (IROperand*)0 || k <= (i64)0 || k > (i64)65536)
            return false;
        if (!pivAffIdx(x, iv, defOf, defBlk, H, B, a, depth + (u32)1))
            return false;
        r[0] = a[0] * k;
        r[1] = a[1] * k;
        r[2] = a[2];
        r[3] = a[3] * k;
        r[4] = a[4];
        return true;
        }

    // The header must end in a CondBranch on an ICmp of an integer phi, with a
    // single-block latch branching back to it and a distinct preheader; the
    // phi's back-edge value must be `Add(iv, positive const)` computed in the
    // latch.
    final bool pivShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _pivIvPhi = (IRInsn*)0;
        _pivLatch = (IRBlock*)0;
        _pivPre = (IRBlock*)0;
        _pivStep = (i32)0;
        if (H.phis().count() == (u32)0)
            return false;
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        if (go == (Object*)0)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == iv)
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return false;
        if (!self.isIntType(iv.ty()))
            return false;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = pivIsLatch(t0, H) ? t0 : (pivIsLatch(t1, H) ? t1 : (IRBlock*)0);
        if (B == (IRBlock*)0)
            return false;

        IRBlock* e0 = ((IROperand*)ivPhi.ops().get((u32)0)).blk();
        IRBlock* PH = (e0 == B) ? ((IROperand*)ivPhi.ops().get((u32)2)).blk() : e0;
        if (PH == (IRBlock*)0 || PH == B || PH == H)
            return false;

        IROperand* ivBack = (e0 == B) ? (IROperand*)ivPhi.ops().get((u32)1)
                                      : (IROperand*)ivPhi.ops().get((u32)3);
        if (ivBack.kind() != (u8)OPK_USE)
            return false;
        Object* no = defOf.get((Hashable*)ivBack.val());
        if (no == (Object*)0)
            return false;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")))
            return false;
        Object* nb = defBlk.get((Hashable*)ivBack.val());
        if (nb == (Object*)0 || (IRBlock*)nb != B)
            return false;
        if (ivNext.ops().count() < (u32)2)
            return false;

        // The step may still be a separate `Const` — const-operand-fold runs
        // AFTER this pass, so `i + 1` need not be an inline immediate yet.
        IROperand* a = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* b = (IROperand*)ivNext.ops().get((u32)1);
        i32 step = (i32)0;
        bool have = false;
        if (a.kind() == (u8)OPK_USE && a.val() == iv)
            have = pivConst(defOf, b, &step);
        else if (b.kind() == (u8)OPK_USE && b.val() == iv)
            have = pivConst(defOf, a, &step);
        if (!have || step <= (i32)0)
            return false;

        _pivIvPhi = ivPhi;
        _pivLatch = B;
        _pivPre = PH;
        _pivStep = step;
        return true;
        }

    final bool pivIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b == H || b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    // Loop-invariant base: a parameter (no def site — live from entry), a value
    // defined outside the header and latch, or an `AddrOf @sym` (a constant
    // address, hoisted to the preheader by the rewrite). All three give the
    // pointer phi a preheader incoming that dominates the loop.
    final bool pivInvariantBase(IRValue* base, IRBlock* H, IRBlock* B,
                          Map* defOf, Map* defBlk)
        {
        Object* bBlk = defBlk.get((Hashable*)base);
        Object* bdef = defOf.get((Hashable*)base);
        if (bBlk == (Object*)0 && bdef == (Object*)0)
            return true; // a parameter
        if (bBlk != (Object*)0 && (IRBlock*)bBlk != H && (IRBlock*)bBlk != B)
            return true;
        return bdef != (Object*)0 && ((IRInsn*)bdef).op().equals(String.withCString("AddrOf"));
        }

    // Resolve a value to the induction variable plus a constant element offset:
    // iv itself is 0, `Add(x, const)` is offset(x) + const. False when it is
    // not an affine function of the iv.
    final bool pivAffine(IRValue* v, IRValue* iv, Map* defOf, i32* out, u32 depth)
        {
        if (v == iv)
            {
            out[0] = (i32)0;
            return true;
            }
        if (depth > (u32)16)
            return false;
        Object* o = defOf.get((Hashable*)v);
        if (o == (Object*)0)
            return false;
        IRInsn* d = (IRInsn*)o;
        if (!d.op().equals(String.withCString("Add")) || d.ops().count() < (u32)2)
            return false;
        IROperand* a = (IROperand*)d.ops().get((u32)0);
        IROperand* b = (IROperand*)d.ops().get((u32)1);
        i32 inner = (i32)0;
        i32 c = (i32)0;
        if (a.kind() == (u8)OPK_USE && pivAffine(a.val(), iv, defOf, &inner, depth + (u32)1) && pivConst(defOf, b, &c))
            {
            out[0] = inner + c;
            return true;
            }
        if (b.kind() == (u8)OPK_USE && pivAffine(b.val(), iv, defOf, &inner, depth + (u32)1) && pivConst(defOf, a, &c))
            {
            out[0] = inner + c;
            return true;
            }
        return false;
        }

    // An immediate, or a `Const` instruction's immediate.
    final bool pivConst(Map* defOf, IROperand* o, i32* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE)
            return false;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == (Object*)0)
            return false;
        IRInsn* cd = (IRInsn*)d;
        if (!cd.op().equals(String.withCString("Const")) || cd.ops().count() < (u32)1)
            return false;
        IROperand* k = (IROperand*)cd.ops().get((u32)0);
        if (k.kind() != (u8)OPK_IMMI)
            return false;
        out[0] = k.imm();
        return true;
        }

    // Give each base a pointer phi stepped by the loop's stride, point every
    // grouped ElementAddr at it (directly when the offset is zero, through one
    // small ElementAddr otherwise), and drop the originals.
    // `base + ivInit` in the preheader: the pointer induction variable's true
    // starting address when the loop does not count from zero.
    final IRValue* pivSeed(IRBlock* PH, IRValue* base, String* ptrTy, String* ivTy,
                     IROperand* ivInit, i32 initV)
        {
        IRValue* seed = new IRValue(ptrTy);
        IRInsn* seedInsn = IRInsn.with(String.withCString("ElementAddr"));
        seedInsn.setRes(seed);
        seedInsn.add(IROperand.useVal(base));
        if (ivInit.kind() == (u8)OPK_USE)
            {
            seedInsn.add(IROperand.useVal(ivInit.val()));
            }
        else
            {
            seedInsn.add(IROperand.immI(initV, ivTy));
            }
        PH.insns().add((Object*)seedInsn);
        return seed;
        }

    // base + ivInit*s + inv*invScale, built in the preheader.
    final IRValue* pivSeedAffine(IRBlock* PH, IRValue* base, String* ptrTy, String* ivTy,
                           IROperand* ivInit, i64 initV, bool initZero, Array* shape)
        {
        i64 gs = ((Number*)shape.get((u32)0)).asI64();
        bool hasInv = ((Number*)shape.get((u32)1)).asI64() != (i64)0;
        i64 invScale = ((Number*)shape.get((u32)2)).asI64();
        IRValue* idx = (IRValue*)0;
        if (!initZero)
            {
            IROperand* initOp = ivInit.kind() == (u8)OPK_USE ? IROperand.useVal(ivInit.val())
                                                             : IROperand.immI((i32)initV, ivTy);
            if (gs == (i64)1 && initOp.kind() == (u8)OPK_USE)
                idx = ivInit.val();
            else
                {
                IRValue* m = new IRValue(ivTy);
                IRInsn* mi = IRInsn.with(String.withCString("Mul"));
                mi.setRes(m);
                mi.add(initOp);
                mi.add(IROperand.immI((i32)gs, ivTy));
                PH.insns().add((Object*)mi);
                idx = m;
                }
            }
        if (hasInv)
            {
            IRValue* t = (IRValue*)shape.get((u32)3);
            if (invScale != (i64)1)
                {
                IRValue* m = new IRValue(ivTy);
                IRInsn* mi = IRInsn.with(String.withCString("Mul"));
                mi.setRes(m);
                mi.add(IROperand.useVal(t));
                mi.add(IROperand.immI((i32)invScale, ivTy));
                PH.insns().add((Object*)mi);
                t = m;
                }
            if (idx != (IRValue*)0)
                {
                IRValue* a = new IRValue(ivTy);
                IRInsn* ai = IRInsn.with(String.withCString("Add"));
                ai.setRes(a);
                ai.add(IROperand.useVal(idx));
                ai.add(IROperand.useVal(t));
                PH.insns().add((Object*)ai);
                idx = a;
                }
            else
                idx = t;
            }
        if (idx == (IRValue*)0)
            return base;
        IRValue* seed = new IRValue(ptrTy);
        IRInsn* si = IRInsn.with(String.withCString("ElementAddr"));
        si.setRes(seed);
        si.add(IROperand.useVal(base));
        si.add(IROperand.useVal(idx));
        PH.insns().add((Object*)si);
        return seed;
        }

    final void pivRewrite(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* PH,
                    String* ivTy, Array* bases, Array* groups, Array* shapes, Map* defOf,
                    IROperand* ivInit)
        {
        // Seed the pointer phi at `base + ivInit`, not `base`. Seeding with the
        // bare base is right only when the loop counts from zero, so
        // `for (i = a; ...)` read from the start of the array instead of from
        // `a` — correct at -O0/-O1, wrong at -O2+ (#1125).
        i64 pivInitV = (i64)0;
        bool pivInitZero = self.constValue(defOf, ivInit, &pivInitV) && pivInitV == (i64)0;
        Array* head = new Array();    // pointer steps + offset ElementAddrs
        Array* deadEAs = new Array(); // the originals they replace
        Map* replace = new Map();     // old ElementAddr result → new value

        for (u32 gi = (u32)0; gi < bases.count(); gi = gi + (u32)1)
            {
            IRValue* base = (IRValue*)bases.get(gi);
            String* ptrTy = base.ty();
            Array* shape = (Array*)shapes.get(gi);
            i64 gs = ((Number*)shape.get((u32)0)).asI64();
            bool gHasInv = ((Number*)shape.get((u32)1)).asI64() != (i64)0;

            // A base that is an `AddrOf @sym` defined INSIDE the loop is a
            // constant address, so it moves to the preheader — otherwise the
            // pointer phi's preheader incoming would not dominate the loop.
            Object* bo = defOf.get((Hashable*)base);
            if (bo != (Object*)0 && ((IRInsn*)bo).op().equals(String.withCString("AddrOf")))
                {
                IRInsn* bdef = (IRInsn*)bo;
                bool moved = self.removeInsn(H, bdef);
                if (removeInsn(B, bdef))
                    moved = true;
                if (moved)
                    PH.insns().add((Object*)bdef);
                }

            // p = phi[(PH, base), (B, pNext)];  pNext = ElementAddr(p, step).
            IRValue* p = new IRValue(ptrTy);
            IRValue* pNext = new IRValue(ptrTy);
            IRInsn* stepInsn = IRInsn.with(String.withCString("ElementAddr"));
            stepInsn.setRes(pNext);
            stepInsn.add(IROperand.useVal(p));
            stepInsn.add(IROperand.immI((i32)((i64)_pivStep * gs), ivTy));
            head.add((Object*)stepInsn);

            // `base + ivInit`, materialised in the PREHEADER when the loop does
            // not start at zero. In a HELPER, not inline: pivRewrite is already
            // near the 16 KB arm64 frame budget and these locals push it over.
            IRValue* phIn = base;
            if (gs != (i64)1 || gHasInv)
                {
                phIn = pivSeedAffine(PH, base, ptrTy, ivTy, ivInit, pivInitV, pivInitZero, shape);
                }
            else if (!pivInitZero)
                {
                phIn = pivSeed(PH, base, ptrTy, ivTy, ivInit, pivInitV);
                }

            IRInsn* pPhi = IRInsn.with(String.withCString("Phi"));
            pPhi.setRes(p);
            pPhi.add(IROperand.block(PH));
            pPhi.add(IROperand.useVal(phIn));
            pPhi.add(IROperand.block(B));
            pPhi.add(IROperand.useVal(pNext));
            H.addPhi(pPhi);

            Array* g = (Array*)groups.get(gi);
            for (u32 k = (u32)0; k + (u32)1 < g.count(); k = k + (u32)2)
                {
                IRInsn* E = (IRInsn*)g.get(k);
                i32 off = ((Number*)g.get(k + (u32)1)).asI32();
                if (off == (i32)0)
                    {
                    replace.set((Hashable*)E.res(), (Object*)p);
                    }
                else
                    {
                    IRValue* ea = new IRValue(ptrTy);
                    IRInsn* eaInsn = IRInsn.with(String.withCString("ElementAddr"));
                    eaInsn.setRes(ea);
                    eaInsn.add(IROperand.useVal(p));
                    eaInsn.add(IROperand.immI(off, ivTy));
                    head.add((Object*)eaInsn);
                    replace.set((Hashable*)E.res(), (Object*)ea);
                    }
                deadEAs.add((Object*)E);
                }
            }

        // Rebuild the latch: the pointer steps and offset addresses first (they
        // depend only on the new phis and each other), then the surviving body
        // with the old ElementAddrs dropped.
        Array* nb = new Array();
        for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
            nb.add(head.get(i));
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (hasInsn(deadEAs, n))
                continue;
            nb.add((Object*)n);
            }
        B.setInsns(nb);

        // Every use of a replaced address, across the whole function.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.phis().get(k), replace);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.insns().get(k), replace);
            if (bb.term() != (IRInsn*)0)
                self.pivReplaceIn(bb.term(), replace);
            }
        }
    }
