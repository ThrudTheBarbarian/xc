// new_alias_array.xc — `new T[N]` allocates by the type T resolves to, not by
// the name it is written with (#723). f32 and f64 name float and double, and a
// typedef names its target, so each takes the primitive allocator that
// `new float[N]` takes. The allocator's shape follows its name, and the
// written name was taken for a struct's: the element size was then whatever
// the second argument register held, and an array of 64 KB or more aborted
// with "out of memory". A typedef of a pointer takes the pointer allocator, a
// typedef of a struct keeps the struct allocator, and a `simd:` pointer the
// page-aligned one.
#import "Stdio.xc"

// Large on the 64-bit targets and wasm32; the Atari ST and the arm9 loader
// have a few MB of heap, and the 6502 a few banks.
#if ARCH_arm64 || ARCH_x86_64 || ARCH_wasm32
#define BIG 200000
#elif ARCH_6502
#define BIG 300
#else
#define BIG 20000
#endif

typedef float real;
typedef real real2;
typedef u16 word;
typedef f64 wide;

struct Point { i32 x; i32 y; }
typedef Point Pt;
typedef i32* IntPtr;

i32 gTarget = 17;

i32 main(void)
{
    f32* f = new f32[BIG];
    f[0] = 1.5;
    f[BIG - 1] = 2.5;
    Stdio.printf("f32    %d %d\n", (i32)(f[0] * 2.0), (i32)(f[BIG - 1] * 2.0));

    f64* d = new f64[BIG / 2];
    d[0] = 3.25;
    d[BIG / 2 - 1] = 4.75;
    Stdio.printf("f64    %d %d\n", (i32)(d[0] * 4.0), (i32)(d[BIG / 2 - 1] * 4.0));

    real* r = new real[BIG];
    r[0] = 5.5;
    r[BIG - 1] = 6.5;
    Stdio.printf("real   %d %d\n", (i32)(r[0] * 2.0), (i32)(r[BIG - 1] * 2.0));

    real2* r2 = new real2[BIG];
    r2[0] = 7.5;
    r2[BIG - 1] = 8.5;
    Stdio.printf("real2  %d %d\n", (i32)(r2[0] * 2.0), (i32)(r2[BIG - 1] * 2.0));

    word* w = new word[BIG];
    w[0] = 40000;
    w[BIG - 1] = 65535;
    Stdio.printf("word   %u %u\n", (u32)w[0], (u32)w[BIG - 1]);

    wide* wd = new wide[BIG / 2];
    wd[0] = 9.25;
    wd[BIG / 2 - 1] = 10.75;
    Stdio.printf("wide   %d %d\n", (i32)(wd[0] * 4.0), (i32)(wd[BIG / 2 - 1] * 4.0));

    Pt* p = new Pt[BIG / 4];
    p[0].x = 11;
    p[BIG / 4 - 1].y = 12;
    Stdio.printf("Pt     %d %d\n", p[0].x, p[BIG / 4 - 1].y);

    simd: f32* s = new f32[BIG];
    s[0] = 13.5;
    s[BIG - 1] = 14.5;
    Stdio.printf("simd   %d %d\n", (i32)(s[0] * 2.0), (i32)(s[BIG - 1] * 2.0));

    IntPtr* ip = new IntPtr[BIG / 4];
    ip[0] = &gTarget;
    ip[BIG / 4 - 1] = &gTarget;
    Stdio.printf("IntPtr %d %d\n", *ip[0], *ip[BIG / 4 - 1]);

    // A small array, which survived the old call by luck.
    real* t = new real[4];
    t[0] = 15.5;
    t[3] = 16.5;
    Stdio.printf("small  %d %d\n", (i32)(t[0] * 2.0), (i32)(t[3] * 2.0));

    // The elements past the ones written read back as zero.
    Stdio.printf("zero   %d %d %u\n", (i32)f[1], (i32)d[1], (u32)w[1]);

    delete f;
    delete d;
    delete r;
    delete r2;
    delete w;
    delete wd;
    delete p;
    delete s;
    delete ip;
    delete t;
    return 0;
}
