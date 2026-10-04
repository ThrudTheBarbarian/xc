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
  // A plain page, or the WORKER of the interactive run loop: there is no DOM in a worker, so it draws
  // on the OffscreenCanvas the loader hands it (globalThis.xccCanvas) and asks the page
  // (ux_web_page.js, through xccPost) for what only the page can do -- the title, the favicon.
  const hasDOM = typeof document !== 'undefined';
  // In the WORKER the canvas the loader transferred commits its frames only when the worker returns
  // to its event loop, and the run loop never does (it blocks on the ring): nothing would ever reach
  // the screen.  So the worker draws on a canvas of its own and, at each present, hands the page a
  // bitmap of it (ux_web_page.js paints it over the page's canvas).
  const pageCanvas = globalThis.xccCanvas ||
                 (hasDOM ? (document.getElementById('ux-canvas') || document.querySelector('canvas')) : null);
  const canvas = (!hasDOM && pageCanvas && typeof OffscreenCanvas !== 'undefined')
                 ? new OffscreenCanvas(pageCanvas.width, pageCanvas.height) : pageCanvas;
  const ctx = canvas.getContext('2d');
  let comp = null; // the worker's composite: GL views under the 2-D layer
  const presentFrame = () => {
    if (hasDOM || !globalThis.xccPost || canvas === pageCanvas) return;
    const gls = [];
    for (const arr of glViews.values()) for (const e of arr) if (e.gl) gls.push(e);
    if (gls.length) {
      if (!comp || comp.width !== canvas.width || comp.height !== canvas.height)
        comp = new OffscreenCanvas(canvas.width, canvas.height);
      const c2 = comp.getContext('2d');
      c2.clearRect(0, 0, comp.width, comp.height);
      for (const e of gls) c2.drawImage(e.el, e.x, e.y, e.w, e.h); // stretched over the view
      c2.drawImage(canvas, 0, 0);                                    // the 2-D layer over the map
      globalThis.xccPost({ uxFrame: comp.transferToImageBitmap() });
      return;
    }
    const bmp = canvas.transferToImageBitmap(); // synchronous -- but it empties the canvas,
    ctx.drawImage(bmp, 0, 0);                   // so put the frame straight back for the next draw
    globalThis.xccPost({ uxFrame: bmp });
  };
  // a scratch canvas: a DOM one on a page, an OffscreenCanvas in a worker
  const mkCanvas = (w, h) => {
    if (hasDOM) { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; }
    return new OffscreenCanvas(w, h);
  };

  // ── the theme: the GEM atlas (Aristo/Cappuccino artwork), 3/9-sliced ──
  // aristo2.png is gtex2png's twin of the GTEX atlas; the locations file is
  // the theme's own slice map (name x y w h  l t r b  fill).  uxThemeReady
  // resolves either way — a missing theme just keeps the flat stand-ins.
  let themeImg = null; const themeLoc = new Map();
  globalThis.uxThemeReady = (async () => {
    try {
      // fetch + createImageBitmap: the same on a page and in a worker (which has no Image)
      const [img, txt] = await Promise.all([
        fetch('aristo2.png').then((r) => { if (!r.ok) throw new Error('no theme'); return r.blob(); })
                            .then((b) => createImageBitmap(b)),
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
  // TEXT is UTF-8: what is drawn, measured and shown as a title.  (cstr above is byte-exact latin1,
  // which is right for the settings store's round trip and wrong for anything a person reads -- an
  // em dash drew as three characters.)
  const utf8 = new TextDecoder('utf-8');
  const files = new Map();               // the file store (UXFileIO): path -> bytes
  const open = new Map();                // open handles: h -> {path, write, at, chunks}
  let nextFile = 3;
  globalThis.uxFiles = files;
  const ustr = (p) => {
    const m = U8(); let e = p >>> 0;
    while (m[e]) e++;
    return utf8.decode(m.slice(p >>> 0, e));
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
    ux_win_set_title: (h, sp) => {
      const t = ustr(sp);
      if (hasDOM) document.title = t;
      else if (globalThis.xccPost) globalThis.xccPost({ uxTitle: t });
    },
    ux_win_order_front: (h) => { front = h; },
    ux_win_geometry: (h, pw, ph) => { const s = wins.get(h); wi32(pw, s ? s.w : 0); wi32(ph, s ? s.h : 0); },
    ux_present: (h) => { presentFrame(); },      // a page's canvas paints are immediate; a worker's are posted
    // The window's content as it is on screen (UXWindow.snapshot): its region of the canvas composed
    // as the page shows it -- the page's white behind, the window's GL views at their places, the 2-D
    // layer over them -- then read back into memory as w * h opaque 0xAARRGGBB words.
    ux_web_snapshot: (h, x, y, w, hh, out) => {
      const s = wins.get(h);
      if (!s || w <= 0 || hh <= 0) return 0;
      const c = mkCanvas(w, hh);
      const g = c.getContext('2d', { willReadFrequently: true });
      g.fillStyle = '#ffffff';
      g.fillRect(0, 0, w, hh);
      for (const e of (glViews.get(h) || [])) if (e.gl) g.drawImage(e.el, e.x - s.x - x, e.y - s.y - y, e.w, e.h);
      g.drawImage(canvas, s.x + x, s.y + y, w, hh, 0, 0, w, hh);
      const d = g.getImageData(0, 0, w, hh).data;
      // byte by byte (0xAARRGGBB little-endian is B, G, R, A): the words need not be 4-byte aligned
      const m = U8(), at = out >>> 0;
      for (let i = 0; i < w * hh; i++) {
        m[at + i * 4] = d[i * 4 + 2];
        m[at + i * 4 + 1] = d[i * 4 + 1];
        m[at + i * 4 + 2] = d[i * 4];
        m[at + i * 4 + 3] = 255;
      }
      return 1;
    },

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
    // FILES (UXFileIO).  A browser has no file system, so the files an app reads and writes live in
    // a store here, where the module runs, by path.  A WRITE is also the browser's download of the
    // file (the page does it: in the worker run loop the bytes are posted to it).  A file the user
    // OPENS comes from the page's file picker: it shows a small dialog (a picker may only open from
    // a user's click), keeps the picked file by a token, and pushes the token through the ring as
    // type 15 (0: cancelled).  The worker then pulls the name and bytes with xccRequest, which
    // blocks until the page has copied them into a SharedArrayBuffer sent with the request.
    // The loader's file primitives (UXFileIO and the stdlib's Files.xc use them), answered from
    // the store: a handle is an open file, a write handle is downloaded when it is closed.
    _xt_file_size: (pp) => { const f = files.get(ustr(pp)); return f ? f.length : -1; },
    _xt_file_exists: (pp) => files.has(ustr(pp)) ? 1 : 0,
    _xt_file_open: (pp, mp) => {
      const path = ustr(pp), mode = ustr(mp);
      const write = mode.includes('w') || mode.includes('a');
      if (!write && !files.has(path)) return -1;
      const h = nextFile++;
      open.set(h, { path, write, at: 0, chunks: mode.includes('a') && files.has(path) ? [files.get(path)] : [] });
      return h;
    },
    _xt_file_read: (h, buf, n) => {
      const o = open.get(h);
      if (!o || o.write) return -1;
      const f = files.get(o.path);
      const k = Math.max(0, Math.min(n, f.length - o.at));
      U8().set(f.subarray(o.at, o.at + k), buf >>> 0);
      o.at += k;
      return k;
    },
    _xt_file_write: (h, buf, n) => {
      const o = open.get(h);
      if (!o || !o.write) return -1;
      o.chunks.push(U8().slice(buf >>> 0, (buf >>> 0) + n));
      return n;
    },
    _xt_file_close: (h) => {
      const o = open.get(h);
      open.delete(h);
      if (!o || !o.write) return;
      const len = o.chunks.reduce((a, c) => a + c.length, 0);
      const bytes = new Uint8Array(len);
      let at = 0;
      for (const c of o.chunks) { bytes.set(c, at); at += c.length; }
      files.set(o.path, bytes);
      const name = o.path.split('/').pop() || 'untitled';
      if (globalThis.xccPost) globalThis.xccPost({ uxDownload: { name, bytes } });
      else if (globalThis.uxPage && globalThis.uxPage.download) globalThis.uxPage.download({ name, bytes });
    },
    ux_web_has_page: () => (globalThis.xccPost && globalThis.xccRequest) ? 1 : 0,
    ux_web_file_open_show: (pp) => {
      if (!globalThis.xccPost || !globalThis.xccRequest) return 0;
      globalThis.xccPost({ uxOpen: { prompt: ustr(pp) } });
      return 1;
    },
    // the page's colour dialog; the answer is ring type 16 (a = 1 chosen / 0 cancelled, then r g b)
    ux_web_color_show: (r, g, b) => {
      if (!globalThis.xccPost || !globalThis.xccRequest) return 0;
      globalThis.xccPost({ uxColor: { r, g, b } });
      return 1;
    },
    // after a type-15 token: pull the picked file into the store, and its path into out
    ux_web_file_take: (token, out, cap) => {
      const nameBuf = new SharedArrayBuffer(1024);
      const nl = globalThis.xccRequest('uxFileName', { token, sab: nameBuf });
      if (nl < 0) return 0;
      const name = new TextDecoder().decode(new Uint8Array(nameBuf).slice(0, nl));
      const size = globalThis.xccRequest('uxFileSize', { token });
      if (size < 0) return 0;
      const sab = new SharedArrayBuffer(Math.max(size, 1));
      if (globalThis.xccRequest('uxFileFill', { token, sab }) !== size) return 0;
      const path = '/picked/' + name;
      files.set(path, new Uint8Array(sab).slice(0, size));
      const enc = new TextEncoder().encode(path);
      if (enc.length + 1 > cap) return 0;
      const m = U8();
      m.set(enc, out >>> 0);
      m[(out >>> 0) + enc.length] = 0;
      return 1;
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
    // A focused text field as a real <input> on the page (ux_web_page.js): its rect in CANVAS
    // coordinates (the window's origin added), its text, whether it is a password.
    ux_field_overlay_show: (win, token, x, y, w, h, tp, secure, cap) => {
      if (!globalThis.xccPost) return 0;
      const s = wins.get(win);
      const m = U8(); let e = tp >>> 0; while (m[e]) e++;
      const text = new TextDecoder().decode(m.slice(tp >>> 0, e));
      globalThis.xccPost({ uxField: { token, x: (s ? s.x : 0) + x, y: (s ? s.y : 0) + y, w, h, text, secure, cap } });
      return 1;
    },
    ux_field_overlay_hide: (token) => { if (globalThis.xccPost) globalThis.xccPost({ uxFieldEnd: token }); },
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
      const src = U8().subarray(p >>> 0, (p >>> 0) + w * h * 4);
      const img = new ImageData(w, h);
      if (fmt === 1) {
        for (let i = 0; i < w * h * 4; i += 4) {
          img.data[i] = src[i + 2]; img.data[i + 1] = src[i + 1]; img.data[i + 2] = src[i]; img.data[i + 3] = src[i + 3];
        }
      } else img.data.set(src);
      if (!hasDOM) {
        // the page sets the favicon (ux_web_page.js): a worker has no <link>
        if (globalThis.xccPost) globalThis.xccPost({ uxAppIcon: { w, h, data: img.data.slice() } });
        globalThis.uxAppIcon = { w, h, href: null };
        return 1;
      }
      const c = mkCanvas(w, h);
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
        c = mkCanvas(w, h);
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
      ctx.fillText(ustr(sp), ox() + x, oy() + y);
    },
    ux_draw_text_weight: (sp, x, y, famp, size, weight, italic, r, g, b, a) => {
      ctx.fillStyle = rgba(r, g, b, a);
      ctx.font = fontW(cstr(famp), size, weight, italic);
      ctx.textBaseline = 'top';
      ctx.fillText(ustr(sp), ox() + x, oy() + y);
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
      return Math.round(ctx.measureText(ustr(sp)).width);
    },
    ux_text_width_weight: (sp, famp, size, weight, italic) => {
      ctx.font = fontW(cstr(famp), size, weight, italic);
      return Math.round(ctx.measureText(ustr(sp)).width);
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
  // glProc, because on wasm a pointer to an import traps when called.  Each is a GLES3
  // name (the bindings below) translated onto the CURRENT context, so the renderer's
  // declarations bind the same way Apple's do.
  let curGl = null;
  const glViews = new Map(); // handle -> [{node, el, gl}]

  // IN THE WORKER a GL view is an OffscreenCanvas of its own (a worker has real WebGL2 there), and
  // the present COMPOSITES: each GL view's canvas at its place, then the 2-D layer over it, into the
  // one frame the worker posts to the page (presentFrame).  So the GL is still the bottom of the
  // stack and the toolkit's 2-D lands over it, as on the page, where the browser does the composite.
  const newGlCanvas = () => hasDOM ? document.createElement('canvas')
                                   : (typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(1, 1) : null);
  // THE GL BINDINGS.  A renderer is written against GLES 3 (renderer.xc: integer object names,
  // pointers into memory, C strings), and WebGL2 is that API with objects, typed arrays and JS
  // strings.  So each GLES3 entry point is a host import here that translates, onto the CURRENT
  // context (curGl): integer names to WebGL objects through per-context tables, pointers to views of
  // the module's memory, strings both ways.  The same source then runs here as on every other GL
  // backend.  (Unknown names are simply absent: the loader traps on a call to one.)
  const T = () => {
    if (!curGl.__ux) curGl.__ux = { buf: [null], tex: [null], vao: [null], sh: [null], prog: [null], fbo: [null],
                                    rbo: [null], loc: [null], str: {} };
    return curGl.__ux;
  };
  const F32 = () => new Float32Array(globalThis.xcc.memory.buffer);
  const U16 = () => new Uint16Array(globalThis.xcc.memory.buffer);
  const num = (v) => typeof v === 'bigint' ? Number(v) : v;
  const gen = (tab, make) => (n, out) => {
    const t = T()[tab], m = I32();
    for (let i = 0; i < n; i++) { t.push(make()); m[((out >>> 0) >> 2) + i] = t.length - 1; }
  };
  const del = (tab, kill) => (n, p) => {
    const t = T()[tab], m = I32();
    for (let i = 0; i < n; i++) { const id = m[((p >>> 0) >> 2) + i]; if (t[id]) { kill(t[id]); t[id] = null; } }
  };
  const obj = (tab, id) => (id ? T()[tab][id] || null : null);
  const cstrU = (p) => { const m = U8(); let e = p >>> 0; while (m[e]) e++; return utf8.decode(m.slice(p >>> 0, e)); };
  const putStr = (s, max, lenP, outP) => {
    const b = new TextEncoder().encode(s || '');
    const n = Math.max(0, Math.min(b.length, max - 1));
    if (outP && max > 0) { U8().set(b.subarray(0, n), outP >>> 0); U8()[(outP >>> 0) + n] = 0; }
    if (lenP) I32()[(lenP >>> 0) >> 2] = n;
  };
  const comps = { 0x1908: 4, 0x1907: 3, 0x1903: 1, 0x8227: 2, 0x1906: 1, 0x1909: 1, 0x190A: 2, 0x8D99: 4, 0x8D98: 3, 0x8D94: 1, 0x8228: 2 };
  const pixView = (type, fmt, w, h, p) => {
    if (!p) return null;
    const n = w * h * (comps[fmt] || 4);
    if (type === 0x1406) return new Float32Array(globalThis.xcc.memory.buffer, p >>> 0, n);
    if (type === 0x1403 || type === 0x8363 || type === 0x8033 || type === 0x8034 || type === 0x140B)
      return new Uint16Array(globalThis.xcc.memory.buffer, p >>> 0, type === 0x1403 || type === 0x140B ? n : w * h);
    return new Uint8Array(globalThis.xcc.memory.buffer, p >>> 0, n);
  };
  const G = (f) => (...a) => (curGl ? f(curGl, ...a) : undefined);
  const glApi = {
    glActiveTexture: G((g, u) => g.activeTexture(u)),
    glAttachShader: G((g, p, s) => g.attachShader(obj('prog', p), obj('sh', s))),
    glBindAttribLocation: G((g, p, i, n) => g.bindAttribLocation(obj('prog', p), i, cstrU(n))),
    glBindBuffer: G((g, t, id) => g.bindBuffer(t, obj('buf', id))),
    glBindFramebuffer: G((g, t, id) => g.bindFramebuffer(t, obj('fbo', id))),
    glBindRenderbuffer: G((g, t, id) => g.bindRenderbuffer(t, obj('rbo', id))),
    glBindTexture: G((g, t, id) => g.bindTexture(t, obj('tex', id))),
    glBindVertexArray: G((g, id) => g.bindVertexArray(obj('vao', id))),
    glBlendColor: G((g, r, gg, b, a) => g.blendColor(r, gg, b, a)),
    glBlendEquation: G((g, m) => g.blendEquation(m)),
    glBlendEquationSeparate: G((g, a, b) => g.blendEquationSeparate(a, b)),
    glBlendFunc: G((g, s, d) => g.blendFunc(s, d)),
    glBlendFuncSeparate: G((g, a, b, c, d) => g.blendFuncSeparate(a, b, c, d)),
    glBufferData: G((g, t, size, p, usage) => {
      size = num(size);
      if (p) g.bufferData(t, new Uint8Array(globalThis.xcc.memory.buffer, p >>> 0, size), usage);
      else g.bufferData(t, size, usage);
    }),
    glBufferSubData: G((g, t, off, size, p) => g.bufferSubData(t, num(off), new Uint8Array(globalThis.xcc.memory.buffer, p >>> 0, num(size)))),
    glCheckFramebufferStatus: G((g, t) => g.checkFramebufferStatus(t)),
    glClear: G((g, m) => g.clear(m)),
    glClearColor: G((g, r, gg, b, a) => g.clearColor(r, gg, b, a)),
    glClearDepthf: G((g, d) => g.clearDepth(d)),
    glClearStencil: G((g, s) => g.clearStencil(s)),
    glColorMask: G((g, r, gg, b, a) => g.colorMask(!!r, !!gg, !!b, !!a)),
    glCompileShader: G((g, s) => g.compileShader(obj('sh', s))),
    glCreateProgram: G((g) => { const t = T().prog; t.push(g.createProgram()); return t.length - 1; }),
    glCreateShader: G((g, type) => { const t = T().sh; t.push(g.createShader(type)); return t.length - 1; }),
    glCullFace: G((g, m) => g.cullFace(m)),
    glDeleteBuffers: G((g, n, p) => del('buf', (o) => g.deleteBuffer(o))(n, p)),
    glDeleteFramebuffers: G((g, n, p) => del('fbo', (o) => g.deleteFramebuffer(o))(n, p)),
    glDeleteRenderbuffers: G((g, n, p) => del('rbo', (o) => g.deleteRenderbuffer(o))(n, p)),
    glDeleteTextures: G((g, n, p) => del('tex', (o) => g.deleteTexture(o))(n, p)),
    glDeleteVertexArrays: G((g, n, p) => del('vao', (o) => g.deleteVertexArray(o))(n, p)),
    glDeleteProgram: G((g, p) => { const t = T().prog; if (t[p]) { g.deleteProgram(t[p]); t[p] = null; } }),
    glDeleteShader: G((g, s) => { const t = T().sh; if (t[s]) { g.deleteShader(t[s]); t[s] = null; } }),
    glDepthFunc: G((g, f) => g.depthFunc(f)),
    glDepthMask: G((g, f) => g.depthMask(!!f)),
    glDepthRangef: G((g, a, b) => g.depthRange(a, b)),
    glDetachShader: G((g, p, s) => g.detachShader(obj('prog', p), obj('sh', s))),
    glDisable: G((g, c) => g.disable(c)),
    glDisableVertexAttribArray: G((g, i) => g.disableVertexAttribArray(i)),
    glDrawArrays: G((g, m, f, c) => g.drawArrays(m, f, c)),
    glDrawArraysInstanced: G((g, m, f, c, n) => g.drawArraysInstanced(m, f, c, n)),
    glDrawElements: G((g, m, c, t, off) => g.drawElements(m, c, t, off >>> 0)),
    glDrawElementsInstanced: G((g, m, c, t, off, n) => g.drawElementsInstanced(m, c, t, off >>> 0, n)),
    glEnable: G((g, c) => g.enable(c)),
    glEnableVertexAttribArray: G((g, i) => g.enableVertexAttribArray(i)),
    glFinish: G((g) => g.finish()),
    glFlush: G((g) => g.flush()),
    glFramebufferRenderbuffer: G((g, t, a, rt, id) => g.framebufferRenderbuffer(t, a, rt, obj('rbo', id))),
    glFramebufferTexture2D: G((g, t, a, tt, id, lvl) => g.framebufferTexture2D(t, a, tt, obj('tex', id), lvl)),
    glFrontFace: G((g, m) => g.frontFace(m)),
    glGenBuffers: G((g, n, p) => gen('buf', () => g.createBuffer())(n, p)),
    glGenFramebuffers: G((g, n, p) => gen('fbo', () => g.createFramebuffer())(n, p)),
    glGenRenderbuffers: G((g, n, p) => gen('rbo', () => g.createRenderbuffer())(n, p)),
    glGenTextures: G((g, n, p) => gen('tex', () => g.createTexture())(n, p)),
    glGenVertexArrays: G((g, n, p) => gen('vao', () => g.createVertexArray())(n, p)),
    glGenerateMipmap: G((g, t) => g.generateMipmap(t)),
    glGetAttribLocation: G((g, p, n) => g.getAttribLocation(obj('prog', p), cstrU(n))),
    glGetError: G((g) => g.getError()),
    glGetIntegerv: G((g, pname, out) => {
      const v = g.getParameter(pname), m = I32(), at = (out >>> 0) >> 2;
      if (v && typeof v === 'object' && typeof v.length === 'number') { for (let i = 0; i < v.length; i++) m[at + i] = v[i]; }
      else if (typeof v === 'boolean') m[at] = v ? 1 : 0;
      else if (typeof v === 'number') m[at] = v;
      else m[at] = 0;
    }),
    glGetFloatv: G((g, pname, out) => {
      const v = g.getParameter(pname), m = F32(), at = (out >>> 0) >> 2;
      if (v && typeof v === 'object' && typeof v.length === 'number') { for (let i = 0; i < v.length; i++) m[at + i] = v[i]; }
      else m[at] = typeof v === 'number' ? v : (v ? 1 : 0);
    }),
    glGetProgramInfoLog: G((g, p, max, lenP, outP) => putStr(g.getProgramInfoLog(obj('prog', p)), max, lenP, outP)),
    glGetProgramiv: G((g, p, pname, out) => {
      const pr = obj('prog', p);
      const v = pname === 0x8B84 ? (g.getProgramInfoLog(pr) || '').length + 1 : g.getProgramParameter(pr, pname);
      I32()[(out >>> 0) >> 2] = typeof v === 'boolean' ? (v ? 1 : 0) : (v | 0);
    }),
    glGetShaderInfoLog: G((g, s, max, lenP, outP) => putStr(g.getShaderInfoLog(obj('sh', s)), max, lenP, outP)),
    glGetShaderiv: G((g, s, pname, out) => {
      const sh = obj('sh', s);
      const v = pname === 0x8B84 ? (g.getShaderInfoLog(sh) || '').length + 1
              : pname === 0x8B88 ? (g.getShaderSource(sh) || '').length + 1 : g.getShaderParameter(sh, pname);
      I32()[(out >>> 0) >> 2] = typeof v === 'boolean' ? (v ? 1 : 0) : (v | 0);
    }),
    glGetString: G((g, name) => {
      const t = T();
      if (t.str[name]) return t.str[name];
      const s = name === 0x1F03 ? (g.getSupportedExtensions() || []).join(' ') : String(g.getParameter(name) || '');
      const b = new TextEncoder().encode(s);
      const p = globalThis.xcc.instance.exports._xt_browser_alloc(b.length + 1);
      U8().set(b, p >>> 0);
      U8()[(p >>> 0) + b.length] = 0;
      t.str[name] = p;
      return p;
    }),
    glGetUniformLocation: G((g, p, n) => {
      const l = g.getUniformLocation(obj('prog', p), cstrU(n));
      if (!l) return -1;
      const t = T().loc;
      t.push(l);
      return t.length - 1;
    }),
    glIsEnabled: G((g, c) => (g.isEnabled(c) ? 1 : 0)),
    glLineWidth: G((g, w) => g.lineWidth(w)),
    glLinkProgram: G((g, p) => g.linkProgram(obj('prog', p))),
    glPixelStorei: G((g, pn, v) => g.pixelStorei(pn, v)),
    glReadPixels: G((g, x, y, w, h, fmt, type, p) => g.readPixels(x, y, w, h, fmt, type, pixView(type, fmt, w, h, p))),
    glRenderbufferStorage: G((g, t, f, w, h) => g.renderbufferStorage(t, f, w, h)),
    glRenderbufferStorageMultisample: G((g, t, s, f, w, h) => g.renderbufferStorageMultisample(t, s, f, w, h)),
    glScissor: G((g, x, y, w, h) => g.scissor(x, y, w, h)),
    glShaderSource: G((g, s, count, strs, lens) => {
      const m = I32();
      let src = '';
      for (let i = 0; i < count; i++) {
        const p = m[((strs >>> 0) >> 2) + i] >>> 0;
        const n = lens ? m[((lens >>> 0) >> 2) + i] : -1;
        src += n >= 0 ? utf8.decode(U8().slice(p, p + n)) : cstrU(p);
      }
      g.shaderSource(obj('sh', s), src);
    }),
    glStencilFunc: G((g, f, r, m) => g.stencilFunc(f, r, m)),
    glStencilMask: G((g, m) => g.stencilMask(m)),
    glStencilOp: G((g, a, b, c) => g.stencilOp(a, b, c)),
    glTexImage2D: G((g, t, lvl, internal, w, h, border, fmt, type, p) =>
      g.texImage2D(t, lvl, internal, w, h, border, fmt, type, pixView(type, fmt, w, h, p))),
    glTexSubImage2D: G((g, t, lvl, x, y, w, h, fmt, type, p) =>
      g.texSubImage2D(t, lvl, x, y, w, h, fmt, type, pixView(type, fmt, w, h, p))),
    glTexParameteri: G((g, t, pn, v) => g.texParameteri(t, pn, v)),
    glTexParameterf: G((g, t, pn, v) => g.texParameterf(t, pn, v)),
    glUniform1f: G((g, l, a) => g.uniform1f(T().loc[l] || null, a)),
    glUniform2f: G((g, l, a, b) => g.uniform2f(T().loc[l] || null, a, b)),
    glUniform3f: G((g, l, a, b, c) => g.uniform3f(T().loc[l] || null, a, b, c)),
    glUniform4f: G((g, l, a, b, c, d) => g.uniform4f(T().loc[l] || null, a, b, c, d)),
    glUniform1i: G((g, l, a) => g.uniform1i(T().loc[l] || null, a)),
    glUniform2i: G((g, l, a, b) => g.uniform2i(T().loc[l] || null, a, b)),
    glUniform3i: G((g, l, a, b, c) => g.uniform3i(T().loc[l] || null, a, b, c)),
    glUniform4i: G((g, l, a, b, c, d) => g.uniform4i(T().loc[l] || null, a, b, c, d)),
    glUseProgram: G((g, p) => g.useProgram(obj('prog', p))),
    glVertexAttribDivisor: G((g, i, d) => g.vertexAttribDivisor(i, d)),
    glVertexAttribIPointer: G((g, i, size, type, stride, off) => g.vertexAttribIPointer(i, size, type, stride, off >>> 0)),
    glVertexAttribPointer: G((g, i, size, type, norm, stride, off) => g.vertexAttribPointer(i, size, type, !!norm, stride, off >>> 0)),
    glViewport: G((g, x, y, w, h) => g.viewport(x, y, w, h)),
  };
  for (const [n, k] of [['1', 1], ['2', 2], ['3', 3], ['4', 4]]) {
    glApi['glUniform' + n + 'fv'] = G((g, l, count, p) => g['uniform' + n + 'fv'](T().loc[l] || null, new Float32Array(globalThis.xcc.memory.buffer, p >>> 0, count * k)));
    glApi['glUniform' + n + 'iv'] = G((g, l, count, p) => g['uniform' + n + 'iv'](T().loc[l] || null, new Int32Array(globalThis.xcc.memory.buffer, p >>> 0, count * k)));
  }
  for (const [n, k] of [['2', 4], ['3', 9], ['4', 16]])
    glApi['glUniformMatrix' + n + 'fv'] = G((g, l, count, tr, p) =>
      g['uniformMatrix' + n + 'fv'](T().loc[l] || null, !!tr, new Float32Array(globalThis.xcc.memory.buffer, p >>> 0, count * k)));
  // offered only where there is WebGL2 at all (the Node rig has none, and binds nothing here)
  if ((() => { const c = newGlCanvas(); return !!(c && c.getContext('webgl2')); })())
    Object.assign(env, glApi);

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
      const el = newGlCanvas();
      if (!el) return;
      if (hasDOM) {
        el.style.position = 'absolute';
        canvas.parentNode.insertBefore(el, canvas); // BELOW the 2D canvas: the map first
        // ...which holds only if the 2-D canvas is POSITIONED too: CSS paints a positioned element
        // over an unpositioned one whatever the order, and the map would cover the 2-D layer.
        if (getComputedStyle(canvas).position === 'static') canvas.style.position = 'relative';
      }
      s.hasGl = true;
      // the frame is read back later than the draw (the worker's composite, a snapshot): keep the buffer
      e = { node, el, gl: el.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false,
                                                    preserveDrawingBuffer: true }) };
      arr.push(e);
    }
    e.x = s.x + x;
    e.y = s.y + y;
    e.w = w;
    e.h = hh;
    if (hasDOM) {
      // where the 2-D canvas is in its (shared) containing block, plus the view's place in it: the
      // canvas need not sit at the page's origin (a menu bar above it, a margin)
      e.el.style.left = (canvas.offsetLeft + s.x + x) + 'px';
      e.el.style.top = (canvas.offsetTop + s.y + y) + 'px';
      e.el.style.width = w + 'px';
      e.el.style.height = hh + 'px';
    }
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
  // On a page the browser composites: nothing to swap.  In the worker the frame is composited and
  // posted now, as the 2-D present does.
  env.ux_gl_present = (h, node) => { if (!hasDOM) presentFrame(); };
  // UXGLView.drawableSize / snapshot: the GL canvas's pixel size, and its last frame (kept by
  // preserveDrawingBuffer) read back as top-down 0xAARRGGBB words, byte by byte (wasm32 words need
  // not be 4-byte aligned).
  env.ux_gl_drawable = (h, node, pw, ph) => {
    const e = (glViews.get(h) || []).find((v) => v.node === node && v.gl);
    if (!e || !e.el.width || !e.el.height) return 0;
    wi32(pw, e.el.width);
    wi32(ph, e.el.height);
    return 1;
  };
  env.ux_gl_read = (h, node, out, pw, ph) => {
    const e = (glViews.get(h) || []).find((v) => v.node === node && v.gl);
    if (!e || e.el.width !== pw || e.el.height !== ph) return 0;
    const g = e.gl, px = new Uint8Array(pw * ph * 4);
    g.bindFramebuffer(g.FRAMEBUFFER, null);
    g.readPixels(0, 0, pw, ph, g.RGBA, g.UNSIGNED_BYTE, px);
    const m = U8(), at = out >>> 0;
    for (let y = 0; y < ph; y++) {
      const r = (ph - 1 - y) * pw * 4; // GL rows run bottom-up
      for (let x = 0; x < pw; x++) {
        const o = at + (y * pw + x) * 4, i = r + x * 4;
        m[o] = px[i + 2]; m[o + 1] = px[i + 1]; m[o + 2] = px[i]; m[o + 3] = px[i + 3];
      }
    }
    return 1;
  };

  globalThis.xccImports = Object.assign(globalThis.xccImports || {}, { env });
})();
