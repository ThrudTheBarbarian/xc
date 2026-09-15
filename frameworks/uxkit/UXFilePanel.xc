// UXFilePanel.xc — a toolkit-drawn modal file panel for backends with no OS dialog (GEM/Win32-under-
// Wine), in the spirit of the Atari ST Universal Item Selector: a scrolling, sorted, mask-filtered
// directory list with a scrollbar, editable Mask + Selection lines, and a button column that both opens
// files and manages them — Find / Rename / Copy / Move / Delete.  UXOpenPanel.runToolkit() drives it.
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXViewDriver.xc"
#import "UXEvent.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXString.xc"
#import "UXLibc.xc"
#import "UXAlert.xc"
#import "UXGroupBox.xc"

#define FP_ROWH 18
#define FP_ROWS 10
#define FP_SBW 14
#define FP_HDRH 18   // the clickable column-title strip above the list
#define FP_SIZEW 74  // width of the right-hand Size column
#define FP_RECMAX 12 // how many recent files to remember
#define FP_SORT_NAME 0
#define FP_SORT_SIZE 1
#define FP_CHARW 6 // approx glyph width, for right-aligning the size text (no measure API)

// Session memory, shared across every panel the app opens: where you were last browsing (so re-opening
// returns there), and the files you have recently chosen.  Both outlive an individual UXFilePanel.
u8* gFileLastDir;               // last directory browsed, malloc'd (null until the first panel closes)
Array<UXFileRow>* gFileRecents; // UXFileRow (name = full path), most-recent first (null until first use)

