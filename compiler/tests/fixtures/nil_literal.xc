// nil_literal.xc — `nil` is the null pointer, of any pointer type.
//
// It is the literal 0 to the lowering, so `p == nil` and `p = nil` produce the
// IR `p == 0` and `p = 0` always have; sema is what makes it a pointer: a
// declaration, assignment, return, argument or comparison that puts it where a
// pointer is not wanted is an error (nil_not_integer, nil_not_compared). This
// fixture is the positive side: every pointer kind, every position.

#import "Stdio.xc"
#import "Assert.xc"

class Node
{
    u32 _v;
    static Node* make(u32 v) { Node* n = new Node(); n._v = v; return n; }
    u32 value(void) { return _v; }
}

Node* firstOr(Node* a, Node* b)
{
    if (a != nil) return a;
    return b != nil ? b : nil;              // nil in a ternary arm, and a return
}

u32 countOf(Node* n)
{
    return n == nil ? (u32)0 : n.value();    // nil on the right of ==
}

bool isNull(pointer p)
{
    return p == nil;                        // a raw pointer against nil
}

void main(void)
{
    Assert.reset();

    Node* a = nil;                          // a class pointer declared nil
    Assert.isTrue(a == nil);                // T1
    Assert.isTrue(nil == a);                // T2 nil on the left
    Assert.isEqual(countOf(a), (u32)0);     // T3 nil passed where a pointer is wanted
    Assert.isEqual(countOf(nil), (u32)0);   // T4 nil as an argument

    a = Node.make((u32)7);
    Assert.isTrue(a != nil);                // T5
    Assert.isEqual(countOf(a), (u32)7);     // T6
    Assert.isEqual(firstOr(nil, a).value(), (u32)7);   // T7 nil as the first argument
    Assert.isTrue(firstOr(nil, nil) == nil); // T8 both nil, result nil

    u32* ip = nil;                          // a pointer to a scalar
    Assert.isTrue(ip == nil);               // T9
    u32 x = (u32)3;
    ip = &x;
    Assert.isTrue(ip != nil);               // T10
    ip = nil;                               // assigned back to nil
    Assert.isTrue(ip == nil);               // T11

    string s = nil;                         // a string is a pointer
    Assert.isTrue(s == nil);                // T12
    s = "abc";
    Assert.isTrue(s != nil);                // T13

    pointer raw = nil;                      // the raw pointer type
    Assert.isTrue(isNull(raw));             // T14
    Assert.isTrue(!isNull((pointer)&x));    // T15

    a = nil;                                // releases the Node
    Assert.isTrue(a == nil);                // T16
    Assert.summary();
}
