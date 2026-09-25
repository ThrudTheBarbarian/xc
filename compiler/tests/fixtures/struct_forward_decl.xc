// struct_forward_decl.xc — a bare `struct Foo;` forward (incomplete-type)
// declaration. C — and c2xc's converted output — uses it so a struct can hold
// a POINTER to a type defined later or in another unit. The reference parser
// hard-errored ("Expected '{' to begin block") where the self-hosted port
// already accepted it; now both accept it and register an incomplete placeholder
// that the later definition fills in.
#import "Stdio.xc"

struct node;                                  // forward declaration
struct node { i32 val; node* next; }          // later definition fills it in

i32 sumList(node* head)
{
    i32 s = (i32)0;
    node* p = head;
    while (p != (node*)0) { s = s + p.val; p = p.next; }
    return s;
}

i32 main(void)
{
    node c; c.val = (i32)3; c.next = (node*)0;
    node b; b.val = (i32)2; b.next = &c;
    node a; a.val = (i32)1; a.next = &b;
    Stdio.printf("sum %d\n", sumList(&a));           // 6
    return (i32)0;
}
