// webhost.xc — loads a plugin with Plugin.loadAsync (the web's way, and the
// same line natively), provides Fence to it and calls it through Spice.
//     webhost <bundle dir or URL> [yes|no|none]     (in a page: $PLUGIN, yes)
#import "Stdio.xc"
#import "Process.xc"
#import "Plugin.xc"
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
protocol Spice :version(1.0)
    {
    static i32 run(i32 x);
    static u32 sum(u8* p, u32 n);
    }
class Host : Object <Fence>
    {
    static i32 emit(u8* p, u32 n) { Stdio.printf("host emit %u bytes\n", n); return (i32)n * (i32)2; }
    static void note(i32 v) { Stdio.printf("host note %d\n", v); }
    }
bool answerYes(String* name, String* publisher, String* domain, String* keyId)
{
    Stdio.printf("asked about %s (domain '%s')\n", name.cString(), domain.cString());
    return true;
}
bool answerNo(String* name, String* publisher, String* domain, String* keyId)
{
    Stdio.printf("asked about %s, said no\n", name.cString());
    return false;
}
void loaded(Plugin* p)
{
    if (p == (Plugin*)0) {
        Stdio.printf("refused: %s\n", Plugin.lastError().cString());
        return;
    }
    Spice.bind(p.table(String.withCString("Spice")));
    Stdio.printf("run -> %d\n", Spice.run((i32)7));
    u8[4] b;
    b[0] = (u8)1; b[1] = (u8)2; b[2] = (u8)3; b[3] = (u8)4;
    u32 t = Spice.sum(&b[0], (u32)4);
    Stdio.printf("sum -> %u, first byte now %u\n", t, (u32)b[0]);
    p.resource(String.withCString("note.txt"), block void(Data* d) {
        if (d == (Data*)0)
            Stdio.printf("resource: none\n");
        else
            Stdio.printf("resource: %s\n", String.withBytes(d.bytes(), d.length()).cString());
    });
}
i32 main(void)
{
    // A page has no command line: there the bundle's URL is $PLUGIN.
    String* where = Process.argumentCount() > (u32)1 ? Process.argument((u32)1)
                                                     : Platform.env(String.withCString("PLUGIN"));
    String* how = Process.argumentCount() > (u32)2 ? Process.argument((u32)2) : String.withCString("yes");
    Plugin.provide(String.withCString("Fence"), Fence.versionMajor(), Fence.versionMinor(), Fence.table());
    PluginConsent_t* c = &answerYes;
    if (how.equals(String.withCString("no"))) c = &answerNo;
    if (how.equals(String.withCString("none"))) c = (PluginConsent_t*)0;
    Plugin.loadAsync(where, c, &loaded);
    return 0;
}
