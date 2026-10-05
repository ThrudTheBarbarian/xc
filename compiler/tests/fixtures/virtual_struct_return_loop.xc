// virtual_struct_return_loop.xc — an overridden method that returns a struct,
// called inside a loop. On wasm32 the indirect call's type left out the hidden
// struct-return parameter it pushes, so the module failed validation (bug 606,
// found by UXKit).
#import "Stdio.xc"
struct R
    {
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    }
class A : Object
    {
    i32 v;
    A* other;
    R af(void)
        {
        R r;
        r.x = (i16)0;
        r.y = (i16)0;
        r.w = (i16)v;
        r.h = (i16)v;
        return r;
        }
    R vp(void)
        {
        return self.af();
        }
    }
class B : A
    {
    R vp(void)
        {
        return self.af();
        }
    }
i32 f(A* a)
    {
    i32 n = (i32)0;
    for (i32 i = (i32)0; i < (i32)3; i = i + (i32)1)
        {
        R r = a.vp();
        n = n + (i32)r.w;
        }
    return n;
    }
void main(void)
    {
    A* a = new B();
    a.v = (i32)3;
    Stdio.printf("%d\n", f(a));
    }
