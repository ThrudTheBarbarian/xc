// collections.xc — Array, Map, Set and String, with element types.
//
// The containers are ordinary xtc classes in the standard library. What makes
// them pleasant to use is the ELEMENT TYPE in angle brackets: `Array<String>*`
// stores and returns `String*`, so nothing at the use site needs a cast, and
// putting the wrong type in is a compile error rather than a crash later.
//
// The element type is ERASED at run time — one Array implementation serves
// every element type — so there is no code-size cost per instantiation, and
// the type argument is a static check, not a runtime one.
#import "Stdio.xc"
#import "Foundation.xc"

class Point : Object
{
    i32 x;
    i32 y;
    void init(void) { x = (i32)0; y = (i32)0; }
    static Point* at(i32 px, i32 py) { Point* p = new Point(); p.x = px; p.y = py; return p; }

    // `description` is what `%@` prints. Object supplies a default; override it
    // and every %@, every container dump and every debug print follows.
    //
    // `String.withFormat` takes the same specifiers Stdio.printf does, which is
    // what makes this one line rather than a run of appends.
    String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
}

i32 main(void)
{
    // ---- Array -------------------------------------------------------------
    // `new Array()` needs no type argument: it is taken from the declaration.
    Array<String>* names = new Array();
    names.add(String.withCString("ada"));
    names.add(String.withCString("grace"));
    names.add(String.withCString("edsger"));

    // get() returns String*, not Object* — no cast at the use site.
    Stdio.printf("count %d, first %s\n",
                 (i16)names.count(), names.get((u32)0).cString());

    // for-in walks a container in order. The loop variable is the element type.
    Stdio.print("names:");
    for (String* n in names) { Stdio.printf(" %s", n.cString()); }
    Stdio.print("\n");

    // ---- Array of your own class ------------------------------------------
    Array<Point>* path = new Array();
    path.add(Point.at((i32)0, (i32)0));
    path.add(Point.at((i32)3, (i32)4));
    // %@ dispatches description() through the vtable.
    Stdio.printf("last %@\n", path.last());

    // ---- Array of a primitive ---------------------------------------------
    // A primitive element travels boxed — a Number goes in, an i32 comes out —
    // but conformance is judged by the DECLARED type, so this array refuses a
    // float at compile time ("cannot be stored in a collection of").
    //
    // Unboxing happens in ASSIGNMENT context, and a for-in loop variable is a
    // binding, so this reads the values and not the boxes. Note that
    // `total + scores.get(i)` would NOT unbox — the right operand there is
    // still an Object*, so bind it to a named local first.
    Array<i32>* scores = new Array();
    scores.add((i32)70);
    scores.add((i32)95);
    i32 total = (i32)0;
    for (i32 v in scores) { total = total + v; }
    Stdio.printf("total %ld\n", total);

    // ---- Map ---------------------------------------------------------------
    // TWO type arguments: the key and the value. Written with one, the argument
    // names the value and the key goes unchecked — anything Hashable, which
    // String is. Prefer the pair: an unchecked key is half a typed collection.
    Map<String, Point>* places = new Map();
    places.set(String.withCString("origin"), Point.at((i32)0, (i32)0));
    places.set(String.withCString("corner"), Point.at((i32)9, (i32)9));
    Point* corner = places.get(String.withCString("corner"));
    Stdio.printf("corner %@, map holds %d\n", corner, (i16)places.count());
    // A missing key gives 0, not a trap.
    Stdio.printf("missing is null: %d\n",
                 (i16)(places.get(String.withCString("nowhere")) == 0 ? 1 : 0));

    // ---- Set ---------------------------------------------------------------
    // Membership is by VALUE, not identity: two equal Strings count once, even
    // though they are different objects.
    Set<String>* seen = new Set();
    seen.add(String.withCString("x"));
    seen.add(String.withCString("y"));
    seen.add(String.withCString("x"));
    Stdio.printf("set holds %d, contains y: %d\n",
                 (i16)seen.count(),
                 (i16)(seen.contains(String.withCString("y")) ? 1 : 0));

    // ---- String ------------------------------------------------------------
    // String is a MUTABLE object with a value identity: `append` grows the
    // receiver in place, `appending` returns a new string, and `equals`
    // compares bytes rather than addresses.
    String* greeting = String.withCString("hello");
    String* longer   = greeting.appending(String.withCString(", world"));
    greeting.appendCString("!");
    Stdio.printf("%s / %s (%d chars) / %s\n",
                 greeting.cString(), longer.cString(),
                 (i16)longer.byteLength(), longer.uppercased().cString());

    Stdio.printf("equal by value: %d, same object: %d\n",
                 (i16)(String.withCString("ada").equals(names.get((u32)0)) ? 1 : 0),
                 (i16)(String.withCString("ada") == names.get((u32)0) ? 1 : 0));

    // Searching and slicing. A miss is String.notFound(), never a negative
    // index — the result type is unsigned.
    Stdio.printf("index of world: %d, prefix hello: %d, slice %s\n",
                 (i16)longer.byteIndexOf(String.withCString("world")),
                 (i16)(longer.hasPrefix(String.withCString("hello")) ? 1 : 0),
                 longer.substringBytes((u32)7, (u32)5).cString());

    // Numbers to strings, including the 64-bit widths.
    Stdio.printf("i32 %s, u64 %s\n",
                 String.withI32((i32)-42).cString(),
                 String.withU64((u64)1099511627776).cString());
    return 0;
}
