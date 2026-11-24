//xtc-flags: expect=sema-error
// The parser reads an operator's precedence before any type is known, so two
// classes cannot give one shape two precedences.
// Refused: operator '**' has the precedence 'above *, right' in 'A.pow' and '*' in 'B.pow': an operator has one precedence; give both the same ':precedence', or leave it off one of them
#import <Stdio.xc>

class A
    {
    i32 v;
    A* pow(A* o) :operator(self ** o) :precedence(above *, right) { return o; }
    }

class B
    {
    i32 v;
    B* pow(B* o) :operator(self ** o) :precedence(*) { return o; }
    }

i32 main(void) { return 0; }
