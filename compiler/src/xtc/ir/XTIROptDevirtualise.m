// XTIROptDevirtualise.m — guarded devirtualisation (see the header). Every
// step, every name and every value is made in the order the port's
// selfhost/opt/OptDevirt.xc makes it: the back ends lay out frame slots in
// value-creation order, so the two compilers write the same code only if
// the two passes create the same values in the same order.
#import "XTIROptDevirtualise.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"
#import "XTIRDominators.h"

// At most this many candidate classes; each method at most this many
// instructions; a versioned loop at most this many (OptDefs.xc's DV_*).
#define DV_MAX 4
#define DV_BODY 24
#define DV_LOOP 64

@implementation XTIROptDevirtualise
    {
    NSMutableArray<XTIRInsn*>* _done;   // sites already rewritten
    NSUInteger _seq;                    // the _dv<seq> in new block names
    XTIRModule* _mod;
    XTIRFunction* _fn;
    }

- (NSString*)passName { return @"devirtualise"; }
- (NSInteger)minOptLevel { return 2; }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>**)outErrors
    {
    (void)outErrors;
    if (!self.profile || !self.profile.devirtualises)
        return YES;
    _mod = mod;
    for (XTIRFunction* fn in [mod.functions copy])
        {
        _fn = fn;
        NSUInteger guard = 0;
        while (guard < 64 && [self one])
            guard++;
        }
    return YES;
    }

// ── helpers ─────────────────────────────────────────────────────────────

static NSString* nameOf(XTIRBlock* b) { return b.name ?: @""; }

- (XTIRValue*)value:(XTIRType*)ty in:(XTIRBlock*)b
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[_fn allocateValueId]
                                                 type:ty
                                              defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:0]];
    [_fn registerValue:v];
    return v;
    }

- (XTIRBlock*)block:(NSString*)name
    {
    XTIRBlock* b = [[XTIRBlock alloc] init];
    b.name = name;
    return b;
    }

