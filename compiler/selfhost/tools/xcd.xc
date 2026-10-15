// xcd — the par worker daemon: this machine's GPUs, served to programs on
// other machines as workers on their tile queue (ParRemote.xc).
//
//     xcd [-port N]            listen on port N (default 7227)
//         [-nimby hh:mm-hh:mm]  take no work in these local hours (the window may cross midnight)
//     XC_PAR_SECRET=…          the pool secret a program must prove
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

i32 main(void)
{
    u16 port = (u16)PAR_REMOTE_PORT;
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
        else if (a.equals(String.withCString("-h")) || a.equals(String.withCString("--help")))
        {
            Stdio.printf("xcd [-port N] [-nimby hh:mm-hh:mm]   serve this machine's GPUs to par programs (XC_PAR_SECRET, XC_PAR_REPORT)\n");
            return 0;
        }
    }
    Array* workers = ParTiles.gpuWorkers();
    if (workers.count() == (u32)0)
    {
        Stdio.printf("xcd: no GPU here to serve\n");
        return 1;
    }
    String* identity = ((ParWorker*)workers.get((u32)0)).identity();
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
    Stdio.printf("xcd: serving %s on port %u%s\n", identity.cString(), (u32)port,
                 ParRemoteServe.hasNimby() ? (ParRemoteServe.nimbyNow() ? " (nimby now)" : " (nimby window set)") : "");
    while (true)
    {
        Socket* c = ls.accept((i32)-1);
        if (c == (Socket*)0)
            continue;
        ParRemoteServe.serve(c, workers, identity);
        c.close();
    }
    return 0;
}
