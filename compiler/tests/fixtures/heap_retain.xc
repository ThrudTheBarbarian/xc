// heap_retain.xc — reference-count coverage, driven by ARC.
//
// This used to exercise the `retain` / `release` / `delete` keywords on class
// instances directly, under `-farc=off`. That flag is retired (bug 026: it
// never reached the IR lowering, so every fixture carrying it was an ARC build
// regardless), and manual lifetime management of a class instance is now
// rejected outright — the compiler owns those refcounts.
//
// The refcount BEHAVIOUR is still worth pinning, so it is exercised the way a
// program can actually reach it now: through aliasing and scope exit. A second
// strong binding is a retain, leaving the scope is the matching release, and
// the last one out runs dealloc.
//
// Test surface:
//   T1   an object whose only binding dies at scope exit is freed
//   T2   a second strong alias keeps it alive past the first binding's death
//   T3   dropping the survivor frees it
//   T4   three nested strong bindings still dealloc exactly once
//   T5   an object passed to and returned from a call is not freed in between
//   T6   a null strong pointer going out of scope frees nothing

#import "Stdio.xc"
#import "Assert.xc"

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }
}

u16 deallocCount;

// Takes a borrowed reference and hands it straight back; the object must
// survive the round trip.
Tracker* passthrough(Tracker* t)
{
    return t;
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    // ── T1: sole binding dies at scope exit → dealloc runs ──
    {
        Tracker* a = new Tracker();
        a.tag = 1;
        Assert.isEqual(a.tag, 1);
    }
    Assert.isEqual(deallocCount, 1);

    // ── T2: a second strong alias outlives the first binding ──
    Tracker* keep = 0;
    {
        Tracker* b = new Tracker();
        b.tag = 2;
        keep = b;                    // refcount 1 → 2
    }                                // b dies: 2 → 1, no dealloc
    Assert.isEqual(deallocCount, 1);
    Assert.isEqual(keep.tag, 2);

    // ── T3: dropping the survivor frees it ──
    keep = 0;                        // refcount 1 → 0 → dealloc
    Assert.isEqual(deallocCount, 2);

    // ── T4: three strong bindings, still exactly one dealloc ──
    {
        Tracker* c = new Tracker();
        c.tag = 3;
        {
            Tracker* d = c;          // refcount 2
            {
                Tracker* e = d;      // refcount 3
                Assert.isEqual(e.tag, 3);
            }                        // → 2
        }                            // → 1
        Assert.isEqual(deallocCount, 2);
    }                                // → 0, dealloc
    Assert.isEqual(deallocCount, 3);

    // ── T5: an object survives being passed to and returned from a call ──
    {
        Tracker* f = new Tracker();
        f.tag = 4;
        Tracker* g = passthrough(f);
        Assert.isEqual(g.tag, 4);
        Assert.isEqual(deallocCount, 3);
    }
    Assert.isEqual(deallocCount, 4);

    // ── T6: a null strong pointer leaving scope frees nothing ──
    {
        Tracker* h = 0;
        Assert.isNull((pointer)h);
    }
    Assert.isEqual(deallocCount, 4);

    Stdio.printf("deallocs=%u\n", deallocCount);

    Assert.summary();
    return;
}
