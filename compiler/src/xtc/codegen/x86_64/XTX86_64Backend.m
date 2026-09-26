#import "XTX86_64Backend.h"
#import "XTRegexCompat.h"
#import "XTAggInitRelay.h"
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
#import "XTIRSupport.h"
#import "XTIRConstant.h"
#import "XTHomingAllocator.h"

// Register homing for the function being emitted (valueId → 64-bit reg name),
// nil when off. SINGLE-write: a homed value lives ONLY in its register — no slot
// store — so EVERY reader must consult sHome (the operand helpers do). Callee-
// saved pool (rbx/r12-r15), saved into frame slots. See XTHomingAllocator.
static NSDictionary<NSNumber*, NSString*>* sHome = nil;
static NSDictionary<NSString*, NSNumber*>* sHomeSaves = nil; // reg → [rbp-off] save slot
// Address folding: pointer-value-id → the ElementAddr/FieldAddr insn to fold into
// its single, immediately-following Load's memory operand (that addr op's own
// emission is skipped). The allocator extends base/index live ranges to the Load.
static NSDictionary<NSNumber*, XTIRInsn*>* sFold = nil;
// Compare-and-branch fusion: an ICmp result-value-id whose ONLY use is its
// block's CondBranch condition (and which is the last instruction before the
// terminator). Its emission drops the setcc/movzx/store and emits just `cmp`;
// the CondBranch then branches on the predicate directly (`cmp; jl`) instead of
// materialising a boolean and testing it. Excluded from homing (never stored).
static NSSet<NSNumber*>* sFusedCmp = nil;
// Compare-and-select fusion: an ICmp whose ONLY use is a Select condition in
// the same block. Without it the condition is materialised (`setcc al; movzx`)
// and then tested AGAIN (`test ecx, ecx`) before the cmov — four instructions
// to re-derive flags the cmp already set. Fused, the ICmp emits nothing at its
// own site and the compare is re-issued at the Select, so the cmov reads the
// flags directly. Only when the ICmp's right-hand side is an immediate: the
// re-issue then needs ONE scratch register, and rax/rdx already hold the two
// selected values.
static NSDictionary<NSNumber*, XTIRInsn*>* sSelSkip = nil; // cond id -> its ICmp
static NSDictionary<NSNumber*, XTIRInsn*>* sSelCmp = nil; // Select id -> its ICmp
// Auto-vectorised loops: a Vec-typed SSA value-id → its assigned SSE register
// (xmm2..xmm15, all caller-saved on System V; vectorised loop bodies contain no
// calls, so no prologue save is needed; xmm0/xmm1 stay emission scratch).
// Absent ⇒ the function has no vectors.
static NSDictionary<NSNumber*, NSString*>* sVec = nil;

// ─────────────────────────────────────────────────────────────────────────────
// x86-64 System V AMD64 backend. Intel syntax (`.intel_syntax noprefix`), so the
// musl cross-clang assembler + ld.lld turn the .s into a static x86-64 ELF.
//
// BRING-UP (milestone 1): a spill-everything value model — every non-memory value
// gets an 8-byte stack slot at [rbp-off]; each op loads its operands into scratch
// regs (rax/rcx), computes, stores the result back. Not optimal, but correct and
// easy to grow. Covers: function framing, System V param spill, integer const /
// width casts / arithmetic+bitwise, Return, and branches. Calls, SSE floats,
// loads/stores, structs and native varargs land in later milestones.
// ─────────────────────────────────────────────────────────────────────────────

static NSUInteger sArcLabel = 0; // unique ARC skip-label counter (per process)

// ABI selector. Default is System V AMD64 (Linux/macOS host). When set, the
// backend emits the Win64 ABI instead: integer args in rcx/rdx/r8/r9 (4, not 6),
// a positional register file shared by ints and floats (xmm0-3), a mandatory
// 32-byte "shadow space" the caller reserves below every call's stack args, and
// PE/COFF object format (no ELF `.type … @function`). Same x86-64 ISA otherwise.
// Set once by xtcg-win64 before codegen; SysV paths are left byte-for-byte intact.
static BOOL sWin64 = NO;

// When the current function returns a >8-byte aggregate, Win64 passes a HIDDEN
// pointer to the caller's destination in rcx (all real params shift right by one);
// this holds the frame offset where that pointer is saved at entry so Return can
// copy the result through it. 0 = this function has no hidden sret.
static NSInteger sWin64SretOff = 0;

@implementation XTX86_64Backend

+ (void)setWin64ABI:(BOOL)win64
    {
    sWin64 = win64;
    }
+ (BOOL)win64
    {
    return sWin64;
    }

// A >8-byte aggregate — the Win64 threshold for by-reference args and hidden-sret
// returns. ≤8-byte aggregates stay by value in a single register / rax.
+ (BOOL)isBigAgg:(XTIRType*)t
    {
    return sWin64 && t && t.kind == XTIRTypeKindAgg && [self aggSize:t.layout] > 8;
    }

// System V: an aggregate over 16 bytes is class MEMORY — returned through a
// hidden pointer in rdi (shifting the GP args right by one), which the callee
// also hands back in rax. ≤16 stays in rax:rdx. Before this predicate the
// backend packed EVERY aggregate into rax:rdx, so a 32-byte struct came back
// with its last 16 bytes never written (hfa_struct_return: r.x fine, r.h junk).
+ (BOOL)isSysVMemRet:(XTIRType*)t
    {
    return !sWin64 && t && t.kind == XTIRTypeKindAgg && [self aggSize:t.layout] > 16;
    }

// Emit an inline N-qword copy from [srcBase+srcDisp] to [dstBase+dstDisp] using
// rax as scratch (the memcpy the by-ref/sret paths need for small structs).
+ (void)copyQwords:(NSUInteger)bytes
           fromReg:(NSString*)srcBase
              disp:(long)srcDisp
             toReg:(NSString*)dstBase
              disp:(long)dstDisp
              into:(NSMutableString*)out
    {
    NSUInteger q = (bytes + 7) / 8;
    for (NSUInteger k = 0; k < q; k++)
        {
        [out appendFormat:@"\tmov\trax, [%@%+ld]\n", srcBase, srcDisp + 8 * (long)k];
        [out appendFormat:@"\tmov\t[%@%+ld], rax\n", dstBase, dstDisp + 8 * (long)k];
        }
    }

// A value is "memory" (a Mem token) if its type is the memory kind — it carries
// ordering, not data, so it gets no slot and no code.

// Intel-syntax reserved words. A user symbol with one of these names is resolved
// against the assembler's register/keyword table BEFORE the symbol table, so
// `[rip+flags]` parses as a register and the whole operand is rejected ("invalid
// base+index expression"). Found via the `sieve` fixture, whose sieve array is
// named `flags` — it failed to assemble at all on x86_64. Parenthesising is NOT a
// reliable escape (Apple clang 17 accepts `[rip+(flags)]`, the Homebrew clang 22
// in /opt/clang/linux does not), so mangle the NAME instead — at its definition
// and at every reference, so they always agree. Only collisions are renamed, so C
// ABI names (write/snprintf/…) are untouched.
+ (NSString*)safeSym:(NSString*)n
    {
    if (!n.length)
        return n;
    static NSSet<NSString*>* R;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableSet* s = [NSMutableSet setWithArray:@[ @"flags", @"eflags", @"rflags",
                                                      @"ip", @"eip", @"rip", @"cs", @"ds", @"es", @"fs", @"gs", @"ss", @"st",
                                                      @"byte", @"word", @"dword", @"qword", @"xmmword", @"ptr", @"offset",
                                                      @"short", @"near", @"far" ]];
      for (NSString* x in @[ @"a", @"b", @"c", @"d" ])
          {
          [s addObject:[x stringByAppendingString:@"l"]];
          [s addObject:[x stringByAppendingString:@"h"]];
          [s addObject:[x stringByAppendingString:@"x"]];
          [s addObject:[NSString stringWithFormat:@"e%@x", x]];
          [s addObject:[NSString stringWithFormat:@"r%@x", x]];
          }
      for (NSString* x in @[ @"si", @"di", @"sp", @"bp" ])
          {
          [s addObject:x];
          [s addObject:[@"e" stringByAppendingString:x]];
          [s addObject:[@"r" stringByAppendingString:x]];
          [s addObject:[x stringByAppendingString:@"l"]];
          }
      for (int i = 0; i < 16; i++)
          {
          [s addObject:[NSString stringWithFormat:@"r%d", i]];
          [s addObject:[NSString stringWithFormat:@"r%dd", i]];
          [s addObject:[NSString stringWithFormat:@"r%dw", i]];
          [s addObject:[NSString stringWithFormat:@"r%db", i]];
          [s addObject:[NSString stringWithFormat:@"xmm%d", i]];
          }
      R = s;
    });
    return [R containsObject:[n lowercaseString]] ? [n stringByAppendingString:@"$x"] : n;
    }

+ (BOOL)isMem:(XTIRValue*)v
    {
    return v.type && v.type.kind == XTIRTypeKindMemory;
    }

// Byte width of a value for slot load/store. Scalars use their type width; a
// pointer is the IR heap-pointer width (handled natively in a later milestone) —
// clamp everything to [1,8].
+ (NSUInteger)widthOf:(XTIRValue*)v
    {
    NSUInteger w = v.type ? v.type.byteWidth : 8;
    if (w == 0)
        w = 8;
    if (w > 8)
        w = 8;
    return w;
    }

// The width a branch or select condition is tested at: 8 for a pointer or a
// 64-bit integer, else 4. A condition is true when ANY of its bits is set, so
// `test eax, eax` read an i64 of 1 << 32, or a pointer whose low 32 bits are
// zero, as false (bug 293).
+ (NSUInteger)condWidth:(XTIROperand*)op fn:(XTIRFunction*)fn
    {
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = fn.values[@(op.valueId)];
        return (v && [self widthOf:v] >= 8) ? 8 : 4;
        }
    if (op.kind == XTIROperandKindImmI && op.type)
        return (op.type.kind == XTIRTypeKindPtr || op.type.byteWidth >= 8) ? 8 : 4;
    return 4;
    }

// Sub-register name for one of the scratch bases a/c/d at a given byte width.
+ (NSString*)reg:(char)base width:(NSUInteger)w
    {
    switch (base)
        {
    case 'a':
        return w == 1 ? @"al" : w == 2 ? @"ax"
                            : w == 4   ? @"eax"
                                       : @"rax";
    case 'c':
        return w == 1 ? @"cl" : w == 2 ? @"cx"
                            : w == 4   ? @"ecx"
                                       : @"rcx";
    case 'd':
        return w == 1 ? @"dl" : w == 2 ? @"dx"
                            : w == 4   ? @"edx"
                                       : @"rdx";
        }
    return @"rax";
    }

// Width-view of a named 64-bit home register. rbx has legacy 8/16/32 names;
// r12-r15 use the b/w/d suffix.
+ (NSString*)regView:(NSString*)r64 width:(NSUInteger)w
    {
    // The r8-r15 names take a width SUFFIX (r8d/r8w/r8b); the eight legacy
    // registers each spell their views differently, and rsi/rdi/rbp/rsp have no
    // 8-bit view at all before REX (sil/dil/bpl/spl). A table beats three
    // special cases: `rdid` was accepted by nothing and the in-house assembler
    // refused it loudly the moment rdi entered a register pool.
    static NSDictionary<NSString*, NSArray<NSString*>*>* views = nil;
    if (!views)
        views = @{ @"rax" : @[ @"al",  @"ax",  @"eax",  @"rax" ],
                   @"rbx" : @[ @"bl",  @"bx",  @"ebx",  @"rbx" ],
                   @"rcx" : @[ @"cl",  @"cx",  @"ecx",  @"rcx" ],
                   @"rdx" : @[ @"dl",  @"dx",  @"edx",  @"rdx" ],
                   @"rsi" : @[ @"sil", @"si",  @"esi",  @"rsi" ],
                   @"rdi" : @[ @"dil", @"di",  @"edi",  @"rdi" ],
                   @"rbp" : @[ @"bpl", @"bp",  @"ebp",  @"rbp" ],
                   @"rsp" : @[ @"spl", @"sp",  @"esp",  @"rsp" ] };
    NSArray<NSString*>* v = views[r64];
    if (v)
        return v[w == 1 ? 0 : w == 2 ? 1 : w == 4 ? 2 : 3];
    return [r64 stringByAppendingString:(w == 1 ? @"b" : w == 2 ? @"w"
                                                     : w == 4   ? @"d"
                                                                : @"")];
    }

+ (NSString*)sizeKw:(NSUInteger)w
    {
    return w == 1 ? @"byte ptr" : w == 2 ? @"word ptr"
                              : w == 4   ? @"dword ptr"
                                         : @"qword ptr";
    }

// Native width of an aggregate FIELD. The shared XTIRLayout sizes fields with the
// front-end's AST/Atari widths (pointer = 2 bytes), but x86-64 uses 64-bit host
// pointers — storing one into a 2-byte ivar slot truncates it and clobbers the next
// field. So the backend owns its own field widths: pointer = 8, F64 = 8, F32 = 4,
// integers natural, Agg recursive. (Mirrors XTArm64Backend arm64FieldWidth.)
+ (NSUInteger)fieldWidth:(XTIRType*)t
    {
    if (!t)
        return 0;
    switch (t.kind)
        {
    case XTIRTypeKindPtr:
        return 8; // host pointer
    case XTIRTypeKindF64:
        return 8;
    case XTIRTypeKindF32:
        return 4;
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

// Native total size of an aggregate (sum of its fields' native widths); never below
// the declared layout.size (a field-less byte buffer carries its count there).
+ (NSUInteger)aggSize:(XTIRLayout*)layout
    {
    if (!layout)
        return 0;
    NSUInteger total = 0;
    for (XTIRLayoutField* f in layout.fields)
        total += [self fieldWidth:f.type];
    if (total < layout.size)
        total = layout.size;
    return total;
    }

// Native byte offset of field `idx` — the RECORDED layout offset. The front
// end lays fields out once (per-target field-alignment cap, blewit #5) and
// every backend reads the same offsets; widths still must match the FE's
// (type-width invariant) or loads/stores are mis-sized.
+ (NSUInteger)fieldOffset:(XTIRLayout*)layout index:(NSUInteger)idx
    {
    if (idx >= layout.fields.count)
        return [self aggSize:layout];
    return layout.fields[idx].byteOffset;
    }

// Frame bytes for a value's slot: the full native type size (aggregates get their
// whole footprint via the recomputed aggSize so AddrOf of a pinned local addresses
// real storage), rounded to 8.
+ (NSUInteger)slotSizeOf:(XTIRValue*)v
    {
    NSUInteger w = (v.type && v.type.kind == XTIRTypeKindAgg) ? [self aggSize:v.type.layout]
                                                              : (v.type ? v.type.byteWidth : 8);
    if (w < 8)
        w = 8;
    return (w + 7) & ~(NSUInteger)7;
    }

// Load an operand ZERO-EXTENDED into base reg's 64-bit view — for addresses and
// array indices, where the full 64-bit register must be a clean value.
// Is this IR scalar kind signed? An index of a signed type must be SIGN-extended
// to 64 bits before it scales into an address — zero-extending it turns a
// negative index into a huge positive one.
+ (BOOL)isSignedKind:(XTIRTypeKind)k
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindI16 || k == XTIRTypeKindI32;
    }

// Load an element index into `base`, extended to 64 bits by its own signedness.
// `u16@ p = &a[3]; @(p - (i16)2) = v;` lowers to an element address with a
// signed 16-bit index of -2; zero-extending it made that 65534 and the store
// landed 128KB past the array. arm64 got this right, so it only ever showed up
// on x86-64.
+ (void)loadIndex:(XTIROperand*)op into:(char)base fn:(XTIRFunction*)fn
             slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
              out:(NSMutableString*)out
    {
    if (op.kind != XTIROperandKindUse)
        {
        [self loadZX:op into:base fn:fn slot:slot out:out];
        return;
        }
    XTIRValue* v = fn.values[@(op.valueId)];
    NSUInteger w = v ? [self fieldWidth:v.type] : 0;
    if (!v || w == 0 || w >= 8 || ![self isSignedKind:v.type.kind])
        {
        [self loadZX:op into:base fn:fn slot:slot out:out];
        return;
        }
    NSString* r64 = [self reg:base width:8];
    NSString* home = sHome[@(op.valueId)];
    // 32->64 is spelled movsxd, not movsx — a distinct opcode (0x63). Getting
    // this wrong is not a syntax nit: `movsx r64, r32` assembles as sign-extend
    // from a BYTE on anything that accepts it, and clang rejects it outright.
    if (home)
        {
        [out appendFormat:@"\t%@\t%@, %@\n", w == 4 ? @"movsxd" : @"movsx",
                          r64, [self regView:home width:w]];
        return;
        }
    NSNumber* sl = slot[@(op.valueId)];
    if (!sl)
        {
        [out appendFormat:@"\txor\t%@, %@\n", r64, r64];
        return;
        }
    // movsxd is the 32->64 spelling; movsx covers 8/16->64.
    if (w == 4)
        [out appendFormat:@"\tmovsxd\t%@, dword ptr [rbp-%@]\n", r64, sl];
    else
        [out appendFormat:@"\tmovsx\t%@, %@ [rbp-%@]\n", r64, [self sizeKw:w], sl];
    }

+ (void)loadZX:(XTIROperand*)op into:(char)base fn:(XTIRFunction*)fn
          slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
           out:(NSMutableString*)out
    {
    NSString *r32 = [self reg:base width:4], *r64 = [self reg:base width:8];
    if (op.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmov\t%@, %lld\n", r64, (long long)op.intValue];
        return;
        }
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = fn.values[@(op.valueId)];
        NSNumber* s = slot[@(op.valueId)];
        NSUInteger w = v ? [self widthOf:v] : 4;
        NSString* home = sHome[@(op.valueId)];
        // homed → zero-extend from the register
        if (home)
            {
            if (w >= 8)
                [self movFromHome:home width:8 into:r64 out:out];
            else if (w == 4)
                [self movFromHome:home width:4 into:r32 out:out];
            else
                [out appendFormat:@"\tmovzx\t%@, %@\n", r32, [self regView:home width:w]];
            return;
            }
        if (!s)
            {
            [out appendFormat:@"\txor\t%@, %@\n", r64, r64];
            return;
            }
        if (w >= 8)
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", r64, s];
        else if (w == 4)
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", r32, s]; // zero-extends
        else
            [out appendFormat:@"\tmovzx\t%@, %@ [rbp-%@]\n", r32, [self sizeKw:w], s];
        return;
        }
    [out appendFormat:@"\txor\t%@, %@\n", r64, r64];
    }

+ (NSString*)blockLabel:(XTIRBlock*)b fn:(XTIRFunction*)fn
    {
    return [NSString stringWithFormat:@".L_%@_%@", fn.name, b.name ?: @"b"];
    }

// Load an operand EXTENDED (sign or zero) to compare width w — so cmp at width w
// never sees stale high bits from a narrow load.
+ (void)loadExt:(XTIROperand*)op into:(char)base signed:(BOOL)sg width:(NSUInteger)w
             fn:(XTIRFunction*)fn
           slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
            out:(NSMutableString*)out
    {
    NSString* rw = [self reg:base width:w];
    if (op.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmov\t%@, %lld\n", rw, (long long)op.intValue];
        return;
        }
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = fn.values[@(op.valueId)];
        NSNumber* s = slot[@(op.valueId)];
        NSUInteger nat = v ? [self widthOf:v] : w;
        NSString* home = sHome[@(op.valueId)];
        // 32→64 has its own spellings and neither is `movsx`/`movzx`: signed is
        // `movsxd` (a distinct opcode), and unsigned is a plain 32-bit `mov`,
        // because writing a 32-bit register zero-extends into the full 64.
        // `movsx rax, ebx` is not a syntax nit — the assembler rejects it, and
        // it only became reachable once a 32-bit value could widen to i64.
        BOOL w32to64 = (nat == 4 && w == 8);
        // homed → extend from the register
        if (home)
            {
            if (nat >= w)
                [self movFromHome:home width:w into:rw out:out];
            else if (w32to64)
                [out appendFormat:@"\t%@\t%@, %@\n", sg ? @"movsxd" : @"mov",
                                  sg ? rw : [self reg:base width:4], [self regView:home width:4]];
            else
                [out appendFormat:@"\t%@\t%@, %@\n", sg ? @"movsx" : @"movzx", rw, [self regView:home width:nat]];
            return;
            }
        if (!s)
            {
            [out appendFormat:@"\txor\t%@, %@\n", rw, rw];
            return;
            }
        if (nat >= w)
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", rw, s];
        else if (w32to64)
            [out appendFormat:@"\t%@\t%@, dword ptr [rbp-%@]\n", sg ? @"movsxd" : @"mov",
                              sg ? rw : [self reg:base width:4], s];
        else
            [out appendFormat:@"\t%@\t%@, %@ [rbp-%@]\n", sg ? @"movsx" : @"movzx", rw, [self sizeKw:nat], s];
        return;
        }
    [out appendFormat:@"\txor\t%@, %@\n", rw, rw];
    }

// Block-copy `size` bytes between a pointer in `ptrReg` and a frame slot (byte 0 at
// [rbp-slotOff]). toSlot: [ptrReg] → slot; else slot → [ptrReg]. Uses rcx as scratch.
+ (void)copyAgg:(NSUInteger)size ptr:(NSString*)ptrReg slot:(NSInteger)slotOff
         toSlot:(BOOL)toSlot
            out:(NSMutableString*)out
    {
    NSUInteger o = 0;
    while (o < size)
        {
        NSUInteger c = (size - o >= 8) ? 8 : (size - o >= 4) ? 4
                                         : (size - o >= 2)   ? 2
                                                             : 1;
        NSString* r = [self reg:'c' width:c];
        NSString* mem = [NSString stringWithFormat:@"[%@+%lu]", ptrReg, (unsigned long)o];
        NSString* frm = [NSString stringWithFormat:@"[rbp-%ld]", (long)(slotOff - (NSInteger)o)];
        NSString *src = toSlot ? mem : frm, *dst = toSlot ? frm : mem;
        [out appendFormat:@"\tmov\t%@, %@\n\tmov\t%@, %@\n", r, src, dst, r]; // load src→r, store r→dst
        o += c;
        }
    }

// System V returns a ≤16-byte struct in rax:rdx. Pack the aggregate's slot into
// those registers (return side) / unpack them into the result slot (call side).
// A >16-byte aggregate never reaches here: it is MEMORY class and travels
// through the hidden sret pointer (isSysVMemRet). arm64 still has the old gap
// for a >16-byte NON-HFA return (no fixture exercises it).
+ (void)aggToRetRegs:(XTIRValue*)v slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                 out:(NSMutableString*)out
    {
    NSNumber* s = slot[@(v.valueId)];
    if (!s)
        return;
    NSInteger off = s.integerValue;
    [out appendFormat:@"\tmov\trax, [rbp-%ld]\n", (long)off];
    // Win64 returns >8-byte aggregates via the hidden sret pointer, so anything
    // reaching here is ≤8 and lives entirely in rax. System V uses rax:rdx ≤16.
    if (!sWin64 && [self aggSize:v.type.layout] > 8)
        [out appendFormat:@"\tmov\trdx, [rbp-%ld]\n", (long)(off - 8)];
    }
+ (void)aggFromRetRegs:(XTIRValue*)res slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                   out:(NSMutableString*)out
    {
    NSNumber* s = slot[@(res.valueId)];
    if (!s)
        return;
    NSInteger off = s.integerValue;
    [out appendFormat:@"\tmov\t[rbp-%ld], rax\n", (long)off];
    if (!sWin64 && [self aggSize:res.type.layout] > 8)
        [out appendFormat:@"\tmov\t[rbp-%ld], rdx\n", (long)(off - 8)];
    }

+ (BOOL)isFloatKind:(XTIRTypeKind)k
    {
    return k == XTIRTypeKindF32 || k == XTIRTypeKindF64;
    }
+ (BOOL)isFloatVal:(XTIRValue*)v
    {
    return v.type && [self isFloatKind:v.type.kind];
    }

// movss/movsd a float value (from its slot) into an xmm register.
+ (void)loadF:(XTIROperand*)op into:(NSString*)xmm fn:(XTIRFunction*)fn
         slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
          out:(NSMutableString*)out
    {
    if (op.kind != XTIROperandKindUse)
        {
        [out appendFormat:@"\txorps\t%@, %@\n", xmm, xmm];
        return;
        }
    XTIRValue* v = fn.values[@(op.valueId)];
    NSNumber* s = slot[@(op.valueId)];
    BOOL d = v && v.type.kind == XTIRTypeKindF64;
    // A HOMED float never has its slot written, so reading the slot here would
    // read whatever was in it before the value was homed.
    NSString* fhome = sHome[@(op.valueId)];
    if (fhome && [self isXmmHome:fhome])
        {
        if (![fhome isEqualToString:xmm])
            [out appendFormat:@"\tmovaps\t%@, %@\n", xmm, fhome];
        return;
        }
    if (s)
        [out appendFormat:@"\tmov%@\t%@, [rbp-%@]\n", d ? @"sd" : @"ss", xmm, s];
    else
        [out appendFormat:@"\txorps\t%@, %@\n", xmm, xmm];
    }

