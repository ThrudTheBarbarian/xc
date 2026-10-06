// RKVariants.xc — one control, several layouts: what they share and what each varies.
//
// A form's layouts are separate trees (UXNB v2), and a control in two of them is two objects with
// one logical id.  What the control SAYS -- its text, whether it is disabled, its flags -- is the
// same everywhere unless the designer decides otherwise; where it sits is each layout's own.  So
// an edit to an Attributes property goes to every layout's copy of the control, except a layout
// where that property has been made to VARY (Interface Builder's "+" beside a property), which
// keeps its own value until the variation is removed.
//
// The variations are kept in the document, in a VARY section of the nib chunk:
//   { count u16, then per entry: tree u16, logicalId u16, property label (u16 length, bytes) }
#import "Array.xc"
#import "Data.xc"
#import "UXRscModel.xc"
#import "RKProps.xc"

class RKVary : Object
    {
    i32 tree;
    i32 logicalId;
    u8* prop; // the property's label, as RKProps names it

    static RKVary* make(i32 tree, i32 id, u8* prop)
        {
        RKVary* v = new RKVary();
        v.tree = tree;
        v.logicalId = id;
        v.prop = prop;
        return v;
        }
    }

class RKVariants : Object
    {
    Array<RKVary>* varied;

    void init(void)
        {
        varied = new Array();
        }

    // ---- which copies ------------------------------------------------------------------------
    // The same control in the form's other layouts.
    static Array<UXRscObject>* copiesOf(UXRscDoc* d, UXRscTree* t, UXRscObject* o)
        {
        Array<UXRscObject>* out = new Array();
        UXRscForm* f = d.formOf(t);
        if (f == (UXRscForm*)0 || o.logicalId == (i32)0)
            {
            return out;
            }
        for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
            {
            UXRscTree* other = f.variantAt(v).tree;
            if (other == t)
                {
                continue;
                }
            Array<UXRscObject>* all = other.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                UXRscObject* c = (UXRscObject* ?)all.get(k);
                if (c.logicalId == o.logicalId && c.type == o.type)
                    {
                    out.add(c);
                    }
                }
            }
        return out;
        }
    // The layout (tree) a copy is in.
    static UXRscTree* treeOf(UXRscDoc* d, UXRscObject* o)
        {
        for (i32 i = (i32)0; i < d.treeCount(); i = i + (i32)1)
            {
            UXRscTree* t = d.treeAt(i);
            if (t.root == o || (t.root != (UXRscObject*)0 && t.root.parentOf(o) != (UXRscObject*)0))
                {
                return t;
                }
            }
        return (UXRscTree*)0;
        }

    // ---- variations ------------------------------------------------------------------------------
    bool varies(UXRscDoc* d, UXRscTree* t, UXRscObject* o, u8* prop)
        {
        return self.find(d.indexOfTree(t), o.logicalId, prop) >= (i32)0;
        }
    i32 find(i32 tree, i32 id, u8* prop)
        {
        for (u32 i = (u32)0; i < varied.count(); i = i + (u32)1)
            {
            RKVary* v = (RKVary* ?)varied.get(i);
            if (v.tree == tree && v.logicalId == id && RKVariants.seq(v.prop, prop))
                {
                return (i32)i;
                }
            }
        return (i32)-1;
        }
    // Make a property this layout's own (a control needs a logical id, which a copy has).
    void vary(UXRscDoc* d, UXRscTree* t, UXRscObject* o, u8* prop)
        {
        if (o.logicalId == (i32)0 || self.varies(d, t, o, prop))
            {
            return;
            }
        varied.add(RKVary.make(d.indexOfTree(t), o.logicalId, prop));
        self.saveTo(d);
        }
    // Share it again: this layout takes the value the others share (from the first copy that
    // does not vary it), and follows them from now on.
    void unvary(UXRscDoc* d, UXRscTree* t, UXRscObject* o, RKProperty* p)
        {
        i32 at = self.find(d.indexOfTree(t), o.logicalId, p.label);
        if (at < (i32)0)
            {
            return;
            }
        varied.removeAt((u32)at);
        Array<UXRscObject>* cs = RKVariants.copiesOf(d, t, o);
        for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
            {
            UXRscObject* c = (UXRscObject* ?)cs.get(i);
            UXRscTree* ct = RKVariants.treeOf(d, c);
            if (ct != (UXRscTree*)0 && !self.varies(d, ct, c, p.label))
                {
                RKVariants.copy(p, c, o);
                break;
                }
            }
        self.saveTo(d);
        }

    // ---- an edit, shared ---------------------------------------------------------------------------
    // `o` (in `t`) has just had property `p` edited.  Unless this layout varies it, every copy in a
    // layout that does not vary it takes the new value.  Returns how many copies changed.
    i32 share(UXRscDoc* d, UXRscTree* t, UXRscObject* o, RKProperty* p)
        {
        if (RKVariants.isFrame(p) || self.varies(d, t, o, p.label))
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        Array<UXRscObject>* cs = RKVariants.copiesOf(d, t, o);
        for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
            {
            UXRscObject* c = (UXRscObject* ?)cs.get(i);
            UXRscTree* ct = RKVariants.treeOf(d, c);
            if (ct != (UXRscTree*)0 && !self.varies(d, ct, c, p.label))
                {
                RKVariants.copy(p, o, c);
                n = n + (i32)1;
                }
            }
        return n;
        }
    // Where a control sits is each layout's own: the frame never shares.
    static bool isFrame(RKProperty* p)
        {
        return p.kind == (i32)RKP_INT && p.sel >= (i32)RKV_X && p.sel <= (i32)RKV_H;
        }
    // Copy one property's value from `a` to `b`.
    static void copy(RKProperty* p, UXRscObject* a, UXRscObject* b)
        {
        if (p.kind == (i32)RKP_TEXT)
            {
            b.text = a.text;
            if (b.ted != (UXRscTedinfo*)0)
                {
                b.ted.text = a.text;
                }
            return;
            }
        if (p.kind == (i32)RKP_FLAG || p.kind == (i32)RKP_STATE)
            {
            RKProps.setBool(b, p, RKProps.boolOf(a, p));
            return;
            }
        RKProps.setInt(b, p, RKProps.intOf(a, p));
        }

    // ---- kept in the document ------------------------------------------------------------------
    static u32 tag(void)
        {
        return (u32)$56415259; // 'VARY'
        }
    void saveTo(UXRscDoc* d)
        {
        u32 i = (u32)0;
        while (i < d.extSections.count())
            {
            if (((UXRscExtSection* ?)d.extSections.get(i)).tag == RKVariants.tag())
                {
                d.extSections.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        if (varied.count() == (u32)0)
            {
            return;
            }
        Data* b = Data.withCapacity((u32)((i32)64));
        RKVariants.be16(b, (i32)varied.count());
        for (u32 k = (u32)0; k < varied.count(); k = k + (u32)1)
            {
            RKVary* v = (RKVary* ?)varied.get(k);
            RKVariants.be16(b, v.tree);
            RKVariants.be16(b, v.logicalId);
            i32 n = UXRscTree.len(v.prop);
            RKVariants.be16(b, n);
            b.appendBytes(v.prop, n);
            }
        UXRscExtSection* x = new UXRscExtSection();
        x.tag = RKVariants.tag();
        x.body = b;
        d.extSections.add(x);
        }
    void loadFrom(UXRscDoc* d)
        {
        varied = new Array();
        for (u32 k = (u32)0; k < d.extSections.count(); k = k + (u32)1)
            {
            UXRscExtSection* x = (UXRscExtSection* ?)d.extSections.get(k);
            if (x.tag != RKVariants.tag())
                {
                continue;
                }
            u8* p = x.body.bytes();
            i32 len = x.body.length();
            i32 at = (i32)2;
            i32 n = len >= (i32)2 ? RKVariants.rd16(p, (i32)0) : (i32)0;
            for (i32 e = (i32)0; e < n && at + (i32)6 <= len; e = e + (i32)1)
                {
                i32 tree = RKVariants.rd16(p, at);
                i32 id = RKVariants.rd16(p, at + (i32)2);
                i32 sl = RKVariants.rd16(p, at + (i32)4);
                at = at + (i32)6;
                if (at + sl > len)
                    {
                    break;
                    }
                u8* s = new u8[(u32)(sl + (i32)1)];
                for (i32 c = (i32)0; c < sl; c = c + (i32)1)
                    {
                    s[c] = p[at + c];
                    }
                s[sl] = (u8)0;
                at = at + sl;
                varied.add(RKVary.make(tree, id, s));
                }
            }
        }
    static void be16(Data* d, i32 v)
        {
        d.appendByte((u8)((v >> (i32)8) & (i32)$FF));
        d.appendByte((u8)(v & (i32)$FF));
        }
    static i32 rd16(u8* p, i32 at)
        {
        return ((i32)p[at] << (i32)8) | (i32)p[at + (i32)1];
        }
    static bool seq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && a[i] == b[i])
            {
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }
    }
