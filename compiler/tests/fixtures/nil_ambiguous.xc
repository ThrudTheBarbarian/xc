//xtc-flags: expect=sema-error
// nil_ambiguous.xc — nil fits every pointer parameter alike, so a call that
// could go to two pointer overloads is ambiguous: "Call to 'g(nil)' is
// ambiguous among 2 overloads". A cast, (Node*)nil, picks one.

#import "Stdio.xc"

class Node
{
    u32 _v;
}

u32 g(Node* n) { return (u32)1; }
u32 g(u8* p)   { return (u32)2; }

void main(void)
{
    Stdio.printf("%u\n", g(nil));           // error: ambiguous
    Stdio.printf("%u\n", g((Node*)nil));    // fine
}
