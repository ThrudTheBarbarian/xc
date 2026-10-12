// Net.xc — talking to the contribution server.
//
// Two calls the visualiser needs: fetch the corpus (an ordinary GET), and
// send one contribution up (a POST).  Both go over https.  The standard Http
// client sends only GET, so the POST is written onto Http's own connection,
// with the same TLS layer.  The server is the project's unless
// XC_BENCH_SERVER names another; nothing here names a path inside the tree.
//
// TLS verifies the server against a CA bundle: the system's on macOS and
// Linux, and on Windows, which keeps its certificates in a store and not in a
// file, the cacert.pem the archive carries beside the program.
//
// Imported by Visualiser.xc.

#import "Model.xc"
#import "Http.xc"
#import "HttpTls.xc"
#import "Url.xc"

String* _net_error = (String*)0;
String* _net_dir = (String*)0;
bool    _net_tls = false;

class Net
    {
    // Where contributions live: the site's bench area, or the server named by
    // XC_BENCH_SERVER (a self-hosted corpus, or a local one for testing).
    static String* server(void)
        {
        String* s = Platform.env(String.withCString("XC_BENCH_SERVER"));
        if (s == (String*)0 || s.isEmpty()) { return String.withCString("https://compile-xc.org"); }
        return s;
        }
    static String* submitUrl(void) { return String.withFormat("%s/benchmarks/submit.php", server().cString()); }
    static String* corpusUrl(void) { return String.withFormat("%s/benchmarks/corpus.php", server().cString()); }

    // What the last call that returned null ran into.
    static String* lastError(void)
        {
        return _net_error == (String*)0 ? String.withCString("unknown error") : _net_error;
        }

    // The program's own path (argv[0]), so a CA bundle beside it is found.
    static void setProgramPath(String* path)
        {
        _net_dir = path == (String*)0 ? (String*)0 : path.deletingLastPathComponent();
        }

    // Register https once: the system's CA bundle, or cacert.pem beside the
    // program or in the current directory.  False when there is none.
    static bool installTls(void)
        {
        if (_net_tls) { return true; }
        _net_tls = HttpTls.install();
        if (!_net_tls && _net_dir != (String*)0 && !_net_dir.isEmpty())
            {
            String* beside = _net_dir.appendingPathComponent(String.withCString("cacert.pem"));
            if (Files.exists(beside)) { _net_tls = HttpTls.installWithBundle(beside); }
            }
        if (!_net_tls && Files.exists(String.withCString("cacert.pem")))
            {
            _net_tls = HttpTls.installWithBundle(String.withCString("cacert.pem"));
            }
        if (!_net_tls)
            {
            _net_error = String.withCString("no CA bundle for https (put cacert.pem beside the program)");
            }
        return _net_tls;
        }

    // A blocking GET: the body text, or null (see lastError).
    static String* get(String* url)
        {
        if (!installTls()) { return (String*)0; }
        HttpResponse* r = Http.get(Url.withString(url));
        if (r == (HttpResponse*)0)
            {
            _net_error = String.withCString("no response");
            return (String*)0;
            }
        if (r.status() != 200)
            {
            _net_error = r.error() != (String*)0 ? r.error()
                       : String.withFormat("the server answered %d", (i32)r.status());
            return (String*)0;
            }
        return r.bodyString();
        }

    // POST `body` (JSON text) to `url`: the parsed response, whatever its
    // status, or null when no response came back (see lastError).
    static HttpResponse* post(String* url, String* body)
        {
        Url* u = Url.withString(url);
        String* host = u.host();
        if (host == (String*)0 || host.isEmpty())
            {
            _net_error = String.withCString("no host in the URL");
            return (HttpResponse*)0;
            }
        bool secure = u.scheme() != (String*)0 && u.scheme().equalsIgnoringCase(BHelp.S((u8*)"https"));
        if (secure && !installTls()) { return (HttpResponse*)0; }
        u32 port = u.port();
        if (port == 0) { port = secure ? 443 : 80; }
        _HttpSocket* sock = new _HttpSocket();
        if (!sock.open(host, port))
            {
            _net_error = sock.error();
            return (HttpResponse*)0;
            }
        if (secure && !sock.startSecure(_http_secure, host))
            {
            _net_error = sock.error();
            sock.disconnect();
            return (HttpResponse*)0;
            }
        String* path = u.path();
        if (path == (String*)0 || path.isEmpty()) { path = String.withCString("/"); }
        String* req = String.withCString("POST ");
        req.append(path);
        req.appendCString(" HTTP/1.1\r\nHost: ");
        req.append(host);
        req.appendCString("\r\nUser-Agent: xc-benchviz/1\r\nContent-Type: application/json\r\nContent-Length: ");
        req.append(String.withU32(body.byteLength()));
        req.appendCString("\r\nConnection: close\r\n\r\n");
        req.append(body);
        if (!sock.sendAll(req.cString(), req.byteLength()))
            {
            _net_error = String.withCString("the request could not be sent");
            sock.disconnect();
            return (HttpResponse*)0;
            }
        Data* raw = new Data();
        u8 buf[8192];
        while (true)
            {
            i32 got = sock.receive(buf, 8192);
            if (got <= 0) { break; }
            raw.appendBytes(buf, got);
            }
        sock.disconnect();
        if (raw.length() == 0)
            {
            _net_error = String.withCString("the server sent nothing back");
            return (HttpResponse*)0;
            }
        return Http._parse(u, raw);
        }
    }
