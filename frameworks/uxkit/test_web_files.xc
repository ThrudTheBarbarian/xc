// test_web_files.xc — open and save on the web, in a REAL browser's worker run loop (the web-files
// gate).  A browser has no file system: a save is the browser's download, and an open is the page's
// dialog, whose Choose button opens the real file picker.  Here the app saves through UXSavePanel and
// UXFileIO (tools/web_files.html checks the download arrived, name and bytes), then opens through
// UXOpenPanel (the page "picks" a file for the dialog's <input type=file>, as a user would) and
// reads it back with UXFileIO, UTF-8 intact.  Then a second open is cancelled.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXOpenPanel.xc"
#import "UXSavePanel.xc"
#import "UXFileIO.xc"

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
bool sameBytes(u8* a, u8* b)
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
    gFails = (i32)0;
    UXWebDriver* d = new UXWebDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    ck((u8*)"in the worker, the web has native open and save", d.hasNativeFileOpen() && d.hasNativeFileSave());

    u8* where = UXSavePanel.run((u8*)"Save the notes", (u8*)"", (u8*)"notes.txt");
    ck((u8*)"saving names the file", where != (u8*)0 && sameBytes(where, (u8*)"/notes.txt"));
    if (where != (u8*)0)
        {
        ck((u8*)"...and the write is the browser's download", UXFileIO.write(where, UXData.fromString((u8*)"saved from the worker")));
        UXData* back = UXFileIO.read(where);
        ck((u8*)"...which the app can read back", back != (UXData*)0 && back.length() == (i32)21);
        }

    u8* picked = UXOpenPanel.run((u8*)"Open a note", (u8*)"");
    ck((u8*)"opening gives the picked file's path", picked != (u8*)0 && sameBytes(picked, (u8*)"/picked/from disk.txt"));
    if (picked != (u8*)0)
        {
        UXData* got = UXFileIO.read(picked);
        bool ok = got != (UXData*)0;
        if (ok)
            {
            got.appendByte((u8)0);
            ok = sameBytes(got.bytes(), (u8*)"héllo from the disk, 日本");
            }
        ck((u8*)"...whose bytes UXFileIO reads, UTF-8 intact", ok);
        }
    u8* none = UXOpenPanel.run((u8*)"Open another", (u8*)"");
    ck((u8*)"a cancelled open gives nothing", none == (u8*)0);

    Stdio.printf(gFails == (i32)0 ? "PASS: web files -- a save is a download, an open is the browser's picker, both through UXFileIO\n" : "FAIL: %d\n", gFails);
    }
