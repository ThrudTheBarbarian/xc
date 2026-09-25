#import "XTIROptAggExpand.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"

// Splitting a copy of a large struct is worse than the block move the back end
// would emit; the point here is the two- or three-field struct a caller passes
// by value and a callee rebuilds.
static const NSUInteger kMaxFields = 4;

@implementation XTIROptAggExpand

- (NSString*)passName { return @"agg-expand"; }
- (NSInteger)minOptLevel { return 2; }

// The pinned local a pointer ultimately names, or 0. Walks FieldAddr and
// ElementAddr back to the AddrOf that started the chain.
static XTIRValueId baseLocalOf(XTIRValueId vid,
                               NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    XTIRValueId cur = vid;
    for (int hop = 0; hop < 8; hop++)
        {
        XTIRInsn* d = defOf[@(cur)];
        if (!d || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindUse)
            return 0;
        if (d.opcode == XTIROpAddrOf)
            return d.operands[0].valueId;
        if (d.opcode != XTIROpFieldAddr && d.opcode != XTIROpElementAddr)
            return 0;
        cur = d.operands[0].valueId;
        }
    return 0;
    }

// Could a store through `sp` disturb a read through `lp`? Distinct PINNED
// LOCALS are distinct storage, which is the only thing that needs proving here
// — the snapshot's own fields are read while the fields of ANOTHER local are
// being written, and without this that would block the fold.
static BOOL mayAlias(XTIRValueId sp, XTIRValueId lp,
                     XTIRFunction* fn, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    if (sp == lp)
        return YES;
    XTIRValueId a = baseLocalOf(sp, defOf), b = baseLocalOf(lp, defOf);
    if (!a || !b)
        return YES;
    BOOL aPinned = NO, bPinned = NO;
    for (XTIRPinnedLocal* pl in fn.frameInfo.pinnedLocals)
        {
        if (pl.valueId == a) aPinned = YES;
        if (pl.valueId == b) bPinned = YES;
        }
    return (!aPinned || !bPinned) ? YES : (a == b);
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        for (int round = 0; round < 16 && [self runOnFunction:fn]; round++)
            ;
    return YES;
    }

// Every instruction of the function, phis and terminator included.
// YES if `v` is typed as a pointer to exactly the aggregate `lay`, in any window.
static BOOL pointsToLayout(XTIRValue* v, XTIRLayout* lay)
    {
    XTIRType* t = v.type;
    return t && t.kind == XTIRTypeKindPtr && t.pointeeType &&
           t.pointeeType.kind == XTIRTypeKindAgg && t.pointeeType.layout == lay;
    }

static NSArray<XTIRInsn*>* allInsns(XTIRFunction* fn)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        }
    return all;
    }

// Point every use of `from` at `to`, across the whole function.
static void replaceUses(XTIRFunction* fn, XTIRValueId from, XTIROperand* to)
    {
    for (XTIRInsn* x in allInsns(fn))
        {
        NSMutableArray<XTIROperand*>* ops = [x.operands mutableCopy];
        BOOL hit = NO;
        for (NSUInteger q = 0; q < ops.count; q++)
            if (ops[q].kind == XTIROperandKindUse && ops[q].valueId == from)
                { ops[q] = to; hit = YES; }
        if (hit) [x replaceOperands:ops];
        }
    }

- (BOOL)runOnFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSMutableArray<XTIRInsn*>*>* userOf =
        [NSMutableDictionary dictionary];
    for (XTIRInsn* i in allInsns(fn))
        {
        if (i.result) defOf[@(i.result.valueId)] = i;
        // At most ONE entry per instruction per value: an instruction naming a
        // value twice is still one user, and the port's collector works that
        // way — a count that differs by operand would make the two disagree.
        for (XTIROperand* o in i.operands)
            if (o.kind == XTIROperandKindUse)
                {
                NSMutableArray* u = userOf[@(o.valueId)];
                if (!u) { u = [NSMutableArray array]; userOf[@(o.valueId)] = u; }
                if (![u containsObject:i]) [u addObject:i];
                }
        }

    for (XTIRBlock* bb in fn.blocks)
        if ([self foldSnapshotIn:bb fn:fn defOf:defOf userOf:userOf])
            return YES;
    for (XTIRBlock* bb in fn.blocks)
        if ([self splitCopyIn:bb fn:fn userOf:userOf])
            return YES;
    return NO;
    }

