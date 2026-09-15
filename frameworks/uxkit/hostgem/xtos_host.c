// xtos_host.c — POSIX/macOS implementation of the XTOS syscall surface (see xtos_host.h).
#include "xtos_host.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <spawn.h>

// ---- service sockets: $TMPDIR/xtos-gem/<name>.sock -------------------------------------------
static void svc_path(const char* name, char* out, size_t n)
    {
    const char* tmp = getenv("TMPDIR");
    if (!tmp || !*tmp)
        tmp = "/tmp";
    // one dir per user session so two runs don't collide; created lazily
    char dir[512];
    snprintf(dir, sizeof dir, "%sxtos-gem-%d", tmp, (int)getuid());
    mkdir(dir, 0700);
    snprintf(out, n, "%s/%s.sock", dir, name);
    }

int sys_svc_register(const char* name)
    {
    char path[600];
    svc_path(name, path, sizeof path);
    unlink(path); // a stale socket from a dead server
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    if (bind(fd, (struct sockaddr*)&a, sizeof a) < 0)
        {
        close(fd);
        return -1;
        }
    if (listen(fd, 16) < 0)
        {
        close(fd);
        return -1;
        }
    return fd;
    }
int sys_svc_connect(const char* name)
    {
    char path[600];
    svc_path(name, path, sizeof path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr*)&a, sizeof a) < 0)
        {
        close(fd);
        return -1;
        }
    return fd;
    }
int sys_svc_accept(int lfd)
    {
    return accept(lfd, NULL, NULL);
    }

int sys_chan_peer(int fd)
    {
#ifdef LOCAL_PEERPID
    pid_t pid = 0;
    socklen_t len = sizeof pid;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0)
        return (int)pid;
#endif
    return -1;
    }

// ---- plain fd I/O + poll --------------------------------------------------------------------
long sys_read(int fd, void* buf, unsigned len)
    {
    return read(fd, buf, len);
    }
long sys_write(int fd, const void* buf, unsigned len)
    {
    return write(fd, buf, len);
    }
long sys_close(int fd)
    {
    return close(fd);
    }
long sys_ioctl(int fd, unsigned req, void* argp)
    {
    (void)fd;
    (void)req;
    (void)argp;
    return -1;
    }

int sys_poll(struct xt_pollfd* fds, int nfds, int timeout_ms)
    {
    struct pollfd pf[64];
    if (nfds > 64)
        nfds = 64;
    for (int i = 0; i < nfds; i++)
        {
        pf[i].fd = fds[i].fd;
        pf[i].events = 0;
        pf[i].revents = 0;
        if (fds[i].events & XT_POLLIN)
            pf[i].events |= POLLIN;
        if (fds[i].events & XT_POLLOUT)
            pf[i].events |= POLLOUT;
        }
    int r = poll(pf, nfds, timeout_ms);
    for (int i = 0; i < nfds; i++)
        {
        short rv = 0;
        if (pf[i].revents & POLLIN)
            rv |= XT_POLLIN;
        if (pf[i].revents & POLLOUT)
            rv |= XT_POLLOUT;
        if (pf[i].revents & POLLERR)
            rv |= XT_POLLERR;
        if (pf[i].revents & POLLHUP)
            rv |= XT_POLLHUP;
        if (pf[i].revents & POLLNVAL)
            rv |= XT_POLLNVAL;
        fds[i].revents = rv;
        }
    return r;
    }

// ---- shared memory: id = (pid<<16)|counter, name derived from id ----------------------------
struct shm_map
    {
    int id;
    void* ptr;
    size_t size;
    };
static struct shm_map g_maps[256];
static int g_shm_counter = 0;
static void shm_name(int id, char* out, size_t n)
    {
    snprintf(out, n, "/xg-shm-%d", id);
    }

int sys_shm_create(unsigned size, unsigned flags)
    {
    (void)flags;
    // A positive, i32-safe, globally-unique id: 15 bits of pid + 16-bit per-process counter (a macOS
    // pid can exceed 15 bits, so (pid<<16) overflowed int).  The NAME is derived from the id, so any
    // process that is handed the id resolves the same segment.
    int id = (((int)getpid() & 0x7FFF) << 16) | (++g_shm_counter & 0xFFFF);
    char nm[64];
    shm_name(id, nm, sizeof nm);
    shm_unlink(nm);
    int fd = shm_open(nm, O_CREAT | O_RDWR, 0600);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, size) < 0)
        {
        close(fd);
        shm_unlink(nm);
        return -1;
        }
    close(fd); // the name persists until shm_unlink
    if (getenv("UX_SHM_DEBUG"))
        fprintf(stderr, "[shm] create id=%d size=%u\n", id, size);
    return id;
    }
void* sys_shm_map(int id)
    {
    char nm[64];
    shm_name(id, nm, sizeof nm);
    int fd = shm_open(nm, O_RDWR, 0600);
    if (getenv("UX_SHM_DEBUG"))
        fprintf(stderr, "[shm] map id=%d -> %s\n", id, fd < 0 ? "FAIL" : "ok");
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) < 0)
        {
        close(fd);
        return NULL;
        }
    void* p = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED)
        return NULL;
    for (int i = 0; i < 256; i++)
        if (!g_maps[i].ptr)
            {
            g_maps[i].id = id;
            g_maps[i].ptr = p;
            g_maps[i].size = st.st_size;
            break;
            }
    return p;
    }
