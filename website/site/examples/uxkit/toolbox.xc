// toolbox.xc — UXAnimation, UXData, UXLog and UXMarkdown.
//
// Four small facilities, all testable with no window: the animation is given
// its time, the logger writes where you tell it, and the rest is pure data.
#import <Stdio.xc>
#import "UXAnimation.xc"
#import "UXData.xc"
#import "UXLog.xc"
#import "UXMarkdown.xc"

i32 gHits;

class Watcher : Object {
    void init(void) { }
    void onMatch(u8* msg) { gHits = gHits + 1; Stdio.printf("    MONITOR saw: %s\n", msg); }
}

void sampleCurve(u8* label, i32 easing) {
    UXAnimation* a = UXAnimation.make((i32)0, (i32)100, (i32)1000, (i32)400, easing);
    Stdio.printf("%s", label);
    i32 ts[5]; ts[0]=(i32)1000; ts[1]=(i32)1100; ts[2]=(i32)1200; ts[3]=(i32)1300; ts[4]=(i32)1400;
    for (i32 i = (i32)0; i < (i32)5; i = i + (i32)1) {
        Stdio.printf(" %d", a.valueAt(ts[i]));
    }
    Stdio.printf("\n");
}

void main(void) {
    // ---- animation ---------------------------------------------------------
    // Same from/to/duration, four curves. Time is passed in, so this is exact.
    Stdio.printf("animation (0->100 over 400ms, sampled every 100ms):\n");
    sampleCurve((u8*)"  linear:    ", (i32)UX_EASE_LINEAR);
    sampleCurve((u8*)"  ease-in:   ", (i32)UX_EASE_IN);
    sampleCurve((u8*)"  ease-out:  ", (i32)UX_EASE_OUT);
    sampleCurve((u8*)"  in-out:    ", (i32)UX_EASE_IN_OUT);

    // Outside the window it clamps to the endpoints rather than extrapolating.
    UXAnimation* a = UXAnimation.make((i32)10, (i32)20, (i32)1000, (i32)400,
                                      (i32)UX_EASE_LINEAR);
    Stdio.printf("  before=%d after=%d finished@1399=%d finished@1400=%d\n",
                 a.valueAt((i32)0), a.valueAt((i32)9999),
                 a.isFinished((i32)1399) ? 1 : 0, a.isFinished((i32)1400) ? 1 : 0);

    // Backwards is just a from greater than a to.
    UXAnimation* back = UXAnimation.make((i32)100, (i32)0, (i32)0, (i32)200,
                                         (i32)UX_EASE_LINEAR);
    Stdio.printf("  reverse at halfway: %d\n", back.valueAt((i32)100));

    // ---- data --------------------------------------------------------------
    // Bytes are appended one at a time here rather than written as a "\xNN"
    // literal, which reads better and carries arbitrary values exactly.
    UXData* d = UXData.fromString((u8*)"GEM");
    d.appendByte((u8)0);
    d.appendByte((u8)1);
    d.appendByte((u8)2);
    d.appendByte((u8)255);
    Stdio.printf("\ndata: len=%d hex=%s\n", d.length(), d.toHex());

    UXData* slice = d.subdata((i32)0, (i32)3);
    Stdio.printf("slice(0,3): len=%d hex=%s\n", slice.length(), slice.toHex());

    UXData* same = UXData.fromString((u8*)"GEM");
    Stdio.printf("equal=%d  differs from whole=%d\n",
                 slice.isEqualTo(same) ? 1 : 0, slice.isEqualTo(d) ? 1 : 0);

    // Appending one buffer to another, and an out-of-range slice.
    UXData* joined = UXData.fromString((u8*)"ab");
    joined.appendData(UXData.fromString((u8*)"cd"));
    Stdio.printf("joined hex=%s   over-long slice len=%d\n",
                 joined.toHex(), d.subdata((i32)2, (i32)999).length());

    // ---- logging -----------------------------------------------------------
    Stdio.printf("\nlog:\n");
    gHits = 0;
    Watcher* w = new Watcher();
    UXLog* net = UXLog.forSubsystem((u8*)"net");
    net.setMinLevel((i32)UX_LOG_INFO);

    // A monitor fires when a logged message matches — the toolkit's own regex.
    net.addMonitor(UXRegex.compile((u8*)"timeout"), &w.onMatch);

    net.debug((u8*)"opening socket");            // below the level: dropped
    net.info((u8*)"connected to host");
    net.warn((u8*)"read timeout after 30s");     // matches the monitor
    net.error((u8*)"giving up");

    Stdio.printf("  monitor fired %d time(s), monitors=%d\n",
                 gHits, net.monitorCount());

    // forSubsystem returns the SAME logger for a name, so settings are shared.
    UXLog* again = UXLog.forSubsystem((u8*)"net");
    Stdio.printf("  same logger: %d\n", again == net ? 1 : 0);

    // ---- markdown ----------------------------------------------------------
    UXAttributedString* md = UXMarkdown.parse(
        (u8*)"plain **bold** and *italic* and `code` here");
    Stdio.printf("\nmarkdown: '%s'\n", md.stringValue());
    Array<UXAttrRun>* rs = md.runs();
    Stdio.printf("  %d run(s):", (i32)rs.count());
    for (u16 i = (u16)0; i < rs.count(); i = i + (u16)1) {
        UXAttrRun* r = (UXAttrRun* ?)rs.get(i);
        Stdio.printf(" [%d..%d%s%s%s]", r.loc, r.end() - (i32)1,
                     r.attr.bold ? (u8*)" B" : (u8*)"",
                     r.attr.italic ? (u8*)" I" : (u8*)"",
                     r.attr.pen == (i32)UXMD_CODE_PEN ? (u8*)" C" : (u8*)"");
    }
    Stdio.printf("\n");

    // A backslash escapes a marker so it appears literally.
    UXAttributedString* esc = UXMarkdown.parse((u8*)"a \\*literal\\* star");
    Stdio.printf("escaped: '%s' runs=%d\n", esc.stringValue(), esc.runCount());

    // Nesting works because the markers toggle independently.
    UXAttributedString* both = UXMarkdown.parse((u8*)"**bold *and italic* **");
    Stdio.printf("nested: '%s' runs=%d\n", both.stringValue(), both.runCount());
}
