//xtc-na: xt6502 — JSON is not available on xt6502
// foundation_json.xc — JSON: parsing to Map / Array / String / Number / Null,
// exact numbers, escapes, insertion-ordered objects, compact and pretty
// writing, and the errors for bad input and unwritable values.
#import "Foundation.xc"
#import "JSON.xc"
#import "Stdio.xc"

i32 gFails;
void check(u8* what, bool ok)
    {
    if (ok)
        Stdio.printf("  ok   %s\n", what);
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool same(String* s, u8* want)
    {
    return s != 0 && s.equals(String.withCString(want));
    }
String* S(u8* c)
    {
    return String.withCString(c);
    }
String* round(u8* text)
    {
    String* r = (String*)0;
    try
        {
        r = JSON.stringify(JSON.parse(S(text)));
        }
    catch (JSONError e)
        {
        r = e.message();
        }
    return r;
    }
String* errorOf(u8* text)
    {
    try
        {
        JSON.parse(S(text));
        }
    catch (JSONError e)
        {
        return e.message();
        }
    return S("(no error)");
    }

i32 main(void)
    {
    gFails = (i32)0;
    Object* v = (Object*)0;
    try
        {
        v = JSON.parse(S("{\"name\":\"xc\",\"tags\":[1,2.5,true,false,null],\"n\":{}}"));
        }
    catch (JSONError e)
        {
        Stdio.printf("parse threw: %s\n", e.message().cString());
        return (i32)1;
        }
    Map* m = (Map* ?)v;
    check("object is a Map", m != 0);
    check("string member", same((String* ?)m.get(S("name")), "xc"));
    Array* tags = (Array* ?)m.get(S("tags"));
    check("array member", tags != 0 && tags.count() == (u32)5);
    Number* one = (Number* ?)tags.get((u32)0);
    check("integer is an Int", one != 0 && one.isInt() && !one.isBool() && one.asI64() == (i64)1);
    Number* half = (Number* ?)tags.get((u32)1);
    check("2.5 is a double", half != 0 && half.isFloat() && half.asDouble() == 2.5d);
    Number* t = (Number* ?)tags.get((u32)2);
    check("true is a bool", t != 0 && t.isBool() && t.asBool());
    Number* f = (Number* ?)tags.get((u32)3);
    check("false is a bool", f != 0 && f.isBool() && !f.asBool());
    check("null is Null", Null.isNull(tags.get((u32)4)));
    check("empty object", ((Map* ?)m.get(S("n"))).count() == (u32)0);
    check("keys keep their order", same((String* ?)m.enumAt((u32)1), "tags"));

    // Round trips, compact.
    check("round trip", same(round("{\"name\":\"xc\",\"tags\":[1,2.5,true,false,null]}"), "{\"name\":\"xc\",\"tags\":[1,2.5,true,false,null]}"));
    check("whitespace dropped", same(round(" [ 1 , { \"a\" : [ ] } ] "), "[1,{\"a\":[]}]"));
    check("i64 extremes exact", same(round("[9223372036854775807,-9223372036854775808]"), "[9223372036854775807,-9223372036854775808]"));
    check("double shortest", same(round("[0.1,1e300,-2.5e-8,3.0]"), "[0.1,1.0e+300,-2.5e-8,3.0]"));
    check("escapes", same(round("[\"a\\\"b\\\\c\\n\\t\\u0001\"]"), "[\"a\\\"b\\\\c\\n\\t\\u0001\"]"));
    check("unicode escapes decode", same(round("[\"\\u00e9\\ud83d\\ude00\"]"), "[\"\u00e9\U0001F600\"]"));
    check("duplicate key keeps last", same(round("{\"a\":1,\"a\":2}"), "{\"a\":2}"));
    check("scalar root", same(round("42"), "42"));

    // Pretty.
    try
        {
        String* p = JSON.stringifyPretty(JSON.parse(S("{\"a\":[1,2],\"b\":{},\"c\":[]}")));
        Stdio.printf("%s", p.cString());
        }
    catch (JSONError e)
        {
        check("pretty", false);
        }

    // Errors.
    Stdio.printf("%s\n", errorOf("[1,2").cString());
    Stdio.printf("%s\n", errorOf("{\"a\" 1}").cString());
    Stdio.printf("%s\n", errorOf("[1] x").cString());
    Stdio.printf("%s\n", errorOf("01").cString());
    Stdio.printf("%s\n", errorOf("").cString());

    // Values JSON cannot hold.
    Array* bad = new Array();
    bad.add(Number.withDouble(0.0d / 0.0d));
    try
        {
        JSON.stringify(bad);
        check("NaN refused", false);
        }
    catch (JSONError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    Map* nk = new Map();
    nk.set(Number.withI32((i32)1), S("x"));
    try
        {
        JSON.stringify(nk);
        check("Number key refused", false);
        }
    catch (JSONError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    Array* other = new Array();
    other.add(new Set());
    try
        {
        JSON.stringify(other);
        check("Set refused", false);
        }
    catch (JSONError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    check("null reference writes null", same(round("null"), "null"));
    check("Bool description", same(Number.withBool(true).description(), "true"));
    check("Bool equals 1", Number.withBool(true).equals(Number.withI32((i32)1)));

    if (gFails == (i32)0)
        Stdio.printf("PASS\n");
    return gFails;
    }
