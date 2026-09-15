// for_in_inferred_type.xc — `for ... in` with and without an element type.
//
// The grammar makes the type optional. It used to be accepted and then lowered
// into nothing: no element type reached lowering, which returned without
// emitting a loop, so the body never ran and NOTHING said why (bug 036). A
// loop that silently does not run reads as "the collection was empty".
//
// Both spellings must produce identical output.
#import "Stdio.xc"

i32 main(void)
{
    u16 sq[5];
    for (u16 i = (u16)0; i < (u16)5; i = i + (u16)1) sq[i] = i * i;

    Stdio.print("typed    ");
    for (u16 v in sq) Stdio.printf("%d ", v);
    Stdio.print("\n");

    Stdio.print("inferred ");
    for (v in sq) Stdio.printf("%d ", v);
    Stdio.print("\n");

    // Inference through a pointer to the same storage.
    u8 bytes[4];
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) bytes[i] = (u8)(i + (u16)65);
    Stdio.print("bytes    ");
    for (b in bytes) Stdio.printf("%d ", (u16)b);
    Stdio.print("\n");
    return 0;
}
