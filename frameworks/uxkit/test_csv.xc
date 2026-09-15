// test_csv.xc — UXCSV parse + serialize with quoting.
#import <Stdio.xc>
#import "UXCSV.xc"

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
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }
UXCSVRow* row(Array<UXCSVRow>* rows, i32 i)
    { return (UXCSVRow* ?)rows.get((u16)i);
    }

void main(void)
    {
    gFails = (i32)0;

    // simple grid
    Array* r = UXCSV.parse((u8*)"name,age,city\nAlice,34,NYC\nBob,28,LA");
    check("three rows", (i32)r.count(), (i32)3);
    check("header field count", row(r, (i32)0).count(), (i32)3);
    eq("header 0", row(r, (i32)0).field((i32)0), (u8*)"name");
    eq("row1 name", row(r, (i32)1).field((i32)0), (u8*)"Alice");
    eq("row1 age", row(r, (i32)1).field((i32)1), (u8*)"34");
    eq("row2 city", row(r, (i32)2).field((i32)2), (u8*)"LA");

    // quoted field containing a comma
    Array* q = UXCSV.parse((u8*)"\"Smith, Alice\",NYC");
    check("two fields despite the comma", row(q, (i32)0).count(), (i32)2);
    eq("quoted field keeps its comma", row(q, (i32)0).field((i32)0), (u8*)"Smith, Alice");
    eq("second field", row(q, (i32)0).field((i32)1), (u8*)"NYC");

    // doubled quotes -> a literal quote
    Array* dq = UXCSV.parse((u8*)"\"say \"\"hi\"\"\",x");
    eq("escaped quotes unescaped", row(dq, (i32)0).field((i32)0), (u8*)"say \"hi\"");
    eq("field after", row(dq, (i32)0).field((i32)1), (u8*)"x");

    // empty fields
    Array* e = UXCSV.parse((u8*)"a,,c");
    check("three fields with an empty middle", row(e, (i32)0).count(), (i32)3);
    eq("empty middle", row(e, (i32)0).field((i32)1), (u8*)"");

    // CRLF line endings
    Array* crlf = UXCSV.parse((u8*)"a,b\r\nc,d");
    check("crlf: two rows", (i32)crlf.count(), (i32)2);
    eq("crlf row2 field0", row(crlf, (i32)1).field((i32)0), (u8*)"c");

    // serialize: a field needing quotes gets them, a plain one doesn't
    Array* out = new Array();
    UXCSVRow* h = new UXCSVRow();
    h.add((u8*)"name");
    h.add((u8*)"note");
    out.add(h);
    UXCSVRow* d = new UXCSVRow();
    d.add((u8*)"Bob");
    d.add((u8*)"has, comma");
    out.add(d);
    eq("serialized", UXCSV.serialize(out), (u8*)"name,note\nBob,\"has, comma\"");

    // round-trip: parse(serialize(x)) preserves fields
    Array* rt = UXCSV.parse(UXCSV.serialize(out));
    eq("round-trip quoted field", row(rt, (i32)1).field((i32)1), (u8*)"has, comma");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXCSV — grid, quoted fields, escaped quotes, empties, CRLF, serialize, round-trip.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
