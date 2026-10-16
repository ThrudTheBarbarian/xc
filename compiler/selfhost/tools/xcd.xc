// xcd — the par worker daemon: this machine's GPUs, served to programs on
// other machines as workers on their tile queue (ParRemote.xc).
//
//     xcd [-port N]            listen on port N (default 7227)
//         [-nimby hh:mm-hh:mm]  take no work in these local hours (the window may cross midnight)
//         [-pool NAME]          advertise as a member of this pool (programs with XC_PAR_POOL=NAME find it)
//         [-no-mdns]            do not advertise on the subnet
//     XC_PAR_SECRET=…          the pool secret a program must prove
//     XCD_HOME=dir             where its certificate lives (default ~/.xcc/xcd)
//     XC_PAR_REPORT=1          say what each block and tile does
//
// A program names its workers with XC_PAR_REMOTE=host[:port],…; a run then
// splits its tiles across the local devices and these. The daemon runs GPU
// kernels only: a tile arrives as the block's kernel source, its object and
// its arrays, and the result goes back as the written slices and the
// reduction partials, which the program folds in tile order.
#import "Stdio.xc"
#import "Par.xc"
#import "ParRemote.xc"
#import "Process.xc"
#import "Thread.xc"

i32 main(void)
{
    u16 port = (u16)PAR_REMOTE_PORT;
    String* pool = new String();
    i64 cacheMb = (i64)0;
    bool mdns = true;
    Array* av = Process.arguments();
    for (u32 i = (u32)1; av != (Array*)0 && i < av.count(); i = i + (u32)1)
    {
        String* a = (String*)av.get(i);
        if (a.equals(String.withCString("-port")) && i + (u32)1 < av.count())
        {
            String* v = (String*)av.get(i + (u32)1);
            u32 n = (u32)0;
            for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                n = n * (u32)10 + (u32)(v.byteAt(k) - (u8)'0');
            port = (u16)n;
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-nimby")) && i + (u32)1 < av.count())
        {
            // hh:mm-hh:mm, as minutes of the day.
            String* v = (String*)av.get(i + (u32)1);
            i32 parts[4];
            u32 np = (u32)0;
            i32 n = (i32)0;
            bool okWindow = v.byteLength() == (u32)11;
            for (u32 k = (u32)0; okWindow && k < v.byteLength(); k = k + (u32)1)
            {
                u8 c = v.byteAt(k);
                if (c >= (u8)'0' && c <= (u8)'9')
                    n = n * (i32)10 + (i32)(c - (u8)'0');
                else if ((c == (u8)':' || c == (u8)'-') && np < (u32)3)
                {
                    parts[np] = n;
                    np = np + (u32)1;
                    n = (i32)0;
                }
                else
                    okWindow = false;
            }
            parts[3] = n;
            if (!okWindow || np != (u32)3 || parts[0] > (i32)23 || parts[2] > (i32)23 || parts[1] > (i32)59 || parts[3] > (i32)59)
            {
                Stdio.printf("xcd: -nimby wants hh:mm-hh:mm, not '%s'\n", v.cString());
                return 1;
            }
            ParRemoteServe.setNimby(parts[0] * (i32)60 + parts[1], parts[2] * (i32)60 + parts[3]);
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-pool")) && i + (u32)1 < av.count())
        {
            pool = (String*)av.get(i + (u32)1);
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-no-mdns")))
            mdns = false;
        else if (a.equals(String.withCString("-cache")) && i + (u32)1 < av.count())
        {
            String* v = (String*)av.get(i + (u32)1);
            i64 mb = (i64)0;
            for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                if (v.byteAt(k) >= (u8)'0' && v.byteAt(k) <= (u8)'9')
                    mb = mb * (i64)10 + (i64)(v.byteAt(k) - (u8)'0');
            cacheMb = mb;
            i = i + (u32)1;
        }
        else if (a.equals(String.withCString("-h")) || a.equals(String.withCString("--help")))
        {
            Stdio.printf("xcd [-port N] [-nimby hh:mm-hh:mm] [-pool NAME] [-no-mdns] [-cache MB]   serve this machine's GPUs to par programs (XC_PAR_SECRET, XC_PAR_REPORT)\n");
            return 0;
        }
    }
    ParRemote.noRemotes();      // a daemon serves its own GPUs, never another's
    Array* workers = ParTiles.gpuWorkers();
    if (workers.count() == (u32)0)
    {
        Stdio.printf("xcd: no GPU here to serve\n");
        return 1;
    }
    String* identity = ((ParWorker*)workers.get((u32)0)).identity();
    // The slice cache: -cache MB, else half of the first card's VRAM, else
    // a gigabyte.
    if (cacheMb <= (i64)0)
    {
        u64 vt = (u64)0;
        u64 vf = (u64)0;
        ((ParWorker*)workers.get((u32)0)).memory(&vt, &vf);
        cacheMb = vt > (u64)0 ? (i64)(vt >> (u64)21) : (i64)1024;
    }
    ParRemoteCache.setCap(cacheMb << (i64)20);
    Log.info("xcd: slice cache %ld MB", cacheMb);
    // Its certificate, made at first start under $XCD_HOME or ~/.xcc/xcd and
    // kept: a program pins its fingerprint on first sight. Every connection
    // is TLS, so a daemon with no TLS library does not start.
    if (!ParTls.load())
    {
        Stdio.printf("xcd: no TLS library: install the xcc third-party libraries, or name the library file in XC_TLS_LIB\n");
        return 1;
    }
    String* dir = Platform.env(String.withCString("XCD_HOME"));
    if (dir.byteLength() == (u32)0)
    {
        String* home = Platform.home();
        if (home.byteLength() == (u32)0)
            home = Platform.env(String.withCString("USERPROFILE"));
        if (home.byteLength() == (u32)0)
        {
            Stdio.printf("xcd: no home directory for the certificate: set XCD_HOME\n");
            return 1;
        }
        dir = home.appending(String.withCString("/.xcc"));
        Files.createDirectory(dir);
        dir = dir.appending(String.withCString("/xcd"));
    }
    Files.createDirectory(dir);
    String* certPath = dir.appending(String.withCString("/cert.pem"));
    String* keyPath = dir.appending(String.withCString("/key.pem"));
    if (!Files.exists(certPath) || !Files.exists(keyPath))
    {
        if (!ParTls.makeSelfSigned(certPath, keyPath, "xcd"))
        {
            Stdio.printf("xcd: cannot write a certificate under %s\n", dir.cString());
            return 1;
        }
        Stdio.printf("xcd: made a certificate under %s\n", dir.cString());
    }
    pointer tls = ParTls.server(certPath, keyPath);
    if (tls == (pointer)0)
    {
        Stdio.printf("xcd: the certificate under %s does not load; remove it and a new one is made\n", dir.cString());
        return 1;
    }
    ParRemoteServe.setTls(tls);
    String* fingerprint = ParTls.certFingerprint(certPath);
    Socket* ls = (Socket*)0;
    try
    {
        ls = Socket.listen(port);
    }
    catch (SocketError e)
    {
        Stdio.printf("xcd: %s\n", e.message().cString());
        return 1;
    }
    Stdio.printf("xcd: serving %s on port %u, certificate %s%s\n", identity.cString(), (u32)port, fingerprint.cString(),
                 ParRemoteServe.hasNimby() ? (ParRemoteServe.nimbyNow() ? " (nimby now)" : " (nimby window set)") : "");
    // Advertised on the subnet as _xcd._tcp, on a thread of its own. The
    // responder and its thread live as long as main does: a thread never
    // owns its receiver.
    MdnsResponder* responder = (MdnsResponder*)0;
    Thread* responderThread = (Thread*)0;
    if (mdns)
    {
        responder = new MdnsResponder(port, pool, String.withCString(PAR_CACHE_VER));
        responderThread = Thread.spawn(&responder.run);
        Stdio.printf("xcd: advertising _xcd._tcp%s%s\n", pool.byteLength() > (u32)0 ? " in pool " : "", pool.cString());
    }
    ParRemoteServe.setup();
    // Each program on a thread of its own; the GPUs serve one run at a time
    // (ParRemoteServe). A thread never owns its receiver, so the connection
    // objects are kept here until their programs have gone.
    Array* conns = new Array();
    while (true)
    {
        Socket* c = ls.accept((i32)-1);
        if (c == (Socket*)0)
            continue;
        u32 i = (u32)0;
        while (i < conns.count())
        {
            if (((ParRemoteConnection*)conns.get(i)).done())
                conns.removeAt(i);
            else
                i = i + (u32)1;
        }
        ParRemoteConnection* conn = new ParRemoteConnection(c, workers, identity);
        conns.add((Object*)conn);
        Thread* t = Thread.spawn(&conn.run);
        t.detach();
    }
    return 0;
}
