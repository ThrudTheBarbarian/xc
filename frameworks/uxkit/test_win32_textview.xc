// test_win32_textview.xc — UXTextView on Win32: a native RichEdit, content in and out as attributed
// runs, the selection, bold/italic/underline and alignment on the selection, typing in the style
// before it, emoji, and undo and redo (the view's own: the RichEdit's is off).  Typing is WM_CHAR sent
// to the RichEdit, as a key press makes it; the undo keys are the path the message loop takes for them.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTextView.xc"
#import "UXGeometry.xc"

// the RichEdit's typing: each character as the WM_CHAR a key press makes (ASCII here)
void w32Type(i32 handle, i32 node, u8* text)
    {
    W32TextView* r = W32TextView.at(handle, node);
    for (i32 i = (i32)0; r != (W32TextView*)0 && text[i] != (u8)0; i = i + (i32)1)
        {
        SendMessageA(r.hwnd, (u32)$0102, (pointer)(u32)text[i], (pointer)0); // WM_CHAR
        }
    }
// Control-Z (redo: with Shift), as the message loop hands it on; and Control-A as the RichEdit does it
i32 w32Key(i32 handle, i32 node, i32 key, i32 shift)
    {
    W32TextView* r = W32TextView.at(handle, node);
    if (r == (W32TextView*)0)
        {
        return (i32)0;
        }
    if (key == (i32)122)
        {
        r.undoKey(shift != (i32)0);
        return (i32)1;
        }
    if (key == (i32)97)
        {
        r.userMoved = true;
        r.select((i32)0, (i32)-1);
        return (i32)1;
        }
    return (i32)0;
    }

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
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
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
    ck(tv.isNative(), "native: the backend made a RichEdit");
    eqi((i32)tv.kind(), (i32)UXKindTextView, "native: the node is a text view");
    tv.nativeDidChange(); // read the content back from the RichEdit
    ck(textIs(tv, (u8*)"hello world!"), "native: it shows the model's text");

    tv.setSelectedRange(Range.make((i32)6, (i32)5));
    Range* sel = tv.selectedRange();
    eqi(sel.loc, (i32)6, "native: the selection is set");
    eqi(sel.len, (i32)5, "native: ...over five bytes");
    tv.toggleBold();
    ck(boldAt(tv, (i32)6) && boldAt(tv, (i32)10) && !boldAt(tv, (i32)5) && !boldAt(tv, (i32)11),
       "native: bold reads back from the RichEdit over the selection only");
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

    // An emoji is four UTF-8 bytes (two UTF-16 units on the native side).
    tv.setSelectedRange(Range.make((i32)12, (i32)0));
    tv.insertText(String.withCString((u8*)" \U0001F44B"));
    eqi(tv.length(), (i32)17, "native: an emoji counts four bytes");
    eqi(tv.selectedRange().loc, (i32)17, "native: the caret is after the emoji, in bytes");
    tv.setSelectedRange(Range.make((i32)13, (i32)4));
    tv.toggleBold();
    ck(boldAt(tv, (i32)13), "native: an emoji can be styled");

    i32 before = w.changes;
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    w32Type(win.handle, (i32)tv.index, (u8*)"Oh, ");
    ck(w.changes > before, "native: the user's typing reaches the delegate");
    String* all = tv.text();
    ck(streq(all.cString(), (u8*)"Oh, hello world! \U0001F44B"), "native: ...and the model");
    ck(boldAt(tv, (i32)10), "native: styles survive typing before them");
    tv.undo();
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "native: undo takes the typing back out");

    // The editing keys reach the view's own handler.  (Not cut, copy and paste: they would replace
    // what is on the clipboard of whoever runs this.)  Typing "Ah " is three inserts and one step.
    eqi(w32Key(win.handle, (i32)tv.index, (i32)97, (i32)0), (i32)1, "keys: select all is taken");
    eqi(tv.selectedRange().len, tv.length(), "keys: ...and selects everything");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    w32Type(win.handle, (i32)tv.index, (u8*)"A");
    w32Type(win.handle, (i32)tv.index, (u8*)"h");
    w32Type(win.handle, (i32)tv.index, (u8*)" ");
    w32Key(win.handle, (i32)tv.index, (i32)122, (i32)0);
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "keys: Control-Z undoes the typing, as one step");
    w32Key(win.handle, (i32)tv.index, (i32)122, (i32)1);
    ck(textIs(tv, (u8*)"Ah hello world! \U0001F44B"), "keys: Shift-Control-Z redoes it");

    // Typed text takes the style before it, or the one chosen at an empty selection.  "world" is bold (bytes 9..14 of "Ah hello world! ..."), so an "s" after it is.
    tv.setSelectedRange(Range.make((i32)14, (i32)0));
    w32Type(win.handle, (i32)tv.index, (u8*)"s");
    ck(textIs(tv, (u8*)"Ah hello worlds! \U0001F44B") && boldAt(tv, (i32)14), "typing: takes the style before it");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    tv.toggleUnderline();
    w32Type(win.handle, (i32)tv.index, (u8*)"U");
    ck(UXTextStyle.at(tv.attributedText(), (i32)0).underline && !UXTextStyle.at(tv.attributedText(), (i32)1).underline,
       "typing: an empty selection's style applies to what is typed next");

    // Content set by the app replaces everything and is not an undo step.
    AttributedString* as = AttributedString.withString(String.withCString((u8*)"plain bold"));
    UXTextStyle.setBold(as, true, (i32)6, (i32)4);
    tv.setAttributedText(as);
    ck(textIs(tv, (u8*)"plain bold") && boldAt(tv, (i32)6) && !boldAt(tv, (i32)0),
       "native: setAttributedText round-trips its runs");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTextView on Win32\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
