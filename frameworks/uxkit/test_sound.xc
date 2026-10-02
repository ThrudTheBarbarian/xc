// test_sound.xc — the sound synthesiser, by what its samples say: the pitch (zero crossings), a slide
// (the pitch at the start against the end), the envelope (near the peak after the 12 ms attack, near
// silence at the end), a second note at its offset, and the boom (decaying, low-passed, the same
// samples every time).  Properties rather than exact samples, so the test does not depend on how a
// target's libm rounds a sine.
#import <Stdio.xc>
#import "UXSound.xc"

i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
// sign changes over [a, b) samples
i32 crossings(i16* s, i32 a, i32 b)
    {
    i32 c = (i32)0;
    for (i32 i = a + (i32)1; i < b; i = i + (i32)1)
        {
        if (((i32)s[i - (i32)1] < (i32)0) != ((i32)s[i] < (i32)0))
            {
            c = c + (i32)1;
            }
        }
    return c;
    }
i32 peak(i16* s, i32 a, i32 b)
    {
    i32 m = (i32)0;
    for (i32 i = a; i < b; i = i + (i32)1)
        {
        i32 v = (i32)s[i] < (i32)0 ? (i32)0 - (i32)s[i] : (i32)s[i];
        m = v > m ? v : m;
        }
    return m;
    }
i32 ms(i32 m) { return (m * (i32)UXSND_RATE) / (i32)1000; }

void main(void)
    {
    // pick(): a 520 Hz sine, 50 ms, volume 0.05
    UXSound* pick = new UXSound();
    pick.note((i32)UXSND_SINE, 520.0, 0.05, 0.05, 0.0, 0.0);
    i16* p = pick.samples();
    ck(pick.frameCount() == ms((i32)70) + (i32)1, "pick lasts 50 ms plus WebAudio's 20 ms stop margin", pick.frameCount());
    i32 zc = crossings(p, (i32)0, ms((i32)50));
    ck(zc >= (i32)50 && zc <= (i32)54, "pick is 520 Hz (52 crossings in 50 ms)", zc);
    i32 top = peak(p, ms((i32)10), ms((i32)16));
    ck(top >= (i32)1500 && top <= (i32)1640, "pick peaks at 0.05 of full scale after the 12 ms attack", top);
    ck(peak(p, (i32)0, ms((i32)1)) < (i32)40, "pick starts near silence (no click)", peak(p, (i32)0, ms((i32)1)));
    ck(peak(p, ms((i32)48), ms((i32)50)) < (i32)40, "pick has decayed to near silence at its end", peak(p, ms((i32)48), ms((i32)50)));

    // order(): a triangle sliding from 320 Hz up to 440 Hz over 90 ms
    UXSound* order = new UXSound();
    order.note((i32)UXSND_TRIANGLE, 320.0, 0.09, 0.07, 440.0, 0.0);
    i16* o = order.samples();
    i32 early = crossings(o, (i32)0, ms((i32)30));
    i32 late = crossings(o, ms((i32)60), ms((i32)90));
    ck(late > early + (i32)3, "order's pitch climbs over its length", late * (i32)100 + early);

    // wire(): 880 Hz, then 1170 Hz from 90 ms on
    UXSound* wire = new UXSound();
    wire.note((i32)UXSND_SINE, 880.0, 0.10, 0.07, 0.0, 0.0);
    wire.note((i32)UXSND_SINE, 1170.0, 0.14, 0.06, 0.0, 0.09);
    i16* w = wire.samples();
    ck(wire.frameCount() == ms((i32)250) + (i32)1, "wire lasts until its second note ends (90 + 140 + 20 ms)", wire.frameCount());
    i32 second = crossings(w, ms((i32)140), ms((i32)200));
    ck(second >= (i32)136 && second <= (i32)144, "wire's second note is 1170 Hz (140 crossings in 60 ms)", second);
    ck(peak(w, ms((i32)125), ms((i32)135)) > (i32)500, "and it sounds after the first has faded", peak(w, ms((i32)125), ms((i32)135)));

    // fight(): the boom
    UXSound* boom = new UXSound();
    boom.boom(0.16, 0.0);
    i16* b = boom.samples();
    i32 loud = peak(b, (i32)0, ms((i32)50));
    i32 quiet = peak(b, ms((i32)400), ms((i32)450));
    ck(loud > (i32)300 && loud < (i32)6000, "the boom is loud at first", loud);
    ck(quiet * (i32)10 < loud, "and decays", quiet);
    // low-passed: far fewer sign changes than white noise's ~one every other sample
    i32 bz = crossings(b, (i32)0, ms((i32)50));
    ck(bz < ms((i32)50) / (i32)8, "the boom is low-passed (few crossings)", bz);
    UXSound* boom2 = new UXSound();
    boom2.boom(0.16, 0.0);
    i16* b2 = boom2.samples();
    bool same = true;
    for (i32 i = (i32)0; i < boom.frameCount(); i = i + (i32)1)
        {
        if (b[i] != b2[i])
            {
            same = false;
            }
        }
    ck(same, "the boom renders the same samples every time", (i32)0);
    // Two sounds BUILT before either is rendered, as an app holds its sounds: each must keep its own
    // parts.  (Its parts were once in a fixed-size array field, which does not keep an object alive:
    // the first sound's second note was freed and became the boom's part.)
    UXSound* first = new UXSound();
    first.note((i32)UXSND_SINE, 880.0, 0.10, 0.07, 0.0, 0.0);
    first.note((i32)UXSND_SINE, 1170.0, 0.14, 0.06, 0.0, 0.09);
    UXSound* then = new UXSound();
    then.boom(0.16, 0.0);
    ck(first.frameCount() == ms((i32)250) + (i32)1, "a sound built before another keeps its own parts", first.frameCount());
    // 0.52 s is a hair under 22932 samples in floating point, so allow the one frame
    i32 bf = then.frameCount() - ms((i32)520);
    ck(bf >= (i32)0 && bf <= (i32)1, "...and so does the second (the boom's 0.5 s + 20 ms)", then.frameCount());
    if (gFails == 0)
        {
        Stdio.printf("PASS: UXSound -- pitch, slide, envelope, a second note at its offset, and the boom\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
