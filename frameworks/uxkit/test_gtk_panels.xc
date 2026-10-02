// test_gtk_panels.xc — GTK's own dialogs behind UXKit's panels (run_gtk_linux.sh test_gtk_panels):
// UXOpenPanel and UXSavePanel are GtkFileDialog, and the colour and font pickers are GtkColorDialog
// and GtkFontDialog.  Each is answered unattended through the REAL dialog: a test hook finds it
// among the toplevels (in-process: GDK_DEBUG=no-portals), sets a file, colour or font on it and presses
// OK -- or Cancel, which must answer nothing.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXOpenPanel.xc"
#import "UXSavePanel.xc"
#import "UXFileIO.xc"

i32 setenv(u8* name, u8* value, i32 overwrite);
u32 alarm(u32 seconds);
void ux_gtk_dialog_auto(i32 ms, u8* path, i32 r, i32 g, i32 b, u8* font, i32 cancel);
i32 ux_gtk_dialog_auto_seen(void);

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
bool sameText(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return false;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

void main(void)
    {
    gFails = (i32)0;
    // the file dialog in-process (no desktop portal), where a test can reach it -- GTK 4's switch
    setenv((u8*)"GDK_DEBUG", (u8*)"no-portals", (i32)1);
    alarm((u32)60); // a dialog nobody answers must fail the gate, not hang it
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no GTK display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXWindow* win = new UXWindow();
    win.open((u8*)"panels", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), new UXView());
    app.addWindow(win);
    ck((u8*)"GTK has all four native panels", d.hasNativeFileOpen() && d.hasNativeFileSave() && d.hasNativeColorPicker() && d.hasNativeFontPicker());

    UXFileIO.write((u8*)"/tmp/uxpanels_open.txt", UXData.fromString((u8*)"x"));
    ux_gtk_dialog_auto((i32)300, (u8*)"/tmp/uxpanels_open.txt", (i32)0, (i32)0, (i32)0, (u8*)"", (i32)0);
    u8* opened = UXOpenPanel.run((u8*)"Open a file", (u8*)"/tmp");
    ck((u8*)"the open dialog came up", ux_gtk_dialog_auto_seen() != (i32)0);
    ck((u8*)"...and answers the file chosen in it", sameText(opened, (u8*)"/tmp/uxpanels_open.txt"));

    ux_gtk_dialog_auto((i32)300, (u8*)"/tmp/uxpanels_saved.rsc", (i32)0, (i32)0, (i32)0, (u8*)"", (i32)0);
    u8* saved = UXSavePanel.run((u8*)"Save", (u8*)"/tmp", (u8*)"untitled.rsc");
    ck((u8*)"the save dialog answers folder + name", sameText(saved, (u8*)"/tmp/uxpanels_saved.rsc"));

    ux_gtk_dialog_auto((i32)300, (u8*)"", (i32)0, (i32)0, (i32)0, (u8*)"", (i32)1);
    u8* none = UXOpenPanel.run((u8*)"Open", (u8*)"/tmp");
    ck((u8*)"Cancel answers nothing", none == (u8*)0 && ux_gtk_dialog_auto_seen() != (i32)0);

    i32 r = (i32)0;
    i32 g = (i32)0;
    i32 b = (i32)0;
    ux_gtk_dialog_auto((i32)300, (u8*)"", (i32)10, (i32)200, (i32)30, (u8*)"", (i32)0);
    i32 okc = d.pickColor((i32)255, (i32)255, (i32)255, &r, &g, &b);
    Stdio.printf("  (colour %d,%d,%d)\n", r, g, b);
    ck((u8*)"the colour dialog answers the colour chosen", okc == (i32)1 && r == (i32)10 && g == (i32)200 && b == (i32)30);

    u8 fam[64];
    i32 size = (i32)0;
    i32 bold = (i32)0;
    i32 italic = (i32)0;
    ux_gtk_dialog_auto((i32)1500, (u8*)"", (i32)0, (i32)0, (i32)0, (u8*)"DejaVu Serif Bold 18", (i32)0);
    i32 okf = d.pickFont((u8*)"Sans", (i32)13, (i32)0, (i32)0, &fam[(i32)0], (i32)64, &size, &bold, &italic);
    Stdio.printf("  (font %s %d bold=%d italic=%d; dialog seen=%d)\n", &fam[(i32)0], size, bold, italic, ux_gtk_dialog_auto_seen());
    ck((u8*)"the font dialog answers the font chosen", okf == (i32)1 && sameText(&fam[(i32)0], (u8*)"DejaVu Serif") && size == (i32)18 && bold == (i32)1 && italic == (i32)0);

    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: GTK's own file, colour and font dialogs answer through UXKit's panels\n" : "FAIL: %d\n", gFails);
    }
