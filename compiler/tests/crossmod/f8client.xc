// f8client.xc — uses f8lib's functions, struct and class, knowing the library
// only from its interface. The values are short binary fractions, so the
// results are exact, apart from apply's, which saturates at 448. See
// f8-lib.sh.
#import "Stdio.xc"
#use <F8Lib>

i32 main(void)
{
    f8 q = quarter(5.0);
    f8:pack(e5m2) g = wide(q);
    f8:pack(e2m5, none) c = clamp(100.0);
    QPoint p = qpoint(q, g, (f8:pack(ue8m0))0.5);
    p.x = p.x + 0.25;
    QScale* s = new QScale((f8)448.0);
    Stdio.printf("q %f g %f c %f p %f %f %f apply %f\n", q, g, c, p.x, p.y, p.s, s.apply(p.x));
    return 0;
}
