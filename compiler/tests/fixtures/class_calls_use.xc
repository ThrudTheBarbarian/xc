// class_calls_use.xc — `#use`d statics called BARE inside a class method,
// and self-method precedence, all pinned (bugs 145 and 147).
//
// `class A` has no `printf`, so the bare `printf` resolves via use-promotion
// to Stdio.printf (bug 145: the reference used to refuse use-promotion
// inside class bodies). `class B` DECLARES `printf`, so its bare `printf`
// resolves to B.printf — member scope wins over the use-promoted name, and
// both compilers agree on the resolution AND on its receiver-kind
// annotation (bug 147: making use-promotion reachable inside class bodies
// had let it capture the self-method call and drop the mark).
#use Stdio
class A {
    void f(void) { printf("in class\n"); }
}
class B {
    void printf(string s) { Stdio.printf("self wins: %s\n", s); }
    void f(void) { printf("x"); }
}
i32 main(void)
{
    A* a = new A(); a.f();
    B* b = new B(); b.f();
    return 0;
}
