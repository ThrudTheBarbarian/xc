// class_array_ivar_array.xc — an array ivar of an element of an inline
// class array (`arr[k].data[i]`), read and written. The element is an
// instance lvalue, so the field is at the element's address; the reference
// used to load a pointer out of the element and write through it (bug 538).
#import "Stdio.xc"
class BigD
    {
    u16 tag;
    u16 data[8];
    }
i32 main(void)
{
    BigD* arr = new BigD[3];
    for (u16 k = (u16)0; k < (u16)3; k = k + (u16)1)
        for (u16 i = (u16)0; i < (u16)8; i = i + (u16)1)
            arr[k].data[i] = k * (u16)10 + i;
    u32 sum = (u32)0;
    for (u16 k = (u16)0; k < (u16)3; k = k + (u16)1)
        for (u16 i = (u16)0; i < (u16)8; i = i + (u16)1)
            sum = sum + (u32)arr[k].data[i];
    Stdio.printf("sum %lu\n", sum);
    return 0;
}
