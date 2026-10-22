// XTIROptVecCombine.m — see the header.
#import "XTIROptVecCombine.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"

@implementation XTIROptVecCombine

- (NSString*)passName
    {
    return self.pool ? @"vec-pool" : @"vec-combine";
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
    if (!prof.vectorizesBitSelect && !prof.vectorizesWideBitSelect)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        {
        if (![XTIROptVecCombine wantedFor:fn profile:prof])
            continue;
        if (!self.pool)
            {
            [self runOnFunction:fn];
            continue;
            }
        for (NSUInteger b = 0; b < fn.blocks.count; b++)
            {
            if (prof.vectorizesBitSelect)
                [self poolBlock:fn.blocks[b] index:b function:fn module:mod];
            else
                [self poolBlockWide:fn.blocks[b] index:b function:fn module:mod];
            }
        }
    return YES;
    }

// Whether fn's vector code may use the bit select and the lane rotate:
// everywhere on arm64; on x86 in a function 64 bytes wide (the port's vcWanted).
+ (BOOL)wantedFor:(XTIRFunction*)fn profile:(XTIROptTargetProfile*)prof
    {
    if (prof.vectorizesBitSelect)
        return YES;
    if (!prof.vectorizesWideBitSelect)
        return NO;
    NSUInteger w = fn.simdLaneBytes ? fn.simdLaneBytes : prof.vectorLaneBytes;
    return w == 64;
    }

static BOOL vcIntKind(XTIRTypeKind k)
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindU8 || k == XTIRTypeKindI16 || k == XTIRTypeKindU16 ||
           k == XTIRTypeKindI32 || k == XTIRTypeKindU32 || k == XTIRTypeKindI64 || k == XTIRTypeKindU64;
    }

// The Const a VSplat broadcasts, when it can come from the table: an integer
// constant defined in this block, into a 16-byte integer vector.
static XTIRInsn* _Nullable vcPoolable(XTIRInsn* n, NSDictionary<NSNumber*, XTIRInsn*>* defIn)
    {
    if (n.opcode != XTIROpVSplat || n.operands.count != 1 || !n.result)
        return nil;
    XTIROperand* o = n.operands[0];
    if (o.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = defIn[@(o.valueId)];
    if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmI)
        return nil;
    XTIRType* t = n.result.type;
    if (t.kind != XTIRTypeKindVec || t.vecBytes != 16 || !t.pointeeType || !vcIntKind(t.pointeeType.kind))
        return nil;
    return d;
    }

// In a big block (over XTIR_VEC_SPLAT_BIG_BODY, where the vectoriser splats
// each constant where it is used), the integer constants' splats become loads
// from a read-only table, `__xtv_kpool_<fn>_<block>`: one `ldr q` each,
// against `movz, movk, dup` (MD5's 64 round constants). The pool instance runs
// LATE, after the last LICM, which would take each table load out of the loop
// as invariant and hold all 64 of MD5's in the 14 vector registers; the table's
// address is an AddrOf at the block's top.
// vcPoolable for a 64-byte vector of 32-bit integer lanes.
static XTIRInsn* _Nullable vcPoolableWide(XTIRInsn* n, NSDictionary<NSNumber*, XTIRInsn*>* defIn)
    {
    if (n.opcode != XTIROpVSplat || n.operands.count != 1 || !n.result)
        return nil;
    XTIROperand* o = n.operands[0];
    if (o.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = defIn[@(o.valueId)];
    if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmI)
        return nil;
    XTIRType* t = n.result.type;
    if (t.kind != XTIRTypeKindVec || t.vecBytes != 64 || !t.pointeeType
        || !(t.pointeeType.kind == XTIRTypeKindI32 || t.pointeeType.kind == XTIRTypeKindU32))
        return nil;
    if (!d.result || !(d.result.type.kind == XTIRTypeKindI32 || d.result.type.kind == XTIRTypeKindU32))
        return nil;
    return d;
    }

