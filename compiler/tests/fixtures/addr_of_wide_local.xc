// addr_of_wide_local.xc — taking the address of a 64-bit (and float) local.
//
// Found by the differential fuzzer (tests/fuzz). On wasm32 a PINNED local (one
// whose address is taken) holds its frame ADDRESS rather than its value, but it
// was still DECLARED from the value's type — so `u64 v; u64@ p = &v;` declared
// an i64 local and then `local.set` an i32 address into it, and the engine
// refused the module outright ("local.set[0] expected type i64, found i32.add
// of type i32"). Invisible while every pinned local was 32 bits or narrower.
#import "Stdio.xc"

void bump(u64@ p) { @p = @p + (u64)7; }

void main(void)
{
    u64 w = (u64)11216243352465308576;
    u64@ pw = &w;
    @pw = @pw + (u64)1;
    Stdio.printf("w %lu:%lu\n", (u32)(w >> (u64)32), (u32)w);

    bump(&w);                             // through a call, so it cannot fold
    Stdio.printf("b %lu:%lu\n", (u32)(w >> (u64)32), (u32)w);

    i64 s = (i64)-5000000000;
    i64@ ps = &s;
    @ps = @ps - (i64)1;
    Stdio.printf("s %lu:%lu\n", (u32)((u64)s >> (u64)32), (u32)s);
    return;
}
