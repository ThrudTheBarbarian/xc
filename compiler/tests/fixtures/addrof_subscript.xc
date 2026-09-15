// addrof_subscript.xc — &arr[K] must yield an address, not the
// value at index K. Pre-fix the codegen folded `&arr[K]` to the
// element value when the array's initializer was visible at
// compile time, so e.g. `(u16)&dlist[0]` came back as the byte
// $70 from the initializer instead of the array's address. The
// Gfx8 setupNative DL-patching path hit this and the JVB target
// jumped to garbage.
//
// Three checks per array shape, with constant K = 0 and K = 1:
//   T1: &arr[0] == arr (decayed)
//   T2: &arr[1] - &arr[0] == elementSize
//   T3: &arr[1] == arr + elementSize
//
// Covers u8, u16, and u32 element widths so we catch any width-
// dependent regression in the offset-multiplication path.

#import "Stdio.xc"
#import "Assert.xc"

u8  dlist8[10]  = { $70, $71, $72, $73, $74, $75, $76, $77, $78, $79 };
u16 dlist16[10] = { $1000, $1001, $1002, $1003, $1004,
                    $1005, $1006, $1007, $1008, $1009 };
u32 dlist32[10] = { $20000000, $20000001, $20000002, $20000003,
                    $20000004, $20000005, $20000006, $20000007,
                    $20000008, $20000009 };

void main(void)
{
    Assert.reset();

    // u8 array — element size 1
    u16 base8 = (u16)dlist8;
    Assert.isEqual((u16)&dlist8[0], base8);
    Assert.isEqual((u16)&dlist8[1] - (u16)&dlist8[0], 1);
    Assert.isEqual((u16)&dlist8[1], base8 + 1);

    // u16 array — element size 2
    u16 base16 = (u16)dlist16;
    Assert.isEqual((u16)&dlist16[0], base16);
    Assert.isEqual((u16)&dlist16[1] - (u16)&dlist16[0], 2);
    Assert.isEqual((u16)&dlist16[1], base16 + 2);

    // u32 array — element size 4
    u16 base32 = (u16)dlist32;
    Assert.isEqual((u16)&dlist32[0], base32);
    Assert.isEqual((u16)&dlist32[1] - (u16)&dlist32[0], 4);
    Assert.isEqual((u16)&dlist32[1], base32 + 4);

    Stdio.printf("DONE 9\n");
    return;
}
