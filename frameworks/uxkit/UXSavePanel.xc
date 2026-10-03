// UXSavePanel.xc — run a file-save dialog and return the path to write (NSSavePanel / GetSaveFileName in
// shape).  The sibling of UXOpenPanel: the platform's own dialog where it has one (AppKit, GTK, Win32), otherwise
// UXKit's drawn file panel in SAVE mode -- a name field, a Save button, folders to navigate, and an
// existing file confirmed before it is replaced.
#import "UXViewDriver.xc"
#import "UXLibc.xc"
#import "UXFilePanel.xc"

class UXSavePanel
    {
    // Returns a malloc'd path the caller owns (and frees), or null if the user cancelled.
    // `defaultName` is the name the field starts with ("untitled.rsc", or the document's own).
    static u8* run(u8* prompt, u8* startDir, u8* defaultName)
        {
        if (gDriver.hasNativeFileSave())
            {
            u8* buf = (u8*)malloc((u32)1024);
            buf[(i32)0] = (u8)0;
            if (gDriver.fileSave(prompt, startDir, defaultName, buf, (i32)1024) != (i32)0)
                {
                return buf;
                }
            free((pointer)buf);
            return (u8*)0; // cancelled
            }
        return UXSavePanel.runToolkit(prompt, startDir, defaultName);
        }

    // UXKit's drawn panel, in save mode.
    static u8* runToolkit(u8* prompt, u8* startDir, u8* defaultName)
        {
        UXFilePanel* p = new UXFilePanel();
        return p.runSave(prompt, startDir, defaultName);
        }
    }