long sys_shm_unmap(int id)
    {
    for (int i = 0; i < 256; i++)
        if (g_maps[i].ptr && g_maps[i].id == id)
            {
            munmap(g_maps[i].ptr, g_maps[i].size);
            g_maps[i].ptr = NULL;
            return 0;
            }
    return -1;
    }
// name-based access on host
long sys_shm_grant(int id, int pid)
    {
    (void)id;
    (void)pid;
    return 0;
    }

// ---- display plane (host buffer) + input (injected queue) -----------------------------------
static int g_fb_w = 0, g_fb_h = 0;
static uint32_t* g_fb = NULL;
static xtos_present_fn g_present = NULL;
static int g_input_r = -1, g_input_w = -1; // the /OS/dev/input self-pipe

void xtos_host_set_display(int w, int h, uint32_t* pixels)
    {
    g_fb_w = w;
    g_fb_h = h;
    g_fb = pixels;
    }

// gemd presents (copies finished rects into the framebuffer) on its own thread while SDL uploads
// that same framebuffer on the main thread.  Sampling a present halfway leaves a horizontal seam —
// the rows above copied, the rows below not.  One lock, held for the copy and for the upload.
static pthread_mutex_t g_fb_mtx = PTHREAD_MUTEX_INITIALIZER;
void xtos_host_fb_lock(void)
    {
    pthread_mutex_lock(&g_fb_mtx);
    }
void xtos_host_fb_unlock(void)
    {
    pthread_mutex_unlock(&g_fb_mtx);
    }
void xtos_host_on_present(xtos_present_fn fn)
    {
    g_present = fn;
    }
uint32_t* xtos_host_pixels(int* w, int* h)
    {
    if (w)
        *w = g_fb_w;
    if (h)
        *h = g_fb_h;
    return g_fb;
    }

void xtos_host_inject(const struct os_event* ev)
    {
    if (g_input_w >= 0)
        {
        ssize_t r = write(g_input_w, ev, sizeof *ev);
        (void)r;
        }
    }

// xg_evnt_multi — a compact-signature wrapper around GEM's 23-argument evnt_multi, for the arm64
// host UXKit client.  xtc's arm64 backend currently mis-marshals arguments past the 8th (they go to a
// private 16-byte-slot buffer, not the AAPCS outgoing-stack area), so a
// 23-arg call from xtc to this C function reads garbage for every arg after the 8th.  This wrapper
// takes 4 args (all in registers, which xtc passes correctly) and makes the real 23-arg call itself
// — a C→C call, so the C compiler's correct AAPCS marshaling applies.  out[0..5] = mx,my,mb,ks,key,nc.
// UXKit always calls evnt_multi with bclk/bmask/bstate = 1 and every mouse-rect = 0, so those are fixed
// here.  Board (arm9) UXKit keeps the direct call; this exists only in the host libxtos.
extern int evnt_multi(int flags, int bclk, int bmask, int bstate,
                      int m1f, int m1x, int m1y, int m1w, int m1h,
                      int m2f, int m2x, int m2y, int m2w, int m2h,
                      short* mep, int tlc, int thc,
                      int* omx, int* omy, int* omb, int* oks, int* okey, int* onc);

int xg_evnt_multi(int flags, void* mepbuf, int timeout_ms, int* out)
    {
    int mx = 0, my = 0, mb = 0, ks = 0, key = 0, nc = 0;
    int r = evnt_multi(flags, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       (short*)mepbuf, timeout_ms & 0xFFFF, (timeout_ms >> 16) & 0xFFFF,
                       &mx, &my, &mb, &ks, &key, &nc);
    out[0] = mx;
    out[1] = my;
    out[2] = mb;
    out[3] = ks;
    out[4] = key;
    out[5] = nc;
    return r;
    }

// One step of a modal drag-track (for a table's drag-to-select): block until the pointer MOVES or the
// button is RELEASED.  MU_M1 with a zero-size rect + m1f=1 fires on any motion; MU_BUTTON with bstate=0
// fires on release.  Fills window-local x,y; returns 1 while still dragging, 0 once released.
// (0x02=MU_BUTTON, 0x04=MU_M1 — aes.h.)  Host-only, like xg_evnt_multi (the board calls evnt_multi direct).
int xg_drag_next(int* x, int* y)
    {
    int mx = 0, my = 0, mb = 0, ks = 0, key = 0, nc = 0;
    int r = evnt_multi(0x02 | 0x04, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       NULL, 0, 0, &mx, &my, &mb, &ks, &key, &nc);
    if (x)
        *x = mx;
    if (y)
        *y = my;
    return (r & 0x02) ? 0 : 1; // MU_BUTTON -> released; else a motion -> keep dragging
    }