// An inlined by-value parameter leaves `v = Load p; a = AddrOf v; FieldAddr a`
// behind — a snapshot of the whole struct taken so its fields can be read out
// of a copy. Read them where they already live instead. There can be more than
// one AddrOf of the same snapshot.
- (BOOL)foldSnapshotIn:(XTIRBlock*)bb
                    fn:(XTIRFunction*)fn
                 defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
                userOf:(NSDictionary<NSNumber*, NSArray<XTIRInsn*>*>*)userOf
    {
    for (NSUInteger i = 0; i < bb.instructions.count; i++)
        {
        XTIRInsn* ld = bb.instructions[i];
        if (ld.opcode != XTIROpLoad || !ld.result ||
            ld.result.type.kind != XTIRTypeKindAgg ||
            ld.operands.count < 2 || !ld.memoryResult ||
            ld.operands[0].kind != XTIROperandKindUse)
            continue;

        NSArray<XTIRInsn*>* addrs = userOf[@(ld.result.valueId)];
        if (addrs.count == 0)
            continue;
        NSMutableArray<XTIRInsn*>* fields = [NSMutableArray array];
        BOOL ok = YES;
        for (XTIRInsn* ao in addrs)
            {
            if (ao.opcode != XTIROpAddrOf || !ao.result) { ok = NO; break; }
            NSArray<XTIRInsn*>* fu = userOf[@(ao.result.valueId)];
            if (fu.count == 0) { ok = NO; break; }
            for (XTIRInsn* f in fu)
                {
                if (f.opcode != XTIROpFieldAddr) { ok = NO; break; }
                [fields addObject:f];
                }
            if (!ok) break;
            }
        if (!ok || fields.count == 0)
            continue;

        // Everything that reads the snapshot must sit in this block, after the
        // load, and nothing in between may write the memory it reads.
        NSUInteger last = i;
        for (XTIRInsn* f in fields)
            {
            NSUInteger at = [bb.instructions indexOfObjectIdenticalTo:f];
            if (at == NSNotFound || at < i) { ok = NO; break; }
            if (at > last) last = at;
            }
        for (XTIRInsn* ao in addrs)
            {
            NSUInteger at = [bb.instructions indexOfObjectIdenticalTo:ao];
            if (at == NSNotFound || at < i) { ok = NO; break; }
            if (at > last) last = at;
            }
        if (!ok)
            continue;

        XTIRValueId srcPtr = ld.operands[0].valueId;
        for (NSUInteger j = i + 1; j <= last && ok; j++)
            {
            XTIRInsn* m = bb.instructions[j];
            if (m.opcode == XTIROpStore && m.operands.count >= 1 &&
                m.operands[0].kind == XTIROperandKindUse)
                ok = !mayAlias(m.operands[0].valueId, srcPtr, fn, defOf);
            else if (m.memoryResult && m.opcode != XTIROpLoad)
                ok = NO;                    // a call, or anything else opaque
            }
        if (!ok)
            continue;

        for (XTIRInsn* f in fields)
            {
            NSMutableArray<XTIROperand*>* ops = [f.operands mutableCopy];
            ops[0] = [XTIROperand useWithValueId:srcPtr];
            [f replaceOperands:ops];
            }
        replaceUses(fn, ld.memoryResult.valueId, ld.operands[1]);
        NSMutableArray<XTIRInsn*>* keep = [NSMutableArray array];
        for (XTIRInsn* x in bb.instructions)
            if (x != ld && ![addrs containsObject:x])
                [keep addObject:x];
        [bb.instructions setArray:keep];
        return YES;
        }
    return NO;
    }

