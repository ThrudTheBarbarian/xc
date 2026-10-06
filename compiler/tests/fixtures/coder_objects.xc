//xtc-na: xt6502 — Coder is not available on xt6502
// coder_objects.xc — archiving your own classes through Codable.
//
// A class overrides encodeWithCoder / initWithCoder and calls super in both,
// as with NSCoding. The unarchiver creates each instance by class name, so
// this fixture needs the compiler's class-name support (className and
// newInstanceOfClass on Object).
//
//   T1  every keyed scalar, at its extremes; a '$' key; a missing key
//   T2  a subclass codes its parent's fields through super
//   T3  shared objects stay shared, and a two-object cycle closes
//   T4  user objects inside Array and Map, gzipped at level 9
//   T5  a value of the wrong type, or out of range, makes unarchive throw
#import "Stdio.xc"
#import "Coder.xc"

// Bytes above $7F are printed as \xHH: the wasm32 host writes each output byte
// as a character of its own, so raw UTF-8 would not compare there.
String* ascii(String* s)
{
    String* out = String.withCString("");
    for (u32 i = (u32)0; i < s.byteLength(); i++)
        {
        u8 c = s.byteAt(i);
        if (c < (u8)$80)
            {
            out.appendByte(c);
            continue;
            }
        out.appendCString("\\x");
        out.appendByte(Data._hexDigit(c >> (u8)4));
        out.appendByte(Data._hexDigit(c & (u8)$0F));
        }
    return out;
}

class Scalars
{
    bool    yes;
    bool    no;
    i32     small;
    u32     big;
    i64     least;
    i64     most;
    u64     top;
    float   f;
    double  d;
    double  notANumber;
    double  infinity;
    String* text;
    Object* nothing;
    i32     dollar;

    void encodeWithCoder(Coder* coder)
    {
        super.encodeWithCoder(coder);
        coder.encodeBool(yes, "yes");
        coder.encodeBool(no, "no");
        coder.encodeI32(small, "small");
        coder.encodeU32(big, "big");
        coder.encodeI64(least, "least");
        coder.encodeI64(most, "most");
        coder.encodeU64(top, "top");
        coder.encodeFloat(f, "f");
        coder.encodeDouble(d, "d");
        coder.encodeDouble(notANumber, "nan");
        coder.encodeDouble(infinity, "inf");
        coder.encodeObject(text, "text");
        coder.encodeObject(nothing, "nothing");
        coder.encodeI32(dollar, "$class");
    }

    void initWithCoder(Coder* coder)
    {
        super.initWithCoder(coder);
        yes = coder.decodeBool("yes");
        no = coder.decodeBool("no");
        small = coder.decodeI32("small");
        big = coder.decodeU32("big");
        least = coder.decodeI64("least");
        most = coder.decodeI64("most");
        top = coder.decodeU64("top");
        f = coder.decodeFloat("f");
        d = coder.decodeDouble("d");
        notANumber = coder.decodeDouble("nan");
        infinity = coder.decodeDouble("inf");
        text = (String* ?)coder.decodeObject("text");
        nothing = coder.decodeObject("nothing");
        dollar = coder.decodeI32("$class");
        Stdio.printf("  has text: %s, has absent: %s, absent reads %d\n",
                     coder.containsKey("text") ? "yes" : "no",
                     coder.containsKey("absent") ? "yes" : "no",
                     coder.decodeI32("absent"));
    }
}

class Shape
{
    String* name;
    i32     id;

    void encodeWithCoder(Coder* coder)
    {
        super.encodeWithCoder(coder);
        coder.encodeObject(name, "name");
        coder.encodeI32(id, "id");
    }

    void initWithCoder(Coder* coder)
    {
        super.initWithCoder(coder);
        name = (String* ?)coder.decodeObject("name");
        id = coder.decodeI32("id");
    }
}

class Point : Shape
{
    i32    x;
    i32    y;
    Point* next;

    void encodeWithCoder(Coder* coder)
    {
        super.encodeWithCoder(coder);
        coder.encodeI32(x, "x");
        coder.encodeI32(y, "y");
        coder.encodeObject(next, "next");
    }

    void initWithCoder(Coder* coder)
    {
        super.initWithCoder(coder);
        x = coder.decodeI32("x");
        y = coder.decodeI32("y");
        next = (Point* ?)coder.decodeObject("next");
    }

    static Point* make(string name, i32 id, i32 x, i32 y)
    {
        Point* p = new Point();
        p.name = String.withCString(name);
        p.id = id;
        p.x = x;
        p.y = y;
        return p;
    }
}

class Holder
{
    Array* points;
    Map*   byName;

    void encodeWithCoder(Coder* coder)
    {
        super.encodeWithCoder(coder);
        coder.encodeObject(points, "points");
        coder.encodeObject(byName, "byName");
    }

    void initWithCoder(Coder* coder)
    {
        super.initWithCoder(coder);
        points = (Array* ?)coder.decodeObject("points");
        byName = (Map* ?)coder.decodeObject("byName");
    }
}

// Writes a string where Reader expects a number.
class Writer
{
    void encodeWithCoder(Coder* coder)
    {
        coder.encodeObject(String.withCString("seven"), "n");
        coder.encodeI64((i64)0x100000000, "wide");
    }
}

class Reader
{
    i32 n;
    i32 wide;

    void initWithCoder(Coder* coder)
    {
        n = coder.decodeI32("n");
    }
}

class NarrowReader
{
    i32 wide;

    void initWithCoder(Coder* coder)
    {
        wide = coder.decodeI32("wide");
    }
}

