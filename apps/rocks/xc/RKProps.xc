// RKProps.xc — what properties a type actually HAS.
//
// The first inspector showed one fixed set of fields for everything, which is
// wrong in both directions: a button could not be marked DEFAULT, and a text
// field was offered a "checked" box it can never meaningfully have.  So the
// pane is driven by a SCHEMA looked up per type, and the pane's job shrinks to
// rendering whatever the schema says.
//
// The indirection is not decoration.  It is the seam a future IBDesignable
// equivalent plugs into: a custom widget class describes its own inspectable
// properties, those descriptors join the list this returns, and the pane
// renders them with no idea they came from somewhere else.  Everything here is
// therefore addressed by DESCRIPTOR rather than by hard-coded field, so the
// day a property arrives from a user's class nothing above has to change.
//
// Deliberately neutral: no widgets, no driver, no view code.  Descriptors are
// data about the model, and the pane is a separate concern.
#import "Array.xc"
#import "RKModel.xc"

// How a property is edited.  COLOUR is named but not yet built — the box colour
// word wants it.
#define RKP_INT 0   // a number: x, y, w, h, thickness
#define RKP_TEXT 1  // a string: the object's text
#define RKP_FLAG 2  // one bit of ob_flags
#define RKP_STATE 3 // one bit of ob_state
#define RKP_ENUM 4  // one of a fixed list, rendered as a pop-up

// Which value a descriptor addresses, for the fixed model fields.
#define RKV_X 0
#define RKV_Y 1
#define RKV_W 2
#define RKV_H 3
#define RKV_TEXT 4
#define RKV_JUST 5 // TEDINFO te_just: 0 left, 1 right, 2 centre

