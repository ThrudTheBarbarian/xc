#import "Stdio.xc"
void main(void) {
    u8 arr[10] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    u16 sum = 7;
    u16 count = 0;
    for (u8 v in arr[5..5]) { sum = sum + v; count = count + 1; }
    Stdio.printf("sum=%u count=%u\n", sum, count);
}
