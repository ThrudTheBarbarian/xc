// test_menukeys.xc — menu shortcuts, neutrally: how an item carries one, how a driver reads it back
// (UXMenuKey), and the matcher that fires an item from a key press on the backends whose menus do
// not handle their own keys.  No driver, so it runs on every target.
#import <Stdio.xc>
#import "UXMenu.xc"
#import "UXEvent.xc"

i32 gFails;
i32 gUndo;
i32 gRedo;
i32 gCopy;
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
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void checkStr(u8* what, u8* got, u8* want)
    {
    check(what, streq(got, want) ? (i32)1 : (i32)0, (i32)1);
    if (!streq(got, want))
        {
        Stdio.printf("       got \"%s\"\n", got);
        }
    }

class Target : Object
    {
    void onUndo(UXMenuItem* s)
        {
        gUndo = gUndo + (i32)1;
        }
    void onRedo(UXMenuItem* s)
        {
        gRedo = gRedo + (i32)1;
        }
    void onCopy(UXMenuItem* s)
        {
        gCopy = gCopy + (i32)1;
        }
    void onNothing(UXMenuItem* s)
        {
        }
    }

UXEvent* key(u8 c, u16 mods)
    {
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventKeyDown;
    e.key = (u16)c;
    e.modifiers = mods;
    return e;
    }

void main(void)
    {
    Target* t = new Target();
    UXMenuBar* bar = new UXMenuBar();
    UXMenu* edit = bar.addMenu((u8*)"Edit");
    UXMenuItem* undo = edit.addItem((u8*)"Undo", &t.onUndo).setShortcut((u8)'z', false);
    UXMenuItem* redo = edit.addItem((u8*)"Redo", &t.onRedo).setShortcut((u8)'Z', true);
    edit.addSeparator();
    UXMenuItem* copy = edit.addItem((u8*)"Copy", &t.onCopy).setShortcut((u8)'C', false);
    UXMenuItem* plain = edit.addItem((u8*)"Plain", &t.onNothing);
    UXMenuItem* off = edit.addItem((u8*)"Paste", &t.onNothing).setShortcut((u8)'V', false);
    off.enabled = false;

    Stdio.printf("-- how an item carries its shortcut\n");
    check("a lower-case key is stored upper-case", (i32)undo.key, (i32)'Z');
    checkStr("Undo", undo.encoded(), (u8*)"Undo\tZ");
    checkStr("Redo, with Shift", redo.encoded(), (u8*)"Redo\t+Z");
    checkStr("an item without one is its title", plain.encoded(), (u8*)"Plain");
    u8* pe = off.encoded();
    check("a disabled one keeps its marker", (i32)pe[0], (i32)2);
    checkStr("and its shortcut", &pe[1], (u8*)"Paste\tV");

    Stdio.printf("-- how a driver reads it\n");
    check("the key", (i32)UXMenuKey.key(redo.encoded()), (i32)'Z');
    check("Shift", UXMenuKey.shift(redo.encoded()) ? (i32)1 : (i32)0, (i32)1);
    check("no Shift", UXMenuKey.shift(undo.encoded()) ? (i32)1 : (i32)0, (i32)0);
    checkStr("the title alone", UXMenuKey.title(redo.encoded()), (u8*)"Redo");
    checkStr("Win32 spells it out", UXMenuKey.labelled(redo.encoded(), (u8*)"\t", (u8*)"Ctrl+", (u8*)"Shift+"), (u8*)"Redo\tShift+Ctrl+Z");
    checkStr("GEM writes ^Z", UXMenuKey.labelled(undo.encoded(), (u8*)"  ", (u8*)"^", (u8*)"S"), (u8*)"Undo  ^Z");
    check("no shortcut, no key", (i32)UXMenuKey.key(plain.encoded()), (i32)0);

    Stdio.printf("-- the matcher\n");
    check("Ctrl+Z fires Undo", bar.performShortcut(key((u8)'z', (u16)UX_MOD_CTRL)) ? (i32)1 : (i32)0, (i32)1);
    check("  Undo", gUndo, (i32)1);
    check("a control code with Ctrl fires it too", bar.performShortcut(key((u8)26, (u16)UX_MOD_CTRL)) ? (i32)1 : (i32)0, (i32)1);
    check("  Undo", gUndo, (i32)2);
    check("Ctrl+Shift+Z fires Redo", bar.performShortcut(key((u8)26, (u16)(UX_MOD_CTRL | UX_MOD_SHIFT))) ? (i32)1 : (i32)0, (i32)1);
    check("  Redo, not Undo", gRedo * (i32)10 + gUndo, (i32)12);
    check("Ctrl+C fires Copy", bar.performShortcut(key((u8)'c', (u16)UX_MOD_CTRL)) ? (i32)1 : (i32)0, (i32)1);
    check("  Copy", gCopy, (i32)1);
    check("a plain z is typing", bar.performShortcut(key((u8)'z', (u16)0)) ? (i32)1 : (i32)0, (i32)0);
    check("a control code without Ctrl is typing", bar.performShortcut(key((u8)26, (u16)0)) ? (i32)1 : (i32)0, (i32)0);
    check("a disabled item does not fire", bar.performShortcut(key((u8)'v', (u16)UX_MOD_CTRL)) ? (i32)1 : (i32)0, (i32)0);
    check("an unbound key does not", bar.performShortcut(key((u8)'q', (u16)UX_MOD_CTRL)) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: menu shortcuts -- encoding, reading, matching\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
