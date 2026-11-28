// `^`, like `%`, `&`, `|`, the shifts and the rotates, takes integers. A float
// operand used to pass the analysis and stop code generation with "unsupported:
// binary op ^" (#795); it is refused at the operator instead.
// xtc: error "'^' needs integer operands, not 'float'"
#import "Stdio.xc"
i32 main(void)
    {
    float a = 1.5;
    float b = 2.5;
    float c = a ^ b;
    Stdio.printf("%d\n", (i32)c);
    return 0;
    }
