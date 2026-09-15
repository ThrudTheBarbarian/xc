// raw_bank_ptr.xc — `bank(BANK_TYPE, idx)` builtin returning raw:u8@.
//xtc-na: wasm32 — `bank()` builds a raw 3-byte banked pointer, a 6502 banking concept with no wasm meaning
//
// The builtin produces a 3-byte (low addr, high addr, bank) pointer
// that addresses byte 0 of the requested window in the named bank.
// Reads and writes through it use the same _banked_load_byte /
// _banked_store_byte machinery as banked:T@ heap pointers, but the
// pointer is excluded from ARC entirely — these address foreign-bank
// data the user supplied (sound, graphics, screendumps), not heap
// blocks with a refcount header.
//
// xt has split banking: BANK_DATA = $6000 ($83-selected, 4 KB),
// BANK_CODE = $4000 ($82-selected, 8 KB). xe has a single 16 KB
// window at $4000 — only BANK_DATA is valid there; BANK_CODE / BANK_C
// raise sema errors.
//
// Test plan: write a sentinel byte through bank(BANK_DATA, n), then
// read it back through a fresh bank() call to the same (type, idx)
// and confirm round-trip. Indexed write+read covers the (self),Y
// path through the banked-load helpers.

#import "Stdio.xc"

void main(void)
{
    // T1: literal-idx round-trip through BANK_DATA bank 1.
    raw:u8* p1 = bank(BANK_DATA, 1);
    *p1 = $A5;
    raw:u8* q1 = bank(BANK_DATA, 1);
    if (*q1 == $A5) { Stdio.printf("T1 PASS\n"); }
    else            { Stdio.printf("T1 FAIL got=$%x\n", *q1); }

    // T2: indexed write+read through the same pointer. p1[5] writes
    // at offset 5 within bank 1's window; reading from a fresh bank()
    // pointer to the same bank confirms persistence.
    p1[5] = $42;
    raw:u8* q2 = bank(BANK_DATA, 1);
    if (q2[5] == $42) { Stdio.printf("T2 PASS\n"); }
    else              { Stdio.printf("T2 FAIL got=$%x\n", q2[5]); }

    // T3: different bank doesn't see bank 1's writes. Write a known
    // sentinel into bank 2 at offset 0 and read it; make sure bank 1's
    // offset 0 still reads $A5.
    raw:u8* p3 = bank(BANK_DATA, 2);
    *p3 = $5A;
    raw:u8* q3a = bank(BANK_DATA, 2);
    raw:u8* q3b = bank(BANK_DATA, 1);
    if (*q3a == $5A && *q3b == $A5) { Stdio.printf("T3 PASS\n"); }
    else                            { Stdio.printf("T3 FAIL a=$%x b=$%x\n", *q3a, *q3b); }

    // T4: runtime idx — bank() should accept a non-literal index.
    u8 which = 3;
    raw:u8* p4 = bank(BANK_DATA, which);
    *p4 = $77;
    raw:u8* q4 = bank(BANK_DATA, 3);
    if (*q4 == $77) { Stdio.printf("T4 PASS\n"); }
    else            { Stdio.printf("T4 FAIL got=$%x\n", *q4); }

    Stdio.printf("DONE 4\n");
}
