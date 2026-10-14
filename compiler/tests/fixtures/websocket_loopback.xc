//xtc-flags: target=arm64
// websocket_loopback.xc — a WebSocket server and a client in one process: the
// handshake (path and headers seen by the server), a text message echoed, a
// binary one long enough for the 64-bit length form, a ping (answered
// inside receive), and the closing handshake with its code and reason.
#import "Stdio.xc"
#import "WebSocket.xc"
#import "Thread.xc"
class Echo
    {
    WebSocketServer* server;
    u32 got;
    void run(void)
        {
        WebSocket* c = server.accept((i32)5000);
        if (c == 0)
            {
            Stdio.printf("server: no client\n");
            return;
            }
        Stdio.printf("server: path %s, key %d, version %s\n", c.path().cString(),
                     (i32)(c.header(String.withCString("Sec-WebSocket-Key")) != 0 ? 1 : 0),
                     c.header(String.withCString("sec-websocket-version")).cString());
        for (;;)
            {
            WebSocketMessage* m = c.receive((i32)5000);
            if (m == 0)
                break;
            got++;
            if (m.isText())
                c.sendText(m.text());
            else
                c.sendData(m.data());
            }
        Stdio.printf("server: %u messages, open %d, close %u '%s'\n", got, (i32)(c.isOpen() ? 1 : 0),
                     (u32)c.closeCode(), c.closeReason().cString());
        }
    }
i32 main(void)
    {
    Echo* e = new Echo();
    e.got = (u32)0;
    u32 port = (u32)0;
    for (u32 p = (u32)47227; p < (u32)47237 && port == (u32)0; p++)
        {
        try
            {
            e.server = WebSocketServer.listen((u16)p);
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
        ws = WebSocket.connect(Url.withString(String.withFormat("ws://127.0.0.1:%lu/echo?x=1", port)));
        }
    catch (WebSocketError err)
        {
        Stdio.printf("client: %s\n", err.message().cString());
        return (i32)1;
        }
    Stdio.printf("client: open %d\n", (i32)(ws.isOpen() ? 1 : 0));
    ws.sendText(String.withCString("hello"));
    WebSocketMessage* m = ws.receive((i32)5000);
    Stdio.printf("client: text %d '%s'\n", (i32)(m != 0 && m.isText() ? 1 : 0), m != 0 ? m.text().cString() : "");
    Data* big = Data.withLength((u32)70000);
    for (u32 i = (u32)0; i < (u32)70000; i++)
        big.bytes()[i] = (u8)(i * (u32)7);
    ws.sendData(big);
    m = ws.receive((i32)5000);
    bool same = m != 0 && !m.isText() && m.data().length() == (u32)70000;
    for (u32 i = (u32)0; same && i < (u32)70000; i++)
        same = m.data().bytes()[i] == (u8)(i * (u32)7);
    Stdio.printf("client: binary %d\n", (i32)(same ? 1 : 0));
    ws.ping();
    ws.sendText(String.withCString("after the ping"));
    m = ws.receive((i32)5000);
    Stdio.printf("client: text %d '%s'\n", (i32)(m != 0 && m.isText() ? 1 : 0), m != 0 ? m.text().cString() : "");
    Stdio.printf("client: nothing more %d\n", (i32)(ws.receive((i32)100) == 0 ? 1 : 0));
    ws.closeWith((u16)1000, String.withCString("done"));
    t.join();                   // the server's last line comes first
    Stdio.printf("client: open %d, close %u\n", (i32)(ws.isOpen() ? 1 : 0), (u32)ws.closeCode());
    e.server.close();
    return (i32)0;
    }