class UXFileRow : Object
    {
    u8* name;
    bool isDir;
    u32 size;
    void init(void)
        {
        name = (u8*)"";
        isDir = false;
        size = (u32)0;
        }
    // A factory keeps the `new` out of reload()'s loop (the compiler warns on new-in-a-loop even when,
    // as here, the object is kept by the array).
    static UXFileRow* make(u8* n, bool d, u32 sz)
        {
        UXFileRow* r = new UXFileRow();
        r.name = n;
        r.isDir = d;
        r.size = sz;
        return r;
        }
    }

    class UXFilePanelBack : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class UXFileListView : UXView
    {
    weak : UXFilePanel* panel;
    void init(void)
        {
        super.init();
        panel = (UXFilePanel*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 listW = (i16)(b.w - (i16)FP_SBW);
        g.fillRect(UXGeom.make((i16)0, (i16)0, listW, b.h), (i32)0);
        if (panel == (UXFilePanel*)0)
            {
            return;
            }
        i32 total = panel.count();
        i32 top = panel.scrollTop();
        i16 sizeR = (i16)(listW - (i16)6); // right edge of the Size column
        for (i32 v = (i32)0; v < (i32)FP_ROWS; v = v + (i32)1)
            {
            i32 i = top + v;
            if (i >= total)
                {
                break;
                }
            UXFileRow* r = panel.rowAt(i);
            i16 ry = (i16)(v * (i32)FP_ROWH);
            if (i == panel.selectedRow())
                {
                g.fillRect(UXGeom.make((i16)0, ry, listW, (i16)FP_ROWH), (i32)250);
                }
            // name on the left (folders get a leading '>'), size right-aligned on the right
            u8* label = r.isDir ? UXStr.append((u8*)"> ", r.name) : UXStr.append((u8*)"  ", r.name);
            g.drawText(label, (i16)6, (i16)(ry + (i16)4), (i32)1, (i32)0);
            // recents are paths, no size
            if (!r.isDir && !panel.isDotDot(r.name) && !panel.inRecents())
                {
                u8 sb[16];
                panel.formatSize(r.size, (u8*)&sb[0]);
                i16 sw = (i16)(panel.slen((u8*)&sb[0]) * (i32)FP_CHARW);
                g.drawText((u8*)&sb[0], (i16)(sizeR - sw), (i16)(ry + (i16)4), (i32)1, (i32)0);
                }
            }
        i16 sx = listW;
        g.fillRect(UXGeom.make(sx, (i16)0, (i16)FP_SBW, b.h), (i32)9);
        i16 ah = (i16)FP_SBW;
        i16 cx = (i16)(sx + (i16)FP_SBW / (i16)2);
        g.fillTriangle(cx, (i16)3, (i16)(sx + (i16)3), (i16)(ah - (i16)3), (i16)(sx + (i16)FP_SBW - (i16)3), (i16)(ah - (i16)3), (i32)0);
        i16 dy = (i16)(b.h - ah);
        g.fillTriangle((i16)(sx + (i16)3), (i16)(dy + (i16)3), (i16)(sx + (i16)FP_SBW - (i16)3), (i16)(dy + (i16)3), cx, (i16)(b.h - (i16)3), (i32)0);
        i16 trkY = ah;
        i16 trkH = (i16)(b.h - (i16)2 * ah);
        i32 shown = (i32)FP_ROWS;
        if (shown > total)
            {
            shown = total;
            }
        i32 range = total > (i32)0 ? total : (i32)1;
        i16 thumbH = (i16)((i32)trkH * shown / range);
        if (thumbH < (i16)12)
            {
            thumbH = (i16)12;
            }
        i32 maxTop = total - (i32)FP_ROWS;
        if (maxTop < (i32)1)
            {
            maxTop = (i32)1;
            }
        i16 thumbY = (i16)(trkY + (i16)((i32)(trkH - thumbH) * top / maxTop));
        g.fillRect(UXGeom.make((i16)(sx + (i16)2), thumbY, (i16)(FP_SBW - (i16)4), thumbH), (i32)0);
        }
    void mouseDown(UXEvent* e)
        {
        if (panel == (UXFilePanel*)0)
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i16 lx = (i16)((i32)e.x - abs.x);
        i16 ly = (i16)((i32)e.y - abs.y);
        i16 listW = (i16)(abs.w - (i16)FP_SBW);
        if (lx >= listW)
            {
            // up arrow
            if (ly < (i16)FP_SBW)
                {
                panel.scrollBy((i32)-1);
                return;
                }
            // down arrow
            if (ly > (i16)(abs.h - (i16)FP_SBW))
                {
                panel.scrollBy((i32)1);
                return;
                }
            // the track/thumb: jump to the click position, then follow the pointer (drag-to-scroll)
            i16 trkY = (i16)FP_SBW;
            i32 trkH = (i32)(abs.h - (i16)2 * (i16)FP_SBW);
            panel.setTopFromY((i32)ly - (i32)trkY, trkH);
            panel.repaintNow();
            i32 x = (i32)0;
            i32 y = (i32)0;
            while (gDriver.trackDragStep(&x, &y) != (i32)0)
                {
                panel.setTopFromY((i32)y - abs.y - (i32)trkY, trkH);
                panel.repaintNow();
                }
            return;
            }
        panel.rowClicked(panel.scrollTop() + ((i32)ly / (i32)FP_ROWH));
        }
    }

    // The clickable column-title strip above the list: "Name" and "Size".  Clicking a title sorts by that
    // column; clicking the one already active flips the direction (the little arrow shows which + which way).
    class UXFileHeader : UXView
    {
    weak : UXFilePanel* panel;
    void init(void)
        {
        super.init();
        panel = (UXFilePanel*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    // Name|Size boundary
    i16 splitX(void)
        {
        UXRect b = self.bounds();
        return (i16)(b.w - (i16)FP_SBW - (i16)FP_SIZEW);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 sx = self.splitX();
        i16 nameW = sx;
        i16 sizeW = (i16)(b.w - (i16)FP_SBW - sx);
        i32 key = panel != (UXFilePanel*)0 ? panel.sortColumn() : (i32)FP_SORT_NAME;
        // two themed header cells (Aristo2 'header'); the active one uses the pressed art
        g.drawTheme(key == (i32)FP_SORT_NAME ? (u8*)"header.pressed" : (u8*)"header", UXGeom.make((i16)0, (i16)0, nameW, b.h));
        g.drawTheme(key == (i32)FP_SORT_SIZE ? (u8*)"header.pressed" : (u8*)"header", UXGeom.make(sx, (i16)0, sizeW, b.h));
        g.drawText((u8*)"Name", (i16)6, (i16)3, (i32)1, (i32)0);
        g.drawText((u8*)"Size", (i16)(sx + (i16)6), (i16)3, (i32)1, (i32)0);
        // sort arrow on the active column (▲ ascending, ▼ descending)
        bool asc = panel != (UXFilePanel*)0 ? panel.sortAscending() : true;
        i16 ax = key == (i32)FP_SORT_NAME ? (i16)(nameW - (i16)14) : (i16)(b.w - (i16)FP_SBW - (i16)14);
        i16 ay = (i16)5;
        i16 aw = (i16)8;
        if (asc)
            {
            g.fillTriangle(ax, (i16)(ay + aw), (i16)(ax + aw), (i16)(ay + aw), (i16)(ax + aw / (i16)2), ay, (i32)1);
            }
        else
            {
            g.fillTriangle(ax, ay, (i16)(ax + aw), ay, (i16)(ax + aw / (i16)2), (i16)(ay + aw), (i32)1);
            }
        g.drawLine((i16)0, (i16)(b.h - (i16)1), b.w, (i16)(b.h - (i16)1), (i32)1);
        }
    void mouseDown(UXEvent* e)
        {
        if (panel == (UXFilePanel*)0)
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i16 lx = (i16)((i32)e.x - abs.x);
        panel.sortBy(lx < self.splitX() ? (i32)FP_SORT_NAME : (i32)FP_SORT_SIZE);
        }
    }

    class UXFilePanel : Object
    {
    u8* curDir;
    Array<UXFileRow>* allRows; // everything in curDir (sorted, folders first)
    Array<UXFileRow>* rows;    // allRows filtered by the mask
    i32 selected;
    u8* selName; // the picked entry's original name (Rename/Delete operate on it)
    i32 top;
    bool done;
    i32 result;
    u8* chosenPath;
    Array<UXFileRow>* allDirs;  // raw folder rows for the current dir (re-sorted on a header click)
    Array<UXFileRow>* allFiles; // raw file rows
    UXFileRow* dotRow;          // the ".." entry (null at the root); kept so re-sort needn't remake it
    UXWindow* win;
    UXFileListView* list;
    UXFileHeader* header;
    UXLabel* pathLabel;
    UXTextField* maskField;
    UXTextField* selField;
    UXCheckbox* hiddenBox;
    UXButton* recentBtn;
    u8* curMask;
    bool showHidden;
    bool recentsMode; // the list shows recent files, not curDir
    i32 sortKey;      // FP_SORT_NAME / FP_SORT_SIZE
    bool sortAsc;

    void init(void)
        {
        curDir = (u8*)"/";
        allRows = new Array();
        rows = new Array();
        allDirs = new Array();
        allFiles = new Array();
        selected = (i32)-1;
        selName = (u8*)"";
        top = (i32)0;
        done = false;
        result = (i32)0;
        chosenPath = (u8*)0;
        curMask = (u8*)"*";
        showHidden = false;
        recentsMode = false;
        sortKey = (i32)FP_SORT_NAME;
        sortAsc = true;
        }
    i32 sortColumn(void)
        {
        return sortKey;
        }
    bool sortAscending(void)
        {
        return sortAsc;
        }
    bool inRecents(void)
        {
        return recentsMode;
        }
    // unix hidden = a leading dot
    bool hidden(u8* name)
        {
        return name[(i32)0] == (u8)46;
        }

    i32 count(void)
        {
        return (i32)rows.count();
        }
    i32 selectedRow(void)
        {
        return selected;
        }
    i32 scrollTop(void)
        {
        return top;
        }
    UXFileRow* rowAt(i32 i)
        { return (UXFileRow* ?)rows.get((u16)i);
        }
    void scrollBy(i32 d)
        {
        top = top + d;
        i32 mx = self.count() - (i32)FP_ROWS;
        if (mx < (i32)0)
            {
            mx = (i32)0;
            }
        if (top > mx)
            {
            top = mx;
            }
        if (top < (i32)0)
            {
            top = (i32)0;
            }
        if (list != (UXFileListView*)0)
            {
            list.setNeedsDisplay();
            }
        }
    // Map a position along the scrollbar track (0..trkH) to the scroll offset — for dragging the thumb.
    void setTopFromY(i32 y, i32 trkH)
        {
        if (trkH <= (i32)0)
            {
            return;
            }
        i32 mx = self.count() - (i32)FP_ROWS;
        if (mx < (i32)0)
            {
            mx = (i32)0;
            }
        i32 t = y * mx / trkH;
        if (t < (i32)0)
            {
            t = (i32)0;
            }
        if (t > mx)
            {
            t = mx;
            }
        if (t != top)
            {
            top = t;
            if (list != (UXFileListView*)0)
                {
                list.setNeedsDisplay();
                }
            }
        }
    // repaint mid-drag (the modal loop is parked)
    void repaintNow(void)
        {
        win.display();
        gNeedsDisplay = false;
        }

    bool before(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            u8 ca = a[i];
            u8 cb = b[i];
            if (ca >= (u8)65 && ca <= (u8)90)
                {
                ca = (u8)(ca + (u8)32);
                }
            if (cb >= (u8)65 && cb <= (u8)90)
                {
                cb = (u8)(cb + (u8)32);
                }
            if (ca != cb)
                {
                return ca < cb;
                }
            i = i + (i32)1;
            }
        return a[i] == (u8)0 && b[i] != (u8)0;
        }
    // Order two rows by the active column, direction applied.  Name is the tiebreaker (and always the
    // key for the Name column); Size sorts numerically with Name breaking ties, so equal/zero-size
    // entries stay alphabetical rather than jittering.
    bool less(UXFileRow* a, UXFileRow* b)
        {
        if (sortKey == (i32)FP_SORT_SIZE)
            {
            // dirs are size 0
            if (a.size != b.size)
                {
                return sortAsc ? a.size < b.size : a.size > b.size;
                }
            return self.before(a.name, b.name); // tie (incl. all dirs): name stays A->Z either direction
            }
        return sortAsc ? self.before(a.name, b.name) : self.before(b.name, a.name);
        }
    // Return a NEW array of src's rows in sorted order, leaving src untouched (so a header click can
    // re-sort the same raw rows without re-listing the directory).  Repeated min-extraction — the lists
    // are a single directory, so O(n^2) is fine and reads clearly.
    Array<UXFileRow>* sortedCopy(Array<UXFileRow>* src)
        {
        Array<UXFileRow>* tmp = new Array();
        for (u16 i = (u16)0; i < src.count(); i = i + (u16)1)
            {
            tmp.add(src.get(i));
            }
        Array<UXFileRow>* out = new Array();
        while (tmp.count() > (u16)0)
            {
            u16 mi = (u16)0;
            for (u16 j = (u16)1; j < tmp.count(); j = j + (u16)1)
                {
                if (self.less((UXFileRow* ?)tmp.get(j), (UXFileRow* ?)tmp.get(mi)))
                    {
                    mi = j;
                    }
                }
            out.add(tmp.get(mi));
            tmp.removeAt(mi);
            }
        return out;
        }
    i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    // Unsigned int -> decimal string; returns the length written.
    i32 utoa(u32 n, u8* out)
        {
        if (n == (u32)0)
            {
            out[(i32)0] = (u8)48;
            out[(i32)1] = (u8)0;
            return (i32)1;
            }
        u8 tmp[12];
        i32 t = (i32)0;
        while (n > (u32)0)
            {
            tmp[t] = (u8)((u32)48 + (n % (u32)10));
            t = t + (i32)1;
            n = n / (u32)10;
            }
        for (i32 k = (i32)0; k < t; k = k + (i32)1)
            {
            out[k] = tmp[t - (i32)1 - k];
            }
        out[t] = (u8)0;
        return t;
        }
    // Human-readable size: bytes under 1K, else one decimal + K/M/G.
    void formatSize(u32 n, u8* out)
        {
        if (n < (u32)1024)
            {
            self.utoa(n, out);
            return;
            }
        u32 div;
        u8 unit;
        // 'K'
        if (n < (u32)1048576)
            {
            div = (u32)1024;
            unit = (u8)75;
            }
        // 'M'
        else if (n < (u32)1073741824)
            {
            div = (u32)1048576;
            unit = (u8)77;
            }
        // 'G'
        else
            {
            div = (u32)1073741824;
            unit = (u8)71;
            }
        u32 whole = n / div;
        u32 frac = ((n - whole * div) * (u32)10) / div;
        i32 p = self.utoa(whole, out);
        out[p] = (u8)46;
        p = p + (i32)1; // '.'
        out[p] = (u8)((u32)48 + frac);
        p = p + (i32)1;
        out[p] = unit;
        p = p + (i32)1;
        out[p] = (u8)0;
        }
    bool streq(u8* a, u8* b)
        {
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
    u8* dup(u8* s)
        {
        i32 n = self.slen(s);
        u8* o = (u8*)malloc((u32)(n + (i32)1));
        for (i32 k = (i32)0; k < n; k = k + (i32)1)
            {
            o[k] = s[k];
            }
        o[n] = (u8)0;
        return o;
        }
    // If the mask text changed since last check, re-filter (polled from the modal loop, so it works
    // however the backend delivers the edit — GEM AES inline, Win32 EN_CHANGE, or a routed keyDown).
    void syncMask(void)
        {
        if (recentsMode)
            {
            return;
            }
        if (maskField != (UXTextField*)0)
            {
            u8* m = maskField.text();
            if (!self.streq(m, curMask))
                {
                curMask = self.dup(m);
                self.applyMask();
                }
            }
        }
    // A mask matches: "" or "*" -> all; "*suffix" -> name ends with suffix; else -> name starts with mask.
    bool matchMask(u8* mask, u8* name)
        {
        if (mask[(i32)0] == (u8)0)
            {
            return true;
            }
        // "*"
        if (mask[(i32)0] == (u8)42 && mask[(i32)1] == (u8)0)
            {
            return true;
            }
        if (mask[(i32)0] == (u8)42)
            {
            u8* suf = (u8*)&mask[(i32)1];
            i32 sl = self.slen(suf);
            i32 nl = self.slen(name);
            if (nl < sl)
                {
                return false;
                }
            for (i32 k = (i32)0; k < sl; k = k + (i32)1)
                {
                if (name[nl - sl + k] != suf[k])
                    {
                    return false;
                    }
                }
            return true;
            }
        i32 ml = self.slen(mask);
        for (i32 k = (i32)0; k < ml; k = k + (i32)1)
            {
            if (name[k] != mask[k])
                {
                return false;
                }
            }
        return true;
        }
    // rows = allRows with files filtered by the mask (folders always shown).
    void applyMask(void)
        {
        rows = new Array();
        selected = (i32)-1;
        top = (i32)0;
        u8* mask = maskField != (UXTextField*)0 ? maskField.text() : (u8*)"*";
        for (u16 i = (u16)0; i < allRows.count(); i = i + (u16)1)
            {
            UXFileRow* r = (UXFileRow* ?)allRows.get(i);
            // hide dot-entries, but never ".."
            if (!showHidden && self.hidden(r.name) && !self.isDotDot(r.name))
                {
                continue;
                }
            if (r.isDir || self.matchMask(mask, r.name))
                {
                rows.add(r);
                }
            }
        if (list != (UXFileListView*)0)
            {
            list.setNeedsDisplay();
            }
        }
    void onToggleHidden(UXControl* c)
        {
        showHidden = hiddenBox.isChecked();
        self.applyMask();
        }

    // Free the malloc'd names of the current rows (called before a reload so they don't accumulate).
    void freeRows(void)
        {
        for (u16 i = (u16)0; i < allRows.count(); i = i + (u16)1)
            { free((pointer)((UXFileRow* ?)allRows.get(i)).name);
            }
        }
    // Parse one listing line.  New format is "<t>\t<size>\t<name>\n"; tolerate the old "<t> <name>\n"
    // (size 0) so a stale libGEM still lists.  Returns the index just past the line.
    void reload(void)
        {
        self.freeRows();
        allDirs = new Array();
        allFiles = new Array();
        selName = (u8*)"";
        if (selField != (UXTextField*)0)
            {
            selField.setText((u8*)"");
            }
        u8* buf = (u8*)malloc((u32)16384);
        buf[(i32)0] = (u8)0;
        gDriver.listDir(curDir, buf, (i32)16384);
        i32 i = (i32)0;
        while (buf[i] != (u8)0)
            {
            u8 t = buf[i];
            i = i + (i32)1;
            u32 sz = (u32)0;
            // new format: tab, size, tab, name
            if (buf[i] == (u8)9)
                {
                i = i + (i32)1;
                while (buf[i] >= (u8)48 && buf[i] <= (u8)57)
                    {
                    sz = sz * (u32)10 + (u32)(buf[i] - (u8)48);
                    i = i + (i32)1;
                    }
                if (buf[i] == (u8)9)
                    {
                    i = i + (i32)1;
                    }
                }
            // old format: single space
            else if (buf[i] == (u8)32)
                {
                i = i + (i32)1;
                }
            i32 start = i;
            while (buf[i] != (u8)0 && buf[i] != (u8)10)
                {
                i = i + (i32)1;
                }
            i32 len = i - start;
            u8* nm = (u8*)malloc((u32)(len + (i32)1));
            for (i32 k = (i32)0; k < len; k = k + (i32)1)
                {
                nm[k] = buf[start + k];
                }
            nm[len] = (u8)0;
            UXFileRow* r = UXFileRow.make(nm, t == (u8)100, sz);
            if (r.isDir)
                {
                allDirs.add(r);
                }
            else
                {
                allFiles.add(r);
                }
            if (buf[i] == (u8)10)
                {
                i = i + (i32)1;
                }
            }
        free((pointer)buf); // the listing buffer, no longer needed
        // ".." at the top (unless we are at the root) — going up lives in the list, the natural place for it.
        dotRow = self.slen(curDir) > (i32)1 ? UXFileRow.make(self.dup((u8*)".."), true, (u32)0) : (UXFileRow*)0;
        if (pathLabel != (UXLabel*)0)
            {
            pathLabel.setText(curDir);
            }
        self.rebuild();
        }
    // Re-derive allRows from the raw dir/file rows for the current sort, then re-filter.  Cheap enough to
    // call on every header click (no directory re-listing).
    void rebuild(void)
        {
        allRows = new Array();
        // ".." is always pinned to the top
        if (dotRow != (UXFileRow*)0)
            {
            allRows.add(dotRow);
            }
        if (sortKey == (i32)FP_SORT_SIZE)
            {
            // Sorting by size: one pool, directories counting as size 0, so they land where 0 belongs
            // (top ascending, bottom descending) rather than being force-grouped first.
            Array<UXFileRow>* all = new Array();
            for (u16 i = (u16)0; i < allDirs.count(); i = i + (u16)1)
                {
                all.add(allDirs.get(i));
                }
            for (u16 i = (u16)0; i < allFiles.count(); i = i + (u16)1)
                {
                all.add(allFiles.get(i));
                }
            Array<UXFileRow>* s = self.sortedCopy(all);
            for (u16 i = (u16)0; i < s.count(); i = i + (u16)1)
                {
                allRows.add(s.get(i));
                }
            }
        else
            {
            // Sorting by name: folders grouped first, then files, each A->Z / Z->A.
            Array<UXFileRow>* sd = self.sortedCopy(allDirs);
            for (u16 i = (u16)0; i < sd.count(); i = i + (u16)1)
                {
                allRows.add(sd.get(i));
                }
            Array<UXFileRow>* sf = self.sortedCopy(allFiles);
            for (u16 i = (u16)0; i < sf.count(); i = i + (u16)1)
                {
                allRows.add(sf.get(i));
                }
            }
        self.applyMask();
        }
    // A header click: same column flips the direction, a new column selects it (ascending to start).
    void sortBy(i32 key)
        {
        // the Recent view isn't the directory; leave it be
        if (recentsMode)
            {
            return;
            }
        if (key == sortKey)
            {
            sortAsc = !sortAsc;
            }
        else
            {
            sortKey = key;
            sortAsc = true;
            }
        self.rebuild();
        if (header != (UXFileHeader*)0)
            {
            header.setNeedsDisplay();
            }
        }

    u8* join(u8* dir, u8* leaf)
        {
        u8* sep = (dir[(i32)0] == (u8)47 && dir[(i32)1] == (u8)0) ? (u8*)"" : (u8*)"/";
        return UXStr.append(UXStr.append(dir, sep), leaf);
        }
    void enter(u8* name)
        {
        recentsMode = false;
        curDir = self.join(curDir, name);
        self.reload();
        }

    // ---- recents ---------------------------------------------------------------------------------
    // Remember a chosen path: drop any earlier copy, put it at the front, and cap the list.
    void addRecent(u8* path)
        {
        if (gFileRecents == (Array*)0)
            {
            gFileRecents = new Array();
            }
        for (u16 i = (u16)0; i < gFileRecents.count(); i = i + (u16)1)
            {
            if (self.streq(((UXFileRow* ?)gFileRecents.get(i)).name, path))
                {
                gFileRecents.removeAt(i);
                break;
                }
            }
        // Rebuild with the new entry first (Array has no insertAt): stash, clear, re-add.
        Array<UXFileRow>* keep = new Array();
        keep.add(UXFileRow.make(self.dup(path), false, (u32)0));
        for (u16 i = (u16)0; i < gFileRecents.count() && keep.count() < (u16)FP_RECMAX; i = i + (u16)1)
            {
            keep.add(gFileRecents.get(i));
            }
        // evicted tail
        for (u16 i = (u16)FP_RECMAX; i < gFileRecents.count(); i = i + (u16)1)
            { free((pointer)((UXFileRow* ?)gFileRecents.get(i)).name);
            }
        gFileRecents = keep;
        }
    // Swap the list over to the remembered files (or back to the directory when toggled off).
    void showRecents(void)
        {
        recentsMode = true;
        rows = new Array();
        selected = (i32)-1;
        top = (i32)0;
        if (gFileRecents != (Array*)0)
            {
            for (u16 i = (u16)0; i < gFileRecents.count(); i = i + (u16)1)
                {
                rows.add(gFileRecents.get(i));
                }
            }
        if (pathLabel != (UXLabel*)0)
            {
            pathLabel.setText((u8*)"Recent files");
            }
        if (recentBtn != (UXButton*)0)
            {
            recentBtn.setTitle((u8*)"Folder");
            recentBtn.setNeedsDisplay();
            }
        if (list != (UXFileListView*)0)
            {
            list.setNeedsDisplay();
            }
        }
    void onRecent(UXControl* c)
        {
        if (recentsMode)
            {
            recentsMode = false;
            if (recentBtn != (UXButton*)0)
                {
                recentBtn.setTitle((u8*)"Recent");
                recentBtn.setNeedsDisplay();
                }
            self.reload();
            }
        else
            {
            self.showRecents();
            }
        }

    void select(i32 i)
        {
        selected = i;
        selName = self.rowAt(i).name;
        if (selField != (UXTextField*)0)
            {
            selField.setText(selName);
            }
        if (list != (UXFileListView*)0)
            {
            list.setNeedsDisplay();
            }
        }
    bool isDotDot(u8* n)
        {
        return n[(i32)0] == (u8)46 && n[(i32)1] == (u8)46 && n[(i32)2] == (u8)0;
        }
    void rowClicked(i32 i)
        {
        if (i < (i32)0 || i >= self.count())
            {
            return;
            }
        // reopen it
        if (recentsMode)
            {
            chosenPath = self.dup(self.rowAt(i).name);
            result = (i32)1;
            done = true;
            return;
            }
        UXFileRow* r = self.rowAt(i);
        if (!r.isDir)
            {
            self.select(i);
            return;
            }
        if (self.isDotDot(r.name))
            {
            self.goUp();
            }
        else
            {
            self.enter(r.name);
            }
        }

    // ---- the button column -----------------------------------------------------------------------
    // the edited name
    u8* target(void)
        {
        return selField != (UXTextField*)0 ? selField.text() : selName;
        }
    void goUp(void)
        {
        i32 n = self.slen(curDir);
        i32 e = n - (i32)1;
        while (e > (i32)0 && curDir[e] != (u8)47)
            {
            e = e - (i32)1;
            }
        if (e <= (i32)0)
            {
            curDir = (u8*)"/";
            }
        else
            {
            u8* up = (u8*)malloc((u32)(e + (i32)1));
            for (i32 k = (i32)0; k < e; k = k + (i32)1)
                {
                up[k] = curDir[k];
                }
            up[e] = (u8)0;
            curDir = up;
            }
        self.reload();
        }
    void onOpen(UXControl* c)
        {
        if (recentsMode)
            {
            if (selected >= (i32)0)
                {
                chosenPath = self.dup(self.rowAt(selected).name);
                result = (i32)1;
                done = true;
                }
            return;
            }
        if (selected >= (i32)0)
            {
            chosenPath = self.join(curDir, self.target());
            result = (i32)1;
            done = true;
            }
        }
    void onCancel(UXControl* c)
        {
        result = (i32)0;
        done = true;
        }
    // Find: select the first entry whose name starts with the Selection text, scrolling it into view.
    void onFind(UXControl* c)
        {
        u8* q = self.target();
        i32 ml = self.slen(q);
        if (ml == (i32)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            u8* nm = self.rowAt(i).name;
            bool hit = true;
            // prefix
            for (i32 k = (i32)0; k < ml; k = k + (i32)1)
                {
                if (nm[k] != q[k])
                    {
                    hit = false;
                    }
                }
            if (hit)
                {
                selected = i;
                selName = nm;
                top = i;
                self.scrollBy((i32)0);
                list.setNeedsDisplay();
                return;
                }
            }
        }
    void onRename(UXControl* c)
        {
        if (selName[(i32)0] != (u8)0)
            {
            gDriver.fileRename(self.join(curDir, selName), self.join(curDir, self.target()));
            self.reload();
            }
        }
    void onCopy(UXControl* c)
        {
        if (selName[(i32)0] != (u8)0)
            {
            gDriver.fileCopy(self.join(curDir, selName), self.join(curDir, self.target()));
            self.reload();
            }
        }
    void onMove(UXControl* c)
        {
        if (selName[(i32)0] != (u8)0)
            {
            gDriver.fileRename(self.join(curDir, selName), self.join(curDir, self.target()));
            self.reload();
            }
        }
    void onDelete(UXControl* c)
        {
        if (selName[(i32)0] == (u8)0)
            {
            return;
            }
        UXAlert* a = new UXAlert();
        a.icon = (i32)2;
        a.addLine((u8*)"Delete this file?");
        a.addLine(selName);
        a.addButton((u8*)"Delete");
        a.addButton((u8*)"Cancel");
        if (a.runModal() == (i32)1)
            {
            gDriver.fileDelete(self.join(curDir, selName));
            self.reload();
            }
        }

    UXButton* mkBtn(UXView* cv, u8* title, callback act void(UXControl* sender), i16 x, i16 y, i16 w, i16 h)
        {
        UXButton* b = new UXButton();
        b.setTitle(title);
        b.setAction(act);
        cv.addSubview(b, UXGeom.make(x, y, w, h));
        return b;
        }
    // The widget building lives in its own function, and not for tidiness: every UXGeom.make is a
    // struct temporary, and arm64 gives a frame 16KB — one function holding the whole panel sat a
    // few bytes under the limit and broke the moment an unrelated struct grew.  ks_app splits its
    // builders for exactly this reason.
    void buildPanel(UXFilePanelBack* canvas, u8* prompt)
        {
        i16 listW = (i16)316;
        i16 listH = (i16)(FP_ROWS * FP_ROWH); // 316 x 180
        i16 lx0 = (i16)10;
        i16 ly0 = (i16)80; // column-title strip origin (below the 3 header rows)
        i16 colX = (i16)334;
        i16 colW = (i16)100;                             // right column (Recent + Manage group)
        i16 listBot = (i16)(ly0 + (i16)FP_HDRH + listH); // 278 — header+list and group share this baseline
        i16 barY = (i16)(listBot + (i16)12);             // the footer row lives under the list
        win.open(prompt, UXGeom.make((i16)140, (i16)80, (i16)444, (i16)(barY + (i16)40)), canvas);

        // ---- header: Directory, then Mask (+Find), then Selection ------------------------------------
        UXLabel* dl = new UXLabel();
        dl.setText((u8*)"Directory:");
        canvas.addSubview(dl, UXGeom.make((i16)10, (i16)8, (i16)66, (i16)16));
        pathLabel = new UXLabel();
        pathLabel.setText(curDir);
        canvas.addSubview(pathLabel, UXGeom.make((i16)80, (i16)8, (i16)354, (i16)16));
        UXLabel* ml = new UXLabel();
        ml.setText((u8*)"Mask:");
        canvas.addSubview(ml, UXGeom.make((i16)10, (i16)32, (i16)44, (i16)16));
        maskField = new UXTextField();
        maskField.setText((u8*)"*");
        canvas.addSubview(maskField, UXGeom.make((i16)54, (i16)30, (i16)120, (i16)20));
        self.mkBtn(canvas, (u8*)"Find", &self.onFind, (i16)186, (i16)30, (i16)76, (i16)22); // just right of the mask
        UXLabel* sl = new UXLabel();
        sl.setText((u8*)"Selection:");
        canvas.addSubview(sl, UXGeom.make((i16)10, (i16)56, (i16)66, (i16)16));
        selField = new UXTextField();
        selField.setText((u8*)"");
        canvas.addSubview(selField, UXGeom.make((i16)80, (i16)54, (i16)246, (i16)20));

        // ---- the sortable column-title strip, then the list (".." at the top for going up) ------------
        header = new UXFileHeader();
        header.panel = self;
        canvas.addSubview(header, UXGeom.make(lx0, ly0, listW, (i16)FP_HDRH));
        list = new UXFileListView();
        list.panel = self;
        canvas.addSubview(list, UXGeom.make(lx0, (i16)(ly0 + (i16)FP_HDRH), listW, listH));

        // ---- right column: Recent, then a Manage group of the file operations ------------------------
        recentBtn = new UXButton();
        recentBtn.setTitle((u8*)"Recent");
        recentBtn.setAction(&self.onRecent);
        canvas.addSubview(recentBtn, UXGeom.make(colX, ly0, colW, (i16)26));
        i16 grpY = (i16)(ly0 + (i16)38);
        UXGroupBox* grp = new UXGroupBox();
        grp.setTitle((u8*)"Manage");
        canvas.addSubview(grp, UXGeom.make(colX, grpY, colW, (i16)(listBot - grpY)));
        i16 gbx = (i16)(colX + (i16)8);
        i16 gbw = (i16)(colW - (i16)16);
        i16 gb0 = (i16)(grpY + (i16)26);
        self.mkBtn(canvas, (u8*)"Rename", &self.onRename, gbx, (i16)(gb0 + (i16)0), gbw, (i16)24);
        self.mkBtn(canvas, (u8*)"Copy", &self.onCopy, gbx, (i16)(gb0 + (i16)30), gbw, (i16)24);
        self.mkBtn(canvas, (u8*)"Move", &self.onMove, gbx, (i16)(gb0 + (i16)60), gbw, (i16)24);
        self.mkBtn(canvas, (u8*)"Delete", &self.onDelete, gbx, (i16)(gb0 + (i16)90), gbw, (i16)24);

        // ---- footer: Show hidden at the left, Cancel + a prominent Open in the bottom-right corner ----
        hiddenBox = new UXCheckbox();
        hiddenBox.setTitle((u8*)"Show hidden");
        hiddenBox.setAction(&self.onToggleHidden);
        canvas.addSubview(hiddenBox, UXGeom.make((i16)10, (i16)(barY + (i16)4), (i16)130, (i16)18));
        self.mkBtn(canvas, (u8*)"Cancel", &self.onCancel, (i16)248, (i16)(barY + (i16)2), (i16)84, (i16)28);
        self.mkBtn(canvas, (u8*)"Open", &self.onOpen, (i16)344, barY, (i16)90, (i16)30);
        self.reload();
        win.tree.finalise();
        win.displayAll();
        }

    u8* run(u8* prompt, u8* startDir)
        {
        curDir = gFileLastDir != (u8*)0 ? gFileLastDir : startDir; // resume where the last panel closed
        UXFilePanelBack* canvas = new UXFilePanelBack();
        win = new UXWindow();
        self.buildPanel(canvas, prompt);

        UXEvent* ev = new UXEvent();
        while (!done)
            {
            gDriver.nextEvent((i32)0, ev);
            u8 k = ev.kind;
            if (k == (u8)UXEventMouseDown)
                {
                win.dispatchMouse(ev);
                }
            else if (k == (u8)UXEventKeyDown)
                {
                win.dispatchKey(ev);
                }
            else if (k == (u8)UXEventWheel)
                {
                self.scrollBy((i32)ev.a > (i32)0 ? (i32)3 : (i32)-3);
                }
            else if (k == (u8)UXEventClose)
                {
                result = (i32)0;
                done = true;
                }
            else if (k == (u8)UXEventRedraw)
                {
                win.displayAll();
                }
            self.syncMask(); // re-filter if the mask changed
            if (gNeedsDisplay)
                {
                win.display();
                gNeedsDisplay = false;
                }
            }
        win.close();
        // Remember the directory (so the next panel resumes here) and the chosen file (for Recent).
        // Dup FIRST: curDir may alias gFileLastDir (when the user never navigated), so freeing before the
        // copy would read freed memory.
        u8* nd = self.dup(curDir);
        if (gFileLastDir != (u8*)0)
            {
            free((pointer)gFileLastDir);
            }
        gFileLastDir = nd;
        if (result == (i32)1 && chosenPath != (u8*)0)
            {
            self.addRecent(chosenPath);
            }
        return result == (i32)1 ? chosenPath : (u8*)0;
        }
    }
