// double_phi.xc — a `double` carried through a PHI.
//
// A double is eight bytes in a frame slot, and a phi copy that moves four of
// them leaves the other four holding whatever the frame had. Both back ends
// that keep doubles in slots got this wrong: m68k copied the high long only,
// and arm9 lost the value entirely. Aggregates had a wide-copy path already;
// the eight-byte SCALARS were missed.
//
// Two things about how this is written, both learned the hard way:
//
//   * the VALUES matter. 1.5, 3.25 and 7.75 all have a ZERO low word, so half
//     a copy still gives the right answer and the bug is invisible. 3.1 does
//     not — it came back as 3.0999984741.
//
//   * the CHECK must not be printf. m68k's `%lf` formatter is independently
//     lossy (it prints 3.0999984741 for a plain constant with no phi in
//     sight), so a text comparison cannot tell a phi bug from a formatting
//     one. Comparing the double against its own literal needs neither the
//     formatter nor a byte order, and fails exactly when a half is lost.
#import "Stdio.xc"

// Opaque enough that the optimiser cannot fold the ternary away.
double pick(bool c) { return c ? 3.1d : 7.7d; }

// A loop-carried double: `acc` is a phi on the back edge.
double loopSum(u16 n)
{
    double acc = 1.1d;
    for (u16 i = (u16)0; i < n; i = i + (u16)1) acc = acc + 0.3d;
    return acc;
}

// Nested, so the accumulator crosses two back edges.
double loopNest(u16 n)
{
    double acc = 0.7d;
    for (u16 i = (u16)0; i < n; i = i + (u16)1)
        for (u16 j = (u16)0; j < n; j = j + (u16)1) acc = acc + 0.1d;
    return acc;
}

u32 eq(double a, double b) { return (a == b) ? (u32)1 : (u32)0; }
u32 equ(u64 a, u64 b)       { return (a == b) ? (u32)1 : (u32)0; }

i32 main(void)
{
    Stdio.printf("tern_t %ld\n", eq(pick(true),  3.1d));
    Stdio.printf("tern_f %ld\n", eq(pick(false), 7.7d));
    // Zero trips: the phi's value is the one that entered the loop, so this
    // isolates the preheader edge from the back edge.
    Stdio.printf("loop_0 %ld\n", eq(loopSum((u16)0), 1.1d));
    // One trip through each, compared against the same sum built inline.
    Stdio.printf("loop_1 %ld\n", eq(loopSum((u16)1), 1.1d + 0.3d));
    Stdio.printf("loop_4 %ld\n", eq(loopSum((u16)4), 1.1d + 0.3d + 0.3d + 0.3d + 0.3d));
    Stdio.printf("nest_0 %ld\n", eq(loopNest((u16)0), 0.7d));
    Stdio.printf("nest_2 %ld\n", eq(loopNest((u16)2), 0.7d + 0.1d + 0.1d + 0.1d + 0.1d));

    // An eight-byte value THROUGH A POINTER, which is a different path from a
    // phi and was separately wrong on m68k: the store wrote one long, so what
    // came back was not what went in. It is also how every `%lf` reaches
    // printf — the vararg buffer is written through a pointer — which is why
    // that looked like a lossy FORMATTER and was not one.
    double dbuf[2];
    double* dp = &dbuf[0];
    *dp = 3.1d;
    dbuf[1] = 7.7d;
    Stdio.printf("dptr   %ld\n", eq(*dp, 3.1d));
    Stdio.printf("darr   %ld\n", eq(dbuf[1], 7.7d));
    u64 ubuf[2];
    u64* up = &ubuf[0];
    *up = ((u64)1 << (u64)40) + (u64)12345;
    ubuf[1] = (u64)0 - (u64)1;
    Stdio.printf("uptr   %ld\n", equ(*up, ((u64)1 << (u64)40) + (u64)12345));
    Stdio.printf("uarr   %ld\n", equ(ubuf[1], (u64)0 - (u64)1));

    // And the vararg path itself, end to end.
    Stdio.printf("vararg %lf\n", 3.1d);
    return 0;
}
