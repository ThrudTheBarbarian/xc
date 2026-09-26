// XTArm9Backend.m — ARMv7-A (A32) emitter. Foundation: slot-per-value,
// load → op → store. See the header for coverage + the ABI note.
#import "XTArm9Backend.h"
#import "XTAggInitRelay.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIROpcode.h"
#import "XTIRSupport.h"
#import "XTIRConstant.h"
#import "XTIRLayout.h"
#import "XTHomingAllocator.h"

// Reserved `slot` dict key holding the byte offset of the saved sret result
// pointer (a function returning a >4-byte aggregate saves the incoming r0 here
// at entry; Return reloads it). Out of the value-id range.
static const XTIRValueId kSretSlotKey = (XTIRValueId)-1;

// Position-independent codegen (Tier-2 ET_DYN). See the header.
static BOOL sPIC = NO;
static BOOL sEmitLib = NO;
// Register-homing map for the function currently being emitted (valueId → reg
// name), or nil when homing is off. Set at the top of emitFunction:. Consulted
// by loadOperand/storeResult so a homed value reads/writes its register instead
// of stack-slot churn. Dual-write (slot stays valid) keeps direct-slot readers
// (stack-passed call args, sret) correct. See XTHomingAllocator.
static NSDictionary<NSNumber*, NSString*>* sHome = nil;

// Vector (NEON) register assignment: valueId → q-register index (8..15). Set at
// the top of emitFunction:. q8-q15 (d16-d31) are NEON-only and caller-saved, so
// they never collide with the scalar VFP code (d0-d15) and — since the
// vectoriser only produces call-free inner loops — need no save/restore.
static NSDictionary<NSNumber*, NSNumber*>* sVecReg = nil;

// valueId → defining instruction, for tracing operands (e.g. a VSplat scalar
// back to a compile-time constant). Set at the top of emitFunction:.
static NSDictionary<NSNumber*, XTIRInsn*>* sDefOf = nil;

// Pure Const/ext instructions whose ONLY consumers are constant-inlined VSplats
// (see the VSplat lowering). Their result is materialised inline as an immediate,
// so emitting them (and their slot store) is dead work — skip it.
static NSSet<NSNumber*>* sNoEmit = nil;

// ICmp results consumed ONLY by their block's CondBranch (populated in the
// per-function pre-scan). The compare is not emitted where it appears; the
// terminator re-emits `cmp` and branches on the condition directly, so the
// boolean is never materialised. arm9 was spending FIVE instructions on it —
// `cmp` / `mov rD,#0` / `mov<cc> rD,#1` / copies / `cmp rD,#0` / `beq` — in
// every loop test, where arm64 (#529) spends two.
static NSSet<NSNumber*>* sFusedCmp = nil;

// Bytes of outgoing-argument area at the bottom of the current frame; stores
// below this offset belong to a CALLEE and are never dead here.
static NSUInteger sOutArgBytes = 0;

// Post-index vld1/vst1 fusion (populated per-function in the pre-scan): maps a
// pointer-IV value id → the ElementAddr that advances it by one vector width.
// A VLoad/VStore through that pointer emits `[rN]!` (auto-incrementing rN by 16)
// and writes the advanced rN to the ElementAddr's home, so the separate advance
// `add` is skipped (its result id lands in sNoEmit).
static NSDictionary<NSNumber*, XTIRInsn*>* sPostIncEA = nil;

@implementation XTArm9Backend

+ (void)setPIC:(BOOL)pic
    {
    sPIC = pic;
    }
+ (BOOL)pic
    {
    return sPIC;
    }
+ (void)setEmitLib:(BOOL)lib
    {
    sEmitLib = lib;
    }

// ── helpers ────────────────────────────────────────────────────────────────

+ (BOOL)isMemValue:(nullable XTIRValue*)v
    {
    return v && v.type && v.type.kind == XTIRTypeKindMemory;
    }

// ── A32-native type sizing ───────────────────────────────────────────────────
// AArch32 is a 32-bit machine: pointers are 4 bytes (unlike arm64's 8). The
// shared XTIRLayout carries 2-byte-pointer (Atari) offsets, so — exactly like
// the arm64 backend — we recompute aggregate sizes / field offsets in A32-native
// widths so a pointer-bearing struct lays out with 4-byte pointer fields.

+ (NSUInteger)fieldWidth:(nullable XTIRType*)t
    {
    if (!t)
        return 0;
    switch (t.kind)
        {
    case XTIRTypeKindPtr:
        return 4; // 32-bit host pointer
    case XTIRTypeKindF64:
        return 8;
    case XTIRTypeKindF32:
    case XTIRTypeKindI32:
    case XTIRTypeKindU32:
        return 4;
    // 8 even where the ARITHMETIC is not implemented yet. The width is a
    // layout contract — a struct's IR offsets are the front-end widths
    // summed, and the back end reads them with its own — so a disagreement
    // does not surface as "unsupported", it surfaces as a wrong address in
    // optimised code. Unsupported OPERATIONS are rejected per-op instead.
    case XTIRTypeKindI64:
    case XTIRTypeKindU64:
        return 8;
    case XTIRTypeKindI16:
    case XTIRTypeKindU16:
        return 2;
    case XTIRTypeKindI8:
    case XTIRTypeKindU8:
    case XTIRTypeKindBool:
        return 1;
    case XTIRTypeKindAgg:
        return [self aggSize:t.layout];
    default:
        return 0; // Void / Memory
        }
    }

+ (NSUInteger)aggSize:(nullable XTIRLayout*)layout
    {
    if (!layout)
        return 0;
    NSUInteger total = 0;
    for (XTIRLayoutField* f in layout.fields)
        total += [self fieldWidth:f.type];
    // A field-less / opaque buffer carries its size in layout.size; never
    // size below it. For a pointer-bearing struct the A32 field sum (4-byte
    // pointers) exceeds the 2-byte-pointer layout.size, so the sum wins.
    if (total < layout.size)
        total = layout.size;
    return total;
    }

// Byte offset of field `idx` — the RECORDED layout offset. The front end
// lays fields out once (per-target field-alignment cap, blewit #5) and every
// backend reads the same offsets; widths still must match the FE's (the
// type-width invariant) or loads/stores are mis-sized.
+ (NSUInteger)fieldOffset:(nullable XTIRLayout*)layout index:(NSUInteger)idx
    {
    if (!layout || idx >= layout.fields.count)
        return [self aggSize:layout];
    return layout.fields[idx].byteOffset;
    }

// Element stride of an ElementAddr (A32-native pointee size).
+ (uint32_t)elemSizeFor:(XTIRInsn*)a fn:(XTIRFunction*)fn
    {
    uint32_t elemSize = 1;
    XTIROperand* baseOp = a.operands[0];
    if (baseOp.kind == XTIROperandKindUse)
        {
        XTIRType* pte = fn.values[@(baseOp.valueId)].type.pointeeType;
        if (pte)
            elemSize = (uint32_t)([self fieldWidth:pte] ?: 1);
        }
    return elemSize;
    }

// Byte offset of a FieldAddr's field (A32-native widths).
+ (uint32_t)fieldByteOffsetFor:(XTIRInsn*)a fn:(XTIRFunction*)fn
    {
    XTIROperand* baseOp = a.operands[0];
    if (baseOp.kind == XTIROperandKindUse)
        {
        XTIRType* pte = fn.values[@(baseOp.valueId)].type.pointeeType;
        if (pte && pte.kind == XTIRTypeKindAgg && pte.layout)
            return (uint32_t)[self fieldOffset:pte.layout index:(NSUInteger)a.operands[1].intValue];
        }
    return 0;
    }

+ (NSString*)blockLabel:(XTIRBlock*)b fn:(XTIRFunction*)fn
    {
    return [NSString stringWithFormat:@".L_%@_%@", fn.name, b.name ?: @"b"];
    }

// ── AAPCS32 aggregate calling convention ─────────────────────────────────────
// A composite return > 4 bytes goes via memory: the caller passes a hidden
// pointer to result storage in r0 (sret), and the real args shift to r1+. A
// composite ≤ 4 bytes is returned in r0.
+ (BOOL)returnsViaSret:(nullable XTIRType*)t
    {
    return t && t.kind == XTIRTypeKindAgg && [self aggSize:t.layout] > 4;
    }

// Words (4-byte units) an argument of `t` occupies in the AAPCS32 arg sequence.
// A double (F64) is 8 bytes = 2 words; everything else (incl. F32, ptr) is 1.
+ (NSUInteger)argWordsForType:(nullable XTIRType*)t
    {
    if (t && t.kind == XTIRTypeKindAgg)
        {
        NSUInteger w = ([self aggSize:t.layout] + 3) / 4;
        return w ? w : 1;
        }
    // i64/u64 occupy two words exactly as an F64 does. The AAPCS classifier
    // below reads this, so getting it right here is most of what an eight-byte
    // type needs to be passed and returned correctly.
    return (t && (t.kind == XTIRTypeKindF64 || t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64)) ? 2 : 1;
    }

// Does an argument of `t` require 8-byte (even-register / 8-aligned-stack)
// placement? F64 does; u8/u16/u32/F32/ptr structs do not (≤4-aligned).
+ (BOOL)argNeeds8Align:(nullable XTIRType*)t
    {
    return t && (t.kind == XTIRTypeKindF64 || t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64);
    }

// Classify a call's arguments into core-register / stack locations per AAPCS32.
// `ncrn` (next core register, 0–3) starts at 1 when sret consumes r0. A composite
// that fits in the remaining core registers goes there; one that doesn't, when no
// stack arg has been placed yet, SPLITS across the remaining registers and the
// stack (AAPCS32 §6.4.1 C.5); after that everything stacks. (8-byte alignment for
// double/i64-bearing aggregates is not modelled yet — all current fixtures are
// ≤4-aligned.) Returns one @[regStart, regWords, stackOff, stackWords] per arg;
// *outStackBytes = total outgoing stack bytes (the reserved outgoing area).
+ (NSArray<NSArray<NSNumber*>*>*)classifyArgTypes:(NSArray<XTIRType*>*)types
                                             sret:(BOOL)sret
                                    outStackBytes:(NSUInteger*)outStackBytes
    {
    return [self classifyArgTypes:types
                             sret:sret
                         varargAt:NSNotFound
                    outStackBytes:outStackBytes];
    }

// `varargAt` is the index at which the VARIADIC tail begins, or NSNotFound.
//
// An xtc variadic on this target starts its tail 8-ALIGNED, which plain AAPCS
// does not require. The reason is forwarding: a forwarder relays its own tail
// into the callee's slots word for word, and the callee re-aligns 8-byte reads
// against its own base — so if the two bases differ in 8-alignment, every
// `double` in the tail is read one word out. `withFormat(fmt, …)` has one named
// word and `appendFormat(self, fmt, …)` has two, which is exactly that case:
// `%d` and `%s` came through and `%f` read 0.
//
// Making every tail start even removes the class of bug rather than detecting
// it. Both sides apply the rule — the caller here, the callee in its vaListOff —
// and C-ABI callees are excluded, since libc follows plain AAPCS. private:docs/bugs/047.
+ (NSArray<NSArray<NSNumber*>*>*)classifyArgTypes:(NSArray<XTIRType*>*)types
                                             sret:(BOOL)sret
                                         varargAt:(NSUInteger)varargAt
                                    outStackBytes:(NSUInteger*)outStackBytes
    {
    NSMutableArray<NSArray<NSNumber*>*>* res = [NSMutableArray array];
    NSUInteger ncrn = sret ? 1 : 0;
    NSUInteger nsaa = 0; // stack bytes used so far
    BOOL stacked = NO;
    NSUInteger argIdx = 0;
    for (XTIRType* t in types)
        {
        // 8-align the tail's base
        if (argIdx == varargAt)
            {
            if (!stacked && (ncrn & 1))
                ncrn++;
            if (stacked && (nsaa & 7))
                nsaa += 4;
            }
        argIdx++;
        NSUInteger words = [self argWordsForType:t];
        // C.3: even-align a double
        if ([self argNeeds8Align:t])
            {
            if (!stacked && (ncrn & 1))
                ncrn++;
            if (stacked && (nsaa & 7))
                nsaa += 4;
            }
        NSUInteger regStart = 0, regWords = 0, stackOff = 0, stackWords = 0;
        if (!stacked && ncrn + words <= 4)
            {
            regStart = ncrn;
            regWords = words;
            ncrn += words;
            }
        else if (!stacked && ncrn < 4)
            {
            regStart = ncrn;
            regWords = 4 - ncrn; // split: fill r{ncrn}..r3
            stackWords = words - regWords;
            stackOff = nsaa;
            nsaa += stackWords * 4;
            ncrn = 4;
            stacked = YES;
            }
        else
            {
            stacked = YES;
            stackOff = nsaa;
            stackWords = words;
            nsaa += words * 4;
            }
        [res addObject:@[ @(regStart), @(regWords), @(stackOff), @(stackWords) ]];
        }
    if (outStackBytes)
        *outStackBytes = nsaa;
    return res;
    }

// Is `v` representable as an ARM data-processing modified immediate (an 8-bit
// value rotated right by an even amount)? Add/sub/cmp etc. require this; a frame
// size or pinned-local offset that fails it must go through a scratch register.
static BOOL arm9EncodableImm(uint32_t v)
    {
    for (int rot = 0; rot < 16; rot++)
        {
        int s = rot * 2;
        uint32_t rotated = (s == 0) ? v : ((v << s) | (v >> (32 - s)));
        if (rotated <= 0xFF)
            return YES;
        }
    return NO;
    }

// Emit `op dst, lhs, #imm`, falling back to a scratch-register form
// (`movw/movt scratch,#imm` + `op dst, lhs, scratch`) when imm isn't an
// ARM-encodable modified immediate. `op` is "add" or "sub". `scratch` must be a
// register free at the call site (r12/ip in prologue/epilogue; a temp elsewhere).
+ (void)emitAlu:(NSString*)op dst:(NSString*)dst lhs:(NSString*)lhs
            imm:(NSUInteger)imm
        scratch:(NSString*)scratch
            out:(NSMutableString*)out
    {
    if (imm == 0)
        {
        if (![dst isEqualToString:lhs])
            [out appendFormat:@"\tmov\t%@, %@\n", dst, lhs];
        return;
        }
    if (arm9EncodableImm((uint32_t)imm))
        {
        [out appendFormat:@"\t%@\t%@, %@, #%lu\n", op, dst, lhs, (unsigned long)imm];
        }
    else
        {
        [self emitMovImm:(int64_t)imm reg:scratch into:out];
        [out appendFormat:@"\t%@\t%@, %@, %@\n", op, dst, lhs, scratch];
        }
    }

// Materialise an arbitrary 32-bit immediate into a register (ARMv7 movw/movt).
+ (void)emitMovImm:(int64_t)imm reg:(NSString*)reg into:(NSMutableString*)out
    {
    uint32_t u = (uint32_t)imm;
    [out appendFormat:@"\tmovw\t%@, #%u\n", reg, (unsigned)(u & 0xFFFF)];
    if ((u >> 16) & 0xFFFF)
        [out appendFormat:@"\tmovt\t%@, #%u\n", reg, (unsigned)((u >> 16) & 0xFFFF)];
    }

// Load an operand into `reg`: an SSA use from its frame slot (byte offset), an
// immediate via movw/movt.
+ (void)loadOperand:(XTIROperand*)op into:(NSString*)reg
               slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindUse)
        {
        NSString* home = sHome[@(op.valueId)];
        // homed → read the register
        if (home)
            {
            if (![home isEqualToString:reg])
                [out appendFormat:@"\tmov\t%@, %@\n", reg, home];
            return;
            }
        NSNumber* s = slot[@(op.valueId)];
        if (s)
            [self emitSpAccess:@"ldr" reg:reg off:s.unsignedIntegerValue out:out];
        else
            [out appendFormat:@"\tmov\t%@, #0\t\t@ phantom/unslotted %%%u\n", reg, (unsigned)op.valueId];
        }
    else if (op.kind == XTIROperandKindImmI)
        {
        [self emitMovImm:op.intValue reg:reg into:out];
        }
    else
        {
        [out appendFormat:@"\tmov\t%@, #0\t\t@ TODO operand kind %d\n", reg, (int)op.kind];
        }
    }

+ (void)storeResult:(XTIRValue*)v from:(NSString*)reg
               slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                out:(NSMutableString*)out
    {
    // Homed value: keep it live in its register. Dual-write — the str below stays
    // so a direct-slot reader (stack-passed call arg, sret copy) sees valid data.
    NSString* home = sHome[@(v.valueId)];
    if (home && ![home isEqualToString:reg])
        [out appendFormat:@"\tmov\t%@, %@\n", home, reg];
    NSNumber* s = slot[@(v.valueId)];
    if (s)
        [self emitSpAccess:@"str" reg:reg off:s.unsignedIntegerValue out:out];
    }

// Keep a block copy's base register in range. The copy walks a struct one chunk
// at a time with `[addr, #i]`, and A32 only reaches 4095 — so a struct bigger
// than 4 KB (an embedded buffer is enough) would emit an unencodable offset,
// the same defect as the vtable slot load above and just as silent. Advance the
// base instead and return the new bias to subtract from later offsets. The
// caller must own `addr`: all four call sites load it into r1 and drop it when
// the copy ends.
+ (NSUInteger)rebase:(NSString*)addr off:(NSUInteger)off bias:(NSUInteger)bias
                 out:(NSMutableString*)out
    {
    if (off - bias <= 4092)
        return bias;
    NSUInteger step = (off - bias) & ~(NSUInteger)0xFFF; // multiple of 4096 => encodable
    [out appendFormat:@"\tadd\t%@, %@, #%lu\n", addr, addr, (unsigned long)step];
    return bias + step;
    }

// Aggregate copy from memory [addr] into a value's frame slot (struct Load),
// in word-then-byte chunks (a single ldr would drop everything past 4 bytes).
+ (void)emitBlockCopyToSlot:(XTIRValue*)v from:(NSString*)addr size:(NSUInteger)size
                       slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                        out:(NSMutableString*)out
    {
    NSNumber* s = slot[@(v.valueId)];
    if (!s)
        return;
    NSUInteger base = s.unsignedIntegerValue, i = 0, bias = 0;
    for (; i + 4 <= size; i += 4)
        {
        bias = [self rebase:addr off:i bias:bias out:out];
        [out appendFormat:@"\tldr\tr2, [%@, #%lu]\n", addr, (unsigned long)(i - bias)];
        [self emitSpAccess:@"str" reg:@"r2" off:base + i out:out];
        }
    for (; i < size; i++)
        {
        bias = [self rebase:addr off:i bias:bias out:out];
        [out appendFormat:@"\tldrb\tr2, [%@, #%lu]\n", addr, (unsigned long)(i - bias)];
        [self emitSpAccess:@"strb" reg:@"r2" off:base + i out:out];
        }
    }

// Aggregate copy from a value's frame slot to memory [addr] (struct Store).
+ (void)emitBlockCopyFromSlot:(XTIRValue*)v to:(NSString*)addr size:(NSUInteger)size
                         slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                          out:(NSMutableString*)out
    {
    NSNumber* s = slot[@(v.valueId)];
    if (!s)
        return;
    NSUInteger base = s.unsignedIntegerValue, i = 0, bias = 0;
    for (; i + 4 <= size; i += 4)
        {
        [self emitSpAccess:@"ldr" reg:@"r2" off:base + i out:out];
        bias = [self rebase:addr off:i bias:bias out:out];
        [out appendFormat:@"\tstr\tr2, [%@, #%lu]\n", addr, (unsigned long)(i - bias)];
        }
    for (; i < size; i++)
        {
        [self emitSpAccess:@"ldrb" reg:@"r2" off:base + i out:out];
        bias = [self rebase:addr off:i bias:bias out:out];
        [out appendFormat:@"\tstrb\tr2, [%@, #%lu]\n", addr, (unsigned long)(i - bias)];
        }
    }

// Canonicalise `reg` to `ty`'s width/signedness (mask/extend in place). A
// narrow result produced at full register width must be reduced so a direct
// consumer (e.g. an inlined `(u16)&p->y == base+2` comparison) sees equal bits.
+ (void)canonicaliseReg:(NSString*)reg toType:(nullable XTIRType*)ty out:(NSMutableString*)out
    {
    if (!ty)
        return;
    switch (ty.kind)
        {
    case XTIRTypeKindU8:
        [out appendFormat:@"\tand\t%@, %@, #255\n", reg, reg];
        break;
    case XTIRTypeKindBool:
        [out appendFormat:@"\tand\t%@, %@, #1\n", reg, reg];
        break;
    case XTIRTypeKindI8:
        [out appendFormat:@"\tsxtb\t%@, %@\n", reg, reg];
        break;
    case XTIRTypeKindU16:
        [out appendFormat:@"\tuxth\t%@, %@\n", reg, reg];
        break;
    case XTIRTypeKindI16:
        [out appendFormat:@"\tsxth\t%@, %@\n", reg, reg];
        break;
    default:
        break; // U32/I32/Ptr — already full width
        }
    }

