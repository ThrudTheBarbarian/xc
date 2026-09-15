// test_json.xc — UXJSON: parse a document + round-trip serialize.
#import <Stdio.xc>
#import "UXJSON.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
bool streq(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got == (u8*)0 ? (u8*)"(null)" : got, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    u8* doc = (u8*)"{\"name\":\"Ada\",\"age\":42,\"active\":true,\"tags\":[\"a\",\"b\",\"c\"],\"meta\":{\"x\":1,\"y\":-3}}";
    UXJSONValue* root = UXJSON.parse(doc);
    check("parsed (non-null)", root != (UXJSONValue*)0 ? (i32)1 : (i32)0, (i32)1);
    check("root is object", root.valueType(), (i32)JV_OBJ);
    eq("name", root.get((u8*)"name").asString(), (u8*)"Ada");
    check("age", root.get((u8*)"age").asInt(), (i32)42);
    check("active", root.get((u8*)"active").asBool() ? (i32)1 : (i32)0, (i32)1);

    // nested array
    UXJSONValue* tags = root.get((u8*)"tags");
    check("tags is array", tags.valueType(), (i32)JV_ARR);
    check("three tags", tags.count(), (i32)3);
    eq("tag 0", tags.at((i32)0).asString(), (u8*)"a");
    eq("tag 2", tags.at((i32)2).asString(), (u8*)"c");

    // nested object with a negative number
    UXJSONValue* meta = root.get((u8*)"meta");
    check("meta.x", meta.get((u8*)"x").asInt(), (i32)1);
    check("meta.y negative", meta.get((u8*)"y").asInt(), (i32)-3);

    // absent key
    check("missing key -> null ptr", root.get((u8*)"nope") == (UXJSONValue*)0 ? (i32)1 : (i32)0, (i32)1);
    check("has name", root.has((u8*)"name") ? (i32)1 : (i32)0, (i32)1);

    // round-trip: serialize a parsed doc back and re-parse -> same values
    u8* out = UXJSON.serialize(root);
    UXJSONValue* again = UXJSON.parse(out);
    check("re-parse ok", again != (UXJSONValue*)0 ? (i32)1 : (i32)0, (i32)1);
    eq("round-trip name", again.get((u8*)"name").asString(), (u8*)"Ada");
    check("round-trip age", again.get((u8*)"age").asInt(), (i32)42);
    check("round-trip meta.y", again.get((u8*)"meta").get((u8*)"y").asInt(), (i32)-3);
    check("round-trip tags count", again.get((u8*)"tags").count(), (i32)3);

    // simple scalars + escapes
    eq("serialize a number", UXJSON.serialize(UXJSON.parse((u8*)"-17")), (u8*)"-17");
    UXJSONValue* esc = UXJSON.parse((u8*)"{\"path\":\"a\\/b\\nc\"}");
    check("escaped string parsed", esc.get((u8*)"path").asString() != (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // whitespace tolerance
    UXJSONValue* ws = UXJSON.parse((u8*)"  {  \"k\" : [ 1 , 2 ]  }  ");
    check("whitespace tolerated", ws.get((u8*)"k").count(), (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXJSON — objects, arrays, nesting, numbers, bools, escapes, round-trip.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
