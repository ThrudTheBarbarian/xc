// A program's free function named like a library method does not capture the
// library's own calls (astronomancy, 2026-10-24): `String.compare(Object*)`
// calls its sibling `compare(String*)`, and a program declaring
// `i32 compare(i32, i32, i32)` made the standard library fail to build
// ("'compare' takes 3 arguments; 1 given" inside String.xc). A method calling
// its own name defers only to a free function that can be what it wraps: one
// with no body, or one in the method's own file.
#import "Foundation.xc"
#import "Stdio.xc"

i32 compare(i32 a, i32 b, i32 c)
    {
    return a + b + c;
    }

i32 main(void)
    {
    String* s = String.withCString("x");
    String* t = String.withCString("y");
    Stdio.printf("%s %d %d\n", s.cString(), compare((i32)1, (i32)2, (i32)3), (i32)s.compare((Object*)t));
    return (i32)0;
    }
