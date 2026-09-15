// undo.xc — undo and redo are the SAME machine run in opposite directions.
//
// An undoable change registers, as it happens, the call that would put things
// back. Undoing invokes that call — and because putting things back is itself a
// change, it registers ITS inverse, which becomes the redo. No second stack of
// bookkeeping; headless, so it runs with no window at all.
#import <Stdio.xc>
#import "UXUndoManager.xc"

// A boxed int, so a value can ride along as the callback's argument.
class Box : Object {
    i32 v;
    void init(void) { v = 0; }
    static Box* of(i32 x) { Box* b = new Box(); b.v = x; return b; }
}

class Model : Object {
    i32 x;
    UXUndoManager* undo;
    void init(void) { x = 0; undo = new UXUndoManager(); }

    // The whole pattern: register the inverse BEFORE changing.
    void setX(Object* arg) {
        i32 want = ((Box* ?)arg).v;
        undo.registerUndo(&self.setX, (Object*)Box.of(x));   // "to undo, put x back"
        undo.setActionName((u8*)"Change X");
        x = want;
    }
}

void main(void) {
    Model* m = new Model();

    m.setX((Object*)Box.of(10));
    m.setX((Object*)Box.of(20));
    m.setX((Object*)Box.of(30));
    Stdio.printf("x=%d  canUndo=%d canRedo=%d\n", m.x, m.undo.canUndo() ? 1 : 0, m.undo.canRedo() ? 1 : 0);

    m.undo.undo();
    Stdio.printf("after undo  x=%d  canRedo=%d\n", m.x, m.undo.canRedo() ? 1 : 0);
    m.undo.undo();
    Stdio.printf("after undo  x=%d\n", m.x);
    m.undo.redo();
    Stdio.printf("after redo  x=%d\n", m.x);

    // A GROUP makes several model edits undo as ONE user action.
    m.undo.beginUndoGrouping();
    m.setX((Object*)Box.of(100));
    m.setX((Object*)Box.of(200));
    m.undo.endUndoGrouping();
    Stdio.printf("grouped to x=%d\n", m.x);
    m.undo.undo();
    Stdio.printf("one undo takes the WHOLE group back to x=%d\n", m.x);

    // Loading a document should not be undoable. Clear first, so canUndo == 0
    // PROVES the disabled edit registered nothing rather than merely leaving
    // earlier actions on the stack.
    m.undo.removeAllActions();
    Stdio.printf("cleared:    canUndo=%d\n", m.undo.canUndo() ? 1 : 0);
    m.undo.disableUndoRegistration();
    m.setX((Object*)Box.of(999));
    m.undo.enableUndoRegistration();
    Stdio.printf("after a disabled edit x=%d canUndo=%d (nothing registered)\n",
                 m.x, m.undo.canUndo() ? 1 : 0);
}
