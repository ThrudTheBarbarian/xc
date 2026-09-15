// time_elapsed.xc — proves the arm64 host clock measures REAL wall time.
//
// The arm64 Time class is backed by libxt.a (support/arm64/runtime/libxt.c),
// which reads CLOCK_MONOTONIC — not the no-op/return-0 stubs it used to ship.
// This fixture sleeps a known interval and asserts the clock actually
// advanced by a sane amount. With the old no-op Time, ticksSince() would
// return 0, the `> 1000` assert would print "FAIL T1", stdout would no longer
// be exactly "ok\n", and the oracle diff would fail — so this test is a real
// guard against the clock silently going back to a cheat.
//
// arm64-only: this validates the libxt.a host-clock path. The xt6502 Time
// class drives the Atari RTCLOK jiffy counter (a separate implementation).
//xtc-na: xt6502 — asserts arm64's real wall-clock timing

#import <Time.xc>
#import <Stdio.xc>
#import <Assert.xc>

void main(void)
{
    Time.clearTimer();
    u32 t0 = Time.timerValue();         // ~0 us since the reset above

    Time.delayJiffies(6);               // sleep ~0.1 s (6 / 60) of real time

    u32 us = Time.ticksSince(t0);       // microseconds actually elapsed
    Assert.isTrue(us > 1000);           // clock advanced (>1 ms; 0 on a no-op)
    Assert.isTrue(us < 2000000);        // ... by a sane amount (< 2 s)

    Stdio.printf("ok\n");
    return;
}
