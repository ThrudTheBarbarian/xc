#include "_fake_typedefs.h"
typedef void (*sig_t)(int);
typedef unsigned sigset_t;
struct sigaction
    {
    void (*sa_handler)(int);
    sigset_t sa_mask;
    int sa_flags;
    };
sig_t signal(int sig, sig_t f);
int sigaction(int sig, const struct sigaction* a, struct sigaction* old);
int sigemptyset(sigset_t* s);
int sigaddset(sigset_t* s, int n);
int sigprocmask(int how, const sigset_t* s, sigset_t* old);
int kill(int pid, int sig);
int raise(int sig);
#define SA_RESTART 2
#define SIG_BLOCK 1
#define SIG_UNBLOCK 2
#define SIGABRT 6
int sigwait(const sigset_t* set, int* sig);
#define SIGILL 4
#define SIGFPE 8
#define SIGBUS 10
#define SIGSEGV 11
