// echo_server.xc — the native half of run.sh: one client, every message
// echoed back, until the client closes.
#import "Stdio.xc"
#import "WebSocket.xc"
i32 main(i32 argc, u8** argv)
    {
    u16 port = (u16)0;
    u8* a = argv[1];
    for (u32 i = (u32)0; a[i] != (u8)0; i = i + (u32)1)
        port = port * (u16)10 + (u16)(a[i] - (u8)'0');
    WebSocketServer* server;
    try
        {
        server = WebSocketServer.listen(port);
        }
    catch (SocketError e)
        {
        Stdio.printf("cannot listen\n");
        return (i32)1;
        }
    Stdio.printf("listening\n");
    WebSocket* c = server.accept((i32)20000);
    if (c == 0)
        return (i32)1;
    for (;;)
        {
        WebSocketMessage* m = c.receive((i32)20000);
        if (m == 0)
            break;
        if (m.isText())
            c.sendText(m.text());
        else
            c.sendData(m.data());
        }
    return 0;
    }
