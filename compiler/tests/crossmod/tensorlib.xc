// tensorlib.xc — a library with tensors in its interface: a function that
// makes a tensor, one that takes one, a class holding one, and functions
// that return views (a column slice, a transpose). See tensor-lib.sh.
#import "Stdio.xc"

class Weights
    {
    tensor<f32, 2> w;
    i32 tag;
    }

tensor<f32, 2> make(u64 r, u64 c)
    {
    tensor<f32, 2> t = new tensor<f32, 2>(r, c);
    for (u64 i = 0; i < r; i++)
        for (u64 j = 0; j < c; j++)
            t[i, j] = (f32)(i * c + j);
    return t;
}

f32 total(tensor<f32, 2> t)
    {
    f32 s = 0.0;
    for (u64 i = 0; i < t.shape(0); i++)
        for (u64 j = 0; j < t.shape(1); j++)
            s += t[i, j];
    return s;
    }

Weights* holder(u64 n)
    {
    Weights* h = new Weights();
    h.w = make(n, n);
    h.tag = 7;
    return h;
    }

tensor<f32, 1> column(tensor<f32, 2> t, u64 j)
    {
    return t[.., j];
    }

tensor<f32, 2> flip(tensor<f32, 2> t)
    {
    return t.transpose();
    }
