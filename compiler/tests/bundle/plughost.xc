// plughost.xc — loads a signed bundle with Plugin.load and calls into it;
// the plugin calls back through the Fence protocol this host provides.
//     plughost <bundle> [yes|no]   consent answer when not yet trusted
//     plughost <bundle> none       no consent callback
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
    static i32 emit(u8* p, u32 n) { Stdio.printf("host emit %s %u\n", p, n); return (i32)n * (i32)2; }
    static void note(i32 v) { Stdio.printf("host note %d\n", v); }
    }
typedef i32 Run_t(i32 x);
bool answerYes(String* name, String* publisher, String* domain, String* keyId)
{
    Stdio.printf("asked about %s from '%s' (domain '%s')\n", name.cString(), publisher != (String*)0 ? publisher.cString() : "",
                 domain != (String*)0 ? domain.cString() : "");
    return true;
}
bool answerNo(String* name, String* publisher, String* domain, String* keyId)
{
    Stdio.printf("asked about %s, said no\n", name.cString());
    return false;
}
i32 main(void)
{
    String* b = Process.argument((u32)1);
    String* how = Process.argumentCount() > (u32)2 ? Process.argument((u32)2) : String.withCString("yes");
    Plugin.provide(String.withCString("Fence"), Fence.versionMajor(), Fence.versionMinor(), Fence.table());
    PluginConsent_t* c = &answerYes;
    if (how.equals(String.withCString("no"))) c = &answerNo;
    if (how.equals(String.withCString("none"))) c = (PluginConsent_t*)0;
    Plugin* p = Plugin.load(b, c);
    if (p == (Plugin*)0) {
        Stdio.printf("refused: %s\n", Plugin.lastError().cString());
        return 1;
    }
    Run_t* run = (Run_t*)p.symbol(String.withCString("SpiceTool$run"));
    if (run == (Run_t*)0) {
        Stdio.printf("no SpiceTool$run\n");
        return 1;
    }
    Stdio.printf("run -> %d\n", run((i32)7));
    return 0;
}
