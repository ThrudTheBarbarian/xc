// cloaked_transitive_method.xc — stage 4c: a :cloaked function
// reaches the xtc stack through a two-hop chain — a non-cloaked
// helper that dispatches to a class method that calls `new`.
// Pass C must name the method at the leaf, the helper in the
// middle, and the cloaked entry at the head.
// xtc: error ":cloaked 'bad' transitively uses the xtc software stack"
// xtc: note  "calls 'invoke' which"
// xtc: note  "calls 'Allocator.grab' which allocates with 'new'"

class Allocator {
    u8 junk;
    u8* grab(void)
    {
        u8* p = new u8[4];
        return p;
    }
}

Allocator* gAlloc;

void invoke(Allocator* a)
{
    u8* p = a.grab();
}

void bad(void) : cloaked
{
    invoke(gAlloc);
}

void main(void) { }
