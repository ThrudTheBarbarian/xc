// A typed collection's primitive element passed to a format function is
// unboxed to its element type, so the format check judges the element, not
// the Number box: `%f` given an Array<f32> element is right, and `%d` given
// one is the mistake to report. The bare spelling under `#use Stdio` is
// unboxed and checked the same way.
//
// xtc: warn "Stdio.printf: '%d' expects an integer but argument 1 is float"
// xtc: warn "Stdio.printf: '%d' expects an integer but argument 2 is f16"
// xtc: warn "Stdio.printf: '%f' expects a floating-point value but argument 3 is i32"
// xtc: warn "String.withFormat: '%s' expects a string but argument 1 is i32"
// xtc: warn "printf (Stdio.printf via use): '%d' expects an integer but argument 2 is float"
// xtc: nowarn "is Object*"

#import "Foundation.xc"
#import "Stdio.xc"
#use Stdio

void main(void)
{
    Array<f32>* f = new Array();
    f.add((f32)1.5);
    Array<f16>* h = new Array();
    h.add((f16)2.5);
    Array<i32>* n = new Array();
    n.add(3);
    Map<String, f64>* m = new Map();
    m.set(String.withCString("k"), 4.5d);
    bool pick = true;

    Stdio.printf("%f %f %d %f\n", f.get(0), h.get(0), n.get(0), m.get(String.withCString("k")));
    Stdio.printf("%ld %d %d\n", n.first(), n.last(), pick ? n.get(0) : 0);
    String* s = String.withFormat("%d %f", n.get(0), f.get(0));
    Stdio.printf("%s\n", s.cString());

    Stdio.printf("%d %d %f\n", f.get(0), h.get(0), n.get(0));
    String* t = String.withFormat("%s", n.get(0));
    t = 0;

    printf("%f %d\n", f.get(0), f.get(0));
    printf("%f %ld\n", h.get(0), n.get(0));
}
