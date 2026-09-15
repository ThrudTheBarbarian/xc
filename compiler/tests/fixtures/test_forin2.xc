#import "Stdio.xc"
void main(void) {
    u8 arr[3] = { 10, 20, 30 };
    for (u8 v in arr) {
        Stdio.printf("%u\n", v);
    }
}
