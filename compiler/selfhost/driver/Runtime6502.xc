// Runtime6502.xc — the xt6502 runtime wrap, ported from XTIRRuntimeEmitter.
// ==========================================================================
//
// The arm64 path concatenates a fixed crt + runtime and assembles. The 6502
// path cannot: its runtime is a TREE of hand-written .asm under
// support/xt6502/asm/, and embedding all of it costs ~1.4 KB in a program that
// never allocates. So the runtime is LAZY-LINKED — this scans the generated
// assembly for the calls a routine would be reached by, and pulls in only
// those templates.
//
// The gate keys off the GENERATED TEXT, not the AST or the IR, because that is
// what the original does and because the per-class `new` stubs this file emits
// are themselves callers: a program whose only heap use is `JSR __xtc_alloc`
// still needs the heap linked (bug 019 — it was stripped, `new` ran on an
// uninitialised free list, and the pointer was garbage).
//
// Everything here is byte-for-byte mirror work. The emitted assembly IS the
// contract with xta and with the harness, so a template pulled in at the wrong
// moment, an alias not emitted, or a marker not stripped does not fail loudly:
// it links, and the program BRKs somewhere unrelated.

#import "Foundation.xc"
#import "Files.xc"
#import "Stdio.xc"
#import "Ir.xc"
#import "Layout.xc"

class Runtime6502
{
    // ── small helpers ────────────────────────────────────────────────────

    static bool contains(String* hay, string needle)
    {
        return hay.byteIndexOf(String.withCString(needle)) != (u32)$FFFF_FFFF;
    }

    static bool containsS(String* hay, String* needle)
    {
        return hay.byteIndexOf(needle) != (u32)$FFFF_FFFF;
    }

    static u8 hexDigit(u32 d)
    {
        string digits = "0123456789ABCDEF";
        return digits[d];
    }

    static String* hex2(u32 v)
    {
        String* o = String.withCString("");
        o.appendByte(hexDigit((v >> (u32)4) & (u32)$F));
        o.appendByte(hexDigit(v & (u32)$F));
        return o;
    }

