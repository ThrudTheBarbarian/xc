#import "Stdio.xc"
#import <xgspike_lib>

class MyView : LibView
    {
    // override the library calls
    u16 drawRect(void)
        {
        return self.tag + (u16)100;
        }
    }

    class Ctl
    {
    u16 v;
    u16 check(void)
        {
        return self.v;
        }
    } Ctl* gCtl;

void main(void)
    {
    MyView* mv = new MyView();
    mv.tag = (u16)5;
    Stdio.printf("override=%d\n", mv.render()); // lib->override = 105

    LibControl* lc = new LibControl();
    Stdio.printf("no-hook=%d\n", lc.validate()); // 999 (unset optional)
    gCtl = new Ctl();
    gCtl.v = (u16)42;
    lc.setValidate(&gCtl.check);
    Stdio.printf("hook=%d\n", lc.validate()); // 42 (bound method across .so)

    gCtl = (Ctl*)0;
    Stdio.printf("after-death=%d\n", lc.validate()); // 999 (weak-zeroed, not dangle)

    LibGeom* g = new LibGeom();
    XGRect r;
    r.x = (u16)1;
    r.y = (u16)2;
    r.w = (u16)6;
    r.h = (u16)7;
    Stdio.printf("area=%d\n", g.area(r)); // 42 (struct by value in)
    XGRect u = g.unit();
    Stdio.printf("unit=%d,%d,%d,%d\n", u.x, u.y, u.w, u.h); // 1,2,3,4 (struct by value out)
    }