- (XTIRInsn*)branchTo:(XTIRBlock*)t
    {
    return [[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                     result:nil
                                   operands:@[ [XTIROperand blockWithRef:t] ]
                                     dbgLoc:nil];
    }

static void setTerm(XTIRBlock* b, XTIRInsn* t)
    {
    if (b.terminator)
        [b resetTerminator];
    [b setTerminator:t];
    }

static XTIRType* dvVoidPtr(void)
    {
    return [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    }

- (XTIRType*)typeOfId:(XTIRValueId)vid
    {
    return [_fn valueForId:vid].type;
    }

static BOOL hasBlock(NSArray<XTIRBlock*>* a, XTIRBlock* b)
    {
    return [a indexOfObjectIdenticalTo:b] != NSNotFound;
    }

// ── candidates ──────────────────────────────────────────────────────────

- (nullable XTIRFunction*)func:(NSString*)name
    {
    for (XTIRFunction* f in _mod.functions)
        if ([f.name isEqualToString:name])
            return f;
    return nil;
    }

static NSString* selectorOf(NSString* impl)
    {
    NSRange r = [impl rangeOfString:@"$"];
    return r.location == NSNotFound ? impl : [impl substringFromIndex:r.location + 1];
    }

static BOOL hasSlot(XTIRSymbol* v, int64_t slot)
    {
    NSArray<NSString*>* s = v.vtableEntryNames;
    if (!s || slot < 0 || (NSUInteger)slot >= s.count)
        return NO;
    return ![s[(NSUInteger)slot] isEqualToString:@"_"];
    }

- (nullable XTIRSymbol*)vtableNamed:(NSString*)name
    {
    for (XTIRSymbol* s in _mod.symbols)
        if (s.kind == XTIRSymbolKindVTable && [s.name isEqualToString:name])
            return s;
    return nil;
    }

- (nullable XTIRSymbol*)parentOf:(XTIRSymbol*)v
    {
    NSArray<NSString*>* s = v.vtableEntryNames;
    if (!s || s.count == 0)
        return nil;
    NSString* up = s[0];
    if ([up isEqualToString:@"_"])
        return nil;
    return [self vtableNamed:up];
    }

- (BOOL)vtable:(XTIRSymbol*)v descends:(XTIRSymbol*)root
    {
    XTIRSymbol* c = v;
    for (NSUInteger guard = 0; c && guard < 64; guard++)
        {
        if (c == root)
            return YES;
        c = [self parentOf:c];
        }
    return NO;
    }

// The class whose own methods take a self of this type.
- (nullable XTIRSymbol*)vtableOfLayout:(XTIRType*)ty
    {
    for (XTIRSymbol* v in _mod.symbols)
        {
        if (v.kind != XTIRSymbolKindVTable || !v.vtableEntryNames || ![v.name hasSuffix:@"$vtbl"])
            continue;
        NSString* cls = [v.name substringToIndex:v.name.length - 4];   // "<Class>$"
        NSArray<NSString*>* s = v.vtableEntryNames;
        for (NSUInteger k = 1; k < s.count; k++)
            {
            NSString* impl = s[k];
            if (![impl hasPrefix:cls])
                continue;
            XTIRFunction* f = [self func:impl];
            if (!f || f.paramTypes.count == 0)
                continue;
            XTIRType* pt = f.paramTypes[0];
            if ([pt isEqual:ty])
                return v;
            break;
            }
        }
    return nil;
    }

// One block, no call, at most DV_BODY instructions: worth inlining.
static BOOL smallLeaf(XTIRFunction* f)
    {
    if (f.blocks.count != 1)
        return NO;
    XTIRBlock* b = f.blocks[0];
    if (b.instructions.count > DV_BODY)
        return NO;
    for (XTIRInsn* n in b.instructions)
        if (n.opcode == XTIROpCall || n.opcode == XTIROpVTblDispatch
            || n.opcode == XTIROpProtoDispatch || n.opcode == XTIROpCallIndirect)
            return NO;
    return YES;
    }

- (NSArray<XTIRSymbol*>*)candidates:(int64_t)slot receiver:(nullable XTIRType*)recvTy
    {
    NSMutableArray<XTIRSymbol*>* out = [NSMutableArray array];
    if (slot < 0 || !recvTy)
        return out;
    XTIRSymbol* c0 = [self vtableOfLayout:recvTy];
    if (!c0 || !hasSlot(c0, slot))
        return out;
    NSString* sel = selectorOf(c0.vtableEntryNames[(NSUInteger)slot]);
    XTIRSymbol* root = c0;
    for (NSUInteger guard = 0; guard < 64; guard++)
        {
        XTIRSymbol* up = [self parentOf:root];
        if (!up || !hasSlot(up, slot) || ![selectorOf(up.vtableEntryNames[(NSUInteger)slot]) isEqualToString:sel])
            break;
        root = up;
        }
    for (XTIRSymbol* s in _mod.symbols)
        {
        if (s.kind != XTIRSymbolKindVTable || !hasSlot(s, slot) || ![self vtable:s descends:root])
            continue;
        XTIRFunction* body = [self func:s.vtableEntryNames[(NSUInteger)slot]];
        if (!body || !smallLeaf(body))
            return @[];
        [out addObject:s];
        if (out.count > DV_MAX)
            return @[];
        }
    return out;
    }

// Is block index bi inside a loop: a branch from a block at or after it back
// to one at or before it.
- (BOOL)inLoop:(NSUInteger)bi
    {
    NSArray<XTIRBlock*>* bs = _fn.blocks;
    for (NSUInteger u = bi; u < bs.count; u++)
        {
        XTIRInsn* t = bs[u].terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            for (NSUInteger h = 0; h <= bi; h++)
                if (bs[h] == o.blockRef)
                    return YES;
            }
        }
    return NO;
    }

- (BOOL)one
    {
    for (NSUInteger bi = 0; bi < _fn.blocks.count; bi++)
        {
        XTIRBlock* B = _fn.blocks[bi];
        for (NSUInteger i = 0; i < B.instructions.count; i++)
            {
            XTIRInsn* d = B.instructions[i];
            if (d.opcode != XTIROpVTblDispatch || d.operands.count < 3)
                continue;
            if (_done && [_done indexOfObjectIdenticalTo:d] != NSNotFound)
                continue;
            if (!d.memoryResult)
                continue;
            XTIROperand* so = d.operands[1];
            XTIROperand* ro = d.operands[0];
            XTIROperand* mo = d.operands.lastObject;
            if (so.kind != XTIROperandKindImmI || ro.kind != XTIROperandKindUse || mo.kind != XTIROperandKindUse)
                continue;
            if (![self inLoop:bi])
                continue;
            NSArray<XTIRSymbol*>* cands = [self candidates:so.intValue receiver:[self typeOfId:ro.valueId]];
            if (cands.count == 0)
                continue;
            if (!_done)
                _done = [NSMutableArray array];
            if ([self version:B site:d candidates:cands])
                return YES;
            [self apply:B index:bi at:i site:d candidates:cands];
            return YES;
            }
        }
    return NO;
    }

- (XTIRSymbolId)symbolIdOf:(NSString*)name
    {
    XTIRSymbol* s = [_mod symbolForName:name];
    return (XTIRSymbolId)[_mod.symbols indexOfObjectIdenticalTo:s];
    }

// The class: the object's word 0, as a FieldAddr and a Load appended to blk.
- (XTIRValue*)classOf:(XTIROperand*)ro mem:(XTIROperand*)mem site:(XTIRInsn*)d in:(XTIRBlock*)blk
    {
    XTIRValue* fa = [self value:[XTIRType ptrToType:dvVoidPtr() window:XTIRWindowXtData] in:blk];
    [blk.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpFieldAddr
                                                          result:fa
                                                        operands:@[ ro, [XTIROperand immIWithType:[XTIRType u8Type] value:0] ]
                                                          dbgLoc:d.dbgLoc]];
    XTIRValue* cls = [self value:dvVoidPtr() in:blk];
    XTIRInsn* ld = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                             result:cls
                                           operands:@[ [XTIROperand useWithValueId:fa.valueId], mem ]
                                             dbgLoc:d.dbgLoc];
    ld.memoryResult = [self value:[XTIRType memoryType] in:blk];
    [blk.instructions addObject:ld];
    return cls;
    }

