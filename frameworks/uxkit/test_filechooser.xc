// test_filechooser.xc — UXFileChooser: extension filtering, navigation, result path, save mode.
#import <Stdio.xc>
#import "UXFileChooser.xc"
#import "UXPath.xc"

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
bool streq(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

Array<UXFileEntry>* listing(void)
    {
    Array<UXFileEntry>* a = new Array();
    a.add(UXFileEntry.make((u8*)"Documents", true));
    a.add(UXFileEntry.make((u8*)"report.txt", false));
    a.add(UXFileEntry.make((u8*)"photo.PNG", false)); // uppercase ext
    a.add(UXFileEntry.make((u8*)"notes.md", false));
    a.add(UXFileEntry.make((u8*)"archive.zip", false));
    return a;
    }

void main(void)
    {
    gFails = (i32)0;
    UXFileChooser* ch = new UXFileChooser();
    ch.setDirectory(UXPath.parse((u8*)"/Users/ada"));
    ch.setEntries(listing());

    // no filter -> everything (5 entries)
    check("all entries visible unfiltered", ch.visibleCount(), (i32)5);

    // filter to .txt and .md -> Documents(dir) + report.txt + notes.md = 3
    ch.allowExtension((u8*)"txt");
    ch.allowExtension((u8*)"md");
    check("filtered to txt+md (+dir)", ch.visibleCount(), (i32)3);

    // case-insensitive extension: allow png -> Documents + photo.PNG = ... plus txt/md already allowed
    ch.allowExtension((u8*)"png");
    check("png (case-insensitive) now included", ch.visibleCount(), (i32)4);

    // navigation
    ch.enter((u8*)"Documents");
    eq("entered subdir", ch.directory().toString(), (u8*)"/Users/ada/Documents");
    ch.goUp();
    eq("went up", ch.directory().toString(), (u8*)"/Users/ada");

    // result path (open mode)
    eq("open result path", ch.resultPath((u8*)"report.txt"), (u8*)"/Users/ada/report.txt");

    // prompt customisation
    ch.setPrompt((u8*)"Choose a Project");
    eq("custom prompt", ch.promptString(), (u8*)"Choose a Project");

    // save mode: result uses the save name, not the chosen entry
    UXFileChooser* sv = new UXFileChooser();
    sv.setDirectory(UXPath.parse((u8*)"/tmp"));
    sv.setSaveMode(true);
    eq("save mode default prompt", sv.promptString(), (u8*)"Save");
    sv.setSaveName((u8*)"untitled.txt");
    eq("save result uses save name", sv.resultPath((u8*)"ignored"), (u8*)"/tmp/untitled.txt");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXFileChooser — filtering (case-insensitive), navigation, result path, save mode, prompt.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
