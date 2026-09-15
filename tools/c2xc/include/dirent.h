#include "_fake_typedefs.h"
struct dirent
    {
    unsigned long long d_ino;
    unsigned long long d_seekoff;
    unsigned short d_reclen;
    unsigned short d_namlen;
    unsigned char d_type;
    char d_name[1024];
    };
typedef struct
    {
    int fd;
    } DIR;
DIR* opendir(const char* p);
struct dirent* readdir(DIR* d);
int closedir(DIR* d);