// AddrOf the vtable and ICmp EQ against the class, appended to blk.
- (XTIRValue*)test:(XTIRValue*)cls against:(XTIRSymbol*)vt site:(XTIRInsn*)d in:(XTIRBlock*)blk
    {
    XTIRValue* va = [self value:dvVoidPtr() in:blk];
    [blk.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                          result:va
                                                        operands:@[ [XTIROperand symWithSymbolId:[self symbolIdOf:vt.name]] ]
                                                          dbgLoc:d.dbgLoc]];
    XTIRValue* eq = [self value:[XTIRType boolType] in:blk];
    [blk.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                          result:eq
                                                        operands:@[ [XTIROperand useWithValueId:cls.valueId],
                                                                    [XTIROperand useWithValueId:va.valueId] ]
                                                       predicate:XTIRICmpEQ
                                                          dbgLoc:d.dbgLoc]];
    return eq;
    }

// ── the split form ──────────────────────────────────────────────────────

- (void)apply:(XTIRBlock*)B index:(NSUInteger)bi at:(NSUInteger)i site:(XTIRInsn*)d candidates:(NSArray<XTIRSymbol*>*)cands
    {
    if (!_done)
        _done = [NSMutableArray array];
    [_done addObject:d];
    _seq++;
    NSString* base = [NSString stringWithFormat:@"%@_dv%lu", nameOf(B), (unsigned long)_seq];
    XTIROperand* ro = d.operands[0];
    XTIROperand* mo = d.operands.lastObject;

    // The join: what followed the site, and B's terminator.
    XTIRBlock* J = [self block:[base stringByAppendingString:@"_join"]];
    for (NSUInteger k = i + 1; k < B.instructions.count; k++)
        [J.instructions addObject:B.instructions[k]];
    XTIRInsn* bt = B.terminator;
    if (bt)
        {
        [B resetTerminator];
        [J setTerminator:bt];
        }
    [B.instructions removeObjectsInRange:NSMakeRange(i, B.instructions.count - i)];
    [self retargetSuccPhisOf:J from:B];

    XTIRValue* cls = [self classOf:ro mem:mo site:d in:B];

    // The fallback: the dispatch as it was.
    XTIRBlock* F = [self block:[base stringByAppendingString:@"_virt"]];
    [F.instructions addObject:d];
    [F setTerminator:[self branchTo:J]];

    NSMutableArray<XTIRBlock*>* newBlocks = [NSMutableArray array];
    NSMutableArray<XTIRInsn*>* calls = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* callBlocks = [NSMutableArray array];
    XTIRBlock* testBlk = B;
    int64_t slot = d.operands[1].intValue;
    for (NSUInteger c = 0; c < cands.count; c++)
        {
        XTIRSymbol* vt = cands[c];
        NSString* impl = vt.vtableEntryNames[(NSUInteger)slot];
        XTIRValue* eq = [self test:cls against:vt site:d in:testBlk];

        XTIRBlock* T = [self block:[NSString stringWithFormat:@"%@_c%lu", base, (unsigned long)c]];
        XTIROperand* recv = ro;
        XTIRFunction* body = [self func:impl];
        if (body && body.paramTypes.count > 0)
            {
            XTIRType* pt = body.paramTypes[0];
            XTIRType* rt = [self typeOfId:ro.valueId];
            if (pt && rt && ![pt isEqual:rt])
                {
                XTIRValue* rc = [self value:pt in:T];
                [T.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpBitcast
                                                                    result:rc
                                                                  operands:@[ ro ]
                                                                    dbgLoc:d.dbgLoc]];
                recv = [XTIROperand useWithValueId:rc.valueId];
                }
            }
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithObjects:
                                             [XTIROperand symWithSymbolId:[self symbolIdOf:impl]], recv, nil];
        for (NSUInteger k = 2; k < d.operands.count; k++)
            [ops addObject:d.operands[k]];
        XTIRValue* res = d.result ? [self value:d.result.type in:T] : nil;
        XTIRInsn* call = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                                   result:res
                                                 operands:ops
                                                 callConv:[XTIRCallConv standard]
                                                   dbgLoc:d.dbgLoc];
        call.memoryResult = [self value:[XTIRType memoryType] in:T];
        [T.instructions addObject:call];
        [T setTerminator:[self branchTo:J]];
        [calls addObject:call];
        [callBlocks addObject:T];

        XTIRBlock* next = c + 1 < cands.count
            ? [self block:[NSString stringWithFormat:@"%@_t%lu", base, (unsigned long)(c + 1)]] : F;
        setTerm(testBlk, [[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand useWithValueId:eq.valueId],
                                                             [XTIROperand blockWithRef:T],
                                                             [XTIROperand blockWithRef:next] ]
                                                   dbgLoc:nil]);
        [newBlocks addObject:T];
        if (next != F)
            [newBlocks addObject:next];
        testBlk = next;
        }
    [newBlocks addObject:F];
    [newBlocks addObject:J];

    // The join's phi: the result after the site. No memory phi: the IR
    // threads its memory token in emission order (lowering makes no memory
    // phis), and F, just before J, ends with the dispatch's token, which the
    // join's readers keep.
    XTIRValue* oldRes = d.result;
    XTIRValue* rp = nil;
    if (oldRes)
        {
        rp = [self value:oldRes.type in:J];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (NSUInteger c = 0; c < calls.count; c++)
            {
            [ops addObject:[XTIROperand blockWithRef:callBlocks[c]]];
            [ops addObject:[XTIROperand useWithValueId:calls[c].result.valueId]];
            }
        [ops addObject:[XTIROperand blockWithRef:F]];
        [ops addObject:[XTIROperand useWithValueId:oldRes.valueId]];
        [J.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi result:rp operands:ops dbgLoc:nil]];
        }
    if (oldRes)
        {
        for (XTIRBlock* b in [_fn.blocks copy])
            replaceIn(b, oldRes, rp);
        replaceIn(J, oldRes, rp);
        }

    NSMutableArray<XTIRBlock*>* kept = [NSMutableArray array];
    for (NSUInteger b = 0; b < _fn.blocks.count; b++)
        {
        [kept addObject:_fn.blocks[b]];
        if (b == bi)
            [kept addObjectsFromArray:newBlocks];
        }
    [_fn.blocks setArray:kept];
    }

