// process_args.xc — Process.arguments() on every target that has a runtime
// for it. The corpus runs programs with NO arguments, so the count is 1 and
// only argv[0] exists; argv[0] is the program path on a host and "" on TOS
// (which passes no name), so it is not printed — only what is deterministic.
//
// Written with bug 128, when m68k got `_xt_argc`/`_xt_argv` (parsed out of
// the GEMDOS basepage's command line, in place) and `_xt_exit`. The m68k
// leg of the parse — words, separators, the in-place NUL — is exercised by
// hand under `xcc-sim-68k --args`, not here.
//
//xtc-na: xt6502 — no process runtime on a 6502. Every other target has
//        `_xt_argc`/`_xt_argv`/`_xt_exit`: m68k from the GEMDOS basepage
//        (128), x86-64/win64 from rt-files.c and wasm32 from the JS loader
//        (#81).
#import "Stdio.xc"
#import "Process.xc"

i32 main(void)
{
    u32 n = Process.argumentCount();
    Stdio.printf("argc %lu\n", n);
    for (u32 i = (u32)1; i < n; i = i + (u32)1)
        Stdio.printf("arg %lu [%s]\n", i, Process.argument(i).cString());
    Stdio.printf("done\n");
    return (i32)0;
}
