/****************************************************************************\
|* XARegionCBankTests.m
|*
|* Verifies xta's preload-stub generator handles xt's region C
|* ($7000-$7FFF window, $84/$85 selector pair) correctly:
|*   — segments whose origin falls in [regCWindowStart, regCWindowEnd]
|*     classify as region-C-window
|*   — 16-bit-pair selectors emit a 10-byte preload stub
|*     (LDA / STA <regLo> / LDA / STA <regHi> / RTS)
|*   — 8-bit selectors emit a 5-byte preload stub
|*   — the per-region page counter is independent from code/data
|*     counters
|*   — legacy split-bank xt without regCWindow set is unchanged
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAAssembler.h"

#define ASSERT_TRUE(cond, msg) \
    do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

#define ASSERT_EQ(lhs, rhs, msg) \
    do { if ((NSInteger)(lhs) != (NSInteger)(rhs)) { \
             fprintf(stderr, "  FAIL: %s (%ld != %ld)\n", msg, \
                     (long)(lhs), (long)(rhs)); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

/* Find the byte position of `needle` (length nlen) inside data, or -1. */
static NSInteger findBytes(NSData *data, const uint8_t *needle, NSUInteger nlen) {
    if (data.length < nlen) return -1;
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i + nlen <= data.length; i++) {
        if (memcmp(p + i, needle, nlen) == 0) return (NSInteger)i;
    }
    return -1;
}

