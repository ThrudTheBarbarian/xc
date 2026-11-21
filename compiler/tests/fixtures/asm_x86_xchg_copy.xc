//xtc-na: arm64,arm9,m68k,xt6502,wasm32 — uses inline x86-64 assembly
// asm_x86_xchg_copy.xc — copy propagation must leave an inline-asm body
// alone. It took the body's `mov rax, r8` for a copy, did not count the
// `xchg` as a write of r8, and rewrote the store to read r8 after the swap:
// the program printed 2 instead of 1.
#import "Stdio.xc"

i64 swapped()
    {
    i64 r = 0;
    asm {
        mov r8, 1
        mov r9, 2
        mov rax, r8
        xchg r8, r9
        mov [r], rax
    }
    return r;
    }

i32 main()
    {
    Stdio.printf("%ld\n", swapped());
    return 0;
    }
