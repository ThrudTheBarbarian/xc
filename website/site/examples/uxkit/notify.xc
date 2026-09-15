// notify.xc — publish/subscribe: one poster, N observers that need not know it.
//
// The decoupled sibling of target/action. Runs headless.
#import <Stdio.xc>
#import "UXNotificationCenter.xc"

class Panel : Object {
    u8* name;
    i32 seen;
    void init(void) { name = (u8*)"?"; seen = 0; }
    static Panel* make(u8* n) { Panel* p = new Panel(); p.name = n; return p; }

    void onChanged(UXNotification* note) {
        seen = seen + 1;
        Stdio.printf("  %s heard '%s' (a=%d b=%d)\n", name, note.name, note.a, note.b);
    }
}

void main(void) {
    UXNotificationCenter* nc = UXNotificationCenter.shared();

    Panel* left  = Panel.make((u8*)"left ");
    Panel* right = Panel.make((u8*)"right");

    // Two observers of the same name, neither knowing about the other or the poster.
    nc.addObserver((Object*)left,  &left.onChanged,  (u8*)"doc.changed", (Object*)0);
    nc.addObserver((Object*)right, &right.onChanged, (u8*)"doc.changed", (Object*)0);

    Stdio.printf("post 'doc.changed':\n");
    nc.postWith((u8*)"doc.changed", (Object*)0, 42, 7);

    // A name nobody observes is simply not delivered — not an error.
    Stdio.printf("post 'doc.saved' (no observers):\n");
    nc.post((u8*)"doc.saved", (Object*)0);

    // Filtering by SENDER: observe one object's notifications only.
    Panel* a = Panel.make((u8*)"docA ");
    Panel* watcher = Panel.make((u8*)"watch");
    nc.addObserver((Object*)watcher, &watcher.onChanged, (u8*)"doc.changed", (Object*)a);
    Stdio.printf("post from a DIFFERENT sender:\n");
    nc.postWith((u8*)"doc.changed", (Object*)left, 1, 1);     // watcher must NOT hear this
    Stdio.printf("post from the watched sender:\n");
    nc.postWith((u8*)"doc.changed", (Object*)a, 2, 2);        // watcher hears it

    Stdio.printf("left=%d right=%d watcher=%d\n", left.seen, right.seen, watcher.seen);

    // Unsubscribing.
    nc.removeObserver((Object*)right);
    Stdio.printf("after removeObserver(right):\n");
    nc.postWith((u8*)"doc.changed", (Object*)0, 9, 9);
    Stdio.printf("left=%d right=%d\n", left.seen, right.seen);
}
