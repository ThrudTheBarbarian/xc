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
// Layout variants (UXNB-V2 sections 1 and 10): a variant's form-factor class and orientation.  The
// registry's own numbers, so they go into the chunk as they are; test_rkforms checks them against
// UXKit's UX_FORM_* / UX_ORIENT_*, which the loader reads them with.
#define RKV_ANY 0
#define RKV_DESKTOP 1
#define RKV_TABLET 2
#define RKV_PHONE 3
#define RKV_ORIENT_NONE 0
#define RKV_ORIENT_PORTRAIT 1
#define RKV_ORIENT_LANDSCAPE 2

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
    RKColor* copy(void)
        {
        return RKColor.unpack(self.pack());
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
    RKTedinfo* copy(void)
        {
        RKTedinfo* c = new RKTedinfo();
        c.text = text;
        c.tmplt = tmplt;
        c.valid = valid;
        c.font = font;
        c.fontId = fontId;
        c.just = just;
        c.color = color != (RKColor*)0 ? color.copy() : new RKColor();
        c.fontsize = fontsize;
        c.thickness = thickness;
        return c;
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
    RKBox* copy(void)
        {
        RKBox* c = new RKBox();
        c.character = character;
        c.thickness = thickness;
        c.color = color != (RKColor*)0 ? color.copy() : new RKColor();
        return c;
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
    RKBitblk* copy(void)
        {
        RKBitblk* c = new RKBitblk();
        c.data = data;
        c.wb = wb;
        c.hl = hl;
        c.x = x;
        c.y = y;
        c.color = color;
        return c;
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
    RKIcon* copy(void)
        {
        RKIcon* c = new RKIcon();
        c.isColor = isColor;
        c.label = label;
        c.pam = pam;
        c.ciconRaw = ciconRaw;
        c.selPam = selPam;
        c.externalPath = externalPath;
        c.monoData = monoData;
        c.monoMask = monoMask;
        c.iconChar = iconChar;
        c.charX = charX;
        c.charY = charY;
        c.textX = textX;
        c.textY = textY;
        c.textW = textW;
        c.textH = textH;
        c.iconX = iconX;
        c.iconY = iconY;
        c.iconW = iconW;
        c.iconH = iconH;
        return c;
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
    // The control's identity across a form's variants (UXNB-V2 section 3): the same number on every
    // variant's copy of it, so a connection made once binds in each layout.  0 = none -- a container
    // that exists for one layout's benefit needs none.  Unique within a form, never renumbered.
    i32 logicalId;

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
        logicalId = (i32)0;
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

    // A deep copy of this subtree, logical ids included -- the seed of a new layout variant (UXNB-V2
    // section 7: a one-time copy, not a live link, so every payload object is the copy's own and
    // editing one layout never reaches into another).  Strings and image bytes are shared: they are
    // replaced when edited, never written through.
    RKObject* deepCopy(void)
        {
        RKObject* c = new RKObject();
        c.type = type;
        c.extType = extType;
        c.legacyExtType = legacyExtType;
        c.flags = flags;
        c.state = state;
        c.x = x;
        c.y = y;
        c.w = w;
        c.h = h;
        c.name = name;
        c.text = text;
        c.logicalId = logicalId;
        if (ted != (RKTedinfo*)0)
            {
            c.ted = ted.copy();
            }
        if (box != (RKBox*)0)
            {
            c.box = box.copy();
            }
        if (icon != (RKIcon*)0)
            {
            c.icon = icon.copy();
            }
        if (bitblk != (RKBitblk*)0)
            {
            c.bitblk = bitblk.copy();
            }
        for (i32 i = (i32)0; i < self.childCount(); i = i + (i32)1)
            {
            c.addChild(self.childAt(i).deepCopy());
            }
        return c;
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
    UXData* nameStore; // owns `name`'s bytes when the name was made here rather than read

    void init(void)
        {
        name = (u8*)"";
        kind = (i32)RKK_DIALOG;
        root = (RKObject*)0;
        nameStore = (UXData*)0;
        }

    // Name this tree `base` + `suffix` ("MAIN" + "_PHONE_L"), owning the bytes.
    void setNameJoined(u8* base, u8* suffix)
        {
        UXData* d = UXData.fromString(base != (u8*)0 ? base : (u8*)"");
        d.appendBytes(suffix, RKTree.len(suffix));
        d.appendByte((u8)0);
        nameStore = d;
        name = d.bytes();
        }
    static i32 len(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
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

    // ---- reparent on drop ----------------------------------------------------
    // Re-derive the tree's nesting from geometry, the rule the original editor used: every object
    // becomes a child of the SMALLEST container that fully encloses it (edges inclusive), so the tree
    // always mirrors what is on screen.  Drop a button onto a box and it is in the box; drag it out
    // and it is not; drop a box over three buttons and it adopts them.  Every object keeps its
    // ABSOLUTE position -- only its parent, and so its parent-relative x/y, change.
    //   - Only containers parent (canHaveChildren): a button never swallows what overlaps it.
    //   - A tie (two containers of the same area enclosing each other, i.e. the same rect) goes to
    //     the EARLIER one in pre-order, and only an earlier object may parent: no cycles.
    //   - Sibling order is the old pre-order, so the z-order is kept.
    // Idempotent: unchanged geometry changes nothing.  Returns how many objects changed parent.
    i32 reparentByGeometry(void)
        {
        if (root == (RKObject*)0)
            {
            return (i32)0;
            }
        Array<RKObject>* all = self.allObjects(); // pre-order, root first
        i32 n = (i32)all.count();
        if (n < (i32)2)
            {
            return (i32)0;
            }
        i32* ax = new i32[(u32)n];
        i32* ay = new i32[(u32)n];
        i32* oldParent = new i32[(u32)n];
        i32* newParent = new i32[(u32)n];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            RKObject* o = (RKObject* ?)all.get((u32)i);
            i32 x = (i32)0;
            i32 y = (i32)0;
            self.absoluteOriginOf(o, &x, &y);
            ax[i] = x;
            ay[i] = y;
            RKObject* p = self.parentOf(o);
            oldParent[i] = (i32)-1;
            for (i32 k = (i32)0; k < n; k = k + (i32)1)
                {
                if ((RKObject* ?)all.get((u32)k) == p)
                    {
                    oldParent[i] = k;
                    }
                }
            }
        i32 changed = (i32)0;
        newParent[0] = (i32)-1;
        for (i32 i = (i32)1; i < n; i = i + (i32)1)
            {
            RKObject* o = (RKObject* ?)all.get((u32)i);
            i32 oArea = o.w * o.h;
            i32 best = (i32)0;
            i32 bestArea = root.w * root.h;
            for (i32 k = (i32)0; k < n; k = k + (i32)1)
                {
                RKObject* p = (RKObject* ?)all.get((u32)k);
                if (k == i || !p.canHaveChildren())
                    {
                    continue;
                    }
                bool enc = ax[i] >= ax[k] && ay[i] >= ay[k] && ax[i] + o.w <= ax[k] + p.w && ay[i] + o.h <= ay[k] + p.h;
                if (!enc)
                    {
                    continue;
                    }
                i32 pArea = p.w * p.h;
                if (pArea == oArea && k >= i)
                    {
                    continue; // a tie: only an earlier object may parent
                    }
                if (pArea < bestArea || (pArea == bestArea && k < best))
                    {
                    best = k;
                    bestArea = pArea;
                    }
                }
            newParent[i] = best;
            if (best != oldParent[i])
                {
                changed = changed + (i32)1;
                }
            }
        if (changed == (i32)0)
            {
            return (i32)0;
            }
        // rebuild every child list in the old pre-order (the z-order), then the relative positions
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            ((RKObject* ?)all.get((u32)i)).children = new Array();
            }
        for (i32 i = (i32)1; i < n; i = i + (i32)1)
            {
            RKObject* o = (RKObject* ?)all.get((u32)i);
            ((RKObject* ?)all.get((u32)newParent[i])).addChild(o);
            o.x = ax[i] - ax[newParent[i]];
            o.y = ay[i] - ay[newParent[i]];
            }
        return changed;
        }
    }

    // ---- forms and their layout variants (UXNB-V2) ------------------------------
    // One FORM is one piece of UI as the application sees it -- its outlets and actions -- and each
    // VARIANT is a whole classic tree laid out for one form factor (and, on a device, one orientation).
    // The trees are separate designs bonded only by their controls' logical ids: a phone layout is
    // not derived from the desktop one, and nothing here makes it so (section 1).
    class RKVariant : Object
    {
    i32 klass;  // RKV_DESKTOP / _TABLET / _PHONE / _ANY
    i32 orient; // RKV_ORIENT_*; NONE on the desktop
    RKTree* tree;
    void init(void)
        {
        klass = (i32)RKV_ANY;
        orient = (i32)RKV_ORIENT_NONE;
        tree = (RKTree*)0;
        }
    }

    class RKForm : Object
    {
    i32 formId; // what the app loads it by: the first tree's index, so a v1 app's constant still works
    u8* name;
    Array<RKVariant>* variants;
    void init(void)
        {
        formId = (i32)0;
        name = (u8*)"";
        variants = new Array();
        }
    i32 variantCount(void)
        {
        return (i32)variants.count();
        }
    RKVariant* variantAt(i32 i)
        { return (RKVariant* ?)variants.get((u32)i);
        }
    RKVariant* find(i32 klass, i32 orient)
        {
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            RKVariant* v = self.variantAt(i);
            if (v.klass == klass && v.orient == orient)
                {
                return v;
                }
            }
        return (RKVariant*)0;
        }
    RKVariant* variantFor(RKTree* t)
        {
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            RKVariant* v = self.variantAt(i);
            if (v.tree == t)
                {
                return v;
                }
            }
        return (RKVariant*)0;
        }
    // The next unused logical id across every variant (ids are never reused within a form).
    i32 nextLogicalId(void)
        {
        i32 hi = (i32)0;
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            Array<RKObject>* all = self.variantAt(i).tree.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                i32 id = ((RKObject* ?)all.get(k)).logicalId;
                if (id > hi)
                    {
                    hi = id;
                    }
                }
            }
        return hi + (i32)1;
        }
    }

    // ---- resource --------------------------------------------------------------
    class RKResource : Object
    {
    Array<RKTree>* trees;
    Array<UXData>* freeStrings;  // rsrc_gaddr(R_STRING, i) — referenced by nothing
    Array<RKBitblk>* freeImages; // rsrc_gaddr(R_IMAGE, i) — likewise
    Array<RKForm>* forms;        // the multi-variant forms; a tree in none is its own `any` form
    bool bigEndian;              // classic 68000 GEM fidelity
    bool packedCoords;           // char/pixel packing on write
    bool embedIcons;             // embed PAM vs reference an external path
    i32 charWidth, charHeight;

    void init(void)
        {
        trees = new Array();
        freeStrings = new Array();
        freeImages = new Array();
        forms = new Array();
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

    i32 indexOfTree(RKTree* t)
        {
        for (i32 i = (i32)0; i < self.treeCount(); i = i + (i32)1)
            {
            if (self.treeAt(i) == t)
                {
                return i;
                }
            }
        return (i32)-1;
        }
    i32 formCount(void)
        {
        return (i32)forms.count();
        }
    RKForm* formAt(i32 i)
        { return (RKForm* ?)forms.get((u32)i);
        }
    // The form a tree is a layout of, or 0 for a tree that stands alone.
    RKForm* formOf(RKTree* t)
        {
        for (i32 i = (i32)0; i < self.formCount(); i = i + (i32)1)
            {
            RKForm* f = self.formAt(i);
            if (f.variantFor(t) != (RKVariant*)0)
                {
                return f;
                }
            }
        return (RKForm*)0;
        }
    RKForm* formById(i32 formId)
        {
        for (i32 i = (i32)0; i < self.formCount(); i = i + (i32)1)
            {
            RKForm* f = self.formAt(i);
            if (f.formId == formId)
                {
                return f;
                }
            }
        return (RKForm*)0;
        }

    // A new layout of `from`'s form, for `klass` at `orient`, seeded as a one-time copy of `from`.
    // The first time a tree gains a sibling layout it becomes a form: it is its desktop layout, and
    // every object in it gets a logical id, which the copy carries -- that is what lets one set of
    // connections bind in both (UXNB-V2 sections 3 and 7).  Returns the new tree, or 0 if the form
    // already has that layout (or the orientation is meaningless: the desktop has none).
    RKTree* addVariant(RKTree* from, i32 klass, i32 orient)
        {
        if (from == (RKTree*)0 || from.root == (RKObject*)0 || self.indexOfTree(from) < (i32)0)
            {
            return (RKTree*)0;
            }
        if ((klass == (i32)RKV_DESKTOP || klass == (i32)RKV_ANY) && orient != (i32)RKV_ORIENT_NONE)
            {
            return (RKTree*)0;
            }
        RKForm* f = self.formOf(from);
        if (f == (RKForm*)0)
            {
            f = new RKForm();
            f.formId = self.indexOfTree(from);
            f.name = from.name;
            RKVariant* first = new RKVariant();
            first.klass = (i32)RKV_DESKTOP;
            first.tree = from;
            f.variants.add(first);
            forms.add(f);
            }
        if (f.find(klass, orient) != (RKVariant*)0)
            {
            return (RKTree*)0;
            }
        // identity for everything the seed has that lacks it
        i32 next = f.nextLogicalId();
        Array<RKObject>* all = from.allObjects();
        for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
            {
            RKObject* o = (RKObject* ?)all.get(k);
            if (o.logicalId == (i32)0)
                {
                o.logicalId = next;
                next = next + (i32)1;
                }
            }
        RKTree* t = new RKTree();
        t.setNameJoined(f.name, RKResource.variantSuffix(klass, orient));
        t.kind = from.kind;
        t.root = from.root.deepCopy();
        self.addTree(t);
        RKVariant* v = new RKVariant();
        v.klass = klass;
        v.orient = orient;
        v.tree = t;
        f.variants.add(v);
        return t;
        }

    // What a variant's tree is called after its form: MAIN_PHONE, MAIN_TABLET_L, ...  The names only
    // have to be distinct, for source export; the loader finds variants through the chunk.
    static u8* variantSuffix(i32 klass, i32 orient)
        {
        if (klass == (i32)RKV_PHONE)
            {
            return orient == (i32)RKV_ORIENT_PORTRAIT ? (u8*)"_PHONE_P"
                 : (orient == (i32)RKV_ORIENT_LANDSCAPE ? (u8*)"_PHONE_L" : (u8*)"_PHONE");
            }
        if (klass == (i32)RKV_TABLET)
            {
            return orient == (i32)RKV_ORIENT_PORTRAIT ? (u8*)"_TABLET_P"
                 : (orient == (i32)RKV_ORIENT_LANDSCAPE ? (u8*)"_TABLET_L" : (u8*)"_TABLET");
            }
        if (klass == (i32)RKV_DESKTOP)
            {
            return (u8*)"_DESKTOP";
            }
        return (u8*)"_ANY";
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
