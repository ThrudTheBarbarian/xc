// printf_unboxed_element.xc — a typed collection's element passed to printf.
//
// An element of an Array<i32> read in a vararg slot is unboxed to its i32, and
// a literal format's conversion is fitted to the argument. The fit used to see
// the box instead (Object*), so `%ld` stayed `%ld` and a 32-bit element went
// through a 64-bit conversion: -5 printed as 4294967291.

#import "Foundation.xc"
#import "Stdio.xc"

Array<i32>* vals(void)
{
    Array<i32>* a = new Array();
    a.add((i32)-5);
    a.add((i32)2000000000);
    a.add((i32)-2147483647);
    return a;
}

i32 main(void)
{
    Array<i32>* a = vals();
    u16 i = (u16)0;
    Stdio.printf("%ld\n", a.get(i));
    i = (u16)1;
    Stdio.printf("%ld\n", a.get(i));
    i = (u16)2;
    Stdio.printf("%d\n", a.get(i));
    return 0;
}
