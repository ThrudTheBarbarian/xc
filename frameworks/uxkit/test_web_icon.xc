// test_web_icon.xc — the application icon on the web (icon_body.xc): the page's favicon.  Under the
// node rig the recorded icon is read back (ux_test_app_icon); run_web_icon.sh also loads it in real
// headless Chrome, where the page decodes the <link rel="icon"> it now has and checks the quadrants.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXImage.xc"
#import "UXString.xc"

extern i32 ux_test_app_icon(i32 x, i32 y);
extern void ux_test_done(void);
i32 iconPixel(i32 x, i32 y) { return ux_test_app_icon(x, y); }
i32 iconW() { return ux_test_app_icon((i32)-1, (i32)0); }
i32 iconH() { return ux_test_app_icon((i32)0, (i32)-1); }
#define ICON_BACKEND "the web"
#import "icon_body.xc"

void main(void)
    {
    gDriver = new UXWebDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    i32 rc = iconBody(app);
    ux_test_done();
    }
