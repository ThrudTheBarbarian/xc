//xtc-flags: target=arm64
// `Map<K, V>` — a collection may take TWO type arguments (private:docs/bugs/049).
//
// NOT xt6502: its Map is a separate, smaller implementation.
//
// Before this, a collection took one type argument, which named the VALUE and
// left the key erased to `Hashable*` and unchecked — so half of a map went
// untyped. `Map<V>` still means exactly that and is unchanged; the second
// argument is what asks for the key to be checked too.
//
// The arguments are a compile-time check and are ERASED at run time, as
// `Array<T>` always has been: one Map implementation serves every pairing, and
// nothing is instantiated per type.
#import "Foundation.xc"
#import "Stdio.xc"

class Point : Object
{
    i32 x;
    void init(void) { x = (i32)0; }
}

i32 main(void)
{
    // Two arguments: the key is a String, the value a Point.
    Map<String, Point>* m = new Map();
    Point* p = new Point(); p.x = (i32)7;
    m.set(String.withCString("a"), p);
    Point* got = m.get(String.withCString("a"));    // VALUE substitutes: no cast
    Stdio.printf("two-arg  val=%ld count=%d\n", got.x, (u16)m.count());

    // One argument still means "the value", keys unchecked — unchanged.
    Map<Point>* legacy = new Map();
    legacy.set(String.withCString("k"), p);
    Stdio.printf("one-arg  val=%ld\n", legacy.get(String.withCString("k")).x);

    // The single-argument containers are untouched by any of it.
    Array<String>* a = new Array();
    a.add(String.withCString("s"));
    Set<String>* st = new Set();
    st.add(String.withCString("z"));
    Stdio.printf("array=%s set=%d\n", a.get((u32)0).cString(), (u16)st.count());
    return 0;
}
