#import "XTIROptStaticInitGuard.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRSymbol.h"
#import "XTIRType.h"
#import "XTIROptTargetProfile.h"

// A recognised `if(!__sinit_X){…}` guard.
@interface XTSinitGuard : NSObject
@property(nonatomic) XTIRBlock* guard;       // block ending in the guard CondBranch
@property(nonatomic) XTIRBlock* run;         // the init block (CondBranch true target)
@property(nonatomic) XTIRBlock* cont;        // the straight-through block (false target)
@property(nonatomic, copy) NSString* sym;    // the __sinit_X symbol name
@property(nonatomic) XTIROperand* loadMemIn; // the flag-Load's incoming memory token
// Component instructions of the guard's check, for cloning to a preheader.
@property(nonatomic) XTIRInsn* addrOfInsn;           // AddrOf @__sinit_X
@property(nonatomic) XTIRInsn* loadInsn;             // Load of the flag
@property(nonatomic, nullable) XTIRInsn* const0Insn; // the Const 0 (if a separate insn)
@property(nonatomic) XTIRInsn* icmpInsn;             // ICmp <pred> flag, <done>
// The guard has TWO shapes. Single-threaded: `ICmp EQ flag, 0` with a run block
// that stores 1. Threaded (private:docs/Design/threading.md §9.5): `ICmp NE flag, 2`
// with a run block that calls `_xtc_sinit_run`, which sets the flag itself.
// Everything after recognition is common, so the difference is carried here
// rather than duplicated through the transform.
@property(nonatomic) XTIRICmpPredicate pred;
@end
@implementation XTSinitGuard
@end

@implementation XTIROptStaticInitGuard
    {
    // Memory tokens this pass has already bypassed, so a later fold whose
    // target was removed by an earlier one can follow the chain.
    NSMutableDictionary<NSNumber*, NSNumber*>* _memBypass;
    // class name -> may its init be relocated earlier? (bug 059)
    NSMutableDictionary<NSString*, NSNumber*>* _hoistable;
    }

- (NSString*)passName
    {
    return @"static-init-guard-elim";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.eliminatesRedundantInitGuards)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod];
    return YES;
    }

static NSArray<XTIRBlock*>* successors(XTIRBlock* b)
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    if (b.terminator)
        for (XTIROperand* op in b.terminator.operands)
            if (op.kind == XTIROperandKindBlock && op.blockRef)
                [out addObject:op.blockRef];
    return out;
    }

