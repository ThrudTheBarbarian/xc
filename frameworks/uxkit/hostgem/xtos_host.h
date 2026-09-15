// xtos_host.h — a HOST (macOS/POSIX) replacement for XTOS's usys.h.
//
// The GEM window server (gem/gemd/*.c) and the client half (gem/gemclient.c) are portable C that
// reach the kernel only through the sys_* wrappers in usys.h — which on the board are `svc #1`
// traps.  This header re-declares that exact surface as ORDINARY FUNCTIONS, implemented over POSIX
// in xtos_host.c: the BSD-shaped service/poll calls become Unix-domain sockets, the shared-memory
// surfaces become POSIX shm, and the display plane + input device are backed by a plain RGBA buffer
// and an event queue (so a "screen grab" is a memcpy and an "input event" is an inject — SDL is an
// optional display on top).  Compile gemd/gemclient with -I this directory so it shadows usys.h.
#ifndef XTOS_HOST_H
#define XTOS_HOST_H
#include <stdint.h>
#include <stddef.h>

// ---- frozen-ABI structs + constants (mirror loader/kernel/xtsys.h) --------------------------
struct os_fbinfo
    {
    int w, h, stride;
    unsigned long addr;
    };
struct os_event
    {
    int type, mx, my, button, key, shift, wheel;
    };
enum
    {
    OS_EV_NONE = 0,
    OS_EV_BTN_DOWN = 1,
    OS_EV_BTN_UP = 2,
    OS_EV_KEY = 3,
    OS_EV_MOTION = 5,
    OS_EV_TIMER = 6,
    OS_EV_WHEEL = 7
    };
struct xt_pollfd
    {
    int fd;
    short events;
    short revents;
    };

#define XT_POLLIN 0x0001
#define XT_POLLOUT 0x0004
#define XT_POLLERR 0x0008
#define XT_POLLHUP 0x0010
#define XT_POLLNVAL 0x0020

#define XT_SHM_CONTIG (1u << 0)
#define XT_SHM_OWNED (1u << 1)
#define XT_SHM_SUPPORTED (XT_SHM_CONTIG | XT_SHM_OWNED)

// The hardware blit engine: unused on the host (/dev/blitter returns -1 -> software present), but
// gemd names these types, so they must exist to compile.
struct xt_blit_cmd
    {
    uint16_t op, flags;
    int32_t dst_id, src_id;
    uint16_t dx, dy, dw, dh, sx, sy, sw, sh;
    uint32_t color;
    };
struct xt_blit_surf
    {
    int32_t id;
    uint32_t stride;
    };
#define XT_BLIT_COPY 2
#define XT_BLIT_SURF_PLANE (-2)
#define XT_BLIT_SURF_WALLPAPER (-3)
#define XT_BLIT_DECLARE 0xB100
#define XT_BLIT_SEQ 0xB101
#define XT_BLIT_WAIT 0xB103

// gemd reaches for gettimeofday through the raw trap; give it a host __syscall that handles it.
#define SYS_gettimeofday 0x400
long __syscall(long n, long a0, long a1, long a2);

// ---- the syscall surface, as host functions -------------------------------------------------
#ifdef __cplusplus
extern "C"
    {
#endif

    // services + channels (Unix-domain sockets under $TMPDIR/xtos-gem/)
    int sys_svc_register(const char* name); // -> listen fd
    int sys_svc_connect(const char* name);  // -> channel fd
    int sys_svc_accept(int lfd);            // -> channel fd (blocks)
    int sys_chan_peer(int fd);              // peer pid, or -1

    // plain fd I/O + poll (POSIX read/write/close/poll)
    long sys_read(int fd, void* buf, unsigned len);
    long sys_write(int fd, const void* buf, unsigned len);
    long sys_close(int fd);
    int sys_poll(struct xt_pollfd* fds, int nfds, int timeout_ms);
    long sys_open(const char* path, int flags); // "/OS/dev/input" + "/dev/blitter" are special
    long sys_ioctl(int fd, unsigned req, void* argp);

    // shared memory (POSIX shm; id encodes creator pid + a counter, so it is globally resolvable)
    int sys_shm_create(unsigned size, unsigned flags);
    void* sys_shm_map(int id);
    long sys_shm_unmap(int id);
    long sys_shm_grant(int id, int pid); // capability model is unenforced on the trusted host

    // display plane (a host-owned RGBA buffer) + input (an injected event queue)
    long sys_fb_info(struct os_fbinfo* fi);
    long sys_fb_present(void);
    long sys_fb_wallpaper(struct os_fbinfo* fi);
    long sys_plane_window(int plane, int x, int y, int w, int h, int scale, int en);
    long sys_cursor_shape(int n);

    // misc
    long sys_klog(const void* buf, unsigned len);
    void xtos_host_fb_lock(void); // held across a present and across the SDL upload (tear-free)
    void xtos_host_fb_unlock(void);
    long sys_nanosleep(unsigned usec);
    long sys_spawn(const char* path, int argc, char** argv);
    void sys_exit(int code);
    long sys_xtos_recv(void* msg8); // OS system messages: none on the host -> 0

    // ---- host-only hooks (NOT part of the XTOS surface) -----------------------------------------
    // The harness sets the display buffer + drains it on present, and injects input events.
    void xtos_host_set_display(int w, int h, uint32_t* pixels); // the framebuffer gemd composites into
    typedef void (*xtos_present_fn)(void);                      // called on sys_fb_present (SDL upload)
    void xtos_host_on_present(xtos_present_fn fn);
    void xtos_host_inject(const struct os_event* ev); // push one input event to /OS/dev/input
    uint32_t* xtos_host_pixels(int* w, int* h);       // the framebuffer, for a screen grab

    // Compact-signature evnt_multi wrapper for the arm64 XG client (works around the xtc >8-arg ABI bug).
    // out[0..5] = mx,my,mb,ks,key,nc.  See xtos_host.c for the rationale.
    int xg_evnt_multi(int flags, void* mepbuf, int timeout_ms, int* out);
    int xg_drag_next(int* x, int* y); // one modal drag-track step: 1 = dragging (x,y set), 0 = released

#ifdef __cplusplus
    }
#endif
#endif