// The branch-taken-on-FALSE condition. The unfused shape tests the boolean and
// branches to the false label on `eq`; fused, the same edge is the INVERSE of
// the compare's own condition.
+ (NSString*)invCond:(NSString*)cc
    {
    if ([cc isEqualToString:@"eq"])
        return @"ne";
    if ([cc isEqualToString:@"ne"])
        return @"eq";
    if ([cc isEqualToString:@"lt"])
        return @"ge";
    if ([cc isEqualToString:@"ge"])
        return @"lt";
    if ([cc isEqualToString:@"gt"])
        return @"le";
    if ([cc isEqualToString:@"le"])
        return @"gt";
    if ([cc isEqualToString:@"lo"])
        return @"hs";
    if ([cc isEqualToString:@"hs"])
        return @"lo";
    if ([cc isEqualToString:@"hi"])
        return @"ls";
    if ([cc isEqualToString:@"ls"])
        return @"hi";
    return @"eq";
    }

+ (nullable NSString*)condForICmp:(uint8_t)pred
    {
    switch (pred)
        {
    case XTIRICmpEQ:
        return @"eq";
    case XTIRICmpNE:
        return @"ne";
    case XTIRICmpSLT:
        return @"lt";
    case XTIRICmpSGT:
        return @"gt";
    case XTIRICmpSLE:
        return @"le";
    case XTIRICmpSGE:
        return @"ge";
    case XTIRICmpULT:
        return @"lo";
    case XTIRICmpUGT:
        return @"hi";
    case XTIRICmpULE:
        return @"ls";
    case XTIRICmpUGE:
        return @"hs";
    default:
        return nil;
        }
    }

// ARM condition for an ordered float compare (after vcmp + vmrs APSR_nzcv).
+ (nullable NSString*)condForFCmp:(uint8_t)pred
    {
    switch (pred)
        {
    case XTIRFCmpOEQ:
        return @"eq";
    case XTIRFCmpONE:
        return @"ne";
    case XTIRFCmpOLT:
        return @"mi";
    case XTIRFCmpOGT:
        return @"gt";
    case XTIRFCmpOLE:
        return @"ls";
    case XTIRFCmpOGE:
        return @"ge";
    default:
        return nil;
        }
    }

// Emit `<mnem> reg, [sp, #off]`, staging sp+off into r12 when off exceeds the
// instruction's immediate-offset range. Halfword (strh/ldrh/ldrsh) and signed-
// byte (ldrsb) take an 8-bit offset (255); word/unsigned-byte take 12 bits
// (4095). The scratch is r12 (ip) — the one register never used to carry an
// operand here — so this is safe for ANY data reg except r12 (which callers
// never pass as the data reg). Large frames (>4 KB) hit the staged path; without
// it the assembler rejects `ldr rN, [sp, #4252]` ("bad immediate value").
+ (void)emitSpAccess:(NSString*)mnem reg:(NSString*)reg off:(NSUInteger)off out:(NSMutableString*)out
    {
    BOOL narrow = [mnem isEqualToString:@"strh"] || [mnem isEqualToString:@"ldrh"] || [mnem isEqualToString:@"ldrsh"] || [mnem isEqualToString:@"ldrsb"];
    if (off <= (narrow ? 255u : 4095u))
        {
        [out appendFormat:@"\t%@\t%@, [sp, #%lu]\n", mnem, reg, (unsigned long)off];
        }
    else
        {
        [self emitAlu:@"add" dst:@"r12" lhs:@"sp" imm:off scratch:@"r12" out:out];
        [out appendFormat:@"\t%@\t%@, [r12]\n", mnem, reg];
        }
    }

// Load one 64-bit operand into a register pair. arm9 is LITTLE-endian, so the
// low word sits at the lower address — the opposite of m68k's pack, which is
// exactly the kind of detail that silently swaps halves if copied across.
//
// An immediate is materialised directly: `slot[...]` answers nil for one, and
// reading offset 0 instead would have loaded whatever is at the bottom of the
// frame (the same trap m68k's slotOff: had).
// The IR TYPE an operand is read at (nil when it has none).
+ (nullable XTIRType*)typeOfOperand:(XTIROperand*)op fn:(XTIRFunction*)fn
    {
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = fn.values[@(op.valueId)];
        if (v)
            return v.type;
        }
    return op.type;
    }

+ (void)loadInt64Operand:(XTIROperand*)op lo:(NSString*)lo hi:(NSString*)hi
                    slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                      fn:(XTIRFunction*)fn
                     out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        uint64_t v = (uint64_t)op.intValue;
        [self emitMovImm:(int64_t)(uint32_t)(v & 0xFFFFFFFFu) reg:lo into:out];
        [self emitMovImm:(int64_t)(uint32_t)(v >> 32) reg:hi into:out];
        return;
        }
    NSNumber* s = (op.kind == XTIROperandKindUse) ? slot[@(op.valueId)] : nil;
    // no slot: a phantom or unslotted value — zero, and say so
    if (!s)
        {
        [out appendFormat:@"\tmov\t%@, #0\t\t@ unslotted 64-bit %%%u\n",
                          lo, (unsigned)op.valueId];
        [out appendFormat:@"\tmov\t%@, #0\n", hi];
        return;
        }
    NSUInteger off = s.unsignedIntegerValue;
    [self emitSpAccess:@"ldr" reg:lo off:off out:out];
    [self emitSpAccess:@"ldr" reg:hi off:off + 4 out:out];
    }

// Load a branch or select condition into `reg` as a word that is zero exactly
// when the condition is false. A 64-bit condition ORs its two halves (into
// `scratch` as well): read as its low word alone, `1 << 32` was false (bug 293).
+ (void)loadCondition:(XTIROperand*)op into:(NSString*)reg scratch:(NSString*)scratch
                 slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                   fn:(XTIRFunction*)fn
                  out:(NSMutableString*)out
    {
    XTIRType* t = [self typeOfOperand:op fn:fn];
    if (t && (t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64))
        {
        [self loadInt64Operand:op lo:reg hi:scratch slot:slot fn:fn out:out];
        [out appendFormat:@"\torr\t%@, %@, %@\n", reg, reg, scratch];
        return;
        }
    [self loadOperand:op into:reg slot:slot out:out];
    }

// Emit `ldr reg, [base, #off]` for an off that may exceed A32's 12-bit (4095)
// immediate, where `base` is a register the CALLER OWNS — the high bits are
// folded into it in place. No scratch is needed: what is left over after the
// low 12 bits is always a multiple of 4096, and a multiple of 4096 up to
// 0xFF000 is an encodable rotated immediate, so `add` takes it directly.
//
// This is what a vtable slot load needs. xtc dispatches by method NAME, so a
// slot index is a translation-unit-wide method-name id, and EVERY class's
// vtable is as wide as the number of distinct method names in the whole unit —
// 1377 slots (5508 bytes) in a large library, however few methods a given class
// implements. Folding the offset into the instruction capped a translation unit
// at 1024 method names, and it was a cliff rather than a slope: one name past
// it, every dispatch to a high slot failed to assemble (XG bug 021).
+ (void)emitFarLoad:(NSString*)reg base:(NSString*)base off:(NSUInteger)off
                out:(NSMutableString*)out
    {
    NSUInteger hi = off & ~(NSUInteger)0xFFF;
    while (hi)
        {
        NSUInteger chunk = hi > 0xFF000 ? 0xFF000 : hi; // multiple of 4096 => encodable
        [out appendFormat:@"\tadd\t%@, %@, #%lu\n", base, base, (unsigned long)chunk];
        hi -= chunk;
        }
    [out appendFormat:@"\tldr\t%@, [%@, #%lu]\n", reg, base, (unsigned long)(off & 0xFFF)];
    }

// vldr/vstr (the VFP coprocessor loads) take an offset of ±1020 only. For a
// frame slot beyond that, materialise sp+offset into a scratch base first.
+ (void)emitVfp:(NSString*)mnem reg:(NSString*)reg off:(NSUInteger)off out:(NSMutableString*)out
    {
    if (off <= 1020)
        {
        [out appendFormat:@"\t%@\t%@, [sp, #%lu]\n", mnem, reg, (unsigned long)off];
        }
    else
        {
        [self emitAlu:@"add" dst:@"r12" lhs:@"sp" imm:off scratch:@"r12" out:out];
        [out appendFormat:@"\t%@\t%@, [r12]\n", mnem, reg];
        }
    }

// Load a float operand (a Use in its frame slot) into a VFP register (s/d).
+ (void)vfpLoad:(NSString*)reg operand:(XTIROperand*)op
           slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
            out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindUse)
        {
        NSNumber* s = slot[@(op.valueId)];
        [self emitVfp:@"vldr" reg:reg off:(s ? s.unsignedIntegerValue : 0)out:out];
        }
    else
        {
        [out appendFormat:@"\t@ TODO vfpLoad operand kind %d\n", (int)op.kind];
        }
    }

+ (void)vfpStore:(NSString*)reg result:(XTIRValue*)v
            slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
             out:(NSMutableString*)out
    {
    NSNumber* s = slot[@(v.valueId)];
    if (s)
        [self emitVfp:@"vstr" reg:reg off:s.unsignedIntegerValue out:out];
    }

// Marshal call arguments into AAPCS32 registers + the outgoing stack area, and
// (when `sret`) set r0 to the result-storage address. `args`/`argTypes` are
// parallel arrays of the by-value arguments (the receiver is just args[0] for a
// method call). Shared by Call / CallIndirect / VTblDispatch.
+ (void)marshalArgs:(NSArray<XTIROperand*>*)args types:(NSArray<XTIRType*>*)argTypes
               sret:(BOOL)sret
             result:(nullable XTIRValue*)res
               slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                out:(NSMutableString*)out
    {
    [self marshalArgs:args
                types:argTypes
                 sret:sret
               result:res
             varargAt:NSNotFound
                 slot:slot
                  out:out];
    }

// The index at which `callee`'s variadic tail starts, or NSNotFound when it is
// not an xtc variadic. C-ABI callees (libc printf) are excluded: they follow
// plain AAPCS and must not get the 8-aligned tail.
+ (NSUInteger)varargTailIndexFor:(NSString*)callee module:(XTIRModule*)mod
    {
    if (!callee)
        return NSNotFound;
    XTIRSymbol* sym = [mod symbolForName:callee];
    if (!sym.attributes[@"variadic"].boolValue)
        return NSNotFound;
    if (sym.attributes[@"cabi"].boolValue)
        return NSNotFound;
    if (!sym.function)
        return NSNotFound;
    NSUInteger named = 0;
    for (NSUInteger i = 0; i < sym.function.paramTypes.count; i++)
        {
        XTIRValue* pv = sym.function.values[@(i)];
        if (pv && [self isMemValue:pv])
            continue;
        named++;
        }
    return named;
    }

+ (void)marshalArgs:(NSArray<XTIROperand*>*)args types:(NSArray<XTIRType*>*)argTypes
               sret:(BOOL)sret
             result:(nullable XTIRValue*)res
           varargAt:(NSUInteger)varargAt
               slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                out:(NSMutableString*)out
    {
    NSUInteger stackBytes = 0;
    NSArray<NSArray<NSNumber*>*>* locs =
        [self classifyArgTypes:argTypes
                          sret:sret
                      varargAt:varargAt
                 outStackBytes:&stackBytes];
    // Stack args first (scratch r12) so the subsequent r0–r3 loads aren't clobbered.
    for (NSUInteger i = 0; i < args.count; i++)
        {
        NSArray<NSNumber*>* L = locs[i];
        NSUInteger regWords = L[1].unsignedIntegerValue;
        NSUInteger stOff = L[2].unsignedIntegerValue, stWords = L[3].unsignedIntegerValue;
        if (!stWords)
            continue;
        NSNumber* s = slot[@(args[i].valueId)];
        NSUInteger so = s ? s.unsignedIntegerValue : 0;
        for (NSUInteger k = 0; k < stWords; k++)
            {
            // r0-r3 are still free here (reg args load below), so copy via r0 —
            // emitSpAccess stages large offsets through r12, which must not be
            // the data reg (it would be for the old `r12` copy).
            [self emitSpAccess:@"ldr" reg:@"r0" off:so + 4 * (regWords + k) out:out];
            [self emitSpAccess:@"str" reg:@"r0" off:stOff + 4 * k out:out];
            }
        }
    // Register args into r{regStart}.. (r0–r3).
    for (NSUInteger i = 0; i < args.count; i++)
        {
        NSArray<NSNumber*>* L = locs[i];
        NSUInteger regStart = L[0].unsignedIntegerValue, regWords = L[1].unsignedIntegerValue;
        if (!regWords)
            continue;
        if (regWords == 1 && args[i].kind != XTIROperandKindUse)
            {
            [self loadOperand:args[i]
                         into:[NSString stringWithFormat:@"r%lu", (unsigned long)regStart]
                         slot:slot
                          out:out];
            continue;
            }
        NSNumber* s = slot[@(args[i].valueId)];
        NSUInteger so = s ? s.unsignedIntegerValue : 0;
        for (NSUInteger k = 0; k < regWords; k++)
            [self emitSpAccess:@"ldr"
                           reg:[NSString stringWithFormat:@"r%lu", (unsigned long)(regStart + k)]
                           off:so + 4 * k
                           out:out];
        }
    // r0 = address of the result slot (callee writes the struct there).
    if (sret)
        {
        NSNumber* rs = res ? slot[@(res.valueId)] : nil;
        [self emitAlu:@"add"
                  dst:@"r0"
                  lhs:@"sp"
                  imm:(rs ? rs.unsignedIntegerValue : 0)
                  scratch:@"r12"
                  out:out];
        }
    }

// Store a (non-sret) scalar / small-aggregate / double call result from r0(:r1).
+ (void)storeCallResult:(XTIRValue*)res
                   slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                    out:(NSMutableString*)out
    {
    if (!res || [self isMemValue:res])
        return;
    NSNumber* rs = slot[@(res.valueId)];
    // ≤4-byte agg → r0
    if (res.type && res.type.kind == XTIRTypeKindAgg)
        {
        if (rs)
            [self emitSpAccess:@"str" reg:@"r0" off:rs.unsignedIntegerValue out:out];
        }
    // 8 bytes → r0:r1
    else if (res.type && (res.type.kind == XTIRTypeKindF64 || res.type.kind == XTIRTypeKindI64 || res.type.kind == XTIRTypeKindU64))
        {
        if (rs)
            {
            [self emitSpAccess:@"str" reg:@"r0" off:rs.unsignedIntegerValue out:out];
            [self emitSpAccess:@"str" reg:@"r1" off:rs.unsignedIntegerValue + 4 out:out];
            }
        }
    else
        {
        [self storeResult:res from:@"r0" slot:slot out:out];
        }
    }

// ── per-instruction ─────────────────────────────────────────────────────────

// ── NEON (aarch32 Advanced SIMD) helpers ─────────────────────────────────────

// Data-type suffix for size-agnostic integer ops (add/sub/mul) or float:
// `.i8/.i16/.i32` or `.f32` (2's-complement add/sub/mul are sign-independent).
static NSString* arm9NeonI(XTIRType* lane)
    {
    if (lane && XTIRTypeKindIsFloating(lane.kind))
        return @"f32";
    uint32_t w = lane ? XTIRTypeKindByteWidth(lane.kind) : 4;
    return w == 1 ? @"i8" : w == 2 ? @"i16"
                                   : @"i32";
    }
// Sign-aware suffix for max/min/compare/widen: u8/s8/u16/s16/u32/s32.
static NSString* arm9NeonU(XTIRType* lane)
    {
    uint32_t w = lane ? XTIRTypeKindByteWidth(lane.kind) : 4;
    NSString* bits = w == 1 ? @"8" : w == 2 ? @"16"
                                            : @"32";
    return [((lane && XTIRTypeKindIsSigned(lane.kind)) ? @"s" : @"u") stringByAppendingString:bits];
    }
// Element-size-only suffix for vld1/vst1/vdup: 8/16/32.
static NSString* arm9NeonSz(XTIRType* lane)
    {
    uint32_t w = lane ? XTIRTypeKindByteWidth(lane.kind) : 4;
    return w == 1 ? @"8" : w == 2 ? @"16"
                                  : @"32";
    }
// Trace a value back to a compile-time constant through the def-map, following
// ZExt/SExt/Trunc/Bitcast. Returns YES + the value; used so a VSplat of a
// constant materialises `movw+vdup` instead of the naive Const→slot→ZExt→slot
// reload chain (the dominant per-copy cost in vectorised arm9 loops).
static BOOL arm9TraceConst(XTIRValueId v, int64_t* out)
    {
    for (int d = 0; d < 16; d++)
        {
        XTIRInsn* def = sDefOf[@(v)];
        if (!def || def.operands.count < 1)
            return NO;
        if (def.opcode == XTIROpConst)
            {
            if (def.operands[0].kind != XTIROperandKindImmI)
                return NO;
            if (out)
                *out = def.operands[0].intValue;
            return YES;
            }
        if ((def.opcode == XTIROpZExt || def.opcode == XTIROpSExt || def.opcode == XTIROpTrunc || def.opcode == XTIROpBitcast) && def.operands[0].kind == XTIROperandKindUse)
            {
            v = def.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }
// q-register index (8..15) assigned to a vector value.
+ (NSInteger)vqForValue:(XTIRValueId)v
    {
    NSNumber* q = sVecReg[@(v)];
    return q ? q.integerValue : 8;
    }

// Vector register allocation. Assigns q8..q15 to the vectoriser's Vec-typed SSA
// values via the same coalesce-through-phi + back-edge-aware live-interval
// linear scan the arm64 backend uses (a loop-invariant splat must stay live
// across the back-edge, else a later in-loop vector op reuses its register).
+ (NSDictionary<NSNumber*, NSNumber*>*)assignVectorRegsForFunction:(XTIRFunction*)fn
    {
    NSMutableSet<NSNumber*>* vecVals = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                [vecVals addObject:@(p.result.valueId)];
        for (XTIRInsn* i in bb.instructions)
            if (i.result && i.result.type.kind == XTIRTypeKindVec)
                [vecVals addObject:@(i.result.valueId)];
        }
    if (vecVals.count == 0)
        return @{};

    NSMutableDictionary<NSNumber*, NSNumber*>* canon = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* p in bb.phiNodes)
            {
            if (!p.result || p.result.type.kind != XTIRTypeKindVec)
                continue;
            for (XTIROperand* o in p.operands)
                if (o.kind == XTIROperandKindUse)
                    canon[@(o.valueId)] = @(p.result.valueId);
            }
    XTIRValueId (^classOf)(XTIRValueId) = ^XTIRValueId(XTIRValueId v) {
      NSNumber* c = canon[@(v)];
      return c ? c.unsignedIntegerValue : v;
    };

    NSMutableDictionary<NSNumber*, NSNumber*>* lo = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* hi = [NSMutableDictionary dictionary];
    void (^touch)(XTIRValueId, NSInteger) = ^(XTIRValueId v, NSInteger pos) {
      if (![vecVals containsObject:@(v)])
          return;
      NSNumber* cls = @(classOf(v));
      if (!lo[cls] || pos < lo[cls].integerValue)
          lo[cls] = @(pos);
      if (!hi[cls] || pos > hi[cls].integerValue)
          hi[cls] = @(pos);
    };
    NSInteger pos = 0;
    NSMutableArray<NSNumber*>*blkStart = [NSMutableArray array], *blkEnd = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        [blkStart addObject:@(pos)];
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                touch(insn.result.valueId, pos);
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    touch(o.valueId, pos);
            pos++;
            }
        [blkEnd addObject:@(pos > 0 ? pos - 1 : 0)];
        }
    // Extend any class defined before a natural loop and last-used inside it to
    // the loop's end (back-edge = terminator targeting an earlier/equal block).
    NSUInteger nb = fn.blocks.count;
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        XTIRInsn* t = fn.blocks[bi].terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            NSUInteger tgt = [fn.blocks indexOfObjectIdenticalTo:o.blockRef];
            if (tgt == NSNotFound || tgt > bi)
                continue;
            NSInteger ls = blkStart[tgt].integerValue, le = blkEnd[bi].integerValue;
            for (NSNumber* cls in lo.allKeys)
                if (lo[cls].integerValue < ls && hi[cls].integerValue >= ls && hi[cls].integerValue <= le)
                    hi[cls] = @(le);
            }
        }

    NSArray<NSNumber*>* classes = [lo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
      return [lo[a] compare:lo[b]];
    }];
    NSMutableArray<NSNumber*>* freePool = [NSMutableArray array];
    for (int r = 8; r <= 15; r++)
        [freePool addObject:@(r)];
    NSMutableArray<NSNumber*>* active = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* regOfClass = [NSMutableDictionary dictionary];
    for (NSNumber* cls in classes)
        {
        NSInteger start = lo[cls].integerValue;
        NSMutableArray<NSNumber*>* still = [NSMutableArray array];
        for (NSNumber* a in active)
            {
            if (hi[a].integerValue < start)
                [freePool addObject:regOfClass[a]];
            else
                [still addObject:a];
            }
        [active setArray:still];
        // Exhaustion is a HARD error. The pool cannot grow (q0-q7 alias the
        // scalar VFP d0-d15), and the old `?: @(15)` fallback silently reused
        // a live register — a miscompile, not degraded code (#1198).
        if (freePool.count == 0)
            {
            fprintf(stderr, "xcc-cg-arm9: error: vector register pressure exceeded "
                            "the 8-register NEON pool (q8-q15) in '%s'\n",
                    fn.name.UTF8String);
            exit(1);
            }
        NSNumber* reg = freePool.lastObject;
        [freePool removeLastObject];
        regOfClass[cls] = reg;
        [active addObject:cls];
        [active sortUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
          return [hi[a] compare:hi[b]];
        }];
        }
    NSMutableDictionary<NSNumber*, NSNumber*>* out = [NSMutableDictionary dictionary];
    for (NSNumber* v in vecVals)
        out[v] = regOfClass[@(classOf(v.unsignedIntegerValue))];
    return out;
    }

