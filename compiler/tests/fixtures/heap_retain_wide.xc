// heap_retain_wide.xc — exercise the 2-byte refcount field.
//
// The block header holds a 16-bit retain count. A count driven past 255 must
// not wrap — a wrap frees a live object once the count comes back down through
// zero, and the victim then surfaces far from the cause — and must not saturate
// early either.
//
// This used to drive the count with 300 explicit `retain` statements under
// `-farc=off`. That flag is retired (bug 026) and manual retain/release of a
// class instance is now rejected, so the count is driven the way a real program
// reaches it: 300 strong array slots holding the same object. Each store is a
// retain and each overwrite is the matching release, which makes this a better
// test than the keywords were — it is how a refcount actually gets large.
//
// Guard for bug 011-5 (arm64 widened this field 8→16 bit) and m68k phase-380.
//
// Test surface:
//   T1   300 strong aliases and no dealloc — the count has not wrapped
//   T2   the object is intact and reachable through a slot at 301 references
//   T3   clearing all 300 slots still leaves the original binding holding it,
//        which is precisely what a wrapped count would have got wrong
//   T4   dropping the last binding deallocs exactly once

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
Tracker* slots[300];

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    u16 i = 0;
    {
        Tracker* a = new Tracker();    // refcount = 1
        a.tag = 42;

        // ── T1: 300 strong slots → refcount = 301 ───────────────
        i = 0;
        while (i < 300)
        {
            slots[i] = a;              // each store retains
            i = i + 1;
        }
        Assert.isEqual(deallocCount, 0);             // T1

        // ── T2: intact at 301 references ────────────────────────
        Assert.isEqual(slots[299].tag, 42);          // T2

        // ── T3: clear all 300 → back to the single binding ──────
        i = 0;
        while (i < 300)
        {
            slots[i] = 0;              // each overwrite releases
            i = i + 1;
        }
        Assert.isEqual(deallocCount, 0);             // T3
        Assert.isEqual(a.tag, 42);
    }                                  // a dies: refcount 0

    // ── T4: exactly one dealloc, no wrap-driven early free ──────
    Assert.isEqual(deallocCount, 1);                 // T4

    Stdio.printf("cycles=%u deallocs=%u\n", i, deallocCount);

    Assert.summary();
    return;
}
