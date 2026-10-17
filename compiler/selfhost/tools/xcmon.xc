// xcmon — the par monitor: the xcd daemons on this subnet, and the programs
// that send it their tile traces, drawn live in a browser page.
//
//     xcmon [-port N]           the page on port N (default 7480), its feed on N+1:
//                               open http://localhost:N/
//           [-trace N]          where programs send XC_PAR_TRACE=<this host>:N (default 7482)
//           [-pool NAME]        the daemons of this pool (as XC_PAR_POOL)
//           [-at host[:port],…] daemons to watch besides those found on the subnet
//
// The page is xcmon.html, beside this program. Each daemon is a node: its
// heartbeat says whether it takes work, the round trip and its memory; a
// program tracing here adds a node of its own with its devices, and each
// tile it has out sits on the device that has it. A daemon that stops
// answering stays on the page, greyed, until it is removed there.
#import "Stdio.xc"
#import "Par.xc"
#import "ParRemote.xc"
#import "Process.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Socket.xc"
#import "WebSocket.xc"
#import "Mdns.xc"
#import "Files.xc"
#import "Bundle.xc"

// One daemon, as the heartbeat sees it.
class MonNode : Object
    {
    String* key;            // host:port
    String* host;
    u16 port;
    String* name;           // the daemon's identity, kept while it is offline
    ParRemoteWorker* w;
    bool online;
    i64 lastSeen;           // us, when it last answered
    }

// One program tracing here: its block, its devices, its tiles out.
class MonProgram : Object
    {
    u32 id;
    String* block;
    Array* workers;         // String, by the trace's worker index
    Map* out;               // "<worker>" -> Number, the tiles it has out
    Map* done;              // "<worker>" -> Number, the tiles it has finished
    u32 run;
    i64 lastRunUs;
    bool live;
    }

Mutex* gLock;
Array* gNodes;
Array* gPrograms;
u32 gNextProgram;
String* gPool;

// The daemons: browse the subnet every few seconds, and beat every known one.
class MonPoller : Object
    {
    void run(void)
        {
        i64 lastBrowse = (i64)0 - (i64)10000000;
        while (true)
            {
            i64 now = ParDevice.nowUs();
            if (now - lastBrowse > (i64)5000000)
                {
                lastBrowse = now;
                Array* found = Mdns.browse(gPool.cString(), PAR_CACHE_VER, (i32)300);
                for (u32 i = (u32)0; i < found.count(); i = i + (u32)1)
                    {
                    MdnsService* svc = (MdnsService*)found.get(i);
                    MonPoller.add(svc.host, svc.port);
                    }
                }
            gLock.lock();
            Array* nodes = gNodes.copy();
            gLock.unlock();
            for (u32 i = (u32)0; i < nodes.count(); i = i + (u32)1)
                {
                MonNode* n = (MonNode*)nodes.get(i);
                bool ok = false;
                if (n.w == (ParRemoteWorker*)0 || n.w.dead() || !n.online)
                    {
                    // A fresh connection each time it is down: one that failed
                    // does not try again by itself.
                    n.w = new ParRemoteWorker(n.host, n.port);
                    ok = n.w.identity().byteLength() > (u32)0;
                    }
                else
                    ok = n.w.heartbeat();
                gLock.lock();
                n.online = ok;
                if (ok)
                    n.lastSeen = ParDevice.nowUs();
                gLock.unlock();
                }
            Thread.sleepMs((u32)1000);
            }
        }

    static void add(String* host, u16 port)
        {
        String* key = String.withString(host);
        key.appendByte((u8)':');
        key.append(String.withU32((u32)port));
        gLock.lock();
        bool have = false;
        for (u32 i = (u32)0; i < gNodes.count(); i = i + (u32)1)
            if (((MonNode*)gNodes.get(i)).key.equals(key))
                have = true;
        if (!have)
            {
            MonNode* n = new MonNode();
            n.key = key;
            n.host = String.withString(host);
            n.port = port;
            n.online = false;
            gNodes.add((Object*)n);
            }
        gLock.unlock();
        }
    }

