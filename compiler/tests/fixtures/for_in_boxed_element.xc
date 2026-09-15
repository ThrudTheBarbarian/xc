// for_in_boxed_element.xc — `for ... in` over a collection of PRIMITIVES.
//
// A typed collection with a primitive element type stores boxed `Number`s —
// the element type is a static check, not a change of representation. Reading
// one back through `get()` unboxes, because that is an assignment context.
// Reading one back through `for ... in` did NOT: the loop variable received
// the Number POINTER reinterpreted as an integer, which on a 32-bit target is
// a large and entirely plausible wrong number (bug 039).
//
// The fix binds the element under a hidden `Number*` and gives the body a
// declaration of the name that was written, so the ONE existing unboxing rule
// fires on it — rather than teaching for-in a second copy of that rule, which
// is how the two paths diverged in the first place.
//
// Class elements are the control: there the element really is a pointer, so
// nothing is unboxed and nothing changed.
// The 64-bit element groups need Number's wide storage. On xt6502 that is
// OFF by default — it costs ~4.5 KB in any program that touches Number, and
// almost no 6502 program wants a 64-bit collection element — so this fixture
// opts in exactly as a user would, BEFORE the import that pulls Number in.
// Harmless on every other target, where the wide storage is unconditional.
#define ENABLE_64BIT 1

#import "Stdio.xc"
#import "Foundation.xc"

// Each group is its own function. Together in one `main` the locals came to a
// 124-byte SP frame, past xt6502's 119-byte budget — the backend says so
// clearly ("automatic frame splitting is a future task"), and splitting is the
// documented answer. Nothing about the test changes.

// The two read paths must agree, and both must unbox.
void agreement(void)
{
    Array<i32>* nums = new Array();
    nums.add((i32)70);
    nums.add((i32)95);

    // Note the two-STEP read: unboxing fires in ASSIGNMENT context, so
    // `i32 e = nums.get(i)` unboxes and `total + nums.get(i)` does not — the
    // latter is an addition whose right operand is still an Object*. That is
    // the existing rule, not something this fixture changes; it is spelled out
    // because getting it wrong yields a pointer-shaped number, not an error.
    i32 viaGet = (i32)0;
    for (u32 i = (u32)0; i < nums.count(); i = i + (u32)1) {
        i32 e = nums.get(i);
        viaGet = viaGet + e;
    }

    i32 viaForIn = (i32)0;
    for (i32 v in nums) { viaForIn = viaForIn + v; }

    Stdio.printf("get %ld forin %ld agree %d\n",
                 viaGet, viaForIn, (i16)(viaGet == viaForIn ? 1 : 0));
}

// A narrower primitive element, to exercise a different accessor.
void narrow(void)
{
    Array<u16>* small = new Array();
    small.add((u16)7);
    small.add((u16)9);
    u16 sum = (u16)0;
    for (u16 v in small) { sum = sum + v; }
    Stdio.printf("u16 sum %d\n", sum);
}

// The 64-bit widths and double. These could not unbox through EITHER path
// until Number's canonical slots were widened to i64/double and the boxing
// table learned them — a box that cannot hold the value is not a box, and
// supporting a type in a collection is part of supporting the type. Sentinels
// chosen so a narrower slot would show: 2^40 does not fit 32 bits, and 3.1 has
// no exact float representation.
void wide(void)
{
    Array<i64>* big = new Array();
    big.add((i64)1099511627776);
    big.add((i64)-5);
    i64 bt = (i64)0;
    for (i64 v in big) { bt = bt + v; }
    Stdio.printf("i64 %s\n", String.withI64(bt).cString());
}

void wideFloat(void)
{
    Array<double>* ds = new Array();
    ds.add(3.1d);
    ds.add(0.25d);
    double dt = 0.0d;
    for (double v in ds) { dt = dt + v; }
    // Compared against the literal rather than printed: a formatter is not
    // what is under test here.
    //
    // `first` is BOUND before the comparison, and has to be. `ds.get(0) ==
    // 3.1d` is a comparison, not an assignment, so it does not unbox — it
    // compares the box POINTER against a double and quietly answers false.
    // Same rule as `total + nums.get(i)` above; it caught this fixture twice
    // while it was being written.
    double first = ds.get((u32)0);
    Stdio.printf("f64 sum-exact %d, first-exact %d\n",
                 (i16)(dt == 3.35d ? 1 : 0),
                 (i16)(first == 3.1d ? 1 : 0));
}

// Control: class elements are pointers, so nothing is unboxed and for-in over
// them was correct all along.
void classElements(void)
{
    Array<String>* names = new Array();
    names.add(String.withCString("ada"));
    names.add(String.withCString("grace"));
    Stdio.print("names:");
    for (String* n in names) { Stdio.printf(" %s", n.cString()); }
    Stdio.print("\n");
}

i32 main(void)
{
    agreement();
    narrow();
    wide();
    wideFloat();
    classElements();
    return 0;
}
