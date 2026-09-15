// XTIRPrinter.m
#import "XTIRPrinter.h"
#import "XTIR.h"

#pragma mark - Per-function value renumbering context

@interface XTIRPrintContext : NSObject
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* idMap; // oldId → newId
@property(nonatomic) NSUInteger nextId;
- (NSString*)nameForValueId:(XTIRValueId)oldId;
- (NSString*)allocateNameForValueId:(XTIRValueId)oldId;
@end

@implementation XTIRPrintContext
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _idMap = [NSMutableDictionary dictionary];
        _nextId = 0;
        }
    return self;
    }
- (NSString*)nameForValueId:(XTIRValueId)oldId
    {
    NSNumber* mapped = self.idMap[@(oldId)];
    if (mapped)
        return [NSString stringWithFormat:@"%%%lu", (unsigned long)mapped.unsignedIntegerValue];
    return [NSString stringWithFormat:@"%%?%u", (unsigned)oldId];
    }
- (NSString*)allocateNameForValueId:(XTIRValueId)oldId
    {
    NSNumber* existing = self.idMap[@(oldId)];
    if (existing)
        return [NSString stringWithFormat:@"%%%lu", (unsigned long)existing.unsignedIntegerValue];
    NSUInteger newId = self.nextId++;
    self.idMap[@(oldId)] = @(newId);
    return [NSString stringWithFormat:@"%%%lu", (unsigned long)newId];
    }
@end

@implementation XTIRPrinter

#pragma mark - Type rendering

+ (NSString*)stringFromWindow:(XTIRWindowId)w
    {
    switch (w)
        {
    case XTIRWindowUnbanked:
        return @"unbanked";
    case XTIRWindowXtCode:
        return @"xt_code";
    case XTIRWindowXtData:
        return @"xt_data";
    case XTIRWindowXlFlat:
        return @"xl_flat";
        }
    return @"unbanked";
    }

+ (NSString*)stringFromType:(XTIRType*)t module:(XTIRModule*)mod
    {
    switch (t.kind)
        {
    case XTIRTypeKindVoid:
        return @"Void";
    case XTIRTypeKindI8:
        return @"I8";
    case XTIRTypeKindU8:
        return @"U8";
    case XTIRTypeKindI16:
        return @"I16";
    case XTIRTypeKindU16:
        return @"U16";
    case XTIRTypeKindI32:
        return @"I32";
    case XTIRTypeKindU32:
        return @"U32";
    case XTIRTypeKindI64:
        return @"I64";
    case XTIRTypeKindU64:
        return @"U64";
    case XTIRTypeKindF32:
        return @"F32";
    case XTIRTypeKindF64:
        return @"F64";
    case XTIRTypeKindBool:
        return @"Bool";
    case XTIRTypeKindMemory:
        return @"Mem";
    case XTIRTypeKindPtr:
        {
        NSString* pointee = t.pointeeType
                                ? [self stringFromType:t.pointeeType module:mod]
                                : @"Void";
        return [NSString stringWithFormat:@"Ptr(%@, %@)",
                                          pointee, [self stringFromWindow:t.windowId]];
        }
    case XTIRTypeKindAgg:
        {
        NSUInteger idx = [mod.layoutTable indexOfObjectIdenticalTo:t.layout];
        if (idx == NSNotFound)
            return @"Agg(?)";
        return [NSString stringWithFormat:@"Agg(%lu)", (unsigned long)idx];
        }
    case XTIRTypeKindVec:
        return [NSString stringWithFormat:@"Vec(%@)",
                                          t.pointeeType ? [self stringFromType:t.pointeeType module:mod] : @"?"];
        }
    return @"?";
    }

#pragma mark - Helpers

