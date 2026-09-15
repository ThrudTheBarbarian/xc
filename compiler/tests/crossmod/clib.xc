// A second INDEPENDENT library. It does not import blib and has never heard of it.
// Both number their protocols from the same base, because neither can know better.
protocol CProto
    {
    u16 see(void);
    }
class CThing<CProto>
    {
    u16 v;
    u16 see(void)
        {
        return (u16)30;
        }
    }
