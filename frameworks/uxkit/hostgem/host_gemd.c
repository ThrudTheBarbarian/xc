// host_gemd.c — the host harness for gemd.  Milestone 1: run the portable window server on macOS
// against the POSIX shim, headless, and confirm it composites a desktop into the framebuffer buffer
// (a "screen grab" = reading that buffer).  SDL display comes in milestone 4.
#include "xtos_host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

extern int gemd_run(void);

static void* gemd_thread(void* a)
    {
    (void)a;
    gemd_run();
    return NULL;
    }

// Milestone 3 — event injection.  gemd reads /OS/dev/input (the shim's self-pipe); xtos_host_inject
// pushes an os_event into it from this process, so a synthetic click enters the SAME poll loop a real
// mouse would.  We wait for the client to report its button's screen centre (a "cx cy" line in
// click_file, bridged from the client's CLICK_TARGET stdout), then inject motion + press + release
// there.  gemd routes it to the client; UXKit hit-tests and fires the action.
static void inject_click(int x, int y, int shift)
    {
    struct os_event mv = {.type = OS_EV_MOTION, .mx = x, .my = y, .shift = shift};
    struct os_event dn = {.type = OS_EV_BTN_DOWN, .mx = x, .my = y, .button = 1, .shift = shift};
    struct os_event up = {.type = OS_EV_BTN_UP, .mx = x, .my = y, .button = 1, .shift = shift};
    xtos_host_inject(&mv);
    usleep(20 * 1000);
    xtos_host_inject(&dn);
    usleep(60 * 1000); // a real click: down, brief hold, up
    xtos_host_inject(&up);
    }
static void inject_at(int x, int y)
    {
    inject_click(x, y, 0);
    }

static void inject_key(int key, int shift)
    {
    struct os_event k = {.type = OS_EV_KEY, .key = key, .shift = shift};
    xtos_host_inject(&k);
    }

// Press at (x1,y1), sweep to (x2,y2) in steps, release — a click-drag (e.g. table drag-select).
static void inject_drag(int x1, int y1, int x2, int y2)
    {
    struct os_event mv = {.type = OS_EV_MOTION, .mx = x1, .my = y1};
    xtos_host_inject(&mv);
    usleep(20 * 1000);
    struct os_event dn = {.type = OS_EV_BTN_DOWN, .mx = x1, .my = y1, .button = 1};
    xtos_host_inject(&dn);
    usleep(40 * 1000);
    for (int i = 1; i <= 8; i++)
        {
        struct os_event m = {.type = OS_EV_MOTION, .mx = x1 + (x2 - x1) * i / 8, .my = y1 + (y2 - y1) * i / 8, .button = 1};
        xtos_host_inject(&m);
        usleep(30 * 1000);
        }
    struct os_event up = {.type = OS_EV_BTN_UP, .mx = x2, .my = y2};
    xtos_host_inject(&up);
    }

// A mouse-wheel notch AT a screen point — gemd scrolls the window under (mx,my), so the point must
// land over the target window's work area (route.c: wind_handle_wheel(mx,my,wheel)).
static void inject_wheel(int x, int y, int notches)
    {
    struct os_event mv = {.type = OS_EV_MOTION, .mx = x, .my = y};
    struct os_event w = {.type = OS_EV_WHEEL, .mx = x, .my = y, .wheel = notches};
    xtos_host_inject(&mv);
    usleep(20 * 1000);
    xtos_host_inject(&w);
    }

extern void wind_work_origin(int hd, int* x, int* y);                    // gemd's on-screen work-area origin (libGEM)
extern int aes_top_reserve(void);                                        // menu-strip height — real on the server side
extern void wind_get(int hd, int field, int* a, int* b, int* c, int* d); // WF_CURRXYWH etc.
#define WF_CURRXYWH_ 4

// Drag the sizer grip (bottom-right corner) by (dw,dh): press on the grip, step motions to the new
// corner (gemd's modal resize loop consumes them), release.  Proves the resize path end to end.
static void inject_resize(int hd, int dw, int dh)
    {
    int x = 0, y = 0, w = 0, h = 0;
    wind_get(hd, WF_CURRXYWH_, &x, &y, &w, &h); // full window rect
    int gx = x + w - 4, gy = y + h - 4;         // the grip
    struct os_event mv = {.type = OS_EV_MOTION, .mx = gx, .my = gy};
    xtos_host_inject(&mv);
    usleep(20 * 1000);
    struct os_event dn = {.type = OS_EV_BTN_DOWN, .mx = gx, .my = gy, .button = 1};
    xtos_host_inject(&dn);
    usleep(40 * 1000);
    // step to the new corner in 8 motions
    for (int i = 1; i <= 8; i++)
        {
        struct os_event m = {.type = OS_EV_MOTION, .mx = gx + dw * i / 8, .my = gy + dh * i / 8, .button = 1};
        xtos_host_inject(&m);
        usleep(25 * 1000);
        }
    struct os_event up = {.type = OS_EV_BTN_UP, .mx = gx + dw, .my = gy + dh};
    xtos_host_inject(&up);
    }