// Recognise the guard whose CondBranch terminates `G`:
//   %p   = AddrOf @__sinit_X
//   %v,_ = Load %p, <mem>
//   %z   = Const 0
//   %c   = ICmp EQ %v, %z
//   CondBranch %c, run, cont
// with `run` (init block) = {Store %p,1; …; Call X$init; Branch cont}.
- (nullable XTSinitGuard*)recognise:(XTIRBlock*)G
                                mod:(XTIRModule*)mod
                              defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
                              preds:(NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>*)preds
    {
    XTIRInsn* term = G.terminator;
    if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
        return nil;
    if (term.operands[0].kind != XTIROperandKindUse)
        return nil;
    if (term.operands[1].kind != XTIROperandKindBlock || term.operands[2].kind != XTIROperandKindBlock)
        return nil;
    XTIRInsn* icmp = defOf[@(term.operands[0].valueId)];
    if (!icmp || icmp.opcode != XTIROpICmp)
        return nil;
    // EQ pairs with 0 (not yet run) and NE with 2 (not yet DONE) — the two
    // shapes above. Any other combination is not a once-guard.
    long long wantConst;
    if (icmp.predicate == XTIRICmpEQ)
        wantConst = 0;
    else if (icmp.predicate == XTIRICmpNE)
        wantConst = 2;
    else
        return nil;
    if (icmp.operands.count < 2 || icmp.operands[0].kind != XTIROperandKindUse)
        return nil;
    XTIROperand* rhs = icmp.operands[1];
    if (rhs.kind == XTIROperandKindImmI)
        {
        if (rhs.intValue != wantConst)
            return nil;
        }
    else if (rhs.kind == XTIROperandKindUse)
        {
        XTIRInsn* cdef = defOf[@(rhs.valueId)];
        if (!cdef || cdef.opcode != XTIROpConst || cdef.operands.count < 1 || cdef.operands[0].kind != XTIROperandKindImmI || cdef.operands[0].intValue != wantConst)
            return nil;
        }
    else
        return nil;

    XTIRInsn* load = defOf[@(icmp.operands[0].valueId)];
    if (!load || load.opcode != XTIROpLoad || load.operands.count < 1 || load.operands[0].kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* addr = defOf[@(load.operands[0].valueId)];
    if (!addr || addr.opcode != XTIROpAddrOf || addr.operands.count < 1 || addr.operands[0].kind != XTIROperandKindSym)
        return nil;
    XTIRSymbol* sym = [mod symbolForId:addr.operands[0].symbolId];
    if (!sym || ![sym.name hasPrefix:@"__sinit"])
        return nil;

    XTIRBlock* run = term.operands[1].blockRef; // EQ true (flag==0) → init
    XTIRBlock* cont = term.operands[2].blockRef;
    if (!run || !cont || run == cont)
        return nil;
    // A phi in cont could have an incoming from the init block; folding it
    // away would leave that phi operand dangling. The lowering's guard-cont
    // has none (the init path defines nothing used after), but bail to be safe.
    if (cont.phiNodes.count != 0)
        return nil;
    // run must be guarded solely by G, store the same flag, and fall to cont.
    NSSet* rp = [preds objectForKey:run];
    if (rp.count != 1 || ![rp containsObject:G])
        return nil;
    if (!run.terminator || run.terminator.opcode != XTIROpBranch || successors(run).count != 1 || successors(run)[0] != cont)
        return nil;
    // Prove the run block really does advance THIS flag, or folding a dominated
    // duplicate would be unsound. Single-threaded that is a Store of 1;
    // threaded, the store happens inside `_xtc_sinit_run`, so the proof is a
    // call to it whose first argument is this flag.
    BOOL advancesFlag = NO;
    for (XTIRInsn* insn in run.instructions)
        {
        XTIROperand* flagArg = nil;
        if (insn.opcode == XTIROpStore && insn.operands.count >= 1)
            {
            flagArg = insn.operands[0];
            }
        else if (insn.opcode == XTIROpCall && insn.operands.count >= 2)
            {
            XTIRSymbol* callee = [mod symbolForId:insn.operands[0].symbolId];
            if (callee && [callee.name isEqualToString:@"_xtc_sinit_run"])
                flagArg = insn.operands[1];
            }
        if (!flagArg || flagArg.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* sa = defOf[@(flagArg.valueId)];
        if (sa && sa.opcode == XTIROpAddrOf && sa.operands.count >= 1 && sa.operands[0].kind == XTIROperandKindSym)
            {
            XTIRSymbol* ss = [mod symbolForId:sa.operands[0].symbolId];
            if (ss && [ss.name isEqualToString:sym.name])
                {
                advancesFlag = YES;
                break;
                }
            }
        }
    if (!advancesFlag)
        return nil;

    XTSinitGuard* g = [XTSinitGuard new];
    g.guard = G;
    g.run = run;
    g.cont = cont;
    g.sym = sym.name;
    g.loadMemIn = (load.operands.count >= 2) ? load.operands[1] : nil;
    g.addrOfInsn = addr;
    g.loadInsn = load;
    g.icmpInsn = icmp;
    g.pred = icmp.predicate;
    g.const0Insn = (rhs.kind == XTIROperandKindUse) ? defOf[@(rhs.valueId)] : nil;
    return g;
    }

// Iterative dominators over the function CFG (entry = first block).
- (NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>*)
    dominatorsOf:(XTIRFunction*)fn
           preds:(NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>*)preds
    {
    NSMutableSet<XTIRBlock*>* all = [NSMutableSet setWithArray:fn.blocks];
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* dom =
        [NSMapTable strongToStrongObjectsMapTable];
    XTIRBlock* entry = fn.blocks.firstObject;
    for (XTIRBlock* b in fn.blocks)
        [dom setObject:(b == entry ? [NSMutableSet setWithObject:entry] : [all mutableCopy])
                forKey:b];
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (XTIRBlock* b in fn.blocks)
            {
            if (b == entry)
                continue;
            NSSet* bp = [preds objectForKey:b];
            NSMutableSet<XTIRBlock*>* nd = nil;
            for (XTIRBlock* p in bp)
                {
                NSMutableSet* dp = [dom objectForKey:p];
                if (!nd)
                    nd = [dp mutableCopy];
                else
                    [nd intersectSet:dp];
                }
            if (!nd)
                nd = [NSMutableSet set];
            [nd addObject:b];
            if (![nd isEqualToSet:[dom objectForKey:b]])
                {
                [dom setObject:nd forKey:b];
                changed = YES;
                }
            }
        }
    return dom;
    }

// Build defOf + preds + the recognised guards for the current CFG.
- (NSArray<XTSinitGuard*>*)recogniseAllIn:(XTIRFunction*)fn module:(XTIRModule*)mod
                                    preds:(NSMapTable**)outPreds
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;
        }
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* preds =
        [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRBlock* s in successors(bb))
            {
            NSMutableSet* set = [preds objectForKey:s];
            if (!set)
                {
                set = [NSMutableSet set];
                [preds setObject:set forKey:s];
                }
            [set addObject:bb];
            }
    NSMutableArray<XTSinitGuard*>* guards = [NSMutableArray array];
    for (XTIRBlock* G in fn.blocks)
        {
        XTSinitGuard* g = [self recognise:G mod:mod defOf:defOf preds:preds];
        if (g)
            [guards addObject:g];
        }
    if (outPreds)
        *outPreds = preds;
    return guards;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (fn.blocks.count < 2)
        return;
    _memBypass = [NSMutableDictionary dictionary];
    if (!_hoistable)
        _hoistable = [NSMutableDictionary dictionary];
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];

    NSMapTable* preds = nil;
    NSArray<XTSinitGuard*>* guards = [self recogniseAllIn:fn module:mod preds:&preds];
    if (guards.count < 1)
        return;

    // Hoist each class's guard to the function entry: it then dominates every
    // in-body guard for that class, which the fold below removes — running
    // the guard once per call and single-blocking loop bodies.
    if (prof.hoistsInitGuardsToEntry)
        {
        [self hoistGuardsToEntry:fn guards:guards module:mod];
        guards = [self recogniseAllIn:fn module:mod preds:&preds];
        }
    if (guards.count < 2)
        return;

    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* dom =
        [self dominatorsOf:fn
                     preds:preds];

    // A guard is redundant if another guard for the SAME class has its
    // straight-through (cont) block dominating this guard's block — the flag
    // is then provably set on every path here.
    NSMutableArray<XTSinitGuard*>* redundant = [NSMutableArray array];
    for (XTSinitGuard* g2 in guards)
        {
        for (XTSinitGuard* g1 in guards)
            {
            if (g1 == g2 || ![g1.sym isEqualToString:g2.sym])
                continue;
            if ([[dom objectForKey:g2.guard] containsObject:g1.cont])
                {
                [redundant addObject:g2];
                break;
                }
            }
        }
    for (XTSinitGuard* g in redundant)
        [self fold:g inFunction:fn];

    // Folding leaves the former guard body as a straight-line chain joined by
    // unconditional branches (guard → cont → …). Coalesce those so the loop
    // body is a single block again — which is what lets the unroller reach it.
    if (redundant.count)
        [self coalesceStraightLineIn:fn];
    }

