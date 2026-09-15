// PR1: direct self-cycle — `class A : A` — must be a sema error.
// xtc: error "Circular inheritance"

class A : A
{
    u8 x;
}

void main(void) { }
