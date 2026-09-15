// deref — pins the unary-`@` (pointer dereference) lowering shape.
// `@p` reads through a pointer; the lowering emits Load with the
// memory token threaded.
u8 read(u8* p)
    {
    return *p;
    }

void write(u8* p, u8 v)
    {
    *p = v;
    return;
    }
