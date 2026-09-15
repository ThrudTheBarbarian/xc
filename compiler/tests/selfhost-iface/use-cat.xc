// §4.2: a category on the imported class, with a local subclass OVERRIDING
// the category method — the full chain machinery: chain slot, $cat family
// tables, the §4.3b owner anchor, and the ownership-compare dispatch.
#import "Stdio.xc"
#import <mod-shape>
class Shape2(Rep)
    {
    u16 rep(void)
        {
        return who() + (u16)1000;
        }
    } class Sub2 : Shape2
    {
    void init(void)
        {
        super.init();
        }
    u16 rep(void)
        {
        return who() + (u16)2000;
        }
    } void main(void)
    {
    Shape2 @b = makeShape2();
    Shape2 @d = makeDerived2();
    Shape2 @s = new Sub2();
    Stdio.printf("%lu %lu %lu\n", (u32)b.rep(), (u32)d.rep(), (u32)s.rep());
    return;
    }
