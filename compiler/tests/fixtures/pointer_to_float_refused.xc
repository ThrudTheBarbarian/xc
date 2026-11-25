//xtc-flags: expect=sema-error
// No pointer has a floating value (#669): the address was converted silently.
// Refused: assignment: a pointer 'float*' has no 'float' value — dereference it (*p) for the value it points at

i32 main(void)
    {
    float x = 1.5;
    float* p = &x;
    float y = 0.0;
    y = p;
    return (i32)y;
    }
