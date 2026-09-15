// test_win32_textlayout.xc — line breaking against REAL glyph metrics.
//
// test_textlayout covers the arithmetic wrap (a uniform character width, no driver).  This covers
// wrapFont: the same greedy rule, but measuring through UXViewDriver.textWidth — the font the text
// will actually be drawn in.  Win32/Wine because that backend runs headlessly; nothing here is
// Win32-specific beyond the driver it boots.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXTextLayout.xc"
#import "UXAttributedString.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"

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
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

u8* gText;

// The widest line the wrap produced, measured the same way the wrap measured it.
i32 widestLine(Array<UXRange>* lines, i32 size)
    {
    i32 w = (i32)0;
    for (u16 i = (u16)0; i < lines.count(); i = i + (u16)1)
        {
        UXRange* ln = (UXRange* ?)lines.get(i);
        i32 lw = UXTextLayout.spanWidth(gText, ln.loc, ln.loc + ln.len, size);
        if (lw > w)
            {
            w = lw;
            }
        }
    return w;
    }
// Does any line start or end in the middle of a word?  (A hard-broken over-long word is the one
// legitimate case, and this text has none.)
bool breaksMidWord(Array<UXRange>* lines)
    {
    for (u16 i = (u16)0; i < lines.count(); i = i + (u16)1)
        {
        UXRange* ln = (UXRange* ?)lines.get(i);
        if (ln.len == (i32)0)
            {
            continue;
            }
        i32 before = ln.loc - (i32)1;
        i32 after = ln.loc + ln.len;
        if (before >= (i32)0 && gText[before] != (u8)' ' && gText[before] != (u8)10)
            {
            return true;
            }
        if (gText[after] != (u8)0 && gText[after] != (u8)' ' && gText[after] != (u8)10)
            {
            return true;
            }
        }
    return false;
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* drv = new UXWin32Driver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    // The seam itself: a wider string must measure wider, and the same string at a bigger size too.
    i32 wNarrow = gDriver.textWidth((u8*)"iiiiiiiiii", (i32)0);
    i32 wWide = gDriver.textWidth((u8*)"WWWWWWWWWW", (i32)0);
    checkTrue("textWidth: 10 W wider than 10 i (proportional)", wWide > wNarrow);
    i32 w12 = gDriver.textWidth((u8*)"The quick brown fox", (i32)12);
    i32 w24 = gDriver.textWidth((u8*)"The quick brown fox", (i32)24);
    checkTrue("textWidth: same text measures wider at 24 than 12", w24 > w12);
    check("textWidth: empty string is zero", gDriver.textWidth((u8*)"", (i32)0), (i32)0);

    gText = (u8*)"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.";

    // THE invariant: no produced line is wider than the measure it was wrapped to.
    Array<UXRange>* lines = UXTextLayout.wrapFont(gText, (i16)200, (i32)0);
    checkTrue("every line fits 200px", widestLine(lines, (i32)0) <= (i32)200);
    checkTrue("wrapped onto several lines", lines.count() > (u16)1);
    checkTrue("no line breaks mid-word", !breaksMidWord(lines));

    // A narrower measure must not produce fewer lines, and still must fit.
    Array* narrow = UXTextLayout.wrapFont(gText, (i16)100, (i32)0);
    checkTrue("100px wraps to at least as many lines as 200px", narrow.count() >= lines.count());
    checkTrue("every line fits 100px", widestLine(narrow, (i32)0) <= (i32)100);

    // A bigger font at the same measure needs at least as many lines.
    Array* big = UXTextLayout.wrapFont(gText, (i16)200, (i32)24);
    checkTrue("24pt needs at least as many lines as the default", big.count() >= lines.count());
    checkTrue("every 24pt line fits 200px", widestLine(big, (i32)24) <= (i32)200);

    // And the metrics are genuinely CONSULTED: a proportional font must break this differently from
    // the uniform-width estimate, whose idea of a line is "same number of characters" regardless of
    // which characters they are.
    u8* mixed = (u8*)"iiiii iiiii iiiii iiiii WWWWW WWWWW WWWWW WWWWW";
    gText = mixed;
    Array<UXRange>* measured = UXTextLayout.wrapFont(mixed, (i16)150, (i32)0);
    Array<UXRange>* uniform = UXTextLayout.wrap(mixed, (i16)150, (i16)8);
    bool differs = measured.count() != uniform.count();
    if (!differs)
        {
        for (u16 i = (u16)0; i < measured.count(); i = i + (u16)1)
            {
            UXRange* a = (UXRange* ?)measured.get(i);
            UXRange* b = (UXRange* ?)uniform.get(i);
            if (a.loc != b.loc || a.len != b.len)
                {
                differs = true;
                }
            }
        }
    checkTrue("proportional wrap differs from the uniform estimate", differs);
    checkTrue("every mixed line fits 150px", widestLine(measured, (i32)0) <= (i32)150);

    // ---- alignment ------------------------------------------------------------------------
    gText = (u8*)"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.";
    Array<UXRange>* ls = UXTextLayout.wrapFont(gText, (i16)200, (i32)0);
    UXRange* first = (UXRange* ?)ls.get((u16)0);
    i32 fw = UXTextLayout.spanWidth(gText, first.loc, first.loc + first.len, (i32)0);

    Array<UXTextRun>* rl = UXTextLayout.layoutLine(gText, first, (i16)200, (i32)0, (i32)UX_ALIGN_LEFT, false);
    check("left: one run at x=0", (i32)((UXTextRun* ?)rl.get((u16)0)).x, (i32)0);
    Array<UXTextRun>* rc = UXTextLayout.layoutLine(gText, first, (i16)200, (i32)0, (i32)UX_ALIGN_CENTER, false);
    check("centre: half the slack", (i32)((UXTextRun* ?)rc.get((u16)0)).x, ((i32)200 - fw) / (i32)2);
    Array<UXTextRun>* rr = UXTextLayout.layoutLine(gText, first, (i16)200, (i32)0, (i32)UX_ALIGN_RIGHT, false);
    check("right: all the slack", (i32)((UXTextRun* ?)rr.get((u16)0)).x, (i32)200 - fw);

    // Justified: a run per word, starting flush left and ENDING exactly on the measure.
    Array<UXTextRun>* rj = UXTextLayout.layoutLine(gText, first, (i16)200, (i32)0, (i32)UX_ALIGN_JUSTIFY, false);
    checkTrue("justify: more runs than one", rj.count() > (u16)1);
    check("justify: first word at x=0", (i32)((UXTextRun* ?)rj.get((u16)0)).x, (i32)0);
    UXTextRun* last = (UXTextRun* ?)rj.get((u16)(rj.count() - (u16)1));
    i32 endX = last.x + UXTextLayout.spanWidth(gText, last.loc, last.loc + last.len, (i32)0);
    check("justify: last word ends on the measure", endX, (i32)200);
    // Words must not overlap or run backwards.
    bool ordered = true;
    for (u16 i = (u16)1; i < rj.count(); i = i + (u16)1)
        {
        UXTextRun* a = (UXTextRun* ?)rj.get((u16)(i - (u16)1));
        UXTextRun* b = (UXTextRun* ?)rj.get(i);
        i32 aEnd = a.x + UXTextLayout.spanWidth(gText, a.loc, a.loc + a.len, (i32)0);
        if (b.x < aEnd)
            {
            ordered = false;
            }
        }
    checkTrue("justify: words in order, no overlap", ordered);

    // The last line of a paragraph sets FLUSH LEFT even when justified.
    UXRange* lastLine = (UXRange* ?)ls.get((u16)(ls.count() - (u16)1));
    Array<UXTextRun>* rlast = UXTextLayout.layoutLine(gText, lastLine, (i16)200, (i32)0, (i32)UX_ALIGN_JUSTIFY, true);
    check("justify: last line is one flush-left run", (i32)rlast.count(), (i32)1);
    check("justify: ...at x=0", (i32)((UXTextRun* ?)rlast.get((u16)0)).x, (i32)0);
    checkTrue("isParagraphEnd: true for the final line",
              UXTextLayout.isParagraphEnd(gText, ls, (u16)(ls.count() - (u16)1)));
    checkTrue("isParagraphEnd: false for the first", !UXTextLayout.isParagraphEnd(gText, ls, (u16)0));

    // ---- rich text -------------------------------------------------------------------------
    // Bold IS wider: the same characters must measure wider once styled, or attributed text would be
    // wrapped with the plain metric and overflow its column.
    u8* plain = (u8*)"The quick brown fox jumps over the lazy dog";
    UXAttributedString* as = UXAttributedString.make(plain);
    i32 wPlain = UXTextLayout.spanWidthAttr(as, (i32)0, as.length(), (i32)16);
    as.setBold(true, (i32)0, as.length());
    i32 wBold = UXTextLayout.spanWidthAttr(as, (i32)0, as.length(), (i32)16);
    checkTrue("attributed: all-bold measures wider than plain", wBold > wPlain);
    check("attributed: plain measure matches the plain metric",
          wPlain, gDriver.textWidth(plain, (i32)16));

    // A styled range must not change the text, only its width — and the wrap must respect it.
    UXAttributedString* mix = UXAttributedString.make(plain);
    mix.setSize((i16)28, (i32)4, (i32)5); // "quick" much bigger
    i32 wMix = UXTextLayout.spanWidthAttr(mix, (i32)0, mix.length(), (i32)16);
    checkTrue("attributed: a larger run widens the span", wMix > wPlain);
    Array<UXRange>* ml = UXTextLayout.wrapAttr(mix, (i16)200, (i32)16);
    bool allFit = true;
    for (u16 i = (u16)0; i < ml.count(); i = i + (u16)1)
        {
        UXRange* ln = (UXRange* ?)ml.get(i);
        if (UXTextLayout.spanWidthAttr(mix, ln.loc, ln.loc + ln.len, (i32)16) > (i32)200)
            {
            allFit = false;
            }
        }
    checkTrue("attributed: every wrapped line fits, styles included", allFit);

    // Style runs and word placement compose: justified attributed text still ends on the measure,
    // and every piece carries the attributes of the characters it covers.
    UXRange* ml0 = (UXRange* ?)ml.get((u16)0);
    Array<UXTextRun>* sruns = UXTextLayout.layoutLineAttr(mix, ml0, (i16)200, (i32)16, (i32)UX_ALIGN_JUSTIFY, false);
    checkTrue("attributed: line splits into style runs", sruns.count() >= (u16)2);
    UXTextRun* sl = (UXTextRun* ?)sruns.get((u16)(sruns.count() - (u16)1));
    i32 sEnd = sl.x + UXTextLayout.spanWidthAttr(mix, sl.loc, sl.loc + sl.len, (i32)16);
    check("attributed: justified line ends on the measure", sEnd, (i32)200);
    bool attrsOk = true;
    for (u16 i = (u16)0; i < sruns.count(); i = i + (u16)1)
        {
        UXTextRun* r = (UXTextRun* ?)sruns.get(i);
        if (r.attr == (UXCharAttr*)0)
            {
            attrsOk = false;
            continue;
            }
        if (!r.attr.sameAs(mix.attributesAt(r.loc)))
            {
            attrsOk = false;
            }
        }
    checkTrue("attributed: each run carries its own attributes", attrsOk);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: wrapFont breaks on real glyph metrics\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
