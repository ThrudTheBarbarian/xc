// foundation_log_levels.xc — Log: levels and the global minimum, debug
// through a Logger with and without its own debug, subsystem channels with
// their own minimum, and monitors (added, called, removed, and dropped when
// their receiver goes).
#import "Foundation.xc"
#import "Log.xc"

class Capture<Logger>
    {
    void error(String* msg)
        {
        Stdio.printf("  E %s\n", msg.cString());
        }
    void warning(String* msg)
        {
        Stdio.printf("  W %s\n", msg.cString());
        }
    void info(String* msg)
        {
        Stdio.printf("  I %s\n", msg.cString());
        }
    void debug(String* msg)
        {
        Stdio.printf("  D %s\n", msg.cString());
        }
    }

// No debug: debug messages come through info.
class Plain<Logger>
    {
    void error(String* msg)
        {
        Stdio.printf("  plain E %s\n", msg.cString());
        }
    void warning(String* msg)
        {
        Stdio.printf("  plain W %s\n", msg.cString());
        }
    void info(String* msg)
        {
        Stdio.printf("  plain I %s\n", msg.cString());
        }
    }

class Watcher : Object
    {
    u32 seen;
    void init(void)
        {
        seen = (u32)0;
        }
    void onLog(String* subsystem, u8 level, String* msg)
        {
        seen++;
        Stdio.printf("  monitor [%s] %d %s\n", subsystem.cString(), (i32)level, msg.cString());
        }
    }

String* S(u8* c)
    {
    return String.withCString(c);
    }

i32 main(void)
    {
    Log.setLogger(new Capture());
    Stdio.printf("default minimum (info):\n");
    Log.debug(S("hidden"));
    Log.info("n=%d", (i32)3);
    Log.warning(S("careful"));
    Log.error(S("broken"));
    Stdio.printf("minimum debug:\n");
    Log.setMinLevel(Log.levelDebug());
    Log.debug("x=%d", (i32)7);
    Stdio.printf("minimum error:\n");
    Log.setMinLevel(Log.levelError());
    Log.warning(S("dropped"));
    Log.error(S("kept"));

    Stdio.printf("channels:\n");
    Log.setMinLevel(Log.levelDebug());
    LogChannel* net = Log.forSubsystem(S("net"));
    net.debug(S("dns ok"));
    net.setMinLevel(Log.levelWarning());
    net.info(S("dropped by the channel"));
    net.warning("retry %d", (i32)2);
    Stdio.printf("same channel: %d\n", (i32)(Log.forSubsystem(S("net")) == net ? 1 : 0));

    Stdio.printf("monitors:\n");
    Watcher* w = new Watcher();
    Log.addMonitor(&w.onLog);
    net.error(S("timeout"));
    Log.info(S("plain"));
    Log.removeMonitor(&w.onLog);
    Log.info(S("unwatched"));
    Watcher* gone = new Watcher();
    Log.addMonitor(&gone.onLog);
    Log.info(S("watched once"));
    gone = (Watcher*)0;
    Log.info(S("after the watcher went"));
    Stdio.printf("seen %d\n", (i32)w.seen);

    Stdio.printf("a Logger without debug:\n");
    Log.setLogger(new Plain());
    Log.debug(S("through info"));
    return (i32)0;
    }
