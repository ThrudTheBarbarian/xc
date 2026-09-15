// compound-assign — `x op= y` lowers by expanding to `x = x op y` and
// reusing the existing plain-assignment path for the lvalue (task #61).
// Here the lvalue is a plain SSA local; the rewrite reads the current
// binding, applies the binary op, and rebinds. Arch-neutral.
u16 run(u16 a)
    {
    u16 x = a;
    x += 5;
    x *= 2;
    x -= 1;
    x &= $00FF;
    x <<= 1;
    return x;
    }
