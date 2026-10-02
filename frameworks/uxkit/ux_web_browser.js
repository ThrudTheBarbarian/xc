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
  // Settings PERSIST: on a plain page straight to localStorage; in the worker run loop (no
  // localStorage in a worker) from a snapshot the page hands the worker at start, with every change
  // posted back for the page to store.  Keys are "uxkit:<domain> <key>"; values are kept as their
  // bytes (latin1 both ways, so UTF-8 survives untouched).
  const LS_PREFIX = 'uxkit:';
  const hasLS = (() => { try { return typeof localStorage !== 'undefined' && localStorage !== null; } catch (e) { return false; } })();
  const settings = new Map();
  const seed = globalThis.xccWorkerData && globalThis.xccWorkerData.uxSettings;
  if (seed) for (const k of Object.keys(seed)) settings.set(k, seed[k]);
  const settingStore = (k, v) => {
    if (hasLS) { try { v === undefined ? localStorage.removeItem(LS_PREFIX + k) : localStorage.setItem(LS_PREFIX + k, v); } catch (e) {} }
    else if (globalThis.xccPost) globalThis.xccPost({ uxSetting: { k, v: v === undefined ? null : v } });
  };
  const settingLoad = (k) => {
    if (hasLS) { try { const v = localStorage.getItem(LS_PREFIX + k); return v === null ? undefined : v; } catch (e) { return settings.get(k); } }
    return settings.get(k);
  };

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
  // alpha is the straight 0..255 value; a == 255 renders as the opaque rgb() form.
  const rgba = (r, g, b, a) => (a >= 255 ? rgb(r, g, b) : `rgba(${r},${g},${b},${a / 255})`);
  const pixCache = new Map(); // drawPixels: bitmap canvases by address/size/layout
  const ox = () => (wins.get(target)?.x ?? 0);
  const oy = () => (wins.get(target)?.y ?? 0);
  const font = (fam, size, bold, italic) =>
    `${italic ? 'italic ' : ''}${bold ? 'bold ' : ''}${size > 0 ? size : 13}px ${fam && fam.length ? fam : 'system-ui'}`;
  // The CSS font shorthand takes a numeric weight straight (400 normal, 600 semibold), so a CSS
  // weight passes through unmodified and the browser resolves the nearest face the family has.
  const fontW = (fam, size, weight, italic) =>
    `${italic ? 'italic ' : ''}${weight > 0 ? weight : 400} ${size > 0 ? size : 13}px ${fam && fam.length ? fam : 'system-ui'}`;

  const env = Object.assign((globalThis.xccImports || {}).env || {}, {
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
      // A window with a GL surface clears to TRANSPARENT, not white, so the map
      // canvas below shows through and the toolkit's 2D composites over it.  A
      // window without one paints the opaque white backdrop it always did.
      if (s && s.hasGl) ctx.clearRect(s.x, s.y, s.w, s.h);
      else if (s) { ctx.fillStyle = '#ffffff'; ctx.fillRect(s.x, s.y, s.w, s.h); }
    },
    ux_clip: (x, y, w, h) => { ctx.save(); ctx.beginPath(); ctx.rect(ox() + x, oy() + y, w, h); ctx.clip(); },
    ux_clip_round: (x, y, w, h, r) => {
      ctx.save(); ctx.beginPath();
      const rr = Math.max(0, Math.min(r, w / 2, h / 2));
      if (rr > 0 && ctx.roundRect) ctx.roundRect(ox() + x, oy() + y, w, h, rr);
      else ctx.rect(ox() + x, oy() + y, w, h);
      ctx.clip();
    },
    ux_clip_end: () => { ctx.restore(); },
    ux_fill_rect: (x, y, w, h, r, g, b, a) => { ctx.fillStyle = rgba(r, g, b, a); ctx.fillRect(ox() + x, oy() + y, w, h); },
    ux_clear_rect: (x, y, w, h) => { ctx.clearRect(ox() + x, oy() + y, w, h); },
    // drawPixels: the bitmap is copied out of wasm memory into a canvas ONCE, keyed by its address,
    // size and layout (UXPIX_ARGB32 words are B,G,R,A in memory and are reordered), then each call is
    // one drawImage of the region.
    // The menu bar.  In the worker (the interactive run loop), the page owns the DOM: the JSON and
    // each state change are posted to it (xccPost; ux_web_page.js builds and updates the bar and
    // pushes a pick into the ring as type 9).  Without a worker -- a plain page -- the bar is built
    // here directly by the same code, when ux_web_page.js is loaded.
    ux_menu_set: (p, len) => {
      const json = new TextDecoder().decode(U8().slice(p >>> 0, (p >>> 0) + len));
      if (globalThis.xccPost) globalThis.xccPost({ uxMenu: json });
      else if (globalThis.uxPage) globalThis.uxPage.menu(json);
    },
    ux_popup_open: (p, len) => {
      const json = new TextDecoder().decode(U8().slice(p >>> 0, (p >>> 0) + len));
      if (globalThis.xccPost) globalThis.xccPost({ uxPopup: json });
      else if (globalThis.uxPage) globalThis.uxPage.popup(json);
    },
    // A modal alert: in the worker, the page shows it (ux_web_page.js) and the answer comes back
    // through the ring as type 7.  Lines and buttons are "|"-separated.
    ux_web_alert_show: (icon, lp, bp, def) => {
      if (!globalThis.xccPost) return 0;
      const str = (p) => { const m = U8(); let e = p >>> 0; while (m[e]) e++;
                           return new TextDecoder().decode(m.slice(p >>> 0, e)); };
      globalThis.xccPost({ uxAlert: { icon, lines: str(lp).split('|'), buttons: str(bp).split('|'), def } });
      return 1;
    },
    ux_menu_state: (t, j, what, on) => {
      const st = { t, j, what, on };
      if (globalThis.xccPost) globalThis.xccPost({ uxMenuState: st });
      else if (globalThis.uxPage) globalThis.uxPage.menuState(st);
    },
    // Sound: 16-bit mono PCM into an AudioBuffer, played by its own source node, so sounds overlap.
    // A browser only lets audio start after the page has been clicked or typed in: the context is
    // made on the first sound and resumed on the first such gesture.  Until it runs, a sound
    // answers 0 (not played) rather than vanishing silently.  uxAudioPlayed counts what started.
    ux_audio_play: (p, frames, rate) => {
      if (frames <= 0 || rate <= 0) return 0;
      const C = globalThis.AudioContext || globalThis.webkitAudioContext;
      if (!C) return 0;
      if (!globalThis.uxAudio) {
        globalThis.uxAudio = new C();
        const wake = () => { if (globalThis.uxAudio.state === 'suspended') globalThis.uxAudio.resume(); };
        for (const ev of ['pointerdown', 'keydown']) globalThis.addEventListener(ev, wake, { capture: true });
      }
      const ac = globalThis.uxAudio;
      if (ac.state === 'suspended') ac.resume();
      if (ac.state !== 'running') return 0;
      const buf = ac.createBuffer(1, frames, rate);
      const d = buf.getChannelData(0);
      const s = new Int16Array(globalThis.xcc.memory.buffer, p >>> 0, frames);
      for (let i = 0; i < frames; i++) d[i] = s[i] / 32768;
      const src = ac.createBufferSource();
      src.buffer = buf;
      src.connect(ac.destination);
      src.start();
      globalThis.uxAudioPlayed = (globalThis.uxAudioPlayed || 0) + 1;
      return 1;
    },
    // The application's icon: the page's favicon.  The pixels (fmt 0 RGBA bytes, 1 0xAARRGGBB words)
    // go onto a canvas and the <link rel="icon"> points at it as a PNG; uxAppIcon keeps what was set.
    ux_app_set_icon: (p, w, h, fmt) => {
      if (w <= 0 || h <= 0) return 0;
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      const src = U8().subarray(p >>> 0, (p >>> 0) + w * h * 4);
      const img = new ImageData(w, h);
      if (fmt === 1) {
        for (let i = 0; i < w * h * 4; i += 4) {
          img.data[i] = src[i + 2]; img.data[i + 1] = src[i + 1]; img.data[i + 2] = src[i]; img.data[i + 3] = src[i + 3];
        }
      } else img.data.set(src);
      c.getContext('2d').putImageData(img, 0, 0);
      const href = c.toDataURL('image/png');
      let link = document.querySelector('link[rel~="icon"]');
      if (!link) { link = document.createElement('link'); link.rel = 'icon'; document.head.appendChild(link); }
      link.type = 'image/png';
      link.href = href;
      globalThis.uxAppIcon = { w, h, href };
      return 1;
    },
    ux_draw_pixels: (p, w, h, fmt, sx, sy, sw, sh, dx, dy, dw, dh, a) => {
      if (w <= 0 || h <= 0 || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || a <= 0) return;
      const key = (p >>> 0) + ':' + w + 'x' + h + ':' + fmt;
      let c = pixCache.get(key);
      if (!c) {
        c = document.createElement('canvas'); c.width = w; c.height = h;
        const src = U8().subarray(p >>> 0, (p >>> 0) + w * h * 4);
        const img = new ImageData(w, h);
        if (fmt === 1) {
          for (let i = 0; i < w * h * 4; i += 4) {
            img.data[i] = src[i + 2]; img.data[i + 1] = src[i + 1]; img.data[i + 2] = src[i]; img.data[i + 3] = src[i + 3];
          }
        } else img.data.set(src);
        c.getContext('2d').putImageData(img, 0, 0);
        if (pixCache.size >= 8) pixCache.delete(pixCache.keys().next().value);
        pixCache.set(key, c);
      }
      ctx.save();
      ctx.globalAlpha = a >= 255 ? 1 : a / 255;
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(c, sx, sy, sw, sh, ox() + dx, oy() + dy, dw, dh);
      ctx.restore();
    },
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
    ux_draw_text: (sp, x, y, famp, size, bold, italic, r, g, b, a) => {
      ctx.fillStyle = rgba(r, g, b, a);
      ctx.font = font(cstr(famp), size, bold, italic);
      ctx.textBaseline = 'top';
      ctx.fillText(cstr(sp), ox() + x, oy() + y);
    },
    ux_draw_text_weight: (sp, x, y, famp, size, weight, italic, r, g, b, a) => {
      ctx.fillStyle = rgba(r, g, b, a);
      ctx.font = fontW(cstr(famp), size, weight, italic);
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
      const v = settingLoad(cstr(dp) + ' ' + cstr(kp));
      if (v === undefined) return 0;
      const m = U8(); let i = 0;
      for (; i < v.length && i < cap - 1; i++) m[(out >>> 0) + i] = v.charCodeAt(i) & 0xFF;
      m[(out >>> 0) + i] = 0;
      return 1;
    },
    ux_setting_set: (dp, kp, vp) => {
      const k = cstr(dp) + ' ' + cstr(kp), v = cstr(vp);
      settings.set(k, v);
      settingStore(k, v);
      return 1;
    },
    ux_setting_remove: (dp, kp) => {
      const k = cstr(dp) + ' ' + cstr(kp);
      settings.delete(k);
      settingStore(k, undefined);
      return 1;
    },
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

  // The drawable's pixel size: the view's CSS size at the device pixel ratio, scaled down by one
  // factor on both sides if that is more than this context can hold (a maximised window at 2x on an
  // old integrated GPU), so the aspect is kept.  The canvas keeps the view's CSS size, so the
  // browser stretches the frame over it.  uxGlTestMax lowers the limit for a test.
  const glPixelSize = (gl, w, hh) => {
    const dpr = globalThis.devicePixelRatio || 1;
    let pw = Math.max(1, Math.round(w * dpr)), ph = Math.max(1, Math.round(hh * dpr));
    let m = 0;
    if (gl) {
      const vp = gl.getParameter(gl.MAX_VIEWPORT_DIMS) || [0, 0];
      m = Math.min(gl.getParameter(gl.MAX_TEXTURE_SIZE) || Infinity,
                   gl.getParameter(gl.MAX_RENDERBUFFER_SIZE) || Infinity, vp[0] || Infinity, vp[1] || Infinity);
    }
    if (globalThis.uxGlTestMax > 0) m = m > 0 ? Math.min(m, globalThis.uxGlTestMax) : globalThis.uxGlTestMax;
    if (m > 0 && m !== Infinity && (pw > m || ph > m)) {
      const k = m / Math.max(pw, ph);
      pw = Math.max(1, Math.floor(pw * k));
      ph = Math.max(1, Math.floor(ph * k));
    }
    return [pw, ph];
  };
  // Made with the tree, and called again on every realize: a view already given a canvas keeps it and
  // follows its frame (a second canvas per realize would stack up under the 2-D one).  Setting a
  // canvas's pixel size clears it, so that happens only when the size changes.
  env.ux_gl_create = (h, node, x, y, w, hh) => {
    const s = wins.get(h);
    if (!s) return;
    let arr = glViews.get(h);
    if (!arr) { arr = []; glViews.set(h, arr); }
    let e = arr.find((v) => v.node === node);
    if (!e) {
      const el = document.createElement('canvas');
      el.style.position = 'absolute';
      canvas.parentNode.insertBefore(el, canvas); // BELOW the 2D canvas: the map first
      s.hasGl = true;
      e = { node, el, gl: el.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false }) };
      arr.push(e);
    }
    e.el.style.left = (s.x + x) + 'px';
    e.el.style.top = (s.y + y) + 'px';
    e.el.style.width = w + 'px';
    e.el.style.height = hh + 'px';
    const [pw, ph] = glPixelSize(e.gl, w, hh);
    if (e.el.width !== pw || e.el.height !== ph) {
      e.el.width = pw;
      e.el.height = ph;
      if (e.gl) e.gl.viewport(0, 0, pw, ph); // the driver's viewport follows the drawable
    }
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
