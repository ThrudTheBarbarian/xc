// f4client.xc — uses f4lib's functions, struct and class, knowing the library
// only from its interface. Every value is exact in e2m1. See f4-lib.sh.
#import "Stdio.xc"
#use <F4Lib>

i32 main(void)
{
    f4 t = third(6.0);
    f4[] h = new f4[5];
    fill(h, 5, 1.5);
    h[2] = t;
    Nibbles n = nibbles(-0.5);
    Cells* c = new Cells((f4)3.0);
    c.put(4, -6.0);
    Stdio.printf("t %f total %f n %f %f %d c %f %f %f\n", t, total(h, 5), n.head, n.w[3], (i16)n.tail,
                 c.at(0), c.at(4), total(n.w, 5));
    return 0;
}
