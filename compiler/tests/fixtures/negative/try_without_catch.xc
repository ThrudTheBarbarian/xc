// A `try` with no `catch` is refused: the self-hosted parser took it while
// the reference refused it (2026-10-17).
// xtc: error "'try' must be followed by 'catch (name) { ... }'"
#import "Foundation.xc"

i32 main(void)
    {
    try
        {
        return 1;
        }
    return 0;
    }
