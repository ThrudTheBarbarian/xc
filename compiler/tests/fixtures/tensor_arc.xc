// tensor_arc.xc — a tensor's storage goes exactly when the last value
// referring to it goes: at scope exit, when a value is overwritten, through
// a returned value (made, a parameter, a field), a copy, a parameter and a
// class field.
// TensorStorage.live() counts the storages alive.
//xtc-na: xt6502 — a tensor value is wider than the 16 bytes it returns by value
#import "Stdio.xc"

class Keeper
    {
    tensor<i32, 2> t;
    tensor<i32, 2> get(void) { return t; }
    }

tensor<i32, 2> same(tensor<i32, 2> t)
    {
    return t;
    }

tensor<i32, 2> make(u64 n)
    {
    tensor<i32, 2> t = new tensor<i32, 2>(n, n);
    t[0, 0] = (i32)n;
    return t;
    }

i32 peek(tensor<i32, 2> t)
    {
    tensor<i32, 2> c = t;
    return c[0, 0];
    }

void live(u8* at)
    {
    Stdio.printf("%s %d\n", at, (i16)TensorStorage.live());
    }

i32 main(void)
    {
    live("start");
        {
        tensor<f32, 1> a = new tensor<f32, 1>(4);
        tensor<f32, 1> b = a;
        live("two values");
        }
    live("scope");
    tensor<i32, 2> m = make(3);
    live("returned");
    Stdio.printf("peek %d\n", (i16)peek(m));
    live("param");
    m = make(2);
    live("overwrite");
    Stdio.printf("m %d\n", (i16)m[0, 0]);
    Keeper* k = new Keeper();
    k.t = m;
    m = make(4);
    live("field");
    tensor<i32, 2> back = same(k.get());
    Stdio.printf("back %d\n", (i16)back[0, 0]);
    back = make(1);
    live("returned field");
    k = (Keeper*)0;
    live("keeper gone");
    for (i32 i = 0; i < 5; i++)
        {
        tensor<u8, 3> l = new tensor<u8, 3>(2, 2, 2);
        l[1, 1, 1] = (u8)i;
        }
    live("loop");
    Stdio.printf("temp %d\n", (i16)make(5)[0, 0]);
    live("temp");
    return 0;
    }
