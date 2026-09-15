// UXUndoManager.xc — a neutral undo/redo stack, AppKit's NSUndoManager in shape.
//
// The whole trick of undo is one idea: an undoable change registers, at the moment it happens, the
// call that would put things back.  To undo, you invoke that call — and because putting things back is
// itself a change, THAT call registers its own inverse, which becomes the redo.  So undo and redo are
// the same machine run in opposite directions; there is no second "redo" bookkeeping.
//
//     // in the model, whenever x changes:
//     undo.registerUndo(&self.setX, box(oldX));       // "to undo, set x back to oldX"
//     undo.setActionName("Change X");
//     ...
//     undo.undo();    // calls setX(oldX); setX registers setX(newX) as the redo
//     undo.redo();    // calls setX(newX); which registers setX(oldX) as the undo again
//
// Registrations are collected into GROUPS so several model edits undo as one user action; a group is
// opened implicitly around a single registration, or explicitly with begin/endUndoGrouping.  While a
// group is being undone, every re-registration lands in one fresh group that is pushed to the OTHER
// stack — that is what makes a whole multi-edit action redo in one step.
#import "Array.xc"

// One recorded inverse.  `block` is a callback, so it never owns the target — the model —
// which matters here: a model that owns its undo manager would otherwise be a retain cycle,
// and NSUndoManager likewise does not retain targets.  `arg` IS retained: it is the data to
// restore.
class UXUndoOp
    {
    callback block void(Object* arg);
    Object* arg;
    void init(void)
        {
        block = (callback void(Object * arg))0;
        arg = (Object*)0;
        }
    }

    // A group of inverses that undo together, newest last (undo runs them in reverse).
    class UXUndoGroup
    {
    Array<UXUndoOp>* ops;
    u8* name; // the action name shown in "Undo <name>" (0 = none)
    void init(void)
        {
        ops = new Array();
        name = (u8*)0;
        }
    }

