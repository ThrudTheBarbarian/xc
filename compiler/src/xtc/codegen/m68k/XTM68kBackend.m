/****************************************************************************\
|* XTM68kBackend.m — IR → Motorola 68000/68030 assembly (Atari ST/TT).
|*
|* Bootstrap backend. Lowering model (naive, slot-per-SSA-value):
|*   - Each function builds a LINK A6 frame.
|*   - Result SSA values live in negative frame slots; parameters live in
|*     the caller-pushed area at positive offsets (8(a6), 12(a6), …).
|*   - Each instruction loads operands into scratch data registers
|*     (D0/D1/D2), computes, and stores its result to its slot.
|*   - Calls: args pushed right-to-left as longs, result in D0, caller
|*     cleans the stack. Return value in D0.
|*   - Phi nodes are eliminated by copying the incoming value into the
|*     phi's slot in each predecessor, just before the branch.
|* No register allocation yet — correctness first.
\****************************************************************************/
#import "XTM68kBackend.h"
#import "XTAggInitRelay.h"
#import "XTIRModule.h"
#import "XTIRConstant.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"
#import "XTIRLayout.h"
#import "XTHomingAllocator.h"

static int gLabelSeq;   // unique local-label counter (reset per module)
static BOOL gHardFloat; // 68881 FPU codegen vs soft-float (set per module)
static BOOL gPic;       // -mpic: GOT/a5 model for base-68000 >32KB programs

// Register homing (set per function). A homed value lives in a data register
// and is single-written there (its frame slot is NOT mirrored — the direct-slot
// readers, stack-passed Agg/F64 args and float ops, consume only un-homed
// values). Two tiers: d5-d7 are callee-saved (persisted across the function,
// saved to reserved frame slots in the prologue, restored before each rts);
// d3-d4 are caller-saved (used only for values that cross no call, so the
// hand-written helpers' d3/d4 clobbers — __udivmod/__print_u32/__fmt_double —
// are harmless and no save/restore is emitted). d0-d2 stay scratch.
static NSDictionary<NSNumber*, NSString*>* gHome = nil;        // valueId → "dN"
static NSArray<NSString*>* gHomeSaves = nil;                   // used callee-saved regs
static NSDictionary<NSString*, NSNumber*>* gHomeSaveOff = nil; // reg → a6-relative slot
// Compare-and-branch fusion: ICmp result-ids that are a block's last insn and
// feed only that block's CondBranch. Their emission stops after `cmp` (flags
// left set) and the CondBranch branches on the predicate directly.
static NSSet<NSNumber*>* gFusedCmp = nil;
// Address folding: ElementAddr/FieldAddr result-id → the addr insn, when it is
// single-use by an immediately-following scalar Load/Store. The addr op is
// elided and folded into the memory operand — `(a0,dN.l*s)` for a scaled array
// index (68020+), `off(a0)` for a struct field.
static NSDictionary<NSNumber*, XTIRInsn*>* gFold = nil;
// Pointer-IV address-register homing: the walking pointer produced by
// XTIROptPointerIV — a Ptr phi `p` whose back-edge is `pNext = ElementAddr(p,
// step)` — homes in an address register a2-a4 and walks in place. Both `p` and
// `pNext` map to the SAME register (gPtrAReg). The advance insn is deferred to
// the end of its block (after the loads that read the pre-advance pointer) and
// emitted as an in-place `adda` (gPtrAdvance: pNext-id → byte displacement).
// Only formed when every use of `p` is an address base (Load/Store/foldable
// ElementAddr) or the advance — never a value — so the in-place walk is safe.
static NSDictionary<NSNumber*, NSString*>* gPtrAReg = nil;    // p & pNext valueId → "aN"
static NSDictionary<NSNumber*, NSNumber*>* gPtrAdvance = nil; // pNext valueId → byte disp
static NSDictionary<NSNumber*, XTIROperand*>* gPtrBase = nil; // p valueId → PH-edge base
static NSArray<NSString*>* gPtrARegSaves = nil;               // used a2-a4 (callee-saved)
static NSDictionary<NSString*, NSNumber*>* gPtrARegSaveOff = nil;

@implementation XTM68kBackend

+ (NSString*)assemblyFromModule:(XTIRModule*)mod
    {
    return [self assemblyFromModule:mod cpu:68000 hardFloat:NO pic:NO];
    }
+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu
    {
    return [self assemblyFromModule:mod cpu:cpu hardFloat:NO pic:NO];
    }
+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu
                      hardFloat:(BOOL)hardFloat
    {
    return [self assemblyFromModule:mod cpu:cpu hardFloat:hardFloat pic:NO];
    }

// A global (or function) named a0-a7/d0-d7/sp/pc/sr/ccr/usp/fp0-fp7 assembles
// as the REGISTER, not the symbol: the assembler's parseOperand tries register
// names first, as Motorola syntax requires, so `lea a1,a0` silently used
// address-register a1 and every access to the array went through whatever it
// happened to hold (found by tests/fixtures/vectorize_runtime_start.xc, whose
// arrays are named a1/a2/a3). Reserved names get a trailing '$': user
// identifiers cannot contain '$', and the method-mangled forms are
// `Class$sel` — never `name$` with nothing after it — so the suffix cannot
// collide with anything else the module emits. Label and every reference go
// through this one function, so the renaming is self-consistent.
static NSString* m68kSym(NSString* name)
    {
    static NSSet<NSString*>* reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableSet* r = [NSMutableSet setWithArray:@[ @"sp", @"pc", @"sr",
                                                      @"ccr", @"usp" ]];
      for (int i = 0; i < 8; i++)
          {
          [r addObject:[NSString stringWithFormat:@"a%d", i]];
          [r addObject:[NSString stringWithFormat:@"d%d", i]];
          [r addObject:[NSString stringWithFormat:@"fp%d", i]];
          }
      reserved = r;
    });
    if (!name || ![reserved containsObject:name.lowercaseString])
        return name;
    return [name stringByAppendingString:@"$"];
    }

+ (NSString*)assemblyFromModule:(XTIRModule*)mod cpu:(NSInteger)cpu
                      hardFloat:(BOOL)hardFloat
                            pic:(BOOL)pic
    {
    gLabelSeq = 0;
    gHardFloat = hardFloat;
    // GOT/a5 model only matters on the 68000 (68020+ has 32-bit PC-relative,
    // which is zero-relocation PIC and has no size limit).
    gPic = pic && cpu < 68020;
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"; xtcg-68k — Atari ST/TT (m%ld) assembly\n", (long)cpu];
    [out appendFormat:@"; module \"%@\"\n\n", mod.name];
    [out appendString:@"\t.text\n\n"];

    // crt0: GEMDOS enters at the first byte of TEXT, so when a `main`
    // exists emit a tiny entry wrapper first — call main, then Pterm with
    // its return value as the process exit code.
    BOOL hasMain = NO;
    for (XTIRFunction* fn in mod.functions)
        if ([fn.name isEqualToString:@"main"])
            {
            hasMain = YES;
            break;
            }
    if (hasMain)
        {
        [out appendString:@"\t.globl\t_start\n_start:\n"];
        // MiNT/GEMDOS well-behaved startup: Mshrink the TPA down to
        // basepage + text + data + bss + a stack reserve, releasing the rest
        // so the OS can reuse it (essential under MiNT multitasking). Set our
        // own stack at the top of the kept region; the heap comes from
        // Malloc, above it. The basepage ptr is at 4(sp) on entry.
        [out appendString:@"\tmove.l\t4(sp),a0\n"];                               // a0 = basepage
        [out appendString:@"\tmove.l\t12(a0),d0\n"];                              // p_tlen
        [out appendString:@"\tadd.l\t20(a0),d0\n"];                               // + p_dlen
        [out appendString:@"\tadd.l\t28(a0),d0\n"];                               // + p_blen
        [out appendString:@"\tadd.l\t#$4100,d0\n"];                               // + basepage(256) + 16K stack
        [out appendString:@"\tmove.l\ta0,d1\n\tadd.l\td0,d1\n\tmove.l\td1,sp\n"]; // SP = top of kept region
        [out appendString:@"\tmove.l\td0,-(sp)\n\tmove.l\ta0,-(sp)\n\tclr.w\t-(sp)\n"
                          @"\tmove.w\t#$4a,-(sp)\n\ttrap\t#1\n\tlea\t12(sp),sp\n"]; // Mshrink(0,bp,keep)
        if (gPic)
            {
            // GOT/a5 setup: capture the runtime PC (bsr pushes it), then point
            // a5 at the GOT via a link-time-constant offset — no relocation.
            [out appendString:@"\tbsr\t.Lpicpc\n.Lpicpc:\n\tmove.l\t(sp)+,a5\n"
                              @"\tadd.l\t#_GOT-.Lpicpc,a5\n"];
            }
        [out appendString:@"\tjsr\tmain\n"];
        [out appendString:@"\tmove.w\td0,-(sp)\t; exit code\n"];
        [out appendString:@"\tmove.w\t#$4c,-(sp)\t; Pterm\n"];
        [out appendString:@"\ttrap\t#1\n\n"];
        }

    for (XTIRFunction* fn in mod.functions)
        {
        [self emitFunction:fn mod:mod cpu:cpu into:out];
        [out appendString:@"\n"];
        }

    [self emitRuntimeStubs:mod into:out];
    [self emitDataSection:mod into:out];
    return out;
    }

// Emit string literals + data globals as labelled, relocatable data after
// the code (GEMDOS folds TEXT+DATA contiguously, so a single segment with
// relocations is fine). Execution never reaches here — every function ends
// in rts.
+ (void)appendBytes:(NSData*)data into:(NSMutableString*)out
    {
    const uint8_t* b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i += 12)
        {
        [out appendString:@"\t.dc.b\t"];
        for (NSUInteger j = i; j < data.length && j < i + 12; j++)
            [out appendFormat:@"%@$%02X", j > i ? @"," : @"", b[j]];
        [out appendString:@"\n"];
        }
    }
+ (void)emitDataSection:(XTIRModule*)mod into:(NSMutableString*)out
    {
    // Initialized data (strings, vtables, initialized globals) -> .data;
    // uninitialized globals -> .bss (size only, the loader zeroes it, keeping
    // them out of the $601A file). Both follow the .text code.
    BOOL anyData = NO;
    NSMutableString* bss = [NSMutableString string];
    for (XTIRSymbol* s in mod.symbols)
        {
        if (s.kind == XTIRSymbolKindStringLit && s.stringBytes)
            {
            if (!anyData)
                {
                [out appendString:@"\n; ── data ──\n\t.data\n\t.even\n"];
                anyData = YES;
                }
            [out appendFormat:@"%@:\n", m68kSym(s.name)];
            [self appendBytes:s.stringBytes into:out];
            }
        else if (s.kind == XTIRSymbolKindVTable)
            {
            if (!anyData)
                {
                [out appendString:@"\n; ── data ──\n\t.data\n\t.even\n"];
                anyData = YES;
                }
            [out appendFormat:@"\t.even\n%@:\n", m68kSym(s.name)];
            for (NSString* entry in s.vtableEntryNames)
                {
                // Empty slots ("_" / nil) must still occupy 4 bytes so the
                // method-slot offsets the dispatcher uses stay correct.
                // PIC: store method-minus-vtable-base (a relocation-free
                // offset); the dispatcher adds it back to the vtable address.
                //
                // ⚠ A slot holds an OFFSET, not an address — so "empty slot"
                // and "null method" are NOT the same bit pattern here. An
                // empty slot is offset 0, and base + 0 == vtable_base, a
                // bogus NON-NULL address. Anything that reads a slot as a
                // VALUE (rather than dispatching through it) must therefore
                // test the offset for zero BEFORE adding the base. VTblLoad
                // — which backs `&obj.method`, where a null result is exactly
                // how an unimplemented `optional` method reports itself —
                // does; see XTIROpVTblLoad below and
                // private:docs/Design/bound-methods.md.
                BOOL empty = entry.length == 0 || [entry isEqualToString:@"_"];
                if (empty)
                    [out appendString:@"\t.dc.l\t0\n"];
                else
                    [out appendFormat:@"\t.dc.l\t%@-%@\n", m68kSym(entry), m68kSym(s.name)];
                }
            }
        else if (s.kind == XTIRSymbolKindDataGlobal)
            {
            // Size by the larger of the m68k width and the IR byteWidth. The
            // m68k width fixes a Ptr (canonical byteWidth 0/2 -> 4) and an Agg
            // with pointer fields; the byteWidth covers an opaque buffer like
            // __xtc_va_buf, whose declared size (128) exceeds its layout's
            // field-sum. Using only one under-sized a global and made
            // neighbours overlap.
            uint32_t w = 1;
            if (s.globalType)
                {
                uint32_t mw = (uint32_t)[self m68kFieldWidth:s.globalType];
                uint32_t bw = s.globalType.byteWidth;
                w = mw > bw ? mw : bw;
                }
            if (s.initialBytes)
                {
                if (!anyData)
                    {
                    [out appendString:@"\n; ── data ──\n\t.data\n\t.even\n"];
                    anyData = YES;
                    }
                [out appendFormat:@"\t.even\n%@:\n", m68kSym(s.name)];
                // The IR stores a scalar initialiser in its canonical
                // little-endian order; m68k is big-endian, so reverse a scalar
                // integer's bytes (u16/i16/u32/i32) before emitting. Strings /
                // aggregates / pointers keep their byte order.
                NSData* bytes = s.initialBytes;
                XTIRTypeKind gk = s.globalType ? s.globalType.kind : XTIRTypeKindVoid;
                BOOL scalarInt = (gk == XTIRTypeKindI16 || gk == XTIRTypeKindU16 ||
                                  gk == XTIRTypeKindI32 || gk == XTIRTypeKindU32);
                if (scalarInt && (bytes.length == 2 || bytes.length == 4))
                    {
                    NSMutableData* r = [NSMutableData dataWithLength:bytes.length];
                    const uint8_t* src = bytes.bytes;
                    uint8_t* dst = r.mutableBytes;
                    for (NSUInteger k = 0; k < bytes.length; k++)
                        dst[k] = src[bytes.length - 1 - k];
                    bytes = r;
                    }
                else if (gk == XTIRTypeKindF32 && bytes.length == 8)
                    {
                    // Float initialiser is stored as 8 little-endian double bits;
                    // narrow to IEEE single and emit big-endian (4 bytes).
                    const uint8_t* p = bytes.bytes;
                    uint64_t lo = 0;
                    for (int k = 0; k < 8; k++)
                        lo |= (uint64_t)p[k] << (8 * k);
                    double dv;
                    memcpy(&dv, &lo, 8);
                    float fv = (float)dv;
                    uint32_t fb;
                    memcpy(&fb, &fv, 4);
                    NSMutableData* r = [NSMutableData dataWithLength:4];
                    uint8_t* dst = r.mutableBytes;
                    dst[0] = (fb >> 24) & 0xFF;
                    dst[1] = (fb >> 16) & 0xFF;
                    dst[2] = (fb >> 8) & 0xFF;
                    dst[3] = fb & 0xFF;
                    bytes = r;
                    }
                else if (gk == XTIRTypeKindF64 && bytes.length == 8)
                    {
                    NSMutableData* r = [NSMutableData dataWithLength:8];
                    const uint8_t* src = bytes.bytes;
                    uint8_t* dst = r.mutableBytes;
                    for (NSUInteger k = 0; k < 8; k++)
                        dst[k] = src[7 - k];
                    bytes = r;
                    }
                else if (gk == XTIRTypeKindAgg && s.globalType.layout)
                    {
                    // The image is laid out per the IR layout and is
                    // little-endian; m68k lays fields out with its own widths
                    // (Ptr → 4) and is big-endian. Re-lay it into ours.
                    bytes = [XTAggInitRelay relay:bytes
                                           layout:s.globalType.layout
                                      widthOfLeaf:^NSUInteger(XTIRType* t) {
                                        return [XTM68kBackend m68kFieldWidth:t];
                                      }
                                        bigEndian:YES];
                    }
                else if (gk == XTIRTypeKindPtr)
                    {
                    // A pointer initialiser arrives at the target's canonical
                    // width (3 bytes on atarist), but an m68k pointer is 4 and
                    // is read as a big-endian long. Zero-extend to 4, then
                    // reverse. The scalarInt branch above can't do it: it only
                    // knows the fixed integer kinds, and Ptr's IR byteWidth is 0.
                    NSMutableData* r = [NSMutableData dataWithLength:w];
                    uint8_t* dst = r.mutableBytes;
                    const uint8_t* src = bytes.bytes;
                    for (NSUInteger k = 0; k < bytes.length && k < w; k++)
                        dst[k] = src[k]; // little-endian in
                    // → big-endian out
                    for (NSUInteger k = 0; k < w / 2; k++)
                        {
                        uint8_t t = dst[k];
                        dst[k] = dst[w - 1 - k];
                        dst[w - 1 - k] = t;
                        }
                    bytes = r;
                    }
                // Zero-fill up to the reserved width. The payload can be
                // narrower than the slot the rest of codegen reads — a
                // 3-byte pointer initialiser in a 4-byte pointer, say — and
                // emitting only the payload let the NEXT symbol's first byte
                // become part of this one. `u8@ nul = 0;` then read back as
                // $00000069 (the 'i' of a following string literal) and
                // `nul == 0` was false. It only showed up when the neighbour
                // was a symbol that doesn't force alignment, which is why the
                // 68000 and 68030 builds of identical source disagreed.
                if (bytes.length < w)
                    {
                    NSMutableData* padded = [bytes mutableCopy];
                    [padded increaseLengthBy:w - bytes.length];
                    bytes = padded;
                    }
                [self appendBytes:bytes into:out];
                }
            else if (gPic)
                {
                // GOT mode keeps a single contiguous in-file image (the GOT
                // is appended after data, relocated), so uninitialized globals
                // stay in .data as zeroed storage rather than a separate .bss.
                if (!anyData)
                    {
                    [out appendString:@"\n; ── data ──\n\t.data\n\t.even\n"];
                    anyData = YES;
                    }
                [out appendFormat:@"\t.even\n%@:\n\t.space\t%u\n", m68kSym(s.name), w];
                }
            else
                {
                [bss appendFormat:@"\t.even\n%@:\n\t.space\t%u\n", m68kSym(s.name), w];
                }
            }
        }
    // (The weak side-table is gone — the intrusive list threads through the
    // slots themselves, so there is no table to reserve. See emitRuntime.)
    // _xtc_bank region table: regions[3 types][256 idx] of 4-byte pointers,
    // zero-initialised (the lazy-alloc check keys off NULL).
    if ([out containsString:@"_xtc_bank_regions"])
        {
        NSString* tbl = @"\t.even\n_xtc_bank_regions:\n\t.space\t3072\n";
        if (gPic)
            {
            if (!anyData)
                {
                [out appendString:@"\n; ── data ──\n\t.data\n\t.even\n"];
                }
            [out appendString:tbl];
            }
        else
            {
            [bss appendString:tbl];
            }
        }
    if (bss.length)
        {
        [out appendString:@"\n; ── bss ──\n\t.bss\n"];
        [out appendString:bss];
        }
    }

// Collect the set of called symbol names across the module.
+ (NSSet<NSString*>*)calledSymbolsIn:(XTIRModule*)mod
    {
    NSMutableSet* names = [NSMutableSet set];
    for (XTIRFunction* fn in mod.functions)
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* insn in bb.instructions)
                if (insn.opcode == XTIROpCall)
                    {
                    XTIROperand* c = insn.operands.firstObject;
                    if (c.kind == XTIROperandKindSym)
                        {
                        XTIRSymbol* s = [mod symbolForId:c.symbolId];
                        if (s.name)
                            [names addObject:s.name];
                        }
                    }
    return names;
    }

