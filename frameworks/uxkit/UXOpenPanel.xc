// UXOpenPanel.xc — run a file-open dialog and return the chosen path (NSOpenPanel / GetOpenFileName in
// shape).  Where the backend has a native dialog it uses it; on GEM (no OS file selector) it falls back
// to a toolkit-drawn modal panel built from UXFileChooser + the neutral widgets.
#import "UXViewDriver.xc"
#import "UXLibc.xc"
#import "UXFilePanel.xc"

class UXOpenPanel
    {
    // Returns a malloc'd path string the caller owns, or null if the user cancelled.
    static u8* run(u8* prompt, u8* startDir)
        {
        if (gDriver.hasNativeFileOpen())
            {
            u8* buf = (u8*)malloc((u32)1024);
            buf[(i32)0] = (u8)0;
            if (gDriver.fileOpen(prompt, startDir, buf, (i32)1024) != (i32)0)
                {
                return buf;
                }
            return (u8*)0; // cancelled
            }
        return UXOpenPanel.runToolkit(prompt, startDir); // GEM: toolkit-drawn panel
        }

    // The toolkit-drawn modal panel (GEM): a real file browser built from the neutral widgets.
    static u8* runToolkit(u8* prompt, u8* startDir)
        {
        UXFilePanel* p = new UXFilePanel();
        return p.run(prompt, startDir);
        }
    }
