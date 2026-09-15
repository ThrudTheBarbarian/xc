// class-inherit — parent class + child override. Sets the vtable
// slot-allocation baseline: Animal.speak occupies slot 0 in Animal's
// vtable; Dog inherits the slot and overrides it. A bare call to
// `speak()` inside another method routes to the inherited method
// when invoked on an Animal@ receiver — concrete dispatch slot is
// reserved for task #18 (backend VTblDispatch coverage).
class Animal
    {
    u8 legs;

    u8 speak(void)
        {
        return 1;
        }
    }

    class Dog : Animal
    {
    u8 tail;

    u8 speak(void)
        {
        return 2;
        }
    }

    u8
    run(void)
    {
    Dog* d = new Dog();
    return d.speak();
    }
