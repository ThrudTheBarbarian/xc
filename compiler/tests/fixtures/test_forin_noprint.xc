// Verify for-in works by writing to a global array, then print the
// results so the loop's effect is observable (was a no-print sentinel).
#import "Stdio.xc"

u16 results[3];
u8 ri = 0;

void main(void) {
    u8 arr[3] = { 10, 20, 30 };
    for (u8 v in arr) {
        results[ri] = v;
        ri++;
    }
    Stdio.printf("ri=%d r0=%d r1=%d r2=%d\n",
                 (u16)ri, results[0], results[1], results[2]);
}
