#import "Stdio.xc"
void main(void) {
    u8 arr[10] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    u16 sum = 0;
    for (u8 v in arr[2...4]) sum = sum + v;
    Stdio.printf("sum=%u\n", sum);
}