// x86 at 64 bytes: the same table, one 4-byte entry per constant, each splat
// reading its entry (folded into one vpbroadcastd from memory; the port explains).
- (void)poolBlockWide:(XTIRBlock*)bb index:(NSUInteger)bi function:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (bb.instructions.count <= XTIR_VEC_SPLAT_BIG_BODY)
        return;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defIn = [NSMutableDictionary dictionary];
    NSUInteger cands = 0;
    for (XTIRInsn* n in bb.instructions)
        {
        if (n.result)
            defIn[@(n.result.valueId)] = n;
        if (vcPoolableWide(n, defIn))
            cands++;
        }
    if (cands < 2)
        return;
    NSString* nm = [NSString stringWithFormat:@"__xtv_kpool_%@_%lu", fn.name, (unsigned long)bi];
    for (XTIRSymbol* s in mod.symbols)
        if ([s.name isEqualToString:nm])
            return;
    XTIRType* u32p = [XTIRType ptrToType:[XTIRType u32Type] window:0];
    XTIRValue* base = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:u32p
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
    [fn registerValue:base];
    XTIRSymbolId symId = (XTIRSymbolId)mod.symbols.count;
    XTIRInsn* ao = [[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                             result:base
                                           operands:@[ [XTIROperand symWithSymbolId:symId] ]
                                             dbgLoc:nil];
    NSMutableData* bytes = [NSMutableData data];
    NSMutableDictionary<NSString*, NSNumber*>* idxOf = [NSMutableDictionary dictionary];
    XTIRType* symTy = nil;
    NSMutableArray<XTIRInsn*>* out = [NSMutableArray arrayWithObject:ao];
    XTIRValueId mem = (XTIRValueId)(fn.paramTypes.count - 1);
    for (XTIRInsn* n in bb.instructions)
        {
        XTIRInsn* kc = vcPoolableWide(n, defIn);
        if (!kc)
            {
            [out addObject:n];
            continue;
            }
        int64_t v = kc.operands[0].intValue & 0xFFFFFFFFLL;
        NSString* key = [NSString stringWithFormat:@"%lld", (long long)v];
        NSNumber* have = idxOf[key];
        NSUInteger idx;
        if (have)
            idx = have.unsignedIntegerValue;
        else
            {
            idx = idxOf.count;
            idxOf[key] = @(idx);
            for (uint32_t k = 0; k < 4; k++)
                {
                uint8_t byte = (uint8_t)((v >> (8 * k)) & 255); // LE
                [bytes appendBytes:&byte length:1];
                }
            }
        if (!symTy)
            symTy = n.result.type;
        XTIRValue* ea = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:u32p
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
        [fn registerValue:ea];
        [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                 result:ea
                                               operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                           [XTIROperand immIWithType:[XTIRType i64Type] value:(int64_t)idx] ]
                                                 dbgLoc:n.dbgLoc]];
        XTIRValue* sv = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:kc.result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
        [fn registerValue:sv];
        XTIRInsn* ld = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                                 result:sv
                                               operands:@[ [XTIROperand useWithValueId:ea.valueId],
                                                           [XTIROperand useWithValueId:mem] ]
                                                 dbgLoc:n.dbgLoc];
        XTIRValue* mr = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:[XTIRType memoryType]
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
        [fn registerValue:mr];
        ld.memoryResult = mr;
        [out addObject:ld];
        [n replaceOperands:@[ [XTIROperand useWithValueId:sv.valueId] ]];
        [out addObject:n];
        }
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:nm type:symTy volatile:NO escapes:NO taskLocal:NO];
    sym.initialBytes = bytes;
    XTIRSymbolId got = [mod addSymbol:sym];
    NSAssert(got == symId, @"kpool symbol id");
    (void)got;
    [bb.instructions setArray:out];
    }

