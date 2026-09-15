// A library that uses Array. Array references Comparable and Object, and Object
// declares <Hashable, Comparable> while implementing only the REQUIRED equals —
// it omits the OPTIONAL compare. Merely importing this library materializes
// Object's Comparable conformance, which is where the `.xtc.iface` round-trip of
// the `optional` flag must survive: without it, the importer re-checks
// conformance and rejects Object for "not implementing compare".
#import "Array.xc"
class Bag : Object
    {
    Array* items;
    void init(void)
        {
        items = new Array();
        }
    void add(Object* o)
        {
        items.add(o);
        }
    u16 size(void)
        {
        return items.count();
        }
    }
