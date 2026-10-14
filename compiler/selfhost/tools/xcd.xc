// xcd — the par worker daemon: this machine's GPUs, served to programs on
// other machines as workers on their tile queue (ParRemote.xc).
//
//     xcd [-port N]            listen on port N (default 7227)
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
        else if (a.equals(String.withCString("-h")) || a.equals(String.withCString("--help")))
        {
            Stdio.printf("xcd [-port N]   serve this machine's GPUs to par programs (XC_PAR_SECRET, XC_PAR_REPORT)\n");
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
    Stdio.printf("xcd: serving %s on port %u\n", identity.cString(), (u32)port);
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
