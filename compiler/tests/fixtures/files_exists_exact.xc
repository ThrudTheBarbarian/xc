// files_exists_exact.xc — Files.existsExact answers for the spelling it was
// given, not for whatever the filesystem would open.
//
// win64's runtime answered existsExact with a plain exists, and NTFS is
// case-insensitive: `#import "String.xc"` beside a program in a directory with
// a string.xc (tests/fixtures has one) took that file instead of the
// stdlib's, so a win64 xcc built such a program without its main. macOS and
// wasm32 compare the stored name; Linux, Android and XTOS are case-sensitive.
//
//xtc-na: xt6502 — a 6502 has no filesystem.
//xtc-na: m68k — TOS names are case-insensitive by design (existsExact = exists).
#import "Stdio.xc"
#import "Files.xc"

i32 main(void)
{
    // Scratch files go in tmp/ (ignored by git).
    Files.createDirectory(String.withCString("tmp"));
    bool w = Files.writeText(String.withCString("tmp/CaseProbe.tmp"), String.withCString("x\n"));
    Stdio.printf("write %d\n", (i16)(w ? 1 : 0));
    Stdio.printf("exact %d\n", (i16)(Files.existsExact(String.withCString("tmp/CaseProbe.tmp")) ? 1 : 0));
    Stdio.printf("lower %d\n", (i16)(Files.existsExact(String.withCString("tmp/caseprobe.tmp")) ? 1 : 0));
    Stdio.printf("upper %d\n", (i16)(Files.existsExact(String.withCString("tmp/CASEPROBE.TMP")) ? 1 : 0));
    Stdio.printf("missing %d\n", (i16)(Files.existsExact(String.withCString("tmp/NoSuchProbe.tmp")) ? 1 : 0));
    return 0;
}
