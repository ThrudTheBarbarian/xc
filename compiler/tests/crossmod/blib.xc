// An INDEPENDENT library. It does not import clib and has never heard of it.
protocol BProto
    {
    u16 bee(void);
    }
class BThing<BProto>
    {
    u16 v;
    u16 bee(void)
        {
        return (u16)10;
        }
    }