// `v:Agg = Load src; ...; Store dst, v` — a struct copy — becomes one
// Load/Store pair per field. The field loads replace the aggregate load WHERE
// IT STANDS and the field stores replace the store where IT stands, so the
// reads and the writes happen exactly where they happened before and no alias
// reasoning is needed.
- (BOOL)splitCopyIn:(XTIRBlock*)bb
                 fn:(XTIRFunction*)fn
             userOf:(NSDictionary<NSNumber*, NSArray<XTIRInsn*>*>*)userOf
    {
    for (NSUInteger i = 0; i < bb.instructions.count; i++)
        {
        XTIRInsn* ld = bb.instructions[i];
        if (ld.opcode != XTIROpLoad || !ld.result || !ld.memoryResult ||
            ld.result.type.kind != XTIRTypeKindAgg || ld.operands.count < 2 ||
            ld.operands[0].kind != XTIROperandKindUse)
            continue;
        NSArray<XTIRInsn*>* u = userOf[@(ld.result.valueId)];
        if (u.count != 1)
            continue;
        XTIRInsn* st = u[0];
        if (st.opcode != XTIROpStore || !st.memoryResult || st.operands.count < 3 ||
            st.operands[0].kind != XTIROperandKindUse ||
            st.operands[1].valueId != ld.result.valueId)
            continue;
        NSUInteger si = [bb.instructions indexOfObjectIdenticalTo:st];
        if (si == NSNotFound || si <= i)
            continue;
        XTIRLayout* lay = ld.result.type.layout;
        if (!lay || lay.fields.count == 0 || lay.fields.count > kMaxFields)
            continue;
        // A field address needs a pointer to the aggregate itself. A copy into
        // a byte buffer (the variadic pack) stores through a U8 pointer, where
        // every FieldAddr would land on byte 0.
        if (!pointsToLayout([fn valueForId:ld.operands[0].valueId], lay) ||
            !pointsToLayout([fn valueForId:st.operands[0].valueId], lay))
            continue;
        BOOL scalarOnly = YES;
        for (XTIRLayoutField* f in lay.fields)
            if (!f.type || f.type.kind == XTIRTypeKindAgg ||
                f.type.kind == XTIRTypeKindMemory)
                { scalarOnly = NO; break; }
        if (!scalarOnly)
            continue;

        XTIRValue* (^mk)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
          XTIRValue* v =
              [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                            type:ty
                                         defSite:[[XTIRDefSite alloc] initWithBlock:bb
                                                                          insnIndex:0]];
          [fn registerValue:v];
          return v;
        };

        NSMutableArray<XTIRInsn*>* loads = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* stores = [NSMutableArray array];
        NSMutableArray<XTIRValue*>* vals = [NSMutableArray array];
        XTIRValueId mem = ld.operands[1].valueId;
        NSUInteger n = lay.fields.count;

        for (NSUInteger f = 0; f < n; f++)
            {
            XTIRType* fty = lay.fields[f].type;
            XTIRType* fpt = [XTIRType ptrToType:fty window:XTIRWindowUnbanked];
            XTIROperand* idx = [XTIROperand immIWithType:[XTIRType u8Type]
                                                   value:(int64_t)f];
            XTIRValue* sa = mk(fpt);
            [loads addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpFieldAddr
                                                       result:sa
                                                     operands:@[ ld.operands[0], idx ]
                                                       dbgLoc:ld.dbgLoc]];
            XTIRValue* fv = mk(fty);
            XTIRValue* m = (f + 1 == n) ? ld.memoryResult : mk([XTIRType memoryType]);
            XTIRInsn* fl = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                                     result:fv
                                                   operands:@[ [XTIROperand useWithValueId:sa.valueId],
                                                               [XTIROperand useWithValueId:mem] ]
                                                     dbgLoc:ld.dbgLoc];
            fl.memoryResult = m;
            [loads addObject:fl];
            [vals addObject:fv];
            mem = m.valueId;
            }

        mem = st.operands[2].valueId;
        for (NSUInteger f = 0; f < n; f++)
            {
            XTIRType* fty = lay.fields[f].type;
            XTIRType* fpt = [XTIRType ptrToType:fty window:XTIRWindowUnbanked];
            XTIROperand* idx = [XTIROperand immIWithType:[XTIRType u8Type]
                                                   value:(int64_t)f];
            XTIRValue* da = mk(fpt);
            [stores addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpFieldAddr
                                                        result:da
                                                      operands:@[ st.operands[0], idx ]
                                                        dbgLoc:st.dbgLoc]];
            XTIRValue* m = (f + 1 == n) ? st.memoryResult : mk([XTIRType memoryType]);
            XTIRInsn* fs = [[XTIRInsn alloc] initWithOpcode:XTIROpStore
                                                     result:nil
                                                   operands:@[ [XTIROperand useWithValueId:da.valueId],
                                                               [XTIROperand useWithValueId:vals[f].valueId],
                                                               [XTIROperand useWithValueId:mem] ]
                                                     dbgLoc:st.dbgLoc];
            fs.memoryResult = m;
            [stores addObject:fs];
            mem = m.valueId;
            }

        NSMutableArray<XTIRInsn*>* out = [NSMutableArray array];
        for (NSUInteger k = 0; k < bb.instructions.count; k++)
            {
            if (k == i)         { [out addObjectsFromArray:loads];  continue; }
            if (k == si)        { [out addObjectsFromArray:stores]; continue; }
            [out addObject:bb.instructions[k]];
            }
        [bb.instructions setArray:out];
        return YES;
        }
    return NO;
    }

@end
