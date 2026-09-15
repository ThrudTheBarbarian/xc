// XTTypeWidthInvariantTests.m — the AST/IR type widths must equal the widths
// the backend actually lays out.
//
// THE INVARIANT
// -------------
// For every target, and for every scalar leaf type, the width the front end
// gives it (XTType.byteWidth, driven by XTPointerType.heapPointerWidth and
// XTType.floatWidth) must equal the width the backend gives it (that backend's
// own fieldWidth function).
//
// WHY IT MATTERS, AND WHY IT IS NOT COSMETIC
// ------------------------------------------
// A struct's IR layout offsets are the AST widths summed in declaration order;
// a backend's field offsets are ITS widths summed in declaration order. They
// agree if and only if each leaf agrees. And they have to agree, because the IR
// optimisation passes fold field and element offsets straight out of the IR
// layout, while the backend reads with its own — so a divergence does not stay
// contained in the type system, it becomes a wrong ADDRESS in optimised code.
//
// HOW IT PRESENTS WHEN IT BREAKS (read this before believing a bug report)
// -----------------------------------------------------------------------
// It does NOT look like a layout error. `struct {u16; u8@; float; u16}` was 17
// bytes in the IR layout and 16 in arm64's, and what came out was
// `add x10, x25, #17` — an element stride one byte too long. Element 0 read
// fine (its offset is 0 either way) and every element after it came back
// shifted. That reads exactly like a loop miscompile, and it cost a lot of
// bisecting: the same silhouette (first entry fine, rest garbage) was reported
// twice, from two unrelated directions, before the shared cause was found.
//
// If you are ever chasing "first element correct, later elements garbage",
// check this invariant FIRST.
//
// The widths were wrong for nearly every target before task #581: pointers
// were 2 on arm64, 4 on x86-64 and 3 on m68k against backends using 8/8/4, and
// floats were xtc's 5 bytes everywhere against a 4-byte IEEE single natively.
// Adding a target, changing a pointer size (an LP64 6502? a MECH FPU that
// makes xt6502's float 4-byte IEEE) or "just tweaking" a fieldWidth function
// re-opens it. This test is the tripwire.
// STRUCT OFFSETS (blewit #5) are no longer a second copy of this contract:
// the front end lays fields out ONCE — at min(natural alignment, the target's
// field-alignment cap) — records the offsets in the IR layout, and every
// backend reads them verbatim. The offset probe below asserts both halves:
// that the front end's layout matches each target's C ABI expectation, and
// that the backend's fieldOffset really is the recorded offset (i.e. nobody
// has quietly reverted to a private prefix-sum).
#import <Foundation/Foundation.h>
#import "XTType.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTArm64Backend.h"
#import "XTM68kBackend.h"
#import "XTArm9Backend.h"
#import "XTX86_64Backend.h"
#import "XT6502Backend.h"
#import "XTWasmBackend.h"

// The backends' width functions are private to their .m files; declare them so
// the test can ask each backend what IT thinks a leaf is worth.
@interface XTArm64Backend (WidthProbe)
+ (NSUInteger)arm64FieldWidth:(XTIRType*)t;
+ (NSUInteger)arm64FieldOffset:(XTIRLayout*)l index:(NSUInteger)i;
@end
@interface XTM68kBackend (WidthProbe)
+ (NSUInteger)m68kFieldWidth:(XTIRType*)t;
+ (NSUInteger)m68kFieldOffset:(XTIRLayout*)l index:(NSUInteger)i;
@end
@interface XTArm9Backend (WidthProbe)
+ (NSUInteger)fieldWidth:(XTIRType*)t;
+ (NSUInteger)fieldOffset:(XTIRLayout*)l index:(NSUInteger)i;
@end
@interface XTX86_64Backend (WidthProbe)
+ (NSUInteger)fieldWidth:(XTIRType*)t;
+ (NSUInteger)fieldOffset:(XTIRLayout*)l index:(NSUInteger)i;
@end
@interface XT6502Backend (WidthProbe)
+ (NSUInteger)byteWidthForType:(XTIRType*)t;
@end
@interface XTWasmBackend (WidthProbe)
+ (NSUInteger)wasmFieldWidth:(XTIRType*)t;
+ (NSUInteger)wasmFieldOffset:(XTIRLayout*)l index:(NSUInteger)i;
@end

static int gFailures;

static void expectWidth(const char* target, const char* leaf,
                        NSUInteger astWidth, NSUInteger backendWidth)
    {
    if (astWidth == backendWidth)
        return;
    gFailures++;
    fprintf(stderr,
            "  FAIL: %s — the front end says %s is %lu bytes, the backend lays it "
            "out as %lu.\n"
            "        Struct offsets will disagree; an optimised element stride "
            "goes wrong and every element after the first reads shifted.\n"
            "        Fix the target's width in XTCompilerDriver (pointer via "
            "XTPointerType.setHeapPointerWidth, float via XTType.setFloatWidth),\n"
            "        or the backend's fieldWidth — but make them agree.\n",
            target, leaf, (unsigned long)astWidth, (unsigned long)backendWidth);
    }

