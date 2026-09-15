// UXTextLayout.xc — greedy word-wrap / line breaking (NSTypesetter's job, in miniature).
//
// Break a string into LINES that fit a pixel width, preferring to break at spaces and falling back to
// a hard character break for a word longer than the line; explicit newlines always break.  Widths are
// estimated from a uniform character width (a real backend refines with glyph metrics), so the wrap is
// pure arithmetic and unit-testable.  Each line is an UXRange into the original text — no copies —
// which is what a text view wants for drawing and hit-testing rows.
#import "Array.xc"
#import "UXRange.xc"            // a line IS a range; a run is a range with a position and a style
#import "UXViewDriver.xc"       // gDriver.textWidth — the real glyph metrics wrapFont breaks on
#import "UXAttributedString.xc" // rich text: per-run styles, measured and drawn in their own font

// How a line sits within its measure.  JUSTIFY stretches the inter-word gaps to fill the measure —
// except on the last line of a paragraph, which sets flush left: stretching it is the classic
// typesetting howler, and only the layout knows which line that is (a drawing seam cannot tell).
// Numbered to MATCH GEM's TEDINFO te_just (0 left, 1 right, 2 centre) rather
// than in visual order.
//
// The order is arbitrary either way, and one of the two numberings is not ours
// to choose: te_just is fixed by a file format Rocks reads and writes.  Picking
// the arbitrary one to agree with the fixed one deletes a translation, and with
// it a whole class of bug -- passing te_just through as UX_ALIGN silently swaps
// RIGHT and CENTRE, which looks very nearly correct on screen and would write
// the wrong value into every resource touched.  A mapping that is only correct
// while someone remembers it is a latent bug; no mapping cannot be got wrong.
//
// Consistent with the rest of the toolkit, which is unapologetically GEM-shaped
// where the format has already made the choice (UXMenuItem.encoded emits GEM's
// marker bytes; UXKind maps onto GEM object types).
#define UX_ALIGN_LEFT 0
#define UX_ALIGN_RIGHT 1
#define UX_ALIGN_CENTER 2
#define UX_ALIGN_JUSTIFY 3

// A positioned piece of a line: the range to draw and the x to draw it at, relative to the measure's
// left edge.  Left/centre/right give one run per line; justified gives one per word.
// A run IS a range, plus where to put it: extending UXRange rather than respelling loc/len keeps one
// vocabulary across the toolkit.  The factory is `at` and not `make` because xtc dispatches on the
// NAME alone — an inherited UXRange.make(loc,len) and a two-arities-different UXTextRun.make would
// be the same method as far as the compiler is concerned.
class UXTextRun : UXRange
    {
    i32 x;
    UXCharAttr* attr; // the style to draw it in (nil = the view's default)
    void init(void)
        {
        super.init();
        x = (i32)0;
        attr = (UXCharAttr*)0;
        }
    static UXTextRun* at(i32 l, i32 n, i32 px)
        {
        UXTextRun* r = new UXTextRun();
        r.loc = l;
        r.len = n;
        r.x = px;
        return r;
        }
    static UXTextRun* styled(i32 l, i32 n, i32 px, UXCharAttr* a)
        {
        UXTextRun* r = UXTextRun.at(l, n, px);
        r.attr = a;
        return r;
        }
    }

// Scratch for measuring a SPAN of the text: the driver measures a NUL-terminated string, and the
// text is not cut up (a line is a range into the original), so a candidate is copied out to be asked
// about.  One buffer, reused — line breaking is not re-entrant.
#define UX_TL_SCRATCH 1024
    u8 gTLScratch[UX_TL_SCRATCH];

