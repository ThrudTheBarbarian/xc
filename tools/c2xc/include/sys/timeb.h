#include "_fake_typedefs.h"
struct timeb
    {
    long time;
    unsigned short millitm;
    short timezone;
    short dstflag;
    };
int ftime(struct timeb* tb);
