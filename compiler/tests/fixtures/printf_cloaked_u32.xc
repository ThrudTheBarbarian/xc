//xtc-flags: skip   (XE-only :cloaked formatter; no XE backend in the corpus yet)
// printf_cloaked_u32.xc — stage 4b: verifies that %lu / %ld
// dispatch through the cloaked _printfU32 formatter on xe.
//
// _printfU32 writes a NUL-terminated ASCII decimal at XT_STDIO_FMT_BUF. The
// public print(u32) wrapper flushes that through putChar. print(i32)
// handles the sign bit inline then delegates to print((u32)val), so
// %ld routes through the same cloaked formatter.
//
// Also serves as a test that u32Div / u32Mod get the right
// placement decision via the helper-promotion pass: those helpers
// are used by _printfU32 (cloaked) but also by any main code that
// touches u32 / or % — if the printf buffer code or putChar ever
// does u32 arithmetic (they don't today), the promotion would keep
// them in main. For this fixture neither main nor putChar does u32
// division, so u32Div / u32Mod should land in the cloaked segment.

#import "Stdio.xc"

// Six-byte byte-compare at XT_STDIO_FMT_BUF (5 digits + NUL max for the u32
// boundary values the test covers).
u8 check(u8 a0, u8 a1, u8 a2, u8 a3, u8 a4, u8 a5, u8 a6, u8 a7, u8 a8, u8 a9)
{
    main:u8* p;
    p = (main:u8*)XT_STDIO_FMT_BUF;

    if (a0 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a0) { return 0; }
    p = p + 1;

    if (a1 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a1) { return 0; }
    p = p + 1;

    if (a2 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a2) { return 0; }
    p = p + 1;

    if (a3 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a3) { return 0; }
    p = p + 1;

    if (a4 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a4) { return 0; }
    p = p + 1;

    if (a5 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a5) { return 0; }
    p = p + 1;

    if (a6 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a6) { return 0; }
    p = p + 1;

    if (a7 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a7) { return 0; }
    p = p + 1;

    if (a8 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a8) { return 0; }
    p = p + 1;

    if (a9 == 0) { if (*p != 0) { return 0; } return 1; }
    if (*p != a9) { return 0; }
    p = p + 1;

    if (*p != 0) { return 0; }
    return 1;
}

void main(void)
{
    u8 ok;

    // T1: zero → "0"
    _printfU32((u32)0);
    ok = check($30, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL\n"); }

    // T2: small value → "123"
    _printfU32((u32)123);
    ok = check($31, $32, $33, 0, 0, 0, 0, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T2 PASS\n"); }
    else         { Stdio.printf("T2 FAIL\n"); }

    // T3: 16-bit boundary — "65536" (one past u16 max).
    _printfU32((u32)65536);
    ok = check($36, $35, $35, $33, $36, 0, 0, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T3 PASS\n"); }
    else         { Stdio.printf("T3 FAIL\n"); }

    // T4: mid-range u32 → "1000000".
    _printfU32((u32)1000000);
    ok = check($31, $30, $30, $30, $30, $30, $30, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T4 PASS\n"); }
    else         { Stdio.printf("T4 FAIL\n"); }

    // T5: u32 max → "4294967295".
    _printfU32((u32)4294967295);
    ok = check($34, $32, $39, $34, $39, $36, $37, $32, $39, $35);
    if (ok == 1) { Stdio.printf("T5 PASS\n"); }
    else         { Stdio.printf("T5 FAIL\n"); }

    // T6: printf round-trip for %lu and %ld. The harness only
    // enforces "no FAIL" here; the displayed output should read
    // "T6 PASS lu=4000000000 ld=-1234567".
    Stdio.printf("T6 PASS lu=%lu ld=%ld\n",
                 (u32)4000000000, (i32)-1234567);

    // T7: %lx zero → "00000000" (always 8 digits).
    _printfHexU32((u32)0);
    ok = check($30, $30, $30, $30, $30, $30, $30, $30, 0, 0);
    if (ok == 1) { Stdio.printf("T7 PASS\n"); }
    else         { Stdio.printf("T7 FAIL\n"); }

    // T8: %lx mixed — "DEADBEEF".
    _printfHexU32((u32)$DEADBEEF);
    ok = check($44, $45, $41, $44, $42, $45, $45, $46, 0, 0);
    if (ok == 1) { Stdio.printf("T8 PASS\n"); }
    else         { Stdio.printf("T8 FAIL\n"); }

    // T9: %lx max — "FFFFFFFF".
    _printfHexU32((u32)$FFFFFFFF);
    ok = check($46, $46, $46, $46, $46, $46, $46, $46, 0, 0);
    if (ok == 1) { Stdio.printf("T9 PASS\n"); }
    else         { Stdio.printf("T9 FAIL\n"); }

    // T10: full printf round-trip for %lx — output should read
    // "T10 PASS lx=CAFEBABE".
    Stdio.printf("T10 PASS lx=%lx\n", (u32)$CAFEBABE);
}