- (void)poolBlock:(XTIRBlock*)bb index:(NSUInteger)bi function:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (bb.instructions.count <= XTIR_VEC_SPLAT_BIG_BODY)
        return;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defIn = [NSMutableDictionary dictionary];
    NSUInteger cands = 0;
    for (XTIRInsn* n in bb.instructions)
        {
        if (n.result)
            defIn[@(n.result.valueId)] = n;
        if (vcPoolable(n, defIn))
            cands++;
        }
    if (cands < 2)
        return;
    NSString* nm = [NSString stringWithFormat:@"__xtv_kpool_%@_%lu", fn.name, (unsigned long)bi];
    for (XTIRSymbol* s in mod.symbols)
        if ([s.name isEqualToString:nm])
            return;
    XTIRType* u8p = [XTIRType ptrToType:[XTIRType u8Type] window:0];
    XTIRValue* base = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:u8p
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
    [fn registerValue:base];
    // The symbol's id is the next one the module hands out: it is added below,
    // once the table is complete, and nothing else adds one in between.
    XTIRSymbolId symId = (XTIRSymbolId)mod.symbols.count;
    XTIRInsn* ao = [[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                             result:base
                                           operands:@[ [XTIROperand symWithSymbolId:symId] ]
                                             dbgLoc:nil];
    NSMutableData* bytes = [NSMutableData data];
    NSMutableDictionary<NSString*, NSNumber*>* idxOf = [NSMutableDictionary dictionary];
    XTIRType* symTy = nil;
    NSMutableArray<XTIRInsn*>* out = [NSMutableArray arrayWithObject:ao];
    for (XTIRInsn* n in bb.instructions)
        {
        XTIRInsn* kc = vcPoolable(n, defIn);
        if (!kc)
            {
            [out addObject:n];
            continue;
            }
        uint32_t w = n.result.type.pointeeType.byteWidth;
        int64_t v = kc.operands[0].intValue;
        if (w < 8)
            v = v & (((int64_t)1 << (w * 8)) - 1);
        NSString* key = [NSString stringWithFormat:@"%u:%lld", w, (long long)v];
        NSNumber* have = idxOf[key];
        NSUInteger idx;
        if (have)
            idx = have.unsignedIntegerValue;
        else
            {
            idx = idxOf.count;
            idxOf[key] = @(idx);
            for (uint32_t l = 0; l < 16 / w; l++)
                for (uint32_t k = 0; k < w; k++)
                    {
                    uint8_t byte = (uint8_t)((v >> (8 * k)) & 255); // LE
                    [bytes appendBytes:&byte length:1];
                    }
            }
        if (!symTy)
            symTy = n.result.type;
        XTIRValue* ea = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:u8p
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:0]];
        [fn registerValue:ea];
        [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                 result:ea
                                               operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                           [XTIROperand immIWithType:[XTIRType i64Type]
                                                                               value:(int64_t)idx * 16] ]
                                                 dbgLoc:n.dbgLoc]];
        [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                 result:n.result
                                               operands:@[ [XTIROperand useWithValueId:ea.valueId] ]
                                                 dbgLoc:n.dbgLoc]];
        }
    // Read-only, compiler-made, never address-taken beyond these loads. The
    // type is the 16-byte vector; the payload is the whole table, and the back
    // ends emit every byte of it.
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:nm type:symTy volatile:NO escapes:NO taskLocal:NO];
    sym.initialBytes = bytes;
    XTIRSymbolId got = [mod addSymbol:sym];
    NSAssert(got == symId, @"kpool symbol id");
    (void)got;
    [bb.instructions setArray:out];
    }

