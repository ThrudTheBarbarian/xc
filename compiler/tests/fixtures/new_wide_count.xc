#use Stdio

// bug 38: `new T[n]` with a count wider than the target's word. The runtime
// takes `unsigned long count` — 8 bytes on a 64-bit host, 4 on wasm32 — and a
// u64 count was passed untruncated, so the wasm module failed validation with
// "call[0] expected type i32, found local.get of type i64". Native never
// noticed, because a u64 count already fits its word.
//
// It matters for converted C: malloc takes size_t = u64, so every C library
// that allocates lands here the moment it is built for wasm32.
i32 take(u64 n)
{
    u8* b = new u8[n];
    if (b == (u8*)0) return -1;
    b[0] = (u8)$DE;
    b[(i32)n - 1] = (u8)$AD;
    i32 r = (i32)b[0] + (i32)b[(i32)n - 1];
    delete b;
    return r;
}

i32 main()
{
    printf("%ld\n", take((u64)16));
    printf("%ld\n", take((u64)4));
    return 0;
}
