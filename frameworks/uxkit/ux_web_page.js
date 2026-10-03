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
                        popup, closePopup, onPopupPick: null, alert, onAlert: null, download, openFile };
  // The worker's posts (the loader forwards them here).
  const prev = globalThis.xccOnMessage;
  globalThis.xccOnMessage = (p) => {
    if (p && p.uxFrame !== undefined) frame(p.uxFrame);
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
    else if (p && p.uxDownload !== undefined) download(p.uxDownload);
    else if (p && p.uxPopup !== undefined) popup(p.uxPopup);
    else if (p && p.uxMenu !== undefined) build(p.uxMenu);
    else if (p && p.uxMenuState) state(p.uxMenuState);
    else if (prev) prev(p);
  };
})();
