#include "_fake_typedefs.h"
struct in_addr
    {
    unsigned s_addr;
    };
struct sockaddr_in
    {
    unsigned char sin_len;
    unsigned char sin_family;
    unsigned short sin_port;
    struct in_addr sin_addr;
    char sin_zero[8];
    };
struct in6_addr
    {
    unsigned char s6_addr[16];
    };
struct sockaddr_in6
    {
    unsigned char sin6_len;
    unsigned char sin6_family;
    unsigned short sin6_port;
    unsigned sin6_flowinfo;
    struct in6_addr sin6_addr;
    unsigned sin6_scope_id;
    };
#define INADDR_ANY 0
#define INADDR_LOOPBACK 0x7f000001
#define IPPROTO_TCP 6
unsigned short htons(unsigned short x);
unsigned short ntohs(unsigned short x);
unsigned htonl(unsigned x);
unsigned ntohl(unsigned x);
/* darwin: the address is v4-mapped when the first ten bytes are zero and the next two 0xff */
#define IN6_IS_ADDR_V4MAPPED(a) ((a)->s6_addr[0] == 0 && (a)->s6_addr[1] == 0 && (a)->s6_addr[2] == 0 && (a)->s6_addr[3] == 0 && (a)->s6_addr[4] == 0 && (a)->s6_addr[5] == 0 && (a)->s6_addr[6] == 0 && (a)->s6_addr[7] == 0 && (a)->s6_addr[8] == 0 && (a)->s6_addr[9] == 0 && (a)->s6_addr[10] == 0xff && (a)->s6_addr[11] == 0xff)
