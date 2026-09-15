// protocol-dispatch.xc — dispatch a method through a protocol pointer.
//
// Two unrelated classes conform to Shape with *different* area()
// bodies. `total` takes a `Shape@` and calls area() — there is no
// concrete class, so this must dispatch through the object's vtable
// (VTblDispatch, task #58). If the slot/vtable were wrong it would call
// the wrong body and the sum would not be 7.
//
//   Square.area() = 4, Circle.area() = 3  →  total(sq)+total(ci) = 7.
protocol Shape
    {
    u16 area(void);
    }

class Square<Shape>
    {
    u16 area(void)
        {
        return (u16)4;
        }
    }

    class Circle<Shape>
    {
    u16 area(void)
        {
        return (u16)3;
        }
    }

    u16
    total(Shape* s)
    {
    return s.area(); // VTblDispatch through the protocol pointer
    }

u16 run(void)
    {
    Square* sq = new Square();
    Circle* ci = new Circle();
    return total(sq) + total(ci); // 4 + 3 = 7
    }
