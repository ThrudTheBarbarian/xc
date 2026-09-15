// class_category.xc — categories and extensions merging into a class.
//
//   class Sh (Drawing) { … }   a CATEGORY: methods only
//   class Sh ()        { … }   an EXTENSION: may also add ivars, but only
//                              where the class itself is being compiled
//
// Both merge into the class of that name, and the part node is then SPENT.
// That is the load-bearing detail: four passes walk the declaration list, and
// one that forgets to skip a merged part lowers the same method twice and dies
// on "append after terminator" — which is exactly what happened during the
// implementation. So the fixture is deliberately a whole program that RUNS,
// rather than a compile-only check.
//
// It also gives the self-hosting differentials something to compare: with no
// file in the tree using the syntax, ast-diff and sema-diff stayed green while
// the self-hosted parser could not parse a category at all. The first run of
// this shape through sema-diff found the port merging ivars after methods and
// leaving the spent node in the program — 22 differing lines.
// private:docs/Design/separate-compilation.md §4.
#import "Stdio.xc"

class Sh {
    u16 w;
    void init(void) { w = (u16)6; }
    u16 area(void) { return w * w; }
}

class Sh (Drawing) {
    u16 drawn(void) { return area() + (u16)100; }
}

class Sh () {
    u16 extra;
    u16 withExtra(void) { return w + extra; }
}

void main(void)
{
    Sh@ s = new Sh();
    s.extra = (u16)7;
    Stdio.printf("%lu %lu %lu\n", (u32)s.area(), (u32)s.drawn(), (u32)s.withExtra());
    return;
}
