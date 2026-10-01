// ux_web_node.js — the Node rig for the web driver: a recording canvas stub.
//
// The design doc's "headless here means node with a canvas/DOM shim" (§5).
// Loaded with `node --require`, so globalThis.xccImports exists before the
// generated loader instantiates the module.  Every draw import records an op
// against the current target window; ux_test_pixel replays the recorded fills
// (last-writer-wins, clip applied at record time) — the web analogue of the
// AppKit rig's cacheDisplayInRect bitmap readback.  The browser page shim
// (canvas2d, later) implements this same surface over real contexts.
//
// Memory views are re-derived PER CALL: memory.grow detaches them (§4), and a
// cached Uint8Array here is exactly the baffling first bug the doc predicts.
'use strict';

const wins = new Map();
let nextH = 1;
let target = 0;
let clip = null;                       // {x,y,w,h} or null
const clipStack = [];                  // the clips under the current one
const settings = new Map();

const U8  = () => new Uint8Array(globalThis.xcc.memory.buffer);
const I32 = () => new Int32Array(globalThis.xcc.memory.buffer);
const I16 = () => new Int16Array(globalThis.xcc.memory.buffer);
const cstr = (p) => {
  const m = U8(); let e = p >>> 0;
  while (m[e]) e++;
  return Buffer.from(m.subarray(p >>> 0, e)).toString('latin1');
};
const wi32 = (p, v) => { I32()[(p >>> 0) >> 2] = v; };

const clipRect = (x, y, w, h) => {
  if (!clip) return { x, y, w, h };
  const x0 = Math.max(x, clip.x), y0 = Math.max(y, clip.y);
  const x1 = Math.min(x + w, clip.x + clip.w), y1 = Math.min(y + h, clip.y + clip.h);
  if (x1 <= x0 || y1 <= y0) return null;
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
};
const rec = (op) => { const w = wins.get(target); if (w) w.ops.push(clip && clip.rounds ? { ...op, rounds: clip.rounds } : op); };
// Is (px, py) -- a pixel centre -- inside every rounded clip an op was recorded under?
const inRounds = (o, px, py) => (o.rounds || []).every(({ x, y, w, h, r }) => {
  const cx = Math.min(Math.max(px, x + r), x + w - r), cy = Math.min(Math.max(py, y + r), y + h - r);
  return (px - cx) ** 2 + (py - cy) ** 2 <= r * r;
});

