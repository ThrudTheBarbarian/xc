// RKModel.xc — the in-memory GEM resource model, ported from GModel.[hm].
//
// A resource is a list of named trees; each tree is a root object with nested
// children.  The classic OBJECT fields are kept, plus the XT GEM extended
// widget types, with type-specific payloads hanging off the node (string /
// TEDINFO / box colour word / icon / bit form).  The flat classic linked
// layout — next/head/tail — is rebuilt only at write time, by flatten().
//
// Ported deliberately, not mechanically.  Two kinds of thing were dropped:
// the NSImage caches (rendering is UXKit's job now — that is the whole reason
// Rocks is being rewritten in XC), and Foundation container types, which
// become Array and plain byte buffers.  Everything that affects FILE FIDELITY
// is kept, including the fields Rocks does not itself interpret: a foreign
// editor's extended-type byte, an imported CICONBLK's original bytes, the
// classic mono icon data.  Those exist so that reading someone else's resource
// and writing it back does not quietly destroy what we did not understand.
//
// See RSC-FORMAT.md (beside this tree) for the on-disk layout.
#import "Array.xc"
#import "UXData.xc"

// ---- object types: classic, then the XT GEM themed extensions ---------
#define RKT_BOX 20
#define RKT_TEXT 21
#define RKT_BOXTEXT 22
#define RKT_IMAGE 23
#define RKT_USERDEF 24
#define RKT_IBOX 25
#define RKT_BUTTON 26
#define RKT_BOXCHAR 27
#define RKT_STRING 28
#define RKT_FTEXT 29
#define RKT_FBOXTEXT 30
#define RKT_ICON 31
#define RKT_TITLE 32
#define RKT_CICONBLK 33 // the standard Atari colour icon (a CICONBLK)
#define RKT_CHECKBOX 40 // XT GEM extensions from here down
#define RKT_RADIO 41
#define RKT_POPUP 42
#define RKT_FIELD 43
#define RKT_CICON 44 // Rocks' own RGBA PAM icon

// ---- flags -----------------------------------------------------------------
#define RKF_NONE $0000
#define RKF_SELECTABLE $0001
#define RKF_DEFAULT $0002
#define RKF_EXIT $0004
#define RKF_EDITABLE $0008
#define RKF_RBUTTON $0010
#define RKF_LASTOB $0020
#define RKF_TOUCHEXIT $0040
#define RKF_HIDETREE $0080
#define RKF_INDIRECT $0100
#define RKF_CANCEL $0200   // Esc fires this object
#define RKF_MOVEABLE $0400 // on the ROOT: the dialog is movable
#define RKF_SUBMENU $0800

// ---- state -----------------------------------------------------------------
#define RKS_NORMAL $0000
#define RKS_SELECTED $0001
#define RKS_CROSSED $0002
#define RKS_CHECKED $0004
#define RKS_DISABLED $0008
#define RKS_OUTLINED $0010
#define RKS_SHADOWED $0020
#define RKS_WHITEBAK $0040 // bits 8-14 then hold the shortcut char index

// ---- tree kinds ------------------------------------------------------------
#define RKK_DIALOG 0
#define RKK_MENU 1
#define RKK_FREE 2

// ---- box corner rounding: ob_type high byte, bits 4-7, one bit per corner --
#define RK_ROUND_TL $10
#define RK_ROUND_TR $20
#define RK_ROUND_BR $40
#define RK_ROUND_BL $80
#define RK_ROUND_ALL $F0

