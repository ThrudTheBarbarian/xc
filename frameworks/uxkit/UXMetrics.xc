// UXMetrics.xc — the standard control sizes, adaptable by form factor.
//
// The portrait audit showed the problem: with no blessed sizes, no two
// platforms rendered a button alike, and a UI laid out on one realm's rows
// overflows another's.  The answer is NOT one global table — a desktop row
// and a touch target are legitimately different sizes — so the standards
// adapt on the one axis that matters: the form factor.  Desktop rows sit
// on the classic 28px basis; the device realm sits on the 44pt touch
// target (Apple's floor; Android's 48dp guidance rounds to the same place
// in neutral units).
//
// The contract this table completes (the drivers keep their half): a
// control FILLS the frame it is given and never exceeds it — theme
// minimums are clamped where the platform allows (Android's setMinHeight,
// GTK's CSS floors) — and the handful of genuinely fixed-intrinsic
// controls (UIStepper, UISwitch) are centred in the frame, with their
// standard size here chosen large enough to hold them.
//
// The pure ...For(kind, ff) forms are the unit-testable truth; the short
// forms read the live driver's formFactorClass().  Rocks snaps to these,
// the showcase poses with them, and hand-laid UIs that adopt them get the
// same fit on every backend.
#import "UXGeometry.xc"
#import "UXViewDriver.xc"

class UXMetrics : Object
    {

    static bool deviceRealm(i32 ff)
        {
        return ff == (i32)UX_FORM_TABLET || ff == (i32)UX_FORM_PHONE;
        }

    // ---- the standard height for a control kind, per form factor -------------
    static i32 stdHeightFor(i32 kind, i32 ff)
        {
        bool dev = UXMetrics.deviceRealm(ff);
        if (kind == (i32)UXKindButton)
            {
            return dev ? (i32)44 : (i32)28;
            }
        if (kind == (i32)UXKindField)
            {
            return dev ? (i32)36 : (i32)24;
            }
        if (kind == (i32)UXKindLabel)
            {
            return dev ? (i32)20 : (i32)16;
            }
        // device: holds a UISwitch
        if (kind == (i32)UXKindCheckbox)
            {
            return dev ? (i32)32 : (i32)20;
            }
        if (kind == (i32)UXKindRadio)
            {
            return dev ? (i32)32 : (i32)20;
            }
        if (kind == (i32)UXKindSlider)
            {
            return dev ? (i32)32 : (i32)20;
            }
        if (kind == (i32)UXKindPopup)
            {
            return dev ? (i32)36 : (i32)26;
            }
        // device: holds a UIStepper
        if (kind == (i32)UXKindStepper)
            {
            return dev ? (i32)32 : (i32)26;
            }
        // device idiom is a thin line
        if (kind == (i32)UXKindProgress)
            {
            return dev ? (i32)8 : (i32)12;
            }
        if (kind == (i32)UXKindSegmented)
            {
            return dev ? (i32)32 : (i32)26;
            }
        return dev ? (i32)44 : (i32)24; // a sane default row
        }

    // ---- the minimum comfortable width, per form factor ----------------------
    static i32 minWidthFor(i32 kind, i32 ff)
        {
        bool dev = UXMetrics.deviceRealm(ff);
        if (kind == (i32)UXKindButton)
            {
            return dev ? (i32)64 : (i32)80;
            }
        if (kind == (i32)UXKindField)
            {
            return (i32)120;
            }
        if (kind == (i32)UXKindSlider)
            {
            return (i32)120;
            }
        // UIStepper is 94pt wide
        if (kind == (i32)UXKindStepper)
            {
            return dev ? (i32)96 : (i32)60;
            }
        if (kind == (i32)UXKindPopup)
            {
            return (i32)100;
            }
        if (kind == (i32)UXKindSegmented)
            {
            return (i32)120;
            }
        if (kind == (i32)UXKindProgress)
            {
            return (i32)120;
            }
        return (i32)60;
        }

    // ---- the navigation bar --------------------------------------------------
    // The drawn nav bar's height (UXNavigationController's fallback bar; the
    // native realizations bring their own chrome and ignore this).
    static i32 navBarHeightFor(i32 ff)
        {
        return UXMetrics.deviceRealm(ff) ? (i32)44 : (i32)28;
        }
    static i32 navBarHeight(void)
        {
        return UXMetrics.navBarHeightFor(gDriver.formFactorClass());
        }

    // ---- rows and gutters ----------------------------------------------------
    // The spacing that makes a column of standard controls read as a form.
    static i32 rowSpacingFor(i32 ff)
        {
        return UXMetrics.deviceRealm(ff) ? (i32)12 : (i32)8;
        }
    static i32 gutterFor(i32 ff)
        {
        return UXMetrics.deviceRealm(ff) ? (i32)16 : (i32)12;
        }

    // ---- the live forms (read the booted driver's realm) ---------------------
    static i32 stdHeight(i32 kind)
        {
        return UXMetrics.stdHeightFor(kind, gDriver.formFactorClass());
        }
    static i32 minWidth(i32 kind)
        {
        return UXMetrics.minWidthFor(kind, gDriver.formFactorClass());
        }
    static i32 rowSpacing(void)
        {
        return UXMetrics.rowSpacingFor(gDriver.formFactorClass());
        }
    static i32 gutter(void)
        {
        return UXMetrics.gutterFor(gDriver.formFactorClass());
        }

    // The standard frame for a kind at a position — the one-liner a form
    // builder wants: UXMetrics.stdFrame(UXKindButton, x, y, w) with w <= 0
    // meaning "the minimum comfortable width".
    static UXRect stdFrame(i32 kind, i32 x, i32 y, i32 w)
        {
        i32 ff = gDriver.formFactorClass();
        i32 useW = w > (i32)0 ? w : UXMetrics.minWidthFor(kind, ff);
        return UXGeom.make((i16)x, (i16)y, (i16)useW, (i16)UXMetrics.stdHeightFor(kind, ff));
        }
    }
