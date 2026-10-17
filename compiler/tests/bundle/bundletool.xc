// bundletool.xc — BundleSign from the command line, for tests/bundle/run.sh:
//   bundletool make <dir> <name> <platform> <code-file> <key-file> [resources-dir]
//   bundletool verify <dir>
//   bundletool sign <dir> <key-file>     re-sign bundle.json as it stands (a tamperer with a key)
#import "Stdio.xc"
#import "Process.xc"
#import "BundleSign.xc"

i32 main(void)
{
    Array* av = Process.arguments();
    if (av == (Array*)0 || av.count() < (u32)3) { Stdio.printf("usage\n"); return 2; }
    String* cmd = (String*)av.get((u32)1);
    String* dir = (String*)av.get((u32)2);
    if (cmd.equals(String.withCString("verify")))
    {
        String* err = BundleSign.verify(dir);
        Stdio.printf("%s\n", err == (String*)0 ? "verified" : err.cString());
        return err == (String*)0 ? 0 : 1;
    }
    if (cmd.equals(String.withCString("make")) && av.count() >= (u32)7)
    {
        Data* seed = BundleSign.publisherKey((String*)av.get((u32)6));
        Map* provides = new Map();
        provides.set((Hashable*)String.withCString("Fence"), (Object*)String.withCString("2.1"));
        String* err = BundleSign.make(dir, (String*)av.get((u32)3), String.withCString("1.2"), (String*)av.get((u32)4),
                                      (String*)av.get((u32)5), av.count() > (u32)7 ? (String*)av.get((u32)7) : (String*)0,
                                      seed, String.withCString("Example"), String.withCString("example.org"),
                                      provides, new Map());
        Stdio.printf("%s\n", err == (String*)0 ? "made" : err.cString());
        return err == (String*)0 ? 0 : 1;
    }
    if (cmd.equals(String.withCString("sign")) && av.count() >= (u32)4)
    {
        Data* seed = BundleSign.publisherKey((String*)av.get((u32)3));
        Data* m = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
        Data* sig = Ed25519.sign(m.bytes(), m.length(), seed.bytes());
        String* h = BundleSign._hex(sig.bytes(), (u32)64);
        h.appendByte((u8)10);
        Files.writeText(BundleSign._join(dir, String.withCString("bundle.sig")), h);
        Stdio.printf("re-signed\n");
        return 0;
    }
    Stdio.printf("usage\n");
    return 2;
}
