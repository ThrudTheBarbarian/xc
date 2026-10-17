//xtc-flags: target=arm64
// EventQueue: a wake from another thread ends a wait, a wake while nobody
// waits is kept for the next wait, a wait with nothing to wake it times out,
// and a watched socket with bytes to read ends one.
#import "Stdio.xc"
#import "Thread.xc"
#import "Socket.xc"
#import "EventQueue.xc"

class Waker : Object
    {
    EventQueue* q;
    bool sent;
    void run(void)
        {
        Thread.sleepMs((u32)50);
        sent = true;
        q.wake();
        }
    }

i32 main(void)
    {
    EventQueue* q = EventQueue.make();
    if (q == (EventQueue*)0)
        {
        Stdio.printf("no event queue\n");
        return 1;
        }
    // A wake from another thread.
    Waker* w = new Waker();
    w.q = q;
    Thread* t = Thread.spawn(&w.run);
    bool woke = q.wait((i32)-1);
    t.join();
    Stdio.printf("woken by a thread: %s\n", woke && w.sent ? "yes" : "no");
    // Drained: nothing more is pending.
    Stdio.printf("drained: %s\n", q.wait((i32)0) ? "no" : "yes");
    // Kept while nobody waits.
    q.wake();
    Stdio.printf("wake kept: %s\n", q.wait((i32)0) ? "yes" : "no");
    // Nothing to wake it.
    Stdio.printf("timed out: %s\n", q.wait((i32)50) ? "no" : "yes");
    // A socket with bytes to read.
    try
        {
        u16 port = (u16)47950;
        Socket* server = (Socket*)0;
        while (server == (Socket*)0 && port < (u16)48000)
            {
            try { server = Socket.listen(port); }
            catch (e) { port = port + (u16)1; }
            }
        Socket* c = Socket.connect(String.withCString("127.0.0.1"), port);
        Socket* s = server.accept((i32)2000);
        q.watch(s.fd());
        woke = q.wait((i32)100);
        Stdio.printf("idle socket: %s\n", woke ? "woke" : "quiet");
        c.writeString(String.withCString("x"));
        woke = q.wait((i32)5000);
        Stdio.printf("socket readable: %s\n", woke ? "yes" : "no");
        q.unwatch(s.fd());
        }
    catch (SocketError e)
        {
        Stdio.printf("socket: %s\n", e.message().cString());
        }
    q.close();
    Stdio.printf("closed: %s\n", q.wait((i32)0) ? "no" : "yes");
    return 0;
    }
