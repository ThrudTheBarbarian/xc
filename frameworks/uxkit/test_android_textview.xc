// test_android_textview.xc — UXTextView on Android, in the emulator: a native EditText of spans,
// content in and out as attributed runs, the selection, bold/italic/underline and alignment on the
// selection, typing in the style before it, emoji, and undo and redo (the view's own; Control-Z and
// Control-Y in the EditText go to it through the driver's undo hook, which this calls).
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTextView.xc"
#import "UXGeometry.xc"

extern void ux_and_test_textview_type(i32 handle, i32 node, u8* text);
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);

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

UXWindow* gWin;
UXTextView* gTv;
Watcher* gW;

void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void nativeChecks(void)
    {
    UXWindow* win = gWin;
    UXTextView* tv = gTv;
    Watcher* w = gW;
    ck(tv.isNative(), "native: the backend made an EditText");
    eqi((i32)tv.kind(), (i32)UXKindTextView, "native: the node is a text view");
    tv.nativeDidChange(); // read the content back from the EditText
    ck(textIs(tv, (u8*)"hello world!"), "native: it shows the model's text");

    tv.setSelectedRange(Range.make((i32)6, (i32)5));
    Range* sel = tv.selectedRange();
    eqi(sel.loc, (i32)6, "native: the selection is set");
    eqi(sel.len, (i32)5, "native: ...over five bytes");
    tv.toggleBold();
    ck(boldAt(tv, (i32)6) && boldAt(tv, (i32)10) && !boldAt(tv, (i32)5) && !boldAt(tv, (i32)11),
       "native: bold reads back from the EditText over the selection only");
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
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)"Oh, ");
    ck(w.changes > before, "native: the user's typing reaches the delegate");
    String* all = tv.text();
    ck(streq(all.cString(), (u8*)"Oh, hello world! \U0001F44B"), "native: ...and the model");
    ck(boldAt(tv, (i32)10), "native: styles survive typing before them");
    tv.undo();
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "native: undo takes the typing back out");

    // Control-Z and Control-Y reach the view's undo.  Typing "Ah " is three inserts and one step.
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)"A");
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)"h");
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)" ");
    uxAndTextViewUndo(win.handle, (i32)tv.index, (i32)0);
    ck(textIs(tv, (u8*)"hello world! \U0001F44B"), "undo key: undoes the typing, as one step");
    uxAndTextViewUndo(win.handle, (i32)tv.index, (i32)1);
    ck(textIs(tv, (u8*)"Ah hello world! \U0001F44B"), "redo key: redoes it");

    // Typed text takes the style before it, or the one chosen at an empty selection.  "world" is bold (bytes 9..14 of "Ah hello world! ..."), so an "s" after it is.
    tv.setSelectedRange(Range.make((i32)14, (i32)0));
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)"s");
    ck(textIs(tv, (u8*)"Ah hello worlds! \U0001F44B") && boldAt(tv, (i32)14), "typing: takes the style before it");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    tv.toggleUnderline();
    ux_and_test_textview_type(win.handle, (i32)tv.index, (u8*)"U");
    ck(UXTextStyle.at(tv.attributedText(), (i32)0).underline && !UXTextStyle.at(tv.attributedText(), (i32)1).underline,
       "typing: an empty selection's style applies to what is typed next");

    // Content set by the app replaces everything and is not an undo step.
    AttributedString* as = AttributedString.withString(String.withCString((u8*)"plain bold"));
    UXTextStyle.setBold(as, true, (i32)6, (i32)4);
    tv.setAttributedText(as);
    ck(textIs(tv, (u8*)"plain bold") && boldAt(tv, (i32)6) && !boldAt(tv, (i32)0),
       "native: setAttributedText round-trips its runs");

    Stdio.printf(gFails == (i32)0 ? "PASS: UXTextView on Android\n" : "FAIL: %d check(s)\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)300);
    }

void testBody(void)
    {
    ux_and_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;

    // ---- the model, before there is a native view ----
    gTv = new UXTextView();
    UXTextView* tv = gTv;
    gW = new Watcher();
    Watcher* w = gW;
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

    UXView* content = new UXView();
    gWin = new UXWindow();
    UXWindow* win = gWin;
    win.open((u8*)"Text", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    app.addWindow(win);
    content.addSubview(tv, UXGeom.make((i16)10, (i16)10, (i16)380, (i16)280));
    win.tree.finalise();
    win.displayAll();
    ux_and_test_call_later((pointer)&nativeChecks, (i32)1500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
