// xtc: error "Expected type in declaration"
// A return list is written bare, `i32, i32 pair(void)` (functions.md); the
// parenthesised form is not a declaration. The port parsed it, undocumented,
// and the reference refused it (2026-10-24: both refuse it now).
(i32, i32) pair(void) { return 1, 2; }
i32 main(void)
    {
    (i32 a, i32 b) = pair();
    return a + b - 3;
    }
