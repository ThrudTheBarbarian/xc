// subscript — pins the lowering of `arr[i]` (read), `arr[i] = v`
// (write), and `arr[i]++` (read-modify-write postfix). All three
// route through ElementAddr on a pointer base; array-base
// subscripts wait on the AddrOf-of-locals task.
u8 readAt(u8* p, u8 i)
    {
    return p[i];
    }

void writeAt(u8* p, u8 i, u8 v)
    {
    p[i] = v;
    return;
    }

u8 bumpReturnOld(u8* p, u8 i)
    {
    return p[i]++;
    }
