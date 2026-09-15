// A program that reaches libc — the import path, end to end. `write` is
// resolved by the loader out of libc.so, through the veneer the linker built.
i32 write(i32 fd, u8* buf, u32 n);

void main(void)
    {
    u8* msg = (u8*)"imports resolved by the ported linker\n";
    write((i32)1, msg, (u32)38);
    }
