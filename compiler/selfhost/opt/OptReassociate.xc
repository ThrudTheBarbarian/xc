// OptReassociate.xc — the Reassociate pass, ported from src/xtc/ir/XTIROptReassociate.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (Reassociate)
    {

    // ── reassociate ──────────────────────────────────────────────────────
    //
    // An unrolled reduction is a chain, `acc + x0 + x1 + x2 + x3`, every link
    // waiting for the one before: four dependent ops per iteration on the value
    // the loop carries. For an associative integer op it is rebuilt as
    // `acc + ((x0 + x1) + (x2 + x3))` — one op on the carried value, the rest
    // in parallel. 32- and 64-bit integers only (wrapping add, mul and the
    // bitwise ops reassociate exactly; float does not).
    final void reassociate(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            _raUses = (Map*)0;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                bool more = true;
                while (more)
                    more = reassocOnce(fn, (IRBlock*)fn.blocks().get(b));
                }
            }
        }

    static bool raOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Mul"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor"));
        }

    static bool raType(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
                                || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")));
        }

    // The link feeding `cur` through `o`: same op, same type, in `bb`, and read
    // nowhere else.
    final IRInsn* raLink(IROperand* o, IRInsn* cur, IRBlock* bb, Map* uses)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (IRInsn*)0;
        Object* uc = uses.get((Hashable*)o.val());
        if (uc == (Object*)0 || ((Number*)uc).asU32() != (u32)1)
            return (IRInsn*)0;
        // The defining instruction from _raDefIn (this block's, by value):
        // a scan of the block here made the pass cubic in its size.
        IRInsn* p = (IRInsn*)_raDefIn.get((Hashable*)o.val());
        if (p == (IRInsn*)0)
            return (IRInsn*)0;
        if (!p.op().equals(cur.op()) || p.ops().count() != (u32)2 || p.memRes() != (IRValue*)0)
            return (IRInsn*)0;
        if (p.res().ty() == (String*)0 || !p.res().ty().equals(cur.res().ty()))
            return (IRInsn*)0;
        return p;
        }

    // The use count of every value in `fn` and its phi results.
    final void raCount(IRFunc* fn)
        {
        Map* uses = new Map();
        Array* phiVals = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* x = (IRBlock*)fn.blocks().get(b);
            u32 total = x.phis().count() + x.insns().count() + (u32)1;
            for (u32 i = (u32)0; i < total; i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)0;
                if (i < x.phis().count())
                    n = (IRInsn*)x.phis().get(i);
                else if (i < x.phis().count() + x.insns().count())
                    n = (IRInsn*)x.insns().get(i - x.phis().count());
                else
                    n = x.term();
                if (n == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    Object* c = uses.get((Hashable*)o.val());
                    u32 cnt = c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
                    uses.set((Hashable*)o.val(), (Object*)Number.withU32(cnt + (u32)1));
                    }
                }
            for (u32 i = (u32)0; i < x.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)x.phis().get(i);
                if (p.res() != (IRValue*)0)
                    phiVals.add((Object*)p.res());
                }
            }
        _raUses = uses;
        _raPhis = phiVals;
        }

    final bool reassocOnce(IRFunc* fn, IRBlock* bb)
        {
        // The function's use counts and phi results, kept while nothing is
        // rewritten (a call that returns false changes nothing): counted for
        // every block, they made the pass blocks x instructions in a function
        // with no chain to shorten at all.
        if (_raUses == (Map*)0)
            raCount(fn);
        Map* uses = _raUses;
        Array* phiVals = _raPhis;

        _raDefIn = new Map();
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* d = (IRInsn*)bb.insns().get(i);
            if (d.res() != (IRValue*)0 && _raDefIn.get((Hashable*)d.res()) == (Object*)0)
                _raDefIn.set((Hashable*)d.res(), (Object*)d);
            }
        // Every result in `bb` that is a link of a longer chain, in one pass,
        // as the reference.
        Map* linkResults = new Map();
        for (u32 ui = (u32)0; ui < bb.insns().count(); ui = ui + (u32)1)
            {
            IRInsn* u = (IRInsn*)bb.insns().get(ui);
            if (u.ops().count() != (u32)2)
                continue;
            for (u32 q = (u32)0; q < (u32)2; q = q + (u32)1)
                {
                IRInsn* p = raLink((IROperand*)u.ops().get(q), u, bb, uses);
                if (p != (IRInsn*)0 && p != u)
                    linkResults.set((Hashable*)p.res(), (Object*)p);
                }
            }

        for (u32 ti = (u32)0; ti < bb.insns().count(); ti = ti + (u32)1)
            {
            IRInsn* T = (IRInsn*)bb.insns().get(ti);
            if (!raOp(T.op()) || T.ops().count() != (u32)2 || T.res() == (IRValue*)0 || T.memRes() != (IRValue*)0
                || !raType(T.res().ty()))
                continue;
            // T must END its chain.
            if (linkResults.get((Hashable*)T.res()) != (Object*)0)
                continue;

            Array* links = new Array();
            links.add((Object*)T);
            Array* leaves = new Array();
            IRInsn* cur = T;
            bool walking = true;
            while (walking)
                {
                IRInsn* p0 = raLink((IROperand*)cur.ops().get((u32)0), cur, bb, uses);
                IRInsn* p1 = p0 != (IRInsn*)0 ? (IRInsn*)0 : raLink((IROperand*)cur.ops().get((u32)1), cur, bb, uses);
                if (p0 != (IRInsn*)0)
                    {
                    leaves.insert((u32)0, cur.ops().get((u32)1));
                    cur = p0;
                    links.add((Object*)cur);
                    }
                else if (p1 != (IRInsn*)0)
                    {
                    leaves.insert((u32)0, cur.ops().get((u32)0));
                    cur = p1;
                    links.add((Object*)cur);
                    }
                else
                    {
                    leaves.insert((u32)0, cur.ops().get((u32)1));
                    leaves.insert((u32)0, cur.ops().get((u32)0));
                    walking = false;
                    }
                }
            if (links.count() < (u32)2)
                continue;
            IROperand* acc = (IROperand*)0;
            bool ok = true;
            for (u32 q = (u32)0; q < leaves.count(); q = q + (u32)1)
                {
                IROperand* l = (IROperand*)leaves.get(q);
                if (l.kind() != (u8)OPK_USE)
                    ok = false;
                else if (bmHas2(phiVals, l.val()))
                    {
                    if (acc != (IROperand*)0)
                        ok = false;
                    acc = l;
                    }
                }
            // Already one op on the carried value (what a rewrite leaves):
            // nothing to shorten, and rebuilding it would never stop.
            if (!ok || acc == (IROperand*)0 || (IROperand*)T.ops().get((u32)0) == acc
                || (IROperand*)T.ops().get((u32)1) == acc)
                continue;
            Array* rest = new Array();
            for (u32 q = (u32)0; q < leaves.count(); q = q + (u32)1)
                if ((IROperand*)leaves.get(q) != acc)
                    rest.add(leaves.get(q));

            u32 at = ti;
            String* ty = T.res().ty();
            while (rest.count() > (u32)1)
                {
                Array* next = new Array();
                for (u32 q = (u32)0; q + (u32)1 < rest.count(); q = q + (u32)2)
                    {
                    IRValue* rv = new IRValue(ty);
                    IRInsn* ni = IRInsn.with(T.op());
                    ni.copyDbg(T);
                    ni.setRes(rv);
                    ni.add((IROperand*)rest.get(q));
                    ni.add((IROperand*)rest.get(q + (u32)1));
                    bb.insns().insert(at, (Object*)ni);
                    at = at + (u32)1;
                    next.add((Object*)IROperand.useVal(rv));
                    }
                if ((rest.count() & (u32)1) != (u32)0)
                    next.add(rest.get(rest.count() - (u32)1));
                rest = next;
                }
            T.ops().set((u32)0, (Object*)acc);
            T.ops().set((u32)1, rest.get((u32)0));
            for (u32 k = (u32)1; k < links.count(); k = k + (u32)1)
                self.removeInsn(bb, (IRInsn*)links.get(k));
            _raUses = (Map*)0;
            return true;
            }
        return false;
        }

    static bool bmHas2(Array* a, IRValue* v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRValue*)a.get(i) == v)
                return true;
        return false;
        }

    final void jumpThread(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 pass = (u32)0;
            while (pass < (u32)8 && jumpThreadOnce(fn))
                pass = pass + (u32)1;
            }
        }

    // The constant an operand resolves to, through the widening casts the front
    // end puts on a boolean.
    final bool jtConst(IROperand* op, Map* defOf, i32* out)
        {
        if (op == (IROperand*)0)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            *out = (i32)op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 hop = (u32)0; hop < (u32)8; hop = hop + (u32)1)
            {
            Object* dd = defOf.get((Hashable*)cur);
            if (dd == (Object*)0)
                return false;
            IRInsn* d = (IRInsn*)dd;
            if (d.ops().count() < (u32)1)
                return false;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("Const")) && a0.kind() == (u8)OPK_IMMI)
                {
                *out = (i32)a0.imm();
                return true;
                }
            if (!d.op().equals(String.withCString("ZExt")) && !d.op().equals(String.withCString("SExt"))
                && !d.op().equals(String.withCString("Trunc")))
                return false;
            if (a0.kind() != (u8)OPK_USE)
                return false;
            cur = a0.val();
            }
        return false;
        }

    final u32 jtUseCount(IRFunc* fn, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            n = n + jtCountIn(bb.phis(), v);
            n = n + jtCountIn(bb.insns(), v);
            if (bb.term() != (IRInsn*)0)
                n = n + jtCountOne(bb.term(), v);
            }
        return n;
        }

    final u32 jtUseCountIn(Array* insns, IRValue* v)
        {
        return jtCountIn(insns, v);
        }

    final u32 jtCountIn(Array* insns, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            n = n + jtCountOne((IRInsn*)insns.get(i), v);
        return n;
        }

    final u32 jtCountOne(IRInsn* i, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 q = (u32)0; q < i.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)i.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                n = n + (u32)1;
            }
        return n;
        }

    final bool jumpThreadOnce(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(i);
                if (n.res() != (IRValue*)0) defOf.set((Hashable*)n.res(), (Object*)n);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0) defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* J = (IRBlock*)fn.blocks().get(b);
            // J must do NOTHING but merge and branch: a predecessor rewired
            // past it would skip anything it held.
            if (J.insns().count() != (u32)0 || J.phis().count() != (u32)1)
                continue;
            IRInsn* term = J.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))
                || term.ops().count() < (u32)3)
                continue;
            IROperand* c0 = (IROperand*)term.ops().get((u32)0);
            if (c0.kind() != (u8)OPK_USE)
                continue;
            IRInsn* phi = (IRInsn*)J.phis().get((u32)0);
            if (phi.res() == (IRValue*)0 || phi.res() != c0.val())
                continue;
            if (phi.ops().count() < (u32)4)
                continue;
            // The phi must be read by NOTHING but J's own branch. If anything
            // else reads it — a block J dominates, say — a predecessor rewired
            // past J reaches that read with the phi never having executed and
            // sees whatever was in the register. That shape segfaulted the
            // self-hosted compiler while all 19 benchmarks stayed correct.
            if (jtUseCount(fn, phi.res()) != (u32)1)
                continue;
            IRBlock* onTrue = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* onFalse = ((IROperand*)term.ops().get((u32)2)).blk();
            if (onTrue == (IRBlock*)0 || onFalse == (IRBlock*)0)
                continue;
            // Redirecting into a block with phis would need a new incoming on
            // each; keep to the case where there is nothing to add.
            if (onTrue.phis().count() != (u32)0 || onFalse.phis().count() != (u32)0)
                continue;
            if (onTrue == J || onFalse == J)
                continue;  // a self-edge would drop an incoming still needed
            // The phi's incoming list is NOT the authority on who reaches J:
            // an earlier pass can redirect an edge without touching the phi.
            u32 realPreds = (u32)0;
            for (u32 pb = (u32)0; pb < fn.blocks().count(); pb = pb + (u32)1)
                {
                IRBlock* pbb = (IRBlock*)fn.blocks().get(pb);
                if (pbb.term() == (IRInsn*)0) continue;
                for (u32 q = (u32)0; q < pbb.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)pbb.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                        realPreds = realPreds + (u32)1;
                    }
                }
            if (realPreds != phi.ops().count() / (u32)2)
                continue;
            if (jtThreadEdge(fn, J, phi, onTrue, onFalse, defOf))
                return true;
            }
        return false;
        }

    // Split out for the arm64 frame budget.
    final bool jtThreadEdge(IRFunc* fn, IRBlock* J, IRInsn* phi,
                      IRBlock* onTrue, IRBlock* onFalse, Map* defOf)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IRBlock* P = ((IROperand*)phi.ops().get(k)).blk();
            i32 kv = (i32)0;
            if (P == (IRBlock*)0 || P == J)
                continue;
            if (!jtConst((IROperand*)phi.ops().get(k + (u32)1), defOf, &kv))
                continue;
            IRBlock* dest = (kv != (i32)0) ? onTrue : onFalse;
            IRInsn* pt = P.term();
            if (pt == (IRInsn*)0)
                continue;
            u32 hits = (u32)0;
            for (u32 q = (u32)0; q < pt.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)pt.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                    hits = hits + (u32)1;
                }
            if (hits != (u32)1)
                continue;
            for (u32 q = (u32)0; q < pt.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)pt.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                    pt.ops().set(q, (Object*)IROperand.block(dest));
                }
            Array* keep = new Array();
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                if (q != k)
                    {
                    keep.add(phi.ops().get(q));
                    keep.add(phi.ops().get(q + (u32)1));
                    }
            while (phi.ops().count() > (u32)0)
                phi.ops().removeAt(phi.ops().count() - (u32)1);
            for (u32 q = (u32)0; q < keep.count(); q = q + (u32)1)
                phi.ops().add(keep.get(q));

            // A phi with ONE incoming IS that incoming. Collapsing it is what
            // actually removes the boolean: left standing it is a value the
            // allocator must place, and a miss costs a store and a reload every
            // iteration — the whole cost this pass exists to remove.
            if (keep.count() == (u32)2
                && ((IROperand*)keep.get((u32)1)).kind() == (u8)OPK_USE)
                {
                IRValue* from = phi.res();
                IRValue* to = ((IROperand*)keep.get((u32)1)).val();
                for (u32 bb2 = (u32)0; bb2 < fn.blocks().count(); bb2 = bb2 + (u32)1)
                    {
                    IRBlock* bb = (IRBlock*)fn.blocks().get(bb2);
                    jtReplace(bb.phis(), from, to);
                    jtReplace(bb.insns(), from, to);
                    if (bb.term() != (IRInsn*)0)
                        jtReplaceOne(bb.term(), from, to);
                    }
                J.phis().removeAt((u32)0);
                }
            return true;
            }
        return false;
        }

    final void jtReplace(Array* insns, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            jtReplaceOne((IRInsn*)insns.get(i), from, to);
        }

    final void jtReplaceOne(IRInsn* n, IRValue* from, IRValue* to)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(q, (Object*)IROperand.useVal(to));
            }
        }

    final void ifConvert(IRModule* m)
        {
        if (!_profile.ifConvert())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 iter = (u32)0; iter < (u32)4096; iter = iter + (u32)1)
                if (!ifConvertOnce(fn))
                    break;
            }
        }

    final bool ifConvertOnce(IRFunc* fn)
        {
        if (!recogniseDiamond(fn))
            return false;
        applyDiamond(fn);
        return true;
        }

    final bool recogniseDiamond(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = H.term();
            if (term == 0)
                continue;
            if (!term.op().equals(String.withCString("CondBranch")))
                continue;
            if (term.ops().count() < (u32)3)
                continue;
            IROperand* condOp = (IROperand*)term.ops().get((u32)0);
            if (condOp.kind() != (u8)OPK_USE || condOp.val() == 0)
                continue;
            IRBlock* tA = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* fA = ((IROperand*)term.ops().get((u32)2)).blk();
            if (tA == 0 || fA == 0 || tA == fA)
                continue;

            IRBlock* T = (IRBlock*)0;
            IRBlock* J = (IRBlock*)0;
            bool tIsTrue = false;
            if (isPureMiddle(fn, tA, H, fA))
                {
                T = tA;
                J = fA;
                tIsTrue = true;
                }
            else if (isPureMiddle(fn, fA, H, tA))
                {
                T = fA;
                J = tA;
                tIsTrue = false;
                }
            else
                {
                // Not a triangle. Try the DIAMOND: both arms pure middles that
                // meet at a common join. isPureMiddle demands that one arm
                // branch to the OTHER arm, so a full if-then-else never matched
                // and no amount of cleaning up its arms could make it match —
                // branch_mix kept three branches per iteration where clang has
                // one.
                IRInsn* ta = tA.term();
                IRInsn* fa = fA.term();
                if (ta == (IRInsn*)0 || fa == (IRInsn*)0)
                    continue;
                if (!ta.op().equals(String.withCString("Branch")) || !fa.op().equals(String.withCString("Branch")))
                    continue;
                if (ta.ops().count() < (u32)1 || fa.ops().count() < (u32)1)
                    continue;
                IRBlock* meet = ((IROperand*)ta.ops().get((u32)0)).blk();
                if (meet == (IRBlock*)0 || meet != ((IROperand*)fa.ops().get((u32)0)).blk())
                    continue;
                if (!isPureMiddle(fn, tA, H, meet) || !isPureMiddle(fn, fA, H, meet))
                    continue;
                if (meet == H || meet == tA || meet == fA || meet.phis().count() == (u32)0)
                    continue;
                Array* mp = self.predsOfBlock(fn, meet);
                if (mp.count() != (u32)2 || !self.hasBlock(mp, tA) || !self.hasBlock(mp, fA))
                    continue;
                // EVERY phi must have exactly the two arm incomings: the
                // applier skips one it cannot orient, and then both arms are
                // deleted underneath it, leaving a phi naming blocks that no
                // longer exist.
                bool phisOK = true;
                for (u32 q = (u32)0; q < meet.phis().count(); q = q + (u32)1)
                    {
                    IRInsn* ph = (IRInsn*)meet.phis().get(q);
                    if (ph.res() == (IRValue*)0 || ph.ops().count() != (u32)4)
                        phisOK = false;
                    else
                        {
                        IRBlock* p0 = ((IROperand*)ph.ops().get((u32)0)).blk();
                        IRBlock* p1 = ((IROperand*)ph.ops().get((u32)2)).blk();
                        if (!((p0 == tA && p1 == fA) || (p0 == fA && p1 == tA)))
                            phisOK = false;
                        }
                    }
                if (!phisOK)
                    continue;
                _icH = H;
                _icT = tA;
                _icF = fA;
                _icJ = meet;
                _icCond = condOp.val();
                _icTIsTrue = true;
                return true;
                }
            if (J == 0 || J == H || J == T)
                continue;
            if (J.phis().count() == (u32)0)
                continue; // nothing to select

            // The join's predecessors must be exactly {H, T}: any other edge
            // and the phis carry values this transform cannot account for.
            Array* jp = self.predsOfBlock(fn, J);
            if (jp.count() != (u32)2)
                continue;
            if (!(self.hasBlock(jp, H) && self.hasBlock(jp, T)))
                continue;

            _icH = H;
            _icT = T;
            _icF = (IRBlock*)0;
            _icJ = J;
            _icCond = condOp.val();
            _icTIsTrue = tIsTrue;
            return true;
            }
        return false;
        }

    // A "pure middle": one predecessor (the head), no phis, a body that can run
    // unconditionally, and an unconditional Branch to the join.
    final bool isPureMiddle(IRFunc* fn, IRBlock* M, IRBlock* H, IRBlock* dest)
        {
        if (M == 0 || M == H)
            return false;
        if (M.phis().count() != (u32)0)
            return false;
        IRInsn* t = M.term();
        if (t == 0 || !t.op().equals(String.withCString("Branch")))
            return false;
        if (t.ops().count() < (u32)1)
            return false;
        if (((IROperand*)t.ops().get((u32)0)).blk() != dest)
            return false;
        for (u32 i = (u32)0; i < M.insns().count(); i = i + (u32)1)
            if (!self.speculatable((IRInsn*)M.insns().get(i)))
                return false;
        Array* mp = self.predsOfBlock(fn, M);
        return mp.count() == (u32)1 && (IRBlock*)mp.get((u32)0) == H;
        }

    final void applyDiamond(IRFunc* fn)
        {
        IRBlock* H = _icH;
        IRBlock* T = _icT;
        IRBlock* F = _icF; // non-zero for a diamond
        IRBlock* J = _icJ;
        Map* defOf = self.defMapAll(fn);

        // The arms' instructions move into the head, ahead of its terminator.
        // For a diamond BOTH arms move: the point is that each arm's value is
        // computed either way and the Select picks one.
        for (u32 i = (u32)0; i < T.insns().count(); i = i + (u32)1)
            H.add((IRInsn*)T.insns().get(i));
        if (F != (IRBlock*)0)
            for (u32 i = (u32)0; i < F.insns().count(); i = i + (u32)1)
                H.add((IRInsn*)F.insns().get(i));

        Array* phis = new Array();
        for (u32 i = (u32)0; i < J.phis().count(); i = i + (u32)1)
            phis.add(J.phis().get(i));
        Array* keptPhis = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)phis.get(i);
            if (!selectForPhi(fn, defOf, phi, H, F != (IRBlock*)0 ? F : H, T))
                keptPhis.add((Object*)phi);
            }
        J.setPhis(keptPhis);

        // The head now falls straight through to the join; the arm is gone.
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(J));
        H.setTerm(br);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != T && bb != F)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    // One join phi becomes a Select (or a boolean And/Or) in the head. False
    // when the phi is not the two-way merge this transform expects.
    // `other` is H for a triangle and the second arm F for a diamond: the join
    // phi's two incomings are (T, ...) and (other, ...).
    final bool selectForPhi(IRFunc* fn, Map* defOf, IRInsn* phi, IRBlock* H, IRBlock* other, IRBlock* T)
        {
        if (phi.res() == 0)
            return false;
        IROperand* vT = (IROperand*)0;
        IROperand* vH = (IROperand*)0;
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IRBlock* pb = ((IROperand*)phi.ops().get(k)).blk();
            if (pb == T)
                vT = (IROperand*)phi.ops().get(k + (u32)1);
            else if (pb == other)
                vH = (IROperand*)phi.ops().get(k + (u32)1);
            }
        if (vT == 0 || vH == 0)
            return false;

        IROperand* selTrue = _icTIsTrue ? vT : vH;
        IROperand* selFalse = _icTIsTrue ? vH : vT;
        String* ty = phi.res().ty();
        IRValue* res = new IRValue(ty);
        IROperand* condUse = IROperand.useVal(_icCond);

        // `cond ? rhs : false` is `cond & rhs`, and `cond ? true : rhs` is
        // `cond | rhs` — one instruction, no condition to materialise. Only
        // when BOTH inputs are strictly 0/1: And(2,1) is 0 where 2?1:0 is 1.
        bool isBool = ty.equals(String.withCString("Bool"));
        bool condOK = isBool01(defOf, condUse);
        IRInsn* repl;
        if (isBool && condOK && isBoolConst(defOf, selFalse, (i32)0) && isBool01(defOf, selTrue))
            {
            repl = IRInsn.with(String.withCString("And"));
            repl.copyDbg(phi);
            repl.add(condUse);
            repl.add(selTrue);
            }
        else if (isBool && condOK && isBoolConst(defOf, selTrue, (i32)1) && isBool01(defOf, selFalse))
            {
            repl = IRInsn.with(String.withCString("Or"));
            repl.copyDbg(phi);
            repl.add(condUse);
            repl.add(selFalse);
            }
        else
            {
            repl = IRInsn.with(String.withCString("Select"));
            repl.copyDbg(phi);
            repl.add(condUse);
            repl.add(selTrue);
            repl.add(selFalse);
            }
        repl.setRes(res);
        H.add(repl);
        self.rewriteUsesTo(fn, phi.res(), IROperand.useVal(res));
        return true;
        }

    // A Use that resolves to a Bool Const of exactly `want`.
    final bool isBoolConst(Map* defOf, IROperand* op, i32 want)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("Const")))
            return false;
        if (n.ops().count() < (u32)1)
            return false;
        IROperand* imm = (IROperand*)n.ops().get((u32)0);
        if (imm.kind() != (u8)OPK_IMMI)
            return false;
        if (imm.ty() == 0 || !imm.ty().equals(String.withCString("Bool")))
            return false;
        return imm.imm() == want;
        }

    // Provably 0 or 1: a comparison result, or a 0/1 bool constant. A loaded
    // bool or a truncation is not, and the caller falls back to Select.
    final bool isBool01(Map* defOf, IROperand* op)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (n.op().equals(String.withCString("ICmp")) || n.op().equals(String.withCString("FCmp")))
            return true;
        return isBoolConst(defOf, op, (i32)0) || isBoolConst(defOf, op, (i32)1);
        }
    }
