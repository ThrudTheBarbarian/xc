// ElfMerge.xc — folding foreign ELF objects into the image being linked.
// =================================================================
//
// Stage 4 of private:docs/Design/foreign-object-linking.md. `ElfObject` says what an
// object CONTAINS; this says what happens when it joins the link: its blobs are
// concatenated onto the image, its symbols are rebased to where they landed,
// and its relocations become fixups the writer can resolve.
//
// The rules that are easy to state and easy to get subtly wrong:
//
//   * A LOCAL symbol's name is not unique across objects — two members both
//     have a static `buf` — so a local definition is tagged `name$o<tag>` and
//     every relocation against it is tagged the same way. An EXTERNAL symbol
//     keeps its name, because that is the whole point of it.
//   * A SECTION symbol has no name at all. A relocation against one means
//     "this section, plus the addend", which is how a compiler refers to its
//     own .rodata. It gets a synthetic name unique to (object, index) — tagging
//     the empty name instead yields `$o1967`, a symbol nothing defines.
//   * STRONG BEATS WEAK whatever the merge order. musl has NO strong `malloc`
//     anywhere in libc.a — lite_malloc's weak alias is the only definition — so
//     a weak definition must be registered, and then stand aside when a strong
//     one arrives later.
//   * A TLS symbol's value is an OFFSET in the thread block, not an address, so
//     it goes in its own table and never into the ordinary symbol map.
#import "Foundation.xc"
#import "X86Asm.xc"
#import "ElfObject.xc"

// A GC unit boundary: a text offset and the symbol that names it (bug 196).
class GcUnit
    {
    u32 _off;
    String* _name;
    void init(void)
        {
        }
    static GcUnit* make(u32 o, String* n)
        {
        GcUnit* u = new GcUnit();
        u._off = o;
        u._name = n;
        return u;
        }
    u32 off(void)
        {
        return _off;
        }
    String* name(void)
        {
        return _name;
        }
    }

    // Iterative (bottom-up) merge sort: stable, no recursion — the library's
    // quicksort recurses once per element on already-sorted input, and a link
    // sorts lists that arrive nearly sorted (fixups come in address order). The
    // source/destination roles alternate by pass PARITY rather than by swapping
    // two pointers: an assignment to an outer local through a loop-scoped temp is
    // lost at loop exit today (bug 199), and a sort that silently does nothing is
    // exactly the failure this must not have.
    void _gcMergeSort(Array* a, callback cmp i8(Object* x, Object* y))
    {
    u32 n = a.count();
    if (n < (u32)2)
        return;
    Array* tmp = Array.withCapacity(n);
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        tmp.add(a.get(i));
    u32 pass = (u32)0; // even: a -> tmp, odd: tmp -> a
    for (u32 w = (u32)1; w < n; w = w * (u32)2)
        {
        Array* src = (pass % (u32)2 == (u32)0) ? a : tmp;
        Array* dst = (pass % (u32)2 == (u32)0) ? tmp : a;
        for (u32 lo = (u32)0; lo < n; lo = lo + w * (u32)2)
            {
            u32 mid = lo + w;
            if (mid > n)
                mid = n;
            u32 hi = lo + w * (u32)2;
            if (hi > n)
                hi = n;
            u32 i = lo;
            u32 j = mid;
            u32 k = lo;
            while (i < mid && j < hi)
                {
                i8 c = (i8)0;
                if (cmp)
                    {
                    c = cmp(src.get(i), src.get(j));
                    }
                if (c <= (i8)0)
                    {
                    dst.set(k, src.get(i));
                    i = i + (u32)1;
                    }
                else
                    {
                    dst.set(k, src.get(j));
                    j = j + (u32)1;
                    }
                k = k + (u32)1;
                }
            while (i < mid)
                {
                dst.set(k, src.get(i));
                i = i + (u32)1;
                k = k + (u32)1;
                }
            while (j < hi)
                {
                dst.set(k, src.get(j));
                j = j + (u32)1;
                k = k + (u32)1;
                }
            }
        pass = pass + (u32)1;
        }
    if (pass % (u32)2 == (u32)1) // the result is in tmp
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            a.set(i, tmp.get(i));
    }

i8 _gcUnitByOffset(Object* a, Object* b)
    {
    u32 x = ((GcUnit*)a).off();
    u32 y = ((GcUnit*)b).off();
    if (x < y)
        return (i8)-1;
    if (x > y)
        return (i8)1;
    return (i8)0;
    }

i8 _gcNumberAsc(Object* a, Object* b)
    {
    u32 x = ((Number*)a).asU32();
    u32 y = ((Number*)b).asU32();
    if (x < y)
        return (i8)-1;
    if (x > y)
        return (i8)1;
    return (i8)0;
    }

