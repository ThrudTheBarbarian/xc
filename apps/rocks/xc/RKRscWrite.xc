// RKRscWrite.xc — the classic GEM .rsc writer, in XC.
//
// The other half of RKRsc.  Emits a big-endian file with packed coordinates,
// so the tools that wrote the resources we read (Interface, ORCS, WERCS, RCS)
// can read ours back.
//
// The section order is the classic one, and every base is computed before a
// byte is written because the header has to carry them all:
//
//     hdr(36) objects tedinfo iconblk bitblk frstr frimg trindex strings images
//
// TREE-RELATIVE LINKS, again.  Each tree's objects are written contiguously
// starting with its root, and ob_next/ob_head/ob_tail are indices within that
// run — which is exactly what RKResource.flatten already produces, since it
// numbers from each tree's own root.  The tree index then points at the root's
// absolute byte offset.  Getting this wrong is invisible in a one-tree file
// and corrupts every later tree, which is the bug the reader hit from the
// other direction.
//
// AN EXPORT MUST NEVER BE SILENTLY LOSSY, the mirror of the reader's rule:
// payloads this slice cannot write (icons, bit forms) are counted and reported
// through warning() rather than dropped quietly.
#import "Array.xc"
#import "UXData.xc"
#import "RKModel.xc"

#define RKW_SZ_HDR 36
#define RKW_SZ_OBJ 24
#define RKW_SZ_TED 28

