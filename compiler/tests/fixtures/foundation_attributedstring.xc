//xtc-na: xt6502 — AttributedString is not available on xt6502
// foundation_attributedstring.xc — AttributedString: attributes over ranges,
// merged runs, reading at a position, removing, replacing text, inserting,
// appending, substrings and equality.
#import "Foundation.xc"
#import "AttributedString.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
Range* R(i32 loc, i32 len)
    {
    return Range.make(loc, len);
    }
// "[text|k=v,k=v]" per run.
void show(u8* what, AttributedString* a)
    {
    Stdio.printf("%s:", what);
    String* t = a.text();
    for (u32 k = (u32)0; k < a.runCount(); k++)
        {
        Range* r = a.runRange(k);
        Map* m = a.runAttributes(k);
        Stdio.printf(" [%s|", t.substringBytes((u32)r.loc, (u32)r.len).cString());
        for (u32 i = (u32)0; i < m.count(); i++)
            {
            String* key = (String*)m.enumAt(i);
            Stdio.printf(i > (u32)0 ? ",%@=%@" : "%@=%@", key, m.get(key));
            }
        Stdio.printf("]");
        }
    Stdio.printf("\n");
    }

i32 main(void)
    {
    String* bold = S("bold");
    String* pen = S("pen");
    AttributedString* a = AttributedString.withString(S("Hello, world"));
    show("plain", a);
    a.setAttribute(bold, Number.withBool(true), R((i32)0, (i32)5));
    show("bold Hello", a);
    a.setAttribute(pen, Number.withI32((i32)2), R((i32)3, (i32)6));
    show("pen 2 over lo, w", a);
    a.setAttribute(bold, Number.withBool(true), R((i32)5, (i32)7));
    show("bold the rest", a);
    a.removeAttribute(pen, R((i32)0, (i32)12));
    show("pen removed", a);
    Stdio.printf("one run: %u, bold at 9: %@, pen at 9: %d\n", a.runCount(), a.attribute(bold, (i32)9),
                 (i32)(a.attribute(pen, (i32)9) == 0 ? 0 : 1));

    AttributedString* b = AttributedString.withString(S("one two three"));
    b.setAttribute(pen, Number.withI32((i32)3), R((i32)4, (i32)3));
    show("pen on two", b);
    Range* run = b.runRangeAt((i32)5);
    Stdio.printf("run at 5: %d+%d\n", run.loc, run.len);
    b.replace(R((i32)4, (i32)3), S("2"));
    show("two -> 2", b);
    b.replace(R((i32)5, (i32)0), S("22"));
    show("insert after 2", b);
    b.replace(R((i32)0, (i32)0), S(">"));
    show("insert at start", b);
    b.appendString(S("!"));
    show("append !", b);
    AttributedString* tail = AttributedString.withString(S(" end"));
    tail.setAttribute(bold, Number.withBool(true), R((i32)1, (i32)3));
    b.append(tail);
    show("append bold end", b);
    AttributedString* sub = b.substring(R((i32)4, (i32)6));
    show("substring 4+6", sub);

    AttributedString* c1 = AttributedString.withString(S("ab"));
    c1.setAttribute(bold, Number.withBool(true), R((i32)0, (i32)1));
    AttributedString* c2 = AttributedString.withString(S("ab"));
    c2.setAttribute(bold, Number.withBool(true), R((i32)0, (i32)1));
    Stdio.printf("equal %d, copy equal %d\n", (i32)(c1.equals(c2) ? 1 : 0), (i32)(c1.copy().equals(c1) ? 1 : 0));
    c2.setAttribute(bold, Number.withBool(true), R((i32)1, (i32)1));
    Stdio.printf("after change equal %d\n", (i32)(c1.equals(c2) ? 1 : 0));

    AttributedString* e = new AttributedString();
    e.appendString(S("x"));
    show("empty then x", e);
    return (i32)0;
    }
