// test_input.xc — the input additions, neutrally: a key's release and the middle button climb the
// responder chain as a press does, a control keeps its own copy of its title, and the key codes
// every backend produces.  No driver, so it runs on every target.
#import <Stdio.xc>
#import "UXControl.xc"
#import "UXEvent.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
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

// The top of a chain: counts what reaches it.
class Sink : UXResponder
    {
    i32 ups;
    i32 others;
    u16 lastKey;
    u16 lastMods;
    void keyUp(UXEvent* e)
        {
        ups = ups + (i32)1;
        lastKey = e.key;
        lastMods = e.modifiers;
        }
    void otherMouseDown(UXEvent* e)
        {
        others = others + (i32)1;
        lastMods = e.modifiers;
        }
    }

void main(void)
    {
    Stdio.printf("-- a release and the middle button climb the chain\n");
    Sink* top = new Sink();
    UXResponder* mid = new UXResponder();
    UXResponder* leaf = new UXResponder();
    leaf.setNextResponder(mid);
    mid.setNextResponder(top);
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventKeyUp;
    e.key = (u16)UX_KEY_LEFT;
    e.modifiers = (u16)UX_MOD_SHIFT;
    leaf.keyUp(e);
    check("keyUp reached the top", top.ups, (i32)1);
    check("  with its key", (i32)top.lastKey, (i32)UX_KEY_LEFT);
    check("  and its modifiers", (i32)top.lastMods, (i32)UX_MOD_SHIFT);
    e.kind = (u8)UXEventOtherMouseDown;
    e.buttons = (u16)UX_BUTTON_MIDDLE;
    e.modifiers = (u16)(UX_MOD_CMD | UX_MOD_ALT);
    leaf.otherMouseDown(e);
    check("otherMouseDown reached the top", top.others, (i32)1);
    check("  with Command and Option", (i32)top.lastMods, (i32)(UX_MOD_CMD | UX_MOD_ALT));

    Stdio.printf("-- a control keeps its own copy of its title\n");
    u8 buf[16];
    buf[0] = (u8)'O';
    buf[1] = (u8)'K';
    buf[2] = (u8)0;
    UXButton* b = new UXButton();
    b.setTitle(&buf[0]);
    check("the title is not the caller's buffer", b.title == &buf[0] ? (i32)0 : (i32)1, (i32)1);
    buf[0] = (u8)'N';
    buf[1] = (u8)'O';
    check("changing the buffer later leaves the title", streq(b.title, (u8*)"OK") ? (i32)1 : (i32)0, (i32)1);
    b.setTitle((u8*)"Cancel");
    check("a new title replaces it", streq(b.title, (u8*)"Cancel") ? (i32)1 : (i32)0, (i32)1);
    UXLabel* l = new UXLabel();
    buf[0] = (u8)'H';
    buf[1] = (u8)'i';
    l.setText(&buf[0]);
    buf[0] = (u8)'?';
    check("a label's text is copied too", streq(l.text(), (u8*)"Hi") ? (i32)1 : (i32)0, (i32)1);
    l.setText((u8*)0);
    check("no text is no text", l.text() == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    Stdio.printf("-- the key codes\n");
    check("an arrow has no character", (i32)UX_KEY_UP & (i32)UX_KEY_ASCII, (i32)0);
    check("Backspace is its character with GEM's scan code", (i32)UX_KEY_BACKSPACE & (i32)UX_KEY_ASCII, (i32)8);
    check("Escape too", (i32)UX_KEY_ESCAPE & (i32)UX_KEY_ASCII, (i32)27);
    check("Command is apart from GEM's kstate", (i32)UX_MOD_CMD & (i32)(UX_MOD_SHIFT | UX_MOD_CTRL | UX_MOD_ALT), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: input -- key release, middle button, modifiers, title copies, key codes\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
