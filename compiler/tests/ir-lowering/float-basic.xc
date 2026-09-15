// float-basic — pins the float type-mapping shape. xtc `float`
// is a 5-byte Atari format → IR F40; `double` → F64. A global
// `gF` initialised to 3.25 registers as a DataGlobal whose bytes
// the backend bakes in. The function reads the global (AddrOf +
// Load on a 5-byte slot) and binds a fresh float literal local.
// NO arithmetic, NO float return — those await the float-arith
// task.
float gF = 3.25;

void use_floats(void)
    {
    float x = gF;
    float y = 1.5;
    }
