/* c2xc_pre.h — force-included ahead of the fake libc headers: what they lack. */
typedef int __builtin_va_list;
typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, T) __c2xc_va_arg(ap, (T)0)
#define va_end(ap) __builtin_va_end(ap)
#define va_copy(d, s) __builtin_va_copy(d, s)
#define NULL ((void*)0)
#define offsetof(T, f) ((unsigned long)&(((T*)0)->f))
/* what a real stdio.h defines and the fake one does not */
#define EOF (-1)
#define BUFSIZ 1024
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define RAND_MAX 2147483647
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
/* fcntl / stat / errno / math constants, darwin+linux values that agree */
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_ACCMODE 3
#define O_CREAT 0x0200
#define O_TRUNC 0x0400
#define O_EXCL 0x0800
#define O_APPEND 0x0008
#define O_NONBLOCK 0x0004
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRGRP 040
#define S_IWGRP 020
#define S_IXGRP 010
#define S_IROTH 04
#define S_IWOTH 02
#define S_IXOTH 01
#define S_IRWXU 0700
#define S_IRWXG 070
#define S_IRWXO 07
#define EINTR 4
#define EAGAIN 35
#define ENOENT 2
#define EEXIST 17
#define EINVAL 22
#define EPIPE 32
#define EWOULDBLOCK EAGAIN
#define HUGE_VAL 1.7976931348623157e+308
#define M_PI 3.14159265358979323846
#define M_E 2.7182818284590452354
#define INFINITY HUGE_VAL
#define NAN (0.0 / 0.0)
#define SIGINT 2
#define SIGTERM 15
#define SIGPIPE 13
#define SIGHUP 1
#define SIGALRM 14
#define SIGUSR1 30
#define SIG_IGN ((void (*)(int))1)
#define SIG_DFL ((void (*)(int))0)
#define F_GETFL 3
#define F_SETFL 4
#define F_SETLK 8
#define F_SETLKW 9
#define F_RDLCK 1
#define F_WRLCK 3
#define F_UNLCK 2
/* POSIX typedefs the fake headers lack */
typedef unsigned char sa_family_t;
typedef unsigned short in_port_t;
typedef unsigned in_addr_t;
typedef unsigned socklen_t;
typedef unsigned nfds_t;
typedef int dev_t;
typedef unsigned long long ino_t;
typedef unsigned short nlink_t;
typedef int blksize_t;
typedef long long blkcnt_t;
typedef int suseconds_t;
typedef unsigned useconds_t;
typedef int key_t;
typedef unsigned id_t;
typedef long intmax_t;
typedef unsigned long uintmax_t;
#define EBADF 9