class RKRscWrite : Object
    {
    u8* out;
    i32 total;
    i32 unhandled;
    u8* warn;

    // the string pool: interned once, each with the offset it will live at
    Array<UXData>* strs;
    Array<RKObject>* allObjs;    // every object, in file order
    Array<RKFlatNode>* allLinks; // its links, tree-relative
    Array<RKTedinfo>* teds;

    void init(void)
        {
        out = (u8*)0;
        total = (i32)0;
        unhandled = (i32)0;
        warn = (u8*)0;
        strs = new Array();
        allObjs = new Array();
        allLinks = new Array();
        teds = new Array();
        }

    u8* warning(void)
        {
        return warn;
        }
    bool wasLossless(void)
        {
        return unhandled == (i32)0;
        }

    // ---- little helpers ----------------------------------------------------
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static bool seq(u8* a, u8* b)
        {
        if (a == (u8*)0)
            {
            a = (u8*)"";
            }
        if (b == (u8*)0)
            {
            b = (u8*)"";
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
    void wr16(i32 off, i32 v)
        {
        if (off < (i32)0 || off + (i32)1 >= total)
            {
            return;
            }
        out[off] = (u8)((v >> (i32)8) & (i32)$FF);
        out[off + (i32)1] = (u8)(v & (i32)$FF);
        }
    void wr32(i32 off, i32 v)
        {
        if (off < (i32)0 || off + (i32)3 >= total)
            {
            return;
            }
        out[off] = (u8)((v >> (i32)24) & (i32)$FF);
        out[off + (i32)1] = (u8)((v >> (i32)16) & (i32)$FF);
        out[off + (i32)2] = (u8)((v >> (i32)8) & (i32)$FF);
        out[off + (i32)3] = (u8)(v & (i32)$FF);
        }
    // characters in the low byte, the signed pixel remainder in the high byte
    i32 packCoord(i32 px, i32 cell)
        {
        if (cell <= (i32)0)
            {
            cell = (i32)8;
            }
        i32 chars = px / cell;
        i32 extra = px - chars * cell;
        return ((extra & (i32)$FF) << (i32)8) | (chars & (i32)$FF);
        }

    // Intern a string, returning its index in the pool.
    i32 intern(u8* s)
        {
        if (s == (u8*)0)
            {
            s = (u8*)"";
            }
        for (i32 i = (i32)0; i < (i32)strs.count(); i = i + (i32)1)
            {
            UXData* d = (UXData* ?)strs.get((u16)i);
            if (RKRscWrite.seq(d.bytes(), s))
                {
                return i;
                }
            }
        strs.add(UXData.fromString(s));
        return (i32)strs.count() - (i32)1;
        }

    // ---- the write ---------------------------------------------------------
    static UXData* write(RKResource* r)
        {
        RKRscWrite* w = new RKRscWrite();
        return w.emit(r);
        }
    static RKRscWrite* writer(RKResource* r)
        {
        RKRscWrite* w = new RKRscWrite();
        w.result = w.emit(r);
        return w;
        }
    UXData* result;

    UXData* emit(RKResource* r)
        {
        if (r == (RKResource*)0)
            {
            return (UXData*)0;
            }
        i32 cw = r.charWidth;
        i32 ch = r.charHeight;

        // ---- pass 1: flatten every tree, in file order --------------------
        // Each tree contributes a contiguous run starting at its root, so the
        // run's own indices ARE the tree-relative links the format wants.
        Array<RKTree>* treeList = r.trees;
        i32 nobs = (i32)0;
        Array<RKFlatNode>* rootAt = new Array(); // one entry per tree: its first object index
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            RKTree* tr = r.treeAt(t);
            Array<RKFlatNode>* fl = r.flatten(tr);
            RKFlatNode* mark = new RKFlatNode();
            mark.next = nobs; // where this tree starts
            rootAt.add(mark);
            for (i32 i = (i32)0; i < (i32)fl.count(); i = i + (i32)1)
                {
                RKFlatNode* n = (RKFlatNode* ?)fl.get((u16)i);
                allObjs.add(n.obj);
                allLinks.add(n);
                nobs = nobs + (i32)1;
                }
            }

        // ---- pass 2: intern everything that lands in the string pool -------
        // Order matters: the layout below hands out one offset per interned
        // string, so anything interned afterwards would get no offset at all.
        for (i32 i = (i32)0; i < (i32)r.freeStrings.count(); i = i + (i32)1)
            {
            self.intern(((UXData* ?)r.freeStrings.get((u16)i)).bytes());
            }
        for (i32 i = (i32)0; i < nobs; i = i + (i32)1)
            {
            RKObject* o = (RKObject* ?)allObjs.get((u16)i);
            if (o.hasStringSpec())
                {
                self.intern(o.text);
                }
            else if (o.hasTedinfo() && o.ted != (RKTedinfo*)0)
                {
                self.intern(o.ted.text);
                self.intern(o.ted.tmplt);
                self.intern(o.ted.valid);
                teds.add(o.ted);
                }
            else if (o.hasIcon() || o.hasBitblk())
                {
                unhandled = unhandled + (i32)1;
                }
            }

        // ---- the layout ----------------------------------------------------
        i32 nted = (i32)teds.count();
        i32 nstring = (i32)r.freeStrings.count();
        i32 ntree = r.treeCount();
        i32 objBase = (i32)RKW_SZ_HDR;
        i32 tedBase = objBase + nobs * (i32)RKW_SZ_OBJ;
        i32 ibBase = tedBase + nted * (i32)RKW_SZ_TED;
        i32 bbBase = ibBase; // no iconblks in this slice
        i32 frstr = bbBase;  // no bitblks either
        i32 frimg = frstr + nstring * (i32)4;
        i32 trindex = frimg; // no free images
        i32 strBase = trindex + ntree * (i32)4;

        i32 strbytes = (i32)0;
        for (i32 i = (i32)0; i < (i32)strs.count(); i = i + (i32)1)
            {
            strbytes = strbytes + (i32)((UXData* ?)strs.get((u16)i)).length() + (i32)1;
            }
        i32 imBase = strBase + strbytes;
        total = imBase; // no image data in this slice

        out = new u8[(u32)(total > (i32)0 ? total : (i32)1)];
        for (i32 i = (i32)0; i < total; i = i + (i32)1)
            {
            out[i] = (u8)0;
            }

        // ---- header --------------------------------------------------------
        self.wr16((i32)0, (i32)0); // rsh_vrsn: plain classic, not extended
        self.wr16((i32)2, objBase);
        self.wr16((i32)4, tedBase);
        self.wr16((i32)6, ibBase);
        self.wr16((i32)8, bbBase);
        self.wr16((i32)10, frstr);
        self.wr16((i32)12, strBase);
        self.wr16((i32)14, imBase);
        self.wr16((i32)16, frimg);
        self.wr16((i32)18, trindex);
        self.wr16((i32)20, nobs);
        self.wr16((i32)22, ntree);
        self.wr16((i32)24, nted);
        self.wr16((i32)26, (i32)0); // nib
        self.wr16((i32)28, (i32)0); // nbb
        self.wr16((i32)30, nstring);
        self.wr16((i32)32, (i32)0); // nimages
        self.wr16((i32)34, total);  // rsh_rssize

        // ---- string data, and the offset each one landed at ----------------
        Array<RKFlatNode>* strOff = new Array();
        i32 cur = strBase;
        for (i32 i = (i32)0; i < (i32)strs.count(); i = i + (i32)1)
            {
            UXData* d = (UXData* ?)strs.get((u16)i);
            RKFlatNode* mark = new RKFlatNode();
            mark.next = cur;
            strOff.add(mark);
            for (i32 k = (i32)0; k < d.length(); k = k + (i32)1)
                {
                out[cur + k] = d.byteAt(k);
                }
            out[cur + d.length()] = (u8)0;
            cur = cur + d.length() + (i32)1;
            }

        // ---- objects -------------------------------------------------------
        for (i32 i = (i32)0; i < nobs; i = i + (i32)1)
            {
            RKObject* o = (RKObject* ?)allObjs.get((u16)i);
            RKFlatNode* fl = (RKFlatNode* ?)allLinks.get((u16)i);
            i32 d = objBase + i * (i32)RKW_SZ_OBJ;
            self.wr16(d + (i32)0, fl.next & (i32)$FFFF);
            self.wr16(d + (i32)2, fl.head & (i32)$FFFF);
            self.wr16(d + (i32)4, fl.tail & (i32)$FFFF);
            // the high byte carries whichever extended meaning this object had
            i32 hi = o.extType != (u8)0 ? (i32)o.extType : (i32)o.legacyExtType;
            self.wr16(d + (i32)6, (hi << (i32)8) | (o.type & (i32)$FF));
            self.wr16(d + (i32)8, o.flags);
            self.wr16(d + (i32)10, o.state);
            self.wr32(d + (i32)12, self.specFor(o, strOff, tedBase));
            self.wr16(d + (i32)16, self.packCoord(o.x, cw));
            self.wr16(d + (i32)18, self.packCoord(o.y, ch));
            self.wr16(d + (i32)20, self.packCoord(o.w, cw));
            self.wr16(d + (i32)22, self.packCoord(o.h, ch));
            }

        // ---- tedinfo -------------------------------------------------------
        for (i32 i = (i32)0; i < nted; i = i + (i32)1)
            {
            RKTedinfo* ti = (RKTedinfo* ?)teds.get((u16)i);
            i32 d = tedBase + i * (i32)RKW_SZ_TED;
            self.wr32(d + (i32)0, self.offOf(strOff, self.intern(ti.text)));
            self.wr32(d + (i32)4, self.offOf(strOff, self.intern(ti.tmplt)));
            self.wr32(d + (i32)8, self.offOf(strOff, self.intern(ti.valid)));
            self.wr16(d + (i32)12, ti.font);
            self.wr16(d + (i32)14, ti.fontId);
            self.wr16(d + (i32)16, ti.just);
            self.wr16(d + (i32)18, (i32)ti.color.pack());
            self.wr16(d + (i32)20, ti.fontsize);
            self.wr16(d + (i32)22, ti.thickness);
            self.wr16(d + (i32)24, RKRscWrite.slen(ti.text) + (i32)1);
            self.wr16(d + (i32)26, RKRscWrite.slen(ti.tmplt) + (i32)1);
            }

        // ---- free string table ---------------------------------------------
        for (i32 i = (i32)0; i < nstring; i = i + (i32)1)
            {
            u8* s = ((UXData* ?)r.freeStrings.get((u16)i)).bytes();
            self.wr32(frstr + i * (i32)4, self.offOf(strOff, self.intern(s)));
            }

        // ---- tree index: each root's absolute byte offset -------------------
        for (i32 t = (i32)0; t < ntree; t = t + (i32)1)
            {
            i32 first = ((RKFlatNode* ?)rootAt.get((u16)t)).next;
            self.wr32(trindex + t * (i32)4, objBase + first * (i32)RKW_SZ_OBJ);
            }

        if (unhandled > (i32)0)
            {
            warn = (u8*)"this resource holds payloads this build cannot write (icons / bit forms); they are not in the output";
            }
        return UXData.fromBytes(out, total);
        }

    i32 offOf(Array<RKFlatNode>* strOff, i32 idx)
        {
        if (idx < (i32)0 || idx >= (i32)strOff.count())
            {
            return (i32)0;
            }
        return ((RKFlatNode* ?)strOff.get((u16)idx)).next;
        }

    // ob_spec, per type — the mirror of the reader's readSpec.
    i32 specFor(RKObject* o, Array<RKFlatNode>* strOff, i32 tedBase)
        {
        if (o.hasBox())
            {
            RKBox* b = o.box;
            if (b == (RKBox*)0)
                {
                return (i32)0;
                }
            i32 th = b.thickness;
            if (th < (i32)0)
                {
                th = th + (i32)256;
                }
            return (((i32)b.character & (i32)$FF) << (i32)24) |
                   ((th & (i32)$FF) << (i32)16) | (i32)b.color.pack();
            }
        if (o.hasStringSpec())
            {
            return self.offOf(strOff, self.intern(o.text));
            }
        if (o.hasTedinfo())
            {
            for (i32 i = (i32)0; i < (i32)teds.count(); i = i + (i32)1)
                {
                if ((RKTedinfo* ?)teds.get((u16)i) == o.ted)
                    {
                    return tedBase + i * (i32)RKW_SZ_TED;
                    }
                }
            }
        return (i32)0;
        }
    }