static NSArray<XTIRInsn*>* allOf(XTIRBlock* bb, BOOL withPhis)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
    if (withPhis)
        [all addObjectsFromArray:bb.phiNodes];
    [all addObjectsFromArray:bb.instructions];
    if (bb.terminator)
        [all addObject:bb.terminator];
    return all;
    }

static void replaceIn(XTIRBlock* bb, XTIRValue* oldRes, XTIRValue* rp)
    {
    for (XTIRInsn* u in allOf(bb, YES))
        {
        if (u.result == rp)
            continue;   // the join's own phi
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger k = 0; k < u.operands.count; k++)
            {
            XTIROperand* o = u.operands[k];
            if (o.kind != XTIROperandKindUse)
                continue;
            if (o.valueId != oldRes.valueId)
                continue;
            XTIROperand* n = [XTIROperand useWithValueId:rp.valueId];
            if (!ops)
                ops = [u.operands mutableCopy];
            ops[k] = n;
            }
        if (ops)
            [u replaceOperands:ops];
        }
    }

static void retargetPhis(XTIRBlock* s, XTIRBlock* from, XTIRBlock* to)
    {
    for (XTIRInsn* ph in s.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger q = 0; q + 1 < ph.operands.count; q += 2)
            if (ph.operands[q].blockRef == from)
                {
                if (!ops)
                    ops = [ph.operands mutableCopy];
                ops[q] = [XTIROperand blockWithRef:to];
                }
        if (ops)
            [ph replaceOperands:ops];
        }
    }

// A successor's phi that took a value from B takes it from J now.
- (void)retargetSuccPhisOf:(XTIRBlock*)J from:(XTIRBlock*)B
    {
    XTIRInsn* t = J.terminator;
    if (!t)
        return;
    for (XTIROperand* o in t.operands)
        {
        if (o.kind != XTIROperandKindBlock || !o.blockRef)
            continue;
        retargetPhis(o.blockRef, B, J);
        }
    }

// ── loop versioning ─────────────────────────────────────────────────────

- (NSArray<XTIRBlock*>*)succsOf:(XTIRBlock*)bb
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    XTIRInsn* t = bb.terminator;
    if (!t)
        return out;
    for (XTIROperand* o in t.operands)
        {
        if (o.kind != XTIROperandKindBlock || !o.blockRef)
            continue;
        if (!hasBlock(_fn.blocks, o.blockRef))
            continue;
        [out addObject:o.blockRef];
        }
    return out;
    }

