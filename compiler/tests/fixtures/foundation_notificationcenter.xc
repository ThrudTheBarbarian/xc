//xtc-na: xt6502 — NotificationCenter is not available on xt6502
// foundation_notificationcenter.xc — NotificationCenter: name and sender
// filters, userInfo, removal, observers that go away, and an observer added
// during delivery.
#import "Foundation.xc"
#import "NotificationCenter.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }

class Listener : Object
    {
    String* tag;
    i32 heard;
    NotificationCenter* centre;
    bool addAnother;
    Listener* kept;   // keeps the late observer alive: the centre does not

    void init(void)
        {
        heard = (i32)0;
        addAnother = false;
        }

    void onNote(Notification* n)
        {
        heard = heard + (i32)1;
        String* who = n.object == (Object*)0 ? S("-") : ((Listener*)n.object).tag;
        Number* v = n.userInfo == 0 ? (Number*)0 : (Number* ?)n.userInfo.get(S("v"));
        Stdio.printf("  %@ heard %@ from %@%s%@\n", tag, n.name, who, v == 0 ? "" : " v=", v == 0 ? S("") : v.description());
        if (addAnother)
            {
            addAnother = false;
            Listener* late = new Listener();
            late.tag = S("late");
            kept = late;
            centre.addObserver(late, &late.onNote, (String*)0, (Object*)0);
            Stdio.printf("  (added late)\n");
            }
        }
    }

i32 main(void)
    {
    NotificationCenter* c = new NotificationCenter();
    Listener* a = new Listener();
    a.tag = S("a");
    Listener* b = new Listener();
    b.tag = S("b");
    Listener* any = new Listener();
    any.tag = S("any");

    c.addObserver(a, &a.onNote, S("Saved"), (Object*)0);
    c.addObserver(b, &b.onNote, S("Saved"), a);
    c.addObserver(any, &any.onNote, (String*)0, (Object*)0);

    Stdio.printf("post Saved from b:\n");
    c.post(S("Saved"), b);
    Stdio.printf("post Saved from a, with userInfo:\n");
    Map* info = new Map();
    info.set(S("v"), Number.withI32((i32)7));
    c.post(S("Saved"), a, info);
    Stdio.printf("post Closed, no sender:\n");
    c.post(S("Closed"), (Object*)0);

    Stdio.printf("remove a for Saved; post Saved:\n");
    c.removeObserver(a, S("Saved"), (Object*)0);
    c.post(S("Saved"), a);

    Stdio.printf("observers: %u\n", c.observerCount());
    Stdio.printf("b goes away; post Saved from a:\n");
    b = (Listener*)0;
    c.post(S("Saved"), a);
    Stdio.printf("observers: %u\n", c.observerCount());

    Stdio.printf("any adds an observer while hearing; post Ping twice:\n");
    any.centre = c;
    any.addAnother = true;
    c.post(S("Ping"), (Object*)0);
    c.post(S("Ping"), (Object*)0);

    Stdio.printf("remove any and the late one; post Ping:\n");
    c.removeObserver(any.kept);
    c.removeObserver(any);
    c.post(S("Ping"), (Object*)0);
    Stdio.printf("observers: %u\n", c.observerCount());
    Stdio.printf("shared is shared: %d\n", (i32)(NotificationCenter.shared() == NotificationCenter.shared() ? 1 : 0));
    Stdio.printf("a heard %d, any heard %d\n", a.heard, any.heard);
    return (i32)0;
    }
