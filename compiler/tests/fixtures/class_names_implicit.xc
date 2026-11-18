//xtc-na: xt6502 — Object has no className / newInstanceOfClass there (class_names_xt6502.xc pins the error)
// class_names_implicit.xc — a class-name call with an implicit receiver.
// `className()` inside a method is a call to Object.className() on self, and
// switches the class-name table on like `o.className()` does: the program
// names no `.className` anywhere, and still gets the receiver's class.
#import "Stdio.xc"

class Shape
    {
    i32 sides;
    void show(void)
        {
        String* n = className();
        Stdio.printf("%s\n", n == (String*)0 ? "(none)" : n.cString());
        }
    }

class Square : Shape
    {
    }

i32 main(void)
    {
    Shape* s = new Shape();
    s.show();
    Shape* q = new Square();
    q.show();
    return 0;
    }
