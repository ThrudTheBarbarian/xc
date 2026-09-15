#include "_fake_typedefs.h"
/* c2xc: POSIX threads as opaque words; the converted program's thread
   layer is expected to be replaced by xc's Thread/Mutex/Cond */
typedef unsigned long pthread_t;
typedef struct
    {
    long opaque[8];
    } pthread_mutex_t;
typedef struct
    {
    long opaque[6];
    } pthread_cond_t;
typedef struct
    {
    long opaque[8];
    } pthread_attr_t;
typedef struct
    {
    long opaque[8];
    } pthread_mutexattr_t;
typedef struct
    {
    long opaque[8];
    } pthread_condattr_t;
typedef unsigned long pthread_key_t;
typedef int pthread_once_t;
#define PTHREAD_MUTEX_INITIALIZER {{0}}
#define PTHREAD_COND_INITIALIZER {{0}}
int pthread_create(pthread_t* t, const pthread_attr_t* a, void* (*fn)(void*), void* arg);
int pthread_join(pthread_t t, void** ret);
int pthread_detach(pthread_t t);
pthread_t pthread_self(void);
void pthread_exit(void* ret);
int pthread_mutex_init(pthread_mutex_t* m, const pthread_mutexattr_t* a);
int pthread_mutex_lock(pthread_mutex_t* m);
int pthread_mutex_unlock(pthread_mutex_t* m);
int pthread_mutex_destroy(pthread_mutex_t* m);
int pthread_cond_init(pthread_cond_t* c, const pthread_condattr_t* a);
int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m);
int pthread_cond_timedwait(pthread_cond_t* c, pthread_mutex_t* m, const void* abstime);
int pthread_cond_signal(pthread_cond_t* c);
int pthread_cond_broadcast(pthread_cond_t* c);
int pthread_cond_destroy(pthread_cond_t* c);
int pthread_key_create(pthread_key_t* k, void (*dtor)(void*));
void* pthread_getspecific(pthread_key_t k);
int pthread_setspecific(pthread_key_t k, const void* v);
int pthread_attr_init(pthread_attr_t* a);
int pthread_attr_setstacksize(pthread_attr_t* a, unsigned long n);
int pthread_attr_destroy(pthread_attr_t* a);
int pthread_sigmask(int how, const void* set, void* old);
int pthread_kill(pthread_t t, int sig);
#define PTHREAD_CREATE_DETACHED 2
#define PTHREAD_STACK_MIN 16384
int pthread_attr_setdetachstate(pthread_attr_t* a, int state);
