// platform_neutral.xc — the ambient cross-platform surface (task #36): Url,
// Log and Platform resolve with NO directives in source on EVERY target
// (each platform prelude imports PlatformCore.xc). On targets with no
// installed delegate, url.fetch completes synchronously with status 0
// after a logged warning — same source, same behaviour, every backend.
//xtc-na: wasm32, ios — fetch there is genuinely async (the browser delegate);
//        completions land after main returns, so the sweep's captured
//        output differs by design. tests/wasm32/platform-browser/ covers it.
#import "Stdio.xc"

void main(void)
{
    Log.info(String.withCString("boot"));
    Url* u = Url.withCString("https://api.example:8080/v1/items?limit=5");
    Stdio.printf("%s %s %s\n", u.scheme().cString(), u.host().cString(),
                 u.path().cString());
    Stdio.printf("port %d q %s\n", (u16)u.port(), u.query().cString());
    u.fetch(block void(u32 status, String* body) {
        if (status == (u32)0 && body == 0) { Log.info(String.withCString("no-transport ok")); }
    });
    Log.warning(String.withCString("w"));
    Log.error(String.withCString("e"));
}
