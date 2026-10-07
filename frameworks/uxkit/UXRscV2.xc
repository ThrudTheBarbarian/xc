// UXRscV2.xc — the UXNB v2 and v3 chunk, parsed in xc (docs/UXNB-V2.md; v3 is its §11).
//
// v1's chunk is read by libGEM's C rscload (UXRsc.xc declares that surface), which
// makes v1 rsc loading GEM-only.  v2 is parsed HERE, from the raw .rsc bytes, with
// no host dependency at all — which is what lets variant selection, logical-id
// resolution and validation run (and be gated) on every backend, wasm32 included.
// The split is clean because the magics differ: a v2 file ('UXNB') is invisible to
// the C v1 reader, and a v1 file ('XGNB') is reported by THIS parser as version 1
// and presented per the spec's compatibility rule — every tree its own
// single-variant form of class `any`.
//
// The parser BORROWS the caller's buffer: every u8* it hands back (class names,
// member names) points into that buffer, valid only while the caller keeps it.
// All multi-byte fields are big-endian, matching the .rsc body.
#import "UXViewDriver.xc" // the UX_FORM_* registry
#import "UXLibc.xc"

// Record sizes, from the spec (§2/§3/§5).  A Ref is 6 bytes {space u8, a u16,
// b u16, _pad u8}; spaces: 0 view-by-coordinate, 1 top-level, 2 owner,
// 3 first-responder (reserved), 4 view-by-logical-id {formId, logicalId}.
#define UXNB_REF_VIEW 0
#define UXNB_REF_TOP 1
#define UXNB_REF_OWNER 2
#define UXNB_REF_FIRSTR 3
#define UXNB_REF_LOGICAL 4

#define UXNB_CONN_OUTLET 0
#define UXNB_CONN_ACTION 1

