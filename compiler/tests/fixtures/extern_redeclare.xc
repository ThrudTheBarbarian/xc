//xtc-flags: target=arm64
// Repeated IDENTICAL body-less declarations merge, as C prototypes do
// (blewit spike, item 1). Stdio (x86_64) declares `write` for its own use;
// a program declaring the same C function again — same signature — is
// declaring the SAME function, not redefining it. This used to be
// "Redefinition of 'write' with same parameter types", which forced every
// program to know what its library had already declared.
#import "Stdio.xc"

i32 getpid(void);
i32 getpid(void);

i32 main(void)
{
    if (getpid() > (i32)0) Stdio.printf("merged\n");
    return 0;
}
