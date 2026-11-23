#include <windows.h>
#include <stdio.h>
_Thread_local long tv[4] = {1, 2, 3, 4};
_Thread_local long tz;
static long res[4];
static DWORD WINAPI work(LPVOID a) { long k = (long)(intptr_t)a; for (int i = 0; i < 1000; i++) { tz += k; tv[i & 3] += k; } res[k - 1] = tz + tv[0] + tv[1] + tv[2] + tv[3]; return 0; }
int main(void) { HANDLE t[4]; for (long i = 0; i < 4; i++) t[i] = CreateThread(0, 0, work, (LPVOID)(intptr_t)(i + 1), 0, 0);
  WaitForMultipleObjects(4, t, TRUE, INFINITE);
  printf("%ld %ld %ld %ld main %ld %ld\n", res[0], res[1], res[2], res[3], tz, tv[0] + tv[1] + tv[2] + tv[3]); return 0; }
