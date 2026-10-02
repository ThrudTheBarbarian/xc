# coi_server.py -- a static server that is cross-origin isolated (COOP + COEP, so a page gets
# SharedArrayBuffer and the xcc loader's worker run loop works), and takes a POST /result that it
# writes to result.txt.  Usage: python3 coi_server.py <port>   (serves the working directory)
import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        open('result.txt', 'wb').write(self.rfile.read(n))
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
