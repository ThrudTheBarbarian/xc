// main_argc_argv.xc — `main` DECLARING parameters.
//
// Every other fixture spells the entry point `i32 main()`, so nothing in the
// suite ever emitted a call to a main that takes arguments. On wasm32 the
// entry export is a zero-parameter wrapper that calls the real main, and it
// pushed nothing before the call — so a main with parameters produced a module
// no host would validate ("not enough arguments on the stack for call"), and
// one line of source was enough to trigger it (bug 116 / blewit FINDINGS #18b).
//
// argc/argv are read, not merely declared: a fixture that ignores them would
// still pass if the arguments were dropped on the way in.
//
// This ran arm64-only until bug 121: xt6502's startup pushes nothing, so a
// `main` with parameters read whatever the stack held — nonzero garbage argc
// with a null argv. Both back ends now zero the entry function's incoming
// parameter bytes, so the fixture covers every target and the 6502 entry ABI
// is held by the corpus rather than by a comment saying it is broken.
#use Stdio

i32 main(i32 argc, u8** argv)
{
    // A hosted run gets argc >= 1; wasm32 has no command line and passes 0.
    // Both are correct, so the check is that argc is SANE and argv agrees with
    // it, rather than a fixed number.
    if (argc < (i32)0 || argc > (i32)1000) { printf("ARGC BAD\n"); return (i32)1; }
    if (argc > (i32)0 && argv == (u8**)0)  { printf("ARGV NULL\n"); return (i32)1; }
    printf("DONE\n");
    return (i32)0;
}
