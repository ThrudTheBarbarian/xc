// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// UndoManager.xc — undo and redo (NSUndoManager in shape).
// ===========================================================================
//
// Undo rests on one idea: an undoable change registers, as it happens, the
// call that would put things back. Undoing makes that call, and because
// putting things back is itself a change, that call registers its own inverse,
// which becomes the redo. Undo and redo are one machine run in opposite
// directions.
//
//     // In the model, whenever x changes:
//     void setX(Number* v)
//         {
//         undo.registerUndo(&self.setX, x);   // "to undo, set x back to the old x"
//         x = v;
//         }
//     …
//     model.setX(Number.withI32((i32)5));
//     undo.setActionName(String.withCString("Change X"));
//     undo.undo();    // calls setX(old); setX registers setX(5) as the redo
//     undo.redo();    // calls setX(5); setX registers setX(old) as the undo again
//
// ── Groups ──────────────────────────────────────────────────────────────────
//
// Registrations are collected into groups, so several model changes undo as
// one user action. A registration outside any group is a group of its own;
// beginUndoGrouping / endUndoGrouping (which nest) make larger ones. A group's
// calls are undone newest first. While a group is undone, everything it
// registers lands in one new group on the redo stack, so a whole action redoes
// in one step.
//
// A new change made outside undo and redo clears the redo stack.
//
// ── Lifetime ────────────────────────────────────────────────────────────────
//
// A registered call does not keep its target alive (a model that owns its
// undo manager would otherwise be a cycle); a call whose target has gone is
// skipped. The argument is kept: it is the data to restore.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "UndoManager: not available on xt6502"
#endif

#import "Foundation.xc"

class _UndoCall
    {
    callback block void(Object* arg);
    Object* arg;
    }

class _UndoGroup
    {
    Array* calls;    // _UndoCall, oldest first
    String* name;    // the action name, or null

    void init(void)
        {
        calls = new Array();
        name = (String*)0;
        }
    }

enum _UndoMode = {UM_NORMAL, UM_UNDOING, UM_REDOING};

