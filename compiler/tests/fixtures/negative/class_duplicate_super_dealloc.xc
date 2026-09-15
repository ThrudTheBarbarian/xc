// PR6: calling super.dealloc more than once in the same dealloc
// body is ambiguous (the auto-append position becomes unclear,
// and the ancestor's body runs twice). Sema rejects.
// xtc: error "duplicate super.dealloc call in 'Dog.dealloc'"

class Animal
{
    u8 legs;
    void dealloc(void) { }
}

class Dog : Animal
{
    u8 tailWag;
    void dealloc(void)
    {
        super.dealloc();
        super.dealloc();   // illegal
    }
}

void main(void) { }
