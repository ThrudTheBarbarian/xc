// protosub.xc — a client SUBCLASS of the library's Box, overriding the methods
// the library reaches through Hashable, Comparable and Object.
#import "Stdio.xc"
#import <ProtoLib>

class Crate : Box
    {
    bool equals(Object* o)
        {
        return true;
        }
    u32 hash(void)
        {
        return (u32)99;
        }
    }

class Base2
    {
    u32 f(void)
        {
        return (u32)1;
        }
    }

class Der2 : Base2
    {
    u32 f(void)
        {
        return (u32)2;
        }
    }

i32 main(void)
    {
    Crate@ c = new Crate();
    Box@ a = ProtoLib.make();
    Base2@ b = new Der2();
    Stdio.printf("own=%lu\n", b.f());
    Stdio.printf("lib-hash=%lu\n", ProtoLib.viaHashable((Hashable*)c));
    Stdio.printf("lib-cmp=%d\n", ProtoLib.viaComparable((Comparable*)c, (Object*)a) ? (i32)1 : (i32)0);
    Stdio.printf("lib-obj=%d\n", ProtoLib.viaObject((Object*)c, (Object*)a) ? (i32)1 : (i32)0);
    Stdio.printf("lib-bound=%lu\n", ProtoLib.viaBound((Hashable*)c));
    Hashable* h = (Hashable*)c;
    Stdio.printf("app-hash=%lu\n", h.hash());
    Box* x = (Box*)c;
    Stdio.printf("app-box=%lu\n", x.hash());
    return 0;
    }
