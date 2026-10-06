// ux_web_page.js — UXKit's PAGE-side services for the web backend: what needs the DOM.
//
// In the interactive run loop the app runs in a worker (the loader's runLoop: "worker"), drawing
// into an OffscreenCanvas through ux_web_browser.js; the DOM stays here, on the page.  The worker
// posts what it needs (xccPost -> xccOnMessage) and this script answers through the ring
// (xccPushEvent).  Without a worker -- a plain page -- ux_web_browser.js calls uxPage directly.
//
// Load it on the page, before the app's script:  <script src="ux_web_page.js"></script>
//
// THE MENU BAR (UXMenuBar): a DOM bar above the canvas.  A click opens a title's pull-down; while
// one is open, moving onto another title opens that one; a pick, a click elsewhere or Escape closes
// it.  A pick goes into the ring as type 9 (a = title, b = item), which the driver turns into a
// menu-select.  Ticked items show a check, greyed ones do not respond.
//
// THE POPUP LIST (UXPopUpButton): see popup() below; a pick is ring type 10.
//
// THE MODAL ALERT (UXAlert): see alert() below; the answer is ring type 7, the 1-based button.
(() => {
  const css = `
.ux-menubar { display: flex; gap: 2px; padding: 2px 4px; font: 13px system-ui, sans-serif;
  background: #ececec; border-bottom: 1px solid #c8c8c8; user-select: none; position: relative; }
.ux-menubar .ux-title { padding: 3px 9px; border-radius: 4px; cursor: default; position: relative; }
.ux-menubar .ux-title.open, .ux-menubar .ux-title:hover { background: #d4d4d4; }
.ux-menubar .ux-drop { position: absolute; top: 100%; left: 0; min-width: 170px; z-index: 1000;
  background: #fafafa; border: 1px solid #bdbdbd; border-radius: 5px; padding: 4px 0;
  box-shadow: 0 4px 14px rgba(0,0,0,.18); display: none; }
.ux-menubar .ux-title.open .ux-drop { display: block; }
.ux-menubar .ux-item { padding: 3px 22px 3px 24px; position: relative; white-space: nowrap; }
.ux-menubar .ux-item:hover:not(.disabled) { background: #2a6fdb; color: #fff; }
.ux-menubar .ux-item.disabled { color: #a0a0a0; }
.ux-menubar .ux-item.checked::before { content: "\\2713"; position: absolute; left: 8px; }
.ux-menubar .ux-key { float: right; margin-left: 24px; opacity: 0.6; }
.ux-menubar .ux-sep { height: 1px; background: #d6d6d6; margin: 4px 0; }
@media (prefers-color-scheme: dark) {
  .ux-menubar { background: #2b2b2b; border-color: #444; color: #e6e6e6; }
  .ux-menubar .ux-title.open, .ux-menubar .ux-title:hover { background: #3d3d3d; }
  .ux-menubar .ux-drop { background: #323232; border-color: #4a4a4a; }
  .ux-menubar .ux-item.disabled { color: #777; }
  .ux-menubar .ux-sep { background: #4a4a4a; }
}`;
  let bar = null;      // the bar element
  let model = [];      // [{title, items:[{text, checked, disabled} | {sep}]}]
  let open = -1;       // the title whose pull-down is open
  const picks = [];    // every pick, for a test to read
  globalThis.uxMenuPicks = picks;

  const pick = (t, j) => {
    picks.push([t, j]);
    if (globalThis.xccPushEvent) globalThis.xccPushEvent(9, t, j);
    else if (globalThis.uxPage.onPick) globalThis.uxPage.onPick(t, j);
  };
  const close = () => {
    if (open >= 0 && bar) bar.children[open].classList.remove('open');
    open = -1;
  };
  const show = (t) => {
    if (open === t) return;
    close();
    if (bar && bar.children[t]) { bar.children[t].classList.add('open'); open = t; }
  };
  const itemEl = (t, j) => bar && bar.children[t] && bar.children[t].querySelector('.ux-drop').children[j];
  const paint = (el, it) => {
    el.classList.toggle('checked', !!it.checked);
    el.classList.toggle('disabled', !!it.disabled);
  };

  // A shortcut: Command on a Mac, Control elsewhere, as the platform's own menus spell it.
  const isMac = /Mac|iPhone|iPad/.test((globalThis.navigator && navigator.platform) || '');
  const keyLabel = (it) => isMac ? (it.shift ? '\u21e7' : '') + '\u2318' + it.key
                                 : 'Ctrl+' + (it.shift ? 'Shift+' : '') + it.key;
  document.addEventListener('keydown', (e) => {
    if (!(isMac ? e.metaKey : e.ctrlKey) || e.altKey || !e.key) return;
    const want = e.key.length === 1 ? e.key.toUpperCase() : '';
    for (let t = 0; t < model.length; t++) {
      const items = model[t].items;
      for (let j = 0; j < items.length; j++) {
        const it = items[j];
        if (it.key && it.key === want && !!it.shift === e.shiftKey && !it.disabled) {
          e.preventDefault();
          e.stopPropagation();
          close();
          pick(t, j);
          return;
        }
      }
    }
  }, true);

  const ensureStyle = () => {
    if (document.getElementById('ux-menu-style')) return;
    const st = document.createElement('style');
    st.id = 'ux-menu-style';
    st.textContent = css;
    document.head.appendChild(st);
  };
  const build = (json) => {
    model = typeof json === 'string' ? JSON.parse(json) : json;
    ensureStyle();
    if (bar) bar.remove();
    bar = document.createElement('div');
    bar.className = 'ux-menubar';
    bar.setAttribute('role', 'menubar');
    model.forEach((m, t) => {
      const title = document.createElement('div');
      title.className = 'ux-title';
      title.setAttribute('role', 'menuitem');
      title.textContent = m.title;
      const drop = document.createElement('div');
      drop.className = 'ux-drop';
      drop.setAttribute('role', 'menu');
      m.items.forEach((it, j) => {
        const el = document.createElement('div');
        if (it.sep) {
          el.className = 'ux-sep';
        } else {
          el.className = 'ux-item';
          el.setAttribute('role', 'menuitem');
          el.textContent = it.text;
          if (it.key) {
            const k = document.createElement('span');
            k.className = 'ux-key';
            k.textContent = keyLabel(it);
            el.appendChild(k);
          }
          paint(el, it);
          el.addEventListener('click', (e) => {
            e.stopPropagation();
            if (model[t].items[j].disabled) return;
            close();
            pick(t, j);
          });
        }
        drop.appendChild(el);
      });
      title.appendChild(drop);
      title.addEventListener('click', (e) => { e.stopPropagation(); open === t ? close() : show(t); });
      title.addEventListener('mouseenter', () => { if (open >= 0) show(t); });
      bar.appendChild(title);
    });
    const canvas = document.getElementById('ux-canvas') || document.getElementById('xcc-canvas') ||
                   document.querySelector('canvas');
    if (canvas && canvas.parentNode) canvas.parentNode.insertBefore(bar, canvas);
    else document.body.prepend(bar);
  };

  const state = (st) => {
    const it = model[st.t] && model[st.t].items[st.j];
    if (!it || it.sep) return;
    if (st.what === 0) it.checked = st.on ? 1 : 0;
    else it.disabled = st.on ? 0 : 1;
    const el = itemEl(st.t, st.j);
    if (el) paint(el, it);
  };

  document.addEventListener('click', close);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && open >= 0) { close(); e.stopPropagation(); } }, true);

  // THE POPUP LIST (UXPopUpButton): a list at the button, the current choice marked.  A pick goes
  // into the ring as type 10 (a = the token the driver gave, b = the item); a click elsewhere or
  // Escape closes it without one.
  let pop = null;
  const popupPicks = [];
  globalThis.uxPopupPicks = popupPicks;
  const closePopup = () => { if (pop) { pop.remove(); pop = null; } };
  const popup = (json) => {
    const o = typeof json === 'string' ? JSON.parse(json) : json;
    closePopup();
    ensureStyle();
    const canvas = document.getElementById('ux-canvas') || document.getElementById('xcc-canvas') ||
                   document.querySelector('canvas');
    const r = canvas ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
    pop = document.createElement('div');
    pop.className = 'ux-menubar ux-popup';
    pop.setAttribute('role', 'listbox');
    pop.style.cssText = `position:absolute; display:block; padding:4px 0; border:1px solid #bdbdbd;
      border-radius:5px; box-shadow:0 4px 14px rgba(0,0,0,.18); background:#fafafa; z-index:1000;
      left:${r.left + window.scrollX + o.x}px; top:${r.top + window.scrollY + o.y}px; min-width:${o.w}px;`;
    o.items.forEach((text, i) => {
      const el = document.createElement('div');
      el.className = 'ux-item' + (i === o.selected ? ' checked' : '');
      el.setAttribute('role', 'option');
      el.textContent = text;
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        closePopup();
        popupPicks.push([o.token, i]);
        if (globalThis.xccPushEvent) globalThis.xccPushEvent(10, o.token, i);
        else if (globalThis.uxPage.onPopupPick) globalThis.uxPage.onPopupPick(o.token, i);
      });
      pop.appendChild(el);
    });
    document.body.appendChild(pop);
    // the click that opened it must not close it
    setTimeout(() => document.addEventListener('click', closePopup, { once: true }), 0);
  };
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && pop) { closePopup(); e.stopPropagation(); } }, true);

  // THE MODAL ALERT (UXAlert, in the worker run loop): a dialog over a dimmed page.  The worker is
  // blocked on the ring until the answer: the 1-based button, as ring type 7.  Return presses the
  // default button and Escape the cancel one (the last), as the native alerts do; nothing behind
  // the dialog can be clicked while it is up.
  const alertCss = `
.ux-alert-back { position: fixed; inset: 0; background: rgba(0,0,0,.28); z-index: 2000;
  display: flex; align-items: center; justify-content: center; font: 13px system-ui, sans-serif; }
.ux-alert { background: #fafafa; border-radius: 10px; padding: 18px 20px 14px; min-width: 260px;
  max-width: 420px; box-shadow: 0 10px 34px rgba(0,0,0,.3); color: #1c1b1f; }
.ux-alert .ux-alert-line { margin: 0 0 6px; }
.ux-alert .ux-alert-line:first-child { font-weight: 600; font-size: 14px; }
.ux-alert .ux-alert-buttons { display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; }
.ux-alert button { font: inherit; padding: 5px 16px; border-radius: 6px; border: 1px solid #c4c4c4;
  background: #fff; cursor: default; }
.ux-alert button.default { background: #2a6fdb; border-color: #2a6fdb; color: #fff; }
@media (prefers-color-scheme: dark) {
  .ux-alert { background: #323232; color: #e6e6e6; }
  .ux-alert button { background: #444; border-color: #555; color: #e6e6e6; }
}`;
  const alertPicks = [];
  globalThis.uxAlertPicks = alertPicks;
  let alertBack = null;
  const answerAlert = (n) => {
    if (!alertBack) return;
    alertBack.remove();
    alertBack = null;
    document.removeEventListener('keydown', alertKeys, true);
    alertPicks.push(n);
    if (globalThis.xccPushEvent) globalThis.xccPushEvent(7, n);
    else if (globalThis.uxPage.onAlert) globalThis.uxPage.onAlert(n);
  };
  let alertModel = null;
  const alertKeys = (e) => {
    if (!alertBack) return;
    if (e.key === 'Enter' && alertModel.def > 0) { e.preventDefault(); e.stopPropagation(); answerAlert(alertModel.def); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); answerAlert(alertModel.buttons.length); }
  };
  const alert = (a) => {
    if (!document.getElementById('ux-alert-style')) {
      const st = document.createElement('style');
      st.id = 'ux-alert-style';
      st.textContent = alertCss;
      document.head.appendChild(st);
    }
    if (alertBack) alertBack.remove();
    alertModel = { lines: a.lines.filter((l) => l !== ''), buttons: a.buttons.filter((b) => b !== ''), def: a.def | 0 };
    if (!alertModel.buttons.length) alertModel.buttons = ['OK'];
    alertBack = document.createElement('div');
    alertBack.className = 'ux-alert-back';
    const box = document.createElement('div');
    box.className = 'ux-alert';
    box.setAttribute('role', 'alertdialog');
    box.setAttribute('aria-modal', 'true');
    alertModel.lines.forEach((l) => {
      const p = document.createElement('p');
      p.className = 'ux-alert-line';
      p.textContent = l;
      box.appendChild(p);
    });
    const row = document.createElement('div');
    row.className = 'ux-alert-buttons';
    alertModel.buttons.forEach((b, i) => {
      const el = document.createElement('button');
      el.textContent = b;
      if (i + 1 === alertModel.def) el.className = 'default';
      el.addEventListener('click', (e) => { e.stopPropagation(); answerAlert(i + 1); });
      row.appendChild(el);
    });
    box.appendChild(row);
    alertBack.appendChild(box);
    alertBack.addEventListener('mousedown', (e) => e.stopPropagation()); // nothing behind it
    document.body.appendChild(alertBack);
    document.addEventListener('keydown', alertKeys, true);
    const d = row.children[(alertModel.def || 1) - 1];
    if (d) d.focus();
  };

  // FILES.  A write is a DOWNLOAD of the file.  An OPEN is a small dialog whose Choose button
  // opens the real file picker (a picker may only open from a user's click, so it cannot open
  // straight from the worker's request).  The picked file is kept by a token, pushed through the
  // ring as type 15 (0: cancelled), and the worker pulls its name and bytes with requests.
  const download = (d) => {
    globalThis.uxDownloads = globalThis.uxDownloads || [];
    globalThis.uxDownloads.push({ name: d.name, length: d.bytes.length, text: new TextDecoder().decode(d.bytes) });
    const url = URL.createObjectURL(new Blob([d.bytes]));
    const a = document.createElement('a');
    a.href = url;
    a.download = d.name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  };
  const picked = new Map();
  let nextPick = 1;
  let openBack = null;
  const openDone = (token) => {
    if (openBack) { openBack.remove(); openBack = null; }
    if (globalThis.xccPushEvent) globalThis.xccPushEvent(15, token);
  };
  const openFile = (o) => {
    if (!document.getElementById('ux-alert-style')) {
      const st = document.createElement('style');
      st.id = 'ux-alert-style';
      st.textContent = alertCss;
      document.head.appendChild(st);
    }
    if (openBack) openBack.remove();
    openBack = document.createElement('div');
    openBack.className = 'ux-alert-back';
    const box = document.createElement('div');
    box.className = 'ux-alert ux-open';
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    const p = document.createElement('p');
    p.className = 'ux-alert-line';
    p.textContent = o.prompt || 'Open a file';
    box.appendChild(p);
    const input = document.createElement('input');
    input.type = 'file';
    input.style.display = 'none';
    input.addEventListener('change', () => {
      const f = input.files && input.files[0];
      if (!f) return;
      f.arrayBuffer().then((buf) => {
        const token = nextPick++;
        picked.set(token, { name: f.name, bytes: new Uint8Array(buf) });
        openDone(token);
      });
    });
    box.appendChild(input);
    const row = document.createElement('div');
    row.className = 'ux-alert-buttons';
    const cancel = document.createElement('button');
    cancel.textContent = 'Cancel';
    cancel.addEventListener('click', (e) => { e.stopPropagation(); openDone(0); });
    const choose = document.createElement('button');
    choose.textContent = 'Choose File\u2026';
    choose.className = 'default';
    choose.addEventListener('click', (e) => { e.stopPropagation(); input.click(); });
    row.appendChild(cancel);
    row.appendChild(choose);
    box.appendChild(row);
    openBack.appendChild(box);
    openBack.addEventListener('mousedown', (e) => e.stopPropagation());
    document.body.appendChild(openBack);
    choose.focus();
  };
  // COLOUR.  A small dialog holding the browser's own colour control, <input type=color>, seeded with
  // the colour; OK pushes it through the ring as type 16 (1, r, g, b), Cancel as (0).
  let colorBack = null;
  const colorDone = (ok, hex) => {
    if (colorBack) { colorBack.remove(); colorBack = null; }
    const v = parseInt((hex || '#000000').slice(1), 16);
    if (globalThis.xccPushEvent) globalThis.xccPushEvent(16, ok ? 1 : 0, (v >> 16) & 255, (v >> 8) & 255, v & 255);
  };
  const pickColor = (o) => {
    if (!document.getElementById('ux-alert-style')) {
      const st = document.createElement('style');
      st.id = 'ux-alert-style';
      st.textContent = alertCss;
      document.head.appendChild(st);
    }
    if (colorBack) colorBack.remove();
    colorBack = document.createElement('div');
    colorBack.className = 'ux-alert-back';
    const box = document.createElement('div');
    box.className = 'ux-alert ux-color';
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    const p = document.createElement('p');
    p.className = 'ux-alert-line';
    p.textContent = 'Colour';
    box.appendChild(p);
    const input = document.createElement('input');
    input.type = 'color';
    input.value = '#' + [o.r, o.g, o.b].map((c) => (c & 255).toString(16).padStart(2, '0')).join('');
    input.style.cssText = 'width: 100%; height: 40px; border: 0; padding: 0; background: none;';
    box.appendChild(input);
    const row = document.createElement('div');
    row.className = 'ux-alert-buttons';
    const cancel = document.createElement('button');
    cancel.textContent = 'Cancel';
    cancel.addEventListener('click', (e) => { e.stopPropagation(); colorDone(false); });
    const ok = document.createElement('button');
    ok.textContent = 'OK';
    ok.className = 'default';
    ok.addEventListener('click', (e) => { e.stopPropagation(); colorDone(true, input.value); });
    row.appendChild(cancel);
    row.appendChild(ok);
    box.appendChild(row);
    colorBack.appendChild(box);
    colorBack.addEventListener('mousedown', (e) => e.stopPropagation());
    box.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); colorDone(false); }
      else if (e.key === 'Enter') { e.preventDefault(); colorDone(true, input.value); }
    });
    document.body.appendChild(colorBack);
    ok.focus();
  };
  // the worker's pulls of a picked file: its name, its size, its bytes (into the request's buffer)
  const prevReq = globalThis.xccOnRequest;
  globalThis.xccOnRequest = (req) => {
    const f = req && req.payload && picked.get(req.payload.token);
    if (req && req.kind === 'uxFileName') {
      if (!f) return -1;
      const enc = new TextEncoder().encode(f.name).slice(0, req.payload.sab.byteLength);
      new Uint8Array(req.payload.sab).set(enc);
      return enc.length;
    }
    if (req && req.kind === 'uxTv') return textView(req.payload);
    if (req && req.kind === 'uxFileSize') return f ? f.bytes.length : -1;
    if (req && req.kind === 'uxFileFill') {
      if (!f) return -1;
      new Uint8Array(req.payload.sab).set(f.bytes);
      picked.delete(req.payload.token);
      return f.bytes.length;
    }
    return prevReq ? prevReq(req) : 0;
  };

  // THE FRAME (the worker run loop): the worker draws on a canvas of its own and posts a bitmap of
  // it at each present, because a canvas transferred to a blocked worker never commits a frame.  It
  // is painted on a display canvas laid exactly over the page's canvas; that one takes no pointer
  // events, so clicks and keys still reach the canvas underneath, where the loader listens.
  let display = null;
  const frame = (bmp) => {
    const under = document.getElementById('ux-canvas') || document.getElementById('xcc-canvas') ||
                  document.querySelector('canvas:not(.ux-display)');
    if (!display) {
      display = document.createElement('canvas');
      display.className = 'ux-display';
      display.style.cssText = 'position:absolute; pointer-events:none; z-index:1;';
      document.body.appendChild(display);
    }
    if (under) {
      const r = under.getBoundingClientRect();
      display.style.left = (r.left + window.scrollX) + 'px';
      display.style.top = (r.top + window.scrollY) + 'px';
      display.style.width = r.width + 'px';
      display.style.height = r.height + 'px';
    }
    if (display.width !== bmp.width || display.height !== bmp.height) { display.width = bmp.width; display.height = bmp.height; }
    display.getContext('2d').drawImage(bmp, 0, 0);
    if (bmp.close) bmp.close();
    globalThis.uxFrames = (globalThis.uxFrames || 0) + 1; // for a gate: frames really painted
  };

  // THE TEXT FIELD (UXTextField, in the worker run loop): while a field has the keyboard, a REAL
  // <input> sits over it, so the browser's own editing works -- IME composition, selection, the
  // clipboard, a phone's keyboard -- none of which a canvas can offer.  Every change goes back as
  // the whole text, UTF-8 through the ring (type 12: token + length, then type 13: token + offset +
  // twenty bytes), and Return as type 14.  Composition is sent once it ends, not stroke by stroke.
  let field = null;      // { el, token }
  const fieldPicks = [];
  globalThis.uxFieldSent = fieldPicks; // what was sent, for a test to read
  const fieldSend = () => {
    if (!field || !globalThis.xccPushEvent) return;
    const bytes = new TextEncoder().encode(field.el.value).slice(0, Math.max(0, field.cap - 1));
    globalThis.xccPushEvent(12, field.token, bytes.length);
    for (let off = 0; off < bytes.length; off += 20) {
      const w = [0, 0, 0, 0, 0];
      for (let k = 0; k < 20 && off + k < bytes.length; k++) w[k >> 2] |= bytes[off + k] << ((k & 3) * 8);
      globalThis.xccPushEvent(13, field.token, off, w[0], w[1], w[2], w[3], w[4]);
    }
    fieldPicks.push(field.el.value);
  };
  const fieldHide = (token) => {
    if (field && (token === undefined || token === field.token)) { field.el.remove(); field = null; }
  };
  const fieldShow = (f) => {
    fieldHide();
    const canvas = document.getElementById('ux-canvas') || document.getElementById('xcc-canvas') ||
                   document.querySelector('canvas');
    const r = canvas ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
    const el = document.createElement('input');
    el.type = f.secure ? 'password' : 'text';
    el.className = 'ux-field';
    el.value = f.text;
    el.style.cssText = `position:absolute; z-index:900; box-sizing:border-box; margin:0;
      left:${r.left + window.scrollX + f.x}px; top:${r.top + window.scrollY + f.y}px;
      width:${f.w}px; height:${f.h}px; font:13px system-ui, sans-serif; padding:0 4px;
      border:1px solid #2a6fdb; border-radius:3px; background:#fff; color:#1c1b1f; outline:none;`;
    field = { el, token: f.token, cap: f.cap || 256 };
    el.addEventListener('input', (e) => { if (!e.isComposing) fieldSend(); });
    el.addEventListener('compositionend', () => fieldSend());
    el.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.isComposing) {
        e.preventDefault();
        fieldSend();
        if (globalThis.xccPushEvent) globalThis.xccPushEvent(14, field.token);
      }
    });
    document.body.appendChild(el);
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  };

  // THE TEXT VIEW (UXTextView): a contenteditable <div> over the view's rect, there while the view
  // is, so the browser does the editing -- typing, the caret, selection, IME, the clipboard, emoji, a
  // phone's keyboard.  Its content is rendered from UTF-8 text and style runs (five ints each: byte
  // start, byte length, flags, colour, size; flags 1 bold, 2 italic, 4 underline, 8 monospace, the
  // paragraph's alignment in bits 4-5) as one <div> per paragraph of <span>s, and read back the
  // same way.  The worker asks for the content, the selection and edits with xccRequest
  // ('uxTv'), which is answered here at once.  The user's edits go to the worker through the ring:
  // type 17 (id) the content changed, 18 (id) the selection moved, 19 (id, 0 undo / 1 redo) an
  // undo key.  Undo is the worker's: the browser's own stops working once content is set from code.
  const tvs = new Map(); // id -> { el, typing }
  const tvAligns = ['left', 'right', 'center', 'justify'];
  const tvSpan = (text, f, c, z) => {
    const sp = document.createElement('span');
    sp.dataset.f = f; sp.dataset.c = c; sp.dataset.s = z;
    let css = '';
    if (f & 1) css += 'font-weight:bold;';
    if (f & 2) css += 'font-style:italic;';
    if (f & 4) css += 'text-decoration:underline;';
    if (f & 8) css += 'font-family:ui-monospace,Menlo,Consolas,monospace;';
    if (c & 0x1000000) css += 'color:#' + (c & 0xffffff).toString(16).padStart(6, '0') + ';';
    if (z > 0) css += 'font-size:' + z + 'px;';
    sp.style.cssText = css;
    sp.textContent = text;
    return sp;
  };
  const enc = new TextEncoder(), dec = new TextDecoder();
  const u8len = (t) => enc.encode(t).length;
  // A UTF-8 byte offset into t as a UTF-16 index (backed off to a character's start), and back.
  const u16of = (t, b) => {
    const bytes = enc.encode(t);
    if (b <= 0) return 0;
    if (b >= bytes.length) return t.length;
    while (b > 0 && (bytes[b] & 0xc0) === 0x80) b--;
    return dec.decode(bytes.slice(0, b)).length;
  };
  const u8of = (t, i) => {
    if (i > 0 && i < t.length) { const c = t.charCodeAt(i); if (c >= 0xdc00 && c < 0xe000) i--; }
    return u8len(t.slice(0, i));
  };
  const tvRender = (el, text, runs) => {
    // paragraphs of [text, f, c, z] pieces
    const paras = [[]];
    let aligns = [0];
    const take = (piece, f, c, z) => {
      const parts = piece.split('\n');
      parts.forEach((pt, k) => {
        if (k > 0) { paras.push([]); aligns.push(0); }
        if (pt.length) paras[paras.length - 1].push([pt, f, c, z]);
        // a run's alignment is its paragraphs': each it has text in, and each whose newline it has
        if ((f >> 4) && (pt.length || k < parts.length - 1)) aligns[aligns.length - 1] = (f >> 4) & 3;
      });
    };
    const bytes = enc.encode(text);
    let at = 0;
    for (let k = 0; k <= runs.length / 5; k++) {
      const st = k < runs.length / 5 ? runs[k * 5] : bytes.length;
      const ln = k < runs.length / 5 ? runs[k * 5 + 1] : 0;
      if (st > at) take(dec.decode(bytes.slice(at, st)), 0, 0, 0);
      if (k < runs.length / 5 && ln > 0) take(dec.decode(bytes.slice(st, st + ln)), runs[k * 5 + 2], runs[k * 5 + 3], runs[k * 5 + 4]);
      at = Math.max(at, st + ln);
    }
    el.textContent = '';
    paras.forEach((ps, k) => {
      const d = document.createElement('div');
      d.style.textAlign = tvAligns[aligns[k]];
      d.dataset.a = aligns[k];
      for (const [pt, f, c, z] of ps) d.appendChild(tvSpan(pt, f, c, z));
      if (!ps.length) d.appendChild(document.createElement('br'));
      el.appendChild(d);
    });
  };
  // The content as paragraphs of styled text nodes: [{align, nodes: [{node, text, f, c, z}]}].
  const tvWalk = (el) => {
    const paras = [];
    let cur = null;
    const para = (block) => {
      const a = block ? (block.dataset.a !== undefined ? +block.dataset.a
                         : Math.max(0, tvAligns.indexOf(getComputedStyle(block).textAlign))) : 0;
      cur = { align: a, nodes: [], block };
      paras.push(cur);
    };
    const styleOf = (n) => {
      let f = 0, c = 0, z = 0;
      for (let e = n.parentElement; e && e !== el; e = e.parentElement) {
        if (e.dataset && e.dataset.f !== undefined) { f |= +e.dataset.f & 15; if (!c) c = +e.dataset.c; if (!z) z = +e.dataset.s; }
        const tag = e.tagName;
        if (tag === 'B' || tag === 'STRONG') f |= 1;
        if (tag === 'I' || tag === 'EM') f |= 2;
        if (tag === 'U') f |= 4;
      }
      return [f, c, z];
    };
    const visit = (n) => {
      if (n.nodeType === 3) {
        if (!cur) para(null);
        const [f, c, z] = styleOf(n);
        cur.nodes.push({ node: n, text: n.nodeValue, f, c, z });
      } else if (n.tagName === 'BR') {
        if (!cur) para(null);
        // a <br> that is not its block's last child is a line break inside it
        if (n.nextSibling) { cur.nodes.push({ node: n, text: '\n', f: 0, c: 0, z: 0 }); }
      } else if (n.tagName === 'DIV' || n.tagName === 'P') {
        para(n);
        for (const k of n.childNodes) visit(k);
        cur = null;
      } else {
        for (const k of n.childNodes) visit(k);
      }
    };
    for (const k of el.childNodes) visit(k);
    if (!paras.length) para(null);
    return paras;
  };
  // The plain text, and a UTF-16 index for each (node, offset) found in it.
  const tvText = (paras) => paras.map((p) => p.nodes.map((x) => x.text).join('')).join('\n');
  const tvRead = (el) => {
    const paras = tvWalk(el);
    let text = '';
    const runs = [];
    let bytes = 0;
    paras.forEach((p, k) => {
      if (k > 0) {
        // the newline takes the previous paragraph's alignment
        runs.push(bytes, 1, (paras[k - 1].align & 3) << 4, 0, 0);
        text += '\n'; bytes += 1;
      }
      for (const x of p.nodes) {
        if (!x.text.length) continue;
        const n = u8len(x.text);
        const f = (x.text === '\n' ? 0 : x.f) | ((p.align & 3) << 4);
        const last = runs.length - 5;
        if (last >= 0 && runs[last] + runs[last + 1] === bytes && runs[last + 2] === f &&
            runs[last + 3] === x.c && runs[last + 4] === x.z) runs[last + 1] += n;
        else runs.push(bytes, n, f, x.c, x.z);
        text += x.text; bytes += n;
      }
    });
    return { text, runs };
  };
  // DOM position -> UTF-16 index in tvText, and back.
  const tvIndexOf = (el, node, off) => {
    const paras = tvWalk(el);
    let at = 0;
    for (let k = 0; k < paras.length; k++) {
      const p = paras[k];
      if (k > 0) at += 1;
      if (p.block && (node === p.block || node === el && el.childNodes[off] === p.block)) {
        if (node === el) return at;
        // (block, off): the off-th child of the block
        let a2 = at;
        for (const x of p.nodes) { if (p.block.childNodes[off] && (p.block.childNodes[off] === x.node || p.block.childNodes[off].contains(x.node))) return a2; a2 += x.text.length; }
        return a2;
      }
      for (const x of p.nodes) {
        if (x.node === node) return at + (x.node.nodeType === 3 ? off : 0);
        if (node.nodeType === 1 && node.contains(x.node) && node !== x.node) {
          // (element, off): before the off-th child
          const ch = node.childNodes[off];
          if (ch && (ch === x.node || ch.contains(x.node))) return at;
        }
        at += x.text.length;
      }
    }
    return at;
  };
  const tvPosOf = (el, idx) => {
    const paras = tvWalk(el);
    let at = 0;
    for (let k = 0; k < paras.length; k++) {
      const p = paras[k];
      if (k > 0) at += 1;
      let end = at + p.nodes.reduce((a, x) => a + x.text.length, 0);
      if (idx <= end) {
        let a2 = at;
        for (const x of p.nodes) {
          if (x.node.nodeType === 3 && idx <= a2 + x.text.length) return [x.node, idx - a2];
          a2 += x.text.length;
        }
        return [p.block || el, p.block ? 0 : el.childNodes.length];
      }
      at = end;
    }
    return [el, el.childNodes.length];
  };
  const tvSel = (t) => {
    const sel = document.getSelection();
    if (!sel || !sel.rangeCount || !t.el.contains(sel.anchorNode)) return t.lastSel || [0, 0];
    const r = sel.getRangeAt(0);
    const text = tvText(tvWalk(t.el));
    const a = tvIndexOf(t.el, r.startContainer, r.startOffset), b = tvIndexOf(t.el, r.endContainer, r.endOffset);
    const s8 = u8of(text, a), e8 = u8of(text, b);
    return [s8, e8 - s8];
  };
  const tvSetSel = (t, s8, l8) => {
    const text = tvText(tvWalk(t.el));
    const a = u16of(text, s8), b = u16of(text, s8 + l8);
    t.lastSel = [s8, l8];
    t.quietSel = true;
    const sel = document.getSelection();
    const r = document.createRange();
    const [n0, o0] = tvPosOf(t.el, a), [n1, o1] = tvPosOf(t.el, b);
    r.setStart(n0, o0); r.setEnd(n1, o1);
    if (document.activeElement === t.el || !document.activeElement || document.activeElement === document.body) {
      sel.removeAllRanges(); sel.addRange(r);
    }
  };
  const tvPush = (type, id, a) => { if (globalThis.xccPushEvent) globalThis.xccPushEvent(type, id, a || 0); };
  const tvMake = (q) => {
    if (tvs.has(q.id)) return;
    const el = document.createElement('div');
    el.className = 'ux-textview';
    el.contentEditable = 'true';
    el.spellcheck = true;
    el.style.cssText = `position:absolute; z-index:800; box-sizing:border-box; margin:0; overflow:auto;
      font:13px system-ui, sans-serif; padding:4px 6px; border:1px solid #b9b9b9; background:#fff;
      color:#1c1b1f; outline:none; white-space:pre-wrap; overflow-wrap:break-word;`;
    const t = { el, typing: null, lastSel: [0, 0], quietSel: false, composing: false };
    tvs.set(q.id, t);
    tvRender(el, '', []);
    el.addEventListener('compositionstart', () => { t.composing = true; });
    el.addEventListener('compositionend', () => { t.composing = false; tvPush(17, q.id); });
    el.addEventListener('input', (e) => { if (!e.isComposing && !t.composing) { t.typed = true; tvPush(17, q.id); } });
    el.addEventListener('beforeinput', (e) => {
      if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') {
        e.preventDefault();
        tvPush(19, q.id, e.inputType === 'historyRedo' ? 1 : 0);
        return;
      }
      // a style chosen at an empty selection: what is typed next is a span of that style
      if (t.typing && e.inputType === 'insertText' && !e.isComposing && e.data) {
        e.preventDefault();
        const sel = document.getSelection();
        const r = sel.getRangeAt(0);
        r.deleteContents();
        const sp = tvSpan(e.data, t.typing.f & 15, t.typing.c, t.typing.z);
        r.insertNode(sp);
        r.setStart(sp.firstChild, sp.firstChild.length); r.collapse(true);
        sel.removeAllRanges(); sel.addRange(r);
        t.typing = null;
        t.typed = true;
        tvPush(17, q.id);
      }
    });
    el.addEventListener('paste', (e) => {
      // pasted as text, in the style at the caret: a page's styles are not this view's
      e.preventDefault();
      const s = (e.clipboardData && e.clipboardData.getData('text/plain')) || '';
      if (s) document.execCommand('insertText', false, s);
    });
    el.addEventListener('keydown', (e) => {
      const mod = isMac ? e.metaKey : e.ctrlKey;
      if (mod && !e.altKey && (e.key === 'z' || e.key === 'Z' || (!isMac && (e.key === 'y' || e.key === 'Y')))) {
        e.preventDefault();
        tvPush(19, q.id, (e.shiftKey || e.key === 'y' || e.key === 'Y') ? 1 : 0);
      }
      // the view's editing keys are its own, not the menu bar's
      if (mod) e.stopPropagation();
    });
    document.body.appendChild(el);
  };
  document.addEventListener('selectionchange', () => {
    for (const [id, t] of tvs) {
      const sel = document.getSelection();
      if (!sel || !sel.anchorNode || !t.el.contains(sel.anchorNode)) continue;
      const now = tvSel(t);
      if (t.quietSel || t.typed) { t.quietSel = false; t.typed = false; t.lastSel = now; continue; }
      if (now[0] !== t.lastSel[0] || now[1] !== t.lastSel[1]) { t.lastSel = now; t.typing = null; tvPush(18, id); }
    }
  });
  const tvFrame = (q) => {
    const t = tvs.get(q.id);
    if (!t) return;
    const canvas = document.getElementById('ux-canvas') || document.getElementById('xcc-canvas') ||
                   document.querySelector('canvas');
    const r = canvas ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
    const st = t.el.style;
    st.left = (r.left + window.scrollX + q.x) + 'px'; st.top = (r.top + window.scrollY + q.y) + 'px';
    st.width = q.w + 'px'; st.height = q.h + 'px';
    st.display = q.hidden ? 'none' : 'block';
  };
  // The worker's text-view requests (and, on a plain page, the browser shim's direct calls).
  const textView = (q) => {
    if (q.op === 'make') { tvMake(q); tvFrame(q); return 1; }
    if (q.op === 'frame') { tvFrame(q); return 1; }
    const t = tvs.get(q.id);
    if (!t) return -1;
    if (q.op === 'set') { tvRender(t.el, dec.decode(q.text), q.runs); t.typing = null; tvSetSel(t, 0, 0); return 1; }
    if (q.op === 'replace') {
      const cur = tvRead(t.el);
      const bytes = enc.encode(cur.text);
      const ins = q.text, n = ins.length;
      // the new content: the bytes before, the replacement, the bytes after; runs likewise
      const out = new Uint8Array(bytes.length - q.len + n);
      out.set(bytes.slice(0, q.start)); out.set(ins, q.start); out.set(bytes.slice(q.start + q.len), q.start + n);
      const runs = [];
      for (let k = 0; k < cur.runs.length; k += 5) {
        const s0 = cur.runs[k], e0 = s0 + cur.runs[k + 1];
        const keep = (a, b, shift) => { if (b > a) runs.push(a + shift, b - a, cur.runs[k + 2], cur.runs[k + 3], cur.runs[k + 4]); };
        keep(s0, Math.min(e0, q.start), 0);
        keep(Math.max(s0, q.start + q.len), e0, n - q.len);
      }
      for (let k = 0; k < q.runs.length; k += 5) runs.push(q.runs[k] + q.start, q.runs[k + 1], q.runs[k + 2], q.runs[k + 3], q.runs[k + 4]);
      const order = [];
      for (let k = 0; k < runs.length; k += 5) order.push(runs.slice(k, k + 5));
      order.sort((x, y) => x[0] - y[0]);
      const sel = tvSel(t);
      tvRender(t.el, dec.decode(out), [].concat(...order));
      tvSetSel(t, sel[0], sel[1]);
      return 1;
    }
    if (q.op === 'size') { const c = tvRead(t.el); const w = new Int32Array(q.sab); w[0] = u8len(c.text); w[1] = c.runs.length / 5; return 1; }
    if (q.op === 'read') {
      const c = tvRead(t.el);
      const b = enc.encode(c.text).slice(0, q.cap);
      new Uint8Array(q.text).set(b);
      const k = Math.min(q.maxRuns, c.runs.length / 5);
      new Int32Array(q.runs).set(c.runs.slice(0, k * 5));
      return k;
    }
    if (q.op === 'sel') { const s = tvSel(t); const w = new Int32Array(q.sab); w[0] = s[0]; w[1] = s[1]; return 1; }
    if (q.op === 'setsel') { tvSetSel(t, q.start, q.len); return 1; }
    if (q.op === 'typing') { t.typing = { f: q.flags, c: q.colour, z: q.size }; return 1; }
    if (q.op === 'focus') { t.el.focus(); tvSetSel(t, t.lastSel[0], t.lastSel[1]); return 1; }
    if (q.op === 'remove') { t.el.remove(); tvs.delete(q.id); return 1; }
    return 0;
  };
  globalThis.uxTextViews = tvs; // for a test to reach the editors

  // The worker's settings snapshot, for xccConfig.workerData: every stored setting, by key.
  const settingsSnapshot = () => {
    const out = {};
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith('uxkit:')) out[k.slice(6)] = localStorage.getItem(k);
      }
    } catch (e) {}
    return out;
  };
  if (globalThis.xccConfig && globalThis.xccConfig.runLoop === 'worker')
    globalThis.xccConfig.workerData = Object.assign({}, globalThis.xccConfig.workerData, { uxSettings: settingsSnapshot() });

  globalThis.uxPage = { menu: build, menuState: state, close, openTitle: show, onPick: null,
                        popup, closePopup, onPopupPick: null, alert, onAlert: null, download, openFile, pickColor,
                        textView };
  // The worker's posts (the loader forwards them here).
  const prev = globalThis.xccOnMessage;
  globalThis.xccOnMessage = (p) => {
    if (p && p.uxFrame !== undefined) frame(p.uxFrame);
    else if (p && p.uxTvFrame !== undefined) tvFrame(p.uxTvFrame);
    else if (p && p.uxField !== undefined) fieldShow(p.uxField);
    else if (p && p.uxFieldEnd !== undefined) fieldHide(p.uxFieldEnd);
    else if (p && p.uxTitle !== undefined) { document.title = p.uxTitle; }
    else if (p && p.uxAppIcon !== undefined) {   // the worker's app icon, as the page's favicon
      const a = p.uxAppIcon, c = document.createElement('canvas');
      c.width = a.w; c.height = a.h;
      c.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(a.data), a.w, a.h), 0, 0);
      let link = document.querySelector('link[rel~="icon"]');
      if (!link) { link = document.createElement('link'); link.rel = 'icon'; document.head.appendChild(link); }
      link.type = 'image/png';
      link.href = c.toDataURL('image/png');
    }
    else if (p && p.uxSetting !== undefined) {   // the worker's settings, persisted here (no localStorage there)
      try {
        if (p.uxSetting.v === null) localStorage.removeItem('uxkit:' + p.uxSetting.k);
        else localStorage.setItem('uxkit:' + p.uxSetting.k, p.uxSetting.v);
      } catch (e) {}
    }
    else if (p && p.uxAlert !== undefined) alert(p.uxAlert);
    else if (p && p.uxOpen !== undefined) openFile(p.uxOpen);
    else if (p && p.uxColor !== undefined) pickColor(p.uxColor);
    else if (p && p.uxDownload !== undefined) download(p.uxDownload);
    else if (p && p.uxPopup !== undefined) popup(p.uxPopup);
    else if (p && p.uxMenu !== undefined) build(p.uxMenu);
    else if (p && p.uxMenuState) state(p.uxMenuState);
    else if (prev) prev(p);
  };
})();
