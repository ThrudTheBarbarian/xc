// CgCommon.xc — helpers the 64-bit back ends share.
// =========================================================================
//
// Arm64.xc and X86_64.xc carried their own copies of these, line for line the
// same, and fixes to one copy did not always reach the other (#336). These are
// the ones with no target in them: the magic-number searches for constant
// division, constant fitting, symbol references in a module, the float type
// test and the inline-asm statement splitter. Moved unchanged.

#import "Foundation.xc"
#import "Stdio.xc"
#import <Ir>
#import "IrDefs.xc"

class CgCommon
    {
    // The unsigned magic number, add-indicator and shift for `d` at width W.
    //
    // The reference works in 2W-bit arithmetic; there is no 64-bit integer
    // here, so the two places it would be needed are handled directly. 2^W mod
    // d becomes ((2^W - 1) mod d + 1) mod d, and q1's doubling is tracked with
    // an overflow flag: the loop's only use of q1 is `q1 < delta` with
    // delta < 2^W, so a q1 that has overflowed is unconditionally not less and
    // the loop simply ends. q2 is meant to wrap — the result is masked to W
    // bits — so its natural u32 wraparound at W = 32 is exactly right.
    static void magicU(u32 d, u32 W, u32* Mout, u32* aout, u32* sout)
    {
        u32 twoWm1 = (u32)1 << (W - (u32)1);
        u32 maxu = W == (u32)32 ? (u32)$FFFF_FFFF : (((u32)1 << W) - (u32)1);
        u32 a = (u32)0;
        u32 p = W - (u32)1;
        u32 nc = maxu - ((maxu % d) + (u32)1) % d;
        u32 q1 = twoWm1 / nc;
        u32 r1 = twoWm1 - q1 * nc;
        bool q1over = false;
        u32 q2 = (twoWm1 - (u32)1) / d;
        u32 r2 = (twoWm1 - (u32)1) - q2 * d;
        u32 delta = (u32)0;
        bool again = true;
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            if (r1 >= nc - r1) { q1 = q1 + q1 + (u32)1; r1 = r1 - (nc - r1); }
            else               { q1 = q1 + q1;          r1 = r1 + r1; }
            if (r2 + (u32)1 >= d - r2) {
                if (q2 >= twoWm1 - (u32)1) a = (u32)1;
                q2 = q2 + q2 + (u32)1;
                r2 = r2 - (d - r2 - (u32)1);
            } else {
                if (q2 >= twoWm1) a = (u32)1;
                q2 = q2 + q2;
                r2 = r2 + r2 + (u32)1;
            }
            delta = d - (u32)1 - r2;
            again = p < (u32)2 * W && !q1over && (q1 < delta || (q1 == delta && r1 == (u32)0));
        }
        *Mout = (q2 + (u32)1) & maxu;
        *aout = a;
        *sout = p - W;
    }

    // The signed magic number and shift, at W = 32 — the only width the signed
    // path takes. Same overflow treatment for q1 as the unsigned case.
    static void magicS(i32 dIn, i32* Mout, u32* sout)
    {
        u32 twoWm1 = (u32)$8000_0000;
        u32 ad = (u32)(dIn < (i32)0 ? -dIn : dIn);
        u32 t = twoWm1 + (((u32)dIn >> (u32)31) & (u32)1);
        u32 anc = t - (u32)1 - t % ad;
        u32 p = (u32)31;
        u32 q1 = twoWm1 / anc;
        u32 r1 = twoWm1 - q1 * anc;
        bool q1over = false;
        u32 q2 = twoWm1 / ad;
        u32 r2 = twoWm1 - q2 * ad;
        u32 delta = (u32)0;
        bool again = true;
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            q1 = q1 + q1; r1 = r1 + r1;
            if (r1 >= anc) { q1 = q1 + (u32)1; r1 = r1 - anc; }
            q2 = q2 + q2; r2 = r2 + r2;
            if (r2 >= ad) { q2 = q2 + (u32)1; r2 = r2 - ad; }
            delta = ad - r2;
            again = !q1over && (q1 < delta || (q1 == delta && r1 == (u32)0));
        }
        // The mask is the full u32 at this width, so the value is already the
        // sign-extended magic; negate it for a negative divisor.
        i32 M = (i32)(q2 + (u32)1);
        if (dIn < (i32)0) M = -M;
        *Mout = M;
        *sout = p - (u32)32;
    }

    // The unsigned magic number, add-indicator and shift for `d` at W = 64
    // (#309; Hacker's Delight 10-10). The reference works in 128-bit
    // arithmetic; here the two places that need it are handled as magicU
    // does at W = 32: 2^64 mod d is ((2^64 - 1) mod d + 1) mod d, and q1's
    // doubling carries an overflow flag (an overflowed q1 is never less than
    // delta, so the loop ends). q2 is meant to wrap.
    static void magicU64(u64 d, u64* Mout, u32* aout, u32* sout)
    {
        u64 twoWm1 = (u64)$8000_0000_0000_0000;
        u64 maxu = (u64)$FFFF_FFFF_FFFF_FFFF;
        u32 a = (u32)0;
        u32 p = (u32)63;
        u64 nc = maxu - ((maxu % d) + (u64)1) % d;
        u64 q1 = twoWm1 / nc;
        u64 r1 = twoWm1 - q1 * nc;
        bool q1over = false;
        u64 q2 = (twoWm1 - (u64)1) / d;
        u64 r2 = (twoWm1 - (u64)1) - q2 * d;
        u64 delta = (u64)0;
        bool again = true;
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            if (r1 >= nc - r1) { q1 = q1 + q1 + (u64)1; r1 = r1 - (nc - r1); }
            else { q1 = q1 + q1; r1 = r1 + r1; }
            if (r2 + (u64)1 >= d - r2) {
                if (q2 >= twoWm1 - (u64)1) a = (u32)1;
                q2 = q2 + q2 + (u64)1;
                r2 = r2 - (d - r2 - (u64)1);
            } else {
                if (q2 >= twoWm1) a = (u32)1;
                q2 = q2 + q2;
                r2 = r2 + r2 + (u64)1;
            }
            delta = d - (u64)1 - r2;
            again = p < (u32)128 && !q1over && (q1 < delta || (q1 == delta && r1 == (u64)0));
        }
        *Mout = q2 + (u64)1;
        *aout = a;
        *sout = p - (u32)64;
    }

    // The signed magic number and shift for `dIn` at W = 64 (#309; Hacker's
    // Delight 10-1), |dIn| >= 2 and not a power of two.
    static void magicS64(i64 dIn, i64* Mout, u32* sout)
    {
        u64 twoWm1 = (u64)$8000_0000_0000_0000;
        u64 ad = dIn < (i64)0 ? (u64)0 - (u64)dIn : (u64)dIn;
        u64 t = twoWm1 + (dIn < (i64)0 ? (u64)1 : (u64)0);
        u64 anc = t - (u64)1 - t % ad;
        u32 p = (u32)63;
        u64 q1 = twoWm1 / anc;
        u64 r1 = twoWm1 - q1 * anc;
        bool q1over = false;
        u64 q2 = twoWm1 / ad;
        u64 r2 = twoWm1 - q2 * ad;
        u64 delta = (u64)0;
        bool again = true;
        while (again) {
            p = p + (u32)1;
            if (q1 >= twoWm1) q1over = true;
            q1 = q1 + q1; r1 = r1 + r1;
            if (r1 >= anc) { q1 = q1 + (u64)1; r1 = r1 - anc; }
            q2 = q2 + q2; r2 = r2 + r2;
            if (r2 >= ad) { q2 = q2 + (u64)1; r2 = r2 - ad; }
            delta = ad - r2;
            again = !q1over && (q1 < delta || (q1 == delta && r1 == (u64)0));
        }
        i64 M = (i64)(q2 + (u64)1);
        if (dIn < (i64)0) M = (i64)0 - M;
        *Mout = M;
        *sout = p - (u32)64;
    }

    // `v` as a value of type `t`'s width: its low bits, sign- or zero-extended.
    static i64 fitConst(i64 v, String* t, bool sgn)
    {
        u32 b = (u32)8;
        if (t != (String*)0) {
            if (IRType.is(t, tyI8) || IRType.is(t, tyU8) || IRType.is(t, tyBool)) b = 1;
            else if (IRType.is(t, tyI16) || IRType.is(t, tyU16)) b = 2;
            else if (IRType.is(t, tyI32) || IRType.is(t, tyU32)) b = 4;
        }
        if (b == (u32)8) return v;
        u32 sh = (u32)64 - b * (u32)8;
        if (sgn) return (v << sh) >> sh;
        return (i64)(((u64)v << sh) >> sh);
    }

    static bool constSigned(String* t)
    {
        return t != (String*)0 && t.hasPrefix(String.withCString("I"));
    }

    // A value's compile-time constant through the ZExt/SExt/Trunc the lowering
    // wraps a narrowed literal in, each conversion APPLIED at its result type
    // (#308): `(i32)(i8)300` is 44, where returning the Const's 300 made the
    // magic-number division divide by the wrong constant at -O0/-O1. `defOf`
    // maps a value to its defining instruction; the arm64 and x86-64 back ends
    // each pass their own.
    static bool constThrough(Map* defOf, IRValue* v, i64* out, u32 depth)
    {
        if (defOf == (Map*)0 || v == (IRValue*)0 || depth >= (u32)8) return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        if (d == (IRInsn*)0 || d.ops().count() < (u32)1 || d.res() == (IRValue*)0) return false;
        IROperand* a0 = (IROperand*)d.ops().get((u32)0);
        String* rt = d.res().ty();
        if (d.isOp(opConst)) {
            if (a0.kind() != (u8)OPK_IMMI) return false;
            *out = fitConst((i64)a0.imm(), rt, constSigned(rt));
            return true;
        }
        bool sx = d.isOp(opSExt);
        bool zx = d.isOp(opZExt);
        if (!(sx || zx || d.isOp(opTrunc)) || a0.kind() != OPK_USE) return false;
        i64 s = (i64)0;
        if (!constThrough(defOf, a0.val(), &s, depth + (u32)1)) return false;
        // An extension reads its source at the source's width: sign bits for
        // SExt, zero bits for ZExt, whatever the source's own signedness.
        if (sx || zx) s = fitConst(s, a0.val().ty(), sx);
        *out = fitConst(s, rt, constSigned(rt));
        return true;
    }

    static bool insnNames(IRInsn* n, String* want)
    {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_SYM) continue;
            if (o.name() != (String*)0 && o.name().equals(want)) return true;
        }
        return false;
    }

    static bool insnsName(Array* list, String* want)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if (insnNames((IRInsn*)list.get(i), want)) return true;
        return false;
    }

    // Does anything in this module call the runtime's thread-create primitive?
    // The INSTRUCTION stream is the question, not the symbol table: a symbol
    // survives dead-function elimination whether or not anything still names
    // it, and a program that imports a threading library it never spawns from
    // should keep the cheaper refcount.
    // Does the module call `name` anywhere? Same walk spawnsThreads does, and
    // for the same reason: a per-module fact the back end must decide for
    // itself rather than be told.
    static bool referencesSymbol(IRModule* m, String* want)
    {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (insnsName(bb.phis(), want)) return true;
                if (insnsName(bb.insns(), want)) return true;
                if (bb.term() != (IRInsn*)0 && insnNames(bb.term(), want)) return true;
            }
        }
        return false;
    }

    static bool spawnsThreads(IRModule* m)
    {
        return referencesSymbol(m, String.withCString("_xt_thread_create"));
    }

    // Whether ARC's count updates must be atomic (the security review of
    // 2026-10-21, #303): when the module spawns a thread, has no main (a
    // library or a plugin, whose caller may have threads of its own), or
    // loads a plugin (whose threads may share its objects). forced is the
    // target's own reason to say yes regardless (arm64 with LSE atomics).
    static bool arcAtomic(IRModule* m, bool forced)
    {
        if (forced) return true;
        if (spawnsThreads(m)) return true;
        bool hasMain = false;
        for (u32 f = (u32)0; f < m.funcs().count() && !hasMain; f = f + (u32)1)
            hasMain = ((IRFunc*)m.funcs().get(f)).name().equals(String.withCString("main"));
        if (!hasMain) return true;
        return referencesSymbol(m, String.withCString("Plugin$load"));
    }

    // Whether a symbol carries a C `byval` mark (the C/C++ reader's, for a
    // struct x86-64 System V passes on the stack by copy) on any of its
    // first n arguments: a back end without that convention refuses it.
    static bool anyByval(IRSymbol* s, u32 n)
        {
        if (s == (IRSymbol*)0)
            return false;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (s.attr(String.withFormat("byval_%u", i)) || s.attr(String.withFormat("byval16_%u", i)))
                return true;
        return false;
        }

    static bool isFloatTy(String* t)
    {
        return IRType.isFloat(t);
    }

    // `{{XTLOCAL:<vid>}}` becomes the local's sp-relative slot WITHOUT enclosing
    // brackets, so the user's `str w0, [result]` reads `str w0, [sp, #N]` —
    // the natural memory-operand syntax on this target.
    // An asm block's lines, each cut at a `;` outside a string literal: a `;`
    // ends the statement, as on the 6502, and the rest of the line is a
    // comment (bindAsmNames leaves it unbound). A line with no `;` stays as
    // it is.
    static Array* asmStatements(String* text)
    {
        Array* out = new Array();
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* l = (String*)lines.get(i);
            if (l.byteIndexOf(String.withCString(";")) == (u32)$FFFF_FFFF) { out.add((Object*)l); continue; }
            bool quoted = false;
            u32 k = (u32)0;
            while (k < l.byteLength() && (quoted || l.byteAt(k) != (u8)';')) {
                if (l.byteAt(k) == (u8)'"') quoted = !quoted;
                k = k + (u32)1;
            }
            String* part = l.substringBytes((u32)0, k).trimmed();
            if (part.byteLength() > (u32)0) out.add((Object*)part);
        }
        return out;
    }
    }
