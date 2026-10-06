// test_gtk_textview.xc — UXTextView on GTK: the native GtkTextView, content in and out as attributed
// runs, the selection, bold/italic/underline and alignment on the selection, typing in the style
// before it, emoji, and undo and redo (the view's own here: GTK's does not record styles).
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTextView.xc"
#import "UXGeometry.xc"

extern void ux_gtk_test_textview_type(i32 handle, i32 node, u8* text);
extern i32 ux_gtk_test_textview_key(i32 handle, i32 node, i32 key, i32 shift);

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    Stdio.printf("  %s %s\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
void eqi(i32 got, i32 want, u8* what)
    {
    Stdio.printf("  %s %s = %d (want %d)\n", got == want ? (u8*)"ok  " : (u8*)"FAIL", what, got, want);
    if (got != want)
        {
        gFails = gFails + 1;
        }
    }
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
bool textIs(UXTextView* tv, u8* want)
    {
    String* t = tv.text();
    return streq(t.cString(), want);
    }
bool boldAt(UXTextView* tv, i32 i)
    {
    return UXTextStyle.at(tv.attributedText(), i).bold;
    }

class Watcher : Object<UXTextViewDelegate>
    {
    i32 changes;
    i32 selections;
    void init(void)
        {
        changes = (i32)0;
        selections = (i32)0;
        }
    void textDidChange(UXTextView* tv)
        {
        changes = changes + (i32)1;
        }
    void selectionDidChange(UXTextView* tv)
        {
        selections = selections + (i32)1;
        }
    }

void main(void)
    {
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;

    // ---- the model, before there is a native view ----
    UXTextView* tv = new UXTextView();
    Watcher* w = new Watcher();
    tv.delegate = w;
    tv.setText(String.withCString((u8*)"hello world"));
    ck(!tv.isNative(), "model: no native view yet");
    tv.setSelectedRange(Range.make((i32)0, (i32)5));
    tv.toggleBold();
    ck(boldAt(tv, (i32)0) && boldAt(tv, (i32)4) && !boldAt(tv, (i32)5), "model: bold over the selection only");
    tv.toggleBold();
    ck(!boldAt(tv, (i32)0), "model: toggling an all-bold selection turns it off");
    tv.undo();
    ck(boldAt(tv, (i32)0), "model: undo brings the bold back");
    tv.redo();
    ck(!boldAt(tv, (i32)0), "model: redo takes it away again");
    tv.setSelectedRange(Range.make((i32)11, (i32)0));
    tv.insertText(String.withCString((u8*)"!"));
    ck(textIs(tv, (u8*)"hello world!"), "model: typing at the caret");
    eqi(tv.selectedRange().loc, (i32)12, "model: the caret moves past what was typed");
    ck(w.changes >= (i32)4, "model: the delegate hears each change");

    // ---- the native view ----
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Text", UXGeom.make((i16)60, (i16)60, (i16)400, (i16)300), content);
    app.addWindow(win);
    content.addSubview(tv, UXGeom.make((i16)10, (i16)10, (i16)380, (i16)280));
    win.tree.finalise();
    win.displayAll();
    ck(tv.isNative(), "native: the backend made a GtkTextView");
    eqi((i32)tv.kind(), (i32)UXKindTextView, "native: the node is a text view");
    tv.nativeDidChange(); // read the content back from the GtkTextView
    ck(textIs(tv, (u8*)"hello world!"), "native: it shows the model's text");

    tv.setSelectedRange(Range.make((i32)6, (i32)5));
    Range* sel = tv.selectedRange();
    eqi(sel.loc, (i32)6, "native: the selection is set");
    eqi(sel.len, (i32)5, "native: ...over five bytes");
    tv.toggleBold();
    ck(boldAt(tv, (i32)6) && boldAt(tv, (i32)10) && !boldAt(tv, (i32)5) && !boldAt(tv, (i32)11),
       "native: bold reads back from the GtkTextView over the selection only");
    tv.toggleItalic();
    tv.toggleUnderline();
    UXTextStyle* st = UXTextStyle.at(tv.attributedText(), (i32)8);
    ck(st.bold && st.italic && st.underline, "native: bold, italic and underline together");
    tv.undo();
    st = UXTextStyle.at(tv.attributedText(), (i32)8);
    ck(st.bold && st.italic && !st.underline, "native: undo takes off the last (underline)");
    tv.redo();
    st = UXTextStyle.at(tv.attributedText(), (i32)8);
    ck(st.underline, "native: redo puts it back");

    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    tv.setAlignment((i32)UX_ALIGN_CENTER);
    eqi(UXTextStyle.at(tv.attributedText(), (i32)3).alignment, (i32)UX_ALIGN_CENTER,
        "native: alignment covers the paragraph the caret is in");

    // An emoji is four UTF-8 bytes (one character on the native side).
    tv.setSelectedRange(Range.make((i32)12, (i32)0));
    tv.insertText(String.withCString((u8*)" \U0001F44B"));
    eqi(tv.length(), (i32)17, "native: an emoji counts four bytes");
    eqi(tv.selectedRange().loc, (i32)17, "native: the caret is after the emoji, in bytes");
    tv.setSelectedRange(Range.make((i32)13, (i32)4));
    tv.toggleBold();
    ck(boldAt(tv, (i32)13), "native: an emoji can be styled");

    i32 before = w.changes;
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)"Oh, ");
    ck(w.changes > before, "native: the user's typing reaches the delegate");
    String* all = tv.text();
    ck(streq(all.cString(), (u8*)"Oh, hello world! \U0001F44B"), "native: ...and the model");
    ck(boldAt(tv, (i32)10), "native: styles survive typing before them");
    tv.undo();
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "native: undo takes the typing back out");

    // The editing keys reach the view's own handler.  (Not cut, copy and paste: they would replace
    // what is on the clipboard of whoever runs this.)  Typing "Ah " is three inserts and one step.
    eqi(ux_gtk_test_textview_key(win.handle, (i32)tv.index, (i32)97, (i32)0), (i32)1, "keys: Control-A is taken");
    eqi(tv.selectedRange().len, tv.length(), "keys: ...and selects everything");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)"A");
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)"h");
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)" ");
    ux_gtk_test_textview_key(win.handle, (i32)tv.index, (i32)122, (i32)0);
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "keys: Control-Z undoes the typing, as one step");
    ux_gtk_test_textview_key(win.handle, (i32)tv.index, (i32)122, (i32)1);
    ck(textIs(tv, (u8*)"Ah hello world! \U0001F44B"), "keys: Shift-Control-Z redoes it");

    // GTK gives typed text no tags: the shim gives it the style before it, or the one chosen at an
    // empty selection.  "world" is bold (bytes 9..14 of "Ah hello world! ..."), so an "s" after it is.
    tv.setSelectedRange(Range.make((i32)14, (i32)0));
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)"s");
    ck(textIs(tv, (u8*)"Ah hello worlds! \U0001F44B") && boldAt(tv, (i32)14), "typing: takes the style before it");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    tv.toggleUnderline();
    ux_gtk_test_textview_type(win.handle, (i32)tv.index, (u8*)"U");
    ck(UXTextStyle.at(tv.attributedText(), (i32)0).underline && !UXTextStyle.at(tv.attributedText(), (i32)1).underline,
       "typing: an empty selection's style applies to what is typed next");

    // The look: text with no colour or size of its own takes the view's ink and default size, and
    // reads back as having none; a colour of its own stays.
    tv.setBackgroundColor((i32)0x202428);
    tv.setInk((i32)0xE8E8E8);
    tv.setCaretColor((i32)0xFFCC00);
    tv.setSelectionColor((i32)0x3A5A8A);
    tv.setDefaultFontSize((i32)18);
    AttributedString* lk = AttributedString.withString(String.withCString((u8*)"ink red"));
    UXTextStyle.setColor(lk, (i32)0xC03020, (i32)4, (i32)3);
    tv.setAttributedText(lk);
    tv.nativeDidChange();
    UXTextStyle* s0 = UXTextStyle.at(tv.attributedText(), (i32)0);
    UXTextStyle* s5 = UXTextStyle.at(tv.attributedText(), (i32)5);
    ck(s0.color == (i32)-1 && s0.size == (i16)0, "look: text in the ink and default size reads back as plain");
    eqi(s5.color, (i32)0xC03020, "look: a colour of its own stays");
    tv.setMonospace(true);
    tv.nativeDidChange();
    ck(!UXTextStyle.at(tv.attributedText(), (i32)0).monospace, "look: a monospace default is not read back as a style");
    tv.setMonospace(false);
    tv.setInk((i32)-1);
    tv.setBackgroundColor((i32)-1);
    tv.setDefaultFontSize((i32)0);

    // Content set by the app replaces everything and is not an undo step.
    AttributedString* as = AttributedString.withString(String.withCString((u8*)"plain bold"));
    UXTextStyle.setBold(as, true, (i32)6, (i32)4);
    tv.setAttributedText(as);
    ck(textIs(tv, (u8*)"plain bold") && boldAt(tv, (i32)6) && !boldAt(tv, (i32)0),
       "native: setAttributedText round-trips its runs");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTextView on GTK\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