long sys_fb_info(struct os_fbinfo* fi)
    {
    if (g_fb)
        {
        fi->w = g_fb_w;
        fi->h = g_fb_h;
        fi->stride = g_fb_w;
        fi->addr = (unsigned long)g_fb;
        return 0;
        }
    fi->w = 1280;
    fi->h = 720;
    fi->stride = 1280;
    fi->addr = 0; // a client only needs the geometry
    return 0;
    }
long sys_fb_present(void)
    {
    if (g_present)
        g_present();
    return 0;
    }
// The wallpaper/back-buffer.  Both halves get one (they are separate processes, so this static is
// per-process): an UXKit CLIENT needs it for its VDI so UXGemDriver.boot succeeds, and GEMD needs it to
// composite OFF-SCREEN.  gemd used to draw direct to the plane here, which is the plane SDL uploads
// from another thread every vsync — so a drag, which erases and recomposites the old-union-new rect
// per motion, could be sampled mid-composite: background painted, dragged window not yet, and the
// window underneath "showing through".  With a back-buffer gemd composites there and gemd_present
// copies finished rects over, which is the board's model (render cached, present uncached).
long sys_fb_wallpaper(struct os_fbinfo* fi)
    {
    static uint32_t* wp = NULL;
    if (!wp)
        wp = calloc((size_t)1280 * 720, 4);
    if (!wp)
        return -1;
    fi->w = 1280;
    fi->h = 720;
    fi->stride = 1280;
    fi->addr = (unsigned long)wp;
    return 0;
    }

// Font + theme live at XTOS paths (/System/fonts, /System/themes, /OS/fonts) that don't exist on the
// host — and /System is SIP-protected, so no symlink.  Rewrite them to the repo's gem/ assets.  Both
// gemd and the UXKit client reach fonts/themes through font_face_open + theme.c's fopen, so redirecting
// here (via the build's -Dfopen=xg_fopen and the font_face_open wrapper below) fixes both.
const char* xg_redirect_path(const char* p)
    {
    if (!p)
        return p;
    const char* gem = getenv("UX_GEM_DIR");
    static char buf[1024];
    const char* sub = NULL;
    if (strncmp(p, "/System/fonts", 13) == 0)
        sub = p + 13;
    else if (strncmp(p, "/OS/fonts", 9) == 0)
        sub = p + 9;
    else if (strncmp(p, "/System/themes", 14) == 0)
        {
        snprintf(buf, sizeof buf, "%s/themes%s", gem ? gem : ".", p + 14);
        return buf;
        }
    else
        return p;
    snprintf(buf, sizeof buf, "%s/fonts%s", gem ? gem : ".", sub && *sub ? sub : "");
    return buf;
    }
FILE* xg_fopen(const char* path, const char* mode)
    {
    return fopen(xg_redirect_path(path), mode);
    }
// vst_load_fonts scans the font dir with opendir(); redirect it too (load_fonts.c is built with
// -Dopendir=xg_opendir) so "/OS/fonts" reaches the repo's gem/fonts, like fopen/font_face_open above.
#include <dirent.h>
DIR* xg_opendir(const char* path)
    {
    return opendir(xg_redirect_path(path));
    }
// The real font_face_open is compiled as xg_ffo_real (see build_gemd.sh); wrap it to redirect.
extern void* xg_ffo_real(const char* path);
void* font_face_open(const char* path)
    {
    return xg_ffo_real(xg_redirect_path(path));
    }
long sys_plane_window(int plane, int x, int y, int w, int h, int scale, int en)
    {
    (void)plane;
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)scale;
    (void)en;
    return 0;
    }
long sys_cursor_shape(int n)
    {
    (void)n;
    return 0;
    }

long sys_open(const char* path, int flags)
    {
    (void)flags;
    if (path && strcmp(path, "/OS/dev/input") == 0)
        {
        if (g_input_r < 0)
            {
            int fd[2];
            if (pipe(fd) == 0)
                {
                g_input_r = fd[0];
                g_input_w = fd[1];
                fcntl(g_input_r, F_SETFL, O_NONBLOCK);
                }
            }
        return g_input_r;
        }
    if (path && strcmp(path, "/dev/blitter") == 0)
        return -1; // no engine -> software present
    return open(path, flags);
    }

// ---- misc -----------------------------------------------------------------------------------
// The one raw trap gemd still issues: gettimeofday.  Everything else goes through a sys_* wrapper.
#include <sys/time.h>
long __syscall(long n, long a0, long a1, long a2)
    {
    (void)a1;
    (void)a2;
    if (n == SYS_gettimeofday)
        {
        return gettimeofday((struct timeval*)a0, NULL);
        }
    return -1;
    }
long sys_klog(const void* buf, unsigned len)
    {
    fwrite(buf, 1, len, stderr);
    return len;
    }
long sys_nanosleep(unsigned usec)
    {
    usleep(usec);
    return 0;
    }
long sys_spawn(const char* path, int argc, char** argv)
    {
    (void)argc;
    pid_t pid;
    extern char** environ;
    if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0)
        return -1;
    return (long)pid;
    }
void sys_exit(int code)
    {
    exit(code);
    }
// no OS system-message stream on host
long sys_xtos_recv(void* msg8)
    {
    (void)msg8;
    return 0;
    }
