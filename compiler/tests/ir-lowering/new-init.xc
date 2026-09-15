// new-init — `new T()` must run the class init. Box.init sets v=42;
// run() allocates a Box and returns b.v, which is 42 only if init
// actually ran (the allocator alone leaves ivars uninitialised).
// Validates the alloc + init Call shape on both backends.
class Box
    {
    u16 v;

    void init(void)
        {
        v = 42;
        }
    }

    u16
    run(void)
    {
    Box b = new Box();
    return b.v;
    }
