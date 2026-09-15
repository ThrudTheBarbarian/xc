// exit_flush.xc — bytes written through the C library's BUFFERED stdio must
// survive a normal return from main (task #30). Through a pipe musl goes
// fully buffered after its first write, so ~1 KB of this output sits in the
// buffer when main returns; a crt that leaves with a raw exit_group(2) never
// runs exit(3)'s __stdio_exit and the tail is silently lost. The corpus
// captures output through a pipe, which is exactly the failing shape.
// target=arm64: native backends only — the x86-64 sweep picks that up too,
// and x86-64 is where the in-house crt owns the exit path.
//xtc-flags: target=arm64
//xtc-na: win64 wasm32 — mingw's C printf writes CRLF in text mode, so the
//        byte oracle can never match (win64's exit path was verified
//        unaffected by hand); wasm32 has no host printf at all — and the
//        backend currently emits INVALID wasm for a bodyless C-variadic
//        call (stack imbalance at validation), filed as its own task.
i32 printf(string fmt, ...);

i32 main(void)
{
    i32 i;
    printf("first\n");
    for (i = 0; i < 200; i = i + 1) {
        printf("line %d\n", i);
    }
    printf("last\n");
    return 0;
}
