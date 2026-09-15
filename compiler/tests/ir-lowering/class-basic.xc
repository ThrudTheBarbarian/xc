// class-basic — minimum viable class lowering: one ivar, one method,
// one `new`, one method call. Sets the baseline shape for the class
// expressions (FieldAddr / Load / Store / Retain / Release / Call).
class Foo
    {
    u8 x;

    u8 get(void)
        {
        return x;
        }
    }

    u8
    run(void)
    {
    Foo* f = new Foo();
    f.x = 42;
    return f.get();
    }
