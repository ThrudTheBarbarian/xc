//xtc-na: xt6502 — Coder is not available on xt6502
// coder_builtins.xc — Coder round trips of the library's own value types.
//
// String, Number, Data, Array, Map and Set are archived in a native JSON form
// rather than through encodeWithCoder, so none of this needs a user class.
//
//   T1  strings: escapes, control bytes, non-ASCII, "$null", invalid UTF-8
//   T2  numbers: 64-bit extremes exact, int/float kind kept, doubles exact,
//       NaN and the infinities
//   T3  containers and Data, including null elements and empty ones
//   T4  one object referred to three times decodes to one object
//   T5  an Array that contains itself
//   T6  compressed archives: gzip magic, and the same graph back
//
// Each case prints the JSON, then archives the decoded graph again and checks
// the text is identical.
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

Object* roundTrip(Object* root)
{
    String* json = Coder.archiveJSON(root);
    Stdio.printf("%s\n", ascii(json).cString());
    try
        {
        Object* back = Coder.unarchiveJSON(json);
        String* again = Coder.archiveJSON(back);
        Stdio.printf("  same text: %s\n", again.equals(json) ? "yes" : "NO");
        return back;
        }
    catch (CoderError e)
        {
        Stdio.printf("  UNEXPECTED: %s\n", e.message().cString());
        }
    return (Object*)0;
}

String* bits(Number* n)
{
    return String.withU64(_coder_dbits(n.asDouble()));
}