// Merge `A -Branch-> B` when B's sole predecessor is A (and B isn't the
// entry / has no phis): append B's instructions to A, take B's terminator,
// repoint B's successors' phi edges to A, and drop B. Fixpoint.
- (void)coalesceStraightLineIn:(XTIRFunction*)fn
    {
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        XTIRBlock* entry = fn.blocks.firstObject;
        // predecessors for this iteration
        NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* preds =
            [NSMapTable strongToStrongObjectsMapTable];
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRBlock* s in successors(bb))
                {
                NSMutableSet* set = [preds objectForKey:s];
                if (!set)
                    {
                    set = [NSMutableSet set];
                    [preds setObject:set forKey:s];
                    }
                [set addObject:bb];
                }
        for (XTIRBlock* A in fn.blocks)
            {
            XTIRInsn* t = A.terminator;
            if (!t || t.opcode != XTIROpBranch || t.operands.count < 1 || t.operands[0].kind != XTIROperandKindBlock)
                continue;
            XTIRBlock* B = t.operands[0].blockRef;
            if (!B || B == A || B == entry || B.phiNodes.count != 0)
                continue;
            NSSet* bp = [preds objectForKey:B];
            if (bp.count != 1 || ![bp containsObject:A])
                continue;

            [A.instructions addObjectsFromArray:B.instructions];
            XTIRInsn* bterm = B.terminator;
            [A resetTerminator];
            [A setTerminator:bterm];
            // B's successors' phis referenced B as a predecessor → now A.
            for (XTIRBlock* S in successors(A))
                for (NSUInteger i = 0; i < S.phiNodes.count; i++)
                    {
                    XTIRInsn* phi = S.phiNodes[i];
                    NSMutableArray<XTIROperand*>* ops = nil;
                    for (NSUInteger k = 0; k < phi.operands.count; k++)
                        {
                        XTIROperand* op = phi.operands[k];
                        if (op.kind == XTIROperandKindBlock && op.blockRef == B)
                            {
                            if (!ops)
                                ops = [phi.operands mutableCopy];
                            ops[k] = [XTIROperand blockWithRef:A];
                            }
                        }
                    if (ops)
                        {
                        XTIRInsn* np = [[XTIRInsn alloc] initWithOpcode:phi.opcode
                                                                 result:phi.result
                                                               operands:ops
                                                                 dbgLoc:phi.dbgLoc];
                        np.memoryResult = phi.memoryResult;
                        S.phiNodes[i] = np;
                        }
                    }
            [fn.blocks removeObject:B];
            changed = YES;
            break;
            }
        }
    }

