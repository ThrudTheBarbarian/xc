// A parameter that holds its instance by value cannot move to the heap, so a
// strong pointer cannot hold its address (#604).
// xtc: error "'&p' is the address of the parameter p, which holds its instance by value and cannot move to the heap; copy it into a local (P c = p;) and take the local's address"

class P : Object { i32 a; i32 b; }

P* gLast;

void keep(P p) { gLast = &p; }

i32 main(void)
    {
    P y;
    keep(y);
    return 0;
    }
