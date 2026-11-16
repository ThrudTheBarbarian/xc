//xtc-na: arm9,m68k,xt6502,x86_64,win64 — uses inline arm64 assembly
// asm_reads_self.xc — inline asm that reads `__self` and a local. Nothing
// else in the method reads self, so at -O2 its parameter store was the only
// write to that slot, and the spill peephole deleted it as never loaded: the
// asm's own `[ sp, #16 ]` is not a load it counts. The method returned 0.
#import "Stdio.xc"

class K
    {
    i64 v;
    i64 peek()
        {
        i64 r = 0;
        asm {
            ldr x9, [__self]
            ldr x9, [x9, #_ivar_K_v]
            str x9, [r]
        }
        return r;
        }
    }

i32 main()
    {
    K* k = new K;
    k.v = 42;
    Stdio.printf("%ld\n", k.peek());
    return 0;
    }
