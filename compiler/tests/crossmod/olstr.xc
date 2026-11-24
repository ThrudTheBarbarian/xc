// olstr.xc — an object built with -c for olmain.xc (#654): it prints with
// Stdio.printf and works on Strings, which the program never does itself.
// The object carries its own copy of String, and the link keeps one of each
// of its symbols, so the two modules must lay out String's vtable alike.
#import "Stdio.xc"

String* greeting(void)
    {
    String* s = String.withCString("hello");
    s.append(String.withCString(", object"));
    return s;
    }

void report(String* s, u32 progHash, i32 progEquals)
    {
    String* up = s.uppercased();
    String* tail = up.substringFromByte(7);
    Stdio.printf("%s len %u prefix %d tail %s\n", up.cString(), s.byteLength(),
                 s.hasPrefix(String.withCString("hello")) ? 1 : 0, tail.cString());
    Stdio.printf("replaced %s\n", s.replacing(String.withCString("object"), String.withCString("program")).cString());
    Stdio.printf("hash agrees %d equals %d\n", progHash == s.hash() ? 1 : 0, progEquals);
    }
