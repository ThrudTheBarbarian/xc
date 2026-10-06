// toolbox.xc — UXAnimation and UXMarkdown.
//
// Two small facilities, both testable with no window: the animation is given
// its time, and markdown is pure data.
#import <Stdio.xc>
#import "UXAnimation.xc"
#import "UXMarkdown.xc"

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

    // ---- markdown ----------------------------------------------------------
    // The result is a Foundation AttributedString; UXTextStyle reads the
    // attributes UXKit draws (bold, italic, the pen) off each of its runs.
    AttributedString* md = UXMarkdown.parse(
        (u8*)"plain **bold** and *italic* and `code` here");
    Stdio.printf("\nmarkdown: '%s'\n", md.text().cString());
    Stdio.printf("  %d run(s):", (i32)md.runCount());
    for (u32 i = (u32)0; i < md.runCount(); i = i + (u32)1) {
        Range* r = md.runRange(i);
        UXTextStyle* st = UXTextStyle.of(md.runAttributes(i));
        Stdio.printf(" [%d..%d%s%s%s]", r.loc, r.end() - (i32)1,
                     st.bold ? (u8*)" B" : (u8*)"",
                     st.italic ? (u8*)" I" : (u8*)"",
                     st.pen == (i32)UXMD_CODE_PEN ? (u8*)" C" : (u8*)"");
    }
    Stdio.printf("\n");

    // A backslash escapes a marker so it appears literally.
    AttributedString* esc = UXMarkdown.parse((u8*)"a \\*literal\\* star");
    Stdio.printf("escaped: '%s' runs=%d\n", esc.text().cString(), (i32)esc.runCount());

    // Nesting works because the markers toggle independently.
    AttributedString* both = UXMarkdown.parse((u8*)"**bold *and italic* **");
    Stdio.printf("nested: '%s' runs=%d\n", both.text().cString(), (i32)both.runCount());
}
