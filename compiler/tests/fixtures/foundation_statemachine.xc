// foundation_statemachine.xc — StateMachine: transitions by event, refused
// events, the events a state allows, back, reset, and the change callback.
#import "Foundation.xc"
#import "StateMachine.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }

class Watcher : Object
    {
    void moved(String* from, String* event, String* to)
        {
        Stdio.printf("  moved %s --%s--> %s\n", from.cString(), event.cString(), to.cString());
        }
    }

void tryFire(StateMachine* m, u8* event)
    {
    bool ok = m.fire(S(event));
    Stdio.printf("fire %s %s, now %s\n", event, ok ? "moved" : "refused", m.state().cString());
    }

i32 main(void)
    {
    StateMachine* m = StateMachine.withInitial(S("idle"));
    m.addTransition(S("idle"), S("start"), S("running"));
    m.addTransition(S("running"), S("pause"), S("paused"));
    m.addTransition(S("running"), S("stop"), S("idle"));
    m.addTransition(S("paused"), S("resume"), S("running"));
    m.addTransition(S("paused"), S("stop"), S("idle"));
    Watcher* w = new Watcher();
    m.setDidChange(&w.moved);

    tryFire(m, "start");
    tryFire(m, "start");
    Array* ev = m.events();
    Stdio.printf("events in running:");
    for (u32 i = (u32)0; i < ev.count(); i++)
        Stdio.printf(" %s", ((String*)ev.get(i)).cString());
    Stdio.printf("\n");
    tryFire(m, "pause");
    Stdio.printf("can resume: %d, can pause: %d\n", (i32)(m.canFire(S("resume")) ? 1 : 0), (i32)(m.canFire(S("pause")) ? 1 : 0));
    tryFire(m, "resume");
    Stdio.printf("depth %d\n", (i32)m.depth());
    m.back();
    Stdio.printf("back: now %s, in paused %d\n", m.state().cString(), (i32)(m.isIn(S("paused")) ? 1 : 0));
    m.back();
    m.back();
    Stdio.printf("back twice: now %s, back again %d\n", m.state().cString(), (i32)(m.back() ? 1 : 0));

    m.addTransition(S("idle"), S("start"), S("warming"));
    tryFire(m, "start");
    m.setState(S("idle"));
    Stdio.printf("reset: now %s, depth %d\n", m.state().cString(), (i32)m.depth());
    tryFire(m, "unknown");
    return (i32)0;
    }
