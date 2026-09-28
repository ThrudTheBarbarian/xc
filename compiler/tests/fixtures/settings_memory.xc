// settings_memory.xc — the in-memory Settings store, on every target.
//
// Settings is the NSUserDefaults-shaped hole in the library: a small named set
// of values a program reads at startup and writes back. This is the memory-only
// half, which is all a target with no filesystem has — so there is nothing to
// mark not-applicable here. The file-backed half is settings_file.xc.
#import "Stdio.xc"
#import "Settings.xc"

i32 main(void)
{
    Settings* s = Settings.memory();

    Stdio.printf("empty %lu %d\n", s.count(), (i16)(s.has(String.withCString("a")) ? 1 : 0));

    s.set(String.withCString("alpha"), String.withCString("one"));
    s.set(String.withCString("beta"), String.withCString("two"));
    Stdio.printf("count %lu\n", s.count());
    Stdio.printf("alpha %s beta %s\n", s.get(String.withCString("alpha")).cString(),
                 s.get(String.withCString("beta")).cString());

    // A second set() REPLACES, and keeps the original position.
    s.set(String.withCString("alpha"), String.withCString("ONE"));
    Stdio.printf("count %lu alpha %s\n", s.count(), s.get(String.withCString("alpha")).cString());
    Stdio.printf("key0 %s\n", ((String*)s.keys().get((u32)0)).cString());

    // The two-argument get() is the fallback for a key that is not there.
    Stdio.printf("missing %s\n", s.get(String.withCString("gamma"), String.withCString("(none)")).cString());

    s.remove(String.withCString("beta"));
    Stdio.printf("after remove %lu has-beta %d\n", s.count(),
                 (i16)(s.has(String.withCString("beta")) ? 1 : 0));

    // Typed accessors: a stored decimal, and a value that is not one.
    s.setInt(String.withCString("n"), (i32)-41);
    Stdio.printf("n %d bad %d absent %d\n", s.getInt(String.withCString("n"), (i32)0),
                 s.getInt(String.withCString("alpha"), (i32)7),
                 s.getInt(String.withCString("zz"), (i32)7));
    s.setBool(String.withCString("on"), true);
    Stdio.printf("on %d off %d\n", (i16)(s.getBool(String.withCString("on"), false) ? 1 : 0),
                 (i16)(s.getBool(String.withCString("off"), false) ? 1 : 0));

    // The file text, built from the store: insertion order, `key = value`.
    Stdio.printf("[%s]", s.serialise().cString());

    // loadText() replaces the store. Comments, blanks and a line with no '='
    // are not settings and are dropped; both sides are trimmed.
    Settings* t = Settings.memory();
    t.loadText(String.withCString("# a comment\n\nalpha =  one \nnot-a-setting\nbeta=2\n"));
    Stdio.printf("loaded %lu %s %s\n", t.count(), t.get(String.withCString("alpha")).cString(),
                 t.get(String.withCString("beta")).cString());
    Stdio.printf("bool1 %d bool2 %d\n", (i16)(t.getBool(String.withCString("beta"), false) ? 1 : 0),
                 (i16)(t.getBool(String.withCString("beta"), true) ? 1 : 0));

    // A memory-only store cannot persist, and says so rather than pretending.
    Stdio.printf("save %d reload %d path %d\n", (i16)(s.save() ? 1 : 0), (i16)(s.reload() ? 1 : 0),
                 (i16)(s.path() == 0 ? 1 : 0));
    return (i32)0;
}
