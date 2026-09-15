// data.xc — UXJSON and UXCSV: reading and writing the two text formats a UI
// actually meets, and what each one does with text containing its delimiters.
//
// Pure string work: no driver, no window, no disk.
#import <Stdio.xc>
#import "UXJSON.xc"
#import "UXCSV.xc"

void main(void) {
    // ---- JSON ------------------------------------------------------------
    u8* text = (u8*)"{\"title\":\"Rocks\",\"zoom\":150,\"grid\":true,"
                    "\"origin\":[10,20],\"font\":null}";

    UXJSONValue* doc = UXJSON.parse(text);
    if (doc == (UXJSONValue*)0) { Stdio.printf("parse failed\n"); return; }

    Stdio.printf("title=%s zoom=%d grid=%d\n",
                 doc.get((u8*)"title").asString(),
                 doc.get((u8*)"zoom").asInt(),
                 doc.get((u8*)"grid").asBool() ? 1 : 0);

    UXJSONValue* origin = doc.get((u8*)"origin");
    Stdio.printf("origin count=%d [%d,%d]\n",
                 origin.count(), origin.at((i32)0).asInt(), origin.at((i32)1).asInt());

    // A missing key is null rather than an error, so has() is the guard.
    Stdio.printf("has(title)=%d has(nope)=%d get(nope)=%d\n",
                 doc.has((u8*)"title") ? 1 : 0, doc.has((u8*)"nope") ? 1 : 0,
                 doc.get((u8*)"nope") == (UXJSONValue*)0 ? 0 : 1);

    Stdio.printf("re-serialised: %s\n", UXJSON.serialize(doc));

    // Text containing the format's own delimiters is the case that matters:
    // quotes and backslashes are escaped on the way out, so the output is JSON
    // and parses back to exactly what went in.
    UXJSONValue* awkward = UXJSON.parse(
        (u8*)"{\"say\":\"he said \\\"hi\\\"\",\"path\":\"C:\\\\Users\",\"two\":\"a\\nb\"}");
    u8* out = UXJSON.serialize(awkward);
    Stdio.printf("awkward: %s\n", out);
    Stdio.printf("stable:  %s\n", UXJSON.serialize(UXJSON.parse(out)));
    Stdio.printf("say is really: [%s]\n", awkward.get((u8*)"say").asString());

    // Numbers are INTEGERS: a fraction is truncated toward zero and does not
    // survive a round trip.
    UXJSONValue* nums = UXJSON.parse((u8*)"{\"a\":3.7,\"b\":-3.7}");
    Stdio.printf("3.7 -> %d   -3.7 -> %d   reserialised: %s\n",
                 nums.get((u8*)"a").asInt(), nums.get((u8*)"b").asInt(),
                 UXJSON.serialize(nums));

    // A malformed document is null, not a partial tree.
    Stdio.printf("bad input: %d   exponent: %d\n",
                 UXJSON.parse((u8*)"{\"a\":") == (UXJSONValue*)0 ? 0 : 1,
                 UXJSON.parse((u8*)"{\"a\":1e3}") == (UXJSONValue*)0 ? 0 : 1);

    // ---- CSV -------------------------------------------------------------
    // A quoted field may hold commas, doubled quotes and even newlines.
    Array<UXCSVRow>* rows = UXCSV.parse(
        (u8*)"name,note\nRocks,\"a, b\"\nGEM,\"say \"\"hi\"\"\"\nWeb,\"two\nlines\"");

    Stdio.printf("csv rows=%d\n", (i32)rows.count());
    for (u16 r = (u16)0; r < rows.count(); r = r + (u16)1) {
        UXCSVRow* row = (UXCSVRow* ?)rows.get(r);
        Stdio.printf("  row %d fields=%d:", (i32)r, row.count());
        for (i32 c = (i32)0; c < row.count(); c = c + (i32)1) {
            Stdio.printf(" [%s]", row.field(c));
        }
        Stdio.printf("\n");
    }

    // Serialising quotes a field only when it needs it, so ordinary data stays
    // readable and the awkward data stays correct.
    Stdio.printf("csv out:\n%s\n", UXCSV.serialize(rows));

    // Empty fields are fields, exactly as UXText.split keeps them.
    Array<UXCSVRow>* sparse = UXCSV.parse((u8*)"a,,c");
    UXCSVRow* s0 = (UXCSVRow* ?)sparse.get((u16)0);
    Stdio.printf("sparse fields=%d middle=[%s]\n", s0.count(), s0.field((i32)1));

    // Building a table to write out.
    Array<UXCSVRow>* made = new Array();
    UXCSVRow* head = new UXCSVRow();
    head.add((u8*)"key"); head.add((u8*)"value");
    made.add(head);
    UXCSVRow* r1 = new UXCSVRow();
    r1.add((u8*)"greeting"); r1.add((u8*)"hello, world");
    made.add(r1);
    Stdio.printf("built:\n%s\n", UXCSV.serialize(made));
}
