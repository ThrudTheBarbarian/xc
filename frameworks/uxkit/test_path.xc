// test_path.xc — UXPath: split, rebuild, extension, append/delete, normalize.
#import <Stdio.xc>
#import "UXPath.xc"

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

void main(void)
    {
    gFails = (i32)0;

    // parse + components
    UXPath* p = UXPath.parse((u8*)"/Users/ada/docs/report.txt");
    check("absolute", p.isAbsolute() ? (i32)1 : (i32)0, (i32)1);
    check("four components", p.count(), (i32)4);
    eq("component 0", p.component((i32)0), (u8*)"Users");
    eq("last component", p.lastComponent(), (u8*)"report.txt");
    eq("round-trips to string", p.toString(), (u8*)"/Users/ada/docs/report.txt");

    // extra slashes collapse; relative stays relative
    UXPath* r = UXPath.parse((u8*)"a//b/c");
    check("relative", r.isAbsolute() ? (i32)1 : (i32)0, (i32)0);
    check("empty parts dropped", r.count(), (i32)3);
    eq("relative round-trip", r.toString(), (u8*)"a/b/c");

    // extension
    eq("extension", p.pathExtension(), (u8*)"txt");
    eq("stem", p.lastComponentWithoutExtension(), (u8*)"report");
    eq("no extension", UXPath.parse((u8*)"/a/b/README").pathExtension(), (u8*)"");
    eq("dotfile has no extension", UXPath.parse((u8*)"/a/.bashrc").pathExtension(), (u8*)"");

    // append / delete
    eq("appending", UXPath.parse((u8*)"/a/b").appendingComponent((u8*)"c").toString(), (u8*)"/a/b/c");
    eq("deleting last", p.deletingLastComponent().toString(), (u8*)"/Users/ada/docs");
    check("original unchanged by delete (still 4)", p.count(), (i32)4);

    // normalize: resolve . and ..
    eq("resolve dot", UXPath.parse((u8*)"/a/./b").normalized().toString(), (u8*)"/a/b");
    eq("resolve dotdot", UXPath.parse((u8*)"/a/b/../c").normalized().toString(), (u8*)"/a/c");
    eq("resolve trailing dotdot", UXPath.parse((u8*)"/a/b/..").normalized().toString(), (u8*)"/a");
    eq("multiple dotdot", UXPath.parse((u8*)"/a/b/c/../../d").normalized().toString(), (u8*)"/a/d");
    eq("relative keeps leading dotdot", UXPath.parse((u8*)"../x").normalized().toString(), (u8*)"../x");
    eq("dotdot past root of absolute is dropped", UXPath.parse((u8*)"/../a").normalized().toString(), (u8*)"/a");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPath — split, round-trip, extension, append/delete, normalize.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
