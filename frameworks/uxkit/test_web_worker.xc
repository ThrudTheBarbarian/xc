// test_web_worker.xc — UXKit in a REAL browser's worker run loop (the web-worker gate).
//
// The interactive run loop: the app runs in a worker, drawing into an OffscreenCanvas, blocked on
// the loader's ring; the DOM is on the page.  What the worker hands the page goes through the
// loader's xccPost (compiler 587).  Here: a menu bar (the page builds a DOM bar), then a modal
// alert (the page shows a DOM dialog and the worker blocks until a button is clicked), then
// UXApplication.run() until a pick in that menu bar fires an item and stops it.
// tools/web_worker.html plays the user: it checks the dialog, clicks "Discard", then picks
// File > New.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXGeometry.xc"
#import "UXControl.xc"

i32 gNew;
i32 gChanges;
i32 gSubmits;
u8* gSubmitted;
bool sameBytes(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void onFieldChange(UXTextField* f)
    {
    gChanges = gChanges + (i32)1;
    }
void onFieldSubmit(UXTextField* f)
    {
    gSubmits = gSubmits + (i32)1;
    gSubmitted = UXStr.dup(f.text());
    Stdio.printf("field: submitted \"%s\"\n", f.text());
    }
UXApplication* gTheApp;
class Ctl : Object
    {
    void onNew(UXMenuItem* s)
        {
        gNew = gNew + (i32)1;
        Stdio.printf("menu: File > New fired\n");
        gTheApp.stop();
        }
    void onQuit(UXMenuItem* s)
        {
        }
    }

// run() needs a delegate; this one has nothing to start
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
    win.open((u8*)"Worker", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)140), new UXView());
    app.addWindow(win);
    Ctl* c = new Ctl();
    UXMenuBar* bar = new UXMenuBar();
    UXMenu* file = bar.addMenu((u8*)"File");
    file.addItem((u8*)"New", &c.onNew);
    file.addItem((u8*)"Quit", &c.onQuit);
    app.setMenuBar(bar);

    UXAlert* a = new UXAlert();
    a.icon = (i32)3;
    a.addLine((u8*)"Discard changes?");
    a.addLine((u8*)"The draft has not been saved.");
    a.addButton((u8*)"Keep");
    a.addButton((u8*)"Discard");
    a.defaultButton = (i32)1;
    i32 answer = a.runModal();
    Stdio.printf("alert answered %d\n", answer);

    // a text field with the keyboard: the page puts a real <input> over it
    UXTextField* field = new UXTextField();
    win.contentView.addSubview(field, UXGeom.make((i16)10, (i16)40, (i16)200, (i16)24));
    field.setOnChange(&onFieldChange);
    field.setOnSubmit(&onFieldSubmit);
    win.tree.finalise();
    win.displayAll();
    win.makeFirstResponder(field);

    gNew = (i32)0;
    app.setDelegate(new Starter());
    app.run(); // until the page's pick fires File > New
    bool typed = gSubmits == (i32)1 && gChanges >= (i32)1 && gSubmitted != (u8*)0 && sameBytes(gSubmitted, (u8*)"héllo 日本");
    bool pass = answer == (i32)2 && gNew == (i32)1 && typed;
    Stdio.printf(pass ? "PASS: worker run loop -- a DOM alert answered, text typed in a real <input>, a DOM menu pick fired\n"
                      : "FAIL: alert %d, new %d, changes %d, submits %d\n", answer, gNew, gChanges, gSubmits);
    }
