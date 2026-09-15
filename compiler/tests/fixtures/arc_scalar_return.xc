// arc_scalar_return.xc — scalar return values survive ARC cleanup.
//
// Before this fix, a function returning a u8/u16/u32 scalar while
// holding strong class-pointer locals would have its A/X clobbered
// by the scope-exit cleanup's _obj_decref / _heap_free helpers. A
// u32 return would also lose its high bytes in _u32HiReg when a
// user-dealloc() executed arbitrary code through $B0..$BF.
//
// emitReturn now stashes the scalar on the hw stack before cleanup
// runs and restores it before the JMP to the function end label.
// Float/double/struct/class returns live in $B0..$B4 and remain
// untouched by the helpers, so they keep the original pass-through.
//
// Test surface:
//   T1  u8  return with strong local → preserved
//   T2  u16 return with strong local → preserved
//   T3  u32 return with strong local whose class has a user
//       dealloc → _u32HiReg survives the user-dealloc JSR
//   T4  All three helpers dealloc'd their tracker exactly once
//       (scope-exit cleanup ran — proving the stash was needed)

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        // Nontrivial dealloc body: reads/writes $B0..$BF via
        // Stdio.printf or arithmetic would also stress _u32HiReg
        // preservation. A single u16 add through $B0 suffices.
        deallocCount = deallocCount + 1;
    }
}

u8 returnU8(void)
{
    Tracker* a = new Tracker();
    a.tag = 5;
    return $C3;
}

u16 returnU16(void)
{
    Tracker* a = new Tracker();
    a.tag = 7;
    return $BEEF;
}

u32 returnU32(void)
{
    Tracker* a = new Tracker();
    a.tag = 9;
    return $12345678;
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    u8 v8 = returnU8();
    Assert.isEqual(v8, $C3);                        // T1

    u16 v16 = returnU16();
    Assert.isEqual(v16, $BEEF);                     // T2

    u32 v32 = returnU32();
    Assert.isEqual(v32, $12345678);                 // T3

    Assert.isEqual(deallocCount, 3);                // T4

    Assert.summary();
    return;
}