class MergedImage
    {
    Data* _text;
    Data* _data;
    Data* _tls;
    Map* _syms;        // name -> Number(offset into text, or into data)
    Array* _dataSyms;  // String@ — names whose offset is a DATA offset
    Array* _globals;   // String@ — names this image exports
    Array* _fixups;    // X86Fixup@
    Array* _weakUndef; // String@ — weak references, may end up absolute 0
    Array* _weakDef;   // String@ — weak definitions, may be replaced
    Map* _tlsSyms;     // name -> Number(offset in the thread block)
    Data* _bss;        // zero-init (COMMON) storage — NOBITS, not file-stored
    Array* _bssSyms;   // String@ — names whose offset is a BSS offset
    u32 _bssAlign;
    Map* _funcSizes;      // name -> byte extent (st_size) of a TEXT function (bug 196 GC)
    Array* _objText;      // Number@ pairs: [start, end) of each merged object's text (bug 196 GC)
    Array* _objData;      // Number@ pairs: [start, end) of each merged object's data
    Array* _objDataAlign; // Number@ per object: its data alignment
    Array* _objLabel;     // String@ per object, parallel to the pairs
    Array* _tBounds;      // Number@ text unit boundaries (every text symbol, section, object start)
    Array* _dBounds;      // Number@ data unit boundaries (sized data symbols, sections, object starts)
    Array* _tlsAbs;       // TlsAbsReloc@ — R_X86_64_64 inside the TLS image
    String* _why;
    bool _failed;

    void init(void)
        {
        _text = new Data();
        _data = new Data();
        _tls = new Data();
        _syms = new Map();
        _dataSyms = new Array();
        _globals = new Array();
        _fixups = new Array();
        _weakUndef = new Array();
        _weakDef = new Array();
        _tlsSyms = new Map();
        _tlsAbs = new Array();
        _bss = new Data();
        _bssSyms = new Array();
        _bssAlign = (u32)1;
        _funcSizes = new Map();
        _objText = new Array();
        _objData = new Array();
        _objDataAlign = new Array();
        _objLabel = new Array();
        _tBounds = new Array();
        _dBounds = new Array();
        _why = new String();
        _failed = false;
        }

    Data* text(void)
        {
        return _text;
        }
    Data* data(void)
        {
        return _data;
        }
    Data* tls(void)
        {
        return _tls;
        }
    Map* syms(void)
        {
        return _syms;
        }
    Array* dataSyms(void)
        {
        return _dataSyms;
        }
    Array* globals(void)
        {
        return _globals;
        }
    Array* fixups(void)
        {
        return _fixups;
        }
    Array* weakUndef(void)
        {
        return _weakUndef;
        }
    Map* tlsSyms(void)
        {
        return _tlsSyms;
        }
    Array* tlsAbs(void)
        {
        return _tlsAbs;
        }
    Data* bss(void)
        {
        return _bss;
        }
    Array* bssSyms(void)
        {
        return _bssSyms;
        }
    u32 bssAlign(void)
        {
        return _bssAlign;
        }
    void setBssAlign(u32 a)
        {
        _bssAlign = a;
        }
    Map* funcSizes(void)
        {
        return _funcSizes;
        }

    Array* objText(void)
        {
        return _objText;
        }
    void noteObject(u32 ts, u32 te, u32 ds, u32 de, u32 dalign, String* label)
        {
        _objText.add((Object*)Number.withU32(ts));
        _objText.add((Object*)Number.withU32(te));
        _objData.add((Object*)Number.withU32(ds));
        _objData.add((Object*)Number.withU32(de));
        _objDataAlign.add((Object*)Number.withU32(dalign));
        _objLabel.add((Object*)label);
        }
    void noteTextBound(u32 off)
        {
        _tBounds.add((Object*)Number.withU32(off));
        }
    void noteDataBound(u32 off)
        {
        _dBounds.add((Object*)Number.withU32(off));
        }

    // ── link-time dead code AND data elimination (bug 196 Stages C + D) ─────
    //
    // The seed/runtime text [0, tPrefix) and data [0, dPrefix) are kept
    // wholesale. Every object and archive member past them is partitioned into
    // UNITS: text at every text symbol (any size — the CFG analysis below makes
    // that safe), text-section and object start; data at every SIZED data
    // symbol, data-section and object start (a size-0 data symbol cannot say
    // where it ends, so it stays inside the unit it falls in). Unreachable
    // units are dropped, the survivors compacted, and every symbol and fixup
    // offset remapped. A unit's EXTENT is [start, nextStart), so padding and
    // unnamed bytes stay with their unit. A DUPLICATE definition (weak, or a
    // second copy of an inline method) still gets its own unit, because the
    // boundaries come from every object's whole symbol table, not from the
    // winners — that is what lets a split build shed its copies.
    //
    // Vendor objects are NOT built with -ffunction-sections, and that costs
    // three things a section-granular linker never has to think about:
    //
    //   1. An intra-section reference to a local function — `lea thunk(%rip)`,
    //      `call static_fn`, `jmp .L` — is resolved by the assembler and carries
    //      NO relocation. Reachability through fixups alone cannot see it
    //      (OpenSSL's lh_*_comp_thunk was dropped that way), and once units
    //      move independently its displacement is wrong. So every text unit is
    //      DECODED (x86-64 length disassembler below); each rel32 / RIP-relative
    //      operand without a fixup at its position becomes an edge AND a
    //      synthetic PC32 fixup anchored to the target unit, which the writer
    //      re-resolves after compaction like any relocation.
    //   2. A rel8 branch cannot be re-resolved (one byte), and hand-asm falls
    //      through from one symbol into the next. Both are GLUE: the units stay
    //      adjacent, verbatim, and live together. `sym + addend` reaching past
    //      the symbol's own unit is glue too, for text and data alike.
    //   3. A unit the disassembler cannot decode with certainty (EVEX, an
    //      opcode we do not know) might hide references: its whole OBJECT is
    //      glued — exactly the section-atomic behaviour of a normal linker — so
    //      the fallback is never less safe than what ld does.
    //
    // Reachability is one fixpoint over both kinds of unit: a live text unit
    // keeps what its fixups and decoded references name (text or data), a live
    // data unit keeps what the fixups applied inside it name (a vtable's
    // methods, a jump table's cases, a string's bytes). Roots: the entry, every
    // fixup applied in the seed prefixes, and the TLS image's relocations.
    u32 _funcAt(Array* fStart, u32 nf, u32 addr)
        {
        // largest i with fStart[i] <= addr, or 0xFFFFFFFF if addr < fStart[0].
        if (nf == (u32)0 || addr < ((Number*)fStart.get((u32)0)).asU32())
            return (u32)$FFFF_FFFF;
        u32 lo = (u32)0;
        u32 hi = nf - (u32)1;
        while (lo < hi)
            {
            u32 mid = (lo + hi + (u32)1) / (u32)2;
            if (((Number*)fStart.get(mid)).asU32() <= addr)
                lo = mid;
            else
                hi = mid - (u32)1;
            }
        return lo;
        }

    static i32 _rd32s(Data* t, u32 p)
        {
        u32 v = (u32)t.byteAt(p) | ((u32)t.byteAt(p + (u32)1) << (u32)8) | ((u32)t.byteAt(p + (u32)2) << (u32)16) | ((u32)t.byteAt(p + (u32)3) << (u32)24);
        return (i32)v;
        }

    // ── x86-64 length disassembler ──────────────────────────────────────────
    // Returns the byte length of the instruction at `p`, or 0 if it cannot be
    // decoded with certainty (unknown opcode / truncated). Only NON-zero
    // lengths must be exactly right; 0 makes the caller glue the whole object.
    // Out-params (instance fields, valid after a non-zero return):
    //   _lastTerm    the opcode is an UNCONDITIONAL transfer (ret/jmp/hlt/ud2)
    //   _lastNop     padding (nop forms, int3, the merge's zero fill)
    //   _lastRelPos  offset of a rel8/rel32 branch displacement, or NONE
    //   _lastRelSize 1 or 4 (with _lastRelPos)
    //   _lastRipPos  offset of a RIP-relative disp32, or NONE
    //   _lastImmSize immediate bytes AFTER the displacement (for RIP targets)
    bool _lastTerm;
    bool _lastNop;
    u32 _lastRelPos;
    u32 _lastRelSize;
    u32 _lastRipPos;
    u32 _lastImmSize;
    u32 _insnLen(Data* t, u32 p, u32 end)
        {
        _lastTerm = false;
        _lastNop = false;
        _lastRelPos = (u32)$FFFF_FFFF;
        _lastRelSize = (u32)0;
        _lastRipPos = (u32)$FFFF_FFFF;
        _lastImmSize = (u32)0;
        u32 s = p;
        bool op66 = false;
        // legacy prefixes
        while (p < end)
            {
            u32 b = (u32)t.byteAt(p);
            if (b == (u32)$66)
                {
                op66 = true;
                p = p + (u32)1;
                continue;
                }
            if (b == (u32)$67)
                {
                p = p + (u32)1;
                continue;
                }
            if (b == (u32)$F0 || b == (u32)$F2 || b == (u32)$F3 || b == (u32)$2E || b == (u32)$36 || b == (u32)$3E || b == (u32)$26 || b == (u32)$64 || b == (u32)$65)
                {
                p = p + (u32)1;
                continue;
                }
            break;
            }
        bool rexW = false;
        if (p < end)
            {
            u32 b = (u32)t.byteAt(p);
            if (b >= (u32)$40 && b <= (u32)$4F)
                {
                if ((b & (u32)$08) != (u32)0)
                    rexW = true;
                p = p + (u32)1;
                }
            }
        if (p >= end)
            return (u32)0;
        u32 op = (u32)t.byteAt(p);
        p = p + (u32)1;
        u32 map = (u32)1;
        bool vex = false;
        // 2-byte VEX: map 0F
        if (op == (u32)$C5)
            {
            if (p + (u32)1 >= end)
                return (u32)0;
            p = p + (u32)1;
            vex = true;
            map = (u32)2;
            op = (u32)t.byteAt(p);
            p = p + (u32)1;
            }
        // 3-byte VEX: map from mmmmm
        else if (op == (u32)$C4)
            {
            if (p + (u32)2 >= end)
                return (u32)0;
            u32 mm = (u32)t.byteAt(p) & (u32)$1F;
            p = p + (u32)2;
            vex = true;
            if (mm == (u32)1)
                map = (u32)2;
            else if (mm == (u32)2)
                map = (u32)38;
            else if (mm == (u32)3)
                map = (u32)3;
            else
                return (u32)0;
            op = (u32)t.byteAt(p);
            p = p + (u32)1;
            }
        else if (op == (u32)$0F)
            {
            if (p >= end)
                return (u32)0;
            u32 op2 = (u32)t.byteAt(p);
            p = p + (u32)1;
            if (op2 == (u32)$38 || op2 == (u32)$3A)
                {
                if (p >= end)
                    return (u32)0;
                map = (op2 == (u32)$38) ? (u32)38 : (u32)3;
                op = (u32)t.byteAt(p);
                p = p + (u32)1;
                }
            else
                {
                map = (u32)2;
                op = op2;
                }
            }
        // decode (hasModRM, immType) per (map, op); immType: 0 none,1 i8,2 i16,4 i32,5 z(2/4),8 i64
        bool modrm = false;
        u32 imm = (u32)0;
        bool grp3 = false;
        u32 relSize = (u32)0;
        if (map == (u32)1)
            {
            u32 lo = op & (u32)7;
            u32 hi = op & (u32)$F8;
            if ((hi == (u32)$00 || hi == (u32)$08 || hi == (u32)$10 || hi == (u32)$18 || hi == (u32)$20 || hi == (u32)$28 || hi == (u32)$30 || hi == (u32)$38) && lo <= (u32)5)
                {
                if (lo <= (u32)3)
                    modrm = true;
                else if (lo == (u32)4)
                    imm = (u32)1;
                else
                    imm = (u32)5;
                }
            // push/pop reg
            else if (op >= (u32)$50 && op <= (u32)$5F)
                {
                }
            else if (op == (u32)$63)
                modrm = true; // movslq r64,r/m32
            else if (op == (u32)$68)
                imm = (u32)5; // push imm z
            else if (op == (u32)$6A)
                imm = (u32)1; // push imm8
            // imul imm z
            else if (op == (u32)$69)
                {
                modrm = true;
                imm = (u32)5;
                }
            // imul imm8
            else if (op == (u32)$6B)
                {
                modrm = true;
                imm = (u32)1;
                }
            // jcc rel8
            else if (op >= (u32)$70 && op <= (u32)$7F)
                {
                imm = (u32)1;
                relSize = (u32)1;
                }
            // grp1 i8
            else if (op == (u32)$80 || op == (u32)$83)
                {
                modrm = true;
                imm = (u32)1;
                }
            // grp1 z
            else if (op == (u32)$81)
                {
                modrm = true;
                imm = (u32)5;
                }
            else if (op >= (u32)$84 && op <= (u32)$8E)
                modrm = true; // test/xchg/mov/lea (0x8F pop r/m -> bail)
            // nop / pause / xchg ax,ax
            else if (op == (u32)$90)
                {
                _lastNop = true;
                }
            // xchg/cbw/cwd/fwait/pushf/popf/sahf/lahf
            else if (op >= (u32)$91 && op <= (u32)$9F)
                {
                }
            else if (op >= (u32)$A0 && op <= (u32)$A3)
                imm = (u32)8; // mov al/ax,moffs64
            else if (op == (u32)$A8)
                imm = (u32)1; // test al,i8
            else if (op == (u32)$A9)
                imm = (u32)5; // test eax,z
            // movs/cmps
            else if (op >= (u32)$A4 && op <= (u32)$A7)
                {
                }
            // stos/lods/scas
            else if (op >= (u32)$AA && op <= (u32)$AF)
                {
                }
            else if (op >= (u32)$B0 && op <= (u32)$B7)
                imm = (u32)1; // mov r8,i8
            else if (op >= (u32)$B8 && op <= (u32)$BF)
                imm = rexW ? (u32)8 : (op66 ? (u32)2 : (u32)4); // mov r,iv
            // shift i8
            else if (op == (u32)$C0 || op == (u32)$C1)
                {
                modrm = true;
                imm = (u32)1;
                }
            // mov r/m8,i8
            else if (op == (u32)$C6)
                {
                modrm = true;
                imm = (u32)1;
                }
            // mov r/m,z
            else if (op == (u32)$C7)
                {
                modrm = true;
                imm = (u32)5;
                }
            // ret imm16
            else if (op == (u32)$C2)
                {
                imm = (u32)2;
                _lastTerm = true;
                }
            // ret
            else if (op == (u32)$C3)
                {
                _lastTerm = true;
                }
            // enter i16,i8
            else if (op == (u32)$C8)
                {
                imm = (u32)3;
                }
            // leave
            else if (op == (u32)$C9)
                {
                }
            // retf
            else if (op == (u32)$CB)
                {
                _lastTerm = true;
                }
            // retf imm16
            else if (op == (u32)$CA)
                {
                imm = (u32)2;
                _lastTerm = true;
                }
            // int3 (padding)
            else if (op == (u32)$CC)
                {
                _lastNop = true;
                }
            else if (op == (u32)$CD)
                imm = (u32)1; // int i8
            // iret
            else if (op == (u32)$CF)
                {
                _lastTerm = true;
                }
            else if (op == (u32)$D0 || op == (u32)$D1 || op == (u32)$D2 || op == (u32)$D3)
                modrm = true; // shift 1/cl
            else if (op >= (u32)$D8 && op <= (u32)$DF)
                modrm = true; // x87
            // loop/jrcxz rel8
            else if (op >= (u32)$E0 && op <= (u32)$E3)
                {
                imm = (u32)1;
                relSize = (u32)1;
                }
            else if (op >= (u32)$E4 && op <= (u32)$E7)
                imm = (u32)1; // in/out imm8
            // call rel32
            else if (op == (u32)$E8)
                {
                imm = (u32)5;
                relSize = (u32)4;
                }
            // jmp rel32
            else if (op == (u32)$E9)
                {
                imm = (u32)5;
                relSize = (u32)4;
                _lastTerm = true;
                }
            // jmp rel8
            else if (op == (u32)$EB)
                {
                imm = (u32)1;
                relSize = (u32)1;
                _lastTerm = true;
                }
            // in/out dx
            else if (op >= (u32)$EC && op <= (u32)$EF)
                {
                }
            // int1/cmc/clc/stc/cli/sti/cld/std
            else if (op == (u32)$F1 || op == (u32)$F5 || (op >= (u32)$F8 && op <= (u32)$FD))
                {
                }
            // hlt
            else if (op == (u32)$F4)
                {
                _lastTerm = true;
                }
            // grp3 r/m8 (imm if reg 0/1)
            else if (op == (u32)$F6)
                {
                modrm = true;
                grp3 = true;
                }
            // grp3 r/m   (imm z if reg 0/1)
            else if (op == (u32)$F7)
                {
                modrm = true;
                grp3 = true;
                }
            else if (op == (u32)$FE)
                modrm = true; // inc/dec r/m8
            else if (op == (u32)$FF)
                modrm = true; // grp5 (jmp r/m handled below)
            else
                return (u32)0; // unknown -> bail (safe)
            if (relSize != (u32)0 && op66)
                return (u32)0; // 16-bit branch: never emitted
            }
        // 0F xx
        else if (map == (u32)2)
            {
            // ud2 (no modrm)
            if (op == (u32)$0B)
                {
                _lastTerm = true;
                return (u32)((p)-s);
                }
            else if (op == (u32)$05 || op == (u32)$06 || op == (u32)$07 || op == (u32)$08 || op == (u32)$09 || op == (u32)$A2 || (op >= (u32)$30 && op <= (u32)$37) || op == (u32)$77 || op == (u32)$A0 || op == (u32)$A1 || op == (u32)$A8 || op == (u32)$A9 || op == (u32)$AA)
                {
                }
            // syscall/clts/sysret/invd/wbinvd/cpuid/wrmsr..getsec/emms|vzeroupper/push-pop fs gs/rsm
            // jcc rel32
            else if (op >= (u32)$80 && op <= (u32)$8F)
                {
                if (vex || op66)
                    return (u32)0;
                imm = (u32)5;
                relSize = (u32)4;
                }
            // bswap
            else if (op >= (u32)$C8 && op <= (u32)$CF)
                {
                }
            // pshuf/psll/psrl/psra-imm/cmpps/pinsr/pextr/shuf imm8
            else if (op == (u32)$70 || op == (u32)$71 || op == (u32)$72 || op == (u32)$73 || op == (u32)$C2 || op == (u32)$C4 || op == (u32)$C5 || op == (u32)$C6)
                {
                modrm = true;
                imm = (u32)1;
                }
            // shld/shrd imm8 / grp8 bt i8
            else if (op == (u32)$A4 || op == (u32)$AC || op == (u32)$BA)
                {
                modrm = true;
                imm = (u32)1;
                }
            else if (op == (u32)$0F)
                return (u32)0; // 3DNow
            // multi-byte nop
            else if (op == (u32)$1F)
                {
                modrm = true;
                _lastNop = true;
                }
            // the vast majority of 0F opcodes are modrm, no imm (mov/cmov/setcc/movzx/arith SSE)
            else
                {
                modrm = true;
                }
            }
        // 0F38 / 0F3A (three-byte): all have modrm; 3A has imm8
        else
            {
            modrm = true;
            if (map == (u32)3)
                imm = (u32)1;
            }
        // ModRM + SIB + disp
        if (modrm)
            {
            if (p >= end)
                return (u32)0;
            u32 mrm = (u32)t.byteAt(p);
            p = p + (u32)1;
            u32 mod = mrm >> (u32)6;
            u32 rm = mrm & (u32)7;
            u32 reg = (mrm >> (u32)3) & (u32)7;
            if (op == (u32)$FF && map == (u32)1 && (reg == (u32)4 || reg == (u32)5))
                _lastTerm = true; // jmp r/m
            if (grp3 && (reg == (u32)0 || reg == (u32)1))
                imm = (op == (u32)$F6) ? (u32)1 : (u32)5; // grp3 test imm
            if (map == (u32)1 && op == (u32)$00 && mrm == (u32)$00)
                _lastNop = true; // 00 00: the merge's zero fill
            if (mod != (u32)3)
                {
                u32 base = rm;
                if (rm == (u32)4)
                    {
                    if (p >= end)
                        return (u32)0;
                    u32 sib = (u32)t.byteAt(p);
                    p = p + (u32)1;
                    base = sib & (u32)7;
                    }
                if (mod == (u32)0)
                    {
                    // RIP-rel disp32
                    if (rm == (u32)5)
                        {
                        _lastRipPos = p;
                        p = p + (u32)4;
                        }
                    else if (rm == (u32)4 && base == (u32)5)
                        p = p + (u32)4; // SIB no-base disp32
                    }
                else if (mod == (u32)1)
                    p = p + (u32)1;
                else
                    p = p + (u32)4;
                }
            }
        // immediate size resolution (z -> 2/4)
        u32 isz = imm;
        if (imm == (u32)5)
            isz = op66 ? (u32)2 : (u32)4;
        if (relSize != (u32)0)
            {
            _lastRelPos = p;
            _lastRelSize = relSize;
            }
        _lastImmSize = isz;
        p = p + isz;
        if (p > end)
            return (u32)0;
        return p - s;
        }

    // The TEXT offset a PC32-in-DATA fixup (a PIC jump-table entry,
    // `.long .Ltarget - .Ltable`) really means. Its addend is target + 4k for
    // entry k, so the target is recovered from the table base: the nearest
    // data offset at or below the entry that some `lea table(%rip)` names.
    // Without one (or if the answer leaves the entry's own object) the raw
    // S+A is used — an over-approximation that at worst anchors to a neighbour.
    u32 _pc32DataTarget(X86Fixup* f, u32 raw, Array* tblBase)
        {
        u32 n = tblBase.count();
        if (n == (u32)0)
            return raw;
        u32 pos = f.offset();
        u32 lo = (u32)0;
        u32 hi = n; // first index with base > pos
        while (lo < hi)
            {
            u32 mid = (lo + hi) / (u32)2;
            if (((Number*)tblBase.get(mid)).asU32() <= pos)
                lo = mid + (u32)1;
            else
                hi = mid;
            }
        if (lo == (u32)0)
            return raw;
        u32 tb = ((Number*)tblBase.get(lo - (u32)1)).asU32();
        u32 k = pos - tb;
        if (k > raw)
            return raw;
        u32 tgt = raw - k;
        // both must lie in one object's text
        for (u32 i = (u32)0; i + (u32)1 < _objText.count(); i = i + (u32)2)
            {
            u32 os = ((Number*)_objText.get(i)).asU32();
            u32 oe = ((Number*)_objText.get(i + (u32)1)).asU32();
            if (raw >= os && raw < oe)
                return (tgt >= os) ? tgt : raw;
            }
        return raw;
        }

    // The old-offset address a fixup's `sym + addend` really names, given the
    // symbol's value `base`: exact for an absolute slot, table-corrected for a
    // PC32-in-data entry into TEXT, and past the 4-byte field (plus any
    // immediate that follows a RIP-relative displacement) for a text kind.
    u32 _gcActual(X86Fixup* f, u32 base, bool toText, Map* ripImm, Array* tblBase)
        {
        u32 k = f.kind();
        u32 raw = base + (u32)f.addend();
        if (k == (u32)X86FIX_ABS64)
            return raw;
        if (k == (u32)X86FIX_PC32DATA)
            return toText ? _pc32DataTarget(f, raw, tblBase) : raw;
        u32 adj = (u32)4;
        Object* im = ripImm.get((Hashable*)Number.withU32(f.offset()));
        if (im != (Object*)0)
            adj = adj + ((Number*)im).asU32();
        return raw + adj;
        }

    // GC state shared by the helpers below (valid during gcDead only).
    Array* _tStart;
    Array* _tEnd;
    Array* _tName;
    u32 _ntu;
    Array* _dStart;
    Array* _dEnd;
    Array* _dName;
    u32 _ndu;
    Array* _tLive;
    Array* _dLive;
    Array* _tGlue;
    Array* _dGlue;
    Array* _tFall;
    Array* _tBucket;
    Array* _dBucket;
    Array* _work;
    Map* _dataSet;
    Map* _bssSet;
    Map* _ripImm;
    Array* _tblBase;
    u32 _markWhy;
    Array* _tWhy;
    Array* _dWhy;

    static u32 DATA_BIT(void)
        {
        return (u32)$8000_0000;
        }

    void _gcMarkId(u32 id)
        {
        if (id == (u32)$FFFF_FFFF)
            return;
        if ((id & MergedImage.DATA_BIT()) != (u32)0)
            {
            u32 j = id & ~MergedImage.DATA_BIT();
            if (((Number*)_dLive.get(j)).asU32() != (u32)0)
                return;
            _dLive.set(j, (Object*)Number.withU32((u32)1));
            _dWhy.set(j, (Object*)Number.withU32(_markWhy));
            }
        else
            {
            if (((Number*)_tLive.get(id)).asU32() != (u32)0)
                return;
            _tLive.set(id, (Object*)Number.withU32((u32)1));
            _tWhy.set(id, (Object*)Number.withU32(_markWhy));
            }
        _work.add((Object*)Number.withU32(id));
        }

    void _glueRange(Array* glue, u32 a, u32 b)
        {
        u32 lo = a < b ? a : b;
        u32 hi = a < b ? b : a;
        for (u32 j = lo; j < hi; j = j + (u32)1)
            glue.set(j, (Object*)Number.withU32((u32)1));
        }

    // The unit a fixup names, as an encoded id (text index, or DATA_BIT|data
    // index), or NONE (bss, TLS, undefined, or inside a seed prefix). A named
    // symbol's addend reaching another unit glues the two.
    u32 _gcTargetOf(X86Fixup* f)
        {
        String* sym = f.symbol();
        if (sym == (String*)0)
            return (u32)$FFFF_FFFF;
        Object* to = _syms.get((Hashable*)sym);
        if (to == (Object*)0)
            return (u32)$FFFF_FFFF;
        if (_bssSet.get((Hashable*)sym) != (Object*)0)
            return (u32)$FFFF_FFFF;
        u32 base = ((Number*)to).asU32();
        bool isSec = sym.hasPrefix(String.withCString(".Lsec"));
        if (_dataSet.get((Hashable*)sym) != (Object*)0)
            {
            u32 far = _gcActual(f, base, false, _ripImm, _tblBase);
            u32 ub = _funcAt(_dStart, _ndu, isSec ? far : base);
            if (ub == (u32)$FFFF_FFFF)
                return (u32)$FFFF_FFFF;
            if (!isSec)
                {
                u32 uf = _funcAt(_dStart, _ndu, far);
                if (uf != (u32)$FFFF_FFFF && uf != ub)
                    _glueRange(_dGlue, ub, uf);
                }
            return MergedImage.DATA_BIT() | ub;
            }
        u32 far = _gcActual(f, base, true, _ripImm, _tblBase);
        u32 ub = _funcAt(_tStart, _ntu, isSec ? far : base);
        if (ub == (u32)$FFFF_FFFF)
            return (u32)$FFFF_FFFF;
        if (!isSec)
            {
            u32 uf = _funcAt(_tStart, _ntu, far);
            if (uf != (u32)$FFFF_FFFF && uf != ub)
                _glueRange(_tGlue, ub, uf);
            }
        return ub;
        }

    // A resolved (relocation-less) intra-section reference from text unit `i`
    // to old offset `tgt`, its displacement at `pos`. Same unit: nothing to
    // do, the unit moves whole. Another unit of the same object: an edge, and
    // either a synthetic PC32 fixup (rel32 / RIP-relative: re-resolved by the
    // writer after compaction) or GLUE (rel8: one byte cannot be re-resolved,
    // so the two units — and everything between — stay adjacent and verbatim).
    void _gcRef(u32 i, u32 tgt, u32 pos, u32 immAfter, bool rel8, u32 os, u32 oe, Array* synth)
        {
        if (tgt < os || tgt >= oe)
            return; // not this object's text
        u32 tf = _funcAt(_tStart, _ntu, tgt);
        if (tf == (u32)$FFFF_FFFF || tf == i)
            return;
        ((Array*)_tBucket.get(i)).add((Object*)Number.withU32(tf));
        if (rel8)
            {
            _glueRange(_tGlue, i, tf);
            return;
            }
        i32 add = (i32)(tgt - ((Number*)_tStart.get(tf)).asU32()) - (i32)4 - (i32)immAfter;
        synth.add((Object*)X86Fixup.make(pos, (u32)X86FIX_PC32, (String*)_tName.get(tf), add));
        }

    // Units of one kind from recorded boundaries: sorted, distinct, each named
    // by a symbol already at that offset or by a synthetic `.Lgc` local.
    void _gcUnits(Array* bounds, u32 prefixEnd, Map* nameAt, bool isData, Array* outStart, Array* outName)
        {
        Array* units = new Array();
        Map* seen = new Map();
        for (u32 i = (u32)0; i < bounds.count(); i = i + (u32)1)
            {
            u32 off = ((Number*)bounds.get(i)).asU32();
            if (off < prefixEnd)
                continue;
            Number* key = Number.withU32(off);
            if (seen.get((Hashable*)key) != (Object*)0)
                continue;
            seen.set((Hashable*)key, (Object*)Number.withU32((u32)1));
            Object* nm = nameAt.get((Hashable*)key);
            String* name;
            if (nm != (Object*)0)
                name = (String*)nm;
            else
                {
                name = String.withCString(isData ? ".Lgcd$" : ".Lgct$");
                name.appendFormat("%lu", off);
                _syms.set((Hashable*)name, (Object*)Number.withU32(off));
                if (isData)
                    {
                    _dataSyms.add((Object*)name);
                    _dataSet.set((Hashable*)name, (Object*)Number.withU32((u32)1));
                    }
                }
            units.add((Object*)GcUnit.make(off, name));
            }
        _gcMergeSort(units, &_gcUnitByOffset);
        for (u32 i = (u32)0; i < units.count(); i = i + (u32)1)
            {
            GcUnit* u = (GcUnit*)units.get(i);
            outStart.add((Object*)Number.withU32(u.off()));
            outName.add((Object*)u.name());
            }
        }

    // Data GC units are whole-OBJECT data regions (bug 200 safety): one unit
    // per merged object that has data, starting at the object's data base.
    // Each start is named by a data symbol already at that offset, or a
    // synthetic `.Lgcd$` local, so a section-relative fixup can be re-anchored.
    void _gcDataObjectUnits(u32 seedDataEnd, Map* nameAt, Array* outStart, Array* outName)
        {
        u32 nobj = _objData.count() / (u32)2;
        Array* units = new Array();
        Map* seen = new Map();
        for (u32 o = (u32)0; o < nobj; o = o + (u32)1)
            {
            u32 ds = ((Number*)_objData.get(o * (u32)2)).asU32();
            u32 de = ((Number*)_objData.get(o * (u32)2 + (u32)1)).asU32();
            if (de <= ds || ds < seedDataEnd)
                continue; // no data, or part of the seed
            Number* key = Number.withU32(ds);
            if (seen.get((Hashable*)key) != (Object*)0)
                continue; // two objects share a base (empty between)
            seen.set((Hashable*)key, (Object*)Number.withU32((u32)1));
            Object* nm = nameAt.get((Hashable*)key);
            String* name;
            if (nm != (Object*)0)
                name = (String*)nm;
            else
                {
                name = String.withCString(".Lgcd$");
                name.appendFormat("%lu", ds);
                _syms.set((Hashable*)name, (Object*)Number.withU32(ds));
                _dataSyms.add((Object*)name);
                _dataSet.set((Hashable*)name, (Object*)Number.withU32((u32)1));
                }
            units.add((Object*)GcUnit.make(ds, name));
            }
        _gcMergeSort(units, &_gcUnitByOffset);
        for (u32 i = (u32)0; i < units.count(); i = i + (u32)1)
            {
            GcUnit* u = (GcUnit*)units.get(i);
            outStart.add((Object*)Number.withU32(u.off()));
            outName.add((Object*)u.name());
            }
        }

    static Array* _gcEnds(Array* starts, u32 end)
        {
        Array* out = new Array();
        u32 n = starts.count();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            out.add((Object*)Number.withU32(i + (u32)1 < n ? ((Number*)starts.get(i + (u32)1)).asU32() : end));
        return out;
        }

    // objIdx per unit: which merged object (index into the parallel _obj*
    // arrays) holds it. Objects were appended in order, so both ascend.
    static Array* _gcObjIdx(Array* starts, Array* objRanges)
        {
        Array* out = new Array();
        u32 oi = (u32)0;
        u32 nobj = objRanges.count() / (u32)2;
        for (u32 i = (u32)0; i < starts.count(); i = i + (u32)1)
            {
            u32 st = ((Number*)starts.get(i)).asU32();
            while (oi + (u32)1 < nobj && ((Number*)objRanges.get((oi + (u32)1) * (u32)2)).asU32() <= st)
                oi = oi + (u32)1;
            out.add((Object*)Number.withU32(oi));
            }
        return out;
        }

    static Array* _gcZeros(u32 n)
        {
        Array* a = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            a.add((Object*)Number.withU32((u32)0));
        return a;
        }

    void gcDead(u32 seedTextEnd, u32 seedDataEnd, String* entry)
        {
        u32 NONE = (u32)$FFFF_FFFF;
        _dataSet = new Map();
        _bssSet = new Map();
        for (u32 i = (u32)0; i < _dataSyms.count(); i = i + (u32)1)
            _dataSet.set((Hashable*)(String*)_dataSyms.get(i), (Object*)Number.withU32((u32)1));
        for (u32 i = (u32)0; i < _bssSyms.count(); i = i + (u32)1)
            _bssSet.set((Hashable*)(String*)_bssSyms.get(i), (Object*)Number.withU32((u32)1));

        // 1. Units. A symbol at a boundary names it; a boundary with none (a
        //    section start, a dropped duplicate) gets a synthetic local.
        Map* tNameAt = new Map();
        Map* dNameAt = new Map();
        Array* keys = _syms.allKeys();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            String* nm = (String*)keys.get(i);
            u32 off = ((Number*)_syms.get((Hashable*)nm)).asU32();
            if (_bssSet.get((Hashable*)nm) != (Object*)0)
                continue;
            bool isData = _dataSet.get((Hashable*)nm) != (Object*)0;
            if (isData ? (off < seedDataEnd) : (off < seedTextEnd))
                continue;
            Map* nameAt = isData ? dNameAt : tNameAt;
            Number* key = Number.withU32(off);
            // The SMALLEST name at an offset names the unit — deterministic, so
            // both compilers anchor a rewritten fixup to the same symbol.
            Object* prev = nameAt.get((Hashable*)key);
            if (prev == (Object*)0 || nm.compare((String*)prev) < (i8)0)
                nameAt.set((Hashable*)key, (Object*)nm);
            }
        _tStart = new Array();
        _tName = new Array();
        _gcUnits(_tBounds, seedTextEnd, tNameAt, false, _tStart, _tName);
        _ntu = _tStart.count();
        if (_ntu == (u32)0)
            return;
        u32 textEnd = _text.length();
        u32 tPrefix = ((Number*)_tStart.get((u32)0)).asU32();
        _tEnd = MergedImage._gcEnds(_tStart, textEnd);
        Array* tObj = MergedImage._gcObjIdx(_tStart, _objText);

        // Dead-DATA elimination (Stage D) is OBJECT-granular, NOT per-symbol.
        // This ABI dispatches methods as `vtable + <global-selector-offset>`
        // with NO relocation, so a data object (a vtable and its method table)
        // is indexed by computed runtime offsets that cross symbol boundaries
        // but NEVER cross an OBJECT boundary (a class's vtable and methods are
        // emitted into one object). So the GC unit for data is the whole
        // object's data region: a region is kept byte-exact (only its base
        // moves, a uniform delta — every runtime offset inside it stays valid)
        // or dropped entirely. That reclaims the duplicate copies a split build
        // carries (the same library compiled into every object; only the
        // first-def-wins copy is referenced, the rest are dead whole regions)
        // without ever shifting a live slot out from under an index (bug 200).
        _dStart = new Array();
        _dName = new Array();
        _gcDataObjectUnits(seedDataEnd, dNameAt, _dStart, _dName);
        _ndu = _dStart.count();
        u32 dataEnd = _data.length();
        u32 dPrefix = _ndu > (u32)0 ? ((Number*)_dStart.get((u32)0)).asU32() : dataEnd;
        _dEnd = MergedImage._gcEnds(_dStart, dataEnd);
        Array* dObj = MergedImage._gcObjIdx(_dStart, _objData);

        _tLive = MergedImage._gcZeros(_ntu);
        _tGlue = MergedImage._gcZeros(_ntu);
        _tFall = MergedImage._gcZeros(_ntu);
        _tWhy = MergedImage._gcZeros(_ntu);
        _dLive = MergedImage._gcZeros(_ndu);
        _dGlue = MergedImage._gcZeros(_ndu);
        _dWhy = MergedImage._gcZeros(_ndu);
        _tBucket = new Array();
        _dBucket = new Array();
        for (u32 i = (u32)0; i < _ntu; i = i + (u32)1)
            {
            _tBucket.add((Object*)new Array());
            _tFall.set(i, (Object*)Number.withU32((u32)1));
            }
        for (u32 i = (u32)0; i < _ndu; i = i + (u32)1)
            _dBucket.add((Object*)new Array());
        u32 nobj = _objText.count() / (u32)2;
        Array* objBad = MergedImage._gcZeros(nobj);

        // Text-applied fixups by application offset: a decoded displacement
        // that has one is a relocation placeholder, not a resolved reference.
        Map* fixAt = new Map();
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            u32 k = f.kind();
            if (k == (u32)X86FIX_ABS64 || k == (u32)X86FIX_PC32DATA)
                continue;
            fixAt.set((Hashable*)Number.withU32(f.offset()), (Object*)Number.withU32(i + (u32)1));
            }

        // 2. Decode every text unit: fall-through, intra-section references
        //    (edges + synthetic fixups), rel8 glue, per-object decode failure.
        _ripImm = new Map();        // fixup app-offset -> imm bytes after a RIP disp32
        Array* synth = new Array(); // synthetic PC32 fixups for resolved references
        for (u32 i = (u32)0; i < _ntu; i = i + (u32)1)
            {
            u32 st = ((Number*)_tStart.get(i)).asU32();
            u32 en = ((Number*)_tEnd.get(i)).asU32();
            u32 o = ((Number*)tObj.get(i)).asU32();
            u32 os = ((Number*)_objText.get(o * (u32)2)).asU32();
            u32 oe = ((Number*)_objText.get(o * (u32)2 + (u32)1)).asU32();
            u32 p = st;
            bool ok = true;
            bool lastRealTerm = false;
            while (p < en)
                {
                // an all-zero tail is the merge's fill
                if ((u32)_text.byteAt(p) == (u32)0)
                    {
                    u32 q = p;
                    while (q < en && (u32)_text.byteAt(q) == (u32)0)
                        q = q + (u32)1;
                    if (q == en)
                        break;
                    }
                u32 len = _insnLen(_text, p, en);
                if (len == (u32)0)
                    {
                    ok = false;
                    break;
                    }
                if (!_lastNop)
                    lastRealTerm = _lastTerm;
                u32 insnEnd = p + len;
                if (_lastRelPos != NONE)
                    {
                    if (_lastRelSize == (u32)4)
                        {
                        if (fixAt.get((Hashable*)Number.withU32(_lastRelPos)) == (Object*)0)
                            {
                            u32 tgt = insnEnd + (u32)MergedImage._rd32s(_text, _lastRelPos);
                            _gcRef(i, tgt, _lastRelPos, (u32)0, false, os, oe, synth);
                            }
                        }
                    else
                        {
                        u32 d8 = (u32)_text.byteAt(_lastRelPos);
                        u32 tgt = insnEnd + (d8 >= (u32)$80 ? d8 - (u32)$100 : d8);
                        _gcRef(i, tgt, _lastRelPos, (u32)0, true, os, oe, synth);
                        }
                    }
                if (_lastRipPos != NONE)
                    {
                    if (fixAt.get((Hashable*)Number.withU32(_lastRipPos)) != (Object*)0)
                        {
                        if (_lastImmSize != (u32)0)
                            _ripImm.set((Hashable*)Number.withU32(_lastRipPos), (Object*)Number.withU32(_lastImmSize));
                        }
                    else
                        {
                        u32 tgt = insnEnd + (u32)MergedImage._rd32s(_text, _lastRipPos);
                        _gcRef(i, tgt, _lastRipPos, _lastImmSize, false, os, oe, synth);
                        }
                    }
                p = insnEnd;
                }
            if (ok)
                _tFall.set(i, (Object*)Number.withU32(lastRealTerm ? (u32)0 : (u32)1));
            else
                objBad.set(o, (Object*)Number.withU32((u32)1));
            }
        // An undecodable object is one unit: glue everything in it.
        for (u32 i = (u32)0; i + (u32)1 < _ntu; i = i + (u32)1)
            {
            u32 o = ((Number*)tObj.get(i)).asU32();
            if (((Number*)objBad.get(o)).asU32() != (u32)0 && ((Number*)tObj.get(i + (u32)1)).asU32() == o)
                _tGlue.set(i, (Object*)Number.withU32((u32)1));
            }
        for (u32 i = (u32)0; i < synth.count(); i = i + (u32)1)
            _fixups.add(synth.get(i));

        // Jump-table bases: data offsets named by text fixups (`lea table(%rip)`).
        _tblBase = new Array();
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            u32 k = f.kind();
            if (k != (u32)X86FIX_PC32 && k != (u32)X86FIX_REL32)
                continue;
            String* sym = f.symbol();
            if (sym == (String*)0 || _dataSet.get((Hashable*)sym) == (Object*)0)
                continue;
            Object* to = _syms.get((Hashable*)sym);
            if (to == (Object*)0)
                continue;
            _tblBase.add((Object*)Number.withU32(((Number*)to).asU32() + (u32)f.addend() + (u32)4));
            }
        _gcMergeSort(_tblBase, &_gcNumberAsc);

        // 3. Edges and roots, then the fixpoint.
        _work = new Array();
        _markWhy = (u32)1;
        Object* eo = _syms.get((Hashable*)entry);
        if (eo != (Object*)0)
            _gcMarkId(_funcAt(_tStart, _ntu, ((Number*)eo).asU32()));
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            u32 tgt = _gcTargetOf(f);
            if (tgt == NONE)
                continue;
            u32 k = f.kind();
            bool isDataFix = (k == (u32)X86FIX_ABS64 || k == (u32)X86FIX_PC32DATA);
            if (isDataFix)
                {
                if (f.offset() < dPrefix)
                    {
                    _markWhy = (u32)2;
                    _gcMarkId(tgt);
                    continue;
                    }
                u32 src = _funcAt(_dStart, _ndu, f.offset());
                if (src != NONE)
                    ((Array*)_dBucket.get(src)).add((Object*)Number.withU32(tgt));
                }
            else
                {
                if (f.offset() < tPrefix)
                    {
                    _markWhy = (u32)3;
                    _gcMarkId(tgt);
                    continue;
                    }
                u32 src = _funcAt(_tStart, _ntu, f.offset());
                if (src != NONE)
                    ((Array*)_tBucket.get(src)).add((Object*)Number.withU32(tgt));
                }
            }
        _markWhy = (u32)2;
        // the TLS image's slots
        for (u32 i = (u32)0; i < _tlsAbs.count(); i = i + (u32)1)
            {
            TlsAbsReloc* t = (TlsAbsReloc*)_tlsAbs.get(i);
            _gcMarkId(_gcTargetOf(X86Fixup.make((u32)0, (u32)X86FIX_ABS64, t.sym(), (i32)t.addend())));
            }
        u32 head = (u32)0;
        while (head < _work.count())
            {
            u32 id = ((Number*)_work.get(head)).asU32();
            head = head + (u32)1;
            if ((id & MergedImage.DATA_BIT()) != (u32)0)
                {
                u32 j = id & ~MergedImage.DATA_BIT();
                Array* b = (Array*)_dBucket.get(j);
                _markWhy = (u32)4;
                for (u32 i = (u32)0; i < b.count(); i = i + (u32)1)
                    _gcMarkId(((Number*)b.get(i)).asU32());
                _markWhy = (u32)7;
                if (j + (u32)1 < _ndu && ((Number*)_dGlue.get(j)).asU32() != (u32)0)
                    _gcMarkId(MergedImage.DATA_BIT() | (j + (u32)1));
                if (j > (u32)0 && ((Number*)_dGlue.get(j - (u32)1)).asU32() != (u32)0)
                    _gcMarkId(MergedImage.DATA_BIT() | (j - (u32)1));
                continue;
                }
            u32 fi = id;
            Array* b = (Array*)_tBucket.get(fi);
            _markWhy = (u32)4;
            for (u32 i = (u32)0; i < b.count(); i = i + (u32)1)
                _gcMarkId(((Number*)b.get(i)).asU32());
            // fall-through / glue: a live unit that runs off its end (or is
            // glued to its neighbour) keeps the neighbour live and adjacent.
            _markWhy = (u32)7;
            if (fi + (u32)1 < _ntu && ((Number*)_tGlue.get(fi)).asU32() != (u32)0)
                _gcMarkId(fi + (u32)1);
            if (fi > (u32)0 && ((Number*)_tGlue.get(fi - (u32)1)).asU32() != (u32)0)
                _gcMarkId(fi - (u32)1);
            _markWhy = (u32)6;
            if (fi + (u32)1 < _ntu && ((Number*)_tFall.get(fi)).asU32() != (u32)0)
                _gcMarkId(fi + (u32)1);
            }

        // 4. Rewrite section-relative fixups (.Lsec + addend) to UNIT-relative
        //    using OLD offsets, BEFORE the symbol remap. A section is fragmented
        //    by compaction, so `.Lsec+addend` would break; `unitName + (raw -
        //    unitStart)` preserves the value AND survives (the unit moves whole).
        String* lsec = String.withCString(".Lsec");
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            String* sym = f.symbol();
            if (sym == (String*)0 || !sym.hasPrefix(lsec))
                continue;
            if (_bssSet.get((Hashable*)sym) != (Object*)0)
                continue;
            Object* to = _syms.get((Hashable*)sym);
            if (to == (Object*)0)
                continue;
            u32 base = ((Number*)to).asU32();
            bool toData = _dataSet.get((Hashable*)sym) != (Object*)0;
            u32 raw = base + (u32)f.addend();
            u32 actual = _gcActual(f, base, !toData, _ripImm, _tblBase);
            u32 tf = toData ? _funcAt(_dStart, _ndu, actual) : _funcAt(_tStart, _ntu, actual);
            if (tf == NONE)
                continue; // section in a seed prefix
            Array* starts = toData ? _dStart : _tStart;
            Array* names = toData ? _dName : _tName;
            i32 newAdd = (i32)(raw - ((Number*)starts.get(tf)).asU32());
            _fixups.set(i, (Object*)X86Fixup.make(f.offset(), f.kind(), (String*)names.get(tf), newAdd));
            }

        if (Platform.env(String.withCString("XCC_GC_STATS")).byteLength() != (u32)0)
            _gcStats(tObj, dObj, objBad, synth.count(), textEnd, tPrefix, dataEnd, dPrefix);

        // 5. Compaction. Copy each prefix, then the live units. A text unit
        //    whose predecessor is live and falls through / is glued to it stays
        //    contiguous, verbatim — no re-alignment between them. Only a BLOCK
        //    START is re-aligned, and to its ORIGINAL alignment (mod 64 — 16-
        //    aligning demoted a 32/64-aligned AVX function and it faulted; data
        //    takes the object's own section alignment when that is larger).
        Data* nt = Data.withCapacity(textEnd);
        nt.append(_text.subdata((u32)0, tPrefix));
        Map* tBase = new Map();
        for (u32 i = (u32)0; i < _ntu; i = i + (u32)1)
            {
            if (((Number*)_tLive.get(i)).asU32() == (u32)0)
                continue;
            bool cont = (i > (u32)0) && ((Number*)_tLive.get(i - (u32)1)).asU32() != (u32)0 && (((Number*)_tFall.get(i - (u32)1)).asU32() != (u32)0 || ((Number*)_tGlue.get(i - (u32)1)).asU32() != (u32)0);
            u32 st = ((Number*)_tStart.get(i)).asU32();
            u32 en = ((Number*)_tEnd.get(i)).asU32();
            if (!cont)
                {
                while (nt.length() % (u32)64 != st % (u32)64)
                    nt.appendByte((u8)0);
                }
            tBase.set((Hashable*)Number.withU32(st), (Object*)Number.withU32(nt.length()));
            nt.append(_text.subdata(st, en - st));
            }
        Data* nd = Data.withCapacity(dataEnd);
        nd.append(_data.subdata((u32)0, dPrefix));
        Map* dBase = new Map();
        for (u32 j = (u32)0; j < _ndu; j = j + (u32)1)
            {
            if (((Number*)_dLive.get(j)).asU32() == (u32)0)
                continue;
            bool cont = (j > (u32)0) && ((Number*)_dLive.get(j - (u32)1)).asU32() != (u32)0 && ((Number*)_dGlue.get(j - (u32)1)).asU32() != (u32)0;
            u32 st = ((Number*)_dStart.get(j)).asU32();
            u32 en = ((Number*)_dEnd.get(j)).asU32();
            if (!cont)
                {
                u32 al = ((Number*)_objDataAlign.get(((Number*)dObj.get(j)).asU32())).asU32();
                if (al < (u32)64)
                    al = (u32)64;
                while (nd.length() % al != st % al)
                    nd.appendByte((u8)0);
                }
            dBase.set((Hashable*)Number.withU32(st), (Object*)Number.withU32(nd.length()));
            nd.append(_data.subdata(st, en - st));
            }

        // 6. Remap symbols (drop the dead); bss/TLS/seed symbols unchanged.
        Array* snames = _syms.allKeys();
        for (u32 i = (u32)0; i < snames.count(); i = i + (u32)1)
            {
            String* nm = (String*)snames.get(i);
            if (_bssSet.get((Hashable*)nm) != (Object*)0)
                continue;
            u32 off = ((Number*)_syms.get((Hashable*)nm)).asU32();
            bool isData = _dataSet.get((Hashable*)nm) != (Object*)0;
            if (isData ? (off < dPrefix) : (off < tPrefix))
                continue;
            u32 fi = isData ? _funcAt(_dStart, _ndu, off) : _funcAt(_tStart, _ntu, off);
            if (fi == NONE)
                continue;
            Array* liveA = isData ? _dLive : _tLive;
            Array* starts = isData ? _dStart : _tStart;
            Map* bases = isData ? dBase : tBase;
            if (((Number*)liveA.get(fi)).asU32() == (u32)0)
                {
                _syms.remove((Hashable*)nm);
                continue;
                }
            u32 ust = ((Number*)starts.get(fi)).asU32();
            u32 nb = ((Number*)bases.get((Hashable*)Number.withU32(ust))).asU32();
            _syms.set((Hashable*)nm, (Object*)Number.withU32(nb + (off - ust)));
            }

        // 7. Remap fixup application offsets (drop the dead units'); seed ones unchanged.
        Array* nf2 = new Array();
        for (u32 i = (u32)0; i < _fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_fixups.get(i);
            u32 k = f.kind();
            bool isDataFix = (k == (u32)X86FIX_ABS64 || k == (u32)X86FIX_PC32DATA);
            u32 app = f.offset();
            if (isDataFix ? (app < dPrefix) : (app < tPrefix))
                {
                nf2.add((Object*)f);
                continue;
                }
            u32 fi = isDataFix ? _funcAt(_dStart, _ndu, app) : _funcAt(_tStart, _ntu, app);
            if (fi == NONE)
                {
                nf2.add((Object*)f);
                continue;
                }
            Array* liveA = isDataFix ? _dLive : _tLive;
            Array* starts = isDataFix ? _dStart : _tStart;
            Map* bases = isDataFix ? dBase : tBase;
            if (((Number*)liveA.get(fi)).asU32() == (u32)0)
                continue;
            u32 ust = ((Number*)starts.get(fi)).asU32();
            u32 nb = ((Number*)bases.get((Hashable*)Number.withU32(ust))).asU32();
            f.setOffset(nb + (app - ust));
            nf2.add((Object*)f);
            }
        _fixups = nf2;
        _text = nt;
        _data = nd;
        }

    void _gcStats(Array* tObj, Array* dObj, Array* objBad, u32 nsynth, u32 textEnd, u32 tPrefix, u32 dataEnd, u32 dPrefix)
        {
        u32 nobj = _objText.count() / (u32)2;
        u32 tl = (u32)0;
        u32 tk = (u32)0;
        u32 ng = (u32)0;
        u32 nfl = (u32)0;
        u32 bad = (u32)0;
        Array* tw = MergedImage._gcZeros((u32)8);
        Array* dw = MergedImage._gcZeros((u32)8);
        Array* objT = MergedImage._gcZeros(nobj);
        Array* objD = MergedImage._gcZeros(nobj);
        for (u32 i = (u32)0; i < _ntu; i = i + (u32)1)
            {
            u32 sz = ((Number*)_tEnd.get(i)).asU32() - ((Number*)_tStart.get(i)).asU32();
            if (((Number*)_tGlue.get(i)).asU32() != (u32)0)
                ng = ng + (u32)1;
            if (((Number*)_tFall.get(i)).asU32() != (u32)0)
                nfl = nfl + (u32)1;
            if (((Number*)_tLive.get(i)).asU32() == (u32)0)
                continue;
            tl = tl + (u32)1;
            tk = tk + sz;
            u32 w = ((Number*)_tWhy.get(i)).asU32();
            tw.set(w, (Object*)Number.withU32(((Number*)tw.get(w)).asU32() + sz));
            u32 o = ((Number*)tObj.get(i)).asU32();
            objT.set(o, (Object*)Number.withU32(((Number*)objT.get(o)).asU32() + sz));
            if (((Number*)objBad.get(o)).asU32() != (u32)0)
                bad = bad + sz;
            }
        u32 dl = (u32)0;
        u32 dk = (u32)0;
        for (u32 j = (u32)0; j < _ndu; j = j + (u32)1)
            {
            u32 sz = ((Number*)_dEnd.get(j)).asU32() - ((Number*)_dStart.get(j)).asU32();
            if (((Number*)_dLive.get(j)).asU32() == (u32)0)
                continue;
            dl = dl + (u32)1;
            dk = dk + sz;
            u32 w = ((Number*)_dWhy.get(j)).asU32();
            dw.set(w, (Object*)Number.withU32(((Number*)dw.get(w)).asU32() + sz));
            u32 o = ((Number*)dObj.get(j)).asU32();
            objD.set(o, (Object*)Number.withU32(((Number*)objD.get(o)).asU32() + sz));
            }
        u32 nbad = (u32)0;
        for (u32 i = (u32)0; i < nobj; i = i + (u32)1)
            if (((Number*)objBad.get(i)).asU32() != (u32)0)
                nbad = nbad + (u32)1;
        Stdio.printf("gc: text=%lu prefix=%lu units=%lu live=%lu kept=%lu dropped=%lu synth=%lu glue=%lu fall=%lu badobjs=%lu/%lu badbytes=%lu\n",
                     textEnd, tPrefix, _ntu, tl, tk, textEnd - tPrefix - tk, nsynth, ng, nfl, nbad, nobj, bad);
        Stdio.printf("gc: text kept by reason: entry=%lu dataroot=%lu seedroot=%lu edge=%lu fall=%lu glue=%lu\n",
                     ((Number*)tw.get((u32)1)).asU32(), ((Number*)tw.get((u32)2)).asU32(), ((Number*)tw.get((u32)3)).asU32(),
                     ((Number*)tw.get((u32)4)).asU32(), ((Number*)tw.get((u32)6)).asU32(), ((Number*)tw.get((u32)7)).asU32());
        Stdio.printf("gc: data=%lu prefix=%lu units=%lu live=%lu kept=%lu dropped=%lu\n",
                     dataEnd, dPrefix, _ndu, dl, dk, dataEnd - dPrefix - dk);
        Stdio.printf("gc: data kept by reason: dataroot=%lu seedroot=%lu edge=%lu glue=%lu\n",
                     ((Number*)dw.get((u32)2)).asU32(), ((Number*)dw.get((u32)3)).asU32(),
                     ((Number*)dw.get((u32)4)).asU32(), ((Number*)dw.get((u32)7)).asU32());
        String* mode = Platform.env(String.withCString("XCC_GC_STATS"));
        if (mode.equals(String.withCString("objs")))
            {
            for (u32 i = (u32)0; i < nobj; i = i + (u32)1)
                {
                u32 tt = ((Number*)_objText.get(i * (u32)2 + (u32)1)).asU32() - ((Number*)_objText.get(i * (u32)2)).asU32();
                u32 dt = ((Number*)_objData.get(i * (u32)2 + (u32)1)).asU32() - ((Number*)_objData.get(i * (u32)2)).asU32();
                if (((Number*)objT.get(i)).asU32() == (u32)0 && ((Number*)objD.get(i)).asU32() == (u32)0)
                    continue;
                Stdio.printf("gc-obj: text=%lu/%lu data=%lu/%lu bad=%lu %s\n", ((Number*)objT.get(i)).asU32(), tt,
                             ((Number*)objD.get(i)).asU32(), dt, ((Number*)objBad.get(i)).asU32(), ((String*)_objLabel.get(i)).cString());
                }
            }
        if (mode.equals(String.withCString("units")))
            {
            for (u32 i = (u32)0; i < _ntu; i = i + (u32)1)
                {
                if (((Number*)_tLive.get(i)).asU32() == (u32)0)
                    continue;
                Stdio.printf("gc-text: why=%lu size=%lu fall=%lu glue=%lu %s\n", ((Number*)_tWhy.get(i)).asU32(),
                             ((Number*)_tEnd.get(i)).asU32() - ((Number*)_tStart.get(i)).asU32(),
                             ((Number*)_tFall.get(i)).asU32(), ((Number*)_tGlue.get(i)).asU32(), ((String*)_tName.get(i)).cString());
                }
            for (u32 j = (u32)0; j < _ndu; j = j + (u32)1)
                {
                if (((Number*)_dLive.get(j)).asU32() == (u32)0)
                    continue;
                Stdio.printf("gc-data: why=%lu size=%lu glue=%lu %s\n", ((Number*)_dWhy.get(j)).asU32(),
                             ((Number*)_dEnd.get(j)).asU32() - ((Number*)_dStart.get(j)).asU32(),
                             ((Number*)_dGlue.get(j)).asU32(), ((String*)_dName.get(j)).cString());
                }
            }
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void fail(String* w)
        {
        if (!_failed)
            {
            _failed = true;
            _why = w;
            }
        }

    bool defines(String* n)
        {
        return _syms.get((Hashable*)n) != (Object*)0;
        }

    bool isWeakDef(String* n)
        {
        for (u32 i = (u32)0; i < _weakDef.count(); i = i + (u32)1)
            if (((String*)_weakDef.get(i)).equals(n))
                return true;
        return false;
        }

    void dropWeakDef(String* n)
        {
        Array* keep = new Array();
        for (u32 i = (u32)0; i < _weakDef.count(); i = i + (u32)1)
            if (!((String*)_weakDef.get(i)).equals(n))
                keep.add(_weakDef.get(i));
        _weakDef = keep;
        Array* keepD = new Array();
        for (u32 i = (u32)0; i < _dataSyms.count(); i = i + (u32)1)
            if (!((String*)_dataSyms.get(i)).equals(n))
                keepD.add(_dataSyms.get(i));
        _dataSyms = keepD;
        }

    void noteWeakDef(String* n)
        {
        _weakDef.add((Object*)n);
        }

    void noteWeakUndef(String* n)
        {
        for (u32 i = (u32)0; i < _weakUndef.count(); i = i + (u32)1)
            if (((String*)_weakUndef.get(i)).equals(n))
                return;
        _weakUndef.add((Object*)n);
        }

    void addGlobal(String* n)
        {
        for (u32 i = (u32)0; i < _globals.count(); i = i + (u32)1)
            if (((String*)_globals.get(i)).equals(n))
                return;
        _globals.add((Object*)n);
        }
    }

    // An R_X86_64_64 inside the thread-local INITIALISATION image. It is applied to
    // the master copy, which every thread inherits, so it is resolved once after
    // the merge rather than per-thread.
    class TlsAbsReloc
    {
    u32 _off;
    String* _sym;
    i64 _addend;
    void init(void)
        {
        }
    u32 off(void)
        {
        return _off;
        }
    String* sym(void)
        {
        return _sym;
        }
    i64 addend(void)
        {
        return _addend;
        }
    void set(u32 o, String* s, i64 a)
        {
        _off = o;
        _sym = s;
        _addend = a;
        }
    }

    class ElfMerge
    {
    // Fold one object into the image. `tag` must be unique per object — it is
    // what keeps two members' static `buf`s apart.
    static void merge(MergedImage* im, ElfObject* o, String* label, u32 tag)
        {
        if (im.failed())
            return;

        // Code is 16-aligned; data takes the object's OWN strictest alignment,
        // floored at 8. Guessing 8 put musl's 16-byte .rodata.cst16 constants
        // on an 8-boundary and `movaps` faulted.
        ElfMerge._padTo(im.text(), (u32)16);
        u32 tbase = im.text().length();
        im.text().append(o.text());

        u32 dbase = im.data().length();
        u32 da = o.dataAlign() < (u32)8 ? (u32)8 : o.dataAlign();
        if (o.data().length() > (u32)0)
            {
            ElfMerge._padTo(im.data(), da);
            dbase = im.data().length();
            im.data().append(o.data());
            }
        // GC unit boundaries (bug 196): every section start and object start,
        // and every defined symbol — recorded BEFORE the duplicate check below,
        // so a dropped second definition still bounds its own bytes.
        im.noteObject(tbase, tbase + o.text().length(), dbase, dbase + o.data().length(), da, label);
            {
            Array* ts = o.textSecStarts();
            Array* ds = o.dataSecStarts();
            for (u32 i = (u32)0; i < ts.count(); i = i + (u32)1)
                im.noteTextBound(tbase + ((Number*)ts.get(i)).asU32());
            for (u32 i = (u32)0; i < ds.count(); i = i + (u32)1)
                im.noteDataBound(dbase + ((Number*)ds.get(i)).asU32());
            Array* sdAll = o.symdefs();
            for (u32 i = (u32)0; i < sdAll.count(); i = i + (u32)1)
                {
                ElfSymDef* s0 = (ElfSymDef*)sdAll.get(i);
                if (s0.where() == (u32)1)
                    im.noteTextBound(tbase + s0.off());
                else if (s0.where() == (u32)2 && s0.size() > (u32)0)
                    im.noteDataBound(dbase + s0.off());
                }
            }

        u32 lbase = (u32)0;
        if (o.tls().length() > (u32)0)
            {
            u32 la = o.tlsAlign() < (u32)1 ? (u32)1 : o.tlsAlign();
            ElfMerge._padTo(im.tls(), la);
            lbase = im.tls().length();
            im.tls().append(o.tls());
            }

        Array* sd = o.symdefs();
        for (u32 si = (u32)0; si < sd.count(); si = si + (u32)1)
            {
            ElfSymDef* s = (ElfSymDef*)sd.get(si);
            if (s.where() == (u32)0)
                {
                // Undefined. A WEAK reference resolves to absolute 0 if nothing
                // in the whole link defines it — remembered now, decided after
                // the archive fixpoint, when "nothing defines it" is a fact.
                if (s.weak() && s.name().byteLength() > (u32)0)
                    im.noteWeakUndef(s.name());
                continue;
                }
            String* nm = ElfMerge.tagged(o, si, tag);
            if (im.defines(nm))
                {
                // §4.3b: a duplicated `C$cat$Names` (the owner anchor) is the
                // same-NAMED category on one class in two modules; a duplicated
                // bare `X$cat` is the class itself compiled into two modules.
                // Both are worth saying out loud — "defined twice" sends the
                // reader looking for a symbol clash that is not the mistake.
                if (nm.contains(String.withCString("$cat$")))
                    {
                    im.fail(String.withCString("two modules define the same category on one class: ")
                                .appending(nm));
                    return;
                    }
                if (nm.hasSuffix(String.withCString("$cat")))
                    {
                    im.fail(String.withCString("class compiled into two modules (category-chain table defined twice): ")
                                .appending(nm));
                    return;
                    }
                // Strong beats weak whatever the order; a weak arriving second
                // is simply not registered.
                if (!s.weak() && im.isWeakDef(nm))
                    im.dropWeakDef(nm);
                else
                    continue;
                }
            // COMMON -> NOBITS bss
            if (s.where() == (u32)5)
                {
                // One slot per name (im.defines above already dropped dup defs,
                // first-def-wins; our codegen emits one COMMON def + externs).
                u32 cal = s.align() < (u32)1 ? (u32)1 : s.align();
                ElfMerge._padTo(im.bss(), cal);
                im.syms().set((Hashable*)nm, (Object*)Number.withU32(im.bss().length()));
                im.bssSyms().add((Object*)nm);
                im.dataSyms().add((Object*)nm); // resolves as a data address

                ElfMerge._zeros(im.bss(), s.size() != (u32)0 ? s.size() : (u32)8);
                if (cal > im.bssAlign())
                    im.setBssAlign(cal);
                if (s.ext())
                    im.addGlobal(nm);
                if (s.weak())
                    im.noteWeakDef(nm);
                continue;
                }
            // TLS: an offset
            if (s.where() == (u32)3)
                {
                if (im.tlsSyms().get((Hashable*)nm) == (Object*)0)
                    im.tlsSyms().set((Hashable*)nm, (Object*)Number.withU32(lbase + s.off()));
                continue;
                }
            if (s.where() == (u32)1)
                {
                im.syms().set((Hashable*)nm, (Object*)Number.withU32(tbase + s.off()));
                if (s.size() > (u32)0)
                    im.funcSizes().set((Hashable*)nm, (Object*)Number.withU32(s.size()));
                }
            else
                {
                im.syms().set((Hashable*)nm, (Object*)Number.withU32(dbase + s.off()));
                im.dataSyms().add((Object*)nm);
                }
            if (s.ext())
                im.addGlobal(nm);
            if (s.weak())
                im.noteWeakDef(nm);
            }

        ElfMerge._textRelocs(im, o, label, tag, tbase);
        ElfMerge._dataRelocs(im, o, label, tag, dbase);
        ElfMerge._tlsRelocs(im, o, label, tag, lbase);
        }

    // The assembler's fixup semantics ARE the ELF ones — `S + A - P` for the
    // PC-relative kinds, `S + A` for the absolute one — so only offsets move.
    static void _textRelocs(MergedImage* im, ElfObject* o, String* label, u32 tag, u32 tbase)
        {
        Array* rs = o.relocs();
        for (u32 i = (u32)0; i < rs.count(); i = i + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)rs.get(i);
            u32 rt = r.type();
            if (r.sym() >= o.symdefs().count())
                {
                im.fail(String.withCString("bad relocation symbol index in ").appending(label));
                return;
                }
            //  2 PC32   4 PLT32   9 GOTPCREL (not relaxable — read as data)
            // 23 TPOFF32 (local-exec TLS)   41/42 [REX_]GOTPCRELX (relaxable)
            if (rt != (u32)2 && rt != (u32)4 && rt != (u32)9 && rt != (u32)23 && rt != (u32)41 && rt != (u32)42)
                {
                String* w = String.withCString("unhandled text relocation type in ");
                w.append(label);
                if (rt == (u32)19 || rt == (u32)20 || rt == (u32)22)
                    w.appendCString(" (general/initial-exec TLS: build the library"
                                    " with -ftls-model=local-exec)");
                im.fail(w);
                return;
                }
            u32 kind = (u32)X86FIX_PC32;
            if (rt == (u32)4)
                kind = (u32)X86FIX_REL32;
            else if (rt == (u32)41 || rt == (u32)42)
                kind = (u32)X86FIX_GOTLOAD;
            else if (rt == (u32)9)
                kind = (u32)X86FIX_GOTREF;
            else if (rt == (u32)23)
                kind = (u32)X86FIX_TPOFF32;
            im.fixups().add((Object*)X86Fixup.make(tbase + r.off(), kind,
                                                   ElfMerge.tagged(o, r.sym(), tag),
                                                   (i32)r.addend()));
            }
        }

    static void _dataRelocs(MergedImage* im, ElfObject* o, String* label, u32 tag, u32 dbase)
        {
        Array* rs = o.dataRelocs();
        for (u32 i = (u32)0; i < rs.count(); i = i + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)rs.get(i);
            u32 rt = r.type();
            // 1 = an absolute slot. 2 = PC32 in DATA, a position-independent
            // jump table — musl's vfprintf has one and our back end never
            // emits one, so it exists only because of foreign input.
            if ((rt != (u32)1 && rt != (u32)2) || r.sym() >= o.symdefs().count())
                {
                im.fail(String.withCString("unhandled data relocation type in ").appending(label));
                return;
                }
            im.fixups().add((Object*)X86Fixup.make(dbase + r.off(),
                                                   rt == (u32)2 ? (u32)X86FIX_PC32DATA : (u32)X86FIX_ABS64,
                                                   ElfMerge.tagged(o, r.sym(), tag), (i32)r.addend()));
            }
        }

    static void _tlsRelocs(MergedImage* im, ElfObject* o, String* label, u32 tag, u32 lbase)
        {
        Array* rs = o.tlsRelocs();
        for (u32 i = (u32)0; i < rs.count(); i = i + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)rs.get(i);
            if (r.type() != (u32)1 || r.sym() >= o.symdefs().count())
                {
                im.fail(String.withCString("unhandled TLS-image relocation type in ").appending(label));
                return;
                }
            TlsAbsReloc* t = new TlsAbsReloc();
            t.set(lbase + r.off(), ElfMerge.tagged(o, r.sym(), tag), r.addend());
            im.tlsAbs().add((Object*)t);
            }
        }

    // The name a symbol is known by INSIDE the merged image.
    static String* tagged(ElfObject* o, u32 si, u32 tag)
        {
        ElfSymDef* s = (ElfSymDef*)o.symdefs().get(si);
        String* n = s.name();
        if (n == 0 || n.byteLength() == (u32)0)
            {
            // A section symbol: no name, and a relocation against it means
            // "this section + addend". It needs a name unique to (object,
            // index), registered under exactly the same one.
            String* out = String.withCString(".Lsec");
            out.appendFormat("%lu$o%lu", si, tag);
            return out;
            }
        if (s.ext() || s.where() == (u32)0)
            return n;
        String* out = String.withString(n);
        out.appendFormat("$o%lu", tag);
        return out;
        }

    static void _padTo(Data* d, u32 a)
        {
        if (a < (u32)1)
            a = (u32)1;
        while (d.length() % a != (u32)0)
            d.appendByte((u8)0);
        }

    static void _zeros(Data* d, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            d.appendByte((u8)0);
        }
    }
