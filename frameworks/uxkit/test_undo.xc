// test_undo.xc — UXUndoManager: undo and redo are one machine run in opposite directions.
//
// Pure model test (no driver): a Model with one undoable property whose setter registers its own
// inverse, exactly like an NSUndoManager -setX: does.  Checks the stacks, grouping, action names,
// and the rule that a fresh edit throws the redo history away.
#import <Stdio.xc>
#import "UXUndoManager.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

class IntBox : Object
    {
    i32 v;
    void init(void)
        {
        v = (i32)0;
        }
    } IntBox* box(i32 v)
    {
    IntBox* b = new IntBox();
    b.v = v;
    return b;
    }

class Model : Object
    {
    UXUndoManager* undo;
    i32 x;
    void init(void)
        {
        undo = new UXUndoManager();
        x = (i32)0;
        }
    // The setter IS the undo block: setting x records the call that restores the old x.
    void setX(Object* arg)
        {
        i32 old = x;
        x = ((IntBox* ?)arg).v;
        undo.registerUndo(&self.setX, (Object*)box(old));
        }
    void setXNamed(i32 v, u8* name)
        {
        self.setX((Object*)box(v));
        undo.setActionName(name);
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    Model* m = new Model();
    UXUndoManager* u = m.undo;

    // ---- 1. basic undo/redo ------------------------------------------------
    check("start x", m.x, (i32)0);
    check("nothing to undo yet", u.canUndo() ? (i32)1 : (i32)0, (i32)0);
    m.setX((Object*)box((i32)1));
    m.setX((Object*)box((i32)2));
    m.setX((Object*)box((i32)3));
    check("x after three sets", m.x, (i32)3);
    check("canUndo", u.canUndo() ? (i32)1 : (i32)0, (i32)1);
    check("canRedo (none yet)", u.canRedo() ? (i32)1 : (i32)0, (i32)0);

    u.undo();
    check("undo -> 2", m.x, (i32)2);
    check("canRedo now", u.canRedo() ? (i32)1 : (i32)0, (i32)1);
    u.undo();
    check("undo -> 1", m.x, (i32)1);
    u.undo();
    check("undo -> 0", m.x, (i32)0);
    check("canUndo exhausted", u.canUndo() ? (i32)1 : (i32)0, (i32)0);

    u.redo();
    check("redo -> 1", m.x, (i32)1);
    u.redo();
    check("redo -> 2", m.x, (i32)2);
    u.redo();
    check("redo -> 3", m.x, (i32)3);
    check("canRedo exhausted", u.canRedo() ? (i32)1 : (i32)0, (i32)0);

    // ---- 2. a fresh edit discards the redo history -------------------------
    u.undo();
    check("undo -> 2 again", m.x, (i32)2);
    check("redo available", u.canRedo() ? (i32)1 : (i32)0, (i32)1);
    m.setX((Object*)box((i32)9)); // new branch
    check("x is 9", m.x, (i32)9);
    check("redo thrown away by the new edit", u.canRedo() ? (i32)1 : (i32)0, (i32)0);

    // ---- 3. explicit grouping: several edits undo as ONE -------------------
    u.removeAllActions();
    m.x = (i32)0;
    u.beginUndoGrouping();
    m.setX((Object*)box((i32)10));
    m.setX((Object*)box((i32)20));
    m.setX((Object*)box((i32)30));
    u.endUndoGrouping();
    check("grouped edits landed", m.x, (i32)30);
    u.undo();
    check("one undo reverts the WHOLE group", m.x, (i32)0);
    u.redo();
    check("one redo re-applies the WHOLE group", m.x, (i32)30);

    // ---- 4. action names ---------------------------------------------------
    u.removeAllActions();
    m.setXNamed((i32)5, (u8*)"Set Five");
    u8* nm = u.undoActionName();
    check("undo action name present", nm != (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // ---- 5. disabled registration -----------------------------------------
    u.removeAllActions();
    u.disableUndoRegistration();
    m.setX((Object*)box((i32)7));
    u.enableUndoRegistration();
    check("x set while disabled", m.x, (i32)7);
    check("but nothing was recorded", u.canUndo() ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXUndoManager — undo/redo, grouping, redo-invalidation, names, disable.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
