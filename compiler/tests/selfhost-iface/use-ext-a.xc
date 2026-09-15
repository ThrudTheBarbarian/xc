// One of two INDEPENDENT extenders (§4.3b) — its twin is use-ext-b; each
// gets its own anchor (Shape2$cat$RepA / $RepB) and their tables must not
// collide.
#import <mod-shape>
class Shape2(RepA)
    {
    u16 repA(void)
        {
        return who() + (u16)100;
        }
    } class SubA : Shape2
    {
    void init(void)
        {
        super.init();
        }
    u16 repA(void)
        {
        return who() + (u16)200;
        }
    } Shape2 @makeSubA(void)
    {
    return new SubA();
    }
u16 callRepA(Shape2 @s)
    {
    return s.repA();
    }
