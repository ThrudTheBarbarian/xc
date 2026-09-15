// UXGem.h.xc — every libGEM / libxtos entry point Xtg calls, in one place.
//
// These are hand-declared only where the DWARF import needs a name to bind to;
// the TYPES (OBJECT, theme, gfx_surface, os_fbinfo) all come through #import
// verbatim, which is what makes this safe — see spikes/RESULTS.md, where a
// hand-guessed sizeof(theme) would have smashed the heap (it is 19502 bytes).

#import <GEM>
#import <xtos>

// ---- boot -------------------------------------------------------------------
i32 v_opnvwk(pointer surface);
void vdi_init(pointer surface);
void vdi_set_face(pointer face);
pointer font_face_open(u8* path);
i32 theme_load(pointer th, u8* dir);
i32 xg_now_ms(void); // ms since a fixed point (gemclient.c) — the toolkit's clock
void xg_now_utc(i32* out7);
i32 xg_local_offset_minutes(void);          // host UTC offset, DST applied (0 on the board)                  // wall clock, UTC civil components (gemclient.c)
i32 xg_listdir(u8* path, u8* out, i32 cap); // portable dir listing (gemclient.c) for the file panel
// Persistent settings, in the system SQLite registry (gem/xg_settings.c -> registry.c's `settings`
// table).  domain 0/"" = the shared domain; 1 = done/found, 0 = no value / no writable registry.
i32 xg_setting_get(u8* domain, u8* key, u8* out, i32 cap);
i32 xg_setting_set(u8* domain, u8* key, u8* value);
i32 xg_setting_remove(u8* domain, u8* key);
i32 xg_unlink(u8* path);
i32 xg_rename(u8* a, u8* b);
i32 xg_copyfile(u8* a, u8* b);
void aes_init(i32 vh, pointer th);
i32 appl_init(void);
i32 aes_handle(void);

// ---- windows ----------------------------------------------------------------
void wind_set_desktop(u32 rgba);
i32 wind_create(i32 kind, i32 x, i32 y, i32 w, i32 h);
void wind_open(i32 h, i32 x, i32 y, i32 w, i32 h2);
void wind_close(i32 h);  // gemd drops the window + its surface (§11)
void wind_delete(i32 h); // ...and frees the client-side handle slot
void wind_set(i32 h, i32 field, i32 a, i32 b, i32 c, i32 d);
void wind_set_name(i32 h, u8* name); // DEPRECATED — sugar over wind_set(WF_NAME)

#define WF_NAME 2
#define WF_INFO 3
#define WF_TOP 10
#define WF_SUBTITLE 32
#define WF_ICON 33
#define WF_TITLEFLAGS 34
#define WF_TITLEBTNS 35
#define WT_MODIFIED $01
void wind_content(i32 h, pointer fn, pointer ud);
void wind_redraw_win(i32 h);
void wind_redraw_area(i32 x, i32 y, i32 w, i32 h); // repaint a screen rect across ALL windows
// One rect, ONE window, in the content callback's own space (a client's = its surface, window-local).
void wind_redraw_rect(i32 hd, i32 x, i32 y, i32 w, i32 h);
i32 wind_find(i32 x, i32 y);
void wind_get(i32 h, i32 what, pointer a, pointer b, pointer c, pointer d);

// ---- text editing -------------------------------------------------------------
// GEM's edit engine, explicitly meant for "a bare evnt_multi client that hosts editable
// objects itself" — which is exactly Xtg.  It does insert / Backspace / Del / arrows /
// Ctrl-U, moves and draws the caret, redraws the field, and validates per character
// (te_pvalid).  UXTextField writes NONE of that.
i32 objc_edit(pointer tree, i32 obj, i32 key, pointer idx, i32 kind);
void objc_edit_set_nodraw(i32 on); // Xtg owns repaint: skip the AES's internal edit-redraw

#define ED_START 0
#define ED_INIT 1 /* focus the field + show the caret (idx = pos, -1 = end) */
#define ED_CHAR 2 /* process one key; returns 1 if consumed */
#define ED_END 3  /* drop focus */

// ---- objects ----------------------------------------------------------------
void objc_draw(pointer tree, i32 start, i32 depth, i32 clx, i32 cly, i32 clw, i32 clh);
void objc_set_userdraw(pointer fn, pointer ud);
void objc_change(pointer tree, i32 obj, i32 state, i32 redraw);
void objc_offset(pointer tree, i32 obj, i32* ax, i32* ay);       // absolute coords of obj
i32 objc_find(pointer tree, i32 start, i32 depth, i32 x, i32 y); // deepest hit, or -1

// ---- menus --------------------------------------------------------------------
// GEM builds the tree, draws the bar, tracks the pull-down, and intercepts the click
// INSIDE evnt_multi — the app just receives MN_SELECTED.  UXMenu writes none of that.
pointer menu_build(pointer menus, i32 nmenus, i32 screen_w); // -> OBJECT* (malloc'd)
void menu_bar(pointer tree, i32 show);
void menu_icheck(pointer tree, i32 title_ord, i32 item_ord, i32 on);
void menu_ienable(pointer tree, i32 title_ord, i32 item_ord, i32 on);
i32 menu_item_ord(pointer tree, i32 title_ord, i32 item_obj);

// ---- alerts / modality --------------------------------------------------------
// form_alert builds, centres, runs and tears down the whole dialog.  UXAlert's job is
// to describe it: "[icon][line|line][button|button]".
i32 form_alert(i32 default_button, u8* alert);

