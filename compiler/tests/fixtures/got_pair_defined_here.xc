//xtc-flags: target=arm64
//xtc-na: x86_64,win64,arm9,m68k,xt6502,wasm32 — arm64's GOT pair
// got_pair_defined_here.xc — the address of a function declared without a
// body is taken through the GOT (`adrp x,f@GOTPAGE; ldr x,[x,f@GOTPAGEOFF]`).
// When the linked image itself defines f (here the runtime's lock pair), the
// linker relaxes the pair to f's own address, the load becoming an add, as
// ld64 does. Left alone, the load read a word of code as the address (Mach-O)
// or was refused for its alignment (ELF).
#import "Stdio.xc"
typedef void fn_t(void);
void _xt_rt_lock(void);
void _xt_rt_unlock(void);
void call(fn_t* f) { f(); }
i32 main(void)
    {
    call(&_xt_rt_lock);
    call(&_xt_rt_unlock);
    Stdio.printf("locked and unlocked through the pointers\n");
    return 0;
    }
