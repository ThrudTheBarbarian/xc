// weak_multibank_ivar.xc — weak ivar where the host class and the
// pointee live in different heap banks.
//
// Validates PR 12's _weak_slot_bank_table: when the pointee dies
// _obj_decref maps the pointee's bank into the $4000-$7FFF window,
// but the slot inside the host class's payload is in the host's
// bank. Without slot-bank tracking _weak_zero_all_for's (zpTmp),Y
// write would land in the pointee's bank at the slot address and
// corrupt unrelated memory, leaving the slot itself non-null.
//
// Forcing cross-bank on rambo192 (heap banks 1-2, 16 KB each):
// each heap bank holds a few kilobytes of structured data. A
// module-scope u8 array of ~14 KB sitting as a class ivar is
// enough to push past the single-bank boundary. We allocate the
// host (Holder) first, then a Bulky that nearly fills bank 1,
// then a Leaf — the Leaf should spill into bank 2 while Holder's
// payload stays in bank 1. The weak ivar assignment now crosses
// banks.
//
// Test surface:
//   T1  weak ivar tracks the Leaf while both live
//   T2  cross-bank release zeroes the slot via the slot-bank
//       switch in _weak_zero_all_for

#import "Stdio.xc"
#import "Assert.xc"

class Leaf { u8 tag; }
class Holder { weak:banked:Leaf* back; u8 pad; }
// ~14 KB consumer — a single class instance that chews through
// most of a heap bank, forcing the next allocation to spill.
// Each heap bank is 16 KB so this leaves ~2 KB for Holder's
// 5-byte payload + allocator headers.
class Bulky { u8 data[14000]; }

banked:Holder* gH;
banked:Bulky*  gB;
banked:Leaf*   gL;

void fill(void)
{
    gH = new Holder();
    gB = new Bulky();         // fills most of heap bank 1
    gL = new Leaf();          // should spill to bank 2
    gL.tag = (u8)7;
    gH.back = gL;             // cross-bank weak ivar store
}

void main(void)
{
    Assert.reset();
    fill();
    Assert.isNotNull((pointer)gH.back);   // T1

    gL = (banked:Leaf*)0;                 // release Leaf in bank 2
    Assert.isNull((pointer)gH.back);      // T2: slot in bank 1 zeroed

    Assert.summary();
    return;
}
