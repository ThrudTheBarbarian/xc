// test_timer.xc — UXTimer / UXTimerScheduler: due-firing, catch-up, one-shots, nextFireTime.
#import <Stdio.xc>
#import "UXTimer.xc"

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

// counters keyed by tag
i32 gA;
i32 gB;
class Sink : Object
    {
    void init(void)
        {
        }
    void onA(UXTimer* t)
        {
        gA = gA + (i32)1;
        }
    void onB(UXTimer* t)
        {
        gB = gB + (i32)1;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    gA = (i32)0;
    gB = (i32)0;
    Sink* s = new Sink();
    UXTimerScheduler* sch = new UXTimerScheduler();

    // one-shot at t=200, repeating every 100 starting at t=100
    UXTimer* once = UXTimer.oneShot((i32)200, &s.onB);
    UXTimer* rep = UXTimer.every((i32)100, (i32)100, &s.onA);
    sch.schedule(once);
    sch.schedule(rep);
    check("two active", sch.activeCount(), (i32)2);
    check("next fire is 100", sch.nextFireTime(), (i32)100);

    // tick before anything is due
    check("tick(50) fires nothing", sch.tick((i32)50), (i32)0);
    check("gA still 0", gA, (i32)0);

    // tick(100): the repeater fires once, reschedules to 200
    check("tick(100) fires the repeater once", sch.tick((i32)100), (i32)1);
    check("gA is 1", gA, (i32)1);
    check("one-shot not yet fired", gB, (i32)0);
    check("next fire now 200", sch.nextFireTime(), (i32)200);

    // tick(350): repeater catches up (200, 300 = 2 fires) AND the one-shot (200) fires once
    i32 fired = sch.tick((i32)350);
    check("tick(350) total fires", fired, (i32)3); // rep*200, rep*300, once*200
    check("gA now 3 (1 + 2 catch-up)", gA, (i32)3);
    check("one-shot fired once", gB, (i32)1);
    check("one active left (the repeater)", sch.activeCount(), (i32)1);
    check("repeater next fire is 400", sch.nextFireTime(), (i32)400);

    // invalidation stops a timer
    rep.invalidate();
    check("invalidated -> none active", sch.activeCount(), (i32)0);
    check("tick after invalidate fires nothing", sch.tick((i32)1000), (i32)0);
    check("gA unchanged", gA, (i32)3);
    check("nextFireTime is -1 when empty", sch.nextFireTime(), (i32)-1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTimer — due firing, repeat catch-up, one-shots, invalidation, nextFireTime.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
