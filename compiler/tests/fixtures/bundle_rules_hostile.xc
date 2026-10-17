// bundle_rules_hostile.xc — BundleRules (bundles-and-plugins.md §4 steps 1-2,
// reviews 3, 5, 16, 17) against hostile input: paths with dot segments,
// absolute and drive-letter paths, backslashes, NUL and non-ASCII; names with
// a dot; two paths that are one file on a case-insensitive disk; and
// manifests with a duplicate key, too deep, too long a string, too many
// bytes. Each is refused; the ordinary ones are accepted.
#import "Stdio.xc"
#import "BundleRules.xc"

void path(u8* s)
{
    Stdio.printf("path %-28s %s\n", s, BundleRules.validPath(String.withCString(s)) ? "ok" : "refused");
}

void name(u8* s)
{
    Stdio.printf("name %-28s %s\n", s, BundleRules.validName(String.withCString(s)) ? "ok" : "refused");
}

void manifest(u8* label, String* text)
{
    try
    {
        Object* o = BundleRules.parseManifest(Data.withBytes(text.cString(), text.byteLength()));
        Stdio.printf("manifest %-20s ok\n", label);
    }
    catch (JSONError e)
    {
        Stdio.printf("manifest %-20s refused\n", label);
    }
}

i32 main(void)
{
    path("Exec/macos-arm64/spice.dylib");
    path("Resources/tool-icon.png");
    path("bundle.json");
    path("../escape.so");
    path("Exec/../../etc/passwd");
    path("./bundle.json");
    path("/etc/passwd");
    path("Resources//x.png");
    path("Resources/");
    path("C:/Windows/version.dll");
    path("Exec\\win\\evil.dll");
    path("Resources/caf\u00e9.png");
    path("Resources/a b.png");
    path("");
    // a NUL inside the name
    u8 nul[8] = {(u8)'a', (u8)'.', (u8)'s', (u8)'o', (u8)0, (u8)'x', (u8)0, (u8)0};
    String* withNul = String.withBytes(&nul[0], (u32)6);
    Stdio.printf("path a.so<NUL>x %s\n", BundleRules.validPath(withNul) ? "ok" : "refused");

    name("spice");
    name("tool_1-b");
    name("spice.evil");
    name("a=b");
    name("x#y");
    name("");

    Array* paths = new Array();
    paths.add((Object*)String.withCString("Exec/linux-x86_64/spice.so"));
    paths.add((Object*)String.withCString("Resources/Icon.png"));
    paths.add((Object*)String.withCString("Exec/linux-x86_64/Spice.so"));
    String* c = BundleRules.collision(paths);
    Stdio.printf("collision %s\n", c == (String*)0 ? "none" : c.cString());
    paths.removeLast();
    c = BundleRules.collision(paths);
    Stdio.printf("collision %s\n", c == (String*)0 ? "none" : c.cString());

    manifest("plain", String.withCString("{\"name\": \"spice\", \"version\": \"1.2\", \"code\": \"spice\"}"));
    manifest("duplicate key", String.withCString("{\"code\": \"spice\", \"code\": \"evil\"}"));
    manifest("nested duplicate", String.withCString("{\"publisher\": {\"key\": \"a\", \"key\": \"b\"}}"));
    manifest("same key, two objs", String.withCString("{\"a\": {\"k\": 1}, \"b\": {\"k\": 2}}"));
    String* deep = new String();
    for (u32 i = (u32)0; i < (u32)20; i = i + (u32)1) deep.appendCString("[");
    for (u32 i = (u32)0; i < (u32)20; i = i + (u32)1) deep.appendCString("]");
    manifest("20 deep", deep);
    String* longStr = String.withCString("{\"x\": \"");
    for (u32 i = (u32)0; i < (u32)5000; i = i + (u32)1) longStr.appendCString("a");
    longStr.appendCString("\"}");
    manifest("5000-byte string", longStr);
    String* big = String.withCString("[");
    for (u32 i = (u32)0; i < (u32)150000; i = i + (u32)1) big.appendCString("1234567,");
    big.appendCString("0]");
    manifest("1.2 MB", big);
    manifest("trailing comma", String.withCString("{\"a\": 1,}"));
    return 0;
}
