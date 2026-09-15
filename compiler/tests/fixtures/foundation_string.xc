// foundation_string.xc — String.xc smoke + correctness tests.
//
//   T1   length() returns the C-string length.
//   T2   charAt indexes individual bytes.
//   T3   cString round-trips through %s.
//   T4   equals — same bytes, same length.
//   T5   equals — same length, different bytes.
//   T6   equals — different lengths.
//   T7   empty string ("") has length 0.
//
// Heap-capable targets only.

#import "Stdio.xc"
#import "String.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    String* a = String.withCString("hello");
    Assert.isEqual(a.byteLength(), (u16)5);                          // T1

    // charAt returns u8. Routing the value through a local before
    // the (u16) widening sidesteps an unrelated narrow-method-return
    // cast issue at the call site.
    u8 c0 = a.byteAt((u16)0);  Assert.isEqual((u16)c0, (u16)'h'); // T2a
    u8 c1 = a.byteAt((u16)1);  Assert.isEqual((u16)c1, (u16)'e'); // T2b
    u8 c4 = a.byteAt((u16)4);  Assert.isEqual((u16)c4, (u16)'o'); // T2c

    // cString round-trip — print and let the runner see "hello"
    // alongside the DONE line in the captured screen output.
    Stdio.printf("%s\n", a.cString());                           // T3

    String* b = String.withCString("hello");
    Assert.isTrue(a.equals(b));                                  // T4

    String* c = String.withCString("hellp");                     // last byte differs
    Assert.isTrue(!a.equals(c));                                 // T5

    String* d = String.withCString("hi");
    Assert.isTrue(!a.equals(d));                                 // T6

    String* e = String.withCString("");
    Assert.isEqual(e.byteLength(), (u16)0);                          // T7

    Assert.summary();
    return;
}
