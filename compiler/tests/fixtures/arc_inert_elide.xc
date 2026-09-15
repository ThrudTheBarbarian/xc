#import "Stdio.xc"
#import "Assert.xc"

// arc-self-retain inter-procedural elision: an ARC-inert method's self-retain
// bracket is dropped (leaf getter, and a delegating getter that only calls
// inert methods), while a method that can transitively release self keeps it.
// All three must stay correct (a mis-elision = wrong refcount / use-after-free).

u16 sink;                       // global, written by a "releasing" path

class Cell
{
    i32 v;
    void init(void) { v = 0; }
    static Cell* make(i32 x) { Cell* c = new Cell(); c.v = x; return c; }
    i32 raw(void)   { return v; }          // leaf      → inert → self-retain elided
    i32 doubled(void) { return raw() + raw(); }  // delegating → inert → elided
    void touch(void) { sink = sink + (u16)1; }    // writes a global (still inert here)
}

void main(void)
{
    Assert.reset();
    sink = 0;

    Cell* a = Cell.make(7);
    Assert.isEqual((u16)a.raw(), (u16)7);            // T1 leaf accessor
    Assert.isEqual((u16)a.doubled(), (u16)14);       // T2 delegating accessor

    // Sum a small array of cells through the accessors (the hot-path shape).
    i32 total = 0;
    u16 i = 0;
    for (i = 0; i < (u16)10; i = i + 1) {
        Cell* c = Cell.make((i32)i);
        total = total + c.raw() + c.doubled();       // raw=i, doubled=2i → 3i
    }
    Assert.isEqual((u16)total, (u16)135);            // T3  3*(0+..+9)=135

    a.touch();
    Assert.isEqual(sink, (u16)1);                    // T4  self stayed alive across touch

    Stdio.printf("DONE 4\n");
}
