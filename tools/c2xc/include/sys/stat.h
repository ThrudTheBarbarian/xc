#include "_fake_defines.h"
#include "_fake_typedefs.h"
/* c2xc: struct stat (darwin, the fields programs read) */
struct stat
    {
    int st_dev;
    unsigned short st_mode;
    unsigned short st_nlink;
    unsigned long long st_ino;
    unsigned st_uid;
    unsigned st_gid;
    int st_rdev;
    struct
        {
        long tv_sec;
        long tv_nsec;
        } st_atimespec, st_mtimespec, st_ctimespec, st_birthtimespec;
    long long st_size;
    long long st_blocks;
    int st_blksize;
    unsigned st_flags;
    unsigned st_gen;
    int st_lspare;
    long long st_qspare[2];
    };
#define st_atime st_atimespec.tv_sec
#define st_mtime st_mtimespec.tv_sec
#define st_ctime st_ctimespec.tv_sec
int stat(const char* path, struct stat* buf);
int fstat(int fd, struct stat* buf);
int lstat(const char* path, struct stat* buf);
int mkdir(const char* path, unsigned mode);
int chmod(const char* path, unsigned mode);
#define S_IFMT 0170000
#define S_IFDIR 0040000
#define S_IFREG 0100000
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
