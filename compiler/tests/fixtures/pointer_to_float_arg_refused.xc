//xtc-flags: expect=sema-error
// A float-returning free call in a return checks its arguments too: the
// float-return tie-breaker used to pick it although nothing converted.
// Refused: argument 1 of 'half': a pointer 'float*' has no 'float' value — dereference it (*p) for the value it points at

float half(float f) { return f / 2.0; }

float g(float* p)
    {
    return half(p);
    }

i32 main(void)
    {
    float x = 3.0;
    return (i32)g(&x);
    }
