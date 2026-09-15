// selfhost-hello.xc — end-to-end self-hosted-toolchain smoke: compiled by xtc,
// assembled + linked + signed entirely in-house (no clang/codesign/system as).
#import "Stdio.xc"
use Stdio;
void main(void)
    {
    printf("Hello, native!\n");
    printf("answer=%d\n", (i16)42);
    }
