// showcase_gtk2.xc — SHEET 2 (containers + navigation) of the GTK contact sheet: one window, every widget (real
// native overlays where they exist), ONE scene render and dump; capture.sh
// crops.  The desktop model: main() owns the thread, no shell inversion —
// present the window, pump the loop dry, snapshot the real widget scene.
// GTK draws its own widgets, so a GdkMacosDisplay capture IS the Linux look.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

extern void ux_gtk_render_scene(i32 handle);
extern i32 ux_gtk_dump_ppm(u8* path);

void main(void)
    {
    gDriver = new UXGtkDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 60, 440, 630), content);
    buildSheet2(content);
    win.tree.finalise();
    win.displayAll();
    ux_gtk_render_scene((i32)1);
    if (ux_gtk_dump_ppm((u8*)"/tmp/ux-sheet2-gtk.ppm") != (i32)0)
        {
        Stdio.printf("PASS: sheet shot\n");
        }
    else
        {
        Stdio.printf("FAIL: no dump\n");
        }
    }
