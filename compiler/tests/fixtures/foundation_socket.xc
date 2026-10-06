//xtc-na: xt6502 — Socket is not available on xt6502
// foundation_socket.xc — Socket's failures, which need no server: a refused
// port, a host that cannot be resolved, and a closed socket's reads and
// writes. (Exchanging bytes needs a peer; the corpus has none.)
#import "Foundation.xc"
#import "Socket.xc"

void tryConnect(u8* host, u16 port)
    {
    try
        {
        Socket* s = Socket.connect(String.withCString(host), port);
        Stdio.printf("connected to %s?\n", host);
        s.close();
        }
    catch (SocketError e)
        {
        // The message names the host; the platform without TCP says so.
        String* m = e.message();
        bool ok = m.hasPrefix(String.withCString("cannot connect to "))
                  || m.hasPrefix(String.withCString("cannot resolve the host"))
                  || m.equals(String.withCString("no TCP sockets on this platform"));
        Stdio.printf("refused: %d\n", (i32)(ok ? 1 : 0));
        }
    }

i32 main(void)
    {
    tryConnect("127.0.0.1", (u16)1);
    tryConnect("no-such-host.invalid", (u16)80);
    Socket* s = new Socket();
    u8 buf[4];
    Stdio.printf("closed: open %d, write %d, read %d, data null %d\n", (i32)(s.isOpen() ? 1 : 0),
                 (i32)(s.write(buf, (u32)4) ? 1 : 0), s.read(buf, (u32)4),
                 (i32)(s.readAvailable((u32)16) == 0 ? 1 : 0));
    s.close();
    return (i32)0;
    }
