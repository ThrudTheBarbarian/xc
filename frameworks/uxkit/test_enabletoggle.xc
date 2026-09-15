// test_enabletoggle.xc — enabling a native control is as immediate as
// disabling it.
//
// structSetHidden pushed to the native control; structSetEnabled did not, on
// AppKit alone — the other four drivers already did.  It only set the shadow
// flag and left the real change to the next realizeTree, which setEnabled does
// not trigger.  So disabling appeared to work whenever something else happened
// to rebuild the tree, and re-enabling looked stuck.
//
// Found on a radio button in an editor's inspector: tick Disabled and it greys,
// untick it and nothing happens.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"en", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)140), content);

    // A radio and a button: both native on AppKit, and the radio is the one
    // the bug was reported on.
    UXRadioButton* r = new UXRadioButton();
    r.setTitle((u8*)"Email");
    UXButton* b = new UXButton();
    b.setTitle((u8*)"OK");
    UXCheckbox* cb = new UXCheckbox();
    cb.setTitle((u8*)"Wrap");
    content.addSubview(r, UXGeom.make((i16)10, (i16)10, (i16)100, (i16)20));
    content.addSubview(b, UXGeom.make((i16)10, (i16)40, (i16)60, (i16)20));
    content.addSubview(cb, UXGeom.make((i16)10, (i16)70, (i16)100, (i16)20));
    win.tree.finalise();
    win.displayAll();

    // No realize between the calls — that is the whole point.  A driver that
    // only writes the shadow flag passes the first check and fails the second.
    check("radio starts enabled", win.tree.enabledOf(r.index) ? (i32)1 : (i32)0, (i32)1);
    r.setEnabled(false);
    check("radio disables", win.tree.enabledOf(r.index) ? (i32)1 : (i32)0, (i32)0);
    check("the native control followed", d.controlEnabled(win.tree.structHandle, (i32)r.index), (i32)0);
    r.setEnabled(true);
    check("radio RE-ENABLES", win.tree.enabledOf(r.index) ? (i32)1 : (i32)0, (i32)1);
    check("and the native control followed back",
          d.controlEnabled(win.tree.structHandle, (i32)r.index), (i32)1);

    // The same, for the other native kinds, and repeatedly — a one-shot push
    // would pass a single round trip.
    b.setEnabled(false);
    b.setEnabled(true);
    b.setEnabled(false);
    check("a button survives repeated toggling",
          d.controlEnabled(win.tree.structHandle, (i32)b.index), (i32)0);
    b.setEnabled(true);
    check("and comes back", d.controlEnabled(win.tree.structHandle, (i32)b.index), (i32)1);
    cb.setEnabled(false);
    check("a checkbox disables", d.controlEnabled(win.tree.structHandle, (i32)cb.index), (i32)0);
    cb.setEnabled(true);
    check("and re-enables", d.controlEnabled(win.tree.structHandle, (i32)cb.index), (i32)1);

    // ---- the same rule for FRAME -------------------------------------------
    // setFrame had the identical gap on AppKit and Win32: shadow-only, with
    // the real move deferred to a realizeTree that setFrame does not trigger.
    // gtk, ios and android already pushed.
    i32 fx = (i32)0;
    i32 fy = (i32)0;
    i32 fw = (i32)0;
    i32 fh = (i32)0;
    d.controlFrame(win.tree.structHandle, (i32)b.index, &fx, &fy, &fw, &fh);
    check("the button starts where it was put", fx, (i32)10);
    b.setFrame(UXGeom.make((i16)120, (i16)40, (i16)90, (i16)20));
    d.controlFrame(win.tree.structHandle, (i32)b.index, &fx, &fy, &fw, &fh);
    check("moving it moves the NATIVE control, with no realize", fx, (i32)120);
    check("and resizes it", fw, (i32)90);

    // Siblings are untouched — the push must reach ONE control.
    check("its neighbour is unaffected",
          d.controlEnabled(win.tree.structHandle, (i32)r.index), (i32)1);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: enabled and frame reach the native control immediately\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
