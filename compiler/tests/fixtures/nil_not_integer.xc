//xtc-flags: expect=sema-error
// nil_not_integer.xc — `nil` is a pointer and nothing else.
//
// Each line below hands nil to something that is not a pointer: a u32
// declaration, a u32 assignment, an i32 return and a u32 parameter. Every one
// is "nil is a pointer: it cannot be a '<type>'". The literal 0 would be
// accepted in all four places; that is what nil is for.

#import "Stdio.xc"

void take(u32 n) { Stdio.printf("%u\n", n); }

i32 give(void)
{
    return nil;                 // error: an i32 return
}

void main(void)
{
    u32 n = nil;                // error: a u32 declaration
    n = nil;                    // error: a u32 assignment
    take(nil);                  // error: a u32 parameter
    Stdio.printf("%d %u\n", give(), n);
}
