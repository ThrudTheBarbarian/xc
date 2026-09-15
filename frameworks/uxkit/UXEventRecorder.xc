// UXEventRecorder.xc — capture a stream of UI events and replay it (debugging / UI test support).
//
// The neutral run loop already funnels every event through one place; a recorder tees a COPY of each
// (tagged with a millisecond offset from the start of recording) into a list, and replay feeds those
// copies back to a sink — the app's own dispatch — in order.  The recorder holds no clock and no
// dispatch of its own: the caller passes the current time in (from the driver) and provides the sink,
// so the model is backend-neutral and testable with synthetic time.  Deterministic bug repros, demos,
// and "do that again" all fall out of this.
#import "Array.xc"
#import "UXEvent.xc"

// (gEventTap itself is declared in UXEvent.xc, beside the drivers that announce through it.)

class UXRecordedEvent : Object
    {
    UXEvent* event;
    i32 timeMs; // milliseconds since recording began
    void init(void)
        {
        event = (UXEvent*)0;
        timeMs = (i32)0;
        }
    }

    class UXEventRecorder
    {
    Array<UXRecordedEvent>* events; // of UXRecordedEvent, in capture order
    bool recording;
    i32 baseMs;
    void init(void)
        {
        events = new Array();
        recording = false;
        baseMs = (i32)0;
        }

    void start(i32 nowMs)
        {
        events.removeAll();
        recording = true;
        baseMs = nowMs;
        }
    void stop(void)
        {
        recording = false;
        }
    bool isRecording(void)
        {
        return recording;
        }

    // Deep-copy the event so later reuse of the caller's UXEvent object can't corrupt the recording.
    static UXEvent* copyEvent(UXEvent* e)
        {
        UXEvent* c = new UXEvent();
        c.kind = e.kind;
        c.x = e.x;
        c.y = e.y;
        c.buttons = e.buttons;
        c.key = e.key;
        c.modifiers = e.modifiers;
        c.handle = e.handle;
        c.a = e.a;
        c.b = e.b;
        c.data = e.data; // the payload is immutable once announced, so the reference is the copy
        return c;
        }
    void record(UXEvent* e, i32 nowMs)
        {
        if (!recording)
            {
            return;
            }
        UXRecordedEvent* r = new UXRecordedEvent();
        r.event = UXEventRecorder.copyEvent(e);
        r.timeMs = nowMs - baseMs;
        events.add(r);
        }

    i32 count(void)
        {
        return (i32)events.count();
        }
    UXEvent* eventAt(i32 i)
        { return ((UXRecordedEvent* ?)events.get((u16)i)).event;
        }
    i32 timeAt(i32 i)
        { return ((UXRecordedEvent* ?)events.get((u16)i)).timeMs;
        }
    i32 durationMs(void)
        {
        if (events.count() == (u16)0)
            {
            return (i32)0;
            }
        return self.timeAt((i32)events.count() - (i32)1);
        }
    void clear(void)
        {
        events.removeAll();
        }

    // Feed every recorded event to the sink in order.  (A driver can pace by timeMs; here it is a
    // straight replay — the ordering and payloads are what matter for a repro.)
    void replay(callback sink void(UXEvent* e))
        {
        if (sink == (callback void(UXEvent * e))0)
            {
            return;
            }
        gInputReplay = true; // a replayed press must not grab the live pointer
        for (u16 i = (u16)0; i < events.count(); i = i + (u16)1)
            {
            sink(((UXRecordedEvent* ?)events.get(i)).event);
            }
        gInputReplay = false;
        }
    // Replay only events at or after fromMs and before toMs — for scrubbing a slice of the recording.
    void replayRange(callback sink void(UXEvent* e), i32 fromMs, i32 toMs)
        {
        // BEFORE the flag: an early return must not leak it
        if (sink == (callback void(UXEvent * e))0)
            {
            return;
            }
        gInputReplay = true;
        for (u16 i = (u16)0; i < events.count(); i = i + (u16)1)
            {
            UXRecordedEvent* r = (UXRecordedEvent* ?)events.get(i);
            if (r.timeMs >= fromMs && r.timeMs < toMs)
                {
                sink(r.event);
                }
            }
        gInputReplay = false;
        }
    }
