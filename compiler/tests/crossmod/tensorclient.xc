// tensorclient.xc — uses tensorlib through its interface alone: a tensor
// made in the library is indexed, changed and passed back; the library's
// class field is read; the client makes a tensor of its own type too; views
// the library returns are read, and the client takes a slice of its own.
#import "Stdio.xc"
#import <TensorLib>

i32 main(void)
    {
    tensor<f32, 2> t = make(2, 3);
    t[1, 2] += 10.0;
    tensor<i32, 1> mine = new tensor<i32, 1>(4);
    mine[3] = 5;
    Weights* h = holder(3);
    Stdio.printf("t %d total %d n %d mine %d h %d %d\n", (i16)t[1, 2], (i16)total(t), (i16)t.count, (i16)mine[3],
                 (i16)h.w[2, 2], (i16)h.tag);
    tensor<f32, 1> c = column(t, 2);
    tensor<f32, 2> f = flip(t);
    tensor<f32, 1> s = t[1, 1..];
    Stdio.printf("views %d %d %d %d\n", (i16)c[1], (i16)f[0, 1], (i16)s[0], (i16)f.stride(0));
    h = (Weights*)0;
    Stdio.printf("live %d\n", (i16)TensorStorage.live());
    return 0;
    }
