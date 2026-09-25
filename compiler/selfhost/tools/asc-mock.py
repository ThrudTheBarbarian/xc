#!/usr/bin/env python3
# asc-mock.py — a local stand-in for App Store Connect and Apple's CA
# download, for sign-diff.sh. It serves over TLS with a test CA, so the
# signer's whole Route 1 path runs: DNS, TCP, TLS verification, the ES256 JWT,
# the CSR, the JSON, the chunked decoding and the PEM bundle it writes.
#
#   asc-mock.py <dir> <port-file>
#
# <dir> holds ca.crt/ca.key (the test CA, served as the WWDR intermediate),
# server.crt/server.key, api.pub (the API key's public half), profile.bin (a
# .mobileprovision) and kid/iss (the expected key id and issuer). The port it
# listens on is written to <port-file>. Each check it makes is appended to
# <dir>/log as "ok <what>" or "FAIL <what>"; the harness reads that.
import base64, http.server, json, os, ssl, subprocess, sys, tempfile, time

D = sys.argv[1]
LOG = os.path.join(D, "log")


def log(ok, what):
    with open(LOG, "a") as f:
        f.write(("ok " if ok else "FAIL ") + what + "\n")


def rd(name):
    with open(os.path.join(D, name)) as f:
        return f.read().strip()


def b64url_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def der_int(b):
    b = b.lstrip(b"\0") or b"\0"
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\x02" + bytes([len(b)]) + b


def check_jwt(auth):
    if not auth or not auth.startswith("Bearer "):
        log(False, "jwt: no bearer token")
        return False
    tok = auth[7:]
    parts = tok.split(".")
    if len(parts) != 3:
        log(False, "jwt: not three parts")
        return False
    hdr = json.loads(b64url_dec(parts[0]))
    cl = json.loads(b64url_dec(parts[1]))
    good = (hdr.get("alg") == "ES256" and hdr.get("typ") == "JWT" and hdr.get("kid") == rd("kid")
            and cl.get("iss") == rd("iss") and cl.get("aud") == "appstoreconnect-v1"
            and cl.get("exp", 0) - cl.get("iat", 0) == 1200 and abs(cl.get("iat", 0) - time.time()) < 300)
    if not good:
        log(False, "jwt: header/claims %r %r" % (hdr, cl))
        return False
    sig = b64url_dec(parts[2])
    body = der_int(sig[:32]) + der_int(sig[32:])
    with tempfile.TemporaryDirectory() as t:
        open(os.path.join(t, "in"), "w").write(parts[0] + "." + parts[1])
        open(os.path.join(t, "sig"), "wb").write(b"\x30" + bytes([len(body)]) + body)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", os.path.join(D, "api.pub"),
                            "-signature", os.path.join(t, "sig"), os.path.join(t, "in")],
                           capture_output=True)
    ok = r.returncode == 0
    log(ok, "jwt: ES256 signature verifies")
    return ok


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body, chunked=False, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Connection", "close")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 100):
                c = body[i:i + 100]
                self.wfile.write(b"%x;ext=1\r\n" % len(c) + c + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        self.close_connection = True

    def api_host(self):
        ok = self.headers.get("Host") == "api.appstoreconnect.apple.com"
        log(ok, "host header %s" % self.headers.get("Host"))
        return ok

    def do_GET(self):
        if self.path == "/certificateauthority/AppleWWDRCAG3.cer":
            log(self.headers.get("Host") == "www.apple.com", "wwdr host header")
            der = subprocess.run(["openssl", "x509", "-in", os.path.join(D, "ca.crt"), "-outform", "DER"],
                                 capture_output=True).stdout
            return self.send(200, der, ctype="application/pkix-cert")
        if not self.api_host() or not check_jwt(self.headers.get("Authorization")):
            return self.send(401, b'{"errors":[{"status":"401","code":"NOT_AUTHORIZED"}]}')
        if self.path == "/v1/certificates?limit=200":
            data = [{"id": "CERT%02d" % i, "type": "certificates",
                     "attributes": {"certificateType": t, "displayName": "Mock é %d" % i}}
                    for i, t in enumerate(["DEVELOPMENT", "DISTRIBUTION", "IOS_DEVELOPMENT"])]
            return self.send(200, json.dumps({"data": data}).encode(), chunked=True)
        if self.path == "/v1/profiles?limit=200":
            prof = base64.b64encode(open(os.path.join(D, "profile.bin"), "rb").read()).decode()
            data = [{"id": "P0", "attributes": {"name": "Other Profile", "profileContent": "AAAA"}},
                    {"id": "P1", "attributes": {"name": "Mock Team Profile", "profileContent": prof}}]
            return self.send(200, json.dumps({"data": data}, indent=1).encode(), chunked=True)
        self.send(404, b'{"errors":[{"status":"404"}]}')

    def do_DELETE(self):
        if not self.api_host() or not check_jwt(self.headers.get("Authorization")):
            return self.send(401, b"{}")
        if self.path == "/v1/certificates/CERT01":
            log(True, "revoke CERT01")
            self.send_response(204)
            self.send_header("Connection", "close")
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True
            return
        self.send(409, b'{"errors":[{"status":"409","detail":"no such certificate"}]}')

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        if not self.api_host() or not check_jwt(self.headers.get("Authorization")):
            return self.send(401, b"{}")
        log(self.headers.get("Content-Type") == "application/json", "post content-type")
        if self.path != "/v1/certificates":
            return self.send(404, b"{}")
        j = json.loads(body)
        a = j["data"]["attributes"]
        log(j["data"]["type"] == "certificates" and a["certificateType"] == "DEVELOPMENT", "post payload")
        with tempfile.TemporaryDirectory() as t:
            csr = os.path.join(t, "csr")
            open(csr, "w").write(a["csrContent"])
            r = subprocess.run(["openssl", "req", "-in", csr, "-verify", "-noout", "-subject"],
                               capture_output=True, text=True)
            log(r.returncode == 0 and "xcc Route 1" in r.stdout, "csr verifies, CN xcc Route 1")
            cert = os.path.join(t, "cert")
            subprocess.run(["openssl", "x509", "-req", "-in", csr, "-CA", os.path.join(D, "ca.crt"),
                            "-CAkey", os.path.join(D, "ca.key"), "-set_serial", "4660", "-days", "30",
                            "-outform", "DER", "-out", cert], capture_output=True)
            der = open(cert, "rb").read()
        out = {"data": {"type": "certificates", "id": "NEW1",
                        "attributes": {"certificateContent": base64.b64encode(der).decode()}}}
        self.send(201, json.dumps(out).encode())


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(D, "server.crt"), os.path.join(D, "server.key"))
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(sys.argv[2], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
