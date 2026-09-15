// PR1: `class X : Y` with Y undeclared must be a sema error.
// xtc: error "Unknown parent class 'Missing' for class 'Child'"

class Child : Missing
{
    u8 x;
}

void main(void) { }
