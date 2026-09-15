#import "XTIROptVaArgExpand.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIRLayout.h"
#import "XTIROptTargetProfile.h"

// Fixed slot stride in __xtc_va_buf (matches XTIRLowering's packVarargsFrom).
static const NSUInteger kSlot = 8;

@implementation XTIROptVaArgExpand
    {
    XTIRModule* _mod;
    XTIRFunction* _fn;
    XTIRBlock* _bb;
    NSMutableArray<XTIRInsn*>* _out;                   // block being rebuilt
    NSMutableDictionary<NSNumber*, NSNumber*>* _remap; // old valueId → new
    XTIRSymbolId _bufSid;
    }

- (NSString*)passName
    {
    return @"vaarg-expand";
    }
- (NSInteger)minOptLevel
    {
    return 0;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    // Native-varargs targets (arm9) lower VaStart/VaArg in the backend to an
    // AAPCS va_list — leave the ops untouched for it.
    if (self.profile.usesNativeVarargs)
        return YES;
    _mod = mod;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

// Find-or-create the shared 128-byte pack buffer (mirrors XTIRLowering).
- (XTIRSymbolId)varargBuffer
    {
    XTIRSymbol* existing = [_mod symbolForName:@"__xtc_va_buf"];
    if (existing)
        return [_mod.symbols indexOfObjectIdenticalTo:existing];
    XTIRLayout* l = [[XTIRLayout alloc] initWithSize:128 alignment:1 fields:@[]];
    [_mod addLayout:l];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:@"__xtc_va_buf"
                                                type:[XTIRType aggWithLayout:l]
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    return [_mod addSymbol:sym];
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    BOOL has = NO;
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* in in bb.instructions)
            if (in.opcode == XTIROpVaStart || in.opcode == XTIROpVaArg)
                {
                has = YES;
                break;
                }
    if (!has)
        return;

    _fn = fn;
    _bufSid = [self varargBuffer];
    _remap = [NSMutableDictionary dictionary];

    // 1. Expand each op in place, allocating fresh boundary values and recording
    //    old→new id remaps (the originals are dropped from the IR).
    for (XTIRBlock* bb in fn.blocks)
        {
        _bb = bb;
        _out = [NSMutableArray arrayWithCapacity:bb.instructions.count];
        for (XTIRInsn* in in bb.instructions)
            {
            if (in.opcode == XTIROpVaStart)
                [self expandVaStart:in];
            else if (in.opcode == XTIROpVaArg)
                [self expandVaArg:in];
            else
                [_out addObject:in];
            }
        [bb.instructions setArray:_out];
        }

    // 2. One function-wide rewrite of every Use that referenced a dropped
    //    boundary value (the VaArg result / mem result) to its replacement.
    if (_remap.count)
        [self applyRemap];
    }

// ── insn builders (append to _out; fresh value carries a correct def site) ───
- (XTIRValue*)fresh:(XTIRType*)t
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[_fn allocateValueId]
                                                 type:t
                                              defSite:[[XTIRDefSite alloc] initWithBlock:_bb insnIndex:_out.count]];
    [_fn registerValue:v];
    return v;
    }
static XTIROperand* U(XTIRValue* v)
    {
    return [XTIROperand useWithValueId:v.valueId];
    }

- (void)push:(XTIROpcode)op result:(nullable XTIRValue*)r operands:(NSArray<XTIROperand*>*)ops
      memOut:(nullable XTIRValue*)memOut
    {
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:op result:r operands:ops dbgLoc:nil];
    insn.memoryResult = memOut;
    [_out addObject:insn];
    }

- (XTIRValue*)constU8:(NSUInteger)val
    {
    XTIRType* u8 = [XTIRType u8Type];
    XTIRValue* c = [self fresh:u8];
    [self push:XTIROpConst
          result:c
        operands:@[ [XTIROperand immIWithType:u8 value:(int64_t)val] ]
          memOut:nil];
    return c;
    }

// VaStart cursorAddr, memIn  →  Store(cursorAddr, 0:u8, memIn) → memResult
- (void)expandVaStart:(XTIRInsn*)va
    {
    XTIROperand* cursorAddr = va.operands[0];
    XTIROperand* memIn = va.operands[1];
    XTIRValue* zero = [self constU8:0];
    XTIRType* memTy = [XTIRType memoryType];
    XTIRValue* newMem = [self fresh:memTy];
    [self push:XTIROpStore
          result:nil
        operands:@[ cursorAddr, U(zero), memIn ]
          memOut:newMem];
    if (va.memoryResult)
        _remap[@(va.memoryResult.valueId)] = @(newMem.valueId);
    }

