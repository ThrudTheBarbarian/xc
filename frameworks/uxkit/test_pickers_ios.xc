// test_pickers_ios.xc — the iOS colour and font pickers are the system's (the ios-pickers gate):
// UIColorPickerViewController and UIFontPickerViewController, through the driver's pickColor and
// pickFont.  As in ios-picker, the test answers each REAL picker (shown, and checked to be on screen)
// through its own delegate as UIKit does: a colour set in the colour picker and the picker closed; a
// face picked in the font picker, then a cancel.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_color_picker_shown(void);
extern void ux_ios_test_color_picker_answer(i32 r, i32 g, i32 b);
extern i32 ux_ios_test_font_picker_shown(void);
extern void ux_ios_test_font_picker_answer(u8* postscriptName);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool sameBytes(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

i32 gAnswer;
// the "user", while a picker is up: check it is on screen, then answer it
void userAtColor(void)
    {
    ck((u8*)"the system colour picker is on screen", ux_ios_test_color_picker_shown() != (i32)0);
    ux_ios_test_color_picker_answer((i32)200, (i32)100, (i32)50);
    }
void userAtFont(void)
    {
    ck((u8*)"the system font picker is on screen", ux_ios_test_font_picker_shown() != (i32)0);
    ux_ios_test_font_picker_answer(gAnswer == (i32)1 ? (u8*)"Georgia-BoldItalic" : (u8*)0);
    }

void picks(void)
    {
    i32 r = (i32)0;
    i32 g = (i32)0;
    i32 b = (i32)0;
    ux_ios_test_call_later((pointer)&userAtColor, (i32)1200);
    i32 ok = gDriver.pickColor((i32)0, (i32)0, (i32)255, &r, &g, &b);
    Stdio.printf("  (colour: %d %d %d)\n", r, g, b);
    ck((u8*)"the colour chosen in the picker is the one returned", ok == (i32)1 && r == (i32)200 && g == (i32)100 && b == (i32)50);

    u8 fam[64];
    i32 size = (i32)0;
    i32 bold = (i32)0;
    i32 ital = (i32)0;
    gAnswer = (i32)1;
    ux_ios_test_call_later((pointer)&userAtFont, (i32)1200);
    ok = gDriver.pickFont((u8*)"Helvetica", (i32)14, (i32)0, (i32)0, &fam[0], (i32)64, &size, &bold, &ital);
    Stdio.printf("  (font: %s %d bold=%d italic=%d)\n", ok == (i32)1 ? &fam[0] : (u8*)"-", size, bold, ital);
    ck((u8*)"the family picked is the one returned", ok == (i32)1 && sameBytes(&fam[0], (u8*)"Georgia"));
    ck((u8*)"...with the face's weight and slant", bold == (i32)1 && ital == (i32)1);
    ck((u8*)"...and the size passed in (the picker has none)", size == (i32)14);
    gAnswer = (i32)2;
    ux_ios_test_call_later((pointer)&userAtFont, (i32)1200);
    ck((u8*)"cancelling the font picker gives nothing", gDriver.pickFont((u8*)"Helvetica", (i32)14, (i32)0, (i32)0, &fam[0], (i32)64, &size, &bold, &ital) == (i32)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: the iOS colour and font pickers are UIKit's -- what the user picks is what the app gets\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXWindow* win = new UXWindow();
    win.open((u8*)"pickers", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    win.displayAll();
    ck((u8*)"iOS has native colour and font pickers", gDriver.hasNativeColorPicker() && gDriver.hasNativeFontPicker());
    ux_ios_test_call_later((pointer)&picks, (i32)300);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
