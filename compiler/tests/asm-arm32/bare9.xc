// No libc, no heap, no ARC: a program that reaches the OS itself. That is what
// makes it linkable by a linker which takes exactly one object.
//
// The syscall number goes in r7 and SYS_write is 0x303 — written `movw` because
// a bare `mov` immediate is an 8-bit value rotated, and 0x303 is not one. (And
// in DECIMAL because the compiler's inline-asm path re-spells the body token by
// token, which splits `0x303` into `0 x303`.)
u32 sysWrite(u32 fd, u8* buf, u32 len)
    {
    asm {
        movw r7, #771
        ldr r0, [sp, #0]
        ldr r1, [sp, #4]
        ldr r2, [sp, #8]
        svc #1
    }
    return (u32)0;
    }

void main(void)
    {
    u8* msg = (u8*)"linked by the ported linker\n";
    sysWrite((u32)1, msg, (u32)28);
    }
