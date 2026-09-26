// protolib.xc — a library that dispatches through the PRELUDE protocols
// (Hashable, Comparable) and through Object and String on objects its client
// made. None of those is declared here, so the interface carries no slot
// numbers for them. Built with --emit-lib; see protocols.sh.
#import "Stdio.xc"

class Box<Comparable, Hashable>
    {
    i32 v;
    void init(void)
        {
        v = (i32)22;
        }
    bool equals(Object* o)
        {
        return false;
        }
    u32 hash(void)
        {
        return (u32)v;
        }
    }

typedef u32 hashfn_t(void);

class ProtoLib
    {
    static u32 viaHashable(Hashable* h)
        {
        return h.hash();
        }
    static bool viaComparable(Comparable* a, Object* b)
        {
        return a.equals(b);
        }
    static bool viaObject(Object* a, Object* b)
        {
        return a.equals(b);
        }
    static u32 viaBound(Hashable* h)
        {
        hashfn_t ^ f = &h.hash;
        if (f)
            return f();
        return (u32)0;
        }
    static u32 length(String* s)
        {
        return s.byteLength();
        }
    static Box@ make(void)
        {
        return new Box();
        }
    }
