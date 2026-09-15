#include "netinet/in.h"
char* inet_ntoa(struct in_addr in);
const char* inet_ntop(int af, const void* src, char* dst, unsigned size);
int inet_pton(int af, const char* src, void* dst);
