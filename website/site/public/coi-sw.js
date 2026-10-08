// coi-sw.js — a service worker that adds the two cross-origin isolation
// headers to every response it serves, so a page under it may use
// SharedArrayBuffer: the worker run loop of a UXKit program on the web shares
// memory with its page, and a browser allows that only on an isolated page.
// The site's host sets no headers, so a page that needs them registers this
// worker for its own folder and reloads once under it. It caches nothing.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  const r = e.request;
  if (r.cache === 'only-if-cached' && r.mode !== 'same-origin') return;
  e.respondWith(fetch(r).then((res) => {
    if (res.status === 0 || res.type === 'opaque') return res;
    const h = new Headers(res.headers);
    h.set('Cross-Origin-Embedder-Policy', 'require-corp');
    h.set('Cross-Origin-Opener-Policy', 'same-origin');
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers: h });
  }));
});
