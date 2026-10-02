// test_mac_icon.xc — the application icon on AppKit (the Dock tile), read back from NSApp (icon_body.xc).
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXImage.xc"
#import "UXString.xc"

extern i32 ux_ak_app_icon_pixel(i32 x, i32 y, i32* w, i32* h);
i32 iconPixel(i32 x, i32 y) { return ux_ak_app_icon_pixel(x, y, (i32*)0, (i32*)0); }
i32 iconW() { i32 w = (i32)0; i32 h = (i32)0; ux_ak_app_icon_pixel((i32)0, (i32)0, &w, &h); return w; }
i32 iconH() { i32 w = (i32)0; i32 h = (i32)0; ux_ak_app_icon_pixel((i32)0, (i32)0, &w, &h); return h; }
#define ICON_BACKEND "AppKit"
#import "icon_body.xc"

void main(void)
    {
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    i32 rc = iconBody(app);
    }
