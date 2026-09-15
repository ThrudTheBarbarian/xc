// static_local_array.xc — bug 174. A function-local `static` ARRAY must have
// persistent (module-global) storage, exactly as a static scalar does: its
// contents survive across calls and a pointer returned into it stays valid.
//
// The static scalar was already backed by a global; a static array whose
// address is taken (`&buf[0]`, or a bare `buf` that decays) was ALSO pinned to
// a frame slot by the address-taken pre-scan, and that frame slot shadowed the
// global — so the array was effectively an ordinary stack local: cleared each
// call, dangling once returned.
//
// Test surface — all deterministic, no argument-aliasing:
//   T1  a static scalar counter (the control — already worked)
//   T2  a static array ACCUMULATES across calls (append one char per call)
//   T3  a pointer returned into a static array is still valid after return
//   T4  a second static array in the same function is independent

i32 printf(u8* f, ...);

// T2/T3: append c to a persistent buffer, return it.
u8* appended(u8 c)
{
    static u8 buf[32];
    static i32 n = 0;
    buf[n] = c; n = n + 1; buf[n] = (u8)0;
    return &buf[0];
}

// T4: a different static array, independent storage.
i32 sumSlots(i32 v)
{
    static i32 slots[4];
    static i32 idx = 0;
    slots[idx] = v; idx = idx + 1;
    i32 s = 0;
    for (i32 i = 0; i < idx; i = i + 1) s = s + slots[i];
    return s;
}

i32 counter(void) { static i32 n = -1; n = n + 1; return n; }

i32 main(void)
{
    // T1
    printf("counter %d %d %d\n", counter(), counter(), counter());   // 0 1 2

    // T2/T3: buffer persists and accumulates.
    appended((u8)'a');
    appended((u8)'b');
    u8* p = appended((u8)'c');
    printf("buf %s\n", p);            // "abc" — persists, pointer valid

    // T4: independent static array accumulates a running sum.
    i32 a = sumSlots(10);
    i32 b = sumSlots(20);
    i32 c = sumSlots(30);
    printf("sums %d %d %d\n", a, b, c);   // 10 30 60

    return (i32)0;
}
