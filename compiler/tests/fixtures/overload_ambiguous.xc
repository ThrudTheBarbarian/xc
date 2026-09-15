//xtc-flags: expect=sema-error
// Ambiguous overload — expects a sema error.

void g(u8 a, u16 b)
    {
    }

void g(u16 a, u8 b)
    {
    }

void main(void)
    {
    g(1, 1);   // could go either way
    return;
    }