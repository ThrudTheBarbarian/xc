// OptStaticInitGuard.xc — the StaticInitGuard pass, ported from src/xtc/ir/XTIROptStaticInitGuard.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptArcSelfRetain>
#import <OptInline>

    class Opt (StaticInitGuard)
    {

    final void staticInitGuard(IRModule* m)
        {
        if (!_profile.initGuardElim())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            initGuardsInFunc(m, fn);
            // Every function's straight-line chains, guards or none: an if
            // that if-conversion made a Select leaves its body and join two
            // blocks, which neither vectoriser takes. Coalescing ran only
            // where a guard was folded, and in 0.9.1 nearly every function
            // had Stdio's; with libRuntime the library's classes have none,
            // and string_scan's loop stopped vectorising (11 s against
            // 0.47). As the reference.
            if (fn.blocks().count() >= (u32)2)
                coalesceStraightLine(fn);
            }
        }

    final void sgCountOps(Array* used, Array* ops)
        {
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)ops.get(i);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && !self.hasValue(used, o.val()))
                used.add((Object*)o.val());
            }
        }
    final void sgCountUses(Array* used, Array* insns)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            sgCountOps(used, ((IRInsn*)insns.get(i)).ops());
        }
    final void sgDeadStripBlock(IRBlock* blk, IRFunc* fn)
        {
        bool removed = true;
        while (removed)
            {
            removed = false;
            Array* used = new Array();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                sgCountUses(used, bb.phis());
                sgCountUses(used, bb.insns());
                if (bb.term() != (IRInsn*)0)
                    sgCountOps(used, bb.term().ops());
                }
            for (i32 i = (i32)blk.insns().count() - (i32)1; i >= (i32)0; i = i - (i32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get((u32)i);
                String* op = n.op();
                bool pure = op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("Load"))
                         || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("Const"))
                         || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt"))
                         || op.equals(String.withCString("Trunc"));
                if (!pure)
                    continue;
                bool resUsed = n.res() != (IRValue*)0 && self.hasValue(used, n.res());
                bool memUsed = n.memRes() != (IRValue*)0 && self.hasValue(used, n.memRes());
                if (!resUsed && !memUsed)
                    {
                    blk.insns().removeAt((u32)i);
                    removed = true;
                    }
                }
            }
        }

    final void initGuardsInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() < (u32)2)
            return;
        _sgBypass = new Map();
        recogniseGuards(m, fn);
        if (_sgGuards.count() < (u32)1)
            return;
        if (_sgFoldAll)
            {
            for (u32 k = (u32)0; k < _sgGuards.count(); k = k + (u32)1)
                foldGuard(fn, k);
            coalesceStraightLine(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                sgDeadStripBlock((IRBlock*)fn.blocks().get(b), fn);
            return;
            }

        if (_profile.initGuardHoist())
            {
            hoistGuardsToEntry(m, fn);
            recogniseGuards(m, fn);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            sgDeadStripBlock((IRBlock*)fn.blocks().get(b), fn);

        // A guard whose init block only sets its own flag does nothing: the
        // class has no initialiser (Math), and nothing but its guards reads
        // the flag. It comes out wherever it is; one left in a loop kept the
        // body two blocks, which neither vectoriser takes (nbody's inner loop
        // calls Math.sqrt). As the reference.
        Array* trivial = new Array();
        for (u32 i = (u32)0; i < _sgGuards.count(); i = i + (u32)1)
            if (sgTrivial(i))
                trivial.add((Object*)Number.with(i));
        for (u32 k = (u32)0; k < trivial.count(); k = k + (u32)1)
            foldGuard(fn, ((Number*)trivial.get(k)).asU32());
        if (trivial.count() > (u32)0)
            {
            // The check's Load of the flag is left behind (foldGuard leaves the
            // tail to dead-code elimination, which keeps a Load): strip it, or
            // the loop still reads the flag every time round. As the reference.
            coalesceStraightLine(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                sgDeadStripBlock((IRBlock*)fn.blocks().get(b), fn);
            recogniseGuards(m, fn);
            }

        if (_sgGuards.count() < (u32)2)
            return;

        // Redundant: another guard for the SAME class has its straight-through
        // block dominating this one — the flag is set on every path here.
        Map* dom = self.dominators(fn);
        Array* redundant = new Array();
        for (u32 i = (u32)0; i < _sgGuards.count(); i = i + (u32)1)
            {
            for (u32 j = (u32)0; j < _sgGuards.count(); j = j + (u32)1)
                {
                if (i == j)
                    continue;
                if (!((String*)_sgSyms.get(j)).equals((String*)_sgSyms.get(i)))
                    continue;
                Object* ds = dom.get((Hashable*)(IRBlock*)_sgGuards.get(i));
                if (ds == 0)
                    continue;
                if (!self.hasBlock((Array*)ds, (IRBlock*)_sgConts.get(j)))
                    continue;
                redundant.add((Object*)Number.with(i));
                break;
                }
            }
        for (u32 k = (u32)0; k < redundant.count(); k = k + (u32)1)
            foldGuard(fn, ((Number*)redundant.get(k)).asU32());
        // Folding leaves a chain of unconditional branches; coalescing them is
        // what puts the loop body back in one block for the unroller.
        if (redundant.count() > (u32)0)
            coalesceStraightLine(fn);
        }

    // The single-threaded guard whose init block is the flag's own store and
    // nothing else (constants aside), branching straight to its cont block.
    // As the reference's guardIsTrivial.
    final bool sgTrivial(u32 i)
        {
        IRInsn* icmp = (IRInsn*)_sgIcmps.get(i);
        IRBlock* run = (IRBlock*)_sgRuns.get(i);
        IRBlock* cont = (IRBlock*)_sgConts.get(i);
        IRInsn* addr = (IRInsn*)_sgAddrs.get(i);
        if (icmp == 0 || icmp.pred() == 0 || !icmp.pred().equals(String.withCString("EQ")))
            return false;
        if (run.phis().count() > (u32)0 || addr == 0 || addr.res() == (IRValue*)0)
            return false;
        IRInsn* t = run.term();
        if (t == 0 || !t.op().equals(String.withCString("Branch")) || t.ops().count() != (u32)1)
            return false;
        IROperand* to = (IROperand*)t.ops().get((u32)0);
        if (to.kind() != (u8)OPK_BLOCK || to.blk() != cont)
            return false;
        for (u32 k = (u32)0; k < run.insns().count(); k = k + (u32)1)
            {
            IRInsn* n = (IRInsn*)run.insns().get(k);
            if (n.op().equals(String.withCString("Const")))
                continue;
            if (n.op().equals(String.withCString("Store")) && n.ops().count() >= (u32)2)
                {
                IROperand* a = (IROperand*)n.ops().get((u32)0);
                if (a.kind() == (u8)OPK_USE && a.val() == addr.res())
                    continue;
                }
            return false;
            }
        for (u32 k = (u32)0; k < cont.phis().count(); k = k + (u32)1)
            {
            IRInsn* ph = (IRInsn*)cont.phis().get(k);
            for (u32 q = (u32)0; q < ph.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)ph.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == run)
                    return false;
                }
            }
        return true;
        }

    final void recogniseGuards(IRModule* m, IRFunc* fn)
        {
        _sgGuards = new Array();
        _sgRuns = new Array();
        _sgConts = new Array();
        _sgSyms = new Array();
        _sgMemIns = new Array();
        _sgAddrs = new Array();
        _sgLoads = new Array();
        _sgIcmps = new Array();
        _sgConsts = new Array();
        Map* defOf = self.defMapAll(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* G = (IRBlock*)fn.blocks().get(b);
            if (!recogniseGuard(m, fn, G, defOf))
                continue;
            _sgGuards.add((Object*)_sgGuard);
            _sgRuns.add((Object*)_sgRun);
            _sgConts.add((Object*)_sgCont);
            _sgSyms.add((Object*)_sgSym);
            _sgMemIns.add((Object*)_sgLoadMemIn);
            _sgAddrs.add((Object*)_sgAddr);
            _sgLoads.add((Object*)_sgLoad);
            _sgIcmps.add((Object*)_sgIcmp);
            _sgConsts.add((Object*)_sgConst0);
            }
        }

    final bool recogniseGuard(IRModule* m, IRFunc* fn, IRBlock* G, Map* defOf)
        {
        IRInsn* term = G.term();
        if (term == 0 || !term.op().equals(String.withCString("CondBranch")))
            return false;
        if (term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE || c0.val() == 0)
            return false;
        IROperand* o1 = (IROperand*)term.ops().get((u32)1);
        IROperand* o2 = (IROperand*)term.ops().get((u32)2);
        if (o1.kind() != (u8)OPK_BLOCK || o2.kind() != (u8)OPK_BLOCK)
            return false;

        Object* d = defOf.get((Hashable*)c0.val());
        if (d == 0)
            return false;
        IRInsn* icmp = (IRInsn*)d;
        if (!icmp.op().equals(String.withCString("ICmp")))
            return false;
        // Two shapes. Single-threaded: `ICmp EQ flag, 0`, run block stores 1.
        // Threaded (threading.md §9.5): `ICmp NE flag, 2`, run block calls
        // _xtc_sinit_run, which sets the flag itself.
        if (icmp.pred() == 0)
            return false;
        i32 wantConst = (i32)0;
        if (icmp.pred().equals(String.withCString("EQ")))
            wantConst = (i32)0;
        else if (icmp.pred().equals(String.withCString("NE")))
            wantConst = (i32)2;
        else
            return false;
        if (icmp.ops().count() < (u32)2)
            return false;
        IROperand* lhs = (IROperand*)icmp.ops().get((u32)0);
        if (lhs.kind() != (u8)OPK_USE || lhs.val() == 0)
            return false;
        if (!isConstOperand(defOf, (IROperand*)icmp.ops().get((u32)1), wantConst))
            return false;

        Object* dl = defOf.get((Hashable*)lhs.val());
        if (dl == 0)
            return false;
        IRInsn* load = (IRInsn*)dl;
        if (!load.op().equals(String.withCString("Load")))
            return false;
        if (load.ops().count() < (u32)1)
            return false;
        IROperand* pa = (IROperand*)load.ops().get((u32)0);
        if (pa.kind() != (u8)OPK_USE || pa.val() == 0)
            return false;
        Object* da = defOf.get((Hashable*)pa.val());
        if (da == 0)
            return false;
        IRInsn* addr = (IRInsn*)da;
        if (!addr.op().equals(String.withCString("AddrOf")))
            return false;
        if (addr.ops().count() < (u32)1)
            return false;
        IROperand* sym = (IROperand*)addr.ops().get((u32)0);
        if (sym.kind() != (u8)OPK_SYM || sym.name() == 0)
            return false;
        if (!sym.name().hasPrefix(String.withCString("__sinit")))
            return false;

        IRBlock* run = o1.blk(); // EQ true (flag == 0) → initialise
        IRBlock* cont = o2.blk();
        if (run == 0 || cont == 0 || run == cont)
            return false;
        // A phi in `cont` could carry a value from the init block; folding the
        // guard would leave it dangling. The lowering's cont has none.
        if (cont.phis().count() != (u32)0)
            return false;
        Array* rp = self.predsOfBlock(fn, run);
        if (rp.count() != (u32)1 || (IRBlock*)rp.get((u32)0) != G)
            return false;
        if (run.term() == 0 || !run.term().op().equals(String.withCString("Branch")))
            return false;
        Array* rs = self.successorsOf(run);
        if (rs.count() != (u32)1 || (IRBlock*)rs.get((u32)0) != cont)
            return false;
        if (!storesFlag(m, defOf, run, sym.name()))
            return false;

        _sgGuard = G;
        _sgRun = run;
        _sgCont = cont;
        _sgSym = sym.name();
        _sgLoadMemIn = load.ops().count() >= (u32)2
                           ? (IROperand*)load.ops().get((u32)1)
                           : (IROperand*)0;
        _sgAddr = addr;
        _sgLoad = load;
        _sgIcmp = icmp;
        IROperand* rhs = (IROperand*)icmp.ops().get((u32)1);
        _sgConst0 = (IRInsn*)0;
        if (rhs.kind() == (u8)OPK_USE && rhs.val() != 0)
            {
            Object* cd = defOf.get((Hashable*)rhs.val());
            if (cd != 0)
                _sgConst0 = (IRInsn*)cd;
            }
        return true;
        }

    // The init block must set the very flag the check read.
    final bool storesFlag(IRModule* m, Map* defOf, IRBlock* run, String* symName)
        {
        for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)run.insns().get(i);
            // Single-threaded: a Store of 1 to the flag. Threaded: the store
            // happens inside _xtc_sinit_run, so the proof is a call to it whose
            // first argument is this flag.
            IROperand* a = (IROperand*)0;
            if (n.op().equals(String.withCString("Store")))
                {
                if (n.ops().count() < (u32)1)
                    continue;
                a = (IROperand*)n.ops().get((u32)0);
                }
            else if (n.op().equals(String.withCString("Call")))
                {
                if (n.ops().count() < (u32)2)
                    continue;
                IROperand* cal = (IROperand*)n.ops().get((u32)0);
                if (cal.kind() != (u8)OPK_SYM || cal.name() == 0)
                    continue;
                if (!cal.name().equals(String.withCString("_xtc_sinit_run")))
                    continue;
                a = (IROperand*)n.ops().get((u32)1);
                }
            else
                continue;
            if (a.kind() != (u8)OPK_USE || a.val() == 0)
                continue;
            Object* d = defOf.get((Hashable*)a.val());
            if (d == 0)
                continue;
            IRInsn* sa = (IRInsn*)d;
            if (!sa.op().equals(String.withCString("AddrOf")))
                continue;
            if (sa.ops().count() < (u32)1)
                continue;
            IROperand* ss = (IROperand*)sa.ops().get((u32)0);
            if (ss.kind() != (u8)OPK_SYM || ss.name() == 0)
                continue;
            if (ss.name().equals(symName))
                return true;
            }
        return false;
        }

    final bool isConstOperand(Map* defOf, IROperand* op, i32 want)
        {
        if (op.kind() == (u8)OPK_IMMI)
            return op.imm() == want;
        if (op.kind() != (u8)OPK_USE || op.val() == 0)
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
        return imm.kind() == (u8)OPK_IMMI && imm.imm() == want;
        }

    // Bypass the check, drop the now-unreachable init block, and rewire uses of
    // its memory tokens to the guard's incoming memory so the chain stays
    // well-formed. The dead check tail is left to the dead-code pass.
    final void foldGuard(IRFunc* fn, u32 idx)
        {
        IRBlock* G = (IRBlock*)_sgGuards.get(idx);
        IRBlock* run = (IRBlock*)_sgRuns.get(idx);
        IRBlock* cont = (IRBlock*)_sgConts.get(idx);
        if (!self.hasBlock(fn.blocks(), G) || !self.hasBlock(fn.blocks(), run))
            return;
        IROperand* memIn = (IROperand*)_sgMemIns.get(idx);
        if (memIn != 0 && memIn.kind() == (u8)OPK_USE && memIn.val() != 0)
            {
            // The target may itself have been removed by an earlier fold — two
            // guards for one class chain, and the second's incoming memory was
            // defined in the first's init block.
            IRValue* target = self.resolveBypass(_sgBypass, memIn.val());
            for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)run.insns().get(i);
                if (n.memRes() == 0)
                    continue;
                _sgBypass.set((Hashable*)n.memRes(), (Object*)target);
                self.forwardMem(fn, n.memRes(), target);
                }
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(cont));
        G.setTerm(br);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != run)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    // Merge `A -Branch-> B` when B's only predecessor is A: B's instructions
    // and terminator move into A, and B's successors' phis now name A.
    final void coalesceStraightLine(IRFunc* fn)
        {
        bool changed = true;
        while (changed)
            {
            changed = false;
            IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
            for (u32 a = (u32)0; a < fn.blocks().count(); a = a + (u32)1)
                {
                if (changed)
                    break;
                IRBlock* A = (IRBlock*)fn.blocks().get(a);
                IRInsn* t = A.term();
                if (t == 0 || !t.op().equals(String.withCString("Branch")))
                    continue;
                if (t.ops().count() < (u32)1)
                    continue;
                IROperand* o = (IROperand*)t.ops().get((u32)0);
                if (o.kind() != (u8)OPK_BLOCK)
                    continue;
                IRBlock* B = o.blk();
                if (B == 0 || B == A || B == entry)
                    continue;
                if (B.phis().count() != (u32)0)
                    continue;
                Array* bp = self.predsOfBlock(fn, B);
                if (bp.count() != (u32)1 || (IRBlock*)bp.get((u32)0) != A)
                    continue;
                mergeBlocks(fn, A, B);
                changed = true;
                }
            }
        }

    final void mergeBlocks(IRFunc* fn, IRBlock* A, IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            A.add((IRInsn*)B.insns().get(i));
        A.setTerm(B.term());
        // B's successors named B as a predecessor; they now name A.
        Array* succ = self.successorsOf(A);
        for (u32 s = (u32)0; s < succ.count(); s = s + (u32)1)
            {
            IRBlock* S = (IRBlock*)succ.get(s);
            for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)S.phis().get(i);
                for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                    {
                    IROperand* po = (IROperand*)phi.ops().get(k);
                    if (po.kind() != (u8)OPK_BLOCK || po.blk() != B)
                        continue;
                    phi.ops().set(k, (Object*)IROperand.block(A));
                    }
                }
            }
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != B)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }
    // Hoist ONE guard per class to the entry: chk_0 → (run_0) → mrg_0 → chk_1
    // → … → the old entry. Each is built from a representative in-body guard,
    // and the in-body ones are then dominated and folded away. Eager init at
    // entry rather than at first use — sound for an idempotent class init the
    // function unconditionally reaches, and validated by the sweep.
    // ── Is it safe to run this class's `init` EARLIER than its first use? ──
    //
    // Hoisting to the function entry relocates the initialiser, so an `init`
    // that can OBSERVE program state set up in between reads the earlier value —
    // silently, and only at -O2. See private:docs/bugs/059.
    //
    // Deliberately crude, because a wrong YES is a wrong answer in the compiled
    // program: any Call at all, or any symbol reference that is not this class's
    // own static data, disqualifies it. Stdio/Assert-style initialisers — set my
    // own statics from constants — still pass, which is the case the
    // optimisation exists for.
    final bool initIsHoistable(IRModule* m, String* flagSym)
        {
        if (!flagSym.hasPrefix(String.withCString("__sinit_")))
            return false;
        String* cls = flagSym.substringFromByte((u32)8);
        String* initName = String.withString(cls);
        initName.appendCString("$init");
        String* ownData = String.withCString("__sdata_");
        ownData.append(cls);
        String* ownIvar = String.withCString("__sivar_");
        ownIvar.append(cls);
        ownIvar.appendCString("_");

        IRFunc* initFn = (IRFunc*)0;
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)m.funcs().get(i);
            if (f.name().equals(initName))
                {
                initFn = f;
                break;
                }
            }
        if (initFn == 0)
            return false; // no body visible -> assume the worst

        for (u32 b = (u32)0; b < initFn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)initFn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n.op().equals(String.withCString("Call")))
                    return false;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* op = (IROperand*)n.ops().get(k);
                    if (op.kind() != (u8)OPK_SYM || op.name() == 0)
                        continue;
                    if (op.name().equals(ownData))
                        continue;
                    if (op.name().hasPrefix(ownIvar))
                        continue;
                    return false;
                    }
                }
            }
        return true;
        }

    final void hoistGuardsToEntry(IRModule* m, IRFunc* fn)
        {
        if (_sgGuards.count() == (u32)0 || fn.blocks().count() == (u32)0)
            return;
        u32 pc = fn.params().count();
        if (pc == (u32)0)
            return;
        // The function's memory token is its last parameter, and it dominates
        // everything — so it is what the entry guard's Load reads.
        IROperand* entryMem = IROperand.useVal((IRValue*)fn.params().get(pc - (u32)1));
        IRBlock* oldEntry = (IRBlock*)fn.blocks().get((u32)0);

        Map* defOf = self.defMapAll(fn);
        Array* reps = new Array(); // one guard index per class
        Array* seen = new Array();
        for (u32 i = (u32)0; i < _sgGuards.count(); i = i + (u32)1)
            {
            String* sym = (String*)_sgSyms.get(i);
            if (has(seen, sym))
                continue;
            // bug 059: only relocate an initialiser that cannot tell it moved.
            if (!initIsHoistable(m, sym))
                continue;
            if (!runIsCloneable(i, defOf))
                continue;
            seen.add((Object*)sym);
            reps.add((Object*)Number.with(i));
            }
        if (reps.count() == (u32)0)
            return;

        Array* newBlocks = new Array();
        Array* checks = new Array();
        Array* merges = new Array();
        for (u32 r = (u32)0; r < reps.count(); r = r + (u32)1)
            {
            u32 idx = ((Number*)reps.get(r)).asU32();
            buildHoistedGuard(fn, idx, entryMem, defOf, newBlocks, checks, merges);
            }

        // mrg_i branches to chk_{i+1}; the last one to the old entry.
        for (u32 i = (u32)0; i < merges.count(); i = i + (u32)1)
            {
            IRBlock* target = (i + (u32)1 < checks.count())
                                  ? (IRBlock*)checks.get(i + (u32)1)
                                  : oldEntry;
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(target));
            ((IRBlock*)merges.get(i)).setTerm(br);
            }
        fn.blocks().insertAll((u32)0, newBlocks);
        }

    // ── Can the init block be cloned to the function entry? ─────────────────
    //
    // The clone runs ahead of every block the function had, so it may use only
    // what it defines itself, the flag pointer and memory token the check block
    // rebuilds, and the function's parameters. The cross-block CSE that runs
    // earlier can leave the init block reading a value defined in the guard
    // block: an `AddrOf @__sdata_X` shared with code after the guard. An address
    // or a constant is rebuilt in the clone; anything else defined outside the
    // block cannot be, and that guard is not hoisted. Cloned verbatim, the use
    // read a register nothing had set yet, and the init wrote through it the
    // first time the flag was clear on entry: a library's `Number.with` called
    // from a client, whose own guard sets the client's flag and not the
    // library's (private:docs/bugs/270).
    final bool isRematerialisable(IRInsn* def)
        {
        if (!def.op().equals(String.withCString("AddrOf"))
            && !def.op().equals(String.withCString("Const")))
            return false;
        if (def.res() == 0 || def.memRes() != 0)
            return false;
        for (u32 k = (u32)0; k < def.ops().count(); k = k + (u32)1)
            if (((IROperand*)def.ops().get(k)).kind() == (u8)OPK_USE)
                return false;
        return true;
        }

    final bool runIsCloneable(u32 idx, Map* defOf)
        {
        IRInsn* addr = (IRInsn*)_sgAddrs.get(idx);
        IRInsn* load = (IRInsn*)_sgLoads.get(idx);
        IRBlock* run = (IRBlock*)_sgRuns.get(idx);
        Map* defined = new Map();
        defined.set((Hashable*)addr.res(), (Object*)addr);
        if (load.memRes() != 0)
            defined.set((Hashable*)load.memRes(), (Object*)load);
        for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)run.insns().get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* op = (IROperand*)n.ops().get(k);
                if (op.kind() != (u8)OPK_USE || op.val() == 0)
                    continue;
                if (defined.get((Hashable*)op.val()) != 0)
                    continue;
                // No def: a parameter, which dominates the clone.
                IRInsn* def = (IRInsn*)defOf.get((Hashable*)op.val());
                if (def != 0 && !isRematerialisable(def))
                    return false;
                }
            if (n.res() != 0)
                defined.set((Hashable*)n.res(), (Object*)n);
            if (n.memRes() != 0)
                defined.set((Hashable*)n.memRes(), (Object*)n);
            }
        return true;
        }

    final void buildHoistedGuard(IRFunc* fn, u32 idx, IROperand* entryMem, Map* defOf,
                           Array* newBlocks, Array* checks, Array* merges)
        {
        String* sym = (String*)_sgSyms.get(idx);
        IRInsn* addr = (IRInsn*)_sgAddrs.get(idx);
        IRInsn* load = (IRInsn*)_sgLoads.get(idx);
        IRInsn* icmp = (IRInsn*)_sgIcmps.get(idx);
        IRInsn* const0 = (IRInsn*)_sgConsts.get(idx);
        IRBlock* run = (IRBlock*)_sgRuns.get(idx);

        IRBlock* C = new IRBlock(hoistName(sym, "_hoist_chk"));
        IRBlock* R = new IRBlock(hoistName(sym, "_hoist_run"));
        IRBlock* M = new IRBlock(hoistName(sym, "_hoist_mrg"));
        // Creation ORDER is load-bearing: the original allocates the load's
        // DATA value before its memory token (freshVal v, then m1), and the
        // after-the-fact numbering must replay exactly that sequence.
        IRValue* a = new IRValue(addr.res().ty());
        IRValue* v = new IRValue(load.res().ty());
        IRValue* m1 = new IRValue(String.withCString("Mem"));

        buildHoistedCheck(C, R, M, addr, load, icmp, const0, entryMem, a, v, m1);
        cloneInitBlock(run, R, M, addr, load, a, m1, defOf);

        newBlocks.add((Object*)C);
        newBlocks.add((Object*)R);
        newBlocks.add((Object*)M);
        checks.add((Object*)C);
        merges.add((Object*)M);
        }

    // The hoisted CHECK block: AddrOf the flag, Load it, compare against zero,
    // and branch to the cloned init or straight to the merge.
    final void buildHoistedCheck(IRBlock* C, IRBlock* R, IRBlock* M,
                           IRInsn* addr, IRInsn* load, IRInsn* icmp, IRInsn* const0,
                           IROperand* entryMem, IRValue* a, IRValue* v, IRValue* m1)
        {
        IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
        ad.setRes(a);
        for (u32 k = (u32)0; k < addr.ops().count(); k = k + (u32)1)
            ad.add((IROperand*)addr.ops().get(k));
        C.add(ad);

        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.setRes(v);
        ld.setMemRes(m1);
        ld.add(IROperand.useVal(a));
        ld.add(entryMem);
        C.add(ld);

        IROperand* rhs;
        if (const0 != 0)
            {
            IRValue* z = new IRValue(const0.res().ty());
            IRInsn* zi = IRInsn.with(String.withCString("Const"));
            zi.setRes(z);
            for (u32 k = (u32)0; k < const0.ops().count(); k = k + (u32)1)
                zi.add((IROperand*)const0.ops().get(k));
            C.add(zi);
            rhs = IROperand.useVal(z);
            }
        else
            {
            rhs = (IROperand*)icmp.ops().get((u32)1); // the immediate 0
            }
        IRValue* c = new IRValue(icmp.res().ty());
        IRInsn* cm = IRInsn.with(String.withCString("ICmp"));
        cm.setRes(c);
        cm.setPred(String.withString(icmp.pred())); // EQ/0 or NE/2 — same guard
        cm.add(IROperand.useVal(ld.res()));
        cm.add(rhs);
        C.add(cm);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(c));
        cb.add(IROperand.block(R));
        cb.add(IROperand.block(M));
        C.setTerm(cb);
        }

    // The representative's init block, cloned into `R`. Its Store names the
    // guard block's AddrOf and threads the guard Load's memory, so both remap
    // onto the clones the check block just built.
    final void cloneInitBlock(IRBlock* run, IRBlock* R, IRBlock* M,
                        IRInsn* addr, IRInsn* load, IRValue* a, IRValue* m1,
                        Map* defOf)
        {
        Map* map = new Map();
        map.set((Hashable*)addr.res(), (Object*)IROperand.useVal(a));
        if (load.memRes() != 0)
            map.set((Hashable*)load.memRes(), (Object*)IROperand.useVal(m1));
        for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)run.insns().get(i);
            // A value from outside the block is rebuilt here, ahead of its
            // first use (runIsCloneable admitted only those that can be).
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* op = (IROperand*)n.ops().get(k);
                if (op.kind() != (u8)OPK_USE || op.val() == 0)
                    continue;
                if (map.get((Hashable*)op.val()) != 0)
                    continue;
                IRInsn* def = (IRInsn*)defOf.get((Hashable*)op.val());
                if (def == 0)
                    continue;
                IRValue* rv = new IRValue(def.res().ty());
                IRInsn* re = IRInsn.with(def.op());
                re.setRes(rv);
                for (u32 j = (u32)0; j < def.ops().count(); j = j + (u32)1)
                    re.add((IROperand*)def.ops().get(j));
                R.add(re);
                map.set((Hashable*)op.val(), (Object*)IROperand.useVal(rv));
                }
            R.add(cloneWithFreshResults(map, n));
            }
        IRInsn* rbr = IRInsn.with(String.withCString("Branch"));
        rbr.add(IROperand.block(M));
        R.setTerm(rbr);
        }

    final IRInsn* cloneWithFreshResults(Map* map, IRInsn* n)
        {
        IRInsn* cl = IRInsn.with(n.op());
        cl.copyDbg(n);
        cl.setPred(n.pred());
        cl.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            cl.add(self.substOperand(map, (IROperand*)n.ops().get(k)));
        if (n.res() != 0)
            {
            IRValue* nr = new IRValue(n.res().ty());
            cl.setRes(nr);
            map.set((Hashable*)n.res(), (Object*)IROperand.useVal(nr));
            }
        if (n.memRes() != 0)
            {
            IRValue* nm = new IRValue(String.withCString("Mem"));
            cl.setMemRes(nm);
            map.set((Hashable*)n.memRes(), (Object*)IROperand.useVal(nm));
            }
        return cl;
        }

    final String* hoistName(String* sym, string suffix)
        {
        String* n = String.withString(sym);
        n.appendCString(suffix);
        return n;
        }
    }
