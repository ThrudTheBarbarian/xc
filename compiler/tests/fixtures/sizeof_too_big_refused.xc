//xtc-flags: expect=sema-error
// sizeof is a u16, so the size of anything over 65535 bytes cannot be its
// value: it would wrap (this array's would read 0). The compiler refuses it,
// naming the size; for an array, multiply its count by sizeof of one element
// (bug 615).
#import "Stdio.xc"
u8 img[1048576];
i32 main(void)
{
    Stdio.printf("%u\n", (u32)sizeof(img));
    return 0;
}
