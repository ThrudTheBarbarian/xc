// test_text.xc — UXText string utilities: trim, split, tokenize, join, case, predicates.
#import <Stdio.xc>
#import "UXText.xc"
#import "UXCharacterSet.xc"

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
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // trim
    eq("trim whitespace", UXText.trimWhitespace((u8*)"  hello  "), (u8*)"hello");
    eq("trim tabs/newlines", UXText.trimWhitespace((u8*)"\t\nhi\n"), (u8*)"hi");
    eq("nothing to trim", UXText.trimWhitespace((u8*)"abc"), (u8*)"abc");

    // split on a char (keeps empty fields)
    Array* parts = UXText.split((u8*)"a,b,c", (u8)',');
    check("split count", (i32)parts.count(), (i32)3);
    eq("split[0]", UXText.partAt(parts, (i32)0), (u8*)"a");
    eq("split[2]", UXText.partAt(parts, (i32)2), (u8*)"c");
    Array* empties = UXText.split((u8*)"a,,c", (u8)',');
    check("empty field preserved", (i32)empties.count(), (i32)3);
    eq("empty middle", UXText.partAt(empties, (i32)1), (u8*)"");

    // tokenize (drops empties, splits on any set char)
    Array* toks = UXText.tokenize((u8*)"  the  quick fox ", UXCharacterSet.whitespace());
    check("token count", (i32)toks.count(), (i32)3);
    eq("token 0", UXText.partAt(toks, (i32)0), (u8*)"the");
    eq("token 2", UXText.partAt(toks, (i32)2), (u8*)"fox");

    // join
    eq("join dash", UXText.join(parts, (u8*)"-"), (u8*)"a-b-c");
    eq("join empty sep", UXText.join(parts, (u8*)""), (u8*)"abc");

    // split then join round-trips
    eq("split/join round-trip", UXText.join(UXText.split((u8*)"x/y/z", (u8)'/'), (u8*)"/"), (u8*)"x/y/z");

    // case
    eq("upper", UXText.toUpper((u8*)"Hello123"), (u8*)"HELLO123");
    eq("lower", UXText.toLower((u8*)"Hello123"), (u8*)"hello123");

    // predicates
    check("hasPrefix", UXText.hasPrefix((u8*)"hello", (u8*)"he") ? (i32)1 : (i32)0, (i32)1);
    check("not hasPrefix", UXText.hasPrefix((u8*)"hello", (u8*)"xy") ? (i32)1 : (i32)0, (i32)0);
    check("hasSuffix", UXText.hasSuffix((u8*)"report.txt", (u8*)".txt") ? (i32)1 : (i32)0, (i32)1);
    check("contains", UXText.contains((u8*)"hello world", (u8*)"o w") ? (i32)1 : (i32)0, (i32)1);
    check("not contains", UXText.contains((u8*)"hello", (u8*)"z") ? (i32)1 : (i32)0, (i32)0);

    // replace
    eq("replace char", UXText.replaceChar((u8*)"a.b.c", (u8)'.', (u8)'/'), (u8*)"a/b/c");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXText — trim, split, tokenize, join, case, prefix/suffix/contains, replace.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
