// XTArm64Backend.m
//
// One 8-byte stack slot per IR value (covers both 32-bit integers and
// 64-bit pointers; ARM64 strictly requires the latter, and the
// integer ops still use the low 4 bytes via str w / ldr w). Caller-
// saved scratch registers (w16/x16, w17/x17) are the universal "load
// operand → op → store result" temporaries; arg registers x0..x7 hold
// parameters at function entry and call arguments at call sites. The
// mapping:
//
//   slot offset = 16 + 8 * value_id     (16-byte prologue saves
//                                        x29/x30 at offsets 0/8)
//   frame_size  = round_up_16(16 + 8 * fn.nextValueId)
//
// Memory tokens consume a slot but never get loaded from / stored to.
//
// AAPCS64 trivia we rely on:
//   - SP must stay 16-byte aligned across calls.
//   - Integer params 0..7 enter in x0..x7 (w-views for ≤32-bit).
//   - Pointer params 0..7 also enter in x0..x7 (full 64-bit view).
//   - Integer / pointer return goes in x0.
//   - x29/x30 are FP/LR; standard prologue stp's them.
//   - w16/w17 (x16/x17) are caller-saved scratch (IP0/IP1) —
//     safe to clobber.
#import "XTArm64Backend.h"
#import "XTAggInitRelay.h"
#import "XTIR.h"

#pragma mark - Per-function context

@interface XTArm64FnCtx : NSObject
@property (nonatomic) XTIRFunction *fn;
@property (nonatomic) XTIRModule *module;
@property (nonatomic) NSMutableString *out;
@property (nonatomic) NSUInteger frameSize;   // bytes, multiple of 16
@property (nonatomic) NSUInteger labelCounter;
@property (nonatomic) NSArray<NSNumber *> *slotOffsets;  // valueId → sp offset
// Register allocation (op-site homing). homeReg maps a homed SSA
// value-id → its dedicated callee-saved register in *canonical* form
// ("x19".."x27" for GP, "d8".."d15" for FP); the actual width used at
// a site is derived per the value's type (homeView:forType:). A value
// absent from homeReg lives in its stack slot as before. savedRegs is
// the ordered list of callee-saved registers to spill in the prologue /
// reload in every epilogue; saveAreaOffset is the sp offset where that
// save area begins (just past the value slots). valueSlotEnd is the
// end of the value-slot region (before the save area), recorded by
// buildSlotTableForCtx: so the save area can be laid out after.
@property (nonatomic) NSMutableDictionary<NSNumber *, NSString *> *homeReg;
@property (nonatomic) NSArray<NSString *> *savedRegs;
@property (nonatomic) NSUInteger saveAreaOffset;
// Base offset held in x28 for a frame too large for sp-relative slot access,
// or 0 when unused. x28 is in no home pool (homes are x19-x27 and x10-x14; x9
// stages, x15-x17 scratch, x8 the indirect result), so it is reserved as a
// second frame base covering the TOP of the frame, where the scalar value slots
// sit once large aggregates have been laid out first.
@property (nonatomic) NSUInteger frameBase;
@property (nonatomic) NSUInteger valueSlotEnd;
// Bug 065: value id -> its position in the IR TEXT's dense per-function
// numbering. The ported back end assigns from that text, so every place this
// one observes id ORDER has to observe the same one.
@property (nonatomic) NSDictionary<NSNumber *, NSNumber *> *denseIdx;
// SP offset of the saved x8 sret pointer, for a function that RETURNS a >16-byte
// non-HFA aggregate: the caller passes the result address in x8, the prologue
// stows it here, and each `return` writes the struct through it. 0 = none.
@property (nonatomic) NSUInteger sretSaveOffset;
// AAPCS outgoing-stack-argument area, reserved at the BOTTOM of the frame
// ([sp, #0 .. maxOutStack)) for calls that pass more than 8 GP / 8 FP arguments.
// 0 for any function that makes no such call — then the frame is byte-identical
// to before and x29/x30 sit at [sp,#0] (see buildSlotTableForCtx / the prologue).
// When non-zero, x29/x30 move up to [sp, #maxOutStack] and every value slot
// starts above them.
@property (nonatomic) NSUInteger maxOutStack;
// Instruction fusion (computed after allocation). `fusedAway` = value-ids whose
// defining insn is folded into a successor and must NOT be emitted; `fuseAt` =
// result-id → fusion descriptor emitted in place of the normal op.
@property (nonatomic) NSMutableSet<NSNumber *> *fusedAway;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSDictionary *> *fuseAt;
// Address-mode folding: `foldedAddr` = FieldAddr/ElementAddr value-ids folded
// into their single Load/Store consumer (their own emit is skipped). `foldInfo`
// = pointer-value-id of a foldable Load/Store → the FieldAddr/ElementAddr insn
// whose base+offset/index it should address directly.
@property (nonatomic) NSMutableSet<NSNumber *> *foldedAddr;
@property (nonatomic) NSMutableDictionary<NSNumber *, XTIRInsn *> *foldInfo;
// Value-id → defining insn, and use multiplicity, for the whole function.
// Built by computeAddrFoldForCtx (it needs both); reused by the emit to spot a
// single-use `Const #0` store value (→ store the zero register, elide the const).
@property (nonatomic) NSMutableDictionary<NSNumber *, XTIRInsn *> *defOf;
@property (nonatomic) NSCountedSet<NSNumber *> *useCount;
// Value-ids whose narrow-int (U8/U16) result provably can't overflow its width,
// so the backend may skip the uxtb/uxth canonicalisation (masked == unmasked
// bit-for-bit). Computed by computeNoWrapForCtx from induction-variable loop
// bounds + forward range propagation.
@property (nonatomic) NSMutableSet<NSNumber *> *noCanon;
// ICmp result value-ids whose only use is their block's CondBranch terminator:
// the ICmp's emit is skipped and the branch emits `cmp …; b.<cond>` directly
// (instead of materialising a 0/1 bool and a `cbnz`).
@property (nonatomic) NSMutableSet<NSNumber *> *fusedCmps;
// SIMD: vector value-id → NEON v-register name ("v0".."v15"). Assigned on first
// def in definition order; vector values are produced and consumed within a
// single straight-line vectorized loop body (no cross-iteration/-call vector
// liveness), so caller-saved v0..v15 suffice and need no spill.
@property (nonatomic) NSMutableDictionary<NSNumber *, NSString *> *vecReg;
@property (nonatomic) NSUInteger vecNext;
@end
@implementation XTArm64FnCtx
@end

@interface XTArm64Backend (SlotColouringForward)
+ (void)computeLiveIntervalsForCtx:(XTArm64FnCtx *)ctx
                           startOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)startOf
                             endOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)endOf
                        phiResults:(NSMutableSet<NSNumber *> *)phiResults
                       crossesCall:(nullable NSMutableSet<NSNumber *> *)crossesCall;
@end

// log2 of a global's alignment: its natural alignment, capped at 8 — the same
// cap the front end uses for struct fields on this target (#1084). Derived from
// SIZE rather than from a type walk because that is all the emit site has, and
// it gives the right answer for every scalar and a safe one for an aggregate:
// anything 8 bytes or larger may contain a pointer, and 8 is what a pointer
// needs. Over-aligning a small aggregate costs padding, never correctness.
static unsigned xtArm64GlobalP2Align(uint32_t size) {
    if (size >= 8) return 3;
    if (size >= 4) return 2;
    if (size >= 2) return 1;
    return 0;
}

@implementation XTArm64Backend

#pragma mark - Frame / slot helpers

// Build the per-value slot-offset table and frame size on ctx. Each
// value gets max(8, round8(arm64FieldWidth)) bytes — 8 for every
// scalar/pointer (so a function with no Agg values lays out identically
// to the old `16 + 8*vid`, zero codegen drift) and arm64AggSize
// (rounded to 8) for an aggregate value, so a multi-field tuple /
// >8-byte struct fits its slot instead of spilling into the next one.
+ (void)buildSlotTableForCtx:(XTArm64FnCtx *)ctx {
    NSUInteger n = ctx.fn.nextValueId;
    NSMutableArray<NSNumber *> *offs = [NSMutableArray arrayWithCapacity:n];
    // AAPCS outgoing-stack-argument area, reserved at the bottom of the frame for
    // any call that passes args past x0..x7 / v0..v7. 0 (the common case) leaves
    // the frame byte-identical: cur starts at 16 and x29/x30 stay at [sp,#0].
    NSUInteger maxOut = 0;
    for (XTIRBlock *blk in ctx.fn.blocks)
        for (XTIRInsn *ins in blk.instructions) {
            NSUInteger b = [self arm64OutStackBytesForInsn:ins ctx:ctx];
            if (b > maxOut) maxOut = b;
        }
    ctx.maxOutStack = maxOut;

    // ── Stack-slot COLOURING ────────────────────────────────────────────
    //
    // A slot used to be handed to every value id in order, so the frame was the
    // SUM of everything the function ever defined — a temporary dead after three
    // instructions cost as much as one live throughout. That is what puts real
    // functions against the 16 KB budget (this compiler's own vecReduxExit and
    // the settings handler both hit it), and it is pure waste: the live-interval
    // analysis that would let slots be REUSED is already computed, for register
    // homing, and simply never consulted here.
    //
    // Values whose live ranges do not overlap now share a slot, exactly as
    // registers already do. Assignment is greedy over intervals sorted by start,
    // with a free list keyed by slot WIDTH so an 8-byte value never lands in a
    // narrower hole.
    //
    // REFUSED, because a shared slot would be silent corruption:
    //   * any function containing inline asm — an asm body may name a slot
    //     directly, and nothing here can see that reference;
    //   * an ADDRESS-TAKEN value — the pointer outlives the interval by
    //     definition, and may be stored, passed or compared;
    //   * an AGGREGATE — its slot is read through field offsets, so a later
    //     occupant would alias the fields;
    //   * a value with no interval, which means the analysis did not see it.
    // Each of those keeps a private slot, exactly as before.
    NSMutableDictionary<NSNumber *, NSNumber *> *ivStart = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *ivEnd   = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *ivPhis = [NSMutableSet set];
    NSMutableArray<NSNumber *> *blkEndPos = [NSMutableArray array];
    [self computeLiveIntervalsForCtx:ctx startOf:ivStart endOf:ivEnd
                          phiResults:ivPhis crossesCall:nil blockEnds:blkEndPos];

    // Loop-aware extension — without this the colouring is UNSOUND, and that is
    // what made the first attempt miscompile rather than merely under-perform.
    //
    // The intervals above are LINEAR and the CFG is not. A value defined
    // mid-loop and live across the BACK EDGE is live again at EARLIER positions
    // on the next iteration, which [def..end] never covers — so a value confined
    // to that earlier region looks disjoint and would be handed the same slot.
    //
    // A loop-carried value is exactly one the pass already pushed out to the
    // latch's end, because it is live-out there. Pulling its START back to the
    // loop header therefore makes its interval span the whole loop, and nothing
    // inside can share it. Only lengthens intervals, so it can remove reuse but
    // never introduce a clobber. Nested loops fall out by applying this per back
    // edge, innermost first.
    NSArray<XTIRBlock *> *cblocks = ctx.fn.blocks;
    for (NSUInteger li = 0; li < cblocks.count && li < blkEndPos.count; li++) {
        XTIRInsn *t = cblocks[li].terminator;
        if (!t) continue;
        for (XTIROperand *o in t.operands) {
            if (o.kind != XTIROperandKindBlock || !o.blockRef) continue;
            NSUInteger hb = [cblocks indexOfObjectIdenticalTo:o.blockRef];
            if (hb == NSNotFound || hb > li) continue;          // forward edge, not a loop
            NSInteger loopLo = 2 * (hb == 0 ? 0 : blkEndPos[hb - 1].integerValue + 1);
            NSInteger latchEnd = 2 * blkEndPos[li].integerValue + 2;
            for (NSNumber *v in ivStart.allKeys) {
                if (ivEnd[v].integerValue < latchEnd) continue;  // not live out of the latch
                if (ivStart[v].integerValue <= loopLo) continue; // already spans the header
                // ...and it must be DEFINED IN THIS LOOP — the same guard the
                // register-homing copy below carries, and for the same reason.
                // The port implements both from ONE shared loopExtendStarts, so
                // a guard added to only one of these two makes the compilers
                // disagree about every frame in the program.
                if (ivStart[v].integerValue > latchEnd) continue;
                ivStart[v] = @(loopLo);
            }
        }
    }

    // A function with inline asm is refused outright: an asm body can name a
    // local's slot directly ({{XTLOCAL}}), and nothing here can see that use.
    // Address-taken values and DECLARED PINNED LOCALS keep private slots for the
    // same reason — the slot address escapes the interval.
    BOOL hasAsmBody = NO;
    NSMutableSet<NSNumber *> *noShare = [NSMutableSet set];
    for (XTIRBlock *blk in ctx.fn.blocks) {
        for (XTIRInsn *ins in blk.instructions) {
            if (ins.opcode == XTIROpAsm) hasAsmBody = YES;
            if (ins.opcode == XTIROpAddrOf && ins.operands.count >= 1
                && ins.operands[0].kind == XTIROperandKindUse)
                [noShare addObject:@(ins.operands[0].valueId)];
        }
    }
    for (XTIRPinnedLocal *pl in ctx.fn.frameInfo.pinnedLocals)
        if (pl.valueId) [noShare addObject:@(pl.valueId)];
    // PHI results and their inputs never share.
    //
    // A phi is realised as a COPY at the end of each predecessor: the incoming
    // value is read there and the phi's slot written there, both at a point
    // where SSA liveness says the phi result is not yet live. So a slot shared
    // with anything live on that edge is clobbered by the copy, and no amount of
    // interval reasoning about the phi result sees it — an independent liveness
    // verifier over this colouring reports ZERO conflicts while the code is
    // still wrong, which is what pointed here. Same shape as the lost-copy bug
    // the homing allocator hit in #683.
    for (XTIRBlock *blk in ctx.fn.blocks)
        for (XTIRInsn *phi in blk.phiNodes) {
            if (phi.result) [noShare addObject:@(phi.result.valueId)];
            for (XTIROperand *o in phi.operands)
                if (o.kind == XTIROperandKindUse) [noShare addObject:@(o.valueId)];
        }
    // Only a value still DEFINED in this function may be coloured. Passes run
    // before codegen (VaArgExpand runs unconditionally, even at -O0) rewrite
    // instructions away and leave their result ids registered with no remaining
    // def -- 29 of them in Stdio$printf alone. Those keep private slots, and
    // "defined" is derived from the IR rather than from whether the interval
    // pass happens to hold a key for them: the two compilers agree on every
    // interval they COMPUTE but not on which dead ids they carry, and using map
    // presence as the test let that difference decide the frame layout.
    NSMutableSet<NSNumber *> *definedVals = [NSMutableSet set];
    for (XTIRBlock *blk in ctx.fn.blocks) {
        for (XTIRInsn *p in blk.phiNodes)     if (p.result) [definedVals addObject:@(p.result.valueId)];
        for (XTIRInsn *i in blk.instructions) if (i.result) [definedVals addObject:@(i.result.valueId)];
        if (blk.terminator && blk.terminator.result)
            [definedVals addObject:@(blk.terminator.result.valueId)];
    }
    // Bug 065. Two facts about the ported back end decide this function's
    // layout, and both come from the same place: the port reads IR TEXT, and
    // XTIRPrintContext renumbers value ids DENSELY PER FUNCTION.
    //
    //  (a) the text has no HOLES. An id whose defining instruction a pass
    //      deleted stays registered here but is never printed, so the port does
    //      not know it exists. Giving it a private slot made this frame bigger
    //      than the port's by exactly the dead count.
    //  (b) the text is renumbered in the order values are FIRST WRITTEN, which
    //      is not the order they were CREATED. A pass that makes a new
    //      instruction with a high id and inserts it early flips the two.
    //      Every tie-break on the raw id therefore breaks the other way in the
    //      port — 37 such inversions in Array$_grow alone.
    //
    // So the id space is filtered to what the function CONTAINS, and everything
    // that observes id ORDER uses the printer's numbering instead of the raw
    // one. (SSA variable space only: vtable slots are positional and a `_`
    // entry is load-bearing for respondsTo / optional protocol methods.)
    NSMutableSet<NSNumber *> *presentVals = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *denseIdx = [NSMutableDictionary dictionary];
    __block NSUInteger denseNext = 0;
    void (^see)(NSUInteger) = ^(NSUInteger vid) {
        [presentVals addObject:@(vid)];
        if (!denseIdx[@(vid)]) denseIdx[@(vid)] = @(denseNext++);
    };
    for (NSUInteger p = 0; p < ctx.fn.paramTypes.count; p++) see(p);
    for (XTIRPinnedLocal *lo in ctx.fn.frameInfo.pinnedLocals) see(lo.valueId);
    for (XTIRBlock *blk in ctx.fn.blocks) {
        NSMutableArray<XTIRInsn *> *all = [blk.phiNodes mutableCopy] ?: [NSMutableArray array];
        [all addObjectsFromArray:blk.instructions];
        if (blk.terminator) [all addObject:blk.terminator];
        for (XTIRInsn *ins in all) {
            if (ins.result) see(ins.result.valueId);
            // The memory token is a SECOND result, beside `result`, and printed
            // like one. Omitting it drops LIVE ids and shrinks frames at -O0 —
            // how three earlier attempts at this bug went wrong.
            if (ins.memoryResult) see(ins.memoryResult.valueId);
        }
    }
    // Operand-only ids last, so a dangling use still gets a deterministic place.
    for (XTIRBlock *blk in ctx.fn.blocks) {
        NSMutableArray<XTIRInsn *> *all = [blk.phiNodes mutableCopy] ?: [NSMutableArray array];
        [all addObjectsFromArray:blk.instructions];
        if (blk.terminator) [all addObject:blk.terminator];
        for (XTIRInsn *ins in all)
            for (XTIROperand *o in ins.operands)
                if (o.kind == XTIROperandKindUse) see(o.valueId);
    }
    ctx.denseIdx = denseIdx;
    NSComparisonResult (^byDense)(NSNumber *, NSNumber *) = ^(NSNumber *a, NSNumber *b) {
        NSNumber *da = denseIdx[a], *db = denseIdx[b];
        if (da && db) return [da compare:db];
        return [a compare:b];
    };

    BOOL colourable = !hasAsmBody;
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger vid = 0; vid < n; vid++) {
        XTIRValue *v = [ctx.fn valueForId:vid];
        BOOL agg = (v && v.type && v.type.kind == XTIRTypeKindAgg);
        BOOL taken = [noShare containsObject:@(vid)];
        if (colourable && !agg && !taken && [definedVals containsObject:@(vid)]
            && ivStart[@(vid)] && ivEnd[@(vid)])
            [order addObject:@(vid)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSInteger sa = ivStart[a].integerValue, sb = ivStart[b].integerValue;
        if (sa != sb) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
        return byDense(a, b);                     // 065: the printer's order
    }];
    NSMutableSet<NSNumber *> *shared = [NSMutableSet setWithArray:order];

    NSUInteger cur = maxOut + 16;              // [0..maxOut)=outgoing args, then x29/x30
    for (NSUInteger vid = 0; vid < n; vid++) [offs addObject:@(0)];

    // Pass 1: every value that cannot share keeps its own slot, in the order
    // the IR TEXT numbers them (065) — the port assigns from that text, so any
    // other order lays the frame out differently for the same program.
    NSArray<NSNumber *> *pass1 = [[presentVals allObjects] sortedArrayUsingComparator:
        ^NSComparisonResult(NSNumber *a, NSNumber *b) { return byDense(a, b); }];
    for (NSNumber *vidN in pass1) {
        NSUInteger vid = vidN.unsignedIntegerValue;
        if (vid >= n) continue;
        if ([shared containsObject:@(vid)]) continue;
        XTIRValue *v = [ctx.fn valueForId:vid];
        NSUInteger w = 8;
        if (v && v.type && v.type.kind == XTIRTypeKindAgg) {
            NSUInteger agg = [self arm64AggSize:v.type.layout];
            w = (agg + 7) & ~(NSUInteger)7;
            if (w < 8) w = 8;
        }
        offs[vid] = @(cur);
        cur += w;
    }

    // Pass 2: colour the rest. A slot is reusable once its previous occupant's
    // interval has ENDED — strictly before this one starts, never equal, since
    // doubled positions make a def and a last-use at the same instruction share
    // a number.
    NSMutableArray<NSNumber *> *freeSlots = [NSMutableArray array];   // offsets
    NSMutableArray<NSNumber *> *freeUntil = [NSMutableArray array];   // their end
    for (NSNumber *vn in order) {
        NSInteger st = ivStart[vn].integerValue;
        NSInteger en = ivEnd[vn].integerValue;
        NSInteger pick = -1;
        for (NSUInteger i = 0; i < freeSlots.count; i++) {
            if (freeUntil[i].integerValue < st) {
                pick = freeSlots[i].integerValue;
                [freeSlots removeObjectAtIndex:i];
                [freeUntil removeObjectAtIndex:i];
                break;
            }
        }
        if (pick < 0) { pick = (NSInteger)cur; cur += 8; }
        offs[vn.unsignedIntegerValue] = @(pick);
        [freeSlots addObject:@(pick)];
        [freeUntil addObject:@(en)];
    }
    ctx.slotOffsets = offs;
    [self verifySlotsForCtx:ctx];

    // Reserve a slot for the incoming x8 sret pointer when this function returns
    // a >16-byte non-HFA aggregate (an HFA returns in v-registers and needs none).
    ctx.sretSaveOffset = 0;
    XTIRType *rt = ctx.fn.returnType;
    if (rt && rt.kind == XTIRTypeKindAgg
        && [self arm64AggHFA:rt.layout elemKind:NULL] == 0
        && [self arm64AggSize:rt.layout] > 16) {
        ctx.sretSaveOffset = cur;
        cur += 8;
    }
    ctx.valueSlotEnd = cur;                   // save area (if any) starts here
    NSUInteger bytes = (cur + 15) & ~(NSUInteger)15;   // round up to 16
    if (bytes < 16) bytes = 16;
    // Frame ceiling. The old 16 KB budget existed because a frame-slot access
    // was a bare `str/ldr <reg>, [sp, #off]` whose scaled immediate tops out
    // at 16380 (w/s view); every slot access now routes through spMemForOff,
    // which stages an out-of-range offset in x9 and goes register-indirect —
    // so a big frame is merely slower at its far end, not a compile error
    // (fuzz seeds 95/165/267: valid programs refused at the DEFAULT -O3, or
    // at -O0 outright). What remains is a sanity ceiling far above anything a
    // real program should reach — 4 MB, half a typical 8 MB thread stack —
    // failing loudly rather than emitting a frame that faults the guard page.
    if (bytes > 4u * 1024u * 1024u) {
        [NSException raise:@"XTFrameBudgetExceeded"
                    format:@"function '%@' needs %lu frame bytes, exceeding the "
                           @"4 MB arm64 frame ceiling — split it into smaller "
                           @"functions or reduce large locals",
                           ctx.fn.name, (unsigned long)bytes];
    }
    ctx.frameSize = bytes;
}

// AAPCS argument classification — the SINGLE source of truth for where each arg
// lives, shared by maxOutStack sizing, caller marshalling, and callee param
// loading so their stack offsets can never drift. Walk `argTypes` (an NSNull
// entry means an untyped immediate → a 4-byte GP scalar) assigning each to a GP
// or FP register while the bank has room, else to the outgoing stack area
// (natural size, naturally aligned — Apple packs stack args to their real size,
// not 8-byte slots). Returns a parallel array of stack offsets: -1 for a
// register arg, else its byte offset within the outgoing area. *total (if given)
// gets the 16-rounded total stack bytes. Aggregates consume registers like
// marshalAggArg and are never stacked here (an overflowing aggregate is left in
// no-home, matching the pre-existing "stack-passed aggregate unsupported").
+ (NSArray<NSNumber *> *)arm64ArgStackOffsets:(NSArray *)argTypes
                                       startGP:(int)gpIdx startFP:(int)fpIdx
                                    totalBytes:(NSUInteger *)total {
    return [self arm64ArgStackOffsets:argTypes startGP:gpIdx startFP:fpIdx
                           totalBytes:total variadicFrom:-1];
}

// `variadicFrom` >= 0 marks the first C-VARIADIC tail argument: on Darwin the
// entire tail goes on the STACK in 8-byte slots however many registers remain
// (Apple's AAPCS deviation — a register-passed tail is what printf reads as
// garbage). -1 = no C-variadic tail (every existing caller). The xtc
// pack-buffer convention never reaches this: its callees take the buffer
// pointer as an ordinary named argument.
+ (NSArray<NSNumber *> *)arm64ArgStackOffsets:(NSArray *)argTypes
                                       startGP:(int)gpIdx startFP:(int)fpIdx
                                    totalBytes:(NSUInteger *)total
                                  variadicFrom:(NSInteger)vfrom {
    NSMutableArray<NSNumber *> *offs = [NSMutableArray arrayWithCapacity:argTypes.count];
    NSUInteger stackOff = 0;
    NSInteger argIdx = -1;
    // One overflow slot. Darwin packs the argument to its natural size; AAPCS64
    // rounds every one up to 8 bytes and aligns it to 8. Both the marshalling
    // site and the parameter-reading site come through here, so they cannot
    // disagree about which rule is in force.
    NSUInteger (^slot)(NSUInteger) = ^NSUInteger(NSUInteger sz) {
        return sArm64Aapcs64Abi ? 8 : sz;
    };
    for (id entry in argTypes) {
        argIdx++;
        if (vfrom >= 0 && argIdx >= vfrom) {
            stackOff = (stackOff + 7) & ~(NSUInteger)7;   // 8-byte slots, 8-aligned
            [offs addObject:@((NSInteger)stackOff)];
            stackOff += 8;
            continue;
        }
        XTIRType *ty = (entry == [NSNull null]) ? nil : (XTIRType *)entry;
        BOOL isFloat = ty && XTIRTypeKindIsFloating(ty.kind);
        BOOL isAgg   = ty && ty.kind == XTIRTypeKindAgg;
        if (isAgg) {
            XTIRTypeKind ek = XTIRTypeKindVoid;
            NSUInteger hfa = [self arm64AggHFA:ty.layout elemKind:&ek];
            BOOL fits;
            if (hfa > 0) { fits = (fpIdx + (int)hfa <= 8); if (fits) fpIdx += (int)hfa; }
            else { NSUInteger nr = [self gpRegsForAgg:ty];
                   fits = (gpIdx + (int)nr <= 8); if (fits) gpIdx += (int)nr; }
            if (fits) {
                [offs addObject:@(-1)];
            } else {
                // Overflow: once an aggregate does not fit the remaining
                // registers it is passed ENTIRELY on the stack (AAPCS C.13),
                // 8-aligned, at its natural size — and the register bank is
                // then closed (NGRN/NSRN → 8) so no later arg backfills the
                // gap. Both the caller and the callee reach this, so their
                // offsets cannot drift. Was silently left in no-home before:
                // a struct past x7 (bug 20) and a callback pair past x7
                // (bug 21) read frame litter.
                if (hfa > 0) fpIdx = 8; else gpIdx = 8;
                NSUInteger sz = ([self arm64AggSize:ty.layout] + 7) & ~(NSUInteger)7;
                stackOff = (stackOff + 7) & ~(NSUInteger)7;
                [offs addObject:@((NSInteger)stackOff)]; stackOff += sz;
            }
        } else if (isFloat) {
            if (fpIdx < 8) { fpIdx++; [offs addObject:@(-1)]; }
            else {
                NSUInteger sz = slot((ty.kind == XTIRTypeKindF64) ? 8 : 4);
                stackOff = (stackOff + sz - 1) & ~(sz - 1);
                [offs addObject:@((NSInteger)stackOff)]; stackOff += sz;
            }
        } else {
            if (gpIdx < 8) { gpIdx++; [offs addObject:@(-1)]; }
            else {
                NSUInteger sz = ty ? [self arm64FieldWidth:ty] : 4;
                if (sz == 0) sz = 4;
                sz = slot(sz);
                stackOff = (stackOff + sz - 1) & ~(sz - 1);
                [offs addObject:@((NSInteger)stackOff)]; stackOff += sz;
            }
        }
    }
    if (total) *total = (stackOff + 15) & ~(NSUInteger)15;
    return offs;
}


// A call straight to a named symbol, whatever the callee's placement. A banked
// or cloaked callee takes the same arguments in the same places; on arm64 the
// placement changes nothing, so a variadic one needs its tail on the stack like
// any other.
static BOOL arm64IsDirectCallOpcode(XTIROpcode op) {
    return op == XTIROpCall || op == XTIROpCallBanked || op == XTIROpCallCloaked;
}

// The first C-variadic TAIL index for a call insn, or -1. Only a direct call
// to a symbol marked variadic AND cabi qualifies (a bodyless `...` source
// declaration or a DWARF C import); the fixed count is the declared parameter
// list, whose IR signature carries a trailing Mem.
+ (NSInteger)arm64CVariadicFromForInsn:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    // Under plain AAPCS64 there is no tail to mark: a variadic argument is
    // placed exactly like a named one, so the ordinary path already does the
    // right thing and the Darwin deviation must NOT be applied.
    if (sArm64Aapcs64Abi) return -1;
    if (!arm64IsDirectCallOpcode(insn.opcode) || insn.operands.count < 2) return -1;
    XTIROperand *callee = insn.operands[0];
    if (callee.kind != XTIROperandKindSym) return -1;
    XTIRSymbol *sym = [ctx.module symbolForId:callee.symbolId];
    // Every variadic call places its tail on the stack under Darwin's rule —
    // not just a C import. Since arm64 uses the native AAPCS va_list (bug 179),
    // an xc variadic (marked `variadic`, not `cabi`) is called the same way, so
    // its callee's va_start finds the tail where the caller wrote it.
    if (!sym || !sym.attributes[@"variadic"].boolValue) return -1;
    NSInteger fixed = (NSInteger)sym.function.paramTypes.count - 1;   // drop Mem
    return fixed >= 0 ? fixed : -1;
}

// Bytes the current function's FIXED params spilled to the incoming stack — the
// gap between sp+frameSize and the first variadic arg for va_start (bug 179).
// Lays the fixed (non-Memory) param types out through the same arg-slot rule the
// caller marshalled with, so the two cannot disagree. Usually 0: a handful of
// fixed args ride x0-x7 / v0-v7.
+ (NSUInteger)arm64FixedParamStackBytes:(XTArm64FnCtx *)ctx {
    NSMutableArray *fixedTypes = [NSMutableArray array];
    for (XTIRType *t in ctx.fn.paramTypes) {
        if (t && t.kind == XTIRTypeKindMemory) continue;
        [fixedTypes addObject:t ?: (id)[NSNull null]];
    }
    NSUInteger bytes = 0;
    [self arm64ArgStackOffsets:fixedTypes startGP:0 startFP:0
                    totalBytes:&bytes variadicFrom:-1];
    return bytes;
}

// Words of variadic tail a forwarder relays into a callee's outgoing slots
// (bug 179). The count can't be known (the format decides at run time), so it
// is capped — 16 words / 128 bytes, exactly as the pack-buffer targets cap it.
static const NSUInteger kArm64VaForwardWords = 16;

// YES if this is a DIRECT call, inside a `vaforward` function, to a variadic
// callee — i.e. a `void say(fmt, ...) { fmt2(fmt, ...); }` forward. Such a call
// re-passes this function's own incoming variadic tail; with no shared buffer
// on arm64 that means copying the tail into the callee's outgoing slots.
+ (BOOL)arm64VaForwardRelayForInsn:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    if (!arm64IsDirectCallOpcode(insn.opcode) || insn.operands.count < 2) return NO;
    XTIRSymbol *own = [ctx.module symbolForName:ctx.fn.name];
    if (!own.attributes[@"vaforward"].boolValue) return NO;
    XTIROperand *callee = insn.operands[0];
    if (callee.kind != XTIROperandKindSym) return NO;
    XTIRSymbol *cs = [ctx.module symbolForId:callee.symbolId];
    return cs.attributes[@"variadic"].boolValue;
}

// The arg IR types of a call insn, in order — NSNull for an untyped immediate.
// `first` is the operand index of the first arg; `argCount` how many; the last
// operand (Memory token) is excluded by the caller's argCount.
+ (NSArray *)arm64ArgTypesForInsn:(XTIRInsn *)insn from:(NSUInteger)first
                            count:(NSUInteger)argCount ctx:(XTArm64FnCtx *)ctx {
    NSMutableArray *types = [NSMutableArray arrayWithCapacity:argCount];
    for (NSUInteger i = 0; i < argCount; i++) {
        XTIROperand *a = insn.operands[first + i];
        XTIRValue *av = (a.kind == XTIROperandKindUse) ? [ctx.fn valueForId:a.valueId] : nil;
        [types addObject:(av && av.type) ? (id)av.type : (id)[NSNull null]];
    }
    return types;
}

// Outgoing stack bytes a single call insn needs (0 for non-calls / all-register
// calls). Mirrors each call opcode's arg range + starting GP index so the size
// computed here matches what the marshalling actually emits.
+ (NSUInteger)arm64OutStackBytesForInsn:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    NSUInteger first, argCount; int startGP;
    switch (insn.opcode) {
        case XTIROpCall: case XTIROpCallBanked: case XTIROpCallCloaked:
        case XTIROpCallIndirect:
            if (insn.operands.count < 2) return 0;
            first = 1; argCount = insn.operands.count - 2; startGP = 0;
            break;
        case XTIROpVTblDispatch:
            if (insn.operands.count < 3) return 0;
            first = 2; argCount = insn.operands.count - 3; startGP = 1;  // receiver in x0
            break;
        case XTIROpProtoDispatch:
            if (insn.operands.count < 4) return 0;
            first = 3; argCount = insn.operands.count - 4; startGP = 1;  // receiver in x0
            break;
        default:
            return 0;
    }
    NSArray *types = [self arm64ArgTypesForInsn:insn from:first count:argCount ctx:ctx];
    NSUInteger total = 0;
    [self arm64ArgStackOffsets:types startGP:startGP startFP:0 totalBytes:&total
                  variadicFrom:[self arm64CVariadicFromForInsn:insn ctx:ctx]];
    // A forwarding call re-passes 128 bytes of the incoming tail into the
    // outgoing slots after the explicit args, so the frame must reserve them.
    if ([self arm64VaForwardRelayForInsn:insn ctx:ctx])
        total += kArm64VaForwardWords * 8;
    return total;
}

// Marshal one scalar/pointer/float call argument to its AAPCS home. `stackOff < 0`
// → a register (advancing gpIdx/fpIdx); else → the outgoing stack area at
// [sp, #stackOff] (the area sits at the frame bottom, so sp-relative == area
// offset at the `bl`). Stack args use x9/w9 (GP) or s16/d16 (FP) as scratch —
// caller-saved temporaries free at the call boundary and distinct from the arg
// registers and the indirect-call fn pointer in x16.
+ (void)marshalArgOperand:(XTIROperand *)a value:(XTIRValue *)av
              stackOffset:(NSInteger)stackOff
                    gpIdx:(int *)gpIdx fpIdx:(int *)fpIdx ctx:(XTArm64FnCtx *)ctx {
    if (av && XTIRTypeKindIsFloating(av.type.kind)) {
        if (stackOff < 0) {
            [self loadValue:a.valueId intoReg:[self fregName:*fpIdx forType:av.type] ctx:ctx];
            (*fpIdx)++;
        } else {
            NSString *scratch = [self fregName:16 forType:av.type];   // s16/d16
            [self loadValue:a.valueId intoReg:scratch ctx:ctx];
            [ctx.out appendFormat:@"    str %@, [sp, #%ld]\n", scratch, (long)stackOff];
        }
    } else {
        if (stackOff < 0) {
            NSString *reg = av ? [self regName:*gpIdx forType:av.type]
                               : [NSString stringWithFormat:@"w%d", *gpIdx];
            [self materialiseOperand:a intoReg:reg ctx:ctx];
            (*gpIdx)++;
        } else {
            NSString *scratch = (av && [self irTypeNeedsXReg:av.type]) ? @"x9" : @"w9";
            [self materialiseOperand:a intoReg:scratch ctx:ctx];
            [ctx.out appendFormat:@"    str %@, [sp, #%ld]\n", scratch, (long)stackOff];
        }
    }
}

+ (NSUInteger)slotOffsetForValue:(XTIRValueId)vid ctx:(XTArm64FnCtx *)ctx {
    if (ctx.slotOffsets && (NSUInteger)vid < ctx.slotOffsets.count) {
        return ctx.slotOffsets[(NSUInteger)vid].unsignedIntegerValue;
    }
    return 16 + 8 * (NSUInteger)vid;          // fallback (table not built)
}

#pragma mark - Register allocation (op-site homing)

// Whole-function "v1" allocator: give the most-used eligible SSA values
// a dedicated callee-saved register for the entire function. No liveness
// analysis is needed — each homed value owns its register, SSA dominance
// guarantees the def precedes every use, and callee-saved registers
// survive `bl` automatically (so a value homed across a call needs no
// spill). The result is that op sites read and write the home register
// directly (`add w19, w19, w20`) instead of the load/op/store stack-
// machine churn.
//
// Eligibility: a value is excluded when it is a Memory token, an
// aggregate, Void, never read, has its address taken (operand of AddrOf
// — it must live at a real stack address), or is a declared pinned local
// (its slot is what AddrOf computes, and inline-asm {{XTLOCAL}} planters
// reference that slot directly). A function containing inline asm is
// skipped entirely: an `asm { }` block can name a local that lowering
// resolved to a fixed sp-relative slot, and homing that value would make
// the asm read a stale slot.
//
// Compute SSA live intervals (for register reuse). Fills `startOf`/`endOf`
// (valueId → DOUBLED program point) and `phiResults` (ids defined by a Phi).
//
// Positions are doubled: a value's interval is [2·defPos+1, 2·lastLivePoint].
// The +1 on the def means a value whose last *read* and the def that *consumes*
// it land on the same instruction (`a₁ = fsqrt(a₀)` — reads a₀ then writes a₁
// into the same reg) get touching-but-non-overlapping intervals, so a serial
// chain may share one register (`fsqrt s8,s8 …`) instead of one-reg-per-value.
//
// Liveness is a textbook backward dataflow with the SSA phi rule: a phi operand
// (pred, v) is a use of v at the END of pred (live-out of pred), not a use in
// the phi's block; the phi result is a def in its block. The interval is a
// conservative OVER-approximation (it ignores lifetime holes and spans whole
// blocks a value is live-out of), so two values judged non-overlapping are
// provably never simultaneously live — the soundness condition for sharing.
+ (BOOL)opcodeEmitsCall:(XTIROpcode)op {
    // Direct calls plus the opcodes arm64 lowers to a hidden runtime bl — a
    // value live across any of these cannot survive in a caller-saved register.
    return op == XTIROpCall || op == XTIROpCallBanked || op == XTIROpCallCloaked
        || op == XTIROpCallIndirect || op == XTIROpCallBankedIndirect
        || op == XTIROpVTblDispatch || op == XTIROpProtoDispatch
        || op == XTIROpMemCopy || op == XTIROpMemSet
        || op == XTIROpRelease || op == XTIROpAutorelease
        || op == XTIROpWeakRegister || op == XTIROpWeakUnregister || op == XTIROpWeakLoad;
}

+ (void)computeLiveIntervalsForCtx:(XTArm64FnCtx *)ctx
                           startOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)startOf
                             endOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)endOf
                        phiResults:(NSMutableSet<NSNumber *> *)phiResults
                       crossesCall:(nullable NSMutableSet<NSNumber *> *)crossesCall {
    [self computeLiveIntervalsForCtx:ctx startOf:startOf endOf:endOf
                          phiResults:phiResults crossesCall:crossesCall blockEnds:nil];
}

// Independent check of the one invariant slot colouring must hold: at NO program
// point may two distinct values sharing a frame slot both be live. Deliberately
// shares nothing with the interval code it checks — plain backward dataflow,
// walked instruction by instruction — because the interval reasoning is exactly
// what has been wrong. Gated on XTC_VERIFY_SLOTS so it costs nothing normally.
+ (void)verifySlotsForCtx:(XTArm64FnCtx *)ctx {
    if (!getenv("XTC_VERIFY_SLOTS")) return;
    XTIRFunction *fn = ctx.fn;
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSUInteger nb = blocks.count;
    if (nb == 0) return;

    NSMutableDictionary<NSValue *, NSNumber *> *idxOf = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < nb; i++)
        idxOf[[NSValue valueWithNonretainedObject:blocks[i]]] = @(i);

    NSMutableArray<NSMutableSet<NSNumber *> *> *useB = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *defB = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *liveIn = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *liveOut = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++) {
        [useB addObject:[NSMutableSet set]];  [defB addObject:[NSMutableSet set]];
        [liveIn addObject:[NSMutableSet set]]; [liveOut addObject:[NSMutableSet set]];
    }

    void (^scan)(XTIRInsn *, NSUInteger) = ^(XTIRInsn *insn, NSUInteger bi) {
        for (XTIROperand *o in insn.operands)
            if (o.kind == XTIROperandKindUse && ![defB[bi] containsObject:@(o.valueId)])
                [useB[bi] addObject:@(o.valueId)];
        if (insn.result) [defB[bi] addObject:@(insn.result.valueId)];
    };
    for (NSUInteger bi = 0; bi < nb; bi++) {
        for (XTIRInsn *p in blocks[bi].phiNodes) if (p.result) [defB[bi] addObject:@(p.result.valueId)];
        for (XTIRInsn *i in blocks[bi].instructions) scan(i, bi);
        if (blocks[bi].terminator) scan(blocks[bi].terminator, bi);
        // A phi operand is an EDGE use: live-out of the NAMED predecessor, not of
        // this block. Missing this is the classic way to under-report liveness.
        for (XTIRInsn *p in blocks[bi].phiNodes)
            for (NSUInteger k = 0; k + 1 < p.operands.count; k += 2) {
                XTIROperand *pb = p.operands[k], *pv = p.operands[k + 1];
                if (pb.kind != XTIROperandKindBlock || pv.kind != XTIROperandKindUse) continue;
                NSNumber *pi = idxOf[[NSValue valueWithNonretainedObject:pb.blockRef]];
                if (pi) [liveOut[pi.unsignedIntegerValue] addObject:@(pv.valueId)];
            }
    }

    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSInteger bi = (NSInteger)nb - 1; bi >= 0; bi--) {
            NSMutableSet<NSNumber *> *out = [liveOut[bi] mutableCopy];
            XTIRInsn *t = blocks[bi].terminator;
            if (t) for (XTIROperand *o in t.operands) {
                if (o.kind != XTIROperandKindBlock || !o.blockRef) continue;
                NSNumber *si = idxOf[[NSValue valueWithNonretainedObject:o.blockRef]];
                if (si) [out unionSet:liveIn[si.unsignedIntegerValue]];
            }
            NSMutableSet<NSNumber *> *in = [out mutableCopy];
            [in minusSet:defB[bi]];
            [in unionSet:useB[bi]];
            if (![out isEqualToSet:liveOut[bi]] || ![in isEqualToSet:liveIn[bi]]) {
                liveOut[bi] = out; liveIn[bi] = in; changed = YES;
            }
        }
    }

    // Walk each block backwards from its live-out set, checking the invariant at
    // every point.
    for (NSUInteger bi = 0; bi < nb; bi++) {
        NSMutableSet<NSNumber *> *live = [liveOut[bi] mutableCopy];
        NSMutableArray<XTIRInsn *> *body = [NSMutableArray array];
        [body addObjectsFromArray:blocks[bi].instructions];
        if (blocks[bi].terminator) [body addObject:blocks[bi].terminator];
        for (NSInteger ii = (NSInteger)body.count - 1; ii >= 0; ii--) {
            XTIRInsn *insn = body[ii];
            if (insn.result) [live removeObject:@(insn.result.valueId)];
            for (XTIROperand *o in insn.operands)
                if (o.kind == XTIROperandKindUse) [live addObject:@(o.valueId)];
            NSMutableDictionary<NSNumber *, NSNumber *> *bySlot = [NSMutableDictionary dictionary];
            for (NSNumber *v in live) {
                if (v.unsignedIntegerValue >= ctx.slotOffsets.count) continue;
                NSNumber *slot = ctx.slotOffsets[v.unsignedIntegerValue];
                NSNumber *other = bySlot[slot];
                if (other && ![other isEqual:v]) {
                    fprintf(stderr,
                        "SLOTCONFLICT fn=%s blk=%lu insn=%ld slot=%ld v%llu vs v%llu\n",
                        ctx.fn.name.UTF8String, (unsigned long)bi, (long)ii,
                        (long)slot.integerValue,
                        (unsigned long long)other.unsignedLongLongValue,
                        (unsigned long long)v.unsignedLongLongValue);
                }
                bySlot[slot] = v;
            }
        }
    }
}

// `blockEnds` (optional) receives each block's LAST undoubled position, which is
// what slot colouring needs to find loop spans. Passing nil keeps the previous
// behaviour exactly, so the register allocator is unaffected.
+ (void)computeLiveIntervalsForCtx:(XTArm64FnCtx *)ctx
                           startOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)startOf
                             endOf:(NSMutableDictionary<NSNumber *, NSNumber *> *)endOf
                        phiResults:(NSMutableSet<NSNumber *> *)phiResults
                       crossesCall:(nullable NSMutableSet<NSNumber *> *)crossesCall
                         blockEnds:(nullable NSMutableArray<NSNumber *> *)blockEndsOut {
    XTIRFunction *fn = ctx.fn;
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSMutableArray<NSNumber *> *callPos = [NSMutableArray array];   // undoubled positions
    NSUInteger nb = blocks.count;
    if (nb == 0) return;

    NSMutableArray<NSMutableSet<NSNumber *> *> *defSet   = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *ueUse    = [NSMutableArray array]; // upward-exposed uses
    NSMutableArray<NSMutableSet<NSNumber *> *> *phiResAt = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *phiEdge  = [NSMutableArray array]; // by PRED index
    NSMutableArray<NSNumber *> *blkEnd = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++) {
        [defSet addObject:[NSMutableSet set]];   [ueUse addObject:[NSMutableSet set]];
        [phiResAt addObject:[NSMutableSet set]]; [phiEdge addObject:[NSMutableSet set]];
        [blkEnd addObject:@0];
    }
    NSMutableDictionary<NSNumber *, NSNumber *> *defPos  = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *lastUse = [NSMutableDictionary dictionary];

    // `pos` is __block so the bodyUse closure below reads the live value (a
    // by-value capture would freeze it at the block-start position, collapsing
    // every interval in the block to a single point).
    __block NSInteger pos = 0;
    for (NSUInteger bi = 0; bi < nb; bi++) {
        XTIRBlock *b = blocks[bi];
        NSMutableSet<NSNumber *> *defs = defSet[bi], *ue = ueUse[bi];
        for (XTIRInsn *phi in b.phiNodes) {
            if (phi.result) {
                defPos[@(phi.result.valueId)] = @(pos);
                [defs addObject:@(phi.result.valueId)];
                [phiResAt[bi] addObject:@(phi.result.valueId)];
                [phiResults addObject:@(phi.result.valueId)];
            }
            pos++;                                 // phi operands are edge uses (below)
        }
        void (^recordUse)(XTIROperand *) = ^(XTIROperand *o) {
            if (o.kind != XTIROperandKindUse) return;
            NSNumber *v = @(o.valueId);
            if (![defs containsObject:v]) [ue addObject:v];
            lastUse[v] = @(pos);
        };
        void (^bodyUse)(XTIRInsn *) = ^(XTIRInsn *insn) {
            for (XTIROperand *o in insn.operands) recordUse(o);
            // A Load/Store that folds its FieldAddr/ElementAddr pointer reads
            // that addr op's base (and index) directly at *this* position — the
            // address computation moves down to here. Extend those operands'
            // live ranges accordingly, or the allocator (seeing the index die at
            // the now-elided addr op) would reuse its register for a value
            // defined before the load/store and clobber the index.
            if (insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindUse) {
                XTIRInsn *fa = ctx.foldInfo[@(insn.operands[0].valueId)];
                if (fa) for (XTIROperand *o in fa.operands) recordUse(o);
            }
            // A CondBranch that fuses its ICmp re-emits the `cmp` here, so the
            // ICmp's operands are read at *this* position (not the elided ICmp's)
            // — extend their live ranges, else the allocator reuses an operand's
            // register for a value defined between the ICmp and the branch (e.g.
            // a short-circuit's false constant) and clobbers it before the cmp.
            if (insn.opcode == XTIROpCondBranch && insn.operands.count >= 1 &&
                insn.operands[0].kind == XTIROperandKindUse &&
                [ctx.fusedCmps containsObject:@(insn.operands[0].valueId)]) {
                XTIRInsn *icmp = ctx.defOf[@(insn.operands[0].valueId)];
                if (icmp) for (XTIROperand *o in icmp.operands) recordUse(o);
            }
        };
        for (XTIRInsn *insn in b.instructions) {
            bodyUse(insn);
            if ([self opcodeEmitsCall:insn.opcode]) [callPos addObject:@(pos)];
            if (insn.result) { defPos[@(insn.result.valueId)] = @(pos); [defs addObject:@(insn.result.valueId)]; }
            pos++;
        }
        if (b.terminator) {
            bodyUse(b.terminator);
            if ([self opcodeEmitsCall:b.terminator.opcode]) [callPos addObject:@(pos)];
            pos++;
        }
        blkEnd[bi] = @(pos - 1);
    }

    // phi-edge uses + successor index lists.
    NSMutableArray<NSArray<NSNumber *> *> *succIdx = [NSMutableArray array];
    for (NSUInteger bi = 0; bi < nb; bi++) {
        NSMutableArray<NSNumber *> *s = [NSMutableArray array];
        XTIRInsn *t = blocks[bi].terminator;
        if (t) for (XTIROperand *o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef) {
                NSUInteger si = [blocks indexOfObjectIdenticalTo:o.blockRef];
                if (si != NSNotFound) [s addObject:@(si)];
            }
        [succIdx addObject:s];
    }
    for (NSUInteger si = 0; si < nb; si++)
        for (XTIRInsn *phi in blocks[si].phiNodes)
            for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2) {
                XTIROperand *bo = phi.operands[k], *vo = phi.operands[k + 1];
                if (bo.kind != XTIROperandKindBlock || !bo.blockRef) continue;
                if (vo.kind != XTIROperandKindUse) continue;
                NSUInteger predBi = [blocks indexOfObjectIdenticalTo:bo.blockRef];
                if (predBi != NSNotFound) [phiEdge[predBi] addObject:@(vo.valueId)];
            }

    // Backward dataflow to a fixpoint.
    NSMutableArray<NSMutableSet<NSNumber *> *> *liveIn = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber *> *> *liveOut = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++) { [liveIn addObject:[NSMutableSet set]]; [liveOut addObject:[NSMutableSet set]]; }
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSInteger bi = (NSInteger)nb - 1; bi >= 0; bi--) {
            NSMutableSet<NSNumber *> *out = [phiEdge[bi] mutableCopy];
            for (NSNumber *sn in succIdx[bi]) {
                NSMutableSet *sin = [liveIn[sn.unsignedIntegerValue] mutableCopy];
                [sin minusSet:phiResAt[sn.unsignedIntegerValue]];
                [out unionSet:sin];
            }
            NSMutableSet<NSNumber *> *in = [ueUse[bi] mutableCopy];
            NSMutableSet *od = [out mutableCopy]; [od minusSet:defSet[bi]];
            [in unionSet:od];
            if (![out isEqualToSet:liveOut[bi]] || ![in isEqualToSet:liveIn[bi]]) {
                liveOut[bi] = out; liveIn[bi] = in; changed = YES;
            }
        }
    }

    // Interval end = max(last read, end of any block the value is live-out of).
    NSMutableDictionary<NSNumber *, NSNumber *> *endByVal = [NSMutableDictionary dictionary];
    for (NSUInteger bi = 0; bi < nb; bi++) {
        NSInteger be = 2 * blkEnd[bi].integerValue + 2;
        for (NSNumber *v in liveOut[bi]) {
            NSNumber *cur = endByVal[v];
            if (!cur || be > cur.integerValue) endByVal[v] = @(be);
        }
    }
    if (blockEndsOut) [blockEndsOut setArray:blkEnd];
    NSMutableSet<NSNumber *> *allVals = [NSMutableSet setWithArray:defPos.allKeys];
    [allVals addObjectsFromArray:lastUse.allKeys];
    // A value whose only consumer is a phi-edge operand has no body def-pos and
    // no body last-use, but it IS live-out of the predecessor (recorded in
    // endByVal). Without this it would default to the point interval [0,0] and
    // be judged non-overlapping with a value defined in that same predecessor
    // (e.g. an accumulator's identity Const), so the two would share a register
    // and the Const's def would clobber the param before the edge copy reads
    // it. Including the live-out keys gives such a param its true [0, live-out]
    // interval. (Surfaced by tail-recursion → loop, where a parameter flows
    // into the header phi as the preheader incoming with no other use.)
    [allVals addObjectsFromArray:endByVal.allKeys];
    for (NSNumber *v in allVals) {
        NSInteger st = defPos[v] ? 2 * defPos[v].integerValue + 1 : 0;  // 0 = param/entry-live
        NSInteger en = st;
        if (lastUse[v]) en = MAX(en, 2 * lastUse[v].integerValue);
        if (endByVal[v]) en = MAX(en, endByVal[v].integerValue);
        startOf[v] = @(st); endOf[v] = @(en);
    }
    // A value crosses a call when a call's doubled position lies in its interval;
    // such a value may not use a caller-saved home. Conservative (over-approx
    // intervals only push more values to callee-saved).
    if (crossesCall)
        for (NSNumber *v in allVals) {
            NSInteger s = startOf[v].integerValue, e = endOf[v].integerValue;
            for (NSNumber *cp in callPos) {
                NSInteger c = 2 * cp.integerValue;
                if (s <= c && c <= e) { [crossesCall addObject:v]; break; }
            }
        }
}

// Thread-safe ARC (private:docs/Design/threading.md §4.1). Class-level rather than
// per-call because the backend's entry point is a class method and the choice
// is a whole-module property: a program either can have two threads or cannot.
// Per-function parameter descriptors for a CHECKED build: the trap reporter
// walks frames and reads each function's arguments out of them, and only the
// back end knows where they sit. Accumulated during codegen, emitted once at
// the end of the module. Reset per module in assemblyFromModule — the back end
// has two callers (the xtcg process and the in-process corpus sweep), and state
// that survives between them is state one of them gets wrong.
static NSMutableArray<NSDictionary *> *sArm64MSFns = nil;

// Registers: GP values (integer / pointer) take x19..x27 (9 slots), FP
// values (F32/F64) take d8..d15 (8 slots, callee-saved low 64). When more
// values are eligible than registers, the most-used win — and now, when their
// live ranges don't overlap, several share one register (live-range reuse).
+ (void)recordMSFnForCtx:(XTArm64FnCtx *)ctx {
    if (sArm64MSFns) {
        NSMutableArray *ps = [NSMutableArray array];
        NSUInteger np = ctx.fn.paramTypes.count;
        for (NSUInteger p = 0; p < np; p++) {
            XTIRType *t = ctx.fn.paramTypes[p];
            if (t && t.kind == XTIRTypeKindMemory) continue;      // the memory token
            BOOL inReg = (ctx.homeReg[@(p)] != nil);
            NSArray *so = ctx.slotOffsets;
            NSUInteger off = (!inReg && p < so.count) ? [so[p] unsignedIntegerValue] : 0;
            NSUInteger width = t ? [self arm64FieldWidth:t] : 0;
            NSUInteger kind = 1;                               // 1 int, 2 ptr, 3 float
            if (t && t.kind == XTIRTypeKindPtr) kind = 2;
            else if (t && XTIRTypeKindIsFloating(t.kind)) kind = 3;
            // The home REGISTER number when there is one: a parameter in x19 is
            // recoverable from the frame chain (the callee-save area of any
            // frame inside this one holds it), which is the only way arguments
            // are ever visible here — the allocator homes essentially every
            // parameter in a register and spills none.
            NSUInteger regNo = NSUIntegerMax;
            if (inReg) {
                NSString *rn = ctx.homeReg[@(p)];
                if ([rn hasPrefix:@"x"] || [rn hasPrefix:@"w"])
                    regNo = (NSUInteger)[[rn substringFromIndex:1] integerValue];
            }
            [ps addObject:@{ @"off": @(inReg ? NSUIntegerMax : off),
                             @"kw":  @((kind << 8) | (width & 0xFF)),
                             @"reg": @(regNo) }];
        }
        // The callee-save layout, so the walk can recover the registers of the
        // frames further out: emitCalleeSaves lays savedRegs down as pairs from
        // saveAreaOffset, so register k sits at saveAreaOffset + k*8.
        NSMutableArray *sr = [NSMutableArray array];
        for (NSString *rn in ctx.savedRegs) {
            if ([rn hasPrefix:@"x"] || [rn hasPrefix:@"d"])
                [sr addObject:@([[rn substringFromIndex:1] integerValue]
                                + ([rn hasPrefix:@"d"] ? 64 : 0))];
            else [sr addObject:@(-1)];
        }
        [sArm64MSFns addObject:@{ @"name": ctx.fn.name ?: @"?", @"params": ps,
                                  @"saveBase": @(ctx.valueSlotEnd),   // saveAreaOffset is assigned FROM this during prologue emission, i.e. after this point
                                  @"saved": sr }];
    }
}

+ (void)allocateRegistersForCtx:(XTArm64FnCtx *)ctx {
    XTIRFunction *fn = ctx.fn;
    ctx.homeReg = [NSMutableDictionary dictionary];
    ctx.savedRegs = @[];

    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSUInteger nb = blocks.count;

    // Loop detection (structured-CFG heuristic): a terminator edge whose
    // target block sits at or before the source in declaration order is a
    // back-edge, and the contiguous block range [target .. source] is its
    // loop body. This front-end emits loop bodies as contiguous block
    // ranges, so the approximation is tight. We home values *used inside a
    // loop* — those are the ones whose per-iteration loads dominate
    // retired-instruction count. A static use-count threshold would
    // wrongly drop a loop-carried value read just once per iteration
    // (static count 1, dynamic count huge); loop membership is the signal
    // that tracks the actual runtime cost, and it also leaves cold,
    // loop-free leaf functions homing nothing (no added frame overhead).
    //
    // A block's *depth* is the number of nested back-edge ranges covering it,
    // so a value used in a doubly-nested inner loop (depth 2) outranks one used
    // in the enclosing loop (depth 1) for a home register — its per-iteration
    // cost is multiplied by the outer trip count, dwarfing the outer value's
    // even when the outer value has a higher static use count. (A flat "in a
    // loop" boolean would let a once-per-outer-iteration value squeeze the
    // hot inner-loop value out of the pool — exactly the LICM-hoisted backing
    // pointer that motivated this.)
    NSMutableArray<NSNumber *> *blkDepth = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++) [blkDepth addObject:@0];
    for (NSUInteger si = 0; si < nb; si++) {
        XTIRInsn *term = blocks[si].terminator;
        if (!term) continue;
        for (XTIROperand *o in term.operands) {
            if (o.kind == XTIROperandKindBlock && o.blockRef) {
                NSUInteger ti = [blocks indexOfObjectIdenticalTo:o.blockRef];
                if (ti != NSNotFound && ti <= si) {
                    for (NSUInteger b = ti; b <= si; b++)
                        blkDepth[b] = @(blkDepth[b].unsignedIntegerValue + 1);
                }
            }
        }
    }

    NSCountedSet *uses = [NSCountedSet set];
    NSMutableSet<NSNumber *> *addrTaken = [NSMutableSet set];
    NSMutableSet<NSNumber *> *hot = [NSMutableSet set];  // value used in a loop
    NSMutableDictionary<NSNumber *, NSNumber *> *hotDepth =
        [NSMutableDictionary dictionary];               // value → max loop depth
    __block BOOL hasAsm = NO;
    void (^scan)(XTIRInsn *, NSUInteger) = ^(XTIRInsn *insn, NSUInteger depth) {
        if (insn.opcode == XTIROpAsm) hasAsm = YES;
        if (insn.opcode == XTIROpAddrOf && insn.operands.count >= 1) {
            XTIROperand *o = insn.operands[0];
            if (o.kind == XTIROperandKindUse) [addrTaken addObject:@(o.valueId)];
        }
        for (XTIROperand *o in insn.operands) {
            if (o.kind == XTIROperandKindUse) {
                [uses addObject:@(o.valueId)];
                if (depth > 0) {
                    [hot addObject:@(o.valueId)];
                    NSNumber *cur = hotDepth[@(o.valueId)];
                    if (!cur || cur.unsignedIntegerValue < depth)
                        hotDepth[@(o.valueId)] = @(depth);
                }
            }
        }
    };
    for (NSUInteger si = 0; si < nb; si++) {
        XTIRBlock *b = blocks[si];
        NSUInteger depth = blkDepth[si].unsignedIntegerValue;
        for (XTIRInsn *p in b.phiNodes)     scan(p, depth);
        for (XTIRInsn *i in b.instructions) scan(i, depth);
        if (b.terminator)                   scan(b.terminator, depth);
    }
    if (hasAsm) return;                       // home nothing (slot-ref safety)

    // The callee-save area sits just past the value slots, and a 64-bit scaled
    // immediate reaches 32760, so a big value-slot region pushes it out of
    // range. This used to give up on homing entirely at that point — which
    // meant a function holding a few large arrays on the stack got NO register
    // allocation at all, and reloaded even a loop-invariant base pointer from
    // its slot on every iteration. emitCalleeSaves already stages an
    // out-of-range save/restore through x9, so there is nothing left to
    // protect against; the 4 MB frame ceiling in buildSlotTableForCtx is the
    // real bound.

    for (XTIRPinnedLocal *pl in fn.frameInfo.pinnedLocals) {
        [addrTaken addObject:@(pl.valueId)];
    }

    NSMutableArray<NSNumber *> *gp = [NSMutableArray array];
    NSMutableArray<NSNumber *> *fp = [NSMutableArray array];
    for (NSUInteger vid = 0; vid < fn.nextValueId; vid++) {
        XTIRValue *v = [fn valueForId:vid];
        if (!v || !v.type) continue;
        if ([addrTaken containsObject:@(vid)]) continue;
        XTIRTypeKind k = v.type.kind;
        if (k == XTIRTypeKindMemory || k == XTIRTypeKindAgg ||
            k == XTIRTypeKindVoid || k == XTIRTypeKindVec) continue;  // Vec → NEON v-regs
        if ([uses countForObject:@(vid)] == 0) continue;   // never read
        if (XTIRTypeKindIsFloating(k)) {
            // Float homes live in d8-d15 (callee-saved), but feeding /
            // retrieving them at call boundaries needs a GP↔FP `fmov`, and
            // value moves between FP regs are `fmov` too. In a straight-line
            // float function (e.g. a print/format helper) those boundary
            // fmovs cost more than the slot traffic they replace, so only
            // home a float that is loop-resident — a loop-carried FP
            // accumulator, where the per-iteration reload it eliminates far
            // outweighs the one-time bracket. (GP values win even in
            // straight-line hot functions — no GP↔mem penalty — so they are
            // not gated this way.)
            if ([hot containsObject:@(vid)]) [fp addObject:@(vid)];
        } else {
            [gp addObject:@(vid)];
        }
    }

    // Rank: deepest-nested loop use first (a value read once per inner
    // iteration of a doubly-nested loop dominates one read several times in
    // the enclosing loop — its dynamic count is multiplied by the outer trip),
    // then by static use count, then vid. When more values are eligible than
    // registers, this spends the 9 GP / 8 FP homes on the runtime-hottest
    // values — including an LICM-hoisted backing pointer used once per
    // innermost iteration, which a flat use-count rank would lose.
    NSComparator byUsesDesc = ^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger da = hotDepth[a].unsignedIntegerValue;
        NSUInteger db = hotDepth[b].unsignedIntegerValue;
        if (da != db) return da > db ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger ca = [uses countForObject:a], cb = [uses countForObject:b];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        // 065: tie-break in the IR TEXT's order, not the creation order. A pass
        // that makes a high-id instruction and inserts it early flips the two,
        // and the port — which reads that text — would tie the other way.
        NSDictionary<NSNumber *, NSNumber *> *di = ctx.denseIdx;
        NSNumber *ta = di[a], *tb = di[b];
        if (ta && tb) return [ta compare:tb];
        return [a compare:b];
    };
    [gp sortUsingComparator:byUsesDesc];
    [fp sortUsingComparator:byUsesDesc];

    NSArray<NSString *> *gpRegs = @[@"x19", @"x20", @"x21", @"x22", @"x23",
                                    @"x24", @"x25", @"x26", @"x27"];
    NSArray<NSString *> *fpRegs = @[@"d8", @"d9", @"d10", @"d11",
                                    @"d12", @"d13", @"d14", @"d15"];
    // Caller-saved GP tier: a value whose range crosses no call may home here
    // with no prologue save. x10-x14 are free (x9 is the large-frame sp-adjust
    // temp; x15-x17 are the load/op/store scratch; x8 is the indirect-result
    // reg). There is no FP caller-saved tier — v0-v15 are FP scratch and v16-v31
    // are the auto-vectoriser's register pool.
    // ...and the ARGUMENT registers on top of that. x0-x7 are dead between
    // calls, and `crossesCall` is computed inclusively (`s <= c && c <= e`), so
    // a value live AT a call — an outgoing argument included — is already
    // excluded from every caller-saved tier. That is what makes these safe
    // despite argument marshalling writing them.
    //
    // PARAMETERS are held out: they arrive in x0-x7, so homing one there makes
    // the prologue's copies a parallel move (param0 in x1 homed to x0 while
    // param1 in x0 homes to x1 clobbers), and the memory-safety trap reporter
    // recovers a parameter's home from the callee-save area, where a
    // caller-saved register never appears.
    //
    // This roughly doubles the GP pool, 14 -> 22. It matters because the top of
    // the remaining benchmark gap is not missing instructions but values that
    // should be in registers and are not: bit_ops spilled both shift results,
    // sort_small round-trips its `&&` result, its index AND its array base
    // through slots on every iteration of the hot loop.
    NSArray<NSString *> *gpCallerRegs = @[@"x10", @"x11", @"x12", @"x13", @"x14"];
    // d16-d31 are caller-saved and belong to the AUTO-VECTORISER's pool — but
    // only in a function that vectorises. One that does not leaves sixteen FP
    // registers unused while its own FP values spill: float_math unrolls four
    // copies of `acc += (double)(a[i] * b[i])`, wants more than the eight
    // callee-saved d8-d15, and the overflow does not merely spill — an unhomed
    // f32 load has no FP scratch at all, so it lands in w17 and bounces through
    // the frame to reach an FP register. Three instructions for one load.
    //
    // Gated on the function having no Vec-typed value anywhere, so the
    // vectoriser's pool is untouched wherever it is in use. crossesCall keeps
    // these off anything live across a call, as it does for x0-x7.
    //
    // d16/d17 stay OUT: they are the FP scratch the load path above uses, and
    // homing a value there produced `fcvt s8, x16` — the scratch was handed to
    // a home and the operand fell back to a GP register. Same split the vector
    // pool uses: v18-v31 home, v16/v17 scratch.
    BOOL fnHasVector = NO;
    for (XTIRBlock *vb in fn.blocks) {
        for (XTIRInsn *vi in vb.instructions)
            if (vi.result && vi.result.type && vi.result.type.kind == XTIRTypeKindVec) { fnHasVector = YES; break; }
        if (fnHasVector) break;
        for (XTIRInsn *vp in vb.phiNodes)
            if (vp.result && vp.result.type && vp.result.type.kind == XTIRTypeKindVec) { fnHasVector = YES; break; }
        if (fnHasVector) break;
    }
    NSArray<NSString *> *fpCallerRegs = fnHasVector ? @[]
        : @[@"d18", @"d19", @"d20", @"d21", @"d22", @"d23",
            @"d24", @"d25", @"d26", @"d27", @"d28", @"d29", @"d30", @"d31"];
    // Tried LAST, after both existing tiers. Ordering is not cosmetic: the
    // preference list is caller-then-callee, so folding these in beside
    // x10-x14 put them ahead of x19-x27 and re-shuffled every allocation the
    // compiler already made. That is a change of a different kind from adding
    // registers, and it cost branch_mix 20% while the extra registers were
    // winning 45% on sieve. Appended at the end, an existing allocation is
    // unchanged and only values that would otherwise get NO register see these.
    NSArray<NSString *> *gpArgTier = @[@"x0", @"x1", @"x2", @"x3",
                                       @"x4", @"x5", @"x6", @"x7"];
    NSUInteger nParams = ctx.fn.paramTypes.count;

    // ── Live-range reuse assignment ──────────────────────────────────
    // Compute live intervals, then assign registers greedily in priority
    // order, letting non-overlapping values SHARE a register. A phi result
    // takes a dedicated (exclusive) register — its register is written by the
    // predecessor-edge copies, whose timing the interval model doesn't track,
    // and the phi-input coalescing pass below threads the back-edge value onto
    // it. A non-phi value may reuse any non-exclusive register whose already-
    // assigned intervals don't overlap its own. This lets an unrolled serial
    // chain (a₀→a₁→…, each dead once the next is computed) pack onto one or two
    // callee-saved registers instead of spilling around the calls between them.
    NSMutableDictionary<NSNumber *, NSNumber *> *startOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *endOf   = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *phiResults = [NSMutableSet set];
    NSMutableSet<NSNumber *> *crossesCall = [NSMutableSet set];
    NSMutableArray<NSNumber *> *rhBlkEnd = [NSMutableArray array];
    [self computeLiveIntervalsForCtx:ctx startOf:startOf endOf:endOf
                          phiResults:phiResults crossesCall:crossesCall
                           blockEnds:rhBlkEnd];

    // Loop-aware START extension, the same soundness fix slot-colouring applies
    // to its own intervals. The intervals above are LINEAR and the CFG is not: a
    // value defined mid-loop and live across the BACK EDGE is live again at
    // EARLIER positions on the next iteration, which [def..end] never covers — so
    // a value confined to that earlier region looks disjoint and would be handed
    // the same register, clobbering the loop-carried one on the next iteration.
    // Register HOMING previously skipped this (only slot colouring did it), so in
    // a large frame a value held across calls (bug 203: the receiver `r` reused
    // across `sample`/`nearest`) was clobbered by a loop-body reuse of its home.
    // Pulling the START back to the loop header makes the interval span the whole
    // loop; only lengthens intervals, so it can remove reuse but never add a
    // clobber. Nested loops fall out by applying it per back edge.
    for (NSUInteger li = 0; li < nb && li < rhBlkEnd.count; li++) {
        XTIRInsn *t = blocks[li].terminator;
        if (!t) continue;
        for (XTIROperand *o in t.operands) {
            if (o.kind != XTIROperandKindBlock || !o.blockRef) continue;
            NSUInteger hb = [blocks indexOfObjectIdenticalTo:o.blockRef];
            if (hb == NSNotFound || hb > li) continue;          // forward edge
            NSInteger loopLo = 2 * (hb == 0 ? 0 : rhBlkEnd[hb - 1].integerValue + 1);
            NSInteger latchEnd = 2 * rhBlkEnd[li].integerValue + 2;
            for (NSNumber *v in startOf.allKeys) {
                if (endOf[v].integerValue < latchEnd) continue;   // not live out of latch
                if (startOf[v].integerValue <= loopLo) continue;  // already spans header
                // ...and it must be DEFINED IN THIS LOOP. Without this a value
                // defined entirely AFTER the loop still matched — its end is
                // past the latch and its start is past the header — and had its
                // start dragged back across a loop it has nothing to do with.
                // With several loops in a function the earliest small one won,
                // so in matrix_mul EVERY value in main started at the same
                // position: every interval overlapped every other, no register
                // could ever be reused, and the allocator degenerated to
                // "the first 22 by rank win, the rest spill".
                if (startOf[v].integerValue > latchEnd) continue;
                startOf[v] = @(loopLo);
            }
        }
    }

    NSMutableArray<NSString *> *saved = [NSMutableArray array];
    NSMutableSet<NSString *> *savedSet = [NSMutableSet set];
    // Two tiers: caller-saved first (no prologue save), then callee-saved. A
    // value that crosses a call may only use callee-saved. Only callee-saved
    // homes are recorded in `saved` for prologue/epilogue.
    void (^assign)(NSArray<NSNumber *> *, NSArray<NSString *> *, NSArray<NSString *> *,
                   NSArray<NSString *> *) =
        ^(NSArray<NSNumber *> *cands, NSArray<NSString *> *callee, NSArray<NSString *> *caller,
          NSArray<NSString *> *argTier) {
        NSMutableArray<NSString *> *regs = [NSMutableArray arrayWithArray:caller];
        [regs addObjectsFromArray:argTier];
        [regs addObjectsFromArray:callee];
        NSMutableArray<NSString *> *callerAll = [NSMutableArray arrayWithArray:caller];
        [callerAll addObjectsFromArray:argTier];
        NSSet<NSString *> *callerSet = [NSSet setWithArray:callerAll];
        NSSet<NSString *> *gpArgRegs = [NSSet setWithArray:argTier];
        NSUInteger nr = regs.count;
        NSMutableArray<NSMutableArray<NSValue *> *> *regIvls = [NSMutableArray array];
        NSMutableArray<NSNumber *> *exclusive = [NSMutableArray array];
        for (NSUInteger i = 0; i < nr; i++) { [regIvls addObject:[NSMutableArray array]]; [exclusive addObject:@NO]; }
        for (NSNumber *v in cands) {
            NSInteger s = startOf[v] ? startOf[v].integerValue : 0;
            NSInteger e = endOf[v]   ? endOf[v].integerValue   : s;
            BOOL isPhi = [phiResults containsObject:v];
            BOOL mayUseCaller = ![crossesCall containsObject:v];
            BOOL isParam = v.integerValue >= 0 && (NSUInteger)v.integerValue < nParams;
            NSInteger chosen = -1;
            for (NSUInteger r = 0; r < nr; r++) {
                if (!mayUseCaller && [callerSet containsObject:regs[r]]) continue;
                if (isParam && [gpArgRegs containsObject:regs[r]]) continue;
                if (exclusive[r].boolValue) continue;
                if (isPhi) { if (regIvls[r].count == 0) { chosen = (NSInteger)r; break; } continue; }
                BOOL ok = YES;
                for (NSValue *iv in regIvls[r]) {
                    NSRange rg = iv.rangeValue;
                    NSInteger s2 = (NSInteger)rg.location, e2 = s2 + (NSInteger)rg.length;
                    if (s <= e2 && s2 <= e) { ok = NO; break; }
                }
                if (ok) { chosen = (NSInteger)r; break; }
            }
            if (chosen < 0) {
                if (getenv("XTREGDBG") && hotDepth[v].unsignedIntegerValue >= (NSUInteger)atoi(getenv("XTREGDBG")))
                    fprintf(stderr, "  UNHOMED %%%ld depth=%lu uses=%lu ivl=[%ld,%ld]\n",
                            (long)v.integerValue,
                            (unsigned long)hotDepth[v].unsignedIntegerValue,
                            (unsigned long)[uses countForObject:v], (long)s, (long)e);
                continue;              // unhomed → stays in its slot
            }
            if (getenv("XTREGDBG") && hotDepth[v].unsignedIntegerValue >= (NSUInteger)atoi(getenv("XTREGDBG")))
                fprintf(stderr, "  homed   %%%ld -> %s depth=%lu uses=%lu ivl=[%ld,%ld]\n",
                        (long)v.integerValue, regs[chosen].UTF8String,
                        (unsigned long)hotDepth[v].unsignedIntegerValue,
                        (unsigned long)[uses countForObject:v], (long)s, (long)e);
            ctx.homeReg[v] = regs[chosen];
            [regIvls[chosen] addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)s, (NSUInteger)(e - s))]];
            if (isPhi) exclusive[chosen] = @YES;
            if (![callerSet containsObject:regs[chosen]] && ![savedSet containsObject:regs[chosen]]) {
                [savedSet addObject:regs[chosen]]; [saved addObject:regs[chosen]];
            }
        }
    };
    if (getenv("XTREGDBG")) fprintf(stderr, "== %s\n", ctx.fn.name.UTF8String);
    assign(gp, gpRegs, gpCallerRegs, gpArgTier);
    assign(fp, fpRegs, fpCallerRegs, @[]);
    // Stable callee-save order (prologue/epilogue iterate this array together).
    [saved sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ia = [gpRegs indexOfObject:a]; if (ia == NSNotFound) ia = 100 + [fpRegs indexOfObject:a];
        NSUInteger ib = [gpRegs indexOfObject:b]; if (ib == NSNotFound) ib = 100 + [fpRegs indexOfObject:b];
        return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
    }];
    ctx.savedRegs = saved;

    // ── Phi-input coalescing ─────────────────────────────────────────
    // A loop-carried accumulator (`v = phi op x`) computes the new value v in
    // scratch, spills it, and the back-edge phi copy reloads it into the
    // phi's home R — a spill + reload every iteration (and, when v crosses a
    // call, a spill across the call too). Assign v the SAME home R as its
    // phi: v is produced directly into R, and the back-edge copy `R = v`
    // collapses to the no-op emitMove R,R the phi emitter already elides.
    // Pure allocation — no emit change.
    //
    // Soundness rests on register liveness, not SSA liveness. Within the loop
    // body, R holds the current-iteration value P up to the instruction that
    // makes v (`v = P op x`, reading P then writing R), after which P must not
    // be read again IN THE BODY — else the new value in R would be seen as P.
    // A use of P OUTSIDE the body is a loop-exit read of the carried value;
    // after the loop R holds the final v (== the SSA loop-closed value, or the
    // entry value on a zero-trip loop), so those reads are satisfied by R too.
    // Hence the gate is: P's last use *within blocks [ti..si]* <= def(v), with
    // v defined inside the body, unhomed, scalar, same register class, not
    // address-taken. (The earlier whole-function lastUse(P) check wrongly
    // counted the loop-exit use and so missed call-crossing accumulators.)
    NSMutableDictionary<NSNumber *, NSNumber *> *defPos = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *defBlk = [NSMutableDictionary dictionary];
    // value → list of @[blockIndex, pos] for each use.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSArray<NSNumber *> *> *> *uloc =
        [NSMutableDictionary dictionary];
    __block NSInteger pos = 0;
    for (NSUInteger bi = 0; bi < nb; bi++) {
        XTIRBlock *b = blocks[bi];
        void (^rec)(XTIRInsn *) = ^(XTIRInsn *insn) {
            if (insn.result) {
                defPos[@(insn.result.valueId)] = @(pos);
                defBlk[@(insn.result.valueId)] = @(bi);
            }
            for (XTIROperand *o in insn.operands) {
                if (o.kind != XTIROperandKindUse) continue;
                NSMutableArray *a = uloc[@(o.valueId)];
                if (!a) { a = [NSMutableArray array]; uloc[@(o.valueId)] = a; }
                [a addObject:@[@(bi), @(pos)]];
            }
            pos++;
        };
        for (XTIRInsn *phi in b.phiNodes) rec(phi);
        for (XTIRInsn *insn in b.instructions) rec(insn);
        if (b.terminator) rec(b.terminator);
    }
    NSMutableSet<NSNumber *> *coalesced = [NSMutableSet set];
    for (NSUInteger si = 0; si < nb; si++) {
        XTIRInsn *term = blocks[si].terminator;
        if (!term) continue;
        for (XTIROperand *toOp in term.operands) {
            if (toOp.kind != XTIROperandKindBlock || !toOp.blockRef) continue;
            NSUInteger ti = [blocks indexOfObjectIdenticalTo:toOp.blockRef];
            if (ti == NSNotFound || ti > si) continue;   // not a back-edge
            XTIRBlock *header = blocks[ti], *backSrc = blocks[si];
            for (XTIRInsn *phi in header.phiNodes) {
                if (!phi.result) continue;
                if ([coalesced containsObject:@(phi.result.valueId)]) continue;
                NSString *R = ctx.homeReg[@(phi.result.valueId)];
                if (!R) continue;                          // phi not homed
                // The phi operand value paired with the back-edge source.
                XTIRValueId vIn = 0; BOOL found = NO;
                for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2) {
                    XTIROperand *bo = phi.operands[k], *vo = phi.operands[k + 1];
                    if (bo.kind == XTIROperandKindBlock && bo.blockRef == backSrc
                        && vo.kind == XTIROperandKindUse) {
                        vIn = vo.valueId; found = YES; break;
                    }
                }
                if (!found || vIn == phi.result.valueId) continue;
                // v may already hold its own home register: re-home it onto the
                // phi's R (R is exclusive to the phi, so nothing else contends).
                // Skip if it is already R, or if v is itself a phi result — that
                // is a nested loop-carried accumulator (the outer phi's back-edge
                // value is the inner phi), and stealing its register just pushes
                // the copy inward.
                NSString *vHome = ctx.homeReg[@(vIn)];
                if (vHome) {
                    if ([vHome isEqualToString:R]) continue;
                    if ([phiResults containsObject:@(vIn)]) continue;
                }
                if ([addrTaken containsObject:@(vIn)]) continue;
                XTIRValue *vv = [fn valueForId:vIn];
                if (!vv || !vv.type) continue;
                XTIRTypeKind vk = vv.type.kind;
                if (vk == XTIRTypeKindMemory || vk == XTIRTypeKindAgg
                    || vk == XTIRTypeKindVoid) continue;
                BOOL homeFP = [R hasPrefix:@"d"] || [R hasPrefix:@"s"];
                if (homeFP != XTIRTypeKindIsFloating(vk)) continue;
                NSNumber *db = defBlk[@(vIn)];
                if (!db) continue;
                // v must be defined inside the loop body [ti..si].
                if (db.unsignedIntegerValue < ti || db.unsignedIntegerValue > si) continue;
                // PRECISE interference: v may share the phi's register iff their
                // SSA live intervals do not overlap. With the doubled-position
                // model (interval [2·def+1, 2·lastUse]), the back-edge value
                // `v = P op x` is defined exactly at P's last read, so v.start =
                // 2p+1 > P.end = 2p → disjoint → the induction / accumulator
                // coalesces; a value still live past the step (a pointer whose
                // OLD value is dereferenced after `p = p.next`) overlaps P and is
                // rejected — which the earlier coarse block-position gate missed,
                // mis-coalescing pointer-walker / for-in loops.
                NSNumber *pS = startOf[@(phi.result.valueId)], *pE = endOf[@(phi.result.valueId)];
                NSNumber *vS = startOf[@(vIn)], *vE = endOf[@(vIn)];
                if (!pS || !pE || !vS || !vE) continue;
                NSInteger ps = pS.integerValue, pe = pE.integerValue;
                NSInteger vs = vS.integerValue, ve = vE.integerValue;
                if (vs <= pe && ps <= ve) continue;           // intervals overlap → unsafe
                // A caller-saved phi home is only safe for v if v also crosses no
                // call — a call after the phi's last body use (so the phi is
                // caller-saved) can still sit inside v's [def..back-edge] range.
                if ([crossesCall containsObject:@(vIn)]
                    && ([gpCallerRegs containsObject:R] || [fpCallerRegs containsObject:R])) continue;
                ctx.homeReg[@(vIn)] = R;                       // coalesce
                [coalesced addObject:@(phi.result.valueId)];
            }
        }
    }
    // Checked build: record where this function's PARAMETERS live.
    //
    // HERE, at the end of register allocation — not in buildSlotTableForCtx,
    // where this started. homeReg is created and filled by THIS method, so
    // sampling it earlier saw an empty map: every parameter looked
    // frame-resident, and the reporter printed whatever else happened to be at
    // that offset. readAt keeps both of its parameters in x19/x20 and spills
    // neither, so the trace confidently said arg0=0x0 arg1=0., so the trap
    // reporter can read them back out of a walked frame. A param the allocator
    // homed in a register has no frame slot to read — recorded as unavailable
    // rather than as a stale slot value, because a confident wrong argument is
    // worse than an absent one (private:docs/Design/memory-safety.md §4).
}

// Emit the callee-saved register save (or restore) block, pairing adjacent
// same-class registers into a single stp/ldp the way clang does — one memory
// instruction for two registers instead of two. The save area lays each reg at
// saveAreaOffset + 8*i (8-byte slots, 8-aligned), exactly the stp/ldp two-slot
// layout. Pairing needs both regs the same class (two X or two D — stp can't mix)
// and the base offset within the stp/ldp scaled-imm7 reach (≤ 504); otherwise the
// reg falls back to a single str/ldr. On every prologue/epilogue, so it pays off
// most in call-heavy / recursive code.
+ (void)emitCalleeSaves:(NSArray<NSString *> *)regs
                   base:(NSUInteger)base
                 toBuf:(NSMutableString *)out
                restore:(BOOL)restore {
    NSString *pair = restore ? @"ldp" : @"stp";
    NSString *one  = restore ? @"ldr" : @"str";
    NSUInteger n = regs.count;
    for (NSUInteger i = 0; i < n; ) {
        NSString *r0 = regs[i];
        NSUInteger off = base + 8 * i;
        BOOL r0fp = [r0 hasPrefix:@"d"] || [r0 hasPrefix:@"s"];
        if (i + 1 < n && off <= 504) {
            NSString *r1 = regs[i + 1];
            BOOL r1fp = [r1 hasPrefix:@"d"] || [r1 hasPrefix:@"s"];
            if (r0fp == r1fp) {
                [out appendFormat:@"    %@ %@, %@, [sp, #%lu]\n", pair, r0, r1, (unsigned long)off];
                i += 2; continue;
            }
        }
        // Past the pair range — and, in a big frame, possibly past the single
        // scaled range too (the save area sits ABOVE the value slots; x/d
        // scaled immediates reach 32760). Stage the address in x9 then, the
        // same materialisation emitSpAddr uses — inline because this function
        // writes to its own buffer, not ctx.out.
        if (off <= 32760) {
            [out appendFormat:@"    %@ %@, [sp, #%lu]\n", one, r0, (unsigned long)off];
        } else {
            if ((off & 0xFFF) == 0 && (off >> 12) <= 4095) {
                [out appendFormat:@"    add x9, sp, #%lu, lsl #12\n", (unsigned long)(off >> 12)];
            } else {
                [out appendFormat:@"    mov w9, #%lu\n", (unsigned long)(off & 0xFFFF)];
                if (off > 0xFFFF)
                    [out appendFormat:@"    movk w9, #%lu, lsl #16\n", (unsigned long)(off >> 16)];
                [out appendString:@"    add x9, sp, x9\n"];
            }
            [out appendFormat:@"    %@ %@, [x9]\n", one, r0];
        }
        i += 1;
    }
}

// The width-correct view of a homed value's canonical register, sized to
// the value's IR type. GP home ("x19") → "x19" for pointers (8 bytes) /
// "w19" for ≤4-byte integers; FP home ("d8") → "d8" for F64 / "s8" for F32.
+ (NSString *)homeView:(NSString *)canon forType:(XTIRType *)ty {
    NSString *num = [canon substringFromIndex:1];
    if ([canon hasPrefix:@"d"] || [canon hasPrefix:@"s"]) {   // FP home
        BOOL dbl = ty && ty.kind == XTIRTypeKindF64;
        return [(dbl ? @"d" : @"s") stringByAppendingString:num];
    }
    return [([self irTypeNeedsXReg:ty] ? @"x" : @"w") stringByAppendingString:num];
}

// Move src → dst, picking the right mnemonic from the register classes:
// GP↔GP `mov`, FP↔FP / GP↔FP `fmov` (the assembler's fmov covers d↔x and
// s↔w when widths match — callers ensure the width pairing). A no-op when
// the registers are identical.
+ (void)emitMove:(NSString *)dst from:(NSString *)src ctx:(XTArm64FnCtx *)ctx {
    if ([dst isEqualToString:src]) return;
    BOOL dFP = [dst hasPrefix:@"s"] || [dst hasPrefix:@"d"];
    BOOL sFP = [src hasPrefix:@"s"] || [src hasPrefix:@"d"];
    if (dFP || sFP) { [ctx.out appendFormat:@"    fmov %@, %@\n", dst, src]; return; }
    // GP move. `mov x,w` / `mov w,x` are illegal; when the home widths differ
    // (a narrow value read into a wide scratch, or a wide value into a narrow
    // dest — both arise now that more values are register-homed) move in
    // w-form: writing w<n> zero-extends the low 32 bits into the full x<n>,
    // which is the right semantics for an unsigned-narrow→wide widen and for a
    // wide→narrow low-word read.
    BOOL dX = [dst hasPrefix:@"x"], sX = [src hasPrefix:@"x"];
    if (dX != sX) {
        NSString *wd = dX ? [@"w" stringByAppendingString:[dst substringFromIndex:1]] : dst;
        NSString *ws = sX ? [@"w" stringByAppendingString:[src substringFromIndex:1]] : src;
        if ([wd isEqualToString:ws]) return;
        [ctx.out appendFormat:@"    mov %@, %@\n", wd, ws];
    } else {
        [ctx.out appendFormat:@"    mov %@, %@\n", dst, src];
    }
}

// Return the register that, after this call, holds `op`'s value WITHOUT a
// load when possible: a homed Use returns its home register directly (no
// instruction emitted); anything else is materialised into `scratch` and
// `scratch` is returned. Op sites use the returned register as a source
// operand, so a homed value is read in-place (`add w16, w19, ...`).
+ (NSString *)operandReg:(XTIROperand *)op
             intoScratch:(NSString *)scratch
                     ctx:(XTArm64FnCtx *)ctx {
    if (op.kind == XTIROperandKindUse) {
        NSString *canon = ctx.homeReg[@(op.valueId)];
        if (canon) {
            return [self homeView:canon
                          forType:[ctx.fn valueForId:op.valueId].type];
        }
    }
    [self materialiseOperand:op intoReg:scratch ctx:ctx];
    return scratch;
}

// If `op` is an immediate (or a use of a Const integer value) whose value v
// fits the arm64 unsigned imm12 form 0 ≤ v ≤ 4095 used by add/sub/cmp, return
// @(v); else nil. Lets an `i + 1` / `i < 1000` fold its constant straight into
// the instruction instead of materialising it into a scratch register first
// (saves the per-iteration `mov #imm` — and on a loop-control compare, shortens
// the dependency feeding the branch). The constant is rematerialised per use by
// the backend anyway, so eliding it here has no liveness effect.
// The `#N, lsl #12` form of the same imm12 field: add/sub/cmp can take a
// 12-bit immediate shifted left by 12, so a constant that is a multiple of 4096
// and no wider than 24 bits is still a single instruction. Without this a loop
// bound of exactly 4096 — the common case, an array length — fell off the imm12
// cliff at 4095 and materialised through `mov` into a register on the
// loop-control path. Returns the operand text ("1, lsl #12") or nil.
+ (NSString *)imm12ShiftedForOperand:(XTIROperand *)op ctx:(XTArm64FnCtx *)ctx {
    int64_t v;
    if (op.kind == XTIROperandKindImmI) {
        v = op.intValue;
    } else if (op.kind == XTIROperandKindUse) {
        XTIRInsn *d = ctx.defOf[@(op.valueId)];
        if (!d || d.opcode != XTIROpConst || d.operands.count < 1 ||
            d.operands[0].kind != XTIROperandKindImmI) return nil;
        v = d.operands[0].intValue;
    } else {
        return nil;
    }
    if (v <= 4095 || (v & 0xFFF) != 0) return nil;
    int64_t hi = v >> 12;
    if (hi > 4095) return nil;
    return [NSString stringWithFormat:@"%lld, lsl #12", (long long)hi];
}

// Is `v` encodable as an AArch64 logical immediate (the and/orr/eor bitmask
// form)? The field encodes a value that repeats with some period e in
// {2,4,8,16,32,64}, where one period is a rotation of a contiguous run of ones.
// 0x0F0F0F0F is such a value — e = 8, four ones — and clang emits it as
// `eor w0, w1, #0xf0f0f0f`, where this backend materialised the constant with
// movz/movk into a register first. All-zeros and all-ones are not encodable.
static BOOL arm64LogicalImm(uint64_t v, int width) {
    if (width != 32 && width != 64) return NO;
    uint64_t wmask = (width == 64) ? ~0ULL : 0xFFFFFFFFULL;
    v &= wmask;
    if (v == 0 || v == wmask) return NO;
    for (int e = 2; e <= width; e <<= 1) {
        uint64_t emask = (e == 64) ? ~0ULL : ((1ULL << e) - 1);
        uint64_t lo = v & emask;
        // v must be `lo` repeated at period e.
        BOOL repeats = YES;
        for (int off = e; off < width; off += e)
            if (((v >> off) & emask) != lo) { repeats = NO; break; }
        if (!repeats) continue;
        if (lo == 0 || lo == emask) continue;           // not encodable at this e
        // Rotate lo so its ones start at bit 0, then require a contiguous run.
        int tz = 0;
        while (((lo >> tz) & 1ULL) == 0) tz++;
        uint64_t rot = ((lo >> tz) | (lo << (e - tz))) & emask;
        if (((rot + 1) & rot) == 0) return YES;         // rot is 0b0..01..1
    }
    return NO;
}

+ (NSNumber *)imm12ForOperand:(XTIROperand *)op ctx:(XTArm64FnCtx *)ctx {
    int64_t v;
    if (op.kind == XTIROperandKindImmI) {
        v = op.intValue;
    } else if (op.kind == XTIROperandKindUse) {
        XTIRInsn *d = ctx.defOf[@(op.valueId)];
        if (!d || d.opcode != XTIROpConst || d.operands.count < 1 ||
            d.operands[0].kind != XTIROperandKindImmI) return nil;
        v = d.operands[0].intValue;
    } else {
        return nil;
    }
    if (v < 0 || v > 4095) return nil;
    return @(v);
}

// The register an op should write its result into: the result's home
// register if homed (so the op emits straight into it, no store), else
// `scratch` (which the caller then stores via storeReg:).
+ (NSString *)resultReg:(XTIRValueId)vid
                scratch:(NSString *)scratch
                    ctx:(XTArm64FnCtx *)ctx {
    NSString *canon = ctx.homeReg[@(vid)];
    if (canon) return [self homeView:canon forType:[ctx.fn valueForId:vid].type];
    return scratch;
}

// Adjust SP by `delta` bytes (negative = grow the frame). `sub`/`add`
// take an imm12 (≤ 4095); beyond that, build the amount in scratch
// x9 (free at prologue/epilogue — params are still in their argument
// registers, the return value is already in x0/s0). delta is always
// a multiple of 16.
+ (void)emitSpAdjust:(NSInteger)delta ctx:(XTArm64FnCtx *)ctx {
    NSString *mnem = delta < 0 ? @"sub" : @"add";
    NSUInteger mag = (NSUInteger)(delta < 0 ? -delta : delta);
    if (mag <= 4095) {
        [ctx.out appendFormat:@"    %@ sp, sp, #%lu\n", mnem, (unsigned long)mag];
    } else {
        [self materialiseImm64:(uint64_t)mag intoXReg:@"x9" ctx:ctx];
        [ctx.out appendFormat:@"    %@ sp, sp, x9\n", mnem];
    }
}

// Returns YES when the IR type is wider than 4 bytes (Ptr on arm64
// is 8 bytes) and therefore needs x-register access. Memory tokens
// also report YES so that the parameter-spill loop skips them
// cleanly — they never get loaded / stored anyway.
+ (BOOL)irTypeNeedsXReg:(XTIRType *)ty {
    if (!ty) return NO;
    switch (ty.kind) {
        case XTIRTypeKindPtr:
        case XTIRTypeKindMemory:
        // A 64-bit integer occupies a full X register, and the arithmetic
        // mnemonics are the same at both widths — so naming the register `x`
        // is most of what i64/u64 need on this target.
        case XTIRTypeKindI64:
        case XTIRTypeKindU64:
            return YES;
        default:
            return NO;
    }
}

// The scratch a branch or select condition is tested in: x16 for a pointer
// or a 64-bit integer, w16 otherwise. A condition is true when ANY of its bits
// is set, so a 64-bit one tested in w16 read `1 << 32`, or a pointer whose low
// 32 bits are zero, as false (bug 293).
+ (NSString *)condRegForOperand:(XTIROperand *)c ctx:(XTArm64FnCtx *)ctx {
    XTIRType *vt = (c.kind == XTIROperandKindUse)
        ? [ctx.fn valueForId:c.valueId].type : c.type;
    return [self irTypeNeedsXReg:vt] ? @"x16" : @"w16";
}

// Pick the integer-register name for `scratch` (16 or 17) sized to
// `ty`. Returns w16/w17 for narrow integers, x16/x17 for pointers.
+ (NSString *)regName:(int)scratch forType:(XTIRType *)ty {
    return [self irTypeNeedsXReg:ty]
        ? [NSString stringWithFormat:@"x%d", scratch]
        : [NSString stringWithFormat:@"w%d", scratch];
}

// arm64-native width of an aggregate FIELD. The shared XTIRLayout
// sizes fields with AST/Atari widths (pointer = 2 bytes), but arm64
// uses 64-bit host pointers — storing one into a 2-byte ivar slot
// truncates it. So arm64 owns its own field widths: pointer = 8,
// F32 = 4 (IEEE single), F64 = 8, integers natural, Agg recursive.
+ (NSUInteger)arm64FieldWidth:(XTIRType *)t {
    if (!t) return 0;
    switch (t.kind) {
        case XTIRTypeKindPtr:   return 8;   // host pointer
        case XTIRTypeKindF64:   return 8;
        case XTIRTypeKindF32:   return 4;
        case XTIRTypeKindI32:
        case XTIRTypeKindU32:   return 4;
        case XTIRTypeKindI64:
        case XTIRTypeKindU64:   return 8;
        case XTIRTypeKindI16:
        case XTIRTypeKindU16:   return 2;
        case XTIRTypeKindI8:
        case XTIRTypeKindU8:
        case XTIRTypeKindBool:  return 1;
        case XTIRTypeKindAgg:   return [self arm64AggSize:t.layout];
        default:                return 0;   // Void / Memory
    }
}

// arm64-native total size of an aggregate layout (sum of its fields'
// arm64 widths). Used wherever arm64 needs an Agg's byte size
// (FieldAddr offsets, struct-global data emission, MemCopy).
+ (NSUInteger)arm64AggSize:(XTIRLayout *)layout {
    if (!layout) return 0;
    NSUInteger total = 0;
    for (XTIRLayoutField *f in layout.fields) {
        total += [self arm64FieldWidth:f.type];
    }
    // A field-less aggregate (e.g. the varargs buffer `__xtc_va_buf`, or
    // any opaque byte buffer) carries its byte count in layout.size with
    // no fields to sum — so never size below the declared layout size.
    // For a pointer-bearing struct the arm64 field sum (8-byte pointers)
    // exceeds the shared 2-byte-pointer layout.size, so the sum still wins.
    if (total < layout.size) total = layout.size;
    return total;
}

// AAPCS homogeneous floating-point aggregate (HFA): a struct whose every leaf —
// recursing through nested aggregates — is the SAME float or double type, with 1
// to 4 leaves total. Such a return/arg travels in consecutive v-registers
// (d0..d3 / s0..s3), NOT x0:x1 or an x8 sret. NSPoint/NSSize (2 doubles) and
// NSRect (4 doubles) are HFAs; that is how Cocoa hands back `-frame` &c.
// Returns the leaf count (1-4) and writes the leaf kind to *outKind, or 0 if the
// layout is not an HFA (a non-float leaf, mixed float widths, or >4 leaves).
+ (NSUInteger)arm64AggHFA:(XTIRLayout *)layout elemKind:(XTIRTypeKind *)outKind {
    if (!layout || layout.fields.count == 0) return 0;
    XTIRTypeKind ek = XTIRTypeKindVoid;
    NSUInteger count = 0;
    for (XTIRLayoutField *f in layout.fields) {
        XTIRType *ft = f.type;
        XTIRTypeKind leaf;
        NSUInteger n;
        if (ft.kind == XTIRTypeKindAgg) {
            n = [self arm64AggHFA:ft.layout elemKind:&leaf];
            if (n == 0) return 0;                       // nested non-HFA → not an HFA
        } else if (XTIRTypeKindIsFloating(ft.kind)) {
            leaf = ft.kind; n = 1;
        } else {
            return 0;                                   // a non-float leaf → not an HFA
        }
        if (ek == XTIRTypeKindVoid) ek = leaf;
        else if (ek != leaf) return 0;                  // mixed float/double → not an HFA
        count += n;
        if (count > 4) return 0;
    }
    if (count == 0 || count > 4) return 0;
    // Guard against trailing padding that would break the register mapping: the
    // element count must account for the whole aggregate.
    NSUInteger esz = XTIRTypeKindIsFloating(ek) && ek == XTIRTypeKindF64 ? 8 : 4;
    if ([self arm64AggSize:layout] != count * esz) return 0;
    if (outKind) *outKind = ek;
    return count;
}

// Byte offset of field `idx` within `layout` — the RECORDED offset. The
// front end lays fields out once (with the per-target field-alignment cap,
// blewit #5) and every backend reads the same offsets, so FE and backend
// cannot disagree. The historical prefix-sum of arm64 widths only ever
// matched because both sides packed tightly; with natural alignment the
// recorded offset is the single source of truth. Leaf widths still must
// match the FE's (the type-width invariant) or loads/stores are mis-sized.
+ (NSUInteger)arm64FieldOffset:(XTIRLayout *)layout index:(NSUInteger)idx {
    if (idx >= layout.fields.count) return [self arm64AggSize:layout];
    return layout.fields[idx].byteOffset;
}

#pragma mark - Block labels

+ (NSString *)blockLabelForFn:(XTIRFunction *)fn block:(XTIRBlock *)block {
    return [NSString stringWithFormat:@"L%@_%@", fn.name, block.name ?: @"bb_?"];
}

#pragma mark - Type canonicalization

// After a 32-bit op produces `wN`, re-canonicalise its bits so the
// in-memory representation matches the IR type's range.
+ (void)canonicaliseReg:(NSString *)reg toType:(XTIRType *)ty ctx:(XTArm64FnCtx *)ctx {
    if (!ty) return;
    switch (ty.kind) {
        case XTIRTypeKindI8:    [ctx.out appendFormat:@"    sxtb %@, %@\n", reg, reg]; break;
        case XTIRTypeKindU8:
        case XTIRTypeKindBool:  [ctx.out appendFormat:@"    uxtb %@, %@\n", reg, reg]; break;
        case XTIRTypeKindI16:   [ctx.out appendFormat:@"    sxth %@, %@\n", reg, reg]; break;
        case XTIRTypeKindU16:   [ctx.out appendFormat:@"    uxth %@, %@\n", reg, reg]; break;
        default: break;        // I32/U32: no extra; everything else unsupported
    }
}

// The single AArch64 extend instruction that canonicalises a value to
// `ty` (combining a move with the sign/zero-extension), or nil for I32/U32
// where no extension is needed (a plain move suffices). Lets a cast emit
// `uxth Wd, Wn` straight from source to destination instead of a separate
// `mov`+`uxth` pair.
+ (nullable NSString *)integerExtendMnemonicForType:(XTIRType *)ty {
    if (!ty) return nil;
    switch (ty.kind) {
        case XTIRTypeKindI8:    return @"sxtb";
        case XTIRTypeKindU8:
        case XTIRTypeKindBool:  return @"uxtb";
        case XTIRTypeKindI16:   return @"sxth";
        case XTIRTypeKindU16:   return @"uxth";
        default:                return nil;   // I32/U32: no extend
    }
}

// FP register name for an IR float type: single (s) for F32,
// double (d) for F64. The 8-byte stack slot holds either.
+ (NSString *)fregName:(int)n forType:(XTIRType *)ty {
    BOOL isDouble = ty && ty.kind == XTIRTypeKindF64;
    return [NSString stringWithFormat:@"%@%d", isDouble ? @"d" : @"s", n];
}

// YES if `insn` is an integer/bool `Const #0` — i.e. its value is the zero
// register (wzr/xzr), so a consumer can store it without materialising a reg.
+ (BOOL)isIntZeroConst:(nullable XTIRInsn *)insn {
    if (!insn || insn.opcode != XTIROpConst || !insn.result) return NO;
    if (XTIRTypeKindIsFloating(insn.result.type.kind)) return NO;
    if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindImmI) return NO;
    return insn.operands[0].intValue == 0;
}

#pragma mark - Load / store helpers

// Read a value into `reg`. A homed value is moved from its home register
// (the slot is never written for homed values, so a slot load would be
// stale); an unhomed value is loaded from its stack slot. GP↔FP and width
// pairing is handled by emitMove:/homeView:.
// A non-homed integer `Const` whose value materialises in a single `mov #imm`
// that is already canonical for its (unsigned) type — so a use can rematerialise
// it inline instead of round-tripping through a stack slot, and its slot def can
// be elided. Unsigned-only: `mov w,#v` with v ≤ typeMax needs no uxt, whereas a
// signed type's sxt could differ from the raw immediate. Returns the immediate
// in *outImm (NULL to just test).
+ (BOOL)rematConst:(XTIRValueId)vid imm:(nullable int64_t *)outImm ctx:(XTArm64FnCtx *)ctx {
    if (ctx.homeReg[@(vid)]) return NO;                 // homed → read the home reg
    XTIRInsn *d = ctx.defOf[@(vid)];
    if (!d || d.opcode != XTIROpConst || !d.result) return NO;
    XTIRTypeKind k = d.result.type.kind;
    if (k != XTIRTypeKindU8 && k != XTIRTypeKindU16 &&
        k != XTIRTypeKindU32 && k != XTIRTypeKindBool) return NO;
    if (d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmI) return NO;
    int64_t v = d.operands[0].intValue;
    uint64_t max = MIN(0xFFFFULL, [self unsignedTypeMax:d.result.type]);   // single-mov & in-range
    if (v < 0 || (uint64_t)v > max) return NO;
    if (outImm) *outImm = v;
    return YES;
}

+ (void)loadValue:(XTIRValueId)vid intoReg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    NSString *canon = ctx.homeReg[@(vid)];
    if (canon) {
        [self emitMove:reg
                  from:[self homeView:canon forType:[ctx.fn valueForId:vid].type]
                   ctx:ctx];
        return;
    }
    int64_t imm;
    if ([self rematConst:vid imm:&imm ctx:ctx]) {
        [ctx.out appendFormat:@"    mov %@, #%lld\n", reg, imm];
        return;
    }
    [ctx.out appendFormat:@"    ldr %@, %@\n",
     reg, [self spMemForOff:[self slotOffsetForValue:vid ctx:ctx] reg:reg ctx:ctx]];
}

// Commit `reg` as the value's definition. A homed value's result lives in
// its home register: move `reg` there (a no-op when the op already emitted
// straight into the home via resultReg:). An unhomed value spills to its
// slot. This is the chokepoint that makes every result site correct
// regardless of whether the op was rewritten to target the home directly.
+ (void)storeReg:(NSString *)reg intoValue:(XTIRValueId)vid ctx:(XTArm64FnCtx *)ctx {
    NSString *canon = ctx.homeReg[@(vid)];
    if (canon) {
        [self emitMove:[self homeView:canon forType:[ctx.fn valueForId:vid].type]
                  from:reg ctx:ctx];
        return;
    }
    [ctx.out appendFormat:@"    str %@, %@\n",
     reg, [self spMemForOff:[self slotOffsetForValue:vid ctx:ctx] reg:reg ctx:ctx]];
}

// Number of consecutive 64-bit GP registers an aggregate argument
// occupies under AAPCS (one per 8 bytes, rounded up). Used by both the
// caller arg-marshal and callee param-spill so a by-value struct ≤16
// bytes rides x{n}..x{n+1} consistently on both sides.
+ (NSUInteger)gpRegsForAgg:(XTIRType *)ty {
    NSUInteger sz = [self arm64AggSize:ty.layout];
    return (sz + 7) / 8;
}

// Store GP register `reg` into the value's stack slot at `+off` bytes.
+ (void)storeReg:(NSString *)reg intoValue:(XTIRValueId)vid
          offset:(NSUInteger)off ctx:(XTArm64FnCtx *)ctx {
    NSUInteger o = [self slotOffsetForValue:vid ctx:ctx] + off;
    [ctx.out appendFormat:@"    str %@, %@\n",
     reg, [self spMemForOff:o reg:reg ctx:ctx]];
}

// Load GP register `reg` from the value's stack slot at `+off` bytes.
+ (void)loadValue:(XTIRValueId)vid offset:(NSUInteger)off
          intoReg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    NSUInteger o = [self slotOffsetForValue:vid ctx:ctx] + off;
    [ctx.out appendFormat:@"    ldr %@, %@\n",
     reg, [self spMemForOff:o reg:reg ctx:ctx]];
}

// The frame-slot addressing operand for a load/store of `reg` at [sp + off].
// `ldr/str <reg>, [sp, #off]`'s scaled immediate tops out at 16380 for a w/s
// view and 32760 for x/d — which is what the old 16 KB FRAME BUDGET protected.
// Past the encodable range the address is STAGED (the same materialisation
// emitSpAddr does) and the access goes register-indirect, so a large frame is
// merely slower at its far end rather than a compile error (fuzz seeds
// 95/165/267: valid programs refused at the DEFAULT -O3, or at -O0 outright).
// x9 is the staging register — the prologue's large-frame temp, free during
// body emission — except when x9/w9 itself carries the data, where x16 (never
// a data register at these chokepoints' call sites) stands in.
+ (NSString *)spMemForOff:(NSUInteger)off reg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    NSUInteger max = ([reg hasPrefix:@"w"] || [reg hasPrefix:@"s"]) ? 16380 : 32760;
    if (off <= max) return [NSString stringWithFormat:@"[sp, #%lu]", (unsigned long)off];
    // Out of range stays sp-relative HERE on purpose: the peepholes parse
    // `[sp, #off]` and nothing else, so emitting another base register now
    // would hide the slot from store-to-load forwarding and dead-store removal
    // (measured: doing that made int_accum and bit_ops worse, not better).
    // expandStagedSlots picks the real form once the peepholes have run.
    return [NSString stringWithFormat:@"[sp, #%lu]", (unsigned long)off];
}

// Emit `add <reg>, sp, #<off>` safely. The add immediate is 12-bit (0-4095,
// optionally <<12), so a slot high in a big frame needs the offset materialised
// into the (scratch) reg first. Used for every frame-slot address computation.
+ (void)emitSpAddr:(NSUInteger)off into:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    if (off <= 4095) {
        [ctx.out appendFormat:@"    add %@, sp, #%lu\n", reg, (unsigned long)off];
    } else if ((off & 0xFFF) == 0 && (off >> 12) <= 4095) {
        [ctx.out appendFormat:@"    add %@, sp, #%lu, lsl #12\n", reg, (unsigned long)(off >> 12)];
    } else {
        NSString *w = [@"w" stringByAppendingString:[reg substringFromIndex:1]];
        [ctx.out appendFormat:@"    mov %@, #%lu\n", w, (unsigned long)(off & 0xFFFF)];
        if (off > 0xFFFF)
            [ctx.out appendFormat:@"    movk %@, #%lu, lsl #16\n", w, (unsigned long)(off >> 16)];
        [ctx.out appendFormat:@"    add %@, sp, %@\n", reg, reg];
    }
}

// Emit `add <dest>, <base>, #<off>` safely. The add immediate is 12-bit
// (0-4095, optionally <<12), so a large object-field offset — an ivar sitting
// behind a 32KB array ivar (finding #13; `add x10, x16, #32796` failed to
// encode) — splits into `hi, lsl #12` + `lo`, or materialises through x17 past
// 16MB. Same family as the emitSpAddr frame-offset fix, at the FIELD site:
// heap objects are not bounded by the 16KB frame budget. `dest` may alias
// `base` (both forms add onto dest last); neither is ever x17 (the operand
// scratch is x16), so x17 is free for the wide case.
+ (void)emitAddImm:(NSString *)dest base:(NSString *)base
            offset:(NSUInteger)off ctx:(XTArm64FnCtx *)ctx {
    if (off <= 4095) {
        [ctx.out appendFormat:@"    add %@, %@, #%lu\n", dest, base, (unsigned long)off];
    } else if (off <= 0xFFFFFF) {
        [ctx.out appendFormat:@"    add %@, %@, #%lu, lsl #12\n",
                              dest, base, (unsigned long)(off >> 12)];
        if (off & 0xFFF)
            [ctx.out appendFormat:@"    add %@, %@, #%lu\n",
                                  dest, dest, (unsigned long)(off & 0xFFF)];
    } else {
        [self materialiseImm64:(uint64_t)off intoXReg:@"x17" ctx:ctx];
        [ctx.out appendFormat:@"    add %@, %@, x17\n", dest, base];
    }
}

// AAPCS indirect result (x8 sret): a struct return larger than 16 bytes is
// written by the callee through a hidden pointer the caller passes in x8, not
// returned in x0:x1. If this call's result is such an aggregate, point x8 at the
// caller's (correctly-sized) result slot before the branch and return YES so the
// caller's copy-back is skipped — the callee has already filled the slot. x8 is
// the reserved indirect-result temp and is not an argument register, so this is
// safe to emit last, after every arg is loaded. (≤16-byte returns → NO, x0:x1.)
+ (BOOL)emitSretSetupIfNeeded:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    if (!insn.result || insn.result.type.kind != XTIRTypeKindAgg) return NO;
    // An HFA (e.g. NSRect = 4 doubles) is returned in v0..v3, not via x8 — even
    // though it is >16 bytes. Only a >16-byte NON-float aggregate uses the sret.
    if ([self arm64AggHFA:insn.result.type.layout elemKind:NULL] > 0) return NO;
    if ([self arm64AggSize:insn.result.type.layout] <= 16) return NO;
    [self emitSpAddr:[self slotOffsetForValue:insn.result.valueId ctx:ctx] into:@"x8" ctx:ctx];
    return YES;
}

// Capture an aggregate return into its result slot after a call: an HFA comes
// back in v0..v(n-1) (d/s per element), a ≤16-byte aggregate in x0:x1, and a
// >16-byte non-float aggregate was already written to the slot through the x8
// sret the caller set (`sretUsed`). Shared by the Call/CallIndirect/VTblDispatch
// result paths.
+ (void)captureAggResult:(XTIRInsn *)insn sretUsed:(BOOL)sretUsed ctx:(XTArm64FnCtx *)ctx {
    XTIRTypeKind ek = XTIRTypeKindVoid;
    NSUInteger hfa = [self arm64AggHFA:insn.result.type.layout elemKind:&ek];
    if (hfa > 0) {
        NSUInteger esz = (ek == XTIRTypeKindF64) ? 8 : 4;
        NSString *pfx = (ek == XTIRTypeKindF64) ? @"d" : @"s";
        for (NSUInteger k = 0; k < hfa; k++) {
            [self storeReg:[NSString stringWithFormat:@"%@%lu", pfx, (unsigned long)k]
                 intoValue:insn.result.valueId offset:esz * k ctx:ctx];
        }
        return;
    }
    if (sretUsed) return;   // >16-byte non-HFA: callee filled the slot via x8.
    NSUInteger base = [self slotOffsetForValue:insn.result.valueId ctx:ctx];
    NSUInteger sz = [self arm64AggSize:insn.result.type.layout];
    [self emitSpAddr:base into:@"x16" ctx:ctx];
    [ctx.out appendString:@"    str x0, [x16]\n"];
    if (sz > 8) [ctx.out appendString:@"    str x1, [x16, #8]\n"];
}

// Marshal a by-value aggregate ARGUMENT from value `vid`'s slot into registers,
// AAPCS: an HFA fills consecutive v-registers (fpIdx), any other aggregate fills
// consecutive GP registers (gpIdx); the matching counter is advanced. Returns NO
// without emitting anything if it doesn't fit its bank (stack-passed — unsupported,
// rare). Shared by every call path so an HFA arg (e.g. -setFrame:(NSRect)) lands
// in v-registers rather than being truncated into GP.
+ (BOOL)marshalAggArg:(XTIRValueId)vid type:(XTIRType *)aty
                gpIdx:(int *)gpIdx fpIdx:(int *)fpIdx ctx:(XTArm64FnCtx *)ctx {
    XTIRTypeKind ek = XTIRTypeKindVoid;
    NSUInteger hfa = [self arm64AggHFA:aty.layout elemKind:&ek];
    if (hfa > 0) {
        if (*fpIdx + (int)hfa > 8) return NO;
        NSUInteger esz = (ek == XTIRTypeKindF64) ? 8 : 4;
        NSString *pfx = (ek == XTIRTypeKindF64) ? @"d" : @"s";
        for (NSUInteger k = 0; k < hfa; k++)
            [self loadValue:vid offset:esz * k
                    intoReg:[NSString stringWithFormat:@"%@%d", pfx, *fpIdx + (int)k] ctx:ctx];
        *fpIdx += (int)hfa;
        return YES;
    }
    NSUInteger nregs = [self gpRegsForAgg:aty];
    if (*gpIdx + (int)nregs > 8) return NO;
    for (NSUInteger k = 0; k < nregs; k++)
        [self loadValue:vid offset:8 * k
                intoReg:[NSString stringWithFormat:@"x%d", *gpIdx + (int)k] ctx:ctx];
    *gpIdx += (int)nregs;
    return YES;
}

// Copy `sz` bytes between memory [x16, #0..] and a frame slot [sp, #slot..] in
// 8/4/2/1-byte chunks (a single `ldr x17` would drop everything past 8 bytes).
// `toFrame` = direction (YES: mem→frame, NO: frame→mem). The transfer rides
// w17/x17, the memory side stays in x16. A narrow strb/strh's scaled immediate
// caps at 4095/8190, so a struct staged high in a big frame overflows it —
// when the slot is out of range we stage the frame base in x15 (a free
// transient scratch here) and address the frame at small offsets.
+ (void)emitAggCopy:(NSUInteger)sz frameSlot:(NSUInteger)slot
            toFrame:(BOOL)toFrame ctx:(XTArm64FnCtx *)ctx {
    NSString *fb = @"sp"; NSUInteger fbias = slot;
    if (slot + sz > 4095) {                 // beyond the strb/strh immediate
        [self emitSpAddr:slot into:@"x15" ctx:ctx];
        fb = @"x15"; fbias = 0;
    }
    NSArray<NSArray *> *chunks = @[@[@8, @"ldr", @"str", @"x17"],
                                   @[@4, @"ldr", @"str", @"w17"],
                                   @[@2, @"ldrh", @"strh", @"w17"],
                                   @[@1, @"ldrb", @"strb", @"w17"]];
    // The tail (<8-byte chunks) of a >4KB aggregate can sit past the narrow
    // load/store immediates (strb tops out at #4095 — finding #13's family).
    // Rebase BOTH pointers once at the first such chunk; `reb` is subtracted
    // from every subsequent offset. The 8-byte chunks never need it (frame
    // aggregates are under the 16KB budget; ldr/str x reach #32760).
    NSUInteger off = 0, reb = 0;
    for (NSArray *c in chunks) {
        NSUInteger w = [c[0] unsignedIntegerValue];
        while (sz - off >= w) {
            if (w < 8 && reb == 0 && off > 4095) {
                [self emitAddImm:@"x16" base:@"x16" offset:off ctx:ctx];
                [self emitSpAddr:slot + off into:@"x15" ctx:ctx];
                fb = @"x15"; fbias = 0; reb = off;
            }
            if (toFrame) {            // mem [x16] → frame
                [ctx.out appendFormat:@"    %@ %@, [x16, #%lu]\n", c[1], c[3], (unsigned long)(off - reb)];
                [ctx.out appendFormat:@"    %@ %@, [%@, #%lu]\n", c[2], c[3], fb, (unsigned long)(fbias + off - reb)];
            } else {                  // frame → mem [x16]
                [ctx.out appendFormat:@"    %@ %@, [%@, #%lu]\n", c[1], c[3], fb, (unsigned long)(fbias + off - reb)];
                [ctx.out appendFormat:@"    %@ %@, [x16, #%lu]\n", c[2], c[3], (unsigned long)(off - reb)];
            }
            off += w;
        }
    }
}

#pragma mark - Operand evaluation

// Materialise `op` into register `reg`. For Use operands: load from
// the slot. For ImmI: emit mov. Other operand kinds are not used in
// the trivial subset.
// Build a 32-bit immediate into a w-register via movz/movk.
+ (void)materialiseImm32:(uint32_t)bits intoWReg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    [ctx.out appendFormat:@"    movz %@, #%u\n", reg, bits & 0xFFFF];
    if ((bits >> 16) != 0) {
        [ctx.out appendFormat:@"    movk %@, #%u, lsl #16\n", reg, (bits >> 16) & 0xFFFF];
    }
}

// Build a 64-bit immediate into an x-register via movz/movk.
+ (void)materialiseImm64:(uint64_t)bits intoXReg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    [ctx.out appendFormat:@"    movz %@, #%u\n", reg, (unsigned)(bits & 0xFFFF)];
    for (int shift = 16; shift < 64; shift += 16) {
        unsigned chunk = (unsigned)((bits >> shift) & 0xFFFF);
        if (chunk != 0) {
            [ctx.out appendFormat:@"    movk %@, #%u, lsl #%d\n", reg, chunk, shift];
        }
    }
}

// Put a deref's effective address in x16. arm64 is a flat host: a pointer
// is dereferenced directly, with no address remapping. (xtc programs that
// poke absolute Atari addresses — hardware registers, ZP — are 6502-only;
// they are never compiled for this backend, so no value reaching a deref
// is an Atari address. A genuinely bad pointer faults, as it should on the
// host.) `src` may be a homed callee-saved register, so move it into x16
// only when it is not already there.
+ (void)emitDerefAddrFor:(XTIROperand *)ptrOp ctx:(XTArm64FnCtx *)ctx {
    NSString *p = [self operandReg:ptrOp intoScratch:@"x16" ctx:ctx];
    if (![p isEqualToString:@"x16"]) [self emitMove:@"x16" from:p ctx:ctx];
}

// Load one operand into an FP register. A use goes through loadValue, which
// already knows the FP form; an immediate has to be built in a GP scratch and
// moved across with `fmov`, since movz/movk cannot target the FP bank.
+ (void)loadFPOperand:(XTIROperand *)op intoReg:(NSString *)reg
               double:(BOOL)dbl ctx:(XTArm64FnCtx *)ctx {
    if (op.kind == XTIROperandKindUse) {
        [self loadValue:op.valueId intoReg:reg ctx:ctx];
        return;
    }
    NSString *gp = dbl ? @"x14" : @"w14";
    [self materialiseOperand:op intoReg:gp ctx:ctx];
    [ctx.out appendFormat:@"    fmov %@, %@\n", reg, gp];
}

+ (void)materialiseOperand:(XTIROperand *)op intoReg:(NSString *)reg ctx:(XTArm64FnCtx *)ctx {
    switch (op.kind) {
        case XTIROperandKindUse: {
            // A constant is cheaper to REBUILD here than to fetch. Otherwise it
            // goes wherever the allocator put it — a home register, or a frame
            // slot — and arrives by a copy, so passing three constants to a
            // call cost eight instructions in arc_alloc's hot loop: three to
            // materialise, one to mask a constant zero back into its width, and
            // four to copy them into x0-x2. Rebuilding makes that three movs.
            //
            // The defining Const is still emitted if anything else reads it;
            // when nothing does, it is dead and goes the usual way.
            XTIRInsn *d = ctx.defOf[@(op.valueId)];
            if (d && d.opcode == XTIROpConst && d.operands.count >= 1 &&
                d.operands[0].kind == XTIROperandKindImmI) {
                [self materialiseOperand:d.operands[0] intoReg:reg ctx:ctx];
                break;
            }
            [self loadValue:op.valueId intoReg:reg ctx:ctx];
            break;
        }
        case XTIROperandKindImmI: {
            int64_t v = op.intValue;
            // Use `mov w<n>, #imm` for small immediates, else `movz`/`movk`.
            if (v >= 0 && v <= 0xFFFF) {
                [ctx.out appendFormat:@"    mov %@, #%lld\n", reg, v];
            } else if ([reg hasPrefix:@"x"]) {
                // An X destination takes the FULL 64 bits. This used to cast to
                // uint32_t unconditionally, which was invisible while nothing
                // wider than 32 bits existed — `(u64)1000000000000` arrived as
                // its low half and every later result was quietly wrong.
                [self materialiseImm64:(uint64_t)v intoXReg:reg ctx:ctx];
            } else {
                uint32_t bits = (uint32_t)v;
                [ctx.out appendFormat:@"    movz %@, #%u\n", reg, bits & 0xFFFF];
                if ((bits >> 16) != 0) {
                    [ctx.out appendFormat:@"    movk %@, #%u, lsl #16\n", reg, (bits >> 16) & 0xFFFF];
                }
            }
            break;
        }
        case XTIROperandKindImmF: {
            // Float immediate — the encoded bytes are packed
            // little-endian into floatRawBytes (5 bytes for F40,
            // 8 for F64). Build the full 64-bit value in the
            // x-form of the target register via movz/movk so the
            // bytes survive; the Const handler stores the slot.
            // NOTE: arm64 float load/store remains 4-byte-truncated
            // (the integer width logic), so float correctness on
            // arm64 awaits the float-arithmetic task; this just
            // avoids emitting an "unsupported operand" stub.
            uint64_t bits = op.floatRawBytes;
            NSString *xreg = [reg hasPrefix:@"w"]
                ? [@"x" stringByAppendingString:[reg substringFromIndex:1]]
                : reg;
            [ctx.out appendFormat:@"    movz %@, #%u\n", xreg, (unsigned)(bits & 0xFFFF)];
            for (int shift = 16; shift < 64; shift += 16) {
                unsigned chunk = (unsigned)((bits >> shift) & 0xFFFF);
                if (chunk != 0) {
                    [ctx.out appendFormat:@"    movk %@, #%u, lsl #%d\n", xreg, chunk, shift];
                }
            }
            break;
        }
        default:
            [ctx.out appendFormat:@"    // unsupported operand kind %d\n", (int)op.kind];
            break;
    }
}

#pragma mark - Phi-edge copies

// Before emitting a terminator that targets `successor`, copy each
// phi's predecessor-operand value into the phi-result's slot.
// Emit one phi's edge copy: incoming value `vop` -> phi result (home reg or slot).
+ (void)emitOnePhiCopy:(XTIRInsn *)phi source:(XTIROperand *)vop ctx:(XTArm64FnCtx *)ctx
{
    // Size the copy register to the phi's type: a Ptr/Memory phi is 8 bytes
    // (a hardcoded w16 would truncate a loop-carried pointer); a float phi
    // needs an FP scratch (a w16 integer view garbles it).
    XTIRType *pty = phi.result.type;

    // An AGGREGATE phi is a slot-to-slot copy, not a register move.
    //
    // Aggregates are never homed (see the `k == XTIRTypeKindAgg` skip in the homing
    // pass) — a struct value always lives in a frame slot. Sizing a register from the
    // phi's type therefore fell back to a 32-bit view and copied the FIRST FOUR BYTES,
    // silently dropping the rest: an 8-byte Rect through a ternary kept its x,y and
    // zeroed its w,h. Compiles clean, naturally.
    //
    // (The same class of bug was already fixed for an aggregate Load — "a single
    // `ldr x17` dropped every byte past the first 8". The phi was missed.)
    if (pty && pty.kind == XTIRTypeKindAgg && vop.kind == XTIROperandKindUse) {
        NSUInteger sz = [self arm64AggSize:pty.layout];
        [self emitSpAddr:[self slotOffsetForValue:vop.valueId ctx:ctx]
                    into:@"x16" ctx:ctx];
        [self emitAggCopy:sz
                frameSlot:[self slotOffsetForValue:phi.result.valueId ctx:ctx]
                  toFrame:YES ctx:ctx];
        return;
    }

    BOOL fp = pty && XTIRTypeKindIsFloating(pty.kind);
    NSString *phiHome = ctx.homeReg[@(phi.result.valueId)];
    if (phiHome && vop.kind == XTIROperandKindUse) {
        // Phi homed + value is an SSA use: materialise directly into the home.
        NSString *dest = [self homeView:phiHome forType:pty];
        [self loadValue:vop.valueId intoReg:dest ctx:ctx];
    } else {
        // Unhomed result, or a Const/Sym operand (a float immediate must build
        // through a GP reg) — stage via scratch and let storeReg settle it.
        NSString *scratch = (fp && vop.kind == XTIROperandKindUse)
            ? [self fregName:16 forType:pty]
            : [self regName:16 forType:pty];
        NSString *src = [self operandReg:vop intoScratch:scratch ctx:ctx];
        [self storeReg:src intoValue:phi.result.valueId ctx:ctx];
    }
}

+ (void)emitPhiCopiesFrom:(XTIRBlock *)predBlock
                     to:(XTIRBlock *)successor
                    ctx:(XTArm64FnCtx *)ctx
{
    // Collect this edge's copies (each phi's incoming value for predBlock).
    NSMutableArray<XTIRInsn *> *phis = [NSMutableArray array];
    NSMutableArray<XTIROperand *> *srcs = [NSMutableArray array];
    for (XTIRInsn *phi in successor.phiNodes) {
        if (phi.opcode != XTIROpPhi) continue;
        // Vector phis (reduction accumulators) are usually coalesced onto one
        // v-register at function-emit start (same register ⇒ no-op), and must
        // never route through the w16 scalar scratch below. But a SHARED
        // preheader incoming — one init splat feeding U accumulator phis
        // (#1198) — can coalesce with only ONE of them; the others need a real
        // full-width edge copy. srcs are all the one shared register and dests
        // are distinct classes, so in-order emission cannot lose a copy.
        if (phi.result && phi.result.type.kind == XTIRTypeKindVec) {
            for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2) {
                XTIROperand *bop = phi.operands[i];
                if (bop.kind != XTIROperandKindBlock || bop.blockRef != predBlock) continue;
                XTIROperand *inc = phi.operands[i + 1];
                NSString *dst = ctx.vecReg[@(phi.result.valueId)];
                NSString *src = inc.kind == XTIROperandKindUse ? ctx.vecReg[@(inc.valueId)] : nil;
                if (dst && src && ![dst isEqualToString:src])   // orr = the v-to-v move
                    [ctx.out appendFormat:@"    orr %@.16b, %@.16b, %@.16b\n", dst, src, src];
                break;
            }
            continue;
        }
        for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2) {
            XTIROperand *bop = phi.operands[i];
            if (bop.kind == XTIROperandKindBlock && bop.blockRef == predBlock) {
                [phis addObject:phi]; [srcs addObject:phi.operands[i + 1]]; break;
            }
        }
    }
    NSUInteger n = phis.count;
    if (n == 0) return;
    // Phi copies are a PARALLEL assignment. The old code copied them in phi
    // order assuming no phi's incoming value is a SIBLING phi on the same edge
    // — but the loop unroller breaks that: an outer header gets `v <- i` next
    // to `i <- i+1`, and copying `i` first makes `v` read the new i (a nested
    // loop's counter came out one too high). Emit in dependency order: a copy
    // whose result is read by another pending copy goes LAST. (#402 fixed the
    // same lost-copy hazard for m68k/xt6502.)
    NSMutableIndexSet *pending = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, n)];
    while (pending.count) {
        NSInteger pick = -1;
        for (NSUInteger idx = pending.firstIndex; idx != NSNotFound;
             idx = [pending indexGreaterThanIndex:idx]) {
            XTIRValueId did = phis[idx].result.valueId;
            BOOL blocked = NO;
            for (NSUInteger o = pending.firstIndex; o != NSNotFound;
                 o = [pending indexGreaterThanIndex:o]) {
                if (o == idx) continue;
                if (srcs[o].kind == XTIROperandKindUse && srcs[o].valueId == did) {
                    blocked = YES; break;
                }
            }
            if (!blocked) { pick = (NSInteger)idx; break; }
        }
        if (pick >= 0) {
            [self emitOnePhiCopy:phis[(NSUInteger)pick] source:srcs[(NSUInteger)pick] ctx:ctx];
            [pending removeIndex:(NSUInteger)pick];
            continue;
        }
        // Residual cycle: every pending copy's DEST is read by another pending
        // copy, so no single-step order is safe -- a swap `%a<-%b, %b<-%a` copied
        // in place loses one value (bug 199: loop-swapped class-pointer locals
        // came back unchanged). A parallel assignment sequentialises correctly by
        // reading EVERY source into a scratch register first, then writing every
        // dest -- SP is untouched, so slot-homed members stay addressable. GP
        // members use x15/x16/x17 (never home registers; spMemForOff's address
        // temp is x9, so it can't clobber them); FP members use s/d16..18.
        // Aggregate cycles (never seen -- a struct phi lives in a slot and does
        // not participate in a register swap) and cycles wider than the scratch
        // pool fall back to the in-place single step, no worse than pre-fix.
        NSMutableArray<NSNumber *> *cyc = [NSMutableArray array];
        NSUInteger gpNeed = 0, fpNeed = 0; BOOL bail = NO;
        for (NSUInteger idx = pending.firstIndex; idx != NSNotFound;
             idx = [pending indexGreaterThanIndex:idx]) {
            XTIRType *pty = phis[idx].result.type;
            if (pty && pty.kind == XTIRTypeKindAgg) { bail = YES; break; }
            if (pty && XTIRTypeKindIsFloating(pty.kind)) fpNeed++; else gpNeed++;
            [cyc addObject:@(idx)];
        }
        if (bail || gpNeed > 3 || fpNeed > 3) {
            NSUInteger fb = pending.firstIndex;          // last-resort single step
            [self emitOnePhiCopy:phis[fb] source:srcs[fb] ctx:ctx];
            [pending removeIndex:fb];
            continue;
        }
        int gpScratch[3] = { 15, 16, 17 };
        int fpScratch[3] = { 16, 17, 18 };
        NSUInteger gpUsed = 0, fpUsed = 0;
        NSMutableArray<NSString *> *staged = [NSMutableArray array];
        // Phase 1: read every source into its own scratch register.
        for (NSNumber *ix in cyc) {
            NSUInteger idx = ix.unsignedIntegerValue;
            XTIRType *pty = phis[idx].result.type;
            NSString *reg = (pty && XTIRTypeKindIsFloating(pty.kind))
                ? [self fregName:fpScratch[fpUsed++] forType:pty]
                : [self regName:gpScratch[gpUsed++] forType:pty];
            [self materialiseOperand:srcs[idx] intoReg:reg ctx:ctx];
            [staged addObject:reg];
        }
        // Phase 2: write every dest from its scratch register.
        NSUInteger si = 0;
        for (NSNumber *ix in cyc) {
            NSUInteger idx = ix.unsignedIntegerValue;
            [self storeReg:staged[si++] intoValue:phis[idx].result.valueId ctx:ctx];
            [pending removeIndex:idx];
        }
    }
}

#pragma mark - ICmp predicate → AArch64 condition

+ (NSString *)condStringForICmpPredicate:(uint8_t)pred {
    switch (pred) {
        case XTIRICmpEQ:  return @"eq";
        case XTIRICmpNE:  return @"ne";
        case XTIRICmpSLT: return @"lt";
        case XTIRICmpSGT: return @"gt";
        case XTIRICmpSLE: return @"le";
        case XTIRICmpSGE: return @"ge";
        case XTIRICmpULT: return @"lo";
        case XTIRICmpUGT: return @"hi";
        case XTIRICmpULE: return @"ls";
        case XTIRICmpUGE: return @"hs";
        default:          return @"eq";
    }
}

// Materialise an ICmp's operands and emit the `cmp` (setting the flags), then
// return its AArch64 condition string. Shared by the standalone ICmp (→ cset)
// and the fused CondBranch (→ b.<cond>).
// YES if `target` has a phi with an incoming edge from `from` — i.e. branching
// from `from` to `target` requires edge copies. Used to gate the `cbz`/`cbnz`
// fusion (which reads a register, not flags) to edges with no intervening copy.
static BOOL phiCopiesNeeded(XTIRBlock *target, XTIRBlock *from) {
    if (!target) return NO;
    for (XTIRInsn *phi in target.phiNodes) {
        if (phi.opcode != XTIROpPhi) continue;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].kind == XTIROperandKindBlock &&
                phi.operands[k].blockRef == from) return YES;
    }
    return NO;
}

// The taken-edge phi copies are emitted UNCONDITIONALLY before the conditional
// branch (so they also run down the fall-through path, which then overwrites its
// own phi slots). That is safe only if no taken-edge copy DESTINATION is a
// fall-edge copy SOURCE — otherwise the taken copy clobbers a value the fall
// copy still needs (e.g. a rotated loop's `pb_i <- i+1` back-edge copy destroys
// pb_i, which the exit edge's `last <- pb_i` copy reads). When they overlap the
// taken copies must go on the taken path only.
static BOOL takenPhiClobbersFallSrc(XTIRBlock *t, XTIRBlock *f, XTIRBlock *from) {
    if (!t || !f) return NO;
    NSMutableSet<NSNumber *> *takenDests = [NSMutableSet set];
    for (XTIRInsn *phi in t.phiNodes) {
        if (phi.opcode != XTIROpPhi || !phi.result) continue;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].kind == XTIROperandKindBlock && phi.operands[k].blockRef == from) {
                [takenDests addObject:@(phi.result.valueId)]; break;
            }
    }
    if (takenDests.count == 0) return NO;
    for (XTIRInsn *phi in f.phiNodes) {
        if (phi.opcode != XTIROpPhi) continue;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].kind == XTIROperandKindBlock && phi.operands[k].blockRef == from) {
                XTIROperand *src = phi.operands[k + 1];
                if (src.kind == XTIROperandKindUse && [takenDests containsObject:@(src.valueId)])
                    return YES;
                break;
            }
    }
    return NO;
}

// If `icmp` is an `x == 0` / `x != 0` test (EQ/NE predicate against an
// integer/pointer zero — either an ImmI 0 or a Use of a `Const #0`), return the
// non-zero operand `x` (suitable for `cbz`/`cbnz`); otherwise nil.
static XTIROperand *icmpZeroTestValue(XTIRInsn *icmp, XTArm64FnCtx *ctx) {
    if (!icmp || icmp.opcode != XTIROpICmp || icmp.operands.count < 2) return nil;
    if (icmp.predicate != 0 && icmp.predicate != 1) return nil;   // EQ=0, NE=1
    BOOL (^isZero)(XTIROperand *) = ^BOOL(XTIROperand *o) {
        if (o.kind == XTIROperandKindImmI) return o.intValue == 0;
        if (o.kind == XTIROperandKindUse) {
            XTIRInsn *d = ctx.defOf[@(o.valueId)];
            return d && d.opcode == XTIROpConst && d.operands.count >= 1 &&
                   d.operands[0].kind == XTIROperandKindImmI && d.operands[0].intValue == 0;
        }
        return NO;
    };
    XTIROperand *o0 = icmp.operands[0], *o1 = icmp.operands[1];
    XTIROperand *val = isZero(o1) ? o0 : (isZero(o0) ? o1 : nil);
    if (!val) return nil;
    // cbz/cbnz are GP-register only; ICmp never has float operands, but guard.
    XTIRType *vt = (val.kind == XTIROperandKindUse) ? [ctx.fn valueForId:val.valueId].type
                                                    : val.type;
    if (vt && XTIRTypeKindIsFloating(vt.kind)) return nil;
    return val;
}

// NEON v-register index for a vector value (assigned in def order; q<n>/v<n> are
// the same physical register).
+ (NSUInteger)vecIndexForValue:(XTIRValueId)vid ctx:(XTArm64FnCtx *)ctx {
    NSString *e = ctx.vecReg[@(vid)];
    if (e) return (NSUInteger)[[e substringFromIndex:1] integerValue];
    NSUInteger n = ctx.vecNext++;
    if (n > 15) n = 15;                    // backstop; vectorized bodies are tiny
    ctx.vecReg[@(vid)] = [NSString stringWithFormat:@"v%lu", (unsigned long)n];
    return n;
}

// Lane-arrangement suffix for arithmetic on a vector of `lane`.
+ (NSString *)neonArrFor:(XTIRType *)lane {
    uint32_t w = lane ? XTIRTypeKindByteWidth(lane.kind) : 4;
    if (w == 1) return @"16b";
    if (w == 2) return @"8h";
    if (w == 8) return @"2d";
    return @"4s";
}

+ (NSString *)emitCompareForICmp:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    // Pointers are 8 bytes on arm64; comparing them through 32-bit w-registers
    // truncates to the low word (two distinct heap pointers whose low 32 bits
    // collide would read equal, breaking p==null tests), so size the compare to
    // the operand type: x-regs for Ptr/Memory, w-regs for narrow integers.
    XTIRType *t0 = (insn.operands[0].kind == XTIROperandKindUse)
        ? [ctx.fn valueForId:insn.operands[0].valueId].type : insn.operands[0].type;
    XTIRType *t1 = (insn.operands[1].kind == XTIROperandKindUse)
        ? [ctx.fn valueForId:insn.operands[1].valueId].type : insn.operands[1].type;
    NSString *r0, *r1;
    if ([self irTypeNeedsXReg:t0] || [self irTypeNeedsXReg:t1]) {
        r0 = @"x16"; r1 = @"x17";
        [self materialiseOperand:insn.operands[0] intoReg:r0 ctx:ctx];
        [self materialiseOperand:insn.operands[1] intoReg:r1 ctx:ctx];
    } else {
        // Fold a small constant right-hand side into `cmp r0, #imm` (the imm12
        // form), eliding the `mov #imm` that otherwise feeds the compare — this
        // sits on the loop-control critical path that gates the back-edge branch.
        NSNumber *imm = [self imm12ForOperand:insn.operands[1] ctx:ctx];
        if (imm) {
            r0 = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    cmp %@, #%@\n", r0, imm];
            return [self condStringForICmpPredicate:insn.predicate];
        }
        NSString *immS = [self imm12ShiftedForOperand:insn.operands[1] ctx:ctx];
        if (immS) {
            r0 = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    cmp %@, #%@\n", r0, immS];
            return [self condStringForICmpPredicate:insn.predicate];
        }
        r0 = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
        r1 = [self operandReg:insn.operands[1] intoScratch:@"w17" ctx:ctx];
    }
    [ctx.out appendFormat:@"    cmp %@, %@\n", r0, r1];
    return [self condStringForICmpPredicate:insn.predicate];
}

#pragma mark - Single instruction emission

// If `c` is a Const whose float value is exactly 2^k (k≥1), return k, else 0.
+ (int)pow2FbitsOfConst:(XTIRInsn *)c {
    if (!c || c.opcode != XTIROpConst || c.operands.count < 1) return 0;
    if (c.operands[0].kind != XTIROperandKindImmF) return 0;
    uint64_t raw = c.operands[0].floatRawBytes;   // IEEE-754 double bits
    uint64_t mant = raw & (((uint64_t)1 << 52) - 1);
    uint64_t expf = (raw >> 52) & 0x7FF;
    uint64_t sign = raw >> 63;
    if (sign || mant != 0 || expf == 0 || expf == 0x7FF) return 0;
    int e = (int)expf - 1023;
    return e >= 1 ? e : 0;
}

// Recognise op chains the backend can emit as a single fused instruction:
//   • `FDiv(SIToFp(x), 2^k)`  → `scvtf Sd, Wn, #k`  (fixed-point convert; the
//     int→float convert and the power-of-two divide collapse, bit-exact when
//     the quotient can't underflow — k≤31/63 here). Removes the fdiv and the
//     2^k constant.
// Only fuses when the consumed intermediates have a single use.
+ (void)computeFusionsForCtx:(XTArm64FnCtx *)ctx {
    ctx.fusedAway = [NSMutableSet set];
    ctx.fuseAt = [NSMutableDictionary dictionary];
    XTIRFunction *fn = ctx.fn;

    NSCountedSet<NSNumber *> *uses = [NSCountedSet set];
    NSMutableDictionary<NSNumber *, XTIRInsn *> *defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock *bb in fn.blocks) {
        NSMutableArray<XTIRInsn *> *all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        for (XTIRInsn *insn in all) {
            if (insn.result) defOf[@(insn.result.valueId)] = insn;
            for (XTIROperand *o in insn.operands)
                if (o.kind == XTIROperandKindUse) [uses addObject:@(o.valueId)];
        }
    }

    // The divisor `scvtf #k` doesn't read — only the convert is consumed, so a
    // multi-use 2^k divisor (e.g. one const-hoisted across the loop) is fine.
    // Track how many of each divisor's uses fuse, to drop it only when dead.
    NSCountedSet<NSNumber *> *divFused = [NSCountedSet set];
    for (XTIRBlock *bb in fn.blocks) {
        for (XTIRInsn *insn in bb.instructions) {
            if (insn.opcode != XTIROpFDiv || !insn.result || insn.operands.count < 2) continue;
            XTIROperand *o0 = insn.operands[0], *o1 = insn.operands[1];
            if (o0.kind != XTIROperandKindUse || o1.kind != XTIROperandKindUse) continue;
            if ([uses countForObject:@(o0.valueId)] != 1) continue;   // convert single-use
            XTIRInsn *cvt = defOf[@(o0.valueId)];
            if (!cvt || (cvt.opcode != XTIROpSIToFp && cvt.opcode != XTIROpUIToFp)) continue;
            if (cvt.operands.count < 1 || cvt.operands[0].kind != XTIROperandKindUse) continue;
            int fbits = [self pow2FbitsOfConst:defOf[@(o1.valueId)]];
            if (fbits < 1) continue;
            int maxb = (insn.result.type.kind == XTIRTypeKindF64) ? 64 : 32;
            if (fbits > maxb) continue;
            ctx.fuseAt[@(insn.result.valueId)] = @{
                @"kind": @"scvtf",
                @"src": cvt.operands[0],
                @"signed": @(cvt.opcode == XTIROpSIToFp),
                @"fbits": @(fbits),
            };
            [ctx.fusedAway addObject:@(o0.valueId)];   // the standalone convert
            [divFused addObject:@(o1.valueId)];
        }
    }
    // A divisor whose every use was fused away is now dead — skip emitting it.
    for (NSNumber *cid in divFused)
        if ([divFused countForObject:cid] == [uses countForObject:cid])
            [ctx.fusedAway addObject:cid];

    // ── Fused multiply-add: FAdd/FSub with a single-use FMul operand ──
    // a*b+c → fmadd, c-a*b → fmsub, a*b-c → fnmsub. One IEEE rounding instead
    // of two, so NOT bit-identical to separate fmul+fadd — but it matches what
    // clang emits under default FP contraction.
    for (XTIRBlock *bb in fn.blocks) {
        XTIRInsn *prevInsn = nil;   // the instruction immediately before `insn`
        for (XTIRInsn *insn in bb.instructions) {
            if ((insn.opcode != XTIROpFAdd && insn.opcode != XTIROpFSub)
                || !insn.result || insn.operands.count < 2) { prevInsn = insn; continue; }
            XTIROperand *o0 = insn.operands[0], *o1 = insn.operands[1];
            // The fused FMul must be the instruction IMMEDIATELY before the
            // FAdd/FSub. Register allocation runs BEFORE fusion and ends the
            // multiply operands' live ranges at the (soon-elided) FMul, so it
            // can hand their registers to a value computed between the FMul and
            // the add — and the fused `fmadd`, reaching back for those
            // operands, then reads clobbered registers. That is exactly what
            // broke a sum of two products, `a*a + b*b` (c2xc bug 34): the FAR
            // product was fused while the NEAR product's loads reused its
            // operand registers. Requiring adjacency keeps the fused operands
            // live (nothing runs between) and leaves the addend — the add's
            // other operand, whose liveness already reaches the add — as the
            // NON-adjacent product, emitted normally. A non-adjacent multiply
            // is left un-fused (a separate fmul+fadd, correct if less tight).
            XTIRInsn *localPrev = prevInsn;
            XTIRInsn *(^mulOf)(XTIROperand *) = ^XTIRInsn *(XTIROperand *o) {
                if (o.kind != XTIROperandKindUse) return nil;
                if ([uses countForObject:@(o.valueId)] != 1) return nil;
                if ([ctx.fusedAway containsObject:@(o.valueId)]) return nil;
                XTIRInsn *d = defOf[@(o.valueId)];
                if (!(d && d.opcode == XTIROpFMul && d.operands.count >= 2)) return nil;
                return (d == localPrev) ? d : nil;   // adjacency (bug 34)
            };
            XTIRInsn *mul = nil; XTIROperand *addend = nil; NSString *mnem = nil;
            if (insn.opcode == XTIROpFAdd) {
                if ((mul = mulOf(o0))) { addend = o1; mnem = @"fmadd"; }
                else if ((mul = mulOf(o1))) { addend = o0; mnem = @"fmadd"; }
            } else {                                    // FSub(o0, o1)
                if ((mul = mulOf(o1))) { addend = o0; mnem = @"fmsub"; }      // c - a*b
                else if ((mul = mulOf(o0))) { addend = o1; mnem = @"fnmsub"; } // a*b - c
            }
            if (!mul) { prevInsn = insn; continue; }
            ctx.fuseAt[@(insn.result.valueId)] = @{
                @"kind": @"fma", @"mnem": mnem,
                @"a": mul.operands[0], @"b": mul.operands[1], @"c": addend,
            };
            [ctx.fusedAway addObject:@(mul.result.valueId)];
            prevInsn = insn;
        }
    }

    // ── Shifted register operand: `orr Rd, Rn, Rm, lsr #k` ──
    // arm64 lets a data-processing instruction shift its SECOND source for
    // free, so a constant shift feeding one of these never needs to exist. It
    // is not only the shift that goes: in bit_ops the two shift results were
    // both live at the `orr`, the pool was exhausted, and each one round-tripped
    // through a frame slot — a store and a reload apiece. Folding one of them
    // removes five instructions from a nine-instruction body, because the
    // pressure that forced the spill goes with it.
    //
    // The shift must be the instruction IMMEDIATELY BEFORE its consumer, for
    // the reason the FMA fusion above documents: allocation runs BEFORE fusion,
    // so it may hand the shift's source register to anything computed in
    // between, and the fused form reaches back for that source.
    //
    // Only the second operand can carry the shift, and only at 32 or 64 bits:
    // narrow values live sign-extended in their registers, and the shift would
    // then act on the extension rather than the value (the trap the LShr paths
    // below spell out).
    for (XTIRBlock *bb in fn.blocks) {
        XTIRInsn *prev = nil;
        for (XTIRInsn *insn in bb.instructions) {
            NSString *mn = nil;
            switch (insn.opcode) {
                case XTIROpAdd: mn = @"add"; break;
                case XTIROpSub: mn = @"sub"; break;
                case XTIROpAnd: mn = @"and"; break;
                case XTIROpOr:  mn = @"orr"; break;
                case XTIROpXor: mn = @"eor"; break;
                default: break;
            }
            if (!mn || !insn.result || insn.operands.count < 2 ||
                !insn.result.type || insn.result.type.byteWidth < 4) { prev = insn; continue; }
            XTIROperand *o1 = insn.operands[1];
            if (o1.kind != XTIROperandKindUse || !prev || !prev.result ||
                prev.result.valueId != o1.valueId ||
                [uses countForObject:@(o1.valueId)] != 1) { prev = insn; continue; }
            NSString *sh = prev.opcode == XTIROpShl  ? @"lsl"
                         : prev.opcode == XTIROpLShr ? @"lsr"
                         : prev.opcode == XTIROpAShr ? @"asr" : nil;
            if (!sh || prev.operands.count < 2 ||
                prev.operands[0].kind != XTIROperandKindUse ||
                !prev.result.type || prev.result.type.byteWidth != insn.result.type.byteWidth) {
                prev = insn; continue;
            }
            // A LOGICAL right shift of a SIGNED value needs the zero-extension
            // dance below; keep those out of the fold entirely.
            if (prev.opcode == XTIROpLShr && XTIRTypeKindIsSigned(prev.result.type.kind)) {
                prev = insn; continue;
            }
            int64_t k = -1;
            if (prev.operands[1].kind == XTIROperandKindImmI)
                k = prev.operands[1].intValue;
            else if (prev.operands[1].kind == XTIROperandKindUse) {
                XTIRInsn *kd = defOf[@(prev.operands[1].valueId)];
                if (kd && kd.opcode == XTIROpConst && kd.operands.count >= 1 &&
                    kd.operands[0].kind == XTIROperandKindImmI)
                    k = kd.operands[0].intValue;
            }
            NSUInteger dw = insn.result.type.byteWidth == 8 ? 64 : 32;
            if (k < 0 || k >= (int64_t)dw) { prev = insn; continue; }
            ctx.fuseAt[@(insn.result.valueId)] = @{
                @"kind": @"shiftop", @"mnem": mn,
                @"a": insn.operands[0], @"src": prev.operands[0],
                @"sh": sh, @"amt": @(k),
            };
            [ctx.fusedAway addObject:@(prev.result.valueId)];
            prev = insn;
        }
    }
}

// The element stride for an ElementAddr (arm64-native: 8-byte host pointers,
// arm64FieldOffset-based aggregate sizes). Shared by the standalone emit and
// the address-mode fold.
+ (uint32_t)arm64ElemSizeForElementAddr:(XTIRInsn *)a ctx:(XTArm64FnCtx *)ctx {
    uint32_t elemSize = 1;
    XTIROperand *baseOp = a.operands[0];
    if (baseOp.kind == XTIROperandKindUse) {
        XTIRValue *bv = [ctx.fn valueForId:baseOp.valueId];
        XTIRType *pte = bv.type.pointeeType;
        if (pte) {
            if (pte.kind == XTIRTypeKindAgg && pte.layout)
                elemSize = (uint32_t)[self arm64AggSize:pte.layout];
            else if (pte.kind == XTIRTypeKindPtr)
                elemSize = 8;               // arm64 host pointer
            else
                elemSize = pte.byteWidth ?: 1;
        }
    }
    return elemSize;
}

// The byte offset of a FieldAddr's field (arm64-native widths). Shared by the
// standalone emit and the address-mode fold.
+ (uint32_t)arm64FieldByteOffsetForFieldAddr:(XTIRInsn *)a ctx:(XTArm64FnCtx *)ctx {
    uint32_t byteOffset = 0;
    XTIROperand *baseOp = a.operands[0];
    if (baseOp.kind == XTIROperandKindUse) {
        XTIRValue *bv = [ctx.fn valueForId:baseOp.valueId];
        XTIRType *pte = bv.type.pointeeType;
        if (pte && pte.kind == XTIRTypeKindAgg && pte.layout) {
            NSUInteger idx = (NSUInteger)a.operands[1].intValue;
            byteOffset = (uint32_t)[self arm64FieldOffset:pte.layout index:idx];
        }
    }
    return byteOffset;
}

// Address-mode folding. A scalar Load/Store whose pointer is a *single-use*
// FieldAddr/ElementAddr can address that op's base+offset/index directly via
// arm64's `[base, #off]` / `[base, idx, lsl #s]` forms — saving the separate
// address-computation op and the x16 staging move. `foldedAddr` records the
// addr ops to skip emitting; `foldInfo` maps the consuming Load/Store's pointer
// value-id to the addr insn it should inline. Aggregate loads/stores keep their
// multi-chunk x16 path (the fold is for the scalar ldr/str only).
+ (void)computeAddrFoldForCtx:(XTArm64FnCtx *)ctx {
    ctx.foldedAddr = [NSMutableSet set];
    ctx.foldInfo = [NSMutableDictionary dictionary];
    XTIRFunction *fn = ctx.fn;

    NSCountedSet<NSNumber *> *uses = [NSCountedSet set];
    NSMutableDictionary<NSNumber *, XTIRInsn *> *defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock *bb in fn.blocks) {
        NSMutableArray<XTIRInsn *> *all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        for (XTIRInsn *insn in all) {
            if (insn.result) defOf[@(insn.result.valueId)] = insn;
            for (XTIROperand *o in insn.operands)
                if (o.kind == XTIROperandKindUse) [uses addObject:@(o.valueId)];
        }
    }
    ctx.defOf = defOf;
    ctx.useCount = uses;

    // A single-use ICmp feeding its own block's CondBranch fuses into the branch.
    ctx.fusedCmps = [NSMutableSet set];
    for (XTIRBlock *bb in fn.blocks) {
        XTIRInsn *t = bb.terminator;
        if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 1) continue;
        if (t.operands[0].kind != XTIROperandKindUse) continue;
        NSNumber *cv = @(t.operands[0].valueId);
        XTIRInsn *cmp = defOf[cv];
        if (cmp && cmp.opcode == XTIROpICmp && cmp.result &&
            [uses countForObject:cv] == 1 && [bb.instructions containsObject:cmp])
            [ctx.fusedCmps addObject:cv];
    }

    for (XTIRBlock *bb in fn.blocks) {
        for (XTIRInsn *insn in bb.instructions) {
            BOOL isLoad  = (insn.opcode == XTIROpLoad  || insn.opcode == XTIROpLoadVolatile);
            BOOL isStore = (insn.opcode == XTIROpStore || insn.opcode == XTIROpStoreVolatile);
            // Lever 2: a Store whose value is a single-use integer `Const #0`
            // stores the zero register directly — elide the const's
            // mov/extend/spill. (Multi-use zero consts still store xzr/wzr below
            // but keep their def for the other users.)
            if (isStore && insn.operands.count >= 3 &&
                insn.operands[1].kind == XTIROperandKindUse) {
                NSNumber *vid = @(insn.operands[1].valueId);
                XTIRInsn *d = defOf[vid];
                if ([self isIntZeroConst:d] && [uses countForObject:vid] == 1)
                    [ctx.foldedAddr addObject:vid];
            }
            // Vector load/store (128-bit q) whose address is ElementAddr(base,
            // CONSTANT index) — a pointer-IV unrolled copy's `p + k·vw`. Fold the
            // constant element offset into the `ldr/str q, [base, #imm]` immediate
            // (scaled-imm range: multiple of 16, ≤ 65520).
            if (insn.opcode == XTIROpVLoad || insn.opcode == XTIROpVStore) {
                XTIROperand *vptr = insn.operands[0];
                if (vptr.kind != XTIROperandKindUse || [uses countForObject:@(vptr.valueId)] != 1) continue;
                XTIRInsn *ea = defOf[@(vptr.valueId)];
                if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2) continue;
                int64_t k;
                if (![self constIndexForElementAddr:ea ctx:ctx value:&k]) continue;
                uint32_t scale = [self arm64ElemSizeForElementAddr:ea ctx:ctx];
                int64_t off = k * (int64_t)scale;
                if (off < 0 || off % 16 != 0 || off > 65520) continue;
                ctx.foldInfo[@(vptr.valueId)] = ea;
                [ctx.foldedAddr addObject:@(ea.result.valueId)];
                continue;
            }
            if (!isLoad && !isStore) continue;
            if (isLoad  && (insn.operands.count < 2 || !insn.result)) continue;
            if (isStore && insn.operands.count < 3) continue;
            // Transfer type drives the scalar/aggregate split and (for the
            // FieldAddr immediate) the scale/alignment range.
            XTIRType *xferTy = nil;
            if (isLoad) {
                xferTy = insn.result.type;
            } else {
                XTIROperand *vop = insn.operands[1];
                xferTy = (vop.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:vop.valueId].type : vop.type;
            }
            if (xferTy && xferTy.kind == XTIRTypeKindAgg) continue;   // multi-chunk path
            XTIROperand *ptr = insn.operands[0];
            if (ptr.kind != XTIROperandKindUse) continue;
            if ([uses countForObject:@(ptr.valueId)] != 1) continue;  // addr single-use
            XTIRInsn *a = defOf[@(ptr.valueId)];
            if (!a || !a.result || a.operands.count < 2) continue;
            uint32_t w = 1;
            if (xferTy) {
                if (xferTy.kind == XTIRTypeKindPtr || xferTy.byteWidth >= 8) w = 8;
                else if (xferTy.byteWidth >= 4) w = 4;
                else if (xferTy.byteWidth == 2) w = 2;
                else w = 1;
            }
            if (a.opcode == XTIROpElementAddr) {
                uint32_t elemSize = [self arm64ElemSizeForElementAddr:a ctx:ctx];
                // Register-offset addressing needs a pow2 element ≤ 8 whose
                // lsl-shift equals the transfer-size log2 (the array case:
                // elemSize == access width).
                if (elemSize == 0 || (elemSize & (elemSize - 1)) != 0) continue;
                if (elemSize > 8 || elemSize != w) continue;
                ctx.foldInfo[@(ptr.valueId)] = a;
                [ctx.foldedAddr addObject:@(a.result.valueId)];
            } else if (a.opcode == XTIROpFieldAddr) {
                uint32_t off = [self arm64FieldByteOffsetForFieldAddr:a ctx:ctx];
                // Scaled unsigned-immediate range: off must be a multiple of
                // the access width and fit the 12-bit scaled field.
                if (w == 0 || off % w != 0 || off / w > 4095) continue;
                ctx.foldInfo[@(ptr.valueId)] = a;
                [ctx.foldedAddr addObject:@(a.result.valueId)];
            }
        }
    }
}

// Materialise a foldable Load/Store's base (and, for ElementAddr, its index)
// and return the fused arm64 addressing operand. Base lands in x16 (or its home);
// the ElementAddr index is zero-extended into x17. Callers must keep x16/x17 off
// the value/dest register when folding an ElementAddr.
// Resolve an ElementAddr's index to a compile-time constant (immI, or a Const
// reached through ZExt/SExt/Trunc — the widened-literal form). Used to fold a
// pointer-IV copy's constant element offset into an immediate addressing mode.
+ (BOOL)constIndexForElementAddr:(XTIRInsn *)ea ctx:(XTArm64FnCtx *)ctx value:(int64_t *)out {
    if (ea.operands.count < 2) return NO;
    XTIROperand *idx = ea.operands[1];
    if (idx.kind == XTIROperandKindImmI) { *out = idx.intValue; return YES; }
    if (idx.kind != XTIROperandKindUse) return NO;
    XTIRValueId cur = idx.valueId;
    for (int g = 0; g < 8; g++) {
        XTIRInsn *d = ctx.defOf[@(cur)];
        if (!d || d.operands.count < 1) return NO;
        if (d.opcode == XTIROpConst && d.operands[0].kind == XTIROperandKindImmI) { *out = d.operands[0].intValue; return YES; }
        if ((d.opcode == XTIROpZExt || d.opcode == XTIROpSExt || d.opcode == XTIROpTrunc) &&
            d.operands[0].kind == XTIROperandKindUse) { cur = d.operands[0].valueId; continue; }
        return NO;
    }
    return NO;
}

+ (NSString *)foldedAddrOperandFor:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    XTIRInsn *a = ctx.foldInfo[@(insn.operands[0].valueId)];
    NSString *base = [self operandReg:a.operands[0] intoScratch:@"x16" ctx:ctx];
    if (a.opcode == XTIROpFieldAddr) {
        uint32_t off = [self arm64FieldByteOffsetForFieldAddr:a ctx:ctx];
        return [NSString stringWithFormat:@"[%@, #%u]", base, (unsigned)off];
    }
    // ElementAddr with a constant index → immediate-offset addressing
    // (the pointer-IV unrolled-copy case: `[p, #k·scale]`), but ONLY when the
    // byte offset fits the access's unsigned scaled-immediate range (multiple of
    // the access width, quotient ≤ 4095). Otherwise fall through to the
    // extended-register form below, which has no such limit.
    int64_t k;
    if ([self constIndexForElementAddr:a ctx:ctx value:&k] && k >= 0) {
        uint32_t scale = [self arm64ElemSizeForElementAddr:a ctx:ctx];
        int64_t off = k * (int64_t)scale;
        // Access width: 16 for a vector q load/store, else the scalar transfer size.
        uint32_t accW = 16;
        if (insn.opcode != XTIROpVLoad && insn.opcode != XTIROpVStore) {
            XTIRType *xt = (insn.opcode == XTIROpStore || insn.opcode == XTIROpStoreVolatile)
                ? (insn.operands[1].kind == XTIROperandKindUse ? [ctx.fn valueForId:insn.operands[1].valueId].type : insn.operands[1].type)
                : insn.result.type;
            accW = (xt && ([self irTypeNeedsXReg:xt] || xt.byteWidth >= 8)) ? 8
                 : (xt && xt.byteWidth >= 4) ? 4 : (xt && xt.byteWidth == 2) ? 2 : 1;
        }
        if (off % accW == 0 && off / accW <= 4095)
            return [NSString stringWithFormat:@"[%@, #%lld]", base, (long long)off];
    }
    // ElementAddr: address the index via the extended-register form
    // `[base, Wm, ext #shift]`, which extends the 32-bit index in place — so a
    // homed index is read straight from its register with no `mov w17,…` staging,
    // and an unhomed one loads into w17. A SIGNED index (the negated offset from
    // `@(p - N)`) must SIGN-extend (`sxtw`) — `uxtw` would turn -4 into +0xFFFC
    // and address a wild page (segfault). An unsigned index zero-extends (the
    // no-wrap analysis keeps it ≤ typeMax, so its high 16 bits are zero).
    XTIRValue *idxV = (a.operands[1].kind == XTIROperandKindUse)
        ? [ctx.fn valueForId:a.operands[1].valueId] : nil;
    // A 64-BIT index is already address-width: its home view is an X register,
    // and `uxtw`/`sxtw` are W-index-only forms — `[x, xM, uxtw #3]` is invalid
    // AArch64 (blewit finding #8; the reference assembler rejects it, and the
    // hardware would silently read only Wm). Use the LSL form with the X
    // register instead; extension is meaningless at full width.
    BOOL idx64 = idxV && (idxV.type.kind == XTIRTypeKindI64
                          || idxV.type.kind == XTIRTypeKindU64
                          || idxV.type.kind == XTIRTypeKindPtr);
    NSString *idx = [self operandReg:a.operands[1]
                         intoScratch:idx64 ? @"x17" : @"w17" ctx:ctx];
    NSString *ext = idx64 ? @"lsl"
                  : (idxV && XTIRTypeKindIsSigned(idxV.type.kind)) ? @"sxtw" : @"uxtw";
    uint32_t elemSize = [self arm64ElemSizeForElementAddr:a ctx:ctx];
    unsigned shift = 0;
    for (uint32_t v = elemSize; v > 1; v >>= 1) shift++;
    return [NSString stringWithFormat:@"[%@, %@, %@ #%u]", base, idx, ext, shift];
}

#pragma mark - No-wrap (induction-bound) analysis  — Lever 1

// The unsigned upper bound a value of type `t` can hold once canonicalised, or
// UINT64_MAX for types we don't range-bound (signed ints — a negative value's
// unsigned interpretation is huge — pointers, memory, floats). Only U8/U16/U32
// (and Bool, byte-wide) are bounded; the analysis is purely unsigned.
+ (uint64_t)unsignedTypeMax:(nullable XTIRType *)t {
    if (!t) return UINT64_MAX;
    switch (t.kind) {
        case XTIRTypeKindBool:
        case XTIRTypeKindU8:  return 0xFFULL;
        case XTIRTypeKindU16: return 0xFFFFULL;
        case XTIRTypeKindU32: return 0xFFFFFFFFULL;
        default:              return UINT64_MAX;     // signed / ptr / etc.
    }
}

static uint64_t satAdd64(uint64_t a, uint64_t b) {
    uint64_t s = a + b; return (s < a) ? UINT64_MAX : s;
}
static uint64_t satMul64(uint64_t a, uint64_t b) {
    if (a == 0 || b == 0) return 0;
    uint64_t p = a * b; return (p / a != b) ? UINT64_MAX : p;
}

// Forward range propagation. ubClean(v) = min(typeMax(v), ubRaw(v)) is the value
// v holds AFTER canonicalisation (memoised); ubRaw(v) is its pre-mask arithmetic
// magnitude, derived from the SAFE ops only (Const ≥ 0, Add, Mul, Shl-by-const,
// And, ZExt) plus loop-guard bounds for induction phis — everything else is the
// full type range. Cycles resolve to the type max. Skipping a U8/U16 value's
// mask is sound exactly when ubRaw(v) ≤ typeMax(v): no bit lands above the width,
// so masked == unmasked. Deciding to skip never changes any bound (the skip
// condition is precisely ubRaw ≤ typeMax = ubClean), so the analysis is stable.
+ (uint64_t)ubCleanForValue:(XTIRValueId)vid
                        ctx:(XTArm64FnCtx *)ctx
                 guardBound:(NSDictionary<NSNumber *, NSNumber *> *)guardBound
                       memo:(NSMutableDictionary<NSNumber *, NSNumber *> *)memo
                   visiting:(NSMutableSet<NSNumber *> *)visiting {
    NSNumber *m = memo[@(vid)];
    if (m) return m.unsignedLongLongValue;
    XTIRValue *val = [ctx.fn valueForId:vid];
    uint64_t tmax = [self unsignedTypeMax:val.type];
    if ([visiting containsObject:@(vid)]) return tmax;        // cycle → conservative
    [visiting addObject:@(vid)];
    uint64_t raw = [self ubRawForValue:vid ctx:ctx guardBound:guardBound
                                  memo:memo visiting:visiting tmax:tmax
                             ignoreGuard:NO];
    [visiting removeObject:@(vid)];
    uint64_t r = MIN(tmax, raw);
    memo[@(vid)] = @(r);
    return r;
}

+ (uint64_t)ubRawForValue:(XTIRValueId)vid
                      ctx:(XTArm64FnCtx *)ctx
               guardBound:(NSDictionary<NSNumber *, NSNumber *> *)guardBound
                     memo:(NSMutableDictionary<NSNumber *, NSNumber *> *)memo
                 visiting:(NSMutableSet<NSNumber *> *)visiting
                     tmax:(uint64_t)tmax
              ignoreGuard:(BOOL)ignoreGuard {
    XTIRInsn *d = ctx.defOf[@(vid)];
    // A param / entry-live narrow value is canonicalised on entry, so it is
    // ≤ typeMax — a SOUND bound. (Give-ups for *arithmetic* below must instead
    // return UINT64_MAX: an op that might overflow the width must NOT report a
    // bound ≤ typeMax, or the caller would wrongly drop its mask.)
    if (!d) return tmax;
    // A guard — a loop-header test or an in-loop exit check `v <ult/ule B` —
    // proves v ≤ B at every use it dominates. The populating pass records a
    // bound only when ALL of v's (non-guard) uses are so dominated, so returning
    // it for any consumer here is sound; it also CAPS the recursion, which is
    // what lets a chain of guarded increments (an unrolled `k += prime` whose
    // every step is re-checked `k ≤ bound`) stay bounded instead of compounding
    // the stride N times and tripping the width.
    //
    // BUT this bound holds only at uses DOMINATED by the guard, not at the guard
    // comparison itself. When deciding whether THIS value's own definition may
    // skip its mask, we must not trust its own guard bound: the compare that
    // establishes `v ≤ B` reads v's raw, pre-mask value, so a `v` whose
    // arithmetic overflows the type (e.g. u16*u16 ≈ 4.3e9) would compare wrong
    // if left unmasked. `ignoreGuard` is YES only for that root decision; nested
    // operand bounds still use their guards (sound — they ARE dominated).
    NSNumber *gbTop = guardBound[@(vid)];
    if (!ignoreGuard && gbTop) return gbTop.unsignedLongLongValue;
    uint64_t (^ub)(XTIROperand *) = ^uint64_t(XTIROperand *o) {
        if (o.kind == XTIROperandKindImmI)
            return (o.intValue >= 0) ? (uint64_t)o.intValue : UINT64_MAX;
        if (o.kind == XTIROperandKindUse)
            return [self ubCleanForValue:o.valueId ctx:ctx guardBound:guardBound
                                    memo:memo visiting:visiting];
        return UINT64_MAX;
    };
    switch (d.opcode) {
        case XTIROpConst:
            if (d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindImmI &&
                d.operands[0].intValue >= 0)
                return (uint64_t)d.operands[0].intValue;
            return UINT64_MAX;
        case XTIROpAdd:
            if (d.operands.count >= 2) return satAdd64(ub(d.operands[0]), ub(d.operands[1]));
            return UINT64_MAX;
        case XTIROpMul:
            if (d.operands.count >= 2) return satMul64(ub(d.operands[0]), ub(d.operands[1]));
            return UINT64_MAX;
        case XTIROpShl:
            // Only a *constant* shift amount has a known multiplier; a variable
            // shift can push bits arbitrarily high → unbounded (keep the mask).
            if (d.operands.count >= 2 && d.operands[1].kind == XTIROperandKindImmI &&
                d.operands[1].intValue >= 0 && d.operands[1].intValue < 64)
                return satMul64(ub(d.operands[0]), 1ULL << d.operands[1].intValue);
            return UINT64_MAX;
        case XTIROpAnd:
            if (d.operands.count >= 2) return MIN(ub(d.operands[0]), ub(d.operands[1]));
            return UINT64_MAX;
        case XTIROpZExt:
            if (d.operands.count >= 1) return ub(d.operands[0]);
            return UINT64_MAX;
        case XTIROpPhi: {
            // A phi's inputs are each ≤ their own typeMax, so the phi is ≤ typeMax
            // (a sound bound); a loop guard may tighten it further.
            NSNumber *gb = guardBound[@(vid)];
            return gb ? gb.unsignedLongLongValue : tmax;
        }
        default:
            return UINT64_MAX;  // Sub (unsigned underflow), Or/Xor, calls, loads…
    }
}

// Mark narrow-int (U8/U16) op results whose value provably fits the type width,
// so the backend can drop their uxtb/uxth. The only nontrivial bound is the
// loop-guard one: a header-phi compared `phi <ult/ule> B` on the edge that
// enters the loop body is ≤ B inside the body (SSA-immutable, body dominated by
// the guard), so every in-body use — including the increment add — is bounded.
+ (void)computeNoWrapForCtx:(XTArm64FnCtx *)ctx {
    ctx.noCanon = [NSMutableSet set];
    XTIRFunction *fn = ctx.fn;
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSUInteger nb = blocks.count;
    if (nb == 0) return;

    // CFG successor / predecessor index lists.
    NSMutableArray<NSMutableArray<NSNumber *> *> *succs = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber *> *> *preds = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++) {
        [succs addObject:[NSMutableArray array]]; [preds addObject:[NSMutableArray array]];
    }
    for (NSUInteger si = 0; si < nb; si++) {
        XTIRInsn *t = blocks[si].terminator;
        if (!t) continue;
        for (XTIROperand *o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef) {
                NSUInteger ti = [blocks indexOfObjectIdenticalTo:o.blockRef];
                if (ti != NSNotFound) { [succs[si] addObject:@(ti)]; [preds[ti] addObject:@(si)]; }
            }
    }

    // Natural loop body per header. A back-edge L→H (H index ≤ L) makes H a
    // header; its body is H plus every block that reaches the latch L without
    // passing through H (backward reachability). Using the precise body — rather
    // than the [header..latch] index span — keeps a sibling exit block that
    // merely *sits* inside that span (e.g. a for-exit placed before the join)
    // out of the loop, so the guard's exit edge is correctly seen to leave it.
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *loopBody = [NSMutableDictionary dictionary];
    for (NSUInteger li = 0; li < nb; li++) {
        for (NSNumber *hn in succs[li]) {
            NSUInteger hidx = hn.unsignedIntegerValue;
            if (hidx > li) continue;                  // not a back-edge
            NSMutableSet<NSNumber *> *body = loopBody[@(hidx)];
            if (!body) { body = [NSMutableSet setWithObject:@(hidx)]; loopBody[@(hidx)] = body; }
            NSMutableArray<NSNumber *> *wl = [NSMutableArray arrayWithObject:@(li)];
            while (wl.count) {
                NSNumber *n = wl.lastObject; [wl removeLastObject];
                if ([body containsObject:n]) continue;
                [body addObject:n];
                if (n.unsignedIntegerValue != hidx)
                    for (NSNumber *p in preds[n.unsignedIntegerValue]) [wl addObject:p];
            }
        }
    }

    // Loop-guard bounds: for each loop header whose terminator is a CondBranch on
    // an `ICmp <less> (phi, B)` taking the in-loop edge, bound that phi by B.
    NSMutableDictionary<NSNumber *, NSNumber *> *guardBound = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *memo = [NSMutableDictionary dictionary];
    for (NSUInteger hi = 0; hi < nb; hi++) {
        NSMutableSet<NSNumber *> *body = loopBody[@(hi)];
        if (!body) continue;                          // not a loop header
        XTIRBlock *H = blocks[hi];
        XTIRInsn *term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3) continue;
        if (term.operands[0].kind != XTIROperandKindUse) continue;
        XTIRInsn *cmp = ctx.defOf[@(term.operands[0].valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2) continue;
        // Which side is a header phi?
        XTIROperand *o0 = cmp.operands[0], *o1 = cmp.operands[1];
        BOOL phiIs0 = NO, phiIs1 = NO;
        for (XTIRInsn *p in H.phiNodes) {
            if (p.result && o0.kind == XTIROperandKindUse && o0.valueId == p.result.valueId) phiIs0 = YES;
            if (p.result && o1.kind == XTIROperandKindUse && o1.valueId == p.result.valueId) phiIs1 = YES;
        }
        if (phiIs0 == phiIs1) continue;               // need exactly one side a phi
        XTIROperand *phiOp = phiIs0 ? o0 : o1;
        XTIROperand *boundOp = phiIs0 ? o1 : o0;
        XTIRICmpPredicate pred = cmp.predicate;
        // Determine the in-loop edge. SOUNDNESS: the guard bounds the phi only if
        // every in-loop block is reached *through* this branch — i.e. exactly one
        // target stays in the loop (the body) and the other exits. Then the only
        // way past the header into the loop is the body edge, so the predicate
        // holds at every in-loop use of the phi (back-edges re-enter via here).
        NSUInteger trueIdx  = [blocks indexOfObjectIdenticalTo:term.operands[1].blockRef];
        NSUInteger falseIdx = [blocks indexOfObjectIdenticalTo:term.operands[2].blockRef];
        BOOL trueInLoop  = (trueIdx  != NSNotFound && [body containsObject:@(trueIdx)]);
        BOOL falseInLoop = (falseIdx != NSNotFound && [body containsObject:@(falseIdx)]);
        if (trueInLoop == falseInLoop) continue;     // need exactly one body edge
        // Predicate as seen with the phi on the left, on the body edge.
        XTIRICmpPredicate eff = phiIs0 ? pred : [self swapICmpOperands:pred];
        if (!trueInLoop) eff = [self negateICmpPredicate:eff];   // body on the false edge
        // Only unsigned upper-bounds give a sound zero-extend bound.
        if (eff != XTIRICmpULT && eff != XTIRICmpULE) continue;
        NSMutableSet<NSNumber *> *visiting = [NSMutableSet set];
        uint64_t b = [self ubCleanForValue:boundOp.valueId ctx:ctx guardBound:guardBound
                                      memo:memo visiting:visiting];
        if (boundOp.kind == XTIROperandKindImmI)
            b = boundOp.intValue >= 0 ? (uint64_t)boundOp.intValue : UINT64_MAX;
        if (b == UINT64_MAX) continue;
        // `phi < b` ⟹ phi ≤ b too (b is a safe over-estimate for both ult/ule).
        guardBound[@(phiOp.valueId)] = @(b);
        [memo removeAllObjects];                       // bounds changed → recompute clean
    }

    // Intermediate (non-header) exit guards. A var-trip-unrolled loop re-checks
    // `k ≤ bound` before every replicated body, so the increment feeding the next
    // step (or the loop-back phi) is bounded by that check even though it is not a
    // loop-header phi. Generalise the guard bound to ANY `CondBranch ICmp <ult/ule>
    // (v, B)` whose v ≤ B edge dominates EVERY (non-guard) use of v — then v ≤ B
    // holds soundly at all those uses (SSA-immutable, dominance-checked), capping
    // the otherwise-compounding `k += stride` chain so its uxtb/uxth can drop.
    {
        // Iterative dominators over the CFG (block 0 = entry). dom[n] = {n} ∪ ⋂dom[p].
        NSMutableArray<NSMutableIndexSet *> *dom = [NSMutableArray array];
        NSMutableIndexSet *uni = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, nb)];
        for (NSUInteger i = 0; i < nb; i++)
            [dom addObject:(i == 0 ? [NSMutableIndexSet indexSetWithIndex:0] : [uni mutableCopy])];
        BOOL dc = YES;
        while (dc) {
            dc = NO;
            for (NSUInteger n = 1; n < nb; n++) {
                NSMutableIndexSet *it = nil;
                for (NSNumber *p in preds[n]) {
                    if (!it) it = [dom[p.unsignedIntegerValue] mutableCopy];
                    else {
                        NSMutableIndexSet *keep = [NSMutableIndexSet indexSet];
                        [it enumerateIndexesUsingBlock:^(NSUInteger x, BOOL *s){
                            if ([dom[p.unsignedIntegerValue] containsIndex:x]) [keep addIndex:x]; }];
                        it = keep;
                    }
                }
                if (!it) it = [NSMutableIndexSet indexSet];
                [it addIndex:n];
                if (![it isEqualToIndexSet:dom[n]]) { dom[n] = it; dc = YES; }
            }
        }
        // value → block indices where it is used (and the insns, to skip the guard).
        NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *useBlk = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSMutableArray<XTIRInsn *> *> *useIn = [NSMutableDictionary dictionary];
        for (NSUInteger bi = 0; bi < nb; bi++) {
            XTIRBlock *bb = blocks[bi];
            void (^rec)(XTIRInsn *) = ^(XTIRInsn *ins){
                for (XTIROperand *o in ins.operands)
                    if (o.kind == XTIROperandKindUse) {
                        NSMutableArray *a = useBlk[@(o.valueId)];
                        if (!a) { a = [NSMutableArray array]; useBlk[@(o.valueId)] = a;
                                  useIn[@(o.valueId)] = [NSMutableArray array]; }
                        [a addObject:@(bi)];
                        [useIn[@(o.valueId)] addObject:ins];
                    }
            };
            for (XTIRInsn *p in bb.phiNodes) rec(p);
            for (XTIRInsn *ins in bb.instructions) rec(ins);
            if (bb.terminator) rec(bb.terminator);
        }
        for (NSUInteger bg = 0; bg < nb; bg++) {
            XTIRInsn *term = blocks[bg].terminator;
            if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3) continue;
            if (term.operands[0].kind != XTIROperandKindUse) continue;
            XTIRInsn *cmp = ctx.defOf[@(term.operands[0].valueId)];
            if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2) continue;
            XTIROperand *o0 = cmp.operands[0], *o1 = cmp.operands[1];
            // Exactly one side a value v we can bound; the other the bound B.
            XTIROperand *vOp = (o0.kind == XTIROperandKindUse) ? o0 : nil;
            XTIROperand *bOp = o1;
            BOOL vIs0 = YES;
            if (!vOp && o1.kind == XTIROperandKindUse) { vOp = o1; bOp = o0; vIs0 = NO; }
            if (!vOp) continue;
            // Effective predicate with v on the left for the TRUE edge.
            XTIRICmpPredicate eff = vIs0 ? cmp.predicate : [self swapICmpOperands:cmp.predicate];
            NSUInteger ctIdx;
            if (eff == XTIRICmpULT || eff == XTIRICmpULE) {
                ctIdx = [blocks indexOfObjectIdenticalTo:term.operands[1].blockRef];     // true edge
            } else {
                XTIRICmpPredicate ne = [self negateICmpPredicate:eff];
                if (ne != XTIRICmpULT && ne != XTIRICmpULE) continue;
                ctIdx = [blocks indexOfObjectIdenticalTo:term.operands[2].blockRef];     // false edge
            }
            if (ctIdx == NSNotFound) continue;
            // SOUNDNESS: ct's ONLY predecessor must be the guard block, so the
            // only way to reach ct (and the uses below) is across the guard's
            // v ≤ B edge. A multi-pred ct could be entered on a path that skips
            // the guard, where v may exceed B — dominance of the uses by ct is
            // not enough on its own. (The unrolled `k ≤ bound` checks each fall
            // straight through to the next single-pred body block, so this holds.)
            if (preds[ctIdx].count != 1) continue;
            // Bound B must be a known non-negative upper bound.
            uint64_t B;
            if (bOp.kind == XTIROperandKindImmI) {
                if (bOp.intValue < 0) continue;
                B = (uint64_t)bOp.intValue;
            } else if (bOp.kind == XTIROperandKindUse) {
                NSMutableSet<NSNumber *> *vis = [NSMutableSet set];
                B = [self ubCleanForValue:bOp.valueId ctx:ctx guardBound:guardBound memo:memo visiting:vis];
                if (B == UINT64_MAX) continue;
            } else continue;
            // SOUND iff every use of v — except the guard's own ICmp — is in a
            // block dominated by the continue target ct (so v ≤ B holds there).
            NSArray<NSNumber *> *ubs = useBlk[@(vOp.valueId)];
            NSArray<XTIRInsn *> *uin = useIn[@(vOp.valueId)];
            BOOL ok = YES;
            for (NSUInteger u = 0; u < ubs.count; u++) {
                if (uin[u] == cmp) continue;                     // the guard test itself
                if (![dom[ubs[u].unsignedIntegerValue] containsIndex:ctIdx]) { ok = NO; break; }
            }
            if (!ok) continue;
            NSNumber *cur = guardBound[@(vOp.valueId)];
            if (!cur || cur.unsignedLongLongValue > B) {
                guardBound[@(vOp.valueId)] = @(B);
                [memo removeAllObjects];
            }
        }
    }

    // Decide no-canon for every U8/U16 arithmetic result.
    for (XTIRBlock *bb in blocks) {
        for (XTIRInsn *insn in bb.instructions) {
            if (!insn.result) continue;
            XTIRTypeKind k = insn.result.type.kind;
            if (k != XTIRTypeKindU8 && k != XTIRTypeKindU16) continue;
            switch (insn.opcode) {
                case XTIROpAdd: case XTIROpMul: case XTIROpShl:
                case XTIROpAnd: case XTIROpZExt:
                case XTIROpConst:           // a literal already in range needs no mask
                    break;
                default: continue;          // only ops whose ubRaw we model
            }
            NSMutableSet<NSNumber *> *visiting = [NSMutableSet set];
            // ignoreGuard:YES — this value's OWN guard bound must not let its
            // definition drop its mask (the guard compare reads it pre-mask).
            uint64_t raw = [self ubRawForValue:insn.result.valueId ctx:ctx
                                    guardBound:guardBound memo:memo visiting:visiting
                                          tmax:[self unsignedTypeMax:insn.result.type]
                                   ignoreGuard:YES];
            if (raw <= [self unsignedTypeMax:insn.result.type])
                [ctx.noCanon addObject:@(insn.result.valueId)];
        }
    }
}

// ULT↔UGT, ULE↔UGE, SLT↔SGT, SLE↔SGE, EQ/NE fixed — predicate when the operands
// are swapped.
+ (XTIRICmpPredicate)swapICmpOperands:(XTIRICmpPredicate)p {
    switch (p) {
        case XTIRICmpULT: return XTIRICmpUGT;  case XTIRICmpUGT: return XTIRICmpULT;
        case XTIRICmpULE: return XTIRICmpUGE;  case XTIRICmpUGE: return XTIRICmpULE;
        case XTIRICmpSLT: return XTIRICmpSGT;  case XTIRICmpSGT: return XTIRICmpSLT;
        case XTIRICmpSLE: return XTIRICmpSGE;  case XTIRICmpSGE: return XTIRICmpSLE;
        default: return p;
    }
}

// The predicate that holds on the complementary edge.
+ (XTIRICmpPredicate)negateICmpPredicate:(XTIRICmpPredicate)p {
    switch (p) {
        case XTIRICmpULT: return XTIRICmpUGE;  case XTIRICmpUGE: return XTIRICmpULT;
        case XTIRICmpULE: return XTIRICmpUGT;  case XTIRICmpUGT: return XTIRICmpULE;
        case XTIRICmpSLT: return XTIRICmpSGE;  case XTIRICmpSGE: return XTIRICmpSLT;
        case XTIRICmpSLE: return XTIRICmpSGT;  case XTIRICmpSGT: return XTIRICmpSLE;
        case XTIRICmpEQ:  return XTIRICmpNE;   case XTIRICmpNE:  return XTIRICmpEQ;
        default: return p;
    }
}

// Emit a fused instruction recorded by computeFusionsForCtx in place of `insn`.
+ (void)emitFused:(NSDictionary *)fz forInsn:(XTIRInsn *)insn ctx:(XTArm64FnCtx *)ctx {
    NSString *kind = fz[@"kind"];
    if ([kind isEqualToString:@"scvtf"]) {
        NSString *src = [self operandReg:fz[@"src"] intoScratch:@"w16" ctx:ctx];
        NSString *dst = [self resultReg:insn.result.valueId
                                scratch:[self fregName:0 forType:insn.result.type] ctx:ctx];
        [ctx.out appendFormat:@"    %@ %@, %@, #%@\n",
         [fz[@"signed"] boolValue] ? @"scvtf" : @"ucvtf", dst, src, fz[@"fbits"]];
        [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
    } else if ([kind isEqualToString:@"shiftop"]) {
        XTIRType *ty = insn.result.type;
        NSString *ra = [self operandReg:fz[@"a"] intoScratch:[self regName:16 forType:ty] ctx:ctx];
        NSString *rs = [self operandReg:fz[@"src"] intoScratch:[self regName:17 forType:ty] ctx:ctx];
        NSString *d  = [self resultReg:insn.result.valueId
                               scratch:[self regName:16 forType:ty] ctx:ctx];
        [ctx.out appendFormat:@"    %@ %@, %@, %@, %@ #%@\n",
         fz[@"mnem"], d, ra, rs, fz[@"sh"], fz[@"amt"]];
        if (![ctx.noCanon containsObject:@(insn.result.valueId)])
            [self canonicaliseReg:d toType:ty ctx:ctx];
        [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
    } else if ([kind isEqualToString:@"fma"]) {
        XTIRType *ty = insn.result.type;
        NSString *ra = [self operandReg:fz[@"a"] intoScratch:[self fregName:0 forType:ty] ctx:ctx];
        NSString *rb = [self operandReg:fz[@"b"] intoScratch:[self fregName:1 forType:ty] ctx:ctx];
        NSString *rc = [self operandReg:fz[@"c"] intoScratch:[self fregName:2 forType:ty] ctx:ctx];
        NSString *d  = [self resultReg:insn.result.valueId scratch:[self fregName:0 forType:ty] ctx:ctx];
        [ctx.out appendFormat:@"    %@ %@, %@, %@, %@\n", fz[@"mnem"], d, ra, rb, rc];
        [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
    }
}

// Unsigned magic-number division (Hacker's Delight §10-9), W ∈ {8,16,32}.
// x/d == (a==0) ? mulhu(x,M) >>u s : (t + ((x-t)>>u 1)) >>u (s-1), t=mulhu(x,M).
static void xtMagicU(uint64_t d, int W, uint64_t *Mout, int *aout, int *sout) {
    uint64_t twoWm1 = (uint64_t)1 << (W - 1);
    uint64_t maxu   = ((uint64_t)1 << W) - 1;
    uint64_t twoW   = (uint64_t)1 << W;
    int a = 0, p = W - 1;
    uint64_t nc = maxu - (twoW % d);
    uint64_t q1 = twoWm1 / nc,        r1 = twoWm1 - q1 * nc;
    uint64_t q2 = (twoWm1 - 1) / d,   r2 = (twoWm1 - 1) - q2 * d;
    uint64_t delta;
    do {
        p++;
        if (r1 >= nc - r1) { q1 = 2*q1 + 1; r1 = 2*r1 - nc; }
        else               { q1 = 2*q1;     r1 = 2*r1; }
        if (r2 + 1 >= d - r2) { if (q2 >= twoWm1 - 1) a = 1; q2 = 2*q2 + 1; r2 = 2*r2 + 1 - d; }
        else                  { if (q2 >= twoWm1)     a = 1; q2 = 2*q2;     r2 = 2*r2 + 1; }
        delta = d - 1 - r2;
    } while (p < 2*W && (q1 < delta || (q1 == delta && r1 == 0)));
    *Mout = (q2 + 1) & maxu;
    *aout = a;
    *sout = p - W;
}

// Signed magic-number division (Hacker's Delight §10-3), W ∈ {8,16,32}, d != 0,
// |d| not a power of two. x/d == ((mulhs(x,M) [+x if M<0] [-x if d<0]) >>s s)
// + (logical sign bit). M is the signed magic, s the post-shift.
static void xtMagicS(int64_t dIn, int W, int64_t *Mout, int *sout) {
    uint64_t two_wm1 = (uint64_t)1 << (W - 1);          // 2^(W-1)
    uint64_t mask    = ((uint64_t)1 << W) - 1;
    int64_t  d  = dIn;
    uint64_t ad = (uint64_t)(d < 0 ? -d : d);           // |d|
    uint64_t t  = two_wm1 + ((uint64_t)d >> (W - 1) & 1);
    uint64_t anc = t - 1 - t % ad;
    int p = W - 1;
    uint64_t q1 = two_wm1 / anc, r1 = two_wm1 - q1 * anc;
    uint64_t q2 = two_wm1 / ad,  r2 = two_wm1 - q2 * ad;
    uint64_t delta;
    do {
        p++;
        q1 = 2*q1; r1 = 2*r1;
        if (r1 >= anc) { q1++; r1 -= anc; }
        q2 = 2*q2; r2 = 2*r2;
        if (r2 >= ad)  { q2++; r2 -= ad; }
        delta = ad - r2;
    } while (q1 < delta || (q1 == delta && r1 == 0));
    int64_t M = (int64_t)((q2 + 1) & mask);
    // sign-extend M from W bits, then negate for a negative divisor.
    if (M & (int64_t)two_wm1) M |= ~(int64_t)mask;
    if (d < 0) M = -M;
    *Mout = M;
    *sout = p - W;
}

// Protocol dispatch through the conformance ITABLE: vtable header word 1 points
// at (protoId, &table) pairs ending in a zero id, and each table lists the
// protocol's methods in declaration order. Both follow from the protocol alone,
// so a library and its client agree on them without agreeing on vtable slot
// numbers, which they cannot do for a protocol the library does not declare
// (Comparable, Hashable). The walk starts with the itable in x16 and leaves the
// matching pair's address there; x17 holds each id and x15 the one sought. The
// arguments are already placed by then, and x15-x17 are never home registers.
+ (void)emitItableWalkFor:(uint32_t)pid hit:(NSString *)hit miss:(NSString *)miss
                      ctx:(XTArm64FnCtx *)ctx {
    [ctx.out appendFormat:@"    mov w15, #%u\n", pid & 0xFFFFu];
    [ctx.out appendFormat:@"    movk w15, #%u, lsl #16\n", (pid >> 16) & 0xFFFFu];
    NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$" withString:@"_"];
    NSUInteger loop = ctx.labelCounter++;
    [ctx.out appendFormat:@".L%@_itab_walk_%lu:\n", fnl, (unsigned long)loop];
    [ctx.out appendString:@"    ldr x17, [x16]\n"];
    [ctx.out appendString:@"    cmp w17, w15\n"];
    [ctx.out appendFormat:@"    b.eq %@\n", hit];
    [ctx.out appendString:@"    add x16, x16, #16\n"];
    [ctx.out appendFormat:@"    cbnz x17, .L%@_itab_walk_%lu\n", fnl, (unsigned long)loop];
    [ctx.out appendFormat:@"    b %@\n", miss];
}

+ (void)emitInsn:(XTIRInsn *)insn
        inBlock:(XTIRBlock *)block
            ctx:(XTArm64FnCtx *)ctx
{
    // Skip defs folded into a fused successor (their result is never read).
    if (insn.result && [ctx.fusedAway containsObject:@(insn.result.valueId)]) return;
    // Skip FieldAddr/ElementAddr folded into a Load/Store's addressing mode.
    if (insn.result && [ctx.foldedAddr containsObject:@(insn.result.valueId)]) return;
    // Skip an ICmp fused into its block's CondBranch (emitted there as cmp+b.cond).
    if (insn.result && [ctx.fusedCmps containsObject:@(insn.result.valueId)]) return;
    // Emit the fused form in place of the normal op at a fusion site.
    if (insn.result && ctx.fuseAt[@(insn.result.valueId)]) {
        [self emitFused:ctx.fuseAt[@(insn.result.valueId)] forInsn:insn ctx:ctx];
        return;
    }
    switch (insn.opcode) {
        // ── Const ──────────────────────────────────────────────────
        case XTIROpConst: {
            if (insn.operands.count < 1 || !insn.result) break;
            // A non-homed small unsigned int Const is rematerialised at each use
            // (loadValue), so its slot def is dead — skip emitting it.
            if ([self rematConst:insn.result.valueId imm:NULL ctx:ctx]) break;
            XTIROperand *imm = insn.operands[0];
            // Float Const: the immF carries the abstract value as raw
            // IEEE-754 double bits. arm64 uses native IEEE, so store
            // the single/double bit pattern straight into the slot.
            if (XTIRTypeKindIsFloating(insn.result.type.kind)) {
                double dv = 0.0;
                uint64_t draw = imm.floatRawBytes;
                memcpy(&dv, &draw, sizeof(dv));
                if (insn.result.type.kind == XTIRTypeKindF64) {
                    [self materialiseImm64:draw intoXReg:@"x16" ctx:ctx];
                    [self storeReg:@"x16" intoValue:insn.result.valueId ctx:ctx];
                } else {
                    float fv = (float)dv;
                    uint32_t fbits = 0;
                    memcpy(&fbits, &fv, sizeof(fbits));
                    [self materialiseImm32:fbits intoWReg:@"w16" ctx:ctx];
                    [self storeReg:@"w16" intoValue:insn.result.valueId ctx:ctx];
                }
                break;
            }
            // The scratch is sized to the RESULT. Hardcoding w16 meant an
            // UNHOMED 64-bit constant materialised only its low half —
            // materialiseOperand picks its 32-bit path from the register name —
            // and storeReg then wrote four bytes where the value is eight, so
            // the next 8-byte load pulled the top half out of frame garbage.
            // Invisible at -O2+, where the constant folds away; the fuzzer found
            // it at -O0, where nothing folds (seed 960291). Same family as the
            // Neg/Not scratch bug in this file.
            NSString *sc = [self regName:16 forType:insn.result.type];
            NSString *d = [self resultReg:insn.result.valueId scratch:sc ctx:ctx];
            [self materialiseOperand:imm intoReg:d ctx:ctx];
            // A literal already inside its type's range needs no mask — the
            // arithmetic paths consult noCanon, this one used to mask
            // unconditionally, so `u16 n = 16` emitted `mov w0,#16; uxth w0,w0`.
            if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                [self canonicaliseReg:d toType:insn.result.type ctx:ctx];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Binary integer arith / bitwise ────────────────────────
        case XTIROpAdd: case XTIROpSub: case XTIROpMul:
        case XTIROpSDiv: case XTIROpUDiv:
        case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpSRem: case XTIROpURem:
        {
            if (insn.operands.count < 2 || !insn.result) break;
            // Unsigned division / remainder by a compile-time constant → magic
            // reciprocal multiply (umull + shifts), avoiding the slow `udiv`.
            if (insn.opcode == XTIROpUDiv || insn.opcode == XTIROpURem) {
                int64_t dC = 0; BOOL haveD = NO;
                XTIROperand *dv = insn.operands[1];
                if (dv.kind == XTIROperandKindImmI) { dC = dv.intValue; haveD = YES; }
                else if (dv.kind == XTIROperandKindUse) {
                    // Walk through the ZExt/SExt/Trunc of a Const (the widened-
                    // literal form the lowering emits for `x / 7`).
                    XTIRValueId cur = dv.valueId;
                    for (int g = 0; g < 8; g++) {
                        XTIRInsn *dd = ctx.defOf[@(cur)];
                        if (!dd || dd.operands.count < 1) break;
                        if (dd.opcode == XTIROpConst && dd.operands[0].kind == XTIROperandKindImmI) {
                            dC = dd.operands[0].intValue; haveD = YES; break;
                        }
                        if ((dd.opcode == XTIROpZExt || dd.opcode == XTIROpSExt || dd.opcode == XTIROpTrunc) &&
                            dd.operands[0].kind == XTIROperandKindUse) { cur = dd.operands[0].valueId; continue; }
                        break;
                    }
                }
                int W = (int)(insn.result.type.byteWidth * 8);
                if (haveD && dC >= 2 && ((uint64_t)dC & ((uint64_t)dC - 1)) != 0 &&
                    (W == 8 || W == 16 || W == 32)) {
                    uint64_t M; int aa, s;
                    xtMagicU((uint64_t)dC, W, &M, &aa, &s);
                    NSString *x = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
                    NSString *dst = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
                    // M → w17 (movz + optional movk for the high half).
                    [ctx.out appendFormat:@"    movz w17, #%llu\n", (unsigned long long)(M & 0xffff)];
                    if (M >> 16) [ctx.out appendFormat:@"    movk w17, #%llu, lsl #16\n", (unsigned long long)((M >> 16) & 0xffff)];
                    // t = mulhu(x, M) = (x*M) >> W, in w15.
                    [ctx.out appendFormat:@"    umull x15, %@, w17\n", x];
                    [ctx.out appendFormat:@"    lsr x15, x15, #%d\n", W];
                    NSString *q;                            // the quotient register
                    if (aa == 0) {
                        q = (insn.opcode == XTIROpUDiv) ? dst : @"w15";
                        [ctx.out appendFormat:@"    lsr %@, w15, #%d\n", q, s];
                    } else {                                 // t + ((x - t) >> 1), then >> (s-1)
                        [ctx.out appendFormat:@"    sub w17, %@, w15\n", x];
                        [ctx.out appendString:@"    lsr w17, w17, #1\n"];
                        [ctx.out appendString:@"    add w15, w15, w17\n"];
                        q = (insn.opcode == XTIROpUDiv) ? dst : @"w15";
                        [ctx.out appendFormat:@"    lsr %@, w15, #%d\n", q, s - 1];
                    }
                    if (insn.opcode == XTIROpURem) {        // r = x - q*d
                        [ctx.out appendFormat:@"    movz w17, #%llu\n", (unsigned long long)((uint64_t)dC & 0xffff)];
                        if ((uint64_t)dC >> 16) [ctx.out appendFormat:@"    movk w17, #%llu, lsl #16\n", (unsigned long long)(((uint64_t)dC >> 16) & 0xffff)];
                        [ctx.out appendFormat:@"    msub %@, %@, w17, %@\n", dst, q, x];
                    }
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dst toType:insn.result.type ctx:ctx];
                    [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
            }
            // Signed division / remainder by a 32-bit compile-time constant →
            // signed magic multiply (smull + shifts + sign correction).
            if (insn.opcode == XTIROpSDiv || insn.opcode == XTIROpSRem) {
                int64_t dC = 0; BOOL haveD = NO;
                XTIROperand *dv = insn.operands[1];
                if (dv.kind == XTIROperandKindImmI) { dC = dv.intValue; haveD = YES; }
                else if (dv.kind == XTIROperandKindUse) {
                    XTIRValueId cur = dv.valueId;
                    for (int g = 0; g < 8; g++) {
                        XTIRInsn *dd = ctx.defOf[@(cur)];
                        if (!dd || dd.operands.count < 1) break;
                        if (dd.opcode == XTIROpConst && dd.operands[0].kind == XTIROperandKindImmI) {
                            dC = dd.operands[0].intValue; haveD = YES; break;
                        }
                        if ((dd.opcode == XTIROpZExt || dd.opcode == XTIROpSExt || dd.opcode == XTIROpTrunc) &&
                            dd.operands[0].kind == XTIROperandKindUse) { cur = dd.operands[0].valueId; continue; }
                        break;
                    }
                }
                int W = (int)(insn.result.type.byteWidth * 8);
                uint64_t adC = (uint64_t)(dC < 0 ? -dC : dC);
                if (haveD && W == 32 && adC >= 2 && (adC & (adC - 1)) != 0) {
                    int64_t M; int s;
                    xtMagicS(dC, W, &M, &s);
                    uint32_t Mu = (uint32_t)M;
                    NSString *x = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
                    NSString *dst = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
                    [ctx.out appendFormat:@"    movz w17, #%u\n", Mu & 0xffff];
                    if (Mu >> 16) [ctx.out appendFormat:@"    movk w17, #%u, lsl #16\n", (Mu >> 16) & 0xffff];
                    // q = mulhs(x, M) = (x*M) >>s 32, in w15.
                    [ctx.out appendFormat:@"    smull x15, %@, w17\n", x];
                    [ctx.out appendString:@"    asr x15, x15, #32\n"];
                    if (dC > 0 && M < 0) [ctx.out appendFormat:@"    add w15, w15, %@\n", x];
                    if (dC < 0 && M > 0) [ctx.out appendFormat:@"    sub w15, w15, %@\n", x];
                    [ctx.out appendFormat:@"    asr w15, w15, #%d\n", s];   // arithmetic post-shift
                    NSString *q = (insn.opcode == XTIROpSDiv) ? dst : @"w15";
                    [ctx.out appendFormat:@"    add %@, w15, w15, lsr #31\n", q];   // + sign bit
                    if (insn.opcode == XTIROpSRem) {        // r = x - q*d
                        uint32_t du = (uint32_t)dC;
                        [ctx.out appendFormat:@"    movz w17, #%u\n", du & 0xffff];
                        if (du >> 16) [ctx.out appendFormat:@"    movk w17, #%u, lsl #16\n", (du >> 16) & 0xffff];
                        [ctx.out appendFormat:@"    msub %@, %@, w17, %@\n", dst, q, x];
                    }
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dst toType:insn.result.type ctx:ctx];
                    [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
            }
            // Fold a small constant addend/subtrahend into the imm12 form
            // (`add d, a, #imm` / `sub d, a, #imm`) instead of materialising it.
            if (insn.opcode == XTIROpAdd || insn.opcode == XTIROpSub) {
                NSString *immSh = [self imm12ShiftedForOperand:insn.operands[1] ctx:ctx];
                if (immSh) {
                    NSString *sc = [self regName:16 forType:insn.result.type];
                    NSString *ar = [self operandReg:insn.operands[0] intoScratch:sc ctx:ctx];
                    NSString *dr = [self resultReg:insn.result.valueId scratch:sc ctx:ctx];
                    [ctx.out appendFormat:@"    %@ %@, %@, #%@\n",
                        insn.opcode == XTIROpAdd ? @"add" : @"sub", dr, ar, immSh];
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dr toType:insn.result.type ctx:ctx];
                    [self storeReg:dr intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
                NSNumber *imm = [self imm12ForOperand:insn.operands[1] ctx:ctx];
                if (imm) {
                    // The scratch is SIZED BY THE RESULT TYPE, like the
                    // register-register path below. Hard-coded w16 was
                    // invisible while the u64 loop variable stayed homed
                    // (operandReg returns the X-view home) — but an UNHOMED
                    // one materialised into w16 (truncating it) and emitted
                    // `add x10, w16, #1`, invalid AArch64 that the in-house
                    // assembler used to encode as the silently-wrong X view
                    // (blewit F10's emission half; rd_spike's u32 dodge).
                    NSString *sc = [self regName:16 forType:insn.result.type];
                    NSString *ar = [self operandReg:insn.operands[0] intoScratch:sc ctx:ctx];
                    NSString *dr = [self resultReg:insn.result.valueId scratch:sc ctx:ctx];
                    [ctx.out appendFormat:@"    %@ %@, %@, #%@\n",
                        insn.opcode == XTIROpAdd ? @"add" : @"sub", dr, ar, imm];
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dr toType:insn.result.type ctx:ctx];
                    [self storeReg:dr intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
            }
            // Fold a bitmask constant into the logical-immediate form
            // (`and/orr/eor d, a, #imm`) instead of building it in a register.
            // A mask like 0x0F0F0F0F cost movz + movk + the op; it is one
            // instruction here.
            if (insn.opcode == XTIROpAnd || insn.opcode == XTIROpOr ||
                insn.opcode == XTIROpXor) {
                int64_t kv = 0;
                BOOL haveK = NO;
                XTIROperand *ro = insn.operands[1];
                if (ro.kind == XTIROperandKindImmI) { kv = ro.intValue; haveK = YES; }
                else if (ro.kind == XTIROperandKindUse) {
                    XTIRInsn *d = ctx.defOf[@(ro.valueId)];
                    if (d && d.opcode == XTIROpConst && d.operands.count >= 1 &&
                        d.operands[0].kind == XTIROperandKindImmI) {
                        kv = d.operands[0].intValue; haveK = YES;
                    }
                }
                int dw = (insn.result.type && insn.result.type.byteWidth == 8) ? 64 : 32;
                if (haveK && arm64LogicalImm((uint64_t)kv, dw)) {
                    NSString *sc = [self regName:16 forType:insn.result.type];
                    NSString *ar = [self operandReg:insn.operands[0] intoScratch:sc ctx:ctx];
                    NSString *dr = [self resultReg:insn.result.valueId scratch:sc ctx:ctx];
                    NSString *mn = insn.opcode == XTIROpAnd ? @"and"
                                 : insn.opcode == XTIROpOr  ? @"orr" : @"eor";
                    uint64_t mask = (dw == 64) ? ~0ULL : 0xFFFFFFFFULL;
                    // Decimal, not hex: the two compilers must emit the same
                    // TEXT, and their printf implementations disagree on how
                    // %llx pads. all-diff caught it as 793/793 arm64 files
                    // differing by `#0x7` against `#0x0000000000000007`.
                    [ctx.out appendFormat:@"    %@ %@, %@, #%llu\n", mn, dr, ar,
                     (unsigned long long)((uint64_t)kv & mask)];
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dr toType:insn.result.type ctx:ctx];
                    [self storeReg:dr intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
            }
            // Fold a constant shift count into the immediate form
            // (`lsl d, a, #k`). The count's own type is narrow, so the
            // register path below materialised it, homed it to a frame slot
            // and zero-extended it — four instructions for what the hardware
            // takes as one operand. The immediate range is the DESTINATION
            // width: 0..31 for a w view, 0..63 for an x view; anything else
            // falls through to the register path unchanged.
            if (insn.opcode == XTIROpShl || insn.opcode == XTIROpLShr ||
                insn.opcode == XTIROpAShr) {
                // The count is narrowed by lowering, so it usually arrives as a
                // ZExt/SExt/Trunc of the literal rather than a bare Const —
                // follow that chain before giving up.
                NSNumber *cntN = [self imm12ForOperand:insn.operands[1] ctx:ctx];
                if (!cntN) {
                    XTIROperand *co = insn.operands[1];
                    for (int hops = 0; hops < 4 && co && co.kind == XTIROperandKindUse; hops++) {
                        XTIRInsn *cd = ctx.defOf[@(co.valueId)];
                        if (!cd || cd.operands.count < 1) break;
                        if (cd.opcode != XTIROpZExt && cd.opcode != XTIROpSExt &&
                            cd.opcode != XTIROpTrunc) break;
                        co = cd.operands[0];
                        cntN = [self imm12ForOperand:co ctx:ctx];
                        if (cntN) break;
                    }
                }
                NSUInteger dw = (insn.result.type && insn.result.type.byteWidth == 8) ? 64 : 32;
                int64_t k = cntN ? cntN.longLongValue : -1;
                if (cntN && k >= 0 && k < (int64_t)dw) {
                    NSString *sc = [self regName:16 forType:insn.result.type];
                    NSString *ar = [self operandReg:insn.operands[0] intoScratch:sc ctx:ctx];
                    NSString *dr = [self resultReg:insn.result.valueId scratch:sc ctx:ctx];
                    // Same narrow-signed guard the register path carries: a
                    // LOGICAL right shift of a narrow SIGNED value must shift
                    // the value, not the sign-extended register.
                    if (insn.opcode == XTIROpLShr && insn.result.type
                        && XTIRTypeKindIsSigned(insn.result.type.kind)
                        && insn.result.type.byteWidth < 4 && [ar hasPrefix:@"w"]) {
                        NSString *ext = insn.result.type.byteWidth == 1 ? @"uxtb" : @"uxth";
                        [ctx.out appendFormat:@"    %@ w16, %@\n", ext, ar];
                        ar = @"w16";
                    }
                    NSString *mn = insn.opcode == XTIROpShl  ? @"lsl"
                                 : insn.opcode == XTIROpLShr ? @"lsr" : @"asr";
                    [ctx.out appendFormat:@"    %@ %@, %@, #%lld\n", mn, dr, ar, (long long)k];
                    if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                        [self canonicaliseReg:dr toType:insn.result.type ctx:ctx];
                    [self storeReg:dr intoValue:insn.result.valueId ctx:ctx];
                    break;
                }
            }
            // Read operands directly from their home registers when homed
            // (no load); the result targets its home register when homed
            // (no store). w15 is the rem quotient scratch — never a home.
            // (NOT x18: x18 is the platform-reserved register on Darwin and
            // may be clobbered by the kernel at any instruction boundary.)
            // The scratch names are SIZED BY THE RESULT TYPE. They used to be
            // hard-coded w16/w17, which was invisible while every integer was
            // 32-bit or narrower — but a homed i64 value is named `x19`, so the
            // pair emitted `lsl x10, w10, w11`: an X destination fed by W
            // sources, which drops the top half of the operands.
            NSString *scratchA = [self regName:16 forType:insn.result.type];
            NSString *scratchB = [self regName:17 forType:insn.result.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:scratchA ctx:ctx];
            NSString *b = [self operandReg:insn.operands[1] intoScratch:scratchB ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:scratchA ctx:ctx];
            NSString *mnem;
            switch (insn.opcode) {
                case XTIROpAdd:  mnem = @"add";  break;
                case XTIROpSub:  mnem = @"sub";  break;
                case XTIROpMul:  mnem = @"mul";  break;
                case XTIROpSDiv: mnem = @"sdiv"; break;
                case XTIROpUDiv: mnem = @"udiv"; break;
                case XTIROpAnd:  mnem = @"and";  break;
                case XTIROpOr:   mnem = @"orr";  break;
                case XTIROpXor:  mnem = @"eor";  break;
                case XTIROpShl:  mnem = @"lsl";  break;
                case XTIROpLShr: mnem = @"lsr";  break;
                case XTIROpAShr: mnem = @"asr";  break;
                default: mnem = nil; break;
            }
            if (insn.opcode == XTIROpSRem || insn.opcode == XTIROpURem) {
                // rem = a - (a / b) * b — needs a temp for the quotient.
                NSString *divOp = (insn.opcode == XTIROpSRem) ? @"sdiv" : @"udiv";
                NSString *q = [self regName:15 forType:insn.result.type];
                [ctx.out appendFormat:@"    %@ %@, %@, %@\n", divOp, q, a, b];
                [ctx.out appendFormat:@"    msub %@, %@, %@, %@\n", d, q, b, a];
            } else if (mnem) {
                // A SHIFT names its count in the destination's width: `lsr x0,
                // x1, x2`, never `lsr x0, x1, w2`. The count's own type is
                // narrow (u8), so a homed count arrives as `w19` and the pair
                // assembles only because our own assembler is lax about it —
                // clang rejects it outright. Move it into the X scratch, which
                // also zeroes the top half, exactly what a 0..63 count wants.
                BOOL isShift = (insn.opcode == XTIROpShl ||
                                insn.opcode == XTIROpLShr ||
                                insn.opcode == XTIROpAShr);
                if (isShift && [d hasPrefix:@"x"] && [b hasPrefix:@"w"]) {
                    [ctx.out appendFormat:@"    mov w17, %@\n", b];
                    b = @"x17";
                }
                // A LOGICAL right shift of a narrow SIGNED value must shift the
                // value, not the register. A narrow value is kept sign-extended
                // in its w register (canonicaliseReg), so `lsr` on i16 -28820
                // shifted 0xFFFF8F6C and pulled the extension bits down into the
                // result. Zero-extend to the type's width first. `>>` on a signed
                // type is an AShr, so the only producer of this shape is the
                // rotate expansion (XTIRLowering synthesises `x rol n` as
                // `(x << rn) | (x LShr rev)`) — which is why every i16/i8 rotate
                // disagreed with the other four back ends while u16/u32 were right.
                if (insn.opcode == XTIROpLShr && insn.result.type
                    && XTIRTypeKindIsSigned(insn.result.type.kind)
                    && insn.result.type.byteWidth < 4 && [a hasPrefix:@"w"]) {
                    NSString *ext = insn.result.type.byteWidth == 1 ? @"uxtb" : @"uxth";
                    [ctx.out appendFormat:@"    %@ w16, %@\n", ext, a];
                    a = @"w16";
                }
                [ctx.out appendFormat:@"    %@ %@, %@, %@\n", mnem, d, a, b];
            }
            // Skip the uxtb/uxth when the no-wrap analysis proved this result
            // can't overflow its width (e.g. a loop induction `i += c` bounded by
            // the loop guard) — masked == unmasked, and the mask is off the
            // loop-carried critical path.
            if (![ctx.noCanon containsObject:@(insn.result.valueId)])
                [self canonicaliseReg:d toType:insn.result.type ctx:ctx];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Unary ─────────────────────────────────────────────────
        case XTIROpNeg: {
            if (insn.operands.count < 1 || !insn.result) break;
            // The scratch must be sized to the RESULT: an i64 negate whose
            // result is unhomed used to take `w16` as its destination while its
            // operand arrived in an x register, and `neg w16, x10` is not a
            // legal pair. (The homed case had the mirror of this bug.)
            NSString *s = [self regName:16 forType:insn.result.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:s ctx:ctx];
            [ctx.out appendFormat:@"    neg %@, %@\n", d, a];
            [self canonicaliseReg:d toType:insn.result.type ctx:ctx];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpNot: {
            if (insn.operands.count < 1 || !insn.result) break;
            NSString *s = [self regName:16 forType:insn.result.type];   // as Neg above
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:s ctx:ctx];
            [ctx.out appendFormat:@"    mvn %@, %@\n", d, a];
            [self canonicaliseReg:d toType:insn.result.type ctx:ctx];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Casts ─────────────────────────────────────────────────
        case XTIROpSExt:
        case XTIROpZExt:
        case XTIROpTrunc:
        case XTIROpBitcast: {
            if (insn.operands.count < 1 || !insn.result) break;
            // A pointer is 8 bytes on arm64, so a Ptr→Ptr bitcast
            // (`(Object@)keyPtr`, `(pointer)key`) must move the full
            // 64-bit value — using the 32-bit `w16` truncates the
            // pointer (high word lost), so casts of heap pointers turn
            // into wild addresses (segfault) or, when the truncated
            // value still looks live, a stale/garbage object that gets
            // double-freed. Integer bitcasts (same-width signedness
            // reinterpretation) stay in `w16`.
            BOOL isPtr = (insn.result.type.kind == XTIRTypeKindPtr);
            // …and the SAME argument applies to an i64/u64 result. Scratching a
            // 64-bit widening through `w16` emitted `mov w16, w<src>`, which
            // neither sign-extends nor carries a high half — so the value was
            // SPILLED as four bytes and reloaded as eight, taking whatever sat
            // in the next slot as its top word. `(i64)-5` read back as
            // 4294967291, and an `i32` 1 stored into an i64 ivar read back as
            // 4294967297 when the adjacent word happened to hold 1.
            BOOL wide = isPtr || [self irTypeNeedsXReg:insn.result.type];
            NSString *reg = wide ? @"x16" : @"w16";
            // The SOURCE is loaded at the source's width, not the result's.
            // Sharing one scratch name meant a widening read its operand with
            // `ldr x16` out of a FOUR-byte slot and took the neighbouring word
            // as the high half — a `u32` 2 arrived as 4294967298.
            XTIRType *srcTy0 = (insn.operands[0].kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:insn.operands[0].valueId].type
                : insn.operands[0].type;
            BOOL srcWide = srcTy0 && ([self irTypeNeedsXReg:srcTy0] || srcTy0.byteWidth >= 8);
            NSString *sreg = srcWide ? @"x16" : @"w16";
            // Read the source from its home (or scratch) and write the
            // result into its home (or scratch), fusing the value move with
            // the canonicalising extend into one instruction: a narrow cast
            // becomes `uxth Wd, Wsrc` rather than `mov Wd, Wsrc` + `uxth`.
            NSString *src = [self operandReg:insn.operands[0] intoScratch:sreg ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:reg ctx:ctx];
            // Pointers need no canonicalisation (the IR Ptr type carries no
            // scalar width); an integer result either extends (sxtb/uxth/…)
            // or, for I32/U32 / same-width bitcast, is a plain move.
            NSString *ext = isPtr ? nil
                          : [self integerExtendMnemonicForType:insn.result.type];
            // Widening a SIGNED 32-bit value into 64 bits is `sxtw Xd, Wn`.
            // There is no narrower mnemonic for it — the table above answers
            // nil for I32/U32 because at 32 bits no extend is needed — so
            // without this the sign was simply dropped.
            XTIRType *srcTy = srcTy0;
            if (!ext && insn.opcode == XTIROpSExt
                && [self irTypeNeedsXReg:insn.result.type]) {
                if (srcTy && srcTy.byteWidth <= 4 && XTIRTypeKindIsSigned(srcTy.kind))
                    ext = @"sxtw";
            }
            // ZERO-extending 32→64 is a 32-bit `mov`: writing a W register
            // clears the top half of its X, and that IS the zero extension.
            // A 64-bit `mov x,x` copies the source register's stale high bits
            // instead — which is what widening the scratch above did on its
            // own, turning a `u8` mask of 0 into 4294967296.
            BOOL zx32to64 = (!ext && wide && !isPtr
                             && insn.opcode != XTIROpSExt
                             && srcTy && !srcWide && srcTy.byteWidth <= 4
                             && !XTIRTypeKindIsFloating(srcTy.kind));
            // A W destination is the RIGHT instruction here and the WRONG name
            // to spill from: writing Wn zeroes the top of Xn (which is the
            // zero-extension), but `storeReg` sizes the spill from the register
            // name, so `str w16` wrote four bytes into an eight-byte slot that
            // was then reloaded with `ldr x17`. Keep the X name for the store.
            NSString *dStore = d;
            if (zx32to64) {
                if ([d hasPrefix:@"x"]) d = [@"w" stringByAppendingString:[d substringFromIndex:1]];
                if ([src hasPrefix:@"x"]) src = [@"w" stringByAppendingString:[src substringFromIndex:1]];
            }
            // uxtb/uxth only take a W destination (and zeroing it clears the
            // whole X); sxtb/sxth/sxtw take either, and a 64-bit result wants X.
            if (ext && wide && [ext hasPrefix:@"u"] && [d hasPrefix:@"x"])
                d = [@"w" stringByAppendingString:[d substringFromIndex:1]];
            if (ext) {
                // sxtb/uxtb/sxth/uxth read a 32-bit Wn source. When the source
                // value is wider than 4 bytes and homed in an x-register (a
                // pointer / 8-byte value being truncated, e.g. `(u16)&arr[i]`),
                // use its w-view (low 32 bits) — `uxth w,x` is not a legal form.
                if ([src hasPrefix:@"x"])
                    src = [@"w" stringByAppendingString:[src substringFromIndex:1]];
                [ctx.out appendFormat:@"    %@ %@, %@\n", ext, d, src];
            } else {
                [self emitMove:d from:src ctx:ctx];
            }
            [self storeReg:dStore intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Comparison ────────────────────────────────────────────
        case XTIROpICmp: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSString *cond = [self emitCompareForICmp:insn ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    cset %@, %@\n", d, cond];
            // Result is Bool — already 0/1, no canonicalisation needed.
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Select (cond ? t : f) ─────────────────────────────────
        case XTIROpSelect: {
            if (insn.operands.count < 3 || !insn.result) break;
            // Match register width to the value type — `w` for 1/2/4-byte
            // scalars, `x` for pointers (8 bytes on arm64) and 8-byte
            // integers. A pointer-selecting csel through `w` registers
            // truncates the address to 32 bits and the subsequent deref
            // crashes (the printf `%e` enum-name lookup hit this — a
            // chain of Selects over u8@ values returned bogus pointers).
            // A float/double Select needs the FP bank and `fcsel`: the integer
            // path loaded both candidates with `ldr w…` and selected into a `d`
            // register, which is not even a legal instruction — it failed as
            // "bad reg d9" at assembly. If-conversion produces these from an
            // `if (x < 0.0) x = -x;`, so any float code with a conditional
            // could hit it. Found by the self-hosted float encoder (M5).
            if (XTIRTypeKindIsFloating(insn.result.type.kind)) {
                BOOL dbl = (insn.result.type.kind == XTIRTypeKindF64);
                // d16/d17 ONLY. d15 was used here as the second operand's
                // scratch, and d15 is in the FP HOME pool (d8-d15) — so an
                // F64 Select silently clobbered whatever value was homed
                // there. The note above the pool says d16/d17 stay out
                // because they are the FP scratch; d15 was overlooked, and
                // this is the one site that used it.
                //
                // Three values fit in two registers because fcsel reads both
                // operands before writing: load op2 into d16 and let the
                // result land on top of it.
                NSString *s1 = dbl ? @"d17" : @"s17";
                NSString *s2 = dbl ? @"d16" : @"s16";
                NSString *s0 = dbl ? @"d16" : @"s16";
                NSString *cr = [self condRegForOperand:insn.operands[0] ctx:ctx];
                [self materialiseOperand:insn.operands[0] intoReg:cr ctx:ctx];
                [self loadFPOperand:insn.operands[1] intoReg:s1 double:dbl ctx:ctx];
                [self loadFPOperand:insn.operands[2] intoReg:s2 double:dbl ctx:ctx];
                [ctx.out appendFormat:@"    cmp %@, #0\n", cr];
                [ctx.out appendFormat:@"    fcsel %@, %@, %@, ne\n", s0, s1, s2];
                [self storeReg:s0 intoValue:insn.result.valueId ctx:ctx];
                break;
            }
            BOOL needX = [self irTypeNeedsXReg:insn.result.type];
            NSString *cr = [self condRegForOperand:insn.operands[0] ctx:ctx];
            [self materialiseOperand:insn.operands[0] intoReg:cr ctx:ctx];
            NSString *r1 = [self operandReg:insn.operands[1]
                                intoScratch:(needX ? @"x17" : @"w17") ctx:ctx];
            NSString *r2 = [self operandReg:insn.operands[2]
                                intoScratch:(needX ? @"x15" : @"w15") ctx:ctx];
            [ctx.out appendFormat:@"    cmp %@, #0\n", cr];
            NSString *r0 = [self resultReg:insn.result.valueId
                                   scratch:(needX ? @"x16" : @"w16") ctx:ctx];
            [ctx.out appendFormat:@"    csel %@, %@, %@, ne\n", r0, r1, r2];
            [self canonicaliseReg:r0 toType:insn.result.type ctx:ctx];
            [self storeReg:r0 intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        // ── Phi: realised by predecessor-edge copies; nothing to
        //         emit at the phi's own location.
        case XTIROpPhi:
            break;

        // ── Call (includes banked/cloaked — no-op on arm64) ─────────
        case XTIROpCall:
        case XTIROpCallBanked:
        case XTIROpCallCloaked: {
            if (insn.operands.count < 2) break;
            XTIROperand *callee = insn.operands[0];
            if (callee.kind != XTIROperandKindSym) break;
            XTIRSymbol *sym = [ctx.module symbolForId:callee.symbolId];
            if (!sym) break;
            // Operands: [callee, arg0, arg1, ..., memInput]. AAPCS64:
            // integer/pointer args fill x0..x7 (gpIdx), float/double
            // args fill the independent v0..v7 bank (fpIdx).
            NSUInteger argCount = insn.operands.count >= 2 ? insn.operands.count - 2 : 0;

            // (Hardware sqrt is no longer a name-matched call here — the
            // SqrtIntrinsic IR pass canonicalises sqrt[f] to the FSqrt op, which
            // the case above instruction-selects to a bare `fsqrt`.)

            NSArray *aTypes = [self arm64ArgTypesForInsn:insn from:1 count:argCount ctx:ctx];
            NSInteger vfrom = [self arm64CVariadicFromForInsn:insn ctx:ctx];
            NSArray<NSNumber *> *stkOff = [self arm64ArgStackOffsets:aTypes startGP:0 startFP:0 totalBytes:NULL variadicFrom:vfrom];
            int gpIdx = 0, fpIdx = 0;
            for (NSUInteger i = 0; i < argCount; i++) {
                XTIROperand *a = insn.operands[i + 1];
                XTIRValue *av = (a.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:a.valueId] : nil;
                if (av && av.type.kind == XTIRTypeKindAgg) {
                    // By-value aggregate arg (AAPCS): an HFA in v-registers, any
                    // other aggregate in consecutive GP registers — OR, when it
                    // overflows its register bank, copied ENTIRELY onto the
                    // outgoing stack area at its classified offset (bug 20/21).
                    if (stkOff[i].integerValue >= 0) {
                        NSUInteger sz = [self arm64AggSize:av.type.layout];
                        [self emitSpAddr:(NSUInteger)stkOff[i].integerValue into:@"x16" ctx:ctx];
                        [self emitAggCopy:sz
                                frameSlot:[self slotOffsetForValue:a.valueId ctx:ctx]
                                  toFrame:NO ctx:ctx];
                    } else if (![self marshalAggArg:a.valueId type:av.type
                                        gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx]) continue;
                } else {
                    [self marshalArgOperand:a value:av stackOffset:stkOff[i].integerValue
                                      gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx];
                }
            }
            // Vararg forward relay (bug 179): a `vaforward` function calling a
            // variadic callee re-passes its OWN incoming tail. Copy a bounded
            // window from the incoming va_list (above this frame) into the
            // outgoing slots that start just past the explicit args. Runs AFTER
            // arg marshalling (x9 free); sema guarantees a forwarder reads no
            // varargs of its own, so its incoming tail is intact.
            if ([self arm64VaForwardRelayForInsn:insn ctx:ctx]) {
                NSUInteger inVa = ctx.frameSize + [self arm64FixedParamStackBytes:ctx];
                NSUInteger tailBase = 0;
                [self arm64ArgStackOffsets:aTypes startGP:0 startFP:0
                                totalBytes:&tailBase variadicFrom:vfrom];
                [ctx.out appendFormat:@"    // vararg forward: relay %lu words #%lu -> #%lu\n",
                 (unsigned long)kArm64VaForwardWords, (unsigned long)inVa, (unsigned long)tailBase];
                for (NSUInteger i = 0; i < kArm64VaForwardWords; i++)
                    [ctx.out appendFormat:@"    ldr x9, [sp, #%lu]\n    str x9, [sp, #%lu]\n",
                     (unsigned long)(inVa + i * 8), (unsigned long)(tailBase + i * 8)];
            }
            // (The fsqrt intrinsic is handled above, before arg marshalling.)
            // >16-byte struct return: pass the result slot in x8 before the call.
            BOOL callSret = [self emitSretSetupIfNeeded:insn ctx:ctx];
            [ctx.out appendFormat:@"    bl _%@\n", sym.name];
            if (insn.result) {
                // AAPCS returns FP in s0/d0; integers/pointers in w0/x0; an
                // aggregate: HFA in v0.., ≤16 B in x0:x1, >16 B non-float via x8.
                if (insn.result.type.kind == XTIRTypeKindAgg) {
                    [self captureAggResult:insn sretUsed:callSret ctx:ctx];
                } else
                if (XTIRTypeKindIsFloating(insn.result.type.kind)) {
                    NSString *fr = [self fregName:0 forType:insn.result.type];
                    [self storeReg:fr intoValue:insn.result.valueId ctx:ctx];
                } else {
                    NSString *destReg = [self regName:0 forType:insn.result.type];
                    if (!([self irTypeNeedsXReg:insn.result.type])) {
                        [self canonicaliseReg:destReg toType:insn.result.type ctx:ctx];
                    }
                    [self storeReg:destReg intoValue:insn.result.valueId ctx:ctx];
                }
            }
            break;
        }
        // ── Branch ───────────────────────────────────────────────
        case XTIROpBranch: {
            if (insn.operands.count < 1) break;
            XTIROperand *tgt = insn.operands[0];
            if (tgt.kind != XTIROperandKindBlock) break;
            [self emitPhiCopiesFrom:block to:tgt.blockRef ctx:ctx];
            [ctx.out appendFormat:@"    b %@\n",
             [self blockLabelForFn:ctx.fn block:tgt.blockRef]];
            break;
        }
        case XTIROpCondBranch: {
            if (insn.operands.count < 3) break;
            XTIROperand *c = insn.operands[0];
            XTIROperand *t = insn.operands[1];
            XTIROperand *f = insn.operands[2];
            // Fused: the condition is a single-use ICmp from this block — emit
            // the `cmp` (setting the flags) and branch on the condition directly,
            // skipping the materialised 0/1 bool + `cbnz`. The cmp runs first;
            // the phi copies (mov/ldr) don't touch the flags, so they may clobber
            // the cmp's operand scratch afterwards and the b.<cond> still reads
            // the right flags.
            if (c.kind == XTIROperandKindUse &&
                [ctx.fusedCmps containsObject:@(c.valueId)]) {
                XTIRInsn *icmp = ctx.defOf[@(c.valueId)];
                // `x == 0` / `x != 0` (EQ/NE against an integer/pointer zero) →
                // `cbz`/`cbnz reg, target` directly, eliding the `cmp #0` that
                // gates the branch (the hot loop-control / null-check path). Only
                // when neither out-edge needs phi copies: cbz reads a register
                // (not flags), so an intervening copy could clobber the operand,
                // and the absence also lets the fall-through/inversion peephole
                // collapse it cleanly. Other edges keep the flags-based path.
                XTIROperand *zval = icmpZeroTestValue(icmp, ctx);
                if (zval &&
                    !phiCopiesNeeded(t.blockRef, block) &&
                    !phiCopiesNeeded(f.blockRef, block)) {
                    XTIRType *vt = (zval.kind == XTIROperandKindUse)
                        ? [ctx.fn valueForId:zval.valueId].type : zval.type;
                    NSString *reg = [self operandReg:zval
                        intoScratch:([self irTypeNeedsXReg:vt] ? @"x16" : @"w16") ctx:ctx];
                    NSString *mnem = (icmp.predicate == 0) ? @"cbz" : @"cbnz";  // EQ→cbz
                    [ctx.out appendFormat:@"    %@ %@, %@\n", mnem, reg,
                     [self blockLabelForFn:ctx.fn block:t.blockRef]];
                    [ctx.out appendFormat:@"    b %@\n",
                     [self blockLabelForFn:ctx.fn block:f.blockRef]];
                    break;
                }
                NSString *cond = [self emitCompareForICmp:icmp ctx:ctx];
                if (takenPhiClobbersFallSrc(t.blockRef, f.blockRef, block)) {
                    // Taken copies would clobber a value the fall copies read;
                    // emit them on the taken path only (invert to skip to fall).
                    XTIRICmpPredicate invp =
                        [self negateICmpPredicate:(XTIRICmpPredicate)icmp.predicate];
                    NSUInteger lbl = ctx.labelCounter++;
                    NSString *Lf = [NSString stringWithFormat:@".Lpc_%lu", (unsigned long)lbl];
                    [ctx.out appendFormat:@"    b.%@ %@\n",
                     [self condStringForICmpPredicate:(uint8_t)invp], Lf];
                    [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
                    [ctx.out appendFormat:@"    b %@\n",
                     [self blockLabelForFn:ctx.fn block:t.blockRef]];
                    [ctx.out appendFormat:@"%@:\n", Lf];
                    [self emitPhiCopiesFrom:block to:f.blockRef ctx:ctx];
                    [ctx.out appendFormat:@"    b %@\n",
                     [self blockLabelForFn:ctx.fn block:f.blockRef]];
                    break;
                }
                [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
                [ctx.out appendFormat:@"    b.%@ %@\n", cond,
                 [self blockLabelForFn:ctx.fn block:t.blockRef]];
                [self emitPhiCopiesFrom:block to:f.blockRef ctx:ctx];
                [ctx.out appendFormat:@"    b %@\n",
                 [self blockLabelForFn:ctx.fn block:f.blockRef]];
                break;
            }
            // Phi copies for both successors. Each successor's phi
            // only references this block if it's an immediate
            // predecessor — emitPhiCopiesFrom handles the absence
            // gracefully by finding no matching pair.
            //
            // The taken-edge phi copies use w16/w17 as scratch, so they
            // MUST run before the branch condition is materialised — else
            // the copy clobbers w16 and the `cbnz` tests a stale value.
            // (This is the short-circuit `||`/`&&`/`?:` pattern, where the
            // taken edge feeds a phi a constant; a plain `if` has no edge
            // phi and was unaffected.) Emitting the taken-edge copies
            // unconditionally here is safe UNLESS a taken-edge copy destination
            // is a fall-edge copy source (takenPhiClobbersFallSrc) — then the
            // taken copy must run on the taken path only. Materialise the branch
            // condition into w16 FIRST (so the post-branch copies can clobber
            // w16 freely) and skip to the fall path when the condition is false.
            if (takenPhiClobbersFallSrc(t.blockRef, f.blockRef, block)) {
                NSString *cr = [self condRegForOperand:c ctx:ctx];
                [self materialiseOperand:c intoReg:cr ctx:ctx];
                NSUInteger lbl = ctx.labelCounter++;
                NSString *Lf = [NSString stringWithFormat:@".Lpc_%lu", (unsigned long)lbl];
                [ctx.out appendFormat:@"    cbz %@, %@\n", cr, Lf];
                [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
                [ctx.out appendFormat:@"    b %@\n",
                 [self blockLabelForFn:ctx.fn block:t.blockRef]];
                [ctx.out appendFormat:@"%@:\n", Lf];
                [self emitPhiCopiesFrom:block to:f.blockRef ctx:ctx];
                [ctx.out appendFormat:@"    b %@\n",
                 [self blockLabelForFn:ctx.fn block:f.blockRef]];
                break;
            }
            [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
            NSString *cr = [self condRegForOperand:c ctx:ctx];
            [self materialiseOperand:c intoReg:cr ctx:ctx];
            [ctx.out appendFormat:@"    cbnz %@, %@\n", cr,
             [self blockLabelForFn:ctx.fn block:t.blockRef]];
            [self emitPhiCopiesFrom:block to:f.blockRef ctx:ctx];
            [ctx.out appendFormat:@"    b %@\n",
             [self blockLabelForFn:ctx.fn block:f.blockRef]];
            break;
        }
        // ── Return ───────────────────────────────────────────────
        case XTIROpReturn: {
            // Operands: [value, memInput] (value optional). Load
            // the return value into x0/w0 (depending on type) if
            // present, then epilogue.
            BOOL hasValue = insn.operands.count > 1;
            if (hasValue) {
                XTIROperand *vop = insn.operands[0];
                XTIRValue *vv = (vop.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:vop.valueId] : nil;
                // AAPCS returns FP in s0/d0. Load the value's slot
                // into the FP return register.
                if (vv && vv.type.kind == XTIRTypeKindAgg) {
                    // Aggregate return, AAPCS: an HFA in v0..v(n-1); a ≤16-byte
                    // aggregate in x0:x1; a >16-byte non-HFA written through the x8
                    // sret pointer the caller passed (stowed in the prologue).
                    XTIRTypeKind ek = XTIRTypeKindVoid;
                    NSUInteger hfa = [self arm64AggHFA:vv.type.layout elemKind:&ek];
                    NSUInteger sz = [self arm64AggSize:vv.type.layout];
                    if (hfa > 0) {
                        NSUInteger esz = (ek == XTIRTypeKindF64) ? 8 : 4;
                        NSString *pfx = (ek == XTIRTypeKindF64) ? @"d" : @"s";
                        for (NSUInteger k = 0; k < hfa; k++)
                            [self loadValue:vop.valueId offset:esz * k
                                    intoReg:[NSString stringWithFormat:@"%@%lu", pfx, (unsigned long)k]
                                        ctx:ctx];
                    } else if (sz > 16 && ctx.sretSaveOffset) {
                        [ctx.out appendFormat:@"    ldr x16, %@\n",
                         [self spMemForOff:ctx.sretSaveOffset reg:@"x16" ctx:ctx]];
                        [self emitAggCopy:sz frameSlot:[self slotOffsetForValue:vop.valueId ctx:ctx]
                                  toFrame:NO ctx:ctx];
                    } else {
                        NSUInteger base = [self slotOffsetForValue:vop.valueId ctx:ctx];
                        [self emitSpAddr:base into:@"x16" ctx:ctx];
                        [ctx.out appendString:@"    ldr x0, [x16]\n"];
                        if (sz > 8) [ctx.out appendString:@"    ldr x1, [x16, #8]\n"];
                    }
                } else if (vv && XTIRTypeKindIsFloating(vv.type.kind)) {
                    NSString *fr = [self fregName:0 forType:vv.type];
                    [self loadValue:vop.valueId intoReg:fr ctx:ctx];
                } else {
                    NSString *reg = vv ? [self regName:0 forType:vv.type] : @"w0";
                    [self materialiseOperand:vop intoReg:reg ctx:ctx];
                }
            }
            // Reload the callee-saved registers. This must come AFTER the
            // return value is read (it may itself be homed in one of these
            // registers) and BEFORE the frame teardown.
            [self emitCalleeSaves:ctx.savedRegs base:ctx.saveAreaOffset
                            toBuf:ctx.out restore:YES];
            if (ctx.maxOutStack == 0) {
                if (ctx.frameSize <= 504) {
                    [ctx.out appendFormat:@"    ldp x29, x30, [sp], #%lu\n",
                     (unsigned long)ctx.frameSize];
                } else {
                    [ctx.out appendString:@"    ldp x29, x30, [sp]\n"];
                    [self emitSpAdjust:(NSInteger)ctx.frameSize ctx:ctx];
                }
            } else {
                // x29/x30 sit at [sp, #maxOutStack], above the outgoing-args area.
                if (ctx.maxOutStack <= 504) {
                    [ctx.out appendFormat:@"    ldp x29, x30, [sp, #%lu]\n",
                     (unsigned long)ctx.maxOutStack];
                } else {
                    [ctx.out appendFormat:@"    add x9, sp, #%lu\n", (unsigned long)ctx.maxOutStack];
                    [ctx.out appendString:@"    ldp x29, x30, [x9]\n"];
                }
                [self emitSpAdjust:(NSInteger)ctx.frameSize ctx:ctx];
            }
            [ctx.out appendString:@"    ret\n"];
            break;
        }
        case XTIROpUnreachable: {
            [ctx.out appendString:@"    brk #0\n"];
            break;
        }

        // ── Memory primitives ─────────────────────────────────────
        case XTIROpLoad:
        case XTIROpLoadVolatile: {
            // Operands: [pointer, memInput]. Loads sized by the
            // pointer's pointee width.
            if (insn.operands.count < 2 || !insn.result) break;
            // Effective address: a single-use FieldAddr/ElementAddr pointer folds
            // into a fused `[base, #off]` / `[base, idx, lsl #s]` (set below);
            // otherwise the flat-host deref stages it into x16.
            BOOL ldFolded = ctx.foldInfo[@(insn.operands[0].valueId)] != nil;
            if (!ldFolded) [self emitDerefAddrFor:insn.operands[0] ctx:ctx];
            XTIRType *pteType = insn.result.type;
            // Aggregate load: a struct value can't ride a single register.
            // Copy the full arm64-native size from [x16] into the result's
            // slot in 8/4/2/1-byte chunks (a single `ldr x17` dropped every
            // byte past the first 8 — e.g. a 12-byte struct returned only
            // its first 8 bytes).
            if (pteType && pteType.kind == XTIRTypeKindAgg) {
                [self emitAggCopy:[self arm64AggSize:pteType.layout]
                        frameSlot:[self slotOffsetForValue:insn.result.valueId ctx:ctx]
                          toFrame:YES ctx:ctx];
                break;
            }
            NSString *ldrMnem;
            NSString *destReg;
            uint32_t pteWidth = pteType ? pteType.byteWidth : 4;
            BOOL pteSigned = pteType ? XTIRTypeKindIsSigned(pteType.kind) : NO;
            if (pteType && pteType.kind == XTIRTypeKindPtr) {
                ldrMnem = @"ldr"; destReg = @"x17";
            } else if (pteType && XTIRTypeKindIsFloating(pteType.kind)) {
                // An FP load needs an FP scratch. Falling through to w17/x17
                // put the value in a GP register, and the only way back out is
                // through the frame — `ldr w17,[p]; str w17,[slot]; ldr s0,[slot]`
                // where `ldr s0,[p]` was wanted.
                ldrMnem = @"ldr"; destReg = [self fregName:16 forType:pteType];
            } else if (pteWidth >= 8) {
                ldrMnem = @"ldr"; destReg = @"x17";   // F64 / 8-byte
            } else if (pteWidth >= 4) {
                ldrMnem = @"ldr"; destReg = @"w17";
            } else if (pteWidth == 2) {
                ldrMnem = pteSigned ? @"ldrsh" : @"ldrh"; destReg = @"w17";
            } else {
                ldrMnem = pteSigned ? @"ldrsb" : @"ldrb"; destReg = @"w17";
            }
            // Load straight into the result's home register when homed (no
            // store). A float result homed in an FP register turns into a
            // direct `ldr s8/d8, [x16]`; the narrow-int ldrsb/ldrsh paths
            // only fire for GP-homed integers, so the width stays valid.
            // Fold the address first (materialises base→x16, index→x17), then
            // pick the dest. A scratch dest of x17 reuses the index register: the
            // load reads x16/x17 to form the address before writing the result.
            NSString *ldAddr = ldFolded ? [self foldedAddrOperandFor:insn ctx:ctx] : @"[x16]";
            destReg = [self resultReg:insn.result.valueId scratch:destReg ctx:ctx];
            [ctx.out appendFormat:@"    %@ %@, %@\n", ldrMnem, destReg, ldAddr];
            [self storeReg:destReg intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpStore:
        case XTIROpStoreVolatile: {
            // Operands: [pointer, value, memInput].
            if (insn.operands.count < 3) break;
            // Effective address: fold a single-use FieldAddr/ElementAddr pointer
            // into the str's addressing mode (set below), else stage into x16.
            BOOL stFolded = ctx.foldInfo[@(insn.operands[0].valueId)] != nil;
            if (!stFolded) [self emitDerefAddrFor:insn.operands[0] ctx:ctx];
            // Pick the value register width from the value operand's
            // resolved IR type.
            XTIRType *vty = nil;
            XTIROperand *vop = insn.operands[1];
            if (vop.kind == XTIROperandKindUse) {
                XTIRValue *vv = [ctx.fn valueForId:vop.valueId];
                vty = vv.type;
            }
            // Aggregate store: copy the value's full slot to [x16] in
            // 8/4/2/1-byte chunks (a single `str x17` truncated to 8 bytes).
            if (vty && vty.kind == XTIRTypeKindAgg && vop.kind == XTIROperandKindUse) {
                [self emitAggCopy:[self arm64AggSize:vty.layout]
                        frameSlot:[self slotOffsetForValue:vop.valueId ctx:ctx]
                          toFrame:NO ctx:ctx];
                break;
            }
            NSString *valReg;
            NSString *strMnem;
            uint32_t valWidth = vty ? vty.byteWidth : 4;
            if (vty && vty.kind == XTIRTypeKindPtr) {
                valReg = @"x17"; strMnem = @"str";
            } else if (valWidth >= 8) {
                valReg = @"x17"; strMnem = @"str";   // F64 / 8-byte
            } else if (valWidth >= 4) {
                valReg = @"w17"; strMnem = @"str";
            } else if (valWidth == 2) {
                valReg = @"w17"; strMnem = @"strh";
            } else {
                valReg = @"w17"; strMnem = @"strb";
            }
            // Store the value's home register directly when homed (a float
            // home yields a direct `str s8/d8`; strh/strb only fire for
            // narrow GP-homed integers, whose w-view is the right width).
            // When folding, base→x16 and index→x17 are live for the addressing
            // mode, so stage the value in x15/w15 instead to avoid clobbering it.
            // (NOT x18: x18 is the platform-reserved register on Darwin and the
            // kernel may clobber it between the mov and the str.)
            NSString *stAddr = @"[x16]";
            if (stFolded) stAddr = [self foldedAddrOperandFor:insn ctx:ctx];
            // Lever 2: store the zero register for an integer `Const #0` value —
            // no mov/extend/spill, and (when single-use) its def is elided too.
            BOOL valIsZero = insn.operands[1].kind == XTIROperandKindUse &&
                [self isIntZeroConst:ctx.defOf[@(insn.operands[1].valueId)]];
            if (valIsZero) {
                valReg = ((vty && vty.kind == XTIRTypeKindPtr) || valWidth >= 8)
                    ? @"xzr" : @"wzr";
            } else {
                // base→x16 and index→x17 are live for a folded addressing mode,
                // so stage the value in x15/w15 to avoid clobbering it.
                if (stFolded) valReg = [valReg stringByReplacingOccurrencesOfString:@"17" withString:@"15"];
                valReg = [self operandReg:insn.operands[1] intoScratch:valReg ctx:ctx];
            }
            [ctx.out appendFormat:@"    %@ %@, %@\n", strMnem, valReg, stAddr];
            break;
        }
        case XTIROpMemCopy: {
            // Operands: [dst, src, size:ImmI, memInput]. Always route
            // to libc memcpy — saves us from worrying about size
            // categorisation. The IR's caller can introduce a more
            // efficient unrolled form via the optimiser.
            if (insn.operands.count < 4) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            [self materialiseOperand:insn.operands[1] intoReg:@"x1" ctx:ctx];
            // Count into w2 (zero-extends to x2): a narrow runtime size value
            // would mis-read 8 bytes from its 4-byte slot via x2.
            [self materialiseOperand:insn.operands[2] intoReg:@"w2" ctx:ctx];
            [ctx.out appendString:@"    bl _memcpy\n"];
            break;
        }
        case XTIROpMemSet: {
            // Operands: [dst, byte:U8, size:ImmI, memInput].
            if (insn.operands.count < 4) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            [self materialiseOperand:insn.operands[1] intoReg:@"w1" ctx:ctx];
            // Count into w2 (zero-extends to x2): see MemCopy.
            [self materialiseOperand:insn.operands[2] intoReg:@"w2" ctx:ctx];
            [ctx.out appendString:@"    bl _memset\n"];
            break;
        }
        case XTIROpAddrOf: {
            // Two operand kinds — symbols (use adrp/add Mach-O dance)
            // and pinned-local Uses (compute sp + slot-offset). The
            // verifier's §12.7 enforces that only these two land
            // here; if a fresh kind appears, fall through to the
            // default "unsupported" comment so triage spots it.
            if (insn.operands.count < 1 || !insn.result) break;
            XTIROperand *op = insn.operands[0];
            // Compute the address straight into the result's home register
            // (no store) when homed.
            NSString *dest = [self resultReg:insn.result.valueId scratch:@"x16" ctx:ctx];
            if (op.kind == XTIROperandKindSym) {
                XTIRSymbol *sym = [ctx.module symbolForId:op.symbolId];
                if (!sym) break;
                BOOL external = sym.isExternalGlobal;
                // An external FUNCTION — a body-less prototype resolved at link
                // (objc_msgSend, any -framework/-l symbol) — likewise has no
                // link-time address, so `&fn` must go through the GOT. It's
                // external iff no function of this name is defined in the module
                // (a local function's `&` keeps the direct adrp/add, which works).
                if (!external && sym.kind == XTIRSymbolKindFunction) {
                    BOOL defined = NO;
                    for (XTIRFunction *fn in ctx.module.functions)
                        if ([fn.name isEqualToString:sym.name]) { defined = YES; break; }
                    external = !defined;
                }
                if (external) {
                    // Defined in ANOTHER module (dylib import — e.g. an imported class's
                    // vtable) or an external function: its address isn't fixed at
                    // static-link time, so take it through the GOT. A direct adrp/add
                    // fails with "target does not have address".
                    [ctx.out appendFormat:@"    adrp %@, _%@@GOTPAGE\n", dest, sym.name];
                    [ctx.out appendFormat:@"    ldr %@, [%@, _%@@GOTPAGEOFF]\n", dest, dest, sym.name];
                } else {
                    [ctx.out appendFormat:@"    adrp %@, _%@@PAGE\n", dest, sym.name];
                    [ctx.out appendFormat:@"    add %@, %@, _%@@PAGEOFF\n", dest, dest, sym.name];
                }
                [self storeReg:dest intoValue:insn.result.valueId ctx:ctx];
            } else if (op.kind == XTIROperandKindUse) {
                // Pinned local: its slot is at sp + slotOffset.
                // `add dest, sp, #<offset>` produces the address.
                NSUInteger offset = [self slotOffsetForValue:op.valueId ctx:ctx];
                [self emitSpAddr:offset into:dest ctx:ctx];
                [self storeReg:dest intoValue:insn.result.valueId ctx:ctx];
            } else {
                [ctx.out appendFormat:@"    // unsupported AddrOf operand kind %d\n",
                 (int)op.kind];
            }
            break;
        }

        // ── Aggregate / field machinery ───────────────────────────
        case XTIROpAggBuild: {
            // Assemble an aggregate value from its field operands: store
            // each field into the result's slot at its arm64FieldOffset.
            // (Multi-return tuples and by-value struct construction.)
            if (!insn.result) break;
            XTIRType *aggTy = insn.result.type;
            if (!aggTy || aggTy.kind != XTIRTypeKindAgg || !aggTy.layout) break;
            NSUInteger base = [self slotOffsetForValue:insn.result.valueId ctx:ctx];
            for (NSUInteger i = 0; i < insn.operands.count; i++) {
                XTIROperand *f = insn.operands[i];
                XTIRValue *fv = (f.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:f.valueId] : nil;
                XTIRType *fty = fv ? fv.type : f.type;
                BOOL isPtr = fty && fty.kind == XTIRTypeKindPtr;
                NSUInteger fw = fty ? [self arm64FieldWidth:fty] : 8;
                NSString *reg, *str;
                if (isPtr || fw >= 8)   { reg = @"x17"; str = @"str"; }
                else if (fw >= 4)       { reg = @"w17"; str = @"str"; }
                else if (fw == 2)       { reg = @"w17"; str = @"strh"; }
                else                    { reg = @"w17"; str = @"strb"; }
                [self materialiseOperand:f intoReg:reg ctx:ctx];
                NSUInteger foff = [self arm64FieldOffset:aggTy.layout index:i];
                [self emitSpAddr:base into:@"x16" ctx:ctx];
                // A field past #4095 in a >4KB aggregate overflows the narrow
                // store immediates (finding #13's family) — fold it into x16.
                if (foff > 4095) { [self emitAddImm:@"x16" base:@"x16" offset:foff ctx:ctx]; foff = 0; }
                [ctx.out appendFormat:@"    %@ %@, [x16, #%lu]\n",
                 str, reg, (unsigned long)foff];
            }
            break;
        }
        case XTIROpAggExtract: {
            // Read field #idx out of a source aggregate value's slot.
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *srcOp = insn.operands[0];
            XTIRValue *srcV = (srcOp.kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:srcOp.valueId] : nil;
            XTIRType *aggTy = srcV ? srcV.type : nil;
            if (!aggTy || aggTy.kind != XTIRTypeKindAgg || !aggTy.layout) break;
            NSUInteger idx = (NSUInteger)insn.operands[1].intValue;
            NSUInteger sbase = [self slotOffsetForValue:srcOp.valueId ctx:ctx];
            NSUInteger foff = [self arm64FieldOffset:aggTy.layout index:idx];
            XTIRType *rty = insn.result.type;
            BOOL isPtr = rty && rty.kind == XTIRTypeKindPtr;
            BOOL sgn = rty && XTIRTypeKindIsSigned(rty.kind);
            NSUInteger fw = rty ? [self arm64FieldWidth:rty] : 8;
            NSString *reg, *ld;
            if (isPtr || fw >= 8)   { reg = @"x17"; ld = @"ldr"; }
            else if (fw >= 4)       { reg = @"w17"; ld = @"ldr"; }
            else if (fw == 2)       { reg = @"w17"; ld = sgn ? @"ldrsh" : @"ldrh"; }
            else                    { reg = @"w17"; ld = sgn ? @"ldrsb" : @"ldrb"; }
            [self emitSpAddr:sbase into:@"x16" ctx:ctx];
            // A field past #4095 in a >4KB aggregate overflows the narrow
            // load immediates (finding #13's family) — fold it into x16.
            if (foff > 4095) { [self emitAddImm:@"x16" base:@"x16" offset:foff ctx:ctx]; foff = 0; }
            [ctx.out appendFormat:@"    %@ %@, [x16, #%lu]\n",
             ld, reg, (unsigned long)foff];
            [self storeReg:reg intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFieldAddr: {
            // Operands: [base:Ptr(Agg(L)), ImmI(field_index)]. Read
            // the field's byteOffset from the layout and emit
            // `add %r, %base, #<offset>`.
            if (insn.operands.count < 2 || !insn.result) break;
            NSString *base = [self operandReg:insn.operands[0] intoScratch:@"x16" ctx:ctx];
            // arm64-native offset: the shared layout's byteOffset is
            // 2-byte-pointer (Atari) based; arm64 uses 8-byte host pointers,
            // so recompute from arm64 field widths (shared helper).
            uint32_t byteOffset = [self arm64FieldByteOffsetForFieldAddr:insn ctx:ctx];
            NSString *dest = [self resultReg:insn.result.valueId scratch:@"x16" ctx:ctx];
            // Safe add: an ivar behind a 32KB array ivar overflows the 12-bit
            // immediate (finding #13).
            [self emitAddImm:dest base:base offset:byteOffset ctx:ctx];
            [self storeReg:dest intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpElementAddr: {
            // Operands: [base:Ptr(T), idx:I16/U16]. Scale idx by
            // sizeof(T) and add to base.
            if (insn.operands.count < 2 || !insn.result) break;
            uint32_t elemSize = [self arm64ElemSizeForElementAddr:insn ctx:ctx];
            // Constant index (e.g. the pointer-IV advance `p + step`, or `p - N`
            // whose negated index folds to a negative constant) → a single
            // immediate add/sub, when the byte offset magnitude fits imm12.
            int64_t kConst;
            if ([self constIndexForElementAddr:insn ctx:ctx value:&kConst] &&
                llabs(kConst) * (int64_t)elemSize <= 4095) {
                int64_t off = kConst * (int64_t)elemSize;
                NSString *base = [self operandReg:insn.operands[0] intoScratch:@"x16" ctx:ctx];
                NSString *dest = [self resultReg:insn.result.valueId scratch:@"x16" ctx:ctx];
                if (off >= 0)
                    [ctx.out appendFormat:@"    add %@, %@, #%lld\n", dest, base, (long long)off];
                else
                    [ctx.out appendFormat:@"    sub %@, %@, #%lld\n", dest, base, (long long)(-off)];
                [self storeReg:dest intoValue:insn.result.valueId ctx:ctx];
                break;
            }
            NSString *base = [self operandReg:insn.operands[0] intoScratch:@"x16" ctx:ctx];
            // The index is a 32-bit (16-bit-valued) subscript. Read it from its
            // home w-register when homed (else load into w17) and fold it into
            // the address with `uxtw` — `add Xd, Xn, Wm, uxtw #shift` both
            // zero-extends the index and scales it, so a homed index needs NO
            // separate `mov`/materialise (the hot-loop case: the index is the
            // induction variable, already in a register).
            // A SIGNED index (e.g. the negated offset from `p - N`) must be
            // SIGN-extended into the 64-bit address — `uxtw` would turn -2 into
            // +0xFFFFFFFE and walk off into a wild address (segfault). A 64-BIT
            // index needs neither: its home view IS an X register, and the
            // W-only `uxtw`/`sxtw` forms are invalid with it (blewit finding
            // #8) — the shifted-register `lsl` form takes the X index whole.
            XTIRValue *idxV = (insn.operands[1].kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:insn.operands[1].valueId] : nil;
            BOOL idx64 = idxV && (idxV.type.kind == XTIRTypeKindI64
                                  || idxV.type.kind == XTIRTypeKindU64
                                  || idxV.type.kind == XTIRTypeKindPtr);
            NSString *idx = [self operandReg:insn.operands[1]
                                 intoScratch:idx64 ? @"x17" : @"w17" ctx:ctx];
            NSString *dest = [self resultReg:insn.result.valueId scratch:@"x16" ctx:ctx];
            NSString *ext = idx64 ? @"lsl"
                          : (idxV && XTIRTypeKindIsSigned(idxV.type.kind)) ? @"sxtw" : @"uxtw";
            if (elemSize == 1) {
                if (idx64)
                    [ctx.out appendFormat:@"    add %@, %@, %@\n", dest, base, idx];
                else
                    [ctx.out appendFormat:@"    add %@, %@, %@, %@\n", dest, base, idx, ext];
            } else if ((elemSize & (elemSize - 1)) == 0) {
                // Power of two — extend and scale.
                unsigned shift = 0;
                for (unsigned v = elemSize; v > 1; v >>= 1) shift++;
                if (shift <= 4 || idx64) {
                    // Extend + scale fused in one add. The extended-register
                    // form's shift field is only valid for [0,4] (×1…×16);
                    // the X-index lsl form reaches 63, so it never splits.
                    [ctx.out appendFormat:@"    add %@, %@, %@, %@ #%u\n", dest, base, idx, ext, shift];
                } else {
                    // Stride ≥ 32 (shift ≥ 5): the fused extend-shift is out of
                    // range, so extend the index into x17 first, then use the
                    // shifted-register add whose lsl reaches 63.
                    [ctx.out appendFormat:@"    %@ x17, %@\n", ext, idx];
                    [ctx.out appendFormat:@"    add %@, %@, x17, lsl #%u\n", dest, base, shift];
                }
            } else {
                // Non-power-of-2 stride: needs a multiply, so widen the index to
                // x17 (sign- or zero-extended per the index type) and madd.
                if (idx64)
                    [ctx.out appendFormat:@"    mov x17, %@\n", idx];
                else
                    [ctx.out appendFormat:@"    %@ x17, %@\n", ext, idx];
                [ctx.out appendFormat:@"    mov x15, #%u\n", (unsigned)elemSize];
                [ctx.out appendFormat:@"    madd %@, x17, x15, %@\n", dest, base];
            }
            [self storeReg:dest intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        // ── IntToPtr / PtrToInt ───────────────────────────────────
        case XTIROpIntToPtr: {
            if (insn.operands.count < 1 || !insn.result) break;
            // The source slot was written by a 32-bit store (str w),
            // so its upper 4 bytes are stale. Force a 32-bit load
            // first so AArch64's "writes to w<n> zero-extend the
            // upper 32 bits of x<n>" semantics gives us a clean
            // pointer-width value, then store the full 8 bytes.
            XTIROperand *op = insn.operands[0];
            if (op.kind == XTIROperandKindUse) {
                [self loadValue:op.valueId intoReg:@"w16" ctx:ctx];
            } else {
                [self materialiseOperand:op intoReg:@"w16" ctx:ctx];
            }
            // An int→ptr is a 16-bit Atari-style address value: mask to
            // 16 bits so the Map/Set `(pointer)0`/`(pointer)1` sentinel
            // scheme and the `(u16)(pointer)N == N` round-trip stay honest.
            // There is no address remapping — arm64 is a flat host and
            // dereferences pointers directly. Native pointers (heap / AddrOf)
            // never flow through IntToPtr; they come from Call / AddrOf and
            // keep their full host width. A program that casts a literal
            // absolute Atari address (a hardware register, ZP) and derefs it
            // is 6502-only and is never compiled for this backend.
            [ctx.out appendString:@"    and w16, w16, #0xFFFF\n"];
            [self storeReg:@"x16" intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpPtrToInt: {
            if (insn.operands.count < 1 || !insn.result) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x16" ctx:ctx];
            // No sandbox to un-bias — the pointer value is used as-is. A
            // `(pointer)N` cast kept N (masked to 16 bits) at IntToPtr, so
            // `(u16)(pointer)N == N` round-trips and the Map/Set tag scheme
            // reads `(pointer)0` as 0 (empty) / `(pointer)1` as 1 (tombstone)
            // directly from the canonicalised low bits.
            NSString *destReg = [self regName:16 forType:insn.result.type];
            // Canonicalise to the result width: `(u16)ptr` keeps only the
            // low 16 bits, etc. Without this the result is the full low
            // 32 bits — usually harmless because a call/param boundary
            // re-canonicalises, but when the value is consumed directly
            // (e.g. an inlined comparison `(u16)&p->y == base+2`, where the
            // RHS is uxth'd but the LHS was not) the high bits make an
            // equal pair miscompare.
            [self canonicaliseReg:destReg toType:insn.result.type ctx:ctx];
            [self storeReg:destReg intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        // ── ARC ops (inline refcount sequences) ───────────────────
        //
        // The class instance layout puts the vtable pointer at slot
        // 0 and ivars after; the refcount byte sits one byte before
        // the object pointer (legacy convention — task #18 leaves
        // the explicit allocation to the runtime-support task).
        // Sequence guards against saturating wraparound at 255.
        case XTIROpVTblLoad: {
            // Operands: [receiver, ImmI(slot), memInput] -> fn pointer.
            // Same address computation as VTblDispatch (vtable ptr at
            // [recv, #0]; method at vtbl[slot * 8]) but WITHOUT the call —
            // this is the code word of `&obj.method`.
            //
            // A null receiver must yield 0, not fault: `&nullDelegate.m` has
            // to be falsy rather than a crash, so one `if (h)` covers both
            // "no delegate" and "delegate doesn't implement it". An empty
            // slot already reads back as 0 (the vtable emits `.quad 0`),
            // which is what makes an unimplemented `optional` method falsy.
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *slotOp = insn.operands[1];
            if (slotOp.kind != XTIROperandKindImmI) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x16" ctx:ctx];
            NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$"
                                                                   withString:@"_"];
            NSUInteger lbl = ctx.labelCounter++;
            // x17 = 0, and stays 0 if recv is null.
            [ctx.out appendString:@"    mov x17, #0\n"];
            [ctx.out appendFormat:@"    cbz x16, .L%@_vtblload_done_%lu\n",
                                  fnl, (unsigned long)lbl];
            [ctx.out appendString:@"    ldr x17, [x16]\n"];
            [ctx.out appendFormat:@"    ldr x17, [x17, #%lld]\n",
                                  (long long)(slotOp.intValue * 8)];
            [ctx.out appendFormat:@".L%@_vtblload_done_%lu:\n",
                                  fnl, (unsigned long)lbl];
            [[self class] storeReg:@"x17" intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpProtoLoad: {
            // Operands: [receiver, ImmI(protoId), ImmI(index), memInput] -> fn
            // pointer. `&p.method` through a protocol: the ProtoDispatch walk
            // without the call. A null receiver, a class with no itable and an
            // unimplemented `optional` all give 0, which is what the null test
            // on the result relies on.
            if (insn.operands.count < 3 || !insn.result) break;
            XTIROperand *pidOp = insn.operands[1];
            XTIROperand *idxOp = insn.operands[2];
            if (pidOp.kind != XTIROperandKindImmI || idxOp.kind != XTIROperandKindImmI) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x16" ctx:ctx];
            NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$"
                                                                   withString:@"_"];
            NSUInteger hit = ctx.labelCounter++;
            NSUInteger done = ctx.labelCounter++;
            NSString *doneL = [NSString stringWithFormat:@".L%@_itab_done_%lu", fnl, (unsigned long)done];
            [ctx.out appendString:@"    mov x17, #0\n"];
            [ctx.out appendFormat:@"    cbz x16, %@\n", doneL];
            [ctx.out appendString:@"    ldr x16, [x16]\n"];
            [ctx.out appendString:@"    ldr x16, [x16, #8]\n"];
            [ctx.out appendFormat:@"    cbz x16, %@\n", doneL];
            [self emitItableWalkFor:(uint32_t)pidOp.intValue
                                hit:[NSString stringWithFormat:@".L%@_itab_hit_%lu", fnl, (unsigned long)hit]
                               miss:doneL
                                ctx:ctx];
            [ctx.out appendFormat:@".L%@_itab_hit_%lu:\n", fnl, (unsigned long)hit];
            [ctx.out appendString:@"    ldr x16, [x16, #8]\n"];
            [ctx.out appendFormat:@"    ldr x17, [x16, #%lld]\n", (long long)(idxOp.intValue * 8)];
            [ctx.out appendFormat:@"%@:\n", doneL];
            [[self class] storeReg:@"x17" intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpRetain: {
            // Operands: [pointer, memInput].
            if (insn.operands.count < 2) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x16" ctx:ctx];
            // Per-function label prefix: ctx.labelCounter resets per
            // function, so a bare `.Lretain_done_N` collides across
            // functions (Mach-O `.L` labels are file-scoped). Qualify
            // with the function name, as the block labels do.
            NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$" withString:@"_"];
            NSUInteger lbl = ctx.labelCounter++;
            [ctx.out appendFormat:@"    cbz x16, .L%@_retain_done_%lu\n", fnl, (unsigned long)lbl];
            // Skip small pointer values (< 64 KB): `(pointer)0`/`(pointer)1`
            // Map/Set sentinels and any non-heap address are not refcounted
            // objects, so touching `[ptr-1]` would fault / corrupt unrelated
            // memory. A real heap object (malloc/`_xtc_new`) is far above
            // 64 KB on the host, so this never skips a live object.
            [ctx.out appendString:@"    cmp x16, #0x10000\n"];
            [ctx.out appendFormat:@"    b.lo .L%@_retain_done_%lu\n", fnl, (unsigned long)lbl];
            // A refcount of ZERO means the object is being DESTROYED: the release
            // that took it to 0 is running dealloc right now. Retaining it here
            // would let the matching release take it back to 0 and dispatch dealloc
            // AGAIN, forever — which is what ANY strong binding of `self` inside a
            // dealloc used to cause (bug 038). A live object always holds at least
            // one reference, so 0 can only mean "already dying", and release has
            // always had the mirror-image guard. This makes the pair symmetric.
            [ctx.out appendString:@"    ldur w17, [x16, #-4]\n"];
            [ctx.out appendFormat:@"    cbz w17, .L%@_retain_done_%lu\n", fnl, (unsigned long)lbl];
            // 32-bit refcount at obj-4, matching the allocator's 40-byte header
            // in src/xtc/support-src/rt.c. It was 16-bit at obj-2, and a u16
            // WRAPS at 65,536 — bugs 025 and 079 were both an object freed
            // while still live because its count went round. That ceiling is
            // reachable: one String retained per lexer token hit it in an
            // ordinary compile. (Before that it was 8-bit and saturated at
            // 255, so an object retained more than 255 times could never be
            // freed at all — heap_retain_wide.)
            if (sArm64ThreadSafeARC) {
                // Threading: the load/add/store below is a data race the moment
                // two threads hold the same object — one increment is lost and
                // the object is freed while still referenced. LDADDLH does the
                // whole read-modify-write atomically; the increment itself needs
                // no ordering (nothing is published BY a retain), but the
                // release bit pairs with the acquire on the release side so a
                // dealloc cannot be reordered ahead of a retain it must observe.
                // The old value is discarded into wzr.
                [ctx.out appendString:@"    sub x16, x16, #4\n"];
                if (sArm64LseAtomics) {
                    [ctx.out appendString:@"    mov w17, #1\n"];
                    [ctx.out appendString:@"    ldaddl w17, wzr, [x16]\n"];
                } else {
                    // No LSE (Android's armv8-a baseline): the same atomic
                    // increment as an exclusive load/store loop. x15/x16/x17
                    // are all reserved scratch, so this needs no spill.
                    [ctx.out appendFormat:@".L%@_rcas_%lu:\n", fnl, (unsigned long)lbl];
                    [ctx.out appendString:@"    ldaxr w17, [x16]\n"];
                    [ctx.out appendString:@"    add w17, w17, #1\n"];
                    [ctx.out appendString:@"    stlxr w15, w17, [x16]\n"];
                    [ctx.out appendFormat:@"    cbnz w15, .L%@_rcas_%lu\n", fnl, (unsigned long)lbl];
                }
            } else {
                [ctx.out appendString:@"    add w17, w17, #1\n"];
                [ctx.out appendString:@"    stur w17, [x16, #-4]\n"];
            }
            [ctx.out appendFormat:@".L%@_retain_done_%lu:\n", fnl, (unsigned long)lbl];
            break;
        }
        case XTIROpRelease:
        case XTIROpAutorelease: {
            // Operands: [pointer, memInput]. Autorelease degrades to
            // immediate Release per IR-SPEC §9.4 — the distinct
            // opcode lets a proper pool land later without retouching
            // every emit site.
            if (insn.operands.count < 2) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$" withString:@"_"];
            NSUInteger lbl = ctx.labelCounter++;
            [ctx.out appendFormat:@"    cbz x0, .L%@_release_done_%lu\n", fnl, (unsigned long)lbl];
            // Skip small pointer values (< 64 KB) (see Retain): sentinels
            // and non-heap addresses are not refcounted heap objects.
            [ctx.out appendString:@"    cmp x0, #0x10000\n"];
            [ctx.out appendFormat:@"    b.lo .L%@_release_done_%lu\n", fnl, (unsigned long)lbl];
            // 32-bit refcount at obj-4 (see Retain). subs sets the flags;
            // free when it reaches 0.
            if (sArm64ThreadSafeARC) {
                // Threading: atomic decrement, and the dealloc decision is made
                // from the value THIS thread took the count down from, not from
                // a re-read (two threads re-reading would both see 0 and both
                // free). LDADDALH returns the OLD halfword, so "I was the last
                // reference" is old == 1.
                //
                // The acquire half is what makes the dealloc safe: it orders
                // every other thread's writes to the object — made before ITS
                // release — ahead of the destructor's reads. The release half
                // publishes this thread's own writes to whoever frees it.
                [ctx.out appendString:@"    sub x16, x0, #4\n"];
                if (sArm64LseAtomics) {
                    [ctx.out appendString:@"    mov w17, #0xffff\n"];   // -1, mod 2^16
                    [ctx.out appendString:@"    ldaddalh w17, w17, [x16]\n"];
                    [ctx.out appendString:@"    cmp w17, #1\n"];
                    [ctx.out appendFormat:@"    b.ne .L%@_release_done_%lu\n", fnl, (unsigned long)lbl];
                } else {
                    // No LSE: an exclusive load/store loop. It keeps the NEW
                    // count rather than the old one and tests it against zero —
                    // "I was the last reference" is old == 1, which is new == 0,
                    // and that needs one register fewer than holding both. The
                    // wrap on an already-zero count is the same 0xffff the
                    // non-atomic path produces, so the two agree exactly.
                    [ctx.out appendFormat:@".L%@_rcas_%lu:\n", fnl, (unsigned long)lbl];
                    [ctx.out appendString:@"    ldaxr w17, [x16]\n"];
                    [ctx.out appendString:@"    sub w17, w17, #1\n"];
                    [ctx.out appendString:@"    stlxr w15, w17, [x16]\n"];
                    [ctx.out appendFormat:@"    cbnz w15, .L%@_rcas_%lu\n", fnl, (unsigned long)lbl];
                    [ctx.out appendFormat:@"    cbnz w17, .L%@_release_done_%lu\n", fnl, (unsigned long)lbl];
                }
            } else {
            [ctx.out appendString:@"    ldur w17, [x0, #-4]\n"];
            [ctx.out appendString:@"    subs w17, w17, #1\n"];
            [ctx.out appendString:@"    stur w17, [x0, #-4]\n"];
            [ctx.out appendFormat:@"    b.ne .L%@_release_done_%lu\n", fnl, (unsigned long)lbl];
            }
            // Refcount hit zero — dispatch to dealloc helper. The
            // runtime stub (or test harness) provides the body. The
            // double-underscore reflects Mach-O's C-symbol prefix
            // convention: the C function `_xtc_dealloc(void *)`
            // lands as the Mach-O symbol `__xtc_dealloc`.
            [ctx.out appendString:@"    bl __xtc_dealloc\n"];
            [ctx.out appendFormat:@".L%@_release_done_%lu:\n", fnl, (unsigned long)lbl];
            break;
        }

        // ── Weak references — runtime calls ───────────────────────
        case XTIROpWeakRegister: {
            // Operands: [slot, obj, memInput].
            if (insn.operands.count < 3) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            [self materialiseOperand:insn.operands[1] intoReg:@"x1" ctx:ctx];
            [ctx.out appendString:@"    bl __xtc_weak_register\n"];
            break;
        }
        case XTIROpWeakUnregister: {
            // Operands: [slot, memInput].
            if (insn.operands.count < 2) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            [ctx.out appendString:@"    bl __xtc_weak_unregister\n"];
            break;
        }
        case XTIROpWeakLoad: {
            // Operands: [slot, memInput]. Result: pointer.
            if (insn.operands.count < 2 || !insn.result) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x0" ctx:ctx];
            [ctx.out appendString:@"    bl __xtc_weak_load\n"];
            [self storeReg:@"x0" intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        // ── VTable dispatch / indirect call ───────────────────────
        case XTIROpVTblDispatch:
        case XTIROpProtoDispatch: {
            // Operands: [receiver, ImmI(slot), arg0, ..., memInput], or for
            // ProtoDispatch [receiver, ImmI(protoId), ImmI(index), arg0, ...,
            // memInput]. Receiver goes in x0 (the implicit self). Other args
            // follow in x1..x7. Vtable ptr lives at [recv, #0]; the
            // function pointer at vtbl[slot * 8], or for a protocol call in
            // the protocol's table found through the itable.
            BOOL viaItable = (insn.opcode == XTIROpProtoDispatch);
            NSUInteger first = viaItable ? 3 : 2;
            if (insn.operands.count < (viaItable ? 3 : 2)) break;
            XTIROperand *recv = insn.operands[0];
            XTIROperand *slotOp = insn.operands[1];
            if (slotOp.kind != XTIROperandKindImmI) break;
            if (viaItable && insn.operands[2].kind != XTIROperandKindImmI) break;
            [self materialiseOperand:recv intoReg:@"x0" ctx:ctx];
            NSUInteger argCount = insn.operands.count >= first + 1 ? insn.operands.count - (first + 1) : 0;
            // Receiver consumed x0, so the GP counter starts at 1; the
            // FP bank (v0..v7) is independent and starts at 0.
            NSArray *vaTypes = [self arm64ArgTypesForInsn:insn from:first count:argCount ctx:ctx];
            NSArray<NSNumber *> *vStk = [self arm64ArgStackOffsets:vaTypes startGP:1 startFP:0 totalBytes:NULL];
            int gpIdx = 1, fpIdx = 0;
            for (NSUInteger i = 0; i < argCount; i++) {
                XTIROperand *a = insn.operands[i + first];
                XTIRValue *av = (a.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:a.valueId] : nil;
                if (av && av.type.kind == XTIRTypeKindAgg) {
                    // By-value aggregate — a 2-word bound-method `^` (recv, code)
                    // or a struct — in consecutive GP registers, or an HFA in
                    // consecutive v-registers. (A `^` is a pointer pair, never an
                    // HFA, so it stays GP.) Stack overflow of an aggregate stays
                    // unsupported.
                    if (![self marshalAggArg:a.valueId type:av.type
                                        gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx]) continue;
                } else {
                    [self marshalArgOperand:a value:av stackOffset:vStk[i].integerValue
                                      gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx];
                }
            }
            int64_t slotIdx = slotOp.intValue;
            // >16-byte struct return: pass the result slot in x8 before the call.
            BOOL vtSret = [self emitSretSetupIfNeeded:insn ctx:ctx];
            if (viaItable) {
                // A receiver whose class does not answer to the protocol
                // calls 0, as an empty vtable slot does.
                NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$"
                                                                       withString:@"_"];
                NSUInteger hit = ctx.labelCounter++;
                NSUInteger miss = ctx.labelCounter++;
                NSUInteger call = ctx.labelCounter++;
                [ctx.out appendString:@"    ldr x16, [x0]\n"];
                [ctx.out appendString:@"    ldr x16, [x16, #8]\n"];
                [ctx.out appendFormat:@"    cbz x16, .L%@_itab_call_%lu\n", fnl, (unsigned long)call];
                [self emitItableWalkFor:(uint32_t)slotOp.intValue
                                    hit:[NSString stringWithFormat:@".L%@_itab_hit_%lu", fnl, (unsigned long)hit]
                                   miss:[NSString stringWithFormat:@".L%@_itab_miss_%lu", fnl, (unsigned long)miss]
                                    ctx:ctx];
                [ctx.out appendFormat:@".L%@_itab_miss_%lu:\n", fnl, (unsigned long)miss];
                [ctx.out appendString:@"    mov x16, #0\n"];
                [ctx.out appendFormat:@"    b .L%@_itab_call_%lu\n", fnl, (unsigned long)call];
                [ctx.out appendFormat:@".L%@_itab_hit_%lu:\n", fnl, (unsigned long)hit];
                [ctx.out appendString:@"    ldr x16, [x16, #8]\n"];
                [ctx.out appendFormat:@"    ldr x16, [x16, #%lld]\n", (long long)(insn.operands[2].intValue * 8)];
                [ctx.out appendFormat:@".L%@_itab_call_%lu:\n", fnl, (unsigned long)call];
            } else {
                [ctx.out appendString:@"    ldr x16, [x0]\n"];
                [ctx.out appendFormat:@"    ldr x16, [x16, #%lld]\n", slotIdx * 8];
            }
            [ctx.out appendString:@"    blr x16\n"];
            if (insn.result) {
                if (insn.result.type.kind == XTIRTypeKindAgg) {
                    // HFA in v0.., ≤16 B in x0:x1, >16 B non-float via the x8 sret.
                    [self captureAggResult:insn sretUsed:vtSret ctx:ctx];
                } else if (XTIRTypeKindIsFloating(insn.result.type.kind)) {
                    [self storeReg:[self fregName:0 forType:insn.result.type]
                          intoValue:insn.result.valueId ctx:ctx];
                } else {
                    NSString *destReg = [self regName:0 forType:insn.result.type];
                    if (!([self irTypeNeedsXReg:insn.result.type])) {
                        [self canonicaliseReg:destReg toType:insn.result.type ctx:ctx];
                    }
                    [self storeReg:destReg intoValue:insn.result.valueId ctx:ctx];
                }
            }
            break;
        }
        case XTIROpCallIndirect: {
            // Operands: [fnPtr, arg0, ..., memInput].
            if (insn.operands.count < 2) break;
            XTIROperand *fp = insn.operands[0];
            [self materialiseOperand:fp intoReg:@"x16" ctx:ctx];
            NSUInteger argCount = insn.operands.count >= 2 ? insn.operands.count - 2 : 0;
            // AAPCS marshalling, mirroring the direct-Call path: GP args in x0..x7,
            // float/double in the independent v0..v7 bank, a by-value aggregate in
            // consecutive GP registers, and an HFA (NSPoint/NSRect passed to a
            // setter) in consecutive v-registers. The fn pointer sits in x16, which
            // no arg touches. (The old loop put every arg in x{i}, so a float arg
            // or an NSRect landed in GP — wrong for a cast msgSend.)
            NSArray *iaTypes = [self arm64ArgTypesForInsn:insn from:1 count:argCount ctx:ctx];
            NSArray<NSNumber *> *iStk = [self arm64ArgStackOffsets:iaTypes startGP:0 startFP:0 totalBytes:NULL];
            int gpIdx = 0, fpIdx = 0;
            for (NSUInteger i = 0; i < argCount; i++) {
                XTIROperand *a = insn.operands[i + 1];
                XTIRValue *av = (a.kind == XTIROperandKindUse)
                    ? [ctx.fn valueForId:a.valueId] : nil;
                if (av && av.type.kind == XTIRTypeKindAgg) {
                    if (![self marshalAggArg:a.valueId type:av.type
                                        gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx]) continue;
                } else {
                    [self marshalArgOperand:a value:av stackOffset:iStk[i].integerValue
                                      gpIdx:&gpIdx fpIdx:&fpIdx ctx:ctx];
                }
            }
            // >16-byte struct return: pass the result slot in x8 before the call.
            BOOL indSret = [self emitSretSetupIfNeeded:insn ctx:ctx];
            [ctx.out appendString:@"    blr x16\n"];
            if (insn.result) {
                if (insn.result.type.kind == XTIRTypeKindAgg) {
                    // HFA in v0.., ≤16 B in x0:x1, >16 B non-float via the x8 sret.
                    [self captureAggResult:insn sretUsed:indSret ctx:ctx];
                } else {
                    NSString *destReg = [self regName:0 forType:insn.result.type];
                    if (!([self irTypeNeedsXReg:insn.result.type])) {
                        [self canonicaliseReg:destReg toType:insn.result.type ctx:ctx];
                    }
                    [self storeReg:destReg intoValue:insn.result.valueId ctx:ctx];
                }
            }
            break;
        }

        // ── Class downcast ────────────────────────────────────────
        //
        // Lowering encodes class_id as the source layout's index in
        // the module's layoutTable. We don't have a "class id" header
        // byte yet (a follow-up task adds one); for now read the
        // vtable pointer and compare against the expected class's
        // vtable address. Matching = same class; failable returns
        // null on mismatch, non-failable traps.
        case XTIROpClassDowncast:
        case XTIROpClassDowncastFailable: {
            if (insn.operands.count < 2 || !insn.result) break;
            [self materialiseOperand:insn.operands[0] intoReg:@"x16" ctx:ctx];
            XTIROperand *idOp = insn.operands[1];
            if (idOp.kind != XTIROperandKindImmI) break;
            NSUInteger lbl = ctx.labelCounter++;
            // For now the downcast is a pass-through: the pointer
            // type carries the target layout, so the verifier and
            // lowering agree on the shape. A proper runtime check
            // lands once the class-header allocator pins the
            // class-id byte.
            (void)idOp;
            if (insn.opcode == XTIROpClassDowncastFailable) {
                NSString *fnl = [ctx.fn.name stringByReplacingOccurrencesOfString:@"$" withString:@"_"];
                [ctx.out appendFormat:@"    cbz x16, .L%@_downcast_done_%lu\n",
                 fnl, (unsigned long)lbl];
                [ctx.out appendFormat:@".L%@_downcast_done_%lu:\n", fnl, (unsigned long)lbl];
            }
            [self storeReg:@"x16" intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        // ── Inline asm — emit body verbatim ───────────────────────
        // The asm body is whatever the user wrote; on arm64 that means
        // it has to be valid arm64 assembly (clang's integrated
        // assembler is downstream and rejects anything else). Fixtures
        // whose asm is 6502-specific tag `target=xt6502` via xtc-flags
        // so arm64 never sees them.
        //
        // Identifier references planted by lowerAsmBlock as
        // `{{XTLOCAL:<vid>}}` resolve to the local's SP-relative slot
        // (`sp, #N`, without enclosing brackets — the user writes
        // `str w0, [result]` and it becomes `str w0, [sp, #N]`,
        // matching the natural arm64 memory-operand syntax). The xt6502
        // path does the equivalent substitution to a ZP byte address;
        // both backends just plug in wherever the pinned local lives.
        case XTIROpAsm: {
            XTIRConstantId cid = NSNotFound;
            for (XTIROperand *op in insn.operands) {
                if (op.kind == XTIROperandKindConstAgg) {
                    cid = op.constantId; break;
                }
            }
            if (cid == NSNotFound) break;
            XTIRConstant *c = [ctx.module constantForId:cid];
            if (!c.stringBytes) break;
            NSString *text = [[NSString alloc] initWithData:c.stringBytes
                                                    encoding:NSUTF8StringEncoding];
            if (!text) break;
            if ([text containsString:@"{{XTLOCAL:"]) {
                NSRegularExpression *re =
                    [NSRegularExpression regularExpressionWithPattern:@"\\{\\{XTLOCAL:(\\d+)\\}\\}"
                                                              options:0 error:NULL];
                NSMutableString *resolved = [text mutableCopy];
                NSArray<NSTextCheckingResult *> *ms =
                    [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
                for (NSTextCheckingResult *m in [ms reverseObjectEnumerator]) {
                    XTIRValueId vid = (XTIRValueId)[[text substringWithRange:[m rangeAtIndex:1]] integerValue];
                    NSUInteger off = [self slotOffsetForValue:vid ctx:ctx];
                    NSString *repl = [NSString stringWithFormat:@"sp, #%lu",
                                       (unsigned long)off];
                    [resolved replaceCharactersInRange:m.range withString:repl];
                }
                text = resolved;
            }
            [ctx.out appendString:@"    // inline asm\n"];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                if (line.length == 0) continue;
                [ctx.out appendFormat:@"    %@\n", line];
            }
            break;
        }

        // ── Banking — no-op on arm64 (single flat address space) ──
        case XTIROpBankSelectFor:
        case XTIROpBankSave:
        case XTIROpBankRestore: {
            // The IR carries banking intent so the 6502 target can
            // act on it; arm64 has nothing to do.
            [ctx.out appendString:@"    nop\n"];
            break;
        }

        // ── Native floating-point ─────────────────────────────────
        // arm64 uses IEEE single (s-reg, F32) / double (d-reg, F64)
        // and native instructions. Operands are SSA Use values held
        // in 8-byte stack slots; ldr/str with an s/d register view
        // copies the right width.
        case XTIROpFAdd: case XTIROpFSub:
        case XTIROpFMul: case XTIROpFDiv: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSString *s0 = [self fregName:0 forType:insn.result.type];
            NSString *s1 = [self fregName:1 forType:insn.result.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s0 ctx:ctx];
            NSString *b = [self operandReg:insn.operands[1] intoScratch:s1 ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:s0 ctx:ctx];
            NSString *mnem;
            switch (insn.opcode) {
                case XTIROpFAdd: mnem = @"fadd"; break;
                case XTIROpFSub: mnem = @"fsub"; break;
                case XTIROpFMul: mnem = @"fmul"; break;
                default:         mnem = @"fdiv"; break;
            }
            [ctx.out appendFormat:@"    %@ %@, %@, %@\n", mnem, d, a, b];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFNeg: {
            if (insn.operands.count < 1 || !insn.result) break;
            NSString *s0 = [self fregName:0 forType:insn.result.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s0 ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:s0 ctx:ctx];
            [ctx.out appendFormat:@"    fneg %@, %@\n", d, a];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFSqrt: {
            // Hardware square root — reads/writes the fp register directly, no
            // ABI marshalling. The SqrtIntrinsic IR pass canonicalised the libm
            // sqrt[f] call to this op; the backend just selects the instruction.
            if (insn.operands.count < 1 || !insn.result) break;
            NSString *s0 = [self fregName:0 forType:insn.result.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s0 ctx:ctx];
            NSString *d = [self resultReg:insn.result.valueId scratch:s0 ctx:ctx];
            [ctx.out appendFormat:@"    fsqrt %@, %@\n", d, a];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFCmp: {
            if (insn.operands.count < 2 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSString *s0 = [self fregName:0 forType:av.type];
            NSString *s1 = [self fregName:1 forType:av.type];
            NSString *a = [self operandReg:insn.operands[0] intoScratch:s0 ctx:ctx];
            NSString *b = [self operandReg:insn.operands[1] intoScratch:s1 ctx:ctx];
            [ctx.out appendFormat:@"    fcmp %@, %@\n", a, b];
            NSString *cond;
            switch (insn.predicate) {
                case XTIRFCmpOEQ: cond = @"eq"; break;
                case XTIRFCmpONE: cond = @"ne"; break;
                case XTIRFCmpOLT: cond = @"mi"; break;
                case XTIRFCmpOGT: cond = @"gt"; break;
                case XTIRFCmpOLE: cond = @"ls"; break;
                case XTIRFCmpOGE: cond = @"ge"; break;
                default:          cond = @"eq"; break;
            }
            NSString *d = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    cset %@, %@\n", d, cond];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpSIToFp: case XTIROpUIToFp: {
            if (insn.operands.count < 1 || !insn.result) break;
            NSString *a = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
            NSString *dst = [self resultReg:insn.result.valueId
                                    scratch:[self fregName:0 forType:insn.result.type]
                                        ctx:ctx];
            [ctx.out appendFormat:@"    %@ %@, %@\n",
             (insn.opcode == XTIROpSIToFp) ? @"scvtf" : @"ucvtf", dst, a];
            [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFpToSI: case XTIROpFpToUI: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSString *src = [self operandReg:insn.operands[0]
                                 intoScratch:[self fregName:0 forType:av.type] ctx:ctx];
            BOOL toSigned = (insn.opcode == XTIROpFpToSI);
            // Convert to 64-bit, then if the truncated value doesn't fit the
            // destination integer width, produce 0. LANGUAGE-SPEC §3.1 says an
            // out-of-range float→int saturates to 0 (and xt6502 does); ARMv8
            // fcvtz* alone would saturate to INT_MAX/MIN instead. Re-extend the
            // low W bits (sign/zero per target) and compare: equal ⇒ it fit.
            [ctx.out appendFormat:@"    %@ x16, %@\n",
             toSigned ? @"fcvtzs" : @"fcvtzu", src];
            NSUInteger w = insn.result.type.byteWidth;
            // The re-extend-and-compare fit check only makes sense for a
            // destination NARROWER than the 64-bit fcvtz result. For a 64-bit
            // destination the fcvtz value IS the result — there is nothing wider
            // to range-check against, and the old `else` branch re-extended the
            // low 32 BITS (sxtw / mov w17,w16), so every value above 2^32 failed
            // the compare and was csel'd to 0: `(i64)3000000000.5` and
            // `(u64)12345678900.5` both came back 0 (bug 173). ARMv8 fcvtz
            // saturates a >2^63 double to INT64_MIN/MAX; the sub-64-bit
            // saturate-to-0 rule does not reach the widest integer.
            if (w < 8) {
                NSString *ext;
                if (toSigned) ext = (w==1) ? @"sxtb x17, w16"
                                   : (w==2) ? @"sxth x17, w16" : @"sxtw x17, w16";
                else          ext = (w==1) ? @"uxtb w17, w16"
                                   : (w==2) ? @"uxth w17, w16" : @"mov w17, w16";
                [ctx.out appendFormat:@"    %@\n", ext];
                [ctx.out appendString:@"    cmp x16, x17\n"];
                [ctx.out appendString:@"    csel x16, x16, xzr, eq\n"];
            }
            // A 64-bit result must be STORED from x16 — passing w16 for it wrote
            // only the low 32 bits, which is the other half of bug 173.
            NSString *outReg = (w >= 8) ? @"x16" : @"w16";
            [self canonicaliseReg:outReg toType:insn.result.type ctx:ctx];
            [self storeReg:outReg intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpFpExt: case XTIROpFpTrunc: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSString *src = [self operandReg:insn.operands[0]
                                 intoScratch:[self fregName:0 forType:av.type] ctx:ctx];
            NSString *dst = [self resultReg:insn.result.valueId
                                    scratch:[self fregName:1 forType:insn.result.type]
                                        ctx:ctx];
            [ctx.out appendFormat:@"    fcvt %@, %@\n", dst, src];
            [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        // ── SIMD (arm64 vectorizer) ───────────────────────────────
        case XTIROpVLoad: {       // operands: [ptr, mem]
            if (insn.operands.count < 1 || !insn.result) break;
            // Fold a constant-index ElementAddr base into `[base, #imm]` (pointer-IV
            // unrolled copy); else address through the materialised pointer.
            NSString *addr = ctx.foldInfo[@(insn.operands[0].valueId)]
                ? [self foldedAddrOperandFor:insn ctx:ctx]
                : [NSString stringWithFormat:@"[%@]", [self operandReg:insn.operands[0] intoScratch:@"x16" ctx:ctx]];
            NSUInteger n = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    ldr q%lu, %@\n", (unsigned long)n, addr];
            break;
        }
        case XTIROpVStore: {      // operands: [ptr, vec, mem]
            if (insn.operands.count < 2 || insn.operands[1].kind != XTIROperandKindUse) break;
            NSString *addr = ctx.foldInfo[@(insn.operands[0].valueId)]
                ? [self foldedAddrOperandFor:insn ctx:ctx]
                : [NSString stringWithFormat:@"[%@]", [self operandReg:insn.operands[0] intoScratch:@"x16" ctx:ctx]];
            NSUInteger v = [self vecIndexForValue:insn.operands[1].valueId ctx:ctx];
            [ctx.out appendFormat:@"    str q%lu, %@\n", (unsigned long)v, addr];
            break;
        }
        case XTIROpVSplat: {      // operands: [scalar] — broadcast to all lanes
            if (insn.operands.count < 1 || !insn.result) break;
            NSString *arr = [self neonArrFor:insn.result.type.pointeeType];
            NSString *s = [self operandReg:insn.operands[0] intoScratch:@"w16" ctx:ctx];
            NSUInteger n = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    dup v%lu.%@, %@\n", (unsigned long)n, arr, s];
            break;
        }
        case XTIROpVAdd: case XTIROpVSub: case XTIROpVMul:
        case XTIROpVAnd: case XTIROpVOr:  case XTIROpVXor: {
            if (insn.operands.count < 2 || !insn.result ||
                insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[1].kind != XTIROperandKindUse) break;
            BOOL bitwise = (insn.opcode == XTIROpVAnd || insn.opcode == XTIROpVOr ||
                            insn.opcode == XTIROpVXor);
            XTIRType *lane = insn.result.type.pointeeType;
            BOOL flt = lane && XTIRTypeKindIsFloating(lane.kind);
            NSString *arr = bitwise ? @"16b" : [self neonArrFor:lane];
            NSString *mnem = (insn.opcode == XTIROpVAdd) ? (flt ? @"fadd" : @"add") :
                             (insn.opcode == XTIROpVSub) ? (flt ? @"fsub" : @"sub") :
                             (insn.opcode == XTIROpVMul) ? (flt ? @"fmul" : @"mul") :
                             (insn.opcode == XTIROpVAnd) ? @"and" :
                             (insn.opcode == XTIROpVOr)  ? @"orr" : @"eor";
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger b = [self vecIndexForValue:insn.operands[1].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    %@ v%lu.%@, v%lu.%@, v%lu.%@\n",
             mnem, (unsigned long)d, arr, (unsigned long)a, arr, (unsigned long)b, arr];
            break;
        }
        case XTIROpVMax: case XTIROpVMin: {   // lane-wise max/min (u/s from lane)
            if (insn.operands.count < 2 || !insn.result ||
                insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[1].kind != XTIROperandKindUse) break;
            XTIRType *lane = insn.result.type.pointeeType;
            BOOL sgn = lane && XTIRTypeKindIsSigned(lane.kind);
            NSString *mnem = (insn.opcode == XTIROpVMax)
                ? (sgn ? @"smax" : @"umax") : (sgn ? @"smin" : @"umin");
            NSString *arr = [self neonArrFor:lane];
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger b = [self vecIndexForValue:insn.operands[1].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    %@ v%lu.%@, v%lu.%@, v%lu.%@\n",
             mnem, (unsigned long)d, arr, (unsigned long)a, arr, (unsigned long)b, arr];
            break;
        }
        case XTIROpVAddLP: {      // unsigned add-long-pairwise (widen ×2)
            if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse ||
                !insn.result) break;
            NSString *inArr = [self neonArrFor:[ctx.fn valueForId:insn.operands[0].valueId].type.pointeeType];
            NSString *outArr = [self neonArrFor:insn.result.type.pointeeType];
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    uaddlp v%lu.%@, v%lu.%@\n",
             (unsigned long)d, outArr, (unsigned long)a, inArr];
            break;
        }
        case XTIROpVMulHi: {      // HIGH half of the lane product
            // No single NEON instruction gives the high half of a 32x32
            // product. umull does the low two lanes into 2xu64 and umull2 the
            // high two, then uzp2 takes the ODD 32-bit word of each 64-bit
            // result — which is the high half of each product. v16/v17 are the
            // FP scratch pair, outside the v18-v31 vector pool, and both are
            // written and read within this one expansion; a vectorised body
            // contains no calls and no FP scalars, so nothing else holds them.
            // uzp2 reads only the scratch, so a destination that aliases either
            // source is safe.
            if (insn.operands.count < 2 || !insn.result ||
                insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[1].kind != XTIROperandKindUse) break;
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger b = [self vecIndexForValue:insn.operands[1].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            [ctx.out appendFormat:@"    umull v16.2d, v%lu.2s, v%lu.2s\n",
             (unsigned long)a, (unsigned long)b];
            [ctx.out appendFormat:@"    umull2 v17.2d, v%lu.4s, v%lu.4s\n",
             (unsigned long)a, (unsigned long)b];
            [ctx.out appendFormat:@"    uzp2 v%lu.4s, v16.4s, v17.4s\n", (unsigned long)d];
            break;
        }
        case XTIROpVLShr: {       // lane-wise logical shift right by a constant
            if (insn.operands.count < 2 || !insn.result ||
                insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[1].kind != XTIROperandKindImmI) break;
            NSString *arr = [self neonArrFor:insn.result.type.pointeeType];
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            int64_t sh = insn.operands[1].intValue;
            // ushr cannot encode a shift of zero (immh:immb holds 2*esize-shift),
            // and a zero shift is just the value.
            if (sh == 0)
                [ctx.out appendFormat:@"    mov v%lu.16b, v%lu.16b\n",
                 (unsigned long)d, (unsigned long)a];
            else
                [ctx.out appendFormat:@"    ushr v%lu.%@, v%lu.%@, #%lld\n",
                 (unsigned long)d, arr, (unsigned long)a, arr, (long long)sh];
            break;
        }
        case XTIROpVICmp: {       // lane-wise compare → 0/-1 mask
            if (insn.operands.count < 2 || !insn.result ||
                insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[1].kind != XTIROperandKindUse) break;
            NSString *arr = [self neonArrFor:insn.result.type.pointeeType];
            NSUInteger a = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            NSUInteger b = [self vecIndexForValue:insn.operands[1].valueId ctx:ctx];
            NSUInteger d = [self vecIndexForValue:insn.result.valueId ctx:ctx];
            // cmhi/cmhs (unsigned), cmgt/cmge (signed), cmeq; the `<`/`<=` forms
            // reuse the `>`/`>=` instruction with operands swapped. NE = EQ then
            // bitwise-not the mask.
            NSString *cm = nil; BOOL swap = NO, invert = NO;
            switch (insn.predicate) {
                case XTIRICmpUGT: cm = @"cmhi"; break;
                case XTIRICmpUGE: cm = @"cmhs"; break;
                case XTIRICmpULT: cm = @"cmhi"; swap = YES; break;
                case XTIRICmpULE: cm = @"cmhs"; swap = YES; break;
                case XTIRICmpSGT: cm = @"cmgt"; break;
                case XTIRICmpSGE: cm = @"cmge"; break;
                case XTIRICmpSLT: cm = @"cmgt"; swap = YES; break;
                case XTIRICmpSLE: cm = @"cmge"; swap = YES; break;
                case XTIRICmpEQ:  cm = @"cmeq"; break;
                case XTIRICmpNE:  cm = @"cmeq"; invert = YES; break;
                default: break;
            }
            if (!cm) break;
            NSUInteger lhs = swap ? b : a, rhs = swap ? a : b;
            [ctx.out appendFormat:@"    %@ v%lu.%@, v%lu.%@, v%lu.%@\n",
             cm, (unsigned long)d, arr, (unsigned long)lhs, arr, (unsigned long)rhs, arr];
            if (invert) [ctx.out appendFormat:@"    not v%lu.16b, v%lu.16b\n", (unsigned long)d, (unsigned long)d];
            break;
        }
        case XTIROpVReduceMax: case XTIROpVReduceMin: {  // horizontal max/min
            // .4s-only (i32/u32 lanes) by construction, like VReduceAdd.
            if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse ||
                !insn.result) break;
            BOOL sgn = XTIRTypeKindIsSigned(insn.result.type.kind);
            NSString *mnem = (insn.opcode == XTIROpVReduceMax)
                ? (sgn ? @"smaxv" : @"umaxv") : (sgn ? @"sminv" : @"uminv");
            NSUInteger v = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            [ctx.out appendFormat:@"    %@ s%lu, v%lu.4s\n", mnem, (unsigned long)v, (unsigned long)v];
            NSString *d = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    fmov %@, s%lu\n", d, (unsigned long)v];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }
        case XTIROpVReduceAdd: {  // scalar <- horizontal add of all lanes
            // Only i32/u32 lanes (.4s) are produced by the reduction vectorizer;
            // `addv` has no .2d form, so this path is .4s-only by construction.
            if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse ||
                !insn.result) break;
            NSUInteger v = [self vecIndexForValue:insn.operands[0].valueId ctx:ctx];
            // addv folds the four lanes into the low s-element of the same
            // register; fmov then moves it into the GP result register.
            [ctx.out appendFormat:@"    addv s%lu, v%lu.4s\n", (unsigned long)v, (unsigned long)v];
            NSString *d = [self resultReg:insn.result.valueId scratch:@"w16" ctx:ctx];
            [ctx.out appendFormat:@"    fmov %@, s%lu\n", d, (unsigned long)v];
            [self storeReg:d intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        case XTIROpVaStart: {
            // Native AAPCS va_list (bug 179). ap = the FIRST incoming variadic
            // stack arg. Under Darwin's rule every variadic arg is on the stack,
            // above this callee's frame: at sp + frameSize + (bytes any FIXED
            // params spilled to the stack, usually 0 — a few fixed args ride
            // x0-x7). Store ap into the cursor slot (operand 0 = &cursor).
            if (insn.operands.count < 1) break;
            NSUInteger off = ctx.frameSize + [self arm64FixedParamStackBytes:ctx];
            [self emitSpAddr:off into:@"x17" ctx:ctx];           // x17 = ap
            [self emitDerefAddrFor:insn.operands[0] ctx:ctx];    // x16 = &cursor
            [ctx.out appendString:@"    str x17, [x16]\n"];
            break;
        }
        case XTIROpVaArg: {
            // Read the next AAPCS arg from the va_list and advance the cursor by
            // one 8-byte slot (Darwin strides every scalar vararg at 8; a struct
            // occupies its 8-rounded size, inline). The caller (cVarargPromote)
            // widened narrow ints to i32 and f32 to f64, so a float result reads
            // the promoted double back and converts.
            if (insn.operands.count < 1 || !insn.result) break;
            [self emitDerefAddrFor:insn.operands[0] ctx:ctx];    // x16 = &cursor
            [ctx.out appendString:@"    ldr x17, [x16]\n"];       // x17 = cursor
            XTIRType *rt = insn.result.type;
            // struct-by-value vararg — the aggregate sits INLINE in the list, so
            // hand back a POINTER to it (the cursor) and advance by its size.
            if (rt && rt.kind == XTIRTypeKindPtr && rt.pointeeType
                && rt.pointeeType.kind == XTIRTypeKindAgg) {
                NSUInteger sz  = [self arm64AggSize:rt.pointeeType.layout];
                NSUInteger adv = (sz + 7) & ~(NSUInteger)7; if (adv == 0) adv = 8;
                [ctx.out appendFormat:@"    add x9, x17, #%lu\n    str x9, [x16]\n",
                 (unsigned long)adv];
                [self storeReg:@"x17" intoValue:insn.result.valueId ctx:ctx];
                break;
            }
            [ctx.out appendString:@"    add x9, x17, #8\n    str x9, [x16]\n"];  // one slot
            if (rt && rt.kind == XTIRTypeKindF32) {
                // Promoted to double in the list; read it and narrow to single.
                [ctx.out appendString:@"    ldr d0, [x17]\n    fcvt s0, d0\n"
                                       "    fmov w16, s0\n"];
                [self storeReg:@"w16" intoValue:insn.result.valueId ctx:ctx];
                break;
            }
            uint32_t w = rt ? rt.byteWidth : 4;
            NSString *dst = ((rt && rt.kind == XTIRTypeKindPtr) || w >= 8) ? @"x16" : @"w16";
            [ctx.out appendFormat:@"    ldr %@, [x17]\n", dst];   // F64 rides GP bits like a Load
            [self canonicaliseReg:dst toType:rt ctx:ctx];
            [self storeReg:dst intoValue:insn.result.valueId ctx:ctx];
            break;
        }

        default:
            [ctx.out appendFormat:@"    // unsupported opcode %d\n", (int)insn.opcode];
            break;
    }
}

#pragma mark - Function emission

// ── Spill peephole ───────────────────────────────────────────────────────
//
// The emit model materialises every unhomed SSA value to a stack slot:
// a result is `str`'d to [sp,#N] and each use is `ldr`'d back. For a
// short-lived temp used once right after its def this round-trips a
// register through memory (in ahl's hot loop ~40% of instructions are
// such spill traffic). This pass runs per function and rewrites:
//
//   (always) Store→load forward — `str R,[sp,#N]` immediately followed by
//     `ldr R2,[sp,#N]` (same register class) → keep the store, replace the
//     load with `R2 ← R` (dropped if R2==R). Unconditionally safe: R holds
//     the value across the adjacent pair and the store still writes memory.
//
// The next two REDUCE instruction count, but are only sound when the
// function never materialises a stack address — i.e. there is no
// `add/sub Rd, sp` and no non-frame `stp/ldp`. In that "clean" case ALL
// spill memory is reached through literal single `[sp,#N]` str/ldr, so a
// per-offset load count is exact:
//
//   (clean) Dead spill store — `str R,[sp,#N]` whose slot is never loaded
//     → drop. (Removes e.g. an inlined nullary call's unused receiver.)
//   (clean) Forward + drop — in the store→load-forward case, if that load
//     is the slot's only load, drop the store too.
//
// In an "unclean" function spill memory can be re-read through a base
// pointer as `[xR,#K]`, invisible to a literal-`[sp,#N]` scan, so removing
// a store there is unsafe — only the always-safe forward runs.

// Parse `<mnem> <reg>, [sp, #<off>]` (or `[sp]`); fill *mnem/*reg/*off and
// return YES. Returns the raw offset string ("0" for a bare `[sp]`).
+ (BOOL)parseSpLine:(NSString *)line
               mnem:(NSString **)mnem
                reg:(NSString **)reg
                off:(NSString **)off {
    NSString *s = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    NSRange sp = [s rangeOfString:@", [sp"];
    if (sp.location == NSNotFound) return NO;
    NSString *head = [s substringToIndex:sp.location];   // "<mnem> <reg>"
    NSRange spc = [head rangeOfString:@" "];
    if (spc.location == NSNotFound) return NO;
    *mnem = [head substringToIndex:spc.location];
    *reg = [[head substringFromIndex:spc.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *tail = [s substringFromIndex:sp.location];  // ", [sp...]"
    NSRange hash = [tail rangeOfString:@"#"];
    if (hash.location == NSNotFound) {                    // bare "[sp]"
        if ([tail hasSuffix:@"[sp]"]) { *off = @"0"; return YES; }
        return NO;
    }
    NSRange close = [tail rangeOfString:@"]"];
    if (close.location == NSNotFound || close.location < hash.location) return NO;
    *off = [[tail substringWithRange:NSMakeRange(hash.location + 1,
              close.location - hash.location - 1)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return YES;
}

// ── Staged frame-slot canonicalisation ───────────────────────────────────
//
// A frame slot past the encodable range (16380 for a w/s view, 32760 for x/d)
// cannot be reached by `ldr/str <reg>, [sp, #off]`, so spMemForOff stages the
// address and the access goes register-indirect:
//
//     mov w9, #16840            (+ movk w9, #hi, lsl #16 past 64 KB)
//     add x9, sp, x9
//     str w17, [x9]
//
// The spill peephole cannot see through that. It parses `[sp, #off]` only, so
// it never forwards a store to the load that follows it, and `add x9, sp, x9`
// trips its aliasing check and turns dead-store removal off for the whole
// function. A frame over 16 KB therefore loses BOTH optimisations, and every
// slot access costs three instructions instead of one — which is what any loop
// over a stack array hits. Measured on int_accum's inner loop: 21 instructions
// over the cliff against 10 under it, for the same source.
//
// Canonicalising the idiom back to `[sp, #off]` before the peepholes run lets
// their existing logic apply unchanged; expandStagedSlots re-expands whatever
// is still out of range afterwards.
+ (NSString *)canonicaliseStagedSlots:(NSString *)text {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    NSUInteger i = 0;
    while (i < lines.count) {
        NSString *t0 = [lines[i] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
        NSString *stageReg = nil;           // "x9" / "x16"
        int64_t off = -1;
        NSUInteger consumed = 0;

        // Form A: mov wN, #lo [; movk wN, #hi, lsl #16] ; add xN, sp, xN
        if ([t0 hasPrefix:@"mov w9, #"] || [t0 hasPrefix:@"mov w16, #"]) {
            NSString *wreg = [t0 hasPrefix:@"mov w9, #"] ? @"w9" : @"w16";
            NSString *xreg = [wreg isEqualToString:@"w9"] ? @"x9" : @"x16";
            int64_t lo = [[t0 substringFromIndex:[t0 rangeOfString:@"#"].location + 1] longLongValue];
            NSUInteger j = i + 1;
            int64_t hi = 0;
            NSString *movk = [NSString stringWithFormat:@"movk %@, #", wreg];
            if (j < lines.count) {
                NSString *tj = [lines[j] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
                if ([tj hasPrefix:movk] && [tj hasSuffix:@", lsl #16"]) {
                    NSString *mid = [tj substringFromIndex:movk.length];
                    hi = [[mid componentsSeparatedByString:@","][0] longLongValue];
                    j++;
                }
            }
            NSString *addForm = [NSString stringWithFormat:@"add %@, sp, %@", xreg, xreg];
            if (j < lines.count) {
                NSString *tj = [lines[j] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
                if ([tj isEqualToString:addForm]) {
                    off = lo + (hi << 16);
                    stageReg = xreg;
                    consumed = j + 1 - i;
                }
            }
        }
        // Form B: add xN, sp, #M, lsl #12
        if (!stageReg) {
            for (NSString *xreg in @[@"x9", @"x16"]) {
                NSString *pre = [NSString stringWithFormat:@"add %@, sp, #", xreg];
                if ([t0 hasPrefix:pre] && [t0 hasSuffix:@", lsl #12"]) {
                    NSString *mid = [t0 substringFromIndex:pre.length];
                    off = [[mid componentsSeparatedByString:@","][0] longLongValue] << 12;
                    stageReg = xreg;
                    consumed = 1;
                    break;
                }
            }
        }

        // The access must be the very next line and use exactly [xN].
        if (stageReg && off >= 0 && i + consumed < lines.count) {
            NSString *acc = [lines[i + consumed] stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
            NSString *needle = [NSString stringWithFormat:@", [%@]", stageReg];
            NSRange nr = [acc rangeOfString:needle];
            if (nr.location != NSNotFound && [acc hasSuffix:needle]) {
                NSString *head = [acc substringToIndex:nr.location];   // "<mnem> <reg>"
                NSRange spc = [head rangeOfString:@" "];
                if (spc.location != NSNotFound) {
                    NSString *mnem = [head substringToIndex:spc.location];
                    NSString *reg = [[head substringFromIndex:spc.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    // Only the plain word/dword loads and stores spMemForOff emits,
                    // and never when the data register IS the staging register.
                    BOOL simple = [mnem isEqualToString:@"ldr"] || [mnem isEqualToString:@"str"];
                    if (simple && ![reg isEqualToString:stageReg]
                        && ![reg isEqualToString:[@"w" stringByAppendingString:
                                                  [stageReg substringFromIndex:1]]]) {
                        [out addObject:[NSString stringWithFormat:@"    %@ %@, [sp, #%lld]",
                                        mnem, reg, off]];
                        i += consumed + 1;
                        continue;
                    }
                }
            }
        }
        [out addObject:lines[i]];
        i++;
    }
    return [out componentsJoinedByString:@"\n"];
}

// Re-expand any `[sp, #off]` the hardware cannot encode, using the same staging
// spMemForOff uses. Runs after the peepholes, so anything they forwarded or
// dropped never pays the staging cost.
+ (NSString *)expandStagedSlots:(NSString *)text
                     frameBase:(NSUInteger)frameBase
                  saveAreaFrom:(NSUInteger)saveAreaStart
                            to:(NSUInteger)saveAreaEnd {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    NSString *m = nil, *r = nil, *o = nil;
    // Two exclusions, and they cannot be a running on/off flag: block bodies are
    // laid out in declaration order, so a loop body often sits AFTER the block
    // holding the epilogue, and a flag cleared at the epilogue would switch the
    // base off for the hottest code in the function.
    //
    //   - Anything emitted BEFORE the setup line (the sret spill) has no x28
    //     yet, so the bound is positional.
    //   - The callee-save area itself is off limits wherever it appears: those
    //     stores run before the setup, and the epilogue's reloads overwrite x28
    //     partway through. Excluding the offset RANGE covers both ends.
    //
    // Getting this wrong is what made array_map, mem_copy, float_math and
    // arc_array compute wrong answers on the first attempt.
    NSInteger setupIdx = -1;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *t = [lines[i] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"add x28, sp, #"]) { setupIdx = (NSInteger)i; break; }
    }
    NSInteger lineIdx = -1;
    for (NSString *ln in lines) {
        lineIdx++;
        BOOL baseLive = (setupIdx >= 0 && lineIdx > setupIdx);
        if (([self parseSpLine:ln mnem:&m reg:&r off:&o])
            && ([m isEqualToString:@"ldr"] || [m isEqualToString:@"str"])) {
            long long off = [o longLongValue];
            NSUInteger max = ([r hasPrefix:@"w"] || [r hasPrefix:@"s"]) ? 16380 : 32760;
            if (off > (long long)max) {
                // One instruction through the frame base when it reaches.
                BOOL inSaveArea = (saveAreaEnd > saveAreaStart
                                   && off >= (long long)saveAreaStart
                                   && off < (long long)saveAreaEnd);
                if (baseLive && frameBase && !inSaveArea
                    && off >= (long long)frameBase
                    && (off - (long long)frameBase) <= (long long)max
                    && ![r isEqualToString:@"x28"]) {
                    [out addObject:[NSString stringWithFormat:@"    %@ %@, [x28, #%lld]",
                                    m, r, off - (long long)frameBase]];
                    continue;
                }
                NSString *stage = ([r isEqualToString:@"x9"] || [r isEqualToString:@"w9"])
                                  ? @"x16" : @"x9";
                NSString *w = [@"w" stringByAppendingString:[stage substringFromIndex:1]];
                if ((off & 0xFFF) == 0 && (off >> 12) <= 4095) {
                    [out addObject:[NSString stringWithFormat:@"    add %@, sp, #%lld, lsl #12",
                                    stage, off >> 12]];
                } else {
                    [out addObject:[NSString stringWithFormat:@"    mov %@, #%lld", w, off & 0xFFFF]];
                    if (off > 0xFFFF)
                        [out addObject:[NSString stringWithFormat:@"    movk %@, #%lld, lsl #16",
                                        w, off >> 16]];
                    [out addObject:[NSString stringWithFormat:@"    add %@, sp, %@", stage, stage]];
                }
                [out addObject:[NSString stringWithFormat:@"    %@ %@, [%@]", m, r, stage]];
                continue;
            }
        }
        [out addObject:ln];
    }
    return [out componentsJoinedByString:@"\n"];
}

// The frame byte RANGE a taken address could reach: for every value whose
// address is taken (AddrOf), and every aggregate — which is only ever touched
// through one — the span from its slot offset to slot + size.
//
// An aggregate occupies ONE slot but spans thousands of bytes, so marking bare
// slot offsets is not enough: a pointer walking it reaches addresses the offset
// set never mentions. Ranges are what the aliasing question is about.
+ (void)aliasableRangeForCtx:(XTArm64FnCtx *)ctx
                          lo:(NSUInteger *)outLo
                          hi:(NSUInteger *)outHi {
    NSUInteger lo = NSUIntegerMax, hi = 0;
    if (!ctx.fn || !ctx.slotOffsets) { *outLo = 0; *outHi = NSUIntegerMax; return; }
    NSMutableSet<NSNumber *> *taken = [NSMutableSet set];
    for (XTIRBlock *bb in ctx.fn.blocks) {
        NSMutableArray<XTIRInsn *> *all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        for (XTIRInsn *in in all)
            if (in.opcode == XTIROpAddrOf)
                for (XTIROperand *o in in.operands)
                    if (o.kind == XTIROperandKindUse) [taken addObject:@(o.valueId)];
    }
    for (XTIRPinnedLocal *pl in ctx.fn.frameInfo.pinnedLocals)
        [taken addObject:@(pl.valueId)];
    for (NSUInteger vid = 0; vid < ctx.slotOffsets.count; vid++) {
        XTIRValue *v = [ctx.fn valueForId:vid];
        BOOL agg = (v && v.type && v.type.kind == XTIRTypeKindAgg);
        if (!agg && ![taken containsObject:@(vid)]) continue;
        NSUInteger off = ctx.slotOffsets[vid].unsignedIntegerValue;
        NSUInteger sz = 8;
        if (agg) {
            sz = [self arm64AggSize:v.type.layout];
            sz = (sz + 7) & ~(NSUInteger)7;
            if (sz < 8) sz = 8;
        }
        if (off < lo) lo = off;
        if (off + sz > hi) hi = off + sz;
    }
    if (lo == NSUIntegerMax) { lo = 0; hi = 0; }
    *outLo = lo; *outHi = hi;
}

+ (NSString *)peepholeSpills:(NSString *)text
                 aliasLo:(NSUInteger)aliasLo
                 aliasHi:(NSUInteger)aliasHi
                 argArea:(NSUInteger)argArea {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSString *m = nil, *r = nil, *o = nil;

    // Cleanliness scan + (if clean) per-offset load count.
    BOOL clean = YES;            // no non-frame stp/ldp
    BOOL spAddrTaken = NO;       // some frame address escaped
    NSCountedSet<NSString *> *loads = [NSCountedSet set];
    for (NSString *ln in lines) {
        NSString *t = [ln stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        // Stack-address materialisation `add/sub Rd, sp, ...` (Rd != sp),
        // or a non-frame stp/ldp, means spill memory may alias via [xR,#K].
        // The frame adjust `add/sub sp, sp, #N` (Rd == sp) is not a base
        // pointer and must not disqualify the function.
        if (([t hasPrefix:@"add "] || [t hasPrefix:@"sub "])
            && ![t hasPrefix:@"add sp,"] && ![t hasPrefix:@"sub sp,"]
            && [t rangeOfString:@", sp,"].location != NSNotFound) {
            spAddrTaken = YES;      // only the aliasable RANGE is at risk
        }
        if (([t hasPrefix:@"stp "] || [t hasPrefix:@"ldp "])
            && [t rangeOfString:@"x29, x30"].location == NSNotFound) {
            clean = NO;
        }
        if ([self parseSpLine:ln mnem:&m reg:&r off:&o]
            && ([m hasPrefix:@"ldr"])) {
            [loads addObject:o];
        }
    }

    NSMutableArray<NSString *> *outLines = [NSMutableArray arrayWithCapacity:lines.count];
    NSUInteger i = 0;
    while (i < lines.count) {
        NSString *ln = lines[i];
        NSString *sm = nil, *sr = nil, *so = nil;
        if ([self parseSpLine:ln mnem:&sm reg:&sr off:&so]
            && [sm isEqualToString:@"str"]) {
            // (clean) dead store — slot never loaded → drop.
            // Outgoing arguments live at [sp, #0 .. maxOutStack) and are read by
            // the CALLEE, so no `ldr` in THIS function ever names them. Treating
            // them as dead deletes the arguments to every stack-passing call —
            // which is what broke 14 of 19 benchmarks on two earlier attempts.
            long long soff = [so longLongValue];
            BOOL isArg = soff < (long long)argArea;
            BOOL reachable = spAddrTaken
                && soff >= (long long)aliasLo && soff < (long long)aliasHi;
            if (clean && !isArg && !reachable && [loads countForObject:so] == 0) { i++; continue; }
            // store→load forward (load on the very next line, same class).
            NSString *lm = nil, *lr = nil, *lo = nil;
            if (i + 1 < lines.count
                && [self parseSpLine:lines[i + 1] mnem:&lm reg:&lr off:&lo]
                && [lm isEqualToString:@"ldr"] && [lo isEqualToString:so]
                && [self regClass:lr] == [self regClass:sr]) {
                BOOL dropStore = clean && !isArg && !reachable && [loads countForObject:so] == 1;
                if (!dropStore) [outLines addObject:ln];  // keep the store
                if (![lr isEqualToString:sr]) {            // skip a no-op move
                    BOOL fp = ([self regClass:lr] == 'd' || [self regClass:lr] == 's');
                    [outLines addObject:[NSString stringWithFormat:@"    %@ %@, %@",
                                         fp ? @"fmov" : @"mov", lr, sr]];
                }
                i += 2;
                continue;
            }
        }
        [outLines addObject:ln];
        i++;
    }
    return [outLines componentsJoinedByString:@"\n"];
}

// First letter of a register name ('w','x','s','d','q','b','h') — the
// register class. Identical-class str/ldr move losslessly via mov/fmov.
+ (unichar)regClass:(NSString *)reg {
    return reg.length ? [reg characterAtIndex:0] : 0;
}

// ── Copy-propagation peephole ────────────────────────────────────────────
//
// The spill peephole forwards a `str sX,[N]; ldr sY,[N]` spill round-trip into
// `fmov sY, sX`. When sY is a SCRATCH register (never live across a block edge)
// and the very next instruction reads sY, that move can vanish: rewrite the
// consumer's source(s) sY→sX and drop the `fmov`, provided sY's value is dead
// after that instruction (it overwrites sY, or sY isn't read again before being
// rewritten / a branch). Removes the `fmov sX→sY` staging short-lived FP temps
// that don't fit the callee-saved homes leave in ahl's hot loop.

// Mnemonics whose first operand is NOT a written register (so reading the value
// onward must continue past them) — stores, compares, branches, returns.
static BOOL mnemWritesReg0(NSString *m) {
    static NSSet *no;
    if (!no) no = [NSSet setWithArray:@[@"str", @"strb", @"strh", @"stp", @"stur",
        @"cmp", @"cmn", @"fcmp", @"tst", @"b", @"bl", @"br", @"blr", @"ret",
        @"cbz", @"cbnz", @"tbz", @"tbnz"]];
    return ![no containsObject:m];
}

// Split a trimmed asm line into (mnemonic, comma-separated operand tokens).
// Returns nil for labels/directives/comments/blanks.
+ (NSArray *)parseAsmLine:(NSString *)line mnem:(NSString **)mnemOut {
    NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0 || [t hasSuffix:@":"] || [t hasPrefix:@"."] || [t hasPrefix:@"//"]) return nil;
    NSRange sp = [t rangeOfString:@" "];
    if (sp.location == NSNotFound) { if (mnemOut) *mnemOut = t; return @[]; }   // bare mnem (e.g. ret)
    if (mnemOut) *mnemOut = [t substringToIndex:sp.location];
    NSArray *raw = [[t substringFromIndex:sp.location + 1] componentsSeparatedByString:@","];
    NSMutableArray *ops = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *o in raw) [ops addObject:[o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    return ops;
}

// Does `reg` appear as a whole-word token anywhere in `line` (incl. inside a
// `[base, #off]` memory operand)?
static BOOL lineMentionsReg(NSString *line, NSString *reg) {
    NSRange r = [line rangeOfString:reg];
    while (r.location != NSNotFound) {
        NSUInteger b = r.location, e = r.location + r.length;
        unichar before = b > 0 ? [line characterAtIndex:b - 1] : ' ';
        unichar after  = e < line.length ? [line characterAtIndex:e] : ' ';
        BOOL alnumB = (before >= '0' && before <= '9') || (before >= 'a' && before <= 'z');
        BOOL alnumA = (after  >= '0' && after  <= '9') || (after  >= 'a' && after  <= 'z');
        if (!alnumB && !alnumA) return YES;
        NSRange rest = NSMakeRange(e, line.length - e);
        r = [line rangeOfString:reg options:0 range:rest];
    }
    return NO;
}

// Only these throwaway scratch registers are safe as the move destination — they
// are never homed and never carry a value across a block boundary.
static BOOL isScratchDst(NSString *reg) {
    if (reg.length < 2) return NO;
    unichar c = [reg characterAtIndex:0];
    NSString *num = [reg substringFromIndex:1];
    if (c == 's' || c == 'd') return [@[@"0", @"1", @"2", @"16"] containsObject:num];
    if (c == 'w' || c == 'x') return [@[@"9", @"16", @"17"] containsObject:num];
    return NO;
}

// Branch fall-through / inversion. The block walker always emits a conditional
// branch as `b.<c> LT` followed by `b LF`, never using layout fall-through. When
// the block laid out next is one of the two targets, one branch is redundant:
//   • next == LF  → drop the `b LF` (fall straight through to it).
//   • next == LT  → invert the condition to `b.<!c> LF` and fall through to LT,
//     turning the loop-entry's *taken* forward branch into a not-taken one and
//     dropping the `b LF`. (A loop header `cmp; b.<c> body; b exit` with body laid
//     out next becomes `cmp; b.<!c> exit` + fall-through — one fewer taken branch
//     per iteration.) A lone `b L` with L laid out next is likewise dropped.
// Safe by construction: the two branch lines must be ADJACENT for the pattern to
// match, so there are no edge phi-copy `mov`s between them (those would break an
// inversion); the taken-edge copies the walker emits *before* the conditional run
// on both paths already, which inversion preserves.
// ── Redundant-reload peephole ────────────────────────────────────────────
//
// The spill peephole forwards a STORE to the load that follows it. It does not
// notice a slot being LOADED twice into the same register with nothing changing
// in between, which is what an index or a loop-invariant base looks like when
// it is slot-homed and read once per use:
//
//     ldr w17, [sp, #16624]     ; index
//     add x16, x16, w17, uxtw #2
//     ldr x16, [sp, #16640]
//     ldr w17, [sp, #16624]     ; same slot, same register, still live
//
// Within one basic block, a reload is redundant when the slot has not been
// stored to, the destination register has not been written, and no call has
// intervened. Conservative on every count: any label, branch, call or write to
// the register drops the fact.
// Same physical register, whatever view names it: writing `w16` zeroes the top
// half of `x16`, so a fact recorded about one view must die with the other.
static BOOL sameArm64Reg(NSString *a, NSString *b) {
    if (!a || !b) return NO;
    if ([a isEqualToString:b]) return YES;
    unichar ca = [a characterAtIndex:0], cb = [b characterAtIndex:0];
    // Two views alias when they name the same physical register: w/x in the
    // general file, and b/h/s/d/q/v in the VECTOR file — writing `s8` zeroes
    // the rest of `d8` exactly as `w16` zeroes the top of `x16`. Knowing only
    // about w/x let a `d8` fact survive an `s8` write, and the next reload was
    // wrongly dropped (auto_cloak's Math.pow tests, caught by the corpus).
    BOOL gpA = (ca == 'w' || ca == 'x'), gpB = (cb == 'w' || cb == 'x');
    BOOL fpA = (ca=='b'||ca=='h'||ca=='s'||ca=='d'||ca=='q'||ca=='v');
    BOOL fpB = (cb=='b'||cb=='h'||cb=='s'||cb=='d'||cb=='q'||cb=='v');
    if (!((gpA && gpB) || (fpA && fpB))) return NO;
    return [[a substringFromIndex:1] isEqualToString:[b substringFromIndex:1]];
}

+ (NSString *)peepholeRedundantReloads:(NSString *)text {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableDictionary<NSString *, NSString *> *held = [NSMutableDictionary dictionary];  // off -> reg
    NSString *m = nil, *r = nil, *o = nil;
    for (NSString *ln in lines) {
        NSString *t = [ln stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length == 0 || [t hasSuffix:@":"] || [t hasPrefix:@"."] || [t hasPrefix:@"//"]) {
            [held removeAllObjects];                      // block boundary / directive
            [out addObject:ln];
            continue;
        }
        NSString *jm = nil;
        NSArray *jo = [self parseAsmLine:ln mnem:&jm];
        if (!jm) { [held removeAllObjects]; [out addObject:ln]; continue; }
        if ([@[@"b", @"bl", @"br", @"blr", @"ret", @"cbz", @"cbnz",
               @"tbz", @"tbnz"] containsObject:jm]
            || [jm hasPrefix:@"b."]) {
            [held removeAllObjects];                      // call/branch: registers gone
            [out addObject:ln];
            continue;
        }
        // A pair op touches TWO registers and `mnemWritesReg0` only names the
        // first, so never try to track through one.
        if ([jm isEqualToString:@"ldp"] || [jm isEqualToString:@"stp"]) {
            [held removeAllObjects];
            [out addObject:ln];
            continue;
        }
        if ([self parseSpLine:ln mnem:&m reg:&r off:&o]) {
            if ([m isEqualToString:@"ldr"]) {
                NSString *cur = held[o];
                if (cur && [cur isEqualToString:r]) continue;   // already there — drop
                // This load redefines r; anything else believed to be in r is stale.
                for (NSString *k in held.allKeys)
                    if (sameArm64Reg(held[k], r)) [held removeObjectForKey:k];
                held[o] = r;
                [out addObject:ln];
                continue;
            }
            if ([m isEqualToString:@"str"]) {
                // An sp-relative store writes exactly this slot, so only this
                // slot's fact changes. (strb/strh write PART of it — the record
                // would be a lie for a later full-width load, so drop it.)
                held[o] = r;
                [out addObject:ln];
                continue;
            }
            [held removeAllObjects];
            [out addObject:ln];
            continue;
        }
        // A store through any other base could land anywhere in the frame —
        // c[i] = … writes through a pointer into a stack array — so nothing
        // believed about any slot survives it.
        if ([jm hasPrefix:@"st"]) {
            [held removeAllObjects];
            [out addObject:ln];
            continue;
        }
        // A plain instruction: whatever it writes invalidates that register.
        if (jo.count >= 1 && mnemWritesReg0(jm)) {
            NSString *w = jo[0];
            for (NSString *k in held.allKeys)
                if (sameArm64Reg(held[k], w)) [held removeObjectForKey:k];
        }
        [out addObject:ln];
    }
    return [out componentsJoinedByString:@"\n"];
}

+ (NSString *)peepholeFallthrough:(NSString *)text {
    static NSDictionary *inv;
    if (!inv) inv = @{@"eq":@"ne",@"ne":@"eq",@"lo":@"hs",@"hs":@"lo",
                      @"ls":@"hi",@"hi":@"ls",@"lt":@"ge",@"ge":@"lt",
                      @"le":@"gt",@"gt":@"le",@"mi":@"pl",@"pl":@"mi",
                      @"cc":@"cs",@"cs":@"cc",@"vs":@"vc",@"vc":@"vs",
                      @"cbz":@"cbnz",@"cbnz":@"cbz"};
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *(^labelOf)(NSString *) = ^NSString *(NSString *ln){
        NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return ([t hasSuffix:@":"] && t.length > 1) ? [t substringToIndex:t.length - 1] : nil;
    };
    NSInteger (^nextReal)(NSUInteger) = ^NSInteger(NSUInteger i){
        for (NSUInteger j = i + 1; j < lines.count; j++)
            if ([[lines[j] stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]] length]) return (NSInteger)j;
        return -1;
    };
    BOOL again = YES;
    while (again) {
        again = NO;
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *t = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            // Lone unconditional `b L` immediately before `L:` → fall through.
            if ([t hasPrefix:@"b "]) {
                NSString *tgt = [t substringFromIndex:2];
                NSInteger j = nextReal(i);
                if (j >= 0 && [labelOf(lines[j]) isEqualToString:tgt]) {
                    [lines removeObjectAtIndex:i]; again = YES; break;
                }
                continue;
            }
            // Conditional `b.<c> LT` or `cb(n)z reg, LT`, then `b LF`, then a label.
            BOOL isDot = [t hasPrefix:@"b."];
            BOOL isCb  = [t hasPrefix:@"cbz "] || [t hasPrefix:@"cbnz "];
            if (!isDot && !isCb) continue;
            NSInteger j = nextReal(i);
            if (j < 0) continue;
            NSString *jt = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (![jt hasPrefix:@"b "]) continue;          // need an adjacent uncond branch
            NSString *LF = [jt substringFromIndex:2];
            NSInteger k = nextReal(j);
            if (k < 0) continue;
            NSString *nextLbl = labelOf(lines[k]);
            if (!nextLbl) continue;
            // Parse the conditional's mnemonic, register (cb only), and target LT.
            NSString *mnem, *reg = nil, *LT;
            if (isDot) {
                NSRange sp = [t rangeOfString:@" "];
                mnem = [t substringToIndex:sp.location];               // "b.lo"
                LT = [[t substringFromIndex:sp.location + 1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            } else {
                NSRange sp = [t rangeOfString:@" "];
                mnem = [t substringToIndex:sp.location];               // "cbz"/"cbnz"
                NSArray *ops = [[t substringFromIndex:sp.location + 1] componentsSeparatedByString:@","];
                if (ops.count != 2) continue;
                reg = [ops[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                LT  = [ops[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
            if ([nextLbl isEqualToString:LF]) {
                // Uncond target is laid out next → drop the `b LF`.
                [lines removeObjectAtIndex:j]; again = YES; break;
            }
            if ([nextLbl isEqualToString:LT]) {
                // Cond target is next → invert condition, branch to LF, drop `b LF`.
                NSString *cc = isDot ? [mnem substringFromIndex:2] : mnem;
                NSString *ic = inv[cc];
                if (!ic) continue;
                lines[i] = isDot
                    ? [NSString stringWithFormat:@"    b.%@ %@", ic, LF]
                    : [NSString stringWithFormat:@"    %@ %@, %@", ic, reg, LF];
                [lines removeObjectAtIndex:j]; again = YES; break;
            }
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

+ (NSString *)peepholeCopyProp:(NSString *)text {
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL again = YES;
    while (again) {
        again = NO;
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            NSString *mm = nil;
            NSArray *mo = [self parseAsmLine:lines[i] mnem:&mm];
            if (!mo || mo.count != 2) continue;
            if (![mm isEqualToString:@"fmov"] && ![mm isEqualToString:@"mov"]) continue;
            NSString *dst = mo[0], *src = mo[1];
            if ([dst isEqualToString:src] || !isScratchDst(dst)) continue;
            // src must be a plain register (not an immediate / shifted form).
            if ([src hasPrefix:@"#"] || [src rangeOfString:@" "].location != NSNotFound) continue;

            NSString *cm = nil;
            NSArray *co = [self parseAsmLine:lines[i + 1] mnem:&cm];
            if (!co || co.count == 0) continue;
            // An FP register source (`s27`/`d5`/`v3` — NOT `sp`) may only be
            // propagated into a reg-reg move, and that move must then be an
            // `fmov`: substituting it into a GP `mov` leaves the invalid
            // `mov w0, s27`, and into any GP arithmetic op an unassemblable
            // operand. Exposed when a `fmov wS, sN; mov w0, wS` reduction-return
            // pair collapsed (bug 203 follow-up). GP↔GP propagation is unchanged.
            BOOL srcFP = src.length > 1
                && ([src hasPrefix:@"s"] || [src hasPrefix:@"d"] || [src hasPrefix:@"v"])
                && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[src characterAtIndex:1]];
            if (srcFP && !(([cm isEqualToString:@"mov"] || [cm isEqualToString:@"fmov"])
                           && co.count == 2))
                continue;
            // Substitute dst→src in the consumer's SOURCE operands (1..) that are
            // exactly dst; operand 0 (the write target) is left alone.
            BOOL used = NO;
            NSMutableArray *no = [co mutableCopy];
            for (NSUInteger k = 1; k < no.count; k++)
                if ([no[k] isEqualToString:dst]) { no[k] = src; used = YES; }
            // A memory operand names its base inside brackets, so an exact
            // match never fires for `mov x16, x12; ldr w17, [x16]` — the copy
            // survived in front of essentially every load in a hot loop. Rewrite
            // the base of the simple forms `[dst]` and `[dst, #imm]` too, and
            // only when the operand is last and the line has no writeback (`!`),
            // so a pre/post-indexed form — which WRITES the base — is left alone.
            if (!used && !srcFP && [src hasPrefix:@"x"]
                && [lines[i + 1] rangeOfString:@"!"].location == NSNotFound) {
                NSUInteger last = no.count - 1;
                if (no.count >= 2) {
                    NSString *opnd = no[last];
                    NSString *plain = [NSString stringWithFormat:@"[%@]", dst];
                    NSString *pre = [NSString stringWithFormat:@"[%@, #", dst];
                    if ([opnd isEqualToString:plain]) {
                        no[last] = [NSString stringWithFormat:@"[%@]", src];
                        used = YES;
                    } else if ([opnd hasPrefix:pre] && [opnd hasSuffix:@"]"]) {
                        no[last] = [NSString stringWithFormat:@"[%@, #%@",
                                    src, [opnd substringFromIndex:pre.length]];
                        used = YES;
                    }
                }
            }
            if (!used) continue;
            NSString *outMnem = srcFP ? @"fmov" : cm;  // GP←FP reg move is fmov, never mov
            // dst must be dead after the consumer.
            BOOL dstWrittenByCons = mnemWritesReg0(cm) && [co[0] isEqualToString:dst];
            BOOL dead = dstWrittenByCons;
            if (!dead) {
                dead = YES;
                for (NSUInteger j = i + 2; j < lines.count; j++) {
                    NSString *t = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (t.length == 0) continue;
                    if ([t hasSuffix:@":"]) break;                 // block boundary: scratch dead-out
                    NSString *jm = nil; NSArray *jo = [self parseAsmLine:lines[j] mnem:&jm];
                    if (!jo) break;
                    if (!mnemWritesReg0(jm)) {                      // branch/ret/store/cmp
                        if ([@[@"b", @"bl", @"br", @"blr", @"ret", @"cbz", @"cbnz",
                               @"tbz", @"tbnz"] containsObject:jm]) break;   // dead-out
                        if (lineMentionsReg(lines[j], dst)) { dead = NO; break; }
                        continue;
                    }
                    if (lineMentionsReg(lines[j], dst)) {
                        // pure overwrite of dst (def, no read) → dead; else live.
                        BOOL readsToo = NO;
                        for (NSUInteger k = 1; k < jo.count; k++)
                            if (lineMentionsReg(jo[k], dst)) { readsToo = YES; break; }
                        if ([jo[0] isEqualToString:dst] && !readsToo) dead = YES;
                        else dead = NO;
                        break;
                    }
                }
            }
            if (!dead) continue;
            // Apply: rebuild the consumer, drop the move.
            NSString *lead = [lines[i + 1] substringToIndex:
                [lines[i + 1] rangeOfString:cm].location];   // preserve indentation
            lines[i + 1] = [NSString stringWithFormat:@"%@%@ %@", lead, outMnem,
                            [no componentsJoinedByString:@", "]];
            [lines removeObjectAtIndex:i];
            again = YES;
            break;
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

// ── Vector register allocation (linear-scan with reuse) ──────────────────
//
// Vector (NEON) values are loop-local: a reduction accumulator phi is reduced
// to a scalar at its loop exit, and the per-iteration body temps die each
// iteration. So disjoint vectorised loops can REUSE the same v-registers — a
// naive "assign sequentially, cap at 15" scheme exhausts and collides once a
// function has more than a handful of vectorised loops.
//
// Each vector phi result is coalesced with its incoming values onto ONE
// register: the reduction accumulator is associative and updated in place, so
// the back-edge needs no copy. Registers come from a pool DISJOINT from the FP
// allocator's home registers (d8-d15) and its d0-d7/d16-d17 scratch — v18..v31
// — so a function mixing float scalars and an int reduction can't alias. A
// vectorised loop body contains no calls (the recogniser forbids them), so
// these caller-saved registers are safe across the loop.
+ (void)allocateVectorRegistersForCtx:(XTArm64FnCtx *)ctx {
    XTIRFunction *fn = ctx.fn;
    // All vector-typed SSA values (phi results + vector-op results).
    NSMutableSet<NSNumber *> *vecVals = [NSMutableSet set];
    for (XTIRBlock *bb in fn.blocks) {
        for (XTIRInsn *p in bb.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec) [vecVals addObject:@(p.result.valueId)];
        for (XTIRInsn *i in bb.instructions)
            if (i.result && i.result.type.kind == XTIRTypeKindVec) [vecVals addObject:@(i.result.valueId)];
    }
    if (vecVals.count == 0) return;

    // Coalesce: each vector phi's incoming values share the phi result's class.
    NSMutableDictionary<NSNumber *, NSNumber *> *canon = [NSMutableDictionary dictionary];
    for (XTIRBlock *bb in fn.blocks)
        for (XTIRInsn *p in bb.phiNodes) {
            if (!p.result || p.result.type.kind != XTIRTypeKindVec) continue;
            for (XTIROperand *o in p.operands)
                if (o.kind == XTIROperandKindUse) canon[@(o.valueId)] = @(p.result.valueId);
        }
    XTIRValueId (^classOf)(XTIRValueId) = ^XTIRValueId(XTIRValueId v) {
        NSNumber *c = canon[@(v)];
        return c ? c.unsignedIntegerValue : v;
    };

    // Live interval per class = [min, max] over the linear positions where any
    // member is defined or used (block order: phis, instructions, terminator).
    NSMutableDictionary<NSNumber *, NSNumber *> *lo = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *hi = [NSMutableDictionary dictionary];
    void (^touch)(XTIRValueId, NSInteger) = ^(XTIRValueId v, NSInteger pos) {
        if (![vecVals containsObject:@(v)]) return;
        NSNumber *cls = @(classOf(v));
        if (!lo[cls] || pos < lo[cls].integerValue) lo[cls] = @(pos);
        if (!hi[cls] || pos > hi[cls].integerValue) hi[cls] = @(pos);
    };
    NSInteger pos = 0;
    NSMutableArray<NSNumber *> *blkPosStart = [NSMutableArray array];   // per-block first linear pos
    NSMutableArray<NSNumber *> *blkPosEnd = [NSMutableArray array];     // per-block last linear pos
    for (XTIRBlock *bb in fn.blocks) {
        [blkPosStart addObject:@(pos)];
        NSMutableArray<XTIRInsn *> *all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        for (XTIRInsn *insn in all) {
            if (insn.result) touch(insn.result.valueId, pos);
            for (XTIROperand *o in insn.operands)
                if (o.kind == XTIROperandKindUse) touch(o.valueId, pos);
            pos++;
        }
        [blkPosEnd addObject:@(pos > 0 ? pos - 1 : 0)];
    }

    // Back-edge-aware interval extension. The naive [min,max] scan above ends a
    // class's interval at its last textual use — but a loop-INVARIANT vector
    // value materialised ONCE before a loop (e.g. a preheader `dup`/VSplat of a
    // loop-invariant scalar) is read on every iteration and must stay live
    // across the back-edge. Without this its register is freed at its last
    // in-body use and reused by a later in-loop vector op (the redundant
    // `&0xFFFF` VAnd under the u16 map's ×4 unroll), corrupting the splat on the
    // next iteration. For each natural loop [header..latch] — a terminator edge
    // to an earlier/equal block in declaration order; this front end emits loop
    // bodies as contiguous block ranges — any class defined before the loop and
    // last-used inside it has its interval extended to the loop's end. This only
    // ever lengthens intervals (fewer reuses), so it cannot introduce a new
    // clobber; the coalesced phi accumulators already span header→latch.
    NSUInteger nblk = fn.blocks.count;
    for (NSUInteger bi = 0; bi < nblk; bi++) {
        XTIRInsn *t = fn.blocks[bi].terminator;
        if (!t) continue;
        for (XTIROperand *o in t.operands) {
            if (o.kind != XTIROperandKindBlock || !o.blockRef) continue;
            NSUInteger tgt = [fn.blocks indexOfObjectIdenticalTo:o.blockRef];
            if (tgt == NSNotFound || tgt > bi) continue;              // forward edge, not a loop
            NSInteger loopStart = blkPosStart[tgt].integerValue;
            NSInteger loopEnd = blkPosEnd[bi].integerValue;
            for (NSNumber *cls in lo.allKeys) {
                if (lo[cls].integerValue < loopStart &&               // defined before the loop
                    hi[cls].integerValue >= loopStart &&              // used within the loop...
                    hi[cls].integerValue <= loopEnd)                  // ...and not already live past it
                    hi[cls] = @(loopEnd);
            }
        }
    }

    // Linear-scan assignment with reuse.
    NSArray<NSNumber *> *classes = [lo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [lo[a] compare:lo[b]];
    }];
    NSMutableArray<NSNumber *> *freePool = [NSMutableArray array];
    for (int r = 18; r <= 31; r++) [freePool addObject:@(r)];
    NSMutableArray<NSNumber *> *active = [NSMutableArray array];   // class ids, by ascending end
    NSMutableDictionary<NSNumber *, NSNumber *> *regOfClass = [NSMutableDictionary dictionary];
    for (NSNumber *cls in classes) {
        NSInteger start = lo[cls].integerValue;
        // Expire classes whose interval ended before this one starts.
        NSMutableArray<NSNumber *> *stillActive = [NSMutableArray array];
        for (NSNumber *a in active) {
            if (hi[a].integerValue < start) [freePool addObject:regOfClass[a]];
            else [stillActive addObject:a];
        }
        [active setArray:stillActive];
        // Exhaustion is a HARD error: the old `@(31)` backstop silently reused
        // a live register, which is a miscompile, not degraded code (#1198 —
        // the x86-64/arm9 twins' 8-register pools actually overflowed).
        if (freePool.count == 0) {
            fprintf(stderr, "xcc-cg-arm64: error: vector register pressure exceeded "
                            "the 14-register pool (v18-v31) in '%s'\n",
                            fn.name.UTF8String);
            exit(1);
        }
        NSNumber *reg = freePool.lastObject;
        [freePool removeLastObject];
        regOfClass[cls] = reg;
        [active addObject:cls];
        [active sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [hi[a] compare:hi[b]]; }];
    }
    // Publish: every vector value maps to its class's register.
    for (NSNumber *v in vecVals)
        ctx.vecReg[v] = [NSString stringWithFormat:@"v%@", regOfClass[@(classOf(v.unsignedIntegerValue))]];
}

+ (void)emitFunction:(XTIRFunction *)fn module:(XTIRModule *)mod into:(NSMutableString *)out {
    XTArm64FnCtx *ctx = [[XTArm64FnCtx alloc] init];
    ctx.fn = fn;
    ctx.module = mod;
    ctx.vecReg = [NSMutableDictionary dictionary];
    ctx.vecNext = 0;
    [self allocateVectorRegistersForCtx:ctx];
    // Emit into a per-function buffer so the spill peephole can run over
    // this function's text in isolation (slot offsets are per-function),
    // then append the optimised text to the real module output.
    NSMutableString *moduleOut = out;
    NSMutableString *body = [NSMutableString string];
    out = body;          // every `out`/ctx.out append below targets the buffer
    ctx.out = body;
    // Folds are computed FIRST, before slots: slot colouring runs the live-
    // interval analysis, and that analysis extends a folded address op's base
    // and index to the Load/Store that re-materialises them (see noteUses). A
    // colouring built on unextended intervals would reuse a slot while a folded
    // address still had to read it — the same hazard the register allocator hit,
    // one level down. computeAddrFold reads no slot state, so this order is free.
    [self computeAddrFoldForCtx:ctx];         // sets ctx.foldedAddr + foldInfo + defOf
    [self buildSlotTableForCtx:ctx];          // sets ctx.slotOffsets + frameSize
    [self computeNoWrapForCtx:ctx];           // sets ctx.noCanon (needs defOf)
    [self allocateRegistersForCtx:ctx];       // liveness sees folds (run after)
    [self computeFusionsForCtx:ctx];          // sets ctx.fusedAway + fuseAt

    // Grow the frame to hold the callee-saved register save area, laid
    // out just past the value slots so value-slot offsets (and AddrOf
    // addresses) are unchanged. Functions that home nothing keep the
    // original byte-identical frame.
    // Reserve x28 as a high frame base when the frame outgrows sp-relative slot
    // addressing. base = ceil((frameSize - 16380) / 4096) * 4096 so that
    // [base, base+16380] covers the top of the frame and the setup stays a
    // single `add x28, sp, #N, lsl #12`. Added to savedRegs so the save area
    // sizes itself and every epilogue restores it like any other home.
    ctx.frameBase = 0;
    if (ctx.frameSize > 16380) {
        NSUInteger base = ((ctx.frameSize - 16380 + 4095) / 4096) * 4096;
        if ((base >> 12) <= 4095) {
            ctx.frameBase = base;
            NSMutableArray *sr = [ctx.savedRegs mutableCopy] ?: [NSMutableArray array];
            [sr addObject:@"x28"];
            ctx.savedRegs = sr;
        }
    }
    ctx.saveAreaOffset = ctx.valueSlotEnd;
    // Checked build: record the parameter map HERE, not at the end of
    // allocation. Two things are only final at this point. x28 joins
    // savedRegs just above when the frame outgrows sp-relative addressing, so
    // a map taken earlier described a save area one register short and the
    // trap reporter recovered the outer frames from the wrong offsets. And a
    // function containing inline asm returns early from allocation, which used
    // to skip the record entirely — a hole in the walk, not merely a frame
    // with poorer arguments, because every outer frame is reached through it.
    [self recordMSFnForCtx:ctx];
    if (ctx.savedRegs.count) {
        NSUInteger end = ctx.saveAreaOffset + 8 * ctx.savedRegs.count;
        ctx.frameSize = (end + 15) & ~(NSUInteger)15;
        if (ctx.frameSize < 16) ctx.frameSize = 16;
    }

    // Function label + prologue. Mach-O underscore convention so
    // a C stub linking against `add` finds `_add`.
    [out appendFormat:@".globl _%@\n", fn.name];
    [out appendFormat:@".align 2\n_%@:\n", fn.name];
    // Prologue. The pre-indexed `stp [sp, #-N]!` immediate caps at
    // 504 bytes; for larger frames adjust SP separately (sub allows
    // imm12 up to 4095, or a temp-register-built value beyond that).
    if (ctx.maxOutStack == 0) {
        if (ctx.frameSize <= 504) {
            [out appendFormat:@"    stp x29, x30, [sp, #-%lu]!\n", (unsigned long)ctx.frameSize];
        } else {
            [self emitSpAdjust:-(NSInteger)ctx.frameSize ctx:ctx];
            [out appendString:@"    stp x29, x30, [sp]\n"];
        }
        [out appendString:@"    mov x29, sp\n"];
    } else {
        // Reserve the outgoing-args area at [sp, #0 .. maxOutStack); x29/x30 above it.
        [self emitSpAdjust:-(NSInteger)ctx.frameSize ctx:ctx];
        if (ctx.maxOutStack <= 504) {
            [out appendFormat:@"    stp x29, x30, [sp, #%lu]\n", (unsigned long)ctx.maxOutStack];
        } else {
            [out appendFormat:@"    add x9, sp, #%lu\n", (unsigned long)ctx.maxOutStack];
            [out appendString:@"    stp x29, x30, [x9]\n"];
        }
        [out appendFormat:@"    add x29, sp, #%lu\n", (unsigned long)ctx.maxOutStack];
    }

    // Stow the incoming x8 sret pointer (a >16-byte non-HFA struct return) before
    // any arg-marshal or body code can clobber x8; each `return` writes through it.
    if (ctx.sretSaveOffset) {
        [out appendFormat:@"    str x8, %@\n",
         [self spMemForOff:ctx.sretSaveOffset reg:@"x8" ctx:ctx]];
    }

    // Save the callee-saved registers we home values in, BEFORE the param
    // spill (a param may be homed in one of these registers — overwriting
    // it before the save would lose the caller's value). They are reloaded
    // in every epilogue.
    [self emitCalleeSaves:ctx.savedRegs base:ctx.saveAreaOffset toBuf:out restore:NO];
    // x28 is saved above; point it at the high frame base now sp is final.
    // Everything emitted from here to the epilogue's restore may address slots
    // through it — expandStagedSlots keys off exactly this line.
    if (ctx.frameBase)
        [out appendFormat:@"    add x28, sp, #%lu, lsl #12\n",
         (unsigned long)(ctx.frameBase >> 12)];

    // Spill parameters into their stack slots. The last param is the
    // Mem phantom — it has a slot but no register, so skip it. AAPCS64:
    // integer/pointer params arrive in x0..x7 (gpIdx); float/double
    // params in the independent v0..v7 bank (fpIdx). Pointer-typed
    // params use the full 64-bit x view; integers w (canonicalised to
    // the IR type's range).
    NSUInteger paramCount = fn.paramTypes.count;
    NSUInteger userParams = (paramCount > 0 && [fn.paramTypes.lastObject kind] == XTIRTypeKindMemory)
        ? paramCount - 1 : paramCount;
    // Incoming stack params: the caller's outgoing-args area sits just above this
    // frame, so a param spilled to the stack lives at [sp, #frameSize + <off>].
    // Same classifier as the caller, so the offsets match exactly.
    NSArray *pTypes = [fn.paramTypes subarrayWithRange:NSMakeRange(0, userParams)];
    NSArray<NSNumber *> *pStk = [self arm64ArgStackOffsets:pTypes startGP:0 startFP:0 totalBytes:NULL];
    int gpIdx = 0, fpIdx = 0;
    for (NSUInteger i = 0; i < userParams; i++) {
        XTIRType *pty = fn.paramTypes[i];
        NSInteger soff = pStk[i].integerValue;
        if (XTIRTypeKindIsFloating(pty.kind)) {
            if (soff >= 0) {   // arrived on the stack (above a possibly-big frame)
                NSString *sc = [self fregName:16 forType:pty];
                NSUInteger po = ctx.frameSize + (NSUInteger)soff;
                [out appendFormat:@"    ldr %@, %@\n", sc,
                 [self spMemForOff:po reg:sc ctx:ctx]];
                [self storeReg:sc intoValue:(XTIRValueId)i ctx:ctx];
                continue;
            }
            if (fpIdx >= 8) continue;
            [self storeReg:[self fregName:fpIdx forType:pty]
                  intoValue:(XTIRValueId)i ctx:ctx];
            fpIdx++;
        } else if (pty.kind == XTIRTypeKindAgg) {
            // By-value aggregate param (AAPCS): an HFA arrives in consecutive
            // v-registers, any other aggregate in consecutive GP registers x{gpIdx}
            // (8 bytes each); spill each into the param's slot. Mirrors the caller's
            // marshalAggArg so a struct/HFA param round-trips intact.
            if (soff >= 0) {
                // Overflowed the register bank: the whole aggregate arrived on
                // the stack, in the caller's outgoing area just above this
                // frame. Copy it into the param's own slot (bug 20/21).
                NSUInteger sz = [self arm64AggSize:pty.layout];
                [self emitSpAddr:ctx.frameSize + (NSUInteger)soff into:@"x16" ctx:ctx];
                [self emitAggCopy:sz
                        frameSlot:[self slotOffsetForValue:(XTIRValueId)i ctx:ctx]
                          toFrame:YES ctx:ctx];
                continue;
            }
            XTIRTypeKind ek = XTIRTypeKindVoid;
            NSUInteger hfa = [self arm64AggHFA:pty.layout elemKind:&ek];
            if (hfa > 0) {
                if (fpIdx + hfa > 8) continue;   // stack-passed: unsupported (rare)
                NSUInteger esz = (ek == XTIRTypeKindF64) ? 8 : 4;
                NSString *pfx = (ek == XTIRTypeKindF64) ? @"d" : @"s";
                for (NSUInteger k = 0; k < hfa; k++)
                    [self storeReg:[NSString stringWithFormat:@"%@%d", pfx, fpIdx + (int)k]
                         intoValue:(XTIRValueId)i offset:esz * k ctx:ctx];
                fpIdx += (int)hfa;
            } else {
                NSUInteger nregs = [self gpRegsForAgg:pty];
                if (gpIdx + nregs > 8) continue;   // stack-passed: unsupported (rare)
                for (NSUInteger k = 0; k < nregs; k++) {
                    [self storeReg:[NSString stringWithFormat:@"x%d", gpIdx + (int)k]
                         intoValue:(XTIRValueId)i offset:8 * k ctx:ctx];
                }
                gpIdx += (int)nregs;
            }
        } else {
            BOOL needX = [self irTypeNeedsXReg:pty];
            if (soff >= 0) {   // arrived on the stack (above a possibly-big frame)
                NSString *sc = needX ? @"x9" : @"w9";
                NSUInteger po = ctx.frameSize + (NSUInteger)soff;
                [out appendFormat:@"    ldr %@, %@\n", sc,
                 [self spMemForOff:po reg:sc ctx:ctx]];
                if (!needX) [self canonicaliseReg:sc toType:pty ctx:ctx];
                [self storeReg:sc intoValue:(XTIRValueId)i ctx:ctx];
                continue;
            }
            if (gpIdx >= 8) continue;
            NSString *reg = [NSString stringWithFormat:@"%@%d", needX ? @"x" : @"w", gpIdx];
            if (!needX) {
                [self canonicaliseReg:reg toType:pty ctx:ctx];
            }
            [self storeReg:reg intoValue:(XTIRValueId)i ctx:ctx];
            gpIdx++;
        }
    }

    // Walk blocks in declaration order. Each block label, then phi
    // (no emission), then regular insns, then terminator.
    for (XTIRBlock *block in fn.blocks) {
        [out appendFormat:@"%@:\n", [self blockLabelForFn:fn block:block]];
        for (XTIRInsn *phi in block.phiNodes) {
            [self emitInsn:phi inBlock:block ctx:ctx];
        }
        for (XTIRInsn *insn in block.instructions) {
            [self emitInsn:insn inBlock:block ctx:ctx];
        }
        if (block.terminator) {
            [self emitInsn:block.terminator inBlock:block ctx:ctx];
        }
    }
    [out appendString:@"\n"];
    NSUInteger aliasLo = 0, aliasHi = NSUIntegerMax;
    [self aliasableRangeForCtx:ctx lo:&aliasLo hi:&aliasHi];
    [moduleOut appendString:
        [self expandStagedSlots:
            [self peepholeFallthrough:[self peepholeCopyProp:
             [self peepholeRedundantReloads:
              [self peepholeSpills:[self canonicaliseStagedSlots:body]
                                  aliasLo:aliasLo aliasHi:aliasHi
                                  argArea:ctx.maxOutStack]]]]
                       frameBase:ctx.frameBase
                    saveAreaFrom:ctx.saveAreaOffset
                              to:ctx.saveAreaOffset + 8 * ctx.savedRegs.count]];
}

#pragma mark - Public


static BOOL sArm64ThreadSafeARC = NO;        // what this module resolved to
static NSInteger sArm64ThreadSafeARCOverride = -1;   // -1 auto, 0 off, 1 on
static BOOL sArm64Aapcs64Abi = NO;   // Darwin's deviations unless told otherwise
static BOOL sArm64LseAtomics = YES;  // Apple Silicon is ARMv8.5; Android's floor is not

+ (void)setThreadSafeARCOverride:(NSInteger)mode { sArm64ThreadSafeARCOverride = mode; }
+ (void)setAapcs64Abi:(BOOL)on { sArm64Aapcs64Abi = on; }
+ (void)setLseAtomics:(BOOL)on { sArm64LseAtomics = on; }
+ (BOOL)threadSafeARC { return sArm64ThreadSafeARC; }

+ (NSString *)assemblyFromModule:(XTIRModule *)mod {
    // Resolve thread-safe ARC HERE rather than in xtcg's main, because the
    // backend has two callers: the xtcg-arm64 process and the corpus sweep,
    // which lowers and codegens in-process. A decision made in only one of them
    // is a decision the other silently gets wrong — and "wrong" here means a
    // threading fixture that races instead of failing to build.
    // A CHECKED build is detected from the module, not from a flag — for the
    // same reason thread-safe ARC is: the back end has two callers and a flag
    // plumbed to one is a decision the other gets wrong.
    sArm64MSFns = [mod referencesSymbolNamed:@"_xt_check_bounds"]
                ? [NSMutableArray array] : nil;

    sArm64ThreadSafeARC = sArm64ThreadSafeARCOverride >= 0
        ? (sArm64ThreadSafeARCOverride != 0)
        : [mod referencesSymbolNamed:@"_xt_thread_create"];

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"// Generated by XTArm64Backend — DO NOT EDIT\n"];
    [out appendString:@".text\n\n"];
    for (XTIRFunction *fn in mod.functions) {
        [self emitFunction:fn module:mod into:out];
    }
    // Module-level data. Uninit globals → `.lcomm _name, size, 1`
    // (Mach-O treats arg 3 as power-of-two alignment, 1 = 2 bytes).
    // Initialised globals → `.section __DATA,__data` + `.globl _name`
    // + `_name:` + `.byte` payload list.
    BOOL emittedUninitHeader = NO;
    BOOL emittedInitHeader = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindDataGlobal) continue;
        if (!sym.globalType) continue;
        // `extern` — this global is DEFINED IN ANOTHER MODULE. Reserve no storage;
        // the reference to its label is all we emit, and the linker resolves it.
        // Defining it here would give this module a SECOND COPY, whose writes would
        // never reach the defining module's — silently.
        if (sym.isExternalGlobal) continue;
        // Agg globals (e.g. struct globals, or __sdata once static
        // fields land) size in arm64-native widths (8-byte pointers),
        // not the shared 2-byte-pointer layout size.
        // Size the global slot with arm64-native widths, not the shared
        // XTIRLayout/Atari widths: a pointer is 8 bytes here (the backend
        // ldr/str a 64-bit host pointer), so a 2-byte .comm slot would let
        // an 8-byte store/load spill into the adjacent global — and an ARC
        // release's load-old then reads a garbage neighbour as a pointer.
        // arm64FieldWidth handles Agg (recursive), Ptr=8, F32=4, F64=8.
        uint32_t size = (uint32_t)[self arm64FieldWidth:sym.globalType];
        if (size == 0) size = 8;
        BOOL isFloat = XTIRTypeKindIsFloating(sym.globalType.kind);
        if (sym.initialBytes.length > 0) {
            if (!emittedInitHeader) {
                [out appendString:@"\n// Module data (initialised)\n"];
                [out appendString:@"    .section __DATA,__data\n"];
                emittedInitHeader = YES;
            }
            NSData *bytes = sym.initialBytes;
            if (sym.globalType.kind == XTIRTypeKindAgg && sym.globalType.layout) {
                // The image is laid out per the IR layout (Ptr 2, xtc floats);
                // arm64 uses Ptr 8 and IEEE. Re-lay it into our layout.
                bytes = [XTAggInitRelay relay:bytes
                                       layout:sym.globalType.layout
                                  widthOfLeaf:^NSUInteger(XTIRType *t) {
                                      return [XTArm64Backend arm64FieldWidth:t];
                                  }
                                    bigEndian:NO];
            }
            if (isFloat && bytes.length != size) {
                // Float globals carry the abstract value as 8 IEEE
                // double bits; arm64 uses native IEEE — emit single
                // (F32) or double (F64) bytes. Byte-list inits
                // (`float f = [b0,b1,b2,b3];`) already match the
                // target slot size — bypass the re-encode.
                double v = 0.0;
                uint64_t raw = 0;
                [bytes getBytes:&raw length:MIN((NSUInteger)8, bytes.length)];
                memcpy(&v, &raw, sizeof(v));
                if (sym.globalType.kind == XTIRTypeKindF64) {
                    NSMutableData *m = [NSMutableData dataWithBytes:&raw length:8];
                    bytes = m;
                } else {
                    float fv = (float)v;
                    uint32_t fb = 0;
                    memcpy(&fb, &fv, sizeof(fb));
                    bytes = [NSMutableData dataWithBytes:&fb length:4];
                }
            }
            // Natural alignment, capped at 8 (uxkit/029). Globals were emitted
            // with NO alignment directive at all, so a pointer-bearing one
            // landed wherever the previous global left the cursor. The
            // in-house linker tolerates that; Apple's ld does not —
            // "pointer not aligned in '__log_logger'+0x3FA50" — which made
            // every `-c` object unusable in a mixed clang link, the exact
            // interop surface `-c` exists for.
            [out appendFormat:@"    .p2align %u\n", xtArm64GlobalP2Align(size)];
            [out appendFormat:@"    .globl _%@\n", sym.name];
            [out appendFormat:@"_%@:\n", sym.name];
            const uint8_t *p = bytes.bytes;
            NSUInteger len = bytes.length;
            for (NSUInteger i = 0; i < len; i++) {
                [out appendFormat:@"    .byte 0x%02X\n", p[i]];
            }
            // Pad with zeros if the payload is short of the declared size.
            for (NSUInteger i = len; i < size; i++) {
                [out appendString:@"    .byte 0x00\n"];
            }
        } else {
            if (!emittedUninitHeader) {
                [out appendString:@"\n// Module data (zero-init)\n"];
                emittedUninitHeader = YES;
            }
            // `.comm` (not `.lcomm`) so the symbol is global —
            // xtc globals escape (visible across translation units
            // and to a linking C stub). Arg 3 is log2 alignment.
            // Mach-O `.comm` takes LOG2 alignment, so the old `1` meant two
            // bytes — not "none", and not enough for a pointer (uxkit/029).
            [out appendFormat:@"    .comm _%@, %u, %u\n", sym.name, (unsigned)size,
                              xtArm64GlobalP2Align(size)];
        }
    }
    // String literals: NUL-terminated bytes in __data. AddrOf of the
    // symbol (kind-agnostic Sym path) resolves to `_<name>`.
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindStringLit) continue;
        if (!emittedInitHeader) {
            [out appendString:@"\n// Module data (initialised)\n"];
            [out appendString:@"    .section __DATA,__data\n"];
            emittedInitHeader = YES;
        }
        // LOCAL, like x86-64's: a literal is module-private, and a global
        // `_str_N` collided with the next object's `_str_N` in a multi-object
        // link — the client's format string came out as the library's class
        // name (bug 136). The object writer now honours `.globl`, so a bare
        // label is an object-local symbol the linker tags per object.
        [out appendFormat:@"_%@:\n", sym.name];
        const uint8_t *p = sym.stringBytes.bytes;
        NSUInteger len = sym.stringBytes.length;
        if (len == 0) {
            [out appendString:@"    .byte 0x00\n"];
            continue;
        }
        for (NSUInteger i = 0; i < len; i++) {
            [out appendFormat:@"    .byte 0x%02X\n", p[i]];
        }
    }
    // VTables (task #58): one 8-byte method-function pointer per slot.
    // Emitted so the `<Class>$vtbl` symbol the `new` vtable-init
    // references resolves at link time. (arm64 virtual dispatch through
    // these is a follow-up — the 2-byte instance-layout vtable slot
    // can't hold a native 8-byte pointer; see the lowering note.)
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindVTable) continue;
        // `extern` — an imported class's vtable lives in its library; emit no local
        // copy (a second table at a different address would break RTTI identity, which
        // compares vtable addresses). The AddrOf reference resolves to the one table.
        if (sym.isExternalGlobal) continue;
        if (!emittedInitHeader) {
            [out appendString:@"\n// Module data (initialised)\n"];
            [out appendString:@"    .section __DATA,__data\n"];
            emittedInitHeader = YES;
        }
        [out appendFormat:@"    .globl _%@\n", sym.name];
        [out appendFormat:@"    .p2align 3\n_%@:\n", sym.name];
        NSArray<NSString *> *entries = sym.vtableEntryNames;
        if (entries.count == 0) {
            [out appendString:@"    .quad 0\n"];
            continue;
        }
        for (NSString *e in entries) {
            if (!e.length) { [out appendString:@"    .quad 0\n"]; continue; }
            // A conformance itable is (protoId, &table) pairs. The id is a VALUE (a
            // hash of the protocol name), emitted as a literal quad, not a label.
            if ([e hasPrefix:@"__protoid_"])
                [out appendFormat:@"    .quad %@\n", [e substringFromIndex:[@"__protoid_" length]]];
            else
                [out appendFormat:@"    .quad _%@\n", e];
        }
    }
    // Load-time constructors: a pointer to each in the Mach-O __mod_init_func
    // section, which dyld (and the XTOS loader's equivalent scan) runs before
    // main. Drives XG-NIB object-factory self-registration with no per-app code.
    if (mod.moduleInitFunctionNames.count > 0) {
        [out appendString:@"\n// Load-time constructors\n"];
        [out appendString:@"    .section __DATA,__mod_init_func,mod_init_funcs\n"];
        [out appendString:@"    .p2align 3\n"];
        for (NSString *initName in mod.moduleInitFunctionNames) {
            [out appendFormat:@"    .quad _%@\n", initName];
        }
    }
    // Checked build: the parameter map the trap reporter reads. One record per
    // function — code address, count, pointer to its parameter array — and two
    // words per parameter: frame offset from x29 (~0 when the allocator kept it
    // in a register and there is nothing to read) and (kind<<8)|width.
    // Emitted whenever this is a CHECKED module, even with zero records. The
    // runtime used to declare it weak and test it for null — but the address of
    // an array is never null, so the compiler folded the guard away and the
    // reporter dereferenced an unresolved symbol. Always defining it removes
    // the question: rt-checked.s and this table are linked together or not at
    // all.
    if (sArm64MSFns != nil) {
        [out appendString:@"\n// Checked-build parameter map (private:docs/Design/memory-safety.md)\n"];
        [out appendString:@"    .section __DATA,__data\n    .p2align 3\n"];
        for (NSUInteger i = 0; i < sArm64MSFns.count; i++) {
            NSDictionary *f = sArm64MSFns[i];
            [out appendFormat:@"___xt_ms_p_%lu:\n", (unsigned long)i];
            // SIGNED, because these fields carry a -1 sentinel for "no home"
            // and the runtime reads them signed. Printed unsigned the sentinel
            // came out as 18446744073709551615 — the same quad, but a different
            // string, and the port spells it -1. The end-of-list marker below
            // was always -1 in both, so one map had two spellings of one value.
            for (NSDictionary *pd in f[@"params"]) {
                [out appendFormat:@"    .quad %lld\n",
                    (long long)[pd[@"off"] longLongValue]];
                [out appendFormat:@"    .quad %lld\n",
                    (long long)[pd[@"kw"] longLongValue]];
                [out appendFormat:@"    .quad %lld\n",
                    (long long)[pd[@"reg"] longLongValue]];
            }
            [out appendFormat:@"___xt_ms_s_%lu:\n", (unsigned long)i];
            for (NSNumber *rn in f[@"saved"])
                [out appendFormat:@"    .quad %lld\n",
                    (long long)rn.longLongValue];
            [out appendString:@"    .quad -1\n"];      // end of the saved list
        }
        [out appendString:@"    .globl ___xt_ms_fns\n___xt_ms_fns:\n"];
        [out appendFormat:@"    .quad %lu\n", (unsigned long)sArm64MSFns.count];
        for (NSUInteger i = 0; i < sArm64MSFns.count; i++) {
            NSDictionary *f = sArm64MSFns[i];
            [out appendFormat:@"    .quad _%@\n", f[@"name"]];
            [out appendFormat:@"    .quad %lu\n",
                (unsigned long)[f[@"params"] count]];
            [out appendFormat:@"    .quad ___xt_ms_p_%lu\n", (unsigned long)i];
            [out appendFormat:@"    .quad %lu\n",
                (unsigned long)[f[@"saveBase"] unsignedLongValue]];
            [out appendFormat:@"    .quad ___xt_ms_s_%lu\n", (unsigned long)i];
        }
    }
    return out;
}

@end
