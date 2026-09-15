#include "_fake_typedefs.h"
int wait(int* status);
int waitpid(int pid, int* status, int opts);
#define WNOHANG 1
#define WIFEXITED(s) (((s) & 0x7f) == 0)
#define WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define WIFSIGNALED(s) ((((s) & 0x7f) + 1) >> 1 > 0)
#define WTERMSIG(s) ((s) & 0x7f)
