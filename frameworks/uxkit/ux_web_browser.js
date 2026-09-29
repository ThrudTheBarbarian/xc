// ux_web_browser.js — the BROWSER canvas shim under UXWebDriver: the real-page
// twin of ux_web_node.js (which records ops for the headless Node gates).
// Same env surface, real Canvas2D calls.  Load it before the generated
// loader script; it draws into #ux-canvas (or the first <canvas>).
//
// One window per canvas region: windows are composited in z-order onto the one
// canvas — window (x,y) offsets every draw, which is exactly the driver's
// coordinate contract (canvas coordinates ARE window coordinates plus origin).
//
// Memory views are re-derived PER CALL: memory.grow detaches them (the design
// doc's "single most likely source of a baffling first bug").
'use strict';
(() => {
  const canvas = document.getElementById('ux-canvas') || document.querySelector('canvas');
  const ctx = canvas.getContext('2d');

  // ── the theme: the GEM atlas (Aristo/Cappuccino artwork), 3/9-sliced ──
  // aristo2.png is gtex2png's twin of the GTEX atlas; the locations file is
  // the theme's own slice map (name x y w h  l t r b  fill).  uxThemeReady
  // resolves either way — a missing theme just keeps the flat stand-ins.
  let themeImg = null; const themeLoc = new Map();
  globalThis.uxThemeReady = (async () => {
    try {
      const [img, txt] = await Promise.all([
        new Promise((res, rej) => {
          const i = new Image();
          i.onload = () => res(i); i.onerror = rej;
          i.src = 'aristo2.png';
        }),
        fetch('aristo2-locations.txt').then((r) => r.text()),
      ]);
      themeImg = img;
      for (const line of txt.split('\n')) {
        const t = line.trim();
        if (!t || t.startsWith('#')) continue;
        const f = t.split(/\s+/);
        if (f.length >= 9)
          themeLoc.set(f[0], { x: +f[1], y: +f[2], w: +f[3], h: +f[4],
                               l: +f[5], t: +f[6], r: +f[7], b: +f[8] });
      }
    } catch (e) { /* themeless: stand-ins */ }
  })();
  const drawSlice = (name, dx, dy, dw, dh) => {
    const s = themeImg && themeLoc.get(name);
    if (!s) return false;
    // The atlas is pixel art and some stretch bands are 1px wide: bilinear
    // smoothing samples the NEIGHBOURING cap pixels and paints a fade across
    // the face (the popup faded to its chevron's blue).  GEM's blitter copies
    // exact pixels; so do we.
    ctx.imageSmoothingEnabled = false;
    const { l, t, r, b } = s;
    const cols = [[0, l], [l, Math.max(0, s.w - l - r)], [s.w - r, r]];
    const rows = [[0, t], [t, Math.max(0, s.h - t - b)], [s.h - b, b]];
    const dcols = [[0, l], [l, Math.max(0, dw - l - r)], [dw - r, r]];
    const drows = [[0, t], [t, Math.max(0, dh - t - b)], [dh - b, b]];
    for (let ri = 0; ri < 3; ri++)
      for (let ci = 0; ci < 3; ci++) {
        const [sx, sw] = cols[ci], [sy, sh] = rows[ri];
        const [tx, tw] = dcols[ci], [ty, th] = drows[ri];
        if (sw > 0 && sh > 0 && tw > 0 && th > 0)
          ctx.drawImage(themeImg, s.x + sx, s.y + sy, sw, sh, dx + tx, dy + ty, tw, th);
      }
    return true;
  };
  const wins = new Map();
  let nextH = 1, target = 0, front = 0;
  const settings = new Map();

  const U8 = () => new Uint8Array(globalThis.xcc.memory.buffer);
  const I16 = () => new Int16Array(globalThis.xcc.memory.buffer);
  const I32 = () => new Int32Array(globalThis.xcc.memory.buffer);
  const cstr = (p) => {
    const m = U8(); let e = p >>> 0;
    while (m[e]) e++;
    return new TextDecoder('latin1').decode(m.subarray(p >>> 0, e));
  };
  const wi32 = (p, v) => { I32()[(p >>> 0) >> 2] = v; };
  const rgb = (r, g, b) => `rgb(${r},${g},${b})`;
  const ox = () => (wins.get(target)?.x ?? 0);
  const oy = () => (wins.get(target)?.y ?? 0);
  const font = (fam, size, bold, italic) =>
    `${italic ? 'italic ' : ''}${bold ? 'bold ' : ''}${size > 0 ? size : 13}px ${fam && fam.length ? fam : 'system-ui'}`;

  globalThis.xccImports = Object.assign(globalThis.xccImports || {}, { env: Object.assign((globalThis.xccImports || {}).env || {}, {
    ux_boot: (pw, ph) => { wi32(pw, canvas.width); wi32(ph, canvas.height); return 1; },
    ux_win_create: (x, y, w, h) => { const hh = nextH++; wins.set(hh, { x, y, w, h }); return hh; },
    ux_win_open: (h, x, y, w, hh) => { const s = wins.get(h); if (s) { s.x = x; s.y = y; s.w = w; s.h = hh; front = h; } },
    ux_win_destroy: (h) => { wins.delete(h); },
    ux_win_set_title: (h, sp) => { document.title = cstr(sp); },
    ux_win_order_front: (h) => { front = h; },
    ux_win_geometry: (h, pw, ph) => { const s = wins.get(h); wi32(pw, s ? s.w : 0); wi32(ph, s ? s.h : 0); },
    ux_present: (h) => {},                       // canvas paints are immediate

    ux_gfx_target: (h) => {
      target = h;
      const s = wins.get(h);
      if (s) { ctx.fillStyle = '#ffffff'; ctx.fillRect(s.x, s.y, s.w, s.h); }
    },
    ux_clip: (x, y, w, h) => { ctx.save(); ctx.beginPath(); ctx.rect(ox() + x, oy() + y, w, h); ctx.clip(); },
    ux_clip_end: () => { ctx.restore(); },
    ux_fill_rect: (x, y, w, h, r, g, b) => { ctx.fillStyle = rgb(r, g, b); ctx.fillRect(ox() + x, oy() + y, w, h); },
    ux_fill_circle: (cx, cy, rad, r, g, b) => {
      ctx.fillStyle = rgb(r, g, b);
      ctx.beginPath(); ctx.arc(ox() + cx, oy() + cy, rad, 0, Math.PI * 2); ctx.fill();
    },
    ux_draw_line: (x0, y0, x1, y1, r, g, b) => {
      ctx.strokeStyle = rgb(r, g, b); ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(ox() + x0, oy() + y0); ctx.lineTo(ox() + x1, oy() + y1); ctx.stroke();
    },
    ux_fill_poly: (xyp, n, r, g, b, a) => {
      const m = I16(); const base = (xyp >>> 0) >> 1;
      if (n < 3) return;
      ctx.fillStyle = rgba(r, g, b, a);
      ctx.beginPath(); ctx.moveTo(ox() + m[base], oy() + m[base + 1]);
      for (let i = 1; i < n; i++) ctx.lineTo(ox() + m[base + i * 2], oy() + m[base + i * 2 + 1]);
      ctx.closePath(); ctx.fill();
    },
    ux_stroke_ops: (opsp, n, width, cap, join, dashp, ndash, phase, r, g, b, a) => {
      const m = I32(); const base = (opsp >>> 0) >> 2;
      const dm = I32(); const dbase = (dashp >>> 0) >> 2;
      ctx.strokeStyle = rgba(r, g, b, a); ctx.lineWidth = width;
      ctx.lineJoin = join === 0 ? 'miter' : (join === 2 ? 'bevel' : 'round');
      ctx.lineCap = cap === 1 ? 'round' : (cap === 2 ? 'square' : 'butt');
      // The dash run and its phase; [] is solid.  setLineDash restarts the phase at each subpath —
      // the rule the seam promises and the reason the run is handed over rather than chopped up here.
      if (ndash > 0) {
        const pat = [];
        for (let k = 0; k < ndash && k < 8; k++) pat.push(dm[dbase + k] > 0 ? dm[dbase + k] : 1);
        ctx.setLineDash(pat);
      } else {
        ctx.setLineDash([]);
      }
      ctx.lineDashOffset = ndash > 0 ? phase : 0;
      ctx.beginPath();
      let i = 0, sx = 0, sy = 0, started = false;
      while (i < n) {
        const op = m[base + i++];
        if (op === 0) { sx = m[base + i]; sy = m[base + i + 1]; i += 2; ctx.moveTo(ox() + sx, oy() + sy); started = true; }
        else if (op === 1) {
          if (!started) { ctx.moveTo(ox() + m[base + i], oy() + m[base + i + 1]); started = true; }
          else ctx.lineTo(ox() + m[base + i], oy() + m[base + i + 1]);
          i += 2;
        } else if (op === 2) {
          ctx.bezierCurveTo(ox() + m[base + i], oy() + m[base + i + 1], ox() + m[base + i + 2],
                            oy() + m[base + i + 3], ox() + m[base + i + 4], oy() + m[base + i + 5]);
          i += 6;
        } else if (op === 3) { ctx.closePath(); }
        else break;
      }
      ctx.stroke();
    },
    ux_draw_text: (sp, x, y, famp, size, bold, italic, r, g, b) => {
      ctx.fillStyle = rgb(r, g, b);
      ctx.font = font(cstr(famp), size, bold, italic);
      ctx.textBaseline = 'top';
      ctx.fillText(cstr(sp), ox() + x, oy() + y);
    },
    ux_draw_theme: (slicep, x, y, w, h) => {
      if (!drawSlice(cstr(slicep), ox() + x, oy() + y, w, h)) {
        ctx.fillStyle = '#c0c0c0'; ctx.fillRect(ox() + x, oy() + y, w, h);
      }
    },
    ux_stroke_rect_edges: (x, y, w, h) => {
      ctx.strokeStyle = '#808080'; ctx.lineWidth = 1;
      ctx.strokeRect(ox() + x + 0.5, oy() + y + 0.5, w - 1, h - 1);
    },
    ux_text_width: (sp, famp, size, bold, italic) => {
      ctx.font = font(cstr(famp), size, bold, italic);
      return Math.round(ctx.measureText(cstr(sp)).width);
    },
    ux_text_width_weight: (sp, famp, size, weight, italic) => {
      ctx.font = fontW(cstr(famp), size, weight, italic);
      return Math.round(ctx.measureText(cstr(sp)).width);
    },
    // The face's ascent, for a caller converting a baseline into the seam's top-of-line y.  The
    // font's own box, NOT actualBoundingBoxAscent: that one follows the string (a line of digits is
    // shorter than a line with a bracket), and a line moved by its own text is the bug this avoids.
    ux_text_ascent: (famp, size, weight, italic) => {
      ctx.font = fontW(cstr(famp), size, weight, italic);
      const m = ctx.measureText('H');
      const a = (m.fontBoundingBoxAscent !== undefined) ? m.fontBoundingBoxAscent
                                                       : (0.8 * (size > 0 ? size : 13));
      return Math.round(a);
    },

    ux_now_utc: (p7) => {
      const d = new Date();
      const v = [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(),
                 d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds() * 1000];
      for (let i = 0; i < 7; i++) wi32((p7 >>> 0) + i * 4, v[i]);
    },
    ux_tz_offmin: () => -new Date().getTimezoneOffset(),
    ux_setting_get: (dp, kp, out, cap) => {
      const v = settings.get(cstr(dp) + ' ' + cstr(kp));
      if (v === undefined) return 0;
      const m = U8(); let i = 0;
      for (; i < v.length && i < cap - 1; i++) m[(out >>> 0) + i] = v.charCodeAt(i) & 0xFF;
      m[(out >>> 0) + i] = 0;
      return 1;
    },
    ux_setting_set: (dp, kp, vp) => { settings.set(cstr(dp) + ' ' + cstr(kp), cstr(vp)); return 1; },
    ux_setting_remove: (dp, kp) => { settings.delete(cstr(dp) + ' ' + cstr(kp)); return 1; },
  });

  // ── GL (WebGL2) ─────────────────────────────────────────────────────────────
  // The page twin of the Node rig's GL surface, over a real context.  One <canvas>
  // per GL view, inserted BEFORE the shared 2D canvas so the map is the bottom of
  // the stack, and the 2D canvas is left unfilled behind a window that has one
  // (see ux_gfx_target) so the toolkit's 2D composites over the map.
  //
  // The entry points are HOST IMPORTS the renderer declares -- this backend has no
  // glProc, because on wasm a pointer to an import traps when called.  The names a
  // WebGL2 context answers are enumerated once (not hardcoded) and each becomes an
  // import that forwards to the CURRENT context, so the renderer's declarations
  // bind the same way Apple's do.
  let curGl = null;
  const glViews = new Map(); // handle -> [{node, el, gl}]

  const glNames = (() => {
    const c = document.createElement('canvas');
    const g = c.getContext('webgl2');
    if (!g) return [];
    const out = new Set();
    for (let o = g; o; o = Object.getPrototypeOf(o))
      for (const k of Object.getOwnPropertyNames(o))
        if (k.startsWith('gl') && typeof g[k] === 'function') out.add(k);
    return [...out];
  })();
  for (const name of glNames)
    env[name] = (...args) => (curGl ? curGl[name](...args) : undefined);

  env.ux_gl_create = (h, node, x, y, w, hh) => {
    const s = wins.get(h);
    if (!s) return;
    let arr = glViews.get(h);
    if (!arr) { arr = []; glViews.set(h, arr); }
    const dpr = globalThis.devicePixelRatio || 1;
    const el = document.createElement('canvas');
    el.style.position = 'absolute';
    el.style.left = (s.x + x) + 'px';
    el.style.top = (s.y + y) + 'px';
    el.style.width = w + 'px';
    el.style.height = hh + 'px';
    el.width = Math.round(w * dpr);
    el.height = Math.round(hh * dpr);
    canvas.parentNode.insertBefore(el, canvas); // BELOW the 2D canvas: the map first
    s.hasGl = true;
    arr.push({ node, el, gl: el.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false }) });
  };
  env.ux_gl_make_current = (h, node) => {
    const arr = glViews.get(h);
    if (!arr) return 0;
    for (const e of arr) if (e.node === node && e.gl) { curGl = e.gl; return 1; }
    return 0;
  };
  env.ux_gl_viewport = (h, node) => {
    const arr = glViews.get(h);
    if (!arr) return;
    for (const e of arr) if (e.node === node && e.gl) { curGl = e.gl; e.gl.viewport(0, 0, e.el.width, e.el.height); }
  };
  env.ux_gl_present = (h, node) => {}; // the browser composites: nothing to swap

  globalThis.xccImports = Object.assign(globalThis.xccImports || {}, { env });
})();