+ (XTIRPrintContext*)buildContextForFunction:(XTIRFunction*)fn
    {
    XTIRPrintContext* ctx = [[XTIRPrintContext alloc] init];

    // 1. Parameters (paramTypes is the source of truth for parameter
    //    count; their value-ids are the first ones registered).
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        {
        XTIRValue* v = [fn valueForId:(XTIRValueId)i];
        if (v)
            [ctx allocateNameForValueId:v.valueId];
        }

    // 2. Pinned locals.
    for (XTIRPinnedLocal* local in fn.frameInfo.pinnedLocals)
        {
        [ctx allocateNameForValueId:local.valueId];
        }

    // 3. Block-by-block: phi results, regular insn results, terminator
    //    (no result), in order.
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* phi in block.phiNodes)
            {
            if (phi.result)
                [ctx allocateNameForValueId:phi.result.valueId];
            if (phi.memoryResult)
                [ctx allocateNameForValueId:phi.memoryResult.valueId];
            }
        for (XTIRInsn* insn in block.instructions)
            {
            if (insn.result)
                [ctx allocateNameForValueId:insn.result.valueId];
            if (insn.memoryResult)
                [ctx allocateNameForValueId:insn.memoryResult.valueId];
            }
        if (block.terminator)
            {
            if (block.terminator.result)
                [ctx allocateNameForValueId:block.terminator.result.valueId];
            if (block.terminator.memoryResult)
                [ctx allocateNameForValueId:block.terminator.memoryResult.valueId];
            }
        }
    return ctx;
    }

+ (NSArray<NSString*>*)predsForBlock:(XTIRBlock*)target inFunction:(XTIRFunction*)fn
    {
    NSMutableArray<NSString*>* preds = [NSMutableArray array];
    for (XTIRBlock* src in fn.blocks)
        {
        if (src == target)
            continue;
        XTIRInsn* term = src.terminator;
        if (!term)
            continue;
        for (XTIROperand* op in term.operands)
            {
            if (op.kind == XTIROperandKindBlock && op.blockRef == target)
                {
                [preds addObject:src.name ?: @"bb_?"];
                break;
                }
            }
        }
    return preds;
    }

#pragma mark - Operand rendering

+ (NSString*)stringFromOperand:(XTIROperand*)op
                        module:(XTIRModule*)mod
                       context:(XTIRPrintContext*)ctx
    {
    switch (op.kind)
        {
    case XTIROperandKindUse:
        return [ctx nameForValueId:op.valueId];
    case XTIROperandKindImmI:
        {
        NSString* typeStr = op.type ? [self stringFromType:op.type module:mod] : @"?";
        return [NSString stringWithFormat:@"#%lld:%@", (long long)op.intValue, typeStr];
        }
    case XTIROperandKindImmF:
        {
        NSString* typeStr = op.type ? [self stringFromType:op.type module:mod] : @"?";
        return [NSString stringWithFormat:@"#fp%016llx:%@",
                                          (unsigned long long)op.floatRawBytes, typeStr];
        }
    case XTIROperandKindSym:
        {
        XTIRSymbol* sym = [mod symbolForId:op.symbolId];
        NSString* name = sym ? sym.name : [NSString stringWithFormat:@"<unresolved-%lu>", (unsigned long)op.symbolId];
        return [NSString stringWithFormat:@"@%@", name];
        }
    case XTIROperandKindBlock:
        return op.blockRef.name ?: @"bb_?";
    case XTIROperandKindConstAgg:
        return [NSString stringWithFormat:@"#cpool:%lu", (unsigned long)op.constantId];
        }
    return @"?";
    }

#pragma mark - Opcode names

