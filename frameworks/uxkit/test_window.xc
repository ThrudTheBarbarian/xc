// test_window.xc — the whole design, end to end, in one program.
//
// Boots GEM from xtc (now possible: libxtos.so exports the syscalls), opens a real
// AES window, and gives it a content tree containing BOTH:
//
//     a G_BUTTON   — GEM draws it, themed, and we write no drawing code at all
//     a G_USERDEF  — the AES calls back into OUR xtc drawRect
//
// Then it reads the framebuffer back and checks the pixels, so the whole chain is
// verified without needing a display:
//
//     appl_init -> wind_open -> wind_redraw_win -> the AES's content callback
//       -> objc_draw -> [G_BUTTON: theme]  and  [G_USERDEF: objc_set_userdraw
//       -> our trampoline -> UXView.drawRect -> VDI -> pixels]

#import <Stdio.xc>
#import <GEM>
#import <xtos>
#import "UXGem.xc"
#import "UXBoot.xc"

// libxtos.so is built without -g, so it carries no DWARF and xtc cannot type it.
// Mirror the two things we need by hand (see xtsys.h / usys.h).  Adding -g to the
// libxtos build would make this unnecessary — libGEM already does it.
// The struct is ours to mirror (a type, not a symbol).  The FUNCTIONS must come
// from #import <xtos> — hand-declaring them makes them plain externs bound to no
// library, so no DT_NEEDED is recorded and the loader cannot resolve them.
struct os_fbinfo
    {
    i32 w;
    i32 h;
    i32 stride;
    u32 addr;
    }

    // ---- libGEM / libc bits the DWARF import needs a name for --------------------
    i32 v_opnvwk(pointer surface);
void vdi_init(pointer surface);
void vdi_set_face(pointer face);
pointer font_face_open(u8* path);
i32 theme_load(pointer th, u8* dir);
// (no need to malloc a guessed size — the `theme` type comes in through DWARF)
void aes_init(i32 vh, pointer th);
i32 appl_init(void);
i32 aes_handle(void);
void wind_set_desktop(u32 rgba);
i32 wind_create(i32 kind, i32 x, i32 y, i32 w, i32 h);
void wind_open(i32 h, i32 x, i32 y, i32 w, i32 h2);
void wind_set_name(i32 h, u8* name);
void wind_content(i32 h, pointer fn, pointer ud);
void wind_redraw_win(i32 h);
void objc_draw(pointer tree, i32 start, i32 depth, i32 clx, i32 cly, i32 clw, i32 clh);
void objc_set_userdraw(pointer fn, pointer ud);
void vsf_color(i32 h, i32 pen);
void vsf_interior(i32 h, i32 style);
void vsf_perimeter(i32 h, i32 on);
void vr_recfl(i32 h, pointer pxy);
void v_get_pixel(i32 h, i32 x, i32 y, i32* pel, i32* index);
pointer malloc(u32 n);

#define W_NAME $0001
#define W_CLOSER $0002
#define W_MOVER $0008

// ---- our content tree --------------------------------------------------------
// 0: G_BOX root      1: G_BUTTON (GEM draws)   2: G_USERDEF (we draw)
OBJECT gTree[3];
theme gTheme; // ~18KB (256 slices) — DWARF gives us the real size
i32 gVH;
u16 gDrawCalls;
i32 gInkIndex; // the pen v_get_pixel found where drawRect painted (-1 = no match)

// The pixel our drawRect paints, so we can prove it ran.
#define INK_PEN 2 /* VDI pen 2 = red */

// ---- THE SEAM ----------------------------------------------------------------
// The AES invokes this for every G_USERDEF inside objc_draw.  This is drawRect.
i32 ux_userdraw(pointer tree, i32 obj, pointer ud)
    {
    gDrawCalls = gDrawCalls + (u16)1;

    OBJECT* t = (OBJECT*)tree;
    i32 ax = (i32)0;
    i32 ay = (i32)0;
    objc_offset(t, obj, &ax, &ay); // the AES gives us absolute coords

    i16 pxy[4];
    pxy[0] = (i16)ax;
    pxy[1] = (i16)ay;
    pxy[2] = (i16)(ax + (i32)t[obj].ob_w - (i32)1);
    pxy[3] = (i16)(ay + (i32)t[obj].ob_h - (i32)1);

    i32 h = aes_handle();
    vsf_color(h, (i32)INK_PEN);
    vsf_interior(h, (i32)1); // solid
    vsf_perimeter(h, (i32)0);
    vr_recfl(h, (pointer)&pxy[0]); // <- app code painting, called by the AES

    // READ IT BACK THE ONLY WAY A CLIENT CAN — through the workstation we just painted
    // with.  v_get_pixel reads that workstation's TARGET SURFACE, which under gemd is our
    // own shm backing store, not the screen.  We ask "is the pixel mine?", never "is the
    // pixel on the plane?" — the plane is gemd's, and we cannot see it.  (An earlier
    // version of this test peeked at the wallpaper buffer and, once we became a gemd
    // client, correctly found nothing there.)
    i32 pel = (i32)0;
    v_get_pixel(h, ax + (i32)8, ay + (i32)8, &pel, &gInkIndex);
    return (i32)0;
    }

// The window's content callback: hand our tree to the AES and let it walk.
void ux_window_draw(i32 handle, i32 wx, i32 wy, i32 ww, i32 wh, pointer ud)
    {
    // place the tree at the work area, then let objc_draw do everything
    gTree[0].ob_x = (i16)wx;
    gTree[0].ob_y = (i16)wy;
    objc_draw((pointer)&gTree[0], (i32)0, (i32)8, wx, wy, ww, wh);
    }

