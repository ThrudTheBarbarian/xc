// test_log.xc — UXLog: level filtering + regex monitors firing callbacks on matching lines.
#import <Stdio.xc>
#import "UXLog.xc"
#import "UXRegex.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

class Watcher : Object
    {
    i32 hits;
    void init(void)
        {
        hits = (i32)0;
        }
    // matches the monitor callback: void(u8* msg)
    void onTimeout(u8* msg)
        {
        hits = hits + (i32)1;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    Watcher* w = new Watcher();

    UXLog* net = UXLog.forSubsystem((u8*)"net");
    net.setStdout(false); // keep the test's own output clean
    net.setMinLevel((i32)UX_LOG_INFO);
    net.addMonitor(UXRegex.compile((u8*)"timeout"), &w.onTimeout);
    check("one monitor registered", net.monitorCount(), (i32)1);

    net.debug((u8*)"connect timeout while tracing"); // DEBUG < INFO: dropped -> monitor must NOT fire
    check("sub-threshold line is dropped (no fire)", w.hits, (i32)0);

    net.info((u8*)"connect established"); // passes level, no match
    check("non-matching line: no fire", w.hits, (i32)0);

    net.error((u8*)"connect timeout after 30s"); // passes level AND matches
    check("matching line fires the monitor", w.hits, (i32)1);

    net.warn((u8*)"read timeout on socket 4"); // another match
    check("second match fires again", w.hits, (i32)2);

    // subsystem registry: same name -> same logger object (os_log-style)
    UXLog* net2 = UXLog.forSubsystem((u8*)"net");
    check("forSubsystem returns the same logger", net2.monitorCount(), (i32)1);
    UXLog* other = UXLog.forSubsystem((u8*)"ui");
    check("a different subsystem is a fresh logger", other.monitorCount(), (i32)0);

    // removing the monitor stops the callbacks
    net.removeMonitor(&w.onTimeout);
    check("monitor removed", net.monitorCount(), (i32)0);
    net.error((u8*)"timeout again");
    check("no fire after removal", w.hits, (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXLog — levels, subsystem registry, regex monitors, removal.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
