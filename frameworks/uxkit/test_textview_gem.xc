// test_textview_gem.xc — UXTextView on GEM, which has no editor of its own: the view draws its text
// and edits it.  A click gives it the keyboard, and keys go through the window as a real keypress
// does (GEM's (scan code << 8) | ASCII); styles, Return, the arrows, Backspace, undo, and drawing the
// result with GEM's text calls.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXTextView.xc"
#import "UXBoot.xc"

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    Stdio.printf("  %s %s\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what);
    if (!ok)
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

class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTextView* tv;

    void key(u16 k, u16 mods)
        {
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventKeyDown;
        e.key = k;
        e.modifiers = mods;
        win.dispatchKey(e);
        }
    void typeIn(u8* s)
        {
        for (i32 i = (i32)0; s[i] != (u8)0; i = i + (i32)1)
            {
            self.key((u16)s[i], (u16)0);
            }
        }
    bool textIs(u8* want)
        {
        String* t = tv.text();
        return streq(t.cString(), want);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("text", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);
        tv = new UXTextView();
        content.addSubview(tv, UXGeom.make((i16)8, (i16)8, (i16)240, (i16)100));
        win.tree.finalise();
        win.displayAll();
        ck((i32)tv.kind() == (i32)UXKindView, "GEM has no editor: the view is drawn");

        UXRect f = tv.absoluteFrame();
        UXEvent* click = new UXEvent();
        click.kind = (u8)UXEventMouseDown;
        click.x = (i16)(f.x + (i16)10);
        click.y = (i16)(f.y + (i16)10);
        win.dispatchMouse(click);
        ck(win.firstResponder == (UXResponder*)tv, "a click gives it the keyboard");

        self.typeIn((u8*)"Dear sir");
        self.key((u16)$1C0D, (u16)0); // Return
        self.typeIn((u8*)"Yes");
        ck(self.textIs((u8*)"Dear sir\nYes"), "typing and Return, through the window");
        self.key((u16)$4B00, (u16)0);                  // Left
        self.key((u16)$4B34, (u16)UX_MOD_SHIFT);       // Shift-Left
        self.key((u16)$4B34, (u16)UX_MOD_SHIFT);
        Range* sel = tv.selectedRange();
        ck(sel.loc == (i32)9 && sel.len == (i32)2, "the arrows move and Shift selects");
        tv.toggleBold();
        ck(UXTextStyle.at(tv.attributedText(), (i32)9).bold, "a style on the selection");
        self.key((u16)$0E08, (u16)0); // Backspace
        ck(self.textIs((u8*)"Dear sir\ns"), "Backspace removes the selection");
        self.key((u16)$2C1A, (u16)UX_MOD_CTRL); // Control-Z
        ck(self.textIs((u8*)"Dear sir\nYes"), "Control-Z undoes it");
        tv.setSelectedRange(Range.make((i32)0, (i32)4));
        tv.setAlignment((i32)UX_ALIGN_CENTER);
        tv.setColor((i32)$C03020);
        win.displayAll(); // the styled text, the selection and the caret, drawn by GEM
        ck(true, "drawn with GEM's text calls");

        Stdio.printf(gFails == (i32)0 ? "PASS: UXTextView on GEM, drawn and edited by the toolkit\n"
                                      : "FAIL: %d check(s)\n", gFails);
        a.stop();
        return (i32)0;
        }
    }

void main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
