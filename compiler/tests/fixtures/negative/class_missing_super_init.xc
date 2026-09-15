// PR5: subclass init that doesn't call super.init, and whose parent
// init takes arguments the compiler can't guess, must be a sema
// error. Auto-synth only kicks in when the parent has a no-arg
// init.
// xtc: error "init on 'Dog' must call super.init(...)"

class Animal
{
    u8 legs;
    void init(u8 l) { legs = l; }
}

class Dog : Animal
{
    u8 tailWag;
    void init(void)
    {
        // missing super.init(l)
        tailWag = 2;
    }
}

void main(void) { }