// A boxed literal, so choices can live in an Array without going through
// String: these are string constants with static lifetime, and round-tripping
// them through a String object hands the pop-up a buffer that does not outlive
// the call (AppKit raises on the nil title that results).  Same boxing idiom as
// RKInt/RKRectBox in RKGuides.
class RKChoice : Object
    {
    u8* s;
    void init(void)
        {
        s = (u8*)"";
        }
    static RKChoice* of(u8* x)
        {
        RKChoice* c = new RKChoice();
        c.s = x;
        return c;
        }
    }

    class RKProperty : Object
    {
    u8* label; // what the designer reads
    i32 kind;  // RKP_*
    i32 sel;   // RKV_* for INT/TEXT/ENUM; the bit mask for FLAG/STATE
    u8* help;  // one line of why it matters; 0 for the obvious ones
    // For RKP_ENUM: the choices, in the order the model numbers them, so the
    // pop-up's index IS the stored value and no mapping table can drift.
    Array<RKChoice>* choices;
    void init(void)
        {
        label = (u8*)"";
        kind = (i32)RKP_INT;
        sel = (i32)0;
        help = (u8*)0;
        choices = new Array();
        }

    static RKProperty* make(u8* label, i32 kind, i32 sel, u8* help)
        {
        RKProperty* p = new RKProperty();
        p.label = label;
        p.kind = kind;
        p.sel = sel;
        p.help = help;
        return p;
        }
    RKProperty* choice(u8* c)
        {
        choices.add(RKChoice.of(c));
        return self;
        }
    i32 choiceCount(void)
        {
        return (i32)choices.count();
        }
    u8* choiceAt(i32 i)
        { return ((RKChoice* ?)choices.get((u16)i)).s;
        }
    }

    class RKProps : Object
    {

    // ---- the schema for a type ---------------------------------------------
    // Geometry is universal; everything after it is what this type actually
    // supports.  A property absent from the list simply cannot be set, which
    // is the point: the pane can only offer what the object can hold.
    static Array<RKProperty>* forType(i32 t)
        {
        Array<RKProperty>* ps = new Array();
        ps.add(RKProperty.make((u8*)"X", (i32)RKP_INT, (i32)RKV_X, (u8*)0));
        ps.add(RKProperty.make((u8*)"Y", (i32)RKP_INT, (i32)RKV_Y, (u8*)0));
        ps.add(RKProperty.make((u8*)"W", (i32)RKP_INT, (i32)RKV_W, (u8*)0));
        ps.add(RKProperty.make((u8*)"H", (i32)RKP_INT, (i32)RKV_H, (u8*)0));

        if (RKProps.hasText(t))
            {
            ps.add(RKProperty.make((u8*)"Text", (i32)RKP_TEXT, (i32)RKV_TEXT, (u8*)0));
            }

        // Every object can be disabled and hidden — those are AES-wide.
        ps.add(RKProperty.make((u8*)"Disabled", (i32)RKP_STATE, (i32)RKS_DISABLED, (u8*)0));
        ps.add(RKProperty.make((u8*)"Hidden", (i32)RKP_FLAG, (i32)RKF_HIDETREE,
                               (u8*)"hides this object AND its children"));

        if (t == (i32)RKT_BUTTON)
            {
            // The three that make a dialog behave: Return fires the default,
            // Esc fires the cancel, and an exit button closes the form.
            ps.add(RKProperty.make((u8*)"Default", (i32)RKP_FLAG, (i32)RKF_DEFAULT,
                                   (u8*)"Return fires this button"));
            ps.add(RKProperty.make((u8*)"Cancel", (i32)RKP_FLAG, (i32)RKF_CANCEL,
                                   (u8*)"Esc fires this button"));
            ps.add(RKProperty.make((u8*)"Exit", (i32)RKP_FLAG, (i32)RKF_EXIT, (u8*)0));
            ps.add(RKProperty.make((u8*)"Selectable", (i32)RKP_FLAG, (i32)RKF_SELECTABLE, (u8*)0));
            ps.add(RKProperty.make((u8*)"Selected", (i32)RKP_STATE, (i32)RKS_SELECTED, (u8*)0));
            }
        if (t == (i32)RKT_CHECKBOX)
            {
            ps.add(RKProperty.make((u8*)"Checked", (i32)RKP_STATE, (i32)RKS_CHECKED, (u8*)0));
            ps.add(RKProperty.make((u8*)"Selectable", (i32)RKP_FLAG, (i32)RKF_SELECTABLE, (u8*)0));
            }
        if (t == (i32)RKT_RADIO)
            {
            // RBUTTON is what makes the AES enforce one-of-a-group, so it is
            // the property that actually matters on a radio.
            ps.add(RKProperty.make((u8*)"Selected", (i32)RKP_STATE, (i32)RKS_SELECTED, (u8*)0));
            ps.add(RKProperty.make((u8*)"Radio group", (i32)RKP_FLAG, (i32)RKF_RBUTTON,
                                   (u8*)"the AES clears the siblings when this is picked"));
            ps.add(RKProperty.make((u8*)"Selectable", (i32)RKP_FLAG, (i32)RKF_SELECTABLE, (u8*)0));
            }
        // Text alignment, on the types that carry a TEDINFO -- which is where
        // GEM keeps te_just.  A plain G_STRING has no TEDINFO and therefore no
        // alignment at all, so offering it there would be a control that
        // silently does nothing.
        //
        // This is the property that makes a column of "Name:" "Size:" "Kind:"
        // labels line its colons up: right-align the text, then align the boxes'
        // right edges with the snap guides.  Left-aligned text cannot be made to
        // line up however carefully the boxes are placed, because the colon then
        // sits wherever the word before it ends.
        if (RKProps.canAlign(t))
            {
            RKProperty* a = RKProperty.make((u8*)"Alignment", (i32)RKP_ENUM, (i32)RKV_JUST,
                                            (u8*)"right-align, then align the edges, to line up colons");
            a.choice((u8*)"Left").choice((u8*)"Right").choice((u8*)"Centre");
            ps.add(a);
            }
        if (RKProps.isEditable(t))
            {
            ps.add(RKProperty.make((u8*)"Editable", (i32)RKP_FLAG, (i32)RKF_EDITABLE, (u8*)0));
            }
        if (t == (i32)RKT_BOX || t == (i32)RKT_IBOX || t == (i32)RKT_BOXCHAR)
            {
            ps.add(RKProperty.make((u8*)"Outlined", (i32)RKP_STATE, (i32)RKS_OUTLINED, (u8*)0));
            ps.add(RKProperty.make((u8*)"Shadowed", (i32)RKP_STATE, (i32)RKS_SHADOWED, (u8*)0));
            ps.add(RKProperty.make((u8*)"Movable", (i32)RKP_FLAG, (i32)RKF_MOVEABLE,
                                   (u8*)"on a tree ROOT: the dialog can be dragged"));
            }
        if (t == (i32)RKT_TITLE)
            {
            ps.add(RKProperty.make((u8*)"Submenu", (i32)RKP_FLAG, (i32)RKF_SUBMENU, (u8*)0));
            }
        // Touch-exit fires on press rather than release; meaningful anywhere
        // the object is clickable at all.
        if (RKProps.isClickable(t))
            {
            ps.add(RKProperty.make((u8*)"Touch exit", (i32)RKP_FLAG, (i32)RKF_TOUCHEXIT,
                                   (u8*)"fires on press, not release"));
            }
        return ps;
        }

    static bool hasText(i32 t)
        {
        return t == (i32)RKT_STRING || t == (i32)RKT_BUTTON || t == (i32)RKT_TITLE ||
               t == (i32)RKT_TEXT || t == (i32)RKT_CHECKBOX || t == (i32)RKT_RADIO ||
               t == (i32)RKT_POPUP || t == (i32)RKT_FIELD || t == (i32)RKT_FTEXT ||
               t == (i32)RKT_BOXTEXT || t == (i32)RKT_FBOXTEXT;
        }
    static bool isEditable(i32 t)
        {
        return t == (i32)RKT_FIELD || t == (i32)RKT_FTEXT || t == (i32)RKT_FBOXTEXT;
        }
    static bool isClickable(i32 t)
        {
        return t == (i32)RKT_BUTTON || t == (i32)RKT_CHECKBOX || t == (i32)RKT_RADIO ||
               t == (i32)RKT_POPUP || t == (i32)RKT_TITLE;
        }

    // ---- reading and writing, BY DESCRIPTOR --------------------------------
    // Nothing above these two functions knows a property's storage, which is
    // what lets a descriptor eventually come from a user's own class.
    static i32 intOf(RKObject* o, RKProperty* p)
        {
        if (p.sel == (i32)RKV_X)
            {
            return o.x;
            }
        if (p.sel == (i32)RKV_Y)
            {
            return o.y;
            }
        if (p.sel == (i32)RKV_W)
            {
            return o.w;
            }
        if (p.sel == (i32)RKV_H)
            {
            return o.h;
            }
        if (p.sel == (i32)RKV_JUST)
            {
            return o.ted != (RKTedinfo*)0 ? o.ted.just : (i32)0;
            }
        return (i32)0;
        }

    // Types whose text can be aligned.
    //
    // The TEDINFO-bearing ones store te_just directly.  G_STRING is included
    // too, and it has no TEDINFO at all -- because a string is exactly what a
    // designer labels a text box with, so it is where alignment is most wanted.
    // Choosing a non-left alignment PROMOTES it to G_TEXT (see setInt), which
    // is the format's own answer: aligned text in a .rsc IS a G_TEXT.
    //
    // Asking the MODEL for the TEDINFO list rather than keeping a second copy
    // here: the copy drifted the moment it existed, omitting G_FIELD.
    static bool canAlign(i32 t)
        {
        return RKObject.typeHasTedinfo(t) || t == (i32)RKT_STRING;
        }
    static void setInt(RKObject* o, RKProperty* p, i32 v)
        {
        if (p.sel == (i32)RKV_X)
            {
            o.x = v;
            return;
            }
        if (p.sel == (i32)RKV_Y)
            {
            o.y = v;
            return;
            }
        if (p.sel == (i32)RKV_W)
            {
            o.w = v;
            return;
            }
        if (p.sel == (i32)RKV_H)
            {
            o.h = v;
            return;
            }
        if (p.sel == (i32)RKV_JUST)
            {
            // A G_STRING has nowhere to put alignment: the format gives it no
            // TEDINFO, and its ob_type high byte is NOT free -- a scan of 112
            // real resources finds junk there on G_STRING specifically, which
            // is why the reader keeps it verbatim as legacyExtType.
            //
            // So promote it to G_TEXT, which is what a GEM designer does by
            // hand for exactly this reason: aligned text in a resource is a
            // G_TEXT.  It round-trips through a plain .rsc, renders on any AES,
            // and needs no extension to the format.  Only on a non-left choice,
            // so merely inspecting a string never rewrites it.
            if (o.ted == (RKTedinfo*)0 && v != (i32)0)
                {
                o.type = (i32)RKT_TEXT;
                o.seedPayload(); // gives it the TEDINFO
                if (o.ted != (RKTedinfo*)0 && o.text != (u8*)0)
                    {
                    o.ted.text = o.text;
                    }
                }
            if (o.ted != (RKTedinfo*)0)
                {
                o.ted.just = v;
                }
            return;
            }
        }
    static bool boolOf(RKObject* o, RKProperty* p)
        {
        if (p.kind == (i32)RKP_FLAG)
            {
            return (o.flags & p.sel) != (i32)0;
            }
        if (p.kind == (i32)RKP_STATE)
            {
            return (o.state & p.sel) != (i32)0;
            }
        return false;
        }
    static void setBool(RKObject* o, RKProperty* p, bool on)
        {
        if (p.kind == (i32)RKP_FLAG)
            {
            if (on)
                {
                o.flags = o.flags | p.sel;
                }
            else
                {
                o.flags = o.flags & ~p.sel;
                }
            return;
            }
        if (p.kind == (i32)RKP_STATE)
            {
            if (on)
                {
                o.state = o.state | p.sel;
                }
            else
                {
                o.state = o.state & ~p.sel;
                }
            }
        }
    }