// mode: which direction the machine is running, so a re-registration is routed to the right stack.
#define UX_UNDO_NORMAL 0
#define UX_UNDO_UNDOING 1
#define UX_UNDO_REDOING 2

    class UXUndoManager
    {
    Array<UXUndoGroup>* undoStack; // of UXUndoGroup, newest last
    Array<UXUndoGroup>* redoStack;
    UXUndoGroup* openGroup; // the group currently collecting registrations (0 = none open)
    i32 groupLevel;         // explicit begin/end nesting depth
    i32 mode;
    u8* pendingName; // setActionName before end-of-group stamps the group
    bool enabled;    // disableUndoRegistration() drops registrations (e.g. during load)

    void init(void)
        {
        undoStack = new Array();
        redoStack = new Array();
        openGroup = (UXUndoGroup*)0;
        groupLevel = (i32)0;
        mode = (i32)UX_UNDO_NORMAL;
        pendingName = (u8*)0;
        enabled = true;
        }

    // ---- registration --------------------------------------------------------
    // Record "to undo, call block(arg)".  Outside an explicit group this is its own one-op group.
    void registerUndo(callback block void(Object* arg), Object* arg)
        {
        if (!enabled)
            {
            return;
            }
        bool implicit = (groupLevel == (i32)0);
        if (implicit)
            {
            self.beginUndoGrouping();
            }
        UXUndoOp* op = new UXUndoOp();
        op.block = block;
        op.arg = arg;
        openGroup.ops.add(op);
        if (implicit)
            {
            self.endUndoGrouping();
            }
        }

    // Name the action.  Inside an open group it stamps that group when it closes; called just after a
    // single (already-closed) registration it names the most recent group on the current stack — so
    // the common `setX(); setActionName("…")` idiom labels the edit it follows.
    void setActionName(u8* name)
        {
        pendingName = name;
        if (groupLevel == (i32)0)
            {
            Array<UXUndoGroup>* s = self.destStack();
            if (s.count() > (u16)0)
                {
                UXUndoGroup* g = (UXUndoGroup* ?)s.get((u16)(s.count() - (u16)1));
                g.name = name;
                }
            }
        }

    // ---- grouping ------------------------------------------------------------
    void beginUndoGrouping(void)
        {
        if (groupLevel == (i32)0)
            {
            openGroup = new UXUndoGroup();
            }
        groupLevel = groupLevel + (i32)1;
        }
    void endUndoGrouping(void)
        {
        if (groupLevel == (i32)0)
            {
            return;
            }
        groupLevel = groupLevel - (i32)1;
        if (groupLevel != (i32)0 || openGroup == (UXUndoGroup*)0)
            {
            return;
            }
        if (openGroup.ops.count() > (u16)0)
            {
            if (pendingName != (u8*)0)
                {
                openGroup.name = pendingName;
                }
            Array* dest = self.destStack();
            dest.add(openGroup);
            // A brand-new user action (registered in NORMAL mode) makes any redo history stale.
            if (mode == (i32)UX_UNDO_NORMAL)
                {
                redoStack.removeAll();
                }
            }
        openGroup = (UXUndoGroup*)0;
        pendingName = (u8*)0;
        }
    // Where a closed group goes: undoing collects the redo, everything else builds the undo stack.
    Array<UXUndoGroup>* destStack(void)
        {
        if (mode == (i32)UX_UNDO_UNDOING)
            {
            return redoStack;
            }
        return undoStack;
        }

    // ---- running the machine -------------------------------------------------
    void invokeGroup(UXUndoGroup* g)
        {
        i32 n = (i32)g.ops.count();
        // reverse: last change undone first
        for (i32 i = n - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            UXUndoOp* op = (UXUndoOp* ?)g.ops.get((u16)i);
            callback b void(Object * arg) = op.block; // auto-zeroed if the target is gone
            if (b != (callback void(Object * arg))0)
                {
                b(op.arg);
                }
            }
        }
    void undo(void)
        {
        if (undoStack.count() == (u16)0)
            {
            return;
            }
        UXUndoGroup* g = (UXUndoGroup* ?)undoStack.get((u16)(undoStack.count() - (u16)1));
        undoStack.removeLast();
        mode = (i32)UX_UNDO_UNDOING;
        self.beginUndoGrouping(); // re-registrations during the invoke form one redo group...
        if (g.name != (u8*)0)
            {
            pendingName = g.name;
            }
        self.invokeGroup(g);
        self.endUndoGrouping(); // ...pushed to redoStack because mode == UNDOING
        mode = (i32)UX_UNDO_NORMAL;
        }
    void redo(void)
        {
        if (redoStack.count() == (u16)0)
            {
            return;
            }
        UXUndoGroup* g = (UXUndoGroup* ?)redoStack.get((u16)(redoStack.count() - (u16)1));
        redoStack.removeLast();
        mode = (i32)UX_UNDO_REDOING; // re-registrations rebuild the undo stack (destStack default)
        self.beginUndoGrouping();
        if (g.name != (u8*)0)
            {
            pendingName = g.name;
            }
        self.invokeGroup(g);
        self.endUndoGrouping();
        mode = (i32)UX_UNDO_NORMAL;
        }

    // ---- queries / housekeeping ----------------------------------------------
    bool canUndo(void)
        {
        return undoStack.count() > (u16)0;
        }
    bool canRedo(void)
        {
        return redoStack.count() > (u16)0;
        }
    u8* undoActionName(void)
        {
        if (undoStack.count() == (u16)0)
            {
            return (u8*)0;
            }
        return ((UXUndoGroup* ?)undoStack.get((u16)(undoStack.count() - (u16)1))).name;
        }
    u8* redoActionName(void)
        {
        if (redoStack.count() == (u16)0)
            {
            return (u8*)0;
            }
        return ((UXUndoGroup* ?)redoStack.get((u16)(redoStack.count() - (u16)1))).name;
        }
    void removeAllActions(void)
        {
        undoStack.removeAll();
        redoStack.removeAll();
        openGroup = (UXUndoGroup*)0;
        groupLevel = (i32)0;
        mode = (i32)UX_UNDO_NORMAL;
        }
    void disableUndoRegistration(void)
        {
        enabled = false;
        }
    void enableUndoRegistration(void)
        {
        enabled = true;
        }
    bool isUndoRegistrationEnabled(void)
        {
        return enabled;
        }
    bool isUndoing(void)
        {
        return mode == (i32)UX_UNDO_UNDOING;
        }
    bool isRedoing(void)
        {
        return mode == (i32)UX_UNDO_REDOING;
        }
    }