// block -> the blocks whose terminator names it, once per mention.
- (NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>*)predMap
    {
    NSMapTable* out = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* src in _fn.blocks)
        {
        XTIRInsn* t = src.terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef || !hasBlock(_fn.blocks, o.blockRef))
                continue;
            NSMutableArray* ps = [out objectForKey:o.blockRef];
            if (!ps)
                {
                ps = [NSMutableArray array];
                [out setObject:ps forKey:o.blockRef];
                }
            [ps addObject:src];
            }
        }
    return out;
    }

static NSArray<XTIRBlock*>* predsIn(NSMapTable* preds, XTIRBlock* b)
    {
    NSArray* ps = b ? [preds objectForKey:b] : nil;
    return ps ?: @[];
    }

static NSArray<XTIRBlock*>* loopBody(NSMapTable* preds, XTIRBlock* H, XTIRBlock* latch)
    {
    NSMutableArray<XTIRBlock*>* body = [NSMutableArray arrayWithObject:H];
    NSHashTable* inBody = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    [inBody addObject:H];
    NSMutableArray<XTIRBlock*>* wl = [NSMutableArray arrayWithObject:latch];
    while (wl.count > 0)
        {
        XTIRBlock* n = wl.lastObject;
        [wl removeLastObject];
        if ([inBody containsObject:n])
            continue;
        [body addObject:n];
        [inBody addObject:n];
        [wl addObjectsFromArray:predsIn(preds, n)];
        }
    return body;
    }

static BOOL defines(XTIRBlock* b, XTIRValueId v)
    {
    for (XTIRInsn* p in b.phiNodes)
        if (p.result && p.result.valueId == v)
            return YES;
    for (XTIRInsn* n in b.instructions)
        if (n.result && n.result.valueId == v)
            return YES;
    return NO;
    }

static BOOL isMem(XTIRValue* v) { return v && v.type.kind == XTIRTypeKindMemory; }

// A phi's memory token: in this IR a memory phi carries it as its memory
// result, with no result (the printer writes `%m = Phi [...]` and the parser
// reads it back so); the port's IR types the phi's own result Mem.
static XTIRValue* phiMem(XTIRInsn* ph)
    {
    if (ph.memoryResult)
        return ph.memoryResult;
    return isMem(ph.result) ? ph.result : nil;
    }

// The memory token live at the end of P (see the port's dvMemAtEnd).
static XTIROperand* memAtEnd(XTIRBlock* P, XTIRBlock* H)
    {
    for (XTIRInsn* ph in H.phiNodes)
        {
        if (!phiMem(ph))
            continue;
        for (NSUInteger q = 0; q + 1 < ph.operands.count; q += 2)
            if (ph.operands[q].blockRef == P)
                return ph.operands[q + 1];
        }
    for (NSInteger i = (NSInteger)P.instructions.count - 1; i >= 0; i--)
        {
        XTIRInsn* n = P.instructions[(NSUInteger)i];
        if (n.memoryResult)
            return [XTIROperand useWithValueId:n.memoryResult.valueId];
        }
    for (XTIRInsn* ph in P.phiNodes)
        if (phiMem(ph))
            return [XTIROperand useWithValueId:phiMem(ph).valueId];
    return nil;
    }

