// UXLog.xc — a small logging facility (os_log / syslog in shape), neutral across backends.
//
// A logger has a SUBSYSTEM name and a minimum level; messages below the level are dropped.  Output
// goes to stdout by default (a real syslog sink is a per-backend add-on).  The interesting part is
// MONITORS: register an UXRegex and a callback, and the callback fires whenever a logged message
// matches — "watch the log for X and tell me", built on the toolkit's own regex engine.
//
//     UXLog* net = UXLog.forSubsystem("net");
//     net.setMinLevel(UX_LOG_INFO);
//     net.addMonitor(UXRegex.compile("timeout"), &self.onTimeout);   // callback on any "timeout" line
//     net.error("connect timeout after 30s");                        // prints, and fires onTimeout
#import <Stdio.xc>
#import "Array.xc"
#import "UXRegex.xc"

#define UX_LOG_DEBUG 0
#define UX_LOG_INFO 1
#define UX_LOG_WARN 2
#define UX_LOG_ERROR 3

// A watch: a compiled pattern and the callback to fire on a match.  A callback never
// owns its receiver, so a monitor cannot keep its observer alive.
class UXLogMonitor : Object
    {
    UXRegex* pattern;
    callback cb void(u8* msg);
    void init(void)
        {
        pattern = (UXRegex*)0;
        cb = (callback void(u8 * msg))0;
        }
    }

    // The process-wide loggers, one per subsystem name (like os_log's subsystem registry).
    Array<UXLog>* gUXLoggers;

class UXLog
    {
    u8* subsystem;
    i32 minLevel;
    bool toStdout;
    Array<UXLogMonitor>* monitors; // of UXLogMonitor

    void init(void)
        {
        subsystem = (u8*)"";
        minLevel = (i32)UX_LOG_INFO;
        toStdout = true;
        monitors = new Array();
        }

    static UXLog* forSubsystem(u8* name)
        {
        if (gUXLoggers == (Array*)0)
            {
            gUXLoggers = new Array();
            }
        for (u16 i = (u16)0; i < gUXLoggers.count(); i = i + (u16)1)
            {
            UXLog* l = (UXLog* ?)gUXLoggers.get(i);
            if (UXLog.streq(l.subsystem, name))
                {
                return l;
                }
            }
        UXLog* l = new UXLog();
        l.subsystem = name;
        gUXLoggers.add(l);
        return l;
        }
    static UXLog* shared(void)
        {
        return UXLog.forSubsystem((u8*)"default");
        }

    static bool streq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    void setMinLevel(i32 lvl)
        {
        minLevel = lvl;
        }
    void setStdout(bool on)
        {
        toStdout = on;
        }
    i32 level(void)
        {
        return minLevel;
        }

    u8* levelName(i32 lvl)
        {
        if (lvl == (i32)UX_LOG_DEBUG)
            {
            return (u8*)"DEBUG";
            }
        if (lvl == (i32)UX_LOG_INFO)
            {
            return (u8*)"INFO";
            }
        if (lvl == (i32)UX_LOG_WARN)
            {
            return (u8*)"WARN";
            }
        return (u8*)"ERROR";
        }

    // The one funnel.  Drops sub-threshold messages, prints the rest, then runs the monitors.
    void log(i32 lvl, u8* msg)
        {
        if (lvl < minLevel)
            {
            return;
            }
        if (toStdout)
            {
            Stdio.printf("[%s] %s: %s\n", self.levelName(lvl), subsystem, msg);
            }
        for (u16 i = (u16)0; i < monitors.count(); i = i + (u16)1)
            {
            UXLogMonitor* m = (UXLogMonitor* ?)monitors.get(i);
            if (m.pattern == (UXRegex*)0)
                {
                continue;
                }
            if (m.pattern.test(msg))
                {
                callback f void(u8 * msg) = m.cb; // auto-zeroed if the observer is gone
                if (f != (callback void(u8 * msg))0)
                    {
                    f(msg);
                    }
                }
            }
        }
    void debug(u8* msg)
        {
        self.log((i32)UX_LOG_DEBUG, msg);
        }
    void info(u8* msg)
        {
        self.log((i32)UX_LOG_INFO, msg);
        }
    void warn(u8* msg)
        {
        self.log((i32)UX_LOG_WARN, msg);
        }
    void error(u8* msg)
        {
        self.log((i32)UX_LOG_ERROR, msg);
        }

    // ---- monitors ------------------------------------------------------------
    void addMonitor(UXRegex* pattern, callback cb void(u8* msg))
        {
        UXLogMonitor* m = new UXLogMonitor();
        m.pattern = pattern;
        m.cb = cb;
        monitors.add(m);
        }
    void removeMonitor(callback cb void(u8* msg))
        {
        for (u16 i = (u16)0; i < monitors.count(); i = i + (u16)1)
            {
            UXLogMonitor* m = (UXLogMonitor* ?)monitors.get(i);
            callback f void(u8 * msg) = m.cb;
            if (f == cb)
                {
                monitors.removeAt(i);
                return;
                }
            }
        }
    i32 monitorCount(void)
        {
        return (i32)monitors.count();
        }
    }
