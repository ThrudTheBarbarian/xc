// cloaked_transitive_heap.xc — stage 4c: a :cloaked function
// calls a non-cloaked helper that allocates on the heap. The
// :cloaked body itself contains no `new` (so the fast-path
// scanCloakedBody error doesn't fire), but Pass C's transitive
// walk finds the helper's `new` and reports the chain.
// xtc: error ":cloaked 'bad' transitively uses the xtc software stack"
// xtc: note  "calls 'make' which allocates with 'new'"

class Widget { u8 x; }

Widget* make(void)
{
    Widget* w = new Widget();
    w.x = 5;
    return w;
}

void bad(void) : cloaked
{
    Widget* w = make();
}

void main(void) { }