void main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    gDrawCalls = (u16)0;

    // ---- boot GEM, entirely from xtc ----------------------------------------
    os_fbinfo fb;
    os_fbinfo wp;
    if (sys_fb_info((pointer)&fb) != (i32)0)
        {
        Stdio.printf("no display plane\n");
        return;
        }
    if (sys_fb_wallpaper((pointer)&wp) != (i32)0)
        {
        Stdio.printf("no back buffer\n");
        return;
        }

    gfx_surface bb;
    bb.w = (i32)wp.w;
    bb.h = (i32)wp.h;
    bb.stride = (i32)wp.stride;
    bb.px = (u32*)wp.addr;

    pointer face = font_face_open("/System/fonts/AovelSansRounded.ttf");
    if (face == (pointer)0)
        {
        Stdio.printf("font load failed\n");
        return;
        }

    vdi_init((pointer)&bb);
    gVH = v_opnvwk((pointer)&bb);
    vdi_set_face(face);

    Stdio.printf("sizeof(theme) = %d bytes (via DWARF)\n", (i16)sizeof(theme));
    if (theme_load((pointer)&gTheme, "/System/themes/Aristo2/1x") != (i32)0)
        {
        Stdio.printf("theme load failed\n");
        return;
        }

    aes_init(gVH, (pointer)&gTheme);
    appl_init();
    wind_set_desktop($20304080);
    Stdio.printf("GEM booted from xtc: %dx%d, vdi handle %d\n",
                 (i16)fb.w, (i16)fb.h, (i16)gVH);

    // ---- the content tree ----------------------------------------------------
    gTree[0].ob_next = (i16)-1;
    gTree[0].ob_head = (i16)1;
    gTree[0].ob_tail = (i16)2;
    gTree[0].ob_type = (u16)G_BOX;
    gTree[0].ob_flags = (u16)0;
    gTree[0].ob_state = (u16)0;
    gTree[0].ob_spec = (pointer)$00021100;
    gTree[0].ob_x = (i16)0;
    gTree[0].ob_y = (i16)0;
    gTree[0].ob_w = (i16)(fb.w - (i32)20);
    gTree[0].ob_h = (i16)(fb.h - (i32)30);

    gTree[1].ob_next = (i16)2;
    gTree[1].ob_head = (i16)-1;
    gTree[1].ob_tail = (i16)-1;
    gTree[1].ob_type = (u16)G_BUTTON;
    gTree[1].ob_flags = (u16)OF_SELECTABLE;
    gTree[1].ob_state = (u16)0;
    gTree[1].ob_spec = (pointer) "OK";
    gTree[1].ob_x = (i16)(fb.w - (i32)90);
    gTree[1].ob_y = (i16)(fb.h - (i32)60);
    gTree[1].ob_w = (i16)60;
    gTree[1].ob_h = (i16)20;

    gTree[2].ob_next = (i16)0;
    gTree[2].ob_head = (i16)-1;
    gTree[2].ob_tail = (i16)-1;
    gTree[2].ob_type = (u16)G_USERDEF;
    gTree[2].ob_flags = (u16)OF_LASTOB;
    gTree[2].ob_state = (u16)0;
    gTree[2].ob_spec = (pointer)0;
    gTree[2].ob_x = (i16)8;
    gTree[2].ob_y = (i16)8;
    gTree[2].ob_w = (i16)60;
    gTree[2].ob_h = (i16)30;

    // ---- register the seam and open a real window ----------------------------
    objc_set_userdraw((pointer)&ux_userdraw, (pointer)0);

    i32 wx = (i32)4;
    i32 wy = (i32)4;
    i32 ww = fb.w - (i32)8;
    i32 wh = fb.h - (i32)8;
    i32 win = wind_create(W_NAME | W_CLOSER | W_MOVER, wx, wy, ww, wh);
    wind_set_name(win, "Xtg");
    wind_content(win, (pointer)&ux_window_draw, (pointer)0);
    wind_open(win, wx, wy, ww, wh);
    wind_redraw_win(win); // the new per-window damage path

    // ---- verify: did our drawRect actually paint, onto our own surface? ------
    Stdio.printf("userdraw invoked %d time(s)   (the AES called our xtc code)\n", (i16)gDrawCalls);

    i32 ax = (i32)0;
    i32 ay = (i32)0;
    objc_offset(&gTree[0], (i32)2, &ax, &ay);
    Stdio.printf("G_USERDEF is at %d,%d  (screen is %dx%d)\n",
                 (i16)ax, (i16)ay, (i16)fb.w, (i16)fb.h);
    Stdio.printf("pen at that pixel, read back through our workstation = %d (want %d)\n",
                 (i16)gInkIndex, (i16)INK_PEN);

    if (gDrawCalls > (u16)0 && gInkIndex == (i32)INK_PEN)
        {
        Stdio.printf("PASS: the AES called our xtc drawRect, and it painted pixels.\n");
        Stdio.printf("      The G_BUTTON next to it was drawn by GEM, themed, for free.\n");
        Stdio.printf("      The pixel was read back from OUR SURFACE — the screen is gemd's.\n");
        }
    else
        {
        Stdio.printf("FAIL: draws=%d pen=%d\n", (i16)gDrawCalls, (i16)gInkIndex);
        }
    }
