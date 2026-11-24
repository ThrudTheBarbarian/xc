// A by-value member named bare in a method is inside self; a strong pointer
// cannot hold its address (#604).
// xtc: error "'&inner' points inside self, and a pointer into an instance cannot be counted; copy the member out (P c = inner;), or allocate it with new"

class P : Object { i32 a; }
class Outer : Object
    {
    P inner;
    P* get(void) { return &inner; }
    }

i32 main(void)
    {
    Outer* o = new Outer();
    return o.get().a;
    }
