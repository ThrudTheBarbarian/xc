// struct_copy.xc — struct value copy is independent of the original.
#import "Stdio.xc"

typedef struct {
    u16 x;
    u8 y;
} Cursor;

void main()
{
    Cursor c = {$1234, 90};

    Cursor d = *&c;		// value copy of c

    d.x = $beef;		// mutate the copy only
    d.y = 209;

    // Original must be unchanged; copy must hold the new values.
    Stdio.printf("c=(%x,%u) d=(%x,%u)\n",
                 c.x, (u16)c.y, d.x, (u16)d.y);
}