// Emit the GEMDOS-backed runtime helpers the program references but that
// have no IR body (the host runtime on arm64 / xt6502). `_putc` is the
// console-output primitive every Stdio path bottoms out at.
+ (void)emitRuntimeStubs:(XTIRModule*)mod into:(NSMutableString*)out
    {
    // Helpers are referenced as `jsr <name>` either by an IR Call (_putc)
    // or introduced by the backend during lowering (__mulsi3, …). Detect by
    // scanning the already-emitted code (stubs are appended after, so their
    // own labels aren't present yet).
    NSSet* defined = [NSSet setWithArray:[mod.functions valueForKey:@"name"]];
    BOOL (^used)(NSString*) = ^BOOL(NSString* name) {
      return [out containsString:[NSString stringWithFormat:@"jsr\t%@\n", name]];
    };
    if (used(@"_putc") && ![defined containsObject:@"_putc"])
        {
        [out appendString:@"; runtime: _putc(u8) -> GEMDOS Cconout\n"];
        [out appendString:@"\t.globl\t_putc\n_putc:\n"];
        [out appendString:@"\tmove.l\t4(sp),d0\n"];
        [out appendString:@"\tmove.w\td0,-(sp)\n"];
        [out appendString:@"\tmove.w\t#2,-(sp)\t; Cconout\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#4,sp\n"];
        [out appendString:@"\trts\n\n"];
        }

    // The GEMDOS runtime behind support/generic/lib/Files.xc and Process.xc
    // (bugs 127/128). Generated from ONE text (scratch filestubs2.py) with the
    // self-hosted twin in M68k.xc, so the two cannot drift. Each stub only when
    // referenced, and never when the module defines the name itself.
    if (used(@"_xt_file_open") && ![defined containsObject:@"_xt_file_open"])
        {
        [out appendString:@"; runtime: _xt_file_open(path, mode) -> handle, <0 on failure : GEMDOS Fopen/Fcreate\n"];
        [out appendString:@"\t.globl\t_xt_file_open\n"];
        [out appendString:@"_xt_file_open:\n"];
        [out appendString:@"\tmove.l\td3,-(sp)\n"];
        [out appendString:@"\tmove.l\t12(sp),a0\t\t; mode string\n"];
        [out appendString:@"\tmove.b\t(a0),d3\t\t\t; first byte: r / w / a\n"];
        [out appendString:@"\tmoveq\t#119,d1\t\t\t; 'w' -> create (truncate)\n"];
        [out appendString:@"\tcmp.b\td1,d3\n"];
        [out appendString:@"\tbeq\t.xfo_create\n"];
        [out appendString:@"\tmoveq\t#0,d2\t\t\t; 'r' -> read-only\n"];
        [out appendString:@"\tmove.b\t1(a0),d1\n"];
        [out appendString:@"\tmoveq\t#43,d0\t\t\t; '+' -> read/write\n"];
        [out appendString:@"\tcmp.b\td0,d1\n"];
        [out appendString:@"\tbne\t.xfo_m1\n"];
        [out appendString:@"\tmoveq\t#2,d2\n"];
        [out appendString:@".xfo_m1:\n"];
        [out appendString:@"\tmoveq\t#97,d1\t\t\t; 'a' -> read/write, then seek to the end\n"];
        [out appendString:@"\tcmp.b\td1,d3\n"];
        [out appendString:@"\tbne\t.xfo_m2\n"];
        [out appendString:@"\tmoveq\t#2,d2\n"];
        [out appendString:@".xfo_m2:\n"];
        [out appendString:@"\tmove.w\td2,-(sp)\t\t; mode\n"];
        [out appendString:@"\tmove.l\t10(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$3D,-(sp)\t\t; Fopen\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#8,sp\n"];
        [out appendString:@"\tmoveq\t#97,d1\n"];
        [out appendString:@"\tcmp.b\td1,d3\n"];
        [out appendString:@"\tbne\t.xfo_done\n"];
        [out appendString:@"\tmove.l\td0,d0\t\t\t; append to a missing file -> create it\n"];
        [out appendString:@"\tbmi\t.xfo_create\n"];
        [out appendString:@"\tmove.l\td0,d3\t\t\t; handle\n"];
        [out appendString:@"\tmove.w\t#2,-(sp)\t\t; SEEK_END\n"];
        [out appendString:@"\tmove.w\td3,-(sp)\n"];
        [out appendString:@"\tmove.l\t#0,-(sp)\t\t; offset 0\n"];
        [out appendString:@"\tmove.w\t#$42,-(sp)\t\t; Fseek\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\tlea\t10(sp),sp\n"];
        [out appendString:@"\tmove.l\td3,d0\n"];
        [out appendString:@"\tbra\t.xfo_done\n"];
        [out appendString:@".xfo_create:\n"];
        [out appendString:@"\tmove.w\t#0,-(sp)\t\t; attributes\n"];
        [out appendString:@"\tmove.l\t10(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$3C,-(sp)\t\t; Fcreate\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#8,sp\n"];
        [out appendString:@".xfo_done:\n"];
        [out appendString:@"\tmove.l\t(sp)+,d3\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_read") && ![defined containsObject:@"_xt_file_read"])
        {
        [out appendString:@"; runtime: _xt_file_read(handle, buf, n) -> bytes read, <0 on failure : GEMDOS Fread\n"];
        [out appendString:@"\t.globl\t_xt_file_read\n"];
        [out appendString:@"_xt_file_read:\n"];
        [out appendString:@"\tmove.l\t8(sp),-(sp)\t\t; buf\n"];
        [out appendString:@"\tmove.l\t16(sp),-(sp)\t\t; n\n"];
        [out appendString:@"\tmove.w\t14(sp),-(sp)\t\t; handle\n"];
        [out appendString:@"\tmove.w\t#$3F,-(sp)\t\t; Fread\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\tlea\t12(sp),sp\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_write") && ![defined containsObject:@"_xt_file_write"])
        {
        [out appendString:@"; runtime: _xt_file_write(handle, buf, n) -> bytes written, <0 on failure : GEMDOS Fwrite\n"];
        [out appendString:@"\t.globl\t_xt_file_write\n"];
        [out appendString:@"_xt_file_write:\n"];
        [out appendString:@"\tmove.l\t8(sp),-(sp)\t\t; buf\n"];
        [out appendString:@"\tmove.l\t16(sp),-(sp)\t\t; n\n"];
        [out appendString:@"\tmove.w\t14(sp),-(sp)\t\t; handle\n"];
        [out appendString:@"\tmove.w\t#$40,-(sp)\t\t; Fwrite\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\tlea\t12(sp),sp\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_close") && ![defined containsObject:@"_xt_file_close"])
        {
        [out appendString:@"; runtime: _xt_file_close(handle) : GEMDOS Fclose\n"];
        [out appendString:@"\t.globl\t_xt_file_close\n"];
        [out appendString:@"_xt_file_close:\n"];
        [out appendString:@"\tmove.w\t6(sp),-(sp)\t\t; handle\n"];
        [out appendString:@"\tmove.w\t#$3E,-(sp)\t\t; Fclose\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#4,sp\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_size") && ![defined containsObject:@"_xt_file_size"])
        {
        [out appendString:@"; runtime: _xt_file_size(path) -> bytes, -1 when it cannot be opened : Fopen/Fseek/Fclose\n"];
        [out appendString:@"\t.globl\t_xt_file_size\n"];
        [out appendString:@"_xt_file_size:\n"];
        [out appendString:@"\tmove.l\td3,-(sp)\n"];
        [out appendString:@"\tmove.w\t#0,-(sp)\t\t; read-only\n"];
        [out appendString:@"\tmove.l\t10(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$3D,-(sp)\t\t; Fopen\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#8,sp\n"];
        [out appendString:@"\tmove.l\td0,d0\n"];
        [out appendString:@"\tbmi\t.xfz_fail\n"];
        [out appendString:@"\tmove.l\td0,d3\t\t\t; handle\n"];
        [out appendString:@"\tmove.w\t#2,-(sp)\t\t; SEEK_END\n"];
        [out appendString:@"\tmove.w\td3,-(sp)\n"];
        [out appendString:@"\tmove.l\t#0,-(sp)\t\t; offset 0\n"];
        [out appendString:@"\tmove.w\t#$42,-(sp)\t\t; Fseek -> d0 = size\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\tlea\t10(sp),sp\n"];
        [out appendString:@"\tmove.l\td0,-(sp)\t\t; keep the size across Fclose\n"];
        [out appendString:@"\tmove.w\td3,-(sp)\n"];
        [out appendString:@"\tmove.w\t#$3E,-(sp)\t\t; Fclose\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#4,sp\n"];
        [out appendString:@"\tmove.l\t(sp)+,d0\n"];
        [out appendString:@"\tbra\t.xfz_done\n"];
        [out appendString:@".xfz_fail:\n"];
        [out appendString:@"\tmoveq\t#-1,d0\n"];
        [out appendString:@".xfz_done:\n"];
        [out appendString:@"\tmove.l\t(sp)+,d3\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_exists") && ![defined containsObject:@"_xt_file_exists"])
        {
        [out appendString:@"; runtime: _xt_file_exists(path) -> 1 / 0 : Fopen read-only, Fclose\n"];
        [out appendString:@"\t.globl\t_xt_file_exists\n"];
        [out appendString:@"_xt_file_exists:\n"];
        [out appendString:@"\tmove.w\t#0,-(sp)\t\t; read-only\n"];
        [out appendString:@"\tmove.l\t6(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$3D,-(sp)\t\t; Fopen\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#8,sp\n"];
        [out appendString:@"\tmove.l\td0,d0\n"];
        [out appendString:@"\tbmi\t.xfe_no\n"];
        [out appendString:@"\tmove.w\td0,-(sp)\n"];
        [out appendString:@"\tmove.w\t#$3E,-(sp)\t\t; Fclose\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#4,sp\n"];
        [out appendString:@"\tmoveq\t#1,d0\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@".xfe_no:\n"];
        [out appendString:@"\tmoveq\t#0,d0\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_exists_exact") && ![defined containsObject:@"_xt_file_exists_exact"])
        {
        [out appendString:@"; runtime: _xt_file_exists_exact(path) -> 1 / 0 : TOS names are case-insensitive, same answer as exists\n"];
        [out appendString:@"\t.globl\t_xt_file_exists_exact\n"];
        [out appendString:@"_xt_file_exists_exact:\n"];
        [out appendString:@"\tmove.w\t#0,-(sp)\t\t; read-only\n"];
        [out appendString:@"\tmove.l\t6(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$3D,-(sp)\t\t; Fopen\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#8,sp\n"];
        [out appendString:@"\tmove.l\td0,d0\n"];
        [out appendString:@"\tbmi\t.xfx_no\n"];
        [out appendString:@"\tmove.w\td0,-(sp)\n"];
        [out appendString:@"\tmove.w\t#$3E,-(sp)\t\t; Fclose\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#4,sp\n"];
        [out appendString:@"\tmoveq\t#1,d0\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@".xfx_no:\n"];
        [out appendString:@"\tmoveq\t#0,d0\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_file_chmod_exec") && ![defined containsObject:@"_xt_file_chmod_exec"])
        {
        [out appendString:@"; runtime: _xt_file_chmod_exec(path) -> 0 : TOS has no execute bit\n"];
        [out appendString:@"\t.globl\t_xt_file_chmod_exec\n"];
        [out appendString:@"_xt_file_chmod_exec:\n"];
        [out appendString:@"\tmoveq\t#0,d0\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_mkdir") && ![defined containsObject:@"_xt_mkdir"])
        {
        [out appendString:@"; runtime: _xt_mkdir(path) -> 0 on success, <0 on failure : GEMDOS Dcreate\n"];
        [out appendString:@"\t.globl\t_xt_mkdir\n"];
        [out appendString:@"_xt_mkdir:\n"];
        [out appendString:@"\tmove.l\t4(sp),-(sp)\t\t; path\n"];
        [out appendString:@"\tmove.w\t#$39,-(sp)\t\t; Dcreate\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\taddq.l\t#6,sp\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_exit") && ![defined containsObject:@"_xt_exit"])
        {
        [out appendString:@"; runtime: _xt_exit(code) : GEMDOS Pterm, never returns\n"];
        [out appendString:@"\t.globl\t_xt_exit\n"];
        [out appendString:@"_xt_exit:\n"];
        [out appendString:@"\tmove.w\t6(sp),-(sp)\t\t; low word of the code\n"];
        [out appendString:@"\tmove.w\t#$4C,-(sp)\t\t; Pterm\n"];
        [out appendString:@"\ttrap\t#1\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_argc") && ![defined containsObject:@"_xt_argc"])
        {
        [out appendString:@"; runtime: _xt_argc() -> 1 + words on the GEMDOS command line (argv[0] is the name TOS does not pass)\n"];
        [out appendString:@"; The basepage sits 256 bytes before TEXT, so no startup storage is needed to find\n"];
        [out appendString:@"; it. A NUL is a separator like a space — _xt_argv writes them in place — and only\n"];
        [out appendString:@"; the length byte ends the line.\n"];
        [out appendString:@"\t.globl\t_xt_argc\n"];
        [out appendString:@"_xt_argc:\n"];
        [out appendString:@"\tmove.l\td3,-(sp)\n"];
        [out appendString:@"\tlea\t_start,a0\n"];
        [out appendString:@"\tlea\t-256(a0),a0\t\t; basepage\n"];
        [out appendString:@"\tmoveq\t#0,d1\n"];
        [out appendString:@"\tmove.b\t128(a0),d1\t\t; command-line length\n"];
        [out appendString:@"\tlea\t129(a0),a0\t\t; its first byte\n"];
        [out appendString:@"\tmoveq\t#0,d0\t\t\t; words so far\n"];
        [out appendString:@"\tmoveq\t#32,d2\t\t\t; ' '\n"];
        [out appendString:@".xac_skip:\n"];
        [out appendString:@"\tmove.l\td1,d1\n"];
        [out appendString:@"\tbeq\t.xac_done\n"];
        [out appendString:@"\tmove.b\t(a0),d3\n"];
        [out appendString:@"\tbeq\t.xac_sep\n"];
        [out appendString:@"\tcmp.b\td2,d3\n"];
        [out appendString:@"\tbne\t.xac_word\n"];
        [out appendString:@".xac_sep:\n"];
        [out appendString:@"\taddq.l\t#1,a0\n"];
        [out appendString:@"\tsubq.l\t#1,d1\n"];
        [out appendString:@"\tbra\t.xac_skip\n"];
        [out appendString:@".xac_word:\n"];
        [out appendString:@"\taddq.l\t#1,d0\n"];
        [out appendString:@".xac_in:\n"];
        [out appendString:@"\tmove.l\td1,d1\n"];
        [out appendString:@"\tbeq\t.xac_done\n"];
        [out appendString:@"\tmove.b\t(a0),d3\n"];
        [out appendString:@"\tbeq\t.xac_skip\n"];
        [out appendString:@"\tcmp.b\td2,d3\n"];
        [out appendString:@"\tbeq\t.xac_skip\n"];
        [out appendString:@"\taddq.l\t#1,a0\n"];
        [out appendString:@"\tsubq.l\t#1,d1\n"];
        [out appendString:@"\tbra\t.xac_in\n"];
        [out appendString:@".xac_done:\n"];
        [out appendString:@"\taddq.l\t#1,d0\t\t\t; + argv[0]\n"];
        [out appendString:@"\tmove.l\t(sp)+,d3\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@"\n"];
        }
    if (used(@"_xt_argv") && ![defined containsObject:@"_xt_argv"])
        {
        [out appendString:@"; runtime: _xt_argv(i) -> the i-th word, NUL-terminated IN PLACE in the basepage's line; \"\" when out of range\n"];
        [out appendString:@"\t.globl\t_xt_argv\n"];
        [out appendString:@"_xt_argv:\n"];
        [out appendString:@"\tmove.l\td3,-(sp)\n"];
        [out appendString:@"\tmove.l\t8(sp),d0\t\t; index\n"];
        [out appendString:@"\tlea\t_start,a0\n"];
        [out appendString:@"\tlea\t-256(a0),a0\t\t; basepage\n"];
        [out appendString:@"\tmoveq\t#0,d1\n"];
        [out appendString:@"\tmove.b\t128(a0),d1\t\t; command-line length\n"];
        [out appendString:@"\tlea\t129(a0),a0\n"];
        [out appendString:@"\tmoveq\t#32,d2\t\t\t; ' '\n"];
        [out appendString:@"\tmove.l\td0,d0\n"];
        [out appendString:@"\tbeq\t.xav_empty\t\t; argv[0]: TOS passes no program name\n"];
        [out appendString:@"\tbmi\t.xav_empty\n"];
        [out appendString:@".xav_skip:\n"];
        [out appendString:@"\tmove.l\td1,d1\n"];
        [out appendString:@"\tbeq\t.xav_empty\n"];
        [out appendString:@"\tmove.b\t(a0),d3\n"];
        [out appendString:@"\tbeq\t.xav_sep\n"];
        [out appendString:@"\tcmp.b\td2,d3\n"];
        [out appendString:@"\tbne\t.xav_word\n"];
        [out appendString:@".xav_sep:\n"];
        [out appendString:@"\taddq.l\t#1,a0\n"];
        [out appendString:@"\tsubq.l\t#1,d1\n"];
        [out appendString:@"\tbra\t.xav_skip\n"];
        [out appendString:@".xav_word:\n"];
        [out appendString:@"\tsubq.l\t#1,d0\n"];
        [out appendString:@"\tbeq\t.xav_found\n"];
        [out appendString:@".xav_in:\n"];
        [out appendString:@"\tmove.l\td1,d1\n"];
        [out appendString:@"\tbeq\t.xav_empty\n"];
        [out appendString:@"\tmove.b\t(a0),d3\n"];
        [out appendString:@"\tbeq\t.xav_skip\n"];
        [out appendString:@"\tcmp.b\td2,d3\n"];
        [out appendString:@"\tbeq\t.xav_skip\n"];
        [out appendString:@"\taddq.l\t#1,a0\n"];
        [out appendString:@"\tsubq.l\t#1,d1\n"];
        [out appendString:@"\tbra\t.xav_in\n"];
        [out appendString:@".xav_found:\n"];
        [out appendString:@"\tmove.l\ta0,-(sp)\t\t; the word's start\n"];
        [out appendString:@".xav_end:\n"];
        [out appendString:@"\tmove.l\td1,d1\n"];
        [out appendString:@"\tbeq\t.xav_term\n"];
        [out appendString:@"\tmove.b\t(a0),d3\n"];
        [out appendString:@"\tbeq\t.xav_ret\t\t; already terminated by an earlier call\n"];
        [out appendString:@"\tcmp.b\td2,d3\n"];
        [out appendString:@"\tbeq\t.xav_term\n"];
        [out appendString:@"\taddq.l\t#1,a0\n"];
        [out appendString:@"\tsubq.l\t#1,d1\n"];
        [out appendString:@"\tbra\t.xav_end\n"];
        [out appendString:@".xav_term:\n"];
        [out appendString:@"\tmove.b\t#0,(a0)\t\t\t; the delimiter (or the byte past a <=124-byte line, still inside the field)\n"];
        [out appendString:@".xav_ret:\n"];
        [out appendString:@"\tmove.l\t(sp)+,d0\n"];
        [out appendString:@"\tmove.l\t(sp)+,d3\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@".xav_empty:\n"];
        [out appendString:@"\tlea\t.xav_nul,a0\n"];
        [out appendString:@"\tmove.l\ta0,d0\n"];
        [out appendString:@"\tmove.l\t(sp)+,d3\n"];
        [out appendString:@"\trts\n"];
        [out appendString:@".xav_nul:\n"];
        [out appendString:@"\t.dc.l\t0\n"];
        [out appendString:@"\n"];
        }

    // 68000 32-bit integer helpers (register ABI: args in d0/d1, result in
    // d0; may clobber d1-d5). On 68030 the backend uses muls.l/divs.l
    // inline, so these are only pulled in for -A m68k.
    // Per-class allocators: _xtc_new_<Class>(count, size) -> count*size
    // bytes from the GEMDOS heap, zero-filled, refcount 1. If the class has
    // a dealloc method, stage its address in the object header (obj-6) so
    // the release-to-zero path can dispatch it.
    // Primitive element sizes (m68k): primitive `_xtc_new_<T>(count)` take
    // only count; class `_xtc_new_<Class>(count, size)` take both.
    NSDictionary* primSize = @{@"u8" : @1, @"i8" : @1, @"bool" : @1, @"u16" : @2, @"i16" : @2, @"u32" : @4, @"i32" : @4, @"pointer" : @4, @"string" : @4, @"float" : @4, @"double" : @8};
    NSSet* defNames = defined;
    (void)defNames;
    // B1: a CLASS `new T` lowers to the generic `_xtc_alloc(count, stride,
    // deallocPtr)` directly — no per-class stub. But `_xtc_new_<T>` is still
    // emitted by the lowering for NON-class allocations: primitive-element
    // arrays (`new u8[N]`) and heap STRUCTs (`new Point()`). Each keeps a thin
    // per-type shim forwarding to _xtc_alloc with a null dealloc:
    //   primitive: _xtc_new_<prim>(count)        -> _xtc_alloc(count, <fixed>, 0)
    //   struct:    _xtc_new_<Struct>(count,size) -> _xtc_alloc(count, size, 0)
    // (the struct's `size` arg has already been overridden to the m68k-native
    // size at the call site). Args pushed reverse so count lands at 4(sp).
    for (XTIRSymbol* s in mod.symbols)
        {
        if (s.kind != XTIRSymbolKindRuntimeHelper || ![s.name hasPrefix:@"_xtc_new_"])
            continue;
        NSString* cls = [s.name substringFromIndex:@"_xtc_new_".length];
        NSNumber* psz = primSize[cls];
        [out appendFormat:@"\t.globl\t%@\n%@:\n", s.name, s.name];
        if (psz)
            [out appendFormat:
                     @"\tclr.l\t-(sp)\n"         // dealloc = 0
                     @"\tmove.l\t#%@,-(sp)\n"    // stride = fixed element size
                     @"\tmove.l\t12(sp),-(sp)\n" // count (orig 4(sp) + 8 pushed)
                     @"\tjsr\t_xtc_alloc\n\tlea\t12(sp),sp\n\trts\n\n",
                     psz];
        else
            [out appendString:
                     @"\tclr.l\t-(sp)\n"         // dealloc = 0
                     @"\tmove.l\t12(sp),-(sp)\n" // size  (orig 8(sp) + 4 pushed)
                     @"\tmove.l\t12(sp),-(sp)\n" // count (orig 4(sp) + 8 pushed)
                     @"\tjsr\t_xtc_alloc\n\tlea\t12(sp),sp\n\trts\n\n"];
        }
    // `.length` of a runtime-sized heap array (private:docs/bugs/045): the element
    // count the allocator wrote at header+0, i.e. obj-14. u16, zero-extended
    // into d0 (the u16 return convention).
    if ([out containsString:@"jsr\t_xtc_count"])
        {
        [out appendString:
                 @"\t.globl\t_xtc_count\n_xtc_count:\n"
                 @"\tmove.l\t4(sp),a0\n"
                 @"\tmoveq\t#0,d0\n"
                 @"\tmove.w\t-14(a0),d0\n"
                 @"\trts\n\n"];
        }
    // Heap allocator + deallocator over GEMDOS Malloc/Mfree. 10-byte header:
    // [count:2][elemSize:2][dealloc:4][refcount:2]; obj=base+10 (refcount at
    // obj-2 matching Retain/Release, dealloc at obj-6, count at obj-10).
    if ([out containsString:@"jsr\t_xtc_alloc\n"])
        {
        [out appendString:
                 @"; runtime: _xtc_alloc(count, stride, deallocPtr) -> zeroed object, refcount 1\n"
                  "; 14-byte header: [count:2][elemSize:2][dealloc:4][weak_head:4][refcount:2],\n"
                  "; obj=base+14. weak_head is the intrusive weak-reference chain (no table);\n"
                  "; it sits BEFORE the refcount so refcount stays at obj-2 and not one line of\n"
                  "; the inline ARC changes. See private:docs/Design/weak-refs-intrusive.md.\n"
                  "\t.globl\t_xtc_alloc\n_xtc_alloc:\n"
                  "\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tjsr\t__mulsi3\n" // d0 = count*stride
                  "\tmove.l\td0,d1\n\tadd.l\t#14,d0\n"                        // d1 = body size; d0 += header
                  // Save the body size ACROSS the GEMDOS Malloc trap on the stack — GEMDOS
                  // clobbers d0-d2 (xst preserves d1 but not d2, which silently corrupted the
                  // zero count and trashed the heap), so a register can't be trusted here.
                  "\tmove.l\td1,-(sp)\n"                                                    // save body size
                  "\tmove.l\td0,-(sp)\n\tmove.w\t#$48,-(sp)\n\ttrap\t#1\n\taddq.l\t#6,sp\n" // Malloc
                  "\tmove.l\t(sp)+,d2\n"                                                    // restore body size → d2
                  "\ttst.l\td0\n\tble.s\t.xa_fail\n"
                  "\tmove.l\td0,a0\n"
                  "\tmove.w\t6(sp),(a0)\n\tmove.w\t10(sp),2(a0)\n"                // count, elemSize (low words)
                  "\tmove.l\t12(sp),4(a0)\n\tclr.l\t8(a0)\n\tmove.w\t#1,12(a0)\n" // dealloc; weak_head=0; refcount=1
                  "\tadd.l\t#14,d0\n\tmove.l\td0,a1\n"                            // d0 = obj = base+14; a1 = zero cursor
                  ".xa_zl:\n\ttst.l\td2\n\tbeq.s\t.xa_done\n\tclr.b\t(a1)+\n\tsubq.l\t#1,d2\n\tbra.s\t.xa_zl\n"
                  ".xa_done:\n\trts\n.xa_fail:\n\tmoveq\t#0,d0\n\trts\n\n"];
        }
    BOOL usesWeak = used(@"__xtc_weak_register") || used(@"__xtc_weak_unregister");
    if (used(@"_xtc_dealloc"))
        {
        [out appendString:
                 @"; runtime: _xtc_dealloc(obj) -> dispatch dealloc per element (count at\n"
                  "; obj-14, stride obj-12) then Mfree(obj-14). Loop state in an a6 frame so it\n"
                  "; survives the dealloc calls. count>=1 (single object => one dispatch).\n"
                  "\t.globl\t_xtc_dealloc\n_xtc_dealloc:\n"
                  "\tlink\ta6,#-8\n\tmove.l\t8(a6),a0\n"]; // -2 count, -4 elem, -8 eltptr
        // Auto-zero any weak references to this object before the memory is
        // freed (and possibly reused), then reload obj into a0.
        if (usesWeak)
            [out appendString:@"\tmove.l\ta0,d0\n\tjsr\t__xtc_weak_zero_all_for\n\tmove.l\t8(a6),a0\n"];
        [out appendString:
                 @"\ttst.l\t-10(a0)\n\tbeq.s\t.xd_free\n"                                     // no dealloc method -> just free
                  "\tmove.w\t#$8000,-2(a0)\n"                                                 // deallocating sentinel: a balanced
                                                                                              // retain/release in the dealloc body
                                                                                              // can't fall to 0 and re-dispatch us
                  "\tmove.w\t-14(a0),-2(a6)\n\tmove.w\t-12(a0),-4(a6)\n\tmove.l\ta0,-8(a6)\n" // count, elem, eltptr=obj
                  ".xd_loop:\n\ttst.w\t-2(a6)\n\tbeq.s\t.xd_free\n"
                  "\tmove.l\t-8(a6),-(sp)\n\tmove.l\t8(a6),a0\n\tmove.l\t-10(a0),a1\n\tjsr\t(a1)\n\taddq.l\t#4,sp\n" // dealloc(eltptr)
                  "\tmove.w\t-4(a6),d0\n\text.l\td0\n\tadd.l\td0,-8(a6)\n"                                           // eltptr += elemSize
                  "\tsubq.w\t#1,-2(a6)\n\tbra.s\t.xd_loop\n"
                  ".xd_free:\n\tmove.l\t8(a6),d0\n\tsub.l\t#14,d0\n" // base = obj-14
                  "\tmove.l\td0,-(sp)\n\tmove.w\t#$49,-(sp)\n\ttrap\t#1\n\taddq.l\t#6,sp\n\tunlk\ta6\n\trts\n\n"];
        }

    // bank(type, idx) -> _xtc_bank: the Atari ST has flat memory and no
    // banking hardware, so each (type, idx) window is simulated with a lazily-
    // allocated, zeroed 12 KB region (mirrors the arm64 corpus stub) so reads
    // and writes through a raw bank pointer round-trip. Args: type at 11(a6),
    // idx at 15(a6) (low byte of each pushed long). Table: regions[3][256].
    if (used(@"_xtc_bank"))
        {
        [out appendString:
                 @"; runtime: _xtc_bank(u8 type, u8 idx) -> lazily-allocated zeroed 12 KB region\n"
                  "\t.globl\t_xtc_bank\n_xtc_bank:\n"
                  "\tlink\ta6,#0\n"
                  "\tmoveq\t#0,d0\n\tmove.b\t11(a6),d0\n\tlsl.l\t#8,d0\n"                       // type*256
                  "\tmoveq\t#0,d1\n\tmove.b\t15(a6),d1\n\tadd.l\td1,d0\n\tlsl.l\t#2,d0\n"       // (type*256+idx)*4
                  "\tlea\t_xtc_bank_regions,a0\n\tadd.l\td0,a0\n"                               // &regions[type][idx]
                  "\tmove.l\t(a0),d0\n\tbne.s\t.xb_done\n"                                      // already allocated?
                  "\tmove.l\ta0,-(sp)\n"                                                        // save &regions[...]
                  "\tmove.l\t#12288,-(sp)\n\tmove.w\t#$48,-(sp)\n\ttrap\t#1\n\taddq.l\t#6,sp\n" // Malloc
                  "\tmove.l\t(sp)+,a0\n\tmove.l\td0,(a0)\n"                                     // store region ptr
                  "\tmove.l\td0,a1\n\tmove.l\t#12288,d1\n"                                      // zero it
                  ".xb_zl:\n\tclr.b\t(a1)+\n\tsubq.l\t#1,d1\n\tbne.s\t.xb_zl\n"
                  ".xb_done:\n\tmove.l\t(a0),d0\n\tunlk\ta6\n\trts\n\n"];
        }

    // Weak side-table: 64 entries of [slot:4][obj:4]. register/unregister
    // (d0=slot[,d1=obj]) maintain it; __xtc_weak_zero_all_for(d0=obj), called
    // from _xtc_dealloc, nulls every slot that pointed at the dying object so
    // a subsequent WeakLoad reads null. Entries use a0/a1/d1 (all scratch).
    if (usesWeak)
        {
        [out appendString:
                 @"; runtime: intrusive weak-reference list — NO TABLE, no cap, no scan.\n"
                  "; slot[-2]=pprev  slot[-1]=next  slot[0]=referent; obj's chain head at obj-6.\n"
                  ";\n"
                  "; `pprev` is the ADDRESS OF THE POINTER THAT POINTS AT THIS SLOT (the Linux\n"
                  "; hlist idiom), not the previous slot. Unlink is then O(1) and never needs the\n"
                  "; object — which matters: a WIDENED `^` holds a FUNCTION pointer in its referent\n"
                  "; word, so recovering the object by reading *slot would treat .text as a header.\n"
                  "; It also makes pprev!=0 an unambiguous 'am I linked?' test (with a plain prev,\n"
                  "; prev==0 means EITHER unlinked OR head-of-chain).\n"
                  ";\n"
                  "; Replaces a 64-entry table that was scanned on every store AND on every\n"
                  "; dealloc — including for the vast majority of objects that had no weak refs at\n"
                  "; all. Registers used: d0/d1/a0/a1 (all scratch).\n"
                  "\t.globl\t__xtc_weak_unregister\n__xtc_weak_unregister:\n" // d0 = slot
                  "\tmove.l\td0,a0\n"
                  "\tmove.l\t-8(a0),d1\n\tbeq.s\t.wku_x\n" // pprev == 0 -> not linked
                  "\tmove.l\td1,a1\n"                      // a1 = pprev
                  "\tmove.l\t-4(a0),d1\n"                  // d1 = next
                  "\tmove.l\td1,(a1)\n"                    // *pprev = next
                  "\ttst.l\td1\n\tbeq.s\t.wku_c\n"
                  "\tmove.l\td1,a1\n"                          // a1 = next
                  "\tmove.l\t-8(a0),d1\n\tmove.l\td1,-8(a1)\n" // next.pprev = pprev
                  ".wku_c:\n\tclr.l\t-8(a0)\n\tclr.l\t-4(a0)\n"
                  ".wku_x:\n\trts\n"
                  "\t.globl\t__xtc_weak_register\n__xtc_weak_register:\n"                  // d0 = slot, d1 = obj
                  "\tmove.l\td1,-(sp)\n\tjsr\t__xtc_weak_unregister\n\tmove.l\t(sp)+,d1\n" // drop any prior link
                  "\ttst.l\td1\n\tbeq.s\t.wkr_x\n"                                         // null obj -> nothing to track
                  "\tmove.l\td0,a0\n"                                                      // a0 = slot
                  "\tmove.l\td1,a1\n\tlea\t-6(a1),a1\n"                                    // a1 = &obj.weak_head
                  "\tmove.l\t(a1),d1\n"                                                    // d1 = nx = *head
                  "\tmove.l\ta1,-8(a0)\n\tmove.l\td1,-4(a0)\n"                             // slot.pprev = &head; slot.next = nx
                  "\tmove.l\ta0,(a1)\n"                                                    // *head = slot
                  "\ttst.l\td1\n\tbeq.s\t.wkr_x\n"
                  "\tmove.l\td1,a1\n"                  // a1 = nx
                  "\tmove.l\ta0,d1\n\tsubq.l\t#4,d1\n" // d1 = &slot.next
                  "\tmove.l\td1,-8(a1)\n"              // nx.pprev = &slot.next
                  ".wkr_x:\n\trts\n"
                  "\t.globl\t__xtc_weak_zero_all_for\n__xtc_weak_zero_all_for:\n" // d0 = obj
                  "\ttst.l\td0\n\tbeq.s\t.wkz_x\n"
                  "\tmove.l\td0,a1\n\tlea\t-6(a1),a1\n"               // a1 = &obj.weak_head
                  "\tmove.l\t(a1),d1\n\tclr.l\t(a1)\n"                // d1 = chain; head = 0
                  ".wkz_l:\n\ttst.l\td1\n\tbeq.s\t.wkz_x\n"           // no weak refs -> ONE test
                  "\tmove.l\td1,a0\n\tmove.l\t-4(a0),d1\n"            // a0 = s; d1 = s.next
                  "\tclr.l\t(a0)\n\tclr.l\t-8(a0)\n\tclr.l\t-4(a0)\n" // zero the referent + links
                  "\tbra.s\t.wkz_l\n"
                  ".wkz_x:\n\trts\n\n"];
        // __weak_table itself is reserved in .bss by emitDataSection (the
        // assembler only tolerates a single text->data->bss transition, so
        // bss storage can't be inlined here in the .text stream).
        }

    // Monotonic microsecond clock (Time.xc: _xt_clk_reset/ticks/delay). The
    // arm64 host runtime backs these with a real CLOCK_MONOTONIC; on the ST a
    // simple advancing counter suffices — the Time column is never oracle-checked
    // (it isn't reproducible across sims), it only has to advance and not crash.
    // Without it, `jsr _xt_clk_reset` hit an UNDEFINED symbol that the assembler
    // resolved to 0 → `jsr 0` restarted the program (the ahl "Begin" loop).
    if (used(@"_xt_clk_reset") || used(@"_xt_clk_ticks") || used(@"_xt_clk_delay"))
        {
        [out appendString:
                 @"; runtime: monotonic counter clock (Time.xc)\n"
                  "\t.even\n__xt_clk_ticks_store:\n\t.dc.l\t0\n"
                  "\t.globl\t_xt_clk_reset\n_xt_clk_reset:\n"
                  "\tlea\t__xt_clk_ticks_store,a0\n\tclr.l\t(a0)\n\trts\n"
                  "\t.globl\t_xt_clk_ticks\n_xt_clk_ticks:\n"
                  "\tlea\t__xt_clk_ticks_store,a0\n\tmove.l\t(a0),d0\n\tadd.l\t#1000,d0\n\tmove.l\td0,(a0)\n\trts\n"
                  "\t.globl\t_xt_clk_delay\n_xt_clk_delay:\n"
                  "\tlea\t__xt_clk_ticks_store,a0\n\tmove.l\t4(sp),d0\n\tadd.l\td0,(a0)\n\trts\n\n"];
        }

    // Float -> ASCII formatters for printf %f/%lf (68881 FPU). Default
    // precision 6 (float) / 10 (double); the *p variants take an explicit
    // precision. Use __print_u32 (needs __udivmod) and _putc.
    BOOL needFmt = used(@"_xtc_pf") || used(@"_xtc_pd") || used(@"_xtc_pfp") || used(@"_xtc_pdp");
    // soft-float %f formatter is a TODO
    if (needFmt && gHardFloat)
        {
        [out appendString:
                 @"; runtime: float/double -> ASCII (printf %f/%lf)\n"
                  "\t.even\n__fp_ten:\n\t.dc.l\t$41200000\n__fp_half:\n\t.dc.l\t$3F000000\n" // 10.0f, 0.5f
                  "__print_u32:\n\tmoveq\t#0,d2\n"                                           // d0 unsigned -> stdout
                  ".pu_div:\n\tmove.l\t#10,d1\n\tbsr\t__udivmod\n\tmove.l\td4,-(sp)\n\taddq.l\t#1,d2\n"
                  "\ttst.l\td0\n\tbne.s\t.pu_div\n"
                  ".pu_pr:\n\tmove.l\t(sp)+,d0\n\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n"
                  "\tsubq.l\t#1,d2\n\tbne.s\t.pu_pr\n\trts\n"
                  "__fmt_double:\n" // fp0=value, d3=prec
                  "\tftst\tfp0\n\tfbge.s\t.fd_pos\n"
                  "\tmove.l\t#45,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tfneg\tfp0,fp0\n"
                  ".fd_pos:\n"
                  // printf %f/%.Nf TRUNCATES to N places (per the xtc Stdio contract) — no
                  // 0.5*10^-prec round term, matching arm64/xt6502.
                  "\tfintrz\tfp0,fp1\n\tfmove.l\tfp1,d0\n"
                  "\tmove.l\td3,-(sp)\n\tbsr\t__print_u32\n\tmove.l\t(sp)+,d3\n"
                  "\tmove.l\t#46,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tfsub\tfp1,fp0\n"
                  ".fd_lp:\n\ttst.l\td3\n\tbeq.s\t.fd_dn\n\tsubq.l\t#1,d3\n"
                  "\tfmul.s\t__fp_ten,fp0\n\tfintrz\tfp0,fp1\n\tfmove.l\tfp1,d0\n\tadd.l\t#48,d0\n"
                  "\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tfsub\tfp1,fp0\n\tbra.s\t.fd_lp\n"
                  ".fd_dn:\n\trts\n"
                  "\t.globl\t_xtc_pd\n_xtc_pd:\n\tfmove.d\t4(sp),fp0\n\tmoveq\t#10,d3\n\tbra\t__fmt_double\n"
                  "\t.globl\t_xtc_pf\n_xtc_pf:\n\tfmove.s\t4(sp),fp0\n\tmoveq\t#6,d3\n\tbra\t__fmt_double\n"
                  "\t.globl\t_xtc_pdp\n_xtc_pdp:\n\tfmove.d\t4(sp),fp0\n\tmove.l\t12(sp),d3\n"
                  "\tbne.s\t__fmt_double\n\tmoveq\t#10,d3\n\tbra\t__fmt_double\n" // 0 = default 10
                  "\t.globl\t_xtc_pfp\n_xtc_pfp:\n\tfmove.s\t4(sp),fp0\n\tmove.l\t8(sp),d3\n"
                  "\tbne.s\t__fmt_double\n\tmoveq\t#6,d3\n\tbra\t__fmt_double\n\n"]; // 0 = default 6
        }
    // Soft-float %f formatter (no FPU): format via the f64 soft-float helpers.
    // float args are extended to f64 so one routine serves both. value in
    // d0:d1, prec in d3. Frame: -4 valHi -8 valLo -12 prec -16 fracHi
    // -20 fracLo -24 scratch. Calls use jsr so used() pulls the helpers in.
    if (needFmt && !gHardFloat)
        {
        [out appendString:
                 @"; runtime: soft-float double -> ASCII (printf %f/%lf, no FPU)\n"
                  "__print_u32:\n\tmoveq\t#0,d2\n"
                  ".su_div:\n\tmove.l\t#10,d1\n\tbsr\t__udivmod\n\tmove.l\td4,-(sp)\n\taddq.l\t#1,d2\n\ttst.l\td0\n\tbne.s\t.su_div\n"
                  ".su_pr:\n\tmove.l\t(sp)+,d0\n\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n\tsubq.l\t#1,d2\n\tbne.s\t.su_pr\n\trts\n"
                  "__fmt_dbl_soft:\n\tlink\ta6,#-24\n"
                  "\tmove.l\td0,-4(a6)\n\tmove.l\td1,-8(a6)\n\tmove.l\td3,-12(a6)\n"
                  "\tand.l\t#$80000000,d0\n\tbeq.s\t.sf_pos\n" // sign
                  "\tmove.l\t#45,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n"
                  "\tmove.l\t-4(a6),d0\n\tand.l\t#$7fffffff,d0\n\tmove.l\td0,-4(a6)\n"
                  ".sf_pos:\n" // round = 0.5*10^-prec
                  "\tmove.l\t#$3fe00000,-16(a6)\n\tclr.l\t-20(a6)\n\tmove.l\t-12(a6),-24(a6)\n"
                  ".sf_rnd:\n\tmove.l\t-24(a6),d0\n\tble.s\t.sf_rdn\n"
                  "\tclr.l\t-(sp)\n\tmove.l\t#$40240000,-(sp)\n\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tjsr\t__divdf3\n\tlea\t16(sp),sp\n"
                  "\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n\tsubq.l\t#1,-24(a6)\n\tbra.s\t.sf_rnd\n"
                  ".sf_rdn:\n" // value += round
                  "\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tmove.l\t-8(a6),-(sp)\n\tmove.l\t-4(a6),-(sp)\n\tjsr\t__adddf3\n\tlea\t16(sp),sp\n"
                  "\tmove.l\td0,-4(a6)\n\tmove.l\td1,-8(a6)\n"
                  "\tmove.l\t-8(a6),-(sp)\n\tmove.l\t-4(a6),-(sp)\n\tjsr\t__fixdfsi\n\taddq.l\t#8,sp\n" // intpart
                  "\tmove.l\td0,-24(a6)\n\tjsr\t__print_u32\n"
                  "\tmove.l\t#46,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n" // '.'
                  "\tmove.l\t-24(a6),d0\n\tjsr\t__floatsidf\n"           // frac = value - (double)intpart
                  "\tmove.l\td1,-(sp)\n\tmove.l\td0,-(sp)\n\tmove.l\t-8(a6),-(sp)\n\tmove.l\t-4(a6),-(sp)\n\tjsr\t__subdf3\n\tlea\t16(sp),sp\n"
                  "\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n"
                  ".sf_dlp:\n\tmove.l\t-12(a6),d0\n\tble.s\t.sf_dn\n"                                                                                 // digit loop
                  "\tclr.l\t-(sp)\n\tmove.l\t#$40240000,-(sp)\n\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tjsr\t__muldf3\n\tlea\t16(sp),sp\n" // frac*=10
                  "\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n"
                  "\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tjsr\t__fixdfsi\n\taddq.l\t#8,sp\n" // digit
                  "\tmove.l\td0,-24(a6)\n\tadd.l\t#48,d0\n\tmove.l\td0,-(sp)\n\tjsr\t_putc\n\taddq.l\t#4,sp\n"
                  "\tmove.l\t-24(a6),d0\n\tjsr\t__floatsidf\n" // frac -= (double)digit
                  "\tmove.l\td1,-(sp)\n\tmove.l\td0,-(sp)\n\tmove.l\t-20(a6),-(sp)\n\tmove.l\t-16(a6),-(sp)\n\tjsr\t__subdf3\n\tlea\t16(sp),sp\n"
                  "\tmove.l\td0,-16(a6)\n\tmove.l\td1,-20(a6)\n\tsubq.l\t#1,-12(a6)\n\tbra.s\t.sf_dlp\n"
                  ".sf_dn:\n\tunlk\ta6\n\trts\n"
                  "\t.globl\t_xtc_pd\n_xtc_pd:\n\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tmoveq\t#10,d3\n\tbra\t__fmt_dbl_soft\n"
                  "\t.globl\t_xtc_pf\n_xtc_pf:\n\tmove.l\t4(sp),d0\n\tjsr\t__extendsfdf2\n\tmoveq\t#6,d3\n\tbra\t__fmt_dbl_soft\n"
                  "\t.globl\t_xtc_pdp\n_xtc_pdp:\n\tmove.l\t4(sp),d0\n\tmove.l\t8(sp),d1\n\tmove.l\t12(sp),d3\n\tbne.s\t.pdp1\n\tmoveq\t#10,d3\n.pdp1:\n\tbra\t__fmt_dbl_soft\n"
                  "\t.globl\t_xtc_pfp\n_xtc_pfp:\n\tmove.l\t4(sp),d0\n\tjsr\t__extendsfdf2\n\tmove.l\t8(sp),d3\n\tbne.s\t.pfp1\n\tmoveq\t#6,d3\n.pfp1:\n\tbra\t__fmt_dbl_soft\n\n"];
        }

    // libm math via the 68881 transcendentals. xtc Math.* lowers to
    // _xm_<op>f (float) / _xm_<op> (double); each maps to one FPU
    // instruction whose result the emulator (and the Zynq m68k JIT)
    // computes with native libm. Float returns in d0; double in d0:d1.
    //
    // An ARRAY of pairs, in this order, not a dictionary: the helpers are
    // emitted in iteration order, and a dictionary's order is its hash
    // layout's. The self-hosted back end walks the same list in the same order.
    NSArray<NSArray<NSString*>*>* xmOps = @[
        @[@"sqrt", @"fsqrt"], @[@"sin", @"fsin"], @[@"cos", @"fcos"], @[@"tan", @"ftan"],
        @[@"atan", @"fatan"], @[@"asin", @"fasin"], @[@"acos", @"facos"], @[@"ln", @"flogn"],
        @[@"exp", @"fetox"], @[@"log10", @"flog10"], @[@"log2", @"flog2"]];
    for (NSArray<NSString*>* pair in xmOps)
        {
        if (!gHardFloat)
            break;
        NSString* op = pair[0];
        NSString* mn = pair[1];
        if (used([NSString stringWithFormat:@"_xm_%@f", op]))
            [out appendFormat:
                     @"\t.globl\t_xm_%@f\n_xm_%@f:\n\tfmove.s\t4(sp),fp0\n\t%@\tfp0,fp0\n\tfmove.s\tfp0,d0\n\trts\n\n",
                     op, op, mn];
        if (used([NSString stringWithFormat:@"_xm_%@", op]))
            [out appendFormat:
                     @"\t.globl\t_xm_%@\n_xm_%@:\n\tfmove.d\t4(sp),fp0\n\t%@\tfp0,fp0\n"
                      "\tfmove.d\tfp0,-(sp)\n\tmove.l\t(sp)+,d0\n\tmove.l\t(sp)+,d1\n\trts\n\n",
                     op, op, mn];
        }
    // pow(a,b) = exp(b*ln(a)) — no single 68881 instruction.
    if (gHardFloat && used(@"_xm_powf"))
        [out appendString:
                 @"\t.globl\t_xm_powf\n_xm_powf:\n\tfmove.s\t4(sp),fp0\n\tflogn\tfp0,fp0\n"
                  "\tfmove.s\t8(sp),fp1\n\tfmul\tfp1,fp0\n\tfetox\tfp0,fp0\n\tfmove.s\tfp0,d0\n\trts\n\n"];
    if (gHardFloat && used(@"_xm_pow"))
        [out appendString:
                 @"\t.globl\t_xm_pow\n_xm_pow:\n\tfmove.d\t4(sp),fp0\n\tflogn\tfp0,fp0\n"
                  "\tfmove.d\t12(sp),fp1\n\tfmul\tfp1,fp0\n\tfetox\tfp0,fp0\n"
                  "\tfmove.d\tfp0,-(sp)\n\tmove.l\t(sp)+,d0\n\tmove.l\t(sp)+,d1\n\trts\n\n"];

    // ── FPU-less math helpers → line-A HLE stubs ───────────────────────
    // Soft-float (f32/f64 arith, convert, compare) and 68000 32-bit integer
    // mul/div/mod each compile to a two-word `line-A + rts` stub. The A9 JIT
    // (or xst) executes the op on native math honouring the m68k C ABI, and
    // preserves d2-d7/a2-a6 — so the register allocator can home there. See
    // private:docs/Design/m68k-math-hle.md. Under hard-float / 68020+ the hardware
    // instruction is emitted inline and none of these symbols are referenced.
    NSArray<NSArray*>* mathHLE = @[
        @[ @"__addsf3", @0x00 ],
        @[ @"__subsf3", @0x01 ],
        @[ @"__mulsf3", @0x02 ],
        @[ @"__divsf3", @0x03 ],
        @[ @"__cmpsf2", @0x05 ],
        @[ @"__adddf3", @0x08 ],
        @[ @"__subdf3", @0x09 ],
        @[ @"__muldf3", @0x0A ],
        @[ @"__divdf3", @0x0B ],
        @[ @"__cmpdf2", @0x0D ],
        @[ @"__fixsfsi", @0x10 ],
        @[ @"__fixdfsi", @0x11 ],
        @[ @"__floatsisf", @0x12 ],
        @[ @"__floatsidf", @0x13 ],
        @[ @"__extendsfdf2", @0x14 ],
        @[ @"__truncdfsf2", @0x15 ],
        @[ @"__mulsi3", @0x18 ],
        @[ @"__divsi3", @0x19 ],
        @[ @"__udivsi3", @0x1A ],
        @[ @"__modsi3", @0x1B ],
        @[ @"__umodsi3", @0x1C ],
        // 64-bit integer pack. Same mechanism, next free selectors.
        @[ @"__adddi3", @0x20 ],
        @[ @"__subdi3", @0x21 ],
        @[ @"__muldi3", @0x22 ],
        @[ @"__divdi3", @0x23 ],
        @[ @"__udivdi3", @0x24 ],
        @[ @"__moddi3", @0x25 ],
        @[ @"__umoddi3", @0x26 ],
        @[ @"__ashldi3", @0x27 ],
        @[ @"__lshrdi3", @0x28 ],
        @[ @"__ashrdi3", @0x29 ],
        @[ @"__anddi3", @0x2A ],
        @[ @"__ordi3", @0x2B ],
        @[ @"__xordi3", @0x2C ],
        // Compare, returning sign(a-b) in d0 as __cmpdf2 does. Kept in
        // SELECTOR order: the stubs are emitted in table order, so a table
        // sorted differently from the port's is a diff in the output.
        @[ @"__cmpdi2", @0x2D ],
        @[ @"__ucmpdi2", @0x2E ],
        // 64-bit integer <-> floating point. Referenced in BOTH float modes,
        // unlike everything above: the 68881 converts .b/.w/.l only, so there
        // is no hardware instruction for a 64-bit integer and -mhard-float has
        // to come through the HLE too.
        @[ @"__floatdidf", @0x2F ],
        @[ @"__floatundidf", @0x30 ],
        @[ @"__floatdisf", @0x31 ],
        @[ @"__floatundisf", @0x32 ],
        @[ @"__fixdfdi", @0x33 ],
        @[ @"__fixunsdfdi", @0x34 ],
        @[ @"__fixsfdi", @0x35 ],
        @[ @"__fixunssfdi", @0x36 ],
    ];
    for (NSArray* e in mathHLE)
        {
        if (!used(e[0]))
            continue;
        [out appendFormat:@"\t.globl\t%@\n%@:\n\t.dc.w\t$%04X\t; line-A math HLE\n\trts\n\n",
                          e[0], e[0], (unsigned)(0xA000 | [(NSNumber*)e[1] intValue])];
        }
    // __udivmod is an INTERNAL subroutine of the hard-float %f formatter
    // (__print_u32 bsr's it), not an ABI-visible math call — keep it as asm.
    if (needFmt)
        {
        [out appendString:
                 @"; runtime: __udivmod — unsigned 32/32, quotient d0, remainder d4\n"
                  "__udivmod:\n"
                  "\tmoveq\t#0,d4\n\tmoveq\t#31,d3\n"
                  ".udm_loop:\n"
                  "\tadd.l\td0,d0\n\troxl.l\t#1,d4\n\tcmp.l\td1,d4\n\tbcs.s\t.udm_no\n"
                  "\tsub.l\td1,d4\n\taddq.l\t#1,d0\n"
                  ".udm_no:\n\tsubq.l\t#1,d3\n\tbpl.s\t.udm_loop\n\trts\n\n"];
        }
    }

// ── Slot assignment ─────────────────────────────────────────────────────
// Parameters → positive offsets (caller-pushed longs at 8(a6), 12(a6)…),
// skipping the trailing Memory token. Result/phi values → negative frame
// slots. Assumes param value id == its positional index (the IR numbers
// params %0,%1,… from zero).
+ (NSMutableDictionary<NSNumber*, NSNumber*>*)assignSlotsFor:(XTIRFunction*)fn
                                                   frameSize:(int*)frameSize
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* slots = [NSMutableDictionary dictionary];
    int argOff = 8;
    NSUInteger paramIdx = 0;
    for (XTIRType* t in fn.paramTypes)
        {
        if (t.kind != XTIRTypeKindMemory)
            {
            slots[@(paramIdx)] = @(argOff);
            // An aggregate is passed by value: the caller pushes the whole
            // struct, so it occupies its full (4-aligned) size on the stack,
            // not one long. AddrOf(param) then points at the pushed copy.
            if (t.kind == XTIRTypeKindAgg && t.layout)
                argOff += ((int)[self m68kAggSize:t.layout] + 3) & ~3;
            else if (t.kind == XTIRTypeKindF64 || t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64)
                argOff += 8; // double / i64 occupy two longs
            else
                argOff += 4;
            }
        paramIdx++;
        }
    // Pinned locals (aggregates / address-taken locals) occupy a fixed
    // region of `pinnedLocalSize` bytes just below A6; each sits at
    // -(pinnedLocalSize) + its byteOffset. Value slots go below that.
    // Recompute the pinned-local region with m68k widths. The front-end's
    // byteOffset / pinnedLocalSize assume the IR's canonical 2/3-byte
    // pointers, which under-sizes a pointer array / aggregate: an
    // address-taken `T@ a[3]` reserves 9 bytes but is addressed with the
    // 4-byte m68k stride (a[2] at +8), so it would overflow its slot and
    // corrupt the frame.
    int pinSize = 0;
    NSMutableDictionary<NSNumber*, NSNumber*>* pinOff = [NSMutableDictionary dictionary];
    for (XTIRPinnedLocal* p in fn.frameInfo.pinnedLocals)
        {
        pinOff[@(p.valueId)] = @(pinSize);
        int sz = (int)[self m68kFieldWidth:p.type];
        pinSize += (sz + 1) & ~1; // keep each entry even-aligned
        }
    pinSize = (pinSize + 1) & ~1;
    for (XTIRPinnedLocal* p in fn.frameInfo.pinnedLocals)
        slots[@(p.valueId)] = @(-pinSize + pinOff[@(p.valueId)].intValue);

    // Value slots stack downward below the pinned region. Aggregates take
    // their full m68k size (rounded to 4); scalars take 4.
    __block int next = pinSize;
    void (^assign)(XTIRValue*) = ^(XTIRValue* r) {
      if (!r || r.type.kind == XTIRTypeKindMemory)
          return;
      if (slots[@(r.valueId)])
          return;
      int sz = 4;
      if (r.type.kind == XTIRTypeKindAgg && r.type.layout)
          sz = ((int)[self m68kAggSize:r.type.layout] + 3) & ~3;
      else if (r.type.kind == XTIRTypeKindF64 || r.type.kind == XTIRTypeKindI64 || r.type.kind == XTIRTypeKindU64)
          sz = 8; // two longs, like a double
      next += sz;
      slots[@(r.valueId)] = @(-next);
    };
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* phi in bb.phiNodes)
            assign(phi.result);
        for (XTIRInsn* insn in bb.instructions)
            assign(insn.result);
        }
    *frameSize = next;
    return slots;
    }

// Detect XTIROptPointerIV walking pointers and home them in address registers
// a2-a4. Populates gPtrAReg / gPtrAdvance / gPtrBase and returns the set of
// value-ids to exclude from d-register homing (each p and its pNext). Only a
// pointer whose EVERY use is an address base (Load/Store operand[0], or the
// base of a foldable ElementAddr) or the advance itself is homed — so advancing
// the register in place can never clobber a live value.
+ (NSSet<NSNumber*>*)detectPointerIVsForFunction:(XTIRFunction*)fn cpu:(NSInteger)cpu
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSMutableArray*>* uses = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;
            for (NSUInteger k = 0; k < insn.operands.count; k++)
                {
                XTIROperand* o = insn.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                NSMutableArray* u = uses[@(o.valueId)];
                if (!u)
                    {
                    u = [NSMutableArray array];
                    uses[@(o.valueId)] = u;
                    }
                [u addObject:@[ insn, @(k) ]];
                }
            }
        }

    NSMutableDictionary<NSNumber*, NSString*>* areg = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* adv = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIROperand*>* base = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* excluded = [NSMutableSet set];
    NSArray<NSString*>* pool = @[ @"a2", @"a3", @"a4" ];
    NSUInteger next = 0;

    for (XTIRBlock* H in fn.blocks)
        {
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (next >= pool.count)
                break;
            if (!phi.result || phi.operands.count != 4)
                continue;
            XTIRType* pt = phi.result.type;
            if (!pt || pt.kind != XTIRTypeKindPtr || !pt.pointeeType)
                continue;
            XTIRValueId pid = phi.result.valueId;
            // The two incoming (block, value) edges; the latch edge's value is the
            // advance pNext = ElementAddr(p, const).
            XTIROperand *v0 = phi.operands[1], *v1 = phi.operands[3];
            XTIROperand *pNextOp = nil, *baseOp = nil;
            for (int e = 0; e < 2; e++)
                {
                XTIROperand* vo = e ? v1 : v0;
                if (vo.kind != XTIROperandKindUse)
                    continue;
                XTIRInsn* d = defOf[@(vo.valueId)];
                if (d && d.opcode == XTIROpElementAddr && d.operands.count >= 2 &&
                    d.operands[0].kind == XTIROperandKindUse && d.operands[0].valueId == pid &&
                    d.operands[1].kind == XTIROperandKindImmI)
                    {
                    pNextOp = vo;
                    baseOp = e ? v0 : v1;
                    }
                }
            if (!pNextOp || !baseOp)
                continue;
            XTIRInsn* advInsn = defOf[@(pNextOp.valueId)];
            uint32_t stride = (uint32_t)[self m68kFieldWidth:pt.pointeeType];
            long long disp = (long long)advInsn.operands[1].intValue * (long long)stride;
            if (disp == 0)
                continue;
            // Safety: every use of p is the advance or an address base, and pNext
            // is used only by this phi's back edge (so p walks in place safely).
            BOOL clean = YES;
            for (NSArray* u in uses[@(pid)])
                {
                XTIRInsn* insn = u[0];
                NSUInteger k = [u[1] unsignedIntegerValue];
                if (insn == advInsn)
                    continue;
                if ((insn.opcode == XTIROpLoad || insn.opcode == XTIROpStore) && k == 0)
                    continue;
                clean = NO;
                break;
                }
            if (clean)
                for (NSArray* u in uses[@(pNextOp.valueId)])
                    {
                    if (u[0] != phi)
                        {
                        clean = NO;
                        break;
                        }
                    }
            if (!clean)
                continue;
            NSString* reg = pool[next++];
            areg[@(pid)] = reg;
            areg[@(pNextOp.valueId)] = reg;
            adv[@(pNextOp.valueId)] = @(disp);
            base[@(pid)] = baseOp;
            [excluded addObject:@(pid)];
            [excluded addObject:@(pNextOp.valueId)];
            }
        }
    gPtrAReg = areg;
    gPtrAdvance = adv;
    gPtrBase = base;
    return excluded;
    }

