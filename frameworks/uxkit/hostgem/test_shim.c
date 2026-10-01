// test_shim.c — milestone 0: the host syscall shim's IPC + shm rendezvous.
//
// Mirrors what gemd + a client actually do: a server registers the "gem" service; a client connects
// and sends a request; the server creates a shared surface, writes into it, grants + hands back the
// id; the client maps it and sees the same bytes.  If this passes, the transport the whole port
// rides on works on macOS.
#include "xtos_host.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <stdlib.h>

// xtos_host.c also carries the GEM-side wrappers (xg_evnt_multi, the font_face_open redirect), which
// call into the GEM tree.  This test is the transport alone and never reaches them, so those two GEM
// entry points are stubs here, loud if anything ever does call them.
int evnt_multi(int flags, int bclk, int bmask, int bstate, int m1f, int m1x, int m1y, int m1w, int m1h,
               int m2f, int m2x, int m2y, int m2w, int m2h, short* mep, int tlc, int thc,
               int* omx, int* omy, int* omb, int* oks, int* okey, int* onc)
    {
    fprintf(stderr, "test_shim: evnt_multi is not part of the transport test\n");
    abort();
    }
void* xg_ffo_real(const char* path)
    {
    fprintf(stderr, "test_shim: font_face_open is not part of the transport test\n");
    abort();
    }

int main(void)
    {
    int lfd = sys_svc_register("gemtest");
    if (lfd < 0)
        {
        printf("FAIL: sys_svc_register\n");
        return 1;
        }

    pid_t pid = fork();
    // ---- CLIENT ----
    if (pid == 0)
        {
        int cfd = sys_svc_connect("gemtest");
        if (cfd < 0)
            {
            printf("client FAIL: connect\n");
            _exit(2);
            }
        sys_write(cfd, "hello", 6);
        int id = -1;
        if (sys_read(cfd, &id, sizeof id) != sizeof id)
            {
            printf("client FAIL: read id\n");
            _exit(3);
            }
        uint32_t* p = (uint32_t*)sys_shm_map(id);
        int ok = p && p[0] == 0xDEADBEEFu && p[42] == 0xCAFEBABEu;
        printf("client: mapped surface id=%d -> [0]=%08x [42]=%08x %s\n",
               id, p ? p[0] : 0, p ? p[42] : 0, ok ? "OK" : "BAD");
        _exit(ok ? 0 : 4);
        }

    // ---- SERVER ----
    int cfd = sys_svc_accept(lfd);
    if (cfd < 0)
        {
        printf("FAIL: accept\n");
        return 1;
        }
    char buf[16] = {0};
    long n = sys_read(cfd, buf, sizeof buf);
    printf("server: peer pid=%d sent '%s' (%ld bytes)\n", sys_chan_peer(cfd), buf, n);

    int id = sys_shm_create(1024 * sizeof(uint32_t), XT_SHM_OWNED);
    uint32_t* p = (uint32_t*)sys_shm_map(id);
    if (!p)
        {
        printf("FAIL: server shm_map\n");
        return 1;
        }
    p[0] = 0xDEADBEEFu;
    p[42] = 0xCAFEBABEu;
    sys_shm_grant(id, sys_chan_peer(cfd));
    sys_write(cfd, &id, sizeof id);

    int st = 0;
    waitpid(pid, &st, 0);
    int ok = (n == 6) && strcmp(buf, "hello") == 0 && WIFEXITED(st) && WEXITSTATUS(st) == 0;
    printf("%s: host shim IPC + shm rendezvous\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
    }
