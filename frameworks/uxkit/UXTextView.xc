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

#define UX_TV_BOLD 1
#define UX_TV_ITALIC 2
#define UX_TV_UNDERLINE 4
#define UX_TV_MONO 8

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

    // ---- drawing, where there is no native view -------------------------------------------------

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(b, (i32)255, (i32)255, (i32)255);
        String* t = model.text(); // held while its bytes are read
        u8* p = t.cString();
        i32 n = model.length();
        i32 y = (i32)4;
        i32 ls = (i32)0;
        for (i32 i = (i32)0; i <= n; i = i + (i32)1)
            {
            if (i == n || p[i] == (u8)10)
                {
                if (i > ls && y < (i32)b.h)
                    {
                    String* line = model.substring(Range.make(ls, i - ls)).text(); // held while drawn
                    g.drawText(line.cString(), (i16)4, (i16)y, (i32)1, (i32)0);
                    }
                ls = i + (i32)1;
                y = y + (i32)16;
                }
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
        model = old;
        i32 n = model.length();
        selStart = selStart > n ? n : selStart;
        selLen = selStart + selLen > n ? n - selStart : selLen;
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
