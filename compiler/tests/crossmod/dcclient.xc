// dcclient.xc — imports dclib and downcasts CLIENT classes the library never saw.
#import <Stdio.xc>
#import <dclib>
class Widget : Object<Pingable>
    {
    i32 s;
    void init(void)
        {
        s = (i32)100;
        }
    i32 ping(i32 x)
        {
        return s + x;
        }
    // non-vtable, non-conforming
    } class Plain : Object
    {
    i32 z;
    void init(void)
        {
        z = (i32)5;
        }
    }
    void main(void)
    {
    Object* w = (Object*)new Widget();
    Object* p = (Object*)new Plain();
    Stdio.printf("isPingable widget=%d plain=%d\n", isPingable(w) ? (i32)1 : (i32)0, isPingable(p) ? (i32)1 : (i32)0);
    Stdio.printf("tryPing widget=%d plain=%d\n", tryPing(w, (i32)5), tryPing(p, (i32)5));
    }
