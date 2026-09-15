class Adder : Object
    {
    i32 base;
    void init(void)
        {
        self.base = (i32)40;
        }
    i32 add(i32 n)
        {
        return self.base + n;
        }
    } i32 twice(i32 n)
    {
    return n * (i32)2;
    }