+ (NSString*)mnemonicForOpcode:(XTIROpcode)op
    {
    switch (op)
        {
    case XTIROpConst:
        return @"Const";
    case XTIROpCopy:
        return @"Copy";
    case XTIROpAdd:
        return @"Add";
    case XTIROpSub:
        return @"Sub";
    case XTIROpMul:
        return @"Mul";
    case XTIROpSDiv:
        return @"SDiv";
    case XTIROpUDiv:
        return @"UDiv";
    case XTIROpSRem:
        return @"SRem";
    case XTIROpURem:
        return @"URem";
    case XTIROpNeg:
        return @"Neg";
    case XTIROpFAdd:
        return @"FAdd";
    case XTIROpFSub:
        return @"FSub";
    case XTIROpFMul:
        return @"FMul";
    case XTIROpFDiv:
        return @"FDiv";
    case XTIROpFNeg:
        return @"FNeg";
    case XTIROpFSqrt:
        return @"FSqrt";
    case XTIROpAnd:
        return @"And";
    case XTIROpOr:
        return @"Or";
    case XTIROpXor:
        return @"Xor";
    case XTIROpNot:
        return @"Not";
    case XTIROpShl:
        return @"Shl";
    case XTIROpLShr:
        return @"LShr";
    case XTIROpAShr:
        return @"AShr";
    case XTIROpRol:
        return @"Rol";
    case XTIROpRor:
        return @"Ror";
    case XTIROpSExt:
        return @"SExt";
    case XTIROpZExt:
        return @"ZExt";
    case XTIROpTrunc:
        return @"Trunc";
    case XTIROpBitcast:
        return @"Bitcast";
    case XTIROpIntToPtr:
        return @"IntToPtr";
    case XTIROpPtrToInt:
        return @"PtrToInt";
    case XTIROpFpToSI:
        return @"FpToSI";
    case XTIROpFpToUI:
        return @"FpToUI";
    case XTIROpSIToFp:
        return @"SIToFp";
    case XTIROpUIToFp:
        return @"UIToFp";
    case XTIROpFpExt:
        return @"FpExt";
    case XTIROpFpTrunc:
        return @"FpTrunc";
    case XTIROpClassDowncast:
        return @"ClassDowncast";
    case XTIROpClassDowncastFailable:
        return @"ClassDowncastFailable";
    case XTIROpICmp:
        return @"ICmp";
    case XTIROpFCmp:
        return @"FCmp";
    case XTIROpSelect:
        return @"Select";
    case XTIROpLoad:
        return @"Load";
    case XTIROpStore:
        return @"Store";
    case XTIROpLoadVolatile:
        return @"LoadVolatile";
    case XTIROpStoreVolatile:
        return @"StoreVolatile";
    case XTIROpMemCopy:
        return @"MemCopy";
    case XTIROpMemSet:
        return @"MemSet";
    case XTIROpAddrOf:
        return @"AddrOf";
    case XTIROpAggBuild:
        return @"AggBuild";
    case XTIROpAggExtract:
        return @"AggExtract";
    case XTIROpAggInsert:
        return @"AggInsert";
    case XTIROpAggLoad:
        return @"AggLoad";
    case XTIROpAggStore:
        return @"AggStore";
    case XTIROpFieldAddr:
        return @"FieldAddr";
    case XTIROpElementAddr:
        return @"ElementAddr";
    case XTIROpBranch:
        return @"Branch";
    case XTIROpCondBranch:
        return @"CondBranch";
    case XTIROpSwitch:
        return @"Switch";
    case XTIROpReturn:
        return @"Return";
    case XTIROpIndirectBranch:
        return @"IndirectBranch";
    case XTIROpUnreachable:
        return @"Unreachable";
    case XTIROpCall:
        return @"Call";
    case XTIROpCallIndirect:
        return @"CallIndirect";
    case XTIROpCallCloaked:
        return @"CallCloaked";
    case XTIROpCallBanked:
        return @"CallBanked";
    case XTIROpCallBankedIndirect:
        return @"CallBankedIndirect";
    case XTIROpVTblDispatch:
        return @"VTblDispatch";
    case XTIROpProtoDispatch:
        return @"ProtoDispatch";
    case XTIROpProtoLoad:
        return @"ProtoLoad";
    case XTIROpVTblLoad:
        return @"VTblLoad";
    case XTIROpVaStart:
        return @"VaStart";
    case XTIROpVaArg:
        return @"VaArg";
    case XTIROpPhi:
        return @"Phi";
    case XTIROpRetain:
        return @"Retain";
    case XTIROpRelease:
        return @"Release";
    case XTIROpAutorelease:
        return @"Autorelease";
    case XTIROpWeakRegister:
        return @"WeakRegister";
    case XTIROpWeakUnregister:
        return @"WeakUnregister";
    case XTIROpWeakLoad:
        return @"WeakLoad";
    case XTIROpBankSave:
        return @"BankSave";
    case XTIROpBankRestore:
        return @"BankRestore";
    case XTIROpBankSelectFor:
        return @"BankSelectFor";
    case XTIROpAsm:
        return @"Asm";
    case XTIROpDbgValue:
        return @"DbgValue";
    case XTIROpVLoad:
        return @"VLoad";
    case XTIROpVStore:
        return @"VStore";
    case XTIROpVSplat:
        return @"VSplat";
    case XTIROpVAdd:
        return @"VAdd";
    case XTIROpVSub:
        return @"VSub";
    case XTIROpVMul:
        return @"VMul";
    case XTIROpVAnd:
        return @"VAnd";
    case XTIROpVOr:
        return @"VOr";
    case XTIROpVXor:
        return @"VXor";
    case XTIROpVMax:
        return @"VMax";
    case XTIROpVMin:
        return @"VMin";
    case XTIROpVICmp:
        return @"VICmp";
    case XTIROpVAddLP:
        return @"VAddLP";
    case XTIROpVReduceAdd:
        return @"VReduceAdd";
    case XTIROpVReduceMax:
        return @"VReduceMax";
    case XTIROpVReduceMin:
        return @"VReduceMin";
        }
    return @"?";
    }

