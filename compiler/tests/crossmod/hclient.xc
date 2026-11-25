// hclient.xc — uses hlib's f16 and bf16 functions, struct and class, knowing
// the library only from its interface. The values are short binary fractions,
// so the results are exact. See f16-lib.sh.
#import "Stdio.xc"
#use <HLib>

i32 main(void)
{
    f16 h = half(5.0);
    bf16 g = brain(h);
    HPoint p = hpoint(h, g);
    p.x = p.x + 0.25;
    HScale* s = new HScale((f16)1.5);
    Stdio.printf("half %f brain %f point %f %f apply %f\n", h, g, p.x, p.y, s.apply(p.x));
    return 0;
}
