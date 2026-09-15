#include "_fake_typedefs.h"
#include "sys/time.h"
typedef struct
    {
    unsigned fds_bits[32];
    } fd_set;
#define FD_SETSIZE 1024
#define FD_ZERO(s) memset((s), 0, sizeof(fd_set))
#define FD_SET(n, s) ((s)->fds_bits[(n) / 32] |= (1u << ((n) % 32)))
#define FD_CLR(n, s) ((s)->fds_bits[(n) / 32] &= ~(1u << ((n) % 32)))
#define FD_ISSET(n, s) (((s)->fds_bits[(n) / 32] & (1u << ((n) % 32))) != 0)
int select(int n, fd_set* r, fd_set* w, fd_set* e, struct timeval* t);
