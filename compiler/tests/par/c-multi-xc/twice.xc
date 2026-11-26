// twice.xc — the xc file of a C/C++ program (tests/par/cpp-multifile.sh):
// a function the C++ file calls, with a string the xc runtime builds.
#import "Foundation.xc"

extern i32 xc_twice(i32 v)
{
    String* s = String.withFormat("%d", v * (i32)2);
    return (i32)s.byteLength() > (i32)0 ? v * (i32)2 : (i32)0;
}
