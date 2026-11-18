// OptRedundantLoadCSE.xc — the RedundantLoadCSE pass, ported from src/xtc/ir/XTIROptRedundantLoadCSE.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    // The key a pure instruction is value-numbered under. It compares as the
    // string `op "|p" pred "|t" type ("|" operand)*` did, where an operand is
    // "u" and its value (resolved through the replacements when the key is
    // made), "s" and a symbol name, "b" and a block name, or "i", a type, ":"
    // and the immediate's text. A missing string reads as an empty one.
    // Nothing changes an instruction while CSE holds its key, so the key keeps
    // the instruction and copies only the resolved values.
    class CSEKey
    {
    IRInsn* _n;
    IRValue* _u0;
    IRValue* _u1;
    IRValue* _u2;
    Array* _uMore; // the fourth use onwards
    u32 _nUses;
    u32 _h;

    void init(void)
        {
        _nUses = (u32)0;
        _h = (u32)0;
        }

    IRInsn* insn(void)
        {
        return _n;
        }
    void setInsn(IRInsn* n)
        {
        _n = n;
        }
    void setHash(u32 h)
        {
        _h = h;
        }

    void addUse(IRValue* v)
        {
        if (_nUses == (u32)0)
            _u0 = v;
        else if (_nUses == (u32)1)
            _u1 = v;
        else if (_nUses == (u32)2)
            _u2 = v;
        else
            {
            if (_uMore == (Array*)0)
                _uMore = new Array();
            _uMore.add((Object*)v);
            }
        _nUses = _nUses + (u32)1;
        }

    IRValue* useAt(u32 i)
        {
        if (i == (u32)0)
            return _u0;
        if (i == (u32)1)
            return _u1;
        if (i == (u32)2)
            return _u2;
        return (IRValue*)_uMore.get(i - (u32)3);
        }

    // A string's hash, a missing one hashing as the empty string.
    static u32 strHash(String* s)
        {
        if (s == (String*)0)
            return (u32)2166136261;
        return s.hash();
        }

    // String equality, a missing string equal to the empty one.
    static bool strEq(String* a, String* b)
        {
        if (a == b)
            return true;
        if (a == (String*)0)
            return b.byteLength() == (u32)0;
        if (b == (String*)0)
            return a.byteLength() == (u32)0;
        return a.equals(b);
        }

    // A block operand's name, as the string spelled it.
    static String* blockName(IROperand* o)
        {
        if (o.blk() == (IRBlock*)0)
            return (String*)0;
        return o.blk().name();
        }

    // The hash of an operand that is not a use.
    static u32 operandHash(IROperand* o)
        {
        if (o.kind() == (u8)OPK_SYM)
            return strHash(o.name()) ^ (u32)1;
        if (o.kind() == (u8)OPK_BLOCK)
            return strHash(blockName(o)) ^ (u32)2;
        u32 h = strHash(o.ty());
        if (o.kind() == (u8)OPK_IMMI)
            return h ^ ((u32)o.imm() * (u32)2654435761) ^ (u32)(o.imm() >> 32);
        if (o.kind() == (u8)OPK_IMMF)
            return h ^ strHash(o.fpHex());
        return h ^ (o.cid() * (u32)2654435761);
        }

    // Two operands that are not uses, compared as their strings were. An
    // immediate's text is `#<n>:<ty>`, `#fp<hex>:<ty>` or `#cpool:<id>`; the
    // three never coincide. A signed and an unsigned integer print alike only
    // when the bits are not negative.
    static bool operandEq(IROperand* a, IROperand* b)
        {
        u8 ka = a.kind();
        u8 kb = b.kind();
        if (ka == (u8)OPK_SYM || kb == (u8)OPK_SYM)
            return ka == kb && strEq(a.name(), b.name());
        if (ka == (u8)OPK_BLOCK || kb == (u8)OPK_BLOCK)
            return ka == kb && strEq(blockName(a), blockName(b));
        if (ka != kb || !strEq(a.ty(), b.ty()))
            return false;
        if (ka == (u8)OPK_IMMI)
            return a.imm() == b.imm() && (a.imm() >= (i64)0 || a.uimm() == b.uimm());
        if (ka == (u8)OPK_IMMF)
            return strEq(a.fpHex(), b.fpHex());
        return a.cid() == b.cid();
        }

    u32 hash(void)
        {
        return _h;
        }

    bool equals(Object* other)
        {
        CSEKey* o = (CSEKey* ?)other;
        if (o == (CSEKey*)0)
            return false;
        if (o == self)
            return true;
        if (_h != o._h || _nUses != o._nUses)
            return false;
        IRInsn* a = _n;
        IRInsn* b = o._n;
        if (a.ops().count() != b.ops().count())
            return false;
        if (!strEq(a.op(), b.op()) || !strEq(a.pred(), b.pred())
            || !strEq(a.res().ty(), b.res().ty()))
            return false;
        u32 u = (u32)0;
        for (u32 k = (u32)0; k < a.ops().count(); k = k + (u32)1)
            {
            IROperand* x = (IROperand*)a.ops().get(k);
            IROperand* y = (IROperand*)b.ops().get(k);
            bool xu = x.kind() == (u8)OPK_USE;
            bool yu = y.kind() == (u8)OPK_USE;
            if (xu != yu)
                return false;
            if (xu)
                {
                if (useAt(u) != o.useAt(u))
                    return false;
                u = u + (u32)1;
                }
            else if (!operandEq(x, y))
                return false;
            }
        return true;
        }
    }

    class Opt (RedundantLoadCSE)
    {

    final void redundantLoadCSE(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            cseInFunc((IRFunc*)m.funcs().get(f));
        }

    final void cseInFunc(IRFunc* fn)
        {
        _cseDefOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    _cseDefOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        Map* replace = new Map();  // value -> the value that wins
        Array* dead = new Array(); // IRInsn@ to drop

        // Cross-block availability, when the back end asked for it. See the
        // reference's XTIROptRedundantLoadCSE for the reasoning; the two
        // relations are:
        //   a block with exactly ONE REACHABLE predecessor inherits that
        //   predecessor's end-of-block state, because the path is a single edge
        //   with nothing executing on it. A join gets nothing.
        // Only ADDRESS computations cross for the pure table: merging a Const
        // into a dominating block is sound in isolation and still made
        // matrix_mul compute the wrong answer.
        // Reachability is load-bearing: "one predecessor, therefore it
        // dominates" is FALSE when that predecessor is itself unreachable.
        // DECLARATION ORDER, and inherit only from a predecessor already
        // processed. Writing a second DFS here gave a different postorder from
        // the reference's dominator utility, and the two optimisers then
        // disagreed on 136 of 796 files — invisible to both back-end byte
        // gates, which run at -O0 where this is not enabled. Declaration order
        // is identical in both compilers by construction.
        Array* order = fn.blocks();
        Map* outPure = new Map();
        Map* outLoaded = new Map();
        Map* preds = (Map*)0;
        if (_cseCrossBlock)
            preds = csePredsMap(fn, order);
        if (_cseLate && preds != (Map*)0)
            order = cseLateOrder(fn, preds);
        for (u32 b = (u32)0; b < order.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)order.get(b);
            Map* availPure = new Map();
            Map* loaded = new Map();
            if (_cseCrossBlock)
                {
                Array* pl = (Array*)preds.get((Hashable*)bb);
                if (pl != (Array*)0 && pl.count() == (u32)1)
                    {
                    IRBlock* P = (IRBlock*)pl.get((u32)0);
                    // Only if P has already been processed this pass.
                    Map* op = (Map*)outPure.get((Hashable*)P);
                    Map* ol = (Map*)outLoaded.get((Hashable*)P);
                    if (op != (Map*)0)
                        {
                        Array* ks = op.allKeys();
                        for (u32 k = (u32)0; k < ks.count(); k = k + (u32)1)
                            {
                            CSEKey* key = (CSEKey*)ks.get(k);
                            String* kop = key.insn().op();
                            if (kop.equals(String.withCString("AddrOf"))
                                || kop.equals(String.withCString("ElementAddr"))
                                || kop.equals(String.withCString("FieldAddr"))
                                || (_cseLate && !kop.equals(String.withCString("Const"))))
                                availPure.set((Hashable*)key, op.get((Hashable*)key));
                            }
                        }
                    if (ol != (Map*)0)
                        {
                        Array* ks = ol.allKeys();
                        for (u32 k = (u32)0; k < ks.count(); k = k + (u32)1)
                            loaded.set((Hashable*)(IRValue*)ks.get(k),
                                       ol.get((Hashable*)(IRValue*)ks.get(k)));
                        }
                    }
                }
            cseInBlock(bb, replace, dead, availPure, loaded);
            if (_cseCrossBlock)
                {
                outPure.set((Hashable*)bb, (Object*)availPure);
                outLoaded.set((Hashable*)bb, (Object*)loaded);
                }
            }
        if (replace.count() == (u32)0 && dead.count() == (u32)0)
            return;

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!self.hasInsn(dead, n))
                    keep.add((Object*)n);
                }
            bb.setInsns(keep);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            rewriteThroughReplace(bb.phis(), replace);
            rewriteThroughReplace(bb.insns(), replace);
            if (bb.term() != 0)
                rewriteInsnThroughReplace(bb.term(), replace);
            }
        }

    // Declaration order, except that a block waits for its sole predecessor
    // (the reference's `late` order). A sweep that places nothing takes the
    // first pending block.
    final Array* cseLateOrder(IRFunc* fn, Map* preds)
        {
        Array* pending = new Array();
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            pending.add(fn.blocks().get(i));
        Array* order = new Array();
        Array* placed = new Array();
        while (pending.count() > (u32)0)
            {
            bool progressed = false;
            u32 q = (u32)0;
            while (q < pending.count())
                {
                IRBlock* b = (IRBlock*)pending.get(q);
                Array* ps = (Array*)preds.get((Hashable*)b);
                if (ps != (Array*)0 && ps.count() == (u32)1 && (IRBlock*)ps.get((u32)0) != b
                    && !hasInsnBlk(placed, (IRBlock*)ps.get((u32)0)))
                    {
                    q = q + (u32)1;
                    continue;
                    }
                order.add((Object*)b);
                placed.add((Object*)b);
                pending.removeAt(q);
                progressed = true;
                }
            if (!progressed)
                {
                order.add(pending.get((u32)0));
                placed.add(pending.get((u32)0));
                pending.removeAt((u32)0);
                }
            }
        return order;
        }

    static bool hasInsnBlk(Array* a, IRBlock* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRBlock*)a.get(i) == b)
                return true;
        return false;
        }

    // Reachable blocks in REVERSE POSTORDER, so a block is always processed
    // after its predecessors on every acyclic path — which is what lets a
    // sole-predecessor inheritance read a state that has already been computed.
    final Array* cseSuccs(IRBlock* bb)
        {
        Array* out = new Array();
        IRInsn* t = bb.term();
        if (t == (IRInsn*)0)
            return out;
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0 && !self.hasBlock(out, o.blk()))
                out.add((Object*)o.blk());
            }
        return out;
        }

    // Predecessors, counting only blocks that are themselves REACHABLE.
    final Map* csePredsMap(IRFunc* fn, Array* reachable)
        {
        Map* m = new Map();
        for (u32 b = (u32)0; b < reachable.count(); b = b + (u32)1)
            m.set((Hashable*)(IRBlock*)reachable.get(b), (Object*)new Array());
        for (u32 b = (u32)0; b < reachable.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)reachable.get(b);
            Array* su = cseSuccs(bb);
            for (u32 i = (u32)0; i < su.count(); i = i + (u32)1)
                {
                Array* pl = (Array*)m.get((Hashable*)(IRBlock*)su.get(i));
                if (pl != (Array*)0 && !self.hasBlock(pl, bb))
                    pl.add((Object*)bb);
                }
            }
        return m;
        }

    final void cseInBlock(IRBlock* bb, Map* replace, Array* dead, Map* availPure, Map* loaded)
        {
        // In a large block (a vectorised MD5 round loop) a splat is made at
        // each use on purpose: merged, it would be one vector register held
        // across the block.
        bool keepSplats = bb.insns().count() > (u32)VEC_SPLAT_BIG_BODY;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (keepSplats && n.op().equals(String.withCString("VSplat")))
                continue;
            if (n.res() != 0 && n.memRes() == 0 && isCSEable(n.op()))
                {
                CSEKey* key = pureKey(n, replace);
                Object* have = availPure.get((Hashable*)key);
                if (have != 0)
                    {
                    replace.set((Hashable*)n.res(), have);
                    dead.add((Object*)n);
                    }
                else
                    {
                    availPure.set((Hashable*)key, (Object*)n.res());
                    }
                continue;
                }
            if (n.op().equals(String.withCString("Load")) && n.res() != 0 && n.ops().count() >= (u32)1 && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE)
                {
                if (reuseLoad(n, replace, loaded, dead))
                    continue;
                continue;
                }
            // A plain Store makes its value available at that pointer, and
            // disturbs only the cached loads that may alias it. Without this a
            // struct field written and read back in the same block went to the
            // frame and came straight back.
            //
            // VOLATILE stores are excluded: the whole point of one is that the
            // memory, not the value, is the observable thing.
            if (n.op().equals(String.withCString("Store")) && n.ops().count() >= (u32)2
                && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE)
                {
                IRValue* sp = resolveReplace(replace, ((IROperand*)n.ops().get((u32)0)).val());
                Array* keys = loaded.allKeys();
                for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
                    {
                    IRValue* lp = (IRValue*)keys.get(k);
                    if (cseMayAlias(sp, lp, replace))
                        loaded.remove((Hashable*)lp);
                    }
                // Only a Use can be forwarded: the table maps value to value,
                // and an immediate has no value to hand a later load.
                IROperand* sv = (IROperand*)n.ops().get((u32)1);
                if (sv.kind() == (u8)OPK_USE)
                    loaded.set((Hashable*)sp, (Object*)resolveReplace(replace, sv.val()));
                continue;
                }
            // Anything that may write memory, and the bank-state ops that
            // repoint pointers, invalidate what this block has loaded.
            if (touchesMemory(n.op()) || isBankStateOp(n.op()))
                loaded.removeAll(); // in place: the CALLER publishes this map
            }
        }

    // Can a store through `sp` change what a load through `lp` would see?
    //
    // Conservative by default — true for anything not proved apart. The one
    // case proved apart is the one that matters: two FieldAddrs off the SAME
    // base with DIFFERENT constant field indices are distinct addresses, so
    // storing p.y does not disturb a cached p.x. Without this the forwarding is
    // useless on the shape it exists for, because `store p.x; store p.y;
    // load p.x` would have the second store wipe what the first just recorded.
    final bool cseMayAlias(IRValue* sp, IRValue* lp, Map* replace)
        {
        if (sp == lp)
            return true;
        Object* so = _cseDefOf.get((Hashable*)sp);
        Object* lo = _cseDefOf.get((Hashable*)lp);
        if (so == (Object*)0 || lo == (Object*)0)
            return true;
        IRInsn* sd = (IRInsn*)so;
        IRInsn* ld = (IRInsn*)lo;
        if (!sd.op().equals(String.withCString("FieldAddr"))
            || !ld.op().equals(String.withCString("FieldAddr")))
            return true;
        if (sd.ops().count() < (u32)2 || ld.ops().count() < (u32)2)
            return true;
        IROperand* sb = (IROperand*)sd.ops().get((u32)0);
        IROperand* lb = (IROperand*)ld.ops().get((u32)0);
        if (sb.kind() != (u8)OPK_USE || lb.kind() != (u8)OPK_USE)
            return true;
        if (resolveReplace(replace, sb.val()) != resolveReplace(replace, lb.val()))
            return true;                  // different, or unknown, objects
        IROperand* si = (IROperand*)sd.ops().get((u32)1);
        IROperand* li = (IROperand*)ld.ops().get((u32)1);
        if (si.kind() != (u8)OPK_IMMI || li.kind() != (u8)OPK_IMMI)
            return true;                  // a non-constant field index
        return si.imm() == li.imm();
        }

    // A Load whose pointer this block has already read hands back the value it
    // read — provided the memory token can be rewired too.
    final bool reuseLoad(IRInsn* n, Map* replace, Map* loaded, Array* dead)
        {
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        IRValue* ptr = resolveReplace(replace, p.val());
        Object* have = loaded.get((Hashable*)ptr);
        // The cached value must be the WIDTH the load wants. A u32 stored at an
        // address and read back as a u8 is not the same value, and the table is
        // keyed only by address.
        if (have != (Object*)0 && n.res() != (IRValue*)0)
            {
            IRValue* cv = (IRValue*)have;
            if (cv.ty() == (String*)0 || !cv.ty().equals(n.res().ty()))
                have = (Object*)0;
            }
        bool canRewire = n.memRes() == 0 || (n.ops().count() >= (u32)2 && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE);
        if (have != 0 && canRewire)
            {
            replace.set((Hashable*)n.res(), have);
            if (n.memRes() != 0)
                {
                IROperand* mi = (IROperand*)n.ops().get((u32)1);
                replace.set((Hashable*)n.memRes(),
                            (Object*)resolveReplace(replace, mi.val()));
                }
            dead.add((Object*)n);
            return true;
            }
        loaded.set((Hashable*)ptr, (Object*)n.res());
        return false;
        }

    // The key an instruction is value-numbered under: its opcode, predicate,
    // result TYPE (so casts to different widths do not collapse together) and
    // its operands, with uses resolved through the replacements so far.
    final CSEKey* pureKey(IRInsn* n, Map* replace)
        {
        CSEKey* key = new CSEKey();
        key.setInsn(n);
        u32 h = CSEKey.strHash(n.op());
        h = (h ^ CSEKey.strHash(n.pred())) * (u32)16777619;
        h = (h ^ CSEKey.strHash(n.res().ty())) * (u32)16777619;
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            u32 oh = (u32)0;
            if (o.kind() == (u8)OPK_USE)
                {
                IRValue* v = resolveReplace(replace, o.val());
                key.addUse(v);
                if (v != (IRValue*)0)
                    oh = v.hash();
                }
            else
                oh = CSEKey.operandHash(o);
            h = (h ^ oh) * (u32)16777619;
            }
        key.setHash(h);
        return key;
        }

    final IRValue* resolveReplace(Map* replace, IRValue* v)
        {
        IRValue* cur = v;
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            Object* nx = replace.get((Hashable*)cur);
            if (nx == 0)
                return cur;
            if ((IRValue*)nx == cur)
                return cur;
            cur = (IRValue*)nx;
            }
        return cur;
        }

    final void rewriteThroughReplace(Array* list, Map* replace)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            rewriteInsnThroughReplace((IRInsn*)list.get(i), replace);
        }

    final void rewriteInsnThroughReplace(IRInsn* n, Map* replace)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            IRValue* r = resolveReplace(replace, o.val());
            if (r == o.val())
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(r));
            }
        }

    // Pure, deterministic and memory-free: safe to value-number. Div and Rem
    // are here — computing one twice with the same operands gives the same
    // answer, and the first one has already trapped if it was going to.
    final bool isCSEable(String* op)
        {
        if (op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem")) || op.equals(String.withCString("FDiv")) || op.equals(String.withCString("AggExtract")))
            return true;
        return speculatable0(op);
        }

    // The `speculatable` list, keyed on the opcode alone.
    final bool speculatable0(String* op)
        {
        IRInsn* probe = IRInsn.with(op);
        return self.speculatable(probe);
        }

    final bool touchesMemory(String* op)
        {
        return op.equals(String.withCString("Load")) || op.equals(String.withCString("Store")) || op.equals(String.withCString("LoadVolatile")) || op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")) || op.equals(String.withCString("AggLoad")) || op.equals(String.withCString("AggStore")) || self.isCallOp(op) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("VTblLoad")) || op.equals(String.withCString("ProtoLoad")) || op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")) || op.equals(String.withCString("WeakLoad")) || op.equals(String.withCString("Asm")) || op.equals(String.withCString("VLoad")) || op.equals(String.withCString("VStore"));
        }

    final bool isBankStateOp(String* op)
        {
        return op.equals(String.withCString("BankSave")) || op.equals(String.withCString("BankRestore")) || op.equals(String.withCString("BankSelectFor"));
        }
    }
