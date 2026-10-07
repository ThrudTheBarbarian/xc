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
// rsc-client rule the rest of Rocks follows.  A per-type pane cannot be a
// fixed set of outlets: the widgets depend on the selection.  So the CONTAINER
// stays something an rsc file can express, and the CONTENTS are generated — which is
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
#import "UXRscModel.xc"
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
    UXButton* vary;     // Vary / Varies: this layout's own value, or the one the layouts share
    u8* attrKey;        // for an attribute row: the setting's key
    void init(void)
        {
        attrKey = (u8*)0;
        vary = (UXButton*)0;
        prop = (RKProperty*)0;
        field = (UXTextField*)0;
        box = (UXCheckbox*)0;
        pop = (UXPopUpButton*)0;
        }
    }

// Which of an object's properties a pane shows: every one, or one inspector tab's share (the
// Size tab has the frame, the Attributes tab the rest).
#define RKIS_ALL 0
#define RKIS_ATTRIBUTES 1
#define RKIS_SIZE 2

    class RKInspector : Object
    {
    UXView* pane; // where rows are built; supplied, not constructed
    i32 section;  // RKIS_*
    UXLabel* typeLabel;
    Array<RKRow>* rows;

    // STRONG: the same reasoning as RKDrag.root -- no cycle exists to break, and a
    // weak reference to a model object is what caused the lifetime crash.
    UXRscObject* target;
    callback changed void(UXRscObject* o);
    // Called BEFORE an edit reaches the model, so the controller can snapshot it for undo.  `key`
    // is the row being typed into, the same for every keystroke of one field (so they make one
    // undo step), or 0 for a one-shot edit (a toggle, a pop-up choice).
    callback willChange void(UXRscObject* o, Object* key);
    // Layout variations: -1 = the control is in one layout only (no toggle), 0 = the property is
    // shared by its layouts, 1 = this layout varies it; and the toggle itself.
    callback varyState i32(UXRscObject* o, RKProperty* p);
    callback varyToggle void(UXRscObject* o, RKProperty* p);
    RKProperty* lastProp; // what the last edit changed, for the controller to share it
    bool lastWasAttr;     // the last edit was to a UXKit control's setting
    // The document and layout the target is in: a UXKit control's settings are its attributes.
    UXRscDoc* doc;
    UXRscTree* tree;

    // Populating a field fires its change hook, which would write a
    // half-written value straight back into the model.
    bool loading;

    void init(void)
        {
        pane = (UXView*)0;
        section = (i32)RKIS_ALL;
        typeLabel = (UXLabel*)0;
        rows = new Array();
        target = (UXRscObject*)0;
        changed = (callback void(UXRscObject * o))0;
        willChange = (callback void(UXRscObject * o, Object * key))0;
        varyState = (callback i32(UXRscObject * o, RKProperty * p))0;
        varyToggle = (callback void(UXRscObject * o, RKProperty * p))0;
        lastProp = (RKProperty*)0;
        lastWasAttr = false;
        doc = (UXRscDoc*)0;
        tree = (UXRscTree*)0;
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
    void show(UXRscObject* o)
        {
        loading = true;
        target = o;
        rows = new Array();
        if (pane != (UXView*)0)
            {
            pane.removeAllSubviews();
            }

        if (o == (UXRscObject*)0)
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
            typeLabel.setText(UXRsc.typeName(o.type));
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
            bool frame = p.kind == (i32)RKP_INT && p.sel >= (i32)RKV_X && p.sel <= (i32)RKV_H;
            if ((section == (i32)RKIS_ATTRIBUTES && frame) || (section == (i32)RKIS_SIZE && !frame))
                {
                continue;
                }
            RKRow* r = new RKRow();
            r.prop = p;
            i32 vst = (i32)-1; // the Vary toggle's state, -1 for none; the fields leave it room
            callback vs i32(UXRscObject * o, RKProperty * p) = varyState;
            if (vs && !frame)
                {
                vst = vs(o, p);
                }
            i32 rw = vst >= (i32)0 ? (i32)64 : (i32)0;
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
                                                (i16)((i32)w - (i32)lw - (i32)16 - rw), rh));
                r.pop = pu;
                }
            else if (p.kind == (i32)RKP_FLAG || p.kind == (i32)RKP_STATE)
                {
                UXCheckbox* cb = new UXCheckbox();
                cb.setTitle(p.label);
                cb.setChecked(RKProps.boolOf(o, p));
                cb.setAction(&self.onToggle);
                pane.addSubview(cb, UXGeom.make((i16)8, y, (i16)((i32)w - (i32)16 - rw), rh));
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
                    f.setText(UXRsc.textOf(o));
                    }
                else
                    {
                    f.setText(RKInspector.fmtInt(RKProps.intOf(o, p)));
                    }
                f.setOnChange(&self.onField);
                pane.addSubview(f, UXGeom.make((i16)((i32)8 + (i32)lw), y,
                                               (i16)((i32)w - (i32)lw - (i32)16 - rw), rh));
                r.field = f;
                }
            // the Vary toggle, beside a property that can differ between layouts
            if (vst >= (i32)0)
                {
                UXButton* vb = new UXButton();
                vb.setTitle(vst == (i32)1 ? (u8*)"Varies" : (u8*)"Vary");
                vb.setAction(&self.onVary);
                pane.addSubview(vb, UXGeom.make((i16)((i32)w - (i32)62), y, (i16)56, rh));
                r.vary = vb;
                }
            rows.add(r);
            y = (i16)((i32)y + (i32)rh + (i32)gap);
            }
        // a UXKit control's settings, which live in the document's attributes
        if (section != (i32)RKIS_SIZE && doc != (UXRscDoc*)0 && tree != (UXRscTree*)0)
            {
            u8* cls = doc.classOf(tree, o);
            Array<RKChoice>* keys = RKInspector.attrKeys(cls);
            for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
                {
                u8* key = ((RKChoice* ?)keys.get(k)).s;
                RKRow* r = new RKRow();
                r.prop = RKProperty.make(key, (i32)RKP_TEXT, (i32)0, (u8*)0);
                r.attrKey = key;
                UXLabel* l = new UXLabel();
                l.setTitle(key);
                pane.addSubview(l, UXGeom.make((i16)8, y, lw, rh));
                UXTextField* f = new UXTextField();
                u8* v = doc.attrOf(tree, o, key);
                f.setText(v != (u8*)0 ? v : (u8*)"");
                f.setOnChange(&self.onField);
                pane.addSubview(f, UXGeom.make((i16)((i32)8 + (i32)lw), y, (i16)((i32)w - (i32)lw - (i32)16), rh));
                r.field = f;
                rows.add(r);
                y = (i16)((i32)y + (i32)rh + (i32)gap);
                }
            }
        loading = false;
        }
    // The settings a UXKit control keeps in attributes, by class (lists are written "A|B|C").
    static Array<RKChoice>* attrKeys(u8* cls)
        {
        Array<RKChoice>* ks = new Array();
        if (cls == (u8*)0)
            {
            return ks;
            }
        if (UXRscDoc.seq(cls, (u8*)"UXSlider"))
            {
            ks.add(RKChoice.of((u8*)"min"));
            ks.add(RKChoice.of((u8*)"max"));
            ks.add(RKChoice.of((u8*)"value"));
            }
        else if (UXRscDoc.seq(cls, (u8*)"UXStepper"))
            {
            ks.add(RKChoice.of((u8*)"min"));
            ks.add(RKChoice.of((u8*)"max"));
            ks.add(RKChoice.of((u8*)"step"));
            ks.add(RKChoice.of((u8*)"value"));
            }
        else if (UXRscDoc.seq(cls, (u8*)"UXProgressBar"))
            {
            ks.add(RKChoice.of((u8*)"total"));
            ks.add(RKChoice.of((u8*)"completed"));
            }
        else if (UXRscDoc.seq(cls, (u8*)"UXSegmentedControl"))
            {
            ks.add(RKChoice.of((u8*)"segments"));
            ks.add(RKChoice.of((u8*)"selected"));
            }
        else if (UXRscDoc.seq(cls, (u8*)"UXComboBox"))
            {
            ks.add(RKChoice.of((u8*)"items"));
            ks.add(RKChoice.of((u8*)"text"));
            }
        return ks;
        }

    // ---- edits, back to the MODEL ------------------------------------------
    // Both hooks find WHICH property changed by matching the widget, because
    // the rows are generated and cannot each have their own method.
    void onField(UXTextField* sender) : action
        {
        if (loading || target == (UXRscObject*)0)
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
            self.warn((Object*)r);
            if (r.attrKey != (u8*)0)
                {
                doc.setAttrOf(tree, target, r.attrKey, RKInspector.dup(sender.text()));
                lastWasAttr = true;
                self.announce();
                return;
                }
            lastProp = r.prop;
            if (r.prop.kind == (i32)RKP_TEXT)
                {
                // Copied: the field's buffer belongs to the driver and is
                // reused, so aliasing it would leave every object edited here
                // sharing one string.
                target.text = RKInspector.dup(sender.text());
                if (target.ted != (UXRscTedinfo*)0)
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
        if (loading || target == (UXRscObject*)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.pop != (UXPopUpButton*)0 && (UXControl*)r.pop == sender)
                {
                i32 wasType = target.type;
                self.warn((Object*)0);
                lastProp = r.prop;
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
        if (loading || target == (UXRscObject*)0)
            {
            return;
            }
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.box != (UXCheckbox*)0 && (UXControl*)r.box == sender)
                {
                self.warn((Object*)0);
                lastProp = r.prop;
                RKProps.setBool(target, r.prop, r.box.isChecked());
                self.announce();
                return;
                }
            }
        }

    void onVary(UXControl* sender) : action
        {
        for (i32 i = (i32)0; i < (i32)rows.count(); i = i + (i32)1)
            {
            RKRow* r = (RKRow* ?)rows.get((u16)i);
            if (r.vary != (UXButton*)0 && (UXControl*)r.vary == sender)
                {
                callback t void(UXRscObject * o, RKProperty * p) = varyToggle;
                if (t)
                    {
                    t(target, r.prop);
                    }
                return;
                }
            }
        }
    void warn(Object* key)
        {
        callback f void(UXRscObject * o, Object * key) = willChange;
        if (f)
            {
            f(target, key);
            }
        }

    void announce(void)
        {
        callback f void(UXRscObject * o) = changed;
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
