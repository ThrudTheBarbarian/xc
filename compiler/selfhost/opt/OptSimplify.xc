// OptSimplify.xc — the Simplify pass, ported from src/xtc/ir/XTIROptSimplify.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptRedundantLoadCSE>
#import <OptStrengthReduce>

    class Opt (Simplify)
    {
    // ── simplify ─────────────────────────────────────────────────────────
    //
    // Integer arithmetic of constants folded, and the identities dropped:
    // x+0, 0+x, x-0, x*1, 1*x, x|0, 0|x, x^0, 0^x, x&~0, ~0&x and shifts by 0
    // are x; x*0, 0*x, x&0, 0&x are 0. Folding is for the 8- to 32-bit types,
    // the result wrapped to its width (unsigned in [0, 2^w), signed sign-
    // extended), so the two compilers spell a constant alike; the identities
    // hold at every width. Floats are untouched. A use-rewrite forwards x to
    // the replaced value's users; what is left dead the dead-code pass takes.
    // Then each tree of one associative integer op (Add, Xor, And, Or) in a
    // block is rebuilt shallowest-first, when that makes it shallower: md5's
    // `((a + f) + m) + k` waits on f three times and becomes `f + (a + (m +
    // k))`, whose m + k LICM hoists. A phi's value counts as deepest, so the
    // value a loop carries is added last.
    // As the reference's XTIROptSimplify.
    final void simplify(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            simplifyFn((IRFunc*)m.funcs().get(f));
            simpStrictFn((IRFunc*)m.funcs().get(f));
            simpMaskFn((IRFunc*)m.funcs().get(f));
            simpBalanceFn((IRFunc*)m.funcs().get(f));
            }
        }

    // `x <= K` for a constant K becomes `x < K + 1` where K + 1 fits (8 to 32
    // bits): the loop passes read a bound with `<` (an inclusive range,
    // `0...N - 1`, once folded, is `i <= 199999`; the vectoriser's
    // constant-trip path took it as 199999 trips).
    final void simpStrictFn(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Map* repl = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("ICmp")) || n.pred() == (String*)0 || n.ops().count() != (u32)2)
                    continue;
                bool ule = n.pred().equals(String.withCString("ULE"));
                bool sle = n.pred().equals(String.withCString("SLE"));
                if (!ule && !sle)
                    continue;
                IROperand* c = (IROperand*)n.ops().get((u32)1);
                String* t = c.kind() == (u8)OPK_USE && c.val() != (IRValue*)0 ? c.val().ty() : c.ty();
                if (!simpIntTy(t) || self.irWidth(t) > (u32)4)
                    continue;
                if (ule != t.hasPrefix(String.withCString("U")))
                    continue;
                i64 k = (i64)0;
                if (!simpConst(c, defOf, repl, &k))
                    continue;
                u32 bits = self.irWidth(t) * (u32)8;
                i64 kw = (i64)0;
                i64 top = (i64)0;
                if (ule)
                    {
                    kw = k & (((i64)1 << (i64)bits) - (i64)1);
                    top = ((i64)1 << (i64)bits) - (i64)1;
                    }
                else
                    {
                    kw = simpWrap(k, t);
                    top = ((i64)1 << (i64)(bits - (u32)1)) - (i64)1;
                    }
                if (kw >= top)
                    continue;
                IRValue* kv = new IRValue(t);
                IRInsn* kc = IRInsn.with(String.withCString("Const"));
                kc.copyDbg(n);
                kc.setRes(kv);
                kc.add(IROperand.immI(simpWrap(kw + (i64)1, t), t));
                n.setPred(String.withCString(ule ? "ULT" : "SLT"));
                n.ops().set((u32)1, (Object*)IROperand.useVal(kv));
                bb.insns().insert(i, (Object*)kc);
                defOf.set((Hashable*)kv, (Object*)kc);
                i = i + (u32)1;
                }
            }
        }

    // Masks: `(x & C1) & C2` is `x & (C1 & C2)`, and `(x & M) <u 2^k` is
    // `(x & (M with the bits below 2^k cleared)) == 0` (`>=u`: `!= 0`), one
    // bit test (8 to 32 bits). perlin's grad() reads `h & 7` as `g < 4`,
    // `g & 1` and `g & 2`: they become h & 4, h & 1 and h & 2, and `h & 7`
    // is dead.
    final void simpMaskFn(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Map* repl = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                bool band = n.op().equals(String.withCString("And"));
                bool icmp = n.op().equals(String.withCString("ICmp")) && n.pred() != (String*)0;
                bool ult = icmp && n.pred().equals(String.withCString("ULT"));
                bool uge = icmp && n.pred().equals(String.withCString("UGE"));
                if ((!band && !ult && !uge) || n.ops().count() != (u32)2)
                    continue;
                IROperand* a = (IROperand*)n.ops().get((u32)0);
                if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
                    continue;
                String* t = a.val().ty();
                if (!simpIntTy(t) || self.irWidth(t) > (u32)4)
                    continue;
                i64 k = (i64)0;
                if (!simpConst((IROperand*)n.ops().get((u32)1), defOf, repl, &k))
                    continue;
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)a.val());
                if (d == (IRInsn*)0 || !d.op().equals(String.withCString("And")) || d.ops().count() != (u32)2)
                    continue;
                IROperand* d0 = (IROperand*)d.ops().get((u32)0);
                if (d0.kind() != (u8)OPK_USE || d0.val() == (IRValue*)0)
                    continue;
                i64 m = (i64)0;
                if (!simpConst((IROperand*)d.ops().get((u32)1), defOf, repl, &m))
                    continue;
                IRValue* xv = d0.val();
                if (!xv.ty().equals(t))
                    continue;
                u32 bits = self.irWidth(t) * (u32)8;
                i64 wmask = ((i64)1 << (i64)bits) - (i64)1;
                m = m & wmask;
                k = k & wmask;
                if (band)
                    {
                    n.ops().set((u32)0, (Object*)IROperand.useVal(xv));
                    n.ops().set((u32)1, (Object*)IROperand.immI(simpWrap(m & k, t), t));
                    continue;
                    }
                if (k == (i64)0 || (k & (k - (i64)1)) != (i64)0)
                    continue;
                i64 mk = m & ~(k - (i64)1);
                if (mk == (i64)0)
                    continue;
                IRValue* av = new IRValue(t);
                IRInsn* na = IRInsn.with(String.withCString("And"));
                na.copyDbg(n);
                na.setRes(av);
                na.add(IROperand.useVal(xv));
                na.add(IROperand.immI(simpWrap(mk, t), t));
                n.setPred(String.withCString(ult ? "EQ" : "NE"));
                n.ops().set((u32)0, (Object*)IROperand.useVal(av));
                n.ops().set((u32)1, (Object*)IROperand.immI((i64)0, t));
                bb.insns().insert(i, (Object*)na);
                defOf.set((Hashable*)av, (Object*)na);
                i = i + (u32)1;
                }
            }
        }

    final bool simpAssoc(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Xor"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"));
        }

    final u32 simpDepthOf(IROperand* o, Map* depth, Map* phiIds)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (u32)0;
        if (phiIds.get((Hashable*)o.val()) != (Object*)0)
            return (u32)1048576;
        Object* d = depth.get((Hashable*)o.val());
        return d == (Object*)0 ? (u32)0 : ((Number*)d).asU32();
        }

    // The leaves of the tree under n, left first, and its interior nodes.
    final void simpLeaves(IRInsn* n, Map* defIn, Map* uses, Array* leaves, Array* inner)
        {
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            IRInsn* d = o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0
                ? (IRInsn*)defIn.get((Hashable*)o.val()) : (IRInsn*)0;
            if (d != (IRInsn*)0 && d.op().equals(n.op()) && d.memRes() == (IRValue*)0 && d.ops().count() == (u32)2
                && d.res().ty() != (String*)0 && d.res().ty().equals(n.res().ty())
                && self.countOf(uses, d.res()) == (u32)1)
                {
                simpLeaves(d, defIn, uses, leaves, inner);
                inner.add((Object*)d);
                }
            else
                leaves.add((Object*)o);
            }
        }

    final void simpBalanceFn(IRFunc* fn)
        {
        Map* uses = self.useCounts(fn);
        Map* phiIds = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    phiIds.set((Hashable*)p.res(), (Object*)p);
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Map* defIn = new Map();
            Map* depth = new Map();
            // Which block value a single-use value feeds, to find the roots.
            Map* userOf = new Map();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        userOf.set((Hashable*)o.val(), (Object*)n);
                    }
                }
            Array* out = new Array();
            bool changed = false;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                IRValue* r = n.res();
                u32 dn = (u32)0;
                if (!n.op().equals(String.withCString("Const")))
                    for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                        {
                        u32 dk = simpDepthOf((IROperand*)n.ops().get(k), depth, phiIds) + (u32)1;
                        if (dk > dn)
                            dn = dk;
                        }
                bool tree = r != (IRValue*)0 && n.memRes() == (IRValue*)0 && n.ops().count() == (u32)2
                    && simpAssoc(n.op()) && simpIntTy(r.ty());
                if (tree)
                    {
                    // A root: not the one use of a like node in this block.
                    IRInsn* u = (IRInsn*)userOf.get((Hashable*)r);
                    if (countOf(uses, r) == (u32)1 && u != (IRInsn*)0 && u.op().equals(n.op())
                        && u.memRes() == (IRValue*)0 && u.res() != (IRValue*)0 && u.res().ty() != (String*)0
                        && u.res().ty().equals(r.ty()))
                        tree = false;
                    }
                Array* leaves = new Array();
                Array* inner = new Array();
                if (tree)
                    {
                    simpLeaves(n, defIn, uses, leaves, inner);
                    tree = leaves.count() >= (u32)3;
                    }
                if (!tree)
                    {
                    out.add((Object*)n);
                    if (r != (IRValue*)0)
                        {
                        defIn.set((Hashable*)r, (Object*)n);
                        depth.set((Hashable*)r, (Object*)Number.with(dn));
                        }
                    continue;
                    }
                // Shallowest two first (the earlier on a tie), until one is
                // left: its depth against the tree's now.
                Array* items = new Array();
                Array* idep = new Array();
                for (u32 k = (u32)0; k < leaves.count(); k = k + (u32)1)
                    {
                    items.add(leaves.get(k));
                    idep.add((Object*)Number.with(simpDepthOf((IROperand*)leaves.get(k), depth, phiIds)));
                    }
                Array* built = new Array();
                while (items.count() > (u32)1)
                    {
                    u32 p0 = (u32)0;
                    for (u32 k = (u32)1; k < items.count(); k = k + (u32)1)
                        if (((Number*)idep.get(k)).asU32() < ((Number*)idep.get(p0)).asU32())
                            p0 = k;
                    IROperand* x = (IROperand*)items.get(p0);
                    u32 dx = ((Number*)idep.get(p0)).asU32();
                    items.removeAt(p0);
                    idep.removeAt(p0);
                    u32 p1 = (u32)0;
                    for (u32 k = (u32)1; k < items.count(); k = k + (u32)1)
                        if (((Number*)idep.get(k)).asU32() < ((Number*)idep.get(p1)).asU32())
                            p1 = k;
                    IROperand* y = (IROperand*)items.get(p1);
                    u32 dy = ((Number*)idep.get(p1)).asU32();
                    items.removeAt(p1);
                    idep.removeAt(p1);
                    IRValue* nv = built.count() < inner.count() ? ((IRInsn*)inner.get(built.count())).res() : r;
                    IRInsn* c = IRInsn.with(n.op());
                    c.copyDbg(n);
                    c.setRes(nv);
                    c.add(x);
                    c.add(y);
                    built.add((Object*)c);
                    u32 dc = (dx > dy ? dx : dy) + (u32)1;
                    items.add((Object*)IROperand.useVal(nv));
                    idep.add((Object*)Number.with(dc));
                    }
                u32 dnew = ((Number*)idep.get((u32)0)).asU32();
                if (dnew >= dn)
                    {
                    out.add((Object*)n);
                    defIn.set((Hashable*)r, (Object*)n);
                    depth.set((Hashable*)r, (Object*)Number.with(dn));
                    continue;
                    }
                // The interior nodes leave their places; the rebuilt tree
                // stands at the root's.
                for (u32 k = (u32)0; k < inner.count(); k = k + (u32)1)
                    {
                    IRInsn* d = (IRInsn*)inner.get(k);
                    for (u32 q = (u32)0; q < out.count(); q = q + (u32)1)
                        if ((IRInsn*)out.get(q) == d)
                            {
                            out.removeAt(q);
                            break;
                            }
                    }
                for (u32 k = (u32)0; k < built.count(); k = k + (u32)1)
                    {
                    IRInsn* c = (IRInsn*)built.get(k);
                    u32 dc = (u32)0;
                    for (u32 q = (u32)0; q < (u32)2; q = q + (u32)1)
                        {
                        u32 dq = simpDepthOf((IROperand*)c.ops().get(q), depth, phiIds) + (u32)1;
                        if (dq > dc)
                            dc = dq;
                        }
                    out.add((Object*)c);
                    defIn.set((Hashable*)c.res(), (Object*)c);
                    depth.set((Hashable*)c.res(), (Object*)Number.with(dc));
                    }
                changed = true;
                }
            if (changed)
                {
                bb.insns().removeAll();
                for (u32 k = (u32)0; k < out.count(); k = k + (u32)1)
                    bb.insns().add(out.get(k));
                }
            }
        }

    final bool simpIntTy(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8"))
            || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"))
            || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
            || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")));
        }

    // v wrapped to t's width (8 to 32 bits).
    final i64 simpWrap(i64 v, String* t)
        {
        u32 bits = self.irWidth(t) * (u32)8;
        i64 span = (i64)1 << (i64)bits;
        i64 r = v & (span - (i64)1);
        if (t.hasPrefix(String.withCString("I")) && r >= span / (i64)2)
            r = r - span;
        return r;
        }

    // An operand's constant value (an immediate, or a Const's), resolved
    // through the replacements made so far.
    final bool simpConst(IROperand* o, Map* defOf, Map* repl, i64* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)self.resolveReplace(repl, o.val()));
        if (d == (IRInsn*)0 || d.ops().count() < (u32)1)
            return false;
        IROperand* d0 = (IROperand*)d.ops().get((u32)0);
        if (d.op().equals(String.withCString("Const")))
            {
            if (d0.kind() != (u8)OPK_IMMI)
                return false;
            out[0] = d0.imm();
            return true;
            }
        // A widened or narrowed constant (a literal the lowering typed
        // narrower): its value under the extension, from a source of 8 to 32
        // bits; the caller wraps to the result's width.
        bool zx = d.op().equals(String.withCString("ZExt"));
        bool sx = d.op().equals(String.withCString("SExt"));
        bool tr = d.op().equals(String.withCString("Trunc"));
        if (!zx && !sx && !tr)
            return false;
        String* st = d0.kind() == (u8)OPK_USE && d0.val() != (IRValue*)0 ? d0.val().ty() : d0.ty();
        if (!simpIntTy(st) || self.irWidth(st) > (u32)4)
            return false;
        i64 k = (i64)0;
        if (!simpConst(d0, defOf, repl, &k))
            return false;
        u32 sbits = self.irWidth(st) * (u32)8;
        i64 smask = ((i64)1 << (i64)sbits) - (i64)1;
        if (zx)
            out[0] = k & smask;
        else if (sx)
            {
            i64 u = k & smask;
            out[0] = u >= ((i64)1 << (i64)(sbits - (u32)1)) ? u - ((i64)1 << (i64)sbits) : u;
            }
        else
            out[0] = k;
        return true;
        }

    // A float operand's constant value: an immediate or a Const's, as a
    // double, resolved through the replacements made so far.
    final bool simpFConst(IROperand* o, Map* defOf, Map* repl, double* out)
        {
        u64 bits = (u64)0;
        String* hex = (String*)0;
        if (o.kind() == (u8)OPK_IMMF)
            hex = o.fpHex();
        else if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
            {
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)self.resolveReplace(repl, o.val()));
            if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1
                || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_IMMF)
                return false;
            hex = ((IROperand*)d.ops().get((u32)0)).fpHex();
            }
        if (!self.srfBits(hex, &bits))
            return false;
        out[0] = *(double*)(pointer)&bits;
        return true;
        }

    // Floats of constants, as the reference's simpFoldFloat: an int-to-float
    // conversion of a constant of up to 32 bits, and FAdd/FSub/FMul/FDiv of
    // two float constants, become a Const computed in the result's own
    // precision; a NaN or infinite result is left alone. 0 when n is none.
    final IRInsn* simpFoldFloat(IRInsn* n, Map* defOf, Map* repl)
        {
        IRValue* r = n.res();
        if (r == (IRValue*)0 || n.memRes() != (IRValue*)0)
            return (IRInsn*)0;
        bool f32 = r.ty().equals(String.withCString("F32"));
        if (!f32 && !r.ty().equals(String.withCString("F64")))
            return (IRInsn*)0;
        String* op = n.op();
        bool ui = op.equals(String.withCString("UIToFp"));
        bool si = op.equals(String.withCString("SIToFp"));
        double v = (double)0;
        if ((ui || si) && n.ops().count() == (u32)1)
            {
            IROperand* a = (IROperand*)n.ops().get((u32)0);
            String* st = a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 ? a.val().ty() : a.ty();
            i64 k = (i64)0;
            if (!simpIntTy(st) || self.irWidth(st) > (u32)4 || !simpConst(a, defOf, repl, &k))
                return (IRInsn*)0;
            u32 sbits = self.irWidth(st) * (u32)8;
            i64 smask = ((i64)1 << (i64)sbits) - (i64)1;
            i64 u = k & smask;
            if (si && u >= ((i64)1 << (i64)(sbits - (u32)1)))
                u = u - ((i64)1 << (i64)sbits);
            if (f32)
                {
                float fv = ui ? (float)(u32)u : (float)(i32)u;
                v = (double)fv;
                }
            else
                v = ui ? (double)(u32)u : (double)(i32)u;
            }
        else
            {
            bool fadd = op.equals(String.withCString("FAdd"));
            bool fsub = op.equals(String.withCString("FSub"));
            bool fmul = op.equals(String.withCString("FMul"));
            bool fdiv = op.equals(String.withCString("FDiv"));
            if ((!fadd && !fsub && !fmul && !fdiv) || n.ops().count() != (u32)2)
                return (IRInsn*)0;
            double x = (double)0;
            double y = (double)0;
            if (!simpFConst((IROperand*)n.ops().get((u32)0), defOf, repl, &x)
                || !simpFConst((IROperand*)n.ops().get((u32)1), defOf, repl, &y))
                return (IRInsn*)0;
            if (f32)
                {
                float fx = (float)x;
                float fy = (float)y;
                float fr = (float)0;
                if (fadd) fr = fx + fy;
                else if (fsub) fr = fx - fy;
                else if (fmul) fr = fx * fy;
                else fr = fx / fy;
                // A subnormal float is left to the hardware (below).
                u32 fb = *(u32*)(pointer)&fr;
                if (((fb >> (u32)23) & (u32)$FF) == (u32)0 && (fb & (u32)$7FFFFF) != (u32)0)
                    return (IRInsn*)0;
                v = (double)fr;
                }
            else if (fadd) v = x + y;
            else if (fsub) v = x - y;
            else if (fmul) v = x * y;
            else v = x / y;
            }
        u64 bits = *(u64*)(pointer)&v;
        // Not NaN, not infinite (the exponent field all ones), and for a
        // double not subnormal (all zeros, a non-zero fraction): the
        // reference explains.
        if (((bits >> (u64)52) & (u64)$7FF) == (u64)$7FF)
            return (IRInsn*)0;
        if (!f32 && ((bits >> (u64)52) & (u64)$7FF) == (u64)0 && (bits & (u64)$FFFFFFFFFFFFF) != (u64)0)
            return (IRInsn*)0;
        string digits = "0123456789abcdef";
        String* hex = String.withCString("");
        for (i32 sh = (i32)60; sh >= (i32)0; sh = sh - (i32)4)
            hex.appendByte(digits[(u32)((bits >> (u64)sh) & (u64)$F)]);
        IRInsn* k = IRInsn.with(String.withCString("Const"));
        k.copyDbg(n);
        k.setRes(r);
        k.add(IROperand.immF(hex, r.ty()));
        return k;
        }
    final bool simpPeel(IROperand* o, Map* defOf)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        Map* none = new Map();
        IRValue* cur = o.val();
        i64 c = (i64)0;
        u32 steps = (u32)0;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            {
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)cur);
            if (d == (IRInsn*)0 || d.memRes() != (IRValue*)0 || d.ops().count() != (u32)2)
                break;
            bool isAdd = d.op().equals(String.withCString("Add"));
            if (!isAdd && !d.op().equals(String.withCString("Sub")))
                break;
            i64 k = (i64)0;
            IROperand* x = (IROperand*)d.ops().get((u32)0);
            IROperand* y = (IROperand*)d.ops().get((u32)1);
            if (simpConst(y, defOf, none, &k) && x.kind() == (u8)OPK_USE && x.val() != (IRValue*)0)
                c = isAdd ? c + k : c - k;
            else if (isAdd && simpConst(x, defOf, none, &k) && y.kind() == (u8)OPK_USE && y.val() != (IRValue*)0)
                {
                c = c + k;
                x = y;
                }
            else
                break;
            cur = x.val();
            steps = steps + (u32)1;
            }
        _peelBase = cur;
        _peelSum = c;
        return steps > (u32)0;
        }

    final void simpDistributeMuls(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Map* none = new Map();
        Map* baseNo = new Map();
        Array* cands = new Array();
        Array* bases = new Array();
        Array* ks = new Array();
        Array* cs = new Array();
        Array* keys = new Array();
        Map* group = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                IRValue* r = n.res();
                if (r == (IRValue*)0 || n.memRes() != (IRValue*)0 || !n.op().equals(String.withCString("Mul"))
                    || n.ops().count() != (u32)2 || !simpIntTy(r.ty()) || self.irWidth(r.ty()) > (u32)4)
                    continue;
                i64 k = (i64)0;
                IROperand* v = (IROperand*)0;
                if (simpConst((IROperand*)n.ops().get((u32)1), defOf, none, &k))
                    v = (IROperand*)n.ops().get((u32)0);
                else if (simpConst((IROperand*)n.ops().get((u32)0), defOf, none, &k))
                    v = (IROperand*)n.ops().get((u32)1);
                if (v == (IROperand*)0 || v.kind() != (u8)OPK_USE || v.val() == (IRValue*)0)
                    continue;
                bool peeled = simpPeel(v, defOf);
                IRValue* bv = _peelBase;
                i64 c = _peelSum;
                if (bv == (IRValue*)0 || bv.ty() == (String*)0 || !bv.ty().equals(r.ty()))
                    continue;
                Object* no = baseNo.get((Hashable*)bv);
                if (no == (Object*)0)
                    {
                    no = (Object*)Number.with(baseNo.count());
                    baseNo.set((Hashable*)bv, no);
                    }
                String* key = String.withU64((u64)((Number*)no).asU32());
                key.appendCString("*");
                key.append(String.withI64(simpWrap(k, r.ty())));
                Object* cnt = group.get((Hashable*)key);
                group.set((Hashable*)key, (Object*)Number.with(cnt == (Object*)0 ? (u32)1 : ((Number*)cnt).asU32() + (u32)1));
                if (peeled)
                    {
                    cands.add((Object*)n);
                    bases.add((Object*)bv);
                    ks.add((Object*)Number.withI64(k));
                    cs.add((Object*)Number.withI64(c));
                    keys.add((Object*)key);
                    }
                }
            }
        // In block order: a product b * k made earlier in the block (the
        // program's, or one made here) is reused. As the reference.
        Map* candAt = new Map();
        for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
            candAt.set((Hashable*)cands.get(i), (Object*)Number.with(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Map* avail = new Map();
            for (u32 at = (u32)0; at < bb.insns().count(); at = at + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(at);
                Object* ci = candAt.get((Hashable*)n);
                if (ci == (Object*)0)
                    {
                    IRValue* r = n.res();
                    if (r != (IRValue*)0 && n.memRes() == (IRValue*)0 && n.op().equals(String.withCString("Mul"))
                        && n.ops().count() == (u32)2 && simpIntTy(r.ty()) && self.irWidth(r.ty()) <= (u32)4)
                        {
                        i64 k = (i64)0;
                        IROperand* v = (IROperand*)0;
                        if (simpConst((IROperand*)n.ops().get((u32)1), defOf, none, &k))
                            v = (IROperand*)n.ops().get((u32)0);
                        else if (simpConst((IROperand*)n.ops().get((u32)0), defOf, none, &k))
                            v = (IROperand*)n.ops().get((u32)1);
                        if (v != (IROperand*)0 && v.kind() == (u8)OPK_USE && v.val() != (IRValue*)0)
                            {
                            Object* no = baseNo.get((Hashable*)v.val());
                            if (no == (Object*)0)
                                {
                                no = (Object*)Number.with(baseNo.count());
                                baseNo.set((Hashable*)v.val(), no);
                                }
                            String* key = String.withU64((u64)((Number*)no).asU32());
                            key.appendCString("*");
                            key.append(String.withI64(simpWrap(k, r.ty())));
                            avail.set((Hashable*)key, (Object*)r);
                            }
                        }
                    continue;
                    }
                u32 i = ((Number*)ci).asU32();
                Object* cnt = group.get(keys.get(i));
                if (cnt == (Object*)0 || ((Number*)cnt).asU32() < (u32)2)
                    continue;
                IRValue* bv = (IRValue*)bases.get(i);
                i64 k = ((Number*)ks.get(i)).asI64();
                i64 c = ((Number*)cs.get(i)).asI64();
                IRValue* r = n.res();
                IRValue* mv = (IRValue*)avail.get(keys.get(i));
                if (mv == (IRValue*)0)
                    {
                    mv = new IRValue(r.ty());
                    IRInsn* m = IRInsn.with(String.withCString("Mul"));
                    m.copyDbg(n);
                    m.setRes(mv);
                    m.add(IROperand.useVal(bv));
                    m.add(IROperand.immI(simpWrap(k, r.ty()), r.ty()));
                    bb.insns().insert(at, (Object*)m);
                    at = at + (u32)1;
                    avail.set(keys.get(i), (Object*)mv);
                    }
                IRInsn* a = IRInsn.with(String.withCString("Add"));
                a.copyDbg(n);
                a.setRes(r);
                a.add(IROperand.useVal(mv));
                a.add(IROperand.immI(simpWrap(c * k, r.ty()), r.ty()));
                bb.insns().set(at, (Object*)a);
                }
            }
        }

    final void simplifyFn(IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        simpDistributeMuls(fn);
        Map* defOf = self.defMapAll(fn);
        Map* repl = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                IRValue* r = n.res();
                IRInsn* fk = simpFoldFloat(n, defOf, repl);
                if (fk != (IRInsn*)0)
                    {
                    bb.insns().set(i, (Object*)fk);
                    defOf.set((Hashable*)r, (Object*)fk);
                    continue;
                    }
                // Neg of a constant (`-7`, which arrives as Neg #7), 8 to 32 bits.
                i64 kn = (i64)0;
                if (r != (IRValue*)0 && n.memRes() == (IRValue*)0 && n.op().equals(String.withCString("Neg"))
                    && n.ops().count() == (u32)1 && simpIntTy(r.ty()) && self.irWidth(r.ty()) <= (u32)4
                    && simpConst((IROperand*)n.ops().get((u32)0), defOf, repl, &kn))
                    {
                    IRInsn* kq = IRInsn.with(String.withCString("Const"));
                    kq.copyDbg(n);
                    kq.setRes(r);
                    kq.add(IROperand.immI(simpWrap((i64)0 - simpWrap(kn, r.ty()), r.ty()), r.ty()));
                    bb.insns().set(i, (Object*)kq);
                    defOf.set((Hashable*)r, (Object*)kq);
                    continue;
                    }
                if (r == (IRValue*)0 || n.memRes() != (IRValue*)0 || n.ops().count() != (u32)2 || !simpIntTy(r.ty()))
                    continue;
                String* op = n.op();
                bool add = op.equals(String.withCString("Add"));
                bool sub = op.equals(String.withCString("Sub"));
                bool mul = op.equals(String.withCString("Mul"));
                bool band = op.equals(String.withCString("And"));
                bool bor = op.equals(String.withCString("Or"));
                bool bxor = op.equals(String.withCString("Xor"));
                bool shl = op.equals(String.withCString("Shl"));
                bool lshr = op.equals(String.withCString("LShr"));
                bool ashr = op.equals(String.withCString("AShr"));
                if (!add && !sub && !mul && !band && !bor && !bxor && !shl && !lshr && !ashr)
                    continue;
                IROperand* a = (IROperand*)n.ops().get((u32)0);
                IROperand* c = (IROperand*)n.ops().get((u32)1);
                i64 ka = (i64)0;
                i64 kc = (i64)0;
                bool ca = simpConst(a, defOf, repl, &ka);
                bool cc = simpConst(c, defOf, repl, &kc);
                u32 w = self.irWidth(r.ty());
                bool small = w <= (u32)4;
                if (ca && cc && small)
                    {
                    u32 bits = w * (u32)8;
                    i64 x = simpWrap(ka, r.ty());
                    i64 y = simpWrap(kc, r.ty());
                    i64 mask = ((i64)1 << (i64)bits) - (i64)1;
                    bool ok = true;
                    i64 v = (i64)0;
                    if (add) v = x + y;
                    else if (sub) v = x - y;
                    else if (mul) v = x * y;
                    else if (band) v = x & y;
                    else if (bor) v = x | y;
                    else if (bxor) v = x ^ y;
                    else
                        {
                        i64 sh = y & mask;
                        if (sh < (i64)0 || sh >= (i64)bits)
                            ok = false;
                        else if (shl) v = x << sh;
                        else if (lshr) v = (x & mask) >> sh;
                        else v = x >> sh;
                        }
                    if (ok)
                        {
                        IRInsn* k = IRInsn.with(String.withCString("Const"));
                        k.copyDbg(n);
                        k.setRes(r);
                        k.add(IROperand.immI(simpWrap(v, r.ty()), r.ty()));
                        bb.insns().set(i, (Object*)k);
                        defOf.set((Hashable*)r, (Object*)k);
                        }
                    continue;
                    }
                // The identities: the other operand must be a value (an
                // immediate pair was folded above, or is 64-bit).
                i64 ones = small ? simpWrap((i64)-1, r.ty()) : (i64)-1;
                IROperand* keep = (IROperand*)0;
                bool zero = false;
                if (cc)
                    {
                    i64 y = small ? simpWrap(kc, r.ty()) : kc;
                    if ((add || sub || bor || bxor || shl || lshr || ashr) && y == (i64)0) keep = a;
                    else if (mul && y == (i64)1) keep = a;
                    else if (band && y == ones) keep = a;
                    else if ((mul || band) && y == (i64)0) zero = true;
                    }
                else if (ca)
                    {
                    i64 x = small ? simpWrap(ka, r.ty()) : ka;
                    if ((add || bor || bxor) && x == (i64)0) keep = c;
                    else if (mul && x == (i64)1) keep = c;
                    else if (band && x == ones) keep = c;
                    else if ((mul || band) && x == (i64)0) zero = true;
                    }
                if (zero)
                    {
                    IRInsn* k = IRInsn.with(String.withCString("Const"));
                    k.copyDbg(n);
                    k.setRes(r);
                    k.add(IROperand.immI((i64)0, r.ty()));
                    bb.insns().set(i, (Object*)k);
                    defOf.set((Hashable*)r, (Object*)k);
                    continue;
                    }
                if (keep != (IROperand*)0 && keep.kind() == (u8)OPK_USE && keep.val() != (IRValue*)0
                    && keep.val().ty() != (String*)0 && keep.val().ty().equals(r.ty()))
                    repl.set((Hashable*)r, (Object*)self.resolveReplace(repl, keep.val()));
                }
            }
        if (repl.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.rewriteThroughReplace(bb.phis(), repl);
            self.rewriteThroughReplace(bb.insns(), repl);
            if (bb.term() != (IRInsn*)0)
                self.rewriteInsnThroughReplace(bb.term(), repl);
            }
        }
    }
