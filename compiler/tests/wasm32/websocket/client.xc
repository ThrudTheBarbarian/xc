// client.xc — the wasm32 half of run.sh: connect, send before the socket is
// open (queued), take the echoes through deliver(), close, and see nil last.
#import "Stdio.xc"
#import "WebSocket.xc"
WebSocket* gWs;
u32 gGot;
void main(i32 argc, u8** argv)
    {
    gWs = WebSocket.connect(Url.withString(String.withCString("ws://127.0.0.1:PORT/")));
    gWs.sendText(String.withCString("hello"));
    Data* d = Data.withLength((u32)3);
    d.bytes()[0] = (u8)1; d.bytes()[1] = (u8)2; d.bytes()[2] = (u8)3;
    gWs.sendData(d);
    gGot = (u32)0;
    gWs.deliver(block void(WebSocketMessage* m) {
        if (m == 0)
            {
            Stdio.printf("closed %u '%s' after %u\n", (u32)gWs.closeCode(), gWs.closeReason().cString(), gGot);
            return;
            }
        gGot++;
        if (m.isText())
            Stdio.printf("text '%s'\n", m.text().cString());
        else
            Stdio.printf("binary %u bytes, last %u\n", m.data().length(), (u32)m.data().bytes()[m.data().length() - (u32)1]);
        if (gGot == (u32)2)
            gWs.closeWith((u16)1000, String.withCString("bye"));
        });
    Stdio.printf("main returns\n");
    }
