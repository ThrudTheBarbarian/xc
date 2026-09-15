/* a function pointer crossing to C in a non-last argument (pthread_create),
   in a system-header struct (sigaction), and last (qsort): each must arrive as
   the code address, one word */
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <signal.h>
static void* startfn(void* arg)
    {
    return (void*)((long)arg + 1);
    }
static int cmp(const void* a, const void* b)
    {
    return *(const int*)a - *(const int*)b;
    }
static volatile int seen = 0;
static void onsig(int s)
    {
    seen = s;
    }
int main(void)
    {
    pthread_t t;
    void* r = 0;
    int rc = pthread_create(&t, NULL, startfn, (void*)41L);
    pthread_join(t, &r);
    printf("thread %d %ld\n", rc, (long)r);
    int v[5] = {3, 1, 4, 1, 5};
    qsort(v, 5, sizeof v[0], cmp);
    printf("%d %d %d %d %d\n", v[0], v[1], v[2], v[3], v[4]);
    struct sigaction act;
    act.sa_handler = onsig;
    act.sa_flags = 0;
    sigemptyset(&act.sa_mask);
    sigaction(SIGUSR1, &act, NULL);
    raise(SIGUSR1);
    printf("signal %d\n", seen == SIGUSR1);
    return 0;
    }
