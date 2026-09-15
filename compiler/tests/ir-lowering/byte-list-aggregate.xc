// byte-list-aggregate.xc — aggregate byte-list initialisers (task #59).
//
// A small array init mixing a NON-literal entry (`base`) with literals,
// plus a struct field init. Elements/fields are read back so placement
// is actually exercised, not just lowered. Kept small so the verbose
// element-wise init stays within the xt6502 96-byte ZP pool (SSA
// register-pressure relief is a separate later task).
//
//   a[0] + a[2] + p.y  =  7 + 30 + 200  =  237
typedef struct
    {
    u16 x;
    u16 y;
    } Pt;

u16 run(void)
    {
    u8 base = 7;
    u8 a[3] = {base, 20, 30}; // non-literal first entry
    Pt p = {100, 200};
    return (u16)a[0] + (u16)a[2] + p.y;
    }
