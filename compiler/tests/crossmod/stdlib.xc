// stdlib.xc — a library built with a standard-library class it does not own
// (bug 637). Number comes from support/generic/lib/Number.xc, outside the
// prelude: the interface names that file under `stdImports` instead of
// exporting Number, so a client that imports Number.xc itself is not
// redefining it.
#import "Stdio.xc"
#import "Number.xc"

class Boxer
    {
    Number* box(i32 v)
        {
        return Number.withI32(v * (i32)2);
        }
    }
