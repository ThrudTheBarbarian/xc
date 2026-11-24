// par_resident_send.xc — an array a GPU run keeps on its device (#15) sent
// through Socket.write: send() fails on a parked array instead of faulting,
// so the writer brings it back first (ParSync). The bytes the other end
// reads add up to what the host sums itself. tests/par/resident.sh runs it
// with residency forced on a CUDA device; anywhere else nothing is parked
// and it prints the same.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no par threads or no sockets there
#import "Foundation.xc"
#import "Socket.xc"
#import "Par.xc"

#define N 4194304
#define SENT 8192

i32 main(void)
{
    u32* acc = new u32[N];
    for (u32 i in 0..N) acc[i] = i & (u32)1023;
    for (u32 r in 0..3)
    {
        par step
        {
            for (u32 i in 0..N)
                acc[i] = acc[i] * (u32)3 + i;
        }
    }
    Socket* server = (Socket*)0;
    u16 port = (u16)47310;
    while (server == (Socket*)0 && port < (u16)47400)
    {
        try { server = Socket.listen(port); }
        catch (SocketError e) { port = port + (u16)1; }
    }
    if (server == (Socket*)0)
    {
        Stdio.printf("no port\n");
        return 1;
    }
    Socket* client = (Socket*)0;
    try { client = Socket.connect(String.withCString("127.0.0.1"), port); }
    catch (SocketError e) { Stdio.printf("no connection\n"); return 1; }
    Socket* peer = server.accept((i32)5000);
    // acc is still on the device here when residency is on.
    bool sent = client.write((u8*)acc, (u32)(SENT * 4));
    u8* got = new u8[SENT * 4];
    u32 have = (u32)0;
    // read() does not wait: 0 is nothing yet.
    u32 idle = (u32)0;
    while (have < (u32)(SENT * 4) && idle < (u32)200)
    {
        i32 n = peer.read(got + have, (u32)(SENT * 4) - have);
        if (n < 0)
            break;
        if (n == 0)
        {
            peer.waitReadable((i32)10);
            idle = idle + (u32)1;
        }
        have = have + (u32)n;
    }
    u32 theirs = (u32)0;
    u32* g = (u32*)got;
    for (u32 i in 0..have / (u32)4) theirs = theirs + g[i];
    u32 ours = (u32)0;
    for (u32 i in 0..SENT) ours = ours + acc[i];
    Stdio.printf("sent %d, %u bytes, sums agree %d\n", (i32)(sent ? 1 : 0), have, (i32)(theirs == ours ? 1 : 0));
    client.close();
    peer.close();
    server.close();
    return 0;
}
