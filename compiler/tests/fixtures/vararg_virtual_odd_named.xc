// A call through a method table to a variadic method with an odd number of
// named words (the receiver counts) (#664). On arm9 an xc variadic starts its
// tail 8-aligned: a direct call knows the callee and places it there, and a
// dispatch now says where in its calling convention. It marshalled the
// arguments as plain AAPCS, so the first variadic word went in the free
// register while the callee read its tail from the next 8-aligned slot, and
// this printed `22 -1515870811`.
#import "Stdio.xc"

protocol Twos
    {
    String* two(u32 a, u8* f, ...);
    }

class Box : Object <Twos>
    {
    String* two(u32 a, u8* f, ...) { return String.withFormat(f, ...); }
    String* fmt(u8* f, ...) { return String.withFormat(f, ...); }
    }

class Box2 : Box
    {
    String* two(u32 a, u8* f, ...) { return String.withFormat(f, ...); }
    String* fmt(u8* f, ...) { return String.withFormat(f, ...); }
    }

i32 main(void)
    {
    Box* b = new Box2();
    Stdio.printf("%s\n", b.two((u32)1, "%d %d", 11, 22).cString());
    Stdio.printf("%s\n", b.fmt("%d %d", 33, 44).cString());
    Twos* t = (Twos*)b;
    Stdio.printf("%s\n", t.two((u32)2, "%d %d %d", 5, 6, 7).cString());
    return 0;
    }
