//xtc-flags: target=arm64
//xtc-na: wasm32 xt6502 m68k — AsyncFiles runs its queue on a Thread
// AsyncFiles runs Files operations on one worker, in order: a write, an
// append and a read of the same file see each other, a missing file reads
// as null, and drain() returns once every completion has run.
#use Stdio
#import "AsyncFiles.xc"

u32 gLen = (u32)0;

i32 main(void)
    {
    String* p = String.withCString("async_files_fixture.tmp");
    AsyncFiles.writeText(p, String.withCString("one\n"), block void(bool ok) { Stdio.printf("write %ld\n", (i32)(ok ? 1 : 0)); });
    AsyncFiles.appendText(p, String.withCString("two\n"), (block void(bool))0);
    AsyncFiles.readText(p, block void(String* t) { gLen = t.byteLength(); Stdio.printf("read [%s]\n", t.cString()); });
    AsyncFiles.readText(String.withCString("/nonexistent/x"), block void(String* t) { Stdio.printf("missing %ld\n", (i32)(t == (String*)0 ? 1 : 0)); });
    AsyncFiles.drain();
    Stdio.printf("drained, len %ld\n", gLen);
    return 0;
    }
