//xtc-flags: -Q loop
// xt6502_quit_loop.xc — `-Q loop`: when main returns, the startup jumps to
// itself instead of returning to the loader, so the machine spins. The value is
// still in A; xcc-sim-6502 recognises the jump to itself as the end of the run
// and exits with it (tests/driver/flag-parity.sh checks the value).
#import "Stdio.xc"

i32 main(void)
{
    i32 v = 3;
    v = v * 2 + 1;
    Stdio.printf("quit style loop: main returns %d\n", v);
    return v;
}
