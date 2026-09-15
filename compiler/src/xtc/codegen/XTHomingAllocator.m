#import "XTHomingAllocator.h"
#import "XTIR.h"

@interface XTHomingResult ()
@property(nonatomic, readwrite) NSDictionary<NSNumber*, NSString*>* homeReg;
@property(nonatomic, readwrite) NSArray<NSString*>* usedCalleeSaved;
@end

@implementation XTHomingResult
@end

@implementation XTHomingAllocator

// Values that are read as an operand somewhere (used for the never-read
// exclusion and the priority sort).
+ (BOOL)isFloatType:(XTIRType*)t
    {
    return t && (t.kind == XTIRTypeKindF32 || t.kind == XTIRTypeKindF64);
    }

// Opcodes that emit a runtime `bl`/`jsr` (clobbering caller-saved registers) —
// the direct calls PLUS the hidden ones some backends lower to a call (bulk
// memory ops, ARC/weak helpers). A value whose range spans any of these can't
// live in a caller-saved register; treating them all as calls is conservative
// (a backend that inlines memcpy just gets a value nudged to callee-saved).
+ (BOOL)isCallOpcode:(XTIROpcode)op
    {
    return op == XTIROpCall || op == XTIROpCallBanked || op == XTIROpCallCloaked || op == XTIROpCallIndirect || op == XTIROpCallBankedIndirect || op == XTIROpVTblDispatch || op == XTIROpMemCopy || op == XTIROpMemSet || op == XTIROpRelease || op == XTIROpAutorelease || op == XTIROpWeakRegister || op == XTIROpWeakUnregister || op == XTIROpWeakLoad;
    }

+ (XTHomingResult*)assignHomesForFunction:(XTIRFunction*)fn
                                 gpCallee:(NSArray<NSString*>*)gpCallee
                                 gpCaller:(NSArray<NSString*>*)gpCaller
                                 fpCallee:(NSArray<NSString*>*)fpCallee
                                 fpCaller:(NSArray<NSString*>*)fpCaller
                                 excluded:(NSSet<NSNumber*>*)excludedIn
    {
    return [self assignHomesForFunction:fn
                               gpCallee:gpCallee
                               gpCaller:gpCaller
                               fpCallee:fpCallee
                               fpCaller:fpCaller
                               excluded:excludedIn
                               foldInfo:nil];
    }

