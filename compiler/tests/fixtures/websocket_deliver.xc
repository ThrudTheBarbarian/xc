//xtc-flags: target=arm64
// websocket_deliver.xc — WebSocket.deliverOn: the client's messages arrive as
// callbacks on the main run loop, in order, with null last once the server
// closes. The server sends three texts and closes.
#import "Stdio.xc"
#import "WebSocket.xc"
#import "Thread.xc"
#import "RunLoop.xc"
class Sender
    {
    WebSocketServer* server;
    void run(void)
        {
        WebSocket* c = server.accept((i32)5000);
        if (c == 0)
            return;
        c.sendText(String.withCString("one"));
        c.sendText(String.withCString("two"));
        c.sendText(String.withCString("three"));
        c.closeWith((u16)1000, String.withCString("done"));
        }
    }
u32 gCount;
i32 main(void)
    {
    Sender* e = new Sender();
    u32 port = (u32)0;
    for (u32 p = (u32)47247; p < (u32)47257 && port == (u32)0; p++)
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
        ws = WebSocket.connect(Url.withString(String.withFormat("ws://127.0.0.1:%lu/", port)));
        }
    catch (WebSocketError err)
        {
        Stdio.printf("client: %s\n", err.message().cString());
        return (i32)1;
        }
    RunLoop* loop = RunLoop.main();
    gCount = (u32)0;
    ws.deliverOn(loop, block void(WebSocketMessage* m) {
        if (m == 0)
            {
            Stdio.printf("closed after %u\n", gCount);
            loop.stop();
            return;
            }
        gCount++;
        Stdio.printf("message %u: %s\n", gCount, m.text().cString());
        });
    loop.run();
    t.join();
    return 0;
    }
