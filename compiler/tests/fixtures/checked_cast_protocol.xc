//xtc-na: xt6502,m68k — no conformance list at run time there, so the cast is refused unless the class declares the protocol
// checked_cast_protocol.xc — a checked cast to a PROTOCOL pointer.
//
// `(Pingable* ?)o` asks whether o conforms to Pingable: the conforming object
// comes back, anything else gives null. The rule that refuses a checked cast
// from a raw `pointer` must leave this alone — a protocol pointer is a valid
// target, and an Object* operand is an object.
//   T1  an object that conforms        — the object, and its method runs.
//   T2  an object that does not        — null.
//   T3  a null operand                 — stays null.

#import "Stdio.xc"

protocol Pingable
    {
    i32 ping(i32 x);
    }

class Yes : Object <Pingable>
    {
    i32 ping(i32 x) { return x + 1; }
    }

class No : Object
    {
    i32 v;
    }

i32 tryPing(Object* o, i32 x)
{
    Pingable* p = (Pingable* ?)o;
    if (p == (Pingable*)0)
        return -1;
    return p.ping(x);
}

i32 main(void)
{
    Stdio.printf("T1 %d\n", tryPing((Object*)new Yes(), 41));
    Stdio.printf("T2 %d\n", tryPing((Object*)new No(), 41));
    Stdio.printf("T3 %d\n", tryPing((Object*)0, 41));
    return 0;
}
