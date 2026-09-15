//xtc-flags: target=arm64
// tentative_global_dup.xc — bug 36. An uninitialised file-scope global is a C
// TENTATIVE definition; repeats of one name (here two `u32 gDup;`, standing in
// for the two files a.xc/b.xc that #import merged into one unit) must collapse
// to a SINGLE storage slot. The port emitted one symbol per declaration, so on
// x86_64 the assembler saw two `gDup:` defs and refused the link ("symbol
// defined twice"); arm64 merged them as common and hid it. Now deduped to the
// first, matching the reference: the setter writes 42, the reader sees 42.
i32 printf(u8* f, ...);
u32 gDup;
u32 gDup;
void setit(u32 v) { gDup = v; }
i32 main(void) { setit((u32)42); printf("%u\n", gDup); return 0; }