// Build a fresh SSA value of `type` defined in `blk`, registered on `fn`.
static XTIRValue* freshVal(XTIRFunction* fn, XTIRType* type, XTIRBlock* blk)
    {
    XTIRValueId vid = [fn allocateValueId];
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                 type:type
                                              defSite:[[XTIRDefSite alloc] initWithBlock:blk insnIndex:0]];
    [fn registerValue:v];
    return v;
    }

// Hoist one guard per class to the function entry, chained ahead of the old
// entry block:  chk_0 → (run_0) → mrg_0 → chk_1 → … → oldEntry. Each chk/run
// is built from a representative in-body guard for that class; the in-body
// guards are then dominated and removed by the fold pass. Eager init at
// entry rather than first use — sound for an idempotent class init the
// function unconditionally reaches (validated by the differential sweep).

// ── Is it safe to run this class's `init` EARLIER than its first use? ──────
//
// Hoisting a guard to the function entry is what makes the fold below possible,
// but it relocates the initialiser: it then runs on entry rather than at first
// use. Any `init` that can OBSERVE program state set up in between reads the
// earlier value — silently, and only at -O2. See private:docs/bugs/059.
//
// So the hoist is now conditional on the initialiser being blind to everything
// except its own class's static block. The test is deliberately crude and
// conservative, because a wrong YES is a wrong answer in the compiled program:
//
//   * any Call at all            -> NO (the callee could read anything)
//   * any symbol reference that
//     is not this class's own
//     static data                -> NO
//
// Stdio/Assert-style initialisers — set my own statics from constants — pass,
// which is the case the optimisation was built for. An init that reads a global
// does not, which is exactly bug 059's repro.
- (BOOL)initIsHoistableFor:(NSString*)flagSym module:(XTIRModule*)mod
    {
    // __sinit_<Class> -> <Class>
    if (![flagSym hasPrefix:@"__sinit_"])
        return NO;
    NSString* cls = [flagSym substringFromIndex:8];
    NSNumber* cached = _hoistable[cls];
    if (cached)
        return cached.boolValue;

    NSString* initName = [NSString stringWithFormat:@"%@$init", cls];
    NSString* ownData = [NSString stringWithFormat:@"__sdata_%@", cls];
    NSString* ownIvar = [NSString stringWithFormat:@"__sivar_%@_", cls];
    XTIRFunction* initFn = nil;
    for (XTIRFunction* f in mod.functions)
        if ([f.name isEqualToString:initName])
            {
            initFn = f;
            break;
            }

    BOOL ok = (initFn != nil); // no body visible -> assume the worst
    if (initFn)
        {
        for (XTIRBlock* b in initFn.blocks)
            {
            for (XTIRInsn* insn in b.instructions)
                {
                if (insn.opcode == XTIROpCall)
                    {
                    ok = NO;
                    break;
                    }
                for (XTIROperand* op in insn.operands)
                    {
                    if (op.kind != XTIROperandKindSym)
                        continue;
                    XTIRSymbol* sy = [mod symbolForId:op.symbolId];
                    if (!sy)
                        {
                        ok = NO;
                        break;
                        }
                    if ([sy.name isEqualToString:ownData])
                        continue;
                    if ([sy.name hasPrefix:ownIvar])
                        continue;
                    ok = NO;
                    break;
                    }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        }
    _hoistable[cls] = @(ok);
    return ok;
    }

// ── Can the init block be cloned to the function entry? ──────────────────────
//
// The clone runs ahead of every block the function had, so it may use only what
// it defines itself, the flag pointer and memory token the check block rebuilds,
// and the function's parameters. The cross-block CSE that runs earlier can leave
// the init block reading a value defined in the guard block: an
// `AddrOf @__sdata_X` shared with code after the guard. An address or a constant
// is rebuilt in the clone; anything else defined outside the block cannot be,
// and that guard is not hoisted. Cloned verbatim, the use read a register
// nothing had set yet, and the init wrote through it the first time the flag
// was clear on entry: a library's `Number.with` called from a client, whose
// own guard sets the client's flag and not the library's
// (private:docs/bugs/270).
static BOOL isRematerialisable(XTIRInsn* def)
    {
    if (def.opcode != XTIROpAddrOf && def.opcode != XTIROpConst)
        return NO;
    if (!def.result || def.memoryResult)
        return NO;
    for (XTIROperand* op in def.operands)
        if (op.kind == XTIROperandKindUse)
            return NO;
    return YES;
    }

static BOOL runIsCloneable(XTSinitGuard* g, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    NSMutableSet<NSNumber*>* defined = [NSMutableSet set];
    [defined addObject:@(g.addrOfInsn.result.valueId)];
    if (g.loadInsn.memoryResult)
        [defined addObject:@(g.loadInsn.memoryResult.valueId)];
    for (XTIRInsn* insn in g.run.instructions)
        {
        for (XTIROperand* op in insn.operands)
            {
            if (op.kind != XTIROperandKindUse || [defined containsObject:@(op.valueId)])
                continue;
            XTIRInsn* def = defOf[@(op.valueId)];
            // No def: a parameter, which dominates the clone.
            if (def && !isRematerialisable(def))
                return NO;
            }
        if (insn.result)
            [defined addObject:@(insn.result.valueId)];
        if (insn.memoryResult)
            [defined addObject:@(insn.memoryResult.valueId)];
        }
    return YES;
    }

- (void)hoistGuardsToEntry:(XTIRFunction*)fn guards:(NSArray<XTSinitGuard*>*)guards
                    module:(XTIRModule*)mod
    {
    if (guards.count == 0 || fn.blocks.count == 0)
        return;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* i in bb.instructions)
            {
            if (i.result)
                defOf[@(i.result.valueId)] = i;
            if (i.memoryResult)
                defOf[@(i.memoryResult.valueId)] = i;
            }
        }
    XTIRType* memTy = [XTIRType memoryType];
    // The function's memory token is its last parameter; reference it as the
    // entry guard's incoming memory (it dominates everything).
    NSUInteger pc = fn.paramTypes.count;
    if (pc == 0)
        return;
    XTIROperand* entryMem = [XTIROperand useWithValueId:(XTIRValueId)(pc - 1)];
    XTIRBlock* oldEntry = fn.blocks.firstObject;

    // One representative guard per class, in first-seen order.
    NSMutableArray<XTSinitGuard*>* reps = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    for (XTSinitGuard* g in guards)
        {
        if ([seen containsObject:g.sym])
            continue;
        // bug 059: only relocate an initialiser that cannot tell it moved.
        if (![self initIsHoistableFor:g.sym module:mod])
            continue;
        if (!runIsCloneable(g, defOf))
            continue;
        [seen addObject:g.sym];
        [reps addObject:g];
        }
    if (reps.count == 0)
        return;

    NSMutableArray<XTIRBlock*>* newBlocks = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* checks = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* merges = [NSMutableArray array];

    for (XTSinitGuard* g in reps)
        {
        XTIRBlock* C = [[XTIRBlock alloc] init];
        C.name = [NSString stringWithFormat:@"%@_hoist_chk", g.sym];
        XTIRBlock* R = [[XTIRBlock alloc] init];
        R.name = [NSString stringWithFormat:@"%@_hoist_run", g.sym];
        XTIRBlock* M = [[XTIRBlock alloc] init];
        M.name = [NSString stringWithFormat:@"%@_hoist_mrg", g.sym];

        // --- check block: AddrOf flag; Load; (Const 0); ICmp EQ; CondBranch
        XTIRValue* a = freshVal(fn, g.addrOfInsn.result.type, C);
        [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                       result:a
                                                     operands:g.addrOfInsn.operands
                                                       dbgLoc:nil]];
        XTIRValue* v = freshVal(fn, g.loadInsn.result.type, C);
        XTIRValue* m1 = freshVal(fn, memTy, C);
        XTIRInsn* load = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                                   result:v
                                                 operands:@[ [XTIROperand useWithValueId:a.valueId], entryMem ]
                                                   dbgLoc:nil];
        load.memoryResult = m1;
        [C appendInstruction:load];
        XTIROperand* rhs;
        if (g.const0Insn)
            {
            XTIRValue* z = freshVal(fn, g.const0Insn.result.type, C);
            [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                           result:z
                                                         operands:g.const0Insn.operands
                                                           dbgLoc:nil]];
            rhs = [XTIROperand useWithValueId:z.valueId];
            }
        else
            {
            rhs = g.icmpInsn.operands[1]; // immediate 0, copied verbatim
            }
        XTIRValue* c = freshVal(fn, g.icmpInsn.result.type, C);
        [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                       result:c
                                                     operands:@[ [XTIROperand useWithValueId:v.valueId], rhs ]
                                                    predicate:g.pred
                                                       dbgLoc:nil]];
        [C setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand useWithValueId:c.valueId],
                                                             [XTIROperand blockWithRef:R],
                                                             [XTIROperand blockWithRef:M] ]
                                                   dbgLoc:nil]];

        // --- run block: clone the representative's init block, threading its
        // incoming memory (the in-body flag-Load's mem result) from m1.
        NSMutableDictionary<NSNumber*, NSNumber*>* map = [NSMutableDictionary dictionary];
        // The init block's Store targets the flag pointer (the guard block's
        // AddrOf @__sinit_X) and threads the guard Load's memory — both are
        // defined in the original guard block, so remap them to the clones we
        // just built in this check block.
        map[@(g.addrOfInsn.result.valueId)] = @(a.valueId);
        if (g.loadInsn.memoryResult)
            map[@(g.loadInsn.memoryResult.valueId)] = @(m1.valueId);
        for (XTIRInsn* insn in g.run.instructions)
            {
            // A value from outside the block is rebuilt here, ahead of its
            // first use (runIsCloneable admitted only those that can be).
            for (XTIROperand* op in insn.operands)
                {
                if (op.kind != XTIROperandKindUse || map[@(op.valueId)])
                    continue;
                XTIRInsn* def = defOf[@(op.valueId)];
                if (!def)
                    continue;
                XTIRValue* rv = freshVal(fn, def.result.type, R);
                [R appendInstruction:[[XTIRInsn alloc] initWithOpcode:def.opcode
                                                               result:rv
                                                             operands:def.operands
                                                               dbgLoc:nil]];
                map[@(op.valueId)] = @(rv.valueId);
                }
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
            for (XTIROperand* op in insn.operands)
                {
                if (op.kind == XTIROperandKindUse && map[@(op.valueId)])
                    [ops addObject:[XTIROperand useWithValueId:
                                                    (XTIRValueId)map[@(op.valueId)].unsignedLongLongValue]];
                else
                    [ops addObject:op];
                }
            XTIRValue* nr = insn.result ? freshVal(fn, insn.result.type, R) : nil;
            XTIRValue* nm = insn.memoryResult ? freshVal(fn, memTy, R) : nil;
            XTIRInsn* cl;
            if (insn.callConv)
                cl = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                               result:nr
                                             operands:ops
                                             callConv:insn.callConv
                                               dbgLoc:insn.dbgLoc];
            else
                cl = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                               result:nr
                                             operands:ops
                                               dbgLoc:insn.dbgLoc];
            cl.memoryResult = nm;
            [R appendInstruction:cl];
            if (insn.result)
                map[@(insn.result.valueId)] = @(nr.valueId);
            if (insn.memoryResult)
                map[@(insn.memoryResult.valueId)] = @(nm.valueId);
            }
        [R setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand blockWithRef:M] ]
                                                   dbgLoc:nil]];

        [newBlocks addObject:C];
        [newBlocks addObject:R];
        [newBlocks addObject:M];
        [checks addObject:C];
        [merges addObject:M];
        }

    // Chain: mrg_i → chk_{i+1}; last mrg → oldEntry.
    for (NSUInteger i = 0; i < merges.count; i++)
        {
        XTIRBlock* target = (i + 1 < checks.count) ? checks[i + 1] : oldEntry;
        [merges[i] setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                           result:nil
                                                         operands:@[ [XTIROperand blockWithRef:target] ]
                                                           dbgLoc:nil]];
        }
    // Splice the new blocks in at the front (chk_0 becomes the entry).
    NSIndexSet* is = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newBlocks.count)];
    [fn.blocks insertObjects:newBlocks atIndexes:is];
    }

