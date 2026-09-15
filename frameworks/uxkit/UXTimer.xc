// UXTimer.xc — scheduled callbacks (NSTimer + the run loop's timer handling, in miniature).
//
// A timer fires its callback at an absolute time and, if repeating, again every interval.  The
// scheduler's tick(now) fires everything due — catching up a repeating timer that fell behind — and
// nextFireTime() tells the run loop how long it may sleep.  No clock of its own: the caller passes the
// time in (from the driver), so the fire logic is deterministic and unit-testable with synthetic time.
#import "Array.xc"

class UXTimer
    {
    i32 fireTime; // next absolute fire time (ms)
    i32 interval; // repeat interval (ms); 0 = one-shot
    bool repeats;
    callback onFire void(UXTimer* t); // never owns its target: a dead target simply stops firing
    bool valid;
    i32 tag;
    void init(void)
        {
        fireTime = (i32)0;
        interval = (i32)0;
        repeats = false;
        onFire = (callback void(UXTimer * t))0;
        valid = true;
        tag = (i32)0;
        }

    static UXTimer* make(i32 fireTime, i32 interval, bool repeats, callback cb void(UXTimer* t))
        {
        UXTimer* t = new UXTimer();
        t.fireTime = fireTime;
        t.interval = interval;
        t.repeats = repeats;
        t.onFire = cb;
        return t;
        }
    static UXTimer* oneShot(i32 at, callback cb void(UXTimer* t))
        {
        return UXTimer.make(at, (i32)0, false, cb);
        }
    static UXTimer* every(i32 firstAt, i32 interval, callback cb void(UXTimer* t))
        {
        return UXTimer.make(firstAt, interval, true, cb);
        }
    void invalidate(void)
        {
        valid = false;
        }
    bool isValid(void)
        {
        return valid;
        }
    void fire(void)
        {
        callback f void(UXTimer * t) = onFire;
        if (f != (callback void(UXTimer * t))0)
            {
            f(self);
            }
        }
    }

    class UXTimerScheduler
    {
    Array<UXTimer>* timers;
    void init(void)
        {
        timers = new Array();
        }

    void schedule(UXTimer* t)
        {
        timers.add(t);
        }
    i32 activeCount(void)
        {
        i32 n = (i32)0;
        for (u16 i = (u16)0; i < timers.count(); i = i + (u16)1)
            { if (((UXTimer* ?)timers.get(i)).valid)
                {
                n = n + (i32)1;
                }
            }
        return n;
        }

    // Fire every timer whose time has come (catching up backlogged repeaters), reschedule repeaters,
    // invalidate one-shots, then prune the dead.  Returns the number of fires.
    i32 tick(i32 nowMs)
        {
        i32 fires = (i32)0;
        for (u16 i = (u16)0; i < timers.count(); i = i + (u16)1)
            {
            UXTimer* t = (UXTimer* ?)timers.get(i);
            while (t.valid && t.fireTime <= nowMs)
                {
                t.fire();
                fires = fires + (i32)1;
                if (t.repeats && t.interval > (i32)0)
                    {
                    t.fireTime = t.fireTime + t.interval;
                    }
                else
                    {
                    t.valid = false;
                    }
                }
            }
        // prune invalid
        u16 j = (u16)0;
        while (j < timers.count())
            {
            if (!((UXTimer* ?)timers.get(j)).valid)
                {
                timers.removeAt(j);
                }
            else
                {
                j = j + (u16)1;
                }
            }
        return fires;
        }
    // Earliest pending fire time, or -1 if nothing is scheduled (how long the run loop may sleep).
    i32 nextFireTime(void)
        {
        i32 best = (i32)-1;
        for (u16 i = (u16)0; i < timers.count(); i = i + (u16)1)
            {
            UXTimer* t = (UXTimer* ?)timers.get(i);
            if (t.valid && (best < (i32)0 || t.fireTime < best))
                {
                best = t.fireTime;
                }
            }
        return best;
        }
    }