- (BOOL)version:(XTIRBlock*)B site:(XTIRInsn*)d candidates:(NSArray<XTIRSymbol*>*)cands
    {
    XTIROperand* ro = d.operands[0];
    XTIRDominators* dom = [XTIRDominators forFunction:_fn];
    NSMapTable* preds = [self predMap];
    NSArray<XTIRBlock*>* best = nil;
    XTIRBlock* bestH = nil;
    for (XTIRBlock* latch in [_fn.blocks copy])
        {
        for (XTIRBlock* H in [self succsOf:latch])
            {
            if (!dom || ![dom isReachable:latch] || ![dom block:H dominates:latch])
                continue;
            NSArray<XTIRBlock*>* body = loopBody(preds, H, latch);
            if (!hasBlock(body, B))
                continue;
            if (!best || body.count < best.count)
                {
                best = body;
                bestH = H;
                }
            }
        }
    if (!best)
        return NO;
    XTIRBlock* H = bestH;
    for (XTIRBlock* b in best)
        if (defines(b, ro.valueId))
            return NO;
    XTIRBlock* P = nil;
    for (XTIRBlock* q in predsIn(preds, H))
        {
        if (hasBlock(best, q))
            continue;
        if (P)
            return NO;
        P = q;
        }
    if (!P || !P.terminator || P.terminator.opcode != XTIROpBranch)
        return NO;
    XTIRBlock* X = nil;
    NSUInteger ninsns = 0;
    for (XTIRBlock* bb in best)
        {
        ninsns += bb.instructions.count + bb.phiNodes.count;
        for (XTIRBlock* t in [self succsOf:bb])
            {
            if (hasBlock(best, t))
                continue;
            if (X && X != t)
                return NO;
            X = t;
            }
        }
    if (!X || ninsns > DV_LOOP)
        return NO;
    NSArray<XTIRBlock*>* xp = predsIn(preds, X);
    for (XTIRBlock* q in xp)
        if (!hasBlock(best, q))
            return NO;
    if (xp.count != 1)
        return NO;

    XTIROperand* memP = memAtEnd(P, H);
    XTIRBlock* up = P;
    for (NSUInteger k = 0; !memP && k < 64; k++)
        {
        NSArray<XTIRBlock*>* ups = predsIn(preds, up);
        if (ups.count != 1)
            break;
        up = ups[0];
        memP = memAtEnd(up, H);
        }
    // Up to the entry with nothing touching memory: the function's own memory
    // parameter (its last) is the token.
    if (!memP && predsIn(preds, up).count == 0)
        {
        // Values print parameters first, the memory token last of them.
        NSArray<XTIRValue*>* vals = [_fn valuesInPrintOrder];
        NSUInteger np = _fn.paramTypes.count;
        XTIRValue* lp = np > 0 && np <= vals.count ? vals[np - 1] : nil;
        if (lp && lp.type.kind == XTIRTypeKindMemory)
            memP = [XTIROperand useWithValueId:lp.valueId];
        }
    if (!memP)
        return NO;
    [_done addObject:d];
    _seq++;
    NSMutableArray<XTIRBlock*>* body = [NSMutableArray array];
    for (XTIRBlock* b in _fn.blocks)
        if (hasBlock(best, b))
            [body addObject:b];
    int64_t slot = d.operands[1].intValue;

    XTIRValue* cls = [self classOf:ro mem:memP site:d in:P];

    NSMutableArray<NSMutableDictionary<NSNumber*, XTIRValue*>*>* vmaps = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* pres = [NSMutableArray array];
    XTIRBlock* preOrig = [self block:[NSString stringWithFormat:@"%@_dv%lu_po", nameOf(P), (unsigned long)_seq]];
    [preOrig setTerminator:[self branchTo:H]];
    NSMutableArray<XTIRBlock*>* entries = [NSMutableArray array];
    NSMutableArray<NSMapTable<XTIRBlock*, XTIRBlock*>*>* copies = [NSMutableArray array];
    XTIRBlock* tb = P;
    for (NSUInteger c = 0; c < cands.count; c++)
        {
        XTIRSymbol* vt = cands[c];
        XTIRValue* eq = [self test:cls against:vt site:d in:tb];
        NSMapTable<XTIRBlock*, XTIRBlock*>* bmap = [NSMapTable strongToStrongObjectsMapTable];
        NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
        NSString* sfx = [NSString stringWithFormat:@"_dv%lu_v%lu", (unsigned long)_seq, (unsigned long)c];
        for (XTIRBlock* ob in body)
            [bmap setObject:[self block:[nameOf(ob) stringByAppendingString:sfx]] forKey:ob];
        XTIRBlock* next = c + 1 < cands.count
            ? [self block:[NSString stringWithFormat:@"%@_dv%lu_t%lu", nameOf(P), (unsigned long)_seq, (unsigned long)(c + 1)]]
            : preOrig;
        XTIRBlock* pre = [self block:[NSString stringWithFormat:@"%@_dv%lu_p%lu", nameOf(P), (unsigned long)_seq, (unsigned long)c]];
        [pre setTerminator:[self branchTo:[bmap objectForKey:H]]];
        [pres addObject:pre];
        setTerm(tb, [[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                              result:nil
                                            operands:@[ [XTIROperand useWithValueId:eq.valueId],
                                                        [XTIROperand blockWithRef:pre],
                                                        [XTIROperand blockWithRef:next] ]
                                              dbgLoc:nil]);
        [entries addObject:tb];
        [copies addObject:bmap];
        [self cloneLoop:body blocks:bmap values:vmap site:d impl:vt.vtableEntryNames[(NSUInteger)slot] from:P entry:pre];
        [vmaps addObject:vmap];
        if (next != preOrig)
            tb = next;
        }
    retargetPhis(H, P, preOrig);

    NSArray<XTIRBlock*>* exits = [self joinExit:body exit:X copies:copies values:vmaps];

    NSMutableArray<XTIRBlock*>* added = [NSMutableArray array];
    for (NSUInteger c = 0; c < cands.count; c++)
        {
        if (entries[c] != P)
            [added addObject:entries[c]];
        [added addObject:pres[c]];
        for (XTIRBlock* ob in body)
            [added addObject:[copies[c] objectForKey:ob]];
        [added addObject:exits[c + 1]];
        }
    [added addObject:preOrig];
    NSMutableArray<XTIRBlock*>* kept = [NSMutableArray array];
    for (XTIRBlock* b in _fn.blocks)
        {
        if (b == X)
            [kept addObject:exits[0]];
        [kept addObject:b];
        if (b == P)
            [kept addObjectsFromArray:added];
        }
    [_fn.blocks setArray:kept];
    return YES;
    }

- (void)name:(XTIRInsn*)n values:(NSMutableDictionary<NSNumber*, XTIRValue*>*)vmap in:(XTIRBlock*)nb
    {
    if (n.result)
        vmap[@(n.result.valueId)] = [self value:n.result.type in:nb];
    if (n.memoryResult)
        vmap[@(n.memoryResult.valueId)] = [self value:[XTIRType memoryType] in:nb];
    }

static XTIROperand* mapOp(XTIROperand* o, NSDictionary<NSNumber*, XTIRValue*>* vmap, NSMapTable* bmap)
    {
    if (o.kind == XTIROperandKindUse)
        {
        XTIRValue* nv = vmap[@(o.valueId)];
        return nv ? [XTIROperand useWithValueId:nv.valueId] : o;
        }
    if (o.kind == XTIROperandKindBlock && o.blockRef && bmap)
        {
        XTIRBlock* nb = [bmap objectForKey:o.blockRef];
        return nb ? [XTIROperand blockWithRef:nb] : o;
        }
    return o;
    }

static XTIRInsn* cloneInsn(XTIRInsn* n, NSDictionary<NSNumber*, XTIRValue*>* vmap, NSMapTable* bmap)
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
    for (XTIROperand* o in n.operands)
        [ops addObject:mapOp(o, vmap, bmap)];
    XTIRInsn* c = [[XTIRInsn alloc] initWithOpcode:n.opcode
                                            result:n.result ? vmap[@(n.result.valueId)] : nil
                                          operands:ops
                                          callConv:n.callConv
                                            dbgLoc:n.dbgLoc];
    c.predicate = n.predicate;
    if (n.memoryResult)
        c.memoryResult = vmap[@(n.memoryResult.valueId)];
    return c;
    }

