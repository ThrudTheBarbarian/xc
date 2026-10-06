// test_textview_drawn.xc — UXTextView where the backend has no editor of its own (GEM's case), so the
// view draws its text and does the editing itself.  Run on the web driver under Node with no page,
// which is such a backend.  The keys are GEM's: (scan code << 8) | ASCII, with Shift and Control in
// the modifiers.  Checks typing, Return, the arrows and Home/End with and without Shift, Backspace and
// Delete, a click and a drag, select all, copy and paste, undo and redo (a run of typing one step),
// and the drawing of the selection and the caret.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTextView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

extern i32 ux_test_pixel(i32 h, i32 x, i32 y);

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

UXEvent* gEv;
UXTextView* gTv;
void key(i32 scan, i32 ascii, u16 mods)
    {
    gEv.init();
    gEv.kind = (u8)UXEventKeyDown;
    gEv.key = (u16)((scan << (i32)8) | ascii);
    gEv.modifiers = mods;
    gTv.keyDown(gEv);
    }
void typeIn(u8* s)
    {
    for (i32 i = (i32)0; s[i] != (u8)0; i = i + (i32)1)
        {
        key((i32)0, (i32)s[i], (u16)0);
        }
    }
// a press or a drag at view point (x, y)
void mouse(u8 kind, i32 x, i32 y)
    {
    UXRect a = gTv.absoluteFrame();
    gEv.init();
    gEv.kind = kind;
    gEv.x = (i16)((i32)a.x + x);
    gEv.y = (i16)((i32)a.y + y);
    if (kind == (u8)UXEventMouseDown)
        {
        gTv.mouseDown(gEv);
        }
    else
        {
        gTv.mouseDragged(gEv);
        }
    }

void main(void)
    {
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }
    gApp = new UXApplication();
    gEv = new UXEvent();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Drawn", UXGeom.make((i16)0, (i16)0, (i16)300, (i16)160), new UXView());
    gApp.addWindow(win);
    gTv = new UXTextView();
    UXTextView* tv = gTv;
    win.contentView.addSubview(tv, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)140));
    win.tree.finalise();
    win.displayAll();
    ck(!tv.isNative(), "no editor on this backend: the view edits");
    ck(tv.acceptsFirstResponder(), "...and takes the keyboard");

    typeIn((u8*)"abc");
    ck(textIs(tv, (u8*)"abc"), "typing");
    eqi(tv.selectedRange().loc, (i32)3, "the caret after it");
    key((i32)$1C, (i32)13, (u16)0);
    typeIn((u8*)"de");
    ck(textIs(tv, (u8*)"abc\nde"), "Return starts a paragraph");
    tv.undo();
    ck(textIs(tv, (u8*)""), "undo takes the run of typing back, as one step");
    tv.redo();
    ck(textIs(tv, (u8*)"abc\nde"), "redo puts it back");
    eqi(tv.selectedRange().loc, (i32)6, "...with the caret at its end");

    key((i32)$4B, (i32)0, (u16)0);
    eqi(tv.selectedRange().loc, (i32)5, "Left moves the caret");
    key((i32)$4B, (i32)$34, (u16)UX_MOD_SHIFT);
    eqi(tv.selectedRange().loc, (i32)4, "Shift-Left extends the selection");
    eqi(tv.selectedRange().len, (i32)1, "...by one");
    key((i32)$0E, (i32)8, (u16)0);
    ck(textIs(tv, (u8*)"abc\ne"), "Backspace removes the selection");
    key((i32)$48, (i32)0, (u16)0);
    eqi(tv.selectedRange().loc, (i32)0, "Up goes to the line above, at the same x");
    key((i32)$4F, (i32)0, (u16)UX_MOD_SHIFT);
    eqi(tv.selectedRange().len, (i32)3, "Shift-End selects to the end of the line");
    key((i32)$53, (i32)127, (u16)0);
    ck(textIs(tv, (u8*)"\ne"), "Delete removes it");
    key((i32)$50, (i32)0, (u16)0);
    key((i32)$4F, (i32)0, (u16)0);
    eqi(tv.selectedRange().loc, (i32)2, "Down and End reach the last line's end");
    key((i32)$47, (i32)0, (u16)0);
    eqi(tv.selectedRange().loc, (i32)1, "Home its start");

    tv.setText(String.withCString((u8*)"hello world"));
    // where a character falls, measured as the view measures it; the inset is 4
    AttributedString* m = tv.attributedText();
    mouse((u8)UXEventMouseDown, (i32)4 + UXTextLayout.spanWidthAttr(m, (i32)0, (i32)6, (i32)13), (i32)8);
    eqi(tv.selectedRange().loc, (i32)6, "a click puts the caret at the character under it");
    mouse((u8)UXEventMouseDragged, (i32)4 + UXTextLayout.spanWidthAttr(m, (i32)0, (i32)11, (i32)13), (i32)8);
    eqi(tv.selectedRange().len, (i32)5, "a drag selects to where it is");
    tv.toggleBold();
    ck(UXTextStyle.at(tv.attributedText(), (i32)8).bold && !UXTextStyle.at(tv.attributedText(), (i32)2).bold,
       "styles act on the selection the mouse made");
    key((i32)$2E, (i32)3, (u16)UX_MOD_CTRL);
    key((i32)$4D, (i32)0, (u16)0);
    key((i32)$2F, (i32)22, (u16)UX_MOD_CTRL);
    ck(textIs(tv, (u8*)"hello worldworld"), "copy and paste");
    key((i32)$2C, (i32)26, (u16)UX_MOD_CTRL);
    ck(textIs(tv, (u8*)"hello world"), "Control-Z undoes the paste");
    key((i32)$1E, (i32)1, (u16)UX_MOD_CTRL);
    eqi(tv.selectedRange().len, (i32)11, "Control-A selects everything");

    // the drawing: the selection behind the text, the caret when there is no selection
    tv.setSelectedRange(Range.make((i32)0, (i32)5));
    win.displayAll();
    wd.webPresentAll();
    UXRect a = tv.absoluteFrame();
    i32 sel = ux_test_pixel(win.handle, (i32)a.x + (i32)4 + (i32)20, (i32)a.y + (i32)6);
    ck(sel != (i32)$FFFFFF && sel != (i32)-1, "the selection is drawn behind the text");
    tv.setSelectedRange(Range.make((i32)0, (i32)0));
    win.displayAll();
    wd.webPresentAll();
    i32 caret = ux_test_pixel(win.handle, (i32)a.x + (i32)4, (i32)a.y + (i32)10);
    eqi(caret, (i32)0, "the caret is drawn at the start");

    // the look: the background and the selection in the view's colours
    tv.setBackgroundColor((i32)0x202428);
    tv.setSelectionColor((i32)0x3A5A8A);
    tv.setSelectedRange(Range.make((i32)0, (i32)5));
    win.displayAll();
    wd.webPresentAll();
    eqi(ux_test_pixel(win.handle, (i32)a.x + (i32)200, (i32)a.y + (i32)100), (i32)0x202428, "look: the background");
    eqi(ux_test_pixel(win.handle, (i32)a.x + (i32)4 + (i32)20, (i32)a.y + (i32)6), (i32)0x3A5A8A, "look: the selection");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTextView drawn and edited by the toolkit\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
