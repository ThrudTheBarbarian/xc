#import "Stdio.xc"
void main(void) {
    u8 arr[3] = { 10, 20, 30 };
    // C-style loop
    for (u8 i = 0; i < 3; i++) {
        Stdio.printf("%u\n", arr[i]);
    }
}
