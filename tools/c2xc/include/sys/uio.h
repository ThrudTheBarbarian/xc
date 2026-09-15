#include "_fake_typedefs.h"
struct iovec
    {
    void* iov_base;
    unsigned long iov_len;
    };
long readv(int fd, const struct iovec* iov, int n);
long writev(int fd, const struct iovec* iov, int n);
