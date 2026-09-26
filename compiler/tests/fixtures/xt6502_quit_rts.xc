//xtc-flags: -Q rts
//xtc-na: arm64,arm9,m68k,x86_64,win64,wasm32 — -Q is an xt6502 option; elsewhere main's return of 42 is a failing exit status
// xt6502_quit_rts.xc — `-Q rts`, the default quit style: when main returns,
// the startup returns to the loader with main's value in A. xcc-sim-6502 treats
// that return as the end of the run and exits with the value; on the machine
// the RTS goes back to DOS, which started the program with a JSR. The value is
// checked by tests/driver/flag-parity.sh; this checks the program runs to its
// end and nothing after main's return prints.
#import "Stdio.xc"

i32 twice(i32 v)
{
    return v * 2;
}

i32 main(void)
{
    Stdio.printf("quit style rts: main returns %d\n", twice(21));
    return twice(21);
}
