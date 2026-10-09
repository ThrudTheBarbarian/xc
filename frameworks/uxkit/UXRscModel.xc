// UXRscModel.xc — the in-memory GEM resource model: what a .rsc document holds.
//
// Shared by the rsc loader (UXRscLoad, which builds UXKit views from it) and by Rocks, the
// designer (which edits it).  One model and one reader/writer pair (UXRscRead, UXRscWrite), so
// what the designer shows and what an app loads cannot disagree about the file.  Ported from
// Rocks' GModel.[hm] by way of its RKModel.xc.
//
// A resource is a list of named trees; each tree is a root object with nested
// children.  The classic OBJECT fields are kept, plus the XT GEM extended
// widget types, with type-specific payloads hanging off the node (string /
// TEDINFO / box colour word / icon / bit form).  The flat classic linked
// layout — next/head/tail — is rebuilt only at write time, by flatten().
//
// Ported deliberately, not mechanically.  Two kinds of thing were dropped:
// the NSImage caches (rendering is UXKit's job), and Foundation container types, which
// become Array and plain byte buffers.  Everything that affects FILE FIDELITY
// is kept, including the fields nothing here interprets: a foreign
// editor's extended-type byte, an imported CICONBLK's original bytes, the
// classic mono icon data.  Those exist so that reading someone else's resource
// and writing it back does not quietly destroy what we did not understand.
//
// See apps/rocks/RSC-FORMAT.md for the on-disk layout.
#import "Array.xc"
#import "Data.xc"
#import "UXString.xc"

// ---- object types: classic, then the XT GEM themed extensions ---------
#define UXR_T_BOX 20
#define UXR_T_TEXT 21
#define UXR_T_BOXTEXT 22
#define UXR_T_IMAGE 23
#define UXR_T_USERDEF 24
#define UXR_T_IBOX 25
#define UXR_T_BUTTON 26
#define UXR_T_BOXCHAR 27
#define UXR_T_STRING 28
#define UXR_T_FTEXT 29
#define UXR_T_FBOXTEXT 30
#define UXR_T_ICON 31
#define UXR_T_TITLE 32
#define UXR_T_CICONBLK 33 // the standard Atari colour icon (a CICONBLK)
#define UXR_T_CHECKBOX 40 // XT GEM extensions from here down
#define UXR_T_RADIO 41
#define UXR_T_POPUP 42
#define UXR_T_FIELD 43
#define UXR_T_CICON 44 // the XT colour icon: an RGBA PAM

// ---- flags -----------------------------------------------------------------
#define UXR_F_NONE $0000
#define UXR_F_SELECTABLE $0001
#define UXR_F_DEFAULT $0002
#define UXR_F_EXIT $0004
#define UXR_F_EDITABLE $0008
#define UXR_F_RBUTTON $0010
#define UXR_F_LASTOB $0020
#define UXR_F_TOUCHEXIT $0040
#define UXR_F_HIDETREE $0080
#define UXR_F_INDIRECT $0100
#define UXR_F_CANCEL $0200   // Esc fires this object
#define UXR_F_MOVEABLE $0400 // on the ROOT: the dialog is movable
#define UXR_F_SUBMENU $0800

// ---- state -----------------------------------------------------------------
// Layout variants (UXNB-V2 sections 1 and 10): a variant's form-factor class and orientation.  The
// registry's own numbers, so they go into the chunk as they are; test_rkforms checks them against
// UXKit's UX_FORM_* / UX_ORIENT_*, which the loader reads them with.
#define UXR_V_ANY 0
#define UXR_V_DESKTOP 1
#define UXR_V_TABLET 2
#define UXR_V_PHONE 3
#define UXR_V_ORIENT_NONE 0
#define UXR_V_ORIENT_PORTRAIT 1
#define UXR_V_ORIENT_LANDSCAPE 2

#define UXR_S_NORMAL $0000
#define UXR_S_SELECTED $0001
#define UXR_S_CROSSED $0002
#define UXR_S_CHECKED $0004
#define UXR_S_DISABLED $0008
#define UXR_S_OUTLINED $0010
#define UXR_S_SHADOWED $0020
#define UXR_S_WHITEBAK $0040 // bits 8-14 then hold the shortcut char index

// ---- tree kinds ------------------------------------------------------------
#define UXR_K_DIALOG 0
#define UXR_K_MENU 1
#define UXR_K_FREE 2

// ---- box corner rounding: ob_type high byte, bits 4-7, one bit per corner --
#define UXR_ROUND_TL $10
#define UXR_ROUND_TR $20
#define UXR_ROUND_BR $40
#define UXR_ROUND_BL $80
#define UXR_ROUND_ALL $F0

