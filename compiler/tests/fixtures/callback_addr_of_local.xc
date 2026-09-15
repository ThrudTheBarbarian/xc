//xtc-flags: target=arm64
// callback_addr_of_local.xc — bug 168 (c2xc 12). Taking `&cb` on a callback
// LOCAL must give the {recv, code} pair, not the auto-zeroing slot's hidden
// link words. `&cb` word[0] used to read the null `prev` link, so a caller
// reading the recv through the address got 0. A callback (like a `weak:` slot)
// carries two link words before its payload; its ADDRESS is the payload, the
// same place reads and writes of the callback already route through.
#use Stdio
i32 dbl(i32 x) { return x * 2; }
i32 main(void)
{
    callback f i32(i32 x);
    f = &dbl;
    pointer* p = (pointer*)&f;
    // For a widened free function the pair is {recv=code, code=trampoline};
    // both words are non-null. Through the link region both would read null.
    printf("w0=%d w1=%d\n", (i32)(p[0] != (pointer)0), (i32)(p[1] != (pointer)0));
    return 0;
}