// One program's trace stream: the header, then 48-byte records (ParTrace).
class MonTrace : Object
    {
    Socket* sock;
    MonProgram* prog;

    static i64 i64At(u8* p)
        {
        u64 v = (u64)0;
        for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
            v = v | ((u64)p[k] << ((u64)k * (u64)8));
        return (i64)v;
        }

    static String* textAt(u8* p)
        {
        u32 n = (u32)0;
        while (n < (u32)40 && p[n] != (u8)0)
            n = n + (u32)1;
        return String.withBytes(p, n);
        }

    void count(Map* m, String* w, i64 d)
        {
        Number* v = (Number*)m.get((Hashable*)w);
        i64 c = (v == (Number*)0 ? (i64)0 : v.asI64()) + d;
        m.set((Hashable*)w, (Object*)Number.with(c < (i64)0 ? (i64)0 : c));
        }

    String* workerName(u32 i)
        {
        if (i < prog.workers.count())
            return (String*)prog.workers.get(i);
        return String.withU32(i);
        }

    void run(void)
        {
        u8 head[16];
        if (!sock.readExact(&head[0], (u32)16, (i32)10000) || head[0] != (u8)'X' || head[1] != (u8)'C')
            {
            sock.close();
            return;
            }
        u8 r[48];
        while (sock.readExact(&r[0], (u32)48, (i32)-1))
            {
            u8 kind = r[0];
            u32 wi = (u32)r[1];
            u32 run = (u32)r[4] | ((u32)r[5] << (u32)8) | ((u32)r[6] << (u32)16) | ((u32)r[7] << (u32)24);
            gLock.lock();
            if (kind == (u8)1)
                {
                // A run starts: its workers are named next.
                prog.run = run;
                prog.workers = new Array();
                prog.out = new Map();
                }
            else if (kind == (u8)2)
                {
                while (prog.workers.count() <= wi)
                    prog.workers.add((Object*)String.withCString("?"));
                prog.workers.set(wi, (Object*)MonTrace.textAt(&r[8]));
                }
            else if (kind == (u8)3)
                prog.block = MonTrace.textAt(&r[8]);
            else if (kind == (u8)4)
                count(prog.out, workerName(wi), (i64)1);
            else if (kind == (u8)5)
                {
                count(prog.out, workerName(wi), (i64)-1);
                count(prog.done, workerName(wi), (i64)1);
                }
            else if (kind == (u8)7)
                {
                prog.lastRunUs = MonTrace.i64At(&r[8]);
                prog.out = new Map();
                }
            gLock.unlock();
            }
        gLock.lock();
        prog.live = false;
        gLock.unlock();
        sock.close();
        }
    }

class MonTraceListener : Object
    {
    Socket* ls;
    Array* keep;            // the stream readers, while they run
    void run(void)
        {
        while (true)
            {
            Socket* c = ls.accept((i32)-1);
            if (c == (Socket*)0)
                continue;
            MonProgram* p = new MonProgram();
            gLock.lock();
            gNextProgram = gNextProgram + (u32)1;
            p.id = gNextProgram;
            p.block = String.withCString("");
            p.workers = new Array();
            p.out = new Map();
            p.done = new Map();
            p.live = true;
            gPrograms.add((Object*)p);
            gLock.unlock();
            MonTrace* t = new MonTrace();
            t.sock = c;
            t.prog = p;
            keep.add((Object*)t);
            Thread* th = Thread.spawn(&t.run);
            th.detach();
            }
        }
    }

// The page itself, over plain HTTP: whatever the path, xcmon.html.
class MonPage : Object
    {
    Socket* ls;
    String* page;
    u16 feedPort;
    void run(void)
        {
        while (true)
            {
            Socket* c = ls.accept((i32)-1);
            if (c == (Socket*)0)
                continue;
            // The request: read to its blank line (or a second of nothing).
            Data* req = new Data();
            while (req.length() < (u32)8192 && c.waitReadable((i32)1000))
                {
                Data* d = c.readAvailable((u32)4096);
                if (d == (Data*)0 || d.length() == (u32)0)
                    break;
                req.append(d);
                String* sofar = String.withBytes(req.bytes(), req.length());
                if (sofar.contains(String.withCString("\r\n\r\n")))
                    break;
                }
            String* body = page.replacing(String.withCString("__FEED_PORT__"), String.withU32((u32)feedPort));
            String* resp = String.withCString("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ");
            resp.append(String.withU32(body.byteLength()));
            resp.appendCString("\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n");
            resp.append(body);
            c.writeString(resp);
            c.close();
            }
        }
    }

