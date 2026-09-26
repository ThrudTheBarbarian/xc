// sclib.xc — a library that uses Number and exports a class of its own.
// Its client (scclient.xc) sees Number only through this library.
#import "Stdio.xc"
#import "Number.xc"

class SCLib : Object
    {
    static void hello(void)
        {
        Stdio.printf("lib=hello\n");
        }
    }
