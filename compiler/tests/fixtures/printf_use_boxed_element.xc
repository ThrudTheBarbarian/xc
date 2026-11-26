// A typed collection's element passed to the bare `printf` of `#use Stdio`
// is unboxed, as it is for `Stdio.printf`: the element's value is printed,
// not its Number box.
#import "Foundation.xc"
#import "Stdio.xc"
#use Stdio

i32 main(void)
    {
    Array<f32>* f = new Array();
    f.add((f32)1.5);
    Array<i32>* n = new Array();
    n.add(-5);
    Array<u8>* c = new Array();
    c.add((u8)65);
    printf("%f %ld %d %c\n", f.get(0), n.get(0), n.get(0), c.get(0));
    Stdio.printf("%f %ld %d %c\n", f.get(0), n.get(0), n.get(0), c.get(0));
    return 0;
    }
