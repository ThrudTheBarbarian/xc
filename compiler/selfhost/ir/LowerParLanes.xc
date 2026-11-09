// LowerParLanes.xc — per-thread lane vectorisation of a `par` kernel's reductions.
// One of the files class Lower is split into (2026-11-02), so the split
// build compiles the lowering side by side; Lower.xc says how they layer.


#import "Foundation.xc"
#import <Node>
#import "NodeDefs.xc"
#import <Types>
#import <Vtable>
#import <Ir>
#import "IrDefs.xc"
#import <FloatEncoding>
#import <ParSpirv>
#import "ParSpirvDefs.xc"
#import <ParWgsl>
#import <Overload>
#import "Process.xc"
#import <OptBase>
#import <Opt>
#import "OptDefs.xc"
#import <IrParse>
#import <LowerBase>
#import <LowerParCommon>
#import <LowerParMetal>

    class Lower (ParLanes)
    {

    // ── per-thread lane vectorisation ─────────────────────────────────────
    // The canonical reduce loop (one straight-line body that reads the item
    // index and folds a U32 with +, no memory and no branches inside) runs two
    // items per thread as uint2 lanes, summing the lanes at the end. This is
    // the shape the hashcat-style MD5 block has; anything else prints scalar.

    final IRInsn* mslDefVal(IRValue* v)
        {
        if (v == (IRValue*)0) return (IRInsn*)0;
        return (IRInsn*)_mDef.get((Hashable*)self.mslKey(v));
        }
    final IRValue* mslPhiFrom(IRInsn* ph, IRBlock* from)
        {
        for (u32 k = (u32)0; k + (u32)1 < ph.ops().count(); k = k + (u32)2)
            if (((IROperand*)ph.ops().get(k)).blk() == from)
                {
                IROperand* v = (IROperand*)ph.ops().get(k + (u32)1);
                return v.kind() == (u8)OPK_USE ? v.val() : (IRValue*)0;
                }
        return (IRValue*)0;
        }
    // The one phi incoming from a block OTHER than `from` (the preheader edge).
    final IRValue* mslPhiNot(IRInsn* ph, IRBlock* from)
        {
        for (u32 k = (u32)0; k + (u32)1 < ph.ops().count(); k = k + (u32)2)
            if (((IROperand*)ph.ops().get(k)).blk() != from)
                {
                IROperand* v = (IROperand*)ph.ops().get(k + (u32)1);
                return v.kind() == (u8)OPK_USE ? v.val() : (IRValue*)0;
                }
        return (IRValue*)0;
        }
    // The ParChunk field a value loads, following one optional Trunc: for a
    // value that is Trunc(Load(FieldAddr self #k)) or Load(FieldAddr self #k),
    // returns k, else -1. This pins the induction start (lo, field 1), the
    // bound (hi, field 2) and the reduction field.
    final i64 mslFieldVia(IRValue* v)
        {
        IRInsn* d = mslDefVal(v);
        if (d == (IRInsn*)0) return (i64)-1;
        if (d.op().equals(String.withCString("Trunc")))
            {
            IROperand* o = (IROperand*)d.ops().get((u32)0);
            if (o.kind() != (u8)OPK_USE) return (i64)-1;
            d = mslDefVal(o.val());
            if (d == (IRInsn*)0) return (i64)-1;
            }
        if (!d.op().equals(String.withCString("Load"))) return (i64)-1;
        IROperand* p = (IROperand*)d.ops().get((u32)0);
        if (p.kind() != (u8)OPK_USE) return (i64)-1;
        return self.mslSelfField(mslDefVal(p.val()));
        }
    final bool mslLaneOp(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("Add"))
            || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Not"))
            || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr"))
            || op.equals(String.withCString("AShr"));
        }
    final bool mslSameVal(IRValue* a, IRValue* b)
        {
        return a != (IRValue*)0 && b != (IRValue*)0 && a.seq() == b.seq();
        }
    // Emit the body's kept instructions (all but the induction increment, the
    // reduction fold and the loop compare) at `width` (2 uint2, 1 scalar) into
    // `out`. The induction value is declared by the caller.
    final bool mslLaneEmit(IRBlock* body, IRValue* skA, IRValue* skB, IRValue* skC, u32 width, String* out)
        {
        _mVecW = width;
        for (u32 i = (u32)0; i < body.insns().count(); i = i + (u32)1)
            {
            IRInsn* ip = (IRInsn*)body.insns().get(i);
            IRValue* r = ip.res();
            if (r == (IRValue*)0 || mslSameVal(r, skA) || mslSameVal(r, skB) || mslSameVal(r, skC)) continue;
            out.appendCString("    "); out.append(self.mslDecl(r));
            }
        for (u32 i = (u32)0; i < body.insns().count(); i = i + (u32)1)
            {
            IRInsn* ip = (IRInsn*)body.insns().get(i);
            IRValue* r = ip.res();
            if (r != (IRValue*)0 && (mslSameVal(r, skA) || mslSameVal(r, skB) || mslSameVal(r, skC))) continue;
            String* st = self.mslStatement(ip);
            if (st == (String*)0) { _mVecW = (u32)0; return false; }
            if (st.byteLength() > (u32)0) { out.appendCString("            "); out.append(st); out.appendCString("\n"); }
            }
        _mVecW = (u32)0;
        return true;
        }
    // A value the body may use: one of the two phis, or defined by a body
    // instruction. A use of anything else (a captured loop-invariant loaded in
    // the preheader, say) is not available in the lane scaffold, so the loop is
    // not vectorisable and falls back to the scalar kernel (bug: par_loop_capture).
    final bool mslLaneHas(IRValue* v, IRBlock* body, IRInsn* indPhi, IRInsn* redPhi)
        {
        if (v == (IRValue*)0) return true;
        if (mslSameVal(v, indPhi.res()) || mslSameVal(v, redPhi.res())) return true;
        for (u32 i = (u32)0; i < body.insns().count(); i = i + (u32)1)
            if (mslSameVal(((IRInsn*)body.insns().get(i)).res(), v)) return true;
        return false;
        }
    // Detect the canonical vectorisable reduce loop, setting the _ln* fields.
    // Backend-independent (uses the IR helpers over _mDef, which every par
    // printer populates through mslAnalyse). True when f is a single
    // straight-line body that reads the item index over the whole chunk range
    // and folds one U32 with +, no memory and no branches inside.
    final bool laneDetect(IRFunc* f)
        {
        // The loop body is the block whose CondBranch has an edge back to
        // itself (loopRotate leaves the rotated loop this shape).
        IRBlock* body = (IRBlock*)0;
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(bi);
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3) continue;
            if (((IROperand*)t.ops().get((u32)1)).blk() == bb || ((IROperand*)t.ops().get((u32)2)).blk() == bb)
                { body = bb; break; }
            }
        if (body == (IRBlock*)0 || body.phis().count() != (u32)2) return false;
        IRInsn* term = body.term();
        if (((IROperand*)term.ops().get((u32)1)).blk() != body) return false;           // true edge loops back
        IROperand* condOp = (IROperand*)term.ops().get((u32)0);
        if (condOp.kind() != (u8)OPK_USE) return false;
        IRInsn* cmp = mslDefVal(condOp.val());
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || !cmp.pred().equals(String.withCString("ULT"))) return false;
        IROperand* icA = (IROperand*)cmp.ops().get((u32)0);
        IROperand* icB = (IROperand*)cmp.ops().get((u32)1);
        if (icA.kind() != (u8)OPK_USE || icB.kind() != (u8)OPK_USE) return false;
        IRValue* indNext = icA.val();
        IRValue* bound = icB.val();
        IRInsn* incr = mslDefVal(indNext);
        if (incr == (IRInsn*)0 || !incr.op().equals(String.withCString("Add"))) return false;
        IROperand* a0 = (IROperand*)incr.ops().get((u32)0);
        IROperand* a1 = (IROperand*)incr.ops().get((u32)1);
        IRValue* indPhiVal = (IRValue*)0;
        if (a0.kind() == (u8)OPK_USE && a1.kind() == (u8)OPK_IMMI && a1.imm() == (i64)1) indPhiVal = a0.val();
        else if (a1.kind() == (u8)OPK_USE && a0.kind() == (u8)OPK_IMMI && a0.imm() == (i64)1) indPhiVal = a1.val();
        else return false;
        IRInsn* p0 = (IRInsn*)body.phis().get((u32)0);
        IRInsn* p1 = (IRInsn*)body.phis().get((u32)1);
        IRInsn* indPhi = (IRInsn*)0; IRInsn* redPhi = (IRInsn*)0;
        if (mslSameVal(p0.res(), indPhiVal)) { indPhi = p0; redPhi = p1; }
        else if (mslSameVal(p1.res(), indPhiVal)) { indPhi = p1; redPhi = p0; }
        else return false;
        if (!indPhi.res().ty().equals(String.withCString("U32")) || !redPhi.res().ty().equals(String.withCString("U32"))) return false;
        // lo/hi must be exactly ParChunk's fields 1 and 2, since the emitted
        // loop uses the kernel's own lo/hi.
        if (mslFieldVia(mslPhiNot(indPhi, body)) != (i64)1) return false;               // induction starts at lo
        if (mslFieldVia(bound) != (i64)2) return false;                                 // bound is hi
        IRValue* redNext = mslPhiFrom(redPhi, body);
        if (redNext == (IRValue*)0) return false;
        i64 redFld = mslFieldVia(mslPhiNot(redPhi, body));
        if (redFld < (i64)0) return false;
        String* redOp = _mRedOps != (Map*)0 ? (String*)_mRedOps.get((Hashable*)String.withU32((u32)redFld)) : (String*)0;
        if (redOp == (String*)0 || !redOp.equals(String.withCString("+"))) return false;
        for (u32 i = (u32)0; i < body.insns().count(); i = i + (u32)1)
            {
            IRInsn* ip = (IRInsn*)body.insns().get(i);
            IRValue* r = ip.res();
            if (r != (IRValue*)0 && (mslSameVal(r, indNext) || mslSameVal(r, cmp.res()))) continue;
            if (!mslLaneOp(ip.op())) return false;
            // Every input must be a lane value (a phi or a body result); a use
            // of a value defined outside the body cannot be vectorised here.
            for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)ip.ops().get(k);
                if (o.kind() == (u8)OPK_USE && !mslLaneHas(o.val(), body, indPhi, redPhi)) return false;
                }
            }
        _lnBody = body; _lnIndPhi = indPhi; _lnRedPhi = redPhi;
        _lnRedNext = redNext; _lnIndNext = indNext; _lnCmpRes = cmp.res(); _lnRedOff = _mObj.offsetAt((u32)redFld);
        return true;
        }
    final String* mslLaneBody(IRFunc* f)
        {
        if (!laneDetect(f)) return (String*)0;
        IRBlock* body = _lnBody;
        String* indName = self.mslName(_lnIndPhi.res());
        String* accName = self.mslName(_lnRedPhi.res());
        String* nextName = self.mslName(_lnRedNext);
        String* off = String.withU32(_lnRedOff);
        String* b = new String();
        b.appendCString("    uint2 _vacc = uint2(0);\n");
        b.appendCString("    long _vb = lo;\n");
        b.appendCString("    for (; _vb + 1 < hi; _vb += 2) {\n");
        b.appendCString("        uint2 "); b.append(indName); b.appendCString(" = uint2(uint(_vb), uint(_vb + 1));\n");
        b.appendCString("        uint2 "); b.append(accName); b.appendCString(" = _vacc;\n");
        if (!mslLaneEmit(body, _lnIndNext, _lnCmpRes, (IRValue*)0, (u32)2, b)) return (String*)0;
        b.appendCString("        _vacc = "); b.append(nextName); b.appendCString(";\n    }\n");
        b.appendCString("    uint _vtot = *(thread uint*)(st + "); b.append(off); b.appendCString(") + _vacc.x + _vacc.y;\n");
        b.appendCString("    if (_vb < hi) {\n");
        b.appendCString("        uint "); b.append(indName); b.appendCString(" = uint(_vb);\n");
        b.appendCString("        uint "); b.append(accName); b.appendCString(" = _vtot;\n");
        if (!mslLaneEmit(body, _lnIndNext, _lnCmpRes, (IRValue*)0, (u32)1, b)) return (String*)0;
        b.appendCString("        _vtot = "); b.append(nextName); b.appendCString(";\n    }\n");
        b.appendCString("    *(thread uint*)(st + "); b.append(off); b.appendCString(") = _vtot;\n");
        return b;
        }

    final String* parMsl(IRFunc* f)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = false;
        _mVecW = (u32)0;
        _mParams = (Map*)0;
        _mGlobals = new Array();
        _mGlobalOf = new Map();
        if (f.params().count() == (u32)0) return (String*)0;
        _mObj = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        // lo and hi are ParChunk's two i64 ivars, fields 1 and 2 (0 is the vtable).
        if (_mObj == (IRLayout*)0 || _mObj.fieldCount() < (u32)3 || !_mObj.typeAt((u32)1).equals(String.withCString("I64")) || !_mObj.typeAt((u32)2).equals(String.withCString("I64")))
            return (String*)0;
        if (!self.mslAnalyse(f)) return (String*)0;
        String* decls = String.withCString("");
        String* body = String.withCString("");
        _mHelperText = new Array();
        _mHelperNames = new Map();
        if (!self.mslBody(f, decls, body)) return (String*)0;
        if (_mFailed) return (String*)0;
        // Two items per thread as uint2 lanes, where the body allows it; the
        // header line, parameters and reduction tail below stay the same.
        String* laneBody = mslLaneBody(f);
        // The header line the runtime reads, and the kernel's parameters.
        String* meta = String.withCString("// xcpar msl size=");
        meta.append(String.withU32(_mObj.size())); meta.appendCString(" lo="); meta.append(String.withU32(_mObj.offsetAt((u32)1)));
        meta.appendCString(" hi="); meta.append(String.withU32(_mObj.offsetAt((u32)2)));
        String* params = String.withCString("constant uchar* args [[buffer(0)]], constant long* span [[buffer(1)]]");
        String* tail = String.withCString("");
        u32 slot = (u32)2;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mBufs.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* pe = self.mslPointee(_mObj.typeAt(k));
            String* et = self.mslScalar(pe);
            if (et == (String*)0) return (String*)0;
            meta.appendCString(" buf="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":");
            meta.append(String.withU32(k - (u32)3)); meta.appendCString(":"); meta.append(String.withU32(self.mslWidth(pe)));
            params.appendCString(self.mslIsConst((i64)k) ? ", constant " : ", device "); params.append(et); params.appendCString("* buf_"); params.append(String.withU32(k));
            params.appendCString(" [[buffer("); params.append(String.withU32(slot)); params.appendCString(")]]");
            slot = slot + (u32)1;
            }
        for (u32 gi = (u32)0; gi < _mGlobals.count(); gi = gi + (u32)1)
            {
            String* gn = (String*)_mGlobals.get(gi);
            IRSymbol* gs = (IRSymbol*)0;
            for (u32 q = (u32)0; q < _m.syms().count(); q = q + (u32)1)
                if (((IRSymbol*)_m.syms().get(q)).name().equals(gn))
                    gs = (IRSymbol*)_m.syms().get(q);
            String* gt = gs != (IRSymbol*)0 ? gs.dataType() : (String*)0;
            IRLayout* gl = self.mslLayoutOf(gt);
            String* et = gl != (IRLayout*)0 ? gl.typeAt((u32)0) : gt;
            // An array of structs: the word it is held in
            // (parWordStructs).
            String* fe = self.parWordOf(et);
            if (fe != (String*)0)
                et = fe;
            String* en = self.mslScalar(et);
            if (en == (String*)0) return (String*)0;
            meta.appendCString(" glob="); meta.append(gn); meta.appendCString(":"); meta.append(String.withU32(self.mslWidth(et)));
            params.appendCString(", device "); params.append(en); params.appendCString("* glob_"); params.append(String.withU32(gi));
            params.appendCString(" [[buffer("); params.append(String.withU32(slot)); params.appendCString(")]]");
            slot = slot + (u32)1;
            }
        if (_parExtraMeta != (String*)0) meta.append(_parExtraMeta);
        String* mDtail = new String();
        String* mShared = new String();
        bool mDevred = _mRedOps != (Map*)0;
        bool mAnyRed = false;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            if (_mReds.get((Hashable*)String.withI64((i64)k)) != (Object*)0)
                mAnyRed = true;
        if (!mAnyRed)
            mDevred = false;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* et = self.mslScalar(_mObj.typeAt(k));
            if (et == (String*)0) return (String*)0;
            meta.appendCString(" red="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":"); meta.append(String.withU32(self.mslWidth(_mObj.typeAt(k))));
            params.appendCString(", device "); params.append(et); params.appendCString("* red_"); params.append(String.withU32(k));
            params.appendCString(" [[buffer("); params.append(String.withU32(slot)); params.appendCString(")]]");
            slot = slot + (u32)1;
            tail.appendCString("    red_"); tail.append(String.withU32(k)); tail.appendCString("[tid] = *(thread "); tail.append(et);
            tail.appendCString("*)(st + "); tail.append(String.withU32(_mObj.offsetAt(k))); tail.appendCString(");\n");
            // On the device (bug 645): the workgroup's values through
            // threadgroup memory, combined in a fixed tree; thread 0 writes
            // its one partial.
            String* rop = _mRedOps != (Map*)0 ? (String*)_mRedOps.get((Hashable*)String.withU32(k)) : (String*)0;
            bool isFloat = self.ptxIs(_mObj.typeAt(k), "F32") || self.ptxIs(_mObj.typeAt(k), "F64");
            String* comb = (String*)0;
            if (rop != (String*)0 && (rop.equals(self.ptxS("min")) || rop.equals(self.ptxS("max"))))
                comb = String.withFormat("%s(sh_%u[lid], sh_%u[lid + s])", rop.cString(), k, k);
            else if (rop != (String*)0 && (rop.equals(self.ptxS("+")) || rop.equals(self.ptxS("*")) ||
                     (!isFloat && (rop.equals(self.ptxS("&")) || rop.equals(self.ptxS("|")) || rop.equals(self.ptxS("^"))))))
                comb = String.withFormat("sh_%u[lid] %s sh_%u[lid + s]", k, rop.cString(), k);
            if (comb == (String*)0)
                mDevred = false;
            else
                {
                mShared.appendFormat("    threadgroup %s sh_%u[256];\n", et.cString(), k);
                mDtail.appendFormat("    sh_%u[lid] = *(thread %s*)(st + %u);\n", k, et.cString(), _mObj.offsetAt(k));
                mDtail.appendCString("    threadgroup_barrier(mem_flags::mem_threadgroup);\n    for (uint s = 128; s > 0; s >>= 1) {\n");
                mDtail.appendFormat("        if (lid < s) sh_%u[lid] = %s;\n", k, comb.cString());
                mDtail.appendCString("        threadgroup_barrier(mem_flags::mem_threadgroup);\n    }\n");
                mDtail.appendFormat("    if (lid == 0) red_%u[gid] = sh_%u[0];\n", k, k);
                }
            }
        if (mDevred) meta.appendCString(" devred devlast");
        // A speed-goal block's runtime compiles it with fast maths (MTLMathModeFast).
        if (_mFast) meta.appendCString(" fast");
        String* out = String.withString(meta);
        out.appendCString("\n#include <metal_stdlib>\nusing namespace metal;\n");
        for (u32 i = (u32)0; i < _mHelperText.count(); i = i + (u32)1)
            out.append((String*)_mHelperText.get(i));
        out.appendCString("kernel void par_kernel("); out.append(params);
        if (mDevred)
            out.appendCString(", uint tid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]], uint gid [[threadgroup_position_in_grid]])\n{\n");
        else
            out.appendCString(", uint tid [[thread_position_in_grid]])\n{\n");
        out.append(mShared);
        out.appendCString("    thread uchar st["); out.append(String.withU32(_mObj.size())); out.appendCString("];\n");
        out.appendCString("    for (uint q = 0; q < "); out.append(String.withU32(_mObj.size())); out.appendCString("u; q++) st[q] = args[q];\n");
        out.appendCString("    long lo = span[0] + long(tid) * span[2];\n");
        out.appendCString("    long hi = min(lo + span[2], span[1]);\n");
        out.appendCString("    *(thread long*)(st + "); out.append(String.withU32(_mObj.offsetAt((u32)1))); out.appendCString(") = lo;\n");
        out.appendCString("    *(thread long*)(st + "); out.append(String.withU32(_mObj.offsetAt((u32)2))); out.appendCString(") = hi;\n");
        if (laneBody != (String*)0)
            out.append(laneBody);
        else
            {
            out.append(decls);
            String* structured = self.sStructured(f, "        ");
            if (structured != (String*)0)
                {
                out.appendCString("    if (lo < hi) do {\n");
                out.append(structured);
                out.appendCString("    } while (false);\n");
                }
            else
                {
                out.appendCString("    uint pc = 0;\n    while (lo < hi && pc != 0xffffffffu) {\n        switch (pc) {\n");
                out.append(body);
                out.appendCString("        default: pc = 0xffffffffu; continue;\n        }\n    }\n");
                }
            }
        if (mDevred)
            // Every thread reaches every barrier: one past the range holds its
            // reductions' starting values, which leave the result unchanged.
            out.append(mDtail);
        else
            {
            out.appendCString("    if (lo >= span[1]) return;\n");
            out.append(tail);
            }
        out.appendCString("}\n");
        // A device-side fold (bug 645), the same shape as the Vulkan path's
        // second entry point: one workgroup of 256 reads the workgroups'
        // partials, each lane accumulating the strided ones from the identity
        // the block object holds, then the same tree the kernel runs, leaving
        // the result in slot 0. The host dispatches it after the kernel with a
        // buffer barrier between (the reference explains why not a counter).
        if (mDevred)
            {
            out.appendCString("kernel void par_fold("); out.append(params);
            out.appendCString(", uint lid [[thread_position_in_threadgroup]])\n{\n");
            out.append(mShared);
            out.appendCString("    long nparts = span[3];\n");
            for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
                {
                if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
                String* et = self.mslScalar(_mObj.typeAt(k));
                if (et == (String*)0) continue;
                String* rop = (String*)_mRedOps.get((Hashable*)String.withU32(k));
                bool isF = self.ptxIs(_mObj.typeAt(k), "F32") || self.ptxIs(_mObj.typeAt(k), "F64");
                String* cmb = (String*)0;
                String* accop = (String*)0;
                if (rop != (String*)0 && (rop.equals(self.ptxS("min")) || rop.equals(self.ptxS("max"))))
                    {
                    cmb = String.withFormat("%s(sh_%u[lid], sh_%u[lid + s])", rop.cString(), k, k);
                    accop = String.withFormat("%s(acc_%u, red_%u[j])", rop.cString(), k, k);
                    }
                else if (rop != (String*)0 && (rop.equals(self.ptxS("+")) || rop.equals(self.ptxS("*")) ||
                         (!isF && (rop.equals(self.ptxS("&")) || rop.equals(self.ptxS("|")) || rop.equals(self.ptxS("^"))))))
                    {
                    cmb = String.withFormat("sh_%u[lid] %s sh_%u[lid + s]", k, rop.cString(), k);
                    accop = String.withFormat("acc_%u %s red_%u[j]", k, rop.cString(), k);
                    }
                if (accop == (String*)0)
                    continue;
                out.appendFormat("    %s acc_%u = *(constant %s*)(args + %u);\n",
                                 et.cString(), k, et.cString(), _mObj.offsetAt(k));
                out.appendFormat("    for (long j = (long)lid; j < nparts; j += 256) acc_%u = %s;\n",
                                 k, accop.cString());
                out.appendFormat("    sh_%u[lid] = acc_%u;\n", k, k);
                out.appendCString("    threadgroup_barrier(mem_flags::mem_threadgroup);\n    for (uint s = 128; s > 0; s >>= 1) {\n");
                out.appendFormat("        if (lid < s) sh_%u[lid] = %s;\n", k, cmb.cString());
                out.appendCString("        threadgroup_barrier(mem_flags::mem_threadgroup);\n    }\n");
                out.appendFormat("    if (lid == 0) red_%u[0] = sh_%u[0];\n", k, k);
                }
            out.appendCString("}\n");
            }
        return out;
        }
    }
