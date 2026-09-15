// arc_weak_field_store_leak.xc — bug 170. Storing a +1 value into a weak SLOT
// that is a FIELD, a GLOBAL, or an ARRAY ELEMENT must release the +1 the store
// adopted, exactly as the weak LOCAL does (bug 153). A weak slot does not own
// its referent, so the +1 has nothing to balance it and leaks.
//
// The store shapes, each of which used to leak:
//   T1  bare-identifier ivar store inside a method  (`wf = new Item()`)
//   T2  member-access ivar store                    (`h.wf = new Item()`)
//   T3  weak global store                           (`gWeak = new Item()`)
//   T4  weak array element store                    (`warr[i] = new Item()`)
//
// A dealloc counter observes the balance: when the store's +1 is the sole
// strong reference, the object must dealloc immediately (weak owns nothing) and
// the slot auto-zero. A borrowed RHS (T5) must NOT be released.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

u16 gLive = (u16)0;

class Item
{
    u16 v;
    void init(void) { v = (u16)0; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
}

class Holder
{
    weak:Item@ wf;
    void bindBare(void)      { wf = new Item(); }   // T1: bare-ident ivar store
    Item* readField(void)    { return wf; }
}

weak:Item@ gWeak;

void main(void)
{
    // T1 — bare-identifier weak ivar store. The +1 has no other owner, so it
    // frees at once and the field auto-zeroes.
    Holder* h = new Holder();
    h.bindBare();
    Assert.isEqual(gLive, (u16)0);          // T1a: freed (was 1 — leaked)
    Assert.isTrue(h.readField() == 0);      // T1b: field auto-zeroed

    // T2 — member-access weak ivar store.
    h.wf = new Item();
    Assert.isEqual(gLive, (u16)0);          // T2: freed
    Assert.isTrue(h.readField() == 0);

    // T3 — weak global store.
    gWeak = new Item();
    Assert.isEqual(gLive, (u16)0);          // T3: freed
    Assert.isTrue(gWeak == 0);

    // T4 — weak array element store.
    {
        weak:Item@ warr[3];
        warr[0] = new Item();
        warr[1] = new Item();
        Assert.isEqual(gLive, (u16)0);      // T4a: both freed
        Assert.isTrue(warr[0] == 0);        // T4b: elements auto-zeroed
        Assert.isTrue(warr[1] == 0);
    }

    // T5 — a BORROWED RHS must not be released. A strong local owns the Item;
    // the weak field points at it and reads it; it dies exactly once at scope
    // exit (no double-free).
    {
        Item* owner = new Item(); owner.v = (u16)42;
        Assert.isEqual(gLive, (u16)1);      // owner alive
        h.wf = owner;                       // borrowed store
        Item* got = h.readField();
        Assert.isTrue(got != 0);
        Assert.isEqual(got.v, (u16)42);     // T5: still alive, not over-released
    }
    Assert.isEqual(gLive, (u16)0);          // T5b: owner freed once at scope exit

    Assert.summary();
    return;
}
