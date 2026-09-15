// settings.xc — a persistent key/value store with registered fallbacks.
//
// No driver is booted here, so this runs purely in memory — which is exactly
// what happens on a backend with nowhere to write, and is why the class works
// before a window exists.
#import <Stdio.xc>
#import "UXKeyValueStore.xc"

void main(void) {
    UXKeyValueStore* app = UXKeyValueStore.forDomain((u8*)"demo");

    // REGISTERED defaults are consulted when a key was never set, so the first
    // launch reads sensible values instead of zero and "".
    app.registerInt((u8*)"fontSize", 12);
    app.registerBool((u8*)"showGrid", true);
    app.registerString((u8*)"theme", (u8*)"light");

    Stdio.printf("first launch: fontSize=%d showGrid=%d theme=%s\n",
                 app.intFor((u8*)"fontSize"),
                 app.boolFor((u8*)"showGrid") ? 1 : 0,
                 app.stringFor((u8*)"theme"));
    Stdio.printf("hasKey(fontSize) = %s  (registered is not SET)\n",
                 app.hasKey((u8*)"fontSize") ? (u8*)"yes" : (u8*)"no");

    // Setting overrides the registration.
    app.setInt((u8*)"fontSize", 18);
    Stdio.printf("after set: fontSize=%d  hasKey=%s\n",
                 app.intFor((u8*)"fontSize"),
                 app.hasKey((u8*)"fontSize") ? (u8*)"yes" : (u8*)"no");

    // Removing falls BACK to the registration rather than to zero.
    app.removeKey((u8*)"fontSize");
    Stdio.printf("after remove: fontSize=%d (back to the registered default)\n",
                 app.intFor((u8*)"fontSize"));

    // DOMAINS: standard() is shared by every program; a named domain falls back
    // to it, so a machine-wide default can be set once and overridden per app.
    UXKeyValueStore* shared = UXKeyValueStore.standard();
    shared.setString((u8*)"editor", (u8*)"rocks");
    Stdio.printf("shared editor=%s  seen from the app domain=%s\n",
                 shared.stringFor((u8*)"editor"), app.stringFor((u8*)"editor"));

    app.setString((u8*)"editor", (u8*)"vi");
    Stdio.printf("app overrides it: app=%s  shared still=%s\n",
                 app.stringFor((u8*)"editor"), shared.stringFor((u8*)"editor"));
}
