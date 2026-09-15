#import "XTIROptArcSelfRetain.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"

@implementation XTIROptArcSelfRetain

- (NSString*)passName
    {
    return @"arc-self-retain";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

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

// The self-retain bracket of `fn` (the receiver Retain + its Releases) to elide,
// or nil. The receiver Retain must be the FIRST entry instruction and the only
// Retain of that class-pointer parameter (so a strong-local copy retain — which
// is not first — is excluded). Out: the receiver value-id.
static NSSet<XTIRInsn*>* _Nullable selfBracket(XTIRFunction* fn)
    {
    if ([fn.name rangeOfString:@"$"].location == NSNotFound)
        return nil; // methods only
    if (fn.blocks.count == 0)
        return nil;
    XTIRBlock* entry = fn.blocks[0];
    if (entry.instructions.count == 0)
        return nil;
    XTIRInsn* first = entry.instructions[0];
    if (first.opcode != XTIROpRetain || first.operands.count < 1)
        return nil;
    if (first.operands[0].kind != XTIROperandKindUse)
        return nil;
    XTIRValueId recv = first.operands[0].valueId;
    XTIRValue* rv = [fn valueForId:recv];
    if (!rv || !rv.defSite.isParameter)
        return nil;
    XTIRType* t = rv.type;
    if (!t || t.kind != XTIRTypeKindPtr || !t.pointeeType ||
        t.pointeeType.kind != XTIRTypeKindAgg)
        return nil;
    NSUInteger retainCount = 0;
    NSMutableSet<XTIRInsn*>* bracket = [NSMutableSet setWithObject:first];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse ||
                insn.operands[0].valueId != recv)
                continue;
            if (insn.opcode == XTIROpRetain)
                retainCount++;
            if (insn.opcode == XTIROpRelease)
                [bracket addObject:insn];
            }
        }
    if (retainCount != 1 || bracket.count < 2)
        return nil; // 1 retain + ≥1 release
    return bracket;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    if (getenv("XTARC_OFF"))
        return YES; // A/B measurement escape hatch
    NSMutableDictionary<NSString*, XTIRFunction*>* funcByName = [NSMutableDictionary dictionary];
    for (XTIRFunction* fn in mod.functions)
        funcByName[fn.name] = fn;

    NSMapTable<XTIRFunction*, NSSet<XTIRInsn*>*>* bracketOf =
        [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRFunction* fn in mod.functions)
        {
        NSSet<XTIRInsn*>* b = selfBracket(fn);
        if (b)
            [bracketOf setObject:b forKey:fn];
        }

    // ARC-inert fixpoint: a function is inert until proven otherwise. Skipping
    // its own bracket (net-zero on its receiver), it must contain no Release, no
    // virtual dispatch, and call only inert known functions.
    NSMutableSet<XTIRFunction*>* notInert = [NSMutableSet set];
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (XTIRFunction* fn in mod.functions)
            {
            if ([notInert containsObject:fn])
                continue;
            NSSet<XTIRInsn*>* bracket = [bracketOf objectForKey:fn];
            BOOL bad = NO;
            for (XTIRBlock* bb in fn.blocks)
                {
                for (XTIRInsn* insn in bb.instructions)
                    {
                    if (bracket && [bracket containsObject:insn])
                        continue;
                    XTIROpcode op = insn.opcode;
                    if (op == XTIROpRelease || op == XTIROpVTblDispatch || op == XTIROpProtoDispatch)
                        {
                        bad = YES;
                        break;
                        }
                    if (op == XTIROpCall || op == XTIROpCallBanked || op == XTIROpCallCloaked)
                        {
                        if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindSym)
                            {
                            bad = YES;
                            break;
                            }
                        XTIRSymbol* sym = [mod symbolForId:insn.operands[0].symbolId];
                        XTIRFunction* g = sym ? funcByName[sym.name] : nil;
                        if (!g || [notInert containsObject:g])
                            {
                            bad = YES;
                            break;
                            }
                        }
                    }
                if (bad)
                    break;
                }
            if (bad)
                {
                [notInert addObject:fn];
                changed = YES;
                }
            }
        }

    for (XTIRFunction* fn in mod.functions)
        {
        NSSet<XTIRInsn*>* bracket = [bracketOf objectForKey:fn];
        if (bracket && ![notInert containsObject:fn])
            {
            if (getenv("XTC_ARC_TRACE"))
                fprintf(stderr, "arc-self-retain: elide %s\n", fn.name.UTF8String);
            [self elide:bracket inFunction:fn];
            }
        }
    return YES;
    }

// Remove the bracket ops, threading the memory token past each (memory result →
// memory input), resolving chains so a use rewires to the first surviving token.
- (void)elide:(NSSet<XTIRInsn*>*)remove inFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* memBypass = [NSMutableDictionary dictionary];
    for (XTIRInsn* op in remove)
        {
        if (op.operands.count >= 2 && op.operands[1].kind == XTIROperandKindUse && op.memoryResult)
            memBypass[@(op.memoryResult.valueId)] = @(op.operands[1].valueId);
        }
    XTIRValueId (^resolve)(XTIRValueId) = ^XTIRValueId(XTIRValueId v) {
      NSNumber* cur = @(v);
      NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
      while (memBypass[cur] && ![seen containsObject:cur])
          {
          [seen addObject:cur];
          cur = memBypass[cur];
          }
      return (XTIRValueId)cur.unsignedLongLongValue;
    };
    NSArray<XTIROperand*>* (^rew)(XTIRInsn*) = ^NSArray*(XTIRInsn* insn) {
      NSMutableArray<XTIROperand*>* out = nil;
      for (NSUInteger i = 0; i < insn.operands.count; i++)
          {
          XTIROperand* o = insn.operands[i];
          if (o.kind != XTIROperandKindUse || !memBypass[@(o.valueId)])
              continue;
          if (!out)
              out = [insn.operands mutableCopy];
          out[i] = [XTIROperand useWithValueId:resolve(o.valueId)];
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
            // Don't rebuild an op being deleted — rebuilding makes a new object
            // that the identity-based removal below would then miss, leaving a
            // half-removed (e.g. release-without-retain) unbalanced bracket.
            if ([remove containsObject:bb.instructions[i]])
                continue;
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
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
            if ([remove containsObject:bb.instructions[i]])
                [bb.instructions removeObjectAtIndex:(NSUInteger)i];
        }
    }

@end
