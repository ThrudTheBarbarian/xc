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
// StateMachine.xc — a finite state machine of named states and events.
// ===========================================================================
//
//     StateMachine* m = StateMachine.withInitial(String.withCString("idle"));
//     m.addTransition(String.withCString("idle"), String.withCString("start"), String.withCString("running"));
//     m.addTransition(String.withCString("running"), String.withCString("stop"), String.withCString("idle"));
//     m.fire(String.withCString("start"));   // true: now "running"
//     m.fire(String.withCString("start"));   // false: "running" has no "start"
//
// Transitions are declared once (in this state, this event leads to that
// state) and the machine is driven by events: a wizard's steps, a drawing
// tool's modes, a connection's life. fire moves when the current state has a
// transition for the event and reports whether it did; back returns to the
// state before the last move, for a wizard's Back button.
//
// States and events are Strings compared by value. Declaring the same state
// and event again replaces the target. An optional callback hears each move.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target, the 6502 included.

#import "Foundation.xc"

#if ARCH_6502
#define _SM_N u16
#else
#define _SM_N u32
#endif

class StateMachine
    {
    Map* _table;     // state -> Map(event -> state)
    String* _state;
    Array* _history; // the states left, oldest first
    callback _didChange void(String* from, String* event, String* to);

    void init(void)
        {
        _table = new Map();
        _state = String.withCString("");
        _history = new Array();
        }

    static StateMachine* withInitial(String* state)
        {
        StateMachine* m = new StateMachine();
        m.setState(state);
        return m;
        }

    // ── Declaring ────────────────────────────────────────────────────────

    // In `from`, `event` leads to `to`.
    void addTransition(String* from, String* event, String* to)
        {
        Map* events = (Map* ?)_table.get(from);
        if (events == 0)
            {
            events = new Map();
            _table.set(from, events);
            }
        events.set(event, to);
        }

    // Calls `method` (a bound method) after each move, with the state left,
    // the event and the state entered. Null stops the calls.
    void setDidChange(callback method void(String* from, String* event, String* to))
        {
        _didChange = method;
        }

    // ── The state ────────────────────────────────────────────────────────

    String* state(void)
        {
        return _state;
        }

    bool isIn(String* state)
        {
        return _state.equals(state);
        }

    // Puts the machine in `state` without a transition and forgets the
    // history: a start or a reset.
    void setState(String* state)
        {
        _state = state == 0 ? String.withCString("") : state;
        _history.removeAll();
        }

    // ── Driving ──────────────────────────────────────────────────────────

    // Where `event` leads from the current state, or null.
    String* targetOf(String* event)
        {
        Map* events = (Map* ?)_table.get(_state);
        if (events == 0)
            return (String*)0;
        return (String* ?)events.get(event);
        }

    bool canFire(String* event)
        {
        return targetOf(event) != 0;
        }

    // The events the current state has transitions for, in the order they
    // were declared.
    Array* events(void)
        {
        Array* out = new Array();
        Map* events = (Map* ?)_table.get(_state);
        if (events == 0)
            return out;
        for (_SM_N i = (_SM_N)0; i < events.count(); i++)
            out.add(events.enumAt(i));
        return out;
        }

    // Moves if the current state has a transition for `event`; whether it
    // did.
    bool fire(String* event)
        {
        String* to = targetOf(event);
        if (to == 0)
            return false;
        String* from = _state;
        _history.add(from);
        _state = to;
        callback m void(String* from, String* event, String* to) = _didChange;
        if (m)
            m(from, event, to);
        return true;
        }

    // Returns to the state before the last move; false when there is none.
    // The change callback is not called.
    bool back(void)
        {
        _SM_N n = _history.count();
        if (n == (_SM_N)0)
            return false;
        _state = (String*)_history.get(n - (_SM_N)1);
        _history.removeAt(n - (_SM_N)1);
        return true;
        }

    // How many moves back can undo.
    _SM_N depth(void)
        {
        return _history.count();
        }
    }