// Check one target: set the front-end widths exactly as XTCompilerDriver would,
// then ask the backend what it lays each leaf out as.
static void checkTarget(const char* target,
                        NSUInteger ptrWidth, NSUInteger floatWidth,
                        NSUInteger (^backendWidth)(XTIRType*))
    {
    [XTPointerType setHeapPointerWidth:ptrWidth];
    [XTType setFloatWidth:floatWidth];
    [XTType setFloatIsIEEE:YES]; // every target is IEEE now (xt6502 via MECH)

    // Pointer and float are the two that have actually drifted.
    expectWidth(target, "a pointer", [XTPointerType pointerToType:[XTType u8Type]].byteWidth,
                backendWidth([XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked]));
    expectWidth(target, "float", [XTType floatType].byteWidth,
                backendWidth([XTIRType f32Type]));
    expectWidth(target, "double", [XTType doubleType].byteWidth,
                backendWidth([XTIRType f64Type]));

    // The integers have always agreed. Assert it anyway — if one ever moves,
    // it fails here rather than as a mystery stride bug three layers down.
    expectWidth(target, "u8", [XTType u8Type].byteWidth, backendWidth([XTIRType u8Type]));
    expectWidth(target, "u16", [XTType u16Type].byteWidth, backendWidth([XTIRType u16Type]));
    expectWidth(target, "u32", [XTType u32Type].byteWidth, backendWidth([XTIRType u32Type]));
    // i64/u64 are 8 bytes on EVERY target, including the ones whose arithmetic
    // cannot do 64 bits yet. The width is a layout contract, not a capability
    // claim: an unsupported operation is rejected per-op, but a width the back
    // end disagrees with corrupts struct offsets in optimised code instead.
    expectWidth(target, "i64", [XTType i64Type].byteWidth, backendWidth([XTIRType i64Type]));
    expectWidth(target, "u64", [XTType u64Type].byteWidth, backendWidth([XTIRType u64Type]));
    }

// ── Struct-offset probe (blewit #5) ────────────────────────────────────────
// One canonical struct touching every alignment class:
//     { u8 a; u32 b; u8 c; double d; u8* e; }
// For each target: set the widths + caps exactly as XTCompilerDriver would,
// lay it out, and assert (1) the front end's offsets match the target's C-ABI
// expectation, and (2) the backend's fieldOffset returns the RECORDED offset
// — i.e. it reads the layout rather than re-deriving a private prefix sum.
static void checkOffsets(const char* target,
                         NSUInteger ptrWidth, NSUInteger fieldCap, NSUInteger tailCap,
                         const NSUInteger expect[5], NSUInteger expectSize,
                         NSUInteger (^_Nullable backendOffset)(XTIRLayout*, NSUInteger))
    {
    [XTPointerType setHeapPointerWidth:ptrWidth];
    [XTType setFloatWidth:4];
    [XTType setFloatIsIEEE:YES];
    [XTStructType setFieldAlignmentCap:fieldCap tailCap:tailCap];

    NSArray<XTStructField*>* fields = @[
        [[XTStructField alloc] initWithName:@"a"
                                       type:[XTType u8Type]],
        [[XTStructField alloc] initWithName:@"b"
                                       type:[XTType u32Type]],
        [[XTStructField alloc] initWithName:@"c"
                                       type:[XTType u8Type]],
        [[XTStructField alloc] initWithName:@"d"
                                       type:[XTType doubleType]],
        [[XTStructField alloc] initWithName:@"e"
                                       type:[XTPointerType pointerToType:[XTType u8Type]]],
    ];
    XTStructType* st = [XTStructType structNamed:@"__offset_probe" fields:fields];
    for (NSUInteger i = 0; i < 5; i++)
        {
        if (st.fields[i].byteOffset == expect[i])
            continue;
        gFailures++;
        fprintf(stderr,
                "  FAIL: %s — field '%s' laid at offset %lu, the target's C ABI "
                "expects %lu.\n        The field-alignment rule (min(natural, "
                "cap %lu)) or the cap itself is wrong for this target.\n",
                target, st.fields[i].fieldName.UTF8String,
                (unsigned long)st.fields[i].byteOffset, (unsigned long)expect[i],
                (unsigned long)fieldCap);
        }
    if (st.byteWidth != expectSize)
        {
        gFailures++;
        fprintf(stderr,
                "  FAIL: %s — probe struct sizeof is %lu, expected %lu "
                "(tail cap %lu).\n",
                target, (unsigned long)st.byteWidth, (unsigned long)expectSize,
                (unsigned long)tailCap);
        }

    if (!backendOffset)
        return;
    // Mirror layoutForStructType: the recorded offsets become the IR layout,
    // and the backend must read them verbatim.
    XTIRType* leaves[5] = {[XTIRType u8Type], [XTIRType u32Type], [XTIRType u8Type], [XTIRType f64Type], [XTIRType ptrToType:[XTIRType u8Type]
                                                                                                                      window:XTIRWindowUnbanked]};
    NSMutableArray<XTIRLayoutField*>* irFields = [NSMutableArray array];
    for (NSUInteger i = 0; i < 5; i++)
        [irFields addObject:[[XTIRLayoutField alloc]
                                initWithOffset:(uint32_t)st.fields[i].byteOffset
                                          type:leaves[i]]];
    XTIRLayout* L = [[XTIRLayout alloc] initWithSize:(uint32_t)st.byteWidth
                                           alignment:1
                                              fields:irFields];
    for (NSUInteger i = 0; i < 5; i++)
        {
        NSUInteger got = backendOffset(L, i);
        if (got == expect[i])
            continue;
        gFailures++;
        fprintf(stderr,
                "  FAIL: %s — backend fieldOffset(%lu) says %lu, the recorded "
                "layout says %lu.\n        The backend must READ the recorded "
                "offset, not re-derive it from its own widths.\n",
                target, (unsigned long)i, (unsigned long)got,
                (unsigned long)expect[i]);
        }
    }

