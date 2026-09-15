// UXControl.xc — target/action, in one field.
//
// This used to be a hand-rolled (target, action) pair, because xtc had no method
// pointers and a bare function pointer cannot carry `self`.  It has callbacks now,
// so the pair collapses to one field that carries both:
//
//     callback action void(UXControl* sender);     // (recv, code), in one value
//
// A callback NEVER owns its receiver, and a stored one AUTO-ZEROES when that
// receiver dies.  Both halves matter here, and they are the language's guarantee
// rather than this file's discipline (xcc 0.5; private:docs/Design/bound-methods.md §6):
//
//   1. A control must NOT own its controller, or
//          window -> viewtree -> button -> action -> window
//      is a retain cycle.  AppKit needs a separate weak `target` field to break
//      it; here the callback's non-ownership IS the break.
//
//   2. `if (action)` reads as "no action set" AND "the target has been
//      deallocated", with the same syntax and no extra machinery.  A dead
//      controller is simply an action that no longer fires.
//
// This used to be spelled `weak: UXAction^ action;`, where the `weak:` was
// load-bearing rather than decorative.  It is now neither needed nor accepted:
// the auto-zeroing is unconditional for a stored callback, with no keyword and
// no way to opt out — which is the point.  A callback is deliberately NOT a
// block: a block owns its captures, a callback never owns its receiver.
#import "UXView.xc"
#import "UXViewDriver.xc"
#import "UXEvent.xc"
#import "UXTextLayout.xc" // UX_ALIGN_*
#import "UXString.xc"     // UXStr.append — the field announcement copies its text

