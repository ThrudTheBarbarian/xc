#use Stdio

// bug 206: `p - q` — pointer DIFFERENCE. Unimplemented in both compilers: the
// reference refused it outright ("lowering: pointer - pointer not yet
// supported") and the port fell through to generic arithmetic and emitted a
// raw BYTE subtraction typed as a pointer. So one compiler rejected valid C
// and the other silently answered in the wrong unit.
//
// The result is in ELEMENTS, as C has it, so `(p + n) - p == n` for every n —
// that identity is the whole point and the thing the old behaviour violated.
// Element sizes are deliberately mixed: 1 (the no-divide path), 8, and a
// 16-byte struct, plus a negative difference.
struct Rec { double a; double b; };

Rec  gr[8];
double gd[8];
u8    gb[16];

i32 main()
{
    double* p = &gd[0];
    double* q = &gd[5];
    printf("%ld\n", (i32)(q - p));          // 5
    printf("%ld\n", (i32)(p - q));          // -5, difference is SIGNED

    Rec* r0 = &gr[0];
    Rec* r3 = &gr[3];
    printf("%ld\n", (i32)(r3 - r0));        // 3

    u8* b0 = &gb[0];
    u8* b7 = &gb[7];
    printf("%ld\n", (i32)(b7 - b0));        // 7 — element size 1, no divide

    // The identity, on each element size.
    printf("%ld\n", (i32)((p + 3) - p));    // 3
    printf("%ld\n", (i32)((r0 + 2) - r0));  // 2
    printf("%ld\n", (i32)((b0 + 9) - b0));  // 9
    return 0;
}