// ---- the GEM 16-bit colour word -------------------------------------------
// border(15-12) text(11-8) textMode(7: 1=replace, 0=transparent) fill(6-4) inside(3-0)
class UXRscColor : Object
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
    UXRscColor* copy(void)
        {
        return UXRscColor.unpack(self.pack());
        }
    static UXRscColor* unpack(u16 raw)
        {
        UXRscColor* c = new UXRscColor();
        c.border = ((i32)raw >> (i32)12) & (i32)$F;
        c.text = ((i32)raw >> (i32)8) & (i32)$F;
        c.replace = ((i32)raw & (i32)$80) != (i32)0;
        c.pattern = ((i32)raw >> (i32)4) & (i32)7;
        c.inside = (i32)raw & (i32)$F;
        return c;
        }
    }

    // ---- payloads --------------------------------------------------------------
    class UXRscTedinfo : Object
    {
    u8* text;  // te_ptext
    u8* tmplt; // te_ptmplt
    u8* valid; // te_pvalid
    i32 font;  // 3 = large, 5 = small
    i32 fontId;
    i32 just; // 0 left, 1 right, 2 centre
    UXRscColor* color;
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
        color = new UXRscColor();
        fontsize = (i32)0;
        thickness = (i32)0;
        }
    UXRscTedinfo* copy(void)
        {
        UXRscTedinfo* c = new UXRscTedinfo();
        c.text = text;
        c.tmplt = tmplt;
        c.valid = valid;
        c.font = font;
        c.fontId = fontId;
        c.just = just;
        c.color = color != (UXRscColor*)0 ? color.copy() : new UXRscColor();
        c.fontsize = fontsize;
        c.thickness = thickness;
        return c;
        }
    }

    class UXRscBox : Object
    {
    u8 character;  // a G_BOXCHAR's char (0 = none)
    i32 thickness; // border thickness; negative = drawn inside
    UXRscColor* color;
    void init(void)
        {
        character = (u8)0;
        thickness = (i32)1;
        color = new UXRscColor();
        }
    UXRscBox* copy(void)
        {
        UXRscBox* c = new UXRscBox();
        c.character = character;
        c.thickness = thickness;
        c.color = color != (UXRscColor*)0 ? color.copy() : new UXRscColor();
        return c;
        }
    }

    // A classic monochrome bit form (BITBLK): 1bpp, wb bytes per row, hl rows.
    // Set bits draw in VDI pen `color`; clear bits are transparent — a BITBLK has
    // no mask.  Carried by G_IMAGE objects and by the free-image table.
    class UXRscBitblk : Object
    {
    Data* data; // wb * hl bytes
    i32 wb, hl, x, y, color;
    void init(void)
        {
        data = (Data*)0;
        wb = (i32)0;
        hl = (i32)0;
        x = (i32)0;
        y = (i32)0;
        color = (i32)1;
        }
    UXRscBitblk* copy(void)
        {
        UXRscBitblk* c = new UXRscBitblk();
        c.data = data;
        c.wb = wb;
        c.hl = hl;
        c.x = x;
        c.y = y;
        c.color = color;
        return c;
        }
    }

    class UXRscIcon : Object
    {
    bool isColor;
    u8* label;
    Data* pam;      // embedded P7 PAM bytes
    Data* ciconRaw; // the original CICONBLK, verbatim, for byte-faithful re-export
    Data* selPam;   // the SELECTED form, if the file had one
    u8* externalPath; // reference instead of embedding
    Data* monoData; // classic ICONBLK ib_pdata, preserved from an import
    Data* monoMask; // ib_pmask
    i32 iconChar, charX, charY;
    i32 textX, textY, textW, textH;
    i32 iconX, iconY, iconW, iconH;
    void init(void)
        {
        isColor = false;
        label = (u8*)"";
        pam = (Data*)0;
        ciconRaw = (Data*)0;
        selPam = (Data*)0;
        externalPath = (u8*)0;
        monoData = (Data*)0;
        monoMask = (Data*)0;
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
    UXRscIcon* copy(void)
        {
        UXRscIcon* c = new UXRscIcon();
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
    class UXRscObject : Object
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

    UXRscTedinfo* ted;
    UXRscBox* box;
    UXRscIcon* icon;
    UXRscBitblk* bitblk;
    Array<UXRscObject>* children;
    // A container CLASS (a scroll/split/tab view) holds children though its GEM type says otherwise.
    // The loader nests by the model tree, so it needs nothing; the editor nests by GEOMETRY and reads
    // this, set for it when the class is known.
    bool holdsChildren;

    void init(void)
        {
        type = (i32)UXR_T_BOX;
        extType = (u8)0;
        legacyExtType = (u8)0;
        flags = (i32)UXR_F_NONE;
        state = (i32)UXR_S_NORMAL;
        x = (i32)0;
        y = (i32)0;
        w = (i32)0;
        h = (i32)0;
        name = (u8*)0;
        text = (u8*)0;
        logicalId = (i32)0;
        ted = (UXRscTedinfo*)0;
        box = (UXRscBox*)0;
        icon = (UXRscIcon*)0;
        bitblk = (UXRscBitblk*)0;
        children = new Array();
        holdsChildren = false;
        }

    static UXRscObject* make(i32 type, i32 x, i32 y, i32 w, i32 h)
        {
        UXRscObject* o = new UXRscObject();
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
        return type == (i32)UXR_T_STRING || type == (i32)UXR_T_BUTTON ||
               type == (i32)UXR_T_TITLE || type == (i32)UXR_T_TEXT ||
               type == (i32)UXR_T_CHECKBOX || type == (i32)UXR_T_RADIO;
        }
    bool hasTedinfo(void)
        {
        return UXRscObject.typeHasTedinfo(type);
        }
    // The same question about a bare type, so the schema can ask it without an
    // object.  ONE list: a second copy of this in Rocks' property schema drifted immediately —
    // it omitted G_FIELD, so text fields, the one type the feature was asked
    // for, were never offered alignment.
    static bool typeHasTedinfo(i32 t)
        {
        return t == (i32)UXR_T_TEXT || t == (i32)UXR_T_BOXTEXT ||
               t == (i32)UXR_T_FTEXT || t == (i32)UXR_T_FBOXTEXT ||
               t == (i32)UXR_T_FIELD;
        }
    bool hasBox(void)
        {
        return type == (i32)UXR_T_BOX || type == (i32)UXR_T_IBOX ||
               type == (i32)UXR_T_BOXCHAR || type == (i32)UXR_T_BOXTEXT ||
               type == (i32)UXR_T_FBOXTEXT;
        }
    bool hasIcon(void)
        {
        return type == (i32)UXR_T_ICON || type == (i32)UXR_T_CICON || type == (i32)UXR_T_CICONBLK;
        }
    bool hasBitblk(void)
        {
        return type == (i32)UXR_T_IMAGE;
        }
    bool canHaveChildren(void)
        {
        return type == (i32)UXR_T_BOX || type == (i32)UXR_T_IBOX ||
               type == (i32)UXR_T_BOXCHAR || type == (i32)UXR_T_TITLE;
        }
    // The type says it, or the editor marked it a container class.
    bool canHoldChildren(void)
        {
        return self.canHaveChildren() || holdsChildren;
        }

    // Give a freshly made object the payload its type needs, so nothing
    // downstream has to null-check what the type guarantees.
    void seedPayload(void)
        {
        if (self.hasTedinfo() && ted == (UXRscTedinfo*)0)
            {
            ted = new UXRscTedinfo();
            }
        if (self.hasBox() && box == (UXRscBox*)0)
            {
            box = new UXRscBox();
            }
        if (self.hasIcon() && icon == (UXRscIcon*)0)
            {
            icon = new UXRscIcon();
            }
        if (self.hasBitblk() && bitblk == (UXRscBitblk*)0)
            {
            bitblk = new UXRscBitblk();
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
    UXRscObject* childAt(i32 i)
        { return (UXRscObject* ?)children.get((u16)i);
        }
    void addChild(UXRscObject* c)
        {
        if (c != (UXRscObject*)0)
            {
            children.add(c);
            }
        }

    // The direct parent of `target` within this subtree, or 0.
    UXRscObject* parentOf(UXRscObject* target)
        {
        for (i32 i = (i32)0; i < self.childCount(); i = i + (i32)1)
            {
            UXRscObject* c = self.childAt(i);
            if (c == target)
                {
                return self;
                }
            UXRscObject* deeper = c.parentOf(target);
            if (deeper != (UXRscObject*)0)
                {
                return deeper;
                }
            }
        return (UXRscObject*)0;
        }

    // Pre-order walk, appending every node in this subtree to `out`.
    void collect(Array<UXRscObject>* out)
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
    UXRscObject* deepCopy(void)
        {
        UXRscObject* c = new UXRscObject();
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
        if (ted != (UXRscTedinfo*)0)
            {
            c.ted = ted.copy();
            }
        if (box != (UXRscBox*)0)
            {
            c.box = box.copy();
            }
        if (icon != (UXRscIcon*)0)
            {
            c.icon = icon.copy();
            }
        if (bitblk != (UXRscBitblk*)0)
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
    class UXRscFlatNode : Object
    {
    UXRscObject* obj;
    i32 next, head, tail;
    void init(void)
        {
        obj = (UXRscObject*)0;
        next = (i32)-1;
        head = (i32)-1;
        tail = (i32)-1;
        }
    }

    // ---- tree ------------------------------------------------------------------
    class UXRscTree : Object
    {
    u8* name;
    i32 kind;
    UXRscObject* root;
    Data* nameStore; // owns `name`'s bytes when the name was made here rather than read

    void init(void)
        {
        name = (u8*)"";
        kind = (i32)UXR_K_DIALOG;
        root = (UXRscObject*)0;
        nameStore = (Data*)0;
        }

    // Name this tree `base` + `suffix` ("MAIN" + "_PHONE_L"), owning the bytes.
    void setNameJoined(u8* base, u8* suffix)
        {
        Data* d = UXStr.toData(base != (u8*)0 ? base : (u8*)"");
        d.appendBytes(suffix, UXRscTree.len(suffix));
        d.appendByte((u8)0);
        nameStore = d;
        name = UXStr.cstr(d);
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

    UXRscObject* parentOf(UXRscObject* node)
        {
        if (root == (UXRscObject*)0 || node == root)
            {
            return (UXRscObject*)0;
            }
        return root.parentOf(node);
        }
    Array<UXRscObject>* allObjects(void)
        {
        Array<UXRscObject>* out = new Array();
        if (root != (UXRscObject*)0)
            {
            root.collect(out);
            }
        return out;
        }
    // Screen coordinates: a child's x/y are relative to its parent.
    bool absoluteOriginOf(UXRscObject* node, i32* ox, i32* oy)
        {
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        UXRscObject* cur = node;
        while (cur != (UXRscObject*)0)
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
        return kind == (i32)UXR_K_MENU;
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
        if (root == (UXRscObject*)0)
            {
            return (i32)0;
            }
        Array<UXRscObject>* all = self.allObjects(); // pre-order, root first
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
            UXRscObject* o = (UXRscObject* ?)all.get((u32)i);
            i32 x = (i32)0;
            i32 y = (i32)0;
            self.absoluteOriginOf(o, &x, &y);
            ax[i] = x;
            ay[i] = y;
            UXRscObject* p = self.parentOf(o);
            oldParent[i] = (i32)-1;
            for (i32 k = (i32)0; k < n; k = k + (i32)1)
                {
                if ((UXRscObject* ?)all.get((u32)k) == p)
                    {
                    oldParent[i] = k;
                    }
                }
            }
        i32 changed = (i32)0;
        newParent[0] = (i32)-1;
        for (i32 i = (i32)1; i < n; i = i + (i32)1)
            {
            UXRscObject* o = (UXRscObject* ?)all.get((u32)i);
            i32 oArea = o.w * o.h;
            i32 best = (i32)0;
            i32 bestArea = root.w * root.h;
            for (i32 k = (i32)0; k < n; k = k + (i32)1)
                {
                UXRscObject* p = (UXRscObject* ?)all.get((u32)k);
                if (k == i || !p.canHoldChildren())
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
            ((UXRscObject* ?)all.get((u32)i)).children = new Array();
            }
        for (i32 i = (i32)1; i < n; i = i + (i32)1)
            {
            UXRscObject* o = (UXRscObject* ?)all.get((u32)i);
            ((UXRscObject* ?)all.get((u32)newParent[i])).addChild(o);
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
    class UXRscVariant : Object
    {
    i32 klass;  // UXR_V_DESKTOP / _TABLET / _PHONE / _ANY
    i32 orient; // UXR_V_ORIENT_*; NONE on the desktop
    UXRscTree* tree;
    void init(void)
        {
        klass = (i32)UXR_V_ANY;
        orient = (i32)UXR_V_ORIENT_NONE;
        tree = (UXRscTree*)0;
        }
    }

    class UXRscForm : Object
    {
    i32 formId; // what the app loads it by: the first tree's index, so a v1 app's constant still works
    u8* name;
    Array<UXRscVariant>* variants;
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
    UXRscVariant* variantAt(i32 i)
        { return (UXRscVariant* ?)variants.get((u32)i);
        }
    UXRscVariant* find(i32 klass, i32 orient)
        {
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            UXRscVariant* v = self.variantAt(i);
            if (v.klass == klass && v.orient == orient)
                {
                return v;
                }
            }
        return (UXRscVariant*)0;
        }
    UXRscVariant* variantFor(UXRscTree* t)
        {
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            UXRscVariant* v = self.variantAt(i);
            if (v.tree == t)
                {
                return v;
                }
            }
        return (UXRscVariant*)0;
        }
    // The next unused logical id across every variant (ids are never reused within a form).
    i32 nextLogicalId(void)
        {
        i32 hi = (i32)0;
        for (i32 i = (i32)0; i < self.variantCount(); i = i + (i32)1)
            {
            Array<UXRscObject>* all = self.variantAt(i).tree.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                i32 id = ((UXRscObject* ?)all.get(k)).logicalId;
                if (id > hi)
                    {
                    hi = id;
                    }
                }
            }
        return hi + (i32)1;
        }
    }

    // ---- the rsc graph (UXNB v3, docs/UXNB-V2.md section 11) ---------------------
    // What the trees do not say: which class a control really is, the non-view objects a form
    // loads with (controllers), and the outlet/action wiring between them.  Kept beside the trees,
    // not in them, because a form's controls exist once per layout theme and the graph does not.
    #define UXR_REF_VIEW 0     // a = tree, b = obj: single-variant forms only
    #define UXR_REF_TOP 1      // a = the top object's id
    #define UXR_REF_OWNER 2    // File's Owner
    #define UXR_REF_FIRSTR 3   // First Responder
    #define UXR_REF_LOGICAL 4  // a = formId, b = logicalId
    #define UXR_CONN_OUTLET 0  // src.member = dst
    #define UXR_CONN_ACTION 1  // src (a control) fires dst.member
    class UXRscRef : Object
    {
    i32 space;
    i32 a;
    i32 b;
    static UXRscRef* make(i32 space, i32 a, i32 b)
        {
        UXRscRef* r = new UXRscRef();
        r.space = space;
        r.a = a;
        r.b = b;
        return r;
        }
    bool same(UXRscRef* o)
        {
        return o != (UXRscRef*)0 && o.space == space && o.a == a && o.b == b;
        }
    }

    // A control whose class is not the one its GEM type implies (a G_USERDEF that is a WaveformView).
    class UXRscClassOverride : Object
    {
    UXRscRef* view;
    u8* cls;
    }

    // A non-view object the form instantiates: IB's "Object" with a custom class.
    class UXRscTopObject : Object
    {
    i32 id;
    u8* cls;
    u8* label; // the designer's name for it; "" = none
    }

    // One outlet or action.  `scope` is the set of layout themes it binds in: bit klass*3+orient,
    // 0 = every theme.  One member may carry several connections with disjoint scopes.
    class UXRscConnection : Object
    {
    i32 kind; // UXR_CONN_*
    UXRscRef* src;
    UXRscRef* dst;
    u8* member;
    u32 scope;
    static u32 themeBit(i32 klass, i32 orient)
        {
        return (u32)1 << (u32)(klass * (i32)3 + orient);
        }
    bool inScope(i32 klass, i32 orient)
        {
        return scope == (u32)0 || (scope & UXRscConnection.themeBit(klass, orient)) != (u32)0;
        }
    }

    // One setting of a control that has no OBJECT field for it: a UXKit view's (a slider's range, a
    // segmented control's segments), kept in the ATTR section (docs/UXNB-V2.md section 11.3).  The
    // value is text; `theme` is a theme bit for a value one layout varies, or UXR_ATTR_SHARED.
    #define UXR_ATTR_SHARED $FFFF
    class UXRscAttr : Object
    {
    i32 formId;
    i32 logicalId;
    i32 theme;
    u8* key;
    u8* value;
    }

    // A v3 extension section kept verbatim: a tag this build does not interpret still goes back out.
    class UXRscExtSection : Object
    {
    u32 tag;
    Data* body;
    }

    // ---- resource --------------------------------------------------------------
    class UXRscDoc : Object
    {
    Array<UXRscTree>* trees;
    Array<Data>* freeStrings;  // rsrc_gaddr(R_STRING, i) — referenced by nothing
    Array<UXRscBitblk>* freeImages; // rsrc_gaddr(R_IMAGE, i) — likewise
    Array<UXRscForm>* forms;        // the multi-variant forms; a tree in none is its own `any` form
    Array<UXRscClassOverride>* classOverrides;
    Array<UXRscTopObject>* topObjects;
    Array<UXRscConnection>* connections;
    Array<UXRscExtSection>* extSections;
    Array<UXRscAttr>* attrs;
    u8* ownerClass; // File's Owner's class, for the designer to list its outlets and actions; "" = unset
    i32 mainMenu;   // the index of the tree that is the application's MAIN menu, or -1 (the app delegate's
                    // menu slot: the document names which of its menus fills it; swap by changing this)
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
        classOverrides = new Array();
        topObjects = new Array();
        connections = new Array();
        extSections = new Array();
        attrs = new Array();
        ownerClass = (u8*)"";
        mainMenu = (i32)-1;
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
    UXRscTree* treeAt(i32 i)
        { return (UXRscTree* ?)trees.get((u16)i);
        }
    void addTree(UXRscTree* t)
        {
        if (t != (UXRscTree*)0)
            {
            trees.add(t);
            }
        }

    i32 indexOfTree(UXRscTree* t)
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
    UXRscForm* formAt(i32 i)
        { return (UXRscForm* ?)forms.get((u32)i);
        }
    // The document's MAIN menu (the one the app installs), or 0.  A menu is a tree; the app delegate
    // has a known menu slot and the document names which tree fills it (Cocoa's NSApplication.mainMenu).
    UXRscTree* mainMenuTree(void)
        {
        return mainMenu >= (i32)0 && mainMenu < self.treeCount() ? self.treeAt(mainMenu) : (UXRscTree*)0;
        }
    void setMainMenuTree(UXRscTree* t)
        {
        mainMenu = self.indexOfTree(t);
        }
    // The form a tree is a layout of, or 0 for a tree that stands alone.
    UXRscForm* formOf(UXRscTree* t)
        {
        for (i32 i = (i32)0; i < self.formCount(); i = i + (i32)1)
            {
            UXRscForm* f = self.formAt(i);
            if (f.variantFor(t) != (UXRscVariant*)0)
                {
                return f;
                }
            }
        return (UXRscForm*)0;
        }
    UXRscForm* formById(i32 formId)
        {
        for (i32 i = (i32)0; i < self.formCount(); i = i + (i32)1)
            {
            UXRscForm* f = self.formAt(i);
            if (f.formId == formId)
                {
                return f;
                }
            }
        return (UXRscForm*)0;
        }

    // A new layout of `from`'s form, for `klass` at `orient`, seeded as a one-time copy of `from`.
    // The first time a tree gains a sibling layout it becomes a form: it is its desktop layout, and
    // every object in it gets a logical id, which the copy carries -- that is what lets one set of
    // connections bind in both (UXNB-V2 sections 3 and 7).  Returns the new tree, or 0 if the form
    // already has that layout (or the orientation is meaningless: the desktop has none).
    UXRscTree* addVariant(UXRscTree* from, i32 klass, i32 orient)
        {
        if (from == (UXRscTree*)0 || from.root == (UXRscObject*)0 || self.indexOfTree(from) < (i32)0)
            {
            return (UXRscTree*)0;
            }
        if ((klass == (i32)UXR_V_DESKTOP || klass == (i32)UXR_V_ANY) && orient != (i32)UXR_V_ORIENT_NONE)
            {
            return (UXRscTree*)0;
            }
        UXRscForm* f = self.formOf(from);
        if (f == (UXRscForm*)0)
            {
            f = new UXRscForm();
            f.formId = self.indexOfTree(from);
            f.name = from.name;
            UXRscVariant* first = new UXRscVariant();
            first.klass = (i32)UXR_V_DESKTOP;
            first.tree = from;
            f.variants.add(first);
            forms.add(f);
            }
        if (f.find(klass, orient) != (UXRscVariant*)0)
            {
            return (UXRscTree*)0;
            }
        // identity for everything the seed has that lacks it
        i32 next = f.nextLogicalId();
        Array<UXRscObject>* all = from.allObjects();
        for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
            {
            UXRscObject* o = (UXRscObject* ?)all.get(k);
            if (o.logicalId == (i32)0)
                {
                o.logicalId = next;
                next = next + (i32)1;
                }
            }
        UXRscTree* t = new UXRscTree();
        t.setNameJoined(f.name, UXRscDoc.variantSuffix(klass, orient));
        t.kind = from.kind;
        t.root = from.root.deepCopy();
        self.addTree(t);
        UXRscVariant* v = new UXRscVariant();
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
        if (klass == (i32)UXR_V_PHONE)
            {
            return orient == (i32)UXR_V_ORIENT_PORTRAIT ? (u8*)"_PHONE_P"
                 : (orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (u8*)"_PHONE_L" : (u8*)"_PHONE");
            }
        if (klass == (i32)UXR_V_TABLET)
            {
            return orient == (i32)UXR_V_ORIENT_PORTRAIT ? (u8*)"_TABLET_P"
                 : (orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (u8*)"_TABLET_L" : (u8*)"_TABLET");
            }
        if (klass == (i32)UXR_V_DESKTOP)
            {
            return (u8*)"_DESKTOP";
            }
        return (u8*)"_ANY";
        }

    // ---- attributes ------------------------------------------------------------------------------
    // A control's attribute for a theme: that theme's own value if it varies it, else the shared
    // one, else 0.  `theme` is a theme bit (UXRscConnection.themeBit), or UXR_ATTR_SHARED.
    u8* attrIn(i32 formId, i32 logicalId, i32 theme, u8* key)
        {
        u8* shared = (u8*)0;
        for (u32 i = (u32)0; i < attrs.count(); i = i + (u32)1)
            {
            UXRscAttr* a = (UXRscAttr* ?)attrs.get(i);
            if (a.formId != formId || a.logicalId != logicalId || !UXRscDoc.seq(a.key, key))
                {
                continue;
                }
            if (a.theme == theme && theme != (i32)UXR_ATTR_SHARED)
                {
                return a.value;
                }
            if (a.theme == (i32)UXR_ATTR_SHARED)
                {
                shared = a.value;
                }
            }
        return shared;
        }
    // Set it (0 removes it).
    void setAttrIn(i32 formId, i32 logicalId, i32 theme, u8* key, u8* value)
        {
        for (u32 i = (u32)0; i < attrs.count(); i = i + (u32)1)
            {
            UXRscAttr* a = (UXRscAttr* ?)attrs.get(i);
            if (a.formId == formId && a.logicalId == logicalId && a.theme == theme && UXRscDoc.seq(a.key, key))
                {
                if (value == (u8*)0)
                    {
                    attrs.removeAt(i);
                    }
                else
                    {
                    a.value = value;
                    }
                return;
                }
            }
        if (value == (u8*)0)
            {
            return;
            }
        UXRscAttr* a = new UXRscAttr();
        a.formId = formId;
        a.logicalId = logicalId;
        a.theme = theme;
        a.key = key;
        a.value = value;
        attrs.add(a);
        }
    // ---- autoresizing ----------------------------------------------------------------------------
    // How a control follows its container when that is resized, kept as the "autoresize" attribute
    // of the control in ONE layout (geometry is each layout's own, so the value is never shared).
    // The value is letters for UXView's mask bits: L R T B for the margins kept (UX_ANCHOR_LEFT 1,
    // RIGHT 2, TOP 4, BOTTOM 8), W H for the sizes that stretch (UX_FLEX_WIDTH 16, HEIGHT 32).  None,
    // or "", is pinned to the top left.
    i32 autoresizeOf(UXRscTree* t, UXRscObject* o)
        {
        if (o.logicalId == (i32)0)
            {
            return (i32)0;
            }
        return UXRscDoc.maskFrom(self.attrIn(self.formIdOf(t), o.logicalId, (i32)self.themeOf(t), (u8*)"autoresize"));
        }
    void setAutoresizeOf(UXRscTree* t, UXRscObject* o, i32 mask)
        {
        self.setAttrIn(self.formIdOf(t), self.ensureLogicalId(t, o), (i32)self.themeOf(t), (u8*)"autoresize",
                       mask != (i32)0 ? UXRscDoc.maskLetters(mask) : (u8*)0);
        }
    // The theme the layout `t` was drawn for: its variant's form factor and orientation, or `any`.
    u32 themeOf(UXRscTree* t)
        {
        UXRscForm* f = self.formOf(t);
        UXRscVariant* v = f != (UXRscForm*)0 ? f.variantFor(t) : (UXRscVariant*)0;
        if (v == (UXRscVariant*)0)
            {
            return UXRscConnection.themeBit((i32)UXR_V_ANY, (i32)UXR_V_ORIENT_NONE);
            }
        return UXRscConnection.themeBit(v.klass, v.orient);
        }
    static i32 maskFrom(u8* s)
        {
        i32 m = (i32)0;
        if (s == (u8*)0)
            {
            return m;
            }
        for (i32 i = (i32)0; s[i] != (u8)0; i = i + (i32)1)
            {
            i32 b = UXRscDoc.maskBit(s[i]);
            m = m | b;
            }
        return m;
        }
    // The letters for a mask, in the order L R T B W H; "" for 0.
    static u8* maskLetters(i32 m)
        {
        u8* letters = (u8*)"LRTBWH";
        u8* s = new u8[(u32)7];
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < (i32)6; i = i + (i32)1)
            {
            if ((m & ((i32)1 << i)) != (i32)0)
                {
                s[n] = letters[i];
                n = n + (i32)1;
                }
            }
        s[n] = (u8)0;
        return s;
        }
    static i32 maskBit(u8 c)
        {
        u8* letters = (u8*)"LRTBWH";
        for (i32 i = (i32)0; i < (i32)6; i = i + (i32)1)
            {
            if (letters[i] == c)
                {
                return (i32)1 << i;
                }
            }
        return (i32)0;
        }

    // For a control in a tree: the shared value (the control gets a logical id when set).
    u8* attrOf(UXRscTree* t, UXRscObject* o, u8* key)
        {
        return o.logicalId != (i32)0 ? self.attrIn(self.formIdOf(t), o.logicalId, (i32)UXR_ATTR_SHARED, key) : (u8*)0;
        }
    void setAttrOf(UXRscTree* t, UXRscObject* o, u8* key, u8* value)
        {
        self.setAttrIn(self.formIdOf(t), self.ensureLogicalId(t, o), (i32)UXR_ATTR_SHARED, key, value);
        }
    static bool seq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && a[i] == b[i])
            {
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    // ---- the rsc graph, for an editor ---------------------------------------------------------
    // The id a form is loaded by: its form's, or for a tree in no form the tree's own index.
    i32 formIdOf(UXRscTree* t)
        {
        UXRscForm* f = self.formOf(t);
        return f != (UXRscForm*)0 ? f.formId : self.indexOfTree(t);
        }
    // Give `o` (in `t`) a logical id if it has none, unique across every layout of its form.
    i32 ensureLogicalId(UXRscTree* t, UXRscObject* o)
        {
        if (o.logicalId != (i32)0)
            {
            return o.logicalId;
            }
        UXRscForm* f = self.formOf(t);
        i32 next = (i32)1;
        if (f != (UXRscForm*)0)
            {
            next = f.nextLogicalId();
            }
        else
            {
            Array<UXRscObject>* all = t.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                i32 id = ((UXRscObject* ?)all.get(k)).logicalId;
                if (id >= next)
                    {
                    next = id + (i32)1;
                    }
                }
            }
        o.logicalId = next;
        return next;
        }
    // A ref to a control that holds in every layout of its form: by logical id (assigned if need be).
    UXRscRef* refFor(UXRscTree* t, UXRscObject* o)
        {
        i32 id = self.ensureLogicalId(t, o);
        return UXRscRef.make((i32)UXR_REF_LOGICAL, self.formIdOf(t), id);
        }
    // The class a control is overridden to, or 0.
    u8* classOf(UXRscTree* t, UXRscObject* o)
        {
        if (o.logicalId == (i32)0)
            {
            return (u8*)0;
            }
        UXRscRef* r = UXRscRef.make((i32)UXR_REF_LOGICAL, self.formIdOf(t), o.logicalId);
        for (u32 i = (u32)0; i < classOverrides.count(); i = i + (u32)1)
            {
            UXRscClassOverride* co = (UXRscClassOverride* ?)classOverrides.get(i);
            if (co.view.same(r))
                {
                return co.cls;
                }
            }
        return (u8*)0;
        }
    // Set a control's class; null or "" goes back to the one its type implies.
    void setClassOf(UXRscTree* t, UXRscObject* o, u8* cls)
        {
        UXRscRef* r = self.refFor(t, o);
        for (u32 i = (u32)0; i < classOverrides.count(); i = i + (u32)1)
            {
            UXRscClassOverride* co = (UXRscClassOverride* ?)classOverrides.get(i);
            if (co.view.same(r))
                {
                if (cls == (u8*)0 || cls[0] == (u8)0)
                    {
                    classOverrides.removeAt(i);
                    }
                else
                    {
                    co.cls = cls;
                    }
                return;
                }
            }
        if (cls != (u8*)0 && cls[0] != (u8)0)
            {
            UXRscClassOverride* co = new UXRscClassOverride();
            co.view = r;
            co.cls = cls;
            classOverrides.add(co);
            }
        }
    // A new top-level object (IB's "Object"), with the next free id.
    UXRscTopObject* addTopObject(u8* cls, u8* label)
        {
        i32 id = (i32)1;
        for (u32 i = (u32)0; i < topObjects.count(); i = i + (u32)1)
            {
            i32 k = ((UXRscTopObject* ?)topObjects.get(i)).id;
            if (k >= id)
                {
                id = k + (i32)1;
                }
            }
        UXRscTopObject* to = new UXRscTopObject();
        to.id = id;
        to.cls = cls;
        to.label = label;
        topObjects.add(to);
        return to;
        }
    UXRscTopObject* topObjectById(i32 id)
        {
        for (u32 i = (u32)0; i < topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* to = (UXRscTopObject* ?)topObjects.get(i);
            if (to.id == id)
                {
                return to;
                }
            }
        return (UXRscTopObject*)0;
        }
    // Remove a top-level object and every connection to or from it.
    void removeTopObject(i32 id)
        {
        for (u32 i = (u32)0; i < topObjects.count(); i = i + (u32)1)
            {
            if (((UXRscTopObject* ?)topObjects.get(i)).id == id)
                {
                topObjects.removeAt(i);
                break;
                }
            }
        UXRscRef* r = UXRscRef.make((i32)UXR_REF_TOP, id, (i32)0);
        self.removeConnectionsTo(r);
        }
    // Remove every connection with `r` at either end (a deleted control or object).  Refs compare
    // by space and a; for a top object b is unused.
    void removeConnectionsTo(UXRscRef* r)
        {
        u32 i = (u32)0;
        while (i < connections.count())
            {
            UXRscConnection* c = (UXRscConnection* ?)connections.get(i);
            bool hit = UXRscDoc.refHits(c.src, r) || UXRscDoc.refHits(c.dst, r);
            if (hit)
                {
                connections.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        }
    static bool refHits(UXRscRef* a, UXRscRef* r)
        {
        if (a.space != r.space)
            {
            return false;
            }
        if (r.space == (i32)UXR_REF_TOP)
            {
            return a.a == r.a;
            }
        if (r.space == (i32)UXR_REF_OWNER || r.space == (i32)UXR_REF_FIRSTR)
            {
            return true;
            }
        return a.a == r.a && a.b == r.b;
        }

    // A copy deep enough to edit independently: every tree, form and graph record is new; strings
    // and image bytes are shared, because an edit replaces them rather than writing into them.  An
    // editor's undo keeps these.
    UXRscDoc* deepCopy(void)
        {
        UXRscDoc* c = new UXRscDoc();
        c.bigEndian = bigEndian;
        c.packedCoords = packedCoords;
        c.embedIcons = embedIcons;
        c.charWidth = charWidth;
        c.charHeight = charHeight;
        c.freeStrings = freeStrings;
        c.freeImages = freeImages;
        c.ownerClass = ownerClass;
        for (i32 i = (i32)0; i < self.treeCount(); i = i + (i32)1)
            {
            UXRscTree* t = self.treeAt(i);
            UXRscTree* u = new UXRscTree();
            u.name = t.name;
            u.nameStore = t.nameStore;
            u.kind = t.kind;
            u.root = t.root != (UXRscObject*)0 ? t.root.deepCopy() : (UXRscObject*)0;
            c.trees.add(u);
            }
        for (i32 i = (i32)0; i < self.formCount(); i = i + (i32)1)
            {
            UXRscForm* f = self.formAt(i);
            UXRscForm* g = new UXRscForm();
            g.formId = f.formId;
            g.name = f.name;
            for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
                {
                UXRscVariant* va = f.variantAt(v);
                UXRscVariant* vb = new UXRscVariant();
                vb.klass = va.klass;
                vb.orient = va.orient;
                vb.tree = c.treeAt(self.indexOfTree(va.tree));
                g.variants.add(vb);
                }
            c.forms.add(g);
            }
        for (u32 i = (u32)0; i < classOverrides.count(); i = i + (u32)1)
            {
            UXRscClassOverride* a = (UXRscClassOverride* ?)classOverrides.get(i);
            UXRscClassOverride* b = new UXRscClassOverride();
            b.view = UXRscRef.make(a.view.space, a.view.a, a.view.b);
            b.cls = a.cls;
            c.classOverrides.add(b);
            }
        for (u32 i = (u32)0; i < topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* a = (UXRscTopObject* ?)topObjects.get(i);
            UXRscTopObject* b = new UXRscTopObject();
            b.id = a.id;
            b.cls = a.cls;
            b.label = a.label;
            c.topObjects.add(b);
            }
        for (u32 i = (u32)0; i < connections.count(); i = i + (u32)1)
            {
            UXRscConnection* a = (UXRscConnection* ?)connections.get(i);
            UXRscConnection* b = new UXRscConnection();
            b.kind = a.kind;
            b.src = UXRscRef.make(a.src.space, a.src.a, a.src.b);
            b.dst = UXRscRef.make(a.dst.space, a.dst.a, a.dst.b);
            b.member = a.member;
            b.scope = a.scope;
            c.connections.add(b);
            }
        for (u32 i = (u32)0; i < extSections.count(); i = i + (u32)1)
            {
            c.extSections.add(extSections.get(i));
            }
        for (u32 i = (u32)0; i < attrs.count(); i = i + (u32)1)
            {
            UXRscAttr* a = (UXRscAttr* ?)attrs.get(i);
            c.setAttrIn(a.formId, a.logicalId, a.theme, a.key, a.value);
            }
        return c;
        }

    static UXRscDoc* emptyDialog(void)
        {
        UXRscDoc* r = new UXRscDoc();
        UXRscTree* t = new UXRscTree();
        t.name = (u8*)"DIALOG";
        t.kind = (i32)UXR_K_DIALOG;
        t.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)320, (i32)200);
        r.addTree(t);
        return r;
        }

    // Flatten a tree to the classic pre-order array with next/head/tail links.
    // This is the ONLY place the linked layout exists: the editor works on the
    // nested form and the flat one is rebuilt at write time, so the two can
    // never disagree.
    Array<UXRscFlatNode>* flatten(UXRscTree* t)
        {
        Array<UXRscFlatNode>* out = new Array();
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0)
            {
            return out;
            }
        Array<UXRscObject>* order = t.allObjects();
        for (u16 i = (u16)0; i < order.count(); i = i + (u16)1)
            {
            UXRscFlatNode* n = new UXRscFlatNode();
            n.obj = (UXRscObject* ?)order.get(i);
            out.add(n);
            }
        // index of an object within the pre-order
        for (i32 i = (i32)0; i < (i32)out.count(); i = i + (i32)1)
            {
            UXRscFlatNode* n = (UXRscFlatNode* ?)out.get((u16)i);
            UXRscObject* o = n.obj;
            i32 kids = o.childCount();
            if (kids > (i32)0)
                {
                n.head = self.indexOf(out, o.childAt((i32)0));
                n.tail = self.indexOf(out, o.childAt(kids - (i32)1));
                }
            // next = the following sibling, or the parent when last
            UXRscObject* p = t.parentOf(o);
            // the root
            if (p == (UXRscObject*)0)
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
            UXRscFlatNode* last = (UXRscFlatNode* ?)out.get((u16)((i32)out.count() - (i32)1));
            last.obj.flags = last.obj.flags | (i32)UXR_F_LASTOB;
            }
        return out;
        }

    i32 indexOf(Array<UXRscFlatNode>* flat, UXRscObject* o)
        {
        for (i32 i = (i32)0; i < (i32)flat.count(); i = i + (i32)1)
            {
            if (((UXRscFlatNode* ?)flat.get((u16)i)).obj == o)
                {
                return i;
                }
            }
        return (i32)-1;
        }
    }
