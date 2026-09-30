//xtc-flags: expect=sema-error
// A method call on a name that is nothing in scope — a class used without
// its import — is refused, naming the name at its position.
// Refused: Undefined identifier 'Filez'
#import "Stdio.xc"

i32 main(void)
    {
    bool b = Filez.exists(String.withCString("x"));
    return b ? (i32)1 : (i32)0;
    }
