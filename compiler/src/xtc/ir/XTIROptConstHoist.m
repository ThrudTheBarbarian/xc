#import "XTIROptConstHoist.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"

@implementation XTIROptConstHoist

- (NSString*)passName
    {
    return @"const-hoist";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod];
    return YES;
    }

// A key for the pointee shape the backend keys element/field strides off — two
// `AddrOf @sym` are mergeable only when these match (same symbol, window, and
// pointee), or a Ptr(U8) base would mis-size a Ptr(Agg) access after the merge.
static NSString* addrPointeeKey(XTIRType* ptrType, XTIRModule* mod)
    {
    XTIRType* p = ptrType.pointeeType;
    if (!p)
        return @"void";
    if (p.kind == XTIRTypeKindAgg)
        {
        NSUInteger idx = [mod.layoutTable indexOfObjectIdenticalTo:p.layout];
        return [NSString stringWithFormat:@"agg%lu", (unsigned long)idx];
        }
    if (p.kind == XTIRTypeKindPtr)
        return [NSString stringWithFormat:@"ptr:%@", addrPointeeKey(p, mod)];
    return [NSString stringWithFormat:@"k%d.w%u", (int)p.kind, p.byteWidth];
    }

// Rebuild an insn with new operands, preserving result/memResult/callConv/pred.
static XTIRInsn* rebuilt(XTIRInsn* insn, NSArray<XTIROperand*>* ops)
    {
    XTIRInsn* r;
    if (insn.callConv)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                    callConv:insn.callConv
                                      dbgLoc:insn.dbgLoc];
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
    else
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                      dbgLoc:insn.dbgLoc];
    r.memoryResult = insn.memoryResult;
    return r;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (fn.blocks.count == 0)
        return;
    XTIRBlock* entry = fn.blocks[0];
    BOOL hoistAddr = self.profile.hoistsGlobalAddr;

    // Group repeatable defs by a value-equivalence key, in program order:
    //   float Const  → "f:<typekind>:<rawbits>"
    //   AddrOf @sym  → "a:<symbolId>:<windowId>:<pointeeKey>"  (profile-gated)
    // Iterated in FIRST-APPEARANCE order, not the dictionary's: the group
    // order fixes the order the canonicals are inserted at the entry front, so
    // enumerating the dictionary would make the emitted IR a function of
    // NSString hash bucket layout — the same leak fixed in XTIROptPointerIV.
    NSMutableDictionary<NSString*, NSMutableArray<XTIRInsn*>*>* groups =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* groupOrder = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* insn in bb.instructions)
            {
            NSString* key = nil;
            if (insn.opcode == XTIROpConst && insn.result &&
                XTIRTypeKindIsFloating(insn.result.type.kind) &&
                insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindImmF)
                {
                key = [NSString stringWithFormat:@"f:%d:%llu",
                                                 (int)insn.result.type.kind,
                                                 (unsigned long long)insn.operands[0].floatRawBytes];
                }
            else if (hoistAddr && insn.opcode == XTIROpAddrOf && insn.result &&
                     insn.result.type.kind == XTIRTypeKindPtr &&
                     insn.operands.count >= 1 &&
                     insn.operands[0].kind == XTIROperandKindSym)
                {
                key = [NSString stringWithFormat:@"a:%llu:%d:%@",
                                                 (unsigned long long)insn.operands[0].symbolId,
                                                 (int)insn.result.type.windowId,
                                                 addrPointeeKey(insn.result.type, mod)];
                }
            if (!key)
                continue;
            NSMutableArray* g = groups[key];
            if (!g)
                {
                g = [NSMutableArray array];
                groups[key] = g;
                [groupOrder addObject:key];
                }
            [g addObject:insn];
            }
        }

    NSMutableDictionary<NSNumber*, NSNumber*>* replace = [NSMutableDictionary dictionary];
    NSMutableSet<XTIRInsn*>* remove = [NSMutableSet set];
    NSMutableArray<XTIRInsn*>* hoist = [NSMutableArray array];
    for (NSString* key in groupOrder)
        {
        NSArray<XTIRInsn*>* g = groups[key];
        if (g.count < 2)
            continue;            // only dedupe repeats
        XTIRInsn* canon = g[0];  // earliest occurrence
        [hoist addObject:canon]; // relocate to entry front
        for (NSUInteger i = 1; i < g.count; i++)
            {
            replace[@(g[i].result.valueId)] = @(canon.result.valueId);
            [remove addObject:g[i]];
            }
        }
    if (hoist.count == 0)
        return;

    // Drop the duplicates and pull the canonicals out of their blocks.
    [remove addObjectsFromArray:hoist];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
            if ([remove containsObject:bb.instructions[i]])
                [bb.instructions removeObjectAtIndex:(NSUInteger)i];
        }
    // Insert the canonicals at the front of the entry block (dominates all).
    [entry.instructions insertObjects:hoist
                            atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, hoist.count)]];

    // Rewrite every use of a removed duplicate to its canonical.
    NSArray<XTIROperand*>* (^rew)(XTIRInsn*) = ^NSArray*(XTIRInsn* insn) {
      NSMutableArray<XTIROperand*>* out = nil;
      for (NSUInteger i = 0; i < insn.operands.count; i++)
          {
          XTIROperand* o = insn.operands[i];
          if (o.kind != XTIROperandKindUse)
              continue;
          NSNumber* c = replace[@(o.valueId)];
          if (!c)
              continue;
          if (!out)
              out = [insn.operands mutableCopy];
          out[i] = [XTIROperand useWithValueId:(XTIRValueId)c.unsignedLongLongValue];
          }
      return out;
    };
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.phiNodes.count; i++)
            {
            NSArray* no = rew(bb.phiNodes[i]);
            if (no)
                bb.phiNodes[i] = rebuilt(bb.phiNodes[i], no);
            }
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            NSArray* no = rew(bb.instructions[i]);
            if (no)
                bb.instructions[i] = rebuilt(bb.instructions[i], no);
            }
        if (bb.terminator)
            {
            NSArray* no = rew(bb.terminator);
            if (no)
                {
                XTIRInsn* nt = rebuilt(bb.terminator, no);
                [bb resetTerminator];
                [bb setTerminator:nt];
                }
            }
        }
    }

@end