+ (XTHomingResult*)assignHomesForFunction:(XTIRFunction*)fn
                                 gpCallee:(NSArray<NSString*>*)gpCallee
                                 gpCaller:(NSArray<NSString*>*)gpCaller
                                 fpCallee:(NSArray<NSString*>*)fpCallee
                                 fpCaller:(NSArray<NSString*>*)fpCaller
                                 excluded:(NSSet<NSNumber*>*)excludedIn
                                 foldInfo:(NSDictionary<NSNumber*, id>*)foldInfo
    {
    XTHomingResult* result = [[XTHomingResult alloc] init];
    NSMutableDictionary<NSNumber*, NSString*>* homeReg = [NSMutableDictionary dictionary];
    result.homeReg = homeReg;
    result.usedCalleeSaved = @[];

    NSArray<XTIRBlock*>* blocks = fn.blocks;
    NSUInteger nb = blocks.count;
    if (nb == 0)
        {
        return result;
        }

    NSMutableSet<NSNumber*>* excluded = [NSMutableSet setWithSet:excludedIn ?: [NSSet set]];

    // ── Position assignment + defs/uses/use-count/call-positions ──────────
    NSMutableArray<NSMutableSet<NSNumber*>*>* defSet = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber*>*>* ueUse = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber*>*>* phiResAt = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber*>*>* phiEdge = [NSMutableArray array];
    NSMutableArray<NSNumber*>* blkEnd = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++)
        {
        [defSet addObject:[NSMutableSet set]];
        [ueUse addObject:[NSMutableSet set]];
        [phiResAt addObject:[NSMutableSet set]];
        [phiEdge addObject:[NSMutableSet set]];
        [blkEnd addObject:@0];
        }
    NSMutableDictionary<NSNumber*, NSNumber*>* defPos = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* lastUse = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* useCount = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* phiResults = [NSMutableSet set];
    NSMutableArray<NSNumber*>* callPositions = [NSMutableArray array];

    __block NSInteger pos = 0;
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        XTIRBlock* b = blocks[bi];
        NSMutableSet<NSNumber*>*defs = defSet[bi], *ue = ueUse[bi];
        for (XTIRInsn* phi in b.phiNodes)
            {
            if (phi.result)
                {
                defPos[@(phi.result.valueId)] = @(pos);
                [defs addObject:@(phi.result.valueId)];
                [phiResAt[bi] addObject:@(phi.result.valueId)];
                [phiResults addObject:@(phi.result.valueId)];
                }
            pos++;
            }
        void (^recordUse)(XTIROperand*) = ^(XTIROperand* o) {
          if (o.kind != XTIROperandKindUse)
              return;
          NSNumber* v = @(o.valueId);
          if (![defs containsObject:v])
              [ue addObject:v];
          lastUse[v] = @(pos);
          useCount[v] = @(useCount[v].integerValue + 1);
        };
        for (XTIRInsn* insn in b.instructions)
            {
            for (XTIROperand* o in insn.operands)
                recordUse(o);
            // A folded ElementAddr/FieldAddr is elided: its base/index are read at
            // THIS Load/Store, so extend their live ranges here (else the allocator
            // reuses their register for the Load result and corrupts the base).
            if (foldInfo.count && (insn.opcode == XTIROpLoad || insn.opcode == XTIROpStore) && insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindUse)
                {
                XTIRInsn* fea = foldInfo[@(insn.operands[0].valueId)];
                if (fea)
                    for (XTIROperand* fo in fea.operands)
                        recordUse(fo);
                }
            if ([self isCallOpcode:insn.opcode])
                [callPositions addObject:@(pos)];
            // AddrOf operand ⇒ address-taken ⇒ must live at a real slot, never home.
            if (insn.opcode == XTIROpAddrOf)
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse)
                        [excluded addObject:@(o.valueId)];
            if (insn.result)
                {
                defPos[@(insn.result.valueId)] = @(pos);
                [defs addObject:@(insn.result.valueId)];
                }
            pos++;
            }
        if (b.terminator)
            {
            for (XTIROperand* o in b.terminator.operands)
                recordUse(o);
            if ([self isCallOpcode:b.terminator.opcode])
                [callPositions addObject:@(pos)];
            pos++;
            }
        blkEnd[bi] = @(pos - 1);
        }

    // ── phi-edge uses + successor lists ──────────────────────────────────
    NSMutableArray<NSArray<NSNumber*>*>* succIdx = [NSMutableArray array];
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        NSMutableArray<NSNumber*>* s = [NSMutableArray array];
        XTIRInsn* t = blocks[bi].terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef)
                    {
                    NSUInteger si = [blocks indexOfObjectIdenticalTo:o.blockRef];
                    if (si != NSNotFound)
                        [s addObject:@(si)];
                    }
        [succIdx addObject:s];
        }
    for (NSUInteger si = 0; si < nb; si++)
        for (XTIRInsn* phi in blocks[si].phiNodes)
            for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
                {
                XTIROperand *bo = phi.operands[k], *vo = phi.operands[k + 1];
                if (bo.kind != XTIROperandKindBlock || !bo.blockRef)
                    continue;
                if (vo.kind != XTIROperandKindUse)
                    continue;
                NSUInteger predBi = [blocks indexOfObjectIdenticalTo:bo.blockRef];
                if (predBi != NSNotFound)
                    {
                    [phiEdge[predBi] addObject:@(vo.valueId)];
                    useCount[@(vo.valueId)] = @(useCount[@(vo.valueId)].integerValue + 1);
                    }
                }

    // ── backward-dataflow liveness (SSA phi rule) ────────────────────────
    NSMutableArray<NSMutableSet<NSNumber*>*>* liveIn = [NSMutableArray array];
    NSMutableArray<NSMutableSet<NSNumber*>*>* liveOut = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++)
        {
        [liveIn addObject:[NSMutableSet set]];
        [liveOut addObject:[NSMutableSet set]];
        }
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSInteger bi = (NSInteger)nb - 1; bi >= 0; bi--)
            {
            NSMutableSet<NSNumber*>* out = [phiEdge[bi] mutableCopy];
            for (NSNumber* sn in succIdx[bi])
                {
                NSMutableSet* sin = [liveIn[sn.unsignedIntegerValue] mutableCopy];
                [sin minusSet:phiResAt[sn.unsignedIntegerValue]];
                [out unionSet:sin];
                }
            NSMutableSet<NSNumber*>* in = [ueUse[bi] mutableCopy];
            NSMutableSet* od = [out mutableCopy];
            [od minusSet:defSet[bi]];
            [in unionSet:od];
            if (![out isEqualToSet:liveOut[bi]] || ![in isEqualToSet:liveIn[bi]])
                {
                liveOut[bi] = out;
                liveIn[bi] = in;
                changed = YES;
                }
            }
        }

    // ── intervals (doubled positions) ────────────────────────────────────
    NSMutableDictionary<NSNumber*, NSNumber*>* endByVal = [NSMutableDictionary dictionary];
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        NSInteger be = 2 * blkEnd[bi].integerValue + 2;
        for (NSNumber* v in liveOut[bi])
            {
            NSNumber* cur = endByVal[v];
            if (!cur || be > cur.integerValue)
                endByVal[v] = @(be);
            }
        }
    NSMutableSet<NSNumber*>* allVals = [NSMutableSet setWithArray:defPos.allKeys];
    [allVals addObjectsFromArray:lastUse.allKeys];
    [allVals addObjectsFromArray:endByVal.allKeys];
    NSMutableDictionary<NSNumber*, NSNumber*>* startOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* endOf = [NSMutableDictionary dictionary];
    for (NSNumber* v in allVals)
        {
        NSInteger st = defPos[v] ? 2 * defPos[v].integerValue + 1 : 0;
        NSInteger en = st;
        if (lastUse[v])
            en = MAX(en, 2 * lastUse[v].integerValue);
        if (endByVal[v])
            en = MAX(en, endByVal[v].integerValue);
        startOf[v] = @(st);
        endOf[v] = @(en);
        }

    // crosses-a-call: any call's doubled position lies within [start,end].
    NSMutableSet<NSNumber*>* crossesCall = [NSMutableSet set];
    for (NSNumber* v in allVals)
        {
        NSInteger s = startOf[v].integerValue, e = endOf[v].integerValue;
        for (NSNumber* cp in callPositions)
            {
            NSInteger c = 2 * cp.integerValue;
            if (s <= c && c <= e)
                {
                [crossesCall addObject:v];
                break;
                }
            }
        }

    // ── candidates, split by register class, sorted by use count ─────────
    NSMutableArray<NSNumber*>* gp = [NSMutableArray array];
    NSMutableArray<NSNumber*>* fp = [NSMutableArray array];
    for (NSNumber* v in allVals)
        {
        if ([excluded containsObject:v])
            continue;
        if (useCount[v].integerValue == 0)
            continue; // never read
        XTIRValue* val = fn.values[v];
        XTIRType* t = val.type;
        if (!t)
            continue;
        if (t.kind == XTIRTypeKindMemory || t.kind == XTIRTypeKindVoid || t.kind == XTIRTypeKindAgg)
            continue;
        if ([self isFloatType:t])
            [fp addObject:v];
        else
            [gp addObject:v];
        }
    // Ties broken by PRINT order, not value id. An id is creation order, and
    // a pass that moves or remakes an instruction leaves the two out of step;
    // the self-hosted allocator reads the printed numbering, so an id
    // tie-break gave the same value r14 on one side and r13 on the other
    // (bug 090's last residue). Print order is the one sequence both see.
    NSArray<XTIRValue*>* printOrder = [fn valuesInPrintOrder];
    NSMutableDictionary<NSNumber*, NSNumber*>* rank = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < printOrder.count; i++)
        rank[@(printOrder[i].valueId)] = @(i);
    NSComparator byUsesDesc = ^NSComparisonResult(NSNumber* a, NSNumber* b) {
      NSInteger ua = useCount[a].integerValue, ub = useCount[b].integerValue;
      if (ua != ub)
          return ua > ub ? NSOrderedAscending : NSOrderedDescending;
      NSInteger ra = rank[a] ? rank[a].integerValue : (NSInteger)a.integerValue + 1000000;
      NSInteger rb = rank[b] ? rank[b].integerValue : (NSInteger)b.integerValue + 1000000;
      return ra < rb ? NSOrderedAscending : NSOrderedDescending; // stable
    };
    [gp sortUsingComparator:byUsesDesc];
    [fp sortUsingComparator:byUsesDesc];

    // ── two-tier assignment with live-range reuse ────────────────────────
    NSMutableArray<NSString*>* usedCallee = [NSMutableArray array];
    NSMutableSet<NSString*>* usedCalleeSet = [NSMutableSet set];
    // assign one register class. `callee`/`caller` are the two tiers; a value is
    // offered caller-saved first when it crosses no call (no prologue save), else
    // only callee-saved. Non-overlapping intervals share a register; phi results
    // get an exclusive register (edge copies write it out of interval-model band).
    void (^assign)(NSArray<NSNumber*>*, NSArray<NSString*>*, NSArray<NSString*>*) =
        ^(NSArray<NSNumber*>* cands, NSArray<NSString*>* callee, NSArray<NSString*>* caller) {
          // Build a combined pool: caller-saved first (preferred), then callee-saved.
          NSMutableArray<NSString*>* pool = [NSMutableArray arrayWithArray:caller];
          [pool addObjectsFromArray:callee];
          NSSet<NSString*>* callerSet = [NSSet setWithArray:caller];
          NSUInteger nr = pool.count;
          NSMutableArray<NSMutableArray<NSValue*>*>* regIvls = [NSMutableArray array];
          NSMutableArray<NSNumber*>* exclusive = [NSMutableArray array];
          for (NSUInteger i = 0; i < nr; i++)
              {
              [regIvls addObject:[NSMutableArray array]];
              [exclusive addObject:@NO];
              }
          for (NSNumber* v in cands)
              {
              NSInteger s = startOf[v].integerValue, e = endOf[v].integerValue;
              BOOL isPhi = [phiResults containsObject:v];
              BOOL mayUseCaller = ![crossesCall containsObject:v];
              NSInteger chosen = -1;
              for (NSUInteger r = 0; r < nr; r++)
                  {
                  if (!mayUseCaller && [callerSet containsObject:pool[r]])
                      continue; // needs callee-saved
                  if (exclusive[r].boolValue)
                      continue;
                  if (isPhi)
                      {
                      if (regIvls[r].count == 0)
                          {
                          chosen = (NSInteger)r;
                          break;
                          }
                      continue;
                      }
                  BOOL ok = YES;
                  for (NSValue* iv in regIvls[r])
                      {
                      NSRange rg = iv.rangeValue;
                      NSInteger s2 = (NSInteger)rg.location, e2 = s2 + (NSInteger)rg.length;
                      if (s <= e2 && s2 <= e)
                          {
                          ok = NO;
                          break;
                          }
                      }
                  if (ok)
                      {
                      chosen = (NSInteger)r;
                      break;
                      }
                  }
              if (chosen < 0)
                  continue; // unhomed → stays in its slot
              NSString* reg = pool[chosen];
              homeReg[v] = reg;
              [regIvls[chosen] addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)s, (NSUInteger)(e - s))]];
              if (isPhi)
                  exclusive[chosen] = @YES;
              if (![callerSet containsObject:reg] && ![usedCalleeSet containsObject:reg])
                  {
                  [usedCalleeSet addObject:reg];
                  [usedCallee addObject:reg];
                  }
              }
        };
    assign(gp, gpCallee, gpCaller);
    assign(fp, fpCallee, fpCaller);

    result.usedCalleeSaved = usedCallee;
    return result;
    }

@end
