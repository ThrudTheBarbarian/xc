// The platform-NEUTRAL surface (task #36) on wasm32: Url, Log and Platform
// resolve with NO #import, NO #package and NO #use in app source — the
// prelude wires Browser as the delegate and the browser console as the
// logger, and the generated loader carries the JS half. This exact source
// also compiles, links and runs on every native target (fetch completes
// with status 0 there until an app installs its own delegate).
void main(void)
    {
    Log.info(String.withCString("boot"));
    Url* ok = Url.withCString("http://x/ok");
    ok.fetch(block void(u32 status, String * body) {
        if (status == (u32)200 && body != 0)
            {
            Log.info(body);
            }
        else
            {
            Log.error(String.withCString("BAD:ok-path"));
            }
    });
    Url* bad = Url.withCString("http://x/fail");
    bad.fetch(block void(u32 status, String * body) {
        if (status == (u32)0 && body == 0)
            {
            Log.info(String.withCString("fail-ok"));
            }
        else
            {
            Log.error(String.withCString("BAD:fail-path"));
            }
    });
    }
