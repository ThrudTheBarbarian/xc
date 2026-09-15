// arc_global_array.xc — a GLOBAL array of class pointers is ARC-managed.
//
// `Tag* g[N];` is a fixed-size array in BSS, and its elements used to be raw
// pointer slots: `g[i] = t` stored the pointer without retaining, so `t` was
// freed at scope exit and the slot dangled. It read back as whatever object
// later reused the memory, or crashed. The scalar case (`Tag* g;`) never had
// the hole because it gates on the TYPE; the element case asked whether the
// base was a tracked strong array LOCAL, which a global is not.
//
// Two things are checked, and the second is the one a sum or a print of the
// value alone would miss: the object must SURVIVE the function that stored it
// (retain), and reassigning the slot must RELEASE the previous occupant rather
// than leak it — which is why Tag prints from dealloc.
#import "Stdio.xc"

class Tag
{
    u32 _id;
    void init(void) { _id = (u32)0; }
    static Tag* make(u32 i) { Tag* t = new Tag(); t._id = i; return t; }
    u32 id(void) { return _id; }
    void dealloc(void) { Stdio.printf("dealloc %ld\n", _id); }
}

Tag* gT[4];

// The store happens in a function that RETURNS, so an unretained slot is left
// pointing at freed memory the moment `put` exits.
void put(u32 i, u32 v) { Tag* t = Tag.make(v); gT[i] = t; }

// Reuse the freed block: without the retain this is what the slot reads back.
void churn(void)
{
    for (u32 i = (u32)0; i < (u32)6; i = i + (u32)1) {
        Tag* junk = Tag.make((u32)900 + i);
        junk.id();
    }
}

void main(void)
{
    put((u32)0, (u32)11);
    put((u32)1, (u32)12);
    churn();
    Stdio.printf("a=%ld b=%ld\n", gT[0].id(), gT[1].id());
    put((u32)0, (u32)22);          // releases 11
    Stdio.printf("c=%ld\n", gT[0].id());
}
