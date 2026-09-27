// description_enum_ivar.xc — an enum ivar is an integer ivar for the
// synthesised description().
//
// A class with no description() of its own gets one that prints each integer
// ivar. An enum is an integer type (the smallest unsigned type that holds its
// members), so a class whose only integer ivar is an enum still gets one, and
// an enum ivar among other integers takes its place in declaration order.
// A class with no integer ivar at all keeps Object's `<Object>`.

#import "Stdio.xc"
#import "String.xc"

enum Kind = {K_A, K_B, K_C};

class Node
{
    Kind kind;
}

class Mixed
{
    u16 id;
    Kind kind;
    i16 delta;
}

class Plain
{
    String* name;
}

void main(void)
{
    Node* n = new Node();
    n.kind = K_B;
    Stdio.printf("%s\n", n.description().cString());

    Mixed* m = new Mixed();
    m.id = (u16)40;
    m.kind = K_C;
    m.delta = (i16)-3;
    Stdio.printf("%s\n", m.description().cString());

    Plain* p = new Plain();
    Stdio.printf("%s\n", p.description().cString());
}