globalThis.xccImports = { env: {
  // ── boot / windows ──
  ux_boot: (pw, ph) => { wi32(pw, 640); wi32(ph, 400); return 1; },
  // A GL entry point as the web delivers it: a host import (see UXWeb.h.xc).  The
  // rig has one so the delivery path is exercised; a page shim has the real set.
  ux_host_add: (a, b) => (a + b) | 0,
  ux_win_create: (x, y, w, h) => {
    const hh = nextH++;
    wins.set(hh, { x, y, w, h, open: 0, title: '', ops: [], presents: 0 });
    return hh;
  },
  ux_win_open:    (h, x, y, w, hh) => { const s = wins.get(h); if (s) { s.x = x; s.y = y; s.w = w; s.h = hh; s.open = 1; } },
  ux_win_destroy: (h) => { wins.delete(h); },
  ux_win_set_title: (h, sp) => { const s = wins.get(h); if (s) s.title = cstr(sp); },
  ux_win_order_front: (h) => {},
  ux_win_geometry: (h, pw, ph) => { const s = wins.get(h); wi32(pw, s ? s.w : 0); wi32(ph, s ? s.h : 0); },
  ux_present: (h) => { const s = wins.get(h); if (s) s.presents++; },

  // ── text measurement ──
  // The rig has no font: widths are the same 0.6-per-character estimate its drawn text uses, so a
  // layout that wraps under the rig wraps the same way twice.
  ux_text_width: (sp, famp, size, bold, italic) => Math.round(cstr(sp).length * 0.6 * (size > 0 ? size : 13)),
  ux_text_width_weight: (sp, famp, size, weight, italic) => Math.round(cstr(sp).length * 0.6 * (size > 0 ? size : 13)),
  ux_text_ascent: (famp, size, weight, italic) => Math.round(0.8 * (size > 0 ? size : 13)),

  // ── GL (WebGL2) ──
  // The rig has no GPU: it RECORDS the surface calls the way it records fills.
  // A page shim implements the same surface over a real WebGL2 context.  The
  // viewport is the canvas pixel size, which here is the window size.
  ux_gl_create: (h, node, x, y, w, hh) => {
    const s = wins.get(h);
    if (s) s.gl = { node, x, y, w, h: hh, created: 1, current: 0, vp: null, presents: 0 };
  },
  ux_gl_make_current: (h, node) => {
    const s = wins.get(h);
    if (!s || !s.gl || s.gl.node !== node) return 0;
    s.gl.current = 1;
    return 1;
  },
  ux_gl_viewport: (h, node) => {
    const s = wins.get(h);
    if (!s || !s.gl || s.gl.node !== node) return;
    s.gl.vp = [0, 0, s.gl.w, s.gl.h];
  },
  ux_gl_present: (h, node) => {
    const s = wins.get(h);
    if (s && s.gl && s.gl.node === node) s.gl.presents++;
  },

  // ── drawing ──
  ux_gfx_target: (h) => { target = h; },
  // A STACK, as the page's save/clip/restore is: a view's clip nested inside a clipping subtree
  // intersects with it, and ending the inner one restores the outer.
  ux_clip:     (x, y, w, h) => {
    clipStack.push(clip);
    if (clip) {
      const x1 = Math.max(x, clip.x), y1 = Math.max(y, clip.y);
      const x2 = Math.min(x + w, clip.x + clip.w), y2 = Math.min(y + h, clip.y + clip.h);
      clip = { x: x1, y: y1, w: Math.max(0, x2 - x1), h: Math.max(0, y2 - y1), rounds: clip.rounds };
    } else clip = { x, y, w, h };
  },
  ux_clip_end: () => { clip = clipStack.length ? clipStack.pop() : null; },
  // A rounded clip: its rectangle clips as ux_clip does, and the rounded shape rides on the clip so
  // every op recorded under it carries it -- ux_test_pixel then drops a point outside a corner, the
  // way the page's roundRect clip would.
  ux_clip_round: (x, y, w, h, r) => {
    globalThis.xccImports.env.ux_clip(x, y, w, h);
    const rr = Math.max(0, Math.min(r, w / 2, h / 2));
    if (rr > 0) clip = { ...clip, rounds: [...(clip.rounds || []), { x, y, w, h, r: rr }] };
  },
  ux_fill_rect: (x, y, w, h, r, g, b, a) => {
    const c = clipRect(x, y, w, h);
    if (c) rec({ op: 'fill', ...c, rgb: (r << 16) | (g << 8) | b, a });
  },
  // A clear: the rect carries nothing afterwards, so the replay drops whatever was painted there and
  // leaves the backdrop showing.  Recorded as its own op so ux_test_pixel can honour it in order.
  ux_clear_rect: (x, y, w, h) => {
    const c = clipRect(x, y, w, h);
    if (c) rec({ op: 'clear', ...c });
  },
  // drawPixels: recorded with a COPY of the source region (the memory may move on), and replayed by
  // ux_test_pixel with nearest sampling and the alpha applied -- enough to read the picture back.
  ux_draw_pixels: (p, w, h, fmt, sx, sy, sw, sh, dx, dy, dw, dh, a) => {
    if (w <= 0 || h <= 0 || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || a <= 0) return;
    const m = U8(); const px = new Uint8Array(sw * sh * 4);
    for (let y = 0; y < sh; y++)
      for (let x = 0; x < sw; x++) {
        const s = (p >>> 0) + (((sy + y) * w + (sx + x)) * 4), d = (y * sw + x) * 4;
        if (fmt === 1) { px[d] = m[s + 2]; px[d + 1] = m[s + 1]; px[d + 2] = m[s]; px[d + 3] = m[s + 3]; }
        else { px[d] = m[s]; px[d + 1] = m[s + 1]; px[d + 2] = m[s + 2]; px[d + 3] = m[s + 3]; }
      }
    const c = clipRect(dx, dy, dw, dh);
    if (c) rec({ op: 'pixels', ...c, dx, dy, dw, dh, sw, sh, px, a });
  },
  ux_fill_circle: (cx, cy, rad, r, g, b) => {
    const c = clipRect(cx - rad, cy - rad, rad * 2, rad * 2);
    if (c) rec({ op: 'fill', ...c, rgb: (r << 16) | (g << 8) | b, a: 255 });   // box stand-in, like GDI's
  },
  ux_draw_line: (x0, y0, x1, y1, r, g, b) => { rec({ op: 'line', x0, y0, x1, y1 }); },
  ux_fill_poly: (xyp, n, r, g, b, a) => {
    // Record the polygon's bounding box as a fill — enough for pixel replay.
    const m = I16(); const base = (xyp >>> 0) >> 1;
    let x0 = 32767, y0 = 32767, x1 = -32768, y1 = -32768;
    for (let i = 0; i < n; i++) {
      const x = m[base + i * 2], y = m[base + i * 2 + 1];
      if (x < x0) x0 = x; if (x > x1) x1 = x;
      if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
    const c = clipRect(x0, y0, x1 - x0, y1 - y0);
    if (c) rec({ op: 'fill', ...c, rgb: (r << 16) | (g << 8) | b, a });
  },
  // Canvas2D strokes real cubics; the rig only counts them, so alpha, join and the dash run are
  // carried through to the record rather than drawn — a test can then ask what the seam actually
  // handed over, which is the part that is ours.
  ux_stroke_ops: (ops, n, width, cap, join, dashp, ndash, phase, r, g, b, a) => {
    const dm = I32(); const dbase = (dashp >>> 0) >> 2;
    const pat = [];
    for (let k = 0; k < ndash && k < 8; k++) pat.push(dm[dbase + k]);
    rec({ op: 'stroke', n, width, join, ndash, phase, pat, a });
  },
  ux_draw_text: (sp, x, y, fam, size, bold, italic, r, g, b, a) => {
    rec({ op: 'text', x, y, s: cstr(sp), a });
  },
  ux_draw_text_weight: (sp, x, y, fam, size, weight, italic, r, g, b, a) => {
    rec({ op: 'text', x, y, s: cstr(sp), weight, a });
  },
  ux_draw_theme: (slicep, x, y, w, h) => {
    const c = clipRect(x, y, w, h);
    if (c) rec({ op: 'fill', ...c, rgb: 0xC0C0C0, a: 255, theme: cstr(slicep) });
  },
  ux_stroke_rect_edges: (x, y, w, h) => { rec({ op: 'edges', x, y, w, h }); },
  ux_text_width: (sp, fam, size, bold, italic) => cstr(sp).length * 7,

  // ── time / zone ──
  ux_now_utc: (p7) => {
    const d = new Date();
    const v = [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(),
               d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(),
               d.getUTCMilliseconds() * 1000];
    for (let i = 0; i < 7; i++) wi32((p7 >>> 0) + i * 4, v[i]);
  },
  ux_tz_offmin: () => -new Date().getTimezoneOffset(),

  // ── settings ──
  ux_setting_get: (dp, kp, out, cap) => {
    const v = settings.get(cstr(dp) + ' ' + cstr(kp));
    if (v === undefined) return 0;
    const m = U8(); let i = 0;
    for (; i < v.length && i < cap - 1; i++) m[(out >>> 0) + i] = v.charCodeAt(i) & 0xFF;
    m[(out >>> 0) + i] = 0;
    return 1;
  },
  ux_setting_set:    (dp, kp, vp) => { settings.set(cstr(dp) + ' ' + cstr(kp), cstr(vp)); return 1; },
  ux_setting_remove: (dp, kp) => { settings.delete(cstr(dp) + ' ' + cstr(kp)); return 1; },

  // ── the run-loop seam, degenerate (no worker, no ring): a blocking request
  // answers its default synchronously, so headless tests keep old behaviour ──
  _xt_req_block: (kind, a, b, c) => c & 0xff,

  // ── test introspection (the rig's own surface, not the driver's) ──
  // Replays the recorded fills in order, source-over, over an opaque white backdrop (what
  // gfx_target lays down for a non-GL window).  An opaque fill (a == 255) replaces the pixel
  // exactly; a translucent one blends, which is what a real Canvas2D would do.
  ux_test_pixel: (h, x, y) => {
    const s = wins.get(h);
    if (!s) return -1;
    let r = 255, g = 255, b = 255, painted = false;
    for (const o of s.ops)
      if ((o.op === 'fill' || o.op === 'clear' || o.op === 'pixels') && x >= o.x && x < o.x + o.w && y >= o.y && y < o.y + o.h
          && inRounds(o, x + 0.5, y + 0.5)) {
        if (o.op === 'clear') { r = 255; g = 255; b = 255; painted = false; continue; }
        if (o.op === 'pixels') {
          const u = Math.min(o.sw - 1, Math.floor((x - o.dx) * o.sw / o.dw));
          const v = Math.min(o.sh - 1, Math.floor((y - o.dy) * o.sh / o.dh));
          const k = (v * o.sw + u) * 4, pa = o.px[k + 3] * o.a / 255;
          r = (o.px[k] * pa + r * (255 - pa)) / 255;
          g = (o.px[k + 1] * pa + g * (255 - pa)) / 255;
          b = (o.px[k + 2] * pa + b * (255 - pa)) / 255;
          painted = true;
          continue;
        }
        const a = o.a === undefined ? 255 : o.a;
        const sr = (o.rgb >> 16) & 255, sg = (o.rgb >> 8) & 255, sb = o.rgb & 255;
        r = (sr * a + r * (255 - a)) / 255;
        g = (sg * a + g * (255 - a)) / 255;
        b = (sb * a + b * (255 - a)) / 255;
        painted = true;
      }
    if (!painted) return -1;
    return ((Math.round(r) & 255) << 16) | ((Math.round(g) & 255) << 8) | (Math.round(b) & 255);
  },
  ux_test_op_count: (h, namep) => {
    const s = wins.get(h);
    if (!s) return 0;
    const name = cstr(namep);
    return s.ops.filter((o) => o.op === name).length;
  },
  ux_test_presents: (h) => { const s = wins.get(h); return s ? s.presents : 0; },
  ux_test_gl_state: (h, out4) => {
    const s = wins.get(h);
    if (!s || !s.gl) { wi32(out4, 0); wi32((out4 >>> 0) + 4, 0); wi32((out4 >>> 0) + 8, 0); wi32((out4 >>> 0) + 12, 0); return 0; }
    wi32(out4, s.gl.created);
    wi32((out4 >>> 0) + 4, s.gl.current);
    wi32((out4 >>> 0) + 8, s.gl.vp ? s.gl.vp[2] : 0);
    wi32((out4 >>> 0) + 12, s.gl.vp ? s.gl.vp[3] : 0);
    return 1;
  },
  ux_test_gl_presents: (h) => { const s = wins.get(h); return s && s.gl ? s.gl.presents : 0; },
} };
