// An ivar named like a method an ancestor declares: `s.hash` would call
// Object.hash() on a load while a store writes the ivar.
// xtc: error "ivar 'hash' of 'Slice' has the name of a method of 'Object'"

class Slice
{
    u32 hash;
    u32 len;
}

void main(void)
{
    Slice* s = new Slice();
    s.hash = 42;
    printf("%u\n", s.hash);
}
