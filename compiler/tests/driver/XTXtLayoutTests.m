/****************************************************************************\
|* XTXtLayoutTests.m
|*
|* Task #55 — make the xt6502 backend memory-model-aware.
|*
|* Three independent checks:
|*   1. Parser round-trip: a synthetic layout with DISTINCT, NON-xt
|*      values is parsed and every field is asserted to round-trip,
|*      including the page sizes the parser DERIVES from the window
|*      length. This tests the parser, not any particular address map —
|*      the layout exists so those numbers can change, so the test must
|*      not bake them in.
|*   2. Shipped sanity: the real `support/xt6502/layouts/xt.lnk` must
|*      parse and be internally CONSISTENT (windows disjoint, registers
|*      distinct, entry in the system region, vars clear of arc-scratch,
|*      page size == window length). It asserts NO specific addresses —
|*      those are the layout's to choose.
|*   3. Negative end-to-end guard: a `.code_regions`-bounded program
|*      whose static data crosses the screen boundary makes xta fail
|*      the build with "exceeds the declared .code_regions". This is
|*      the screen-RAM overrun guard the backend now emits — the
|*      safeguard that keeps spill placement (#56/#57) honest.
\****************************************************************************/

#import <Foundation/Foundation.h>
#include <unistd.h>          // getpid() — Apple's Foundation drags this in
                             // transitively, GNUstep's does not, so on Linux
                             // the implicit declaration is a hard error.
#import "XTMemoryModel.h"
#import "XTLinkerScriptParser.h"
#import "XAAssembler.h"

#define ASSERT_TRUE(cond, msg) \
    do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

