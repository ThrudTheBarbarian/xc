// Https.xc — one HTTPS request over the 3p tls module (Mbed TLS behind the
// tlsshim C glue, frameworks/3p/tls). The binary links tlsshim.o and the
// Mbed TLS static libraries; the certificate is verified against the host's
// CA bundle, and the hostname drives SNI and the name check.
//
// HTTP/1.1 with `Connection: close`: the whole response is read, the head
// split from the body, and a chunked body decoded.
//
// Two environment variables point it somewhere else, for testing against a
// local server: XCC_SIGN_HTTPS_CONNECT=<host>:<port> is where every request
// connects (SNI, verification and the Host header keep the real name), and
// XCC_SIGN_CA_FILE replaces the CA bundle.

#import "Foundation.xc"
#import "Files.xc"
#import "PlatformCore.xc"

// ── the tls module ──────────────────────────────────────────────────────────
pointer xt_tls_client_new(u8* caPath);
pointer xt_tls_connect(pointer client, i32 fd, u8* hostname);
i32 xt_tls_read(pointer conn, u8* buf, i32 len);
i32 xt_tls_write(pointer conn, u8* buf, i32 len);
void xt_tls_close(pointer conn);

// ── libc ────────────────────────────────────────────────────────────────────
// struct addrinfo: the two pointers after ai_addrlen are in the opposite order
// on Linux (ai_addr, ai_canonname) and the BSDs (ai_canonname, ai_addr).
struct AddrInfo
    {
    i32 flags;
    i32 family;
    i32 socktype;
    i32 proto;
    u32 addrlen;
    u32 pad;
    pointer first;
    pointer second;
    pointer next;
    }
i32 getaddrinfo(u8* node, u8* service, pointer hints, pointer* res);
void freeaddrinfo(pointer res);
i32 socket(i32 domain, i32 type, i32 proto);
i32 connect(i32 fd, pointer addr, u32 len);
i32 close(i32 fd);

class HttpsResponse
    {
    i32 _status; // -1: no response; see why()
    String* _why;
    Array* _hdrNames;  // lower-cased
    Array* _hdrValues;
    Data* _body;
    void init(void)
        {
        _status = (i32)-1;
        _hdrNames = new Array();
        _hdrValues = new Array();
        _body = Data.withCapacity((u32)0);
        }
    i32 status(void)
        {
        return _status;
        }
    String* why(void)
        {
        return _why;
        }
    Data* body(void)
        {
        return _body;
        }
    String* bodyText(void)
        {
        return String.withBytes(_body.bytes(), _body.length());
        }
    String* header(string lowerName)
        {
        String* n = String.withCString(lowerName);
        for (u32 i = (u32)0; i < _hdrNames.count(); i = i + (u32)1)
            if (((String*)_hdrNames.get(i)).equals(n))
                return (String*)_hdrValues.get(i);
        return (String*)0;
        }
    }

