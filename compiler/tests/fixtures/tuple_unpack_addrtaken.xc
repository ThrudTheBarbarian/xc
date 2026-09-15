// tuple_unpack_addrtaken.xc — a tuple-unpacking target that is ALSO address-taken.
//
// `(a, b) = f(...)` assigns the multi-return values to a and b. When a target
// (b) has had its address taken (`&b`), it lives in a frame slot, not the SSA
// `locals` map — and the tuple-unpack lowering only looked in `locals`, so it
// soft-failed "tuple target 'b' not found" on EVERY backend (shared lowering).
// Found by the differential fuzzer (seed 5086). The fix stores the extracted
// field to the pinned local's slot, like a plain assignment.
#import <Stdio.xc>

i32, i32 mr(i32 x) { return (x + 1), (x + 100); }

void main(void) {
    i32 a = 5;
    i32 b = 10;
    i32* p = &b;          // b is address-taken → lives in a frame slot
    *p = 20;              // b = 20 through the pointer
    (a, b) = mr((i32)b);  // b is a tuple target AND was address-taken
    Stdio.printf("a=%d b=%d\n", a, b);   // a=21 b=120
    return;
}
