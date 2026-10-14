//xtc-flags: expect=sema-error
// nil_auto_refused.xc — `auto p = nil` has no type to infer: nil is a pointer
// of every type and so of none in particular. The declaration must name the
// pointer type.

#import "Stdio.xc"

void main(void)
{
    auto p = nil;                       // error: name the pointer type
    Stdio.printf("%u\n", (u32)(p == nil));
}
