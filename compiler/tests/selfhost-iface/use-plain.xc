// Stage 3 alone: compile against the interface, no categories. Virtual
// dispatch across the boundary works only if the client adopted the module's
// slot numbering rather than re-deriving its own.
#import "Stdio.xc"
#import <mod-shape>
void main(void)
    {
    Shape2 @s = makeShape2();
    Shape2 @d = makeDerived2();
    Stdio.printf("%u %u\n", s.who(), d.who());
    return;
    }
