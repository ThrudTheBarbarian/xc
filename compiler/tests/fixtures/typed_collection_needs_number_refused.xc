//xtc-flags: expect=sema-error
// A typed collection of primitives keeps its elements boxed in Number, so
// reading one back needs the Number class. Array.xc alone does not bring it
// in (Foundation.xc does); the reference then left the element as its box and
// the program printed nonsense, and the self-hosted compiler failed later
// with "method call on a non-class".
// Refused: a collection of 'i32' keeps its elements as Number: #import "Number.xc"
#import "Stdio.xc"
#import "Array.xc"

Array<i32>* vals(void)
{
    Array<i32>* a = new Array();
    a.add((i32)7);
    return a;
}

i32 main(void)
{
    Array<i32>* a = vals();
    u16 i = (u16)0;
    Stdio.printf("%ld\n", a.get(i));
    return 0;
}
