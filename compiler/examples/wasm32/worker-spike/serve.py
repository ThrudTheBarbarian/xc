#!/usr/bin/env python3
# Serves the spike with the COOP/COEP headers SharedArrayBuffer requires.
# Usage: python3 serve.py [port]   (default 8000), then open localhost:<port>
import http.server, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()
