#include "_fake_typedefs.h"
int strcasecmp(const char* a, const char* b);
int strncasecmp(const char* a, const char* b, unsigned long n);
void bzero(void* p, unsigned long n);
void bcopy(const void* s, void* d, unsigned long n);
char* index(const char* s, int c);
char* rindex(const char* s, int c);
int ffs(int i);
