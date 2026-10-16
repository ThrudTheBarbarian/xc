// wss_loopback.xc — a `wss:` WebSocket server and client in one process: the
// server has a self-signed certificate it makes here (CN=localhost), the
// client verifies against that same file as its bundle, and a text message
// goes round and comes back; then the closing handshake over TLS.
#import "Stdio.xc"
#import "WebSocket.xc"
#import "HttpTls.xc"
#import "Thread.xc"
#import "Files.xc"
#import "Process.xc"
class Echo
    {
    WebSocketServer* server;
    void run(void)
        {
        WebSocket* c = server.accept((i32)5000);
        if (c == 0)
            {
            Stdio.printf("server: no client\n");
            return;
            }
        WebSocketMessage* m = c.receive((i32)5000);
        if (m != 0 && m.isText())
            c.sendText(String.withFormat("echo: %s", m.text().cString()));
        m = c.receive((i32)5000);
        Stdio.printf("server: open %d, close %u '%s'\n", (i32)(c.isOpen() ? 1 : 0),
                     (u32)c.closeCode(), c.closeReason().cString());
        }
    }
i32 main(void)
    {
    Array* av = Process.arguments();
    String* dir = av.count() > (u32)1 ? (String*)av.get((u32)1) : String.withCString(".");
    String* cert = dir.appending(String.withCString("/cert.pem"));
    String* key = dir.appending(String.withCString("/key.pem"));
    if (xctls_make_self_signed(cert.cString(), key.cString(), "localhost") != (i32)0)
        {
        Stdio.printf("no certificate\n");
        return (i32)1;
        }
    HttpSecureAcceptor* tls = HttpTls.serverWith(cert, key);
    if (tls == 0 || !HttpTls.installWithBundle(cert))
        {
        Stdio.printf("no tls\n");
        return (i32)1;
        }
    Echo* e = new Echo();
    u32 port = (u32)0;
    for (u32 p = (u32)47260; p < (u32)47270 && port == (u32)0; p++)
        {
        try
            {
            e.server = WebSocketServer.listenSecure((u16)p, tls);
            port = p;
            }
        catch (SocketError err)
            {
            }
        }
    if (port == (u32)0)
        {
        Stdio.printf("no port to listen on\n");
        return (i32)1;
        }
    Thread* t = Thread.spawn(&e.run);
    WebSocket* ws;
    try
        {
        ws = WebSocket.connect(Url.withString(String.withFormat("wss://localhost:%lu/secure", port)));
        }
    catch (WebSocketError err)
        {
        Stdio.printf("client: %s\n", err.message().cString());
        return (i32)1;
        }
    Stdio.printf("client: open %d\n", (i32)(ws.isOpen() ? 1 : 0));
    ws.sendText(String.withCString("over tls"));
    WebSocketMessage* m = ws.receive((i32)5000);
    Stdio.printf("client: text %d '%s'\n", (i32)(m != 0 && m.isText() ? 1 : 0), m != 0 ? m.text().cString() : "");
    ws.closeWith((u16)1000, String.withCString("bye"));
    t.join();
    Stdio.printf("client: open %d, close %u\n", (i32)(ws.isOpen() ? 1 : 0), (u32)ws.closeCode());
    e.server.close();
    return (i32)0;
    }
