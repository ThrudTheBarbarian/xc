// RKInspector.xc — the property pane, driven by the type's SCHEMA.
//
// It no longer knows what a button or a field has.  It asks RKProps for the
// selected type's descriptors and renders whatever comes back, so a button
// gets Default/Cancel/Exit and a text field gets Editable and never a
// meaningless "checked".  When a custom widget eventually describes its own
// inspectable properties (the IBDesignable equivalent), they arrive through
// the same list and this file does not change.
//
// THE ROWS ARE BUILT DYNAMICALLY, and that is a deliberate exception to the
// nib-client rule the rest of Rocks follows.  A per-type pane cannot be a
// fixed set of outlets: the widgets depend on the selection.  So the CONTAINER
// stays something a nib can express, and the CONTENTS are generated — which is
// how Xcode's inspector works too, for the same reason.  Rebuilding is what
// UXView.removeAllSubviews exists for.
//
// The direction of truth is unchanged: the model is authoritative, the pane
// reflects it, an edit writes back and then asks the canvas to catch up.
#import "UXControl.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXMetrics.xc"
#import "Array.xc"
#import "RKModel.xc"
#import "RKProps.xc"
#import "UXPopUpButton.xc"
#import "RKCanvas.xc"

// One rendered row: the descriptor it edits, and the widget editing it.
class RKRow : Object
    {
    RKProperty* prop;
    UXTextField* field; // for INT / TEXT
    UXCheckbox* box;    // for FLAG / STATE
    UXPopUpButton* pop; // for ENUM
    void init(void)
        {
        prop = (RKProperty*)0;
        field = (UXTextField*)0;
        box = (UXCheckbox*)0;
        pop = (UXPopUpButton*)0;
        }
    }

    class RKInspector : Object
    {
    UXView* pane; // where rows are built; supplied, not constructed
    UXLabel* typeLabel;
    Array<RKRow>* rows;

    // STRONG: the same reasoning as RKDrag.root -- no cycle exists to break, and a
    // weak reference to a model object is what caused the lifetime crash.
    RKObject* target;
    callback changed void(RKObject* o);

    // Populating a field fires its change hook, which would write a
    // half-written value straight back into the model.
    bool loading;

    void init(void)
        {
        pane = (UXView*)0;
        typeLabel = (UXLabel*)0;
        rows = new Array();
        target = (RKObject*)0;
        changed = (callback void(RKObject * o))0;
        loading = false;
        }

    void attach(UXView* p, UXLabel* tl)
        {
        pane = p;
        typeLabel = tl;
        }

    // ---- number formatting, both ways --------------------------------------
    static i32 parseInt(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 i = (i32)0;
        i32 sign = (i32)1;
        i32 v = (i32)0;
        if (s[0] == (u8)45)
            {
            sign = (i32)-1;
            i = (i32)1;
            }
        while (s[i] >= (u8)48 && s[i] <= (u8)57)
            {
            v = v * (i32)10 + ((i32)s[i] - (i32)48);
            i = i + (i32)1;
            }
        return v * sign;
        }
    static u8* fmtInt(i32 v)
        {
        u8* b = new u8[(u32)12];
        i32 n = (i32)0;
        if (v < (i32)0)
            {
            b[n] = (u8)45;
            n = n + (i32)1;
            v = -v;
            }
        u8 tmp[12];
        i32 t = (i32)0;
        if (v == (i32)0)
            {
            tmp[t] = (u8)48;
            t = (i32)1;
            }
        while (v > (i32)0)
            {
            tmp[t] = (u8)((i32)48 + v % (i32)10);
            v = v / (i32)10;
            t = t + (i32)1;
            }
        while (t > (i32)0)
            {
            t = t - (i32)1;
            b[n] = tmp[t];
            n = n + (i32)1;
            }
        b[n] = (u8)0;
        return b;
        }
    static u8* dup(u8* s)
        {
        if (s == (u8*)0)
            {
            return (u8*)"";
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        u8* d = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            d[i] = s[i];
            }
        d[n] = (u8)0;
        return d;
        }

    // ---- render the schema --------------------------------------------------
    void show(RKObject* o)
        {
        loading = true;
        target = o;
        rows = new Array();
        if (pane != (UXView*)0)
            {
            pane.removeAllSubviews();
            }

        if (o == (RKObject*)0)
            {
            // Blank, not stale: an inspector still showing the last object's
            // numbers invites editing something that is not selected.
            if (typeLabel != (UXLabel*)0)
                {
                typeLabel.setText((u8*)"—");
                }
            loading = false;
            return;
            }
        if (typeLabel != (UXLabel*)0)
            {
            typeLabel.setText(RKCanvas.typeName(o.type));
            }
        if (pane == (UXView*)0)
            {
            loading = false;
            return;
            }

        Array<RKProperty>* ps = RKProps.forType(o.type);
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        i16 gap = (i16)4;
        i16 lw = (i16)86;
        i16 y = (i16)4;
        i16 w = pane.bounds().w;
        if (w <= (i16)0)
            {
            w = (i16)240;
            }

        for (i32 i = (i32)0; i < (i32)ps.count(); i = i + (i32)1)
            {
            RKProperty* p = (RKProperty* ?)ps.get((u16)i);
            RKRow* r = new RKRow();
            r.prop = p;
            if (p.kind == (i32)RKP_ENUM)
                {
                // A pop-up whose item ORDER is the model's numbering, so the
                // selected index is the stored value directly -- no mapping
                // table to drift out of step with the format.
                UXLabel* l = new UXLabel();
                l.setTitle(p.label);
                pane.addSubview(l, UXGeom.make((i16)8, y, lw, rh));
                UXPopUpButton* pu = new UXPopUpButton();
                for (i32 c = (i32)0; c < p.choiceCount(); c = c + (i32)1)
                    {
                    pu.addItem(p.choiceAt(c), c);
                    }
                pu.selectItem(RKProps.intOf(o, p));
                pu.setAction(&self.onEnum);
                pane.addSubview(pu, UXGeom.make((i16)((i32)8 + (i32)lw), y,
                                                (i16)((i32)w - (i32)lw - (i32)16), rh));
                r.pop = pu;
                }
            else if (p.kind == (i32)RKP_FLAG || p.kind == (i32)RKP_STATE)
                {
                UXCheckbox* cb = new UXCheckbox();
                cb.setTitle(p.label);
                cb.setChecked(RKProps.boolOf(o, p));
                cb.setAction(&self.onToggle);
                pane.addSubview(cb, UXGeom.make((i16)8, y, (i16)((i32)w - (i32)16), rh));
                r.box = cb;
                }
            else
                {
                UXLabel* l = new UXLabel();
                l.setTitle(p.label);
                pane.addSubview(l, UXGeom.make((i16)8, y, lw, rh));
                UXTextField* f = new UXTextField();
                if (p.kind == (i32)RKP_TEXT)
                    {
                    f.setText(RKCanvas.textOf(o));
                    }
                else
                    {
                    f.setText(RKInspector.fmtInt(RKProps.intOf(o, p)));
                    }
                f.setOnChange(&self.onField);
                pane.addSubview(f, UXGeom.make((i16)((i32)8 + (i32)lw), y,
                                               (i16)((i32)w - (i32)lw - (i32)16), rh));
                r.field = f;
                }
            rows.add(r);
            y = (i16)((i32)y + (i32)rh + (i32)gap);
            }
        loading = false;
        }

    // ---- edits, back to the MODEL ------------------------------------------
    // Both hooks find WHICH property changed by matching the widget, because
    // the rows are generated and cannot each have their own method.
    void onField(UXTextField* sender) : action
        {
        if (loading || target == (RKObject*)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.field != sender)
                {
                continue;
                }
            if (r.prop.kind == (i32)RKP_TEXT)
                {
                // Copied: the field's buffer belongs to the driver and is
                // reused, so aliasing it would leave every object edited here
                // sharing one string.
                target.text = RKInspector.dup(sender.text());
                if (target.ted != (RKTedinfo*)0)
                    {
                    target.ted.text = target.text;
                    }
                }
            else
                {
                RKProps.setInt(target, r.prop, RKInspector.parseInt(sender.text()));
                }
            self.announce();
            return;
            }
        }

    // A pop-up changed.  Same match-the-sender shape as the other two hooks:
    // the rows are generated, so none of them can have a method of its own.
    void onEnum(UXControl* sender) : action
        {
        if (loading || target == (RKObject*)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.pop != (UXPopUpButton*)0 && (UXControl*)r.pop == sender)
                {
                i32 wasType = target.type;
                RKProps.setInt(target, r.prop, r.pop.selectedIndex());
                self.announce();
                // Aligning a G_STRING promotes it to G_TEXT, so the pane is now
                // describing the wrong type.  Re-render -- safe here, and only
                // here: a pop-up choice is a FINISHED interaction, whereas
                // rebuilding while someone is typing in a field would destroy
                // the field under their cursor.
                if (target.type != wasType)
                    {
                    self.show(target);
                    }
                return;
                }
            }
        }

    void onToggle(UXControl* sender) : action
        {
        if (loading || target == (RKObject*)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.box != (UXCheckbox*)0 && (UXControl*)r.box == sender)
                {
                RKProps.setBool(target, r.prop, r.box.isChecked());
                self.announce();
                return;
                }
            }
        }

    void announce(void)
        {
        callback f void(RKObject * o) = changed;
        if (f)
            {
            f(target);
            }
        }

    // ---- for tests: find the row editing a named property -------------------
    RKRow* rowNamed(u8* name)
        {
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            u8* a = r.prop.label;
            i32 k = (i32)0;
            while (a[k] != (u8)0 && name[k] != (u8)0 && a[k] == name[k])
                {
                k = k + (i32)1;
                }
            if (a[k] == name[k])
                {
                return r;
                }
            }
        return (RKRow*)0;
        }
    i32 rowCount(void)
        {
        return (i32)rows.count();
        }
    }