+ (NSString*)stringFromCallConv:(XTIRCallConv*)cc
    {
    if (!cc)
        return @"CallConv::Standard";
    switch (cc.kind)
        {
    case XTIRCallConvStandard:
        return @"CallConv::Standard";
    case XTIRCallConvCloaked:
        return @"CallConv::Cloaked";
    case XTIRCallConvBanked:
        return @"CallConv::Banked";
    case XTIRCallConvInline:
        return @"CallConv::Inline";
    case XTIRCallConvRuntimeHelper:
        return @"CallConv::RuntimeHelper";
        }
    return @"CallConv::Standard";
    }

#pragma mark - Instruction rendering

+ (NSString*)stringFromInsn:(XTIRInsn*)insn
                     module:(XTIRModule*)mod
                    context:(XTIRPrintContext*)ctx
    {
    NSMutableString* line = [NSMutableString string];

    // LHS: result(s).
    NSMutableArray<NSString*>* lhs = [NSMutableArray array];
    if (insn.result)
        {
        [lhs addObject:[NSString stringWithFormat:@"%@:%@",
                                                  [ctx nameForValueId:insn.result.valueId],
                                                  [self stringFromType:insn.result.type
                                                                module:mod]]];
        }
    if (insn.memoryResult)
        {
        [lhs addObject:[ctx nameForValueId:insn.memoryResult.valueId]];
        }
    if (lhs.count > 0)
        {
        [line appendString:[lhs componentsJoinedByString:@", "]];
        [line appendString:@" = "];
        }

    // Mnemonic.
    [line appendString:[self mnemonicForOpcode:insn.opcode]];

    // Operands — opcode-specific shapes.
    switch (insn.opcode)
        {
    case XTIROpPhi:
        {
        // Phi [(bb_pred, %v), ...]
        [line appendString:@" ["];
        NSMutableArray<NSString*>* pairs = [NSMutableArray array];
        // Phi operands are pairs: (Block, Use), (Block, Use), ...
        for (NSUInteger i = 0; i + 1 < insn.operands.count; i += 2)
            {
            XTIROperand* blockOp = insn.operands[i];
            XTIROperand* valueOp = insn.operands[i + 1];
            [pairs addObject:[NSString stringWithFormat:@"(%@, %@)",
                                                        [self stringFromOperand:blockOp
                                                                         module:mod
                                                                        context:ctx],
                                                        [self stringFromOperand:valueOp
                                                                         module:mod
                                                                        context:ctx]]];
            }
        [line appendString:[pairs componentsJoinedByString:@", "]];
        [line appendString:@"]"];
        break;
        }
    case XTIROpCall:
    case XTIROpCallCloaked:
    case XTIROpCallBanked:
    case XTIROpCallIndirect:
    case XTIROpCallBankedIndirect:
        {
        // <sym/fp>, [args], CallConv::Kind, %mem
        // Operands layout: [callee, arg0, arg1, ..., memInput]
        NSUInteger n = insn.operands.count;
        if (n >= 2)
            {
            XTIROperand* callee = insn.operands[0];
            XTIROperand* memOp = insn.operands[n - 1];
            NSMutableArray<NSString*>* args = [NSMutableArray array];
            for (NSUInteger i = 1; i + 1 < n; i++)
                {
                [args addObject:[self stringFromOperand:insn.operands[i]
                                                 module:mod
                                                context:ctx]];
                }
            [line appendFormat:@" %@, [%@], %@, %@",
                               [self stringFromOperand:callee
                                                module:mod
                                               context:ctx],
                               [args componentsJoinedByString:@", "],
                               [self stringFromCallConv:insn.callConv],
                               [self stringFromOperand:memOp
                                                module:mod
                                               context:ctx]];
            }
        break;
        }
    case XTIROpICmp:
    case XTIROpVICmp:
    case XTIROpFCmp:
        {
        // ICmp <pred>, %a, %b
        //
        // VICmp is here because its predicate is the SAME integer enum and
        // it must survive the text. It used to fall to the generic case,
        // which prints operands only — so `VICmp %200, %184` reached the
        // back end with no predicate at all. In-process that is invisible
        // (the opcode is created after parsing and the enum is still in
        // memory), so the original never noticed; anything reading the
        // TEXT, which is every consumer of --dump-opt-ir and the whole
        // ported pipeline, got a compare with no operator.
        static NSString* const iPred[] = {@"EQ", @"NE", @"SLT", @"SGT", @"SLE", @"SGE",
                                          @"ULT", @"UGT", @"ULE", @"UGE"};
        static NSString* const fPred[] = {@"OEQ", @"ONE", @"OLT", @"OGT", @"OLE", @"OGE"};
        NSString* predStr = nil;
        if ((insn.opcode == XTIROpICmp || insn.opcode == XTIROpVICmp) && insn.predicate < sizeof(iPred) / sizeof(iPred[0]))
            {
            predStr = iPred[insn.predicate];
            }
        else if (insn.opcode == XTIROpFCmp && insn.predicate < sizeof(fPred) / sizeof(fPred[0]))
            {
            predStr = fPred[insn.predicate];
            }
        else
            {
            predStr = [NSString stringWithFormat:@"P%u", (unsigned)insn.predicate];
            }
        [line appendFormat:@" %@", predStr];
        for (XTIROperand* op in insn.operands)
            {
            [line appendFormat:@", %@", [self stringFromOperand:op module:mod context:ctx]];
            }
        break;
        }
    default:
        {
        // Generic: comma-separated operand list.
        NSMutableArray<NSString*>* parts = [NSMutableArray array];
        for (XTIROperand* op in insn.operands)
            {
            [parts addObject:[self stringFromOperand:op module:mod context:ctx]];
            }
        if (parts.count > 0)
            {
            [line appendString:@" "];
            [line appendString:[parts componentsJoinedByString:@", "]];
            }
        break;
        }
        }
    return line;
    }

