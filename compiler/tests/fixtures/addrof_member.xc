// addrof_member.xc — &obj.field and &p->field must yield an
// address, not the value of the field. Same shape of bug as
// addrof_subscript: when the AddrOf operand was a MemberAccess
// the codegen fell through to emitExprToA: and loaded the
// field's value rather than its address.
//
//   T1   &obj.x        == &obj      (offset 0)
//   T2   &obj.y        == &obj + 2  (u16 width)
//   T3   &obj.y - &obj.x == 2       (relative)
//   T4   &p->x         == p         (deref + offset 0)
//   T5   &p->y         == p + 2

#import "Stdio.xc"
#import "Assert.xc"

struct Point { u16 x; u16 y; }

Point pt;

void main(void)
{
    Assert.reset();

    pt.x = $1234;
    pt.y = $5678;

    u16 base  = (u16)&pt;
    Assert.isEqual((u16)&pt.x, base);
    Assert.isEqual((u16)&pt.y, base + 2);
    Assert.isEqual((u16)&pt.y - (u16)&pt.x, 2);

    Point* p = &pt;
    Assert.isEqual((u16)&p->x, (u16)p);
    Assert.isEqual((u16)&p->y, (u16)p + 2);

    Stdio.printf("DONE 5\n");
    return;
}
