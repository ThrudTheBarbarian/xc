//xtc-flags: expect=sema-error
// undeclared_call_named.xc — bug 209. Calling a function that does not exist
// must name it AND give a position. The self-hosted compiler said a bare
// "unresolved call": no symbol, no file, no line, one line per call site. A
// framework build lost a diagnosis to it — a link failure whose real cause
// was a missing -L, read from that message as a bad include path.
//
// The reference had always printed `file:line:col: error: Call to undeclared
// function 'f'`, so this was a DIVERGENCE, and the shipped compiler is the
// port. diag-diff passed 25/25 throughout, because no fixture exercised it:
// this is that fixture.
#use Stdio

i32 main()
{
    i32 x = someMissingThing((i32)3);
    printf("%ld\n", x);
    return 0;
}