void main(void)
{
    // T1
    Stdio.printf("T1 strings\n");
    Array* strs = new Array();
    strs.add(String.withCString("plain"));
    strs.add(String.withCString(""));
    strs.add(String.withCString("q\"b\\s/ \n\r\t \x01\x1f\x7f"));
    strs.add(String.withCString("café ☃ \U0001F600"));
    strs.add(String.withCString("$null"));
    u8 raw[3] = { $FF, $FE, $41 };
    strs.add(String.withBytes(&raw[0], (u32)3));
    Array* s2 = (Array* ?)roundTrip(strs);
    String* odd = (String*)s2.get((u32)5);
    Stdio.printf("  invalid UTF-8 kept: %s\n",
                 (odd.byteLength() == (u32)3 && odd.byteAt((u32)0) == (u8)$FF) ? "yes" : "NO");
    Stdio.printf("  \"$null\" is a string: %s\n", (s2.get((u32)4) != 0) ? "yes" : "NO");

    // T2
    Stdio.printf("T2 numbers\n");
    Array* nums = new Array();
    nums.add(Number.withI32((i32)0));
    nums.add(Number.withI32((i32)-1));
    nums.add(Number.withI64((i64)0x8000000000000000));
    nums.add(Number.withI64((i64)0x7FFFFFFFFFFFFFFF));
    nums.add(Number.withU64((u64)0xFFFFFFFFFFFFFFFF));
    nums.add(Number.withDouble(0.1d));
    // -0.0 through its bits: a -0.0d literal compiles to +0.0 on win64.
    nums.add(Number.withDouble(_coder_dfrom((u64)0x8000000000000000)));
    nums.add(Number.withDouble(3.0d));
    nums.add(Number.withDouble(1.0e21d));
    nums.add(Number.withDouble(1.5e300d));
    nums.add(Number.withDouble(_coder_dfrom((u64)1)));
    nums.add(Number.withDouble(_coder_dfrom((u64)0x7FEFFFFFFFFFFFFF)));
    nums.add(Number.withDouble(123456.789d));
    nums.add(Number.withDouble(_coder_dfrom((u64)0x7FF8000000000000)));
    nums.add(Number.withDouble(_coder_dfrom((u64)0x7FF0000000000000)));
    nums.add(Number.withDouble(_coder_dfrom((u64)0xFFF0000000000000)));
    Array* n2 = (Array* ?)roundTrip(nums);
    bool kinds = true;
    bool exact = true;
    for (u32 i = (u32)0; i < nums.count(); i++)
        {
        Number* a = (Number*)nums.get(i);
        Number* b = (Number*)n2.get(i);
        if (a.isFloat() != b.isFloat())
            kinds = false;
        if (a.isFloat() && !bits(a).equals(bits(b)))
            exact = false;
        if (!a.isFloat() && a.asI64() != b.asI64())
            exact = false;
        }
    Stdio.printf("  kinds kept: %s, values exact: %s\n", kinds ? "yes" : "NO", exact ? "yes" : "NO");
    Number* big = (Number*)n2.get((u32)4);
    Stdio.printf("  u64 max: %s\n", String.withU64(big.asU64()).cString());

    // T3
    Stdio.printf("T3 containers\n");
    Array* box = new Array();
    Map* m = new Map();
    m.set(String.withCString("one"), Number.withI32((i32)1));
    m.set(String.withCString("two"), Number.withI32((i32)2));
    m.set(Number.withI32((i32)3), (Object*)0);
    box.add(m);
    Set* s = new Set();
    s.add(String.withCString("x"));
    s.add(String.withCString("y"));
    box.add(s);
    u8 bytes[5] = { $00, $DE, $AD, $BE, $EF };
    box.add(Data.withBytes(&bytes[0], (u32)5));
    box.add(Data.withCapacity((u32)0));
    box.add((Object*)0);
    box.add(new Array());
    box.add(Array.with(Array.with(String.withCString("deep"))));
    Array* b2 = (Array* ?)roundTrip(box);
    Map* m2 = (Map* ?)b2.get((u32)0);
    Number* two = (Number* ?)m2.get(String.withCString("two"));
    Stdio.printf("  map count %d, two=%d, has 3: %s\n", (i32)m2.count(), two.asI32(),
                 m2.containsKey(Number.withI32((i32)3)) ? "yes" : "NO");
    Set* s3 = (Set* ?)b2.get((u32)1);
    Stdio.printf("  set count %d, has y: %s\n", (i32)s3.count(),
                 s3.contains(String.withCString("y")) ? "yes" : "NO");
    Data* d2 = (Data* ?)b2.get((u32)2);
    Stdio.printf("  data %s\n", d2.hexString().cString());
    Stdio.printf("  null element: %s\n", (b2.get((u32)4) == 0) ? "yes" : "NO");

    // T4
    Stdio.printf("T4 sharing\n");
    String* shared = String.withCString("shared");
    Array* sh = Array.with(shared, shared, Array.with(shared), String.withCString("shared"));
    Array* sh2 = (Array* ?)roundTrip(sh);
    Array* inner = (Array* ?)sh2.get((u32)2);
    Stdio.printf("  one object: %s, equal copy separate: %s\n",
                 (sh2.get((u32)0) == sh2.get((u32)1) && inner.get((u32)0) == sh2.get((u32)0)) ? "yes" : "NO",
                 (sh2.get((u32)3) != sh2.get((u32)0)) ? "yes" : "NO");

    // T5
    Stdio.printf("T5 cycle\n");
    Array* loop = new Array();
    loop.add(String.withCString("head"));
    loop.add(loop);
    Array* loop2 = (Array* ?)roundTrip(loop);
    Stdio.printf("  contains itself: %s\n", (loop2.get((u32)1) == loop2) ? "yes" : "NO");
    loop.removeAll();
    loop2.removeAll();

    // T6
    Stdio.printf("T6 compressed\n");
    Array* many = new Array();
    for (u32 i = (u32)0; i < (u32)200; i++)
        many.add(String.withFormat("entry %d of the list", (i32)i));
    String* plain = Coder.archiveJSON(many);
    Data* d0 = Coder.archive(many, (u8)0);
    Stdio.printf("  level 0 is JSON: %s\n",
                 (d0.length() == plain.byteLength() && d0.byteAt((u32)0) == (u8)'{') ? "yes" : "NO");
    for (u8 level = (u8)1; level <= (u8)9; level = level + (u8)4)
        {
        Data* z = Coder.archive(many, level);
        bool magic = z.byteAt((u32)0) == (u8)$1F && z.byteAt((u32)1) == (u8)$8B;
        try
            {
            Object* back = Coder.unarchive(z);
            Stdio.printf("  level %d: gzip %s, smaller %s, same graph %s\n", (i32)level,
                         magic ? "yes" : "NO", (z.length() < plain.byteLength()) ? "yes" : "NO",
                         Coder.archiveJSON(back).equals(plain) ? "yes" : "NO");
            }
        catch (CoderError e)
            {
            Stdio.printf("  UNEXPECTED: %s\n", e.message().cString());
            }
        }
    Stdio.printf("done\n");
}
