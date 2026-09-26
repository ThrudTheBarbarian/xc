// protoclient.xc — a client of libProtoLib: its own class answering to the
// prelude protocols, passed to the library, and the library's Box called
// through the same protocols here. Base2/Der2 give the client an override root
// of its own, which moves its slot numbering away from the library's.
#import "Stdio.xc"
#import <ProtoLib>

class Tag<Comparable, Hashable>
    {
    i32 v;
    void init(void)
        {
        v = (i32)7;
        }
    bool equals(Object* o)
        {
        return true;
        }
    u32 hash(void)
        {
        return (u32)77;
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
    Tag@ t = new Tag();
    Box@ a = ProtoLib.make();
    Base2@ b = new Der2();
    String@ s = String.withCString("hello");
    Stdio.printf("own=%lu\n", b.f());
    Stdio.printf("lib-hash=%lu\n", ProtoLib.viaHashable((Hashable*)t));
    Stdio.printf("lib-cmp=%d\n", ProtoLib.viaComparable((Comparable*)t, (Object*)a) ? (i32)1 : (i32)0);
    Stdio.printf("lib-obj=%d\n", ProtoLib.viaObject((Object*)t, (Object*)a) ? (i32)1 : (i32)0);
    Stdio.printf("lib-bound=%lu\n", ProtoLib.viaBound((Hashable*)t));
    Stdio.printf("lib-len=%lu\n", ProtoLib.length(s));
    Hashable* h = (Hashable*)a;
    Stdio.printf("app-hash=%lu\n", h.hash());
    Comparable* k = (Comparable*)a;
    Stdio.printf("app-cmp=%d\n", k.equals((Object*)t) ? (i32)1 : (i32)0);
    Object* o = (Object*)a;
    Stdio.printf("app-obj=%d\n", o.equals((Object*)t) ? (i32)1 : (i32)0);
    return 0;
    }
