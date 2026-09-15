#import <Foundation/Foundation.h>
#import "XTDwarfReader.h"
#import "XTDwarfInterface.h"
#import "XTType.h"
#import "XTPointerType.h"
#import "XTStructType.h"

#define ASSERT_TRUE(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } \
    else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

// Locate the checked-in fixture relative to a couple of plausible CWDs so the
// test works whether run from the repo root (`make test`) or elsewhere.
static NSString *fixturePath(NSString *name) {
    NSArray<NSString *> *candidates = @[
        [@"tests/dwarf/fixtures" stringByAppendingPathComponent:name],
        [@"../tests/dwarf/fixtures" stringByAppendingPathComponent:name],
    ];
    for (NSString *p in candidates)
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    return candidates[0];
}

static XTStructField *fieldNamed(XTStructType *st, NSString *n) {
    for (XTStructField *f in st.fields)
        if ([f.fieldName isEqualToString:n]) return f;
    return nil;
}

int runDwarfReaderTests(void) {
    int failures = 0;

    // Pin the widths this suite's assertions were written against — the
    // process defaults it always inherited (it never configured any). The
    // scenario is DELIBERATELY "xtc pointer narrower than the C lib's":
    // the reader synthesises pads at ITS pointer width (default 2, matching
    // ambient 2), so gfx_surface's px imports as a 2-byte slot + 2-byte
    // tail pad and the total still equals DW_AT_byte_size. A mismatched
    // ambient width (e.g. 8 leaked from the arm64 suite, or a well-meaning
    // pin of 4) breaks that coherence. Imported structs are :packed, so
    // the field-alignment cap can't reshape them — set it to the value
    // that would EXPOSE any accidental re-alignment of an import.
    [XTPointerType setHeapPointerWidth:2];
    [XTType setFloatWidth:5];
    [XTType setFloatIsIEEE:NO];
    [XTStructType setFieldAlignmentCap:8];

    NSError *err = nil;
    XTDwarfInterface *iface =
        [XTDwarfReader readInterfaceFromPath:fixturePath(@"tinylib.so") error:&err];

    ASSERT_TRUE(iface != nil, "reads tinylib.so interface");
    if (!iface) {
        fprintf(stderr, "  (error: %s)\n", err.localizedDescription.UTF8String);
        return failures;
    }

    // ── .dynsym export set ──────────────────────────────────────────────
    ASSERT_TRUE([iface.exports containsObject:@"surface_area"],   "exports surface_area");
    ASSERT_TRUE([iface.exports containsObject:@"surface_stride"], "exports surface_stride");

    // ── function signatures from DWARF ──────────────────────────────────
    XTDwarfFunction *area = iface.functionsByName[@"surface_area"];
    ASSERT_TRUE(area != nil, "typed surface_area");
    if (area) {
        ASSERT_TRUE(area.returnType.kind == XTTypeKindI32, "surface_area returns i32 (C int)");
        ASSERT_TRUE(area.paramTypes.count == 1, "surface_area takes one param");
        XTType *p0 = area.paramTypes.firstObject;
        ASSERT_TRUE(p0.kind == XTTypeKindPointer, "param is a pointer");
        if ([p0 isKindOfClass:[XTPointerType class]]) {
            XTType *pointee = ((XTPointerType *)p0).pointeeType;
            ASSERT_TRUE(pointee.kind == XTTypeKindStruct, "points to a struct");
        }
    }

    XTDwarfFunction *stride = iface.functionsByName[@"surface_stride"];
    ASSERT_TRUE(stride != nil, "typed surface_stride");
    if (stride) {
        ASSERT_TRUE(stride.returnType.kind == XTTypeKindU32, "surface_stride returns u32 (uint32_t)");
    }

    // ── struct layout taken VERBATIM from DWARF offsets ─────────────────
    XTType *gfx = iface.types[@"gfx_surface"];
    ASSERT_TRUE(gfx != nil && gfx.kind == XTTypeKindStruct, "imports gfx_surface as a struct type");
    if ([gfx isKindOfClass:[XTStructType class]]) {
        XTStructType *st = (XTStructType *)gfx;
        if (st.byteWidth != 12)
            fprintf(stderr, "  (gfx_surface byteWidth=%lu packed=%d fields=%lu)\n",
                    (unsigned long)st.byteWidth, st.packed, (unsigned long)st.fields.count);
        ASSERT_TRUE(st.byteWidth == 12, "gfx_surface total size == DW_AT_byte_size (12)");

        XTStructField *w = fieldNamed(st, @"w");
        XTStructField *h = fieldNamed(st, @"h");
        XTStructField *strideF = fieldNamed(st, @"stride");
        XTStructField *px = fieldNamed(st, @"px");
        ASSERT_TRUE(w  && w.byteOffset == 0,      "w  @ offset 0");
        ASSERT_TRUE(h  && h.byteOffset == 2,      "h  @ offset 2");
        ASSERT_TRUE(strideF && strideF.byteOffset == 4, "stride @ offset 4");
        ASSERT_TRUE(px && px.byteOffset == 8,     "px @ offset 8 (verbatim, despite narrower xtc pointer)");
        ASSERT_TRUE(strideF && strideF.fieldType.kind == XTTypeKindU32, "stride field is u32");
    }

    // ── Native-pointer-width layout + self-referential typed pointers ───
    // librec.so: struct rec { void *p; short x; struct rec *next; }
    // C/ARM layout (4-byte pointers): p@0, x@4, next@8, size 12. With
    // targetPointerWidth:4 the reconstructed field SEQUENCE must reproduce
    // those offsets when tight-packed at native widths — i.e. NO pad before
    // x (a 4-byte p already reaches offset 4), and a pad between x and next.
    XTDwarfInterface *rec4 =
        [XTDwarfReader readInterfaceFromPath:fixturePath(@"librec.so")
                          targetPointerWidth:4 error:&err];
    ASSERT_TRUE(rec4 != nil, "reads librec.so @ ptr-width 4");
    XTType *recT = rec4.types[@"rec"];
    ASSERT_TRUE([recT isKindOfClass:[XTStructType class]], "imports rec as a struct");
    if ([recT isKindOfClass:[XTStructType class]]) {
        XTStructType *st = (XTStructType *)recT;
        // Field sequence at native widths: p(4), x(2), pad(2), next(4).
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (XTStructField *f in st.fields) [names addObject:f.fieldName];
        ASSERT_TRUE(st.fields.count == 4, "rec has 4 fields (p, x, pad, next) at width 4");
        ASSERT_TRUE([names[0] isEqualToString:@"p"], "field 0 is p");
        ASSERT_TRUE([names[1] isEqualToString:@"x"], "field 1 is x (no pad before — 4-byte p reaches offset 4)");
        ASSERT_TRUE([names[2] hasPrefix:@"__pad"], "field 2 is padding (x@4..6 → next@8)");
        ASSERT_TRUE([names[3] isEqualToString:@"next"], "field 3 is next");

        // next is a TYPED self-referential pointer (rec@), not an opaque handle.
        XTStructField *next = fieldNamed(st, @"next");
        ASSERT_TRUE(next && [next.fieldType isKindOfClass:[XTPointerType class]],
                    "next is a typed pointer (not bare/opaque)");
        if ([next.fieldType isKindOfClass:[XTPointerType class]]) {
            XTType *pointee = ((XTPointerType *)next.fieldType).pointeeType;
            ASSERT_TRUE(pointee.kind == XTTypeKindStruct, "next points to a struct (self-reference resolved)");
            ASSERT_TRUE([pointee.displayName isEqualToString:@"rec"], "next points back to rec");
        }
    }
    XTDwarfFunction *recx = rec4.functionsByName[@"rec_x"];
    ASSERT_TRUE(recx && recx.returnType.kind == XTTypeKindI32, "rec_x returns i32");
    ASSERT_TRUE(recx && recx.paramTypes.count == 1
                && recx.paramTypes.firstObject.kind == XTTypeKindPointer,
                "rec_x takes a rec pointer");

    // ── Mach-O container + sibling .dSYM (macOS) ────────────────────────
    // Same tinylib.c, but built as a native Mach-O dylib whose DWARF lives in
    // a sibling `.dSYM` (Darwin's default). The reader must dispatch on the
    // Mach-O magic, pull exports from LC_SYMTAB, and read the DWARF from the
    // `.dSYM` — recovering the identical interface it gets from the ELF fixture.
#if defined(__APPLE__)
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xtc-macho-dwarf"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *dylib = [dir stringByAppendingPathComponent:@"tinylib.so"];
    NSTask *cc = [[NSTask alloc] init];
    cc.launchPath = @"/usr/bin/clang";
    cc.arguments  = @[@"-g", @"-shared", fixturePath(@"tinylib.c"), @"-o", dylib];
    @try { [cc launch]; [cc waitUntilExit]; } @catch (NSException *e) { /* no clang → skip */ }

    if ([[NSFileManager defaultManager] fileExistsAtPath:dylib]) {
        NSError *mErr = nil;
        XTDwarfInterface *m = [XTDwarfReader readInterfaceFromPath:dylib error:&mErr];
        ASSERT_TRUE(m != nil, "reads Mach-O tinylib.so interface");
        ASSERT_TRUE([m.exports containsObject:@"surface_area"],
                    "Mach-O exports surface_area (underscore stripped)");
        XTDwarfFunction *ma = m.functionsByName[@"surface_area"];
        ASSERT_TRUE(ma != nil, "Mach-O typed surface_area (DWARF from .dSYM)");
        ASSERT_TRUE(ma && ma.returnType.kind == XTTypeKindI32, "Mach-O surface_area returns i32");
        ASSERT_TRUE(ma && ma.paramTypes.count == 1
                    && ma.paramTypes.firstObject.kind == XTTypeKindPointer,
                    "Mach-O surface_area takes a pointer");
        XTType *mg = m.types[@"gfx_surface"];
        ASSERT_TRUE([mg isKindOfClass:[XTStructType class]], "Mach-O imports gfx_surface struct");
        if ([mg isKindOfClass:[XTStructType class]]) {
            XTStructField *strideF = fieldNamed((XTStructType *)mg, @"stride");
            ASSERT_TRUE(strideF && strideF.byteOffset == 4,
                        "Mach-O gfx_surface stride @ offset 4 (verbatim DWARF layout)");
        }

        // ── Imported enum CONSTANTS (gap D) ─────────────────────────────
        // A C library's enumerators must arrive as usable bare identifiers.
        // They previously did NOT: only the enum TYPE was registered, so
        // `W_NAME` was an "Undefined identifier" and every binding had to
        // hand-mirror the values — duplication that silently drifts when the
        // header changes. They are now swept out of ALL enum DIEs (a typedef'd
        // or tagged enum is never reached by following type references alone).
        ASSERT_TRUE(m.enumConstants[@"W_NAME"].longLongValue == 3,
                    "typedef enum constant W_NAME = 3");
        ASSERT_TRUE(m.enumConstants[@"W_CLOSER"].longLongValue == 4,
                    "typedef enum constant W_CLOSER = 4");
        ASSERT_TRUE(m.enumConstants[@"OS_DISABLED"].longLongValue == 8,
                    "tagged enum constant OS_DISABLED = 8");

        // DARWIN-ONLY behaviour, pinned so nobody re-derives a false general
        // rule from it. clang emits the enumerators into the .o, but the Mach-O
        // link keeps DWARF in a sibling .dSYM and dsymutil STRIPS the
        // unreferenced enum type — so an untagged anonymous enum vanishes here.
        //
        // This is NOT a property of DWARF and does NOT apply to the ELF/gcc
        // targets that actually consume library imports (arm9, x86_64): there,
        // building the library with -fno-eliminate-unused-debug-types brings
        // every constant back at zero runtime cost (the ALLOC sections are
        // byte-identical). See private:docs/Design/c-library-imports.md.
        ASSERT_TRUE(m.enumConstants[@"G_USERDEF"] == nil,
                    "Darwin: dsymutil strips an unreferenced anonymous enum");
    } else {
        fprintf(stderr, "  SKIP: clang unavailable — Mach-O reader path not exercised\n");
    }
#endif

    return failures;
}
