// A finite or none pack uses its top binade for numbers, so with 8 exponent
// bits its largest values would be beyond f32, which the operations work in.
// xtc: error "a finite pack has at most 7 exponent bits, so that its largest values fit f32"
#import "Stdio.xc"

i32 main(void)
{
    f16:pack(e8m7, finite) w = 1.0;
    Stdio.printf("%f\n", w);
    return 0;
}
