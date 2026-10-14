// nil_overload.xc — a nil argument chooses a pointer overload.
//
// nil is the null pointer of any pointer type and nothing else, so among
// overloads it matches the pointer parameter and never the integer one,
// whatever width that integer has. Two pointer overloads tie, which is an
// ambiguous call (nil_ambiguous); `auto` cannot take nil's type
// (nil_auto_refused).

#import "Stdio.xc"

class Node
{
    u32 _v;
}

u32 f(Node* n)  { return (u32)1; }
u32 f(u32 x)    { return (u32)2; }
u32 g(u8 x)     { return (u32)3; }      // a u8, nil's carrier width: still not it
u32 g(string s) { return (u32)4; }
u32 h(i64 x)    { return (u32)5; }
u32 h(pointer p) { return (u32)6; }

void main(void)
{
    Stdio.printf("%u %u %u\n", f(nil), g(nil), h(nil));
}