int runRegionCBankTests(void) {
    int failures = 0;

    NSString *tmpDir = NSTemporaryDirectory();

    // ── 16-bit selector: ext-window segment emits 10-byte stub ────
    {
        NSString *src =
            @"    .org $4000\n"
            @"    LDA #$01\n"
            @"    .org $7000\n"
            @"    LDA #$02\n";
        XAAssembler *a = [XAAssembler new];
        a.bankedMode = YES;
        a.hasSplitBanking = YES;
        a.codeBankReg = 0x82;
        a.dataBankReg = 0x83;
        a.bankWindowStart = 0x4000;
        a.bankWindowEnd   = 0x7FFF;
        a.dataWindowStart = 0x6000;
        a.dataWindowEnd   = 0x6FFF;
        // Region C: 16-bit selector $84/$85 over $7000-$7FFF.
        a.regCWindowStart = 0x7000;
        a.regCWindowEnd   = 0x7FFF;
        a.regCBankRegLo   = 0x84;
        a.regCBankRegHi   = 0x85;

        NSArray<XASegment *> *segs =
            [a assembleSource:src filename:@"test.s"];
        ASSERT_TRUE(segs.count >= 2,
                    "PR3: assembled both code and ext-window segments");

        NSString *xex = [NSString stringWithFormat:@"%@/pr3-16bit.xex", tmpDir];
        BOOL ok = [a writeBankedXEX:segs entryPoint:0x4000 toFile:xex];
        ASSERT_TRUE(ok, "PR3 16-bit: writeBankedXEX succeeded");

        NSData *bytes = [NSData dataWithContentsOfFile:xex];
        // Look for the 10-byte preload signature:
        //   A9 01 85 84 A9 00 85 85 60
        // (LDA #$01 / STA $84 / LDA #$00 / STA $85 / RTS — page 1, hi byte 0)
        uint8_t needle[] = {0xA9, 0x01, 0x85, 0x84,
                            0xA9, 0x00, 0x85, 0x85, 0x60};
        ASSERT_TRUE(findBytes(bytes, needle, sizeof(needle)) >= 0,
                    "PR3 16-bit: 10-byte preload stub for region C present");

        [[NSFileManager defaultManager] removeItemAtPath:xex error:NULL];
    }

    // ── 8-bit selector: ext-window with regHi=0 → 5-byte stub ────
    {
        NSString *src =
            @"    .org $7000\n"
            @"    LDA #$03\n";
        XAAssembler *a = [XAAssembler new];
        a.bankedMode = YES;
        a.hasSplitBanking = YES;
        a.codeBankReg = 0x82;
        a.dataBankReg = 0x83;
        a.bankWindowStart = 0x4000;
        a.bankWindowEnd   = 0x7FFF;
        a.dataWindowStart = 0x6000;
        a.dataWindowEnd   = 0x6FFF;
        a.regCWindowStart = 0x7000;
        a.regCWindowEnd   = 0x7FFF;
        a.regCBankRegLo   = 0x84;
        a.regCBankRegHi   = 0;     // 8-bit

        NSArray<XASegment *> *segs =
            [a assembleSource:src filename:@"test.s"];
        NSString *xex = [NSString stringWithFormat:@"%@/pr3-8bit.xex", tmpDir];
        BOOL ok = [a writeBankedXEX:segs entryPoint:0x7000 toFile:xex];
        ASSERT_TRUE(ok, "PR3 8-bit: writeBankedXEX succeeded");
        NSData *bytes = [NSData dataWithContentsOfFile:xex];
        // 5-byte stub:  A9 01 85 84 60   (page 1 → $84)
        uint8_t needle[]  = {0xA9, 0x01, 0x85, 0x84, 0x60};
        // The 16-bit form would have an additional LDA/STA $85 we
        // don't want to see following.
        uint8_t bad[]    = {0xA9, 0x01, 0x85, 0x84, 0xA9};
        ASSERT_TRUE(findBytes(bytes, needle, sizeof(needle)) >= 0,
                    "PR3 8-bit: 5-byte preload stub present");
        ASSERT_TRUE(findBytes(bytes, bad, sizeof(bad)) < 0,
                    "PR3 8-bit: no 16-bit prefix bytes follow");
        [[NSFileManager defaultManager] removeItemAtPath:xex error:NULL];
    }

    // ── Independence: ext page counter doesn't share with code ───
    // Two ext segments + one code segment: ext segments get pages 1
    // and 2; code segment gets page 1 (independent counter).
    {
        NSString *src =
            @"    .org $4000\n"
            @"    LDA #$10\n"
            @"    .org $7000\n"
            @"    LDA #$11\n"
            @"    .org $7000\n"
            @"    LDA #$12\n";
        XAAssembler *a = [XAAssembler new];
        a.bankedMode = YES;
        a.hasSplitBanking = YES;
        a.codeBankReg = 0x82;
        a.dataBankReg = 0x83;
        a.bankWindowStart = 0x4000;
        a.bankWindowEnd   = 0x7FFF;
        a.dataWindowStart = 0x6000;
        a.dataWindowEnd   = 0x6FFF;
        a.regCWindowStart = 0x7000;
        a.regCWindowEnd   = 0x7FFF;
        a.regCBankRegLo   = 0x84;
        a.regCBankRegHi   = 0x85;

        NSArray<XASegment *> *segs =
            [a assembleSource:src filename:@"test.s"];
        NSString *xex = [NSString stringWithFormat:@"%@/pr3-counter.xex",
                                                    tmpDir];
        [a writeBankedXEX:segs entryPoint:0x4000 toFile:xex];
        NSData *bytes = [NSData dataWithContentsOfFile:xex];
        // Page-1 stub for code (LDA #$01 / STA $82) — single 5-byte
        // form because hasSplitBanking is on and the code window's
        // selector is 8-bit.
        uint8_t code1[] = {0xA9, 0x01, 0x85, 0x82, 0x60};
        ASSERT_TRUE(findBytes(bytes, code1, sizeof(code1)) >= 0,
                    "PR3 counters: code segment got page 1 ($82)");
        // Page-1 stub for region C (LDA #$01 / STA $84 / LDA #$00 /
        // STA $85 / RTS).
        uint8_t ext1[] = {0xA9, 0x01, 0x85, 0x84, 0xA9, 0x00, 0x85, 0x85, 0x60};
        ASSERT_TRUE(findBytes(bytes, ext1, sizeof(ext1)) >= 0,
                    "PR3 counters: first ext segment got page 1 ($84/$85)");
        // Page-2 stub for region C.
        uint8_t ext2[] = {0xA9, 0x02, 0x85, 0x84, 0xA9, 0x00, 0x85, 0x85, 0x60};
        ASSERT_TRUE(findBytes(bytes, ext2, sizeof(ext2)) >= 0,
                    "PR3 counters: second ext segment got page 2 ($84/$85)");
        [[NSFileManager defaultManager] removeItemAtPath:xex error:NULL];
    }

    // ── Legacy: regCWindowStart = 0 means no ext classification ───
    {
        NSString *src =
            @"    .org $4000\n"
            @"    LDA #$01\n"
            @"    .org $7000\n"
            @"    LDA #$02\n";
        XAAssembler *a = [XAAssembler new];
        a.bankedMode = YES;
        a.hasSplitBanking = YES;
        a.codeBankReg = 0x82;
        a.dataBankReg = 0x83;
        a.bankWindowStart = 0x4000;
        a.bankWindowEnd   = 0x7FFF;
        a.dataWindowStart = 0x6000;
        a.dataWindowEnd   = 0x7FFF;     // legacy: full data half
        // No regCWindowStart — the ext path stays inert.

        NSArray<XASegment *> *segs =
            [a assembleSource:src filename:@"test.s"];
        NSString *xex = [NSString stringWithFormat:@"%@/pr3-legacy.xex", tmpDir];
        BOOL ok = [a writeBankedXEX:segs entryPoint:0x4000 toFile:xex];
        ASSERT_TRUE(ok, "PR3 legacy: writeBankedXEX succeeded");
        NSData *bytes = [NSData dataWithContentsOfFile:xex];
        // The $7000 segment routes through $83 (data window), not $84/$85.
        // Look for legacy data-stub: LDA #$01 / STA $83 / RTS.
        uint8_t data1[] = {0xA9, 0x01, 0x85, 0x83, 0x60};
        ASSERT_TRUE(findBytes(bytes, data1, sizeof(data1)) >= 0,
                    "PR3 legacy: $7000 segment routed through $83 (data)");
        // No $84 writes anywhere in the legacy build.
        uint8_t ext_marker[] = {0x85, 0x84};
        ASSERT_TRUE(findBytes(bytes, ext_marker, sizeof(ext_marker)) < 0,
                    "PR3 legacy: no $84 writes in stub bytes");
        [[NSFileManager defaultManager] removeItemAtPath:xex error:NULL];
    }

    return failures;
}