// How many words of variadic tail a forwarder relays. arm9 is the one target
// where varargs travel in REGISTERS rather than a shared buffer, so a forwarder
// cannot simply decline to repack — it has to move its own incoming tail into
// the callee's argument slots. The count cannot be known (the format string
// decides at run time), so it is capped, exactly as the other targets' pack
// buffer caps them at 128 bytes. 16 words is 64 bytes of tail. Copying more
// than the callee reads is harmless: it only ever reads what its format names.
static const NSUInteger kArm9VaForwardWords = 16;

// Relay this function's incoming variadic tail into the callee's slots.
//
// Tail word i belongs at callee slot k+i, where k is the slots its EXPLICIT
// arguments already occupy. Slots 0-3 are r0-r3, slots >= 4 the outgoing stack
// at [sp,#(slot-4)*4]. Slots k..3 are disjoint from the 0..k-1 that marshalArgs
// just filled, so this runs after it and clobbers nothing.
+ (void)emitVaForwardRelayK:(NSUInteger)k
                  vaListOff:(NSUInteger)vaListOff
                        out:(NSMutableString*)out
    {
    [out appendFormat:@"\t@ vararg forward: relay %lu words to slot %lu+\n",
                      (unsigned long)kArm9VaForwardWords, (unsigned long)k];
    for (NSUInteger i = 0; i < kArm9VaForwardWords; i++)
        {
        NSUInteger dst = k + i;
        NSUInteger src = vaListOff + i * 4;
        if (dst < 4)
            {
            [out appendFormat:@"\tldr\tr%lu, [sp, #%lu]\n",
                              (unsigned long)dst, (unsigned long)src];
            }
        else
            {
            [out appendFormat:@"\tldr\tr12, [sp, #%lu]\n", (unsigned long)src];
            [out appendFormat:@"\tstr\tr12, [sp, #%lu]\n", (unsigned long)((dst - 4) * 4)];
            }
        }
    }