#define ASSERT_EQ(lhs, rhs, msg) \
    do { if ((NSInteger)(lhs) != (NSInteger)(rhs)) { \
             fprintf(stderr, "  FAIL: %s (%ld != %ld)\n", msg, \
                     (long)(lhs), (long)(rhs)); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

// Locate the shipped xt.lnk across the CWDs `make test` / CI may
// use. Returns nil if not found anywhere.
static NSString *findXtNewLnk(void) {
    NSArray<NSString *> *candidates = @[
        @"support/xt6502/layouts/xt.lnk",
        @"../support/xt6502/layouts/xt.lnk",
        @"/opt/xtc/support/xt6502/layouts/xt.lnk",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// Parser round-trip: feed a layout with DISTINCT, NON-canonical values
// and assert the parser reproduces exactly those — including the values
// it DERIVES (a bank window's page size is its length). This tests the
// parser (does each key land in the right field?), NOT any particular
// xt address map: the layout exists precisely so the numbers can change,
// so the test must not bake them in. Deliberately uses none of the real
// xt addresses.
static int assertParserRoundTrip(void) {
    int failures = 0;
    NSString *src = @""
        "[zp]\n"
        "hp          = $40-$41\n"
        "arc-scratch = $42-$4B\n"
        "vars        = $4C-$5F, $70-$7F\n"
        "runtime     = $60-$6F\n"
        "[memory]\n"
        "system  = $1000-$1FFF\n"
        "screen  = $2000-$2FFF\n"
        "main    = $C000-$CFFF\n"
        "[banking]\n"
        "code-window = $3000-$4FFF\n"      // length $2000 → page size $2000
        "code-reg    = $D500\n"
        "data-window = $5000-$6FFF\n"       // length $2000 → page size $2000
        "data-reg    = $D501\n"
        "extra-window = $7000-$77FF\n"      // a third (future) region
        "extra-reg    = $D502\n"
        "[stack]\n"
        "range = $0200-$03FF\n"
        "grows = up\n"
        "[heap]\n"
        "range = $5000-$7000\n"
        "bank  = $02-$08\n"
        "grows = up\n"
        "[entry]\n"
        "address = $1000\n";
    NSString *tmp = [NSString stringWithFormat:@"/tmp/xtc-xtparse-test-%d.lnk",
                                                (int)getpid()];
    [src writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSError *err = nil;
    XTMemoryModel *m = [XTLinkerScriptParser parseFile:tmp error:&err];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

    ASSERT_TRUE(m != nil, "parser: layout parses");
    if (!m) return failures;

    ASSERT_EQ(m.entryAddress, 0x1000, "parser: entry round-trips");
    ASSERT_EQ(m.systemStart, 0x1000, "parser: system start round-trips");
    ASSERT_EQ(m.systemEnd, 0x1FFF, "parser: system end round-trips");
    ASSERT_EQ(m.screenStart, 0x2000, "parser: screen start round-trips");
    ASSERT_EQ(m.screenEnd, 0x2FFF, "parser: screen end round-trips");
    ASSERT_EQ(m.mainRegionRanges.count, 1, "parser: one main region");
    if (m.mainRegionRanges.count >= 1) {
        ASSERT_EQ(m.mainRegionRanges[0][0].unsignedIntegerValue, 0xC000,
                  "parser: main start round-trips");
        ASSERT_EQ(m.mainRegionRanges[0][1].unsignedIntegerValue, 0xCFFF,
                  "parser: main end round-trips");
    }
    // Code/data windows + their own registers. Page size is DERIVED from
    // the window length, never declared.
    ASSERT_TRUE(m.hasBanking, "parser: [banking] present");
    ASSERT_EQ(m.bankWindowStart, 0x3000, "parser: code window start round-trips");
    ASSERT_EQ(m.bankWindowEnd, 0x4FFF, "parser: code window end round-trips");
    ASSERT_EQ(m.bankPageSize, 0x2000, "parser: code page size DERIVED from window");
    ASSERT_EQ(m.codeBankReg, 0xD500, "parser: codeReg round-trips");
    ASSERT_EQ(m.dataWindowStart, 0x5000, "parser: data window start round-trips");
    ASSERT_EQ(m.dataWindowEnd, 0x6FFF, "parser: data window end round-trips");
    ASSERT_EQ(m.dataPageSize, 0x2000, "parser: data page size DERIVED from window");
    ASSERT_EQ(m.dataBankReg, 0xD501, "parser: dataReg round-trips");
    // A non-code/data region (`extra-window`/`extra-reg`) is preserved
    // generically — the convention extends without new parser keys.
    ASSERT_TRUE(m.extraBankRegions[@"extra"] != nil, "parser: extra region captured");
    if (m.extraBankRegions[@"extra"]) {
        ASSERT_EQ(m.extraBankRegions[@"extra"][@"windowStart"].unsignedIntegerValue,
                  0x7000, "parser: extra window start round-trips");
        ASSERT_EQ(m.extraBankRegions[@"extra"][@"reg"].unsignedIntegerValue,
                  0xD502, "parser: extra reg round-trips");
    }
    // Declaring windows + per-window registers must NOT switch on static
    // split-bank placement — that is a separate, codeWindow-driven concern.
    ASSERT_TRUE(!m.hasSplitBanking, "parser: window/reg decls don't force split banking");
    // ZP slots round-trip.
    ASSERT_EQ(m.zpHPStart, 0x40, "parser: hp round-trips");
    ASSERT_EQ(m.zpArcScratchStart, 0x42, "parser: arc-scratch start round-trips");
    ASSERT_EQ(m.zpArcScratchEnd, 0x4B, "parser: arc-scratch end round-trips");
    ASSERT_EQ(m.zpVarsRanges.count, 2, "parser: two var ranges");
    if (m.zpVarsRanges.count >= 2) {
        ASSERT_EQ(m.zpVarsRanges[0][0].unsignedIntegerValue, 0x4C,
                  "parser: vars start round-trips");
    }
    // Heap range + bank span.
    ASSERT_EQ(m.heapLow, 0x5000, "parser: heap low round-trips");
    ASSERT_EQ(m.heapTop, 0x7000, "parser: heap top round-trips");
    ASSERT_EQ(m.heapBank, 0x02, "parser: heap first bank round-trips");
    ASSERT_EQ(m.heapBankEnd, 0x08, "parser: heap last bank round-trips");
    ASSERT_TRUE(m.stackRangeSet, "parser: [stack] range set");
    ASSERT_EQ(m.stackRangeStart, 0x0200, "parser: stack start round-trips");
    return failures;
}

// Shipped xt.lnk sanity: the file must parse and be internally CONSISTENT,
// but the test asserts no specific addresses — those are the layout's to
// choose. It checks the invariants any valid xt layout must hold.
static int assertShippedXtSane(XTMemoryModel *m) {
    int failures = 0;
    ASSERT_TRUE(m != nil, "shipped: xt.lnk parses");
    if (!m) return failures;

    ASSERT_TRUE(m.hasBanking, "shipped: banking declared");
    ASSERT_TRUE(m.bankWindowEnd > m.bankWindowStart, "shipped: code window non-empty");
    ASSERT_TRUE(m.dataWindowEnd > m.dataWindowStart, "shipped: data window non-empty");
    ASSERT_TRUE(m.codeBankReg != 0 && m.dataBankReg != 0,
                "shipped: both bank registers declared");
    ASSERT_TRUE(m.codeBankReg != m.dataBankReg,
                "shipped: code and data registers are distinct");
    // Page size is the window length (derived, not declared).
    ASSERT_TRUE(m.bankPageSize == (uint16_t)(m.bankWindowEnd - m.bankWindowStart + 1),
                "shipped: code page size == window length");
    ASSERT_TRUE(m.dataPageSize == (uint16_t)(m.dataWindowEnd - m.dataWindowStart + 1),
                "shipped: data page size == window length");
    // Code and data windows must not overlap.
    BOOL windowsDisjoint = (m.dataWindowStart > m.bankWindowEnd) ||
                           (m.bankWindowStart > m.dataWindowEnd);
    ASSERT_TRUE(windowsDisjoint, "shipped: code and data windows disjoint");
    // Entry lands inside the system region.
    ASSERT_TRUE(m.entryAddress >= m.systemStart && m.entryAddress <= m.systemEnd,
                "shipped: entry within system region");
    // The var pool must not collide with the ARC-scratch reservation.
    if (m.zpArcScratchEnd) {
        for (NSArray<NSNumber *> *r in m.zpVarsRanges) {
            BOOL overlap = !(r[0].unsignedIntegerValue > m.zpArcScratchEnd ||
                             r[1].unsignedIntegerValue < m.zpArcScratchStart);
            ASSERT_TRUE(!overlap, "shipped: vars clear of arc-scratch");
        }
    }
    ASSERT_TRUE(m.heapLow != 0 || m.heapBank != 0, "shipped: heap declared");
    ASSERT_TRUE(m.entryAddress != 0, "shipped: entry declared");
    return failures;
}

int runXtLayoutTests(void) {
    int failures = 0;

    // ── 1. Parser round-trip on arbitrary (non-xt) values ─────────
    failures += assertParserRoundTrip();

    // ── 2. Shipped xt.lnk parses + is internally consistent ───────
    {
        NSString *path = findXtNewLnk();
        if (path) {
            NSError *err = nil;
            XTMemoryModel *m = [XTLinkerScriptParser parseFile:path error:&err];
            failures += assertShippedXtSane(m);
        } else {
            fprintf(stderr, "  SKIP: xt.lnk not found on disk "
                    "(parser round-trip above still covers the parser)\n");
        }
    }

    // ── 2. Screen-overrun guard: static data past screenStart fails ─
    //
    // The backend emits `.code_regions <mainRegionRanges>`. Here we
    // reproduce that with the harness model's region ($2000-$9BFF,
    // screen at $9C00) and place a chunk of static data that crosses
    // the region end. xta's pass-1 overflow check must fail the build.
    {
        // .org near the region end so a small .byte chunk crosses it
        // in one step from inside the region — exercises the exact
        // guard path without 31 KB of filler.
        NSMutableString *bytes = [NSMutableString stringWithString:@"$00"];
        for (int i = 0; i < 39; i++) [bytes appendString:@",$00"];  // 40 bytes
        NSString *src = [NSString stringWithFormat:
            @".code_regions $2000-$9BFF\n"
            @"    .org $9BF0\n"
            @"_overrun: .byte %@\n", bytes];   // $9BF0 + 40 = $9C18 > $9BFF

        XAAssembler *a = [XAAssembler new];
        NSArray<XASegment *> *segs = [a assembleSource:src filename:@"overrun.s"];
        ASSERT_TRUE(segs == nil,
                    "guard: assembly fails when data crosses screenStart");

        BOOL sawMsg = NO;
        for (NSString *e in a.errors) {
            if ([e containsString:@"exceeds the declared .code_regions"]) {
                sawMsg = YES; break;
            }
        }
        ASSERT_TRUE(sawMsg,
                    "guard: error names the .code_regions overflow");
    }

    // ── 2b. Control: the same data one region-end-aligned step lower
    //         assembles cleanly (the guard isn't a false positive). ─
    {
        NSMutableString *bytes = [NSMutableString stringWithString:@"$00"];
        for (int i = 0; i < 39; i++) [bytes appendString:@",$00"];  // 40 bytes
        NSString *src = [NSString stringWithFormat:
            @".code_regions $2000-$9BFF\n"
            @"    .org $9000\n"
            @"_ok: .byte %@\n", bytes];        // $9000 + 40, well inside

        XAAssembler *a = [XAAssembler new];
        NSArray<XASegment *> *segs = [a assembleSource:src filename:@"ok.s"];
        ASSERT_TRUE(segs != nil,
                    "guard: data inside the region assembles cleanly");
    }

    // ── 3. Spill negative test (STACK-ABI §11.5): a `.space` spill
    //         slot larger than the usable region must fail the build
    //         via .code_regions. The backend emits pinned-local spills
    //         as `.space`, so the overflow guard must catch `.space`
    //         too — not just `.byte`/instructions. This is what keeps a
    //         spill from silently rotting into screen RAM. ─
    {
        // A 32 KB spill from $2000 runs to $A000, well past $9BFF.
        NSString *src =
            @".code_regions $2000-$9BFF\n"
            @"    .org $2000\n"
            @"_spill_main_1: .space $8000\n";

        XAAssembler *a = [XAAssembler new];
        NSArray<XASegment *> *segs = [a assembleSource:src filename:@"spill.s"];
        ASSERT_TRUE(segs == nil,
                    "spill guard: oversized .space spill fails the build");
        BOOL sawMsg = NO;
        for (NSString *e in a.errors) {
            if ([e containsString:@"exceeds the declared .code_regions"]) {
                sawMsg = YES; break;
            }
        }
        ASSERT_TRUE(sawMsg,
                    "spill guard: error names the .code_regions overflow");
    }

    // ── 3b. Control: a spill that fits the region assembles cleanly. ─
    {
        NSString *src =
            @".code_regions $2000-$9BFF\n"
            @"    .org $2000\n"
            @"_spill_main_1: .space 300\n";   // largevar-sized, fits

        XAAssembler *a = [XAAssembler new];
        NSArray<XASegment *> *segs = [a assembleSource:src filename:@"spillok.s"];
        ASSERT_TRUE(segs != nil,
                    "spill guard: in-region .space spill assembles cleanly");
    }

    return failures;
}
