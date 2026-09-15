// UXStateMachine.xc — a finite state machine (for wizards, drawing-tool modes, interaction flows).
//
// States and named transitions (event -> next state).  fire(event) moves to the next state if the
// current state has a transition for that event, and reports whether it did.  A multi-step wizard
// (with Back/Next), a tool palette (select / draw / erase modes), or any "what happens when X in state
// Y" logic drops out of this — declared once, driven by events.  Pure logic, fully testable.
#import "Array.xc"

class UXTransition : Object
    {
    u8* fromState;
    u8* event;
    u8* toState;
    void init(void)
        {
        fromState = (u8*)"";
        event = (u8*)"";
        toState = (u8*)"";
        }
    }

    class UXStateMachine
    {
    Array<UXTransition>* transitions; // of UXTransition
    Array<UXTransition>* history;     // visited states (for a wizard's Back), most recent last
    u8* current;
    void init(void)
        {
        transitions = new Array();
        history = new Array();
        current = (u8*)"";
        }

    static bool streq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    void setInitial(u8* state)
        {
        current = state;
        history.removeAll();
        }
    u8* currentState(void)
        {
        return current;
        }
    bool isIn(u8* state)
        {
        return UXStateMachine.streq(current, state);
        }

    // Declare: in `fromState`, `event` leads to `toState`.
    void addTransition(u8* fromState, u8* event, u8* toState)
        {
        UXTransition* t = new UXTransition();
        t.fromState = fromState;
        t.event = event;
        t.toState = toState;
        transitions.add(t);
        }

    UXTransition* transitionFor(u8* event)
        {
        for (u16 i = (u16)0; i < transitions.count(); i = i + (u16)1)
            {
            UXTransition* t = (UXTransition* ?)transitions.get(i);
            if (UXStateMachine.streq(t.fromState, current) && UXStateMachine.streq(t.event, event))
                {
                return t;
                }
            }
        return (UXTransition*)0;
        }
    bool canFire(u8* event)
        {
        return self.transitionFor(event) != (UXTransition*)0;
        }

    // Attempt the transition; returns true if the machine moved.
    bool fire(u8* event)
        {
        UXTransition* t = self.transitionFor(event);
        if (t == (UXTransition*)0)
            {
            return false;
            }
        UXTransition* h = new UXTransition();
        h.toState = current;
        history.add(h); // remember where we were
        current = t.toState;
        return true;
        }
    // Go back to the previous state (wizard Back); false if there is no history.
    bool back(void)
        {
        if (history.count() == (u16)0)
            {
            return false;
            }
        UXTransition* h = (UXTransition* ?)history.get((u16)(history.count() - (u16)1));
        history.removeLast();
        current = h.toState;
        return true;
        }
    i32 depth(void)
        {
        return (i32)history.count();
        }
    }
