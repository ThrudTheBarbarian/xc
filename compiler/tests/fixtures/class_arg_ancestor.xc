// A class-pointer argument may be typed as an ANCESTOR of the parameter's
// class: the call is an implicit downcast, the one collection code relies on
// (`Object*` from `Array.get`). The same rule holds for a free function, a
// static method, an instance method, an implicit-self call and a protocol
// call. A protocol parameter takes `Object*`, and a protocol value converts to
// a class that conforms to it.
#import "Stdio.xc"

protocol Named { i32 id(); }

class A : Object { i32 a; }
class A2 : A <Named>
    {
    i32 b;
    i32 id() { return b; }
    }

void f(A2* x) { Stdio.printf("f %ld %ld\n", x.a, x.b); }
void g(Named@ n) { Stdio.printf("g %ld\n", n.id()); }
void h(A2* x) { Stdio.printf("h %ld\n", x.b); }
void viaProto(Named@ n) { h(n); }

protocol Taker { void take(A2* x); }

class K : Object <Taker>
    {
    static void s(A2* x) { Stdio.printf("s %ld\n", x.b); }
    void m(A2* x) { Stdio.printf("m %ld\n", x.b); }
    void take(A2* x) { Stdio.printf("take %ld\n", x.b); }
    void self1(A* x) { m(x); }
    }

void main(void)
    {
    A2* two = new A2();
    two.a = 3;
    two.b = 4;
    A* up = two;
    Object* obj = two;
    Array* arr = new Array();
    arr.add(two);

    f(up);
    f(arr.get(0));
    K.s(up);
    K.s(obj);
    K* k = new K();
    k.m(obj);
    k.self1(up);
    Taker@ t = k;
    t.take(up);
    g(obj);
    viaProto(two);
    }
