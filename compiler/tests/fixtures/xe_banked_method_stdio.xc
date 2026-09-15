// xe_banked_method_stdio.xc — Phase 1c: a `:banked` heap-class
// method body that calls Stdio.printf (a `:cloaked` static-class
// library method). Cross-bank call: from a numbered code bank
// down to the cloaked-segment, both wrapped in their respective
// PORTB brackets. The Phase 2 substitution must give Stdio.printf
// $32 (cloaked-segment) and the banked method's bank a different
// PORTB literal — they resolve via the same `__xtc_portb_lit`
// machinery.
#import "Stdio.xc"
#import "Assert.xc"

class Reporter
{
    u16 count;

    void say(u16 v) :banked
    {
        count = count + 1;
        Stdio.printf("v=%u\n", v);
    }

    u16 howMany(void) :banked  { return count; }
}

void main(void)
{
    Assert.reset();
    Reporter* r = new Reporter();
    r.say(7);
    r.say(42);
    Assert.isEqual(r.howMany(), 2);
    Assert.summary();
    return;
}
