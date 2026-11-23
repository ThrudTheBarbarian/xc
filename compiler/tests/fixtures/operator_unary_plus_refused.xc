//xtc-flags: expect=sema-error
// Prefix `+` has no built-in meaning; only a class operator gives it one.
// Refused: prefix '+' is defined only by a class operator, not for 'i32'
#import <Stdio.xc>

i32 main(void)
    {
    i32 a = 5;
    return +a;
    }
