// collections.xc — UXBag, UXBinaryHeap and UXCache: the three collections that
// are not just "a list".
//
// All three are pure data structures: no driver, no window, no platform.
#import <Stdio.xc>
#import "UXBag.xc"
#import "UXBinaryHeap.xc"
#import "UXCache.xc"

class Token : Object
{
    u8* name;
    // A direct subclass of Object does not chain to super.init() — the object
    // is already initialised when this body runs.
    void init(void) { name = (u8*)"?"; }
    static Token* named(u8* n) { Token* t = new Token(); t.name = n; return t; }
}

void main(void) {
    // ---- UXBag: a set that counts -----------------------------------------
    Token* red   = Token.named((u8*)"red");
    Token* green = Token.named((u8*)"green");
    Token* blue  = Token.named((u8*)"blue");

    UXBag* bag = new UXBag();
    bag.add((Object*)red);
    bag.add((Object*)red);
    bag.add((Object*)green);
    bag.addTimes((Object*)blue, (i32)4);

    Stdio.printf("bag: unique=%d total=%d\n", bag.uniqueCount(), bag.totalCount());
    for (i32 i = (i32)0; i < bag.uniqueCount(); i = i + (i32)1) {
        Stdio.printf("  %s x%d\n",
                     ((Token* ?)bag.memberAt(i)).name, bag.countAt(i));
    }

    // remove() takes ONE occurrence off; the member survives until zero.
    bag.remove((Object*)red);
    Stdio.printf("after one remove: red=%d contains=%d\n",
                 bag.countFor((Object*)red), bag.contains((Object*)red) ? 1 : 0);
    bag.remove((Object*)red);
    Stdio.printf("after two:        red=%d contains=%d unique=%d\n",
                 bag.countFor((Object*)red), bag.contains((Object*)red) ? 1 : 0,
                 bag.uniqueCount());

    // removeAllOf() drops the member whatever its count.
    bag.removeAllOf((Object*)blue);
    Stdio.printf("after removeAllOf(blue): unique=%d total=%d\n",
                 bag.uniqueCount(), bag.totalCount());

    // Membership is by IDENTITY, so an equal-looking twin is a different member.
    Token* red2 = Token.named((u8*)"red");
    bag.add((Object*)red2);
    Stdio.printf("identity: red2 count=%d unique=%d\n",
                 bag.countFor((Object*)red2), bag.uniqueCount());

    // Removing something that is not there is a silent no-op, not a negative.
    bag.remove((Object*)red);
    Stdio.printf("remove absent: total=%d\n", bag.totalCount());

    // ---- UXBinaryHeap: a priority queue -----------------------------------
    UXBinaryHeap* q = new UXBinaryHeap();
    q.insert((Object*)Token.named((u8*)"repaint"), (i32)5);
    q.insert((Object*)Token.named((u8*)"quit"),    (i32)1);
    q.insert((Object*)Token.named((u8*)"save"),    (i32)3);
    q.insert((Object*)Token.named((u8*)"resize"),  (i32)2);

    Stdio.printf("heap count=%d minimum=%s\n",
                 q.count(), ((Token* ?)q.minimum()).name);
    Stdio.printf("drain:");
    while (!q.isEmpty()) {
        Stdio.printf(" %s", ((Token* ?)q.removeMinimum()).name);
    }
    Stdio.printf("\n");

    // Negate the key for a max-heap: the priority is just an integer you choose.
    UXBinaryHeap* top = new UXBinaryHeap();
    top.insert((Object*)Token.named((u8*)"score-10"), -(i32)10);
    top.insert((Object*)Token.named((u8*)"score-90"), -(i32)90);
    top.insert((Object*)Token.named((u8*)"score-50"), -(i32)50);
    Stdio.printf("max-heap first out: %s\n", ((Token* ?)top.minimum()).name);

    // An empty heap answers 0 rather than trapping.
    UXBinaryHeap* empty = new UXBinaryHeap();
    Stdio.printf("empty: isEmpty=%d minimum=%d\n",
                 empty.isEmpty() ? 1 : 0,
                 empty.minimum() == (Object*)0 ? 0 : 1);

    // ---- UXCache: bounded, least-recently-used ----------------------------
    UXCache* c = new UXCache();
    c.setCapacity((i32)3);
    c.set((u8*)"a", (Object*)Token.named((u8*)"A"));
    c.set((u8*)"b", (Object*)Token.named((u8*)"B"));
    c.set((u8*)"c", (Object*)Token.named((u8*)"C"));

    // Touching "a" makes it most-recent, so "b" becomes the oldest.
    c.get((u8*)"a");
    c.set((u8*)"d", (Object*)Token.named((u8*)"D"));     // over capacity: evict
    Stdio.printf("cache count=%d a=%d b=%d c=%d d=%d\n", c.count(),
                 c.contains((u8*)"a") ? 1 : 0, c.contains((u8*)"b") ? 1 : 0,
                 c.contains((u8*)"c") ? 1 : 0, c.contains((u8*)"d") ? 1 : 0);

    // contains() does NOT count as a use, so peeking cannot rescue an entry.
    c.contains((u8*)"c");
    c.set((u8*)"e", (Object*)Token.named((u8*)"E"));
    Stdio.printf("after peek+set: c=%d e=%d\n",
                 c.contains((u8*)"c") ? 1 : 0, c.contains((u8*)"e") ? 1 : 0);

    // A miss is 0, and setting an existing key updates in place rather than
    // adding a second entry.
    Stdio.printf("miss=%d\n", c.get((u8*)"gone") == (Object*)0 ? 0 : 1);
    i32 before = c.count();
    c.set((u8*)"e", (Object*)Token.named((u8*)"E2"));
    Stdio.printf("re-set same key: %d -> %d value=%s\n",
                 before, c.count(), ((Token* ?)c.get((u8*)"e")).name);

    // Shrinking the capacity evicts immediately.
    c.setCapacity((i32)1);
    Stdio.printf("after setCapacity(1): count=%d\n", c.count());
}
