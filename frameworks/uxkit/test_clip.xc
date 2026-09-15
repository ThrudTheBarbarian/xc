// test_clip.xc — the two GEM additions that UXScrollView / UXTableView need:
//   1. OF_CLIPCHILDREN — a child is cut off at its parent's edge (no clipping -> no scrolling)
//   2. G_SCROLL / G_SLIDER — themed widgets, so UXScrollBar has NO drawing code
//
// Read back real pixels; no display needed.
#import <Stdio.xc>
#import <GEM>
#import <xtos>
#import "UXGem.xc"
#import "UXBoot.xc"

i32 v_opnvwk(pointer surface);
void vdi_init(pointer surface);
void vdi_set_face(pointer face);
pointer font_face_open(u8* path);
i32 theme_load(pointer th, u8* dir);
void aes_init(i32 vh, pointer th);
i32 appl_init(void);
i32 aes_handle(void);
void objc_draw(pointer tree, i32 start, i32 depth, i32 clx, i32 cly, i32 clw, i32 clh);
void vsf_color(i32 h, i32 pen);
void vsf_interior(i32 h, i32 style);
void vsf_perimeter(i32 h, i32 on);
void vr_recfl(i32 h, pointer pxy);
pointer malloc(u32 n);

struct os_fbinfo
    {
    i32 w;
    i32 h;
    i32 stride;
    u32 addr;
    }

#define OF_CLIPCHILDREN $1000
#define G_SCROLL 45
#define G_SLIDER 46

    OBJECT gTree[5];
SCROLLBAR gSb;
SCROLLBAR gSl;
theme gTheme;

