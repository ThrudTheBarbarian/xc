// statemachine.xc — a wizard as a declared state machine.
//
// States and named transitions, declared once and driven by events. Pure logic:
// no window, no driver, fully testable.
#import <Stdio.xc>
#import "UXStateMachine.xc"

void show(u8* what, UXStateMachine* m) {
    Stdio.printf("%s state=%s depth=%d\n", what, m.current, m.depth());
}

void main(void) {
    UXStateMachine* m = new UXStateMachine();
    m.setInitial((u8*)"welcome");

    // A three-page wizard. Declared once; the UI just fires events.
    m.addTransition((u8*)"welcome", (u8*)"next", (u8*)"details");
    m.addTransition((u8*)"details", (u8*)"next", (u8*)"confirm");
    m.addTransition((u8*)"confirm", (u8*)"finish", (u8*)"done");
    // Cancel is reachable from anywhere EXCEPT done — declared per state, so the
    // machine itself enforces it and no screen needs an if.
    m.addTransition((u8*)"welcome", (u8*)"cancel", (u8*)"cancelled");
    m.addTransition((u8*)"details", (u8*)"cancel", (u8*)"cancelled");
    m.addTransition((u8*)"confirm", (u8*)"cancel", (u8*)"cancelled");

    show((u8*)"start:        ", m);

    // canFire is what a Next button reads for its enabled state.
    Stdio.printf("canFire next=%d finish=%d\n",
                 m.canFire((u8*)"next") ? 1 : 0, m.canFire((u8*)"finish") ? 1 : 0);

    m.fire((u8*)"next");  show((u8*)"after next:   ", m);
    m.fire((u8*)"next");  show((u8*)"after next:   ", m);

    // An event the current state has no transition for is REFUSED, not an error.
    bool ok = m.fire((u8*)"next");
    Stdio.printf("fire next from confirm: %s (no such transition)\n", ok ? (u8*)"moved" : (u8*)"refused");

    // Back walks the history the fires built.
    m.back();             show((u8*)"after back:   ", m);
    m.back();             show((u8*)"after back:   ", m);
    Stdio.printf("back at the start: %s\n", m.back() ? (u8*)"moved" : (u8*)"refused");

    // Drive it to the end.
    m.fire((u8*)"next"); m.fire((u8*)"next"); m.fire((u8*)"finish");
    show((u8*)"finished:     ", m);
    Stdio.printf("isIn done: %s   cancel still possible: %s\n",
                 m.isIn((u8*)"done") ? (u8*)"yes" : (u8*)"no",
                 m.canFire((u8*)"cancel") ? (u8*)"yes" : (u8*)"no");
}
