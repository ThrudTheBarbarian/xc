// test_host.xc — the parts of Xtg that are PURE LOGIC, tested on the HOST.
//
// While gemd is mid-build (and qemu will not boot), nothing that touches the AES can be
// run at all.  But UXGeom and UXStr need neither, and they are exactly where a silent
// error hides: an off-by-one in a rect union yields a damage rect that is subtly too
// SMALL, which shows up months later as "sometimes it doesn't repaint".
//
// UXGeom.unite is also precisely where the struct-ternary miscompile bit (XTC-BUGS §10),
// which is the whole argument for testing it rather than reading it.
//
//   xtc -A arm64 test_host.xc -o test_host && ./test_host
#import <Stdio.xc>
#import "UXGeometry.xc"
#import "UXString.xc"

i32 gFail;

void ck(u8* what, bool ok)
    {
    if (!ok)
        {
        gFail = gFail + (i32)1;
        Stdio.printf("  FAIL  %s\n", what);
        }
    else
        {
        Stdio.printf("  ok    %s\n", what);
        }
    }

void ckRect(u8* what, UXRect r, i16 x, i16 y, i16 w, i16 h)
    {
    bool ok = r.x == x && r.y == y && r.w == w && r.h == h;
    if (!ok)
        {
        gFail = gFail + (i32)1;
        Stdio.printf("  FAIL  %s: got %d,%d %dx%d  want %d,%d %dx%d\n",
                     what, r.x, r.y, r.w, r.h, x, y, w, h);
        }
    else
        {
        Stdio.printf("  ok    %s\n", what);
        }
    }

bool streq(u8* a, u8* b)
    {
    u16 i = (u16)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (u16)1;
        }
    return a[i] == b[i];
    }

void main(void)
    {
    gFail = (i32)0;

    Stdio.printf("UXGeom.unite — the damage rect (XTC-BUGS §10 bit here):\n");
    ckRect("disjoint, b right+below",
           UXGeom.unite(UXGeom.make((i16)10, (i16)10, (i16)5, (i16)5),
                        UXGeom.make((i16)20, (i16)20, (i16)5, (i16)5)),
           (i16)10, (i16)10, (i16)15, (i16)15);
    ckRect("b contained in a",
           UXGeom.unite(UXGeom.make((i16)0, (i16)0, (i16)100, (i16)100),
                        UXGeom.make((i16)10, (i16)10, (i16)5, (i16)5)),
           (i16)0, (i16)0, (i16)100, (i16)100);
    ckRect("EMPTY a is ignored (or every union snaps to 0,0)",
           UXGeom.unite(UXGeom.zero(),
                        UXGeom.make((i16)12, (i16)38, (i16)40, (i16)20)),
           (i16)12, (i16)38, (i16)40, (i16)20);
    ckRect("EMPTY b is ignored",
           UXGeom.unite(UXGeom.make((i16)12, (i16)38, (i16)40, (i16)20), UXGeom.zero()),
           (i16)12, (i16)38, (i16)40, (i16)20);
    ckRect("a is b",
           UXGeom.unite(UXGeom.make((i16)3, (i16)4, (i16)5, (i16)6),
                        UXGeom.make((i16)3, (i16)4, (i16)5, (i16)6)),
           (i16)3, (i16)4, (i16)5, (i16)6);
    ckRect("b left+above a (union must grow LEFT)",
           UXGeom.unite(UXGeom.make((i16)20, (i16)20, (i16)5, (i16)5),
                        UXGeom.make((i16)10, (i16)10, (i16)5, (i16)5)),
           (i16)10, (i16)10, (i16)15, (i16)15);

    Stdio.printf("UXGeom.intersects — the drawRect skip (a false NO = a view never repaints):\n");
    ck("touching edges do NOT intersect",
       !UXGeom.intersects(UXGeom.make((i16)0, (i16)0, (i16)10, (i16)10),
                          UXGeom.make((i16)10, (i16)0, (i16)10, (i16)10)));
    ck("one pixel of overlap DOES",
       UXGeom.intersects(UXGeom.make((i16)0, (i16)0, (i16)10, (i16)10),
                         UXGeom.make((i16)9, (i16)9, (i16)10, (i16)10)));
    ck("fully separate does not",
       !UXGeom.intersects(UXGeom.make((i16)0, (i16)0, (i16)5, (i16)5),
                          UXGeom.make((i16)50, (i16)50, (i16)5, (i16)5)));

    Stdio.printf("UXGeom.contains:\n");
    ck("top-left corner is inside", UXGeom.contains(UXGeom.make((i16)10, (i16)10, (i16)5, (i16)5), (i16)10, (i16)10));
    ck("bottom-right corner is OUT", !UXGeom.contains(UXGeom.make((i16)10, (i16)10, (i16)5, (i16)5), (i16)15, (i16)15));

    Stdio.printf("UXStr:\n");
    ck("fromInt(0)", streq(UXStr.fromInt((i32)0), "0"));
    ck("fromInt(42)", streq(UXStr.fromInt((i32)42), "42"));
    ck("fromInt(-7)", streq(UXStr.fromInt((i32)-7), "-7"));
    ck("fromInt(32767)", streq(UXStr.fromInt((i32)32767), "32767"));
    ck("fromHex(0)", streq(UXStr.fromHex((u32)0), "0"));
    ck("fromHex(0x1f)", streq(UXStr.fromHex((u32)31), "1f"));
    ck("fromHex(0xdead)", streq(UXStr.fromHex((u32)57005), "dead"));
    ck("cat with sep", streq(UXStr.cat("a", (u8)124, "b"), "a|b"));
    ck("cat: empty lhs takes NO separator", streq(UXStr.cat("", (u8)124, "b"), "b"));
    ck("append", streq(UXStr.append("obj ", "9"), "obj 9"));
    ck("len", UXStr.len("hello") == (u16)5);

    if (gFail == (i32)0)
        {
        Stdio.printf("PASS: %s\n", "all host checks");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFail);
        }
    }
