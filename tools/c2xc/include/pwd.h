#include "_fake_typedefs.h"
struct passwd
    {
    char* pw_name;
    char* pw_passwd;
    unsigned pw_uid;
    unsigned pw_gid;
    char* pw_dir;
    char* pw_shell;
    };
struct passwd* getpwnam(const char* n);
struct passwd* getpwuid(unsigned uid);
