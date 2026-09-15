// Peep6502.xc — the xt6502 asm-text peephole, ported from XT6502AsmPeephole.
// ==========================================================================
//
// Runs over the RAW back-end output at -O>=1 to close patterns the SSA→stack
// lowering opens up. It is not cosmetic: the xt6502 corpus fixture
// vtable_stack_args builds and RUNS CORRECTLY at -O1 and produces nothing at
// -O2 without this pass, so the pre-peephole text is not merely bigger — the
// reference has never executed that path, because the peephole has always been
// there above -O0.
//
// Six rules, applied to a fixed point (rule 2 can expose new rule 1 patterns
// and vice versa). Everything is line-level: each `\n`-separated line is blank,
// a comment, a label, a directive, or an instruction, and a rule may only fuse
// across lines that do not change that classification.

#import "Foundation.xc"

#define LK_BLANK $00
#define LK_COMMENT $01
#define LK_LABEL $02
#define LK_INSN $03
#define LK_DIRECTIVE $04

class Peep6502
    {
    // ── line plumbing ────────────────────────────────────────────────────

    static Array* splitLines(String* text)
        {
        Array* out = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < text.byteLength(); i = i + (u32)1)
            {
            if (text.byteAt(i) == (u8)'\n')
                {
                out.add((Object*)text.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        out.add((Object*)text.substringFromByte(start));
        return out;
        }

    static String* joinLines(Array* lines)
        {
        String* o = String.withCString("");
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                o.appendByte((u8)'\n');
            o.append((String*)lines.get(i));
            }
        return o;
        }

    static bool isSpace(u8 c)
        {
        return c == (u8)' ' || c == (u8)'\t' || c == (u8)'\r';
        }

    static String* trimmed(String* line)
        {
        u32 a = (u32)0;
        u32 b = line.byteLength();
        while (a < b && isSpace(line.byteAt(a)))
            a = a + (u32)1;
        while (b > a && isSpace(line.byteAt(b - (u32)1)))
            b = b - (u32)1;
        return line.substringBytes(a, b - a);
        }

    static u8 classify(String* line)
        {
        String* t = trimmed(line);
        if (t.byteLength() == (u32)0)
            return (u8)LK_BLANK;
        if (t.byteAt((u32)0) == (u8)';')
            return (u8)LK_COMMENT;
        if (t.byteAt((u32)0) == (u8)'.')
            {
            // A directive UNLESS it is a local label (`.Licmp3_store:`), which
            // is a branch target and must classify as one.
            if (t.byteAt(t.byteLength() - (u32)1) == (u8)':')
                return (u8)LK_LABEL;
            return (u8)LK_DIRECTIVE;
            }
        // A label sits at column 0. `name = expr` is an equate, also column 0.
        if (line.byteLength() > (u32)0 && !isSpace(line.byteAt((u32)0)))
            {
            if (t.byteAt(t.byteLength() - (u32)1) == (u8)':')
                return (u8)LK_LABEL;
            if (t.byteIndexOf(String.withCString("=")) != (u32)$FFFF_FFFF)
                return (u8)LK_LABEL;
            }
        return (u8)LK_INSN;
        }

    // The opcode is the first token; the operand is the rest, trimmed. Both
    // are "" when absent.
    static String* opOf(String* line)
        {
        String* t = trimmed(line);
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (isSpace(t.byteAt(i)))
                return t.substringBytes((u32)0, i);
        return t;
        }

    static String* operandOf(String* line)
        {
        String* t = trimmed(line);
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (isSpace(t.byteAt(i)))
                return trimmed(t.substringFromByte(i));
        return String.withCString("");
        }

    static bool eq(String* a, string b)
        {
        return a.equals(String.withCString(b));
        }

    static bool isFlagBranch(String* op)
        {
        return eq(op, "BEQ") || eq(op, "BNE") || eq(op, "BMI") || eq(op, "BPL");
        }

    static bool isFlagOnly(String* op)
        {
        return eq(op, "CLC") || eq(op, "SEC") || eq(op, "CLD") || eq(op, "SED") || eq(op, "CLV") || eq(op, "CLI") || eq(op, "SEI") || eq(op, "NOP");
        }

    static bool isStoreOp(String* op)
        {
        return eq(op, "STA") || eq(op, "STX") || eq(op, "STY");
        }

    static bool isCondBranch(String* op)
        {
        return eq(op, "BCC") || eq(op, "BCS") || eq(op, "BEQ") || eq(op, "BNE") || eq(op, "BMI") || eq(op, "BPL") || eq(op, "BVC") || eq(op, "BVS");
        }

    static bool isBarrier(String* op)
        {
        return eq(op, "JMP") || eq(op, "JSR") || eq(op, "RTS") || eq(op, "RTI") || eq(op, "BRK") || eq(op, "BEQ") || eq(op, "BNE") || eq(op, "BMI") || eq(op, "BPL") || eq(op, "BCC") || eq(op, "BCS") || eq(op, "BVC") || eq(op, "BVS") || eq(op, "BRA") || eq(op, "PHA") || eq(op, "PLA") || eq(op, "PSH") || eq(op, "PLL") || eq(op, "TXS") || eq(op, "TSX") || eq(op, "ADD");
        }

    // ── Rule 1: redundant reload elimination ─────────────────────────────
    //
    //     STA +N,SP
    //     LDA +N,SP    <- A still holds it; drop
    //
    // Safety: the LDA sets Z/N and STA does not, so a reload immediately
    // before a flag-reading branch SUPPLIES the flags that branch tests.
    // Dropping it there miscompiled a loop bound into an infinite loop.
    static String* redundantReload(String* text)
        {
        Array* lines = splitLines(text);
        u32 n = lines.count();
        Array* out = new Array();
        String* prevOp = (String*)0;
        String* prevOperand = (String*)0;
        u8 prevKind = (u8)LK_BLANK;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            u8 k = classify(line);
            if (k != (u8)LK_INSN)
                {
                out.add((Object*)line);
                prevOp = (String*)0;
                prevOperand = (String*)0;
                prevKind = k;
                continue;
                }
            String* op = opOf(line);
            String* operand = operandOf(line);
            if (isFlagOnly(op))
                {
                // Transparent to the reload chain: emit, and KEEP prev, so
                // `STA s / CLC / LDA s` still recognises the reload.
                out.add((Object*)line);
                continue;
                }
            bool drop = false;
            if (prevKind == (u8)LK_INSN && prevOperand != (String*)0 && operand.byteLength() > (u32)0 && operand.equals(prevOperand))
                {
                if ((eq(prevOp, "STA") && eq(op, "LDA")) || (eq(prevOp, "STX") && eq(op, "LDX")) || (eq(prevOp, "STY") && eq(op, "LDY")))
                    drop = true;
                }
            if (drop)
                {
                for (u32 j = i + (u32)1; j < n; j = j + (u32)1)
                    {
                    u8 kk = classify((String*)lines.get(j));
                    if (kk == (u8)LK_BLANK || kk == (u8)LK_COMMENT)
                        continue;
                    if (kk == (u8)LK_INSN)
                        {
                        if (isFlagBranch(opOf((String*)lines.get(j))))
                            drop = false;
                        }
                    break;
                    }
                }
            if (!drop)
                {
                out.add((Object*)line);
                prevOp = op;
                prevOperand = operand;
                prevKind = k;
                }
            // If dropped, prev stays the STA, so `STA / LDA / LDA` collapses.
            }
        return joinLines(out);
        }

    // ── Rule 2: JMP-to-next-label elimination ────────────────────────────
    static String* labelNameOrNull(String* line)
        {
        String* t = trimmed(line);
        if (t.byteLength() == (u32)0)
            return (String*)0;
        if (t.byteAt(t.byteLength() - (u32)1) != (u8)':')
            return (String*)0;
        return trimmed(t.substringBytes((u32)0, t.byteLength() - (u32)1));
        }

    static String* jmpToNextLabel(String* text)
        {
        Array* lines = splitLines(text);
        u32 n = lines.count();
        Array* drop = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            drop.add((Object*)Number.with((u32)0));
        bool any = false;
        for (u32 i = (u32)0; i + (u32)1 < n; i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            if (classify(line) != (u8)LK_INSN)
                continue;
            if (!eq(opOf(line), "JMP"))
                continue;
            String* operand = operandOf(line);
            u32 j = i + (u32)1;
            while (j < n)
                {
                u8 k = classify((String*)lines.get(j));
                if (k == (u8)LK_BLANK || k == (u8)LK_COMMENT)
                    {
                    j = j + (u32)1;
                    continue;
                    }
                break;
                }
            if (j >= n)
                break;
            String* label = labelNameOrNull((String*)lines.get(j));
            if (label != (String*)0 && label.equals(operand))
                {
                drop.set(i, (Object*)Number.with((u32)1));
                any = true;
                }
            }
        if (!any)
            return text;
        Array* out = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (((Number*)drop.get(i)).asU32() == (u32)0)
                out.add(lines.get(i));
        return joinLines(out);
        }

    // ── Rule 4: duplicate consecutive store elimination ──────────────────
    static String* duplicateStore(String* text)
        {
        Array* lines = splitLines(text);
        Array* out = new Array();
        String* prevTrim = (String*)0;
        bool prevWasStore = false;
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            u8 k = classify(line);
            if (k != (u8)LK_INSN)
                {
                out.add((Object*)line);
                prevTrim = (String*)0;
                prevWasStore = false;
                continue;
                }
            String* op = opOf(line);
            bool isStore = isStoreOp(op);
            String* t = trimmed(line);
            if (isStore && prevWasStore && prevTrim != (String*)0 && t.equals(prevTrim))
                continue; // identical consecutive store
            out.add((Object*)line);
            prevTrim = t;
            prevWasStore = isStore;
            }
        return joinLines(out);
        }

    // ── Rule 5: constant-immediate fold into CMP/ADC/SBC ─────────────────
    //
    //   LDA #$<imm> / STA <slot> / LDA <other> / CMP <slot>
    //     ->          LDA <other> / CMP #$<imm>
    //
    // Gated on the slot being a ONE-SHOT: exactly two operand mentions in the
    // whole text (the store and the single consumer). Without that gate a
    // const fold elsewhere can shift the slot layout so this matches a slot
    // something else still reads, which miscompiled a signed 16-bit compare
    // into an infinite loop.
    static String* constFold(String* text)
        {
        Array* lines = splitLines(text);
        u32 n = lines.count();
        Map* uses = new Map();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            if (classify(line) != (u8)LK_INSN)
                continue;
            String* od = operandOf(line);
            if (od.byteLength() == (u32)0)
                continue;
            Object* c = uses.get((Hashable*)od);
            u32 v = c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
            uses.set((Hashable*)od, (Object*)Number.with(v + (u32)1));
            }
        Array* drop = new Array();
        Array* rewrite = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            drop.add((Object*)Number.with((u32)0));
            rewrite.add((Object*)0);
            }
        bool any = false;
        for (u32 i = (u32)0; i + (u32)3 < n; i = i + (u32)1)
            {
            if (classify((String*)lines.get(i)) != (u8)LK_INSN)
                continue;
            if (classify((String*)lines.get(i + (u32)1)) != (u8)LK_INSN)
                continue;
            if (classify((String*)lines.get(i + (u32)2)) != (u8)LK_INSN)
                continue;
            if (classify((String*)lines.get(i + (u32)3)) != (u8)LK_INSN)
                continue;
            String* op0 = opOf((String*)lines.get(i));
            String* od0 = operandOf((String*)lines.get(i));
            String* op1 = opOf((String*)lines.get(i + (u32)1));
            String* od1 = operandOf((String*)lines.get(i + (u32)1));
            String* op2 = opOf((String*)lines.get(i + (u32)2));
            String* od2 = operandOf((String*)lines.get(i + (u32)2));
            String* op3 = opOf((String*)lines.get(i + (u32)3));
            String* od3 = operandOf((String*)lines.get(i + (u32)3));
            if (!eq(op0, "LDA"))
                continue;
            if (!od0.hasPrefix(String.withCString("#$")))
                continue;
            if (!eq(op1, "STA"))
                continue;
            if (!eq(op2, "LDA"))
                continue;
            if (od2.equals(od1))
                continue; // reloads the slot: still live
            if (!eq(op3, "CMP") && !eq(op3, "ADC") && !eq(op3, "SBC"))
                continue;
            if (!od3.equals(od1))
                continue; // must consume the slot
            Object* c = uses.get((Hashable*)od1);
            if (c == (Object*)0 || ((Number*)c).asU32() != (u32)2)
                continue;
            drop.set(i, (Object*)Number.with((u32)1));
            drop.set(i + (u32)1, (Object*)Number.with((u32)1));
            String* r = String.withCString("    ");
            r.append(op3);
            r.appendCString(" ");
            r.append(od0);
            rewrite.set(i + (u32)3, (Object*)r);
            any = true;
            }
        if (!any)
            return text;
        Array* out = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            if (((Number*)drop.get(i)).asU32() != (u32)0)
                continue;
            Object* r = rewrite.get(i);
            out.add(r != (Object*)0 ? r : lines.get(i));
            }
        return joinLines(out);
        }

    // ── Rule: dead SP-frame store elimination ────────────────────────────
    //
    // A store to +N,SP is dead when a later store OVERWRITES the identical
    // operand with no intervening reference. The scan stops at any label,
    // branch, call or SP-changing op: past one of those the slot could be read
    // on a path we cannot see, or +N,SP could name a different byte.
    static i32 spDirectOffset(String* operand)
        {
        if (!operand.hasPrefix(String.withCString("+")))
            return (i32)-1;
        if (operand.byteLength() <= (u32)4)
            return (i32)-1;
        u32 L = operand.byteLength();
        if (operand.byteAt(L - (u32)3) != (u8)',' || operand.byteAt(L - (u32)2) != (u8)'S' || operand.byteAt(L - (u32)1) != (u8)'P')
            return (i32)-1;
        return parseDec(operand.substringBytes((u32)1, L - (u32)4));
        }

    // "(+M,SP),Y" / "(+M,SP)" -> M
    static i32 spIndirectBase(String* operand)
        {
        if (!operand.hasPrefix(String.withCString("(+")))
            return (i32)-1;
        u32 at = operand.byteIndexOf(String.withCString(",SP)"));
        if (at == (u32)$FFFF_FFFF || at <= (u32)2)
            return (i32)-1;
        return parseDec(operand.substringBytes((u32)2, at - (u32)2));
        }

    static i32 parseDec(String* s)
        {
        if (s.byteLength() == (u32)0)
            return (i32)-1;
        i32 v = (i32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (i32)-1;
            v = v * (i32)10 + (i32)((u32)c - (u32)'0');
            }
        return v;
        }

    static String* deadStore(String* text)
        {
        Array* lines = splitLines(text);
        u32 n = lines.count();
        Array* drop = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            drop.add((Object*)Number.with((u32)0));
        bool any = false;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            if (classify(line) != (u8)LK_INSN)
                continue;
            String* op = opOf(line);
            if (!isStoreOp(op))
                continue;
            String* s = operandOf(line);
            i32 ns = spDirectOffset(s);
            if (ns < (i32)0)
                continue;
            bool dead = false;
            for (u32 j = i + (u32)1; j < n; j = j + (u32)1)
                {
                u8 kk = classify((String*)lines.get(j));
                if (kk == (u8)LK_BLANK || kk == (u8)LK_COMMENT)
                    continue;
                if (kk != (u8)LK_INSN)
                    break; // label / directive
                String* jop = opOf((String*)lines.get(j));
                String* jod = operandOf((String*)lines.get(j));
                // An SP-indirect deref reads the WHOLE 3-byte pointer (lo M,
                // hi M+1, bank M+2) though the operand only names +M,SP — so
                // if our slot is any of those three it is LIVE. `STA +8,SP`
                // then `LDA (+7,SP),Y` reads +8 as the pointer's high byte.
                i32 ib = spIndirectBase(jod);
                if (ib >= (i32)0)
                    {
                    if (ns >= ib && ns <= ib + (i32)2)
                        break;
                    continue;
                    }
                if (isStoreOp(jop) && jod.equals(s))
                    {
                    dead = true;
                    break;
                    }
                if (jod.byteIndexOf(s) != (u32)$FFFF_FFFF)
                    break; // read / RMW
                if (isBarrier(jop))
                    break;
                }
            if (dead)
                {
                drop.set(i, (Object*)Number.with((u32)1));
                any = true;
                }
            }
        if (!any)
            return text;
        Array* out = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (((Number*)drop.get(i)).asU32() == (u32)0)
                out.add(lines.get(i));
        return joinLines(out);
        }

    // ── Rule 3: ICmp + CondBranch fusion ─────────────────────────────────
    //
    // The back end materialises a compare's boolean into a slot and then tests
    // it. The tail has a regular shape:
    //
    //   LDA #$<X> / BRA .Licmp<N>_store / .Licmp<N>_<KIND>: / LDA #$<Y>
    //   .Licmp<N>_store: / STA <slot> / BEQ .Lcbsk_<M> / JMP <true>
    //   .Lcbsk_<M>: / JMP <false>
    //
    // "flip": the labelled branches produce 0; "set": they produce 1. Either
    // way the inner conditional branches are retargeted at the right side and
    // the whole tail collapses to one JMP. Branches to .Licmp<N>_done are the
    // multi-word compare's own merge point and are LEFT ALONE.
    static String* icmpBranchFusion(String* text)
        {
        Array* lines = splitLines(text);
        u32 n = lines.count();
        Array* drop = new Array();
        Array* rewrite = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            drop.add((Object*)Number.with((u32)0));
            rewrite.add((Object*)0);
            }
        bool any = false;
        for (u32 i = (u32)0; i + (u32)6 < n; i = i + (u32)1)
            {
            String* t = trimmed((String*)lines.get(i));
            String* nidx = storeLabelIndex(t);
            if (nidx == (String*)0)
                continue;
            if (i < (u32)4)
                continue;

            String* flipLabel = labelFor(nidx, "_flip:");
            String* setLabel = labelFor(nidx, "_set:");
            String* flipRef = labelFor(nidx, "_flip");
            String* setRef = labelFor(nidx, "_set");
            String* storeRef = labelFor(nidx, "_store");

            String* la0 = trimmed((String*)lines.get(i - (u32)4));
            String* bra = trimmed((String*)lines.get(i - (u32)3));
            String* kind = trimmed((String*)lines.get(i - (u32)2));
            String* la1 = trimmed((String*)lines.get(i - (u32)1));

            bool isFlip = kind.equals(flipLabel);
            bool isSet = kind.equals(setLabel);
            if (!isFlip && !isSet)
                continue;
            String* wantBra = String.withCString("BRA ");
            wantBra.append(storeRef);
            if (!bra.equals(wantBra))
                continue;

            i32 firstVal = (i32)-1;
            i32 secondVal = (i32)-1;
            if (eq(la0, "LDA #$00"))
                firstVal = (i32)0;
            else if (eq(la0, "LDA #$01"))
                firstVal = (i32)1;
            if (eq(la1, "LDA #$00"))
                secondVal = (i32)0;
            else if (eq(la1, "LDA #$01"))
                secondVal = (i32)1;
            if (firstVal < (i32)0 || secondVal < (i32)0 || firstVal == secondVal)
                continue;

            if (i + (u32)5 >= n)
                continue;
            String* staLine = trimmed((String*)lines.get(i + (u32)1));
            String* beqLine = trimmed((String*)lines.get(i + (u32)2));
            String* jmpT = trimmed((String*)lines.get(i + (u32)3));
            String* cbskLbl = trimmed((String*)lines.get(i + (u32)4));
            String* jmpF = trimmed((String*)lines.get(i + (u32)5));

            if (!staLine.hasPrefix(String.withCString("STA ")))
                continue;
            if (!beqLine.hasPrefix(String.withCString("BEQ .Lcbsk_")))
                continue;
            if (!jmpT.hasPrefix(String.withCString("JMP ")))
                continue;
            if (!jmpF.hasPrefix(String.withCString("JMP ")))
                continue;

            String* cbskName = beqLine.substringFromByte((u32)4);
            String* wantLbl = String.withString(cbskName);
            wantLbl.appendCString(":");
            if (!cbskLbl.equals(wantLbl))
                continue;

            String* trueTarget = trimmed(jmpT.substringFromByte((u32)4));
            String* falseTarget = trimmed(jmpF.substringFromByte((u32)4));

            bool canonicalFlip = isFlip && secondVal == (i32)0 && firstVal == (i32)1;
            bool canonicalSet = isSet && secondVal == (i32)1 && firstVal == (i32)0;
            if (!canonicalFlip && !canonicalSet)
                continue;

            String* condTarget = canonicalFlip ? falseTarget : trueTarget;
            String* keptJmpTarget = canonicalFlip ? trueTarget : falseTarget;
            String* labelRetarget = canonicalFlip ? flipRef : setRef;

            Array* branchIdx = new Array();
            bool anyMatch = false;
            i32 j = (i32)i - (i32)5;
            while (j >= (i32)0)
                {
                String* raw = (String*)lines.get((u32)j);
                u8 k = classify(raw);
                if (k == (u8)LK_BLANK || k == (u8)LK_COMMENT)
                    {
                    j = j - (i32)1;
                    continue;
                    }
                if (k != (u8)LK_INSN)
                    break;
                String* op = opOf(raw);
                String* od = operandOf(raw);
                if (isCondBranch(op))
                    {
                    if (od.equals(labelRetarget))
                        {
                        branchIdx.add((Object*)Number.with((u32)j));
                        anyMatch = true;
                        }
                    j = j - (i32)1;
                    continue;
                    }
                // The compare's own logic sits above the tail; step over it.
                if (eq(op, "CMP") || eq(op, "LDA") || eq(op, "STA") || eq(op, "LDX") || eq(op, "LDY"))
                    {
                    j = j - (i32)1;
                    continue;
                    }
                break;
                }
            if (!anyMatch)
                continue;

            for (u32 b = (u32)0; b < branchIdx.count(); b = b + (u32)1)
                {
                u32 li = ((Number*)branchIdx.get(b)).asU32();
                String* raw = (String*)lines.get(li);
                String* r = String.withCString("    ");
                r.append(opOf(raw));
                r.appendCString(" ");
                r.append(condTarget);
                rewrite.set(li, (Object*)r);
                }
            for (u32 d = i - (u32)4; d <= i + (u32)5; d = d + (u32)1)
                drop.set(d, (Object*)Number.with((u32)1));
            String* jr = String.withCString("    JMP ");
            jr.append(keptJmpTarget);
            rewrite.set(i + (u32)5, (Object*)jr);
            drop.set(i + (u32)5, (Object*)Number.with((u32)0)); // keep for the JMP
            any = true;
            }
        if (!any)
            return text;
        Array* out = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            if (((Number*)drop.get(i)).asU32() != (u32)0)
                continue;
            Object* r = rewrite.get(i);
            out.add(r != (Object*)0 ? r : lines.get(i));
            }
        return joinLines(out);
        }

    // `.Licmp<N>_store:` -> "<N>", else null.
    static String* storeLabelIndex(String* t)
        {
        String* pre = String.withCString(".Licmp");
        if (!t.hasPrefix(pre))
            return (String*)0;
        String* suf = String.withCString("_store:");
        u32 at = t.byteIndexOf(suf);
        if (at == (u32)$FFFF_FFFF)
            return (String*)0;
        if (at + suf.byteLength() != t.byteLength())
            return (String*)0;
        u32 from = pre.byteLength();
        if (at <= from)
            return (String*)0;
        String* digits = t.substringBytes(from, at - from);
        for (u32 i = (u32)0; i < digits.byteLength(); i = i + (u32)1)
            {
            u8 c = digits.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (String*)0;
            }
        return digits;
        }

    static String* labelFor(String* nidx, string suffix)
        {
        String* s = String.withCString(".Licmp");
        s.append(nidx);
        s.appendCString(suffix);
        return s;
        }

    // ── entry ────────────────────────────────────────────────────────────
    //
    // Iterate to a fixed point: rule 2 can put a STA and its reload next to
    // each other across what used to be a block boundary, and rule 1 can
    // expose a JMP-to-next-label in turn. Capped at 8 hops, as the original.
    static String* optimise(String* asmText, u32 level)
        {
        if (level == (u32)0 || asmText.byteLength() == (u32)0)
            return asmText;
        String* cur = asmText;
        for (u32 hop = (u32)0; hop < (u32)8; hop = hop + (u32)1)
            {
            String* prev = cur;
            cur = icmpBranchFusion(cur);
            cur = constFold(cur);
            cur = redundantReload(cur);
            cur = duplicateStore(cur);
            cur = deadStore(cur);
            cur = jmpToNextLabel(cur);
            if (cur.equals(prev))
                break;
            }
        return cur;
        }
    }
