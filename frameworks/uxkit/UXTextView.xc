// UXTextView.xc — an editable, multi-line rich-text view.
//
// The content is a Foundation AttributedString whose attributes are the ones UXTextStyle names:
// bold, italic, underline, monospace, color, size, and alignment, which applies to a whole
// paragraph.  Other attributes the app sets are kept in the model but not shown.
//
// A backend that has the driver's textView* methods makes the view natively (NSTextView on AppKit)
// and owns the editing: typing, the caret and selection, the clipboard, undo, scrolling and input
// methods.  The view then reads the native content back whenever the user changes it, so
// attributedText() is always current.  Until the native view exists, and on a backend without
// one, the view edits its own model.  Undo is the native view's where the backend has it
// (textViewUndo); elsewhere the view keeps its own, recording each run of typing as one step.
//
// Offsets are UTF-8 bytes, as everywhere in Foundation's strings.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXTextStyle.xc"
#import "UXTextLayout.xc"
#import "UXViewDriver.xc"
#import "UXLibc.xc"
#import "AttributedString.xc"
#import "UndoManager.xc"
#import "Range.xc"
#import "Map.xc"
#import "Number.xc"
#import "UXPasteboard.xc"
#import "UXString.xc"

#define UX_TV_BOLD 1
#define UX_TV_ITALIC 2
#define UX_TV_UNDERLINE 4
#define UX_TV_MONO 8
#define UX_TV_PAD 4   // the drawn view's inset
#define UX_TV_SIZE 13 // the drawn view's text size

protocol UXTextViewDelegate
    {
    optional void textDidChange(UXTextView * tv);
    optional void selectionDidChange(UXTextView * tv);
    }

