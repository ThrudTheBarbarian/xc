// A range index: `:operator(self[lo..hi])` makes `v[a..b]` a call of the
// method with the two bounds, for slicing. `...` is its own operator, so a
// class can give the closed range its own meaning.
#import <Stdio.xc>

i32 live;

class Seq
    {
    i32 items[8];
    i32 count;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    static Seq* upTo(i32 n)
        {
        Seq* s = new Seq();
        for (i32 i = 0; i < n; i = i + 1)
            s.items[i] = i * i;
        s.count = n;
        return s;
        }
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    Seq* slice(i32 lo, i32 hi) :operator(self[lo..hi])
        {
        Seq* s = new Seq();
        for (i32 i = lo; i < hi; i = i + 1)
            s.items[i - lo] = items[i];
        s.count = hi - lo;
        return s;
        }
    Seq* closed(i32 lo, i32 hi) :operator(self[lo...hi]) { return self[lo..hi + 1]; }
    void fill(i32 lo, i32 hi, i32 x) :operator(self[lo..hi] = x)
        {
        for (i32 i = lo; i < hi; i = i + 1)
            items[i] = x;
        }
    }

void show(string label, Seq* s)
    {
    Stdio.printf("%s", label);
    for (i32 i = 0; i < s.count; i = i + 1)
        Stdio.printf(" %d", s[i]);
    Stdio.printf("\n");
    }

i32 main(void)
    {
    Seq* s = Seq.upTo(8);
    show("all", s);
    show("mid", s[2..5]);
    show("closed", s[2...5]);
    Seq* t = s[1..7][1..4];
    show("twice", t);
    Stdio.printf("one %d\n", s[3..6][0]);
    s[0..3] = 7;
    show("filled", s);
    t = 0;
    s = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
