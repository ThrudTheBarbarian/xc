#include <stdio.h>
int sum(int* a, int n)
    {
    int s = 0;
    while (n-- > 0)
        s += *a++;
    return s;
    }
int main(void)
    {
    int arr[5] = {1, 2, 3, 4, 5};
    int *p = arr, *q = &arr[4];
    printf("%d %ld %d\n", sum(arr, 5), (long)(q - p), *(p + 2));
    char buf[16];
    char* d = buf;
    const char* s = "hello";
    while ((*d++ = *s++) != 0)
        ;
    printf("%s %d\n", buf, (int)(d - buf));
    int** pp = &p;
    **pp = 42;
    printf("%d %d\n", arr[0], p[0]);
    p += 2;
    p--;
    printf("%d\n", *p);
    unsigned char bytes[4] = {0xff, 0x80, 1, 0};
    printf("%d %d\n", bytes[0], bytes[1] >> 4);
    return 0;
    }
