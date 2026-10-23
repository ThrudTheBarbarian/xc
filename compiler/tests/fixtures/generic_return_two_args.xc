// A two-argument generic as a return type, on a method and a function, and
// as one of several values. The port keeps a return list as one spelling,
// joined with commas, and split it at the comma inside `Map<String, Map>`:
// "unsupported: type Map<String".
#import "Foundation.xc"
#import "Stdio.xc"

class Holder
    {
    static Map<String, Map>* make(void)
        {
        Map<String, Map>* m = new Map();
        m.set(String.withCString("inner"), new Map());
        return m;
        }
    Map<String, String>*, u32 named(void)
        {
        Map<String, String>* m = new Map();
        m.set(String.withCString("a"), String.withCString("b"));
        return m, (u32)7;
        }
    }

Map<String, String>* single(void)
    {
    Map<String, String>* m = new Map();
    m.set(String.withCString("x"), String.withCString("y"));
    return m;
    }

i32 main(void)
    {
    Map<String, Map>* m = Holder.make();
    Holder* h = new Holder();
    (Map<String, String>* n, u32 k) = h.named();
    Map<String, String>* s = single();
    Stdio.printf("%u %u %u %u\n", m.count(), n.count(), k, s.count());
    return 0;
    }
