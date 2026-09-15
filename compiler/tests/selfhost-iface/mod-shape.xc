// The MODULE half: compiled with `xcc -c` by the harness, whose .xtc.iface is
// what every use-*.xc fixture imports. A plain class with virtual dispatch
// (who is overridden) so the clients must ADOPT its slot numbering.
class Shape2
    {
    u16 v;
    void init(void)
        {
        v = (u16)10;
        }
    u16 who(void)
        {
        return v + (u16)1;
        }
    } class Derived2 : Shape2
    {
    void init(void)
        {
        super.init();
        }
    u16 who(void)
        {
        return v + (u16)2;
        }
    } Shape2 @makeShape2(void)
    {
    return new Shape2();
    }
Shape2 @makeDerived2(void)
    {
    return new Derived2();
    }
