// UXNull.xc — a singleton "null object" sentinel (NSNull in shape).
//
// A collection here stores Object*, and 0 is a valid nil — but sometimes you need to store an EXPLICIT
// "there is nothing here" that is distinct from "absent" (a sparse row, a JSON null, a cleared slot).
// UXNull.null() is one shared immutable instance that stands for exactly that; isNull() recognises it.
// It doubles as the reference example of the toolkit's singleton pattern (a lazily-made global, like
// UXNotificationCenter.shared / UXLog.shared).
#import "Array.xc"

UXNull* gUXNull;

class UXNull : Object
    {
    void init(void)
        {
        }
    // The one shared instance.
    static UXNull* null(void)
        {
        if (gUXNull == (UXNull*)0)
            {
            gUXNull = new UXNull();
            }
        return gUXNull;
        }
    // Is this reference the null sentinel?  (Both a real nil and the sentinel are "nothing", but only
    // the sentinel is an object you can put in a collection.)
    static bool isNull(Object* o)
        {
        return o != (Object*)0 && o == (Object*)UXNull.null();
        }
    // Convenience: nil OR the sentinel.
    static bool isNothing(Object* o)
        {
        return o == (Object*)0 || UXNull.isNull(o);
        }
    }
