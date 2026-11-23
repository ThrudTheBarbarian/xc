// xtc: error "holds an instance of itself by value through ivar"
// A class cannot hold an instance of itself by value, directly or through
// another class: it would have no size. A pointer member (`Ring* next;`) can.
class Link { i32 n; Ring r; }
class Ring { i32 k; Link l; }
i32 main(void) { Ring r; r.k = 1; return r.k; }
