// global_ptr_init.xc — a pointer-typed global's initialiser must fill the
// whole slot the backend reads.
//
// The IR carries a pointer at the target's canonical width (3 bytes on
// atarist) while the m68k backend reserves and loads 4. The backend emitted
// only the initialiser's bytes and never zero-filled the rest of the slot, so
// the NEXT symbol's first byte became part of this pointer: `u8@ nul = 0;`
// read back as $00000069 — the 'i' of a following string literal — and
// `nul == 0` was false.
//
// It only bit when the neighbouring symbol was one that doesn't force
// alignment (a string literal, not a data global), which is why the 68000 and
// 68030 builds of identical source disagreed: the CPU changes the symbol
// order, not the pointer. `str_pad` below exists to BE that neighbour.
//
// A non-zero pointer global also has to be byte-reversed on big-endian m68k;
// the scalar-int reversal never covered Ptr (its IR byteWidth is 0), so `raw`
// pins that too.
#import "Stdio.xc"

u8* nul = 0;
u8* raw = $1234;

void main()
{
    Stdio.printf("str_pad\n");             // a string literal, to neighbour the pointers
    if (nul == 0)      Stdio.printf("nul=ok\n");   else Stdio.printf("nul=BAD\n");
    if (raw == $1234)  Stdio.printf("raw=ok\n");   else Stdio.printf("raw=BAD\n");
    Stdio.printf("isnull=%d\n", nul == 0);
}
