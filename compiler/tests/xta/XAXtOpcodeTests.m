/****************************************************************************\
|* XAXtOpcodeTests.m
|*
|* Verifies xta encodes the xt CPU's added opcodes correctly
|* (docs/6502/6502-embellishments.md §§1-3), and that the per-mode
|* diagnostic catches out-of-range immediates / offsets.
|*
|* Coverage:
|*   - SP-relative loads/stores (LDA/STA/LDX/STX/LDY/STY +d,SP)
|*   - SP-relative arith (ADC/SBC/CMP +d,SP)
|*   - ADD SP, #signed8 — stack adjustment
|*   - PSH #N / PLL #N — prologue / epilogue bundles
|*   - PHX / PHY / PLX / PLY — direct push/pop of X and Y
|*   - BRA #signed8 — 65C02-style unconditional branch
|*   - SP-relative offset out of [-128, +127] → error
|*   - PSH/PLL #N out of [0, 255] → error
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAAssembler.h"

#define ASSERT_TRUE(cond, msg) \
    do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } \
         else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

#define ASSERT_BYTES(actual, expected, expectedLen, msg) do { \
    BOOL _ok = ((actual).length == (expectedLen)); \
    if (_ok) _ok = (memcmp((actual).bytes, (expected), (expectedLen)) == 0); \
    if (!_ok) { \
        fprintf(stderr, "  FAIL: %s\n    expected:", msg); \
        for (NSUInteger _i = 0; _i < (expectedLen); _i++) fprintf(stderr, " %02X", ((const uint8_t *)(expected))[_i]); \
        fprintf(stderr, "\n    actual:  "); \
        for (NSUInteger _i = 0; _i < (actual).length; _i++) fprintf(stderr, " %02X", ((const uint8_t *)(actual).bytes)[_i]); \
        fprintf(stderr, "\n"); \
        failures++; \
    } else { \
        fprintf(stderr, "  PASS: %s\n", msg); \
    } \
} while (0)

static NSData *assemble(NSString *source) {
    XAAssembler *asm_ = [[XAAssembler alloc] init];
    NSArray *segs = [asm_ assembleSource:source filename:@"test.asm"];
    if (!segs || segs.count == 0) return nil;
    return [(XASegment *)segs[0] data];
}

static NSArray<NSString *> *assembleErrors(NSString *source) {
    XAAssembler *asm_ = [[XAAssembler alloc] init];
    [asm_ assembleSource:source filename:@"test.asm"];
    return asm_.errors ?: @[];
}

int runXtOpcodeTests(void) {
    int failures = 0;
    fprintf(stderr, "\n  ── xt CPU opcodes ────────────────────────\n");

    // ── SP-relative loads / stores ────────────────────────────
    {
        // LDA +5,SP → $B2 $05
        NSData *d = assemble(@".org $2000\nLDA +5,SP\n");
        uint8_t want[] = {0xB2, 0x05};
        ASSERT_BYTES(d, want, 2, "LDA +5,SP → B2 05");
    }
    {
        // LDA -1,SP → $B2 $FF  (two's-complement -1)
        NSData *d = assemble(@".org $2000\nLDA -1,SP\n");
        uint8_t want[] = {0xB2, 0xFF};
        ASSERT_BYTES(d, want, 2, "LDA -1,SP → B2 FF");
    }
    {
        // LDA +127,SP → $B2 $7F  (max positive offset)
        NSData *d = assemble(@".org $2000\nLDA +127,SP\n");
        uint8_t want[] = {0xB2, 0x7F};
        ASSERT_BYTES(d, want, 2, "LDA +127,SP → B2 7F (max pos)");
    }
    {
        // LDA -128,SP → $B2 $80  (min negative offset)
        NSData *d = assemble(@".org $2000\nLDA -128,SP\n");
        uint8_t want[] = {0xB2, 0x80};
        ASSERT_BYTES(d, want, 2, "LDA -128,SP → B2 80 (max neg)");
    }
    {
        NSData *d = assemble(@".org $2000\nSTA +5,SP\n");
        uint8_t want[] = {0x92, 0x05};
        ASSERT_BYTES(d, want, 2, "STA +5,SP → 92 05");
    }
    {
        NSData *d = assemble(@".org $2000\nLDX +3,SP\n");
        uint8_t want[] = {0x42, 0x03};
        ASSERT_BYTES(d, want, 2, "LDX +3,SP → 42 03");
    }
    {
        NSData *d = assemble(@".org $2000\nSTX +4,SP\n");
        uint8_t want[] = {0x02, 0x04};
        ASSERT_BYTES(d, want, 2, "STX +4,SP → 02 04");
    }
    {
        NSData *d = assemble(@".org $2000\nLDY +5,SP\n");
        uint8_t want[] = {0x52, 0x05};
        ASSERT_BYTES(d, want, 2, "LDY +5,SP → 52 05");
    }
    {
        NSData *d = assemble(@".org $2000\nSTY +6,SP\n");
        uint8_t want[] = {0x12, 0x06};
        ASSERT_BYTES(d, want, 2, "STY +6,SP → 12 06");
    }
    {
        NSData *d = assemble(@".org $2000\nADC +7,SP\n");
        uint8_t want[] = {0x72, 0x07};
        ASSERT_BYTES(d, want, 2, "ADC +7,SP → 72 07");
    }
    {
        NSData *d = assemble(@".org $2000\nSBC +8,SP\n");
        uint8_t want[] = {0xF2, 0x08};
        ASSERT_BYTES(d, want, 2, "SBC +8,SP → F2 08");
    }
    {
        NSData *d = assemble(@".org $2000\nCMP +9,SP\n");
        uint8_t want[] = {0xD2, 0x09};
        ASSERT_BYTES(d, want, 2, "CMP +9,SP → D2 09");
    }

    // ── ADD SP, #imm — stack adjustment ───────────────────────
    {
        NSData *d = assemble(@".org $2000\nADD SP, #12\n");
        uint8_t want[] = {0x22, 0x0C};
        ASSERT_BYTES(d, want, 2, "ADD SP,#12 → 22 0C");
    }
    {
        NSData *d = assemble(@".org $2000\nADD SP, #-12\n");
        uint8_t want[] = {0x22, 0xF4};
        ASSERT_BYTES(d, want, 2, "ADD SP,#-12 → 22 F4 (two's complement)");
    }

    // ── PSH / PLL — prologue / epilogue ───────────────────────
    {
        NSData *d = assemble(@".org $2000\nPSH #12\n");
        uint8_t want[] = {0x32, 0x0C};
        ASSERT_BYTES(d, want, 2, "PSH #12 → 32 0C");
    }
    {
        NSData *d = assemble(@".org $2000\nPLL #12\n");
        uint8_t want[] = {0x62, 0x0C};
        ASSERT_BYTES(d, want, 2, "PLL #12 → 62 0C");
    }
    {
        NSData *d = assemble(@".org $2000\nPSH #255\n");
        uint8_t want[] = {0x32, 0xFF};
        ASSERT_BYTES(d, want, 2, "PSH #255 → 32 FF (max immediate)");
    }

    // ── Direct push/pop of X and Y ────────────────────────────
    {
        NSData *d = assemble(@".org $2000\nPHX\n");
        uint8_t want[] = {0x44};
        ASSERT_BYTES(d, want, 1, "PHX → 44");
    }
    {
        NSData *d = assemble(@".org $2000\nPHY\n");
        uint8_t want[] = {0x54};
        ASSERT_BYTES(d, want, 1, "PHY → 54");
    }
    {
        NSData *d = assemble(@".org $2000\nPLX\n");
        uint8_t want[] = {0x64};
        ASSERT_BYTES(d, want, 1, "PLX → 64");
    }
    {
        NSData *d = assemble(@".org $2000\nPLY\n");
        uint8_t want[] = {0x74};
        ASSERT_BYTES(d, want, 1, "PLY → 74 (resolved from doc duplicate)");
    }

    // ── BRA — unconditional branch ────────────────────────────
    {
        // BRA forward by 4 bytes from $2000: target $2006, offset = +4.
        // (PC after BRA opcode + operand = $2002; target - $2002 = +4.)
        NSData *d = assemble(@".org $2000\nBRA tgt\nNOP\nNOP\nNOP\nNOP\ntgt: NOP\n");
        // Expected: $80 $04 $EA $EA $EA $EA $EA  (BRA, +4, four NOPs, target NOP)
        uint8_t want[] = {0x80, 0x04, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA};
        ASSERT_BYTES(d, want, 7, "BRA tgt forward → 80 04 (offset = +4)");
    }
    {
        // BRA backward to a prior label.
        NSData *d = assemble(@".org $2000\nstart: NOP\nBRA start\n");
        // $2000: NOP ($EA), $2001: BRA start = $80 $FD  (offset = $2000 - $2003 = -3)
        uint8_t want[] = {0xEA, 0x80, 0xFD};
        ASSERT_BYTES(d, want, 3, "BRA backward → 80 FD (offset = -3)");
    }

    // ── Stack-indirect / indexed (§2b) ────────────────────────
    {
        // LDA (+5,SP),Y → $03 $05 — deref a stacked pointer.
        NSData *d = assemble(@".org $2000\nLDA (+5,SP),Y\n");
        uint8_t want[] = {0x03, 0x05};
        ASSERT_BYTES(d, want, 2, "LDA (+5,SP),Y → 03 05");
    }
    {
        // STA (+5,SP),Y → $13 $05.
        NSData *d = assemble(@".org $2000\nSTA (+5,SP),Y\n");
        uint8_t want[] = {0x13, 0x05};
        ASSERT_BYTES(d, want, 2, "STA (+5,SP),Y → 13 05");
    }
    {
        // LDA (-1,SP),Y → $03 $FF — negative offset, two's complement.
        NSData *d = assemble(@".org $2000\nLDA (-1,SP),Y\n");
        uint8_t want[] = {0x03, 0xFF};
        ASSERT_BYTES(d, want, 2, "LDA (-1,SP),Y → 03 FF");
    }
    {
        // LDA +5,SP,X → $23 $05 — indexed in-frame access.
        NSData *d = assemble(@".org $2000\nLDA +5,SP,X\n");
        uint8_t want[] = {0x23, 0x05};
        ASSERT_BYTES(d, want, 2, "LDA +5,SP,X → 23 05");
    }
    {
        // STA +5,SP,X → $33 $05.
        NSData *d = assemble(@".org $2000\nSTA +5,SP,X\n");
        uint8_t want[] = {0x33, 0x05};
        ASSERT_BYTES(d, want, 2, "STA +5,SP,X → 33 05");
    }
    {
        // LDA -1,SP,X → $23 $FF — negative offset.
        NSData *d = assemble(@".org $2000\nLDA -1,SP,X\n");
        uint8_t want[] = {0x23, 0xFF};
        ASSERT_BYTES(d, want, 2, "LDA -1,SP,X → 23 FF");
    }
    {
        // Symbolic offset, resolved in pass 2.
        NSData *d = assemble(@"N = 12\n.org $2000\nLDA (+(N + 7),SP),Y\n");
        uint8_t want[] = {0x03, 0x13};
        ASSERT_BYTES(d, want, 2, "LDA (+(N+7),SP),Y with N=12 → 03 13");
    }
    {
        // Out-of-range offset rejected on the indirect mode too.
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nLDA (+200,SP),Y\n");
        ASSERT_TRUE(errs.count > 0 && [errs[0] containsString:@"out of range"],
                    "LDA (+200,SP),Y rejected as out of range");
    }

    // ── Diagnostics: out-of-range SP-relative offset ─────────
    {
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nLDA +200,SP\n");
        ASSERT_TRUE(errs.count > 0
                    && [errs[0] containsString:@"signed-8-bit"]
                    && [errs[0] containsString:@"out of range"],
                    "LDA +200,SP rejected with signed-8-bit-out-of-range diagnostic");
    }
    {
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nLDA -200,SP\n");
        ASSERT_TRUE(errs.count > 0
                    && [errs[0] containsString:@"out of range"],
                    "LDA -200,SP rejected as out of range");
    }
    {
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nADD SP, #200\n");
        ASSERT_TRUE(errs.count > 0
                    && [errs[0] containsString:@"out of range"],
                    "ADD SP,#200 rejected as out of range");
    }
    {
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nPSH #300\n");
        ASSERT_TRUE(errs.count > 0
                    && [errs[0] containsString:@"out of range"],
                    "PSH #300 rejected as out of range");
    }
    {
        NSArray<NSString *> *errs = assembleErrors(@".org $2000\nPLL #300\n");
        ASSERT_TRUE(errs.count > 0
                    && [errs[0] containsString:@"out of range"],
                    "PLL #300 rejected as out of range");
    }

    // ── Edge case: SP-relative with a symbolic offset (resolved
    //    in pass 2; should still pass through the byte emitter). ──
    {
        NSData *d = assemble(@"N = 12\n.org $2000\nLDA +(N + 7),SP\n");
        uint8_t want[] = {0xB2, 0x13};
        ASSERT_BYTES(d, want, 2, "LDA +(N+7),SP with N=12 → B2 13 (N+7=19=$13)");
    }

    // ── End-to-end: assemble a complete PSH + SP-relative + PLL +
    //    RTS sequence and verify the byte stream. Walks the
    //    canonical xt frame setup against the §3 layout. ──
    {
        NSString *src =
            @".org $2000\n"
            @"my_func:\n"
            @"  PSH #4\n"           // allocate 4 locals + 6 saved = 10 bytes
            @"  LDA #$42\n"
            @"  STA +6,SP\n"        // write local[0]
            @"  LDA +6,SP\n"        // read it back into A
            @"  PLL #4\n"
            @"  RTS\n";
        NSData *d = assemble(src);
        uint8_t want[] = {
            0x32, 0x04,             // PSH #4
            0xA9, 0x42,             // LDA #$42
            0x92, 0x06,             // STA +6,SP
            0xB2, 0x06,             // LDA +6,SP
            0x62, 0x04,             // PLL #4
            0x60,                   // RTS
        };
        ASSERT_BYTES(d, want, sizeof(want), "complete PSH/SP-relative/PLL/RTS frame");
    }

    return failures;
}