class Https
    {
    void init(void)
        {
        }

    // The host's CA bundle, or null.
    static String* caBundle(void)
        {
        String* forced = Platform.env(String.withCString("XCC_SIGN_CA_FILE"));
        if (forced != (String*)0 && forced.byteLength() > (u32)0)
            return forced;
        Array* c = new Array();
        c.add((Object*)String.withCString("/etc/ssl/cert.pem"));                  // macOS, BSD
        c.add((Object*)String.withCString("/etc/ssl/certs/ca-certificates.crt")); // Debian/Ubuntu
        c.add((Object*)String.withCString("/etc/pki/tls/certs/ca-bundle.crt"));   // RHEL/Fedora
        for (u32 i = (u32)0; i < c.count(); i = i + (u32)1)
            if (Files.exists((String*)c.get(i)))
                return (String*)c.get(i);
        return (String*)0;
        }

    // A connected TCP socket to host:port, or -1.
    static i32 dial(String* host, String* port)
        {
        AddrInfo hints;
        hints.flags = (i32)0;
        hints.family = (i32)0;
        hints.socktype = (i32)1; // SOCK_STREAM
        hints.proto = (i32)0;
        hints.addrlen = (u32)0;
        hints.pad = (u32)0;
        hints.first = (pointer)0;
        hints.second = (pointer)0;
        hints.next = (pointer)0;
        pointer res = (pointer)0;
        if (getaddrinfo(host.cString(), port.cString(), (pointer)&hints, &res) != (i32)0 || res == (pointer)0)
            return (i32)-2;
        i32 fd = (i32)-1;
        pointer ai = res;
        while (ai != (pointer)0)
            {
            AddrInfo* a = (AddrInfo*)ai;
#if ARCH_x86_64
            pointer addr = a.first;
#else
            pointer addr = a.second;
#endif
            i32 s = socket(a.family, a.socktype, a.proto);
            if (s >= (i32)0)
                {
                if (connect(s, addr, a.addrlen) == (i32)0)
                    {
                    fd = s;
                    break;
                    }
                close(s);
                }
            ai = a.next;
            }
        freeaddrinfo(res);
        return fd;
        }

    static void decodeChunked(Data* src, Data* out)
        {
        u32 n = src.length();
        u32 i = (u32)0;
        while (i < n)
            {
            u32 j = i;
            while (j + (u32)1 < n && !(src.byteAt(j) == (u8)13 && src.byteAt(j + (u32)1) == (u8)10))
                j = j + (u32)1;
            if (j + (u32)1 >= n)
                break;
            u32 sz = (u32)0;
            for (u32 k = i; k < j; k = k + (u32)1)
                {
                u8 c = src.byteAt(k);
                if (c == (u8)';')
                    break;
                u32 d;
                if (c >= (u8)'0' && c <= (u8)'9')
                    d = (u32)(c - (u8)'0');
                else if (c >= (u8)'a' && c <= (u8)'f')
                    d = (u32)(c - (u8)'a') + (u32)10;
                else if (c >= (u8)'A' && c <= (u8)'F')
                    d = (u32)(c - (u8)'A') + (u32)10;
                else
                    continue;
                sz = sz * (u32)16 + d;
                }
            i = j + (u32)2;
            if (sz == (u32)0)
                break;
            if (i + sz > n)
                sz = n - i;
            out.appendBytes(src.bytes() + i, sz);
            i = i + sz;
            if (i + (u32)1 < n && src.byteAt(i) == (u8)13 && src.byteAt(i + (u32)1) == (u8)10)
                i = i + (u32)2;
            }
        }

    // One request. `headers` is "Name: value" lines, each ending CR LF;
    // `body` may be null.
    static HttpsResponse* request(string method, String* host, String* path, String* headers, Data* body)
        {
        HttpsResponse* r = new HttpsResponse();
        String* dialHost = host;
        String* dialPort = String.withCString("443");
        String* redirect = Platform.env(String.withCString("XCC_SIGN_HTTPS_CONNECT"));
        if (redirect != (String*)0 && redirect.byteLength() > (u32)0)
            {
            u32 colon = redirect.lastIndexOfByte((u8)':');
            if (colon != String.notFound())
                {
                dialHost = redirect.substringBytes((u32)0, colon);
                dialPort = redirect.substringFromByte(colon + (u32)1);
                }
            else
                dialHost = redirect;
            }
        i32 fd = Https.dial(dialHost, dialPort);
        if (fd == (i32)-2)
            {
            r._why = String.withCString("DNS lookup failed for ");
            r._why.append(host);
            return r;
            }
        if (fd < (i32)0)
            {
            r._why = String.withCString("connect failed to ");
            r._why.append(host);
            return r;
            }
        String* ca = Https.caBundle();
        pointer client = xt_tls_client_new(ca != (String*)0 ? ca.cString() : (u8*)0);
        if (client == (pointer)0)
            {
            close(fd);
            r._why = String.withCString("TLS client init failed");
            return r;
            }
        pointer conn = xt_tls_connect(client, fd, host.cString());
        if (conn == (pointer)0)
            {
            close(fd);
            r._why = String.withCString("TLS handshake / certificate verification failed");
            return r;
            }

        String* req = String.withCString(method);
        req.appendCString(" ");
        req.append(path);
        req.appendCString(" HTTP/1.1\r\nHost: ");
        req.append(host);
        req.appendCString("\r\nConnection: close\r\n");
        if (headers != (String*)0)
            req.append(headers);
        if (body != (Data*)0)
            {
            req.appendCString("Content-Length: ");
            req.append(String.withU32(body.length()));
            req.appendCString("\r\n");
            }
        req.appendCString("\r\n");
        Data* out = Data.withString(req);
        if (body != (Data*)0)
            out.append(body);
        xt_tls_write(conn, out.bytes(), (i32)out.length());

        Data* raw = Data.withCapacity((u32)16384);
        u8* buf = new u8[16384];
        while (true)
            {
            i32 got = xt_tls_read(conn, buf, (i32)16384);
            if (got <= (i32)0)
                break;
            raw.appendBytes(buf, (u32)got);
            }
        delete buf;
        xt_tls_close(conn);
        close(fd);

        u32 n = raw.length();
        u32 hdrEnd = (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i + (u32)3 < n; i = i + (u32)1)
            if (raw.byteAt(i) == (u8)13 && raw.byteAt(i + (u32)1) == (u8)10 && raw.byteAt(i + (u32)2) == (u8)13 && raw.byteAt(i + (u32)3) == (u8)10)
                {
                hdrEnd = i;
                break;
                }
        if (hdrEnd == (u32)$FFFFFFFF)
            {
            r._why = String.withCString("malformed HTTP response");
            return r;
            }
        String* head = String.withBytes(raw.bytes(), hdrEnd);
        Array* lines = head.splitOnByte((u8)10);
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            if (line.hasSuffix(String.withCString("\r")))
                line = line.substringBytes((u32)0, line.byteLength() - (u32)1);
            if (i == (u32)0)
                {
                Array* sl = line.splitOnByte((u8)32);
                if (sl.count() >= (u32)2)
                    {
                    String* code = (String*)sl.get((u32)1);
                    i32 st = (i32)0;
                    for (u32 k = (u32)0; k < code.byteLength(); k = k + (u32)1)
                        {
                        u8 c = code.byteAt(k);
                        if (c < (u8)'0' || c > (u8)'9')
                            break;
                        st = st * (i32)10 + (i32)(c - (u8)'0');
                        }
                    r._status = st;
                    }
                continue;
                }
            u32 colon = line.indexOfByte((u8)':');
            if (colon == String.notFound())
                continue;
            r._hdrNames.add((Object*)line.substringBytes((u32)0, colon).lowercased());
            r._hdrValues.add((Object*)line.substringFromByte(colon + (u32)1).trimmed());
            }
        if (r._status < (i32)0)
            r._status = (i32)0;
        Data* bodyData = raw.subdataFrom(hdrEnd + (u32)4);
        String* te = r.header("transfer-encoding");
        if (te != (String*)0 && te.contains(String.withCString("chunked")))
            Https.decodeChunked(bodyData, r._body);
        else
            r._body = bodyData;
        return r;
        }
    }
