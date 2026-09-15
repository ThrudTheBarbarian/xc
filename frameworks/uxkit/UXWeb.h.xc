// UXWeb.h.xc — the web backend's host surface (doc/UXKit-WEB-BACKEND.md §0/§2).
//
// The Win32 driver's counterpart of UXWin32.h.xc: every call the wasm module makes
// OUT to the browser, declared once.  Plain externs land in the `env` import
// namespace, which the generated loader backs with globalThis.xccImports.env — the
// browser page supplies a Canvas2D shim, the Node test rig supplies a recording
// stub, and a missing function fails AT CALL TIME (the loader's env is a Proxy),
// so a partial shim runs everything it can — which is what lets the driver grow.
//
// Strings cross as addresses into linear memory; the JS side re-derives its
// Uint8Array view PER CALL — memory.grow detaches cached views, and the design
// doc calls that "the single most likely source of a baffling first bug" (§4).
//
// Colours cross as 8-bit r,g,b triplets: the pen→colour mapping is xtc-side
// (UXCanvasGraphics.penR/G/B), so the JS surface never needs the VDI pen table.

// ── boot / windows ──────────────────────────────────────────────────────────
// ux_boot fills the screen (page canvas) size.  A window is a JS-side handle —
// on the real page an OffscreenCanvas layer, in the Node rig a plain record.
extern i32 ux_boot(i32* w, i32* h);
extern i32 ux_win_create(i32 x, i32 y, i32 w, i32 h);
extern void ux_win_open(i32 h, i32 x, i32 y, i32 w, i32 hh);
extern void ux_win_destroy(i32 h);
extern void ux_win_set_title(i32 h, u8* s);
extern void ux_win_order_front(i32 h);
extern void ux_win_geometry(i32 h, i32* w, i32* hh);
// Commit the window's surface to the visible canvas (worker: OffscreenCanvas
// commit / transfer; Node rig: a counter).  Once per consolidated repaint.
extern void ux_present(i32 h);

// ── drawing (Canvas2D) ──────────────────────────────────────────────────────
// All drawing lands on the CURRENT target, selected once per paint pass —
// mirrors the one-HDC-in-flight model the GDI driver uses (gW32CurHdc).
extern void ux_gfx_target(i32 h);
extern void ux_clip(i32 x, i32 y, i32 w, i32 h);
extern void ux_clip_end(void);
extern void ux_fill_rect(i32 x, i32 y, i32 w, i32 h, i32 r, i32 g, i32 b);
extern void ux_fill_circle(i32 cx, i32 cy, i32 rad, i32 r, i32 g, i32 b);
extern void ux_draw_line(i32 x0, i32 y0, i32 x1, i32 y1, i32 r, i32 g, i32 b);
extern void ux_fill_poly(i16* xy, i32 n, i32 r, i32 g, i32 b);
// The UXSTROKE_* op run, walked JS-side into one Path2D + stroke() — Canvas2D
// strokes real cubics with joins/caps, so the web answers strokesNatively true.
extern void ux_stroke_ops(i32* ops, i32 n, i32 width, i32 cap, i32 r, i32 g, i32 b);
extern void ux_draw_text(u8* s, i32 x, i32 y, u8* family, i32 size, i32 bold, i32 italic,
                         i32 r, i32 g, i32 b);
// A themed 9-slice: `slice` names an ImageBitmap the page preloaded (Aristo
// assets).  The Node rig and a theme-less page fill a grey stand-in.
extern void ux_draw_theme(u8* slice, i32 x, i32 y, i32 w, i32 h);
// A 1px control border (the stand-in for Win32's DrawEdge on the fallback
// button/field/table boxes) — one import instead of four lines per box.
extern void ux_stroke_rect_edges(i32 x, i32 y, i32 w, i32 h);
// ctx.measureText — real shaped-width measurement, the thing UXTextLayout needs
// to agree with what drawTextFont later paints.
extern i32 ux_text_width(u8* s, u8* family, i32 size, i32 bold, i32 italic);

// ── time / zone ─────────────────────────────────────────────────────────────
// nowMs maps to the loader's own time_ms (already in the base env).
extern i32 time_ms(void);
extern void ux_now_utc(i32* out7);
extern i32 ux_tz_offmin(void);

// ── persistent settings (localStorage) ──────────────────────────────────────
extern i32 ux_setting_get(u8* domain, u8* key, u8* out, i32 cap);
extern i32 ux_setting_set(u8* domain, u8* key, u8* value);
extern i32 ux_setting_remove(u8* domain, u8* key);

// ── the run-loop seam (the loader's third role) ────────
// Provided by the generated loader ONLY in Worker mode (or by a test harness
// that owns a ring): 8-i32 events [type,a,b,...], type 1/2/3 mouse down/up/
// move (a=x, b=y, c=button), 4/5 key down/up (a=keyCode).  _xt_ring_wait
// blocks — the whole reason the module runs in a Worker (§3).
extern i32 _xt_ring_wait(i32 timeoutMs);
extern i32 _xt_ring_read(i32* ev8);
extern i32 _xt_req_block(i32 kind, i32 a, i32 b, i32 c);
