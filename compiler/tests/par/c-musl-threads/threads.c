#include <pthread.h>
#include <stdio.h>
_Thread_local long tv[4] = {1, 2, 3, 4};
_Thread_local long tz;
static void* work(void* a) { long k = (long)a; for (int i = 0; i < 1000; i++) { tz += k; tv[i & 3] += k; } return (void*)(tz + tv[0] + tv[1] + tv[2] + tv[3]); }
int main(void) { pthread_t t[4]; void* r[4]; for (long i = 0; i < 4; i++) pthread_create(&t[i], 0, work, (void*)(i + 1));
  for (int i = 0; i < 4; i++) pthread_join(t[i], &r[i]);
  printf("%ld %ld %ld %ld main %ld %ld\n", (long)r[0], (long)r[1], (long)r[2], (long)r[3], tz, tv[0] + tv[1] + tv[2] + tv[3]); return 0; }
