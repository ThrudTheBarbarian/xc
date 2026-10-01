//xtc-na: xt6502,m68k,arm9,wasm32 — no persistent per-user store under the test harnesses (6502 and m68k have none; arm9 and wasm under node have no home or localStorage)
// settings_standard.xc — Settings.standard() round-trips through the platform's
// own store: CFPreferences on macOS, the registry on Windows, a text file on
// Linux. The same calls, the same answers, whichever store is underneath.
#import "Foundation.xc"
#import "Settings.xc"
#import "Stdio.xc"

i32 main(void)
{
    String* name = String.withCString("org.compile-xc.fixture-settings-standard");
    Settings* s = Settings.standard(name);
    s.removeAll();
    s.set(String.withCString("width"), String.withCString("640"));
    s.setInt(String.withCString("runs"), (i32)3);
    s.setBool(String.withCString("dark"), true);
    Stdio.printf("save %d\n", s.save() ? 1 : 0);

    Settings* r = Settings.standard(name);
    Stdio.printf("count %u runs %d dark %d width %@\n", r.count(),
                 r.getInt(String.withCString("runs"), (i32)0),
                 r.getBool(String.withCString("dark"), false) ? 1 : 0,
                 r.get(String.withCString("width")));

    r.remove(String.withCString("width"));
    r.save();
    s.reload();
    Stdio.printf("after remove %u width %@\n", s.count(), s.get(String.withCString("width"), String.withCString("gone")));

    s.removeAll();
    Stdio.printf("cleared %d\n", s.save() ? 1 : 0);
    return 0;
}
