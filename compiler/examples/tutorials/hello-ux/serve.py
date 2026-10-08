#!/usr/bin/env python3
# serve.py — serves the web build with the two headers a UXKit page needs.
#
# UXKit's run loop is a worker that shares memory with the page, and a browser
# allows that only on a page served with cross-origin isolation: the
# Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers below.
# A plain file:// page, or a server without them, shows an empty canvas.
#
#   python3 serve.py [port]      default 8000, then open http://localhost:8000/
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
print(f"serving on http://localhost:{port}/")
http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()