    static String* hex4(u32 v)
    {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1) {
            u32 nib = (v >> ((u32)4 * ((u32)3 - i))) & (u32)$F;
            o.appendByte(hexDigit(nib));
        }
        return o;
    }

    // "u64/u64Mul" -> "u64Mul". The include paths are written as
    // <dir>/<name> and the ALIAS uses the bare name, so both spellings are
    // needed from the one table.
    static String* lastComponent(String* p)
    {
        u32 slash = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < p.byteLength(); i = i + (u32)1)
            if (p.byteAt(i) == (u8)'/') slash = i;
        if (slash == (u32)$FFFF_FFFF) return p;
        return p.substringFromByte(slash + (u32)1);
    }

    // ── templates ────────────────────────────────────────────────────────
    //
    // `rel` is relative to the SUPPORT ROOT (the directory holding xt6502/,
    // generic/, ...), not to the home above it — the same thing in a source
    // tree and different in an install, which is why the root is resolved once
    // by the caller and passed in. A missing template returns "" rather than
    // failing: that is the original's behaviour, and the assembler is what
    // reports the resulting dangling reference.
    static String* readTemplate(String* root, String* rel)
    {
        if (root != (String*)0 && root.byteLength() > (u32)0) {
            String* p = String.withString(root);
            p.appendCString("/");
            p.append(rel);
            String* s = Files.readText(p);
            if (s != (String*)0) return s;
        }
        String* cwdRel = String.withCString("support/");
        cwdRel.append(rel);
        String* s2 = Files.readText(cwdRel);
        if (s2 != (String*)0) return s2;
        String* up = String.withCString("../support/");
        up.append(rel);
        String* s3 = Files.readText(up);
        if (s3 != (String*)0) return s3;
        return String.withCString("");
    }

    // A banked runtime entry is reached through the unbanked _xcall
    // trampoline: stash the target in the vector, set the code bank, jump.
    static void appendBankedThunks(String* out, Array* names, string bankSymbol)
    {
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
            String* n = (String*)names.get(i);
            out.appendFormat("_%s:\n", n.cString());
            out.appendFormat("    LDA #<%s\n    STA _xcall_vec\n", n.cString());
            out.appendFormat("    LDA #>%s\n    STA _xcall_vec+1\n", n.cString());
            out.appendFormat("    LDA #%s\n    STA _xc_bank\n", bankSymbol);
            out.appendCString("    JMP _xcall\n");
        }
    }

    // The element width of a PRIMITIVE array element, or 0 when the suffix
    // names a class instead. Mirrors the original's table exactly — and it is
    // mirrored, not independently derived, because a unilateral change on
    // either side is a silent stride divergence in the emitted allocator.
    // `float` was FIVE here until private:docs/bugs/073: the width of the retired
    // bespoke float format, left behind when the language moved to IEEE
    // binary32. Changed in the SAME commit on both sides.
    static u32 primElemWidth(String* s)
    {
        if (s.equals(String.withCString("bool")))    return (u32)1;
        if (s.equals(String.withCString("i8")))      return (u32)1;
        if (s.equals(String.withCString("u8")))      return (u32)1;
        if (s.equals(String.withCString("i16")))     return (u32)2;
        if (s.equals(String.withCString("u16")))     return (u32)2;
        if (s.equals(String.withCString("i32")))     return (u32)4;
        if (s.equals(String.withCString("u32")))     return (u32)4;
        if (s.equals(String.withCString("pointer"))) return (u32)3;
        if (s.equals(String.withCString("string")))  return (u32)3;
        if (s.equals(String.withCString("float")))   return (u32)4;
        if (s.equals(String.withCString("double")))  return (u32)8;
        return (u32)0;
    }

    static bool moduleHasFunc(IRModule* mod, String* name)
    {
        for (u32 i = (u32)0; i < mod.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)mod.funcs().get(i)).name().equals(name)) return true;
        return false;
    }

    static bool moduleHasRuntimeSymbolPrefixed(IRModule* mod, string prefix)
    {
        String* p = String.withCString(prefix);
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)mod.syms().get(i);
            if (s.kind() != (u8)SYM_RUNTIME) continue;
            if (s.name().hasPrefix(p)) return true;
        }
        return false;
    }

    static bool moduleHasRuntimeSymbol(IRModule* mod, string name)
    {
        String* n = String.withCString(name);
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)mod.syms().get(i);
            if (s.kind() == (u8)SYM_RUNTIME && s.name().equals(n)) return true;
        }
        return false;
    }

    // Strip a marker-bracketed span, inclusive of both markers. The harness
    // brackets its heap-init call and its ARC stubs with @@LL-...@@ comments so
    // the prepended startup can be made to match the runtime actually embedded
    // below it.
    static String* stripSpan(String* s, string beginM, string endM)
    {
        String* b = String.withCString(beginM);
        String* e = String.withCString(endM);
        u32 rb = s.byteIndexOf(b);
        u32 re = s.byteIndexOf(e);
        if (rb == (u32)$FFFF_FFFF || re == (u32)$FFFF_FFFF || re < rb) return s;
        String* out = String.withString(s.substringToByte(rb));
        out.append(s.substringFromByte(re + e.byteLength()));
        return out;
    }

    // ── the wrap ─────────────────────────────────────────────────────────

    static String* wrap(String* generatedAsm, IRModule* mod, Layout* layout,
                        String* root, String* harnessRel)
    {
        String* out = String.withCString("");
        String* harness = readTemplate(root, harnessRel);

        // The base harness ships degenerate weak no-op stubs. When the program
        // really uses weak refs, strip them so the real side-table adapters
        // emitted below do not collide with them.
        bool usesWeak = contains(generatedAsm, "JSR __xtc_weak_register")
                     || contains(generatedAsm, "JSR __xtc_weak_unregister");
        if (usesWeak) {
            harness = harness.replacing(
                String.withCString("__xtc_weak_register:\n    RTS\n__xtc_weak_unregister:\n    RTS\n__xtc_weak_load:\n    LDA #0\n    LDX #0\n    TAY\n    RTS\n"),
                String.withCString("; (weak no-op stubs replaced by the real side-table)\n"));
        }
        out.append(harness);
        out.appendCString("\n");

        // ── per-`new` allocator stubs ────────────────────────────────────
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() != (u8)SYM_RUNTIME) continue;
            if (!sym.name().hasPrefix(String.withCString("_xtc_new_"))) continue;
            String* suffix = sym.name().substringFromByte((u32)9);   // "_xtc_new_"
            u32 w = primElemWidth(suffix);
            if (w != (u32)0) {
                u32 shift = (u32)0;
                u32 tmp = w;
                while ((tmp & (u32)1) == (u32)0 && tmp > (u32)1) {
                    shift = shift + (u32)1; tmp = tmp >> (u32)1;
                }
                bool pow2 = (tmp == (u32)1);
                out.appendFormat("_%s:\n", sym.name().cString());
                if (pow2 && shift == (u32)0) {
                    out.appendCString("    LDA +3,SP\n    LDX +4,SP\n    JMP _heap_alloc16\n");
                } else if (pow2) {
                    out.appendCString("    LDA +3,SP\n    TAX\n    LDA +4,SP\n");
                    for (u32 b = (u32)0; b < shift; b = b + (u32)1)
                        out.appendCString("    ASL A\n    PHA\n    TXA\n    ROL A\n    TAX\n    PLA\n");
                    out.appendCString("    STX _tmp\n    ADC #$00\n    TAX\n    LDA _tmp\n    JMP _heap_alloc16\n");
                } else {
                    out.appendCString("    LDA +3,SP\n    STA _tmp\n    LDA +4,SP\n    STA _tmp+1\n");
                    for (u32 r = (u32)1; r < w; r = r + (u32)1)
                        out.appendCString("    CLC\n    LDA _tmp\n    ADC +3,SP\n    STA _tmp\n"
                                          "    LDA _tmp+1\n    ADC +4,SP\n    STA _tmp+1\n");
                    out.appendCString("    LDA _tmp\n    LDX _tmp+1\n    JMP _heap_alloc16\n");
                }
                continue;
            }
            // A CLASS element. The descriptor at obj+60 is [bank, lo, hi] —
            // the order __xtc_release reads it back in.
            String* className = suffix;
            String* deallocName = String.withString(className);
            deallocName.appendCString("$dealloc");
            if (moduleHasFunc(mod, deallocName)) {
                out.appendFormat("_%s:\n", sym.name().cString());
                out.appendCString("    LDX #$00\n    LDA #$40\n    JSR _heap_alloc16\n"
                                  "    STA $90\n    STX $91\n    STY $92\n    STY __bank_data_reg\n"
                                  "    LDA $90\n    STA $98\n    LDA $91\n    STA $99\n"
                                  "    LDY #xtc_desc_off\n");
                out.appendFormat("    LDA #__dbank_%s$dealloc\n", className.cString());
                out.appendCString("    STA ($98),Y\n    INY\n");
                out.appendFormat("    LDA #<_%s$dealloc\n", className.cString());
                out.appendCString("    STA ($98),Y\n    INY\n");
                out.appendFormat("    LDA #>_%s$dealloc\n", className.cString());
                out.appendCString("    STA ($98),Y\n"
                                  "    LDY #56\n"
                                  "    LDA +5,SP\n    STA ($98),Y\n    INY\n"
                                  "    LDA +6,SP\n    STA ($98),Y\n    INY\n"
                                  "    LDA +3,SP\n    STA ($98),Y\n    INY\n"
                                  "    LDA +4,SP\n    STA ($98),Y\n"
                                  "    LDA #$00\n    STA __bank_data_reg\n"
                                  "    LDA $90\n    LDX $91\n    LDY $92\n    RTS\n");
            } else {
                out.appendFormat("_%s:\n", sym.name().cString());
                out.appendCString("    LDX #$00\n    LDA #$40\n    JSR _heap_alloc16\n"
                                  "    STA $90\n    STX $91\n    STY $92\n    STY __bank_data_reg\n"
                                  "    LDA $90\n    STA $98\n    LDA $91\n    STA $99\n"
                                  "    LDA #$00\n    LDY #xtc_desc_off\n"
                                  "    STA ($98),Y\n    INY\n"
                                  "    STA ($98),Y\n    INY\n"
                                  "    STA ($98),Y\n"
                                  "    STA __bank_data_reg\n"
                                  "    LDA $90\n    LDX $91\n    LDY $92\n    RTS\n");
            }
        }

        // ── the single generic class allocator ───────────────────────────
        // `new T` lowers to _xtc_alloc(count, stride, deallocPtr); one
        // allocator serves every class. Args on the hw stack, little-endian:
        // count @+3,+4; stride @+5,+6; deallocPtr lo@+7 hi@+8 bank@+9.
        if (moduleHasRuntimeSymbol(mod, "_xtc_alloc")) {
            out.appendCString(
                "__xtc_alloc:\n"
                "    LDX #$00\n    LDA #$40\n    JSR _heap_alloc16\n"
                "    STA $90\n    STX $91\n    STY $92\n    STY __bank_data_reg\n"
                "    LDA $90\n    STA $98\n    LDA $91\n    STA $99\n"
                "    LDY #xtc_desc_off\n"
                "    LDA +9,SP\n    STA ($98),Y\n"
                "    INY\n    LDA +7,SP\n    STA ($98),Y\n"
                "    INY\n    LDA +8,SP\n    STA ($98),Y\n"
                "    LDY #56\n"
                "    LDA +5,SP\n    STA ($98),Y\n"
                "    INY\n    LDA +6,SP\n    STA ($98),Y\n"
                "    INY\n    LDA +3,SP\n    STA ($98),Y\n"
                "    INY\n    LDA +4,SP\n    STA ($98),Y\n"
                "    LDA #$00\n    STA __bank_data_reg\n"
                "    LDA $90\n    LDX $91\n    LDY $92\n    RTS\n");
        }

        // ── bank(type, idx) ──────────────────────────────────────────────
        // Window high bytes come from the LAYOUT, never hardcoded. For a DATA
        // bank the index is also marked claimed in the shared bitmap, so the
        // on-demand heap never hands out the same page.
        if (moduleHasRuntimeSymbol(mod, "_xtc_bank")) {
            u32 dataWinHi = (layout.dataWindowStart() >> (u32)8) & (u32)$FF;
            u32 codeWinHi = (layout.bankWindowStart() >> (u32)8) & (u32)$FF;
            out.appendCString(
                "__xtc_bank:\n"
                "    LDA +4,SP\n"
                "    TAY\n"
                "    LDA +3,SP\n"
                "    BEQ __xb_data\n"
                "    CMP #$01\n"
                "    BEQ __xb_code\n"
                "    LDA #$00\n"
                "    LDX #$00\n"
                "    LDY #$00\n"
                "    RTS\n"
                "__xb_data:\n"
                "    LDA #heap_bank_dynamic\n"
                "    BEQ __xb_data_ret\n"
                "    TYA\n"
                "    PHA\n"
                "    JSR _bank_set\n"
                "    PLA\n"
                "    TAY\n"
                "__xb_data_ret:\n"
                "    LDA #$00\n");
            out.appendFormat("    LDX #$%s\n    RTS\n", hex2(dataWinHi).cString());
            out.appendCString("__xb_code:\n    LDA #$00\n");
            out.appendFormat("    LDX #$%s\n    RTS\n", hex2(codeWinHi).cString());
        }

        // ── heap config, from the layout ─────────────────────────────────
        u32 heapPages = (u32)0;
        if (layout.heapBankLast() >= layout.heapBankFirst() && layout.heapBankFirst() != (u32)0)
            heapPages = layout.heapBankLast() - layout.heapBankFirst() + (u32)1;
        u32 heapTotal = heapPages * layout.dataPageSize();
        out.appendCString("\n; ── banked free-list heap config (from layout) ──\n");
        out.appendFormat("heap_bank_first = $%s\n", hex2(layout.heapBankFirst()).cString());
        out.appendFormat("heap_bank_last  = $%s\n", hex2(layout.heapBankLast()).cString());
        out.appendFormat("heap_bank_dynamic = $%s\n",
                         hex2(layout.heapBankDynamic() ? (u32)1 : (u32)0).cString());
        out.appendCString("regC_heap_bank_first = $00\n"
                          "regC_heap_bank_last  = $00\n");
        out.appendFormat("heap_low  = $%s\n", hex4(layout.heapStart()).cString());
        out.appendFormat("heap_end  = $%s\n", hex4(layout.heapEnd()).cString());
        out.appendCString("regC_heap_low = $0000\n"
                          "regC_heap_end = $0000\n");
        out.appendFormat("heap_total_bytes    = $%s\n", hex4(heapTotal & (u32)$FFFF).cString());
        out.appendFormat("heap_total_bytes_b2 = $%s\n",
                         hex2((heapTotal >> (u32)16) & (u32)$FF).cString());
        out.appendFormat("heap_total_bytes_b3 = $%s\n",
                         hex2((heapTotal >> (u32)24) & (u32)$FF).cString());
        out.appendCString("_tmp: .byte $00, $00\n");

        // ── the lazy-link gate ───────────────────────────────────────────
        //
        // Only embed the heap / ARC / bank runtime when the program reaches it.
        // The per-class and primitive `new` stubs emitted above call
        // _heap_alloc16, so ANY `new` symbol forces the heap in even when the
        // user code only JSRs the stub — the stub lives outside generatedAsm.
        // ARC's release path frees through the heap, so usesARC implies
        // usesHeap.
        bool usesARC = contains(generatedAsm, "JSR __xtc_retain")
                    || contains(generatedAsm, "JSR __xtc_release")
                    || contains(generatedAsm, "JSR __xtc_dealloc")
                    || contains(generatedAsm, "JSR _obj_");
        bool hasNewSymbol = moduleHasRuntimeSymbolPrefixed(mod, "_xtc_new_");
        bool usesHeap = usesARC || hasNewSymbol
                     || contains(generatedAsm, "JSR _heap_alloc")
                     || contains(generatedAsm, "JSR _heap_free")
                     || contains(generatedAsm, "JSR _xtc_new_")
                     // bug 019: `new` for a class local lowers to the generic
                     // _xtc_alloc, and a program that calls it needs the heap
                     // even with no retain/release at all. Without this the
                     // heap and _heap_init were stripped and `new` ran on an
                     // uninitialised free list.
                     || contains(generatedAsm, "JSR __xtc_alloc");
        // bank() claims data banks through the same bitmap allocator the heap
        // uses, so it needs the bank allocator even with no heap.
        bool usesBank = contains(generatedAsm, "JSR __xtc_bank")
                     || contains(generatedAsm, "JSR _bank_");

        // {{zp.hp}} / {{zp.tmp}} live inside the layout's arc-scratch window:
        // the heap walk pointer at arc+6, the secondary pointer at arc+8.
        u32 zpHp  = layout.arcStart() + (u32)6;
        u32 zpTmp = layout.arcStart() + (u32)8;

        if (usesHeap || usesBank) {
            out.append(readTemplate(root, String.withCString("xt6502/asm/heap/bank-alloc.asm")));
            out.appendCString("\n");
            out.append(readTemplate(root, String.withCString("xt6502/asm/heap/bank-xt.asm")));
            out.appendCString("\n");
        }
        if (usesHeap) {
            String* heapSrc = readTemplate(root, String.withCString("xt6502/asm/heap/heap.asm"));
            String* hpS = String.withCString("$"); hpS.append(hex2(zpHp));
            String* tmpS = String.withCString("$"); tmpS.append(hex2(zpTmp));
            heapSrc = heapSrc.replacing(String.withCString("{{zp.hp}}"), hpS);
            heapSrc = heapSrc.replacing(String.withCString("{{zp.tmp}}"), tmpS);
            out.appendCString("\n");
            out.append(heapSrc);
            out.appendCString("\n");
        }
        if (usesARC) {
            String* retainSrc = readTemplate(root, String.withCString("xt6502/asm/heap/retain.asm"));
            String* tmpS = String.withCString("$"); tmpS.append(hex2(zpTmp));
            retainSrc = retainSrc.replacing(String.withCString("{{zp.tmp}}"), tmpS);
            retainSrc = retainSrc.replacing(String.withCString("{{weak.zeroAllHook}}"),
                usesWeak ? String.withCString("JSR _weak_zero_all_for")
                         : String.withCString("; (driver: no weak side-table)"));
            retainSrc = retainSrc.replacing(String.withCString("{{heap.objBankStash}}"),
                                            String.withCString("STY _obj_bank"));
            out.append(retainSrc);
            out.appendCString("\n");
        }

        // ── the 64-bit pack, linked only when referenced ─────────────────
        //
        // The i8/i16/i32 mul/div/mod pack is unconditional: small, and nearly
        // every program touches some of it. The 64-bit routines are neither, so
        // they are gated the same way the heap is.
        appendPack64(out, generatedAsm);

        if (usesWeak) {
            String* weakSrc = readTemplate(root, String.withCString("xt6502/asm/weak/weak.asm"));
            String* tmpS = String.withCString("$"); tmpS.append(hex2(zpTmp));
            weakSrc = weakSrc.replacing(String.withCString("{{zp.tmp}}"), tmpS);
            out.append(weakSrc);
            out.appendCString(
                "__xtc_weak_register:\n"
                "    LDA $84\n    STA _weak_slot\n"
                "    LDA $85\n    STA _weak_slot+1\n"
                "    LDA $86\n    STA _weak_slot_bank\n"
                "    LDA $87\n    LDX $88\n    LDY $89\n"
                "    JMP _weak_register\n"
                // The slot's BANK matters to unregister: it walks the links
                // living in front of the slot, so the slot's bank has to be
                // mapped. The old side-table only compared main-RAM bytes and
                // could ignore it.
                "__xtc_weak_unregister:\n"
                "    LDA $84\n    STA _weak_slot\n"
                "    LDA $85\n    STA _weak_slot+1\n"
                "    LDA $86\n    STA _weak_slot_bank\n"
                "    JMP _weak_unregister\n"
                "__xtc_weak_load:\n"
                "    LDY #$00\n    LDA ($84),Y\n    PHA\n"
                "    INY\n    LDA ($84),Y\n    TAX\n"
                "    INY\n    LDA ($84),Y\n    TAY\n"
                "    PLA\n    RTS\n\n");
        }

        // ── float / double, banked ───────────────────────────────────────
        appendFloatAndDouble(out, generatedAsm);

        out.appendCString("\n");
        out.append(generatedAsm);
        appendFloatDoubleBanks(out, generatedAsm);

        // Strip the harness's heap-init call / ARC stubs the program never
        // reaches, so the prepended startup matches the runtime embedded above.
        String* result = out;
        if (!usesHeap) result = stripSpan(result, "; @@LL-HEAPINIT-BEGIN@@", "; @@LL-HEAPINIT-END@@");
        if (!usesARC)  result = stripSpan(result, "; @@LL-ARC-BEGIN@@", "; @@LL-ARC-END@@");
        return result;
    }

    // ── the 64-bit pack ──────────────────────────────────────────────────

    static bool refsCall(String* asmText, String* name)
    {
        String* pat = String.withCString("JSR _");
        pat.append(name);
        return containsS(asmText, pat);
    }

    static void appendPack64(String* out, String* generatedAsm)
    {
        Array* pack = new Array();
        pack.add((Object*)String.withCString("u64/u64Add"));
        pack.add((Object*)String.withCString("u64/u64Sub"));
        pack.add((Object*)String.withCString("u64/u64Mul"));
        pack.add((Object*)String.withCString("u64/u64Div"));
        pack.add((Object*)String.withCString("u64/u64Mod"));
        pack.add((Object*)String.withCString("i64/i64Add"));
        pack.add((Object*)String.withCString("i64/i64Sub"));
        pack.add((Object*)String.withCString("i64/i64Mul"));
        pack.add((Object*)String.withCString("i64/i64Div"));
        pack.add((Object*)String.withCString("i64/i64Mod"));
        pack.add((Object*)String.withCString("i64/i64Abs"));

        String* inc = String.withCString("");
        String* alias = String.withCString("");
        Array* have = new Array();
        for (u32 i = (u32)0; i < pack.count(); i = i + (u32)1) {
            String* rel = (String*)pack.get(i);
            String* name = lastComponent(rel);
            if (!refsCall(generatedAsm, name)) continue;
            inc.appendFormat(".include \"xt6502/asm/%s.asm\"\n", rel.cString());
            alias.appendFormat("_%s = %s\n", name.cString(), name.cString());
            have.add((Object*)rel);
        }
        // The three shifts share one file — the back end calls them by the
        // unsigned name at every width, and they are useless separately. No
        // alias: they are already labelled _u64Shl etc.
        Array* shifts = new Array();
        shifts.add((Object*)String.withCString("u64Shl"));
        shifts.add((Object*)String.withCString("u64LShr"));
        shifts.add((Object*)String.withCString("u64AShr"));
        for (u32 i = (u32)0; i < shifts.count(); i = i + (u32)1) {
            if (!refsCall(generatedAsm, (String*)shifts.get(i))) continue;
            if (!contains(inc, "u64Shifts"))
                inc.appendCString(".include \"xt6502/asm/u64/u64Shifts.asm\"\n");
        }
        if (inc.byteLength() == (u32)0) return;

        // CLOSE THE DEPENDENCY GRAPH. A routine reaches its siblings by their
        // BARE label — i64Mod does `JSR i64Div`, and the signed add/sub/mul
        // TAIL-CALL their unsigned twin with `JMP u64Add` — so scanning the
        // generated asm can never see those edges, and a callee left out
        // resolves to $0000. The edges are a TABLE, not a scan of the .asm
        // files: this runs with different support roots in different callers,
        // so a file read that works in one silently returns nothing in the
        // other. Re-derive with:
        //   grep -oE "J(SR|MP) _?[a-zA-Z][a-zA-Z0-9_]*" support/xt6502/asm/{i,u}64/*.asm
        bool grew = true;
        while (grew) {
            grew = false;
            for (u32 i = (u32)0; i < have.count(); i = i + (u32)1) {
                String* rel = (String*)have.get(i);
                String* cand = calleeOf(rel);
                if (cand == (String*)0) continue;
                if (hasRel(have, cand)) continue;
                have.add((Object*)cand);
                inc.appendFormat(".include \"xt6502/asm/%s.asm\"\n", cand.cString());
                alias.appendFormat("_%s = %s\n", lastComponent(cand).cString(),
                                                 lastComponent(cand).cString());
                grew = true;
            }
        }
        out.append(inc);
        out.append(alias);
    }

    static bool hasRel(Array* a, String* rel)
    {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(rel)) return true;
        return false;
    }

    // The single callee each 64-bit routine reaches by a bare label.
    static String* calleeOf(String* rel)
    {
        if (rel.equals(String.withCString("i64/i64Add"))) return String.withCString("u64/u64Add");
        if (rel.equals(String.withCString("i64/i64Sub"))) return String.withCString("u64/u64Sub");
        if (rel.equals(String.withCString("i64/i64Mul"))) return String.withCString("u64/u64Mul");
        if (rel.equals(String.withCString("i64/i64Div"))) return String.withCString("u64/u64Div");
        if (rel.equals(String.withCString("i64/i64Mod"))) return String.withCString("i64/i64Div");
        if (rel.equals(String.withCString("u64/u64Mod"))) return String.withCString("u64/u64Div");
        return (String*)0;
    }

    // ── float / double ───────────────────────────────────────────────────

    static bool uses(String* asmText, string rt)
    {
        String* a = String.withCString("JSR _"); a.appendCString(rt);
        String* b = String.withCString("JSR ");  b.appendCString(rt);
        return containsS(asmText, a) || containsS(asmText, b);
    }

    static Array* floatNames(void)
    {
        Array* a = new Array();
        a.add((Object*)String.withCString("u32ToFp"));
        a.add((Object*)String.withCString("i32ToFp"));
        a.add((Object*)String.withCString("i16ToFp"));
        a.add((Object*)String.withCString("i8ToFp"));
        a.add((Object*)String.withCString("u16ToFp"));
        a.add((Object*)String.withCString("u8ToFp"));
        a.add((Object*)String.withCString("fpToI32"));
        a.add((Object*)String.withCString("fpAdd"));
        a.add((Object*)String.withCString("fpSub"));
        a.add((Object*)String.withCString("fpMul"));
        a.add((Object*)String.withCString("fpDiv"));
        a.add((Object*)String.withCString("fpCmp"));
        a.add((Object*)String.withCString("fp2Asc"));
        a.add((Object*)String.withCString("asc2fp"));
        return a;
    }

    static Array* doubleNames(void)
    {
        Array* a = new Array();
        a.add((Object*)String.withCString("dpAdd"));
        a.add((Object*)String.withCString("dpSub"));
        a.add((Object*)String.withCString("dpMul"));
        a.add((Object*)String.withCString("dpDiv"));
        a.add((Object*)String.withCString("dpCmp"));
        a.add((Object*)String.withCString("dp2Asc"));
        a.add((Object*)String.withCString("dpToFp"));
        a.add((Object*)String.withCString("fpToDp"));
        a.add((Object*)String.withCString("i8ToDp"));
        a.add((Object*)String.withCString("i16ToDp"));
        a.add((Object*)String.withCString("i32ToDp"));
        a.add((Object*)String.withCString("u8ToDp"));
        a.add((Object*)String.withCString("u16ToDp"));
        a.add((Object*)String.withCString("u32ToDp"));
        a.add((Object*)String.withCString("dpSqrt"));
        a.add((Object*)String.withCString("dpMod"));
        a.add((Object*)String.withCString("asc2dp"));
        return a;
    }

    static bool needTrig(String* g)
    {
        return uses(g, "fpSin") || uses(g, "fpCos") || uses(g, "fpTan") || uses(g, "fpAtan");
    }

    static bool needDouble(String* g)
    {
        return contains(g, "JSR _dp") || contains(g, "JSR dp")
            || uses(g, "u32ToDp") || uses(g, "i32ToDp") || uses(g, "u16ToDp")
            || uses(g, "i16ToDp") || uses(g, "u8ToDp")  || uses(g, "i8ToDp")
            || uses(g, "dpToFp")  || uses(g, "fpToDp")  || uses(g, "asc2dp");
    }

    static bool needFloat(String* g)
    {
        if (needDouble(g)) return true;
        if (needTrig(g) || uses(g, "fpSqrt") || uses(g, "fpAbs") || uses(g, "fpMod")) return true;
        Array* fn = floatNames();
        for (u32 i = (u32)0; i < fn.count(); i = i + (u32)1) {
            String* n = (String*)fn.get(i);
            String* a = String.withCString("JSR _"); a.append(n);
            String* b = String.withCString("JSR ");  b.append(n);
            if (containsS(g, a) || containsS(g, b)) return true;
        }
        return false;
    }

    static Array* extrasLinked(String* g)
    {
        Array* e = new Array();
        if (needTrig(g)) {
            e.add((Object*)String.withCString("fpSin"));
            e.add((Object*)String.withCString("fpCos"));
            e.add((Object*)String.withCString("fpTan"));
            e.add((Object*)String.withCString("fpAtan"));
        }
        if (uses(g, "fpSqrt")) e.add((Object*)String.withCString("fpSqrt"));
        if (uses(g, "fpAbs"))  e.add((Object*)String.withCString("fpAbs"));
        if (uses(g, "fpMod"))  e.add((Object*)String.withCString("fpMod"));
        return e;
    }

    static void appendFloatAndDouble(String* out, String* g)
    {
        bool nf = needFloat(g);
        bool nd = needDouble(g);
        if (!nf && !nd) return;
        out.appendCString("\n; ── Banked-runtime thunks (task #121) ──\n");
        if (nf) {
            appendBankedThunks(out, floatNames(), "__bank_fpRuntime");
            appendBankedThunks(out, extrasLinked(g), "__bank_fpRuntime");
        }
        if (nd) appendBankedThunks(out, doubleNames(), "__bank_dpRuntime");
    }

    static void appendFloatDoubleBanks(String* out, String* g)
    {
        bool nf = needFloat(g);
        bool nd = needDouble(g);
        if (nf || nd) out.appendCString("\n; ── Banked float/double runtime (task #121) ──\n");
        if (nf) {
            out.appendCString(".bank fpRuntime\n");
            Array* fn = floatNames();
            for (u32 i = (u32)0; i < fn.count(); i = i + (u32)1)
                out.appendFormat(".include \"xt6502/asm/float/%s.asm\"\n",
                                 ((String*)fn.get(i)).cString());
            if (needTrig(g)) {
                out.appendCString(".include \"xt6502/asm/float/fpTrig.asm\"\n");
                out.appendCString(".include \"xt6502/asm/float/fpTrigReduce.asm\"\n");
            }
            if (uses(g, "fpSqrt")) out.appendCString(".include \"xt6502/asm/float/fpSqrt.asm\"\n");
            if (uses(g, "fpAbs"))  out.appendCString(".include \"xt6502/asm/float/fpAbs.asm\"\n");
            if (uses(g, "fpMod"))  out.appendCString(".include \"xt6502/asm/float/fpMod.asm\"\n");
        }
        if (nd) {
            out.appendCString(".bank dpRuntime\n");
            Array* dn = doubleNames();
            for (u32 i = (u32)0; i < dn.count(); i = i + (u32)1)
                out.appendFormat(".include \"xt6502/asm/double/%s.asm\"\n",
                                 ((String*)dn.get(i)).cString());
        }
    }
}