+ (void)emitFunction:(XTIRFunction*)fn mod:(XTIRModule*)mod
                 cpu:(NSInteger)cpu
                into:(NSMutableString*)out
    {
    int frameSize = 0;
    NSMutableDictionary<NSNumber*, NSNumber*>* slots =
        [self assignSlotsFor:fn
                   frameSize:&frameSize];

    // Register homing: give the hottest eligible values a callee-saved d-reg
    // (d5-d7). Floats route to the empty FP pool ⇒ stay in slots; pointers home
    // in d-regs (loadOperand moves d→a for (aN) addressing). Reserve a frame
    // slot per used callee-saved reg to save/restore it (no `movem` in xta).
    // Compare-and-branch fusion: an ICmp that is a block's last instruction and
    // whose result is used ONLY by that block's CondBranch. Excluded from homing.
    NSMutableSet<NSNumber*>* fused = [NSMutableSet set];
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* uc = [NSMutableDictionary dictionary];
        void (^cnt)(NSArray<XTIROperand*>*) = ^(NSArray<XTIROperand*>* ops) {
          for (XTIROperand* o in ops)
              if (o.kind == XTIROperandKindUse)
                  uc[@(o.valueId)] = @(uc[@(o.valueId)].integerValue + 1);
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                cnt(p.operands);
            for (XTIRInsn* in in bb.instructions)
                cnt(in.operands);
            if (bb.terminator)
                cnt(bb.terminator.operands);
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            XTIRInsn* t = bb.terminator;
            if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 1)
                continue;
            XTIROperand* cond = t.operands[0];
            if (cond.kind != XTIROperandKindUse || uc[@(cond.valueId)].integerValue != 1)
                continue;
            XTIRInsn* last = bb.instructions.lastObject;
            if (last && last.opcode == XTIROpICmp && last.result && last.result.valueId == cond.valueId)
                {
                // A 64-bit compare goes through a helper that returns
                // sign(a-b) in d0, so the flags a fused branch would read are
                // those of `tst.l d0` — a SIGNED test — whatever the operands'
                // own signedness was. Rather than translate the predicate at
                // the branch, keep the boolean.
                XTIRType* ct = last.operands.count ? [self operandType:last.operands[0] fn:fn] : nil;
                BOOL wide = ct && (ct.kind == XTIRTypeKindI64 || ct.kind == XTIRTypeKindU64);
                if (!wide)
                    [fused addObject:@(cond.valueId)];
                }
            }
        }
    gFusedCmp = fused;

    // Address folding: a single-use ElementAddr/FieldAddr immediately consumed by
    // a scalar Load/Store folds into that memory operand (scaled index / field
    // displacement). The addr op is elided → excluded from homing.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* fold = [NSMutableDictionary dictionary];
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* uc = [NSMutableDictionary dictionary];
        void (^cnt)(NSArray<XTIROperand*>*) = ^(NSArray<XTIROperand*>* ops) {
          for (XTIROperand* o in ops)
              if (o.kind == XTIROperandKindUse)
                  uc[@(o.valueId)] = @(uc[@(o.valueId)].integerValue + 1);
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                cnt(p.operands);
            for (XTIRInsn* in in bb.instructions)
                cnt(in.operands);
            if (bb.terminator)
                cnt(bb.terminator.operands);
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            NSArray<XTIRInsn*>* ins = bb.instructions;
            for (NSUInteger i = 0; i + 1 < ins.count; i++)
                {
                XTIRInsn* ea = ins[i];
                if ((ea.opcode != XTIROpElementAddr && ea.opcode != XTIROpFieldAddr) || !ea.result)
                    continue;
                if (uc[@(ea.result.valueId)].integerValue != 1)
                    continue;
                XTIRInsn* nx = ins[i + 1];
                BOOL isLoad = nx.opcode == XTIROpLoad, isStore = nx.opcode == XTIROpStore;
                if (!isLoad && !isStore)
                    continue;
                if (nx.operands.count < 1 || nx.operands[0].kind != XTIROperandKindUse || nx.operands[0].valueId != ea.result.valueId)
                    continue;
                XTIRType* mt = isLoad ? nx.result.type
                                      : (nx.operands.count >= 2 && nx.operands[1].kind == XTIROperandKindUse
                                             ? [fn valueForId:nx.operands[1].valueId].type
                                             : nx.operands[1].type);
                if (mt && mt.kind == XTIRTypeKindAgg)
                    continue; // struct copy stays a byte loop
                if (ea.opcode == XTIROpElementAddr)
                    {
                    XTIRType* rt = ea.result.type;
                    uint32_t st = (rt && rt.pointeeType) ? (uint32_t)[self m68kFieldWidth:rt.pointeeType] : 1;
                    if (!(st == 1 || st == 2 || st == 4 || st == 8))
                        continue; // needs a scale
                    if (st > 1 && cpu < 68020)
                        continue; // *scale is 68020+
                    }
                fold[@(ea.result.valueId)] = ea;
                }
            }
        }
    gFold = fold;

    // Pointer-IV address-register homing: walking pointers go in a2-a4, excluded
    // from the d-register homing below (and their advance is deferred + emitted
    // in place — see emitDeferredAdvancesForBlock: and the ElementAddr/Load cases).
    NSSet<NSNumber*>* ptrExcluded = [self detectPointerIVsForFunction:fn cpu:cpu];

    NSMutableSet<NSNumber*>* excluded = [NSMutableSet setWithSet:fused];
    [excluded addObjectsFromArray:fold.allKeys];
    [excluded unionSet:ptrExcluded];
    // A 64-bit integer does not fit in a home. The allocator would happily put
    // one in d3, and every consumer reads it from its SLOT — so the value was
    // written to a register and read from memory that nothing had written. The
    // low half looked right (it came from the helper's own result) while the
    // high half was whatever the slot held. i64 lives in a slot, like a double.
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* in in bb.instructions)
            if (in.result && (in.result.type.kind == XTIRTypeKindI64 || in.result.type.kind == XTIRTypeKindU64))
                [excluded addObject:@(in.result.valueId)];
        // A PARAMETER is not an instruction result, so the loop above never sees
        // one. `i64 add(i64 a, i64 b)` homed both into d3/d4 holding only their high
        // longs, while the body read them from 8(a6)/16(a6) — right by luck here,
        // and wrong the moment a consumer preferred the home. Param value id is its
        // positional index (see assignSlotsFor:).
        {
        NSUInteger paramPos = 0;
        for (XTIRType* t in fn.paramTypes)
            {
            if (t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64)
                [excluded addObject:@(paramPos)];
            paramPos++;
            }
        }
    // d5-d7 are callee-saved homes (persisted across the whole function). d3-d4
    // are offered as CALLER-saved homes: the allocator only places a value there
    // if its live range crosses NO call, so the runtime helpers' d3/d4 clobbers
    // (__udivmod remainder/counter, __fmt_double precision) can never corrupt a
    // homed value — and no prologue save or call-site spill is needed. The
    // per-instruction codegen uses only d0-d2 as scratch, so d3-d4 stay free.
    XTHomingResult* hr = [XTHomingAllocator assignHomesForFunction:fn
                                                          gpCallee:@[ @"d5", @"d6", @"d7" ]
                                                          gpCaller:@[ @"d3", @"d4" ]
                                                          fpCallee:@[]
                                                          fpCaller:@[]
                                                          excluded:excluded];
    gHome = hr.homeReg;
    gHomeSaves = hr.usedCalleeSaved;
    NSMutableDictionary<NSString*, NSNumber*>* saveOff = [NSMutableDictionary dictionary];
    for (NSString* r in gHomeSaves)
        {
        frameSize += 4;
        saveOff[r] = @(-frameSize);
        }
    gHomeSaveOff = saveOff;

    // Reserve save slots for the pointer-IV address registers (a2-a4 are
    // callee-saved): distinct regs used, in a2<a3<a4 order for stable output.
    NSMutableArray<NSString*>* ptrSaves = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* ptrSaveOff = [NSMutableDictionary dictionary];
    for (NSString* r in @[ @"a2", @"a3", @"a4" ])
        if ([gPtrAReg.allValues containsObject:r])
            {
            [ptrSaves addObject:r];
            frameSize += 4;
            ptrSaveOff[r] = @(-frameSize);
            }
    gPtrARegSaves = ptrSaves;
    gPtrARegSaveOff = ptrSaveOff;

    // Frame budget: `link a6,#-N` and `d16(a6)` local addressing use a 16-bit
    // SIGNED displacement, so a frame can't exceed 32768 bytes (locals sit at
    // -N..-1). Fail loudly rather than emit a displacement that wraps. (68020+
    // could use link.l / a base displacement to lift this; not wired yet.)
    if (frameSize > 32768)
        {
        [NSException raise:@"XTFrameBudgetExceeded"
                    format:@"function '%@' needs %d frame bytes, exceeding the "
                           @"32768-byte m68k frame budget (16-bit a6 displacement) "
                           @"— split it into smaller functions or reduce large locals",
                           fn.name, frameSize];
        }

    [out appendFormat:@"\t.globl\t%@\n%@:\n", m68kSym(fn.name), m68kSym(fn.name)];
    [out appendFormat:@"\tlink\ta6,#-%d\n", frameSize];
    for (NSString* r in gHomeSaves) // persist clobbered callee-saved homes
        [out appendFormat:@"\tmove.l\t%@,%@(a6)\n", r, gHomeSaveOff[r]];
    for (NSString* r in gPtrARegSaves) // save pointer-IV address regs (callee-saved)
        [out appendFormat:@"\tmove.l\t%@,%@(a6)\n", r, gPtrARegSaveOff[r]];
    // Seed homed parameters: they arrive on the caller's stack (positive a6
    // offset), so their home register would otherwise be uninitialised.
    //
    // In VALUE-ID order, not gHome's. Enumerating the dictionary walks it in
    // Foundation's hash order, which made the emitted parameter-seed sequence
    // depend on how NSNumber keys happen to hash — stable for one process and
    // one Foundation, and not a property of the program being compiled. (Found
    // by the self-hosted port, which had no reason to reproduce it; same class
    // as the hash-ordered IR emission in XTIROptPointerIV / XTIROptConstHoist.)
    NSArray<NSNumber*>* seedOrder =
        [gHome.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber* vid in seedOrder)
        {
        NSNumber* off = slots[vid];
        if (off && off.intValue > 0)
            [out appendFormat:@"\tmove.l\t%d(a6),%@\n", off.intValue, gHome[vid]];
        }

    for (XTIRBlock* bb in fn.blocks)
        {
        if (bb.name)
            [out appendFormat:@"%@:\n", [self labelFor:fn block:bb]];
        for (XTIRInsn* insn in bb.instructions)
            {
            // A pointer-IV advance (pNext = ElementAddr(p, const), homed in an
            // address register) is deferred to AFTER the loads that read the
            // pre-advance pointer, then emitted in place — see below.
            if (insn.result && gPtrAdvance[@(insn.result.valueId)])
                continue;
            [self emitInsn:insn fn:fn block:bb mod:mod slots:slots cpu:cpu into:out];
            }
        // deferred in-place advances
        for (XTIRInsn* insn in bb.instructions)
            {
            NSNumber* disp = insn.result ? gPtrAdvance[@(insn.result.valueId)] : nil;
            if (!disp)
                continue;
            NSString* reg = gPtrAReg[@(insn.result.valueId)];
            long long d = disp.longLongValue;
            if (d >= 1 && d <= 8)
                [out appendFormat:@"\taddq.l\t#%lld,%@\n", d, reg];
            else if (d >= -8 && d <= -1)
                [out appendFormat:@"\tsubq.l\t#%lld,%@\n", -d, reg];
            else
                [out appendFormat:@"\tadda.l\t#%lld,%@\n", d, reg];
            }
        if (bb.terminator)
            [self emitInsn:bb.terminator fn:fn block:bb mod:mod slots:slots cpu:cpu into:out];
        }
    }

