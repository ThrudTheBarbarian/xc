// zerobig.xc — a large zero-initialised global (bug 642). The storage belongs
// in a zero-fill section, so the program's file stays small; the array is
// still usable end to end.
#import <Stdio.xc>
u32 big[8000000];
u32 small;
void main(void)
    {
    big[0] = 1;
    big[7999999] = 7;
    small = 2;
    Stdio.printf("%ld %ld %ld %ld\n", (i32)big[0], (i32)big[1], (i32)big[7999999], (i32)small);
    }
