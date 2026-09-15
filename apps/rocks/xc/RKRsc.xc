// RKRsc.xc — the classic GEM .rsc reader, in XC.
//
// Ported from src/rsc.c (portable C, shared with the XT GEM desktop).  Why a
// port rather than binding that C: xcc compiles .xc, and Rocks has to build
// for every target UXKit runs on — a C dependency would pin the editor to
// whatever platforms happen to have a C toolchain, which defeats the point of
// writing it in XC at all.
//
// That does mean a second implementation of the format, which is exactly the
// thing this project keeps trying to avoid.  Two mitigations: it is the ONLY
// XC one, and it deliberately has no dependency on anything else in Rocks, so
// it can be PROMOTED INTO UXKit later.  UXKit wants it — UXNibV2 already parses
// the RSHDR and the chunk in XC, while v1 nib loading still leans on libGEM's C
// rscload and is GEM-only for exactly that reason.  Moving this file up would
// close that gap and stop a third implementation ever being written.
//
// AN IMPORT MUST NEVER BE SILENTLY LOSSY.  Payloads this slice does not yet
// preserve (icons, bit forms, palettes) are counted and reported through
// warning(), so a file that came in carrying more than we understood says so
// rather than quietly dropping it on the way back out.
#import "Array.xc"
#import "UXData.xc"
#import "RKModel.xc"

#define RK_SZ_HDR 36 // 18 words
#define RK_SZ_OBJ 24
#define RK_SZ_TED 28

