/****************************************************************************\
|* Minimal dispatch_once shim for GNUstep/Linux.
|* Uses a double-checked lock with C11 atomics.
|* Guards prevent conflicts when the real libdispatch is present.
\****************************************************************************/
#ifndef DISPATCH_COMPAT_H
#define DISPATCH_COMPAT_H

#ifndef __DISPATCH_PUBLIC_HEADER__ /* real dispatch/dispatch.h not present */

#include <pthread.h>
#include <stdatomic.h>

typedef atomic_int dispatch_once_t;

static inline void dispatch_once(dispatch_once_t* pred, void (^block)(void))
    {
    if (atomic_load_explicit(pred, memory_order_acquire) == 0)
        {
        static pthread_mutex_t _once_mutex = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&_once_mutex);
        if (atomic_load_explicit(pred, memory_order_relaxed) == 0)
            {
            block();
            atomic_store_explicit(pred, 1, memory_order_release);
            }
        pthread_mutex_unlock(&_once_mutex);
        }
    }

#endif /* __DISPATCH_PUBLIC_HEADER__ */
#endif /* DISPATCH_COMPAT_H */
