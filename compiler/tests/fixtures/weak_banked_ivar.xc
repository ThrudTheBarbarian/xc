// weak_banked_ivar.xc — 3-byte banked weak ivar auto-zeroes on
// single-bank banked-heap.
//
// Validates Phase 3 PR 9: `class X { weak:banked:Y@ f; }` on
// xt-heap / xe-heap. The weak ivar slot is 3 bytes (lo/hi/per-
// instance-bank) sitting inside a bank-window class payload, and
// the side-table key is the 3-byte banked pointee key. When the
// pointee's refcount hits zero the slot-zero walk zeroes all
// three bytes. On single-bank banked-heap the dying object and
// the host class live in the same heap bank, so the zero-walk's
// (zpTmp),Y write lands in the correct bank without new runtime
// bank-switching (multi-bank is the rambo* bring-up item in
// doc/Issues).
//
// Test surface:
//   T1  Parent.back tracks Child while both alive
//   T2  Freeing Child zeroes Parent.back's 3-byte slot
//   T3  Freeing Parent afterwards runs cleanly (aggregate walker
//       unregisters the already-empty ivar)

#import "Stdio.xc"
#import "Assert.xc"

class Leaf { u8 tag; }

class Holder
{
    weak:banked:Leaf* back;
}

// Module-scope holders so explicit release drives the test points.
// Holder + Leaf both use explicit banked: placement so assignments
// into the 3-byte weak ivar receive 3-byte banked pointers (the
// default Heap placement produces 2-byte pointers without a bank
// byte, which can't populate slot+2).
banked:Holder* gH;
banked:Leaf*   gL;

void setupAndDropLeaf(void)
{
    gH = new Holder();
    gL = new Leaf();          gL.tag = (u8)42;
    gH.back = gL;              // weak:banked:Leaf@ ivar store, 3-byte
    Assert.isNotNull((pointer)gH.back);   // T1

    gL = (banked:Leaf*)0;      // dealloc Leaf → _weak_zero_all_for
    Assert.isNull((pointer)gH.back);      // T2: 3-byte slot zeroed
}

void main(void)
{
    Assert.reset();
    setupAndDropLeaf();
    gH = (banked:Holder*)0;   // dealloc Holder → aggregate walker
    Assert.isNull((pointer)gH);           // T3: sanity
    Assert.summary();
    return;
}