+ (void)emitInsn:(XTIRInsn*)in fn:(XTIRFunction*)fn module:(XTIRModule*)mod
            slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
       vaListOff:(NSUInteger)vaListOff
             out:(NSMutableString*)out
    {
    XTIROpcode op = in.opcode;
    NSArray<XTIROperand*>* ops = in.operands;
    XTIRValue* res = in.result;
    // Skip a pure Const/ext whose only consumers are constant-inlined VSplats.
    if (res && sNoEmit && [sNoEmit containsObject:@(res.valueId)])
        return;
    // A fused compare is emitted by its CondBranch, not here.
    if (res && sFusedCmp && [sFusedCmp containsObject:@(res.valueId)])
        return;
    // Module-unique suffix for inline ARC branch labels (ELF .L labels are
    // file-scoped, so a per-function counter would collide across functions).
    static NSUInteger sArcLabel = 0;

    // ── 64-bit integer ops ───────────────────────────────────────────────
    // Intercepted before the 32-bit paths below, which work a word at a time
    // and would silently compute only the low half. Both operands go to
    // r0:r1 / r2:r3 per AAPCS and the result comes back in r0:r1 — the same
    // convention a double already uses.
    //
    // Multiply, divide, modulo and the shifts call libgcc, which arm9 already
    // links (`-lgcc` in the arm-none-eabi-gcc invocation in src/xtc/main.m).
    // Add, subtract and the bitwise ops do NOT: libgcc has no __adddi3 /
    // __subdi3 / __anddi3 / __ordi3 / __xordi3 on ARM, because every compiler
    // emits them inline — and calling them produced a .so with undefined
    // symbols that the XTOS loader refused, which reads as "no output" rather
    // than as a link error. They are two instructions each here.
    // Producing a 64-bit value from a narrower one, or from another 64-bit one.
    // Each of these falls through to a one-word path below that writes the low
    // word and leaves the high word holding whatever the slot did: `(i64)5`
    // stored 5 and a stale high half, which then propagated through every
    // arithmetic result computed from it.
    if (res && (res.type.kind == XTIRTypeKindI64 || res.type.kind == XTIRTypeKindU64) && ops.count >= 1 && slot[@(res.valueId)] && (op == XTIROpZExt || op == XTIROpSExt || op == XTIROpBitcast || op == XTIROpConst || op == XTIROpPtrToInt))
        {
        NSUInteger ro = slot[@(res.valueId)].unsignedIntegerValue;
        if (op == XTIROpConst && ops[0].kind == XTIROperandKindImmI)
            {
            uint64_t v = (uint64_t)ops[0].intValue;
            [self emitMovImm:(int64_t)(uint32_t)(v & 0xFFFFFFFFu) reg:@"r0" into:out];
            [self emitMovImm:(int64_t)(uint32_t)(v >> 32) reg:@"r1" into:out];
            }
        else if (op == XTIROpBitcast || op == XTIROpConst)
            {
            // A same-width reinterpretation (i64 <-> u64) is a two-word copy.
            [self loadInt64Operand:ops[0] lo:@"r0" hi:@"r1" slot:slot fn:fn out:out];
            }
        else
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            XTIRType* st = (ops[0].kind == XTIROperandKindUse)
                               ? fn.values[@(ops[0].valueId)].type
                               : ops[0].type;
            NSUInteger sw = [self fieldWidth:st];
            if (op == XTIROpSExt)
                {
                if (sw == 1)
                    [out appendString:@"\tsxtb\tr0, r0\n"];
                else if (sw == 2)
                    [out appendString:@"\tsxth\tr0, r0\n"];
                [out appendString:@"\tasr\tr1, r0, #31\n"]; // sign smear
                }
            else
                {
                if (sw == 1)
                    [out appendString:@"\tand\tr0, r0, #255\n"];
                else if (sw == 2)
                    [out appendString:@"\tuxth\tr0, r0\n"];
                [out appendString:@"\tmov\tr1, #0\n"];
                }
            }
        [self emitSpAccess:@"str" reg:@"r0" off:ro out:out];
        [self emitSpAccess:@"str" reg:@"r1" off:ro + 4 out:out];
        return;
        }

    // The UNARY 64-bit ops. Without this they fell through to the 32-bit path
    // below, which writes the LOW word only and leaves the high word holding
    // whatever the frame had — `i64 x = -5000000000;` (a Neg over a wide Const)
    // printed a high half of $A5A5A5A5, the stack fill pattern. Same shape, and
    // the same omission, as the m68k back end had.
    if (res && (res.type.kind == XTIRTypeKindI64 || res.type.kind == XTIRTypeKindU64) && ops.count == 1 && slot[@(res.valueId)] && (op == XTIROpNeg || op == XTIROpNot))
        {
        [self loadInt64Operand:ops[0] lo:@"r0" hi:@"r1" slot:slot fn:fn out:out];
        if (op == XTIROpNeg)
            {
            // 0 - x across both words. Spelled with subs/sbc (which the Sub
            // path above already relies on) rather than rsbs/rsc.
            [out appendString:@"\tmov\tr2, #0\n\tmov\tr3, #0\n"];
            [out appendString:@"\tsubs\tr0, r2, r0\n\tsbc\tr1, r3, r1\n"];
            }
        else
            {
            [out appendString:@"\tmvn\tr0, r0\n\tmvn\tr1, r1\n"];
            }
        NSUInteger ro = slot[@(res.valueId)].unsignedIntegerValue;
        [self emitSpAccess:@"str" reg:@"r0" off:ro out:out];
        [self emitSpAccess:@"str" reg:@"r1" off:ro + 4 out:out];
        return;
        }

    if (res && (res.type.kind == XTIRTypeKindI64 || res.type.kind == XTIRTypeKindU64) && ops.count >= 2 && slot[@(res.valueId)])
        {
        NSString *h = nil, *loOp = nil, *hiOp = nil;
        switch (op)
            {
        case XTIROpAdd:
            loOp = @"adds";
            hiOp = @"adc";
            break;
        case XTIROpSub:
            loOp = @"subs";
            hiOp = @"sbc";
            break;
        case XTIROpAnd:
            loOp = @"and";
            hiOp = @"and";
            break;
        case XTIROpOr:
            loOp = @"orr";
            hiOp = @"orr";
            break;
        case XTIROpXor:
            loOp = @"eor";
            hiOp = @"eor";
            break;
        case XTIROpMul:
            h = @"__muldi3";
            break;
        case XTIROpSDiv:
            h = @"__divdi3";
            break;
        case XTIROpUDiv:
            h = @"__udivdi3";
            break;
        case XTIROpSRem:
            h = @"__moddi3";
            break;
        case XTIROpURem:
            h = @"__umoddi3";
            break;
        case XTIROpShl:
            h = @"__ashldi3";
            break;
        case XTIROpLShr:
            h = @"__lshrdi3";
            break;
        case XTIROpAShr:
            h = @"__ashrdi3";
            break;
        default:
            break;
            }
        if (h || loOp)
            {
            [self loadInt64Operand:ops[0] lo:@"r0" hi:@"r1" slot:slot fn:fn out:out];
            // A shift takes its COUNT in r2 as a single word — that is libgcc's
            // signature (`__ashldi3(long long, int)`), so a 64-bit count would
            // be half-read.
            BOOL isShift = (op == XTIROpShl || op == XTIROpLShr || op == XTIROpAShr);
            if (isShift)
                [self loadOperand:ops[1] into:@"r2" slot:slot out:out];
            else
                [self loadInt64Operand:ops[1] lo:@"r2" hi:@"r3" slot:slot fn:fn out:out];
            if (h)
                [out appendFormat:@"\tbl\t%@\n", h];
            else
                {
                [out appendFormat:@"\t%@\tr0, r0, r2\n", loOp];
                [out appendFormat:@"\t%@\tr1, r1, r3\n", hiOp];
                }
            NSUInteger ro = slot[@(res.valueId)].unsignedIntegerValue;
            [self emitSpAccess:@"str" reg:@"r0" off:ro out:out];
            [self emitSpAccess:@"str" reg:@"r1" off:ro + 4 out:out];
            return;
            }
        }

    // Binary integer ops: load r0,r1 → op → store.
    NSString* (^bin)(NSString*) = nil;
    (void)bin;
    NSString* mnem = nil;
    switch (op)
        {
    case XTIROpAdd:
        mnem = @"add";
        break;
    case XTIROpSub:
        mnem = @"sub";
        break;
    case XTIROpMul:
        mnem = @"mul";
        break;
    case XTIROpAnd:
        mnem = @"and";
        break;
    case XTIROpOr:
        mnem = @"orr";
        break;
    case XTIROpXor:
        mnem = @"eor";
        break;
    case XTIROpShl:
        mnem = @"lsl";
        break;
    case XTIROpLShr:
        mnem = @"lsr";
        break;
    case XTIROpAShr:
        mnem = @"asr";
        break;
    default:
        break;
        }
    if (mnem && ops.count >= 2 && res)
        {
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
        // A right shift acts on the full 32-bit register, but a narrow operand
        // sits in its slot un-extended (an i8 -16 is 0x000000F0). Canonicalise
        // the LHS to its operand type first: AShr needs sign-extension
        // (asr 0xFFFFFFF0 → correct), LShr zero-extension (no stale high bits).
        if (op == XTIROpAShr || op == XTIROpLShr)
            {
            XTIRType* lt = (ops[0].kind == XTIROperandKindUse)
                               ? fn.values[@(ops[0].valueId)].type
                               : ops[0].type;
            // ... and for LShr that extension must be UNSIGNED even when the
            // operand's type is signed. Passing the operand type straight in
            // sign-extended it, so `lsr` on i16 -28820 shifted 0xFFFF8F6C and
            // pulled the extension bits down (the comment above always said
            // "LShr zero-extension" — the code just did not do it). `>>` on a
            // signed type is an AShr, so the only producer of this shape is the
            // rotate expansion in the shared lowering: every i8/i16 `<:` / `:>`
            // was wrong here while the unsigned ones were right. Same bug, and
            // the same fix, as the arm64 back end.
            if (op == XTIROpLShr && lt && XTIRTypeKindIsSigned(lt.kind))
                {
                if (lt.kind == XTIRTypeKindI8)
                    [out appendFormat:@"\tand\tr0, r0, #255\n"];
                else if (lt.kind == XTIRTypeKindI16)
                    [out appendFormat:@"\tuxth\tr0, r0\n"];
                else
                    [self canonicaliseReg:@"r0" toType:lt out:out];
                }
            else
                {
                [self canonicaliseReg:@"r0" toType:lt out:out];
                }
            }
        [out appendFormat:@"\t%@\tr0, r0, r1\n", mnem];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }

    switch (op)
        {
    case XTIROpConst:
        if (res && ops.count >= 1)
            {
            if (ops[0].kind == XTIROperandKindImmF)
                {
                // softfp: a float lives as raw IEEE bits in its slot. The
                // operand carries the 64-bit double pattern; an F32 result
                // narrows it to single precision first.
                uint64_t raw = ops[0].floatRawBytes;
                NSNumber* s = slot[@(res.valueId)];
                NSUInteger so = s ? s.unsignedIntegerValue : 0;
                if (res.type && res.type.kind == XTIRTypeKindF64)
                    {
                    [self emitMovImm:(int64_t)(uint32_t)raw reg:@"r0" into:out];
                    [self emitMovImm:(int64_t)(uint32_t)(raw >> 32) reg:@"r1" into:out];
                    [self emitSpAccess:@"str" reg:@"r0" off:so out:out];
                    [self emitSpAccess:@"str" reg:@"r1" off:so + 4 out:out];
                    }
                else
                    {
                    double d;
                    memcpy(&d, &raw, 8);
                    float f = (float)d;
                    uint32_t bits;
                    memcpy(&bits, &f, 4);
                    [self emitMovImm:(int64_t)bits reg:@"r0" into:out];
                    [self emitSpAccess:@"str" reg:@"r0" off:so out:out];
                    }
                return;
                }
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpCopy:
    case XTIROpIntToPtr:
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpBitcast:
        // A reinterpret (same bits, new type). Canonicalise to the result's
        // signedness so a signed↔unsigned narrow reinterpret reads right:
        // `(u8)(i8 -1)` → 0xFF (255), `(i8)(u8 200)` → 0xFFFFFFC8 (-56).
        // No-op for Ptr / 32-bit / float results (canonicaliseReg default).
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self canonicaliseReg:@"r0" toType:res.type out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpPtrToInt:
        // Canonicalise to the result width: `(u16)ptr` keeps only the low
        // 16 bits. Without this a 32-bit address compared against its own
        // uxth'd form (`&arr[0] == (u16)arr`) miscompares on the high bits.
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self canonicaliseReg:@"r0" toType:res.type out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpNeg:
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [out appendString:@"\trsb\tr0, r0, #0\n"];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpNot:
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [out appendString:@"\tmvn\tr0, r0\n"];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpZExt:
    case XTIROpTrunc:
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            if (op == XTIROpTrunc)
                {
                // Truncate to the result width, canonicalised to the result's
                // SIGNEDNESS: a signed narrow result is sign-extended (i16 -5 →
                // 0xFFFFFFFB), an unsigned one zero-extended. A bare uxth left
                // a signed value zero-extended, so a later 32-bit compare /
                // inlined use saw the wrong high bits.
                [self canonicaliseReg:@"r0" toType:res.type out:out];
                }
            // ZExt — always zero-fill to the (narrower) source width.
            else
                {
                uint32_t w = res.type ? res.type.byteWidth : 4;
                XTIRType* st = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)].type : ops[0].type;
                uint32_t sw = st ? st.byteWidth : 4;
                uint32_t mw = sw < w ? sw : w;
                if (mw == 1)
                    [out appendString:@"\tand\tr0, r0, #255\n"];
                else if (mw == 2)
                    [out appendString:@"\tuxth\tr0, r0\n"];
                }
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpSExt:
        if (res && ops.count >= 1)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            XTIRType* st = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)].type : ops[0].type;
            uint32_t sw = st ? st.byteWidth : 4;
            if (sw == 1)
                [out appendString:@"\tsxtb\tr0, r0\n"];
            else if (sw == 2)
                [out appendString:@"\tsxth\tr0, r0\n"];
            // Sign-extend from the SOURCE width, then canonicalise to the
            // RESULT type: `(u16)(i8 -1)` lowers to SExt(i8)->U16, which must
            // be 0x0000FFFF (65535), not the 32-bit-sign-extended 0xFFFFFFFF.
            [self canonicaliseReg:@"r0" toType:res.type out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpSDiv:
    case XTIROpUDiv:
        // Cortex-A9 has NO hardware integer divide — sdiv/udiv are UNDEFINED.
        // Use the EABI runtime helpers (args r0/r1, quotient in r0).
        if (res && ops.count >= 2)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
            [out appendFormat:@"\tbl\t%@\n", op == XTIROpSDiv ? @"__aeabi_idiv" : @"__aeabi_uidiv"];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpSRem:
    case XTIROpURem:
        // No hw divide → use __aeabi_{i,ui}divmod (quotient r0, REMAINDER r1).
        if (res && ops.count >= 2)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
            [out appendFormat:@"\tbl\t%@\n", op == XTIROpSRem ? @"__aeabi_idivmod" : @"__aeabi_uidivmod"];
            [self storeResult:res from:@"r1" slot:slot out:out]; // remainder
            }
        return;
    case XTIROpRol:
    case XTIROpRor:
        if (res && ops.count >= 2)
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
            if (op == XTIROpRol)
                [out appendString:@"\trsb\tr1, r1, #32\n"]; // rol n = ror (32-n)
            [out appendString:@"\tror\tr0, r0, r1\n"];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpSelect:
        // operands: cond, trueVal, falseVal → cond ? true : false
        if (res && ops.count >= 3)
            {
            [self loadCondition:ops[0] into:@"r2" scratch:@"r3" slot:slot fn:fn out:out];
            [self loadOperand:ops[1] into:@"r0" slot:slot out:out];
            [self loadOperand:ops[2] into:@"r1" slot:slot out:out];
            [out appendString:@"\tcmp\tr2, #0\n\tmoveq\tr0, r1\n"];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
    case XTIROpICmp:
        if (res && ops.count >= 2)
            {
            NSString* cc = [self condForICmp:in.predicate];
            // A 64-bit compare is not one `cmp`: the single-word path below
            // reads the LOW word of each operand and ignores the rest, so
            // `7 == 0` came out true.
            //
            // Done inline rather than through libgcc's __cmpdi2. That call
            // works, but it drags newlib in behind it — the .so grew
            // undefined `abort`/`calloc`/`fprintf`/`_impure_ptr`/`free`,
            // which is a lot of loader surface for three instructions.
            XTIRType* ct0 = [self typeOfOperand:ops[0] fn:fn];
            XTIRType* ct1 = [self typeOfOperand:ops[1] fn:fn];
            BOOL w0 = ct0 && (ct0.kind == XTIRTypeKindI64 || ct0.kind == XTIRTypeKindU64);
            BOOL w1 = ct1 && (ct1.kind == XTIRTypeKindI64 || ct1.kind == XTIRTypeKindU64);
            if (w0 || w1)
                {
                BOOL sgn = (ct0 && ct0.kind == XTIRTypeKindI64) || (ct1 && ct1.kind == XTIRTypeKindI64);
                uint8_t p = in.predicate;
                BOOL ordered = (p != XTIRICmpEQ && p != XTIRICmpNE);
                if (sgn && ordered)
                    {
                    // The signed orderings all reduce to lt/ge on a 64-bit
                    // SUBTRACTION: `subs` then `sbcs` leaves N and V set
                    // from the full-width result, which is exactly the
                    // signed comparison. `a > b` is `b < a`, so the two
                    // "greater" forms swap their operands rather than
                    // needing a condition that also reads Z — Z here
                    // reflects only the high word and would be wrong.
                    BOOL swap = (p == XTIRICmpSGT || p == XTIRICmpSLE);
                    NSString* cc2 = (p == XTIRICmpSLT || p == XTIRICmpSGT) ? @"lt" : @"ge";
                    [self loadInt64Operand:ops[swap ? 1 : 0]
                                        lo:@"r0"
                                        hi:@"r1"
                                      slot:slot
                                        fn:fn
                                       out:out];
                    [self loadInt64Operand:ops[swap ? 0 : 1]
                                        lo:@"r2"
                                        hi:@"r3"
                                      slot:slot
                                        fn:fn
                                       out:out];
                    [out appendString:@"\tsubs\tr12, r0, r2\n\tsbcs\tr12, r1, r3\n"];
                    [out appendString:@"\tmov\tr0, #0\n"];
                    [out appendFormat:@"\tmov%@\tr0, #1\n", cc2];
                    [self storeResult:res from:@"r0" slot:slot out:out];
                    return;
                    }
                // Equality, and the unsigned orderings: compare the high
                // words, and only if they are equal let the low words
                // decide. `cmpeq` is exactly that, and the unsigned
                // conditions read C/Z, which both comparisons set correctly
                // — so condForICmp's own answer is right as it stands.
                [self loadInt64Operand:ops[0] lo:@"r0" hi:@"r1" slot:slot fn:fn out:out];
                [self loadInt64Operand:ops[1] lo:@"r2" hi:@"r3" slot:slot fn:fn out:out];
                [out appendString:@"\tcmp\tr1, r3\n\tcmpeq\tr0, r2\n\tmov\tr0, #0\n"];
                if (cc)
                    [out appendFormat:@"\tmov%@\tr0, #1\n", cc];
                [self storeResult:res from:@"r0" slot:slot out:out];
                return;
                }
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
            [out appendString:@"\tcmp\tr0, r1\n\tmov\tr0, #0\n"];
            if (cc)
                [out appendFormat:@"\tmov%@\tr0, #1\n", cc];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;

    // ── Floating point (softfp ABI: values live as bits in slots/core regs;
    //    compute uses genuine VFP instructions) ───────────────────────────
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFDiv:
        {
        if (ops.count < 2 || !res)
            return;
        BOOL d = res.type && res.type.kind == XTIRTypeKindF64;
        NSString* sfx = d ? @"f64" : @"f32";
        NSString *ra = d ? @"d2" : @"s0", *rb = d ? @"d3" : @"s1";
        NSString* m = op == XTIROpFAdd ? @"vadd" : op == XTIROpFSub ? @"vsub"
                                               : op == XTIROpFMul   ? @"vmul"
                                                                    : @"vdiv";
        [self vfpLoad:ra operand:ops[0] slot:slot out:out];
        [self vfpLoad:rb operand:ops[1] slot:slot out:out];
        [out appendFormat:@"\t%@.%@\t%@, %@, %@\n", m, sfx, ra, ra, rb];
        [self vfpStore:ra result:res slot:slot out:out];
        return;
        }
    case XTIROpFNeg:
        {
        if (ops.count < 1 || !res)
            return;
        BOOL d = res.type && res.type.kind == XTIRTypeKindF64;
        NSString* ra = d ? @"d2" : @"s0";
        [self vfpLoad:ra operand:ops[0] slot:slot out:out];
        [out appendFormat:@"\tvneg.%@\t%@, %@\n", d ? @"f64" : @"f32", ra, ra];
        [self vfpStore:ra result:res slot:slot out:out];
        return;
        }
    case XTIROpFSqrt:
        {
        // VFP hardware square root (the SqrtIntrinsic pass canonicalised a
        // libm sqrt[f] call to this op — no more libm round-trip).
        if (ops.count < 1 || !res)
            return;
        BOOL d = res.type && res.type.kind == XTIRTypeKindF64;
        NSString* ra = d ? @"d2" : @"s0";
        [self vfpLoad:ra operand:ops[0] slot:slot out:out];
        [out appendFormat:@"\tvsqrt.%@\t%@, %@\n", d ? @"f64" : @"f32", ra, ra];
        [self vfpStore:ra result:res slot:slot out:out];
        return;
        }
    case XTIROpVaStart:
        {
        // Native AAPCS va_list. ap = the first variadic arg = sp + vaListOff
        // (the prologue's saved r0-r3 are contiguous with the stack args).
        // Store ap into the cursor slot (operand 0 = &cursor); the variadic fn
        // hands ap to libc vprintf. va_arg isn't lowered natively — nothing on
        // arm9 consumes a va_list itself (Stdio forwards to vprintf).
        [self emitAlu:@"add" dst:@"r0" lhs:@"sp" imm:vaListOff scratch:@"r12" out:out];
        [self loadOperand:in.operands[0] into:@"r1" slot:slot out:out];
        [out appendString:@"\tstr\tr0, [r1]\n"];
        return;
        }
    case XTIROpVaArg:
        {
        // Read the next AAPCS-promoted arg from the va_list and advance it.
        // r1 = &cursor, r2 = cursor (va_list ptr). The caller (cVarargPromote)
        // widened narrow ints → i32 and float → double, so a narrow/float
        // result reads the promoted width then truncates/converts.
        if (!res)
            return;
        XTIRType* rt = res.type;
        BOOL isF64 = (rt.kind == XTIRTypeKindF64);
        BOOL isF32 = (rt.kind == XTIRTypeKindF32); // promoted to f64 in the list
        // A 64-bit INTEGER is 8-byte aligned and 8 bytes wide, exactly as
        // an f64 is — AAPCS makes no distinction. It used to fall through
        // to the generic branch below, which reads ONE word and advances
        // four: `%lld` printed garbage and every following argument shifted
        // by a word. Only f64 had been taught the rule.
        BOOL isI64 = (rt.kind == XTIRTypeKindI64 || rt.kind == XTIRTypeKindU64);
        [self loadOperand:in.operands[0] into:@"r1" slot:slot out:out];
        [out appendString:@"\tldr\tr2, [r1]\n"];
        if (isF64 || isF32 || isI64) // AEABI: 8-byte types 8-aligned
            [out appendString:@"\tadd\tr2, r2, #7\n\tbic\tr2, r2, #7\n"];
        if (isI64)
            {
            NSNumber* ro = slot[@(res.valueId)];
            [out appendString:@"\tldr\tr0, [r2]\n\tldr\tr3, [r2, #4]\n"];
            [out appendString:@"\tadd\tr2, r2, #8\n\tstr\tr2, [r1]\n"];
            if (ro)
                {
                [self emitSpAccess:@"str" reg:@"r0" off:ro.unsignedIntegerValue out:out];
                [self emitSpAccess:@"str" reg:@"r3" off:ro.unsignedIntegerValue + 4 out:out];
                }
            }
        else if (isF64)
            {
            [out appendString:@"\tvldr\td0, [r2]\n\tadd\tr3, r2, #8\n\tstr\tr3, [r1]\n"];
            [self vfpStore:@"d0" result:res slot:slot out:out];
            }
        else if (isF32)
            {
            [out appendString:@"\tvldr\td0, [r2]\n\tvcvt.f32.f64\ts0, d0\n"
                               "\tadd\tr3, r2, #8\n\tstr\tr3, [r1]\n"];
            [self vfpStore:@"s0" result:res slot:slot out:out];
            }
        else if (rt.kind == XTIRTypeKindPtr && rt.pointeeType && rt.pointeeType.kind == XTIRTypeKindAgg)
            {
            // struct-by-value vararg — va_arg(ap, T@). AAPCS passed the struct
            // INLINE in the va_list, so hand back a POINTER to it (the cursor
            // itself), not a load of its first word. Advance by the word-
            // rounded struct size (an aggregate occupies ceil(size/4) words).
            NSUInteger sz = [XTArm9Backend aggSize:rt.pointeeType.layout];
            NSUInteger adv = ((sz + 3) / 4) * 4;
            if (adv == 0)
                adv = 4;
            [out appendString:@"\tmov\tr0, r2\n"]; // r0 = &struct in the list
            [out appendFormat:@"\tadd\tr3, r2, #%lu\n\tstr\tr3, [r1]\n", (unsigned long)adv];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        else
            {
            [out appendString:@"\tldr\tr0, [r2]\n\tadd\tr3, r2, #4\n\tstr\tr3, [r1]\n"];
            [self canonicaliseReg:@"r0" toType:rt out:out];
            [self storeResult:res from:@"r0" slot:slot out:out];
            }
        return;
        }
    case XTIROpFCmp:
        {
        if (ops.count < 2 || !res)
            return;
        XTIRType* ot = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)].type : ops[0].type;
        BOOL d = ot && ot.kind == XTIRTypeKindF64;
        NSString *ra = d ? @"d2" : @"s0", *rb = d ? @"d3" : @"s1";
        [self vfpLoad:ra operand:ops[0] slot:slot out:out];
        [self vfpLoad:rb operand:ops[1] slot:slot out:out];
        [out appendFormat:@"\tvcmp.%@\t%@, %@\n\tvmrs\tAPSR_nzcv, fpscr\n", d ? @"f64" : @"f32", ra, rb];
        NSString* cc = [self condForFCmp:in.predicate];
        [out appendString:@"\tmov\tr0, #0\n"];
        if (cc)
            [out appendFormat:@"\tmov%@\tr0, #1\n", cc];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }
    case XTIROpSIToFp:
    case XTIROpUIToFp:
        {
        // int (core reg) → VFP, then convert to float.
        if (ops.count < 1 || !res)
            return;
        BOOL d = res.type && res.type.kind == XTIRTypeKindF64;
        BOOL sgn = op == XTIROpSIToFp;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        XTIRType* st = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)].type : ops[0].type;
        [self canonicaliseReg:@"r0" toType:st out:out]; // sign/zero-extend narrow src
        [out appendString:@"\tvmov\ts0, r0\n"];
        NSString* dst = d ? @"d2" : @"s0";
        [out appendFormat:@"\tvcvt.%@.%@32\t%@, s0\n", d ? @"f64" : @"f32", sgn ? @"s" : @"u", dst];
        [self vfpStore:dst result:res slot:slot out:out];
        return;
        }
    case XTIROpFpToSI:
    case XTIROpFpToUI:
        {
        // float → VFP convert-to-int (round toward zero), then to a core reg.
        // LANGUAGE-SPEC §3.1: an out-of-range float→int saturates to 0 (not
        // INT_MAX/MIN). Detect it two ways: (1) re-extend the result's low W
        // bits and compare — catches a value that overflows a NARROW dest
        // (i8/i16); (2) the FPSCR IOC flag — catches a vcvt that saturated the
        // 32-bit conversion itself (W=32, where the re-extend is a no-op).
        if (ops.count < 1 || !res)
            return;
        XTIRType* st = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)].type : ops[0].type;
        BOOL d = st && st.kind == XTIRTypeKindF64;
        BOOL sgn = op == XTIROpFpToSI;
        NSString* src = d ? @"d2" : @"s0";
        [self vfpLoad:src operand:ops[0] slot:slot out:out];
        [out appendString:@"\tvmrs\tr1, fpscr\n\tbic\tr1, r1, #1\n\tvmsr\tfpscr, r1\n"]; // clear IOC
        [out appendFormat:@"\tvcvt.%@32.%@\ts0, %@\n", sgn ? @"s" : @"u", d ? @"f64" : @"f32", src];
        [out appendString:@"\tvmov\tr0, s0\n"];
        [out appendString:@"\tmov\tr1, r0\n"];
        [self canonicaliseReg:@"r1" toType:res.type out:out];                      // re-extend low W bits
        [out appendString:@"\tcmp\tr0, r1\n\tmovne\tr0, #0\n"];                    // narrow overflow → 0
        [out appendString:@"\tvmrs\tr1, fpscr\n\ttst\tr1, #1\n\tmovne\tr0, #0\n"]; // IOC saturate → 0
        [self canonicaliseReg:@"r0" toType:res.type out:out];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }
    // f32 → f64
    case XTIROpFpExt:
        {
        if (ops.count < 1 || !res)
            return;
        [self vfpLoad:@"s0" operand:ops[0] slot:slot out:out];
        [out appendString:@"\tvcvt.f64.f32\td2, s0\n"];
        [self vfpStore:@"d2" result:res slot:slot out:out];
        return;
        }
    // f64 → f32
    case XTIROpFpTrunc:
        {
        if (ops.count < 1 || !res)
            return;
        [self vfpLoad:@"d2" operand:ops[0] slot:slot out:out];
        [out appendString:@"\tvcvt.f32.f64\ts0, d2\n"];
        [self vfpStore:@"s0" result:res slot:slot out:out];
        return;
        }
    case XTIROpCall:
    case XTIROpCallIndirect:
    case XTIROpCallCloaked:
    case XTIROpCallBanked:
    case XTIROpCallBankedIndirect:
        {
        // AAPCS32. Direct (Call/CallCloaked/CallBanked): a Sym callee + Use
        // args. Indirect (CallIndirect/CallBankedIndirect): operand[0] is the
        // callee function-pointer value, the rest are args. (Mem token
        // filtered.) Cloak/bank are 6502 banking concepts — on the flat A32
        // target they collapse to a plain call. Aggregate args pass by value
        // (split across r0–r3 + the outgoing stack area); an aggregate result
        // > 4 bytes uses sret (hidden result pointer in r0, args → r1+).
        BOOL indirect = (op == XTIROpCallIndirect || op == XTIROpCallBankedIndirect);
        NSString* callee = nil;
        XTIROperand* calleeOp = nil;
        NSMutableArray<XTIROperand*>* args = [NSMutableArray array];
        NSMutableArray<XTIRType*>* argTypes = [NSMutableArray array];
        for (NSUInteger idx = 0; idx < ops.count; idx++)
            {
            XTIROperand* o = ops[idx];
            // fn-pointer value
            if (indirect && idx == 0)
                {
                calleeOp = o;
                continue;
                }
            if (o.kind == XTIROperandKindSym)
                callee = [mod symbolForId:o.symbolId].name;
            else if (o.kind == XTIROperandKindUse && ![self isMemValue:fn.values[@(o.valueId)]])
                {
                [args addObject:o];
                [argTypes addObject:(fn.values[@(o.valueId)].type ?: (id)[NSNull null])];
                }
            }
        BOOL sret = res && ![self isMemValue:res] && [self returnsViaSret:res.type];
        NSUInteger vaAt = indirect ? NSNotFound
                                   : [self varargTailIndexFor:callee module:mod];
        [self marshalArgs:args
                    types:argTypes
                     sret:sret
                   result:res
                 varargAt:vaAt
                     slot:slot
                      out:out];
        // A forwarding call inside a `vaforward` function relays this
        // function's own incoming tail into the callee's slots. Sema
        // guarantees such a function reads no varargs of its own, so its
        // homed r0-r3 block is untouched and IS the tail. private:docs/bugs/047.
        if (!indirect && [mod symbolForName:fn.name].attributes[@"vaforward"].boolValue && [mod symbolForName:callee].attributes[@"variadic"].boolValue)
            {
            NSArray<NSArray<NSNumber*>*>* alocs =
                [self classifyArgTypes:argTypes
                                  sret:sret
                              varargAt:vaAt
                         outStackBytes:NULL];
            NSUInteger k = sret ? 1 : 0;
            for (NSArray<NSNumber*>* L in alocs)
                k += L[1].unsignedIntegerValue;
            if (k & 1)
                k++; // the tail's base is 8-aligned
            [self emitVaForwardRelayK:k vaListOff:vaListOff out:out];
            }
        if (indirect)
            {
            // Load the function pointer into r12 (ip — caller-saved, free
            // after arg marshalling) and branch-and-link through it.
            [self loadOperand:calleeOp into:@"r12" slot:slot out:out];
            [out appendString:@"\tblx\tr12\n"];
            }
        else
            {
            [out appendFormat:@"\tbl\t%@\n", callee ?: @"0 @ TODO unknown callee"];
            }
        if (!sret)
            [self storeCallResult:res slot:slot out:out];
        return;
        }
    case XTIROpVTblDispatch:
        {
        // Virtual dispatch. Operands: [receiver, ImmI(slot), arg0, ..., mem].
        // The receiver is the implicit self (args[0]); the callee is loaded
        // from its vtable: [recv] → vtable ptr, [vtbl + slot*4] → fn ptr.
        if (ops.count < 2 || ops[1].kind != XTIROperandKindImmI)
            return;
        NSMutableArray<XTIROperand*>* args = [NSMutableArray arrayWithObject:ops[0]];
        NSMutableArray<XTIRType*>* argTypes = [NSMutableArray array];
        XTIRValue* recvV = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)] : nil;
        [argTypes addObject:(recvV.type ?: (id)[NSNull null])];
        for (NSUInteger i = 2; i < ops.count; i++)
            {
            XTIROperand* o = ops[i];
            if (o.kind == XTIROperandKindUse && ![self isMemValue:fn.values[@(o.valueId)]])
                {
                [args addObject:o];
                [argTypes addObject:(fn.values[@(o.valueId)].type ?: (id)[NSNull null])];
                }
            }
        BOOL sret = res && ![self isMemValue:res] && [self returnsViaSret:res.type];
        [self marshalArgs:args types:argTypes sret:sret result:res slot:slot out:out];
        // Receiver landed in r0 (or r1 when sret took r0). Load vtable → fn ptr.
        NSString* recvReg = sret ? @"r1" : @"r0";
        [out appendFormat:@"\tldr\tr12, [%@]\n", recvReg];
        [self emitFarLoad:@"r12" base:@"r12" off:(NSUInteger)(ops[1].intValue * 4) out:out];
        [out appendString:@"\tblx\tr12\n"];
        if (!sret)
            [self storeCallResult:res slot:slot out:out];
        return;
        }

    case XTIROpProtoDispatch:
        {
        // Operands: [receiver, ImmI protoId, ImmI methodIndex, args…, mem].
        //
        //   recv[0]         -> vtable
        //   vtable[0]       -> itable: (protoId, &table) pairs, id 0 terminates
        //   scan for protoId, then table[methodIndex] is the impl.
        //
        // The scan is what buys composability: a protocol's method INDEX depends
        // only on its own declaration, so two independently built libraries agree
        // on it without ever having met. A slot NUMBER could never be agreed.
        //
        // Registers: args occupy r0-r3, so the scan may only use r12 and lr — and
        // lr is dead here because the `blx` below overwrites it anyway.
        if (ops.count < 3 || ops[1].kind != XTIROperandKindImmI || ops[2].kind != XTIROperandKindImmI)
            return;
        NSMutableArray<XTIROperand*>* args = [NSMutableArray arrayWithObject:ops[0]];
        NSMutableArray<XTIRType*>* argTypes = [NSMutableArray array];
        XTIRValue* recvV = (ops[0].kind == XTIROperandKindUse) ? fn.values[@(ops[0].valueId)] : nil;
        [argTypes addObject:(recvV.type ?: (id)[NSNull null])];
        for (NSUInteger i = 3; i < ops.count; i++)
            {
            XTIROperand* o = ops[i];
            if (o.kind == XTIROperandKindUse && ![self isMemValue:fn.values[@(o.valueId)]])
                {
                [args addObject:o];
                [argTypes addObject:(fn.values[@(o.valueId)].type ?: (id)[NSNull null])];
                }
            }
        BOOL sret = res && ![self isMemValue:res] && [self returnsViaSret:res.type];
        [self marshalArgs:args types:argTypes sret:sret result:res slot:slot out:out];
        NSString* recvReg = sret ? @"r1" : @"r0";
        [self emitItableLookup:recvReg protoId:(uint32_t)ops[1].intValue out:out];
        [self emitFarLoad:@"r12" base:@"r12" off:(NSUInteger)(ops[2].intValue * 4) out:out];
        [out appendString:@"\tblx\tr12\n"];
        if (!sret)
            [self storeCallResult:res slot:slot out:out];
        return;
        }

    case XTIROpProtoLoad:
        {
        // The same lookup without the call — `&delegate.method`. A null result is
        // an unimplemented `optional`, which is what respondsTo tests for.
        if (ops.count < 3 || !res)
            return;
        if (ops[1].kind != XTIROperandKindImmI || ops[2].kind != XTIROperandKindImmI)
            return;
        if ([self isMemValue:res])
            return;
        NSUInteger pn = sArcLabel++;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [out appendString:@"\tmov\tr12, #0\n"]; // default null
        [out appendString:@"\tcmp\tr0, #0\n"];
        [out appendFormat:@"\tbeq\t.L_pl_%lu\n", (unsigned long)pn]; // null recv -> falsy
        [self emitItableLookup:@"r0" protoId:(uint32_t)ops[1].intValue out:out];
        // A miss also leaves 0 — the class did not implement an `optional`, which
        // is exactly what respondsTo tests. Skip the index: never load through null.
        [out appendString:@"\tcmp\tr12, #0\n"];
        [out appendFormat:@"\tbeq\t.L_pl_%lu\n", (unsigned long)pn];
        [self emitFarLoad:@"r12" base:@"r12" off:(NSUInteger)(ops[2].intValue * 4) out:out];
        [out appendFormat:@".L_pl_%lu:\n", (unsigned long)pn];
        [self storeResult:res from:@"r12" slot:slot out:out];
        return;
        }

    case XTIROpVTblLoad:
        {
        // Operands: [receiver, ImmI(slot), mem] -> fn pointer.
        // VTblDispatch's address computation ([recv] -> vtbl,
        // [vtbl + slot*4] -> fn) without the call: the code word of
        // `&obj.method`.
        //
        // A null receiver yields 0 rather than faulting, so `&nullDel.m`
        // is falsy instead of a crash. An empty slot is already 0 in the
        // emitted vtable, which is what makes an unimplemented `optional`
        // method falsy.
        if (ops.count < 2 || ops[1].kind != XTIROperandKindImmI)
            return;
        if (!res || [self isMemValue:res])
            return;
        NSUInteger n = sArcLabel++;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [out appendString:@"\tmov\tr12, #0\n"]; // default null
        [out appendString:@"\tcmp\tr0, #0\n"];
        [out appendFormat:@"\tbeq\t.L_vtl_%lu\n", (unsigned long)n];
        [out appendString:@"\tldr\tr12, [r0]\n"]; // vtable ptr
        [self emitFarLoad:@"r12" base:@"r12" off:(NSUInteger)(ops[1].intValue * 4) out:out];
        [out appendFormat:@".L_vtl_%lu:\n", (unsigned long)n];
        [self storeResult:res from:@"r12" slot:slot out:out];
        return;
        }

    // ── Memory model ────────────────────────────────────────────────────
    case XTIROpLoad:
    case XTIROpLoadVolatile:
        {
        // Operands: [ptr, memInput] → result. Sized by the result's width.
        if (ops.count < 1 || !res)
            return;
        [self loadOperand:ops[0] into:@"r1" slot:slot out:out];
        XTIRType* pte = res.type;
        // struct load → block copy
        if (pte && pte.kind == XTIRTypeKindAgg)
            {
            [self emitBlockCopyToSlot:res
                                 from:@"r1"
                                 size:[self aggSize:pte.layout]
                                 slot:slot
                                  out:out];
            return;
            }
        uint32_t w = pte ? pte.byteWidth : 4;
        // Eight bytes is two words, for an i64 exactly as for a double:
        // without the integer arm, `*p = someU64` wrote one word and what
        // came back was not what went in.
        if (pte && (pte.kind == XTIRTypeKindF64 || pte.kind == XTIRTypeKindI64 || pte.kind == XTIRTypeKindU64))
            {
            NSNumber* rs = slot[@(res.valueId)];
            [out appendString:@"\tldr\tr0, [r1]\n\tldr\tr2, [r1, #4]\n"];
            if (rs)
                {
                [self emitSpAccess:@"str" reg:@"r0" off:rs.unsignedIntegerValue out:out];
                [self emitSpAccess:@"str" reg:@"r2" off:rs.unsignedIntegerValue + 4 out:out];
                }
            return;
            }
        BOOL sgn = pte ? XTIRTypeKindIsSigned(pte.kind) : NO;
        NSString* ld = @"ldr";
        if (pte && pte.kind == XTIRTypeKindPtr)
            ld = @"ldr"; // 4-byte ptr
        else if (w == 2)
            ld = sgn ? @"ldrsh" : @"ldrh";
        else if (w == 1)
            ld = sgn ? @"ldrsb" : @"ldrb";
        [out appendFormat:@"\t%@\tr0, [r1]\n", ld];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }
    case XTIROpStore:
    case XTIROpStoreVolatile:
        {
        // Operands: [ptr, value, memInput]. Sized by the value's width.
        if (ops.count < 2)
            return;
        XTIROperand* vop = ops[1];
        XTIRType* vty = (vop.kind == XTIROperandKindUse) ? fn.values[@(vop.valueId)].type : vop.type;
        if (vty && vty.kind == XTIRTypeKindAgg && vop.kind == XTIROperandKindUse)
            {
            [self loadOperand:ops[0] into:@"r1" slot:slot out:out]; // dst addr
            [self emitBlockCopyFromSlot:fn.values[@(vop.valueId)]
                                     to:@"r1"
                                   size:[self aggSize:vty.layout]
                                   slot:slot
                                    out:out];
            return;
            }
        [self loadOperand:ops[0] into:@"r1" slot:slot out:out]; // addr
        // 8 bytes → 2 words
        if (vty && (vty.kind == XTIRTypeKindF64 || vty.kind == XTIRTypeKindI64 || vty.kind == XTIRTypeKindU64))
            {
            NSNumber* vs = (vop.kind == XTIROperandKindUse) ? slot[@(vop.valueId)] : nil;
            NSUInteger so = vs ? vs.unsignedIntegerValue : 0;
            [self emitSpAccess:@"ldr" reg:@"r0" off:so out:out];
            [self emitSpAccess:@"ldr" reg:@"r2" off:so + 4 out:out];
            [out appendString:@"\tstr\tr0, [r1]\n\tstr\tr2, [r1, #4]\n"];
            return;
            }
        [self loadOperand:vop into:@"r0" slot:slot out:out]; // value
        uint32_t w = vty ? vty.byteWidth : 4;
        NSString* st = @"str";
        if (vty && vty.kind == XTIRTypeKindPtr)
            st = @"str"; // 4-byte ptr
        else if (w == 2)
            st = @"strh";
        else if (w == 1)
            st = @"strb";
        [out appendFormat:@"\t%@\tr0, [r1]\n", st];
        return;
        }
    case XTIROpAddrOf:
        // Operand is either a Sym (global / string literal) or a Use of a
        // pinned local (its frame slot is the addressable storage).
        if (ops.count < 1 || !res)
            return;
        if (ops[0].kind == XTIROperandKindSym)
            {
            XTIRSymbol* sym = [mod symbolForId:ops[0].symbolId];
            // ELF, bare names. PIC: load the address from a literal pool
            // (`ldr r0, =sym`) — a position-independent reference the loader
            // resolves to R_ARM_RELATIVE for a local symbol. Static (Tier-1):
            // the absolute movw/movt is shorter (no memory load).
            if (sPIC)
                [out appendFormat:@"\tldr\tr0, =%@\n", sym.name];
            else
                [out appendFormat:@"\tmovw\tr0, #:lower16:%@\n\tmovt\tr0, #:upper16:%@\n",
                                  sym.name, sym.name];
            }
        else if (ops[0].kind == XTIROperandKindUse)
            {
            NSNumber* s = slot[@(ops[0].valueId)];
            [self emitAlu:@"add"
                      dst:@"r0"
                      lhs:@"sp"
                      imm:(s ? s.unsignedIntegerValue : 0)scratch:@"r12"
                      out:out];
            }
        else
            {
            [out appendFormat:@"\tmov\tr0, #0\t\t@ TODO AddrOf operand kind %d\n", (int)ops[0].kind];
            }
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
    case XTIROpFieldAddr:
        // Operands: [base:Ptr(Agg), ImmI(field_index)] → base + byteOffset.
        if (ops.count < 2 || !res)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self emitAlu:@"add"
                  dst:@"r0"
                  lhs:@"r0"
                  imm:[self fieldByteOffsetFor:in fn:fn]
              scratch:@"r12"
                  out:out];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
    case XTIROpElementAddr:
        {
        // Operands: [base:Ptr(T), idx] → base + idx·sizeof(T).
        if (ops.count < 2 || !res)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
        uint32_t es = [self elemSizeFor:in fn:fn];
        if (es == 1)
            {
            [out appendString:@"\tadd\tr0, r0, r1\n"];
            }
        else if ((es & (es - 1)) == 0)
            {
            unsigned sh = 0;
            for (uint32_t v = es; v > 1; v >>= 1)
                sh++;
            [out appendFormat:@"\tadd\tr0, r0, r1, lsl #%u\n", sh];
            }
        else
            {
            // Non-power-of-2 stride: Cortex-A9 has mla (r0 = r1·r2 + r0).
            [self emitMovImm:es reg:@"r2" into:out];
            [out appendString:@"\tmla\tr0, r1, r2, r0\n"];
            }
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }
    case XTIROpMemCopy:
        // Operands: [dst, src, size:ImmI, memInput] → memcpy.
        if (ops.count < 3)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
        [self loadOperand:ops[2] into:@"r2" slot:slot out:out];
        [out appendString:@"\tbl\tmemcpy\n"];
        return;
    case XTIROpMemSet:
        // Operands: [dst, byte, size:ImmI, memInput] → memset.
        if (ops.count < 3)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
        [self loadOperand:ops[2] into:@"r2" slot:slot out:out];
        [out appendString:@"\tbl\tmemset\n"];
        return;

    // ── Aggregate build / extract (tuples, by-value struct construction) ─
    case XTIROpAggBuild:
        {
        // Assemble an aggregate from its field operands: store each into the
        // result slot at its A32-native field offset.
        if (!res || !res.type || res.type.kind != XTIRTypeKindAgg || !res.type.layout)
            return;
        NSNumber* bs = slot[@(res.valueId)];
        if (!bs)
            return;
        NSUInteger base = bs.unsignedIntegerValue;
        for (NSUInteger i = 0; i < ops.count; i++)
            {
            XTIROperand* f = ops[i];
            XTIRType* fty = (f.kind == XTIROperandKindUse) ? fn.values[@(f.valueId)].type : f.type;
            [self loadOperand:f into:@"r0" slot:slot out:out];
            NSUInteger foff = base + [self fieldOffset:res.type.layout index:i];
            uint32_t w = fty ? fty.byteWidth : 4;
            NSString* st = (fty && fty.kind == XTIRTypeKindPtr) ? @"str"
                           : w == 2                             ? @"strh"
                           : w == 1                             ? @"strb"
                                                                : @"str";
            [self emitSpAccess:st reg:@"r0" off:foff out:out];
            }
        return;
        }
    case XTIROpAggExtract:
        {
        // Read field #idx out of a source aggregate value's slot.
        if (ops.count < 2 || !res)
            return;
        XTIROperand* srcOp = ops[0];
        XTIRType* aggTy = (srcOp.kind == XTIROperandKindUse) ? fn.values[@(srcOp.valueId)].type : srcOp.type;
        if (!aggTy || aggTy.kind != XTIRTypeKindAgg || !aggTy.layout)
            return;
        NSNumber* ss = slot[@(srcOp.valueId)];
        if (!ss)
            return;
        NSUInteger foff = ss.unsignedIntegerValue + [self fieldOffset:aggTy.layout index:(NSUInteger)ops[1].intValue];
        XTIRType* rty = res.type;
        uint32_t w = rty ? rty.byteWidth : 4;
        BOOL sgn = rty ? XTIRTypeKindIsSigned(rty.kind) : NO;
        NSString* ld = (rty && rty.kind == XTIRTypeKindPtr) ? @"ldr"
                       : w == 2                             ? (sgn ? @"ldrsh" : @"ldrh")
                       : w == 1                             ? (sgn ? @"ldrsb" : @"ldrb")
                                                            : @"ldr";
        [self emitSpAccess:ld reg:@"r0" off:foff out:out];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }

    // ── ARC (inline refcount sequences) ─────────────────────────────────
    // Refcount is a 16-bit value at obj-2 (the allocator's 4-byte-field
    // header puts it just below the object pointer). A single
    // `cmp ptr,#0x10000 / blo done` skips BOTH null and the Map/Set
    // `(pointer)0/1` sentinels and any non-heap address (< 64 KB) — a real
    // heap object is far above that, so [obj,#-2] is always a valid header.
    case XTIROpRetain:
        if (ops.count < 1)
            return;
            {
            NSUInteger n = sArcLabel++;
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [out appendFormat:@"\tcmp\tr0, #0x10000\n\tblo\t.L_arc_%lu\n", (unsigned long)n];
            // Zero means "already dying" — see the arm64 back end. Retaining
            // an object whose dealloc is running relaunches dealloc (bug 038).
            [out appendString:@"\tldrh\tr1, [r0, #-2]\n\tcmp\tr1, #0\n"];
            [out appendFormat:@"\tbeq\t.L_arc_%lu\n", (unsigned long)n];
            // The count saturates at 0xFFFF rather than wrapping to 0, which
            // would free the object while it is still referenced (bug 261).
            // The add is 32-bit, so 0xFFFF + 1 is 0x10000 and the store is
            // skipped.
            if (sArm9ThreadSafeARC)
                {
                // Exclusive-monitor retry loop: LDREXH tags the address,
                // STREXH stores only if nothing else wrote it in between and
                // reports failure in r2, so the loop re-runs on a lost race.
                // A plain load/add/store would silently drop the other
                // thread's increment and free a live object.
                //
                // The retry label comes from the SAME counter as the done
                // label, not a parallel `.L_arcx_` series: the self-hosted
                // port allocates its labels that way, and the two back ends
                // are held to byte-identical output.
                NSUInteger rl = sArcLabel++;
                [out appendFormat:@"\tsub\tr3, r0, #2\n.L_arc_%lu:\n", (unsigned long)rl];
                [out appendString:@"\tldrexh\tr1, [r3]\n\tadd\tr1, r1, #1\n\tcmp\tr1, #0x10000\n"];
                [out appendFormat:@"\tbeq\t.L_arc_%lu\n", (unsigned long)n];
                [out appendString:@"\tstrexh\tr2, r1, [r3]\n"];
                [out appendFormat:@"\tcmp\tr2, #0\n\tbne\t.L_arc_%lu\n", (unsigned long)rl];
                }
            else
                {
                // r1 still holds the count the zero test just read.
                [out appendString:@"\tadd\tr1, r1, #1\n\tcmp\tr1, #0x10000\n"];
                [out appendFormat:@"\tbeq\t.L_arc_%lu\n", (unsigned long)n];
                [out appendString:@"\tstrh\tr1, [r0, #-2]\n"];
                }
            [out appendFormat:@".L_arc_%lu:\n", (unsigned long)n];
            }
        return;
    case XTIROpRelease:
    case XTIROpAutorelease:
        // Autorelease degrades to immediate Release (no pool yet).
        if (ops.count < 1)
            return;
            {
            NSUInteger n = sArcLabel++;
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            [out appendFormat:@"\tcmp\tr0, #0x10000\n\tblo\t.L_arc_%lu\n", (unsigned long)n];
            // A saturated count (0xFFFF) is left alone: once retain stopped
            // counting, the true number of references is unknown, so the
            // object is leaked rather than freed while it may still be in use
            // (bug 261). The plain path reads it sign-extended, so 0xFFFF is -1.
            if (sArm9ThreadSafeARC)
                {
                // Same monitor loop, decrementing. The "was I the last
                // reference?" test uses the value THIS iteration stored
                // (r1 == 0), which only one thread can produce — two
                // threads re-reading a zero would both call dealloc.
                NSUInteger rl = sArcLabel++;
                [out appendFormat:@"\tsub\tr3, r0, #2\n.L_arc_%lu:\n", (unsigned long)rl];
                [out appendString:@"\tldrexh\tr1, [r3]\n\tadd\tr2, r1, #1\n\tcmp\tr2, #0x10000\n"];
                [out appendFormat:@"\tbeq\t.L_arc_%lu\n", (unsigned long)n];
                [out appendString:@"\tsub\tr1, r1, #1\n\tstrexh\tr2, r1, [r3]\n"];
                [out appendFormat:@"\tcmp\tr2, #0\n\tbne\t.L_arc_%lu\n", (unsigned long)rl];
                [out appendString:@"\tdmb\tish\n"]; // acquire before the destructor reads
                [out appendFormat:@"\tcmp\tr1, #0\n\tbne\t.L_arc_%lu\n", (unsigned long)n];
                }
            else
                {
                [out appendString:@"\tldrsh\tr1, [r0, #-2]\n\tcmn\tr1, #1\n"];
                [out appendFormat:@"\tbeq\t.L_arc_%lu\n", (unsigned long)n];
                [out appendString:@"\tsubs\tr1, r1, #1\n\tstrh\tr1, [r0, #-2]\n"];
                [out appendFormat:@"\tbne\t.L_arc_%lu\n", (unsigned long)n];
                }
            [out appendString:@"\tbl\t_xtc_dealloc\n"]; // r0 = obj; reads header fnptr
            [out appendFormat:@".L_arc_%lu:\n", (unsigned long)n];
            }
        return;
    case XTIROpWeakRegister:
        // Operands: [slot, obj, memInput].
        if (ops.count < 2)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [self loadOperand:ops[1] into:@"r1" slot:slot out:out];
        [out appendString:@"\tbl\t_xtc_weak_register\n"];
        return;
    case XTIROpWeakUnregister:
        // Operands: [slot, memInput].
        if (ops.count < 1)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [out appendString:@"\tbl\t_xtc_weak_unregister\n"];
        return;
    case XTIROpWeakLoad:
        // Operands: [slot, memInput] → result.
        if (ops.count < 1 || !res)
            return;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        [out appendString:@"\tbl\t_xtc_weak_load\n"];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;

    // ── NEON SIMD (aarch32) — mirrors the arm64 vectoriser lowering, q8..q15.
    // [ptr, mem] → vld1 {dLo,dHi}, [addr]{!}
    case XTIROpVLoad:
        {
        if (ops.count < 1 || !res)
            return;
        NSInteger q = [self vqForValue:res.valueId];
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        XTIRInsn* ea = (sPostIncEA && ops[0].kind == XTIROperandKindUse)
                           ? sPostIncEA[@(ops[0].valueId)]
                           : nil;
        [out appendFormat:@"\tvld1.%@\t{d%ld, d%ld}, [r0]%@\n",
                          arm9NeonSz(res.type.pointeeType), (long)(2 * q), (long)(2 * q + 1), ea ? @"!" : @""];
        if (ea && ea.result)
            [self storeResult:ea.result from:@"r0" slot:slot out:out]; // advanced ptr
        return;
        }
    // [ptr, vec, mem]
    case XTIROpVStore:
        {
        if (ops.count < 2 || ops[1].kind != XTIROperandKindUse)
            return;
        NSInteger q = [self vqForValue:ops[1].valueId];
        XTIRType* lane = [fn valueForId:ops[1].valueId].type.pointeeType;
        [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
        XTIRInsn* ea = (sPostIncEA && ops[0].kind == XTIROperandKindUse)
                           ? sPostIncEA[@(ops[0].valueId)]
                           : nil;
        [out appendFormat:@"\tvst1.%@\t{d%ld, d%ld}, [r0]%@\n", arm9NeonSz(lane),
                          (long)(2 * q), (long)(2 * q + 1), ea ? @"!" : @""];
        if (ea && ea.result)
            [self storeResult:ea.result from:@"r0" slot:slot out:out]; // advanced ptr
        return;
        }
    // [scalar] → vdup.<sz> qD, rX
    case XTIROpVSplat:
        {
        if (ops.count < 1 || !res)
            return;
        NSInteger d = [self vqForValue:res.valueId];
        int64_t c;
        // Constant splat: materialise the immediate straight into r0 (movw/movt)
        // and vdup — skip the naive Const→slot→ZExt→mask→slot→reload chain.
        if (ops[0].kind == XTIROperandKindUse && arm9TraceConst(ops[0].valueId, &c))
            {
            uint32_t w = res.type.pointeeType ? XTIRTypeKindByteWidth(res.type.pointeeType.kind) : 4;
            uint32_t mask = w == 1 ? 0xFFu : w == 2 ? 0xFFFFu
                                                    : 0xFFFFFFFFu;
            [self emitMovImm:(int64_t)((uint32_t)c & mask) reg:@"r0" into:out];
            }
        else
            {
            [self loadOperand:ops[0] into:@"r0" slot:slot out:out];
            }
        [out appendFormat:@"\tvdup.%@\tq%ld, r0\n", arm9NeonSz(res.type.pointeeType), (long)d];
        return;
        }
    case XTIROpVAdd:
    case XTIROpVSub:
    case XTIROpVMul:
    case XTIROpVAnd:
    case XTIROpVOr:
    case XTIROpVXor:
        {
        if (ops.count < 2 || !res || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSInteger a = [self vqForValue:ops[0].valueId], b = [self vqForValue:ops[1].valueId], d = [self vqForValue:res.valueId];
        if (op == XTIROpVAnd || op == XTIROpVOr || op == XTIROpVXor)
            {
            NSString* m = op == XTIROpVAnd ? @"vand" : op == XTIROpVOr ? @"vorr"
                                                                       : @"veor";
            [out appendFormat:@"\t%@\tq%ld, q%ld, q%ld\n", m, (long)d, (long)a, (long)b]; // 128-bit, no size
            }
        else
            {
            NSString* m = op == XTIROpVAdd ? @"vadd" : op == XTIROpVSub ? @"vsub"
                                                                        : @"vmul";
            [out appendFormat:@"\t%@.%@\tq%ld, q%ld, q%ld\n", m, arm9NeonI(res.type.pointeeType), (long)d, (long)a, (long)b];
            }
        return;
        }
    case XTIROpVMax:
    case XTIROpVMin:
        {
        if (ops.count < 2 || !res || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSInteger a = [self vqForValue:ops[0].valueId], b = [self vqForValue:ops[1].valueId], d = [self vqForValue:res.valueId];
        [out appendFormat:@"\t%@.%@\tq%ld, q%ld, q%ld\n", op == XTIROpVMax ? @"vmax" : @"vmin",
                          arm9NeonU(res.type.pointeeType), (long)d, (long)a, (long)b];
        return;
        }
    // vpaddl.<u> qD, qA  (widen pairwise ×2)
    case XTIROpVAddLP:
        {
        if (ops.count < 1 || ops[0].kind != XTIROperandKindUse || !res)
            return;
        NSInteger a = [self vqForValue:ops[0].valueId], d = [self vqForValue:res.valueId];
        [out appendFormat:@"\tvpaddl.%@\tq%ld, q%ld\n",
                          arm9NeonU([fn valueForId:ops[0].valueId].type.pointeeType), (long)d, (long)a];
        return;
        }
    // vcgt/vcge/vceq → 0/-1 lane mask
    case XTIROpVICmp:
        {
        if (ops.count < 2 || !res || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSInteger a = [self vqForValue:ops[0].valueId], b = [self vqForValue:ops[1].valueId], d = [self vqForValue:res.valueId];
        NSString* cm = nil;
        BOOL swap = NO, invert = NO;
        switch (in.predicate)
            {
        case XTIRICmpUGT:
        case XTIRICmpSGT:
            cm = @"vcgt";
            break;
        case XTIRICmpUGE:
        case XTIRICmpSGE:
            cm = @"vcge";
            break;
        case XTIRICmpULT:
        case XTIRICmpSLT:
            cm = @"vcgt";
            swap = YES;
            break;
        case XTIRICmpULE:
        case XTIRICmpSLE:
            cm = @"vcge";
            swap = YES;
            break;
        case XTIRICmpEQ:
            cm = @"vceq";
            break;
        case XTIRICmpNE:
            cm = @"vceq";
            invert = YES;
            break;
        default:
            return;
            }
        NSInteger lhs = swap ? b : a, rhs = swap ? a : b;
        // vceq takes the size-only suffix (i8/i16/i32); vcgt/vcge take sign+size.
        NSString* suf = [cm isEqualToString:@"vceq"] ? arm9NeonI(res.type.pointeeType)
                                                     : arm9NeonU(res.type.pointeeType);
        [out appendFormat:@"\t%@.%@\tq%ld, q%ld, q%ld\n", cm, suf, (long)d, (long)lhs, (long)rhs];
        if (invert)
            [out appendFormat:@"\tvmvn\tq%ld, q%ld\n", (long)d, (long)d];
        return;
        }
    // horizontal add of 4×i32 → GP scalar
    case XTIROpVReduceAdd:
        {
        if (ops.count < 1 || ops[0].kind != XTIROperandKindUse || !res)
            return;
        NSInteger q = [self vqForValue:ops[0].valueId];
        [out appendFormat:@"\tvadd.i32\td%ld, d%ld, d%ld\n", (long)(2 * q), (long)(2 * q), (long)(2 * q + 1)];
        [out appendFormat:@"\tvpadd.i32\td%ld, d%ld, d%ld\n", (long)(2 * q), (long)(2 * q), (long)(2 * q)];
        [out appendFormat:@"\tvmov.32\tr0, d%ld[0]\n", (long)(2 * q)];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }
    case XTIROpVReduceMax:
    // horizontal max/min of 4×i32
    case XTIROpVReduceMin:
        {
        if (ops.count < 1 || ops[0].kind != XTIROperandKindUse || !res)
            return;
        NSInteger q = [self vqForValue:ops[0].valueId];
        NSString* mx = op == XTIROpVReduceMax ? @"vmax" : @"vmin";
        NSString* pmx = op == XTIROpVReduceMax ? @"vpmax" : @"vpmin";
        NSString* su = arm9NeonU(res.type);
        [out appendFormat:@"\t%@.%@\td%ld, d%ld, d%ld\n", mx, su, (long)(2 * q), (long)(2 * q), (long)(2 * q + 1)];
        [out appendFormat:@"\t%@.%@\td%ld, d%ld, d%ld\n", pmx, su, (long)(2 * q), (long)(2 * q), (long)(2 * q)];
        [out appendFormat:@"\tvmov.32\tr0, d%ld[0]\n", (long)(2 * q)];
        [self storeResult:res from:@"r0" slot:slot out:out];
        return;
        }

    case XTIROpAsm:
        {
        // `asm { … }` — the body is emitted verbatim, as on arm64/x86-64.
        // Register homing and vector-register assignment are already
        // suppressed for any function containing one (see `hasAsm`), so a
        // body may refer to locals by their fixed sp-relative slots.
        XTIRConstantId cid = NSNotFound;
        for (XTIROperand* o in ops)
            if (o.kind == XTIROperandKindConstAgg)
                {
                cid = o.constantId;
                break;
                }
        if (cid == NSNotFound)
            return;
        XTIRConstant* c = [mod constantForId:cid];
        if (!c.stringBytes)
            return;
        NSString* text = [[NSString alloc] initWithData:c.stringBytes
                                               encoding:NSUTF8StringEncoding];
        if (!text)
            return;
        if ([text containsString:@"{{XTLOCAL:"])
            {
            NSRegularExpression* re =
                [NSRegularExpression regularExpressionWithPattern:@"\\{\\{XTLOCAL:(\\d+)\\}\\}"
                                                          options:0
                                                            error:NULL];
            NSMutableString* resolved = [text mutableCopy];
            for (NSTextCheckingResult* m in [[re matchesInString:text
                                                         options:0
                                                           range:NSMakeRange(0, text.length)]
                     reverseObjectEnumerator])
                {
                XTIRValueId vid = (XTIRValueId)[[text substringWithRange:[m rangeAtIndex:1]] integerValue];
                NSNumber* s = slot[@(vid)];
                [resolved replaceCharactersInRange:m.range
                                        withString:[NSString stringWithFormat:@"sp, #%ld",
                                                                              (long)(s ? s.integerValue : 0)]];
                }
            text = resolved;
            }
        [out appendString:@"\t@ inline asm\n"];
        for (NSString* line in [text componentsSeparatedByString:@"\n"])
            {
            NSString* t = [line stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
            if (t.length)
                [out appendFormat:@"\t%@\n", t];
            }
        return;
        }

    default:
        if (res && ![self isMemValue:res])
            {
            [out appendFormat:@"\tmov\tr0, #0\t\t@ TODO opcode %d\n", (int)op];
            [self storeResult:res from:@"r0" slot:slot out:out];
            fprintf(stderr, "xcc-cg-arm9: note: unhandled opcode %d in '%s' (placeholder emitted)\n",
                    (int)op, fn.name.UTF8String);
            }
        return;
        }
    }

// Emit the parallel phi-copies for the edge `from` → `to`.
+ (void)emitPhiEdgeFrom:(XTIRBlock*)from to:(XTIRBlock*)to fn:(XTIRFunction*)fn
                   slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                    out:(NSMutableString*)out
    {
    NSMutableArray<XTIRValue*>* dests = [NSMutableArray array];
    NSMutableArray<XTIROperand*>* srcs = [NSMutableArray array];
    for (XTIRInsn* phi in to.phiNodes)
        {
        if (phi.opcode != XTIROpPhi || !phi.result)
            continue;
        for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2)
            {
            XTIROperand* bop = phi.operands[i];
            if (bop.kind == XTIROperandKindBlock && bop.blockRef == from)
                {
                // An AGGREGATE phi is a slot-to-slot BLOCK COPY, not a one-word move.
                // A struct value always lives in a frame slot, so routing it through r0
                // copied only its first FOUR BYTES and left the rest as whatever the
                // frame held — on arm9 that is the 0xa5a5 stack poison, so an 8-byte
                // Rect through a ternary came back with garbage w/h. (arm64 and m68k had
                // the same bug; they just happened to read zeros.)
                XTIROperand* vop = phi.operands[i + 1];
                XTIRType* pty = phi.result.type;
                // A VECTOR phi lives in a q-register, not a slot — never route
                // it through r0. Coalesced (same q) ⇒ no-op; a SHARED preheader
                // incoming (one init splat feeding U accumulator phis, #1198)
                // coalesces with only one phi, so the others need a q-to-q move
                // (vorr is the NEON register move; the srcs all being the one
                // shared register, in-order emission cannot lose a copy).
                if (pty && pty.kind == XTIRTypeKindVec)
                    {
                    NSNumber* dq = sVecReg[@(phi.result.valueId)];
                    NSNumber* sq = vop.kind == XTIROperandKindUse ? sVecReg[@(vop.valueId)] : nil;
                    if (dq && sq && ![dq isEqualToNumber:sq])
                        [out appendFormat:@"\tvorr\tq%@, q%@, q%@\n", dq, sq, sq];
                    break;
                    }
                NSNumber* dstSlot = slot[@(phi.result.valueId)];
                // The SAME argument for an i64 — and for a DOUBLE, which is the
                // same eight bytes in the same kind of slot. The one-word path
                // below left the other half holding whatever the frame did: a
                // `u64` loop variable kept 0xa5a5a5a5 up there, so `v > 0` was
                // permanently true and String.withU64 spun forever, and a
                // double through a ternary lost its value outright.
                if (pty && (pty.kind == XTIRTypeKindI64 || pty.kind == XTIRTypeKindU64 || pty.kind == XTIRTypeKindF64) && dstSlot)
                    {
                    if (vop.kind == XTIROperandKindUse && slot[@(vop.valueId)])
                        {
                        NSUInteger so = slot[@(vop.valueId)].unsignedIntegerValue;
                        NSUInteger dd = dstSlot.unsignedIntegerValue;
                        [self emitSpAccess:@"ldr" reg:@"r0" off:so out:out];
                        [self emitSpAccess:@"str" reg:@"r0" off:dd out:out];
                        [self emitSpAccess:@"ldr" reg:@"r0" off:so + 4 out:out];
                        [self emitSpAccess:@"str" reg:@"r0" off:dd + 4 out:out];
                        break;
                        }
                    // An immediate source, integer or float: the bits are laid
                    // down directly. arm9 is LITTLE-endian, so the low word is
                    // at the lower address.
                    if (vop.kind == XTIROperandKindImmI || vop.kind == XTIROperandKindImmF)
                        {
                        uint64_t iv = (vop.kind == XTIROperandKindImmF)
                                          ? vop.floatRawBytes
                                          : (uint64_t)vop.intValue;
                        NSUInteger dd = dstSlot.unsignedIntegerValue;
                        [self emitMovImm:(int64_t)(uint32_t)(iv & 0xFFFFFFFFu) reg:@"r0" into:out];
                        [self emitSpAccess:@"str" reg:@"r0" off:dd out:out];
                        [self emitMovImm:(int64_t)(uint32_t)(iv >> 32) reg:@"r0" into:out];
                        [self emitSpAccess:@"str" reg:@"r0" off:dd + 4 out:out];
                        break;
                        }
                    }
                if (pty && pty.kind == XTIRTypeKindAgg && vop.kind == XTIROperandKindUse && dstSlot)
                    {
                    // r1 = sp + dstSlot. (movw/movt then add, so a big frame offset
                    // does not overflow the add's 8-bit rotated immediate.)
                    [out appendFormat:@"\tmovw\tr1, #%lu\n", (unsigned long)(dstSlot.unsignedIntegerValue & 0xFFFF)];
                    [out appendFormat:@"\tmovt\tr1, #%lu\n", (unsigned long)((dstSlot.unsignedIntegerValue >> 16) & 0xFFFF)];
                    [out appendString:@"\tadd\tr1, r1, sp\n"];
                    [self emitBlockCopyFromSlot:fn.values[@(vop.valueId)]
                                             to:@"r1"
                                           size:[self aggSize:pty.layout]
                                           slot:slot
                                            out:out];
                    break;
                    }
                [dests addObject:phi.result];
                [srcs addObject:vop];
                break;
                }
            }
        }
    NSUInteger n = dests.count;
    if (n == 0)
        return;
    // Phi copies are a PARALLEL assignment. A naive in-order emission is wrong
    // when one copy's SOURCE is a SIBLING copy's DEST — after an inner loop
    // unrolls, `v0 <- lc4` runs next to `lc4 <- lc4+1`, and copying lc4 first
    // hands v0 the post-increment value (a lost copy → nested counter one too
    // high). Emit in dependency order: a copy whose dest is not read by any
    // pending copy goes first. (A stack shuffle is unusable here — arm9 slots are
    // sp-relative, so a push would shift every [sp,#off] mid-sequence; arm64 and
    // xt6502 use this same value-ordering.) A residual true cycle (a swap) is
    // rare; break it by picking the first pending copy (matches arm64).
    NSMutableIndexSet* pending = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, n)];
    while (pending.count)
        {
        NSInteger pick = -1;
        for (NSUInteger idx = pending.firstIndex; idx != NSNotFound;
             idx = [pending indexGreaterThanIndex:idx])
            {
            XTIRValueId did = dests[idx].valueId;
            BOOL blocked = NO;
            for (NSUInteger o = pending.firstIndex; o != NSNotFound;
                 o = [pending indexGreaterThanIndex:o])
                {
                if (o == idx)
                    continue;
                if (srcs[o].kind == XTIROperandKindUse && srcs[o].valueId == did)
                    {
                    blocked = YES;
                    break;
                    }
                }
            if (!blocked)
                {
                pick = (NSInteger)idx;
                break;
                }
            }
        if (pick >= 0)
            {
            [self loadOperand:srcs[(NSUInteger)pick] into:@"r0" slot:slot out:out];
            [self storeResult:dests[(NSUInteger)pick] from:@"r0" slot:slot out:out];
            [pending removeIndex:(NSUInteger)pick];
            continue;
            }
        // Residual cycle: every pending copy's DEST is another copy's SOURCE, so
        // no single-step order is safe — a swap `%a<-%b, %b<-%a` copied in place
        // loses one value (bug 199: loop-swapped class-pointer locals came back
        // unchanged). arm9 slots are sp-relative so a stack shuffle would shift
        // every [sp,#off]; instead read EVERY source into its own scratch
        // register (r0/r2/r3 — never home registers, homes are r4-r11), then
        // write every dest. Only 32-bit scalars reach here (i64/double/agg phis
        // are copied inline above), so one GP register per member suffices. A
        // cycle wider than the 3-register pool falls back to the in-place single
        // step, no worse than pre-fix.
        NSArray<NSString*>* pool = @[ @"r0", @"r2", @"r3" ];
        if (pending.count > pool.count)
            {
            NSUInteger fb = pending.firstIndex;
            [self loadOperand:srcs[fb] into:@"r0" slot:slot out:out];
            [self storeResult:dests[fb] from:@"r0" slot:slot out:out];
            [pending removeIndex:fb];
            continue;
            }
        NSMutableArray<NSNumber*>* cyc = [NSMutableArray array];
        for (NSUInteger idx = pending.firstIndex; idx != NSNotFound;
             idx = [pending indexGreaterThanIndex:idx])
            [cyc addObject:@(idx)];
        for (NSUInteger k = 0; k < cyc.count; k++)
            [self loadOperand:srcs[cyc[k].unsignedIntegerValue] into:pool[k] slot:slot out:out];
        for (NSUInteger k = 0; k < cyc.count; k++)
            {
            [self storeResult:dests[cyc[k].unsignedIntegerValue] from:pool[k] slot:slot out:out];
            [pending removeIndex:cyc[k].unsignedIntegerValue];
            }
        }
    }

