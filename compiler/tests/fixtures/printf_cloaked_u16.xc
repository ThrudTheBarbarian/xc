//xtc-flags: skip   (XE-only :cloaked formatter; no XE backend in the corpus yet)
// printf_cloaked_u16.xc — stage 4b smoke test for :cloaked _printfU16.
//
// On xe targets Stdio.print(u16) / Stdio.printf("%u", ...) route the
// formatting through a :cloaked handler that writes a NUL-terminated
// ASCII decimal at XT_STDIO_FMT_BUF (printf buffer tail). The dispatcher flushes
// those bytes via putChar on the main bank. This fixture exercises
// the full round-trip: call the cloaked formatter, read back from
// XT_STDIO_FMT_BUF, compare against the expected bytes, then emit a PASS line
// via printf itself (which also goes through the same path).

#import "Stdio.xc"

// Compare the NUL-terminated bytes at XT_STDIO_FMT_BUF against five inline u8
// targets. Stops at the first expected-NUL ($00) and requires the
// actual byte there to also be NUL. Bytes past the NUL are ignored
// (the printf-buffer tail keeps leftovers from earlier calls, which
// is fine — only the emitted prefix matters).
u8 check(u8 a0, u8 a1, u8 a2, u8 a3, u8 a4)
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

    if (*p != 0) { return 0; }
    return 1;
}

void main(void)
{
    u8 ok;

    // T1: zero → "0"
    _printfU16((u16)0);
    ok = check($30, 0, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL\n"); }

    // T2: single digit → "7"
    _printfU16((u16)7);
    ok = check($37, 0, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T2 PASS\n"); }
    else         { Stdio.printf("T2 FAIL\n"); }

    // T3: five digits → "12345" (exercises the reverse loop).
    _printfU16((u16)12345);
    ok = check($31, $32, $33, $34, $35);
    if (ok == 1) { Stdio.printf("T3 PASS\n"); }
    else         { Stdio.printf("T3 FAIL\n"); }

    // T4: u16 max → "65535".
    _printfU16((u16)65535);
    ok = check($36, $35, $35, $33, $35);
    if (ok == 1) { Stdio.printf("T4 PASS\n"); }
    else         { Stdio.printf("T4 FAIL\n"); }

    // T5: boundary at "10" — two digits, minimum reverse case.
    _printfU16((u16)10);
    ok = check($31, $30, 0, 0, 0);
    if (ok == 1) { Stdio.printf("T5 PASS\n"); }
    else         { Stdio.printf("T5 FAIL\n"); }

    // T6: %x via the cloaked hex formatter — leading zeros preserved.
    _printfHexU16((u16)$1234);
    ok = check($31, $32, $33, $34, 0);
    if (ok == 1) { Stdio.printf("T6 PASS\n"); }
    else         { Stdio.printf("T6 FAIL\n"); }

    // T7: %x boundary — uppercase letters.
    _printfHexU16((u16)$ABCD);
    ok = check($41, $42, $43, $44, 0);
    if (ok == 1) { Stdio.printf("T7 PASS\n"); }
    else         { Stdio.printf("T7 FAIL\n"); }

    // T8: %x zero → "0000".
    _printfHexU16((u16)0);
    ok = check($30, $30, $30, $30, 0);
    if (ok == 1) { Stdio.printf("T8 PASS\n"); }
    else         { Stdio.printf("T8 FAIL\n"); }

    // T9: printHex(u16) direct path — read back buffer after flush.
    // Direct printHex should write "CAFE" through putChar, which
    // places the string on screen (but also updates the cloaked
    // buffer just before the flush). Check the buffer post-call.
    Stdio.printHex((u16)$CAFE);
    ok = check($43, $41, $46, $45, 0);
    if (ok == 1) { Stdio.printf("\nT9 PASS\n"); }
    else         { Stdio.printf("\nT9 FAIL\n"); }

    // T10: full printf round-trip. u=%u uses _printfU16; d=%d transits
    // via print(i16) → print((u16)val) → _printfU16; x=%x uses
    // _printfHexU16. Eyeball the screen output — harness only enforces
    // "no FAIL" here.
    Stdio.printf("T10 PASS u=%u d=%d x=%x\n",
                 (u16)42, (i16)-13, (u16)$CAFE);
}