// AES_MENUBAR_H
static int bar_height(void)
    {
    int b = aes_top_reserve();
    return b > 0 ? b : 22;
    }

// Play a client-authored injection script — a generic way to drive a multi-step interaction test
// headlessly.  The client (which knows its own widget coordinates) writes local coords + steps; the
// harness converts local->screen with gemd's wind_work_origin and injects, so the same "gemd owns
// placement" rule as await_click_target holds.  Grammar, one step per line:
//   CLICK  <handle> <local_x> <local_y>  a full press+release at a widget (window-local coords)
//   SCLICK <x> <y>                       a full press+release at ABSOLUTE screen coords (menus: the
//                                        top strip + the dropdown popup are not in any work area)
//   MTITLE <title_x>                     click a menu-bar title in the top strip (opens its dropdown)
//   MITEM  <title_x> <yoff>              click <yoff> px below the strip — into the just-opened dropdown
//                                        (the client owns the strip height; the SERVER here does, so
//                                        the harness resolves the y from its own aes_top_reserve)
//   WHEEL  <handle> <local_x> <local_y> <notches>   a wheel scroll over a window (+notches = down);
//                                        gemd scrolls the window under the point, so it's window-local
//   KEY    <ascii> <shift>               a keystroke (shift = GEM Kbshift bits)
//   DELAY  <ms>                          wait, so the client processes + repaints between steps
// Returns 1 if the script was found and played, 0 if it never appeared within timeout_ms.
static int play_script(const char* path, int timeout_ms)
    {
    FILE* f = NULL;
    for (int waited = 0; waited < timeout_ms && !(f = fopen(path, "r")); waited += 100)
        usleep(100 * 1000);
    if (!f)
        return 0;
    usleep(300 * 1000); // let the client reach its event loop
    char line[128];
    while (fgets(line, sizeof line, f))
        {
        int a, b, c, d, e;
        if (sscanf(line, "CLICK %d %d %d", &a, &b, &c) == 3)
            {
            int ox = 0, oy = 0;
            wind_work_origin(a, &ox, &oy);
            printf("script: CLICK win %d local %d,%d -> screen %d,%d\n", a, b, c, ox + b, oy + c);
            inject_at(ox + b, oy + c);
            }
        else if (sscanf(line, "MCLICK %d %d %d %d", &a, &b, &c, &d) == 4)
            {
            int ox = 0, oy = 0;
            wind_work_origin(a, &ox, &oy); // d = GEM Kbshift bits (0x03 shift, 0x04 ctrl)
            printf("script: MCLICK win %d local %d,%d shift %d\n", a, b, c, d);
            inject_click(ox + b, oy + c, d);
            }
        else if (sscanf(line, "SCLICK %d %d", &a, &b) == 2)
            {
            printf("script: SCLICK screen %d,%d\n", a, b);
            inject_at(a, b);
            }
        else if (sscanf(line, "MTITLE %d", &a) == 1)
            {
            int bh = bar_height();
            printf("script: MTITLE x=%d (barH %d) -> click %d,%d\n", a, bh, a + 8, bh / 2);
            inject_at(a + 8, bh / 2);
            }
        else if (sscanf(line, "MITEM %d %d", &a, &b) == 2)
            {
            int bh = bar_height();
            printf("script: MITEM x=%d yoff=%d -> click %d,%d\n", a, b, a + 12, bh + b);
            inject_at(a + 12, bh + b);
            }
        else if (sscanf(line, "DRAG %d %d %d %d %d", &a, &b, &c, &d, &e) == 5)
            {
            int ox = 0, oy = 0;
            wind_work_origin(a, &ox, &oy); // window-local press -> screen, drag to 2nd pt
            printf("script: DRAG win %d local %d,%d -> %d,%d\n", a, b, c, d, e);
            inject_drag(ox + b, oy + c, ox + d, oy + e);
            }
        else if (sscanf(line, "RESIZE %d %d %d", &a, &b, &c) == 3)
            {
            printf("script: RESIZE win %d by %d,%d\n", a, b, c);
            inject_resize(a, b, c);
            }
        else if (sscanf(line, "WHEEL %d %d %d %d", &a, &b, &c, &d) == 4)
            {
            int ox = 0, oy = 0;
            wind_work_origin(a, &ox, &oy); // d = notches (+ down)
            printf("script: WHEEL win %d local %d,%d -> screen %d,%d notches %d\n", a, b, c, ox + b, oy + c, d);
            inject_wheel(ox + b, oy + c, d);
            }
        else if (sscanf(line, "KEY %d %d", &a, &b) == 2)
            {
            printf("script: KEY %d shift %d\n", a, b);
            inject_key(a, b);
            }
        else if (sscanf(line, "DELAY %d", &a) == 1)
            {
            usleep((useconds_t)a * 1000);
            }
        usleep(120 * 1000); // a beat between every step
        }
    fclose(f);
    return 1;
    }

