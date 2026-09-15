#include "_fake_typedefs.h"
typedef unsigned socklen_t;
struct sockaddr
    {
    unsigned char sa_len;
    unsigned char sa_family;
    char sa_data[14];
    };
struct sockaddr_storage
    {
    unsigned char ss_len;
    unsigned char ss_family;
    char __ss_pad[126];
    };
#define AF_UNSPEC 0
#define AF_INET 2
#define AF_INET6 30
#define PF_INET AF_INET
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 0xffff
#define SO_REUSEADDR 4
#define SO_KEEPALIVE 8
#define SHUT_RDWR 2
int socket(int d, int t, int p);
int bind(int fd, const struct sockaddr* a, unsigned len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr* a, unsigned* len);
int connect(int fd, const struct sockaddr* a, unsigned len);
int setsockopt(int fd, int level, int opt, const void* v, unsigned len);
int getsockname(int fd, struct sockaddr* a, unsigned* len);
int getpeername(int fd, struct sockaddr* a, unsigned* len);
int shutdown(int fd, int how);
long send(int fd, const void* b, unsigned long n, int flags);
long recv(int fd, void* b, unsigned long n, int flags);
#define SOMAXCONN 128
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
