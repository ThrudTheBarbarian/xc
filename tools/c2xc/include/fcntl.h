#include "_fake_defines.h"
#include "_fake_typedefs.h"
/* c2xc: darwin's struct flock (LP64) */
struct flock
    {
    long long l_start;
    long long l_len;
    int l_pid;
    short l_type;
    short l_whence;
    };
int open(const char* path, int flags, ...);
int fcntl(int fd, int cmd, ...);
int creat(const char* path, unsigned mode);