// VaArg cursorAddr, memIn  →  read __xtc_va_buf[cursor] at the result type,
// advance the cursor. Reproduces XTIRLowering's old inline expansion exactly.
- (void)expandVaArg:(XTIRInsn*)va
    {
    XTIROperand* cursorAddr = va.operands[0];
    XTIROperand* memIn = va.operands[1];
    XTIRType* resT = va.result.type;
    XTIRType* u8 = [XTIRType u8Type];
    XTIRType* u16 = [XTIRType u16Type];
    XTIRType* u8Ptr = [XTIRType ptrToType:u8 window:XTIRWindowUnbanked];
    XTIRType* memTy = [XTIRType memoryType];

    // bufPtr = AddrOf(__xtc_va_buf)
    XTIRValue* bufPtr = [self fresh:u8Ptr];
    [self push:XTIROpAddrOf
          result:bufPtr
        operands:@[ [XTIROperand symWithSymbolId:_bufSid] ]
          memOut:nil];
    // cursor = Load(cursorAddr) : u8   (memIn → m1)
    XTIRValue* cursor = [self fresh:u8];
    XTIRValue* m1 = [self fresh:memTy];
    [self push:XTIROpLoad result:cursor operands:@[ cursorAddr, memIn ] memOut:m1];
    // idx = ZExt(cursor) : u16 ; slotPtr = ElementAddr(bufPtr, idx)
    XTIRValue* idx = [self fresh:u16];
    [self push:XTIROpZExt result:idx operands:@[ U(cursor) ] memOut:nil];
    XTIRValue* slotPtr = [self fresh:u8Ptr];
    [self push:XTIROpElementAddr result:slotPtr operands:@[ U(bufPtr), U(idx) ] memOut:nil];

    NSUInteger advance = kSlot;
    XTIRValue* lastMem = m1;
    XTIRValue* newResult = nil;

    BOOL isStructPtr = (resT.kind == XTIRTypeKindPtr && resT.pointeeType && resT.pointeeType.kind == XTIRTypeKindAgg);
    if (isStructPtr)
        {
        // Hand back a typed pointer INTO the buffer; advance by sizeof(struct).
        newResult = [self fresh:resT];
        [self push:XTIROpBitcast result:newResult operands:@[ U(slotPtr) ] memOut:nil];
        if (resT.pointeeType.byteWidth > 0)
            advance = resT.pointeeType.byteWidth;
        }
    else if (XTIRTypeKindIsInteger(resT.kind) && resT.byteWidth < 2)
        {
        // Packer widened narrow ints to 2 bytes — read wide, truncate.
        BOOL sgn = XTIRTypeKindIsSigned(resT.kind);
        XTIRType* wide = sgn ? [XTIRType i16Type] : [XTIRType u16Type];
        XTIRValue* wv = [self fresh:wide];
        XTIRValue* m2 = [self fresh:memTy];
        [self push:XTIROpLoad result:wv operands:@[ U(slotPtr), U(m1) ] memOut:m2];
        lastMem = m2;
        newResult = [self fresh:resT];
        [self push:XTIROpTrunc result:newResult operands:@[ U(wv) ] memOut:nil];
        }
    else
        {
        XTIRValue* m2 = [self fresh:memTy];
        newResult = [self fresh:resT];
        [self push:XTIROpLoad result:newResult operands:@[ U(slotPtr), U(m1) ] memOut:m2];
        lastMem = m2;
        }

    // cursor += advance ; Store(cursorAddr, next) → memResult
    XTIRValue* delta = [self constU8:advance];
    XTIRValue* next = [self fresh:u8];
    [self push:XTIROpAdd result:next operands:@[ U(cursor), U(delta) ] memOut:nil];
    XTIRValue* newMem = [self fresh:memTy];
    [self push:XTIROpStore result:nil operands:@[ cursorAddr, U(next), U(lastMem) ] memOut:newMem];

    if (va.result)
        _remap[@(va.result.valueId)] = @(newResult.valueId);
    if (va.memoryResult)
        _remap[@(va.memoryResult.valueId)] = @(newMem.valueId);
    }

// ── function-wide use rewrite (old boundary id → replacement) ────────────────
- (void)applyRemap
    {
    for (XTIRBlock* bb in _fn.blocks)
        {
        [self rewriteList:bb.phiNodes];
        [self rewriteList:bb.instructions];
        XTIRInsn* t = bb.terminator;
        XTIRInsn* nt = t ? [self rebuild:t] : nil;
        if (nt)
            {
            [bb resetTerminator];
            [bb setTerminator:nt];
            }
        }
    }
- (void)rewriteList:(NSMutableArray<XTIRInsn*>*)list
    {
    for (NSUInteger i = 0; i < list.count; i++)
        {
        XTIRInsn* nt = [self rebuild:list[i]];
        if (nt)
            list[i] = nt;
        }
    }
- (nullable XTIRInsn*)rebuild:(XTIRInsn*)insn
    {
    NSMutableArray<XTIROperand*>* out = nil;
    for (NSUInteger i = 0; i < insn.operands.count; i++)
        {
        XTIROperand* op = insn.operands[i];
        NSNumber* to = (op.kind == XTIROperandKindUse) ? _remap[@(op.valueId)] : nil;
        if (to)
            {
            if (!out)
                out = [insn.operands mutableCopy];
            out[i] = [XTIROperand useWithValueId:(XTIRValueId)to.unsignedIntegerValue];
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

@end
