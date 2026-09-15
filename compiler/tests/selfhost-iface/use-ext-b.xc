#import <mod-shape>
class Shape2(RepB)
    {
    u16 repB(void)
        {
        return who() + (u16)300;
        }
    } class SubB : Shape2
    {
    void init(void)
        {
        super.init();
        }
    u16 repB(void)
        {
        return who() + (u16)400;
        }
    } Shape2 @makeSubB(void)
    {
    return new SubB();
    }
u16 callRepB(Shape2 @s)
    {
    return s.repB();
    }