void main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    os_fbinfo fb;
    if (sys_fb_info((pointer)&fb) != (i32)0)
        {
        Stdio.printf("no display\n");
        return;
        }
    // Draw into a buffer WE OWN, not the wallpaper. Since the M7 SEC_PLANE gate the plane
    // (WALLPAPER_BASE) is PL0-none for every process except gemd — a client writing it faults
    // (RESPONSIBILITIES rule 1: only gemd touches the plane). This is a pure VDI/AES drawing
    // test, so a plain PL0-RW heap surface is exactly right; it needs no gemd surface at all.
    gfx_surface bb;
    bb.w = (i32)fb.w;
    bb.h = (i32)fb.h;
    bb.stride = (i32)fb.stride;
    bb.px = (u32*)malloc((u32)((i32)fb.stride * (i32)fb.h * (i32)4));
    if (bb.px == (u32*)0)
        {
        Stdio.printf("no heap surface\n");
        return;
        }
    pointer face = font_face_open("/System/fonts/AovelSansRounded.ttf");
    vdi_init((pointer)&bb);
    i32 vh = v_opnvwk((pointer)&bb);
    vdi_set_face(face);
    if (theme_load((pointer)&gTheme, "/System/themes/Aristo2/1x") != (i32)0)
        {
        Stdio.printf("theme load failed\n");
        return;
        }
    aes_init(vh, (pointer)&gTheme);
    appl_init();
    i32 h = aes_handle();

    // Paint the test area RED.  Not white: VDI pen 0 IS white, and the scrollbar thumb
    // is near-white too, so a white background cannot tell "the widget drew" from "it
    // did not".  Red is in nothing we draw, so every check below is unambiguous.
    i16 bg[4];
    bg[0] = (i16)0;
    bg[1] = (i16)0;
    bg[2] = (i16)199;
    bg[3] = (i16)119;
    vsf_color(h, (i32)2);
    vsf_interior(h, (i32)1);
    vsf_perimeter(h, (i32)0);
    vr_recfl(h, (pointer)&bg[0]);

    Stdio.printf("screen is %dx%d — everything below must fit inside it\n", (i16)fb.w, (i16)fb.h);
    // 0: root box.  1: CLIPPING container (40x30 at 10,10).  2: a child that OVERFLOWS it.
    // 3: G_SCROLL.  4: G_SLIDER.
    gTree[0].ob_next = (i16)-1;
    gTree[0].ob_head = (i16)1;
    gTree[0].ob_tail = (i16)4;
    gTree[0].ob_type = (u16)G_IBOX;
    gTree[0].ob_flags = (u16)0;
    gTree[0].ob_state = (u16)0;
    gTree[0].ob_spec = (pointer)0;
    gTree[0].ob_x = (i16)0;
    gTree[0].ob_y = (i16)0;
    gTree[0].ob_w = (i16)200;
    gTree[0].ob_h = (i16)120;

    gTree[1].ob_next = (i16)3;
    gTree[1].ob_head = (i16)2;
    gTree[1].ob_tail = (i16)2;
    gTree[1].ob_type = (u16)G_IBOX;
    gTree[1].ob_flags = (u16)OF_CLIPCHILDREN;
    gTree[1].ob_state = (u16)0;
    gTree[1].ob_spec = (pointer)0;
    gTree[1].ob_x = (i16)10;
    gTree[1].ob_y = (i16)10;
    gTree[1].ob_w = (i16)40;
    gTree[1].ob_h = (i16)30;

    // child is 100 wide inside a 40-wide clipping parent -> must be cut at x=50
    gTree[2].ob_next = (i16)1;
    gTree[2].ob_head = (i16)-1;
    gTree[2].ob_tail = (i16)-1;
    gTree[2].ob_type = (u16)G_BOX;
    gTree[2].ob_flags = (u16)0;
    gTree[2].ob_state = (u16)0;
    gTree[2].ob_spec = (pointer)$00FF1100;
    gTree[2].ob_x = (i16)0;
    gTree[2].ob_y = (i16)0;
    gTree[2].ob_w = (i16)100;
    gTree[2].ob_h = (i16)20;

    gSb.vert = (i16)1;
    gSb.value = (i16)500;
    gSb.page = (i16)300;
    gSb.arrows = (i16)1;
    gTree[3].ob_next = (i16)4;
    gTree[3].ob_head = (i16)-1;
    gTree[3].ob_tail = (i16)-1;
    gTree[3].ob_type = (u16)G_SCROLL;
    gTree[3].ob_flags = (u16)0;
    gTree[3].ob_state = (u16)0;
    gTree[3].ob_spec = (pointer)&gSb;
    gTree[3].ob_x = (i16)70;
    gTree[3].ob_y = (i16)10;
    gTree[3].ob_w = (i16)16;
    gTree[3].ob_h = (i16)100;

    gSl.vert = (i16)0;
    gSl.value = (i16)500;
    gSl.page = (i16)0;
    gSl.arrows = (i16)0;
    gTree[4].ob_next = (i16)0;
    gTree[4].ob_head = (i16)-1;
    gTree[4].ob_tail = (i16)-1;
    gTree[4].ob_type = (u16)G_SLIDER;
    gTree[4].ob_flags = (u16)OF_LASTOB;
    gTree[4].ob_state = (u16)0;
    gTree[4].ob_spec = (pointer)&gSl;
    gTree[4].ob_x = (i16)100;
    gTree[4].ob_y = (i16)20;
    gTree[4].ob_w = (i16)90;
    gTree[4].ob_h = (i16)24;

    objc_draw((pointer)&gTree[0], (i32)0, (i32)8, (i32)0, (i32)0, (i32)200, (i32)120);

    // ---- 1. clipping: inside the container painted, outside NOT -------------
    u32 RED = bb.px[(i32)195 + (i32)115 * bb.stride];   // a corner nothing draws on
    u32 inside = bb.px[(i32)30 + (i32)20 * bb.stride];  // x=30: inside  the 10..50 container
    u32 outside = bb.px[(i32)60 + (i32)20 * bb.stride]; // x=60: OUTSIDE it, inside the CHILD
    bool clipped = (inside != RED) && (outside == RED); // child drew here, but NOT there
    Stdio.printf("clip:   bg=%lx inside=%lx outside=%lx -> %s\n", RED, inside, outside,
                 clipped ? "PASS (child cut at the parent edge)" : "FAIL");

    // ---- 2. the themed widgets drew ----------------------------------------
    // scan the whole G_SCROLL rect: did ANYTHING draw there?
    i32 hits = (i32)0;
    for (i32 yy = (i32)10; yy < (i32)110; yy++)
        {
        for (i32 xx = (i32)70; xx < (i32)86; xx++)
            {
            if (bb.px[xx + yy * bb.stride] != (u32)$FF0000FF)
                {
                hits = hits + (i32)1;
                }
            }
        }
    Stdio.printf("G_SCROLL rect: %d of 1600 px non-background\n", hits);
    i32 hits2 = (i32)0;
    for (i32 yy = (i32)20; yy < (i32)44; yy++)
        {
        for (i32 xx = (i32)100; xx < (i32)190; xx++)
            {
            if (bb.px[xx + yy * bb.stride] != (u32)$FF0000FF)
                {
                hits2 = hits2 + (i32)1;
                }
            }
        }
    Stdio.printf("G_SLIDER rect: %d of 2160 px non-background (a slider must NOT fill its box)\n", hits2);
    for (u16 i = (u16)0; i < (u16)5; i++)
        {
        Stdio.printf("  obj %d: type=%d flags=%x next=%d head=%d tail=%d  %d,%d %dx%d\n",
                     (i16)i, (i16)gTree[i].ob_type, (u32)gTree[i].ob_flags,
                     gTree[i].ob_next, gTree[i].ob_head, gTree[i].ob_tail,
                     gTree[i].ob_x, gTree[i].ob_y, gTree[i].ob_w, gTree[i].ob_h);
        }
    Stdio.printf("  sb.vert=%d value=%d page=%d arrows=%d  sizeof(SCROLLBAR)=%d\n",
                 gSb.vert, gSb.value, gSb.page, gSb.arrows, (i16)sizeof(SCROLLBAR));
    u32 scr = bb.px[(i32)78 + (i32)60 * bb.stride];  // mid-thumb of the scrollbar
    u32 sld = bb.px[(i32)134 + (i32)31 * bb.stride]; // the slider KNOB (value=500)
    bool drew = (scr != RED) && (sld != RED);
    Stdio.printf("widget: G_SCROLL=%lx  G_SLIDER=%lx -> %s\n", scr, sld,
                 drew ? "PASS (themed, zero drawing code in Xtg)" : "FAIL");

    if (clipped && drew)
        {
        Stdio.printf("PASS: OF_CLIPCHILDREN + G_SCROLL + G_SLIDER\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