class RKRsc : Object
    {
    u8* buf;
    i32 len;
    bool be; // the file's byte order (big-endian = classic)
    i32 cellW, cellH;
    i32 unhandled; // payloads seen but not yet preserved
    u8* warn;
    RKResource* result; // what reader() parsed — a field, see reader()
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
        result = (RKResource*)0;
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
    static RKResource* read(u8* bytes, i32 n)
        {
        RKRsc* r = new RKRsc();
        RKResource* out = r.tryParse(bytes, n, true);
        if (out == (RKResource*)0)
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
    static RKRsc* reader(u8* bytes, i32 n)
        {
        RKRsc* r = new RKRsc();
        RKResource* res = r.tryParse(bytes, n, true);
        if (res == (RKResource*)0)
            {
            res = r.tryParse(bytes, n, false);
            }
        r.result = res;
        return r;
        }

    RKResource* tryParse(u8* bytes, i32 n, bool bigEndian)
        {
        buf = bytes;
        len = n;
        be = bigEndian;
        unhandled = (i32)0;
        warn = (u8*)0;
        if (n < (i32)RK_SZ_HDR)
            {
            return (RKResource*)0;
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
            return (RKResource*)0;
            }
        if (ntree < (i32)0 || ntree > (i32)2000)
            {
            return (RKResource*)0;
            }
        if (ntree == (i32)0 && nstr <= (i32)0 && nimg <= (i32)0)
            {
            return (RKResource*)0;
            }
        if (nobs > (i32)0)
            {
            if (objBase < (i32)RK_SZ_HDR || objBase >= n)
                {
                return (RKResource*)0;
                }
            if (objBase + nobs * (i32)RK_SZ_OBJ > n)
                {
                return (RKResource*)0;
                }
            }
        if (ntree > (i32)0 && trindex + ntree * (i32)4 > n)
            {
            return (RKResource*)0;
            }
        if (rssize != (i32)0 && rssize != n && rssize < objBase)
            {
            return (RKResource*)0;
            }

        RKResource* res = new RKResource();
        res.bigEndian = bigEndian;
        nobjects = nobs;

        // ---- the flat OBJECT array ----------------------------------------
        Array<RKObject>* flat = new Array();
        Array<RKFlatNode>* links = new Array();
        for (i32 i = (i32)0; i < nobs; i = i + (i32)1)
            {
            i32 o = objBase + i * (i32)RK_SZ_OBJ;
            RKObject* g = new RKObject();
            RKFlatNode* fl = new RKFlatNode();
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
            // file said it was ours — see RKObject's two fields for why that
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
            i32 idx = (rootOff - objBase) / (i32)RK_SZ_OBJ;
            if (idx < (i32)0 || idx >= nobs)
                {
                continue;
                }
            self.attachChildren(flat, links, idx, idx, nobs);
            RKTree* tr = new RKTree();
            tr.root = (RKObject* ?)flat.get((u16)idx);
            tr.name = (u8*)"";
            tr.kind = tr.root.type == (i32)RKT_BOX && self.looksLikeMenu(tr.root)
                          ? (i32)RKK_MENU
                          : (i32)RKK_DIALOG;
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
            return (RKResource*)0;
            }
        return res;
        }

    // Attach one object's children, then theirs.  `base` is the tree root's
    // index in the flat array: every link is added to it to reach the real
    // object.  Guarded against a malformed file looping forever — an editor
    // that hangs on a bad resource is worse than one that reads it partially.
    void attachChildren(Array<RKObject>* flat, Array<RKFlatNode>* links,
                        i32 base, i32 absIdx, i32 nobs)
        {
        RKFlatNode* fl = (RKFlatNode* ?)links.get((u16)absIdx);
        if (fl.head < (i32)0)
            {
            return;
            }
        RKObject* parent = (RKObject* ?)flat.get((u16)absIdx);
        i32 c = fl.head;
        i32 guard = (i32)0;
        while (c >= (i32)0 && guard <= nobs)
            {
            i32 childAbs = base + c;
            if (childAbs < (i32)0 || childAbs >= nobs)
                {
                return;
                }
            parent.addChild((RKObject* ?)flat.get((u16)childAbs));
            self.attachChildren(flat, links, base, childAbs, nobs);
            if (c == fl.tail)
                {
                c = (i32)-1;
                }
            else
                { c = ((RKFlatNode* ?)links.get((u16)childAbs)).next;
                }
            guard = guard + (i32)1;
            }
        }

    // A menu tree's root box holds a bar of G_TITLEs.
    bool looksLikeMenu(RKObject* root)
        {
        if (root.childCount() < (i32)1)
            {
            return false;
            }
        RKObject* bar = root.childAt((i32)0);
        for (i32 i = (i32)0; i < bar.childCount(); i = i + (i32)1)
            {
            if (bar.childAt(i).type == (i32)RKT_TITLE)
                {
                return true;
                }
            }
        return false;
        }

    // ob_spec means something different per type: an inline colour word for a
    // box, a string offset for the string-ish types, a TEDINFO for the
    // editable ones.  Anything else is counted rather than guessed at.
    void readSpec(RKObject* g, i32 spec)
        {
        i32 t = g.type;
        if (t == (i32)RKT_BOX || t == (i32)RKT_IBOX || t == (i32)RKT_BOXCHAR)
            {
            RKBox* b = new RKBox();
            b.character = (u8)((spec >> (i32)24) & (i32)$FF);
            b.thickness = (spec >> (i32)16) & (i32)$FF;
            if (b.thickness >= (i32)128)
                {
                b.thickness = b.thickness - (i32)256;
                }
            b.color = RKColor.unpack((u16)(spec & (i32)$FFFF));
            g.box = b;
            return;
            }
        if (t == (i32)RKT_STRING || t == (i32)RKT_BUTTON || t == (i32)RKT_TITLE ||
            t == (i32)RKT_CHECKBOX || t == (i32)RKT_RADIO || t == (i32)RKT_POPUP)
            {
            g.text = self.cstrAt(spec);
            return;
            }
        if (t == (i32)RKT_TEXT || t == (i32)RKT_BOXTEXT ||
            t == (i32)RKT_FTEXT || t == (i32)RKT_FBOXTEXT || t == (i32)RKT_FIELD)
            {
            RKTedinfo* ti = new RKTedinfo();
            if (spec > (i32)0 && spec + (i32)RK_SZ_TED <= len)
                {
                ti.text = self.cstrAt(self.rd32(spec + (i32)0));
                ti.tmplt = self.cstrAt(self.rd32(spec + (i32)4));
                ti.valid = self.cstrAt(self.rd32(spec + (i32)8));
                ti.font = self.rd16s(spec + (i32)12);
                ti.fontId = self.rd16s(spec + (i32)14);
                ti.just = self.rd16s(spec + (i32)16);
                ti.color = RKColor.unpack((u16)self.rd16(spec + (i32)18));
                ti.fontsize = self.rd16s(spec + (i32)20);
                ti.thickness = self.rd16s(spec + (i32)22);
                }
            g.ted = ti;
            return;
            }
        if (t == (i32)RKT_ICON || t == (i32)RKT_CICON || t == (i32)RKT_CICONBLK ||
            t == (i32)RKT_IMAGE)
            {
            unhandled = unhandled + (i32)1; // counted, never silently dropped
            }
        }
    }
