//xtc-flags: expect=sema-error
// A string literal is a pointer, not a number (#669): stored in a float it
// compiled silently and held the address.
// Refused: initialiser: a string literal is a pointer, not a 'float' — for one character write 'x' (or s[0]); for a number in text, parse it (NumberFormatter's parse); cast explicitly if the address is really meant

i32 main(void)
    {
    float c = "x";
    return (i32)c;
    }
