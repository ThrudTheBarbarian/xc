import http.server, sys, functools
iso = sys.argv[2] == "1"
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        if iso:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[3])).serve_forever()
