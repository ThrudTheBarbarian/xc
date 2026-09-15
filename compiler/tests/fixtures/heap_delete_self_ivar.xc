// heap_delete_self_ivar.xc — releasing a `banked:T@` ivar of self from inside
// a method must load the ivar's pointer VALUE (via the self pointer) and free
// THAT block.
//
// The release used to be an explicit `delete child` under `-farc=off`. That
// flag is retired (bug 026) and manual lifetime management of a class instance
// is now rejected, so the ivar is cleared instead — which is the same operation
// through the path that ships: ARC drops the old value on the store.
//
// Detection is via a dealloc counter, NOT same-address reuse: Inner's
// dealloc bumps a global, and the test asserts it fired exactly once.
// (The older reuse check — "the freed slot is handed back to the next
// new" — only holds for the xt6502 custom first-fit allocator; the arm64
// host build frees through system malloc, which gives no reuse guarantee,
// so the delete fired correctly there but the reuse check spuriously
// failed. The counter is deterministic on both.)

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocs;

class Inner { u16 v; void dealloc(void) { deallocs = deallocs + $0A; } }
class Container {
    banked:Inner* child;
    void init(void)    { child = new Inner(); }
    void cleanup(void) { child = 0; }    // ARC releases the old value
}

void main(void)
{
    Assert.reset();
    deallocs = $D0;                          // distinctive base (208)

    banked:Container* c = new Container();
    Assert.isEqual(deallocs, $D0);           // T1 — nothing freed yet

    c.cleanup();                             // delete child → Inner.dealloc
    Assert.isEqual(deallocs, $DA);           // T2 — fired once ($D0 + $0A)

    Stdio.printf("deallocs=%u\n", deallocs);
    Assert.summary();
    return;
}
