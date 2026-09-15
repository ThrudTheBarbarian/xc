#use Stdio

// bug 205: `&param` on a scalar parameter gets its own frame slot (bug 202).
// The port's arm64 back end loaded that slot at the WRONG WIDTH — `ldrb`
// for an I32 — so any value over 255 came back truncated. 256 reads as 0.
void bump(i32* a, i32* b) { *a = *a + 1; *b = *b + 1; return; }

i32 tr8(i32 row, i32 col)
{
    if ((row == 0) || (col == 0)) return -1;
    bump(&row, &col);
    return row * 10000 + col;
}

i32 main()
{
    printf("%ld\n", tr8(102, 256));
    printf("%ld\n", tr8(2, 273));
    printf("%ld\n", tr8(1, 1));
    return 0;
}
