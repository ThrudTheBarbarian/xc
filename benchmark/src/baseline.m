// baseline — startup only. See baseline.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, char **argv)
    {
    @autoreleasepool { printf("%u 0\n", (uint32_t)argc); }
    return 0;
    }
