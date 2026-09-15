#import "Stdio.xc"
void main(void) {
    u8 arr[2] = { 10, 20 };
    for (u8 v in arr) {
        Stdio.printf("%u\n", v);
    }
}
