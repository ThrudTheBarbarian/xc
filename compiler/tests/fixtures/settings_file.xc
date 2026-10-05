// settings_file.xc — Settings against a real file, where there is a filesystem.
//
// Settings.open() reads the file once and save() rewrites it whole; reload()
// takes the file as the truth again. The store keeps insertion order, so a
// save() after a load() writes the same keys in the same order and the file
// text is stable.
//
// The file lives in the working directory under a fixed name and is
// overwritten on every run; nothing here can delete it (Files has no remove).
//
//xtc-na: xt6502 — a 6502 has no filesystem: Settings there is memory-only and
//        save() reports false (settings_memory.xc covers that half).
#import "Stdio.xc"
#import "Settings.xc"
#import "Files.xc"

i32 main(void)
{
    // Scratch files go in tmp/ (ignored by git).
    Files.createDirectory(String.withCString("tmp"));
    String* p = String.withCString("tmp/settings_file.tmp");

    // A file that is not there is an EMPTY STORE, not an error: the first
    // save() creates it.
    Settings* fresh = Settings.open(p);
    Stdio.printf("fresh %lu save %d\n", fresh.count(), (i16)(fresh.save() ? 1 : 0));
    Stdio.printf("created size %ld\n", Files.size(p));

    Files.writeText(p, String.withCString("# a comment\nalpha = one\n\nbeta=two\n"));
    Settings* s = Settings.open(p);
    Stdio.printf("count %lu alpha %s beta %s\n", s.count(),
                 s.get(String.withCString("alpha")).cString(),
                 s.get(String.withCString("beta")).cString());
    Stdio.printf("path %s\n", s.path().cString());

    // A save after a load drops the comment, keeps the order, and is stable:
    // saving the same store twice writes the same bytes.
    Stdio.printf("save %d\n", (i16)(s.save() ? 1 : 0));
    Stdio.printf("text [%s]", Files.readText(p).cString());
    Stdio.printf("again %d same %d\n", (i16)(s.save() ? 1 : 0),
                 (i16)(s.serialise().equals(Files.readText(p)) ? 1 : 0));

    // reload() takes the file as the truth: a changed value is overwritten.
    s.set(String.withCString("alpha"), String.withCString("CHANGED"));
    Stdio.printf("dirty %s\n", s.get(String.withCString("alpha")).cString());
    Stdio.printf("reload %d clean %s\n", (i16)(s.reload() ? 1 : 0),
                 s.get(String.withCString("alpha")).cString());

    // A file that has gone leaves the store EMPTY, not stale.
    Files.writeText(String.withCString("tmp/settings_file_gone.tmp"), String.withCString("q = r\n"));
    Settings* gone = Settings.open(String.withCString("tmp/settings_file_gone.tmp"));
    Stdio.printf("before %lu\n", gone.count());
    gone.set(String.withCString("z"), String.withCString("w"));
    Stdio.printf("after %lu reload %d now %lu\n", gone.count(), (i16)(gone.reload() ? 1 : 0), gone.count());

    return (i32)0;
}
