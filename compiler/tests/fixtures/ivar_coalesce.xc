// ivar_coalesce.xc — exercises the per-region ivar-bracket coalescing
// pass on cloaked / xe-banked-heap-method emission. A method that
// reads several ivars back-to-back (no JSR between) should hit the
// optimiser's coalesce path: one PORTB save/set/restore around the
// run, plain (self),Y inside.
//
// Before the pass: each ivar load is `JSR _ivar_load_byte` (24+
// cycles bracket overhead per byte). After: bracket once around the
// whole run, plain LDA (selfPtr),Y inside.
//
// Byte-level correctness is the bar — the coalesced output must be
// observably equivalent to the per-call helper version. We verify
// by reading 4 ivars in one method and checking the sum against the
// known-good value computed at construction time.

#import "Stdio.xc"
#import "Assert.xc"

class Rect {
    u8 x;
    u8 y;
    u8 w;
    u8 h;

    void init(u8 ix, u8 iy, u8 iw, u8 ih) : cloaked
    {
        x = ix; y = iy; w = iw; h = ih;
        return;
    }

    // Hot reader: 4 consecutive ivar loads with no JSR between.
    // The coalesce pass should fold these into one bracket.
    u16 sum(void) : cloaked
    {
        u16 s;
        s = (u16)x + (u16)y + (u16)w + (u16)h;
        return s;
    }

    // Hot writer: 4 consecutive ivar stores with no JSR between.
    void scale2(void) : cloaked
    {
        x = x * 2;
        y = y * 2;
        w = w * 2;
        h = h * 2;
        return;
    }
}

void main(void)
{
    Assert.reset();
    Rect* r = new Rect();
    r.init((u8)10, (u8)20, (u8)30, (u8)40);

    // T1: reader path — coalesced 4 loads should match per-call helper.
    Assert.isEqual(r.sum(), (u16)100);

    // T2: writer path — coalesced 4 stores should still be observable
    // through subsequent reads.
    r.scale2();
    Assert.isEqual(r.sum(), (u16)200);

    Assert.summary();
    return;
}
