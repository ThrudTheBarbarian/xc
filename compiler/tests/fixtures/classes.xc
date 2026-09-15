// classes.xc — class ivars + methods
#import "Stdio.xc"

class Colour
{
    u8 red;
    u8 green;
    u8 blue;

    void set(u8 r, u8 g, u8 b)
    {
        red = r;
        green = g;
        blue = b;
    }

    u16 sum(void)
    {
        return (u16)red + (u16)green + (u16)blue;
    }
}

void main(void)
{
    Colour* c = new Colour();
    c.set($5A, $3C, $D1);		// 90, 60, 209

    Stdio.printf("%d %d %d %d\n",
        (i16)c.red, (i16)c.green, (i16)c.blue, (i16)c.sum());	// 90 60 209 359
}
