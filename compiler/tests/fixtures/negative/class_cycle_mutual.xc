// PR1: mutual cycle — `A : B ; B : A` — must be a sema error. The
// diagnostic names the class whose chain was followed when the
// cycle was detected; we check for the shared "Circular inheritance"
// substring so either order satisfies the match.
// xtc: error "Circular inheritance"

class A : B
{
    u8 x;
}

class B : A
{
    u8 y;
}

void main(void) { }
