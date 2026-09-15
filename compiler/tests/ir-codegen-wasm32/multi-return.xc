// Multiple return values: on wasm the extra results travel through the
// sret/agg slot path, so this covers agg values carrying their slot address.
extern void putw(i32 v);

i32, i32 divmod(i32 a, i32 b)
    {
    return a / b, a % b;
    }

void main(void)
    {
    i32 q;
    i32 r;
    (q, r) = divmod(47, 5);
    putw(q); // 9
    putw(r); // 2
    }
