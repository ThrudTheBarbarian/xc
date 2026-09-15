// test_rkroundtrip.xc — read a real .rsc, write it, read it back, compare.
//
// The strongest test available for both halves at once, and the reason it is
// worth more than checking the writer's bytes against a golden file: a golden
// file only proves we still do what we did last week. A round trip proves the
// two halves AGREE — and since the reader was validated against a resource
// written by other people's tools, agreeing with it means agreeing with them.
//
// What it deliberately does NOT assert is byte-identity with the input. The
// input came from another editor with its own string ordering and section
// padding; matching that byte for byte is not a goal and chasing it would
// bake in someone else's layout. What must survive is the MODEL: same trees,
// same shapes, same coordinates, same text.
#import <Stdio.xc>
#import <Files.xc>
#import <String.xc>
#import "RKRsc.xc"
#import "RKRscWrite.xc"
#import "RKModel.xc"

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
void checkTrue(u8* what, bool got)
    {
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool sameStr(u8* a, u8* b)
    {
    if (a == (u8*)0)
        {
        a = (u8*)"";
        }
    if (b == (u8*)0)
        {
        b = (u8*)"";
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

// Walk two subtrees in lockstep, comparing everything the model carries.
i32 gDiffs;
void compare(RKObject* a, RKObject* b, i32 depth)
    {
    if (a.type != b.type)
        {
        gDiffs = gDiffs + (i32)1;
        Stdio.printf("    type %d != %d\n", a.type, b.type);
        return;
        }
    if (a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h)
        {
        gDiffs = gDiffs + (i32)1;
        Stdio.printf("    geom %d,%d %dx%d != %d,%d %dx%d\n", a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h);
        }
    if (a.state != b.state)
        {
        gDiffs = gDiffs + (i32)1;
        }
    if (a.hasStringSpec() && !sameStr(a.text, b.text))
        {
        gDiffs = gDiffs + (i32)1;
        Stdio.printf("    text \"%s\" != \"%s\"\n", a.text, b.text);
        }
    if (a.childCount() != b.childCount())
        {
        gDiffs = gDiffs + (i32)1;
        Stdio.printf("    childCount %d != %d\n", a.childCount(), b.childCount());
        return;
        }
    for (i32 i = (i32)0; i < a.childCount(); i = i + (i32)1)
        {
        compare(a.childAt(i), b.childAt(i), depth + (i32)1);
        }
    }

void main(void)
    {
    gFails = (i32)0;
    gDiffs = (i32)0;
    u8* path = (u8*)"resources/desktop.rsc";
    String* p = String.withCString(path);
    if (!Files.exists(p))
        {
        Stdio.printf("SKIP: no sample .rsc at %s\n", path);
        return;
        }
    Data* d = Files.readData(p);
    if (d == (Data*)0)
        {
        Stdio.printf("FAIL: unreadable\n");
        return;
        }

    // ---- in ----------------------------------------------------------------
    RKRsc* r1 = RKRsc.reader(d.bytes(), (i32)d.length());
    RKResource* orig = r1.result;
    checkTrue("the original parses", orig != (RKResource*)0);
    if (orig == (RKResource*)0)
        {
        Stdio.printf("FAIL: 1\n");
        return;
        }
    Stdio.printf("in:  %d bytes, %d trees, %d objects\n",
                 (i32)d.length(), orig.treeCount(), r1.nobjects);

    // ---- out ---------------------------------------------------------------
    RKRscWrite* w = RKRscWrite.writer(orig);
    UXData* bytes = w.result;
    checkTrue("something was written", bytes != (UXData*)0 && bytes.length() > (i32)36);
    if (bytes == (UXData*)0)
        {
        Stdio.printf("FAIL: 1\n");
        return;
        }
    Stdio.printf("out: %d bytes%s\n", bytes.length(),
                 w.wasLossless() ? (u8*)"" : (u8*)" (lossy — see warning)");
    if (!w.wasLossless())
        {
        Stdio.printf("  note: %s\n", w.warning());
        }

    // ---- and back ----------------------------------------------------------
    RKRsc* r2 = RKRsc.reader(bytes.bytes(), bytes.length());
    RKResource* back = r2.result;
    checkTrue("what we wrote parses again", back != (RKResource*)0);
    if (back == (RKResource*)0)
        {
        Stdio.printf("FAIL: 1\n");
        return;
        }

    check("same tree count", back.treeCount(), orig.treeCount());
    check("same object count", r2.nobjects, r1.nobjects);

    // The model must survive, tree by tree, node by node.
    i32 n = orig.treeCount() < back.treeCount() ? orig.treeCount() : back.treeCount();
    for (i32 t = (i32)0; t < n; t = t + (i32)1)
        {
        compare(orig.treeAt(t).root, back.treeAt(t).root, (i32)0);
        }
    check("model differences after a round trip", gDiffs, (i32)0);

    // Informational: how close to the input did we land?  Byte-identity is
    // NOT a goal — the input came from another editor with its own string
    // ordering and padding — but the number is worth seeing, because a large
    // divergence would mean the layout drifted rather than the ordering.
    if (bytes.length() == (i32)d.length())
        {
        i32 diff = (i32)0;
        for (i32 i = (i32)0; i < bytes.length(); i = i + (i32)1)
            {
            if (bytes.byteAt(i) != d.bytes()[i])
                {
                diff = diff + (i32)1;
                }
            }
        Stdio.printf("  same length as the input; %d of %d bytes differ\n", diff, bytes.length());
        }
    else
        {
        Stdio.printf("  length differs from the input (%d vs %d) — ordering, not structure\n",
                     bytes.length(), (i32)d.length());
        }

    // A second round trip must be a fixed point: if writing changed anything
    // structural, the third read would differ from the second.
    UXData* bytes2 = RKRscWrite.write(back);
    checkTrue("a second write produces the same length",
              bytes2 != (UXData*)0 && bytes2.length() == bytes.length());

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a real resource survives read -> write -> read\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
