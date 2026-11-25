// f16 takes the packs e5m10 (its default) and e8m7 (bf16); others are refused.
// xtc: error "f16 has no pack 'e4m11'"
#import "Stdio.xc"

i32 main(void)
{
    f16:pack(e4m11) h = 1.0;
    Stdio.printf("%f\n", h);
    return 0;
}
