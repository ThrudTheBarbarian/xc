// protocols.xc — single inheritance, virtual dispatch, protocols, and the
// optional-method trick that makes the delegate pattern work.
#import "Foundation.xc"
#import "Stdio.xc"

// A protocol is a list of methods a class promises to have. `optional`
// methods may be left out.
protocol Speaker
{
    String* speak(void);
    optional String* whisper(void);
}

class Animal : Object <Speaker>
{
    String* _name;
    void init(void) { _name = String.withCString("animal"); }
    static Animal* named(String* n) { Animal* a = new Animal(); a._name = n; return a; }
    String* name(void) { return _name; }

    // Virtual by default: a subclass's override wins even through a
    // base-class reference.
    String* speak(void) { return String.withCString("..."); }
    String* description(void) { return _name; }
}

class Dog : Animal
{
    // No init() here — the parent's still runs, then the fields below are
    // whatever the parent left them.
    static Dog* named(String* n) { Dog* d = new Dog(); d._name = n; return d; }
    String* speak(void) { return String.withCString("Woof"); }
    String* whisper(void) { return String.withCString("woof?"); }   // optional, implemented
}

class Cat : Animal
{
    static Cat* named(String* n) { Cat* c = new Cat(); c._name = n; return c; }
    String* speak(void) { return String.withCString("Meow"); }
    // whisper() deliberately NOT implemented.
}

// The type of a bound method: receiver + code, as one value.

// Taking the PROTOCOL as the parameter type means this works for anything
// that conforms, including classes written later.
void introduce(Speaker* s)
{
    Stdio.printf("  %@ says %s\n", s, s.speak().cString());

    // An unimplemented optional method leaves a NULL vtable slot, so binding
    // it with `&` doubles as "does it respond to this?" — no respondsTo:
    // call and no runtime lookup. The compiler will not let you call an
    // optional method directly; you must go through the bound value, which
    // is exactly what forces you to check it first.
    callback w String*(void) = &s.whisper;
    if (w != 0) Stdio.printf("    ...and whispers %s\n", w().cString());
    else        Stdio.print("    (does not whisper)\n");
}

i32 main(void)
{
    Animal* d = Dog.named(String.withCString("Rex"));
    Animal* c = Cat.named(String.withCString("Tom"));

    // Virtual dispatch: both are Animal* here, but each speaks for itself.
    Stdio.print("through Animal*:\n");
    Stdio.printf("  %@ -> %s\n", d, d.speak().cString());
    Stdio.printf("  %@ -> %s\n", c, c.speak().cString());

    Stdio.print("through Speaker*:\n");
    introduce(d);
    introduce(c);
    return 0;
}
