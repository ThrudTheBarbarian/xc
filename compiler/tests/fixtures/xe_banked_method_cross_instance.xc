// xe_banked_method_cross_instance.xc — Phase 1c: a `:banked`
// method on instance A calls a `:banked` method on a different
// instance B (passed as parameter). The nested call must save
// A's self-pointer + bank, restore PORTB to B's bank, run B's
// body, then restore back to A — all through the cloaked-
// bracket wrapper.
#import "Stdio.xc"
#import "Assert.xc"

class Sink
{
    u16 store;
    void absorb(u16 v) :banked  { store = store + v; }
    u16 total(void) :banked     { return store; }
}

class Source
{
    u16 emitted;

    void pump(banked:Sink* dst, u16 n) :banked
    {
        u16 i;
        for (i = 0; i < n; i = i + 1) {
            dst.absorb(i);
            emitted = emitted + 1;
        }
    }
}

void main(void)
{
    Assert.reset();
    Sink* s = new Sink();
    Source* src = new Source();
    src.pump(s, 5);
    Assert.isEqual(s.total(), 10);
    Assert.summary();
    return;
}
