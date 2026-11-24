// A global array of class instances has no header for each element, so it
// is refused as a local one is (#641).
// xtc: error "a global array of class instances (`P[3]`) is not supported; declare an array of references (`P* ga[N]`) instead"

class P : Object { i32 a; }

P ga[3];

i32 main(void)
    {
    return 0;
    }
