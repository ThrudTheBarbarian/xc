// UXRscRead.xc — UXRscReader, the classic GEM .rsc reader, in XC, and the nib chunk after it.
//
// Ported from src/rsc.c (portable C, shared with the XT GEM desktop) for Rocks, and moved into
// UXKit so the nib loader and the designer read a file the same way, on every backend: xcc
// compiles .xc, and a C dependency (libGEM's rscload, which the v1 loader used) pinned nib
// loading to GEM.
//
// AN IMPORT MUST NEVER BE SILENTLY LOSSY.  Payloads this slice does not yet
// preserve (icons, bit forms, palettes) are counted and reported through
// warning(), so a file that came in carrying more than we understood says so
// rather than quietly dropping it on the way back out.
#import "Array.xc"
#import "UXData.xc"
#import "UXRscModel.xc"

#define UXR_SZ_HDR 36 // 18 words
#define UXR_SZ_OBJ 24
#define UXR_SZ_TED 28

class UXRscReader : Object
    {
    u8* buf;
    i32 len;
    bool be; // the file's byte order (big-endian = classic)
    i32 cellW, cellH;
    i32 unhandled; // payloads seen but not yet preserved
    u8* warn;
    UXRscDoc* result; // what reader() parsed — a field, see reader()
    i32 nobjects;       // the header's object count, for cross-checking

    void init(void)
        {
        buf = (u8*)0;
        len = (i32)0;
        be = true;
        cellW = (i32)8;
        cellH = (i32)16;
        unhandled = (i32)0;
        warn = (u8*)0;
        result = (UXRscDoc*)0;
        nobjects = (i32)0;
        }

    // ---- byte order --------------------------------------------------------
    i32 rd16(i32 off)
        {
        if (off < (i32)0 || off + (i32)1 >= len)
            {
            return (i32)0;
            }
        i32 a = (i32)buf[off];
        i32 b = (i32)buf[off + (i32)1];
        return be ? ((a << (i32)8) | b) : ((b << (i32)8) | a);
        }
    // the same, as a SIGNED 16-bit value (coordinates and links are signed)
    i32 rd16s(i32 off)
        {
        i32 v = self.rd16(off);
        return v >= (i32)32768 ? v - (i32)65536 : v;
        }
    i32 rd32(i32 off)
        {
        if (off < (i32)0 || off + (i32)3 >= len)
            {
            return (i32)0;
            }
        i32 a = (i32)buf[off];
        i32 b = (i32)buf[off + (i32)1];
        i32 c = (i32)buf[off + (i32)2];
        i32 d = (i32)buf[off + (i32)3];
        if (be)
            {
            return (a << (i32)24) | (b << (i32)16) | (c << (i32)8) | d;
            }
        return (d << (i32)24) | (c << (i32)16) | (b << (i32)8) | a;
        }

    // A coordinate is packed as characters in the low byte and a SIGNED pixel
    // remainder in the high byte — so the same file lays out correctly on
    // systems with different cell sizes.
    i32 unpackCoord(i32 raw, i32 cell)
        {
        i32 lo = raw & (i32)$FF;
        i32 hi = (raw >> (i32)8) & (i32)$FF;
        // signed
        if (hi >= (i32)128)
            {
            hi = hi - (i32)256;
            }
        return lo * cell + hi;
        }

    // A NUL-terminated Latin-1 string living at `off` in the file.
    u8* cstrAt(i32 off)
        {
        if (off <= (i32)0 || off >= len)
            {
            return (u8*)"";
            }
        i32 n = (i32)0;
        while (off + n < len && buf[off + n] != (u8)0)
            {
            n = n + (i32)1;
            }
        u8* s = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            s[i] = buf[off + i];
            }
        s[n] = (u8)0;
        return s;
        }

    u8* warning(void)
        {
        return warn;
        }
    bool wasLossless(void)
        {
        return unhandled == (i32)0;
        }

    // ---- the parse ---------------------------------------------------------
    // Tries big-endian first (the classic Atari order), then little-endian,
    // because real files in the wild are both.
    static UXRscDoc* read(u8* bytes, i32 n)
        {
        UXRscReader* r = new UXRscReader();
        UXRscDoc* out = r.tryParse(bytes, n, true);
        if (out == (UXRscDoc*)0)
            {
            out = r.tryParse(bytes, n, false);
            }
        return out;
        }
    // The same, keeping the reader so the caller can ask about losses.  The
    // result is a FIELD rather than an out-parameter: writing an object
    // pointer through a `T**` does not retain it, so the callee's local dies
    // with the call and the caller is left holding memory that survives only
    // until the next allocation reuses it.  A field is an ordinary strong
    // reference and ARC tracks it.  (Primitive out-params — `boot(&w,&h)` —
    // are fine; it is object ones that bite.)
    static UXRscReader* reader(u8* bytes, i32 n)
        {
        UXRscReader* r = new UXRscReader();
        UXRscDoc* res = r.tryParse(bytes, n, true);
        if (res == (UXRscDoc*)0)
            {
            res = r.tryParse(bytes, n, false);
            }
        r.result = res;
        return r;
        }

    UXRscDoc* tryParse(u8* bytes, i32 n, bool bigEndian)
        {
        buf = bytes;
        len = n;
        be = bigEndian;
        unhandled = (i32)0;
        warn = (u8*)0;
        if (n < (i32)UXR_SZ_HDR)
            {
            return (UXRscDoc*)0;
            }

        i32 objBase = self.rd16((i32)1 * (i32)2);
        i32 trindex = self.rd16((i32)9 * (i32)2);
        i32 nobs = self.rd16((i32)10 * (i32)2);
        i32 ntree = self.rd16((i32)11 * (i32)2);
        i32 nstr = self.rd16s((i32)15 * (i32)2);
        i32 nimg = self.rd16s((i32)16 * (i32)2);
        i32 rssize = self.rd16((i32)17 * (i32)2);

        // Sanity, in the same order the C does it.  A cursor/image bank
        // (EmuTOS's mform.rsc) has NO trees at all — accept that, as long as
        // the file carries something.
        if (nobs < (i32)0 || nobs > (i32)8000)
            {
            return (UXRscDoc*)0;
            }
        if (ntree < (i32)0 || ntree > (i32)2000)
            {
            return (UXRscDoc*)0;
            }
        if (ntree == (i32)0 && nstr <= (i32)0 && nimg <= (i32)0)
            {
            return (UXRscDoc*)0;
            }
        if (nobs > (i32)0)
            {
            if (objBase < (i32)UXR_SZ_HDR || objBase >= n)
                {
                return (UXRscDoc*)0;
                }
            if (objBase + nobs * (i32)UXR_SZ_OBJ > n)
                {
                return (UXRscDoc*)0;
                }
            }
        if (ntree > (i32)0 && trindex + ntree * (i32)4 > n)
            {
            return (UXRscDoc*)0;
            }
        if (rssize != (i32)0 && rssize != n && rssize < objBase)
            {
            return (UXRscDoc*)0;
            }

        UXRscDoc* res = new UXRscDoc();
        res.bigEndian = bigEndian;
        nobjects = nobs;

        // ---- the flat OBJECT array ----------------------------------------
        Array<UXRscObject>* flat = new Array();
        Array<UXRscFlatNode>* links = new Array();
        for (i32 i = (i32)0; i < nobs; i = i + (i32)1)
            {
            i32 o = objBase + i * (i32)UXR_SZ_OBJ;
            UXRscObject* g = new UXRscObject();
            UXRscFlatNode* fl = new UXRscFlatNode();
            fl.next = self.rd16s(o + (i32)0);
            fl.head = self.rd16s(o + (i32)2);
            fl.tail = self.rd16s(o + (i32)4);
            i32 rawType = self.rd16(o + (i32)6);
            g.type = rawType & (i32)$FF;
            g.flags = self.rd16(o + (i32)8);
            g.state = self.rd16(o + (i32)10);
            i32 spec = self.rd32(o + (i32)12);
            g.x = self.unpackCoord(self.rd16(o + (i32)16), cellW);
            g.y = self.unpackCoord(self.rd16(o + (i32)18), cellH);
            g.w = self.unpackCoord(self.rd16(o + (i32)20), cellW);
            g.h = self.unpackCoord(self.rd16(o + (i32)22), cellH);
            // The ob_type high byte is someone else's extended type unless the
            // file said it was ours — see UXRscObject's two fields for why that
            // distinction has to be kept.
            g.legacyExtType = (u8)((rawType >> (i32)8) & (i32)$FF);
            self.readSpec(g, spec);
            g.seedPayload();
            fl.obj = g;
            flat.add(g);
            links.add(fl);
            }

        // ---- the tree index, and the nesting -------------------------------
        // ob_next/ob_head/ob_tail are indices RELATIVE TO THE TREE'S ROOT, not
        // into the file's flat array — because the AES hands an app a pointer
        // to the tree's first object (rsrc_gaddr(R_TREE, i)) and every link is
        // an offset from there.  Missing that reads correctly for the FIRST
        // tree, whose root is at index 0 so relative and absolute coincide,
        // and silently mis-links every tree after it.  The nesting is
        // therefore rebuilt per tree, from its own root, never globally.
        for (i32 t = (i32)0; t < ntree; t = t + (i32)1)
            {
            i32 rootOff = self.rd32(trindex + t * (i32)4);
            i32 idx = (rootOff - objBase) / (i32)UXR_SZ_OBJ;
            if (idx < (i32)0 || idx >= nobs)
                {
                continue;
                }
            self.attachChildren(flat, links, idx, idx, nobs);
            UXRscTree* tr = new UXRscTree();
            tr.root = (UXRscObject* ?)flat.get((u16)idx);
            tr.name = (u8*)"";
            tr.kind = tr.root.type == (i32)UXR_T_BOX && self.looksLikeMenu(tr.root)
                          ? (i32)UXR_K_MENU
                          : (i32)UXR_K_DIALOG;
            res.addTree(tr);
            }

        // ---- free strings: rsrc_gaddr(R_STRING, i) -------------------------
        i32 frstr = self.rd16((i32)5 * (i32)2);
        if (nstr > (i32)0 && frstr > (i32)0)
            {
            for (i32 i = (i32)0; i < nstr; i = i + (i32)1)
                {
                i32 off = self.rd32(frstr + i * (i32)4);
                res.freeStrings.add(UXData.fromString(self.cstrAt(off)));
                }
            }
        // Free images are a table of BITBLKs; not preserved in this slice, but
        // counted so the import cannot be silently lossy.
        if (nimg > (i32)0)
            {
            unhandled = unhandled + nimg;
            }

        if (unhandled > (i32)0)
            {
            warn = (u8*)"this file carries payloads this build does not preserve (icons / bit forms); re-export would lose them";
            }
        // Reject only if nothing worth having came out.
        if (res.treeCount() == (i32)0 && res.freeStrings.count() == (u16)0)
            {
            return (UXRscDoc*)0;
            }
        if (be && rssize >= (i32)UXR_SZ_HDR)
            {
            self.readNibV2(res, rssize);
            }
        return res;
        }

    // The nib chunk at rsh_rssize, if there is one (docs/UXNB-V2.md): v1 ('XGNB'), v2 or v3
    // ('UXNB').  It carries the forms with more than one layout, each layout tree's logical ids,
    // and the nib graph: class overrides, top objects, connections (v3: scoped), v3's extension
    // sections.  Single-variant `any` forms are the writer's listing of standalone trees and come
    // back as just that.  The chunk is big-endian whatever the classic part is, and is ignored
    // (not an error) when malformed: the classic trees are all there either way.
    void readNibV2(UXRscDoc* res, i32 at)
        {
        if (at + (i32)20 > len)
            {
            return;
            }
        i32 magic = self.rd32(at);
        i32 ver = self.rd16(at + (i32)4);
        bool v1 = magic == (i32)$58474E42 && ver == (i32)1;
        if (!v1 && !(magic == (i32)$55584E42 && (ver == (i32)2 || ver == (i32)3)))
            {
            return;
            }
        i32 end = at + self.rd32(at + (i32)8);
        if (end > len)
            {
            return;
            }
        i32 nClasses = self.rd16(at + (i32)12);
        i32 nObjects = self.rd16(at + (i32)14);
        i32 nConns = self.rd16(at + (i32)16);
        i32 nForms = v1 ? (i32)0 : self.rd16(at + (i32)18);
        i32 nMaps = v1 ? (i32)0 : self.rd16(at + (i32)20);
        i32 nPres = v1 ? (i32)0 : self.rd16(at + (i32)22);
        i32 nExt = ver >= (i32)3 ? self.rd16(at + (i32)24) : (i32)0;
        i32 topStride = ver >= (i32)3 ? (i32)10 : (i32)6;
        i32 connStride = ver >= (i32)3 ? (i32)22 : (i32)18;
        i32 p = at + (v1 ? (i32)20 : ver >= (i32)3 ? (i32)28 : (i32)24);
        // the blob comes after every section; find it by walking them
        i32 q = p;
        for (i32 f = (i32)0; f < nForms && q + (i32)10 <= end; f = f + (i32)1)
            {
            q = q + (i32)10 + self.rd16(q + (i32)6) * (i32)4;
            }
        i32 mapsAt = q;
        for (i32 m = (i32)0; m < nMaps && q + (i32)4 <= end; m = m + (i32)1)
            {
            q = q + (i32)4 + self.rd16(q + (i32)2) * (i32)4;
            }
        i32 classAt = q;
        i32 topAt = classAt + nClasses * (i32)10;
        i32 connAt = topAt + nObjects * topStride;
        q = connAt + nConns * connStride;
        for (i32 i = (i32)0; i < nPres && q + (i32)8 <= end; i = i + (i32)1)
            {
            q = q + (i32)8 + self.rd16(q + (i32)2) * (i32)4;
            }
        i32 extAt = q;
        for (i32 e = (i32)0; e < nExt && q + (i32)8 <= end; e = e + (i32)1)
            {
            q = q + (i32)8 + ((self.rd32(q + (i32)4) + (i32)1) & (i32)-2);
            }
        i32 blob = q;
        if (blob > end)
            {
            return;
            }
        // forms
        for (i32 f = (i32)0; f < nForms && p + (i32)10 <= end; f = f + (i32)1)
            {
            i32 formId = self.rd16(p);
            i32 nameOff = self.rd32(p + (i32)2);
            i32 nVar = self.rd16(p + (i32)6);
            bool loose = nVar == (i32)1 && self.rd16(p + (i32)10) == (i32)UXR_V_ANY && self.rd16(p + (i32)12) == formId;
            if (!loose)
                {
                UXRscForm* fm = new UXRscForm();
                fm.formId = formId;
                fm.name = nameOff > (i32)0 && blob + nameOff < end ? self.cstrAt(blob + nameOff) : (u8*)"";
                for (i32 v = (i32)0; v < nVar; v = v + (i32)1)
                    {
                    i32 word = self.rd16(p + (i32)10 + v * (i32)4);
                    i32 tree = self.rd16(p + (i32)12 + v * (i32)4);
                    if (tree < res.treeCount())
                        {
                        UXRscVariant* va = new UXRscVariant();
                        va.klass = word & (i32)$3FFF;
                        va.orient = (word >> (i32)14) & (i32)3;
                        va.tree = res.treeAt(tree);
                        if (va.tree.name == (u8*)0 || va.tree.name[0] == (u8)0)
                            {
                            // the form's own layout keeps its name; the others are named after it
                            if (va.klass == (i32)UXR_V_DESKTOP && va.orient == (i32)UXR_V_ORIENT_NONE)
                                {
                                va.tree.name = fm.name;
                                }
                            else
                                {
                                va.tree.setNameJoined(fm.name, UXRscDoc.variantSuffix(va.klass, va.orient));
                                }
                            }
                        fm.variants.add(va);
                        }
                    }
                res.forms.add(fm);
                }
            p = p + (i32)10 + nVar * (i32)4;
            }
        // maps: each tree's logical ids, by pre-order index
        q = mapsAt;
        for (i32 m = (i32)0; m < nMaps && q + (i32)4 <= end; m = m + (i32)1)
            {
            i32 tree = self.rd16(q);
            i32 ne = self.rd16(q + (i32)2);
            if (tree < res.treeCount())
                {
                Array<UXRscObject>* all = res.treeAt(tree).allObjects();
                for (i32 e = (i32)0; e < ne; e = e + (i32)1)
                    {
                    i32 obj = self.rd16(q + (i32)4 + e * (i32)4);
                    if (obj < (i32)all.count())
                        {
                        ((UXRscObject* ?)all.get((u32)obj)).logicalId = self.rd16(q + (i32)6 + e * (i32)4);
                        }
                    }
                }
            q = q + (i32)4 + ne * (i32)4;
            }
        // the nib graph
        for (i32 i = (i32)0; i < nClasses; i = i + (i32)1)
            {
            i32 r = classAt + i * (i32)10;
            UXRscClassOverride* co = new UXRscClassOverride();
            co.view = self.refAt(r);
            co.cls = self.blobStr(blob, end, self.rd32(r + (i32)6));
            res.classOverrides.add(co);
            }
        for (i32 i = (i32)0; i < nObjects; i = i + (i32)1)
            {
            i32 r = topAt + i * topStride;
            UXRscTopObject* to = new UXRscTopObject();
            to.id = self.rd16(r);
            to.cls = self.blobStr(blob, end, self.rd32(r + (i32)2));
            to.label = ver >= (i32)3 ? self.blobStr(blob, end, self.rd32(r + (i32)6)) : (u8*)"";
            res.topObjects.add(to);
            }
        for (i32 i = (i32)0; i < nConns; i = i + (i32)1)
            {
            i32 r = connAt + i * connStride;
            UXRscConnection* c = new UXRscConnection();
            c.kind = (i32)buf[r];
            c.src = self.refAt(r + (i32)2);
            c.dst = self.refAt(r + (i32)8);
            c.member = self.blobStr(blob, end, self.rd32(r + (i32)14));
            c.scope = ver >= (i32)3 ? (u32)self.rd32(r + (i32)18) : (u32)0;
            res.connections.add(c);
            }
        q = extAt;
        for (i32 e = (i32)0; e < nExt && q + (i32)8 <= end; e = e + (i32)1)
            {
            i32 size = self.rd32(q + (i32)4);
            if (size < (i32)0 || q + (i32)8 + size > end)
                {
                break;
                }
            if (self.rd32(q) == (i32)$4E414D45) // 'NAME': the trees' and objects' names
                {
                self.readNames(res, q + (i32)8, q + (i32)8 + size);
                }
            else
                {
                UXRscExtSection* x = new UXRscExtSection();
                x.tag = (u32)self.rd32(q);
                x.body = UXData.fromBytes(&buf[q + (i32)8], size);
                res.extSections.add(x);
                }
            q = q + (i32)8 + ((size + (i32)1) & (i32)-2);
            }
        }

    // The NAME section: { count u16, then count x { tree u16, obj u16, len u16, bytes[len] } },
    // obj $FFFF naming the tree itself and otherwise an object's pre-order index.
    void readNames(UXRscDoc* res, i32 p, i32 end)
        {
        i32 n = self.rd16(p);
        p = p + (i32)2;
        for (i32 i = (i32)0; i < n && p + (i32)6 <= end; i = i + (i32)1)
            {
            i32 tree = self.rd16(p);
            i32 obj = self.rd16(p + (i32)2);
            i32 nl = self.rd16(p + (i32)4);
            p = p + (i32)6;
            if (p + nl > end)
                {
                return;
                }
            u8* nm = new u8[(u32)(nl + (i32)1)];
            for (i32 k = (i32)0; k < nl; k = k + (i32)1)
                {
                nm[k] = buf[p + k];
                }
            nm[nl] = (u8)0;
            p = p + nl;
            if (tree >= res.treeCount())
                {
                continue;
                }
            UXRscTree* t = res.treeAt(tree);
            if (obj == (i32)$FFFF)
                {
                t.name = nm;
                }
            else
                {
                Array<UXRscObject>* all = t.allObjects();
                if (obj < (i32)all.count())
                    { ((UXRscObject* ?)all.get((u32)obj)).name = nm;
                    }
                }
            }
        }

    // A 6-byte Ref {space u8, a u16, b u16, _pad u8}.
    UXRscRef* refAt(i32 r)
        {
        return UXRscRef.make((i32)buf[r], self.rd16(r + (i32)1), self.rd16(r + (i32)3));
        }
    u8* blobStr(i32 blob, i32 end, i32 off)
        {
        return off > (i32)0 && blob + off < end ? self.cstrAt(blob + off) : (u8*)"";
        }

    // Attach one object's children, then theirs.  `base` is the tree root's
    // index in the flat array: every link is added to it to reach the real
    // object.  Guarded against a malformed file looping forever — an editor
    // that hangs on a bad resource is worse than one that reads it partially.
    void attachChildren(Array<UXRscObject>* flat, Array<UXRscFlatNode>* links,
                        i32 base, i32 absIdx, i32 nobs)
        {
        UXRscFlatNode* fl = (UXRscFlatNode* ?)links.get((u16)absIdx);
        if (fl.head < (i32)0)
            {
            return;
            }
        UXRscObject* parent = (UXRscObject* ?)flat.get((u16)absIdx);
        i32 c = fl.head;
        i32 guard = (i32)0;
        while (c >= (i32)0 && guard <= nobs)
            {
            i32 childAbs = base + c;
            if (childAbs < (i32)0 || childAbs >= nobs)
                {
                return;
                }
            parent.addChild((UXRscObject* ?)flat.get((u16)childAbs));
            self.attachChildren(flat, links, base, childAbs, nobs);
            if (c == fl.tail)
                {
                c = (i32)-1;
                }
            else
                { c = ((UXRscFlatNode* ?)links.get((u16)childAbs)).next;
                }
            guard = guard + (i32)1;
            }
        }

    // A menu tree's root box holds a bar of G_TITLEs.
    bool looksLikeMenu(UXRscObject* root)
        {
        if (root.childCount() < (i32)1)
            {
            return false;
            }
        UXRscObject* bar = root.childAt((i32)0);
        for (i32 i = (i32)0; i < bar.childCount(); i = i + (i32)1)
            {
            if (bar.childAt(i).type == (i32)UXR_T_TITLE)
                {
                return true;
                }
            }
        return false;
        }

    // ob_spec means something different per type: an inline colour word for a
    // box, a string offset for the string-ish types, a TEDINFO for the
    // editable ones.  Anything else is counted rather than guessed at.
    void readSpec(UXRscObject* g, i32 spec)
        {
        i32 t = g.type;
        if (t == (i32)UXR_T_BOX || t == (i32)UXR_T_IBOX || t == (i32)UXR_T_BOXCHAR)
            {
            UXRscBox* b = new UXRscBox();
            b.character = (u8)((spec >> (i32)24) & (i32)$FF);
            b.thickness = (spec >> (i32)16) & (i32)$FF;
            if (b.thickness >= (i32)128)
                {
                b.thickness = b.thickness - (i32)256;
                }
            b.color = UXRscColor.unpack((u16)(spec & (i32)$FFFF));
            g.box = b;
            return;
            }
        if (t == (i32)UXR_T_STRING || t == (i32)UXR_T_BUTTON || t == (i32)UXR_T_TITLE ||
            t == (i32)UXR_T_CHECKBOX || t == (i32)UXR_T_RADIO || t == (i32)UXR_T_POPUP)
            {
            g.text = self.cstrAt(spec);
            return;
            }
        if (t == (i32)UXR_T_TEXT || t == (i32)UXR_T_BOXTEXT ||
            t == (i32)UXR_T_FTEXT || t == (i32)UXR_T_FBOXTEXT || t == (i32)UXR_T_FIELD)
            {
            UXRscTedinfo* ti = new UXRscTedinfo();
            if (spec > (i32)0 && spec + (i32)UXR_SZ_TED <= len)
                {
                ti.text = self.cstrAt(self.rd32(spec + (i32)0));
                ti.tmplt = self.cstrAt(self.rd32(spec + (i32)4));
                ti.valid = self.cstrAt(self.rd32(spec + (i32)8));
                ti.font = self.rd16s(spec + (i32)12);
                ti.fontId = self.rd16s(spec + (i32)14);
                ti.just = self.rd16s(spec + (i32)16);
                ti.color = UXRscColor.unpack((u16)self.rd16(spec + (i32)18));
                ti.fontsize = self.rd16s(spec + (i32)20);
                ti.thickness = self.rd16s(spec + (i32)22);
                }
            g.ted = ti;
            return;
            }
        if (t == (i32)UXR_T_ICON || t == (i32)UXR_T_CICON || t == (i32)UXR_T_CICONBLK ||
            t == (i32)UXR_T_IMAGE)
            {
            unhandled = unhandled + (i32)1; // counted, never silently dropped
            }
        }
    }
