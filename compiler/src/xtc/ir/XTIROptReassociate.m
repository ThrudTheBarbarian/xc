#import "XTIROptReassociate.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@implementation XTIROptReassociate

- (NSString*)passName
    {
    return @"reassociate";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL reassocOp(XTIROpcode op)
    {
    return op == XTIROpAdd || op == XTIROpMul || op == XTIROpAnd || op == XTIROpOr || op == XTIROpXor;
    }

// 32- and 64-bit integers: a narrow result is canonicalised after each op by
// the back ends, and leaving those alone keeps this pass out of their way.
static BOOL reassocType(XTIRType* t)
    {
    return t && XTIRTypeKindIsInteger(t.kind) && (t.byteWidth == 4 || t.byteWidth == 8);
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        for (XTIRBlock* bb in fn.blocks)
            while ([self reassociateOneIn:bb function:fn])
                ;
    return YES;
    }

// Rebuild one chain in `bb`; NO when there is none left to rebuild.
- (BOOL)reassociateOneIn:(XTIRBlock*)bb function:(XTIRFunction*)fn
    {
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    NSMutableSet<NSNumber*>* phiIds = [NSMutableSet set];
    for (XTIRBlock* b in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
        [all addObjectsFromArray:b.instructions];
        if (b.terminator)
            [all addObject:b.terminator];
        for (XTIRInsn* i in all)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
        for (XTIRInsn* p in b.phiNodes)
            if (p.result)
                [phiIds addObject:@(p.result.valueId)];
        }
    NSMutableDictionary<NSNumber*, XTIRInsn*> * defIn = [NSMutableDictionary dictionary];
    for (XTIRInsn* i in bb.instructions)
        if (i.result)
            defIn[@(i.result.valueId)] = i;

    // The link feeding `cur` through operand `o`: same op, same type, in this
    // block, and read nowhere else.
    XTIRInsn* (^linkOf)(XTIROperand*, XTIRInsn*) = ^XTIRInsn*(XTIROperand* o, XTIRInsn* cur) {
      if (o.kind != XTIROperandKindUse || [uses countForObject:@(o.valueId)] != 1)
          return nil;
      XTIRInsn* p = defIn[@(o.valueId)];
      if (!p || p.opcode != cur.opcode || p.operands.count != 2 || p.memoryResult ||
          p.result.type.kind != cur.result.type.kind || p.result.type.byteWidth != cur.result.type.byteWidth)
          return nil;
      return p;
    };

    for (XTIRInsn* T in bb.instructions)
        {
        if (!reassocOp(T.opcode) || T.operands.count != 2 || !T.result || T.memoryResult ||
            !reassocType(T.result.type))
            continue;
        // T must END its chain: its result is not itself a link of a longer one.
        BOOL isLink = NO;
        if ([uses countForObject:@(T.result.valueId)] == 1)
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == T || u.opcode != T.opcode || u.operands.count != 2)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == T.result.valueId && linkOf(o, u) == T)
                        isLink = YES;
                }
        if (isLink)
            continue;

        // Walk back from T. At each link the operand that is the next link is
        // followed (operand 0 first); the other is a leaf.
        NSMutableArray<XTIRInsn*>* links = [NSMutableArray arrayWithObject:T];
        NSMutableArray<XTIROperand*>* leaves = [NSMutableArray array];
        XTIRInsn* cur = T;
        while (YES)
            {
            XTIRInsn* p0 = linkOf(cur.operands[0], cur);
            XTIRInsn* p1 = p0 ? nil : linkOf(cur.operands[1], cur);
            if (p0)
                {
                [leaves insertObject:cur.operands[1] atIndex:0];
                cur = p0;
                }
            else if (p1)
                {
                [leaves insertObject:cur.operands[0] atIndex:0];
                cur = p1;
                }
            else
                {
                [leaves insertObject:cur.operands[1] atIndex:0];
                [leaves insertObject:cur.operands[0] atIndex:0];
                break;
                }
            [links addObject:cur];
            }
        if (links.count < 2)
            continue;
        // Exactly one leaf is the loop-carried value, and every leaf is a value.
        XTIROperand* acc = nil;
        BOOL ok = YES;
        for (XTIROperand* l in leaves)
            {
            if (l.kind != XTIROperandKindUse)
                ok = NO;
            else if ([phiIds containsObject:@(l.valueId)])
                {
                if (acc)
                    ok = NO;
                acc = l;
                }
            }
        // Already one op on the carried value (`acc op tree`, which is what a
        // rewrite leaves): nothing to shorten, and rebuilding it again would
        // never stop.
        if (!ok || !acc || T.operands[0] == acc || T.operands[1] == acc)
            continue;
        // Already `acc op (one value)`: nothing to shorten.
        NSMutableArray<XTIROperand*>* rest = [NSMutableArray array];
        for (XTIROperand* l in leaves)
            if (l != acc)
                [rest addObject:l];

        // Pairwise tree over the other leaves, built just before T.
        NSUInteger at = [bb.instructions indexOfObjectIdenticalTo:T];
        XTIRType* ty = T.result.type;
        while (rest.count > 1)
            {
            NSMutableArray<XTIROperand*>* next = [NSMutableArray array];
            for (NSUInteger q = 0; q + 1 < rest.count; q += 2)
                {
                XTIRValueId rid = [fn allocateValueId];
                XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                              type:ty
                                                           defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:at]];
                [fn registerValue:rv];
                [bb.instructions insertObject:[[XTIRInsn alloc] initWithOpcode:T.opcode
                                                                        result:rv
                                                                      operands:@[ rest[q], rest[q + 1] ]
                                                                        dbgLoc:T.dbgLoc]
                                      atIndex:at];
                at++;
                [next addObject:[XTIROperand useWithValueId:rid]];
                }
            if (rest.count % 2)
                [next addObject:rest.lastObject];
            rest = next;
            }
        [T replaceOperands:@[ acc, rest[0] ]];
        for (XTIRInsn* l in links)
            if (l != T)
                [bb.instructions removeObjectIdenticalTo:l];
        return YES;
        }
    return NO;
    }

@end
