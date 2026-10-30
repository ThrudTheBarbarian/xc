//xtc-na: xt6502,m68k,arm9,wasm32 — Directory needs a hosted file system
// directory_list.xc — Directory.list, move and remove on a small tree
//
// The entries of a directory come back in the file system's own order, so
// the program looks each one up by name: every name once, with its kind, and
// nothing else. Then a file is moved and the tree is removed, files,
// subdirectory and all.
#import "Stdio.xc"
#import "Files.xc"
#import "Directory.xc"

u32 kindOf(Array* es, string name)
{
    u32 found = (u32)0;
    u32 kind = (u32)99;
    for (u32 i = (u32)0; i < es.count(); i = i + (u32)1) {
        DirEntry* e = (DirEntry*)es.get(i);
        if (e.name.equals(String.withCString(name))) {
            found = found + (u32)1;
            kind = (u32)e.kind;
        }
    }
    return found == (u32)1 ? kind : (u32)100 + found;
}

i32 main(i32 argc, u8** argv)
{
    String* root = String.withCString("directory_list.tmp");
    Directory.remove(root);
    Files.createDirectory(root);
    Files.createDirectory(String.withCString("directory_list.tmp/sub"));
    Files.writeText(String.withCString("directory_list.tmp/a.txt"), String.withCString("alpha\n"));
    Files.writeText(String.withCString("directory_list.tmp/b.txt"), String.withCString("beta\n"));
    Files.writeText(String.withCString("directory_list.tmp/sub/c.txt"), String.withCString("gamma\n"));

    Array* es = Directory.list(root);
    Stdio.printf("entries %u\n", es.count());
    Stdio.printf("a.txt %u b.txt %u sub %u\n", kindOf(es, "a.txt"), kindOf(es, "b.txt"), kindOf(es, "sub"));
    Array* inner = Directory.list(String.withCString("directory_list.tmp/sub"));
    Stdio.printf("sub holds %u: c.txt %u\n", inner.count(), kindOf(inner, "c.txt"));
    Stdio.printf("missing directory lists as nothing: %d\n", Directory.list(String.withCString("directory_list.nope")) == (Array*)0);

    bool moved = Directory.move(String.withCString("directory_list.tmp/a.txt"), String.withCString("directory_list.tmp/sub/a2.txt"));
    Stdio.printf("moved %d: a.txt %u, a2.txt %u, text %s", moved, kindOf(Directory.list(root), "a.txt"),
                 kindOf(Directory.list(String.withCString("directory_list.tmp/sub")), "a2.txt"),
                 Files.readText(String.withCString("directory_list.tmp/sub/a2.txt")).cString());

    bool gone = Directory.remove(root);
    Stdio.printf("removed %d, exists %d\n", gone, Files.exists(root));
    return 0;
}