#pragma mark - Function rendering

+ (NSString*)stringFromFunctionSignatureLanguage:(XTIRFunction*)fn
                                          module:(XTIRModule*)mod
    {
    // Language-level: strip the trailing Mem from params; return Mem
    // is also implicit.
    NSMutableArray<NSString*>* paramStrs = [NSMutableArray array];
    NSUInteger paramCount = fn.paramTypes.count;
    NSUInteger keep = paramCount;
    if (keep > 0 && [fn.paramTypes[keep - 1] kind] == XTIRTypeKindMemory)
        keep--;
    for (NSUInteger i = 0; i < keep; i++)
        {
        [paramStrs addObject:[self stringFromType:fn.paramTypes[i] module:mod]];
        }
    return [NSString stringWithFormat:@"(%@) -> %@",
                                      [paramStrs componentsJoinedByString:@", "],
                                      [self stringFromType:fn.returnType
                                                    module:mod]];
    }

+ (NSString*)stringFromFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    XTIRPrintContext* ctx = [self buildContextForFunction:fn];

    NSMutableString* out = [NSMutableString string];

    // Header: function name(%0:T, %1:T, ..., %N:Mem) -> (T, Mem)
    NSMutableArray<NSString*>* paramStrs = [NSMutableArray array];
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        {
        XTIRValue* v = [fn valueForId:(XTIRValueId)i];
        NSString* name = v ? [ctx nameForValueId:v.valueId]
                           : [NSString stringWithFormat:@"%%%lu", (unsigned long)i];
        [paramStrs addObject:[NSString stringWithFormat:@"%@: %@",
                                                        name,
                                                        [self stringFromType:fn.paramTypes[i]
                                                                      module:mod]]];
        }
    NSString* retStr;
    if (fn.returnType.kind == XTIRTypeKindVoid)
        {
        retStr = @"Mem";
        }
    else
        {
        retStr = [NSString stringWithFormat:@"(%@, Mem)",
                                            [self stringFromType:fn.returnType
                                                          module:mod]];
        }
    [out appendFormat:@"  function %@(%@) -> %@ {\n",
                      fn.name,
                      [paramStrs componentsJoinedByString:@", "],
                      retStr];

    // Frame info.
    if (fn.frameInfo.pinnedLocals.count > 0 || fn.frameInfo.pinnedLocalSize > 0)
        {
        NSMutableArray<NSString*>* slotStrs = [NSMutableArray array];
        for (XTIRPinnedLocal* local in fn.frameInfo.pinnedLocals)
            {
            // `esc` marks a local whose address escapes via a pointer
            // (`&`-taken / passed by address). The xt6502 backend routes
            // these to stable frame spill instead of the per-function ZP
            // pin pool; losing the flag on round-trip mis-routes them to
            // a static ZP slot that aliases across calls (legs=64 bug).
            [slotStrs addObject:[NSString stringWithFormat:@"(%@:%@ @%u%@)",
                                                           [ctx nameForValueId:local.valueId],
                                                           [self stringFromType:local.type
                                                                         module:mod],
                                                           (unsigned)local.byteOffset,
                                                           local.escapesViaPointer ? @" esc" : @""]];
            }
        [out appendFormat:@"    frame: { pinned: [%@], size: %u }\n",
                          [slotStrs componentsJoinedByString:@", "],
                          (unsigned)fn.frameInfo.pinnedLocalSize];
        }

    // `unroll: [bb_x, ...]` — the loop headers `: unroll` asked for. Emitted
    // ONLY when non-empty, exactly as `frame:` above is emitted only when there
    // are pinned locals: a line on every function would move the expected IR
    // text of every fixture in the tree, and ir-diff / irwide-diff / opt-diff
    // all compare that text. Sorted, because a set has no order and the IR text
    // is a byte-for-byte contract between two implementations.
    if (fn.forcedUnrollHeaders.count > 0)
        {
        NSArray<NSString*>* names =
            [fn.forcedUnrollHeaders.allObjects sortedArrayUsingSelector:@selector(compare:)];
        [out appendFormat:@"    unroll: [%@]\n",
                          [names componentsJoinedByString:@", "]];
        }

    // Blocks.
    for (XTIRBlock* block in fn.blocks)
        {
        [out appendFormat:@"    %@:\n", block.name ?: @"bb_?"];
        NSArray<NSString*>* preds = [self predsForBlock:block inFunction:fn];
        if (preds.count == 0)
            {
            [out appendString:@"      preds: -\n"];
            }
        else
            {
            [out appendFormat:@"      preds: %@\n",
                              [preds componentsJoinedByString:@", "]];
            }
        for (XTIRInsn* phi in block.phiNodes)
            {
            [out appendFormat:@"      %@\n",
                              [self stringFromInsn:phi
                                            module:mod
                                           context:ctx]];
            }
        for (XTIRInsn* insn in block.instructions)
            {
            [out appendFormat:@"      %@\n",
                              [self stringFromInsn:insn
                                            module:mod
                                           context:ctx]];
            }
        if (block.terminator)
            {
            [out appendFormat:@"      %@\n",
                              [self stringFromInsn:block.terminator
                                            module:mod
                                           context:ctx]];
            }
        }

    [out appendString:@"  }\n"];
    return out;
    }

