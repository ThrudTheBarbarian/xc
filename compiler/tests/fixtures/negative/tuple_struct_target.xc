// A tuple target that is a struct is refused. A struct target used only
// through a member was refused in lowering, but one passed or assigned whole
// built silently and read the wrong bytes (#452).
// xtc: error "a tuple cannot hold the struct 'lo'; pass a pointer to it instead"
struct V3 { float x; float y; float z; }
V3 v3(float x, float y, float z) { V3 r; r.x = x; r.y = y; r.z = z; return r; }
float sum(V3 a) { return a.x + a.y + a.z; }
bool, V3, V3 bounds(float a) { return true, v3(a, 1.0, 2.0), v3(3.0, 4.0, a); }
float use(V3 lo, V3 hi) { return sum(lo) + sum(hi); }
i32 main(void)
    {
    (bool any, V3 lo, V3 hi) = bounds(5.0);
    return any ? (i32)use(lo, hi) : 0;
    }
