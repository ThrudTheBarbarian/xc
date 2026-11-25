// A variadic method that forwards its `...` through a method-table call
// passes the whole tail, doubles included (#661). On arm9 the forwarder
// relays its incoming tail into the callee's slots; a call made by dispatch
// relayed nothing, so the callee read garbage.
#import "Stdio.xc"

class Sink : Object
    {
    String* fmt(u8* f, ...) { return String.withFormat(f, ...); }
    }
class LoudSink : Sink
    {
    String* fmt(u8* f, ...)
        {
        String* s = String.withFormat(f, ...);
        s.appendCString("!");
        return s;
        }
    }

class Teller : Object
    {
    Sink* _sink;
    void setSink(Sink* s) { _sink = s; }
    // A forwarder: its `...` goes on, through the method table.
    String* say(u8* f, ...) { return _sink.fmt(f, ...); }
    // Two named words before the tail: the tail starts 8-aligned all the same.
    String* tagged(u32 tag, u8* f, ...) { return _sink.fmt(f, ...); }
    }

i32 main(void)
    {
    Teller* lg = new Teller();
    lg.setSink(new Sink());
    Stdio.printf("%s\n", lg.say("%d %d", 7, 9).cString());
    Stdio.printf("%s\n", lg.say("%s and %f", "words", 2.5d).cString());
    lg.setSink(new LoudSink());
    Stdio.printf("%s\n", lg.say("%d-%d-%d", 1, 2, 3).cString());
    Stdio.printf("%s\n", lg.tagged((u32)5, "%f %d", 0.25d, 42).cString());
    return 0;
    }