void printPoint(Point* p)
{
    Stdio.printf("  %s #%d (%d,%d) next %s\n", p.name.cString(), p.id, p.x, p.y,
                 (p.next == 0) ? "none" : p.next.name.cString());
}

Object* viaJSON(Object* root)
{
    String* json = Coder.archiveJSON(root);
    Stdio.printf("%s\n", ascii(json).cString());
    try
        {
        return Coder.unarchiveJSON(json);
        }
    catch (CoderError e)
        {
        Stdio.printf("  UNEXPECTED: %s\n", e.message().cString());
        }
    return (Object*)0;
}

void main(void)
{
    Stdio.printf("T1 scalars\n");
    Scalars* s = new Scalars();
    s.yes = true;
    s.small = (i32)-2147483648;
    s.big = (u32)4294967295;
    s.least = (i64)0x8000000000000000;
    s.most = (i64)0x7FFFFFFFFFFFFFFF;
    s.top = (u64)0xFFFFFFFFFFFFFFFF;
    s.f = (float)0.1d;
    s.d = 2.0d / 3.0d;
    s.notANumber = _json_dfrom((u64)0x7FF8000000000000);
    s.infinity = _json_dfrom((u64)0xFFF0000000000000);
    s.text = String.withCString("tab\there é");
    s.dollar = (i32)42;
    Scalars* s2 = (Scalars* ?)viaJSON(s);
    Stdio.printf("  %s %s %d %s\n", s2.yes ? "true" : "false", s2.no ? "true" : "false", s2.small,
                 String.withU32(s2.big).cString());
    Stdio.printf("  %s %s %s\n", String.withI64(s2.least).cString(), String.withI64(s2.most).cString(),
                 String.withU64(s2.top).cString());
    Stdio.printf("  float same: %s, double same: %s, nan: %s, -inf: %s\n",
                 (s2.f == s.f) ? "yes" : "NO",
                 (_json_dbits(s2.d) == _json_dbits(s.d)) ? "yes" : "NO",
                 ((_json_dbits(s2.notANumber) & (u64)0x7FF8000000000000) == (u64)0x7FF8000000000000) ? "yes" : "NO",
                 (_json_dbits(s2.infinity) == (u64)0xFFF0000000000000) ? "yes" : "NO");
    Stdio.printf("  text \"%s\", nothing %s, $class key %d\n", ascii(s2.text).cString(),
                 (s2.nothing == 0) ? "null" : "SET", s2.dollar);

    Stdio.printf("T2 subclass\n");
    Point* solo = Point.make("solo", (i32)7, (i32)-3, (i32)4);
    printPoint((Point* ?)viaJSON(solo));

    Stdio.printf("T3 sharing and a cycle\n");
    Point* a = Point.make("a", (i32)1, (i32)1, (i32)2);
    Point* b = Point.make("b", (i32)2, (i32)3, (i32)4);
    a.next = b;
    b.next = a;
    Array* list = Array.with(a, b, a);
    Array* list2 = (Array* ?)viaJSON(list);
    Point* a2 = (Point* ?)list2.get((u32)0);
    Point* b2 = (Point* ?)list2.get((u32)1);
    printPoint(a2);
    printPoint(b2);
    Stdio.printf("  shared: %s, cycle: %s\n", (list2.get((u32)2) == a2) ? "yes" : "NO",
                 (a2.next == b2 && b2.next == a2) ? "yes" : "NO");
    a.next = (Point*)0;
    a2.next = (Point*)0;

    Stdio.printf("T4 collections, gzipped\n");
    Holder* h = new Holder();
    h.points = new Array();
    h.byName = new Map();
    for (i32 i = (i32)0; i < (i32)40; i++)
        {
        Point* p = Point.make("p", i, i * (i32)10, -i);
        p.name = String.withFormat("point %d", i);
        h.points.add(p);
        h.byName.set(p.name, p);
        }
    Data* z = Coder.archive(h, (u8)9);
    String* plain = Coder.archiveJSON(h);
    Stdio.printf("  gzip %s, smaller %s\n",
                 (z.byteAt((u32)0) == (u8)$1F && z.byteAt((u32)1) == (u8)$8B) ? "yes" : "NO",
                 (z.length() * (u32)3 < plain.byteLength()) ? "yes" : "NO");
    try
        {
        Holder* h2 = (Holder* ?)Coder.unarchive(z);
        Point* p17 = (Point* ?)h2.points.get((u32)17);
        printPoint(p17);
        Stdio.printf("  %d points, map finds the same object: %s\n", (i32)h2.points.count(),
                     (h2.byName.get(String.withCString("point 17")) == p17) ? "yes" : "NO");
        Stdio.printf("  same graph: %s\n", Coder.archiveJSON(h2).equals(plain) ? "yes" : "NO");
        }
    catch (CoderError e)
        {
        Stdio.printf("  UNEXPECTED: %s\n", e.message().cString());
        }

    Stdio.printf("T5 wrong types\n");
    String* w = Coder.archiveJSON(new Writer());
    String* asReader = w.replacing(String.withCString("\"Writer\""), String.withCString("\"Reader\""));
    String* asNarrow = w.replacing(String.withCString("\"Writer\""), String.withCString("\"NarrowReader\""));
    try
        {
        Coder.unarchiveJSON(asReader);
        Stdio.printf("  UNEXPECTEDLY decoded\n");
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s\n", e.message().cString());
        }
    try
        {
        Coder.unarchiveJSON(asNarrow);
        Stdio.printf("  UNEXPECTEDLY decoded\n");
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s\n", e.message().cString());
        }
    Stdio.printf("done\n");
}