+ (void)emitTerminator:(XTIRInsn*)t fn:(XTIRFunction*)fn block:(XTIRBlock*)blk
                module:(XTIRModule*)mod
                  slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                 frame:(NSUInteger)frame
              nativeVa:(BOOL)nativeVa
                   out:(NSMutableString*)out
    {
    switch (t.opcode)
        {
    case XTIROpUnreachable:
        {
        // A failed CHECKED downcast `(T*)p` lands here, and it is
        // reachable — the comment this replaces claimed otherwise. Falling
        // through meant the cast silently succeeded with a mistyped pointer
        // and the program carried on; on the hosts it then exited 0, so a
        // failed cast looked like a clean run to any script checking status.
        // A checked cast failing is an assertion the programmer got wrong,
        // so it aborts — loudly, and with a non-zero status — everywhere.
        // Use `(T* ?)p` when failure is a possibility rather than a bug.
        [out appendString:@"\tudf\t#0\n"];
        return;
        }
    case XTIROpReturn:
        {
        XTIROperand* rv = nil;
        if (t.operands.count >= 1 && t.operands[0].kind != XTIROperandKindBlock && !(t.operands[0].kind == XTIROperandKindUse && [self isMemValue:fn.values[@(t.operands[0].valueId)]]))
            rv = t.operands[0];
        XTIRType* rvt = rv && rv.kind == XTIROperandKindUse ? fn.values[@(rv.valueId)].type
                        : rv                                ? rv.type
                                                            : nil;
        if (rv && rvt && rvt.kind == XTIRTypeKindAgg && [self returnsViaSret:fn.returnType])
            {
            // sret: copy the aggregate from its slot to [savedResultPtr]; r0 = ptr.
            NSNumber* sp_ = slot[@(kSretSlotKey)];
            NSNumber* vs = slot[@(rv.valueId)];
            [self emitSpAccess:@"ldr" reg:@"r1" off:(sp_ ? sp_.unsignedIntegerValue : 0)out:out];
            [self emitBlockCopyFromSlot:fn.values[@(rv.valueId)]
                                     to:@"r1"
                                   size:[self aggSize:rvt.layout]
                                   slot:slot
                                    out:out];
            (void)vs;
            [out appendString:@"\tmov\tr0, r1\n"];
            }
        else if (rv && rvt && (rvt.kind == XTIRTypeKindF64 || rvt.kind == XTIRTypeKindI64 || rvt.kind == XTIRTypeKindU64))
            {
            // softfp: double / i64 returned in r0:r1 (two words from its
            // slot). Without the i64 arm the scalar path below loaded r0
            // alone and the caller took the callee's leftover r1 as the
            // high half — a correct low word and a garbage high one.
            NSNumber* vs = (rv.kind == XTIROperandKindUse) ? slot[@(rv.valueId)] : nil;
            NSUInteger so = vs ? vs.unsignedIntegerValue : 0;
            [self emitSpAccess:@"ldr" reg:@"r0" off:so out:out];
            [self emitSpAccess:@"ldr" reg:@"r1" off:so + 4 out:out];
            }
        else if (rv)
            {
            // Scalar or small (≤4-byte) aggregate → r0 (one word). Canonicalise
            // a narrow scalar return to its declared width (the AAPCS callee
            // contract — and so a caller comparing it sees clean bits, e.g.
            // negate()'s 0-10 → 0x000000F6, not 0xFFFFFFF6).
            [self loadOperand:rv into:@"r0" slot:slot out:out];
            if (!(rvt && rvt.kind == XTIRTypeKindAgg))
                [self canonicaliseReg:@"r0" toType:fn.returnType out:out];
            }
        [self emitFrameReturnNativeVa:nativeVa frame:frame out:out];
        return;
        }
    case XTIROpBranch:
        if (t.operands.count >= 1 && t.operands[0].kind == XTIROperandKindBlock)
            {
            XTIRBlock* tgt = t.operands[0].blockRef;
            [self emitPhiEdgeFrom:blk to:tgt fn:fn slot:slot out:out];
            [out appendFormat:@"\tb\t%@\n", [self blockLabel:tgt fn:fn]];
            }
        return;
    case XTIROpCondBranch:
        {
        // operands: cond, trueBlk, falseBlk
        XTIROperand* cond = nil;
        XTIRBlock *tb = nil, *fb = nil;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind == XTIROperandKindBlock)
                {
                if (!tb)
                    tb = o.blockRef;
                else if (!fb)
                    fb = o.blockRef;
                }
            else if (!cond)
                cond = o;
            }
        NSString* flab = [NSString stringWithFormat:@".L_%@_%@_f", fn.name, blk.name ?: @"b"];
        XTIRInsn* fcmp = (cond && cond.kind == XTIROperandKindUse && sFusedCmp && [sFusedCmp containsObject:@(cond.valueId)] && sDefOf)
                             ? sDefOf[@(cond.valueId)]
                             : nil;
        if (fcmp && fcmp.operands.count >= 2)
            {
            // Fused: re-emit the compare here and branch on its condition,
            // so the boolean is never built. Branch to the FALSE label on
            // the INVERSE, matching the unfused shape below.
            [self loadOperand:fcmp.operands[0] into:@"r0" slot:slot out:out];
            [self loadOperand:fcmp.operands[1] into:@"r1" slot:slot out:out];
            [out appendString:@"\tcmp\tr0, r1\n"];
            [out appendFormat:@"\tb%@\t%@\n",
                              [self invCond:[self condForICmp:fcmp.predicate]], flab];
            }
        else
            {
            if (cond)
                [self loadCondition:cond into:@"r0" scratch:@"r1" slot:slot fn:fn out:out];
            else
                [self loadOperand:cond into:@"r0" slot:slot out:out];
            [out appendString:@"\tcmp\tr0, #0\n"];
            [out appendFormat:@"\tbeq\t%@\n", flab];
            }
        if (tb)
            {
            [self emitPhiEdgeFrom:blk to:tb fn:fn slot:slot out:out];
            [out appendFormat:@"\tb\t%@\n", [self blockLabel:tb fn:fn]];
            }
        [out appendFormat:@"%@:\n", flab];
        if (fb)
            {
            [self emitPhiEdgeFrom:blk to:fb fn:fn slot:slot out:out];
            [out appendFormat:@"\tb\t%@\n", [self blockLabel:fb fn:fn]];
            }
        return;
        }
    default:
        [out appendFormat:@"\t@ TODO terminator %d\n", (int)t.opcode];
        [self emitFrameReturnNativeVa:nativeVa frame:frame out:out];
        return;
        }
    }

