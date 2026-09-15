/* c2xc: struct tms is passed by address only */
struct tms
    {
    long tms_utime;
    long tms_stime;
    long tms_cutime;
    long tms_cstime;
    };
long times(struct tms* buf);
