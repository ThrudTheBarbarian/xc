// xe_banked_method_scope.xc — Phase 1c: ARC scope-exit cleanup
// of a local strong-class-pointer inside a `:banked` heap-class
// method body. The local `t` is +1-owned by the body; its
// scope-exit decref + dealloc must fire exactly once per call,
// counted via Tracker.dealloc.
#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

class Manager
{
    u16 hits;

    void run(void) :banked
    {
        Tracker* t = new Tracker();
        t.tag = 1;
        hits = hits + 1;
    }

    u16 count(void) :banked  { return hits; }
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;
    Manager* m = new Manager();
    m.run();
    m.run();
    m.run();
    Assert.isEqual(m.count(), 3);
    Assert.isEqual(deallocCount, 3);
    Assert.summary();
    return;
}
