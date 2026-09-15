// test_rkrsc.xc — the .rsc reader, against a REAL file.
//
// The point of this gate is that it does not read a fixture we made up.  It
// reads the GEM desktop's own desktop.rsc — a file written by other tools,
// carrying the things real resources carry — because a reader that only ever
// sees its own writer's output is a reader that has not been tested.
//
// It reads resources/desktop.rsc relative to the working directory (run it
// from a GEM desktop checkout) and SKIPS cleanly when that file is absent.
#import <Stdio.xc>
#import <Files.xc>
#import <String.xc>
#import "RKRsc.xc"
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

// Every object in the tree, counted by walking the NESTED form — which is only
// correct if the reader rebuilt the nesting from head/tail properly.
i32 countNested(RKObject* o)
    {
    i32 n = (i32)1;
    for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
        {
        n = n + countNested(o.childAt(i));
        }
    return n;
    }

void main(void)
    {
    gFails = (i32)0;
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
        Stdio.printf("FAIL: could not read %s\n", path);
        return;
        }
    i32 n = (i32)d.length();
    Stdio.printf("read %d bytes from %s\n", n, path);

    RKRsc* rd = RKRsc.reader(d.bytes(), n);
    RKResource* res = rd.result;
    checkTrue("the file parses at all", res != (RKResource*)0);
    if (res == (RKResource*)0)
        {
        Stdio.printf("FAIL: 1\n");
        return;
        }

    checkTrue("it is big-endian, as a classic .rsc is", rd.be);
    checkTrue("at least one tree came out", res.treeCount() > (i32)0);
    Stdio.printf("  trees=%d  freeStrings=%d\n",
                 res.treeCount(), (i32)res.freeStrings.count());

    // Every tree must have a root, and the nesting must have been rebuilt —
    // a reader that read the flat array but not the links would give 1 here.
    i32 totalObjects = (i32)0;
    bool everyTreeHasRoot = true;
    bool someTreeHasChildren = false;
    for (i32 i = (i32)0; i < res.treeCount(); i = i + (i32)1)
        {
        RKTree* t = res.treeAt(i);
        if (t.root == (RKObject*)0)
            {
            everyTreeHasRoot = false;
            }
        else
            {
            i32 c = countNested(t.root);
            totalObjects = totalObjects + c;
            if (c > (i32)1)
                {
                someTreeHasChildren = true;
                }
            }
        }
    checkTrue("every tree has a root", everyTreeHasRoot);
    checkTrue("the nesting was rebuilt (a tree has children)", someTreeHasChildren);

    // THE guard, and the one that earned its place: every object in the file
    // must be reachable from exactly one tree, so walking the rebuilt nesting
    // has to total the header's own count.  When the links were read as
    // array-absolute rather than tree-relative this said 41 against a header
    // saying 33 — objects reached twice, from the wrong parents — while every
    // other check in this file still passed.
    check("nested objects total the header's count", totalObjects, rd.nobjects);

    // Coordinates unpack to sensible pixels: a root box should have real extent,
    // not the raw packed word.
    RKTree* t0 = res.treeAt((i32)0);
    checkTrue("the first tree's root has a positive width", t0.root.w > (i32)0);
    checkTrue("the first tree's root has a positive height", t0.root.h > (i32)0);
    checkTrue("and a plausible one (< 2000px)", t0.root.w < (i32)2000 && t0.root.h < (i32)2000);
    Stdio.printf("  root %dx%d at %d,%d\n", t0.root.w, t0.root.h, t0.root.x, t0.root.y);

    // An import must never be silently lossy: if payloads were skipped, the
    // reader has to SAY so rather than let a re-export quietly drop them.
    if (!rd.wasLossless())
        {
        Stdio.printf("  note: %s\n", rd.warning());
        checkTrue("a lossy import reports a warning", rd.warning() != (u8*)0);
        }
    else
        {
        Stdio.printf("  import was lossless\n");
        }

    // The parse must be stable: reading the same bytes twice gives the same shape.
    RKResource* again = RKRsc.read(d.bytes(), n);
    checkTrue("a second parse agrees on the tree count",
              again != (RKResource*)0 && again.treeCount() == res.treeCount());

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the .rsc reader parses a real resource\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
