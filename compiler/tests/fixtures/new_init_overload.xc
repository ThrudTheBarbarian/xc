// new_init_overload.xc — `new T(args)` picks the right init()
// overload via conversionRank scoring, not declaration order.
//
// Pre-fix the codegen's emitNewExpr selected the first init
// whose parameter count matched the call arity, completely
// bypassing the conversionRank-based scoring used at every
// other call site. Symptom: `new Gfx8(buf)` (buf is u8@)
// silently routed to init(u8 n), truncating the pointer to
// a small int. With inheritance present, declaration order
// beat the smaller-fit rule even for u8 vs u16.
//
//   T1   new Foo(7)         → init(u8 n) — literal small int
//                             prefers u8
//   T2   new Foo(b)         → init(u8@ b) — pointer arg picks
//                             pointer overload, not the u8 one
//   T3   inheritance + u8/u16 ordering still respects exact
//        type match for non-literal args
//   T4   inheritance + literal int prefers u8 over u16

#import "Stdio.xc"
#import "Assert.xc"

class Base { u16 dummy; }

class Foo : Base {
    u8  v8;
    u16 v16;
    u8* p;
    void init(void)    { v8 = 11; v16 = 1111; p = (u8*)0; return; }
    void init(u8 n)    { v8 = n;  v16 = 0;    p = (u8*)0; return; }
    void init(u16 n)   { v8 = 0;  v16 = n;    p = (u8*)0; return; }
    void init(u8* buf) { v8 = 99; v16 = 0;    p = buf;    return; }
}

void main(void)
{
    Assert.reset();

    // T1: literal 7 → init(u8). v8=7, v16=0, p=0.
    Foo* a = new Foo(7);
    Assert.isEqual(a.v8, 7);

    // T2: u8@ buf → init(u8@). v8=99, p=buf, NOT v8=lo(buf).
    u8* buf = new u8[10];
    Foo* b = new Foo(buf);
    Assert.isEqual(b.v8, 99);
    Assert.isEqual((u16)b.p, (u16)buf);

    // T3: u16 var → init(u16). v8=0, v16=val.
    u16 sixteen = 4321;
    Foo* c = new Foo(sixteen);
    Assert.isEqual(c.v16, 4321);

    // T4: literal that fits both u8 and u16 → init(u8) wins.
    Foo* d = new Foo(200);
    Assert.isEqual(d.v8, 200);
    Assert.isEqual(d.v16, 0);

    // T5: zero-arg → init(void). v8=11.
    Foo* e = new Foo();
    Assert.isEqual(e.v8, 11);

    Stdio.printf("DONE 7\n");
    return;
}
