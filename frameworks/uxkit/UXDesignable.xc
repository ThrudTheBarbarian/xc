// UXDesignable.xc — the nib reflection protocol (doc/UXKit-NIB.md §4).
//
// A class that declares any `outlet` field or `:action` method AUTO-CONFORMS to this protocol; the
// compiler generates both method bodies from the decorations (setOutlet: a checked assignment per
// outlet; wireAction: control.setAction(&self.<method>) per action).  UXNib.load reaches a loaded
// object through this protocol to wire a nib's connections by name — no per-app code, and no
// reflection beyond what the `outlet`/`action` decorations already declare and the compiler checks.
//
// (`: Object <UXDesignable>` written by hand is equivalent to the auto-apply; either way the bodies
// are compiler-generated.  See the note in UXKit-NIB.md on why wireAction BINDS rather than returning
// the callback: a `callback` RETURN type does not parse and a reference to one does not round-trip
// yet, but a callback held as a local — which is all wireAction needs — works.  (This read `T^`
// before the 0.5 rename; the sigil is gone, the constraint is unchanged.))
#import "UXControl.xc"

protocol UXDesignable
    {
    // Assign the named `outlet` field with a checked cast.  false = unknown name or type mismatch.
    bool setOutlet(u8 * name, Object * value);
    // Bind the named `:action` method to the control's action, inside this call.  false = unknown.
    bool wireAction(u8 * name, UXControl * control);
    }
