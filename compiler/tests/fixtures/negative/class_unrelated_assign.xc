// PR4: unrelated class pointers can't silently alias. Sema must
// reject `Animal@ a = v` when v's static type is a pointer to an
// unrelated class.
// xtc: error "initialiser: 'Vehicle' is not a subclass of 'Animal'"

class Animal { u8 legs; }
class Vehicle { u8 wheels; }

void main(void)
{
    Vehicle* v = new Vehicle();
    Animal* a = v;
}
