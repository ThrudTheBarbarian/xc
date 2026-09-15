// memory_basic.xc — verify Memory.memset / memclr / memcpy /
// memmove across boundary shapes:
//   T1-T3   memset / memclr coverage
//   T4-T7   memcpy: short / cross-boundary / pattern-roundtrip /
//           zero-length / both-aligned-page
//   T8-T11  memmove: forward (calls memcpy), backward overlap,
//           same-pointer no-op, page-spanning backward
//
// All buffers live in two u8 globals so we can probe them
// directly. The two-buffer split means memcpy regions are
// always non-overlapping; memmove tests use a single buffer
// with deliberately overlapping ranges.
//
// Memory.memset/memcpy/memmove are implemented in inline 6502
// assembly (support/generic/lib/Memory.xc) with no arm64 variant,
// so this fixture can only run on the xt6502 backend.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses the 16-bit-address Memory API (inline 6502 asm)

#import "Stdio.xc"
#import "Assert.xc"
#import "Memory.xc"

u8 buf[600];
u8 dst[600];

void fillBuf(u8 v)
{
    u16 i;
    for (i = (u16)0; i < (u16)600; i = i + (u16)1) buf[i] = v;
    return;
}

void fillDst(u8 v)
{
    u16 i;
    for (i = (u16)0; i < (u16)600; i = i + (u16)1) dst[i] = v;
    return;
}

// Stamp a recognisable pattern in `buf`: buf[i] = (u8)(i & $FF).
// Then memcpy/memmove can verify byte-for-byte fidelity by checking
// dst[i] == (u8)((sourceIndex + i) & $FF).
void stampPattern(void)
{
    u16 i;
    for (i = (u16)0; i < (u16)600; i = i + (u16)1) buf[i] = (u8)(i & (u16)$FF);
    return;
}

bool runOf(u16 from, u16 to, u8 expect)
{
    u16 i;
    for (i = from; i < to; i = i + (u16)1) {
        if (buf[i] != expect) return false;
    }
    return true;
}

bool dstRunOf(u16 from, u16 to, u8 expect)
{
    u16 i;
    for (i = from; i < to; i = i + (u16)1) {
        if (dst[i] != expect) return false;
    }
    return true;
}

// Verify dst[from..to) matches buf[srcOff..srcOff+(to-from)).
bool dstMatchesBuf(u16 from, u16 to, u16 srcOff)
{
    u16 i;
    for (i = from; i < to; i = i + (u16)1) {
        if (dst[i] != buf[srcOff + (i - from)]) return false;
    }
    return true;
}

// Verify buf[from..to) matches the i&$FF pattern shifted by
// srcOffsetAtFrom — i.e. buf[from + j] == (u8)((srcOffsetAtFrom + j) & $FF)
// for j in [0, to-from). Used to check memmove backward correctness.
bool bufMatchesShiftedPattern(u16 from, u16 to, u16 srcOffsetAtFrom)
{
    u16 i;
    for (i = from; i < to; i = i + (u16)1) {
        u16 expected = srcOffsetAtFrom + (i - from);
        if (buf[i] != (u8)(expected & (u16)$FF)) return false;
    }
    return true;
}

