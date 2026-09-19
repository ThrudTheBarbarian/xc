// XTIRDominatorTests.m — the dominator tree, on the shapes passes rely on.
//
// A diamond (both arms dominated by the branch, the join dominated by the
// branch and NOT by either arm), a loop (body and exit dominated by the
// header), and an UNREACHABLE block — the last being the case that makes
// "one predecessor, therefore dominated" wrong, and the reason passes should
// ask this rather than count edges.
#import <Foundation/Foundation.h>
#import "XTIR.h"
#import "XTIRDominators.h"

static XTIRBlock* blk(NSString* name)
    {
    XTIRBlock* b = [[XTIRBlock alloc] init];
    b.name = name;
    return b;
    }

static void br(XTIRBlock* from, XTIRBlock* to)
    {
    [from setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                  result:nil
                                                operands:@[ [XTIROperand blockWithRef:to] ]
                                                  dbgLoc:nil]];
    }

static void cbr(XTIRBlock* from, XTIRValue* c, XTIRBlock* t, XTIRBlock* f)
    {
    [from setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                  result:nil
                                                operands:@[ [XTIROperand useWithValueId:c.valueId],
                                                            [XTIROperand blockWithRef:t],
                                                            [XTIROperand blockWithRef:f] ]
                                                  dbgLoc:nil]];
    }

int runIRDominatorTests(void)
    {
    fprintf(stderr, "  XTIRDominatorTests\n");
    int failures = 0;

    XTIRType* u8 = [XTIRType u8Type];
    XTIRType* mem = [XTIRType memoryType];
    XTIRType* bl = [XTIRType boolType];

    //        entry
    //        /   \          hdr --> body --> hdr   (a loop)
    //     then   else       hdr --> exit
    //        \   /
    //         join --> hdr ... exit --> ret
    //  orphan (no predecessor at all)
    XTIRBlock* entry = blk(@"entry");
    XTIRBlock* thenB = blk(@"then");
    XTIRBlock* elseB = blk(@"else");
    XTIRBlock* join  = blk(@"join");
    XTIRBlock* hdr   = blk(@"hdr");
    XTIRBlock* body  = blk(@"body");
    XTIRBlock* exit  = blk(@"exit");
    XTIRBlock* orphan = blk(@"orphan");

    XTIRFunction* fn = [[XTIRFunction alloc] initWithName:@"dom"
                                               returnType:u8
                                               paramTypes:@[ mem ]
                                               entryBlock:entry];
    for (XTIRBlock* b in @[ thenB, elseB, join, hdr, body, exit, orphan ])
        [fn.blocks addObject:b];

    XTIRValue* cond = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:bl
                                                 defSite:[XTIRDefSite parameterDef]];
    [fn registerValue:cond];

    cbr(entry, cond, thenB, elseB);
    br(thenB, join);
    br(elseB, join);
    br(join, hdr);
    cbr(hdr, cond, body, exit);
    br(body, hdr);
    br(exit, exit);
    br(orphan, join);          // reaches join, but nothing reaches orphan

    XTIRDominators* d = [XTIRDominators forFunction:fn];
    if (!d)
        { fprintf(stderr, "    FAIL: no dominators\n"); return 1; }

    struct { XTIRBlock* b; XTIRBlock* want; const char* name; } idoms[] = {
        { thenB, entry, "then" },
        { elseB, entry, "else" },
        // NOT `then` or `else`: the join is reachable through either arm, so
        // only the branch itself dominates it.
        { join,  entry, "join" },
        { hdr,   join,  "hdr"  },
        { body,  hdr,   "body" },
        { exit,  hdr,   "exit" },
    };
    for (unsigned i = 0; i < sizeof(idoms) / sizeof(idoms[0]); i++)
        {
        XTIRBlock* got = [d idomOf:idoms[i].b];
        if (got != idoms[i].want)
            {
            fprintf(stderr, "    FAIL: idom(%s) = %s, want %s\n", idoms[i].name,
                    (got.name ?: @"nil").UTF8String, idoms[i].want.name.UTF8String);
            failures++;
            }
        }
    if ([d idomOf:entry] != nil)
        { fprintf(stderr, "    FAIL: the entry should have no idom\n"); failures++; }

    // Unreachable blocks are absent, which is the point: a pass asking
    // "is this dominated" must get NO rather than a plausible-looking answer.
    if ([d isReachable:orphan])
        { fprintf(stderr, "    FAIL: orphan reported reachable\n"); failures++; }
    if ([d block:orphan dominates:join])
        { fprintf(stderr, "    FAIL: an unreachable block dominates nothing\n"); failures++; }
    if ([d idomOf:orphan] != nil)
        { fprintf(stderr, "    FAIL: orphan should have no idom\n"); failures++; }

    // Transitive dominance, and the negative cases.
    if (![d block:entry dominates:body])  { fprintf(stderr, "    FAIL: entry !dom body\n"); failures++; }
    if (![d block:hdr dominates:body])    { fprintf(stderr, "    FAIL: hdr !dom body\n"); failures++; }
    if (![d block:body dominates:body])   { fprintf(stderr, "    FAIL: body !dom itself\n"); failures++; }
    if ([d block:thenB dominates:join])   { fprintf(stderr, "    FAIL: then dominates join\n"); failures++; }
    if ([d block:body dominates:exit])    { fprintf(stderr, "    FAIL: body dominates exit\n"); failures++; }

    // Reverse postorder must place every block after its immediate dominator,
    // which is what lets a forward pass inherit a complete table.
    NSArray<XTIRBlock*>* rpo = d.reversePostorder;
    for (NSUInteger i = 0; i < rpo.count; i++)
        {
        XTIRBlock* id0 = [d idomOf:rpo[i]];
        if (id0 && [rpo indexOfObjectIdenticalTo:id0] >= i)
            {
            fprintf(stderr, "    FAIL: %s precedes its idom in RPO\n",
                    rpo[i].name.UTF8String);
            failures++;
            }
        }
    if (rpo.count != 7)
        { fprintf(stderr, "    FAIL: RPO has %lu blocks, want 7 (orphan excluded)\n",
                  (unsigned long)rpo.count); failures++; }

    if (failures == 0)
        fprintf(stderr, "  PASS (%lu reachable blocks, orphan excluded)\n",
                (unsigned long)rpo.count);
    return failures;
    }