// The defining insn of a use operand, when it is `op`, in this block, with one use.
static XTIRInsn* _Nullable vcDef(XTIROperand* o, XTIROpcode op, NSDictionary<NSNumber*, XTIRInsn*>* defIn,
                                 NSCountedSet<NSNumber*>* uses)
    {
    if (o.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = defIn[@(o.valueId)];
    if (!d || d.opcode != op || [uses countForObject:@(o.valueId)] != 1)
        return nil;
    return d;
    }

static BOOL vcSame(XTIROperand* a, XTIROperand* b)
    {
    return a.kind == XTIROperandKindUse && b.kind == XTIROperandKindUse && a.valueId == b.valueId;
    }

// VRotl for VOr(p, q): p a VShl and q a VLShr of the same x, by c and w - c.
static XTIRInsn* _Nullable vcRotate(XTIRInsn* n, XTIROperand* p, XTIROperand* q,
                                    NSDictionary<NSNumber*, XTIRInsn*>* defIn, NSCountedSet<NSNumber*>* uses,
                                    NSMutableArray<XTIRInsn*>* dead)
    {
    XTIRInsn* sl = vcDef(p, XTIROpVShl, defIn, uses);
    XTIRInsn* sr = vcDef(q, XTIROpVLShr, defIn, uses);
    if (!sl || !sr || sl.operands.count != 2 || sr.operands.count != 2)
        return nil;
    XTIROperand* x = sl.operands[0];
    if (!vcSame(x, sr.operands[0]))
        return nil;
    XTIROperand* c = sl.operands[1];
    XTIROperand* d = sr.operands[1];
    if (c.kind != XTIROperandKindImmI || d.kind != XTIROperandKindImmI || !c.type)
        return nil;
    int64_t w = (int64_t)c.type.byteWidth * 8;
    if (w == 0 || c.intValue <= 0 || c.intValue >= w || c.intValue + d.intValue != w)
        return nil;
    [dead addObject:sl];
    [dead addObject:sr];
    return [[XTIRInsn alloc] initWithOpcode:XTIROpVRotl
                                     result:n.result
                                   operands:@[ x, [XTIROperand immIWithType:c.type value:c.intValue] ]
                                     dbgLoc:n.dbgLoc];
    }

// VBsl for VOr(p, q): p = VAnd(m, a) (either order), q = VAnd(VNot(m), b)
// (either order).
static XTIRInsn* _Nullable vcSelect(XTIRInsn* n, XTIROperand* p, XTIROperand* q,
                                    NSDictionary<NSNumber*, XTIRInsn*>* defIn, NSCountedSet<NSNumber*>* uses,
                                    NSMutableArray<XTIRInsn*>* dead)
    {
    XTIRInsn* ap = vcDef(p, XTIROpVAnd, defIn, uses);
    XTIRInsn* aq = vcDef(q, XTIROpVAnd, defIn, uses);
    if (!ap || !aq || ap.operands.count != 2 || aq.operands.count != 2)
        return nil;
    for (NSUInteger k = 0; k < 2; k++)
        {
        XTIRInsn* nt = vcDef(aq.operands[k], XTIROpVNot, defIn, uses);
        if (!nt || nt.operands.count != 1)
            continue;
        XTIROperand* mk = nt.operands[0];
        XTIROperand* b = aq.operands[1 - k];
        for (NSUInteger j = 0; j < 2; j++)
            {
            if (!vcSame(ap.operands[j], mk))
                continue;
            [dead addObject:ap];
            [dead addObject:aq];
            [dead addObject:nt];
            return [[XTIRInsn alloc] initWithOpcode:XTIROpVBsl
                                             result:n.result
                                           operands:@[ mk, ap.operands[1 - j], b ]
                                             dbgLoc:n.dbgLoc];
            }
        }
    return nil;
    }

// VBsl for VXor(p, q): q = VAnd(m, VXor(a, p)) (either order throughout).
static XTIRInsn* _Nullable vcSelectXor(XTIRInsn* n, XTIROperand* p, XTIROperand* q,
                                       NSDictionary<NSNumber*, XTIRInsn*>* defIn, NSCountedSet<NSNumber*>* uses,
                                       NSMutableArray<XTIRInsn*>* dead)
    {
    XTIRInsn* aq = vcDef(q, XTIROpVAnd, defIn, uses);
    if (!aq || aq.operands.count != 2 || p.kind != XTIROperandKindUse)
        return nil;
    for (NSUInteger k = 0; k < 2; k++)
        {
        XTIRInsn* x = vcDef(aq.operands[k], XTIROpVXor, defIn, uses);
        if (!x || x.operands.count != 2)
            continue;
        XTIROperand* mk = aq.operands[1 - k];
        for (NSUInteger j = 0; j < 2; j++)
            {
            if (!vcSame(x.operands[j], p))
                continue;
            [dead addObject:aq];
            [dead addObject:x];
            return [[XTIRInsn alloc] initWithOpcode:XTIROpVBsl
                                             result:n.result
                                           operands:@[ mk, x.operands[1 - j], p ]
                                             dbgLoc:n.dbgLoc];
            }
        }
    return nil;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* i in all)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defIn = [NSMutableDictionary dictionary];
        NSMutableArray<XTIRInsn*>* dead = [NSMutableArray array];
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            if (n.result)
                defIn[@(n.result.valueId)] = n;
            if (n.operands.count != 2 || !n.result)
                continue;
            XTIROperand* p = n.operands[0];
            XTIROperand* q = n.operands[1];
            if (n.opcode == XTIROpVXor)
                {
                XTIRInsn* rx = vcSelectXor(n, p, q, defIn, uses, dead);
                if (!rx)
                    rx = vcSelectXor(n, q, p, defIn, uses, dead);
                if (rx)
                    {
                    bb.instructions[i] = rx;
                    defIn[@(rx.result.valueId)] = rx;
                    }
                continue;
                }
            if (n.opcode != XTIROpVOr)
                continue;
            XTIRInsn* r = vcRotate(n, p, q, defIn, uses, dead);
            if (!r)
                r = vcRotate(n, q, p, defIn, uses, dead);
            if (!r)
                r = vcSelect(n, p, q, defIn, uses, dead);
            if (!r)
                r = vcSelect(n, q, p, defIn, uses, dead);
            if (!r)
                continue;
            bb.instructions[i] = r;
            defIn[@(r.result.valueId)] = r;
            }
        for (XTIRInsn* d in dead)
            [bb.instructions removeObjectIdenticalTo:d];
        }
    }

@end
