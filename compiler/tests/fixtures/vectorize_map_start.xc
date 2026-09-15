// vectorize_map_start.xc — a MAP loop that does not start at zero.
//
// Sibling of vectorize_const_tail.xc, and the more dangerous shape. The
// reduction case returned a wrong SUM; this one WRITES OUTSIDE THE RANGE:
//
//     for (i = 2; i < 16; i++) gb[i] = ga[i] + 100;
//
// vectorised from the existing induction phi, which starts at 2, and the
// vector store covers a whole 4-lane group — so gb[0] and gb[1], which the
// loop must never touch, were overwritten at -O2 and above. Reported from a
// renderer spike (`p[i]=A` at i=2) after the reduction-only fix (#1125) left
// this recogniser untouched.
//
// The check now lives in EVERY recogniser, not just the reduction one:
// map, reduction, min/max, count, dot-product and widening-sum all step the
// existing phi by the vector width, and all were making the same unchecked
// assumption.
#import "Stdio.xc"

u32 ga[16];
u32 gb[16];

void mapFrom2(void) { for (u32 i = (u32)2; i < (u32)16; i = i + (u32)1) gb[i] = ga[i] + (u32)100; }
void mapFrom0(void) { for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1) gb[i] = ga[i] + (u32)200; }

void main(void)
{
    for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1) { ga[i] = i; gb[i] = (u32)999; }
    mapFrom2();
    // 0 and 1 must still hold the sentinel: the loop started at 2.
    Stdio.printf("from2: gb0=%ld gb1=%ld gb2=%ld gb15=%ld\n", gb[0], gb[1], gb[2], gb[15]);
    mapFrom0();
    Stdio.printf("from0: gb0=%ld gb15=%ld\n", gb[0], gb[15]);
}
