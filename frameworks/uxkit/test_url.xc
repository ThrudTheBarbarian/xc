// test_url.xc — UXURL parsing + rebuild.
#import <Stdio.xc>
#import "UXURL.xc"

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

    UXURL* u = UXURL.parse((u8*)"https://example.com:8080/path/to/page?q=1&x=2#section");
    eq("scheme", u.scheme, (u8*)"https");
    eq("host", u.host, (u8*)"example.com");
    check("port", u.port, (i32)8080);
    eq("path", u.path, (u8*)"/path/to/page");
    eq("query", u.query, (u8*)"q=1&x=2");
    eq("fragment", u.fragment, (u8*)"section");
    eq("round-trips", u.toString(), (u8*)"https://example.com:8080/path/to/page?q=1&x=2#section");
    eq("last path component", u.lastPathComponent(), (u8*)"page");

    // no port, no query/fragment
    UXURL* u2 = UXURL.parse((u8*)"http://host/a/b");
    eq("host2", u2.host, (u8*)"host");
    check("no port -> -1", u2.port, (i32)-1);
    eq("path2", u2.path, (u8*)"/a/b");
    check("empty query", (i32)UXURL.slen(u2.query), (i32)0);
    eq("round-trips2", u2.toString(), (u8*)"http://host/a/b");

    // file URL
    UXURL* f = UXURL.parse((u8*)"file:///Users/ada/doc.txt");
    check("is file url", f.isFileURL() ? (i32)1 : (i32)0, (i32)1);
    eq("file path", f.path, (u8*)"/Users/ada/doc.txt");
    check("empty host for file", (i32)UXURL.slen(f.host), (i32)0);
    eq("file last component", f.lastPathComponent(), (u8*)"doc.txt");

    // constructed file URL
    UXURL* made = UXURL.fileURL((u8*)"/tmp/x.png");
    eq("made file url string", made.toString(), (u8*)"file:///tmp/x.png");

    // query without fragment
    UXURL* q = UXURL.parse((u8*)"https://s/search?term=cats");
    eq("query only", q.query, (u8*)"term=cats");
    check("no fragment", (i32)UXURL.slen(q.fragment), (i32)0);

    // scheme-less (relative) path
    UXURL* rel = UXURL.parse((u8*)"/just/a/path");
    check("no scheme", (i32)UXURL.slen(rel.scheme), (i32)0);
    eq("relative path", rel.path, (u8*)"/just/a/path");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXURL — scheme/host/port/path/query/fragment, file URLs, round-trip, relative.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
