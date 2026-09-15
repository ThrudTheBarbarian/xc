#include "_fake_defines.h"
#include "_fake_typedefs.h"
/* c2xc: struct tm as every host lays it out */
struct tm
    {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
    long tm_gmtoff;
    char* tm_zone;
    };
struct timespec
    {
    long tv_sec;
    long tv_nsec;
    };
time_t time(time_t* t);
struct tm* localtime(const time_t* t);
struct tm* gmtime(const time_t* t);
struct tm* localtime_r(const time_t* t, struct tm* out);
struct tm* gmtime_r(const time_t* t, struct tm* out);
time_t mktime(struct tm* tm);
char* ctime(const time_t* t);
char* asctime(const struct tm* tm);
unsigned long strftime(char* s, unsigned long max, const char* fmt, const struct tm* tm);
clock_t clock(void);
double difftime(time_t a, time_t b);
char* strptime(const char* s, const char* fmt, struct tm* tm);
