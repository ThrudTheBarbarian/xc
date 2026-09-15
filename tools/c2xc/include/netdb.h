#include "_fake_typedefs.h"
#include "sys/socket.h"
struct addrinfo
    {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    unsigned ai_addrlen;
    char* ai_canonname;
    struct sockaddr* ai_addr;
    struct addrinfo* ai_next;
    };
struct hostent
    {
    char* h_name;
    char** h_aliases;
    int h_addrtype;
    int h_length;
    char** h_addr_list;
    };
#define AI_PASSIVE 1
#define AI_NUMERICHOST 4
#define NI_MAXHOST 1025
#define NI_MAXSERV 32
#define NI_NUMERICHOST 2
#define NI_NUMERICSERV 8
int getaddrinfo(const char* host, const char* serv, const struct addrinfo* hints, struct addrinfo** res);
void freeaddrinfo(struct addrinfo* res);
const char* gai_strerror(int e);
int getnameinfo(const struct sockaddr* sa, unsigned salen, char* host, unsigned hostlen, char* serv, unsigned servlen, int flags);
