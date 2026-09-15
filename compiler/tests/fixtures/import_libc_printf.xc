// Imports libc's variadic printf via #import <c> and calls it with int AND
// float varargs. Exercises C/AAPCS varargs: ints in r1-r3, a float promoted
// to double in an 8-byte-aligned register pair (which also requires the
// prologue to keep SP 8-aligned), + DT_NEEDED libc.so on the XTOS loader.
// arm9-only: the other backends have no libc.so to import.
//xtc-na: arm64,m68k,xt6502,x86_64,win64 — imports <c> (libc); only the arm9 loader provides it
#import <c>

i32 main() {
    printf("v %d %d %d\n", 7, 35, 42);
    printf("f %f\n", 1.5);
    printf("mix %d %f %f\n", 9, 2.5, 3.25);
    return 0;
}
