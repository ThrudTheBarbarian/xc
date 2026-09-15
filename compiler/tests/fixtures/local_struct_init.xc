#import "Stdio.xc"
struct Node { u16 tag; u8* link; float coef; u16 tail; }
struct Inner { u16 a; u16 b; }
struct Outer { u16 head; Inner nest; float f; u16 tail; }
u8 buf[4] = { $11, $22, $33, $44 };

void main()
{
    // local struct with a pointer + float member, brace-init
    Node n = { $DEAD, 0, 3.14159, $C3C3 };
    Stdio.printf("n=%x,%x,%x\n", n.tag, n.tail, (u16)(n.link == 0));
    if (n.coef == 3.14159) Stdio.printf("n.coef=ok\n"); else Stdio.printf("n.coef=BAD\n");

    // local with a real pointer value
    Node m = { $BEEF, 0, 1.5, $5A5A };
    m.link = &buf[0];
    Stdio.printf("m=%x,%x deref=%x\n", m.tag, m.tail, *m.link);

    // nested aggregate local (phase-165 path)
    Outer o = { $1111, {$2222, $3333}, 2.5, $4444 };
    Stdio.printf("o=%x,%x,%x,%x\n", o.head, o.nest.a, o.nest.b, o.tail);
    if (o.f == 2.5) Stdio.printf("o.f=ok\n"); else Stdio.printf("o.f=BAD\n");

    // local array of structs with pointer members
    Node arr[2] = { {$0101, 0, 0.5, $0202}, {$0303, 0, 0.25, $0404} };
    Stdio.printf("a0=%x,%x a1=%x,%x\n", arr[0].tag, arr[0].tail, arr[1].tag, arr[1].tail);
}
