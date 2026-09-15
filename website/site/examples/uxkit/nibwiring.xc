// nibwiring.xc — the `outlet` / `:action` decorations, and the two methods the
// compiler generates from them.
//
// No nib is loaded here: the point is that declaring the decorations is ALL a
// class does to become wireable. UXDesignable conformance and both method
// bodies are generated, and can be called directly — which is what the loader
// does when it wires a resource's connections by name.
#import <Stdio.xc>
#import "UXControl.xc"
#import "UXDesignable.xc"

i32 gApplied;

// Declaring any `outlet` field or `:action` method auto-conforms the class to
// UXDesignable. Note that `<UXDesignable>` is NOT written here.
class PrefsController : Object
{
    outlet UXTextField* nameField;
    outlet UXCheckbox*  showGrid;

    void init(void) { gApplied = (i32)0; }

    void onApply(UXControl* c)  :action { gApplied = gApplied + (i32)1; }
    void onCancel(UXControl* c) :action { }
}

void main(void) {
    PrefsController* p = new PrefsController();

    // --- the generated setOutlet ---------------------------------------------
    UXTextField* field = new UXTextField();
    Stdio.printf("assign nameField: %d\n",
                 p.setOutlet((u8*)"nameField", (Object*)field) ? 1 : 0);
    Stdio.printf("  landed in the field: %d\n",
                 p.nameField == field ? 1 : 0);

    // An unknown name is a false, not a crash — a nib naming an outlet this
    // class no longer has simply fails to connect.
    Stdio.printf("unknown name: %d\n",
                 p.setOutlet((u8*)"nope", (Object*)field) ? 1 : 0);

    // The assignment is a CHECKED cast against the declared type, so a
    // connection of the wrong kind is refused rather than mis-assigned.
    //
    // Note what a refusal does to the field: it CLEARS it rather than leaving
    // the previous value. That does not matter on a nib load, where each outlet
    // is connected once from null — but it means a false return is not "nothing
    // happened".
    UXCheckbox* box = new UXCheckbox();
    Stdio.printf("wrong type into nameField: %d\n",
                 p.setOutlet((u8*)"nameField", (Object*)box) ? 1 : 0);
    Stdio.printf("  field kept its old value: %d   is now null: %d\n",
                 p.nameField == field ? 1 : 0,
                 p.nameField == (UXTextField*)0 ? 1 : 0);

    // --- the generated wireAction --------------------------------------------
    UXButton* apply = new UXButton();
    Stdio.printf("wire onApply: %d\n",
                 p.wireAction((u8*)"onApply", (UXControl*)apply) ? 1 : 0);

    // The control now calls the method. Firing it proves the binding is real
    // rather than recorded.
    apply.fire();
    Stdio.printf("  applied count: %d\n", gApplied);

    Stdio.printf("unknown action: %d\n",
                 p.wireAction((u8*)"nope", (UXControl*)apply) ? 1 : 0);
}
