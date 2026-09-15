#import "Stdio.xc"

u8 out[4];
u8 out_idx = 0;
void print_u8(u8 v) { out[out_idx] = v; out_idx++; }

void main(void) {
    u8 arr[2] = { 10, 20 };
    for (u8 v in arr) {
        print_u8(v);
    }
    Stdio.printf("idx=%d out0=%d out1=%d\n",
                 (u16)out_idx, (u16)out[0], (u16)out[1]);
}
