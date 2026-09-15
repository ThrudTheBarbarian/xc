// incdec_pinned.xc — regression: ++/-- on a pinned local must write the
// new value back to its frame slot. Taking a local's address pins it (its
// value lives in the slot, not an SSA register); before the fix the
// increment was computed but never stored, so a read through the pointer
// (or inline asm naming it) saw the stale value. Both backends.
#import "Stdio.xc"

void main(void)
{
    u8 q = 90;
    u8* p = &q;        // address-taken → q is pinned to a frame slot
    ++q;               // must store 91 back to the slot
    Stdio.printf("q1=%d\n", (u16)*p);
    q--;               // and back to 90
    Stdio.printf("q2=%d\n", (u16)*p);

    u16 w = $00FF;
    u16* pw = &w;
    w++;               // wide pinned inc → $0100 (256)
    Stdio.printf("w=%d\n", *pw);
    return;
}