// Fold a redundant guard: bypass the check, drop the dead init block, and
// rewire any use of the init block's memory tokens to the guard's incoming
// memory (the backend treats the token as advisory; this keeps the IR's
// memory chain well-formed). Then dead-strip the guard tail in the block.
- (void)fold:(XTSinitGuard*)g inFunction:(XTIRFunction*)fn
    {
    if (![fn.blocks containsObject:g.guard] || ![fn.blocks containsObject:g.run])
        return;

    // Memory tokens defined by the init block → rewrite to the guard's
    // incoming memory token.
    NSMutableSet<NSNumber*>* runMem = [NSMutableSet set];
    for (XTIRInsn* insn in g.run.instructions)
        if (insn.memoryResult)
            [runMem addObject:@(insn.memoryResult.valueId)];
    if (runMem.count && g.loadMemIn && g.loadMemIn.kind == XTIROperandKindUse)
        {
        // The target may itself have been removed by an EARLIER fold — two
        // guards for the same class chain, and the second one's incoming
        // memory was defined in the first one's init block. Follow the chain
        // to a token that still exists, or the text ends up naming a value
        // nothing defines (`%?N`), which a second implementation cannot
        // reproduce because the number is an allocation id.
        XTIRValueId target = g.loadMemIn.valueId;
        for (int hop = 0; hop < 64; hop++)
            {
            NSNumber* next = _memBypass[@(target)];
            if (!next)
                break;
            target = (XTIRValueId)next.unsignedLongLongValue;
            }
        for (NSNumber* dead in runMem)
            _memBypass[dead] = @(target);
        [self replaceUsesIn:fn ofAny:runMem with:target];
        }

    // Bypass: guard block branches straight to cont.
    [g.guard resetTerminator];
    [g.guard setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                     result:nil
                                                   operands:@[ [XTIROperand blockWithRef:g.cont] ]
                                                     dbgLoc:nil]];

    // The init block is now unreachable.
    [fn.blocks removeObject:g.run];

    // Guard-check tail (AddrOf/Load/ICmp/Const) is now unused — left for
    // the pipeline's global XTIROptDeadCode pass, which is sound. (The old
    // local deadStripBlock had an unsound use-scan that nulled a live const.)
    }