// The AES's input source is PLUGGABLE.  This is the seam gemd relies on (a client
// reads the server's channel instead of sys_input) — and it is what lets a test drive
// a MODAL dialog headlessly, which is otherwise impossible.
void aes_set_events(pointer fn); // int (*)(aes_event *ev, int timeout_ms)

#define AES_NONE 0
#define AES_BTN_DOWN 1
#define AES_BTN_UP 2
#define AES_KEY 3
#define AES_QUIT 4
#define AES_TIMER 6

// ---- events -----------------------------------------------------------------
i32 evnt_multi(i32 flags, i32 bclk, i32 bmask, i32 bstate,
               i32 m1f, i32 m1x, i32 m1y, i32 m1w, i32 m1h,
               i32 m2f, i32 m2x, i32 m2y, i32 m2w, i32 m2h,
               pointer mepbuf, i32 tlc, i32 thc,
               pointer mx, pointer my, pointer mbut, pointer kstate,
               pointer key, pointer nclk);
#ifdef ARCH_arm64
// Host-only compact wrapper (libxtos): xtc's arm64 backend mis-passes arguments past the 8th, so the
// 23-arg evnt_multi above returns garbage output pointers on macOS.  This 4-arg form (all in
// registers) makes the real call C-side.  out6 = i32[6] -> mx,my,mb,ks,key,nc.i32     xg_evnt_multi(i32 flags, pointer mepbuf, i32 timeoutMs, pointer out6);
i32 xg_drag_next(i32* x, i32* y); // one modal drag-track step: 1 = dragging (x,y set), 0 = released
#endif

i32 aes_event_win(void);   // WHICH of our windows the last input event was for (gemd tags it)
i32 aes_top_reserve(void); // height of the menu-bar strip gemd reserves at the top of the screen

// ---- drawing ----------------------------------------------------------------
void theme_draw(i32 handle, pointer th, u8* name, i32 dx, i32 dy, i32 dw, i32 dh);
void vsf_color(i32 h, i32 pen);
void vsf_interior(i32 h, i32 style);
void vsf_perimeter(i32 h, i32 on);
void vr_recfl(i32 h, pointer pxy);
void vst_color(i32 h, i32 pen);
void vst_height(i32 h, i32 pts, pointer a, pointer b, pointer c, pointer d);
void v_gtext(i32 h, i32 x, i32 y, u8* s);
// Text extent: fills a 8-int16 array — [0],[1] .. [6],[7] are the four corners of the string's box,
// so the width is x2-x0 and the height y2-y0.  What UXTextLayout measures a candidate line with.
void vqt_extent(i32 h, u8* s, pointer extent);
// The AES's modal popup menu (aes/menu.c): a flat row array drawn as a themed panel at a SCREEN
// point, tracked with hover + save-under, returning the chosen row's id (-1 = cancelled).  It backs the
// desktop's context menus and its dialogs' G_POPUP combos (xtdesk.c: objc_offset then menu_popup), and
// UXKit drives it from a popup button, whose items become the rows.  SCREEN coordinates: a window-local
// point needs WF_CURRXYWH + wind_calc(WC_WORK) first — see UXGemDriver.runPopupMenu.
// Layout matches the C `menu_item` exactly (label*0 accel*8 id*16 sub*24 nsub*32 flags*36, size 40).
struct menu_item
    {
    pointer label;
    pointer accel;
    i32 id;
    i32 _pad;
    pointer sub;
    i32 nsub;
    u32 flags;
    } i32 menu_popup(pointer items, i32 n, i32 x, i32 y);
// The font registry: vst_load_fonts maps the font dir (id 1 = system, 2..N = the files, sorted by name),
// vst_font selects a face by id, vdi_font_name reports a face's name, vst_effects synthesises bold/italic.
i32 vst_font(i32 h, i32 id);
i32 vst_effects(i32 h, i32 effects);
i32 vst_load_fonts(i32 h, i32 select);
u8* vdi_font_name(i32 id);
void vdi_set_font_dir(u8* path);
void v_circle(i32 h, i32 x, i32 y, i32 radius);
void v_pline(i32 h, i32 n, pointer pxy);
void vsl_color(i32 h, i32 pen);
void vsl_width(i32 h, i32 w);
void v_setrgb(i32 h, i32 index, i32 r, i32 g, i32 b); // set a pen straight from 8-bit RGB (true colour)

// ---- event classes / messages ------------------------------------------------
#define MU_KEYBD $01
#define MU_BUTTON $02
#define MU_M1 $04
#define MU_MESAG $10
#define MU_TIMER $20
#define MU_QUIT $40

#define WM_REDRAW 20
#define WM_TOPPED 21
#define WM_CLOSED 22
#define WM_SIZED 27
#define WM_MOVED 28
#define WM_WHEEL 33 // a wheel with no window bar, forwarded to the client (m[4]=x m[5]=y m[6]=notches)
#define MN_SELECTED 10

i32 wind_calc(i32 type, i32 kind, i32 x, i32 y, i32 w, i32 h, pointer px, pointer py, pointer pw, pointer ph);
// Direction constants MUST match gemd's aes.h (enum { WC_BORDER=0, WC_WORK=1 }) — they were
// swapped here, so windowCreate asked to grow work->full but gemd shrank full->work, and every
// window came out chrome-worth too small (the Corner button + status line fell off the bottom).
#define WC_BORDER 0 // work area -> full window rect (so the content gets the size asked for)
#define WC_WORK 1   // full window rect -> work area
#define W_NAME $0001
#define W_CLOSER $0002
#define W_FULLER $0004
#define W_MOVER $0008
#define W_SIZER $0020

#define WF_WORKXYWH 4
#define WF_CURRXYWH 5 // the window's FULL rect in SCREEN coords (a client tracks this one)