class UndoManager
    {
    Array* _undo;          // _UndoGroup, newest last
    Array* _redo;
    _UndoGroup* _open;     // the group collecting registrations, or null
    u32 _depth;            // begin/end nesting
    u8 _mode;
    String* _pendingName;  // setActionName inside an open group
    u32 _disabled;         // disable/enable nesting
    u32 levelsOfUndo;      // the most groups kept on each stack; 0 = no limit

    void init(void)
        {
        _undo = new Array();
        _redo = new Array();
        _open = (_UndoGroup*)0;
        _depth = (u32)0;
        _mode = (u8)UM_NORMAL;
        _pendingName = (String*)0;
        _disabled = (u32)0;
        levelsOfUndo = (u32)0;
        }

    // ── Registering ──────────────────────────────────────────────────────

    // Records "to undo, call block(arg)", where block is a method bound to
    // the object to change (&model.setX). Outside an open group it is a group
    // of its own. Nothing is recorded while registration is disabled.
    void registerUndo(callback block void(Object* arg), Object* arg)
        {
        if (_disabled > (u32)0)
            return;
        bool alone = _depth == (u32)0;
        if (alone)
            beginUndoGrouping();
        _UndoCall* c = new _UndoCall();
        c.block = block;
        c.arg = arg;
        _open.calls.add(c);
        if (alone)
            endUndoGrouping();
        }

    // Names the action, for "Undo <name>". Inside an open group it names that
    // group; otherwise it names the group just recorded, so the usual
    // `model.setX(v); undo.setActionName(…)` names the change it follows.
    void setActionName(String* name)
        {
        if (_depth > (u32)0)
            {
            _pendingName = name;
            return;
            }
        Array* s = _mode == (u8)UM_UNDOING ? _redo : _undo;
        if (s.count() > (u32)0)
            ((_UndoGroup*)s.get(s.count() - (u32)1)).name = name;
        }

    // ── Grouping ─────────────────────────────────────────────────────────

    void beginUndoGrouping(void)
        {
        if (_depth == (u32)0)
            _open = new _UndoGroup();
        _depth = _depth + (u32)1;
        }

    // Closes the innermost group; the outermost one goes on its stack if it
    // recorded anything.
    void endUndoGrouping(void)
        {
        if (_depth == (u32)0)
            return;
        _depth = _depth - (u32)1;
        if (_depth > (u32)0 || _open == 0)
            return;
        _UndoGroup* g = _open;
        _open = (_UndoGroup*)0;
        if (_pendingName != 0)
            g.name = _pendingName;
        _pendingName = (String*)0;
        if (g.calls.count() == (u32)0)
            return;
        Array* dest = _mode == (u8)UM_UNDOING ? _redo : _undo;
        dest.add(g);
        if (levelsOfUndo > (u32)0)
            {
            while (dest.count() > levelsOfUndo)
                dest.removeAt((u32)0);
            }
        if (_mode == (u8)UM_NORMAL)
            _redo.removeAll();
        }

    // How deep the open groups are nested; 0 when none is open.
    u32 groupingLevel(void)
        {
        return _depth;
        }

    // ── Undoing and redoing ──────────────────────────────────────────────

    // Undoes the newest group, if there is one. A group still open is closed
    // first.
    void undo(void)
        {
        _run(_undo, (u8)UM_UNDOING);
        }

    void redo(void)
        {
        _run(_redo, (u8)UM_REDOING);
        }

    void _run(Array* stack, u8 mode)
        {
        while (_depth > (u32)0)
            endUndoGrouping();
        if (stack.count() == (u32)0)
            return;
        _UndoGroup* g = (_UndoGroup*)stack.get(stack.count() - (u32)1);
        stack.removeAt(stack.count() - (u32)1);
        _mode = mode;
        beginUndoGrouping();
        _pendingName = g.name;
        for (u32 i = g.calls.count(); i > (u32)0; i = i - (u32)1)
            {
            _UndoCall* c = (_UndoCall*)g.calls.get(i - (u32)1);
            // A local, so the call is not read as a method of `c`; zero if the
            // target has gone.
            callback b void(Object* arg) = c.block;
            if (b)
                b(c.arg);
            }
        endUndoGrouping();
        _mode = (u8)UM_NORMAL;
        }

    bool canUndo(void)
        {
        return _undo.count() > (u32)0;
        }

    bool canRedo(void)
        {
        return _redo.count() > (u32)0;
        }

    // The newest group's name, or null.
    String* undoActionName(void)
        {
        return _undo.count() == (u32)0 ? (String*)0 : ((_UndoGroup*)_undo.get(_undo.count() - (u32)1)).name;
        }

    String* redoActionName(void)
        {
        return _redo.count() == (u32)0 ? (String*)0 : ((_UndoGroup*)_redo.get(_redo.count() - (u32)1)).name;
        }

    bool isUndoing(void)
        {
        return _mode == (u8)UM_UNDOING;
        }

    bool isRedoing(void)
        {
        return _mode == (u8)UM_REDOING;
        }

    // ── Housekeeping ─────────────────────────────────────────────────────

    // Forgets every undo and redo, and any open group.
    void removeAllActions(void)
        {
        _undo.removeAll();
        _redo.removeAll();
        _open = (_UndoGroup*)0;
        _depth = (u32)0;
        _pendingName = (String*)0;
        }

    // Stops recording, as while a document loads. Calls nest: registration
    // resumes after as many enables as disables.
    void disableUndoRegistration(void)
        {
        _disabled = _disabled + (u32)1;
        }

    void enableUndoRegistration(void)
        {
        if (_disabled > (u32)0)
            _disabled = _disabled - (u32)1;
        }

    bool isUndoRegistrationEnabled(void)
        {
        return _disabled == (u32)0;
        }
    }
