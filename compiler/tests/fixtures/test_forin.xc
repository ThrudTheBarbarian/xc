#import "Stdio.xc"

void main(void) {
    u8 arr[3] = {10, 20, 30};
    u16 sum = 0;
    for (u8 v in arr) {
        sum = sum + v;   // 10 + 20 + 30 = 60
    }
    Stdio.printf("sum=%d\n", sum);
}
