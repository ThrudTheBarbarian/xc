// array_string_init — a string literal initialising an array of bytes is the
// list of its bytes and a NUL, as C reads it, for a sized or an unsized
// array, at file scope or in a function. It used to store the POINTER's
// bytes into the array (both compilers), so Base64.xc computed its alphabet
// element by element instead.
#import "Stdio.xc"

u8 alpha[8] = "ABCDEFG";
u8 unsized[] = "hello";
i8 signed_[4] = "xyz";

i32 main(void)
{
    u8 local[6] = "ab\ncd";
    Stdio.printf("%c %c %d\n", alpha[0], alpha[6], (i32)alpha[7]);
    Stdio.printf("%d %c%c\n", (i32)sizeof(unsized), unsized[0], unsized[4]);
    Stdio.printf("%d %d\n", (i32)signed_[2], (i32)signed_[3]);
    Stdio.printf("%d %c %d\n", (i32)local[2], local[3], (i32)local[5]);
    return 0;
}
