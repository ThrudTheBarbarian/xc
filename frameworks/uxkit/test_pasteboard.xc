// test_pasteboard.xc — UXPasteboard: typed payloads, change count, general clipboard.
#import <Stdio.xc>
#import "UXPasteboard.xc"

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
        Stdio.printf("  ok   %s = \"%s\"\n", what, got == (u8*)0 ? (u8*)"(null)" : got);
        }
    else
        {
        Stdio.printf("  FAIL %s mismatch\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXPasteboard* pb = new UXPasteboard();
    check("starts empty", pb.typeCount(), (i32)0);
    check("change count 0", pb.changeCount, (i32)0);

    pb.writeText((u8*)"hello");
    eq("read text back", pb.text(), (u8*)"hello");
    check("has text type", pb.hasType((u8*)"public.utf8-plain-text") ? (i32)1 : (i32)0, (i32)1);
    check("one type", pb.typeCount(), (i32)1);
    check("change count bumped", pb.changeCount, (i32)1);

    // a second representation of the same copy
    pb.setString((u8*)"<b>hello</b>", (u8*)"public.html");
    check("two types now", pb.typeCount(), (i32)2);
    eq("html payload", pb.stringForType((u8*)"public.html"), (u8*)"<b>hello</b>");
    eq("text still there", pb.text(), (u8*)"hello");
    check("change count 2", pb.changeCount, (i32)2); // writeText + setString(html)

    // overwrite a type in place (no new entry, still bumps count)
    pb.writeText((u8*)"world");
    check("still two types after overwrite", pb.typeCount(), (i32)2);
    eq("overwritten text", pb.text(), (u8*)"world");
    check("change count 3", pb.changeCount, (i32)3);

    // preferredType picks the first present
    eq("prefer html when present", pb.preferredType((u8*)"public.html", (u8*)"public.utf8-plain-text"), (u8*)"public.html");
    eq("fall back to text", pb.preferredType((u8*)"public.rtf", (u8*)"public.utf8-plain-text"), (u8*)"public.utf8-plain-text");
    check("neither present -> null", pb.preferredType((u8*)"a", (u8*)"b") == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // missing type reads null
    check("missing type is null", pb.stringForType((u8*)"public.rtf") == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // clearContents wipes and bumps
    pb.clearContents();
    check("cleared to empty", pb.typeCount(), (i32)0);
    check("clear bumped count", pb.changeCount, (i32)4);
    check("text gone after clear", pb.text() == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // general pasteboard is a shared singleton
    UXPasteboard.general().writeText((u8*)"clip");
    eq("general clipboard shared", UXPasteboard.general().text(), (u8*)"clip");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPasteboard — typed payloads, change count, overwrite, preference, general clipboard.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