// ── per-function ────────────────────────────────────────────────────────────

// Frame teardown + return. A native-va_list variadic function pushed {r0-r3} at
// entry (the AAPCS va_list save area), so it drops those 16 bytes and returns via
// lr; every other function pops pc directly.
+ (void)emitFrameReturnNativeVa:(BOOL)nativeVa frame:(NSUInteger)frame
                            out:(NSMutableString*)out
    {
    if (frame)
        [self emitAlu:@"add" dst:@"sp" lhs:@"sp" imm:frame scratch:@"r12" out:out];
    if (nativeVa)
        [out appendString:@"\tpop\t{r4-r11, lr}\n\tadd\tsp, sp, #16\n\tbx\tlr\n"];
    else
        [out appendString:@"\tpop\t{r4-r11, pc}\n"];
    }

+ (void)emitFunction:(XTIRFunction*)fn module:(XTIRModule*)mod into:(NSMutableString*)out
    {
    NSString* label = fn.name; // ELF ARM: bare symbol names (no leading underscore)
    [out appendFormat:@"\t.global\t%@\n\t.type\t%@, %%function\n", label, label];
    // PIC: hide internal symbols so their references stay non-preemptible
    // (R_ARM_RELATIVE, not ABS32/GLOB_DAT). `main` keeps default visibility so
    // the loader resolves the entry from .dynsym. In library mode (--emit-lib)
    // every function is part of the exported API — keep default visibility so an
    // app can link against it.
    if (sPIC && !sEmitLib && ![label isEqualToString:@"main"])
        [out appendFormat:@"\t.hidden\t%@\n", label];
    [out appendFormat:@"%@:\n", label];

    // Register homing. GP pool = the callee-saved r4-r11 (the prologue already
    // pushes them, so no extra save/restore). No caller-saved tier on arm9: every
    // caller-saved reg (r0-r3, r12) is used as scratch. FP homing is not wired yet
    // (floats stay in slots). A function with inline asm is skipped — an asm block
    // may reference a local by its fixed sp-relative slot.
    BOOL hasAsm = NO;
    for (XTIRBlock* ab in fn.blocks)
        for (XTIRInsn* ai in ab.instructions)
            if (ai.opcode == XTIROpAsm)
                {
                hasAsm = YES;
                break;
                }
    if (hasAsm)
        {
        sHome = nil;
        }
    else
        {
        // A 64-bit value occupies two words and cannot live in one home. Left
        // homeable, the allocator puts it in (say) r5 while every consumer
        // reads its SLOT — so the value is written to a register and read from
        // memory nothing wrote, which shows up as a correct low half and a
        // garbage high half. m68k had exactly this.
        NSMutableSet<NSNumber*>* wide = [NSMutableSet set];
        for (XTIRBlock* wb in fn.blocks)
            for (XTIRInsn* wi in wb.instructions)
                if (wi.result && (wi.result.type.kind == XTIRTypeKindI64 || wi.result.type.kind == XTIRTypeKindU64))
                    [wide addObject:@(wi.result.valueId)];
        // A PARAMETER is not an instruction result, so the loop above misses it:
        // `i64 add(i64 a, i64 b)` homed a into r4 holding only its low word.
        // Param value id is its positional index.
        for (NSUInteger paramPos = 0; paramPos < fn.paramTypes.count; paramPos++)
            {
            XTIRType* pt = fn.paramTypes[paramPos];
            if (pt.kind == XTIRTypeKindI64 || pt.kind == XTIRTypeKindU64)
                [wide addObject:@(paramPos)];
            }
        XTHomingResult* hr = [XTHomingAllocator assignHomesForFunction:fn
                                                              gpCallee:@[ @"r4", @"r5", @"r6", @"r7", @"r8", @"r9", @"r10", @"r11" ]
                                                              gpCaller:@[]
                                                              fpCallee:@[]
                                                              fpCaller:@[]
                                                              excluded:wide];
        sHome = hr.homeReg;
        }
    sVecReg = hasAsm ? nil : [self assignVectorRegsForFunction:fn];
        {
        NSMutableDictionary<NSNumber*, XTIRInsn*>* dm = [NSMutableDictionary dictionary];
        for (XTIRBlock* ab in fn.blocks)
            for (XTIRInsn* ai in ab.instructions)
                if (ai.result)
                    dm[@(ai.result.valueId)] = ai;
        sDefOf = dm;

        // Backend DCE for constant chains orphaned by the VSplat const-inline:
        // an insn is skippable iff it's a pure Const/ext whose result is consumed
        // ONLY by constant-inlined VSplat scalars or by other skippable insns.
        // Build use-sites, then iterate to a fixpoint.
        NSMutableDictionary<NSNumber*, NSMutableArray<XTIRInsn*>*>* uses = [NSMutableDictionary dictionary];
        for (XTIRBlock* ab in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:ab.phiNodes];
            [all addObjectsFromArray:ab.instructions];
            if (ab.terminator)
                [all addObject:ab.terminator];
            for (XTIRInsn* ai in all)
                for (XTIROperand* o in ai.operands)
                    if (o.kind == XTIROperandKindUse)
                        {
                        NSMutableArray<XTIRInsn*>* u = uses[@(o.valueId)];
                        if (!u)
                            {
                            u = [NSMutableArray array];
                            uses[@(o.valueId)] = u;
                            }
                        [u addObject:ai];
                        }
            }
        NSMutableSet<NSNumber*>* skip = [NSMutableSet set];
        BOOL (^inlinedByVSplat)(XTIRInsn*, XTIRValueId) = ^BOOL(XTIRInsn* u, XTIRValueId v) {
          int64_t c;
          return u.opcode == XTIROpVSplat && u.operands.count >= 1 && u.operands[0].kind == XTIROperandKindUse && u.operands[0].valueId == v && arm9TraceConst(v, &c);
        };
        BOOL changed = YES;
        while (changed)
            {
            changed = NO;
            for (NSNumber* vid in dm)
                {
                if ([skip containsObject:vid])
                    continue;
                XTIRInsn* def = dm[vid];
                XTIROpcode dop = def.opcode;
                if (dop != XTIROpConst && dop != XTIROpZExt && dop != XTIROpSExt && dop != XTIROpTrunc && dop != XTIROpBitcast)
                    continue;
                BOOL allDead = YES;
                for (XTIRInsn* u in uses[vid])
                    if (!inlinedByVSplat(u, vid.unsignedIntegerValue) && !(u.result && [skip containsObject:@(u.result.valueId)]))
                        {
                        allDead = NO;
                        break;
                        }
                if (allDead)
                    {
                    [skip addObject:vid];
                    changed = YES;
                    }
                }
            }

        // Post-index fusion pairing. An ElementAddr `P + k` that advances a
        // pointer-IV by exactly one vector width (k·stride == 16, the {dN,dN+1}
        // load/store auto-increment) is folded into the VLoad/VStore that reads P:
        // that op emits `[rN]!` and writes the post-incremented rN to the
        // advance's home, so the separate `add` is dropped. Requirements, per the
        // block the advance lives in:
        //   • P is the address of exactly ONE VLoad/VStore, and it's in this block
        //     (so the fused post-increment runs where the `add` would have);
        //   • the advance's RESULT is not read anywhere in this block. SSA
        //     dominance then puts every reader in a phi edge or a dominated
        //     successor block — both run after this block exits, so deferring the
        //     advance to the load/store here changes nothing they observe.
        // (After unrolling the advanced pointer feeds the NEXT copy's block, so
        // "no in-block reader" holds even though it isn't purely phi-carried.)
        NSMutableDictionary<NSNumber*, XTIRInsn*>* postInc = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* ea in bb.instructions)
                {
                if (ea.opcode != XTIROpElementAddr || ea.operands.count < 2 || !ea.result)
                    continue;
                if (ea.operands[1].kind != XTIROperandKindImmI)
                    continue;
                uint32_t es = [self elemSizeFor:ea fn:fn];
                if ((int64_t)es * ea.operands[1].intValue != 16)
                    continue;
                if (ea.operands[0].kind != XTIROperandKindUse)
                    continue;
                XTIRValueId pid = ea.operands[0].valueId;
                // Exactly one memory op is addressed by P, and it's in this block.
                XTIRInsn* memOp = nil;
                NSUInteger nAddr = 0;
                for (XTIRInsn* u in uses[@(pid)])
                    {
                    if ((u.opcode != XTIROpVLoad && u.opcode != XTIROpVStore) || u.operands.count < 1 || u.operands[0].kind != XTIROperandKindUse || u.operands[0].valueId != pid)
                        continue;
                    nAddr++;
                    memOp = u;
                    }
                if (nAddr != 1 || [bb.instructions indexOfObjectIdenticalTo:memOp] == NSNotFound)
                    continue;
                // The advanced pointer must not be read within this block.
                BOOL safe = YES;
                for (XTIRInsn* u in uses[@(ea.result.valueId)])
                    if (u.opcode != XTIROpPhi && [bb.instructions indexOfObjectIdenticalTo:u] != NSNotFound)
                        {
                        safe = NO;
                        break;
                        }
                if (!safe)
                    continue;
                postInc[@(pid)] = ea;
                [skip addObject:@(ea.result.valueId)]; // drop the advance `add`
                }
            }
        sNoEmit = skip;
        sPostIncEA = postInc;

        // Compare-branch fusion. Conditions, all necessary:
        //   * the block's terminator is a CondBranch on this value,
        //   * the value is defined by an ICmp in the SAME block,
        //   * that ICmp is the block's LAST instruction, so nothing between it
        //     and the branch can clobber the flags (the phi-edge moves this
        //     terminator emits come AFTER the branch, and `mov` without S does
        //     not write flags anyway),
        //   * it has exactly ONE use — the branch. A second reader still needs
        //     the boolean as a value.
        //   * and it is a 32-bit compare: the i64 path is `subs`+`sbcs` with its
        //     own operand swapping, not one `cmp`, so it is left alone.
        NSMutableSet<NSNumber*>* fused = [NSMutableSet set];
        for (XTIRBlock* bb in fn.blocks)
            {
            XTIRInsn* term = bb.terminator;
            if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 1)
                continue;
            XTIROperand* cop = nil;
            for (XTIROperand* o in term.operands)
                if (o.kind == XTIROperandKindUse)
                    {
                    cop = o;
                    break;
                    }
            if (!cop)
                continue;
            XTIRInsn* last = bb.instructions.lastObject;
            if (!last || last.opcode != XTIROpICmp || !last.result)
                continue;
            if (last.result.valueId != cop.valueId)
                continue;
            if (uses[@(cop.valueId)].count != 1)
                continue;
            BOOL wide = NO;
            for (XTIROperand* o in last.operands)
                {
                XTIRType* t = [self typeOfOperand:o fn:fn];
                if (t && (t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64))
                    wide = YES;
                }
            if (wide)
                continue;
            if (![self condForICmp:last.predicate])
                continue;
            [fused addObject:@(cop.valueId)];
            }
        sFusedCmp = fused;
        }

    // Give every value a byte-offset frame slot, sized by its A32-native type
    // width. Iterating 0..nextValueId covers params, instruction/phi results AND
    // pinned locals (which are never an instruction result — they only appear as
    // AddrOf operands, so the old result-only walk missed them). A scalar/pointer
    // gets a 4-byte (register-width) slot; an aggregate pinned local gets its full
    // A32 size, so AddrOf of it yields real addressable frame storage.
    // Reserve an outgoing-argument stack area at the BOTTOM of the frame, sized
    // to the largest stack-passed-argument footprint of any call we make. Stack
    // args then live at [sp,#0..] with no sp movement around calls; value slots
    // sit above the area (and above the saved-sret-ptr word, if any).
    NSUInteger maxOutStack = 0;
    BOOL sret = [self returnsViaSret:fn.returnType];
    // A native-AAPCS-va_list variadic function (one with a VaStart op) saves its
    // incoming r0-r3 contiguous with the stack args, so `va_start` yields a real
    // va_list it can hand to libc vprintf.
    BOOL nativeVa = NO;
    for (XTIRBlock* b in fn.blocks)
        for (XTIRInsn* vin in b.instructions)
            if (vin.opcode == XTIROpVaStart)
                {
                nativeVa = YES;
                break;
                }
    // A FORWARDER — `printf(fmt, ...)` — has no VaStart of its own, but it still
    // needs its incoming r0-r3 homed contiguously with its stack args, because
    // that block IS the tail it relays. private:docs/bugs/047.
    XTIRSymbol* ownSym = [mod symbolForName:fn.name];
    BOOL vaForward = ownSym.attributes[@"vaforward"].boolValue;
    if (vaForward)
        nativeVa = YES;
    for (XTIRBlock* b in fn.blocks)
        {
        for (XTIRInsn* in in b.instructions)
            {
            if (in.opcode != XTIROpCall && in.opcode != XTIROpCallIndirect &&
                in.opcode != XTIROpCallCloaked && in.opcode != XTIROpCallBanked &&
                in.opcode != XTIROpCallBankedIndirect && in.opcode != XTIROpVTblDispatch &&
                in.opcode != XTIROpProtoDispatch)
                continue;
            BOOL cIndirect = (in.opcode == XTIROpCallIndirect ||
                              in.opcode == XTIROpCallBankedIndirect);
            BOOL cVtbl = (in.opcode == XTIROpVTblDispatch);
            // ProtoDispatch (itable call) also passes args and so needs its stack
            // footprint reserved — WITHOUT it, a stack arg gets written over a local
            // at [sp,#0..] (the outgoing area was never reserved). Its ImmI protoId
            // (idx 1) and methodIndex (idx 2) are not args; the receiver (idx 0) is.
            BOOL cProto = (in.opcode == XTIROpProtoDispatch);
            NSMutableArray<XTIRType*>* ats = [NSMutableArray array];
            for (NSUInteger idx = 0; idx < in.operands.count; idx++)
                {
                if (cIndirect && idx == 0)
                    continue; // callee fn-pointer, not an arg
                if (cVtbl && idx == 1)
                    continue; // ImmI slot index, not an arg
                if (cProto && (idx == 1 || idx == 2))
                    continue; // ImmI protoId + methodIndex
                XTIROperand* o = in.operands[idx];
                if (o.kind == XTIROperandKindUse && ![self isMemValue:fn.values[@(o.valueId)]])
                    [ats addObject:(fn.values[@(o.valueId)].type ?: (id)[NSNull null])];
                }
            BOOL cSret = in.result && ![self isMemValue:in.result] && [self returnsViaSret:in.result.type];
            NSUInteger sb = 0;
            NSString* cCallee = nil;
            for (XTIROperand* o in in.operands)
                if (o.kind == XTIROperandKindSym)
                    {
                    cCallee = [mod symbolForId:o.symbolId].name;
                    break;
                    }
            NSUInteger cVaAt = cIndirect ? NSNotFound
                                         : [self varargTailIndexFor:cCallee module:mod];
            NSArray<NSArray<NSNumber*>*>* clocs =
                [self classifyArgTypes:ats
                                  sret:cSret
                              varargAt:cVaAt
                         outStackBytes:&sb];
            // A forwarding call also writes the relayed tail into the outgoing
            // area, past whatever the explicit args used — reserve for it or the
            // relay lands on this function's own locals.
            if (vaForward && in.opcode == XTIROpCall)
                {
                NSUInteger k = cSret ? 1 : 0;
                for (NSArray<NSNumber*>* L in clocs)
                    k += L[1].unsignedIntegerValue;
                NSUInteger last = k + kArm9VaForwardWords; // one past the last slot
                if (last > 4)
                    {
                    NSUInteger need = (last - 4) * 4;
                    if (need > sb)
                        sb = need;
                    }
                }
            if (sb > maxOutStack)
                maxOutStack = sb;
            }
        }
    maxOutStack = (maxOutStack + 7) & ~(NSUInteger)7;
    // Publish the outgoing-argument boundary for the spill peephole. Everything
    // BELOW it at [sp,#0..maxOutStack) is an argument the CALLEE reads, so no
    // load in this function refers to it and a load count would call it dead.
    // Above it, every slot is this frame's own and the count is exact — which is
    // what lets dead-store removal work in a function that makes calls, instead
    // of only in leaves.
    sOutArgBytes = maxOutStack;

    NSMutableDictionary<NSNumber*, NSNumber*>* slot = [NSMutableDictionary dictionary];
    NSUInteger cur = maxOutStack;
    // saved result pointer
    if (sret)
        {
        slot[@(kSretSlotKey)] = @(cur);
        cur += 4;
        }
    // PRINT order, not id order — see valuesInPrintOrder (bug 090).
    for (XTIRValue* v in [fn valuesInPrintOrder])
        {
        if ([self isMemValue:v])
            continue;
        slot[@(v.valueId)] = @(cur);
        NSUInteger w = [self fieldWidth:v.type];
        if (w < 4)
            w = 4;                    // min register-width slot
        w = (w + 3) & ~(NSUInteger)3; // round up to 4
        cur += w;
        }
    NSUInteger frame = (cur + 7) & ~(NSUInteger)7;
    // AAPCS requires SP 8-byte aligned at a public call. `push {r4-r11, lr}` is
    // 9 words (36 bytes) — odd, so it leaves SP 8-misaligned — and `frame` is
    // already a multiple of 8, so the sub doesn't fix it. Pad the frame to make
    // (36 + frame) a multiple of 8. Without this, a variadic callee that reads a
    // double off its stack save area (libc printf "%f") sees garbage. The single
    // computation flows to both the prologue sub and the epilogue add.
    if ((36 + frame) & 7)
        frame += 4;

    // Native va_list save area: push {r0-r3} FIRST so [r0,r1,r2,r3|incoming stack
    // args] is one contiguous block just below the caller's stack args. va_start
    // points into it; the epilogue drops the 16 bytes (see emitFrameReturnNativeVa).
    if (nativeVa)
        [out appendString:@"\tpush\t{r0-r3}\n"];
    [out appendString:@"\tpush\t{r4-r11, lr}\n"];
    if (frame)
        [self emitAlu:@"sub" dst:@"sp" lhs:@"sp" imm:frame scratch:@"r12" out:out];

    // sret: save the incoming hidden result pointer (r0) for Return to use.
    if (sret)
        [self emitSpAccess:@"str"
                       reg:@"r0"
                       off:slot[@(kSretSlotKey)].unsignedIntegerValue
                       out:out];

    // Spill params (AAPCS32). Aggregate params arrive split across r0–r3 + the
    // incoming stack area; copy each word into the param's frame slot.
    NSMutableArray<XTIRType*>* ptypes = [NSMutableArray array];
    NSMutableArray<NSNumber*>* pvids = [NSMutableArray array];
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        {
        XTIRValue* pv = fn.values[@(i)];
        if (!pv || [self isMemValue:pv])
            continue;
        [ptypes addObject:(pv.type ?: (id)[NSNull null])];
        [pvids addObject:@(i)];
        }
    NSArray<NSArray<NSNumber*>*>* plocs =
        [self classifyArgTypes:ptypes
                          sret:sret
                 outStackBytes:NULL];
    // va_list base = saved-r0 (at sp+frame+36) + the bytes the named args (incl. an
    // sret ptr) consumed in r0-r3 → the address of the first VARIADIC arg.
    NSUInteger vaListOff = 0;
    if (nativeVa)
        {
        NSUInteger usedRegWords = sret ? 1 : 0;
        for (NSArray<NSNumber*>* L in plocs)
            usedRegWords += L[1].unsignedIntegerValue;
        // The tail starts 8-ALIGNED — the caller placed it there (see
        // classifyArgTypes:varargAt:), so the base must be computed the same way
        // or the two disagree by a word.
        if (usedRegWords & 1)
            usedRegWords++;
        if (usedRegWords > 4)
            usedRegWords = 4;
        vaListOff = frame + 36 + usedRegWords * 4;
        }
    for (NSUInteger i = 0; i < pvids.count; i++)
        {
        NSNumber* s = slot[pvids[i]];
        if (!s)
            continue;
        NSUInteger so = s.unsignedIntegerValue;
        NSArray<NSNumber*>* L = plocs[i];
        NSUInteger regStart = L[0].unsignedIntegerValue, regWords = L[1].unsignedIntegerValue;
        NSUInteger stOff = L[2].unsignedIntegerValue, stWords = L[3].unsignedIntegerValue;
        for (NSUInteger k = 0; k < regWords; k++)
            [self emitSpAccess:@"str"
                           reg:[NSString stringWithFormat:@"r%lu", (unsigned long)(regStart + k)]
                           off:so + 4 * k
                           out:out];
        // Incoming stack words: above our saved regs + frame (9 saved × 4 = 36).
        // (Large-offset note: the str below keeps r12 as the data reg, so it can't
        // route through emitSpAccess's r12 base — only hit by a function with
        // stack-passed params AND a >4 KB frame, which no current fixture is.)
        for (NSUInteger k = 0; k < stWords; k++)
            {
            [self emitSpAccess:@"ldr" reg:@"r12" off:frame + 36 + stOff + 4 * k out:out];
            [out appendFormat:@"\tstr\tr12, [sp, #%lu]\n",
                              (unsigned long)(so + 4 * (regWords + k))];
            }
        // A homed param: seed its home register from the incoming value (a scalar
        // occupies one arg reg, or sits in the slot when stack-passed).
        NSString* home = sHome[pvids[i]];
        if (home)
            {
            if (regWords >= 1)
                [out appendFormat:@"\tmov\t%@, r%lu\n", home, (unsigned long)regStart];
            else
                [self emitSpAccess:@"ldr" reg:home off:so out:out];
            }
        }

    // Intra-block literal-pool flushing: a `ldr rX, =sym` must reach its pool
    // within ARM's ±4 KB load range. Per-block/per-function .ltorg (below) covers
    // ordinary code, but a SINGLE basic block can exceed 4 KB (e.g. stack_class's
    // main, with many inlined class inits) — then the pool at the block end is out
    // of reach of an early ldr=. So also flush mid-block once enough code has
    // accumulated, branching over the inline pool so it's never executed. The
    // threshold is in emitted-text bytes (a safe proxy: ~15 B/insn ⇒ <3 KB code
    // per pool, well under the 4 KB limit).
    NSUInteger lastPoolLen = out.length;
    NSUInteger poolSeq = 0;
    for (XTIRBlock* b in fn.blocks)
        {
        [out appendFormat:@"%@:\n", [self blockLabel:b fn:fn]];
        for (XTIRInsn* in in b.instructions)
            {
            [self emitInsn:in fn:fn module:mod slot:slot vaListOff:vaListOff out:out];
            if (sPIC && out.length - lastPoolLen > 8000)
                {
                NSString* skip = [NSString stringWithFormat:@".Lpool_%@_%lu",
                                                            label, (unsigned long)poolSeq++];
                [out appendFormat:@"\tb\t%@\n\t.ltorg\n%@:\n", skip, skip];
                lastPoolLen = out.length;
                }
            }
        if (b.terminator)
            [self emitTerminator:b.terminator
                              fn:fn
                           block:b
                          module:mod
                            slot:slot
                           frame:frame
                        nativeVa:nativeVa
                             out:out];
        else // fallthrough safety
            [self emitFrameReturnNativeVa:nativeVa frame:frame out:out];
        // PIC: flush the literal pool after each block so a `ldr rX, =sym` early
        // in a large (>4 KB) function still reaches its pool. Safe because every
        // block ends in a non-fall-through terminator (`b` or `pop {pc}`), so the
        // inline pool is branched over, never executed.
        if (sPIC)
            {
            [out appendString:@"\t.ltorg\n"];
            lastPoolLen = out.length;
            }
        }
    [out appendFormat:@"\t.size\t%@, .-%@\n", label, label];
    // PIC: flush the literal pool per function so each `ldr rX, =sym` finds its
    // pool within the ±4095 load range (a module-wide pool at section end is
    // out of reach of early instructions in a large function).
    if (sPIC)
        [out appendString:@"\t.ltorg\n"];
    [out appendString:@"\n"];
    }

