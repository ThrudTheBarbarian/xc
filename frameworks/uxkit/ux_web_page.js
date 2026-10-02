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

  const build = (json) => {
    model = typeof json === 'string' ? JSON.parse(json) : json;
    if (!document.getElementById('ux-menu-style')) {
      const st = document.createElement('style');
      st.id = 'ux-menu-style';
      st.textContent = css;
      document.head.appendChild(st);
    }
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

  globalThis.uxPage = { menu: build, menuState: state, close, openTitle: show, onPick: null };
  // The worker's posts (the loader forwards them here).
  const prev = globalThis.xccOnMessage;
  globalThis.xccOnMessage = (p) => {
    if (p && p.uxMenu !== undefined) build(p.uxMenu);
    else if (p && p.uxMenuState) state(p.uxMenuState);
    else if (prev) prev(p);
  };
})();