+ (void)storeF:(NSString*)xmm into:(XTIRValue*)res
          slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
           out:(NSMutableString*)out
    {
    if (!res)
        return;
    NSString* fhome = sHome[@(res.valueId)];
    if (fhome && [self isXmmHome:fhome])
        {
        if (![fhome isEqualToString:xmm])
            [out appendFormat:@"\tmovaps\t%@, %@\n", fhome, xmm];
        return;
        }
    NSNumber* s = slot[@(res.valueId)];
    if (!s)
        return;
    [out appendFormat:@"\tmov%@\t[rbp-%@], %@\n", res.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", s, xmm];
    }

// ── float destination / source selection ────────────────────────────────────
//
// Every float op used to stage through the xmm0/xmm1 scratch pair even when
// both operands were already homed, so float_math's inner loop ran
//
//     movaps xmm0, xmm9 ; movaps xmm1, xmm10 ; mulss xmm0, xmm1
//     movaps xmm9, xmm0 ; movaps xmm0, xmm9  ; cvtss2sd xmm0, xmm0 ...
//
// — 35 register-to-register movaps around 8 arithmetic instructions, where
// arm64 emits the same source with none. Emitting straight into the result's
// home register collapses that; `loadF` into a register the value already
// occupies emits nothing, and `storeF` back out of it likewise.
//
// The one hazard is a two-operand form whose destination is ALSO where the
// second operand lives: writing the first operand there destroys the second
// before it is read. That case falls back to the scratch register.
+ (NSString*)fdstFor:(XTIRValue*)res clobbering:(XTIROperand*)other
                  as:(XTIROperand*)first
    {
    NSString* h = res ? sHome[@(res.valueId)] : nil;
    if (!h || ![self isXmmHome:h])
        return @"xmm0";
    if (other && other.kind == XTIROperandKindUse)
        {
        // Same VALUE in both operands (x*x) is safe: the read happens from the
        // destination, which still holds it.
        BOOL sameValue = first && first.kind == XTIROperandKindUse &&
                         first.valueId == other.valueId;
        NSString* oh = sHome[@(other.valueId)];
        if (!sameValue && oh && [self isXmmHome:oh] && [oh isEqualToString:h])
            return @"xmm0";
        }
    return h;
    }

// A float value's own home register when it has one, else the xmm0 scratch.
// Used by Store, where xmm0 is free (unlike a binary op, whose first operand
// may already be sitting there).
+ (NSString*)fsrcForStore:(XTIROperand*)op fn:(XTIRFunction*)fn
                     slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                      out:(NSMutableString*)out
    {
    if (op && op.kind == XTIROperandKindUse)
        {
        NSString* h = sHome[@(op.valueId)];
        if (h && [self isXmmHome:h])
            return h;
        }
    [self loadF:op into:@"xmm0" fn:fn slot:slot out:out];
    return @"xmm0";
    }

// The second operand's own home register when it has one — no copy needed —
// otherwise load it into the xmm1 scratch and use that.
+ (NSString*)fsrcFor:(XTIROperand*)op fn:(XTIRFunction*)fn
                slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                 out:(NSMutableString*)out
    {
    if (op && op.kind == XTIROperandKindUse)
        {
        NSString* h = sHome[@(op.valueId)];
        if (h && [self isXmmHome:h])
            return h;
        }
    [self loadF:op into:@"xmm1" fn:fn slot:slot out:out];
    return @"xmm1";
    }

// ── operand → scratch base register ─────────────────────────────────────────
// Loads an operand (an SSA value in its slot, or an immediate) into base reg
// `base` (a/c/d) at the operand's width. Returns nothing; the caller knows base.
+ (void)load:(XTIROperand*)op into:(char)base fn:(XTIRFunction*)fn
        slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
         out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmov\t%@, %lld\n", [self reg:base width:8], (long long)op.intValue];
        return;
        }
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = fn.values[@(op.valueId)];
        NSNumber* s = slot[@(op.valueId)];
        NSUInteger w = v ? [self widthOf:v] : 8;
        NSString* home = sHome[@(op.valueId)];
        // homed → read the register
        if (home)
            {
            [self movFromHome:home width:w into:[self reg:base width:w] out:out];
            }
        else if (s)
            {
            // Zero/garbage-free load: a sub-8 mov leaves high bits as-is, so use
            // the natural-width reg view; callers that need a wider result extend.
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", [self reg:base width:w], s];
            }
        else
            {
            [out appendFormat:@"\txor\t%@, %@\n", [self reg:base width:8], [self reg:base width:8]];
            }
        return;
        }
    // Sym / other — not handled at milestone 1; zero it so the asm stays valid.
    [out appendFormat:@"\txor\t%@, %@\n", [self reg:base width:8], [self reg:base width:8]];
    }

// store scratch base `base` into value `res` — its home register (single-write)
// or, un-homed, its slot at res's width.
+ (void)store:(char)base into:(XTIRValue*)res
         slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
          out:(NSMutableString*)out
    {
    if (!res)
        return;
    NSUInteger w = [self widthOf:res];
    // Dual-write: mirror into the home register AND keep the slot valid — several
    // opcode handlers (call-arg marshalling, casts) read operand slots directly,
    // so single-write is unsafe without auditing every one.
    NSString* home = sHome[@(res.valueId)];
    if (home)
        {
        [self movIntoHome:home width:w from:[self reg:base width:w] out:out];
        return;
        }
    NSNumber* s = slot[@(res.valueId)];
    if (!s)
        return;
    [out appendFormat:@"\tmov\t[rbp-%@], %@\n", s, [self reg:base width:w]];
    }

// Memory-operand string for a folded ElementAddr/FieldAddr `ea`: `[base + idx*s]`
// or `[base + off]`. A homed pointer base is used directly (64-bit valid); an
// unhomed base is zero-extended into rax. The INDEX is ALWAYS zero-extended into
// rcx (a memory operand uses the full 64-bit index, so dirty high bits from a
// homed 32-bit index would corrupt the address). Base loads first, then index.
+ (NSString*)foldedMemOp:(XTIRInsn*)ea fn:(XTIRFunction*)fn
                    slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                     out:(NSMutableString*)out
    {
    XTIROperand* bop = ea.operands[0];
    NSString* bhome = (bop.kind == XTIROperandKindUse) ? sHome[@(bop.valueId)] : nil;
    NSString* baseReg;
    if (bhome)
        baseReg = [self regView:bhome width:8];
    else
        {
        [self loadZX:bop into:'a' fn:fn slot:slot out:out];
        baseReg = @"rax";
        }

    XTIRValue* base = (bop.kind == XTIROperandKindUse) ? fn.values[@(bop.valueId)] : nil;
    XTIRType* pte = base ? base.type.pointeeType : nil;
    if (ea.opcode == XTIROpFieldAddr)
        {
        NSUInteger off = 0;
        if (pte && pte.kind == XTIRTypeKindAgg && pte.layout && ea.operands[1].kind == XTIROperandKindImmI)
            {
            NSUInteger idx = (NSUInteger)ea.operands[1].intValue;
            if (idx < pte.layout.fields.count)
                off = [self fieldOffset:pte.layout index:idx];
            }
        return off ? [NSString stringWithFormat:@"[%@ + %lu]", baseReg, (unsigned long)off]
                   : [NSString stringWithFormat:@"[%@]", baseReg];
        }
    NSUInteger stride = pte ? [self fieldWidth:pte] : 1;
    if (stride == 0)
        stride = 1;

    // A HOMED UNSIGNED 32-bit index can be the index register directly, with no
    // staging mov: on x86-64 every write to a 32-bit register zero-extends into
    // its 64-bit half, so a home last written as `mov r12d, …` / `add r12d, 1`
    // already has clean upper bits — exactly the property the rcx zero-extend
    // was there to establish. That mov sat in the hot loop of every indexed
    // access (`mov ecx, r12d` then `[rbx + rcx*4]`, where `[rbx + r12*4]`
    // encodes identically).
    //
    // ONLY unsigned, and only width 4. A signed narrow index must still go
    // through loadIndex's movsxd: a negative i32 homed by a 32-bit write reads
    // as a huge POSITIVE 64-bit index, which addresses far outside the object
    // rather than before it.
    NSString* idxReg = nil;
    XTIROperand* iop = ea.operands[1];
    if (iop.kind == XTIROperandKindUse)
        {
        XTIRValue* iv = fn.values[@(iop.valueId)];
        NSString* ihome = sHome[@(iop.valueId)];
        NSUInteger iw = iv ? [self fieldWidth:iv.type] : 0;
        if (ihome && iv && iw == 4 && ![self isSignedKind:iv.type.kind])
            idxReg = [self regView:ihome width:8];
        }
    if (!idxReg)
        {
        [self loadIndex:iop into:'c' fn:fn slot:slot out:out]; // rcx = index, sign-aware
        idxReg = @"rcx";
        }
    return [NSString stringWithFormat:@"[%@ + %@*%lu]", baseReg, idxReg, (unsigned long)stride];
    }

// mov an operand into a named width-w destination register (imm / home reg / slot).
+ (void)movOperand:(XTIROperand*)op intoReg:(NSString*)dst width:(NSUInteger)w
                fn:(XTIRFunction*)fn
              slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
               out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmov\t%@, %lld\n", dst, (long long)op.intValue];
        return;
        }
    if (op.kind == XTIROperandKindUse)
        {
        NSString* home = sHome[@(op.valueId)];
        if (home)
            {
            [self movFromHome:home width:w into:dst out:out];
            return;
            }
        NSNumber* s = slot[@(op.valueId)];
        if (s)
            {
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", dst, s];
            return;
            }
        }
    [out appendFormat:@"\tmov\t%@, 0\n", dst];
    }

// x86 source-operand string for `op` at width w, usable as the 2nd operand of a
// two-address op writing `resR`: an immediate, the operand's home reg view, or
// its slot memory. If the operand currently lives in resR (would be clobbered
// when resR is produced), it is copied to rcx first and rcx returned.
+ (NSString*)srcOperand:(XTIROperand*)op width:(NSUInteger)w resReg:(NSString*)resR
                     fn:(XTIRFunction*)fn
                   slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                    out:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        long long v = (long long)op.intValue;
        // x86-64 ALU instructions take an imm32 (sign-extended to 64), never an
        // imm64 — only `mov` has a full-width immediate form. A 64-bit constant
        // therefore has to go through a register: `and r15, 1095233372415` is
        // not an instruction, and the assembler said so as "invalid operand".
        if (w == 8 && (v > INT32_MAX || v < INT32_MIN))
            {
            NSString* tmp = [self reg:'c' width:8];
            [out appendFormat:@"\tmov\t%@, %lld\n", tmp, v];
            return tmp;
            }
        return [NSString stringWithFormat:@"%lld", v];
        }
    if (op.kind == XTIROperandKindUse)
        {
        NSString* home = sHome[@(op.valueId)];
        if (home)
            {
            NSString* hv = [self regView:home width:w];
            // aliases result reg → save to rcx
            if ([hv isEqualToString:resR])
                {
                [out appendFormat:@"\tmov\t%@, %@\n", [self reg:'c' width:w], hv];
                return [self reg:'c' width:w];
                }
            return hv;
            }
        NSNumber* s = slot[@(op.valueId)];
        if (s)
            return [NSString stringWithFormat:@"[rbp-%@]", s];
        }
    [out appendFormat:@"\tmov\t%@, 0\n", [self reg:'c' width:w]];
    return [self reg:'c' width:w];
    }

