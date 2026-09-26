// cnlib.xc — the library half of classnames.sh, built with --emit-lib.
// Shape is public. Wedge is a subclass the client never sees in the
// interface's use: it reaches the client only as a Shape, made here.
#import "Stdio.xc"

class Shape
    {
    i32 sides;
    void init(void)
        {
        sides = (i32)1;
        }
    i32 count(void)
        {
        return sides;
        }
    }

class Square : Shape
    {
    void init(void)
        {
        sides = (i32)4;
        }
    }

class Wedge : Shape
    {
    void init(void)
        {
        sides = (i32)3;
        }
    }

class CnLib
    {
    static Shape* makeWedge(void)
        {
        return new Wedge();
        }
    // A lookup made inside the library finds the library's own classes.
    static Object* make(String* name)
        {
        return Object.newInstanceOfClass(name);
        }
    }
