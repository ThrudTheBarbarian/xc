// x86_signed_elem_index.xc — bug 023: a pointer stepped BACKWARDS with a signed
// narrow offset. x86-64 zero-extended the index into its scaled addressing mode,
// so -2 became 65534 and the store landed 128KB past the array (segfault). Every
// other backend was correct, which is why the rest of the corpus never caught it.
#import "Stdio.xc"

void main(void)
{
    u16 ar[5];
    ar[0] = (u16)10; ar[1] = (u16)11; ar[2] = (u16)12;
    ar[3] = (u16)13; ar[4] = (u16)14;

    u16* p = &ar[3];
    *(p - (i16)2) = (u16)$DE;      // ar[1]
    *(p - (i16)1) = (u16)$AD;      // ar[2]
    *(p + (i16)1) = (u16)$BE;      // ar[4]

    i16 back = (i16)-3;
    *(p + back) = (u16)$EF;        // ar[0], via a variable signed index

    Stdio.printf("%lu %lu %lu %lu %lu\n", (u32)ar[0], (u32)ar[1],
                 (u32)ar[2], (u32)ar[3], (u32)ar[4]);
}
