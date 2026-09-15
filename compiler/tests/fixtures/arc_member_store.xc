// arc_member_store.xc — validate ARC 2b member stores for strong
// class-pointer fields.
//
// Under -farc, `base.field = expr;` where the field is a strong
// class pointer should:
//   • release the old field value,
//   • retain the new if the RHS is a borrowed reference,
//   • skip the retain if the RHS is value-producing.
//
// Restrictions in this first cut: base is a heap-pointer identifier
// and the access is single-level. Nested chains, subscript bases,
// and stack-instance bases fall through to the pre-ARC emit path.
//
// new T() on a class with strong-pointer ivars now zero-fills the
// payload so the first member store's release-old step sees null
// (no-op) rather than garbage.
//
// Test surface:
//   T1-T2  base.field = new T() — new's +1 transfers to the field
//          slot; old field value was null (zero-init), no release.
//   T3-T4  base.field = identifier — borrow retained; old released.
//   T5-T6  base.field = null — old released, slot holds null.
//   T7     Releasing `base` at scope exit fires the class's user
//          dealloc() which can release its fields — the refcount
//          chain ripples down.

#import "Stdio.xc"
#import "Assert.xc"

class Inner
{
    u8 mark;
    void dealloc(void)
    {
        innerDeallocs = innerDeallocs + 1;
    }
}

class Container
{
    Inner* payload;
}

u16 innerDeallocs;

void firstStore(void)
{
    Container* c = new Container();    // payload zero-init to null
    c.payload = new Inner();           // store: old null, new +1 transfers
    c.payload.mark = 77;
    // Scope-exit: c releases → aggregate walker releases c.payload
    // (the Inner) → Inner dealloc fires.
}

void reassignWithNew(void)
{
    Container* c = new Container();
    c.payload = new Inner();           // Inner#1 into the field
    c.payload.mark = 1;
    c.payload = new Inner();           // replace: Inner#1 refcount 0 → dealloc
    c.payload.mark = 2;
    // Scope-exit: c releases → Inner#2 also released.
    // Total Inner deallocs for this function: 2.
}

void reassignWithIdentifier(Inner* i)
{
    Container* c = new Container();
    c.payload = new Inner();           // Inner#1 into the field
    c.payload.mark = 11;
    c.payload = i;                     // release Inner#1, retain i
                                       // (i's refcount bumped for field)
    c.payload.mark = 22;
    // Scope-exit: c releases → c.payload (= i) decref'd. `i` is a
    // strong param also scope-released; both drop i's refcount from 3
    // (caller's 1 + prologue 1 + field 1) back to 1 (caller's). No
    // extra inner dealloc beyond Inner#1's replacement.
}

void reassignWithNull(void)
{
    Container* c = new Container();
    c.payload = new Inner();           // Inner#1 into the field
    c.payload.mark = 99;
    c.payload = (Inner*)0;             // release Inner#1, store null
    // Scope-exit: c releases → c.payload null, no further release.
}

void main(void)
{
    Assert.reset();
    innerDeallocs = 0;

    // ── T1: first-store + scope-exit aggregate walker ──
    u16 before = innerDeallocs;
    firstStore();
    Assert.isEqual(innerDeallocs - before, 1);   // Inner released via walker

    // ── T2: reassign-with-new — Inner#1 freed mid-function, Inner#2 at exit ──
    before = innerDeallocs;
    reassignWithNew();
    Assert.isEqual(innerDeallocs - before, 2);

    // ── T3: reassign-with-identifier — Inner#1 freed; keeper stays alive ──
    Inner* keeper = new Inner();
    before = innerDeallocs;
    reassignWithIdentifier(keeper);
    Assert.isEqual(innerDeallocs - before, 1);   // only Inner#1 freed
    Assert.isEqual(keeper.mark, 22);             // keeper still live

    // ── T4: reassign-with-null — Inner#1 freed; slot null at exit ──
    before = innerDeallocs;
    reassignWithNull();
    Assert.isEqual(innerDeallocs - before, 1);

    Assert.summary();
    return;
}
