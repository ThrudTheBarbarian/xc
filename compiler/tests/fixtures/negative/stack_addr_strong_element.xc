// An element of an array of instances has no header of its own, so a strong
// pointer cannot hold its address (#604).
// xtc: error "'&g[1]' points inside the array g, and a pointer into an array cannot be counted; copy the element out (P c = g[1];), or allocate it with new"

class P : Object { i32 a; }

P g[3];

i32 main(void)
    {
    P* r = &g[1];
    return r.a;
    }
