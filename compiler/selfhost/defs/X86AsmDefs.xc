// X86AsmDefs.xc — the constants of X86Asm.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define X86FIX_REL32 0
#define X86FIX_PC32 1
#define X86FIX_ABS64 2
#define X86FIX_PC32DATA 3 // a PC-relative slot in DATA — musl's vfprintf
#define X86FIX_GOTLOAD 4  // [REX_]GOTPCRELX: a RELAXABLE GOT load. When the
#define X86FIX_GOTREF 5   // plain GOTPCREL: NOT relaxable, because the slot
#define X86FIX_TPOFF32 6  // local-exec TLS: the addend IS the final
#define OP_NONE 0
#define OP_REG 1
#define OP_MEM 2
#define OP_IMM 3
#define XK_SIZE 99
