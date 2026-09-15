// test_eventrecorder.xc — UXEventRecorder: capture a stream and replay it faithfully.
#import <Stdio.xc>
#import "UXEventRecorder.xc"
#import "UXEvent.xc"

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

// A sink that re-plays into: sums x's and counts, and remembers the last kind — stands in for the
// app's dispatch, proving replay delivers the right events in order.
class Sink : Object
    {
    i32 n;
    i32 sumX;
    i32 lastKind;
    i32 firstX;
    void init(void)
        {
        n = (i32)0;
        sumX = (i32)0;
        lastKind = (i32)0;
        firstX = (i32)-1;
        }
    void onEvent(UXEvent* e)
        {
        if (firstX < (i32)0)
            {
            firstX = (i32)e.x;
            }
        sumX = sumX + (i32)e.x;
        lastKind = (i32)e.kind;
        n = n + (i32)1;
        }
    }

    UXEvent*
    mkMouse(i32 kind, i32 x, i32 y)
    {
    UXEvent* e = new UXEvent();
    e.kind = (u8)kind;
    e.x = (i16)x;
    e.y = (i16)y;
    return e;
    }

void main(void)
    {
    gFails = (i32)0;
    UXEventRecorder* rec = new UXEventRecorder();

    // not recording yet: record() is a no-op
    rec.record(mkMouse((i32)UXEventMouseDown, (i32)5, (i32)5), (i32)0);
    check("nothing recorded before start", rec.count(), (i32)0);

    rec.start((i32)1000); // clock base = 1000ms
    check("recording flag", rec.isRecording() ? (i32)1 : (i32)0, (i32)1);
    rec.record(mkMouse((i32)UXEventMouseDown, (i32)10, (i32)20), (i32)1000);    // t=0
    rec.record(mkMouse((i32)UXEventMouseDragged, (i32)30, (i32)40), (i32)1050); // t=50
    rec.record(mkMouse((i32)UXEventMouseUp, (i32)50, (i32)60), (i32)1120);      // t=120
    rec.stop();
    check("three events captured", rec.count(), (i32)3);
    check("first timestamp is 0", rec.timeAt((i32)0), (i32)0);
    check("second timestamp relative", rec.timeAt((i32)1), (i32)50);
    check("duration", rec.durationMs(), (i32)120);
    check("event payload preserved (x)", (i32)rec.eventAt((i32)1).x, (i32)30);
    check("event kind preserved", (i32)rec.eventAt((i32)2).kind, (i32)UXEventMouseUp);

    // deep copy: mutating a source event after recording must not change the recording
    UXEvent* src = mkMouse((i32)UXEventMouseDown, (i32)7, (i32)7);
    rec.start((i32)0);
    rec.record(src, (i32)0);
    rec.stop();
    src.x = (i16)999; // mutate after capture
    check("recording is an independent copy", (i32)rec.eventAt((i32)0).x, (i32)7);

    // replay delivers everything, in order
    rec.clear();
    rec.start((i32)0);
    rec.record(mkMouse((i32)UXEventMouseDown, (i32)1, (i32)0), (i32)0);
    rec.record(mkMouse((i32)UXEventMouseDragged, (i32)2, (i32)0), (i32)10);
    rec.record(mkMouse((i32)UXEventMouseDragged, (i32)4, (i32)0), (i32)20);
    rec.record(mkMouse((i32)UXEventMouseUp, (i32)8, (i32)0), (i32)30);
    rec.stop();
    Sink* s = new Sink();
    rec.replay(&s.onEvent);
    check("replay delivered all 4", s.n, (i32)4);
    check("replay in order (first x=1)", s.firstX, (i32)1);
    check("replay summed x (1+2+4+8)", s.sumX, (i32)15);
    check("replay last kind is MouseUp", s.lastKind, (i32)UXEventMouseUp);

    // range replay: only [10,30) -> the two draggeds
    Sink* s2 = new Sink();
    rec.replayRange(&s2.onEvent, (i32)10, (i32)30);
    check("range replay count", s2.n, (i32)2);
    check("range replay summed x (2+4)", s2.sumX, (i32)6);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXEventRecorder — capture gating, timestamps, deep copy, ordered replay, range replay.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