class UXControl : UXView
    {
    callback action void(UXControl* sender);
    u8* title;
    // How the text sits in the control's box: UX_ALIGN_LEFT / CENTER / RIGHT.
    //
    // It lives on the CONTROL rather than in the shadow tree because the
    // drivers already read a control's own state from its peer when they
    // realize it (the same read that pushes a check box's tick), so alignment
    // needs no new node field on seven backends to travel.
    //
    // Why it matters at all: a column of "Name:" "Size:" "Kind:" labels only
    // lines its colons up if the text is RIGHT-aligned in boxes whose right
    // edges agree.  Left-aligned text makes that impossible however carefully
    // the boxes are placed, because the colon's position then depends on the
    // length of the word before it.
    i32 align;

    void init(void)
        {
        super.init();
        action = (callback void(UXControl * sender))0;
        title = "";
        align = (i32)UX_ALIGN_LEFT;
        }

    void setAlignment(i32 a)
        {
        align = a;
        // the next realize pushes it
        if (owner != (UXViewTree*)0)
            {
            self.setNeedsDisplay();
            }
        }
    i32 alignment(void)
        {
        return align;
        }

    // &controller.onOK — a method, bound to its receiver.  No downcast, no selector.
    void setAction(callback a void(UXControl* sender))
        {
        action = a;
        }
    void setTitle(u8* s)
        {
        title = s;
        }

    void fire(void)
        {
        // false if unset OR if the target died
        if (action)
            {
            action(self);
            }
        }

    // A control consumes its click — it does not pass it up the chain.
    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        self.fire();
        }
    }

    // A real G_BUTTON.  We write NO drawing code: the AES themes it, exactly as it
    // themes a button in any other GEM app.
    class UXButton : UXControl
    {
    UXKind kind(void)
        {
        return UXKindButton;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setSpecOf(index, (pointer)title); // a button's content is its label
        t.setPeerOf(index, (pointer)self);  // so a native backend can fire the action directly
        t.setSelectableOf(index, true);
        }
    }

    // A static text label — no behaviour, just its text.  kind() is Label, which the GEM driver
    // realizes as a native G_STRING and the Win32 driver paints in its Label branch, so the toolkit
    // writes no drawing.  setText before OR after attach both work (spec follows the title).
    class UXLabel : UXControl
    {
    UXKind kind(void)
        {
        return UXKindLabel;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setSpecOf(index, (pointer)title);
        // A label has no action to fire, but the drivers read a control's own
        // state off its peer -- which is how alignment reaches the native text
        // field.  Without this a label could be told to right-align and would
        // silently stay left.
        t.setPeerOf(index, (pointer)self);
        }
    void setText(u8* s)
        {
        title = s;
        if (owner != (UXViewTree*)0)
            {
            owner.setSpecOf(index, (pointer)s);
            self.setNeedsDisplay();
            }
        }
    u8* text(void)
        {
        return title;
        }
    }

    // A checkbox.  Unlike UXButton (a native G_BUTTON) this is CUSTOM-DRAWN: GEM has no native
    // checkbox object and neither does a bare Win32 window class, so the control paints itself with
    // the neutral UXGraphics primitives and is therefore identical on every backend — kind() is
    // View (a G_USERDEF on GEM), so the driver just calls drawRect.  State lives here; a click
    // toggles it and fires target/action, exactly like a button that remembers.
    class UXCheckbox : UXControl
    {
    bool checked;

    void init(void)
        {
        super.init();
        checked = false;
        }
    // native where the backend has it, app-drawn else
    UXKind kind(void)
        {
        return UXKindCheckbox;
        }
    // Expose the label + self to the driver: a native backend (Win32) builds a real check box from
    // them; GEM/AppKit ignore both (setPeerOf is a no-op there) and app-draw via drawRect below.
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setSpecOf(index, (pointer)title);
        t.setPeerOf(index, (pointer)self);
        }

    bool isChecked(void)
        {
        return checked;
        }
    void setChecked(bool c)
        {
        checked = c;
        self.setNeedsDisplay();
        }

    // A square box (black frame, white interior) with a checkmark when checked — the GEM/desktop look
    // (Win32/AppKit realize a NATIVE check box, so this drawRect only runs on GEM + headless).
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i32 ink = self.isEnabled() ? (i32)1 : (i32)8; // grey the label when disabled
        // The themed check box sprite at its NATIVE 21x21 (theme_blit stretches, so any other size blurs
        // the art).  Aristo2 on GEM; the other backends realize a NATIVE check box and skip this drawRect.
        i16 sy = (i16)(((i32)b.h - (i32)21) / (i32)2);
        if (sy < (i16)0)
            {
            sy = (i16)0;
            }
        g.drawTheme(checked ? (u8*)"check.selected" : (u8*)"check", UXGeom.make((i16)0, sy, (i16)21, (i16)21));
        g.drawText(title, (i16)24, (i16)(((i32)b.h - (i32)12) / (i32)2), ink, (i32)0);
        }

    // Toggle, then fire — the app hears the new state through the action.
    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        checked = checked ? false : true;
        self.setNeedsDisplay();
        self.fire();
        }
    bool acceptsFirstResponder(void)
        {
        return self.isEnabled();
        }
    }

    // A radio button: like a checkbox, but exactly one in its GROUP is selected at a time.  Also
    // custom-drawn (kind View) — neither backend has a native radio — so it runs identically on
    // GEM and Win32.  The mutual exclusion is pure neutral logic in UXRadioGroup: clicking a button
    // asks the group to select it, and the group clears the others.
    class UXRadioButton : UXControl
    {
    bool selected;
    weak : UXRadioGroup* group; // weak: the group owns the button, not the reverse

    void init(void)
        {
        super.init();
        selected = false;
        group = (UXRadioGroup*)0;
        }
    UXKind kind(void)
        {
        return UXKindRadio;
        }
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setSpecOf(index, (pointer)title);
        t.setPeerOf(index, (pointer)self);
        }

    bool isSelected(void)
        {
        return selected;
        }
    void setSelected(bool s)
        {
        selected = s;
        self.setNeedsDisplay();
        }

    // A round button (black ring, white interior) with a central dot when selected — the GEM look
    // (Win32/AppKit realize a NATIVE radio, so this only runs on GEM + headless).
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i32 ink = self.isEnabled() ? (i32)1 : (i32)8; // grey the label when disabled
        i16 sy = (i16)(((i32)b.h - (i32)21) / (i32)2);
        if (sy < (i16)0)
            {
            sy = (i16)0;
            }
        if (g.hasThemeArt())
            {
            g.drawTheme(selected ? (u8*)"radio.selected" : (u8*)"radio", UXGeom.make((i16)0, sy, (i16)21, (i16)21));
            }
        else
            {
            // No sprite atlas on this backend: a geometric ring with a filled dot.
            i16 cx = (i16)10;
            i16 cy = (i16)(sy + (i16)10);
            g.fillCircle(cx, cy, (i16)8, (i32)9);
            g.fillCircle(cx, cy, (i16)7, (i32)0);
            if (selected)
                {
                g.fillCircle(cx, cy, (i16)4, (i32)1);
                }
            }
        g.drawText(title, (i16)24, (i16)(((i32)b.h - (i32)12) / (i32)2), ink, (i32)0);
        }

    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        if (group != (UXRadioGroup*)0)
            {
            group.select(self);
            }
        else
            {
            self.setSelected(true);
            }
        self.fire();
        }
    bool acceptsFirstResponder(void)
        {
        return self.isEnabled();
        }
    }

    // The exclusion set.  It STRONG-refs its buttons (the tree does too — shared ownership is fine,
    // there is no cycle because the button's back-reference is weak).  select() clears every button
    // but the chosen one; that IS the whole of "radio behaviour".
    class UXRadioGroup : Object
    {
    Array* buttons;
    void init(void)
        {
        buttons = new Array();
        }

    void add(UXRadioButton* b)
        {
        buttons.add(b);
        b.group = self;
        }

    void select(UXRadioButton* chosen)
        {
        for (Object* o in buttons)
            {
            UXRadioButton* b = (UXRadioButton* ?)o;
            if (b != (UXRadioButton*)0)
                {
                b.setSelected(b == chosen);
                }
            }
        }
    UXRadioButton* selected(void)
        {
        for (Object* o in buttons)
            {
            UXRadioButton* b = (UXRadioButton* ?)o;
            if (b != (UXRadioButton*)0 && b.isSelected())
                {
                return b;
                }
            }
        return (UXRadioButton*)0;
        }
    }

    // ---------------------------------------------------------------------------------
    // UXTextField — an editable text field.
    //
    // It contains NO TEXT-EDITING CODE.  Not "a little"; none.
    //
    // A G_FTEXT object with OF_EDITABLE and a TEDINFO is exactly what GEM's edit engine
    // operates on, so insert, Backspace, Delete, arrows, Ctrl-U, the caret (and its
    // survival across a full redraw), and per-character validation are all objc_edit's
    // job.  We hand it a buffer and forward the keys.
    //
    // This is the same bargain as UXButton, which contains no drawing code: if Xtg is
    // re-implementing something GEM already does, that is a bug in Xtg.
    // Fired on every edit (per keystroke), weak like `action` so the field never owns its
    // controller.  The buffer is already truthful when this fires — read sender.text().
    class UXTextField : UXControl
    {
    u8* buf; // the text; the driver's editor points at it
    u16 cap;
    i32 caret;                                   // the edit engine carries the caret in and out through this
    pointer editor;                              // the backend field-editor bound to buf (GEM: a TEDINFO)
    u8* place;                                   // placeholder prompt shown while empty (AppKit/Win32; GEM ignores it)
    bool secure;                                 // mask input as a password (AppKit/Win32; GEM shows plain text)
    callback onChange void(UXTextField* sender); // per-keystroke hook; never owns its receiver

    void init(void)
        {
        super.init();
        cap = (u16)128;
        buf = (u8*)malloc((u32)cap);
        buf[0] = (u8)0;
        caret = (i32)0;
        editor = (pointer)0; // the driver makes it in attachTo
        place = (u8*)0;
        secure = false;
        onChange = (callback void(UXTextField * sender))0;
        }

    void dealloc(void)
        {
        if (editor != (pointer)0)
            {
            gDriver.fieldEditorFree(editor);
            }
        }

    UXKind kind(void)
        {
        return UXKindField;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        editor = gDriver.fieldEditorNew(buf, (i32)cap); // a field's content is its editor
        t.setSpecOf(index, editor);
        t.setPeerOf(index, (pointer)self); // so a native backend can call fieldDidChange
        t.setEditableOf(index, true);
        if (place != (u8*)0)
            {
            gDriver.fieldEditorSetPlaceholder(editor, place);
            }
        if (secure)
            {
            gDriver.fieldEditorSetSecure(editor, (i32)1);
            }
        }

    void setOnChange(callback c void(UXTextField* sender))
        {
        onChange = c;
        }

    // A grey prompt shown while the field is empty.  Set it before OR after attach.
    void setPlaceholder(u8* s)
        {
        place = s;
        if (editor != (pointer)0)
            {
            gDriver.fieldEditorSetPlaceholder(editor, s);
            }
        }

    // Mask input as a password.  Set it before attach (the native control type is chosen then).
    void setSecure(bool on)
        {
        secure = on;
        if (editor != (pointer)0)
            {
            gDriver.fieldEditorSetSecure(editor, on ? (i32)1 : (i32)0);
            }
        }

    // The backend calls this after the native field's text changed (buf already synced); on GEM
    // the neutral keyDown IS the edit engine, so it calls it directly.  One notification path.
    // BOTH native backends funnel here after syncing the buffer (Win32 EN_CHANGE, AppKit
    // controlTextDidChange), so one announcement covers them — the same reason scrollTo is the only
    // place a scroll is announced.  The text is COPIED: the field's buffer keeps changing as the
    // user types, and a recording must hold what was typed then, not what is there now.
    void fieldDidChange(void)
        {
        if (gEventTap != (callback void(UXEvent * e))0 && !gInputReplay)
            {
            UXEvent* ev = new UXEvent();
            ev.kind = (u8)UXEventTextChanged;
            ev.a = (i32)self.index;
            ev.data = (Object*)String.withCString(self.text()); // copied: the buffer keeps changing
            gEventTap(ev);
            }
        if (onChange)
            {
            onChange(self);
            }
        }

    // A per-input-position validation string — '9' digits, 'A' upper+space, 'a' letters,
    // 'X' anything...  the edit engine enforces it on every keystroke, for free.
    void setValidation(u8* v)
        {
        gDriver.fieldEditorSetValid(editor, v);
        }

    u8* text(void)
        {
        return buf;
        }
    void setText(u8* s)
        {
        u16 i = (u16)0;
        while (s[i] != (u8)0 && i < cap - (u16)1)
            {
            buf[i] = s[i];
            i = i + (u16)1;
            }
        buf[i] = (u8)0;
        caret = (i32)i;
        self.setNeedsDisplay();
        }

    // ---- first responder: focus IS the caret ---------------------------------
    bool acceptsFirstResponder(void)
        {
        return self.isEnabled();
        }

    bool becomeFirstResponder(void)
        {
        owner.editText(index, (i32)0, &caret, (i32)UXEditBegin);
        self.setNeedsDisplay();
        return true;
        }

    bool resignFirstResponder(void)
        {
        owner.editText(index, (i32)0, &caret, (i32)UXEditEnd);
        self.setNeedsDisplay();
        return true;
        }

    // ---- the whole of "text editing" -----------------------------------------
    void keyDown(UXEvent* e)
        {
        i32 used = owner.editText(index, (i32)e.key, &caret, (i32)UXEditKey);
        if (used != (i32)0)
            {
            self.setNeedsDisplay(); // objc_edit redrew the field; we still owe the
            self.fieldDidChange();  // GEM path: the neutral keyDown IS the edit engine
            return;                 // window a damage rect for the composite
            }
        super.keyDown(e); // not ours (Tab, Return, a shortcut) -> up the chain
        }
    }
