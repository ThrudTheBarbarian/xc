// test_savepanel.xc — UXKit's drawn save panel (UXSavePanel's fallback: UXFilePanel in save mode), on a
// real driver over a real folder: the name field starts as the default; Save answers with folder +
// name; an existing file is confirmed before it is replaced (and a No keeps the panel up); a folder
// name is entered rather than saved over; ".." goes up.  The listing comes from the driver's listDir,
// which on the POSIX backends is ux_posix_fs.h -- so this is also the gate that the drawn panel sees
// files at all on AppKit and GTK.
//
// macOS: AppKit, headless.  x86_64: GTK on real Linux (run_gtk_linux.sh test_savepanel).
#import <Stdio.xc>
#if ARCH_x86_64
#import "UXGtkDriver.xc"
#else
#import "UXAppKitDriver.xc"
#endif
#import "UXFilePanel.xc"
#import "UXFileIO.xc"

i32 mkdir(u8* path, u32 mode);
i32 rmdir(u8* path);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool sameText(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return false;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
// "dir/leaf", owned by the returned data
Data* joined(u8* dir, u8* leaf)
    {
    Data* d = UXStr.toData(dir);
    d.appendByte((u8)'/');
    d.append(UXStr.toData(leaf));
    d.appendByte((u8)0);
    return d;
    }

// The Replace question, answered by the test instead of a modal alert.
class TestSavePanel : UXFilePanel
    {
    i32 asked;
    bool answer;
    void init(void)
        {
        super.init();
        asked = (i32)0;
        answer = false;
        }
    bool confirmReplace(u8* name)
        {
        asked = asked + (i32)1;
        return answer;
        }
    }

void main(void)
    {
    gFails = (i32)0;
#if ARCH_x86_64
    UXGtkDriver* d = new UXGtkDriver();
#else
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
#endif
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }

    // a scratch folder: one file, one subfolder
    u8* dir = (u8*)"/tmp/uxsavepanel_test";
    mkdir(dir, (u32)$1ED);
    Data* sub = joined(dir, (u8*)"sub");
    mkdir(sub.bytes(), (u32)$1ED);
    Data* existing = joined(dir, (u8*)"a.rsc");
    UXFileIO.write(existing.bytes(), UXStr.toData((u8*)"old"));

    TestSavePanel* p = new TestSavePanel();
    p.saveMode = true;
    p.defName = (u8*)"new.rsc";
    p.curDir = dir;
    p.win = new UXWindow();
    p.buildPanel(new UXFilePanelBack(), (u8*)"Save");

    ck((u8*)"the driver lists the folder: one file", p.allFiles.count() == (u16)1);
    ck((u8*)"...and one subfolder", p.allDirs.count() == (u16)1);
    ck((u8*)"the name field starts as the default", sameText(p.selField.text(), (u8*)"new.rsc"));

    // a new name: saved straight away, no question
    p.onOpen((UXControl*)0);
    ck((u8*)"Save with a new name answers", p.done && p.result == (i32)1);
    ck((u8*)"...folder + name", sameText(p.chosenPath, joined(dir, (u8*)"new.rsc").bytes()));
    ck((u8*)"...without asking", p.asked == (i32)0);

    // an existing name: asked, and No keeps the panel up
    p.done = false;
    p.result = (i32)0;
    p.selField.setText((u8*)"a.rsc");
    p.answer = false;
    p.onOpen((UXControl*)0);
    ck((u8*)"an existing file is asked about", p.asked == (i32)1);
    ck((u8*)"...and No does not save", !p.done);
    p.answer = true;
    p.onOpen((UXControl*)0);
    ck((u8*)"Yes saves over it", p.done && sameText(p.chosenPath, existing.bytes()));

    // a folder's name goes into the folder, and the name goes back to the default
    p.done = false;
    p.selField.setText((u8*)"sub");
    p.onOpen((UXControl*)0);
    ck((u8*)"a folder's name enters it", !p.done && sameText(p.curDir, sub.bytes()));
    ck((u8*)"...and the name field is the default again", sameText(p.selField.text(), (u8*)"new.rsc"));
    // a click on a folder row (enter -> reload) must not wipe a typed name in save mode
    p.selField.setText((u8*)"typed.rsc");
    p.goUp();
    ck((u8*)"save mode: a folder change keeps the typed name", sameText(p.selField.text(), (u8*)"typed.rsc"));
    p.enter((u8*)"sub");
    p.selField.setText((u8*)"..");
    p.onOpen((UXControl*)0);
    ck((u8*)"\"..\" goes back up", !p.done && sameText(p.curDir, dir));
    p.win.close();

    // OPEN mode is unchanged: a folder change clears the selection
    UXFilePanel* o = new UXFilePanel();
    o.curDir = dir;
    o.win = new UXWindow();
    o.buildPanel(new UXFilePanelBack(), (u8*)"Open");
    o.selField.setText((u8*)"a.rsc");
    o.enter((u8*)"sub");
    ck((u8*)"open mode: entering a folder clears the selection", o.selField.text()[(i32)0] == (u8)0);
    o.win.close();

    remove(existing.bytes());
    rmdir(sub.bytes());
    rmdir(dir);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the drawn save panel -- name, replace, folders, and a real listing\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
