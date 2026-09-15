//xtc-flags: target=arm64
// ivar_step_in_method.xc — bug 35 (blewit's site gap). A bare `outstanding++`
// inside a method is an implicit-self ivar step: it must RMW the ivar slot, not
// rebind a dead SSA local (the reference silently lost it; the port rejected it
// as "step of a non-local").
i32 printf(u8* f, ...);
class Pool {
    u32 outstanding;
    void submit(void) { outstanding++; }
    void done(void)   { outstanding--; }
    u32 count(void)   { return outstanding; }
}
i32 main(void) {
    Pool p = new Pool;
    p.submit(); p.submit(); p.submit(); p.done();
    printf("%u\n", p.count());
    return 0;
}