/****************************************************************************\
|* Itable lookup: receiver (r0, or r1 when sret took r0) + a protocol id -> the
|* protocol's method table in r12.
|*
|*   recv[0]     -> vtable
|*   vtable[0]   -> itable  ((protoId, &table) pairs, a zero id terminates)
|*   scan for protoId, then the caller indexes table[methodIndex].
|*
|* Done in a runtime helper rather than inline, because after marshalling only r12
|* and lr are free and the scan needs THREE live values (cursor, entry id, target
|* id). The helper takes the id in r12 and the receiver in r0/r1, preserves r0-r3,
|* and returns the table in r12. `bl` clobbers lr, which is fine: a function
|* containing a dispatch is not a leaf, so its prologue already saved it.
|*
|* Cost: two loads and a compare per itable entry, and a class conforms to one or
|* two protocols in practice. A monomorphic call site could cache the resolved
|* table against the receiver's vtable pointer and skip the scan — worth doing if a
|* dispatch-heavy path ever measures hot, not worth the code size before then.
\****************************************************************************/
+ (void)emitItableLookup:(NSString*)recvReg
                 protoId:(uint32_t)pid
                     out:(NSMutableString*)out
    {
    [out appendFormat:@"\tmovw\tr12, #%u\n", (unsigned)(pid & 0xFFFFu)];
    [out appendFormat:@"\tmovt\tr12, #%u\n", (unsigned)((pid >> 16) & 0xFFFFu)];
    [out appendFormat:@"\tbl\t%@\n",
                      [recvReg isEqualToString:@"r1"] ? @"_xtc_itable_s" : @"_xtc_itable"];
    }