// The feed: every half second, the whole picture as JSON to every page open.
class MonFeed : Object
    {
    WebSocketServer* ws;
    Array* clients;
    Mutex* lock;
    void accepts(void)
        {
        while (true)
            {
            WebSocket* c = ws.accept((i32)-1);
            if (c == (WebSocket*)0)
                continue;
            lock.lock();
            clients.add((Object*)c);
            lock.unlock();
            }
        }
    void run(void)
        {
        Thread* a = Thread.spawn(&self.accepts);
        a.detach();
        while (true)
            {
            String* snap = MonFeed.snapshot();
            lock.lock();
            Array* keep = new Array();
            for (u32 i = (u32)0; i < clients.count(); i = i + (u32)1)
                {
                WebSocket* c = (WebSocket*)clients.get(i);
                if (c.isOpen() && c.sendText(snap))
                    keep.add((Object*)c);
                }
            clients = keep;
            lock.unlock();
            Thread.sleepMs((u32)500);
            }
        }

    static void jsonString(String* out, String* s)
        {
        out.appendByte((u8)'"');
        for (u32 i = (u32)0; s != (String*)0 && i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)'"' || c == (u8)'\\')
                out.appendByte((u8)'\\');
            if (c >= (u8)32)
                out.appendByte(c);
            }
        out.appendByte((u8)'"');
        }

    static void jsonCounts(String* out, Map* m, String* w)
        {
        Number* v = m == (Map*)0 ? (Number*)0 : (Number*)m.get((Hashable*)w);
        out.append(String.withI64(v == (Number*)0 ? (i64)0 : v.asI64()));
        }

    static String* snapshot(void)
        {
        String* out = String.withCString("{\"t\":");
        out.append(String.withI64(ParDevice.nowUs() / (i64)1000));
        out.appendCString(",\"nodes\":[");
        gLock.lock();
        for (u32 i = (u32)0; i < gNodes.count(); i = i + (u32)1)
            {
            MonNode* n = (MonNode*)gNodes.get(i);
            ParRemoteWorker* w = n.w;
            bool known = w != (ParRemoteWorker*)0;
            if (i > (u32)0)
                out.appendByte((u8)',');
            out.appendCString("{\"id\":");
            MonFeed.jsonString(out, n.key);
            out.appendCString(",\"name\":");
            if (known && w.identity().byteLength() > (u32)0)
                n.name = w.identity();
            MonFeed.jsonString(out, n.name != (String*)0 ? n.name : n.key);
            out.appendCString(",\"online\":");
            out.appendCString(n.online ? "true" : "false");
            out.appendCString(",\"available\":");
            out.appendCString(known && w.available() ? "true" : "false");
            out.appendCString(",\"queued\":");
            out.append(String.withU32(known ? w.queued() : (u32)0));
            out.appendCString(",\"rttUs\":");
            out.append(String.withI64(known ? w.rttUs() : (i64)0));
            out.appendCString(",\"vramFreeMb\":");
            out.append(String.withI64(known ? w.vramFree() >> (i64)20 : (i64)0));
            out.appendCString(",\"vramTotalMb\":");
            out.append(String.withI64(known ? w.vramTotal() >> (i64)20 : (i64)0));
            out.appendCString(",\"ramFreeMb\":");
            out.append(String.withI64(known ? w.ramFree() >> (i64)20 : (i64)0));
            out.appendCString(",\"ramTotalMb\":");
            out.append(String.withI64(known ? w.ramTotal() >> (i64)20 : (i64)0));
            out.appendCString("}");
            }
        out.appendCString("],\"programs\":[");
        for (u32 i = (u32)0; i < gPrograms.count(); i = i + (u32)1)
            {
            MonProgram* p = (MonProgram*)gPrograms.get(i);
            if (i > (u32)0)
                out.appendByte((u8)',');
            out.appendCString("{\"id\":");
            out.append(String.withU32(p.id));
            out.appendCString(",\"live\":");
            out.appendCString(p.live ? "true" : "false");
            out.appendCString(",\"block\":");
            MonFeed.jsonString(out, p.block);
            out.appendCString(",\"run\":");
            out.append(String.withU32(p.run));
            out.appendCString(",\"lastRunUs\":");
            out.append(String.withI64(p.lastRunUs));
            out.appendCString(",\"workers\":[");
            for (u32 k = (u32)0; k < p.workers.count(); k = k + (u32)1)
                {
                String* w = (String*)p.workers.get(k);
                if (k > (u32)0)
                    out.appendByte((u8)',');
                out.appendCString("{\"name\":");
                MonFeed.jsonString(out, w);
                out.appendCString(",\"out\":");
                MonFeed.jsonCounts(out, p.out, w);
                out.appendCString(",\"done\":");
                MonFeed.jsonCounts(out, p.done, w);
                out.appendCString("}");
                }
            out.appendCString("]}");
            }
        gLock.unlock();
        out.appendCString("]}");
        return out;
        }
    }

