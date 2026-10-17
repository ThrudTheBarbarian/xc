// unguarded_action.xc — -Wunguarded-action: a callback called with no test
// since it was last assigned warns; each guarded form below does not. Both
// compilers (the shipped one had no such check before 2026-10-17, and the
// reference missed `if (!f || x) continue;`).
// xtc: warn "`bare` is a callback and is called without being checked"
// xtc: warn "`reassigned` is a callback and is called without being checked"
// xtc: nowarn "`tested`"
// xtc: nowarn "`bailed`"
// xtc: nowarn "`either`"
// xtc: nowarn "`anded`"
// xtc: nowarn "`ternary`"
class T : Object
    {
    void hit(i32 v) { }
    i32 val(i32 v) { return v; }
    }
void run(T* t, bool x)
{
    callback bare void(i32 v) = &t.hit;
    bare(1);
    callback tested void(i32 v) = &t.hit;
    if (tested) { tested(2); }
    callback reassigned void(i32 v) = &t.hit;
    if (reassigned) { reassigned = &t.hit; reassigned(3); }
    for (u32 i = (u32)0; i < (u32)2; i = i + (u32)1) {
        callback bailed void(i32 v) = &t.hit;
        if (!bailed) continue;
        bailed(4);
        callback either void(i32 v) = &t.hit;
        if (!either || x) continue;
        either(5);
    }
    callback anded void(i32 v) = &t.hit;
    if (anded && x) { anded(6); }
    callback ternary i32(i32 v) = &t.val;
    i32 r = ternary ? ternary(7) : (i32)0;
    if (x) bare(r);
}
i32 main(void)
{
    T* t = new T();
    run(t, true);
    return 0;
}
