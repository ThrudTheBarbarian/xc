// The `?` failable-cast modifier is only meaningful on a
// class-pointer cast. Applying it to a scalar or non-class
// pointer is a sema error.
// xtc: error "'?' failable-cast modifier is only valid on class-pointer casts"

void main(void) {
    u8 x = 5;
    u16 y = (u16 ?)x;      // ? on a scalar cast — rejected.
}
