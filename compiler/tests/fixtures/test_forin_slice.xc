#import "Stdio.xc"

void main(void) {
    u8 arr[5] = {10, 20, 30, 40, 50};
    u16 sum = 0;
    u16 cnt = 0;
    for (u8 v in arr[1..3]) {
        sum = sum + v;
        cnt = cnt + 1;
    }
    Stdio.printf("sum=%d cnt=%d\n", sum, cnt);
}
