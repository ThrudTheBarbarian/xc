// string_path.xc — the path helpers.
//
// self-hosting M2. M1 listed stringByAppendingPathComponent: /
// …PathExtension: as "small and self-contained" — they are, but they are also
// what every part of a compiler that touches a filename needs, and the edge
// cases are where a hand-rolled version goes wrong.
//
// The separator is '/' on every target: the xt targets have no filesystem of
// their own, the hosted ones are POSIX, and Windows accepts '/' in every API
// that takes a path.
//
//   T1  lastPathComponent — including trailing separators, the root, and the
//       empty string
//   T2  deletingLastPathComponent — absolute vs relative when the parent runs
//       out ("/usr" → "/", but "usr" → "")
//   T3  pathExtension — and the two dots that introduce nothing: a leading one
//       (".bashrc") and a trailing one ("archive.")
//   T4  deletingPathExtension
//   T5  appendingPathComponent — exactly one separator however many either
//       side brings, and joining from an empty receiver
//   T6  appendingPathExtension
//   T7  isAbsolutePath

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

bool eq(String* s, string want)
{
    return s.equals(String.withCString(want));
}

void t1_t2(void)
{
    // ── T1: lastPathComponent.
    Assert.isTrue(eq(String.withCString("/a/b/c.txt").lastPathComponent(), "c.txt"));  // T1a
    Assert.isTrue(eq(String.withCString("c.txt").lastPathComponent(), "c.txt"));       // T1b
    // Trailing separators are ignored rather than yielding an empty component.
    Assert.isTrue(eq(String.withCString("/a/b/").lastPathComponent(), "b"));           // T1c
    Assert.isTrue(eq(String.withCString("/a/b///").lastPathComponent(), "b"));
    // The root is its own last component; the empty string has none.
    Assert.isTrue(eq(String.withCString("/").lastPathComponent(), "/"));               // T1d
    Assert.isTrue(String.withCString("").lastPathComponent().isEmpty());               // T1e

    // ── T2: deletingLastPathComponent.
    Assert.isTrue(eq(String.withCString("/a/b/c.txt").deletingLastPathComponent(), "/a/b"));  // T2a
    Assert.isTrue(eq(String.withCString("/a/b/").deletingLastPathComponent(), "/a"));        // T2b
    // When the parent runs out, absolute keeps the root and relative goes empty.
    Assert.isTrue(eq(String.withCString("/usr").deletingLastPathComponent(), "/"));          // T2c
    Assert.isTrue(String.withCString("usr").deletingLastPathComponent().isEmpty());          // T2d
    Assert.isTrue(eq(String.withCString("/").deletingLastPathComponent(), "/"));             // T2e
    Assert.isTrue(eq(String.withCString("a/b").deletingLastPathComponent(), "a"));           // T2f
}

void t3_t4(void)
{
    // ── T3: pathExtension.
    Assert.isTrue(eq(String.withCString("/a/b/c.txt").pathExtension(), "txt"));   // T3a
    Assert.isTrue(eq(String.withCString("c.tar.gz").pathExtension(), "gz"));      // T3b — last dot wins
    Assert.isTrue(String.withCString("/a/b/c").pathExtension().isEmpty());        // T3c
    // A dot in a DIRECTORY name is not the file's extension.
    Assert.isTrue(String.withCString("/a.b/c").pathExtension().isEmpty());        // T3d
    // Neither a leading dot nor a trailing one introduces an extension.
    Assert.isTrue(String.withCString("/home/.bashrc").pathExtension().isEmpty()); // T3e
    Assert.isTrue(String.withCString("archive.").pathExtension().isEmpty());      // T3f
    Assert.isTrue(String.withCString("").pathExtension().isEmpty());              // T3g

    // ── T4: deletingPathExtension.
    Assert.isTrue(eq(String.withCString("/a/b/c.txt").deletingPathExtension(), "/a/b/c")); // T4a
    Assert.isTrue(eq(String.withCString("c.tar.gz").deletingPathExtension(), "c.tar"));    // T4b
    Assert.isTrue(eq(String.withCString("/a/b/c").deletingPathExtension(), "/a/b/c"));     // T4c
    Assert.isTrue(eq(String.withCString(".bashrc").deletingPathExtension(), ".bashrc"));   // T4d
}

void t5_t6_t7(void)
{
    // ── T5: appendingPathComponent — one separator, whatever the inputs bring.
    String* dir = String.withCString("/tmp");
    Assert.isTrue(eq(dir.appendingPathComponent(String.withCString("x.o")), "/tmp/x.o"));   // T5a
    Assert.isTrue(eq(dir, "/tmp"));                                                        // T5b — untouched

    Assert.isTrue(eq(String.withCString("/tmp/").appendingPathComponent(String.withCString("x")), "/tmp/x"));   // T5c
    Assert.isTrue(eq(String.withCString("/tmp").appendingPathComponent(String.withCString("/x")), "/tmp/x"));   // T5d
    Assert.isTrue(eq(String.withCString("/tmp//").appendingPathComponent(String.withCString("//x/")), "/tmp/x"));// T5e

    // From an empty receiver, so a join loop can start at "".
    Assert.isTrue(eq(String.withCString("").appendingPathComponent(String.withCString("a")), "a"));  // T5f
    // From the root.
    Assert.isTrue(eq(String.withCString("/").appendingPathComponent(String.withCString("usr")), "/usr")); // T5g
    // An empty or null component leaves the path (minus trailing separators).
    Assert.isTrue(eq(String.withCString("/tmp/").appendingPathComponent(String.withCString("")), "/tmp")); // T5h
    Assert.isTrue(eq(String.withCString("/tmp").appendingPathComponent((String*)0), "/tmp"));              // T5i
    Assert.isTrue(eq(String.withCString("/").appendingPathComponent(String.withCString("")), "/"));        // T5j

    // Chained, which is how a driver builds one.
    String* p = String.withCString("/usr")
                 .appendingPathComponent(String.withCString("local"))
                 .appendingPathComponent(String.withCString("bin"));
    Assert.isTrue(eq(p, "/usr/local/bin"));                                     // T5k

    // ── T6: appendingPathExtension.
    Assert.isTrue(eq(String.withCString("/a/file").appendingPathExtension(String.withCString("txt")), "/a/file.txt")); // T6a
    Assert.isTrue(eq(String.withCString("f.tar").appendingPathExtension(String.withCString("gz")), "f.tar.gz"));       // T6b
    // An empty extension is a copy, not a trailing dot.
    Assert.isTrue(eq(String.withCString("f").appendingPathExtension(String.withCString("")), "f"));                    // T6c
    Assert.isTrue(eq(String.withCString("f").appendingPathExtension((String*)0), "f"));                                // T6d

    // ── T7.
    Assert.isTrue(String.withCString("/a").isAbsolutePath());                   // T7a
    Assert.isFalse(String.withCString("a").isAbsolutePath());                   // T7b
    Assert.isFalse(String.withCString("").isAbsolutePath());                    // T7c
}

void main(void)
{
    t1_t2();
    t3_t4();
    t5_t6_t7();
    Assert.summary();
    return;
}