// Poll for the client's reported click target: "<handle> <local_x> <local_y>".  A client works in
// window-local coordinates (it never knows its screen placement — gemd owns it), so convert local
// ->screen here with gemd's own wind_work_origin, since gemd is what hit-tests the injected event.
// Returns 1 and fills *x,*y (screen) once the file has a full line; 0 if none appears within timeout.
static int await_click_target(const char* path, int* x, int* y, int timeout_ms)
    {
    for (int waited = 0; waited < timeout_ms; waited += 100)
        {
        FILE* f = fopen(path, "r");
        if (f)
            {
            int hd, lx, ly;
            int n = fscanf(f, "%d %d %d", &hd, &lx, &ly);
            fclose(f);
            if (n == 3)
                {
                int ox = 0, oy = 0;
                wind_work_origin(hd, &ox, &oy);
                *x = ox + lx;
                *y = oy + ly;
                return 1;
                }
            }
        usleep(100 * 1000);
        }
    return 0;
    }

static void dump_ppm(const char* path, uint32_t* px, int w, int h)
    {
    FILE* f = fopen(path, "wb");
    if (!f)
        return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (long i = 0; i < (long)w * h; i++)
        {
        uint32_t p = px[i]; // RGBA-8888 (0xRRGGBBAA)
        unsigned char rgb[3] = {(p >> 24) & 0xFF, (p >> 16) & 0xFF, (p >> 8) & 0xFF};
        fwrite(rgb, 1, 3, f);
        }
    fclose(f);
    }

int main(int argc, char** argv)
    {
    int W = 1280, H = 720;
    uint32_t* fb = calloc((size_t)W * H, 4);
    xtos_host_set_display(W, H, fb);

    // serve mode: run gemd as a SERVER for `secs` seconds (a client connects meanwhile), then dump
    // the framebuffer and exit.  Default: the headless first-frame composite check.
    int serve = argc > 1 && strcmp(argv[1], "serve") == 0;
    int events = argc > 1 && strcmp(argv[1], "events") == 0;
    int script = argc > 1 && strcmp(argv[1], "script") == 0;
    int secs = (serve || events || script) && argc > 2 ? atoi(argv[2]) : 1;

    pthread_t t;
    pthread_create(&t, NULL, gemd_thread, NULL);

    // script mode: play the client's multi-step injection script (table click, typing, menu, …),
    // then give it a moment to finish reacting + quit before dumping the frame and exiting.
    if (script)
        {
        if (!play_script("/tmp/hostgem_script.txt", 8000))
            printf("no script reported by the client\n");
        usleep((useconds_t)secs * 1000 * 1000);
        int w = 0, h = 0;
        uint32_t* px = xtos_host_pixels(&w, &h);
        dump_ppm("/tmp/hostgem_fb.ppm", px, w, h);
        return 0;
        }

    // events mode: gemd is up; wait for the client's button coordinates, inject a click there, then
    // give the client a moment to fire the action and quit before we dump the frame and exit.
    if (events)
        {
        int cx = 0, cy = 0;
        if (await_click_target("/tmp/hostgem_click.txt", &cx, &cy, 8000))
            {
            usleep(300 * 1000); // let the client reach evnt_multi
            printf("injecting click at %d,%d\n", cx, cy);
            inject_at(cx, cy);
            }
        else
            {
            printf("no click target reported by the client\n");
            }
        usleep((useconds_t)secs * 1000 * 1000); // let the action fire + client exit
        int w = 0, h = 0;
        uint32_t* px = xtos_host_pixels(&w, &h);
        dump_ppm("/tmp/hostgem_fb.ppm", px, w, h);
        return 0;
        }

    usleep((useconds_t)(serve ? secs : 1) * 1000 * 1000);

    int w = 0, h = 0;
    uint32_t* px = xtos_host_pixels(&w, &h);
    long nonzero = 0;
    for (long i = 0; i < (long)w * h; i++)
        if (px[i] & 0x00FFFFFFu)
            nonzero++;
    printf("host framebuffer %dx%d: %ld nonzero pixels (%.0f%%)\n", w, h, nonzero, 100.0 * nonzero / ((double)w * h));

    if (serve)
        {
        dump_ppm("/tmp/hostgem_fb.ppm", px, w, h);
        // did a client window land?  Compare a pixel inside the kitchen-sink's rect (opens at
        // 120,90,460x420 -> its grey backdrop) against a bare-desktop pixel far from it.
        uint32_t inWin = px[(90 + 200) * w + (120 + 200)]; // ~mid window
        uint32_t deskt = px[(H - 40) * w + (W - 40)];      // bottom-right desktop
        printf("pixel in-window=%08x desktop=%08x -> %s\n", inWin, deskt,
               inWin != deskt ? "a client window is composited" : "no window visible");
        return 0;
        }
    int ok = nonzero > (long)w * h / 4;
    printf("%s: gemd composited a desktop into the host framebuffer\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
    }
