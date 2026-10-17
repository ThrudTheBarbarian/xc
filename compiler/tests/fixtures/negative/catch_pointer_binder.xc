// The catch binder is `e` or `T e`: a type name and a binding name, never a
// pointer spelling. The self-hosted parser took `catch (Error* e)` while the
// reference refused it (2026-10-17).
// xtc: error "Expected ')' but found '*'"
#import "Foundation.xc"
#import "Error.xc"

i32 main(void)
    {
    try
        {
        throw new Error();
        }
    catch (Error* e)
        {
        return 1;
        }
    return 0;
    }
