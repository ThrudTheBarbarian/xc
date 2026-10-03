// A program that reaches libc — the import path, end to end. `write` is
// resolved by the loader out of libc.so, through the veneer the linker built.
// write() is the platform's own (Stdio.xc: libc's i32 write(i32, u8*, i32)).

void main(void)
    {
    u8* msg = (u8*)"imports resolved by the ported linker\n";
    write((i32)1, msg, (i32)38);
    }
