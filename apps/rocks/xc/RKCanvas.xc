// RKCanvas.xc — the resource model, realized as REAL UXKit widgets.
//
// This is the payoff for writing Rocks in XC.  A GEM object tree becomes an
// actual UXView tree of actual UXButtons and UXTextFields, so the canvas is
// not a drawing OF the UI, it IS the UI — the same widget objects, through the
// same drivers, that the edited application will run.  There is no second
// renderer to keep in step, which is the failure mode this whole rewrite was
// chosen to avoid: seven platforms were made to agree on how a radio button
// looks exactly once, and the editor inherits that rather than re-deriving it.
//
// Coordinates need no translation.  A GEM child's x/y are relative to its
// parent, and so are a UXView subview's, so the nesting maps straight across.
//
// Deliberately NEUTRAL: no file I/O, no driver calls, no Rocks state.  It takes
// a model and returns views, which keeps it buildable on every target and
// testable headlessly.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGroupBox.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
#import "RKModel.xc"

class RKCanvas : Object
    {
    // The object -> widget map, kept as two parallel arrays.  Selection needs
    // it: clicking an outline row has to find the widget that row stands for,
    // and rediscovering it by walking two trees in step would re-derive at
    // every click something realize() already knew for free.
    Array<RKObject>* objs;
    Array<UXView>* views;

    void init(void)
        {
        objs = new Array();
        views = new Array();
        }

    // The widget realized for an object, or 0 if it was not realized (the
    // form's root, or a tree that is not the one on screen).
    UXView* viewFor(RKObject* o)
        {
        for (i32 i = (i32)0; i < (i32)objs.count(); i = i + (i32)1)
            {
            if ((RKObject* ?)objs.get((u16)i) == o)
                { return (UXView* ?)views.get((u16)i);
                }
            }
        return (UXView*)0;
        }

    // Build `tree` into `into`, which is normally the canvas outlet.  Returns
    // the number of widgets realized, so a caller can report "12 objects" and
    // a test can assert the whole tree arrived rather than most of it.
    i32 realize(RKTree* tree, UXView* into)
        {
        if (tree == (RKTree*)0 || tree.root == (RKObject*)0 || into == (UXView*)0)
            {
            return (i32)0;
            }
        // The root box is the form's own background: its children are what the
        // designer sees, so realize those INTO the canvas rather than nesting
        // one redundant container.
        objs = new Array();
        views = new Array();
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < tree.root.childCount(); i = i + (i32)1)
            {
            n = n + self.realizeInto(tree.root.childAt(i), into);
            }
        return n;
        }

    i32 realizeInto(RKObject* o, UXView* parent)
        {
        UXView* v = RKCanvas.widgetFor(o);
        if (v == (UXView*)0)
            {
            return (i32)0;
            }
        parent.addSubview(v, UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
        // The designer should see the state they set, not a uniformly live
        // form — so disabled objects look disabled, HIDETREE objects are
        // actually hidden, and a selected radio shows selected.  Hiding is
        // recoverable: the object still has its row in the outline, so it can
        // be selected and un-hidden there.  That escape hatch is what makes
        // honouring it safe rather than a trap.
        RKCanvas.applyState(v, o);
        objs.add(o);
        views.add(v);
        i32 n = (i32)1;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            n = n + self.realizeInto(o.childAt(i), v);
            }
        return n;
        }

    // One GEM type -> one UXKit widget.  Where the toolkit has no equivalent
    // the object becomes a plain view rather than nothing: an unknown type
    // still occupies its rectangle, so a form with something exotic in it lays
    // out correctly instead of collapsing.
    static UXView* widgetFor(RKObject* o)
        {
        i32 t = o.type;

        if (t == (i32)RKT_BUTTON)
            {
            UXButton* b = new UXButton();
            b.setTitle(RKCanvas.textOf(o));
            return (UXView*)b;
            }
        if (t == (i32)RKT_CHECKBOX)
            {
            UXCheckbox* c = new UXCheckbox();
            c.setTitle(RKCanvas.textOf(o));
            c.setChecked((o.state & (i32)RKS_CHECKED) != (i32)0);
            return (UXView*)c;
            }
        if (t == (i32)RKT_RADIO)
            {
            UXRadioButton* r = new UXRadioButton();
            r.setTitle(RKCanvas.textOf(o));
            r.setSelected((o.state & (i32)RKS_SELECTED) != (i32)0);
            return (UXView*)r;
            }
        if (t == (i32)RKT_STRING || t == (i32)RKT_TEXT || t == (i32)RKT_TITLE)
            {
            UXLabel* l = new UXLabel();
            l.setTitle(RKCanvas.textOf(o));
            return (UXView*)l;
            }
        if (t == (i32)RKT_FIELD || t == (i32)RKT_FTEXT ||
            t == (i32)RKT_BOXTEXT || t == (i32)RKT_FBOXTEXT)
            {
            UXTextField* f = new UXTextField();
            if (o.ted != (RKTedinfo*)0)
                {
                f.setText(o.ted.text);
                }
            return (UXView*)f;
            }
        if (t == (i32)RKT_POPUP)
            {
            // A GEM popup's spec is its label; the menu behind it lives in a
            // linked tree, which the editor will follow once tree navigation
            // exists.  Showing the control with its current value beats
            // showing nothing — which is what it did before: an unmapped type
            // fell through to a plain view and left a HOLE in the form, next
            // to its label, with no indication anything was missing.
            UXPopUpButton* p = new UXPopUpButton();
            p.addItem(RKCanvas.textOf(o), (i32)0);
            p.selectItem((i32)0);
            return (UXView*)p;
            }
        if (t == (i32)RKT_BOX || t == (i32)RKT_BOXCHAR)
            {
            // A visible box with children reads as a group; an empty one is
            // just a panel.  Either way it is a real container.
            UXGroupBox* g = new UXGroupBox();
            g.setTitle((u8*)"");
            return (UXView*)g;
            }
        // IBOX is an INVISIBLE box — a grouping rectangle with no chrome — so
        // a plain view is exactly right, not a group box.
        if (t == (i32)RKT_IBOX)
            {
            return new UXView();
            }

        // Anything else is a type this build does not realize yet (icons, bit
        // forms, USERDEF).  It gets a VISIBLE placeholder rather than a plain
        // view: an invisible stand-in is a silent hole in the designer's form,
        // and the whole reader/writer discipline here is that what we cannot
        // handle must announce itself rather than vanish.
        UXGroupBox* unknown = new UXGroupBox();
        unknown.setTitle(RKCanvas.typeName(o.type));
        return (UXView*)unknown;
        }

    // A short name for a type, for placeholders and the outline.
    static u8* typeName(i32 t)
        {
        if (t == (i32)RKT_BOX)
            {
            return (u8*)"box";
            }
        if (t == (i32)RKT_TEXT)
            {
            return (u8*)"text";
            }
        if (t == (i32)RKT_BOXTEXT)
            {
            return (u8*)"boxtext";
            }
        if (t == (i32)RKT_IMAGE)
            {
            return (u8*)"image";
            }
        if (t == (i32)RKT_USERDEF)
            {
            return (u8*)"userdef";
            }
        if (t == (i32)RKT_IBOX)
            {
            return (u8*)"ibox";
            }
        if (t == (i32)RKT_BUTTON)
            {
            return (u8*)"button";
            }
        if (t == (i32)RKT_BOXCHAR)
            {
            return (u8*)"boxchar";
            }
        if (t == (i32)RKT_STRING)
            {
            return (u8*)"string";
            }
        if (t == (i32)RKT_FTEXT)
            {
            return (u8*)"ftext";
            }
        if (t == (i32)RKT_FBOXTEXT)
            {
            return (u8*)"fboxtext";
            }
        if (t == (i32)RKT_ICON)
            {
            return (u8*)"icon";
            }
        if (t == (i32)RKT_TITLE)
            {
            return (u8*)"title";
            }
        if (t == (i32)RKT_CICONBLK)
            {
            return (u8*)"ciconblk";
            }
        if (t == (i32)RKT_CHECKBOX)
            {
            return (u8*)"checkbox";
            }
        if (t == (i32)RKT_RADIO)
            {
            return (u8*)"radio";
            }
        if (t == (i32)RKT_POPUP)
            {
            return (u8*)"popup";
            }
        if (t == (i32)RKT_FIELD)
            {
            return (u8*)"field";
            }
        if (t == (i32)RKT_CICON)
            {
            return (u8*)"cicon";
            }
        return (u8*)"?";
        }

    // Push an object's STATE into the widget realized for it.
    //
    // ONE place, called both when a form is first realized and after every
    // edit.  It used to be three -- widgetFor set the toggles at creation,
    // realizeInto did enabled/hidden, and the controller's edit path did its
    // own subset -- and each time a property was added the three drifted a
    // little further.  That is how "Hidden" reached the model and never the
    // screen, and then how "Selected" on a radio did the same: the code that
    // built a form knew about it and the code that edited one did not.
    //
    // Adding a property now means adding it HERE, and both paths get it.
    static void applyState(UXView* w, RKObject* o)
        {
        if (w == (UXView*)0 || o == (RKObject*)0)
            {
            return;
            }
        w.setEnabled((o.state & (i32)RKS_DISABLED) == (i32)0);
        w.setHidden((o.flags & (i32)RKF_HIDETREE) != (i32)0);
        // Text alignment, straight through: UX_ALIGN_* is numbered to match
        // GEM's te_just, so there is nothing to convert.  It used to need a
        // three-way map, which is one more thing that can be got backwards --
        // and getting it backwards swaps RIGHT and CENTRE, which looks nearly
        // correct and would write the wrong value into every .rsc Rocks saved.
        if (o.ted != (RKTedinfo*)0)
            { ((UXControl* ?)w).setAlignment(o.ted.just);
            }
        i32 k = (i32)w.kind();
        if (k == (i32)UXKindCheckbox)
            {
            ((UXCheckbox* ?)w).setChecked((o.state & (i32)RKS_CHECKED) != (i32)0);
            }
        else if (k == (i32)UXKindRadio)
            {
            ((UXRadioButton* ?)w).setSelected((o.state & (i32)RKS_SELECTED) != (i32)0);
            }
        }

    // Push an object's text into the widget already realized for it.  The
    // alternative — rebuild the widget — would destroy the control the
    // designer is typing into, along with the keyboard focus.
    static void applyText(UXView* w, RKObject* o)
        {
        u8* t = RKCanvas.textOf(o);
        i32 k = (i32)w.kind();
        if (k == (i32)UXKindField)
            { ((UXTextField* ?)w).setText(t);
            return;
            }
        if (k == (i32)UXKindButton || k == (i32)UXKindLabel ||
            k == (i32)UXKindCheckbox || k == (i32)UXKindRadio)
            {
            ((UXControl* ?)w).setTitle(t);
            }
        }

    static u8* textOf(RKObject* o)
        {
        if (o.text != (u8*)0)
            {
            return o.text;
            }
        if (o.ted != (RKTedinfo*)0 && o.ted.text != (u8*)0)
            {
            return o.ted.text;
            }
        return (u8*)"";
        }
    }
