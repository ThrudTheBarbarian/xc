// An instance variable set, a call that reads it, then set again: not a dead
// store, since the call reads the first value. ParRemote's resend flag was
// reported as "never read".
#import "Stdio.xc"
class Sender
    {
    bool _resend;
    u32 send(u32 n)
        {
        return _resend ? n * (u32)2 : n;
        }
    u32 again(u32 n)
        {
        _resend = true;
        u32 r = send(n);
        _resend = false;
        return r;
        }
    }
i32 main(void)
    {
    Sender* s = new Sender();
    Stdio.printf("%u\n", s.again((u32)21));
    return 0;
    }
