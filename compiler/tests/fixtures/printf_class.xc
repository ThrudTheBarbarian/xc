// printf %@ on a class instance — scalar + nested struct + nested
// class ivar coverage.
//
// Exercises the class-descriptor path end-to-end: compiler
// synthesises a per-class descriptor from the ivar list, packs
// (instance_ptr, desc_ptr) into the vararg buffer, and
// Stdio.printStruct walks it via type-8 (inline struct) and
// type-9 (class-pointer indirection) recursion.

#import <Stdio.xc>

struct Point
    {
    u16 x;
    u16 y;
    }

class Tag
    {
    u8  kind;
    u16 id;
    }

class Blob
    {
    u8     tag;
    u16    count;
    i16    delta;
    Point* origin;
    Tag*   marker;
    }

void main(void)
    {
    Blob* b = new Blob();
    b.tag      = $2A;
    b.count    = 1000;
    b.delta    = -5;
    b.origin   = new Point();
    b.origin.x = 17;
    b.origin.y = 42;
    b.marker   = new Tag();
    b.marker.kind = 7;
    b.marker.id   = 2024;

    Stdio.printf("blob=%@\n", b);
    return;
    }