- (void)cloneLoop:(NSArray<XTIRBlock*>*)body
           blocks:(NSMapTable<XTIRBlock*, XTIRBlock*>*)bmap
           values:(NSMutableDictionary<NSNumber*, XTIRValue*>*)vmap
             site:(XTIRInsn*)d
             impl:(NSString*)impl
             from:(XTIRBlock*)P
            entry:(XTIRBlock*)entry
    {
    for (XTIRBlock* ob in body)
        {
        XTIRBlock* nb = [bmap objectForKey:ob];
        for (XTIRInsn* p in ob.phiNodes)
            [self name:p values:vmap in:nb];
        for (XTIRInsn* n in ob.instructions)
            [self name:n values:vmap in:nb];
        }
    for (XTIRBlock* ob in body)
        {
        XTIRBlock* nb = [bmap objectForKey:ob];
        for (XTIRInsn* p in ob.phiNodes)
            {
            XTIRInsn* np = cloneInsn(p, vmap, bmap);
            NSMutableArray<XTIROperand*>* ops = [np.operands mutableCopy];
            for (NSUInteger q = 0; q + 1 < ops.count; q += 2)
                if (ops[q].blockRef == P)
                    ops[q] = [XTIROperand blockWithRef:entry];
            [np replaceOperands:ops];
            [nb.phiNodes addObject:np];
            }
        for (XTIRInsn* n in ob.instructions)
            {
            if (n == d)
                {
                [self directCall:n values:vmap impl:impl in:nb];
                continue;
                }
            [nb.instructions addObject:cloneInsn(n, vmap, bmap)];
            }
        if (ob.terminator)
            [nb setTerminator:cloneInsn(ob.terminator, vmap, bmap)];
        }
    }

- (void)directCall:(XTIRInsn*)d values:(NSDictionary<NSNumber*, XTIRValue*>*)vmap impl:(NSString*)impl in:(XTIRBlock*)nb
    {
    XTIROperand* recv = mapOp(d.operands[0], vmap, nil);
    XTIRFunction* body = [self func:impl];
    if (body && body.paramTypes.count > 0 && recv.kind == XTIROperandKindUse)
        {
        XTIRType* pt = body.paramTypes[0];
        XTIRValue* rv = vmap[@(d.operands[0].valueId)];
        XTIRType* rt = rv ? rv.type : [self typeOfId:recv.valueId];
        if (pt && rt && ![pt isEqual:rt])
            {
            XTIRValue* rc = [self value:pt in:nb];
            [nb.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpBitcast
                                                                 result:rc
                                                               operands:@[ recv ]
                                                                 dbgLoc:d.dbgLoc]];
            recv = [XTIROperand useWithValueId:rc.valueId];
            }
        }
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithObjects:
                                         [XTIROperand symWithSymbolId:[self symbolIdOf:impl]], recv, nil];
    for (NSUInteger k = 2; k < d.operands.count; k++)
        [ops addObject:mapOp(d.operands[k], vmap, nil)];
    XTIRInsn* call = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                               result:d.result ? vmap[@(d.result.valueId)] : nil
                                             operands:ops
                                             callConv:[XTIRCallConv standard]
                                               dbgLoc:d.dbgLoc];
    call.memoryResult = vmap[@(d.memoryResult.valueId)];
    [nb.instructions addObject:call];
    }

