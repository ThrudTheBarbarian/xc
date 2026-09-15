// array_sizeless_forin.xc — regression for private:docs/bugs/010 #4. A sizeless
// array-literal declaration `u8 a[] = {...}` must infer its element count
// from the initialiser, so `for x in a` iterates every element (it used
// to infer 0 → zero iterations → sum 0). Distinctive values; the sum and
// count are the proof.
#import "Stdio.xc"

void main(void)
{
    u8 a[] = { $0A, $14, $1E, $28, $32 };   // 10,20,30,40,50 — 5 elements
    u16 sum = 0;
    u8  cnt = 0;
    for (u8 v in a)
    {
        sum = sum + v;
        cnt = cnt + 1;
    }
    Stdio.printf("sum=%d cnt=%d\n", sum, (u16)cnt);   // sum=150 cnt=5
    return;
}