int runTypeWidthInvariantTests(void)
    {
    gFailures = 0;

    NSUInteger savedPtr = [XTPointerType heapPointerWidth];
    NSUInteger savedFlt = [XTType floatWidth];
    BOOL savedIEEE = [XTType floatIsIEEE];
    NSUInteger savedFieldCap = [XTStructType fieldAlignmentCap];
    NSUInteger savedTailCap = [XTStructType tailAlignmentCap];

    // Keep these rows in step with XTCompilerDriver's per-target settings.
    checkTarget("arm64", 8, 4, ^NSUInteger(XTIRType* t) {
      return [XTArm64Backend arm64FieldWidth:t];
    });
    checkTarget("x86_64", 8, 4, ^NSUInteger(XTIRType* t) {
      return [XTX86_64Backend fieldWidth:t];
    });
    checkTarget("m68k", 4, 4, ^NSUInteger(XTIRType* t) {
      return [XTM68kBackend m68kFieldWidth:t];
    });
    checkTarget("arm9", 4, 4, ^NSUInteger(XTIRType* t) {
      return [XTArm9Backend fieldWidth:t];
    });
    // wasm32: 4-byte linear-memory pointers, IEEE f32/f64 (wasm value types).
    checkTarget("wasm32", 4, 4, ^NSUInteger(XTIRType* t) {
      return [XTWasmBackend wasmFieldWidth:t];
    });
    // xt6502: 3-byte banked pointers [addr-lo, addr-hi, bank]. Float is now
    // 4-byte IEEE f32 — the MECH coprocessor made the bespoke 5-byte softfloat
    // obsolete (private:docs/Design/mech-offload-xt6502.md), so this row moved 5 -> 4.
    checkTarget("xt6502", 3, 4, ^NSUInteger(XTIRType* t) {
      return [XT6502Backend byteWidthForType:t];
    });

        // ── Offsets: { u8 a; u32 b; u8 c; double d; u8* e; } per target ──────
        // Expectations are each target's C ABI (clang -arch arm64 / -m68000 gcc);
        // xt6502 is the tightly packed historical layout with pow2 tail rounding.
        {
        const NSUInteger arm64Exp[5] = {0, 4, 8, 16, 24};
        checkOffsets("arm64", 8, 8, 8, arm64Exp, 32, ^NSUInteger(XTIRLayout* l, NSUInteger i) {
          return [XTArm64Backend arm64FieldOffset:l index:i];
        });
        checkOffsets("x86_64", 8, 8, 8, arm64Exp, 32, ^NSUInteger(XTIRLayout* l, NSUInteger i) {
          return [XTX86_64Backend fieldOffset:l index:i];
        });
        const NSUInteger arm9Exp[5] = {0, 4, 8, 16, 24}; // ptr 4 → e still 8-aligned at 24
        checkOffsets("arm9", 4, 8, 8, arm9Exp, 32, ^NSUInteger(XTIRLayout* l, NSUInteger i) {
          return [XTArm9Backend fieldOffset:l index:i];
        });
        const NSUInteger m68kExp[5] = {0, 2, 6, 8, 16}; // everything 2-aligned
        checkOffsets("m68k", 4, 2, 2, m68kExp, 20, ^NSUInteger(XTIRLayout* l, NSUInteger i) {
          return [XTM68kBackend m68kFieldOffset:l index:i];
        });
        const NSUInteger wasm32Exp[5] = {0, 4, 8, 16, 24}; // clang --target=wasm32 layout
        checkOffsets("wasm32", 4, 8, 8, wasm32Exp, 32, ^NSUInteger(XTIRLayout* l, NSUInteger i) {
          return [XTWasmBackend wasmFieldOffset:l index:i];
        });
        const NSUInteger xt6502Exp[5] = {0, 1, 5, 6, 14};    // tightly packed
        checkOffsets("xt6502", 3, 1, 8, xt6502Exp, 24, nil); // reads recorded offsets already
        }

    [XTPointerType setHeapPointerWidth:savedPtr];
    [XTType setFloatWidth:savedFlt];
    [XTType setFloatIsIEEE:savedIEEE];
    [XTStructType setFieldAlignmentCap:savedFieldCap tailCap:savedTailCap];

    if (gFailures == 0)
        fprintf(stderr, "  PASS: front-end and backend leaf widths agree on all 5 targets\n");
    return gFailures;
    }
