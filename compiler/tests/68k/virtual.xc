protocol Shape
    {
    i16 area(void);
    }
class Square<Shape>
    {
    i16 side;
    i16 area(void)
        {
        return side * side;
        }
    } i16 main()
    {
    Square* s;
    s = new Square;
    s.side = 6;
    Shape* sh;
    sh = s;
    return sh.area();
    }
