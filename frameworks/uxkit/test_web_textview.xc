// test_web_textview.xc — UXTextView in a real browser (the web-textview gate): its editor is a
// contenteditable the page puts over the view.  tools/web_textview.html plays the user, and this
// side answers each of its steps:
//   1. the content set here is on the page, "world" bold;
//   2. the user types " 👋" at the end: the view hears it and its text is read back from the page;
//   3. the user selects "hello": the view hears it and makes it italic, which the page shows;
//   4. the user presses the undo key: the italic goes, on the page and in the view;
//   5. the user presses it again: the typing goes too, as one step.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTextView.xc"
#import "UXGeometry.xc"

UXApplication* gTheApp;
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
bool textIs(UXTextView* tv, u8* want)
    {
    String* t = tv.text();
    return streq(t.cString(), want);
    }

class Steps : Object<UXTextViewDelegate>
    {
    i32 step;
    void init(void)
        {
        step = (i32)0;
        }
    void textDidChange(UXTextView* tv)
        {
        String* t = tv.text();
        Stdio.printf("TEXT %d: %s\n", step, t.cString());
        if (step == (i32)0 && textIs(tv, (u8*)"hello world \U0001F44B"))
            {
            ck(UXTextStyle.at(tv.attributedText(), (i32)6).bold, "the bold survives typing after it");
            ck(!UXTextStyle.at(tv.attributedText(), (i32)0).bold, "...and stays where it was");
            step = (i32)1;
            Stdio.printf("STEP typed\n");
            }
        else if (step == (i32)2 && textIs(tv, (u8*)"hello world \U0001F44B") &&
                 !UXTextStyle.at(tv.attributedText(), (i32)0).italic)
            {
            step = (i32)3;
            Stdio.printf("STEP undone-italic\n");
            }
        else if (step == (i32)3 && textIs(tv, (u8*)"hello world"))
            {
            ck(UXTextStyle.at(tv.attributedText(), (i32)6).bold, "undo keeps the bold that was set");
            step = (i32)4;
            Stdio.printf("STEP undone-typing\n");
            Stdio.printf(gFails == (i32)0 ? "PASS: UXTextView in a browser\n" : "FAIL: %d check(s)\n", gFails);
            gTheApp.stop();
            }
        }
    void selectionDidChange(UXTextView* tv)
        {
        Range* r = tv.selectedRange();
        Stdio.printf("SEL %d: %d %d\n", step, r.loc, r.len);
        if (step == (i32)1 && r.loc == (i32)0 && r.len == (i32)5)
            {
            tv.toggleItalic();
            ck(UXTextStyle.at(tv.attributedText(), (i32)2).italic, "italic over the user's selection");
            step = (i32)2;
            Stdio.printf("STEP italic\n");
            }
        }
    }

class Starter : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        return (i32)0;
        }
    }

void main(void)
    {
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    gApp = app;
    gTheApp = app;
    UXWindow* win = new UXWindow();
    win.open((u8*)"Text", UXGeom.make((i16)0, (i16)0, (i16)300, (i16)160), new UXView());
    app.addWindow(win);
    UXTextView* tv = new UXTextView();
    Steps* steps = new Steps();
    tv.delegate = steps;
    win.contentView.addSubview(tv, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)140));
    AttributedString* as = AttributedString.withString(String.withCString((u8*)"hello world"));
    UXTextStyle.setBold(as, true, (i32)6, (i32)5);
    tv.setAttributedText(as);
    win.tree.finalise();
    win.displayAll();
    ck(tv.isNative(), "the page made an editor");
    tv.nativeDidChange(); // read it back from the page
    ck(textIs(tv, (u8*)"hello world") && UXTextStyle.at(tv.attributedText(), (i32)7).bold,
       "the page has the content, with its runs");
    tv.setBackgroundColor((i32)0x202428); // the page checks the editor takes the look
    tv.setInk((i32)0xE8E8E8);
    Stdio.printf("STEP ready\n");
    app.setDelegate(new Starter());
    app.run(); // until the last step stops it
    if (steps.step != (i32)4)
        {
        Stdio.printf("FAIL: stopped at step %d\n", steps.step);
        }
    }
