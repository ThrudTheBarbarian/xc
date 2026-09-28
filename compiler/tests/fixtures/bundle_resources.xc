// bundle_resources.xc — Bundle finds a program's own files.
//
// Bundle names the one directory a program's resources live in and resolves a
// resource name inside it: a program that ships a template or a dictionary
// cannot rely on its working directory, because a launcher, an icon and a test
// harness each start it somewhere else. This checks the resolution rules —
// with and without a Resources subdirectory, with and without an extension —
// and that a missing resource is null rather than empty.
//
// The tree it uses is built here, in the working directory, and overwritten on
// every run; nothing here can delete it (Files has no remove).
//
//xtc-na: xt6502 — a 6502 has no filesystem: Bundle there can name a root but
//        cannot read one.
#import "Stdio.xc"
#import "Bundle.xc"
#import "Files.xc"

i32 main(void)
{
    Files.createDirectory(String.withCString("bundle_resources.tmp"));
    Files.createDirectory(String.withCString("bundle_resources.tmp/Resources"));
    Files.createDirectory(String.withCString("bundle_resources.tmp/Resources/sub"));
    Files.writeText(String.withCString("bundle_resources.tmp/Resources/greeting.txt"),
                    String.withCString("hello bundle\n"));
    Files.writeText(String.withCString("bundle_resources.tmp/Resources/sub/inner.txt"),
                    String.withCString("inner\n"));
    Files.writeText(String.withCString("bundle_resources.tmp/Resources/log"),
                    String.withCString("no extension\n"));

    // A root WITH a Resources directory: that is where the resources are.
    Bundle* b = Bundle.withRoot(String.withCString("bundle_resources.tmp"));
    Stdio.printf("root %s\n", b.root().cString());
    Stdio.printf("res %s\n", b.resourcePath().cString());
    Stdio.printf("greeting [%s]\n", b.textForResource(String.withCString("greeting"), String.withCString("txt")).trimmed().cString());
    Stdio.printf("inner [%s]\n", b.textForResource(String.withCString("sub/inner"), String.withCString("txt")).trimmed().cString());
    Stdio.printf("noext [%s]\n", b.textForResource(String.withCString("log"), String.withCString("")).trimmed().cString());
    Stdio.printf("exists %d %d %d\n",
                 (i16)(b.resourceExists(String.withCString("greeting"), String.withCString("txt")) ? 1 : 0),
                 (i16)(b.resourceExists(String.withCString("log"), String.withCString("")) ? 1 : 0),
                 (i16)(b.resourceExists(String.withCString("nope"), String.withCString("txt")) ? 1 : 0));
    Stdio.printf("data %ld\n", b.dataForResource(String.withCString("greeting"), String.withCString("txt")).length());

    // A resource that is not there is NULL, not an empty String: "no such
    // resource" and "an empty resource" have to be different answers.
    String* missing = b.textForResource(String.withCString("nope"), String.withCString("txt"));
    Stdio.printf("missing %s\n", missing == 0 ? "NULL" : "text");
    Stdio.printf("missing data %s\n", b.dataForResource(String.withCString("nope"), String.withCString("txt")) == 0 ? "NULL" : "data");

    // The path is built whether or not the file is there, so a caller can name
    // where a resource WOULD be.
    Stdio.printf("path %s\n", b.pathForResource(String.withCString("nope"), String.withCString("txt"), (String*)0).cString());

    // A root with NO Resources directory uses the root itself: the same source
    // works for an app that keeps everything flat.
    Files.createDirectory(String.withCString("bundle_flat.tmp"));
    Files.writeText(String.withCString("bundle_flat.tmp/flat.txt"), String.withCString("flat\n"));
    Bundle* flat = Bundle.withRoot(String.withCString("bundle_flat.tmp"));
    Stdio.printf("flatres %s\n", flat.resourcePath().cString());
    Stdio.printf("flat [%s]\n", flat.textForResource(String.withCString("flat"), String.withCString("txt")).trimmed().cString());

    // The directory part of a path, both separators, and a path with none.
    Stdio.printf("dira %s\n", Bundle.directoryOf(String.withCString("a/b/c.txt")).cString());
    Stdio.printf("dirb %s\n", Bundle.directoryOf(String.withCString("noSlash")).cString());
    return (i32)0;
}
