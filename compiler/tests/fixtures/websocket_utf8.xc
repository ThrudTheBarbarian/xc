//xtc-flags: target=arm64
// websocket_utf8.xc — a text frame whose payload is not UTF-8 fails the
// connection with 1007 (RFC 6455 §8.1), on the side that receives it; the
// sender's next receive sees the close. Binary frames carry anything.
#import "Stdio.xc"
#import "WebSocket.xc"
#import "Thread.xc"
class Sink
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
        Stdio.printf("server: binary %d\n", (i32)(m != 0 && !m.isText() ? 1 : 0));
        m = c.receive((i32)5000);
        Stdio.printf("server: message %d, open %d, close %u\n", (i32)(m != 0 ? 1 : 0),
                     (i32)(c.isOpen() ? 1 : 0), (u32)c.closeCode());
        }
    }
i32 main(void)
    {
    Sink* s = new Sink();
    u32 port = (u32)0;
    for (u32 p = (u32)47240; p < (u32)47250 && port == (u32)0; p++)
        {
        try
            {
            s.server = WebSocketServer.listen((u16)p);
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
    Thread* t = Thread.spawn(&s.run);
    WebSocket* ws;
    try
        {
        ws = WebSocket.connect(Url.withString(String.withFormat("ws://127.0.0.1:%lu/", port)));
        }
    catch (WebSocketError err)
        {
        Stdio.printf("client: %s\n", err.message().cString());
        return (i32)1;
        }
    u8 bad[3];
    bad[0] = (u8)0xC3; bad[1] = (u8)0x28; bad[2] = (u8)0xFF;    // a lead byte with no continuation, then a byte UTF-8 never has
    ws.sendBytes(&bad[0], (u32)3);                             // binary: fine
    ws._send((u8)1, &bad[0], (u32)3);                          // text: not UTF-8
    WebSocketMessage* m = ws.receive((i32)5000);
    t.join();
    Stdio.printf("client: message %d, open %d, close %u\n", (i32)(m != 0 ? 1 : 0),
                 (i32)(ws.isOpen() ? 1 : 0), (u32)ws.closeCode());
    s.server.close();
    return (i32)0;
    }
