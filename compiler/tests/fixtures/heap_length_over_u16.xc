//xtc-flags: target=arm64
// `.length` must carry the whole element count, not its low 16 bits. It was
// typed u16 in all THREE lowering paths, so any array of more than 65535
// elements reported `count & 0xFFFF` — 120000 read back as 54464. The
// allocation itself was always right; the runtime header holds the true count
// and the header-read path fetched it and then truncated it on return.
// docs/bugs/234.
//
// One case per path: a declared fixed-size array (compile-time constant), a
// heap array whose literal count is recorded at declaration, and a heap array
// whose count is only known at run time (the `_xtc_count` header read).
// target=arm64: the xt6502 word is 16 bits and its primitive-array allocator
// stores no count at all — that target keeps the compile-time diagnostic.
#use Stdio

u32 runtimeCount(void) { return (u32)120000; }

u8 declared[70000];

i32 main(void)
{
    // 1 — fixed-size declared array, folded at compile time.
    Stdio.printf("declared=%ld\n", (u32)declared.length);

    // 2 — heap array with a literal count, recorded at declaration.
    u32* lit = new u32[120000];
    Stdio.printf("literal=%ld\n", (u32)lit.length);

    // 3 — heap array with a run-time count: a real allocation-header read.
    u32 n = runtimeCount();
    u32* dyn = new u32[n];
    Stdio.printf("runtime=%ld\n", (u32)dyn.length);

    // The elements really are there — the allocation was never the bug, so a
    // fix that shrank the array to match the truncated length would be wrong.
    dyn[n - (u32)1] = (u32)$DEC0DE;
    Stdio.printf("last=%lx\n", dyn[dyn.length - (u32)1]);

    delete lit;
    delete dyn;
    return 0;
}