class UXRscV2
    {
    u8* buf; // the whole .rsc image (borrowed)
    u32 len;
    i32 ver;   // 1, 2 or 3
    u32 chunk; // offset of the shell (at rsh_rssize)
    u32 body;  // offset of the first count word
    // section counts
    i32 nClasses;
    i32 nObjects;
    i32 nConns;
    i32 nForms;
    i32 nMaps;
    i32 nPres;
    i32 nExt; // v3 extension sections
    // section offsets (absolute into buf)
    u32 offForms;
    u32 offMaps;
    u32 offClassov;
    u32 offTopobj;
    u32 offConns;
    u32 offPres;
    u32 offExt;
    u32 offBlob;

    void init(void)
        {
        buf = (u8*)0;
        }

    // ---- big-endian readers --------------------------------------------------
    u32 rdU16(u32 at)
        {
        return ((u32)buf[at] << (u32)8) | (u32)buf[at + (u32)1];
        }
    u32 rdU32(u32 at)
        {
        return ((u32)buf[at] << (u32)24) | ((u32)buf[at + (u32)1] << (u32)16) | ((u32)buf[at + (u32)2] << (u32)8) | (u32)buf[at + (u32)3];
        }

    // ---- open ----------------------------------------------------------------
    // The chunk sits at rsh_rssize (RSHDR word 17 — the classic total-size word),
    // exactly where the v1 spec put it: a classic AES reads by header offsets and
    // never looks past it.  Returns null when there is no rsc chunk at all.
    static UXRscV2* open(u8* rsc, u32 rscLen)
        {
        if (rsc == (u8*)0 || rscLen < (u32)48)
            {
            return (UXRscV2*)0;
            }
        UXRscV2* n = new UXRscV2();
        n.buf = rsc;
        n.len = rscLen;
        u32 rssize = n.rdU16((u32)34);
        if (rssize + (u32)12 > rscLen)
            {
            return (UXRscV2*)0;
            }
        n.chunk = rssize;
        u32 magic = n.rdU32(rssize);
        i32 v = (i32)n.rdU16(rssize + (u32)4);
        // 'UXNB' — v2 native
        if (magic == (u32)$55584E42)
            {
            // "serialised by a newer" -> refuse loudly
            if (v != (i32)2 && v != (i32)3)
                {
                return (UXRscV2*)0;
                }
            n.ver = v;
            }
        // 'XGNB' — the v1 magic, read as v1
        else if (magic == (u32)$58474E42)
            {
            if (v != (i32)1)
                {
                return (UXRscV2*)0;
                }
            n.ver = (i32)1;
            }
        else
            {
            return (UXRscV2*)0;
            }
        n.body = rssize + (u32)12;
        return n.parse() ? n : (UXRscV2*)0;
        }

    bool parse(void)
        {
        u32 at = body;
        nClasses = (i32)self.rdU16(at);
        at = at + (u32)2;
        nObjects = (i32)self.rdU16(at);
        at = at + (u32)2;
        nConns = (i32)self.rdU16(at);
        at = at + (u32)2;
        if (ver == (i32)1)
            {
            // v1 body: counts + _pad, then the three fixed-stride sections.
            at = at + (u32)2; // _pad
            nForms = (i32)0;
            nMaps = (i32)0;
            nPres = (i32)0;
            nExt = (i32)0;
            offForms = at;
            offMaps = at;
            }
        else
            {
            nForms = (i32)self.rdU16(at);
            at = at + (u32)2;
            nMaps = (i32)self.rdU16(at);
            at = at + (u32)2;
            nPres = (i32)self.rdU16(at);
            at = at + (u32)2;
            nExt = (i32)0;
            if (ver >= (i32)3)
                {
                nExt = (i32)self.rdU16(at);
                at = at + (u32)4; // nExt, _pad
                }
            // forms are variable-length: {formId, name, nVar, _pad} + nVar*(class, tree)
            offForms = at;
            for (i32 f = (i32)0; f < nForms; f = f + (i32)1)
                {
                u32 nv = self.rdU16(at + (u32)6);
                at = at + (u32)10 + nv * (u32)4;
                }
            // maps too: {tree, nEntries} + nEntries*(obj, logicalId)
            offMaps = at;
            for (i32 m = (i32)0; m < nMaps; m = m + (i32)1)
                {
                u32 ne = self.rdU16(at + (u32)2);
                at = at + (u32)4 + ne * (u32)4;
                }
            }
        offClassov = at;
        at = at + (u32)nClasses * (u32)10;
        offTopobj = at;
        at = at + (u32)nObjects * self.topStride();
        offConns = at;
        at = at + (u32)nConns * self.connStride();
        offPres = at;
        if (ver >= (i32)2)
            {
            for (i32 p = (i32)0; p < nPres; p = p + (i32)1)
                {
                u32 nr = self.rdU16(at + (u32)2);
                at = at + (u32)8 + nr * (u32)4;
                }
            }
        offExt = at;
        for (i32 e = (i32)0; e < nExt && at + (u32)8 <= len; e = e + (i32)1)
            {
            at = at + (u32)8 + ((self.rdU32(at + (u32)4) + (u32)1) & (u32)$FFFFFFFE);
            }
        offBlob = at;
        return at <= len;
        }

    i32 version(void)
        {
        return ver;
        }
    // v3 widened two records: a top object gained its label, a connection its scope.
    u32 topStride(void)
        {
        return ver >= (i32)3 ? (u32)10 : (u32)6;
        }
    u32 connStride(void)
        {
        return ver >= (i32)3 ? (u32)22 : (u32)18;
        }
    // 0 = "" by construction
    u8* str(u32 off)
        {
        return &buf[offBlob + off];
        }

    // ---- forms and variants --------------------------------------------------
    i32 formCount(void)
        {
        return nForms;
        }
    // offset of form record f
    u32 formAt(i32 f)
        {
        u32 at = offForms;
        for (i32 i = (i32)0; i < f; i = i + (i32)1)
            {
            at = at + (u32)10 + self.rdU16(at + (u32)6) * (u32)4;
            }
        return at;
        }
    // or 0 = not found
    u32 formOffById(i32 formId)
        {
        u32 at = offForms;
        for (i32 i = (i32)0; i < nForms; i = i + (i32)1)
            {
            if ((i32)self.rdU16(at) == formId)
                {
                return at;
                }
            at = at + (u32)10 + self.rdU16(at + (u32)6) * (u32)4;
            }
        return (u32)0;
        }
    u8* formName(i32 formId)
        {
        u32 at = self.formOffById(formId);
        return at != (u32)0 ? self.str(self.rdU32(at + (u32)2)) : (u8*)0;
        }

    // The §1 fallback chains: own class first, nearest-larger before
    // nearest-smaller, `any` last.  Writes the class that actually won into
    // chosenClass (the rscVariantClass answer); returns the tree index or -1.
    i32 chainAt(i32 klass, i32 step)
        {
        return UXRscV2.chain(klass, step);
        }
    static i32 chain(i32 klass, i32 step)
        {
        if (klass == (i32)UX_FORM_PHONE)
            {
            if (step == (i32)0)
                {
                return (i32)UX_FORM_PHONE;
                }
            if (step == (i32)1)
                {
                return (i32)UX_FORM_TABLET;
                }
            if (step == (i32)2)
                {
                return (i32)UX_FORM_DESKTOP;
                }
            return (i32)UX_FORM_ANY;
            }
        if (klass == (i32)UX_FORM_TABLET)
            {
            if (step == (i32)0)
                {
                return (i32)UX_FORM_TABLET;
                }
            if (step == (i32)1)
                {
                return (i32)UX_FORM_DESKTOP;
                }
            if (step == (i32)2)
                {
                return (i32)UX_FORM_PHONE;
                }
            return (i32)UX_FORM_ANY;
            }
        if (klass == (i32)UX_FORM_DESKTOP)
            {
            if (step == (i32)0)
                {
                return (i32)UX_FORM_DESKTOP;
                }
            if (step == (i32)1)
                {
                return (i32)UX_FORM_TABLET;
                }
            if (step == (i32)2)
                {
                return (i32)UX_FORM_PHONE;
                }
            return (i32)UX_FORM_ANY;
            }
        if (step == (i32)0)
            {
            return (i32)UX_FORM_ANY;
            }
        if (step == (i32)1)
            {
            return (i32)UX_FORM_DESKTOP;
            }
        if (step == (i32)2)
            {
            return (i32)UX_FORM_TABLET;
            }
        return (i32)UX_FORM_PHONE;
        }
    // A variant's class word: the form-factor class in the low byte, the ORIENTATION in its top two
    // bits (UXNB-V2 section 10: 0 none, 1 portrait, 2 landscape) -- allocated so that files from
    // before orientation, which have 0 there, read unchanged.
    static i32 classOf(u32 word)
        {
        return (i32)(word & (u32)$3FFF);
        }
    static i32 orientOf(u32 word)
        {
        return (i32)(word >> (u32)14);
        }
    // The tree for a form on a device of class `klass` held at orientation `orient`: down the form
    // factor chain, and within each class the current orientation's tree first, then one with no
    // orientation, then the OTHER orientation's (geometry adapts worse than nothing at all, but it is
    // still something).  UX_ORIENT_NONE (the desktop) takes any orientation in the same order.
    i32 selectTreeOriented(i32 formId, i32 klass, i32 orient, i32* chosenClass, i32* chosenOrient)
        {
        chosenOrient[0] = (i32)UX_ORIENT_NONE;
        if (ver == (i32)1)
            {
            chosenClass[0] = (i32)UX_FORM_ANY;
            return formId;
            }
        u32 at = self.formOffById(formId);
        if (at == (u32)0)
            {
            chosenClass[0] = (i32)-1;
            return (i32)-1;
            }
        u32 nv = self.rdU16(at + (u32)6);
        i32 other = orient == (i32)UX_ORIENT_PORTRAIT ? (i32)UX_ORIENT_LANDSCAPE
                  : (orient == (i32)UX_ORIENT_LANDSCAPE ? (i32)UX_ORIENT_PORTRAIT : (i32)-1);
        for (i32 step = (i32)0; step < (i32)4; step = step + (i32)1)
            {
            i32 want = self.chainAt(klass, step);
            // pass 0: this orientation; 1: none; 2: the other one (or, for NONE, anything)
            for (i32 pass = (i32)0; pass < (i32)3; pass = pass + (i32)1)
                {
                for (u32 v = (u32)0; v < nv; v = v + (u32)1)
                    {
                    u32 vat = at + (u32)10 + v * (u32)4;
                    u32 word = self.rdU16(vat);
                    if (UXRscV2.classOf(word) != want)
                        {
                        continue;
                        }
                    i32 o = UXRscV2.orientOf(word);
                    bool take = pass == (i32)0 ? (o == orient)
                              : (pass == (i32)1 ? (o == (i32)UX_ORIENT_NONE) : (other < (i32)0 || o == other));
                    if (take)
                        {
                        chosenClass[0] = want;
                        chosenOrient[0] = o;
                        return (i32)self.rdU16(vat + (u32)2);
                        }
                    }
                }
            }
        chosenClass[0] = (i32)-1;
        return (i32)-1;
        }
    i32 selectTree(i32 formId, i32 klass, i32* chosenClass)
        {
        if (ver == (i32)1)
            {
            // v1 compatibility rule: tree formId, class `any`, always.
            chosenClass[0] = (i32)UX_FORM_ANY;
            return formId;
            }
        u32 at = self.formOffById(formId);
        if (at == (u32)0)
            {
            chosenClass[0] = (i32)-1;
            return (i32)-1;
            }
        u32 nv = self.rdU16(at + (u32)6);
        for (i32 step = (i32)0; step < (i32)4; step = step + (i32)1)
            {
            i32 want = self.chainAt(klass, step);
            for (u32 v = (u32)0; v < nv; v = v + (u32)1)
                {
                u32 vat = at + (u32)10 + v * (u32)4;
                if (UXRscV2.classOf(self.rdU16(vat)) == want)
                    {
                    chosenClass[0] = want;
                    return (i32)self.rdU16(vat + (u32)2);
                    }
                }
            }
        chosenClass[0] = (i32)-1;
        return (i32)-1;
        }

    // ---- logical maps --------------------------------------------------------
    // logicalId -> object index within `tree`, or -1: absent is LEGAL (the
    // variant genuinely dropped that control) and the caller skips, silently.
    i32 objForLogical(i32 tree, i32 logicalId)
        {
        u32 at = offMaps;
        for (i32 m = (i32)0; m < nMaps; m = m + (i32)1)
            {
            u32 ne = self.rdU16(at + (u32)2);
            if ((i32)self.rdU16(at) == tree)
                {
                for (u32 e = (u32)0; e < ne; e = e + (u32)1)
                    {
                    u32 eat = at + (u32)4 + e * (u32)4;
                    if ((i32)self.rdU16(eat + (u32)2) == logicalId)
                        {
                        return (i32)self.rdU16(eat);
                        }
                    }
                return (i32)-1;
                }
            at = at + (u32)4 + ne * (u32)4;
            }
        return (i32)-1;
        }

    // ---- refs ----------------------------------------------------------------
    i32 refSpace(u32 at)
        {
        return (i32)buf[at];
        }
    i32 refA(u32 at)
        {
        return (i32)self.rdU16(at + (u32)1);
        }
    i32 refB(u32 at)
        {
        return (i32)self.rdU16(at + (u32)3);
        }
    // A VIEW ref resolved against the chosen tree: space 0 carries coordinates
    // (legal only single-variant — honoured iff its tree matches), space 4 goes
    // through the logical map.  Non-view spaces return -2 (caller's business).
    i32 resolveView(u32 refAt, i32 tree)
        {
        i32 sp = self.refSpace(refAt);
        if (sp == (i32)UXNB_REF_VIEW)
            {
            return self.refA(refAt) == tree ? self.refB(refAt) : (i32)-1;
            }
        if (sp == (i32)UXNB_REF_LOGICAL)
            {
            return self.objForLogical(tree, self.refB(refAt));
            }
        return (i32)-2;
        }

    // ---- sections ------------------------------------------------------------
    i32 classOverrideCount(void)
        {
        return nClasses;
        }
    // Ref, then name u32
    u32 classOverrideAt(i32 i)
        {
        return offClassov + (u32)i * (u32)10;
        }
    u8* classOverrideName(i32 i)
        {
        return self.str(self.rdU32(self.classOverrideAt(i) + (u32)6));
        }

    i32 topObjectCount(void)
        {
        return nObjects;
        }
    i32 topObjectId(i32 i)
        {
        return (i32)self.rdU16(offTopobj + (u32)i * self.topStride());
        }
    u8* topObjectName(i32 i)
        {
        return self.str(self.rdU32(offTopobj + (u32)i * self.topStride() + (u32)2));
        }
    // The designer's name for it ("Library Controller"); "" before v3 or when unnamed.
    u8* topObjectLabel(i32 i)
        {
        return ver >= (i32)3 ? self.str(self.rdU32(offTopobj + (u32)i * (u32)10 + (u32)6)) : (u8*)"";
        }

    i32 connCount(void)
        {
        return nConns;
        }
    u32 connAt(i32 i)
        {
        return offConns + (u32)i * self.connStride();
        }
    i32 connKind(i32 i)
        {
        return (i32)buf[self.connAt(i)];
        }
    // a Ref offset
    u32 connSrc(i32 i)
        {
        return self.connAt(i) + (u32)2;
        }
    u32 connDst(i32 i)
        {
        return self.connAt(i) + (u32)8;
        }
    u8* connMember(i32 i)
        {
        return self.str(self.rdU32(self.connAt(i) + (u32)14));
        }
    // The themes a connection applies to: bit class*3+orient; 0 = every theme (all of v2).
    u32 connScope(i32 i)
        {
        return ver >= (i32)3 ? self.rdU32(self.connAt(i) + (u32)18) : (u32)0;
        }
    static u32 themeBit(i32 klass, i32 orient)
        {
        return (u32)1 << (u32)(klass * (i32)3 + orient);
        }
    // Whether connection i binds in the theme (klass, orient).
    bool connInScope(i32 i, i32 klass, i32 orient)
        {
        u32 sc = self.connScope(i);
        return sc == (u32)0 || (sc & UXRscV2.themeBit(klass, orient)) != (u32)0;
        }

    // ---- v3 extension sections: {tag u32, size u32, body} ---------------------
    i32 extCount(void)
        {
        return nExt;
        }
    u32 extAt(i32 i)
        {
        u32 at = offExt;
        for (i32 e = (i32)0; e < i; e = e + (i32)1)
            {
            at = at + (u32)8 + ((self.rdU32(at + (u32)4) + (u32)1) & (u32)$FFFFFFFE);
            }
        return at;
        }
    u32 extTag(i32 i)
        {
        return self.rdU32(self.extAt(i));
        }
    u32 extSize(i32 i)
        {
        return self.rdU32(self.extAt(i) + (u32)4);
        }
    // offset of the body, into the buffer
    u32 extBody(i32 i)
        {
        return self.extAt(i) + (u32)8;
        }

    // ---- validation (§4: rscValidate) ---------------------------------------
    // How many connections fail to bind for `formId` at `klass`: each failed
    // connection's index lands in out (up to cap).  A dropped control is exactly
    // one of these — the DESIGNER decides whether it is a warning or intended.
    i32 validate(i32 formId, i32 klass, i32* out, i32 cap)
        {
        i32 chosen = (i32)0;
        i32 tree = self.selectTree(formId, klass, &chosen);
        if (tree < (i32)0)
            {
            return (i32)-1;
            }
        i32 bad = (i32)0;
        for (i32 i = (i32)0; i < nConns; i = i + (i32)1)
            {
            bool fail = false;
            if (self.resolveView(self.connSrc(i), tree) == (i32)-1)
                {
                fail = true;
                }
            if (self.resolveView(self.connDst(i), tree) == (i32)-1)
                {
                fail = true;
                }
            if (fail)
                {
                if (bad < cap)
                    {
                    out[bad] = i;
                    }
                bad = bad + (i32)1;
                }
            }
        return bad;
        }
    }
