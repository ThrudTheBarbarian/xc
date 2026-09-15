// PR5: calling super.init more than once in the same init body is
// ambiguous (which call gets the auto-null-propagation wrapper?
// which sets up parent state first?). Sema rejects.
// xtc: error "duplicate super.init call in 'Dog.init'"

class Animal
{
    u8 legs;
    void init(void) { legs = 4; }
}

class Dog : Animal
{
    u8 tailWag;
    void init(void)
    {
        super.init();
        super.init();   // illegal
        tailWag = 2;
    }
}

void main(void) { }