+ (NSString*)labelFor:(XTIRFunction*)fn block:(XTIRBlock*)bb
    {
    return [NSString stringWithFormat:@".%@$%@", fn.name, bb.name ?: @"bb"];
    }

// ── Aggregate layout. Field OFFSETS come verbatim from the recorded IR
// layout — the front end lays fields out once with the per-target
// field-alignment cap (2 on m68k: the m68k C ABI, and what keeps a
// multi-byte field off an odd address, where a 68000 takes an address
// error — blewit #5) and every backend reads the same offsets. Widths
// still must match the FE's (the type-width invariant). ─────────────────
+ (NSUInteger)m68kFieldWidth:(XTIRType*)t
    {
    if (!t)
        return 4;
    if (t.kind == XTIRTypeKindPtr)
        return 4;
    if (t.kind == XTIRTypeKindAgg && t.layout)
        return [self m68kAggSize:t.layout];
    return t.byteWidth ?: 1;
    }
+ (NSUInteger)m68kAggSize:(XTIRLayout*)lay
    {
    NSUInteger s = 0;
    for (XTIRLayoutField* f in lay.fields)
        s += [self m68kFieldWidth:f.type];
    if (s < lay.size)
        s = lay.size; // honour the padded layout size (bug 015)
    return s ?: 1;
    }
+ (NSUInteger)m68kFieldOffset:(XTIRLayout*)lay index:(NSUInteger)idx
    {
    if (!lay || idx >= lay.fields.count)
        return [self m68kAggSize:lay];
    return lay.fields[idx].byteOffset;
    }

// ── Operand helpers ─────────────────────────────────────────────────────
// The IR TYPE an operand is read at (nil when it has none) — the type-level
// companion to widthOf:, for the places that need the KIND and not just the
// byte count.
+ (nullable XTIRType*)operandType:(XTIROperand*)op fn:(XTIRFunction*)fn
    {
    if (op.kind == XTIROperandKindImmI)
        return op.type;
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = [fn valueForId:op.valueId];
        if (v)
            return v.type;
        }
    return nil;
    }

