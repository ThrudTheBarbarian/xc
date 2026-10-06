// test_appkit_title.xc — a control's title changed after it is on screen reaches the native
// control: a button's, a check box's and a label's, through setTitle and setText.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern i32 ux_ak_test_control_text(i32 handle, i32 node, u8* buf, i32 n);

i32 gFails = 0;
void ck(bool ok, u8* what, u8* got)
    {
    Stdio.printf("  %s %s (%s)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, got);
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

void main(void)
    {
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Titles", UXGeom.make((i16)0, (i16)0, (i16)300, (i16)160), content);
    UXButton* b = new UXButton();
    b.setTitle((u8*)"Button");
    content.addSubview(b, UXGeom.make((i16)10, (i16)10, (i16)100, (i16)24));
    UXCheckbox* c = new UXCheckbox();
    c.setTitle((u8*)"Checkbox");
    content.addSubview(c, UXGeom.make((i16)10, (i16)50, (i16)140, (i16)20));
    UXLabel* l = new UXLabel();
    l.setText((u8*)"Label");
    content.addSubview(l, UXGeom.make((i16)10, (i16)90, (i16)140, (i16)20));
    win.tree.finalise();
    win.displayAll();

    u8 buf[64];
    ux_ak_test_control_text(win.handle, (i32)b.index, &buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Button"), "a button shows its first title", &buf[(i32)0]);
    b.setTitle((u8*)"Stop");
    c.setTitle((u8*)"Shuffle");
    l.setTitle((u8*)"Now playing");
    win.displayAll();
    ux_ak_test_control_text(win.handle, (i32)b.index, &buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Stop"), "and a title set after it is made", &buf[(i32)0]);
    ux_ak_test_control_text(win.handle, (i32)c.index, &buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Shuffle"), "so does a check box", &buf[(i32)0]);
    ux_ak_test_control_text(win.handle, (i32)l.index, &buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Now playing"), "and a label, through setTitle as through setText", &buf[(i32)0]);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: titles changed after realize reach the native controls\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