void main(void)
{
    Assert.reset();

    u16 bufBase = (u16)&buf[0];
    u16 dstBase = (u16)&dst[0];

    // ── T1: short memclr within a single page ─────────────
    fillBuf((u8)$AA);
    Memory.memclr(bufBase + (u16)100, (u16)10);
    Assert.isTrue(runOf((u16)0, (u16)100, (u8)$AA));      // T1a
    Assert.isTrue(runOf((u16)100, (u16)110, (u8)0));      // T1b
    Assert.isTrue(runOf((u16)110, (u16)600, (u8)$AA));    // T1c

    // ── T2: cross-boundary memclr (lead + tail) ──────────
    fillBuf((u8)$BB);
    Memory.memclr(bufBase + (u16)50, (u16)300);
    Assert.isTrue(runOf((u16)0, (u16)50, (u8)$BB));       // T2a
    Assert.isTrue(runOf((u16)50, (u16)350, (u8)0));       // T2b
    Assert.isTrue(runOf((u16)350, (u16)600, (u8)$BB));    // T2c

    // ── T3: memset with non-zero value + zero-length no-op
    fillBuf((u8)$00);
    Memory.memset(bufBase + (u16)200, (u8)$5A, (u16)50);
    Assert.isTrue(runOf((u16)0, (u16)200, (u8)0));        // T3a
    Assert.isTrue(runOf((u16)200, (u16)250, (u8)$5A));    // T3b
    Assert.isTrue(runOf((u16)250, (u16)600, (u8)0));      // T3c
    fillBuf((u8)$77);
    Memory.memclr(bufBase + (u16)100, (u16)0);
    Assert.isTrue(runOf((u16)0, (u16)600, (u8)$77));      // T3d

    // ── T4: memcpy short within-page ──────────────────────
    stampPattern();
    fillDst((u8)$EE);
    Memory.memcpy(dstBase + (u16)0, bufBase + (u16)0, (u16)10);
    Assert.isTrue(dstMatchesBuf((u16)0, (u16)10, (u16)0));  // T4a
    Assert.isTrue(dstRunOf((u16)10, (u16)600, (u8)$EE));    // T4b — beyond not touched

    // ── T5: memcpy spanning a page boundary ───────────────
    stampPattern();
    fillDst((u8)$DD);
    Memory.memcpy(dstBase + (u16)50, bufBase + (u16)50, (u16)300);
    Assert.isTrue(dstRunOf((u16)0, (u16)50, (u8)$DD));      // T5a
    Assert.isTrue(dstMatchesBuf((u16)50, (u16)350, (u16)50)); // T5b
    Assert.isTrue(dstRunOf((u16)350, (u16)600, (u8)$DD));   // T5c

    // ── T6: memcpy zero-length is a no-op ────────────────
    fillDst((u8)$33);
    Memory.memcpy(dstBase + (u16)100, bufBase + (u16)0, (u16)0);
    Assert.isTrue(dstRunOf((u16)0, (u16)600, (u8)$33));    // T6

    // ── T7: memcpy at deliberately misaligned offsets ────
    // Picks src + dst with low bytes that cannot both be 0
    // simultaneously, forcing the simple indirect-Y path
    // even when it might happen to align by coincidence.
    stampPattern();
    fillDst((u8)$CC);
    Memory.memcpy(dstBase + (u16)17, bufBase + (u16)33, (u16)200);
    Assert.isTrue(dstRunOf((u16)0, (u16)17, (u8)$CC));     // T7a
    Assert.isTrue(dstMatchesBuf((u16)17, (u16)217, (u16)33)); // T7b
    Assert.isTrue(dstRunOf((u16)217, (u16)600, (u8)$CC));  // T7c

    // ── T8: memmove forward (dst < src) — defers to memcpy
    stampPattern();
    Memory.memmove(bufBase + (u16)0, bufBase + (u16)100, (u16)50);
    // Now buf[0..49] should hold the original pattern bytes 100..149.
    Assert.isTrue(bufMatchesShiftedPattern((u16)0, (u16)50, (u16)100)); // T8

    // ── T9: memmove backward (dst > src, overlap) ────────
    // Shift bytes [0..199) forward by 50 → bytes now at [50..249).
    // Forward memcpy would clobber buf[50..199] before reading them;
    // memmove must walk backward.
    stampPattern();
    Memory.memmove(bufBase + (u16)50, bufBase + (u16)0, (u16)200);
    Assert.isTrue(bufMatchesShiftedPattern((u16)50, (u16)250, (u16)0)); // T9

    // ── T10: memmove same-pointer is a no-op ─────────────
    stampPattern();
    Memory.memmove(bufBase + (u16)10, bufBase + (u16)10, (u16)100);
    Assert.isTrue(bufMatchesShiftedPattern((u16)0, (u16)600, (u16)0)); // T10

    // ── T11: memmove backward spanning a page (>256 bytes)
    stampPattern();
    Memory.memmove(bufBase + (u16)100, bufBase + (u16)0, (u16)400);
    Assert.isTrue(bufMatchesShiftedPattern((u16)100, (u16)500, (u16)0)); // T11

    Assert.summary();
    return;
}
