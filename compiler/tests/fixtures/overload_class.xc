// Class-scoped method overloading.

#import <Stdio.xc>

class Ovl
    {
    static void write(u8 v)
        {
        Stdio.printf("u8=%d\n", v);
        }

    static void write(u16 v)
        {
        Stdio.printf("u16=%d\n", v);
        }

    static void write(string s)
        {
        Stdio.printf("str=%s\n", s);
        }
    }

void main(void)
    {
    u8 a = 7;
    u16 b = 1000;
    Ovl.write(a);
    Ovl.write(b);
    Ovl.write("hi");
    return;
    }
