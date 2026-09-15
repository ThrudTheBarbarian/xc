#import "Stdio.xc"

u8 results[3];
u8 ri = 0;

void main(void) {
    u8 arr[3] = { 10, 20, 30 };
    for (u8 v in arr) {
        results[ri] = v;
        ri++;
    }
    Stdio.printf("ri=%d r0=%d r1=%d r2=%d\n",
                 (u16)ri, (u16)results[0], (u16)results[1], (u16)results[2]);
}