u16 numberArg(String* v)
{
    u32 n = (u32)0;
    for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
        n = n * (u32)10 + (u32)(v.byteAt(k) - (u8)'0');
    return (u16)n;
}

i32 main(void)
{
    u16 port = (u16)7480;
    u16 tracePort = (u16)7482;
    gPool = new String();
    gLock = new Mutex();
    gNodes = new Array();
    gPrograms = new Array();
    Array* at = new Array();
    Array* av = Process.arguments();
    for (u32 i = (u32)1; av != (Array*)0 && i < av.count(); i = i + (u32)1)
    {
        String* a = (String*)av.get(i);
        bool more = i + (u32)1 < av.count();
        if (a.equals(String.withCString("-port")) && more)
        {
            port = numberArg((String*)av.get(i + (u32)1));
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-trace")) && more)
        {
            tracePort = numberArg((String*)av.get(i + (u32)1));
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-pool")) && more)
        {
            gPool = (String*)av.get(i + (u32)1);
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-at")) && more)
        {
            String* v = (String*)av.get(i + (u32)1);
            u32 s = (u32)0;
            while (s < v.byteLength())
            {
                u32 e = s;
                while (e < v.byteLength() && v.byteAt(e) != (u8)',')
                    e = e + (u32)1;
                at.add((Object*)v.substringBytes(s, e - s));
                s = e + (u32)1;
            }
            i = i + (u32)1;
        }
        else
        {
            Stdio.printf("usage: xcmon [-port N] [-trace N] [-pool NAME] [-at host[:port],...]\n");
            return (i32)2;
        }
    }

    // The page, beside this program.
    String* exe = Bundle.executablePath();
    u32 cut = exe != (String*)0 ? exe.byteLength() : (u32)0;
    while (cut > (u32)0 && exe.byteAt(cut - (u32)1) != (u8)'/' && exe.byteAt(cut - (u32)1) != (u8)'\\')
        cut = cut - (u32)1;
    String* pagePath = Platform.env(String.withCString("XCMON_PAGE"));
    if (pagePath.byteLength() == (u32)0)
        pagePath = (cut > (u32)0 ? exe.substringBytes((u32)0, cut) : new String()).appending(String.withCString("xcmon.html"));
    String* page = Files.readText(pagePath);
    if (page == (String*)0)
    {
        Stdio.printf("xcmon: no page at %s (XCMON_PAGE names another)\n", pagePath.cString());
        return (i32)1;
    }

    for (u32 i = (u32)0; i < at.count(); i = i + (u32)1)
    {
        String* e = (String*)at.get(i);
        u32 colon = e.indexOfByte((u8)':');
        if (colon == (u32)$FFFFFFFF)
            MonPoller.add(e, (u16)PAR_REMOTE_PORT);
        else
            MonPoller.add(e.substringBytes((u32)0, colon), numberArg(e.substringFromByte(colon + (u32)1)));
    }

    MonPage* pg = new MonPage();
    MonFeed* feed = new MonFeed();
    MonTraceListener* tl = new MonTraceListener();
    try
    {
        pg.ls = Socket.listen(port);
        feed.ws = WebSocketServer.listen((u16)((u32)port + (u32)1));
        tl.ls = Socket.listen(tracePort);
    }
    catch (SocketError e)
    {
        Stdio.printf("xcmon: %s\n", e.message().cString());
        return (i32)1;
    }
    pg.page = page;
    pg.feedPort = (u16)((u32)port + (u32)1);
    feed.clients = new Array();
    feed.lock = new Mutex();
    tl.keep = new Array();
    MonPoller* poller = new MonPoller();

    Thread* t1 = Thread.spawn(&poller.run);
    Thread* t2 = Thread.spawn(&tl.run);
    Thread* t3 = Thread.spawn(&feed.run);
    Stdio.printf("xcmon: the page at http://localhost:%u/ ; programs trace to XC_PAR_TRACE=<this host>:%u\n",
                 (u32)port, (u32)tracePort);
    pg.run();
    t1.join();
    t2.join();
    t3.join();
    return 0;
}
