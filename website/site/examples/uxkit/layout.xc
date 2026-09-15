// layout.xc — the view tree and springs-and-struts resizing.
//
// A header pinned across the top, a footer across the bottom, and a body that
// takes whatever is left. Resize the window and watch each one follow its rule.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

#define W 320
#define H 200

class Layout : Object <UXApplicationDelegate>
{
    void init(void) { }

    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Layout", UXGeom.make(60, 60, W, H), content);

        // Across the top, growing sideways but never taller.
        UXLabel* header = new UXLabel();
        header.setText((u8*)"header — pinned top, flexible width");
        content.addSubview(header, UXGeom.make(8, 8, W - 16, 18));
        header.setAutoresizeMask(UX_ANCHOR_TOP | UX_ANCHOR_LEFT | UX_FLEX_WIDTH);

        // The middle takes all the slack in BOTH directions.
        UXView* body = new UXView();
        content.addSubview(body, UXGeom.make(8, 34, W - 16, H - 74));
        body.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_TOP | UX_FLEX_WIDTH | UX_FLEX_HEIGHT);

        // Glued to the bottom-left: the gap below it stays constant.
        UXButton* ok = new UXButton();
        ok.setTitle((u8*)"OK");
        content.addSubview(ok, UXGeom.make(8, H - 32, 72, 24));
        ok.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_BOTTOM);

        win.tree.finalise();
        win.displayAll();

        // Frames are PARENT-relative; absoluteFrame() is the window-relative one.
        UXRect f = ok.frame();
        UXRect a = ok.absoluteFrame();
        Stdio.printf("ok frame=%d,%d abs=%d,%d\n", f.x, f.y, a.x, a.y);
        return 0;
    }
}

void main(void) {
    gDriver = new UXAppKitDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Layout());
    app.run();
}
