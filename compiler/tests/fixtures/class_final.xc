// class_final.xc — `final` opts a method back out of the vtable.
//
// Virtuality is inferred whole-program, so a method nobody overrides already
// keeps its direct call and needs no marker. `final` exists for --emit-lib,
// where the program ISN'T whole: there, every exported instance method is made
// an override root and given a slot (task #586), because the overrides live in
// a client that doesn't exist yet. `final` is the author asserting "no client
// overrides this" — restoring the direct call and keeping the vtable small,
// which is load-bearing on xt6502 (it hard-errors above slot 84).
//
// It needs NO codegen: a method with no slot already lowers to a direct call.
//
// `final` is a promise the compiler ENFORCES, or it would just be a way to
// silently devirtualise something that IS overridden:
//   - a subclass may not override a final method   (class_final_override)
//   - a final method may not satisfy a protocol    (class_final_protocol)
//     — a protocol call dispatches through the very slot `final` removes.
//
// Here it must simply not disturb ordinary dispatch: the overridable method
// still dispatches to the subclass, and the final one still runs.
#import "Stdio.xc"

class Shape
{
    u16       area(void)  { return (u16)1; }    // overridable
    final u16 sides(void) { return (u16)4; }    // final: direct call, no slot
}

class Square : Shape
{
    u16 area(void) { return (u16)42; }          // overrides the non-final one
}

void main(void)
{
    Square* sq = new Square();
    Shape*  sh = sq;                            // through a BASE pointer

    Stdio.printf("area=%d\n",  sh.area());      // must reach Square's override
    Stdio.printf("sides=%d\n", sh.sides());     // the final method still runs
}
