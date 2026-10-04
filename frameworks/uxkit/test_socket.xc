// test_socket.xc — UXSocket against a peer (the socket gate, run_socket.sh, starts an echo server on
// localhost and names its port in UX_SOCKET_PORT).  Connected by name, a write comes back whole
// through read, which never blocks: before the reply it answers 0, and waitReadable waits for it.  A
// refused port gives null with a reason, and when the peer closes, read answers -1.
#import <Stdio.xc>
#import "UXSocket.xc"
#import "UXString.xc"
#import <PlatformCore.xc>

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    i32 port = UXStr.toInt(Platform.env(String.withCString((u8*)"UX_SOCKET_PORT")).cString());
    if (port <= (i32)0)
        {
        Stdio.printf("SKIP: no UX_SOCKET_PORT\n");
        return;
        }
    UXSocket* s = UXSocket.connectTo((u8*)"localhost", port);
    ck((u8*)"connects to the peer by name", s != (UXSocket*)0 && s.isOpen());
    if (s == (UXSocket*)0)
        {
        Stdio.printf("FAIL: %s\n", UXSocket.lastError());
        return;
        }
    u8 buf[256];
    ck((u8*)"read before anything is sent answers 0 without blocking", s.read(&buf[0], (i32)256) == (i32)0);
    ck((u8*)"a write is sent whole", s.write((u8*)"hello, daemon\n", (i32)14));
    ck((u8*)"waitReadable sees the reply come", s.waitReadable((i32)3000));
    i32 got = (i32)0;
    for (i32 k = (i32)0; k < (i32)50 && got < (i32)14; k = k + (i32)1)
        {
        i32 n = s.read(&buf[got], (i32)256 - got);
        if (n < (i32)0)
            {
            break;
            }
        got = got + n;
        if (got < (i32)14)
            {
            s.waitReadable((i32)100);
            }
        }
    buf[got] = (u8)0;
    ck((u8*)"read gives back what was sent", got == (i32)14 && buf[0] == (u8)104 && buf[12] == (u8)110);
    // the server closes after "bye"
    s.write((u8*)"bye\n", (i32)4);
    i32 last = (i32)0;
    for (i32 k = (i32)0; k < (i32)50 && last >= (i32)0; k = k + (i32)1)
        {
        s.waitReadable((i32)100);
        last = s.read(&buf[0], (i32)256);
        }
    ck((u8*)"when the peer closes, read answers -1 and the socket is closed", last == (i32)-1 && !s.isOpen());
    ck((u8*)"...and a write after that fails", !s.write((u8*)"x", (i32)1));
    // the last reference to a closed socket going, and to one still open: both freed cleanly
    s = (UXSocket*)0;
    UXSocket* again = UXSocket.connectTo((u8*)"localhost", port);
    ck((u8*)"a second connection", again != (UXSocket*)0);
    again = (UXSocket*)0;
    ck((u8*)"freeing a closed socket and an open one returns", true);
    UXSocket* none = UXSocket.connectTo((u8*)"localhost", port + (i32)1);
    ck((u8*)"a refused port gives null, with a reason", none == (UXSocket*)0 && UXSocket.lastError()[0] != (u8)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXSocket -- connect by name, whole writes, reads that never block, a closed peer seen\n" : "FAIL: %d\n", gFails);
    }
