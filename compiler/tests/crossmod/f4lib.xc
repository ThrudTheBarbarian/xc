// f4lib.xc — a library with f4 in its interface: functions taking and
// returning f4 and an f4[], a struct with an f4 field and an f4 array field,
// and a class holding an f4 array. See f4-lib.sh.
#import "Stdio.xc"

struct Nibbles
{
    f4 head;
    f4 w[5];
    u8 tail;
};

f4 third(f32 v)
{
    return (f4)(v / 3);
}

f32 total(f4[] a, u32 n)
{
    f32 s = 0.0;
    for (u32 i = 0; i < n; i++)
        s = s + a[i];
    return s;
}

void fill(f4[] a, u32 n, f4 v)
{
    for (u32 i = 0; i < n; i++)
        a[i] = v;
}

Nibbles nibbles(f4 h)
{
    Nibbles r;
    r.head = h;
    for (u32 i = 0; i < 5; i++)
        r.w[i] = (f4)(f32)i;
    r.tail = 9;
    return r;
}

class Cells : Object
    {
    f4 cells[7];
    void init(f4 v)
        {
        for (u32 i = 0; i < 7; i++)
            cells[i] = v;
        }
    f32 at(u32 i) { return cells[i]; }
    void put(u32 i, f4 v) { cells[i] = v; }
    }
