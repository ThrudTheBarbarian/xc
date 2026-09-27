//xtc-flags: expect=sema-error
// class_unknown_parent.xc — a class whose parent names no class is refused
// ("Unknown parent class 'Nope' for class 'A'"): its layout and dispatch start
// from the parent's, so there is nothing to build it from. The shipped
// compiler used to accept it and build A as if it had no parent (bug 442).
class A : Nope
    {
    i32 x;
    }

i32 main(void)
{
    A* a = new A();
    return a.x;
}
