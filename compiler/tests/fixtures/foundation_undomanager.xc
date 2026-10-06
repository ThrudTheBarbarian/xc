//xtc-na: xt6502 — UndoManager is not available on xt6502
// foundation_undomanager.xc — UndoManager: undo and redo through
// self-registering setters, action names, groups, redo cleared by a new
// change, disabling, the level limit, and a target that has gone.
#import "Foundation.xc"
#import "UndoManager.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }

class Model : Object
    {
    Number* x;
    UndoManager* undo;

    void init(void)
        {
        x = Number.withI32((i32)0);
        }

    void setX(Object* v)
        {
        undo.registerUndo(&self.setX, x);
        x = (Number*)v;
        }
    }

void show(u8* what, Model* m, UndoManager* u)
    {
    String* un = u.undoActionName();
    String* rn = u.redoActionName();
    Stdio.printf("%-24s x=%@ undo=%d(%@) redo=%d(%@)\n", what, m.x,
                 (i32)(u.canUndo() ? 1 : 0), un == 0 ? S("-") : un,
                 (i32)(u.canRedo() ? 1 : 0), rn == 0 ? S("-") : rn);
    }

i32 main(void)
    {
    UndoManager* u = new UndoManager();
    Model* m = new Model();
    m.undo = u;

    m.setX(Number.withI32((i32)1));
    u.setActionName(S("One"));
    m.setX(Number.withI32((i32)2));
    u.setActionName(S("Two"));
    show("set 1, set 2", m, u);
    u.undo();
    show("undo", m, u);
    u.undo();
    show("undo", m, u);
    u.undo();
    show("undo (nothing)", m, u);
    u.redo();
    show("redo", m, u);
    u.redo();
    show("redo", m, u);

    u.beginUndoGrouping();
    m.setX(Number.withI32((i32)3));
    m.setX(Number.withI32((i32)4));
    u.setActionName(S("Both"));
    u.endUndoGrouping();
    show("group 3, 4", m, u);
    u.undo();
    show("undo group", m, u);
    u.redo();
    show("redo group", m, u);

    u.undo();
    m.setX(Number.withI32((i32)9));
    u.setActionName(S("Nine"));
    show("undo, then new change", m, u);

    u.disableUndoRegistration();
    u.disableUndoRegistration();
    m.setX(Number.withI32((i32)10));
    u.enableUndoRegistration();
    m.setX(Number.withI32((i32)11));
    u.enableUndoRegistration();
    show("disabled twice", m, u);
    m.setX(Number.withI32((i32)12));
    show("enabled", m, u);

    u.removeAllActions();
    u.levelsOfUndo = (u32)2;
    m.setX(Number.withI32((i32)20));
    m.setX(Number.withI32((i32)21));
    m.setX(Number.withI32((i32)22));
    u.undo();
    u.undo();
    u.undo();
    show("levels 2: 3 sets, 3 undos", m, u);

    // A target that has gone is skipped.
    UndoManager* u2 = new UndoManager();
    Model* gone = new Model();
    gone.undo = u2;
    gone.setX(Number.withI32((i32)5));
    gone = (Model*)0;
    u2.undo();
    Stdio.printf("undo after the target went: canRedo=%d\n", (i32)(u2.canRedo() ? 1 : 0));
    return (i32)0;
    }
