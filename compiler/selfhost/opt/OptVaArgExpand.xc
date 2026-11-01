// OptVaArgExpand.xc — the VaArgExpand pass, ported from src/xtc/ir/XTIROptVaArgExpand.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (VaArgExpand)
    {

    // ── vaarg-expand ─────────────────────────────────────────────────────
    //
    // MANDATORY on every target whose varargs travel in the pack buffer: the
    // back end has no case for the abstract VaStart/VaArg, so they are gone by
    // the time it runs whatever the level. (arm9 passes its tail in registers
    // and lowers the ops itself, which is why the profile turns this off.)
    //
    // `VaStart` zeroes the cursor; `VaArg` reads `__xtc_va_buf[cursor]` at the
    // result type and advances. The expansion is the lowering's old inline one,
    // instruction for instruction.
    final void vaArgExpand(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            vaInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    final void vaInFunc(IRModule* m, IRFunc* fn)
        {
        if (!hasVaOps(fn))
            return;
        String* buf = vaBuffer(m);
        // old value -> its replacement; the originals leave the IR, so every
        // remaining use of one is rewritten in a second walk.
        Map* remap = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* out = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.op().equals(String.withCString("VaStart")))
                    expandVaStart(n, out, remap);
                else if (n.op().equals(String.withCString("VaArg")))
                    expandVaArg(m, n, out, remap, buf);
                else
                    out.add((Object*)n);
                }
            bb.setInsns(out);
            }
        applyRemap(fn, remap);
        }

    final bool hasVaOps(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(i)).op();
                if (op.equals(String.withCString("VaStart")) || op.equals(String.withCString("VaArg")))
                    return true;
                }
            }
        return false;
        }

    // The shared 128-byte pack buffer — found or made, exactly as the lowering
    // makes it, because a second one would be a second buffer.
    final String* vaBuffer(IRModule* m)
        {
        String* name = String.withCString("__xtc_va_buf");
        if (symNamed(m, name) != 0)
            return name;
        IRLayout* l = IRLayout.with((u32)128, (u32)1);
        u32 id = m.addLayout(l);
        String* ty = String.withCString("Agg(");
        ty.appendFormat("%ld", (i32)id);
        ty.appendCString(")");
        m.addSym(IRSymbol.dataGlobal(name, ty));
        return name;
        }

    final void push(Array* out, IRInsn* n)
        {
        out.add((Object*)n);
        }

    // Read one argument out of the buffer at `slotPtr`. Three shapes: a struct
    // stays IN the buffer and only its address is handed back; a narrow int was
    // widened by the packer and is read wide and truncated; everything else is
    // one load at its own type.
    final IRValue* readVaSlot(IRModule* m, Array* out, String* resT,
                        IRValue* slotPtr, IRValue* m1)
        {
        if (isStructPtr(resT))
            {
            IRValue* r = new IRValue(resT);
            IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
            bc.setRes(r);
            bc.add(IROperand.useVal(slotPtr));
            push(out, bc);
            u32 w = aggWidth(m, resT);
            if (w > (u32)0)
                _vaAdvance = w;
            return r;
            }
        if (isNarrowInt(resT))
            {
            // The packer widened a narrow int to two bytes: read it wide and
            // truncate, or the high byte is read as the next argument.
            bool sgn = resT.equals(String.withCString("I8"));
            String* wide = String.withCString(sgn ? "I16" : "U16");
            IRValue* wv = new IRValue(wide);
            IRValue* m2 = new IRValue(String.withCString("Mem"));
            IRInsn* l2 = IRInsn.with(String.withCString("Load"));
            l2.setRes(wv);
            l2.setMemRes(m2);
            l2.add(IROperand.useVal(slotPtr));
            l2.add(IROperand.useVal(m1));
            push(out, l2);
            _vaMem = m2;
            IRValue* r = new IRValue(resT);
            IRInsn* tr = IRInsn.with(String.withCString("Trunc"));
            tr.setRes(r);
            tr.add(IROperand.useVal(wv));
            push(out, tr);
            return r;
            }
        IRValue* m2 = new IRValue(String.withCString("Mem"));
        IRValue* r = new IRValue(resT);
        IRInsn* l2 = IRInsn.with(String.withCString("Load"));
        l2.setRes(r);
        l2.setMemRes(m2);
        l2.add(IROperand.useVal(slotPtr));
        l2.add(IROperand.useVal(m1));
        push(out, l2);
        _vaMem = m2;
        return r;
        }

    final IRValue* emitConstU8(Array* out, u32 v)
        {
        IRValue* c = new IRValue(String.withCString("U8"));
        IRInsn* n = IRInsn.with(String.withCString("Const"));
        n.setRes(c);
        n.add(IROperand.immU(v, String.withCString("U8")));
        push(out, n);
        return c;
        }

    // VaStart cursorAddr, memIn → Store(cursorAddr, 0:u8, memIn)
    final void expandVaStart(IRInsn* va, Array* out, Map* remap)
        {
        IROperand* cursorAddr = (IROperand*)va.ops().get((u32)0);
        IROperand* memIn = (IROperand*)va.ops().get((u32)1);
        IRValue* zero = emitConstU8(out, (u32)0);
        IRValue* newMem = new IRValue(String.withCString("Mem"));
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        st.setMemRes(newMem);
        st.add(cursorAddr);
        st.add(IROperand.useVal(zero));
        st.add(memIn);
        push(out, st);
        if (va.memRes() != 0)
            remap.set((Hashable*)va.memRes(), (Object*)newMem);
        }

    final void expandVaArg(IRModule* m, IRInsn* va, Array* out, Map* remap, String* buf)
        {
        IROperand* cursorAddr = (IROperand*)va.ops().get((u32)0);
        IROperand* memIn = (IROperand*)va.ops().get((u32)1);
        String* resT = va.res().ty();
        String* u8Ptr = String.withCString("Ptr(U8, unbanked)");

        IRValue* bufPtr = new IRValue(u8Ptr);
        IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
        ad.setRes(bufPtr);
        ad.add(IROperand.sym(buf));
        push(out, ad);

        IRValue* cursor = new IRValue(String.withCString("U8"));
        IRValue* m1 = new IRValue(String.withCString("Mem"));
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.setRes(cursor);
        ld.setMemRes(m1);
        ld.add(cursorAddr);
        ld.add(memIn);
        push(out, ld);

        IRValue* idx = new IRValue(String.withCString("U16"));
        IRInsn* zx = IRInsn.with(String.withCString("ZExt"));
        zx.setRes(idx);
        zx.add(IROperand.useVal(cursor));
        push(out, zx);

        IRValue* slotPtr = new IRValue(u8Ptr);
        IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
        ea.setRes(slotPtr);
        ea.add(IROperand.useVal(bufPtr));
        ea.add(IROperand.useVal(idx));
        push(out, ea);

        // The packer's fixed slot stride, unless the value IS the struct in the
        // buffer — then the pointer is handed back and the cursor steps over the
        // struct itself. `_vaAdvance` / `_vaMem` are how the shape below reports
        // back: the three cases differ in all three of result, memory and stride.
        _vaAdvance = (u32)8;
        _vaMem = m1;
        IRValue* newResult = readVaSlot(m, out, resT, slotPtr, m1);
        IRValue* delta = emitConstU8(out, _vaAdvance);
        IRValue* next = new IRValue(String.withCString("U8"));
        IRInsn* ad2 = IRInsn.with(String.withCString("Add"));
        ad2.setRes(next);
        ad2.add(IROperand.useVal(cursor));
        ad2.add(IROperand.useVal(delta));
        push(out, ad2);

        IRValue* newMem = new IRValue(String.withCString("Mem"));
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        st.setMemRes(newMem);
        st.add(cursorAddr);
        st.add(IROperand.useVal(next));
        st.add(IROperand.useVal(_vaMem));
        push(out, st);

        if (va.res() != 0)
            remap.set((Hashable*)va.res(), (Object*)newResult);
        if (va.memRes() != 0)
            remap.set((Hashable*)va.memRes(), (Object*)newMem);
        }

    final bool isStructPtr(String* t)
        {
        return t.hasPrefix(String.withCString("Ptr(Agg("));
        }

    final bool isNarrowInt(String* t)
        {
        return t.equals(String.withCString("U8")) || t.equals(String.withCString("I8"));
        }

    // `Ptr(Agg(N), unbanked)` -> the size layout N records.
    final u32 aggWidth(IRModule* m, String* t)
        {
        u32 i = (u32)8; // past `Ptr(Agg(`
        u32 id = (u32)0;
        while (i < t.byteLength())
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            id = id * (u32)10 + (u32)(c - (u8)'0');
            i = i + (u32)1;
            }
        if (id >= m.layouts().count())
            return (u32)0;
        return ((IRLayout*)m.layouts().get(id)).size();
        }

    final void applyRemap(IRFunc* fn, Map* remap)
        {
        if (remap.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                remapUses((IRInsn*)bb.phis().get(i), remap);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                remapUses((IRInsn*)bb.insns().get(i), remap);
            if (bb.term() != 0)
                remapUses(bb.term(), remap);
            }
        }

    final void remapUses(IRInsn* n, Map* remap)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            Object* to = remap.get((Hashable*)o.val());
            if (to == 0)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal((IRValue*)to));
            }
        }
    }
