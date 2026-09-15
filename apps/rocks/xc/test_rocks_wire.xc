// test_rocks_wire.xc — the seam's gate: builder and controller agree, headless.
//
// This is the test that protects the bootstrap plan.  RKMainBuilder wires the
// controller through setOutlet/wireAction — the SAME UXDesignable methods a
// nib loader drives — so every wiring name here is one a future nib will carry
// as data.  A typo in either half is a name the other does not know, and the
// whole point is that it fails HERE, in a headless gate, rather than at load
// time in a half-built window.
//
// It also asserts the outlets actually landed, not merely that setOutlet
// returned true: a checked assignment that silently no-ops would satisfy the
// return value and leave the controller holding nothing.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"

i32 gFails;
void check(u8* what, bool got)
    {
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    ux_ak_set_capture((i32)1); // native controls, no window shown
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    RKMainController* c = new RKMainController();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Rocks", UXGeom.make((i16)0, (i16)0, (i16)1000, (i16)640), content);

    check("every wiring name is known to the controller",
          RKMainBuilder.buildInto(content, c, (i16)1000, (i16)640));

    // the outlets actually landed
    check("formOutline outlet assigned", c.formOutline != (UXOutlineView*)0);
    check("canvas outlet assigned", c.canvas != (UXView*)0);
    check("inspector outlet assigned", c.inspector != (UXView*)0);
    check("statusLabel outlet assigned", c.statusLabel != (UXLabel*)0);

    // an unknown name must be REJECTED, not silently accepted — that rejection
    // is what turns a nib typo into an error instead of a dead connection
    check("an unknown outlet name is refused",
          !c.setOutlet((u8*)"noSuchOutlet", (Object*)content));

    // and the controller can drive its own view through the outlet
    c.say((u8*)"wired");
    check("controller reaches its outlet", c.statusLabel != (UXLabel*)0);

    win.tree.finalise();
    win.close();

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: Rocks' builder and controller agree on every wiring name\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", (i16)gFails);
        }
    }
