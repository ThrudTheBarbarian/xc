// class_names_unrelated.xc — names that only look like the class-name
// methods. A struct field and a static method called `className`, a field
// called `newInstanceOfClass`, and the spellings `x.className()` and
// `Object.newInstanceOfClass(name)` in this comment and in a string: none of
// them is a call to Object's methods, so the program gets no class-name
// table (tests/driver/runtime-switches.sh checks the assembly).
#import "Stdio.xc"

struct Rec
    {
    i32 className;
    i32 newInstanceOfClass;
    }

class Counter
    {
    i32 n;
    static i32 className(i32 k)
        {
        return k + (i32)1;
        }
    }

i32 main(void)
    {
    Rec r;
    r.className = (i32)3;
    r.newInstanceOfClass = (i32)4;
    Counter* c = new Counter();
    c.n = Counter.className((i32)6);
    Stdio.printf("%d %d %d\n", r.className, r.newInstanceOfClass, c.n);
    Stdio.printf("%s\n", "o.className() and Object.newInstanceOfClass(n)");
    return 0;
    }