// ---- the GEM 16-bit colour word -------------------------------------------
// border(15-12) text(11-8) textMode(7: 1=replace, 0=transparent) fill(6-4) inside(3-0)
class RKColor : Object
    {
    i32 border; // VDI pen index; 1 = black, 0 = white
    i32 text;
    bool replace;
    i32 pattern; // 0..7 fill pattern
    i32 inside;

    void init(void)
        {
        border = (i32)1;
        text = (i32)1;
        replace = false;
        pattern = (i32)0;
        inside = (i32)0;
        }

    u16 pack(void)
        {
        return (u16)(((border & (i32)$F) << (i32)12) | ((text & (i32)$F) << (i32)8) |
                     ((replace ? (i32)1 : (i32)0) << (i32)7) |
                     ((pattern & (i32)7) << (i32)4) | (inside & (i32)$F));
        }
    static RKColor* unpack(u16 raw)
        {
        RKColor* c = new RKColor();
        c.border = ((i32)raw >> (i32)12) & (i32)$F;
        c.text = ((i32)raw >> (i32)8) & (i32)$F;
        c.replace = ((i32)raw & (i32)$80) != (i32)0;
        c.pattern = ((i32)raw >> (i32)4) & (i32)7;
        c.inside = (i32)raw & (i32)$F;
        return c;
        }
    }

    // ---- payloads --------------------------------------------------------------
    class RKTedinfo : Object
    {
    u8* text;  // te_ptext
    u8* tmplt; // te_ptmplt
    u8* valid; // te_pvalid
    i32 font;  // 3 = large, 5 = small
    i32 fontId;
    i32 just; // 0 left, 1 right, 2 centre
    RKColor* color;
    i32 fontsize;
    i32 thickness;
    void init(void)
        {
        text = (u8*)"";
        tmplt = (u8*)"";
        valid = (u8*)"";
        font = (i32)5;
        fontId = (i32)0;
        just = (i32)0;
        color = new RKColor();
        fontsize = (i32)0;
        thickness = (i32)0;
        }
    }

    class RKBox : Object
    {
    u8 character;  // a G_BOXCHAR's char (0 = none)
    i32 thickness; // border thickness; negative = drawn inside
    RKColor* color;
    void init(void)
        {
        character = (u8)0;
        thickness = (i32)1;
        color = new RKColor();
        }
    }

    // A classic monochrome bit form (BITBLK): 1bpp, wb bytes per row, hl rows.
    // Set bits draw in VDI pen `color`; clear bits are transparent — a BITBLK has
    // no mask.  Carried by G_IMAGE objects and by the free-image table.
    class RKBitblk : Object
    {
    UXData* data; // wb * hl bytes
    i32 wb, hl, x, y, color;
    void init(void)
        {
        data = (UXData*)0;
        wb = (i32)0;
        hl = (i32)0;
        x = (i32)0;
        y = (i32)0;
        color = (i32)1;
        }
    }

    class RKIcon : Object
    {
    bool isColor;
    u8* label;
    UXData* pam;      // embedded P7 PAM bytes
    UXData* ciconRaw; // the original CICONBLK, verbatim, for byte-faithful re-export
    UXData* selPam;   // the SELECTED form, if the file had one
    u8* externalPath; // reference instead of embedding
    UXData* monoData; // classic ICONBLK ib_pdata, preserved from an import
    UXData* monoMask; // ib_pmask
    i32 iconChar, charX, charY;
    i32 textX, textY, textW, textH;
    i32 iconX, iconY, iconW, iconH;
    void init(void)
        {
        isColor = false;
        label = (u8*)"";
        pam = (UXData*)0;
        ciconRaw = (UXData*)0;
        selPam = (UXData*)0;
        externalPath = (u8*)0;
        monoData = (UXData*)0;
        monoMask = (UXData*)0;
        iconChar = (i32)0;
        charX = (i32)0;
        charY = (i32)0;
        textX = (i32)0;
        textY = (i32)0;
        textW = (i32)0;
        textH = (i32)0;
        iconX = (i32)0;
        iconY = (i32)0;
        iconW = (i32)0;
        iconH = (i32)0;
        }
    }

    // ---- the object node -------------------------------------------------------
    class RKObject : Object
    {
    i32 type;
    // The ob_type high byte when it carries ROCKS' meaning: corner rounding
    // (bits 4-7), the rounded-field / group-box flag (bit 0), a popup's tree.
    u8 extType;
    // The same byte when it came from someone ELSE's resource.  Other editors
    // use it as a free extended-type field, so it is kept verbatim and written
    // back, but must not MEAN anything here — otherwise a legacy button with
    // 0x12 would read as a rounded box.
    u8 legacyExtType;
    i32 flags;
    i32 state;
    i32 x, y, w, h;
    u8* name; // symbolic name for source export; 0 = derive one
    u8* text; // string spec

    RKTedinfo* ted;
    RKBox* box;
    RKIcon* icon;
    RKBitblk* bitblk;
    Array<RKObject>* children;

    void init(void)
        {
        type = (i32)RKT_BOX;
        extType = (u8)0;
        legacyExtType = (u8)0;
        flags = (i32)RKF_NONE;
        state = (i32)RKS_NORMAL;
        x = (i32)0;
        y = (i32)0;
        w = (i32)0;
        h = (i32)0;
        name = (u8*)0;
        text = (u8*)0;
        ted = (RKTedinfo*)0;
        box = (RKBox*)0;
        icon = (RKIcon*)0;
        bitblk = (RKBitblk*)0;
        children = new Array();
        }

    static RKObject* make(i32 type, i32 x, i32 y, i32 w, i32 h)
        {
        RKObject* o = new RKObject();
        o.type = type;
        o.x = x;
        o.y = y;
        o.w = w;
        o.h = h;
        o.seedPayload();
        return o;
        }

    // ---- type capability queries -------------------------------------------
    bool hasStringSpec(void)
        {
        return type == (i32)RKT_STRING || type == (i32)RKT_BUTTON ||
               type == (i32)RKT_TITLE || type == (i32)RKT_TEXT ||
               type == (i32)RKT_CHECKBOX || type == (i32)RKT_RADIO;
        }
    bool hasTedinfo(void)
        {
        return RKObject.typeHasTedinfo(type);
        }
    // The same question about a bare type, so the schema can ask it without an
    // object.  ONE list: a second copy of this in RKProps drifted immediately —
    // it omitted G_FIELD, so text fields, the one type the feature was asked
    // for, were never offered alignment.
    static bool typeHasTedinfo(i32 t)
        {
        return t == (i32)RKT_TEXT || t == (i32)RKT_BOXTEXT ||
               t == (i32)RKT_FTEXT || t == (i32)RKT_FBOXTEXT ||
               t == (i32)RKT_FIELD;
        }
    bool hasBox(void)
        {
        return type == (i32)RKT_BOX || type == (i32)RKT_IBOX ||
               type == (i32)RKT_BOXCHAR || type == (i32)RKT_BOXTEXT ||
               type == (i32)RKT_FBOXTEXT;
        }
    bool hasIcon(void)
        {
        return type == (i32)RKT_ICON || type == (i32)RKT_CICON || type == (i32)RKT_CICONBLK;
        }
    bool hasBitblk(void)
        {
        return type == (i32)RKT_IMAGE;
        }
    bool canHaveChildren(void)
        {
        return type == (i32)RKT_BOX || type == (i32)RKT_IBOX ||
               type == (i32)RKT_BOXCHAR || type == (i32)RKT_TITLE;
        }

    // Give a freshly made object the payload its type needs, so nothing
    // downstream has to null-check what the type guarantees.
    void seedPayload(void)
        {
        if (self.hasTedinfo() && ted == (RKTedinfo*)0)
            {
            ted = new RKTedinfo();
            }
        if (self.hasBox() && box == (RKBox*)0)
            {
            box = new RKBox();
            }
        if (self.hasIcon() && icon == (RKIcon*)0)
            {
            icon = new RKIcon();
            }
        if (self.hasBitblk() && bitblk == (RKBitblk*)0)
            {
            bitblk = new RKBitblk();
            }
        if (self.hasStringSpec() && text == (u8*)0)
            {
            text = (u8*)"";
            }
        }

    i32 childCount(void)
        {
        return (i32)children.count();
        }
    RKObject* childAt(i32 i)
        { return (RKObject* ?)children.get((u16)i);
        }
    void addChild(RKObject* c)
        {
        if (c != (RKObject*)0)
            {
            children.add(c);
            }
        }

    // The direct parent of `target` within this subtree, or 0.
    RKObject* parentOf(RKObject* target)
        {
        for (i32 i = (i32)0; i < self.childCount(); i = i + (i32)1)
            {
            RKObject* c = self.childAt(i);
            if (c == target)
                {
                return self;
                }
            RKObject* deeper = c.parentOf(target);
            if (deeper != (RKObject*)0)
                {
                return deeper;
                }
            }
        return (RKObject*)0;
        }

    // Pre-order walk, appending every node in this subtree to `out`.
    void collect(Array<RKObject>* out)
        {
        out.add(self);
        for (i32 i = (i32)0; i < self.childCount(); i = i + (i32)1)
            {
            self.childAt(i).collect(out);
            }
        }
    }

    // ---- a flattened node: the classic OBJECT array's links --------------------
    class RKFlatNode : Object
    {
    RKObject* obj;
    i32 next, head, tail;
    void init(void)
        {
        obj = (RKObject*)0;
        next = (i32)-1;
        head = (i32)-1;
        tail = (i32)-1;
        }
    }

    // ---- tree ------------------------------------------------------------------
    class RKTree : Object
    {
    u8* name;
    i32 kind;
    RKObject* root;

    void init(void)
        {
        name = (u8*)"";
        kind = (i32)RKK_DIALOG;
        root = (RKObject*)0;
        }

    RKObject* parentOf(RKObject* node)
        {
        if (root == (RKObject*)0 || node == root)
            {
            return (RKObject*)0;
            }
        return root.parentOf(node);
        }
    Array<RKObject>* allObjects(void)
        {
        Array<RKObject>* out = new Array();
        if (root != (RKObject*)0)
            {
            root.collect(out);
            }
        return out;
        }
    // Screen coordinates: a child's x/y are relative to its parent.
    bool absoluteOriginOf(RKObject* node, i32* ox, i32* oy)
        {
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        RKObject* cur = node;
        while (cur != (RKObject*)0)
            {
            ax = ax + cur.x;
            ay = ay + cur.y;
            if (cur == root)
                {
                ox[0] = ax;
                oy[0] = ay;
                return true;
                }
            cur = self.parentOf(cur);
            }
        return false; // not in this tree
        }
    bool isMenu(void)
        {
        return kind == (i32)RKK_MENU;
        }
    }

    // ---- resource --------------------------------------------------------------
    class RKResource : Object
    {
    Array<RKTree>* trees;
    Array<UXData>* freeStrings;  // rsrc_gaddr(R_STRING, i) — referenced by nothing
    Array<RKBitblk>* freeImages; // rsrc_gaddr(R_IMAGE, i) — likewise
    bool bigEndian;              // classic 68000 GEM fidelity
    bool packedCoords;           // char/pixel packing on write
    bool embedIcons;             // embed PAM vs reference an external path
    i32 charWidth, charHeight;

    void init(void)
        {
        trees = new Array();
        freeStrings = new Array();
        freeImages = new Array();
        bigEndian = true;
        packedCoords = true;
        embedIcons = true;
        charWidth = (i32)8;
        charHeight = (i32)16;
        }

    i32 treeCount(void)
        {
        return (i32)trees.count();
        }
    RKTree* treeAt(i32 i)
        { return (RKTree* ?)trees.get((u16)i);
        }
    void addTree(RKTree* t)
        {
        if (t != (RKTree*)0)
            {
            trees.add(t);
            }
        }

    static RKResource* emptyDialog(void)
        {
        RKResource* r = new RKResource();
        RKTree* t = new RKTree();
        t.name = (u8*)"DIALOG";
        t.kind = (i32)RKK_DIALOG;
        t.root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)320, (i32)200);
        r.addTree(t);
        return r;
        }

    // Flatten a tree to the classic pre-order array with next/head/tail links.
    // This is the ONLY place the linked layout exists: the editor works on the
    // nested form and the flat one is rebuilt at write time, so the two can
    // never disagree.
    Array<RKFlatNode>* flatten(RKTree* t)
        {
        Array<RKFlatNode>* out = new Array();
        if (t == (RKTree*)0 || t.root == (RKObject*)0)
            {
            return out;
            }
        Array<RKObject>* order = t.allObjects();
        for (u16 i = (u16)0; i < order.count(); i = i + (u16)1)
            {
            RKFlatNode* n = new RKFlatNode();
            n.obj = (RKObject* ?)order.get(i);
            out.add(n);
            }
        // index of an object within the pre-order
        for (i32 i = (i32)0; i < (i32)out.count(); i = i + (i32)1)
            {
            RKFlatNode* n = (RKFlatNode* ?)out.get((u16)i);
            RKObject* o = n.obj;
            i32 kids = o.childCount();
            if (kids > (i32)0)
                {
                n.head = self.indexOf(out, o.childAt((i32)0));
                n.tail = self.indexOf(out, o.childAt(kids - (i32)1));
                }
            // next = the following sibling, or the parent when last
            RKObject* p = t.parentOf(o);
            // the root
            if (p == (RKObject*)0)
                {
                n.next = (i32)-1;
                }
            else
                {
                i32 pos = (i32)-1;
                for (i32 k = (i32)0; k < p.childCount(); k = k + (i32)1)
                    {
                    if (p.childAt(k) == o)
                        {
                        pos = k;
                        }
                    }
                if (pos >= (i32)0 && pos + (i32)1 < p.childCount())
                    {
                    n.next = self.indexOf(out, p.childAt(pos + (i32)1));
                    }
                else
                    {
                    n.next = self.indexOf(out, p); // last child points back
                    }
                }
            }
        // the last object in the tree carries LASTOB
        if (out.count() > (u16)0)
            {
            RKFlatNode* last = (RKFlatNode* ?)out.get((u16)((i32)out.count() - (i32)1));
            last.obj.flags = last.obj.flags | (i32)RKF_LASTOB;
            }
        return out;
        }

    i32 indexOf(Array<RKFlatNode>* flat, RKObject* o)
        {
        for (i32 i = (i32)0; i < (i32)flat.count(); i = i + (i32)1)
            {
            if (((RKFlatNode* ?)flat.get((u16)i)).obj == o)
                {
                return i;
                }
            }
        return (i32)-1;
        }
    }
