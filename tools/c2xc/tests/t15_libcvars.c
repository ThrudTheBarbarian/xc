/* libc's variables: stderr, errno, getopt's optarg and optind -- reached through
   the run-time, since an extern variable is a private copy in xcc 0.5 */
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char** argv)
    {
    fprintf(stderr, "to stderr %d\n", 7);
    fputs("to stdout\n", stdout);
    FILE* f = fopen("/nonexistent/x", "r");
    printf("open %s errno %d %s\n", f ? "ok" : "failed", errno, errno == ENOENT ? "ENOENT" : "other");
    char* av[] = {"prog", "-a", "-b", "val", "-c", "rest", NULL};
    int c, na = 0;
    char* bv = NULL;
    while ((c = getopt(6, av, "ab:c")) != -1)
        {
        if (c == 'a')
            na++;
        else if (c == 'b')
            bv = optarg;
        else if (c == 'c')
            na += 10;
        }
    printf("a=%d b=%s c optind=%d rest=%s\n", na, bv, optind, av[optind]);
    return 0;
    }
