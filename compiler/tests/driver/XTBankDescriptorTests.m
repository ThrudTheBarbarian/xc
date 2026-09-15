/****************************************************************************\
|* XTBankDescriptorTests.m
|*
|* Unit tests for PR0 of the xt-extended-RAM track:
|*   — banks[] is populated for split-bank xt layouts (one code +
|*     one data entry, both 8-bit selectors)
|*   — banks[] grows a third entry when extended-banking fields are set
|*   — 16-bit selector flag (regAddrHi != 0) and pageCount math
|*   — codeRegionSpan / dataRegionSpan / regCRegionSpan defaults
\****************************************************************************/

#import <Foundation/Foundation.h>
#include <unistd.h>          // getpid() — Apple's Foundation drags this in
                             // transitively, GNUstep's does not, so on Linux
                             // the implicit declaration is a hard error.
#import "XTMemoryModel.h"
#import "XTBankDescriptor.h"
#import "XTLinkerScriptParser.h"

#define ASSERT_TRUE(cond, msg) \
    do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

#define ASSERT_EQ(lhs, rhs, msg) \
    do { if ((NSInteger)(lhs) != (NSInteger)(rhs)) { \
             fprintf(stderr, "  FAIL: %s (%ld != %ld)\n", msg, \
                     (long)(lhs), (long)(rhs)); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

int runBankDescriptorTests(void) {
    int failures = 0;

    // ── Split-bank xt layout: banks[] has code + data ─────────────
    {
        XTMemoryModel *m = [XTMemoryModel new];
        m.hasBanking = YES;
        m.hasSplitBanking = YES;
        m.codeWindowStart = 0x4000;
        m.codeWindowEnd   = 0x5FFF;
        m.codeBankReg     = 0x82;
        m.dataWindowStart = 0x6000;
        m.dataWindowEnd   = 0x7FFF;
        m.dataBankReg     = 0x83;
        [m deriveBackwardCompatFields];

        ASSERT_EQ(m.banks.count, 2, "Split xt: banks[] has 2 entries");
        ASSERT_EQ(m.banks[0].kind, XTBankKindCode, "Split xt: entry 0 is code");
        ASSERT_EQ(m.banks[0].regAddrLo, 0x82, "Split xt: code reg = $82");
        ASSERT_EQ(m.banks[0].regAddrHi, 0, "Split xt: code 8-bit selector");
        ASSERT_EQ(m.banks[0].pageSize, 0x2000, "Split xt: code page = 8 KB");
        ASSERT_EQ(m.banks[0].regionSpan, 0x200000ULL,
                  "Split xt: code region default = 2 MB");
        ASSERT_EQ(m.banks[0].pageCount, 256, "Split xt: code 256 pages");
        ASSERT_TRUE(!m.banks[0].is16Bit, "Split xt: code not 16-bit");

        ASSERT_EQ(m.banks[1].kind, XTBankKindData, "Split xt: entry 1 is data");
        ASSERT_EQ(m.banks[1].regAddrLo, 0x83, "Split xt: data reg = $83");
        ASSERT_EQ(m.banks[1].pageSize, 0x2000, "Split xt: data page = 8 KB");
        ASSERT_EQ(m.banks[1].regionSpan, 0x200000ULL,
                  "Split xt: data region default = 2 MB");
    }

    // ── xt-extended: 16-bit $84/$85 for region C ──────────────────
    {
        XTMemoryModel *m = [XTMemoryModel new];
        m.hasBanking = YES;
        m.hasSplitBanking = YES;
        m.codeWindowStart = 0x4000;
        m.codeWindowEnd   = 0x5FFF;
        m.codeBankReg     = 0x82;
        m.dataWindowStart = 0x6000;
        m.dataWindowEnd   = 0x6FFF;     // 4 KB now
        m.dataBankReg     = 0x83;

        m.hasRegionCBanking = YES;
        m.regCWindowStart = 0x7000;
        m.regCWindowEnd   = 0x7FFF;
        m.regCPageSize    = 0x1000;
        m.regCBankRegLo   = 0x84;
        m.regCBankRegHi   = 0x85;        // 16-bit
        m.regCRegionSpan  = 0x500000ULL; // 5 MB (8 MB HyperRAM default)

        [m deriveBackwardCompatFields];

        ASSERT_EQ(m.banks.count, 3, "xt-ext: banks[] has 3 entries");
        ASSERT_EQ(m.banks[2].kind, XTBankKindData, "xt-ext: ext is data-typed");
        ASSERT_EQ(m.banks[2].regAddrLo, 0x84, "xt-ext: ext reg lo = $84");
        ASSERT_EQ(m.banks[2].regAddrHi, 0x85, "xt-ext: ext reg hi = $85");
        ASSERT_TRUE(m.banks[2].is16Bit, "xt-ext: ext is 16-bit");
        ASSERT_EQ(m.banks[2].pageSize, 0x1000, "xt-ext: ext page = 4 KB");
        ASSERT_EQ(m.banks[2].regionSpan, 0x500000ULL,
                  "xt-ext: ext region = 5 MB");
        ASSERT_EQ(m.banks[2].pageCount, 1280,
                  "xt-ext: ext 1280 pages (5 MB / 4 KB)");
    }

    // ── Scaling: 16 MB HyperRAM → 13 MB region C, 3328 pages ──────
    {
        XTMemoryModel *m = [XTMemoryModel new];
        m.hasBanking = YES;
        m.hasSplitBanking = YES;
        m.codeBankReg = 0x82;
        m.dataBankReg = 0x83;
        m.codeWindowStart = 0x4000; m.codeWindowEnd = 0x5FFF;
        m.dataWindowStart = 0x6000; m.dataWindowEnd = 0x6FFF;

        m.hasRegionCBanking = YES;
        m.regCWindowStart = 0x7000;
        m.regCWindowEnd   = 0x7FFF;
        m.regCPageSize    = 0x1000;
        m.regCBankRegLo   = 0x84;
        m.regCBankRegHi   = 0x85;
        m.regCRegionSpan  = 0xD00000ULL; // 13 MB (16 MB HyperRAM)

        [m deriveBackwardCompatFields];

        ASSERT_EQ(m.banks[2].pageCount, 3328,
                  "16 MB HyperRAM: ext has 3328 pages");
    }

    // ── 8-bit extended selector ───────────────────────────────────
    {
        XTMemoryModel *m = [XTMemoryModel new];
        m.hasBanking = YES;
        m.hasSplitBanking = YES;
        m.codeBankReg = 0x82;
        m.dataBankReg = 0x83;
        m.codeWindowStart = 0x4000; m.codeWindowEnd = 0x5FFF;
        m.dataWindowStart = 0x6000; m.dataWindowEnd = 0x6FFF;

        m.hasRegionCBanking = YES;
        m.regCWindowStart = 0x7000;
        m.regCWindowEnd   = 0x7FFF;
        m.regCPageSize    = 0x1000;
        m.regCBankRegLo   = 0x84;
        m.regCBankRegHi   = 0;         // 8-bit
        // No regCRegionSpan — exercises the 8-bit default
        [m deriveBackwardCompatFields];

        ASSERT_TRUE(!m.banks[2].is16Bit, "8-bit ext: not 16-bit");
        ASSERT_EQ(m.banks[2].regionSpan, 0x100000ULL,
                  "8-bit ext: default span = pageSize × 256 (1 MB)");
    }

    // ── Flat layout: banks[] is nil ───────────────────────────────
    {
        XTMemoryModel *m = [XTMemoryModel new];
        m.hasBanking = NO;
        [m deriveBackwardCompatFields];
        ASSERT_TRUE(m.banks == nil, "Flat layout: banks[] is nil");
    }

    // ── Shipped xt.lnk: the single-window xt model ───────────────
    // xt is one 16 KB code-bank window at $6000-$9FFF with the bank
    // selectors relocated out of ZP to $D5C0 (code) / $D5C1 (data).
    // The earlier three-window split-bank + region-C model is retired.
    {
        // Resolve via /opt/xtc — same path the driver uses when
        // -m xt is passed at the CLI. Skip the test if /opt/xtc
        // isn't installed (CI without `make` having run).
        NSString *path = @"/opt/xtc/support/xt6502/layouts/xt.lnk";
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSError *err = nil;
            XTMemoryModel *m = [XTLinkerScriptParser parseFile:path
                                                         error:&err];
            ASSERT_TRUE(m != nil, "xt.lnk parses");
            ASSERT_TRUE(m.hasBanking, "xt.lnk has banking");
            ASSERT_TRUE(!m.hasSplitBanking, "xt.lnk is single-window (not split)");
            ASSERT_TRUE(!m.hasRegionCBanking, "xt.lnk has no region C");
            ASSERT_EQ(m.bankWindowStart, 0x6000, "code window start");
            ASSERT_EQ(m.bankWindowEnd,   0x9FFF, "code window end (16 KB)");
            ASSERT_EQ(m.bankPageSize,    0x4000, "code page = 16 KB");
            ASSERT_EQ(m.codeBankReg,     0xD5C0, "code bank reg = $D5C0");
            ASSERT_EQ(m.dataBankReg,     0xD5C1, "data bank reg = $D5C1");
        }
    }

    // ── Parser: synthetic .lnk with region C ──────────────────────
    {
        NSString *src = @""
            "[zp]\n"
            "sp      = $89-$8A\n"
            "tmp     = $8B-$8C\n"
            "hp      = $8D-$8E\n"
            "bankReg = $82-$85\n"
            "vars    = $8F-$9F, $C0-$FF\n"
            "runtime = $B0-$BF\n"
            "[memory]\n"
            "system  = $2000-$3FFF\n"
            "main    = $A000-$BFFF\n"
            "screen  = $8000-$9FFF\n"
            "[banking]\n"
            "codeWindow    = $4000-$5FFF\n"
            "codeReg       = $82\n"
            "codeRegion    = $200000\n"
            "dataWindow    = $6000-$6FFF\n"
            "dataReg       = $83\n"
            "dataRegion    = $100000\n"
            "pageSize      = $1000\n"
            "regCWindow    = $7000-$7FFF\n"
            "regCPageSize  = $1000\n"
            "regCReg       = $84-$85\n"
            "regCRegion    = $500000\n"
            "[entry]\n"
            "address = $2000\n"
            "[startup]\n"
            "file    = xt.asm\n";
        NSString *tmp = [NSString stringWithFormat:@"/tmp/xtc-pr0-test-%d.lnk",
                                                    (int)getpid()];
        [src writeToFile:tmp atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
        NSError *parseErr = nil;
        XTMemoryModel *m = [XTLinkerScriptParser parseFile:tmp
                                                     error:&parseErr];
        ASSERT_TRUE(m != nil, "Parser: region-C .lnk parses");
        ASSERT_TRUE(m.hasRegionCBanking,
                    "Parser: hasRegionCBanking set from regCWindow");
        ASSERT_EQ(m.regCWindowStart, 0x7000, "Parser: regCWindow start");
        ASSERT_EQ(m.regCWindowEnd,   0x7FFF, "Parser: regCWindow end");
        ASSERT_EQ(m.regCPageSize,    0x1000, "Parser: regCPageSize");
        ASSERT_EQ(m.regCBankRegLo,   0x84, "Parser: regCReg lo from $84-$85");
        ASSERT_EQ(m.regCBankRegHi,   0x85, "Parser: regCReg hi from $84-$85");
        ASSERT_EQ(m.regCRegionSpan,  0x500000ULL, "Parser: regCRegion = 5 MB");
        ASSERT_EQ(m.codeRegionSpan, 0x200000ULL, "Parser: codeRegion = 2 MB");
        ASSERT_EQ(m.dataRegionSpan, 0x100000ULL, "Parser: dataRegion = 1 MB");
        ASSERT_EQ(m.banks.count, 3, "Parser: banks[] has 3 entries");
        ASSERT_TRUE(m.banks[2].is16Bit, "Parser: third bank is 16-bit");
        ASSERT_EQ(m.banks[2].pageCount, 1280,
                  "Parser: third bank has 1280 pages (5 MB / 4 KB)");

        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    }

    return failures;
}
