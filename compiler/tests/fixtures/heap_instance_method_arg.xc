// heap_instance_method_arg.xc — a non-virtual instance method that takes an
// ARGUMENT, called on a `new`'d heap object, must receive `self`.
//
// Regression for a lowering bug: a class-typed local (`Counter c = new
// Counter()`) has a bare-class declared type — not a pointer, not a stack
// value-instance — so the method-call lowering mis-classified `c.set(x)` as a
// STATIC call and never passed `self`. A no-arg method survived on whatever was
// in the receiver register, but a method WITH an argument took its first
// argument in self's slot and dereferenced the value (7) as the object pointer:
// a wild store / crash. The fix: an identifier receiver that's a local variable
// is an instance, not the class itself.
#import <Stdio.xc>

class Counter {
    i16 v;
    void set(i16 x) { v = x; }
    i16  bump(void) { v = v + 1; return v; }
    i16  add(i16 d) { v = v + d; return v; }   // second arg-taking method
}

void main(void) {
    Counter c = new Counter();
    c.set(40);
    Stdio.printf("a=%d\n", c.bump());   // 41
    Stdio.printf("b=%d\n", c.add(9));   // 50
    return;
}