+ (uint32_t)widthOf:(XTIROperand*)op fn:(XTIRFunction*)fn
    {
    if (op.kind == XTIROperandKindImmI)
        return op.type ? op.type.byteWidth : 4;
    if (op.kind == XTIROperandKindUse)
        {
        XTIRValue* v = [fn valueForId:op.valueId];
        if (v && v.type.byteWidth)
            return v.type.byteWidth;
        }
    return 4;
    }

// FPU format suffix for a float type / operand.
+ (NSString*)fsfx:(XTIRType*)t
    {
    return (t && t.kind == XTIRTypeKindF64) ? @"d" : @"s";
    }
+ (NSString*)fsfxOp:(XTIROperand*)op fn:(XTIRFunction*)fn
    {
    XTIRType* t = (op.kind == XTIROperandKindUse) ? [fn valueForId:op.valueId].type : op.type;
    return [self fsfx:t];
    }
+ (int)slotOff:(XTIROperand*)op slots:(NSDictionary*)slots
    {
    NSNumber* o = slots[@(op.valueId)];
    return o ? o.intValue : 0;
    }

// Widen a narrow integer in data register `r` to a full 32-bit value before a
// 32-bit operation (divs.l/divu.l/muls.l). Sign-extend for a signed opcode,
// zero-extend (mask) for unsigned, using the instruction's result width.
+ (void)extendReg:(NSString*)r toLongFor:(XTIRInsn*)insn into:(NSMutableString*)out
    {
    NSUInteger w = insn.result ? insn.result.type.byteWidth : 4;
    if (w >= 4 || w == 0)
        return;
    BOOL sgn = (insn.opcode == XTIROpSDiv || insn.opcode == XTIROpSRem);
    if (sgn)
        {
        if (w == 1)
            [out appendFormat:@"\text.w\t%@\n\text.l\t%@\n", r, r];
        else
            [out appendFormat:@"\text.l\t%@\n", r]; // w == 2
        }
    else
        {
        [out appendFormat:@"\tand.l\t#$%lX,%@\n",
                          (unsigned long)(w == 1 ? 0xFF : 0xFFFF), r];
        }
    }

+ (void)loadOperand:(XTIROperand*)op
            intoReg:(NSString*)reg
              slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
               into:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        [out appendFormat:@"\tmove.l\t#%lld,%@\n", (long long)op.intValue, reg];
        }
    else if (op.kind == XTIROperandKindUse)
        {
        NSString* pareg = gPtrAReg[@(op.valueId)]; // walking pointer → its address reg
        if (pareg)
            {
            if (![pareg isEqualToString:reg])
                [out appendFormat:@"\tmove.l\t%@,%@\n", pareg, reg];
            return;
            }
        NSString* home = gHome[@(op.valueId)]; // homed → read the register
        if (home)
            {
            if (![home isEqualToString:reg])
                [out appendFormat:@"\tmove.l\t%@,%@\n", home, reg];
            return;
            }
        NSNumber* off = slots[@(op.valueId)];
        if (off)
            [out appendFormat:@"\tmove.l\t%d(a6),%@\n", off.intValue, reg];
        // No id in the note. A value with no slot is a memory token that
        // reached an operand position — it holds nothing to load, so neither
        // back end emits an instruction and the note is the whole output. The
        // ID, however, is NOT stable across a dump-and-reparse of the IR: the
        // printer renumbers, so this back end's internal id and the id a tool
        // reading the printed IR sees differ by however many values the
        // printer dropped. That made every m68k file differ at -O3 on a
        // comment about nothing. The note still says where it happened; the
        // number was the only unstable part of it.
        else
            [out appendFormat:@"\t; <unmapped use> -> %@\n", reg];
        }
    else
        {
        [out appendFormat:@"\t; <operand kind %d unsupported> -> %@\n", op.kind, reg];
        }
    }

// loadOperand, except a 64-bit operand reads its LOW long. An i64/u64 lives
// in an 8-byte slot pair (high at slot, low at slot+4 — big-endian), and
// loadOperand's single move.l from the slot base silently delivers the HIGH
// half. Callers that consume a 64-bit value AS a 32-bit quantity (an element
// index, a truncation source) want the significant half. Non-64-bit operands
// take the plain path unchanged.
+ (void)loadOperandLow32:(XTIROperand*)op
                      fn:(XTIRFunction*)fn
                 intoReg:(NSString*)reg
                   slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
                    into:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindUse)
        {
        XTIRType* t = [fn valueForId:op.valueId].type;
        if (t && (t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64))
            {
            NSNumber* off = slots[@(op.valueId)];
            if (off)
                {
                [out appendFormat:@"\tmove.l\t%d(a6),%@\n", off.intValue + 4, reg];
                return;
                }
            // 64-bit values are never homed (they live in slots, like
            // doubles) — fall through only for the unmapped-use diagnostic.
            }
        }
    [self loadOperand:op intoReg:reg slots:slots into:out];
    }

// An eight-byte scalar return arrives in d0:d1 (high:low) — TWO longs. Every
// call site has to store both, and each one used to say so in its own words:
// the direct Call handled F64/I64/U64, CallIndirect handled only F64, and
// VTblDispatch handled none of them and stored d0 alone. Big-endian means d0
// lands at the slot's low address, so the symptom was a correct HIGH word and
// an untouched low one — `i64 through a virtual or protocol call` returned
// garbage while the same method called directly was fine (found by the
// differential fuzzer; guard: tests/fixtures/int64_return_dispatch.xc).
// One predicate now, so the three sites cannot drift apart again.
// Returns YES when it stored the result, NO when the caller's own path applies.
+ (BOOL)storeWideReturn:(XTIRInsn*)insn
                  slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
                   into:(NSMutableString*)out
    {
    if (!insn.result)
        return NO;
    XTIRTypeKind k = insn.result.type.kind;
    if (k != XTIRTypeKindF64 && k != XTIRTypeKindI64 && k != XTIRTypeKindU64)
        return NO;
    NSNumber* s = slots[@(insn.result.valueId)];
    if (!s)
        return NO;
    [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n",
                      s.intValue, s.intValue + 4];
    return YES;
    }

+ (void)storeReg:(NSString*)reg
        toResult:(XTIRValue*)r
           slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
            into:(NSMutableString*)out
    {
    // A homed value lives in its register; write there ONLY and skip the slot
    // mirror (single-write). Float ops / stack-passed args that read slots
    // directly consume UN-homed values, so their slots are still authoritative.
    NSString* home = gHome[@(r.valueId)];
    if (home)
        {
        if (![home isEqualToString:reg])
            [out appendFormat:@"\tmove.l\t%@,%@\n", reg, home];
        return;
        }
    NSNumber* off = slots[@(r.valueId)];
    if (off)
        [out appendFormat:@"\tmove.l\t%@,%d(a6)\n", reg, off.intValue];
    }