// Each version leaves through an exit block of its own (see the port's
// dvJoinExit). Returns the exit blocks: the original's first, then one per
// copy.
- (NSArray<XTIRBlock*>*)joinExit:(NSArray<XTIRBlock*>*)body
                            exit:(XTIRBlock*)X
                          copies:(NSArray<NSMapTable<XTIRBlock*, XTIRBlock*>*>*)copies
                          values:(NSArray<NSMutableDictionary<NSNumber*, XTIRValue*>*>*)vmaps
    {
    XTIRBlock* ex = nil;
    for (XTIRBlock* b in body)
        {
        if (ex)
            break;
        XTIRInsn* t = b.terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef == X)
                ex = b;
        }
    NSMutableArray<XTIRBlock*>* exits = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* exiting = [NSMutableArray arrayWithObject:ex];
    for (NSMapTable* bm in copies)
        [exiting addObject:[bm objectForKey:ex]];
    for (NSUInteger e = 0; e < exiting.count; e++)
        {
        XTIRBlock* eb = exiting[e];
        XTIRBlock* xb = [self block:[NSString stringWithFormat:@"%@_dv%lu_x%lu", nameOf(eb), (unsigned long)_seq, (unsigned long)e]];
        [xb setTerminator:[self branchTo:X]];
        XTIRInsn* t = eb.terminator;
        NSMutableArray<XTIROperand*>* ops = [t.operands mutableCopy];
        for (NSUInteger k = 0; k < ops.count; k++)
            if (ops[k].kind == XTIROperandKindBlock && ops[k].blockRef == X)
                ops[k] = [XTIROperand blockWithRef:xb];
        [t replaceOperands:ops];
        [exits addObject:xb];
        }
    for (XTIRInsn* ph in X.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = [ph.operands mutableCopy];
        NSUInteger n0 = ops.count;
        for (NSUInteger q = 0; q + 1 < n0; q += 2)
            {
            XTIROperand* bo = ops[q];
            if (bo.kind != XTIROperandKindBlock || bo.blockRef != ex)
                continue;
            XTIROperand* vo = ops[q + 1];
            ops[q] = [XTIROperand blockWithRef:exits[0]];
            for (NSUInteger c = 0; c < copies.count; c++)
                {
                [ops addObject:[XTIROperand blockWithRef:exits[c + 1]]];
                [ops addObject:mapOp(vo, vmaps[c], nil)];
                }
            }
        [ph replaceOperands:ops];
        }
    // Loop values read outside the loop.
    NSMutableDictionary<NSNumber*, XTIRValue*>* phiOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* ob in [_fn.blocks copy])
        {
        if (hasBlock(body, ob))
            continue;
        for (XTIRInsn* u in allOf(ob, ob != X))
            {
            NSMutableArray<XTIROperand*>* ops = nil;
            for (NSUInteger k = 0; k < u.operands.count; k++)
                {
                XTIROperand* o = u.operands[k];
                if (o.kind != XTIROperandKindUse || !vmaps[0][@(o.valueId)])
                    continue;
                // A memory token keeps naming the original loop's: it is laid
                // out last before X, so its token is the latest.
                if ([self typeOfId:o.valueId].kind == XTIRTypeKindMemory)
                    continue;
                XTIRValue* pv = phiOf[@(o.valueId)];
                if (!pv)
                    {
                    pv = [self value:[self typeOfId:o.valueId] in:X];
                    NSMutableArray<XTIROperand*>* pops = [NSMutableArray array];
                    [pops addObject:[XTIROperand blockWithRef:exits[0]]];
                    [pops addObject:[XTIROperand useWithValueId:o.valueId]];
                    for (NSUInteger c = 0; c < copies.count; c++)
                        {
                        [pops addObject:[XTIROperand blockWithRef:exits[c + 1]]];
                        [pops addObject:[XTIROperand useWithValueId:vmaps[c][@(o.valueId)].valueId]];
                        }
                    [X.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi result:pv operands:pops dbgLoc:nil]];
                    phiOf[@(o.valueId)] = pv;
                    }
                if (!ops)
                    ops = [u.operands mutableCopy];
                ops[k] = [XTIROperand useWithValueId:pv.valueId];
                }
            if (ops)
                [u replaceOperands:ops];
            }
        }
    return exits;
    }

@end
