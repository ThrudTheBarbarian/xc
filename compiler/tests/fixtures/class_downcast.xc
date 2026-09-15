// class_downcast.xc — runtime-checked class-pointer downcasts.
//
// The plain cast `(T@) x` runtime-checks the class-id byte stamped
// at payload offset 0 by `new` and walks the `__class_parent`
// chain up from the instance's id until it either matches the
// target (success) or hits 0 (failure). On mismatch the plain
// form traps (BRK); the failable variant `(T@ ?) x` substitutes
// a null pointer instead. A null operand passes through unchanged
// for both flavours.
//
//   T1  downcast to matching leaf class (Dog ← Animal)       — success.
//   T2  failable downcast that should fail (Cat ← Dog)       — null.
//   T3  plain cast that would succeed, no trap.
//   T4  null operand, failable cast                          — stays null.

#import "Stdio.xc"

class Animal {
    u8 legs;
    void init(void)     { legs = 4; }
}
class Dog : Animal { u8 tailWag; }
class Cat : Animal { u8 purr;    }

void main(void)
{
    Animal* a = new Dog();

    Dog* d = (Dog* ?)a;
    if (d != 0)  Stdio.printf("T1 PASS\n");
    else         Stdio.printf("T1 FAIL\n");

    Cat* c = (Cat* ?)a;
    if (c == 0)  Stdio.printf("T2 PASS\n");
    else         Stdio.printf("T2 FAIL\n");

    Dog* d2 = (Dog*)a;
    if (d2 != 0) Stdio.printf("T3 PASS\n");
    else         Stdio.printf("T3 FAIL\n");

    Animal* nothing = (Animal*)0;
    Cat* c2 = (Cat* ?)nothing;
    if (c2 == 0) Stdio.printf("T4 PASS\n");
    else         Stdio.printf("T4 FAIL\n");
}