// Soft-float binary op via the libgcc-style runtime (__addsf3 / __adddf3
// …). f32: args in d0/d1, result d0. f64: args pushed (high word first),
// result d0:d1.
+ (void)emitSoftFloatBinary:(NSString*)op dbl:(BOOL)dbl
                         o0:(int)o0
                         o1:(int)o1
                     result:(int)r
                       into:(NSMutableString*)out
    {
    if (dbl)
        {
        [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o1 + 4, o1];
        [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o0 + 4, o0];
        [out appendFormat:@"\tjsr\t__%@df3\n\tlea\t16(sp),sp\n", op];
        [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n", r, r + 4];
        }
    else
        {
        [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\t%d(a6),d1\n", o0, o1];
        [out appendFormat:@"\tjsr\t__%@sf3\n\tmove.l\td0,%d(a6)\n", op, r];
        }
    }

// 64-bit integer binary op via a line-A HLE helper, using the SAME shape as the
// soft-float f64 path: both operands pushed high word first, result in d0:d1,
// stored back to the result's slot.
//
// Doing it this way rather than with register pairs is deliberate. An i64 value
// lives in a memory slot exactly as a double does, so the register allocator —
// which reasons in single 32-bit registers — needs no notion of a pair, and the
// only new thing in the back end is the call. The helpers themselves are
// two-word line-A stubs the host executes natively (private:docs/Design/m68k-math-hle.md).
// Push one 64-bit operand: low long first, so the high long ends up at the
// lower address (big-endian), matching how a double is passed.
//
// An operand is NOT always slot-resident. `slotOff:` answers 0 for anything
// without a slot, so an immediate — `x + (u64)5` — would have been read from
// 0(a6) and 4(a6): the saved frame pointer and the return address.
+ (void)pushInt64Operand:(XTIROperand*)op
                      fn:(XTIRFunction*)fn
                   slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
                    into:(NSMutableString*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        uint64_t v = (uint64_t)op.intValue;
        [out appendFormat:@"\tmove.l\t#%u,-(sp)\n", (unsigned)(v & 0xFFFFFFFFu)];
        [out appendFormat:@"\tmove.l\t#%u,-(sp)\n", (unsigned)(v >> 32)];
        return;
        }
    // An operand of a 64-bit operation is NOT always 64 bits wide. A shift
    // count is the everyday case — `v >> n` lowers as `LShr %wide, %n:U8` — and
    // reading two longs from a four-byte slot took the next slot along as the
    // high half, so the count was some enormous number and the result zero.
    XTIRValue* sv = (op.kind == XTIROperandKindUse) ? [fn valueForId:op.valueId] : nil;
    XTIRTypeKind k = sv ? sv.type.kind : XTIRTypeKindI64;
    if (k != XTIRTypeKindI64 && k != XTIRTypeKindU64)
        {
        [self loadOperand:op intoReg:@"d0" slots:slots into:out];
        [self extendD0ToPairSigned:XTIRTypeKindIsSigned(k)
                             width:[self widthOf:op fn:fn]
                              into:out];
        [out appendString:@"\tmove.l\td0,-(sp)\n\tmove.l\td1,-(sp)\n"]; // low, then high
        return;
        }
    NSNumber* o = slots[@(op.valueId)];
    int off = o ? o.intValue : 0;
    [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", off + 4, off];
    }

// Extend the 32-bit value in d0 to the pair d1:d0 (high:low), in place.
+ (void)extendD0ToPairSigned:(BOOL)sgn width:(uint32_t)w into:(NSMutableString*)out
    {
    if (sgn)
        {
        if (w == 1)
            [out appendString:@"\text.w\td0\n\text.l\td0\n"];
        else if (w == 2)
            [out appendString:@"\text.l\td0\n"];
        // Smear the sign across the high long: d1 = d0 >> 31 (arithmetic).
        [out appendString:@"\tmove.l\td0,d1\n\tasr.l\t#8,d1\n"
                          @"\tasr.l\t#8,d1\n\tasr.l\t#8,d1\n\tasr.l\t#7,d1\n"];
        }
    else
        {
        if (w == 1)
            [out appendString:@"\tand.l\t#$ff,d0\n"];
        else if (w == 2)
            [out appendString:@"\tand.l\t#$ffff,d0\n"];
        [out appendString:@"\tmoveq\t#0,d1\n"];
        }
    }

+ (void)emitInt64Binary:(NSString*)helper
                     a0:(XTIROperand*)a0
                     a1:(XTIROperand*)a1
                 result:(int)r
                     fn:(XTIRFunction*)fn
                  slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
                   into:(NSMutableString*)out
    {
    [self pushInt64Operand:a1 fn:fn slots:slots into:out];
    [self pushInt64Operand:a0 fn:fn slots:slots into:out];
    [out appendFormat:@"\tjsr\t%@\n\tlea\t16(sp),sp\n", helper];
    [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n", r, r + 4];
    }

// Emit `<mnem>.l <src>, <dst>` using the cheapest addressing for the source:
// an immediate (`addq`/`subq` for add/sub of 1-8, else `addi`/`andi`/…), a home
// register, or a memory slot (m68k ALU ops take a memory source directly). Falls
// back to loading the source into d1.
+ (void)emitAlu:(NSString*)mnem src:(XTIROperand*)src dst:(NSString*)dst
          slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
           into:(NSMutableString*)out
    {
    if (src.kind == XTIROperandKindImmI)
        {
        long long k = src.intValue;
        BOOL addsub = [mnem isEqualToString:@"add"] || [mnem isEqualToString:@"sub"];
        if (addsub && k >= 1 && k <= 8)
            [out appendFormat:@"\t%@q.l\t#%lld,%@\n", mnem, k, dst];
        else
            [out appendFormat:@"\t%@.l\t#%lld,%@\n", mnem, k, dst];
        return;
        }
    // Source = a home register when available; otherwise load into d1. (A memory
    // source — `add.l d16(a6),Dn` — would save the load, but xta mis-encodes the
    // ALU-with-memory-source direction bit, so it is NOT used here. TODO: fix the
    // xta encoding, then a spilled operand can be an ea source directly.)
    // Source = home register, or a memory slot directly (`add.l d16(a6),Dn`).
    // EXCEPTION: eor has no `<ea>,Dn` form on m68k (only `Dn,<ea>`), so its source
    // must be a data register — load a spilled eor operand into d1.
    NSString* ea = nil;
    if (src.kind == XTIROperandKindUse)
        {
        NSString* home = gHome[@(src.valueId)];
        if (home)
            ea = home;
        else if (![mnem isEqualToString:@"eor"])
            {
            NSNumber* off = slots[@(src.valueId)];
            if (off)
                ea = [NSString stringWithFormat:@"%d(a6)", off.intValue];
            }
        }
    if (!ea)
        {
        [self loadOperand:src intoReg:@"d1" slots:slots into:out];
        ea = @"d1";
        }
    [out appendFormat:@"\t%@.l\t%@,%@\n", mnem, ea, dst];
    }

// dst = op0 <mnem> op1. Two-address: compute directly in the result's home
// register (or d0), so a homed accumulator/IV needs no scratch round-trip.
+ (void)emitBinary:(NSString*)mnem
              insn:(XTIRInsn*)insn
             slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
              into:(NSMutableString*)out
    {
    XTIROperand *a = insn.operands[0], *b = insn.operands[1];
    BOOL commut = ![mnem isEqualToString:@"sub"];
    NSString* rhome = insn.result ? gHome[@(insn.result.valueId)] : nil;
    NSString* dst = rhome ?: @"d0";
    NSString* aHome = (a.kind == XTIROperandKindUse) ? gHome[@(a.valueId)] : nil;
    NSString* bHome = (b.kind == XTIROperandKindUse) ? gHome[@(b.valueId)] : nil;
    BOOL aInDst = aHome && [aHome isEqualToString:dst];
    BOOL bInDst = bHome && [bHome isEqualToString:dst];

    XTIROperand* src;
    if (aInDst)
        src = b; // dst already holds a
    else if (bInDst && commut)
        src = a; // dst holds b; commute
    // sub with b in dst
    else if (bInDst)
        {
        [out appendFormat:@"\tmove.l\t%@,d1\n", dst]; // save b
        [self loadOperand:a intoReg:dst slots:slots into:out];
        [out appendFormat:@"\tsub.l\td1,%@\n", dst];
        [self storeReg:dst toResult:insn.result slots:slots into:out];
        return;
        }
    else
        {
        [self loadOperand:a intoReg:dst slots:slots into:out];
        src = b;
        }

    [self emitAlu:mnem src:src dst:dst slots:slots into:out];
    [self storeReg:dst toResult:insn.result slots:slots into:out];
    }

// Bcc mnemonic for the NEGATED ICmp predicate (branch-to-false when the
// condition is false, so a fused CondBranch can skip the boolean).
+ (NSString*)condForNegatedPredicate:(uint8_t)p
    {
    switch (p)
        {
    case XTIRICmpEQ:
        return @"ne";
    case XTIRICmpNE:
        return @"eq";
    case XTIRICmpSLT:
        return @"ge";
    case XTIRICmpSGT:
        return @"le";
    case XTIRICmpSLE:
        return @"gt";
    case XTIRICmpSGE:
        return @"lt";
    case XTIRICmpULT:
        return @"cc";
    case XTIRICmpUGT:
        return @"ls";
    case XTIRICmpULE:
        return @"hi";
    case XTIRICmpUGE:
        return @"cs";
    default:
        return @"ne";
        }
    }

// Scc/Bcc condition mnemonic for an ICmp predicate.
+ (NSString*)condForPredicate:(uint8_t)p
    {
    switch (p)
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
        return @"cs";
    case XTIRICmpUGT:
        return @"hi";
    case XTIRICmpULE:
        return @"ls";
    case XTIRICmpUGE:
        return @"cc";
    default:
        return @"eq";
        }
    }

// Copy each phi value flowing along the edge from -> to into the phi's slot.
// Source addressing for a value: an immediate, its home register, or its memory
// slot. nil if unmapped.
+ (NSString*)eaOf:(XTIROperand*)op slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
    {
    if (op.kind == XTIROperandKindImmI)
        return [NSString stringWithFormat:@"#%lld", (long long)op.intValue];
    if (op.kind == XTIROperandKindUse)
        {
        NSString* home = gHome[@(op.valueId)];
        if (home)
            return home;
        NSNumber* off = slots[@(op.valueId)];
        if (off)
            return [NSString stringWithFormat:@"%d(a6)", off.intValue];
        }
    return nil;
    }

// An i64 phi is EIGHT bytes in a slot, so the `move.l` on the scalar path
// copied only its high long and left the low one holding whatever the slot had.
// Aggregates already had this fix; the eight-byte scalars were missed.
//
// F64 travels this path too. A double through a ternary or round a loop is a
// phi of exactly the same width, and it lost its low long the same way — which
// stayed invisible for as long as anyone tested with 1.5 / 3.25 / 7.75. Every
// one of those has a ZERO low word, so half a copy still gives the right
// answer; 3.1 does not, and came back as 3.0999984741.
+ (BOOL)emitWidePhiCopyTo:(XTIRValue*)dest from:(XTIROperand*)src
                    slots:(NSDictionary*)slots
                     into:(NSMutableString*)out
    {
    XTIRType* dt = dest.type;
    if (!dt || !(dt.kind == XTIRTypeKindI64 || dt.kind == XTIRTypeKindU64 || dt.kind == XTIRTypeKindF64))
        return NO;
    NSNumber* ds = slots[@(dest.valueId)];
    if (!ds)
        return NO;
    int d = ds.intValue;
    if (src.kind == XTIROperandKindImmI)
        {
        uint64_t v = (uint64_t)src.intValue;
        [out appendFormat:@"\tmove.l\t#%u,%d(a6)\n", (unsigned)(v >> 32), d];
        [out appendFormat:@"\tmove.l\t#%u,%d(a6)\n", (unsigned)(v & 0xFFFFFFFFu), d + 4];
        return YES;
        }
    if (src.kind == XTIROperandKindImmF)
        {
        uint64_t bits = src.floatRawBytes; // the IEEE double pattern
        [out appendFormat:@"\tmove.l\t#$%08X,%d(a6)\n", (uint32_t)(bits >> 32), d];
        [out appendFormat:@"\tmove.l\t#$%08X,%d(a6)\n", (uint32_t)(bits & 0xFFFFFFFF), d + 4];
        return YES;
        }
    if (src.kind != XTIROperandKindUse)
        return NO;
    NSNumber* ss = slots[@(src.valueId)];
    if (!ss)
        return NO;
    [out appendFormat:@"\tmove.l\t%d(a6),%d(a6)\n", ss.intValue, d];
    [out appendFormat:@"\tmove.l\t%d(a6),%d(a6)\n", ss.intValue + 4, d + 4];
    return YES;
    }

+ (void)emitPhiCopiesFrom:(XTIRBlock*)from
                       to:(XTIRBlock*)to
                       fn:(XTIRFunction*)fn
                    slots:(NSDictionary*)slots
                     into:(NSMutableString*)out
    {
    // Collect this edge's copies (each phi's dest <- its operand for `from`).
    NSMutableArray<XTIRValue*>* dests = [NSMutableArray array];
    NSMutableArray<XTIROperand*>* srcs = [NSMutableArray array];
    for (XTIRInsn* phi in to.phiNodes)
        {
        NSArray<XTIROperand*>* ops = phi.operands;
        for (NSUInteger i = 0; i + 1 < ops.count; i += 2)
            {
            if (ops[i].kind == XTIROperandKindBlock && ops[i].blockRef == from)
                {
                [dests addObject:phi.result];
                [srcs addObject:ops[i + 1]];
                break;
                }
            }
        }
    if (dests.count == 0)
        return;

    // Direct sequential copies are safe iff no phi's DEST location is a DIFFERENT
    // phi's SOURCE location (a sequential write would clobber a not-yet-read
    // source). A location is a home register OR a frame slot: the slot case is
    // load-bearing when one phi's SOURCE value is itself another phi's DEST —
    // e.g. `v0 <- lc4` emitted alongside `lc4 <- lc4+1`, where after the inner
    // loop unrolls `v0`'s source copy-propagates to the counter `lc4`. Writing
    // lc4's slot first then reading it for v0 hands v0 the post-increment value
    // (a lost copy). Both live in slots, not registers, so a register-only check
    // missed it. The common loop case (independent accumulator/IV updates) stays
    // safe; a true cycle (e.g. a swap) still needs the stack parallel-copy
    // fallback. Aggregates are excluded — they take the safe-path byte copy and
    // never share the scalar stack shuffle.
    NSString* (^locOf)(XTIRValueId) = ^NSString*(XTIRValueId vid) {
      NSString* h = gHome[@(vid)];
      if (h)
          return h;
      NSNumber* off = slots[@(vid)];
      return off ? [NSString stringWithFormat:@"%d(a6)", off.intValue] : nil;
    };
    BOOL safe = YES;
    for (NSUInteger i = 0; i < dests.count && safe; i++)
        {
        if (dests[i].type.kind == XTIRTypeKindAgg)
            continue;
        NSString* rd = locOf(dests[i].valueId);
        if (!rd)
            continue;
        for (NSUInteger j = 0; j < srcs.count; j++)
            {
            if (i == j || srcs[j].kind != XTIROperandKindUse)
                continue;
            NSString* rs = locOf(srcs[j].valueId);
            if (rs && [rs isEqualToString:rd])
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
            // Pointer-IV walking pointer: the dest homes in an address register.
            // On the back edge the source IS that register (already advanced in
            // place) → no-op; on the preheader edge, load the base into it.
            NSString* destAReg = gPtrAReg[@(dests[i].valueId)];
            if (destAReg)
                {
                NSString* srcAReg = srcs[i].kind == XTIROperandKindUse
                                        ? gPtrAReg[@(srcs[i].valueId)]
                                        : nil;
                if (![destAReg isEqualToString:srcAReg])
                    [self loadOperand:srcs[i] intoReg:destAReg slots:slots into:out];
                continue;
                }
            // An AGGREGATE phi is a slot-to-slot BYTE COPY, not a `move.l`.
            // A struct value always lives in a frame slot (aggregates are never
            // homed), so a 4-byte move copied only its first four bytes and silently
            // dropped the rest — an 8-byte Rect through a ternary kept x,y and zeroed
            // w,h. The same "not just a 4-byte move.l" fix already exists for an
            // aggregate Store; the phi was missed.
            if ([self emitWidePhiCopyTo:dests[i] from:srcs[i] slots:slots into:out])
                continue;
            XTIRType* dt = dests[i].type;
            if (dt && dt.kind == XTIRTypeKindAgg && dt.layout && srcs[i].kind == XTIROperandKindUse)
                {
                NSUInteger width = [self m68kAggSize:dt.layout];
                NSNumber* ds = slots[@(dests[i].valueId)];
                if (!ds)
                    continue;
                [out appendFormat:@"\tlea\t%d(a6),a0\n", ds.intValue]; // dest
                [out appendFormat:@"\tlea\t%d(a6),a1\n", [self slotOff:srcs[i] slots:slots]];
                int n = gLabelSeq++;
                [out appendFormat:@"\tmove.l\t#%lu,d0\n.Lphicpy%d:\n\tmove.b\t(a1)+,(a0)+\n"
                                  @"\tsubq.l\t#1,d0\n\tbne.s\t.Lphicpy%d\n",
                                  (unsigned long)width, n, n];
                continue;
                }
            NSString* ea = [self eaOf:srcs[i] slots:slots];
            if (!ea)
                {
                [self loadOperand:srcs[i] intoReg:@"d0" slots:slots into:out];
                ea = @"d0";
                }
            NSString* dHome = gHome[@(dests[i].valueId)];
            NSNumber* dSlot = slots[@(dests[i].valueId)];
            if (dHome)
                {
                if (![ea isEqualToString:dHome])
                    [out appendFormat:@"\tmove.l\t%@,%@\n", ea, dHome];
                // single-write: the home register is authoritative; skip the slot.
                }
            else if (dSlot)
                {
                [out appendFormat:@"\tmove.l\t%@,%d(a6)\n", ea, dSlot.intValue]; // mem-to-mem ok on m68k
                }
            }
        return;
        }
    // Cycle: read EVERY source (push) before writing ANY dest (pop reverse).
    // Pointer-IV walking pointers (address-register homes) are handled directly
    // and excluded from the stack shuffle (they can't be in a d-register cycle).
    NSMutableArray<XTIRValue*>* cd = [NSMutableArray array];
    NSMutableArray<XTIROperand*>* cs = [NSMutableArray array];
    for (NSUInteger i = 0; i < dests.count; i++)
        {
        NSString* destAReg = gPtrAReg[@(dests[i].valueId)];
        XTIRType* dt = dests[i].type;
        if (destAReg)
            {
            NSString* srcAReg = srcs[i].kind == XTIROperandKindUse
                                    ? gPtrAReg[@(srcs[i].valueId)]
                                    : nil;
            if (![destAReg isEqualToString:srcAReg])
                [self loadOperand:srcs[i] intoReg:destAReg slots:slots into:out];
            }
        else if ([self emitWidePhiCopyTo:dests[i] from:srcs[i] slots:slots into:out])
            {
            // Eight-byte scalar: copied in place, exactly as an aggregate is
            // below. Both step outside the read-all-then-write-all discipline,
            // so a cycle whose members are 64-bit would still be wrong — no
            // such cycle exists today, and it would need a wide shuffle.
            continue;
            }
        else if (dt && dt.kind == XTIRTypeKindAgg && dt.layout && srcs[i].kind == XTIROperandKindUse)
            {
            // An aggregate is a slot-to-slot byte copy — a 4-byte push/pop would
            // truncate it. Copy the full width in place (aggregates have their own
            // slot and can't participate in the scalar d-register shuffle below).
            NSUInteger width = [self m68kAggSize:dt.layout];
            NSNumber* ds = slots[@(dests[i].valueId)];
            if (!ds)
                continue;
            [out appendFormat:@"\tlea\t%d(a6),a0\n", ds.intValue];
            [out appendFormat:@"\tlea\t%d(a6),a1\n", [self slotOff:srcs[i] slots:slots]];
            int n = gLabelSeq++;
            [out appendFormat:@"\tmove.l\t#%lu,d0\n.Lphicpy%d:\n\tmove.b\t(a1)+,(a0)+\n"
                              @"\tsubq.l\t#1,d0\n\tbne.s\t.Lphicpy%d\n",
                              (unsigned long)width, n, n];
            }
        else
            {
            [cd addObject:dests[i]];
            [cs addObject:srcs[i]];
            }
        }
    for (XTIROperand* s in cs)
        {
        [self loadOperand:s intoReg:@"d0" slots:slots into:out];
        [out appendString:@"\tmove.l\td0,-(sp)\n"];
        }
    for (NSInteger i = (NSInteger)cd.count - 1; i >= 0; i--)
        {
        [out appendString:@"\tmove.l\t(sp)+,d0\n"];
        [self storeReg:@"d0" toResult:cd[i] slots:slots into:out];
        }
    }

// Memory operand for a folded ElementAddr/FieldAddr. Emits the needed loads
// (base → a0; ElementAddr index → d1 if not homed) and returns the m68k ea:
// `off(a0)` for a struct field, `(a0,dN.l*stride)` for a scaled array index.
+ (NSString*)foldedMemOp:(XTIRInsn*)ea fn:(XTIRFunction*)fn
                   slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
                    into:(NSMutableString*)out
    {
    [self loadOperand:ea.operands[0] intoReg:@"a0" slots:slots into:out]; // base → a0
    if (ea.opcode == XTIROpFieldAddr)
        {
        XTIRValue* bv = [fn valueForId:ea.operands[0].valueId];
        XTIRLayout* lay = bv.type.pointeeType.layout;
        uint32_t off = lay ? (uint32_t)[self m68kFieldOffset:lay index:(int)ea.operands[1].intValue] : 0;
        return off ? [NSString stringWithFormat:@"%u(a0)", off] : @"(a0)";
        }
    XTIRType* rt = ea.result.type;
    uint32_t stride = (rt && rt.pointeeType) ? (uint32_t)[self m68kFieldWidth:rt.pointeeType] : 1;
    XTIROperand* idx = ea.operands[1];
    // A 64-bit index reads its LOW long (slot+4, big-endian): loadOperand
    // brings the HIGH half, so every folded u64-indexed access resolved to
    // element 0 (u64_index_subscript summed words[0] eight times) — and a
    // register HOME is no better, since a 32-bit home holds one half. The
    // slot pair is authoritative; skip the home entirely for i64.
    XTIRValue* idxVal = (idx.kind == XTIROperandKindUse) ? [fn valueForId:idx.valueId] : nil;
    BOOL idx64 = idxVal.type && (idxVal.type.kind == XTIRTypeKindI64 || idxVal.type.kind == XTIRTypeKindU64);
    NSString* idxReg = (!idx64 && idx.kind == XTIROperandKindUse) ? gHome[@(idx.valueId)] : nil;
    if (!idxReg)
        {
        [self loadOperandLow32:idx fn:fn intoReg:@"d1" slots:slots into:out];
        idxReg = @"d1";
        }
    return stride == 1 ? [NSString stringWithFormat:@"(a0,%@.l)", idxReg]
                       : [NSString stringWithFormat:@"(a0,%@.l*%u)", idxReg, stride];
    }

+ (void)emitInsn:(XTIRInsn*)insn
              fn:(XTIRFunction*)fn
           block:(XTIRBlock*)bb
             mod:(XTIRModule*)mod
           slots:(NSDictionary<NSNumber*, NSNumber*>*)slots
             cpu:(NSInteger)cpu
            into:(NSMutableString*)out
    {
    // ── 64-bit integer ops, intercepted before the 32-bit switch ─────────
    // Every integer case below works in `.l` registers and would silently
    // compute only the low half of an i64. An i64 lives in a memory slot like
    // a double does, so each operation is one HLE call rather than a register
    // pair the allocator would have to learn about.
    // A 64-bit CONSTANT needs both longs written. The Const case below emits a
    // single `move.l #imm`, which left the high word holding whatever the slot
    // had — the low half of every result was right and the high half was not.
    if (insn.opcode == XTIROpConst && insn.result && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64) && insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindImmI)
        {
        NSNumber* off = slots[@(insn.result.valueId)];
        if (off)
            {
            uint64_t v = (uint64_t)insn.operands[0].intValue;
            [out appendFormat:@"\tmove.l\t#%u,%d(a6)\n",
                              (unsigned)(v >> 32), off.intValue]; // high long first
            [out appendFormat:@"\tmove.l\t#%u,%d(a6)\n",
                              (unsigned)(v & 0xFFFFFFFFu), off.intValue + 4];
            return;
            }
        }
    // Widening INTO 64 bits, and truncating out of it. `(u64)1000000` is not a
    // 64-bit constant — it is a 32-bit Const followed by a ZExt — so without
    // this the low long was written and the high long kept whatever the slot
    // held, which is a correct low half and a wrong high half.
    if (insn.result && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64) && (insn.opcode == XTIROpZExt || insn.opcode == XTIROpSExt) && insn.operands.count >= 1)
        {
        NSNumber* off = slots[@(insn.result.valueId)];
        if (off)
            {
            int r = off.intValue;
            [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
            [self extendD0ToPairSigned:(insn.opcode == XTIROpSExt)
                                 width:[self widthOf:insn.operands[0] fn:fn]
                                  into:out];
            // Big-endian: the HIGH long sits at the lower address.
            [out appendFormat:@"\tmove.l\td1,%d(a6)\n\tmove.l\td0,%d(a6)\n", r, r + 4];
            return;
            }
        }
    // A same-width reinterpretation (i64 <-> u64) is an eight-byte copy, not the
    // `move.l` the generic Bitcast falls through to. `(u64)someI64` wrote the
    // high long into the destination's high long and left its low long holding
    // whatever the slot did — a number that looked plausible until it did not.
    if (insn.opcode == XTIROpBitcast && insn.result && insn.operands.count >= 1 && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64) && insn.operands[0].kind == XTIROperandKindUse)
        {
        XTIRValue* sv = [fn valueForId:insn.operands[0].valueId];
        NSNumber* so = slots[@(insn.operands[0].valueId)];
        NSNumber* ro = slots[@(insn.result.valueId)];
        if (sv && so && ro && (sv.type.kind == XTIRTypeKindI64 || sv.type.kind == XTIRTypeKindU64))
            {
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\td0,%d(a6)\n",
                              so.intValue, ro.intValue];
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\td0,%d(a6)\n",
                              so.intValue + 4, ro.intValue + 4];
            return;
            }
        }
    // Truncating FROM 64 bits reads the LOW long, which is at off+4.
    if (insn.opcode == XTIROpTrunc && insn.result && insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindUse)
        {
        XTIRValue* sv = [fn valueForId:insn.operands[0].valueId];
        if (sv && (sv.type.kind == XTIRTypeKindI64 || sv.type.kind == XTIRTypeKindU64))
            {
            NSNumber* so = slots[@(sv.valueId)];
            if (so)
                {
                [out appendFormat:@"\tmove.l\t%d(a6),d0\n", so.intValue + 4];
                uint32_t tw = insn.result.type ? insn.result.type.byteWidth : 4;
                if (tw == 1)
                    [out appendString:@"\tand.l\t#$ff,d0\n"];
                else if (tw == 2)
                    [out appendString:@"\tand.l\t#$ffff,d0\n"];
                [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
                return;
                }
            }
        }
    // The UNARY 64-bit ops. Without this they fell through to the 32-bit
    // `neg.l d0` / `not.l d0` below, which touches only the low long and leaves
    // the high one holding whatever the slot had — `-1747915140643999929` came
    // back with its high half one too large and its low half zero. Expressed as
    // the equivalent binary helper call (0 - x, x ^ -1) rather than the m68k
    // `neg.l`/`negx.l` pair, because the simulator implements neither NEGX nor
    // ADDX, so the pair would assemble and then trap at run time.
    if (insn.result && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64) && insn.operands.count == 1 && (insn.opcode == XTIROpNeg || insn.opcode == XTIROpNot))
        {
        NSNumber* ro = slots[@(insn.result.valueId)];
        if (ro)
            {
            XTIROperand* k = [XTIROperand immIWithType:insn.result.type
                                                 value:(insn.opcode == XTIROpNeg ? 0 : -1)];
            if (insn.opcode == XTIROpNeg)
                [self emitInt64Binary:@"__subdi3"
                                   a0:k
                                   a1:insn.operands[0]
                               result:ro.intValue
                                   fn:fn
                                slots:slots
                                 into:out];
            else
                [self emitInt64Binary:@"__xordi3"
                                   a0:insn.operands[0]
                                   a1:k
                               result:ro.intValue
                                   fn:fn
                                slots:slots
                                 into:out];
            return;
            }
        }
    if (insn.result && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64) && insn.operands.count >= 2)
        {
        BOOL sgn = (insn.result.type.kind == XTIRTypeKindI64);
        NSString* h = nil;
        switch (insn.opcode)
            {
        case XTIROpAdd:
            h = @"__adddi3";
            break;
        case XTIROpSub:
            h = @"__subdi3";
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
        case XTIROpAnd:
            h = @"__anddi3";
            break;
        case XTIROpOr:
            h = @"__ordi3";
            break;
        case XTIROpXor:
            h = @"__xordi3";
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
        (void)sgn;
        if (h)
            {
            NSNumber* ro = slots[@(insn.result.valueId)];
            if (ro)
                {
                [self emitInt64Binary:h
                                   a0:insn.operands[0]
                                   a1:insn.operands[1]
                               result:ro.intValue
                                   fn:fn
                                slots:slots
                                 into:out];
                return;
                }
            }
        }
    switch (insn.opcode)
        {

    case XTIROpConst:
        {
        XTIROperand* op = insn.operands.firstObject;
        if (op.kind == XTIROperandKindImmI && insn.result)
            {
            NSString* home = gHome[@(insn.result.valueId)]; // single-write the home
            if (home)
                {
                [out appendFormat:@"\tmove.l\t#%lld,%@\n", (long long)op.intValue, home];
                }
            else
                {
                NSNumber* off = slots[@(insn.result.valueId)];
                if (off)
                    [out appendFormat:@"\tmove.l\t#%lld,%d(a6)\n",
                                      (long long)op.intValue, off.intValue];
                }
            }
        else if (op.kind == XTIROperandKindImmF && insn.result)
            {
            // floatRawBytes is the IEEE double bit pattern. Store f32 or f64.
            int off = slots[@(insn.result.valueId)].intValue;
            uint64_t bits = op.floatRawBytes;
            if (insn.result.type.kind == XTIRTypeKindF64)
                {
                [out appendFormat:@"\tmove.l\t#$%08X,%d(a6)\n", (uint32_t)(bits >> 32), off];
                [out appendFormat:@"\tmove.l\t#$%08X,%d(a6)\n", (uint32_t)(bits & 0xFFFFFFFF), off + 4];
                }
            else
                {
                double dv;
                memcpy(&dv, &bits, 8);
                float fv = (float)dv;
                uint32_t fb;
                memcpy(&fb, &fv, 4);
                [out appendFormat:@"\tmove.l\t#$%08X,%d(a6)\n", fb, off];
                }
            }
        else
            [out appendString:@"\t; TODO Const (non-int)\n"];
        break;
        }
    case XTIROpCopy:
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;

    case XTIROpAdd:
        [self emitBinary:@"add" insn:insn slots:slots into:out];
        break;
    case XTIROpSub:
        [self emitBinary:@"sub" insn:insn slots:slots into:out];
        break;
    case XTIROpAnd:
        [self emitBinary:@"and" insn:insn slots:slots into:out];
        break;
    case XTIROpOr:
        [self emitBinary:@"or" insn:insn slots:slots into:out];
        break;
    case XTIROpXor:
        [self emitBinary:@"eor" insn:insn slots:slots into:out];
        break;

    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
        {
        NSString* m = insn.opcode == XTIROpShl    ? @"lsl"
                      : insn.opcode == XTIROpLShr ? @"lsr"
                                                  : @"asr";
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        // The shift is full-width (.l), so a narrow operand's high bits must be
        // correct: asr.l needs the value SIGN-extended (else it shifts in 0s),
        // and lsr.l needs it ZERO-extended (else stale/sign upper bits shift
        // DOWN into the result — (u8)253 >> 2 gave 255 instead of 63). Shl is
        // unaffected (its result's low W bits don't depend on the high bits).
        uint32_t vw = [self widthOf:insn.operands[0] fn:fn];
        if (insn.opcode == XTIROpAShr)
            {
            if (vw == 1)
                [out appendString:@"\text.w\td0\n\text.l\td0\n"];
            else if (vw == 2)
                [out appendString:@"\text.l\td0\n"];
            }
        else if (insn.opcode == XTIROpLShr)
            {
            if (vw == 1)
                [out appendString:@"\tand.l\t#$ff,d0\n"];
            else if (vw == 2)
                [out appendString:@"\tand.l\t#$ffff,d0\n"];
            }
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out];
        [out appendFormat:@"\t%@.l\td1,d0\n", m];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpMul:
        {
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out];
        if (cpu >= 68020)
            [out appendString:@"\tmuls.l\td1,d0\n"];
        else
            [out appendString:@"\tjsr\t__mulsi3\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpUDiv:
    case XTIROpSDiv:
        {
        // (helper used here and by URem/SRem — see +extendReg below)
        NSString* m = insn.opcode == XTIROpUDiv ? @"divu.l" : @"divs.l";
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out];
        // The divide is 32-bit; a narrow operand left in the low word with stale
        // upper bits would divide as a wrong 32-bit number ((i16)-5511 as +60025).
        [self extendReg:@"d0" toLongFor:insn into:out];
        [self extendReg:@"d1" toLongFor:insn into:out];
        if (cpu >= 68020)
            [out appendFormat:@"\t%@\td1,d0\n", m];
        else
            [out appendFormat:@"\tjsr\t%@\n",
                              insn.opcode == XTIROpUDiv ? @"__udivsi3" : @"__divsi3"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpURem:
    case XTIROpSRem:
        {
        // rem = a - (a/b)*b   (low 32 bits of q*b are sign-agnostic)
        NSString* m = insn.opcode == XTIROpURem ? @"divu.l" : @"divs.l";
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out]; // a
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out]; // b
        [self extendReg:@"d0" toLongFor:insn into:out];                         // 32-bit divs.l/muls.l
        [self extendReg:@"d1" toLongFor:insn into:out];                         // need full 32-bit operands
        if (cpu >= 68020)
            {
            [out appendString:@"\tmove.l\td0,d2\n"]; // save a
            [out appendFormat:@"\t%@\td1,d0\n", m];  // d0 = a/b
            [out appendString:@"\tmuls.l\td1,d0\n"]; // d0 = (a/b)*b
            [out appendString:@"\tsub.l\td0,d2\n"];  // d2 = a - (a/b)*b
            [self storeReg:@"d2" toResult:insn.result slots:slots into:out];
            }
        else
            {
            [out appendFormat:@"\tjsr\t%@\n",
                              insn.opcode == XTIROpURem ? @"__umodsi3" : @"__modsi3"];
            [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
            }
        break;
        }

    case XTIROpNeg:
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [out appendString:@"\tneg.l\td0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
    case XTIROpNot:
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [out appendString:@"\tnot.l\td0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;

    case XTIROpZExt:
        {
        XTIROperand* src = insn.operands[0];
        [self loadOperand:src intoReg:@"d0" slots:slots into:out];
        uint32_t w = [self widthOf:src fn:fn];
        if (w == 1)
            [out appendString:@"\tand.l\t#$ff,d0\n"];
        else if (w == 2)
            [out appendString:@"\tand.l\t#$ffff,d0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpSExt:
        {
        XTIROperand* src = insn.operands[0];
        [self loadOperand:src intoReg:@"d0" slots:slots into:out];
        uint32_t w = [self widthOf:src fn:fn];
        if (w == 1)
            [out appendString:@"\text.w\td0\n\text.l\td0\n"];
        else if (w == 2)
            [out appendString:@"\text.l\td0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpTrunc:
        {
        // Truncation must clear the high bits — a stored value keeps its full
        // 32 bits, so an un-masked `(u16)x` leaves stale upper bits that later
        // full-width u16 arithmetic (e.g. `val/10` in a digit loop) reads as a
        // huge number, overrunning fixed buffers.
        // A 64-bit SOURCE reads its LOW long (slot+4, big-endian) — a plain
        // loadOperand brings the HIGH half, which for any small u64 is 0
        // (u64_index_subscript printed i3=0 u5=0).
        [self loadOperandLow32:insn.operands[0]
                            fn:fn
                       intoReg:@"d0"
                         slots:slots
                          into:out];
        uint32_t tw = insn.result.type ? insn.result.type.byteWidth : 4;
        if (tw == 1)
            [out appendString:@"\tand.l\t#$ff,d0\n"];
        else if (tw == 2)
            [out appendString:@"\tand.l\t#$ffff,d0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFDiv:
        {
        BOOL dbl = insn.result.type.kind == XTIRTypeKindF64;
        int o0 = [self slotOff:insn.operands[0] slots:slots];
        int o1 = [self slotOff:insn.operands[1] slots:slots];
        int r = slots[@(insn.result.valueId)].intValue;
        if (gHardFloat)
            {
            NSString* m = insn.opcode == XTIROpFAdd ? @"fadd" : insn.opcode == XTIROpFSub ? @"fsub"
                                                            : insn.opcode == XTIROpFMul   ? @"fmul"
                                                                                          : @"fdiv";
            NSString* s = dbl ? @"d" : @"s";
            [out appendFormat:@"\tfmove.%@\t%d(a6),fp0\n\t%@.%@\t%d(a6),fp0\n\tfmove.%@\tfp0,%d(a6)\n",
                              s, o0, m, s, o1, s, r];
            }
        else
            {
            // soft-float: __{add,sub,mul,div}{sf,df}3
            NSString* op = insn.opcode == XTIROpFAdd ? @"add" : insn.opcode == XTIROpFSub ? @"sub"
                                                            : insn.opcode == XTIROpFMul   ? @"mul"
                                                                                          : @"div";
            [self emitSoftFloatBinary:op dbl:dbl o0:o0 o1:o1 result:r into:out];
            }
        break;
        }
    case XTIROpFNeg:
        {
        // Negation is just the sign bit, soft or hard.
        BOOL dbl = insn.result.type.kind == XTIRTypeKindF64;
        int o0 = [self slotOff:insn.operands[0] slots:slots];
        int r = slots[@(insn.result.valueId)].intValue;
        if (o0 != r)
            {
            [out appendFormat:@"\tmove.l\t%d(a6),%d(a6)\n", o0, r];
            if (dbl)
                [out appendFormat:@"\tmove.l\t%d(a6),%d(a6)\n", o0 + 4, r + 4];
            }
        [out appendFormat:@"\teor.l\t#$80000000,%d(a6)\n", r]; // flip sign (high word)
        break;
        }
    case XTIROpFpToSI:
    case XTIROpFpToUI:
        {
        BOOL dbl = [self fsfxOp:insn.operands[0] fn:fn].length && [[self fsfxOp:insn.operands[0] fn:fn] isEqualToString:@"d"];
        int o0 = [self slotOff:insn.operands[0] slots:slots];
        // A 64-bit RESULT cannot use the paths below: they produce d0 and store
        // one long, which on a big-endian machine lands in the HIGH half — so
        // (i64)7.0d came back as 7<<32. The 68881 has no 64-bit integer
        // conversion either (fmove.l is 32-bit), so both float modes go through
        // the HLE helper, which returns d0:d1 like every other 64-bit call.
        BOOL wideRes = insn.result && (insn.result.type.kind == XTIRTypeKindI64 || insn.result.type.kind == XTIRTypeKindU64);
        if (wideRes)
            {
            NSNumber* ro = slots[@(insn.result.valueId)];
            BOOL uns = (insn.opcode == XTIROpFpToUI);
            NSString* h = dbl ? (uns ? @"__fixunsdfdi" : @"__fixdfdi")
                              : (uns ? @"__fixunssfdi" : @"__fixsfdi");
            if (dbl)
                {
                // f64 argument on the stack, high long first — the shape every
                // 64-bit helper takes.
                [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o0 + 4, o0];
                [out appendFormat:@"\tjsr\t%@\n\taddq.l\t#8,sp\n", h];
                }
            else
                {
                [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tjsr\t%@\n", o0, h];
                }
            if (ro)
                [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n",
                                  ro.intValue, ro.intValue + 4];
            break;
            }
        if (gHardFloat)
            {
            // LANGUAGE-SPEC §3.1: an out-of-range float→int saturates to 0 (what
            // arm64/xt6502 do), but the FPU's fmove.l saturates to INT_MAX/MIN.
            // Guard with the IEEE exponent: if the unbiased exponent reaches the
            // destination's signed/unsigned bit width, the magnitude can't fit,
            // so produce 0.
            int vid = insn.result ? (int)insn.result.valueId : 0;
            NSUInteger W = insn.result.type.byteWidth ?: 4;
            int thr = (int)(8 * W) - ((insn.opcode == XTIROpFpToSI) ? 1 : 0);
            if (dbl)
                {
                [out appendFormat:@"\tmove.l\t%d(a6),d1\n\tswap\td1\n\tlsr.w\t#4,d1\n"
                                  @"\tand.w\t#$7ff,d1\n\tcmp.w\t#%d,d1\n\tbge.s\t.fsat%d\n",
                                  o0, 1023 + thr, vid];
                [out appendFormat:@"\tfmove.d\t%d(a6),fp0\n\tfmove.l\tfp0,d0\n", o0];
                }
            else
                {
                [out appendFormat:@"\tmove.l\t%d(a6),d1\n\tswap\td1\n\tlsr.w\t#7,d1\n"
                                  @"\tand.w\t#$ff,d1\n\tcmp.w\t#%d,d1\n\tbge.s\t.fsat%d\n",
                                  o0, 127 + thr, vid];
                [out appendFormat:@"\tfmove.s\t%d(a6),fp0\n\tfmove.l\tfp0,d0\n", o0];
                }
            [out appendFormat:@"\tbra.s\t.fsd%d\n.fsat%d:\tmoveq\t#0,d0\n.fsd%d:\n",
                              vid, vid, vid];
            }
        else if (dbl)
            {
            [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o0 + 4, o0];
            [out appendString:@"\tjsr\t__fixdfsi\n\taddq.l\t#8,sp\n"];
            }
        else
            {
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tjsr\t__fixsfsi\n", o0];
            }
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }
    case XTIROpSIToFp:
    case XTIROpUIToFp:
        {
        BOOL dbl = insn.result.type.kind == XTIRTypeKindF64;
        int r = slots[@(insn.result.valueId)].intValue;
        // A 64-bit SOURCE cannot use the paths below: loadOperand brings ONE
        // long into d0, which big-endian makes the HIGH half — so (double)(i64)3
        // read 0 and produced 0.0. Same reasoning as FpToSI above: no 68881
        // instruction exists, so both float modes take the helper.
        XTIROperand* sop = insn.operands[0];
        XTIRType* srcT = (sop.kind == XTIROperandKindUse)
                             ? [fn valueForId:sop.valueId].type
                             : sop.type;
        if (srcT && (srcT.kind == XTIRTypeKindI64 || srcT.kind == XTIRTypeKindU64))
            {
            BOOL uns = (insn.opcode == XTIROpUIToFp);
            NSString* h = dbl ? (uns ? @"__floatundidf" : @"__floatdidf")
                              : (uns ? @"__floatundisf" : @"__floatdisf");
            [self pushInt64Operand:insn.operands[0] fn:fn slots:slots into:out];
            [out appendFormat:@"\tjsr\t%@\n\taddq.l\t#8,sp\n", h];
            if (dbl)
                [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n", r, r + 4];
            else
                [out appendFormat:@"\tmove.l\td0,%d(a6)\n", r];
            break;
            }
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        if (gHardFloat)
            {
            [out appendFormat:@"\tfmove.l\td0,fp0\n\tfmove.%@\tfp0,%d(a6)\n", dbl ? @"d" : @"s", r];
            }
        else if (dbl)
            {
            [out appendFormat:@"\tjsr\t__floatsidf\n\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n", r, r + 4];
            }
        else
            {
            [out appendFormat:@"\tjsr\t__floatsisf\n\tmove.l\td0,%d(a6)\n", r];
            }
        break;
        }
    case XTIROpFpExt:
    case XTIROpFpTrunc:
        {
        BOOL toDbl = insn.result.type.kind == XTIRTypeKindF64;
        int o0 = [self slotOff:insn.operands[0] slots:slots];
        int r = slots[@(insn.result.valueId)].intValue;
        if (gHardFloat)
            {
            NSString *ss = [self fsfxOp:insn.operands[0] fn:fn], *ds = [self fsfx:insn.result.type];
            [out appendFormat:@"\tfmove.%@\t%d(a6),fp0\n\tfmove.%@\tfp0,%d(a6)\n", ss, o0, ds, r];
            }
        // f32 -> f64
        else if (toDbl)
            {
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tjsr\t__extendsfdf2\n", o0];
            [out appendFormat:@"\tmove.l\td0,%d(a6)\n\tmove.l\td1,%d(a6)\n", r, r + 4];
            }
        // f64 -> f32
        else
            {
            [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o0 + 4, o0];
            [out appendFormat:@"\tjsr\t__truncdfsf2\n\taddq.l\t#8,sp\n\tmove.l\td0,%d(a6)\n", r];
            }
        break;
        }
    case XTIROpFCmp:
        {
        BOOL dbl = [[self fsfxOp:insn.operands[0] fn:fn] isEqualToString:@"d"];
        int o0 = [self slotOff:insn.operands[0] slots:slots];
        int o1 = [self slotOff:insn.operands[1] slots:slots];
        if (gHardFloat)
            {
            NSString* s = dbl ? @"d" : @"s";
            NSArray* fcc = @[ @"fseq", @"fsne", @"fslt", @"fsgt", @"fsle", @"fsge" ];
            NSString* cc = insn.predicate < fcc.count ? fcc[insn.predicate] : @"fseq";
            [out appendFormat:@"\tfmove.%@\t%d(a6),fp0\n\tfcmp.%@\t%d(a6),fp0\n", s, o0, s, o1];
            [out appendFormat:@"\t%@\td2\n\tand.l\t#1,d2\n", cc];
            }
        else
            {
            // soft compare returns d0 = sign(a-b) in {-1,0,1}; map predicate.
            if (dbl)
                {
                [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o1 + 4, o1];
                [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n", o0 + 4, o0];
                [out appendString:@"\tjsr\t__cmpdf2\n\tlea\t16(sp),sp\n"];
                }
            else
                {
                [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\t%d(a6),d1\n\tjsr\t__cmpsf2\n", o0, o1];
                }
            // d0 <=> 0; set d2 = (d0 <pred> 0)
            NSArray* icc = @[ @"eq", @"ne", @"lt", @"gt", @"le", @"ge" ];
            NSString* cc = insn.predicate < icc.count ? icc[insn.predicate] : @"eq";
            [out appendFormat:@"\tmoveq\t#0,d2\n\ttst.l\td0\n\ts%@\td2\n\tand.l\t#1,d2\n", cc];
            }
        [self storeReg:@"d2" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpICmp:
        {
            // A 64-bit compare cannot be one `cmp.l`: comparing the high longs
            // alone made `7 == 0` true, which is how String.withU64 returned "0"
            // for every input. It goes through a helper returning sign(a-b) in d0,
            // exactly as the soft-float compare above does, and the predicate is
            // then applied to d0 against zero.
            {
            XTIRType* ct = [self operandType:insn.operands[0] fn:fn];
            XTIRType* ct1 = [self operandType:insn.operands[1] fn:fn];
            BOOL wide = (ct && (ct.kind == XTIRTypeKindI64 || ct.kind == XTIRTypeKindU64)) || (ct1 && (ct1.kind == XTIRTypeKindI64 || ct1.kind == XTIRTypeKindU64));
            if (wide && insn.result)
                {
                BOOL sgn = (ct && ct.kind == XTIRTypeKindI64) || (ct1 && ct1.kind == XTIRTypeKindI64);
                [self pushInt64Operand:insn.operands[1] fn:fn slots:slots into:out];
                [self pushInt64Operand:insn.operands[0] fn:fn slots:slots into:out];
                [out appendFormat:@"\tjsr\t%@\n\tlea\t16(sp),sp\n",
                                  sgn ? @"__cmpdi2" : @"__ucmpdi2"];
                // d0 is -1/0/1, so the test against zero is always SIGNED —
                // the operands' signedness was already spent on choosing the
                // helper. Every predicate maps to its signed condition; reusing
                // the soft-float table here was wrong, because ICmp has ten
                // predicates to FCmp's six and the unsigned half ran off the
                // end into the "eq" default.
                NSString* cc = @"eq";
                switch (insn.predicate)
                    {
                case XTIRICmpNE:
                    cc = @"ne";
                    break;
                case XTIRICmpSLT:
                case XTIRICmpULT:
                    cc = @"lt";
                    break;
                case XTIRICmpSGT:
                case XTIRICmpUGT:
                    cc = @"gt";
                    break;
                case XTIRICmpSLE:
                case XTIRICmpULE:
                    cc = @"le";
                    break;
                case XTIRICmpSGE:
                case XTIRICmpUGE:
                    cc = @"ge";
                    break;
                default:
                    break; // EQ
                    }
                [out appendFormat:@"\tmoveq\t#0,d2\n\ttst.l\td0\n\ts%@\td2\n"
                                  @"\tand.l\t#1,d2\n",
                                  cc];
                [self storeReg:@"d2" toResult:insn.result slots:slots into:out];
                break;
                }
            }
        // Compare at the operand width so dirty high bits in the 32-bit
        // slots don't corrupt narrow (u8/u16) comparisons.
        uint32_t w0 = [self widthOf:insn.operands[0] fn:fn];
        uint32_t w1 = [self widthOf:insn.operands[1] fn:fn];
        uint32_t w = w0 > w1 ? w0 : w1;
        NSString* sz = w == 1 ? @"b" : w == 2 ? @"w"
                                              : @"l";
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out];
        // Fused into the block's CondBranch: leave the flags set, no boolean.
        if (insn.result && gFusedCmp && [gFusedCmp containsObject:@(insn.result.valueId)])
            {
            [out appendFormat:@"\tcmp.%@\td1,d0\n", sz];
            break;
            }
        [out appendString:@"\tmoveq\t#0,d2\n"];      // pre-clear (flags set by cmp below)
        [out appendFormat:@"\tcmp.%@\td1,d0\n", sz]; // d0 - d1 at operand width
        [out appendFormat:@"\ts%@\td2\n", [self condForPredicate:insn.predicate]];
        [out appendString:@"\tand.l\t#1,d2\n"];
        [self storeReg:@"d2" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;

    case XTIROpBitcast:
        {
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        // A reinterpret to a narrow integer (e.g. `(u16)i16expr`) must present
        // the canonical narrow value with clean high bits: the source may
        // carry stale upper bits (a 32-bit Sub result, a sign-extended i16)
        // that a later full-width op — like a `val/10` digit loop — misreads.
        XTIRType* rt = insn.result.type;
        if (rt && XTIRTypeKindIsInteger(rt.kind))
            {
            if (rt.byteWidth == 1)
                [out appendString:@"\tand.l\t#$ff,d0\n"];
            else if (rt.byteWidth == 2)
                [out appendString:@"\tand.l\t#$ffff,d0\n"];
            }
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpAddrOf:
        {
        XTIROperand* s = insn.operands.firstObject;
        if (s.kind == XTIROperandKindSym)
            {
            XTIRSymbol* sym = [mod symbolForId:s.symbolId];
            [out appendFormat:@"\tlea\t%@,a0\n", m68kSym(sym.name)];
            [self storeReg:@"a0" toResult:insn.result slots:slots into:out];
            }
        // address of a pinned local
        else if (s.kind == XTIROperandKindUse)
            {
            NSNumber* off = slots[@(s.valueId)];
            if (off)
                {
                [out appendFormat:@"\tlea\t%d(a6),a0\n", off.intValue];
                [self storeReg:@"a0" toResult:insn.result slots:slots into:out];
                }
            else
                [out appendFormat:@"\t; TODO AddrOf unmapped %%%u\n", s.valueId];
            }
        else
            [out appendString:@"\t; TODO AddrOf (non-sym)\n"];
        break;
        }

    case XTIROpFieldAddr:
        {
        if (insn.result && gFold[@(insn.result.valueId)])
            break; // folded into its Load/Store
        XTIROperand* base = insn.operands[0];
        int fieldIdx = (int)insn.operands[1].intValue;
        XTIRValue* bv = [fn valueForId:base.valueId];
        XTIRLayout* lay = bv.type.pointeeType.layout;
        uint32_t off = lay ? (uint32_t)[self m68kFieldOffset:lay index:fieldIdx] : 0;
        [self loadOperand:base intoReg:@"d0" slots:slots into:out];
        if (off)
            [out appendFormat:@"\tadd.l\t#%u,d0\n", off];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpLoad:
        {
        XTIRType* lrt = insn.result.type;
        // Whole-struct load (`Struct v = arr[i]`): copy the full m68k width
        // into the result's frame slot, not just a 4-byte `move.l`.
        if (lrt && lrt.kind == XTIRTypeKindAgg && lrt.layout)
            {
            NSUInteger width = [self m68kAggSize:lrt.layout];
            [self loadOperand:insn.operands[0] intoReg:@"a1" slots:slots into:out]; // src ptr
            NSNumber* db = slots[@(insn.result.valueId)];
            [out appendFormat:@"\tlea\t%d(a6),a0\n", db ? db.intValue : 0]; // dest slot
            int n = gLabelSeq++;
            [out appendFormat:@"\tmove.l\t#%lu,d0\n.Lcpy%d:\n\tmove.b\t(a1)+,(a0)+\n"
                              @"\tsubq.l\t#1,d0\n\tbne.s\t.Lcpy%d\n",
                              (unsigned long)width, n, n];
            break;
            }
        XTIRType* rt = insn.result.type;
        uint32_t w = rt ? rt.byteWidth : 4;
        BOOL sgn = rt && XTIRTypeKindIsSigned(rt.kind);
        NSString* pareg = insn.operands[0].kind == XTIROperandKindUse
                              ? gPtrAReg[@(insn.operands[0].valueId)]
                              : nil; // walking pointer → (aN)
        XTIRInsn* fea = pareg ? nil : gFold[@(insn.operands[0].valueId)];
        NSString* mem = pareg ? [NSString stringWithFormat:@"(%@)", pareg]
                              : (fea ? [self foldedMemOp:fea fn:fn slots:slots into:out] : nil);
        if (!mem)
            {
            [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
            mem = @"(a0)";
            }
        if (w == 1)
            [out appendFormat:sgn ? @"\tmove.b\t%@,d0\n\text.w\td0\n\text.l\td0\n"
                                  : @"\tmoveq\t#0,d0\n\tmove.b\t%@,d0\n",
                              mem];
        else if (w == 2)
            [out appendFormat:sgn ? @"\tmove.w\t%@,d0\n\text.l\td0\n"
                                  : @"\tmoveq\t#0,d0\n\tmove.w\t%@,d0\n",
                              mem];
        else if (w == 8 && (rt.kind == XTIRTypeKindI64 || rt.kind == XTIRTypeKindU64 || rt.kind == XTIRTypeKindF64))
            {
            // Two longs, high first (big-endian), straight into the slot: the
            // 4-byte fallthrough below would have loaded only the high word and
            // then stored it as if it were the whole value.
            // The SECOND long is at address+4, and the only way to say that
            // for an arbitrary addressing mode is to put the address in a
            // register first: string-prefixing "4" onto `mem` produced
            // `4-8(a6)`, which the assembler rejected outright (it happened to
            // work while every 8-byte load came through plain `(a0)`).
            // `lea mem,a0` first, then (a0) and 4(a0). That works for EVERY
            // addressing mode `mem` can be — a walking pointer's (aN), a folded
            // displacement, an absolute — where reloading the pointer OPERAND
            // does not: at -O3 the address is folded, so operand[0] is not the
            // effective address and the load came back from somewhere else
            // entirely (a `%lf` printed 0.0).
            NSNumber* db = slots[@(insn.result.valueId)];
            if (db)
                {
                if (![mem isEqualToString:@"(a0)"])
                    [out appendFormat:@"\tlea\t%@,a0\n", mem];
                [out appendString:@"\tmove.l\t(a0),d0\n"];
                [out appendFormat:@"\tmove.l\td0,%d(a6)\n", db.intValue];
                [out appendString:@"\tmove.l\t4(a0),d0\n"];
                [out appendFormat:@"\tmove.l\td0,%d(a6)\n", db.intValue + 4];
                break;
                }
            [out appendFormat:@"\tmove.l\t%@,d0\n", mem];
            }
        else
            [out appendFormat:@"\tmove.l\t%@,d0\n", mem]; // long / pointer
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpStore:
        {
        XTIROperand* valOp = insn.operands[1];
        XTIRType* vt = (valOp.kind == XTIROperandKindUse)
                           ? [fn valueForId:valOp.valueId].type
                           : valOp.type;
        // Whole-struct store (`arr[i] = structValue`): the value is a
        // materialized aggregate in a frame slot — byte-copy its full m68k
        // width to the destination, not just a 4-byte `move.l`.
        if (vt && vt.kind == XTIRTypeKindAgg && vt.layout)
            {
            NSUInteger width = [self m68kAggSize:vt.layout];
            [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];     // dest
            [out appendFormat:@"\tlea\t%d(a6),a1\n", [self slotOff:valOp slots:slots]]; // src
            int n = gLabelSeq++;
            [out appendFormat:@"\tmove.l\t#%lu,d0\n.Lcpy%d:\n\tmove.b\t(a1)+,(a0)+\n"
                              @"\tsubq.l\t#1,d0\n\tbne.s\t.Lcpy%d\n",
                              (unsigned long)width, n, n];
            break;
            }
        // An eight-byte value is two longs in a slot; copy both, high first.
        // F64 as well as i64: `*p = 3.1d` stored ONE long, so the value read
        // back was not the value written — `*p == 3.1d` was false, and every
        // `%lf` went through the vararg buffer and came out at float precision.
        // (Only visible with a constant whose low word is non-zero: 1.5, 3.25
        // and 7.75 all survive a half-store intact.)
        if (vt && (vt.kind == XTIRTypeKindI64 || vt.kind == XTIRTypeKindU64 || vt.kind == XTIRTypeKindF64) && valOp.kind == XTIROperandKindUse && slots[@(valOp.valueId)])
            {
            // The DESTINATION goes through the same fold/walking-pointer
            // machinery the narrow path below uses, then `lea`d into a0 so the
            // second long can be written at +4. Reloading operand[0] from its
            // slot instead was wrong whenever the address had been FOLDED: that
            // slot is never written, so the store landed on garbage and the
            // value simply did not arrive (a `%lf` printed 0.0).
            NSString* dpareg = insn.operands[0].kind == XTIROperandKindUse
                                   ? gPtrAReg[@(insn.operands[0].valueId)]
                                   : nil;
            XTIRInsn* dfea = dpareg ? nil : gFold[@(insn.operands[0].valueId)];
            NSString* dmem = dpareg ? [NSString stringWithFormat:@"(%@)", dpareg]
                                    : (dfea ? [self foldedMemOp:dfea fn:fn slots:slots into:out] : nil);
            if (!dmem)
                {
                [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
                }
            else if (![dmem isEqualToString:@"(a0)"])
                {
                [out appendFormat:@"\tlea\t%@,a0\n", dmem];
                }
            int so = [self slotOff:valOp slots:slots];
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\td0,(a0)\n", so];
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\td0,4(a0)\n", so + 4];
            break;
            }
        [self loadOperand:insn.operands[1] intoReg:@"d0" slots:slots into:out]; // value → d0
        NSString* pareg = insn.operands[0].kind == XTIROperandKindUse
                              ? gPtrAReg[@(insn.operands[0].valueId)]
                              : nil; // walking pointer → (aN)
        XTIRInsn* fea = pareg ? nil : gFold[@(insn.operands[0].valueId)];
        NSString* mem = pareg ? [NSString stringWithFormat:@"(%@)", pareg]
                              : (fea ? [self foldedMemOp:fea fn:fn slots:slots into:out] : nil);
        if (!mem)
            {
            [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
            mem = @"(a0)";
            }
        uint32_t w = [self widthOf:insn.operands[1] fn:fn];
        if (w == 1)
            [out appendFormat:@"\tmove.b\td0,%@\n", mem];
        else if (w == 2)
            [out appendFormat:@"\tmove.w\td0,%@\n", mem];
        else
            [out appendFormat:@"\tmove.l\td0,%@\n", mem];
        break;
        }

    case XTIROpElementAddr:
        {
        if (insn.result && gFold[@(insn.result.valueId)])
            break; // folded into its Load/Store
        XTIRType* rt = insn.result.type;
        uint32_t stride = (rt && rt.pointeeType)
                              ? (uint32_t)[self m68kFieldWidth:rt.pointeeType]
                              : 1;
        // Constant index (the pointer-IV advance `p_next = p + step`): the whole
        // offset folds to a compile-time displacement — compute it in the result
        // home register directly (addq/addi), no index-scale sequence.
        XTIROperand* idxOp = insn.operands[1];
        if (idxOp.kind == XTIROperandKindImmI)
            {
            long long disp = (long long)idxOp.intValue * (long long)stride;
            NSString* rhome = insn.result ? gHome[@(insn.result.valueId)] : nil;
            NSString* dst = rhome ?: @"d0";
            [self loadOperand:insn.operands[0] intoReg:dst slots:slots into:out]; // base → dst
            if (disp >= 1 && disp <= 8)
                [out appendFormat:@"\taddq.l\t#%lld,%@\n", disp, dst];
            else if (disp >= -8 && disp <= -1)
                [out appendFormat:@"\tsubq.l\t#%lld,%@\n", -disp, dst];
            else if (disp != 0)
                [out appendFormat:@"\tadd.l\t#%lld,%@\n", disp, dst];
            [self storeReg:dst toResult:insn.result slots:slots into:out];
            break;
            }
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out]; // base
        // A 64-bit index cannot go through loadOperand: it brings ONE long
        // into d1, which big-endian makes the HIGH half — so every u64-indexed
        // element resolved to element 0 (u64_spill_add_imm read stack garbage
        // for words[3]). The address math is 32-bit; read the LOW long.
        [self loadOperandLow32:insn.operands[1]
                            fn:fn
                       intoReg:@"d1"
                         slots:slots
                          into:out]; // index
        if (stride == 2)
            [out appendString:@"\tlsl.l\t#1,d1\n"];
        else if (stride == 4)
            [out appendString:@"\tlsl.l\t#2,d1\n"];
        else if (stride == 8)
            [out appendString:@"\tlsl.l\t#3,d1\n"];
        else if (stride != 1)
            {
            if (cpu >= 68020)
                {
                [out appendFormat:@"\tmove.l\t#%u,d2\n", stride];
                [out appendString:@"\tmuls.l\td2,d1\n"]; // d1 = index*stride
                }
            else
                {
                // __mulsi3 takes its args in d0/d1, returns in d0, and may
                // clobber d1-d5 — so it can't scale d1 in place, and it would
                // eat the base in d0. Spill the base, multiply per the helper's
                // ABI, then reassemble. (Powers of two never come here.)
                [out appendString:@"\tmove.l\td0,-(sp)\n"];       // save base
                [out appendString:@"\tmove.l\td1,d0\n"];          // d0 = index
                [out appendFormat:@"\tmove.l\t#%u,d1\n", stride]; // d1 = stride
                [out appendString:@"\tjsr\t__mulsi3\n"];          // d0 = index*stride
                [out appendString:@"\tmove.l\td0,d1\n"];          // d1 = offset
                [out appendString:@"\tmove.l\t(sp)+,d0\n"];       // restore base
                }
            }
        [out appendString:@"\tadd.l\td1,d0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpRetain:
        {
        // 16-bit refcount at obj-2; skip null / <64KB sentinels (real heap
        // objects live above LOAD_BASE = $10000).
        int n = gLabelSeq++;
        [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
        [out appendString:@"\tmove.l\ta0,d0\n\tcmp.l\t#$10000,d0\n"];
        [out appendFormat:@"\tbcs\t.Lrt%d\n", n];
        // Zero means "already dying" — see the arm64 back end. Retaining an
        // object whose dealloc is running relaunches dealloc (bug 038).
        [out appendString:@"\tmove.w\t-2(a0),d1\n"];
        [out appendFormat:@"\tbeq\t.Lrt%d\n", n];
        [out appendString:@"\taddq.w\t#1,d1\n\tmove.w\td1,-2(a0)\n"];
        [out appendFormat:@".Lrt%d:\n", n];
        break;
        }
    case XTIROpRelease:
    case XTIROpAutorelease:
        {
        int n = gLabelSeq++;
        [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
        [out appendString:@"\tmove.l\ta0,d0\n\tcmp.l\t#$10000,d0\n"];
        [out appendFormat:@"\tbcs\t.Lrl%d\n", n];
        [out appendString:@"\tmove.w\t-2(a0),d1\n\tsubq.w\t#1,d1\n\tmove.w\td1,-2(a0)\n"];
        [out appendFormat:@"\tbne\t.Lrl%d\n", n];
        [out appendString:@"\tmove.l\ta0,-(sp)\n\tjsr\t_xtc_dealloc\n\taddq.l\t#4,sp\n"];
        [out appendFormat:@".Lrl%d:\n", n];
        break;
        }

    // ── Weak references — side-table runtime calls ────────────────────
    // [slot, obj, mem]
    case XTIROpWeakRegister:
        {
        if (insn.operands.count < 3)
            break;
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out]; // slot
        [self loadOperand:insn.operands[1] intoReg:@"d1" slots:slots into:out]; // obj
        [out appendString:@"\tjsr\t__xtc_weak_register\n"];
        break;
        }
    // [slot, mem]
    case XTIROpWeakUnregister:
        {
        if (insn.operands.count < 2)
            break;
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out];
        [out appendString:@"\tjsr\t__xtc_weak_unregister\n"];
        break;
        }
    // [slot, mem] -> result (deref; the slot
    case XTIROpWeakLoad:
        {
        // memory is zeroed in place by __xtc_weak_zero_all_for, so a plain
        // load reads null once the pointee is gone).
        if (insn.operands.count < 2 || !insn.result)
            break;
        [self loadOperand:insn.operands[0] intoReg:@"a0" slots:slots into:out];
        [out appendString:@"\tmove.l\t(a0),d0\n"];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    // [cond, ifTrue, ifFalse] -> result
    case XTIROpSelect:
        {
        // No conditional move on the 68000/68030 — branch around it. (Used by
        // the printf %e enum-name lookup: a chain of Selects over u8@ names.)
        if (insn.operands.count < 3 || !insn.result)
            break;
        int n = gLabelSeq++;
        [self loadOperand:insn.operands[0] intoReg:@"d0" slots:slots into:out]; // cond
        [out appendFormat:@"\ttst.l\td0\n\tbeq.s\t.Lsel%df\n", n];
        [self loadOperand:insn.operands[1] intoReg:@"d0" slots:slots into:out]; // ifTrue
        [out appendFormat:@"\tbra.s\t.Lsel%dd\n.Lsel%df:\n", n, n];
        [self loadOperand:insn.operands[2] intoReg:@"d0" slots:slots into:out]; // ifFalse
        [out appendFormat:@".Lsel%dd:\n", n];
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpAggBuild:
        {
        XTIRType* aggTy = insn.result.type;
        if (aggTy.kind != XTIRTypeKindAgg || !aggTy.layout)
            break;
        int base = slots[@(insn.result.valueId)].intValue;
        for (NSUInteger i = 0; i < insn.operands.count; i++)
            {
            [self loadOperand:insn.operands[i] intoReg:@"d0" slots:slots into:out];
            NSUInteger foff = [self m68kFieldOffset:aggTy.layout index:i];
            XTIRType* fty = (i < aggTy.layout.fields.count) ? aggTy.layout.fields[i].type : nil;
            NSUInteger fw = [self m68kFieldWidth:fty];
            NSString* sfx = fw == 1 ? @"b" : fw == 2 ? @"w"
                                                     : @"l";
            [out appendFormat:@"\tmove.%@\td0,%d(a6)\n", sfx, base + (int)foff];
            }
        break;
        }
    case XTIROpAggExtract:
        {
        XTIROperand* src = insn.operands[0];
        int idx = (int)insn.operands[1].intValue;
        XTIRValue* sv = [fn valueForId:src.valueId];
        XTIRType* aggTy = sv.type;
        if (aggTy.kind != XTIRTypeKindAgg || !aggTy.layout)
            break;
        int base = slots[@(src.valueId)].intValue;
        NSUInteger foff = [self m68kFieldOffset:aggTy.layout index:idx];
        XTIRType* rty = insn.result.type;
        uint32_t fw = rty ? rty.byteWidth : 4;
        BOOL sgn = rty && XTIRTypeKindIsSigned(rty.kind);
        int off = base + (int)foff;
        if (fw == 1)
            [out appendFormat:sgn ? @"\tmove.b\t%d(a6),d0\n\text.w\td0\n\text.l\td0\n"
                                  : @"\tmoveq\t#0,d0\n\tmove.b\t%d(a6),d0\n",
                              off];
        else if (fw == 2)
            [out appendFormat:sgn ? @"\tmove.w\t%d(a6),d0\n\text.l\td0\n"
                                  : @"\tmoveq\t#0,d0\n\tmove.w\t%d(a6),d0\n",
                              off];
        else
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n", off]; // long / pointer
        [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpVTblDispatch:
        {
        // operands: [receiver, slotImm, arg0..argN, mem]. The receiver is
        // the implicit first (self) argument. vtable ptr is at receiver+0;
        // method ptr at vtable + slot*4.
        XTIROperand* recv = insn.operands[0];
        int slot = (int)insn.operands[1].intValue;
        NSUInteger argc = insn.operands.count >= 3 ? insn.operands.count - 3 : 0;
        // extra args R→L
        for (NSInteger i = (NSInteger)argc - 1; i >= 0; i--)
            {
            [self loadOperand:insn.operands[2 + i] intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\tmove.l\td0,-(sp)\n"];
            }
        [self loadOperand:recv intoReg:@"d0" slots:slots into:out]; // self (last)
        [out appendString:@"\tmove.l\td0,-(sp)\n"];
        [self loadOperand:recv intoReg:@"a0" slots:slots into:out]; // receiver
        [out appendString:@"\tmove.l\t(a0),a1\n"];                  // vtable base (runtime addr)
        // PIC vtable: slot holds (method - vtable_base); method = base + offset.
        if (slot)
            [out appendFormat:@"\tmove.l\t%d(a1),d0\n", slot * 4];
        else
            [out appendString:@"\tmove.l\t(a1),d0\n"];       // offset
        [out appendString:@"\tadd.l\td0,a1\n\tjsr\t(a1)\n"]; // a1 = method
        [out appendFormat:@"\tlea\t%lu(sp),sp\n", (unsigned long)(4 * (argc + 1))];
        if (![self storeWideReturn:insn slots:slots into:out] && insn.result && insn.result.type.kind != XTIRTypeKindMemory)
            [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpVTblLoad:
        {
        // operands: [receiver, slotImm, mem] -> fn pointer.
        // VTblDispatch's address computation without the call: the code word
        // of `&obj.method`.
        //
        // TWO null cases, and on m68k they are NOT the same check. The vtable
        // is PIC — a slot holds (method - vtable_base), and the dispatcher adds
        // the base back. So an EMPTY slot holds offset 0, and blindly adding
        // the base would yield vtable_base, a bogus non-null "method". Harmless
        // for dispatch (nothing ever dispatches an empty slot) but fatal here,
        // where a null result is exactly what reports "optional method not
        // implemented". So: bail out on a zero offset BEFORE adding the base.
        //
        // A null receiver must likewise yield 0 rather than fault, so that one
        // `if (h)` covers both "no delegate" and "doesn't implement it".
        XTIROperand* recv = insn.operands[0];
        int slot = (int)insn.operands[1].intValue;
        int n = gLabelSeq++;
        [self loadOperand:recv intoReg:@"a0" slots:slots into:out];
        [out appendString:@"\tmoveq\t#0,d0\n"];    // default: null
        [out appendString:@"\tmove.l\ta0,d1\n"];   // sets Z if recv == 0
        [out appendFormat:@"\tbeq\t.Lvtl%d\n", n]; // null receiver -> 0
        [out appendString:@"\tmove.l\t(a0),a1\n"]; // vtable base
        if (slot)
            [out appendFormat:@"\tmove.l\t%d(a1),d0\n", slot * 4];
        else
            [out appendString:@"\tmove.l\t(a1),d0\n"]; // PIC offset; sets Z
        [out appendFormat:@"\tbeq\t.Lvtl%d\n", n];     // empty slot -> 0
        [out appendString:@"\tadd.l\ta1,d0\n"];        // method = base + offset
        [out appendFormat:@".Lvtl%d:\n", n];
        if (insn.result && insn.result.type.kind != XTIRTypeKindMemory)
            [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    case XTIROpCallBankedIndirect:
    case XTIROpCallIndirect:
        {
        // operands: [funcptr, arg0..argN, mem]
        NSUInteger argc = insn.operands.count >= 2 ? insn.operands.count - 2 : 0;
        for (NSInteger i = (NSInteger)argc - 1; i >= 0; i--)
            {
            [self loadOperand:insn.operands[i + 1] intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\tmove.l\td0,-(sp)\n"];
            }
        [self loadOperand:insn.operands[0] intoReg:@"a1" slots:slots into:out];
        [out appendString:@"\tjsr\t(a1)\n"];
        if (argc)
            [out appendFormat:@"\tlea\t%lu(sp),sp\n", (unsigned long)(4 * argc)];
        if ([self storeWideReturn:insn slots:slots into:out])
            {
            // stored: an eight-byte scalar comes back in d0:d1
            }
        else if (insn.result && insn.result.type.kind == XTIRTypeKindAgg && insn.result.type.layout)
            {
            int base = slots[@(insn.result.valueId)].intValue;
            NSUInteger sz = [self m68kAggSize:insn.result.type.layout];
            [out appendFormat:@"\tmove.l\td0,%d(a6)\n", base];
            if (sz > 4)
                [out appendFormat:@"\tmove.l\td1,%d(a6)\n", base + 4];
            }
        else if (insn.result && insn.result.type.kind != XTIRTypeKindMemory)
            [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
        break;
        }

    // m68k is flat — there are no code/data banks, so a `:banked` or cloaked
    // call is just a plain call (same operand shape: [sym, args…, mem]). The
    // banking/cloak metadata is meaningless here and ignored.
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
    case XTIROpCall:
        {
        XTIROperand* callee = insn.operands.firstObject;
        XTIRSymbol* sym = (callee.kind == XTIROperandKindSym)
                              ? [mod symbolForId:callee.symbolId]
                              : nil;
        NSUInteger argc = insn.operands.count >= 2 ? insn.operands.count - 2 : 0;
        // _xtc_alloc(count, stride, deallocPtr): the IR's `stride` is the shared
        // 2-byte-pointer (Atari) instance size — too small for m68k's 4-byte
        // pointers, so a single `new T` would under-allocate and the init's
        // wider field stores would overflow into the next heap object. Override
        // the stride with the m68k-native instance size (the same fix the
        // per-class `_xtc_new_<T>` path below applies). deallocPtr/count pass
        // through. Push reverse (deallocPtr, size, count) → count at 4(sp).
        if (sym && [sym.name isEqualToString:@"_xtc_alloc"] && argc == 3 && insn.result.type.pointeeType)
            {
            NSUInteger sz = [self m68kFieldWidth:insn.result.type.pointeeType];
            [self loadOperand:insn.operands[3] intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\tmove.l\td0,-(sp)\n"];                      // deallocPtr
            [out appendFormat:@"\tmove.l\t#%lu,-(sp)\n", (unsigned long)sz]; // native size
            [self loadOperand:insn.operands[1] intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\tmove.l\td0,-(sp)\n"]; // count
            [out appendFormat:@"\tjsr\t%@\n\tlea\t12(sp),sp\n", m68kSym(sym.name)];
            if (insn.result && insn.result.type.kind != XTIRTypeKindMemory)
                [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
            break;
            }
        // _xtc_new_<T>(count, size): the IR's `size` uses 2-byte pointers;
        // override it with the m68k element size (4-byte pointers) — for
        // class instances (Agg) and primitive/pointer arrays alike.
        if (sym && [sym.name hasPrefix:@"_xtc_new_"] && argc == 2 && insn.result.type.pointeeType)
            {
            NSUInteger sz = [self m68kFieldWidth:insn.result.type.pointeeType];
            [out appendFormat:@"\tmove.l\t#%lu,-(sp)\n", (unsigned long)sz]; // size
            [self loadOperand:insn.operands[1] intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\tmove.l\td0,-(sp)\n"]; // count
            [out appendFormat:@"\tjsr\t%@\n\tlea\t8(sp),sp\n", m68kSym(sym.name)];
            if (insn.result && insn.result.type.kind != XTIRTypeKindMemory)
                [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
            break;
            }
        // Aggregate return value uses an sret buffer: pass the address of the
        // result's frame slot as a hidden trailing arg; the callee copies the
        // whole aggregate there (D0:D1 can't hold a struct > 8 bytes).
        BOOL aggRet = insn.result && insn.result.type.kind == XTIRTypeKindAgg && insn.result.type.layout;
        NSUInteger popBytes = 0;
        if (aggRet)
            {
            int rbase = slots[@(insn.result.valueId)].intValue;
            [out appendFormat:@"\tlea\t%d(a6),a0\n\tmove.l\ta0,-(sp)\n", rbase];
            popBytes += 4;
            }
        // push right-to-left
        for (NSInteger i = (NSInteger)argc - 1; i >= 0; i--)
            {
            XTIROperand* ao = insn.operands[i + 1];
            XTIRValue* av = (ao.kind == XTIROperandKindUse)
                                ? [fn valueForId:ao.valueId]
                                : nil;
            if (av && av.type.kind == XTIRTypeKindAgg && av.type.layout)
                {
                // Aggregate by value: push the whole struct (high long first so
                // byte 0 lands at the lowest pushed address = the param offset).
                int abase = slots[@(ao.valueId)].intValue;
                NSUInteger asz = ([self m68kAggSize:av.type.layout] + 3) & ~3u;
                for (int o = (int)asz - 4; o >= 0; o -= 4)
                    [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n", abase + o];
                popBytes += asz;
                }
            else if (av && (av.type.kind == XTIRTypeKindF64 || av.type.kind == XTIRTypeKindI64 || av.type.kind == XTIRTypeKindU64))
                {
                // double AND i64 occupy two longs: push the low long first so
                // the high long lands at the lower (param) address — big-endian
                // order. Without the i64 arm an eight-byte argument was pushed
                // as one long and every later argument shifted with it.
                int doff = slots[@(ao.valueId)].intValue;
                [out appendFormat:@"\tmove.l\t%d(a6),-(sp)\n\tmove.l\t%d(a6),-(sp)\n",
                                  doff + 4, doff];
                popBytes += 8;
                }
            else
                {
                [self loadOperand:ao intoReg:@"d0" slots:slots into:out];
                [out appendString:@"\tmove.l\td0,-(sp)\n"];
                popBytes += 4;
                }
            }
        [out appendFormat:@"\tjsr\t%@\n", sym ? m68kSym(sym.name) : @"<indirect>"];
        if (popBytes)
            [out appendFormat:@"\tlea\t%lu(sp),sp\n", (unsigned long)popBytes];
        if ([self storeWideReturn:insn slots:slots into:out])
            {
            // stored: an eight-byte scalar comes back in d0:d1
            }
        else if (aggRet)
            {
            // result already written into its slot by the callee via sret.
            }
        else if (insn.result && insn.result.type.kind != XTIRTypeKindMemory)
            {
            [self storeReg:@"d0" toResult:insn.result slots:slots into:out];
            }
        break;
        }

    case XTIROpReturn:
        {
        XTIROperand* v = insn.operands.firstObject;
        XTIRValue* vv = (v.kind == XTIROperandKindUse) ? [fn valueForId:v.valueId] : nil;
        // returned in d0:d1
        if (vv && (vv.type.kind == XTIRTypeKindF64 || vv.type.kind == XTIRTypeKindI64 || vv.type.kind == XTIRTypeKindU64))
            {
            int base = slots[@(v.valueId)].intValue;
            [out appendFormat:@"\tmove.l\t%d(a6),d0\n\tmove.l\t%d(a6),d1\n", base, base + 4];
            }
        else if (vv && vv.type.kind == XTIRTypeKindAgg && vv.type.layout)
            {
            // aggregate return via the caller's sret buffer, passed as the
            // implicit trailing arg at 8 + 4*nUser(a6). Copy the whole struct.
            int base = slots[@(v.valueId)].intValue;
            NSUInteger sz = ([self m68kAggSize:vv.type.layout] + 3) & ~3u;
            // sret pointer sits just past the real params (each aggregate param
            // occupies its full pushed size, not one long).
            int sretOff = 8;
            for (XTIRType* t in fn.paramTypes)
                {
                if (t.kind == XTIRTypeKindMemory)
                    continue;
                sretOff += (t.kind == XTIRTypeKindAgg && t.layout)
                               ? (((int)[self m68kAggSize:t.layout] + 3) & ~3)
                               : ((t.kind == XTIRTypeKindF64 || t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64) ? 8 : 4);
                }
            [out appendFormat:@"\tmove.l\t%d(a6),a0\n", sretOff];
            for (NSUInteger o = 0; o < sz; o += 4)
                [out appendFormat:@"\tmove.l\t%d(a6),%lu(a0)\n",
                                  base + (int)o, (unsigned long)o];
            }
        else if (v && (v.kind == XTIROperandKindImmI ||
                       (v.kind == XTIROperandKindUse &&
                        !(v.type && v.type.kind == XTIRTypeKindMemory))))
            {
            [self loadOperand:v intoReg:@"d0" slots:slots into:out];
            }
        for (NSString* r in gHomeSaves) // restore callee-saved homes
            [out appendFormat:@"\tmove.l\t%@(a6),%@\n", gHomeSaveOff[r], r];
        for (NSString* r in gPtrARegSaves) // restore pointer-IV address regs
            [out appendFormat:@"\tmove.l\t%@(a6),%@\n", gPtrARegSaveOff[r], r];
        [out appendString:@"\tunlk\ta6\n\trts\n"];
        break;
        }

    case XTIROpBranch:
        {
        XTIROperand* tgt = insn.operands.firstObject;
        if (tgt.kind == XTIROperandKindBlock)
            {
            [self emitPhiCopiesFrom:bb to:tgt.blockRef fn:fn slots:slots into:out];
            [out appendFormat:@"\tbra\t%@\n", [self labelFor:fn block:tgt.blockRef]];
            }
        break;
        }

    case XTIROpCondBranch:
        {
        // operands: [cond, trueBlock, falseBlock]
        XTIROperand* cond = insn.operands[0];
        XTIRBlock *tb = insn.operands[1].blockRef, *fb = insn.operands[2].blockRef;
        int n = gLabelSeq++;
        XTIRInsn* fcmp = bb.instructions.lastObject;
        if (cond.kind == XTIROperandKindUse && gFusedCmp && [gFusedCmp containsObject:@(cond.valueId)] && fcmp && fcmp.opcode == XTIROpICmp && fcmp.result && fcmp.result.valueId == cond.valueId)
            {
            // The ICmp already emitted `cmp` with the flags still set: branch to
            // the false edge on the NEGATED predicate. No boolean/tst.
            [out appendFormat:@"\tb%@\t.Lcbf%d\n", [self condForNegatedPredicate:fcmp.predicate], n];
            }
        else
            {
            [self loadOperand:cond intoReg:@"d0" slots:slots into:out];
            [out appendString:@"\ttst.l\td0\n"];
            [out appendFormat:@"\tbeq\t.Lcbf%d\n", n]; // false edge
            }
        [self emitPhiCopiesFrom:bb to:tb fn:fn slots:slots into:out];
        [out appendFormat:@"\tbra\t%@\n", [self labelFor:fn block:tb]];
        [out appendFormat:@".Lcbf%d:\n", n];
        [self emitPhiCopiesFrom:bb to:fb fn:fn slots:slots into:out];
        [out appendFormat:@"\tbra\t%@\n", [self labelFor:fn block:fb]];
        break;
        }

    case XTIROpUnreachable:
        // A failed CHECKED downcast `(T*)p` lands here, and it is
        // reachable — the comment this replaces claimed otherwise. Falling
        // through meant the cast silently succeeded with a mistyped pointer
        // and the program carried on; on the hosts it then exited 0, so a
        // failed cast looked like a clean run to any script checking status.
        // A checked cast failing is an assertion the programmer got wrong,
        // so it aborts — loudly, and with a non-zero status — everywhere.
        // Use `(T* ?)p` when failure is a possibility rather than a bug.
        [out appendString:@"\tillegal\n"]; // $4AFC — illegal instruction
        break;

    case XTIROpAsm:
        {
        // Inline asm is per-architecture and this backend has no lowering for
        // it (verbatim emission would need frame-slot substitution and homing
        // suppressed around the block). A block whose body the preprocessor
        // emptied is harmless and emits nothing. A block with text is refused:
        // dropping it built a program that ran with the block's effect missing
        // and exited 0 — double_math_lnexp, whose 6502 `asm { LDA d ... }`
        // copies never ran, printed FAIL lines that looked like a 68881 bug
        // (bug 254).
        BOOL hasText = NO;
        for (XTIROperand* o in insn.operands)
            {
            if (o.kind != XTIROperandKindConstAgg)
                continue;
            NSData* bytes = [mod constantForId:o.constantId].stringBytes;
            const unsigned char* p = bytes.bytes;
            for (NSUInteger k = 0; k < bytes.length; k++)
                if (p[k] != 0 && p[k] != ' ' && p[k] != '\t' && p[k] != '\n' && p[k] != '\r')
                    hasText = YES;
            }
        if (hasText)
            [NSException raise:@"XTM68kInlineAsm"
                        format:@"inline asm has no m68k lowering (guard the source "
                               @"with #if ARCH_6502, or the architecture it is "
                               @"written for)"];
        break;
        }

    default:
        // No silent fall-through: an unhandled opcode here would emit nothing
        // and produce a wrong-but-clean binary (how CallBanked vanished). Fail
        // loudly so the gap is caught at compile time, not as garbage output.
        // A genuinely-ignorable opcode must be given an explicit no-op case
        // above with a comment saying why — it must never reach this default.
        [NSException raise:@"XTM68kUnhandledOpcode"
                    format:@"m68k backend: no codegen for IR opcode %d — refusing "
                           @"to emit a silently-wrong binary. Add a case (or an "
                           @"explicit no-op) for it.",
                           (int)insn.opcode];
        break;
        }
    }

@end