// Replace, across the function, every Use of an id in `ids` with `newId`.
- (void)replaceUsesIn:(XTIRFunction*)fn
                ofAny:(NSSet<NSNumber*>*)ids
                 with:(XTIRValueId)newId
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        [self replaceInList:bb.phiNodes ofAny:ids with:newId];
        [self replaceInList:bb.instructions ofAny:ids with:newId];
        XTIRInsn* t = bb.terminator;
        if (t)
            {
            XTIRInsn* nt = [self rebuild:t ofAny:ids with:newId];
            if (nt)
                {
                [bb resetTerminator];
                [bb setTerminator:nt];
                }
            }
        }
    }

- (void)replaceInList:(NSMutableArray<XTIRInsn*>*)list
                ofAny:(NSSet<NSNumber*>*)ids
                 with:(XTIRValueId)newId
    {
    for (NSUInteger i = 0; i < list.count; i++)
        {
        XTIRInsn* nt = [self rebuild:list[i] ofAny:ids with:newId];
        if (nt)
            list[i] = nt;
        }
    }

- (nullable XTIRInsn*)rebuild:(XTIRInsn*)insn
                        ofAny:(NSSet<NSNumber*>*)ids
                         with:(XTIRValueId)newId
    {
    NSMutableArray<XTIROperand*>* out = nil;
    for (NSUInteger i = 0; i < insn.operands.count; i++)
        {
        XTIROperand* op = insn.operands[i];
        if (op.kind == XTIROperandKindUse && [ids containsObject:@(op.valueId)])
            {
            if (!out)
                out = [insn.operands mutableCopy];
            out[i] = [XTIROperand useWithValueId:newId];
            }
        }
    if (!out)
        return nil;
    XTIRInsn* r;
    if (insn.callConv)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                    callConv:insn.callConv
                                      dbgLoc:insn.dbgLoc];
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
    else
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                      dbgLoc:insn.dbgLoc];
    r.memoryResult = insn.memoryResult;
    return r;
    }