// Read a call argument operand into a named arg register (r64/r32 views), width-
// aware and home-aware — a homed operand reads its register, not its slot.
+ (void)readArgOp:(XTIROperand*)a into64:(NSString*)r64 into32:(NSString*)r32
               fn:(XTIRFunction*)fn
             slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
              out:(NSMutableString*)out
    {
    if (a.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmov\t%@, %lld\n", r64, (long long)a.intValue];
        return;
        }
    if (a.kind != XTIROperandKindUse)
        {
        [out appendFormat:@"\txor\t%@, %@\n", r64, r64];
        return;
        }
    XTIRValue* v = fn.values[@(a.valueId)];
    NSUInteger w = v ? [self widthOf:v] : 8;
    NSString* home = sHome[@(a.valueId)];
    if (home)
        {
        if (w >= 8)
            [self movFromHome:home width:8 into:r64 out:out];
        else if (w == 4)
            [self movFromHome:home width:4 into:r32 out:out];
        else
            [out appendFormat:@"\tmovzx\t%@, %@\n", r32, [self regView:home width:w]];
        return;
        }
    NSNumber* s = slot[@(a.valueId)];
    if (!s)
        [out appendFormat:@"\txor\t%@, %@\n", r64, r64];
    else if (w >= 8)
        [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", r64, s];
    else if (w == 4)
        [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", r32, s];
    else
        [out appendFormat:@"\tmovzx\t%@, %@ [rbp-%@]\n", r32, [self sizeKw:w], s];
    }


// ── Fallthrough peephole ─────────────────────────────────────────────────
//
// Drop `jmp L` when L is the very next label, and invert a conditional whose
// TAKEN target is next so the fall-through is the other side. This back end
// had no such pass: every block ended in a taken branch even when its target
// immediately followed it, so mem_copy's vectorised body read
//
//     movdqu xmm14, [r15] ; movdqa xmm13, xmm14 ; paddd xmm13, xmm15
//     movdqu [r14], xmm13 ; jmp .L_main_bb_7_for_body_vu1
//
// — one wasted instruction and one taken branch in five, in every unrolled
// copy of every loop in the program. arm64 has had this since it was written.
+ (NSString*)peepholeFallthrough:(NSString*)text
{
    static NSDictionary* inv;
    if (!inv) inv = @{@"e":@"ne",@"ne":@"e",@"z":@"nz",@"nz":@"z",
                      @"b":@"ae",@"ae":@"b",@"be":@"a",@"a":@"be",
                      @"l":@"ge",@"ge":@"l",@"le":@"g",@"g":@"le",
                      @"s":@"ns",@"ns":@"s",@"c":@"nc",@"nc":@"c",
                      @"o":@"no",@"no":@"o",@"p":@"np",@"np":@"p"};
    NSMutableArray<NSString*>* lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSString* (^labelOf)(NSString*) = ^NSString*(NSString* ln) {
      NSString* t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      return ([t hasSuffix:@":"] && t.length > 1 && ![t hasPrefix:@"."] ) || ([t hasSuffix:@":"] && [t hasPrefix:@".L"])
                 ? [t substringToIndex:t.length - 1] : nil;
    };
    // The next line that is neither blank nor a pure directive (.p2align sits
    // between a jump and the label it falls into once loop heads are aligned).
    NSInteger (^nextReal)(NSUInteger) = ^NSInteger(NSUInteger i) {
      for (NSUInteger j = i + 1; j < lines.count; j++)
          {
          NSString* t = [lines[j] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
          if (!t.length || [t hasPrefix:@".p2align"] || [t hasPrefix:@"#"])
              continue;
          return (NSInteger)j;
          }
      return -1;
    };
    BOOL again = YES;
    while (again)
        {
        again = NO;
        for (NSUInteger i = 0; i < lines.count; i++)
            {
            NSString* t = [lines[i] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if ([t hasPrefix:@"jmp\t"] || [t hasPrefix:@"jmp "])
                {
                NSString* tgt = [[t substringFromIndex:3]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSInteger j = nextReal(i);
                if (j >= 0 && [labelOf(lines[j]) isEqualToString:tgt])
                    { [lines removeObjectAtIndex:i]; again = YES; break; }
                continue;
                }
            if (![t hasPrefix:@"j"])
                continue;                       // not a branch
            NSRange sp = [t rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
            if (sp.location == NSNotFound)
                continue;
            NSString* cc = [t substringWithRange:NSMakeRange(1, sp.location - 1)];
            NSString* ic = inv[cc];
            if (!ic)
                continue;                       // not a conditional we can invert
            NSString* LT = [[t substringFromIndex:sp.location]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSInteger j = nextReal(i);
            if (j < 0)
                continue;
            NSString* jt = [lines[j] stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            if (!([jt hasPrefix:@"jmp\t"] || [jt hasPrefix:@"jmp "]))
                continue;
            NSString* LF = [[jt substringFromIndex:3]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSInteger k = nextReal((NSUInteger)j);
            if (k < 0)
                continue;
            NSString* nextLbl = labelOf(lines[(NSUInteger)k]);
            if (!nextLbl)
                continue;
            if ([nextLbl isEqualToString:LF])
                { [lines removeObjectAtIndex:(NSUInteger)j]; again = YES; break; }
            if ([nextLbl isEqualToString:LT])
                {
                lines[i] = [NSString stringWithFormat:@"\tj%@\t%@", ic, LF];
                [lines removeObjectAtIndex:(NSUInteger)j];
                again = YES;
                break;
                }
            }
        }
    return [lines componentsJoinedByString:@"\n"];
}


// Move a value between its HOME register and a GP register, choosing the
// cross-file instruction when the home is an xmm one. `mov ecx, xmm9` is not an
// instruction: between the integer and FP files it is movd (32) / movq (64).
// Floats are homed now, and a Load or Store of float BITS still goes through a
// GP register, so both directions occur.
//
// Added AFTER the call sites were rewritten, deliberately: the other way round,
// a mechanical rewrite matches this method's own else branch and it calls
// itself. That is a stack overflow, and it surfaces as EXC_BAD_ACCESS inside
// CoreFoundation string code, which looks nothing like recursion.
+ (BOOL)isXmmHome:(NSString*)r { return [r hasPrefix:@"xmm"]; }

+ (void)movFromHome:(NSString*)home width:(NSUInteger)w
               into:(NSString*)dst out:(NSMutableString*)out
{
    if ([self isXmmHome:home])
        [out appendFormat:@"\t%@\t%@, %@\n", w >= 8 ? @"movq" : @"movd", dst, home];
    else
        [out appendFormat:@"\tmov\t%@, %@\n", dst, [self regView:home width:w]];
}

+ (void)movIntoHome:(NSString*)home width:(NSUInteger)w
               from:(NSString*)src out:(NSMutableString*)out
{
    if ([self isXmmHome:home])
        [out appendFormat:@"\t%@\t%@, %@\n", w >= 8 ? @"movq" : @"movd", home, src];
    else
        [out appendFormat:@"\tmov\t%@, %@\n", [self regView:home width:w], src];
}

// ── Copy-propagation peephole ────────────────────────────────────────────
//
// The value model stages many values through the scratch registers (rax/rcx/
// rdx) — e.g. `mov edx, r14d ; mov [r12+rcx*4], edx` or the phi-copy chain
// `mov eax, r14d ; mov ebx, eax`. When a `mov Dscratch, S` is immediately
// consumed and Dscratch is dead afterwards, forward S into the consumer and
// drop the mov. Only the DELETED move's destination must be scratch (rax/rcx/
// rdx) — those never live across a block boundary or call, so the dead-out
// assumption at a label/branch/call is sound. Substitution is EXACT-WIDTH
// (string match): a 32-bit `mov ecx, ebx` feeding a 64-bit `[…+rcx*4]` address
// is left alone, because its implicit zero-extension into rcx is load-bearing.

// register token → 64-bit canonical name (nil if not a GP register).
static NSDictionary<NSString*, NSString*>* x86Canon(void)
    {
    static NSDictionary* d = nil;
    if (!d)
        {
        NSMutableDictionary* m = [NSMutableDictionary dictionary];
        NSArray* bases = @[ @"a", @"b", @"c", @"d" ];
        NSArray* r64 = @[ @"rax", @"rbx", @"rcx", @"rdx" ];
        for (NSUInteger i = 0; i < bases.count; i++)
            {
            NSString *b = bases[i], *c = r64[i];
            m[c] = c;                                      // rax/rbx/rcx/rdx
            m[[NSString stringWithFormat:@"e%@x", b]] = c; // eax/ebx/ecx/edx
            m[[b stringByAppendingString:@"x"]] = c;       // ax/bx/cx/dx
            m[[b stringByAppendingString:@"l"]] = c;       // al/bl/cl/dl
            }
        for (NSString* nm in @[ @"si", @"di", @"bp", @"sp" ])
            {
            NSString* c = [@"r" stringByAppendingString:nm];
            m[c] = c;
            m[[@"e" stringByAppendingString:nm]] = c;
            m[nm] = c;
            m[[nm stringByAppendingString:@"l"]] = c;
            }
        for (int n = 8; n <= 15; n++)
            {
            NSString* c = [NSString stringWithFormat:@"r%d", n];
            m[c] = c;
            m[[c stringByAppendingString:@"d"]] = c;
            m[[c stringByAppendingString:@"w"]] = c;
            m[[c stringByAppendingString:@"b"]] = c;
            }
        d = m;
        }
    return d;
    }

// All width-views (rcx,ecx,cx,cl) of a 64-bit canonical register.
static NSArray<NSString*>* x86ViewsFor(NSString* canon)
    {
    static NSMutableDictionary<NSString*, NSArray*>* inv = nil;
    if (!inv)
        {
        inv = [NSMutableDictionary dictionary];
        [x86Canon() enumerateKeysAndObjectsUsingBlock:^(NSString* k, NSString* v, BOOL* s) {
          NSMutableArray* a = [inv[v] mutableCopy] ?: [NSMutableArray array];
          [a addObject:k];
          inv[v] = a;
        }];
        }
    return inv[canon] ?: @[];
    }

// Whole-token (register-delimited) presence / replacement in an operand string.
static BOOL x86Mentions(NSString* s, NSString* tok)
    {
    NSString* pat = [NSString stringWithFormat:@"(?<![A-Za-z0-9_])%@(?![A-Za-z0-9_])", tok];
    return [s rangeOfString:pat options:NSRegularExpressionSearch].location != NSNotFound;
    }
// Escape a literal string for use as a regex replacement TEMPLATE — `$`
// introduces a capture-group reference and `\` is the escape, so both must be
// backslash-escaped. Apple's Foundation has +escapedTemplateForString: for this;
// GNUstep's does not, so spell it out (portable, and cheap for these operands).
static NSString* x86EscapeTemplate(NSString* to)
    {
    return [[to stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"$"
                                  withString:@"\\$"];
    }
static NSString* x86Subst(NSString* s, NSString* from, NSString* to)
    {
    NSString* pat = [NSString stringWithFormat:@"(?<![A-Za-z0-9_])%@(?![A-Za-z0-9_])", from];
    NSRange r = NSMakeRange(0, s.length);
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    return XTRegexReplace(re, s, x86EscapeTemplate(to));
    }

// Intel-syntax line → operand array (nil for labels/directives/comments/blank);
// *mnemOut set to the mnemonic. Operands split on ", " (this backend never emits
// a comma inside a `[base + idx*scale]` memory operand).
+ (NSArray<NSString*>*)x86Parse:(NSString*)line mnem:(NSString**)mnemOut
    {
    NSString* t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0 || [t hasSuffix:@":"] || [t hasPrefix:@"."] || [t hasPrefix:@"#"])
        return nil;
    NSRange sp = [t rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (sp.location == NSNotFound)
        {
        if (mnemOut)
            *mnemOut = t;
        return @[];
        }
    if (mnemOut)
        *mnemOut = [t substringToIndex:sp.location];
    NSString* rest = [[t substringFromIndex:sp.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray* ops = [[rest componentsSeparatedByString:@", "] mutableCopy];
    for (NSUInteger i = 0; i < ops.count; i++)
        ops[i] = [ops[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return ops;
    }

// Mnemonics whose operand 0 is a written destination register.
static BOOL x86WritesOp0(NSString* m)
    {
    static NSSet* s = nil;
    if (!s)
        s = [NSSet setWithArray:@[ @"mov", @"movzx", @"movsx", @"movsxd", @"lea",
                                   @"add", @"sub", @"imul", @"and", @"or", @"xor", @"neg", @"not",
                                   @"sar", @"shl", @"shr", @"inc", @"dec", @"cmove", @"cmovne", @"cmovl",
                                   @"cmovg", @"cmovle", @"cmovge", @"cmovb", @"cmova", @"cmovbe", @"cmovae" ]];
    return [s containsObject:m];
    }
// Mnemonics that transfer control (a scratch reg is dead-out past them).
static BOOL x86IsCtrl(NSString* m)
    {
    return [m hasPrefix:@"j"] || [m isEqualToString:@"call"] || [m isEqualToString:@"ret"];
    }
// Mnemonics with IMPLICIT rax/rdx clobbers (not visible in the operand list) —
// a hard barrier for the copy-prop scan, which reasons only about explicit ops.
static BOOL x86ImplicitClobber(NSString* m)
    {
    static NSSet* s = nil;
    if (!s)
        s = [NSSet setWithArray:@[ @"div", @"idiv", @"mul", @"cqo", @"cdq",
                                   @"cwd", @"cdqe", @"cbw", @"cwde" ]];
    return [s containsObject:m];
    }
// Variable shift/rotate — the count operand MUST be `cl` (or an immediate), so an
// `mov cl, r` feeding one cannot be forwarded (`shl eax, r12b` is illegal).
static BOOL x86IsShift(NSString* m)
    {
    static NSSet* s = nil;
    if (!s)
        s = [NSSet setWithArray:@[ @"shl", @"shr", @"sar", @"sal",
                                   @"rol", @"ror", @"rcl", @"rcr" ]];
    return [s containsObject:m];
    }

+ (NSString*)peepholeCopyProp:(NSString*)text
    {
    NSMutableArray<NSString*>* lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL again = YES;
    while (again)
        {
        again = NO;
        for (NSUInteger i = 0; i + 1 < lines.count; i++)
            {
            NSString* mm = nil;
            NSArray* mo = [self x86Parse:lines[i] mnem:&mm];
            if (!mo || mo.count != 2 || ![mm isEqualToString:@"mov"])
                continue;
            NSString *D = mo[0], *S = mo[1];
            if ([D isEqualToString:S])
                continue;
            NSString* dcanon = x86Canon()[D];
            if (!dcanon)
                continue; // D not a bare register
            if (!([dcanon isEqualToString:@"rax"] || [dcanon isEqualToString:@"rcx"] || [dcanon isEqualToString:@"rdx"]))
                continue; // D must be scratch
            if (!x86Canon()[S])
                continue; // S must be a bare register

            NSString* scanon = x86Canon()[S];
            NSArray<NSString*>* dviews = x86ViewsFor(dcanon);
            BOOL (^reads)(NSString*) = ^BOOL(NSString* ln) {
              for (NSString* v in dviews)
                  if (x86Mentions(ln, v))
                      return YES;
              return NO;
            };

            // Forward-scan for the consumer — the first line that uses D as a source,
            // through "transparent" lines only. Stop (no transform) at a control
            // transfer, an implicit rax/rdx clobber, a write to S, a redefinition of
            // D, or a block boundary. (Adjacency isn't required: the value is often
            // computed between the mov and its store.)
            NSInteger cons = -1;
            for (NSUInteger j = i + 1; j < lines.count; j++)
                {
                NSString* jm = nil;
                NSArray* jo = [self x86Parse:lines[j] mnem:&jm];
                if (!jo)
                    {
                    NSString* tr = [lines[j] stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceCharacterSet]];
                    if (tr.length == 0)
                        continue;
                    break; // label/directive
                    }
                if (x86IsCtrl(jm) || x86ImplicitClobber(jm))
                    break;
                BOOL wr0 = x86WritesOp0(jm) && jo.count >= 1 && x86Canon()[jo[0]] != nil;
                if (wr0 && [x86Canon()[jo[0]] isEqualToString:scanon])
                    break; // S clobbered
                NSUInteger srcStart = wr0 ? 1 : 0;
                BOOL dInSrc = NO;
                for (NSUInteger k = srcStart; k < jo.count; k++)
                    if ([dviews indexOfObjectPassingTest:^BOOL(NSString* v, NSUInteger idx, BOOL* st) {
                          return x86Mentions(jo[k], v);
                        }] != NSNotFound)
                        {
                        dInSrc = YES;
                        break;
                        }
                if (dInSrc)
                    {
                    // D is an accumulator here (also written) → the mov is live; skip.
                    if (wr0 && [x86Canon()[jo[0]] isEqualToString:dcanon])
                        break;
                    cons = (NSInteger)j;
                    break;
                    }
                if (wr0 && [x86Canon()[jo[0]] isEqualToString:dcanon])
                    break; // D redefined (dead store)
                }
            if (cons < 0)
                continue;

            // Substitute exact-token D→S in the consumer's source operands.
            NSString* cm = nil;
            NSMutableArray* co = [[self x86Parse:lines[cons] mnem:&cm] mutableCopy];
            // `cl` as a shift count must stay `cl`; never forward it into a shift.
            if (x86IsShift(cm) && [dcanon isEqualToString:@"rcx"])
                continue;
            BOOL cWr0 = x86WritesOp0(cm) && co.count >= 1 && x86Canon()[co[0]] != nil;
            BOOL used = NO;
            for (NSUInteger k = (cWr0 ? 1 : 0); k < co.count; k++)
                if (x86Mentions(co[k], D))
                    {
                    co[k] = x86Subst(co[k], D, S);
                    used = YES;
                    }
            if (!used)
                continue;

            // D (its whole register family) must be dead after the consumer. SOUND
            // basis: a scratch register (rax/rcx/rdx) is NEVER live INTO a basic
            // block — the backend reloads it before use at every branch target — so
            // the only reads of THIS definition are on the straight-line path until
            // D is redefined. Scan the rest of the function linearly (through labels
            // and branches): a read of D-family before any kill ⇒ live (skip); a
            // pure redefinition, or reaching the end with no read ⇒ dead. This is
            // what makes the ARC null-check safe: `cmp p,#; jb .skip; addw [p-2],1`
            // has a later `[rax-2]` read, so the mov into rax is kept.
            BOOL dead = YES;
            for (NSUInteger j = (NSUInteger)cons + 1; j < lines.count; j++)
                {
                NSString* jm = nil;
                NSArray* jo = [self x86Parse:lines[j] mnem:&jm];
                if (!jo)
                    continue; // label/directive/blank
                // hidden rax/rdx use → assume live
                if (x86ImplicitClobber(jm))
                    {
                    dead = NO;
                    break;
                    }
                if (reads(lines[j]))
                    {
                    // A pure overwrite of exactly D (same width), with D absent from
                    // the sources, KILLS the old value before it is read.
                    BOOL pureDef = x86WritesOp0(jm) && jo.count >= 1 && [jo[0] isEqualToString:D];
                    BOOL srcReads = NO;
                    if (pureDef)
                        for (NSUInteger k = 1; k < jo.count; k++)
                            if (reads(jo[k]))
                                srcReads = YES;
                    dead = pureDef && !srcReads;
                    break;
                    }
                }
            if (!dead)
                continue;

            NSString* lead = [lines[cons] substringToIndex:
                                              [lines[cons] rangeOfString:cm].location]; // keep indentation
            lines[cons] = [NSString stringWithFormat:@"%@%@\t%@", lead, cm,
                                                     [co componentsJoinedByString:@", "]];
            [lines removeObjectAtIndex:i];
            again = YES;
            break;
            }
        }
    return [lines componentsJoinedByString:@"\n"];
    }

// Thread-safe ARC (private:docs/Design/threading.md §4.1) — see the arm64 backend for
// why the decision is made here rather than in the xtcg main: the backend has
// more than one caller and only one of them parses command lines.
static BOOL sX86ThreadSafeARC = NO;
static NSInteger sX86ThreadSafeARCOverride = -1;

+ (void)setThreadSafeARCOverride:(NSInteger)mode
    {
    sX86ThreadSafeARCOverride = mode;
    }
+ (BOOL)threadSafeARC
    {
    return sX86ThreadSafeARC;
    }

+ (NSString*)assemblyFromModule:(XTIRModule*)mod
    {
    sX86ThreadSafeARC = sX86ThreadSafeARCOverride >= 0
                            ? (sX86ThreadSafeARCOverride != 0)
                            : [mod referencesSymbolNamed:@"_xt_thread_create"];
    NSMutableString* out = [NSMutableString string];
    [out appendString:@"\t.intel_syntax noprefix\n\t.text\n"];
    for (XTIRFunction* fn in mod.functions)
        {
        if (fn.blocks.count == 0)
            continue;                                     // external proto — linker resolves
        NSMutableString* fbuf = [NSMutableString string]; // per-function → peephole
        [self emitFunction:fn module:mod into:fbuf];
        [out appendString:[self peepholeFallthrough:[self peepholeCopyProp:fbuf]]];
        }

    // Read-only data: string literals (+ initialised globals).
    NSMutableString *rodata = [NSMutableString string], *data = [NSMutableString string],
                    *bss = [NSMutableString string];
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind == XTIRSymbolKindStringLit && sym.stringBytes)
            {
            [rodata appendFormat:@"%@:\n", [self safeSym:sym.name]];
            [self emitBytes:sym.stringBytes into:rodata];
            }
        else if (sym.kind == XTIRSymbolKindDataGlobal)
            {
            // `extern` — defined in another module. Reserve no storage; emitting it here
            // would give this module a SECOND COPY whose writes never reach the other's.
            if (sym.isExternalGlobal)
                continue;
            if (sym.initialBytes)
                {
                NSData* bytes = sym.initialBytes;
                XTIRType* gt = sym.globalType;
                if (gt.kind == XTIRTypeKindAgg && gt.layout)
                    {
                    bytes = [XTAggInitRelay relay:bytes
                                           layout:gt.layout
                                      widthOfLeaf:^NSUInteger(XTIRType* t) {
                                        return [XTX86_64Backend fieldWidth:t];
                                      }
                                        bigEndian:NO];
                    }
                // The FE carries a float global's initialiser as 8 IEEE-double bits
                // regardless of its declared width; re-encode to the native target
                // width (F32 single / F64 double) so an F32 global isn't left with
                // the double's low 4 (zero) bytes. (Byte-list inits already match
                // the slot size, so length==fieldWidth bypasses this.) Mirrors
                // XTArm64Backend.
                if (gt && [self isFloatKind:gt.kind] && bytes.length != [self fieldWidth:gt])
                    {
                    uint64_t raw = 0;
                    [bytes getBytes:&raw length:MIN((NSUInteger)8, bytes.length)];
                    double v;
                    memcpy(&v, &raw, sizeof(v));
                    if (gt.kind == XTIRTypeKindF64)
                        {
                        bytes = [NSData dataWithBytes:&raw length:8];
                        }
                    else
                        {
                        float fv = (float)v;
                        uint32_t fb;
                        memcpy(&fb, &fv, sizeof(fb));
                        bytes = [NSData dataWithBytes:&fb length:4];
                        }
                    }
                // A file-scope global has EXTERNAL linkage in C — export it so
                // separate units share one definition. Local-only (no `.globl`)
                // gave each unit a private copy (win64/PE keeps its own path).
                if (!sWin64)
                    [data appendFormat:@"\t.globl\t%@\n", [self safeSym:sym.name]];
                [data appendFormat:@"%@:\n", [self safeSym:sym.name]];
                [self emitBytes:bytes into:data];
                }
            // uninitialised → COMMON / BSS
            else
                {
                // Size with the RECOMPUTED native width (pointer = 8, Agg via
                // aggSize), not the FE 2-byte-pointer/0-for-Ptr byteWidth — else a
                // global that is written at its native width overflows into the
                // adjacent global and cross-corrupts it. This covers static-class
                // data (__sdata_<C>, an Agg) AND a bare class-pointer global
                // (`Foo@ g;`): the latter has byteWidth 0, so the old code gave it
                // 1 byte, and an 8-byte pointer store clobbered the next global —
                // whose stale value then faulted the ARC release-before-assign.
                XTIRType* gt = sym.globalType;
                NSUInteger sz = gt ? [self fieldWidth:gt] : 1;
                if (sz == 0)
                    sz = 1;
                if (sWin64)
                    {
                    [bss appendFormat:@"%@:\n\t.zero\t%lu\n", [self safeSym:sym.name], (unsigned long)sz];
                    }
                else
                    {
                    // An UNINITIALISED file-scope global is a C tentative
                    // definition → a COMMON symbol, so separately-compiled units
                    // (and #used C libraries) merge it to one slot. A local
                    // `.bss` def gave each unit a PRIVATE copy — cross-object
                    // writes never met (c2xc bug 36, cross-object variant).
                    NSUInteger al = sz >= 8 ? 8 : (sz >= 4 ? 4 : (sz >= 2 ? 2 : 1));
                    [bss appendFormat:@"\t.comm\t%@, %lu, %lu\n",
                                      [self safeSym:sym.name], (unsigned long)sz, (unsigned long)al];
                    }
                }
            }
        }
    // VTables — one 4-byte function pointer per slot (heap-pointer width). Code
    // One 8-byte (.quad) function pointer per slot — host pointers are 8 bytes.
    NSMutableString* vtbl = [NSMutableString string];
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindVTable)
            continue;
        // `extern` — an imported class's vtable lives in its library; emit no local
        // copy (a second table at a different address would break RTTI identity, which
        // compares vtable addresses). The AddrOf reference resolves to the one table.
        if (sym.isExternalGlobal)
            continue;
        [vtbl appendFormat:@"\t.globl\t%@\n\t.p2align 2\n%@:\n", [self safeSym:sym.name], [self safeSym:sym.name]];
        NSArray<NSString*>* entries = sym.vtableEntryNames;
        if (entries.count == 0)
            {
            [vtbl appendString:@"\t.quad\t0\n"];
            continue;
            }
        for (NSString* e in entries)
            {
            if (!e.length)
                {
                [vtbl appendString:@"\t.quad\t0\n"];
                continue;
                }
            // Conformance itable (protoId, &table) pairs: the id is a literal value.
            if ([e hasPrefix:@"__protoid_"])
                [vtbl appendFormat:@"\t.quad\t%@\n", [e substringFromIndex:[@"__protoid_" length]]];
            else
                [vtbl appendFormat:@"\t.quad\t%@\n", e];
            }
        }

    if (rodata.length)
        {
        [out appendString:@"\t.section .rodata\n"];
        [out appendString:rodata];
        }
    if (vtbl.length)
        {
        [out appendString:@"\t.data\n"];
        [out appendString:vtbl];
        }
    if (data.length)
        {
        [out appendString:@"\t.data\n"];
        [out appendString:data];
        }
    if (bss.length)
        {
        [out appendString:@"\t.bss\n"];
        [out appendString:bss];
        }
    // Load-time constructors — static initialisers, XG-NIB factory
    // self-registration, static-init guards. A table of pointers in .data
    // between `__xt_ctors_start` and `__xt_ctors_end`, which crt-linux.s and
    // crt-win64.s walk before calling main (bug 134). It used to be an ELF
    // `.init_array` entry, which is right for a link that has an ld script
    // and a libc start that walks it; this toolchain has neither. The
    // in-house assembler folded the section into .data, the linker defined
    // `__init_array_start == __init_array_end` on purpose (musl's archives
    // carry none), and crt-linux.s called main directly — so the pointer
    // sat in the image and nothing ever ran it. On win64 the mingw
    // `__attribute__((constructor))` stub that used to carry it is gone with
    // the mingw fallback. One table, both hosts, no object-format change.
    //
    // The ENTRY module — the one defining main — always defines the bounds,
    // empty or not, since the crt references them. A module that defines
    // neither main nor a constructor defines nothing, so a library object
    // adds no symbol; a second module WITH constructors linked into one
    // executable is a duplicate-definition error, loudly, until the linkers
    // collect per-object tables (the design in private:docs/bugs/134).
    BOOL hasMain = NO;
    for (XTIRFunction* fn in mod.functions)
        if ([fn.name isEqualToString:@"main"])
            {
            hasMain = YES;
            break;
            }
    if (mod.moduleInitFunctionNames.count > 0 || hasMain)
        {
        [out appendString:@"\t.data\n\t.p2align 3\n\t.globl\t__xt_ctors_start\n__xt_ctors_start:\n"];
        for (NSString* initName in mod.moduleInitFunctionNames)
            [out appendFormat:@"\t.quad\t%@\n", initName];
        [out appendString:@"\t.globl\t__xt_ctors_end\n__xt_ctors_end:\n"];
        }
    return out;
    }

// Emit an NSData as `.byte b, b, …` (8 per line).
+ (void)emitBytes:(NSData*)bytes into:(NSMutableString*)out
    {
    const uint8_t* p = bytes.bytes;
    NSUInteger n = bytes.length;
    for (NSUInteger i = 0; i < n; i += 8)
        {
        [out appendString:@"\t.byte\t"];
        for (NSUInteger j = i; j < n && j < i + 8; j++)
            [out appendFormat:@"%@%u", j > i ? @", " : @"", (unsigned)p[j]];
        [out appendString:@"\n"];
        }
    }

// SSE packed arithmetic mnemonic for a lane type + Vec opcode (nil = unsupported).
// Integer lanes need SSE2 (SSE4.1 for pmulld); float lanes SSE.
+ (NSString*)sseMnemForVecOp:(XTIROpcode)op lane:(XTIRType*)lane
    {
    BOOL flt = lane && [self isFloatKind:lane.kind];
    if (flt)
        {
        BOOL d = lane.kind == XTIRTypeKindF64;
        switch (op)
            {
        case XTIROpVAdd:
            return d ? @"addpd" : @"addps";
        case XTIROpVSub:
            return d ? @"subpd" : @"subps";
        case XTIROpVMul:
            return d ? @"mulpd" : @"mulps";
        case XTIROpVAnd:
            return d ? @"andpd" : @"andps";
        case XTIROpVOr:
            return d ? @"orpd" : @"orps";
        case XTIROpVXor:
            return d ? @"xorpd" : @"xorps";
        case XTIROpVMax:
            return d ? @"maxpd" : @"maxps";
        case XTIROpVMin:
            return d ? @"minpd" : @"minps";
        default:
            return nil;
            }
        }
    NSUInteger w = [self fieldWidth:lane]; // lane byte width: 1/2/4/8
    BOOL sgn = lane && XTIRTypeKindIsSigned(lane.kind);
    switch (op)
        {
    case XTIROpVAdd:
        return w == 1 ? @"paddb" : w == 2 ? @"paddw"
                               : w == 4   ? @"paddd"
                                          : @"paddq";
    case XTIROpVSub:
        return w == 1 ? @"psubb" : w == 2 ? @"psubw"
                               : w == 4   ? @"psubd"
                                          : @"psubq";
    case XTIROpVMul:
        return w == 2 ? @"pmullw" : w == 4 ? @"pmulld"
                                           : nil; // no 8/16-bit-lane byte mul
    case XTIROpVAnd:
        return @"pand";
    case XTIROpVOr:
        return @"por";
    case XTIROpVXor:
        return @"pxor";
    case XTIROpVMax:
        return w == 4 ? (sgn ? @"pmaxsd" : @"pmaxud") : w == 2 ? (sgn ? @"pmaxsw" : @"pmaxuw")
                                                    : w == 1   ? (sgn ? @"pmaxsb" : @"pmaxub")
                                                               : nil;
    case XTIROpVMin:
        return w == 4 ? (sgn ? @"pminsd" : @"pminud") : w == 2 ? (sgn ? @"pminsw" : @"pminuw")
                                                    : w == 1   ? (sgn ? @"pminsb" : @"pminub")
                                                               : nil;
    default:
        return nil;
        }
    }

// Whole-function SSE register assignment for Vec-typed values. Linear-scan with
// reuse over live intervals; a vector phi coalesces its incoming values onto the
// phi's own register (an in-place accumulator needs no back-edge copy). Ported
// from the arm64 vector allocator; pool is xmm2..xmm15.
+ (NSDictionary<NSNumber*, NSString*>*)assignVectorRegsFor:(XTIRFunction*)fn
    {
    NSMutableSet<NSNumber*>* vecVals = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                [vecVals addObject:@(p.result.valueId)];
        for (XTIRInsn* in in bb.instructions)
            if (in.result && in.result.type.kind == XTIRTypeKindVec)
                [vecVals addObject:@(in.result.valueId)];
        }
    if (vecVals.count == 0)
        return nil;

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
    NSMutableArray<NSNumber*>* blkPosStart = [NSMutableArray array]; // per-block first linear pos
    NSMutableArray<NSNumber*>* blkPosEnd = [NSMutableArray array];   // per-block last linear pos
    for (XTIRBlock* bb in fn.blocks)
        {
        [blkPosStart addObject:@(pos)];
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
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
        [blkPosEnd addObject:@(pos > 0 ? pos - 1 : 0)];
        }

    // Back-edge-aware interval extension (see the arm64 twin in
    // allocateVectorRegistersForCtx: for the full rationale). A loop-invariant
    // vector value materialised ONCE before a loop (e.g. a preheader splat) is
    // read every iteration and must stay live across the back-edge, else its
    // xmm register is reused mid-loop and the splat is corrupted on the next
    // iteration. For each natural loop [header..latch] (a terminator edge to an
    // earlier/equal block; loop bodies are contiguous ranges), any class defined
    // before the loop and last-used inside it is extended to the loop's end.
    NSUInteger nblk = fn.blocks.count;
    for (NSUInteger bi = 0; bi < nblk; bi++)
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
                continue; // forward edge, not a loop
            NSInteger loopStart = blkPosStart[tgt].integerValue;
            NSInteger loopEnd = blkPosEnd[bi].integerValue;
            for (NSNumber* cls in lo.allKeys)
                {
                if (lo[cls].integerValue < loopStart &&
                    hi[cls].integerValue >= loopStart &&
                    hi[cls].integerValue <= loopEnd)
                    hi[cls] = @(loopEnd);
                }
            }
        }

    NSArray<NSNumber*>* classes = [lo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
      return [lo[a] compare:lo[b]];
    }];
    // Pool: xmm2..xmm15 (xmm0/xmm1 stay emission scratch — VICmp/VReduce/VAddLP
    // synthesise masks in them). Allocation pops from the END, so the order is
    // reverse preference: xmm15..xmm8 first (the historical pool), then
    // xmm5..xmm2, and xmm7/xmm6 dead last — those two are callee-saved on
    // Win64 (the prologue does not save xmm regs), so they are touched only
    // under pressure no real program has reached. Exhaustion is a HARD error:
    // the old `?: @(15)` fallback silently reused a live register, which is
    // how vectorize_outer_iv_addend computed src[i]² instead of src[i]*3
    // (pmulld xmm15, xmm15 — the splat-of-3 clobbered by a VLoad) (#1198).
    NSMutableArray<NSNumber*>* freePool = [NSMutableArray array];
    for (NSNumber* r in @[ @6, @7, @2, @3, @4, @5, @8, @9, @10, @11, @12, @13, @14, @15 ])
        [freePool addObject:r];
    // Which instruction defines each class, and whether that class is a phi
    // result — for the two-address coalescing below.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOfClass = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* phiClass = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                [phiClass addObject:@(classOf(p.result.valueId))];
        for (XTIRInsn* in in bb.instructions)
            if (in.result && in.result.type.kind == XTIRTypeKindVec)
                defOfClass[@(classOf(in.result.valueId))] = in;
        }

    NSMutableArray<NSNumber*>* active = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* regOfClass = [NSMutableDictionary dictionary];
    for (NSNumber* cls in classes)
        {
        NSInteger start = lo[cls].integerValue;
        NSMutableArray<NSNumber*>* stillActive = [NSMutableArray array];
        for (NSNumber* a in active)
            {
            if (hi[a].integerValue < start)
                [freePool addObject:regOfClass[a]];
            else
                [stillActive addObject:a];
            }
        [active setArray:stillActive];
        if (freePool.count == 0)
            {
            fprintf(stderr, "xcc-cg-x86_64: error: vector register pressure exceeded "
                            "the %d-register SSE pool in '%s'\n",
                    14,
                    fn.name.UTF8String);
            exit(1);
            }
        // TWO-ADDRESS COALESCING. x86 vector ops are destructive — `paddd d, b`
        // writes d — so when the result gets a different register from a source
        // that DIES at this instruction, the emitter has to copy:
        //
        //     movdqu xmm14, [r8]        arm64, three-address, needs no copy:
        //     movdqa xmm13, xmm14   <--   ldr q30, [x11]
        //     paddd  xmm13, xmm15         add v29.4s, v30.4s, v31.4s
        //     movdqu [rsi], xmm13         str q29, [x10]
        //
        // Linear scan never reuses the source because it frees a register only
        // when `hi < start`, and here the source dies exactly AT the position
        // the result is born. For a two-address op that is precisely the case
        // where reuse is correct: the instruction reads the source and writes
        // the destination, which is what the machine instruction does anyway.
        //
        // Phi classes are excluded — a vector phi needs a register of its own,
        // and the incoming values are already coalesced onto it above.
        NSNumber* reg = nil;
        XTIRInsn* def = defOfClass[cls];
        if (def && ![phiClass containsObject:cls] && def.operands.count >= 1 &&
            def.opcode != XTIROpVLoad && def.operands[0].kind == XTIROperandKindUse)
            {
            NSNumber* acls = @(classOf(def.operands[0].valueId));
            if (![acls isEqual:cls] && ![phiClass containsObject:acls] &&
                regOfClass[acls] && hi[acls] && hi[acls].integerValue == start &&
                [active containsObject:acls])
                {
                reg = regOfClass[acls];
                [active removeObject:acls]; // its interval ends here
                }
            }
        if (!reg)
            {
            reg = freePool.lastObject;
            [freePool removeLastObject];
            }
        regOfClass[cls] = reg;
        [active addObject:cls];
        [active sortUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
          return [hi[a] compare:hi[b]];
        }];
        }
    NSMutableDictionary<NSNumber*, NSString*>* out = [NSMutableDictionary dictionary];
    for (NSNumber* v in vecVals)
        out[v] = [NSString stringWithFormat:@"xmm%@", regOfClass[@(classOf(v.unsignedIntegerValue))]];
    return out;
    }

+ (void)emitFunction:(XTIRFunction*)fn module:(XTIRModule*)mod into:(NSMutableString*)out
    {
    NSString* name = fn.name;
    // `.type … @function` is ELF-only; PE/COFF (Win64) rejects it.
    if (sWin64)
        [out appendFormat:@"\t.globl\t%@\n%@:\n", name, name];
    else
        [out appendFormat:@"\t.globl\t%@\n\t.type\t%@, @function\n%@:\n", name, name, name];

    BOOL hasAsm = NO;
    for (XTIRBlock* ab in fn.blocks)
        for (XTIRInsn* ai in ab.instructions)
            if (ai.opcode == XTIROpAsm)
                {
                hasAsm = YES;
                break;
                }

    // Address folding — computed BEFORE homing so folded addresses are excluded
    // from it (a folded addr is never materialised → a home register would be
    // wasted). An ElementAddr/FieldAddr whose result is used exactly once folds
    // into its consumer's memory operand: (a) an immediately-following Load (`mov
    // edx,[r12+rcx*4]`), or (b) a Store whose ADDRESS operand is this addr (`mov
    // [r12+rcx*4],edx`) — the store consumer need not be adjacent since the
    // base/index are recomputed at the store site.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* fold = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* fused = [NSMutableSet set];
    NSMutableDictionary<NSNumber*, XTIRInsn*>* skip = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRInsn*>* selCmp = [NSMutableDictionary dictionary];
    if (!hasAsm)
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* uc = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber*, XTIRInsn*>* useOf = [NSMutableDictionary dictionary];
        void (^rec)(XTIROperand*, XTIRInsn*) = ^(XTIROperand* o, XTIRInsn* host) {
          if (o.kind != XTIROperandKindUse)
              return;
          uc[@(o.valueId)] = @(uc[@(o.valueId)].integerValue + 1);
          useOf[@(o.valueId)] = host; // meaningful only when the count stays 1
        };
        for (XTIRBlock* b in fn.blocks)
            {
            // Phi operands live in a SEPARATE array from `instructions` — a value
            // consumed only by a loop-carried phi (a pointer-advance back-edge) is
            // still multiply-used and must NOT be folded away.
            for (XTIRInsn* p in b.phiNodes)
                for (XTIROperand* o in p.operands)
                    rec(o, p);
            for (XTIRInsn* in in b.instructions)
                for (XTIROperand* o in in.operands)
                    rec(o, in);
            if (b.terminator)
                for (XTIROperand* o in b.terminator.operands)
                    rec(o, b.terminator);
            }
        for (XTIRBlock* b in fn.blocks)
            {
            NSArray<XTIRInsn*>* ins = b.instructions;
            for (NSUInteger i = 0; i < ins.count; i++)
                {
                XTIRInsn* ea = ins[i];
                if ((ea.opcode != XTIROpElementAddr && ea.opcode != XTIROpFieldAddr) || !ea.result)
                    continue;
                if (uc[@(ea.result.valueId)].integerValue != 1)
                    continue;
                // pow2 stride only (x86 scale)
                if (ea.opcode == XTIROpElementAddr)
                    {
                    XTIRValue* base = ea.operands[0].kind == XTIROperandKindUse ? fn.values[@(ea.operands[0].valueId)] : nil;
                    NSUInteger st = (base && base.type.pointeeType) ? [self fieldWidth:base.type.pointeeType] : 1;
                    if (!(st == 1 || st == 2 || st == 4 || st == 8))
                        continue;
                    }
                XTIRInsn* cons = useOf[@(ea.result.valueId)];
                // (a) adjacent Load — fold into its source memory operand.
                if (i + 1 < ins.count && ins[i + 1] == cons && cons.opcode == XTIROpLoad && cons.operands.count >= 1 && cons.operands[0].kind == XTIROperandKindUse && cons.operands[0].valueId == ea.result.valueId && !(cons.result && cons.result.type.kind == XTIRTypeKindAgg))
                    {
                    fold[@(ea.result.valueId)] = ea;
                    continue;
                    }
                // (b) Store whose ADDRESS (ops[0], not the value ops[1]) is this addr —
                // fold into the destination memory operand. The consumer need not be
                // adjacent: the base/index are recomputed at the store site (kept live
                // by the foldInfo hook). Skip aggregate stores (byte-copy path).
                if (cons.opcode == XTIROpStore && cons.operands.count >= 2 && cons.operands[0].kind == XTIROperandKindUse && cons.operands[0].valueId == ea.result.valueId)
                    {
                    XTIRValue* vv = cons.operands[1].kind == XTIROperandKindUse
                                        ? fn.values[@(cons.operands[1].valueId)]
                                        : nil;
                    if (vv && vv.type.kind == XTIRTypeKindAgg)
                        continue;
                    fold[@(ea.result.valueId)] = ea;
                    continue;
                    }
                }
            }
        // Compare-and-branch fusion: a block ending in `CondBranch %c` where %c is
        // an ICmp that is the block's LAST instruction (flags reach the branch
        // untouched) and is used ONLY by that branch.
        for (XTIRBlock* b in fn.blocks)
            {
            XTIRInsn* term = b.terminator;
            if (!term || term.opcode != XTIROpCondBranch)
                continue;
            XTIROperand* cond = nil;
            for (XTIROperand* o in term.operands)
                if (o.kind != XTIROperandKindBlock)
                    {
                    cond = o;
                    break;
                    }
            if (!cond || cond.kind != XTIROperandKindUse)
                continue;
            if (uc[@(cond.valueId)].integerValue != 1)
                continue;
            XTIRInsn* last = b.instructions.lastObject;
            if (last && last.opcode == XTIROpICmp && last.result && last.result.valueId == cond.valueId)
                [fused addObject:@(cond.valueId)];
            }
        // Compare-and-select fusion (see sSelSkip).
        for (XTIRBlock* b in fn.blocks)
            {
            NSMutableDictionary<NSNumber*, XTIRInsn*>* defs = [NSMutableDictionary dictionary];
            for (XTIRInsn* in in b.instructions)
                if (in.result)
                    defs[@(in.result.valueId)] = in;
            for (XTIRInsn* in in b.instructions)
                {
                if (in.opcode != XTIROpSelect || !in.result || in.operands.count < 3)
                    continue;
                XTIROperand* c = in.operands[0];
                if (c.kind != XTIROperandKindUse || uc[@(c.valueId)].integerValue != 1)
                    continue;
                XTIRInsn* cmp = defs[@(c.valueId)];
                if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2)
                    continue;
                if ([fused containsObject:@(c.valueId)])
                    continue;
                // Immediate RHS only, and one that a cmp can encode.
                if (cmp.operands[1].kind != XTIROperandKindImmI)
                    continue;
                long long k = (long long)cmp.operands[1].intValue;
                if (k < INT32_MIN || k > INT32_MAX)
                    continue;
                skip[@(c.valueId)] = cmp;
                selCmp[@(in.result.valueId)] = cmp;
                }
            }
        }
    sFold = fold;
    sFusedCmp = fused;
    sSelSkip = skip;
    sSelCmp = selCmp;
    sVec = hasAsm ? nil : [self assignVectorRegsFor:fn]; // SSE regs for Vec values

    // Register homing (GP callee-saved rbx/r12-r15). Folded addresses excluded.
    NSArray<NSString*>* usedSaves = @[];
    if (hasAsm)
        {
        sHome = nil;
        sHomeSaves = nil;
        }
    else
        {
        NSMutableSet<NSNumber*>* excluded = [NSMutableSet setWithArray:fold.allKeys];
        [excluded unionSet:fused]; // fused ICmp results are never materialised
        [excluded addObjectsFromArray:skip.allKeys]; // ...nor are Select-fused ones
        // Floats used to stay in slots entirely, and float_math showed it:
        // sixteen instructions for four of arithmetic, every intermediate
        // stored and immediately reloaded. Every xmm is caller-saved under
        // SysV, so these are a CALLER tier and the allocator's crossesCall test
        // keeps anything live across a call out of them by itself.
        //
        // xmm0/xmm1 are emission scratch and xmm2-xmm15 are the vectoriser's
        // pool, so this is gated on the function having no Vec value at all,
        // exactly as arm64 gates d18-d31 on fnHasVector.
        BOOL fnHasVector = NO;
        for (XTIRBlock* vb in fn.blocks)
            {
            for (XTIRInsn* vi in vb.instructions)
                if (vi.result && vi.result.type && vi.result.type.kind == XTIRTypeKindVec)
                    { fnHasVector = YES; break; }
            if (fnHasVector) break;
            for (XTIRInsn* vp in vb.phiNodes)
                if (vp.result && vp.result.type && vp.result.type.kind == XTIRTypeKindVec)
                    { fnHasVector = YES; break; }
            if (fnHasVector) break;
            }
        NSArray<NSString*>* fpPool = fnHasVector ? @[]
            : @[ @"xmm8", @"xmm9", @"xmm10", @"xmm11", @"xmm12", @"xmm13",
                 @"xmm14", @"xmm15" ];
        // GP caller tier. SysV leaves only five callee-saved registers, so a
        // function with more than five hot values put the rest in slots and the
        // hot loop became store/reload traffic — call_depth spent 25 of its 60
        // loop instructions moving temporaries in and out of the frame. These
        // six are caller-saved on their ABI and are NOT emission scratch (rax,
        // rcx and rdx are), so a value that crosses no call may live in one for
        // free. The allocator's crossesCall test is inclusive at both ends, so a
        // value that is an operand OR the result of a call is already barred —
        // which is what makes the argument registers safe despite the marshalling
        // sequence writing them in order.
        //
        // Under Win64 rdi and rsi are callee-saved, so only r8-r11 qualify.
        NSArray<NSString*>* gpCallerPool = sWin64
            ? @[ @"r8", @"r9", @"r10", @"r11" ]
            : @[ @"rdi", @"rsi", @"r8", @"r9", @"r10", @"r11" ];
        XTHomingResult* hr = [XTHomingAllocator assignHomesForFunction:fn
                                                              gpCallee:@[ @"rbx", @"r12", @"r13", @"r14", @"r15" ]
                                                              gpCaller:gpCallerPool
                                                              fpCallee:@[]
                                                              fpCaller:fpPool
                                                              excluded:excluded
                                                              foldInfo:fold
                                                               selInfo:skip];
        // A parameter homed in one of these is safe even though four of them
        // are incoming-argument registers: the prologue SPILLS every parameter
        // to its slot first and only then seeds the homes from those slots, so
        // nothing reads an argument register after the seeding starts.
        sHome = hr.homeReg;
        usedSaves = hr.usedCalleeSaved;
        }

    // One 8-byte slot per non-memory value, addressed [rbp-off]. In PRINT
    // order, not value-id order: ids are creation order, and after a pass has
    // moved an instruction the two differ — the self-hosted back end reads the
    // printed numbering and laid the same value out at a different offset
    // (bug 090, 30 functions in int_arith.xc at -O3, every one a slot swap).
    NSMutableDictionary<NSNumber*, NSNumber*>* slot = [NSMutableDictionary dictionary];
    NSUInteger cur = 0;
    for (XTIRValue* v in [fn valuesInPrintOrder])
        {
        if ([self isMem:v])
            continue;
        cur += [self slotSizeOf:v]; // aggregates (pinned locals) get full size
        slot[@(v.valueId)] = @(cur);
        }
    NSMutableDictionary<NSString*, NSNumber*>* saves = [NSMutableDictionary dictionary];
    // callee-save area
    for (NSString* r in usedSaves)
        {
        cur += 8;
        saves[r] = @(cur);
        }
    sHomeSaves = saves;
    // Hidden sret (Win64 >8-byte, System V >16-byte MEMORY-class return):
    // reserve one slot for the caller's destination pointer.
    sWin64SretOff = 0;
    BOOL hasSret = [self isBigAgg:fn.returnType] || [self isSysVMemRet:fn.returnType];
    if (hasSret)
        {
        cur += 8;
        sWin64SretOff = (NSInteger)cur;
        }
    NSUInteger frame = (cur + 15) & ~(NSUInteger)15; // keep rsp 16-aligned

    [out appendString:@"\tpush\trbp\n\tmov\trbp, rsp\n"];
    if (frame)
        [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)frame];
    for (NSString* r in usedSaves) // persist clobbered callee-saved homes
        [out appendFormat:@"\tmov\t[rbp-%@], %@\n", saves[r], r];
    if (hasSret) // rcx/rdi = caller's result buffer
        [out appendFormat:@"\tmov\t[rbp-%ld], %@\n", (long)sWin64SretOff,
                          sWin64 ? @"rcx" : @"rdi"];

    if (sWin64)
        {
        // Win64 param spill. A single POSITIONAL counter shared by int and float:
        // arg at position p (p<4) is in [rcx,rdx,r8,r9][p] (int/ptr/agg-chunk) or
        // xmm{p} (float). Args past position 4 are on the stack, above the caller's
        // 32-byte shadow store: first stack arg at [rbp+48] ([rbp+8]=ret, +16..48
        // shadow), then +8 each. Aggregates use the same private N-chunk packing as
        // SysV but consume positional slots (caller/callee agree — same backend).
        NSArray<NSString*>* ireg4 = [self argRegs64]; // rcx,rdx,r8,r9
        NSUInteger pos = hasSret ? 1 : 0, sstack = 0; // rcx = sret when present
        for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
            {
            XTIRValue* pv = fn.values[@(i)];
            if (!pv || [self isMem:pv])
                continue;
            NSNumber* s = slot[@(i)];
            if (pv.type.kind == XTIRTypeKindAgg && [self isBigAgg:pv.type])
                {
                // Win64: a >8-byte struct arrives BY REFERENCE — one positional slot
                // holds a pointer to the caller's copy. Deref it into the local slot
                // (rax = ptr, r10 = word scratch; neither is a param reg).
                [out appendString:pos < 4
                                      ? [NSString stringWithFormat:@"\tmov\trax, %@\n", ireg4[pos]]
                                      : [NSString stringWithFormat:@"\tmov\trax, [rbp+%lu]\n", (unsigned long)(48 + 8 * sstack)]];
                if (pos >= 4)
                    sstack++;
                if (s)
                    {
                    NSUInteger q = ([self aggSize:pv.type.layout] + 7) / 8;
                    for (NSUInteger k = 0; k < q; k++)
                        {
                        [out appendFormat:@"\tmov\tr10, [rax%+ld]\n", (long)(8 * k)];
                        [out appendFormat:@"\tmov\t[rbp-%ld], r10\n", (long)(s.integerValue - 8 * (long)k)];
                        }
                    }
                pos++;
                }
            else if (pv.type.kind == XTIRTypeKindAgg)
                {
                // ≤8-byte struct: by value in one register / stack slot.
                if (pos < 4)
                    {
                    if (s)
                        [out appendFormat:@"\tmov\t[rbp-%@], %@\n", s, ireg4[pos]];
                    }
                else if (s)
                    {
                    [out appendFormat:@"\tmov\trax, [rbp+%lu]\n", (unsigned long)(48 + 8 * sstack)];
                    [out appendFormat:@"\tmov\t[rbp-%@], rax\n", s];
                    }
                if (pos >= 4)
                    sstack++;
                pos++;
                }
            else if ([self isFloatVal:pv])
                {
                if (pos < 4)
                    {
                    if (s)
                        [out appendFormat:@"\tmov%@\t[rbp-%@], xmm%lu\n",
                                          pv.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", s, (unsigned long)pos];
                    }
                else if (s)
                    {
                    [out appendFormat:@"\tmov\trax, [rbp+%lu]\n", (unsigned long)(48 + 8 * sstack)];
                    [out appendFormat:@"\tmov\t[rbp-%@], rax\n", s];
                    }
                if (pos >= 4)
                    sstack++;
                pos++;
                }
            // int/pointer
            else
                {
                if (pos < 4)
                    {
                    if (s)
                        [out appendFormat:@"\tmov\t[rbp-%@], %@\n", s, ireg4[pos]];
                    }
                else if (s)
                    {
                    [out appendFormat:@"\tmov\trax, [rbp+%lu]\n", (unsigned long)(48 + 8 * sstack)];
                    [out appendFormat:@"\tmov\t[rbp-%@], rax\n", s];
                    }
                if (pos >= 4)
                    sstack++;
                pos++;
                }
            }
        }
    else
        {
        // Spill incoming System V args to their slots: integer/pointer from rdi,rsi,
        // rdx,rcx,r8,r9; float/double from xmm0-7 (independent counters). A hidden
        // sret consumes rdi, shifting the GP args right by one.
        NSArray<NSString*>* iregs = @[ @"rdi", @"rsi", @"rdx", @"rcx", @"r8", @"r9" ];
        NSUInteger ireg = hasSret ? 1 : 0, freg = 0, sidx = 0;
        for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
            {
            XTIRValue* pv = fn.values[@(i)];
            if (!pv || [self isMem:pv])
                continue;
            NSNumber* s = slot[@(i)];
            // struct by value → spill N int regs
            if (pv.type.kind == XTIRTypeKindAgg)
                {
                // Mirror of the caller: N = ceil(size/8) consecutive GP arg regs, one
                // 8-byte chunk each, back into the padded slot. Skip symmetrically if
                // it would overflow past r9.
                NSUInteger nregs = ([self aggSize:pv.type.layout] + 7) / 8;
                if (s && ireg + nregs <= iregs.count)
                    {
                    for (NSUInteger k = 0; k < nregs; k++)
                        {
                        [out appendFormat:@"\tmov\t[rbp-%ld], %@\n",
                                          (long)(s.integerValue - 8 * (long)k), iregs[ireg]];
                        ireg++;
                        }
                    }
                }
            else if ([self isFloatVal:pv])
                {
                if (s && freg < 8)
                    [out appendFormat:@"\tmov%@\t[rbp-%@], xmm%lu\n",
                                      pv.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", s, (unsigned long)freg];
                freg++;
                }
            else
                {
                // integer/pointer in a GP reg
                if (ireg < iregs.count)
                    {
                    if (s)
                        [out appendFormat:@"\tmov\t[rbp-%@], %@\n", s, iregs[ireg]];
                    ireg++;
                    }
                // overflow: caller passed it on the stack
                else
                    {
                    // Stack args sit above the return address: [rbp+16] is the first,
                    // then +8 each, in left-to-right param order (matches the caller's
                    // sidx). Slots are ≥8 bytes, so a full 8-byte copy never clobbers.
                    if (s)
                        {
                        [out appendFormat:@"\tmov\trax, [rbp+%lu]\n", (unsigned long)(16 + 8 * sidx)];
                        [out appendFormat:@"\tmov\t[rbp-%@], rax\n", s];
                        }
                    sidx++;
                    }
                }
            }
        }
    // Seed homed params from their just-spilled slots (the spill above always
    // wrote the slot; single-write readers use the home from here on).
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        {
        NSString* home = sHome[@(i)];
        NSNumber* s = slot[@(i)];
        if (!home || !s)
            continue;
        // A float parameter homed in an xmm needs the FP load. `mov xmm9,
        // [rbp-16]` is not an instruction — and the in-house assembler ACCEPTED
        // it rather than refusing, so logical_not_float simply read rubbish for
        // its parameters instead of failing to build.
        XTIRValue* pv = fn.values[@(i)];
        if ([self isXmmHome:home])
            [out appendFormat:@"\tmov%@\t%@, [rbp-%@]\n",
                              (pv && pv.type.kind == XTIRTypeKindF64) ? @"sd" : @"ss",
                              home, s];
        else
            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", home, s];
        }

    // Align loop heads. x86 fetches in 16-byte windows, so a hot loop whose
    // head straddles one costs throughput on every iteration — and, worse,
    // whether it straddles is decided by however much code happens to sit in
    // front of it. Regenerating the RUNTIME (which branch_mix does not even
    // call in its loop) moved that benchmark 57ms -> 79ms, a 37% swing from
    // pure layout. clang aligns these as a matter of course; we emitted no
    // alignment directive anywhere.
    //
    // A loop head is a block some LATER block branches back to.
    NSMutableSet<NSValue*>* loopHeads = [NSMutableSet set];
    for (NSUInteger bi = 0; bi < fn.blocks.count; bi++)
        {
        XTIRInsn* t = fn.blocks[bi].terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            NSUInteger hb = [fn.blocks indexOfObjectIdenticalTo:o.blockRef];
            if (hb != NSNotFound && hb <= bi)
                [loopHeads addObject:[NSValue valueWithNonretainedObject:o.blockRef]];
            }
        }

    for (XTIRBlock* bb in fn.blocks)
        {
        if ([loopHeads containsObject:[NSValue valueWithNonretainedObject:bb]])
            // THIRTY-TWO, and only because the ELF writer now puts .text on a
            // 64-byte boundary. The assembler pads relative to the START of the
            // section, so a section-relative 32-byte boundary is an absolute one
            // only when the section itself is at least that aligned; at the old
            // align-16 base every head landed at 16 mod 32, in the middle of a
            // fetch window, which is worse than the arbitrary phase align-4 gives.
            // Both halves together, measured on the x86-64 host over all nineteen
            // benchmarks: mem_copy -27%, sort_small -18%, branch_mix +12%, the
            // rest within 2%; 1.9% faster on the geometric mean. The point is as
            // much that the phase is now DETERMINISTIC — it no longer re-rolls
            // when unrelated code ahead of a hot function changes size, which had
            // produced 37% swings between byte-identical loops. private:docs/bugs/232.
            [out appendString:@"\t.p2align\t5, 0x90\n"];
        [out appendFormat:@"%@:\n", [self blockLabel:bb fn:fn]];
        for (XTIRInsn* in in bb.instructions)
            [self emitInsn:in fn:fn module:mod slot:slot out:out];
        if (bb.terminator)
            [self emitTerminator:bb.terminator fn:fn block:bb slot:slot frame:frame out:out];
        else
            {
            [self emitHomeRestore:out];
            if (frame)
                [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)frame];
            [out appendString:@"\tpop\trbp\n\tret\n"];
            }
        }
    }