class UXTextLayout
    {
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }

    // Width of text[start..end) in the UI font at `size`.  With no driver (a pure model test) fall
    // back to the old uniform estimate so the arithmetic path still answers.
    static i32 spanWidth(u8* text, i32 start, i32 end, i32 size)
        {
        i32 n = end - start;
        if (n < (i32)0)
            {
            n = (i32)0;
            }
        if (n > (i32)UX_TL_SCRATCH - (i32)1)
            {
            n = (i32)UX_TL_SCRATCH - (i32)1;
            }
        for (i32 k = (i32)0; k < n; k = k + (i32)1)
            {
            gTLScratch[k] = text[start + k];
            }
        gTLScratch[n] = (u8)0;
        if (gDriver == (UXViewDriver*)0)
            {
            return n * (i32)8;
            }
        return gDriver.textWidth((u8*)&gTLScratch[(i32)0], size);
        }
    // How many characters of text[start..end) fit in `width` — for hard-breaking a word longer than
    // the measure.  Grows one character at a time: lines are short, and a proportional font gives no
    // closed form.  Always at least one, or an over-narrow measure would loop for ever.
    static i32 charsThatFit(u8* text, i32 start, i32 end, i32 size, i16 width)
        {
        i32 fit = (i32)0;
        for (i32 k = (i32)1; start + k <= end; k = k + (i32)1)
            {
            if (UXTextLayout.spanWidth(text, start, start + k, size) > (i32)width)
                {
                break;
                }
            fit = k;
            }
        return fit > (i32)0 ? fit : (i32)1;
        }

    // wrap(), but measuring the font it will be DRAWN in rather than assuming a uniform character
    // width.  Same greedy rule — a word joins the open line if the span still fits, else it starts a
    // new one; an over-long word hard-breaks; newlines always break.
    static Array<UXRange>* wrapFont(u8* text, i16 width, i32 size)
        {
        Array<UXRange>* lines = new Array();
        i32 n = UXTextLayout.slen(text);
        i32 lineStart = (i32)-1;
        i32 lineEnd = (i32)-1;
        i32 i = (i32)0;
        while (i < n)
            {
            u8 c = text[i];
            if (c == (u8)10)
                {
                if (lineStart >= (i32)0)
                    {
                    lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                    }
                else
                    {
                    lines.add(UXRange.make(i, (i32)0));
                    }
                lineStart = (i32)-1;
                i = i + (i32)1;
                continue;
                }
            if (c == (u8)' ')
                {
                i = i + (i32)1;
                continue;
                }
            i32 wordStart = i;
            while (i < n && text[i] != (u8)' ' && text[i] != (u8)10)
                {
                i = i + (i32)1;
                }
            i32 wordEnd = i;
            if (lineStart >= (i32)0 && UXTextLayout.spanWidth(text, lineStart, wordEnd, size) <= (i32)width)
                {
                lineEnd = wordEnd; // the word fits on the open line
                continue;
                }
            // it does not: flush the line
            if (lineStart >= (i32)0)
                {
                lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                lineStart = (i32)-1;
                }
            i32 p = wordStart; // place the word, breaking it if
            // it cannot fit alone
            while (UXTextLayout.spanWidth(text, p, wordEnd, size) > (i32)width)
                {
                i32 fit = UXTextLayout.charsThatFit(text, p, wordEnd, size, width);
                if (p + fit >= wordEnd)
                    {
                    break;
                    }
                lines.add(UXRange.make(p, fit));
                p = p + fit;
                }
            lineStart = p;
            lineEnd = wordEnd;
            }
        if (lineStart >= (i32)0)
            {
            lines.add(UXRange.make(lineStart, lineEnd - lineStart));
            }
        return lines;
        }

    // Wrap `text` to `width` pixels using `charWidth` per character.  Scans word by word: a word joins
    // the current line if the span from the line's start through the word still fits, else it starts a
    // new line (trailing/leading run-separating spaces are absorbed); a word wider than the line hard-
    // breaks; newlines always break (an empty line between two newlines is preserved).
    static Array<UXRange>* wrap(u8* text, i16 width, i16 charWidth)
        {
        Array<UXRange>* lines = new Array();
        i32 n = UXTextLayout.slen(text);
        i32 maxChars = charWidth > (i16)0 ? (i32)width / (i32)charWidth : n;
        if (maxChars < (i32)1)
            {
            maxChars = (i32)1;
            }

        i32 lineStart = (i32)-1; // -1 = no line open yet
        i32 lineEnd = (i32)-1;   // one past the last word placed on the open line
        i32 i = (i32)0;
        while (i < n)
            {
            u8 c = text[i];
            // newline: flush (or emit an empty line)
            if (c == (u8)10)
                {
                if (lineStart >= (i32)0)
                    {
                    lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                    }
                else
                    {
                    lines.add(UXRange.make(i, (i32)0));
                    }
                lineStart = (i32)-1;
                i = i + (i32)1;
                continue;
                }
            // skip inter-word spaces
            if (c == (u8)' ')
                {
                i = i + (i32)1;
                continue;
                }

            i32 wordStart = i; // a word: the next non-space, non-newline run
            while (i < n && text[i] != (u8)' ' && text[i] != (u8)10)
                {
                i = i + (i32)1;
                }
            i32 wordEnd = i;
            i32 wordLen = wordEnd - wordStart;

            // open a new line with this word
            if (lineStart < (i32)0)
                {
                if (wordLen <= maxChars)
                    {
                    lineStart = wordStart;
                    lineEnd = wordEnd;
                    }
                // hard-break an over-long word
                else
                    {
                    i32 p = wordStart;
                    while (wordEnd - p > maxChars)
                        {
                        lines.add(UXRange.make(p, maxChars));
                        p = p + maxChars;
                        }
                    lineStart = p;
                    lineEnd = wordEnd;
                    }
                }
            // the word fits on the open line
            else if (wordEnd - lineStart <= maxChars)
                {
                lineEnd = wordEnd;
                }
            // wrap: flush, then place the word
            else
                {
                lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                if (wordLen <= maxChars)
                    {
                    lineStart = wordStart;
                    lineEnd = wordEnd;
                    }
                else
                    {
                    i32 p = wordStart;
                    while (wordEnd - p > maxChars)
                        {
                        lines.add(UXRange.make(p, maxChars));
                        p = p + maxChars;
                        }
                    lineStart = p;
                    lineEnd = wordEnd;
                    }
                }
            }
        if (lineStart >= (i32)0)
            {
            lines.add(UXRange.make(lineStart, lineEnd - lineStart));
            }
        return lines;
        }

    // Lay ONE line out within `measure`, as runs to draw.  `isLast` marks the last line of the
    // paragraph (or the line before an explicit newline), which never stretches.
    static Array<UXTextRun>* layoutLine(u8* text, UXRange* ln, i16 measure, i32 size, i32 align, bool isLast)
        {
        Array<UXTextRun>* runs = new Array();
        i32 start = ln.loc;
        i32 end = ln.loc + ln.len;
        if (ln.len <= (i32)0)
            {
            return runs;
            }
        i32 w = UXTextLayout.spanWidth(text, start, end, size);
        i32 slack = (i32)measure - w;
        if (slack < (i32)0)
            {
            slack = (i32)0;
            }

        if (align == (i32)UX_ALIGN_CENTER)
            {
            runs.add(UXTextRun.at(start, ln.len, slack / (i32)2));
            return runs;
            }
        if (align == (i32)UX_ALIGN_RIGHT)
            {
            runs.add(UXTextRun.at(start, ln.len, slack));
            return runs;
            }
        if (align != (i32)UX_ALIGN_JUSTIFY || isLast || slack == (i32)0)
            {
            runs.add(UXTextRun.at(start, ln.len, (i32)0)); // flush left
            return runs;
            }

        // Justified: count the gaps, then walk the words placing each at the running x.  The slack is
        // shared out with the remainder spread one pixel at a time over the LEFTMOST gaps, so the
        // line ends exactly on the measure instead of a pixel or two short.
        i32 gaps = (i32)0;
            {
            i32 i = start;
            while (i < end)
                {
                while (i < end && text[i] != (u8)' ')
                    {
                    i = i + (i32)1;
                    }
                while (i < end && text[i] == (u8)' ')
                    {
                    i = i + (i32)1;
                    }
                if (i < end)
                    {
                    gaps = gaps + (i32)1;
                    }
                }
            }
        if (gaps == (i32)0)
            {
            runs.add(UXTextRun.at(start, ln.len, (i32)0));
            return runs;
            }

        i32 per = slack / gaps;
        i32 extra = slack - per * gaps;
        i32 x = (i32)0;
        i32 i = start;
        i32 gap = (i32)0;
        while (i < end)
            {
            i32 wordStart = i;
            while (i < end && text[i] != (u8)' ')
                {
                i = i + (i32)1;
                }
            i32 wordEnd = i;
            runs.add(UXTextRun.at(wordStart, wordEnd - wordStart, x));
            x = x + UXTextLayout.spanWidth(text, wordStart, wordEnd, size);
            i32 spaceStart = i;
            while (i < end && text[i] == (u8)' ')
                {
                i = i + (i32)1;
                }
            // a real gap, not the line's tail
            if (i < end)
                {
                x = x + UXTextLayout.spanWidth(text, spaceStart, i, size) + per;
                if (gap < extra)
                    {
                    x = x + (i32)1;
                    }
                gap = gap + (i32)1;
                }
            }
        return runs;
        }

    // Is line `i` the last of its paragraph — the last line overall, or the one before a newline?
    // Justification asks this, and only the layout can answer it.
    static bool isParagraphEnd(u8* text, Array<UXRange>* lines, u16 i)
        {
        if (i + (u16)1 >= lines.count())
            {
            return true;
            }
        UXRange* ln = (UXRange* ?)lines.get(i);
        i32 after = ln.loc + ln.len;
        while (text[after] == (u8)' ')
            {
            after = after + (i32)1;
            }
        return text[after] == (u8)10 || text[after] == (u8)0;
        }

    // ---- rich text ---------------------------------------------------------------------------
    // Width of text[start..end) where every character may carry its own style: split at attribute
    // boundaries and measure each piece in ITS font, because bold is wider than regular and a run
    // measured with the plain metric would overflow the column it was wrapped into.
    static i32 spanWidthAttr(UXAttributedString* as, i32 start, i32 end, i32 baseSize)
        {
        u8* text = as.stringValue();
        i32 total = (i32)0;
        i32 i = start;
        while (i < end)
            {
            UXCharAttr* a = as.attributesAt(i);
            i32 j = i + (i32)1;
            while (j < end && as.attributesAt(j).sameAs(a))
                {
                j = j + (i32)1;
                }
            i32 n = j - i;
            if (n > (i32)UX_TL_SCRATCH - (i32)1)
                {
                n = (i32)UX_TL_SCRATCH - (i32)1;
                }
            for (i32 k = (i32)0; k < n; k = k + (i32)1)
                {
                gTLScratch[k] = text[i + k];
                }
            gTLScratch[n] = (u8)0;
            i32 sz = a.size > (i16)0 ? (i32)a.size : baseSize;
            if (gDriver == (UXViewDriver*)0)
                {
                total = total + n * (i32)8;
                }
            else
                {
                total = total + gDriver.textWidthStyled((u8*)&gTLScratch[(i32)0], (u8*)"", sz, a.bold, a.italic);
                }
            i = j;
            }
        return total;
        }

    // wrapFont for attributed text: identical greedy rule, measured per style.
    static Array<UXRange>* wrapAttr(UXAttributedString* as, i16 width, i32 baseSize)
        {
        Array<UXRange>* lines = new Array();
        u8* text = as.stringValue();
        i32 n = as.length();
        i32 lineStart = (i32)-1;
        i32 lineEnd = (i32)-1;
        i32 i = (i32)0;
        while (i < n)
            {
            u8 c = text[i];
            if (c == (u8)10)
                {
                if (lineStart >= (i32)0)
                    {
                    lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                    }
                else
                    {
                    lines.add(UXRange.make(i, (i32)0));
                    }
                lineStart = (i32)-1;
                i = i + (i32)1;
                continue;
                }
            if (c == (u8)' ')
                {
                i = i + (i32)1;
                continue;
                }
            i32 wordStart = i;
            while (i < n && text[i] != (u8)' ' && text[i] != (u8)10)
                {
                i = i + (i32)1;
                }
            i32 wordEnd = i;
            if (lineStart >= (i32)0 && UXTextLayout.spanWidthAttr(as, lineStart, wordEnd, baseSize) <= (i32)width)
                {
                lineEnd = wordEnd;
                continue;
                }
            if (lineStart >= (i32)0)
                {
                lines.add(UXRange.make(lineStart, lineEnd - lineStart));
                lineStart = (i32)-1;
                }
            i32 p = wordStart;
            while (UXTextLayout.spanWidthAttr(as, p, wordEnd, baseSize) > (i32)width)
                {
                i32 fit = (i32)0;
                for (i32 k = (i32)1; p + k <= wordEnd; k = k + (i32)1)
                    {
                    if (UXTextLayout.spanWidthAttr(as, p, p + k, baseSize) > (i32)width)
                        {
                        break;
                        }
                    fit = k;
                    }
                if (fit <= (i32)0)
                    {
                    fit = (i32)1;
                    }
                if (p + fit >= wordEnd)
                    {
                    break;
                    }
                lines.add(UXRange.make(p, fit));
                p = p + fit;
                }
            lineStart = p;
            lineEnd = wordEnd;
            }
        if (lineStart >= (i32)0)
            {
            lines.add(UXRange.make(lineStart, lineEnd - lineStart));
            }
        return lines;
        }

    // One attributed line, aligned within `measure`, as STYLE runs to draw.  A line is cut at every
    // attribute change (so each run draws in one font) and, when justified, at every word as well —
    // the two cuts compose: the x of a piece is where the alignment put its word plus how far into
    // that word the style change fell.
    static Array<UXTextRun>* layoutLineAttr(UXAttributedString* as, UXRange* ln, i16 measure, i32 baseSize,
                                            i32 align, bool isLast)
        {
        Array<UXTextRun>* out = new Array();
        if (ln.len <= (i32)0)
            {
            return out;
            }
        u8* text = as.stringValue();
        // Word/alignment placement first, on the text alone.
        Array<UXTextRun>* placed = UXTextLayout.layoutLineWidth(as, ln, measure, baseSize, align, isLast);
        for (u16 r = (u16)0; r < placed.count(); r = r + (u16)1)
            {
            UXTextRun* pr = (UXTextRun* ?)placed.get(r);
            i32 end = pr.loc + pr.len;
            i32 i = pr.loc;
            i32 x = pr.x;
            // cut this piece at attribute boundaries
            while (i < end)
                {
                UXCharAttr* a = as.attributesAt(i);
                i32 j = i + (i32)1;
                while (j < end && as.attributesAt(j).sameAs(a))
                    {
                    j = j + (i32)1;
                    }
                out.add(UXTextRun.styled(i, j - i, x, a));
                x = x + UXTextLayout.spanWidthAttr(as, i, j, baseSize);
                i = j;
                }
            }
        return out;
        }

    // The alignment solve for attributed text — layoutLine's shape, measuring per style.
    static Array<UXTextRun>* layoutLineWidth(UXAttributedString* as, UXRange* ln, i16 measure, i32 baseSize,
                                             i32 align, bool isLast)
        {
        Array<UXTextRun>* runs = new Array();
        u8* text = as.stringValue();
        i32 start = ln.loc;
        i32 end = ln.loc + ln.len;
        i32 w = UXTextLayout.spanWidthAttr(as, start, end, baseSize);
        i32 slack = (i32)measure - w;
        if (slack < (i32)0)
            {
            slack = (i32)0;
            }
        if (align == (i32)UX_ALIGN_CENTER)
            {
            runs.add(UXTextRun.at(start, ln.len, slack / (i32)2));
            return runs;
            }
        if (align == (i32)UX_ALIGN_RIGHT)
            {
            runs.add(UXTextRun.at(start, ln.len, slack));
            return runs;
            }
        if (align != (i32)UX_ALIGN_JUSTIFY || isLast || slack == (i32)0)
            {
            runs.add(UXTextRun.at(start, ln.len, (i32)0));
            return runs;
            }
        i32 gaps = (i32)0;
            {
            i32 i = start;
            while (i < end)
                {
                while (i < end && text[i] != (u8)' ')
                    {
                    i = i + (i32)1;
                    }
                while (i < end && text[i] == (u8)' ')
                    {
                    i = i + (i32)1;
                    }
                if (i < end)
                    {
                    gaps = gaps + (i32)1;
                    }
                }
            }
        if (gaps == (i32)0)
            {
            runs.add(UXTextRun.at(start, ln.len, (i32)0));
            return runs;
            }
        i32 per = slack / gaps;
        i32 extra = slack - per * gaps;
        i32 x = (i32)0;
        i32 i = start;
        i32 gap = (i32)0;
        while (i < end)
            {
            i32 wordStart = i;
            while (i < end && text[i] != (u8)' ')
                {
                i = i + (i32)1;
                }
            i32 wordEnd = i;
            runs.add(UXTextRun.at(wordStart, wordEnd - wordStart, x));
            x = x + UXTextLayout.spanWidthAttr(as, wordStart, wordEnd, baseSize);
            i32 spaceStart = i;
            while (i < end && text[i] == (u8)' ')
                {
                i = i + (i32)1;
                }
            if (i < end)
                {
                x = x + UXTextLayout.spanWidthAttr(as, spaceStart, i, baseSize) + per;
                if (gap < extra)
                    {
                    x = x + (i32)1;
                    }
                gap = gap + (i32)1;
                }
            }
        return runs;
        }

    // Convenience: just the line count for a width.
    static i32 lineCount(u8* text, i16 width, i16 charWidth)
        {
        return (i32)UXTextLayout.wrap(text, width, charWidth).count();
        }
    }
