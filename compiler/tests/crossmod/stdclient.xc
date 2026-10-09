// stdclient.xc — imports libStdLib AND Number.xc (bug 637). It used to fail
// with "Redefinition of class 'Number'": the library's interface exported the
// Number it was built with. Now the interface names Number.xc, the client
// imports it once, and the explicit import below is a no-op.
#import "Stdio.xc"
#import <StdLib>
#import "Number.xc"

i32 main(void)
    {
    Boxer* b = new Boxer();
    Number* n = b.box((i32)21);
    Number* m = Number.withI32((i32)1);
    Stdio.printf("%d %d\n", n.asI32(), m.asI32());
    return (i32)0;
    }
