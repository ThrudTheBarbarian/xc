// weak_struct_field.xc — an auto-zeroing slot inside a plain STRUCT.
//
// Both kinds work, and both are ordinary uses of the paradigm:
//
//   T1  `weak:C@` in a struct   — never compiled before
//   T2  `act_t^`  in a struct   — compiled, and SILENTLY DANGLED: nothing linked
//                                 it, so `if (h.a)` stayed true after the
//                                 receiver died and called through freed memory.
//
// The slot carries two hidden link words before its payload. They must be REAL
// fields in the IR layout, not a gap: the backends recompute FieldAddr offsets
// by SUMMING their own field widths and never read the layout's byteOffset, so a
// gap is invisible to them and the payload lands back on top of the links. That
// shifts every source field's IR index — which is why one function
// (structType:fieldNamed:index:) owns the mapping, and why every positional
// walk over st.fields has to skip them too.
//
// See private:docs/Design/weak-refs-intrusive.md.
#import "Stdio.xc"

typedef u16 act_t(void);

class C
{
    u16  v;
    void init(void)    { v = (u16)9; }
    u16  g(void)       { return v; }
    void dealloc(void) { Stdio.printf("died\n"); }
}

struct WHolder { weak:C* p; }      // T1
struct AHolder { act_t^ a; }       // T2

void main(void)
{
    WHolder w;
    {
        C* c = new C();
        w.p = c;
        Stdio.printf("w-alive=%d\n", (u16)(w.p != (C*)0 ? (u16)1 : (u16)0));
    }
    Stdio.printf("w-dead=%d\n", (u16)(w.p != (C*)0 ? (u16)1 : (u16)0));

    AHolder h;
    {
        C* c2 = new C();
        h.a = &c2.g;
        Stdio.printf("a-alive=%d\n", (u16)(h.a ? (u16)1 : (u16)0));
    }
    Stdio.printf("a-dead=%d\n", (u16)(h.a ? (u16)1 : (u16)0));
}
