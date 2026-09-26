//xtc-na: xt6502 — Coder is not available on xt6502
// coder_errors.xc — what Coder refuses, and that it refuses by throwing.
//
// Every bad input must come back as a CoderError with a message, never as a
// crash or a half-built graph:
//
//   T1  text that is not JSON
//   T2  JSON that is not a Coder archive, or a damaged one
//   T3  a gzipped archive with a bad CRC, and one cut short
//   T4  hand-written archives that ARE valid: extra whitespace, escapes, a
//       surrogate pair, and a null root
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

void bad(string json)
{
    try
        {
        Object* o = Coder.unarchiveJSON(String.withCString(json));
        Stdio.printf("  UNEXPECTEDLY decoded: %s\n", json);
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s\n", e.message().cString());
        }
}

void badData(string name, Data* d)
{
    try
        {
        Object* o = Coder.unarchive(d);
        Stdio.printf("  %s: UNEXPECTEDLY decoded\n", name);
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s: %s\n", name, e.message().cString());
        }
}

void main(void)
{
    Stdio.printf("T1 not JSON\n");
    bad("");
    bad("{");
    bad("[1,2,]");
    bad("{\"a\" 1}");
    bad("\"unterminated");
    bad("tru");
    bad("01");
    bad("-");
    bad("1.e5");
    bad("{\"a\":\"\\q\"}");
    bad("\"tab\there\"");
    bad("[1] 2");

    Stdio.printf("T2 not an archive\n");
    bad("[1,2]");
    bad("{\"$archiver\":\"NSKeyedArchiver\",\"$version\":1}");
    bad("{\"$archiver\":\"Coder\",\"$version\":2,\"$top\":{},\"$objects\":[]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}}}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{},\"$objects\":[\"$null\"]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":5},\"$objects\":[\"$null\"]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":9}},\"$objects\":[\"$null\"]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"$class\":\"NoSuchClass\",\"x\":1}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"x\":1}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"$class\":\"Array\",\"$items\":[\"x\"]}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"$class\":\"Array\",\"$items\":[7]}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"$class\":\"Data\",\"$base64\":\"abc\"}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",{\"$class\":\"Map\",\"$keys\":[0],\"$values\":[]}]}");
    bad("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":1}},"
        "\"$objects\":[\"$null\",true]}");
    badData("no data", (Data*)0);

    Stdio.printf("T3 damaged gzip\n");
    Array* list = new Array();
    for (u32 i = (u32)0; i < (u32)50; i++)
        list.add(String.withFormat("line %d", (i32)i));
    Data* z = Coder.archive(list, (u8)6);
    Data* crc = Data.withData(z);
    u32 at = crc.length() - (u32)8;
    crc.setByteAt(at, crc.byteAt(at) ^ (u8)$80);
    badData("bad CRC", crc);
    badData("cut short", z.subdata((u32)0, z.length() - (u32)12));
    badData("header only", z.subdata((u32)0, (u32)10));

    Stdio.printf("T4 valid by hand\n");
    try
        {
        String* hand = String.withCString(
            " {\n  \"$version\" : 1 ,\n  \"$objects\" : [ \"$null\" , \"a\\u00e9\\ud83d\\ude00\\n\" ] ,"
            "\n  \"$top\" : { \"root\" : { \"$ref\" : 1 } } , \"$archiver\" : \"Coder\" , \"extra\" : null\n}\n");
        String* s = (String* ?)Coder.unarchiveJSON(hand);
        Stdio.printf("  string of %d bytes: %s", (i32)s.byteLength(), ascii(s).cString());
        Object* none = Coder.unarchiveJSON(String.withCString(
            "{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":0}},\"$objects\":[\"$null\"]}"));
        Stdio.printf("  null root: %s\n", (none == 0) ? "yes" : "NO");
        Object* nothing = Coder.unarchive(Coder.archive((Object*)0, (u8)9));
        Stdio.printf("  archive of null: %s\n", (nothing == 0) ? "yes" : "NO");
        }
    catch (CoderError e)
        {
        Stdio.printf("  UNEXPECTED: %s\n", e.message().cString());
        }
    Stdio.printf("done\n");
}