class UXTextView : UXView
    {
    AttributedString* model;
    i32 selStart;
    i32 selLen;
    i32 nativeWin; // the window and node of the native view, -1 until the backend makes it
    i32 nativeNode;
    UndoManager* undoer; // the model's own undo, used while there is no native view
    UXTextStyle* typing; // the style typing gets at an empty selection
    bool typingRun;      // the user's edits since the last other change are one undo step
    i32 caret;           // the drawn view's caret and the selection's anchor (the end that stays)
    i32 anchor;
    i32 scrollY;
    // the look: colours 0xRRGGBB or -1 for the platform's; the default size (0: the platform's)
    i32 background;
    i32 ink;
    i32 caretColor;
    i32 selectionColor;
    i32 baseSize;
    bool baseMono;
    weak : UXTextViewDelegate* delegate;

    void init(void)
        {
        super.init();
        model = AttributedString.withString(String.withCString((u8*)""));
        selStart = (i32)0;
        selLen = (i32)0;
        nativeWin = (i32)-1;
        nativeNode = (i32)-1;
        undoer = new UndoManager();
        typing = new UXTextStyle();
        typingRun = false;
        caret = (i32)0;
        anchor = (i32)0;
        scrollY = (i32)0;
        background = (i32)-1;
        ink = (i32)-1;
        caretColor = (i32)-1;
        selectionColor = (i32)-1;
        baseSize = (i32)0;
        baseMono = false;
        }

    UXKind kind(void)
        {
        callback f void(i32 handle, i32 node, u8 * text, i32 nbytes, i32 * runs, i32 nruns) = &gDriver.textViewSetAll;
        return f ? UXKindTextView : UXKindView;
        }

    // The backend finds the view from its node (to attach the native view and report edits).
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    bool isNative(void)
        {
        return nativeWin >= (i32)0;
        }

    // Whether the native view keeps the undo (or this view does).
    bool nativeUndoes(void)
        {
        callback f i32(i32 handle, i32 node, i32 what) = &gDriver.textViewUndo;
        return self.isNative() && f;
        }

    // ---- content -----------------------------------------------------------------------------

    // Replaces the whole content (not an undoable edit) and puts the caret at the start.
    void setAttributedText(AttributedString* as)
        {
        model = as != (AttributedString*)0 ? as.copy() : AttributedString.withString(String.withCString((u8*)""));
        selStart = (i32)0;
        selLen = (i32)0;
        undoer.removeAllActions();
        if (self.isNative())
            {
            self.pushAll();
            self.pushSelection();
            }
        self.setNeedsDisplay();
        }

    void setText(String* text)
        {
        self.setAttributedText(AttributedString.withString(text));
        }

    // A copy of the content as it is now.
    AttributedString* attributedText(void)
        {
        return model.copy();
        }

    String* text(void)
        {
        return model.text();
        }

    i32 length(void)
        {
        return model.length();
        }

    // ---- selection ---------------------------------------------------------------------------

    Range* selectedRange(void)
        {
        if (self.isNative())
            {
            callback f void(i32 handle, i32 node, i32 * start, i32 * len) = &gDriver.textViewSelection;
            if (f)
                {
                i32 s = (i32)0;
                i32 l = (i32)0;
                f(nativeWin, nativeNode, &s, &l);
                selStart = s;
                selLen = l;
                }
            }
        return Range.make(selStart, selLen);
        }

    void setSelectedRange(Range* r)
        {
        i32 n = model.length();
        i32 s = r.loc < (i32)0 ? (i32)0 : (r.loc > n ? n : r.loc);
        i32 e = s + r.len > n ? n : s + r.len;
        selStart = s;
        selLen = e < s ? (i32)0 : e - s;
        caret = selStart + selLen;
        anchor = selStart;
        typing = self.styleBefore(selStart);
        typingRun = false;
        if (self.isNative())
            {
            self.pushSelection();
            }
        self.fireSelection();
        }

    // Puts the keyboard focus in the view.
    void focus(void)
        {
        callback f void(i32 handle, i32 node) = &gDriver.textViewFocus;
        if (self.isNative() && f)
            {
            f(nativeWin, nativeNode);
            }
        }

    // ---- editing -----------------------------------------------------------------------------

    // Replaces the selection with text, in the typing style, and leaves the caret after it.
    void insertText(String* text)
        {
        Range* sel = self.selectedRange();
        AttributedString* piece = AttributedString.withAttributes(text, self.attrsOf(typing));
        i32 n = piece.length();
        typingRun = false;
        if (self.isNative())
            {
            if (!self.nativeUndoes())
                {
                self.snapshot();
                }
            self.pushReplace(sel.loc, sel.len, piece, (i32)0);
            self.pull();
            selStart = sel.loc + n;
            selLen = (i32)0;
            self.pushSelection();
            }
        else
            {
            self.snapshot();
            model.replaceWithAttributed(sel, piece);
            selStart = sel.loc + n;
            selLen = (i32)0;
            self.fireChange();
            }
        }

    // Bold, italic and underline each turn on over the selection unless all of it has them already,
    // in which case they turn off.  An empty selection changes what typing gets.
    void toggleBold(void)
        {
        self.toggle((u8*)"bold", UX_TV_BOLD);
        }

    void toggleItalic(void)
        {
        self.toggle((u8*)"italic", UX_TV_ITALIC);
        }

    void toggleUnderline(void)
        {
        self.toggle((u8*)"underline", UX_TV_UNDERLINE);
        }

    // A colour (0xRRGGBB) over the selection; -1 returns it to the view's ink.
    void setColor(i32 rgb)
        {
        Range* sel = self.selectedRange();
        typing.color = rgb;
        if (sel.len == (i32)0)
            {
            self.pushTyping();
            return;
            }
        self.restyle((u8*)"color", rgb >= (i32)0 ? (Object*)Number.with(rgb) : (Object*)0, sel.loc, sel.len);
        }

    // A point size over the selection; 0 returns it to the default.
    void setFontSize(i32 size)
        {
        Range* sel = self.selectedRange();
        typing.size = (i16)size;
        if (sel.len == (i32)0)
            {
            self.pushTyping();
            return;
            }
        self.restyle((u8*)"size", size > (i32)0 ? (Object*)Number.with(size) : (Object*)0, sel.loc, sel.len);
        }

    // The alignment (UX_ALIGN_*) of every paragraph the selection touches.
    void setAlignment(i32 align)
        {
        Range* sel = self.selectedRange();
        typing.alignment = align;
        i32 s = self.paragraphStart(sel.loc);
        i32 e = self.paragraphEnd(sel.loc + sel.len);
        if (e < model.length())
            {
            e = e + (i32)1; // a paragraph's newline is part of it
            }
        if (e <= s)
            {
            self.pushTyping();
            return;
            }
        self.restyle((u8*)"alignment", align != (i32)UX_ALIGN_LEFT ? (Object*)Number.with(align) : (Object*)0, s, e - s);
        }

    // The style at the selection: of its first byte, or what typing gets at an empty one.
    UXTextStyle* selectionStyle(void)
        {
        Range* sel = self.selectedRange();
        if (sel.len == (i32)0)
            {
            return typing;
            }
        return UXTextStyle.at(model, sel.loc);
        }

    // ---- the look ----------------------------------------------------------------------------
    // Colours are 0xRRGGBB; -1 returns one to the platform's.  The ink is the colour of text with no
    // colour of its own (a run's color attribute overrides it).

    void setBackgroundColor(i32 rgb)
        {
        background = rgb;
        self.lookChanged();
        }

    void setInk(i32 rgb)
        {
        ink = rgb;
        self.lookChanged();
        }

    void setCaretColor(i32 rgb)
        {
        caretColor = rgb;
        self.lookChanged();
        }

    void setSelectionColor(i32 rgb)
        {
        selectionColor = rgb;
        self.lookChanged();
        }

    // The size of text with no size of its own, in the view's pixels; 0 is the platform's.
    void setDefaultFontSize(i32 size)
        {
        baseSize = size;
        self.lookChanged();
        }

    // Whether text with no face of its own is monospace.
    void setMonospace(bool on)
        {
        baseMono = on;
        self.lookChanged();
        }

    void lookChanged(void)
        {
        if (self.isNative())
            {
            self.pushLook();
            self.pushAll(); // the content again, drawn against the new defaults
            self.pushSelection();
            }
        self.setNeedsDisplay();
        }

    static i32 packColour(i32 rgb)
        {
        return rgb >= (i32)0 ? ((i32)0x01000000 | (rgb & (i32)0xFFFFFF)) : (i32)0;
        }

    void pushLook(void)
        {
        callback f void(i32 handle, i32 node, i32 background, i32 ink, i32 caret, i32 selection, i32 size,
                        i32 monospace) = &gDriver.textViewSetLook;
        if (f)
            {
            f(nativeWin, nativeNode, UXTextView.packColour(background), UXTextView.packColour(ink),
              UXTextView.packColour(caretColor), UXTextView.packColour(selectionColor), baseSize,
              baseMono ? (i32)1 : (i32)0);
            }
        }

    // ---- undo --------------------------------------------------------------------------------

    void undo(void)
        {
        typingRun = false;
        if (self.nativeUndoes())
            {
            self.nativeUndo((i32)0);
            self.pull();
            self.fireChange();
            return;
            }
        undoer.undo();
        }

    void redo(void)
        {
        typingRun = false;
        if (self.nativeUndoes())
            {
            self.nativeUndo((i32)1);
            self.pull();
            self.fireChange();
            return;
            }
        undoer.redo();
        }

    bool canUndo(void)
        {
        return self.nativeUndoes() ? self.nativeUndo((i32)2) != (i32)0 : undoer.canUndo();
        }

    bool canRedo(void)
        {
        return self.nativeUndoes() ? self.nativeUndo((i32)3) != (i32)0 : undoer.canRedo();
        }

    // ---- from the backend --------------------------------------------------------------------

    // The backend made the native view for this node: give it the content.
    void nativeAttach(i32 handle, i32 node)
        {
        nativeWin = handle;
        nativeNode = node;
        self.pushLook();
        self.pushAll();
        self.pushSelection();
        self.pushTyping();
        }

    // The user changed the text in the native view.
    void nativeDidChange(void)
        {
        if (!self.nativeUndoes() && !typingRun)
            {
            self.snapshot(); // the model is still the content before this edit
            typingRun = true;
            }
        self.pull();
        self.fireChange();
        }

    // The user moved the caret or the selection in the native view.
    void nativeDidSelect(void)
        {
        Range* sel = self.selectedRange();
        typing = self.styleBefore(sel.loc);
        typingRun = false;
        self.fireSelection();
        }

    // ---- the drawn view, where there is no native one (GEM) --------------------------------------
    // The view lays its model out with UXTextLayout, draws each run in its style with the selection
    // behind it and the caret, and does the editing itself: typing, Backspace and Delete, Return, the
    // arrows, Home and End (Shift extends the selection), a click and a drag, the wheel, the clipboard
    // and the undo keys (Control-Z, Shift-Control-Z, Control-Y), a run of typing being one step.

    bool acceptsFirstResponder(void)
        {
        return !self.isNative();
        }

    // The drawn view's default size.
    i32 size0(void)
        {
        return baseSize > (i32)0 ? baseSize : (i32)UX_TV_SIZE;
        }

    // A colour of the look as red, green, blue, or the given default.
    static i32 part(i32 rgb, i32 dflt, i32 shift)
        {
        i32 c = rgb >= (i32)0 ? rgb : dflt;
        return (c >> shift) & (i32)255;
        }

    // The lines as laid out for the view's width.
    Array<Range>* drawnLines(void)
        {
        UXRect b = self.bounds();
        i16 measure = (i16)((i32)b.w - (i32)UX_TV_PAD * (i32)2);
        return UXTextLayout.wrapAttr(model, measure > (i16)8 ? measure : (i16)8, self.size0());
        }

    // A line's height: room for the largest size on it.
    i32 lineHeightOf(Range* ln)
        {
        i32 big = self.size0();
        for (i32 i = ln.loc; i < ln.loc + ln.len; i = UXTextLayout.styleEnd(model, i, ln.loc + ln.len))
            {
            UXTextStyle* st = UXTextStyle.at(model, i);
            if ((i32)st.size > big)
                {
                big = (i32)st.size;
                }
            }
        return big + (i32)5;
        }

    // The x where byte i of a line falls, from the view's left edge, alignment included.
    i32 xIn(Range* ln, i32 i, i32 measure)
        {
        i32 w = UXTextLayout.spanWidthAttr(model, ln.loc, ln.loc + ln.len, self.size0());
        i32 al = model.length() > (i32)0 ? UXTextStyle.at(model, ln.loc < model.length() ? ln.loc : model.length() - (i32)1).alignment : (i32)0;
        i32 off = al == (i32)UX_ALIGN_RIGHT ? measure - w : (al == (i32)UX_ALIGN_CENTER ? (measure - w) / (i32)2 : (i32)0);
        if (off < (i32)0)
            {
            off = (i32)0;
            }
        return (i32)UX_TV_PAD + off + UXTextLayout.spanWidthAttr(model, ln.loc, i, self.size0());
        }

    // The line byte i is on (a byte at a line's end belongs to it).
    u16 lineOf(Array<Range>* lines, i32 i)
        {
        u16 n = lines.count();
        for (u16 k = (u16)0; k < n; k = k + (u16)1)
            {
            Range* ln = (Range* ?)lines.get(k);
            Range* nx = k + (u16)1 < n ? (Range* ?)lines.get(k + (u16)1) : (Range*)0;
            if (nx == (Range*)0 || i < nx.loc)
                {
                return k;
                }
            }
        return n > (u16)0 ? n - (u16)1 : (u16)0;
        }

    // The byte nearest a point in the view.
    i32 indexAt(i32 px, i32 py)
        {
        Array<Range>* lines = self.drawnLines();
        UXRect b = self.bounds();
        i32 measure = (i32)b.w - (i32)UX_TV_PAD * (i32)2;
        i32 y = (i32)UX_TV_PAD - scrollY;
        for (u16 k = (u16)0; k < lines.count(); k = k + (u16)1)
            {
            Range* ln = (Range* ?)lines.get(k);
            i32 lh = self.lineHeightOf(ln);
            if (py < y + lh || k + (u16)1 == lines.count())
                {
                i32 best = ln.loc;
                i32 bestD = (i32)1000000;
                i32 i = ln.loc;
                while (i <= ln.loc + ln.len)
                    {
                    i32 d = self.xIn(ln, i, measure) - px;
                    d = d < (i32)0 ? (i32)0 - d : d;
                    if (d < bestD)
                        {
                        bestD = d;
                        best = i;
                        }
                    if (i == ln.loc + ln.len)
                        {
                        break;
                        }
                    i = self.nextChar(i);
                    }
                return best;
                }
            y = y + lh;
            }
        return model.length();
        }

    // UTF-8 character boundaries either side of byte i.
    i32 nextChar(i32 i)
        {
        String* t = model.text();
        u8* p = t.cString();
        i32 n = model.length();
        i32 k = i + (i32)1;
        while (k < n && (p[k] & (u8)$C0) == (u8)$80)
            {
            k = k + (i32)1;
            }
        return k > n ? n : k;
        }

    i32 prevChar(i32 i)
        {
        String* t = model.text();
        u8* p = t.cString();
        i32 k = i - (i32)1;
        while (k > (i32)0 && (p[k] & (u8)$C0) == (u8)$80)
            {
            k = k - (i32)1;
            }
        return k < (i32)0 ? (i32)0 : k;
        }

    // The caret moves to i: with extend, the selection runs from the anchor to i.
    void moveTo(i32 i, bool extend)
        {
        i32 n = model.length();
        i32 c = i < (i32)0 ? (i32)0 : (i > n ? n : i);
        if (!extend)
            {
            anchor = c;
            }
        selStart = c < anchor ? c : anchor;
        selLen = c < anchor ? anchor - c : c - anchor;
        caret = c;
        typing = self.styleBefore(selStart);
        typingRun = false;
        self.scrollToCaret();
        self.setNeedsDisplay();
        self.fireSelection();
        }

    // Text typed at the selection, in the typing style; a run of it is one undo step.
    void typeText(String* text)
        {
        if (!typingRun)
            {
            self.snapshot();
            typingRun = true;
            }
        AttributedString* piece = AttributedString.withAttributes(text, self.attrsOf(typing));
        model.replaceWithAttributed(Range.make(selStart, selLen), piece);
        selStart = selStart + piece.length();
        selLen = (i32)0;
        caret = selStart;
        anchor = selStart;
        self.scrollToCaret();
        self.fireChange();
        }

    // Bytes [s, e) removed, as one undo step of their own.
    void removeRange(i32 s, i32 e)
        {
        if (e <= s)
            {
            return;
            }
        self.snapshot();
        typingRun = false;
        model.replace(Range.make(s, e - s), String.withCString((u8*)""));
        selStart = s;
        selLen = (i32)0;
        caret = s;
        anchor = s;
        typing = self.styleBefore(s);
        self.scrollToCaret();
        self.fireChange();
        }

    void scrollToCaret(void)
        {
        Array<Range>* lines = self.drawnLines();
        UXRect b = self.bounds();
        u16 l = self.lineOf(lines, caret);
        i32 top = (i32)0;
        i32 lh = self.size0() + (i32)5;
        for (u16 k = (u16)0; k < lines.count(); k = k + (u16)1)
            {
            Range* ln = (Range* ?)lines.get(k);
            lh = self.lineHeightOf(ln);
            if (k == l)
                {
                break;
                }
            top = top + lh;
            }
        i32 view = (i32)b.h - (i32)UX_TV_PAD * (i32)2;
        if (top < scrollY)
            {
            scrollY = top;
            }
        else if (top + lh > scrollY + view)
            {
            scrollY = top + lh - view;
            }
        }

    void keyDown(UXEvent* e)
        {
        if (self.isNative())
            {
            super.keyDown(e);
            return;
            }
        i32 ascii = (i32)e.key & (i32)$FF;
        i32 scan = ((i32)e.key >> (i32)8) & (i32)$FF;
        bool shift = ((u16)e.modifiers & (u16)UX_MOD_SHIFT) != (u16)0;
        bool ctrl = ((u16)e.modifiers & (u16)UX_MOD_CTRL) != (u16)0;
        // the editing keys with Control: a letter's code, or the letter itself
        i32 letter = ascii >= (i32)1 && ascii <= (i32)26 ? ascii + (i32)96 : (ascii >= (i32)65 && ascii <= (i32)90 ? ascii + (i32)32 : ascii);
        if (ctrl)
            {
            if (letter == (i32)'z' || letter == (i32)'y')
                {
                if (letter == (i32)'y' || shift)
                    {
                    self.redo();
                    }
                else
                    {
                    self.undo();
                    }
                return;
                }
            if (letter == (i32)'a')
                {
                anchor = (i32)0;
                self.moveTo(model.length(), true);
                return;
                }
            if (letter == (i32)'c' || letter == (i32)'x')
                {
                if (selLen > (i32)0)
                    {
                    String* piece = model.substring(Range.make(selStart, selLen)).text();
                    UXPasteboard.general().writeText(UXStr.dup(piece.cString()));
                    if (letter == (i32)'x')
                        {
                        self.removeRange(selStart, selStart + selLen);
                        }
                    }
                return;
                }
            if (letter == (i32)'v')
                {
                u8* got = UXPasteboard.general().text();
                if (got != (u8*)0 && got[0] != (u8)0)
                    {
                    typingRun = false;
                    self.typeText(String.withCString(got));
                    typingRun = false;
                    }
                return;
                }
            }
        // the moving keys, by scan code (GEM's), and their Shift forms
        if (scan == (i32)$4B || scan == (i32)$73)
            {
            i32 to = selLen > (i32)0 && !shift ? selStart : self.prevChar(caret);
            self.moveTo(to, shift);
            return;
            }
        if (scan == (i32)$4D || scan == (i32)$74)
            {
            i32 to = selLen > (i32)0 && !shift ? selStart + selLen : self.nextChar(caret);
            self.moveTo(to, shift);
            return;
            }
        if (scan == (i32)$48 || scan == (i32)$50)
            {
            Array<Range>* lines = self.drawnLines();
            UXRect b = self.bounds();
            i32 measure = (i32)b.w - (i32)UX_TV_PAD * (i32)2;
            u16 l = self.lineOf(lines, caret);
            Range* cur = (Range* ?)lines.get(l);
            i32 x = self.xIn(cur, caret, measure);
            i32 target = scan == (i32)$48 ? (i32)l - (i32)1 : (i32)l + (i32)1;
            if (target < (i32)0)
                {
                self.moveTo((i32)0, shift);
                return;
                }
            if (target >= (i32)lines.count())
                {
                self.moveTo(model.length(), shift);
                return;
                }
            Range* ln = (Range* ?)lines.get((u16)target);
            i32 best = ln.loc;
            i32 bestD = (i32)1000000;
            for (i32 i = ln.loc; i <= ln.loc + ln.len; i = i == ln.loc + ln.len ? i + (i32)1 : self.nextChar(i))
                {
                i32 d = self.xIn(ln, i, measure) - x;
                d = d < (i32)0 ? (i32)0 - d : d;
                if (d < bestD)
                    {
                    bestD = d;
                    best = i;
                    }
                }
            self.moveTo(best, shift);
            return;
            }
        if (scan == (i32)$47 || scan == (i32)$4F)
            {
            Array<Range>* lines = self.drawnLines();
            Range* ln = (Range* ?)lines.get(self.lineOf(lines, caret));
            self.moveTo(scan == (i32)$47 ? ln.loc : ln.loc + ln.len, shift);
            return;
            }
        if (ascii == (i32)8)
            {
            if (selLen > (i32)0)
                {
                self.removeRange(selStart, selStart + selLen);
                }
            else if (caret > (i32)0)
                {
                self.removeRange(self.prevChar(caret), caret);
                }
            return;
            }
        if (ascii == (i32)127 || scan == (i32)$53)
            {
            if (selLen > (i32)0)
                {
                self.removeRange(selStart, selStart + selLen);
                }
            else if (caret < model.length())
                {
                self.removeRange(caret, self.nextChar(caret));
                }
            return;
            }
        if (ascii == (i32)13 || ascii == (i32)10)
            {
            self.typeText(String.withCString((u8*)"\n"));
            return;
            }
        if (ascii >= (i32)32 && ascii < (i32)127 && !ctrl)
            {
            u8 one[2];
            one[0] = (u8)ascii;
            one[1] = (u8)0;
            self.typeText(String.withCString(&one[0]));
            return;
            }
        super.keyDown(e); // not the view's: up the chain
        }

    void mouseDown(UXEvent* e)
        {
        if (self.isNative())
            {
            return;
            }
        UXRect a = self.absoluteFrame();
        self.moveTo(self.indexAt((i32)e.x - (i32)a.x, (i32)e.y - (i32)a.y), false);
        }

    void mouseDragged(UXEvent* e)
        {
        if (self.isNative())
            {
            return;
            }
        UXRect a = self.absoluteFrame();
        self.moveTo(self.indexAt((i32)e.x - (i32)a.x, (i32)e.y - (i32)a.y), true);
        }

    void scrollWheel(UXEvent* e)
        {
        if (self.isNative())
            {
            return;
            }
        scrollY = scrollY - e.a * (self.size0() + (i32)5) * (i32)3;
        scrollY = scrollY < (i32)0 ? (i32)0 : scrollY;
        self.setNeedsDisplay();
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(b, UXTextView.part(background, (i32)0xFFFFFF, (i32)16), UXTextView.part(background, (i32)0xFFFFFF, (i32)8),
                      UXTextView.part(background, (i32)0xFFFFFF, (i32)0));
        i16 r = (i16)((i32)b.x + (i32)b.w - (i32)1);
        i16 bt = (i16)((i32)b.y + (i32)b.h - (i32)1);
        g.drawLine(b.x, b.y, r, b.y, (i32)9);
        g.drawLine(b.x, bt, r, bt, (i32)9);
        g.drawLine(b.x, b.y, b.x, bt, (i32)9);
        g.drawLine(r, b.y, r, bt, (i32)9);
        String* textStr = model.text(); // held while its bytes are read
        u8* text = textStr.cString();
        Array<Range>* lines = self.drawnLines();
        i32 measure = (i32)b.w - (i32)UX_TV_PAD * (i32)2;
        i32 y = (i32)UX_TV_PAD - scrollY;
        for (u16 k = (u16)0; k < lines.count(); k = k + (u16)1)
            {
            Range* ln = (Range* ?)lines.get(k);
            i32 lh = self.lineHeightOf(ln);
            if (y + lh < (i32)0)
                {
                y = y + lh;
                continue;
                }
            if (y > (i32)b.h)
                {
                break;
                }
            // the selection behind this line's part of it
            i32 s0 = selStart > ln.loc ? selStart : ln.loc;
            i32 s1 = selStart + selLen < ln.loc + ln.len ? selStart + selLen : ln.loc + ln.len;
            if (selLen > (i32)0 && s1 > s0)
                {
                i32 x0 = self.xIn(ln, s0, measure);
                i32 x1 = self.xIn(ln, s1, measure);
                g.fillRectRGB(UXGeom.make((i16)x0, (i16)y, (i16)(x1 - x0), (i16)lh), UXTextView.part(selectionColor, (i32)0xB4CDF5, (i32)16),
                              UXTextView.part(selectionColor, (i32)0xB4CDF5, (i32)8), UXTextView.part(selectionColor, (i32)0xB4CDF5, (i32)0));
                }
            // the runs, each in its style
            i32 i = ln.loc;
            while (i < ln.loc + ln.len)
                {
                i32 j = UXTextLayout.styleEnd(model, i, ln.loc + ln.len);
                UXTextStyle* st = UXTextStyle.at(model, i);
                i32 n = j - i;
                u8* piece = (u8*)malloc((u32)n + (u32)1);
                for (i32 q = (i32)0; q < n; q = q + (i32)1)
                    {
                    piece[q] = text[i + q] == (u8)10 ? (u8)32 : text[i + q];
                    }
                piece[n] = (u8)0;
                i32 x = self.xIn(ln, i, measure);
                i32 sz = st.size > (i16)0 ? (i32)st.size : self.size0();
                i32 rgb = st.color >= (i32)0 ? st.color : (ink >= (i32)0 ? ink : (i32)0);
                g.drawTextFontRGBA(piece, (i16)x, (i16)(y + lh - sz - (i32)3), st.monospace || baseMono ? (u8*)"monospace" : (u8*)"",
                                   sz, st.bold ? (i32)UXWEIGHT_BOLD : (i32)UXWEIGHT_NORMAL, st.italic,
                                   (rgb >> (i32)16) & (i32)255, (rgb >> (i32)8) & (i32)255, rgb & (i32)255, (i32)255);
                if (st.underline)
                    {
                    i32 xe = self.xIn(ln, j, measure);
                    g.fillRectRGB(UXGeom.make((i16)x, (i16)(y + lh - (i32)3), (i16)(xe - x), (i16)1),
                                  (rgb >> (i32)16) & (i32)255, (rgb >> (i32)8) & (i32)255, rgb & (i32)255);
                    }
                free((pointer)piece);
                i = j;
                }
            // the caret
            if (selLen == (i32)0 && self.lineOf(lines, caret) == k)
                {
                i32 cx = self.xIn(ln, caret, measure);
                g.fillRectRGB(UXGeom.make((i16)cx, (i16)(y + (i32)1), (i16)1, (i16)(lh - (i32)2)), UXTextView.part(caretColor, ink >= (i32)0 ? ink : (i32)0, (i32)16),
                          UXTextView.part(caretColor, ink >= (i32)0 ? ink : (i32)0, (i32)8),
                          UXTextView.part(caretColor, ink >= (i32)0 ? ink : (i32)0, (i32)0));
                }
            y = y + lh;
            }
        }

    // ---- inside ------------------------------------------------------------------------------

    void toggle(u8* name, i32 flag)
        {
        Range* sel = self.selectedRange();
        if (sel.len == (i32)0)
            {
            bool v = !self.hasFlag(typing, flag);
            self.setFlag(typing, flag, v);
            self.pushTyping();
            return;
            }
        bool all = true;
        for (i32 i = sel.loc; i < sel.loc + sel.len; i = i + (i32)1)
            {
            if (!self.hasFlag(UXTextStyle.at(model, i), flag))
                {
                all = false;
                break;
                }
            }
        self.setFlag(typing, flag, !all);
        self.restyle(name, all ? (Object*)0 : (Object*)Number.withBool(true), sel.loc, sel.len);
        }

    bool hasFlag(UXTextStyle* st, i32 flag)
        {
        return flag == UX_TV_BOLD ? st.bold : (flag == UX_TV_ITALIC ? st.italic : st.underline);
        }

    void setFlag(UXTextStyle* st, i32 flag, bool v)
        {
        if (flag == UX_TV_BOLD)
            {
            st.bold = v;
            }
        else if (flag == UX_TV_ITALIC)
            {
            st.italic = v;
            }
        else
            {
            st.underline = v;
            }
        }

    // One attribute set (or, with value 0, removed) over bytes [s, s+l), as one undoable edit.
    void restyle(u8* name, Object* value, i32 s, i32 l)
        {
        String* key = String.withCString(name);
        typingRun = false;
        if (self.isNative())
            {
            self.pull();
            if (!self.nativeUndoes())
                {
                self.snapshot();
                }
            AttributedString* piece = model.substring(Range.make(s, l));
            if (value != (Object*)0)
                {
                piece.setAttribute(key, value, Range.make((i32)0, l));
                }
            else
                {
                piece.removeAttribute(key, Range.make((i32)0, l));
                }
            self.pushReplace(s, l, piece, (i32)1);
            self.pull();
            self.fireChange();
            return;
            }
        self.snapshot();
        if (value != (Object*)0)
            {
            model.setAttribute(key, value, Range.make(s, l));
            }
        else
            {
            model.removeAttribute(key, Range.make(s, l));
            }
        self.fireChange();
        }

    // The style typing gets with the caret at i: the byte before it, or the first at the start.
    UXTextStyle* styleBefore(i32 i)
        {
        if (model.length() == (i32)0)
            {
            return typing;
            }
        return UXTextStyle.at(model, i > (i32)0 ? i - (i32)1 : (i32)0);
        }

    i32 paragraphStart(i32 i)
        {
        String* t = model.text();
        u8* p = t.cString();
        i32 k = i;
        while (k > (i32)0 && p[k - (i32)1] != (u8)10)
            {
            k = k - (i32)1;
            }
        return k;
        }

    i32 paragraphEnd(i32 i)
        {
        String* t = model.text();
        u8* p = t.cString();
        i32 n = model.length();
        i32 k = i;
        while (k < n && p[k] != (u8)10)
            {
            k = k + (i32)1;
            }
        return k;
        }

    // The attributes a style stands for, leaving out the defaults.
    Map* attrsOf(UXTextStyle* st)
        {
        Map* m = new Map();
        if (st.bold)
            {
            m.set(String.withCString((u8*)"bold"), Number.withBool(true));
            }
        if (st.italic)
            {
            m.set(String.withCString((u8*)"italic"), Number.withBool(true));
            }
        if (st.underline)
            {
            m.set(String.withCString((u8*)"underline"), Number.withBool(true));
            }
        if (st.monospace)
            {
            m.set(String.withCString((u8*)"monospace"), Number.withBool(true));
            }
        if (st.color >= (i32)0)
            {
            m.set(String.withCString((u8*)"color"), Number.with(st.color));
            }
        if (st.size > (i16)0)
            {
            m.set(String.withCString((u8*)"size"), Number.with((i32)st.size));
            }
        if (st.alignment != (i32)UX_ALIGN_LEFT)
            {
            m.set(String.withCString((u8*)"alignment"), Number.with(st.alignment));
            }
        return m;
        }

    static i32 flagsOf(UXTextStyle* st)
        {
        i32 f = (i32)0;
        if (st.bold)
            {
            f = f | UX_TV_BOLD;
            }
        if (st.italic)
            {
            f = f | UX_TV_ITALIC;
            }
        if (st.underline)
            {
            f = f | UX_TV_UNDERLINE;
            }
        if (st.monospace)
            {
            f = f | UX_TV_MONO;
            }
        return f | ((st.alignment & (i32)3) << (i32)4);
        }

    static i32 colourOf(UXTextStyle* st)
        {
        return st.color >= (i32)0 ? ((i32)0x01000000 | (st.color & (i32)0xFFFFFF)) : (i32)0;
        }

    // The style a packed run stands for.
    static UXTextStyle* styleOfRun(i32 flags, i32 colour, i32 size)
        {
        UXTextStyle* st = new UXTextStyle();
        st.bold = (flags & UX_TV_BOLD) != (i32)0;
        st.italic = (flags & UX_TV_ITALIC) != (i32)0;
        st.underline = (flags & UX_TV_UNDERLINE) != (i32)0;
        st.monospace = (flags & UX_TV_MONO) != (i32)0;
        st.alignment = (flags >> (i32)4) & (i32)3;
        st.color = (colour & (i32)0x01000000) != (i32)0 ? (colour & (i32)0xFFFFFF) : (i32)-1;
        st.size = (i16)size;
        return st;
        }

    // as's runs, packed five i32s each; n receives the count.  The caller frees the result.
    i32* packRuns(AttributedString* as, i32* n)
        {
        u32 k = as.runCount();
        i32* runs = (i32*)malloc(((u32)k + (u32)1) * (u32)5 * (u32)4);
        for (u32 j = (u32)0; j < k; j = j + (u32)1)
            {
            Range* r = as.runRange(j);
            UXTextStyle* st = UXTextStyle.of(as.runAttributes(j));
            i32 o = (i32)j * (i32)5;
            runs[o] = r.loc;
            runs[o + (i32)1] = r.len;
            runs[o + (i32)2] = UXTextView.flagsOf(st);
            runs[o + (i32)3] = UXTextView.colourOf(st);
            runs[o + (i32)4] = (i32)st.size;
            }
        n[0] = (i32)k;
        return runs;
        }

    void pushAll(void)
        {
        callback f void(i32 handle, i32 node, u8 * text, i32 nbytes, i32 * runs, i32 nruns) = &gDriver.textViewSetAll;
        if (!f)
            {
            return;
            }
        String* t = model.text();
        i32 n = (i32)0;
        i32* runs = self.packRuns(model, &n);
        f(nativeWin, nativeNode, t.cString(), model.length(), runs, n);
        free((pointer)runs);
        }

    void pushReplace(i32 s, i32 l, AttributedString* piece, i32 attrsOnly)
        {
        callback f void(i32 handle, i32 node, i32 start, i32 len, u8 * text, i32 nbytes, i32 * runs, i32 nruns,
                        i32 attrsOnly) = &gDriver.textViewReplace;
        if (!f)
            {
            return;
            }
        String* t = piece.text();
        i32 n = (i32)0;
        i32* runs = self.packRuns(piece, &n);
        f(nativeWin, nativeNode, s, l, t.cString(), piece.length(), runs, n, attrsOnly);
        free((pointer)runs);
        }

    void pushSelection(void)
        {
        callback f void(i32 handle, i32 node, i32 start, i32 len) = &gDriver.textViewSetSelection;
        if (f)
            {
            f(nativeWin, nativeNode, selStart, selLen);
            }
        }

    void pushTyping(void)
        {
        callback f void(i32 handle, i32 node, i32 flags, i32 colour, i32 size) = &gDriver.textViewSetTyping;
        if (self.isNative() && f)
            {
            f(nativeWin, nativeNode, UXTextView.flagsOf(typing), UXTextView.colourOf(typing), (i32)typing.size);
            }
        }

    // The model, read back from the native view.
    void pull(void)
        {
        callback size void(i32 handle, i32 node, i32 * nbytes, i32 * nruns) = &gDriver.textViewSize;
        callback rd i32(i32 handle, i32 node, u8 * buf, i32 cap, i32 * runs, i32 maxRuns) = &gDriver.textViewRead;
        if (!self.isNative() || !size || !rd)
            {
            return;
            }
        i32 nb = (i32)0;
        i32 nr = (i32)0;
        size(nativeWin, nativeNode, &nb, &nr);
        u8* buf = (u8*)malloc((u32)nb + (u32)1);
        i32* runs = (i32*)malloc(((u32)nr + (u32)1) * (u32)5 * (u32)4);
        i32 k = rd(nativeWin, nativeNode, buf, nb + (i32)1, runs, nr);
        AttributedString* m = AttributedString.withString(String.withCString(buf));
        for (i32 j = (i32)0; j < k; j = j + (i32)1)
            {
            i32 o = j * (i32)5;
            Map* a = self.attrsOf(UXTextView.styleOfRun(runs[o + (i32)2], runs[o + (i32)3], runs[o + (i32)4]));
            if (a.count() > (u32)0)
                {
                m.setAttributes(a, Range.make(runs[o], runs[o + (i32)1]));
                }
            }
        free((pointer)buf);
        free((pointer)runs);
        model = m;
        }

    i32 nativeUndo(i32 what)
        {
        callback f i32(i32 handle, i32 node, i32 what) = &gDriver.textViewUndo;
        return f ? f(nativeWin, nativeNode, what) : (i32)0;
        }

    // Before a model edit: the content as it was, for undo.
    void snapshot(void)
        {
        undoer.registerUndo(&self.restoreSnapshot, (Object*)model.copy());
        }

    void restoreSnapshot(Object* arg)
        {
        AttributedString* old = (AttributedString* ?)arg;
        if (old == (AttributedString*)0)
            {
            return;
            }
        undoer.registerUndo(&self.restoreSnapshot, (Object*)model.copy()); // so the undo can be redone
        // the caret goes after what changed: past the common start, before the common end
        String* was = model.text();
        String* now = old.text();
        u8* p = was.cString();
        u8* q = now.cString();
        i32 pn = model.length();
        i32 qn = old.length();
        i32 head = (i32)0;
        while (head < pn && head < qn && p[head] == q[head])
            {
            head = head + (i32)1;
            }
        i32 tail = (i32)0;
        while (tail < pn - head && tail < qn - head && p[pn - (i32)1 - tail] == q[qn - (i32)1 - tail])
            {
            tail = tail + (i32)1;
            }
        model = old;
        selStart = qn - tail;
        selLen = (i32)0;
        caret = selStart;
        anchor = selStart;
        typingRun = false;
        if (self.isNative())
            {
            self.pushAll();
            self.pushSelection();
            }
        self.fireChange();
        }

    void fireChange(void)
        {
        self.setNeedsDisplay();
        if (delegate != (UXTextViewDelegate*)0)
            {
            callback f void(UXTextView * tv) = &delegate.textDidChange;
            if (f)
                {
                f(self);
                }
            }
        }

    void fireSelection(void)
        {
        if (delegate != (UXTextViewDelegate*)0)
            {
            callback f void(UXTextView * tv) = &delegate.selectionDidChange;
            if (f)
                {
                f(self);
                }
            }
        }
    }