// The helper itself, emitted once per module that dispatches through a protocol.
+ (void)emitItableHelperInto:(NSMutableString*)out
    {
    [out appendString:
             @"\t.text\n"
             @"\t.p2align 2\n"
             @"\t.global\t_xtc_itable\n\t.hidden\t_xtc_itable\n"
             @"\t.type\t_xtc_itable, %function\n"
             @"_xtc_itable:\n" // r0 = recv, r12 = protoId -> r12 = table
             @"\tpush\t{r0, r1}\n"
             @"\tldr\tr0, [r0]\n"     // vtable
             @"\tldr\tr0, [r0, #4]\n" // itable (vtable entry 1; entry 0 = parent link)
             @"\tcmp\tr0, #0\n"
             @"\tbeq\t1f\n"
             @"0:\n"
             @"\tldr\tr1, [r0]\n" // entry's protoId
             @"\tcmp\tr1, #0\n"   // 0 terminates
             @"\tbeq\t1f\n"
             @"\tcmp\tr1, r12\n"
             @"\tbeq\t2f\n"
             @"\tadd\tr0, r0, #8\n"
             @"\tb\t0b\n"
             @"2:\n"
             @"\tldr\tr12, [r0, #4]\n" // &table
             @"\tpop\t{r0, r1}\n"
             @"\tbx\tlr\n"
             @"1:\n"
             @"\tmov\tr12, #0\n" // miss: null (an unimplemented optional)
             @"\tpop\t{r0, r1}\n"
             @"\tbx\tlr\n"
             // sret variant: the receiver is in r1 because r0 carries the result pointer.
             @"\t.global\t_xtc_itable_s\n\t.hidden\t_xtc_itable_s\n"
             @"\t.type\t_xtc_itable_s, %function\n"
             @"_xtc_itable_s:\n"
             @"\tpush\t{r0, r1}\n"
             @"\tldr\tr0, [r1]\n"
             @"\tldr\tr0, [r0, #4]\n" // itable (vtable entry 1; entry 0 = parent link)
             @"\tcmp\tr0, #0\n"
             @"\tbeq\t1f\n"
             @"0:\n"
             @"\tldr\tr1, [r0]\n"
             @"\tcmp\tr1, #0\n"
             @"\tbeq\t1f\n"
             @"\tcmp\tr1, r12\n"
             @"\tbeq\t2f\n"
             @"\tadd\tr0, r0, #8\n"
             @"\tb\t0b\n"
             @"2:\n"
             @"\tldr\tr12, [r0, #4]\n"
             @"\tpop\t{r0, r1}\n"
             @"\tbx\tlr\n"
             @"1:\n"
             @"\tmov\tr12, #0\n"
             @"\tpop\t{r0, r1}\n"
             @"\tbx\tlr\n\n"];
    }

// Thread-safe ARC (private:docs/Design/threading.md §4.1) — see the header for why
// ldrex/strex rather than a critical section.
static BOOL sArm9ThreadSafeARC = NO;
static NSInteger sArm9ThreadSafeARCOverride = -1;

+ (void)setThreadSafeARCOverride:(NSInteger)mode
    {
    sArm9ThreadSafeARCOverride = mode;
    }
+ (BOOL)threadSafeARC
    {
    return sArm9ThreadSafeARC;
    }

// ── Spill peephole (ported from arm64; arm9 had none) ────────────────────
//
// arm9 homes into r4-r11 but DUAL-WRITES: every result goes to its home
// register AND to its frame slot, so the slot stays valid for any reader that
// wants it. Measured on a reduction+dot kernel, that is 101 `str` to 10 `ldr` —
// nine out of ten spill stores are never read back, on an in-order core where a
// store is not free. (x86-64 abandoned dual-write in #525 and m68k in #538;
// arm9 is the last one still doing it. Removing the writes that provably have no
// reader is the same win without the migration's risk.)
//
// Two transforms, both per function:
//
//   (always) store->load forward — `str R,[sp,#N]` immediately followed by
//     `ldr R2,[sp,#N]` of the same class: keep the store, replace the load with
//     `mov R2, R`. Safe unconditionally — R still holds the value and the store
//     still writes memory.
//
//   (clean)  dead spill store — `str R,[sp,#N]` whose slot is never loaded
//     anywhere in the function: drop it.
//
// The dead-store form is only sound when the function never MATERIALISES a
// stack address, because then every access to spill memory is a literal
// `[sp,#N]` and a per-offset load count is exact. Disqualifiers on arm9:
//
//   * `add/sub Rd, sp, ...` with Rd != sp — a base pointer into the frame.
//     The prologue's own `sub sp, sp, #N` (Rd == sp) is not one.
//   * any `ldm`/`stm` that is not the prologue/epilogue `push`/`pop`.
//   * inline asm, which may name a slot directly. arm9 marks those blocks with
//     an `@ inline asm` comment, and homing already skips such functions.
//
// NOT ported from arm64: its scratch-register copy-prop. arm64 may treat a
// branch as "scratch dead-out"; that rule is UNSOUND on a backend that keeps a
// value in a scratch register across a branch (it cost the x86-64 port a corpus
// full of SIGSEGVs, #531). Establishing arm9's rule needs its own evidence, so
// this pass reasons only about frame slots, never about register liveness.
+ (BOOL)a9ParseSpLine:(NSString*)line
                 mnem:(NSString**)mnem
                  reg:(NSString**)reg
                  off:(NSString**)off
    {
    NSString* s = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    NSRange sp = [s rangeOfString:@", [sp"];
    if (sp.location == NSNotFound)
        return NO;
    NSString* head = [s substringToIndex:sp.location]; // "<mnem> <reg>"
    NSRange spc = [head rangeOfString:@" "];
    if (spc.location == NSNotFound)
        return NO;
    NSString* m = [head substringToIndex:spc.location];
    if (![m isEqualToString:@"str"] && ![m isEqualToString:@"ldr"])
        return NO;
    *mnem = m;
    *reg = [[head substringFromIndex:spc.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // Only a plain register operand — never a register LIST or a shifted form.
    if ([*reg rangeOfString:@"{"].location != NSNotFound)
        return NO;
    NSString* tail = [s substringFromIndex:sp.location]; // ", [sp, #N]"
    // Reject an indexed/writeback form: only "[sp, #N]" and "[sp]" are literal.
    if ([tail rangeOfString:@"!"].location != NSNotFound)
        return NO;
    if ([tail rangeOfString:@", r"].location != NSNotFound)
        return NO;
    NSRange hash = [tail rangeOfString:@"#"];
    if (hash.location == NSNotFound)
        {
        if ([tail hasSuffix:@"[sp]"])
            {
            *off = @"0";
            return YES;
            }
        return NO;
        }
    NSRange close = [tail rangeOfString:@"]"];
    if (close.location == NSNotFound || close.location <= hash.location)
        return NO;
    *off = [[tail substringWithRange:
                      NSMakeRange(hash.location + 1, close.location - hash.location - 1)]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return YES;
    }

+ (NSString*)a9PeepholeSpills:(NSString*)text
    {
    // Bisection aid: XTC_NO_A9_PEEP=1 emits the un-peepholed text, so a
    // suspected miscompile can be attributed in one build rather than a stash.
    const char* off = getenv("XTC_NO_A9_PEEP");
    if (off && *off && strcmp(off, "0") != 0)
        return text;
    NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
    NSString *m = nil, *r = nil, *o = nil;

    BOOL clean = YES;
    NSCountedSet<NSString*>* loads = [NSCountedSet set];
    for (NSString* ln in lines)
        {
        NSString* t = [[ln stringByReplacingOccurrencesOfString:@"\t" withString:@" "]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t rangeOfString:@"@ inline asm"].location != NSNotFound)
            return text;
        if (([t hasPrefix:@"add "] || [t hasPrefix:@"sub "]) && ![t hasPrefix:@"add sp,"] && ![t hasPrefix:@"sub sp,"] && [t rangeOfString:@", sp"].location != NSNotFound)
            clean = NO;
        // `mov Rd, sp` is the SAME materialisation as `add Rd, sp, #0` —
        // emitAlu shortcuts a zero offset to a mov, which is exactly what an
        // AddrOf of the frame's FIRST slot (a leaf's aggregate parameter)
        // produces. Missing it let the load count call the param's prologue
        // spill dead, so a by-value struct at slot 0 read stack garbage —
        // struct_byval's T1 `got=165 exp=1` on arm9, at every -O level.
        if ([t hasPrefix:@"mov "] && ([t hasSuffix:@", sp"] || [t rangeOfString:@", sp @"].location != NSNotFound))
            clean = NO;
        if (([t hasPrefix:@"ldm"] || [t hasPrefix:@"stm"]))
            clean = NO;
        // NOTE: a call no longer disqualifies the whole function. arm9 writes
        // stack ARGUMENTS to the outgoing area at [sp,#0..sOutArgBytes) and the
        // CALLEE reads them, so a load count in this function calls them dead —
        // deleting them handed callees frame garbage (0xA5A5A5A5 out of
        // int64_ops). That is a property of the OFFSET, not of the function, so
        // the boundary is honoured per store below rather than by refusing to
        // optimise anything that makes a call.
        // ANY frame access this parser cannot read exactly disqualifies the
        // dead-store form. ARM32 reaches a slot through more than plain
        // str/ldr — `ldrd`/`strd` move a PAIR (so they read [sp,#N] AND
        // [sp,#N+4]), `vldr`/`vstr` move float/double slots, and the byte and
        // halfword forms are their own mnemonics. Counting only `ldr` made an
        // i64 slot read by `ldrd` look never-loaded, so its store was deleted
        // and the reader got frame garbage — 0xA5A5A5A5 out of int64_ops and
        // heap_length_runtime. A load count is only exact if EVERY access is
        // one this pass understands; anything else and it must not claim to
        // know, rather than guess and be wrong.
        BOOL parsed = [self a9ParseSpLine:ln mnem:&m reg:&r off:&o];
        if (!parsed && [t rangeOfString:@"[sp"].location != NSNotFound)
            clean = NO;
        if (parsed && [m isEqualToString:@"ldr"])
            [loads addObject:o];
        }

    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:lines.count];
    NSUInteger i = 0;
    while (i < lines.count)
        {
        NSString* ln = lines[i];
        NSString *sm = nil, *sr = nil, *so = nil;
        if ([self a9ParseSpLine:ln mnem:&sm reg:&sr off:&so] && [sm isEqualToString:@"str"])
            {
            // Dead store — but never one in the outgoing-argument area, whose
            // reader is the callee and is invisible to a load count here.
            if (clean && [loads countForObject:so] == 0 && (NSUInteger)so.integerValue >= sOutArgBytes)
                {
                i++;
                continue;
                }
            NSString *lm = nil, *lr = nil, *lo = nil;
            if (i + 1 < lines.count && [self a9ParseSpLine:lines[i + 1] mnem:&lm reg:&lr off:&lo] && [lm isEqualToString:@"ldr"] && [lo isEqualToString:so] && [sr hasPrefix:@"r"] && [lr hasPrefix:@"r"])
                {
                BOOL dropStore = clean && [loads countForObject:so] == 1 && (NSUInteger)so.integerValue >= sOutArgBytes;
                if (!dropStore)
                    [out addObject:ln];
                if (![lr isEqualToString:sr])
                    [out addObject:[NSString stringWithFormat:@"\tmov\t%@, %@", lr, sr]];
                i += 2;
                continue;
                }
            }
        [out addObject:ln];
        i++;
        }
    return [out componentsJoinedByString:@"\n"];
    }

+ (NSString*)assemblyFromModule:(XTIRModule*)mod
    {
    sArm9ThreadSafeARC = sArm9ThreadSafeARCOverride >= 0
                             ? (sArm9ThreadSafeARCOverride != 0)
                             : [mod referencesSymbolNamed:@"_xt_thread_create"];
    NSMutableString* out = [NSMutableString string];
    BOOL needsItable = NO;
    for (XTIRFunction* f in mod.functions)
        for (XTIRBlock* b in f.blocks)
            for (XTIRInsn* i in b.instructions)
                if (i.opcode == XTIROpProtoDispatch || i.opcode == XTIROpProtoLoad)
                    needsItable = YES;
    // A `.file` directive naming the MODULE, not the temp .s we happen to be
    // writing to. Without one, gas has no file symbol to emit and falls back to
    // the name of the temporary object gcc handed it (`ccTxhJ1j.o`) — which is
    // random per build, lands in .symtab as an STT_FILE, and makes the .so
    // non-reproducible. Naming it after the module is both deterministic and
    // more useful than a temp path.
    [out appendFormat:@"\t.file\t\"%@.xc\"\n", mod.name ?: @"module"];
    [out appendString:@"\t.syntax unified\n\t.arch armv7-a\n\t.fpu neon\n\t.text\n\n"];
    if (needsItable)
        [self emitItableHelperInto:out];
    // Per-FUNCTION buffer: the spill peephole's dead-store form counts loads
    // per frame offset, and that count is only exact within one frame.
    for (XTIRFunction* fn in mod.functions)
        {
        NSMutableString* fbuf = [NSMutableString string];
        [self emitFunction:fn module:mod into:fbuf];
        [out appendString:[self a9PeepholeSpills:fbuf]];
        }
    [self emitModuleDataFromModule:mod into:out];
    return out;
    }

// Module-level data: globals, string literals, vtables. ELF/GNU-as syntax,
// bare symbol names, A32-native widths (4-byte pointers). AddrOf of any of
// these resolves to the bare symbol via movw/movt :lower16:/:upper16:.
+ (void)emitModuleDataFromModule:(XTIRModule*)mod into:(NSMutableString*)out
    {
    __block BOOL emittedData = NO;
    void (^dataHeader)(void) = ^{
      if (!emittedData)
          {
          [out appendString:@"\n\t.data\n"];
          emittedData = YES;
          }
    };
    // Globals — initialised → .data payload; zero-init → .comm.
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindDataGlobal || !sym.globalType)
            continue;
        // `extern` — this global is DEFINED IN ANOTHER MODULE. Reserve no storage;
        // the reference to its label is all we emit, and the linker resolves it.
        // Defining it here would give this module a SECOND COPY, whose writes would
        // never reach the defining module's — silently.
        if (sym.isExternalGlobal)
            continue;
        uint32_t size = (uint32_t)[self fieldWidth:sym.globalType];
        if (size == 0)
            size = 4;
        if (sym.initialBytes.length > 0)
            {
            NSData* bytes = sym.initialBytes;
            if (sym.globalType.kind == XTIRTypeKindAgg && sym.globalType.layout)
                {
                bytes = [XTAggInitRelay relay:bytes
                                       layout:sym.globalType.layout
                                  widthOfLeaf:^NSUInteger(XTIRType* t) {
                                    return [XTArm9Backend fieldWidth:t];
                                  }
                                    bigEndian:NO];
                }
            BOOL isFloat = XTIRTypeKindIsFloating(sym.globalType.kind);
            if (isFloat && bytes.length != size)
                {
                // Float globals carry the value as 8 IEEE-double bits; re-encode
                // to the native slot width (F32 → 4, F64 → 8).
                uint64_t raw = 0;
                [bytes getBytes:&raw length:MIN((NSUInteger)8, bytes.length)];
                if (sym.globalType.kind == XTIRTypeKindF64)
                    {
                    bytes = [NSMutableData dataWithBytes:&raw length:8];
                    }
                else
                    {
                    double dv = 0.0;
                    memcpy(&dv, &raw, sizeof(dv));
                    float fv = (float)dv;
                    uint32_t fb = 0;
                    memcpy(&fb, &fv, sizeof(fb));
                    bytes = [NSMutableData dataWithBytes:&fb length:4];
                    }
                }
            dataHeader();
            [out appendFormat:@"\t.global\t%@\n%@:\n", sym.name, sym.name];
            const uint8_t* p = bytes.bytes;
            for (NSUInteger i = 0; i < bytes.length; i++)
                [out appendFormat:@"\t.byte\t0x%02X\n", p[i]];
            for (NSUInteger i = bytes.length; i < size; i++)
                [out appendString:@"\t.byte\t0x00\n"];
            }
        else
            {
            // `.comm` so the symbol is global (escapes to a linking C stub).
            [out appendFormat:@"\t.comm\t%@, %u, 4\n", sym.name, (unsigned)size];
            }
        }
    // String literals — NUL-terminated bytes.
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindStringLit)
            continue;
        dataHeader();
        [out appendFormat:@"\t.global\t%@\n%@:\n", sym.name, sym.name];
        const uint8_t* p = sym.stringBytes.bytes;
        NSUInteger len = sym.stringBytes.length;
        if (len == 0)
            {
            [out appendString:@"\t.byte\t0x00\n"];
            continue;
            }
        for (NSUInteger i = 0; i < len; i++)
            [out appendFormat:@"\t.byte\t0x%02X\n", p[i]];
        }
    // VTables — one 4-byte function pointer per slot.
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindVTable)
            continue;
        // `extern` — an imported class's vtable lives in its library. Emit no
        // definition (a local copy at a different address would break RTTI identity,
        // which compares vtable addresses); the AddrOf reference resolves to the one
        // exported table via the loader.
        if (sym.isExternalGlobal)
            continue;
        dataHeader();
        [out appendFormat:@"\t.global\t%@\n\t.p2align 2\n%@:\n", sym.name, sym.name];
        NSArray<NSString*>* entries = sym.vtableEntryNames;
        if (entries.count == 0)
            {
            [out appendString:@"\t.word\t0\n"];
            continue;
            }
        for (NSString* e in entries)
            {
            if (!e.length)
                {
                [out appendString:@"\t.word\t0\n"];
                continue;
                }
            // An itable is (protoId, &table) pairs. The id is a VALUE — a hash of the
            // protocol's name — so it is emitted as a literal word, not a label.
            if ([e hasPrefix:@"__protoid_"])
                [out appendFormat:@"\t.word\t%@\n", [e substringFromIndex:[@"__protoid_" length]]];
            else
                [out appendFormat:@"\t.word\t%@\n", e];
            }
        }
    // Load-time constructors: a 4-byte pointer to each in `.init_array`, which
    // the XTOS loader runs deps-first before _app_entry (and ld.so at dlopen).
    // Drives XG-NIB object-factory self-registration with no per-app code. On
    // ARM the `@` char begins a comment, so the section type uses `%`.
    if (mod.moduleInitFunctionNames.count > 0)
        {
        [out appendString:@"\t.section .init_array,\"aw\",%init_array\n\t.p2align 2\n"];
        for (NSString* initName in mod.moduleInitFunctionNames)
            [out appendFormat:@"\t.word\t%@\n", initName];
        }
    }

@end
