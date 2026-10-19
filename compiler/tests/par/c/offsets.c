/* offsets: stores at [i + c], and pointer arrays that may overlap touched
   at an offset or by rows: blocks, whose run-time overlap check compares
   the elements each touches (k * i + [c0, c1]); the calls that do overlap
   run serially. */
#include <stdio.h>
#define N 100000
int a[N + 4], b[N + 4], c[N + 4];
void shift(int *d, const int *s, int n) { for (int i = 0; i < n; i++) d[i + 1] = s[i] * 2; }
void rows(int *d, const int *s) { for (int i = 0; i < 100; i++) for (int j = 0; j < 100; j++) d[i * 100 + j] = s[i * 100 + j] + 1; }
int main(void)
{
    for (int i = 0; i < N + 4; i++) { a[i] = i % 97; b[i] = 0; c[i] = 0; }
    for (int i = 0; i < N; i++) b[i + 2] = a[i] + a[i + 3];
    for (int i = 1; i < N; i++) c[i - 1] = b[i] * 3;
    shift(c, a, N);
    rows(b, a);
    rows(a + 50, a);          /* overlapping rows: must stay serial-correct */
    shift(a, a, N);           /* one array, the store a step ahead: serial */
    shift(b + 10, b, 5);      /* overlapping, a short run */
    rows(c + 20000, b);       /* apart: parallel */
    long long t = 0;
    for (int i = 0; i < N + 4; i++) t += (long long)a[i] * 7 + b[i] * 3 + c[i];
    printf("%lld\n", t);
    return 0;
}
