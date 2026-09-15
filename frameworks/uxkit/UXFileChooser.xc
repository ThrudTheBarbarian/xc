// UXFileChooser.xc — the model behind an open/save file panel (NSOpenPanel/NSSavePanel in shape).
//
// It owns the navigation state (current directory as an UXPath), a backend-supplied listing of the
// directory's entries, an extension filter, and a customisable prompt string.  Directories always
// show; files show only when they match an allowed extension (empty filter = all).  Entering a folder
// and going up are UXPath surgery.  The panel VIEW and the actual directory read are the backend's job
// — this is the testable model it drives.
#import "Array.xc"
#import "UXPath.xc"

class UXFileEntry : Object
    {
    u8* name;
    bool isDir;
    void init(void)
        {
        name = (u8*)"";
        isDir = false;
        }
    static UXFileEntry* make(u8* name, bool isDir)
        {
        UXFileEntry* e = new UXFileEntry();
        e.name = name;
        e.isDir = isDir;
        return e;
        }
    }

    class UXFileChooser
    {
    UXPath* dir;
    Array<UXFileEntry>* entries;    // of UXFileEntry — the current directory's listing (set by the backend)
    Array<UXFileEntry>* extensions; // of UXFileEntry (name = the allowed extension); empty = accept all files
    bool saveMode;
    u8* prompt;
    u8* saveName;

    void init(void)
        {
        dir = UXPath.parse((u8*)"/");
        entries = new Array();
        extensions = new Array();
        saveMode = false;
        prompt = (u8*)"Open";
        saveName = (u8*)"";
        }

    void setDirectory(UXPath* p)
        {
        dir = p;
        }
    UXPath* directory(void)
        {
        return dir;
        }
    void setEntries(Array* e)
        {
        entries = e;
        }
    void allowExtension(u8* ext)
        {
        extensions.add(UXFileEntry.make(ext, false));
        }
    void setSaveMode(bool on)
        {
        saveMode = on;
        if (on && UXFileChooser.streq(prompt, (u8*)"Open"))
            {
            prompt = (u8*)"Save";
            }
        }
    // the customisable button/title string
    void setPrompt(u8* p)
        {
        prompt = p;
        }
    u8* promptString(void)
        {
        return prompt;
        }
    void setSaveName(u8* n)
        {
        saveName = n;
        }

    static bool streq(u8* a, u8* b)
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
    static u8 lower(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') ? (u8)(c + (u8)32) : c;
        }
    // case-insensitive equality (extensions)
    static bool ieq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (UXFileChooser.lower(a[i]) != UXFileChooser.lower(b[i]))
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    bool acceptsFile(u8* name)
        {
        if (extensions.count() == (u16)0)
            {
            return true;
            }
        u8* ext = UXPath.parse(name).pathExtension();
        for (u16 i = (u16)0; i < extensions.count(); i = i + (u16)1)
            {
            if (UXFileChooser.ieq(((UXFileEntry* ?)extensions.get(i)).name, ext))
                {
                return true;
                }
            }
        return false;
        }

    // Directories always; files only if they pass the extension filter.
    Array<UXFileEntry>* visibleEntries(void)
        {
        Array<UXFileEntry>* out = new Array();
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXFileEntry* e = (UXFileEntry* ?)entries.get(i);
            if (e.isDir || self.acceptsFile(e.name))
                {
                out.add(e);
                }
            }
        return out;
        }
    i32 visibleCount(void)
        {
        return (i32)self.visibleEntries().count();
        }

    // ---- navigation (UXPath surgery) ----------------------------------------
    void enter(u8* dirname)
        {
        dir = dir.appendingComponent(dirname);
        entries = new Array();
        }
    void goUp(void)
        {
        dir = dir.deletingLastComponent();
        entries = new Array();
        }

    // The full path the panel would return for a chosen name (or the save name in save mode).
    u8* resultPath(u8* chosenName)
        {
        u8* leaf = saveMode ? saveName : chosenName;
        return dir.appendingComponent(leaf).toString();
        }
    }
