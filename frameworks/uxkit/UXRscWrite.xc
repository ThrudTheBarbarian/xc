// UXRscWrite.xc — UXRscWriter, the classic GEM .rsc writer, in XC.
//
// The other half of UXRscReader.  Emits a big-endian file with packed coordinates,
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
// run — which is exactly what UXRscDoc.flatten already produces, since it
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
#import "UXRscModel.xc"

#define UXRW_SZ_HDR 36
#define UXRW_SZ_OBJ 24
#define UXRW_SZ_TED 28

class UXRscWriter : Object
    {
    u8* out;
    i32 total;
    i32 unhandled;
    u8* warn;

    // the string pool: interned once, each with the offset it will live at
    Array<UXData>* strs;
    Array<UXRscObject>* allObjs;    // every object, in file order
    Array<UXRscFlatNode>* allLinks; // its links, tree-relative
    Array<UXRscTedinfo>* teds;

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
        // Compare by LENGTH: a stored string is a UXData of its bytes with no terminator after them,
        // so reading one up to a NUL ran on past its end into whatever followed, and a string could
        // fail to match itself.  The template ("____...") did, every time: each TEDINFO interned a
        // new copy beyond the laid-out table, offOf found no offset for it, and te_ptmplt was
        // written as 0 -- every editable field lost its template on the next read.
        i32 n = UXRscWriter.slen(s);
        for (i32 i = (i32)0; i < (i32)strs.count(); i = i + (i32)1)
            {
            UXData* d = (UXData* ?)strs.get((u16)i);
            if (d.length() != n)
                {
                continue;
                }
            u8* b = d.bytes();
            i32 k = (i32)0;
            while (k < n && b[k] == s[k])
                {
                k = k + (i32)1;
                }
            if (k == n)
                {
                return i;
                }
            }
        strs.add(UXData.fromString(s));
        return (i32)strs.count() - (i32)1;
        }

    // ---- the write ---------------------------------------------------------
    static UXData* write(UXRscDoc* r)
        {
        UXRscWriter* w = new UXRscWriter();
        return w.emit(r);
        }
    static UXRscWriter* writer(UXRscDoc* r)
        {
        UXRscWriter* w = new UXRscWriter();
        w.result = w.emit(r);
        return w;
        }
    UXData* result;

    UXData* emit(UXRscDoc* r)
        {
        if (r == (UXRscDoc*)0)
            {
            return (UXData*)0;
            }
        i32 cw = r.charWidth;
        i32 ch = r.charHeight;

        // ---- pass 1: flatten every tree, in file order --------------------
        // Each tree contributes a contiguous run starting at its root, so the
        // run's own indices ARE the tree-relative links the format wants.
        Array<UXRscTree>* treeList = r.trees;
        i32 nobs = (i32)0;
        Array<UXRscFlatNode>* rootAt = new Array(); // one entry per tree: its first object index
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            UXRscTree* tr = r.treeAt(t);
            Array<UXRscFlatNode>* fl = r.flatten(tr);
            UXRscFlatNode* mark = new UXRscFlatNode();
            mark.next = nobs; // where this tree starts
            rootAt.add(mark);
            for (i32 i = (i32)0; i < (i32)fl.count(); i = i + (i32)1)
                {
                UXRscFlatNode* n = (UXRscFlatNode* ?)fl.get((u16)i);
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
            UXRscObject* o = (UXRscObject* ?)allObjs.get((u16)i);
            if (o.hasStringSpec())
                {
                self.intern(o.text);
                }
            else if (o.hasTedinfo() && o.ted != (UXRscTedinfo*)0)
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
        i32 objBase = (i32)UXRW_SZ_HDR;
        i32 tedBase = objBase + nobs * (i32)UXRW_SZ_OBJ;
        i32 ibBase = tedBase + nted * (i32)UXRW_SZ_TED;
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
        Array<UXRscFlatNode>* strOff = new Array();
        i32 cur = strBase;
        for (i32 i = (i32)0; i < (i32)strs.count(); i = i + (i32)1)
            {
            UXData* d = (UXData* ?)strs.get((u16)i);
            UXRscFlatNode* mark = new UXRscFlatNode();
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
            UXRscObject* o = (UXRscObject* ?)allObjs.get((u16)i);
            UXRscFlatNode* fl = (UXRscFlatNode* ?)allLinks.get((u16)i);
            i32 d = objBase + i * (i32)UXRW_SZ_OBJ;
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
            UXRscTedinfo* ti = (UXRscTedinfo* ?)teds.get((u16)i);
            i32 d = tedBase + i * (i32)UXRW_SZ_TED;
            self.wr32(d + (i32)0, self.offOf(strOff, self.intern(ti.text)));
            self.wr32(d + (i32)4, self.offOf(strOff, self.intern(ti.tmplt)));
            self.wr32(d + (i32)8, self.offOf(strOff, self.intern(ti.valid)));
            self.wr16(d + (i32)12, ti.font);
            self.wr16(d + (i32)14, ti.fontId);
            self.wr16(d + (i32)16, ti.just);
            self.wr16(d + (i32)18, (i32)ti.color.pack());
            self.wr16(d + (i32)20, ti.fontsize);
            self.wr16(d + (i32)22, ti.thickness);
            self.wr16(d + (i32)24, UXRscWriter.slen(ti.text) + (i32)1);
            self.wr16(d + (i32)26, UXRscWriter.slen(ti.tmplt) + (i32)1);
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
            i32 first = ((UXRscFlatNode* ?)rootAt.get((u16)t)).next;
            self.wr32(trindex + t * (i32)4, objBase + first * (i32)UXRW_SZ_OBJ);
            }

        if (unhandled > (i32)0)
            {
            warn = (u8*)"this resource holds payloads this build cannot write (icons / bit forms); they are not in the output";
            }
        UXData* file = UXData.fromBytes(out, total);
        if (r.formCount() > (i32)0 || r.classOverrides.count() > (u32)0 || r.topObjects.count() > (u32)0 ||
            r.connections.count() > (u32)0 || r.extSections.count() > (u32)0 || UXRscWriter.namesSection(r) != (UXData*)0 ||
            (r.ownerClass != (u8*)0 && r.ownerClass[0] != (u8)0) || r.attrs.count() > (u32)0)
            {
            file.appendData(self.nibChunk(r));
            }
        return file;
        }

    // ---- the UXNB v3 chunk (docs/UXNB-V2.md sections 2 and 11) -----------------
    // Written only when the document has layout variants or a nib graph, so a plain resource stays
    // byte-for-byte classic.  It sits at rsh_rssize, past everything a classic AES reads: there, every variant is
    // just another tree.  Forms first -- each multi-variant form, then every tree in no form as a
    // single-variant `any` form under its own index (in a v2 file only the form list finds a tree)
    // -- then one map per variant tree, object index (pre-order, as the tree is written) to logical
    // id.  Then the graph: class overrides, top objects, scoped connections, the extension sections
    // as they were read.  No presentations yet: nothing authors them.
    static void be16(UXData* d, i32 v)
        {
        d.appendByte((u8)((v >> (i32)8) & (i32)$FF));
        d.appendByte((u8)(v & (i32)$FF));
        }
    static void be32(UXData* d, i32 v)
        {
        UXRscWriter.be16(d, (v >> (i32)16) & (i32)$FFFF);
        UXRscWriter.be16(d, v & (i32)$FFFF);
        }
    // A string into the blob; "" (and null) is offset 0, which the blob starts with.
    static i32 blobAdd(UXData* blob, u8* s)
        {
        if (s == (u8*)0 || s[0] == (u8)0)
            {
            return (i32)0;
            }
        i32 at = blob.length();
        blob.appendBytes(s, UXRscWriter.slen(s));
        blob.appendByte((u8)0);
        return at;
        }
    static void ref(UXData* d, UXRscRef* r)
        {
        d.appendByte((u8)(r != (UXRscRef*)0 ? r.space : (i32)UXR_REF_OWNER));
        UXRscWriter.be16(d, r != (UXRscRef*)0 ? r.a : (i32)0);
        UXRscWriter.be16(d, r != (UXRscRef*)0 ? r.b : (i32)0);
        d.appendByte((u8)0);
        }
    // The NAME section (see UXRscReader.readNames), or 0 when nothing has a name.  The classic file
    // stores no names, so without it a tree's or a control's name would not survive a save.
    static UXData* namesSection(UXRscDoc* r)
        {
        UXData* d = UXData.withCapacity((i32)64);
        UXRscWriter.be16(d, (i32)0); // count, patched below
        i32 n = (i32)0;
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            UXRscTree* tr = r.treeAt(t);
            if (tr.name != (u8*)0 && tr.name[0] != (u8)0)
                {
                UXRscWriter.nameEntry(d, t, (i32)$FFFF, tr.name);
                n = n + (i32)1;
                }
            Array<UXRscObject>* all = tr.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                u8* nm = ((UXRscObject* ?)all.get(k)).name;
                if (nm != (u8*)0 && nm[0] != (u8)0)
                    {
                    UXRscWriter.nameEntry(d, t, (i32)k, nm);
                    n = n + (i32)1;
                    }
                }
            }
        if (n == (i32)0)
            {
            return (UXData*)0;
            }
        u8* b = d.bytes();
        b[0] = (u8)((n >> (i32)8) & (i32)$FF);
        b[1] = (u8)(n & (i32)$FF);
        return d;
        }
    static void lenStr(UXData* d, u8* s)
        {
        i32 n = UXRscWriter.slen(s);
        UXRscWriter.be16(d, n);
        d.appendBytes(s, n);
        }
    static void nameEntry(UXData* d, i32 tree, i32 obj, u8* nm)
        {
        i32 nl = UXRscWriter.slen(nm);
        UXRscWriter.be16(d, tree);
        UXRscWriter.be16(d, obj);
        UXRscWriter.be16(d, nl);
        d.appendBytes(nm, nl);
        }
    UXData* nibChunk(UXRscDoc* r)
        {
        // the string blob: offset 0 is "", then each form's name
        UXData* blob = UXData.withCapacity((i32)64);
        blob.appendByte((u8)0);
        Array<UXRscFlatNode>* nameAt = new Array(); // per form, its name's blob offset
        for (i32 f = (i32)0; f < r.formCount(); f = f + (i32)1)
            {
            UXRscFlatNode* m = new UXRscFlatNode();
            m.next = blob.length();
            nameAt.add(m);
            u8* nm = r.formAt(f).name;
            if (nm != (u8*)0)
                {
                blob.appendBytes(nm, UXRscWriter.slen(nm));
                }
            blob.appendByte((u8)0);
            }
        i32 nLoose = (i32)0;
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            if (r.formOf(r.treeAt(t)) == (UXRscForm*)0)
                {
                nLoose = nLoose + (i32)1;
                }
            }
        // the maps: every tree with at least one identified control (a form's layouts, and a tree in
        // no form whose controls are wired or classed by logical id)
        i32 nMaps = (i32)0;
        UXData* maps = UXData.withCapacity((i32)64);
        for (i32 f = (i32)0; f < r.treeCount(); f = f + (i32)1)
            {
            UXRscTree* tr = r.treeAt(f);
            Array<UXRscObject>* all = tr.allObjects();
            i32 ne = (i32)0;
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                if (((UXRscObject* ?)all.get(k)).logicalId != (i32)0)
                    {
                    ne = ne + (i32)1;
                    }
                }
            if (ne == (i32)0)
                {
                continue;
                }
            UXRscWriter.be16(maps, r.indexOfTree(tr));
            UXRscWriter.be16(maps, ne);
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                i32 id = ((UXRscObject* ?)all.get(k)).logicalId;
                if (id != (i32)0)
                    {
                    UXRscWriter.be16(maps, (i32)k);
                    UXRscWriter.be16(maps, id);
                    }
                }
            nMaps = nMaps + (i32)1;
            }

        // the graph, strings into the same blob
        UXData* graph = UXData.withCapacity((i32)128);
        for (u32 i = (u32)0; i < r.classOverrides.count(); i = i + (u32)1)
            {
            UXRscClassOverride* co = (UXRscClassOverride* ?)r.classOverrides.get(i);
            UXRscWriter.ref(graph, co.view);
            UXRscWriter.be32(graph, UXRscWriter.blobAdd(blob, co.cls));
            }
        for (u32 i = (u32)0; i < r.topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* to = (UXRscTopObject* ?)r.topObjects.get(i);
            UXRscWriter.be16(graph, to.id);
            UXRscWriter.be32(graph, UXRscWriter.blobAdd(blob, to.cls));
            UXRscWriter.be32(graph, UXRscWriter.blobAdd(blob, to.label));
            }
        for (u32 i = (u32)0; i < r.connections.count(); i = i + (u32)1)
            {
            UXRscConnection* cn = (UXRscConnection* ?)r.connections.get(i);
            graph.appendByte((u8)cn.kind);
            graph.appendByte((u8)0);
            UXRscWriter.ref(graph, cn.src);
            UXRscWriter.ref(graph, cn.dst);
            UXRscWriter.be32(graph, UXRscWriter.blobAdd(blob, cn.member));
            UXRscWriter.be32(graph, (i32)cn.scope);
            }
        UXData* names = UXRscWriter.namesSection(r);
        i32 nExt = (i32)r.extSections.count();
        if (names != (UXData*)0)
            {
            UXRscWriter.be32(graph, (i32)$4E414D45); // 'NAME'
            UXRscWriter.be32(graph, names.length());
            graph.appendBytes(names.bytes(), names.length());
            if ((names.length() & (i32)1) != (i32)0)
                {
                graph.appendByte((u8)0);
                }
            nExt = nExt + (i32)1;
            }
        if (r.attrs.count() > (u32)0)
            {
            UXData* at = UXData.withCapacity((i32)64);
            UXRscWriter.be16(at, (i32)r.attrs.count());
            for (u32 i = (u32)0; i < r.attrs.count(); i = i + (u32)1)
                {
                UXRscAttr* a = (UXRscAttr* ?)r.attrs.get(i);
                UXRscWriter.be16(at, a.formId);
                UXRscWriter.be16(at, a.logicalId);
                UXRscWriter.be16(at, a.theme);
                UXRscWriter.lenStr(at, a.key);
                UXRscWriter.lenStr(at, a.value);
                }
            UXRscWriter.be32(graph, (i32)$41545452); // 'ATTR'
            UXRscWriter.be32(graph, at.length());
            graph.appendBytes(at.bytes(), at.length());
            if ((at.length() & (i32)1) != (i32)0)
                {
                graph.appendByte((u8)0);
                }
            nExt = nExt + (i32)1;
            }
        if (r.ownerClass != (u8*)0 && r.ownerClass[0] != (u8)0)
            {
            i32 ol = UXRscWriter.slen(r.ownerClass);
            UXRscWriter.be32(graph, (i32)$4F574E52); // 'OWNR'
            UXRscWriter.be32(graph, ol);
            graph.appendBytes(r.ownerClass, ol);
            if ((ol & (i32)1) != (i32)0)
                {
                graph.appendByte((u8)0);
                }
            nExt = nExt + (i32)1;
            }
        for (u32 i = (u32)0; i < r.extSections.count(); i = i + (u32)1)
            {
            UXRscExtSection* x = (UXRscExtSection* ?)r.extSections.get(i);
            UXRscWriter.be32(graph, (i32)x.tag);
            UXRscWriter.be32(graph, x.body.length());
            graph.appendBytes(x.body.bytes(), x.body.length());
            if ((x.body.length() & (i32)1) != (i32)0)
                {
                graph.appendByte((u8)0);
                }
            }

        UXData* c = UXData.withCapacity((i32)256);
        UXRscWriter.be32(c, (i32)$55584E42); // 'UXNB'
        UXRscWriter.be16(c, (i32)3);         // version
        UXRscWriter.be16(c, (i32)0);         // flags
        UXRscWriter.be32(c, (i32)0);         // size, patched below
        UXRscWriter.be16(c, (i32)r.classOverrides.count());
        UXRscWriter.be16(c, (i32)r.topObjects.count());
        UXRscWriter.be16(c, (i32)r.connections.count());
        UXRscWriter.be16(c, r.formCount() + nLoose);
        UXRscWriter.be16(c, nMaps);
        UXRscWriter.be16(c, (i32)0); // nPres
        UXRscWriter.be16(c, nExt);
        UXRscWriter.be16(c, (i32)0); // _pad
        for (i32 f = (i32)0; f < r.formCount(); f = f + (i32)1)
            {
            UXRscForm* fm = r.formAt(f);
            UXRscWriter.be16(c, fm.formId);
            UXRscWriter.be32(c, ((UXRscFlatNode* ?)nameAt.get((u32)f)).next);
            UXRscWriter.be16(c, fm.variantCount());
            UXRscWriter.be16(c, (i32)0);
            for (i32 v = (i32)0; v < fm.variantCount(); v = v + (i32)1)
                {
                UXRscVariant* va = fm.variantAt(v);
                UXRscWriter.be16(c, (va.klass & (i32)$3FFF) | ((va.orient & (i32)3) << (i32)14));
                UXRscWriter.be16(c, r.indexOfTree(va.tree));
                }
            }
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            if (r.formOf(r.treeAt(t)) == (UXRscForm*)0)
                {
                UXRscWriter.be16(c, t);
                UXRscWriter.be32(c, (i32)0); // unnamed
                UXRscWriter.be16(c, (i32)1);
                UXRscWriter.be16(c, (i32)0);
                UXRscWriter.be16(c, (i32)UXR_V_ANY);
                UXRscWriter.be16(c, t);
                }
            }
        c.appendData(maps);
        c.appendData(graph);
        c.appendData(blob);
        i32 n = c.length();
        u8* b = c.bytes();
        b[8] = (u8)((n >> (i32)24) & (i32)$FF);
        b[9] = (u8)((n >> (i32)16) & (i32)$FF);
        b[10] = (u8)((n >> (i32)8) & (i32)$FF);
        b[11] = (u8)(n & (i32)$FF);
        return c;
        }

    i32 offOf(Array<UXRscFlatNode>* strOff, i32 idx)
        {
        if (idx < (i32)0 || idx >= (i32)strOff.count())
            {
            return (i32)0;
            }
        return ((UXRscFlatNode* ?)strOff.get((u16)idx)).next;
        }

    // ob_spec, per type — the mirror of the reader's readSpec.
    i32 specFor(UXRscObject* o, Array<UXRscFlatNode>* strOff, i32 tedBase)
        {
        if (o.hasBox())
            {
            UXRscBox* b = o.box;
            if (b == (UXRscBox*)0)
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
                if ((UXRscTedinfo* ?)teds.get((u16)i) == o.ted)
                    {
                    return tedBase + i * (i32)UXRW_SZ_TED;
                    }
                }
            }
        return (i32)0;
        }
    }
