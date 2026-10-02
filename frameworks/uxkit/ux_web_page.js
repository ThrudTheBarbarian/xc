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
                        popup, closePopup, onPopupPick: null, alert, onAlert: null };
  // The worker's posts (the loader forwards them here).
  const prev = globalThis.xccOnMessage;
  globalThis.xccOnMessage = (p) => {
    if (p && p.uxSetting !== undefined) {   // the worker's settings, persisted here (no localStorage there)
      try {
        if (p.uxSetting.v === null) localStorage.removeItem('uxkit:' + p.uxSetting.k);
        else localStorage.setItem('uxkit:' + p.uxSetting.k, p.uxSetting.v);
      } catch (e) {}
    }
    else if (p && p.uxAlert !== undefined) alert(p.uxAlert);
    else if (p && p.uxPopup !== undefined) popup(p.uxPopup);
    else if (p && p.uxMenu !== undefined) build(p.uxMenu);
    else if (p && p.uxMenuState) state(p.uxMenuState);
    else if (prev) prev(p);
  };
})();
