// timers.xc — UXTimer and UXTimerScheduler with SYNTHETIC time.
//
// The scheduler has no clock of its own: tick(now) is handed the time, so the
// firing logic is deterministic and runs headless with no window and no driver.
#import <Stdio.xc>
#import "UXTimer.xc"

i32 gOneShots;
i32 gTicks;

class Handlers : Object {
    void init(void) { }
    void onOnce(UXTimer* t)  { gOneShots = gOneShots + 1; Stdio.printf("  one-shot fired\n"); }
    void onEvery(UXTimer* t) { gTicks = gTicks + 1;       Stdio.printf("  repeater fired (%d)\n", gTicks); }
}

void main(void) {
    gOneShots = 0; gTicks = 0;
    Handlers* h = new Handlers();
    UXTimerScheduler* s = new UXTimerScheduler();

    s.schedule(UXTimer.oneShot(100, &h.onOnce));         // once, at t=100
    s.schedule(UXTimer.every(100, 50, &h.onEvery));      // every 50ms from t=100

    Stdio.printf("active: %d  next fire at: %d\n", s.activeCount(), s.nextFireTime());

    Stdio.printf("tick(50)  -> nothing is due yet\n");
    Stdio.printf("  fires: %d\n", s.tick(50));

    Stdio.printf("tick(100) -> both are due\n");
    Stdio.printf("  fires: %d\n", s.tick(100));
    Stdio.printf("  active now: %d (the one-shot pruned itself)\n", s.activeCount());

    // A repeater that fell behind CATCHES UP: jumping to 260 owes fires at
    // 150, 200 and 250 — three, not one.
    Stdio.printf("tick(260) -> the repeater catches up\n");
    Stdio.printf("  fires: %d\n", s.tick(260));

    Stdio.printf("next fire at: %d\n", s.nextFireTime());

    // Cancelling: invalidate stops it firing at once; the next tick prunes it.
    UXTimer* rep = UXTimer.every(1000, 50, &h.onEvery);
    s.schedule(rep);
    Stdio.printf("scheduled another: active %d\n", s.activeCount());
    rep.invalidate();
    Stdio.printf("after invalidate:  active %d (not yet pruned)\n", s.activeCount());
    s.tick(400);
    Stdio.printf("after tick:        active %d, next %d\n",
                 s.activeCount(), s.nextFireTime());
}
