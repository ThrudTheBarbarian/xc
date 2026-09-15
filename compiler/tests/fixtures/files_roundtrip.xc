// files_roundtrip.xc — Files.xc against a real file, on every target that
// has a file runtime: write, size, exists, read back, append, and the
// answers for a file that is not there.
//
// No fixture exercised Files at all until 2026-09-03, which is how m68k
// shipped with NONE of the `_xt_file_*` primitives defined (bug 127): every
// file call assembled as `jsr 0`, and as68-diff scored it a pass because both
// assemblers agreed. This is the guard — the m68k leg runs it under
// xcc-sim-68k, whose GEMDOS emulation opens real host files.
//
// The file it writes lives in the working directory under a fixed name and is
// overwritten on every run; nothing here can delete it (Files has no remove).
//
//xtc-na: xt6502 — a 6502 has no filesystem. Every other target has the
//        `_xt_file_*` runtime: arm64/android in libxt, m68k as GEMDOS stubs
//        (127), x86-64/win64 in rt-files.c and wasm32 in the JS loader (#81).
#import "Stdio.xc"
#import "Files.xc"

i32 main(void)
{
    String* p = String.withCString("files_roundtrip.tmp");
    String* none = String.withCString("files_roundtrip_missing.tmp");

    bool w = Files.writeText(p, String.withCString("hello, files\n"));
    Stdio.printf("write %d\n", (i16)(w ? 1 : 0));
    Stdio.printf("size %ld\n", Files.size(p));
    Stdio.printf("exists %d\n", (i16)(Files.exists(p) ? 1 : 0));

    String* back = Files.readText(p);
    if (back == 0) Stdio.printf("read NULL\n");
    else           Stdio.printf("read [%s]\n", back.cString());

    bool a = Files.appendText(p, String.withCString("more\n"));
    Stdio.printf("append %d size %ld\n", (i16)(a ? 1 : 0), Files.size(p));
    String* both = Files.readText(p);
    Stdio.printf("lines %lu\n", both == 0 ? (u32)0 : both.byteLength());

    Stdio.printf("missing size %ld exists %d\n", Files.size(none),
                 (i16)(Files.exists(none) ? 1 : 0));
    String* gone = Files.readText(none);
    Stdio.printf("missing read %s\n", gone == 0 ? "NULL" : "text");
    return (i32)0;
}
