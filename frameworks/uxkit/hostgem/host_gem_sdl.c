// host_gem_sdl.c — milestone 4: the host gemd behind a live SDL window.
//
// Same gemd-over-the-shim server as host_gemd, but instead of a headless framebuffer dump this opens
// an SDL window, uploads the framebuffer to a texture every frame, and feeds real mouse/keyboard as
// injected os_events — the exact path M3 drove synthetically.  gemd runs on a background thread; SDL
// owns the main thread (required on macOS).  An UXKit client (kitchen-sink) connects as a separate
// process, exactly as in run_client.sh; here you can actually click it.
#include "xtos_host.h"
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

extern int gemd_run(void);
static void* gemd_thread(void* a)
    {
    (void)a;
    gemd_run();
    return NULL;
    }

// SDL delivers window-local coordinates; the SDL window is the same 1280x720 as the framebuffer, so
// those ARE screen coordinates in gemd's space (no scaling, no offset) — gemd hit-tests them directly.
static void inject(int type, int x, int y, int button, int key, int shift, int wheel)
    {
    struct os_event e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.mx = x;
    e.my = y;
    e.button = button;
    e.key = key;
    e.shift = shift;
    e.wheel = wheel;
    xtos_host_inject(&e);
    }

// GEM shift/ctrl bits (aes.h Kbshift): SHIFT = bit0|bit1, CTRL = bit2.
static int gem_shift(SDL_Keymod m)
    {
    int s = 0;
    if (m & KMOD_SHIFT)
        s |= 0x03;
    if (m & KMOD_CTRL)
        s |= 0x04;
    return s;
    }

// A best-effort SDL keysym -> GEM key (low byte = ASCII; the AES edit engine reads the ASCII byte).
// Printable ASCII passes through; the common editing keys map to their control codes.  Fuller
// scancode mapping (arrows, function keys) can follow if a client needs it.
static int gem_key(SDL_Keycode k)
    {
    switch (k)
        {
    case SDLK_RETURN:
    case SDLK_KP_ENTER:
        return 13;
    case SDLK_BACKSPACE:
        return 8;
    case SDLK_TAB:
        return 9;
    case SDLK_ESCAPE:
        return 27;
    default:
        return (k >= 32 && k < 127) ? (int)k : 0;
        }
    }

int main(int argc, char** argv)
    {
    (void)argc;
    (void)argv;
    int W = 1280, H = 720;
    uint32_t* fb = calloc((size_t)W * H, 4);
    xtos_host_set_display(W, H, fb);

    // macOS turns Ctrl+left-click into a right-click by default; the toolkit uses Ctrl-click to toggle
    // a table row into a multi-selection, so keep it a real left-click-with-Ctrl (the board has no such
    // emulation, so this only matters for the SDL host).
    SDL_SetHint(SDL_HINT_MAC_CTRL_CLICK_EMULATE_RIGHT_CLICK, "0");
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
        }
    // No ALLOW_HIGHDPI: keep the drawable 1:1 with the framebuffer so SDL mouse coords == gemd screen
    // coords.  RenderCopy still scales the texture to the window if the OS gives us a HiDPI backing.
    SDL_Window* win = SDL_CreateWindow("UXKit on host GEM",
                                       SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, W, H, 0);
    if (!win)
        {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        return 1;
        }
    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren)
        ren = SDL_CreateRenderer(win, -1, 0);
    SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
                                         SDL_TEXTUREACCESS_STREAMING, W, H);

    pthread_t t;
    pthread_create(&t, NULL, gemd_thread, NULL);

    int running = 1;
    int mouse_x = 0, mouse_y = 0; // last pointer position, for wheel events (which carry none)
    while (running)
        {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            {
            switch (e.type)
                {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_MOUSEMOTION:
                mouse_x = e.motion.x;
                mouse_y = e.motion.y;                        // remember where the pointer is —
                inject(OS_EV_MOTION, e.motion.x, e.motion.y, // the wheel scrolls the window UNDER it
                       (e.motion.state & SDL_BUTTON_LMASK) ? 1 : 0, 0,
                       gem_shift(SDL_GetModState()), 0);
                break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                if (e.button.button == SDL_BUTTON_LEFT)
                    inject(e.type == SDL_MOUSEBUTTONDOWN ? OS_EV_BTN_DOWN : OS_EV_BTN_UP,
                           e.button.x, e.button.y, 1, 0, gem_shift(SDL_GetModState()), 0);
                break;
            case SDL_MOUSEWHEEL:
                // gemd scrolls the window under (mx,my) — SDL wheel events carry no position, so
                // use the last motion's.  (Injecting at 0,0 scrolled nothing: it hit the desktop.)
                inject(OS_EV_WHEEL, mouse_x, mouse_y, 0, 0, gem_shift(SDL_GetModState()), e.wheel.y);
                break;
            case SDL_KEYDOWN:
                {
                int k = gem_key(e.key.keysym.sym);
                if (k)
                    inject(OS_EV_KEY, 0, 0, 0, k, gem_shift(e.key.keysym.mod), 0);
                break;
                }
                }
            }
        int w = 0, h = 0;
        uint32_t* px = xtos_host_pixels(&w, &h);
        xtos_host_fb_lock(); // no present may land mid-upload (see xtos_host.c)
        SDL_UpdateTexture(tex, NULL, px, w * (int)sizeof(uint32_t));
        xtos_host_fb_unlock();
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren); // vsync paces the loop; no busy spin
        }

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
    }
