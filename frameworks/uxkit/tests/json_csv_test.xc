// json_csv_test.xc — the `json-csv` gate.
//
// UXJSON.serialize used to emit string contents RAW, so any value containing a
// quote or a backslash produced invalid JSON — {"say":"he said "hi""} — and the
// round trip was silently lossy.  Worse, measure() sized the buffer from the
// unescaped length, so a correct serializer bolted on afterwards would overrun
// it.  Both halves are fixed; these assertions are what stops it coming back.
//
// The interesting cases are all about text that contains the DELIMITERS of the
// format it is being written into, which is exactly the text nobody tests with.
#import <Stdio.xc>
#import "UXJSON.xc"
#import "UXCSV.xc"

i32 gFail = (i32)0;

void check(u8* what, bool cond)
    {
    if (!cond)
        {
        gFail = gFail + (i32)1;
        Stdio.printf("  FAIL %s\n", what);
        }
    else
        {
        Stdio.printf("  ok   %s\n", what);
        }
    }
void checkStr(u8* what, u8* got, u8* want)
    {
    bool same = UXJSON.streq(got, want);
    if (!same)
        {
        gFail = gFail + (i32)1;
        Stdio.printf("  FAIL %s\n       got  %s\n       want %s\n", what, got, want);
        }
    else
        {
        Stdio.printf("  ok   %s\n", what);
        }
    }

void jsonTests(void)
    {
    Stdio.printf("json:\n");

    // A quote inside a value must come back out escaped, and re-parse.
    UXJSONValue* v = UXJSON.parse((u8*)"{\"say\":\"he said \\\"hi\\\"\"}");
    check((u8*)"parse quoted value", v != (UXJSONValue*)0);
    checkStr((u8*)"value unescaped on parse", v.get((u8*)"say").asString(), (u8*)"he said \"hi\"");
    u8* out = UXJSON.serialize(v);
    checkStr((u8*)"value re-escaped on serialize", out, (u8*)"{\"say\":\"he said \\\"hi\\\"\"}");

    // Serialize -> parse -> serialize must be a fixed point, not merely valid.
    UXJSONValue* again = UXJSON.parse(out);
    check((u8*)"output re-parses", again != (UXJSONValue*)0);
    checkStr((u8*)"round trip is stable", UXJSON.serialize(again), out);

    // Backslash, newline and tab.
    UXJSONValue* w = UXJSON.parse((u8*)"{\"p\":\"C:\\\\Users\",\"m\":\"a\\nb\\tc\"}");
    checkStr((u8*)"backslash unescaped", w.get((u8*)"p").asString(), (u8*)"C:\\Users");
    checkStr((u8*)"control chars re-escaped", UXJSON.serialize(w),
             (u8*)"{\"p\":\"C:\\\\Users\",\"m\":\"a\\nb\\tc\"}");

    // KEYS need escaping too — the half that is easy to forget.
    UXJSONValue* k = UXJSON.parse((u8*)"{\"a\\\"b\":1}");
    check((u8*)"escaped key is findable", k.has((u8*)"a\"b"));
    checkStr((u8*)"escaped key re-emitted", UXJSON.serialize(k), (u8*)"{\"a\\\"b\":1}");

    // \b and \f, which the parser gained alongside the serializer.
    UXJSONValue* bf = UXJSON.parse((u8*)"{\"x\":\"a\\bb\\fc\"}");
    checkStr((u8*)"\\b and \\f round trip", UXJSON.serialize(bf), (u8*)"{\"x\":\"a\\bb\\fc\"}");

    // Documented limits, asserted so the docs cannot drift from the code.
    UXJSONValue* n = UXJSON.parse((u8*)"{\"a\":3.7,\"b\":-3.7}");
    check((u8*)"fraction truncates toward zero", n.get((u8*)"a").asInt() == (i32)3 && n.get((u8*)"b").asInt() == (i32)-3);
    check((u8*)"exponent notation is refused", UXJSON.parse((u8*)"{\"a\":1e3}") == (UXJSONValue*)0);
    UXJSONValue* u = UXJSON.parse((u8*)"{\"u\":\"\\u0041\"}");
    checkStr((u8*)"\\uXXXX is not decoded", u.get((u8*)"u").asString(), (u8*)"u0041");

    // Nesting and the empty containers.
    UXJSONValue* deep = UXJSON.parse((u8*)"{\"a\":[1,{\"b\":[]},{}],\"c\":null}");
    checkStr((u8*)"nesting round trips", UXJSON.serialize(deep),
             (u8*)"{\"a\":[1,{\"b\":[]},{}],\"c\":null}");
    check((u8*)"missing key is null", deep.get((u8*)"nope") == (UXJSONValue*)0);
    }

void csvTests(void)
    {
    Stdio.printf("csv:\n");

    // A quoted field containing a comma, a doubled quote and a newline.
    Array<UXCSVRow>* rows = UXCSV.parse((u8*)"a,\"b,c\",\"say \"\"hi\"\"\"\nd,e,f");
    check((u8*)"two rows", (i32)rows.count() == (i32)2);
    UXCSVRow* r0 = (UXCSVRow* ?)rows.get((u16)0);
    check((u8*)"three fields", r0.count() == (i32)3);
    checkStr((u8*)"comma inside quotes", r0.field((i32)1), (u8*)"b,c");
    checkStr((u8*)"doubled quote unescaped", r0.field((i32)2), (u8*)"say \"hi\"");

    // Serialize quotes only what needs it, and the result re-parses identically.
    u8* out = UXCSV.serialize(rows);
    checkStr((u8*)"quoted only where needed", out, (u8*)"a,\"b,c\",\"say \"\"hi\"\"\"\nd,e,f");
    Array<UXCSVRow>* again = UXCSV.parse(out);
    checkStr((u8*)"round trip is stable", UXCSV.serialize(again), out);

    // An embedded newline stays inside its field rather than starting a row.
    Array<UXCSVRow>* nl = UXCSV.parse((u8*)"x,\"line1\nline2\",z");
    check((u8*)"embedded newline does not split the row", (i32)nl.count() == (i32)1);
    checkStr((u8*)"embedded newline preserved",
             ((UXCSVRow* ?)nl.get((u16)0)).field((i32)1), (u8*)"line1\nline2");

    // Empty fields are fields — the CSV analogue of UXText.split.
    Array<UXCSVRow>* empties = UXCSV.parse((u8*)"a,,c");
    check((u8*)"empty field is a field", ((UXCSVRow* ?)empties.get((u16)0)).count() == (i32)3);
    checkStr((u8*)"empty field is empty",
             ((UXCSVRow* ?)empties.get((u16)0)).field((i32)1), (u8*)"");
    }

void main(void)
    {
    jsonTests();
    csvTests();
    if (gFail == (i32)0)
        {
        Stdio.printf("== json-csv: OK ==\n");
        }
    else
        {
        Stdio.printf("== json-csv: %d FAILED ==\n", gFail);
        }
    }
