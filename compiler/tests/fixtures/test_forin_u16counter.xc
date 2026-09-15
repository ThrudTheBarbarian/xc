#import "Stdio.xc"
void main(void) {
    u16 arr[3] = { 100, 200, 300 };
    for (u16 v in arr) {
        Stdio.printf("%u\n", v);
    }
}