// Restore callee-saved home registers before returning (rbp still valid).
+ (void)emitHomeRestore:(NSMutableString*)out
    {
    // In a STABLE order. Enumerating the dictionary walks it in Foundation's
    // hash order, so the restore sequence a function emitted depended on how
    // NSString keys happened to hash — not on the program being compiled, and
    // not matching the prologue's save order either (that walks an array).
    // Found by the self-hosted port; same class as the m68k parameter-seed leak
    // (#943) and the hash-ordered IR emission in XTIROptPointerIV.
    NSArray<NSString*>* order =
        [sHomeSaves.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* r in order)
        [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", r, sHomeSaves[r]];
    }

// Integer arg registers (64-bit / 32-bit views), in order. Win64 uses only the
// first four (rcx/rdx/r8/r9); System V uses six (rdi/rsi/rdx/rcx/r8/r9).
+ (NSArray<NSString*>*)argRegs64
    {
    return sWin64 ? @[ @"rcx", @"rdx", @"r8", @"r9" ]
                  : @[ @"rdi", @"rsi", @"rdx", @"rcx", @"r8", @"r9" ];
    }
+ (NSArray<NSString*>*)argRegs32
    {
    return sWin64 ? @[ @"ecx", @"edx", @"r8d", @"r9d" ]
                  : @[ @"edi", @"esi", @"edx", @"ecx", @"r8d", @"r9d" ];
    }
// First-argument register (runtime-helper call sites: dealloc/weak/etc.).
+ (NSString*)arg0Reg64
    {
    return sWin64 ? @"rcx" : @"rdi";
    }
+ (NSString*)arg1Reg64
    {
    return sWin64 ? @"rdx" : @"rsi";
    }

// A fixed-target runtime/libc call (memcpy, memset, _xtc_*). On Win64 the caller
// must reserve the 32-byte shadow store around it; on System V a bare call.
// Argument registers must already be loaded (this only frames the call itself).
+ (void)emitRTCall:(NSString*)target into:(NSMutableString*)out
    {
    if (sWin64)
        [out appendFormat:@"\tsub\trsp, 32\n\tcall\t%@\n\tadd\trsp, 32\n", target];
    else
        [out appendFormat:@"\tcall\t%@\n", target];
    }

// Unsigned magic-number division (Hacker's Delight §10-9), W ∈ {8,16,32}.
// x/d == (a==0) ? mulhu(x,M) >>u s : (t + ((x-t)>>u 1)) >>u (s-1), t=mulhu(x,M).
static void xtMagicU(uint64_t d, int W, uint64_t* Mout, int* aout, int* sout)
    {
    uint64_t twoWm1 = (uint64_t)1 << (W - 1);
    uint64_t maxu = ((uint64_t)1 << W) - 1;
    uint64_t twoW = (uint64_t)1 << W;
    int a = 0, p = W - 1;
    uint64_t nc = maxu - (twoW % d);
    uint64_t q1 = twoWm1 / nc, r1 = twoWm1 - q1 * nc;
    uint64_t q2 = (twoWm1 - 1) / d, r2 = (twoWm1 - 1) - q2 * d;
    uint64_t delta;
    do
        {
        p++;
        if (r1 >= nc - r1)
            {
            q1 = 2 * q1 + 1;
            r1 = 2 * r1 - nc;
            }
        else
            {
            q1 = 2 * q1;
            r1 = 2 * r1;
            }
        if (r2 + 1 >= d - r2)
            {
            if (q2 >= twoWm1 - 1)
                a = 1;
            q2 = 2 * q2 + 1;
            r2 = 2 * r2 + 1 - d;
            }
        else
            {
            if (q2 >= twoWm1)
                a = 1;
            q2 = 2 * q2;
            r2 = 2 * r2 + 1;
            }
        delta = d - 1 - r2;
        } while (p < 2 * W && (q1 < delta || (q1 == delta && r1 == 0)));
    *Mout = (q2 + 1) & maxu;
    *aout = a;
    *sout = p - W;
    }

// Signed magic-number division (Hacker's Delight §10-3), W = 32.
static void xtMagicS(int64_t dIn, int W, int64_t* Mout, int* sout)
    {
    uint64_t two_wm1 = (uint64_t)1 << (W - 1);
    uint64_t mask = ((uint64_t)1 << W) - 1;
    int64_t d = dIn;
    uint64_t ad = (uint64_t)(d < 0 ? -d : d);
    uint64_t t = two_wm1 + ((uint64_t)d >> (W - 1) & 1);
    uint64_t anc = t - 1 - t % ad;
    int p = W - 1;
    uint64_t q1 = two_wm1 / anc, r1 = two_wm1 - q1 * anc;
    uint64_t q2 = two_wm1 / ad, r2 = two_wm1 - q2 * ad;
    uint64_t delta;
    do
        {
        p++;
        q1 = 2 * q1;
        r1 = 2 * r1;
        if (r1 >= anc)
            {
            q1++;
            r1 -= anc;
            }
        q2 = 2 * q2;
        r2 = 2 * r2;
        if (r2 >= ad)
            {
            q2++;
            r2 -= ad;
            }
        delta = ad - r2;
        } while (q1 < delta || (q1 == delta && r1 == 0));
    int64_t M = (int64_t)((q2 + 1) & mask);
    if (M & (int64_t)two_wm1)
        M |= ~(int64_t)mask;
    if (d < 0)
        M = -M;
    *Mout = M;
    *sout = p - W;
    }

// The instruction defining value `vid` (linear scan; used only for the rare
// constant-divisor walk below — divisions by a constant are uncommon).
+ (XTIRInsn*)x86DefInsnFor:(XTIRValueId)vid inFn:(XTIRFunction*)fn
    {
    for (XTIRBlock* b in fn.blocks)
        for (XTIRInsn* in in b.instructions)
            if (in.result && in.result.valueId == vid)
                return in;
    return nil;
    }

// A compile-time constant divisor: a direct immediate, or a Const reached through
// the ZExt/SExt/Trunc the lowering wraps a widened literal in (`x / 7`).
+ (BOOL)x86ConstDivisor:(XTIROperand*)op fn:(XTIRFunction*)fn out:(int64_t*)outC
    {
    if (op.kind == XTIROperandKindImmI)
        {
        if (outC)
            *outC = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = op.valueId;
    for (int g = 0; g < 8; g++)
        {
        XTIRInsn* dd = [self x86DefInsnFor:cur inFn:fn];
        if (!dd || dd.operands.count < 1)
            return NO;
        if (dd.opcode == XTIROpConst && dd.operands[0].kind == XTIROperandKindImmI)
            {
            if (outC)
                *outC = dd.operands[0].intValue;
            return YES;
            }
        if ((dd.opcode == XTIROpZExt || dd.opcode == XTIROpSExt || dd.opcode == XTIROpTrunc) &&
            dd.operands[0].kind == XTIROperandKindUse)
            {
            cur = dd.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }

+ (void)emitInsn:(XTIRInsn*)in fn:(XTIRFunction*)fn module:(XTIRModule*)mod
            slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
             out:(NSMutableString*)out
    {
    XTIROpcode op = in.opcode;
    XTIRValue* res = in.result;
    NSArray<XTIROperand*>* ops = in.operands;

    switch (op)
        {
    case XTIROpAddrOf:
        {
        // Symbol (string literal / global) → RIP-relative lea; a Use of a
        // pinned local → its frame slot address. The low 4 bytes (eax) is the
        // real address in a low-4GB static ELF, stored at the pointer IR width.
        if (!res || ops.count < 1)
            return;
        if (ops[0].kind == XTIROperandKindSym)
            {
            XTIRSymbol* sym = [mod symbolForId:ops[0].symbolId];
            // A function with no body in this module — a prototype, or a
            // method of a class imported from another library (Base$dealloc
            // for `new Base[N]`) — is imported too. A static link relaxes the
            // GOT load back to the lea when the image defines the symbol.
            BOOL imported = sym.isExternalGlobal;
            if (!imported && sym.kind == XTIRSymbolKindFunction)
                {
                imported = YES;
                for (XTIRFunction* f in mod.functions)
                    if ([f.name isEqualToString:sym.name]) { imported = NO; break; }
                }
            if (imported && !sWin64)
                {
                // Imported from another .so (e.g. an imported class's vtable): its
                // address isn't fixed at static-link time, so load it FROM the GOT
                // (SysV/ELF) rather than form a direct RIP-relative address. (win64
                // PE uses IAT/__imp_ indirection — not wired for cross-module class
                // casts yet; it keeps the plain lea.)
                [out appendFormat:@"\tmov\trax, [rip+%@@GOTPCREL]\n", [self safeSym:sym.name] ?: @"0"];
                }
            else
                {
                // PARENTHESISE the symbol. In Intel syntax a bare name inside a
                // memory operand is resolved against the register/keyword table
                // FIRST, so a user global called `flags` (or es/cs/st/eflags/…)
                // parses as a register and the assembler rejects the whole
                // operand ("invalid base+index expression"). `[rip + (sym)]`
                // forces it to be read as an expression. (Found via the `sieve`
                // fixture, whose sieve array is named `flags` — it failed to
                // assemble at all on x86_64.)
                [out appendFormat:@"\tlea\trax, [rip+%@]\n", [self safeSym:sym.name] ?: @"0"];
                }
            }
        else if (ops[0].kind == XTIROperandKindUse)
            {
            NSNumber* s = slot[@(ops[0].valueId)];
            if (s)
                [out appendFormat:@"\tlea\trax, [rbp-%@]\n", s];
            else
                [out appendString:@"\txor\teax, eax\n"];
            }
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpElementAddr:
        {
        // addr = base + index * stride; stride = base pointee NATIVE width (a
        // pointer element is 8 bytes, not the FE layout's 2/4).
        if (!res || ops.count < 2)
            return;
        if (sFold[@(res.valueId)])
            return; // folded into its Load below
        XTIRValue* base = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        NSUInteger stride = (base && base.type.pointeeType) ? [self fieldWidth:base.type.pointeeType] : 1;
        if (stride == 0)
            stride = 1;
        // A CONSTANT index folds into the displacement, and a HOMED base is
        // already in a register, so `p + 4` is one lea. It used to be four
        // instructions —
        //     mov rax, <base> ; mov rcx, 4 ; lea rax, [rax+rcx*4] ; mov <dst>, rax
        // — and mem_copy's vectorised body was mostly that: eight instructions
        // of addressing for four of work, twice per unrolled copy.
        NSString* rh = res ? sHome[@(res.valueId)] : nil;
        if (rh && [self isXmmHome:rh])
            rh = nil; // an address never lives in an xmm
        NSString* dst = rh ?: @"rax";
        NSString* bh = (ops[0].kind == XTIROperandKindUse) ? sHome[@(ops[0].valueId)] : nil;
        if (bh && [self isXmmHome:bh])
            bh = nil;
        NSString* bReg = bh;
        if (!bReg)
            {
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = base
            bReg = @"rax";
            }
        if (ops[1].kind == XTIROperandKindImmI)
            {
            long long disp = (long long)ops[1].intValue * (long long)stride;
            if (disp == 0)
                {
                if (![dst isEqualToString:bReg])
                    [out appendFormat:@"\tmov\t%@, %@\n", dst, bReg];
                }
            else
                [out appendFormat:@"\tlea\t%@, [%@%+lld]\n", dst, bReg, disp];
            }
        else
            {
            // rcx is emission scratch and never a home, so loading the index
            // into it cannot disturb a homed base.
            [self loadIndex:ops[1] into:'c' fn:fn slot:slot out:out];
            if (stride == 1 || stride == 2 || stride == 4 || stride == 8)
                [out appendFormat:@"\tlea\t%@, [%@ + rcx*%lu]\n", dst, bReg, (unsigned long)stride];
            else
                {
                [out appendFormat:@"\timul\trcx, rcx, %lu\n", (unsigned long)stride];
                [out appendFormat:@"\tlea\t%@, [%@ + rcx]\n", dst, bReg];
                }
            }
        if (!rh)
            [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpFieldAddr:
        {
        // addr = base + field offset (struct member).
        if (!res || ops.count < 2)
            return;
        if (sFold[@(res.valueId)])
            return; // folded into its Load below
        XTIRValue* base = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        XTIRType* pte = base ? base.type.pointeeType : nil;
        NSUInteger off = 0;
        if (pte && pte.kind == XTIRTypeKindAgg && pte.layout && ops[1].kind == XTIROperandKindImmI)
            {
            NSUInteger idx = (NSUInteger)ops[1].intValue;
            if (idx < pte.layout.fields.count)
                off = [self fieldOffset:pte.layout index:idx]; // native 8-byte ptrs
            }
        // Same as ElementAddr: a homed base needs no load, and the offset is a
        // displacement rather than a separate add.
        NSString* rh = res ? sHome[@(res.valueId)] : nil;
        if (rh && [self isXmmHome:rh])
            rh = nil;
        NSString* dst = rh ?: @"rax";
        NSString* bh = (ops[0].kind == XTIROperandKindUse) ? sHome[@(ops[0].valueId)] : nil;
        if (bh && [self isXmmHome:bh])
            bh = nil;
        NSString* bReg = bh;
        if (!bReg)
            {
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
            bReg = @"rax";
            }
        if (off)
            [out appendFormat:@"\tlea\t%@, [%@+%lu]\n", dst, bReg, (unsigned long)off];
        else if (![dst isEqualToString:bReg])
            [out appendFormat:@"\tmov\t%@, %@\n", dst, bReg];
        if (!rh)
            [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpRetain:
        {
        // refcount (u32 @ obj-4) += 1, skipping null/sentinels/non-heap
        // (anything < 0x10000 — a real heap object is far above that).
        if (ops.count < 1)
            return;
        NSUInteger n = sArcLabel++;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendFormat:@"\tcmp\trax, 0x10000\n\tjb\t.L_arc_%lu\n", (unsigned long)n];
        // Zero means "already dying" — see the arm64 back end. Retaining an
        // object whose dealloc is running relaunches dealloc (bug 038).
        [out appendString:@"\tcmp\tdword ptr [rax-4], 0\n"];
        [out appendFormat:@"\tje\t.L_arc_%lu\n", (unsigned long)n];
        // Threading: `lock` makes the read-modify-write indivisible, which
        // a plain `add word ptr [mem], 1` is NOT — two threads retaining
        // one object lose an increment and free it while it is still held.
        [out appendString:sX86ThreadSafeARC
                              ? @"\tlock add\tdword ptr [rax-4], 1\n"
                              : @"\tadd\tdword ptr [rax-4], 1\n"];
        [out appendFormat:@".L_arc_%lu:\n", (unsigned long)n];
        return;
        }
    case XTIROpRelease:
    case XTIROpAutorelease:
        {
        // refcount-- ; free via _xtc_dealloc(obj) when it hits 0.
        if (ops.count < 1)
            return;
        NSUInteger n = sArcLabel++;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendFormat:@"\tcmp\trax, 0x10000\n\tjb\t.L_arc_%lu\n", (unsigned long)n];
        if (sX86ThreadSafeARC)
            {
            // XADD returns the PREVIOUS value in the source register, so
            // "I took the last reference" is old == 1 — decided from this
            // thread's own exchange, not from a re-read two threads could
            // both see as zero. cx = -1 makes the exchange a decrement.
            [out appendString:@"\tmov\tecx, -1\n"];
            [out appendString:@"\tlock xadd\tdword ptr [rax-4], ecx\n"];
            [out appendString:@"\tcmp\tecx, 1\n"];
            [out appendFormat:@"\tjne\t.L_arc_%lu\n", (unsigned long)n];
            }
        else
            {
            [out appendString:@"\tsub\tdword ptr [rax-4], 1\n"];
            [out appendFormat:@"\tjnz\t.L_arc_%lu\n", (unsigned long)n];
            }
        [out appendFormat:@"\tmov\t%@, rax\n", [self arg0Reg64]];
        [self emitRTCall:@"_xtc_dealloc" into:out];
        [out appendFormat:@".L_arc_%lu:\n", (unsigned long)n];
        return;
        }
    // [slotAddr, obj, mem] → _xtc_weak_register
    case XTIROpWeakRegister:
        {
        if (ops.count < 2)
            return;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [self loadZX:ops[1] into:'c' fn:fn slot:slot out:out];
        // arg0 ← rax, arg1 ← rcx. On Win64 arg1 is rdx and arg0 is rcx, so
        // move arg1 FIRST (rcx→rdx) before arg0 clobbers rcx (rax→rcx).
        [out appendFormat:@"\tmov\t%@, rcx\n\tmov\t%@, rax\n", [self arg1Reg64], [self arg0Reg64]];
        [self emitRTCall:@"_xtc_weak_register" into:out];
        return;
        }
    // [slotAddr, mem] → _xtc_weak_unregister
    case XTIROpWeakUnregister:
        {
        if (ops.count < 1)
            return;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendFormat:@"\tmov\t%@, rax\n", [self arg0Reg64]];
        [self emitRTCall:@"_xtc_weak_unregister" into:out];
        return;
        }
    // [slotAddr, mem] → result (nil if pointee dead)
    case XTIROpWeakLoad:
        {
        if (!res || ops.count < 1)
            return;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendFormat:@"\tmov\t%@, rax\n", [self arg0Reg64]];
        [self emitRTCall:@"_xtc_weak_load" into:out];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpAggBuild:
        {
        // Assemble an aggregate (multi-return tuple / by-value struct) from its
        // field operands: store each into the result slot at its native offset.
        if (!res || !res.type || res.type.kind != XTIRTypeKindAgg || !res.type.layout)
            return;
        NSNumber* s = slot[@(res.valueId)];
        if (!s)
            return;
        NSInteger baseOff = s.integerValue;
        XTIRLayout* layout = res.type.layout;
        for (NSUInteger i = 0; i < ops.count && i < layout.fields.count; i++)
            {
            NSUInteger fw = [self fieldWidth:layout.fields[i].type];
            if (fw == 0)
                fw = 8;
            if (fw > 8)
                fw = 8;
            NSInteger addr = baseOff - (NSInteger)[self fieldOffset:layout index:i];
            [self loadZX:ops[i] into:'a' fn:fn slot:slot out:out];
            [out appendFormat:@"\tmov\t[rbp-%ld], %@\n", (long)addr, [self reg:'a' width:fw]];
            }
        return;
        }
    case XTIROpAggExtract:
        {
        // Extract field `index` from an aggregate — read it at the native offset.
        if (!res || ops.count < 2 || ops[1].kind != XTIROperandKindImmI)
            return;
        XTIRValue* aggV = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        NSNumber* as = ops[0].kind == XTIROperandKindUse ? slot[@(ops[0].valueId)] : nil;
        if (!aggV || !aggV.type.layout || !as)
            return;
        NSInteger addr = as.integerValue - (NSInteger)[self fieldOffset:aggV.type.layout index:(NSUInteger)ops[1].intValue];
        NSUInteger rw = [self widthOf:res];
        [out appendFormat:@"\tmov\t%@, [rbp-%ld]\n", [self reg:'a' width:rw], (long)addr];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpLoad:
        {
        // [addr, memInput] → result. Deref through the (zero-extended) pointer.
        if (!res || ops.count < 1)
            return;
        XTIRInsn* fea = sFold[@(ops[0].valueId)];
        // folded addr → memory operand
        if (fea && res.type.kind != XTIRTypeKindAgg)
            {
            NSString* memop = [self foldedMemOp:fea fn:fn slot:slot out:out]; // base→rax, idx→rcx
            // A FLOAT loads straight into an xmm. It used to go through a
            // general register and then `movd`/`movq` across — two instructions
            // and a domain crossing for what movss/movsd does in one.
            if ([self isFloatVal:res])
                {
                NSString* Df = [self fdstFor:res clobbering:nil as:nil];
                [out appendFormat:@"\tmov%@\t%@, %@\n",
                                  res.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", Df, memop];
                [self storeF:Df into:res slot:slot out:out];
                return;
                }
            NSUInteger w = [self widthOf:res];
            [out appendFormat:@"\tmov\t%@, %@\n", [self reg:'d' width:w], memop];
            [self store:'d' into:res slot:slot out:out];
            return;
            }
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = address
        // whole-struct copy
        if (res.type.kind == XTIRTypeKindAgg)
            {
            NSNumber* ds = slot[@(res.valueId)];
            if (ds)
                [self copyAgg:[self aggSize:res.type.layout]
                          ptr:@"rax"
                         slot:ds.integerValue
                       toSlot:YES
                          out:out];
            return;
            }
        if ([self isFloatVal:res])
            {
            NSString* Df = [self fdstFor:res clobbering:nil as:nil];
            [out appendFormat:@"\tmov%@\t%@, [rax]\n",
                              res.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", Df];
            [self storeF:Df into:res slot:slot out:out];
            return;
            }
        NSUInteger w = [self widthOf:res];
        [out appendFormat:@"\tmov\t%@, [rax]\n", [self reg:'c' width:w]];
        [self store:'c' into:res slot:slot out:out];
        return;
        }
    case XTIROpStore:
        {
        // [addr, value, memInput]. Write value through the pointer.
        if (ops.count < 2)
            return;
        XTIRInsn* sea = sFold[@(ops[0].valueId)];
        // folded addr → dest memory operand
        if (sea)
            {
            XTIRValue* vv2 = ops[1].kind == XTIROperandKindUse ? fn.values[@(ops[1].valueId)] : nil;
            if (!(vv2 && vv2.type.kind == XTIRTypeKindAgg))
                {
                NSUInteger w = vv2 ? [self widthOf:vv2] : 4;
                // A FLOAT goes straight out of an xmm. Its source register is
                // chosen BEFORE the address is computed, for the same reason
                // rdx is loaded first below — though an xmm could not be
                // clobbered by foldedMemOp's rax/rcx in any case.
                if (vv2 && [self isFloatVal:vv2])
                    {
                    NSString* Sf = [self fsrcForStore:ops[1] fn:fn slot:slot out:out];
                    NSString* memop = [self foldedMemOp:sea fn:fn slot:slot out:out];
                    [out appendFormat:@"\tmov%@\t%@, %@\n",
                                      vv2.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", memop, Sf];
                    return;
                    }
                // Value → rdx FIRST (rdx is never a home reg nor foldedMemOp's
                // rax/rcx scratch, so the address computation can't clobber it).
                [self load:ops[1] into:'d' fn:fn slot:slot out:out];
                NSString* memop = [self foldedMemOp:sea fn:fn slot:slot out:out]; // base→rax/home, idx→rcx
                [out appendFormat:@"\tmov\t%@, %@\n", memop, [self reg:'d' width:w]];
                return;
                }
            }
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = address
        XTIRValue* vv = ops[1].kind == XTIROperandKindUse ? fn.values[@(ops[1].valueId)] : nil;
        // whole-struct copy
        if (vv && vv.type.kind == XTIRTypeKindAgg)
            {
            NSNumber* vs = slot[@(ops[1].valueId)];
            if (vs)
                [self copyAgg:[self aggSize:vv.type.layout]
                          ptr:@"rax"
                         slot:vs.integerValue
                       toSlot:NO
                          out:out];
            return;
            }
        if (vv && [self isFloatVal:vv])
            {
            NSString* Sf = [self fsrcForStore:ops[1] fn:fn slot:slot out:out];
            [out appendFormat:@"\tmov%@\t[rax], %@\n",
                              vv.type.kind == XTIRTypeKindF64 ? @"sd" : @"ss", Sf];
            return;
            }
        NSUInteger w = vv ? [self widthOf:vv] : 4;
        [self load:ops[1] into:'c' fn:fn slot:slot out:out]; // rcx = value
        [out appendFormat:@"\tmov\t[rax], %@\n", [self reg:'c' width:w]];
        return;
        }
    case XTIROpCall:
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
    case XTIROpCallIndirect:
    case XTIROpCallBankedIndirect:
        {
        // Direct: operands [callee(Sym), arg0, …, mem]. Indirect: operands[0] is
        // a fn-pointer Use, not a Sym. Integer/pointer args fill rdi..r9 (System
        // V); banked/cloaked are 6502 concepts — plain calls on native x86-64.
        BOOL indirect = (op == XTIROpCallIndirect || op == XTIROpCallBankedIndirect);
        if (ops.count < 1 || (!indirect && ops[0].kind != XTIROperandKindSym))
            return;
        XTIRSymbol* callee = indirect ? nil : [mod symbolForId:ops[0].symbolId];
        NSUInteger argEnd = ops.count;
        if (argEnd > 1 && ops[argEnd - 1].kind == XTIROperandKindUse)
            {
            XTIRValue* lv = fn.values[@(ops[argEnd - 1].valueId)];
            if (lv && [self isMem:lv])
                argEnd--; // drop the mem token
            }
        if (sWin64)
            {
            // Win64: caller reserves a 32-byte shadow store, room for stack args
            // (positions ≥4), and a copy area for any >8-byte struct passed BY
            // REFERENCE. A single POSITIONAL counter spans int and float; each arg
            // — scalar or struct — takes exactly one slot. A >8-byte struct RESULT
            // uses a hidden sret pointer in rcx, shifting real args right by one.
            BOOL bigRet = (res && [self isBigAgg:res.type]);
            NSUInteger cpos = bigRet ? 1 : 0, wstack = 0, copyBytes = 0;
            for (NSUInteger i = 1; i < argEnd; i++)
                {
                XTIROperand* a = ops[i];
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                if (v && [self isBigAgg:v.type])
                    copyBytes += ([self aggSize:v.type.layout] + 15) & ~(NSUInteger)15;
                if (cpos >= 4)
                    wstack++;
                cpos++;
                }
            NSUInteger copyBase = 32 + wstack * 8; // copies above shadow + stack args
            NSUInteger resv = ((copyBase + copyBytes) + 15) & ~(NSUInteger)15;
            [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)resv];

            NSUInteger pos = bigRet ? 1 : 0, sstack = 0, copyOff = copyBase;
            for (NSUInteger i = 1; i < argEnd; i++)
                {
                XTIROperand* a = ops[i];
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                // >8-byte struct → by reference
                if (v && [self isBigAgg:v.type])
                    {
                    NSNumber* s = slot[@(a.valueId)];
                    NSUInteger sz = [self aggSize:v.type.layout];
                    if (s)
                        [self copyQwords:sz
                                 fromReg:@"rbp"
                                    disp:-(long)s.integerValue
                                   toReg:@"rsp"
                                    disp:(long)copyOff
                                    into:out];
                    if (pos < 4)
                        {
                        [out appendFormat:@"\tlea\t%@, [rsp+%lu]\n", [self argRegs64][pos], (unsigned long)copyOff];
                        }
                    else
                        {
                        [out appendFormat:@"\tlea\trax, [rsp+%lu]\n", (unsigned long)copyOff];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    copyOff += (sz + 15) & ~(NSUInteger)15;
                    pos++;
                    }
                // ≤8-byte struct → by value
                else if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    NSNumber* s = slot[@(a.valueId)];
                    if (pos < 4)
                        {
                        if (s)
                            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", [self argRegs64][pos], s];
                        }
                    else if (s)
                        {
                        [out appendFormat:@"\tmov\trax, [rbp-%@]\n", s];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    pos++;
                    }
                else if ([self isFloatVal:v])
                    {
                    if (pos < 4)
                        {
                        [self loadF:a
                               into:[NSString stringWithFormat:@"xmm%lu", (unsigned long)pos]
                                 fn:fn
                               slot:slot
                                out:out];
                        }
                    else
                        {
                        [self loadZX:a into:'a' fn:fn slot:slot out:out];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    pos++;
                    }
                // int/pointer in a reg
                else if (pos < 4)
                    {
                    [self readArgOp:a into64:[self argRegs64][pos] into32:[self argRegs32][pos] fn:fn slot:slot out:out];
                    pos++;
                    }
                // int/pointer → stack (above shadow)
                else
                    {
                    [self loadZX:a into:'a' fn:fn slot:slot out:out];
                    [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                    sstack++;
                    pos++;
                    }
                }
            // load the fn pointer → r11
            if (indirect)
                {
                [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
                [out appendString:@"\tmov\tr11, rax\n"];
                }
            // hidden sret → rcx = &result slot
            if (bigRet)
                {
                NSNumber* rs = slot[@(res.valueId)];
                if (rs)
                    [out appendFormat:@"\tlea\trcx, [rbp-%@]\n", rs];
                }
            if (indirect)
                [out appendString:@"\tcall\tr11\n"];
            else
                [out appendFormat:@"\tcall\t%@\n", callee.name ?: @"0"];
            [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)resv];
            // result already written through sret into its slot
            if (bigRet)
                {
                return;
                }
            }
        else
            {
            // Pre-pass: System V passes integer/pointer args past r9 on the stack.
            // Size that outgoing area so a single `sub rsp` reserves it (kept
            // 16-aligned). Struct/float overflow past their register files is
            // unsupported (rare), so only integer stack args are counted.
            // A >16-byte aggregate RESULT is MEMORY class: rdi carries a hidden
            // pointer to the result slot, shifting the GP args right by one.
            BOOL memRet = (res && [self isSysVMemRet:res.type]);
            NSUInteger cIreg = memRet ? 1 : 0, cFreg = 0, nstack = 0;
            for (NSUInteger i = 1; i < argEnd; i++)
                {
                XTIROperand* a = ops[i];
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    NSUInteger nr = ([self aggSize:v.type.layout] + 7) / 8;
                    if (cIreg + nr <= 6)
                        cIreg += nr;
                    }
                else if (v && [self isFloatVal:v] && cFreg < 8)
                    {
                    cFreg++;
                    }
                else if (cIreg < 6)
                    {
                    cIreg++;
                    }
                else
                    {
                    nstack++;
                    }
                }
            NSUInteger resv = ((nstack * 8) + 15) & ~(NSUInteger)15; // 16-align
            if (resv)
                [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)resv];

            NSUInteger ireg = memRet ? 1 : 0, freg = 0, sidx = 0;
            for (NSUInteger i = 1; i < argEnd; i++)
                {
                XTIROperand* a = ops[i];
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                // struct by value → N int regs
                if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    // Private xtc ABI (matches XTArm64Backend): a by-value struct
                    // occupies N = ceil(size/8) consecutive GP arg registers, one
                    // per 8-byte chunk; the callee spills them back into its slot.
                    // (Slots are padded to a multiple of 8 by slotSizeOf, so the
                    // tail chunk's over-read stays in-slot.) Overflow past r9 is
                    // unsupported — skip symmetrically with the prologue.
                    NSNumber* s = slot[@(a.valueId)];
                    NSUInteger nregs = ([self aggSize:v.type.layout] + 7) / 8;
                    if (s && ireg + nregs <= 6)
                        {
                        for (NSUInteger k = 0; k < nregs; k++)
                            {
                            [out appendFormat:@"\tmov\t%@, [rbp-%ld]\n", [self argRegs64][ireg],
                                              (long)(s.integerValue - 8 * (long)k)];
                            ireg++;
                            }
                        }
                    }
                // float arg → xmm
                else if (v && [self isFloatVal:v] && freg < 8)
                    {
                    [self loadF:a
                           into:[NSString stringWithFormat:@"xmm%lu", (unsigned long)freg]
                             fn:fn
                           slot:slot
                            out:out];
                    freg++;
                    }
                // int/pointer arg
                else if (ireg < 6)
                    {
                    [self readArgOp:a into64:[self argRegs64][ireg] into32:[self argRegs32][ireg] fn:fn slot:slot out:out];
                    ireg++;
                    }
                // int/pointer → stack
                else
                    {
                    // Materialise (zero-extended) through rax and store into the
                    // reserved area: [rsp+0], [rsp+8], … in source order. rax is
                    // free scratch here — it's reloaded as al=#vector-args below.
                    [self loadZX:a into:'a' fn:fn slot:slot out:out];
                    [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(8 * sidx)];
                    sidx++;
                    }
                }
            // load the fn pointer → r11
            if (indirect)
                {
                [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
                [out appendString:@"\tmov\tr11, rax\n"];
                }
            // hidden sret → rdi = &result slot
            if (memRet)
                {
                NSNumber* rs = slot[@(res.valueId)];
                if (rs)
                    [out appendFormat:@"\tlea\trdi, [rbp-%@]\n", rs];
                }
            [out appendFormat:@"\tmov\teax, %lu\n", (unsigned long)freg]; // al = # vector args (variadic ABI)
            if (indirect)
                [out appendString:@"\tcall\tr11\n"];
            else
                [out appendFormat:@"\tcall\t%@\n", callee.name ?: @"0"];
            if (resv)
                [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)resv]; // reclaim stack args
            // result already written through sret into its slot
            if (memRet)
                {
                return;
                }
            }
        if (res && ![self isMem:res])
            {
            if (res.type.kind == XTIRTypeKindAgg)
                [self aggFromRetRegs:res slot:slot out:out]; // struct in rax:rdx
            else if ([self isFloatVal:res])
                [self storeF:@"xmm0" into:res slot:slot out:out];
            else
                [self store:'a' into:res slot:slot out:out];
            }
        return;
        }
    case XTIROpVTblDispatch:
        {
        // Operands: [receiver, ImmI(slot), arg0…, mem]. Callee = the receiver's
        // vtable[slot]: [recv] → vtable ptr, [vtbl + slot*8] → fn ptr. Marshal
        // receiver+args (System V), then indirect-call through r11.
        if (ops.count < 2 || ops[1].kind != XTIROperandKindImmI)
            return;
        NSMutableArray<XTIROperand*>* args = [NSMutableArray arrayWithObject:ops[0]];
        NSUInteger argEnd = ops.count;
        if (argEnd > 2 && ops[argEnd - 1].kind == XTIROperandKindUse)
            {
            XTIRValue* lv = fn.values[@(ops[argEnd - 1].valueId)];
            if (lv && [self isMem:lv])
                argEnd--;
            }
        for (NSUInteger i = 2; i < argEnd; i++)
            [args addObject:ops[i]];
        NSUInteger vShadow = 0, vFreg = 0; // Win64 stack reserve / SysV vector-arg count
        BOOL vBigRet = sWin64 && res && [self isBigAgg:res.type];
        BOOL vMemRet = (res && [self isSysVMemRet:res.type]); // SysV >16B: rdi sret
        if (sWin64)
            {
            // Win64: 32-byte shadow store + positional rcx/rdx/r8/r9 (shared with
            // xmm0-3), stack args above the shadow, >8-byte structs by reference,
            // and a hidden sret in rcx for a >8-byte struct result. Same rules as a
            // plain Call — VTblDispatch just computes the callee from the vtable.
            NSUInteger cpos = vBigRet ? 1 : 0, wstack = 0, copyBytes = 0;
            for (XTIROperand* a in args)
                {
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                if (v && [self isBigAgg:v.type])
                    copyBytes += ([self aggSize:v.type.layout] + 15) & ~(NSUInteger)15;
                if (cpos >= 4)
                    wstack++;
                cpos++;
                }
            NSUInteger copyBase = 32 + wstack * 8;
            vShadow = ((copyBase + copyBytes) + 15) & ~(NSUInteger)15;
            [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)vShadow];
            NSUInteger pos = vBigRet ? 1 : 0, sstack = 0, copyOff = copyBase;
            for (XTIROperand* a in args)
                {
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                // >8-byte struct → by reference
                if (v && [self isBigAgg:v.type])
                    {
                    NSNumber* sv = slot[@(a.valueId)];
                    NSUInteger sz = [self aggSize:v.type.layout];
                    if (sv)
                        [self copyQwords:sz
                                 fromReg:@"rbp"
                                    disp:-(long)sv.integerValue
                                   toReg:@"rsp"
                                    disp:(long)copyOff
                                    into:out];
                    if (pos < 4)
                        {
                        [out appendFormat:@"\tlea\t%@, [rsp+%lu]\n", [self argRegs64][pos], (unsigned long)copyOff];
                        }
                    else
                        {
                        [out appendFormat:@"\tlea\trax, [rsp+%lu]\n", (unsigned long)copyOff];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    copyOff += (sz + 15) & ~(NSUInteger)15;
                    pos++;
                    }
                // ≤8-byte struct → by value
                else if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    NSNumber* sv = slot[@(a.valueId)];
                    if (pos < 4)
                        {
                        if (sv)
                            [out appendFormat:@"\tmov\t%@, [rbp-%@]\n", [self argRegs64][pos], sv];
                        }
                    else if (sv)
                        {
                        [out appendFormat:@"\tmov\trax, [rbp-%@]\n", sv];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    pos++;
                    }
                else if ([self isFloatVal:v])
                    {
                    if (pos < 4)
                        [self loadF:a
                               into:[NSString stringWithFormat:@"xmm%lu", (unsigned long)pos]
                                 fn:fn
                               slot:slot
                                out:out];
                    else
                        {
                        [self loadZX:a into:'a' fn:fn slot:slot out:out];
                        [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                        sstack++;
                        }
                    pos++;
                    }
                else if (pos < 4)
                    {
                    [self readArgOp:a into64:[self argRegs64][pos] into32:[self argRegs32][pos] fn:fn slot:slot out:out];
                    pos++;
                    }
                else
                    {
                    [self loadZX:a into:'a' fn:fn slot:slot out:out];
                    [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(32 + 8 * sstack)];
                    sstack++;
                    pos++;
                    }
                }
            }
        else
            {
            // A >16-byte aggregate result is MEMORY class: rdi carries the hidden
            // result pointer, so the receiver and every GP arg shift right by one
            // (the callee prologue shifts identically off hasSret).
            // uxkit/033: System V passes integer/pointer arguments past r9 on the
            // STACK, and this path used to marshal only what fitted in registers
            // — every argument from the 7th on (self included) was silently
            // dropped, along with the `sub rsp` that reserves room for them. The
            // callee then read its own caller's leftovers: `structAbsFrame(h, i,
            // x, y, w, ht)` is exactly seven with self, so it read a stale word
            // as `ht` and wrote through it.
            //
            // Only the INDIRECT path was wrong; the direct-call path above has
            // always reserved and stored. That is why it hid so long: a
            // class-typed call devirtualises to a direct Call, and at -O2+ the
            // inliner removes it outright. It needs a protocol receiver, seven
            // arguments and a real dispatch to show at all.
            //
            // Same pre-pass as the direct path, so the two agree by construction.
            NSUInteger cIreg = vMemRet ? 1 : 0, cFreg = 0, nstack = 0;
            for (XTIROperand* a in args)
                {
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    NSUInteger nr = ([self aggSize:v.type.layout] + 7) / 8;
                    if (cIreg + nr <= 6)
                        cIreg += nr;
                    }
                else if (v && [self isFloatVal:v] && cFreg < 8)
                    {
                    cFreg++;
                    }
                else if (cIreg < 6)
                    {
                    cIreg++;
                    }
                else
                    {
                    nstack++;
                    }
                }
            NSUInteger vResv = ((nstack * 8) + 15) & ~(NSUInteger)15; // 16-align
            if (vResv)
                [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)vResv];
            vShadow = vResv; // reclaimed after the call

            NSUInteger ireg = vMemRet ? 1 : 0, freg = 0, sidx = 0;
            for (XTIROperand* a in args)
                {
                XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
                // struct/^ by value → N GP regs
                if (v && v.type.kind == XTIRTypeKindAgg)
                    {
                    // A by-value aggregate — including a 2-word bound-method `^`
                    // (recv, code) — occupies N = ceil(size/8) consecutive GP arg
                    // registers, the same private xtc ABI the plain Call path
                    // (above) and the callee prologue use. This loop USED to load a
                    // single register per arg, which truncated a 16-byte `^` to its
                    // receiver word and dropped the code word — the cross-`.so`
                    // bug, since an imported method is always vtable-dispatched
                    // (a local call devirtualises to a direct Call and was fine).
                    NSNumber* s = slot[@(a.valueId)];
                    NSUInteger nregs = ([self aggSize:v.type.layout] + 7) / 8;
                    if (s && ireg + nregs <= 6)
                        {
                        for (NSUInteger k = 0; k < nregs; k++)
                            {
                            [out appendFormat:@"\tmov\t%@, [rbp-%ld]\n", [self argRegs64][ireg],
                                              (long)(s.integerValue - 8 * (long)k)];
                            ireg++;
                            }
                        }
                    }
                else if (v && [self isFloatVal:v] && freg < 8)
                    {
                    [self loadF:a
                           into:[NSString stringWithFormat:@"xmm%lu", (unsigned long)freg]
                             fn:fn
                           slot:slot
                            out:out];
                    freg++;
                    }
                else if (ireg < 6)
                    {
                    [self readArgOp:a into64:[self argRegs64][ireg] into32:[self argRegs32][ireg] fn:fn slot:slot out:out];
                    ireg++;
                    }
                // int/pointer → stack
                else
                    {
                    // Through rax into the reserved area — [rsp+0], [rsp+8], … in
                    // source order — exactly as the direct path does. rax is free
                    // scratch: it is reloaded with the receiver below.
                    [self loadZX:a into:'a' fn:fn slot:slot out:out];
                    [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(8 * sidx)];
                    sidx++;
                    }
                }
            vFreg = freg;
            }
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];                              // rax = receiver
        [out appendString:@"\tmov\tr11, [rax]\n"];                                          // vtable ptr @ object+0
        [out appendFormat:@"\tmov\tr11, [r11 + %lld]\n", (long long)(ops[1].intValue * 8)]; // fn ptr
        if (!sWin64)
            [out appendFormat:@"\tmov\teax, %lu\n", (unsigned long)vFreg]; // al = # vector args (SysV variadic)
        // hidden sret → rcx = &result slot
        if (vBigRet)
            {
            NSNumber* rs = slot[@(res.valueId)];
            if (rs)
                [out appendFormat:@"\tlea\trcx, [rbp-%@]\n", rs];
            }
        // hidden sret → rdi = &result slot
        if (vMemRet)
            {
            NSNumber* rs = slot[@(res.valueId)];
            if (rs)
                [out appendFormat:@"\tlea\trdi, [rbp-%@]\n", rs];
            }
        [out appendString:@"\tcall\tr11\n"];
        // Reclaim: Win64's shadow+stack area, or SysV's outgoing stack args
        // (uxkit/033 — this path used to reserve neither).
        if (vShadow)
            [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)vShadow];
        if (vBigRet || vMemRet)
            return; // result already written through sret into its slot
        if (res && ![self isMem:res])
            {
            if (res.type.kind == XTIRTypeKindAgg)
                [self aggFromRetRegs:res slot:slot out:out]; // ≤8/≤16 in regs
            else if ([self isFloatVal:res])
                [self storeF:@"xmm0" into:res slot:slot out:out];
            else
                [self store:'a' into:res slot:slot out:out];
            }
        return;
        }
    case XTIROpProtoDispatch:
        {
        // Protocol dispatch through the per-class ITABLE (bug 201). Operands:
        // [receiver, ImmI protoId, ImmI methodIndex, args…, mem]. The itable
        // (vtable header entry 1 = a (protoId,&table) list, 0-terminated) is
        // laid out unit-independently — a method's INDEX depends only on the
        // protocol's own declaration — so a split build in which each object
        // numbers its vtables from source still agrees. Marshalling is the
        // SysV VTblDispatch path verbatim; only the callee resolution differs
        // (an inline itable walk instead of a fixed vtable slot). Mirror of
        // the self-hosted emitProtoDispatchX86.
        if (ops.count < 3 || ops[1].kind != XTIROperandKindImmI || ops[2].kind != XTIROperandKindImmI)
            return;
        if (sWin64)
            return; // itable dispatch is x86_64/linux only
        NSMutableArray<XTIROperand*>* args = [NSMutableArray arrayWithObject:ops[0]];
        NSUInteger argEnd = ops.count;
        if (argEnd > 3 && ops[argEnd - 1].kind == XTIROperandKindUse)
            {
            XTIRValue* lv = fn.values[@(ops[argEnd - 1].valueId)];
            if (lv && [self isMem:lv])
                argEnd--;
            }
        for (NSUInteger i = 3; i < argEnd; i++)
            [args addObject:ops[i]];
        NSUInteger vFreg = 0;
        BOOL vMemRet = (res && [self isSysVMemRet:res.type]);
        NSUInteger cIreg = vMemRet ? 1 : 0, cFreg = 0, nstack = 0;
        for (XTIROperand* a in args)
            {
            XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
            if (v && v.type.kind == XTIRTypeKindAgg)
                {
                NSUInteger nr = ([self aggSize:v.type.layout] + 7) / 8;
                if (cIreg + nr <= 6)
                    cIreg += nr;
                }
            else if (v && [self isFloatVal:v] && cFreg < 8)
                {
                cFreg++;
                }
            else if (cIreg < 6)
                {
                cIreg++;
                }
            else
                {
                nstack++;
                }
            }
        NSUInteger vResv = ((nstack * 8) + 15) & ~(NSUInteger)15;
        if (vResv)
            [out appendFormat:@"\tsub\trsp, %lu\n", (unsigned long)vResv];
        NSUInteger ireg = vMemRet ? 1 : 0, freg = 0, sidx = 0;
        for (XTIROperand* a in args)
            {
            XTIRValue* v = a.kind == XTIROperandKindUse ? fn.values[@(a.valueId)] : nil;
            if (v && v.type.kind == XTIRTypeKindAgg)
                {
                NSNumber* sv = slot[@(a.valueId)];
                NSUInteger nregs = ([self aggSize:v.type.layout] + 7) / 8;
                if (sv && ireg + nregs <= 6)
                    {
                    for (NSUInteger k = 0; k < nregs; k++)
                        {
                        [out appendFormat:@"\tmov\t%@, [rbp-%ld]\n", [self argRegs64][ireg],
                                          (long)(sv.integerValue - 8 * (long)k)];
                        ireg++;
                        }
                    }
                }
            else if (v && [self isFloatVal:v] && freg < 8)
                {
                [self loadF:a
                       into:[NSString stringWithFormat:@"xmm%lu", (unsigned long)freg]
                         fn:fn
                       slot:slot
                        out:out];
                freg++;
                }
            else if (ireg < 6)
                {
                [self readArgOp:a into64:[self argRegs64][ireg] into32:[self argRegs32][ireg] fn:fn slot:slot out:out];
                ireg++;
                }
            else
                {
                [self loadZX:a into:'a' fn:fn slot:slot out:out];
                [out appendFormat:@"\tmov\t[rsp+%lu], rax\n", (unsigned long)(8 * sidx)];
                sidx++;
                }
            }
        vFreg = freg;
        NSUInteger lbl = sArcLabel++;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendString:@"\tmov\tr11, [rax]\n"];
        [out appendString:@"\tmov\tr11, [r11 + 8]\n"];
        [out appendFormat:@".L_it_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\tmov\tr10, [r11]\n"];
        [out appendFormat:@"\tcmp\tr10d, %lu\n", (unsigned long)(uint32_t)ops[1].intValue];
        [out appendFormat:@"\tje\t.L_ith_%lu\n", (unsigned long)lbl];
        [out appendString:@"\ttest\tr10, r10\n"];
        [out appendFormat:@"\tjz\t.L_itm_%lu\n", (unsigned long)lbl];
        [out appendString:@"\tadd\tr11, 16\n"];
        [out appendFormat:@"\tjmp\t.L_it_%lu\n", (unsigned long)lbl];
        [out appendFormat:@".L_itm_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\txor\tr11d, r11d\n"];
        [out appendFormat:@"\tjmp\t.L_itc_%lu\n", (unsigned long)lbl];
        [out appendFormat:@".L_ith_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\tmov\tr11, [r11 + 8]\n"];
        [out appendFormat:@"\tmov\tr11, [r11 + %lld]\n", (long long)(ops[2].intValue * 8)];
        [out appendFormat:@".L_itc_%lu:\n", (unsigned long)lbl];
        [out appendFormat:@"\tmov\teax, %lu\n", (unsigned long)vFreg];
        if (vMemRet)
            {
            NSNumber* rs = slot[@(res.valueId)];
            if (rs)
                [out appendFormat:@"\tlea\trdi, [rbp-%@]\n", rs];
            }
        [out appendString:@"\tcall\tr11\n"];
        if (vResv)
            [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)vResv];
        if (vMemRet)
            return;
        if (res && ![self isMem:res])
            {
            if (res.type.kind == XTIRTypeKindAgg)
                [self aggFromRetRegs:res slot:slot out:out];
            else if ([self isFloatVal:res])
                [self storeF:@"xmm0" into:res slot:slot out:out];
            else
                [self store:'a' into:res slot:slot out:out];
            }
        return;
        }
    case XTIROpProtoLoad:
        {
        // Take the address of a protocol method (&s.method) through the itable
        // (bug 201): the ProtoDispatch walk, but STORE table[index] instead of
        // calling it. Null receiver / absent itable / miss / null slot -> null,
        // which is what a &s.method null test relies on. Mirror of the
        // self-hosted emitProtoLoadX86.
        if (ops.count < 3 || ops[1].kind != XTIROperandKindImmI || ops[2].kind != XTIROperandKindImmI)
            return;
        if (!res || [self isMem:res])
            return;
        NSUInteger lbl = sArcLabel++;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendString:@"\txor\tr11d, r11d\n"];
        [out appendString:@"\ttest\trax, rax\n"];
        [out appendFormat:@"\tjz\t.L_pld_%lu\n", (unsigned long)lbl];
        [out appendString:@"\tmov\tr10, [rax]\n"];
        [out appendString:@"\tmov\tr10, [r10 + 8]\n"];
        [out appendString:@"\ttest\tr10, r10\n"];
        [out appendFormat:@"\tjz\t.L_pld_%lu\n", (unsigned long)lbl];
        [out appendFormat:@".L_pli_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\tmov\trax, [r10]\n"];
        [out appendFormat:@"\tcmp\teax, %lu\n", (unsigned long)(uint32_t)ops[1].intValue];
        [out appendFormat:@"\tje\t.L_plh_%lu\n", (unsigned long)lbl];
        [out appendString:@"\ttest\trax, rax\n"];
        [out appendFormat:@"\tjz\t.L_pld_%lu\n", (unsigned long)lbl];
        [out appendString:@"\tadd\tr10, 16\n"];
        [out appendFormat:@"\tjmp\t.L_pli_%lu\n", (unsigned long)lbl];
        [out appendFormat:@".L_plh_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\tmov\tr10, [r10 + 8]\n"];
        [out appendFormat:@"\tmov\tr11, [r10 + %lld]\n", (long long)(ops[2].intValue * 8)];
        [out appendFormat:@".L_pld_%lu:\n", (unsigned long)lbl];
        [out appendString:@"\tmov\trax, r11\n"];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpVTblLoad:
        {
        // Operands: [receiver, ImmI(slot), mem] -> fn pointer.
        // VTblDispatch's address computation ([recv] -> vtbl,
        // [vtbl + slot*8] -> fn) without the call: the code word of
        // `&obj.method`.
        //
        // A null receiver yields 0 rather than faulting, so `&nullDel.m`
        // is falsy instead of a crash. An empty slot is already 0 in the
        // emitted vtable (`.quad 0`), which is what makes an unimplemented
        // `optional` method falsy.
        if (ops.count < 2 || ops[1].kind != XTIROperandKindImmI)
            return;
        if (!res || [self isMem:res])
            return;
        NSUInteger n = sArcLabel++;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = receiver
        [out appendString:@"\txor\tr11, r11\n"];               // default null
        [out appendString:@"\ttest\trax, rax\n"];
        [out appendFormat:@"\tjz\t.L_vtl_%lu\n", (unsigned long)n];
        [out appendString:@"\tmov\tr11, [rax]\n"]; // vtable ptr
        [out appendFormat:@"\tmov\tr11, [r11 + %lld]\n",
                          (long long)(ops[1].intValue * 8)];
        [out appendFormat:@".L_vtl_%lu:\n", (unsigned long)n];
        [out appendString:@"\tmov\trax, r11\n"];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpConst:
        if (res && ops.count >= 1)
            {
            NSNumber* s = slot[@(res.valueId)];
            // A HOMED float constant has to reach its HOME. This used to write
            // the raw bits into the slot and stop — "it's read back via
            // movss/movsd", which stopped being true when floats got
            // registers. float_math's `double acc = 0.0` then started at
            // whatever the seeding loop had left in that xmm (b[4095] == 1.0),
            // and the benchmark came out exactly 1 too high.
            NSString* chome = sHome[@(res.valueId)];
            if ([self isFloatVal:res] && ops[0].kind == XTIROperandKindImmF &&
                chome && [self isXmmHome:chome])
                {
                union { uint64_t u; double d; } c;
                c.u = ops[0].floatRawBytes;
                if (res.type.kind == XTIRTypeKindF64)
                    [out appendFormat:@"\tmovabs\trax, %llu\n\tmovq\t%@, rax\n",
                                      (unsigned long long)c.u, chome];
                else
                    {
                    union { uint32_t u; float f; } f;
                    f.f = (float)c.d;
                    [out appendFormat:@"\tmov\teax, %u\n\tmovd\t%@, eax\n",
                                      (unsigned)f.u, chome];
                    }
                return;
                }
            if ([self isFloatVal:res] && ops[0].kind == XTIROperandKindImmF && s)
                {
                    // ImmF carries the raw IEEE *double* bits; store the slot's bits
                    // directly (it's read back via movss/movsd). F32 narrows first.
                    union {
                    uint64_t u;
                    double d;
                    } c;
                c.u = ops[0].floatRawBytes;
                if (res.type.kind == XTIRTypeKindF64)
                    [out appendFormat:@"\tmovabs\trax, %llu\n\tmov\t[rbp-%@], rax\n",
                                      (unsigned long long)c.u, s];
                else
                    {
                        union {
                        uint32_t u;
                        float f;
                        } f;
                    f.f = (float)c.d;
                    [out appendFormat:@"\tmov\tdword ptr [rbp-%@], %u\n", s, (unsigned)f.u];
                    }
                }
            else
                {
                [self load:ops[0] into:'a' fn:fn slot:slot out:out];
                [self store:'a' into:res slot:slot out:out];
                }
            }
        return;

    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFDiv:
        {
        if (!res || ops.count < 2)
            return;
        BOOL d = res.type.kind == XTIRTypeKindF64;
        NSString* D = [self fdstFor:res clobbering:ops[1] as:ops[0]];
        [self loadF:ops[0] into:D fn:fn slot:slot out:out];
        NSString* S = [self fsrcFor:ops[1] fn:fn slot:slot out:out];
        NSString* mn = op == XTIROpFAdd ? @"add" : op == XTIROpFSub ? @"sub"
                                               : op == XTIROpFMul   ? @"mul"
                                                                    : @"div";
        [out appendFormat:@"\t%@%@\t%@, %@\n", mn, d ? @"sd" : @"ss", D, S];
        [self storeF:D into:res slot:slot out:out];
        return;
        }
    case XTIROpFNeg:
        {
        if (!res || ops.count < 1)
            return;
        BOOL d = res.type.kind == XTIRTypeKindF64;
        // The operand goes to the scratch FIRST, so zeroing the destination
        // cannot destroy it even when result and operand share a home.
        [self loadF:ops[0] into:@"xmm0" fn:fn slot:slot out:out];
        NSString* Dn = res ? sHome[@(res.valueId)] : nil;
        if (!Dn || ![self isXmmHome:Dn] || [Dn isEqualToString:@"xmm0"])
            Dn = @"xmm1";
        [out appendFormat:@"\txorps\t%@, %@\n\tsub%@\t%@, xmm0\n",
                          Dn, Dn, d ? @"sd" : @"ss", Dn]; // 0-x
        [self storeF:Dn into:res slot:slot out:out];
        return;
        }
    case XTIROpFSqrt:
        {
        if (!res || ops.count < 1)
            return;
        BOOL d = res.type.kind == XTIRTypeKindF64;
        NSString* Sq = [self fsrcFor:ops[0] fn:fn slot:slot out:out];
        NSString* Dq = [self fdstFor:res clobbering:nil as:nil];
        [out appendFormat:@"\tsqrt%@\t%@, %@\n", d ? @"sd" : @"ss", Dq, Sq];
        [self storeF:Dq into:res slot:slot out:out];
        return;
        }
    case XTIROpSIToFp:
    case XTIROpUIToFp:
        {
        if (!res || ops.count < 1)
            return;
        BOOL d = res.type.kind == XTIRTypeKindF64;
        XTIRValue* sv = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        NSUInteger w = (sv && [self widthOf:sv] >= 8) ? 8 : 4;
        // cvtsi2ss reads a signed reg, so a SIGNED source must be sign-extended
        // (zero-extend would turn a negative i8 into a large positive int).
        if (op == XTIROpSIToFp)
            [self loadExt:ops[0] into:'a' signed:YES width:w fn:fn slot:slot out:out];
        else
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
        [out appendFormat:@"\tcvtsi2%@\txmm0, %@\n", d ? @"sd" : @"ss", [self reg:'a' width:w]];
        [self storeF:@"xmm0" into:res slot:slot out:out];
        return;
        }
    case XTIROpFpToSI:
    case XTIROpFpToUI:
        {
        if (!res || ops.count < 1)
            return;
        XTIRValue* sv = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        BOOL d = sv && sv.type.kind == XTIRTypeKindF64;
        NSUInteger rw = [self widthOf:res];
        [self loadF:ops[0] into:@"xmm0" fn:fn slot:slot out:out];
        [out appendFormat:@"\tcvtt%@2si\t%@, xmm0\n", d ? @"sd" : @"ss", [self reg:'a' width:(rw >= 8 ? 8 : 4)]];
        // xtc semantics: out-of-range / NaN saturate to 0. cvtt* yields the
        // "integer indefinite" (0x8000…0) for those, so map that value → 0.
        if (rw >= 8)
            [out appendString:@"\txor\tecx, ecx\n\tmov\trdx, 0x8000000000000000\n"
                               "\tcmp\trax, rdx\n\tcmove\trax, rcx\n"];
        else
            [out appendString:@"\txor\tecx, ecx\n\tcmp\teax, 0x80000000\n\tcmove\teax, ecx\n"];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    // f32 → f64
    case XTIROpFpExt:
        {
        if (!res || ops.count < 1)
            return;
        NSString* Sc = [self fsrcFor:ops[0] fn:fn slot:slot out:out];
        NSString* Dc = [self fdstFor:res clobbering:nil as:nil];
        [out appendFormat:@"\tcvtss2sd\t%@, %@\n", Dc, Sc];
        [self storeF:Dc into:res slot:slot out:out];
        return;
        }
    // f64 → f32
    case XTIROpFpTrunc:
        {
        if (!res || ops.count < 1)
            return;
        NSString* Sc = [self fsrcFor:ops[0] fn:fn slot:slot out:out];
        NSString* Dc = [self fdstFor:res clobbering:nil as:nil];
        [out appendFormat:@"\tcvtsd2ss\t%@, %@\n", Dc, Sc];
        [self storeF:Dc into:res slot:slot out:out];
        return;
        }
    case XTIROpFCmp:
        {
        // ucomisd sets CF/ZF like an unsigned compare. seta/setae are the
        // ORDERED >/>= (NaN → false); LT/LE swap operands to reuse them.
        if (!res || ops.count < 2)
            return;
        XTIRValue* lv = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        BOOL d = lv && lv.type.kind == XTIRTypeKindF64;
        uint8_t p = in.predicate;
        BOOL swap = (p == XTIRFCmpOLT || p == XTIRFCmpOLE);
        [self loadF:ops[swap ? 1 : 0] into:@"xmm0" fn:fn slot:slot out:out];
        [self loadF:ops[swap ? 0 : 1] into:@"xmm1" fn:fn slot:slot out:out];
        [out appendFormat:@"\tucomi%@\txmm0, xmm1\n", d ? @"sd" : @"ss"];
        NSString* cc = (p == XTIRFCmpOEQ) ? @"sete" : (p == XTIRFCmpONE)                   ? @"setne"
                                                  : (p == XTIRFCmpOGE || p == XTIRFCmpOLE) ? @"setae"
                                                                                           : @"seta";
        [out appendFormat:@"\t%@\tal\n\tmovzx\teax, al\n", cc];
        [self store:'a' into:res slot:slot out:out];
        return;
        }

    // Width casts: load src, the destination width view writes the slot. movzx/
    // movsx widen a narrow source; a same/narrowing cast is just a re-store.
    case XTIROpZExt:
        if (res && ops.count >= 1)
            {
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // home-aware zero-extend
            [self store:'a' into:res slot:slot out:out];
            }
        return;
    case XTIROpSExt:
        if (res && ops.count >= 1)
            {
            NSUInteger dw = [self widthOf:res];
            [self loadExt:ops[0]
                     into:'a'
                   signed:YES
                    width:(dw < 4 ? 4 : dw)
                       fn:fn
                     slot:slot
                      out:out]; // home-aware sign-extend
            [self store:'a' into:res slot:slot out:out];
            }
        return;
    case XTIROpTrunc:
    case XTIROpCopy:
    case XTIROpBitcast:
        if (res && ops.count >= 1)
            {
            [self load:ops[0] into:'a' fn:fn slot:slot out:out];
            [self store:'a' into:res slot:slot out:out];
            }
        return;

    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
        // Reinterpret — zero-extend so a width change leaves no stale high bits.
        if (res && ops.count >= 1)
            {
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
            [self store:'a' into:res slot:slot out:out];
            }
        return;

    // Binary integer ops: lhs→rax, rhs→rcx, op, store rax. Width from result.
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
        {
        if (!res || ops.count < 2)
            return;
        NSUInteger w = [self widthOf:res];
        if (w < 4)
            w = 4;
        NSString* mn = op == XTIROpAdd ? @"add" : op == XTIROpSub ? @"sub"
                                              : op == XTIROpAnd   ? @"and"
                                              : op == XTIROpOr    ? @"or"
                                              : op == XTIROpXor   ? @"xor"
                                                                  : @"imul";
        // imul accepts an immediate ONLY in its 3-operand form (`imul dst,src,imm`);
        // the 2-operand form the two-address path below emits cannot. Take a
        // constant multiplier here → one `imul dst, <src>, imm`.
        //
        // The immediate is an imm32, SIGN-EXTENDED to 64 — there is no
        // imul r64, r/m64, imm64. A wider multiplier silently lost its
        // top 32 bits here: `x * 0x100000001B3` (the FNV-1a 64 prime)
        // became `x * 0x1B3`, and every 64-bit content hash blewit
        // computed on x86_64 disagreed with arm64 (spike/
        // xtc_mul64_imm_bug.xc). Wide constants fall through to the
        // general path, whose srcOperand already stages them in a
        // register (mov r64, imm64 exists; imul r64, r64 does too).
        if (op == XTIROpMul && ops[1].kind == XTIROperandKindImmI && !(w == 8 && ((long long)ops[1].intValue > INT32_MAX || (long long)ops[1].intValue < INT32_MIN)))
            {
            NSString* rh = sHome[@(res.valueId)];
            NSString* dst = rh ? [self regView:rh width:w] : [self reg:'a' width:w];
            if (ops[0].kind == XTIROperandKindUse)
                {
                NSString* src = [self srcOperand:ops[0] width:w resReg:@"" fn:fn slot:slot out:out];
                [out appendFormat:@"\timul\t%@, %@, %lld\n", dst, src, (long long)ops[1].intValue];
                }
            // const*const (rare — normally already constant-folded)
            else
                {
                [self movOperand:ops[0] intoReg:dst width:w fn:fn slot:slot out:out];
                [out appendFormat:@"\timul\t%@, %@, %lld\n", dst, dst, (long long)ops[1].intValue];
                }
            if (!rh)
                [self store:'a' into:res slot:slot out:out];
            return;
            }
        NSString* resHome = sHome[@(res.valueId)];
        // Two-address form when the result is homed (i32/u32/ptr): compute
        // directly in the result register instead of round-tripping scratch.
        // `res = k <op> o`; for a commutative op we keep whichever operand
        // already sits in resR (or swap) so the produce-into is a no-op.
        if (resHome && (w == 4 || w == 8))
            {
            NSString* resR = [self regView:resHome width:w];
            BOOL commut = (op != XTIROpSub);
            XTIROperand *keep = ops[0], *other = ops[1];
            // Only a USE has a home. An immediate's operand shares the id
            // field with its value, so `#1` read as "value %1" here — and
            // whenever %1 happened to be homed in the result register the
            // immediate was kept and the real operand staged out, three
            // instructions where the port's one `add ebx, 1` is right
            // (bug 090's residue: Array$add, Stdio$_emitU32, …).
            if (commut && ops[1].kind == XTIROperandKindUse && [sHome[@(ops[1].valueId)] isEqualToString:resHome])
                {
                keep = ops[1];
                other = ops[0];
                }
            BOOL keepInRes = (keep.kind == XTIROperandKindUse && [sHome[@(keep.valueId)] isEqualToString:resHome]);
            // Stage `other` FIRST (into rcx if it currently lives in resR) so
            // producing `keep` into resR can't clobber it.
            NSString* os = [self srcOperand:other width:w resReg:resR fn:fn slot:slot out:out];
            if (!keepInRes)
                [self movOperand:keep intoReg:resR width:w fn:fn slot:slot out:out];
            [out appendFormat:@"\t%@\t%@, %@\n", mn, resR, os];
            return;
            }
        [self load:ops[0] into:'a' fn:fn slot:slot out:out];
        [self load:ops[1] into:'c' fn:fn slot:slot out:out];
        NSString *a = [self reg:'a' width:w], *c = [self reg:'c' width:w];
        [out appendFormat:@"\t%@\t%@, %@\n", mn, a, c];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
        {
        if (!res || ops.count < 2)
            return;
        NSUInteger w = [self widthOf:res];
        if (w < 4)
            w = 4;
        // Extend the operand to the full shift width first: a right shift pulls
        // the high bits down, so a narrow value loaded with stale high bits gives
        // garbage. AShr needs sign-extension (arithmetic), LShr/Shl zero.
        [self loadExt:ops[0] into:'a' signed:(op == XTIROpAShr) width:w fn:fn slot:slot out:out];
        NSString* mn = op == XTIROpShl ? @"shl" : op == XTIROpLShr ? @"shr"
                                                                   : @"sar";
        // constant count → immediate shift
        if (ops[1].kind == XTIROperandKindImmI)
            {
            long long cnt = ops[1].intValue & (w == 8 ? 63 : 31); // CPU masks cl the same way
            [out appendFormat:@"\t%@\t%@, %lld\n", mn, [self reg:'a' width:w], cnt];
            }
        else
            {
            [self load:ops[1] into:'c' fn:fn slot:slot out:out]; // shift count in cl
            [out appendFormat:@"\t%@\t%@, cl\n", mn, [self reg:'a' width:w]];
            }
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpNeg:
    case XTIROpNot:
        if (res && ops.count >= 1)
            {
            NSUInteger w = [self widthOf:res];
            if (w < 4)
                w = 4;
            [self load:ops[0] into:'a' fn:fn slot:slot out:out];
            [out appendFormat:@"\t%@\t%@\n", op == XTIROpNeg ? @"neg" : @"not", [self reg:'a' width:w]];
            [self store:'a' into:res slot:slot out:out];
            }
        return;

    case XTIROpUDiv:
    case XTIROpURem:
    case XTIROpSDiv:
    case XTIROpSRem:
        {
        // x86 division: dividend in (e/r)ax, divisor in (e/r)cx; quotient → ax,
        // remainder → dx. Signed uses cdq/cqo + idiv; unsigned zeroes edx + div.
        if (!res || ops.count < 2)
            return;
        BOOL sgned = (op == XTIROpSDiv || op == XTIROpSRem);
        BOOL rem = (op == XTIROpURem || op == XTIROpSRem);
        NSUInteger w = [self widthOf:res];
        if (w < 4)
            w = 4;
        // Constant divisor → magic reciprocal multiply (mul/imul high half + a
        // couple of shifts), avoiding the ~20-40 cycle div/idiv. Every xtc integer
        // type is <=32-bit, so the dividend is extended to 32 and a W=32 magic
        // serves all widths. (Hacker's Delight §10-3/§10-9, same as arm64.)
        int64_t dC = 0;
        if (w == 4 && [self x86ConstDivisor:ops[1] fn:fn out:&dC])
            {
            uint64_t ad = (uint64_t)(dC < 0 ? -dC : dC);
            BOOL nonPow2 = (ad >= 2) && ((ad & (ad - 1)) != 0);
            if (!sgned && nonPow2)
                {
                uint64_t ud = (uint64_t)(uint32_t)dC, M;
                int aa, s;
                xtMagicU(ud, 32, &M, &aa, &s);
                [self loadExt:ops[0] into:'a' signed:NO width:4 fn:fn slot:slot out:out];
                [out appendFormat:@"\tmov\tecx, %u\n", (uint32_t)M];
                [out appendString:@"\tmul\tecx\n"]; // edx = mulhu(x,M) = t
                if (aa == 0)
                    {
                    if (s > 0)
                        [out appendFormat:@"\tshr\tedx, %d\n", s];
                    }
                // t + ((x-t)>>1), >> (s-1)
                else
                    {
                    [self loadExt:ops[0] into:'a' signed:NO width:4 fn:fn slot:slot out:out];
                    [out appendString:@"\tsub\teax, edx\n"];
                    [out appendString:@"\tshr\teax, 1\n"];
                    [out appendString:@"\tadd\tedx, eax\n"];
                    if (s > 1)
                        [out appendFormat:@"\tshr\tedx, %d\n", s - 1];
                    }
                // r = x - q*d
                if (rem)
                    {
                    [out appendFormat:@"\timul\tecx, edx, %d\n", (int32_t)dC];
                    [self loadExt:ops[0] into:'a' signed:NO width:4 fn:fn slot:slot out:out];
                    [out appendString:@"\tsub\teax, ecx\n"];
                    [self store:'a' into:res slot:slot out:out];
                    }
                else
                    {
                    [self store:'d' into:res slot:slot out:out];
                    }
                return;
                }
            if (sgned && nonPow2)
                {
                int64_t Ms;
                int s;
                xtMagicS(dC, 32, &Ms, &s);
                [self loadExt:ops[0] into:'a' signed:YES width:4 fn:fn slot:slot out:out];
                [out appendFormat:@"\tmov\tecx, %u\n", (uint32_t)Ms];
                [out appendString:@"\timul\tecx\n"]; // edx = mulhs(x,M) = q0
                if (dC > 0 && Ms < 0)
                    {
                    [self loadExt:ops[0] into:'a' signed:YES width:4 fn:fn slot:slot out:out];
                    [out appendString:@"\tadd\tedx, eax\n"];
                    }
                if (dC < 0 && Ms > 0)
                    {
                    [self loadExt:ops[0] into:'a' signed:YES width:4 fn:fn slot:slot out:out];
                    [out appendString:@"\tsub\tedx, eax\n"];
                    }
                if (s > 0)
                    [out appendFormat:@"\tsar\tedx, %d\n", s];
                [out appendString:@"\tmov\teax, edx\n"]; // + sign bit: q0 + (q0>>u31)
                [out appendString:@"\tshr\teax, 31\n"];
                [out appendString:@"\tadd\tedx, eax\n"];
                if (rem)
                    {
                    [out appendFormat:@"\timul\tecx, edx, %d\n", (int32_t)dC];
                    [self loadExt:ops[0] into:'a' signed:YES width:4 fn:fn slot:slot out:out];
                    [out appendString:@"\tsub\teax, ecx\n"];
                    [self store:'a' into:res slot:slot out:out];
                    }
                else
                    {
                    [self store:'d' into:res slot:slot out:out];
                    }
                return;
                }
            }
        [self loadExt:ops[0] into:'a' signed:sgned width:w fn:fn slot:slot out:out];
        [self loadExt:ops[1] into:'c' signed:sgned width:w fn:fn slot:slot out:out];
        if (sgned)
            [out appendFormat:@"\t%@\n", w == 8 ? @"cqo" : @"cdq"];
        else
            [out appendString:@"\txor\tedx, edx\n"];
        [out appendFormat:@"\t%@\t%@\n", sgned ? @"idiv" : @"div", [self reg:'c' width:w]];
        [self store:(rem ? 'd' : 'a') into:res slot:slot out:out];
        return;
        }
    case XTIROpICmp:
        {
        if (!res || ops.count < 2)
            return;
        // Fused into a Select: the compare is re-issued at the cmov so the
        // flags reach it directly. Nothing to emit here.
        if (sSelSkip && sSelSkip[@(res.valueId)])
            return;
        uint8_t p = in.predicate;
        BOOL sg = (p == XTIRICmpSLT || p == XTIRICmpSLE || p == XTIRICmpSGT || p == XTIRICmpSGE);
        XTIRValue* l = ops[0].kind == XTIROperandKindUse ? fn.values[@(ops[0].valueId)] : nil;
        XTIRValue* r = ops[1].kind == XTIROperandKindUse ? fn.values[@(ops[1].valueId)] : nil;
        NSUInteger wl = l ? [self widthOf:l] : 4, wr = r ? [self widthOf:r] : 4;
        NSUInteger w = (wl > wr ? wl : wr);
        if (w < 4)
            w = 4;
        [self loadExt:ops[0] into:'a' signed:sg width:w fn:fn slot:slot out:out];
        // FOLD A CONSTANT RIGHT-HAND SIDE. x86 has `cmp r32, imm32` and
        // `cmp r64, imm32` (sign-extended) and nothing was using either: every
        // comparison against a literal cost an extra `mov` into rcx first, in
        // every loop guard in every program. arm64 folds the same operand into
        // `cmp w10, #1, lsl #12` from the same IR, which already carries it as
        // an immediate (`ICmp ULT, %71, #8192:U32`).
        //
        // A 64-bit compare takes only a sign-extendable imm32, so a wider
        // literal still goes through the register.
        BOOL folded = NO;
        if (ops[1].kind == XTIROperandKindImmI)
            {
            long long k = (long long)ops[1].intValue;
            BOOL fits = (w <= 4) || (k >= INT32_MIN && k <= INT32_MAX);
            if (fits)
                {
                // ...and against ZERO, `test r, r` sets the same flags in one
                // byte less and with no immediate at all. Only for equality and
                // the unsigned predicates: `test` clears CF and OF, so the
                // SIGNED less/greater tests would read the wrong flags.
                BOOL zeroOK = (k == 0) &&
                              (p == XTIRICmpEQ || p == XTIRICmpNE ||
                               p == XTIRICmpULT || p == XTIRICmpUGE);
                if (zeroOK)
                    {
                    [out appendFormat:@"\ttest\t%@, %@\n", [self reg:'a' width:w],
                                      [self reg:'a' width:w]];
                    folded = YES;
                    }
                else
                    {
                    // Print a 32-bit immediate in its SIGNED reading. The bit
                    // pattern is what a 32-bit compare tests, and `cmp eax, -1`
                    // takes the sign-extended imm8 encoding (83 /7 ib, three
                    // bytes) where `cmp eax, 4294967295` takes imm32 (3d id,
                    // five). The assembler already has both forms; it chooses
                    // by whether the printed value fits a signed byte, so the
                    // spelling decides the encoding. clang emits the short one
                    // and vocab-diff flagged the difference.
                    long long pk = (w == 4) ? (long long)(int32_t)k : k;
                    [out appendFormat:@"\tcmp\t%@, %lld\n", [self reg:'a' width:w], pk];
                    folded = YES;
                    }
                }
            }
        if (!folded)
            {
            [self loadExt:ops[1] into:'c' signed:sg width:w fn:fn slot:slot out:out];
            [out appendFormat:@"\tcmp\t%@, %@\n", [self reg:'a' width:w], [self reg:'c' width:w]];
            }
        // Fused into the block's CondBranch: leave the flags set and let the
        // terminator branch on the predicate — no boolean materialisation.
        if (sFusedCmp && [sFusedCmp containsObject:@(res.valueId)])
            return;
        [out appendFormat:@"\t%@\tal\n\tmovzx\teax, al\n", [self setccForICmp:p]];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpSelect:
        {
        // cond ? trueVal : falseVal — branchless cmov.
        if (!res || ops.count < 3)
            return;
        NSUInteger w = [self widthOf:res];
        if (w < 4)
            w = 4;
        [self load:ops[1] into:'a' fn:fn slot:slot out:out];   // true → rax
        [self load:ops[2] into:'d' fn:fn slot:slot out:out];   // false → rdx
        // The condition is an ICmp used only here: re-issue its compare now
        // (rax/rdx already hold the two values, rcx is free) and let the cmov
        // read the flags. Take the FALSE value when the predicate does not hold.
        XTIRInsn* scmp = sSelCmp ? sSelCmp[@(res.valueId)] : nil;
        if (scmp && ops[0].kind == XTIROperandKindUse && sSelSkip &&
            sSelSkip[@(ops[0].valueId)])
            {
            uint8_t sp = scmp.predicate;
            BOOL ssg = (sp == XTIRICmpSLT || sp == XTIRICmpSLE ||
                        sp == XTIRICmpSGT || sp == XTIRICmpSGE);
            XTIRValue* sl = scmp.operands[0].kind == XTIROperandKindUse
                                ? fn.values[@(scmp.operands[0].valueId)] : nil;
            NSUInteger cw = sl ? [self widthOf:sl] : 4;
            if (cw < 4)
                cw = 4;
            [self loadExt:scmp.operands[0] into:'c' signed:ssg width:cw fn:fn slot:slot out:out];
            long long k = (long long)scmp.operands[1].intValue;
            BOOL zeroOK = (k == 0) && (sp == XTIRICmpEQ || sp == XTIRICmpNE ||
                                       sp == XTIRICmpULT || sp == XTIRICmpUGE);
            if (zeroOK)
                [out appendFormat:@"\ttest\t%@, %@\n", [self reg:'c' width:cw], [self reg:'c' width:cw]];
            else
                [out appendFormat:@"\tcmp\t%@, %lld\n", [self reg:'c' width:cw],
                                  (cw == 4) ? (long long)(int32_t)k : k];
            [out appendFormat:@"\t%@\t%@, %@\n", [self cmovForNegatedICmp:sp],
                              [self reg:'a' width:w], [self reg:'d' width:w]];
            [self store:'a' into:res slot:slot out:out];
            return;
            }
        [self loadZX:ops[0] into:'c' fn:fn slot:slot out:out]; // cond → rcx (zero-extended)
        NSUInteger cw = [self condWidth:ops[0] fn:fn];
        [out appendFormat:@"\ttest\t%@, %@\n", [self reg:'c' width:cw], [self reg:'c' width:cw]];
        [out appendFormat:@"\tcmove\t%@, %@\n", [self reg:'a' width:(w < 4 ? 4 : w)], [self reg:'d' width:(w < 4 ? 4 : w)]];
        [self store:'a' into:res slot:slot out:out];
        return;
        }

    // %v:Vec <- [ptr] (128-bit unaligned)
    case XTIROpVLoad:
        {
        if (!res || ops.count < 1 || !sVec[@(res.valueId)])
            return;
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = pointer
        BOOL flt = res.type.pointeeType && [self isFloatKind:res.type.pointeeType.kind];
        [out appendFormat:@"\t%@\t%@, [rax]\n", flt ? @"movups" : @"movdqu", sVec[@(res.valueId)]];
        return;
        }
    // [ptr] <- %v:Vec
    case XTIROpVStore:
        {
        if (ops.count < 2 || ops[1].kind != XTIROperandKindUse || !sVec[@(ops[1].valueId)])
            return;
        XTIRValue* vv = fn.values[@(ops[1].valueId)];
        BOOL flt = vv.type.pointeeType && [self isFloatKind:vv.type.pointeeType.kind];
        [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out]; // rax = pointer
        [out appendFormat:@"\t%@\t[rax], %@\n", flt ? @"movups" : @"movdqu", sVec[@(ops[1].valueId)]];
        return;
        }
    // %v:Vec <- broadcast(scalar)
    case XTIROpVSplat:
        {
        if (!res || ops.count < 1 || !sVec[@(res.valueId)])
            return;
        NSString* d = sVec[@(res.valueId)];
        XTIRType* lane = res.type.pointeeType;
        // f64 ×2
        if (lane && lane.kind == XTIRTypeKindF64)
            {
            [self loadF:ops[0] into:d fn:fn slot:slot out:out];
            [out appendFormat:@"\tunpcklpd\t%@, %@\n", d, d];
            }
        // f32 ×4
        else if (lane && lane.kind == XTIRTypeKindF32)
            {
            [self loadF:ops[0] into:d fn:fn slot:slot out:out];
            [out appendFormat:@"\tshufps\t%@, %@, 0\n", d, d];
            }
        // integer lanes (via GP)
        else
            {
            [self loadZX:ops[0] into:'a' fn:fn slot:slot out:out];
            [out appendFormat:@"\tmovd\t%@, eax\n", d];
            NSUInteger lw = lane ? lane.byteWidth : 4;
            if (lw == 2)
                {
                // 16-bit lanes: a dword pshufd would splat the scalar as
                // [c,0,c,0,…] across the 8 word lanes (zeroing the odd ones).
                // Broadcast the low word to all 8 lanes instead.
                [out appendFormat:@"\tpshuflw\t%@, %@, 0\n\tpshufd\t%@, %@, 0\n", d, d, d, d];
                }
            else if (lw == 1)
                {
                // 8-bit lanes: broadcast the low byte to all 16 lanes.
                [out appendFormat:@"\tpunpcklbw\t%@, %@\n\tpshuflw\t%@, %@, 0\n"
                                  @"\tpshufd\t%@, %@, 0\n",
                                  d, d, d, d, d, d];
                }
            // 32-bit lanes ×4
            else
                {
                [out appendFormat:@"\tpshufd\t%@, %@, 0\n", d, d];
                }
            }
        return;
        }
    case XTIROpVAdd:
    case XTIROpVSub:
    case XTIROpVMul:
    case XTIROpVAnd:
    case XTIROpVOr:
    case XTIROpVXor:
    case XTIROpVMax:
    case XTIROpVMin:
        {
        if (!res || ops.count < 2 || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSString *d = sVec[@(res.valueId)], *a = sVec[@(ops[0].valueId)], *b = sVec[@(ops[1].valueId)];
        if (!d || !a || !b)
            return;
        XTIRType* lane = res.type.pointeeType;
        NSString* mn = [self sseMnemForVecOp:op lane:lane];
        if (!mn)
            return;
        BOOL flt = lane && [self isFloatKind:lane.kind];
        NSString* mov = flt ? @"movaps" : @"movdqa";
        BOOL commut = (op != XTIROpVSub);
        // Two-address destructive form: compute in d. Keep whichever source is
        // already d (commutative), else copy a→d first.
        if ([d isEqualToString:a])
            [out appendFormat:@"\t%@\t%@, %@\n", mn, d, b];
        else if (commut && [d isEqualToString:b])
            [out appendFormat:@"\t%@\t%@, %@\n", mn, d, a];
        else
            {
            [out appendFormat:@"\t%@\t%@, %@\n", mov, d, a];
            [out appendFormat:@"\t%@\t%@, %@\n", mn, d, b];
            }
        return;
        }
    // The HIGH half of a 32x32 lane product. SSE2 gives only pmuludq, which
    // multiplies the EVEN lanes (0 and 2) into two 64-bit results, so the four
    // high halves take two products and a re-interleave:
    //
    //   xmm0 = hi(a0*b0), hi(a2*b2)   in lanes 0 and 2
    //   xmm1 = hi(a1*b1), hi(a3*b3)   in lanes 0 and 2   (operands swapped
    //                                  within each pair by pshufd 0xB1)
    //   shufps 0x88 gathers <h0,h2,h1,h3>, pshufd 0xD8 puts it back in order.
    //
    // The operand order matters for aliasing: `a` is dead once both shuffles
    // have read it, and `b` is read into the DESTINATION last, so d may alias
    // either input without losing a value that is still needed.
    case XTIROpVMulHi:
        {
        if (!res || ops.count < 2 || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSString *d = sVec[@(res.valueId)], *a = sVec[@(ops[0].valueId)], *b = sVec[@(ops[1].valueId)];
        if (!d || !a || !b)
            return;
        [out appendFormat:@"\tmovdqa\txmm0, %@\n", a];
        [out appendFormat:@"\tpmuludq\txmm0, %@\n", b];
        [out appendString:@"\tpsrlq\txmm0, 32\n"];
        [out appendFormat:@"\tpshufd\txmm1, %@, 0xB1\n", a];
        [out appendFormat:@"\tpshufd\t%@, %@, 0xB1\n", d, b];
        [out appendFormat:@"\tpmuludq\txmm1, %@\n", d];
        [out appendString:@"\tpsrlq\txmm1, 32\n"];
        [out appendFormat:@"\tmovdqa\t%@, xmm0\n", d];
        [out appendFormat:@"\tshufps\t%@, xmm1, 0x88\n", d];
        [out appendFormat:@"\tpshufd\t%@, %@, 0xD8\n", d, d];
        return;
        }
    // Lane-wise logical shift right by a CONSTANT. SSE2 spells this
    // psrlw/psrld/psrlq by lane width, all two-address and all taking the count
    // as an 8-bit immediate — there is no lane-wise variable shift below AVX2,
    // and the IR never asks for one.
    case XTIROpVLShr:
        {
        if (!res || ops.count < 2 || ops[0].kind != XTIROperandKindUse)
            return;
        NSString *d = sVec[@(res.valueId)], *a = sVec[@(ops[0].valueId)];
        if (!d || !a)
            return;
        XTIRType* lane = res.type.pointeeType;
        NSUInteger lw = lane ? [self fieldWidth:lane] : 4;
        NSString* mn = lw == 2 ? @"psrlw" : lw == 8 ? @"psrlq" : @"psrld";
        if (lw != 2 && lw != 4 && lw != 8)
            return; // no byte-lane shift in SSE
        if (![d isEqualToString:a])
            [out appendFormat:@"\tmovdqa\t%@, %@\n", d, a];
        [out appendFormat:@"\t%@\t%@, %lld\n", mn, d, (long long)ops[1].intValue];
        return;
        }
    // scalar <- horizontal add of 4 i32 lanes
    case XTIROpVReduceAdd:
        {
        if (!res || ops.count < 1 || ops[0].kind != XTIROperandKindUse || !sVec[@(ops[0].valueId)])
            return;
        NSString* v = sVec[@(ops[0].valueId)];
        [out appendFormat:@"\tphaddd\t%@, %@\n\tphaddd\t%@, %@\n", v, v, v, v];
        [out appendFormat:@"\tmovd\teax, %@\n", v];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    case XTIROpVReduceMax:
    // horizontal max/min of 4 i32 lanes
    case XTIROpVReduceMin:
        {
        if (!res || ops.count < 1 || ops[0].kind != XTIROperandKindUse || !sVec[@(ops[0].valueId)])
            return;
        NSString* v = sVec[@(ops[0].valueId)];
        BOOL sgn = XTIRTypeKindIsSigned(res.type.kind);
        NSString* mn = (op == XTIROpVReduceMax) ? (sgn ? @"pmaxsd" : @"pmaxud") : (sgn ? @"pminsd" : @"pminud");
        // fold [3210]→pairwise via two shuffles (xmm0 is a free scratch here).
        [out appendFormat:@"\tpshufd\txmm0, %@, 0x4E\n\t%@\t%@, xmm0\n", v, mn, v];
        [out appendFormat:@"\tpshufd\txmm0, %@, 0xB1\n\t%@\t%@, xmm0\n", v, mn, v];
        [out appendFormat:@"\tmovd\teax, %@\n", v];
        [self store:'a' into:res slot:slot out:out];
        return;
        }
    // %v:Vec <- lane-wise compare → 0/-1 mask (i32 lanes)
    case XTIROpVICmp:
        {
        if (!res || ops.count < 2 || ops[0].kind != XTIROperandKindUse || ops[1].kind != XTIROperandKindUse)
            return;
        NSString *d = sVec[@(res.valueId)], *a = sVec[@(ops[0].valueId)], *b = sVec[@(ops[1].valueId)];
        if (!d || !a || !b)
            return;
        BOOL useEq = NO, swap = NO, invert = NO, uns = NO;
        switch (in.predicate)
            {
        case XTIRICmpSGT:
            break;
        case XTIRICmpSLT:
            swap = YES;
            break;
        case XTIRICmpSGE:
            swap = YES;
            invert = YES;
            break;
        case XTIRICmpSLE:
            invert = YES;
            break;
        case XTIRICmpUGT:
            uns = YES;
            break;
        case XTIRICmpULT:
            uns = YES;
            swap = YES;
            break;
        case XTIRICmpUGE:
            uns = YES;
            swap = YES;
            invert = YES;
            break;
        case XTIRICmpULE:
            uns = YES;
            invert = YES;
            break;
        case XTIRICmpEQ:
            useEq = YES;
            break;
        case XTIRICmpNE:
            useEq = YES;
            invert = YES;
            break;
        default:
            return;
            }
        NSString *lhs = swap ? b : a, *rhs = swap ? a : b;
        // The compare must be taken at the LANE width. Every mnemonic here used
        // to be the `d` (32-bit) form whatever the lanes were, so a vector of
        // BYTES was compared four at a time as one dword and a match needed all
        // four to coincide: `if (buf[i] == 44) n++` counted 0 instead of 64,
        // silently, in string_scan. Every other vector op in this back end picks
        // its width through vecMnemonic; this one did not.
        XTIRType* lane = res.type ? res.type.pointeeType : nil;
        NSUInteger lw = lane ? [self fieldWidth:lane] : 4;
        if (lw != 1 && lw != 2 && lw != 4)
            return;         // 64-bit lanes need SSE4.2 pcmpgtq; not emitted today
        NSString* sfx = lw == 1 ? @"b" : lw == 2 ? @"w" : @"d";
        if (uns && !useEq)
            {
            // Bias both by the lane's sign bit, so an unsigned order becomes a
            // signed one. All-ones shifted into place gives the mask: for BYTES
            // that needs 0x01 per byte first (pabsb of all-ones), because
            // shifting all-ones left by 7 in 16-bit units leaves 0xFF80, not
            // 0x8080.
            if (lw == 1)
                [out appendString:@"\tpcmpeqd\txmm1, xmm1\n\tpabsb\txmm1, xmm1\n\tpsllw\txmm1, 7\n"];
            else if (lw == 2)
                [out appendString:@"\tpcmpeqd\txmm1, xmm1\n\tpsllw\txmm1, 15\n"];
            else
                [out appendString:@"\tpcmpeqd\txmm1, xmm1\n\tpslld\txmm1, 31\n"];
            [out appendFormat:@"\tmovdqa\t%@, %@\n\tpxor\t%@, xmm1\n", d, lhs, d];
            [out appendFormat:@"\tmovdqa\txmm0, %@\n\tpxor\txmm0, xmm1\n", rhs];
            [out appendFormat:@"\tpcmpgt%@\t%@, xmm0\n", sfx, d];
            }
        else
            {
            NSString* cmp = [NSString stringWithFormat:@"%@%@",
                                                       useEq ? @"pcmpeq" : @"pcmpgt", sfx];
            if ([d isEqualToString:lhs])
                [out appendFormat:@"\t%@\t%@, %@\n", cmp, d, rhs];
            else if (useEq && [d isEqualToString:rhs])
                [out appendFormat:@"\t%@\t%@, %@\n", cmp, d, lhs];
            else
                {
                [out appendFormat:@"\tmovdqa\t%@, %@\n", d, lhs];
                [out appendFormat:@"\t%@\t%@, %@\n", cmp, d, rhs];
                }
            }
        if (invert)
            [out appendFormat:@"\tpcmpeqd\txmm0, xmm0\n\tpxor\t%@, xmm0\n", d]; // ^ all-ones
        return;
        }
    // widen pairwise add: u8→u16 (pmaddubsw) or u16→u32 (pmaddwd)
    case XTIROpVAddLP:
        {
        if (!res || ops.count < 1 || ops[0].kind != XTIROperandKindUse || !sVec[@(ops[0].valueId)] || !sVec[@(res.valueId)])
            return;
        NSString *d = sVec[@(res.valueId)], *a = sVec[@(ops[0].valueId)];
        XTIRType* inLane = fn.values[@(ops[0].valueId)].type.pointeeType;
        NSUInteger iw = inLane ? [self fieldWidth:inLane] : 2;
        if (![d isEqualToString:a])
            [out appendFormat:@"\tmovdqa\t%@, %@\n", d, a];
        // u8 pairs → u16 : pmaddubsw with +1 bytes (xmm0)
        if (iw == 1)
            {
            [out appendString:@"\tpcmpeqd\txmm0, xmm0\n\tpabsb\txmm0, xmm0\n"]; // 0x01×16
            [out appendFormat:@"\tpmaddubsw\t%@, xmm0\n", d];
            }
        // u16 pairs → u32 : pmaddwd with +1 words (xmm0)
        else
            {
            [out appendString:@"\tpcmpeqd\txmm0, xmm0\n\tpsrlw\txmm0, 15\n"]; // 0x0001×8
            [out appendFormat:@"\tpmaddwd\t%@, xmm0\n", d];
            }
        return;
        }

    case XTIROpMemCopy:
        {
        // Operands: [dst, src, size, memInput] → memcpy(arg0, arg1, arg2).
        // Arg regs are never home registers (pool is rbx/r12-r15), so
        // materialising in order can't clobber an earlier arg.
        if (in.operands.count < 3)
            return;
        NSArray<NSString*>*ir = [self argRegs64], *ir32 = [self argRegs32];
        [self readArgOp:in.operands[0] into64:ir[0] into32:ir32[0] fn:fn slot:slot out:out];
        [self readArgOp:in.operands[1] into64:ir[1] into32:ir32[1] fn:fn slot:slot out:out];
        [self readArgOp:in.operands[2] into64:ir[2] into32:ir32[2] fn:fn slot:slot out:out];
        [self emitRTCall:@"memcpy" into:out];
        return;
        }
    case XTIROpMemSet:
        {
        // Operands: [dst, byte:U8, size, memInput] → memset(arg0, arg1, arg2).
        if (in.operands.count < 3)
            return;
        NSArray<NSString*>*mr = [self argRegs64], *mr32 = [self argRegs32];
        [self readArgOp:in.operands[0] into64:mr[0] into32:mr32[0] fn:fn slot:slot out:out];
        [self readArgOp:in.operands[1] into64:mr[1] into32:mr32[1] fn:fn slot:slot out:out];
        [self readArgOp:in.operands[2] into64:mr[2] into32:mr32[2] fn:fn slot:slot out:out];
        [self emitRTCall:@"memset" into:out];
        return;
        }

    case XTIROpAsm:
        {
        // `asm { … }` — the body is emitted verbatim, as on arm64. The
        // backend already suppresses register homing and address folding for
        // any function containing one (see `hasAsm`), so a body may refer to
        // locals by their fixed rbp-relative slots.
        XTIRConstantId cid = NSNotFound;
        for (XTIROperand* op2 in in.operands)
            if (op2.kind == XTIROperandKindConstAgg)
                {
                cid = op2.constantId;
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
                                        withString:s ? [NSString stringWithFormat:@"rbp-%ld",
                                                                                  (long)s.integerValue]
                                                     : @"rbp"];
                }
            text = resolved;
            }
        [out appendString:@"\t# inline asm\n"];
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
        [out appendFormat:@"\t# TODO insn op=%d\n", (int)op];
        return;
        }
    }

+ (NSString*)setccForICmp:(uint8_t)p
    {
    switch (p)
        {
    case XTIRICmpEQ:
        return @"sete";
    case XTIRICmpNE:
        return @"setne";
    case XTIRICmpSLT:
        return @"setl";
    case XTIRICmpSGT:
        return @"setg";
    case XTIRICmpSLE:
        return @"setle";
    case XTIRICmpSGE:
        return @"setge";
    case XTIRICmpULT:
        return @"setb";
    case XTIRICmpUGT:
        return @"seta";
    case XTIRICmpULE:
        return @"setbe";
    case XTIRICmpUGE:
        return @"setae";
        }
    return @"sete";
    }

// Conditional jump taken when the ICmp predicate is FALSE (the fused CondBranch
// jumps to its false target on the negated condition).
// cmov taken when the ICmp predicate is FALSE — a fused Select moves its
// FALSE value over the true one already in the destination.
+ (NSString*)cmovForNegatedICmp:(uint8_t)p
    {
    switch (p)
        {
    case XTIRICmpEQ:
        return @"cmovne";
    case XTIRICmpNE:
        return @"cmove";
    case XTIRICmpSLT:
        return @"cmovge";
    case XTIRICmpSGT:
        return @"cmovle";
    case XTIRICmpSLE:
        return @"cmovg";
    case XTIRICmpSGE:
        return @"cmovl";
    case XTIRICmpULT:
        return @"cmovae";
    case XTIRICmpUGT:
        return @"cmovbe";
    case XTIRICmpULE:
        return @"cmova";
    case XTIRICmpUGE:
        return @"cmovb";
        }
    return @"cmovne";
    }

+ (NSString*)jccForNegatedICmp:(uint8_t)p
    {
    switch (p)
        {
    case XTIRICmpEQ:
        return @"jne";
    case XTIRICmpNE:
        return @"je";
    case XTIRICmpSLT:
        return @"jge";
    case XTIRICmpSGT:
        return @"jle";
    case XTIRICmpSLE:
        return @"jg";
    case XTIRICmpSGE:
        return @"jl";
    case XTIRICmpULT:
        return @"jae";
    case XTIRICmpUGT:
        return @"jbe";
    case XTIRICmpULE:
        return @"ja";
    case XTIRICmpUGE:
        return @"jb";
        }
    return @"jne";
    }

// On the CFG edge from→to, copy each phi's incoming value (the one tagged with
// `from`) into the phi's own slot before the jump. These copies are PARALLEL
// (all read the pre-branch state), so a naive sequential emission is wrong when
// one copy's DEST location is another copy's SOURCE location — e.g. after an
// inner loop unrolls, `v0 <- lc4` runs alongside `lc4 <- lc4+1`, and writing
// lc4's slot first hands v0 the post-increment value (a lost copy). Detect that
// aliasing (register home OR frame slot) and, when present, snapshot every
// source onto the stack before writing any destination.
+ (NSString*)phiLocOf:(XTIRValueId)vid slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
    {
    NSString* home = sHome[@(vid)];
    if (home)
        return home; // 64-bit home reg name
    NSNumber* s = slot[@(vid)];
    return s ? [NSString stringWithFormat:@"[rbp-%@]", s] : nil;
    }

+ (void)phiEdgesFrom:(XTIRBlock*)from to:(XTIRBlock*)to fn:(XTIRFunction*)fn
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
            if (phi.operands[i].kind == XTIROperandKindBlock && phi.operands[i].blockRef == from)
                {
                XTIROperand* inc = phi.operands[i + 1];
                // vector phi
                if (phi.result.type.kind == XTIRTypeKindVec)
                    {
                    NSString* dst = sVec[@(phi.result.valueId)];
                    NSString* src = inc.kind == XTIROperandKindUse ? sVec[@(inc.valueId)] : nil;
                    if (dst && src && ![dst isEqualToString:src]) // coalesced ⇒ no-op
                        [out appendFormat:@"\tmovdqa\t%@, %@\n", dst, src];
                    break;
                    }
                [dests addObject:phi.result];
                [srcs addObject:inc];
                break;
                }
            }
        }
    if (dests.count == 0)
        return;

    // Safe iff no copy's DEST location aliases a DIFFERENT copy's SOURCE location.
    BOOL safe = YES;
    for (NSUInteger i = 0; i < dests.count && safe; i++)
        {
        NSString* dloc = [self phiLocOf:dests[i].valueId slot:slot];
        if (!dloc)
            continue;
        for (NSUInteger j = 0; j < srcs.count; j++)
            {
            if (i == j || srcs[j].kind != XTIROperandKindUse)
                continue;
            NSString* sloc = [self phiLocOf:srcs[j].valueId slot:slot];
            if (sloc && [sloc isEqualToString:dloc])
                {
                safe = NO;
                break;
                }
            }
        }
    if (safe)
        {
        for (NSUInteger i = 0; i < dests.count; i++)
            {
            [self load:srcs[i] into:'a' fn:fn slot:slot out:out];
            [self store:'a' into:dests[i] slot:slot out:out];
            }
        return;
        }
    // Aliased: read EVERY source (push) before writing ANY dest (pop reverse).
    // push/pop are 64-bit and balanced, so branch-point rsp alignment is kept.
    for (XTIROperand* s in srcs)
        {
        [self load:s into:'a' fn:fn slot:slot out:out];
        [out appendString:@"\tpush\trax\n"];
        }
    for (NSInteger i = (NSInteger)dests.count - 1; i >= 0; i--)
        {
        [out appendString:@"\tpop\trax\n"];
        [self store:'a' into:dests[i] slot:slot out:out];
        }
    }

+ (void)emitTerminator:(XTIRInsn*)t fn:(XTIRFunction*)fn block:(XTIRBlock*)blk
                  slot:(NSDictionary<NSNumber*, NSNumber*>*)slot
                 frame:(NSUInteger)frame
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
        [out appendString:@"\tud2\n"];
        return;
        }
    case XTIROpReturn:
        {
        for (XTIROperand* o in t.operands)
            {
            XTIRValue* v = o.kind == XTIROperandKindUse ? fn.values[@(o.valueId)] : nil;
            if (v && [self isMem:v])
                continue;
            if (v && v.type.kind == XTIRTypeKindAgg && sWin64SretOff)
                {
                // Hidden sret (Win64 >8B in rcx, System V >16B MEMORY class in
                // rdi): copy the result struct through the caller's pointer
                // (saved at entry), then return that pointer in rax — both
                // ABIs require rax = the sret pointer on return.
                NSNumber* s = slot[@(v.valueId)];
                [out appendFormat:@"\tmov\trax, [rbp-%ld]\n", (long)sWin64SretOff]; // dest ptr
                if (s)
                    {
                    NSUInteger q = ([self aggSize:v.type.layout] + 7) / 8;
                    for (NSUInteger k = 0; k < q; k++)
                        {
                        [out appendFormat:@"\tmov\tr10, [rbp-%ld]\n", (long)(s.integerValue - 8 * (long)k)];
                        [out appendFormat:@"\tmov\t[rax%+ld], r10\n", (long)(8 * k)];
                        }
                    }
                [out appendFormat:@"\tmov\trax, [rbp-%ld]\n", (long)sWin64SretOff]; // return the ptr
                }
            else if (v && v.type.kind == XTIRTypeKindAgg)
                [self aggToRetRegs:v slot:slot out:out]; // ≤8/≤16 in regs
            else if (v && [self isFloatVal:v])
                [self loadF:o into:@"xmm0" fn:fn slot:slot out:out];
            else
                [self load:o into:'a' fn:fn slot:slot out:out]; // → rax (xmm0 for float)
            break;
            }
        [self emitHomeRestore:out];
        if (frame)
            [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)frame];
        [out appendString:@"\tpop\trbp\n\tret\n"];
        return;
        }
    case XTIROpBranch:
        if (t.operands.count >= 1 && t.operands[0].kind == XTIROperandKindBlock)
            {
            [self phiEdgesFrom:blk to:t.operands[0].blockRef fn:fn slot:slot out:out];
            [out appendFormat:@"\tjmp\t%@\n", [self blockLabel:t.operands[0].blockRef fn:fn]];
            }
        return;
    case XTIROpCondBranch:
        {
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
        NSString* flab = [NSString stringWithFormat:@".Lf_%@_%@", fn.name, blk.name ?: @"b"];
        XTIRInsn* fcmp = blk.instructions.lastObject;
        if (cond && cond.kind == XTIROperandKindUse && sFusedCmp && [sFusedCmp containsObject:@(cond.valueId)] && fcmp && fcmp.opcode == XTIROpICmp && fcmp.result && fcmp.result.valueId == cond.valueId)
            {
            // The ICmp already emitted `cmp` and left the flags set: branch to
            // the false target on the NEGATED predicate. No boolean/test.
            [out appendFormat:@"\t%@\t%@\n", [self jccForNegatedICmp:fcmp.predicate], flab];
            }
        else
            {
            // Zero-extend the condition: a narrow (bool/u8) cond loaded as `mov al`
            // leaves stale high bits, and `test eax,eax` would then see a false
            // (0) condition as non-zero. loadZX cleans the full register first.
            NSUInteger cw = 4;
            if (cond)
                {
                [self loadZX:cond into:'a' fn:fn slot:slot out:out];
                cw = [self condWidth:cond fn:fn];
                }
            [out appendFormat:@"\ttest\t%@, %@\n", [self reg:'a' width:cw], [self reg:'a' width:cw]];
            [out appendFormat:@"\tje\t%@\n", flab]; // false → flab
            }
        if (tb)
            {
            [self phiEdgesFrom:blk to:tb fn:fn slot:slot out:out];
            [out appendFormat:@"\tjmp\t%@\n", [self blockLabel:tb fn:fn]];
            }
        [out appendFormat:@"%@:\n", flab];
        if (fb)
            {
            [self phiEdgesFrom:blk to:fb fn:fn slot:slot out:out];
            [out appendFormat:@"\tjmp\t%@\n", [self blockLabel:fb fn:fn]];
            }
        return;
        }
    default:
        [self emitHomeRestore:out];
        if (frame)
            [out appendFormat:@"\tadd\trsp, %lu\n", (unsigned long)frame];
        [out appendString:@"\tpop\trbp\n\tret\n"];
        return;
        }
    }

@end
