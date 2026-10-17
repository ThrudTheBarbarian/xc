// propshost.xc — a plugin's developer properties: the manifest's readonly and
// writeable values, a user's overrides kept in a Settings file across runs.
//     propshost <bundle> <settings file> show [key...]
//     propshost <bundle> <settings file> set <key> <value>
//     propshost <bundle> <settings file> reset <key>
#import "Stdio.xc"
#import "Process.xc"
#import "Plugin.xc"
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
class Host : Object <Fence>
    {
    static i32 emit(u8* p, u32 n) { return (i32)n; }
    static void note(i32 v) { }
    }
class Watcher : Object
    {
    u32 seen;
    void changed(Notification* n) { seen = seen + (u32)1; }
    }
bool yes(String* name, String* publisher, String* domain, String* keyId) { return true; }
void show(Plugin* p, String* k)
{
    String* i = p.info(k);
    String* v = p.value(k);
    Stdio.printf("%s: info=%s value=%s writeable=%s overridden=%s defaultChanged=%s\n", k.cString(),
                 i != (String*)0 ? i.cString() : "-", v != (String*)0 ? v.cString() : "-",
                 p.isWriteable(k) ? "yes" : "no", p.isOverridden(k) ? "yes" : "no", p.defaultChanged(k) ? "yes" : "no");
}
i32 main(void)
{
    Plugin.provide(String.withCString("Fence"), Fence.versionMajor(), Fence.versionMinor(), Fence.table());
    Settings* s = Settings.open(Process.argument((u32)2));
    Plugin.useSettings(s);
    Plugin* p = Plugin.load(Process.argument((u32)1), &yes);
    if (p == (Plugin*)0) {
        Stdio.printf("refused: %s\n", Plugin.lastError().cString());
        return 1;
    }
    Watcher* w = new Watcher();
    NotificationCenter.shared().addObserver(w, &w.changed, Plugin.valueChanged(), (Object*)0);
    String* cmd = Process.argument((u32)3);
    if (cmd.equals(String.withCString("set"))) {
        bool ok = p.setValue(Process.argument((u32)4), Process.argument((u32)5));
        Stdio.printf("set %s -> %s, notified %u\n", Process.argument((u32)4).cString(), ok ? "yes" : "no", w.seen);
    } else if (cmd.equals(String.withCString("reset"))) {
        p.resetValue(Process.argument((u32)4));
        Stdio.printf("reset %s, notified %u\n", Process.argument((u32)4).cString(), w.seen);
    } else {
        Array* ks = p.infoKeys();
        Stdio.printf("keys:");
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1) Stdio.printf(" %s", ((String*)ks.get(i)).cString());
        Stdio.printf("\n");
        for (u32 i = (u32)4; i < Process.argumentCount(); i = i + (u32)1) show(p, Process.argument(i));
    }
    return 0;
}