#pragma mark - Symbol rendering

+ (NSString*)stringFromAttributes:(NSDictionary<NSString*, NSNumber*>*)attrs
    {
    if (attrs.count == 0)
        return @"";
    NSArray<NSString*>* keys = [attrs.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    for (NSString* k in keys)
        {
        NSNumber* v = attrs[k];
        [parts addObject:[NSString stringWithFormat:@"%@: %@",
                                                    k, v.boolValue ? @"true" : @"false"]];
        }
    return [NSString stringWithFormat:@"\n    attributes: { %@ }",
                                      [parts componentsJoinedByString:@", "]];
    }

// Append explicit "escapes" / "volatile" / "taskLocal" flags to an
// attributes line whenever the symbol carries one. These ride on the
// dedicated XTIRSymbol properties (set via the factory-method
// initializer for dataGlobal symbols) rather than the generic
// `attributes` NSDictionary, so the bare stringFromAttributes:
// loses them. The XTIROptDeadFunctionElim pass keys off sym.escapes
// to decide whether a function symbol's address might have been
// taken outside the visible IR; without round-trip preservation
// the post-parse module had no escapes-marked symbols and DFE was
// over-aggressive on the subprocess path.
+ (NSString*)stringFromIntrinsicFlags:(XTIRSymbol*)sym
    {
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    if (sym.escapes)
        [parts addObject:@"escapes: true"];
    if (sym.volatileAccess)
        [parts addObject:@"volatile: true"];
    if (sym.taskLocal)
        [parts addObject:@"taskLocal: true"];
    if (parts.count == 0)
        return @"";
    return [NSString stringWithFormat:@"\n    flags: { %@ }",
                                      [parts componentsJoinedByString:@", "]];
    }

+ (NSString*)stringFromSymbol:(XTIRSymbol*)sym module:(XTIRModule*)mod
    {
    NSMutableString* out = [NSMutableString string];
    switch (sym.kind)
        {
    case XTIRSymbolKindFunction:
        {
        NSString* sig;
        if (sym.function)
            {
            sig = [self stringFromFunctionSignatureLanguage:sym.function module:mod];
            }
        else if (sym.functionType)
            {
            sig = @"() -> Void";
            }
        else
            {
            sig = @"() -> Void";
            }
        [out appendFormat:@"  symbol %@: function %@%@%@\n",
                          sym.name, sig, [self stringFromAttributes:sym.attributes],
                          [self stringFromIntrinsicFlags:sym]];
        break;
        }
    case XTIRSymbolKindDataGlobal:
        {
        NSString* typeStr = sym.globalType
                                ? [self stringFromType:sym.globalType module:mod]
                                : @"?";
        NSMutableString* init = [NSMutableString string];
        if (sym.initialBytes.length)
            {
            [init appendString:@" init ["];
            const uint8_t* p = sym.initialBytes.bytes;
            for (NSUInteger i = 0; i < sym.initialBytes.length; i++)
                {
                if (i > 0)
                    [init appendString:@", "];
                [init appendFormat:@"#$%02X", p[i]];
                }
            [init appendString:@"]"];
            }
        [out appendFormat:@"  symbol %@: dataglobal %@%@%@%@\n",
                          sym.name, typeStr, init, [self stringFromAttributes:sym.attributes],
                          [self stringFromIntrinsicFlags:sym]];
        break;
        }
    case XTIRSymbolKindRuntimeHelper:
        [out appendFormat:@"  symbol %@: runtime () -> Void%@\n",
                          sym.name, [self stringFromAttributes:sym.attributes]];
        break;
    case XTIRSymbolKindZpEquate:
        [out appendFormat:@"  symbol %@: zpequate $%04x%@\n",
                          sym.name, sym.address, [self stringFromAttributes:sym.attributes]];
        break;
    case XTIRSymbolKindStringLit:
        {
        NSMutableString* b = [NSMutableString string];
        if (sym.stringBytes.length)
            {
            [b appendString:@" ["];
            const uint8_t* p = sym.stringBytes.bytes;
            for (NSUInteger i = 0; i < sym.stringBytes.length; i++)
                {
                if (i > 0)
                    [b appendString:@", "];
                [b appendFormat:@"#$%02X", p[i]];
                }
            [b appendString:@"]"];
            }
        [out appendFormat:@"  symbol %@: stringlit%@%@\n",
                          sym.name, b, [self stringFromAttributes:sym.attributes]];
        break;
        }
    case XTIRSymbolKindVTable:
        {
        // Emit the slot list inline so virtual-dispatch targets
        // survive the IR text round-trip. Without it the parser
        // rebuilt an EMPTY vtable, dead-function-elim couldn't seed
        // the virtual methods, and the backend emitted a null table
        // (dispatch → $0000). An empty-name slot prints as `_`.
        NSMutableString* slots = [NSMutableString string];
        NSArray<NSString*>* entries = sym.vtableEntryNames;
        if (entries.count)
            {
            [slots appendString:@" ["];
            for (NSUInteger i = 0; i < entries.count; i++)
                {
                if (i)
                    [slots appendString:@", "];
                NSString* e = entries[i];
                [slots appendString:(e.length ? e : @"_")];
                }
            [slots appendString:@"]"];
            }
        [out appendFormat:@"  symbol %@: vtable%@%@\n",
                          sym.name, slots, [self stringFromAttributes:sym.attributes]];
        break;
        }
        }
    return out;
    }

#pragma mark - Module

// Emit each constant in the module's constants pool as
//   constant N: kind=<int|float|string|agg> [bytes=[...]|value=<v>|elements=...]
// One per line. The constant pool is referenced from instruction
// operands via `#cpool:N`; without re-dumping/reading it back, parsed
// modules ended up with mod.constants empty and any ConstAgg-bearing
// instruction (e.g. inline asm) referenced garbage. Currently only
// string-kind constants are exercised by the corpus inline-asm path;
// the others are dumped in a tolerant shape for future use.
+ (void)appendConstantsForModule:(XTIRModule*)mod into:(NSMutableString*)out
    {
    if (mod.constants.count == 0)
        return;
    for (NSUInteger i = 0; i < mod.constants.count; i++)
        {
        XTIRConstant* c = mod.constants[i];
        [out appendFormat:@"  constant %lu: ", (unsigned long)i];
        if (c.kind == XTIRConstantKindString)
            {
            [out appendString:@"string bytes=["];
            const uint8_t* b = c.stringBytes.bytes;
            for (NSUInteger k = 0; k < c.stringBytes.length; k++)
                {
                if (k > 0)
                    [out appendString:@", "];
                [out appendFormat:@"#$%02X", b[k]];
                }
            [out appendString:@"]"];
            }
        else if (c.kind == XTIRConstantKindInt)
            {
            [out appendFormat:@"int value=%lld", c.intValue];
            }
        else if (c.kind == XTIRConstantKindFloat)
            {
            [out appendFormat:@"float bits=%llu", c.floatRawBytes];
            }
        else if (c.kind == XTIRConstantKindAgg)
            {
            // Aggregate constants would need recursive emission; the
            // corpus doesn't exercise them through this path yet.
            [out appendString:@"agg (sub-elements not yet round-tripped)"];
            }
        [out appendString:@"\n"];
        }
    }

// Emit each layout in the module's layoutTable as
//   layout N: size=<size> align=<align> fields=[(off:<type>), ...]
// One per line. Empty fields list is allowed (anonymous byte-block
// aggregates such as `u8 vals[6]` have size 6, alignment 1, no fields).
// The parser reads these in order so layoutTable[N] matches the index
// the rest of the IR uses in `Agg(N)`.
+ (void)appendLayoutsForModule:(XTIRModule*)mod into:(NSMutableString*)out
    {
    if (mod.layoutTable.count == 0)
        return;
    for (NSUInteger i = 0; i < mod.layoutTable.count; i++)
        {
        XTIRLayout* layout = mod.layoutTable[i];
        [out appendFormat:@"  layout %lu: size=%u align=%u",
                          (unsigned long)i, (unsigned)layout.size, (unsigned)layout.alignment];
        if (layout.fields.count > 0)
            {
            [out appendString:@" fields=["];
            BOOL first = YES;
            for (XTIRLayoutField* f in layout.fields)
                {
                if (!first)
                    [out appendString:@", "];
                first = NO;
                [out appendFormat:@"(%u:%@)",
                                  (unsigned)f.byteOffset, [self stringFromType:f.type module:mod]];
                }
            [out appendString:@"]"];
            }
        [out appendString:@"\n"];
        }
    }

+ (NSString*)stringFromModule:(XTIRModule*)mod
    {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"module \"%@\" {\n", mod.name];
    [self appendLayoutsForModule:mod into:out];
    [self appendConstantsForModule:mod into:out];
    // Load-time constructors (run before main): one `modinit "<fn>"` per name.
    for (NSString* initName in mod.moduleInitFunctionNames)
        {
        [out appendFormat:@"  modinit \"%@\"\n", initName];
        }
    for (XTIRSymbol* sym in mod.symbols)
        {
        [out appendString:[self stringFromSymbol:sym module:mod]];
        }
    for (XTIRFunction* fn in mod.functions)
        {
        [out appendString:[self stringFromFunction:fn module:mod]];
        }
    [out appendString:@"}\n"];
    return out;
    }

@end
