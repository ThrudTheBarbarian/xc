// PR2: a subclass ivar whose name matches an inherited ivar would
// share the single ivar-offset map entry with its ancestor (sema
// keys unqualified) and silently corrupt parent-typed accesses.
// Sema rejects the redeclaration at the earliest point.
// xtc: error "Subclass 'Child' redeclares ivar 'x' inherited from 'Parent'"

class Parent
{
    u8 x;
}

class Child : Parent
{
    u8 x;    // illegal — shadows Parent.x
}

void main(void) { }
