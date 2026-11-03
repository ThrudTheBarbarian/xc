// OptVectorizeParts.xc — the vectoriser's building blocks: fit checks, epilogues, constants and splats (src/xtc/ir/XTIROptVectorize.m).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (VectorizeParts)
    {

    // xc leaves a `for` loop's step in a block of its own when the body ends in
    // `c ? a : b` (the join): a latch whose one predecessor is a loop's exit
    // and branches straight to it. Folded into that predecessor, the latch is
    // the inner loop's exit block, which is the shape recognised. A merge of a
    // straight line, so nothing else changes.
    final void escMergeLatches(IRFunc* fn)
        {
        u32 b = (u32)0;
        while (b < fn.blocks().count())
            {
            IRBlock* X = (IRBlock*)fn.blocks().get(b);
            b = b + (u32)1;
            if (X.phis().count() != (u32)0 || !escIs(X.term(), "Branch") || X.term().ops().count() < (u32)1)
                continue;
            IRBlock* H = ((IROperand*)X.term().ops().get((u32)0)).blk();
            if (H == X || H.phis().count() == (u32)0 || escFrom((IRInsn*)H.phis().get((u32)0), X) == (IROperand*)0)
                continue;
            Array* ps = escPreds(fn, X);
            if (ps.count() != (u32)1)
                continue;
            IRBlock* P = (IRBlock*)ps.get((u32)0);
            if (P == X || P == H || !escIs(P.term(), "Branch") || P.phis().count() != (u32)0)
                continue;
            Array* pp = escPreds(fn, P);
            bool exitOfLoop = pp.count() > (u32)0;
            for (u32 i = (u32)0; i < pp.count(); i = i + (u32)1)
                if (!escIs(((IRBlock*)pp.get(i)).term(), "CondBranch"))
                    exitOfLoop = false;
            if (!exitOfLoop)
                continue;
            for (u32 i = (u32)0; i < X.insns().count(); i = i + (u32)1)
                P.insns().add(X.insns().get(i));
            P.setTerm(X.term());
            for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)H.phis().get(i);
                for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                    if (((IROperand*)phi.ops().get(q)).blk() == X)
                        phi.ops().set(q, (Object*)IROperand.block(P));
                }
            b = b - (u32)1;
            fn.blocks().removeAt(b);
            }
        }

    // The blocks that branch to `t`.
    final Array* escPreds(IRFunc* fn, IRBlock* t)
        {
        Array* ps = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)term.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == t)
                    {
                    ps.add((Object*)bb);
                    break;
                    }
                }
            }
        return ps;
        }

    static bool escIs(IRInsn* n, string op)
        {
        return n != (IRInsn*)0 && n.op().equals(String.withCString(op));
        }

    // A phi's incoming operand from `b`, or 0.
    static IROperand* escFrom(IRInsn* phi, IRBlock* b)
        {
        for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
            if (((IROperand*)phi.ops().get(q)).blk() == b)
                return (IROperand*)phi.ops().get(q + (u32)1);
        return (IROperand*)0;
        }

    static bool escLane32(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
                                   || t.equals(String.withCString("F32")));
        }

    // Whether `o` is the block's field `field` (lo 1, hi 2) as a par body
    // reads it: Trunc(Load(FieldAddr(self, #field))), self the method's
    // object. As the reference (isParField:).
    final bool escIsParField(IROperand* o, i64 field)
        {
        if (o == (IROperand*)0 || o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRInsn* t = (IRInsn*)_esDefOf.get((Hashable*)o.val());
        if (!escIs(t, "Trunc") || t.ops().count() == (u32)0 || ((IROperand*)t.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return false;
        IRInsn* l = (IRInsn*)_esDefOf.get((Hashable*)((IROperand*)t.ops().get((u32)0)).val());
        if (!escIs(l, "Load") || l.ops().count() == (u32)0 || ((IROperand*)l.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return false;
        IRInsn* fa = (IRInsn*)_esDefOf.get((Hashable*)((IROperand*)l.ops().get((u32)0)).val());
        if (!escIs(fa, "FieldAddr") || fa.ops().count() < (u32)2)
            return false;
        IROperand* b = (IROperand*)fa.ops().get((u32)0);
        IROperand* k = (IROperand*)fa.ops().get((u32)1);
        if (b.kind() != (u8)OPK_USE || _esDefOf.get((Hashable*)b.val()) != (Object*)0 || k.kind() != (u8)OPK_IMMI)
            return false;
        return k.imm() == field;
        }

    final IRBlock* escBlockOf(IRFunc* fn, IRValue* v)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (((IRInsn*)bb.insns().get(i)).res() == v)
                    return bb;
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                if (((IRInsn*)bb.phis().get(i)).res() == v)
                    return bb;
            }
        return (IRBlock*)0;
        }

    // B -> T0 (the inner header), a chain of tests each leaving for E, and
    // L, the body, back to T0.
    final bool escInner(IRFunc* fn)
        {
        _esT0 = ((IROperand*)_esB.term().ops().get((u32)0)).blk();
        if (_esT0 == _esH || _esT0 == _esB || _esT0.phis().count() == (u32)0)
            return false;
        _esTests = new Array();
        _esCont = new Array();
        IRBlock* cur = _esT0;
        _esL = (IRBlock*)0;
        while (_esTests.count() < (u32)8)
            {
            IRInsn* t = cur.term();
            if (cur != _esT0 && (cur.phis().count() != (u32)0 || escPreds(fn, cur).count() != (u32)1))
                return false;
            // A block that only passes on (xc's `&&`, if-converted, leaves the
            // test in a join block after the header): part of the chain, no test.
            if (escIs(t, "Branch") && t.ops().count() >= (u32)1)
                {
                IRBlock* nx = ((IROperand*)t.ops().get((u32)0)).blk();
                if (nx == _esT0 || nx == _esH || nx == _esB || nx == _esE || _esTests.contains((Object*)nx))
                    return false;
                _esTests.add((Object*)cur);
                _esCont.add((Object*)Number.with((u32)2));
                cur = nx;
                continue;
                }
            if (!escIs(t, "CondBranch") || t.ops().count() < (u32)3)
                return false;
            IRBlock* a = ((IROperand*)t.ops().get((u32)1)).blk();
            IRBlock* b = ((IROperand*)t.ops().get((u32)2)).blk();
            IRBlock* next = (IRBlock*)0;
            if (b == _esE && a != _esE)
                {
                next = a;
                _esCont.add((Object*)Number.with((u32)1));
                }
            else if (a == _esE && b != _esE)
                {
                next = b;
                _esCont.add((Object*)Number.with((u32)0));
                }
            else
                return false;
            if (((IROperand*)t.ops().get((u32)0)).kind() != (u8)OPK_USE)
                return false;
            _esTests.add((Object*)cur);
            if (next == _esT0 || next == _esH || next == _esB || _esTests.contains((Object*)next))
                return false;
            if (escIs(next.term(), "Branch") && ((IROperand*)next.term().ops().get((u32)0)).blk() == _esT0)
                {
                _esL = next;
                break;
                }
            cur = next;
            }
        if (_esL == (IRBlock*)0 || _esL.phis().count() != (u32)0 || escPreds(fn, _esL).count() != (u32)1)
            return false;
        Array* tp = escPreds(fn, _esT0);
        if (tp.count() != (u32)2)
            return false;
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)_esT0.phis().get(i);
            if (p.res() == (IRValue*)0 || !escLane32(p.res().ty()) || p.ops().count() != (u32)4
                || escFrom(p, _esB) == (IROperand*)0 || escFrom(p, _esL) == (IROperand*)0)
                return false;
            }
        // E is reached from the tests and nothing else.
        Array* ep = escPreds(fn, _esE);
        u32 testing = (u32)0;
        for (u32 i = (u32)0; i < _esCont.count(); i = i + (u32)1)
            if (((Number*)_esCont.get(i)).asU32() != (u32)2)
                testing = testing + (u32)1;
        if (ep.count() != testing || testing == (u32)0 || _esE.phis().count() != (u32)0)
            return false;
        for (u32 i = (u32)0; i < ep.count(); i = i + (u32)1)
            if (!_esTests.contains(ep.get(i)))
                return false;
        return true;
        }

    // The sum phi p closes in E: `s + w`, or a Select between that and s. The
    // instructions it takes go in `special`. False when p is not such a sum.
    final bool escAccOf(IRFunc* fn, IRInsn* p, Set* special)
        {
        IROperand* back = escFrom(p, _esE);
        if (p.ops().count() != (u32)4 || back == (IROperand*)0 || back.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)back.val());
        String* t = p.res().ty();
        // Integer sums only: wrapping adds reassociate; float ones do not.
        if (d == (IRInsn*)0 || escBlockOf(fn, d.res()) != _esE || t == (String*)0
            || !(t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))) || !t.equals(d.res().ty()))
            return false;
        IRInsn* add = d;
        u32 kind = (u32)0;
        IROperand* cond = (IROperand*)0;
        if (escIs(d, "Select") && d.ops().count() == (u32)3)
            {
            IROperand* x = (IROperand*)d.ops().get((u32)1);
            IROperand* y = (IROperand*)d.ops().get((u32)2);
            IROperand* other = (IROperand*)0;
            if (y.kind() == (u8)OPK_USE && y.val() == p.res())
                {
                kind = (u32)1;
                other = x;
                }
            else if (x.kind() == (u8)OPK_USE && x.val() == p.res())
                {
                kind = (u32)2;
                other = y;
                }
            if (other == (IROperand*)0 || other.kind() != (u8)OPK_USE)
                return false;
            add = (IRInsn*)_esDefOf.get((Hashable*)other.val());
            if (add == (IRInsn*)0 || escBlockOf(fn, add.res()) != _esE || escUses(add.res()) != (u32)1)
                return false;
            cond = (IROperand*)d.ops().get((u32)0);
            special.add((Hashable*)add.res());
            }
        if (!escIs(add, "Add") || add.ops().count() != (u32)2 || !add.res().ty().equals(t))
            return false;
        IROperand* a = (IROperand*)add.ops().get((u32)0);
        IROperand* b = (IROperand*)add.ops().get((u32)1);
        bool aIs = a.kind() == (u8)OPK_USE && a.val() == p.res();
        bool bIs = b.kind() == (u8)OPK_USE && b.val() == p.res();
        if (!aIs && !bIs)
            return false;
        special.add((Hashable*)d.res());
        _esAccPhis.add((Object*)p);
        _esAccW.add((Object*)(aIs ? b : a));
        _esAccKind.add((Object*)Number.with(kind));
        _esAccCond.add((Object*)cond);
        return true;
        }

    // Not from the loop: defined before it (or a parameter), and not a phi of H.
    final bool escIsInvariant(IRValue* v)
        {
        if (v == (IRValue*)0 || v == _esIvPhi.res() || _esRegion.contains((Hashable*)v) || escIsAcc(v))
            return false;
        IRBlock* at = escBlockOf(_esFn, v);
        return at == (IRBlock*)0 || !(at == _esH || at == _esE || escRegionBlocks().contains((Object*)at));
        }

    // What a pointer points into: a global ("s:" and its name) or the value it
    // is derived from ("v:" and its creation number).
    final String* escRootOf(IRValue* p)
        {
        IRValue* v = p;
        for (u32 hop = (u32)0; hop < (u32)16; hop = hop + (u32)1)
            {
            IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)v);
            if (d == (IRInsn*)0 || d.ops().count() < (u32)1)
                break;
            IROperand* o = (IROperand*)d.ops().get((u32)0);
            if (escIs(d, "AddrOf") && o.kind() == (u8)OPK_SYM && o.name() != (String*)0)
                {
                String* r = String.withCString("s:");
                r.append(o.name());
                return r;
                }
            if ((escIs(d, "ElementAddr") || escIs(d, "FieldAddr")) && o.kind() == (u8)OPK_USE)
                {
                v = o.val();
                continue;
                }
            break;
            }
        String* r = new String();
        r.appendFormat("v:%u", v.seq());
        return r;
        }

    // The loop's own ElementAddr that `ad` reads, or 0.
    final IRInsn* escOwnAddr(IROperand* ad)
        {
        if (ad.kind() != (u8)OPK_USE || !_esRegion.contains((Hashable*)ad.val()))
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)ad.val());
        return escIs(d, "ElementAddr") ? d : (IRInsn*)0;
        }

    final bool escIsAcc(IRValue* v)
        {
        for (u32 i = (u32)0; i < _esAccPhis.count(); i = i + (u32)1)
            if (((IRInsn*)_esAccPhis.get(i)).res() == v)
                return true;
        return false;
        }

    // B, the tests (T0 among them) and L, in order.
    final Array* escRegionBlocks(void)
        {
        Array* r = new Array();
        r.add((Object*)_esB);
        r.addAll(_esTests);
        r.add((Object*)_esL);
        return r;
        }

    // An operand the vector code can take: a region value or the iv (a lane
    // value), an invariant, or an immediate. A boolean invariant has no splat.
    final bool escOperandOK(IROperand* o, bool maskOK)
        {
        if (o.kind() == (u8)OPK_IMMI || o.kind() == (u8)OPK_IMMF)
            return true;
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRValue* v = o.val();
        if (v == _esIvPhi.res() || _esRegion.contains((Hashable*)v))
            return escLane32(v.ty()) || (maskOK && v.ty().equals(String.withCString("Bool")));
        if (escIsAcc(v))
            return false;
        // An invariant: a constant, or defined outside the loop, and a
        // lane-sized scalar.
        if (!escLane32(v.ty()))
            return false;
        IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)v);
        if (d != (IRInsn*)0 && escIs(d, "Const"))
            return true;
        IRBlock* at = escBlockOf(_esFn, v);
        return at == (IRBlock*)0 || !(at == _esH || at == _esE || escRegionBlocks().contains((Object*)at));
        }

    static i64 escLog2(i64 v)
        {
        if (v <= (i64)0 || (v & (v - (i64)1)) != (i64)0)
            return (i64)0 - (i64)1;
        i64 s = (i64)0;
        while (((i64)1 << s) < v)
            s = s + (i64)1;
        return s;
        }

    static bool escFloatPred(String* p)
        {
        return p != (String*)0 && (p.equals(String.withCString("OLT")) || p.equals(String.withCString("OLE"))
            || p.equals(String.withCString("OGT")) || p.equals(String.withCString("OGE"))
            || p.equals(String.withCString("OEQ")) || p.equals(String.withCString("UNE")));
        }

    // ── the rewrite ────────────────────────────────────────────────────────

    final String* escVecTy(String* scalar)
        {
        if (scalar.equals(String.withCString("Bool")))
            return vecTyOf(String.withCString("I32"), _esBytes);
        return vecTyOf(scalar, _esBytes);
        }

    final IRValue* escPut(Array* into, string op, String* ty, IROperand* a, IROperand* b)
        {
        IRValue* r = new IRValue(ty);
        IRInsn* n = IRInsn.with(String.withCString(op));
        n.setRes(r);
        if (a != (IROperand*)0)
            n.add(a);
        if (b != (IROperand*)0)
            n.add(b);
        into.add((Object*)n);
        return r;
        }

    // The scalar type an operand of `n` has: its own, or the other operand's.
    static String* escOpTy(IRInsn* n, u32 k)
        {
        IROperand* o = (IROperand*)n.ops().get(k);
        if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
            return o.val().ty();
        for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1)
            {
            IROperand* p = (IROperand*)n.ops().get(j);
            if (p.kind() == (u8)OPK_USE && p.val() != (IRValue*)0)
                return p.val().ty();
            }
        return n.res().ty();
        }

    // `b ^ ((a ^ b) & m)`: a where the mask is set, else b.
    final IRValue* escBlend(Array* into, String* vty, IRValue* m, IRValue* a, IRValue* b)
        {
        IRValue* d = escPut(into, "VXor", vty, IROperand.useVal(a), IROperand.useVal(b));
        IRValue* e = escPut(into, "VAnd", vty, IROperand.useVal(d), IROperand.useVal(m));
        return escPut(into, "VXor", vty, IROperand.useVal(b), IROperand.useVal(e));
        }

    // escPut, reusing an identical lane operation computed earlier in the same
    // vector loop: clang leaves x*x in both the test and the body, and every
    // value kept is a vector register for the whole inner loop.
    final IRValue* escPutC(Array* into, string op, String* ty, IROperand* a, IROperand* b)
        {
        String* k = new String();
        k.appendFormat("%s:%u:%u", op, a.val().seq(), b.val().seq());
        Object* have = _esCse.get((Hashable*)k);
        if (have != (Object*)0)
            return (IRValue*)have;
        IRValue* r = escPut(into, op, ty, a, b);
        _esCse.set((Hashable*)k, (Object*)r);
        return r;
        }

    // The float constant 2.0, as an immediate or a Const.
    final bool escIsTwo(IROperand* o)
        {
        IROperand* c = o;
        if (o.kind() == (u8)OPK_USE)
            {
            IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)o.val());
            if (!escIs(d, "Const") || d.ops().count() < (u32)1)
                return false;
            c = (IROperand*)d.ops().get((u32)0);
            }
        return c.kind() == (u8)OPK_IMMF && c.fpHex() != (String*)0
            && c.fpHex().equals(String.withCString("4000000000000000"));
        }

    // The other _esJam - 1 vectors (escApply): copy u runs items viv + u*VF.
    // Every instruction of VB, VI and VE that depends on viv or on a lane
    // value is copied, once per copy, after the block's originals, with viv
    // read as viv + u*VF; a lane phi of VI is copied with it. The trip
    // counter, its test, VE's step and everything uniform stay single. As
    // the reference (jamBody:).
    static bool escJamUses(IRInsn* n, Set* D)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && D.contains((Hashable*)o.val()))
                return true;
            }
        return false;
        }

    // Would `jam` copies fit the back end's vector pool? VI, the inner loop,
    // is where the copies stand together, so it is swept in order as
    // vecInterleaveFits sweeps a reduction's body: a value that depends on the
    // lanes (D, as escJam builds it) is held once per copy, a uniform one once.
    // VI's phis and every vector it reads from outside are live throughout,
    // its own values from definition to last use (to the end when a phi takes
    // one round again); an add takes the register of an operand that dies at
    // it. Four copies of three multiply-add chains (`a = a * k + c`) asked
    // arm64 for more than its 14, and the back end, which does not spill a
    // vector, stopped the build (0.89 and 0.9). As the reference's jamFits:.
    static bool escIsVec(IRValue* v)
        {
        return v != (IRValue*)0 && v.ty().hasPrefix(String.withCString("Vec("));
        }

    static u32 escCopies(Set* D, IRValue* v, u32 jam)
        {
        return D.contains((Hashable*)v) ? jam : (u32)1;
        }

    final bool escJamFits(u32 jam, IRBlock* VB, IRBlock* VI, IRValue* viv, u32 pool)
        {
        Set* D = new Set();
        D.add((Hashable*)viv);
        for (u32 i = (u32)0; i < VB.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)VB.insns().get(i);
            if (n.res() != (IRValue*)0 && escJamUses(n, D))
                D.add((Hashable*)n.res());
            }
        Set* phiRes = new Set();
        for (u32 i = (u32)0; i < VI.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)VI.phis().get(i);
            if (p.res() == (IRValue*)0)
                continue;
            phiRes.add((Hashable*)p.res());
            if (escIsVec(p.res()) || escJamUses(p, D))
                D.add((Hashable*)p.res());
            }
        for (u32 i = (u32)0; i < VI.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)VI.insns().get(i);
            if (n.res() != (IRValue*)0 && escJamUses(n, D))
                D.add((Hashable*)n.res());
            }
        u32 n = VI.insns().count();
        Set* inVI = new Set();
        Map* lastUse = new Map();
        Set* outside = new Set();
        u32 through = (u32)0;
        for (u32 i = (u32)0; i < VI.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)VI.phis().get(i);
            if (p.res() != (IRValue*)0 && escIsVec(p.res()))
                through = through + escCopies(D, p.res(), jam);
            }
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)VI.insns().get(i);
            for (u32 q = (u32)0; q < insn.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(q);
                if (o.kind() != (u8)OPK_USE || !escIsVec(o.val()))
                    continue;
                if (inVI.contains((Hashable*)o.val()))
                    lastUse.set((Hashable*)o.val(), (Object*)Number.withU32(i));
                else if (!phiRes.contains((Hashable*)o.val()) && !outside.contains((Hashable*)o.val()))
                    {
                    outside.add((Hashable*)o.val());
                    through = through + escCopies(D, o.val(), jam);
                    }
                }
            if (insn.res() != (IRValue*)0)
                inVI.add((Hashable*)insn.res());
            }
        for (u32 i = (u32)0; i < VI.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)VI.phis().get(i);
            for (u32 q = (u32)0; q < p.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)p.ops().get(q);
                if (o.kind() == (u8)OPK_USE && inVI.contains((Hashable*)o.val()))
                    lastUse.set((Hashable*)o.val(), (Object*)Number.withU32(n));
                }
            }
        u32 live = (u32)0;
        u32 peak = (u32)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)VI.insns().get(i);
            u32 dying = (u32)0;
            for (u32 q = (u32)0; q < insn.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(q);
                if (o.kind() != (u8)OPK_USE || !inVI.contains((Hashable*)o.val()) || !escIsVec(o.val()))
                    continue;
                Number* lu = (Number*)lastUse.get((Hashable*)o.val());
                if (lu == (Number*)0 || lu.asU32() != i)
                    continue;
                lastUse.set((Hashable*)o.val(), (Object*)Number.withU32(n + (u32)1));
                dying = dying + escCopies(D, o.val(), jam);
                }
            u32 born = (insn.res() != (IRValue*)0 && escIsVec(insn.res())) ? escCopies(D, insn.res(), jam) : (u32)0;
            if (insn.op().equals(String.withCString("VAdd")) && dying > (u32)0)
                {
                live = live + born - dying;
                if (live > peak)
                    peak = live;
                }
            else
                {
                live = live + born;
                if (live > peak)
                    peak = live;
                live = live - dying;
                }
            }
        return peak + through <= pool;
        }

    // VH: the vector iv and the vector sums; `viv <= N - VF` (the last whole
    // step), else VX. Returns the iv's next value (defined in VE).
    final IRValue* escVecHead(IRFunc* fn, IRBlock* VH, IRBlock* VB, IRBlock* VE, IRBlock* VX, IRValue* viv)
        {
        String* ivTy = _esIvPhi.res().ty();
        IRValue* vivNext = new IRValue(ivTy);
        IRInsn* ip = IRInsn.with(String.withCString("Phi"));
        ip.setRes(viv);
        ip.add(IROperand.block(_esPH));
        ip.add(escFrom(_esIvPhi, _esPH));
        ip.add(IROperand.block(VE));
        ip.add(IROperand.useVal(vivNext));
        VH.addPhi(ip);
        // The sums stay SCALAR, each step adding its lanes' reduction: a vector
        // sum would hold a register through the whole inner loop, and one
        // reduction a step is nothing beside the inner loop's work.
        _esVSum = new Array();
        _esVSumNext = new Array();
        for (u32 i = (u32)0; i < _esAccPhis.count(); i = i + (u32)1)
            {
            IRInsn* acc = (IRInsn*)_esAccPhis.get(i);
            String* t = acc.res().ty();
            IRValue* vs = new IRValue(t);
            IRValue* vn = new IRValue(t);
            IRInsn* sp = IRInsn.with(String.withCString("Phi"));
            sp.setRes(vs);
            sp.add(IROperand.block(_esPH));
            sp.add(escFrom(acc, _esPH));
            sp.add(IROperand.block(VE));
            sp.add(IROperand.useVal(vn));
            VH.addPhi(sp);
            _esVSum.add((Object*)vs);
            _esVSumNext.add((Object*)vn);
            }
        IRValue* c = (IRValue*)0;
        if (_esBoundConst)
            {
            c = new IRValue(String.withCString("Bool"));
            IRInsn* g = IRInsn.with(String.withCString("ICmp"));
            g.setRes(c);
            g.setPred(String.withCString(_esSigned ? "SLE" : "ULE"));
            g.add(IROperand.useVal(viv));
            g.add(IROperand.immI(_esN - (i64)(_esVF * _esJam), ivTy));
            VH.insns().add((Object*)g);
            _esJamCmp = g;
            }
        else
            {
            // A run-time bound: viv < N and N - viv >= VF (N - VF could wrap).
            String* b = String.withCString("Bool");
            IRValue* c1 = escPut(VH.insns(), "ICmp", b, IROperand.useVal(viv), _esBoundOp);
            ((IRInsn*)VH.insns().get(VH.insns().count() - (u32)1)).setPred(String.withCString(_esSigned ? "SLT" : "ULT"));
            IRValue* rem = escPut(VH.insns(), "Sub", ivTy, _esBoundOp, IROperand.useVal(viv));
            IRValue* c2 = escPut(VH.insns(), "ICmp", b, IROperand.useVal(rem), IROperand.immI((i64)(_esVF * _esJam), ivTy));
            _esJamCmp = (IRInsn*)VH.insns().get(VH.insns().count() - (u32)1);
            ((IRInsn*)VH.insns().get(VH.insns().count() - (u32)1)).setPred(String.withCString(_esSigned ? "SGE" : "UGE"));
            c = escPut(VH.insns(), "And", b, IROperand.useVal(c1), IROperand.useVal(c2));
            }
        IRInsn* br = IRInsn.with(String.withCString("CondBranch"));
        br.add(IROperand.useVal(c));
        br.add(IROperand.block(VB));
        br.add(IROperand.block(VX));
        VH.setTerm(br);
        return vivNext;
        }

    // A compare the trip count can replace: two operands and a predicate, read
    // once, defined in the loop.
    final bool escTripCmpOK(IRInsn* g, bool inAnd)
        {
        if (g.ops().count() != (u32)2 || g.pred() == (String*)0 || escUses(g.res()) != (u32)1)
            return false;
        return !inAnd || _esRegion.contains((Hashable*)g.res());
        }

    // How many operands in the function read v.
    final u32 escUses(IRValue* v)
        {
        u32 c = (u32)0;
        for (u32 b = (u32)0; b < _esFn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)_esFn.blocks().get(b);
            Array* all = new Array();
            all.addAll(bb.phis());
            all.addAll(bb.insns());
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() == v)
                        c = c + (u32)1;
                    }
                }
            }
        return c;
        }

    // VX: the sums reduced and added to what they entered with; the scalar
    // loop then starts where the vector one stopped.
    final void escVecExit(IRBlock* VX, IRValue* viv)
        {
        for (u32 i = (u32)0; i < _esAccPhis.count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)_esAccPhis.get(i);
            escReenter(p, VX, IROperand.useVal((IRValue*)_esVSum.get(i)));
            }
        escReenter(_esIvPhi, VX, IROperand.useVal(viv));
        for (u32 i = (u32)0; i < _esPassPhis.count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)_esPassPhis.get(i);
            escReenter(p, VX, escFrom(p, _esPH));
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(_esH));
        VX.setTerm(br);
        }

    // H's phi `p` now enters from VX with `v` instead of from PH.
    final void escReenter(IRInsn* p, IRBlock* VX, IROperand* v)
        {
        for (u32 q = (u32)0; q + (u32)1 < p.ops().count(); q = q + (u32)2)
            if (((IROperand*)p.ops().get(q)).blk() == _esPH)
                {
                p.ops().set(q, (Object*)IROperand.block(VX));
                p.ops().set(q + (u32)1, (Object*)v);
                }
        }

    // Every value the cycle-closing instruction depends on, walked backwards
    // through the body. Values defined outside the body (the header's phis, the
    // preheader's invariants) are recorded but not walked through.
    final Map* vecDistributeCone(IRInsn* accNext, IRBlock* B)
        {
        Map* cone = new Map();
        Array* work = new Array();
        cone.set((Hashable*)accNext.res(), (Object*)accNext);
        work.add((Object*)accNext);
        while (work.count() > (u32)0)
            {
            IRInsn* cur = (IRInsn*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            for (u32 k = (u32)0; k < cur.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)cur.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == 0)
                    continue;
                if (cone.get((Hashable*)o.val()) != (Object*)0)
                    continue;
                cone.set((Hashable*)o.val(), (Object*)cur);
                for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                    if (((IRInsn*)B.insns().get(i)).res() == o.val())
                        work.add((Object*)B.insns().get(i));
                }
            }
        return cone;
        }

    // Nothing in the body may be observable twice, so the copy may hold only
    // pure arithmetic and loads.
    final bool vecDistributePure(IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)B.insns().get(i)).op();
            if (op.equals(String.withCString("Load")) || op.equals(String.withCString("Const"))
                || op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))
                || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And"))
                || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor"))
                || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr"))
                || op.equals(String.withCString("AShr")) || op.equals(String.withCString("ICmp"))
                || op.equals(String.withCString("Select")) || op.equals(String.withCString("ZExt"))
                || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc"))
                || op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("FieldAddr"))
                || op.equals(String.withCString("ElementAddr")))
                continue;
            return false;
            }
        return true;
        }

    final void vecDistributeRewrite(Array* insns, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            vecDistributeRewriteOne((IRInsn*)insns.get(i), from, to);
        }

    final void vecDistributeRewriteOne(IRInsn* n, IRValue* from, IRValue* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    final void vecNoteDefs(Map* defOf, Map* defBlk, Array* list, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() == (IRValue*)0)
                continue;
            defOf.set((Hashable*)n.res(), (Object*)n);
            defBlk.set((Hashable*)n.res(), (Object*)bb);
            }
        }

    // A literal, or a RUNTIME bound; sets _vrMapRT to say which. Kept to ONE
    // call at the use site, and the locals kept in here, because vecMapAt is at
    // the arm64 frame ceiling: the same test written inline cost it 176 bytes.
    final bool vecMapBound(IRInsn* guard, Map* defOf, i64* n)
        {
        _vrMapRT = false;
        // WIDE: a u32 bound above 2^31 truncated into an i32 came back
        // negative here and this guard read it as "not a counted loop", so the
        // shipped compiler left call_depth's 2,800,000,000-trip reduction
        // scalar while the reference vectorised it.
        if (vecConstWide((IROperand*)guard.ops().get((u32)1), defOf, n))
            return *n > (i64)0;
        if (((IROperand*)guard.ops().get((u32)1)).kind() != (u8)OPK_USE)
            return false;
        _vrMapRT = true;
        return true;
        }

    // Is a RUNTIME map bound usable? It needs a strict `<` -- with `i <= n` the
    // trip count is n+1 and the vector limit n & ~(vw-1) is simply wrong -- and
    // it must be loop-INVARIANT. A value with NO defining instruction is a
    // parameter, invariant by construction, so an absent defBlk entry must not
    // read as a refusal. EXTRACTED for the arm64 frame budget: inline, vecMapAt
    // needed 18080 bytes against a 16384 ceiling.
    final bool vecMapRTOK(IRInsn* guard, Map* defBlk, IRBlock* H, IRBlock* B)
        {
        if (!guard.pred().equals(String.withCString("ULT")) && !guard.pred().equals(String.withCString("SLT")))
            return false;
        Object* bdb = defBlk.get((Hashable*)((IROperand*)guard.ops().get((u32)1)).val());
        if (bdb != (Object*)0 && ((IRBlock*)bdb == H || (IRBlock*)bdb == B))
            return false;
        return true;
        }

    // The phi value on the back edge from `B`.
    final IROperand* vecBackOp(IRInsn* phi, IRBlock* B)
        {
        if (((IROperand*)phi.ops().get((u32)0)).blk() == B)
            return (IROperand*)phi.ops().get((u32)1);
        if (((IROperand*)phi.ops().get((u32)2)).blk() == B)
            return (IROperand*)phi.ops().get((u32)3);
        return (IROperand*)0;
        }

    // The value paired with the ENTRY (non-latch) block, and that block. The
    // operands are (block, value) pairs, so when B is the first pair the entry
    // value is the second one.
    // Does this induction phi provably start at ZERO on the loop's entry edge?
    // EVERY recogniser needs it (see XTIROptVectorize.m). The transforms step
    // the existing phi by the vector width and keep the guard, which reproduces
    // the scalar loop only from 0. A non-zero start miscompiled BOTH shapes:
    // a reduction returned 1956 instead of 2016, and a map WROTE b[0] and b[1]
    // for a loop starting at 2 — memory outside the range.
    // The induction variable's constant start, or -1 when it is not a
    // non-negative constant. A non-zero start is VECTORISED now rather than
    // refused: every epilogue here works from the trip LENGTH, so [start, n)
    // splits into whole vectors plus a scalar tail exactly as [0, n) does.
    //
    // Returning the value rather than a bool keeps the CALL SITES to one
    // expression each — #1126 found that adding a separate branch pushed
    // Opt$vecWideningAt 80 bytes past the 16 KB arm64 frame budget, and that
    // constraint has not gone away.
    // 64-bit, read with vecConstWide: a u32 start of 2^31 or more is a
    // constant there too (the narrow read made it negative, and the loop took
    // the runtime-start path, where the reference took the constant one).
    final i64 vecIvStart(IRInsn* ivPhi, IRBlock* latch, Map* defOf)
        {
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return (i64)-1;
        IROperand* entry = ((IROperand*)ivPhi.ops().get((u32)0)).blk() == latch
                               ? (IROperand*)ivPhi.ops().get((u32)3)
                               : (IROperand*)ivPhi.ops().get((u32)1);
        if (entry == (IROperand*)0)
            return (i64)-1;
        i64 start = (i64)0;
        if (!vecConstWide(entry, defOf, &start))
            return (i64)-1;
        if (start < (i64)0)
            return (i64)-1;
        return start;
        }

    final IROperand* vecEntryOpOf(IRInsn* phi, IRBlock* B)
        {
        return ((IROperand*)phi.ops().get((u32)0)).blk() == B
                   ? (IROperand*)phi.ops().get((u32)3)
                   : (IROperand*)phi.ops().get((u32)1);
        }

    final IRBlock* vecEntryBlkOf(IRInsn* phi, IRBlock* B)
        {
        return ((IROperand*)phi.ops().get((u32)0)).blk() == B
                   ? ((IROperand*)phi.ops().get((u32)2)).blk()
                   : ((IROperand*)phi.ops().get((u32)0)).blk();
        }

    final bool vecAccReadElsewhere(IRBlock* bb, IRInsn* accNext, IRValue* acc)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n == accNext)
                continue;
            if (insnUsesValue(n, acc))
                return true;
            }
        return false;
        }

    // The reduction body: the map's allowed set minus Store, plus the ivNext and
    // accNext handled separately. The lane is restricted to 32-bit integer —
    // a narrower one is the widening-sum shape, and float needs an associativity
    // the source language does not grant.
    // Unsigned magic-number division, the SIMPLE form only (Hacker's Delight
    // §10-9). Returns false unless x/d == mulhu(x, M) >>u s holds for every x,
    // which is the `a == 0` case; the other form needs an extra add and a shift
    // that cannot overflow, and there is no vector idiom for it here. d = 7 and
    // d = 14 are the small divisors that fall out — they stay scalar and
    // correct. Results land in _magicM / _magicS.
    //
    // The same computation lives in the arm64 back end, which is where the
    // SCALAR lowering gets its constants. Both must agree, or a loop would
    // compute one answer vectorised and another scalar.
    final bool vecMagicU32(u32 d)
        {
        if (d < (u32)2)
            return false;
        u64 twoWm1 = (u64)$80000000;
        u64 maxu = (u64)$FFFFFFFF;
        u64 twoW = (u64)$100000000;
        u64 dd = (u64)d;
        bool addForm = false;
        u32 p = (u32)31;
        u64 nc = maxu - (twoW % dd);
        u64 q1 = twoWm1 / nc;
        u64 r1 = twoWm1 - q1 * nc;
        u64 q2 = (twoWm1 - (u64)1) / dd;
        u64 r2 = (twoWm1 - (u64)1) - q2 * dd;
        u64 delta = (u64)0;
        bool more = true;
        while (more)
            {
            p = p + (u32)1;
            if (r1 >= nc - r1) { q1 = (u64)2 * q1 + (u64)1; r1 = (u64)2 * r1 - nc; }
            else               { q1 = (u64)2 * q1;          r1 = (u64)2 * r1; }
            if (r2 + (u64)1 >= dd - r2)
                {
                if (q2 >= twoWm1 - (u64)1) addForm = true;
                q2 = (u64)2 * q2 + (u64)1;
                r2 = (u64)2 * r2 + (u64)1 - dd;
                }
            else
                {
                if (q2 >= twoWm1) addForm = true;
                q2 = (u64)2 * q2;
                r2 = (u64)2 * r2 + (u64)1;
                }
            delta = dd - (u64)1 - r2;
            more = p < (u32)64 && (q1 < delta || (q1 == delta && r1 == (u64)0));
            }
        if (addForm)
            return false;
        _magicM = (u32)((q2 + (u64)1) & maxu);
        _magicS = p - (u32)32;
        return true;
        }

    // Would B's vector form fit the back end's pool? An upper bound, on the
    // scalar body: each per-lane value (elems) is a vector from its definition
    // to its last use, each splatted operand of a per-lane op holds one more
    // for that op, and the accumulator and the lane-index vector are live
    // throughout. No register reuse is credited. It is NOT an upper bound of
    // the back end's own count (values the allocator holds across the loop
    // are not all seen here), so it keeps a margin of three: a 14-register
    // function whose MD5-like body counted 14 overflowed. As the reference's
    // vecScalarBodyFits.
    final bool vecScalarBodyFits(IRBlock* B, Array* elems, u32 pool)
        {
        Map* isElem = new Map();
        for (u32 i = (u32)0; i < elems.count(); i = i + (u32)1)
            isElem.set((Hashable*)elems.get(i), elems.get(i));
        u32 n = B.insns().count();
        Map* lastUse = new Map();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)B.insns().get(i);
            for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                    lastUse.set((Hashable*)o.val(), (Object*)Number.with(i));
                }
            }
        u32 live = (u32)2;
        u32 peak = live;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)B.insns().get(i);
            if (insn.res() == (IRValue*)0 || isElem.get((Hashable*)insn.res()) == (Object*)0)
                continue;
            u32 splats = (u32)0;
            for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || isElem.get((Hashable*)o.val()) == (Object*)0)
                    splats = splats + (u32)1;
                }
            if (live + (u32)1 + splats > peak)
                peak = live + (u32)1 + splats;
            live = live + (u32)1;
            for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || isElem.get((Hashable*)o.val()) == (Object*)0)
                    continue;
                Object* lu = lastUse.get((Hashable*)o.val());
                if (lu != (Object*)0 && ((Number*)lu).asU32() == i)
                    {
                    lastUse.set((Hashable*)o.val(), (Object*)Number.with(n));
                    live = live - (u32)1;
                    }
                }
            }
        return peak + (u32)3 <= pool;
        }

    final bool vecRedux32(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")));
        }

    // Is this operand an ElementAddr indexed by the induction variable?
    final bool vecIsElemAddr(IROperand* p, IRValue* iv, Map* defOf)
        {
        if (p.kind() != (u8)OPK_USE)
            return false;
        Object* o = defOf.get((Hashable*)p.val());
        if (o == (Object*)0)
            return false;
        IRInsn* ea = (IRInsn*)o;
        if (!ea.op().equals(String.withCString("ElementAddr")) || ea.ops().count() < (u32)2)
            return false;
        IROperand* idx = (IROperand*)ea.ops().get((u32)1);
        return idx.kind() == (u8)OPK_USE && idx.val() == iv;
        }

    final bool vecElementwise(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul"));
        }

    // The vector opcode for a scalar elementwise one. The float ops reuse
    // VAdd/VSub/VMul — the backend emits fadd/fsub/fmul when the result
    // vector's lane is floating.
    final String* vecOpFor(String* op)
        {
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("FAdd")))
            return String.withCString("VAdd");
        if (op.equals(String.withCString("Sub")) || op.equals(String.withCString("FSub")))
            return String.withCString("VSub");
        if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul")))
            return String.withCString("VMul");
        if (op.equals(String.withCString("And")))
            return String.withCString("VAnd");
        if (op.equals(String.withCString("Or")))
            return String.withCString("VOr");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("VXor");
        if (op.equals(String.withCString("FSqrt")))
            return String.withCString("VSqrt");
        if (op.equals(String.withCString("FDiv")))
            return String.withCString("VDiv");
        return op;
        }

    // Lane types the map vectoriser handles: 8/16/32-bit integer (same-width
    // wrapping arithmetic) or 32-bit float. Float REDUCTIONS need an
    // associativity the source language does not grant, so they are not here.
    final bool vecLaneOK(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("F32"));
        }

    // A compile-time integer through Const and the width casts.
    // The 64-bit form, for a loop BOUND. The narrow one below truncates, and a
    // u32 bound above 2^31 then reads as negative — which the `n <= 0` guards
    // took for "not a constant loop" and refused. Everything else it is asked
    // for (a step, a shift, a delta) is genuinely small and keeps the narrow
    // form. The reference uses int64_t on this path throughout.
    final bool vecConstWide(IROperand* op, Map* defOf, i64* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
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
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* a = (IROperand*)def.ops().get((u32)0);
            if (def.op().equals(String.withCString("Const")))
                {
                if (a.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = a.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (a.kind() == (u8)OPK_IMMI)
                {
                out[0] = a.imm();
                return true;
                }
            if (a.kind() != (u8)OPK_USE)
                return false;
            cur = a.val();
            }
        return false;
        }

    final bool vecConstExt(IROperand* op, Map* defOf, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
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
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* a = (IROperand*)def.ops().get((u32)0);
            if (def.op().equals(String.withCString("Const")))
                {
                if (a.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = a.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (a.kind() == (u8)OPK_IMMI)
                {
                out[0] = a.imm();
                return true;
                }
            if (a.kind() != (u8)OPK_USE)
                return false;
            cur = a.val();
            }
        return false;
        }

    final bool vecFoldConst(IROperand* op, Map* defOf, u32 depth, i64* out)
        {
        i32 k = (i32)0;
        if (vecConstExt(op, defOf, &k))
            {
            out[0] = (i64)k;
            return true;
            }
        if (depth > (u32)8 || op.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)op.val());
        if (d == (IRInsn*)0 || d.ops().count() != (u32)2)
            return false;
        String* o = d.op();
        bool add = o.equals(String.withCString("Add"));
        bool sub = o.equals(String.withCString("Sub"));
        bool mul = o.equals(String.withCString("Mul"));
        bool band = o.equals(String.withCString("And"));
        bool bor = o.equals(String.withCString("Or"));
        bool bxor = o.equals(String.withCString("Xor"));
        bool shl = o.equals(String.withCString("Shl"));
        bool shr = o.equals(String.withCString("LShr"));
        if (!add && !sub && !mul && !band && !bor && !bxor && !shl && !shr)
            return false;
        i64 a = (i64)0;
        i64 b = (i64)0;
        if (!vecFoldConst((IROperand*)d.ops().get((u32)0), defOf, depth + (u32)1, &a)
            || !vecFoldConst((IROperand*)d.ops().get((u32)1), defOf, depth + (u32)1, &b))
            return false;
        i64 lim = (i64)2147483647;
        if (a < (i64)0 || a > lim || b < (i64)0 || b > lim)
            return false;
        i64 r = (i64)0;
        if (add) r = a + b;
        else if (sub) r = a - b;
        else if (mul) r = a * b;
        else if (band) r = a & b;
        else if (bor) r = a | b;
        else if (bxor) r = a ^ b;
        else if (shl)
            {
            if (b > (i64)30)
                return false;
            r = a << b;
            }
        else
            {
            if (b > (i64)30)
                return false;
            r = a >> b;
            }
        if (r < (i64)0 || r > lim)
            return false;
        out[0] = r;
        return true;
        }

    // Epilogue part 2 for a MAP: the vector loop falls into the remainder
    // through a LANDING PAD that does nothing but branch.
    //
    // The empty block is load-bearing. Sending the vector loop straight to H2
    // looks right — a map carries nothing out but the induction variable, which
    // enters as the constant M — and it works until loop rotation gives the
    // vector loop its SECOND exit (the body's own back-edge test). That edge
    // then lands on a phi-carrying header with no incoming for it, so the iv is
    // undefined on entry and the remainder is skipped:
    //     for (i = 0; i < 5; i++) b[i] = a[i] * 3;
    // wrote four elements and left the fifth untouched. One pred keeps H2's
    // phis well-formed however the loop is later reshaped. The reduction
    // epilogue gets this for free — its VE is where the reduce lands.
    // Pinned by tests/fixtures/vectorize_map_tail.xc.
    final void vecMapEpilogue(IRFunc* fn, VecCand* c, IRBlock* H2, IRBlock* B2, Map* cmap)
        {
        IRBlock* H = c.h();
        IRBlock* E2 = c.e();
        IRBlock* PH = c.pre();
        IRBlock* VE = new IRBlock(hoistName2(H.name(), "_vexit"));
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H2));
        VE.setTerm(br);

        // The vector loop exits to VE instead of E.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == E2)
                t.ops().set(k, (Object*)IROperand.block(VE));
            }

        // Seed the clone: its iv enters at M, on the edge from VE — which is
        // where the clone's phis still name the ORIGINAL preheader.
        Object* ivC = cmap.get((Hashable*)c.ivPhi().res());
        for (u32 k = (u32)0; k < H2.phis().count(); k = k + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(k);
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(q);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != PH)
                    continue;
                phi.ops().set(q, (Object*)IROperand.block(VE));
                if (ivC != (Object*)0 && phi.res() == (IRValue*)ivC)
                    phi.ops().set(q + (u32)1, c.rtTrip()
                                                  ? (Object*)IROperand.useVal(_vecMapRtM)
                                                  : (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
                }
            }

        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == c.b())
                at = k + (u32)1;
        Array* three = new Array();
        three.add((Object*)VE);
        three.add((Object*)H2);
        three.add((Object*)B2);
        fn.blocks().insertAll(at, three);
        }

    // The header's predecessor that is not the latch.
    final IRBlock* vecHeaderPred(IRFunc* fn, IRBlock* H, IRBlock* B)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == B || bb.term() == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)bb.term().ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == H)
                    return bb;
                }
            }
        return (IRBlock*)0;
        }

    // An iv-indexed narrow load feeding only the multiply. The lane must be u16
    // — VMul has no 8-bit-lane form.
    final IRInsn* vecDotLoad(IRValue* v, IRValue* iv, IRBlock* B,
                       Map* defOf, Map* defBlk, Map* uses)
        {
        Object* o = defOf.get((Hashable*)v);
        Object* b = defBlk.get((Hashable*)v);
        if (o == (Object*)0 || b == (Object*)0 || (IRBlock*)b != B)
            return (IRInsn*)0;
        IRInsn* ld = (IRInsn*)o;
        if (!ld.op().equals(String.withCString("Load")) || ld.res() == (IRValue*)0 || self.countOf(uses, v) != (u32)1 || ld.ops().count() < (u32)1)
            return (IRInsn*)0;
        if (ld.res().ty() == (String*)0 || !ld.res().ty().equals(String.withCString("U16")))
            return (IRInsn*)0;
        if (!vecIsElemAddr((IROperand*)ld.ops().get((u32)0), iv, defOf))
            return (IRInsn*)0;
        return ld;
        }

    // The phi's incoming block on the latch side (or the preheader side). The
    // back-edge source is the one that FOLLOWS the header in block order.
    final IRBlock* vecIncoming(IRFunc* fn, IRInsn* phi, u32 idxH, bool wantLatch)
        {
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        if (b0 == (IRBlock*)0 || b1 == (IRBlock*)0)
            return (IRBlock*)0;
        if (!self.hasBlock(fn.blocks(), b0) || !self.hasBlock(fn.blocks(), b1))
            return (IRBlock*)0;
        bool b0latch = self.blockIndex(fn, b0) > idxH;
        if (wantLatch)
            return b0latch ? b0 : b1;
        return b0latch ? b1 : b0;
        }

    // ── Count reduction ──────────────────────────────────────────────────
    //
    // `for (i<N) if (a[i] <cmp> k) n += delta` arrives if-converted to a Select,
    // so the body is a single block and the accumulator's back-edge value is
    // Select(cmp, Add(acc, delta), acc). Ported to close a real parity gap: the
    // original has SIX recognisers and this port had five, and no differential
    // could see it, because not one file in the tree has this loop shape (#1131).
    //
    // Split into helpers from the outset rather than after the fact: every
    // recogniser here sits within a few hundred bytes of the 16 KB arm64 frame
    // ceiling, and six functions had to be carved up today to get back under it.

    final i32 vecBlockIndex(IRFunc* fn, IRBlock* b)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b)
                return (i32)i;
        return (i32)-1;
        }

    // The latch is the header predecessor that comes AFTER the header in block
    // order; the preheader is the other one.
    final IRBlock* vecCountEdge(IRFunc* fn, IRInsn* phi, IRBlock* H, bool wantLatch)
        {
        if (phi.ops().count() < (u32)4)
            return (IRBlock*)0;
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        i32 i0 = vecBlockIndex(fn, b0);
        i32 i1 = vecBlockIndex(fn, b1);
        if (i0 < (i32)0 || i1 < (i32)0)
            return (IRBlock*)0;
        bool b0latch = i0 > vecBlockIndex(fn, H);
        if (wantLatch)
            return b0latch ? b0 : b1;
        return b0latch ? b1 : b0;
        }

    // The guard target that leads into the loop: the latch itself when the body
    // is merged, otherwise a single-successor block branching to it.
    final bool vecCountLeadsTo(IRBlock* b, IRBlock* L, IRBlock* H)
        {
        if (b == L)
            return true;
        if (b == (IRBlock*)0 || b == H)
            return false;
        if (b.phis().count() != (u32)0)
            return false;
        if (b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == L;
        }

    final bool vecCountAccRead(IRBlock* bb, IRValue* acc)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n == _vcAccNext || n == _vcIncr)
                continue;
            if (insnUsesValue(n, acc))
                return true;
            }
        return false;
        }

    // The diamond head: address, load, compare, conditional branch — and
    // nothing else. Returns the loaded element, or null.
    final IRValue* vecMaxMinHead(IRBlock* B, IRValue* iv, Map* defOf)
        {
        IRValue* elem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
                {
                if (n.ops().count() < (u32)2)
                    return (IRValue*)0;
                IROperand* idx = (IROperand*)n.ops().get((u32)1);
                if (idx.kind() != (u8)OPK_USE || idx.val() != iv)
                    return (IRValue*)0;
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (IRValue*)0;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (IRValue*)0;
                if (!vecRedux32(n.res().ty()))
                    return (IRValue*)0;
                elem = n.res();
                continue;
                }
            if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return (IRValue*)0;
            }
        return elem;
        }

    // The then arm holds nothing but a reload, and the join's arms are
    // (body → accumulator, then → element): the `if (cmp) m = a[i]` shape.
    final bool vecMaxMinArms(IRBlock* B, IRBlock* TH, IRBlock* L, IRValue* iv,
                       IRValue* acc, IRValue* elem, Map* defOf, Map* defBlk)
        {
        if (TH.phis().count() != (u32)0 || TH.term() == (IRInsn*)0 || !TH.term().op().equals(String.withCString("Branch")) || TH.term().ops().count() < (u32)1 || ((IROperand*)TH.term().ops().get((u32)0)).blk() != L)
            return false;
        for (u32 i = (u32)0; i < TH.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)TH.insns().get(i)).op();
            if (!op.equals(String.withCString("AddrOf")) && !op.equals(String.withCString("ElementAddr")) && !op.equals(String.withCString("Load")))
                return false;
            }
        IROperand* armFromB = vecArmFrom(_mmJoinPhi, B);
        IROperand* armFromTH = vecArmFrom(_mmJoinPhi, TH);
        if (armFromB == (IROperand*)0 || armFromB.kind() != (u8)OPK_USE || armFromB.val() != acc)
            return false;
        if (armFromTH == (IROperand*)0 || armFromTH.kind() != (u8)OPK_USE)
            return false;
        if (armFromTH.val() == elem)
            return true;
        Object* ro = defOf.get((Hashable*)armFromTH.val());
        Object* rb = defBlk.get((Hashable*)armFromTH.val());
        if (ro == (Object*)0 || rb == (Object*)0 || (IRBlock*)rb != TH)
            return false;
        IRInsn* rl = (IRInsn*)ro;
        if (!rl.op().equals(String.withCString("Load")) || rl.ops().count() < (u32)1)
            return false;
        return vecIsElemAddr((IROperand*)rl.ops().get((u32)0), iv, defOf);
        }

    // Every value a block defines — results and memory results alike.
    final void vecCollectDefs(Array* out, IRBlock* bb)
        {
        if (bb == (IRBlock*)0)
            return;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                out.add((Object*)n.memRes());
            if (n.res() != (IRValue*)0)
                out.add((Object*)n.res());
            }
        }

    final void vecRewireGone(IRInsn* n, Array* gone, IRValue* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || !self.hasValue(gone, o.val()))
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // The phi arm paired with a given incoming block.
    final IROperand* vecArmFrom(IRInsn* phi, IRBlock* from)
        {
        if (((IROperand*)phi.ops().get((u32)0)).blk() == from)
            return (IROperand*)phi.ops().get((u32)1);
        if (((IROperand*)phi.ops().get((u32)2)).blk() == from)
            return (IROperand*)phi.ops().get((u32)3);
        return (IROperand*)0;
        }

    // A RUNTIME bound. The vectoriser emitted `M = n & ~(vw-1)`, and the unroll
    // needs the trip to be a whole number of U vectors -- so widen that mask to
    // ~(U*vw-1) and it is one by construction. Nothing else changes: the guard
    // and the scalar clone's induction seed are the SAME value, so lowering M
    // moves both, and the clone already runs [M, n) -- the tail merely gets up
    // to U*vw-1 elements instead of vw-1.
    //
    // Refused (returns 1) unless the mask is EXACTLY the one the vectoriser
    // built: any other bound is one this pass does not understand, and
    // rewriting it would change the loop's trip count. EXTRACTED for the arm64
    // frame budget -- inline, vecUnrollAt needed 20032 bytes against 16384.
    // The vector registers the back end has for fn: 14 (arm64 v18-v31, x86
    // xmm/ymm 2-15), or 22 on arm64 in a function with no float scalars, where
    // the FP allocator's homes v8-v15 are free (the arm64 back end then takes
    // them). As the reference's vecPoolFor.
    final u32 vecPoolFor(IRFunc* fn)
        {
        if (!_profile.bitSelect())
            return (u32)14;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 part = (u32)0; part < (u32)2; part = part + (u32)1)
                {
                Array* list = part == (u32)0 ? bb.phis() : bb.insns();
                for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)list.get(i);
                    if (n.res() != (IRValue*)0 && vcFloatTy(n.res().ty()))
                        return (u32)14;
                    for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)n.ops().get(k);
                        if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && vcFloatTy(o.val().ty()))
                            return (u32)14;
                        }
                    }
                }
            }
        return (u32)22;
        }

    final bool vcFloatTy(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
        }

    final bool vcVecTy(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Vec("));
        }

    // Would two interleaved copies of B's vector work fit the back end's pool?
    // A sweep of B in order: each vector value B defines is live from its
    // definition to its last use in B, twice over when it depends on the iv
    // (its clone stands next to it); the two accumulators, and every vector B
    // reads from outside (a preheader splat, the iota load), are live
    // throughout. A VAdd takes the register of an operand that dies at it
    // (the back ends' reuse); anything else needs its own while its operands
    // live. The back ends do not spill a vector and an overflow is a build
    // error, so this is an upper bound. As the reference's vecInterleaveFits.
    final bool vecInterleaveFits(IRFunc* fn, IRBlock* B, IRValue* vacc, IRValue* iv, IRInsn* ivNextInsn, u32 pool)
        {
        u32 n = B.insns().count();
        Map* dep = new Map();
        dep.set((Hashable*)iv, (Object*)iv);
        dep.set((Hashable*)vacc, (Object*)vacc);
        Map* inB = new Map();
        Map* lastUse = new Map();
        Map* outside = new Map();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)B.insns().get(i);
            if (insn == ivNextInsn)
                continue;
            bool d = false;
            for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                lastUse.set((Hashable*)o.val(), (Object*)Number.with(i));
                if (dep.get((Hashable*)o.val()) != (Object*)0)
                    d = true;
                if (vcVecTy(o.val().ty()) && o.val() != vacc && inB.get((Hashable*)o.val()) == (Object*)0)
                    outside.set((Hashable*)o.val(), (Object*)o.val());
                }
            if (insn.res() != (IRValue*)0)
                {
                inB.set((Hashable*)insn.res(), (Object*)insn.res());
                if (d)
                    dep.set((Hashable*)insn.res(), (Object*)insn.res());
                }
            }
        u32 live = (u32)2;
        u32 peak = live;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            IRInsn* insn = (IRInsn*)B.insns().get(i);
            if (insn == ivNextInsn)
                continue;
            u32 dying = (u32)0;
            for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)insn.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || o.val() == vacc
                    || inB.get((Hashable*)o.val()) == (Object*)0)
                    continue;
                Object* lu = lastUse.get((Hashable*)o.val());
                if (!vcVecTy(o.val().ty()) || lu == (Object*)0 || ((Number*)lu).asU32() != i)
                    continue;
                lastUse.set((Hashable*)o.val(), (Object*)Number.with(n));
                dying = dying + (dep.get((Hashable*)o.val()) != (Object*)0 ? (u32)2 : (u32)1);
                }
            bool vecDef = insn.res() != (IRValue*)0 && vcVecTy(insn.res().ty());
            u32 born = vecDef ? (dep.get((Hashable*)insn.res()) != (Object*)0 ? (u32)2 : (u32)1) : (u32)0;
            if (insn.op().equals(String.withCString("VAdd")) && dying > (u32)0)
                {
                live = live + born - dying;
                if (live > peak)
                    peak = live;
                }
            else
                {
                live = live + born;
                if (live > peak)
                    peak = live;
                live = live - dying;
                }
            }
        return peak + outside.count() <= pool;
        }

    // The vectoriser's runtime limit mask `n & ~(vw-1)`, the guard's bound
    // or, for a loop from a start s (a par block's run over [lo, hi)), under
    // the Add of `((n - s) & ~(vw-1)) + s`: widening it keeps the trip from s
    // a whole number of U vectors. Null for any other bound.
    final IRInsn* vecRuntimeMask(IRInsn* guard, Map* defOf, u32 vw)
        {
        IROperand* gb = (IROperand*)guard.ops().get((u32)1);
        if (gb.kind() != (u8)OPK_USE)
            return (IRInsn*)0;
        Object* mo = defOf.get((Hashable*)gb.val());
        if (mo == (Object*)0)
            return (IRInsn*)0;
        IRInsn* mask = (IRInsn*)mo;
        if (mask.op().equals(String.withCString("Add")) && mask.ops().count() == (u32)2)
            {
            IROperand* a0 = (IROperand*)mask.ops().get((u32)0);
            IROperand* a1 = (IROperand*)mask.ops().get((u32)1);
            IRInsn* m0 = a0.kind() == (u8)OPK_USE ? (IRInsn*)defOf.get((Hashable*)a0.val()) : (IRInsn*)0;
            IRInsn* m1 = a1.kind() == (u8)OPK_USE ? (IRInsn*)defOf.get((Hashable*)a1.val()) : (IRInsn*)0;
            if (m0 != (IRInsn*)0 && m0.op().equals(String.withCString("And")))
                mask = m0;
            else if (m1 != (IRInsn*)0 && m1.op().equals(String.withCString("And")))
                mask = m1;
            }
        if (!mask.op().equals(String.withCString("And")) || mask.ops().count() < (u32)2)
            return (IRInsn*)0;
        IROperand* mi = (IROperand*)mask.ops().get((u32)1);
        if (mi.kind() != (u8)OPK_IMMI)
            return (IRInsn*)0;
        if (mi.imm() != (i64) ~((i32)vw - (i32)1))
            return (IRInsn*)0;
        return mask;
        }

    // The lane of a vector type, `Vec(L)` or `Vec(L, bytes)`; null for any other.
    final String* vuLaneOf(String* t)
        {
        if (t == (String*)0 || !t.hasPrefix(String.withCString("Vec(")) || !t.hasSuffix(String.withCString(")")))
            return (String*)0;
        String* inner = t.substringFromByte((u32)4);
        String* lane = inner.substringToByte(inner.byteLength() - (u32)1);
        for (u32 i = (u32)0; i < lane.byteLength(); i = i + (u32)1)
            {
            if (lane.byteAt(i) == (u8)'(')
                return (String*)0;
            if (lane.byteAt(i) == (u8)',')
                return lane.substringToByte(i);
            }
        return lane;
        }

    // One extra accumulator: its zeroed init in the preheader, its own iv offset,
    // and a clone of the iv-dependent chain with iv → iv+k*vw and vacc → vacc_k.
    final void vecUnrollCopy(u32 k, i32 vw, String* ivTy, String* vecTy,
                       IRValue* iv, IRValue* vacc, IRBlock* B, IRBlock* PH,
                       IRInsn* initInsn, IRInsn* vnextInsn, Array* ivDep,
                       Array* appended, Array* newPhis, Array* accs, bool bigBody)
        {
        IRValue* vaccK = new IRValue(vecTy);
        // All U accumulators start from the SAME preheader broadcast — reuse
        // copy 0's VSplat rather than cloning it per copy. U-1 phi copies
        // replace U-1 live splats, which is what keeps the backends'
        // 8-register vector pools from overflowing (#1198).
        IRValue* ivK = new IRValue(ivTy);
        IRInsn* ia = IRInsn.with(String.withCString("Add"));
        ia.setRes(ivK);
        ia.add(IROperand.useVal(iv));
        ia.add(IROperand.immI((i32)k * vw, ivTy));
        appended.add((Object*)ia);
        u32 copyStart = appended.count() - (u32)1; // iv_k's index
        IRValue* offK = (IRValue*)0;    // copy k's k*vw splat, once made
        Map* offVals = new Map();         // copy 0 values whose copy k is them + k*vw

        Map* remap = new Map();
        remap.set((Hashable*)iv, (Object*)ivK);
        remap.set((Hashable*)vacc, (Object*)vaccK);
        IRValue* vnextK = (IRValue*)0;
        // The values that depend on iv: iv itself and every result in ivDep.
        Map* dep = new Map();
        dep.set((Hashable*)iv, (Object*)iv);
        for (u32 i = (u32)0; i < ivDep.count(); i = i + (u32)1)
            {
            IRInsn* dn = (IRInsn*)ivDep.get(i);
            if (dn.res() != (IRValue*)0)
                dep.set((Hashable*)dn.res(), (Object*)dn);
            }
        // A VSplat(iv) whose one use is the lane-index VAdd rewritten below is
        // not cloned at all, outside a big body (whose clones pair with their
        // originals by position): left in, it was still emitted, a broadcast
        // nothing reads, every block. Mirrors the original.
        Map* skipSplat = new Map();
        if (!bigBody)
            {
            Map* uses = new Map();
            for (u32 i = (u32)0; i < ivDep.count(); i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)ivDep.get(i);
                for (u32 j = (u32)0; j < u.ops().count(); j = j + (u32)1)
                    {
                    IROperand* o = (IROperand*)u.ops().get(j);
                    if (o.kind() != (u8)OPK_USE)
                        continue;
                    Number* c = (Number*)uses.get((Hashable*)o.val());
                    uses.set((Hashable*)o.val(), (Object*)Number.with(c == (Number*)0 ? (u32)1 : c.asU32() + (u32)1));
                    }
                }
            for (u32 i = (u32)0; i < ivDep.count(); i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)ivDep.get(i);
                if (!u.op().equals(String.withCString("VAdd")) || u.res() == (IRValue*)0 || u.ops().count() != (u32)2)
                    continue;
                for (u32 q = (u32)0; q < (u32)2; q = q + (u32)1)
                    {
                    IROperand* sOp = (IROperand*)u.ops().get(q);
                    IROperand* oOp = (IROperand*)u.ops().get((u32)1 - q);
                    if (sOp.kind() != (u8)OPK_USE || oOp.kind() != (u8)OPK_USE)
                        continue;
                    Object* sdo = dep.get((Hashable*)sOp.val());
                    if (sdo == (Object*)0 || sdo == (Object*)iv)
                        continue;
                    IRInsn* sd = (IRInsn*)sdo;
                    if (!sd.op().equals(String.withCString("VSplat")) || sd.ops().count() < (u32)1)
                        continue;
                    IROperand* so = (IROperand*)sd.ops().get((u32)0);
                    if (so.kind() != (u8)OPK_USE || so.val() != iv)
                        continue;
                    if (dep.get((Hashable*)oOp.val()) != (Object*)0 || vuLaneOf(u.res().ty()) == (String*)0)
                        continue;
                    Number* c = (Number*)uses.get((Hashable*)sOp.val());
                    if (c != (Number*)0 && c.asU32() == (u32)1)
                        skipSplat.set((Hashable*)sOp.val(), (Object*)sOp.val());
                    }
                }
            }
        for (u32 i = (u32)0; i < ivDep.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)ivDep.get(i);
            if (n.res() != (IRValue*)0 && skipSplat.get((Hashable*)n.res()) != (Object*)0)
                continue;
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            // The lane-index vector, VAdd(VSplat(iv), iota): copy k's is copy
            // 0's plus a constant k*vw splat made once in the preheader, not a
            // broadcast of iv+k*vw rebuilt every block (call_depth, 2026-11-01:
            // zero, move, broadcast, two adds per block). Copy k's own VSplat
            // is still cloned, so the clones stay in step with their originals,
            // and dead-code drops it. Mirrors the original.
            IRValue* ivSplatK = (IRValue*)0;
            // Further along the same chain: VAdd(a value that is copy 0's plus
            // k*vw, an invariant) is copy 0's result plus k*vw too, so the
            // seed's add is folded into copy 0's and copy k pays one add, not
            // two (as clang's base + 16k vectors). Mirrors the original.
            if (!bigBody && offK != (IRValue*)0 && n.op().equals(String.withCString("VAdd")) && n.res() != (IRValue*)0 && n.ops().count() == (u32)2)
                for (u32 q = (u32)0; q < (u32)2 && ivSplatK == (IRValue*)0; q = q + (u32)1)
                    {
                    IROperand* aOp = (IROperand*)n.ops().get(q);
                    IROperand* oOp = (IROperand*)n.ops().get((u32)1 - q);
                    if (aOp.kind() == (u8)OPK_USE && offVals.get((Hashable*)aOp.val()) != (Object*)0
                        && oOp.kind() == (u8)OPK_USE && dep.get((Hashable*)oOp.val()) == (Object*)0
                        && n.res().ty().equals(offK.ty()))
                        ivSplatK = offK;
                    }
            // Not in a big body (MD5's rounds): it rebuilds its lane values next
            // to their uses on purpose, to keep its vector registers for its own
            // values (vecRematLanes). Mirrors the original.
            if (!bigBody && ivSplatK == (IRValue*)0 && n.op().equals(String.withCString("VAdd")) && n.res() != (IRValue*)0 && n.ops().count() == (u32)2)
                for (u32 q = (u32)0; q < (u32)2 && ivSplatK == (IRValue*)0; q = q + (u32)1)
                    {
                    IROperand* sOp = (IROperand*)n.ops().get(q);
                    IROperand* oOp = (IROperand*)n.ops().get((u32)1 - q);
                    if (sOp.kind() != (u8)OPK_USE || oOp.kind() != (u8)OPK_USE)
                        continue;
                    Object* sdo = dep.get((Hashable*)sOp.val());
                    if (sdo == (Object*)0 || sdo == (Object*)iv)
                        continue;
                    IRInsn* sd = (IRInsn*)sdo;
                    if (!sd.op().equals(String.withCString("VSplat")) || sd.ops().count() < (u32)1)
                        continue;
                    IROperand* so = (IROperand*)sd.ops().get((u32)0);
                    if (so.kind() != (u8)OPK_USE || so.val() != iv)
                        continue;
                    if (dep.get((Hashable*)oOp.val()) != (Object*)0)
                        continue;
                    String* lane = vuLaneOf(n.res().ty());
                    if (lane == (String*)0)
                        continue;
                    IRValue* kc = new IRValue(lane);
                    IRInsn* kci = IRInsn.with(String.withCString("Const"));
                    kci.setRes(kc);
                    kci.add(IROperand.immI((i32)k * vw, lane));
                    PH.insns().add((Object*)kci);
                    ivSplatK = new IRValue(n.res().ty());
                    IRInsn* ksp = IRInsn.with(String.withCString("VSplat"));
                    ksp.setRes(ivSplatK);
                    ksp.add(IROperand.useVal(kc));
                    PH.insns().add((Object*)ksp);
                    }
            if (ivSplatK != (IRValue*)0)
                {
                cl.add(IROperand.useVal(n.res()));
                cl.add(IROperand.useVal(ivSplatK));
                offK = ivSplatK;
                offVals.set((Hashable*)n.res(), (Object*)n.res());
                }
            else
            for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(j);
                Object* r = o.kind() == (u8)OPK_USE
                                ? remap.get((Hashable*)o.val())
                                : (Object*)0;
                cl.add(r == (Object*)0 ? o : IROperand.useVal((IRValue*)r));
                }
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                remap.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                cl.setMemRes(new IRValue(String.withCString("Mem")));
            appended.add((Object*)cl);
            if (n == vnextInsn)
                vnextK = cl.res();
            }
        if (!bigBody)
            {
            // This copy's clones nothing reads, the VAdds the fold above
            // bypassed: dead-code keeps vector ops, so they go here.
            bool again = true;
            while (again)
                {
                again = false;
                for (u32 q = appended.count(); q > copyStart + (u32)1; q = q - (u32)1)
                    {
                    IRInsn* cn = (IRInsn*)appended.get(q - (u32)1);
                    if (cn.res() == (IRValue*)0 || cn.res() == vnextK
                        || !(cn.op().equals(String.withCString("VAdd")) || cn.op().equals(String.withCString("VSplat"))))
                        continue;
                    bool read = false;
                    for (u32 r = copyStart; r < appended.count() && !read; r = r + (u32)1)
                        {
                        IRInsn* rn = (IRInsn*)appended.get(r);
                        for (u32 j = (u32)0; j < rn.ops().count(); j = j + (u32)1)
                            {
                            IROperand* o = (IROperand*)rn.ops().get(j);
                            if (o.kind() == (u8)OPK_USE && o.val() == cn.res())
                                read = true;
                            }
                        }
                    if (!read)
                        {
                        appended.removeAt(q - (u32)1);
                        again = true;
                        }
                    }
                }
            }
        if (!bigBody)
            {
            bool ivkRead = false;
            for (u32 q = copyStart + (u32)1; q < appended.count() && !ivkRead; q = q + (u32)1)
                {
                IRInsn* an = (IRInsn*)appended.get(q);
                for (u32 j = (u32)0; j < an.ops().count(); j = j + (u32)1)
                    {
                    IROperand* o = (IROperand*)an.ops().get(j);
                    if (o.kind() == (u8)OPK_USE && o.val() == ivK)
                        ivkRead = true;
                    }
                }
            if (!ivkRead)
                appended.removeAt(copyStart);
            }
        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
        ph.setRes(vaccK);
        ph.add(IROperand.block(PH));
        ph.add(IROperand.useVal(initInsn.res()));
        ph.add(IROperand.block(B));
        ph.add(IROperand.useVal(vnextK));
        newPhis.add((Object*)ph);
        accs.add((Object*)vaccK);
        }

    final void vecUnrollSplice(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E,
                         IRValue* iv, IRValue* vacc, String* vecTy,
                         IRInsn* ivNextInsn, IRInsn* vnextInsn, String* ivTy,
                         i32 vw, u32 U, Array* appended, Array* newPhis, Array* accs,
                         Array* interleave)
        {
        // The clones go at the END of the body, after copy 0's whole chain, so
        // the loop-invariant values copy 0 computes mid-body are defined before
        // the clones that share them. The iv step is order-independent — it
        // reads only the phi. A big body's (U = 2, `interleave` its iv chain)
        // go each straight after its original instead: the shared values an
        // original reads come before it, so before its clone too.
        if (interleave != (Array*)0)
            {
            Array* il = new Array();
            il.add(appended.get((u32)0));
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                il.add((Object*)n);
                for (u32 j = (u32)0; j < interleave.count(); j = j + (u32)1)
                    if ((IRInsn*)interleave.get(j) == n)
                        {
                        il.add(appended.get(j + (u32)1));
                        break;
                        }
                }
            B.insns().removeAll();
            for (u32 i = (u32)0; i < il.count(); i = i + (u32)1)
                B.insns().add(il.get(i));
            }
        else
            for (u32 i = (u32)0; i < appended.count(); i = i + (u32)1)
                B.insns().add(appended.get(i));
        for (u32 j = (u32)0; j < ivNextInsn.ops().count(); j = j + (u32)1)
            {
            IROperand* o = (IROperand*)ivNextInsn.ops().get(j);
            if (o.kind() == (u8)OPK_IMMI || (o.kind() == (u8)OPK_USE && o.val() != iv))
                ivNextInsn.ops().set(j, (Object*)IROperand.immI((i32)U * vw, ivTy));
            }
        for (u32 i = (u32)0; i < newPhis.count(); i = i + (u32)1)
            H.addPhi((IRInsn*)newPhis.get(i));

        // Combine the copies at the exit with the reduction's own op, then point
        // the existing horizontal reduce at the combined accumulator.
        Array* combine = new Array();
        IRValue* cur = vacc;
        for (u32 k = (u32)1; k < U; k = k + (u32)1)
            {
            IRValue* r = new IRValue(vecTy);
            IRInsn* cb = IRInsn.with(vnextInsn.op());
            cb.setRes(r);
            cb.add(IROperand.useVal(cur));
            cb.add(IROperand.useVal((IRValue*)accs.get(k)));
            combine.add((Object*)cb);
            cur = r;
            }
        for (u32 i = (u32)0; i < combine.count(); i = i + (u32)1)
            E.insns().insert(i, combine.get(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (hasInsn(combine, n))
                    continue;
                vecReplaceUse(n, vacc, cur, (IRInsn*)0);
                }
            }
        }

    // The bound comes from the candidate, NOT from re-reading the guard: the
    // guard's bound is a USE of a Const, not an immediate operand, so reading it
    // here returned nothing and an earlier version quietly set needEpi=false --
    // which vectorised a 100-element loop with no remainder and stepped clean
    // past the end. Recording n at recognition time removes the guess.
    final void vecSetEpi(VecCand* c)
        {
        // A RUNTIME bound always takes the epilogue and has no compile-time M:
        // the limit is computed in the preheader instead.
        if (c.rtTrip())
            {
            c.setEpi(true, (i32)0);
            return;
            }
        // M is the last whole-vector boundary of the trip LENGTH `n - ivStart`,
        // rebased onto the start — `n - n%vw` was right only for a zero start.
        i64 n = _vrN;
        i64 trip = n - _vrIvStart;
        i64 m = _vrIvStart + (trip - (trip % (i64)c.vw()));
        c.setEpi(m != n, m);
        }

    // The zeroed vector accumulator in the preheader and the phi that replaces
    // the scalar one in the header.
    final void vecZeroSeedPhi(VecCand* c, IRBlock* H, IRBlock* B, IRBlock* PH,
                        String* accVecTy, String* u32t,
                        IRValue* vacc, IRValue* vnext)
        {
        IRValue* vacc0 = new IRValue(accVecTy);
        IRValue* zero = new IRValue(u32t);
        IRInsn* zc = IRInsn.with(String.withCString("Const"));
        zc.setRes(zero);
        zc.add(IROperand.immI((i32)0, u32t));
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(vacc0);
        sp.add(IROperand.useVal(zero));
        PH.insns().add((Object*)zc);
        PH.insns().add((Object*)sp);
        IRInsn* vphi = IRInsn.with(String.withCString("Phi"));
        vphi.setRes(vacc);
        vphi.add(IROperand.block(PH));
        vphi.add(IROperand.useVal(vacc0));
        vphi.add(IROperand.block(B));
        vphi.add(IROperand.useVal(vnext));
        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            newPhis.add(p == c.accPhi() ? (Object*)vphi : (Object*)p);
            }
        H.setPhis(newPhis);
        }

    // Rebuild the widening body: the narrow loads become vector loads, and the
    // scalar multiply and widening are dropped (replaced by VMul / VAddLP).
    // Returns [vload, vload2].
    final Array* vecWideningLoads(VecCand* c, IRBlock* B, IRValue* mul, IRValue* zxSrc,
                            String* loadVecTy, Array* nb)
        {
        IRValue* vload = (IRValue*)0;
        IRValue* vload2 = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.accNext())
                continue; // the scalar accumulate goes
            if (c.isDot() && n.res() != (IRValue*)0 && n.res() == mul)
                continue; // → VMul
            if (n.res() != (IRValue*)0 && (n.res() == c.load() || (c.isDot() && n.res() == c.load2())))
                {
                IRValue* vl = new IRValue(loadVecTy);
                IRInsn* vi = IRInsn.with(String.withCString("VLoad"));
                vi.copyDbg(n);
                vi.setRes(vl);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vi.add((IROperand*)n.ops().get(k));
                vi.setMemRes(n.memRes());
                nb.add((Object*)vi);
                if (n.res() == c.load())
                    vload = vl;
                else
                    vload2 = vl;
                continue;
                }
            if (n.op().equals(String.withCString("ZExt")) && n.ops().count() >= (u32)1)
                {
                IROperand* zs = (IROperand*)n.ops().get((u32)0);
                if (zs.kind() == (u8)OPK_USE && zs.val() == zxSrc)
                    continue; // replaced
                }
            nb.add((Object*)n); // address, iv step, constants
            }
        Array* out = new Array();
        out.add((Object*)vload);
        out.add((Object*)vload2);
        return out;
        }

    // Rebuild the diamond head as the loop's single straight-line vector latch.
    final bool vecMaxMinLatch(VecCand* c, IRBlock* B, IRBlock* H, String* vecTy,
                        IRValue* vacc, IRValue* vload, IRValue* vnext,
                        IRValue* ivNextV)
        {
        Array* nb = new Array();
        bool sawLoad = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.op().equals(String.withCString("Load")) && n.res() == c.elem())
                {
                sawLoad = true;
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.copyDbg(n);
                vl.setRes(vload);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k));
                vl.setMemRes(n.memRes());
                nb.add((Object*)vl);
                continue;
                }
            if (n.op().equals(String.withCString("AddrOf")) || n.op().equals(String.withCString("ElementAddr")) || n.op().equals(String.withCString("Const")))
                nb.add((Object*)n); // the address plumbing stays
            // The compare and the casts are dropped — folded into the vector op.
            }
        if (!sawLoad)
            return false;

        IRInsn* vop = IRInsn.with(c.isMax() ? String.withCString("VMax")
                                            : String.withCString("VMin"));
        vop.setRes(vnext);
        vop.add(IROperand.useVal(vacc));
        vop.add(IROperand.useVal(vload));
        nb.add((Object*)vop);

        IRInsn* ia = IRInsn.with(String.withCString("Add"));
        ia.setRes(ivNextV);
        ia.add(IROperand.useVal(c.iv()));
        ia.add(IROperand.immI((i32)c.vw(), c.ivNext().res().ty()));
        nb.add((Object*)ia);
        B.setInsns(nb);
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        B.setTerm(br);
        return true;
        }

    // The reduction rewrite: the scalar accumulator phi becomes a VECTOR one
    // seeded with zeroed lanes in the preheader, the body accumulates into it,
    // and the exit block horizontally reduces it back to a scalar.
    // M = ivStart + (max(n - ivStart, 0) & ~(vw-1)), emitted into the
    // preheader. The old form, M = n & ~(vw-1), rounded the BOUND down instead
    // of the trip length, which is only the same number when ivStart is 0 and
    // n >= 0: a bound below the start seeded the remainder BELOW the start
    // (fuzz 267 wrote a[0] from a [2, 1) loop), and a start off the vector
    // stride let the last vector step overrun M so the remainder re-applied
    // the overlap. The clamp is a sign-mask (AShr/Not/And), not a Select, so
    // it stays in the basic-ALU subset every vectorising back end handles.
    // EXTRACTED for the arm64 frame budget -- vecApplyReduction has no slots
    // to spare. Mirrors xtvEmitRuntimeM, byte-identically.
    final IRValue* vecRuntimeLimit(VecCand* c, IRBlock* PH)
        {
        String* ivTy = c.iv().ty();
        // The start is an operand: a runtime one (a par chunk's `lo`) when the
        // recogniser accepted it, else the constant seed as an immediate.
        IROperand* start = c.ivStartOp();
        if (start == (IROperand*)0 && c.ivStart() != (i64)0)
            start = IROperand.immI(c.ivStart(), ivTy);
        IROperand* tl = c.bound();
        if (start != (IROperand*)0)
            {
            IRValue* tv = new IRValue(ivTy);
            IRInsn* sb = IRInsn.with(String.withCString("Sub"));
            sb.setRes(tv);
            sb.add(c.bound());
            sb.add(start);
            PH.add(sb);
            tl = IROperand.useVal(tv);
            }
        IROperand* ctl = tl;
        IRInsn* g = c.guard();
        bool uns = g != (IRInsn*)0 && g.pred() != (String*)0
            && (g.pred().equals(String.withCString("ULT")) || g.pred().equals(String.withCString("ULE")));
        if (uns)
            {
            // An unsigned loop: the trip length is bound - start when the
            // bound is not below the start, else 0. Read as signed, a length
            // of 2^31 or more was negative and the clamp made it 0, so a par
            // block of 2.8e9 items ran all of them in the scalar remainder
            // (call_depth, 3x slower on one thread). The mask is
            // 0 - (bound >= start). As the reference.
            if (start != (IROperand*)0)
                {
                IRValue* okv = new IRValue(String.withCString("Bool"));
                IRInsn* ok = IRInsn.with(String.withCString("ICmp"));
                ok.setRes(okv);
                ok.setPred(String.withCString("UGE"));
                ok.add(c.bound());
                ok.add(start);
                PH.add(ok);
                IRValue* wv = new IRValue(ivTy);
                IRInsn* zx = IRInsn.with(String.withCString("ZExt"));
                zx.setRes(wv);
                zx.add(IROperand.useVal(okv));
                PH.add(zx);
                IRValue* mkv = new IRValue(ivTy);
                IRInsn* mk = IRInsn.with(String.withCString("Sub"));
                mk.setRes(mkv);
                mk.add(IROperand.immI((i64)0, ivTy));
                mk.add(IROperand.useVal(wv));
                PH.add(mk);
                IRValue* cv0 = new IRValue(ivTy);
                IRInsn* an1 = IRInsn.with(String.withCString("And"));
                an1.setRes(cv0);
                an1.add(tl);
                an1.add(IROperand.useVal(mkv));
                PH.add(an1);
                ctl = IROperand.useVal(cv0);
                }
            }
        else
            {
            // max(tl, 0): tl & ~(tl >> (bits-1)) — the sign fills the mask
            // when tl is negative, so the And zeroes it.
            IRValue* sv = new IRValue(ivTy);
            IRInsn* sh = IRInsn.with(String.withCString("AShr"));
            sh.setRes(sv);
            sh.add(tl);
            sh.add(IROperand.immI((i64)(self.irWidth(ivTy) * (u32)8 - (u32)1),
                                  String.withCString("U8")));
            PH.add(sh);
            IRValue* nv = new IRValue(ivTy);
            IRInsn* nt = IRInsn.with(String.withCString("Not"));
            nt.setRes(nv);
            nt.add(IROperand.useVal(sv));
            PH.add(nt);
            IRValue* cv = new IRValue(ivTy);
            IRInsn* an0 = IRInsn.with(String.withCString("And"));
            an0.setRes(cv);
            an0.add(tl);
            an0.add(IROperand.useVal(nv));
            PH.add(an0);
            ctl = IROperand.useVal(cv);
            }
        IRValue* mv = new IRValue(ivTy);
        IRInsn* an = IRInsn.with(String.withCString("And"));
        an.setRes(mv);
        an.add(ctl);
        an.add(IROperand.immI((i64) ~((i32)c.vw() - (i32)1), ivTy));
        PH.add(an);
        if (start == (IROperand*)0)
            return mv;
        IRValue* rv = new IRValue(ivTy);
        IRInsn* ad = IRInsn.with(String.withCString("Add"));
        ad.setRes(rv);
        ad.add(IROperand.useVal(mv));
        ad.add(start);
        PH.add(ad);
        return rv;
        }

    // The lane-index vector <0,1,2,3>, as a read-only 16-byte global. Building
    // it in REGISTERS would need a lane-insert sequence or a literal pool in
    // each back end; loading it needs only the VLoad both already have, and it
    // is loop-invariant so the load sits in the preheader.
    //
    // Named per FUNCTION. An initialised data global is emitted with .globl, so
    // one fixed name would put the same label in every object that vectorises
    // an iota loop and the link would refuse the second.
    final String* vecIotaSymbol(String* laneTy, u32 vecBytes, IRFunc* fn)
        {
        u32 lw = vecLaneWidth(laneTy);
        String* nm = new String();
        nm.appendFormat("__xtv_iota_%s_%u", fn.name().cString(), lw);
        // A 32-byte table gets its own name, so it never collides with the
        // 16-byte one; the 16-byte name is unchanged.
        if (vecBytes == (u32)64)
            nm.appendCString("_w64");
        else if (vecBytes != (u32)16)
            nm.appendCString("_w32");
        if (symNamed(_vecModule, nm) != (IRSymbol*)0)
            return nm;
        u32 lanes = vecBytes / lw;
        Array* bytes = new Array();
        for (u32 l = (u32)0; l < lanes; l = l + (u32)1)
            for (u32 k = (u32)0; k < lw; k = k + (u32)1)
                bytes.add((Object*)Number.with((l >> ((u32)8 * k)) & (u32)0xFF)); // LE
        String* vt = vecTyOf(laneTy, vecBytes);
        IRSymbol* sym = IRSymbol.dataGlobal(nm, vt);
        // Read-only, compiler-made, never address-taken beyond the VLoad here.
        sym.clearEscapes();
        sym.setNoAttrs();
        sym.setBytes(bytes);
        _vecModule.addSym(sym);
        return nm;
        }

    // The vector width this target's profile allows: 16 bytes, 32 under
    // -mavx2 (SIMD step 1, S2), or 64 under -mavx512. Map, reduce and min/max
    // loops take it; the widening forms stay at 16.
    final u32 vectorBytes(void)
        {
        if (_vecFnBytes != (u32)0)
            return _vecFnBytes == (u32)64 ? (u32)64 : _vecFnBytes == (u32)32 ? (u32)32 : (u32)16;
        if (_profile != (OptProfile*)0 && _profile.vectorLaneBytes() == (u32)64)
            return (u32)64;
        if (_profile != (OptProfile*)0 && _profile.vectorLaneBytes() == (u32)32)
            return (u32)32;
        return (u32)16;
        }

    // A vector type's text: `Vec(I32)` at 16 bytes (every existing dump is
    // unchanged), `Vec(I32, 32)` when wider, as the reference prints it.
    final String* vecTyOf(String* lane, u32 bytes)
        {
        String* t = new String();
        if (bytes == (u32)16)
            t.appendFormat("Vec(%s)", lane.cString());
        else
            t.appendFormat("Vec(%s, %u)", lane.cString(), bytes);
        return t;
        }

    final u32 vecLaneWidth(String* laneTy)
        {
        if (laneTy.equals(String.withCString("I32")) || laneTy.equals(String.withCString("U32")))
            return (u32)4;
        if (laneTy.equals(String.withCString("I16")) || laneTy.equals(String.withCString("U16")))
            return (u32)2;
        if (laneTy.equals(String.withCString("I8")) || laneTy.equals(String.withCString("U8")))
            return (u32)1;
        return (u32)8;
        }

    // The horizontal reduce at the loop exit, plus the initial scalar added back
    // if the accumulator did not start at zero, and the rewiring of every
    // post-loop reader of the old scalar accumulator.
    // Splice the remainder loop in between the vector loop and the exit.
    //
    // EXTRACTED from vecReduxExit purely for the arm64 frame budget: inlined, it
    // needed 18096 bytes against a 16384 limit, because every IR value in a
    // function gets its own frame slot whether or not its live range overlaps
    // anything. Same wall, same workaround as the settings handler — and the
    // reason stack-slot colouring is worth building.
    final IRValue* vecReduxEpilogue(IRFunc* fn, VecCand* c, IRValue* outV, Array* head)
        {
        IRValue* finalV = outV;
        // Epilogue part 2: the reduction lands between the vector loop and
        // the remainder, because the remainder's accumulator starts FROM it.
        IRBlock* H = c.h();
        IRBlock* E2 = c.e();
        IRBlock* H2 = _vecH2;
        IRBlock* B2 = _vecB2;
        IRBlock* PH = _vecPH;
        Map* cmap = _vecCmap;
        IRBlock* VE = new IRBlock(hoistName2(H.name(), "_vexit"));
        for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
            VE.add((IRInsn*)head.get(i));
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H2));
        VE.setTerm(br);

        // The vector loop exits to VE instead of E.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == E2)
                t.ops().set(k, (Object*)IROperand.block(VE));
            }

        // Seed the clone: iv enters at M, accumulator at the reduced total.
        Object* ivC = cmap.get((Hashable*)c.ivPhi().res());
        Object* accC = cmap.get((Hashable*)c.accPhi().res());
        for (u32 k = (u32)0; k < H2.phis().count(); k = k + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(k);
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(q);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != PH)
                    continue;
                phi.ops().set(q, (Object*)IROperand.block(VE));
                if (accC != (Object*)0 && phi.res() == (IRValue*)accC)
                    phi.ops().set(q + (u32)1, (Object*)IROperand.useVal(outV));
                else if (ivC != (Object*)0 && phi.res() == (IRValue*)ivC)
                    phi.ops().set(q + (u32)1, c.rtTrip()
                                                  ? (Object*)IROperand.useVal(_vecRtM)
                                                  : (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
                }
            }
        if (accC != (Object*)0)
            finalV = (IRValue*)accC;

        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == c.b())
                at = k + (u32)1;
        Array* three = new Array();
        three.add((Object*)VE);
        three.add((Object*)H2);
        three.add((Object*)B2);
        fn.blocks().insertAll(at, three);
        return finalV;
        }

    // Whether the loop at header H has a square root or a divide in its body
    // block (the latch): lane work an ordered float sum pays for itself on.
    final bool vecHeavyFloat(IRBlock* H, Map* defOf, Map* defBlk)
        {
        IRInsn* t = H.term();
        if (t == (IRInsn*)0 || t.ops().count() < (u32)3)
            return false;
        for (u32 k = (u32)1; k < (u32)3; k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                continue;
            IRBlock* b = o.blk();
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                {
                String* op = ((IRInsn*)b.insns().get(i)).op();
                if (op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("FDiv")))
                    return true;
                }
            }
        return false;
        }

    final void vecReplaceUse(IRInsn* n, IRValue* old, IRValue* to, IRInsn* skip)
        {
        if (n == skip)
            return;
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() != old)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    final IROperand* vecSplatConst(i64 k)
        {
        // An unsigned 32-bit lane's constant as the unsigned value it is (the
        // reference's spelling: `#2654435761`, not `#-1640531535`); vecConst
        // reads 32 bits signed.
        if (k < (i64)0 && _vecSplatTy != (String*)0 && _vecSplatTy.equals(String.withCString("U32")))
            k = k + (i64)4294967296;
        Object* have = _vecSplatK.get((Hashable*)Number.withI64(k));
        if (have != (Object*)0)
            return IROperand.useVal((IRValue*)have);
        // Past a few, a constant is splatted where it is used, not held in a
        // vector register for the whole loop: MD5's 64 round constants would
        // need 64, and arm64's vectoriser pool is 14.
        if (_vecSplatBig || _vecSplatK.count() >= (u32)VEC_SPLAT_HOIST_MAX)
            {
            IRValue* bc = new IRValue(_vecSplatTy);
            IRInsn* bn = IRInsn.with(String.withCString("Const"));
            bn.setRes(bc);
            bn.add(IROperand.immI(k, _vecSplatTy));
            _vecBody.add((Object*)bn);
            IRValue* bv = new IRValue(_vecTy);
            IRInsn* bs = IRInsn.with(String.withCString("VSplat"));
            bs.setRes(bv);
            bs.add(IROperand.useVal(bc));
            _vecBody.add((Object*)bs);
            return IROperand.useVal(bv);
            }
        IRValue* cst = new IRValue(_vecSplatTy);
        IRInsn* cn = IRInsn.with(String.withCString("Const"));
        cn.setRes(cst);
        cn.add(IROperand.immI(k, _vecSplatTy));
        _vecSplatPH.insns().add((Object*)cn);
        IRValue* v = new IRValue(_vecTy);
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(v);
        sp.add(IROperand.useVal(cst));
        _vecSplatPH.insns().add((Object*)sp);
        _vecSplatK.set((Hashable*)Number.withI64(k), (Object*)v);
        return IROperand.useVal(v);
        }

    // A stable key for a value, for the entry-splat cache. The original uses the
    // value id; ids here are stamped at print time, so identity is found by
    // position — params first, then each block's phis and instructions, which is
    // the same order the printer numbers in.
    final String* vecValueKey(IRFunc* fn, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            if ((IRValue*)fn.params().get(i) == v)
                return vecKeyOf(n);
            n = n + (u32)1;
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                if (((IRInsn*)bb.phis().get(i)).res() == v)
                    return vecKeyOf(n);
                n = n + (u32)1;
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                if (((IRInsn*)bb.insns().get(i)).res() == v)
                    return vecKeyOf(n);
                n = n + (u32)1;
                }
            }
        return (String*)0;
        }

    final String* vecKeyOf(u32 n)
        {
        String* s = new String();
        s.appendFormat("v%lu", n);
        return s;
        }
    }
