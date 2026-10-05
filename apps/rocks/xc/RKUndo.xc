// RKUndo.xc — undo and redo, by snapshot.
//
// Before each edit the controller records a copy of the whole document (UXRscDoc.deepCopy), and
// undo swaps the current document for the last copy.  A copy of the model rather than of its
// written bytes, so undoing never loses what the file format cannot hold yet, and no edit needs an
// inverse of its own: a new kind of edit is undoable the day it records a snapshot first.
//
// Keystrokes into one inspector field are one step: a snapshot recorded with the same key as the
// last one is skipped, until something else (a new selection, another kind of edit) breaks the
// run.
#import "Array.xc"
#import "UXRscModel.xc"

// One state to go back (or forward) to: the document, and where the designer was in it.
class RKUndoStep : Object
    {
    UXRscDoc* doc;
    u8* label;      // what the step undoes: "Move", "Typing", "New Layout"
    i32 tree;       // the tree on the canvas
    i32 selection;  // the selected object's pre-order index in that tree, or -1

    static RKUndoStep* make(UXRscDoc* d, u8* label, i32 tree, i32 selection)
        {
        RKUndoStep* s = new RKUndoStep();
        s.doc = d;
        s.label = label;
        s.tree = tree;
        s.selection = selection;
        return s;
        }
    }

class RKUndoStack : Object
    {
    Array<RKUndoStep>* undos;
    Array<RKUndoStep>* redos;
    Object* lastKey; // the run being coalesced, or 0
    i32 limit;       // the oldest steps go once there are this many

    void init(void)
        {
        undos = new Array();
        redos = new Array();
        lastKey = (Object*)0;
        limit = (i32)200;
        }

    // Snapshot `doc` before an edit.  A step with the same non-zero key as the last one is part of
    // the same run and records nothing.  Any new step empties the redo list.
    void record(UXRscDoc* doc, u8* label, i32 tree, i32 selection, Object* key)
        {
        if (doc == (UXRscDoc*)0)
            {
            return;
            }
        if (key != (Object*)0 && key == lastKey && undos.count() > (u32)0)
            {
            return;
            }
        lastKey = key;
        undos.add(RKUndoStep.make(doc.deepCopy(), label, tree, selection));
        while ((i32)undos.count() > limit)
            {
            undos.removeAt((u32)0);
            }
        redos = new Array();
        }
    // Push a snapshot taken earlier: a drag copies the document when the press lands, and pushes
    // the copy only once the press turns out to be a move.
    void push(UXRscDoc* snapshot, u8* label, i32 tree, i32 selection)
        {
        lastKey = (Object*)0;
        undos.add(RKUndoStep.make(snapshot, label, tree, selection));
        while ((i32)undos.count() > limit)
            {
            undos.removeAt((u32)0);
            }
        redos = new Array();
        }
    // The last snapshot was for an edit that did not happen after all.
    void discardLast(void)
        {
        if (undos.count() > (u32)0)
            {
            undos.removeAt(undos.count() - (u32)1);
            }
        lastKey = (Object*)0;
        }
    // A new run starts with the next edit (the selection moved, say).
    void breakRun(void)
        {
        lastKey = (Object*)0;
        }
    void clear(void)
        {
        undos = new Array();
        redos = new Array();
        lastKey = (Object*)0;
        }

    bool canUndo(void)
        {
        return undos.count() > (u32)0;
        }
    bool canRedo(void)
        {
        return redos.count() > (u32)0;
        }
    u8* undoLabel(void)
        {
        return self.canUndo() ? ((RKUndoStep* ?)undos.get(undos.count() - (u32)1)).label : (u8*)"";
        }
    u8* redoLabel(void)
        {
        return self.canRedo() ? ((RKUndoStep* ?)redos.get(redos.count() - (u32)1)).label : (u8*)"";
        }

    // The state to go back to, with the current one (`doc` at `tree`, `selection`) kept for redo;
    // 0 when there is nothing to undo.
    RKUndoStep* undo(UXRscDoc* doc, i32 tree, i32 selection)
        {
        if (!self.canUndo())
            {
            return (RKUndoStep*)0;
            }
        RKUndoStep* s = (RKUndoStep* ?)undos.get(undos.count() - (u32)1);
        undos.removeAt(undos.count() - (u32)1);
        redos.add(RKUndoStep.make(doc, s.label, tree, selection));
        lastKey = (Object*)0;
        return s;
        }
    RKUndoStep* redo(UXRscDoc* doc, i32 tree, i32 selection)
        {
        if (!self.canRedo())
            {
            return (RKUndoStep*)0;
            }
        RKUndoStep* s = (RKUndoStep* ?)redos.get(redos.count() - (u32)1);
        redos.removeAt(redos.count() - (u32)1);
        undos.add(RKUndoStep.make(doc, s.label, tree, selection));
        lastKey = (Object*)0;
        return s;
        }
    }
