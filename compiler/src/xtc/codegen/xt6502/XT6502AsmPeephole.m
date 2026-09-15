#import "XT6502AsmPeephole.h"

// ─────────────────────────────────────────────────────────────────────
// Helpers — line-level tokenisation.
//
// We treat each `\n`-separated line as either:
//   - blank
//   - a comment (`;` prefix after optional whitespace)
//   - a label   (`<name>:` at column 0, no leading whitespace)
//   - an instruction (`    OP arg, arg2`)
//
// Rules can read this classification to decide whether two adjacent
// instructions can be fused without crossing a label or directive
// boundary.
// ─────────────────────────────────────────────────────────────────────

typedef NS_ENUM(uint8_t, XTLineKind) {
    XTLineBlank,
    XTLineComment,
    XTLineLabel,
    XTLineInsn,
    XTLineDirective, // .org, .bank, .byte, .include, etc.
};

static XTLineKind classifyLine(NSString* line)
    {
    NSString* trim = [line stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
    if (trim.length == 0)
        return XTLineBlank;
    if ([trim hasPrefix:@";"])
        return XTLineComment;
    if ([trim hasPrefix:@"."])
        return XTLineDirective;
    // Label: name followed by ':' at end of trimmed line, no leading
    // whitespace on the original line. Also accept `name = expr`.
    if (![line hasPrefix:@" "] && ![line hasPrefix:@"\t"])
        {
        if ([trim hasSuffix:@":"] || [trim containsString:@"="])
            return XTLineLabel;
        }
    return XTLineInsn;
    }

// Extract the opcode (first token) and the operand text (rest of the
// line) from an instruction line. Operand may be empty.
static void splitInsn(NSString* line, NSString** outOp, NSString** outOperand)
    {
    NSString* trim = [line stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
    NSRange spc = [trim rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (spc.location == NSNotFound)
        {
        *outOp = trim;
        *outOperand = @"";
        return;
        }
    *outOp = [trim substringToIndex:spc.location];
    *outOperand = [[trim substringFromIndex:spc.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule 1: redundant reload elimination.
//
//     STA +N,SP
//     LDA +N,SP    ← A still holds the just-stored value; drop this
//
// Also covers STA <addr> / LDA <addr> in zero-page and absolute modes,
// since the new backend's "spill global" path emits those for static
// data. The discriminator is that the operand matches verbatim.
//
// Safety: the LDA updates Z/N, and STA/STX/STY do NOT. So a reload load
// immediately before a flag-reading conditional branch (BEQ/BNE/BMI/BPL)
// supplies the flags that branch tests — dropping it would leave the
// branch reading whatever set the register earlier. The ICmp+CondBranch
// boolean tail (`STA slot / LDA slot / BEQ`) is exactly that shape, so we
// look ahead and keep the load when the next real instruction is such a
// branch. (Constant-operand folding can expose this by reshaping the
// surrounding code; before the guard it miscompiled a loop bound into an
// infinite loop — see phase-248.)
//
// Both forms also apply to LDX/LDY after STX/STY, when used in the
// same dst-then-reload pattern. The new backend uses them for the
// loop-index slot of for-in and the Y-side of (+d,SP),Y indirection.
// ─────────────────────────────────────────────────────────────────────

static NSString* applyRedundantReload(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSUInteger n = lines.count;
    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:n];
    NSString* prevOp = nil;
    NSString* prevOperand = nil;
    XTLineKind prevKind = XTLineBlank;
    // Conditional branches that read the Z/N flags a load sets. A reload
    // LDA/LDX/LDY immediately before one of these supplies the flags it
    // tests — it must NOT be dropped, because STA/STX/STY don't touch Z/N,
    // so removing the load would leave the branch reading whatever set the
    // register earlier (e.g. the ICmp+CondBranch boolean tail's `STA slot /
    // LDA slot / BEQ` — dropping the LDA made BEQ test a stale flag and
    // miscompiled a loop bound into an infinite loop).
    NSSet<NSString*>* flagBranch =
        [NSSet setWithArray:@[ @"BEQ", @"BNE", @"BMI", @"BPL" ]];
    // Ops that touch only the processor flags — never A/X/Y, never memory.
    // They sit transparently between a `STA s` and its reload `LDA s`
    // (a dependent arithmetic chain emits `STA s / CLC / LDA s / ADC …`),
    // so passing them through WITHOUT advancing the prev-tracker lets the
    // reload still be recognised as redundant. Safe because none of them
    // reload the register or rewrite s, so A still holds s at the LDA, and
    // the dropped LDA's only effect (setting Z/N) is still guarded below.
    NSSet<NSString*>* flagOnly =
        [NSSet setWithArray:@[ @"CLC", @"SEC", @"CLD", @"SED",
                               @"CLV", @"CLI", @"SEI", @"NOP" ]];
    for (NSUInteger i = 0; i < n; i++)
        {
        NSString* line = lines[i];
        XTLineKind k = classifyLine(line);
        if (k == XTLineInsn)
            {
            NSString *op = nil, *operand = nil;
            splitInsn(line, &op, &operand);
            if ([flagOnly containsObject:op])
                {
                // Transparent to the reload chain — emit, keep prev.
                [out addObject:line];
                continue;
                }
            BOOL drop = NO;
            if (prevKind == XTLineInsn && prevOperand && operand.length > 0 &&
                [operand isEqualToString:prevOperand])
                {
                if (([prevOp isEqualToString:@"STA"] && [op isEqualToString:@"LDA"]) ||
                    ([prevOp isEqualToString:@"STX"] && [op isEqualToString:@"LDX"]) ||
                    ([prevOp isEqualToString:@"STY"] && [op isEqualToString:@"LDY"]))
                    {
                    drop = YES;
                    }
                }
            // Keep the load if the next real instruction is a flag-reading
            // branch — it consumes this load's Z/N.
            if (drop)
                {
                for (NSUInteger j = i + 1; j < n; j++)
                    {
                    XTLineKind kk = classifyLine(lines[j]);
                    if (kk == XTLineBlank || kk == XTLineComment)
                        continue;
                    if (kk == XTLineInsn)
                        {
                        NSString *nop = nil, *nopd = nil;
                        splitInsn(lines[j], &nop, &nopd);
                        if ([flagBranch containsObject:nop])
                            drop = NO;
                        }
                    break;
                    }
                }
            if (!drop)
                [out addObject:line];
            // Update prev tracker. If we dropped the LDA, prev stays
            // the STA — important so a chain `STA / LDA / LDA` collapses
            // to one STA.
            if (!drop)
                {
                prevOp = op;
                prevOperand = operand;
                prevKind = k;
                }
            }
        else
            {
            [out addObject:line];
            // Labels, comments, blanks, directives break the chain
            // (a label means another control-flow path can land here
            // and the LDA might be required).
            prevOp = nil;
            prevOperand = nil;
            prevKind = k;
            }
        }
    return [out componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule 2: JMP-to-next-label elimination.
//
//     JMP target
//     target:        ← previous JMP is a no-op
//
// The new backend emits an unconditional JMP at the end of every basic
// block, even when the next block in emission order is exactly the
// jump target. legacy didn't have this problem — it tracked emission
// order. Trivial to recover at peephole level.
//
// The blank-line gap between the JMP and the label is fine — blank
// lines and pure comments don't break the pattern. Any other content
// (instruction, directive) does.
// ─────────────────────────────────────────────────────────────────────

// Extract a label name from a label line ("foo:" → "foo", "foo = bar"
// returns nil since that's an equate, not a branch target).
static NSString* labelNameOrNil(NSString* line)
    {
    NSString* trim = [line stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
    if (![trim hasSuffix:@":"])
        return nil;
    NSString* name = [trim substringToIndex:trim.length - 1];
    return [name stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    }

static NSString* applyJmpToNextLabel(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i + 1 < lines.count; i++)
        {
        NSString* line = lines[i];
        if (classifyLine(line) != XTLineInsn)
            continue;
        NSString *op = nil, *operand = nil;
        splitInsn(line, &op, &operand);
        if (![op isEqualToString:@"JMP"])
            continue;
        // Scan forward for the next "real" line (skip blanks/comments).
        NSUInteger j = i + 1;
        while (j < lines.count)
            {
            XTLineKind k = classifyLine(lines[j]);
            if (k == XTLineBlank || k == XTLineComment)
                {
                j++;
                continue;
                }
            break;
            }
        if (j >= lines.count)
            break;
        NSString* label = labelNameOrNil(lines[j]);
        if (label && [label isEqualToString:operand])
            {
            [drop addIndex:i];
            }
        }
    if (drop.count == 0)
        return asmText;
    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSUInteger i = 0; i < lines.count; i++)
        {
        if (![drop containsIndex:i])
            [out addObject:lines[i]];
        }
    return [out componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule 3: ICmp + CondBranch fusion.
//
// The new backend lowers `%b = ICmp ...; CondBranch %b, T, F` as two
// independent IR ops, materialising the boolean result into a stack
// slot before the CondBranch tests it. That's ~10 wasted instructions
// per branch — and it's the single biggest reason the IR path loses
// on control-flow-heavy fixtures (loops.xc 1.77×, int_arith 1.69×).
//
// The boolean-materialisation tail has a regular shape:
//
//   [inner conditional branches that target .Licmp<N>_<KIND>]
//   LDA #$01 (or #$00)
//   BRA .Licmp<N>_store
//   .Licmp<N>_<KIND>:                  ← KIND is "flip" or "set"
//   LDA #$00 (or #$01) — opposite of the first LDA
//   .Licmp<N>_store:
//   STA <slot>
//   BEQ .Lcbsk_<M>
//   JMP <bool_true_target>
//   .Lcbsk_<M>:
//   JMP <bool_false_target>
//
// Two variants depending on what the labelled branches mean:
//   "_flip": branches set result=0 (false); fall-through is 1 (true).
//   "_set" : branches set result=1 (true);  fall-through is 0 (false).
//
// Either way, the transformation is:
//   - Retarget the inner conditional branches that pointed at
//     .Licmp<N>_<KIND> so they go to the appropriate side directly
//     ("_flip" → bool_false_target, "_set" → bool_true_target).
//   - Delete the materialisation tail entirely.
//   - Emit a single `JMP <other_side>` (the side the previous
//     fall-through would have taken).
//
// Branches that target .Licmp<N>_done (the multi-word-compare merge
// point) are LEFT ALONE — they're part of the compare's own logic.
// ─────────────────────────────────────────────────────────────────────

static NSString* applyICmpBranchFusion(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSUInteger n = lines.count;
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:n];
    NSMutableIndexSet* consumed = [NSMutableIndexSet indexSet];
    // First pass — scan for the structural anchor `.Licmp<N>_store:` and
    // check the 10-line shape both before and after. If matched, build
    // a substitution.
    //
    // Substitutions = dict of { lineIdx → replacementText }, plus a set
    // of indices to drop. We apply on a second pass.
    NSMutableDictionary<NSNumber*, NSString*>* rewrite = [NSMutableDictionary dictionary];
    NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];

    NSRegularExpression* storeLabelRe = [NSRegularExpression
        regularExpressionWithPattern:@"^\\.Licmp([0-9]+)_store:\\s*$"
                             options:0
                               error:NULL];

    for (NSUInteger i = 0; i + 6 < n; i++)
        {
        NSString* line = lines[i];
        NSTextCheckingResult* m = [storeLabelRe firstMatchInString:line
                                                           options:0
                                                             range:NSMakeRange(0, line.length)];
        if (!m)
            continue;
        NSString* nidx = [line substringWithRange:[m rangeAtIndex:1]];
        NSString* flipLabel = [NSString stringWithFormat:@".Licmp%@_flip:", nidx];
        NSString* setLabel = [NSString stringWithFormat:@".Licmp%@_set:", nidx];
        NSString* flipRef = [NSString stringWithFormat:@".Licmp%@_flip", nidx];
        NSString* setRef = [NSString stringWithFormat:@".Licmp%@_set", nidx];
        NSString* storeRef = [NSString stringWithFormat:@".Licmp%@_store", nidx];

        // BEFORE the `_store:` line, look for the 4-line:
        //   LDA #$<X>      (i-4)
        //   BRA .Licmp<N>_store    (i-3)
        //   .Licmp<N>_<KIND>:      (i-2)
        //   LDA #$<Y>      (i-1)
        //   .Licmp<N>_store:       (i)
        if (i < 4)
            continue;
        NSString* la0 = [lines[i - 4] stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
        NSString* bra = [lines[i - 3] stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
        NSString* kindLine = [lines[i - 2] stringByTrimmingCharactersInSet:
                                               [NSCharacterSet whitespaceCharacterSet]];
        NSString* la1 = [lines[i - 1] stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];

        BOOL isFlip = [kindLine isEqualToString:flipLabel];
        BOOL isSet = [kindLine isEqualToString:setLabel];
        if (!isFlip && !isSet)
            continue;
        if (![bra isEqualToString:[@"BRA " stringByAppendingString:storeRef]])
            continue;

        int firstVal = -1, secondVal = -1;
        if ([la0 isEqualToString:@"LDA #$00"])
            firstVal = 0;
        else if ([la0 isEqualToString:@"LDA #$01"])
            firstVal = 1;
        if ([la1 isEqualToString:@"LDA #$00"])
            secondVal = 0;
        else if ([la1 isEqualToString:@"LDA #$01"])
            secondVal = 1;
        if (firstVal < 0 || secondVal < 0 || firstVal == secondVal)
            continue;

        // AFTER the `_store:` line:
        //   STA <slot>            (i+1)
        //   BEQ .Lcbsk_<M>        (i+2)
        //   JMP <bool_true>       (i+3)
        //   .Lcbsk_<M>:           (i+4)
        //   JMP <bool_false>      (i+5)
        if (i + 5 >= n)
            continue;
        NSString* staLine = [lines[i + 1] stringByTrimmingCharactersInSet:
                                              [NSCharacterSet whitespaceCharacterSet]];
        NSString* beqLine = [lines[i + 2] stringByTrimmingCharactersInSet:
                                              [NSCharacterSet whitespaceCharacterSet]];
        NSString* jmpT = [lines[i + 3] stringByTrimmingCharactersInSet:
                                           [NSCharacterSet whitespaceCharacterSet]];
        NSString* cbskLabelLine = [lines[i + 4] stringByTrimmingCharactersInSet:
                                                    [NSCharacterSet whitespaceCharacterSet]];
        NSString* jmpF = [lines[i + 5] stringByTrimmingCharactersInSet:
                                           [NSCharacterSet whitespaceCharacterSet]];

        if (![staLine hasPrefix:@"STA "])
            continue;
        if (![beqLine hasPrefix:@"BEQ .Lcbsk_"])
            continue;
        if (![jmpT hasPrefix:@"JMP "])
            continue;
        if (![jmpF hasPrefix:@"JMP "])
            continue;

        NSString* cbskName = [beqLine substringFromIndex:4]; // ".Lcbsk_<M>"
        if (![cbskLabelLine isEqualToString:
                                [cbskName stringByAppendingString:@":"]])
            continue;

        NSString* trueTarget = [[jmpT substringFromIndex:4]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* falseTarget = [[jmpF substringFromIndex:4]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Decide rewrites.
        // Flip: labelled branch sets result=0 (false). The labelled
        // label's LDA is #$00 (i.e. la1 == 0 when kind == flip, or la0 == 0
        // when... wait, kind is at i-2, la1 is at i-1, which is the LDA
        // INSIDE the labelled block. So la1's value is what the labelled
        // branch produces.
        //   kind == flip + la1 == 0 + la0 == 1 → flip pattern ✓
        //   kind == set  + la1 == 1 + la0 == 0 → set pattern ✓
        // Anything else is inconsistent — skip to stay safe.
        BOOL canonicalFlip = isFlip && secondVal == 0 && firstVal == 1;
        BOOL canonicalSet = isSet && secondVal == 1 && firstVal == 0;
        if (!canonicalFlip && !canonicalSet)
            continue;

        NSString* condTarget = canonicalFlip ? falseTarget : trueTarget;
        NSString* keptJmpTarget = canonicalFlip ? trueTarget : falseTarget;
        NSString* labelToRetarget = canonicalFlip ? flipRef : setRef;

        // Walk backward from i-4 (the first LDA of the materialisation
        // tail) and rewrite branches that target labelToRetarget. Stop
        // at: any label, any unconditional jump, any non-branch
        // instruction, or `_done:` for THIS comparison (the multi-byte
        // compare merge point). Branches we care about are BCC/BCS/BEQ/
        // BNE/BMI/BPL/BVC/BVS.
        NSMutableArray<NSNumber*>* branchIdx = [NSMutableArray array];
        NSInteger j = (NSInteger)i - 5;
        BOOL anyMatch = NO;
        while (j >= 0)
            {
            NSString* raw = lines[j];
            XTLineKind k = classifyLine(raw);
            if (k == XTLineBlank || k == XTLineComment)
                {
                j--;
                continue;
                }
            if (k != XTLineInsn)
                break;
            NSString *op = nil, *operand = nil;
            splitInsn(raw, &op, &operand);
            NSSet* condOps = [NSSet setWithArray:@[
                @"BCC", @"BCS", @"BEQ", @"BNE", @"BMI", @"BPL", @"BVC", @"BVS"
            ]];
            if ([condOps containsObject:op])
                {
                if ([operand isEqualToString:labelToRetarget])
                    {
                    [branchIdx addObject:@(j)];
                    anyMatch = YES;
                    }
                j--;
                continue;
                }
            // Stop at first non-conditional-branch instruction (CMP,
            // LDA, STA, etc. that lives ABOVE the materialisation tail
            // are part of the compare's own logic).
            if ([op isEqualToString:@"CMP"] || [op isEqualToString:@"LDA"] ||
                [op isEqualToString:@"STA"] || [op isEqualToString:@"LDX"] ||
                [op isEqualToString:@"LDY"])
                {
                j--;
                continue;
                }
            break;
            }
        if (!anyMatch)
            continue;

        // All checks passed — commit the rewrite.
        for (NSNumber* bi in branchIdx)
            {
            NSUInteger li = bi.unsignedIntegerValue;
            NSString* raw = lines[li];
            NSString *op = nil, *operand = nil;
            splitInsn(raw, &op, &operand);
            NSString* replaced = [NSString stringWithFormat:@"    %@ %@", op, condTarget];
            rewrite[@(li)] = replaced;
            }
        // Drop the materialisation tail from i-4 through i+5 inclusive.
        for (NSUInteger d = i - 4; d <= i + 5; d++)
            {
            [drop addIndex:d];
            [consumed addIndex:d];
            }
        // Insert a single JMP to the kept target. We attach it as a
        // synthetic replacement on i+5 so the line index is preserved.
        rewrite[@(i + 5)] = [NSString stringWithFormat:@"    JMP %@", keptJmpTarget];
        [drop removeIndex:i + 5]; // keep this slot for the JMP
        }

    if (rewrite.count == 0 && drop.count == 0)
        return asmText;

    for (NSUInteger i = 0; i < n; i++)
        {
        if ([drop containsIndex:i])
            continue;
        NSString* r = rewrite[@(i)];
        [result addObject:r ?: lines[i]];
        }
    return [result componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule 4: duplicate consecutive store elimination.
//
//     STA +N,SP        STA +N,SP
//     STA +N,SP   →    (dropped — same operand, A unchanged)
//
// The backend emits this when the register allocator gave two adjacent
// SSA values the same stack slot (typical for a Sub result feeding a
// Phi whose slot coincides). The second STA writes the same byte back
// to the same address with no intervening A modification — pure waste.
// Same logic for STX/STY consecutive duplicates.
//
// Safety: STA / STX / STY don't change flags or A/X/Y; consecutive
// duplicates have identical observable effect to one. The "no
// intervening modification" check is implicit — we only fire when
// the next non-blank/non-comment line is the exact same store
// instruction.
// ─────────────────────────────────────────────────────────────────────

static NSString* applyDuplicateStore(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:lines.count];
    NSString* prevTrim = nil;
    BOOL prevWasStore = NO;
    for (NSString* line in lines)
        {
        XTLineKind k = classifyLine(line);
        if (k == XTLineInsn)
            {
            NSString *op = nil, *operand = nil;
            splitInsn(line, &op, &operand);
            BOOL isStore = [op isEqualToString:@"STA"] || [op isEqualToString:@"STX"] || [op isEqualToString:@"STY"];
            NSString* trim = [line stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
            if (isStore && prevWasStore && [trim isEqualToString:prevTrim])
                {
                continue; // duplicate — drop
                }
            [out addObject:line];
            prevTrim = trim;
            prevWasStore = isStore;
            }
        else
            {
            [out addObject:line];
            // Labels and directives reset the chain. Blank/comment lines
            // also break the "consecutive" requirement to stay safe.
            prevTrim = nil;
            prevWasStore = NO;
            }
        }
    return [out componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule 5: constant-immediate fold into CMP/ADC/SBC.
//
// The backend lowers a const-typed IR operand by emitting:
//     LDA #$<imm>
//     STA <slot>
// and the comparison/arithmetic then reads the value back from <slot>:
//     LDA <other>
//     CMP <slot>     ← could just be CMP #$<imm>
//
// When the slot's ONLY use between the storing STA and a single
// CMP/ADC/SBC reference is that one read, the slot is a one-shot
// scratch and the literal can be folded directly into the CMP/ADC/SBC.
//
// Conservative shape we match here:
//
//   LDA #$<imm>            (anchor1, "the literal load")
//   STA <slot>             (anchor2, "the spill")
//   <one or more lines that DO NOT touch <slot> AND DO NOT clobber A
//    in a way that would change the original LDA's value … but the next
//    CMP/ADC/SBC uses a DIFFERENT operand anyway, so the LDA chain
//    ending at <other> is fine>
//   LDA <other>            (anchor3, "load the LHS")
//   <CMP|ADC|SBC> <slot>   (anchor4, "the immediate consumer") → fold
//
// Simplified: walk through the asm and find the 4-line tight pattern:
//   LDA #$<imm>
//   STA <slot>
//   LDA <other>
//   <CMP|ADC|SBC> <slot>
//
// Rewrite to:
//   LDA <other>
//   <CMP|ADC|SBC> #$<imm>
//
// 4 instructions → 2. The conservative tight version misses cases where
// other code sits between STA and LDA, but the new-IR backend emits
// them adjacent for ICmp/Add/Sub. Bigger fold windows can come later.
//
// Safety: the fold preserves Z/N/C flags after the comparison (CMP #X
// and CMP <slot containing X> produce identical flags) and A value
// (CMP doesn't change A; the LDA <other> is the same).
// ─────────────────────────────────────────────────────────────────────

static NSString* applyConstFold(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSUInteger n = lines.count;
    NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSNumber*, NSString*>* rewrite = [NSMutableDictionary dictionary];

    // How many instruction lines reference each operand string. Dropping the
    // `STA <slot>` is only safe when the slot's value is consumed exactly
    // once — by the CMP/ADC/SBC at i+3. If the same slot is read anywhere
    // else (e.g. the backend copies a multi-byte compare's constant to a
    // second slot, so the const slot is also read by that copy), removing
    // its store leaves the other reader with garbage. So gate the fold on
    // the slot appearing exactly twice in the whole function: the store and
    // the one consumer. (A const-operand fold elsewhere can shift the slot
    // layout so this pattern matches a non-one-shot slot — without this
    // check that miscompiled a signed 16-bit compare into an infinite loop.)
    NSCountedSet<NSString*>* opUses = [NSCountedSet set];
    for (NSString* line in lines)
        {
        if (classifyLine(line) != XTLineInsn)
            continue;
        NSString *o = nil, *od = nil;
        splitInsn(line, &o, &od);
        if (od.length)
            [opUses addObject:od];
        }

    for (NSUInteger i = 0; i + 3 < n; i++)
        {
        if (classifyLine(lines[i]) != XTLineInsn)
            continue;
        if (classifyLine(lines[i + 1]) != XTLineInsn)
            continue;
        if (classifyLine(lines[i + 2]) != XTLineInsn)
            continue;
        if (classifyLine(lines[i + 3]) != XTLineInsn)
            continue;

        NSString *op0 = nil, *opd0 = nil, *op1 = nil, *opd1 = nil, *op2 = nil, *opd2 = nil, *op3 = nil, *opd3 = nil;
        splitInsn(lines[i], &op0, &opd0);
        splitInsn(lines[i + 1], &op1, &opd1);
        splitInsn(lines[i + 2], &op2, &opd2);
        splitInsn(lines[i + 3], &op3, &opd3);

        if (![op0 isEqualToString:@"LDA"])
            continue;
        if (![opd0 hasPrefix:@"#$"])
            continue;
        if (![op1 isEqualToString:@"STA"])
            continue;
        if (![op2 isEqualToString:@"LDA"])
            continue;
        // Don't fold if the LDA at i+2 reloads the same slot — that
        // means the value is still being used through the slot.
        if ([opd2 isEqualToString:opd1])
            continue;
        if (![op3 isEqualToString:@"CMP"] &&
            ![op3 isEqualToString:@"ADC"] &&
            ![op3 isEqualToString:@"SBC"])
            continue;
        if (![opd3 isEqualToString:opd1])
            continue; // must consume the slot
        // The slot must be a one-shot: written here, read only at i+3.
        // opd1 appears at i+1 (STA) and i+3 (consume) = 2 uses; any more
        // means another instruction reads the slot, so dropping the store
        // would corrupt it.
        if ([opUses countForObject:opd1] != 2)
            continue;

        // Match. Drop the two anchor lines and rewrite the last to
        // immediate form. Keep the LDA <other>.
        [drop addIndex:i];     // LDA #$<imm>
        [drop addIndex:i + 1]; // STA <slot>
        // i+2: LDA <other> — keep
        // i+3: rewrite to CMP/ADC/SBC #$<imm>
        rewrite[@(i + 3)] = [NSString stringWithFormat:@"    %@ %@", op3, opd0];
        }

    if (drop.count == 0)
        return asmText;

    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
        {
        if ([drop containsIndex:i])
            continue;
        NSString* r = rewrite[@(i)];
        [out addObject:r ?: lines[i]];
        }
    return [out componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────
// Rule: dead SP-frame store elimination.
//
//     STA +N,SP        ← dead: overwritten before any read
//     ... (no read of +N,SP, no branch/call/SP-change) ...
//     STA +N,SP        ← overwrite
//
// A dependent arithmetic chain leaves each intermediate in A and rule 1
// drops the reloads (`STA s / CLC / LDA s` → `STA s / CLC`), so the STA
// that spilled it is now dead. Only SP-frame slots (+N,SP), only within a
// straight-line run: the scan stops at any label / branch / call / SP-
// changing op, because past one of those the slot could be read on a path
// we can't see, or `+N,SP` could name a different byte at a shifted spDelta.
//
// Safety: we declare a store dead only when a later store OVERWRITES the
// identical operand with NO intervening reference to it (an exact-match
// reload `LDA +N,SP`, an RMW `INC +N,SP`, or an indirect `(+N,SP),Y` all
// count as references — `containsString` catches them, and the comma in
// `+N,SP` keeps `+7,SP` from matching inside `+17,SP`). Pure stores STA /
// STX / STY with the identical operand are the only overwrites.
// ─────────────────────────────────────────────────────────────────────

// Parse a direct SP-frame operand "+N,SP" → N, else -1.
static NSInteger spDirectOffset(NSString* operand)
    {
    if (![operand hasPrefix:@"+"] || ![operand hasSuffix:@",SP"])
        return -1;
    if (operand.length <= 4)
        return -1;
    NSString* num = [operand substringWithRange:NSMakeRange(1, operand.length - 4)];
    NSScanner* sc = [NSScanner scannerWithString:num];
    NSInteger v = 0;
    if (![sc scanInteger:&v] || !sc.isAtEnd)
        return -1;
    return v;
    }

// Parse an SP-indirect operand "(+M,SP),Y" / "(+M,SP)" → M, else -1.
static NSInteger spIndirectBase(NSString* operand)
    {
    if (![operand hasPrefix:@"(+"])
        return -1;
    NSRange tail = [operand rangeOfString:@",SP)"];
    if (tail.location == NSNotFound || tail.location <= 2)
        return -1;
    NSString* num = [operand substringWithRange:NSMakeRange(2, tail.location - 2)];
    NSScanner* sc = [NSScanner scannerWithString:num];
    NSInteger v = 0;
    if (![sc scanInteger:&v] || !sc.isAtEnd)
        return -1;
    return v;
    }

static NSString* applyDeadStore(NSString* asmText)
    {
    NSArray<NSString*>* lines = [asmText componentsSeparatedByString:@"\n"];
    NSUInteger n = lines.count;
    NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
    NSSet<NSString*>* storeOps =
        [NSSet setWithArray:@[ @"STA", @"STX", @"STY" ]];
    // Ops that end the straight-line run: control flow, or anything that
    // moves SP (so a later +N,SP names a different byte).
    NSSet<NSString*>* barrierOps = [NSSet setWithArray:@[
        @"JMP", @"JSR", @"RTS", @"RTI", @"BRK",
        @"BEQ", @"BNE", @"BMI", @"BPL", @"BCC", @"BCS", @"BVC", @"BVS", @"BRA",
        @"PHA", @"PLA", @"PSH", @"PLL", @"TXS", @"TSX", @"ADD"
    ]];
    for (NSUInteger i = 0; i < n; i++)
        {
        if (classifyLine(lines[i]) != XTLineInsn)
            continue;
        NSString *op = nil, *operand = nil;
        splitInsn(lines[i], &op, &operand);
        if (![storeOps containsObject:op])
            continue;
        NSInteger ns = spDirectOffset(operand);
        if (ns < 0)
            continue;
        NSString* s = operand;
        BOOL dead = NO;
        for (NSUInteger j = i + 1; j < n; j++)
            {
            XTLineKind kk = classifyLine(lines[j]);
            if (kk == XTLineBlank || kk == XTLineComment)
                continue;
            if (kk != XTLineInsn)
                break; // label / directive = barrier
            NSString *jop = nil, *jod = nil;
            splitInsn(lines[j], &jop, &jod);
            // An SP-indirect deref `(+M,SP),Y` reads the WHOLE 3-byte
            // pointer (lo M, hi M+1, bank M+2) even though the operand
            // string only names +M,SP — so if our slot is any of those
            // three bytes it's live. (This was the bug: `STA +8,SP` then
            // `LDA (+7,SP),Y` reads +8 as the pointer's hi byte.)
            NSInteger ib = spIndirectBase(jod);
            if (ib >= 0)
                {
                if (ns >= ib && ns <= ib + 2)
                    break; // part of the pointer = live
                continue;  // unrelated pointer
                }
            if ([storeOps containsObject:jop] && [jod isEqualToString:s])
                {
                dead = YES;
                break; // overwritten before any read
                }
            if ([jod containsString:s])
                break; // direct read / RMW = live
            if ([barrierOps containsObject:jop])
                break;
            }
        if (dead)
            [drop addIndex:i];
        }
    if (drop.count == 0)
        return asmText;
    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
        if (![drop containsIndex:i])
            [out addObject:lines[i]];
    return [out componentsJoinedByString:@"\n"];
    }

// ─────────────────────────────────────────────────────────────────────

@implementation XT6502AsmPeephole

+ (NSString*)optimise:(NSString*)asmText level:(NSInteger)level
    {
    if (level <= 0 || asmText.length == 0)
        return asmText;
    // Iterate to fixed point — rule 2 can expose new rule 1 patterns
    // (a dropped JMP can put a STA + LDA next to each other across
    // what used to be a block boundary) and vice versa.
    NSString* cur = asmText;
    for (int hop = 0; hop < 8; hop++)
        {
        NSString* prev = cur;
        cur = applyICmpBranchFusion(cur);
        cur = applyConstFold(cur);
        cur = applyRedundantReload(cur);
        cur = applyDuplicateStore(cur);
        cur = applyDeadStore(cur);
        cur = applyJmpToNextLabel(cur);
        if ([cur isEqualToString:prev])
            break;
        }
    return cur;
    }

@end
