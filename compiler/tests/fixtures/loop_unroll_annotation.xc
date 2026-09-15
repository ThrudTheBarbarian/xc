#use Stdio

// bug 211: `for (...) : unroll` did not parse in the port, while the reference
// parsed it fine — a documented syntax with a worked example on the website
// that the SHIPPED compiler rejected.
//
// The annotation is INERT in both implementations: `forceUnroll` appears six
// times in the whole reference tree — parsed, stored on the AST node, and never
// read. It was a hook for the AST optimiser, removed in phase-323. So the
// correct behaviour is to accept it and carry on, which is what both now do,
// and this fixture pins that the SYNTAX is accepted and the loop still runs.
i32 main()
{
    u16 total = (u16)0;
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) : unroll
    {
        total = total + i;
    }
    printf("%d\n", total);

    u16 t2 = (u16)0;
    for (u16 i = (u16)0; i < (u16)3; i = i + (u16)1) : unroll
        t2 = t2 + (u16)10;
    printf("%d\n", t2);
    return 0;
}
