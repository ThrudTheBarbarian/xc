// foundation_csv.xc — CSV: quoted fields with separators, quotes and line
// breaks; every line ending; other separators; records by header; writing
// that quotes only when needed; and the errors for broken quoting.
#import "Foundation.xc"
#import "CSV.xc"

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
String* S(u8* c)
    {
    return String.withCString(c);
    }
bool is(Object* o, u8* want)
    {
    String* s = (String* ?)o;
    return s != 0 && s.equals(S(want));
    }
Array* rowsOf(u8* text, u8 sep)
    {
    try
        {
        return CSV.parseWith(S(text), sep);
        }
    catch (CSVError e)
        {
        Stdio.printf("  threw: %s\n", e.message().cString());
        }
    return new Array();
    }
// Parse and write back.
bool round(u8* text, u8* want)
    {
    String* s = CSV.stringify(rowsOf(text, (u8)','));
    bool ok = s.equals(S(want));
    if (!ok)
        Stdio.printf("  got [%s]\n", s.cString());
    return ok;
    }
void showError(u8* text)
    {
    try
        {
        CSV.parse(S(text));
        Stdio.printf("  (no error)\n");
        }
    catch (CSVError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    }

i32 main(void)
    {
    gFails = (i32)0;
    Array* rows = rowsOf("name,qty\r\n\"Smith, J\",3\r\n\"say \"\"hi\"\"\",\"two\nlines\"\r\n", (u8)',');
    check("three rows", rows.count() == 3);
    Array* r1 = (Array*)rows.get(1);
    check("quoted separator", is(r1.get(0), "Smith, J"));
    check("plain field", is(r1.get(1), "3"));
    Array* r2 = (Array*)rows.get(2);
    check("doubled quotes", is(r2.get(0), "say \"hi\""));
    check("line break in a field", is(r2.get(1), "two\nlines"));

    check("LF endings", rowsOf("a\nb\n", (u8)',').count() == 2);
    check("CR endings", rowsOf("a\rb", (u8)',').count() == 2);
    check("empty text has no rows", rowsOf("", (u8)',').count() == 0);
    Array* e = (Array*)rowsOf(",,\n", (u8)',').get(0);
    check("empty fields kept", e.count() == 3 && is(e.get(2), ""));
    Array* blank = (Array*)rowsOf("a\n\nb\n", (u8)',').get(1);
    check("blank line is one empty field", blank.count() == 1 && is(blank.get(0), ""));
    Array* sp = (Array*)rowsOf(" a , b ", (u8)',').get(0);
    check("spaces kept", is(sp.get(0), " a ") && is(sp.get(1), " b "));
    Array* t = (Array*)rowsOf("x\ty,z\n", (u8)'\t').get(0);
    check("tab separated", t.count() == 2 && is(t.get(1), "y,z"));

    Array* recs = CSV.records(rowsOf("id,name\n1,ann\n2\n", (u8)','));
    check("records", recs.count() == 2);
    Map* m0 = (Map*)recs.get(0);
    check("record field", is(m0.get(S("name")), "ann"));
    Map* m1 = (Map*)recs.get(1);
    check("short row padded", is(m1.get(S("name")), ""));

    check("round trip", round("name,qty\r\n\"Smith, J\",3\r\n", "name,qty\n\"Smith, J\",3\n"));
    check("quotes only when needed", round("\"plain\",\"a\"\"b\"\n", "plain,\"a\"\"b\"\n"));
    Array* mixed = new Array();
    Array* row = new Array();
    row.add(Number.withI32((i32)42));
    row.add(Null.null());
    row.add(S("x;y"));
    mixed.add(row);
    check("objects and Null", CSV.stringifyWith(mixed, (u8)';').equals(S("42;;\"x;y\"\n")));

    showError("a,\"open\nb");
    showError("\"a\"b,c");

    if (gFails == (i32)0)
        Stdio.printf("PASS\n");
    return gFails;
    }