// Remove, from `blk` only, pure/side-effect-free instructions whose results
// are unused anywhere in the function — peels the now-dead guard tail
// (AddrOf / Load / ICmp / Const) without touching other blocks.
- (void)deadStripBlock:(XTIRBlock*)blk inFunction:(XTIRFunction*)fn
    {
    BOOL removed = YES;
    while (removed)
        {
        removed = NO;
        NSMutableSet<NSNumber*>* used = [NSMutableSet set];
        void (^count)(NSArray<XTIROperand*>*) = ^(NSArray<XTIROperand*>* ops) {
          for (XTIROperand* op in ops)
              if (op.kind == XTIROperandKindUse)
                  [used addObject:@(op.valueId)];
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                count(p.operands);
            for (XTIRInsn* i in bb.instructions)
                count(i.operands);
            if (bb.terminator)
                count(bb.terminator.operands);
            }
        for (NSInteger i = (NSInteger)blk.instructions.count - 1; i >= 0; i--)
            {
            XTIRInsn* insn = blk.instructions[i];
            BOOL pure = NO;
            switch (insn.opcode)
                {
            case XTIROpAddrOf:
            case XTIROpLoad:
            case XTIROpICmp:
            case XTIROpConst:
            case XTIROpZExt:
            case XTIROpSExt:
            case XTIROpTrunc:
                pure = YES;
                break;
            default:
                break;
                }
            if (!pure)
                continue;
            BOOL resUsed = insn.result && [used containsObject:@(insn.result.valueId)];
            BOOL memUsed = insn.memoryResult && [used containsObject:@(insn.memoryResult.valueId)];
            if (!resUsed && !memUsed)
                {
                [blk.instructions removeObjectAtIndex:(NSUInteger)i];
                removed = YES;
                }
            }
        }
    }

@end
