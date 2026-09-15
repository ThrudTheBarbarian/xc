// UXAlert.xc — alerts, and the only modal thing in the toolkit.
//
// A GEM alert is a STRING:  "[icon][line|line|line][button|button]"
// form_alert builds the tree, centres it, saves what is underneath, runs the modal
// loop, restores, and returns the 1-based button.  So UXAlert writes no dialog code:
// it describes the alert and reads the answer.
//
// icon: 0 none, 1 note, 2 wait, 3 stop — the theme has art for all three.
//
// Neutral now: UXAlert is the MODEL (icon, lines, buttons, default) and runModal() hands it to
// the driver, which pops the native dialog — GEM's form_alert, Win32's MessageBox, AppKit's
// NSAlert — and returns the 1-based button.  No backend string format lives here.
#import "UXControl.xc"
#import "UXString.xc"
#import "UXViewDriver.xc"

class UXAlert : Object
    {
    i32 icon;          // 0 none / 1 note / 2 wait / 3 stop
    u8* lines;         // "line|line"
    u8* buttons;       // "OK|Cancel"
    i32 defaultButton; // 1-based; Return fires it (Esc fires the cancel one)

    void init(void)
        {
        icon = (i32)1;
        lines = "";
        buttons = "";
        defaultButton = (i32)1;
        }

    // '|'
    void addLine(u8* s)
        {
        lines = UXStr.cat(lines, (u8)124, s);
        }
    void addButton(u8* s)
        {
        buttons = UXStr.cat(buttons, (u8)124, s);
        }

    // Modal.  Returns the 1-based button.  The driver pops the native dialog and does the rest.
    i32 runModal(void)
        {
        return gDriver.alertRun(icon, lines, buttons, defaultButton);
        }
    }
